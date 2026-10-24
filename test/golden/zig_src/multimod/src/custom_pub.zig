//! Zig translation of Rust crate `multimod`, module `custom_pub`.
//!
//! Rust source documentation:
//! Module discovered via `#[path = "custom.rs"]` (not the conventional
//! `custom_pub.rs` layout).
//!
//! Zig consumer contract:
//! Import the registered `multimod` module through a build dependency; child
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
//! const library = @import("multimod");
//! ```

/// Runs the translated Rust operation `custom_fn`.
pub fn custom_fn() u32 {
    return 5;
}
