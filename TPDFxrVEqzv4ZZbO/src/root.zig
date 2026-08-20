const std = @import("std");

pub const limit: u32 = 42;

pub fn add(a: u32, b: u32) u32 {
    return (a + b);
}

test "add sums" {
    std.testing.expectEqual(7, add(3, 4));
}
