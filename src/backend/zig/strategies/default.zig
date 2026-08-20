//! translate_rust.backend.zig.strategies.default — standard Zig lowering rules.
//!
//! Implements the default `LoweringStrategy`: faithful primitive/slice/option
//! mapping, error unions for unionable `Result`, and standard Rust collection
//! mapping (`HashMap` → `std.AutoHashMap`, `Vec` → `std.ArrayListUnmanaged`, ...).
//! Generics lower via comptime duck typing (bounds erased at emit).
//!
//! Boxed types owned by a returned `ast.Type` (`.opt`, `.err_union`,
//! `.ptr`/`.slice` element, `.array`) come from a thread-local cell pool. Tuple
//! element slices use fixed backing storage owned by the `DefaultStrategy`
//! instance passed through the opaque context. A pointer returned by one
//! lowering call stays valid until the next lowering call on the same owner —
//! sufficient for the single-call lowering pattern the engine uses.

const ir = @import("translate_rust.ir");
const ast = @import("../ast.zig");

const BoxCells = struct {
    cells: [32]ast.Type = undefined,
    next: usize = 0,
};
threadlocal var box_cells: BoxCells = .{};

/// The default lowering strategy. The caller owns each strategy instance and
/// passes its address through the opaque context for tuple lowering.
pub const DefaultStrategy = struct {
    tuple_cells: [32][16]ast.Type = undefined,
    next_tuple_cell: usize = 0,
    pub fn lowerType(ctx: *anyopaque, ty: ir.types.Type) anyerror!ast.Type {
        return switch (ty) {
            .prim => |p| ast.Type{ .prim = primToAst(p) },
            .path => |p| lowerPath(p),
            .reference => |r| makePtr(!r.mut, .one, try lowerTypeImpl(ctx, r.pointee)),
            .raw_ptr => |r| makePtr(!r.mut, .many, try lowerTypeImpl(ctx, r.pointee)),
            .slice => |s| makeSlice(s.const_, try lowerTypeImpl(ctx, s.elem)),
            .array => |a| ast.Type{
                .array = ast.Array{
                    .elem = box(try lowerTypeImpl(ctx, a.elem)),
                    .len = switch (a.len) {
                        .literal => |n| n,
                        .generic => 0,
                    },
                },
            },
            .tuple => |elems| blk: {
                const self: *DefaultStrategy = @ptrCast(@alignCast(ctx));
                break :blk ast.Type{ .tuple = try lowerTuple(self, ctx, elems) };
            },
            .fn_ptr => ast.Type{ .named = "fnptr" },
            .generic_inst => |gi| blk: {
                const maybe = try lowerStdGeneric(ctx, "", gi.args.params);
                break :blk maybe orelse ast.Type.any_opaque;
            },
            .option => |inner| ast.Type{ .opt = box(try lowerTypeImpl(ctx, inner.*)) },
            .result => |r| resultToAst(ctx, r.*),
            .boxed => |inner| ast.Type{ .opt = box(try lowerTypeImpl(ctx, inner.*)) },
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
            return .{ .named = "std.ArrayListUnmanaged" };
        }
        if (std.mem.eql(u8, name, "BuildHasherDefault")) {
            return .{ .named = "std.hash.BuildHasherDefault" };
        }
        if (std.mem.eql(u8, name, "HashMap") or
            std.mem.eql(u8, name, "HashSet") or
            std.mem.eql(u8, name, "BTreeMap"))
        {
            return .{ .named = "std.AutoHashMap" };
        }
        return null;
    }

    fn lowerTypeImpl(ctx: *anyopaque, ty: ir.types.Type) anyerror!ast.Type {
        return DefaultStrategy.lowerType(ctx, ty);
    }

    fn box(ty: ast.Type) *const ast.Type {
        const idx = box_cells.next % box_cells.cells.len;
        box_cells.next += 1;
        box_cells.cells[idx] = ty;
        return &box_cells.cells[idx];
    }

    fn makePtr(is_const: bool, size: ast.PtrSize, elem: ast.Type) ast.Type {
        return .{ .ptr = .{
            .elem = box(elem),
            .is_const = is_const,
            .size = size,
        } };
    }

    fn makeSlice(is_const: bool, elem: ast.Type) ast.Type {
        return .{ .slice = .{
            .elem = box(elem),
            .is_const = is_const,
        } };
    }

    fn lowerTuple(
        self: *DefaultStrategy,
        ctx: *anyopaque,
        elems: []const ir.types.Type,
    ) anyerror![]const ast.Type {
        const cell_index = self.next_tuple_cell % self.tuple_cells.len;
        self.next_tuple_cell += 1;
        const cell = &self.tuple_cells[cell_index];
        const n = @min(elems.len, cell.len);
        for (elems[0..n], 0..) |e, i| {
            cell[i] = try lowerTypeImpl(ctx, e);
        }
        return cell[0..n];
    }

    fn resultToAst(ctx: *anyopaque, r: ir.types.Result) anyerror!ast.Type {
        const err_unionable = switch (r.err) {
            .prim => |p| p == .unit,
            else => false,
        };
        if (err_unionable) {
            return .{ .err_union = .{
                .payload = box(try lowerTypeImpl(ctx, r.ok)),
            } };
        }
        return ast.Type.any_opaque;
    }

    fn lowerPath(p: ir.types.Path) anyerror!ast.Type {
        if (p.segments.len == 0) return error.EmptyPath;
        return .{ .named = p.segments[p.segments.len - 1].name };
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

test "default: lower short and long tuples into caller storage" {
    var strategy: DefaultStrategy = .{};

    const short = try DefaultStrategy.lowerType(&strategy, ir.types.Type{
        .tuple = &.{
            .{ .prim = .u8 },
            .{ .prim = .i16 },
        },
    });
    try std.testing.expectEqual(@as(usize, 2), short.tuple.len);
    try std.testing.expectEqual(ast.Prim.u8, short.tuple[0].prim);
    try std.testing.expectEqual(ast.Prim.i16, short.tuple[1].prim);

    const long_elements = [_]ir.types.Type{
        .{ .prim = .u8 },
        .{ .prim = .u16 },
        .{ .prim = .u32 },
        .{ .prim = .u64 },
        .{ .prim = .i8 },
        .{ .prim = .i16 },
        .{ .prim = .i32 },
        .{ .prim = .i64 },
        .{ .prim = .f32 },
        .{ .prim = .f64 },
        .{ .prim = .bool },
        .{ .prim = .char },
        .{ .prim = .isize },
        .{ .prim = .usize },
        .{ .prim = .unit },
        .{ .prim = .never },
    };
    const long = try DefaultStrategy.lowerType(
        &strategy,
        ir.types.Type{ .tuple = &long_elements },
    );
    const expected = [_]ast.Prim{
        .u8,  .u16, .u32,  .u64, .i8,    .i16,   .i32,       .i64,
        .f32, .f64, .bool, .u21, .isize, .usize, .void_type, .noreturn_type,
    };
    try std.testing.expectEqual(@as(usize, expected.len), long.tuple.len);
    for (expected, 0..) |expected_prim, index| {
        try std.testing.expectEqual(expected_prim, long.tuple[index].prim);
    }
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
