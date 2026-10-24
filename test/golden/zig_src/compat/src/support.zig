//! Zig translation of Rust crate `compat`, module `support`.
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
const support = @import("./support.zig");
pub const child = @import("./support/child.zig");

/// Rust `ParentValue` state with Zig value semantics.
pub const ParentValue = struct {
    const Self = @This();

    value: u32,

    /// Runs the translated Rust operation `make`.
    pub fn make() support.ParentValue {
        return support.ParentValue{ .value = 11 };
    }
};

/// Runs the translated Rust operation `parent_value`.
pub fn parent_value() u32 {
    return 3;
}

test "translated tests reachable through ./support.zig" {
    _ = support;
}

test "translated tests reachable through ./support/child.zig" {
    _ = child;
}
