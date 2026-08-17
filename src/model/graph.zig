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

/// A dependency edge to an external crate (deps layer, deferred for v1).
/// Records both the dependency's own crate name and the alias a `use` can
/// refer to it by.
pub const CrateDep = struct {
    extern_name: []const u8,
    local_alias: []const u8,
    id: u32,
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

pub const UseKind = union(enum) {
    plain: spine.EntityId, // use a::b::C;        → target
    alias: spine.EntityId, // use a::b as X;      → target, local name X
    glob, //                  use a::b::*;        → marked, emitter enumerates
};

/// A `use` / `pub use` declaration (data-model/crate-graph.md §2.3, §3.4).
/// Lives in the graph's `uses` table; its `id` is the same EntityId as the
/// use_ Entity in the SymbolTable. The emitter materializes an exporting
/// `UseDecl` (is_pub_export == true) as `pub const alias = target;` because
/// Zig has no re-export.
pub const UseDecl = struct {
    id: spine.EntityId,
    kind: UseKind,
    local_name: []const u8, // name binding into the current scope
    is_pub_export: bool,
    target: spine.EntityId, // the resolved definition
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

        for (self.uses.items) |*u| a.free(u.local_name);
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

    /// Look up a Module by id; `null` if id is out of range (dense table).
    pub fn module(self: *const CrateGraph, id: spine.EntityId) ?Module {
        if (id >= self.modules.items.len) return null;
        return self.modules.items[id];
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
        const m = self.module(mod_id) orelse return error.UnknownModule;
        var out: std.ArrayListUnmanaged(spine.EntityId) = .empty;
        errdefer out.deinit(allocator);
        for (m.items) |item_id| {
            if (self.symbol_table.get(item_id)) |e| {
                const is_public = switch (e.visibility) {
                    .public => true,
                    else => false,
                };
                if (is_public) try out.append(allocator, item_id);
            }
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
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    const foo_name = try allocator.dupe(u8, "foo");
    const bar_name = try allocator.dupe(u8, "bar");
    const foo_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = foo_name,
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const bar_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = bar_name,
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const items = try allocator.alloc(spine.EntityId, 2);
    items[0] = foo_id;
    items[1] = bar_id;
    const root_id = try g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = items,
        .attributes = &.{},
    });

    const surface = try g.exportedSurface(allocator, root_id);
    defer allocator.free(surface);
    try std.testing.expectEqual(@as(usize, 1), surface.len);
    try std.testing.expectEqual(foo_id, surface[0]);
}
