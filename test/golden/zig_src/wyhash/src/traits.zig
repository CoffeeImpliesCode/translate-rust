//! Zig translation of Rust crate `wyhash`, module `traits`.
//!
//! Zig consumer contract:
//! Import the registered `wyhash` module through a build dependency; child
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
//! const library = @import("wyhash");
//! ```

const std = @import("std");
const functions = @import("./functions.zig");
const traits = @import("./traits.zig");
const functions_1 = @import("./functions.zig");
const r2z = @import("r2z");

/// WyHash hasher
pub const WyHash = struct {
    const Self = @This();

    h: u64,
    size: u64,

    /// Create hasher with a seed
    pub fn with_seed(seed: u64) traits.WyHash {
        return traits.WyHash{ .h = seed, .size = 0 };
    }

    /// Runs the translated Rust operation `write`.
    pub fn write(self: *WyHash, bytes: []const u8) void {
        return if (bytes.len == 0) {
            self.h = functions_1.mix_with_p0(self.h);
        } else {
            var __chunk_index: usize = 0;
            while (bytes.len > __chunk_index) : (__chunk_index += @as(usize, 18446744073709551615)) {
                const bytes_1 = bytes[__chunk_index..@min(__chunk_index + @as(usize, 18446744073709551615), bytes.len)];
                self.h = functions_1.wyhash_core(bytes_1, self.h);
                self.size +%= @as(u64, bytes_1.len);
            }
        };
    }

    /// Runs the translated Rust operation `finish`.
    pub fn finish(self: *const WyHash) u64 {
        return functions_1.wyhash_finish(self.size, self.h);
    }
};

/// WyRng random number generator
pub const WyRng = struct {
    const Self = @This();

    @"0": u64,

    /// Runs the translated Rust operation `next_u32`.
    pub fn next_u32(self: *WyRng) u32 {
        return @as(u32, @truncate(self.next_u64()));
    }

    /// Runs the translated Rust operation `next_u64`.
    pub fn next_u64(self: *WyRng) u64 {
        return functions_1.wyrng(&self.@"0");
    }

    /// Runs the translated Rust operation `fill_bytes`.
    pub fn fill_bytes(self: *WyRng, dest: []u8) void {
        return r2z.random.fill_bytes_via_next(self, dest);
    }

    /// Runs the translated Rust operation `try_fill_bytes`.
    pub fn try_fill_bytes(self: *WyRng, dest: []u8) r2z.Result(void, r2z.random.Error) {
        self.fill_bytes(dest);
        return r2z.Result(void, r2z.random.Error){ .Ok = @as(void, {}) };
    }

    /// Runs the translated Rust operation `from_seed`.
    pub fn from_seed(seed: [8]u8) traits.WyRng {
        return traits.WyRng{ .@"0" = functions_1.read64(&seed) };
    }

    /// Runs the translated Rust operation `seed_from_u64`.
    pub fn seed_from_u64(state: u64) traits.WyRng {
        return traits.WyRng{ .@"0" = state };
    }
};

test "translated tests reachable through ./functions.zig" {
    _ = functions;
}

test "translated tests reachable through ./traits.zig" {
    _ = traits;
}
