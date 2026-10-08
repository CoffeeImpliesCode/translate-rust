//! Zig translation of Rust crate `adler`, module `algo`.
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

const algo = @import("./algo.zig");

/// Rust `U32X4` state with Zig value semantics.
pub const U32X4 = struct {
    const Self = @This();

    @"0": [4]u32,

    /// Runs the translated Rust operation `from`.
    pub fn from(bytes: []const u8) algo.U32X4 {
        return algo.U32X4{ .@"0" = [_]u32{ @as(u32, bytes[0]), @as(u32, bytes[1]), @as(u32, bytes[2]), @as(u32, bytes[3]) } };
    }

    /// Runs the translated Rust operation `add_assign`.
    pub fn add_assign(self: *U32X4, other: algo.U32X4) void {
        for (self.@"0"[0..], other.@"0"[0..]) |*s, *o| {
            s.* +%= o.*;
        }
    }

    /// Runs the translated Rust operation `rem_assign`.
    pub fn rem_assign(self: *U32X4, quotient: u32) void {
        for (self.@"0"[0..]) |*s| {
            {
                const __r2z_compound_rhs: u32 = quotient;
                const __r2z_compound_place = &s.*;
                const __r2z_compound_lhs = __r2z_compound_place.*;
                __r2z_compound_place.* = @rem(__r2z_compound_lhs, __r2z_compound_rhs);
            }
        }
    }

    /// Runs the translated Rust operation `mul_assign`.
    pub fn mul_assign(self: *U32X4, rhs: u32) void {
        for (self.@"0"[0..]) |*s| {
            s.* *%= rhs;
        }
    }
};
