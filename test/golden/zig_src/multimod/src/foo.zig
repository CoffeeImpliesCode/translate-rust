//! Zig translation of Rust crate `multimod`, module `foo`.
//!
//! Rust source documentation:
//! Nested out-of-line module containing its own child `mod bar;`, proving
//! discovery recurses into submodule files.
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
const bar = @import("./foo/bar.zig");
const bar_1 = @import("./foo/bar.zig");
const tests = @import("./foo/tests.zig");

/// Runs the translated Rust operation `foo_fn`.
pub fn foo_fn() u32 {
    return bar_1.bar_fn();
}

test "translated tests reachable through ./foo/tests.zig" {
    _ = tests;
}
