//! translate_rust.emit_hex_test — P3 golden-file test for body emission.
//!
//! Builds a full hex model in memory (CrateGraph + Bodies), calls
//! `emitRich`, and compares the output against the golden file
//! `test/r2z-hex.zig`.
//!
//! The hex subset proves the emitter's slice-handling (a `for (bytes) |byte|`
//! loop over a `[]const u8` param) and string-emission (`var out` initialized
//! from a string literal) paths. The in-memory model uses only expression
//! kinds the v1 emitter lowers for real: `let`, `for` over a slice, `assign`,
//! `return`, path, and string literal.

const std = @import("std");
const spine = @import("spine.zig");
const graph = @import("graph.zig");
const items = @import("items.zig");
const types = @import("types.zig");
const exprs = @import("exprs.zig");
const emit = @import("emit.zig");

// ---------------------------------------------------------------------------
// Model wrapper (CrateGraph + Bodies, deinit-safe)
// ---------------------------------------------------------------------------

const Model = struct {
    g: graph.CrateGraph,
    bodies: emit.Bodies,
    /// Backing store for types — kept so deinit can free inner pointers.
    types_store: []types.Type,

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        // Free heap-allocated pointers inside Type unions (Slice, etc.)
        for (self.types_store) |t| {
            switch (t) {
                .slice => |s| allocator.destroy(@constCast(s)),
                .reference => |r| allocator.destroy(@constCast(r)),
                .raw_ptr => |p| allocator.destroy(@constCast(p)),
                .array => |a| allocator.destroy(@constCast(a)),
                .fn_ptr => |f| allocator.destroy(@constCast(f)),
                .option => |o| allocator.destroy(@constCast(o)),
                .result => |r| allocator.destroy(@constCast(r)),
                .boxed => |b| allocator.destroy(@constCast(b)),
                else => {},
            }
        }
        allocator.free(self.types_store);
        allocator.free(self.bodies.pats);
        allocator.free(self.bodies.stmts);
        allocator.free(self.bodies.exprs);
        for (self.bodies.bodies) |bk| {
            switch (bk) {
                .fn_ => |fb| allocator.free(fb.params),
                else => {},
            }
        }
        allocator.free(self.bodies.bodies);
        self.g.deinit();
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// hex model construction
//
// Entity IDs (symbol_table, dense 0..4):
//   0 = root module
//   1 = encode (fn)
//   2 = bytes (parameter, not a module item)
//   3 = out (local variable)
//   4 = byte (for-loop binding)
//
// Module 0 items: [1] — only the top-level declaration.
//
// Types table:
//   0 = []const u8
//
// Exprs table:
//   0  = string literal ""
//   1  = PathExpr(def=3) — out
//   2  = PathExpr(def=2) — bytes
//   3  = AssignExpr(target=1, op=plain, value=2)   — out = bytes
//   4  = PathExpr(def=2) — bytes                   — for iterable
//   5  = BlockExpr{stmts=[2], tail=null}           — for body
//   6  = ForExpr(pat=1, iterable=4, body=5)        — for (bytes) |byte|
//   7  = PathExpr(def=3) — out                     — return value
//   8  = ReturnExpr(value=7)                       — return out
//   9  = BlockExpr{stmts=[0,1], tail=8}            — fn body
//
// Stmts table:
//   0 = LetStmt{pat=0, init=0, ty=0}   — var out: []const u8 = ""
//   1 = ExprStmt(expr=6)               — for loop
//   2 = ExprStmt(expr=3)               — out = bytes (for body)
//
// Pats table:
//   0 = Binding{name="out", mutable=true}
//   1 = Binding{name="byte", mutable=false}
// ---------------------------------------------------------------------------

fn buildHexModel(allocator: std.mem.Allocator) !*Model {
    const m = try allocator.create(Model);
    errdefer allocator.destroy(m);

    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    // ── CrateGraph ──────────────────────────────────────────────────────
    var g = graph.CrateGraph.init(allocator);
    errdefer g.deinit();

    // Root module entity in the symbol table (id 0).
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

    // Root module in the modules table (also id 0).
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

    // Entity 1 — encode fn (public).
    const encode_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "encode"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Entity 2 — bytes parameter (kind=.field; path target only).
    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try allocator.dupe(u8, "bytes"),
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Entity 3 — out local variable.
    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try allocator.dupe(u8, "out"),
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Entity 4 — byte for-loop binding.
    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try allocator.dupe(u8, "byte"),
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Wire module items: [encode].
    const items_slice = try allocator.alloc(spine.EntityId, 1);
    items_slice[0] = encode_id;
    g.modules.items[root_id].items = items_slice;

    try g.addCrate(.{
        .name = try allocator.dupe(u8, "hex"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    // ── Types table ─────────────────────────────────────────────────────
    // 0 = []const u8

    const slice_ptr = try allocator.create(types.Slice);
    slice_ptr.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const byte_slice_type: types.Type = .{ .slice = slice_ptr };

    const types_store = try allocator.alloc(types.Type, 1);
    types_store[0] = byte_slice_type;

    // ── Params (for encode) ─────────────────────────────────────────────
    const params = try allocator.alloc(items.Param, 1);
    params[0] = .{
        .name = "bytes",
        .ty = byte_slice_type,
        .span = span,
    };

    // ── Pats table ──────────────────────────────────────────────────────
    // 0 = out (mutable), 1 = byte (immutable)

    const pats_store = try allocator.alloc(exprs.Pattern, 2);
    pats_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .binding = .{
            .name = "out",
            .mode = .{ .value = {} },
            .mutable = true,
        } },
    };
    pats_store[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .wildcard = {} },
    };

    // ── Exprs table ─────────────────────────────────────────────────────

    const exprs_store = try allocator.alloc(exprs.Expr, 10);

    // 0: string literal ""
    exprs_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .literal = .{ .string = .{ .bytes = "" } } },
    };

    // 1: PathExpr → out (entity 3)
    exprs_store[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .path = .{ .def = 3, .generic_args = &.{} } },
    };

    // 2: PathExpr → bytes (entity 2)
    exprs_store[2] = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{ .path = .{ .def = 2, .generic_args = &.{} } },
    };

    // 3: AssignExpr: out = bytes
    exprs_store[3] = .{
        .id = 3,
        .span = span,
        .ty = null,
        .kind = .{
            .assign = .{
                .target = 1, // out
                .op = .plain,
                .value = 2, // bytes
                .overflow = .checked,
            },
        },
    };

    // 4: PathExpr → bytes (for iterable)
    exprs_store[4] = .{
        .id = 4,
        .span = span,
        .ty = null,
        .kind = .{ .path = .{ .def = 2, .generic_args = &.{} } },
    };

    // 5: BlockExpr — for body { out = bytes; }
    exprs_store[5] = .{
        .id = 5,
        .span = span,
        .ty = null,
        .kind = .{
            .block = .{
                .statements = &.{2}, // stmt index 2
                .tail = null,
                .labelled = null,
            },
        },
    };

    // 6: ForExpr — for (bytes) |byte| { ... }
    exprs_store[6] = .{
        .id = 6,
        .span = span,
        .ty = null,
        .kind = .{
            .for_ = .{
                .pattern = 1, // byte binding pat
                .iterable = 4, // bytes path expr
                .body = exprs_store[5].kind.block,
                .iter_kind = .{ .slice = {} },
            },
        },
    };

    // 7: PathExpr → out (return value)
    exprs_store[7] = .{
        .id = 7,
        .span = span,
        .ty = null,
        .kind = .{ .path = .{ .def = 3, .generic_args = &.{} } },
    };

    // 8: ReturnExpr — return out
    exprs_store[8] = .{
        .id = 8,
        .span = span,
        .ty = null,
        .kind = .{ .return_ = .{ .value = 7 } },
    };

    // 9: BlockExpr — fn body { var out: []const u8 = ""; for ...; return out; }
    exprs_store[9] = .{
        .id = 9,
        .span = span,
        .ty = null,
        .kind = .{
            .block = .{
                .statements = &.{ 0, 1 }, // stmt indices 0 (let_out), 1 (for_stmt)
                .tail = 8, // return_out
                .labelled = null,
            },
        },
    };

    // ── Stmts table ─────────────────────────────────────────────────────

    const stmts_store = try allocator.alloc(exprs.Statement, 3);

    // 0: LetStmt — var out: []const u8 = ""
    stmts_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{
            .let = .{
                .pattern = 0, // out binding
                .init = 0, // string literal ""
                .ty = 0, // TypeId 0 = []const u8
            },
        },
    };

    // 1: ExprStmt — for loop (fn body)
    stmts_store[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .expr = 6 }, // for_expr
    };

    // 2: ExprStmt — out = bytes (for body)
    stmts_store[2] = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{ .expr = 3 }, // assign_out
    };

    // ── Bodies (indexed by EntityId) ────────────────────────────────────

    const bodies_arr = try allocator.alloc(emit.BodyKind, 5);
    bodies_arr[0] = .none; // root module
    bodies_arr[1] = .{
        .fn_ = .{
            .params = params,
            .ret = byte_slice_type,
            .body = 9, // fn body block expr
        },
    };
    bodies_arr[2] = .none; // bytes
    bodies_arr[3] = .none; // out
    bodies_arr[4] = .none; // byte

    m.* = .{
        .g = g,
        .bodies = .{
            .exprs = exprs_store,
            .stmts = stmts_store,
            .pats = pats_store,
            .types = types_store,
            .bodies = bodies_arr,
        },
        .types_store = types_store,
    };

    return m;
}

// ---------------------------------------------------------------------------
// Helpers for golden comparison
// ---------------------------------------------------------------------------

fn readFixture(allocator: std.mem.Allocator, test_io: std.Io, path: []const u8) ![]const u8 {
    var io_buf: [4096]u8 = undefined;
    var dir = std.Io.Dir.cwd();
    const file = try dir.openFile(test_io, path, .{});
    defer file.close(test_io);
    var reader = file.reader(test_io, &io_buf);
    return reader.interface.allocRemaining(allocator, .limited(1 << 20));
}

fn normalize(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= raw.len) {
        if (i == raw.len or raw[i] == '\n') {
            var end = i;
            while (end > line_start) {
                const c = raw[end - 1];
                if (c == ' ' or c == '\t' or c == '\r') {
                    end -= 1;
                } else break;
            }
            try out.appendSlice(allocator, raw[line_start..end]);
            try out.append(allocator, '\n');
            line_start = i + 1;
        }
        i += 1;
    }

    while (out.items.len >= 2 and out.items[out.items.len - 2] == '\n') {
        _ = out.pop();
    }
    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') {
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

/// Extract the item declarations from the golden file (everything from the
/// first `pub fn encode` up to the first test block).
fn extractCore(allocator: std.mem.Allocator, golden: []const u8) ![]const u8 {
    const start_marker = "pub fn encode";
    const test_marker = "\ntest \"";

    const start_idx = std.mem.indexOf(u8, golden, start_marker) orelse return error.CoreNotFound;
    const after_start = golden[start_idx..];
    const test_idx = std.mem.indexOf(u8, after_start, test_marker);

    if (test_idx) |ti| {
        return allocator.dupe(u8, after_start[0..ti]);
    } else {
        // No test blocks — use entire golden from start_marker.
        return allocator.dupe(u8, after_start);
    }
}

// ---------------------------------------------------------------------------
// P3 golden-file test: body-aware emission
// ---------------------------------------------------------------------------

test "emit hex with body golden" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;

    // 1) Load and normalize the golden file.
    const golden_raw = try readFixture(allocator, test_io, "test/r2z-hex.zig");
    defer allocator.free(golden_raw);
    const golden_norm = try normalize(allocator, golden_raw);
    defer allocator.free(golden_norm);

    // 2) Extract the core (items + fn body, no file header / tests).
    const core_raw = try extractCore(allocator, golden_norm);
    defer allocator.free(core_raw);
    const core = try normalize(allocator, core_raw);
    defer allocator.free(core);

    // 3) Build the in-memory hex model with bodies.
    var model = try buildHexModel(allocator);
    defer allocator.destroy(model);
    defer model.deinit(allocator);

    // 4) Emit with body lowering.
    const out = try emit.emitRich(allocator, &model.g, &model.bodies);
    defer allocator.free(out);
    const out_norm = try normalize(allocator, out);
    defer allocator.free(out_norm);

    // 5) Compare.  The core is the item-level portion of the golden file;
    //    emit output is exactly the item-level output (no file header, no tests).
    try std.testing.expectEqualStrings(core, out_norm);
}
