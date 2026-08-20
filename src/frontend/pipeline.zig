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

    var instantiation_table: monomorphize.InstantiationTable = .{};
    defer instantiation_table.deinit(allocator);
    if (infer.solveWithGraph(allocator, &b_temp, &g)) |inferred| {
        inferred.apply(exprs_list.items);
        _ = resolve_methods.resolveMethods(&g, &b_temp);
        instantiation_table = monomorphize.collectInstantiations(allocator, &g, &b_temp) catch .{};
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
        .instantiations = try instantiation_table.instantiations.toOwnedSlice(allocator),
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

test "analyzeSource resolves generic alias inherent method chain" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const src =
        \\pub struct Fletcher<T> { state: T }
        \\pub type Fletcher16 = Fletcher<u16>;
        \\impl Fletcher<u16> {
        \\    pub fn new() -> Fletcher<u16> {
        \\        Fletcher { state: 0u16 }
        \\    }
        \\}
        \\impl<T> Fletcher<T> {
        \\    pub fn update(self, state: T) -> Fletcher<T> {
        \\        Fletcher { state }
        \\    }
        \\    pub fn value(self) -> T {
        \\        self.state
        \\    }
        \\}
        \\pub fn calculate(input: u16) -> u16 {
        \\    Fletcher16::new().update(input + 1).value()
        \\}
    ;

    const rust_ir = try analyzeSource(allocator, "fletcher", "2021", src);

    var new_id: ?spine.EntityId = null;
    var update_id: ?spine.EntityId = null;
    var value_id: ?spine.EntityId = null;
    for (rust_ir.graph.symbol_table.entities.items) |entity| {
        if (entity.kind != .fn_) continue;
        if (std.mem.eql(u8, entity.name, "new")) {
            new_id = entity.id;
        } else if (std.mem.eql(u8, entity.name, "update")) {
            update_id = entity.id;
        } else if (std.mem.eql(u8, entity.name, "value")) {
            value_id = entity.id;
        }
    }
    try std.testing.expect(new_id != null);
    try std.testing.expect(update_id != null);
    try std.testing.expect(value_id != null);

    var saw_new = false;
    var saw_update = false;
    var saw_value = false;
    var saw_primitive_add = false;
    for (rust_ir.bodies.exprs) |expression| {
        try std.testing.expect(expression.kind != .unsupported);
        switch (expression.kind) {
            .call => |call| switch (call.call_kind) {
                .associated => |target| {
                    try std.testing.expectEqual(new_id.?, target);
                    saw_new = true;
                },
                else => {},
            },
            .method_call => |method_call| {
                const target = rust_ir.graph.symbol_table.get(method_call.method) orelse
                    return error.TestUnexpectedResult;
                try std.testing.expect(target.kind == .fn_);
                if (target.id == update_id.?) {
                    saw_update = true;
                } else if (target.id == value_id.?) {
                    saw_value = true;
                } else {
                    return error.TestUnexpectedResult;
                }
            },
            .binary => |binary| {
                try std.testing.expect(binary.op == .add);
                saw_primitive_add = true;
            },
            else => {},
        }
    }

    try std.testing.expect(saw_new);
    try std.testing.expect(saw_update);
    try std.testing.expect(saw_value);
    try std.testing.expect(saw_primitive_add);
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

test "analyzeSource: pre-P4 declarations and body graph stay lossless" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const src =
        \\mod state {
        \\    pub struct State(pub u8);
        \\
        \\    pub trait Inspect {
        \\        fn value(&self) -> u8;
        \\    }
        \\
        \\    pub fn initial() -> State {
        \\        State(1)
        \\    }
        \\}
        \\
        \\pub use state::State;
        \\
        \\#[cfg(test)]
        \\mod tests {
        \\    use super::State;
        \\
        \\    #[test]
        \\    fn state_body_is_lossless() {
        \\        let mut value = 7;
        \\        let State(inner) = State(value);
        \\        value = if true { inner } else { 3 };
        \\    }
        \\}
    ;

    const rust_ir = try analyzeSource(allocator, "pre_p4", "2021", src);
    const helpers = struct {
        fn findEntity(
            rust_ir_: *const ir.RustIR,
            kind: spine.EntityKind,
            name: []const u8,
        ) ?spine.Entity {
            for (rust_ir_.graph.symbol_table.entities.items) |entity| {
                if (entity.kind != kind) continue;
                if (std.mem.eql(u8, entity.name, name)) return entity;
            }
            return null;
        }

        fn findModule(rust_ir_: *const ir.RustIR, name: []const u8) ?graph.Module {
            for (rust_ir_.graph.modules.items) |module| {
                if (std.mem.eql(u8, module.name, name)) return module;
            }
            return null;
        }

        fn hasAttribute(
            attributes: []const spine.Attribute,
            name: []const u8,
            meta_fragment: []const u8,
        ) bool {
            for (attributes) |attribute| {
                if (!std.mem.eql(u8, attribute.name, name)) continue;
                if (meta_fragment.len == 0) return true;
                if (std.mem.indexOf(u8, attribute.meta, meta_fragment) != null) return true;
            }
            return false;
        }
    };

    const state_module = helpers.findEntity(&rust_ir, .module, "state");
    try std.testing.expect(state_module != null);
    const state_module_entity = state_module.?;
    try std.testing.expect(state_module_entity.visibility == .private);
    try std.testing.expectEqual(@as(?spine.EntityId, 0), state_module_entity.parent);

    const state_entity = helpers.findEntity(&rust_ir, .struct_, "State");
    try std.testing.expect(state_entity != null);
    const state = state_entity.?;
    try std.testing.expect(state.visibility == .public);
    try std.testing.expectEqual(@as(?spine.EntityId, state_module_entity.id), state.parent);
    try std.testing.expect(state.id < rust_ir.bodies.bodies.len);
    try std.testing.expect(rust_ir.bodies.bodies[state.id] == .struct_);
    const state_body = rust_ir.bodies.bodies[state.id].struct_;
    try std.testing.expect(state_body.layout == .tuple);
    try std.testing.expectEqual(@as(usize, 1), state_body.fields.len);
    try std.testing.expectEqualStrings("0", state_body.fields[0].name);
    try std.testing.expect(state_body.fields[0].ty == .prim);
    try std.testing.expect(state_body.fields[0].ty.prim == .u8);

    const inspect_entity = helpers.findEntity(&rust_ir, .trait_, "Inspect");
    try std.testing.expect(inspect_entity != null);
    const inspect = inspect_entity.?;
    try std.testing.expect(inspect.visibility == .public);
    try std.testing.expectEqual(@as(?spine.EntityId, state_module_entity.id), inspect.parent);
    try std.testing.expect(inspect.id < rust_ir.bodies.bodies.len);
    try std.testing.expect(rust_ir.bodies.bodies[inspect.id] == .trait_);
    const inspect_body = rust_ir.bodies.bodies[inspect.id].trait_;
    try std.testing.expectEqual(@as(usize, 1), inspect_body.methods.len);
    try std.testing.expectEqualStrings("value", inspect_body.methods[0].name);
    try std.testing.expect(inspect_body.methods[0].receiver == .ref_);
    try std.testing.expect(inspect_body.methods[0].ret == .prim);
    try std.testing.expect(inspect_body.methods[0].ret.prim == .u8);

    const initial_entity = helpers.findEntity(&rust_ir, .fn_, "initial");
    try std.testing.expect(initial_entity != null);
    const initial = initial_entity.?;
    try std.testing.expect(initial.visibility == .public);
    try std.testing.expectEqual(@as(?spine.EntityId, state_module_entity.id), initial.parent);
    try std.testing.expect(initial.id < rust_ir.bodies.bodies.len);
    try std.testing.expect(rust_ir.bodies.bodies[initial.id] == .fn_);

    var state_reexport: ?graph.UseDecl = null;
    for (rust_ir.graph.uses.items) |use_decl| {
        if (!use_decl.is_pub_export) continue;
        if (!std.mem.eql(u8, use_decl.local_name, "State")) continue;
        state_reexport = use_decl;
        break;
    }
    try std.testing.expect(state_reexport != null);
    const reexport = state_reexport.?;
    try std.testing.expectEqual(state.id, reexport.target);
    try std.testing.expect(reexport.kind == .plain);
    try std.testing.expectEqual(state.id, reexport.kind.plain);
    const reexport_entity = rust_ir.graph.symbol_table.get(reexport.id);
    try std.testing.expect(reexport_entity != null);
    try std.testing.expect(reexport_entity.?.visibility == .public);
    try std.testing.expectEqual(@as(?spine.EntityId, 0), reexport_entity.?.parent);

    const tests_module = helpers.findEntity(&rust_ir, .module, "tests");
    try std.testing.expect(tests_module != null);
    const tests_module_entity = tests_module.?;
    try std.testing.expect(tests_module_entity.visibility == .private);
    try std.testing.expect(helpers.hasAttribute(
        tests_module_entity.attributes,
        "cfg",
        "test",
    ));
    const tests_module_row = helpers.findModule(&rust_ir, "tests");
    try std.testing.expect(tests_module_row != null);
    try std.testing.expect(helpers.hasAttribute(
        tests_module_row.?.attributes,
        "cfg",
        "test",
    ));

    const test_entity = helpers.findEntity(&rust_ir, .fn_, "state_body_is_lossless");
    try std.testing.expect(test_entity != null);
    const test_fn = test_entity.?;
    try std.testing.expect(test_fn.visibility == .private);
    try std.testing.expectEqual(@as(?spine.EntityId, tests_module_entity.id), test_fn.parent);
    try std.testing.expect(helpers.hasAttribute(test_fn.attributes, "test", ""));
    try std.testing.expect(test_fn.id < rust_ir.bodies.bodies.len);
    try std.testing.expect(rust_ir.bodies.bodies[test_fn.id] == .fn_);

    const test_body = rust_ir.bodies.bodies[test_fn.id].fn_;
    try std.testing.expect(test_body.body < rust_ir.bodies.exprs.len);
    const body_expression = rust_ir.bodies.exprs[test_body.body];
    try std.testing.expect(body_expression.kind == .block);
    const body_block = body_expression.kind.block;
    try std.testing.expectEqual(@as(usize, 3), body_block.statements.len);
    try std.testing.expect(body_block.tail == null);

    const mutable_statement = rust_ir.bodies.stmts[body_block.statements[0]];
    try std.testing.expect(mutable_statement.kind == .let);
    const mutable_let = mutable_statement.kind.let;
    const mutable_pattern = rust_ir.bodies.pats[mutable_let.pattern];
    try std.testing.expect(mutable_pattern.kind == .binding);
    try std.testing.expectEqualStrings("value", mutable_pattern.kind.binding.name);
    try std.testing.expect(mutable_pattern.kind.binding.mutable);
    try std.testing.expect(mutable_let.init != null);
    const seven = rust_ir.bodies.exprs[mutable_let.init.?];
    try std.testing.expect(seven.kind == .literal);
    try std.testing.expect(seven.kind.literal == .int);
    try std.testing.expectEqual(@as(i128, 7), seven.kind.literal.int.value);

    const destructure_statement = rust_ir.bodies.stmts[body_block.statements[1]];
    try std.testing.expect(destructure_statement.kind == .let);
    const destructure_let = destructure_statement.kind.let;
    const destructure_pattern = rust_ir.bodies.pats[destructure_let.pattern];
    try std.testing.expect(destructure_pattern.kind == .struct_pat);
    const tuple_pattern = destructure_pattern.kind.struct_pat;
    try std.testing.expectEqual(state.id, tuple_pattern.def);
    try std.testing.expectEqual(@as(usize, 1), tuple_pattern.fields.len);
    try std.testing.expectEqualStrings("0", tuple_pattern.fields[0].field);
    try std.testing.expect(tuple_pattern.fields[0].pat != null);
    const inner_pattern = rust_ir.bodies.pats[tuple_pattern.fields[0].pat.?];
    try std.testing.expect(inner_pattern.kind == .binding);
    try std.testing.expectEqualStrings("inner", inner_pattern.kind.binding.name);
    try std.testing.expect(!inner_pattern.kind.binding.mutable);

    try std.testing.expect(destructure_let.init != null);
    const constructor = rust_ir.bodies.exprs[destructure_let.init.?];
    try std.testing.expect(constructor.kind == .call);
    try std.testing.expect(constructor.kind.call.call_kind == .constructor);
    try std.testing.expectEqual(state.id, constructor.kind.call.call_kind.constructor);
    try std.testing.expectEqual(@as(usize, 1), constructor.kind.call.args.len);
    const constructor_arg = rust_ir.bodies.exprs[constructor.kind.call.args[0]];
    try std.testing.expect(constructor_arg.kind == .path);

    const assignment_statement = rust_ir.bodies.stmts[body_block.statements[2]];
    try std.testing.expect(assignment_statement.kind == .expr);
    const assignment = rust_ir.bodies.exprs[assignment_statement.kind.expr];
    try std.testing.expect(assignment.kind == .assign);
    try std.testing.expect(assignment.kind.assign.op == .plain);
    try std.testing.expect(rust_ir.bodies.exprs[assignment.kind.assign.target].kind == .path);
    const conditional = rust_ir.bodies.exprs[assignment.kind.assign.value];
    try std.testing.expect(conditional.kind == .if_else);
    const if_else = conditional.kind.if_else;
    const condition = rust_ir.bodies.exprs[if_else.cond];
    try std.testing.expect(condition.kind == .literal);
    try std.testing.expect(condition.kind.literal == .boolean);
    try std.testing.expect(condition.kind.literal.boolean);
    try std.testing.expect(if_else.then_.tail != null);
    try std.testing.expectEqual(@as(usize, 0), if_else.then_.statements.len);
    try std.testing.expect(rust_ir.bodies.exprs[if_else.then_.tail.?].kind == .path);
    try std.testing.expect(if_else.@"else" == .block);
    const else_block = if_else.@"else".block;
    try std.testing.expect(else_block.tail != null);
    try std.testing.expectEqual(@as(usize, 0), else_block.statements.len);
    const three = rust_ir.bodies.exprs[else_block.tail.?];
    try std.testing.expect(three.kind == .literal);
    try std.testing.expect(three.kind.literal == .int);
    try std.testing.expectEqual(@as(i128, 3), three.kind.literal.int.value);

    const body_expression_ids = [_]exprs.NodeId{
        test_body.body,
        mutable_let.init.?,
        destructure_let.init.?,
        constructor.kind.call.args[0],
        assignment_statement.kind.expr,
        assignment.kind.assign.target,
        assignment.kind.assign.value,
        if_else.cond,
        if_else.then_.tail.?,
        else_block.tail.?,
    };
    for (body_expression_ids) |expression_id| {
        try std.testing.expect(expression_id < rust_ir.bodies.exprs.len);
        try std.testing.expect(rust_ir.bodies.exprs[expression_id].kind != .unsupported);
    }
}
