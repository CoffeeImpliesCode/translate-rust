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

const BlockImportTarget = union(enum) {
    entity: spine.EntityId,
    external: []const []const u8,
};
const BlockImport = struct {
    name: []const u8,
    target: BlockImportTarget,
    block_depth: usize,
};
const BlockImportBinding = union(enum) {
    none,
    bound: BlockImportTarget,
    ambiguous,
};
const Ext = struct {
    ctx: *Ctx,
    /// Enclosing fn entity id (for local parents).
    fn_id: spine.EntityId,
    /// The struct/enum/union entity this fn's impl block implements, when the
    /// enclosing fn is an associated method (`Self::method(...)` resolution).
    self_ty: ?spine.EntityId = null,
    locals: std.ArrayListUnmanaged(Local) = .empty,
    /// Items (`fn`) declared by the blocks that enclose this body. Rust gives
    /// an item the whole enclosing block as its scope, so a nested helper sees
    /// the siblings declared beside it — including one written after the call
    /// — while a `let` binding of the enclosing function stays invisible to it.
    /// That is why the item scope is threaded apart from `locals`.
    item_scope: []const Local = &.{},
    /// Borrowed lexical import scope; the declaring block owns each path array.
    block_imports: []const BlockImport = &.{},
    block_depth: usize = 0,

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

/// Patterns must retain the selected variant, not only its owning enum.
fn ensurePatternVariant(e: *Ext, def: spine.EntityId, raw_path: []const u8) !spine.EntityId {
    const entity = e.ctx.g.symbol_table.get(def) orelse return def;
    if (entity.kind != .enum_) return def;
    const separator = std.mem.lastIndexOf(u8, raw_path, "::") orelse return def;
    const name = std.mem.trim(u8, raw_path[separator + 2 ..], " \t\r\n");
    if (!enumBodyHasVariant(e, def, name)) return def;
    if (resolveVariant(e, def, name)) |variant| return variant;
    const variant = try e.ctx.g.symbol_table.add(.{
        .id = 0,
        .kind = .variant,
        .name = try e.ctx.alloc.dupe(u8, name),
        .span = span_of,
        .visibility = entity.visibility,
        .parent = def,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try e.ctx.bodies_list.append(e.ctx.alloc, .none);
    return variant;
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

/// One module-item lookup on the search path currently being walked.
const UseLookup = struct {
    module_id: spine.EntityId,
    name: []const u8,
};

/// The `(module, name)` lookups the current `use` walk has already made.
///
/// A `use` may lead back into a module the walk is already inside — `mod a
/// { pub use crate::b::Item; } mod b { pub use crate::a::Item; }` names each
/// other — and resolution descends through those aliases one `resolveImportedEntity`
/// at a time. Each descent used to start a walk of its own, so nothing saw the
/// module it was returning to and the recursion ran until the stack died.
///
/// Re-entering a lookup that is already on the path IS that cycle, and it ends
/// this walk the way any path this crate does not hold ends it: with null.
/// Nothing is lost by stopping there. Resolution is a function of the pair, so
/// an acyclic walk never reaches a pair it already proved, and every crate
/// without a `use` cycle answers exactly as it did before.
const UseLookupPath = struct {
    entries: std.ArrayListUnmanaged(UseLookup) = .empty,

    fn contains(self: *const UseLookupPath, module_id: spine.EntityId, name: []const u8) bool {
        for (self.entries.items) |entry| {
            if (entry.module_id != module_id) continue;
            if (std.mem.eql(u8, entry.name, name)) return true;
        }
        return false;
    }

    /// Push one lookup, or report that this walk is already inside it.
    fn enter(self: *UseLookupPath, alloc: std.mem.Allocator, module_id: spine.EntityId, name: []const u8) !bool {
        if (self.contains(module_id, name)) return false;
        try self.entries.append(alloc, .{ .module_id = module_id, .name = name });
        return true;
    }

    fn deinit(self: *UseLookupPath, alloc: std.mem.Allocator) void {
        self.entries.deinit(alloc);
        self.* = .{};
    }
};

/// Resolve a use binding through its already-resolved target, or by walking
/// the binding's source path in the lexical module tree. The latter keeps
/// source-driven extraction correct when a graph was built without the names
/// pass (or when a use target was left unresolved).
fn resolveImportedEntity(e: *const Ext, use_id: spine.EntityId, path: *UseLookupPath) ?spine.EntityId {
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

        const target = resolveUseSourcePath(e, current, hop_count + 1, path) orelse return null;
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
    path: *UseLookupPath,
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
    const module_id = use_ent.parent orelse return null;
    return resolveUsePathSegments(e, module_id, segments[0..count], depth, path);
}

/// The bounded walk every `use` path takes, module-level or block-local.
///
/// `segments` is the path's own text already split on `::`; `module_id` is the
/// module the declaration sits in, which is what makes `crate`, `self` and
/// `super` mean the same thing for both. Every intermediate segment must name a
/// module and there is no crate-wide same-name fallback, so a path that names
/// nothing this crate holds returns null — and its caller decides what to do,
/// which is what lets a block-local import refuse instead of guessing.
fn resolveUsePathSegments(
    e: *const Ext,
    module_id: spine.EntityId,
    segments: []const []const u8,
    depth: usize,
    path: *UseLookupPath,
) ?spine.EntityId {
    if (depth >= e.ctx.g.symbol_table.entities.items.len) return null;
    const count = segments.len;
    if (count == 0) return null;

    var current = module_id;
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
        const found = resolveUsePathSegment(e, current, segments[index], path) orelse return null;
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
    var path: UseLookupPath = .{};
    defer path.deinit(e.ctx.alloc);
    return resolveModuleItemThroughGlobs(e, module_id, name, &visited, &path);
}

/// One segment of a `use` path, resolved as a module item lookup of its own.
/// The glob walk's own visited set is per lookup, exactly as it is for every
/// other entry into `resolveModuleItemThroughGlobs`; the `use` walk's lookup
/// path is the one that spans the whole descent.
fn resolveUsePathSegment(
    e: *const Ext,
    module_id: spine.EntityId,
    name: []const u8,
    path: *UseLookupPath,
) ?spine.EntityId {
    var visited: std.ArrayListUnmanaged(spine.EntityId) = .empty;
    defer visited.deinit(e.ctx.alloc);
    return resolveModuleItemThroughGlobs(e, module_id, name, &visited, path);
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
    path: *UseLookupPath,
) ?spine.EntityId {
    const entered = path.enter(e.ctx.alloc, module_id, name) catch return null;
    if (!entered) return null;
    defer path.entries.items.len -= 1;
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
                return resolveImportedEntity(e, item_id, path);
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
                return resolveImportedEntity(e, ent.id, path);
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
            if (resolveModuleItemThroughGlobs(e, target, name, visited, path)) |found| {
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
        if (resolveModuleItemThroughGlobs(e, target, name, visited, path)) |found| {
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

/// Split a `::`-joined path into its segments, or null when it names nothing
/// or names more of them than `segments` can hold.
fn splitPathSegments(raw: []const u8, segments: [][]const u8) ?[]const []const u8 {
    var count: usize = 0;
    var it = std.mem.splitSequence(u8, raw, "::");
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        if (count == segments.len) return null;
        segments[count] = segment;
        count += 1;
    }
    if (count == 0) return null;
    return segments[0..count];
}

/// Resolve `segments` relative to `module_id`. `crate`, `self` and `super`
/// move the start; everything after the qualifiers is a module walk.
fn resolvePathSegmentsInModule(
    e: *const Ext,
    module_id: spine.EntityId,
    segments: []const []const u8,
) ?spine.EntityId {
    if (segments.len == 0) return null;
    var start = module_id;
    var offset: usize = 0;
    if (std.mem.eql(u8, segments[0], "crate")) {
        start = rootModuleEntity(e) orelse return null;
        offset = 1;
    } else if (std.mem.eql(u8, segments[0], "self")) {
        offset = 1;
    } else {
        while (offset < segments.len and std.mem.eql(u8, segments[offset], "super")) {
            start = parentModuleEntity(e, start) orelse return null;
            offset += 1;
        }
    }
    if (offset >= segments.len) return null;
    return resolveModulePath(e, start, segments[offset..]);
}

/// Resolve a scoped path string to its terminal entity, in the module being
/// lowered.
fn resolveScopedPathText(e: *const Ext, raw: []const u8) ?spine.EntityId {
    var segments: [8][]const u8 = undefined;
    const parsed = splitPathSegments(raw, &segments) orelse return null;
    const count = parsed.len;
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
    return resolvePathSegmentsInModule(e, owner, parsed);
}

/// Resolve a supertrait path as the trait that writes it wrote it.
///
/// A supertrait is named in the lexical module of its own declaration, so
/// `private::Sealed` is a module relative to THAT trait. Reducing the path to
/// its leaf name and resolving that name in whatever function is asking about
/// the bound resolves a different declaration — or nothing at all — as soon as
/// the caller sits in another module, or a shadowing declaration of the leaf
/// name is in scope there.
fn resolveSupertraitPath(
    e: *const Ext,
    decl_id: spine.EntityId,
    raw: []const u8,
) ?spine.EntityId {
    var path = std.mem.trim(u8, raw, " \t\r\n");
    if (path.len == 0) return null;
    // Generic arguments say how a supertrait is used, never which trait it is.
    if (std.mem.indexOfScalar(u8, path, '<')) |generic_start| path = path[0..generic_start];
    var segments: [8][]const u8 = undefined;
    const parsed = splitPathSegments(std.mem.trim(u8, path, " \t\r\n"), &segments) orelse
        return null;
    const module_id = owningModule(e, decl_id) orelse
        owningModule(e, e.ctx.mod_id) orelse
        return null;
    return resolvePathSegmentsInModule(e, module_id, parsed);
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
        .prim => |primitive| @tagName(primitive),
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

fn primitiveSourceAssociatedCall(e: *Ext, raw: []const u8, args: []const exprs.NodeId, explicit: []const types.Type) anyerror!?exprs.NodeId {
    const separator = std.mem.indexOf(u8, raw, "::") orelse return null;
    const primitive = mapPrim(raw[0..separator]) orelse return null;
    const method = raw[separator + 2 ..];
    if (implMethodForOwnerType(e, @tagName(primitive), method)) |direct|
        return try appendGenericCall(e, .{ .associated = direct }, args, explicit);
    if (explicit.len != 0) return null;
    var selected: ?spine.EntityId = null;
    for (e.ctx.g.symbol_table.entities.items) |implementation| {
        if (implementation.kind != .impl_ or implementation.id >= e.ctx.bodies_list.items.len) continue;
        const body = switch (e.ctx.bodies_list.items[implementation.id]) {
            .impl_ => |value| value,
            else => continue,
        };
        if (body.trait_path == null or body.self_ty != .path or body.self_ty.path.segments.len != 1) continue;
        const self_name = body.self_ty.path.segments[0].name;
        // The Rust input is valid: its trait solver has already checked the
        // inline and where-clause bounds for this primitive instantiation.
        // Preserve that actual source implementation and its Self argument,
        // rather than reimplementing a second trait solver here.
        const generics = body.generics orelse continue;
        if (generics.params.len != 1 or generics.params[0] != .type_ or
            !std.mem.eql(u8, generics.params[0].type_.name, self_name)) continue;
        for (e.ctx.g.symbol_table.entities.items) |child| {
            if (child.kind != .fn_ or child.parent != implementation.id or !std.mem.eql(u8, child.name, method)) continue;
            if (selected != null) return null;
            selected = child.id;
        }
    }
    const selected_method = selected orelse return null;
    return try appendGenericCall(e, .{ .associated = selected_method }, args, &.{.{ .prim = primitive }});
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

/// True when `enum_id` is the canonical `core::<module>::<enum>` this pass
/// materializes for a prelude variant.
///
/// A crate is free to declare its own `Result` and its own `Ok`; `appendPat`
/// and `lowerCall` resolve ordinary source first, so a declaration with that
/// spelling keeps its own meaning everywhere it is reached. Only the shape
/// reached through the prelude root is the one whose generic parameters the
/// source never writes, so only that one may be stamped with a type derived
/// from what its arms carry.
fn isStandardPreludeEnum(
    e: *const Ext,
    enum_id: spine.EntityId,
    module_name: []const u8,
    enum_name: []const u8,
) bool {
    const enum_entity = e.ctx.g.symbol_table.get(enum_id) orelse return false;
    if (enum_entity.kind != .enum_ or !std.mem.eql(u8, enum_entity.name, enum_name)) return false;
    const module_entity = e.ctx.g.symbol_table.get(enum_entity.parent orelse return false) orelse
        return false;
    if (module_entity.kind != .module or !std.mem.eql(u8, module_entity.name, module_name)) return false;
    const root_entity = e.ctx.g.symbol_table.get(module_entity.parent orelse return false) orelse
        return false;
    return root_entity.kind == .module and std.mem.eql(u8, root_entity.name, "core");
}

/// The variants a standard-library enum declares, for the external enums this
/// translator admits in value position.
///
/// An enum outside the crate still has a shape, and the IR needs it:
/// `io::ErrorKind::UnexpectedEof` names a unit variant OF AN ENUM, and lowering
/// it as a bare name would lose which enum it belongs to — which enum is
/// exactly what a consumer needs to pick the right representation. Same role as
/// `standard_option_variants`, for the same reason.
const std_enum_variants = [_]struct {
    path: []const []const u8,
    variants: []const []const u8,
}{
    .{ .path = &.{ "std", "io", "ErrorKind" }, .variants = &.{
        "Other",
        "NotFound",
        "PermissionDenied",
        "ConnectionRefused",
        "ConnectionReset",
        "HostUnreachable",
        "NetworkUnreachable",
        "ConnectionAborted",
        "NotConnected",
        "AddrInUse",
        "AddrNotAvailable",
        "NetworkDown",
        "BrokenPipe",
        "AlreadyExists",
        "WouldBlock",
        "InvalidInput",
        "InvalidData",
        "TimedOut",
        "WriteZero",
        "UnexpectedEof",
        "Interrupted",
        "Unsupported",
        "OutOfMemory",
    } },
};

fn stdEnumVariantNames(owner_path: []const []const u8) ?[]const []const u8 {
    for (std_enum_variants) |entry| {
        if (entry.path.len != owner_path.len) continue;
        var equal = true;
        for (entry.path, owner_path) |expected, actual| {
            if (!std.mem.eql(u8, expected, actual)) {
                equal = false;
                break;
            }
        }
        if (equal) return entry.variants;
    }
    return null;
}

/// A standard-library unit struct this translator admits in value position,
/// recorded with the declaration it actually has.
///
/// A unit struct is written as a bare name wherever a value is expected —
/// `_marker: PhantomData` is how siphasher spells `_marker: PhantomData<S>` —
/// and there is no binding of that name in scope to resolve: the `use` that
/// introduced it binds a TYPE, not a value. Lowering the name as an unresolved
/// identifier refuses valid Rust, and lowering it to a bare `.path` to nothing
/// loses which declaration it stands for. So the declaration is recorded here,
/// once, from the standard library's own source, and every later reference
/// finds the same entity — the same role `std_enum_variants` plays for a
/// variant of an external enum. A struct outside this table keeps the refusal
/// it already has rather than being minted.
const StdUnitStruct = struct {
    /// The declaration's path, spelled the way `core` spells it. A `std`
    /// spelling of the same path reaches it too; see
    /// `externalPathMatchesStandard`.
    path: []const []const u8,
    /// The declaration's own name, which is also the value the path spells.
    name: []const u8,
    /// The declaration's TYPE parameters, in source order. `PhantomData`'s `T`
    /// is what the surrounding position fixes, so it is declared even though
    /// the value position never spells it.
    type_params: []const []const u8 = &.{},
};

const std_unit_structs = [_]StdUnitStruct{
    // `pub struct PhantomData<T: ?Sized>;` — verbatim. The `?Sized` bound is
    // implied on every type parameter rather than spelled, so no bound is
    // recorded.
    .{
        .path = &.{ "core", "marker", "PhantomData" },
        .name = "PhantomData",
        .type_params = &.{"T"},
    },
};

fn stdUnitStruct(path: []const []const u8) ?StdUnitStruct {
    for (std_unit_structs) |entry| {
        if (externalPathMatchesStandard(path, entry.path)) return entry;
    }
    return null;
}

/// The struct entity an external path names, created on first use under the
/// module that contains it and found again on every later use — the same
/// find-or-create shape `ensureExternalEnumEntity` and
/// `ensureStandardPreludeVariant` use.
fn ensureExternalUnitStructEntity(
    e: *Ext,
    module_id: spine.EntityId,
    decl: StdUnitStruct,
) anyerror!spine.EntityId {
    for (e.ctx.g.symbol_table.entities.items) |ent| {
        if (ent.kind == .struct_ and ent.parent == module_id and
            std.mem.eql(u8, ent.name, decl.name))
        {
            return ent.id;
        }
    }
    const struct_id = try e.ctx.g.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = try e.ctx.alloc.dupe(u8, decl.name),
        .span = span_of,
        .visibility = .public,
        .parent = module_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try e.ctx.bodies_list.append(e.ctx.alloc, .none);
    const params = try e.ctx.alloc.alloc(types.GenericParam, decl.type_params.len);
    for (decl.type_params, 0..) |param_name, index| {
        params[index] = .{ .type_ = .{ .name = param_name, .bounds = &.{} } };
    }
    // A unit struct is one that spells no field list at all, which is how
    // `PhantomData` is written, so the layout is `.unit` and not a named field
    // list that happens to be empty.
    e.ctx.bodies_list.items[struct_id] = .{ .struct_ = .{
        .generic_params = decl.type_params,
        .generics = .{ .params = params, .where_clauses = &.{} },
        .layout = .unit,
        .fields = &.{},
        .methods = &.{},
    } };
    try appendGraphModuleItem(e, module_id, struct_id);
    return struct_id;
}

/// The extern module chain an external path's module prefix names, built
/// through the same `ensureExternalModule` the prelude variants use: `std`
/// first, then `std::io` under it.
fn ensureExternalModuleChain(
    e: *Ext,
    segments: []const []const u8,
) anyerror!spine.EntityId {
    var parent: ?spine.EntityId = null;
    for (segments) |segment| {
        parent = try ensureExternalModule(e, parent, segment);
    }
    return parent orelse error.MissingModuleEntity;
}

/// The enum entity an external path names, created on first use under the
/// module that contains it and found again on every later use — the same
/// find-or-create shape `ensureStandardPreludeVariant` uses for `Option`.
fn ensureExternalEnumEntity(
    e: *Ext,
    module_id: spine.EntityId,
    enum_name: []const u8,
    variant_names: []const []const u8,
) anyerror!spine.EntityId {
    for (e.ctx.g.symbol_table.entities.items) |ent| {
        if (ent.kind == .enum_ and ent.parent == module_id and
            std.mem.eql(u8, ent.name, enum_name))
        {
            return ent.id;
        }
    }
    const enum_id = try e.ctx.g.symbol_table.add(.{
        .id = 0,
        .kind = .enum_,
        .name = try e.ctx.alloc.dupe(u8, enum_name),
        .span = span_of,
        .visibility = .public,
        .parent = module_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try e.ctx.bodies_list.append(e.ctx.alloc, .none);
    const variants = try e.ctx.alloc.alloc(items.Variant, variant_names.len);
    for (variant_names, 0..) |variant_name, index| {
        variants[index] = .{
            .name = try e.ctx.alloc.dupe(u8, variant_name),
            .fields = .{ .none = {} },
            .discriminant = null,
        };
    }
    e.ctx.bodies_list.items[enum_id] = .{ .enum_ = .{
        .kind = .data,
        .generic_params = &.{},
        .variants = variants,
        .repr_int = null,
        .non_exhaustive = false,
    } };
    try appendGraphModuleItem(e, module_id, enum_id);
    return enum_id;
}

/// A path naming a variant of a standard-library enum: `io::ErrorKind::…`.
///
/// The owner is admitted only when it resolves to an external nominal whose
/// enum this translator knows the shape of, and only when the trailing name is
/// one of that enum's variants. A name it does not declare is refused rather
/// than minted, so no variant can be invented for an enum that lacks it.
fn lowerExternalEnumVariantPath(e: *Ext, node: ts.Node) anyerror!?exprs.NodeId {
    const raw = std.mem.trim(u8, text(e, node), " \t\r\n");
    const separator = std.mem.lastIndexOf(u8, raw, "::") orelse return null;
    const owner_text = std.mem.trim(u8, raw[0..separator], " \t\r\n");
    const variant_name = std.mem.trim(u8, raw[separator + 2 ..], " \t\r\n");
    if (owner_text.len == 0 or variant_name.len == 0) return null;

    const owner = (try externalNominalForPath(e, owner_text)) orelse return null;
    if (owner.path.len < 2) return null;
    const names = stdEnumVariantNames(owner.path) orelse return null;
    var declared = false;
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, variant_name)) {
            declared = true;
            break;
        }
    }
    if (!declared) return null;

    const module_id = try ensureExternalModuleChain(e, owner.path[0 .. owner.path.len - 1]);
    const enum_id = try ensureExternalEnumEntity(
        e,
        module_id,
        owner.path[owner.path.len - 1],
        names,
    );
    const variant = try appendExpr(e, .{ .enum_variant = .{
        .def = enum_id,
        .variant = try e.ctx.alloc.dupe(u8, variant_name),
        .tuple_fields = &.{},
        .named_fields = &.{},
    } });
    return variant;
}

/// A path naming a standard-library unit struct in value position:
/// `PhantomData`, `core::marker::PhantomData`, `std::marker::PhantomData`.
///
/// The declaration is admitted only when the path resolves to an external
/// nominal this translator records in `std_unit_structs`; anything else keeps
/// the refusal it already has, so no declaration can be invented for a type
/// outside the crate. Both spellings go through `externalNominalForPath`, so
/// the one entity is reached whether the source wrote the bare name its own
/// `use` introduced or the full path itself.
///
/// The result is a plain `.path` naming that struct, which is what a
/// crate-local unit struct in value position lowers to as well: the value of a
/// unit struct IS its constructor, and the constructor's name is the
/// declaration's. The type parameter the surrounding position fixes is not
/// spelled here, exactly as the source does not spell it.
fn lowerExternalUnitStructPath(e: *Ext, raw_path: []const u8) anyerror!?exprs.NodeId {
    const external = (try externalNominalForPath(e, raw_path)) orelse return null;
    const decl = stdUnitStruct(external.path) orelse return null;
    const module_id = try ensureExternalModuleChain(e, external.path[0 .. external.path.len - 1]);
    const struct_id = try ensureExternalUnitStructEntity(e, module_id, decl);
    return try appendExpr(e, .{ .path = .{ .def = struct_id, .generic_args = &.{} } });
}

/// One parameter of a known standard-library associated function.
const StdAssocParam = struct { name: []const u8, ty_param: []const u8 };

/// An associated function of a standard-library type, recorded with the
/// signature the standard library actually declares.
///
/// An entity in the graph carries a signature, and a wrong one is worse than
/// no entity at all: the backend checks arity against `params` and reads the
/// declared return when inferring the call. A placeholder would be a fabricated
/// fact, not an admission. So only the functions this table names are admitted,
/// and only with the signature it gives. Anything else keeps the refusal it
/// already has — a typed `unsupported`, which is accurate — until its real
/// declaration is known.
///
/// `std::io::Cursor::new` is, verbatim from the standard library:
/// `impl<T> Cursor<T> { pub const fn new(inner: T) -> Cursor<T> }`.
const StdAssocFn = struct {
    owner: []const []const u8,
    /// The other standard spellings of that same declaration. `std::vec::Vec`
    /// and `alloc::vec::Vec` are one item the standard library publishes under
    /// both roots, and a source may write either. Keeping the aliases beside
    /// the signature is what lets both spellings reach ONE declaration instead
    /// of two that could answer differently.
    owner_aliases: []const []const []const u8 = &.{},
    name: []const u8,
    type_params: []const []const u8,
    params: []const StdAssocParam,
    ret_owner: []const []const u8,
    ret_args: []const []const u8,
};

const std_assoc_fns = [_]StdAssocFn{
    .{
        .owner = &.{ "std", "io", "Cursor" },
        .name = "new",
        .type_params = &.{"T"},
        .params = &.{.{ .name = "inner", .ty_param = "T" }},
        .ret_owner = &.{ "std", "io", "Cursor" },
        .ret_args = &.{"T"},
    },
    // `impl<R: Read> BufReader<R> { pub fn new(inner: R) -> BufReader<R> }`,
    // verbatim. `R` is the reader the buffer wraps, so `BufReader::new(data)`
    // hands back a `BufReader` over exactly the argument's own type — which is
    // what makes `fill_buf` and `consume` on the result the same two
    // `std::io::BufRead` methods `runtime_io_methods` admits on any other
    // `BufRead`-bounded receiver.
    .{
        .owner = &.{ "std", "io", "BufReader" },
        .name = "new",
        .type_params = &.{"R"},
        .params = &.{.{ .name = "inner", .ty_param = "R" }},
        .ret_owner = &.{ "std", "io", "BufReader" },
        .ret_args = &.{"R"},
    },
    // `impl<T> Vec<T> { pub const fn new() -> Vec<T> }`, verbatim. The element
    // type is not an argument here — `Vec::new()` takes none — so `T` is the
    // element the surrounding position fixes, and this declares the call with
    // that parameter open rather than inventing one.
    .{
        .owner = &.{ "alloc", "vec", "Vec" },
        .owner_aliases = &.{&.{ "std", "vec", "Vec" }},
        .name = "new",
        .type_params = &.{"T"},
        .params = &.{},
        .ret_owner = &.{ "alloc", "vec", "Vec" },
        .ret_args = &.{"T"},
    },
    // `impl String { pub const fn new() -> String }`, verbatim. A `String`
    // carries no type parameter, so this one is declared with its whole
    // signature and the call it builds is typed at extraction.
    .{
        .owner = &.{ "alloc", "string", "String" },
        .owner_aliases = &.{&.{ "std", "string", "String" }},
        .name = "new",
        .type_params = &.{},
        .params = &.{},
        .ret_owner = &.{ "alloc", "string", "String" },
        .ret_args = &.{},
    },
    // `impl<K, V> HashMap<K, V> { pub fn new() -> HashMap<K, V> }`, verbatim.
    // The key and the value are the ones the surrounding position fixes, for
    // the same reason `Vec::new` leaves its element open.
    .{
        .owner = &.{ "std", "collections", "HashMap" },
        .name = "new",
        .type_params = &.{ "K", "V" },
        .params = &.{},
        .ret_owner = &.{ "std", "collections", "HashMap" },
        .ret_args = &.{ "K", "V" },
    },
};

fn externalPathSlicesEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}

/// The known signature for `Owner::assoc`, or null when this function is not
/// one this translator can declare. Matching is on the RESOLVED owner path, so
/// a crate's own `Cursor` is never claimed by the standard library's, and a
/// standard name published under both roots reaches the one declaration it is.
fn findStdAssocFn(owner_path: []const []const u8, assoc_name: []const u8) ?*const StdAssocFn {
    for (&std_assoc_fns) |*entry| {
        if (!std.mem.eql(u8, entry.name, assoc_name)) continue;
        if (!externalPathSlicesEqual(entry.owner, owner_path)) {
            var published_under = false;
            for (entry.owner_aliases) |alias| {
                if (!externalPathSlicesEqual(alias, owner_path)) continue;
                published_under = true;
                break;
            }
            if (!published_under) continue;
        }
        return entry;
    }
    return null;
}

/// A type an entry's own type parameter names, in the representation every
/// other generic signature in this file uses: a one-segment path with no
/// entity, because a type parameter has none of its own until it is
/// monomorphised.
fn typeParamType(e: *Ext, name: []const u8) anyerror!types.Type {
    const segments = try e.ctx.alloc.alloc(types.PathSegment, 1);
    segments[0] = .{ .name = try e.ctx.alloc.dupe(u8, name), .id = null };
    return .{ .path = .{ .segments = segments } };
}

/// The associated function of an external nominal, declared under the external
/// module chain that holds the owner's module — the same chain the prelude
/// enums and external enum variants already live in — with the signature the
/// standard library declares.
///
/// Nothing is emitted for such an entity: it belongs to an external module, and
/// no file is generated for one.
fn ensureExternalAssociatedFn(
    e: *Ext,
    owner_path: []const []const u8,
    assoc_name: []const u8,
) anyerror!?spine.EntityId {
    if (owner_path.len < 2 or assoc_name.len == 0) return null;
    const known = findStdAssocFn(owner_path, assoc_name) orelse return null;

    const module_id = try ensureExternalModuleChain(e, owner_path[0 .. owner_path.len - 1]);
    // `(module, name)` is NOT the identity of an associated function: every
    // type in one standard module shares that module, and `Cursor::new` and
    // `BufReader::new` share the name. Keying on those two alone hands back
    // whichever was declared first, so a second owner silently inherits the
    // first one's signature. The declared result is what distinguishes them —
    // a constructor returns its owner — so it joins the key.
    for (e.ctx.g.symbol_table.entities.items) |ent| {
        if (ent.kind != .fn_ or ent.parent == null or ent.parent.? != module_id) continue;
        if (!std.mem.eql(u8, ent.name, assoc_name)) continue;
        if (ent.id >= e.ctx.bodies_list.items.len) continue;
        const existing = switch (e.ctx.bodies_list.items[ent.id]) {
            .fn_ => |value| value,
            else => continue,
        };
        const existing_ret = switch (existing.ret) {
            .external_nominal => |value| value,
            else => continue,
        };
        if (!externalPathSlicesEqual(existing_ret.path, known.ret_owner)) continue;
        return ent.id;
    }

    const params = try e.ctx.alloc.alloc(items.Param, known.params.len);
    for (known.params, 0..) |param, index| {
        params[index] = .{
            .name = try e.ctx.alloc.dupe(u8, param.name),
            .ty = try typeParamType(e, param.ty_param),
            .span = span_of,
        };
    }
    const ret_path = try e.ctx.alloc.alloc([]const u8, known.ret_owner.len);
    for (known.ret_owner, 0..) |name, index| {
        ret_path[index] = try e.ctx.alloc.dupe(u8, name);
    }
    const ret_args = try e.ctx.alloc.alloc(types.Type, known.ret_args.len);
    for (known.ret_args, 0..) |name, index| {
        ret_args[index] = try typeParamType(e, name);
    }
    const generic_params = try e.ctx.alloc.alloc(types.GenericParam, known.type_params.len);
    for (known.type_params, 0..) |name, index| {
        generic_params[index] = .{ .type_ = .{
            .name = try e.ctx.alloc.dupe(u8, name),
            .bounds = &.{},
        } };
    }

    const fn_id = try e.ctx.g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try e.ctx.alloc.dupe(u8, assoc_name),
        .span = span_of,
        .visibility = .public,
        .parent = module_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try e.ctx.bodies_list.append(e.ctx.alloc, .none);
    // The SIGNATURE is real and comes from the standard library. The BODY is
    // not: there is no source for it, and `body = 0` is the frontend-wide
    // marker for "not lowered yet", which a finished foreign declaration must
    // not carry. An empty block records that there is nothing here to walk.
    const body = try appendExpr(e, .{ .block = .{
        .statements = &.{},
        .tail = null,
        .labelled = null,
    } });
    e.ctx.bodies_list.items[fn_id] = .{ .fn_ = .{
        .params = params,
        .ret = .{ .external_nominal = .{ .path = ret_path, .args = ret_args } },
        .generic_params = try e.ctx.alloc.dupe([]const u8, known.type_params),
        .generics = .{ .params = generic_params, .where_clauses = &.{} },
        .body = body,
    } };
    try appendGraphModuleItem(e, module_id, fn_id);
    return fn_id;
}

/// An `Owner::assoc(..)` call whose owner is an external nominal AND whose
/// signature this translator knows. Anything else is left to the existing
/// refusal rather than declared with a guessed shape.
///
/// `generic_args` is the call's own turbofish, and it is the answer to the
/// element a constructor leaves open: `Vec::<String>::new()` names its element
/// here, where `Vec::new()` leaves it to the position around it.
fn lowerExternalAssociatedCall(
    e: *Ext,
    raw_path: []const u8,
    args: []const exprs.NodeId,
    generic_args: []const types.Type,
) anyerror!?exprs.NodeId {
    const separator = std.mem.lastIndexOf(u8, raw_path, "::") orelse return null;
    var owner_text = std.mem.trim(u8, raw_path[0..separator], " \t\r\n");
    const assoc_name = std.mem.trim(u8, raw_path[separator + 2 ..], " \t\r\n");
    // A turbofish can sit ON the owner — `Vec::<String>::new` — and its
    // arguments are the CALLEE's, not another module segment. Resolving the
    // whole spelling would name a module `<String>`, which is not one.
    if (std.mem.indexOfScalar(u8, owner_text, '<')) |cut| {
        owner_text = std.mem.trim(u8, owner_text[0..cut], " \t\r\n");
    }
    if (owner_text.len == 0 or assoc_name.len == 0) return null;
    const owner = (try externalNominalForPath(e, owner_text)) orelse return null;
    const fn_id = (try ensureExternalAssociatedFn(e, owner.path, assoc_name)) orelse return null;
    // The declared return is the call's own type wherever the declaration leaves
    // it decided — `String::new()` states it outright, and a turbofished
    // `Vec::<String>::new()` states its element the same way — and stays open
    // where the standard library itself leaves it open.
    return @as(?exprs.NodeId, try appendGenericCall(e, .{ .associated = fn_id }, args, generic_args));
}

fn lookupModuleEntity(e: *const Ext, name: []const u8) ?spine.EntityId {
    const owner = owningModule(e, e.ctx.mod_id) orelse return null;
    return resolveModuleItem(e, owner, name);
}

/// Resolve an identifier: lexical `let` bindings first, then the enclosing
/// blocks' items, then a `use` those blocks declare, and only then the current
/// module scope.
fn resolveName(e: *const Ext, name: []const u8) ?spine.EntityId {
    var i = e.locals.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, e.locals.items[i].name, name)) return e.locals.items[i].def;
    }
    var j = e.item_scope.len;
    while (j > 0) {
        j -= 1;
        if (std.mem.eql(u8, e.item_scope[j].name, name)) return e.item_scope[j].def;
    }
    // A block-local `use` is the innermost binding for its name, so nothing
    // outside its block may answer for it. A binding to a definition IS that
    // definition; a binding to an external path has no entity here and is read
    // through `externalUsePath`, so it yields null rather than falling through
    // to a module item of the same name.
    switch (blockImportBinding(e, name)) {
        .none => {},
        .ambiguous => return null,
        .bound => |target| return switch (target) {
            .entity => |def| def,
            .external => null,
        },
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

/// Whether a `tuple_type` node really is a Rust tuple rather than a
/// parenthesized type.
///
/// Rust groups a type with parentheses — `&(dyn Error + 'static)`, and the
/// plain `(T)` that reads the same way — and needs a trailing comma to spell a
/// one-element tuple: `(T,)`. The vendored grammar has no node for the
/// grouping form, so both arrive as a `tuple_type` with one child and the
/// comma is the only thing that separates them. More than one child is a
/// tuple in either spelling.
fn isTupleTypeNode(node: ts.Node, raw: []const u8) bool {
    if (node.namedChildCount() != 1) return true;
    const outer = std.mem.trim(u8, raw, " \t\r\n");
    if (outer.len < 2 or !std.mem.endsWith(u8, outer, ")")) return true;
    const inner = std.mem.trimEnd(u8, outer[0 .. outer.len - 1], " \t\r\n");
    return std.mem.endsWith(u8, inner, ",");
}

/// The `Path` a trait bound names. A nominal that resolved to an external path
/// (`std::io::Read`) has no entity ids, so its segments are rebuilt from the
/// provenance path rather than borrowed.
fn cstBoundPath(e: *Ext, ty: types.Type) anyerror!types.Path {
    return switch (ty) {
        .path => |path| path,
        .external_nominal => |external| blk: {
            const segments = try e.ctx.alloc.alloc(types.PathSegment, external.path.len);
            errdefer e.ctx.alloc.free(segments);
            for (external.path, 0..) |name, index| {
                segments[index] = .{ .name = try e.ctx.alloc.dupe(u8, name), .id = null };
            }
            break :blk .{ .segments = segments };
        },
        else => error.InvalidType,
    };
}

/// The `alloc`/`core`/`std` path a prelude name stands for, or null when the
/// name is not one. A bare `Iterator` in a bound names no graph entity, so the
/// full path is what lets a consumer tell it apart from a crate's own trait.
///
/// This table lives here, not in cst.zig, because the declaration pass imports
/// this module and not the other way round: both passes read the same prelude
/// names when they lower a `dyn Trait` bound or a generic parameter bound, and
/// one table keeps those two readings identical.
pub fn preludeExternalPath(name: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, name, "String")) return &.{ "alloc", "string", "String" };
    if (std.mem.eql(u8, name, "Vec")) return &.{ "alloc", "vec", "Vec" };
    if (std.mem.eql(u8, name, "HashMap")) return &.{ "std", "collections", "HashMap" };
    if (std.mem.eql(u8, name, "From")) return &.{ "core", "convert", "From" };
    if (std.mem.eql(u8, name, "Into")) return &.{ "core", "convert", "Into" };
    if (std.mem.eql(u8, name, "TryFrom")) return &.{ "core", "convert", "TryFrom" };
    if (std.mem.eql(u8, name, "TryInto")) return &.{ "core", "convert", "TryInto" };
    if (std.mem.eql(u8, name, "AsRef")) return &.{ "core", "convert", "AsRef" };
    if (std.mem.eql(u8, name, "AsMut")) return &.{ "core", "convert", "AsMut" };
    if (std.mem.eql(u8, name, "Default")) return &.{ "core", "default", "Default" };
    if (std.mem.eql(u8, name, "Clone")) return &.{ "core", "clone", "Clone" };
    if (std.mem.eql(u8, name, "Copy")) return &.{ "core", "marker", "Copy" };
    if (std.mem.eql(u8, name, "Send")) return &.{ "core", "marker", "Send" };
    if (std.mem.eql(u8, name, "Sync")) return &.{ "core", "marker", "Sync" };
    if (std.mem.eql(u8, name, "Sized")) return &.{ "core", "marker", "Sized" };
    if (std.mem.eql(u8, name, "Unpin")) return &.{ "core", "marker", "Unpin" };
    if (std.mem.eql(u8, name, "Fn")) return &.{ "core", "ops", "Fn" };
    if (std.mem.eql(u8, name, "FnMut")) return &.{ "core", "ops", "FnMut" };
    if (std.mem.eql(u8, name, "FnOnce")) return &.{ "core", "ops", "FnOnce" };
    if (std.mem.eql(u8, name, "Drop")) return &.{ "core", "ops", "Drop" };
    if (std.mem.eql(u8, name, "Iterator")) return &.{ "core", "iter", "Iterator" };
    if (std.mem.eql(u8, name, "IntoIterator")) return &.{ "core", "iter", "IntoIterator" };
    if (std.mem.eql(u8, name, "DoubleEndedIterator")) return &.{ "core", "iter", "DoubleEndedIterator" };
    if (std.mem.eql(u8, name, "ExactSizeIterator")) return &.{ "core", "iter", "ExactSizeIterator" };
    if (std.mem.eql(u8, name, "Extend")) return &.{ "core", "iter", "Extend" };
    if (std.mem.eql(u8, name, "Debug")) return &.{ "core", "fmt", "Debug" };
    if (std.mem.eql(u8, name, "Display")) return &.{ "core", "fmt", "Display" };
    if (std.mem.eql(u8, name, "Hash")) return &.{ "core", "hash", "Hash" };
    if (std.mem.eql(u8, name, "Hasher")) return &.{ "core", "hash", "Hasher" };
    if (std.mem.eql(u8, name, "PartialEq")) return &.{ "core", "cmp", "PartialEq" };
    if (std.mem.eql(u8, name, "Eq")) return &.{ "core", "cmp", "Eq" };
    if (std.mem.eql(u8, name, "PartialOrd")) return &.{ "core", "cmp", "PartialOrd" };
    if (std.mem.eql(u8, name, "Ord")) return &.{ "core", "cmp", "Ord" };
    if (std.mem.eql(u8, name, "Add")) return &.{ "core", "ops", "Add" };
    if (std.mem.eql(u8, name, "Sub")) return &.{ "core", "ops", "Sub" };
    if (std.mem.eql(u8, name, "Mul")) return &.{ "core", "ops", "Mul" };
    if (std.mem.eql(u8, name, "Div")) return &.{ "core", "ops", "Div" };
    if (std.mem.eql(u8, name, "Rem")) return &.{ "core", "ops", "Rem" };
    if (std.mem.eql(u8, name, "Not")) return &.{ "core", "ops", "Not" };
    if (std.mem.eql(u8, name, "BitAnd")) return &.{ "core", "ops", "BitAnd" };
    if (std.mem.eql(u8, name, "BitOr")) return &.{ "core", "ops", "BitOr" };
    if (std.mem.eql(u8, name, "BitXor")) return &.{ "core", "ops", "BitXor" };
    if (std.mem.eql(u8, name, "Shl")) return &.{ "core", "ops", "Shl" };
    if (std.mem.eql(u8, name, "Shr")) return &.{ "core", "ops", "Shr" };
    if (std.mem.eql(u8, name, "Neg")) return &.{ "core", "ops", "Neg" };
    if (std.mem.eql(u8, name, "AddAssign")) return &.{ "core", "ops", "AddAssign" };
    if (std.mem.eql(u8, name, "SubAssign")) return &.{ "core", "ops", "SubAssign" };
    if (std.mem.eql(u8, name, "MulAssign")) return &.{ "core", "ops", "MulAssign" };
    if (std.mem.eql(u8, name, "DivAssign")) return &.{ "core", "ops", "DivAssign" };
    if (std.mem.eql(u8, name, "RemAssign")) return &.{ "core", "ops", "RemAssign" };
    if (std.mem.eql(u8, name, "BitAndAssign")) return &.{ "core", "ops", "BitAndAssign" };
    if (std.mem.eql(u8, name, "BitOrAssign")) return &.{ "core", "ops", "BitOrAssign" };
    if (std.mem.eql(u8, name, "BitXorAssign")) return &.{ "core", "ops", "BitXorAssign" };
    if (std.mem.eql(u8, name, "ShlAssign")) return &.{ "core", "ops", "ShlAssign" };
    if (std.mem.eql(u8, name, "ShrAssign")) return &.{ "core", "ops", "ShrAssign" };
    if (std.mem.eql(u8, name, "Index")) return &.{ "core", "ops", "Index" };
    if (std.mem.eql(u8, name, "IndexMut")) return &.{ "core", "ops", "IndexMut" };
    if (std.mem.eql(u8, name, "Deref")) return &.{ "core", "ops", "Deref" };
    if (std.mem.eql(u8, name, "DerefMut")) return &.{ "core", "ops", "DerefMut" };
    return null;
}

pub fn preludePathSegments(allocator: std.mem.Allocator, name: []const u8) !?[]const types.PathSegment {
    const external = preludeExternalPath(name) orelse return null;
    const segments = try allocator.alloc(types.PathSegment, external.len);
    for (external, 0..) |seg_name, i| {
        segments[i] = .{ .name = try allocator.dupe(u8, seg_name), .id = null };
    }
    return segments;
}

/// Whether a nominal type path spells `std::io::Result`, the standard alias
/// `pub type Result<T> = core::result::Result<T, io::Error>`.
///
/// `alias_is_std_io` reports that a leading `io` segment is the module a
/// `use std::io;` binds; without it the two-segment spelling is a crate's own
/// `Result` and keeps its own meaning.
pub fn isStdIoResultPath(segments: []const types.PathSegment, alias_is_std_io: bool) bool {
    if (segments.len < 2) return false;
    if (!std.mem.eql(u8, segments[segments.len - 1].name, "Result")) return false;
    if (segments.len == 3) {
        return std.mem.eql(u8, segments[0].name, "std") and
            std.mem.eql(u8, segments[1].name, "io");
    }
    if (segments.len == 2) {
        return alias_is_std_io and std.mem.eql(u8, segments[0].name, "io");
    }
    return false;
}

/// The `std::io::Error` the alias carries as its error arm. The path is owned
/// the way every other external nominal in the table owns its own.
pub fn stdIoErrorNominal(allocator: std.mem.Allocator) !types.Type {
    const names = [_][]const u8{ "std", "io", "Error" };
    const path = try allocator.alloc([]const u8, names.len);
    var copied: usize = 0;
    errdefer {
        for (path[0..copied]) |segment| allocator.free(segment);
        allocator.free(path);
    }
    for (names, 0..) |segment, index| {
        path[index] = try allocator.dupe(u8, segment);
        copied += 1;
    }
    return .{ .external_nominal = .{ .path = path, .args = &.{} } };
}

/// Whether `io` in this module names the standard `std::io`.
fn aliasNamesStdIo(e: *const Ext) !bool {
    const path = (try externalUsePath(e, "io")) orelse return false;
    return path.len == 2 and
        std.mem.eql(u8, path[0], "std") and
        std.mem.eql(u8, path[1], "io");
}

/// The path a trait-bound node names, with every segment the graph could
/// resolve already resolved.
///
/// A bound is not a type position: it names a capability, and one the crate
/// never declares — `Sized`, or a trait from an external crate that was not
/// imported under its bare name — has no type to map to. Splitting the source
/// text keeps the bound on record by name, which is what `boundPathMatches`
/// then resolves through the module's `use`. This is why a bound survives
/// where a parameter type of the same name would not.
fn cstPathFromNode(e: *Ext, node: ts.Node) anyerror!types.Path {
    if (mapCstType(e, node)) |mapped| {
        if (cstBoundPath(e, mapped)) |path| return path else |_| {}
    } else |_| {}
    var source = std.mem.trim(u8, text(e, node), " \t\r\n");
    if (std.mem.startsWith(u8, source, "::")) source = source[2..];
    if (source.len == 0) return error.InvalidType;
    var segments: std.ArrayListUnmanaged(types.PathSegment) = .empty;
    errdefer {
        for (segments.items) |segment| e.ctx.alloc.free(segment.name);
        segments.deinit(e.ctx.alloc);
    }
    var parts = std.mem.splitSequence(u8, source, "::");
    while (parts.next()) |part| {
        // A qualified path can carry its arguments (`Trait<Item = u8>`); the
        // arguments are the bound's `args`, not part of the name.
        const head = if (std.mem.indexOfScalar(u8, part, '<')) |cut| part[0..cut] else part;
        const name = std.mem.trim(u8, head, " \t\r\n");
        if (name.len == 0) continue;
        try segments.append(e.ctx.alloc, .{
            .name = try e.ctx.alloc.dupe(u8, name),
            .id = null,
        });
    }
    if (segments.items.len == 0) return error.InvalidType;
    return .{ .segments = try segments.toOwnedSlice(e.ctx.alloc) };
}

/// Parse one trait bound: `?Sized`, `Iterator<Item = u8>`, `std::io::Read`.
///
/// `optional` marks a relaxation bound (`?T`): it removes a bound rather than
/// adding one, and a consumer must not read it as a capability.
fn parseCstTraitBound(e: *Ext, node: ts.Node) anyerror!?types.Bound {
    var actual_node = node;
    var optional = false;
    if (std.mem.eql(u8, node.kind(), "removed_trait_bound")) {
        optional = true;
        var i: u32 = 0;
        var found: ?ts.Node = null;
        while (node.namedChild(i)) |child| : (i += 1) {
            found = child;
            break;
        }
        actual_node = found orelse return null;
    }
    if (std.mem.eql(u8, actual_node.kind(), "lifetime")) return null;

    var args_list: std.ArrayListUnmanaged(types.Type) = .empty;
    errdefer args_list.deinit(e.ctx.alloc);
    var assoc_list: std.ArrayListUnmanaged(types.AssociatedTypeBinding) = .empty;
    errdefer assoc_list.deinit(e.ctx.alloc);

    var trait_node = actual_node;
    if (std.mem.eql(u8, actual_node.kind(), "generic_type")) {
        trait_node = actual_node.childByFieldName("type") orelse return error.InvalidType;
        const args_node = actual_node.childByFieldName("type_arguments") orelse
            return error.InvalidType;
        var i: u32 = 0;
        while (args_node.namedChild(i)) |arg_child| : (i += 1) {
            if (std.mem.eql(u8, arg_child.kind(), "lifetime")) continue;
            if (std.mem.eql(u8, arg_child.kind(), "type_binding")) {
                const binding_name = arg_child.childByFieldName("name") orelse
                    return error.InvalidType;
                const binding_type = arg_child.childByFieldName("type") orelse
                    return error.InvalidType;
                try assoc_list.append(e.ctx.alloc, .{
                    .name = try e.ctx.alloc.dupe(u8, text(e, binding_name)),
                    .ty = try mapCstType(e, binding_type),
                });
            } else {
                try args_list.append(e.ctx.alloc, try mapCstType(e, arg_child));
            }
        }
    }

    var bound_path = try cstPathFromNode(e, trait_node);
    // A bare prelude name (`Iterator`, `Sized`) stands for a full `core::`
    // path. Only when nothing in the graph claims the name: a crate that
    // declares its own `Debug` keeps it, which is the whole point of matching
    // a bound by path rather than by its last segment.
    if (bound_path.segments.len == 1 and bound_path.segments[0].id == null) {
        if (preludePathSegments(e.ctx.alloc, bound_path.segments[0].name) catch null) |segs| {
            bound_path.segments = segs;
        }
    }

    return .{
        .path = bound_path,
        .args = try args_list.toOwnedSlice(e.ctx.alloc),
        .associated_types = try assoc_list.toOwnedSlice(e.ctx.alloc),
        .optional = optional,
    };
}

/// Append one entry of a `dyn Trait + 'a`, `impl Trait`, or `T: Trait` bound
/// list. `trait_bounds` wraps the whole `+`-separated list, so the walk
/// descends through it and through a `bounded_type`; a lifetime bound names no
/// trait. One parser serves all three spellings, so a bound written on a
/// generic parameter and the same bound written on `dyn` cannot disagree.
fn appendCstTraitBound(
    e: *Ext,
    node: ts.Node,
    bounds: *std.ArrayListUnmanaged(types.Bound),
) anyerror!void {
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "lifetime")) return;
    if (std.mem.eql(u8, kind, "bounded_type") or
        std.mem.eql(u8, kind, "trait_bounds"))
    {
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            try appendCstTraitBound(e, child, bounds);
        }
        return;
    }
    // `dyn Trait` and `impl Trait` both wrap their `+`-separated list behind a
    // `trait` field. Without this arm `abstract_type` is read as a leaf, and
    // reading its name means mapping it as a type — which lands back here, so
    // a helper parameter spelled `impl Iterator` recursed until the stack ran
    // out. Descent is what makes both wrappers terminate.
    if (std.mem.eql(u8, kind, "dynamic_type") or
        std.mem.eql(u8, kind, "abstract_type"))
    {
        const trait_node = node.childByFieldName("trait") orelse return error.InvalidType;
        return appendCstTraitBound(e, trait_node, bounds);
    }
    if (std.mem.eql(u8, kind, "higher_ranked_trait_bound") or
        std.mem.eql(u8, kind, "use_bounds"))
    {
        return error.InvalidType;
    }
    const bound = (try parseCstTraitBound(e, node)) orelse return error.InvalidType;
    try bounds.append(e.ctx.alloc, bound);
}

/// The bounds a generic parameter declaration carries: `R: io::Read + ?Sized`
/// on the parameter itself, or a `where R: ...` predicate.
fn collectCstGenericBounds(e: *Ext, node: ts.Node) anyerror![]const types.Bound {
    if (std.mem.eql(u8, node.kind(), "trait_bounds")) {
        var wrapped: std.ArrayListUnmanaged(types.Bound) = .empty;
        errdefer wrapped.deinit(e.ctx.alloc);
        try appendCstTraitBound(e, node, &wrapped);
        return wrapped.toOwnedSlice(e.ctx.alloc);
    }
    var bounds: std.ArrayListUnmanaged(types.Bound) = .empty;
    errdefer bounds.deinit(e.ctx.alloc);
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        const kind = child.kind();
        if (std.mem.eql(u8, kind, "trait_bounds") or std.mem.eql(u8, kind, "type_bound")) {
            try appendCstTraitBound(e, child, &bounds);
        }
    }
    return bounds.toOwnedSlice(e.ctx.alloc);
}

/// Read the `where` predicates of a function item into the same
/// `WhereClause` rows the declaration pass writes, so a consumer that walks
/// `generics.where_clauses` cannot tell the two passes apart.
fn collectCstWhereClause(
    e: *Ext,
    where_node: ts.Node,
    where_clauses: *std.ArrayListUnmanaged(types.WhereClause),
) anyerror!void {
    var i: u32 = 0;
    while (where_node.namedChild(i)) |predicate| : (i += 1) {
        if (!std.mem.eql(u8, predicate.kind(), "where_predicate")) continue;
        const left_node = predicate.childByFieldName("left") orelse
            (if (predicate.namedChildCount() > 0) predicate.namedChild(0) else null) orelse continue;
        if (std.mem.eql(u8, left_node.kind(), "lifetime")) continue;
        const self_path = try cstPathFromNode(e, left_node);
        const bounds_node = predicate.childByFieldName("bounds") orelse blk: {
            var j: u32 = 0;
            while (predicate.namedChild(j)) |c| : (j += 1) {
                if (std.mem.eql(u8, c.kind(), "trait_bounds")) break :blk c;
            }
            break :blk null;
        };
        const clause_bounds: []const types.Bound = if (bounds_node) |bn|
            try collectCstGenericBounds(e, bn)
        else
            &.{};
        try where_clauses.append(e.ctx.alloc, .{
            .self_ty = self_path,
            .bounds = clause_bounds,
        });
    }
}

/// Collect the full generic metadata of a function item: every type, const and
/// lifetime parameter with its bounds, plus its `where` clauses.
///
/// This mirrors the declaration pass's collector and produces the same
/// `types.Generics`. A block-local `fn` is a real item with a real signature,
/// so its bounds have to be as complete as a module-level `fn`'s — a body that
/// calls `r.read_exact(..)` through `R: ?Sized + io::Read` is exactly what those
/// bounds authorise, and dropping them would refuse a call Rust accepts.
fn collectCstGenerics(e: *Ext, item: ts.Node) anyerror!?types.Generics {
    var params: std.ArrayListUnmanaged(types.GenericParam) = .empty;
    errdefer params.deinit(e.ctx.alloc);
    var where_clauses: std.ArrayListUnmanaged(types.WhereClause) = .empty;
    errdefer where_clauses.deinit(e.ctx.alloc);
    var found = false;
    var i: u32 = 0;
    while (item.namedChild(i)) |child| : (i += 1) {
        const ck = child.kind();
        if (std.mem.eql(u8, ck, "type_parameters")) {
            var j: u32 = 0;
            while (child.namedChild(j)) |parameter| : (j += 1) {
                const kind = parameter.kind();
                if (std.mem.eql(u8, kind, "type_parameter")) {
                    var name: []const u8 = "";
                    var k: u32 = 0;
                    while (parameter.namedChild(k)) |part| : (k += 1) {
                        if (std.mem.eql(u8, part.kind(), "type_identifier")) {
                            name = text(e, part);
                            break;
                        }
                    }
                    if (name.len == 0) continue;
                    try params.append(e.ctx.alloc, .{ .type_ = .{
                        .name = try e.ctx.alloc.dupe(u8, name),
                        .bounds = try collectCstGenericBounds(e, parameter),
                    } });
                    found = true;
                } else if (std.mem.eql(u8, kind, "const_parameter")) {
                    var name: []const u8 = "";
                    var ty_node: ?ts.Node = parameter.childByFieldName("type");
                    var k: u32 = 0;
                    while (parameter.namedChild(k)) |part| : (k += 1) {
                        if (std.mem.eql(u8, part.kind(), "identifier")) name = text(e, part);
                        if (ty_node == null and std.mem.eql(u8, part.kind(), "type")) ty_node = part;
                    }
                    if (name.len == 0 or ty_node == null) continue;
                    try params.append(e.ctx.alloc, .{ .const_ = .{
                        .name = try e.ctx.alloc.dupe(u8, name),
                        .ty = try mapCstType(e, ty_node.?),
                    } });
                    found = true;
                } else if (std.mem.eql(u8, kind, "lifetime_parameter")) {
                    try params.append(e.ctx.alloc, .{ .lifetime = .{
                        .name = try e.ctx.alloc.dupe(u8, text(e, parameter)),
                    } });
                    found = true;
                }
            }
        } else if (std.mem.eql(u8, ck, "where_clause")) {
            try collectCstWhereClause(e, child, &where_clauses);
            found = true;
        }
    }
    if (!found) {
        params.deinit(e.ctx.alloc);
        where_clauses.deinit(e.ctx.alloc);
        return null;
    }
    return .{
        .params = try params.toOwnedSlice(e.ctx.alloc),
        .where_clauses = try where_clauses.toOwnedSlice(e.ctx.alloc),
    };
}

/// The declared bounds of an `impl Trait`, `dyn Trait`, or `Box<dyn Trait>`
/// inner type.
///
/// Both spellings wrap the same `+`-separated list behind a `trait` field, so
/// they collect identically and differ only in the type they produce: `impl
/// Trait` is an opaque type inference may still name concretely later, while
/// `dyn Trait` is an erased trait object from the start. Reading one as the
/// other loses that distinction, so the two wrappers stay apart here even
/// though the rows beneath them are identical.
fn cstTraitBoundList(e: *Ext, node: ts.Node) anyerror![]const types.Bound {
    var bounds: std.ArrayListUnmanaged(types.Bound) = .empty;
    errdefer bounds.deinit(e.ctx.alloc);
    try appendCstTraitBound(e, node, &bounds);
    if (bounds.items.len == 0) return error.InvalidType;
    return bounds.toOwnedSlice(e.ctx.alloc);
}

/// `impl Trait`: the declared bounds are all the type says, and `concrete`
/// stays empty for inference to fill. This is the shape the declaration pass
/// writes for the same source.
fn cstOpaqueType(e: *Ext, node: ts.Node) anyerror!types.Type {
    return .{ .@"opaque" = .{ .bounds = try cstTraitBoundList(e, node) } };
}

/// `dyn Trait + 'a`, and the inner type of a `Box<dyn Trait>`: an erased trait
/// object, which is what the IR's `dyn_trait` keeps.
fn cstDynTraitType(e: *Ext, node: ts.Node) anyerror!types.Type {
    return .{ .dyn_trait = try cstTraitBoundList(e, node) };
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
    // `<I as private::Sealed>::Buffer` arrives as an outer
    // `scoped_type_identifier`, so the projection is reached through the
    // named-type arm below rather than as a bare `qualified_type`. A bracketed
    // form on its own names nothing — it has no `::Member` to project — so it
    // keeps the refusal the inner `qualified_type` already got instead of
    // falling through to the first-child default, which would read the
    // receiver as if it were the whole type.
    if (std.mem.eql(u8, kind, "bracketed_type") or std.mem.eql(u8, kind, "qualified_type")) {
        return error.UnresolvedNominalType;
    }
    if (std.mem.eql(u8, kind, "scoped_type_identifier")) {
        if (try mapCstQualifiedProjection(e, node)) |projection| return projection;
    }
    if (std.mem.eql(u8, kind, "generic_type") or std.mem.eql(u8, kind, "generic_type_with_turbofish") or
        std.mem.eql(u8, kind, "type_identifier") or
        std.mem.eql(u8, kind, "identifier") or
        std.mem.eql(u8, kind, "scoped_type_identifier"))
    {
        const named_type = try mapCstNamedType(e, node);
        return named_type;
    }
    if (std.mem.eql(u8, kind, "abstract_type")) {
        return cstOpaqueType(e, node);
    }
    if (std.mem.eql(u8, kind, "dynamic_type") or
        std.mem.eql(u8, kind, "bounded_type"))
    {
        return cstDynTraitType(e, node);
    }
    if (std.mem.eql(u8, kind, "tuple_type") or std.mem.eql(u8, kind, "unit_type")) {
        var tup: std.ArrayListUnmanaged(types.Type) = .empty;
        defer tup.deinit(e.ctx.alloc);
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            try tup.append(e.ctx.alloc, try mapCstType(e, c));
        }
        if (tup.items.len == 0) return .{ .prim = .unit };
        if (tup.items.len == 1 and !isTupleTypeNode(node, text(e, node))) {
            // `(T)` groups; only `(T,)` is a one-element tuple.
            return tup.items[0];
        }
        return .{ .tuple = try tup.toOwnedSlice(e.ctx.alloc) };
    }
    if (node.namedChildCount() > 0) return mapCstType(e, node.namedChild(0).?);
    return unsupportedCstType();
}
/// `<Receiver as Trait>::Member` — the qualified associated projection, in the
/// one shape the rest of the pipeline already reads.
///
/// The CST is an OUTER `scoped_type_identifier` whose `path` is a
/// `bracketed_type` holding the inner `qualified_type`; the member is the
/// outer `name` field, and the inner node carries `type` (the receiver) and
/// `alias` (the trait). `qualifiedAssociatedPath` already walks exactly that
/// shape, so the projection is read through it rather than a second spelling
/// of the same walk.
///
/// The IR form is three path segments — receiver, trait, member — with the
/// module prefix on the trait and the `as` clause already gone. The middle
/// segment is the trait ENTITY, not the text that spelled it, so
/// `private::Sealed` and a `Sealed` in scope reach the same projection through
/// the one resolver that finds nested modules.
///
/// The terminal id stays NULL. An impl's own `type Member = ...` is this
/// projection already carried out for ONE concrete receiver, so stamping that
/// id here would let the first impl's array length stand in for the generic
/// the signature is written on. The null terminal is what the backend's
/// `lowerAssociatedProjection` pairs with the trait descriptor so the impl
/// matching the receiver supplies the layout.
///
/// Every check here is the conservative half of the pair: the receiver is a
/// lexical type parameter no declaration resolves, the middle entity is a
/// trait, and that trait declares this member in its own body. Metadata that
/// does not support the shape is refused (`null`), which leaves the node to
/// the ordinary named-path mapper rather than guessing a layout.
fn mapCstQualifiedProjection(e: *Ext, node: ts.Node) anyerror!?types.Type {
    const qualified = qualifiedAssociatedPath(e, node) orelse return null;
    const member = std.mem.trim(u8, qualified.name, " \t\r\n");
    if (member.len == 0) return null;

    const trait_id = resolvePatternPath(e, qualified.trait) orelse return null;
    const trait_entity = e.ctx.g.symbol_table.get(trait_id) orelse return null;
    if (trait_entity.kind != .trait_) return null;
    if (!traitDeclaresAssociatedType(e, trait_id, member)) return null;

    const receiver = mapCstType(e, qualified.receiver) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    const receiver_path = switch (receiver) {
        .path => |path| path,
        else => return null,
    };
    // The head of a projection is the lexical type parameter the source wrote
    // the signature on. A receiver that carries an id has already been
    // resolved to one nominal, and the descriptor pair the backend builds is
    // about choosing between impls — not about a receiver already chosen.
    if (receiver_path.segments.len != 1) return null;
    const receiver_segment = receiver_path.segments[0];
    if (receiver_segment.id != null) return null;
    if (!activeTypeParameter(e, receiver_segment.name)) return null;

    const segments = try e.ctx.alloc.alloc(types.PathSegment, 3);
    errdefer e.ctx.alloc.free(segments);
    // The receiver keeps the name slice its own path already owns; nothing
    // here allocates a second copy of it or frees the first.
    segments[0] = receiver_segment;
    segments[1] = .{ .name = trait_entity.name, .id = trait_id };
    segments[2] = .{
        .name = try e.ctx.alloc.dupe(u8, member),
        .id = null,
    };
    return .{ .path = .{ .segments = segments } };
}

/// True when `trait_id` declares an associated TYPE called `name` in its own
/// body. This is the same membership `validateAssociatedProjection` in
/// `ir/validate.zig` requires of the IR path and `traitHasAssociatedMember`
/// in `backend/zig/lower.zig` requires of the descriptor, so a projection the
/// extractor emits is one the rest of the pipeline can act on.
fn traitDeclaresAssociatedType(
    e: *const Ext,
    trait_id: spine.EntityId,
    name: []const u8,
) bool {
    if (trait_id >= e.ctx.bodies_list.items.len) return false;
    const trait_body = switch (e.ctx.bodies_list.items[trait_id]) {
        .trait_ => |body| body,
        else => return false,
    };
    for (trait_body.assoc_types) |assoc_type| {
        if (std.mem.eql(u8, assoc_type.name, name)) return true;
    }
    return false;
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
    } else if (std.mem.eql(u8, kind, "scoped_type_identifier") or std.mem.eql(u8, kind, "scoped_identifier")) {
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
            } else if (std.mem.eql(u8, k, "scoped_type_identifier") or std.mem.eql(u8, k, "scoped_identifier")) {
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

    // `std::io::Result<T>` is the standard alias
    // `pub type Result<T> = core::result::Result<T, io::Error>`, so it reads as
    // a one-armed result here and the error arm is the nominal the runtime's
    // `r2z.io.Result` is written in. A crate's own one-armed `Result` is not
    // this type, which is what the alias argument below decides.
    if (args.len == 1 and isStdIoResultPath(segs.items, try aliasNamesStdIo(e))) {
        const r = try e.ctx.alloc.create(types.Result);
        r.* = .{
            .ok = args[0],
            .err = try stdIoErrorNominal(e.ctx.alloc),
            .is_error_unionable = true,
        };
        return .{ .result = r };
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
    if (segs.items.len == 0 and blockImportBinding(e, nm) == .none and resolveName(e, nm) == null and
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
            const path = switch (blockImportBinding(e, nm)) {
                .bound => try externalNominalPath(e, external_path, &.{}),
                else => external_path,
            };
            return .{ .external_nominal = .{
                .path = path,
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
    // A block-local `use` binds the name in the innermost scope that introduces
    // it, so once a block has bound it neither an outer block nor a module
    // import may answer — including a module import of a DIFFERENT path under
    // the same name, which is what makes a body-scoped alias shadow instead of
    // merge.
    switch (blockImportBinding(e, name)) {
        .bound => |target| return switch (target) {
            .external => |path| path,
            .entity => null,
        },
        .ambiguous => return null,
        .none => {},
    }
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

/// The standard declaration a bare, unclaimed name stands for, or null when
/// something already claims the name.
///
/// A name this crate binds is never a prelude name. siphasher imports
/// `core::hash::Hasher as _` beside its own `struct Hasher<S>`, and the local
/// one has to keep answering for `Hasher`; Rust's rule is the same, since an
/// item in scope outranks the prelude.
fn preludeBareName(e: *const Ext, name: []const u8) ?[]const []const u8 {
    if (resolveName(e, name) != null) return null;
    return preludeExternalPath(name);
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
    // A block-local import is the innermost binding for its name, so it
    // outranks both the prelude entry below and a module import. Consulting it
    // first is what makes a body-local `use std::string::String;` mean that
    // path, rather than the `alloc::string::String` the prelude supplies for a
    // name no module binds.
    prefix = blockImportPath(e, parts[0]) orelse prefix;
    if (prefix.len == 0) {
        // A name the module itself imports is the import's: an explicit `use`
        // shadows the prelude, which is Rust's own rule and the reason
        // `use std::collections::HashMap;` keeps meaning that map.
        if (part_count == 1) {
            prefix = (try externalUsePath(e, parts[0])) orelse
                preludeBareName(e, parts[0]) orelse return null;
        } else if (preludeBareName(e, parts[0])) |prelude| {
            prefix = prelude;
        } else if (!std.mem.eql(u8, parts[0], "core") and
            !std.mem.eql(u8, parts[0], "std") and
            !std.mem.eql(u8, parts[0], "alloc"))
        {
            prefix = (try externalUsePath(e, parts[0])) orelse return null;
        }
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
    // A block-local `use` is the innermost binding for its name, so a module
    // item of the same name does not outrank it: the guard below exists to
    // leave a head that still resolves locally alone, and a block import is not
    // local scope.
    switch (blockImportBinding(e, segs[0].name)) {
        .none => if (resolveModuleItem(e, module_id, segs[0].name) != null) return null,
        .bound, .ambiguous => {},
    }
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
    const callee = valueChild(node, 0) orelse return null;
    if (!std.mem.eql(u8, callee.kind(), "field_expression")) return null;
    const method = valueChild(callee, 1) orelse return null;
    return text(e, method);
}

/// The receiver (`recv`) of a `recv.method(...)` call node, or null.
fn receiverOf(node: ts.Node) ?ts.Node {
    if (!std.mem.eql(u8, node.kind(), "call_expression")) return null;
    const callee = valueChild(node, 0) orelse return null;
    if (!std.mem.eql(u8, callee.kind(), "field_expression")) return null;
    return valueChild(callee, 0);
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
        // `parameter.pattern` is a grammar FIELD, and its wildcard case is
        // the ANONYMOUS `_` token — `namedChild` never returns it, so the walk
        // below cannot see `|_: ()|` at all and a TYPED parameter lost its
        // slot. Reading the field keeps the token; the named walk stays as
        // the fallback for a revision that carries no field. `self_parameter`
        // has no `pattern` field, so it still falls through unchanged.
        if (node.childByFieldName("pattern")) |pattern| return pattern;
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

// Only known runtime owners qualify; references and unconstrained T stay borrowed.
fn ownedCaptureContainerType(ty: types.Type) bool {
    switch (ty) {
        .boxed => return true,
        .external_nominal => |external| {
            return externalPathSlicesEqual(external.path, &.{ "alloc", "string", "String" }) or
                externalPathSlicesEqual(external.path, &.{ "std", "string", "String" }) or
                externalPathSlicesEqual(external.path, &.{ "alloc", "string", "FromUtf8Error" }) or
                externalPathSlicesEqual(external.path, &.{ "std", "string", "FromUtf8Error" }) or
                externalPathSlicesEqual(external.path, &.{ "alloc", "vec", "Vec" }) or
                externalPathSlicesEqual(external.path, &.{ "alloc", "borrow", "Cow" }) or
                externalPathSlicesEqual(external.path, &.{ "std", "borrow", "Cow" });
        },
        else => return false,
    }
}

fn patternBindsByValue(e: *const Ext, pattern_id: exprs.NodeId) bool {
    if (pattern_id >= e.ctx.pats.items.len) return false;
    return switch (e.ctx.pats.items[pattern_id].kind) {
        .binding => |binding| binding.mode == .value,
        .tuple => |tuple| patternsBindByValue(e, tuple.elements),
        .@"or" => |alternatives| patternsBindByValue(e, alternatives.alternatives),
        .struct_pat => |structure| fieldsBindByValue(e, structure.fields),
        .external_variant => |variant| fieldsBindByValue(e, variant.fields),
        .slice => |slice| patternsBindByValue(e, slice.elements) or
            (if (slice.rest) |rest| patternBindsByValue(e, rest) else false),
        else => false,
    };
}

fn blockConsumesBinding(e: *const Ext, block: exprs.BlockExpr, def: spine.EntityId) bool {
    for (block.statements) |stmt_id| {
        if (stmt_id >= e.ctx.stmts.items.len) continue;
        switch (e.ctx.stmts.items[stmt_id].kind) {
            .let => |declaration| {
                const init = declaration.init orelse continue;
                if (expressionConsumesBinding(e, init, def, patternBindsByValue(e, declaration.pattern))) return true;
            },
            .expr => |expr_id| {
                if (valueConsumesBinding(e, expr_id, def)) return true;
            },
            else => {},
        }
    }
    const tail = block.tail orelse return false;
    return valueConsumesBinding(e, tail, def);
}

fn valueConsumesBinding(e: *const Ext, expr_id: exprs.NodeId, def: spine.EntityId) bool {
    return expressionConsumesBinding(e, expr_id, def, true);
}

fn expressionConsumesBinding(e: *const Ext, expr_id: exprs.NodeId, def: spine.EntityId, by_value: bool) bool {
    if (expr_id >= e.ctx.exprs.items.len) return false;
    switch (e.ctx.exprs.items[expr_id].kind) {
        .path => |path| return by_value and path.def == def,
        .block => |block| return blockConsumesBinding(e, block, def),
        .array => |array| {
            for (array.elements) |element| {
                if (valueConsumesBinding(e, element, def)) return true;
            }
        },
        .vec_lit => |literal| {
            for (literal.elements) |element| {
                if (valueConsumesBinding(e, element, def)) return true;
            }
            // `vec![e; n]` evaluates `n` as an ordinary expression after `e`,
            // so a binding the count reads is consumed here too — and a count
            // that moves one out of it is the same move the elements would be.
            if (literal.repeat) |repeat| switch (repeat) {
                .expression => |count| {
                    if (valueConsumesBinding(e, count, def)) return true;
                },
                .literal => {},
            };
        },
        .struct_lit => |structure| {
            for (structure.fields) |field| {
                if (valueConsumesBinding(e, field.value, def)) return true;
            }
        },
        .enum_variant => |variant| {
            for (variant.tuple_fields) |field| {
                if (valueConsumesBinding(e, field, def)) return true;
            }
            for (variant.named_fields) |field| {
                if (valueConsumesBinding(e, field.value, def)) return true;
            }
        },
        .external_variant => |variant| {
            for (variant.tuple_fields) |field| {
                if (valueConsumesBinding(e, field, def)) return true;
            }
            for (variant.named_fields) |field| {
                if (valueConsumesBinding(e, field.value, def)) return true;
            }
        },
        .call => |call| {
            for (call.args) |argument| {
                if (valueConsumesBinding(e, argument, def)) return true;
            }
        },
        .core_call => |call| {
            for (call.args) |argument| {
                if (valueConsumesBinding(e, argument, def)) return true;
            }
        },
        .method_call => |method| {
            if (expressionConsumesBinding(e, method.receiver, def, methodConsumesOwnedReceiver(e, method))) return true;
            for (method.args) |argument| {
                if (valueConsumesBinding(e, argument, def)) return true;
            }
        },
        .cast => |cast| return valueConsumesBinding(e, cast.operand, def),
        .try_ => |tried| return valueConsumesBinding(e, tried.inner, def),
        .return_ => |returned| {
            const value = returned.value orelse return false;
            return valueConsumesBinding(e, value, def);
        },
        .break_ => |brk| {
            const value = brk.value orelse return false;
            return valueConsumesBinding(e, value, def);
        },
        .assign => |assignment| return valueConsumesBinding(e, assignment.value, def),
        .if_else => |conditional| {
            if (expressionConsumesBinding(e, conditional.cond, def, false)) return true;
            if (blockConsumesBinding(e, conditional.then_, def)) return true;
            return elseBranchConsumesBinding(e, conditional.@"else", def);
        },
        .if_let => |conditional| {
            if (expressionConsumesBinding(e, conditional.scrutinee, def, patternBindsByValue(e, conditional.pattern))) return true;
            if (blockConsumesBinding(e, conditional.then_, def)) return true;
            return elseBranchConsumesBinding(e, conditional.@"else", def);
        },
        .loop_ => |loop| return blockConsumesBinding(e, loop.body, def),
        .while_ => |loop| return expressionConsumesBinding(e, loop.cond, def, false) or
            blockConsumesBinding(e, loop.body, def),
        .for_ => |loop| return expressionConsumesBinding(e, loop.iterable, def, false) or
            blockConsumesBinding(e, loop.body, def),
        .match => |arms| {
            for (arms.arms) |arm| {
                if (expressionConsumesBinding(e, arms.scrutinee, def, patternsBindByValue(e, arm.patterns))) return true;
                if (arm.guard) |guard| {
                    if (expressionConsumesBinding(e, guard, def, false)) return true;
                }
                if (valueConsumesBinding(e, arm.body, def)) return true;
            }
        },
        .field => |field| return expressionConsumesBinding(e, field.base, def, false),
        .index => |index| return expressionConsumesBinding(e, index.base, def, false) or
            expressionConsumesBinding(e, index.index, def, false),
        .unary => |unary| return expressionConsumesBinding(e, unary.operand, def, false),
        .binary => |binary| {
            const takes_left = binary.op == .add and isKnownStringOperand(e, binary.lhs);
            return expressionConsumesBinding(e, binary.lhs, def, takes_left) or
                expressionConsumesBinding(e, binary.rhs, def, false);
        },
        .iterator_chain => |chain| return expressionConsumesBinding(e, chain.source, def, false),
        .format_write => |format| {
            if (expressionConsumesBinding(e, format.writer, def, false)) return true;
            for (format.args) |argument| {
                if (expressionConsumesBinding(e, argument, def, false)) return true;
            }
        },
        .literal,
        .range,
        .unit,
        .core_function,
        .panic_,
        .unsupported,
        .closure,
        .continue_,
        => {},
    }
    return false;
}

fn elseBranchConsumesBinding(e: *const Ext, branch: exprs.ElseBranch, def: spine.EntityId) bool {
    return switch (branch) {
        .none => false,
        .block => |block| blockConsumesBinding(e, block, def),
        .chain => |chained| valueConsumesBinding(e, chained, def),
    };
}
fn patternsBindByValue(e: *const Ext, patterns: []const exprs.NodeId) bool {
    for (patterns) |pattern| {
        if (patternBindsByValue(e, pattern)) return true;
    }
    return false;
}

fn fieldsBindByValue(e: *const Ext, fields: []const exprs.FieldPat) bool {
    for (fields) |field| {
        if (field.pat) |pattern| {
            if (patternBindsByValue(e, pattern)) return true;
        } else if (field.shorthand) return true;
    }
    return false;
}

fn isKnownStringOperand(e: *const Ext, id: exprs.NodeId) bool {
    if (id >= e.ctx.exprs.items.len or e.ctx.exprs.items[id].kind != .path) return false;
    const ty = localType(e, e.ctx.exprs.items[id].kind.path.def) orelse return false;
    if (ty != .external_nominal) return false;
    return externalPathSlicesEqual(ty.external_nominal.path, &.{ "alloc", "string", "String" }) or
        externalPathSlicesEqual(ty.external_nominal.path, &.{ "std", "string", "String" });
}

// These consuming receivers match the existing finite standard-library signatures.
// Extraction has not resolved receiver_mode yet; `String::len` must stay a borrow.
fn methodConsumesOwnedReceiver(e: *const Ext, method: exprs.MethodCall) bool {
    if (method.receiver >= e.ctx.exprs.items.len or e.ctx.exprs.items[method.receiver].kind != .path) return false;
    const ty = localType(e, e.ctx.exprs.items[method.receiver].kind.path.def) orelse return false;
    if (ty != .external_nominal) return false;
    const external = ty.external_nominal;
    if (external.path.len != 3 or
        (!std.mem.eql(u8, external.path[0], "alloc") and !std.mem.eql(u8, external.path[0], "std"))) return false;
    const entity = e.ctx.g.symbol_table.get(method.method) orelse return false;
    if (std.mem.eql(u8, external.path[1], "string") and std.mem.eql(u8, external.path[2], "String"))
        return std.mem.eql(u8, entity.name, "into_bytes");
    if (std.mem.eql(u8, external.path[1], "borrow") and std.mem.eql(u8, external.path[2], "Cow"))
        return std.mem.eql(u8, entity.name, "into_owned");
    if (std.mem.eql(u8, external.path[1], "vec") and std.mem.eql(u8, external.path[2], "Vec"))
        return std.mem.eql(u8, entity.name, "into_iter");
    return false;
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
        if (isBlockTrivia(child)) continue;
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
    var consumed = false;
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
        const body_takes_it = ownedCaptureContainerType(capture_type) and
            blockConsumesBinding(e, body_block, outer_local.def);
        if (body_takes_it) consumed = true;
        const by_value = capture_mode == .by_value or body_takes_it;
        try captures.append(e.ctx.alloc, .{
            .name = capture_entity.name,
            .mode = if (mutated and !by_value) .by_mut_ref else if (by_value) .by_value else .by_ref,
            .ty = capture_type_id,
        });
    }
    if (consumed) closure_trait = .fn_once;

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

            if (std.mem.eql(u8, name, "copied")) {
                // `xs.iter().copied()` hands out the elements themselves, and
                // that is what a Zig `for` over `xs` already binds. Keeping the
                // iterator would bind a borrow per element instead, and every
                // use of the element against its own type would then fail.
                const copied_recv = receiverOf(node);
                if (copied_recv) |recv| {
                    const iter_call = peelParenthesized(recv);
                    if (std.mem.eql(u8, iter_call.kind(), "call_expression")) {
                        if (methodNameOf(e, iter_call)) |iter_name| {
                            if (std.mem.eql(u8, iter_name, "iter") or
                                std.mem.eql(u8, iter_name, "iter_mut"))
                            {
                                const iter_recv = receiverOf(iter_call) orelse
                                    return error.MalformedCst;
                                return unwrapIterable(e, iter_recv);
                            }
                        }
                    }
                }
                // Anything else — a `copied()` further along a chain, or over
                // something that is not an iterator at all — is NOT a
                // malformed iterable, and this arm used to say it was: it
                // returned an error that abandoned the whole extraction on
                // source which compiles. It falls through to the ordinary
                // lowering below, which is where this receiver was already
                // being read before, so a form this code can make sense of
                // still gets made sense of and only one it cannot becomes the
                // typed `unsupported` marker that lowering produces.
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
/// The item a `for` over a container binds, or null when the carrier says
/// nothing about its elements.
///
/// A standard container answers from its own type argument, and a BORROW of one
/// answers with a borrow of that element — which is exactly what
/// `for entry in &values` binds, and the only thing in the source that says so.
/// Without it the loop's binding has no type at all, and every use of an element
/// in the body — projecting it, measuring it, casting it — starts from nothing.
fn iteratorCarrierItem(e: *const Ext, ty: types.Type) ?types.Type {
    switch (ty) {
        .reference => |reference| {
            const element = iteratorCarrierItem(e, reference.pointee) orelse return null;
            const borrow = e.ctx.alloc.create(types.Ref) catch return null;
            borrow.* = .{ .mut = reference.mut, .pointee = element };
            return .{ .reference = borrow };
        },
        .external_nominal => |external| {
            if (external.path.len != 3 or external.args.len != 1) return null;
            if (!std.mem.eql(u8, external.path[0], "alloc")) return null;
            if (!std.mem.eql(u8, external.path[1], "vec")) return null;
            if (!std.mem.eql(u8, external.path[2], "Vec")) return null;
            return external.args[0];
        },
        else => return null,
    }
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
        // `'outer:` is the first named child of a labelled `for`. It names the
        // loop, so it is neither the binding, nor the iterable, nor the body.
        if (isSourceLabelNode(c)) continue;
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

    // The iterable is evaluated BEFORE the loop binding exists, so it is
    // lowered first and every name it reads resolves against the enclosing
    // scope. Lowering the pattern first installs the capture through
    // `pushLocal`, and `resolveName` reverse-resolves a name to the most
    // recent local — so in `for buf in buf.chunks(4)` the ITERABLE RECEIVER
    // would bind to the capture rather than to the parameter, and the two
    // would be one entity from here on. That is invisible for a capture whose
    // name differs from its receiver's and fatal for the one that matches.
    // `lowerIf` orders its scrutinee the same way, for the same reason.
    const iter = iter_node orelse return error.MalformedCst;
    const it = try unwrapIterable(e, iter);
    const iter_eid = it.eid;

    // Every loop binding is in local scope before the body is lowered
    // (`lowerPattern` registers each binding via `pushLocal`, including tuple
    // and reference patterns).
    const pn = pat_node orelse return error.MalformedCst;
    const pat_id = try lowerPattern(e, pn);
    // A binding over a borrow of a standard container carries that carrier's
    // element, and the borrow the loop writes is the whole of what says so. A
    // slice or an array iterable is left to inference, which already reads its
    // element off the same node — only the carriers that answer nothing here are
    // given a type.
    if (knownCastOperandType(e, iter_eid)) |iterable_ty| {
        switch (iterable_ty) {
            .reference, .external_nominal => if (iteratorCarrierItem(e, iterable_ty)) |item| {
                setPatternLocalTypes(e, pat_id, item);
            },
            else => {},
        }
    }

    const body = body_node orelse return error.MalformedCst;
    // The label belongs to the loop, and the backend reads a loop's label off
    // the block its body is, so it is recorded there.
    var body_blk = try lowerBlock(e, body);
    body_blk.labelled = try controlLabel(e, node);

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

/// The first named child that carries a value, stepping over lexical trivia.
///
/// Tree-sitter attaches `extras` — `//` and `/* */` comments among them — to
/// the node whose span contains them, so a comment written between two
/// operands, between a receiver and its field, or between two call arguments
/// is a named child of that node. A positional read has to step over it: the
/// comment is not an expression, and handing it to `lowerExpr` refuses the
/// whole translation with the comment's own node kind as the reason.
fn firstValueChild(node: ts.Node) ?ts.Node {
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (isBlockTrivia(child)) continue;
        return child;
    }
    return null;
}

/// The `index`-th named child that carries a value. A node with two operands
/// either side of an unnamed token — a receiver and its field, a base and its
/// subscript — is read positionally, and one that does not have that many
/// values is malformed, which stays the caller's answer to give.
fn valueChild(node: ts.Node, index: u32) ?ts.Node {
    var seen: u32 = 0;
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (isBlockTrivia(child)) continue;
        if (seen == index) return child;
        seen += 1;
    }
    return null;
}

/// The last named child that carries a value. An operator token is unnamed, so
/// for a node with two named children this is the right operand.
fn lastValueChild(node: ts.Node) ?ts.Node {
    var found: ?ts.Node = null;
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (isBlockTrivia(child)) continue;
        found = child;
    }
    return found;
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

/// The name a block-local helper is declared under in the emitted package.
///
/// Zig has no nested functions, so the helper is hoisted to module scope,
/// where its source name no longer identifies it: two tests may each define
/// `read`, and one function may define that name in two separate blocks. The
/// dense entity id is assigned in source order, so it names the helper stably
/// and without collision — the same device `__r2z_static_` uses for a
/// function-local `static`.
fn localFnEntityName(
    alloc: std.mem.Allocator,
    entity_id: spine.EntityId,
    source_name: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(alloc, "__r2z_localfn_{d}_{s}", .{ entity_id, source_name });
}

/// Whether a CST node can carry the declared type of a parameter.
fn isParameterTypeNodeKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "type") or
        std.mem.eql(u8, kind, "primitive_type") or
        std.mem.eql(u8, kind, "reference_type") or
        std.mem.eql(u8, kind, "pointer_type") or
        std.mem.eql(u8, kind, "generic_type") or
        std.mem.eql(u8, kind, "type_identifier") or
        std.mem.eql(u8, kind, "scoped_type_identifier") or
        std.mem.eql(u8, kind, "array_type") or
        std.mem.eql(u8, kind, "slice_type") or
        std.mem.eql(u8, kind, "tuple_type") or
        std.mem.eql(u8, kind, "unit_type") or
        std.mem.eql(u8, kind, "abstract_type") or
        std.mem.eql(u8, kind, "dynamic_type") or
        std.mem.eql(u8, kind, "bounded_type");
}

fn collectCstPatternNames(
    e: *const Ext,
    node: ts.Node,
    out: *std.ArrayListUnmanaged([]const u8),
) anyerror!void {
    if (std.mem.eql(u8, node.kind(), "identifier")) {
        try out.append(e.ctx.alloc, text(e, node));
    }
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        try collectCstPatternNames(e, child, out);
    }
}

/// A parameter whose pattern has no single plain identifier binds under a
/// synthetic name, chosen so it can never collide with a name the pattern
/// itself introduces.
fn syntheticLocalFnParamName(
    e: *Ext,
    ordinal: usize,
    source_names: []const []const u8,
) anyerror![]const u8 {
    var candidate = try std.fmt.allocPrint(e.ctx.alloc, "__r2z_param_{d}", .{ordinal});
    while (true) {
        var collision = false;
        for (source_names) |source_name| {
            if (std.mem.eql(u8, candidate, source_name)) {
                collision = true;
                break;
            }
        }
        if (!collision) return candidate;
        const extended = try std.fmt.allocPrint(e.ctx.alloc, "{s}_", .{candidate});
        e.ctx.alloc.free(candidate);
        candidate = extended;
    }
}

/// Map a block-local helper's parameter list. A `fn` item has no receiver, so
/// only value parameters appear here.
fn mapLocalFnParams(e: *Ext, params_node: ?ts.Node) anyerror![]const items.Param {
    const pn = params_node orelse return &.{};
    var params: std.ArrayListUnmanaged(items.Param) = .empty;
    errdefer params.deinit(e.ctx.alloc);
    var source_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer source_names.deinit(e.ctx.alloc);

    var j: u32 = 0;
    while (pn.namedChild(j)) |p| : (j += 1) {
        if (!std.mem.eql(u8, p.kind(), "parameter")) continue;
        const pattern = paramPatternNode(p) orelse continue;
        try collectCstPatternNames(e, pattern, &source_names);
    }

    var ordinal: usize = 0;
    j = 0;
    while (pn.namedChild(j)) |p| : (j += 1) {
        if (!std.mem.eql(u8, p.kind(), "parameter")) continue;
        var pname: ?[]const u8 = null;
        var synthetic = false;
        var pty: ?types.Type = null;
        var k: u32 = 0;
        while (p.namedChild(k)) |c| : (k += 1) {
            const kk = c.kind();
            if (std.mem.eql(u8, kk, "identifier")) {
                if (pname == null) pname = text(e, c);
            } else if (isParameterTypeNodeKind(kk)) {
                pty = try mapCstType(e, c);
            }
        }
        if (paramPatternNode(p)) |pattern_node| {
            pname = plainParamName(e, pattern_node);
        }
        if (pname == null) {
            pname = try syntheticLocalFnParamName(e, ordinal, source_names.items);
            synthetic = true;
        }
        ordinal += 1;
        const param_name = pname orelse return error.MalformedParameter;
        const param_ty = pty orelse return error.MalformedParameter;
        try params.append(e.ctx.alloc, .{
            .name = if (synthetic) param_name else try e.ctx.alloc.dupe(u8, param_name),
            .ty = param_ty,
            .span = span_of,
        });
    }
    return params.toOwnedSlice(e.ctx.alloc);
}

/// The type node attached to a helper's `-> T` clause, or null when it returns
/// unit. The grammar exposes `return_type` as a field and older revisions
/// spell it as a node kind, so both are accepted.
fn localFnReturnTypeNode(node: ts.Node) ?ts.Node {
    if (node.childByFieldName("return_type")) |ret| return ret;
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), "return_type")) return child;
    }
    return null;
}

/// A helper's own type parameters (`fn pick<T>(..)`). Its body may name them
/// and, being its own item, no enclosing function contributes any.
fn localFnGenericParams(e: *Ext, node: ts.Node) anyerror![]const []const u8 {
    var params: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer params.deinit(e.ctx.alloc);
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (!std.mem.eql(u8, child.kind(), "type_parameters")) continue;
        var j: u32 = 0;
        while (child.namedChild(j)) |parameter| : (j += 1) {
            if (!std.mem.eql(u8, parameter.kind(), "type_parameter")) continue;
            var name: []const u8 = "";
            var k: u32 = 0;
            while (parameter.namedChild(k)) |parameter_child| : (k += 1) {
                if (std.mem.eql(u8, parameter_child.kind(), "type_identifier")) {
                    name = text(e, parameter_child);
                    break;
                }
            }
            if (name.len == 0) continue;
            try params.append(e.ctx.alloc, try e.ctx.alloc.dupe(u8, name));
        }
    }
    return params.toOwnedSlice(e.ctx.alloc);
}

/// One declared block-local helper: its source binding name and its entity.
const LocalFnDecl = struct { name: []const u8, def: spine.EntityId };

/// Declare one block-local `fn` item.
///
/// The item becomes a `.fn_` entity parented to the enclosing callable, with
/// its own `FnBody`, plus a lexical binding of its source name in this block.
/// It is deliberately absent from every module's `items`, so a module-global
/// lookup can never reach it: only the block that declared it and the blocks
/// nested inside that one can name it. The entity carries the emitted identity
/// rather than the source name, because the helper is declared at module
/// scope where the source name may already be taken.
///
/// The body is lowered separately, after every item of the block is declared,
/// so a call may name an item written below it.
///
/// The signature is complete: parameter types, return type, the type parameter
/// names its body may use, and the full `generics` metadata — per-parameter
/// bounds and `where` clauses — read through the same parser and the same
/// `types.Generics` shape a module-level `fn` gets. A helper is a real item
/// with a real signature, so `R: ?Sized + io::Read` on one authorises exactly
/// what it authorises on any other function.
fn declareLocalFn(e: *Ext, node: ts.Node) anyerror!LocalFnDecl {
    const name = functionNodeName(e.ctx, node) orelse return error.MalformedLocalFunctionName;
    var params_node: ?ts.Node = null;
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), "parameters")) params_node = child;
    }
    const generic_params = try localFnGenericParams(e, node);

    // The entity and its body row are appended first: the signature resolves a
    // name the helper OWNS — its own type parameter — against that row, so it
    // has to exist before the signature is mapped. The row's body id stays 0,
    // which is the frontend-wide "not lowered yet" placeholder.
    const entity_id: spine.EntityId = @intCast(e.ctx.g.symbol_table.entities.items.len);
    _ = try e.ctx.g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try localFnEntityName(e.ctx.alloc, entity_id, name),
        .span = span_of,
        .visibility = .private,
        .parent = e.fn_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try e.ctx.bodies_list.append(e.ctx.alloc, .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .generic_params = generic_params,
        .generics = null,
        .body = 0,
    } });

    // A signature is written in the enclosing block's scope, but the helper is
    // the owner from here on, which is what makes its own `T` resolve.
    var signature: Ext = .{
        .ctx = e.ctx,
        .fn_id = entity_id,
        .item_scope = e.item_scope,
        .block_imports = e.block_imports,
        .block_depth = e.block_depth,
    };
    defer signature.deinit();
    const params = try mapLocalFnParams(&signature, params_node);
    const ret: types.Type = if (localFnReturnTypeNode(node)) |ret_node|
        try mapCstType(&signature, ret_node)
    else
        .{ .prim = .unit };

    const generics = try collectCstGenerics(&signature, node);
    e.ctx.bodies_list.items[entity_id] = .{ .fn_ = .{
        .params = params,
        .ret = ret,
        .generic_params = generic_params,
        .generics = generics,
        .body = 0,
    } };
    try e.locals.append(e.ctx.alloc, .{ .name = name, .def = entity_id });
    return .{ .name = name, .def = entity_id };
}

/// Compile-time imports stay in their declaring block; source bytes are borrowed.
fn blockImportBinding(e: *const Ext, name: []const u8) BlockImportBinding {
    var best_depth: ?usize = null;
    var bound: ?BlockImportTarget = null;
    var duplicate = false;
    for (e.block_imports) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        if (best_depth == null or entry.block_depth > best_depth.?) {
            best_depth = entry.block_depth;
            bound = entry.target;
            duplicate = false;
            continue;
        }
        if (entry.block_depth == best_depth.?) duplicate = true;
    }
    if (duplicate) return .ambiguous;
    const found = bound orelse return .none;
    return .{ .bound = found };
}

fn blockImportPath(e: *const Ext, name: []const u8) ?[]const []const u8 {
    return switch (blockImportBinding(e, name)) {
        .bound => |target| switch (target) {
            .external => |path| path,
            .entity => null,
        },
        .none, .ambiguous => null,
    };
}

fn isCanonicalImportRoot(root: []const u8) bool {
    return std.mem.eql(u8, root, "std") or
        std.mem.eql(u8, root, "alloc") or
        std.mem.eql(u8, root, "core");
}

fn lastPathSegment(raw: []const u8) []const u8 {
    var source = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, source, "::")) source = source[2..];
    const separator = std.mem.lastIndexOf(u8, source, "::") orelse return source;
    return std.mem.trim(u8, source[separator + 2 ..], " \t\r\n");
}

fn freeImportSegments(alloc: std.mem.Allocator, segments: []const []const u8) void {
    alloc.free(segments);
}

fn freeBlockImportTarget(alloc: std.mem.Allocator, target: BlockImportTarget) void {
    switch (target) {
        .entity => {},
        .external => |path| freeImportSegments(alloc, path),
    }
}

fn blockImportSegments(
    e: *Ext,
    prefix: []const []const u8,
    raw: []const u8,
) !?[]const []const u8 {
    var parts: [16][]const u8 = undefined;
    var count: usize = 0;
    var source = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, source, "::")) source = source[2..];
    if (source.len == 0) return null;
    var iterator = std.mem.splitSequence(u8, source, "::");
    while (iterator.next()) |part| {
        const name = std.mem.trim(u8, part, " \t\r\n");
        if (name.len == 0 or count == parts.len) return null;
        parts[count] = name;
        count += 1;
    }
    const owned = try e.ctx.alloc.alloc([]const u8, prefix.len + count);
    @memcpy(owned[0..prefix.len], prefix);
    @memcpy(owned[prefix.len..], parts[0..count]);
    return owned;
}

fn dupeImportSegments(
    e: *Ext,
    segments: []const []const u8,
) ![]const []const u8 {
    const owned = try e.ctx.alloc.alloc([]const u8, segments.len);
    @memcpy(owned, segments);
    return owned;
}

fn blockImportEntity(e: *const Ext, path: []const []const u8) ?spine.EntityId {
    const module_id = owningModule(e, e.fn_id) orelse return null;
    var lookups: UseLookupPath = .{};
    defer lookups.deinit(e.ctx.alloc);
    return resolveUsePathSegments(e, module_id, path, 0, &lookups);
}

const UseScan = struct {
    imports: std.ArrayListUnmanaged(BlockImport) = .empty,
    refused: bool = false,

    fn deinit(self: *UseScan, alloc: std.mem.Allocator) void {
        for (self.imports.items) |entry| freeBlockImportTarget(alloc, entry.target);
        self.imports.deinit(alloc);
        self.* = undefined;
    }
};

fn appendBlockImport(
    e: *Ext,
    scan: *UseScan,
    name: []const u8,
    target: BlockImportTarget,
    depth: usize,
) anyerror!void {
    errdefer freeBlockImportTarget(e.ctx.alloc, target);
    try scan.imports.append(e.ctx.alloc, .{
        .name = name,
        .target = target,
        .block_depth = depth,
    });
}

fn bindBlockImportLeaf(
    e: *Ext,
    name: []const u8,
    prefix: []const []const u8,
    raw: []const u8,
    depth: usize,
    scan: *UseScan,
) anyerror!void {
    const segments = (try blockImportSegments(e, prefix, raw)) orelse {
        scan.refused = true;
        return;
    };
    if (isCanonicalImportRoot(segments[0])) {
        try appendBlockImport(e, scan, name, .{ .external = segments }, depth);
        return;
    }
    const def = blockImportEntity(e, segments);
    freeImportSegments(e.ctx.alloc, segments);
    if (def == null) {
        scan.refused = true;
        return;
    }
    try appendBlockImport(e, scan, name, .{ .entity = def.? }, depth);
}

fn bindBlockImportSelf(
    e: *Ext,
    prefix: []const []const u8,
    depth: usize,
    scan: *UseScan,
) anyerror!void {
    if (prefix.len == 0) {
        scan.refused = true;
        return;
    }
    const leaf = prefix[prefix.len - 1];
    if (isCanonicalImportRoot(prefix[0])) {
        const owned = try dupeImportSegments(e, prefix);
        try appendBlockImport(e, scan, leaf, .{ .external = owned }, depth);
        return;
    }
    const def = blockImportEntity(e, prefix) orelse {
        scan.refused = true;
        return;
    };
    try appendBlockImport(e, scan, leaf, .{ .entity = def }, depth);
}

fn collectBlockUseClause(
    e: *Ext,
    node: ts.Node,
    prefix: []const []const u8,
    depth: usize,
    scan: *UseScan,
) anyerror!void {
    if (scan.refused) return;
    if (isComment(node)) return;
    const k = node.kind();
    if (std.mem.eql(u8, k, "visibility_modifier")) return;

    if (std.mem.eql(u8, k, "scoped_use_list")) {
        var path_node: ?ts.Node = null;
        var list_node: ?ts.Node = null;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            const ck = c.kind();
            if (std.mem.eql(u8, ck, "use_list")) {
                list_node = c;
            } else if (path_node == null) {
                path_node = c;
            }
        }
        const list = list_node orelse {
            scan.refused = true;
            return;
        };
        if (path_node) |pn| {
            const folded = (try blockImportSegments(e, prefix, text(e, pn))) orelse {
                scan.refused = true;
                return;
            };
            defer freeImportSegments(e.ctx.alloc, folded);
            try collectBlockUseClause(e, list, folded, depth, scan);
        } else {
            try collectBlockUseClause(e, list, prefix, depth, scan);
        }
    } else if (std.mem.eql(u8, k, "use_list")) {
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            try collectBlockUseClause(e, c, prefix, depth, scan);
            if (scan.refused) return;
        }
    } else if (std.mem.eql(u8, k, "use_as_clause")) {
        var path_child: ?ts.Node = null;
        var alias_child: ?ts.Node = null;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            if (path_child == null) path_child = c else if (alias_child == null) alias_child = c;
        }
        const pc = path_child orelse {
            scan.refused = true;
            return;
        };
        const ac = alias_child orelse {
            scan.refused = true;
            return;
        };
        const alias = std.mem.trim(u8, text(e, ac), " \t\r\n");
        if (alias.len == 0 or std.mem.eql(u8, alias, "self") or
            std.mem.eql(u8, alias, "crate") or std.mem.eql(u8, alias, "super"))
        {
            scan.refused = true;
            return;
        }
        if (std.mem.eql(u8, std.mem.trim(u8, text(e, pc), " \t\r\n"), "self")) {
            scan.refused = true;
            return;
        }
        try bindBlockImportLeaf(e, alias, prefix, text(e, pc), depth, scan);
    } else if (std.mem.eql(u8, k, "use_wildcard")) {
        scan.refused = true;
    } else if (std.mem.eql(u8, k, "self")) {
        try bindBlockImportSelf(e, prefix, depth, scan);
    } else if (std.mem.eql(u8, k, "identifier") or
        std.mem.eql(u8, k, "scoped_identifier") or
        std.mem.eql(u8, k, "crate") or
        std.mem.eql(u8, k, "super"))
    {
        const raw = std.mem.trim(u8, text(e, node), " \t\r\n");
        if (std.mem.eql(u8, raw, "self")) {
            scan.refused = true;
            return;
        }
        try bindBlockImportLeaf(e, lastPathSegment(raw), prefix, raw, depth, scan);
    } else {
        scan.refused = true;
    }
}

fn collectBlockUseDeclaration(
    e: *Ext,
    node: ts.Node,
    depth: usize,
    scan: *UseScan,
) anyerror!void {
    var clauses: usize = 0;
    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        if (isComment(c)) continue;
        const k = c.kind();
        if (std.mem.eql(u8, k, "visibility_modifier")) continue;
        clauses += 1;
        try collectBlockUseClause(e, c, &.{}, depth, scan);
        if (scan.refused) return;
    }
    if (clauses == 0) scan.refused = true;
}

/// Lower one declared block-local helper:
///
/// A helper is a separate Rust item and does not capture the enclosing
/// function's `let` bindings, so it gets its own `Ext` carrying only the item
/// scope. Its own block declares the helpers nested inside it in turn.
///
/// The body id written here is always a freshly appended `.block` expression —
/// `lowerBlock` allocates one even for an empty body — so it is never the 0
/// that marks "not lowered yet". That is how the extraction driver tells a
/// helper that is already lowered from one that still needs its body read.
fn lowerLocalFnBody(e: *Ext, node: ts.Node, entity_id: spine.EntityId) anyerror!void {
    var block: ?ts.Node = null;
    var params_node: ?ts.Node = null;
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        const k = child.kind();
        if (std.mem.eql(u8, k, "block")) block = child;
        if (std.mem.eql(u8, k, "parameters")) params_node = child;
    }
    const blk_node = block orelse return error.MalformedLocalFunctionBody;

    // The enclosing block's imports come along, and are BORROWED: the block
    // that owns them outlives this call, because a helper is lowered in place
    // while the body that declares it is read. A helper does not capture the
    // enclosing function's `let` bindings, but a `use` is an ITEM, and an item
    // is in scope for the whole block that declares it.
    var nested: Ext = .{
        .ctx = e.ctx,
        .fn_id = entity_id,
        .item_scope = e.item_scope,
        .block_imports = e.block_imports,
        .block_depth = e.block_depth,
    };
    defer nested.deinit();

    const params: []const items.Param = switch (e.ctx.bodies_list.items[entity_id]) {
        .fn_ => |body| body.params,
        else => return error.MalformedLocalFunctionBody,
    };
    var param_prelude: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
    defer param_prelude.deinit(e.ctx.alloc);
    if (params_node) |pn| {
        var p: u32 = 0;
        var param_index: usize = 0;
        while (pn.namedChild(p)) |pnode| : (p += 1) {
            if (!std.mem.eql(u8, pnode.kind(), "parameter")) continue;
            if (param_index >= params.len) return error.MalformedCst;
            try registerParamLocal(&nested, pnode, params[param_index], &param_prelude);
            param_index += 1;
        }
        if (param_index != params.len) return error.MalformedCst;
    }

    const body_expr = try lowerExpr(&nested, blk_node);
    if (param_prelude.items.len > 0) {
        switch (e.ctx.exprs.items[body_expr].kind) {
            .block => |*body| {
                const old_statements = body.statements;
                const merged = try e.ctx.alloc.alloc(
                    exprs.NodeId,
                    param_prelude.items.len + old_statements.len,
                );
                @memcpy(merged[0..param_prelude.items.len], param_prelude.items);
                @memcpy(merged[param_prelude.items.len..], old_statements);
                if (old_statements.len > 0) e.ctx.alloc.free(old_statements);
                body.statements = merged;
            },
            else => return error.MalformedCst,
        }
    }

    var fn_body = switch (e.ctx.bodies_list.items[entity_id]) {
        .fn_ => |body| body,
        else => return error.MalformedLocalFunctionBody,
    };
    fn_body.body = body_expr;
    e.ctx.bodies_list.items[entity_id] = .{ .fn_ = fn_body };
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

    // A `use` written in a body is an item too, so it is in scope for the whole
    // block that writes it: the statements ABOVE it, the helpers beside it, and
    // nothing outside. The bindings are installed before any of this block is
    // lowered — before the helper signatures are mapped and before the first
    // statement runs — the same order `block_items` uses and for the same reason.
    //
    // A refused declaration keeps its node so the statement loop can place its
    // marker where the declaration is, as a statement of THIS block: a marker no
    // walker reaches is the silent omission this must never be.
    var refused_use_nodes: std.ArrayListUnmanaged(ts.Node) = .empty;
    defer refused_use_nodes.deinit(e.ctx.alloc);
    const outer_imports = e.block_imports;
    const outer_depth = e.block_depth;
    const import_depth = outer_depth + 1;
    // `scope` owns the entries past `outer_imports` and only those: the entries
    // it inherits are borrowed from the block that declared them. Released on
    // the normal and the error path alike.
    var owned_imports: ?[]BlockImport = null;
    defer if (owned_imports) |scope| {
        for (scope[outer_imports.len..]) |entry| freeBlockImportTarget(e.ctx.alloc, entry.target);
        e.ctx.alloc.free(scope);
    };
    {
        var collected: std.ArrayListUnmanaged(BlockImport) = .empty;
        defer {
            for (collected.items) |entry| freeBlockImportTarget(e.ctx.alloc, entry.target);
            collected.deinit(e.ctx.alloc);
        }
        var scan_use: u32 = 0;
        while (node.namedChild(scan_use)) |c| : (scan_use += 1) {
            if (isBlockTrivia(c)) continue;
            if (!std.mem.eql(u8, c.kind(), "use_declaration")) continue;
            // One `defer` per iteration, not an `errdefer` plus an explicit call:
            // this body can fail again after `scan.deinit` has already run.
            var scan: UseScan = .{};
            defer scan.deinit(e.ctx.alloc);
            try collectBlockUseDeclaration(e, c, import_depth, &scan);
            if (scan.refused) {
                try refused_use_nodes.append(e.ctx.alloc, c);
                continue;
            }
            try collected.appendSlice(e.ctx.alloc, scan.imports.items);
            // Ownership of these entries moves to `collected`; the scan's buffer
            // no longer holds them, so its `deinit` frees only the buffer.
            scan.imports.clearRetainingCapacity();
        }
        if (collected.items.len > 0) {
            const scope = try e.ctx.alloc.alloc(
                BlockImport,
                outer_imports.len + collected.items.len,
            );
            @memcpy(scope[0..outer_imports.len], outer_imports);
            @memcpy(scope[outer_imports.len..], collected.items);
            // The entries now live in `scope`, so this list must forget them
            // before its own `deinit` — which runs at the end of this scope,
            // while `scope` is still installed and still in use.
            collected.clearRetainingCapacity();
            owned_imports = scope;
            e.block_imports = scope;
        }
    }
    // Registered AFTER the release, so the restore runs FIRST: the field is never
    // left pointing at released memory, not even between two defers.
    defer e.block_imports = outer_imports;
    defer e.block_depth = outer_depth;
    e.block_depth = import_depth;

    // A Rust `fn` item is in scope for the whole block that declares it, so
    // every one of them is declared before the first statement runs. That is
    // what lets a call name an item written further down the block.
    var block_items: std.ArrayListUnmanaged(Local) = .empty;
    defer block_items.deinit(e.ctx.alloc);
    {
        var scan: u32 = 0;
        while (node.namedChild(scan)) |c| : (scan += 1) {
            if (isBlockTrivia(c)) continue;
            if (!std.mem.eql(u8, c.kind(), "function_item")) continue;
            const declared = try declareLocalFn(e, c);
            try block_items.append(e.ctx.alloc, .{
                .name = declared.name,
                .def = declared.def,
            });
        }
    }
    // A helper body sees the enclosing block's items, and nothing of the
    // enclosing block's `let` bindings. The extended scope has to outlive the
    // statement loop, so its lifetime is this function's: a `defer` inside the
    // `if` that installs it would run at the end of that `if`, restoring and
    // freeing the scope before the first statement is lowered.
    const outer_item_scope = e.item_scope;
    var block_scope: []const Local = &.{};
    defer {
        if (block_scope.len > 0) e.ctx.alloc.free(block_scope);
    }
    if (block_items.items.len > 0) {
        const scope = try e.ctx.alloc.alloc(Local, e.item_scope.len + block_items.items.len);
        @memcpy(scope[0..e.item_scope.len], e.item_scope);
        @memcpy(scope[e.item_scope.len..], block_items.items);
        block_scope = scope;
        e.item_scope = scope;
    }
    defer e.item_scope = outer_item_scope;
    var local_fn_ordinal: usize = 0;
    // Both lists are in source order and the loop walks children in source
    // order, so one cursor matches each refused declaration to its position.
    var refused_uses: usize = 0;

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
        } else if (std.mem.eql(u8, k, "function_item")) {
            if (local_fn_ordinal >= block_items.items.len) return error.MalformedCst;
            const declared = block_items.items[local_fn_ordinal];
            local_fn_ordinal += 1;
            const sid = try appendStmt(e, .{ .item = declared.def });
            try stmt_ids.append(e.ctx.alloc, sid);
            try lowerLocalFnBody(e, c, declared.def);
        } else if (std.mem.eql(u8, k, "use_declaration")) {
            // An admitted `use` binds a name and has no runtime effect, so it
            // contributes no statement. It is handled here, BEFORE the `is_last`
            // arms, so it can never become the block tail: a block that ends in
            // a `use` item is unit, which is what Rust says it is.
            //
            // A refused one replays its marker HERE rather than at the scan
            // above, so the marker is a statement of this block that validation,
            // the reachability walker and the backend all reach.
            if (refused_uses < refused_use_nodes.items.len and
                refused_use_nodes.items[refused_uses].id == c.id)
            {
                refused_uses += 1;
                const sid = try appendStmt(e, .{
                    .expr = try unsupported(e, "block-local use"),
                });
                try stmt_ids.append(e.ctx.alloc, sid);
            }
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

/// A node that only names the construct around it: `'outer` in front of a
/// loop, or after `break`/`continue`. It is never a value, a condition, or a
/// body, and lowering it as one either invents an operand a bare `break` does
/// not have or rejects the node as an unhandled construct.
fn isSourceLabelNode(node: ts.Node) bool {
    return std.mem.eql(u8, node.kind(), "label");
}

/// The source label a control construct carries, or null when it has none.
///
/// tree-sitter spells the node `label` and gives it NO field, so it is found
/// by its kind among the named children. The node text carries the apostrophe
/// it was written with, which is trimmed from BOTH ends: the source may spell
/// `'outer` where a definition spells `outer`, and a label that keeps its
/// punctuation can never be matched against the name an exit names.
fn controlLabel(e: *Ext, node: ts.Node) anyerror!?[]const u8 {
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (!isSourceLabelNode(child)) continue;
        const name = std.mem.trim(u8, text(e, child), "' \t\r\n");
        if (name.len == 0) continue;
        const label = try e.ctx.alloc.dupe(u8, name);
        return label;
    }
    return null;
}

/// The operand of `break value`, or null when the `break` carries none.
fn controlValue(e: *Ext, node: ts.Node) anyerror!?exprs.NodeId {
    if (node.childByFieldName("value")) |value| {
        const lowered = try lowerExpr(e, value);
        return lowered;
    }
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (isSourceLabelNode(child) or isComment(child)) continue;
        const lowered = try lowerExpr(e, child);
        return lowered;
    }
    return null;
}

// ── expression lowering ─────────────────────────────────────────────────────

/// True when `node` is the discard `_`: the anonymous token in pattern
/// position, or the identifier `_`, which names no binding in expression
/// position.
fn isUnderscoreValue(e: *const Ext, node: ts.Node) bool {
    if (std.mem.eql(u8, node.kind(), "_")) return true;
    if (!std.mem.eql(u8, node.kind(), "identifier")) return false;
    return std.mem.eql(u8, std.mem.trim(u8, text(e, node), " \t\r\n"), "_");
}

fn lowerAssignmentExpression(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const lhs = node.childByFieldName("left");
    const rhs = node.childByFieldName("right");
    if (lhs == null or rhs == null) return error.MalformedCst;

    // `_ = value;` evaluates and discards: `_` names no place, so there is
    // no target to write and the right side is the whole of it. The caller
    // wraps the returned node in an expression statement, which is exactly
    // the discard Rust performs. Reading it as a use of a binding called `_`
    // refused valid Rust as an "unresolved identifier" — no such binding is
    // ever pushed — while dropping the right side would drop effects the
    // source performs.
    if (std.mem.eql(u8, node.kind(), "assignment_expression") and isUnderscoreValue(e, lhs.?)) {
        return lowerExpr(e, rhs.?);
    }

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

/// `&[T]` and `&mut [T]` lower to a slice, and a `*const [T]` / `*mut [T]`
/// destination is a raw pointer to that same unsized slice: both carry the
/// element AND the length, so the cast re-labels one as the other and keeps
/// both. Only the fat destination can stand for a slice — a thin `*const u8`
/// has nowhere to keep the length — and the mutability still has to hold: a
/// shared slice cannot become a mutable pointer, while a mutable one can
/// become either. Same rule as `sliceToRawPointerCompatible` in `infer.zig` and
/// `sliceToRawPointerCompatible` in `ir/validate.zig`.
fn sliceToRawPointerCompatible(
    source_slice: *const types.Slice,
    target_raw: *const types.RawPtr,
) bool {
    if (target_raw.mut and source_slice.const_) return false;
    const target_slice = switch (target_raw.pointee) {
        .slice => |value| value,
        else => return false,
    };
    return infer.typeEqual(source_slice.elem, target_slice.elem);
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
            .slice => |source_slice| return sliceToRawPointerCompatible(source_slice, target.raw_ptr),
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

/// `entry.0` through a borrow: the element of a tuple, read off the receiver's
/// own type.
///
/// A tuple has no field entities — `0` and `1` are positions, not names — so
/// there is nothing for `knownFieldType` to look up and the projection goes
/// unanswered. Nothing else states what such a receiver holds either: the
/// borrow in front of it says nothing about the element behind it, which is
/// exactly what a `for` over `&Vec<(A, B)>` binds.
fn tupleProjectionType(e: *const Ext, field: exprs.FieldExpr) ?types.Type {
    const base = knownCastOperandType(e, field.base) orelse return null;
    const behind = switch (base) {
        .reference => |reference| reference.pointee,
        .raw_ptr => |raw_ptr| raw_ptr.pointee,
        else => base,
    };
    const tuple = switch (behind) {
        .tuple => |value| value,
        else => return null,
    };
    const index = std.fmt.parseInt(usize, field.field, 10) catch return null;
    if (index >= tuple.len) return null;
    return tuple[index];
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
        .field => |field| knownFieldType(e, field.resolved) orelse tupleProjectionType(e, field),
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
        // A core call's result is fixed by the function and its type
        // arguments, not by the values it is applied to, so the frontend can
        // answer this before inference runs. Without it a local bound to a
        // core call has no type here, and everything downstream of an index
        // into it — an array literal above all, which the Zig AST can only
        // emit with a named element type — is left untyped.
        .core_call => |call| coreCallResultType(call),
        else => null,
    };
}

/// The type a core call yields where its function and type arguments alone
/// decide it. These are the same rules `infer.knownCoreCallType` applies, so
/// the two passes cannot disagree; the remaining core functions depend on
/// value arguments only inference can see, and stay unknown here.
fn coreCallResultType(call: exprs.CoreCall) ?types.Type {
    const result: ?types.Type = switch (call.function) {
        .mem_transmute => if (call.generic_args.len == 2) call.generic_args[1] else null,
        .default_value, .convert_from => if (call.generic_args.len == 1) call.generic_args[0] else null,
        .mem_size_of, .mem_size_of_val => .{ .prim = .usize },
        else => null,
    };
    return result;
}

/// The result a call declares through the signature it was resolved against.
///
/// An associated call on an external nominal is the shape this needs it for:
/// `ensureExternalAssociatedFn` declared that signature from the standard
/// library, so its result is the owner's own identity and the source writes
/// no type for it anywhere — `Ok(String::from("a"))` names `String` only in
/// the call's return position. A crate's own function declares its result the
/// same way, so one rule covers both.
fn declaredCallResultType(e: *const Ext, call: exprs.Call) ?types.Type {
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
    if (ret == .unsupported) return null;
    return ret;
}

/// `vec![a, b]` is `Vec<typeof a>`: every element of one literal carries the
/// same type by construction, so the first element that names one names the
/// vector's element. A literal whose elements say nothing says nothing.
fn vecLitType(e: *const Ext, literal: exprs.VecLit) ?types.Type {
    for (literal.elements) |element| {
        const elem = resultArmValueType(e, element) orelse continue;
        var external = (externalNominalForPath(e, "alloc::vec::Vec") catch return null) orelse
            return null;
        const args = e.ctx.alloc.alloc(types.Type, 1) catch return null;
        args[0] = elem;
        external.args = args;
        return .{ .external_nominal = external };
    }
    return null;
}

/// A borrow the arm wrote over its own value: `Ok(&self.bytes)` is
/// `Result<&[u8], E>`, and that reference is the payload's whole type. Nothing
/// outside the arm states it — the arm is the only place the borrow appears —
/// so it is read from the value under it rather than from whatever row the
/// borrow node happens to carry.
fn borrowedPayloadType(e: *const Ext, node_id: exprs.NodeId) ?types.Type {
    if (node_id >= e.ctx.exprs.items.len) return null;
    const unary = switch (e.ctx.exprs.items[node_id].kind) {
        .unary => |value| value,
        else => return null,
    };
    const mode = switch (unary.op) {
        .ref => |value| value,
        else => return null,
    };
    const pointee = knownCastOperandType(e, unary.operand) orelse return null;
    if (pointee == .unsupported) return null;
    const ref_ptr = e.ctx.alloc.create(types.Ref) catch return null;
    ref_ptr.* = .{ .mut = (mode == .mutable), .pointee = pointee };
    return .{ .reference = ref_ptr };
}

/// The type an `Ok`/`Err` arm's own value carries.
///
/// `Ok(v)` is `Result<typeof v, E>`, so the ok slot is whatever `v` is — a
/// concrete type, a slice, a type parameter, a vector literal — and only the
/// value itself says which. `knownCastOperandType` already answers for the
/// shapes it recognises; the two it does not are an associated call on an
/// external nominal and a `vec!` literal, and neither is a guess — each
/// carries its own type in a place this pass has already read.
fn resultArmValueType(e: *const Ext, node_id: exprs.NodeId) ?types.Type {
    if (literalTypeIsOnlyAFallback(e, node_id)) return null;
    if (borrowedPayloadType(e, node_id)) |ty| return ty;
    if (knownCastOperandType(e, node_id)) |ty| return ty;
    if (node_id >= e.ctx.exprs.items.len) return null;
    return switch (e.ctx.exprs.items[node_id].kind) {
        .call => |call| declaredCallResultType(e, call),
        .vec_lit => |literal| vecLitType(e, literal),
        else => null,
    };
}

/// Whether the only type `node_id` has is the fallback an unsuffixed numeric
/// literal falls back on.
///
/// `Ok(1)` does not name a type: Rust reads that integer off the position it
/// stands in, and `i32` is what it becomes when the position asks for
/// nothing. Naming the fallback here would fix `T` before any position had a
/// say, and the position that does have one is a later pass. So the answer is
/// nothing, and the pair stays unbound for that pass — which is where an
/// unconstrained `Result` was always going to be decided.
fn literalTypeIsOnlyAFallback(e: *const Ext, node_id: exprs.NodeId) bool {
    if (node_id >= e.ctx.exprs.items.len) return false;
    const literal = switch (e.ctx.exprs.items[node_id].kind) {
        .literal => |value| value,
        else => return false,
    };
    return switch (literal) {
        .int => |integer| integer.ty_suffix == null,
        .float => |float| !std.mem.endsWith(u8, float.text, "f32") and
            !std.mem.endsWith(u8, float.text, "f64"),
        else => false,
    };
}

/// What one arm of a pair contributes to the `Result` the pair builds.
const ResultArmPayload = struct {
    error_arm: bool,
    ty: types.Type,
};

/// The payload a canonical `Ok(..)`/`Err(..)` construction carries, or null
/// when the node is not one of them or its value has not decided yet.
///
/// Only the arm that WRITES a slot answers for that slot: `Ok(v)` names
/// `Result<typeof v, E>`, and `E` is written in no `Ok` arm at all.
fn standardResultArmPayload(e: *const Ext, node_id: exprs.NodeId) ?ResultArmPayload {
    if (node_id >= e.ctx.exprs.items.len) return null;
    const variant = switch (e.ctx.exprs.items[node_id].kind) {
        .enum_variant => |value| value,
        else => return null,
    };
    const info = standardPreludeVariantName(variant.variant) orelse return null;
    if (!std.mem.eql(u8, info.enum_name, "Result")) return null;
    if (!isStandardPreludeEnum(e, variant.def, info.module_name, info.enum_name)) return null;
    if (variant.tuple_fields.len != 1 or variant.named_fields.len != 0) return null;
    const payload = resultArmValueType(e, variant.tuple_fields[0]) orelse return null;
    return .{ .error_arm = std.mem.eql(u8, variant.variant, "Err"), .ty = payload };
}

/// Bind the `Result` an unannotated `Ok`/`Err` pair builds onto both of the arm
/// nodes that carry it.
///
/// Rust writes the identity of a `Result` in exactly one place: the annotation
/// on the value. `let r: Result<String, u8> = ..` already arrives typed,
/// because `mapCstType` read both slots off that annotation and inference
/// pushes them into the `Ok` it names. Written without one, `Ok(v)` says only
/// `T = typeof v` and `Err(e)` says only `E = typeof e`: each arm holds half
/// of an identity neither of them names in full, and the pair is the only
/// place the other half exists at all. Stating it here is reading the source,
/// and it is what gives the conditional's own type, a `let` that takes it,
/// and every match that reads it a resolved pair instead of the stand-in
/// nothing later pass fills in.
///
/// Both nodes get the SAME interned row. Inference reads a conditional's type
/// by comparing its arms, and the two arms of one `Result` are one value, so
/// one row is that identity while two equal rows would only agree by
/// coincidence.
fn pinStandardResultArms(
    e: *Ext,
    then_tail: ?exprs.NodeId,
    else_tail: ?exprs.NodeId,
) !void {
    const then_arm = then_tail orelse return;
    const else_arm = else_tail orelse return;
    const then_payload = standardResultArmPayload(e, then_arm) orelse return;
    const else_payload = standardResultArmPayload(e, else_arm) orelse return;
    if (then_payload.error_arm == else_payload.error_arm) return;
    const ok = if (then_payload.error_arm) else_payload.ty else then_payload.ty;
    const err = if (then_payload.error_arm) then_payload.ty else else_payload.ty;
    // `appendType` interns, but interning this row needs the pointer to compare
    // first, so the reuse case reads the table directly rather than allocating
    // a row it would then throw away.
    var result_id: exprs.TypeId = 0;
    var found = false;
    for (e.ctx.types.items, 0..) |candidate, index| {
        const existing = switch (candidate) {
            .result => |value| value,
            else => continue,
        };
        if (!existing.is_error_unionable) continue;
        if (!infer.typeEqual(existing.ok, ok) or !infer.typeEqual(existing.err, err)) continue;
        result_id = @intCast(index);
        found = true;
        break;
    }
    if (!found) {
        const result = try e.ctx.alloc.create(types.Result);
        result.* = .{ .ok = ok, .err = err, .is_error_unionable = true };
        result_id = (try appendType(e, .{ .result = result })) orelse return;
    }
    e.ctx.exprs.items[then_arm].ty = result_id;
    e.ctx.exprs.items[else_arm].ty = result_id;
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

/// The byte width of an integer's native-endian byte image, or null for a
/// type that has no fixed one. `usize` / `isize` are excluded on purpose:
/// their image is as wide as the target pointer, which no IR type can name
/// until monomorphization has picked one.
fn nativeEndianByteWidth(primitive: types.Prim) ?u64 {
    return switch (primitive) {
        .i8, .u8 => 1,
        .i16, .u16 => 2,
        .i32, .u32 => 4,
        .i64, .u64 => 8,
        .i128, .u128 => 16,
        else => null,
    };
}

/// `[u8; N]`, the array an integer's native-endian byte image is written as.
fn nativeEndianByteArray(e: *Ext, primitive: types.Prim) ?types.Type {
    const width = nativeEndianByteWidth(primitive) orelse return null;
    const array = e.ctx.alloc.create(types.Array) catch return null;
    array.* = .{ .elem = .{ .prim = .u8 }, .len = .{ .literal = width } };
    return .{ .array = array };
}

/// `mem::size_of::<T>()`, the target's own answer for an integer's byte width.
///
/// This is how a `usize`/`isize` byte image gets a length without the
/// translator having to know the target. A `.literal` length would be right
/// for the host that ran the translation and wrong for every target that is not
/// it, which is the same reason `nativeEndianByteWidth` refuses those two
/// types; the difference is that this one DEFERS the question instead of
/// declining it. The length stays an expression all the way through, so the
/// target decides.
fn appendMemSizeOf(e: *Ext, primitive: types.Prim) anyerror!exprs.NodeId {
    const generic_args = try e.ctx.alloc.alloc(types.Type, 1);
    generic_args[0] = .{ .prim = primitive };
    const call = try appendExpr(e, .{ .core_call = .{
        .function = .mem_size_of,
        .generic_args = generic_args,
        .args = &.{},
    } });
    e.ctx.exprs.items[call].ty = try appendType(e, .{ .prim = .usize });
    return call;
}

/// `[u8; @sizeOf(T)]`, the byte image of an integer whose width only the target
/// knows. The length is the `mem_size_of` call above, not a number.
fn targetWidthByteArray(e: *Ext, primitive: types.Prim) !types.Type {
    const width = try appendMemSizeOf(e, primitive);
    const array = try e.ctx.alloc.create(types.Array);
    array.* = .{ .elem = .{ .prim = .u8 }, .len = .{ .expression = width } };
    return .{ .array = array };
}

/// The byte image of `primitive` however its width is known: a literal array
/// length for a fixed-width integer, the target's own `mem_size_of` for
/// `usize`/`isize`. Only a type with neither a fixed width nor a size the
/// target can answer is refused.
fn integerByteArray(e: *Ext, primitive: types.Prim) !types.Type {
    if (nativeEndianByteWidth(primitive)) |width| {
        const array = try e.ctx.alloc.create(types.Array);
        array.* = .{ .elem = .{ .prim = .u8 }, .len = .{ .literal = width } };
        return .{ .array = array };
    }
    return switch (primitive) {
        .usize, .isize => targetWidthByteArray(e, primitive),
        else => error.UnresolvedNominalType,
    };
}

/// Whether an integer's byte width is one this translator can state at all: a
/// fixed width for the sized integers, or the target's own `mem_size_of` for
/// `usize`/`isize`. A float, a `char`, or a `bool` has no byte image these
/// methods produce, so the answer is no.
fn isIntegerByteWidthKnown(primitive: types.Prim) bool {
    return switch (primitive) {
        .i8, .i16, .i32, .i64, .i128, .isize, .u8, .u16, .u32, .u64, .u128, .usize => true,
        else => false,
    };
}

/// `core::mem::transmute` between an integer and the same value's bytes.
/// `generic_args[0]` is the parameter and `generic_args[1]` the result, the
/// order the runtime reads them in — which is the order Rust's own
/// `transmute::<Src, Dst>` already spells, so no reordering happens here.
fn appendNativeEndianTransmute(
    e: *Ext,
    parameter: types.Type,
    result: types.Type,
    operand: exprs.NodeId,
) anyerror!exprs.NodeId {
    const generic_args = try e.ctx.alloc.alloc(types.Type, 2);
    generic_args[0] = parameter;
    generic_args[1] = result;
    const args = try e.ctx.alloc.alloc(exprs.NodeId, 1);
    args[0] = operand;
    return appendExpr(e, .{ .core_call = .{
        .function = .mem_transmute,
        .generic_args = generic_args,
        .args = args,
    } });
}

/// The integer a receiver expression holds, looking through one reference
/// layer because Rust's method call auto-derefs its receiver.
fn integerReceiverType(ty: types.Type) ?types.Prim {
    return switch (ty) {
        .prim => |primitive| primitive,
        .reference => |reference| switch (reference.pointee) {
            .prim => |primitive| primitive,
            else => null,
        },
        else => null,
    };
}

/// `receiver.to_ne_bytes()`, or null when this call is anything else.
///
/// The method is settled here rather than left to method dispatch because its
/// result is an ARRAY, not a number: no numeric method names it, and the
/// dispatch table keys on the receiver's primitive, so the spelling reaches
/// the backend as an unresolvable call. The runtime's `memory.transmute` is
/// already the operation — it copies the value's own bytes with `@memcpy`,
/// which is native-endian by construction — so `to_ne_bytes` and its inverse
/// are one core call each rather than a new runtime entry.
fn appendToNeBytes(e: *Ext, receiver: exprs.NodeId) anyerror!?exprs.NodeId {
    const declared = knownCastOperandType(e, receiver) orelse return null;
    const primitive = integerReceiverType(declared) orelse return null;
    const bytes = nativeEndianByteArray(e, primitive) orelse return null;
    const operand = if (declared == .reference)
        try appendExpr(e, .{ .unary = .{ .op = .deref, .operand = receiver } })
    else
        receiver;
    const transmuted = try appendNativeEndianTransmute(e, .{ .prim = primitive }, bytes, operand);
    return transmuted;
}

/// `u16::from_ne_bytes`, the associated-function spelling of the same bytes.
fn primitiveFromNeBytesTarget(raw: []const u8) ?types.Prim {
    const suffix = "::from_ne_bytes";
    if (!std.mem.endsWith(u8, raw, suffix)) return null;
    const primitive = mapPrim(raw[0 .. raw.len - suffix.len]) orelse return null;
    return if (nativeEndianByteWidth(primitive) != null) primitive else null;
}

fn appendPrimitiveFromNeBytes(
    e: *Ext,
    target_primitive: types.Prim,
    args: []const exprs.NodeId,
) anyerror!exprs.NodeId {
    defer e.ctx.alloc.free(args);
    if (args.len != 1) return unsupported(e, "primitive from_ne_bytes call");
    const bytes = nativeEndianByteArray(e, target_primitive) orelse
        return unsupported(e, "primitive from_ne_bytes call");
    return appendNativeEndianTransmute(e, bytes, .{ .prim = target_primitive }, args[0]);
}

/// `receiver.to_le_bytes()`, the explicit little-endian spelling of the same
/// byte image `to_ne_bytes` produces natively.
///
/// It is deliberately NOT `mem_transmute`. `mem_transmute` copies the value's
/// own bytes, which is the right answer on a little-endian target and the wrong
/// one on a big-endian one; `to_le_bytes` has to be little-endian on every
/// target or the hash it feeds is a different hash. So it gets its own core
/// function, which the backend emits as `std.mem.nativeToLittle` — a `@bitCast`
/// on LE and a `@byteSwap` on BE, both resolved at comptime.
fn appendToLeBytes(e: *Ext, receiver: exprs.NodeId) anyerror!?exprs.NodeId {
    const declared = knownCastOperandType(e, receiver) orelse return null;
    const primitive = integerReceiverType(declared) orelse return null;
    // A fixed-width integer gets a literal array length; `usize`/`isize` get
    // the target's own `mem_size_of`, so the count is never the host's.
    const byte_array = integerByteArray(e, primitive) catch return null;
    const operand = if (declared == .reference)
        try appendExpr(e, .{ .unary = .{ .op = .deref, .operand = receiver } })
    else
        receiver;
    const generic_args = try e.ctx.alloc.alloc(types.Type, 1);
    generic_args[0] = .{ .prim = primitive };
    const args = try e.ctx.alloc.alloc(exprs.NodeId, 1);
    args[0] = operand;
    const call = try appendExpr(e, .{ .core_call = .{
        .function = .prim_to_le_bytes,
        .generic_args = generic_args,
        .args = args,
    } });
    e.ctx.exprs.items[call].ty = try appendType(e, byte_array);
    return call;
}

/// `u16::from_le_bytes`, the associated-function spelling of the same decode.
fn primitiveFromLeBytesTarget(raw: []const u8) ?types.Prim {
    const suffix = "::from_le_bytes";
    if (!std.mem.endsWith(u8, raw, suffix)) return null;
    const primitive = mapPrim(raw[0 .. raw.len - suffix.len]) orelse return null;
    return switch (primitive) {
        .i8, .i16, .i32, .i64, .i128, .isize, .u8, .u16, .u32, .u64, .u128, .usize => primitive,
        else => null,
    };
}

fn appendPrimitiveFromLeBytes(
    e: *Ext,
    target_primitive: types.Prim,
    args: []const exprs.NodeId,
) anyerror!exprs.NodeId {
    defer e.ctx.alloc.free(args);
    if (args.len != 1) return unsupported(e, "primitive from_le_bytes call");
    // The decode takes the bytes as they are and produces the integer, so it
    // needs no array type of its own — this asks only whether the width is one
    // anything can state, and deliberately does NOT build the array, which
    // would leave an unreferenced `mem_size_of` expression in the table.
    if (!isIntegerByteWidthKnown(target_primitive)) {
        return unsupported(e, "primitive from_le_bytes call");
    }
    const generic_args = try e.ctx.alloc.alloc(types.Type, 1);
    generic_args[0] = .{ .prim = target_primitive };
    const owned = try e.ctx.alloc.alloc(exprs.NodeId, 1);
    owned[0] = args[0];
    const call = try appendExpr(e, .{ .core_call = .{
        .function = .prim_from_le_bytes,
        .generic_args = generic_args,
        .args = owned,
    } });
    e.ctx.exprs.items[call].ty = try appendType(e, .{ .prim = target_primitive });
    return call;
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

/// An integer primitive's own `const fn` for its extreme value, as
/// `u64::max_value()` spells it. `MIN`/`MAX` are the same values under their
/// modern names, and `BITS` is the width the other two are computed from, so
/// one table answers all of the spellings a single type can be asked for.
const PrimitiveAssocConst = struct {
    name: []const u8,
    arity: usize,
    /// The `const fn` body, evaluated here because every one of them is a
    /// compile-time constant: `max_value`/`MAX` is the type's largest
    /// representable value, `min_value`/`MIN` its smallest, and `BITS` its
    /// width. None of them reads an argument, reads memory, or can fail, so a
    /// /// literal is the whole operation.
    value: i128,
    text: []const u8,
};

/// `u8::MAX` — the largest value a `u8` can hold. The `value` field is what
/// the emitter re-derives from, and `text` is the same number in hex so the
/// emitted literal stays as readable as the source's own constant.
const primitive_assoc_consts = [_]struct { prim: types.Prim, entry: PrimitiveAssocConst }{
    .{ .prim = .u8, .entry = .{ .name = "max_value", .arity = 0, .value = 0xff, .text = "0xff" } },
    .{ .prim = .u8, .entry = .{ .name = "MAX", .arity = 0, .value = 0xff, .text = "0xff" } },
    .{ .prim = .u8, .entry = .{ .name = "min_value", .arity = 0, .value = 0, .text = "0" } },
    .{ .prim = .u8, .entry = .{ .name = "MIN", .arity = 0, .value = 0, .text = "0" } },
    .{ .prim = .u8, .entry = .{ .name = "BITS", .arity = 0, .value = 8, .text = "8" } },
    .{ .prim = .u16, .entry = .{ .name = "max_value", .arity = 0, .value = 0xffff, .text = "0xffff" } },
    .{ .prim = .u16, .entry = .{ .name = "MAX", .arity = 0, .value = 0xffff, .text = "0xffff" } },
    .{ .prim = .u16, .entry = .{ .name = "min_value", .arity = 0, .value = 0, .text = "0" } },
    .{ .prim = .u16, .entry = .{ .name = "MIN", .arity = 0, .value = 0, .text = "0" } },
    .{ .prim = .u16, .entry = .{ .name = "BITS", .arity = 0, .value = 16, .text = "16" } },
    .{ .prim = .u32, .entry = .{ .name = "max_value", .arity = 0, .value = 0xffff_ffff, .text = "0xffff_ffff" } },
    .{ .prim = .u32, .entry = .{ .name = "MAX", .arity = 0, .value = 0xffff_ffff, .text = "0xffff_ffff" } },
    .{ .prim = .u32, .entry = .{ .name = "min_value", .arity = 0, .value = 0, .text = "0" } },
    .{ .prim = .u32, .entry = .{ .name = "MIN", .arity = 0, .value = 0, .text = "0" } },
    .{ .prim = .u32, .entry = .{ .name = "BITS", .arity = 0, .value = 32, .text = "32" } },
    // `u64::MAX` fits an `i128` value field exactly — 1.8e19 against a ceiling
    // of 1.7e38 — so it is carried as itself and the emitter re-derives the Zig
    // spelling from `text` plus `ty_suffix`.
    .{
        .prim = .u64,
        .entry = .{
            .name = "max_value",
            .arity = 0,
            .value = 0xffff_ffff_ffff_ffff,
            .text = "0xffff_ffff_ffff_ffff",
        },
    },
    .{
        .prim = .u64,
        .entry = .{
            .name = "MAX",
            .arity = 0,
            .value = 0xffff_ffff_ffff_ffff,
            .text = "0xffff_ffff_ffff_ffff",
        },
    },
    // The full u128 maximum is emitted as typed bit-not below, not an i128 literal.
    .{ .prim = .u64, .entry = .{ .name = "min_value", .arity = 0, .value = 0, .text = "0" } },
    .{ .prim = .u64, .entry = .{ .name = "MIN", .arity = 0, .value = 0, .text = "0" } },
    .{ .prim = .u64, .entry = .{ .name = "BITS", .arity = 0, .value = 64, .text = "64" } },
    .{ .prim = .i8, .entry = .{ .name = "max_value", .arity = 0, .value = 0x7f, .text = "0x7f" } },
    .{ .prim = .i8, .entry = .{ .name = "MAX", .arity = 0, .value = 0x7f, .text = "0x7f" } },
    .{ .prim = .i8, .entry = .{ .name = "min_value", .arity = 0, .value = -0x80, .text = "-0x80" } },
    .{ .prim = .i8, .entry = .{ .name = "MIN", .arity = 0, .value = -0x80, .text = "-0x80" } },
    .{ .prim = .i8, .entry = .{ .name = "BITS", .arity = 0, .value = 8, .text = "8" } },
    .{ .prim = .i16, .entry = .{ .name = "max_value", .arity = 0, .value = 0x7fff, .text = "0x7fff" } },
    .{ .prim = .i16, .entry = .{ .name = "MAX", .arity = 0, .value = 0x7fff, .text = "0x7fff" } },
    .{ .prim = .i16, .entry = .{ .name = "min_value", .arity = 0, .value = -0x8000, .text = "-0x8000" } },
    .{ .prim = .i16, .entry = .{ .name = "MIN", .arity = 0, .value = -0x8000, .text = "-0x8000" } },
    .{ .prim = .i16, .entry = .{ .name = "BITS", .arity = 0, .value = 16, .text = "16" } },
    .{ .prim = .i32, .entry = .{ .name = "max_value", .arity = 0, .value = 0x7fff_ffff, .text = "0x7fff_ffff" } },
    .{ .prim = .i32, .entry = .{ .name = "MAX", .arity = 0, .value = 0x7fff_ffff, .text = "0x7fff_ffff" } },
    .{ .prim = .i32, .entry = .{ .name = "min_value", .arity = 0, .value = -0x8000_0000, .text = "-0x8000_0000" } },
    .{ .prim = .i32, .entry = .{ .name = "MIN", .arity = 0, .value = -0x8000_0000, .text = "-0x8000_0000" } },
    .{ .prim = .i32, .entry = .{ .name = "BITS", .arity = 0, .value = 32, .text = "32" } },
    .{ .prim = .i64, .entry = .{ .name = "max_value", .arity = 0, .value = 0x7fff_ffff_ffff_ffff, .text = "0x7fff_ffff_ffff_ffff" } },
    .{ .prim = .i64, .entry = .{ .name = "MAX", .arity = 0, .value = 0x7fff_ffff_ffff_ffff, .text = "0x7fff_ffff_ffff_ffff" } },
    .{ .prim = .i64, .entry = .{ .name = "min_value", .arity = 0, .value = std.math.minInt(i64), .text = "-0x8000_0000_0000_0000" } },
    .{ .prim = .i64, .entry = .{ .name = "MIN", .arity = 0, .value = std.math.minInt(i64), .text = "-0x8000_0000_0000_0000" } },
    .{ .prim = .i64, .entry = .{ .name = "BITS", .arity = 0, .value = 64, .text = "64" } },
    .{ .prim = .i128, .entry = .{ .name = "max_value", .arity = 0, .value = std.math.maxInt(i128), .text = "0x7fff_ffff_ffff_ffff_ffff_ffff_ffff_ffff" } },
    .{ .prim = .i128, .entry = .{ .name = "MAX", .arity = 0, .value = std.math.maxInt(i128), .text = "0x7fff_ffff_ffff_ffff_ffff_ffff_ffff_ffff" } },
    .{ .prim = .i128, .entry = .{ .name = "min_value", .arity = 0, .value = std.math.minInt(i128), .text = "-0x8000_0000_0000_0000_0000_0000_0000_0000" } },
    .{ .prim = .i128, .entry = .{ .name = "MIN", .arity = 0, .value = std.math.minInt(i128), .text = "-0x8000_0000_0000_0000_0000_0000_0000_0000" } },
    .{ .prim = .i128, .entry = .{ .name = "BITS", .arity = 0, .value = 128, .text = "128" } },
    .{ .prim = .u128, .entry = .{ .name = "min_value", .arity = 0, .value = 0, .text = "0" } },
    .{ .prim = .u128, .entry = .{ .name = "MIN", .arity = 0, .value = 0, .text = "0" } },
    .{ .prim = .u128, .entry = .{ .name = "BITS", .arity = 0, .value = 128, .text = "128" } },
};

/// `u64::max_value()` / `i8::MIN` / `u32::BITS`, as a literal of the named
/// primitive, or null when the path is not one of this table's entries.
fn primitiveAssocConstTarget(raw: []const u8) ?struct { prim: types.Prim, entry: PrimitiveAssocConst } {
    const separator = std.mem.indexOf(u8, raw, "::") orelse return null;
    if (std.mem.lastIndexOf(u8, raw, "::").? != separator) return null;
    const base_name = std.mem.trim(u8, raw[0..separator], " \t\r\n");
    const const_name = std.mem.trim(u8, raw[separator + 2 ..], " \t\r\n");
    const primitive = mapPrim(base_name) orelse return null;
    if ((primitive == .usize or primitive == .isize or primitive == .u128) and
        (std.mem.eql(u8, const_name, "MAX") or std.mem.eql(u8, const_name, "MIN") or
            std.mem.eql(u8, const_name, "BITS") or std.mem.eql(u8, const_name, "max_value") or
            std.mem.eql(u8, const_name, "min_value")))
    {
        return .{ .prim = primitive, .entry = .{
            .name = const_name,
            .arity = 0,
            .value = 0,
            .text = "0",
        } };
    }
    for (primitive_assoc_consts) |candidate| {
        if (candidate.prim != primitive) continue;
        if (!std.mem.eql(u8, candidate.entry.name, const_name)) continue;
        return .{ .prim = candidate.prim, .entry = candidate.entry };
    }
    return null;
}

fn appendPrimitiveAssocConst(
    e: *Ext,
    prim: types.Prim,
    entry: PrimitiveAssocConst,
    args: []const exprs.NodeId,
) anyerror!exprs.NodeId {
    defer e.ctx.alloc.free(args);
    if (args.len != entry.arity) return unsupported(e, "primitive associated const call");
    if (prim == .usize or prim == .isize or prim == .u128) {
        return appendTargetIntegerConstant(e, prim, entry.name);
    }
    const suffix = if (std.mem.eql(u8, entry.name, "BITS")) "u32" else @tagName(prim);
    const literal = try appendExpr(e, .{ .literal = .{ .int = .{
        .text = try e.ctx.alloc.dupe(u8, entry.text),
        .value = entry.value,
        .base = .hex,
        .ty_suffix = try e.ctx.alloc.dupe(u8, suffix),
    } } });
    e.ctx.exprs.items[literal].ty = try appendType(e, .{ .prim = if (std.mem.eql(u8, entry.name, "BITS")) .u32 else prim });
    return literal;
}

fn typedIntegerLiteral(e: *Ext, prim: types.Prim, value: i128) anyerror!exprs.NodeId {
    const id = try appendExpr(e, .{ .literal = .{ .int = .{
        .text = try std.fmt.allocPrint(e.ctx.alloc, "{d}", .{value}),
        .value = value,
        .base = .dec,
        .ty_suffix = @tagName(prim),
    } } });
    e.ctx.exprs.items[id].ty = try appendType(e, .{ .prim = prim });
    return id;
}

fn typedIntegerBinary(e: *Ext, prim: types.Prim, op: exprs.BinaryOp, lhs: exprs.NodeId, rhs: exprs.NodeId) anyerror!exprs.NodeId {
    const id = try appendExpr(e, .{ .binary = .{
        .op = op,
        .overflow = .wrapping,
        .lhs = lhs,
        .rhs = rhs,
    } });
    e.ctx.exprs.items[id].ty = try appendType(e, .{ .prim = prim });
    return id;
}

fn typedIntegerNot(e: *Ext, prim: types.Prim, operand: exprs.NodeId) anyerror!exprs.NodeId {
    const id = try appendExpr(e, .{ .unary = .{ .op = .bit_not, .operand = operand } });
    e.ctx.exprs.items[id].ty = try appendType(e, .{ .prim = prim });
    return id;
}

/// Target pointer widths are computed in the emitted program. In particular
/// u128::MAX never passes through the IR's signed i128 literal payload.
fn appendTargetIntegerConstant(e: *Ext, prim: types.Prim, name: []const u8) anyerror!exprs.NodeId {
    const is_bits = std.mem.eql(u8, name, "BITS");
    const is_min = std.mem.eql(u8, name, "MIN") or std.mem.eql(u8, name, "min_value");
    if (prim == .u128 and is_bits) return typedIntegerLiteral(e, .u32, 128);
    if (prim != .isize and !is_bits) {
        const zero = try typedIntegerLiteral(e, prim, 0);
        return if (is_min) zero else typedIntegerNot(e, prim, zero);
    }
    const bytes = try appendMemSizeOf(e, prim);
    const bits = try typedIntegerBinary(e, .usize, .mul, bytes, try typedIntegerLiteral(e, .usize, 8));
    if (is_bits) {
        const target = (try appendType(e, .{ .prim = .u32 })) orelse unreachable;
        const cast = try appendExpr(e, .{ .cast = .{
            .kind = .as_,
            .operand = bits,
            .source_type = .{ .prim = .usize },
            .target = target,
        } });
        e.ctx.exprs.items[cast].ty = target;
        return cast;
    }
    const shift = try typedIntegerBinary(e, .usize, .sub, bits, try typedIntegerLiteral(e, .usize, 1));
    const minus_one = try typedIntegerNot(e, prim, try typedIntegerLiteral(e, prim, 0));
    const minimum = try typedIntegerBinary(e, prim, .shl, minus_one, shift);
    return if (is_min) minimum else typedIntegerNot(e, prim, minimum);
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
        // The operand is read twice: the conversion is judged against the
        // source recorded on the cast, and a reader that re-derives the
        // source from the operand has nothing to compare against unless the
        // node carries one of its own. `knownCastOperandType` can answer from
        // the binding the operand names, which leaves the node itself
        // untyped — and an untyped operand under a raw-pointer destination is
        // exactly what validation refuses. Pinning the type this very cast is
        // judged by makes the two the same statement, and does not weaken the
        // check: the source still has to agree with what the operand says.
        // The type is INTERNED through the table's own find-or-append, not
        // looked up: a parameter's type is not an entry until something asks
        // for one, so a lookup alone would find nothing and silently leave the
        // operand untyped.
        if (e.ctx.exprs.items[operand].ty == null) {
            if (try appendType(e, source_type)) |source_id| {
                e.ctx.exprs.items[operand].ty = source_id;
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
    name: []const u8,
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
    const name = segments[count - 1];
    if (!std.mem.eql(u8, name, "MAX") and !std.mem.eql(u8, name, "MIN") and
        !std.mem.eql(u8, name, "BITS")) return null;
    if (!isIntegerByteWidthKnown(primitive)) return null;
    return .{ .primitive = primitive, .name = name };
}

fn lowerPrimitiveAssociatedConstant(e: *Ext, constant: PrimitiveAssociatedConstant) anyerror!exprs.NodeId {
    if (constant.primitive == .usize or constant.primitive == .isize or constant.primitive == .u128)
        return appendTargetIntegerConstant(e, constant.primitive, constant.name);
    const raw = try std.fmt.allocPrint(e.ctx.alloc, "{s}::{s}", .{ @tagName(constant.primitive), constant.name });
    defer e.ctx.alloc.free(raw);
    const target = primitiveAssocConstTarget(raw) orelse return error.MalformedCst;
    return appendPrimitiveAssocConst(e, target.prim, target.entry, try e.ctx.alloc.alloc(exprs.NodeId, 0));
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
        // A unit struct is spelled as a bare name in value position, so
        // `_marker: PhantomData` arrives here with no binding of that name in
        // scope: the `use` that introduced it binds a TYPE, not a value. Last,
        // because it is the widest of these — every branch above resolves a
        // real local entity first, so this only ever sees a name nothing in
        // this crate claims.
        if (try lowerExternalUnitStructPath(e, nm)) |unit_struct| {
            return unit_struct;
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
        // A variant of a standard-library enum, declared under the external
        // module chain the same way the prelude's own enums are. Last, because
        // it is the widest of these: everything above it resolves a real local
        // entity first, so this only ever sees a path nothing local claims.
        if (try lowerExternalEnumVariantPath(e, node)) |external_variant| {
            return external_variant;
        }
        // A standard-library unit struct, reached by its full path where the
        // `use` spelling above would have reached the same entity by name.
        if (try lowerExternalUnitStructPath(e, text(e, node))) |unit_struct| {
            return unit_struct;
        }
        return unsupported(e, "unresolved scoped path");
    }
    if (std.mem.eql(u8, kind, "mutable_specifier")) return error.MalformedCst;

    // Binary / compound assignments.
    if (std.mem.eql(u8, kind, "binary_expression")) {
        const lhs = firstValueChild(node);
        const rhs = lastValueChild(node);
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
        const base = valueChild(node, 0);
        const field = valueChild(node, 1);
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
        const base = valueChild(node, 0);
        const idx = valueChild(node, 1);
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
            // `'outer:` is the first named child of a labelled `while`. It
            // names the loop; it is neither the condition nor the body.
            if (isSourceLabelNode(c)) continue;
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
        // The label belongs to the loop, and the backend reads a loop's label
        // off the block its body is, so it is recorded there.
        var while_body = try lowerBlock(e, body);
        while_body.labelled = try controlLabel(e, node);
        return appendExpr(e, .{ .while_ = .{
            .cond = cond_id,
            .capture = capture,
            .body = while_body,
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
            if (isBlockTrivia(c)) continue;
            if (!std.mem.eql(u8, c.kind(), "return")) {
                val = try lowerExpr(e, c);
                break;
            }
        }
        return appendExpr(e, .{ .return_ = .{ .value = val } });
    }
    if (std.mem.eql(u8, kind, "unary_expression")) {
        const operand = lastValueChild(node);
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
        return lowerExpr(e, firstValueChild(node) orelse return error.MalformedCst);
    }
    if (std.mem.eql(u8, kind, "try_expression")) {
        const inner_node = firstValueChild(node) orelse
            node.childByFieldName("expression") orelse return error.MalformedCst;
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
    // Rust writes `_` between digits, and `std.fmt.parseInt` has no rule for
    // it at all: every one of them makes the parse fail. `trimEnd` alone —
    // which is all this did — therefore turned `0x_07_06_05_04_03_02_01_00`
    // into a refusal named "integer literal out of range" for a value that is
    // neither out of range nor unreadable. The separator was the whole of the
    // problem, so it is skipped here instead.
    //
    // Skipping EVERY `_` is the rule rustc's own lexer applies, and `syn`
    // pins it: `syn/tests/test_lit.rs:220` reads `5_____0_____` as `50` and
    // line 228 reads `0x__7___f_` as `127`. A rule that only tolerated one
    // separator between digits would be stricter than the language it reads.
    // The base prefix is consumed above, so `0x_ff` and `0xff` arrive here as
    // the same digits.
    const radix: i128 = base;
    var value: i128 = 0;
    var saw_digit = false;
    for (untrimmed_digits) |character| {
        if (character == '_') continue;
        const digit: i128 = switch (character) {
            '0'...'9' => character - '0',
            'a'...'f' => character - 'a' + 10,
            'A'...'F' => character - 'A' + 10,
            else => return null,
        };
        if (digit >= radix) return null;
        if (saw_digit) value = std.math.mul(i128, value, radix) catch return null;
        value = std.math.add(i128, value, digit) catch return null;
        saw_digit = true;
    }
    // Separators are not digits: a literal made only of them names no value.
    if (!saw_digit) return null;
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

// Rust's `_` digit separator, which `std.fmt.parseInt` cannot read.
//
// `siphasher` writes both of its vector-table keys this way
// (`src/tests.rs:127-128`, `src/tests128.rs:50-51`, and the `2_4` twins), and
// every one of them used to come back as an `.unsupported` node whose reason
// blamed the value's RANGE. The range was never the problem, so the refusal
// named an obstacle the source did not contain.
test "Rust digit separators fold into the literal's value" {
    // `0x_07_06_05_04_03_02_01_00` — a separator straight after the base
    // prefix and one between every pair of digits.
    const key0 = parseIntLiteral("0x_07_06_05_04_03_02_01_00") orelse
        return error.LiteralRejected;
    try std.testing.expectEqual(@as(i128, 506097522914230528), key0.value);
    try std.testing.expectEqual(@as(u8, 16), key0.base);

    // `0x_0f_0e_0d_0c_0b_0a_09_08` — the same spelling over a value whose top
    // nibble is not zero, so a fold that dropped digits would still look
    // plausible here if it did not compare against the exact number.
    const key1 = parseIntLiteral("0x_0f_0e_0d_0c_0b_0a_09_08") orelse
        return error.LiteralRejected;
    try std.testing.expectEqual(@as(i128, 1084818905618843912), key1.value);
    try std.testing.expectEqual(@as(u8, 16), key1.base);

    // The decimal spelling with an interior separator, which is the same
    // defect in the base `std.fmt.parseInt` handled by default.
    const separated = parseIntLiteral("1_000_000") orelse return error.LiteralRejected;
    try std.testing.expectEqual(@as(i128, 1000000), separated.value);
    try std.testing.expectEqual(@as(u8, 10), separated.base);

    // A suffix still binds after the separators are folded away.
    const suffixed = parseIntLiteral("0x_ff_u8") orelse return error.LiteralRejected;
    try std.testing.expectEqual(@as(i128, 255), suffixed.value);
    try std.testing.expectEqualStrings("u8", suffixed.ty_suffix.?);

    // The spellings `syn`'s own lexer tests pin: it reads a RUN of separators
    // as one, at either end of the digit string as well as between digits, and
    // a suffix still binds after them. A fold that stopped at the first
    // separator, or that rejected a doubled one, would disagree with the
    // parser this repository already treats as the reference for literal
    // syntax.
    const doubled = parseIntLiteral("5_____0_____") orelse return error.LiteralRejected;
    try std.testing.expectEqual(@as(i128, 50), doubled.value);
    const prefix_run = parseIntLiteral("0x__7___f_") orelse return error.LiteralRejected;
    try std.testing.expectEqual(@as(i128, 127), prefix_run.value);
    const suffixed_run = parseIntLiteral("0x_7F__u8") orelse return error.LiteralRejected;
    try std.testing.expectEqual(@as(i128, 127), suffixed_run.value);
    try std.testing.expectEqualStrings("u8", suffixed_run.ty_suffix.?);
    const binary = parseIntLiteral("0b_1_0__01") orelse return error.LiteralRejected;
    try std.testing.expectEqual(@as(i128, 9), binary.value);
    try std.testing.expectEqual(@as(u8, 2), binary.base);

    // What is still refused: a spelling with no digit in it at all, and one
    // carrying a digit the base cannot express. A separator is not a digit, so
    // `0x_` and `___` name no value; `0b_2` and `0xffg` do not name one either.
    for ([_][]const u8{ "", "_", "___", "0x_", "0b_2", "0xffg" }) |spelling| {
        if (parseIntLiteral(spelling) != null) return error.InvalidLiteralAccepted;
    }
}

/// Read the `[e; N]` / `vec![e; N]` count a Rust source spells out.
///
/// `N` is a number the generated 64-bit program states, so the parse is
/// `u64`-wide and overflows at `u64::MAX` no matter how wide the translator
/// host's pointers are. Null means "not a source constant this parser can
/// fold", which callers turn into their own refusal.
fn parseVecRepeatCount(raw: []const u8) ?u64 {
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

    var base: u64 = 10;
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

    var value: u64 = 0;
    var saw_digit = false;
    var previous_separator = false;
    for (digits, 0..) |character, index| {
        if (character == '_') {
            if (!saw_digit or previous_separator or index + 1 == digits.len) return null;
            previous_separator = true;
            continue;
        }

        const digit: u64 = switch (character) {
            '0'...'9' => character - '0',
            'a'...'f' => character - 'a' + 10,
            'A'...'F' => character - 'A' + 10,
            else => return null,
        };
        if (digit >= base) return null;
        if (value > (std.math.maxInt(u64) - digit) / base) return null;
        value = value * base + digit;
        saw_digit = true;
        previous_separator = false;
    }

    if (!saw_digit or previous_separator) return null;
    return value;
}

/// Fold one binary step of a source-written array length.
///
/// The operands are target counts, so every bound here is `u64`: a shift by
/// 32 is a legal `[e; 1 << 32]` whether or not the translator's own pointers
/// are 32 bits wide, and a step that would leave the `u64` count range is
/// simply not foldable.
fn checkedArrayLenBinary(op: exprs.BinaryOp, lhs: u64, rhs: u64) ?u64 {
    return switch (op) {
        .add => std.math.add(u64, lhs, rhs) catch null,
        .sub => std.math.sub(u64, lhs, rhs) catch null,
        .mul => std.math.mul(u64, lhs, rhs) catch null,
        .div => if (rhs == 0) null else lhs / rhs,
        .rem => if (rhs == 0) null else lhs % rhs,
        .bit_and => lhs & rhs,
        .bit_or => lhs | rhs,
        .bit_xor => lhs ^ rhs,
        .shl => blk: {
            if (rhs >= @bitSizeOf(u64)) break :blk null;
            const shift: std.math.Log2Int(u64) = @intCast(rhs);
            if (lhs > (@as(u64, std.math.maxInt(u64)) >> shift)) break :blk null;
            break :blk lhs << shift;
        },
        .shr => blk: {
            if (rhs >= @bitSizeOf(u64)) break :blk null;
            break :blk lhs >> @as(std.math.Log2Int(u64), @intCast(rhs));
        },
        else => null,
    };
}

// A count is metadata about the translated program, so every bound here is
// `u64` rather than the translator host's pointer width: a 32-bit host used to
// refuse `4294967296` outright and to reject the `1 << 32` shift that names it.
test "array and vec repeat counts fold across the whole u64 range" {
    const foldable = [_]struct {
        token: []const u8,
        count: u64,
    }{
        .{ .token = "4294967296", .count = 4294967296 },
        .{ .token = "4294967296_usize", .count = 4294967296 },
        .{ .token = "0x1_0000_0000", .count = 4294967296 },
        .{ .token = "18446744073709551615", .count = std.math.maxInt(u64) },
    };
    for (foldable) |case| {
        try std.testing.expectEqual(
            case.count,
            parseVecRepeatCount(case.token) orelse return error.CountRejected,
        );
    }
    // One past the widest count is not a count, not a wrapped zero.
    try std.testing.expect(parseVecRepeatCount("18446744073709551616") == null);

    try std.testing.expectEqual(
        @as(u64, 1 << 32),
        checkedArrayLenBinary(.shl, 1, 32) orelse return error.CountRejected,
    );
    try std.testing.expectEqual(
        @as(u64, 4294967296),
        checkedArrayLenBinary(.mul, 65536, 65536) orelse return error.CountRejected,
    );
    // A shift by the count's own width, and any step past `u64`, is a step
    // this folder cannot fold; it never produces a narrowed answer.
    try std.testing.expect(checkedArrayLenBinary(.shl, 1, 64) == null);
    try std.testing.expect(checkedArrayLenBinary(.mul, 4294967296, 4294967296) == null);
    try std.testing.expect(checkedArrayLenBinary(.add, std.math.maxInt(u64), 1) == null);
}

/// The constant value of an already-lowered node used as an array length.
///
/// `remaining` bounds the walk; it is host recursion fuel and stays `usize`.
/// The value it returns is a target count and is `u64` throughout.
fn constArrayLenFromExpr(e: *const Ext, node_id: exprs.NodeId, remaining: usize) ?u64 {
    if (remaining == 0 or node_id >= e.ctx.exprs.items.len) return null;
    return switch (e.ctx.exprs.items[node_id].kind) {
        .literal => |literal| switch (literal) {
            .int => |integer| blk: {
                if (integer.value < 0) break :blk null;
                const max_count: i128 = @intCast(std.math.maxInt(u64));
                if (integer.value > max_count) break :blk null;
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

/// The constant length a source `[e; N]` spells out, before it is lowered.
///
/// `remaining` bounds the walk; it is host recursion fuel and stays `usize`.
/// The length it returns is a target count and is `u64` throughout, so a
/// 64-bit target's `[e; 4294967296]` folds the same way on a 32-bit host.
fn constArrayLenFromCst(e: *const Ext, node: ts.Node, remaining: usize) ?u64 {
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

/// The type `b"..."` is: `&'static [u8; N]`.
///
/// Both halves belong to the literal itself. The element is a byte, and the
/// length is the number of bytes the source wrote, so there is nothing here for
/// a surrounding constraint to decide — which is why this is asked of the
/// literal rather than left for the solver. The borrow is part of the type
/// rather than an inference about the position, the same reading
/// `resolve_methods.sharedRefType` gives the same literal.
fn byteStringType(e: *const Ext, len: usize) std.mem.Allocator.Error!?types.Type {
    const array = try e.ctx.alloc.create(types.Array);
    errdefer e.ctx.alloc.destroy(array);
    array.* = .{ .elem = .{ .prim = .u8 }, .len = .{ .literal = @intCast(len) } };
    const reference = try e.ctx.alloc.create(types.Ref);
    errdefer e.ctx.alloc.destroy(reference);
    reference.* = .{ .mut = false, .pointee = .{ .array = array } };
    return .{ .reference = reference };
}

fn sourceDeterminedExprType(e: *const Ext, node_id: exprs.NodeId) std.mem.Allocator.Error!?types.Type {
    if (node_id >= e.ctx.exprs.items.len) return null;
    const expression = e.ctx.exprs.items[node_id];
    // A published row is an answer only where the row is one. The `_`
    // placeholder is the type table's stand-in for a Rust `_`, and every other
    // reader of this chain refuses it before taking it for a decision:
    // `declaredPeerType`, `pinKnownType`, `setKnownType`, `isUnnamedElement`
    // and `containerAlreadyNamed` all read it as "nothing has been said here".
    // Handing it back as an answer made a slot nothing had decided look
    // decided, and a row holding one is a row `validate` refuses — including
    // the nested case, where the placeholder row is a whole sub-row nothing
    // can complete: `refineSourceTupleRow` writes only the elements it reads.
    if (expression.ty) |type_id| {
        if (type_id < e.ctx.types.items.len) {
            const published = e.ctx.types.items[type_id];
            if (!infer.isInferPlaceholderType(published)) return published;
        }
    }
    switch (expression.kind) {
        .literal => |literal| return switch (literal) {
            .int => |integer| if (integer.ty_suffix != null) knownCastOperandType(e, node_id) else null,
            .float => |float| if (std.mem.endsWith(u8, float.text, "f32") or std.mem.endsWith(u8, float.text, "f64")) knownCastOperandType(e, node_id) else null,
            .boolean => .{ .prim = .bool },
            .character => .{ .prim = .char },
            .string => knownCastOperandType(e, node_id),
            // `"..."` answers `&str` just above and `b"..."` answers its own
            // bytes here. Falling through to a refusal made the whole literal
            // a hole: a byte string in a tuple or array literal position left
            // `unattributedType` — the `_` placeholder — in that row, and the
            // row is what `validate` reads, so a value the source fully
            // determined was refused for a slot nothing was left to fill.
            .byte_array => |bytes| byteStringType(e, bytes.items.len),
        },
        .unary => |unary| {
            const operand = (try sourceDeterminedExprType(e, unary.operand)) orelse return null;
            return switch (unary.op) {
                .ref => |mode| blk: {
                    const reference = try e.ctx.alloc.create(types.Ref);
                    reference.* = .{ .mut = mode == .mutable, .pointee = operand };
                    break :blk .{ .reference = reference };
                },
                .deref => switch (operand) {
                    .reference => |reference| reference.pointee,
                    .raw_ptr => |pointer| pointer.pointee,
                    else => null,
                },
                .negate, .bit_not, .logical_not => operand,
            };
        },
        .index => |index| {
            const base = (try sourceDeterminedExprType(e, index.base)) orelse return null;
            if (index.index >= e.ctx.exprs.items.len or e.ctx.exprs.items[index.index].kind != .range) return indexedElementType(base);
            var sequence = base;
            for (0..128) |_| {
                switch (sequence) {
                    .reference => |reference| sequence = reference.pointee,
                    .boxed => |boxed| sequence = boxed.*,
                    else => break,
                }
            }
            const element = indexedElementType(sequence) orelse return null;
            const view = try e.ctx.alloc.create(types.Slice);
            view.* = .{ .const_ = if (sequence == .slice) sequence.slice.const_ else true, .elem = element };
            return .{ .slice = view };
        },
        // A constructor IS a value of the enum that declares it, and that is
        // written in the source: `Sign::Plus` says `Sign` before inference
        // runs. `knownCastOperandType` has no arm for a variant at all, so the
        // `.else` below answered null and `attachKnownTupleType` put
        // `unattributedType` — the `_` placeholder — into a slot the source had
        // already decided, and a row is what `validate` reads whether or not an
        // expression still points at it.
        .enum_variant => |variant| return sourceDeterminedVariantType(e, variant),
        else => return knownCastOperandType(e, node_id),
    }
}

/// What an enum-constructor expression IS, read off the declaration it names.
///
/// This is the extraction-time half of what the inference pass answers for the
/// same node — `knownSourceEnumVariantType` for a crate's own enum,
/// `preludeVariantType` for the prelude's — and it keeps that pass's refusal.
/// An enum that declares type parameters has no identity until a position picks
/// the arguments: `Some(v)` is `Option<T>` and `None` is `Option<T>` with `T`
/// still the enum's own parameter, so neither answers anything here and the
/// slot stays a question for the constraint around it. That is exactly what a
/// `None` needs, because it carries no payload to read a type out of.
fn sourceDeterminedVariantType(
    e: *const Ext,
    variant: exprs.EnumVariant,
) std.mem.Allocator.Error!?types.Type {
    if (variant.def >= e.ctx.bodies_list.items.len) return null;
    const owner = switch (e.ctx.bodies_list.items[variant.def]) {
        .enum_ => |body| body,
        else => return null,
    };
    if (owner.generic_params.len != 0) return null;
    const entity = e.ctx.g.symbol_table.get(variant.def) orelse return null;
    if (entity.name.len == 0) return null;
    // A row that already names this declaration is the one the solver would
    // find, spelling and all; minting a second, shorter path beside it would
    // lock a different identity into a row nothing may overwrite afterwards.
    for (e.ctx.types.items) |candidate| {
        const path = switch (candidate) {
            .path => |value| value,
            else => continue,
        };
        if (path.segments.len == 0) continue;
        if (path.segments[path.segments.len - 1].id == variant.def) return candidate;
    }
    const segments = try e.ctx.alloc.alloc(types.PathSegment, 1);
    segments[0] = .{ .name = entity.name, .id = variant.def };
    return .{ .path = .{ .segments = segments } };
}

/// Give an array literal the `[T; N]` type its elements and length name.
///
/// `len` is a target count. For the repeating form it is the source-written
/// `[e; N]` count, which is `u64` because the array it describes belongs to a
/// 64-bit target; for the explicit list form it is `elements.len`, the real
/// number of nodes just lowered, widened from `usize`.
fn attachKnownArrayType(
    e: *Ext,
    array_id: exprs.NodeId,
    elements: []const exprs.NodeId,
    len: u64,
) !void {
    if (elements.len == 0) return;
    const element_type = (try sourceDeterminedExprType(e, elements[0])) orelse return;
    for (elements[1..]) |element| {
        const candidate = (try sourceDeterminedExprType(e, element)) orelse return;
        if (!infer.typeEqual(element_type, candidate)) return;
    }
    const array_type = try e.ctx.alloc.create(types.Array);
    errdefer e.ctx.alloc.destroy(array_type);
    array_type.* = .{
        .elem = element_type,
        .len = .{ .literal = len },
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
        // A slot the source named — a generic parameter, a local's type, a
        // suffixed literal — is a decision and stands as written. A slot
        // nothing has typed yet is a hole, and the inference placeholder is
        // what a hole looks like in this table.
        tuple_types[index] = (try sourceDeterminedExprType(e, element)) orelse
            try unattributedType(e);
    }
    const aggregate: types.Type = .{ .tuple = tuple_types };
    // Partial tuple rows belong to this literal. The solver fills their
    // unknown elements; sharing such a row would couple unrelated literals.
    if (isConcreteDeclaredReturnType(aggregate)) {
        if (infer.findTypeIndexInSlice(e.ctx.types.items, aggregate)) |existing| {
            e.ctx.alloc.free(tuple_types);
            e.ctx.exprs.items[tuple_id].ty = existing;
            return;
        }
    }
    const type_id: exprs.TypeId = @intCast(e.ctx.types.items.len);
    try e.ctx.types.append(e.ctx.alloc, aggregate);
    e.ctx.exprs.items[tuple_id].ty = type_id;
}

/// The type of a construct nothing has attributed a type to yet.
///
/// This is the entry a written `_` lowers to, and solving rewrites it once the
/// constraints around it name a type. An `unsupported` entry is not that: it is
/// a terminal refusal, and a type row stays in the table whether or not any
/// expression still points at it, so one refused element condemned the whole
/// row before the inference that would have filled it had run.
fn unattributedType(e: *Ext) std.mem.Allocator.Error!types.Type {
    const path = try e.ctx.alloc.alloc([]const u8, 1);
    path[0] = "_";
    return .{ .external_nominal = .{ .path = path, .args = &.{} } };
}

fn lowerArrayExpression(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    if (node.childByFieldName("length")) |length_node| {
        const element_node = node.childByFieldName("element") orelse
            node.childByFieldName("value") orelse
            firstValueChild(node) orelse return error.MalformedCst;
        // The fold is `u64`-wide, so `[e; 4294967296]` is a count rather than
        // a refusal on any host. The recursion bound is symbol and expression
        // cardinality, so it stays host-sized.
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
    try attachKnownArrayType(e, array_id, owned_elements, @intCast(owned_elements.len));
    return array_id;
}

fn hexDigit(value: u8) ?u8 {
    if (value >= '0' and value <= '9') return value - '0';
    if (value >= 'a' and value <= 'f') return value - 'a' + 10;
    if (value >= 'A' and value <= 'F') return value - 'A' + 10;
    return null;
}

/// Decode a Rust `\u{...}` escape into a Unicode scalar.
/// Count one to six hex digits; underscore runs follow digits.
/// Borrows `escape`, allocates nothing, and returns null for an invalid escape.
fn decodeRustUnicodeEscape(escape: []const u8) ?u32 {
    if (escape.len < 5 or escape[0] != '\\' or escape[1] != 'u' or escape[2] != '{') {
        return null;
    }
    if (escape[escape.len - 1] != '}') return null;
    const digits = escape[3 .. escape.len - 1];
    if (digits.len == 0) return null;
    var value: u32 = 0;
    var counted: usize = 0;
    for (digits) |digit| {
        if (digit == '_') {
            if (counted == 0) return null;
            continue;
        }
        const nibble = hexDigit(digit) orelse return null;
        if (counted == 6) return null;
        counted += 1;
        value = value * 16 + @as(u32, nibble);
    }
    if (!isUnicodeScalar(value)) return null;
    return value;
}

/// Append one scalar value as UTF-8.
///
/// Hand-rolled to mirror `decodeUtf8Codepoint` beside it: the same rules in
/// both directions, so what this accepts and what that reads back agree.
fn appendUtf8Codepoint(
    allocator: std.mem.Allocator,
    bytes: *std.ArrayListUnmanaged(u8),
    value: u32,
) !void {
    if (!isUnicodeScalar(value)) return error.InvalidLiteral;
    if (value < 0x80) {
        try bytes.append(allocator, @intCast(value));
    } else if (value < 0x800) {
        try bytes.append(allocator, @intCast(0xc0 | (value >> 6)));
        try bytes.append(allocator, @intCast(0x80 | (value & 0x3f)));
    } else if (value < 0x10000) {
        try bytes.append(allocator, @intCast(0xe0 | (value >> 12)));
        try bytes.append(allocator, @intCast(0x80 | ((value >> 6) & 0x3f)));
        try bytes.append(allocator, @intCast(0x80 | (value & 0x3f)));
    } else {
        try bytes.append(allocator, @intCast(0xf0 | (value >> 18)));
        try bytes.append(allocator, @intCast(0x80 | ((value >> 12) & 0x3f)));
        try bytes.append(allocator, @intCast(0x80 | ((value >> 6) & 0x3f)));
        try bytes.append(allocator, @intCast(0x80 | (value & 0x3f)));
    }
}

pub fn decodeEscapedBytes(
    allocator: std.mem.Allocator,
    body: []const u8,
    allow_unicode: bool,
) ![]const u8 {
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
            'u' => {
                // `\u{...}` names a scalar value, so it contributes its UTF-8
                // encoding to the string's bytes rather than one byte. A byte
                // string has no such escape in Rust — `\u` there is rejected by
                // rustc — so the byte path keeps refusing it.
                if (!allow_unicode) return error.InvalidLiteral;
                const closing = std.mem.indexOfScalarPos(u8, body, i + 1, '}') orelse
                    return error.InvalidLiteral;
                const scalar = decodeRustUnicodeEscape(body[i - 1 .. closing + 1]) orelse
                    return error.InvalidLiteral;
                try appendUtf8Codepoint(allocator, &bytes, scalar);
                i = closing;
            },
            '\n', '\r' => {
                i += 1;
                while (i < body.len and switch (body[i]) {
                    ' ', '\t', '\n', '\r' => true,
                    else => false,
                }) i += 1;
                continue;
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

/// Decode a quoted Rust char literal to its Unicode scalar value.
/// Return null for unsupported or invalid literal syntax.
/// Borrows raw; allocates nothing.
pub fn decodeRustCharCodepoint(raw: []const u8) ?u32 {
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
        // The one parser for `\u{...}`, shared with the string decoder so a
        // char literal and a string literal cannot disagree about which code
        // points are valid.
        'u' => decodeRustUnicodeEscape(body) orelse null,
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
        const bytes = try decodeEscapedBytes(allocator, raw[prefix_len + 1 .. closing_quote], false);
        if (bytes.len == 1) return bytes;
        allocator.free(bytes);
        return null;
    }
    if (quote != '"') return null;
    if (raw.len < prefix_len + 2) return null;
    const closing_quote = raw.len - 1;
    if (raw[closing_quote] != '"') return null;
    const bytes = try decodeEscapedBytes(allocator, raw[prefix_len + 1 .. closing_quote], false);
    return bytes;
}

/// Decode Rust raw strings (`r".."`, `r#".."#`, `r##"a"b#c"##`).
///
/// Every hashed spelling is the same kind of literal as the unquoted one — the
/// hashes only decide where the body ends — so `r` alone is the test and
/// `decodeRawBytes` reads the count off BOTH ends. A guard that required the
/// quote right after the `r` turned every hashed spelling into an invalid
/// string literal, though that decoder already reads all of them. A null
/// result means that `raw` is not a raw string.
fn decodeRustRawString(allocator: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    if (raw.len == 0 or raw[0] != 'r') return null;
    return decodeRawBytes(allocator, raw, 1);
}

fn appendSourceStringLiteral(e: *Ext, bytes: []const u8) !exprs.NodeId {
    const borrowed_str: types.Ref = .{ .mut = false, .pointee = types.str_type };
    const candidate: types.Type = .{ .reference = &borrowed_str };
    const type_id = infer.findTypeIndexInSlice(e.ctx.types.items, candidate) orelse blk: {
        const reference = try e.ctx.alloc.create(types.Ref);
        errdefer e.ctx.alloc.destroy(reference);
        reference.* = borrowed_str;
        const id: exprs.TypeId = @intCast(e.ctx.types.items.len);
        try e.ctx.types.append(e.ctx.alloc, .{ .reference = reference });
        break :blk id;
    };
    const node = try appendExpr(e, .{ .literal = .{ .string = .{ .bytes = bytes } } });
    e.ctx.exprs.items[node].ty = type_id;
    return node;
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
    // A raw string is its own bytes; nothing inside it is an escape.
    const raw_string = decodeRustRawString(e.ctx.alloc, raw) catch
        return unsupported(e, "invalid raw string");
    if (raw_string) |raw_body| {
        return appendSourceStringLiteral(e, raw_body);
    }
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') {
        return unsupported(e, "invalid string literal");
    }
    // The source spelling is not the value: `"a\\nb"` is `a\nb` with ONE
    // backslash. Passing the spelling through emitted a Zig literal carrying
    // two, so the translated string compared unequal to the Rust one — wrong
    // output that still compiled. An escape this decoder does not know is
    // refused, never passed through: a half-decoded literal is the same class
    // of defect one level further on.
    const bytes = decodeEscapedBytes(e.ctx.alloc, raw[1 .. raw.len - 1], true) catch
        return unsupported(e, "unsupported string escape");
    return appendSourceStringLiteral(e, bytes);
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
            const base_node = firstValueChild(child) orelse return error.MalformedCst;
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
        // Every ITEM of a tuple pattern occupies a position, including the ones
        // no binding is read from: Rust writes `Variant(_, b)`, and that `_` is
        // an item. Tree-sitter hides it from `namedChild` — the wildcard is a
        // hidden rule around one anonymous token, so it inlines into this node
        // and is not a named child — and a pattern read as `[b]` rather than
        // `[_ , b]` renumbers `b` onto position 0, where it names the WHOLE
        // payload instead of the field the source asked for. `child` reports
        // every child in source order, so the items are walked over it and the
        // punctuation around them is dropped by kind: `namedChild` never saw
        // `(` and `,` either, and neither does `child`.
        var i: u32 = 0;
        while (node.child(i)) |child| : (i += 1) {
            if (child.id == type_node.id or isBlockTrivia(child)) continue;
            if (!child.isNamed() and !std.mem.eql(u8, child.kind(), "_")) continue;
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

        const resolved_def = def_opt orelse return appendPat(e, .{ .unsupported = .{
            .reason = "unresolved tuple struct pattern",
            .suggested_version = .v3,
        } });
        const def = try ensurePatternVariant(e, resolved_def, raw_type);

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

        const resolved_def = def_opt orelse return appendPat(e, .{ .unsupported = .{
            .reason = "unresolved struct pattern",
            .suggested_version = .v3,
        } });
        const def = try ensurePatternVariant(e, resolved_def, raw_type);
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
/// Null-id paths are lexical generic parameters and must remain for inference, and
/// a placeholder names nothing yet: a row holding one is not a finished type, and
/// sharing it would couple two literals that each owe the slot their own type.
fn isConcreteDeclaredReturnType(t: types.Type) bool {
    if (infer.isInferPlaceholderType(t)) return false;
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

/// The type parameters the entity a call names actually declares, or null when
/// none can be counted.
///
/// A `.method_ref` is a call-site reference with no declaration of its own, so
/// its count is the one the owner it hangs under declares: a trait keeps its
/// methods in its own body, and any other owner has the matching child.
fn calleeTypeParamCount(e: *const Ext, def: spine.EntityId) ?usize {
    if (def >= e.ctx.g.symbol_table.entities.items.len) return null;
    const entity = e.ctx.g.symbol_table.get(def) orelse return null;
    if (def < e.ctx.bodies_list.items.len) {
        switch (e.ctx.bodies_list.items[def]) {
            .fn_ => |body| return body.generic_params.len,
            .struct_ => |body| return body.generic_params.len,
            .enum_ => |body| return body.generic_params.len,
            else => {},
        }
    }
    if (entity.kind != .method_ref) return null;
    const owner = entity.parent orelse return null;
    if (owner >= e.ctx.bodies_list.items.len) return null;
    switch (e.ctx.bodies_list.items[owner]) {
        .trait_ => |body| {
            for (body.methods) |method| {
                if (std.mem.eql(u8, method.name, entity.name)) return method.generic_params.len;
            }
            return null;
        },
        else => {
            for (e.ctx.g.symbol_table.entities.items) |child| {
                if (child.kind != .fn_ or child.parent == null or child.parent.? != owner) continue;
                if (!std.mem.eql(u8, child.name, entity.name)) continue;
                if (child.id >= e.ctx.bodies_list.items.len) return null;
                return switch (e.ctx.bodies_list.items[child.id]) {
                    .fn_ => |body| body.generic_params.len,
                    else => return null,
                };
            }
        },
    }
    return null;
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
        var declared_arguments = true;
        for (generic_args) |argument| {
            if (isConcreteDeclaredReturnType(argument)) continue;
            if (argument == .path and argument.path.segments.len == 1 and
                argument.path.segments[0].id == null and
                activeTypeParameter(e, argument.path.segments[0].name)) continue;
            declared_arguments = false;
            break;
        }
        // A `.generic_inst` fills the type parameters its DECLARATION declares,
        // so an argument list of a different length is not an instantiation of
        // that declaration — it is the receiver witness a trait or blanket call
        // carries (`I::m()` names `I`; `u32::m()` names `u32`), and the callee
        // declares no parameter for it. Minting the instantiation anyway records
        // a type the crate never wrote, and `validateTypeContext` rejects it as
        // the incomplete metadata it is. The declared return, bound to the
        // receiver it names, is the honest type for the call — which is what
        // the two arms below publish, in that order.
        const callee_arity = calleeTypeParamCount(e, generic_decl);
        if (declared_arguments and callee_arity != null and callee_arity.? == generic_args.len) {
            const owned_args = try e.ctx.alloc.dupe(types.Type, generic_args);
            errdefer e.ctx.alloc.free(owned_args);
            const type_id = (try appendType(e, .{ .generic_inst = .{
                .decl = generic_decl,
                .args = .{ .params = owned_args },
            } })) orelse unreachable;
            e.ctx.exprs.items[id].ty = type_id;
        } else {
            try appendDeclaredCallReturnType(e, call_kind, id);
            try appendReceiverBoundCallReturnType(e, call_kind, generic_decl, id, generic_args);
        }
    } else {
        try appendDeclaredCallReturnType(e, call_kind, id);
    }
    return id;
}

/// The declared return of a callee whose type parameters belong to the `impl`
/// it sits in, with the receiver bound to them.
///
/// `impl<I> FromRadix10Checked for I { fn from_radix_10_checked(..) -> (Option<I>, usize) }`
/// declares no parameter of its own, so the argument list `appendGenericCall`
/// was handed is the RECEIVER, not a type argument list — and the callee's
/// declared return names the impl's parameter, which nothing in the callee can
/// settle. `u8::from_radix_10_checked(..)` is the one statement in the source
/// that says `I` is `u8`, and dropping it left the call node with no type at
/// all. Nothing downstream could recover it either: the comparison beside it
/// has no concrete peer to ask, so the `(Some(255), 3)` and `(None, 3)` tuple
/// rows that comparison exists to type kept the `_` placeholder, and a row is
/// what `validate` reads whether or not an expression still points at it.
///
/// The binding is admitted only where the owning `impl` declares exactly as
/// many type parameters as the argument list supplies, and only where the
/// result is CONCRETE afterwards. A call whose return stays open is left
/// untyped, which is what it already was, rather than handed a substituted row
/// nothing can act on. A declared return that names no parameter is unchanged
/// by substitution, so this publishes exactly what `appendDeclaredCallReturnType`
/// would have and only ever adds the rows the two together could not reach.
/// Whether the call node already carries exactly the callee's declared return:
/// the row `appendDeclaredCallReturnType` wrote when the declaration looked
/// concrete enough to pin, before the receiver was bound. That row is the one
/// thing this producer may still replace, and it is recognized WITHOUT
/// touching heap payloads: the declared return is the callee's own value, so
/// the published row only has to BE that value for the overwrite to be this
/// producer answering its own question twice, never inference's answer being
/// thrown away. Anything else the table holds is somebody else's decision,
/// and this producer leaves the node exactly as it found it.
fn rowStillReadsDeclared(published: types.Type, declared: types.Type) bool {
    if (std.meta.activeTag(published) != std.meta.activeTag(declared)) return false;
    return switch (published) {
        .prim => |value| value == declared.prim,
        .path => |path| blk: {
            if (path.segments.len != declared.path.segments.len) break :blk false;
            for (path.segments, declared.path.segments) |pub_seg, decl_seg| {
                if (!std.mem.eql(u8, pub_seg.name, decl_seg.name)) break :blk false;
                if ((pub_seg.id == null) != (decl_seg.id == null)) break :blk false;
                if (pub_seg.id) |pub_id| {
                    if (pub_id != decl_seg.id.?) break :blk false;
                }
            }
            break :blk true;
        },
        .tuple => |tuple| blk: {
            if (tuple.len == 0 or tuple.len != declared.tuple.len) break :blk false;
            for (tuple, declared.tuple) |pub_elem, decl_elem| {
                if (!rowStillReadsDeclared(pub_elem, decl_elem)) break :blk false;
            }
            break :blk true;
        },
        .option => |inner| declared == .option and
            rowStillReadsDeclared(inner.*, declared.option.*),
        else => false,
    };
}

fn appendReceiverBoundCallReturnType(
    e: *Ext,
    call_kind: exprs.CallKind,
    def: spine.EntityId,
    call_id: exprs.NodeId,
    receiver_args: []const types.Type,
) anyerror!void {
    switch (call_kind) {
        .free, .associated => {},
        .constructor => return,
    }
    if (receiver_args.len == 0) return;
    if (def >= e.ctx.bodies_list.items.len) return;
    const fn_body = switch (e.ctx.bodies_list.items[def]) {
        .fn_ => |value| value,
        else => return,
    };
    if (fn_body.generic_params.len != 0) return;
    const entity = e.ctx.g.symbol_table.get(def) orelse return;
    const owner = entity.parent orelse return;
    if (owner >= e.ctx.bodies_list.items.len) return;
    const impl_body = switch (e.ctx.bodies_list.items[owner]) {
        .impl_ => |value| value,
        else => return,
    };
    const params = impl_body.generics orelse return;
    if (params.params.len != receiver_args.len) return;
    const names = try e.ctx.alloc.alloc([]const u8, params.params.len);
    defer e.ctx.alloc.free(names);
    for (params.params, 0..) |param, index| {
        switch (param) {
            .type_ => |value| names[index] = value.name,
            else => return,
        }
    }
    const substituted = types.substType(e.ctx.alloc, fn_body.ret, names, receiver_args) catch return;
    if (!isConcreteDeclaredReturnType(substituted)) {
        types.freeSubstitutedType(e.ctx.alloc, fn_body.ret, substituted, names, receiver_args);
        return;
    }
    // The row `appendDeclaredCallReturnType` wrote may still be there: the
    // callee's own return, decided by nobody, which the receiver now binds.
    // Overwriting THAT row is safe exactly because nothing decided it —
    // `rowStillReadsDeclared` proves it still reads the declaration, leaf for
    // leaf — while any other row is inference's or a peer's answer and this
    // producer leaves it alone. A merely-nearby row never qualifies: the
    // comparison walks only the containers the two rows share.
    if (e.ctx.exprs.items[call_id].ty) |published_id| {
        if (published_id >= e.ctx.types.items.len) {
            types.freeSubstitutedType(e.ctx.alloc, fn_body.ret, substituted, names, receiver_args);
            return;
        }
        if (!rowStillReadsDeclared(e.ctx.types.items[published_id], fn_body.ret)) {
            // Somebody else's decision — inference's, or a peer producer's:
            // the substitution dies with the guarded `freeSubstitutedType`
            // the earlier arms already ran, and the node keeps its row.
            types.freeSubstitutedType(e.ctx.alloc, fn_body.ret, substituted, names, receiver_args);
            return;
        }
    }
    // The published row OWNS what `substType` allocated. `appendType` copies the
    // `Type` VALUE into the table, so the `.tuple` slice and the `.option`
    // payload that value points at have to outlive the model. Releasing the
    // substitution here — `freeSubstitutedType` destroys exactly those two
    // containers — left the table row pointing at released memory, and every
    // later reader of it walked garbage: `containsInferPlaceholderDepth` on a
    // `(Option<u8>, usize)` row raised `switch on corrupt value` out of
    // `isInferPlaceholderType`, from `pinKnownType`, on three atoi fixtures.
    // `freeSubstitutedType` is documented to run "after its last use", and a row
    // in the type table is used for the rest of the model's life, so that use
    // does not end here and ownership passes to the arena with it. Publishing
    // without releasing is the same rule `appendDeclaredCallReturnType`
    // follows when it publishes an unsubstituted declared return.
    const published = try appendType(e, substituted);
    if (published == null) {
        types.freeSubstitutedType(e.ctx.alloc, fn_body.ret, substituted, names, receiver_args);
        return;
    }
    e.ctx.exprs.items[call_id].ty = published;
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
    const receiver_id = try lowerExpr(e, receiver);
    if (generic_args.len == 0) {
        if (try appendTypedStandardMethod(e, receiver_id, method_name, args)) |standard|
            return standard;
    }
    return appendExpr(e, .{ .method_call = .{
        .receiver = receiver_id,
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

fn normalizedCrateNameEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if ((if (a == '-') @as(u8, '_') else a) !=
            (if (b == '-') @as(u8, '_') else b)) return false;
    }
    return true;
}

/// Cargo's dependency key is the source root, but `package` establishes the
/// runtime identity. Do not admit an unrelated package renamed `rand_core`.
fn externalPackageRootMatches(e: *const Ext, source_root: []const u8, package: []const u8) bool {
    for (e.ctx.g.crates.items) |crate| {
        if (!e.ctx.g.entityBelongsToRoot(e.fn_id, crate.root)) continue;
        for (crate.deps) |dependency| {
            if (normalizedCrateNameEqual(source_root, dependency.local_alias) or
                normalizedCrateNameEqual(source_root, dependency.extern_name))
                return normalizedCrateNameEqual(dependency.extern_name, package);
        }
    }
    return normalizedCrateNameEqual(source_root, package);
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
    if (externalPackageRootMatches(e, canonical[0], "rand_core") and
        std.mem.eql(u8, canonical[1], "impls") and
        std.mem.eql(u8, canonical[2], "fill_bytes_via_next")) return .rng_fill_bytes_via_next;
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
        // A module-qualified head names itself through the module's own `use`:
        // `use core::hash;` followed by `impl hash::Hasher for T` IS
        // `core::hash::Hasher`, and the source never wrote that path out. The
        // written segments alone would answer no for that spelling and yes for
        // the spelled-out one, so the head is resolved to the identity the
        // import proves BEFORE the standard path is compared. A head no import
        // binds keeps the spelling it was written with, and the comparison is
        // over the whole path — never a leaf, never a prefix — so a crate's own
        // homonym stays refused.
        if (try externalNominalForPath(e, raw)) |canonical| {
            defer {
                for (canonical.path) |segment| e.ctx.alloc.free(segment);
                e.ctx.alloc.free(canonical.path);
            }
            return externalPathMatchesStandard(canonical.path, wanted);
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
        const super_id = resolveSupertraitPath(e, trait_id, supertrait) orelse continue;
        if (try traitHasStandardSupertrait(e, super_id, wanted, depth + 1)) return true;
    }
    return false;
}

/// Supertraits of the standard numeric traits this translator admits by name.
///
/// `num_traits` is an external crate, so its trait declarations are not graph
/// entities and their supertrait lists cannot be read — the graph walk in
/// `traitHasStandardSupertrait` has nothing to descend. Without these edges a
/// bound that reaches `One` only through `Signed: Num: One` is refused for a
/// capability it really grants, which is exactly how `atoi` writes
/// `pub fn signum<I>(self) -> I where I: Signed { I::one() }`.
const standard_numeric_supertraits = [_]struct { trait_name: []const u8, super_name: []const u8 }{
    .{ .trait_name = "Num", .super_name = "Zero" },
    .{ .trait_name = "Num", .super_name = "One" },
    .{ .trait_name = "Signed", .super_name = "Num" },
    .{ .trait_name = "Unsigned", .super_name = "Num" },
    .{ .trait_name = "PrimInt", .super_name = "Num" },
    .{ .trait_name = "PrimInt", .super_name = "Bounded" },
};

fn numericTraitReachesByName(name: []const u8, wanted: []const []const u8, depth: usize) bool {
    if (depth > 4 or wanted.len == 0) return false;
    if (std.mem.eql(u8, name, wanted[wanted.len - 1])) return true;
    for (standard_numeric_supertraits) |edge| {
        if (!std.mem.eql(u8, edge.trait_name, name)) continue;
        if (numericTraitReachesByName(edge.super_name, wanted, depth + 1)) return true;
    }
    return false;
}

/// Whether an EXTERNAL standard trait reaches `wanted` by name, following the
/// supertrait edges above.
///
/// Only a bound whose terminal carries no entity reaches this, so a crate's own
/// `Signed` — which does have an entity, and keeps its own meaning — never does.
fn externalNumericTraitReaches(
    bound: types.Bound,
    wanted: []const []const u8,
    depth: usize,
) bool {
    if (depth > 4) return false;
    if (bound.path.segments.len == 0 or wanted.len == 0) return false;
    const terminal = bound.path.segments[bound.path.segments.len - 1];
    if (terminal.id != null) return false;
    return numericTraitReachesByName(terminal.name, wanted, depth);
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
                    } else if (externalNumericTraitReaches(bound, trait_path, 0)) {
                        return true;
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
                    } else if (externalNumericTraitReaches(bound, trait_path, 0)) {
                        return true;
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
        const super_id = resolveSupertraitPath(e, trait_id, supertrait) orelse continue;
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
        const super_id = resolveSupertraitPath(e, trait_id, supertrait) orelse continue;
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

/// A standard-library container that `From` is admitted on when the source
/// names it as the receiver of an associated call. `String` was the first;
/// `Vec` is the same shape — a container built from a slice — so both live in
/// one table rather than as separate arms.
const std_from_receivers = [_]struct { name: []const u8, path: []const u8 }{
    .{ .name = "String", .path = "alloc::string::String" },
    .{ .name = "Vec", .path = "alloc::vec::Vec" },
};

/// The external nominal a `From` receiver name stands for, or null when the
/// name is not one of the admitted containers.
fn stdFromReceiverNominal(e: *Ext, name: []const u8) anyerror!?types.Type {
    for (std_from_receivers) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        const external = (try externalNominalForPath(e, entry.path)) orelse return null;
        return .{ .external_nominal = external };
    }
    return null;
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

    // `Vec::from(..)` names its receiver, so there is no receiver expression
    // to read a type from and no type parameter to look a bound up under. The
    // std container is therefore admitted by NAME, and only when the crate has
    // not declared something by that name itself — a local `Vec` keeps its own
    // `from`. This is the same admission `String::from` already had, widened
    // to every container `From` is written on, not a second path beside it.
    var receiver = try activeGenericReceiver(e, receiver_name);
    if (receiver) |generic_receiver| {
        if (args.len == 0 and boundAssociatedMethodTrait(e, receiver_name, method_name) == null) {
            const identity_trait: ?[]const u8 = if (std.mem.eql(u8, method_name, "zero"))
                "Zero"
            else if (std.mem.eql(u8, method_name, "one"))
                "One"
            else
                null;
            const is_min = std.mem.eql(u8, method_name, "min_value");
            const is_max = std.mem.eql(u8, method_name, "max_value");
            const trait_name = identity_trait orelse if (is_min or is_max) "Bounded" else "";
            const module_name = if (identity_trait != null) "identities" else "bounds";
            if (trait_name.len > 0 and
                ((try genericHasStandardTraitBound(e, generic_receiver, &.{ "num_traits", trait_name })) or
                    (try genericHasStandardTraitBound(e, generic_receiver, &.{ "num_traits", module_name, trait_name })) or
                    (try genericHasStandardTraitBound(e, generic_receiver, &.{ "num_traits", "PrimInt" })) or
                    (try genericHasStandardTraitBound(e, generic_receiver, &.{ "num_traits", "int", "PrimInt" }))))
            {
                const target = (try appendType(e, generic_receiver)) orelse unreachable;
                const id = try appendExpr(e, .{ .core_call = .{
                    .function = if (identity_trait != null)
                        (if (std.mem.eql(u8, method_name, "zero")) .numeric_zero else .numeric_one)
                    else if (is_min)
                        .numeric_min_value
                    else
                        .numeric_max_value,
                    .generic_args = try e.ctx.alloc.dupe(types.Type, &.{generic_receiver}),
                    .args = args,
                } });
                e.ctx.exprs.items[id].ty = target;
                return id;
            }
        }
    }
    var named_receiver = false;
    if (receiver == null and std.mem.eql(u8, method_name, "from") and
        resolveName(e, receiver_name) == null)
    {
        if (try stdFromReceiverNominal(e, receiver_name)) |named| {
            receiver = named;
            named_receiver = true;
        }
    }
    if (receiver == null) {
        if (!std.mem.eql(u8, method_name, "default")) return null;
        const primitive = mapPrim(receiver_name) orelse return null;
        receiver = .{ .prim = primitive };
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
        // Admitted by name above, or by a `From` bound on a type parameter.
        // Anything else is a `from` this translator has not admitted, and is
        // refused rather than lowered as an arbitrary conversion.
        if (!named_receiver and
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

/// The canonical generic owner of `MaybeUninit::<T>::uninit()`.
/// A source homonym remains a source call: its owner is not this external type.
fn appendMaybeUninitUninit(
    e: *Ext,
    owner: types.ExternalNominal,
    method_name: []const u8,
    args: []const exprs.NodeId,
) anyerror!?exprs.NodeId {
    if (!std.mem.eql(u8, method_name, "uninit") or
        owner.args.len != 1 or owner.path.len != 3 or
        !std.mem.eql(u8, owner.path[0], "core") or
        !std.mem.eql(u8, owner.path[1], "mem") or
        !std.mem.eql(u8, owner.path[2], "MaybeUninit"))
    {
        return null;
    }
    if (args.len != 0) {
        e.ctx.alloc.free(args);
        return try unsupported(e, "MaybeUninit::uninit call takes no arguments");
    }
    const call = try appendExpr(e, .{ .core_call = .{
        .function = .maybe_uninit_uninit,
        .generic_args = owner.args,
        .args = args,
    } });
    // The semantic result stays MaybeUninit<T>; only backend layout erases it.
    // Its enclosing array literal, not this element, owns the repeat length.
    e.ctx.exprs.items[call].ty = try appendType(e, .{ .external_nominal = owner });
    return call;
}

fn pinKnownOperand(e: *Ext, id: exprs.NodeId) anyerror!?types.Type {
    const ty = knownCastOperandType(e, id) orelse return null;
    if (e.ctx.exprs.items[id].ty == null) e.ctx.exprs.items[id].ty = try appendType(e, ty);
    return ty;
}

fn appendTypedStandardMethod(e: *Ext, receiver: exprs.NodeId, name: []const u8, args: []const exprs.NodeId) anyerror!?exprs.NodeId {
    const declared = (try pinKnownOperand(e, receiver)) orelse return null;
    const ty = if (declared == .reference) declared.reference.pointee else declared;
    if (std.mem.eql(u8, name, "copy_to_nonoverlapping") and ty == .raw_ptr and args.len == 2) {
        const generics = try e.ctx.alloc.dupe(types.Type, &.{ty.raw_ptr.pointee});
        const source = if (declared == .reference) blk: {
            const deref = try appendExpr(e, .{ .unary = .{ .op = .deref, .operand = receiver } });
            e.ctx.exprs.items[deref].ty = try appendType(e, ty);
            break :blk deref;
        } else receiver;
        const ordered = try e.ctx.alloc.dupe(exprs.NodeId, &.{ source, args[0], args[1] });
        for (ordered) |arg| _ = try pinKnownOperand(e, arg);
        const id = try appendExpr(e, .{ .core_call = .{
            .function = .ptr_copy_nonoverlapping,
            .generic_args = generics,
            .args = ordered,
        } });
        e.ctx.exprs.items[id].ty = try appendType(e, .{ .prim = .unit });
        e.ctx.alloc.free(args);
        return id;
    }
    if (std.mem.eql(u8, name, "to_vec") and args.len == 0 and (ty == .slice or ty == .array)) {
        var owner = (try externalNominalForPath(e, "alloc::vec::Vec")) orelse return null;
        owner.args = try e.ctx.alloc.dupe(types.Type, &.{if (ty == .slice) ty.slice.elem else ty.array.elem});
        const target: types.Type = .{ .external_nominal = owner };
        const id = try appendExpr(e, .{ .core_call = .{
            .function = .convert_from,
            .generic_args = try e.ctx.alloc.dupe(types.Type, &.{target}),
            .args = try e.ctx.alloc.dupe(exprs.NodeId, &.{receiver}),
        } });
        e.ctx.exprs.items[id].ty = try appendType(e, target);
        e.ctx.alloc.free(args);
        return id;
    }
    return null;
}

fn appendHasherUfcs(e: *Ext, raw: []const u8, args: []const exprs.NodeId) anyerror!?exprs.NodeId {
    const separator = std.mem.lastIndexOf(u8, raw, "::") orelse return null;
    const method = raw[separator + 2 ..];
    // `Hasher::write` is the one standard method whose payload is not a
    // primitive: it takes a byte slice, so there is no `mapPrim` spelling to
    // read. The `write_` spellings keep their exact primitive whitelist, and a
    // bare `write` is admitted with no payload at all — which is what makes the
    // `hash_write_primitive` fallback below unreachable for it.
    if (args.len != 2) return null;
    const bare_write = std.mem.eql(u8, method, "write");
    if (!bare_write and !std.mem.startsWith(u8, method, "write_")) return null;
    const primitive: ?types.Prim = if (bare_write) null else (mapPrim(method["write_".len..]) orelse return null);
    if (primitive) |payload| {
        switch (payload) {
            .u8, .u16, .u32, .u64, .usize, .i8, .i16, .i32, .i64, .isize => {},
            else => return null,
        }
    }
    const owner = (try externalNominalForPath(e, raw[0..separator])) orelse return null;
    defer {
        for (owner.path) |part| e.ctx.alloc.free(part);
        e.ctx.alloc.free(owner.path);
    }
    if (owner.path.len != 3 or
        (!std.mem.eql(u8, owner.path[0], "core") and !std.mem.eql(u8, owner.path[0], "std")) or
        !std.mem.eql(u8, owner.path[1], "hash") or !std.mem.eql(u8, owner.path[2], "Hasher")) return null;
    const receiver = (try pinKnownOperand(e, args[0])) orelse return null;
    const actual = if (receiver == .reference) receiver.reference.pointee else receiver;
    if (actual == .path and actual.path.segments.len == 1 and actual.path.segments[0].id == null and
        (try genericHasStandardTraitBound(e, actual, &.{ "core", "hash", "Hasher" })))
    {
        const id = try appendExpr(e, .{ .method_call = .{
            .receiver = args[0],
            .receiver_mode = .mutable,
            .method = try pushMethodRef(e, method),
            .args = try e.ctx.alloc.dupe(exprs.NodeId, args[1..]),
        } });
        e.ctx.exprs.items[id].ty = try appendType(e, .{ .prim = .unit });
        e.ctx.alloc.free(args);
        return id;
    }
    // Two impls of `core::hash::Hasher` for one receiver would be a coherence
    // error rustc rejects long before this point, so a second answer means the
    // graph lost a distinction the source kept: binding either one would emit a
    // call into an implementation the source never named.
    var bound: ?spine.EntityId = null;
    for (e.ctx.g.symbol_table.entities.items) |implementation| {
        if (implementation.kind != .impl_ or implementation.id >= e.ctx.bodies_list.items.len) continue;
        const body = switch (e.ctx.bodies_list.items[implementation.id]) {
            .impl_ => |value| value,
            else => continue,
        };
        if (!infer.typeEqual(body.self_ty, actual)) continue;
        const trait_path = body.trait_path orelse continue;
        // The impl's OWN scope names the trait, not the scope this call is
        // lowered in: siphasher writes `impl hash::Hasher for SipHasher13`
        // beside a `use core::hash;` in `sip.rs` and calls `Hasher::write`
        // from `tests.rs`, which imports `Hasher` and nothing named `hash`,
        // so the written spelling resolved against the current module found
        // no `hash` to expand and the call fell through to `unresolved call`.
        // `boundPathMatches` reads the segments the binder already resolved
        // and falls back to the OWNER's `use` chain, and it is the matcher the
        // method pass uses for this same impl, so the two cannot disagree.
        if (!bodies.boundPathMatches(e.ctx.g, implementation.id, trait_path, &.{ "core", "hash", "Hasher" })) continue;
        for (e.ctx.g.symbol_table.entities.items) |source_method| {
            if (source_method.kind != .fn_ or source_method.parent != implementation.id or
                !std.mem.eql(u8, source_method.name, method)) continue;
            if (bound != null) return null;
            bound = source_method.id;
        }
    }
    if (bound) |target| return try appendGenericCall(e, .{ .associated = target }, args, &.{});
    // The native primitive write is the LAST resort for a receiver this crate
    // does not implement `core::hash::Hasher` for. A bare `write` carries a
    // byte slice, not a primitive, so fabricating one here would silently
    // miscompile the call: without a source-backed implementation there is
    // nothing honest to lower it to.
    const payload = primitive orelse return null;
    e.ctx.exprs.items[args[1]].ty = try appendType(e, .{ .prim = payload });
    const id = try appendExpr(e, .{ .core_call = .{
        .function = .hash_write_primitive,
        .generic_args = try e.ctx.alloc.dupe(types.Type, &.{.{ .prim = payload }}),
        .args = args,
    } });
    e.ctx.exprs.items[id].ty = try appendType(e, .{ .prim = .unit });
    return id;
}

fn lowerCall(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const callee = firstValueChild(node) orelse return error.MalformedCst;
    var callee_base = callee;
    var generic_args: []const types.Type = &.{};
    if (std.mem.eql(u8, callee.kind(), "generic_function")) {
        if (callee.childByFieldName("function")) |function_node| {
            callee_base = function_node;
        } else {
            var found_function = false;
            var child_index: u32 = 0;
            while (callee.namedChild(child_index)) |child| : (child_index += 1) {
                if (isBlockTrivia(child)) continue;
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
        const recv = valueChild(callee_base, 0) orelse return error.MalformedCst;
        const method = valueChild(callee_base, 1) orelse return error.MalformedCst;
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

        // Rust `x.to_ne_bytes()` → the runtime's native-endian transmute.
        if (std.mem.eql(u8, mname, "to_ne_bytes") and generic_args.len == 0 and
            iteratorArgumentsEmpty(call_args))
        {
            if (try appendToNeBytes(e, try lowerExpr(e, recv))) |bytes| return bytes;
        }

        // Rust `x.to_le_bytes()` → the little-endian encoding. It cannot share
        // the native-endian path above, because on a big-endian target the two
        // differ by a byte swap and only one of them is the value the source
        // asked for.
        if (std.mem.eql(u8, mname, "to_le_bytes") and generic_args.len == 0 and
            iteratorArgumentsEmpty(call_args))
        {
            if (try appendToLeBytes(e, try lowerExpr(e, recv))) |bytes| return bytes;
        }

        const method_def = try pushMethodRef(e, mname);
        const args = try lowerArgs(e, call_args);
        const receiver_id = try lowerExpr(e, recv);
        if (generic_args.len == 0) {
            if (try appendTypedStandardMethod(e, receiver_id, mname, args)) |standard|
                return standard;
        }
        // The turbofish on `recv.method::<T>(..)` is the callee's own, so it is
        // recorded here rather than dropped. `generic_args` is freed on
        // function exit, hence the dupe.
        return appendExpr(e, .{ .method_call = .{
            .receiver = receiver_id,
            .receiver_mode = .value,
            .method = method_def,
            .generic_args = try e.ctx.alloc.dupe(types.Type, generic_args),
            .args = args,
        } });
    }

    // free / associated / enum-variant / constructor call
    const args: []const exprs.NodeId = try lowerArgs(e, call_args);
    if (callee_base.childByFieldName("path")) |owner_node| {
        if (std.mem.eql(u8, owner_node.kind(), "generic_type") or
            std.mem.eql(u8, owner_node.kind(), "generic_type_with_turbofish"))
        {
            const owner_type: ?types.Type = mapCstNamedType(e, owner_node) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            };
            const variant_node = callee_base.childByFieldName("name") orelse callee_base.namedChild(1);
            if (owner_type != null and owner_type.? == .external_nominal and variant_node != null) {
                const owner = owner_type.?.external_nominal;
                const variant = text(e, variant_node.?);
                if (generic_args.len == 0) {
                    if (try appendMaybeUninitUninit(e, owner, variant, args)) |uninit| {
                        return uninit;
                    }
                }
                if (owner.path.len == 3 and
                    (std.mem.eql(u8, owner.path[0], "alloc") or std.mem.eql(u8, owner.path[0], "std")) and
                    std.mem.eql(u8, owner.path[1], "borrow") and std.mem.eql(u8, owner.path[2], "Cow") and
                    (std.mem.eql(u8, variant, "Owned") or std.mem.eql(u8, variant, "Borrowed")))
                {
                    const id = try appendExpr(e, .{ .external_variant = .{
                        .owner = owner,
                        .variant = try e.ctx.alloc.dupe(u8, variant),
                        .tuple_fields = args,
                        .named_fields = &.{},
                    } });
                    e.ctx.exprs.items[id].ty = try appendType(e, owner_type.?);
                    return id;
                }
            }
        }
    }
    if (generic_args.len == 0) {
        if (try appendHasherUfcs(e, text(e, callee_base), args)) |hash_call| return hash_call;
    }
    if (std.mem.eql(u8, callee_base.kind(), "scoped_identifier") or
        std.mem.eql(u8, callee_base.kind(), "scoped_type_identifier"))
    {
        if (try lowerBoundCoreAssociatedCall(e, text(e, callee_base), args, generic_args)) |core_call| {
            return core_call;
        }
    }
    if (try coreFunction(e, text(e, callee_base))) |function| {
        if (function == .rng_fill_bytes_via_next) {
            for (args) |arg| _ = try pinKnownOperand(e, arg);
        }
        const id = try appendExpr(e, .{ .core_call = .{
            .function = function,
            .generic_args = try e.ctx.alloc.dupe(types.Type, generic_args),
            .args = args,
        } });
        if (function == .rng_fill_bytes_via_next)
            e.ctx.exprs.items[id].ty = try appendType(e, .{ .prim = .unit });
        return id;
    }

    if (std.mem.eql(u8, callee_base.kind(), "scoped_identifier") or
        std.mem.eql(u8, callee_base.kind(), "scoped_type_identifier"))
    {
        // Struct::method(...) / Enum::Variant(...) / Self::method(...) /
        // Type::constructor(...). Split the scoped path at "::".
        if (try primitiveSourceAssociatedCall(e, text(e, callee_base), args, generic_args)) |source_call|
            return source_call;
        if (try traitMethodForPath(e, callee_base)) |method| {
            return appendGenericCall(e, .{ .associated = method }, args, generic_args);
        }
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
        if (primitiveFromNeBytesTarget(t)) |target_primitive| {
            if (generic_args.len != 0) {
                e.ctx.alloc.free(args);
                return unsupported(e, "primitive from_ne_bytes call");
            }
            return appendPrimitiveFromNeBytes(e, target_primitive, args);
        }
        if (primitiveFromLeBytesTarget(t)) |target_primitive| {
            if (generic_args.len != 0) {
                e.ctx.alloc.free(args);
                return unsupported(e, "primitive from_le_bytes call");
            }
            return appendPrimitiveFromLeBytes(e, target_primitive, args);
        }
        if (primitiveAssocConstTarget(t)) |assoc_const| {
            if (generic_args.len != 0) {
                e.ctx.alloc.free(args);
                return unsupported(e, "primitive associated const call");
            }
            return appendPrimitiveAssocConst(e, assoc_const.prim, assoc_const.entry, args);
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
        if (try activeGenericReceiver(e, base_name)) |generic_receiver| {
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
                    if (generic_args.len == 0) &.{generic_receiver} else generic_args,
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

        // An associated function of an external nominal — `io::Cursor::new` —
        // admitted last, after every local owner has had its chance. The
        // backend decides whether it can lower it.
        if (try lowerExternalAssociatedCall(e, t, args, generic_args)) |external_call| {
            return external_call;
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
        firstValueChild(let_node) orelse return error.MalformedCst;
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
            if (isBlockTrivia(a)) continue;
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

/// The value an `else` branch produces, or null when it is not one expression
/// — a chained `else if` is a conditional of its own and an absent branch
/// produces nothing, so neither answers for the arms of this one.
fn elseBranchTail(else_branch: exprs.ElseBranch) ?exprs.NodeId {
    return switch (else_branch) {
        .block => |block| block.tail,
        .chain, .none => null,
    };
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
        try pinStandardResultArms(e, then_blk.tail, elseBranchTail(else_branch));
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
    try pinStandardResultArms(e, then_blk.tail, elseBranchTail(else_branch));
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
    return decodeEscapedBytes(alloc, literal[1 .. literal.len - 1], true);
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

/// Lower `matches!(scrutinee, pattern)` to the IR shape a source `match`
/// already produces: one arm whose patterns are the `|`-separated alternatives
/// answering `true`, and a wildcard arm answering `false` — the two arms the
/// macro's own expansion spells. The pattern text is parsed through the same
/// wrapper-subexpression parse `parseAndLowerSubExpr` uses, so each
/// alternative reaches `lowerPattern` through the identical node shape a
/// `match_arm`'s own pattern does; a token tree the grammar will not accept
/// as a pattern is a fatal `MalformedCst`, never a guessed variant. Bodies
/// are boolean literals, so inference unifies the arms to `bool` exactly as
/// it does for a source match over literals, and the backend lowers the same
/// `.match` it already lowers. An or-alternative that lowers to an
/// `.unsupported` pattern marks the whole invocation the way `lowerMatch`
/// marks a source match whose pattern it cannot admit.
fn lowerMatchesMacro(e: *Ext, raw_tokens: []const u8) anyerror!exprs.NodeId {
    const macro_args = try expand.splitMacroArgs(e.ctx.alloc, raw_tokens);
    defer e.ctx.alloc.free(macro_args);
    if (macro_args.len != 2)
        return unsupported(e, "matches macro requires a scrutinee and a pattern");
    const scrutinee = try parseAndLowerSubExpr(e, macro_args[0]);
    const pattern_text = std.mem.trim(u8, macro_args[1], " \t\r\n");
    if (pattern_text.len == 0) return unsupported(e, "matches macro requires a pattern");

    var alternatives: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
    defer alternatives.deinit(e.ctx.alloc);
    var cursor: usize = 0;
    var depth_paren: usize = 0;
    var depth_bracket: usize = 0;
    var depth_brace: usize = 0;
    var alternative_start: usize = 0;
    while (cursor < pattern_text.len) {
        const c = pattern_text[cursor];
        switch (c) {
            '(' => depth_paren += 1,
            ')' => depth_paren -|= 1,
            '[' => depth_bracket += 1,
            ']' => depth_bracket -|= 1,
            '{' => depth_brace += 1,
            '}' => depth_brace -|= 1,
            '|' => if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0) {
                const fragment = std.mem.trim(u8, pattern_text[alternative_start..cursor], " \t\r\n");
                if (fragment.len == 0) return unsupported(e, "matches macro requires a pattern");
                try alternatives.append(e.ctx.alloc, try parseMatchPatternText(e, fragment));
                alternative_start = cursor + 1;
            },
            else => {},
        }
        cursor += 1;
    }
    const last = std.mem.trim(u8, pattern_text[alternative_start..], " \t\r\n");
    if (last.len == 0) return unsupported(e, "matches macro requires a pattern");
    try alternatives.append(e.ctx.alloc, try parseMatchPatternText(e, last));

    for (alternatives.items) |pat_id| {
        if (patternContainsUnsupported(e, pat_id))
            return unsupported(e, "unsupported matches pattern");
    }

    const hit_arm_body = try appendExpr(e, .{ .literal = .{ .boolean = true } });
    const miss_arm_body = try appendExpr(e, .{ .literal = .{ .boolean = false } });
    const miss_pat = try appendPat(e, .{ .wildcard = {} });
    var arms: std.ArrayListUnmanaged(exprs.MatchArm) = .empty;
    defer arms.deinit(e.ctx.alloc);
    try arms.append(e.ctx.alloc, .{
        .patterns = try alternatives.toOwnedSlice(e.ctx.alloc),
        .guard = null,
        .body = hit_arm_body,
    });
    const miss_patterns = try e.ctx.alloc.alloc(exprs.NodeId, 1);
    miss_patterns[0] = miss_pat;
    try arms.append(e.ctx.alloc, .{
        .patterns = miss_patterns,
        .guard = null,
        .body = miss_arm_body,
    });
    return appendExpr(e, .{ .match = .{
        .scrutinee = scrutinee,
        .arms = try arms.toOwnedSlice(e.ctx.alloc),
        .option_scrutinee = false,
    } });
}

/// Parse one `matches!` or-alternative through the expression-statement
/// wrapper `match_arm` patterns come from, so the node `lowerPattern` sees is
/// the same `pattern` wrapper a source `match` hands it.
fn parseMatchPatternText(e: *Ext, fragment: []const u8) anyerror!exprs.NodeId {
    const prefix = "fn __macro_pat__() { let __probe = 0; match __probe { ";
    const suffix = " => true, _ => false, } }";
    const wrapped = try std.fmt.allocPrint(e.ctx.alloc, "{s}{s}{s}", .{ prefix, fragment, suffix });
    defer e.ctx.alloc.free(wrapped);

    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(rust.language());
    const tree = parser.parseString(wrapped, null) orelse return error.MalformedCst;
    defer tree.destroy();

    const root = tree.rootNode();
    if (root.hasError()) return error.MalformedCst;
    const fn_node = root.namedChild(0) orelse return error.MalformedCst;
    var block_node: ?ts.Node = null;
    var i: u32 = 0;
    while (fn_node.namedChild(i)) |c| : (i += 1) {
        if (std.mem.eql(u8, c.kind(), "block")) {
            block_node = c;
            break;
        }
    }
    const blk = block_node orelse return error.MalformedCst;
    var arm_node: ?ts.Node = null;
    var j: u32 = 0;
    while (blk.namedChild(j)) |c| : (j += 1) {
        // `match_expression` is not in the grammar's `_expression`, so a bare
        // `match` in statement position is never a block child directly: it
        // arrives through `expression_statement`'s block-ending branch. The
        // same wrapper is what `parseAndLowerSubExpr`, `lowerBlock` and
        // `lowerIf` all step over, and reading past it here is what left
        // `arm_node` null for every `matches!` alternative.
        const unwrapped = if (std.mem.eql(u8, c.kind(), "expression_statement"))
            c.namedChild(0)
        else
            c;
        const match_node = unwrapped orelse continue;
        if (!std.mem.eql(u8, match_node.kind(), "match_expression")) continue;
        const body = match_node.childByFieldName("body") orelse return error.MalformedCst;
        var k: u32 = 0;
        while (body.namedChild(k)) |arm| : (k += 1) {
            if (std.mem.eql(u8, arm.kind(), "match_arm")) {
                arm_node = arm;
                break;
            }
        }
        break;
    }
    const arm = arm_node orelse return error.MalformedCst;
    const pattern_wrapper = arm.childByFieldName("pattern") orelse return error.MalformedCst;
    const pattern_node = firstMatchPatternChild(pattern_wrapper) orelse return error.MalformedCst;

    const orig_src = e.ctx.src;
    e.ctx.src = wrapped;
    defer e.ctx.src = orig_src;
    return lowerPattern(e, pattern_node);
}

/// `format!` is deliberately still a refusal, stated plainly. Its expansion —
/// the rendered template as an OWNED `String` — has no producer: `write!`'s
/// `format_write` shape needs a writer operand `format!` never writes, and no
/// IR node carries an allocating sink the backend could lower. Guessing one
/// would invent an emission that does not exist, so this honours the
/// no-pin-a-refusal-as-a-shape contract by naming the limitation instead.
/// This exists so `lowerMacroInvocation`'s pre-switch routing names the
/// reason in one place rather than scattering string literals.
fn lowerFormatMacro(e: *Ext, raw_tokens: []const u8) anyerror!exprs.NodeId {
    _ = raw_tokens;
    return unsupported(e, "macro format");
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

    // `matches!` is a distinct shape the classifier keeps as `.custom` — the
    // pattern it carries must reach the pattern lowering whole — so its
    // basename is recognized here, beside `debug_assert!`, without touching
    // the macro-kind enum. `format!` is a classified kind whose arm below used
    // to join the refusal below, for the same reason: its template-first
    // shape differs from `write!`'s writer-first one.
    if (std.mem.eql(u8, macro_base, "matches")) {
        return lowerMatchesMacro(e, raw_tokens);
    }
    if (kind == .format) {
        return lowerFormatMacro(e, raw_tokens);
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
                    // `vec![e; N]` evaluates its element before its count, so
                    // the element is lowered first and the count follows.
                    const lowered = try e.ctx.alloc.alloc(exprs.NodeId, 1);
                    errdefer e.ctx.alloc.free(lowered);
                    lowered[0] = try parseAndLowerSubExpr(e, repeat.element);
                    // A count the translator already holds stays a number, so
                    // every literal form lowers exactly as it did. Anything
                    // else is an ordinary Rust expression and goes through the
                    // SAME sub-expression parser the element used, in the same
                    // lexical context: `vec![0u8; n]` then carries `n` — with
                    // its own effects, type, and captures — where it used to be
                    // a refusal.
                    const count: exprs.VecRepeatCount = if (parseVecRepeatCount(repeat.count)) |literal|
                        .{ .literal = literal }
                    else
                        .{ .expression = try parseAndLowerSubExpr(e, repeat.count) };
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
        .println, .eprintln => {
            return unsupported(e, try std.fmt.allocPrint(e.ctx.alloc, "macro {s}", .{@tagName(kind)}));
        },
        // `format!` used to join the refusal arm above. It no longer does:
        // `lowerFormatMacro` is reached before this switch. This arm is the
        // backstop if that routing is ever bypassed, and it names the same
        // honest refusal rather than a new shape.
        .format => {
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
    // `fn f(_: T)` puts its wildcard in the same anonymous `pattern` field a
    // closure parameter uses, so the field is read before the named walk for
    // the same reason.
    if (node.childByFieldName("pattern")) |pattern| return pattern;
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
    // `fn f(_: T)` binds nothing, so there is no destructuring to run: the
    // typed binding IS the whole of it. Without this the wildcard reaches
    // `lowerPattern` and emits `let _ = <param>;`, a prologue that discards
    // the value the backend has just declared.
    if (std.mem.eql(u8, pattern.kind(), "_") or
        std.mem.eql(u8, pattern.kind(), "wildcard_pattern")) return;
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
        // A function body holds no item whose body is extracted on its own:
        // a `fn` written inside one is a block-local helper, lowered together
        // with the function that holds it. Stopping here keeps such a helper
        // from answering for the module-level item of the same name.
        return null;
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

test "a unicode escape contributes its UTF-8 encoding to a string" {
    const allocator = std.testing.allocator;

    // U+00E9 is one escape in the source and two bytes in the value.
    const bmp = try decodeEscapedBytes(allocator, "caf\\u{e9}", true);
    defer allocator.free(bmp);
    try std.testing.expectEqualStrings("caf\xC3\xA9", bmp);

    // U+1F600 is past the BMP and four bytes wide — the case a decoder that
    // spends one byte per escape, or one per code unit, gets wrong.
    const astral = try decodeEscapedBytes(allocator, "\\u{1F600}", true);
    defer allocator.free(astral);
    try std.testing.expectEqualStrings("\xF0\x9F\x98\x80", astral);

    // A unicode escape alongside the byte escapes the decoder already handled,
    // and several of each in one literal.
    const mixed = try decodeEscapedBytes(allocator, "a\\nb\\u{41}c\\u{7f}", true);
    defer allocator.free(mixed);
    try std.testing.expectEqualStrings("a\nb\x41c\x7f", mixed);
}

test "an underscore separator does not change the scalar a unicode escape names" {
    const cases = [_]struct { raw: []const u8, value: u32 }{
        .{ .raw = "'\\u{41}'", .value = 0x41 },
        .{ .raw = "'\\u{7_f}'", .value = 0x7f },
        .{ .raw = "'\\u{e9}'", .value = 0x00e9 },
        .{ .raw = "'\\u{4_e_9}'", .value = 0x04e9 },
        .{ .raw = "'\\u{1f642}'", .value = 0x1f642 },
        .{ .raw = "'\\u{1_f_642___}'", .value = 0x1f642 },
        .{ .raw = "'\\u{1__f642}'", .value = 0x1f642 },
        .{ .raw = "'\\u{1_f6__4_2}'", .value = 0x1f642 },
        .{ .raw = "'\\u{10ffff}'", .value = 0x10ffff },
        .{ .raw = "'\\u{10_ffff_}'", .value = 0x10ffff },
        .{ .raw = "'\\u{10ffff__}'", .value = 0x10ffff },
        .{ .raw = "'\\u{000041}'", .value = 0x41 },
        .{ .raw = "'\\u{0000_41}'", .value = 0x41 },
        .{ .raw = "'\\u{0000_00}'", .value = 0x00 },
        .{ .raw = "'\\u{a_}'", .value = 0x0a },
        .{ .raw = "'\\u{0_}'", .value = 0x00 },
    };
    for (cases) |entry| {
        const decoded = decodeRustCharCodepoint(entry.raw) orelse
            return error.UnderscoredUnicodeEscapeRefused;
        try std.testing.expectEqual(entry.value, decoded);
    }
}

test "a char literal and the string spelling of an underscored escape agree" {
    const allocator = std.testing.allocator;
    const bytes = try decodeEscapedBytes(allocator, "\\u{1_f_642___}\\u{10_ffff_}", true);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("\xF0\x9F\x99\x82\xF4\x8F\xBF\xBF", bytes);

    const scalar = decodeRustCharCodepoint("'\\u{1_f_642___}'") orelse
        return error.UnderscoredUnicodeEscapeRefused;
    try std.testing.expectEqual(@as(u32, 0x1f642), scalar);
    var encoded: [4]u8 = undefined;
    const encoded_len = try std.unicode.utf8Encode(@intCast(scalar), &encoded);
    try std.testing.expectEqualSlices(u8, encoded[0..encoded_len], bytes[0..4]);

    const mixed = try decodeEscapedBytes(allocator, "a\\nb\\u{4_1}c\\u{7_f}", true);
    defer allocator.free(mixed);
    try std.testing.expectEqualStrings("a\nb\x41c\x7f", mixed);
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

/// The number a `vec!` literal states outright, or null when the count is an
/// expression the target evaluates instead. A test that means to pin a folded
/// count says so here rather than reaching into the union at every site.
fn vecRepeatLiteralCount(count: exprs.VecRepeatCount) ?u64 {
    return switch (count) {
        .literal => |value| value,
        .expression => null,
    };
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
    try std.testing.expectEqual(
        @as(u64, 200_000),
        vecRepeatLiteralCount(repeated_vec.repeat orelse return error.ExpectedRepeatedVecCount),
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
        @as(u64, 1),
        vecRepeatLiteralCount(suffixed_decimal_vec.repeat orelse return error.ExpectedSuffixedDecimalVecCount),
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
        @as(u64, 255),
        vecRepeatLiteralCount(suffixed_hex_vec.repeat orelse return error.ExpectedSuffixedHexVecCount),
    );
}

/// The `vec!` literal a `let` binds, or an error naming the shape that broke.
fn letVecLiteral(
    stmts: []const exprs.Statement,
    expressions: []const exprs.Expr,
    block: exprs.BlockExpr,
    index: usize,
) !exprs.VecLit {
    if (index >= block.statements.len) return error.MissingVecLet;
    const statement = switch (stmts[block.statements[index]].kind) {
        .let => |declaration| declaration,
        else => return error.ExpectedVecLet,
    };
    const init = statement.init orelse return error.ExpectedVecInitializer;
    return switch (expressions[init].kind) {
        .vec_lit => |literal| literal,
        else => return error.ExpectedVecLit,
    };
}

// `vec![e; n]` counts in `usize` whatever `e` is, and `n` is an ordinary Rust
// expression: it is not part of any `Vec`'s type, so it has to be an IR node
// the backend evaluates rather than a number this layer invented. The count
// reaches the IR through the SAME sub-expression parser the element uses, so
// a path, a call, or an arithmetic expression all arrive as what the source
// wrote them as. A count that is a plain integer still folds, and both live in
// one function here so neither arm can quietly absorb the other.
test "a vec! repeat count that is not a constant lowers as an expression" {
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
        .name = try alloc.dupe(u8, "build_counts"),
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
        \\fn build_counts() {
        \\    let count = 3usize;
        \\    let byte = 0u8;
        \\    let dynamic = vec![byte; count];
        \\    let arithmetic = vec![byte; count - 1];
        \\    let folded = vec![byte; 4];
        \\    let suffixed = vec![byte; 0x_FF_usize];
        \\}
        ,
        .mod_id = root_id,
    };
    try std.testing.expect(try extractFunction(&ctx, fn_id));

    const body = switch (exprs_list.items[bodies_list.items[fn_id].fn_.body].kind) {
        .block => |block| block,
        else => return error.ExpectedFunctionBlock,
    };
    try std.testing.expectEqual(@as(usize, 6), body.statements.len);

    // A count that names something is an EXPRESSION the backend evaluates, so
    // the node has to exist and it has to be the path the source wrote. A
    // refusal here would have been an `.unsupported` node instead.
    const dynamic = try letVecLiteral(stmts_list.items, exprs_list.items, body, 2);
    try std.testing.expectEqual(@as(usize, 1), dynamic.elements.len);
    try std.testing.expect(dynamic.elements[0] < exprs_list.items.len);
    try std.testing.expect(exprs_list.items[dynamic.elements[0]].kind != .unsupported);
    const dynamic_count = switch (dynamic.repeat orelse return error.ExpectedDynamicVecCount) {
        .expression => |count| count,
        .literal => return error.DynamicCountWasFolded,
    };
    try std.testing.expect(dynamic_count < exprs_list.items.len);
    try std.testing.expect(exprs_list.items[dynamic_count].kind == .path);

    // `count - 1` folds to nothing this parser reads as one token, and it
    // arrives as the binary expression the source wrote rather than as
    // anything invented to stand in for it.
    const arithmetic = try letVecLiteral(stmts_list.items, exprs_list.items, body, 3);
    const arithmetic_count = switch (arithmetic.repeat orelse return error.ExpectedArithmeticVecCount) {
        .expression => |count| count,
        .literal => return error.ArithmeticCountWasFolded,
    };
    try std.testing.expect(arithmetic_count < exprs_list.items.len);
    const arithmetic_expr = switch (exprs_list.items[arithmetic_count].kind) {
        .binary => |binary| binary,
        else => return error.ArithmeticCountIsNotBinary,
    };
    try std.testing.expect(arithmetic_expr.op == exprs.BinaryOp.sub);

    // The forms that always folded still fold, in this same function, so the
    // expression arm above is not quietly absorbing them.
    const folded = try letVecLiteral(stmts_list.items, exprs_list.items, body, 4);
    try std.testing.expectEqual(
        @as(u64, 4),
        vecRepeatLiteralCount(folded.repeat orelse return error.ExpectedFoldedVecCount),
    );
    const suffixed = try letVecLiteral(stmts_list.items, exprs_list.items, body, 5);
    try std.testing.expectEqual(
        @as(u64, 255),
        vecRepeatLiteralCount(suffixed.repeat orelse return error.ExpectedSuffixedVecCount),
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

// `&[u8]` and `*const [u8]` are the same fat pointer under two names, so the
// cast is legal Rust. The destination has to stay fat: a target that carried
// only the element would drop the length and turn half the value into
// nothing.
test "a borrowed slice casts to a raw pointer to the same slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const byte_slice = try alloc.create(types.Slice);
    byte_slice.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const params = try alloc.dupe(items.Param, &.{
        .{ .name = "input", .ty = .{ .slice = byte_slice }, .span = span_of },
    });
    var fixture = try SourceTestFixture.init(
        alloc,
        "fat_pointer_cast",
        \\fn fat_pointer_cast(input: &[u8]) {
        \\    let fat = input as *const [u8];
        \\}
    ,
        params,
        .{ .prim = .unit },
    );
    defer fixture.deinit(alloc);
    try fixture.validate();

    const body_id = fixture.tables.bodies_list.items[fixture.function_id].fn_.body;
    const block = switch (fixture.tables.exprs_list.items[body_id].kind) {
        .block => |block| block,
        else => return error.ExpectedFunctionBlock,
    };
    const let_statement = switch (fixture.tables.stmts_list.items[block.statements[0]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedSliceCastLet,
    };
    const cast = switch (fixture.tables.exprs_list.items[let_statement.init.?].kind) {
        .cast => |cast| cast,
        else => return error.ExpectedSlicePointerCast,
    };
    const source_slice = switch (cast.source_type) {
        .slice => |slice| slice,
        else => return error.ExpectedSlicePointerSource,
    };
    try std.testing.expect(source_slice.const_);
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, source_slice.elem);
    const target_pointer = switch (fixture.tables.types_list.items[cast.target]) {
        .raw_ptr => |pointer| pointer,
        else => return error.ExpectedSlicePointerTarget,
    };
    try std.testing.expect(!target_pointer.mut);
    const target_slice = switch (target_pointer.pointee) {
        .slice => |slice| slice,
        else => return error.ExpectedThinSlicePointerTarget,
    };
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, target_slice.elem);
}

// A shared slice cannot become a mutable pointer, however wide the
// destination's pointee is.
test "a shared slice cast to a mutable pointer to slice is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const byte_slice = try alloc.create(types.Slice);
    byte_slice.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const params = try alloc.dupe(items.Param, &.{
        .{ .name = "input", .ty = .{ .slice = byte_slice }, .span = span_of },
    });
    var fixture = try SourceTestFixture.init(
        alloc,
        "reject_slice_mutability",
        \\fn reject_slice_mutability(input: &[u8]) {
        \\    let invalid = input as *mut [u8];
        \\}
    ,
        params,
        .{ .prim = .unit },
    );
    defer fixture.deinit(alloc);
    try std.testing.expectError(error.UnsupportedExpression, fixture.validate());
}

// A raw string is its own bytes and the hashes only decide where the body
// ends, so `r##"a"b#c"##` is `a"b#c`: the inner quote and hash are content,
// not an escape and not a terminator.
test "a hashed raw string keeps its own bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fixture = try SourceTestFixture.init(
        alloc,
        "raw_text",
        \\fn raw_text() {
        \\    let text = r##"a"b#c"##;
        \\}
    ,
        &.{},
        .{ .prim = .unit },
    );
    defer fixture.deinit(alloc);

    const body_id = fixture.tables.bodies_list.items[fixture.function_id].fn_.body;
    const block = switch (fixture.tables.exprs_list.items[body_id].kind) {
        .block => |block| block,
        else => return error.ExpectedFunctionBlock,
    };
    const let_statement = switch (fixture.tables.stmts_list.items[block.statements[0]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedRawStringLet,
    };
    const literal = switch (fixture.tables.exprs_list.items[let_statement.init.?].kind) {
        .literal => |literal| literal,
        else => return error.ExpectedRawStringLiteral,
    };
    try std.testing.expectEqualStrings("a\"b#c", literal.string.bytes);
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

/// The `.fn_` entities one function's body declared as block-local items.
/// Entity ids are dense and assigned in source order, so this order is the
/// order the `fn` items were written in.
fn blockLocalFnEntities(
    fixture: *const SourceTestFixture,
    out: *std.ArrayListUnmanaged(spine.EntityId),
) !void {
    for (fixture.graph_store.symbol_table.entities.items) |ent| {
        if (ent.kind != .fn_) continue;
        if (ent.parent != fixture.function_id) continue;
        try out.append(fixture.graph_store.symbol_table.allocator, ent.id);
    }
}

/// The lowered block of a function body, which is never the empty body id a
/// function entity carries before its body is walked.
fn fnBodyBlock(tables: *const LookupTestTables, fn_id: spine.EntityId) !exprs.BlockExpr {
    if (fn_id >= tables.bodies_list.items.len) return error.MissingBodyId;
    const body_id = tables.bodies_list.items[fn_id].fn_.body;
    if (body_id == 0 or body_id >= tables.exprs_list.items.len) return error.MissingFunctionBody;
    return switch (tables.exprs_list.items[body_id].kind) {
        .block => |block| block,
        else => error.ExpectedBlockBody,
    };
}

/// The callee of an expression that must be a call to a free function.
fn freeCallTarget(tables: *const LookupTestTables, expr_id: exprs.NodeId) !spine.EntityId {
    if (expr_id >= tables.exprs_list.items.len) return error.MissingExpressionNode;
    return switch (tables.exprs_list.items[expr_id].kind) {
        .call => |call| switch (call.call_kind) {
            .free => |def| def,
            else => error.ExpectedFreeCall,
        },
        else => error.ExpectedCall,
    };
}

/// The integer a block's tail expression must evaluate to.
fn blockTailInt(tables: *const LookupTestTables, block: exprs.BlockExpr) !i128 {
    const tail = block.tail orelse return error.ExpectedTailExpression;
    if (tail >= tables.exprs_list.items.len) return error.MissingExpressionNode;
    return switch (tables.exprs_list.items[tail].kind) {
        .literal => |literal| switch (literal) {
            .int => |int| int.value,
            else => error.ExpectedIntegerLiteral,
        },
        else => error.ExpectedLiteral,
    };
}

/// The expression a statement evaluates, or the initializer a `let` binds.
fn statementExpr(tables: *const LookupTestTables, stmt_id: exprs.NodeId) !exprs.NodeId {
    if (stmt_id >= tables.stmts_list.items.len) return error.MissingStatement;
    return switch (tables.stmts_list.items[stmt_id].kind) {
        .expr => |expr_id| expr_id,
        .let => |declaration| declaration.init orelse error.MissingInitializer,
        else => error.ExpectedExpressionStatement,
    };
}

/// Resolve a bare name the way a function body in `src` would, so a test can
/// ask what module-global lookup reaches.
fn moduleLookupFor(
    fixture: *SourceTestFixture,
    src: []const u8,
    name: []const u8,
) !?spine.EntityId {
    var ctx: Ctx = .{
        .alloc = fixture.graph_store.symbol_table.allocator,
        .g = &fixture.graph_store,
        .exprs = &fixture.tables.exprs_list,
        .stmts = &fixture.tables.stmts_list,
        .pats = &fixture.tables.pats_list,
        .types = &fixture.tables.types_list,
        .bodies_list = &fixture.tables.bodies_list,
        .src = src,
        .mod_id = fixture.graph_store.crates.items[0].root,
    };
    const ext: Ext = .{ .ctx = &ctx, .fn_id = fixture.function_id };
    return lookupModuleEntity(&ext, name);
}

/// The full generic metadata of a declared function body.
fn fnGenerics(tables: *const LookupTestTables, fn_id: spine.EntityId) !types.Generics {
    if (fn_id >= tables.bodies_list.items.len) return error.MissingBodyId;
    return switch (tables.bodies_list.items[fn_id]) {
        .fn_ => |body| body.generics orelse return error.MissingGenerics,
        else => error.ExpectedFunctionBody,
    };
}

/// The bound whose terminal segment is `terminal`, or null.
fn findBound(bounds: []const types.Bound, terminal: []const u8) ?types.Bound {
    for (bounds) |bound| {
        if (bound.path.segments.len == 0) continue;
        const last = bound.path.segments[bound.path.segments.len - 1];
        if (std.mem.eql(u8, last.name, terminal)) return bound;
    }
    return null;
}

test "a block-local fn is declared, callable, and out of module reach" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const src =
        \\fn outer() {
        \\    fn helper() -> u8 { 7 }
        \\    helper();
        \\}
    ;

    var fixture = try SourceTestFixture.init(alloc, "outer", src, &.{}, .{ .prim = .unit });
    defer fixture.deinit(alloc);

    var helpers: std.ArrayListUnmanaged(spine.EntityId) = .empty;
    defer helpers.deinit(alloc);
    try blockLocalFnEntities(&fixture, &helpers);
    try std.testing.expectEqual(@as(usize, 1), helpers.items.len);
    const helper = helpers.items[0];

    // The helper owns a body of its own rather than aliasing the enclosing one.
    try std.testing.expect((try fnBodyBlock(&fixture.tables, helper)).tail != null);

    // The bare call in the enclosing body resolves to that helper.
    const outer_body = try fnBodyBlock(&fixture.tables, fixture.function_id);
    const call_stmt = outer_body.statements[outer_body.statements.len - 1];
    try std.testing.expectEqual(
        helper,
        try freeCallTarget(&fixture.tables, try statementExpr(&fixture.tables, call_stmt)),
    );

    // Nothing outside the declaring block can name it: it is no module item.
    try std.testing.expectEqual(@as(?spine.EntityId, null), try moduleLookupFor(&fixture, src, "helper"));
    try fixture.validate();
}

test "a block-local fn carries the same bound metadata a module-level fn does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const src =
        \\fn outer() {
        \\    fn helper<R: ?Sized + Iterator>(value: R) -> R { value }
        \\    helper(1u8);
        \\}
    ;

    var fixture = try SourceTestFixture.init(alloc, "outer", src, &.{}, .{ .prim = .unit });
    defer fixture.deinit(alloc);

    var helpers: std.ArrayListUnmanaged(spine.EntityId) = .empty;
    defer helpers.deinit(alloc);
    try blockLocalFnEntities(&fixture, &helpers);
    try std.testing.expectEqual(@as(usize, 1), helpers.items.len);
    const helper = helpers.items[0];

    const generics = try fnGenerics(&fixture.tables, helper);
    try std.testing.expectEqual(@as(usize, 1), generics.params.len);
    try std.testing.expectEqual(@as(usize, 0), generics.where_clauses.len);
    const param = switch (generics.params[0]) {
        .type_ => |value| value,
        else => return error.ExpectedTypeParameter,
    };
    try std.testing.expectEqualStrings("R", param.name);

    // Both bounds are on record, each against its full `core::` path: the
    // relaxation `?Sized` and the capability `Iterator`.
    try std.testing.expectEqual(@as(usize, 2), param.bounds.len);
    const relaxed = findBound(param.bounds, "Sized") orelse return error.MissingSizedBound;
    const capability = findBound(param.bounds, "Iterator") orelse return error.MissingIteratorBound;
    try std.testing.expect(relaxed.optional);
    try std.testing.expect(!capability.optional);
    for ([_]types.Bound{ relaxed, capability }) |bound| {
        try std.testing.expectEqual(@as(usize, 3), bound.path.segments.len);
        try std.testing.expectEqualStrings("core", bound.path.segments[0].name);
        for (bound.path.segments) |segment| {
            // An external trait has no entity of its own; the path is what a
            // consumer matches, so no segment may claim one.
            try std.testing.expectEqual(@as(?spine.EntityId, null), segment.id);
        }
    }

    const outer_block = try fnBodyBlock(&fixture.tables, fixture.function_id);
    const call_stmt = outer_block.statements[outer_block.statements.len - 1];
    try std.testing.expectEqual(
        helper,
        try freeCallTarget(&fixture.tables, try statementExpr(&fixture.tables, call_stmt)),
    );
    try fixture.validate();
}

test "an impl Trait on a helper parameter and return keeps its bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const src =
        \\fn outer() {
        \\    fn helper(value: impl Iterator) -> impl Iterator { value }
        \\}
    ;

    var fixture = try SourceTestFixture.init(alloc, "outer", src, &.{}, .{ .prim = .unit });
    defer fixture.deinit(alloc);

    var helpers: std.ArrayListUnmanaged(spine.EntityId) = .empty;
    defer helpers.deinit(alloc);
    try blockLocalFnEntities(&fixture, &helpers);
    try std.testing.expectEqual(@as(usize, 1), helpers.items.len);
    const helper = helpers.items[0];

    const signature = switch (fixture.tables.bodies_list.items[helper]) {
        .fn_ => |body| body,
        else => return error.ExpectedFunctionBody,
    };
    try std.testing.expectEqual(@as(usize, 1), signature.params.len);

    // `impl Trait` is an opaque type whose declared bounds stay on the
    // signature, NOT an erased `dyn Trait`. The two wrappers hold the same
    // rows, so a test that only checked the bounds could not tell them apart —
    // and reading `impl Trait` as a leaf sent the mapper back through itself
    // until the stack ran out, which is why this fixture exists at all.
    for ([_]types.Type{ signature.params[0].ty, signature.ret }) |declared| {
        const bounds = switch (declared) {
            .@"opaque" => |opaque_type| opaque_type.bounds,
            else => return error.ExpectedOpaqueType,
        };
        try std.testing.expectEqual(@as(usize, 1), bounds.len);
        const segments = bounds[0].path.segments;
        try std.testing.expectEqual(@as(usize, 3), segments.len);
        try std.testing.expectEqualStrings("core", segments[0].name);
        try std.testing.expectEqualStrings("Iterator", segments[2].name);
    }

    // The body still reads the helper's own parameter.
    var param_def: ?spine.EntityId = null;
    for (fixture.graph_store.symbol_table.entities.items) |ent| {
        if (ent.kind != .field or ent.parent != helper) continue;
        param_def = ent.id;
    }
    const param = param_def orelse return error.MissingHelperParameter;
    const block = try fnBodyBlock(&fixture.tables, helper);
    const tail = block.tail orelse return error.ExpectedTailExpression;
    try std.testing.expectEqual(
        param,
        switch (fixture.tables.exprs_list.items[tail].kind) {
            .path => |path_expr| path_expr.def,
            else => return error.ExpectedPathExpression,
        },
    );
    try fixture.validate();
}

test "a block-local fn resolves a call written before its declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const src =
        \\fn outer() {
        \\    let first = helper();
        \\    fn helper() -> u8 { 3 }
        \\    helper();
        \\}
    ;

    var fixture = try SourceTestFixture.init(alloc, "outer", src, &.{}, .{ .prim = .unit });
    defer fixture.deinit(alloc);

    var helpers: std.ArrayListUnmanaged(spine.EntityId) = .empty;
    defer helpers.deinit(alloc);
    try blockLocalFnEntities(&fixture, &helpers);
    try std.testing.expectEqual(@as(usize, 1), helpers.items.len);
    const helper = helpers.items[0];

    const outer_body = try fnBodyBlock(&fixture.tables, fixture.function_id);
    // Statement order is `let`, then the item, then the trailing call.
    const pre_declaration = outer_body.statements[0];
    const post_declaration = outer_body.statements[outer_body.statements.len - 1];
    try std.testing.expectEqual(
        helper,
        try freeCallTarget(&fixture.tables, try statementExpr(&fixture.tables, pre_declaration)),
    );
    try std.testing.expectEqual(
        helper,
        try freeCallTarget(&fixture.tables, try statementExpr(&fixture.tables, post_declaration)),
    );
    try fixture.validate();
}

test "same-named helpers in sibling blocks each resolve to their own item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const src =
        \\fn outer() {
        \\    {
        \\        fn helper() -> u8 { 1 }
        \\        helper();
        \\    }
        \\    fn helper() -> u8 { 2 }
        \\    helper();
        \\}
    ;

    var fixture = try SourceTestFixture.init(alloc, "outer", src, &.{}, .{ .prim = .unit });
    defer fixture.deinit(alloc);

    var helpers: std.ArrayListUnmanaged(spine.EntityId) = .empty;
    defer helpers.deinit(alloc);
    try blockLocalFnEntities(&fixture, &helpers);
    try std.testing.expectEqual(@as(usize, 2), helpers.items.len);
    // The enclosing block pre-declares its own item before the walk descends
    // into the inner block, so the outer helper takes the lower id.
    const outer_helper = helpers.items[0];
    const inner_helper = helpers.items[1];
    try std.testing.expect(inner_helper != outer_helper);

    const outer_body = try fnBodyBlock(&fixture.tables, fixture.function_id);
    // The inner block is statement 0; the outer call is the last statement.
    const inner_block_stmt = outer_body.statements[0];
    const inner_block_id = try statementExpr(&fixture.tables, inner_block_stmt);
    const inner_body = switch (fixture.tables.exprs_list.items[inner_block_id].kind) {
        .block => |block| block,
        else => return error.ExpectedBlockBody,
    };
    const inner_call = inner_body.statements[inner_body.statements.len - 1];
    const outer_call = outer_body.statements[outer_body.statements.len - 1];
    try std.testing.expectEqual(
        inner_helper,
        try freeCallTarget(&fixture.tables, try statementExpr(&fixture.tables, inner_call)),
    );
    try std.testing.expectEqual(
        outer_helper,
        try freeCallTarget(&fixture.tables, try statementExpr(&fixture.tables, outer_call)),
    );

    // Sharing a source name does not make them interchangeable: the inner call
    // reaches the helper written inside the inner block.
    try std.testing.expectEqual(
        @as(i128, 1),
        try blockTailInt(&fixture.tables, try fnBodyBlock(&fixture.tables, inner_helper)),
    );
    try std.testing.expectEqual(
        @as(i128, 2),
        try blockTailInt(&fixture.tables, try fnBodyBlock(&fixture.tables, outer_helper)),
    );
    try fixture.validate();
}

test "a helper body sees the items declared beside it in the same block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const src =
        \\fn outer() {
        \\    fn helper() -> u8 { sibling() }
        \\    fn sibling() -> u8 { 9 }
        \\    helper();
        \\}
    ;

    var fixture = try SourceTestFixture.init(alloc, "outer", src, &.{}, .{ .prim = .unit });
    defer fixture.deinit(alloc);

    var helpers: std.ArrayListUnmanaged(spine.EntityId) = .empty;
    defer helpers.deinit(alloc);
    try blockLocalFnEntities(&fixture, &helpers);
    try std.testing.expectEqual(@as(usize, 2), helpers.items.len);
    const helper = helpers.items[0];
    const sibling = helpers.items[1];

    const helper_body = try fnBodyBlock(&fixture.tables, helper);
    try std.testing.expectEqual(
        sibling,
        try freeCallTarget(&fixture.tables, helper_body.tail.?),
    );
    try fixture.validate();
}

test "a generic block-local helper keeps its own type parameter and body scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const src =
        \\fn outer() {
        \\    fn identity<T>(value: T) -> T { value }
        \\    identity(1u8);
        \\}
    ;

    var fixture = try SourceTestFixture.init(alloc, "outer", src, &.{}, .{ .prim = .unit });
    defer fixture.deinit(alloc);

    var helpers: std.ArrayListUnmanaged(spine.EntityId) = .empty;
    defer helpers.deinit(alloc);
    try blockLocalFnEntities(&fixture, &helpers);
    try std.testing.expectEqual(@as(usize, 1), helpers.items.len);
    const helper = helpers.items[0];

    // `T` is the helper's OWN parameter, so its return type names it without a
    // resolved entity — no enclosing function contributes one.
    const helper_body = switch (fixture.tables.bodies_list.items[helper]) {
        .fn_ => |body| body,
        else => return error.ExpectedFunctionBody,
    };
    try std.testing.expectEqual(@as(usize, 1), helper_body.generic_params.len);
    try std.testing.expectEqualStrings("T", helper_body.generic_params[0]);
    const ret_path = switch (helper_body.ret) {
        .path => |path| path,
        else => return error.ExpectedTypeParameterReturn,
    };
    try std.testing.expectEqual(@as(usize, 1), ret_path.segments.len);
    try std.testing.expectEqualStrings("T", ret_path.segments[0].name);

    // The body reads the helper's own parameter, not a binding of the caller.
    var param_def: ?spine.EntityId = null;
    for (fixture.graph_store.symbol_table.entities.items) |ent| {
        if (ent.kind != .field or ent.parent != helper) continue;
        param_def = ent.id;
    }
    const param = param_def orelse return error.MissingHelperParameter;
    const block = try fnBodyBlock(&fixture.tables, helper);
    const tail = block.tail orelse return error.ExpectedTailExpression;
    try std.testing.expectEqual(
        param,
        switch (fixture.tables.exprs_list.items[tail].kind) {
            .path => |path_expr| path_expr.def,
            else => return error.ExpectedPathExpression,
        },
    );

    const outer_block = try fnBodyBlock(&fixture.tables, fixture.function_id);
    const call_stmt = outer_block.statements[outer_block.statements.len - 1];
    try std.testing.expectEqual(
        helper,
        try freeCallTarget(&fixture.tables, try statementExpr(&fixture.tables, call_stmt)),
    );
    try fixture.validate();
}

test "a variant of a standard-library enum keeps the enum that owns it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const src =
        \\fn outer() {
        \\    let kind = std::io::ErrorKind::UnexpectedEof;
        \\}
    ;

    var fixture = try SourceTestFixture.init(alloc, "outer", src, &.{}, .{ .prim = .unit });
    defer fixture.deinit(alloc);

    const outer_body = try fnBodyBlock(&fixture.tables, fixture.function_id);
    const let_stmt = outer_body.statements[0];
    const init = switch (fixture.tables.stmts_list.items[let_stmt].kind) {
        .let => |declaration| declaration.init orelse return error.MissingInitializer,
        else => return error.ExpectedLetStatement,
    };

    // The path names a variant OF AN ENUM, so the enum is what the node carries.
    // Lowering it to a bare name would lose which representation to pick.
    const variant = switch (fixture.tables.exprs_list.items[init].kind) {
        .enum_variant => |value| value,
        else => return error.ExpectedEnumVariant,
    };
    try std.testing.expectEqualStrings("UnexpectedEof", variant.variant);

    const enum_entity = fixture.graph_store.symbol_table.get(variant.def) orelse
        return error.MissingEntityId;
    try std.testing.expectEqual(spine.EntityKind.enum_, enum_entity.kind);
    try std.testing.expectEqualStrings("ErrorKind", enum_entity.name);

    // It hangs off the external module chain `std` -> `io`, built through the
    // same `ensureExternalModule` the prelude enums use.
    const io_module = enum_entity.parent orelse return error.MissingParentId;
    const io_entity = fixture.graph_store.symbol_table.get(io_module) orelse
        return error.MissingEntityId;
    try std.testing.expectEqual(spine.EntityKind.module, io_entity.kind);
    try std.testing.expectEqualStrings("io", io_entity.name);
    const std_module = io_entity.parent orelse return error.MissingParentId;
    const std_entity = fixture.graph_store.symbol_table.get(std_module) orelse
        return error.MissingEntityId;
    try std.testing.expectEqual(spine.EntityKind.module, std_entity.kind);
    try std.testing.expectEqualStrings("std", std_entity.name);

    // The enum keeps its declared shape, so the variant is not minted on the fly.
    const enum_body = switch (fixture.tables.bodies_list.items[variant.def]) {
        .enum_ => |value| value,
        else => return error.ExpectedEnumBody,
    };
    var found = false;
    for (enum_body.variants) |declared| {
        if (std.mem.eql(u8, declared.name, "UnexpectedEof")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
    try fixture.validate();
}

test "a known external associated function is admitted with its declared signature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const src =
        \\fn outer() {
        \\    let cursor = std::io::Cursor::new([0u8; 1]);
        \\}
    ;

    var fixture = try SourceTestFixture.init(alloc, "outer", src, &.{}, .{ .prim = .unit });
    defer fixture.deinit(alloc);

    const outer_body = try fnBodyBlock(&fixture.tables, fixture.function_id);
    const let_stmt = outer_body.statements[0];
    const init = switch (fixture.tables.stmts_list.items[let_stmt].kind) {
        .let => |declaration| declaration.init orelse return error.MissingInitializer,
        else => return error.ExpectedLetStatement,
    };
    const call = switch (fixture.tables.exprs_list.items[init].kind) {
        .call => |value| value,
        else => return error.ExpectedCall,
    };
    const fn_id = switch (call.call_kind) {
        .associated => |def| def,
        else => return error.ExpectedAssociatedCall,
    };
    try std.testing.expectEqual(@as(usize, 1), call.args.len);

    // The entity hangs off the external `std` -> `io` chain and carries the
    // associated function's own name, which together are the identity the
    // backend matches. Nothing here claims the crate declared this function.
    const fn_entity = fixture.graph_store.symbol_table.get(fn_id) orelse
        return error.MissingEntityId;
    try std.testing.expectEqual(spine.EntityKind.fn_, fn_entity.kind);
    try std.testing.expectEqualStrings("new", fn_entity.name);
    const io_id = fn_entity.parent orelse return error.MissingParentId;
    const io_entity = fixture.graph_store.symbol_table.get(io_id) orelse
        return error.MissingEntityId;
    try std.testing.expectEqualStrings("io", io_entity.name);
    const std_id = io_entity.parent orelse return error.MissingParentId;
    const std_entity = fixture.graph_store.symbol_table.get(std_id) orelse
        return error.MissingEntityId;
    try std.testing.expectEqualStrings("std", std_entity.name);

    // The signature is the one the standard library declares —
    // `pub const fn new(inner: T) -> Cursor<T>` — and it is the part a
    // fabricated one would have got wrong: the backend checks arity against
    // `params` and reads the declared return when inferring the call.
    const fn_body = switch (fixture.tables.bodies_list.items[fn_id]) {
        .fn_ => |value| value,
        else => return error.ExpectedFunctionBody,
    };
    try std.testing.expectEqual(@as(usize, 1), fn_body.params.len);
    try std.testing.expectEqualStrings("inner", fn_body.params[0].name);
    const inner_ty = switch (fn_body.params[0].ty) {
        .path => |value| value,
        else => return error.ExpectedTypeParameter,
    };
    try std.testing.expectEqual(@as(usize, 1), inner_ty.segments.len);
    try std.testing.expectEqualStrings("T", inner_ty.segments[0].name);
    try std.testing.expectEqual(@as(?spine.EntityId, null), inner_ty.segments[0].id);

    // The return is `Cursor<T>`, which is the external nominal with one
    // argument — the same shape `lowerType` already maps to the runtime
    // cursor, so nothing new is needed to read it.
    const ret = switch (fn_body.ret) {
        .external_nominal => |value| value,
        else => return error.ExpectedExternalNominal,
    };
    try std.testing.expectEqual(@as(usize, 3), ret.path.len);
    try std.testing.expectEqualStrings("std", ret.path[0]);
    try std.testing.expectEqualStrings("io", ret.path[1]);
    try std.testing.expectEqualStrings("Cursor", ret.path[2]);
    try std.testing.expectEqual(@as(usize, 1), ret.args.len);
    const ret_arg = switch (ret.args[0]) {
        .path => |value| value,
        else => return error.ExpectedTypeParameter,
    };
    try std.testing.expectEqualStrings("T", ret_arg.segments[0].name);

    // And `T` is the function's own type parameter, declared as such.
    try std.testing.expectEqual(@as(usize, 1), fn_body.generic_params.len);
    try std.testing.expectEqualStrings("T", fn_body.generic_params[0]);
    const generics = fn_body.generics orelse return error.MissingGenerics;
    try std.testing.expectEqual(@as(usize, 1), generics.params.len);

    try fixture.validate();
}

test "parentheses group a type while a trailing comma makes a one-element tuple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const src =
        \\fn declares(pair: (u8,), grouped: (u8), erased: &(dyn std::error::Error + 'static)) {}
    ;

    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();
    const root_id = try addLookupTestEntity(alloc, &g, .module, "", null, null);
    const fn_id = try addLookupTestEntity(alloc, &g, .fn_, "declares", root_id, null);
    try addLookupTestModule(alloc, &g, "", null, true, &.{fn_id});
    try g.addCrate(.{
        .name = try alloc.dupe(u8, "paren-test"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

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
        .src = src,
        .mod_id = root_id,
    };
    var ext: Ext = .{ .ctx = &ctx, .fn_id = fn_id };
    defer ext.deinit();

    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(rust.language());
    const tree = parser.parseString(src, null) orelse return error.ParseFailed;
    defer tree.destroy();
    const fn_node = tree.rootNode().namedChild(0) orelse return error.MissingFunction;
    var params_node: ?ts.Node = null;
    var child_index: u32 = 0;
    while (fn_node.namedChild(child_index)) |child| : (child_index += 1) {
        if (std.mem.eql(u8, child.kind(), "parameters")) params_node = child;
    }
    const pn = params_node orelse return error.MissingParameters;

    var mapped: [3]types.Type = undefined;
    var count: usize = 0;
    var i: u32 = 0;
    while (pn.namedChild(i)) |parameter| : (i += 1) {
        if (count == mapped.len) return error.UnexpectedParameter;
        var type_node: ?ts.Node = null;
        var k: u32 = 0;
        while (parameter.namedChild(k)) |child| : (k += 1) {
            if (isParameterTypeNodeKind(child.kind())) {
                type_node = child;
                break;
            }
        }
        mapped[count] = try mapCstType(&ext, type_node orelse return error.MissingParameterType);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);

    // The comma is what makes a tuple: `(u8,)` keeps it, `(u8)` only groups.
    const pair = switch (mapped[0]) {
        .tuple => |members| members,
        else => return error.ExpectedTupleType,
    };
    try std.testing.expectEqual(@as(usize, 1), pair.len);
    try std.testing.expectEqual(types.Prim.u8, pair[0].prim);
    try std.testing.expectEqual(types.Prim.u8, mapped[1].prim);

    // A borrow of a parenthesized trait object is a borrow of the trait
    // object, not of a one-element tuple wrapping it.
    const erased = switch (mapped[2]) {
        .reference => |reference| reference.pointee,
        else => return error.ExpectedReferenceType,
    };
    const bounds = switch (erased) {
        .dyn_trait => |declared| declared,
        else => return error.ExpectedDynTraitType,
    };
    try std.testing.expectEqual(@as(usize, 1), bounds.len);
    try std.testing.expectEqual(@as(usize, 3), bounds[0].path.segments.len);
    try std.testing.expectEqualStrings("std", bounds[0].path.segments[0].name);
    try std.testing.expectEqualStrings("Error", bounds[0].path.segments[2].name);
}

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
    // CrateGraph owns both the path array and each segment.
    const owned_path = try alloc.alloc([]const u8, path.len);
    var copied: usize = 0;
    errdefer {
        for (owned_path[0..copied]) |segment| alloc.free(segment);
        alloc.free(owned_path);
    }
    for (path) |segment| {
        owned_path[copied] = try alloc.dupe(u8, segment);
        copied += 1;
    }
    const owned_name = try alloc.dupe(u8, local_name);
    errdefer alloc.free(owned_name);
    try g.addUse(.{
        .id = use_id,
        .kind = .{ .external = .{ .path = owned_path } },
        .local_name = owned_name,
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

test "a source label names its loop and its exits and never becomes an operand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    const root_id = try addLookupTestEntity(alloc, &g, .module, "", null, null);
    const fn_id = try addLookupTestEntity(alloc, &g, .fn_, "labelled", root_id, null);
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
        \\fn labelled() -> u32 {
        \\    'outer: loop {
        \\        loop {
        \\            continue 'outer;
        \\            break 'outer 7;
        \\        }
        \\        break;
        \\    }
        \\}
        ,
        .mod_id = root_id,
    };
    try std.testing.expect(try extractFunction(&ctx, fn_id));

    var labelled_loops: usize = 0;
    var plain_loops: usize = 0;
    var labelled_continues: usize = 0;
    var labelled_breaks: usize = 0;
    var bare_breaks: usize = 0;
    for (tables.exprs_list.items) |expression| {
        switch (expression.kind) {
            .loop_ => |loop_expr| {
                if (loop_expr.body.labelled) |label| {
                    try std.testing.expectEqualStrings("outer", label);
                    labelled_loops += 1;
                } else {
                    plain_loops += 1;
                }
            },
            .continue_ => |cont| {
                const label = cont.label orelse return error.UnlabelledContinue;
                try std.testing.expectEqualStrings("outer", label);
                labelled_continues += 1;
            },
            .break_ => |brk| {
                if (brk.label) |label| {
                    try std.testing.expectEqualStrings("outer", label);
                    // `break 'outer 7` hands the loop its value. A label on
                    // its own never invents one, so the bare `break` below
                    // stays valueless.
                    if (brk.value == null) return error.LabelledBreakLostValue;
                    labelled_breaks += 1;
                } else {
                    if (brk.value != null) return error.BareBreakGainedValue;
                    bare_breaks += 1;
                }
            },
            .unsupported => |marker| {
                std.debug.print("unlowered node: {s}\n", .{marker.reason});
                return error.LabelLoweredAsOperand;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), labelled_loops);
    try std.testing.expectEqual(@as(usize, 1), plain_loops);
    try std.testing.expectEqual(@as(usize, 1), labelled_continues);
    try std.testing.expectEqual(@as(usize, 1), labelled_breaks);
    try std.testing.expectEqual(@as(usize, 1), bare_breaks);
}
