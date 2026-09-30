const std = @import("std");
const root = @import("./root.zig");
const error_1 = @import("./error.zig");
const r2z = @import("r2z");

test "test_gen_iter" {
    const allocator: std.mem.Allocator = std.testing.allocator;
    const result_1: std.ArrayListUnmanaged(struct { usize, usize }) = __r2z_vec_value: {
        var __r2z_vec: std.ArrayListUnmanaged(struct { usize, usize }) = std.ArrayListUnmanaged(struct { usize, usize }).empty;
        errdefer __r2z_vec.deinit(allocator);
        try __r2z_vec.append(allocator, .{ 0, 1 });
        try __r2z_vec.append(allocator, .{ 2, 3 });
        break :__r2z_vec_value __r2z_vec;
    };
    try std.testing.expect(__r2z_value_block_1: {
        var __r2z_compare: std.ArrayListUnmanaged(struct { usize, usize }) = try r2z.alloc.vec_collect(struct { usize, usize }, allocator, root.generate_iter(5));
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare);
        const __r2z_compare_1 = &result_1;
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare, __r2z_compare_1.*);
    });
    {
        var __r2z_release = result_1;
        defer __r2z_release.deinit(allocator);
    }
}

test "test_encode_to_slice" {
    const allocator: std.mem.Allocator = std.testing.allocator;
    var output_1: [8]u8 = [_]u8{ 0 } ** 8;
    root.encode_to_slice(*const [4]u8, "kiwi", &output_1).unwrap(allocator);
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, &output_1, "6b697769"));
    var output_2: [10]u8 = [_]u8{ 0 } ** 10;
    root.encode_to_slice(*const [5]u8, "kiwis", &output_2).unwrap(allocator);
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, &output_2, "6b69776973"));
    var output_3: [100]u8 = [_]u8{ 0 } ** 100;
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, root.encode_to_slice(*const [5]u8, "kiwis", &output_3), r2z.Result(void, error_1.FromHexError){ .Err = error_1.FromHexError{ .InvalidStringLength = @as(void, {}) } }));
}

test "test_decode_to_slice" {
    const allocator: std.mem.Allocator = std.testing.allocator;
    var output_1: [4]u8 = [_]u8{ 0 } ** 4;
    root.decode_to_slice(*const [8]u8, "6b697769", &output_1).unwrap(allocator);
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, &output_1, "kiwi"));
    var output_2: [5]u8 = [_]u8{ 0 } ** 5;
    root.decode_to_slice(*const [10]u8, "6b69776973", &output_2).unwrap(allocator);
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, &output_2, "kiwis"));
    var output_3: [4]u8 = [_]u8{ 0 } ** 4;
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, root.decode_to_slice(*const [1]u8, "6", &output_3), r2z.Result(void, error_1.FromHexError){ .Err = error_1.FromHexError{ .OddLength = @as(void, {}) } }));
}

test "test_encode" {
    const allocator: std.mem.Allocator = std.testing.allocator;
    try std.testing.expect(__r2z_value_block_1: {
        var __r2z_compare: r2z.alloc.String = try root.encode([]const u8, allocator, "foobar");
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare);
        const __r2z_compare_1 = "666f6f626172";
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare, __r2z_compare_1);
    });
}

test "test_decode" {
    const allocator: std.mem.Allocator = std.testing.allocator;
    try std.testing.expect(__r2z_value_block_1: {
        var __r2z_compare: r2z.Result(std.ArrayListUnmanaged(u8), error_1.FromHexError) = try root.decode([]const u8, allocator, "666f6f626172");
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare);
        var __r2z_compare_1: r2z.Result(std.ArrayListUnmanaged(u8), error_1.FromHexError) = r2z.Result(std.ArrayListUnmanaged(u8), error_1.FromHexError){ .Ok = __r2z_value_block_2: {
            var __r2z_string_receiver: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "foobar");
            defer __r2z_string_receiver.deinit(allocator);
            break :__r2z_value_block_2 __r2z_string_receiver.into_bytes();
        } };
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare_1);
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare, __r2z_compare_1);
    });
}

test "test_from_hex_okay_str" {
    const allocator: std.mem.Allocator = std.testing.allocator;
    try std.testing.expect(__r2z_value_block_1: {
        var __r2z_compare: std.ArrayListUnmanaged(u8) = (try root.from_hex([]const u8, allocator, "666f6f626172")).unwrap(allocator);
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare);
        const __r2z_compare_1 = "foobar";
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare, __r2z_compare_1);
    });
    try std.testing.expect(__r2z_value_block_1: {
        var __r2z_compare_2: std.ArrayListUnmanaged(u8) = (try root.from_hex([]const u8, allocator, "666F6F626172")).unwrap(allocator);
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare_2);
        const __r2z_compare_3 = "foobar";
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare_2, __r2z_compare_3);
    });
}

test "test_from_hex_okay_bytes" {
    const allocator: std.mem.Allocator = std.testing.allocator;
    try std.testing.expect(__r2z_value_block_1: {
        var __r2z_compare: std.ArrayListUnmanaged(u8) = (try root.from_hex(*const [12]u8, allocator, "666f6f626172")).unwrap(allocator);
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare);
        const __r2z_compare_1 = "foobar";
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare, __r2z_compare_1);
    });
    try std.testing.expect(__r2z_value_block_1: {
        var __r2z_compare_2: std.ArrayListUnmanaged(u8) = (try root.from_hex(*const [12]u8, allocator, "666F6F626172")).unwrap(allocator);
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare_2);
        const __r2z_compare_3 = "foobar";
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare_2, __r2z_compare_3);
    });
}

test "test_invalid_length" {
    const allocator: std.mem.Allocator = std.testing.allocator;
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, (try root.from_hex([]const u8, allocator, "1")).unwrap_err(), error_1.FromHexError{ .OddLength = @as(void, {}) }));
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, (try root.from_hex([]const u8, allocator, "666f6f6261721")).unwrap_err(), error_1.FromHexError{ .OddLength = @as(void, {}) }));
}

test "test_invalid_char" {
    const allocator: std.mem.Allocator = std.testing.allocator;
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, (try root.from_hex([]const u8, allocator, "66ag")).unwrap_err(), error_1.FromHexError{ .InvalidHexCharacter = .{ .c = 'g', .index = 3 } }));
}

test "test_empty" {
    const allocator: std.mem.Allocator = std.testing.allocator;
    try std.testing.expect(__r2z_value_block_1: {
        var __r2z_compare: std.ArrayListUnmanaged(u8) = (try root.from_hex([]const u8, allocator, "")).unwrap(allocator);
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare);
        const __r2z_compare_1 = "";
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare, __r2z_compare_1);
    });
}

test "test_from_hex_whitespace" {
    const allocator: std.mem.Allocator = std.testing.allocator;
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, (try root.from_hex([]const u8, allocator, "666f 6f62617")).unwrap_err(), error_1.FromHexError{ .InvalidHexCharacter = .{ .c = ' ', .index = 4 } }));
}

test "test_from_hex_array" {
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, root.from_hex__u8_6([]const u8, "666f6f626172"), r2z.Result([6]u8, error_1.FromHexError){ .Ok = [_]u8{ 102, 111, 111, 98, 97, 114 } }));
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, root.from_hex__u8_5([]const u8, "666f6f626172"), r2z.Result([5]u8, error_1.FromHexError){ .Err = error_1.FromHexError{ .InvalidStringLength = @as(void, {}) } }));
}

test "test_to_hex" {
    const allocator: std.mem.Allocator = std.testing.allocator;
    try std.testing.expect(__r2z_value_block_1: {
        var __r2z_compare: r2z.alloc.String = __r2z_value_block_2: {
            const __r2z_blanket_self_0: [6]u8 = [_]u8{ 102, 111, 111, 98, 97, 114 };
            break :__r2z_value_block_2 try root.encode_hex([6]u8, r2z.alloc.String, allocator, &__r2z_blanket_self_0);
        };
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare);
        var __r2z_compare_1: r2z.alloc.String = try r2z.format.toString(allocator, "666f6f626172");
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare_1);
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare, __r2z_compare_1);
    });
    try std.testing.expect(__r2z_value_block_1: {
        var __r2z_compare_2: r2z.alloc.String = __r2z_value_block_2: {
            const __r2z_blanket_self_0: [6]u8 = [_]u8{ 102, 111, 111, 98, 97, 114 };
            break :__r2z_value_block_2 try root.encode_hex_upper([6]u8, r2z.alloc.String, allocator, &__r2z_blanket_self_0);
        };
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare_2);
        var __r2z_compare_3: r2z.alloc.String = try r2z.format.toString(allocator, "666F6F626172");
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare_3);
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare_2, __r2z_compare_3);
    });
}

test "translated tests reachable through ./root.zig" {
    _ = root;
}

test "translated tests reachable through ./error.zig" {
    _ = error_1;
}
