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
//! Any unresolved non-external path degrades to `target = 0` with
//! `.kind = .{ .plain = 0 }`; an unresolved non-glob use rooted at `core`,
//! `std`, `alloc` or a manifest dependency uses `.kind = .external` and
//! retains its full path.

const std = @import("std");
const ir = @import("translate_rust.ir");
const spine = ir.spine;
const graph = ir.graph;

pub const span_of: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

/// A per-module scope: bare-name -> EntityId within ONE module. Shadowing is
/// modeled by the entries map (a later binding overwrites an earlier one);
/// name lookup never bleeds across modules except through explicit descent.
///
/// `locals` holds the same names restricted to items that are NOT `use`
/// declarations, so the binding a `use` displaced stays reachable. A `use`
/// that binds a name its own module already declares must SHADOW that
/// declaration for every reader of the module — that is what `entries` says —
/// but a use declaration is never its own target, and the thing such a path
/// names is precisely the declaration the `use` sat on top of. One map cannot
/// answer both questions, so the two live side by side.
pub const Scope = struct {
    mod_id: spine.EntityId, // the module entity's EntityId
    entries: std.StringHashMapUnmanaged(spine.EntityId) = .empty,
    locals: std.StringHashMapUnmanaged(spine.EntityId) = .empty,

    pub fn init(mod_id: spine.EntityId) Scope {
        return .{ .mod_id = mod_id, .entries = .empty, .locals = .empty };
    }

    pub fn deinit(self: *Scope, alloc: std.mem.Allocator) void {
        self.entries.deinit(alloc);
        self.locals.deinit(alloc);
        self.* = undefined;
    }

    /// Resolve a bare name within this module ONLY.
    pub fn lookup(self: *const Scope, name: []const u8) ?spine.EntityId {
        return self.entries.get(name);
    }

    /// The declaration `name` names in this module, ignoring any `use` that
    /// bound the same name. Null when the module holds no such declaration.
    pub fn lookupLocal(self: *const Scope, name: []const u8) ?spine.EntityId {
        return self.locals.get(name);
    }
};

const BaseKind = enum { crate_, self_, super_, bare };

/// A parsed `use` path. `segments` and `alias` are sub-slices of the source
/// name (not separately allocated); the caller owns `segments`' backing
/// buffer and must free it.
const ParsedUse = struct {
    base: BaseKind,
    super_depth: usize = 0,
    segments: std.ArrayListUnmanaged([]const u8) = .empty,
    alias: ?[]const u8 = null,
    glob: bool = false,
};

fn parseUsePath(alloc: std.mem.Allocator, src: []const u8) ParsedUse {
    var out: ParsedUse = .{ .base = .bare };
    var path = src;

    // Alias: `path as Alias`
    if (std.mem.indexOf(u8, path, " as ")) |ai| {
        const alias = std.mem.trim(u8, path[ai + 4 ..], " \t\r\n");
        if (alias.len > 0) out.alias = alias;
        path = std.mem.trim(u8, path[0..ai], " \t\r\n");
    }

    // Explicit base prefix. Count every `super::` so nested parent traversal
    // follows the lexical module tree one edge at a time.
    var rest = path;
    if (std.mem.startsWith(u8, path, "crate::")) {
        out.base = .crate_;
        rest = path["crate::".len..];
    } else if (std.mem.startsWith(u8, path, "self::")) {
        out.base = .self_;
        rest = path["self::".len..];
    } else {
        while (std.mem.startsWith(u8, rest, "super::")) {
            out.base = .super_;
            out.super_depth += 1;
            rest = rest["super::".len..];
        }
    }
    if (out.super_depth == 0 and std.mem.startsWith(u8, path, "::")) {
        // Absolute `::foo` — treated as bare (resolve from the current scope).
        rest = path[2..];
        out.base = .bare;
    }

    // Strip the trailing glob only after recognizing its explicit base.
    if (std.mem.endsWith(u8, rest, "*")) {
        out.glob = true;
        var end: usize = rest.len - 1;
        while (end > 0 and (rest[end - 1] == ' ' or rest[end - 1] == '\t')) end -= 1;
        if (end >= 2 and rest[end - 1] == ':' and rest[end - 2] == ':') end -= 2;
        rest = rest[0..end];
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

/// Discard a binding that names the `use` being resolved, and hand back what
/// the name stood for before that `use` shadowed it.
///
/// A `use` registers itself in its own module under BOTH its source path and
/// the name it binds, so a single-segment `use helper;` is reachable as
/// "helper" through the very entry being resolved. Taking that would make the
/// declaration its own target: `u.target` and `entity.resolved` would both
/// name the `use_` itself, and every later hop that follows a binding would
/// walk into itself and find nothing. A use declaration is never its own
/// target.
///
/// What a self-hit hides is not always nothing. A `use` that binds a name its
/// own module already declares — a re-export written as `use self::T;`, or a
/// path that leads back into the module holding it — SHADOWED a real
/// declaration to get there, and that declaration is what the path names.
/// Discarding the self-hit and returning null there is what turned such a use
/// into a dangling alias, so the shadowed declaration is consulted instead;
/// only a name nothing else declared still falls through to the bare fallback
/// inside `resolvePath`.
fn skipSelf(
    found: ?spine.EntityId,
    sc: *const Scope,
    self_id: spine.EntityId,
    seg: []const u8,
) ?spine.EntityId {
    const binding = found orelse return null;
    if (binding != self_id) return binding;
    return sc.lookupLocal(seg);
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
    self_id: spine.EntityId,
    segs: []const []const u8,
    bare_fallback: bool,
    need_module: bool,
) ?spine.EntityId {
    if (segs.len == 0) return if (need_module) start else null;
    var cur = start;
    for (segs, 0..) |seg, i| {
        const sc = scopeAt(scopes, cur) orelse return null;
        var found = skipSelf(sc.lookup(seg), &sc, self_id, seg);
        if (found == null and i == 0 and bare_fallback) {
            const rsc = scopeAt(scopes, root_id) orelse return null;
            found = skipSelf(rsc.lookup(seg), &rsc, self_id, seg);
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

fn clearExternalKind(alloc: std.mem.Allocator, u: *graph.UseDecl) void {
    switch (u.kind) {
        .external => |external| {
            for (external.path) |segment| alloc.free(segment);
            if (external.path.len > 0) alloc.free(external.path);
        },
        else => {},
    }
    u.kind = .{ .plain = 0 };
}

/// A crate name the manifest spells with dashes is spelled with underscores
/// at the use site, so the two forms have to compare equal here exactly as
/// they do in the declaration binder.
fn normalizedNameEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_char, right_char| {
        const normalized_left = if (left_char == '-') '_' else left_char;
        const normalized_right = if (right_char == '-') '_' else right_char;
        if (normalized_left != normalized_right) return false;
    }
    return true;
}

/// Whether `name` roots a path whose types never exist as graph entities: the
/// three standard crates, or a dependency this crate's manifest declares.
///
/// This has to answer exactly as `cst.zig`'s `isKnownExternalCrate` does. The
/// CST pass seeds every such `use` with an external candidate so declaration
/// types can bind while the walk is still running; this pass is what keeps
/// that candidate. A narrower rule here silently drops a dependency-rooted
/// `use` back to a plain binding that resolves to nothing, and every later
/// path through that alias stops naming a type at all.
fn isExternalRootName(g: *const graph.CrateGraph, name: []const u8) bool {
    if (std.mem.eql(u8, name, "core") or
        std.mem.eql(u8, name, "std") or
        std.mem.eql(u8, name, "alloc"))
    {
        return true;
    }
    for (g.crates.items) |crate_info| {
        for (crate_info.deps) |dependency| {
            if (normalizedNameEqual(dependency.local_alias, name) or
                normalizedNameEqual(dependency.extern_name, name))
            {
                return true;
            }
        }
    }
    return false;
}

fn isExternalRootedUse(g: *const graph.CrateGraph, parsed: ParsedUse) bool {
    if (parsed.base != .bare or parsed.glob or parsed.segments.items.len == 0) return false;
    return isExternalRootName(g, parsed.segments.items[0]);
}

fn duplicateExternalPath(
    alloc: std.mem.Allocator,
    segments: []const []const u8,
) ![]const []const u8 {
    var path = try alloc.alloc([]const u8, segments.len);
    var copied: usize = 0;
    errdefer {
        for (path[0..copied]) |segment| alloc.free(segment);
        alloc.free(path);
    }
    for (segments, 0..) |segment, index| {
        path[index] = try alloc.dupe(u8, segment);
        copied += 1;
    }
    return path;
}

/// Resolve every `use` declaration in the graph against per-module scopes.
/// Fills each `UseDecl.kind`/`.target` and sets the matching `use_` entity's
/// `.resolved` field. An unresolved non-glob path rooted at `core`, `std`, or
/// `alloc` becomes `.external` with an owned path; every other unresolved path
/// stays plain.
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
                scope.deinit(alloc);
                scope = Scope.init(@intCast(i));
                continue;
            };
            // A `use` also introduces a binding under its local name, and it
            // shadows whatever the module already declared under it. A
            // declaration is the one binding no `use` may displace, so it is
            // indexed beside the shadowed name: `skipSelf` reads it back when
            // the path being resolved is the `use` that did the shadowing.
            if (ent.kind == .use_) {
                if (use_local.get(item_id)) |ln| {
                    if (ln.len > 0) scope.entries.put(alloc, ln, item_id) catch continue;
                }
            } else {
                scope.locals.put(alloc, ent.name, item_id) catch continue;
            }
        }
        scopes.items[i] = scope;
    }

    const scope_slice: []const ?Scope = scopes.items;

    // Resolve each use declaration.
    for (g.uses.items) |*u| {
        const ent = g.symbol_table.get(u.id) orelse continue;
        if (u.id < g.symbol_table.entities.items.len) {
            g.symbol_table.entities.items[u.id].resolved = null;
        }
        var parsed = parseUsePath(alloc, ent.name);
        defer parsed.segments.deinit(alloc);

        var start: ?spine.EntityId = null;
        switch (parsed.base) {
            .crate_ => start = root_id,
            .self_, .bare => start = ent.parent,
            .super_ => {
                var cursor = ent.parent;
                var depth: usize = 0;
                while (depth < parsed.super_depth) : (depth += 1) {
                    const module_id = cursor orelse break;
                    const module_ent = g.symbol_table.get(module_id) orelse break;
                    if (module_ent.kind != .module) break;
                    cursor = module_ent.parent;
                }
                if (depth == parsed.super_depth) start = cursor;
            },
        }
        const start_id = start orelse root_id;
        const bare_fallback = parsed.base == .bare;
        const target = resolvePath(
            scope_slice,
            g,
            root_id,
            start_id,
            u.id,
            parsed.segments.items,
            bare_fallback,
            parsed.glob,
        );

        if (target) |t| {
            clearExternalKind(alloc, u);
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
            clearExternalKind(alloc, u);
            u.target = 0;
            if (isExternalRootedUse(g, parsed)) {
                const external_path = try duplicateExternalPath(alloc, parsed.segments.items);
                u.kind = .{ .external = .{
                    .path = external_path,
                } };
            }
        }
    }
}
