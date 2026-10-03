//! Zig translation of Rust crate `wyhash`, module `functions`.
//!
//! Zig consumer contract:
//! Import the registered `wyhash` module through a build dependency; child
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
//! const library = @import("wyhash");
//! ```

const std = @import("std");
const tests = @import("./functions/tests.zig");
const r2z = @import("r2z");

pub const P0: u64 = 11562461410679940143;

pub const P1: u64 = 16646288086500911323;

pub const P2: u64 = 10285213230658275043;

pub const P3: u64 = 6384245875588680899;

pub const P4: u64 = 2129725606500045391;

pub const P5: u64 = 16952864883938283877;

/// Runs the translated Rust operation `wymum`.
pub fn wymum(a: u64, b: u64) u64 {
    const r: u128 = @as(u128, a) *% @as(u128, b);
    return @as(u64, @truncate(r >> @intCast(64) ^ r));
}

/// Runs the translated Rust operation `read64`.
pub fn read64(data: []const u8) u64 {
    return @as(u64, data[7]) << @intCast(56) | @as(u64, data[6]) << @intCast(48) | @as(u64, data[5]) << @intCast(40) | @as(u64, data[4]) << @intCast(32) | @as(u64, data[3]) << @intCast(24) | @as(u64, data[2]) << @intCast(16) | @as(u64, data[1]) << @intCast(8) | @as(u64, data[0]);
}

/// Runs the translated Rust operation `read32`.
pub fn read32(data: []const u8) u64 {
    return @as(u64, data[3]) << @intCast(24) | @as(u64, data[2]) << @intCast(16) | @as(u64, data[1]) << @intCast(8) | @as(u64, data[0]);
}

/// Runs the translated Rust operation `read64_swapped`.
pub fn read64_swapped(data: []const u8) u64 {
    return read32(data) << @intCast(32) | read32(data[4..]);
}

/// Runs the translated Rust operation `read_rest`.
pub fn read_rest(data: []const u8) u64 {
    return switch (data.len) {
        1 => @as(u64, data[0]),
        2 => @as(u64, data[1]) << @intCast(8) | @as(u64, data[0]),
        3 => @as(u64, data[1]) << @intCast(16) | @as(u64, data[0]) << @intCast(8) | @as(u64, data[2]),
        4 => read32(data),
        5 => read32(data) << @intCast(8) | @as(u64, data[4]),
        6 => read32(data) << @intCast(16) | @as(u64, data[5]) << @intCast(8) | @as(u64, data[4]),
        7 => __r2z_value_block_2: {
            break :__r2z_value_block_2 read32(data) << @intCast(24) | @as(u64, data[5]) << @intCast(16) | @as(u64, data[4]) << @intCast(8) | @as(u64, data[6]);
        },
        8 => read64_swapped(data),
        else => @panic("panic"),
    };
}

/// Generate a hash for the input data and seed
pub fn wyhash(bytes: []const u8, seed: u64) u64 {
    const seed_1: u64 = wyhash_core(bytes, seed);
    return wyhash_finish(@as(u64, bytes.len), seed_1);
}

/// Runs the translated Rust operation `mix_with_p0`.
pub fn mix_with_p0(seed: u64) u64 {
    return seed ^ P0;
}

/// Runs the translated Rust operation `wyhash_core`.
pub fn wyhash_core(bytes: []const u8, _seed: u64) u64 {
    var seed: u64 = _seed;
    var __r2z_chunks_exact = r2z.chunksExact(bytes, 32);
    while (__r2z_chunks_exact.next()) |chunk| {
        seed = wymum(seed ^ P0, wymum(read64(chunk) ^ P1, read64(chunk[8..]) ^ P2) ^ wymum(read64(chunk[16..]) ^ P3, read64(chunk[24..]) ^ P4));
    }
    seed = mix_with_p0(seed);
    const rest: usize = bytes.len & 31;
    if (rest != 0) __r2z_value_block_1: {
        const start: usize = bytes.len & ~@as(usize, 31);
        break :__r2z_value_block_1 switch ((bytes.len -% 1 & 31) / 8) {
            0 => __r2z_value_block_3: {
                seed = wymum(seed, read_rest(bytes[start..]) ^ P1);
                break :__r2z_value_block_3 @as(void, {});
            },
            1 => {
                seed = wymum(read64_swapped(bytes[start..]) ^ seed, read_rest(bytes[(start +% 8)..]) ^ P2);
            },
            2 => {
                seed = wymum(read64_swapped(bytes[start..]) ^ seed, read64_swapped(bytes[(start +% 8)..]) ^ P2) ^ wymum(seed, read_rest(bytes[(start +% 16)..]) ^ P3);
            },
            3 => {
                seed = wymum(read64_swapped(bytes[start..]) ^ seed, read64_swapped(bytes[(start +% 8)..]) ^ P2) ^ wymum(read64_swapped(bytes[(start +% 16)..]) ^ seed, read_rest(bytes[(start +% 24)..]) ^ P4);
            },
            else => @panic("unreachable"),
        };
    }
    return seed;
}

/// Runs the translated Rust operation `wyhash_finish`.
pub fn wyhash_finish(length: u64, seed: u64) u64 {
    return wymum(seed, length ^ P5);
}

/// Pseudo-Random Number Generator (PRNG)
/// Note that the input seed is updated
pub fn wyrng(seed: *u64) u64 {
    seed.* = seed.* +% P0;
    return wymum(seed.* ^ P1, seed.*);
}

test "translated tests reachable through ./functions/tests.zig" {
    _ = tests;
}
