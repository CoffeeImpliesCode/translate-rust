// Golden emitter output for the fnv crate (P2 target).
// FNV-1a hash: one public const fn over a byte slice, no allocation,
// no generics, no traits — the simplest possible translation target.

const std = @import("std");

pub const FNV_OFFSET_BASIS: u64 = 14695981039346656037;
pub const FNV_PRIME: u64 = 1099511628211;
pub fn fnv1a_hash(data: []const u8) u64 {
    var h: u64 = FNV_OFFSET_BASIS;
    for (data) |byte| {
        h ^= byte;
        h *%= FNV_PRIME;
    }
    return h;
}

test "fnv1a empty string" {
    try std.testing.expectEqual(@as(u64, 0xcbf29ce484222325), fnv1a_hash(""));
}

test "fnv1a single byte" {
    try std.testing.expectEqual(@as(u64, 0xaf63dc4c8601ec8c), fnv1a_hash("a"));
}

test "fnv1a foobar" {
    try std.testing.expectEqual(@as(u64, 0x85944171f73967e8), fnv1a_hash("foobar"));
}
