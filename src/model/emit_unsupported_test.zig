//! translate_rust.emit_unsupported_test — P2: `.unsupported` expression nodes
//! must render as VALID, compilable Zig in fn bodies (`if (true) @panic(...)`)
//! and as `undefined` + a loud comment in comptime const initializers (never
//! `@panic`, which is a compile error at comptime).
//! C-free on purpose: imports only the model modules (no tree-sitter), so it
//! runs under `zig build test` exactly like emit_fnv_test.zig.

const std = @import("std");
const spine = @import("spine.zig");
const graph = @import("graph.zig");
const types = @import("types.zig");
const exprs = @import("exprs.zig");
const emit = @import("emit.zig");

const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

/// Minimal model.
///
/// Entities (dense symbol-table ids):
///   0 = root module
///   1 = tail_fn   — fn whose block TAIL is an unsupported expr (value pos)
///   2 = stmt_fn   — fn whose block contains an unsupported expr STATEMENT
///   3 = broken_const — const whose INIT is an unsupported expr (comptime)
///
/// Exprs:
///   0 = unsupported{ reason = `he said "hi" \ back` }  (runtime; escaping)
///   1 = unsupported{ reason = "unresolved identifier" } (comptime const init)
///   2 = BlockExpr{ stmts=[], tail=0 }        — tail_fn body
///   3 = BlockExpr{ stmts=[0], tail=null }    — stmt_fn body (stmt 0 = expr 0)
///
/// Stmts:
///   0 = ExprStmt(expr = 0)
const Model = struct {
    g: graph.CrateGraph,
    bodies: emit.Bodies,

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        allocator.free(self.bodies.exprs);
        allocator.free(self.bodies.stmts);
        allocator.free(self.bodies.types);
        allocator.free(self.bodies.bodies);
        self.g.deinit();
    }
};

fn buildModel(allocator: std.mem.Allocator) !*Model {
    const m = try allocator.create(Model);
    errdefer allocator.destroy(m);

    var g = graph.CrateGraph.init(allocator);
    errdefer g.deinit();

    // Entity 0 — root module.
    _ = try g.symbol_table.add(.{
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
    const root_id = try g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = try allocator.dupe(u8, ""),
        .parent = null,
        .source_path = try allocator.dupe(u8, "src/lib.rs"),
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });

    // Entity 1 — tail_fn (value-position unsupported tail).
    const tail_fn_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "tail_fn"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    // Entity 2 — stmt_fn (statement-position unsupported).
    const stmt_fn_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "stmt_fn"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    // Entity 3 — broken_const (comptime unsupported init).
    const const_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .const_,
        .name = try allocator.dupe(u8, "broken_const"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const items_slice = try allocator.alloc(spine.EntityId, 3);
    items_slice[0] = tail_fn_id;
    items_slice[1] = stmt_fn_id;
    items_slice[2] = const_id;
    g.modules.items[root_id].items = items_slice;

    try g.addCrate(.{
        .name = try allocator.dupe(u8, "unsup"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    // Types: 0 = u64, 1 = unit (void).
    const types_store = try allocator.alloc(types.Type, 2);
    types_store[0] = .{ .prim = .u64 };
    types_store[1] = .{ .prim = .unit };

    // Exprs.
    const exprs_store = try allocator.alloc(exprs.Expr, 4);
    exprs_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .unsupported = .{
            .reason = "he said \"hi\" \\ back",
            .suggested_version = .v2,
        } },
    };
    exprs_store[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .unsupported = .{
            .reason = "unresolved identifier",
            .suggested_version = .v2,
        } },
    };
    exprs_store[2] = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{ .statements = &.{}, .tail = 0, .labelled = null } },
    };
    exprs_store[3] = .{
        .id = 3,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{ .statements = &.{0}, .tail = null, .labelled = null } },
    };

    // Stmts: 0 = ExprStmt(expr 0).
    const stmts_store = try allocator.alloc(exprs.Statement, 1);
    stmts_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .expr = 0 },
    };

    // Bodies indexed by entity id.
    const bodies_arr = try allocator.alloc(emit.BodyKind, 4);
    bodies_arr[0] = .none; // root module
    bodies_arr[1] = .{ .fn_ = .{ .params = &.{}, .ret = types_store[1], .body = 2 } };
    bodies_arr[2] = .{ .fn_ = .{ .params = &.{}, .ret = types_store[1], .body = 3 } };
    bodies_arr[3] = .{ .const_ = .{ .ty = types_store[0], .init = 1 } };

    m.* = .{
        .g = g,
        .bodies = .{
            .exprs = exprs_store,
            .stmts = stmts_store,
            .pats = &.{},
            .types = types_store,
            .bodies = bodies_arr,
        },
    };
    return m;
}

/// Assert `text` is syntactically valid Zig (std.zig.Ast.parse accepts it).
fn expectValidZig(allocator: std.mem.Allocator, text: []const u8) !void {
    const src_z = try allocator.dupeZ(u8, text);
    defer allocator.free(src_z);
    var tree = try std.zig.Ast.parse(allocator, src_z, .zig);
    defer tree.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
}

// Runtime fn-body `.unsupported` → `if (true) @panic("translate-rust: unsupported: <reason>")`,
// escaping embedded quotes and backslashes; every occurrence keeps valid `;`
// syntax — no bare `= ;` and no bare `@panic` unreachable code issues.
test "unsupported expr in fn body emits runtime if (true) @panic with escaped reason" {
    const allocator = std.testing.allocator;
    var model = try buildModel(allocator);
    defer allocator.destroy(model);
    defer model.deinit(allocator);

    const out = try emit.emitRich(allocator, &model.g, &model.bodies);
    defer allocator.free(out);

    // Value-position tail (tail_fn) and statement position (stmt_fn): both
    // carry the full escaped panic prefix wrapped in `if (true)`.
    try std.testing.expect(std.mem.indexOf(u8, out, "if (true) @panic(\"translate-rust: unsupported: ") != null);
    // Quotes and backslashes are escaped so the reason is a valid Zig
    // string-literal body (emitted `\"` and `\\`).
    try std.testing.expect(std.mem.indexOf(u8, out, "he said \\\"hi\\\" \\\\ back") != null);
    // A statement-position panic still ends with `");` (needs_semi preserved).
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\\ back\")") != null);

    // No broken construct anywhere: nothing like `= ;` or `= /* ... */ ;`.
    try std.testing.expect(std.mem.indexOf(u8, out, "= ;") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "= /* unsupported expr */ ;") == null);

    // The whole emission is syntactically valid Zig.
    try expectValidZig(allocator, out);
}
// Comptime const-init `.unsupported` → `undefined` + loud comment, NEVER
// `@panic` (a comptime panic is a compile error).
test "unsupported expr in const init emits undefined + comment, never @panic" {
    const allocator = std.testing.allocator;
    var model = try buildModel(allocator);
    defer allocator.destroy(model);
    defer model.deinit(allocator);

    const out = try emit.emitRich(allocator, &model.g, &model.bodies);
    defer allocator.free(out);

    // The comptime init lowers to a loud comment + bare `undefined` (coerces
    // to the declared u64).
    const start = std.mem.indexOf(u8, out, "const broken_const").?;
    const rest = out[start..];
    const semi = std.mem.indexOf(u8, rest, ";").?;

    try std.testing.expect(std.mem.indexOf(u8, rest[0..semi], "// translate-rust: unsupported unresolved identifier") != null);
    try std.testing.expect(std.mem.endsWith(u8, rest[0..semi], "undefined"));
    // No @panic in the const-init region (comptime hazard).
    try std.testing.expect(std.mem.indexOf(u8, rest[0..semi], "@panic") == null);

    // Overall output still parses as valid Zig.
    try expectValidZig(allocator, out);
}
