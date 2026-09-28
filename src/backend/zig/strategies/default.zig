//! translate_rust.backend.zig.strategies.default — standard Zig lowering rules.
//!
//! Implements the default `LoweringStrategy`: faithful primitive/slice/option
//! mapping, error unions for unionable `Result`, and selected standard Rust
//! collection mapping (`BTreeMap` → `std.AutoHashMap`, `Vec` →
//! `std.ArrayListUnmanaged`, `HashMap`/`HashSet` → the r2z `collections`
//! containers, ...).
//! Generics lower via comptime duck typing (bounds erased at emit).
//!
//! Boxed types owned by a returned `ast.Type` (`.opt`, `.err_union`,
//! `.ptr`/`.slice` element, `.array`) come from a thread-local cell pool. Tuple
//! elements and function parameters use fixed backing storage owned by the `DefaultStrategy`
//! instance passed through the opaque context. A pointer returned by one
//! lowering call stays valid until the next lowering call on the same owner —
//! sufficient for the single-call lowering pattern the engine uses.

const std = @import("std");
const ir = @import("translate_rust.ir");
const ast = @import("../ast.zig");

const BoxCells = struct {
    cells: [32]ast.Type = undefined,
    next: usize = 0,
};
threadlocal var box_cells: BoxCells = .{};

/// The default lowering strategy. The caller owns each strategy instance and
/// passes its address through the opaque context for tuple and function types.
pub const DefaultStrategy = struct {
    tuple_cells: [32][16]ast.Type = undefined,
    next_tuple_cell: usize = 0,
    generic_cells: [8][4]ast.Type = undefined,
    next_generic_cell: usize = 0,
    pub fn lowerType(ctx: *anyopaque, ty: ir.types.Type) anyerror!ast.Type {
        return switch (ty) {
            .prim => |p| ast.Type{ .prim = primToAst(p) },
            .path => |p| lowerPath(p),
            .external_nominal => |external| try lowerExternal(ctx, external),
            .reference => |r| makePtr(!r.mut, .one, try lowerTypeImpl(ctx, r.pointee)),
            .raw_ptr => |r| makePtr(!r.mut, .many, try lowerTypeImpl(ctx, r.pointee)),
            .slice => |s| makeSlice(s.const_, try lowerTypeImpl(ctx, s.elem)),
            .array => |a| ast.Type{
                .array = ast.Array{
                    .elem = box(try lowerTypeImpl(ctx, a.elem)),
                    .len = switch (a.len) {
                        .literal => |n| n,
                        .generic, .expression => return error.TypeRequiresExpressionContext,
                    },
                },
            },
            .tuple => |elems| blk: {
                const self: *DefaultStrategy = @ptrCast(@alignCast(ctx));
                break :blk ast.Type{ .tuple = try lowerTuple(self, ctx, elems) };
            },
            .fn_ptr => |function| blk: {
                const self: *DefaultStrategy = @ptrCast(@alignCast(ctx));
                break :blk .{ .fn_ptr = .{
                    .params = try lowerTuple(self, ctx, function.params),
                    .ret = box(try lowerTypeImpl(ctx, function.ret)),
                } };
            },
            .generic_inst => |gi| blk: {
                const maybe = try lowerStdGeneric(ctx, "", gi.args.params);
                break :blk maybe orelse ast.Type.any_opaque;
            },
            .option => |inner| ast.Type{ .opt = box(try lowerTypeImpl(ctx, inner.*)) },
            .result => |r| resultToAst(ctx, r.*),
            .boxed => |inner| ast.Type{ .opt = box(try lowerTypeImpl(ctx, inner.*)) },
            .@"opaque" => |opaque_type| try lowerTypeImpl(ctx, (opaque_type.concrete orelse return error.UnresolvedOpaqueType).*),
            .dyn_trait => return error.UnsupportedDynamicTrait,
            .unsupported => ast.Type.any_opaque,
        };
    }
    fn externalPathEqual(path: []const []const u8, expected: []const []const u8) bool {
        if (path.len != expected.len) return false;
        for (path, expected) |actual, wanted| {
            if (!std.mem.eql(u8, actual, wanted)) return false;
        }
        return true;
    }

    /// `core::collections`, `std::collections`, or `alloc::collections`.
    fn isCollectionsPath(path: []const []const u8) bool {
        if (path.len != 3) return false;
        if (!std.mem.eql(u8, path[0], "core") and
            !std.mem.eql(u8, path[0], "std") and
            !std.mem.eql(u8, path[0], "alloc")) return false;
        return std.mem.eql(u8, path[1], "collections");
    }

    fn isCollectionsMapPath(path: []const []const u8) bool {
        return isCollectionsPath(path) and std.mem.eql(u8, path[2], "HashMap");
    }

    fn isCollectionsSetPath(path: []const []const u8) bool {
        return isCollectionsPath(path) and std.mem.eql(u8, path[2], "HashSet");
    }

    fn lowerExternal(ctx: *anyopaque, external: ir.types.ExternalNominal) anyerror!ast.Type {
        if (externalPathEqual(external.path, &.{ "core", "option", "Option" }) or
            externalPathEqual(external.path, &.{ "std", "option", "Option" }))
        {
            if (external.args.len != 1) return error.GenericArgumentArityMismatch;
            return .{ .opt = box(try lowerTypeImpl(ctx, external.args[0])) };
        }
        if (externalPathEqual(external.path, &.{ "core", "result", "Result" }) or
            externalPathEqual(external.path, &.{ "std", "result", "Result" }))
        {
            if (external.args.len != 2) return error.GenericArgumentArityMismatch;
            return resultToAst(ctx, .{
                .ok = external.args[0],
                .err = external.args[1],
                .is_error_unionable = false,
            });
        }
        if (externalPathEqual(external.path, &.{ "std", "string", "String" })) {
            if (external.args.len != 0) return error.GenericArgumentArityMismatch;
            return .{ .named = "[]const u8" };
        }
        if (isCollectionsMapPath(external.path)) {
            if (external.args.len != 3) return error.GenericArgumentArityMismatch;
            const self: *DefaultStrategy = @ptrCast(@alignCast(ctx));
            return self.lowerExternalGeneric(ctx, "r2z.collections.HashMap", external.args);
        }
        if (isCollectionsSetPath(external.path)) {
            if (external.args.len != 2) return error.GenericArgumentArityMismatch;
            const self: *DefaultStrategy = @ptrCast(@alignCast(ctx));
            return self.lowerExternalGeneric(ctx, "r2z.collections.HashSet", external.args);
        }
        return error.UnsupportedExternalNominalType;
    }

    pub fn lowerStdGeneric(
        ctx: *anyopaque,
        name: []const u8,
        params: []const ir.types.Type,
    ) anyerror!?ast.Type {
        _ = ctx;
        if (std.mem.eql(u8, name, "Vec") or std.mem.eql(u8, name, "String")) {
            return .{ .named = "std.ArrayListUnmanaged" };
        }
        if (std.mem.eql(u8, name, "BTreeMap")) {
            return .{ .named = "std.AutoHashMap" };
        }
        // `HashMap`/`HashSet` name a *builder* as their last parameter, so
        // they cannot become `std.AutoHashMap`: that would substitute Wyhash
        // for whatever the Rust source asked for — for the `fnv` crate, the
        // single reason it exists. The r2z containers keep the builder and
        // build a `std.hash_map` context from it. The arity is part of the
        // name: a two-parameter `HashMap<K, V>` means Rust's randomly seeded
        // `RandomState`, which has no static Zig equivalent, so only the
        // spelled-out three-parameter form maps.
        if (std.mem.eql(u8, name, "HashMap") and params.len == 3) {
            return .{ .named = "r2z.collections.HashMap" };
        }
        if (std.mem.eql(u8, name, "HashSet") and params.len == 2) {
            return .{ .named = "r2z.collections.HashSet" };
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

    /// Lower generic arguments into caller-owned storage, mirroring
    /// `lowerTuple`: a pointer into `self` outlives the next call on the same
    /// owner, which is what the single-call lowering pattern needs.
    fn lowerExternalGeneric(
        self: *DefaultStrategy,
        ctx: *anyopaque,
        name: []const u8,
        args: []const ir.types.Type,
    ) anyerror!ast.Type {
        const cell_index = self.next_generic_cell % self.generic_cells.len;
        self.next_generic_cell += 1;
        const cell = &self.generic_cells[cell_index];
        const n = @min(args.len, cell.len);
        for (args[0..n], 0..) |arg, i| cell[i] = try lowerTypeImpl(ctx, arg);
        return .{ .generic = .{ .name = name, .params = cell[0..n] } };
    }

    fn resultToAst(ctx: *anyopaque, r: ir.types.Result) anyerror!ast.Type {
        if (r.is_error_unionable) {
            return .{ .err_union = .{
                .payload = box(try lowerTypeImpl(ctx, r.ok)),
            } };
        }
        const self: *DefaultStrategy = @ptrCast(@alignCast(ctx));
        return .{ .generic = .{
            .name = "r2z.Result",
            .params = try self.lowerTuple(ctx, &.{ r.ok, r.err }),
        } };
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
    // `HashMap`/`HashSet` used to be asserted `null` here: r2z-core had no
    // container at all. They now map to the r2z `collections` types, which
    // keep the Rust `BuildHasher` the source named. `std.AutoHashMap` is
    // deliberately NOT the answer — it would swap the crate's hasher for
    // Wyhash, which is the one thing the `fnv` crate exists to prevent.
    const hash_set = try DefaultStrategy.lowerStdGeneric(
        undefined,
        "HashSet",
        &.{ ir.types.Type{ .prim = .u64 }, ir.types.Type{ .prim = .f32 } },
    );
    try std.testing.expect(hash_set != null);
    try std.testing.expectEqualStrings("r2z.collections.HashSet", hash_set.?.named);

    const hash_map = try DefaultStrategy.lowerStdGeneric(
        undefined,
        "HashMap",
        &.{
            ir.types.Type{ .prim = .u64 },
            ir.types.Type{ .prim = .f32 },
            ir.types.Type{ .prim = .usize },
        },
    );
    try std.testing.expect(hash_map != null);
    try std.testing.expectEqualStrings("r2z.collections.HashMap", hash_map.?.named);

    // A two-parameter `HashMap<K, V>` is Rust's randomly seeded
    // `RandomState`. It has no static Zig equivalent, so the name mapping
    // must not claim it.
    const unseeded_map = try DefaultStrategy.lowerStdGeneric(
        undefined,
        "HashMap",
        &.{ ir.types.Type{ .prim = .u64 }, ir.types.Type{ .prim = .f32 } },
    );
    try std.testing.expect(unseeded_map == null);

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

test "default: external nominal mapping is explicit and fail-loud" {
    var strategy: DefaultStrategy = .{};
    const option = try DefaultStrategy.lowerType(&strategy, .{
        .external_nominal = .{
            .path = &.{ "core", "option", "Option" },
            .args = &.{.{ .prim = .u8 }},
        },
    });
    try std.testing.expectEqual(ast.Prim.u8, option.opt.*.prim);

    try std.testing.expectError(
        error.UnsupportedExternalNominalType,
        DefaultStrategy.lowerType(&strategy, .{
            .external_nominal = .{
                .path = &.{ "alloc", "collections", "VecDeque" },
                .args = &.{.{ .prim = .u8 }},
            },
        }),
    );
}

test "default: collections external nominals keep the source's BuildHasher" {
    var strategy: DefaultStrategy = .{};

    const map = try DefaultStrategy.lowerType(&strategy, .{
        .external_nominal = .{
            .path = &.{ "std", "collections", "HashMap" },
            .args = &.{
                .{ .prim = .u64 },
                .{ .prim = .f32 },
                .{ .prim = .usize },
            },
        },
    });
    try std.testing.expectEqualStrings("r2z.collections.HashMap", map.generic.name);
    try std.testing.expectEqual(@as(usize, 3), map.generic.params.len);
    try std.testing.expectEqual(ast.Prim.u64, map.generic.params[0].prim);
    try std.testing.expectEqual(ast.Prim.f32, map.generic.params[1].prim);
    try std.testing.expectEqual(ast.Prim.usize, map.generic.params[2].prim);

    const set = try DefaultStrategy.lowerType(&strategy, .{
        .external_nominal = .{
            .path = &.{ "core", "collections", "HashSet" },
            .args = &.{ .{ .prim = .u64 }, .{ .prim = .usize } },
        },
    });
    try std.testing.expectEqualStrings("r2z.collections.HashSet", set.generic.name);
    try std.testing.expectEqual(@as(usize, 2), set.generic.params.len);

    // `alloc::collections` is the same Rust type by another path.
    const from_alloc = try DefaultStrategy.lowerType(&strategy, .{
        .external_nominal = .{
            .path = &.{ "alloc", "collections", "HashMap" },
            .args = &.{ .{ .prim = .u64 }, .{ .prim = .f32 }, .{ .prim = .usize } },
        },
    });
    try std.testing.expectEqualStrings("r2z.collections.HashMap", from_alloc.generic.name);

    // Dropping the builder parameter must not silently invent one.
    try std.testing.expectError(
        error.GenericArgumentArityMismatch,
        DefaultStrategy.lowerType(&strategy, .{
            .external_nominal = .{
                .path = &.{ "std", "collections", "HashMap" },
                .args = &.{ .{ .prim = .u64 }, .{ .prim = .f32 } },
            },
        }),
    );
}
