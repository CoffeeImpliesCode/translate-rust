//! names — source-driven name resolution (P1 of the source model).
//!
//! Operates purely on the in-memory `CrateGraph`; it is C-free and
//! tree-sitter-free (no `@import("tree_sitter")`). After the cst extractor has
//! populated the symbol table, modules, and `uses`, this pass walks every
//! `UseDecl`, parses the full source-path text stored on the `use_` entity,
//! and resolves it against per-module scopes — honoring `crate`/`self`/`super`
//! bases, `as` aliases, and trailing `::*` globs.
//!
//! Resolution rules (edition 2018+ path semantics):
//!   - `crate::`  -> root module scope
//!   - `self::`   -> the use's own module
//!   - `super::`  -> the parent of the use's own module
//!   - bare / leading `::` -> the use's own module, falling back to the crate
//!     root for the first segment when it is not found locally
//! Any unresolved or ambiguous path degrades to `target = 0` with
//! `.kind = .{ .plain = 0 }` rather than aborting the pass.

const std = @import("std");
const spine = @import("spine.zig");
const graph = @import("graph.zig");

pub const span_of: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

/// A per-module scope: bare-name -> EntityId within ONE module. Shadowing is
/// modeled by the entries map (a later binding overwrites an earlier one);
/// name lookup never bleeds across modules except through explicit descent.
pub const Scope = struct {
    mod_id: spine.EntityId, // the module entity's EntityId
    entries: std.StringHashMapUnmanaged(spine.EntityId) = .empty,

    pub fn init(mod_id: spine.EntityId) Scope {
        return .{ .mod_id = mod_id, .entries = .empty };
    }

    pub fn deinit(self: *Scope, alloc: std.mem.Allocator) void {
        self.entries.deinit(alloc);
        self.* = undefined;
    }

    /// Resolve a bare name within this module ONLY.
    pub fn lookup(self: *const Scope, name: []const u8) ?spine.EntityId {
        return self.entries.get(name);
    }
};

const BaseKind = enum { crate_, self_, super_, bare };

/// A parsed `use` path. `segments` and `alias` are sub-slices of the source
/// name (not separately allocated); the caller owns `segments`' backing
/// buffer and must free it.
const ParsedUse = struct {
    base: BaseKind,
    segments: std.ArrayListUnmanaged([]const u8) = .empty,
    alias: ?[]const u8 = null,
    glob: bool = false,
};

fn parseUsePath(alloc: std.mem.Allocator, src: []const u8) ParsedUse {
    var out: ParsedUse = .{ .base = .bare };
    var path = src;

    // Trailing glob: `path::*`
    if (std.mem.endsWith(u8, path, "*")) {
        out.glob = true;
        var end: usize = path.len - 1;
        while (end > 0 and (path[end - 1] == ' ' or path[end - 1] == '\t')) end -= 1;
        if (end >= 2 and path[end - 1] == ':' and path[end - 2] == ':') end -= 2;
        path = path[0..end];
    }

    // Alias: `path as Alias`
    if (std.mem.indexOf(u8, path, " as ")) |ai| {
        const alias = std.mem.trim(u8, path[ai + 4 ..], " \t\r\n");
        if (alias.len > 0) out.alias = alias;
        path = std.mem.trim(u8, path[0..ai], " \t\r\n");
    }

    // Explicit base prefix.
    var rest = path;
    if (std.mem.startsWith(u8, path, "crate::")) {
        out.base = .crate_;
        rest = path["crate::".len..];
    } else if (std.mem.startsWith(u8, path, "self::")) {
        out.base = .self_;
        rest = path["self::".len..];
    } else if (std.mem.startsWith(u8, path, "super::")) {
        out.base = .super_;
        rest = path["super::".len..];
    } else if (std.mem.startsWith(u8, path, "::")) {
        // Absolute `::foo` — treated as bare (resolve from the current scope).
        rest = path[2..];
        out.base = .bare;
    }

    // Split the remainder into path segments.
    var it = std.mem.splitSequence(u8, rest, "::");
    while (it.next()) |seg| {
        const trimmed = std.mem.trim(u8, seg, " \t\r\n");
        if (trimmed.len == 0) continue;
        out.segments.append(alloc, trimmed) catch break;
    }
    return out;
}

/// Locate the `graph.Module` row that corresponds to a module *entity*. The
/// symbol table and the modules table use separate dense ids, so we bridge
/// them: a module entity (id, name, parent) matches the Module whose
/// `parent`/`name` agree (both parent fields reference the parent's entity id).
fn moduleForEntity(g: *const graph.CrateGraph, e: *const spine.Entity) ?*const graph.Module {
    for (g.modules.items) |*m| {
        if (m.parent == e.parent and std.mem.eql(u8, m.name, e.name)) return m;
    }
    return null;
}

/// The crate-root module's symbol-table EntityId.
fn findRootEntity(g: *const graph.CrateGraph) ?spine.EntityId {
    for (g.symbol_table.entities.items, 0..) |*e, i| {
        if (e.kind != .module) continue;
        if (moduleForEntity(g, e)) |m| {
            if (m.is_crate) return @intCast(i);
        }
    }
    // Fallback: the first module entity in the table.
    for (g.symbol_table.entities.items, 0..) |*e, i| {
        if (e.kind == .module) return @intCast(i);
    }
    return null;
}

/// Read-only access to the scope keyed by a module *entity id*.
fn scopeAt(scopes: []const ?Scope, entity_id: spine.EntityId) ?Scope {
    if (entity_id >= scopes.len) return null;
    return scopes[entity_id];
}

/// Walk `segs` from the scope of module entity `start`. `bare_fallback` lets
/// the first segment resolve from the crate root when absent locally (bare
/// paths). `need_module` requires every intermediate AND the final segment to
/// be a module (used by globs, whose target is the named module itself).
/// Returns the resolved EntityId, or null on any failure.
fn resolvePath(
    scopes: []const ?Scope,
    g: *const graph.CrateGraph,
    root_id: spine.EntityId,
    start: spine.EntityId,
    segs: []const []const u8,
    bare_fallback: bool,
    need_module: bool,
) ?spine.EntityId {
    if (segs.len == 0) return null;
    var cur = start;
    for (segs, 0..) |seg, i| {
        const sc = scopeAt(scopes, cur) orelse return null;
        var found = sc.lookup(seg);
        if (found == null and i == 0 and bare_fallback) {
            const rsc = scopeAt(scopes, root_id) orelse return null;
            found = rsc.lookup(seg);
            if (found != null) cur = root_id;
        }
        const f = found orelse return null;
        const e = g.symbol_table.get(f) orelse return null;
        if (need_module and e.kind != .module) return null;
        if (i == segs.len - 1) return f;
        if (e.kind != .module) return null;
        cur = f;
    }
    return null;
}

/// Replace a UseDecl's local name, keeping it allocator-owned (graph-owned).
fn setLocalName(alloc: std.mem.Allocator, u: *graph.UseDecl, new: []const u8) void {
    alloc.free(u.local_name);
    u.local_name = alloc.dupe(u8, new) catch "";
}

/// Resolve every `use` declaration in the graph against per-module scopes.
/// Fills each `UseDecl.kind`/`.target` and sets the matching `use_` entity's
/// `.resolved` field. Unresolvable paths degrade to `target = 0` (leaving
/// `.resolved` untouched) rather than erroring the pass.
pub fn resolveGraph(alloc: std.mem.Allocator, g: *graph.CrateGraph) !void {
    const root_id = findRootEntity(g) orelse 0;

    // Map each use entity id -> its binding name (for scope indexing).
    var use_local: std.AutoHashMapUnmanaged(spine.EntityId, []const u8) = .empty;
    defer use_local.deinit(alloc);
    for (g.uses.items) |u| {
        try use_local.put(alloc, u.id, u.local_name);
    }

    // Build one scope per module entity, keyed by its symbol-table id.
    // Resolving the bridge (module entity <-> Module row) needs mutable access
    // to the symbol table, but only reads entity fields.
    const entity_count = g.symbol_table.entities.items.len;
    var scopes: std.ArrayListUnmanaged(?Scope) = .empty;
    defer {
        for (scopes.items) |*s| if (s.*) |*sc| sc.deinit(alloc);
        scopes.deinit(alloc);
    }
    try scopes.appendNTimes(alloc, null, entity_count);
    for (g.symbol_table.entities.items, 0..) |*e, i| {
        if (e.kind != .module) continue;
        const m = moduleForEntity(g, e) orelse continue;
        var scope = Scope.init(@intCast(i));
        for (m.items) |item_id| {
            const ent = g.symbol_table.get(item_id) orelse continue;
            if (ent.name.len == 0) continue;
            scope.entries.put(alloc, ent.name, item_id) catch {
                scope.entries.deinit(alloc);
                scope = Scope.init(@intCast(i));
                continue;
            };
            // A `use` also introduces a binding under its local name.
            if (ent.kind == .use_) {
                if (use_local.get(item_id)) |ln| {
                    if (ln.len > 0) scope.entries.put(alloc, ln, item_id) catch continue;
                }
            }
        }
        scopes.items[i] = scope;
    }

    const scope_slice: []const ?Scope = scopes.items;

    // Resolve each use declaration.
    for (g.uses.items) |*u| {
        const ent = g.symbol_table.get(u.id) orelse continue;
        var parsed = parseUsePath(alloc, ent.name);
        defer parsed.segments.deinit(alloc);

        var start: ?spine.EntityId = null;
        switch (parsed.base) {
            .crate_ => start = root_id,
            .self_, .bare => start = ent.parent,
            .super_ => {
                if (ent.parent) |p| {
                    if (g.symbol_table.get(p)) |own_ent| {
                        if (own_ent.kind == .module) {
                            if (moduleForEntity(g, &own_ent)) |own_mod| {
                                start = own_mod.parent;
                            }
                        }
                    }
                }
            },
        }
        const start_id = start orelse root_id;
        const bare_fallback = parsed.base == .bare;
        const target = resolvePath(
            scope_slice,
            g,
            root_id,
            start_id,
            parsed.segments.items,
            bare_fallback,
            parsed.glob,
        );

        if (target) |t| {
            u.target = t;
            if (parsed.glob) {
                // The target is the module EntityId that the glob enumerates.
                u.kind = .glob;
                setLocalName(alloc, u, "");
            } else if (parsed.alias) |alias| {
                u.kind = .{ .alias = t };
                setLocalName(alloc, u, alias);
            } else if (parsed.segments.items.len > 0) {
                u.kind = .{ .plain = t };
                setLocalName(alloc, u, parsed.segments.items[parsed.segments.items.len - 1]);
            } else {
                u.target = 0;
                u.kind = .{ .plain = 0 };
            }
            if (u.id < g.symbol_table.entities.items.len)
                g.symbol_table.entities.items[u.id].resolved = t;
        } else {
            // Unresolved: degrade to target 0, leave `.resolved` untouched.
            u.target = 0;
            u.kind = .{ .plain = 0 };
        }
    }
}
