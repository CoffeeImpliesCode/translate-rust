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

test "emitFile: missing and empty function bodies are rejected" {
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

test "emitFile: places documentation on files, imports, declarations, and fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const file = ast.File{
        .path = "src/doc.zig",
        .documentation = "Encoding helpers.\nSecond line.",
        .imports = &.{.{
            .local_name = "std",
            .module_or_path = "std",
            .documentation = "Only the io and fmt modules are used.",
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
                .documentation = "Lifecycle states.",
                .variants = &.{
                    .{ .name = "Idle", .documentation = "Not started." },
                    .{ .name = "Done" },
                },
            } },
            .{ .union_decl = .{
                .name = "Payload",
                .fields = &.{.{
                    .name = "count",
                    .ty = .{ .prim = .u32 },
                    .documentation = "How many.",
                }},
            } },
            .{ .const_decl = .{
                .name = "LIMIT",
                .ty = .{ .prim = .u32 },
                .init = .{ .lit = .{ .int = 7 } },
                .documentation = "Never exceeded.",
            } },
        },
    };

    const out = try emitFile(a, file);

    // File documentation is `//!` and leads the file. Import, declaration,
    // field and tag documentation is `///` at the indentation of the thing
    // it documents, immediately above it.
    try std.testing.expect(std.mem.startsWith(
        u8,
        out,
        "//! Encoding helpers.\n//! Second line.\n\n",
    ));
    try std.testing.expect(std.mem.indexOf(
        u8,
        out,
        "/// Only the io and fmt modules are used.\nconst std = @import(\"std\");\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out,
        "/// Running totals.\npub const Counters = struct {\n" ++
            "    /// Bytes seen so far.\n    total: u64,\n    runs: u32,\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out,
        "/// Lifecycle states.\npub const State = enum {\n" ++
            "    /// Not started.\n    Idle,\n    Done,\n};\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out,
        "pub const Payload = union(enum) {\n    /// How many.\n    count: u32,\n};\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out,
        "/// Never exceeded.\npub const LIMIT: u32 = 7;\n",
    ) != null);
    // A declaration with no authored documentation emits no marker at all, so
    // nothing is left dangling after the last declaration.
    try std.testing.expect(std.mem.indexOf(u8, out, "///\n") == null);
}

test "emitFile: a blank line inside documentation becomes a bare marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const file = ast.File{
        .path = "src/doc.zig",
        .documentation = "First paragraph.\n\nSecond paragraph.",
        .decls = &.{.{ .const_decl = .{
            .name = "VALUE",
            .ty = .{ .prim = .u8 },
            .init = .{ .lit = .{ .int = 0 } },
        } }},
    };

    const out = try emitFile(a, file);
    try std.testing.expectEqualStrings(
        \\//! First paragraph.
        \\//!
        \\//! Second paragraph.
        \\
        \\pub const VALUE: u8 = 0;
        \\
    , out);
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

// `RustHashLayout.tuple` is `[]const type`, so the generic Hash walk has to
// bind each child descriptor at comptime to satisfy its own `comptime C: type`
// parameter. Zig unrolls that only under `inline for`; a plain `for` binds the
// capture at runtime, where it names nothing. The second loop omits the flag
// entirely, which is every source `for`, and pins that its bytes do not move.
test "emitExpr: a comptime loop is spelled inline and a runtime one is not" {
    // The shape the Hash walk actually builds: a two-input loop whose captures
    // are the field and the slot, both bound at comptime. The flag has to
    // survive the multi-input form, not just the simplest one.
    const comptime_loop: ast.Expr = .{ .for_expr = .{
        .inputs = &.{ .{ .ident = "Fields" }, .{ .ident = "Slots" } },
        .captures = &.{ .{ .name = "Field" }, .{ .name = "Slot" } },
        .body = .{ .stmts = &.{} },
        .is_inline = true,
    } };
    const runtime_loop: ast.Expr = .{ .for_expr = .{
        .inputs = &.{.{ .ident = "items" }},
        .captures = &.{.{ .name = "item" }},
        .body = .{ .stmts = &.{} },
    } };

    const inlined = try emitExpression(std.testing.allocator, comptime_loop);
    defer std.testing.allocator.free(inlined);
    try std.testing.expectEqualStrings(
        "inline for (Fields, Slots) |Field, Slot| {\n}",
        inlined,
    );

    const runtime = try emitExpression(std.testing.allocator, runtime_loop);
    defer std.testing.allocator.free(runtime);
    try std.testing.expectEqualStrings(
        "for (items) |item| {\n}",
        runtime,
    );
}

// A conditional can bind a payload per branch. Zig captures whatever the
// condition evaluated to, so the one shape serves both an optional that was
// unwrapped and an error union that was split.
test "emitExpr: a conditional binds a payload per branch and keeps its group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const split: ast.Expr = .{ .if_expr = .{
        .cond = try boxed(a, .{ .call = .{
            .callee = try boxed(a, ident("parse")),
            .args = try list(a, &.{.{ .ident = "input" }}),
        } }),
        .then_capture = .{ .name = "ok" },
        .then_body = try boxed(a, ident("ok")),
        .else_body = try boxed(a, ident("fallback")),
        .else_capture = .{ .name = "tag" },
    } };

    // A borrowed payload takes the same star a `for` capture takes.
    const borrowed: ast.Expr = .{ .if_expr = .{
        .cond = try boxed(a, ident("maybe")),
        .then_capture = .{ .name = "item", .by_ref = true },
        .then_body = try boxed(a, ident("item")),
    } };

    // A binding Zig would read as a keyword has to stay quoted, or the
    // payload is not an identifier at all.
    const keyword: ast.Expr = .{ .if_expr = .{
        .cond = try boxed(a, ident("maybe")),
        .then_capture = .{ .name = "error" },
        .then_body = try boxed(a, ident("error")),
    } };

    // The conditional is a whole expression, so an operator still wraps it
    // rather than applying to the payload the branch binds.
    const biased: ast.Expr = try binary(a, .add, split, ident("bias"));

    try expectEmittedRows(a, &.{
        .{
            .expression = split,
            .expected = "if (parse(input)) |ok| ok else |tag| fallback",
        },
        .{ .expression = borrowed, .expected = "if (maybe) |*item| item" },
        .{ .expression = keyword, .expected = "if (maybe) |@\"error\"| @\"error\"" },
        .{
            .expression = biased,
            .expected = "(if (parse(input)) |ok| ok else |tag| fallback) + bias",
        },
    });
}

/// The condition a Rust `loop` lowers to. Zig only needs it spelled, so every
/// loop test here builds its header from this one.
fn forever(a: std.mem.Allocator) !*ast.Expr {
    return boxed(a, .{ .lit = .{ .bool_lit = true } });
}

// Zig rejects a loop label no `break` or `continue` names, so a source label
// reaches the emitted loop only when an exit inside its body lands on it.
test "emitExpr: a while loop label nothing names is left off" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `'outer: while true { step(); }` names its label nowhere.
    const loop: ast.Expr = .{ .while_expr = .{
        .cond = try forever(a),
        .label = "outer",
        .body = .{ .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, ident("step")) }}) },
    } };

    try expectEmittedRows(a, &.{
        .{ .expression = loop, .expected = "while (true) {\n    step;\n}" },
    });
}

test "emitExpr: a while loop keeps a label its own break names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const loop: ast.Expr = .{ .while_expr = .{
        .cond = try forever(a),
        .label = "outer",
        .body = .{ .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, .{
            .break_expr = .{ .label = "outer" },
        }) }}) },
    } };

    try expectEmittedRows(a, &.{
        .{ .expression = loop, .expected = "outer: while (true) {\n    break :outer;\n}" },
    });
}

test "emitExpr: a continue alone keeps a while loop label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const loop: ast.Expr = .{ .while_expr = .{
        .cond = try forever(a),
        .label = "outer",
        .body = .{ .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, .{
            .continue_expr = .{ .label = "outer" },
        }) }}) },
    } };

    try expectEmittedRows(a, &.{
        .{ .expression = loop, .expected = "outer: while (true) {\n    continue :outer;\n}" },
    });
}

test "emitExpr: a for loop label follows the same rule as a while loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const unnamed: ast.Expr = .{ .for_expr = .{
        .inputs = &.{.{ .ident = "items" }},
        .captures = &.{.{ .name = "item" }},
        .label = "outer",
        .body = .{ .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, ident("step")) }}) },
    } };
    const named: ast.Expr = .{ .for_expr = .{
        .inputs = &.{.{ .ident = "items" }},
        .captures = &.{.{ .name = "item" }},
        .label = "outer",
        .body = .{ .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, .{
            .break_expr = .{ .label = "outer" },
        }) }}) },
    } };

    try expectEmittedRows(a, &.{
        .{ .expression = unnamed, .expected = "for (items) |item| {\n    step;\n}" },
        .{ .expression = named, .expected = "outer: for (items) |item| {\n    break :outer;\n}" },
    });
}

// A loop that carries a value hands it to a generated wrapper block, so a
// `break` naming the loop's source label lands on that block instead and the
// label has nothing left to name.
test "emitExpr: a value loop drops the label its own break named" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `'outer: loop { loop { break 'outer 5; } }`.
    const inner: ast.Expr = .{ .while_expr = .{
        .cond = try forever(a),
        .body = .{ .expr = try boxed(a, .{ .break_expr = .{
            .value = try boxed(a, .{ .lit = .{ .uint = 5 } }),
            .label = "outer",
        } }) },
    } };
    const outer: ast.Expr = .{ .while_expr = .{
        .cond = try forever(a),
        .label = "outer",
        .body = .{ .expr = try boxed(a, inner) },
    } };

    const emitted = try emitExpression(std.testing.allocator, outer);
    defer std.testing.allocator.free(emitted);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "break :__r2z_value_loop_0 5;") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "outer:") == null);
}

// `'outer: loop { 'outer: loop { break 'outer; } }`: the break names the inner
// loop, so only the inner one may carry the label.
test "emitExpr: a loop shadowed by a nested one loses its label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const inner: ast.Expr = .{ .while_expr = .{
        .cond = try forever(a),
        .label = "outer",
        .body = .{ .expr = try boxed(a, .{ .break_expr = .{ .label = "outer" } }) },
    } };
    const outer: ast.Expr = .{ .while_expr = .{
        .cond = try forever(a),
        .label = "outer",
        .body = .{ .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, inner) }}) },
    } };

    try expectEmittedRows(a, &.{
        .{
            .expression = outer,
            .expected = "while (true) {\n    outer: while (true) {\n        break :outer;\n    }\n}",
        },
    });
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
        .break_expr = .{ .value = try boxed(a, try binary(a, .add, ident("a"), ident("b"))) },
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
    try std.testing.expect(std.mem.indexOf(u8, try emitExpression(a, chunk_loop), "while ((a + b).len > __chunk_index)") != null);
    try std.testing.expect(std.mem.indexOf(u8, try emitExpression(a, chunk_loop), "const chunk = (a + b)[__chunk_index..@min(__chunk_index + n, (a + b).len)];") != null);
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

test "emitFile: a type alias renders through emitType, not as an identifier" {
    const byte = ast.Type{ .prim = .u8 };
    const rows = ast.Type{ .slice = .{ .elem = &byte, .is_const = true } };
    const file: ast.File = .{
        .path = "src/root.zig",
        .decls = &.{
            .{ .const_decl = .{
                .name = "BytePointer",
                .init = .{ .type_value = .{ .ptr = .{
                    .elem = &byte,
                    .is_const = true,
                    .size = .c,
                } } },
            } },
            .{ .const_decl = .{
                .name = "Rows",
                .init = .{ .type_value = .{ .opt = &rows } },
            } },
        },
    };
    const output = try emitFile(std.testing.allocator, file);
    defer std.testing.allocator.free(output);
    try std.testing.expect(
        std.mem.indexOf(u8, output, "pub const BytePointer = [*c]const u8;") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, output, "pub const Rows = ?[]const u8;") != null,
    );
}

// A Rust `for` is `()`, so a block that ends in one hands out no value. The
// chunk loop is the sharp case: `emitChunkLoop` writes a prelude and a
// `while`, so a `break :label` prefixed onto it lands in the middle of the
// `var` and the emitted file stops parsing there.
test "emitExpr: a block ending in a unit loop is written as a statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const chunk_loop: ast.Expr = .{ .for_expr = .{
        .inputs = try list(a, &.{.{ .builtin = .{
            .name = "sliceChunks",
            .args = try list(a, &.{ ident("data"), ident("n") }),
        } }}),
        .captures = try listCaptures(a, &.{.{ .name = "chunk" }}),
        .body = .{
            .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, ident("use")) }}),
            .expr = null,
        },
    } };
    const chunk_tail: ast.Expr = .{ .block = .{
        .stmts = try listStmts(a, &.{}),
        .expr = try boxed(a, chunk_loop),
    } };
    // A Rust `while` is `()` too, so it is the same case by the same rule.
    const while_tail: ast.Expr = .{ .block = .{
        .stmts = try listStmts(a, &.{}),
        .expr = try boxed(a, .{ .while_expr = .{
            .cond = try boxed(a, ident("p")),
            .body = .{ .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, ident("step")) }}) },
        } }),
    } };

    try expectEmittedRows(a, &.{
        .{
            .expression = chunk_tail,
            .expected = "{\n" ++
                "    var __chunk_index: usize = 0;\n" ++
                "    while (data.len > __chunk_index) : (__chunk_index += n) {\n" ++
                "        const chunk = data[__chunk_index..@min(__chunk_index + n, data.len)];\n" ++
                "        use;\n" ++
                "    }\n" ++
                "}",
        },
        .{ .expression = while_tail, .expected = "{\n    while (p) {\n        step;\n    }\n}" },
    });
}

// The other side of the same rule: a tail that really does carry a value still
// leaves through the block's label, whatever shape it has.
test "emitExpr: a block ending in a value still breaks out of its label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `{ step(); 5 }`.
    const literal_tail: ast.Expr = .{ .block = .{
        .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, ident("step")) }}),
        .expr = try boxed(a, .{ .lit = .{ .uint = 5 } }),
    } };
    // `{ loop { break 5; } }` — a Rust `loop` lowers to a value `while`.
    const loop_tail: ast.Expr = .{ .block = .{
        .stmts = try listStmts(a, &.{}),
        .expr = try boxed(a, .{ .while_expr = .{
            .cond = try forever(a),
            .body = .{ .expr = try boxed(a, .{ .break_expr = .{
                .value = try boxed(a, .{ .lit = .{ .uint = 5 } }),
            } }) },
        } }),
    } };
    // `{ { 5 } }` — a block tail carries a value when the block inside it does.
    const block_tail: ast.Expr = .{ .block = .{
        .stmts = try listStmts(a, &.{}),
        .expr = try boxed(a, .{ .block = .{
            .stmts = try listStmts(a, &.{}),
            .expr = try boxed(a, .{ .lit = .{ .uint = 5 } }),
        } }),
    } };

    try expectEmittedRows(a, &.{
        .{
            .expression = literal_tail,
            .expected = "__r2z_value_block_0: {\n    step;\n    break :__r2z_value_block_0 5;\n}",
        },
        .{
            .expression = block_tail,
            .expected = "__r2z_value_block_0: {\n" ++
                "    break :__r2z_value_block_0 __r2z_value_block_1: {\n" ++
                "        break :__r2z_value_block_1 5;\n" ++
                "    };\n" ++
                "}",
        },
    });

    // The value loop is the one tail whose own shape decides the classification,
    // so it is checked against the emitted text rather than a row: the block
    // keeps its label, the loop is handed to it whole, and the loop's own
    // value-carrying `break` still names the loop. It is not demoted to a
    // statement just because a `while` is one of the statement-like forms.
    const loop_emitted = try emitExpression(a, loop_tail);
    try std.testing.expect(std.mem.indexOf(u8, loop_emitted, "__r2z_value_block_0: {") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, loop_emitted, "break :__r2z_value_block_0 __r2z_value_loop_1:") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, loop_emitted, "break :__r2z_value_loop_1 5;") != null);
}

// `if bytes.is_empty() { .. } else { for bytes in bytes.chunks(n) { .. } }` —
// the shape wyhash's `Hasher::write` lowers to. The `else` block ends in a
// unit loop, so it is a statement on both sides of the `else`.
test "emitExpr: an else branch ending in a chunk loop stays a statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const chunk_loop: ast.Expr = .{ .for_expr = .{
        .inputs = try list(a, &.{.{ .builtin = .{
            .name = "sliceChunks",
            .args = try list(a, &.{ ident("data"), ident("n") }),
        } }}),
        .captures = try listCaptures(a, &.{.{ .name = "chunk" }}),
        .body = .{
            .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, ident("use")) }}),
            .expr = null,
        },
    } };
    const conditional: ast.Expr = .{ .if_expr = .{
        .cond = try boxed(a, ident("p")),
        .then_body = try boxed(a, .{ .block = .{
            .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, ident("mix")) }}),
            .expr = null,
        } }),
        .else_body = try boxed(a, .{ .block = .{
            .stmts = try listStmts(a, &.{}),
            .expr = try boxed(a, chunk_loop),
        } }),
    } };

    const emitted = try emitExpression(a, conditional);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "break :") == null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "while (data.len > __chunk_index)") != null);
}

// Zig rejects a parameter its body never reads; Rust allows one. Zig 0.16
// accepts NO spelling for it: an unnamed parameter is `missing parameter name`
// and a `_`-prefixed one is still `unused function parameter`. Both forms were
// compiled to confirm it. The only form that compiles keeps the name and
// discards it in the body, which is the same `_ = <name>;` this emitter already
// writes for an unread `self` receiver and an unread local.
test "emitFile: an unread parameter keeps its name and is discarded in the body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const byte = ast.Type{ .prim = .u8 };
    const shape_code = ast.Decl{ .fn_decl = .{
        .name = "shapeCode",
        .params = &.{
            .{ .name = "unit", .ty = byte },
            .{ .name = "record", .ty = byte },
            .{ .name = "choice", .ty = byte },
        },
        .ret_type = byte,
        .body = .{ .expr = try boxed(a, ident("choice")) },
    } };

    const out = try emitFile(a, .{ .path = "src/shape.zig", .decls = &.{shape_code} });
    // Every parameter keeps the spelling the source declared, so the position
    // and the generated documentation both still name it.
    try std.testing.expect(std.mem.indexOf(
        u8,
        out,
        "pub fn shapeCode(unit: u8, record: u8, choice: u8) u8 {",
    ) != null);
    // The two unread ones are discarded in the body, and the read one is not.
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = unit;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = record;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = choice;") == null);
    // Neither spelling Zig rejects may appear.
    try std.testing.expect(std.mem.indexOf(u8, out, "_unit") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_record") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "return choice;") != null);
}

// A closure reaches the emitter already inlined at its call site — the Zig AST
// has no closure node — so a read that happens only inside one arrives as a
// block argument, and a loop payload arrives as an ordinary `for`. Both are
// below the function body. Nothing is renamed any more, so the observable is
// no longer a `_`-prefixed name but a `_ = <name>;` the walk would add to a
// parameter it wrongly called unread: both of these stay live, so neither
// discard may appear.
test "emitFile: a parameter read only inside an inlined closure keeps its plain name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const byte = ast.Type{ .prim = .u8 };
    const closure_call = ast.Expr{
        .call = .{
            .callee = try boxed(a, ident("mapEach")),
            .args = try list(a, &.{
                ident("items"),
                // The inlined closure body: a block whose tail is the read.
                .{ .block = .{ .stmts = &.{}, .expr = try boxed(a, ident("scale")) } },
            }),
        },
    };
    const payload_loop = ast.Expr{ .for_expr = .{
        .inputs = try list(a, &.{ident("items")}),
        .captures = try listCaptures(a, &.{.{ .name = "item" }}),
        .body = .{
            .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, ident("scale")) }}),
            .expr = null,
        },
    } };
    const apply = ast.Decl{ .fn_decl = .{
        .name = "apply",
        .params = &.{
            .{ .name = "items", .ty = byte },
            .{ .name = "scale", .ty = byte },
        },
        .ret_type = .{ .void_type = {} },
        .body = .{ .stmts = try listStmts(a, &.{
            .{ .expr_stmt = try boxed(a, closure_call) },
            .{ .expr_stmt = try boxed(a, payload_loop) },
        }) },
    } };

    const out = try emitFile(a, .{ .path = "src/apply.zig", .decls = &.{apply} });
    try std.testing.expect(std.mem.indexOf(u8, out, "items: u8, scale: u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_scale") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_items") == null);
    // A descent that stopped at the surface would call `scale` and `items`
    // unread and write the discards the rule requires, which is a silent
    // rewrite of the body rather than a compile error — so the absence of the
    // discard is the property, not the spelling.
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = scale;") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = items;") == null);
}

// A name that already begins with `_` is left exactly as it is. Under the
// discard-in-the-body rule nothing is renamed at all, so the second-underscore
// hazard cannot arise; this pins that the name survives untouched and is still
// discarded, because Zig rejects an unread parameter whatever it is called.
test "emitFile: a parameter already named with a leading underscore keeps its name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const byte = ast.Type{ .prim = .u8 };
    const measure = ast.Decl{ .fn_decl = .{
        .name = "measure",
        .params = &.{
            .{ .name = "_unit", .ty = byte },
            .{ .name = "record", .ty = byte },
        },
        .ret_type = byte,
        .body = .{ .expr = try boxed(a, .{ .lit = .{ .int = 1 } }) },
    } };

    const out = try emitFile(a, .{ .path = "src/measure.zig", .decls = &.{measure} });
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn measure(_unit: u8, record: u8) u8 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__unit") == null);
    // `_unit` is unread and `record` is unread, so BOTH are discarded in the body.
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = _unit;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = record;\n") != null);
}

// The discard is a body statement, not a signature change: the parameter keeps
// its position AND its name, so the arity the source declared is still the
// arity every call site supplies and every call site still names it.
test "emitFile: a caller still passes every argument positionally" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const byte = ast.Type{ .prim = .u8 };
    const forwarded = ast.Expr{ .call = .{
        .callee = try boxed(a, ident("pick")),
        .args = try list(a, &.{ ident("choice"), .{ .lit = .{ .int = 1 } } }),
    } };
    const shape_code = ast.Decl{ .fn_decl = .{
        .name = "shapeCode",
        .params = &.{
            .{ .name = "unit", .ty = byte },
            .{ .name = "choice", .ty = byte },
        },
        .ret_type = byte,
        .body = .{
            .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, forwarded) }}),
            .expr = try boxed(a, .{ .lit = .{ .int = 0 } }),
        },
    } };

    const out = try emitFile(a, .{ .path = "src/shape.zig", .decls = &.{shape_code} });
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn shapeCode(unit: u8, choice: u8) u8 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pick(choice, 1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "return 0;") != null);
}

// Rust introduces the local only after its initialiser is produced, so a
// declaration that rebinds the parameter's name never reads the parameter.
// Counting that declaration as a read would leave a genuinely unread
// parameter with no discard in its body, which is exactly the Zig error.
test "emitFile: a parameter the body shadows is still unread" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const byte = ast.Type{ .prim = .u8 };
    const shadowed = ast.Decl{ .fn_decl = .{
        .name = "shadowed",
        .params = &.{.{ .name = "unit", .ty = byte }},
        .ret_type = byte,
        .body = .{
            .stmts = try listStmts(a, &.{.{ .let_stmt = .{
                .name = "unit",
                .init = .{ .lit = .{ .int = 3 } },
            } }}),
            .expr = try boxed(a, .{ .lit = .{ .int = 3 } }),
        },
    } };

    const out = try emitFile(a, .{ .path = "src/shadowed.zig", .decls = &.{shadowed} });
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn shadowed(unit: u8) u8 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = unit;\n") != null);
}

// The other half of the same rule: the initialiser runs while the parameter is
// still the only `unit` in scope, so this one IS a read and the plain name has
// to survive.
test "emitFile: a shadowing initialiser still reads the parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const byte = ast.Type{ .prim = .u8 };
    const shadowed = ast.Decl{ .fn_decl = .{
        .name = "shadowed",
        .params = &.{.{ .name = "unit", .ty = byte }},
        .ret_type = byte,
        .body = .{
            .stmts = try listStmts(a, &.{.{ .let_stmt = .{
                .name = "unit",
                .init = ident("unit"),
            } }}),
            .expr = try boxed(a, .{ .lit = .{ .int = 0 } }),
        },
    } };

    const out = try emitFile(a, .{ .path = "src/shadowed.zig", .decls = &.{shadowed} });
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn shadowed(unit: u8) u8 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_unit") == null);
}

// The bare `_` that spells an unread switch capture is a different Zig
// construct, and the two rules must not collapse into one spelling: an arm
// whose binding nothing reads writes no capture at all, while the unread
// parameter beside it is discarded by a body statement.
test "emitFile: the parameter prefix is not the switch capture spelling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const byte = ast.Type{ .prim = .u8 };
    const arm_body: ast.Expr = .{ .lit = .{ .int = 10 } };
    const binding_arm = ast.MatchArm{ .patterns = &.{.{ .binding = "value" }}, .body = arm_body };
    const shape_code = ast.Decl{ .fn_decl = .{
        .name = "shapeCode",
        .params = &.{
            .{ .name = "record", .ty = byte },
            .{ .name = "choice", .ty = byte },
        },
        .ret_type = byte,
        .body = .{ .expr = try boxed(a, .{ .match_expr = .{
            .target = try boxed(a, ident("choice")),
            .arms = try listArms(a, &.{binding_arm}),
        } }) },
    } };

    const out = try emitFile(a, .{ .path = "src/shape.zig", .decls = &.{shape_code} });
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn shapeCode(record: u8, choice: u8) u8 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "else =>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "|value|") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = record;\n") != null);
}

// The `self` receiver answers the same question every ordinary parameter does,
// and it is written by a second rule: the receiver is skipped when the
// parameter list is walked, so its discard cannot also arrive as an ordinary
// one. Rust allows a method that never mentions its receiver, and Zig reports
// that as `unused function parameter`, so the discard has to be there.
test "emitFile: an unread receiver is discarded once, and a read one is not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const byte = ast.Type{ .prim = .u8 };
    const greeter = ast.Type{ .named = "Greeter" };
    const receiver = ast.FnParam{ .name = "self", .ty = .{ .ptr = .{ .elem = &greeter, .is_const = true } } };
    const step = ast.Expr{ .call = .{
        .callee = try boxed(a, ident("bump")),
        .args = try list(a, &.{ident("tag")}),
    } };
    const forgetful = ast.Decl{ .fn_decl = .{
        .name = "forgetful",
        .params = &.{ receiver, .{ .name = "tag", .ty = byte } },
        .ret_type = .{ .void_type = {} },
        .body = .{ .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, step) }}) },
    } };

    const out = try emitFile(a, .{ .path = "src/greeter.zig", .decls = &.{forgetful} });
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn forgetful(self: *const Greeter, tag: u8) void {") != null);
    // The receiver is the only unread name here: `bump(tag)` READS `tag`, so
    // the ordinary parameter beside it is live and gets no discard. One
    // `_ =` line, and the receiver is not among them twice.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "_ = self;\n"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "_ = tag;\n"));

    // The same declaration with a body that reads the receiver writes no
    // discard for it, which is the half a scan that always discarded would
    // get wrong.
    const aware = ast.Decl{ .fn_decl = .{
        .name = "aware",
        .params = &.{ receiver, .{ .name = "tag", .ty = byte } },
        .ret_type = byte,
        .body = .{ .expr = try boxed(a, .{ .field_access = .{
            .target = try boxed(a, ident("self")),
            .field_name = "id",
        } }) },
    } };
    const read_out = try emitFile(a, .{ .path = "src/greeter.zig", .decls = &.{aware} });
    try std.testing.expect(std.mem.indexOf(u8, read_out, "pub fn aware(self: *const Greeter, tag: u8) u8 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_out, "_ = self;\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, read_out, "return self.id;\n") != null);
}

// A `comptime T: type` parameter is the one parameter whose references live in
// the SIGNATURE (`bytes: []const T`), not in the body, so a body-only scan
// would answer "unread" and discard a parameter the parameter list still
// needs. The exemption is the `is_comptime` arm of the same walk, and this
// pins it against the ordinary parameter beside it, which is discarded.
test "emitFile: a comptime type parameter is exempt from the body discard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const byte = ast.Type{ .prim = .u8 };
    const named_t = ast.Type{ .named = "T" };
    const head = ast.Decl{ .fn_decl = .{
        .name = "head",
        .params = &.{
            .{ .name = "T", .ty = .{ .prim = .type_type }, .is_comptime = true },
            .{ .name = "bytes", .ty = .{ .slice = .{ .elem = &named_t, .is_const = true } } },
        },
        .ret_type = byte,
        .body = .{ .expr = try boxed(a, .{ .lit = .{ .int = 0 } }) },
    } };

    const out = try emitFile(a, .{ .path = "src/head.zig", .decls = &.{head} });
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn head(comptime T: type, bytes: []const T) u8 {") != null);
    // `T` is named by the parameter beside it and never by the body, so it is
    // the one parameter here with no discard.
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = T;\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = bytes;\n") != null);
}

// A `macro_rules!` body reaches the emitter already expanded, so there is no
// macro node to descend into — what arrives is the statements the body spells.
// The shapes only an expansion leaves behind are the bare block it wraps
// itself in, the `defer` it drops in, and the `match` whose arms carry the
// result; a read inside any of them is a read of the parameter. The positive
// control is the sibling nothing reads: it must still be discarded, or an
// absence proves nothing.
test "emitFile: a parameter read only inside a macro-expanded body keeps its plain name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const byte = ast.Type{ .prim = .u8 };
    const expansion: ast.Expr = .{ .block = .{ .stmts = try listStmts(a, &.{
        .{ .expr_stmt = try boxed(a, ident("scale")) },
        .{ .defer_stmt = .{ .expr = ident("scale") } },
    }) } };
    const arm_body: ast.Expr = .{ .block = .{
        .stmts = try listStmts(a, &.{}),
        .expr = try boxed(a, ident("scale")),
    } };
    const dispatch: ast.Expr = .{ .match_expr = .{
        .target = try boxed(a, ident("kind")),
        .arms = try listArms(a, &.{.{ .patterns = &.{.{ .binding = "variant" }}, .body = arm_body }}),
    } };
    const apply = ast.Decl{ .fn_decl = .{
        .name = "apply",
        .params = &.{
            .{ .name = "kind", .ty = byte },
            .{ .name = "scale", .ty = byte },
            .{ .name = "record", .ty = byte },
        },
        .ret_type = .{ .void_type = {} },
        .body = .{ .stmts = try listStmts(a, &.{
            .{ .expr_stmt = try boxed(a, expansion) },
            .{ .expr_stmt = try boxed(a, dispatch) },
        }) },
    } };

    const out = try emitFile(a, .{ .path = "src/apply.zig", .decls = &.{apply} });
    try std.testing.expect(std.mem.indexOf(u8, out, "kind: u8, scale: u8, record: u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = scale;\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = kind;\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = record;\n") != null);
    // The read reached the emitter through all three shapes, so each one is
    // still on the page naming the parameter it read. The match arm's label is
    // depth-seeded, so the payload is checked from the break rather than from a
    // suffix this file does not fix.
    try std.testing.expect(std.mem.indexOf(u8, out, "scale;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "defer scale;") != null);
    const arm_break = std.mem.indexOf(u8, out, "break :__r2z_value_block_").?;
    try std.testing.expect(std.mem.indexOfPos(u8, out, arm_break, " scale;") != null);
}

// A read that arrives through a qualified name, a cast operand or the right
// side of an assignment reaches the walk through three different nodes, and
// the qualified one only matches because the comparison is on the path's root.
test "emitFile: a parameter read through a field, a cast and an assignment keeps its plain name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const byte = ast.Type{ .prim = .u8 };
    const widened = ast.Expr{ .cast = .{ .target = byte, .operand = try boxed(a, ident("scale")) } };
    const carried = ast.Decl{ .fn_decl = .{
        .name = "carried",
        .params = &.{
            .{ .name = "scale", .ty = byte },
            .{ .name = "record", .ty = byte },
        },
        .ret_type = .{ .void_type = {} },
        .body = .{ .stmts = try listStmts(a, &.{
            .{ .expr_stmt = try boxed(a, .{ .field_access = .{
                .target = try boxed(a, ident("scale")),
                .field_name = "len",
            } }) },
            .{ .expr_stmt = try boxed(a, widened) },
            .{ .assign = .{
                .target = ident("total"),
                .val = ident("scale"),
            } },
        }) },
    } };

    const out = try emitFile(a, .{ .path = "src/carried.zig", .decls = &.{carried} });
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = scale;\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = record;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "scale.len;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "total = scale;") != null);
}

// The other half of a loop is its `else` arm, which the emitter writes outside
// the body and inside the scope that owns the enclosing exit. A read that
// happens only there is still a read of the parameter.
test "emitFile: a parameter read only in a loop body or its else arm keeps its plain name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const byte = ast.Type{ .prim = .u8 };
    const counted: ast.Expr = .{ .while_expr = .{
        .cond = try boxed(a, ident("more")),
        .body = .{ .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, ident("scale")) }}) },
        .else_body = try boxed(a, .{ .block = .{
            .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, ident("scale")) }}),
        } }),
    } };
    const drained: ast.Expr = .{ .for_expr = .{
        .inputs = try list(a, &.{ident("items")}),
        .captures = try listCaptures(a, &.{.{ .name = "item" }}),
        .body = .{ .stmts = try listStmts(a, &.{}), .expr = null },
        .else_body = try boxed(a, .{ .block = .{
            .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, ident("scale")) }}),
        } }),
    } };
    const tally = ast.Decl{ .fn_decl = .{
        .name = "tally",
        .params = &.{
            .{ .name = "items", .ty = byte },
            .{ .name = "scale", .ty = byte },
            .{ .name = "record", .ty = byte },
        },
        .ret_type = .{ .void_type = {} },
        .body = .{ .stmts = try listStmts(a, &.{
            .{ .expr_stmt = try boxed(a, counted) },
            .{ .expr_stmt = try boxed(a, drained) },
        }) },
    } };

    const out = try emitFile(a, .{ .path = "src/tally.zig", .decls = &.{tally} });
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = scale;\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = items;\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = record;\n") != null);
    // Both `else` arms are written, and each one still names the parameter.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, " else "));
    try std.testing.expect(std.mem.indexOf(u8, out, "while (more) {\n        scale;\n    } else ") != null);
}

// A labelled block reaches Zig in one position it accepts as a branch, and the
// lowerer uses exactly that one: the collection error block and the guarded
// match chain both land in an `if` arm. The spelling is pinned here — the label
// leads the braces with nothing in front of it and nothing after them, because
// a branch is already a whole statement and neither the `break :` a value tail
// carries nor the `;` a value expression needs may be added to it.
test "emitExpr: a labelled block is written bare in the branch that takes it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const branch: ast.Expr = .{ .block = .{
        .label = "__r2z_collect_err",
        .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, ident("release")) }}),
        .expr = try boxed(a, .{ .lit = .{ .int = 7 } }),
    } };
    const conditional: ast.Expr = .{ .if_expr = .{
        .cond = try boxed(a, ident("failed")),
        .then_body = try boxed(a, branch),
        .else_body = try boxed(a, .{ .lit = .{ .int = 0 } }),
    } };

    const out = try emitExpression(a, conditional);
    try std.testing.expectEqualStrings(
        "if (failed) __r2z_collect_err: {\n" ++
            "    release;\n" ++
            "    break :__r2z_collect_err 7;\n" ++
            "} else 0",
        out,
    );
    // The label leads the block and nothing terminates it: a branch is already
    // a whole statement, so a `;` here is the Zig error this spelling avoids.
    try std.testing.expect(std.mem.indexOf(u8, out, "__r2z_collect_err: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "} else 0") != null);
}

// The five emitter tests that used to live in `ast.zig`, read through helpers
// there because that file has no test file of its own. They belong here: the
// helpers they need — `emitExpression` and `emitFile` — already exist, and a
// shape whose AST validates is not the same claim as a shape whose emitted Zig
// is what the shape claims.
//
// Two of them needed their ASSERTION corrected as well as their home. A
// self-valued labelled block written as a bare statement, and a guard chain
// written as a function-body tail, are both positions the emitter no longer
// emits: the label needs a carrier for the value it carries. Each test below
// asserts the shape that is actually emitted, which is the shape that compiles.

// A self-valued labelled block emits its own label and leaves through it. It
// reaches Zig through a CARRIER — a `const` initializer here — because written
// as a bare statement there is nothing for the block's value to attach to and
// Zig reads the label as a statement label.
test "emitFile: a self-valued labelled block is written as a labelled block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const seven = try boxed(a, .{ .lit = .{ .uint = 7 } });
    const bound = ast.Decl{ .fn_decl = .{
        .name = "chainValue",
        .ret_type = .{ .prim = .u8 },
        .body = .{
            .stmts = try listStmts(a, &.{.{ .let_stmt = .{
                .name = "answer",
                .init = .{ .block = .{ .label = "chain", .expr = seven } },
            } }}),
            .expr = try boxed(a, ident("answer")),
        },
    } };

    const out = try emitFile(a, .{ .path = "src/chain.zig", .decls = &.{bound} });
    // The label is the source's own and the value leaves through it: both
    // bytes are the shape, because a block that emitted `break :` with no label
    // would not parse.
    try std.testing.expect(std.mem.indexOf(u8, out, "const answer = chain: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "break :chain 7;") != null);

    // An unlabelled value block still gets a label of the emitter's own, and it
    // is a DIFFERENT one — which is why the two are not the same shape and
    // must not be emitted as one.
    const generated = ast.Decl{ .fn_decl = .{
        .name = "generatedValue",
        .ret_type = .{ .prim = .u8 },
        .body = .{
            .stmts = try listStmts(a, &.{.{ .let_stmt = .{
                .name = "answer",
                .init = .{ .block = .{ .expr = seven } },
            } }}),
            .expr = try boxed(a, ident("answer")),
        },
    } };
    const generated_out = try emitFile(a, .{ .path = "src/chain.zig", .decls = &.{generated} });
    try std.testing.expect(
        std.mem.indexOf(u8, generated_out, "const answer = __r2z_value_block_") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, generated_out, "break :") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_out, "chain") == null);
}

// The ordered chain a guarded `match` lowers to: a labelled block whose arms
// leave through `break :label`, closed by the `unreachable` that stands where
// every value was already taken. It is bound to a local rather than moved into
// the body's tail, because a labelled block needs the binding to be what gives
// its value somewhere to go.
test "emitFile: the guard chain keeps its label, its exits and its unreachable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const guarded_arm = ast.Expr{ .block = .{
        .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, .{ .if_expr = .{
            .cond = try boxed(a, ident("usable")),
            .then_body = try boxed(a, .{ .block = .{
                .stmts = try listStmts(a, &.{.{ .expr_stmt = try boxed(a, .{ .break_expr = .{
                    .value = try boxed(a, ident("payload")),
                    .label = "__r2z_match_block",
                } }) }}),
            } }),
        } }) }}),
    } };
    const dispatch = ast.Expr{ .match_expr = .{
        .target = try boxed(a, ident("input")),
        .arms = try listArms(a, &.{
            .{ .patterns = &.{.{ .enum_literal = "Found" }}, .body = guarded_arm },
            .{ .patterns = &.{.wildcard}, .body = ident("fallback") },
        }),
    } };
    const chain = ast.Expr{ .block = .{
        .label = "__r2z_match_block",
        .stmts = try listStmts(a, &.{
            .{ .expr_stmt = try boxed(a, dispatch) },
            .{ .expr_stmt = try boxed(a, .{ .unreachable_ = {} }) },
        }),
    } };

    const classify = ast.Decl{ .fn_decl = .{
        .name = "classify",
        .ret_type = .{ .named = "Tag" },
        .body = .{
            .stmts = try listStmts(a, &.{.{ .let_stmt = .{
                .name = "__r2z_chain",
                .init = chain,
            } }}),
            .expr = try boxed(a, ident("__r2z_chain")),
        },
    } };
    const out = try emitFile(a, .{ .path = "src/classify.zig", .decls = &.{classify} });

    // The chain is bound, and the tail names the binding — so the label never
    // reaches the one position it has no spelling for.
    try std.testing.expect(
        std.mem.indexOf(u8, out, "const __r2z_chain = __r2z_match_block: {") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, out, "return __r2z_chain;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "return __r2z_match_block") == null);
    // The scrutinee is dispatched, the guard sits inside the arm's prong, and
    // the arm's value leaves through the chain's own label — not through the
    // arm block, which is not the carrier.
    try std.testing.expect(std.mem.indexOf(u8, out, "switch (input) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".Found =>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "if (usable)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "break :__r2z_match_block payload;") != null);
    // The chain closes where every value was already taken.
    try std.testing.expect(std.mem.indexOf(u8, out, "unreachable;") != null);
    // Exactly one label was written, and it is the chain's: a second one would
    // be a redefinition Zig refuses.
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, out, "__r2z_match_block: {"),
    );
}

// The per-field destructure: each binding is read out of the captured payload
// by the field it came from, and the arm's value leaves through the arm's own
// generated label. Two fields binding one name would write two `const` of that
// name in one block, which is why the AST refuses it — this pins the bytes the
// refusal is protecting.
test "emitExpr: a per-field destructure reads each field into its own binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const destructure = ast.Expr{ .match_expr = .{
        .target = try boxed(a, ident("input")),
        .arms = try listArms(a, &.{.{ .patterns = &.{.{ .struct_pat = .{
            .name = "pair",
            .fields = &.{
                .{ .name = "left", .pat = .{ .binding = "left" } },
                .{ .name = "right", .pat = .{ .binding = "right" } },
            },
        } }}, .body = .{ .bin_op = .{
            .op = .add,
            .lhs = try boxed(a, ident("left")),
            .rhs = try boxed(a, ident("right")),
        } } }}),
    } };
    const out = try emitExpression(a, destructure);

    // The field is what each name is read from, so the pairing is the shape:
    // swapping which field a name comes from moves two bytes and nothing else.
    try std.testing.expect(
        std.mem.indexOf(u8, out, "const left = __r2z_match_payload.left;") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, out, "const right = __r2z_match_payload.right;") != null,
    );
    // The arm's own value leaves through the arm's generated block, which is
    // the one the emitter invents — not through the chain, and not through a
    // `return`.
    try std.testing.expect(
        std.mem.indexOf(u8, out, "break :__r2z_match_arm left + right;") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, out, "return") == null);

    // The single positional field is NOT read this way: it takes the direct
    // capture, so the payload is bound whole and no field access is written.
    const positional = ast.Expr{ .match_expr = .{
        .target = try boxed(a, ident("input")),
        .arms = try listArms(a, &.{.{ .patterns = &.{.{ .struct_pat = .{
            .name = "Some",
            .fields = &.{.{ .name = "0", .pat = .{ .binding = "value" } }},
        } }}, .body = ident("value") }}),
    } };
    const positional_out = try emitExpression(a, positional);
    try std.testing.expect(
        std.mem.indexOf(u8, positional_out, ".Some => |value| value") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, positional_out, "__r2z_match_payload") == null);
}

// The owner-position turbofish: the type argument is written by `emitType`
// ahead of every value argument, because Zig's generic parameters are
// comptime and come first. An owner instantiation therefore reads
// `Vec(T).empty`, not `Vec.empty(T)`.
test "emitExpr: an owner turbofish writes the type argument before any value argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const owner = ast.Expr{ .call = .{
        .callee = try boxed(a, ident("std.ArrayListUnmanaged")),
        .generic_args = &.{.{ .prim = .u8 }},
    } };
    const owner_init = ast.Expr{ .field_access = .{
        .target = try boxed(a, owner),
        .field_name = "empty",
    } };
    const out = try emitExpression(a, owner_init);
    try std.testing.expectEqualStrings("std.ArrayListUnmanaged(u8).empty", out);

    // With a value argument beside it, the type argument still comes first —
    // that ordering is the shape, and moving it would bind `u8` to a value.
    const with_value = ast.Expr{ .call = .{
        .callee = try boxed(a, ident("std.ArrayListUnmanaged")),
        .generic_args = &.{.{ .prim = .u8 }},
        .args = try list(a, &.{ident("source")}),
    } };
    const value_out = try emitExpression(a, with_value);
    try std.testing.expectEqualStrings("std.ArrayListUnmanaged(u8, source)", value_out);

    // The same call with no type argument is a different shape and emits no
    // parentheses where the turbofish wrote them.
    const bare_out = try emitExpression(a, .{ .call = .{
        .callee = try boxed(a, ident("std.ArrayListUnmanaged")),
    } });
    try std.testing.expectEqualStrings("std.ArrayListUnmanaged()", bare_out);
}

// The discard for an unread parameter: Zig has no spelling for one, so the
// name is written verbatim in the parameter list and the `_ = <name>;` goes in
// the body. Both halves are pinned together here because the pair is the whole
// contract — a name without the discard is `unused function parameter`, and a
// discard without the name is `missing parameter name`.
test "emitFile: an underscore-prefixed parameter keeps its name and is still discarded in the body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const consume = ast.Decl{ .fn_decl = .{
        .name = "consume",
        .params = &.{
            .{ .name = "_unit", .ty = .{ .prim = .u8 } },
            .{ .name = "read", .ty = .{ .prim = .u8 } },
        },
        .ret_type = .{ .void_type = {} },
        .body = .{ .stmts = try listStmts(a, &.{
            .{ .expr_stmt = try boxed(a, .{ .unit = {} }) },
        }) },
    } };
    const out = try emitFile(a, .{ .path = "src/consume.zig", .decls = &.{consume} });

    // Both names are written in the parameter list: a parameter dropped from it
    // is `missing parameter name`, and a `_`-prefixed one is not a discard —
    // the `_` check belongs to the switch-capture spelling and has no say here.
    try std.testing.expect(std.mem.indexOf(u8, out, "(_unit: u8, read: u8)") != null);
    // Both are discarded in the body, `_unit` included, because both are unread.
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = _unit;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = read;\n") != null);

    // A parameter the body DOES read keeps no discard, so the two cases are
    // distinguished by the body rather than by the spelling of the name.
    const aware = ast.Decl{ .fn_decl = .{
        .name = "consume",
        .params = &.{.{ .name = "read", .ty = .{ .prim = .u8 } }},
        .ret_type = .{ .void_type = {} },
        .body = .{ .stmts = try listStmts(a, &.{
            .{ .expr_stmt = try boxed(a, ident("read")) },
        }) },
    } };
    const read_out = try emitFile(a, .{ .path = "src/consume.zig", .decls = &.{aware} });
    try std.testing.expect(std.mem.indexOf(u8, read_out, "(read: u8)") != null);
    // The body names it, so no discard: the two cases differ by the body, not
    // by the spelling of the name.
    try std.testing.expect(std.mem.indexOf(u8, read_out, "_ = read;") == null);

    // The `comptime T: type` parameter is exempt, because its references live in
    // the signature and a body-only scan would discard one the parameter list
    // still needs.
    const head = ast.Decl{ .fn_decl = .{
        .name = "head",
        .params = &.{
            .{ .name = "T", .ty = .{ .prim = .type_type }, .is_comptime = true },
            .{ .name = "bytes", .ty = .{ .slice = .{
                .elem = &ast.Type{ .named = "T" },
                .is_const = true,
            } } },
        },
        .ret_type = .{ .prim = .u8 },
        .body = .{ .stmts = try listStmts(a, &.{
            .{ .expr_stmt = try boxed(a, .{ .unit = {} }) },
        }) },
    } };
    const type_out = try emitFile(a, .{ .path = "src/head.zig", .decls = &.{head} });
    try std.testing.expect(
        std.mem.indexOf(u8, type_out, "(comptime T: type, bytes: []const T)") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, type_out, "_ = T;\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, type_out, "_ = bytes;\n") != null);
}
