const std = @import("std");
const functions = @import("../functions.zig");
const functions_1 = @import("../functions.zig");

test "read_rest_byte_sorting" {
    try std.testing.expect((1 == functions_1.read_rest(&[_]u8{ 1 })));
    try std.testing.expect((513 == functions_1.read_rest(&[_]u8{ 1, 2 })));
    try std.testing.expect((131331 == functions_1.read_rest(&[_]u8{ 1, 2, 3 })));
    try std.testing.expect((67305985 == functions_1.read_rest(&[_]u8{ 1, 2, 3, 4 })));
    try std.testing.expect((17230332165 == functions_1.read_rest(&[_]u8{ 1, 2, 3, 4, 5 })));
    try std.testing.expect((4410965034501 == functions_1.read_rest(&[_]u8{ 1, 2, 3, 4, 5, 6 })));
    try std.testing.expect((1129207048832263 == functions_1.read_rest(&[_]u8{ 1, 2, 3, 4, 5, 6, 7 })));
    try std.testing.expect((289077004534744581 == functions_1.read_rest(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 })));
}

test "read64_byte_sorting" {
    try std.testing.expect((578437695752307201 == functions_1.read64(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 })));
}

test "translated tests reachable through ../functions.zig" {
    _ = functions;
}
