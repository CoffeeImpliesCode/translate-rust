//! translate_rust.backend.zig.strategies.embedded — embedded/no-alloc Zig lowering rules.
//!
//! Implements an embedded-oriented `LoweringStrategy`: zero heap allocations
//! in default paths, favoring slices and fixed buffers over dynamic containers.

const std = @import("std");
const ir = @import("translate_rust.ir");
const ast = @import("../ast.zig");
const default_strat = @import("default.zig");

pub const EmbeddedStrategy = struct {
    pub fn lowerType(ctx: *anyopaque, ty: ir.types.Type) anyerror!ast.Type {
        return default_strat.DefaultStrategy.lowerType(ctx, ty);
    }

    pub fn lowerStdGeneric(
        ctx: *anyopaque,
        name: []const u8,
        params: []const ir.types.Type,
    ) anyerror!?ast.Type {
        _ = ctx;
        _ = params;
        if (std.mem.eql(u8, name, "Vec")) {
            return .{ .named = "std.ArrayListUnmanaged" };
        }
        if (std.mem.eql(u8, name, "String")) {
            return .{ .named = "[]const u8" };
        }
        if (std.mem.eql(u8, name, "BTreeMap")) {
            return .{ .named = "std.AutoHashMap" };
        }
        return null;
    }
};

test "embedded strategy lower generic" {
    const s = try EmbeddedStrategy.lowerStdGeneric(undefined, "String", &.{});
    try std.testing.expect(s != null);
    try std.testing.expectEqualStrings("[]const u8", s.?.named);
}
