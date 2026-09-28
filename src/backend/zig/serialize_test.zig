//! translate_rust.backend.zig.serialize_test — JSON roundtrip tests
//! for ast.Package serialization.

const std = @import("std");
const testing = std.testing;
const ast = @import("ast.zig");
const serialize = @import("serialize.zig");

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

    // Basic sanity of JSON output.
    try testing.expect(std.mem.indexOf(u8, json_bytes, "demo_pkg") != null);
    try testing.expect(std.mem.indexOf(u8, json_bytes, "Rectangle") != null);

    // Roundtrip.
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
    try testing.expect(std.mem.indexOf(u8, json_bytes, "\"kind\": \"defer_stmt\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_bytes, "\"is_errdefer\": false") != null);
    try testing.expect(std.mem.indexOf(u8, json_bytes, "\"is_errdefer\": true") != null);

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
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
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
