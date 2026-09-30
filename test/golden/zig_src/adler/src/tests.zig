const std = @import("std");
const root = @import("./root.zig");

test "zeroes" {
    try std.testing.expect(root.adler32_slice(&[_]u8{}) == 1);
    try std.testing.expect(root.adler32_slice(&[_]u8{ 0 }) == 1 | @as(u32, 1) << @intCast(16));
    try std.testing.expect(root.adler32_slice(&[_]u8{ 0, 0 }) == 1 | @as(u32, 2) << @intCast(16));
    try std.testing.expect(root.adler32_slice(&[_]u8{ 0 } ** 100) == 6553601);
    try std.testing.expect(root.adler32_slice(&[_]u8{ 0 } ** 1024) == 67108865);
    try std.testing.expect(root.adler32_slice(&[_]u8{ 0 } ** 1048576) == 15728641);
}

test "ones" {
    try std.testing.expect(root.adler32_slice(&[_]u8{ 255 } ** 1024) == 2040986670);
    try std.testing.expect(root.adler32_slice(&[_]u8{ 255 } ** 1048576) == 2391338769);
}

test "mixed" {
    try std.testing.expect(root.adler32_slice(&[_]u8{ 1 }) == 2 | @as(u32, 2) << @intCast(16));
    try std.testing.expect(root.adler32_slice(&[_]u8{ 40 }) == 41 | @as(u32, 41) << @intCast(16));
    try std.testing.expect(root.adler32_slice(&[_]u8{ 165 } ** 1048576) == 3573586609);
}

test "wiki" {
    try std.testing.expect(root.adler32_slice("Wikipedia") == 300286872);
}

test "resume" {
    var adler: root.Adler32 = root.Adler32.new();
    adler.write_slice(&[_]u8{ 255 } ** 1024);
    const partial: u32 = adler.checksum();
    try std.testing.expect(partial == 2040986670);
    adler.write_slice(&[_]u8{ 255 } ** 1047552);
    try std.testing.expect(adler.checksum() == 2391338769);
    var adler_1: root.Adler32 = root.Adler32.from_checksum(partial);
    adler_1.write_slice(&[_]u8{ 255 } ** 1047552);
    try std.testing.expect(adler_1.checksum() == 2391338769);
}

test "translated tests reachable through ./root.zig" {
    _ = root;
}
