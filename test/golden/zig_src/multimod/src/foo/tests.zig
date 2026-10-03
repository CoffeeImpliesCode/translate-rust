//! Zig translation of Rust crate `multimod`, module `tests`.
//!
//! Zig consumer contract:
//! Import the registered `multimod` module through a build dependency; child
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
//! const library = @import("multimod");
//! ```

const std = @import("std");
const bar = @import("./bar.zig");
const foo = @import("../foo.zig");

test "foo_fn_delegates_to_bar_fn" {
    try std.testing.expect(bar.bar_fn() == foo.foo_fn());
    try std.testing.expect(7 == foo.foo_fn());
}

test "translated tests reachable through ../foo.zig" {
    _ = foo;
}
