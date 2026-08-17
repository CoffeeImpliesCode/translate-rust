const std = @import("std");
const builtin = @import("builtin");

// ── Arithmetic Primitives ──────────────────────────────────────────

/// Wrapping integer addition (`a +% b`).
pub inline fn wrappingAdd(a: anytype, b: anytype) @TypeOf(a) {
    return a +% b;
}

/// Wrapping integer subtraction (`a -% b`).
pub inline fn wrappingSub(a: anytype, b: anytype) @TypeOf(a) {
    return a -% b;
}

/// Wrapping integer multiplication (`a *% b`).
pub inline fn wrappingMul(a: anytype, b: anytype) @TypeOf(a) {
    return a *% b;
}

/// Saturating integer addition (`a +| b`).
pub inline fn saturatingAdd(a: anytype, b: anytype) @TypeOf(a) {
    return a +| b;
}

/// Saturating integer subtraction (`a -| b`).
pub inline fn saturatingSub(a: anytype, b: anytype) @TypeOf(a) {
    return a -| b;
}

/// Bitwise rotate left.
pub inline fn rotateLeft(comptime T: type, val: T, shift: anytype) T {
    return std.math.rotl(T, val, @as(std.math.Log2Int(T), @intCast(shift)));
}

/// Bitwise rotate right.
pub inline fn rotateRight(comptime T: type, val: T, shift: anytype) T {
    return std.math.rotr(T, val, @as(std.math.Log2Int(T), @intCast(shift)));
}

/// Count leading zeros.
pub inline fn leadingZeros(val: anytype) std.math.Log2IntCeil(@TypeOf(val)) {
    return @clz(val);
}

/// Count trailing zeros.
pub inline fn trailingZeros(val: anytype) std.math.Log2IntCeil(@TypeOf(val)) {
    return @ctz(val);
}

// ── Slice Utilities ────────────────────────────────────────────────

/// Iterator yielding non-overlapping chunks of a slice.
pub fn Chunks(comptime T: type) type {
    return struct {
        const Self = @This();

        slice: []const T,
        size: usize,
        index: usize = 0,

        pub fn next(self: *Self) ?[]const T {
            std.debug.assert(self.size > 0);
            if (self.index >= self.slice.len) return null;
            const remaining = self.slice.len - self.index;
            const chunk_len = @min(remaining, self.size);
            const result = self.slice[self.index .. self.index + chunk_len];
            self.index += chunk_len;
            return result;
        }
    };
}

/// Create a non-overlapping chunk iterator over `slice`.
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
            std.debug.assert(self.size > 0);
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
    return .{
        .slice = slice,
        .size = size,
    };
}

/// Copy all elements from `src` into `dest`.
pub inline fn copyFromSlice(comptime T: type, dest: []T, src: []const T) void {
    @memcpy(dest[0..src.len], src);
}

// ── Core Trait Runtimes & Hasher ───────────────────────────────────

/// Generic Hasher trait interface wrapper.
pub const Hasher = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (ctx: *anyopaque, bytes: []const u8) void,
        finish: *const fn (ctx: *const anyopaque) u64,
    };

    pub inline fn write(self: Hasher, bytes: []const u8) void {
        self.vtable.write(self.ptr, bytes);
    }

    pub inline fn finish(self: Hasher) u64 {
        return self.vtable.finish(self.ptr);
    }
};

/// 64-bit FNV-1a Hasher implementation.
pub const FnvHasher = struct {
    state: u64 = 0xcbf29ce484222325,

    pub const FNV_PRIME: u64 = 0x100000001b3;
    pub const FNV_OFFSET_BASIS: u64 = 0xcbf29ce484222325;

    pub fn init() FnvHasher {
        return .{ .state = FNV_OFFSET_BASIS };
    }

    pub fn write(self: *FnvHasher, bytes: []const u8) void {
        for (bytes) |byte| {
            self.state ^= byte;
            self.state = wrappingMul(self.state, FNV_PRIME);
        }
    }

    pub fn finish(self: *const FnvHasher) u64 {
        return self.state;
    }

    pub fn hasher(self: *FnvHasher) Hasher {
        return .{
            .ptr = self,
            .vtable = &.{
                .write = writeErased,
                .finish = finishErased,
            },
        };
    }

    fn writeErased(ctx: *anyopaque, bytes: []const u8) void {
        const self: *FnvHasher = @ptrCast(@alignCast(ctx));
        self.write(bytes);
    }

    fn finishErased(ctx: *const anyopaque) u64 {
        const self: *const FnvHasher = @ptrCast(@alignCast(ctx));
        return self.finish();
    }
};

// ── Panic & Assertion ──────────────────────────────────────────────

/// Runtime assertion (active in all build modes).
pub inline fn assert(cond: bool) void {
    std.debug.assert(cond);
}

/// Debug-only assertion (active only in Debug mode).
pub inline fn debugAssert(cond: bool) void {
    if (builtin.mode == .Debug) {
        std.debug.assert(cond);
    }
}

// ── Unit Tests ─────────────────────────────────────────────────────

test "arithmetic primitives: wrapping operations" {
    const max_u32 = std.math.maxInt(u32);
    try std.testing.expectEqual(@as(u32, 0), wrappingAdd(max_u32, @as(u32, 1)));
    try std.testing.expectEqual(max_u32, wrappingSub(@as(u32, 0), @as(u32, 1)));
    try std.testing.expectEqual(@as(u32, 0xffff_fffe), wrappingMul(max_u32, @as(u32, 2)));

    const min_i32 = std.math.minInt(i32);
    const max_i32 = std.math.maxInt(i32);
    try std.testing.expectEqual(min_i32, wrappingAdd(max_i32, @as(i32, 1)));
    try std.testing.expectEqual(max_i32, wrappingSub(min_i32, @as(i32, 1)));
}

test "arithmetic primitives: saturating operations" {
    const max_u32 = std.math.maxInt(u32);
    try std.testing.expectEqual(max_u32, saturatingAdd(max_u32, @as(u32, 50)));
    try std.testing.expectEqual(@as(u32, 0), saturatingSub(@as(u32, 10), @as(u32, 50)));

    const max_i32 = std.math.maxInt(i32);
    const min_i32 = std.math.minInt(i32);
    try std.testing.expectEqual(max_i32, saturatingAdd(max_i32, @as(i32, 100)));
    try std.testing.expectEqual(min_i32, saturatingSub(min_i32, @as(i32, 100)));
}

test "arithmetic primitives: bitwise rotates and zero counts" {
    const val_u32: u32 = 0x12345678;
    try std.testing.expectEqual(@as(u32, 0x34567812), rotateLeft(u32, val_u32, 8));
    try std.testing.expectEqual(@as(u32, 0x78123456), rotateRight(u32, val_u32, 8));

    const clz_val: u32 = 0x0000_ffff;
    try std.testing.expectEqual(@as(std.math.Log2IntCeil(u32), 16), leadingZeros(clz_val));

    const ctz_val: u32 = 0xffff_0000;
    try std.testing.expectEqual(@as(std.math.Log2IntCeil(u32), 16), trailingZeros(ctz_val));
}

test "slice utilities: chunks" {
    const data = [_]u32{ 1, 2, 3, 4, 5, 6, 7 };
    var it = chunks(u32, &data, 3);

    const c1 = it.next();
    try std.testing.expect(c1 != null);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, c1.?);

    const c2 = it.next();
    try std.testing.expect(c2 != null);
    try std.testing.expectEqualSlices(u32, &.{ 4, 5, 6 }, c2.?);

    const c3 = it.next();
    try std.testing.expect(c3 != null);
    try std.testing.expectEqualSlices(u32, &.{7}, c3.?);

    try std.testing.expectEqual(@as(?[]const u32, null), it.next());
}

test "slice utilities: windows" {
    const data = [_]u8{ 10, 20, 30, 40 };
    var it = windows(u8, &data, 2);

    const w1 = it.next();
    try std.testing.expect(w1 != null);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20 }, w1.?);

    const w2 = it.next();
    try std.testing.expect(w2 != null);
    try std.testing.expectEqualSlices(u8, &.{ 20, 30 }, w2.?);

    const w3 = it.next();
    try std.testing.expect(w3 != null);
    try std.testing.expectEqualSlices(u8, &.{ 30, 40 }, w3.?);

    try std.testing.expectEqual(@as(?[]const u8, null), it.next());

    var it_empty = windows(u8, &[_]u8{}, 2);
    try std.testing.expectEqual(@as(?[]const u8, null), it_empty.next());
}

test "slice utilities: copyFromSlice" {
    const src = [_]u8{ 1, 2, 3, 4 };
    var dest: [4]u8 = undefined;
    copyFromSlice(u8, &dest, &src);
    try std.testing.expectEqualSlices(u8, &src, &dest);
}

test "hasher runtime and FnvHasher" {
    var fnv = FnvHasher.init();
    fnv.write("hello world");
    const h1 = fnv.finish();
    try std.testing.expect(h1 != FnvHasher.FNV_OFFSET_BASIS);

    // Test polymorphic Hasher interface wrapper
    var fnv2 = FnvHasher.init();
    const dyn_hasher = fnv2.hasher();
    dyn_hasher.write("hello world");
    const h2 = dyn_hasher.finish();
    try std.testing.expectEqual(h1, h2);
}

test "assertions" {
    assert(true);
    debugAssert(true);
}
