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

        // Free per-entity strings, then the symbol table's backing array.
        for (self.symbol_table.entities.items) |*e| {
            a.free(e.name);
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

    /// Look up a Module by its owning entity, or by a dense row id when the
    /// symbol table is not populated (as in small graph-only fixtures).
    pub fn module(self: *const CrateGraph, id: spine.EntityId) ?Module {
        if (self.symbol_table.get(id)) |entity| {
            if (entity.kind == .module) {
                const module_row = self.moduleForEntity(id) orelse return null;
                return module_row.*;
            }
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
        for (self.modules.items, 0..) |module_row, index| {
            if (@as(usize, module_row.id) != index) return error.InvalidModuleId;
            if (self.moduleEntityId(&module_row) == null) return error.InvalidModuleEntity;
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
            const module_entity_id = self.moduleEntityId(&module_row) orelse
                return error.InvalidModuleEntity;
            if (module_row.parent) |parent_id| {
                if (@as(usize, parent_id) >= self.symbol_table.entities.items.len) {
                    return error.InvalidParent;
                }
                if (self.symbol_table.entities.items[parent_id].kind != .module) {
                    return error.InvalidParent;
                }
                if (self.moduleForEntity(parent_id) == null) return error.InvalidParent;
            } else if (!module_row.is_extern) {
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
