//! r2z-core (libr2z) — the generic Rust-core → Zig-std compatibility layer.
//!
//! DESIGN RULE: r2z-core maps **Rust language core / core::std** concepts onto
//! Zig 0.16 std and builtins. It knows NOTHING about specific Rust crates
//! (fnv, wyhash, ...) — each translated crate generates its OWN functions and
//! types. The translation is automatic; it must not depend on omniscience
//! about any particular crate's internals.
//!
//! Where Zig std already provides something (hashing, arithmetic operators,
//! `@memcpy`, ...) r2z-core re-exports or aliases it — never reimplements —
//! so translated code is maximally interoperable with the Zig ecosystem.
//! Promoting functionality from very-central Rust *crates* into r2z-core is a
//! deliberate, far-off decision; it does not happen today.

const std = @import("std");
const builtin = @import("builtin");

// ── Rust `core::hash` → Zig `std.hash` (generic, no single-algorithm alias) ─
//
// Hashing is a core concept; Zig std ships FNV-1a, Wyhash, SipHash, XxHash,
// Adler32, Crc32, Murmur, CityHash and autoHash. Translated hashing code uses
// `std.hash.*` directly or via this re-export. We do NOT promote any specific
// algorithm (e.g. `Fnv1a_64` for the fnv crate) into r2z-core.
pub const hash = std.hash;

// ── Rust `core::num` → Zig operators / builtins ──────────────────────────
//
// Rust's inherent integer methods (`.wrapping_add`, `.rotate_left`, ...)
// all override low-level ops. The emitter lowers most to operators and
// builtins directly (`+%`, `*%`, `@clz`, ...); these named shims cover the
// cases where the Rust *method call* must survive as a function.

/// Rust `a.wrapping_add(b)` → `a +% b`.
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

/// Rust `a.count_ones()` → `@popCount`.
pub inline fn countOnes(val: anytype) std.meta.Int(.unsigned, @typeInfo(@TypeOf(val)).int.bits) {
    return @popCount(val);
}

/// Rust `a.pow(n)` → `std.math.pow(T, a, n)` (integer exponentiation).
pub inline fn pow(comptime T: type, base: T, exponent: u32) T {
    return std.math.pow(T, base, exponent);
}

// ── Rust `core::slice` → Zig slice primitives ────────────────────────────

/// Iterator yielding non-overlapping chunks of a slice (Rust `chunks(n)`).
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

/// Create a non-overlapping chunk iterator over `slice`.
pub fn chunks(comptime T: type, slice: []const T, size: usize) Chunks(T) {
    std.debug.assert(size > 0);
    return .{ .slice = slice, .size = size };
}

/// Iterator yielding overlapping sliding windows of a slice (Rust `windows(n)`).
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

/// Create an overlapping sliding window iterator over `slice`.
pub fn windows(comptime T: type, slice: []const T, size: usize) Windows(T) {
    std.debug.assert(size > 0);
    return .{ .slice = slice, .size = size };
}

/// Rust `dest.copy_from_slice(src)` → `@memcpy` (length must match).
pub inline fn copyFromSlice(comptime T: type, dest: []T, src: []const T) void {
    @memcpy(dest[0..src.len], src);
}

/// Rust `slice.get(i)` → bounds-checked optional element. Returns `null`
/// on out of bounds (never panics), unlike unchecked `slice[i]`.
pub inline fn get(comptime T: type, slice: []const T, index: usize) ?T {
    if (index >= slice.len) return null;
    return slice[index];
}

// ── Rust `core::panicking` + `std::assert` → Zig assertions ──────────────

/// Rust `assert!` (active in all build modes).
pub inline fn assert(cond: bool) void {
    std.debug.assert(cond);
}

/// Rust `debug_assert!` (active only in Debug mode). The argument is guarded
/// so it is NOT evaluated in release builds — matches Rust semantics and
/// avoids the Bun debug_assert-regression (prior-work §4 lesson 4).
pub inline fn debugAssert(cond: bool) void {
    if (builtin.mode == .Debug) {
        std.debug.assert(cond);
    }
}

/// Rust `panic!("msg")` → `@panic`.
pub inline fn panic(msg: []const u8) noreturn {
    @panic(msg);
}

// ── Unit Tests ───────────────────────────────────────────────────────────

test "core::num wrapping/saturating arithmetic" {
    const max_u32 = std.math.maxInt(u32);
    try std.testing.expectEqual(@as(u32, 0), wrappingAdd(max_u32, @as(u32, 1)));
    try std.testing.expectEqual(max_u32, wrappingSub(@as(u32, 0), @as(u32, 1)));
    try std.testing.expectEqual(@as(u32, 0xffff_fffe), wrappingMul(max_u32, @as(u32, 2)));
    try std.testing.expectEqual(max_u32, saturatingAdd(max_u32, @as(u32, 50)));
    try std.testing.expectEqual(@as(u32, 0), saturatingSub(@as(u32, 10), @as(u32, 50)));
}

test "core::num bitwise / popcount / pow" {
    const v: u32 = 0x12345678;
    try std.testing.expectEqual(@as(u32, 0x34567812), rotateLeft(u32, v, 8));
    try std.testing.expectEqual(@as(u32, 0x78123456), rotateRight(u32, v, 8));

    const lz: u32 = 0x0000_ffff;
    const tz: u32 = 0xffff_0000;
    try std.testing.expectEqual(@as(std.math.Log2IntCeil(u32), 16), leadingZeros(lz));
    try std.testing.expectEqual(@as(std.math.Log2IntCeil(u32), 16), trailingZeros(tz));

    try std.testing.expectEqual(@as(u32, 3), countOnes(@as(u32, 0b1011)));

    try std.testing.expectEqual(@as(u32, 8), pow(u32, 2, 3));
}

test "core::slice chunks / windows / copy / get" {
    const data = [_]u32{ 1, 2, 3, 4, 5, 6, 7 };
    var it = chunks(u32, &data, 3);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, it.next().?);
    try std.testing.expectEqualSlices(u32, &.{ 4, 5, 6 }, it.next().?);
    try std.testing.expectEqualSlices(u32, &.{7}, it.next().?);
    try std.testing.expectEqual(@as(?[]const u32, null), it.next());

    const bytes = [_]u8{ 10, 20, 30, 40 };
    var w = windows(u8, &bytes, 2);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20 }, w.next().?);
    try std.testing.expectEqualSlices(u8, &.{ 20, 30 }, w.next().?);

    const src = [_]u8{ 1, 2, 3, 4 };
    var dest: [4]u8 = undefined;
    copyFromSlice(u8, &dest, &src);
    try std.testing.expectEqualSlices(u8, &src, &dest);

    try std.testing.expectEqual(@as(?u8, 30), get(u8, &bytes, 2));
    try std.testing.expectEqual(@as(?u8, null), get(u8, &bytes, 99));
}

test "assertions and panic helpers" {
    assert(true);
    debugAssert(true);
}