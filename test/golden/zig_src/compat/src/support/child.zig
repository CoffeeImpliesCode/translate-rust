//! Zig translation of Rust crate `compat`, module `child`.
//!
//! Zig consumer contract:
//! Import the registered `compat` module through a build dependency; child
//! modules are reached through the crate's exported namespaces.
//! Requires Zig 0.17.0. Target and optimization options belong to the consumer.
//! Rust names are preserved except native protocol hooks and name collisions.
//! Zig field access and value copying do not enforce Rust privacy or moves.
//! Pointers, slices and erased interfaces borrow their backing storage.
//! Release returned owned runtime storage with its creating allocator;
//! assignment is not a deep clone and does not create a second cleanup owner.
//! This package does not supply a borrow checker or a process-wide allocator.
//!
//! ```zig
//! const library = @import("compat");
//! ```

const std = @import("std");
const support = @import("../support.zig");
const root = @import("../root.zig");

/// Runs the translated Rust operation `total`.
pub fn total() u32 {
    const explicit: support.ParentValue = support.ParentValue{ .value = 7 };
    const constructed: support.ParentValue = support.ParentValue.make();
    return explicit.value +% constructed.value +% support.parent_value() +% root.root_value();
}

test "translated tests reachable through ../support.zig" {
    _ = support;
}

test "translated tests reachable through ../root.zig" {
    _ = root;
}
