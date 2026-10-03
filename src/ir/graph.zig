//! translate_rust.model.graph — the crate & module graph (data-model.md §3.1,
//! data-model/crate-graph.md §1-3).
//!
//! A `CrateGraph` owns a single dense `SymbolTable` (EntityId -> Entity) shared
//! by every crate, plus a dense `modules` table (EntityId == index, mirroring
//! the SymbolTable), a `uses` table (the accumulating `use`/`pub use` decls,
//! again keyed by EntityId), and a flat list of `Crate`s. Loading/saving goes
//! through `json.zig`, which is the lossless JSON boundary.
//!
//! Ownership: a graph parsed by `json.parse` owns every referenced string and
//! slice (allocated from the graph allocator); `deinit` frees them all.

const std = @import("std");
const spine = @import("spine.zig");

/// How a Rust module arose (data-model/crate-graph.md §1.2).
pub const ModuleKind = enum { root, @"inline", file, directory };

/// A node in the module tree. Its `id` is an EntityId into the SymbolTable;
/// the crate root is reachable from `Crate.root`. `items` is a flat list of
/// child entity IDs (modules, structs, fns, uses, ...); `parent` is the
/// inverse edge so `super::` paths can climb.
///
/// `items` and `parent` are two records of ONE fact, and `validateTopology`
/// holds them to it in both directions: an entity whose `parent` is a module is
/// in that module's `items`, and an entity in a module's `items` has that
/// module as its `parent`. There is therefore no second way to be listed. A
/// METHOD — the `fn_` of an `impl`, a trait, or an inherent block — belongs to
/// that enclosing declaration and not to the module around it, so its parent
/// names the impl or trait and no module's `items` mentions it: it is listed by
/// the impl's own `assoc_items`, and a graph that also listed it under the
/// module would give one declaration two parents, which the second direction
/// refuses. A free function has no such owner and is a module item, so the
/// parent it does have is the module that declares it.
pub const Module = struct {
    id: spine.EntityId,
    kind: ModuleKind,
    name: []const u8, // "" for root; "foo" for `mod foo`
    parent: ?spine.EntityId, // null only for crate / extern roots
    source_path: ?[]const u8, // file holding this module's items
    is_crate: bool,
    is_extern: bool,
    span: spine.Span,
    items: []const spine.EntityId,
    attributes: []const spine.Attribute,
};

pub const CrateKind = enum { lib, bin };

/// An external crate dependency and its Cargo source metadata.
pub const CrateDep = struct {
    extern_name: []const u8,
    local_alias: []const u8,
    id: u32,
    version: ?[]const u8 = null,
    path: ?[]const u8 = null,
    git: ?[]const u8 = null,
    optional: bool = false,
    default_features: ?bool = null,
    features: []const []const u8 = &.{},
    /// Whether this build's RESOLVED feature set for this dependency is
    /// certainly empty.
    ///
    /// The declared `features` above are what the dependency table asked for,
    /// and they say nothing about a forward edge in the consuming crate's own
    /// feature table — `std = ["num-traits/std"]` switches a dependency
    /// feature on without the dependency ever naming it. Only the frontend can
    /// read that edge, so only the frontend may answer this. Default false
    /// means UNKNOWN: every hand-built fixture and every existing constructor
    /// reads unknown until the frontend opts in, and an answer of false must
    /// never be read as "this package is in its default, featureless
    /// configuration".
    resolved_features_known_empty: bool = false,
};

/// A crate in the graph (a workspace / dependency set). v1 fills exactly one.
pub const Crate = struct {
    name: []const u8,
    edition: u16, // 2015/2018/2021 (2024) — affects path resolution
    kind: CrateKind,
    root: spine.EntityId, // the crate-root Module
    deps: []const CrateDep,
    is_translated: bool,
};

pub const ExternalUse = struct {
    /// The rooted Rust path that has no translated graph entity.
    path: []const []const u8,
};

pub const UseKind = union(enum) {
    plain: spine.EntityId, // use a::b::C;        → target
    alias: spine.EntityId, // use a::b as X;      → target, local name X
    glob, //                  use a::b::*;        → marked, backend enumerates
    external: ExternalUse, // unresolved rooted alloc/core/std path; target stays 0
};

/// A `use` / `pub use` declaration (data-model/crate-graph.md §2.3, §3.4).
/// Lives in the graph's `uses` table; its `id` is the same EntityId as the
/// use_ Entity in the SymbolTable. The backend materializes an exporting
/// `UseDecl` (is_pub_export == true) as `pub const alias = target;` because
/// Zig has no re-export.
pub const UseDecl = struct {
    id: spine.EntityId,
    kind: UseKind,
    local_name: []const u8, // name binding into the current scope
    is_pub_export: bool,
    // The resolved definition, or zero for glob/unresolved external uses.
    target: spine.EntityId,
    span: spine.Span,
};

/// An external crate binding (data-model/crate-graph.md §3.4).
pub const ExternCrate = struct {
    id: spine.EntityId,
    crate_id: u32,
    alias: []const u8,
};

/// Leading segment of a Rust path (data-model/crate-graph.md §3.2).
pub const PathPrefix = union(enum) {
    crate_,
    self_,
    super_,
    @"extern": []const u8, // `extern` → external crate name
};

/// An ordered path plus, after resolution, a terminal target EntityId.
pub const Path = struct {
    prefix: ?PathPrefix, // null → relative to current scope
    segments: []const []const u8,
    resolution: ?spine.EntityId,
};

pub const TopologyError = error{
    NoCrate,
    MissingRootModule,
    InvalidEntityId,
    InvalidModuleId,
    InvalidModuleEntity,
    InvalidParent,
    InvalidResolvedEntity,
    UnknownModuleItem,
    MissingModuleItem,
    DuplicateModuleItem,
    InvalidModuleItemParent,
    MissingUseMetadata,
    InvalidUseMetadata,
    InvalidDependency,
    UnownedEntity,
};

/// Top of the model: the set of crates, their modules, and the global symbol
/// table. Cross-references are always EntityIds (pointer-chasing, never text).
pub const CrateGraph = struct {
    allocator: std.mem.Allocator,
    crates: std.ArrayListUnmanaged(Crate) = .empty,
    symbol_table: spine.SymbolTable,
    // Dense Module table: Module.id == index into this list (mirrors the
    // SymbolTable, since every Module is also an Entity).
    modules: std.ArrayListUnmanaged(Module) = .empty,
    // `use` / `pub use` decls, keyed by the same EntityId as the use_ entity.
    uses: std.ArrayListUnmanaged(UseDecl) = .empty,
    // Wire header (data-model.md §4); round-tripped, not otherwise interpreted.
    sidecar: ?[]const u8 = null,
    toolchain: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) CrateGraph {
        return .{
            .allocator = allocator,
            .symbol_table = spine.SymbolTable.init(allocator),
        };
    }

    /// Release every owned string and slice, then the backing arrays.
    pub fn deinit(self: *CrateGraph) void {
        const a = self.allocator;

        for (self.crates.items) |*c| {
            a.free(c.name);
            for (c.deps) |d| {
                a.free(d.extern_name);
                a.free(d.local_alias);
                if (d.version) |version| a.free(version);
                if (d.path) |path| a.free(path);
                if (d.git) |git| a.free(git);
                for (d.features) |feature| a.free(feature);
                if (d.features.len > 0) a.free(d.features);
            }
            a.free(c.deps);
        }
        self.crates.deinit(a);

        for (self.modules.items) |*m| {
            a.free(m.name);
            if (m.source_path) |sp| a.free(sp);
            a.free(m.items);
            freeAttributes(a, m.attributes);
        }
        self.modules.deinit(a);

        for (self.uses.items) |*u| {
            a.free(u.local_name);
            switch (u.kind) {
                .external => |external| {
                    for (external.path) |segment| a.free(segment);
                    if (external.path.len > 0) a.free(external.path);
                },
                else => {},
            }
        }
        self.uses.deinit(a);

        // Free per-entity strings, then the symbol table's backing array. An
        // entity name is a slice the CALLER supplied, so ownership is recorded
        // on the entity rather than assumed from the type: a site that passed a
        // string literal or any slice it does not own sets `name_owned = false`
        // and this must not free it. Freeing a literal is not a leak — Zig
        // dedupes identical literals, so one such free corrupts the single byte
        // sequence the whole test binary shares for that spelling.
        for (self.symbol_table.entities.items) |*e| {
            if (e.name_owned) a.free(e.name);
            if (e.renamed_to) |rn| a.free(rn);
            switch (e.visibility) {
                .in_path => |p| a.free(p),
                else => {},
            }
            freeAttributes(a, e.attributes);
        }
        self.symbol_table.deinit();

        if (self.sidecar) |s| a.free(s);
        if (self.toolchain) |t| a.free(t);
        self.* = undefined;
    }

    pub fn addCrate(self: *CrateGraph, c: Crate) !void {
        try self.crates.append(self.allocator, c);
    }

    /// Append a module, assigning the next dense id (overwrites `m.id`).
    pub fn addModule(self: *CrateGraph, m: Module) !spine.EntityId {
        const id: spine.EntityId = @intCast(self.modules.items.len);
        var mm = m;
        mm.id = id;
        try self.modules.append(self.allocator, mm);
        return id;
    }

    /// Look up the module row owned by an entity, rejecting ambiguous rows.
    pub fn moduleForEntity(
        self: *const CrateGraph,
        entity_id: spine.EntityId,
    ) ?*const Module {
        const entity = self.symbol_table.get(entity_id) orelse return null;
        if (entity.kind != .module) return null;
        return self.moduleForEntityFields(entity.parent, entity.name);
    }

    /// Return the entity id that owns a module row.
    ///
    /// Module rows have a dense row id, while their parent and item edges use
    /// symbol-table entity ids. Match the stable module name and parent edge
    /// instead of confusing those two id spaces.
    pub fn moduleEntityId(self: *const CrateGraph, module_row: *const Module) ?spine.EntityId {
        var result: ?spine.EntityId = null;
        for (self.symbol_table.entities.items) |entity| {
            if (entity.kind != .module) continue;
            if (entity.parent != module_row.parent) continue;
            if (!std.mem.eql(u8, entity.name, module_row.name)) continue;
            if (result != null) return null;
            result = entity.id;
        }
        return result;
    }

    fn moduleForEntityFields(
        self: *const CrateGraph,
        parent: ?spine.EntityId,
        name: []const u8,
    ) ?*const Module {
        var result: ?*const Module = null;
        for (self.modules.items) |*module_row| {
            if (module_row.parent != parent) continue;
            if (!std.mem.eql(u8, module_row.name, name)) continue;
            if (result != null) return null;
            result = module_row;
        }
        return result;
    }

    /// Look up the Module a declaration owns.
    ///
    /// An EntityId names ONE declaration, so this answers about that
    /// declaration and nothing else: when the symbol table holds the id, the id
    /// has already named its row, and a row that is not a module has no module
    /// row to answer with. Falling through to `moduleById` in that case would
    /// let one id name two declarations — the entity it indexes AND whatever
    /// module happens to sit at that dense row position — which is how a
    /// function's id comes to resolve to a module and a receiver to be read off
    /// the wrong declaration.
    ///
    /// The dense-row fallback is therefore only for an id the symbol table does
    /// NOT hold, which is the small graph-only fixture that has module rows and
    /// no entity table.
    pub fn module(self: *const CrateGraph, id: spine.EntityId) ?Module {
        if (self.symbol_table.get(id)) |entity| {
            if (entity.kind != .module) return null;
            const module_row = self.moduleForEntity(id) orelse return null;
            return module_row.*;
        }
        const module_row = self.moduleById(id) orelse return null;
        return module_row.*;
    }

    /// Return the dense module row for an EntityId.
    ///
    /// A validator and backend must not silently accept a missing module row.
    /// The dense table is authoritative, so an id that does not equal its
    /// row index is malformed even if a later linear scan would find it.
    pub fn moduleById(self: *const CrateGraph, id: spine.EntityId) ?*const Module {
        if (@as(usize, id) >= self.modules.items.len) return null;
        const module_row = &self.modules.items[@as(usize, id)];
        if (module_row.id != id) return null;
        return module_row;
    }

    /// Return whether a module explicitly owns an item id.
    pub fn moduleHasItem(
        self: *const CrateGraph,
        module_id: spine.EntityId,
        item_id: spine.EntityId,
    ) bool {
        const module_row = self.moduleForEntity(module_id) orelse return false;
        for (module_row.items) |candidate| {
            if (candidate == item_id) return true;
        }
        return false;
    }

    /// Return whether an entity is rooted at the specified crate root.
    ///
    /// This walks parent edges, not module-row indices. A malformed cycle or
    /// missing parent is reported as not belonging to the root.
    pub fn entityBelongsToRoot(
        self: *const CrateGraph,
        entity_id: spine.EntityId,
        root_id: spine.EntityId,
    ) bool {
        var current = entity_id;
        var steps: usize = 0;
        while (steps <= self.symbol_table.entities.items.len) : (steps += 1) {
            if (current == root_id) return true;
            const entity = self.symbol_table.get(current) orelse return false;
            current = entity.parent orelse return false;
        }
        return false;
    }

    /// Reject every malformed graph edge before serialization or lowering.
    pub fn validateTopology(self: *const CrateGraph) TopologyError!void {
        if (self.crates.items.len == 0) return error.NoCrate;
        if (self.modules.items.len == 0) return error.MissingRootModule;

        for (self.symbol_table.entities.items, 0..) |entity, index| {
            if (@as(usize, entity.id) != index) return error.InvalidEntityId;
        }
        // A module row's PARENT edge is checked before the row is resolved to an
        // entity, because the row is identified by (parent, name): a parent that
        // names no module makes the pair match nothing, and reporting that as a
        // missing module entity would blame the row for a fault in its parent
        // edge. `InvalidParent` names the edge that is actually malformed.
        for (self.modules.items) |module_row| {
            if (module_row.parent) |parent_id| {
                if (@as(usize, parent_id) >= self.symbol_table.entities.items.len) {
                    return error.InvalidParent;
                }
                if (self.symbol_table.entities.items[parent_id].kind != .module) {
                    return error.InvalidParent;
                }
                if (self.moduleForEntity(parent_id) == null) return error.InvalidParent;
            }
        }

        // Each module ROW must be the row of a DISTINCT module ENTITY. Two rows
        // answering for one entity is the same identity fault as two entities
        // answering for one row, in the other direction: `moduleEntityId` finds
        // each row's entity by (parent, name), so two rows carrying the same
        // pair both resolve to the same entity and every later read of "the
        // module row for this module" has two candidates. Refusing here means
        // the ambiguity is caught once, at the row that introduces it, instead
        // of surfacing later as whichever row a linear scan happened to reach
        // first.
        for (self.modules.items, 0..) |module_row, index| {
            if (@as(usize, module_row.id) != index) return error.InvalidModuleId;
            const entity_id = self.moduleEntityId(&module_row) orelse
                return error.InvalidModuleEntity;
            for (self.modules.items[0..index]) |prior| {
                const prior_entity_id = self.moduleEntityId(&prior) orelse
                    return error.InvalidModuleEntity;
                if (prior_entity_id == entity_id) return error.InvalidModuleEntity;
            }
        }

        for (self.crates.items, 0..) |crate, crate_index| {
            if (@as(usize, crate.root) >= self.symbol_table.entities.items.len) {
                return error.MissingRootModule;
            }
            const root_entity = self.symbol_table.entities.items[crate.root];
            const root_module = self.moduleForEntity(crate.root) orelse
                return error.MissingRootModule;
            if (root_entity.kind != .module or
                root_module.kind != .root or
                !root_module.is_crate or
                root_module.is_extern or
                root_module.parent != null)
            {
                return error.MissingRootModule;
            }
            for (self.crates.items[0..crate_index]) |prior| {
                if (prior.root == crate.root) return error.MissingRootModule;
            }
            for (crate.deps, 0..) |dependency, dependency_index| {
                if (dependency_index >= @as(usize, std.math.maxInt(u32))) {
                    return error.InvalidDependency;
                }
                if (dependency.id != @as(u32, @intCast(dependency_index + 1))) {
                    return error.InvalidDependency;
                }
            }
        }

        for (self.modules.items) |module_row| {
            // The parent edge was checked above; resolving the row's own entity
            // is what remains, and the crate-root case needs that id to ask
            // whether this row IS a crate's root.
            const module_entity_id = self.moduleEntityId(&module_row) orelse
                return error.InvalidModuleEntity;
            if (module_row.parent == null and !module_row.is_extern) {
                var is_crate_root = false;
                for (self.crates.items) |crate| {
                    if (crate.root == module_entity_id) {
                        is_crate_root = true;
                        break;
                    }
                }
                if (!is_crate_root or module_row.kind != .root or !module_row.is_crate) {
                    return error.MissingRootModule;
                }
            }

            for (module_row.items, 0..) |item_id, item_index| {
                if (@as(usize, item_id) >= self.symbol_table.entities.items.len) {
                    return error.UnknownModuleItem;
                }
                const item = self.symbol_table.entities.items[item_id];
                if (item.parent != module_entity_id) return error.InvalidModuleItemParent;
                for (module_row.items[0..item_index]) |prior| {
                    if (prior == item_id) return error.DuplicateModuleItem;
                }
            }
        }

        for (self.symbol_table.entities.items) |entity| {
            if (entity.parent) |parent_id| {
                if (@as(usize, parent_id) >= self.symbol_table.entities.items.len) {
                    return error.InvalidParent;
                }
                const parent = self.symbol_table.entities.items[parent_id];
                if (parent.kind == .module) {
                    if (self.moduleForEntity(parent_id) == null) return error.InvalidModuleEntity;
                    if (!self.moduleHasItem(parent_id, entity.id)) {
                        return error.MissingModuleItem;
                    }
                }
                if (entity.kind == .use_ or entity.kind == .extern_crate) {
                    if (parent.kind != .module) return error.InvalidModuleItemParent;
                }
            } else if (entity.kind != .module and entity.kind != .crate_) {
                return error.MissingModuleItem;
            }
            if (entity.kind == .method_ref) {
                const parent_id = entity.parent orelse return error.MissingModuleItem;
                const parent_kind = self.symbol_table.entities.items[parent_id].kind;
                if (parent_kind != .fn_ and parent_kind != .trait_) {
                    return error.InvalidParent;
                }
                if (entity.resolved != null) return error.InvalidResolvedEntity;
            }
            if (entity.resolved) |resolved_id| {
                if (@as(usize, resolved_id) >= self.symbol_table.entities.items.len) {
                    return error.InvalidResolvedEntity;
                }
            }
            if (entity.kind == .module and self.moduleForEntity(entity.id) == null) {
                return error.InvalidModuleEntity;
            }
        }

        for (self.symbol_table.entities.items) |entity| {
            var rooted = false;
            for (self.crates.items) |crate| {
                if (self.entityBelongsToRoot(entity.id, crate.root)) {
                    rooted = true;
                    break;
                }
            }
            if (!rooted) {
                for (self.modules.items) |module_row| {
                    if (!module_row.is_extern or module_row.parent != null) continue;
                    const extern_root_id = self.moduleEntityId(&module_row) orelse
                        return error.InvalidModuleEntity;
                    if (self.entityBelongsToRoot(entity.id, extern_root_id)) {
                        rooted = true;
                        break;
                    }
                }
            }
            if (!rooted) return error.UnownedEntity;
        }

        for (self.uses.items, 0..) |use_decl, use_index| {
            if (@as(usize, use_decl.id) >= self.symbol_table.entities.items.len) {
                return error.InvalidUseMetadata;
            }
            const use_entity = self.symbol_table.entities.items[use_decl.id];
            if (use_entity.kind != .use_) return error.InvalidUseMetadata;
            if (use_decl.kind != .external and
                @as(usize, use_decl.target) >= self.symbol_table.entities.items.len)
            {
                return error.InvalidUseMetadata;
            }
            if (use_entity.resolved) |resolved_id| {
                if (resolved_id != use_decl.target) return error.InvalidUseMetadata;
            }
            for (self.uses.items[0..use_index]) |prior| {
                if (prior.id == use_decl.id) return error.InvalidUseMetadata;
            }
            switch (use_decl.kind) {
                .plain => |target| if (target != use_decl.target) return error.InvalidUseMetadata,
                .alias => |target| if (target != use_decl.target) return error.InvalidUseMetadata,
                .glob => {},
                .external => |external| {
                    if (use_decl.target != 0 or use_entity.resolved != null) {
                        return error.InvalidUseMetadata;
                    }
                    if (external.path.len == 0) return error.InvalidUseMetadata;
                    for (external.path) |segment| {
                        if (segment.len == 0) return error.InvalidUseMetadata;
                    }
                },
            }
        }
        for (self.symbol_table.entities.items) |entity| {
            if (entity.kind == .use_ and self.useById(entity.id) == null) {
                return error.MissingUseMetadata;
            }
        }
    }

    pub fn findCrate(self: *const CrateGraph, name: []const u8) ?Crate {
        for (self.crates.items) |c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }

    /// Record a use declaration; `u.id` must be the use_ entity's EntityId.
    pub fn addUse(self: *CrateGraph, u: UseDecl) !void {
        try self.uses.append(self.allocator, u);
    }

    /// Find the UseDecl whose EntityId is `id` (linear; uses are few).
    pub fn useById(self: *const CrateGraph, id: spine.EntityId) ?UseDecl {
        for (self.uses.items) |u| {
            if (u.id == id) return u;
        }
        return null;
    }

    /// The declaration a `use` binds, or null when it binds none.
    ///
    /// `UseDecl.target` carries `0` for a glob and for an unresolved
    /// `core`/`std` path, and `0` is also the crate-root module's EntityId. So
    /// the raw field has one value standing for two facts, and a reader that
    /// takes it as an id resolves a `use std::io::Read` to the crate root. This
    /// reads the KIND first and answers null whenever no declaration is named,
    /// so the one EntityId a use can carry is always a declaration's.
    pub fn useTarget(self: *const CrateGraph, id: spine.EntityId) ?spine.EntityId {
        const use_decl = self.useById(id) orelse return null;
        return switch (use_decl.kind) {
            .plain => |target| target,
            .alias => |target| target,
            .glob, .external => null,
        };
    }

    /// Lazy query, not stored state (crate-graph.md §2.2): the set of item ids
    /// reachable through a module whose Entity.visibility is `.public`. Kept
    /// intentionally simple; recursion into public sub-modules is a later
    /// refinement (this honors the surface walk's minimal contract).
    pub fn exportedSurface(
        self: *const CrateGraph,
        allocator: std.mem.Allocator,
        mod_id: spine.EntityId,
    ) ![]spine.EntityId {
        try self.validateTopology();
        const m = self.module(mod_id) orelse return error.UnknownModule;
        const module_entity_id = self.moduleEntityId(
            self.moduleForEntity(mod_id) orelse return error.UnknownModule,
        ) orelse return error.InvalidModuleEntity;
        var out: std.ArrayListUnmanaged(spine.EntityId) = .empty;
        errdefer out.deinit(allocator);
        for (m.items) |item_id| {
            const e = self.symbol_table.get(item_id) orelse return error.UnknownModuleItem;
            if (e.parent != module_entity_id) return error.InvalidModuleItemParent;
            const is_public = switch (e.visibility) {
                .public => true,
                else => false,
            };
            if (is_public) try out.append(allocator, item_id);
        }
        return out.toOwnedSlice(allocator);
    }
};

fn freeAttributes(a: std.mem.Allocator, attrs: []const spine.Attribute) void {
    for (attrs) |at| {
        a.free(at.name);
        a.free(at.meta);
    }
    a.free(attrs);
}

test "addModule assigns dense ids mirroring the symbol table" {
    const allocator = std.testing.allocator;
    var g = CrateGraph.init(allocator);
    defer g.deinit();
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    const id0 = try g.addModule(.{
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
    const id1 = try g.addModule(.{
        .id = 0,
        .kind = .file,
        .name = "",
        .parent = id0,
        .source_path = null,
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });
    try std.testing.expectEqual(@as(spine.EntityId, 0), id0);
    try std.testing.expectEqual(@as(spine.EntityId, 1), id1);
    try std.testing.expectEqual(ModuleKind.file, g.module(id1).?.kind);
}

test "exportedSurface collects only public items" {
    const allocator = std.testing.allocator;
    var g = CrateGraph.init(allocator);
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
        .name = try allocator.dupe(u8, ""),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const foo_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "foo"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const bar_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "bar"),
        .span = span,
        .visibility = .private,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const module_items = try allocator.dupe(spine.EntityId, &.{ foo_id, bar_id });
    _ = try g.addModule(.{
        .id = root_id,
        .kind = .root,
        .name = try allocator.dupe(u8, ""),
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = module_items,
        .attributes = &.{},
    });
    try g.addCrate(.{
        .name = try allocator.dupe(u8, "surface"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    const surface = try g.exportedSurface(allocator, root_id);
    defer allocator.free(surface);
    try std.testing.expectEqual(@as(usize, 1), surface.len);
    try std.testing.expectEqual(foo_id, surface[0]);
}

test "exportedSurface rejects malformed item endpoints" {
    const allocator = std.testing.allocator;
    var g = CrateGraph.init(allocator);
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
        .name = try allocator.dupe(u8, ""),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const item_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "orphan"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const module_items = try allocator.dupe(spine.EntityId, &.{item_id});
    _ = try g.addModule(.{
        .id = root_id,
        .kind = .root,
        .name = try allocator.dupe(u8, ""),
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = module_items,
        .attributes = &.{},
    });
    try g.addCrate(.{
        .name = try allocator.dupe(u8, "surface"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    module_items[0] = 99;
    try std.testing.expectError(
        error.UnknownModuleItem,
        g.exportedSurface(allocator, root_id),
    );
}

test "deinit frees every owned entity name exactly once" {
    const allocator = std.testing.allocator;
    var g = CrateGraph.init(allocator);
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    // Many distinct names rather than one, so a missed free or a double free
    // is reported instead of hiding behind an allocation the graph reuses.
    // `std.testing.allocator` fails the test on either.
    var index: usize = 0;
    while (index < 64) : (index += 1) {
        _ = try g.symbol_table.add(.{
            .id = 0,
            .kind = .fn_,
            .name = try std.fmt.allocPrint(allocator, "entity_{d}", .{index}),
            .span = span,
            .visibility = .public,
            .parent = null,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
        });
    }
    g.deinit();
}

test "deinit leaves an entity name the graph does not own alone" {
    const allocator = std.testing.allocator;
    // A string literal is what a fixture writes when it means to write a name,
    // and this spelling is not private to this test: `cst.zig` compares entity
    // names against it and the ts_ext receiver handling does too. Zig dedupes
    // identical literals, so freeing this one name damages the single shared
    // byte sequence for `self` across the whole test binary rather than a
    // private copy.
    const literal: []const u8 = "self";
    var g = CrateGraph.init(allocator);
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };
    const id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = literal,
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
        .name_owned = false,
    });
    try std.testing.expectEqualStrings("self", g.symbol_table.get(id).?.name);

    g.deinit();

    // The point of the flag: `deinit` ran to completion over this graph and
    // left the borrowed name alone. Before the flag existed this call freed the
    // literal, which under `std.testing.allocator` is an invalid free and
    // aborts — so this test is the one that fails when the ownership is not
    // recorded.
    try std.testing.expectEqualStrings("self", literal);
}

/// Build a well-formed single-crate graph and the ids a test needs to perturb.
///
/// The shape is the smallest one that exercises DECLARATION parenting: a crate
/// root module, a struct declared in it, an `impl` block whose parent is that
/// struct, and a method whose parent is the `impl` — plus a free function whose
/// parent is the module. The method is the case this module exists to pin: it
/// is NOT a module item, and a fixture that parents it on the module instead of
/// on the impl is the bug that made receiver identity read off the wrong
/// declaration.
const IdentityFixture = struct {
    graph: CrateGraph,
    root_module: spine.EntityId,
    free_fn: spine.EntityId,
    point_struct: spine.EntityId,
    impl_block: spine.EntityId,
    method: spine.EntityId,
};

fn buildIdentityFixture(allocator: std.mem.Allocator) !IdentityFixture {
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };
    var g = CrateGraph.init(allocator);
    errdefer g.deinit();

    const root_module = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try allocator.dupe(u8, ""),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const free_fn = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "free_fn"),
        .span = span,
        .visibility = .public,
        .parent = root_module,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const point_struct = try g.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = try allocator.dupe(u8, "Point"),
        .span = span,
        .visibility = .public,
        .parent = root_module,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    // The impl block is parented on the TYPE it implements for, not on the
    // module that declares it — `finalizePendingImpls` rewrites this edge once
    // the target resolves.
    const impl_block = try g.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = try allocator.dupe(u8, "Point"),
        .span = span,
        .visibility = .public,
        .parent = point_struct,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    // The method's parent is the impl. This is the whole point.
    const method = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "x"),
        .span = span,
        .visibility = .public,
        .parent = impl_block,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // The root module lists exactly what it DECLARES: the free function and
    // the struct. The impl is reached through the struct and the method
    // through the impl, so neither belongs here.
    const root_items = try allocator.dupe(spine.EntityId, &.{ free_fn, point_struct });
    _ = try g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = try allocator.dupe(u8, ""),
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = root_items,
        .attributes = &.{},
    });
    try g.addCrate(.{
        .name = try allocator.dupe(u8, "identity"),
        .edition = 2021,
        .kind = .lib,
        .root = root_module,
        .deps = &.{},
        .is_translated = true,
    });

    return .{
        .graph = g,
        .root_module = root_module,
        .free_fn = free_fn,
        .point_struct = point_struct,
        .impl_block = impl_block,
        .method = method,
    };
}

test "an EntityId names one declaration across every graph edge" {
    const allocator = std.testing.allocator;
    var f = try buildIdentityFixture(allocator);
    defer f.graph.deinit();
    const g = &f.graph;

    // The graph as built is sound; the properties below are read off a graph
    // that validates, so a failure means an identity fault and not a broken
    // fixture.
    try g.validateTopology();

    // Every id reads back its OWN row. Each declaration here carries a distinct
    // name or a distinct kind, so an id that resolved to a second declaration
    // would answer one of these with the other's value.
    try std.testing.expectEqual(@as(spine.EntityId, 0), f.root_module);
    try std.testing.expectEqualStrings("", g.symbol_table.get(f.root_module).?.name);
    try std.testing.expectEqualStrings("free_fn", g.symbol_table.get(f.free_fn).?.name);
    try std.testing.expectEqualStrings("Point", g.symbol_table.get(f.point_struct).?.name);
    try std.testing.expectEqualStrings("Point", g.symbol_table.get(f.impl_block).?.name);
    try std.testing.expectEqualStrings("x", g.symbol_table.get(f.method).?.name);

    // Two declarations share the spelling "Point" — the struct and the impl
    // block — and their ids still tell them apart, which is the case a
    // name-keyed table would get wrong.
    try std.testing.expect(f.point_struct != f.impl_block);
    try std.testing.expectEqual(
        spine.EntityKind.struct_,
        g.symbol_table.get(f.point_struct).?.kind,
    );
    try std.testing.expectEqual(
        spine.EntityKind.impl_,
        g.symbol_table.get(f.impl_block).?.kind,
    );

    // Each module row resolves to exactly one entity, and the two module edges
    // — `parent` and `items` — agree about which declarations the module owns.
    try std.testing.expectEqual(
        @as(?spine.EntityId, f.root_module),
        g.moduleEntityId(&g.modules.items[0]),
    );
    try std.testing.expect(g.moduleForEntity(f.root_module) != null);
    try std.testing.expect(g.moduleHasItem(f.root_module, f.free_fn));
    try std.testing.expect(g.moduleHasItem(f.root_module, f.point_struct));

    // `module` answers about a module id and only about a module id. A
    // declaration that is not a module has no module row, and one EntityId must
    // not name both the declaration and whatever module row shares its index.
    try std.testing.expectEqual(ModuleKind.root, g.module(f.root_module).?.kind);
    for ([_]spine.EntityId{ f.free_fn, f.point_struct, f.impl_block, f.method }) |non_module| {
        try std.testing.expect(g.module(non_module) == null);
        try std.testing.expect(g.moduleForEntity(non_module) == null);
    }
}

/// Replace the root module's `items`, freeing the slice it replaced.
///
/// The graph owns its `items` slice and `deinit` frees whichever one is
/// current, so a test that swaps it has to free the outgoing one itself. Both
/// are heap slices here — never a literal — so the free is always of something
/// this allocator handed out.
fn setRootItems(g: *CrateGraph, items: []spine.EntityId) void {
    const allocator = g.allocator;
    allocator.free(g.modules.items[0].items);
    g.modules.items[0].items = items;
}

test "a method's parent is its declaration and never a module" {
    const allocator = std.testing.allocator;
    var f = try buildIdentityFixture(allocator);
    defer f.graph.deinit();
    const g = &f.graph;

    // As declared: the method hangs off the impl, and the impl hangs off the
    // type it is for. `super::` and receiver resolution climb exactly that
    // chain.
    try std.testing.expectEqual(
        @as(?spine.EntityId, f.impl_block),
        g.symbol_table.get(f.method).?.parent,
    );
    try std.testing.expectEqual(
        @as(?spine.EntityId, f.point_struct),
        g.symbol_table.get(f.impl_block).?.parent,
    );
    try std.testing.expect(g.moduleHasItem(f.root_module, f.method) == false);
    try g.validateTopology();

    // The module's `items` must name the method's OWN parent or nothing. This
    // is the first direction of the one-fact rule, and it is what catches the
    // fixture bug: a method listed by the module while parented on the impl
    // gives one declaration two parents, and the graph refuses rather than
    // letting a later read pick one.
    setRootItems(g, try allocator.dupe(spine.EntityId, &.{
        f.free_fn,
        f.point_struct,
        f.method,
    }));
    try std.testing.expectError(error.InvalidModuleItemParent, g.validateTopology());

    // The second direction: reparent the method onto the module and leave it out
    // of `items`. Now the module does not list it, and the entity loop refuses
    // that too — so there is no way to leave a method owned by a module that
    // does not admit to it.
    setRootItems(g, try allocator.dupe(spine.EntityId, &.{ f.free_fn, f.point_struct }));
    g.symbol_table.entities.items[f.method].parent = f.root_module;
    try std.testing.expectError(error.MissingModuleItem, g.validateTopology());

    // And the pair that IS legal: the module lists it AND the method's parent
    // is the module. That is not a method at all — it is a free function, and
    // the graph accepts it as one. The distinction is WHICH parent is named, so
    // a method mis-parented onto the module is indistinguishable from a free
    // function unless the impl also lists it; `assoc_items` is what says so.
    // Pinning the legal case is what keeps this from reading as "the validator
    // refuses every method-ish parent", which would be wrong.
    setRootItems(g, try allocator.dupe(spine.EntityId, &.{
        f.free_fn,
        f.point_struct,
        f.method,
    }));
    try g.validateTopology();
}

test "an impl block is parented on the type it implements for" {
    const allocator = std.testing.allocator;
    var f = try buildIdentityFixture(allocator);
    defer f.graph.deinit();
    const g = &f.graph;

    // `impl Point { .. }` sits inside the struct `Point`, not beside it. That
    // is the edge receiver resolution walks to answer "what type is this
    // method for", so an impl parented on the MODULE — which is also a live id
    // and also passes a naive containment check — would silently change the
    // answer while leaving the graph well-formed.
    const impl_entity = g.symbol_table.get(f.impl_block).?;
    try std.testing.expectEqual(spine.EntityKind.impl_, impl_entity.kind);
    try std.testing.expectEqual(@as(?spine.EntityId, f.point_struct), impl_entity.parent);
    try std.testing.expect(impl_entity.parent != f.root_module);
    const impl_target = g.symbol_table.get(impl_entity.parent.?) orelse unreachable;
    try std.testing.expectEqual(spine.EntityKind.struct_, impl_target.kind);
    try std.testing.expectEqual(f.point_struct, impl_target.id);

    // Both declarations are still reachable from the crate root through the
    // chain, so the stricter parenting costs nothing.
    try std.testing.expect(g.entityBelongsToRoot(f.impl_block, f.root_module));
    try std.testing.expect(g.entityBelongsToRoot(f.method, f.root_module));
    try g.validateTopology();
}

test "moduleEntityId rejects two modules sharing a parent and a name" {
    const allocator = std.testing.allocator;
    var f = try buildIdentityFixture(allocator);
    defer f.graph.deinit();
    const g = &f.graph;

    // A second module ENTITY with the same (parent, name) as the root: both are
    // kind `.module`, both hang off nothing, both are spelled "". There is no
    // field left to tell them apart, so `moduleEntityId` must answer null rather
    // than hand back the first — a caller reading the first would resolve every
    // `super::` edge in the crate through whichever entity the scan reached
    // first, which for a duplicate is arbitrary.
    const shadow = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try allocator.dupe(u8, ""),
        .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try std.testing.expect(shadow != f.root_module);
    try std.testing.expect(g.moduleEntityId(&g.modules.items[0]) == null);

    // The two lookups detect the ambiguity on different sides, and both are
    // right: `moduleEntityId` asks "which ENTITY owns this row" and finds two
    // candidates, so it refuses. `moduleForEntity` asks the reverse question —
    // "which ROW does this entity's (parent, name) name" — and there is still
    // exactly one such row, so it answers. A reader that wants to be sure the
    // pair identifies a module must go through `moduleEntityId`, which is what
    // `validateTopology` does for every row; this asserts the division so the
    // asymmetry reads as design rather than as a hole.
    // Both entities resolve to the SAME row — that is the whole fault. The row
    // side is unambiguous while the entity side is not, so nothing that only
    // walks parent edges can tell the two declarations apart.
    const root_row = g.moduleForEntity(f.root_module).?;
    const shadow_row = g.moduleForEntity(shadow).?;
    try std.testing.expectEqual(@as(usize, 0), root_row.id);
    try std.testing.expectEqual(@as(usize, 0), shadow_row.id);
    try std.testing.expectEqual(root_row.id, shadow_row.id);
    // The shadow has no module row of its own, so the graph is refused rather
    // than quietly using the root's row for a second declaration.
    try std.testing.expectError(error.InvalidModuleEntity, g.validateTopology());

    // Give the shadow a row that duplicates the root's (parent, name) and the
    // ambiguity is now two-sided: two entities for one row. Still refused, and
    // for the same reason — the pair no longer identifies a module.
    const shadow_items = try allocator.dupe(spine.EntityId, &.{});
    _ = try g.addModule(.{
        .id = 0,
        .kind = .@"inline",
        .name = try allocator.dupe(u8, ""),
        .parent = null,
        .source_path = null,
        .is_crate = false,
        .is_extern = false,
        .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
        .items = shadow_items,
        .attributes = &.{},
    });
    try std.testing.expect(g.moduleEntityId(&g.modules.items[0]) == null);
    try std.testing.expect(g.moduleEntityId(&g.modules.items[1]) == null);
    try std.testing.expectError(error.InvalidModuleEntity, g.validateTopology());
}

test "two module rows may not answer for one module entity" {
    const allocator = std.testing.allocator;
    var f = try buildIdentityFixture(allocator);
    defer f.graph.deinit();
    const g = &f.graph;

    // One module entity, two rows naming it. `moduleEntityId` finds a single
    // entity for each row, so nothing about the PAIR is ambiguous — which is
    // exactly why this has to be refused explicitly: every later read of "the
    // module row for the root" has two candidates, and a linear scan resolves
    // that by row order, so `module(root)` would answer with whichever row
    // happens to sit first and `moduleHasItem` would consult the other's items.
    const duplicate_items = try allocator.dupe(spine.EntityId, &.{});
    _ = try g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = try allocator.dupe(u8, ""),
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
        .items = duplicate_items,
        .attributes = &.{},
    });

    // Both rows name the root entity, and `moduleEntityId` reports that for
    // each — so the refusal cannot come from an ambiguous name match.
    try std.testing.expectEqual(
        @as(?spine.EntityId, f.root_module),
        g.moduleEntityId(&g.modules.items[0]),
    );
    try std.testing.expectEqual(
        @as(?spine.EntityId, f.root_module),
        g.moduleEntityId(&g.modules.items[1]),
    );
    try std.testing.expectError(error.InvalidModuleEntity, g.validateTopology());
}

test "validateTopology refuses a graph whose entity ids were reused" {
    const allocator = std.testing.allocator;
    var f = try buildIdentityFixture(allocator);
    defer f.graph.deinit();
    const g = &f.graph;
    try g.validateTopology();

    // Point a row's stored id at another row's index. `SymbolTable.add` cannot
    // produce this — it overwrites `.id` with the row's own index — but the
    // field is public and a deserializer or a fixture can, so the topology
    // check is the backstop that keeps one id from naming two rows.
    g.symbol_table.entities.items[f.method].id = f.free_fn;
    try std.testing.expectError(error.InvalidEntityId, g.validateTopology());

    // Restored, the same graph validates again: the refusal is about the
    // reused id, not about the graph's shape.
    g.symbol_table.entities.items[f.method].id = f.method;
    try g.validateTopology();
}

test "a deferred binder placeholder is not a graph declaration" {
    const allocator = std.testing.allocator;
    var f = try buildIdentityFixture(allocator);
    defer f.graph.deinit();
    const g = &f.graph;

    const placeholder = spine.deferredPlaceholder(0).?;
    // No row answers for it, in either id space.
    try std.testing.expect(g.symbol_table.get(placeholder) == null);
    try std.testing.expect(g.moduleById(placeholder) == null);
    try std.testing.expect(g.module(placeholder) == null);
    try std.testing.expect(g.moduleForEntity(placeholder) == null);
    try std.testing.expect(g.entityBelongsToRoot(placeholder, f.root_module) == false);

    // A placeholder used as a `parent` names no declaration, so the graph is
    // refused instead of the edge being read as the last entity or as no edge
    // at all. Both of those would let a method resolve to a receiver its owner
    // never had.
    g.symbol_table.entities.items[f.method].parent = placeholder;
    try std.testing.expectError(error.InvalidParent, g.validateTopology());

    // Same for a module row's parent edge, and for a `resolved` edge: a
    // placeholder is never the answer to "which declaration".
    g.symbol_table.entities.items[f.method].parent = f.impl_block;
    g.modules.items[0].parent = placeholder;
    try std.testing.expectError(error.InvalidParent, g.validateTopology());
    g.modules.items[0].parent = null;
    g.symbol_table.entities.items[f.free_fn].resolved = placeholder;
    try std.testing.expectError(error.InvalidResolvedEntity, g.validateTopology());
}
