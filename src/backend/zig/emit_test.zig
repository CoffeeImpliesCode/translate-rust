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

fn ident(name: []const u8) ast.Expr {
    return .{ .ident = name };
}

/// `BinOp` stores its operands behind pointers, so a nested binary expression
/// needs a stable home. The test arena gives every operand one for free.
fn binary(a: std.mem.Allocator, op: ast.BinOpKind, lhs: ast.Expr, rhs: ast.Expr) !ast.Expr {
    const lhs_slot = try a.create(ast.Expr);
    lhs_slot.* = lhs;
    const rhs_slot = try a.create(ast.Expr);
    rhs_slot.* = rhs;
    return .{ .bin_op = .{ .op = op, .lhs = lhs_slot, .rhs = rhs_slot } };
}

/// Copies `expr` into the arena and hands back the stable slot that a node
/// holding operands behind pointers needs.
fn boxed(a: std.mem.Allocator, expr: ast.Expr) !*ast.Expr {
    const slot = try a.create(ast.Expr);
    slot.* = expr;
    return slot;
}

fn unary(a: std.mem.Allocator, op: ast.UnaryOpKind, operand: ast.Expr) !ast.Expr {
    return .{ .unary_op = .{ .op = op, .operand = try boxed(a, operand) } };
}

/// Copies `exprs` into the arena and hands back the stable slice that a node
/// holding its children inline needs; a `&.{ ... }` literal built from runtime
/// values would point at a temporary that dies with the statement.
fn list(a: std.mem.Allocator, exprs: []const ast.Expr) ![]const ast.Expr {
    const slot = try a.alloc(ast.Expr, exprs.len);
    @memcpy(slot, exprs);
    return slot;
}

/// `list` for a match's arm slice, which holds nodes rather than expressions.
fn listArms(a: std.mem.Allocator, arms: []const ast.MatchArm) ![]const ast.MatchArm {
    const slot = try a.alloc(ast.MatchArm, arms.len);
    @memcpy(slot, arms);
    return slot;
}

fn listCaptures(a: std.mem.Allocator, items: []const ast.Capture) ![]const ast.Capture {
    const slot = try a.alloc(ast.Capture, items.len);
    @memcpy(slot, items);
    return slot;
}

fn listStmts(a: std.mem.Allocator, items: []const ast.Stmt) ![]const ast.Stmt {
    const slot = try a.alloc(ast.Stmt, items.len);
    @memcpy(slot, items);
    return slot;
}

/// One row of a table-driven emission test: an expression and the exact Zig
/// text it has to produce.
const EmittedRow = struct { expression: ast.Expr, expected: []const u8 };

fn expectEmittedRows(a: std.mem.Allocator, rows: []const EmittedRow) !void {
    for (rows) |row| {
        const out = try emitExpression(a, row.expression);
        try std.testing.expectEqualStrings(row.expected, out);
    }
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

test "emitFile: a function body must survive lowering, and the smallest real one emits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A vanished body is a translation loss, not an empty Zig function:
    // `pub fn f() void {}` compiles and silently does nothing, so the
    // emitter must never synthesise one. `emitFile` validates first, so
    // both shapes fail before a byte of source is written.
    const no_body = ast.File{
        .path = "src/empty.zig",
        .decls = &.{.{ .fn_decl = .{
            .name = "nullBody",
            .ret_type = .{ .void_type = {} },
        } }},
    };
    try std.testing.expectError(error.EmptyTranslatedFunction, emitFile(a, no_body));

    const empty_body = ast.File{
        .path = "src/empty.zig",
        .decls = &.{.{ .fn_decl = .{
            .name = "emptyBody",
            .ret_type = .{ .void_type = {} },
            .body = .{ .stmts = &.{}, .expr = null },
        } }},
    };
    try std.testing.expectError(error.EmptyTranslatedBody, emitFile(a, empty_body));

    // The boundary: a single statement is the smallest body that still
    // carries a translated result, and it emits as a real body.
    const one_stmt = ast.File{
        .path = "src/empty.zig",
        .decls = &.{.{ .fn_decl = .{
            .name = "setup",
            .ret_type = .{ .void_type = {} },
            .body = .{ .stmts = &.{.{ .let_stmt = .{
                .name = "tag",
                .ty = .{ .prim = .u8 },
                .init = .{ .lit = .{ .int = 7 } },
            } }} },
        } }},
    };
    try std.testing.expectEqualStrings(
        \\pub fn setup() void {
        \\    const tag: u8 = 7;
        \\}
        \\
    ,
        try emitFile(a, one_stmt),
    );
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
    try std.testing.expect(std.mem.indexOf(u8, out, ".circle => |r| r * 3.14") != null);
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
        "        break :__r2z_match_arm left + right;\n" ++
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
        \\            break :__r2z_match_arm left + right;
        \\        },
        \\    };
        \\}
        \\
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
        "__r2z_match_payload + __r2z_match_payload_1;\n" ++
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
        "                break :__r2z_match_arm_1 a + b;\n" ++
        "            },\n" ++
        "            .second => |__r2z_match_payload_2| __r2z_match_arm_2: {\n" ++
        "                const c = __r2z_match_payload_2.c;\n" ++
        "                const d = __r2z_match_payload_2.d;\n" ++
        "                break :__r2z_match_arm_2 c + d;\n" ++
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
        .fingerprint = 0xA11E_0001,
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
        \\
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

fn emitPatternText(a: std.mem.Allocator, pat: ast.Pattern) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    try emit.emitPattern(a, &buf, pat);
    return buf.toOwnedSlice(a);
}

test "emitPattern: inclusive range uses three dots" {
    const emitted = try emitPatternText(std.testing.allocator, .{ .range_pat = .{
        .lo = .{ .char_lit = 'A' },
        .hi = .{ .char_lit = 'F' },
        .inclusive = true,
    } });
    defer std.testing.allocator.free(emitted);
    try std.testing.expectEqualStrings("'A'...'F'", emitted);
}

test "emitPattern: exclusive range shifts the upper bound down by one" {
    const emitted = try emitPatternText(std.testing.allocator, .{ .range_pat = .{
        .lo = .{ .char_lit = 'A' },
        .hi = .{ .char_lit = 'F' },
        .inclusive = false,
    } });
    defer std.testing.allocator.free(emitted);
    try std.testing.expectEqualStrings("'A'...('F' - 1)", emitted);
}

test "emitPattern: exclusive integer range shifts the upper bound down by one" {
    const emitted = try emitPatternText(std.testing.allocator, .{ .range_pat = .{
        .lo = .{ .int = 0 },
        .hi = .{ .int = 9 },
        .inclusive = false,
    } });
    defer std.testing.allocator.free(emitted);
    try std.testing.expectEqualStrings("0...(9 - 1)", emitted);
}

test "emitPattern: a missing lower bound degrades to the wildcard" {
    const emitted = try emitPatternText(std.testing.allocator, .{ .range_pat = .{
        .lo = null,
        .hi = .{ .char_lit = 'F' },
        .inclusive = true,
    } });
    defer std.testing.allocator.free(emitted);
    try std.testing.expectEqualStrings("_", emitted);
}

test "emitPattern: a missing upper bound degrades to the wildcard" {
    const emitted = try emitPatternText(std.testing.allocator, .{ .range_pat = .{
        .lo = .{ .char_lit = 'A' },
        .hi = null,
        .inclusive = true,
    } });
    defer std.testing.allocator.free(emitted);
    try std.testing.expectEqualStrings("_", emitted);
}

test "emitPattern: a boundless range is a catch-all wildcard" {
    const emitted = try emitPatternText(std.testing.allocator, .{ .range_pat = .{
        .lo = null,
        .hi = null,
        .inclusive = true,
    } });
    defer std.testing.allocator.free(emitted);
    try std.testing.expectEqualStrings("_", emitted);
}

test "emitExpr: a bin_op emits bare and only re-wraps where precedence needs it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Equal precedence. The right operand keeps its group because the operator
    // is left-associative: `a - (b - c)` is not `a - b - c`. The left operand
    // already is the outer group, so it needs nothing.
    const right_same = try binary(a, .sub, ident("a"), try binary(a, .sub, ident("b"), ident("c")));
    const left_same = try binary(a, .sub, try binary(a, .sub, ident("a"), ident("b")), ident("c"));

    // A tighter child binds on its own in either slot.
    const tighter_right = try binary(a, .sub, ident("a"), try binary(a, .mul, ident("b"), ident("c")));
    const tighter_left = try binary(a, .add, try binary(a, .mul, ident("a"), ident("b")), ident("c"));

    // A looser child would be dragged into the parent group, so it keeps its
    // own parentheses in either slot.
    const looser_right = try binary(a, .mul, ident("a"), try binary(a, .add, ident("b"), ident("c")));
    const looser_left = try binary(a, .mul, try binary(a, .add, ident("a"), ident("b")), ident("c"));

    // Boolean groups, loosest first: `or` then `and`.
    const and_of_or_right = try binary(a, .bool_and, ident("p"), try binary(a, .bool_or, ident("q"), ident("r")));
    const and_of_or_left = try binary(a, .bool_and, try binary(a, .bool_or, ident("p"), ident("q")), ident("r"));
    const or_of_and_right = try binary(a, .bool_or, ident("p"), try binary(a, .bool_and, ident("q"), ident("r")));
    const or_of_and_left = try binary(a, .bool_or, try binary(a, .bool_and, ident("p"), ident("q")), ident("r"));

    // A comparison sits below the bitwise operators, so `a | b == c` already
    // means `(a | b) == c` and must not grow parentheses.
    const eq_of_or_right = try binary(a, .equal, ident("a"), try binary(a, .bit_or, ident("b"), ident("c")));
    const eq_of_or_left = try binary(a, .equal, try binary(a, .bit_or, ident("a"), ident("b")), ident("c"));

    // A shift sits below `+`, so `(a << b) + c` keeps its group.
    const add_of_shl_left = try binary(a, .add, try binary(a, .shl, ident("a"), ident("b")), ident("c"));
    const shl_of_add_right = try binary(a, .shl, ident("a"), try binary(a, .add, ident("b"), ident("c")));

    // The wrapping variants share a group with their plain operator.
    const add_wrap_of_mul_wrap = try binary(
        a,
        .add_wrap,
        ident("a"),
        try binary(a, .mul_wrap, ident("b"), ident("c")),
    );
    const sub_wrap_of_sub_wrap = try binary(
        a,
        .sub_wrap,
        ident("a"),
        try binary(a, .sub_wrap, ident("b"), ident("c")),
    );

    try expectEmittedRows(a, &.{
        .{ .expression = right_same, .expected = "a - (b - c)" },
        .{ .expression = left_same, .expected = "a - b - c" },
        .{ .expression = tighter_right, .expected = "a - b * c" },
        .{ .expression = tighter_left, .expected = "a * b + c" },
        .{ .expression = looser_right, .expected = "a * (b + c)" },
        .{ .expression = looser_left, .expected = "(a + b) * c" },
        .{ .expression = and_of_or_right, .expected = "p and (q or r)" },
        .{ .expression = and_of_or_left, .expected = "(p or q) and r" },
        .{ .expression = or_of_and_right, .expected = "p or q and r" },
        .{ .expression = or_of_and_left, .expected = "p and q or r" },
        .{ .expression = eq_of_or_right, .expected = "a == b | c" },
        .{ .expression = eq_of_or_left, .expected = "a | b == c" },
        .{ .expression = add_of_shl_left, .expected = "(a << b) + c" },
        .{ .expression = shl_of_add_right, .expected = "a << b + c" },
        .{ .expression = add_wrap_of_mul_wrap, .expected = "a +% b *% c" },
        .{ .expression = sub_wrap_of_sub_wrap, .expected = "a -% (b -% c)" },
    });
}

test "emitExpr: a bin_op keeps its group in a prefix operand, argument and cast" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Every prefix operator binds tighter than every binary operator, so each
    // one has to wrap its operand. `&a + b` would take the address of `a`.
    const negate = try unary(a, .negate, try binary(a, .add, ident("a"), ident("b")));
    const bit_not = try unary(a, .bit_not, try binary(a, .mul, ident("a"), ident("b")));
    const bool_not = try unary(a, .bool_not, try binary(a, .bool_and, ident("a"), ident("b")));
    const addr_of = try unary(a, .addr_of, try binary(a, .add, ident("a"), ident("b")));
    const try_op = try unary(a, .try_op, try binary(a, .bit_or, ident("a"), ident("b")));

    // `.*` binds tighter too, and a nested prefix operand loses its group
    // without a wrap: `&x.*` reads as `&(x.*)`, not `(&x).*`.
    const deref_of_bin = try unary(a, .deref, try binary(a, .add, ident("a"), ident("b")));
    const deref_of_unary = try unary(a, .deref, try unary(a, .addr_of, ident("x")));

    // An already atomic operand stays bare.
    const negate_ident = try unary(a, .negate, ident("a"));
    const addr_of_ident = try unary(a, .addr_of, ident("a"));

    // An argument list and a cast operand are already delimited, so a binary
    // child needs nothing there.
    const callee = ident("len");
    const call_arg: ast.Expr = .{ .call = .{
        .callee = &callee,
        .args = &.{try binary(a, .add, ident("a"), ident("b"))},
    } };
    const cast: ast.Expr = .{ .cast = .{
        .target = .{ .prim = .u64 },
        .operand = try boxed(a, try binary(a, .add, ident("a"), ident("b"))),
    } };

    try expectEmittedRows(a, &.{
        .{ .expression = negate, .expected = "-(a + b)" },
        .{ .expression = bit_not, .expected = "~(a * b)" },
        .{ .expression = bool_not, .expected = "!(a and b)" },
        .{ .expression = addr_of, .expected = "&(a + b)" },
        .{ .expression = try_op, .expected = "try (a | b)" },
        .{ .expression = deref_of_bin, .expected = "(a + b).*" },
        .{ .expression = deref_of_unary, .expected = "(&x).*" },
        .{ .expression = negate_ident, .expected = "-a" },
        .{ .expression = addr_of_ident, .expected = "&a" },
        .{ .expression = call_arg, .expected = "len(a + b)" },
        .{ .expression = cast, .expected = "@as(u64, a + b)" },
    });
}

test "emitExpr: a bin_op stays bare in delimited slots and stays wrapped in receivers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const returned: ast.Expr = .{
        .return_expr = try boxed(a, try binary(a, .add, ident("a"), ident("b"))),
    };
    const broken: ast.Expr = .{
        .break_expr = try boxed(a, try binary(a, .add, ident("a"), ident("b"))),
    };

    // A switch subject sits inside the `switch (...)` delimiters, and a prong
    // body is a whole expression, so a binary child needs nothing in either.
    const matched: ast.Expr = .{ .match_expr = .{
        .target = try boxed(a, try binary(a, .add, ident("a"), ident("b"))),
        .arms = try listArms(a, &.{.{ .patterns = &.{.{ .binding = "x" }}, .body = ident("x") }}),
    } };
    const prong: ast.Expr = .{ .match_expr = .{
        .target = try boxed(a, try binary(a, .add, ident("a"), ident("b"))),
        .arms = try listArms(a, &.{
            .{ .patterns = &.{.{ .binding = "x" }}, .body = try binary(a, .sub, ident("x"), ident("y")) },
        }),
    } };

    // Both `if` slots hold a whole expression.
    const conditional: ast.Expr = .{ .if_expr = .{
        .cond = try boxed(a, try binary(a, .bool_and, ident("p"), ident("q"))),
        .then_body = try boxed(a, try binary(a, .add, ident("a"), ident("b"))),
        .else_body = try boxed(a, try binary(a, .sub, ident("a"), ident("b"))),
    } };

    // A receiver, by contrast, has to stay atomic: `a + b.len` reads the field
    // of `b` instead of the sum.
    const field_receiver: ast.Expr = .{ .field_access = .{
        .target = try boxed(a, try binary(a, .add, ident("a"), ident("b"))),
        .field_name = "len",
    } };
    const index_receiver: ast.Expr = .{ .builtin = .{
        .name = "index",
        .args = try list(a, &.{
            try binary(a, .add, ident("a"), ident("b")),
            ident("i"),
        }),
    } };

    // A range start has to be one primary expression, while a range end may
    // be a full expression because `..` binds looser than `+`.
    const ranged: ast.Expr = .{ .range = .{
        .start = try boxed(a, try binary(a, .add, ident("a"), ident("b"))),
        .end = try boxed(a, try binary(a, .add, ident("b"), ident("c"))),
    } };

    // The chunk loop reads `.len` off its target and indexes it, so the same
    // receiver rule applies to a lowered `for` loop.
    const chunk_loop: ast.Expr = .{ .for_expr = .{
        .inputs = try list(a, &.{.{ .builtin = .{
            .name = "sliceChunks",
            .args = try list(a, &.{
                try binary(a, .add, ident("a"), ident("b")),
                ident("n"),
            }),
        } }}),
        .captures = try listCaptures(a, &.{.{ .name = "chunk" }}),
        .body = .{ .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, ident("use")) }}), .expr = null },
    } };

    try expectEmittedRows(a, &.{
        .{ .expression = returned, .expected = "return a + b" },
        .{ .expression = broken, .expected = "break a + b" },
        .{ .expression = matched, .expected = "switch (a + b) {\n    else => |x| x,\n}" },
        .{ .expression = prong, .expected = "switch (a + b) {\n    else => |x| x - y,\n}" },
        .{ .expression = conditional, .expected = "if (p and q) a + b else a - b" },
        .{ .expression = field_receiver, .expected = "(a + b).len" },
        .{ .expression = index_receiver, .expected = "(a + b)[i]" },
        .{ .expression = ranged, .expected = "(a + b)..b + c" },
    });
    try std.testing.expect(std.mem.indexOf(u8, try emitExpression(a, chunk_loop),
        "while ((a + b).len > __chunk_index)") != null);
    try std.testing.expect(std.mem.indexOf(u8, try emitExpression(a, chunk_loop),
        "const chunk = (a + b)[__chunk_index..@min(__chunk_index + n, (a + b).len)];") != null);
}

test "emitExpr: the wyhash read chain and wymum product need one group, not seven" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `u64::from(data[i]) << N`, one link of the read64 / read_rest chain.
    const byte_shift = struct {
        fn build(alloc: std.mem.Allocator, byte: i64, shift: i64) !ast.Expr {
            const from = try boxed(alloc, .{ .cast = .{
                .target = .{ .prim = .u64 },
                .operand = try boxed(alloc, .{ .builtin = .{
                    .name = "index",
                    .args = try list(alloc, &.{ ident("data"), .{ .lit = .{ .int = byte } } }),
                } }),
            } });
            return binary(alloc, .shl, from.*, (try boxed(alloc, .{ .builtin = .{
                .name = "intCast",
                .args = try list(alloc, &.{.{ .lit = .{ .int = shift } }}),
            } })).*);
        }
    }.build;

    // `read64` is eight `|` links, each holding a `<<`, nested to the left.
    // `|` is left-associative and `<<` binds tighter, so the whole chain is
    // one flat alternation with no parentheses of its own.
    var chain = try byte_shift(a, 7, 56);
    var byte: i64 = 6;
    while (true) {
        chain = try binary(a, .bit_or, chain, try byte_shift(a, byte, byte * 8));
        if (byte == 0) break;
        byte -= 1;
    }
    try expectEmittedRows(a, &.{.{ .expression = chain, .expected =
    \\@as(u64, data[7]) << @intCast(56) | @as(u64, data[6]) << @intCast(48) | @as(u64, data[5]) << @intCast(40) | @as(u64, data[4]) << @intCast(32) | @as(u64, data[3]) << @intCast(24) | @as(u64, data[2]) << @intCast(16) | @as(u64, data[1]) << @intCast(8) | @as(u64, data[0]) << @intCast(0)
    }});

    // A chain nested to the right is the one that must keep its group:
    // `a | b | c | d` parses as `((a | b) | c) | d`, so a right-nested source
    // shape is not the same expression.
    const nested_left = try binary(
        a,
        .bit_or,
        try binary(a, .bit_or, ident("a"), ident("b")),
        ident("c"),
    );
    const nested_right = try binary(
        a,
        .bit_or,
        try binary(a, .bit_or, ident("a"), ident("b")),
        try binary(a, .bit_or, ident("c"), ident("d")),
    );
    try expectEmittedRows(a, &.{
        .{ .expression = nested_left, .expected = "a | b | c" },
        .{ .expression = nested_right, .expected = "a | b | (c | d)" },
    });

    // `wymum`: the product is one multiplication, so the cast operands need
    // no group of their own.
    const product = try binary(
        a,
        .mul_wrap,
        .{ .cast = .{
            .target = .{ .prim = .u128 },
            .operand = try boxed(a, ident("a")),
        } },
        .{ .cast = .{
            .target = .{ .prim = .u128 },
            .operand = try boxed(a, ident("b")),
        } },
    );
    try expectEmittedRows(a, &.{
        .{ .expression = product, .expected = "@as(u128, a) *% @as(u128, b)" },
    });

    // `wymum`'s tail, `((r >> 64) ^ r) as u64`: the shift binds tighter than
    // the exclusive or, so the whole tail needs no group of its own.
    const tail = try binary(
        a,
        .bit_xor,
        (try boxed(a, try binary(a, .shr, ident("r"), .{ .builtin = .{
            .name = "intCast",
            .args = try list(a, &.{.{ .lit = .{ .int = 64 } }}),
        } }))).*,
        ident("r"),
    );
    try expectEmittedRows(a, &.{
        .{ .expression = tail, .expected = "r >> @intCast(64) ^ r" },
    });
}