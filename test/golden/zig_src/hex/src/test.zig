const std = @import("std");
const root = @import("./root.zig");
const error_1 = @import("./error.zig");
const r2z = @import("r2z");

test "test_encode_to_slice" {
    var output_1: [8]u8 = [_]u8{ 0 } ** 8;
    root.encode_to_slice(*const [4]u8, "kiwi", &output_1).unwrap();
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, &output_1, "6b697769"));
    var output_2: [10]u8 = [_]u8{ 0 } ** 10;
    root.encode_to_slice(*const [5]u8, "kiwis", &output_2).unwrap();
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, &output_2, "6b69776973"));
    var output_3: [100]u8 = [_]u8{ 0 } ** 100;
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, root.encode_to_slice(*const [5]u8, "kiwis", &output_3), r2z.Result(void, error_1.FromHexError){ .Err = error_1.FromHexError.InvalidStringLength }));
}

test "test_decode_to_slice" {
    var output_1: [4]u8 = [_]u8{ 0 } ** 4;
    root.decode_to_slice(*const [8]u8, "6b697769", &output_1).unwrap();
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, &output_1, "kiwi"));
    var output_2: [5]u8 = [_]u8{ 0 } ** 5;
    root.decode_to_slice(*const [10]u8, "6b69776973", &output_2).unwrap();
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, &output_2, "kiwis"));
    var output_3: [4]u8 = [_]u8{ 0 } ** 4;
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, root.decode_to_slice(*const [1]u8, "6", &output_3), r2z.Result(void, error_1.FromHexError){ .Err = error_1.FromHexError.OddLength }));
}

test "test_from_hex_array" {
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, root.from_hex__u8_6([]const u8, "666f6f626172"), r2z.Result([6]u8, error_1.FromHexError){ .Ok = [_]u8{ 102, 111, 111, 98, 97, 114 } }));
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, root.from_hex__u8_5([]const u8, "666f6f626172"), r2z.Result([5]u8, error_1.FromHexError){ .Err = error_1.FromHexError.InvalidStringLength }));
}

test "translated tests reachable through ./root.zig" {
    _ = root;
}
