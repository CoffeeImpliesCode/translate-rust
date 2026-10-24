//! Zig translation of Rust crate `adler`, module `crate root`.
//!
//! Rust source documentation:
//! Adler-32 checksum implementation.
//! This implementation features:
//! - Permissively licensed (0BSD) clean-room implementation.
//! - Zero dependencies.
//! - Zero `unsafe`.
//! - Decent performance (3-4 GB/s).
//! - `#![no_std]` support (with `default-features = false`).
//!
//! Zig consumer contract:
//! Import the registered `adler` module through a build dependency; child
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
//! const library = @import("adler");
//! ```

const std = @import("std");
const algo = @import("./algo.zig");
const algo_1 = @import("./algo.zig");
const tests = @import("./tests.zig");
const r2z = @import("r2z");

/// Adler-32 checksum calculator.
/// An instance of this type is equivalent to an Adler-32 checksum: It can be created in the default
/// state via [`new`] (or the provided `Default` impl), or from a precalculated checksum via
/// [`from_checksum`], and the currently stored checksum can be fetched via [`checksum`].
/// This type also implements `Hasher`, which makes it easy to calculate Adler-32 checksums of any
/// type that implements or derives `Hash`. This also allows using Adler-32 in a `HashMap`, although
/// that is not recommended (while every checksum is a hash function, they are not necessarily a
/// good one).
/// # Examples
/// Basic, piecewise checksum calculation:
/// ```
/// use adler::Adler32;
/// let mut adler = Adler32::new();
/// adler.write_slice(&[0, 1, 2]);
/// adler.write_slice(&[3, 4, 5]);
/// assert_eq!(adler.checksum(), 0x00290010);
/// ```
/// Using `Hash` to process structures:
/// ```
/// use std::hash::Hash;
/// use adler::Adler32;
/// #[derive(Hash)]
/// struct Data {
/// byte: u8,
/// word: u16,
/// big: u64,
/// }
/// let mut adler = Adler32::new();
/// let data = Data { byte: 0x1F, word: 0xABCD, big: !0 };
/// data.hash(&mut adler);
/// // hash value depends on architecture endianness
/// if cfg!(target_endian = "little") {
/// assert_eq!(adler.checksum(), 0x33410990);
/// }
/// if cfg!(target_endian = "big") {
/// assert_eq!(adler.checksum(), 0x331F0990);
/// }
/// ```
/// [`new`]: #method.new
/// [`from_checksum`]: #method.from_checksum
/// [`checksum`]: #method.checksum
pub const Adler32 = struct {
    const Self = @This();

    a: u16,
    b: u16,

    /// Creates a new Adler-32 instance with default state.
    pub fn new() root.Adler32 {
        return root.Adler32.default();
    }

    /// Creates an `Adler32` instance from a precomputed Adler-32 checksum.
    /// This allows resuming checksum calculation without having to keep the `Adler32` instance
    /// around.
    /// # Example
    /// ```
    /// # use adler::Adler32;
    /// let parts = [
    /// "rust",
    /// "acean",
    /// ];
    /// let whole = adler::adler32_slice(b"rustacean");
    /// let mut sum = Adler32::new();
    /// sum.write_slice(parts[0].as_bytes());
    /// let partial = sum.checksum();
    /// // ...later
    /// let mut sum = Adler32::from_checksum(partial);
    /// sum.write_slice(parts[1].as_bytes());
    /// assert_eq!(sum.checksum(), whole);
    /// ```
    pub fn from_checksum(sum: u32) root.Adler32 {
        return root.Adler32{ .a = @as(u16, @truncate(sum)), .b = @as(u16, @truncate(sum >> @intCast(16))) };
    }

    /// Returns the calculated checksum at this point in time.
    pub fn checksum(self: *const Adler32) u32 {
        return @as(u32, self.b) << @intCast(16) | @as(u32, self.a);
    }

    /// Adds `bytes` to the checksum calculation.
    /// If efficiency matters, this should be called with Byte slices that contain at least a few
    /// thousand Bytes.
    pub fn write_slice(self: *Adler32, bytes: []const u8) void {
        self.compute(bytes);
    }

    /// Runs the translated Rust operation `default`.
    pub fn default() root.Adler32 {
        return root.Adler32{ .a = 1, .b = 0 };
    }

    /// Runs the translated Rust operation `finish`.
    pub fn finish(self: *const Adler32) u64 {
        return @as(u64, self.checksum());
    }

    /// Runs the translated Rust operation `write`.
    pub fn write(self: *Adler32, bytes: []const u8) void {
        self.write_slice(bytes);
    }

    /// Runs the translated Rust operation `compute`.
    pub fn compute(self: *Adler32, bytes: []const u8) void {
        const MOD: u32 = 65521;
        const CHUNK_SIZE: usize = 5552 *% 4;
        var a: u32 = @as(u32, self.a);
        var b: u32 = @as(u32, self.b);
        var a_vec: algo_1.U32X4 = algo_1.U32X4{ .@"0" = @as([4]u32, @splat(0)) };
        var b_vec: algo_1.U32X4 = a_vec;
        const _tuple = r2z.splitAt(bytes, bytes.len -% @rem(bytes.len, 4));
        const bytes_1 = _tuple[0];
        const remainder = _tuple[1];
        const chunk_iter: r2z.ChunksExact(u8) = r2z.chunksExact(bytes_1, CHUNK_SIZE);
        const remainder_chunk: []const u8 = r2z.chunksExactRemainder(chunk_iter);
        var __r2z_iter = chunk_iter;
        while (__r2z_iter.next()) |chunk| {
            var __r2z_chunks_exact = r2z.chunksExact(chunk, 4);
            while (__r2z_chunks_exact.next()) |byte_vec| {
                const val: algo_1.U32X4 = algo_1.U32X4.from(byte_vec);
                a_vec.add_assign(val);
                b_vec.add_assign(a_vec);
            }
            b +%= @as(u32, @truncate(CHUNK_SIZE)) *% a;
            a_vec.rem_assign(MOD);
            b_vec.rem_assign(MOD);
            {
                const __r2z_compound_rhs: u32 = MOD;
                const __r2z_compound_place = &b;
                const __r2z_compound_lhs = __r2z_compound_place.*;
                __r2z_compound_place.* = @rem(__r2z_compound_lhs, __r2z_compound_rhs);
            }
        }
        var __r2z_chunks_exact = r2z.chunksExact(remainder_chunk, 4);
        while (__r2z_chunks_exact.next()) |byte_vec_1| {
            const val_1: algo_1.U32X4 = algo_1.U32X4.from(byte_vec_1);
            a_vec.add_assign(val_1);
            b_vec.add_assign(a_vec);
        }
        b +%= @as(u32, @truncate(remainder_chunk.len)) *% a;
        a_vec.rem_assign(MOD);
        b_vec.rem_assign(MOD);
        {
            const __r2z_compound_rhs_1: u32 = MOD;
            const __r2z_compound_place_1 = &b;
            const __r2z_compound_lhs_1 = __r2z_compound_place_1.*;
            __r2z_compound_place_1.* = @rem(__r2z_compound_lhs_1, __r2z_compound_rhs_1);
        }
        b_vec.mul_assign(4);
        b_vec.@"0"[1] +%= MOD -% a_vec.@"0"[1];
        b_vec.@"0"[2] +%= (MOD -% a_vec.@"0"[2]) *% 2;
        b_vec.@"0"[3] +%= (MOD -% a_vec.@"0"[3]) *% 3;
        for (a_vec.@"0"[0..]) |av| {
            a +%= av;
        }
        for (b_vec.@"0"[0..]) |bv| {
            b +%= bv;
        }
        for (remainder[0..]) |byte| {
            a +%= @as(u32, byte);
            b +%= a;
        }
        self.a = @as(u16, @truncate(@rem(a, MOD)));
        self.b = @as(u16, @truncate(@rem(b, MOD)));
    }
};

/// Calculates the Adler-32 checksum of a byte slice.
/// This is a convenience function around the [`Adler32`] type.
/// [`Adler32`]: struct.Adler32.html
pub fn adler32_slice(data: []const u8) u32 {
    var h: Adler32 = Adler32.new();
    h.write_slice(data);
    return h.checksum();
}

/// Calculates the Adler-32 checksum of a `BufRead`'s contents.
/// The passed `BufRead` implementor will be read until it reaches EOF (or until it reports an
/// error).
/// If you only have a `Read` implementor, you can wrap it in `std::io::BufReader` before calling
/// this function.
/// # Errors
/// Any error returned by the reader are bubbled up by this function.
/// # Examples
/// ```no_run
/// # fn run() -> Result<(), Box<dyn std::error::Error>> {
/// use adler::adler32;
/// use std::fs::File;
/// use std::io::BufReader;
/// let file = File::open("input.txt")?;
/// let mut file = BufReader::new(file);
/// adler32(&mut file)?;
/// # Ok(()) }
/// # fn main() { run().unwrap() }
/// ```
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
///
pub fn adler32(comptime R: type, allocator: std.mem.Allocator, _reader: R) r2z.Result(u32, r2z.io.Error) {
    var reader = if (switch (@typeInfo(@TypeOf(_reader))) {
        .pointer => |__r2z_bufread_pointer| switch (__r2z_bufread_pointer.size) {
            .slice => false,
            else => true,
        },
        else => false,
    }) @as(void, {}) else _reader;
    defer r2z.alloc.dropTemporary(allocator, &reader);
    var h: Adler32 = Adler32.new();
    while (true) {
        const len: usize = __r2z_value_block_2: {
            const buf: []const u8 = switch (r2z.io.fill_buf(if (switch (@typeInfo(@TypeOf(_reader))) {
                .pointer => |__r2z_bufread_pointer_2| switch (__r2z_bufread_pointer_2.size) {
                    .slice => false,
                    else => true,
                },
                else => false,
            }) _reader else &reader)) {
                .Ok => |__r2z_try_ok| __r2z_try_ok,
                .Err => |__r2z_try_err| return r2z.Result(u32, r2z.io.Error){ .Err = __r2z_try_err },
            };
            if (buf.len == 0) {
                return r2z.Result(u32, r2z.io.Error){ .Ok = h.checksum() };
            }
            h.write_slice(buf);
            break :__r2z_value_block_2 buf.len;
        };
        r2z.io.consume(if (switch (@typeInfo(@TypeOf(_reader))) {
            .pointer => |__r2z_bufread_pointer_4| switch (__r2z_bufread_pointer_4.size) {
                .slice => false,
                else => true,
            },
            else => false,
        }) _reader else &reader, len);
    }
}

pub const root = @import("./root.zig");

test "translated tests reachable through ./tests.zig" {
    _ = tests;
}

test "translated tests reachable through ./root.zig" {
    _ = root;
}
