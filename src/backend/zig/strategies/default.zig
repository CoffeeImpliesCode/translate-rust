//! translate_rust.backend.zig.strategies.default — standard Zig lowering rules.
//!
//! Implements the default `LoweringStrategy`: faithful primitive/slice/option
//! mapping, error unions for unionable `Result`, and standard Rust collection
//! mapping (`HashMap` → `std.AutoHashMap`, `Vec` → `std.ArrayListUnmanaged`, ...).
//! Generics lower via comptime duck typing (bounds erased at emit).
//!
//! The strategy is stateless: boxed types owned by a returned `ast.Type`
//! (`.opt`, `.err_union`, `.ptr`/`.slice` element, `.array`) come from a
//! thread-local cell pool. A pointer returned by one lowering call stays valid
//! until the next lowering call on the same thread — sufficient for the
//! single-call lowering pattern the engine uses.

const ir = @import("translate_rust.ir");
const ast = @import("../ast.zig");

const BoxCells = struct {
    cells: [32]ast.Type = undefined,
    next: usize = 0,
};
threadlocal var box_cells: BoxCells = .{};

/// The default lowering strategy. Stateless: every method is a pure function
/// of its inputs, so the opaque context pointer is unused.
pub const DefaultStrategy = struct {
    pub fn lowerType(ctx: *anyopaque, ty: ir.types.Type) anyerror!ast.Type {
        return switch (ty) {
            .prim => |p| ast.Type{ .prim = primToAst(p) },
            .path => |p| lowerPath(p),
            .reference => |r| makePtr(!r.mut, .one, try lowerTypeImpl(r.pointee)),
            .raw_ptr => |r| makePtr(!r.mut, .many, try lowerTypeImpl(r.pointee)),
            .slice => |s| makeSlice(s.const_, try lowerTypeImpl(s.elem)),
            .array => |a| ast.Type{
                .array = ast.Array{
                    .elem = box(try lowerTypeImpl(a.elem)),
                    .len = switch (a.len) {
                        .literal => |n| n,
                        .generic => 0,
                    },
                },
            },
            .tuple => |elems| ast.Type{ .tuple = try lowerTuple(elems) },
            .fn_ptr => ast.Type{ .named = "fnptr" },
            .generic_inst => |gi| blk: {
                const maybe = try lowerStdGeneric(ctx, "", gi.args.params);
                break :blk maybe orelse ast.Type.any_opaque;
            },
            .option => |inner| ast.Type{ .opt = box(try lowerTypeImpl(inner.*)) },
            .result => |r| resultToAst(r.*),
            .boxed => |inner| ast.Type{ .opt = box(try lowerTypeImpl(inner.*)) },
            .unsupported => ast.Type.any_opaque,
        };
    }

    pub fn lowerStdGeneric(
        ctx: *anyopaque,
        name: []const u8,
        params: []const ir.types.Type,
    ) anyerror!?ast.Type {
        _ = ctx;
        _ = params;
        if (std.mem.eql(u8, name, "Vec") or std.mem.eql(u8, name, "String")) {
            return ast.Type{ .named = "std.ArrayListUnmanaged" };
        }
        if (std.mem.eql(u8, name, "BuildHasherDefault")) {
            return ast.Type{ .named = "std.hash.BuildHasherDefault" };
        }
        if (std.mem.eql(u8, name, "HashMap") or
            std.mem.eql(u8, name, "HashSet") or
            std.mem.eql(u8, name, "BTreeMap"))
        {
            return ast.Type{ .named = "std.AutoHashMap" };
        }
        return null;
    }

    fn lowerTypeImpl(ty: ir.types.Type) anyerror!ast.Type {
        return DefaultStrategy.lowerType(undefined, ty);
    }

    fn box(ty: ast.Type) *const ast.Type {
        const idx = box_cells.next % box_cells.cells.len;
        box_cells.next += 1;
        box_cells.cells[idx] = ty;
        return &box_cells.cells[idx];
    }

    fn makePtr(is_const: bool, size: ast.PtrSize, elem: ast.Type) ast.Type {
        return ast.Type{ .ptr = .{
            .elem = box(elem),
            .is_const = is_const,
            .size = size,
        } };
    }

    fn makeSlice(is_const: bool, elem: ast.Type) ast.Type {
        return ast.Type{ .slice = .{
            .elem = box(elem),
            .is_const = is_const,
        } };
    }

    fn lowerTuple(elems: []const ir.types.Type) anyerror![]const ast.Type {
        var buf: [16]ast.Type = undefined;
        const n = @min(elems.len, buf.len);
        for (elems[0..n], 0..) |e, i| {
            buf[i] = try lowerTypeImpl(e);
        }
        return buf[0..n];
    }

    fn resultToAst(r: ir.types.Result) anyerror!ast.Type {
        const err_unionable = switch (r.err) {
            .prim => |p| p == .unit,
            else => false,
        };
        if (err_unionable) {
            return ast.Type{ .err_union = .{
                .payload = box(try lowerTypeImpl(r.ok)),
            } };
        }
        return ast.Type.any_opaque;
    }

    fn lowerPath(p: ir.types.Path) anyerror!ast.Type {
        if (p.segments.len == 0) return error.EmptyPath;
        return ast.Type{ .named = p.segments[p.segments.len - 1].name };
    }

    fn primToAst(p: ir.types.Prim) ast.Prim {
        return switch (p) {
            .i8 => .i8,
            .i16 => .i16,
            .i32 => .i32,
            .i64 => .i64,
            .i128 => .i128,
            .u8 => .u8,
            .u16 => .u16,
            .u32 => .u32,
            .u64 => .u64,
            .u128 => .u128,
            .isize => .isize,
            .usize => .usize,
            .f32 => .f32,
            .f64 => .f64,
            .bool => .bool,
            .char => .u21,
            .unit => .void_type,
            .never => .noreturn_type,
        };
    }
};

test "default: lower primitives, slices, options, results" {
    const u32_ty = try DefaultStrategy.lowerType(undefined, ir.types.Type{ .prim = .u32 });
    try std.testing.expectEqual(ast.Prim.u32, u32_ty.prim);

    const slice_ty = try DefaultStrategy.lowerType(undefined, ir.types.Type{
        .slice = &.{
            .const_ = true,
            .elem = ir.types.Type{ .prim = .u8 },
        },
    });
    try std.testing.expectEqual(ast.Prim.u8, slice_ty.slice.elem.*.prim);
    try std.testing.expect(slice_ty.slice.is_const);

    const opt_ty = try DefaultStrategy.lowerType(undefined, ir.types.Type{
        .option = &ir.types.Type{ .prim = .f64 },
    });
    try std.testing.expectEqual(ast.Prim.f64, opt_ty.opt.*.prim);

    const res_ty = try DefaultStrategy.lowerType(undefined, ir.types.Type{
        .result = &.{
            .ok = ir.types.Type{ .prim = .u8 },
            .err = ir.types.Type{ .prim = .unit },
            .is_error_unionable = true,
        },
    });
    try std.testing.expectEqual(ast.Prim.u8, res_ty.err_union.payload.*.prim);

    const named_ty = try DefaultStrategy.lowerType(undefined, ir.types.Type{
        .path = .{ .segments = &.{
            .{ .name = "core", .id = null },
            .{ .name = "Result", .id = null },
        } },
    });
    try std.testing.expectEqualStrings("Result", named_ty.named);
}

test "default: standard generic mapping" {
    const generic = try DefaultStrategy.lowerStdGeneric(
        undefined,
        "HashSet",
        &.{ ir.types.Type{ .prim = .u64 }, ir.types.Type{ .prim = .f32 } },
    );
    try std.testing.expect(generic != null);
    try std.testing.expectEqualStrings("std.AutoHashMap", generic.?.named);

    const vec = try DefaultStrategy.lowerStdGeneric(
        undefined,
        "Vec",
        &.{ir.types.Type{ .prim = .u8 }},
    );
    try std.testing.expect(vec != null);
    try std.testing.expectEqualStrings("std.ArrayListUnmanaged", vec.?.named);

    const unknown = try DefaultStrategy.lowerStdGeneric(undefined, "NoSuchType", &.{});
    try std.testing.expect(unknown == null);
}

const std = @import("std");
