//! r2z-core (libr2z) — the translation runtime for translate-rust.
//!
//! Provides thin, zero-overhead Zig 0.16 shims that translated Rust code
//! lowers onto. Deliberately MINIMAL and NOT crate-specific: anything that
//! Zig std already provides (hashing, slices) is re-exported/aliased, not
//! reimplemented — we strive for maximum compatibility with Zig std.
//!
//! The translated fnv/fletcher/etc. crates implement their OWN algorithm in
//! their own package; r2z-core only supplies the shared primitives those
//! translations need.

const std = @import("std");
const builtin = @import("builtin");

// ── Hash framework — re-export Zig std.hash (max compat) ─────────────────
//
// Zig std already ships the standard hashing algorithms (incl. FNV-1a,
// which is what the `fnv` crate implements). Translated crates should use
// these directly; r2z-core MUST NOT carry a crate's hash constants.
pub const hash = std.hash;

// Convenience aliases for the algorithms Rust code most commonly translates:
pub const Fnv1a_32 = std.hash.Fnv1a_32;
pub const Fnv1a_64 = std.hash.Fnv1a_64;
pub const Fnv1a_128 = std.hash.Fnv1a_128;
pub const Wyhash = std.hash.Wyhash;
pub const SipHash64 = std.hash.SipHash64;
pub const SipHash128 = std.hash.SipHash128;
pub const XxHash3 = std.hash.XxHash3;
pub const XxHash64 = std.hash.XxHash64;
pub const Adler32 = std.hash.Adler32;
pub const Crc32 = std.hash.Crc32;

// ── Arithmetic primitives (thin translators of Rust methods) ─────────────
//
// Rust `.wrapping_add` / `.wrapping_mul` / `.rotate_left` / `.leading_zeros`
// etc. override low-level ops. The Zig emitter lowers these to operators and
// builtins where possible; these shims cover cases where the method name
// must survive as a call.

/// Rust `a.wrapping_add(b)` → `r2z.wrappingAdd(a, b)` (== `a +% b`).
pub inline fn wrappingAdd(a: anytype, b: anytype) @TypeOf(a) {
    return a +% b;
}

/// Rust `a.wrapping_sub(b)` → `a -% b`.
pub inline fn wrappingSub(a: anytype, b: anytype) @TypeOf(a) {
    return a -% b;
}

/// Rust `a.wrapping_mul(b)` → `a *% b`.
pub inline fn wrappingMul(a: anytype, b: anytype) @TypeOf(a) {
    return a *% b;
}

/// Rust `a.saturating_add(b)` → `a +| b`.
pub inline fn saturatingAdd(a: anytype, b: anytype) @TypeOf(a) {
    return a +| b;
}

/// Rust `a.saturating_sub(b)` → `a -| b`.
pub inline fn saturatingSub(a: anytype, b: anytype) @TypeOf(a) {
    return a -| b;
}

/// Rust `a.rotate_left(shift)` → `std.math.rotl`.
pub inline fn rotateLeft(comptime T: type, val: T, shift: std.math.Log2Int(T)) T {
    return std.math.rotl(T, val, shift);
}

/// Rust `a.rotate_right(shift)` → `std.math.rotr`.
pub inline fn rotateRight(comptime T: type, val: T, shift: std.math.Log2Int(T)) T {
    return std.math.rotr(T, val, shift);
}

/// Rust `a.leading_zeros()` → `@clz`.
pub inline fn leadingZeros(val: anytype) std.math.Log2IntCeil(@TypeOf(val)) {
    return @clz(val);
}

/// Rust `a.trailing_zeros()` → `@ctz`.
pub inline fn trailingZeros(val: anytype) std.math.Log2IntCeil(@TypeOf(val)) {
    return @ctz(val);
}

// ── Slice utilities (translation targets, not in std as shims) ───────────

/// Iterator yielding non-overlapping chunks of a slice.
pub fn Chunks(comptime T: type) type {
    return struct {
        const Self = @This();

        slice: []const T,
        size: usize,
        index: usize = 0,

        pub fn next(self: *Self) ?[]const T {
            if (self.index >= self.slice.len) return null;
            const chunk_len = @min(self.slice.len - self.index, self.size);
            const result = self.slice[self.index .. self.index + chunk_len];
            self.index += chunk_len;
            return result;
        }
    };
}

/// Create a non-overlapping chunk iterator over `slice` (Rust `chunks(n)`).
pub fn chunks(comptime T: type, slice: []const T, size: usize) Chunks(T) {
    std.debug.assert(size > 0);
    return .{
        .slice = slice,
        .size = size,
    };
}

/// Iterator yielding overlapping sliding windows of a slice.
pub fn Windows(comptime T: type) type {
    return struct {
        const Self = @This();

        slice: []const T,
        size: usize,
        index: usize = 0,

        pub fn next(self: *Self) ?[]const T {
            if (self.size > self.slice.len or self.index > self.slice.len - self.size) {
                return null;
            }
            const result = self.slice[self.index .. self.index + self.size];
            self.index += 1;
            return result;
        }
    };
}

/// Create an overlapping sliding window iterator over `slice` (Rust `windows(n)`).
pub fn windows(comptime T: type, slice: []const T, size: usize) Windows(T) {
    std.debug.assert(size > 0);
    return .{
        .slice = slice,
        .size = size,
    };
}

/// Rust `dest.copy_from_slice(src)` → `@memcpy`.
pub inline fn copyFromSlice(comptime T: type, dest: []T, src: []const T) void {
    @memcpy(dest[0..src.len], src);
}

// ── Panic & Assertion ─────────────────────────────────────────────────────

/// Rust `assert!` (active in all modes).
pub inline fn assert(cond: bool) void {
    std.debug.assert(cond);
}

/// Rust `debug_assert!` (active only in Debug mode). Guarded so the argument
/// is NOT evaluated in release builds — avoids the Bun debug_assert-regression
/// (prior-work §4 lesson 4).
pub inline fn debugAssert(cond: bool) void {
    if (builtin.mode == .Debug) {
        std.debug.assert(cond);
    }
}

// ── Unit Tests ───────────────────────────────────────────────────────────

test "hash aliases re-export Zig std" {
    // FNV-1a is already in std; r2z just re-exports it.
    try std.testing.expectEqual(
        std.hash.Fnv1a_64.hash(""),
        Fnv1a_64.hash(""),
    );
    // Wyhash seed API.
    try std.testing.expectEqual(
        std.hash.Wyhash.hash(0, "abc"),
        Wyhash.hash(0, "abc"),
    );
}

test "arithmetic primitives: wrapping operations" {
    const max_u32 = std.math.maxInt(u32);
    try std.testing.expectEqual(@as(u32, 0), wrappingAdd(max_u32, @as(u32, 1)));
    try std.testing.expectEqual(max_u32, wrappingSub(@as(u32, 0), @as(u32, 1)));
    try std.testing.expectEqual(@as(u32, 0xffff_fffe), wrappingMul(max_u32, @as(u32, 2)));
}

test "arithmetic primitives: saturating operations" {
    const max_u32 = std.math.maxInt(u32);
    try std.testing.expectEqual(max_u32, saturatingAdd(max_u32, @as(u32, 50)));
    try std.testing.expectEqual(@as(u32, 0), saturatingSub(@as(u32, 10), @as(u32, 50)));
}

test "arithmetic primitives: bitwise rotates and zero counts" {
    const val_u32: u32 = 0x12345678;
    const lz_val: u32 = 0x0000_ffff;
    const tz_val: u32 = 0xffff_0000;
    try std.testing.expectEqual(@as(u32, 0x34567812), rotateLeft(u32, val_u32, 8));
    try std.testing.expectEqual(@as(u32, 0x78123456), rotateRight(u32, val_u32, 8));
    try std.testing.expectEqual(@as(std.math.Log2IntCeil(u32), 16), leadingZeros(lz_val));
    try std.testing.expectEqual(@as(std.math.Log2IntCeil(u32), 16), trailingZeros(tz_val));
}

test "slice utilities: chunks" {
    const data = [_]u32{ 1, 2, 3, 4, 5, 6, 7 };
    var it = chunks(u32, &data, 3);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, it.next().?);
    try std.testing.expectEqualSlices(u32, &.{ 4, 5, 6 }, it.next().?);
    try std.testing.expectEqualSlices(u32, &.{7}, it.next().?);
    try std.testing.expectEqual(@as(?[]const u32, null), it.next());
}

test "slice utilities: windows" {
    const data = [_]u8{ 10, 20, 30, 40 };
    var it = windows(u8, &data, 2);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20 }, it.next().?);
    try std.testing.expectEqualSlices(u8, &.{ 20, 30 }, it.next().?);
    try std.testing.expectEqualSlices(u8, &.{ 30, 40 }, it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "slice utilities: copyFromSlice" {
    const src = [_]u8{ 1, 2, 3, 4 };
    var dest: [4]u8 = undefined;
    copyFromSlice(u8, &dest, &src);
    try std.testing.expectEqualSlices(u8, &src, &dest);
}

test "assertions" {
    assert(true);
    debugAssert(true);
}