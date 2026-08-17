//! translate_rust.emit_fnv_test — P3 golden-file test for body emission.
//!
//! Builds a full fnv model in memory (CrateGraph + Bodies), calls
//! `emitRich`, and compares the output against the golden file
//! `test/r2z-fnv.zig`.

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
// fnv model construction
//
// Entity IDs (symbol_table, dense 0..6):
//   0 = root module
//   1 = FNV_OFFSET_BASIS (const)
//   2 = FNV_PRIME (const)
//   3 = fnv1a_hash (fn)
//   4 = data (parameter, not a module item)
//   5 = h (local variable)
//   6 = byte (for-loop binding)
//
// Module 0 items: [1, 2, 3] — only the top-level declarations.
//
// Types table:
//   0 = u64
//   1 = []const u8
//
// Exprs table:
//   0  = int literal "14695981039346656037"
//   1  = int literal "1099511628211"
//   2  = PathExpr(def=1) — FNV_OFFSET_BASIS
//   3  = PathExpr(def=2) — FNV_PRIME
//   4  = PathExpr(def=4) — data
//   5  = PathExpr(def=5) — h
//   6  = PathExpr(def=6) — byte
//   7  = AssignExpr(target=5, op=bit_xor, value=6)    — h ^= byte
//   8  = AssignExpr(target=5, op=mul, value=3, wrap)   — h *%= FNV_PRIME
//   9  = BlockExpr{stmts=[1,2], tail=null}              — for body
//  10  = ForExpr(pat=1, iterable=4, body=9)             — for byte in data
//  11  = ReturnExpr(value=5)                             — return h
//  12  = BlockExpr{stmts=[0,3], tail=11}                — fn body
//
// Stmts table:
//   0 = LetStmt{pat=0, init=2, ty=0}    — var h: u64 = FNV_OFFSET_BASIS
//   1 = ExprStmt(expr=7)                 — h ^= byte
//   2 = ExprStmt(expr=8)                 — h *%= FNV_PRIME
//   3 = ExprStmt(expr=10)                — for loop
//
// Pats table:
//   0 = Binding{name="h",  mutable=true}
//   1 = Binding{name="byte", mutable=false}
// ---------------------------------------------------------------------------

fn buildFnvModel(allocator: std.mem.Allocator) !*Model {
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

    // Entity 1 — FNV_OFFSET_BASIS const (public for golden match)
    const basis_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .const_,
        .name = try allocator.dupe(u8, "FNV_OFFSET_BASIS"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Entity 2 — FNV_PRIME const
    const prime_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .const_,
        .name = try allocator.dupe(u8, "FNV_PRIME"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Entity 3 — fnv1a_hash fn (public)
    const hash_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "fnv1a_hash"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Entity 4 — data parameter (kind=.field; not a module item, just a path target)
    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try allocator.dupe(u8, "data"),
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Entity 5 — h local variable
    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try allocator.dupe(u8, "h"),
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Entity 6 — byte for-loop binding
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

    // Wire module items: [basis, prime, hash]
    const items_slice = try allocator.alloc(spine.EntityId, 3);
    items_slice[0] = basis_id;
    items_slice[1] = prime_id;
    items_slice[2] = hash_id;
    g.modules.items[root_id].items = items_slice;

    try g.addCrate(.{
        .name = try allocator.dupe(u8, "fnv"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    // ── Types table ─────────────────────────────────────────────────────
    // 0 = u64, 1 = []const u8

    const u64_type: types.Type = .{ .prim = .u64 };

    const slice_ptr = try allocator.create(types.Slice);
    slice_ptr.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const byte_slice_type: types.Type = .{ .slice = slice_ptr };

    const types_store = try allocator.alloc(types.Type, 2);
    types_store[0] = u64_type;
    types_store[1] = byte_slice_type;

    // ── Params (for fnv1a_hash) ─────────────────────────────────────────
    const params = try allocator.alloc(items.Param, 1);
    params[0] = .{
        .name = "data",
        .ty = byte_slice_type,
        .span = span,
    };

    // ── Pats table ──────────────────────────────────────────────────────
    // 0 = h (mutable), 1 = byte (immutable)

    const pats_store = try allocator.alloc(exprs.Pattern, 2);
    pats_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .binding = .{
            .name = "h",
            .mode = .{ .value = {} },
            .mutable = true,
        } },
    };
    pats_store[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .binding = .{
            .name = "byte",
            .mode = .{ .value = {} },
            .mutable = false,
        } },
    };

    // ── Exprs table ─────────────────────────────────────────────────────

    const exprs_store = try allocator.alloc(exprs.Expr, 13);

    // 0: int literal for FNV_OFFSET_BASIS
    exprs_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{
            .text = "14695981039346656037",
            .value = 14695981039346656037,
            .base = .dec,
            .ty_suffix = null,
        } } },
    };

    // 1: int literal for FNV_PRIME
    exprs_store[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{
            .text = "1099511628211",
            .value = 1099511628211,
            .base = .dec,
            .ty_suffix = null,
        } } },
    };

    // 2: PathExpr → FNV_OFFSET_BASIS (entity 1)
    exprs_store[2] = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{ .path = .{ .def = 1, .generic_args = &.{} } },
    };

    // 3: PathExpr → FNV_PRIME (entity 2)
    exprs_store[3] = .{
        .id = 3,
        .span = span,
        .ty = null,
        .kind = .{ .path = .{ .def = 2, .generic_args = &.{} } },
    };

    // 4: PathExpr → data (entity 4)
    exprs_store[4] = .{
        .id = 4,
        .span = span,
        .ty = null,
        .kind = .{ .path = .{ .def = 4, .generic_args = &.{} } },
    };

    // 5: PathExpr → h (entity 5)
    exprs_store[5] = .{
        .id = 5,
        .span = span,
        .ty = null,
        .kind = .{ .path = .{ .def = 5, .generic_args = &.{} } },
    };

    // 6: PathExpr → byte (entity 6)
    exprs_store[6] = .{
        .id = 6,
        .span = span,
        .ty = null,
        .kind = .{ .path = .{ .def = 6, .generic_args = &.{} } },
    };

    // 7: AssignExpr: h ^= byte
    exprs_store[7] = .{
        .id = 7,
        .span = span,
        .ty = null,
        .kind = .{
            .assign = .{
                .target = 5, // h
                .op = .bit_xor,
                .value = 6, // byte
                .overflow = .checked,
            },
        },
    };

    // 8: AssignExpr: h *%= FNV_PRIME (wrapping_mul → wrapping overflow)
    exprs_store[8] = .{
        .id = 8,
        .span = span,
        .ty = null,
        .kind = .{
            .assign = .{
                .target = 5, // h
                .op = .mul,
                .value = 3, // FNV_PRIME path
                .overflow = .wrapping,
            },
        },
    };

    // 9: BlockExpr — for body { h ^= byte; h *%= FNV_PRIME; }
    exprs_store[9] = .{
        .id = 9,
        .span = span,
        .ty = null,
        .kind = .{
            .block = .{
                .statements = &.{ 1, 2 }, // stmt indices 1, 2
                .tail = null,
                .labelled = null,
            },
        },
    };

    // 10: ForExpr — for (data) |byte| { ... }
    exprs_store[10] = .{
        .id = 10,
        .span = span,
        .ty = null,
        .kind = .{
            .for_ = .{
                .pattern = 1, // byte binding pat
                .iterable = 4, // data path expr
                .body = exprs_store[9].kind.block,
                .iter_kind = .{ .slice = {} },
            },
        },
    };

    // 11: ReturnExpr — return h
    exprs_store[11] = .{
        .id = 11,
        .span = span,
        .ty = null,
        .kind = .{ .return_ = .{ .value = 5 } },
    };

    // 12: BlockExpr — fn body { var h: u64 = ...; for ...; return h; }
    exprs_store[12] = .{
        .id = 12,
        .span = span,
        .ty = null,
        .kind = .{
            .block = .{
                .statements = &.{ 0, 3 }, // stmt indices 0 (let_h), 3 (for_stmt)
                .tail = 11, // return_h
                .labelled = null,
            },
        },
    };

    // ── Stmts table ─────────────────────────────────────────────────────

    const stmts_store = try allocator.alloc(exprs.Statement, 4);

    // 0: LetStmt — var h: u64 = FNV_OFFSET_BASIS
    stmts_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{
            .let = .{
                .pattern = 0, // h binding
                .init = 2, // PathExpr → FNV_OFFSET_BASIS
                .ty = 0, // TypeId 0 = u64
            },
        },
    };

    // 1: ExprStmt — h ^= byte (for body)
    stmts_store[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .expr = 7 }, // assign_xor
    };

    // 2: ExprStmt — h *%= FNV_PRIME (for body)
    stmts_store[2] = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{ .expr = 8 }, // assign_mul
    };

    // 3: ExprStmt — for loop (fn body)
    stmts_store[3] = .{
        .id = 3,
        .span = span,
        .ty = null,
        .kind = .{ .expr = 10 }, // for_expr
    };

    // ── Bodies (indexed by EntityId) ────────────────────────────────────

    const bodies_arr = try allocator.alloc(emit.BodyKind, 7);
    bodies_arr[0] = .none; // root module
    bodies_arr[1] = .{
        .const_ = .{
            .ty = u64_type,
            .init = 0, // int literal
        },
    };
    bodies_arr[2] = .{
        .const_ = .{
            .ty = u64_type,
            .init = 1, // int literal
        },
    };
    bodies_arr[3] = .{
        .fn_ = .{
            .params = params,
            .ret = u64_type,
            .body = 12, // fn body block expr
        },
    };
    bodies_arr[4] = .none; // data
    bodies_arr[5] = .none; // h
    bodies_arr[6] = .none; // byte

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
/// first `pub const FNV_OFFSET_BASIS` to just before the first `\ntest "`).
fn extractCore(allocator: std.mem.Allocator, golden: []const u8) ![]const u8 {
    const start_marker = "pub const FNV_OFFSET_BASIS";
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

test "emit fnv with body golden" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;

    // 1) Load and normalize the golden file.
    const golden_raw = try readFixture(allocator, test_io, "test/r2z-fnv.zig");
    defer allocator.free(golden_raw);
    const golden_norm = try normalize(allocator, golden_raw);
    defer allocator.free(golden_norm);

    // 2) Extract the core (items + fn body, no file header / tests).
    const core_raw = try extractCore(allocator, golden_norm);
    defer allocator.free(core_raw);
    const core = try normalize(allocator, core_raw);
    defer allocator.free(core);

    // 3) Build the in-memory fnv model with bodies.
    var model = try buildFnvModel(allocator);
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
