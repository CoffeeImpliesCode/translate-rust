//! Zig translation of Rust crate `multimod`, module `crate root`.
//!
//! Rust source documentation:
//! Multifile module-discovery fixture: one out-of-line module (`mod foo;`),
//! one nested two-level module (`mod foo;` -> `mod bar;`), and one module
//! declared through a `#[path = "..."]` attribute. Used by the frontend
//! pipeline test to prove submodule files are found and ingested recursively.
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
const foo = @import("./foo.zig");

/// Runs the translated Rust operation `enter`.
pub fn enter() u32 {
    return 42;
}

pub const custom_pub = @import("./custom_pub.zig");

test "translated tests reachable through ./foo.zig" {
    _ = foo;
}
