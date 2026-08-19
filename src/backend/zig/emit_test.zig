//! translate_rust.backend.zig.emit_test — emitter tests.
//! Verifies `emitFile` produces clean, valid Zig 0.16 syntax for the full
//! range of ast.Decl / ast.Expr / ast.Type / ast.Stmt constructs.

const std = @import("std");
const ast = @import("ast.zig");
const emit = @import("emit.zig");

fn emitFile(a: std.mem.Allocator, file: ast.File) ![]const u8 {
    return emit.emitFile(a, &file);
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
