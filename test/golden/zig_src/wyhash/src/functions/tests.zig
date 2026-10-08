//! Zig translation of Rust crate `wyhash`, module `tests`.
//!
//! Zig consumer contract:
//! Import the registered `wyhash` module through a build dependency; child
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
//! const library = @import("wyhash");
//! ```

const std = @import("std");
const functions = @import("../functions.zig");
const functions_1 = @import("../functions.zig");

test "read_rest_byte_sorting" {
    try std.testing.expect(1 == functions_1.read_rest(&[_]u8{ 1 }));
    try std.testing.expect(513 == functions_1.read_rest(&[_]u8{ 1, 2 }));
    try std.testing.expect(131331 == functions_1.read_rest(&[_]u8{ 1, 2, 3 }));
    try std.testing.expect(67305985 == functions_1.read_rest(&[_]u8{ 1, 2, 3, 4 }));
    try std.testing.expect(17230332165 == functions_1.read_rest(&[_]u8{ 1, 2, 3, 4, 5 }));
    try std.testing.expect(4410965034501 == functions_1.read_rest(&[_]u8{ 1, 2, 3, 4, 5, 6 }));
    try std.testing.expect(1129207048832263 == functions_1.read_rest(&[_]u8{ 1, 2, 3, 4, 5, 6, 7 }));
    try std.testing.expect(289077004534744581 == functions_1.read_rest(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }));
}

test "read64_byte_sorting" {
    try std.testing.expect(578437695752307201 == functions_1.read64(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }));
}

test "translated tests reachable through ../functions.zig" {
    _ = functions;
}
