//! translate_rust.backend.zig.serialize_test — JSON roundtrip tests
//! for ast.Package serialization.

const std = @import("std");
const testing = std.testing;
const ast = @import("ast.zig");
const serialize = @import("serialize.zig");

test "serialize preserves finite float boundary bits through JSON" {
    const values = [_]f64{ 1e300, 1e-300, std.math.floatMax(f64), 5e-324, 0.0, -0.0 };
    for (values) |value| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const pkg: ast.Package = .{
            .name = "float_boundary",
            .version = "0.1.0",
            .files = &.{.{
                .path = "src/root.zig",
                .imports = &.{},
                .decls = &.{.{ .const_decl = .{
                    .name = "VALUE",
                    .ty = .{ .prim = .f64 },
                    .init = .{ .lit = .{ .float = value } },
                } }},
            }},
            .zon_deps = &.{},
        };
        const bytes = try serialize.encode(allocator, &pkg);
        const decoded = try serialize.decode(allocator, bytes);
        const actual = decoded.files[0].decls[0].const_decl.init.lit.float;
        try testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(actual)));
    }
}

test "serialize: ast package JSON roundtrip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // ---- Build a rich representative Package. All `allocator.create` nodes
    // live in the arena; slice/array literals live on this test stack frame
    // (valid for the whole test = encode + decode scope).

    // Types
    const u8_ty = try allocator.create(ast.Type);
    u8_ty.* = .{ .prim = .u8 };
    const slice_ty = try allocator.create(ast.Type);
    slice_ty.* = .{ .slice = .{ .elem = u8_ty, .is_const = true } };
    const opt_ty = try allocator.create(ast.Type);
    opt_ty.* = .{ .opt = slice_ty };

    // Exprs
    const lit_str = try allocator.create(ast.Expr);
    lit_str.* = .{ .lit = .{ .str = "hello" } };

    const ident_a = try allocator.create(ast.Expr);
    ident_a.* = .{ .ident = "a" };
    const ident_b = try allocator.create(ast.Expr);
    ident_b.* = .{ .ident = "b" };

    const bin_expr = try allocator.create(ast.Expr);
    bin_expr.* = .{
        .bin_op = .{
            .op = .add,
            .lhs = ident_a,
            .rhs = ident_b,
        },
    };

    const let_stmt = ast.Stmt{
        .let_stmt = .{
            .name = "sum",
            .ty = .{ .prim = .u32 },
            .init = bin_expr.*,
            .is_mut = true,
        },
    };

    const const_decl = ast.Decl{
        .const_decl = .{
            .name = "GREETING",
            .ty = slice_ty.*,
            .init = lit_str.*,
        },
    };

    const method_fn = ast.Decl{
        .fn_decl = .{
            .name = "area",
            .params = &.{
                .{ .name = "self", .ty = .{ .ptr = .{ .elem = u8_ty } } },
            },
            .ret_type = .{ .prim = .u32 },
            .body = .{
                .stmts = &.{let_stmt},
                .expr = bin_expr,
            },
        },
    };

    const struct_decl = ast.Decl{
        .struct_decl = .{
            .name = "Rectangle",
            .fields = &.{
                .{ .name = "width", .ty = .{ .prim = .u32 } },
                .{ .name = "height", .ty = .{ .prim = .u32 } },
            },
            .decls = &.{method_fn},
        },
    };

    const enum_decl = ast.Decl{
        .enum_decl = .{
            .name = "Color",
            .tag_type = .{ .prim = .u8 },
            .variants = &.{
                .{ .name = "Red" },
                .{ .name = "Green", .value = bin_expr },
            },
        },
    };

    const union_decl = ast.Decl{
        .union_decl = .{
            .name = "Shape",
            .tag_type = .{ .prim = .u8 },
            .fields = &.{
                .{ .name = "circle", .ty = .{ .prim = .f64 } },
                .{ .name = "rect", .ty = .{ .slice = .{ .elem = slice_ty, .is_const = true } } },
            },
        },
    };

    const var_decl = ast.Decl{
        .var_decl = .{
            .name = "counter",
            .ty = .{ .prim = .u32 },
            .init = .{ .lit = .{ .uint = 42 } },
        },
    };

    const match_expr = try allocator.create(ast.Expr);
    match_expr.* = .{
        .match_expr = .{
            .target = ident_a,
            .arms = &.{
                .{ .patterns = &.{.{ .binding = "x" }}, .body = lit_str.* },
                .{ .patterns = &.{.wildcard}, .body = .{ .lit = .{ .str = "other" } } },
            },
        },
    };

    const generic_fn = ast.Decl{
        .fn_decl = .{
            .name = "identity",
            .ret_type = .{ .generic = .{ .name = "T" } },
            .body = .{
                .expr = match_expr,
            },
            .generic_params = &.{
                .{ .name = "T" },
            },
        },
    };

    const comment_decl = ast.Decl{
        .comment = " a comment",
    };

    const test_decl = ast.TestDecl{
        .name = "basic test",
        .body = .{
            .stmts = &.{let_stmt},
        },
    };

    const file = ast.File{
        .path = "src/root.zig",
        .imports = &.{
            .{ .local_name = "std", .module_or_path = "std" },
        },
        .decls = &.{
            const_decl,
            struct_decl,
            enum_decl,
            union_decl,
            var_decl,
            generic_fn,
            comment_decl,
        },
        .tests = &.{test_decl},
    };

    const pkg = ast.Package{
        .name = "demo_pkg",
        .version = "0.1.0",
        .fingerprint = 0xABCDEF0123456789,
        .files = &.{file},
        .zon_deps = &.{
            .{ .name = "dep", .url = "https://example.com/dep.tar.gz", .hash = "1220abc" },
        },
    };
    // ----

    const json_bytes = try serialize.encode(allocator, &pkg);
    const decoded = try serialize.decode(allocator, json_bytes);

    // Validate decoded structure.
    try testing.expectEqualStrings("demo_pkg", decoded.name);
    try testing.expectEqualStrings("0.1.0", decoded.version);
    try testing.expectEqual(@as(?u64, 0xABCDEF0123456789), decoded.fingerprint);
    try testing.expectEqual(@as(usize, 1), decoded.files.len);
    try testing.expectEqual(@as(usize, 1), decoded.zon_deps.len);

    const f = decoded.files[0];
    try testing.expectEqualStrings("src/root.zig", f.path);
    try testing.expectEqual(@as(usize, 1), f.imports.len);
    try testing.expectEqualStrings("std", f.imports[0].local_name);
    try testing.expectEqual(@as(usize, 7), f.decls.len);
    try testing.expectEqual(@as(usize, 1), f.tests.len);

    // decl 0: const_decl
    const d0 = f.decls[0];
    try testing.expect(d0 == .const_decl);
    try testing.expectEqualStrings("GREETING", d0.const_decl.name);
    try testing.expect(d0.const_decl.ty.?.slice.elem.* == .prim);

    // decl 1: struct_decl
    const d1 = f.decls[1];
    try testing.expect(d1 == .struct_decl);
    try testing.expectEqualStrings("Rectangle", d1.struct_decl.name);
    try testing.expectEqual(@as(usize, 2), d1.struct_decl.fields.len);
    try testing.expectEqualStrings("width", d1.struct_decl.fields[0].name);
    // hoisted method
    try testing.expectEqual(@as(usize, 1), d1.struct_decl.decls.len);
    try testing.expect(d1.struct_decl.decls[0] == .fn_decl);
    try testing.expectEqualStrings("area", d1.struct_decl.decls[0].fn_decl.name);
    // body with let_stmt + bin_op expr
    const area_body = d1.struct_decl.decls[0].fn_decl.body.?;
    try testing.expectEqual(@as(usize, 1), area_body.stmts.len);
    try testing.expect(area_body.stmts[0] == .let_stmt);
    try testing.expectEqualStrings("sum", area_body.stmts[0].let_stmt.name);
    const tail = area_body.expr.?.*;
    try testing.expect(tail == .bin_op);
    try testing.expect(tail.bin_op.op == .add);

    // decl 2: enum_decl
    const d2 = f.decls[2];
    try testing.expect(d2 == .enum_decl);
    try testing.expectEqualStrings("Color", d2.enum_decl.name);
    try testing.expectEqual(@as(usize, 2), d2.enum_decl.variants.len);
    try testing.expectEqualStrings("Red", d2.enum_decl.variants[0].name);
    try testing.expect(d2.enum_decl.variants[0].value == null);
    try testing.expect(d2.enum_decl.variants[1].value != null);

    // decl 3: union_decl
    const d3 = f.decls[3];
    try testing.expect(d3 == .union_decl);
    try testing.expectEqualStrings("Shape", d3.union_decl.name);
    try testing.expectEqual(@as(usize, 2), d3.union_decl.fields.len);

    // decl 4: var_decl
    const d4 = f.decls[4];
    try testing.expect(d4 == .var_decl);
    try testing.expectEqualStrings("counter", d4.var_decl.name);
    try testing.expect(d4.var_decl.init == .lit);

    // decl 5: generic fn
    const d5 = f.decls[5];
    try testing.expect(d5 == .fn_decl);
    try testing.expectEqualStrings("identity", d5.fn_decl.name);
    try testing.expectEqual(@as(usize, 1), d5.fn_decl.generic_params.len);
    const gen_body_expr = d5.fn_decl.body.?.expr.?.*;
    try testing.expect(gen_body_expr == .match_expr);
    try testing.expectEqual(@as(usize, 2), gen_body_expr.match_expr.arms.len);
    try testing.expect(gen_body_expr.match_expr.arms[0].patterns[0] == .binding);

    // decl 6: comment
    const d6 = f.decls[6];
    try testing.expect(d6 == .comment);
    try testing.expectEqualStrings(" a comment", d6.comment);

    // zon deps
    try testing.expectEqualStrings("dep", decoded.zon_deps[0].name);
    try testing.expectEqualStrings("https://example.com/dep.tar.gz", decoded.zon_deps[0].url);
    try testing.expectEqualStrings("1220abc", decoded.zon_deps[0].hash);
}

test "serialize: minimal empty package roundtrip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const pkg = ast.Package{
        .name = "empty",
    };

    const json_bytes = try serialize.encodeVal(allocator, pkg);
    const json_bytes2 = try serialize.serialize(allocator, pkg);
    // encodeVal and serialize alias; both produced.
    _ = json_bytes2;

    const decoded = try serialize.deserialize(allocator, json_bytes);
    try testing.expectEqualStrings("empty", decoded.name);
    try testing.expectEqualStrings("0.0.0", decoded.version);
    try testing.expectEqual(@as(?u64, null), decoded.fingerprint);
    try testing.expectEqual(@as(usize, 0), decoded.files.len);
    try testing.expectEqual(@as(usize, 0), decoded.zon_deps.len);
}

test "serialize: documentation roundtrips through the package codec" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const pkg = ast.Package{
        .name = "documented",
        .files = &.{.{
            .path = "src/doc.zig",
            .documentation = "Encoding helpers.\nSecond line.",
            .imports = &.{.{
                .local_name = "std",
                .module_or_path = "std",
                .documentation = "Only io and fmt are used.",
            }},
            .decls = &.{
                .{ .struct_decl = .{
                    .name = "Counters",
                    .documentation = "Running totals.",
                    .fields = &.{
                        .{
                            .name = "total",
                            .ty = .{ .prim = .u64 },
                            .documentation = "Bytes seen so far.",
                        },
                        .{ .name = "runs", .ty = .{ .prim = .u32 } },
                    },
                } },
                .{ .enum_decl = .{
                    .name = "State",
                    .variants = &.{
                        .{ .name = "Idle", .documentation = "Not started." },
                        .{ .name = "Done" },
                    },
                } },
                .{ .const_decl = .{
                    .name = "LIMIT",
                    .ty = .{ .prim = .u32 },
                    .init = .{ .lit = .{ .int = 7 } },
                    .documentation = "Never exceeded.",
                } },
            },
        }},
    };

    const encoded = try serialize.encodeVal(allocator, pkg);
    const decoded = try serialize.deserialize(allocator, encoded);

    const file = decoded.files[0];
    try testing.expectEqualStrings("Encoding helpers.\nSecond line.", file.documentation);
    try testing.expectEqualStrings("Only io and fmt are used.", file.imports[0].documentation);

    const counters = file.decls[0].struct_decl;
    try testing.expectEqualStrings("Running totals.", counters.documentation);
    try testing.expectEqualStrings("Bytes seen so far.", counters.fields[0].documentation);
    try testing.expectEqualStrings("", counters.fields[1].documentation);

    const state = file.decls[1].enum_decl;
    try testing.expectEqualStrings("", state.documentation);
    try testing.expectEqualStrings("Not started.", state.variants[0].documentation);
    try testing.expectEqualStrings("", state.variants[1].documentation);

    const limit = file.decls[2].const_decl;
    try testing.expectEqualStrings("Never exceeded.", limit.documentation);
}

test "serialize: documentation is additive metadata, absent from undocumented wires" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A node with no authored documentation keeps exactly the wire it had, so
    // a package written before the field existed still describes itself.
    const undocumented = try serialize.encodeStructField(allocator, .{
        .name = "runs",
        .ty = .{ .prim = .u32 },
    });
    try testing.expect(undocumented.object.get("documentation") == null);

    const documented = try serialize.encodeStructField(allocator, .{
        .name = "total",
        .ty = .{ .prim = .u64 },
        .documentation = "Bytes seen so far.",
    });
    try testing.expectEqualStrings(
        "Bytes seen so far.",
        documented.object.get("documentation").?.string,
    );

    // A null value decodes back to the empty default rather than to text.
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"name":"runs","ty":{"kind":"prim","value":"u32"},"is_pub":true,"documentation":null}
    ,
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "",
        (try serialize.decodeStructField(allocator, parsed.value)).documentation,
    );
}

test "serialize: whitespace formatting" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const pkg = ast.Package{
        .name = "fmt_check",
        .files = &.{
            .{
                .path = "src/a.zig",
                .imports = &.{
                    .{ .local_name = "std", .module_or_path = "std" },
                },
            },
        },
    };

    const json_bytes = try serialize.encode(allocator, &pkg);
    // Indented output contains newlines.
    try testing.expect(std.mem.indexOf(u8, json_bytes, "\n") != null);

    // Roundtrip still correct.
    const decoded = try serialize.decode(allocator, json_bytes);
    try testing.expectEqualStrings("fmt_check", decoded.name);
    try testing.expectEqual(@as(usize, 1), decoded.files.len);
    try testing.expectEqualStrings("src/a.zig", decoded.files[0].path);
}

test "serialize: defer and errdefer statements roundtrip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const normal_stmt: ast.Stmt = .{ .defer_stmt = .{
        .expr = .{ .call = .{
            .callee = &ast.Expr{ .ident = "release" },
        } },
    } };
    const error_stmt: ast.Stmt = .{ .defer_stmt = .{
        .expr = .{ .call = .{
            .callee = &ast.Expr{ .ident = "rollback" },
        } },
        .is_errdefer = true,
    } };
    const pkg = ast.Package{
        .name = "defer_roundtrip",
        .files = &.{.{
            .path = "src/root.zig",
            .decls = &.{.{ .fn_decl = .{
                .name = "work",
                .ret_type = .{ .void_type = {} },
                .body = .{ .stmts = &.{ normal_stmt, error_stmt } },
            } }},
        }},
    };

    const json_bytes = try serialize.encode(allocator, &pkg);
    const decoded = try serialize.decode(allocator, json_bytes);
    const stmts = decoded.files[0].decls[0].fn_decl.body.?.stmts;
    try testing.expectEqual(@as(usize, 2), stmts.len);

    try testing.expect(stmts[0] == .defer_stmt);
    try testing.expect(!stmts[0].defer_stmt.is_errdefer);
    try testing.expect(stmts[0].defer_stmt.expr == .call);
    try testing.expectEqualStrings(
        "release",
        stmts[0].defer_stmt.expr.call.callee.*.ident,
    );

    try testing.expect(stmts[1] == .defer_stmt);
    try testing.expect(stmts[1].defer_stmt.is_errdefer);
    try testing.expect(stmts[1].defer_stmt.expr == .call);
    try testing.expectEqualStrings(
        "rollback",
        stmts[1].defer_stmt.expr.call.callee.*.ident,
    );
}

fn checkImportAllocationFailures(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeImport(allocator, value);
    defer {
        allocator.free(decoded.local_name);
        allocator.free(decoded.module_or_path);
    }
}

test "serialize: scalar decoder releases ownership on allocation failure" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"local_name":"std","module_or_path":"std","is_pub":false}
    ,
        .{},
    );
    defer parsed.deinit();

    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkImportAllocationFailures,
        .{parsed.value},
    );
}

fn checkGenericTypeAllocationFailures(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeType(allocator, value);
    defer {
        allocator.free(decoded.generic.name);
        allocator.free(decoded.generic.params);
    }
}

test "serialize: nested decoder releases malformed and allocation failures" {
    var valid = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"kind":"generic","name":"Vec","params":[{"kind":"prim","value":"u8"}]}
    ,
        .{},
    );
    defer valid.deinit();

    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkGenericTypeAllocationFailures,
        .{valid.value},
    );

    var malformed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"kind":"generic","name":"Vec","params":[{"kind":"prim","value":"u8"},{"kind":"invalid"}]}
    ,
        .{},
    );
    defer malformed.deinit();

    try testing.expectError(
        error.UnknownTypeKind,
        serialize.decodeType(testing.allocator, malformed.value),
    );
}

fn checkPackageAllocationFailures(
    backing_allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    var stable = testing.FailingAllocator.init(backing_allocator, .{ .resize_fail_index = 0 });
    const allocator = stable.allocator();
    const decoded = try serialize.decodePackage(allocator, value);
    defer {
        allocator.free(decoded.name);
        allocator.free(decoded.version);
        for (decoded.files) |file| {
            allocator.free(file.path);
        }
        allocator.free(decoded.files);
        for (decoded.zon_deps) |dep| {
            allocator.free(dep.name);
            allocator.free(dep.url);
            allocator.free(dep.hash);
        }
        allocator.free(decoded.zon_deps);
    }
}

test "serialize: package decoder releases malformed and allocation failures" {
    const prefix =
        \\{"format_version":1,"name":"demo","version":"1.0.0","files":[
        \\{"path":"src/root.zig","imports":[],"decls":[],"tests":[]}
        \\],"zon_deps":
    ;
    var valid = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        prefix ++
            \\[{"name":"dep","url":"https://example.invalid","hash":"abc"}]}
        ,
        .{},
    );
    defer valid.deinit();

    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkPackageAllocationFailures,
        .{valid.value},
    );

    var malformed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        prefix ++
            \\{}}
        ,
        .{},
    );
    defer malformed.deinit();

    try testing.expectError(
        error.BadWireFormat,
        serialize.decodePackage(testing.allocator, malformed.value),
    );
}

/// Build borrowed package nodes with matching zero-sized array and repeat types.
/// `allocator` must outlive every encode call using the returned package.
fn packageEncodingSweep(
    allocator: std.mem.Allocator,
    n: u64,
) !ast.Package {
    const no_elements: []const ast.Type = &.{};
    const unit_ty = try allocator.create(ast.Type);
    unit_ty.* = .{ .tuple = no_elements };

    const unit_expr = try allocator.create(ast.Expr);
    unit_expr.* = .unit;

    const wide_body = try allocator.create(ast.Expr);
    wide_body.* = .{ .repeat = .{ .type_name = unit_ty.*, .elem = unit_expr, .len = n } };

    const fields = try allocator.dupe(ast.StructField, &.{.{
        .name = "length",
        .ty = .{ .array = .{ .elem = unit_ty, .len = n } },
        .documentation = "Elements, not bytes.",
    }});

    const decls = try allocator.alloc(ast.Decl, 2);
    decls[0] = .{ .fn_decl = .{
        .name = "wide",
        .documentation = "Counts past a host word.",
        .ret_type = .{ .array = .{ .elem = unit_ty, .len = n } },
        .body = .{ .expr = wide_body },
    } };
    decls[1] = .{ .struct_decl = .{
        .name = "Sizable",
        .documentation = "Carries the declared length.",
        .fields = fields,
    } };

    const files = try allocator.alloc(ast.File, 1);
    files[0] = .{
        .path = "src/root.zig",
        .documentation = "Root module.",
        .imports = &.{
            .{
                .local_name = "std",
                .module_or_path = "std",
                .documentation = "Only mem is used.",
            },
        },
        .decls = decls,
    };

    return .{
        .name = "encode_sweep",
        .version = "1.2.3",
        .fingerprint = 0xFEDCBA9876543210,
        .files = files,
        .zon_deps = &.{
            .{ .name = "dep", .url = "https://example.invalid/dep.tar.gz", .hash = "1220abc" },
        },
    };
}

fn checkPackageEncodeAllocations(
    backing_allocator: std.mem.Allocator,
    pkg: *const ast.Package,
) !void {
    var stable = testing.FailingAllocator.init(backing_allocator, .{ .resize_fail_index = 0 });
    const allocator = stable.allocator();
    allocator.free(try serialize.encode(allocator, pkg));
}

test "serialize: package encode keeps its tree in the call and returns caller bytes" {
    // The widest admissible count: printed digits rather than an `i64`.
    const n = above_i64_counts[above_i64_counts.len - 1];

    var nodes = std.heap.ArenaAllocator.init(testing.allocator);
    defer nodes.deinit();
    const pkg = try packageEncodingSweep(nodes.allocator(), n);

    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkPackageEncodeAllocations,
        .{&pkg},
    );

    // The bytes are the caller's and outlive the tree the encoder built: the
    // per-call arena is already gone, yet they still decode, and they free
    // against the allocator that produced them.
    const bytes = try serialize.encode(testing.allocator, &pkg);
    defer testing.allocator.free(bytes);

    var decoded_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer decoded_state.deinit();
    const decoded = try serialize.decode(decoded_state.allocator(), bytes);

    try testing.expectEqualStrings("encode_sweep", decoded.name);
    try testing.expectEqualStrings("1.2.3", decoded.version);
    try testing.expectEqual(@as(?u64, 0xFEDCBA9876543210), decoded.fingerprint);
    try testing.expectEqualStrings("dep", decoded.zon_deps[0].name);
    try testing.expectEqualStrings("https://example.invalid/dep.tar.gz", decoded.zon_deps[0].url);
    try testing.expectEqualStrings("1220abc", decoded.zon_deps[0].hash);

    const file = decoded.files[0];
    try testing.expectEqualStrings("Root module.", file.documentation);
    try testing.expectEqualStrings("Only mem is used.", file.imports[0].documentation);

    const wide = file.decls[0].fn_decl;
    try testing.expectEqualStrings("Counts past a host word.", wide.documentation);
    try testing.expect(wide.ret_type == .array);
    try testing.expectEqual(n, wide.ret_type.array.len);
    try testing.expect(wide.ret_type.array.elem.* == .tuple);
    try testing.expectEqual(@as(usize, 0), wide.ret_type.array.elem.*.tuple.len);

    const repeat = wide.body.?.expr.?.*;
    try testing.expect(repeat == .repeat);
    try testing.expectEqual(n, repeat.repeat.len);
    try testing.expect(repeat.repeat.type_name.? == .tuple);
    try testing.expectEqual(@as(usize, 0), repeat.repeat.type_name.?.tuple.len);
    try testing.expect(repeat.repeat.elem.* == .unit);

    const sizable = file.decls[1].struct_decl;
    try testing.expectEqualStrings("Sizable", sizable.name);
    try testing.expectEqualStrings("Carries the declared length.", sizable.documentation);
    try testing.expectEqualStrings("length", sizable.fields[0].name);
    try testing.expectEqualStrings("Elements, not bytes.", sizable.fields[0].documentation);
    try testing.expect(sizable.fields[0].ty == .array);
    try testing.expectEqual(n, sizable.fields[0].ty.array.len);
}

fn checkTupleDecodeAllocations(allocator: std.mem.Allocator, value: std.json.Value) !void {
    const decoded = try serialize.decodeExpr(allocator, value);
    defer {
        allocator.free(decoded.tuple[0].lit.str);
        allocator.free(decoded.tuple);
    }
    try testing.expectEqualStrings("value", decoded.tuple[0].lit.str);
    try testing.expectEqual(@as(i128, 42), decoded.tuple[1].lit.int);
}

test "serialize: tuple values survive roundtrip and allocation failures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const encoded = try serialize.encodeExpr(arena.allocator(), .{
        .tuple = &.{
            .{ .lit = .{ .str = "value" } },
            .{ .lit = .{ .int = 42 } },
        },
    });
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkTupleDecodeAllocations,
        .{encoded},
    );
}

fn checkMatchDecodeAllocations(allocator: std.mem.Allocator, value: std.json.Value) !void {
    const decoded = try serialize.decodeExpr(allocator, value);
    defer {
        allocator.free(decoded.match_expr.target.ident);
        allocator.destroy(@constCast(decoded.match_expr.target));
        for (decoded.match_expr.arms) |arm| {
            for (arm.patterns) |pattern| {
                switch (pattern) {
                    .enum_literal => |name| allocator.free(name),
                    else => {},
                }
            }
            allocator.free(arm.patterns);
            if (arm.capture) |capture| allocator.free(capture.name);
            allocator.free(arm.body.ident);
        }
        allocator.free(decoded.match_expr.arms);
    }
    try testing.expect(decoded.match_expr.arms[0].capture != null);
    try testing.expect(decoded.match_expr.arms[1].capture.?.by_ref);
}

test "serialize: match captures survive roundtrip and allocation failures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const encoded = try serialize.encodeExpr(arena.allocator(), .{
        .match_expr = .{
            .target = &ast.Expr{ .ident = "input" },
            .arms = &.{
                .{
                    .patterns = &.{.{ .enum_literal = "value" }},
                    .capture = .{ .name = "payload" },
                    .body = .{ .ident = "payload" },
                },
                .{
                    .patterns = &.{.{ .enum_literal = "pointer" }},
                    .capture = .{ .name = "pointer_payload", .by_ref = true },
                    .body = .{ .ident = "pointer_payload" },
                },
            },
        },
    });
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkMatchDecodeAllocations,
        .{encoded},
    );
}

fn checkArrayExprTypeAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeType(allocator, value);
    defer {
        const array = decoded.array_expr;
        const call = array.len.call;
        allocator.free(call.callee.*.ident);
        allocator.destroy(@constCast(call.callee));
        allocator.free(call.args);
        allocator.destroy(@constCast(array.len));
        allocator.destroy(@constCast(array.elem));
    }
    try testing.expect(decoded == .array_expr);
    try testing.expect(decoded.array_expr.elem.* == .prim);
    try testing.expect(decoded.array_expr.len.* == .call);
    try testing.expectEqualStrings("arrayLen", decoded.array_expr.len.call.callee.*.ident);
    try testing.expectEqual(@as(usize, 1), decoded.array_expr.len.call.args.len);
}

test "serialize: expression-sized arrays survive allocation failures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const encoded = try serialize.encodeType(arena.allocator(), .{
        .array_expr = .{
            .elem = &ast.Type{ .prim = .u8 },
            .len = &ast.Expr{ .call = .{
                .callee = &ast.Expr{ .ident = "arrayLen" },
                .args = &.{.{ .lit = .{ .int = 4 } }},
            } },
        },
    });
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkArrayExprTypeAllocations,
        .{encoded},
    );
}

test "serialize: nested expression-sized arrays roundtrip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const inner = ast.Type{ .array_expr = .{
        .elem = &ast.Type{ .prim = .u8 },
        .len = &ast.Expr{ .lit = .{ .int = 2 } },
    } };
    const outer = ast.Type{ .array_expr = .{
        .elem = &inner,
        .len = &ast.Expr{ .lit = .{ .int = 3 } },
    } };

    const decoded = try serialize.decodeType(
        arena.allocator(),
        try serialize.encodeType(arena.allocator(), outer),
    );
    try testing.expect(decoded == .array_expr);
    try testing.expect(decoded.array_expr.elem.* == .array_expr);
    try testing.expect(decoded.array_expr.elem.array_expr.elem.* == .prim);
    try testing.expect(decoded.array_expr.len.* == .lit);
    try testing.expectEqual(@as(i128, 3), decoded.array_expr.len.lit.int);
    try testing.expect(decoded.array_expr.elem.array_expr.len.* == .lit);
    try testing.expectEqual(@as(i128, 2), decoded.array_expr.elem.array_expr.len.lit.int);
}

test "serialize: for captures preserve pointer mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const encoded = try serialize.encodeExpr(arena.allocator(), .{
        .for_expr = .{
            .inputs = &.{.{ .ident = "items" }},
            .captures = &.{.{ .name = "item", .by_ref = true }},
            .body = .{
                .stmts = &.{.{ .expr_stmt = &ast.Expr{ .ident = "item" } }},
            },
        },
    });
    const captures = encoded.object.get("captures").?.array.items;
    try testing.expect(captures[0].object.get("by_ref").?.bool);

    const decoded = try serialize.decodeExpr(arena.allocator(), encoded);
    try testing.expect(decoded == .for_expr);
    try testing.expectEqual(@as(usize, 1), decoded.for_expr.captures.len);
    try testing.expectEqualStrings("item", decoded.for_expr.captures[0].name);
    try testing.expect(decoded.for_expr.captures[0].by_ref);
}

fn checkIfCaptureDecodeAllocations(allocator: std.mem.Allocator, value: std.json.Value) !void {
    const decoded = try serialize.decodeExpr(allocator, value);
    try testing.expect(decoded == .if_expr);
    defer {
        const if_expr = decoded.if_expr;
        allocator.free(if_expr.cond.*.ident);
        allocator.destroy(@constCast(if_expr.cond));
        allocator.free(if_expr.then_body.*.ident);
        allocator.destroy(@constCast(if_expr.then_body));
        allocator.free(if_expr.else_body.?.*.ident);
        allocator.destroy(@constCast(if_expr.else_body.?));
        allocator.free(if_expr.then_capture.?.name);
        allocator.free(if_expr.else_capture.?.name);
    }
    try testing.expectEqualStrings("maybe", decoded.if_expr.cond.*.ident);
    try testing.expectEqualStrings("ok", decoded.if_expr.then_capture.?.name);
    try testing.expect(!decoded.if_expr.then_capture.?.by_ref);
    try testing.expectEqualStrings("tag", decoded.if_expr.else_capture.?.name);
    try testing.expect(decoded.if_expr.else_capture.?.by_ref);
}

test "serialize: conditional captures keep both payloads and every allocation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const encoded = try serialize.encodeExpr(arena.allocator(), .{
        .if_expr = .{
            .cond = &ast.Expr{ .ident = "maybe" },
            .then_capture = .{ .name = "ok" },
            .then_body = &ast.Expr{ .ident = "ok" },
            .else_body = &ast.Expr{ .ident = "fallback" },
            .else_capture = .{ .name = "tag", .by_ref = true },
        },
    });
    const then_wire = encoded.object.get("then_capture").?.object;
    try testing.expectEqualStrings("ok", then_wire.get("name").?.string);
    try testing.expect(!then_wire.get("by_ref").?.bool);
    const else_wire = encoded.object.get("else_capture").?.object;
    try testing.expectEqualStrings("tag", else_wire.get("name").?.string);
    try testing.expect(else_wire.get("by_ref").?.bool);

    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkIfCaptureDecodeAllocations,
        .{encoded},
    );
}

test "serialize: an else capture without its branch is rejected" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"kind":"if_expr","cond":{"kind":"ident","name":"maybe"},"then_body":{"kind":"ident","name":"ok"},"else_body":null,"else_capture":{"name":"tag","by_ref":false}}
    ,
        .{},
    );
    defer parsed.deinit();

    try testing.expectError(
        error.BadWireFormat,
        serialize.decodeExpr(testing.allocator, parsed.value),
    );
}

test "serialize: a conditional without captures keeps the wire it had without them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // A plain conditional is the whole wire: no capture key appears at all, so
    // a sidecar written before payloads existed still describes it exactly.
    const encoded = try serialize.encodeExpr(arena.allocator(), .{
        .if_expr = .{
            .cond = &ast.Expr{ .ident = "maybe" },
            .then_body = &ast.Expr{ .ident = "ok" },
            .else_body = &ast.Expr{ .ident = "fallback" },
        },
    });
    try testing.expect(encoded.object.get("then_capture") == null);
    try testing.expect(encoded.object.get("else_capture") == null);

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"kind":"if_expr","cond":{"kind":"ident","name":"maybe"},"then_body":{"kind":"ident","name":"ok"},"else_body":{"kind":"ident","name":"fallback"}}
    ,
        .{},
    );
    defer parsed.deinit();

    const decoded = try serialize.decodeExpr(arena.allocator(), parsed.value);
    try testing.expect(decoded.if_expr.then_capture == null);
    try testing.expect(decoded.if_expr.else_capture == null);
    try testing.expectEqualStrings("maybe", decoded.if_expr.cond.*.ident);
    try testing.expectEqualStrings("ok", decoded.if_expr.then_body.*.ident);
    try testing.expectEqualStrings("fallback", decoded.if_expr.else_body.?.*.ident);
}

fn expectRangePatternEqual(expected: ast.Pattern, actual: ast.Pattern) !void {
    try testing.expect(actual == .range_pat);
    try testing.expectEqual(expected.range_pat.inclusive, actual.range_pat.inclusive);
    try testing.expectEqual(expected.range_pat.lo != null, actual.range_pat.lo != null);
    try testing.expectEqual(expected.range_pat.hi != null, actual.range_pat.hi != null);
    if (expected.range_pat.lo) |lo| {
        try testing.expectEqual(lo, actual.range_pat.lo.?);
    }
    if (expected.range_pat.hi) |hi| {
        try testing.expectEqual(hi, actual.range_pat.hi.?);
    }
}

test "serialize: range patterns roundtrip through JSON text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const patterns = [_]ast.Pattern{
        .{ .range_pat = .{ .lo = .{ .int = 65 }, .hi = .{ .int = 70 }, .inclusive = true } },
        .{ .range_pat = .{ .lo = .{ .char_lit = 'A' }, .hi = .{ .char_lit = 'F' }, .inclusive = true } },
        .{ .range_pat = .{ .lo = null, .hi = .{ .uint = 9 }, .inclusive = true } },
        .{ .range_pat = .{ .lo = .{ .char_lit = 'a' }, .hi = null, .inclusive = false } },
        .{ .range_pat = .{ .lo = null, .hi = null, .inclusive = false } },
        .{ .range_pat = .{} },
    };

    for (patterns) |original| {
        const encoded = try serialize.encodePattern(allocator, original);
        try testing.expectEqualStrings("range_pat", encoded.object.get("kind").?.string);

        // Full text round trip: value -> text -> value -> pattern.
        const text = try std.json.Stringify.valueAlloc(allocator, encoded, .{});
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
        defer parsed.deinit();

        const decoded = try serialize.decodePattern(allocator, parsed.value);
        try expectRangePatternEqual(original, decoded);
    }
}

test "serialize: range pattern bounds are encoded as literals or null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // `char_lit` bounds keep a JSON integer, `int` bounds are stringified.
    const encoded = try serialize.encodePattern(allocator, .{
        .range_pat = .{ .lo = null, .hi = .{ .char_lit = 'F' }, .inclusive = false },
    });

    const object = encoded.object;
    try testing.expect(object.get("lo").? == .null);
    try testing.expectEqualStrings("char_lit", object.get("hi").?.object.get("kind").?.string);
    try testing.expectEqual(@as(i64, 'F'), object.get("hi").?.object.get("value").?.integer);
    try testing.expect(!object.get("inclusive").?.bool);

    const wide = try serialize.encodePattern(allocator, .{
        .range_pat = .{ .lo = .{ .int = 0 }, .hi = .{ .uint = 9 }, .inclusive = true },
    });
    try testing.expectEqualStrings("0", wide.object.get("lo").?.object.get("value").?.string);
    try testing.expectEqualStrings("9", wide.object.get("hi").?.object.get("value").?.string);
    try testing.expect(wide.object.get("inclusive").?.bool);
}

test "serialize: range patterns survive inside match arms" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const original = ast.Pattern{ .range_pat = .{
        .lo = .{ .char_lit = '0' },
        .hi = .{ .char_lit = '9' },
        .inclusive = true,
    } };
    const encoded = try serialize.encodeExpr(allocator, .{
        .match_expr = .{
            .target = &ast.Expr{ .ident = "c" },
            .arms = &.{
                .{ .patterns = &.{original}, .body = .{ .ident = "digit" } },
                .{
                    .patterns = &.{.{ .range_pat = .{
                        .lo = .{ .char_lit = 'A' },
                        .hi = null,
                        .inclusive = false,
                    } }},
                    .body = .{ .ident = "letter" },
                },
            },
        },
    });

    const decoded = try serialize.decodeExpr(allocator, encoded);
    try testing.expect(decoded == .match_expr);
    try testing.expectEqual(@as(usize, 2), decoded.match_expr.arms.len);
    try expectRangePatternEqual(original, decoded.match_expr.arms[0].patterns[0]);
    try expectRangePatternEqual(
        .{ .range_pat = .{ .lo = .{ .char_lit = 'A' }, .hi = null, .inclusive = false } },
        decoded.match_expr.arms[1].patterns[0],
    );
}

fn checkRangePatternDecodeAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodePattern(allocator, value);
    if (decoded.range_pat.lo) |lo| allocator.free(lo.str);
    if (decoded.range_pat.hi) |hi| allocator.free(hi.str);
}

test "serialize: range pattern string bounds survive allocation failures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const encoded = try serialize.encodePattern(arena.allocator(), .{
        .range_pat = .{
            .lo = .{ .str = "lower" },
            .hi = .{ .str = "upper" },
            .inclusive = true,
        },
    });
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkRangePatternDecodeAllocations,
        .{encoded},
    );
}

const MalformedRangePattern = struct {
    json: []const u8,
    expected: anyerror,
};

test "serialize: malformed range pattern payloads are rejected" {
    const cases = [_]MalformedRangePattern{
        .{
            .json =
            \\{"kind":"range_pat","lo":5,"hi":null,"inclusive":true}
            ,
            .expected = error.BadWireFormat,
        },
        .{
            .json =
            \\{"kind":"range_pat","lo":null,"hi":null,"inclusive":"yes"}
            ,
            .expected = error.BadWireFormat,
        },
        .{
            .json =
            \\{"kind":"range_pat","lo":null,"hi":{"kind":"nope"},"inclusive":true}
            ,
            .expected = error.UnknownLiteralKind,
        },
        .{
            .json =
            \\{"kind":"range_pat","lo":{"kind":"int"},"inclusive":true}
            ,
            .expected = error.MissingField,
        },
        // A misspelled discriminator is an unknown pattern kind, not a
        // range_pat with defaults.
        .{
            .json =
            \\{"kind":"range","lo":null,"hi":null,"inclusive":true}
            ,
            .expected = error.UnknownPatternKind,
        },
    };

    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            testing.allocator,
            case.json,
            .{},
        );
        defer parsed.deinit();
        try testing.expectError(
            case.expected,
            serialize.decodePattern(testing.allocator, parsed.value),
        );
    }
}

// ---------------------------------------------------------------------------
// `[e; N]` repeat counts
// ---------------------------------------------------------------------------
//
// Preserve full-width counts in both array types and repeat expressions.
// Counts beyond i64 can describe valid zero-sized Rust arrays, and the widest
// count is `u64`max on every host: a count sizes the target's array, not the
// translator's own address space, so none of these are filtered or skipped on
// a 32-bit build.

// Keep boundary counts as native JSON numbers.
const i64_range_counts = [_]u64{
    0, // an empty repeat is a legal count, not an absent one
    4294967295, // u32::MAX
    4294967296, // 2^32, first count wider than a32-bit host
    9007199254740993, // 2^53 + 1, first count f64 rounds
    9223372036854775807, // i64::MAX
};

// Signed boundary, floating-point precision, and unsigned maximum.
const above_i64_counts = [_]u64{
    9223372036854775808, // 2^63
    9223372036854775809, // 2^63 + 1
    18446744073709551615, // u64::MAX
};

/// Exercise repeats with and without an explicit element type.
/// Returned file and declaration slices must outlive this helper.
fn repeatCountPackage(
    allocator: std.mem.Allocator,
    n: u64,
    fill: ast.Expr,
) !ast.Package {
    const u8_ty = try allocator.create(ast.Type);
    u8_ty.* = .{ .prim = .u8 };
    const fill_node = try allocator.create(ast.Expr);
    fill_node.* = fill;
    const filled_body = try allocator.create(ast.Expr);
    filled_body.* = .{ .repeat = .{ .type_name = u8_ty.*, .elem = fill_node, .len = n } };

    const no_elements: []const ast.Type = &.{};
    const unit_ty = try allocator.create(ast.Type);
    unit_ty.* = .{ .tuple = no_elements };
    const unit = try allocator.create(ast.Expr);
    unit.* = .unit;
    const zeros_body = try allocator.create(ast.Expr);
    zeros_body.* = .{ .repeat = .{ .type_name = null, .elem = unit, .len = n } };

    const decls = try allocator.alloc(ast.Decl, 2);
    decls[0] = .{ .fn_decl = .{
        .name = "filled",
        .ret_type = .{ .array = .{ .elem = u8_ty, .len = n } },
        .body = .{ .expr = filled_body },
    } };
    decls[1] = .{ .fn_decl = .{
        .name = "zeros",
        .ret_type = .{ .array = .{ .elem = unit_ty, .len = n } },
        .body = .{ .expr = zeros_body },
    } };

    const files = try allocator.alloc(ast.File, 1);
    files[0] = .{ .path = "src/root.zig", .decls = decls };

    return .{ .name = "repeat_counts", .files = files };
}

/// Read the counts back out of the encoded bytes with a real JSON parser and
/// require each one to still be a JSON integer. A quoted string would change
/// the wire format, and a float would round the counts above 2^53.
fn expectCountsAreJsonIntegers(
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
    n: u64,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    // Only counts an `i64` holds keep the plain JSON integer spelling; a
    // wider one rides as a `number_string` and is checked by the roundtrip.
    const expected = std.math.cast(i64, n) orelse return error.BadWireFormat;
    const files = parsed.value.object.get("files").?.array.items;
    // One file holding the two repeat shapes, not two files.
    try testing.expectEqual(@as(usize, 1), files.len);
    for (files) |file_v| {
        const decls = file_v.object.get("decls").?.array.items;
        try testing.expectEqual(@as(usize, 2), decls.len);
        for (decls) |decl_v| {
            const fn_v = decl_v.object.get("value").?.object;

            const ret_v = fn_v.get("ret_type").?;
            try testing.expectEqualStrings("array", ret_v.object.get("kind").?.string);
            const type_len = ret_v.object.get("len").?;
            try testing.expect(type_len == .integer);
            try testing.expectEqual(expected, type_len.integer);

            const repeat_v = fn_v.get("body").?.object.get("expr").?;
            try testing.expectEqualStrings("repeat", repeat_v.object.get("kind").?.string);
            const repeat_len = repeat_v.object.get("len").?;
            try testing.expect(repeat_len == .integer);
            try testing.expectEqual(expected, repeat_len.integer);
        }
    }
}

fn expectFilledRepeatDecl(decl: ast.Decl, n: u64) !void {
    try testing.expect(decl == .fn_decl);
    const fn_decl = decl.fn_decl;
    try testing.expectEqualStrings("filled", fn_decl.name);

    try testing.expect(fn_decl.ret_type == .array);
    try testing.expectEqual(n, fn_decl.ret_type.array.len);
    try testing.expect(fn_decl.ret_type.array.elem.* == .prim);
    try testing.expectEqual(ast.Prim.u8, fn_decl.ret_type.array.elem.*.prim);

    const repeat = fn_decl.body.?.expr.?.*;
    try testing.expect(repeat == .repeat);
    try testing.expectEqual(n, repeat.repeat.len);
    try testing.expect(repeat.repeat.type_name.? == .prim);
    try testing.expectEqual(ast.Prim.u8, repeat.repeat.type_name.?.prim);
    try testing.expect(repeat.repeat.elem.* == .lit);
    try testing.expectEqual(@as(u128, 7), repeat.repeat.elem.*.lit.uint);
}

fn expectZerosRepeatDecl(decl: ast.Decl, n: u64) !void {
    try testing.expect(decl == .fn_decl);
    const fn_decl = decl.fn_decl;
    try testing.expectEqualStrings("zeros", fn_decl.name);

    try testing.expect(fn_decl.ret_type == .array);
    try testing.expectEqual(n, fn_decl.ret_type.array.len);
    try testing.expect(fn_decl.ret_type.array.elem.* == .tuple);
    try testing.expectEqual(@as(usize, 0), fn_decl.ret_type.array.elem.*.tuple.len);

    const repeat = fn_decl.body.?.expr.?.*;
    try testing.expect(repeat == .repeat);
    try testing.expectEqual(n, repeat.repeat.len);
    try testing.expect(repeat.repeat.type_name == null);
    try testing.expect(repeat.repeat.elem.* == .unit);
}

/// Encode a package and require the decoded repeat literals, their element
/// types and their array types to come back with `n` unchanged. Returns the
/// encoded bytes so a caller can also read the counts off the wire.
fn expectRepeatCountRoundtrip(
    allocator: std.mem.Allocator,
    pkg: *const ast.Package,
    n: u64,
) ![]const u8 {
    const json_bytes = try serialize.encode(allocator, pkg);

    const decoded = try serialize.decode(allocator, json_bytes);
    try testing.expectEqual(@as(usize, 1), decoded.files.len);
    const decls = decoded.files[0].decls;
    try testing.expectEqual(@as(usize, 2), decls.len);
    try expectFilledRepeatDecl(decls[0], n);
    try expectZerosRepeatDecl(decls[1], n);
    return json_bytes;
}

test "serialize: repeat counts an i64 holds keep an exact numeric wire form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for (i64_range_counts) |n| {
        const pkg = try repeatCountPackage(allocator, n, .{ .lit = .{ .uint = 7 } });
        const json_bytes = try expectRepeatCountRoundtrip(allocator, &pkg, n);
        try expectCountsAreJsonIntegers(allocator, json_bytes, n);
    }
}

test "serialize: repeat counts wider than i64 roundtrip exactly and are released" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for (above_i64_counts) |n| {
        const pkg = try repeatCountPackage(allocator, n, .{ .lit = .{ .uint = 7 } });
        _ = try expectRepeatCountRoundtrip(allocator, &pkg, n);
    }

    // Non-allocating element encoding isolates ownership of wide count text.
    // The checked allocator must see all temporary count text released.
    const n = above_i64_counts[above_i64_counts.len - 1];
    const pkg = try repeatCountPackage(allocator, n, .{ .ident = "seed" });
    const json_bytes = try serialize.encode(testing.allocator, &pkg);
    testing.allocator.free(json_bytes);
}

test "serialize: negative array and repeat counts are rejected without leaks" {
    var array = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"kind":"array","elem":{"kind":"named","name":"OwnedArrayElement"},"len":-1}
    ,
        .{},
    );
    defer array.deinit();
    try testing.expectError(
        error.BadWireFormat,
        serialize.decodeType(testing.allocator, array.value),
    );

    var repeat = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"kind":"repeat","type_name":{"kind":"named","name":"OwnedRepeatType"},"elem":{"kind":"ident","name":"OwnedRepeatedElement"},"len":-1}
    ,
        .{},
    );
    defer repeat.deinit();
    try testing.expectError(
        error.BadWireFormat,
        serialize.decodeExpr(testing.allocator, repeat.value),
    );
}

test "serialize: array and repeat counts past u64 are rejected without leaks" {
    var array = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"kind":"array","elem":{"kind":"named","name":"OwnedArrayElement"},"len":18446744073709551616}
    ,
        .{ .parse_numbers = false },
    );
    defer array.deinit();
    try testing.expectError(
        error.BadWireFormat,
        serialize.decodeType(testing.allocator, array.value),
    );

    var repeat = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"kind":"repeat","type_name":{"kind":"named","name":"OwnedRepeatType"},"elem":{"kind":"ident","name":"OwnedRepeatedElement"},"len":18446744073709551616}
    ,
        .{ .parse_numbers = false },
    );
    defer repeat.deinit();
    try testing.expectError(
        error.BadWireFormat,
        serialize.decodeExpr(testing.allocator, repeat.value),
    );
}

test "serialize: a type value carries its type on the wire" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const byte = ast.Type{ .prim = .u8 };
    const encoded = try serialize.encodeExpr(allocator, .{ .type_value = .{ .ptr = .{
        .elem = &byte,
        .is_const = true,
        .size = .c,
    } } });

    try testing.expectEqualStrings("type_value", encoded.object.get("kind").?.string);
    // The type rides the existing type codec: no second spelling of a pointer.
    const wire = encoded.object.get("ty").?.object;
    try testing.expectEqualStrings("ptr", wire.get("kind").?.string);
    try testing.expectEqualStrings("c", wire.get("size").?.string);
    try testing.expect(wire.get("is_const").?.bool);
    try testing.expectEqualStrings("u8", wire.get("elem").?.object.get("value").?.string);

    const decoded = try serialize.decodeExpr(allocator, encoded);
    try testing.expect(decoded == .type_value);
    try testing.expect(decoded.type_value == .ptr);
    try testing.expectEqual(ast.PtrSize.c, decoded.type_value.ptr.size);
    try testing.expect(decoded.type_value.ptr.is_const);
    try testing.expectEqual(ast.Prim.u8, decoded.type_value.ptr.elem.prim);
}

test "serialize: a nested type value roundtrips through the type codec" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const byte = ast.Type{ .prim = .u8 };
    const rows = ast.Type{ .slice = .{ .elem = &byte, .is_const = true } };
    const decoded = try serialize.decodeExpr(
        allocator,
        try serialize.encodeExpr(allocator, .{ .type_value = .{ .opt = &rows } }),
    );
    try testing.expect(decoded == .type_value);
    try testing.expect(decoded.type_value == .opt);
    try testing.expect(decoded.type_value.opt.* == .slice);
    try testing.expect(decoded.type_value.opt.slice.is_const);
    try testing.expect(decoded.type_value.opt.slice.elem.* == .prim);
    try testing.expectEqual(ast.Prim.u8, decoded.type_value.opt.slice.elem.prim);
}

fn checkTypeValueDecodeAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeExpr(allocator, value);
    // `freeDecodedExpr` hands the embedded type to `freeDecodedType`; the test
    // releases the same pointee box so the checked allocator sees every byte.
    defer allocator.destroy(@constCast(decoded.type_value.ptr.elem));
    try testing.expect(decoded == .type_value);
    try testing.expect(decoded.type_value == .ptr);
    try testing.expectEqual(ast.PtrSize.c, decoded.type_value.ptr.size);
    try testing.expect(decoded.type_value.ptr.is_const);
    try testing.expectEqual(ast.Prim.u8, decoded.type_value.ptr.elem.prim);
}

test "serialize: a pointer alias survives allocation failures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const byte = ast.Type{ .prim = .u8 };
    const encoded = try serialize.encodeExpr(arena.allocator(), .{ .type_value = .{ .ptr = .{
        .elem = &byte,
        .is_const = true,
        .size = .c,
    } } });
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkTypeValueDecodeAllocations,
        .{encoded},
    );
}

/// Release the boxed type trees the documentation fixtures decode: `opt`,
/// `slice` and `ptr` each own one element box, `named` owns a duplicated name.
fn freeFixtureType(allocator: std.mem.Allocator, ty: ast.Type) void {
    switch (ty) {
        .opt => |elem| {
            freeFixtureType(allocator, elem.*);
            allocator.destroy(@constCast(elem));
        },
        .slice => |slice| {
            freeFixtureType(allocator, slice.elem.*);
            allocator.destroy(@constCast(slice.elem));
        },
        .ptr => |ptr| {
            freeFixtureType(allocator, ptr.elem.*);
            allocator.destroy(@constCast(ptr.elem));
        },
        .named => |name| allocator.free(name),
        // An expression-typed descriptor is a whole tree, so it is released
        // through the recursive expression helper rather than this file's
        // deliberately narrow `freeFixtureExpr`.
        .expr => |expr| {
            freeRollbackFixtureExpr(allocator, expr.*);
            allocator.destroy(@constCast(expr));
        },
        else => {},
    }
}

/// Release the expression shapes the documentation fixtures decode.
fn freeFixtureExpr(allocator: std.mem.Allocator, expr: ast.Expr) void {
    switch (expr) {
        .ident => |name| allocator.free(name),
        .lit => |literal| switch (literal) {
            .str => |text| allocator.free(text),
            else => {},
        },
        else => {},
    }
}

fn freeFixtureStmt(allocator: std.mem.Allocator, stmt: ast.Stmt) void {
    switch (stmt) {
        .let_stmt => |let_stmt| {
            allocator.free(let_stmt.name);
            if (let_stmt.ty) |ty| freeFixtureType(allocator, ty);
            freeFixtureExpr(allocator, let_stmt.init);
        },
        .assign => |assign| {
            freeFixtureExpr(allocator, assign.target);
            freeFixtureExpr(allocator, assign.val);
        },
        .defer_stmt => |defer_stmt| freeFixtureExpr(allocator, defer_stmt.expr),
        .expr_stmt => |expr| {
            freeFixtureExpr(allocator, expr.*);
            allocator.destroy(@constCast(expr));
        },
    }
}

fn checkStructFieldDecodeAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeStructField(allocator, value);
    defer {
        allocator.free(decoded.name);
        allocator.free(decoded.documentation);
        freeFixtureType(allocator, decoded.ty);
        freeFixtureExpr(allocator, decoded.default_val.?.*);
        allocator.destroy(@constCast(decoded.default_val.?));
    }
    try testing.expectEqualStrings("Where writes land.", decoded.documentation);
    try testing.expectEqualStrings("target", decoded.name);
    try testing.expect(decoded.ty == .opt);
    try testing.expect(decoded.ty.opt.* == .slice);
    try testing.expect(decoded.ty.opt.slice.is_const);
    try testing.expectEqual(ast.Prim.u8, decoded.ty.opt.slice.elem.prim);
    try testing.expectEqualStrings("NONE", decoded.default_val.?.ident);
}

test "serialize: a documented struct field releases every allocation on failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The field owns a nested optional slice type and a default expression, so
    // a failure anywhere past the type has real bytes to unwind.
    const byte = ast.Type{ .prim = .u8 };
    const slice_ty = ast.Type{ .slice = .{ .elem = &byte, .is_const = true } };
    const default_val = ast.Expr{ .ident = "NONE" };
    const encoded = try serialize.encodeStructField(arena.allocator(), .{
        .name = "target",
        .ty = .{ .opt = &slice_ty },
        .default_val = &default_val,
        .documentation = "Where writes land.",
    });

    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkStructFieldDecodeAllocations,
        .{encoded},
    );
}

fn checkEnumVariantDecodeAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeEnumVariant(allocator, value);
    defer {
        allocator.free(decoded.name);
        allocator.free(decoded.documentation);
        freeFixtureExpr(allocator, decoded.value.?.*);
        allocator.destroy(@constCast(decoded.value.?));
    }
    try testing.expectEqualStrings("Not started.", decoded.documentation);
    try testing.expectEqualStrings("Idle", decoded.name);
    try testing.expectEqualStrings("Idle_code", decoded.value.?.ident);
}

test "serialize: a documented enum tag releases every allocation on failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const discriminant = ast.Expr{ .ident = "Idle_code" };
    const encoded = try serialize.encodeEnumVariant(arena.allocator(), .{
        .name = "Idle",
        .value = &discriminant,
        .documentation = "Not started.",
    });

    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkEnumVariantDecodeAllocations,
        .{encoded},
    );
}

fn checkUnionFieldDecodeAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeUnionField(allocator, value);
    defer {
        allocator.free(decoded.name);
        allocator.free(decoded.documentation);
        freeFixtureType(allocator, decoded.ty);
    }
    try testing.expectEqualStrings("Where bytes originate.", decoded.documentation);
    try testing.expectEqualStrings("source", decoded.name);
    try testing.expect(decoded.ty == .opt);
    try testing.expect(decoded.ty.opt.* == .ptr);
    try testing.expect(decoded.ty.opt.ptr.is_const);
    try testing.expectEqualStrings("Source", decoded.ty.opt.ptr.elem.named);
}

test "serialize: a documented union field releases every allocation on failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const named_ty = ast.Type{ .named = "Source" };
    const ptr_ty = ast.Type{ .ptr = .{ .elem = &named_ty, .is_const = true, .size = .c } };
    const encoded = try serialize.encodeUnionField(arena.allocator(), .{
        .name = "source",
        .ty = .{ .opt = &ptr_ty },
        .documentation = "Where bytes originate.",
    });

    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkUnionFieldDecodeAllocations,
        .{encoded},
    );
}

fn checkFnDeclDecodeAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeDecl(allocator, value);
    try testing.expect(decoded == .fn_decl);
    const fn_decl = decoded.fn_decl;
    defer {
        allocator.free(fn_decl.name);
        allocator.free(fn_decl.documentation);
        for (fn_decl.params) |param| {
            allocator.free(param.name);
            freeFixtureType(allocator, param.ty);
        }
        allocator.free(fn_decl.params);
        freeFixtureType(allocator, fn_decl.ret_type);
        const body = fn_decl.body.?;
        allocator.free(body.label.?);
        for (body.stmts) |stmt| freeFixtureStmt(allocator, stmt);
        allocator.free(body.stmts);
        for (fn_decl.generic_params) |param| {
            allocator.free(param.name);
            freeFixtureType(allocator, param.ty.?);
        }
        allocator.free(fn_decl.generic_params);
    }
    try testing.expectEqualStrings("Applies a patch.", fn_decl.documentation);
    try testing.expectEqualStrings("apply", fn_decl.name);
    try testing.expectEqual(@as(usize, 1), fn_decl.params.len);
    try testing.expectEqualStrings("input", fn_decl.params[0].name);
    try testing.expect(fn_decl.params[0].ty == .opt);
    try testing.expect(fn_decl.params[0].ty.opt.* == .ptr);
    try testing.expectEqual(ast.Prim.u8, fn_decl.params[0].ty.opt.ptr.elem.prim);
    try testing.expect(fn_decl.ret_type == .opt);
    try testing.expectEqual(ast.Prim.u8, fn_decl.ret_type.opt.prim);
    try testing.expectEqualStrings("outer", fn_decl.body.?.label.?);
    try testing.expectEqual(@as(usize, 4), fn_decl.body.?.stmts.len);
    try testing.expectEqual(@as(usize, 1), fn_decl.generic_params.len);
    try testing.expectEqualStrings("T", fn_decl.generic_params[0].name);
    try testing.expectEqualStrings("T", fn_decl.generic_params[0].ty.?.opt.ptr.elem.named);
}

test "serialize: a documented function releases params, generics and body on failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const byte = ast.Type{ .prim = .u8 };
    const param_ptr = ast.Type{ .ptr = .{ .elem = &byte, .is_const = true, .size = .c } };
    const param_ty = ast.Type{ .opt = &param_ptr };
    const ret_ty = ast.Type{ .opt = &byte };
    const let_ty = ast.Type{ .opt = &byte };
    const name_ty = ast.Type{ .named = "T" };
    const generic_ptr = ast.Type{ .ptr = .{ .elem = &name_ty, .is_const = true, .size = .c } };
    const generic_ty = ast.Type{ .opt = &generic_ptr };
    const total_ident = ast.Expr{ .ident = "total" };
    const seed_ident = ast.Expr{ .ident = "seed" };
    const cleanup_ident = ast.Expr{ .ident = "cleanup" };
    const trailing = ast.Expr{ .lit = .{ .str = "done" } };
    const body_label: []const u8 = "outer";
    const encoded = try serialize.encodeDecl(arena.allocator(), .{ .fn_decl = .{
        .name = "apply",
        .params = &.{.{ .name = "input", .ty = param_ty }},
        .ret_type = ret_ty,
        .body = .{
            .label = body_label,
            .stmts = &.{
                .{ .let_stmt = .{
                    .name = "total",
                    .ty = let_ty,
                    .init = seed_ident,
                    .is_mut = true,
                } },
                .{ .assign = .{ .target = total_ident, .val = seed_ident } },
                .{ .defer_stmt = .{ .expr = cleanup_ident } },
                .{ .expr_stmt = &trailing },
            },
        },
        .generic_params = &.{.{ .name = "T", .is_comptime = true, .ty = generic_ty }},
        .documentation = "Applies a patch.",
    } });

    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkFnDeclDecodeAllocations,
        .{encoded},
    );
}

fn checkConstDeclDecodeAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeDecl(allocator, value);
    try testing.expect(decoded == .const_decl);
    const const_decl = decoded.const_decl;
    defer {
        allocator.free(const_decl.name);
        allocator.free(const_decl.documentation);
        freeFixtureType(allocator, const_decl.ty.?);
        freeFixtureExpr(allocator, const_decl.init);
    }
    try testing.expectEqualStrings("Never exceeded.", const_decl.documentation);
    try testing.expectEqualStrings("LIMIT", const_decl.name);
    try testing.expect(const_decl.ty.? == .ptr);
    try testing.expect(const_decl.ty.?.ptr.is_const);
    try testing.expectEqualStrings("Buf", const_decl.ty.?.ptr.elem.named);
    try testing.expectEqualStrings("limit_default", const_decl.init.ident);
}

test "serialize: a documented constant releases its type, init and doc on failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const named_ty = ast.Type{ .named = "Buf" };
    const const_ty = ast.Type{ .ptr = .{ .elem = &named_ty, .is_const = true, .size = .c } };
    const init = ast.Expr{ .ident = "limit_default" };
    const encoded = try serialize.encodeDecl(arena.allocator(), .{ .const_decl = .{
        .name = "LIMIT",
        .ty = const_ty,
        .init = init,
        .documentation = "Never exceeded.",
    } });

    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkConstDeclDecodeAllocations,
        .{encoded},
    );
}

fn checkVarDeclDecodeAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeDecl(allocator, value);
    try testing.expect(decoded == .var_decl);
    const var_decl = decoded.var_decl;
    defer {
        allocator.free(var_decl.name);
        allocator.free(var_decl.documentation);
        freeFixtureType(allocator, var_decl.ty.?);
        freeFixtureExpr(allocator, var_decl.init);
    }
    try testing.expectEqualStrings("Reusable storage.", var_decl.documentation);
    try testing.expectEqualStrings("scratch", var_decl.name);
    try testing.expect(var_decl.ty.? == .slice);
    try testing.expect(!var_decl.ty.?.slice.is_const);
    try testing.expectEqual(ast.Prim.u8, var_decl.ty.?.slice.elem.prim);
    try testing.expectEqualStrings("scratch buffer", var_decl.init.lit.str);
}

test "serialize: a documented variable releases its type, init and doc on failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const byte = ast.Type{ .prim = .u8 };
    const var_ty = ast.Type{ .slice = .{ .elem = &byte } };
    const init = ast.Expr{ .lit = .{ .str = "scratch buffer" } };
    const encoded = try serialize.encodeDecl(arena.allocator(), .{ .var_decl = .{
        .name = "scratch",
        .ty = var_ty,
        .init = init,
        .documentation = "Reusable storage.",
    } });

    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkVarDeclDecodeAllocations,
        .{encoded},
    );
}

/// A documentation key that is neither a string nor null is rejected once the
/// name, type and value beside it are already owned.
const MalformedDocumentation = struct {
    node: enum { struct_field, enum_variant, union_field, decl },
    json: []const u8,
};

test "serialize: malformed documentation frees what the field decoded before it" {
    const cases = [_]MalformedDocumentation{
        .{ .node = .struct_field, .json =
        \\{"name":"target",
        \\ "ty":{"kind":"opt","elem":{"kind":"prim","value":"u8"}},
        \\ "default_val":{"kind":"ident","name":"NONE"},
        \\ "is_pub":true,
        \\ "documentation":42}
        },
        .{ .node = .enum_variant, .json =
        \\{"name":"Idle",
        \\ "value":{"kind":"ident","name":"Idle_code"},
        \\ "documentation":42}
        },
        .{ .node = .union_field, .json =
        \\{"name":"source",
        \\ "ty":{"kind":"opt","elem":{"kind":"named","name":"Source"}},
        \\ "is_pub":true,
        \\ "documentation":42}
        },
        .{ .node = .decl, .json =
        \\{"kind":"fn_decl",
        \\ "value":{"name":"apply",
        \\  "params":[{"name":"input",
        \\            "ty":{"kind":"opt","elem":{"kind":"prim","value":"u8"}}}],
        \\  "ret_type":{"kind":"prim","value":"void_type"},
        \\  "body":null,
        \\  "documentation":42}}
        },
        .{ .node = .decl, .json =
        \\{"kind":"const_decl",
        \\ "value":{"name":"LIMIT",
        \\  "ty":{"kind":"opt","elem":{"kind":"named","name":"Buf"}},
        \\  "init":{"kind":"ident","name":"limit_default"},
        \\  "documentation":42}}
        },
        .{ .node = .decl, .json =
        \\{"kind":"var_decl",
        \\ "value":{"name":"scratch","is_pub":true,"is_mut":true,
        \\  "ty":{"kind":"slice","elem":{"kind":"prim","value":"u8"},"is_const":false},
        \\  "init":{"kind":"ident","name":"scratch_default"},
        \\  "documentation":42}}
        },
    };

    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            testing.allocator,
            case.json,
            .{},
        );
        defer parsed.deinit();
        switch (case.node) {
            .struct_field => try testing.expectError(
                error.BadWireFormat,
                serialize.decodeStructField(testing.allocator, parsed.value),
            ),
            .enum_variant => try testing.expectError(
                error.BadWireFormat,
                serialize.decodeEnumVariant(testing.allocator, parsed.value),
            ),
            .union_field => try testing.expectError(
                error.BadWireFormat,
                serialize.decodeUnionField(testing.allocator, parsed.value),
            ),
            .decl => try testing.expectError(
                error.BadWireFormat,
                serialize.decodeDecl(testing.allocator, parsed.value),
            ),
        }
    }
}

/// Release the type shapes the rollback fixtures decode: an owned name, or a
/// box pointing at one.
fn freeRollbackFixtureType(allocator: std.mem.Allocator, ty: ast.Type) void {
    switch (ty) {
        .named => |name| allocator.free(name),
        .opt => |elem| {
            freeRollbackFixtureType(allocator, elem.*);
            allocator.destroy(@constCast(elem));
        },
        .array => |array| {
            freeRollbackFixtureType(allocator, array.elem.*);
            allocator.destroy(@constCast(array.elem));
        },
        .ptr => |ptr| {
            freeRollbackFixtureType(allocator, ptr.elem.*);
            allocator.destroy(@constCast(ptr.elem));
        },
        .slice => |slice| {
            freeRollbackFixtureType(allocator, slice.elem.*);
            allocator.destroy(@constCast(slice.elem));
        },
        .err_union => |err_union| {
            if (err_union.err_set) |err_set| allocator.free(err_set);
            freeRollbackFixtureType(allocator, err_union.payload.*);
            allocator.destroy(@constCast(err_union.payload));
        },
        .tuple => |elements| {
            for (elements) |element| freeRollbackFixtureType(allocator, element);
            if (elements.len != 0) allocator.free(elements);
        },
        .anon_struct => |anon_struct| {
            for (anon_struct.fields) |field| {
                allocator.free(field.name);
                freeRollbackFixtureType(allocator, field.ty);
                if (field.default_val) |value| {
                    freeRollbackFixtureExpr(allocator, value.*);
                    allocator.destroy(@constCast(value));
                }
                if (field.documentation.len != 0) allocator.free(field.documentation);
            }
            if (anon_struct.fields.len != 0) allocator.free(anon_struct.fields);
        },
        .expr => |expr| {
            freeRollbackFixtureExpr(allocator, expr.*);
            allocator.destroy(@constCast(expr));
        },
        else => {},
    }
}

/// Release the expression shapes the rollback fixtures decode: a decoded
/// expression owns every name, box and slice below it.
fn freeRollbackFixtureExpr(allocator: std.mem.Allocator, expr: ast.Expr) void {
    switch (expr) {
        .ident, .panic_, .unsupported => |name| allocator.free(name),
        .lit => |literal| switch (literal) {
            .str, .error_tag => |text| allocator.free(text),
            else => {},
        },
        .field_access => |access| {
            freeRollbackFixtureExpr(allocator, access.target.*);
            allocator.destroy(@constCast(access.target));
            allocator.free(access.field_name);
        },
        .call => |call| {
            freeRollbackFixtureExpr(allocator, call.callee.*);
            allocator.destroy(@constCast(call.callee));
            for (call.generic_args) |argument| freeRollbackFixtureType(allocator, argument);
            if (call.generic_args.len != 0) allocator.free(call.generic_args);
            for (call.args) |arg| freeRollbackFixtureExpr(allocator, arg);
            if (call.args.len != 0) allocator.free(call.args);
        },
        .bin_op => |bin_op| {
            freeRollbackFixtureExpr(allocator, bin_op.lhs.*);
            allocator.destroy(@constCast(bin_op.lhs));
            freeRollbackFixtureExpr(allocator, bin_op.rhs.*);
            allocator.destroy(@constCast(bin_op.rhs));
        },
        .unary_op => |unary_op| {
            freeRollbackFixtureExpr(allocator, unary_op.operand.*);
            allocator.destroy(@constCast(unary_op.operand));
        },
        .struct_init => |struct_init| {
            if (struct_init.type_name) |type_name| freeRollbackFixtureType(allocator, type_name);
            for (struct_init.fields) |field| {
                allocator.free(field.name);
                freeRollbackFixtureExpr(allocator, field.expr);
            }
            if (struct_init.fields.len != 0) allocator.free(struct_init.fields);
        },
        .array_init => |array_init| {
            if (array_init.type_name) |type_name| freeRollbackFixtureType(allocator, type_name);
            for (array_init.elements) |element| freeRollbackFixtureExpr(allocator, element);
            if (array_init.elements.len != 0) allocator.free(array_init.elements);
        },
        .multi_array => |multi_array| {
            if (multi_array.type_name) |type_name| freeRollbackFixtureType(allocator, type_name);
            for (multi_array.elements) |element| freeRollbackFixtureExpr(allocator, element);
            if (multi_array.elements.len != 0) allocator.free(multi_array.elements);
        },
        .for_expr => |for_expr| {
            for (for_expr.inputs) |input| freeRollbackFixtureExpr(allocator, input);
            if (for_expr.inputs.len != 0) allocator.free(for_expr.inputs);
            for (for_expr.captures) |capture| allocator.free(capture.name);
            if (for_expr.captures.len != 0) allocator.free(for_expr.captures);
            freeRollbackFixtureBlock(allocator, for_expr.body);
            if (for_expr.else_body) |else_body| {
                freeRollbackFixtureExpr(allocator, else_body.*);
                allocator.destroy(@constCast(else_body));
            }
            if (for_expr.label) |label| allocator.free(label);
        },
        .while_expr => |while_expr| {
            freeRollbackFixtureExpr(allocator, while_expr.cond.*);
            allocator.destroy(@constCast(while_expr.cond));
            if (while_expr.continue_expr) |continue_expr| {
                freeRollbackFixtureExpr(allocator, continue_expr.*);
                allocator.destroy(@constCast(continue_expr));
            }
            if (while_expr.captures) |captures| {
                for (captures) |capture| allocator.free(capture);
                if (captures.len != 0) allocator.free(captures);
            }
            freeRollbackFixtureBlock(allocator, while_expr.body);
            if (while_expr.else_body) |else_body| {
                freeRollbackFixtureExpr(allocator, else_body.*);
                allocator.destroy(@constCast(else_body));
            }
            if (while_expr.label) |label| allocator.free(label);
        },
        .range => |range| {
            freeRollbackFixtureExpr(allocator, range.start.*);
            allocator.destroy(@constCast(range.start));
            if (range.end) |end| {
                freeRollbackFixtureExpr(allocator, end.*);
                allocator.destroy(@constCast(end));
            }
        },
        .return_expr => |value| {
            if (value) |expr_ptr| {
                freeRollbackFixtureExpr(allocator, expr_ptr.*);
                allocator.destroy(@constCast(expr_ptr));
            }
        },
        .break_expr => |break_expr| {
            if (break_expr.label) |label| allocator.free(label);
            if (break_expr.value) |expr_ptr| {
                freeRollbackFixtureExpr(allocator, expr_ptr.*);
                allocator.destroy(@constCast(expr_ptr));
            }
        },
        .type_value => |ty| freeRollbackFixtureType(allocator, ty),
        .builtin => |builtin| {
            allocator.free(builtin.name);
            for (builtin.args) |arg| freeRollbackFixtureExpr(allocator, arg);
            if (builtin.args.len != 0) allocator.free(builtin.args);
        },
        else => {},
    }
}

fn freeRollbackFixtureBlock(allocator: std.mem.Allocator, block: ast.Block) void {
    if (block.label) |label| allocator.free(label);
    for (block.stmts) |stmt| switch (stmt) {
        .expr_stmt => |expr_ptr| {
            freeRollbackFixtureExpr(allocator, expr_ptr.*);
            allocator.destroy(@constCast(expr_ptr));
        },
        .let_stmt => |let_stmt| {
            allocator.free(let_stmt.name);
            if (let_stmt.ty) |ty| freeRollbackFixtureType(allocator, ty);
            freeRollbackFixtureExpr(allocator, let_stmt.init);
        },
        else => {},
    };
    if (block.stmts.len != 0) allocator.free(block.stmts);
    if (block.expr) |expr_ptr| {
        freeRollbackFixtureExpr(allocator, expr_ptr.*);
        allocator.destroy(@constCast(expr_ptr));
    }
}

fn checkWhileDecodeRollbackAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeExpr(allocator, value);
    defer freeRollbackFixtureExpr(allocator, decoded);
    try testing.expect(decoded == .while_expr);
    const loop = decoded.while_expr;
    try testing.expect(loop.cond.* == .call);
    try testing.expectEqualStrings("has_next", loop.cond.call.callee.*.ident);
    try testing.expectEqualStrings("items", loop.cond.call.args[0].ident);
    try testing.expect(loop.continue_expr.?.* == .bin_op);
    try testing.expectEqual(ast.BinOpKind.add, loop.continue_expr.?.bin_op.op);
    try testing.expectEqualStrings("cursor", loop.continue_expr.?.bin_op.lhs.*.ident);
    try testing.expectEqual(@as(i128, 1), loop.continue_expr.?.bin_op.rhs.*.lit.int);
    try testing.expectEqual(@as(usize, 2), loop.captures.?.len);
    try testing.expectEqualStrings("cursor", loop.captures.?[0]);
    try testing.expectEqualStrings("step", loop.captures.?[1]);
    try testing.expectEqualStrings("body_label", loop.body.label.?);
    try testing.expectEqual(@as(usize, 1), loop.body.stmts.len);
    try testing.expectEqualStrings("done", loop.body.expr.?.ident);
    try testing.expectEqualStrings("exhausted", loop.else_body.?.ident);
    try testing.expectEqualStrings("outer_label", loop.label.?);
}

fn checkRangeDecodeRollbackAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeExpr(allocator, value);
    defer {
        allocator.free(decoded.range.start.*.ident);
        allocator.destroy(@constCast(decoded.range.start));
        allocator.destroy(@constCast(decoded.range.end.?));
    }
    try testing.expect(decoded == .range);
    try testing.expectEqualStrings("first", decoded.range.start.*.ident);
    try testing.expect(decoded.range.end.?.* == .lit);
    try testing.expectEqual(@as(i128, 10), decoded.range.end.?.lit.int);
}

/// Wires that carry every optional part a real expression has: calls with
/// arguments, nested field accesses, two-field struct literals, array literals
/// with a type, loops with captures, bodies and else branches, and exits that
/// carry a value and a label.
const nested_field_access_fixture = ast.Expr{ .field_access = .{
    .target = &ast.Expr{ .call = .{
        .callee = &ast.Expr{ .ident = "lookup" },
        .args = &.{.{ .ident = "table" }},
    } },
    .field_name = "value",
} };

const nested_bin_op_fixture = ast.Expr{ .bin_op = .{
    .op = .equal,
    .lhs = &ast.Expr{ .call = .{
        .callee = &ast.Expr{ .ident = "read" },
        .args = &.{.{ .ident = "cursor" }},
    } },
    .rhs = &ast.Expr{ .field_access = .{
        .target = &ast.Expr{ .ident = "state" },
        .field_name = "ready",
    } },
} };

const nested_unary_op_fixture = ast.Expr{ .unary_op = .{
    .op = .negate,
    .operand = &ast.Expr{ .call = .{
        .callee = &ast.Expr{ .ident = "distance" },
        .args = &.{ .{ .ident = "cursor" }, .{ .lit = .{ .int = 2 } } },
    } },
} };

const nested_struct_init_fixture = ast.Expr{ .struct_init = .{
    .type_name = ast.Type{ .opt = &ast.Type{ .named = "Config" } },
    .fields = &.{
        .{ .name = "first", .expr = .{ .ident = "left" } },
        .{ .name = "second", .expr = .{ .call = .{
            .callee = &ast.Expr{ .ident = "combine" },
            .args = &.{.{ .ident = "left" }},
        } } },
    },
} };

const nested_array_init_fixture = ast.Expr{ .array_init = .{
    .type_name = ast.Type{ .array = .{ .elem = &ast.Type{ .prim = .u8 }, .len = 3 } },
    .elements = &.{
        .{ .ident = "first" },
        .{ .call = .{
            .callee = &ast.Expr{ .ident = "make" },
            .args = &.{.{ .lit = .{ .int = 2 } }},
        } },
    },
} };

const nested_multi_array_fixture = ast.Expr{ .multi_array = .{
    .elements = &.{
        .{ .lit = .{ .str = "alpha" } },
        .{ .ident = "repeat_count" },
    },
} };

const nested_loop_fixture = ast.Expr{ .while_expr = .{
    .cond = &ast.Expr{ .call = .{
        .callee = &ast.Expr{ .ident = "has_next" },
        .args = &.{.{ .ident = "items" }},
    } },
    .continue_expr = &ast.Expr{ .bin_op = .{
        .op = .add,
        .lhs = &ast.Expr{ .ident = "cursor" },
        .rhs = &ast.Expr{ .lit = .{ .int = 1 } },
    } },
    .captures = &.{ "cursor", "step" },
    .body = .{
        .label = "body_label",
        .stmts = &.{.{ .expr_stmt = &ast.Expr{ .call = .{
            .callee = &ast.Expr{ .ident = "step" },
        } } }},
        .expr = &ast.Expr{ .ident = "done" },
    },
    .else_body = &ast.Expr{ .ident = "exhausted" },
    .label = "outer_label",
} };

const nested_for_expr_fixture = ast.Expr{ .for_expr = .{
    .inputs = &.{ .{ .ident = "items" }, .{ .ident = "limits" } },
    .captures = &.{
        .{ .name = "item", .by_ref = true },
        .{ .name = "index" },
    },
    .body = .{
        .label = "body_label",
        .stmts = &.{.{ .expr_stmt = &ast.Expr{ .ident = "item" } }},
        .expr = &ast.Expr{ .ident = "index" },
    },
    .else_body = &ast.Expr{ .ident = "exhausted" },
    .label = "outer_label",
} };

const nested_range_fixture = ast.Expr{ .range = .{
    .start = &ast.Expr{ .ident = "first" },
    .end = &ast.Expr{ .lit = .{ .int = 10 } },
} };

const nested_return_expr_fixture = ast.Expr{ .return_expr = &ast.Expr{ .call = .{
    .callee = &ast.Expr{ .ident = "finish" },
    .args = &.{.{ .ident = "result" }},
} } };

const nested_break_expr_fixture = ast.Expr{ .break_expr = .{
    .value = &ast.Expr{ .bin_op = .{
        .op = .add,
        .lhs = &ast.Expr{ .ident = "partial" },
        .rhs = &ast.Expr{ .lit = .{ .int = 1 } },
    } },
    .label = "outer_label",
} };

fn checkFieldAccessDecodeRollbackAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeExpr(allocator, value);
    defer freeRollbackFixtureExpr(allocator, decoded);
    try testing.expect(decoded == .field_access);
    try testing.expect(decoded.field_access.target.* == .call);
    try testing.expectEqualStrings("lookup", decoded.field_access.target.call.callee.*.ident);
    try testing.expectEqualStrings("table", decoded.field_access.target.call.args[0].ident);
    try testing.expectEqualStrings("value", decoded.field_access.field_name);
}

fn checkBinOpDecodeRollbackAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeExpr(allocator, value);
    defer freeRollbackFixtureExpr(allocator, decoded);
    try testing.expect(decoded == .bin_op);
    try testing.expectEqual(ast.BinOpKind.equal, decoded.bin_op.op);
    try testing.expect(decoded.bin_op.lhs.* == .call);
    try testing.expectEqualStrings("read", decoded.bin_op.lhs.call.callee.*.ident);
    try testing.expectEqualStrings("cursor", decoded.bin_op.lhs.call.args[0].ident);
    try testing.expect(decoded.bin_op.rhs.* == .field_access);
    try testing.expectEqualStrings("state", decoded.bin_op.rhs.field_access.target.*.ident);
    try testing.expectEqualStrings("ready", decoded.bin_op.rhs.field_access.field_name);
}

fn checkUnaryOpDecodeRollbackAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeExpr(allocator, value);
    defer freeRollbackFixtureExpr(allocator, decoded);
    try testing.expect(decoded == .unary_op);
    try testing.expectEqual(ast.UnaryOpKind.negate, decoded.unary_op.op);
    try testing.expect(decoded.unary_op.operand.* == .call);
    try testing.expectEqualStrings("distance", decoded.unary_op.operand.call.callee.*.ident);
    try testing.expectEqual(@as(usize, 2), decoded.unary_op.operand.call.args.len);
    try testing.expectEqualStrings("cursor", decoded.unary_op.operand.call.args[0].ident);
    try testing.expectEqual(@as(i128, 2), decoded.unary_op.operand.call.args[1].lit.int);
}

fn checkStructInitDecodeRollbackAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeExpr(allocator, value);
    defer freeRollbackFixtureExpr(allocator, decoded);
    try testing.expect(decoded == .struct_init);
    try testing.expect(decoded.struct_init.type_name.? == .opt);
    try testing.expectEqualStrings("Config", decoded.struct_init.type_name.?.opt.*.named);
    try testing.expectEqual(@as(usize, 2), decoded.struct_init.fields.len);
    try testing.expectEqualStrings("first", decoded.struct_init.fields[0].name);
    try testing.expectEqualStrings("left", decoded.struct_init.fields[0].expr.ident);
    try testing.expectEqualStrings("second", decoded.struct_init.fields[1].name);
    try testing.expectEqualStrings(
        "combine",
        decoded.struct_init.fields[1].expr.call.callee.*.ident,
    );
    try testing.expectEqualStrings("left", decoded.struct_init.fields[1].expr.call.args[0].ident);
}

fn checkArrayInitDecodeRollbackAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeExpr(allocator, value);
    defer freeRollbackFixtureExpr(allocator, decoded);
    try testing.expect(decoded == .array_init);
    try testing.expect(decoded.array_init.type_name.? == .array);
    try testing.expectEqual(@as(u64, 3), decoded.array_init.type_name.?.array.len);
    try testing.expectEqual(ast.Prim.u8, decoded.array_init.type_name.?.array.elem.*.prim);
    try testing.expectEqual(@as(usize, 2), decoded.array_init.elements.len);
    try testing.expectEqualStrings("first", decoded.array_init.elements[0].ident);
    try testing.expectEqualStrings("make", decoded.array_init.elements[1].call.callee.*.ident);
    try testing.expectEqual(@as(i128, 2), decoded.array_init.elements[1].call.args[0].lit.int);
}

fn checkMultiArrayDecodeRollbackAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeExpr(allocator, value);
    defer freeRollbackFixtureExpr(allocator, decoded);
    try testing.expect(decoded == .multi_array);
    try testing.expectEqual(@as(usize, 2), decoded.multi_array.elements.len);
    try testing.expectEqualStrings("alpha", decoded.multi_array.elements[0].lit.str);
    try testing.expectEqualStrings("repeat_count", decoded.multi_array.elements[1].ident);
}

fn checkForDecodeRollbackAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeExpr(allocator, value);
    defer freeRollbackFixtureExpr(allocator, decoded);
    try testing.expect(decoded == .for_expr);
    try testing.expectEqual(@as(usize, 2), decoded.for_expr.inputs.len);
    try testing.expectEqualStrings("items", decoded.for_expr.inputs[0].ident);
    try testing.expectEqualStrings("limits", decoded.for_expr.inputs[1].ident);
    try testing.expectEqual(@as(usize, 2), decoded.for_expr.captures.len);
    try testing.expectEqualStrings("item", decoded.for_expr.captures[0].name);
    try testing.expect(decoded.for_expr.captures[0].by_ref);
    try testing.expectEqualStrings("index", decoded.for_expr.captures[1].name);
    try testing.expect(!decoded.for_expr.captures[1].by_ref);
    try testing.expectEqualStrings("body_label", decoded.for_expr.body.label.?);
    try testing.expectEqual(@as(usize, 1), decoded.for_expr.body.stmts.len);
    try testing.expectEqualStrings("item", decoded.for_expr.body.stmts[0].expr_stmt.*.ident);
    try testing.expectEqualStrings("index", decoded.for_expr.body.expr.?.ident);
    try testing.expectEqualStrings("exhausted", decoded.for_expr.else_body.?.ident);
    try testing.expectEqualStrings("outer_label", decoded.for_expr.label.?);
}

fn checkReturnDecodeRollbackAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeExpr(allocator, value);
    defer freeRollbackFixtureExpr(allocator, decoded);
    try testing.expect(decoded == .return_expr);
    try testing.expect(decoded.return_expr.?.* == .call);
    try testing.expectEqualStrings("finish", decoded.return_expr.?.call.callee.*.ident);
    try testing.expectEqualStrings("result", decoded.return_expr.?.call.args[0].ident);
}

fn checkBreakDecodeRollbackAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeExpr(allocator, value);
    defer freeRollbackFixtureExpr(allocator, decoded);
    try testing.expect(decoded == .break_expr);
    try testing.expectEqualStrings("outer_label", decoded.break_expr.label.?);
    try testing.expect(decoded.break_expr.value.?.* == .bin_op);
    try testing.expectEqual(ast.BinOpKind.add, decoded.break_expr.value.?.bin_op.op);
    try testing.expectEqualStrings("partial", decoded.break_expr.value.?.bin_op.lhs.*.ident);
    try testing.expectEqual(@as(i128, 1), decoded.break_expr.value.?.bin_op.rhs.*.lit.int);
}

test "serialize: expression decoder rollback keeps every allocation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const encoder = arena.allocator();

    // Every shape `decodeExpr` builds out of boxes, names and lists gets the
    // same treatment: decode it, check what it means, and let the failing
    // allocator reach every allocation in it.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkFieldAccessDecodeRollbackAllocations,
        .{try serialize.encodeExpr(encoder, nested_field_access_fixture)},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkBinOpDecodeRollbackAllocations,
        .{try serialize.encodeExpr(encoder, nested_bin_op_fixture)},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkUnaryOpDecodeRollbackAllocations,
        .{try serialize.encodeExpr(encoder, nested_unary_op_fixture)},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkStructInitDecodeRollbackAllocations,
        .{try serialize.encodeExpr(encoder, nested_struct_init_fixture)},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkArrayInitDecodeRollbackAllocations,
        .{try serialize.encodeExpr(encoder, nested_array_init_fixture)},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkMultiArrayDecodeRollbackAllocations,
        .{try serialize.encodeExpr(encoder, nested_multi_array_fixture)},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkWhileDecodeRollbackAllocations,
        .{try serialize.encodeExpr(encoder, nested_loop_fixture)},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkForDecodeRollbackAllocations,
        .{try serialize.encodeExpr(encoder, nested_for_expr_fixture)},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkInlineForDecodeRollbackAllocations,
        .{try serialize.encodeExpr(encoder, hash_child_walk)},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkRangeDecodeRollbackAllocations,
        .{try serialize.encodeExpr(encoder, nested_range_fixture)},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkReturnDecodeRollbackAllocations,
        .{try serialize.encodeExpr(encoder, nested_return_expr_fixture)},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkBreakDecodeRollbackAllocations,
        .{try serialize.encodeExpr(encoder, nested_break_expr_fixture)},
    );
}

fn checkInlineForDecodeRollbackAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeExpr(allocator, value);
    defer freeRollbackFixtureExpr(allocator, decoded);
    try testing.expect(decoded == .for_expr);
    try testing.expect(decoded.for_expr.is_inline);
    try testing.expectEqual(@as(usize, 1), decoded.for_expr.inputs.len);
    try testing.expectEqual(@as(usize, 1), decoded.for_expr.captures.len);
    try testing.expectEqualStrings("Child", decoded.for_expr.captures[0].name);
    const children = decoded.for_expr.inputs[0].unary_op.operand.array_init.elements;
    try testing.expectEqual(@as(usize, 3), children.len);
    const reference_layout = children[0].type_value.expr.call.args[0].struct_init;
    try testing.expectEqualStrings("reference", reference_layout.fields[0].name);
    try testing.expectEqualStrings("D", reference_layout.fields[0].expr.type_value.named);
    const str_layout = children[1].type_value.expr.call.args[0].struct_init;
    try testing.expectEqualStrings("reference", str_layout.fields[0].name);
    const str_descriptor = str_layout.fields[0].expr.type_value.expr.call;
    const str_descriptor_layout = str_descriptor.args[0].struct_init;
    try testing.expectEqualStrings("str", str_descriptor_layout.fields[0].name);
    try testing.expect(str_descriptor_layout.fields[0].expr == .unit);
    const scalar_layout = children[2].type_value.expr.call.args[0].struct_init;
    try testing.expectEqualStrings("scalar", scalar_layout.fields[0].name);
}

test "serialize: an inline hash walk roundtrips its comptime descriptors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const encoded = try serialize.encodeExpr(allocator, hash_child_walk);
    try testing.expectEqualStrings("for_expr", encoded.object.get("kind").?.string);
    try testing.expect(encoded.object.get("is_inline").?.bool);

    const decoded = try serialize.decodeExpr(allocator, encoded);
    try testing.expect(decoded == .for_expr);
    try testing.expect(decoded.for_expr.is_inline);
    try testing.expectEqual(@as(usize, 1), decoded.for_expr.inputs.len);
    try testing.expectEqual(@as(usize, 1), decoded.for_expr.captures.len);
    try testing.expectEqualStrings("Child", decoded.for_expr.captures[0].name);
    try testing.expectEqualStrings("Child", decoded.for_expr.body.stmts[0].expr_stmt.*.ident);

    // The walk binds descriptors, not runtime values: every child is a comptime
    // type value, and each keeps its own layout tag.
    const walk = decoded.for_expr.inputs[0].unary_op;
    try testing.expect(walk.op == .addr_of);
    const children = walk.operand.array_init.elements;
    try testing.expectEqual(@as(usize, 3), children.len);
    const reference = children[0].type_value.expr.call;
    try testing.expectEqualStrings("r2z.RustHashType", reference.callee.*.ident);
    const reference_layout = reference.args[0].struct_init;
    try testing.expectEqualStrings("reference", reference_layout.fields[0].name);
    try testing.expectEqualStrings("D", reference_layout.fields[0].expr.type_value.named);
    try testing.expectEqualStrings(
        "r2z.RustHashRef",
        reference.generic_args[0].expr.call.callee.*.ident,
    );

    // `&str`: the reference layout over the `str` descriptor, whose own void
    // `.str` tag stays nested one level down.
    const str_child = children[1].type_value.expr.call;
    try testing.expectEqualStrings("r2z.RustHashType", str_child.callee.*.ident);
    const str_layout = str_child.args[0].struct_init;
    try testing.expectEqualStrings("reference", str_layout.fields[0].name);
    const str_descriptor = str_layout.fields[0].expr.type_value.expr.call;
    try testing.expectEqualStrings("r2z.RustHashType", str_descriptor.callee.*.ident);
    const str_descriptor_layout = str_descriptor.args[0].struct_init;
    try testing.expectEqualStrings("str", str_descriptor_layout.fields[0].name);
    try testing.expect(str_descriptor_layout.fields[0].expr == .unit);
    const str_view = str_child.generic_args[0].expr.call;
    try testing.expectEqualStrings("r2z.RustHashRef", str_view.callee.*.ident);
    try testing.expect(!str_view.args[0].lit.bool_lit);

    // `u64`: the runtime type against the `.scalar` member naming that source
    // kind, reached through the inline enum rather than spelled as a name.
    const scalar_child = children[2].type_value.expr.call;
    const scalar_layout = scalar_child.args[0].struct_init;
    try testing.expectEqualStrings("scalar", scalar_layout.fields[0].name);
    try testing.expectEqualStrings(
        "FieldType",
        scalar_layout.fields[0].expr.field_access.target.builtin.name,
    );
    try testing.expectEqualStrings("u64", scalar_layout.fields[0].expr.field_access.field_name);
    try testing.expectEqual(ast.Prim.u64, scalar_child.generic_args[0].prim);

    // The same walk without the flag keeps exactly the bytes it had before the
    // field existed: an absent `is_inline` reads back as not inline, and the
    // descriptors it walks are unchanged.
    var runtime_walk = hash_child_walk;
    runtime_walk.for_expr.is_inline = false;
    const runtime_encoded = try serialize.encodeExpr(allocator, runtime_walk);
    try testing.expect(runtime_encoded.object.get("is_inline") == null);
    const runtime_decoded = try serialize.decodeExpr(allocator, runtime_encoded);
    try testing.expect(!runtime_decoded.for_expr.is_inline);
    const runtime_walk_expr = runtime_decoded.for_expr.inputs[0].unary_op;
    try testing.expect(runtime_walk_expr.op == .addr_of);
    const runtime_descriptors = runtime_walk_expr.operand.array_init.elements;
    try testing.expectEqual(@as(usize, 3), runtime_descriptors.len);
    try testing.expectEqualStrings(
        "r2z.RustHashType",
        runtime_descriptors[0].type_value.expr.call.callee.*.ident,
    );
}

/// An expression wire the decoder must reject only after it already owns the
/// boxes, names and lists it decoded beside the offending field. Decoding runs
/// against `testing.allocator`, which reports whatever the failed decode left
/// behind when the test ends.
const MalformedExprRollback = struct {
    json: []const u8,
    expected: anyerror,
};

test "serialize: expression decoder rollback releases what it decoded before the wire failed" {
    const cases = [_]MalformedExprRollback{
        // A loop whose condition never arrives: the condition box exists
        // before the key is looked up.
        .{ .json =
        \\{"kind":"while_expr",
        \\ "body":{"label":null,"stmts":[],"expr":null}}
        , .expected = error.MissingField },
        // A loop whose condition, step, body, else branch and first capture
        // all decode, and whose second capture is not a name.
        .{ .json =
        \\{"kind":"while_expr",
        \\ "cond":{"kind":"call","callee":{"kind":"ident","name":"has_next"},
        \\        "generic_args":[],"args":[{"kind":"ident","name":"items"}]},
        \\ "continue_expr":{"kind":"bin_op","op":"add",
        \\                  "lhs":{"kind":"ident","name":"cursor"},
        \\                  "rhs":{"kind":"lit","value":{"kind":"int","value":"1"}}},
        \\ "captures":["cursor",42],
        \\ "body":{"label":"body_label",
        \\         "stmts":[{"kind":"expr_stmt",
        \\                 "expr":{"kind":"call",
        \\                       "callee":{"kind":"ident","name":"step"},
        \\                       "generic_args":[],"args":[]}}],
        \\         "expr":{"kind":"ident","name":"done"}},
        \\ "label":"outer_label",
        \\ "else_body":{"kind":"ident","name":"exhausted"}}
        , .expected = error.BadWireFormat },
        // A loop whose body never arrives, behind a decoded condition, step
        // and else branch.
        .{ .json =
        \\{"kind":"while_expr",
        \\ "cond":{"kind":"ident","name":"again"},
        \\ "continue_expr":{"kind":"ident","name":"next"},
        \\ "else_body":{"kind":"ident","name":"stop"}}
        , .expected = error.MissingField },
        // A range whose start never arrives.
        .{ .json =
        \\{"kind":"range","end":{"kind":"lit","value":{"kind":"int","value":10}}}
        , .expected = error.MissingField },
        // A range whose end is not an expression, behind a decoded start.
        .{ .json =
        \\{"kind":"range",
        \\ "start":{"kind":"ident","name":"first"},
        \\ "end":{"kind":"ident","name":42}}
        , .expected = error.BadWireFormat },
        // A field access whose field name is not a name, behind a decoded
        // target.
        .{ .json =
        \\{"kind":"field_access",
        \\ "target":{"kind":"ident","name":"config"},
        \\ "field_name":42}
        , .expected = error.BadWireFormat },
        // A binary operation whose right operand is not an expression kind,
        // behind a decoded left operand.
        .{ .json =
        \\{"kind":"bin_op","op":"add",
        \\ "lhs":{"kind":"ident","name":"left"},
        \\ "rhs":{"kind":"mystery"}}
        , .expected = error.UnknownExprKind },
        // A unary operation whose operand is not an expression.
        .{ .json =
        \\{"kind":"unary_op","op":"negate","operand":42}
        , .expected = error.BadWireFormat },
        // A struct literal whose fields are not an array, behind a decoded
        // type name.
        .{ .json =
        \\{"kind":"struct_init",
        \\ "type_name":{"kind":"named","name":"Config"},
        \\ "fields":42}
        , .expected = error.BadWireFormat },
        // A struct literal whose second field has no name, behind a decoded
        // first field.
        .{ .json =
        \\{"kind":"struct_init",
        \\ "fields":[{"name":"first","expr":{"kind":"ident","name":"one"}},
        \\           {"name":42,"expr":{"kind":"ident","name":"two"}}]}
        , .expected = error.BadWireFormat },
        // An array literal whose second element is not an expression, behind a
        // decoded type and first element.
        .{ .json =
        \\{"kind":"array_init",
        \\ "type_name":{"kind":"array","elem":{"kind":"prim","value":"u8"},"len":3},
        \\ "elements":[{"kind":"ident","name":"first"},42]}
        , .expected = error.BadWireFormat },
        // A comptime-repeated array whose second element is not an
        // expression, behind a decoded first element.
        .{ .json =
        \\{"kind":"multi_array",
        \\ "elements":[{"kind":"lit","value":{"kind":"str","value":"alpha"}},42]}
        , .expected = error.BadWireFormat },
        // A for loop whose else branch is not an expression, behind decoded
        // inputs, captures and body.
        .{ .json =
        \\{"kind":"for_expr",
        \\ "inputs":[{"kind":"ident","name":"items"}],
        \\ "captures":[{"name":"item","by_ref":true}],
        \\ "body":{"label":null,"stmts":[],"expr":null},
        \\ "else_body":42}
        , .expected = error.BadWireFormat },
        // A return whose value is not an expression kind.
        .{ .json =
        \\{"kind":"return_expr","value":{"kind":"mystery"}}
        , .expected = error.UnknownExprKind },
        // A break whose label is not a name, behind a decoded value.
        .{ .json =
        \\{"kind":"break_expr",
        \\ "value":{"kind":"ident","name":"done"},
        \\ "label":42}
        , .expected = error.BadWireFormat },
        // A loop whose inline flag is not a boolean, behind decoded inputs,
        // captures, body, else branch and label.
        .{ .json =
        \\{"kind":"for_expr",
        \\ "inputs":[{"kind":"ident","name":"items"}],
        \\ "captures":[{"name":"item","by_ref":true}],
        \\ "body":{"label":null,"stmts":[],"expr":null},
        \\ "else_body":{"kind":"ident","name":"exhausted"},
        \\ "label":"outer_label",
        \\ "is_inline":"yes"}
        , .expected = error.BadWireFormat },
    };

    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            testing.allocator,
            case.json,
            .{},
        );
        defer parsed.deinit();
        try testing.expectError(
            case.expected,
            serialize.decodeExpr(testing.allocator, parsed.value),
        );
    }
}

/// Wires for the three type shapes that build owned children out of boxes and
/// lists: an error union with an array-of-optional payload, a three-element
/// tuple, and an anonymous struct with a defaulted field beside a private one.
const nested_err_union_type_fixture = ast.Type{ .err_union = .{
    .err_set = "Failure",
    .payload = &ast.Type{ .array = .{
        .elem = &ast.Type{ .opt = &ast.Type{ .named = "Value" } },
        .len = 4,
    } },
} };

const nested_tuple_type_fixture = ast.Type{ .tuple = &.{
    ast.Type{ .named = "First" },
    ast.Type{ .ptr = .{ .elem = &ast.Type{ .named = "Item" }, .is_const = true } },
    ast.Type{ .prim = .u8 },
} };

const nested_anon_struct_type_fixture = ast.Type{ .anon_struct = .{
    .fields = &.{
        .{
            .name = "first",
            .ty = ast.Type{ .opt = &ast.Type{ .named = "Config" } },
            .default_val = &ast.Expr{ .ident = "DEFAULT_CONFIG" },
        },
        .{
            .name = "second",
            .ty = ast.Type{ .prim = .u8 },
            .is_pub = false,
        },
    },
} };

/// `r2z.RustHashLayout{ .str = {} }` — a `void`-payload tag.
const hash_str_layout = ast.Expr{ .struct_init = .{
    .type_name = ast.Type{ .named = "r2z.RustHashLayout" },
    .fields = &.{.{ .name = "str", .expr = ast.Expr{ .unit = {} } }},
} };

/// `@FieldType(r2z.RustHashLayout, "scalar").u64` — the `scalar` tag names the
/// SOURCE kind it hashes, so its payload is that member of the inline enum.
/// There is no `Expr.enum_literal` here, and a bare `.u64` identifier would
/// name nothing: the member is only reachable through the enum type. The AST
/// carries the BARE builtin name and a typed first argument — emit.zig prints
/// the `@` itself, and `validateQualifiedName` rejects one in a name.
const hash_scalar_kind = ast.Expr{ .field_access = .{
    .target = &ast.Expr{ .builtin = .{
        .name = "FieldType",
        .args = &.{
            ast.Expr{ .type_value = ast.Type{ .named = "r2z.RustHashLayout" } },
            ast.Expr{ .lit = .{ .str = "scalar" } },
        },
    } },
    .field_name = "u64",
} };

/// `r2z.RustHashLayout{ .scalar = @FieldType(..., "scalar").u64 }`. The
/// `void`-payload `.str` tag beside it is untouched by that change.
const hash_scalar_layout = ast.Expr{ .struct_init = .{
    .type_name = ast.Type{ .named = "r2z.RustHashLayout" },
    .fields = &.{.{ .name = "scalar", .expr = hash_scalar_kind }},
} };

/// `r2z.RustHashLayout{ .reference = D }` — a tag carrying one child
/// descriptor. `D` is the Hash-bound parameter, forwarded by name; a `named`
/// type here is a type, never source text.
const hash_reference_layout = ast.Expr{ .struct_init = .{
    .type_name = ast.Type{ .named = "r2z.RustHashLayout" },
    .fields = &.{.{ .name = "reference", .expr = ast.Expr{ .type_value = .{ .named = "D" } } }},
} };

/// `[]const u8`, the runtime type of `str` itself.
const hash_str_runtime_type = ast.Type{ .slice = .{
    .elem = &ast.Type{ .prim = .u8 },
    .is_const = true,
} };

/// `r2z.RustHashRef(D, true)` — the borrow of a Hash-bound parameter. The
/// descriptor is the one type argument; `mutable` is a comptime value, so it
/// is an ordinary argument.
const hash_reference_borrow = ast.Type{ .expr = &ast.Expr{ .call = .{
    .callee = &ast.Expr{ .ident = "r2z.RustHashRef" },
    .generic_args = &.{ast.Type{ .named = "D" }},
    .args = &.{ast.Expr{ .lit = .{ .bool_lit = true } }},
} } };

/// The descriptor for `&D`: the reference layout over the pointee, with the
/// borrow itself as the runtime type.
const hash_reference_descriptor = ast.Type{ .expr = &ast.Expr{ .call = .{
    .callee = &ast.Expr{ .ident = "r2z.RustHashType" },
    .generic_args = &.{hash_reference_borrow},
    .args = &.{hash_reference_layout},
} } };

/// The descriptor for `str`.
const hash_str_descriptor = ast.Type{ .expr = &ast.Expr{ .call = .{
    .callee = &ast.Expr{ .ident = "r2z.RustHashType" },
    .generic_args = &.{hash_str_runtime_type},
    .args = &.{hash_str_layout},
} } };

/// `r2z.RustHashRef(r2z.RustHashType([]const u8, ...), false)` — the Zig
/// borrow of an unsized `str` IS the fat `[]const u8` view, which is what that
/// constructor call returns. A pointer to the slice would be a borrow of the
/// borrow, an `&&str`, and would need a second reference layout.
const hash_str_borrow_type = ast.Type{ .expr = &ast.Expr{ .call = .{
    .callee = &ast.Expr{ .ident = "r2z.RustHashRef" },
    .generic_args = &.{hash_str_descriptor},
    .args = &.{ast.Expr{ .lit = .{ .bool_lit = false } }},
} } };

/// `r2z.RustHashLayout{ .reference = r2z.RustHashType([]const u8, ...) }` —
/// a borrow of an unsized value is a sized `.reference` over the pointee
/// descriptor, never a bare `.str`.
const hash_str_reference_layout = ast.Expr{ .struct_init = .{
    .type_name = ast.Type{ .named = "r2z.RustHashLayout" },
    .fields = &.{.{
        .name = "reference",
        .expr = ast.Expr{ .type_value = hash_str_descriptor },
    }},
} };

/// The descriptor for `&str`: the single reference layout over the `str`
/// descriptor, with the fat slice view as the runtime type.
const hash_str_borrow_descriptor = ast.Type{ .expr = &ast.Expr{ .call = .{
    .callee = &ast.Expr{ .ident = "r2z.RustHashType" },
    .generic_args = &.{hash_str_borrow_type},
    .args = &.{hash_str_reference_layout},
} } };

/// The descriptor for `u64`.
const hash_scalar_descriptor = ast.Type{ .expr = &ast.Expr{ .call = .{
    .callee = &ast.Expr{ .ident = "r2z.RustHashType" },
    .generic_args = &.{ast.Type{ .prim = .u64 }},
    .args = &.{hash_scalar_layout},
} } };

/// The descriptor a translated `fn hash<D: Hash>(pair: (&mut D, &str, u64))`
/// declares for `pair`, spelled the way `lower.zig` spells every Hash
/// descriptor: `r2z.RustHashType(runtime type, layout)`, the runtime type in
/// the type-argument slot and the layout in the value-argument slot, and the
/// child descriptors in Rust tuple order behind `&.{ ... }`.
///
/// `str` is unsized and the fatness belongs to the borrow itself, so the
/// second field is `&str` whose value is the `[]const u8` slice view —
/// `r2z.RustHashRef(strDescriptor, false)` — laid out as the single
/// `.reference` over that same descriptor. A `*const []const u8` would be a
/// borrow of that view, an `&&str`, and would need two reference layouts. The
/// first field is `&mut D`, whose runtime type is the `r2z.RustHashRef(D, true)`
/// call rather than a spelled `*D`: the runtime resolves that thin pointer to
/// `*D.Type`. Every node below reaches the emitted Zig, so losing the tuple
/// order, a layout tag, a unit payload or a borrow's `mutable` value changes
/// the hash a translated `Hash` computes.
const hash_descriptor_type_fixture = ast.Type{ .expr = &ast.Expr{ .call = .{
    .callee = &ast.Expr{ .ident = "r2z.RustHashType" },
    .generic_args = &.{ast.Type{ .tuple = &.{
        hash_reference_borrow,
        hash_str_borrow_type,
        ast.Type{ .prim = .u64 },
    } }},
    .args = &.{ast.Expr{ .struct_init = .{
        .type_name = ast.Type{ .named = "r2z.RustHashLayout" },
        .fields = &.{.{ .name = "tuple", .expr = ast.Expr{ .unary_op = .{
            .op = .addr_of,
            .operand = &ast.Expr{ .array_init = .{ .elements = &.{
                ast.Expr{ .type_value = hash_reference_descriptor },
                ast.Expr{ .type_value = hash_str_borrow_descriptor },
                ast.Expr{ .type_value = hash_scalar_descriptor },
            } } },
        } } }},
    } }},
} } };

/// The `inline for` walk a translated `Hash` takes over a tuple layout's child
/// descriptors: one input holding the comptime `&.{ D, D, D }` of type values,
/// one capture binding each child. `inline` is what keeps that dispatch at
/// comptime, so a roundtrip that dropped it would emit a runtime loop over
/// types that cannot typecheck.
const hash_child_walk = ast.Expr{ .for_expr = .{
    .is_inline = true,
    .inputs = &.{ast.Expr{ .unary_op = .{
        .op = .addr_of,
        .operand = &ast.Expr{ .array_init = .{ .elements = &.{
            ast.Expr{ .type_value = hash_reference_descriptor },
            ast.Expr{ .type_value = hash_str_borrow_descriptor },
            ast.Expr{ .type_value = hash_scalar_descriptor },
        } } },
    } }},
    .captures = &.{.{ .name = "Child" }},
    .body = .{
        .stmts = &.{.{ .expr_stmt = &ast.Expr{ .ident = "Child" } }},
    },
} };

fn checkErrUnionDecodeRollbackAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeType(allocator, value);
    defer freeRollbackFixtureType(allocator, decoded);
    try testing.expect(decoded == .err_union);
    try testing.expectEqualStrings("Failure", decoded.err_union.err_set.?);
    try testing.expect(decoded.err_union.payload.* == .array);
    try testing.expectEqual(@as(u64, 4), decoded.err_union.payload.array.len);
    try testing.expect(decoded.err_union.payload.array.elem.* == .opt);
    try testing.expectEqualStrings("Value", decoded.err_union.payload.array.elem.opt.*.named);
}

fn checkTupleTypeDecodeRollbackAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeType(allocator, value);
    defer freeRollbackFixtureType(allocator, decoded);
    try testing.expect(decoded == .tuple);
    try testing.expectEqual(@as(usize, 3), decoded.tuple.len);
    try testing.expectEqualStrings("First", decoded.tuple[0].named);
    try testing.expect(decoded.tuple[1] == .ptr);
    try testing.expect(decoded.tuple[1].ptr.is_const);
    try testing.expectEqualStrings("Item", decoded.tuple[1].ptr.elem.*.named);
    try testing.expectEqual(ast.Prim.u8, decoded.tuple[2].prim);
}

fn checkAnonStructDecodeRollbackAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeType(allocator, value);
    defer freeRollbackFixtureType(allocator, decoded);
    try testing.expect(decoded == .anon_struct);
    try testing.expectEqual(@as(usize, 2), decoded.anon_struct.fields.len);
    try testing.expectEqualStrings("first", decoded.anon_struct.fields[0].name);
    try testing.expect(decoded.anon_struct.fields[0].ty == .opt);
    try testing.expectEqualStrings("Config", decoded.anon_struct.fields[0].ty.opt.*.named);
    try testing.expectEqualStrings(
        "DEFAULT_CONFIG",
        decoded.anon_struct.fields[0].default_val.?.ident,
    );
    try testing.expect(decoded.anon_struct.fields[0].is_pub);
    try testing.expectEqualStrings("", decoded.anon_struct.fields[0].documentation);
    try testing.expectEqualStrings("second", decoded.anon_struct.fields[1].name);
    try testing.expectEqual(ast.Prim.u8, decoded.anon_struct.fields[1].ty.prim);
    try testing.expect(!decoded.anon_struct.fields[1].is_pub);
    try testing.expect(decoded.anon_struct.fields[1].default_val == null);
    try testing.expectEqualStrings("", decoded.anon_struct.fields[1].documentation);
}

fn checkExprTypeDecodeRollbackAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeType(allocator, value);
    defer freeRollbackFixtureType(allocator, decoded);
    try testing.expect(decoded == .expr);
    try testing.expectEqualStrings("r2z.RustHashType", decoded.expr.call.callee.*.ident);
    try testing.expectEqual(@as(usize, 1), decoded.expr.call.generic_args.len);
    const runtime_tuple = decoded.expr.call.generic_args[0].tuple;
    try testing.expectEqual(@as(usize, 3), runtime_tuple.len);
    try testing.expectEqualStrings("r2z.RustHashRef", runtime_tuple[0].expr.call.callee.*.ident);
    const str_view = runtime_tuple[1].expr.call;
    try testing.expectEqualStrings("r2z.RustHashRef", str_view.callee.*.ident);
    try testing.expect(!str_view.args[0].lit.bool_lit);
    try testing.expectEqual(ast.Prim.u64, runtime_tuple[2].prim);
    try testing.expectEqual(@as(usize, 1), decoded.expr.call.args.len);
    const layout = decoded.expr.call.args[0].struct_init;
    try testing.expectEqualStrings("r2z.RustHashLayout", layout.type_name.?.named);
    try testing.expectEqualStrings("tuple", layout.fields[0].name);
    try testing.expect(layout.fields[0].expr.unary_op.op == .addr_of);
    const children = layout.fields[0].expr.unary_op.operand.array_init.elements;
    try testing.expectEqual(@as(usize, 3), children.len);
    const reference = children[0].type_value.expr.*.call;
    try testing.expectEqualStrings("reference", reference.args[0].struct_init.fields[0].name);
    try testing.expectEqualStrings("D", reference.generic_args[0].expr.*.call.generic_args[0].named);
    try testing.expect(reference.generic_args[0].expr.*.call.args[0].lit.bool_lit);
    const str_borrow = children[1].type_value.expr.*.call;
    try testing.expectEqualStrings("reference", str_borrow.args[0].struct_init.fields[0].name);
    const str_pointee = str_borrow.args[0].struct_init.fields[0].expr.type_value;
    const str_pointee_layout = str_pointee.expr.*.call.args[0].struct_init;
    try testing.expectEqualStrings("str", str_pointee_layout.fields[0].name);
    try testing.expect(str_pointee_layout.fields[0].expr == .unit);
    const scalar_layout = children[2].type_value.expr.*.call.args[0].struct_init;
    try testing.expectEqualStrings("scalar", scalar_layout.fields[0].name);
    try testing.expectEqualStrings(
        "FieldType",
        scalar_layout.fields[0].expr.field_access.target.builtin.name,
    );
}

test "serialize: type decoder rollback keeps every allocation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const encoder = arena.allocator();

    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkErrUnionDecodeRollbackAllocations,
        .{try serialize.encodeType(encoder, nested_err_union_type_fixture)},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkTupleTypeDecodeRollbackAllocations,
        .{try serialize.encodeType(encoder, nested_tuple_type_fixture)},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkAnonStructDecodeRollbackAllocations,
        .{try serialize.encodeType(encoder, nested_anon_struct_type_fixture)},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkExprTypeDecodeRollbackAllocations,
        .{try serialize.encodeType(encoder, hash_descriptor_type_fixture)},
    );
}

test "serialize: a hash descriptor type roundtrips with its layout intact" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const encoded = try serialize.encodeType(allocator, hash_descriptor_type_fixture);

    // The wire carries the descriptor expression, never its spelling smuggled
    // in as a name.
    try testing.expectEqualStrings("expr", encoded.object.get("kind").?.string);
    try testing.expect(encoded.object.get("name") == null);
    const encoded_call = encoded.object.get("expr").?;
    try testing.expectEqualStrings("call", encoded_call.object.get("kind").?.string);
    const encoded_callee = encoded_call.object.get("callee").?.object;
    try testing.expectEqualStrings("r2z.RustHashType", encoded_callee.get("name").?.string);

    // The runtime type is a tuple whose first element is itself a descriptor,
    // so the canonical tag has to recurse through the type argument.
    const encoded_type_arg = encoded_call.object.get("generic_args").?.array.items[0];
    try testing.expectEqualStrings("tuple", encoded_type_arg.object.get("kind").?.string);
    const encoded_borrow = encoded_type_arg.object.get("elements").?.array.items[0];
    try testing.expectEqualStrings("expr", encoded_borrow.object.get("kind").?.string);
    const encoded_ref = encoded_borrow.object.get("expr").?.object;
    const encoded_ref_callee = encoded_ref.get("callee").?.object;
    try testing.expectEqualStrings("r2z.RustHashRef", encoded_ref_callee.get("name").?.string);
    const encoded_mutable = encoded_ref.get("args").?.array.items[0];
    const encoded_mutable_literal = encoded_mutable.object.get("value").?.object;
    try testing.expectEqualStrings("bool_lit", encoded_mutable_literal.get("kind").?.string);
    try testing.expect(encoded_mutable_literal.get("value").?.bool);

    const decoded = try serialize.decodeType(allocator, encoded);
    try testing.expect(decoded == .expr);
    try testing.expect(decoded.expr.* == .call);
    try testing.expectEqualStrings("r2z.RustHashType", decoded.expr.call.callee.*.ident);
    try testing.expectEqual(@as(usize, 1), decoded.expr.call.generic_args.len);

    // The runtime type: the tuple's elements in Rust order, the `&mut D`
    // borrow spelled through the descriptor rather than as a pointer type.
    const runtime_tuple = decoded.expr.call.generic_args[0].tuple;
    try testing.expectEqual(@as(usize, 3), runtime_tuple.len);
    try testing.expectEqualStrings("r2z.RustHashRef", runtime_tuple[0].expr.call.callee.*.ident);
    try testing.expect(runtime_tuple[0].expr.call.args[0].lit.bool_lit);
    const str_view = runtime_tuple[1].expr.call;
    try testing.expectEqualStrings("r2z.RustHashRef", str_view.callee.*.ident);
    try testing.expect(!str_view.args[0].lit.bool_lit);
    try testing.expectEqual(ast.Prim.u64, runtime_tuple[2].prim);

    // The layout: one tagged field, its children in the same order.
    try testing.expectEqual(@as(usize, 1), decoded.expr.call.args.len);
    const layout = decoded.expr.call.args[0].struct_init;
    try testing.expectEqualStrings("r2z.RustHashLayout", layout.type_name.?.named);
    try testing.expectEqual(@as(usize, 1), layout.fields.len);
    try testing.expectEqualStrings("tuple", layout.fields[0].name);
    try testing.expect(layout.fields[0].expr.unary_op.op == .addr_of);
    const children = layout.fields[0].expr.unary_op.operand.array_init.elements;
    try testing.expectEqual(@as(usize, 3), children.len);

    // `&mut D`: the reference layout over the pointee descriptor, with the
    // `r2z.RustHashRef(D, true)` borrow as the runtime type.
    const reference = children[0].type_value.expr.*.call;
    const reference_layout = reference.args[0].struct_init;
    try testing.expectEqualStrings("r2z.RustHashType", reference.callee.*.ident);
    try testing.expectEqualStrings("r2z.RustHashLayout", reference_layout.type_name.?.named);
    try testing.expectEqual(@as(usize, 1), reference_layout.fields.len);
    try testing.expectEqualStrings("reference", reference_layout.fields[0].name);
    try testing.expectEqualStrings("D", reference_layout.fields[0].expr.type_value.named);
    const borrow = reference.generic_args[0].expr.*.call;
    try testing.expectEqualStrings("r2z.RustHashRef", borrow.callee.*.ident);
    try testing.expectEqualStrings("D", borrow.generic_args[0].named);
    try testing.expect(borrow.args[0].lit.bool_lit);

    // `&str`: one reference layout over the `str` descriptor, with the fat
    // `[]const u8` view — not a pointer to it — as the runtime type.
    const str_borrow = children[1].type_value.expr.*.call;
    const str_borrow_layout = str_borrow.args[0].struct_init;
    try testing.expectEqualStrings("r2z.RustHashType", str_borrow.callee.*.ident);
    try testing.expectEqualStrings("r2z.RustHashLayout", str_borrow_layout.type_name.?.named);
    try testing.expectEqualStrings("reference", str_borrow_layout.fields[0].name);
    try testing.expect(str_borrow.generic_args[0] == .expr);
    const str_borrow_view = str_borrow.generic_args[0].expr.*.call;
    try testing.expectEqualStrings("r2z.RustHashRef", str_borrow_view.callee.*.ident);
    try testing.expect(!str_borrow_view.args[0].lit.bool_lit);
    const str_pointee = str_borrow_layout.fields[0].expr.type_value.expr.*.call;
    try testing.expectEqualStrings("r2z.RustHashType", str_pointee.callee.*.ident);
    try testing.expect(str_pointee.generic_args[0] == .slice);
    const str_pointee_layout = str_pointee.args[0].struct_init;
    try testing.expectEqualStrings("r2z.RustHashLayout", str_pointee_layout.type_name.?.named);
    try testing.expectEqualStrings("str", str_pointee_layout.fields[0].name);
    try testing.expect(str_pointee_layout.fields[0].expr == .unit);

    // `u64`: the runtime type against the `.scalar` member naming that source
    // kind, reached through the inline enum rather than spelled as a name.
    const scalar = children[2].type_value.expr.*.call;
    const scalar_layout = scalar.args[0].struct_init;
    try testing.expectEqualStrings("scalar", scalar_layout.fields[0].name);
    try testing.expectEqualStrings(
        "FieldType",
        scalar_layout.fields[0].expr.field_access.target.builtin.name,
    );
    try testing.expectEqualStrings("u64", scalar_layout.fields[0].expr.field_access.field_name);
    const scalar_kind = scalar_layout.fields[0].expr.field_access.target.builtin;
    try testing.expectEqual(@as(usize, 2), scalar_kind.args.len);
    try testing.expect(scalar_kind.args[0] == .type_value);
    try testing.expectEqualStrings("r2z.RustHashLayout", scalar_kind.args[0].type_value.named);
    try testing.expectEqualStrings("scalar", scalar_kind.args[1].lit.str);
    try testing.expectEqual(ast.Prim.u64, scalar.generic_args[0].prim);
}

/// A type wire the decoder must reject only after it already owns the payload
/// box, the element list or the field list it built beside the offending
/// entry. Decoding runs against `testing.allocator`, which reports whatever
/// the failed decode left behind when the test ends.
const MalformedTypeRollback = struct {
    json: []const u8,
    expected: anyerror,
};

test "serialize: type decoder rollback releases what it decoded before the wire failed" {
    const cases = [_]MalformedTypeRollback{
        // An error union whose payload never arrives: the payload box exists
        // before the key is looked up.
        .{ .json =
        \\{"kind":"err_union","err_set":"Failure"}
        , .expected = error.MissingField },
        // An error union whose error set is not a name, behind a decoded
        // payload.
        .{ .json =
        \\{"kind":"err_union",
        \\ "payload":{"kind":"named","name":"Value"},
        \\ "err_set":42}
        , .expected = error.BadWireFormat },
        // An error union whose payload is not a type kind.
        .{ .json =
        \\{"kind":"err_union","payload":{"kind":"mystery"}}
        , .expected = error.UnknownTypeKind },
        // A tuple whose second element is not a type kind, behind a decoded
        // first element.
        .{ .json =
        \\{"kind":"tuple",
        \\ "elements":[{"kind":"named","name":"First"},{"kind":"mystery"}]}
        , .expected = error.UnknownTypeKind },
        // A tuple whose second element is not an object at all, behind a
        // decoded array type.
        .{ .json =
        \\{"kind":"tuple",
        \\ "elements":[{"kind":"array","elem":{"kind":"prim","value":"u8"},"len":2},42]}
        , .expected = error.BadWireFormat },
        // An anonymous struct whose second field has no name, behind a decoded
        // first field.
        .{ .json =
        \\{"kind":"anon_struct",
        \\ "fields":[{"name":"first","ty":{"kind":"prim","value":"u8"}},
        \\           {"name":42,"ty":{"kind":"prim","value":"u16"}}]}
        , .expected = error.BadWireFormat },
        // An anonymous struct whose second field type is not a type kind,
        // behind a decoded first field carrying its own name and box.
        .{ .json =
        \\{"kind":"anon_struct",
        \\ "fields":[{"name":"first","ty":{"kind":"opt","elem":{"kind":"named","name":"Config"}}},
        \\           {"name":"second","ty":{"kind":"mystery"}}]}
        , .expected = error.UnknownTypeKind },
        // An expression type whose payload never arrives: the box exists
        // before the key is looked up.
        .{ .json =
        \\{"kind":"expr"}
        , .expected = error.MissingField },
        // An expression type whose payload is not an expression object, behind
        // the box.
        .{ .json =
        \\{"kind":"expr","expr":42}
        , .expected = error.BadWireFormat },
        // An expression type whose payload is not an expression kind at all.
        .{ .json =
        \\{"kind":"expr","expr":{"kind":"mystery"}}
        , .expected = error.UnknownExprKind },
        // An expression type whose type argument is not a type kind, behind a
        // decoded callee and its box.
        .{ .json =
        \\{"kind":"expr",
        \\ "expr":{"kind":"call","callee":{"kind":"ident","name":"r2z.RustHashType"},
        \\         "generic_args":[{"kind":"mystery"}],"args":[]}}
        , .expected = error.UnknownTypeKind },
        // An expression type whose layout field has no name, behind a decoded
        // struct-init type name.
        .{ .json =
        \\{"kind":"expr",
        \\ "expr":{"kind":"struct_init",
        \\         "type_name":{"kind":"named","name":"r2z.RustHashLayout"},
        \\         "fields":[{"name":42,"expr":{"kind":"unit"}}]}}
        , .expected = error.BadWireFormat },
    };

    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            testing.allocator,
            case.json,
            .{},
        );
        defer parsed.deinit();
        try testing.expectError(
            case.expected,
            serialize.decodeType(testing.allocator, parsed.value),
        );
    }
}

/// A package with one file carrying an import, a typed and documented
/// constant, and a function whose body binds a value: every allocation a
/// package decode owns below the parse is reachable from here.
const nested_package_fixture = ast.Package{
    .name = "rollback_demo",
    .version = "1.2.3",
    .files = &.{
        .{
            .path = "src/root.zig",
            .documentation = "Where the rollback demo lives.",
            .imports = &.{
                .{ .local_name = "std", .module_or_path = "std", .is_pub = false },
            },
            .decls = &.{
                .{ .const_decl = .{
                    .name = "LIMIT",
                    .ty = ast.Type{ .slice = .{
                        .elem = &ast.Type{ .named = "Byte" },
                        .is_const = true,
                    } },
                    .init = .{ .lit = .{ .int = 64 } },
                    .documentation = "How far the loop walks.",
                } },
                .{ .fn_decl = .{
                    .name = "walk",
                    .params = &.{
                        .{ .name = "cursor", .ty = ast.Type{ .opt = &ast.Type{ .named = "Index" } } },
                    },
                    .ret_type = ast.Type{ .ptr = .{ .elem = &ast.Type{ .named = "Byte" } } },
                    .body = .{
                        .stmts = &.{.{ .let_stmt = .{
                            .name = "step",
                            .init = .{ .call = .{
                                .callee = &ast.Expr{ .ident = "advance" },
                                .args = &.{.{ .ident = "cursor" }},
                            } },
                        } }},
                        .expr = &ast.Expr{ .ident = "step" },
                    },
                    .documentation = "Walks the cursor one step.",
                } },
            },
        },
    },
    .zon_deps = &.{
        .{ .name = "dep", .url = "https://example.invalid", .hash = "abc" },
    },
};

/// Release the package shapes this fixture decodes. The fixture is only ever
/// decoded from bytes `serialize.encode` produced, so the name and version
/// were copied by the decoder rather than defaulted to static text.
fn freePackageFixture(allocator: std.mem.Allocator, pkg: ast.Package) void {
    allocator.free(pkg.name);
    allocator.free(pkg.version);
    for (pkg.files) |file| {
        allocator.free(file.path);
        if (file.documentation.len != 0) allocator.free(file.documentation);
        for (file.imports) |import| {
            allocator.free(import.local_name);
            allocator.free(import.module_or_path);
            if (import.documentation.len != 0) allocator.free(import.documentation);
        }
        if (file.imports.len != 0) allocator.free(file.imports);
        for (file.decls) |decl| freePackageFixtureDecl(allocator, decl);
        if (file.decls.len != 0) allocator.free(file.decls);
        for (file.tests) |test_decl| {
            allocator.free(test_decl.name);
            freeRollbackFixtureBlock(allocator, test_decl.body);
        }
        if (file.tests.len != 0) allocator.free(file.tests);
    }
    if (pkg.files.len != 0) allocator.free(pkg.files);
    for (pkg.zon_deps) |dep| {
        allocator.free(dep.name);
        if (dep.url.len != 0) allocator.free(dep.url);
        if (dep.hash.len != 0) allocator.free(dep.hash);
        if (dep.path) |path| allocator.free(path);
    }
    if (pkg.zon_deps.len != 0) allocator.free(pkg.zon_deps);
}

fn freePackageFixtureDecl(allocator: std.mem.Allocator, decl: ast.Decl) void {
    switch (decl) {
        .const_decl => |const_decl| {
            allocator.free(const_decl.name);
            if (const_decl.ty) |ty| freeRollbackFixtureType(allocator, ty);
            freeRollbackFixtureExpr(allocator, const_decl.init);
            if (const_decl.documentation.len != 0) allocator.free(const_decl.documentation);
        },
        .fn_decl => |fn_decl| {
            allocator.free(fn_decl.name);
            if (fn_decl.documentation.len != 0) allocator.free(fn_decl.documentation);
            for (fn_decl.params) |param| {
                allocator.free(param.name);
                freeRollbackFixtureType(allocator, param.ty);
            }
            if (fn_decl.params.len != 0) allocator.free(fn_decl.params);
            freeRollbackFixtureType(allocator, fn_decl.ret_type);
            if (fn_decl.body) |body| freeRollbackFixtureBlock(allocator, body);
        },
        else => {},
    }
}

/// `serialize.decode` owns every allocation it makes, so an exhausted
/// allocator must reach the caller as the allocation failure it is. Reported
/// as a malformed wire instead, the caller rejects a package that never had a
/// syntax problem, and cannot tell a full heap from a broken document.
fn checkPackageDecodePreservesAllocationErrors(
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
) !void {
    const decoded = try serialize.decode(allocator, json_bytes);
    defer freePackageFixture(allocator, decoded);
    try testing.expectEqualStrings("rollback_demo", decoded.name);
    try testing.expectEqualStrings("1.2.3", decoded.version);
    try testing.expectEqual(@as(usize, 1), decoded.files.len);
    const file = decoded.files[0];
    try testing.expectEqualStrings("src/root.zig", file.path);
    try testing.expectEqualStrings("Where the rollback demo lives.", file.documentation);
    try testing.expectEqual(@as(usize, 1), file.imports.len);
    try testing.expectEqualStrings("std", file.imports[0].local_name);
    try testing.expectEqualStrings("std", file.imports[0].module_or_path);
    try testing.expectEqual(@as(usize, 2), file.decls.len);

    const constant = file.decls[0].const_decl;
    try testing.expectEqualStrings("LIMIT", constant.name);
    try testing.expectEqual(@as(i128, 64), constant.init.lit.int);
    try testing.expectEqualStrings("How far the loop walks.", constant.documentation);
    try testing.expect(constant.ty.? == .slice);
    try testing.expect(constant.ty.?.slice.is_const);
    try testing.expectEqualStrings("Byte", constant.ty.?.slice.elem.*.named);

    const function = file.decls[1].fn_decl;
    try testing.expectEqualStrings("walk", function.name);
    try testing.expectEqualStrings("Walks the cursor one step.", function.documentation);
    try testing.expectEqual(@as(usize, 1), function.params.len);
    try testing.expectEqualStrings("cursor", function.params[0].name);
    try testing.expect(function.params[0].ty == .opt);
    try testing.expectEqualStrings("Index", function.params[0].ty.opt.*.named);
    try testing.expect(function.ret_type == .ptr);
    try testing.expectEqualStrings("Byte", function.ret_type.ptr.elem.*.named);
    try testing.expectEqual(@as(usize, 1), function.body.?.stmts.len);
    try testing.expectEqualStrings("step", function.body.?.stmts[0].let_stmt.name);
    try testing.expectEqualStrings(
        "advance",
        function.body.?.stmts[0].let_stmt.init.call.callee.*.ident,
    );
    try testing.expectEqualStrings("step", function.body.?.expr.?.ident);

    try testing.expectEqual(@as(usize, 1), decoded.zon_deps.len);
    try testing.expectEqualStrings("dep", decoded.zon_deps[0].name);
    try testing.expectEqualStrings("https://example.invalid", decoded.zon_deps[0].url);
}

test "serialize: package decoder rollback preserves allocation errors" {
    // The bytes live in their own arena, so the sweep below only ever fails an
    // allocation inside the decoder.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const json_bytes = try serialize.encode(arena.allocator(), &nested_package_fixture);

    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkPackageDecodePreservesAllocationErrors,
        .{json_bytes},
    );

    // A wire that is not JSON at all is still reported as a syntax failure.
    try testing.expectError(
        error.InvalidJson,
        serialize.decode(testing.allocator, "this is not json {"),
    );
}

// ---------------------------------------------------------------------------
// The emission shapes this session's lowering added
//
// Each fixture is the tree the lowerer builds for a construct the emitter
// then writes out, not a tree written to suit the test. The claim under test
// is one of identity: the wire form carries the shape and gives it back, so
// the tree the emitter sees after a package crosses the wire is the tree it
// was handed. Every shape is checked against the decoded tree, re-encoded to
// demand the same bytes, and swept for allocations the decoder fails to
// release.
// ---------------------------------------------------------------------------

/// `lowerGuardedMatch` labels its carrier exactly when an arm hands a value
/// to it. A chain whose arms all leave the function carries no label, and
/// Zig reports a label that names nothing as unused.
const guard_chain_label = "__r2z_match_block";

/// The exit one arm ends on. The value and the label travel together because
/// Zig rejects a `break` with no operand beside one that carries a value.
const guard_chain_exit: ast.Expr = .{ .break_expr = .{
    .value = &ast.Expr{ .ident = "payload" },
    .label = guard_chain_label,
} };

/// One guarded arm: the arm's own statements, then the test, whose body is a
/// block holding nothing but the exit above. Rust decides the arm with its
/// guard before its body does anything, so the body runs inside the test.
const guard_chain_arm_body: ast.Expr = .{ .block = .{
    .label = null,
    .stmts = &.{.{ .expr_stmt = &ast.Expr{ .if_expr = .{
        .cond = &ast.Expr{ .ident = "usable" },
        .then_body = &ast.Expr{ .block = .{
            .label = null,
            .stmts = &.{.{ .expr_stmt = &guard_chain_exit }},
        } },
        .else_body = null,
    } } }},
    .expr = null,
} };

/// One dispatch of the chain: a switch over the bound subject, the guarded
/// arm first and the catch-all last.
const guard_chain_dispatch: ast.Expr = .{ .match_expr = .{
    .target = &ast.Expr{ .ident = "__r2z_match_subject" },
    .arms = &.{
        .{
            .patterns = &.{.{ .enum_literal = "Found" }},
            .body = guard_chain_arm_body,
        },
        .{
            .patterns = &.{.wildcard},
            .body = .{ .ident = "missing" },
        },
    },
} };

/// The chain itself: a labelled block with no tail of its own, because each
/// arm leaves it through the exit that names it.
const guard_chain_block: ast.Block = .{
    .label = guard_chain_label,
    .stmts = &.{
        // The scrutinee is bound once, above the chain, so every dispatch
        // reads the same value and a side-effecting one runs a single time.
        .{ .let_stmt = .{
            .name = "__r2z_match_subject",
            .init = .{ .ident = "input" },
            .is_mut = false,
        } },
        .{ .expr_stmt = &guard_chain_dispatch },
        // Every value was taken by an arm above, so this is only reached when
        // the last of them failed its own guard.
        .{ .expr_stmt = &ast.Expr{ .unreachable_ = {} } },
    },
    .expr = null,
};

/// The chain as a FUNCTION BODY reaches it. `bindGuardChainToLocal` binds the
/// labelled chain to a local and hands the value back by name, because a
/// labelled block is legal Zig only as an `if`/`else` branch: written as a
/// body tail it would be `return <label>: { .. };`, which is not a grammar
/// production. So the body carries no label of its own — the chain's label
/// rides on the block the binding initialises.
const guard_chain_body: ast.Block = .{
    .label = null,
    .stmts = &.{.{ .let_stmt = .{
        .name = "__r2z_chain",
        .init = .{ .block = guard_chain_block },
        .is_mut = false,
    } }},
    .expr = &ast.Expr{ .ident = "__r2z_chain" },
};

const guard_chain_package: ast.Package = .{
    .name = "guard_chain",
    .fingerprint = 0x1,
    .files = &.{.{
        .path = "src/root.zig",
        .decls = &.{.{ .fn_decl = .{
            .name = "classify",
            .ret_type = .{ .named = "Tag" },
            .body = guard_chain_body,
        } }},
    }},
};

test "serialize: a guarded match chain keeps its label, its dispatches and its exits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bytes = try serialize.encode(allocator, &guard_chain_package);
    const decoded = try serialize.decode(allocator, bytes);

    // The decoded tree is still a package the translator would promote, so
    // the wire dropped nothing the validator reads.
    try ast.validateForTranslation(&decoded);

    const fn_body = decoded.files[0].decls[0].fn_decl.body.?;
    // A declaration body declares no label, so the chain reaches it whole in
    // a statement's initialiser and the value comes back off the local by
    // name.
    try testing.expect(fn_body.label == null);
    try testing.expectEqual(@as(usize, 1), fn_body.stmts.len);
    try testing.expect(fn_body.stmts[0] == .let_stmt);
    try testing.expectEqualStrings("__r2z_chain", fn_body.stmts[0].let_stmt.name);
    try testing.expect(fn_body.stmts[0].let_stmt.ty == null);
    try testing.expect(!fn_body.stmts[0].let_stmt.is_mut);
    try testing.expect(fn_body.stmts[0].let_stmt.init == .block);
    try testing.expectEqualStrings("__r2z_chain", fn_body.expr.?.ident);

    const body = fn_body.stmts[0].let_stmt.init.block;
    try testing.expectEqualStrings(guard_chain_label, body.label.?);
    try testing.expect(body.expr == null);
    try testing.expectEqual(@as(usize, 3), body.stmts.len);

    // The subject is bound once, above the chain.
    try testing.expect(body.stmts[0] == .let_stmt);
    try testing.expectEqualStrings("__r2z_match_subject", body.stmts[0].let_stmt.name);
    try testing.expectEqualStrings("input", body.stmts[0].let_stmt.init.ident);
    try testing.expect(!body.stmts[0].let_stmt.is_mut);

    // Each dispatch is a statement that carries a switch.
    try testing.expect(body.stmts[1] == .expr_stmt);
    const dispatch = body.stmts[1].expr_stmt.*;
    try testing.expect(dispatch == .match_expr);
    try testing.expectEqualStrings("__r2z_match_subject", dispatch.match_expr.target.*.ident);
    try testing.expectEqual(@as(usize, 2), dispatch.match_expr.arms.len);

    const guarded = dispatch.match_expr.arms[0];
    try testing.expectEqual(@as(usize, 1), guarded.patterns.len);
    try testing.expect(guarded.patterns[0] == .enum_literal);
    try testing.expectEqualStrings("Found", guarded.patterns[0].enum_literal);
    try testing.expect(guarded.capture == null);
    try testing.expect(guarded.body == .block);

    // The test holds the exit, and the exit names the carrier two scopes
    // below the block that declares the label.
    const arm_block = guarded.body.block;
    try testing.expect(arm_block.label == null);
    try testing.expect(arm_block.expr == null);
    try testing.expectEqual(@as(usize, 1), arm_block.stmts.len);
    const test_expr = arm_block.stmts[0].expr_stmt.*;
    try testing.expect(test_expr == .if_expr);
    try testing.expectEqualStrings("usable", test_expr.if_expr.cond.*.ident);
    try testing.expect(test_expr.if_expr.else_body == null);
    try testing.expect(test_expr.if_expr.then_capture == null);
    const exit_block = test_expr.if_expr.then_body.*;
    try testing.expect(exit_block == .block);
    try testing.expectEqual(@as(usize, 1), exit_block.block.stmts.len);
    const exit_expr = exit_block.block.stmts[0].expr_stmt.*;
    try testing.expect(exit_expr == .break_expr);
    try testing.expectEqualStrings(guard_chain_label, exit_expr.break_expr.label.?);
    try testing.expectEqualStrings("payload", exit_expr.break_expr.value.?.ident);

    // The fall-through past an exhaustive set of literals.
    try testing.expect(body.stmts[2].expr_stmt.* == .unreachable_);

    // The tree that came back is the tree that went out: the same wire again.
    try testing.expectEqualStrings(bytes, try serialize.encode(allocator, &decoded));
}

/// The same carrier in the one place Zig takes a labelled block: an `if`
/// branch. A block tail cannot carry a label, so a statements-only tail hands
/// both its statements and its label to the block they land in. The value the
/// branch yields is the value the exits below hand to that same label.
const guard_chain_branch: ast.Expr = .{ .if_expr = .{
    .cond = &ast.Expr{ .ident = "ready" },
    .then_body = &ast.Expr{ .lit = .{ .str = "pending" } },
    .else_body = &ast.Expr{ .block = guard_chain_block },
} };

const guard_chain_branch_package: ast.Package = .{
    .name = "guard_chain_branch",
    .fingerprint = 0x2,
    .files = &.{.{
        .path = "src/root.zig",
        .decls = &.{.{ .fn_decl = .{
            .name = "step",
            .ret_type = .{ .named = "Tag" },
            .body = .{ .stmts = &.{.{ .expr_stmt = &guard_chain_branch }} },
        } }},
    }},
};

test "serialize: a self-valued labelled block yields through its own label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bytes = try serialize.encode(allocator, &guard_chain_branch_package);
    const decoded = try serialize.decode(allocator, bytes);
    try ast.validateForTranslation(&decoded);

    const body = decoded.files[0].decls[0].fn_decl.body.?;
    try testing.expectEqual(@as(usize, 1), body.stmts.len);
    const branch = body.stmts[0].expr_stmt.*;
    try testing.expect(branch == .if_expr);
    try testing.expectEqualStrings("ready", branch.if_expr.cond.*.ident);
    try testing.expectEqualStrings("pending", branch.if_expr.then_body.*.lit.str);

    // The branch is a block that carries its own label and no tail: its value
    // is what its own exits hand out, never the value of a last expression.
    const carrier = branch.if_expr.else_body.?.*;
    try testing.expect(carrier == .block);
    try testing.expectEqualStrings(guard_chain_label, carrier.block.label.?);
    try testing.expect(carrier.block.expr == null);

    // The exit inside the carrier names the carrier: the block is valued by
    // its own label and by nothing else.
    const arm_block = carrier.block.stmts[1].expr_stmt.*.match_expr.arms[0].body.block;
    const exit_block = arm_block.stmts[0].expr_stmt.*.if_expr.then_body.*;
    const exit_expr = exit_block.block.stmts[0].expr_stmt.*;
    try testing.expect(exit_expr == .break_expr);
    try testing.expectEqualStrings(carrier.block.label.?, exit_expr.break_expr.label.?);
    try testing.expect(exit_expr.break_expr.value.?.* == .ident);
    try testing.expectEqualStrings("payload", exit_expr.break_expr.value.?.ident);

    try testing.expectEqualStrings(bytes, try serialize.encode(allocator, &decoded));
}

/// An arm that destructures a payload cannot keep its struct pattern: the
/// emitter's destructure block breaks out with the arm's own value, and it
/// cannot hold the exit that hands that value to the chain. Such an arm
/// dispatches on the tag and the payload name instead, and reads each field
/// into a binding of its own ahead of the guard that reads them.
const destructured_arm: ast.MatchArm = .{
    .patterns = &.{
        .{ .enum_literal = "Found" },
        .{ .binding = "__r2z_match_payload" },
    },
    .body = .{ .block = .{
        .label = null,
        .stmts = &.{
            .{ .let_stmt = .{
                .name = "item",
                .init = .{ .field_access = .{
                    .target = &ast.Expr{ .ident = "__r2z_match_payload" },
                    .field_name = "item",
                } },
                .is_mut = false,
            } },
            .{ .expr_stmt = &ast.Expr{ .if_expr = .{
                .cond = &ast.Expr{ .ident = "item.usable" },
                .then_body = &ast.Expr{ .block = .{
                    .label = null,
                    .stmts = &.{.{ .expr_stmt = &guard_chain_exit }},
                } },
                .else_body = null,
            } } },
        },
        .expr = null,
    } },
};

const destructured_dispatch: ast.Expr = .{ .match_expr = .{
    .target = &ast.Expr{ .ident = "__r2z_match_subject" },
    .arms = &.{
        destructured_arm,
        .{
            .patterns = &.{.wildcard},
            .body = .{ .ident = "missing" },
        },
    },
} };

const destructured_chain_block: ast.Block = .{
    .label = guard_chain_label,
    .stmts = &.{
        .{ .let_stmt = .{
            .name = "__r2z_match_subject",
            .init = .{ .ident = "input" },
            .is_mut = false,
        } },
        .{ .expr_stmt = &destructured_dispatch },
        .{ .expr_stmt = &ast.Expr{ .unreachable_ = {} } },
    },
    .expr = null,
};

/// The same chain in the shape a function body holds it: bound to a local and
/// returned by name, so the body itself declares no label.
const destructured_body: ast.Block = .{
    .label = null,
    .stmts = &.{.{ .let_stmt = .{
        .name = "__r2z_chain",
        .init = .{ .block = destructured_chain_block },
        .is_mut = false,
    } }},
    .expr = &ast.Expr{ .ident = "__r2z_chain" },
};

const destructured_package: ast.Package = .{
    .name = "destructured_arm",
    .fingerprint = 0x3,
    .files = &.{.{
        .path = "src/root.zig",
        .decls = &.{.{ .fn_decl = .{
            .name = "read",
            .ret_type = .{ .named = "Tag" },
            .body = destructured_body,
        } }},
    }},
};

test "serialize: a field-slot destructuring binding keeps its payload and field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bytes = try serialize.encode(allocator, &destructured_package);
    const decoded = try serialize.decode(allocator, bytes);
    try ast.validateForTranslation(&decoded);

    const fn_body = decoded.files[0].decls[0].fn_decl.body.?;
    try testing.expect(fn_body.label == null);
    try testing.expectEqual(@as(usize, 1), fn_body.stmts.len);
    try testing.expectEqualStrings("__r2z_chain", fn_body.stmts[0].let_stmt.name);
    try testing.expect(fn_body.stmts[0].let_stmt.init == .block);
    try testing.expectEqualStrings("__r2z_chain", fn_body.expr.?.ident);

    const body = fn_body.stmts[0].let_stmt.init.block;
    try testing.expectEqualStrings(guard_chain_label, body.label.?);
    const dispatch = body.stmts[1].expr_stmt.*;
    try testing.expect(dispatch == .match_expr);
    try testing.expectEqual(@as(usize, 2), dispatch.match_expr.arms.len);

    // The dispatch names the tag and the payload; the payload is bound, not
    // captured, because a prong that captures one has no field slot left.
    const arm = dispatch.match_expr.arms[0];
    try testing.expect(arm.capture == null);
    try testing.expectEqual(@as(usize, 2), arm.patterns.len);
    try testing.expect(arm.patterns[0] == .enum_literal);
    try testing.expectEqualStrings("Found", arm.patterns[0].enum_literal);
    try testing.expect(arm.patterns[1] == .binding);
    try testing.expectEqualStrings("__r2z_match_payload", arm.patterns[1].binding);

    // The field slot is read out of the payload into its own binding, ahead
    // of the guard that reads it, and it is `const`: nothing rebinds it.
    try testing.expect(arm.body == .block);
    const arm_block = arm.body.block;
    try testing.expectEqual(@as(usize, 2), arm_block.stmts.len);
    const field_binding = arm_block.stmts[0].let_stmt;
    try testing.expectEqualStrings("item", field_binding.name);
    try testing.expect(field_binding.ty == null);
    try testing.expect(!field_binding.is_mut);
    try testing.expect(field_binding.init == .field_access);
    const payload = field_binding.init.field_access.target.*;
    try testing.expectEqualStrings("__r2z_match_payload", payload.ident);
    try testing.expectEqualStrings("item", field_binding.init.field_access.field_name);

    // The guard that reads the binding still exits through the carrier.
    const exit_expr = arm_block.stmts[1].expr_stmt.*.if_expr.then_body.*;
    try testing.expect(exit_expr.block.stmts[0].expr_stmt.* == .break_expr);
    try testing.expectEqualStrings(
        guard_chain_label,
        exit_expr.block.stmts[0].expr_stmt.*.break_expr.label.?,
    );

    try testing.expectEqualStrings(bytes, try serialize.encode(allocator, &decoded));
}

/// An operand that owns runtime storage is bound mutable and released by the
/// `defer` right behind it. The binding is what makes the release correct:
/// the temporary's address is what the release writes through, and every move
/// empties the very place that defer names.
const comparison_operand_type: ast.Type = .{ .generic = .{
    .name = "Vec",
    .params = &.{.{ .prim = .u8 }},
} };

const comparison_temporary_block: ast.Block = .{
    .label = null,
    .stmts = &.{
        .{ .let_stmt = .{
            .name = "__r2z_compare0",
            .ty = comparison_operand_type,
            .init = .{ .call = .{
                .callee = &ast.Expr{ .ident = "cloneInto" },
                .args = &.{.{ .ident = "left" }},
            } },
            .is_mut = true,
        } },
        .{ .defer_stmt = .{ .expr = .{ .call = .{
            .callee = &ast.Expr{ .ident = "r2z.alloc.dropTemporary" },
            .args = &.{
                .{ .ident = "allocator" },
                .{ .unary_op = .{
                    .op = .addr_of,
                    .operand = &ast.Expr{ .ident = "__r2z_compare0" },
                } },
            },
        } } } },
        .{ .let_stmt = .{
            .name = "__r2z_compare1",
            .ty = comparison_operand_type,
            .init = .{ .ident = "right" },
            .is_mut = true,
        } },
        .{ .defer_stmt = .{ .expr = .{ .call = .{
            .callee = &ast.Expr{ .ident = "r2z.alloc.dropTemporary" },
            .args = &.{
                .{ .ident = "allocator" },
                .{ .unary_op = .{
                    .op = .addr_of,
                    .operand = &ast.Expr{ .ident = "__r2z_compare1" },
                } },
            },
        } } } },
    },
    .expr = &ast.Expr{ .bin_op = .{
        .op = .equal,
        .lhs = &ast.Expr{ .ident = "__r2z_compare0" },
        .rhs = &ast.Expr{ .ident = "__r2z_compare1" },
    } },
};

const comparison_temporary_expr: ast.Expr = .{ .block = comparison_temporary_block };

const comparison_temporary_package: ast.Package = .{
    .name = "comparison_temporary",
    .fingerprint = 0x4,
    .files = &.{.{
        .path = "src/root.zig",
        .decls = &.{.{ .fn_decl = .{
            .name = "same",
            .ret_type = .{ .prim = .bool },
            .body = .{ .expr = &comparison_temporary_expr },
        } }},
    }},
};

test "serialize: a comparison temporary keeps its type, its mutability and its release" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bytes = try serialize.encode(allocator, &comparison_temporary_package);
    const decoded = try serialize.decode(allocator, bytes);
    try ast.validateForTranslation(&decoded);

    const fn_body = decoded.files[0].decls[0].fn_decl.body.?;
    try testing.expect(fn_body.label == null);
    // The comparison block is the body's TAIL, not its statement list: the
    // release each operand is armed with has to run in the scope that owns
    // the binding, so the statements stay inside the block the emitter writes
    // the value out of.
    try testing.expectEqual(@as(usize, 0), fn_body.stmts.len);
    try testing.expect(fn_body.expr.?.* == .block);
    const body = fn_body.expr.?.block;
    try testing.expect(body.label == null);
    try testing.expectEqual(@as(usize, 4), body.stmts.len);

    // The binding is typed and mutable: the release writes through its
    // address, and it takes the allocator the caller owns.
    const binding = body.stmts[0].let_stmt;
    try testing.expectEqualStrings("__r2z_compare0", binding.name);
    try testing.expect(binding.is_mut);
    try testing.expect(binding.ty.? == .generic);
    try testing.expectEqualStrings("Vec", binding.ty.?.generic.name);
    try testing.expectEqual(@as(usize, 1), binding.ty.?.generic.params.len);
    try testing.expect(binding.ty.?.generic.params[0] == .prim);
    try testing.expectEqual(ast.Prim.u8, binding.ty.?.generic.params[0].prim);
    try testing.expect(binding.init == .call);
    try testing.expectEqualStrings("cloneInto", binding.init.call.callee.*.ident);

    // The release is a plain `defer`, not an `errdefer`: both exits of the
    // comparison need it, and one of them is not an error.
    const release = body.stmts[1].defer_stmt;
    try testing.expect(!release.is_errdefer);
    try testing.expect(release.expr == .call);
    try testing.expectEqualStrings("r2z.alloc.dropTemporary", release.expr.call.callee.*.ident);
    try testing.expectEqual(@as(usize, 2), release.expr.call.args.len);
    try testing.expectEqualStrings("allocator", release.expr.call.args[0].ident);
    try testing.expect(release.expr.call.args[1] == .unary_op);
    try testing.expectEqual(ast.UnaryOpKind.addr_of, release.expr.call.args[1].unary_op.op);
    const released = release.expr.call.args[1].unary_op.operand.*;
    try testing.expectEqualStrings("__r2z_compare0", released.ident);

    // The second operand is bound the same way, and the comparison itself is
    // the block's tail: the block exists to release what it compared.
    try testing.expectEqualStrings("__r2z_compare1", body.stmts[2].let_stmt.name);
    try testing.expect(body.stmts[2].let_stmt.is_mut);
    try testing.expectEqualStrings(
        "__r2z_compare1",
        body.stmts[3].defer_stmt.expr.call.args[1].unary_op.operand.*.ident,
    );
    const tail = body.expr.?.*;
    try testing.expect(tail == .bin_op);
    try testing.expectEqual(ast.BinOpKind.equal, tail.bin_op.op);
    try testing.expectEqualStrings("__r2z_compare0", tail.bin_op.lhs.*.ident);
    try testing.expectEqualStrings("__r2z_compare1", tail.bin_op.rhs.*.ident);

    try testing.expectEqualStrings(bytes, try serialize.encode(allocator, &decoded));
}

/// A binding the source never reads is discarded by assigning it to `_`. That
/// is not a wildcard pattern: `unusedBindingAsDiscard` in `emit.zig` builds an
/// ordinary `.assign` whose target is the ident `_`, and nine such idents ride
/// the wire in `test/golden/zig_src/hex/src/test.zig`, so the discard has to
/// survive as the assignment it is.
const discard_assign_package: ast.Package = .{ .name = "discard_assign", .fingerprint = 0x5, .files = &.{
    .{ .path = "src/root.zig", .decls = &.{.{ .fn_decl = .{
        .name = "advance",
        .ret_type = .{ .prim = .void_type },
        .body = .{ .stmts = &.{.{ .assign = .{
            .target = .{ .ident = "_" },
            .val = .{ .call = .{
                .callee = &ast.Expr{ .ident = "next" },
                .args = &.{
                    .{ .ident = "cursor" },
                    .{ .unary_op = .{
                        .op = .addr_of,
                        .operand = &ast.Expr{ .ident = "slot" },
                    } },
                },
            } },
        } }} },
    } }} },
} };

test "serialize: an assignment to the discard ident keeps its target and its operator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bytes = try serialize.encode(allocator, &discard_assign_package);
    const decoded = try serialize.decode(allocator, bytes);
    try ast.validateForTranslation(&decoded);

    const body = decoded.files[0].decls[0].fn_decl.body.?;
    try testing.expectEqual(@as(usize, 1), body.stmts.len);
    const assign = body.stmts[0].assign;

    // The target is the ident `_`, not a wildcard and not a binding: the wire
    // names it, and the value it discards comes back whole.
    try testing.expect(assign.target == .ident);
    try testing.expectEqualStrings("_", assign.target.ident);
    try testing.expectEqual(ast.AssignOp.assign, assign.op);

    try testing.expect(assign.val == .call);
    try testing.expectEqualStrings("next", assign.val.call.callee.*.ident);
    try testing.expectEqual(@as(usize, 2), assign.val.call.args.len);
    try testing.expectEqualStrings("cursor", assign.val.call.args[0].ident);
    try testing.expect(assign.val.call.args[1] == .unary_op);
    try testing.expectEqual(ast.UnaryOpKind.addr_of, assign.val.call.args[1].unary_op.op);
    try testing.expectEqualStrings("slot", assign.val.call.args[1].unary_op.operand.*.ident);

    // Spelled out on the wire: an `assign` whose target is the ident `_`.
    const wire_stmt = try serialize.encodeStmt(allocator, body.stmts[0]);
    try testing.expectEqualStrings("assign", wire_stmt.object.get("kind").?.string);
    try testing.expectEqualStrings("ident", wire_stmt.object.get("target").?.object.get("kind").?.string);
    try testing.expectEqualStrings("_", wire_stmt.object.get("target").?.object.get("name").?.string);
    try testing.expectEqualStrings("assign", wire_stmt.object.get("op").?.string);

    try testing.expectEqualStrings(bytes, try serialize.encode(allocator, &decoded));
}

/// A `continue` that names a loop is an expression, not the loop's own
/// `continue_expr` slot: the labelled restart the emitter writes is
/// `continue :outer;` standing on its own inside the body. Only the loop's own
/// field was decoded before, so this is the shape a reader could confuse for it.
const labelled_continue_package: ast.Package = .{ .name = "labelled_continue", .fingerprint = 0x6, .files = &.{
    .{ .path = "src/root.zig", .decls = &.{.{ .fn_decl = .{
        .name = "step",
        .ret_type = .{ .prim = .void_type },
        .body = .{ .stmts = &.{.{ .expr_stmt = &ast.Expr{ .while_expr = .{
            .cond = &ast.Expr{ .ident = "ready" },
            .body = .{ .stmts = &.{
                .{ .expr_stmt = &ast.Expr{ .continue_expr = .{ .label = "outer" } } },
            } },
            .label = "outer",
        } } }} },
    } }} },
} };

test "serialize: a continue expression keeps the loop it names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bytes = try serialize.encode(allocator, &labelled_continue_package);
    const decoded = try serialize.decode(allocator, bytes);
    try ast.validateForTranslation(&decoded);

    const body = decoded.files[0].decls[0].fn_decl.body.?;
    try testing.expectEqual(@as(usize, 1), body.stmts.len);
    try testing.expect(body.stmts[0].expr_stmt.* == .while_expr);
    const loop = body.stmts[0].expr_stmt.*.while_expr;

    // The loop keeps its own continue slot empty; the label the emitter wrote
    // is on the `continue` inside the body, which is a different field.
    try testing.expect(loop.continue_expr == null);
    try testing.expect(loop.captures == null);
    try testing.expectEqualStrings("outer", loop.label.?);
    try testing.expectEqualStrings("ready", loop.cond.*.ident);

    try testing.expectEqual(@as(usize, 1), loop.body.stmts.len);
    const restart = loop.body.stmts[0].expr_stmt.*;
    try testing.expect(restart == .continue_expr);
    try testing.expectEqualStrings("outer", restart.continue_expr.label.?);

    // Spelled out on the wire: a `continue_expr` expression carrying a label,
    // not a loop with a continue slot filled in.
    const wire_expr = try serialize.encodeExpr(allocator, loop.body.stmts[0].expr_stmt.*);
    try testing.expectEqualStrings("continue_expr", wire_expr.object.get("kind").?.string);
    try testing.expectEqualStrings("outer", wire_expr.object.get("label").?.string);

    try testing.expectEqualStrings(bytes, try serialize.encode(allocator, &decoded));
}

/// A block may carry a label AND hand out a value: the emitter writes both when
/// a labelled chain is the tail of a function. The fixtures that existed
/// covered a label with no tail and no label with a tail, so the combination —
/// the one the emitter actually produces — was never on the wire.
const labelled_tail_package: ast.Package = .{
    .name = "labelled_tail",
    .fingerprint = 0x7,
    .files = &.{.{ .path = "src/root.zig", .decls = &.{.{ .fn_decl = .{
        .name = "pick",
        .ret_type = .{ .prim = .u8 },
        .body = .{ .expr = &ast.Expr{ .block = .{
            .label = "chosen",
            .stmts = &.{.{ .let_stmt = .{
                .name = "value",
                .init = .{ .call = .{
                    .callee = &ast.Expr{ .ident = "select" },
                    .args = &.{.{ .ident = "candidate" }},
                } },
            } }},
            .expr = &ast.Expr{ .ident = "value" },
        } } },
    } }} }},
};

test "serialize: a labelled block keeps both its label and its value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bytes = try serialize.encode(allocator, &labelled_tail_package);
    const decoded = try serialize.decode(allocator, bytes);
    try ast.validateForTranslation(&decoded);

    const body = decoded.files[0].decls[0].fn_decl.body.?;

    // The label belongs to the block expression, not to the declaration body:
    // a declaration body is never labelled, and dropping the label here would
    // leave a `break` inside pointing at nothing.
    try testing.expect(body.label == null);
    try testing.expect(body.expr.?.* == .block);
    const block = body.expr.?.*.block;
    try testing.expectEqualStrings("chosen", block.label.?);

    try testing.expectEqual(@as(usize, 1), block.stmts.len);
    try testing.expectEqualStrings("value", block.stmts[0].let_stmt.name);
    try testing.expect(block.stmts[0].let_stmt.init == .call);
    try testing.expectEqualStrings("select", block.stmts[0].let_stmt.init.call.callee.*.ident);

    // The tail the block hands out survives beside the label.
    try testing.expect(block.expr.?.* == .ident);
    try testing.expectEqualStrings("value", block.expr.?.*.ident);

    // Spelled out on the wire: one object carrying a label AND a non-null expr.
    // `encodeExpr` wraps a block in a `{kind, block}` envelope, so the label and
    // the tail live under "block", not beside "kind" on the expression object.
    const wire_expr = try serialize.encodeExpr(allocator, body.expr.?.*);
    try testing.expectEqualStrings("block", wire_expr.object.get("kind").?.string);
    const wire_block = wire_expr.object.get("block").?.object;
    try testing.expectEqualStrings("chosen", wire_block.get("label").?.string);
    const wire_tail = wire_block.get("expr").?.object;
    try testing.expectEqualStrings("ident", wire_tail.get("kind").?.string);
    try testing.expectEqualStrings("value", wire_tail.get("name").?.string);

    try testing.expectEqualStrings(bytes, try serialize.encode(allocator, &decoded));
}

const allowzero_byte_type: ast.Type = .{ .prim = .u8 };

/// `*align(1) allowzero` is what a fat pointer's data word is: both `emit.zig`
/// and `lower.zig` hand it over, and every fixture decoded it with the default
/// `false` and no alignment, so nothing pinned that the flag and the alignment
/// survive at all.
const allowzero_ptr_package: ast.Package = .{
    .name = "allowzero_ptr",
    .fingerprint = 0x8,
    .files = &.{.{ .path = "src/root.zig", .decls = &.{.{ .fn_decl = .{
        .name = "store",
        .params = &.{
            .{ .name = "slot", .ty = .{ .ptr = .{
                .elem = &allowzero_byte_type,
                .is_allowzero = true,
                .alignment = 1,
            } } },
        },
        .ret_type = .{ .prim = .bool },
        .body = .{ .expr = &ast.Expr{ .ident = "slot" } },
    } }} }},
};

test "serialize: an allowzero pointer keeps its flag and its alignment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bytes = try serialize.encode(allocator, &allowzero_ptr_package);
    const decoded = try serialize.decode(allocator, bytes);
    try ast.validateForTranslation(&decoded);

    const param = decoded.files[0].decls[0].fn_decl.params[0];
    try testing.expectEqualStrings("slot", param.name);
    try testing.expect(param.ty == .ptr);

    const pointer = param.ty.ptr;
    try testing.expect(pointer.is_allowzero);
    try testing.expectEqual(@as(u32, 1), pointer.alignment.?);
    try testing.expect(!pointer.is_const);
    try testing.expectEqual(ast.PtrSize.one, pointer.size);
    try testing.expect(pointer.elem.* == .prim);
    try testing.expectEqual(ast.Prim.u8, pointer.elem.*.prim);

    // Spelled out on the wire: `is_allowzero` true and `alignment` 1, not the
    // two defaults every other fixture read back.
    const wire_ty = try serialize.encodeType(allocator, param.ty);
    try testing.expect(wire_ty.object.get("is_allowzero").?.bool);
    try testing.expectEqual(@as(i64, 1), wire_ty.object.get("alignment").?.integer);

    try testing.expectEqualStrings(bytes, try serialize.encode(allocator, &decoded));
}

/// Every compound operator the emitter can write. `hex` lands `add_assign` on
/// the wire and nothing decoded one before, so the whole table is walked: an
/// operator the codec spelled differently would otherwise read back as a
/// different assignment, or as a plain `=` that clobbers what it was meant to
/// add to.
const compound_assign_ops = [_]struct { op: ast.AssignOp, wire: []const u8 }{
    .{ .op = .assign, .wire = "assign" },
    .{ .op = .add_assign, .wire = "add_assign" },
    .{ .op = .add_assign_wrap, .wire = "add_assign_wrap" },
    .{ .op = .sub_assign, .wire = "sub_assign" },
    .{ .op = .sub_assign_wrap, .wire = "sub_assign_wrap" },
    .{ .op = .mul_assign, .wire = "mul_assign" },
    .{ .op = .mul_assign_wrap, .wire = "mul_assign_wrap" },
    .{ .op = .div_assign, .wire = "div_assign" },
    .{ .op = .mod_assign, .wire = "mod_assign" },
    .{ .op = .bit_and_assign, .wire = "bit_and_assign" },
    .{ .op = .bit_or_assign, .wire = "bit_or_assign" },
    .{ .op = .bit_xor_assign, .wire = "bit_xor_assign" },
    .{ .op = .shl_assign, .wire = "shl_assign" },
    .{ .op = .shr_assign, .wire = "shr_assign" },
};

test "serialize: every compound assignment operator roundtrips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stmts: [compound_assign_ops.len]ast.Stmt = undefined;
    for (compound_assign_ops, 0..) |entry, index| {
        stmts[index] = .{ .assign = .{
            .target = .{ .ident = "acc" },
            .val = .{ .ident = "step" },
            .op = entry.op,
        } };
    }

    const accumulate: ast.Package = .{ .name = "compound_assign", .fingerprint = 0x9, .files = &.{
        .{ .path = "src/root.zig", .decls = &.{.{ .fn_decl = .{
            .name = "accumulate",
            .ret_type = .{ .prim = .void_type },
            .body = .{ .stmts = &stmts },
        } }} },
    } };

    const bytes = try serialize.encode(allocator, &accumulate);
    const decoded = try serialize.decode(allocator, bytes);
    try ast.validateForTranslation(&decoded);

    const body = decoded.files[0].decls[0].fn_decl.body.?;
    try testing.expectEqual(@as(usize, compound_assign_ops.len), body.stmts.len);
    for (compound_assign_ops, body.stmts) |entry, stmt| {
        try testing.expectEqual(entry.op, stmt.assign.op);
        try testing.expectEqualStrings("acc", stmt.assign.target.ident);
        try testing.expectEqualStrings("step", stmt.assign.val.ident);

        // Each operator keeps its own spelling on the wire rather than
        // collapsing onto `assign`.
        const wire_stmt = try serialize.encodeStmt(allocator, stmt);
        try testing.expectEqualStrings(entry.wire, wire_stmt.object.get("op").?.string);
    }

    try testing.expectEqualStrings(bytes, try serialize.encode(allocator, &decoded));
}

/// A loop with no captures has two spellings: the encoder always writes the
/// key, and a wire written before captures existed leaves it out. Both must
/// read back as the same loop, because absent maps to the `null` the field
/// already holds for "no capture" — never to an empty capture list that the
/// emitter would then print as `| |`.
const capture_free_loop_package: ast.Package = .{ .name = "capture_free_loop", .fingerprint = 0xa, .files = &.{
    .{ .path = "src/root.zig", .decls = &.{.{ .fn_decl = .{
        .name = "walk",
        .ret_type = .{ .prim = .void_type },
        .body = .{ .stmts = &.{.{ .expr_stmt = &ast.Expr{ .while_expr = .{
            .cond = &ast.Expr{ .ident = "ready" },
            .continue_expr = &ast.Expr{ .ident = "advance" },
            .body = .{ .stmts = &.{
                .{ .expr_stmt = &ast.Expr{ .ident = "step" } },
            } },
        } } }} },
    } }} },
} };

/// The same package with the loop's `captures` key deleted rather than null.
const captures_absent_row =
    \\{"format_version":1,"name":"capture_free_loop","version":"0.0.0","fingerprint":"10","files":[
    \\{"path":"src/root.zig","imports":[],"decls":[
    \\{"kind":"fn_decl","value":{"name":"walk","is_pub":true,"is_test":false,"params":[],
    \\"ret_type":{"kind":"prim","value":"void_type"},
    \\"body":{"label":null,"stmts":[
    \\{"kind":"expr_stmt","expr":{"kind":"while_expr",
    \\"cond":{"kind":"ident","name":"ready"},
    \\"continue_expr":{"kind":"ident","name":"advance"},
    \\"body":{"label":null,"stmts":[
    \\{"kind":"expr_stmt","expr":{"kind":"ident","name":"step"}}],"expr":null},
    \\"label":null,"else_body":null}}],"expr":null},
    \\"generic_params":[]}}],
    \\"tests":[]}],"zon_deps":[]}
;

test "serialize: a loop's captures key reads the same absent as it does null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bytes = try serialize.encode(allocator, &capture_free_loop_package);

    // The encoder spells "no capture" as a present, null key rather than an
    // absent one, so the two wires below differ in that one value and nothing
    // else.
    var encoded = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer encoded.deinit();
    const encoded_loop = encoded.value.object.get("files").?.array.items[0]
        .object.get("decls").?.array.items[0].object.get("value").?
        .object.get("body").?.object.get("stmts").?.array.items[0]
        .object.get("expr").?.object;
    try testing.expect(encoded_loop.get("captures") != null);
    try testing.expect(encoded_loop.get("captures").? == .null);

    const with_null = try serialize.decode(allocator, bytes);
    try ast.validateForTranslation(&with_null);
    const absent = try serialize.decode(allocator, captures_absent_row);
    try ast.validateForTranslation(&absent);

    for ([_]*const ast.Package{ &with_null, &absent }) |candidate| {
        try testing.expectEqualStrings("capture_free_loop", candidate.name);
        try testing.expectEqual(@as(u64, 10), candidate.fingerprint.?);

        const body = candidate.files[0].decls[0].fn_decl.body.?;
        try testing.expectEqual(@as(usize, 1), body.stmts.len);
        const loop = body.stmts[0].expr_stmt.*.while_expr;

        // No capture in either spelling — not an empty list.
        try testing.expect(loop.captures == null);
        try testing.expectEqualStrings("ready", loop.cond.*.ident);
        try testing.expectEqualStrings("advance", loop.continue_expr.?.*.ident);
        try testing.expect(loop.label == null);
        try testing.expect(loop.else_body == null);
        try testing.expectEqual(@as(usize, 1), loop.body.stmts.len);
        try testing.expectEqualStrings("step", loop.body.stmts[0].expr_stmt.*.ident);
    }

    // The absent key is not a second spelling of the wire: it reads back as
    // exactly the bytes the encoder writes, key included.
    try testing.expectEqualStrings(bytes, try serialize.encode(allocator, &absent));
}

// Release one decoded shape. A node kind no fixture builds is not freed
// here, and a fixture that grows one without teaching this function about it
// fails the sweep below with a leak rather than passing quietly.
fn freeShapeExpr(allocator: std.mem.Allocator, expr: ast.Expr) void {
    switch (expr) {
        .lit => |literal| freeShapeLiteral(allocator, literal),
        .ident, .panic_, .unsupported => |name| allocator.free(name),
        .field_access => |access| {
            freeShapeExpr(allocator, access.target.*);
            allocator.destroy(@constCast(access.target));
            allocator.free(access.field_name);
        },
        .call => |call| {
            freeShapeExpr(allocator, call.callee.*);
            allocator.destroy(@constCast(call.callee));
            for (call.generic_args) |argument| freeShapeType(allocator, argument);
            if (call.generic_args.len != 0) allocator.free(call.generic_args);
            for (call.args) |arg| freeShapeExpr(allocator, arg);
            if (call.args.len != 0) allocator.free(call.args);
        },
        .block => |block| freeShapeBlock(allocator, block),
        .match_expr => |match| {
            freeShapeExpr(allocator, match.target.*);
            allocator.destroy(@constCast(match.target));
            for (match.arms) |arm| {
                for (arm.patterns) |pattern| freeShapePattern(allocator, pattern);
                if (arm.patterns.len != 0) allocator.free(arm.patterns);
                if (arm.capture) |capture| allocator.free(capture.name);
                freeShapeExpr(allocator, arm.body);
            }
            if (match.arms.len != 0) allocator.free(match.arms);
        },
        .bin_op => |bin_op| {
            freeShapeExpr(allocator, bin_op.lhs.*);
            allocator.destroy(@constCast(bin_op.lhs));
            freeShapeExpr(allocator, bin_op.rhs.*);
            allocator.destroy(@constCast(bin_op.rhs));
        },
        .unary_op => |unary_op| {
            freeShapeExpr(allocator, unary_op.operand.*);
            allocator.destroy(@constCast(unary_op.operand));
        },
        .if_expr => |if_expr| {
            freeShapeExpr(allocator, if_expr.cond.*);
            allocator.destroy(@constCast(if_expr.cond));
            freeShapeExpr(allocator, if_expr.then_body.*);
            allocator.destroy(@constCast(if_expr.then_body));
            if (if_expr.else_body) |else_body| {
                freeShapeExpr(allocator, else_body.*);
                allocator.destroy(@constCast(else_body));
            }
            if (if_expr.then_capture) |capture| allocator.free(capture.name);
            if (if_expr.else_capture) |capture| allocator.free(capture.name);
        },
        .break_expr => |break_expr| {
            if (break_expr.label) |label| allocator.free(label);
            if (break_expr.value) |value| {
                freeShapeExpr(allocator, value.*);
                allocator.destroy(@constCast(value));
            }
        },
        else => {},
    }
}

fn freeShapeBlock(allocator: std.mem.Allocator, block: ast.Block) void {
    if (block.label) |label| allocator.free(label);
    for (block.stmts) |stmt| switch (stmt) {
        .let_stmt => |let_stmt| {
            allocator.free(let_stmt.name);
            if (let_stmt.ty) |ty| freeShapeType(allocator, ty);
            freeShapeExpr(allocator, let_stmt.init);
        },
        .defer_stmt => |defer_stmt| freeShapeExpr(allocator, defer_stmt.expr),
        .expr_stmt => |expr_ptr| {
            freeShapeExpr(allocator, expr_ptr.*);
            allocator.destroy(@constCast(expr_ptr));
        },
        .assign => |assign| {
            freeShapeExpr(allocator, assign.target);
            freeShapeExpr(allocator, assign.val);
        },
    };
    if (block.stmts.len != 0) allocator.free(block.stmts);
    if (block.expr) |expr_ptr| {
        freeShapeExpr(allocator, expr_ptr.*);
        allocator.destroy(@constCast(expr_ptr));
    }
}

fn freeShapeLiteral(allocator: std.mem.Allocator, literal: ast.Literal) void {
    switch (literal) {
        .str, .error_tag => |text| allocator.free(text),
        else => {},
    }
}

fn freeShapePattern(allocator: std.mem.Allocator, pattern: ast.Pattern) void {
    switch (pattern) {
        .wildcard => {},
        .binding, .enum_literal => |name| allocator.free(name),
        .lit => |literal| freeShapeLiteral(allocator, literal),
        .tuple => |patterns| {
            for (patterns) |item| freeShapePattern(allocator, item);
            if (patterns.len != 0) allocator.free(patterns);
        },
        .struct_pat => |struct_pattern| {
            if (struct_pattern.name) |name| allocator.free(name);
            for (struct_pattern.fields) |field| {
                allocator.free(field.name);
                freeShapePattern(allocator, field.pat);
            }
            if (struct_pattern.fields.len != 0) allocator.free(struct_pattern.fields);
        },
        .range_pat => |range_pattern| {
            if (range_pattern.lo) |lo| freeShapeLiteral(allocator, lo);
            if (range_pattern.hi) |hi| freeShapeLiteral(allocator, hi);
        },
    }
}

fn freeShapeType(allocator: std.mem.Allocator, ty: ast.Type) void {
    switch (ty) {
        .named => |name| allocator.free(name),
        .generic => |generic| {
            allocator.free(generic.name);
            for (generic.params) |param| freeShapeType(allocator, param);
            if (generic.params.len != 0) allocator.free(generic.params);
        },
        else => {},
    }
}

fn checkGuardChainDecodeAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeExpr(allocator, value);
    defer freeShapeExpr(allocator, decoded);
    try testing.expect(decoded == .block);
    try testing.expectEqualStrings(guard_chain_label, decoded.block.label.?);
}

fn checkBranchDecodeAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeExpr(allocator, value);
    defer freeShapeExpr(allocator, decoded);
    try testing.expect(decoded == .if_expr);
    try testing.expectEqualStrings(guard_chain_label, decoded.if_expr.else_body.?.block.label.?);
}

fn checkDestructuredDecodeAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeExpr(allocator, value);
    defer freeShapeExpr(allocator, decoded);
    const arm = decoded.block.stmts[1].expr_stmt.*.match_expr.arms[0];
    try testing.expectEqualStrings("__r2z_match_payload", arm.patterns[1].binding);
    try testing.expectEqualStrings("item", arm.body.block.stmts[0].let_stmt.name);
}

fn checkComparisonDecodeAllocations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const decoded = try serialize.decodeExpr(allocator, value);
    defer freeShapeExpr(allocator, decoded);
    try testing.expect(decoded == .block);
    try testing.expectEqual(@as(usize, 4), decoded.block.stmts.len);
    try testing.expectEqualStrings("Vec", decoded.block.stmts[0].let_stmt.ty.?.generic.name);
}

test "serialize: the new emission shapes decode without leaking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkGuardChainDecodeAllocations,
        .{try serialize.encodeExpr(allocator, .{ .block = guard_chain_block })},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkBranchDecodeAllocations,
        .{try serialize.encodeExpr(allocator, guard_chain_branch)},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkDestructuredDecodeAllocations,
        .{try serialize.encodeExpr(allocator, .{ .block = destructured_chain_block })},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkComparisonDecodeAllocations,
        .{try serialize.encodeExpr(allocator, .{ .block = comparison_temporary_block })},
    );
}

test "serialize: the new emission shapes encode without leaking" {
    const packages = [_]*const ast.Package{
        &guard_chain_package,
        &guard_chain_branch_package,
        &destructured_package,
        &comparison_temporary_package,
    };
    for (packages) |pkg| {
        try testing.checkAllAllocationFailures(
            testing.allocator,
            checkPackageEncodeAllocations,
            .{pkg},
        );
    }
}
