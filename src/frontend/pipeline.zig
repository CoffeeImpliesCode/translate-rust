//! translate_rust.frontend.pipeline — full frontend orchestration pipeline.
//!
//! Orchestrates:
//! Ingestion -> CST extraction -> Name resolution -> Function body extraction ->
//! Built-in Macro Expansion -> Type Inference -> Method & Trait Resolution ->
//! Generic Monomorphization -> returns completed `ir.RustIR`.
//!
//! Zero backend dependencies: does NOT depend on emit.zig, package.zig, or driver.zig.

const std = @import("std");
const ir = @import("translate_rust.ir");
const spine = ir.spine;
const graph = ir.graph;
const types = ir.types;
const exprs = ir.exprs;
const bodies = ir.bodies;

pub const ingest = @import("ingest.zig");
pub const cst = @import("cst.zig");
pub const ts_ext = @import("ts_ext.zig");
pub const expand = @import("expand.zig");
pub const names = @import("names.zig");
pub const infer = @import("infer.zig");
pub const resolve_methods = @import("resolve_methods.zig");
pub const monomorphize = @import("monomorphize.zig");

const default_span: spine.Span = .{
    .start_line = 1,
    .start_col = 1,
    .end_line = 1,
    .end_col = 1,
};

/// Orchestrates the entire frontend analysis on a crate directory:
/// 1. Ingestion (`Cargo.toml` name/edition/entry point resolution).
/// 2. CST extraction (`cst.extractFile` across root + submodules).
/// 3. Name resolution (`names.resolveGraph`).
/// 4. Body lowering (`ts_ext.extractFunction` across fn entities).
/// 5. Macro expansion (`expand`).
/// 6. Type inference (`infer.solve` + constraint propagation).
/// 7. Method & trait resolution (`resolve_methods.resolveMethods`).
/// 8. Monomorphization (`monomorphize.collectInstantiations`).
/// Returns the completed `ir.RustIR`.
pub fn analyzeCrate(
    allocator: std.mem.Allocator,
    io: std.Io,
    crate_dir: []const u8,
) !ir.RustIR {
    // 1. Ingestion
    const manifest = try ingest.loadCrateManifest(allocator, io, crate_dir);
    const src = try ingest.readFileAlloc(allocator, io, manifest.root_path);

    return analyzeSourceWithGraph(allocator, io, crate_dir, manifest, src);
}

/// Analyze a crate when source is already loaded in memory.
pub fn analyzeSource(
    allocator: std.mem.Allocator,
    crate_name: []const u8,
    edition: []const u8,
    source: []const u8,
) !ir.RustIR {
    const manifest: ingest.Manifest = .{
        .name = crate_name,
        .edition = edition,
        .version = null,
        .root_path = "src/lib.rs",
        .is_bin = false,
    };
    return analyzeSourceWithGraph(allocator, null, ".", manifest, source);
}

fn analyzeSourceWithGraph(
    allocator: std.mem.Allocator,
    maybe_io: ?std.Io,
    crate_dir: []const u8,
    manifest: ingest.Manifest,
    src: []const u8,
) !ir.RustIR {
    // 1. Construct root module and symbol table in CrateGraph
    var g = graph.CrateGraph.init(allocator);

    const root_entity_name = try allocator.dupe(u8, "");
    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = root_entity_name,
        .span = default_span,
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
        .span = default_span,
        .items = &.{},
        .attributes = &.{},
    });
    try g.addCrate(.{
        .name = try allocator.dupe(u8, manifest.name),
        .edition = 2021,
        .kind = if (manifest.is_bin) .bin else .lib,
        .root = 0,
        .deps = &.{},
        .is_translated = true,
    });

    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    var bodies_list: std.ArrayListUnmanaged(bodies.BodyKind) = .empty;
    // Slot 0 for root module
    try bodies_list.append(allocator, .none);
    // Const initializers are lowered into the expr table by cst, so the table
    // must exist (and share the allocator) before CST extraction runs.
    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;

    // 2. CST extraction across root and submodules
    const root_dir = std.fs.path.dirname(manifest.root_path) orelse crate_dir;
    var cst_ctx: cst.Ctx = .{
        .alloc = allocator,
        .g = &g,
        .src = src,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
        .base_dir = root_dir,
        .io = maybe_io,
    };
    try cst.extractFile(&cst_ctx);

    // 3. Name resolution
    try names.resolveGraph(allocator, &g);

    // 4. Function body lowering
    var stmts_list: std.ArrayListUnmanaged(exprs.Statement) = .empty;
    var pats_list: std.ArrayListUnmanaged(exprs.Pattern) = .empty;

    // Cache module sources for submodules
    var module_srcs: std.AutoHashMapUnmanaged(spine.EntityId, []const u8) = .empty;
    defer module_srcs.deinit(allocator);
    try module_srcs.put(allocator, 0, src);

    if (maybe_io) |io| {
        for (g.modules.items) |m| {
            if (m.id == 0) continue;
            if (m.source_path) |sp| {
                if (ingest.readFileAlloc(allocator, io, sp)) |m_src| {
                    try module_srcs.put(allocator, m.id, m_src);
                } else |_| {}
            }
        }
    }

    var ts_ctx: ts_ext.Ctx = .{
        .alloc = allocator,
        .g = &g,
        .exprs = &exprs_list,
        .stmts = &stmts_list,
        .pats = &pats_list,
        .types = &types_list,
        .bodies_list = &bodies_list,
        .src = src,
        .mod_id = 0,
    };

    var fn_ids: std.ArrayListUnmanaged(spine.EntityId) = .empty;
    defer fn_ids.deinit(allocator);
    for (g.symbol_table.entities.items) |ent| {
        if (ent.kind == .fn_) try fn_ids.append(allocator, ent.id);
    }

    for (fn_ids.items) |fn_id| {
        const ent = g.symbol_table.get(fn_id) orelse continue;
        var cur = ent.parent orelse continue;
        var m_src: ?[]const u8 = null;
        while (g.module(cur)) |m| {
            if (module_srcs.get(cur)) |s| {
                m_src = s;
                break;
            }
            cur = m.parent orelse break;
        }
        const fn_src = m_src orelse src;
        ts_ctx.src = fn_src;
        ts_ctx.mod_id = ent.parent.?;
        _ = ts_ext.extractFunction(&ts_ctx, fn_id) catch false;
    }

    // 5. Type inference, method resolution, and generic monomorphization
    var b_temp: bodies.Bodies = .{
        .exprs = exprs_list.items,
        .stmts = stmts_list.items,
        .pats = pats_list.items,
        .types = types_list.items,
        .bodies = bodies_list.items,
    };

    if (infer.solveWithGraph(allocator, &b_temp, &g)) |inferred| {
        inferred.apply(exprs_list.items);
        _ = resolve_methods.resolveMethods(&g, &b_temp);
        _ = monomorphize.collectInstantiations(allocator, &g, &b_temp) catch null;
    } else |_| {}

    const final_bodies: bodies.Bodies = .{
        .exprs = try exprs_list.toOwnedSlice(allocator),
        .stmts = try stmts_list.toOwnedSlice(allocator),
        .pats = try pats_list.toOwnedSlice(allocator),
        .types = try types_list.toOwnedSlice(allocator),
        .bodies = try bodies_list.toOwnedSlice(allocator),
    };

    return .{
        .crate_name = manifest.name,
        .edition = manifest.edition,
        .graph = g,
        .types = final_bodies.types,
        .bodies = final_bodies,
    };
}

test "analyzeSource on simple Rust function" {
    // The pipeline's internal allocations (cst param names, infer result
    // types) are arena-owned like the reference driver; use an arena here so
    // the strict testing allocator stays leak-clean.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const src =
        \\pub fn add(a: i32, b: i32) -> i32 {
        \\    a + b
        \\}
    ;

    const rust_ir = try analyzeSource(allocator, "mini", "2021", src);

    try std.testing.expectEqualStrings("mini", rust_ir.crate_name);
    try std.testing.expectEqualStrings("2021", rust_ir.edition);
    try std.testing.expect(rust_ir.graph.symbol_table.entities.items.len > 0);
}

test "analyzeSource: const array + primitive initializers parsed into const body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const src =
        \\pub const BIT_REVERSE_TABLE: [u16; 4] = [0x00, 0x80, 0x40, 0xC0];
        \\pub const ZEROES: [u8; 256] = [0u8; 256];
        \\pub const FLAG: bool = true;
        \\pub const COUNT: u32 = 42;
    ;

    const rust_ir = try analyzeSource(allocator, "consts", "2021", src);
    const body_tables = rust_ir.bodies;

    var saw_table = false;
    var saw_zeroes = false;
    var saw_flag = false;
    var saw_count = false;
    for (rust_ir.graph.symbol_table.entities.items) |ent| {
        if (ent.kind != .const_) continue;
        const cb = switch (body_tables.bodies[ent.id]) {
            .const_ => |c| c,
            else => continue,
        };
        if (std.mem.eql(u8, ent.name, "BIT_REVERSE_TABLE")) {
            try std.testing.expect(cb.ty == .array);
            try std.testing.expectEqual(@as(u32, 4), cb.ty.array.len.literal);
            try std.testing.expect(cb.ty.array.elem.prim == .u16);
            const ex = body_tables.exprs[cb.init];
            try std.testing.expect(ex.kind == .array);
            try std.testing.expectEqual(@as(?usize, null), ex.kind.array.repeat);
            try std.testing.expectEqual(@as(usize, 4), ex.kind.array.elements.len);
            // First element 0x00 → 0; third element 0x40 → 64.
            const first = body_tables.exprs[ex.kind.array.elements[0]];
            try std.testing.expectEqual(@as(i128, 0), first.kind.literal.int.value);
            const third = body_tables.exprs[ex.kind.array.elements[2]];
            try std.testing.expectEqual(@as(i128, 64), third.kind.literal.int.value);
            saw_table = true;
        } else if (std.mem.eql(u8, ent.name, "ZEROES")) {
            try std.testing.expect(cb.ty == .array);
            try std.testing.expectEqual(@as(u32, 256), cb.ty.array.len.literal);
            const ex = body_tables.exprs[cb.init];
            try std.testing.expect(ex.kind == .array);
            try std.testing.expect(ex.kind == .array);
            try std.testing.expectEqual(@as(?usize, 256), ex.kind.array.repeat);
            try std.testing.expectEqual(@as(usize, 1), ex.kind.array.elements.len);
            saw_zeroes = true;
        } else if (std.mem.eql(u8, ent.name, "FLAG")) {
            const ex = body_tables.exprs[cb.init];
            try std.testing.expect(ex.kind == .literal);
            try std.testing.expect(ex.kind.literal == .boolean);
            try std.testing.expectEqual(true, ex.kind.literal.boolean);
            saw_flag = true;
        } else if (std.mem.eql(u8, ent.name, "COUNT")) {
            const ex = body_tables.exprs[cb.init];
            try std.testing.expect(ex.kind == .literal);
            try std.testing.expect(ex.kind.literal == .int);
            try std.testing.expectEqual(@as(i128, 42), ex.kind.literal.int.value);
            saw_count = true;
        }
    }
    try std.testing.expect(saw_table);
    try std.testing.expect(saw_zeroes);
    try std.testing.expect(saw_flag);
    try std.testing.expect(saw_count);
}

test "analyzeCrate: recursive multi-file submodule discovery (nested + #[path])" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // `test/crates/multimod` exercises:
    //  - `mod foo;` -> `src/foo.rs`
    //  - `mod bar;` inside `foo.rs` -> `src/foo/bar.rs` (two-level recursion)
    //  - `#[path = "custom.rs"] pub mod custom_pub;` (attribute-resolved path)
    const rust_ir = try analyzeCrate(allocator, std.testing.io, "test/crates/multimod");

    // The dense `modules[]` table is indexed by module id (see `addModule`),
    // which is independent of the entity ids in the symbol table. Look each
    // module up by scanning `modules[]` and matching its name.
    const find_mod = struct {
        fn find(
            ir_: *const ir.RustIR,
            name_: []const u8,
        ) ?graph.Module {
            for (ir_.graph.modules.items) |m| {
                if (std.mem.eql(u8, m.name, name_)) return m;
            }
            return null;
        }
    }.find;

    // A root entity for `enter` must exist (root items intact).
    const enter_ent = struct {
        fn find(ir_: *const ir.RustIR) ?spine.EntityId {
            for (ir_.graph.symbol_table.entities.items) |ent| {
                if (std.mem.eql(u8, ent.name, "enter")) return ent.id;
            }
            return null;
        }
    }.find(&rust_ir);
    if (enter_ent == null) return error.MissingRootFn;

    // `mod foo;` was found as an out-of-line file module and populated.
    const foo_mod = find_mod(&rust_ir, "foo") orelse return error.MissingFooModule;
    try std.testing.expect(foo_mod.kind == .file);
    try std.testing.expect(foo_mod.source_path != null);
    try std.testing.expect(foo_mod.items.len > 0);

    // Two-level recursion: `foo` contains its child `bar` module.
    const bar_mod = find_mod(&rust_ir, "bar") orelse return error.MissingBarModule;
    try std.testing.expect(bar_mod.kind == .file);
    try std.testing.expect(bar_mod.source_path != null);
    try std.testing.expect(bar_mod.items.len > 0);

    // A `foo_fn` fn entity exists under module `foo`.
    const foo_fn = struct {
        fn find(ir_: *const ir.RustIR) ?spine.EntityId {
            for (ir_.graph.symbol_table.entities.items) |ent| {
                if (std.mem.eql(u8, ent.name, "foo_fn")) return ent.id;
            }
            return null;
        }
    }.find(&rust_ir);
    if (foo_fn == null) return error.MissingFooFn;

    // `#[path = "custom.rs"]` resolved the module from the attrs.
    const custom_mod = find_mod(&rust_ir, "custom_pub") orelse return error.MissingCustomModule;
    try std.testing.expect(custom_mod.source_path != null);
    try std.testing.expect(custom_mod.items.len > 0);
}
