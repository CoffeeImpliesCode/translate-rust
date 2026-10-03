//! Zig translation of Rust crate `multimod`, module `bar`.
//!
//! Rust source documentation:
//! Child of `foo.rs`, resolved as `src/foo/bar.rs`.
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

/// Runs the translated Rust operation `bar_fn`.
pub fn bar_fn() u32 {
    return 7;
}
