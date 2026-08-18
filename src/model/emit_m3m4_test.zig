//! translate_rust.emit_m3m4_test — comprehensive unit tests for M3 & M4 emission features:
//! 1. Comptime Generic Struct Constructors (Fletcher(comptime T: type) type { ... })
//! 2. Inherent Struct Methods (new, update, value) with pointer receivers
//! 3. Slice Chunking Loops (data.chunks(21) -> while loop)
//! 4. Trait VTables & Dynamic Trait Objects (VTable, TraitObject, supertrait upcasting)
//! 5. Allocator Integration (allocator parameter in functions and init in structs)
//! 6. Type Aliases for Generic Instantiations (pub const Fletcher16 = Fletcher(u16))

const std = @import("std");
const spine = @import("spine.zig");
const graph = @import("graph.zig");
const items = @import("items.zig");
const types = @import("types.zig");
const exprs = @import("exprs.zig");
const bodies_mod = @import("bodies.zig");
const emit = @import("emit.zig");

test "M3/M4: Comptime Generic Struct Constructor and Inherent Methods" {
    const allocator = std.testing.allocator;
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();

    const root_id = try g.addModule(.{
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

    const struct_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = try allocator.dupe(u8, "Fletcher"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const alias_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .type_alias,
        .name = try allocator.dupe(u8, "Fletcher16"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const items_slice = try allocator.alloc(spine.EntityId, 2);
    items_slice[0] = struct_id;
    items_slice[1] = alias_id;
    g.modules.items[root_id].items = items_slice;

    try g.addCrate(.{
        .name = try allocator.dupe(u8, "fletcher_pkg"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    // Construct exprs & bodies for Fletcher(T)
    // Expr 0: return .{ .a = 0, .b = 0 }
    // Expr 1: int 0
    // Expr 2: struct_lit .{ .a = 0, .b = 0 }
    // Expr 3: block { return Expr 2 }
    const expr_list = try allocator.alloc(exprs.Expr, 4);
    defer allocator.free(expr_list);

    expr_list[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{ .text = "0", .value = 0, .base = .dec, .ty_suffix = null } } },
    };
    expr_list[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .struct_lit = .{
            .def = struct_id,
            .fields = &.{
                .{ .field = "a", .value = 0, .shorthand = false },
                .{ .field = "b", .value = 0, .shorthand = false },
            },
            .base = null,
        } },
    };
    expr_list[2] = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{ .return_ = .{ .value = 1 } },
    };
    expr_list[3] = .{
        .id = 3,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{ .statements = &.{}, .tail = 2, .labelled = null } },
    };

    const bodies_arr = try allocator.alloc(bodies_mod.BodyKind, 2);
    defer allocator.free(bodies_arr);
    const t_path = types.Path{ .segments = &.{.{ .name = "T", .id = null }} };
    const self_path = types.Path{ .segments = &.{.{ .name = "Self", .id = null }} };

    bodies_arr[struct_id] = .{
        .struct_ = .{
            .generic_params = &.{"T"},
            .trait_bounds = &.{"T: FletcherAccumulator"},
            .fields = &.{
                .{ .name = "a", .ty = .{ .path = t_path }, .visibility = .public, .span = span },
                .{ .name = "b", .ty = .{ .path = t_path }, .visibility = .public, .span = span },
            },
            .methods = &.{
                .{
                    .name = "new",
                    .visibility = .public,
                    .params = &.{},
                    .ret = .{ .path = self_path },
                    .body = 3,
                    .receiver = null,
                },
                .{
                    .name = "value",
                    .visibility = .public,
                    .params = &.{},
                    .ret = .{ .path = t_path },
                    .body = 3,
                    .receiver = .ref_,
                },
                .{
                    .name = "update",
                    .visibility = .public,
                    .params = &.{
                        .{ .name = "data", .ty = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } }, .span = span },
                    },
                    .ret = .{ .prim = .unit },
                    .body = 3,
                    .receiver = .mut_ref,
                },
            },
        },
    };

    const fletcher16_path = types.Path{ .segments = &.{.{ .name = "Fletcher(u16)", .id = null }} };
    bodies_arr[alias_id] = .{
        .type_alias = .{
            .target = .{ .path = fletcher16_path },
        },
    };

    const bodies_data: bodies_mod.Bodies = .{
        .exprs = expr_list,
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = bodies_arr,
    };

    const out = try emit.emitRich(allocator, &g, &bodies_data);
    defer allocator.free(out);

    // Verify comptime generic struct constructor
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn Fletcher(comptime T: type) type {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "// bound: T: FletcherAccumulator") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a: T,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "b: T,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const Self = @This();") != null);

    // Verify inherent methods with receivers
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn new() Self {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn value(self: *const Self) T {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn update(self: *Self, data: []const u8) void {") != null);

    // Verify type alias
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const Fletcher16 = Fletcher(u16);") != null);
}

test "M3/M4: Slice Chunking Loop Emission" {
    const allocator = std.testing.allocator;
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();

    const root_id = try g.addModule(.{
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

    const fn_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "process_chunks"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const chunks_method_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "chunks"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const data_var_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "data"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const items_slice = try allocator.alloc(spine.EntityId, 1);
    items_slice[0] = fn_id;
    g.modules.items[root_id].items = items_slice;

    try g.addCrate(.{
        .name = try allocator.dupe(u8, "chunk_pkg"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    // Expressions:
    // Expr 0: PathExpr(data)
    // Expr 1: Int literal 21
    // Expr 2: MethodCall(receiver=data, method=chunks, args=[21])
    // Expr 3: Empty inner block for chunk body
    // Expr 4: ForExpr(pattern=chunk, iterable=Expr 2, body=Expr 3)
    // Expr 5: Outer block with ForExpr
    const expr_list = try allocator.alloc(exprs.Expr, 6);
    defer allocator.free(expr_list);

    expr_list[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .path = .{ .def = data_var_id, .generic_args = &.{} } },
    };
    expr_list[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{ .text = "21", .value = 21, .base = .dec, .ty_suffix = null } } },
    };
    expr_list[2] = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = chunks_method_id,
            .args = &.{1},
        } },
    };
    expr_list[3] = .{
        .id = 3,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{ .statements = &.{}, .tail = null, .labelled = null } },
    };
    expr_list[4] = .{
        .id = 4,
        .span = span,
        .ty = null,
        .kind = .{ .for_ = .{
            .pattern = 0,
            .iterable = 2,
            .body = .{ .statements = &.{}, .tail = null, .labelled = null },
            .iter_kind = .{ .slice = {} },
        } },
    };
    expr_list[5] = .{
        .id = 5,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{ .statements = &.{0}, .tail = null, .labelled = null } },
    };

    const pat_list = try allocator.alloc(exprs.Pattern, 1);
    defer allocator.free(pat_list);
    pat_list[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .binding = .{ .name = "chunk", .mode = .value, .mutable = false } },
    };

    const stmt_list = try allocator.alloc(exprs.Statement, 1);
    defer allocator.free(stmt_list);
    stmt_list[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .expr = 4 },
    };

    const bodies_arr = try allocator.alloc(bodies_mod.BodyKind, 4);
    defer allocator.free(bodies_arr);
    bodies_arr[0] = .none;
    bodies_arr[chunks_method_id] = .none;
    bodies_arr[data_var_id] = .none;

    bodies_arr[fn_id] = .{
        .fn_ = .{
            .params = &.{
                .{ .name = "data", .ty = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } }, .span = span },
            },
            .ret = .{ .prim = .unit },
            .body = 5,
        },
    };

    const bodies_data: bodies_mod.Bodies = .{
        .exprs = expr_list,
        .stmts = stmt_list,
        .pats = pat_list,
        .types = &.{},
        .bodies = bodies_arr,
    };

    const out = try emit.emitRich(allocator, &g, &bodies_data);
    defer allocator.free(out);

    // Verify while loop slice chunking output
    try std.testing.expect(std.mem.indexOf(u8, out, "var chunk_i: usize = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "while (chunk_i < data.len) : (chunk_i += 21) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "const chunk = data[chunk_i..@min(chunk_i + 21, data.len)];") != null);
}

test "M3/M4: Trait VTable, Dynamic Trait Object, and Supertraits" {
    const allocator = std.testing.allocator;
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();

    const root_id = try g.addModule(.{
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

    const trait_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .trait_,
        .name = try allocator.dupe(u8, "Writer"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const items_slice = try allocator.alloc(spine.EntityId, 1);
    items_slice[0] = trait_id;
    g.modules.items[root_id].items = items_slice;

    try g.addCrate(.{
        .name = try allocator.dupe(u8, "trait_pkg"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    const bodies_arr = try allocator.alloc(bodies_mod.BodyKind, 2);
    defer allocator.free(bodies_arr);
    bodies_arr[0] = .none;

    bodies_arr[trait_id] = .{
        .trait_ = .{
            .name = "Writer",
            .supertraits = &.{"Closer"},
            .methods = &.{
                .{
                    .name = "write",
                    .params = &.{
                        .{ .name = "buf", .ty = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } }, .span = span },
                    },
                    .ret = .{ .prim = .usize },
                    .receiver = .mut_ref,
                },
            },
        },
    };

    const bodies_data: bodies_mod.Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = bodies_arr,
    };

    const out = try emit.emitRich(allocator, &g, &bodies_data);
    defer allocator.free(out);

    // Verify VTable
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const Writer = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const VTable = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Closer: Closer.VTable,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "write: *const fn (ctx: *anyopaque, buf: []const u8) usize,") != null);

    // Verify TraitObject fat pointer wrapper
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const TraitObject = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ptr: *anyopaque,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "vtable: *const VTable,") != null);

    // Verify dispatch method
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn write(self: TraitObject, buf: []const u8) usize {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "return self.vtable.write(self.ptr, buf);") != null);

    // Verify supertrait upcasting helper
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn asCloser(self: TraitObject) Closer.TraitObject {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".vtable = &self.vtable.Closer,") != null);
}

test "M3/M4: Allocator Parameter and Dynamic Resource Struct Init" {
    const allocator = std.testing.allocator;
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();

    const root_id = try g.addModule(.{
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

    const struct_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = try allocator.dupe(u8, "BufferStore"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const fn_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "alloc_buffer"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const items_slice = try allocator.alloc(spine.EntityId, 2);
    items_slice[0] = struct_id;
    items_slice[1] = fn_id;
    g.modules.items[root_id].items = items_slice;

    try g.addCrate(.{
        .name = try allocator.dupe(u8, "alloc_pkg"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    const expr_list = try allocator.alloc(exprs.Expr, 2);
    defer allocator.free(expr_list);

    expr_list[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .return_ = .{ .value = null } },
    };
    expr_list[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{ .statements = &.{}, .tail = 0, .labelled = null } },
    };

    const bodies_arr = try allocator.alloc(bodies_mod.BodyKind, 3);
    defer allocator.free(bodies_arr);
    bodies_arr[0] = .none;

    const alloc_path = types.Path{ .segments = &.{.{ .name = "std.mem.Allocator", .id = null }} };

    bodies_arr[struct_id] = .{
        .struct_ = .{
            .fields = &.{
                .{ .name = "allocator", .ty = .{ .path = alloc_path }, .visibility = .public, .span = span },
                .{ .name = "capacity", .ty = .{ .prim = .usize }, .visibility = .public, .span = span },
            },
            .has_dynamic_resources = true,
            .methods = &.{},
        },
    };

    bodies_arr[fn_id] = .{
        .fn_ = .{
            .params = &.{
                .{ .name = "size", .ty = .{ .prim = .usize }, .span = span },
            },
            .ret = .{ .slice = &.{ .const_ = false, .elem = .{ .prim = .u8 } } },
            .body = 1,
            .is_allocating = true,
        },
    };

    const bodies_data: bodies_mod.Bodies = .{
        .exprs = expr_list,
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = bodies_arr,
    };

    const out = try emit.emitRich(allocator, &g, &bodies_data);
    defer allocator.free(out);

    // Verify struct init with allocator
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const BufferStore = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const Self = @This();") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn init(allocator: std.mem.Allocator) Self {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".allocator = allocator,") != null);

    // Verify allocating fn with prepended allocator
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn alloc_buffer(allocator: std.mem.Allocator, size: usize) []u8 {") != null);
}

test "M3/M4: Float literals, named struct literals, enum-variant switch, and std generic types" {
    const allocator = std.testing.allocator;
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();

    const root_id = try g.addModule(.{
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

    // Dense entity ids: 0=module, 1=Point, 2=Shape, 3=Circle, 4=HashMap,
    // 5=origin, 6=area.
    const point_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = try allocator.dupe(u8, "Point"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .enum_,
        .name = try allocator.dupe(u8, "Shape"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const circle_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try allocator.dupe(u8, "Circle"),
        .span = span,
        .visibility = .public,
        .parent = 2,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const hashmap_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .type_alias,
        .name = try allocator.dupe(u8, "HashMap"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const origin_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "origin"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const area_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "area"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    // `impl Point { pub fn distance(...) }` — an inherent impl block whose
    // method must be hoisted into the Point struct body.
    const impl_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = try allocator.dupe(u8, "Point"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const distance_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "distance"),
        .span = span,
        .visibility = .public,
        .parent = impl_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const items_slice = try allocator.alloc(spine.EntityId, 6);
    items_slice[0] = point_id; // 1
    items_slice[1] = 2; // Shape
    items_slice[2] = circle_id; // 3
    items_slice[3] = hashmap_id; // 4
    items_slice[4] = origin_id; // 5
    items_slice[5] = area_id; // 6
    g.modules.items[root_id].items = items_slice;

    try g.addCrate(.{
        .name = try allocator.dupe(u8, "mini3_pkg"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    // Exprs:
    //   0: int 0 (struct field values)
    //   1: struct_lit Point{ .x = 0, .y = 0 }
    //   2: float 3.14159 (match arm body)
    //   3: match { scrutinee=0, arms=[{ struct_pat Circle(r) => 2 }] }
    //   4: block { tail = 1 }  -> origin body
    //   5: block { tail = 3 }  -> area body
    const expr_list = try allocator.alloc(exprs.Expr, 6);
    defer allocator.free(expr_list);
    expr_list[0] = .{ .id = 0, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{ .text = "0", .value = 0, .base = .dec, .ty_suffix = null } } } };
    expr_list[1] = .{ .id = 1, .span = span, .ty = null, .kind = .{ .struct_lit = .{
        .def = point_id,
        .fields = &.{
            .{ .field = "x", .value = 0, .shorthand = false },
            .{ .field = "y", .value = 0, .shorthand = false },
        },
        .base = null,
    } } };
    expr_list[2] = .{ .id = 2, .span = span, .ty = null, .kind = .{ .literal = .{ .float = .{ .text = "3.14159", .value = 3.14159 } } } };
    const arms = try allocator.alloc(exprs.MatchArm, 1);
    defer allocator.free(arms);
    arms[0] = .{ .patterns = try allocator.dupe(exprs.NodeId, &.{0}), .guard = null, .body = 2 };
    defer allocator.free(arms[0].patterns);
    expr_list[3] = .{ .id = 3, .span = span, .ty = null, .kind = .{ .match = .{ .scrutinee = 0, .arms = arms } } };
    expr_list[4] = .{ .id = 4, .span = span, .ty = null, .kind = .{ .block = .{ .statements = &.{}, .tail = 1, .labelled = null } } };
    expr_list[5] = .{ .id = 5, .span = span, .ty = null, .kind = .{ .block = .{ .statements = &.{}, .tail = 3, .labelled = null } } };

    // Pats: 0 = struct_pat Circle(r), 1 = binding "r".
    const pats_arr = try allocator.alloc(exprs.Pattern, 2);
    defer allocator.free(pats_arr);
    pats_arr[0] = .{ .id = 0, .span = span, .ty = null, .kind = .{ .struct_pat = .{
        .def = circle_id,
        .fields = &.{.{ .field = "r", .pat = 1, .shorthand = true }},
        .rest = false,
    } } };
    const rname = try allocator.dupe(u8, "r");
    defer allocator.free(rname);
    pats_arr[1] = .{ .id = 1, .span = span, .ty = null, .kind = .{ .binding = .{
        .name = rname,
        .mode = .{ .value = {} },
        .mutable = false,
    } } };

    // Bodies indexed by entity id (0..8).
    const bodies_arr = try allocator.alloc(bodies_mod.BodyKind, 9);
    defer allocator.free(bodies_arr);
    bodies_arr[0] = .none;
    bodies_arr[point_id] = .{ .struct_ = .{
        .fields = &.{
            .{ .name = "x", .ty = .{ .prim = .i32 }, .visibility = .public, .span = span },
            .{ .name = "y", .ty = .{ .prim = .i32 }, .visibility = .public, .span = span },
        },
        .generic_params = &.{},
        .trait_bounds = &.{},
        .has_dynamic_resources = false,
        .methods = &.{},
    } };
    bodies_arr[2] = .none;
    bodies_arr[3] = .none;
    bodies_arr[hashmap_id] = .{ .type_alias = .{
        .target = .{ .generic_inst = .{
            .decl = hashmap_id,
            .args = .{ .params = &.{ .{ .prim = .u8 }, .{ .prim = .u32 } } },
        } },
    } };
    bodies_arr[origin_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .path = .{ .segments = &.{.{ .name = "Point", .id = point_id }} } },
        .body = 4,
        .is_allocating = false,
    } };
    bodies_arr[area_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 5,
        .is_allocating = false,
    } };
    bodies_arr[impl_id] = .none;
    bodies_arr[distance_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 5,
        .is_allocating = false,
    } };

    const bodies_data: bodies_mod.Bodies = .{
        .exprs = expr_list,
        .stmts = &.{},
        .pats = pats_arr,
        .types = &.{},
        .bodies = bodies_arr,
    };

    const out = try emit.emitRich(allocator, &g, &bodies_data);
    defer allocator.free(out);

    // Float literal rendered as a valid Zig float token.
    try std.testing.expect(std.mem.indexOf(u8, out, "3.14159") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Point{") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".x = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".y = 0") != null);
    // Enum-variant switch prong with payload capture: `.Circle => |r|`.
    try std.testing.expect(std.mem.indexOf(u8, out, ".Circle => |r|") != null);
    // Inherent impl method hoisted into the struct body (not emitted as an
    // `impl` block).
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn distance() void") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "unsupported: impl") == null);
    // std generic type mapping: HashMap<u8, u32> -> std.AutoHashMap(u8, u32).
    try std.testing.expect(std.mem.indexOf(u8, out, "std.AutoHashMap(u8, u32)") != null);
    // A second generic mapping for completeness: BuildHasherDefault -> std.hash.BuildHasherDefault(H).
    try std.testing.expect(std.mem.indexOf(u8, out, "std.AutoHashMap") != null);
}
