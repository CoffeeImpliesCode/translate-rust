//! translate_rust.backend.zig.emit_test — emitter tests.
//! Verifies `emitFile` produces clean, valid Zig 0.16 syntax for the full
//! range of ast.Decl / ast.Expr / ast.Type / ast.Stmt constructs.

const std = @import("std");
const ast = @import("ast.zig");
const emit = @import("emit.zig");
const serialize = @import("serialize.zig");

fn emitFile(a: std.mem.Allocator, file: ast.File) ![]const u8 {
    return emit.emitFile(a, &file);
}

fn emitExpression(a: std.mem.Allocator, expression: ast.Expr) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    try emit.emitExpr(a, &buf, expression, 0);
    return buf.toOwnedSlice(a);
}

test "emitFile: emits imports, struct with fields and methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const u64_ty = ast.Type{ .prim = .u64 };
    const bool_ty = ast.Type{ .prim = .bool };

    const field_access_self = ast.Expr{ .field_access = .{
        .target = &ast.Expr{ .ident = "self" },
        .field_name = "id",
    } };

    const get_id = ast.Decl{ .fn_decl = .{
        .name = "getId",
        .is_pub = true,
        .params = &.{
            .{ .name = "self", .ty = .{ .ptr = .{ .elem = @constCast(&ast.Type{ .named = "Greeter" }), .is_const = true } } },
        },
        .ret_type = u64_ty,
        .body = .{ .expr = &field_access_self },
    } };

    const greeter = ast.Decl{ .struct_decl = .{
        .name = "Greeter",
        .is_pub = true,
        .fields = &.{
            .{ .name = "id", .ty = u64_ty },
            .{ .name = "active", .ty = bool_ty },
        },
        .decls = &.{get_id},
    } };

    const file = ast.File{
        .path = "src/root.zig",
        .imports = &.{
            .{ .local_name = "std", .module_or_path = "std" },
        },
        .decls = &.{greeter},
    };

    const out = try emitFile(a, file);
    try std.testing.expect(std.mem.startsWith(u8, out, "const std = @import(\"std\");\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const Greeter = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "id: u64,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "active: bool,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn getId(self: *const Greeter) u64 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "return self.id;\n") != null);
}
test "emitFile: emits compact bodies for empty non-extern functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const null_body = ast.Decl{ .fn_decl = .{
        .name = "nullBody",
        .ret_type = .{ .void_type = {} },
    } };
    const empty_body = ast.Decl{ .fn_decl = .{
        .name = "emptyBody",
        .ret_type = .{ .void_type = {} },
        .body = .{ .stmts = &.{}, .expr = null },
    } };
    const file = ast.File{
        .path = "src/empty.zig",
        .decls = &.{ null_body, empty_body },
    };

    const out = try emitFile(a, file);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn nullBody() void {}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn emptyBody() void {}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn nullBody() void;\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn emptyBody() void {\n}\n") == null);
}

test "emitFile: emits enum with tag type and variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const color = ast.Decl{ .enum_decl = .{
        .name = "Color",
        .is_pub = true,
        .tag_type = ast.Type{ .prim = .u8 },
        .variants = &.{
            .{ .name = "red" },
            .{ .name = "green" },
            .{ .name = "blue", .value = &ast.Expr{ .lit = .{ .int = 0x1F } } },
        },
    } };

    const file = ast.File{
        .path = "src/color.zig",
        .decls = &.{color},
    };

    const out = try emitFile(a, file);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const Color = enum(u8) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "red,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "blue = 31,\n") != null);
}

test "emitFile: emits union(enum) with payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const shape = ast.Decl{ .union_decl = .{
        .name = "Shape",
        .is_pub = true,
        .fields = &.{
            .{ .name = "circle", .ty = .{ .prim = .f64 } },
            .{ .name = "rect", .ty = .{ .named = "Rect" } },
        },
    } };

    const file = ast.File{
        .path = "src/shape.zig",
        .decls = &.{shape},
    };

    const out = try emitFile(a, file);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const Shape = union(enum) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "circle: f64,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "rect: Rect,\n") != null);
}

test "emitFile: emits const, var, fn with match/switch and tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const shape_ty = ast.Type{ .named = "Shape" };

    // const LIMIT: u32 = 100;
    const limit = ast.Decl{ .const_decl = .{
        .name = "LIMIT",
        .is_pub = true,
        .ty = ast.Type{ .prim = .u32 },
        .init = .{ .lit = .{ .int = 100 } },
    } };

    // var counter: u32 = 0;
    const counter = ast.Decl{ .var_decl = .{
        .name = "counter",
        .is_pub = false,
        .ty = ast.Type{ .prim = .u32 },
        .init = .{ .lit = .{ .int = 0 } },
    } };

    // fn area(s: Shape) f64 {
    //     return switch (s) {
    //         .circle => |r| r * 3.14,
    //         else => 0.0,
    //     };
    // }
    const r_ident = ast.Expr{ .ident = "r" };
    const pi = ast.Expr{ .lit = .{ .float = 3.14 } };

    const area_fn = ast.Decl{ .fn_decl = .{
        .name = "area",
        .is_pub = true,
        .params = &.{.{ .name = "s", .ty = shape_ty }},
        .ret_type = ast.Type{ .prim = .f64 },
        .body = .{
            .stmts = &.{},
            .expr = &ast.Expr{ .return_expr = &ast.Expr{ .match_expr = .{
                .target = &ast.Expr{ .ident = "s" },
                .arms = &.{
                    .{
                        .patterns = &.{ .{ .enum_literal = "circle" }, .{ .binding = "r" } },
                        .body = ast.Expr{ .bin_op = .{
                            .op = .mul,
                            .lhs = &r_ident,
                            .rhs = &pi,
                        } },
                    },
                    .{
                        .patterns = &.{.{ .wildcard = {} }},
                        .body = ast.Expr{ .lit = .{ .float = 0.0 } },
                    },
                },
            } } },
        },
    } };

    // test "area test" { try std.testing.expectEqual(@as(f64, 0.0), area(.{ .rect = .{} })); }
    const area_test = ast.TestDecl{
        .name = "area test",
        .body = .{
            .stmts = &.{
                .{ .expr_stmt = &ast.Expr{ .call = .{
                    .callee = &ast.Expr{ .field_access = .{
                        .target = &ast.Expr{ .field_access = .{
                            .target = &ast.Expr{ .ident = "std" },
                            .field_name = "testing",
                        } },
                        .field_name = "expect",
                    } },
                    .args = &.{
                        .{ .call = .{
                            .callee = &ast.Expr{ .ident = "area" },
                            .args = &.{.{ .struct_init = .{
                                .type_name = ast.Type{ .named = "Shape" },
                                .fields = &.{.{
                                    .name = "rect",
                                    .expr = .{ .struct_init = .{ .type_name = null, .fields = &.{} } },
                                }},
                            } }},
                        } },
                    },
                } } },
            },
        },
    };

    const file = ast.File{
        .path = "src/area.zig",
        .imports = &.{
            .{ .local_name = "std", .module_or_path = "std" },
            .{ .local_name = "shape", .module_or_path = "./shape.zig", .is_pub = true },
        },
        .decls = &.{ limit, counter, area_fn },
        .tests = &.{area_test},
    };

    const out = try emitFile(a, file);
    try std.testing.expect(std.mem.startsWith(u8, out, "const std = @import(\"std\");\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "const shape = @import(\"./shape.zig\");\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const LIMIT: u32 = 100;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "var counter: u32 = 0;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn area(s: Shape) f64 {") != null);
    // In statement position, an if/switch value tail becomes a `return expr;`.
    try std.testing.expect(std.mem.indexOf(u8, out, "return switch (s) {\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".circle => |r| (r * 3.14)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "else => 0.0,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "test \"area test\" {") != null);
}

test "emitFile: emits generic struct as comptime type fn and plain struct as const" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // pub fn Fletcher(comptime T: type) type { return struct { a: T, b: T }; }
    const generic = ast.Decl{ .struct_decl = .{
        .name = "Fletcher",
        .is_pub = true,
        .generic_params = &.{.{ .name = "T", .is_comptime = true, .ty = null }},
        .fields = &.{
            .{ .name = "a", .ty = .{ .named = "T" } },
            .{ .name = "b", .ty = .{ .named = "T" } },
        },
    } };

    // pub const Point = struct { x: i32, y: i32 };
    const point = ast.Decl{ .struct_decl = .{
        .name = "Point",
        .is_pub = true,
        .fields = &.{
            .{ .name = "x", .ty = .{ .prim = .i32 } },
            .{ .name = "y", .ty = .{ .prim = .i32 } },
        },
    } };

    const file = ast.File{
        .path = "src/root.zig",
        .decls = &.{ generic, point },
    };

    const out = try emitFile(a, file);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn Fletcher(comptime T: type) type {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "return struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a: T,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "b: T,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "};") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const Point = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "x: i32,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "y: i32,") != null);
}

test "emitFile: emits comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = ast.Decl{ .comment = "This is a top-level comment.\nSecond line." };
    const file = ast.File{ .path = "src/c.zig", .decls = &.{doc} };

    const out = try emitFile(a, file);
    try std.testing.expect(std.mem.indexOf(u8, out, "// This is a top-level comment.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "// Second line.\n") != null);
}

test "emitType: unsupported type name is a valid Zig type" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try emit.emitType(std.testing.allocator, &buf, .{ .named = "unsupported type" });
    try std.testing.expectEqualStrings("anyopaque", buf.items);
}

test "emitExpr: destructuring match uses ordinary fresh names and direct captures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const expression: ast.Expr = .{ .match_expr = .{
        .target = &ast.Expr{ .ident = "input" },
        .arms = &.{
            .{
                .patterns = &.{.{ .struct_pat = .{
                    .name = "pair",
                    .fields = &.{
                        .{ .name = "left", .pat = .{ .binding = "left" } },
                        .{ .name = "right", .pat = .{ .binding = "right" } },
                    },
                } }},
                .body = .{ .bin_op = .{
                    .op = .add,
                    .lhs = &ast.Expr{ .ident = "left" },
                    .rhs = &ast.Expr{ .ident = "right" },
                } },
            },
            .{
                .patterns = &.{.{ .struct_pat = .{
                    .name = "one",
                    .fields = &.{.{
                        .name = "0",
                        .pat = .{ .binding = "value" },
                    }},
                } }},
                .body = .{ .ident = "value" },
            },
            .{
                .patterns = &.{.{ .struct_pat = .{
                    .name = "broken",
                    .fields = &.{
                        .{ .name = "left", .pat = .{ .binding = "left" } },
                        .{ .name = "right", .pat = .{ .binding = "right" } },
                    },
                } }},
                .body = .{ .unsupported = "broken arm" },
            },
            .{
                .patterns = &.{.{ .binding = "whole" }},
                .body = .{ .ident = "whole" },
            },
        },
    } };

    const out = try emitExpression(a, expression);
    const expected =
        "switch (input) {\n" ++
        "    .pair => |__r2z_match_payload| __r2z_match_arm: {\n" ++
        "        const left = __r2z_match_payload.left;\n" ++
        "        const right = __r2z_match_payload.right;\n" ++
        "        break :__r2z_match_arm (left + right);\n" ++
        "    },\n" ++
        "    .one => |value| value,\n" ++
        "    .broken => @panic(\"unsupported: broken arm\"),\n" ++
        "    else => |whole| whole,\n" ++
        "}";
    try std.testing.expectEqualStrings(expected, out);
    try std.testing.expect(std.mem.indexOf(u8, out, "@\"match payload\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@\"match arm\"") == null);
}

test "match captures: tagged union payloads survive public roundtrip and emission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const payload_union: ast.Decl = .{ .union_decl = .{
        .name = "Payload",
        .fields = &.{
            .{ .name = "value", .ty = .{ .prim = .u32 } },
            .{ .name = "pointer", .ty = .{ .prim = .u32 } },
            .{ .name = "pair", .ty = .{ .anon_struct = .{ .fields = &.{
                .{ .name = "left", .ty = .{ .prim = .u32 } },
                .{ .name = "right", .ty = .{ .prim = .u32 } },
            } } } },
        },
    } };
    const payload_match: ast.Expr = .{ .match_expr = .{
        .target = &ast.Expr{ .ident = "input" },
        .arms = &.{
            .{
                .patterns = &.{.{ .enum_literal = "value" }},
                .capture = .{ .name = "__r2z_match_payload" },
                .body = .{ .ident = "__r2z_match_payload" },
            },
            .{
                .patterns = &.{.{ .enum_literal = "pointer" }},
                .capture = .{ .name = "pointer_payload", .by_ref = true },
                .body = .{ .unary_op = .{
                    .op = .deref,
                    .operand = &ast.Expr{ .ident = "pointer_payload" },
                } },
            },
            .{
                .patterns = &.{.{ .struct_pat = .{
                    .name = "pair",
                    .fields = &.{
                        .{ .name = "left", .pat = .{ .binding = "left" } },
                        .{ .name = "right", .pat = .{ .binding = "right" } },
                    },
                } }},
                .body = .{ .bin_op = .{
                    .op = .add,
                    .lhs = &ast.Expr{ .ident = "left" },
                    .rhs = &ast.Expr{ .ident = "right" },
                } },
            },
        },
    } };
    const read_payload: ast.Decl = .{ .fn_decl = .{
        .name = "readPayload",
        .params = &.{.{ .name = "input", .ty = .{ .named = "Payload" } }},
        .ret_type = .{ .prim = .u32 },
        .body = .{ .expr = &payload_match },
    } };
    const file: ast.File = .{
        .path = "src/root.zig",
        .decls = &.{ payload_union, read_payload },
    };
    const package: ast.Package = .{
        .name = "match_capture",
        .fingerprint = 0xCA97_0001,
        .files = &.{file},
    };

    try ast.validateForTranslation(&package);
    const encoded = try serialize.encode(allocator, &package);
    const decoded = try serialize.decode(allocator, encoded);
    const decoded_match = decoded.files[0].decls[1].fn_decl.body.?.expr.?.match_expr;
    const value_capture = decoded_match.arms[0].capture.?;
    try std.testing.expectEqualStrings("__r2z_match_payload", value_capture.name);
    try std.testing.expect(!value_capture.by_ref);
    const pointer_capture = decoded_match.arms[1].capture.?;
    try std.testing.expectEqualStrings("pointer_payload", pointer_capture.name);
    try std.testing.expect(pointer_capture.by_ref);
    try std.testing.expect(decoded_match.arms[2].capture == null);

    const source = try emit.emitFile(allocator, &decoded.files[0]);
    try std.testing.expectEqualStrings(
        \\pub const Payload = union(enum) {
        \\    value: u32,
        \\    pointer: u32,
        \\    pair: struct { left: u32, right: u32 },
        \\};
        \\
        \\pub fn readPayload(input: Payload) u32 {
        \\    return switch (input) {
        \\        .value => |__r2z_match_payload| __r2z_match_payload,
        \\        .pointer => |*pointer_payload| pointer_payload.*,
        \\        .pair => |__r2z_match_payload_1| __r2z_match_arm: {
        \\            const left = __r2z_match_payload_1.left;
        \\            const right = __r2z_match_payload_1.right;
        \\            break :__r2z_match_arm (left + right);
        \\        },
        \\    };
        \\}
    ,
        source,
    );
}

test "emitExpr: match fresh names skip source identifiers bindings and labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const expression: ast.Expr = .{ .match_expr = .{
        .target = &ast.Expr{ .ident = "__r2z_match_payload" },
        .arms = &.{.{
            .patterns = &.{.{ .struct_pat = .{
                .name = "pair",
                .fields = &.{
                    .{
                        .name = "left",
                        .pat = .{ .binding = "__r2z_match_arm" },
                    },
                    .{
                        .name = "right",
                        .pat = .{ .binding = "__r2z_match_arm_1" },
                    },
                },
            } }},
            .body = .{ .block = .{
                .label = "__r2z_match_arm",
                .expr = &ast.Expr{ .block = .{
                    .label = "__r2z_match_arm_1",
                    .expr = &ast.Expr{ .bin_op = .{
                        .op = .add,
                        .lhs = &ast.Expr{ .ident = "__r2z_match_payload" },
                        .rhs = &ast.Expr{ .ident = "__r2z_match_payload_1" },
                    } },
                } },
            } },
        }},
    } };

    const out = try emitExpression(a, expression);
    const expected =
        "switch (__r2z_match_payload) {\n" ++
        "    .pair => |__r2z_match_payload_2| __r2z_match_arm_2: {\n" ++
        "        const __r2z_match_arm = __r2z_match_payload_2.left;\n" ++
        "        const __r2z_match_arm_1 = __r2z_match_payload_2.right;\n" ++
        "        break :__r2z_match_arm_2 __r2z_match_arm: {\n" ++
        "            break :__r2z_match_arm __r2z_match_arm_1: {\n" ++
        "                break :__r2z_match_arm_1 " ++
        "(__r2z_match_payload + __r2z_match_payload_1);\n" ++
        "            };\n" ++
        "        };\n" ++
        "    },\n" ++
        "}";
    try std.testing.expectEqualStrings(expected, out);
}

test "emitExpr: nested repeated destructuring names follow source order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const expression: ast.Expr = .{ .match_expr = .{
        .target = &ast.Expr{ .ident = "outer" },
        .arms = &.{.{
            .patterns = &.{.{ .struct_pat = .{
                .name = "outer",
                .fields = &.{
                    .{ .name = "nested", .pat = .{ .binding = "nested" } },
                    .{ .name = "fallback", .pat = .{ .binding = "fallback" } },
                },
            } }},
            .body = .{ .match_expr = .{
                .target = &ast.Expr{ .ident = "nested" },
                .arms = &.{
                    .{
                        .patterns = &.{.{ .struct_pat = .{
                            .name = "first",
                            .fields = &.{
                                .{ .name = "a", .pat = .{ .binding = "a" } },
                                .{ .name = "b", .pat = .{ .binding = "b" } },
                            },
                        } }},
                        .body = .{ .bin_op = .{
                            .op = .add,
                            .lhs = &ast.Expr{ .ident = "a" },
                            .rhs = &ast.Expr{ .ident = "b" },
                        } },
                    },
                    .{
                        .patterns = &.{.{ .struct_pat = .{
                            .name = "second",
                            .fields = &.{
                                .{ .name = "c", .pat = .{ .binding = "c" } },
                                .{ .name = "d", .pat = .{ .binding = "d" } },
                            },
                        } }},
                        .body = .{ .bin_op = .{
                            .op = .add,
                            .lhs = &ast.Expr{ .ident = "c" },
                            .rhs = &ast.Expr{ .ident = "d" },
                        } },
                    },
                },
            } },
        }},
    } };

    const first = try emitExpression(a, expression);
    const second = try emitExpression(a, expression);
    try std.testing.expectEqualStrings(first, second);

    const expected =
        "switch (outer) {\n" ++
        "    .outer => |__r2z_match_payload| __r2z_match_arm: {\n" ++
        "        const nested = __r2z_match_payload.nested;\n" ++
        "        const fallback = __r2z_match_payload.fallback;\n" ++
        "        break :__r2z_match_arm switch (nested) {\n" ++
        "            .first => |__r2z_match_payload_1| __r2z_match_arm_1: {\n" ++
        "                const a = __r2z_match_payload_1.a;\n" ++
        "                const b = __r2z_match_payload_1.b;\n" ++
        "                break :__r2z_match_arm_1 (a + b);\n" ++
        "            },\n" ++
        "            .second => |__r2z_match_payload_2| __r2z_match_arm_2: {\n" ++
        "                const c = __r2z_match_payload_2.c;\n" ++
        "                const d = __r2z_match_payload_2.d;\n" ++
        "                break :__r2z_match_arm_2 (c + d);\n" ++
        "            },\n" ++
        "        };\n" ++
        "    },\n" ++
        "}";
    try std.testing.expectEqualStrings(expected, first);
}

test "emitExpr: Rust unit uses an explicit void value" {
    const unit: ast.Expr = .{ .unit = {} };
    const emitted = try emitExpression(std.testing.allocator, unit);
    defer std.testing.allocator.free(emitted);
    try std.testing.expectEqualStrings("@as(void, {})", emitted);
}

test "expression-sized arrays survive public roundtrip and emission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const length_call: ast.Expr = .{ .call = .{
        .callee = &ast.Expr{ .ident = "arrayLen" },
        .args = &.{.{ .lit = .{ .int = 4 } }},
    } };
    const array_type: ast.Type = .{ .array_expr = .{
        .elem = &ast.Type{ .prim = .u8 },
        .len = &length_call,
    } };
    const package: ast.Package = .{
        .name = "expression_array",
        .files = &.{.{
            .path = "src/root.zig",
            .decls = &.{
                .{ .fn_decl = .{
                    .name = "arrayLen",
                    .params = &.{.{
                        .name = "length",
                        .ty = .{ .prim = .usize },
                        .is_comptime = true,
                    }},
                    .ret_type = .{ .prim = .usize },
                    .body = .{ .expr = &ast.Expr{ .ident = "length" } },
                } },
                .{ .fn_decl = .{
                    .name = "identityArray",
                    .params = &.{.{ .name = "input", .ty = array_type }},
                    .ret_type = array_type,
                    .body = .{ .expr = &ast.Expr{ .ident = "input" } },
                } },
            },
        }},
    };

    try ast.validateForTranslation(&package);
    const encoded = try serialize.encode(allocator, &package);
    const decoded = try serialize.decode(allocator, encoded);
    const decoded_type = decoded.files[0].decls[1].fn_decl.params[0].ty;
    try std.testing.expect(decoded_type == .array_expr);
    try std.testing.expect(decoded_type.array_expr.elem.* == .prim);
    try std.testing.expect(decoded_type.array_expr.len.* == .call);
    try std.testing.expectEqualStrings(
        "arrayLen",
        decoded_type.array_expr.len.call.callee.ident,
    );

    const source = try emit.emitFile(allocator, &decoded.files[0]);
    try std.testing.expectEqualStrings(
        \\pub fn arrayLen(comptime length: usize) usize {
        \\    return length;
        \\}
        \\
        \\pub fn identityArray(input: [arrayLen(4)]u8) [arrayLen(4)]u8 {
        \\    return input;
        \\}
    ,
        source,
    );
}

test "emitExpr: repeated array uses the whole type's element" {
    const expression: ast.Expr = .{ .repeat = .{
        .type_name = .{ .array = .{
            .elem = &ast.Type{ .prim = .u32 },
            .len = 4,
        } },
        .elem = &ast.Expr{ .lit = .{ .int = 0 } },
        .len = 4,
    } };

    const emitted = try emitExpression(std.testing.allocator, expression);
    defer std.testing.allocator.free(emitted);
    try std.testing.expectEqualStrings("[_]u32{ 0 } ** 4", emitted);
}

test "emitExpr: for captures emit pointer bindings" {
    const expression: ast.Expr = .{ .for_expr = .{
        .inputs = &.{.{ .ident = "items" }},
        .captures = &.{.{ .name = "item", .by_ref = true }},
        .body = .{
            .stmts = &.{},
            .expr = &ast.Expr{ .ident = "item" },
        },
    } };

    const emitted = try emitExpression(std.testing.allocator, expression);
    defer std.testing.allocator.free(emitted);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "for (items) |*item|") != null);
}
