//! Zig translation of Rust crate `adler`, module `tests`.
//!
//! Zig consumer contract:
//! Import the registered `adler` module through a build dependency; child
//! modules are reached through the crate's exported namespaces.
//! Requires Zig 0.16.0. Target and optimization options belong to the consumer.
//! Rust names are preserved except native protocol hooks and name collisions.
//! Zig field access and value copying do not enforce Rust privacy or moves.
//! Pointers, slices and erased interfaces borrow their backing storage.
//! Release returned owned runtime storage with its creating allocator;
//! assignment is not a deep clone and does not create a second cleanup owner.
//! This package does not supply a borrow checker or a process-wide allocator.
//!
//! ```zig
//! const library = @import("adler");
//! ```

const std = @import("std");
const root = @import("./root.zig");
const r2z = @import("r2z");

/// Runs the translated Rust operation `__r2z_localfn_124_test`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
///
pub fn __r2z_localfn_124_test(allocator: std.mem.Allocator, data: []const u8, checksum_1: u32) void {
    var buf: r2z.io.BufReader([]const u8) = r2z.io.BufReader([]const u8).init(data);
    const real_sum: u32 = root.adler32(*r2z.io.BufReader([]const u8), allocator, &buf).unwrap(allocator);
    std.debug.assert(checksum_1 == real_sum);
}

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

test "bufread" {
    const allocator: std.mem.Allocator = std.testing.allocator;
    __r2z_localfn_124_test(allocator, &[_]u8{}, 1);
    __r2z_localfn_124_test(allocator, &[_]u8{ 0 } ** 1024, 67108865);
    __r2z_localfn_124_test(allocator, &[_]u8{ 0 } ** 1048576, 15728641);
    __r2z_localfn_124_test(allocator, &[_]u8{ 165 } ** 1048576, 3573586609);
}

test "translated tests reachable through ./root.zig" {
    _ = root;
}
