//! Zig translation of Rust crate `mini`, module `crate root`.
//!
//! Rust source documentation:
//! mini — a tiny no_std crate exercising the v1 model surface.
//! translate-rust P1 fixture: file-split module, struct, data-carrying enum,
//! fn + match, and a `pub use` re-export.
//!
//! Zig consumer contract:
//! Import the registered `mini` module through a build dependency; child
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
//! const library = @import("mini");
//! ```

/// Rust `Point` state with Zig value semantics.
pub const Point = struct {
    x: i32,
    y: i32,
};

/// Alternatives of Rust `Shape`; the active tag determines the payload.
pub const Shape = union(enum) {
    Circle: f64,
    Rect: struct { width: f64, height: f64 },
};

/// Runs the translated Rust operation `area`.
pub fn area(shape: Shape) f64 {
    return switch (shape) {
        .Circle => |r| r * r * 3.14159,
        .Rect => |__r2z_match_payload| __r2z_match_arm: {
            const width = __r2z_match_payload.width;
            const height = __r2z_match_payload.height;
            break :__r2z_match_arm width * height;
        },
    };
}

/// Runs the translated Rust operation `origin`.
pub fn origin() Point {
    return Point{ .x = 0, .y = 0 };
}

pub const helper = util.helper;

pub const util = @import("./util.zig");
