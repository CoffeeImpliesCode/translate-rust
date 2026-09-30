const std = @import("std");
const error_1 = @import("../error.zig");
const r2z = @import("r2z");

test "test_display" {
    const allocator: std.mem.Allocator = std.testing.allocator;
    try std.testing.expect(__r2z_value_block_1: {
        var __r2z_compare: r2z.alloc.String = try r2z.format.toString(allocator, error_1.FromHexError{ .InvalidHexCharacter = .{ .c = '\n', .index = 5 } });
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare);
        const __r2z_compare_1 = "Invalid character '\\n' at position 5";
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare, __r2z_compare_1);
    });
    try std.testing.expect(__r2z_value_block_1: {
        var __r2z_compare_2: r2z.alloc.String = try r2z.format.toString(allocator, error_1.FromHexError{ .OddLength = @as(void, {}) });
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare_2);
        const __r2z_compare_3 = "Odd number of digits";
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare_2, __r2z_compare_3);
    });
    try std.testing.expect(__r2z_value_block_1: {
        var __r2z_compare_4: r2z.alloc.String = try r2z.format.toString(allocator, error_1.FromHexError{ .InvalidStringLength = @as(void, {}) });
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare_4);
        const __r2z_compare_5 = "Invalid string length";
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare_4, __r2z_compare_5);
    });
}

test "translated tests reachable through ../error.zig" {
    _ = error_1;
}
