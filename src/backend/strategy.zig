//! translate_rust.backend.strategy — pluggable lowering strategies for the Zig backend.
//!
//! A `LoweringStrategy` provides target decision hooks: how to lower arbitrary
//! IR types and how to map standard Rust generic instantiations. Strategies are
//! dynamic (opaque context + vtable) so the lowering engine never depends on a
//! concrete strategy.

const ir = @import("translate_rust.ir");
const ast = @import("zig/ast.zig");

/// A pluggable lowering strategy. The opaque `ptr` is the strategy's own state;
/// all strategy-specific work goes through `vtable.` Dispatch helpers below
/// make calls ergonomic and valid even when `ptr` is null (strategy omitted).
pub const LoweringStrategy = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Lower an arbitrary IR type to a Zig AST type. Fails when the IR type
        /// has no faithful target-language representation in this strategy.
        lowerType: *const fn (ctx: *anyopaque, ty: ir.types.Type) anyerror!ast.Type,

        /// Try to lower a standard Rust generic instantiation (`HashMap`, `Vec`,
        /// ...). Returns null when this strategy does not own the given name.
        lowerStdGeneric: *const fn (
            ctx: *anyopaque,
            name: []const u8,
            params: []const ir.types.Type,
        ) anyerror!?ast.Type,
    };

    /// Dispatch to `vtable.lowerType`.
    pub fn lowerType(self: LoweringStrategy, ty: ir.types.Type) anyerror!ast.Type {
        return self.vtable.lowerType(self.ptr, ty);
    }

    /// Dispatch to `vtable.lowerStdGeneric`.
    pub fn lowerStdGeneric(
        self: LoweringStrategy,
        name: []const u8,
        params: []const ir.types.Type,
    ) anyerror!?ast.Type {
        return self.vtable.lowerStdGeneric(self.ptr, name, params);
    }
};

const MockStrategy = struct {
    const Self = MockStrategy;
    lower_type_calls: usize = 0,
    lower_std_calls: usize = 0,

    fn lowerType(ctx: *anyopaque, ty: ir.types.Type) anyerror!ast.Type {
        _ = ty;
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.lower_type_calls += 1;
        return ast.Type{ .void_type = {} };
    }

    fn lowerStdGeneric(
        ctx: *anyopaque,
        name: []const u8,
        params: []const ir.types.Type,
    ) anyerror!?ast.Type {
        _ = params;
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.lower_std_calls += 1;
        if (std.mem.eql(u8, name, "Vec")) {
            return ast.Type{ .named = "std.ArrayListUnmanaged" };
        }
        return null;
    }
};

const std = @import("std");

test "strategy: virtual dispatch through vtable" {
    var mock = MockStrategy{};
    var strat = LoweringStrategy{
        .ptr = &mock,
        .vtable = &.{
            .lowerType = MockStrategy.lowerType,
            .lowerStdGeneric = MockStrategy.lowerStdGeneric,
        },
    };

    const lowered = try strat.lowerType(ir.types.Type{ .prim = .u32 });
    try std.testing.expectEqual(ast.Type.void_type, lowered);

    const maybe_vec = try strat.lowerStdGeneric(
        "Vec",
        &.{ir.types.Type{ .prim = .f64 }},
    );
    try std.testing.expect(maybe_vec != null);
    try std.testing.expectEqualStrings("std.ArrayListUnmanaged", maybe_vec.?.named);

    const maybe_unknown = try strat.lowerStdGeneric(
        "Unknown",
        &.{},
    );
    try std.testing.expect(maybe_unknown == null);

    try std.testing.expectEqual(@as(usize, 2), mock.lower_std_calls);
    try std.testing.expectEqual(@as(usize, 1), mock.lower_type_calls);
}
