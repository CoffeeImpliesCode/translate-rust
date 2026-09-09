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

pub const character = @import("character.zig");
pub const memory = @import("memory.zig");
pub const format = @import("format.zig");
pub const alloc = @import("alloc.zig");
pub const io = @import("io.zig");
pub const Result = @import("result.zig").Result;
pub const convert = @import("convert.zig");
pub const option = @import("option.zig");
pub const ops = @import("ops.zig");

test {
    _ = @import("alloc.zig");
    _ = @import("character.zig");
    _ = @import("format.zig");
    _ = @import("io.zig");
    _ = @import("memory.zig");
    _ = @import("result.zig");
    _ = @import("convert.zig");
    _ = @import("option.zig");
    _ = @import("ops.zig");
}

// ── Rust `core::hash` → Zig `std.hash` (generic, no single-algorithm alias) ─
//
// Hashing is a core concept; Zig std ships FNV-1a, Wyhash, SipHash, XxHash,
// Adler32, Crc32, Murmur, CityHash and autoHash. Translated hashing code uses
// `std.hash.*` directly or via this re-export. We do NOT promote any specific
// algorithm (e.g. `Fnv1a_64` for the fnv crate) into r2z-core.
pub const hash = std.hash;

// ── Rust `core::hash::Hasher` trait → Zig interface + FNV-1a runtime ─────
//
// Rust's `core::hash` exposes a `Hasher` trait. r2z-core provides a small,
// allocation-free trait interface (`Hasher`) plus one concrete, self-contained
// runtime (`FnvHasher`) that translated hashing code can call directly when
// the original Rust crate relied on a fixed algorithm. This pair is part of
// the r2z-core contract: a `Hasher` that can `write` bytes and `finish` u64.

/// Generic Hasher trait-interface wrapper (type-erased, allocation-free).
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

/// 64-bit FNV-1a hasher: `write([]const u8)` feeds bytes, `finish() u64`
/// returns the digest. Zero-allocation, stateless.
pub const FnvHasher = struct {
    state: u64 = FNV_OFFSET_BASIS,

    pub const FNV_PRIME: u64 = 0x100000001b3;
    pub const FNV_OFFSET_BASIS: u64 = 0xcbf29ce484222325;

    pub fn init() FnvHasher {
        return .{ .state = FNV_OFFSET_BASIS };
    }

    pub const default = init;

    pub fn write(self: *FnvHasher, bytes: []const u8) void {
        for (bytes) |byte| {
            self.state ^= byte;
            self.state = wrappingMul(self.state, FNV_PRIME);
        }
    }

    pub fn finish(self: *const FnvHasher) u64 {
        return self.state;
    }

    /// Adapt this concrete hasher to the erased `Hasher` interface.
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

/// Rust `BuildHasherDefault<H>`: a zero-sized builder that constructs a
/// fresh `H` through its default constructor for every request.
pub fn BuildHasherDefault(comptime H: type) type {
    return struct {
        const Self = @This();

        pub fn new() Self {
            return .{};
        }

        pub fn default() Self {
            return .{};
        }

        pub fn build_hasher(self: Self) H {
            _ = self;
            return H.default();
        }
    };
}
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
pub inline fn rotateLeft(comptime T: type, val: T, shift: u32) T {
    const Unsigned = @Int(.unsigned, @bitSizeOf(T));
    const unsigned_value: Unsigned = @bitCast(val);
    const rotated: Unsigned = std.math.rotl(Unsigned, unsigned_value, shift);
    return @bitCast(rotated);
}

/// Rust `a.rotate_right(shift)` → `std.math.rotr`.
pub inline fn rotateRight(comptime T: type, val: T, shift: u32) T {
    const Unsigned = @Int(.unsigned, @bitSizeOf(T));
    const unsigned_value: Unsigned = @bitCast(val);
    const rotated: Unsigned = std.math.rotr(Unsigned, unsigned_value, shift);
    return @bitCast(rotated);
}

/// Rust `a.checked_add(b)` → null on overflow.
pub inline fn checkedAdd(comptime T: type, a: T, b: T) ?T {
    const result = @addWithOverflow(a, b);
    if (result[1] != 0) return null;
    return result[0];
}

/// Rust `a.checked_sub(b)` → null on overflow.
pub inline fn checkedSub(comptime T: type, a: T, b: T) ?T {
    const result = @subWithOverflow(a, b);
    if (result[1] != 0) return null;
    return result[0];
}

/// Rust `a.checked_mul(b)` → null on overflow.
pub inline fn checkedMul(comptime T: type, a: T, b: T) ?T {
    const result = @mulWithOverflow(a, b);
    if (result[1] != 0) return null;
    return result[0];
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

/// Iterator yielding only complete, non-overlapping chunks of a slice
/// (Rust `chunks_exact(n)`). The final partial chunk is retained separately
/// and remains available through `remainder()` regardless of iterator progress.
pub fn ChunksExact(comptime T: type) type {
    return struct {
        const Self = @This();

        slice: []const T,
        size: usize,
        remainder_slice: []const T,
        index: usize = 0,

        pub fn next(self: *Self) ?[]const T {
            if (self.slice.len - self.index < self.size) return null;
            const result = self.slice[self.index .. self.index + self.size];
            self.index += self.size;
            return result;
        }

        /// Return the unconsumed partial tail from iterator creation.
        pub fn remainder(self: *const Self) []const T {
            return self.remainder_slice;
        }
    };
}

/// Create an exact-size chunk iterator over `slice`.
pub fn chunksExact(slice: anytype, size: usize) ChunksExact(std.meta.Elem(@TypeOf(slice))) {
    std.debug.assert(size > 0);
    const full_len = slice.len - slice.len % size;
    return .{
        .slice = slice[0..full_len],
        .size = size,
        .remainder_slice = slice[full_len..],
    };
}

/// Split `slice` at `mid` (Rust `slice.split_at(mid)`).
/// Zig's bounds-checked slicing preserves Rust's panic-on-invalid-index
/// contract when `mid > slice.len`.
pub fn splitAt(slice: anytype, mid: usize) struct {
    []const std.meta.Elem(@TypeOf(slice)),
    []const std.meta.Elem(@TypeOf(slice)),
} {
    return .{ slice[0..mid], slice[mid..] };
}

pub fn splitFirst(slice: anytype) ?struct {
    *const std.meta.Elem(@TypeOf(slice)),
    []const std.meta.Elem(@TypeOf(slice)),
} {
    if (slice.len == 0) return null;
    return .{ &slice[0], slice[1..] };
}

pub fn rangeContains(start: anytype, end: @TypeOf(start), value: anytype, comptime inclusive: bool) bool {
    return start <= value and if (inclusive) value <= end else value < end;
}

/// Return the stable partial tail of a `chunksExact` iterator.
pub inline fn chunksExactRemainder(iterator: anytype) @TypeOf(iterator.remainder()) {
    return iterator.remainder();
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
    if (dest.len != src.len) @panic("copy_from_slice requires equal lengths");
    @memcpy(dest, src);
}

/// Rust `slice.get(i)` → bounds-checked optional element. Returns `null`
/// on out of bounds (never panics), unlike unchecked `slice[i]`.
pub inline fn get(comptime T: type, slice: []const T, index: usize) ?T {
    if (index >= slice.len) return null;
    return slice[index];
}

// ── Rust `core::iter` → Zig iterator protocol ────────────────────────────
//
// Concrete iterators own their cursor state by value. Slice iterators borrow
// caller-owned storage and return pointers so the borrow is visible in Zig.

/// `(lower_bound, upper_bound)` returned by `size_hint`.
pub const SizeHint = struct { usize, ?usize };

/// Element type yielded by an iterator: unwraps the optional return of its
/// `next(self: *Self) ?T` method.
fn Elem(comptime Base: type) type {
    const ret = @typeInfo(@TypeOf(Base.next)).@"fn".return_type.?;
    return switch (@typeInfo(ret)) {
        .optional => |o| o.child,
        else => ret,
    };
}

/// Iterator yielding borrowed elements of a slice (Rust `slice.iter()`).
pub fn SliceIter(comptime T: type) type {
    return struct {
        const Self = @This();

        slice: []const T,
        front_index: usize = 0,
        back_index: usize,

        pub fn next(self: *Self) ?*const T {
            if (self.front_index >= self.back_index) return null;
            const result = &self.slice[self.front_index];
            self.front_index += 1;
            return result;
        }

        pub fn next_back(self: *Self) ?*const T {
            if (self.front_index >= self.back_index) return null;
            self.back_index -= 1;
            return &self.slice[self.back_index];
        }

        pub fn clone(self: *const Self) Self {
            return self.*;
        }

        pub fn as_slice(self: *const Self) []const T {
            return self.slice[self.front_index..self.back_index];
        }

        pub fn len(self: *const Self) usize {
            return self.back_index - self.front_index;
        }

        pub fn size_hint(self: *const Self) SizeHint {
            const count = self.len();
            return .{ count, count };
        }

        pub fn nth(self: *Self, index: usize) ?*const T {
            if (index >= self.len()) {
                self.front_index = self.back_index;
                return null;
            }
            self.front_index += index;
            return self.next();
        }
    };
}

/// Create a borrowed slice iterator (mutable `[]T` coerces implicitly).
pub fn sliceIter(comptime T: type, slice: []const T) SliceIter(T) {
    return .{ .slice = slice, .back_index = slice.len };
}

/// Iterator yielding disjoint mutable pointers into a caller-owned slice.
pub fn SliceIterMut(comptime T: type) type {
    return struct {
        const Self = @This();

        slice: []T,
        front_index: usize = 0,
        back_index: usize,

        pub fn next(self: *Self) ?*T {
            if (self.front_index >= self.back_index) return null;
            const result = &self.slice[self.front_index];
            self.front_index += 1;
            return result;
        }

        pub fn next_back(self: *Self) ?*T {
            if (self.front_index >= self.back_index) return null;
            self.back_index -= 1;
            return &self.slice[self.back_index];
        }

        pub fn as_slice(self: *const Self) []const T {
            return self.slice[self.front_index..self.back_index];
        }

        pub fn len(self: *const Self) usize {
            return self.back_index - self.front_index;
        }

        pub fn size_hint(self: *const Self) SizeHint {
            const count = self.len();
            return .{ count, count };
        }

        pub fn nth(self: *Self, index: usize) ?*T {
            if (index >= self.len()) {
                self.front_index = self.back_index;
                return null;
            }
            self.front_index += index;
            return self.next();
        }
    };
}

/// Create an iterator yielding disjoint mutable pointers into `slice`.
pub fn sliceIterMut(comptime T: type, slice: []T) SliceIterMut(T) {
    return .{ .slice = slice, .back_index = slice.len };
}

/// Half-open range iterator over `usize` (Rust `start..end`).
pub const Range = struct {
    const Self = @This();

    start: usize,
    end: usize,

    pub fn init(start: usize, end: usize) Self {
        return .{ .start = start, .end = end };
    }

    pub fn next(self: *Self) ?usize {
        if (self.start >= self.end) return null;
        const result = self.start;
        self.start += 1;
        return result;
    }

    pub fn next_back(self: *Self) ?usize {
        if (self.start >= self.end) return null;
        self.end -= 1;
        return self.end;
    }

    pub fn clone(self: *const Self) Self {
        return self.*;
    }

    pub fn len(self: *const Self) usize {
        if (self.start >= self.end) return 0;
        return self.end - self.start;
    }

    pub fn size_hint(self: *const Self) SizeHint {
        const count = self.len();
        return .{ count, count };
    }

    pub fn nth(self: *Self, index: usize) ?usize {
        if (index >= self.len()) {
            self.start = self.end;
            return null;
        }
        self.start += index;
        return self.next();
    }
};

/// Create a half-open `usize` range.
pub fn range(start: usize, end: usize) Range {
    return Range.init(start, end);
}

/// Adapter applying `F` to every element (Rust `iter.map(F)`).
pub fn Map(comptime Base: type, comptime F: anytype, comptime Out: type) type {
    return struct {
        const Self = @This();

        base: Base,

        pub fn next(self: *Self) ?Out {
            const el = self.base.next() orelse return null;
            return F(el);
        }
    };
}

/// Adapter keeping only elements where `F` returns true (Rust `iter.filter(F)`).
pub fn Filter(comptime Base: type, comptime F: anytype) type {
    return struct {
        const Self = @This();

        base: Base,

        pub fn next(self: *Self) ?Elem(Base) {
            while (self.base.next()) |el| {
                if (F(el)) return el;
            }
            return null;
        }
    };
}

/// Adapter ending after at most `n` elements (Rust `iter.take(n)`).
pub fn Take(comptime Base: type) type {
    return struct {
        const Self = @This();

        base: Base,
        remaining: usize,

        pub fn next(self: *Self) ?Elem(Base) {
            if (self.remaining == 0) return null;
            self.remaining -= 1;
            const result = self.base.next() orelse {
                self.remaining = 0;
                return null;
            };
            return result;
        }
    };
}

/// Adapter yielding every `step`th source element (Rust `iter.step_by(step)`).
pub fn StepBy(comptime Base: type) type {
    return struct {
        const Self = @This();

        base: Base,
        step: usize,

        pub fn next(self: *Self) ?Elem(Base) {
            std.debug.assert(self.step > 0);
            const result = self.base.next() orelse return null;
            var skipped: usize = 1;
            while (skipped < self.step) : (skipped += 1) {
                if (self.base.next() == null) break;
            }
            return result;
        }

        /// Consume the source tail that is not part of the stepped sequence.
        pub fn next_back(self: *Self) ?Elem(Base) {
            std.debug.assert(self.step > 0);
            const hint = self.base.size_hint();
            if (hint[0] == 0) return null;
            const discarded = (hint[0] - 1) % self.step;
            var count: usize = 0;
            while (count < discarded) : (count += 1) {
                if (self.base.next_back() == null) return null;
            }
            return self.base.next_back();
        }

        pub fn nth(self: *Self, index: usize) ?Elem(Base) {
            var skipped: usize = 0;
            while (skipped < index) : (skipped += 1) {
                if (self.next() == null) return null;
            }
            return self.next();
        }

        pub fn clone(self: *const Self) Self {
            return self.*;
        }

        pub fn len(self: *const Self) usize {
            return self.size_hint()[0];
        }

        pub fn size_hint(self: *const Self) SizeHint {
            std.debug.assert(self.step > 0);
            const hint = self.base.size_hint();
            const lower = if (hint[0] == 0) 0 else (hint[0] - 1) / self.step + 1;
            const upper = if (hint[1]) |value|
                if (value == 0) @as(?usize, 0) else (value - 1) / self.step + 1
            else
                null;
            return .{ lower, upper };
        }
    };
}

/// Create a nonzero-stride adapter.
pub fn stepBy(iter: anytype, step: usize) StepBy(@TypeOf(iter)) {
    std.debug.assert(step > 0);
    return .{ .base = iter, .step = step };
}

/// Adapter discarding the first `n` source elements (Rust `iter.skip(n)`).
pub fn Skip(comptime Base: type) type {
    return struct {
        const Self = @This();

        base: Base,
        remaining: usize,

        pub fn next(self: *Self) ?Elem(Base) {
            while (self.remaining != 0) {
                if (self.base.next() == null) {
                    self.remaining = 0;
                    return null;
                }
                self.remaining -= 1;
            }
            return self.base.next();
        }

        pub fn next_back(self: *Self) ?Elem(Base) {
            while (self.remaining != 0) {
                if (self.base.next() == null) {
                    self.remaining = 0;
                    return null;
                }
                self.remaining -= 1;
            }
            return self.base.next_back();
        }

        pub fn nth(self: *Self, index: usize) ?Elem(Base) {
            var skipped: usize = 0;
            while (skipped < index) : (skipped += 1) {
                if (self.next() == null) return null;
            }
            return self.next();
        }

        pub fn clone(self: *const Self) Self {
            return self.*;
        }

        pub fn len(self: *const Self) usize {
            return self.size_hint()[0];
        }

        pub fn size_hint(self: *const Self) SizeHint {
            const hint = self.base.size_hint();
            const lower_skip = @min(hint[0], self.remaining);
            const lower = hint[0] - lower_skip;
            const upper = if (hint[1]) |value|
                @as(?usize, value - @min(value, self.remaining))
            else
                null;
            return .{ lower, upper };
        }
    };
}

/// Create a skip adapter.
pub fn skip(iter: anytype, count: usize) Skip(@TypeOf(iter)) {
    return .{ .base = iter, .remaining = count };
}

/// Adapter pairing items from two sources until either is exhausted.
pub fn Zip(comptime Left: type, comptime Right: type) type {
    return struct {
        const Self = @This();
        pub const Item = struct { Elem(Left), Elem(Right) };

        left: Left,
        right: Right,

        pub fn next(self: *Self) ?Item {
            const left = self.left.next() orelse return null;
            const right = self.right.next() orelse return null;
            return .{ left, right };
        }

        /// Trim an unequal source tail before taking a pair from the back.
        pub fn next_back(self: *Self) ?Item {
            const left_len = self.left.len();
            const right_len = self.right.len();
            if (left_len > right_len) {
                var discarded: usize = 0;
                while (discarded < left_len - right_len) : (discarded += 1) {
                    if (self.left.next_back() == null) return null;
                }
            } else if (right_len > left_len) {
                var discarded: usize = 0;
                while (discarded < right_len - left_len) : (discarded += 1) {
                    if (self.right.next_back() == null) return null;
                }
            }
            const left = self.left.next_back();
            const right = self.right.next_back();
            return .{ left orelse return null, right orelse return null };
        }

        pub fn nth(self: *Self, index: usize) ?Item {
            var skipped: usize = 0;
            while (skipped < index) : (skipped += 1) {
                if (self.next() == null) return null;
            }
            return self.next();
        }

        pub fn clone(self: *const Self) Self {
            return self.*;
        }

        pub fn len(self: *const Self) usize {
            return @min(self.left.len(), self.right.len());
        }

        pub fn size_hint(self: *const Self) SizeHint {
            const left_hint = self.left.size_hint();
            const right_hint = self.right.size_hint();
            const lower = @min(left_hint[0], right_hint[0]);
            const upper: ?usize = if (left_hint[1]) |left_upper|
                if (right_hint[1]) |right_upper| @min(left_upper, right_upper) else left_upper
            else
                right_hint[1];
            return .{ lower, upper };
        }
    };
}

/// Create a zip adapter.
pub fn zip(left: anytype, right: anytype) Zip(@TypeOf(left), @TypeOf(right)) {
    return .{ .left = left, .right = right };
}

/// Adapter adding a zero-based index (Rust `iter.enumerate()`).
pub fn Enumerate(comptime Base: type) type {
    return struct {
        const Self = @This();
        pub const Item = struct { usize, Elem(Base) };

        base: Base,
        index: usize = 0,

        pub fn next(self: *Self) ?Item {
            const element = self.base.next() orelse return null;
            const result = Item{ self.index, element };
            self.index += 1;
            return result;
        }

        pub fn next_back(self: *Self) ?Item {
            const remaining = self.base.len();
            if (remaining == 0) return null;
            const element = self.base.next_back() orelse return null;
            return .{ self.index + remaining - 1, element };
        }

        pub fn nth(self: *Self, index: usize) ?Item {
            var skipped: usize = 0;
            while (skipped < index) : (skipped += 1) {
                if (self.next() == null) return null;
            }
            return self.next();
        }

        pub fn clone(self: *const Self) Self {
            return self.*;
        }

        pub fn len(self: *const Self) usize {
            return self.base.len();
        }

        pub fn size_hint(self: *const Self) SizeHint {
            return self.base.size_hint();
        }
    };
}

/// Create an enumerate adapter.
pub fn enumerate(iter: anytype) Enumerate(@TypeOf(iter)) {
    return .{ .base = iter };
}

/// Adapter reversing a double-ended source (Rust `iter.rev()`).
pub fn Rev(comptime Base: type) type {
    return struct {
        const Self = @This();

        base: Base,

        pub fn next(self: *Self) ?Elem(Base) {
            return self.base.next_back();
        }

        pub fn next_back(self: *Self) ?Elem(Base) {
            return self.base.next();
        }

        pub fn nth(self: *Self, index: usize) ?Elem(Base) {
            var skipped: usize = 0;
            while (skipped < index) : (skipped += 1) {
                if (self.next() == null) return null;
            }
            return self.next();
        }

        pub fn clone(self: *const Self) Self {
            return self.*;
        }

        pub fn len(self: *const Self) usize {
            return self.base.len();
        }

        pub fn size_hint(self: *const Self) SizeHint {
            return self.base.size_hint();
        }
    };
}

/// Create a reverse adapter.
pub fn rev(iter: anytype) Rev(@TypeOf(iter)) {
    return .{ .base = iter };
}

/// Consume `iter` until `F` returns true (Rust `iter.any(F)`).
pub fn any(iter: anytype, comptime F: anytype) bool {
    var iterator = iter;
    while (iterator.next()) |element| {
        if (F(element)) return true;
    }
    return false;
}

/// Wrap `iter` so each element becomes `F(el)`.
pub fn map(iter: anytype, comptime F: anytype, comptime Out: type) Map(@TypeOf(iter), F, Out) {
    return .{ .base = iter };
}

/// Wrap `iter`, keeping only the elements for which `F(el)` is true.
pub fn filter(iter: anytype, comptime F: anytype) Filter(@TypeOf(iter), F) {
    return .{ .base = iter };
}

/// Wrap `iter`, ending after at most `n` elements.
pub fn take(iter: anytype, n: usize) Take(@TypeOf(iter)) {
    return .{ .base = iter, .remaining = n };
}

/// Consume `iter`, accumulating `F(acc, el)` starting from `init`.
pub fn fold(iter: anytype, comptime Acc: type, init: Acc, comptime F: anytype) Acc {
    var acc = init;
    var it = iter;
    while (it.next()) |el| {
        acc = F(acc, el);
    }
    return acc;
}

/// Type-erased iterator box: a `next` function pointer over an `*anyopaque`
/// context, giving one uniform iterator type.
pub fn Iterator(comptime T: type) type {
    return struct {
        const Self = @This();

        next_fn: *const fn (context: *anyopaque) ?T,
        context: *anyopaque,

        pub fn init(next_fn: *const fn (context: *anyopaque) ?T, context: *anyopaque) Self {
            return .{ .next_fn = next_fn, .context = context };
        }

        pub inline fn next(self: *Self) ?T {
            return self.next_fn(self.context);
        }

        pub fn map(self: Self, comptime F: anytype, comptime Out: type) Map(Self, F, Out) {
            return .{ .base = self };
        }

        pub fn filter(self: Self, comptime F: anytype) Filter(Self, F) {
            return .{ .base = self };
        }

        pub fn take(self: Self, n: usize) Take(Self) {
            return .{ .base = self, .remaining = n };
        }

        pub fn fold(self: Self, comptime Acc: type, acc0: Acc, comptime F: anytype) Acc {
            var acc = acc0;
            var it = self;
            while (it.next()) |el| {
                acc = F(acc, el);
            }
            return acc;
        }
    };
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

test "core::num checked arithmetic rejects signed overflow and unsigned underflow" {
    try std.testing.expectEqual(@as(?u8, 255), checkedAdd(u8, 254, 1));
    try std.testing.expectEqual(@as(?u8, null), checkedAdd(u8, 255, 1));
    try std.testing.expectEqual(@as(?i8, null), checkedAdd(i8, 127, 1));

    try std.testing.expectEqual(@as(?u8, null), checkedSub(u8, 0, 1));
    try std.testing.expectEqual(@as(?i8, null), checkedSub(i8, -128, 1));
    try std.testing.expectEqual(@as(?i8, -127), checkedSub(i8, -128, -1));

    try std.testing.expectEqual(@as(?u8, null), checkedMul(u8, 16, 16));
    try std.testing.expectEqual(@as(?i8, null), checkedMul(i8, 64, 2));
    try std.testing.expectEqual(@as(?i8, -64), checkedMul(i8, -32, 2));
}

test "core::num bitwise / popcount / pow" {
    const v: u32 = 0x12345678;
    try std.testing.expectEqual(@as(u32, 0x34567812), rotateLeft(u32, v, 8));
    try std.testing.expectEqual(@as(u32, 0x78123456), rotateRight(u32, v, 8));
    try std.testing.expectEqual(@as(u32, 1), rotateLeft(u32, 1, 32));
    try std.testing.expectEqual(@as(u32, 1), rotateRight(u32, 1, 32));
    try std.testing.expectEqual(@as(u32, 2), rotateLeft(u32, 1, 65));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), rotateRight(u32, 1, 65));

    const signed_bits: i32 = @bitCast(@as(u32, 0x8000_0001));
    const signed_left: i32 = @bitCast(@as(u32, 0x0000_0003));
    const signed_right: i32 = @bitCast(@as(u32, 0xc000_0000));
    try std.testing.expectEqual(signed_left, rotateLeft(i32, signed_bits, 1));
    try std.testing.expectEqual(signed_right, rotateRight(i32, signed_bits, 1));

    const lz: u32 = 0x0000_ffff;
    const tz: u32 = 0xffff_0000;
    try std.testing.expectEqual(@as(std.math.Log2IntCeil(u32), 16), leadingZeros(lz));

    try std.testing.expectEqual(@as(std.math.Log2IntCeil(u32), 16), trailingZeros(tz));

    try std.testing.expectEqual(@as(u32, 3), countOnes(@as(u32, 0b1011)));

    try std.testing.expectEqual(@as(u32, 8), pow(u32, 2, 3));
}
test "core::slice chunksExact preserves full chunks and remainder" {
    const data = [_]u8{ 1, 2, 3, 4, 5 };
    var it = chunksExact(&data, 2);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, it.next().?);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4 }, it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
    try std.testing.expectEqualSlices(u8, &.{5}, it.remainder());

    const complete = [_]u8{ 6, 7, 8, 9 };
    var complete_it = chunksExact(&complete, 2);
    try std.testing.expectEqualSlices(u8, &.{ 6, 7 }, complete_it.next().?);
    try std.testing.expectEqualSlices(u8, &.{ 8, 9 }, complete_it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), complete_it.next());
    try std.testing.expectEqual(@as(usize, 0), complete_it.remainder().len);

    const empty = [_]u8{};
    var empty_it = chunksExact(&empty, 3);
    try std.testing.expectEqual(@as(?[]const u8, null), empty_it.next());
    try std.testing.expectEqual(@as(usize, 0), empty_it.remainder().len);
}

test "core::slice splitAt returns two bounds-checked slices" {
    const data = [_]u8{ 10, 20, 30, 40 };
    const parts = splitAt(&data, 2);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20 }, parts[0]);
    try std.testing.expectEqualSlices(u8, &.{ 30, 40 }, parts[1]);
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

test "core::hash Hasher / FnvHasher" {
    // Known FNV-1a 64-bit vectors.
    var empty = FnvHasher.init();
    empty.write("");
    try std.testing.expectEqual(@as(u64, 0xcbf29ce484222325), empty.finish());

    var a = FnvHasher.init();
    a.write("a");
    try std.testing.expectEqual(@as(u64, 0xaf63dc4c8601ec8c), a.finish());

    // Deterministic across writes; not the offset basis for non-empty input.
    var fnv = FnvHasher.init();
    fnv.write("hello world");
    const h1 = fnv.finish();
    try std.testing.expect(h1 != FnvHasher.FNV_OFFSET_BASIS);

    // Erased Hasher interface must match the concrete hasher.
    var fnv2 = FnvHasher.init();
    const dyn_hasher = fnv2.hasher();
    dyn_hasher.write("hello world");
    try std.testing.expectEqual(h1, dyn_hasher.finish());

    // `default` aliases the fresh offset-basis constructor, and each builder
    // call must create an independent hasher.
    var default_hasher = FnvHasher.default();
    try std.testing.expectEqual(FnvHasher.FNV_OFFSET_BASIS, default_hasher.finish());
    const Builder = BuildHasherDefault(FnvHasher);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(Builder));
    const builder = Builder.new();
    var built_a = builder.build_hasher();
    var built_b = Builder.default().build_hasher();
    built_a.write("a");
    try std.testing.expectEqual(@as(u64, 0xaf63dc4c8601ec8c), built_a.finish());
    try std.testing.expectEqual(FnvHasher.FNV_OFFSET_BASIS, built_b.finish());
}

// Test-only comptime functions shared by the `core::iter` tests below.
const iterfns = struct {
    const IsEven = struct {
        fn apply(x: u32) bool {
            return x % 2 == 0;
        }
    };
    const IsEvenRef = struct {
        fn apply(x: *const u32) bool {
            return x.* % 2 == 0;
        }
    };
    const Square = struct {
        fn apply(x: u32) u64 {
            return @as(u64, x) * x;
        }
    };
    const SquareRef = struct {
        fn apply(x: *const u32) u64 {
            return @as(u64, x.*) * x.*;
        }
    };
    const SumSquares = struct {
        fn apply(acc: u64, x: u32) u64 {
            return acc + Square.apply(x);
        }
    };
    const SumSquaresRef = struct {
        fn apply(acc: u64, x: *const u32) u64 {
            return acc + SquareRef.apply(x);
        }
    };
    const BoxNext = struct {
        fn next(context: *anyopaque) ?u32 {
            const iterator: *SliceIter(u32) = @ptrCast(@alignCast(context));
            const item = iterator.next() orelse return null;
            return item.*;
        }
    };
};

test "core::iter sliceIter produces borrowed elements" {
    const data = [_]u8{ 4, 5, 6 };
    var it = sliceIter(u8, &data);
    try std.testing.expectEqual(@as(u8, 4), it.next().?.*);
    try std.testing.expectEqual(@as(u8, 5), it.next().?.*);
    try std.testing.expectEqual(@as(u8, 6), it.next().?.*);
    try std.testing.expect(it.next() == null);
}

test "core::iter map/filter chains and take" {
    const data = [_]u32{ 1, 2, 3, 4, 5, 6 };

    // filter → map: evens squared = 4, 16, 36.
    var it = map(filter(sliceIter(u32, &data), iterfns.IsEvenRef.apply), iterfns.SquareRef.apply, u64);
    try std.testing.expectEqual(@as(?u64, 4), it.next());
    try std.testing.expectEqual(@as(?u64, 16), it.next());
    try std.testing.expectEqual(@as(?u64, 36), it.next());
    try std.testing.expectEqual(@as(?u64, null), it.next());

    // take after filter yields at most n.
    var limited = take(filter(sliceIter(u32, &data), iterfns.IsEvenRef.apply), 2);
    try std.testing.expectEqual(@as(u32, 2), limited.next().?.*);
    try std.testing.expectEqual(@as(u32, 4), limited.next().?.*);
    try std.testing.expect(limited.next() == null);

    // take(0) terminates immediately without consuming the source.
    var none = take(sliceIter(u32, &data), 0);
    try std.testing.expect(none.next() == null);
}

test "core::iter fold accumulates" {
    const data = [_]u32{ 1, 2, 3, 4, 5, 6 };

    // Sum of squares of all elements: 1+4+9+16+25+36 = 91.
    try std.testing.expectEqual(@as(u64, 91), fold(sliceIter(u32, &data), u64, 0, iterfns.SumSquaresRef.apply));

    // Sum of squares of evens: 4+16+36 = 56.
    try std.testing.expectEqual(@as(u64, 56), fold(filter(sliceIter(u32, &data), iterfns.IsEvenRef.apply), u64, 0, iterfns.SumSquaresRef.apply));

    // Mutable slice `[]T` coerces into the `[]const T` parameter.
    var mut = [_]u8{ 1, 2, 3 };
    try std.testing.expectEqual(@as(usize, 3), fold(sliceIter(u8, &mut), usize, 0, struct {
        fn apply(acc: usize, _: *const u8) usize {
            return acc + 1;
        }
    }.apply));
}

test "core::iter type-erased Iterator box" {
    const data = [_]u32{ 1, 2, 3, 4, 5, 6 };

    var ctx_a = sliceIter(u32, &data);
    var boxed: Iterator(u32) = Iterator(u32).init(iterfns.BoxNext.next, &ctx_a);
    try std.testing.expectEqual(@as(?u32, 1), boxed.next());
    try std.testing.expectEqual(@as(?u32, 2), boxed.next());

    // Adapter methods on the box; base state (context pointer) is shared.
    var evens = boxed.filter(iterfns.IsEven.apply);
    try std.testing.expectEqual(@as(?u32, 4), evens.next());
    try std.testing.expectEqual(@as(?u32, 6), evens.next());
    try std.testing.expectEqual(@as(?u32, null), evens.next());

    // fold straight off a fresh box: sum of squares = 91.
    var ctx_b = sliceIter(u32, &data);
    var b = Iterator(u32).init(iterfns.BoxNext.next, &ctx_b);
    try std.testing.expectEqual(@as(u64, 91), b.fold(u64, 0, iterfns.SumSquares.apply));
}

test "core::iter slice iterator borrows and clones cursor state" {
    const data = [_]u8{ 10, 20, 30, 40 };
    var iterator = sliceIter(u8, &data);

    try std.testing.expectEqual(@as(usize, 4), iterator.len());
    try std.testing.expectEqualSlices(u8, &data, iterator.as_slice());
    const first = iterator.next().?;
    try std.testing.expect(first == &data[0]);
    try std.testing.expectEqual(@as(u8, 10), first.*);

    const hint = iterator.size_hint();
    try std.testing.expectEqual(@as(usize, 3), hint[0]);
    try std.testing.expectEqual(@as(?usize, 3), hint[1]);

    var cloned = iterator.clone();
    try std.testing.expectEqual(@as(u8, 20), cloned.next().?.*);
    try std.testing.expectEqual(@as(u8, 30), cloned.next().?.*);
    try std.testing.expectEqual(@as(u8, 20), iterator.next().?.*);
    try std.testing.expectEqualSlices(u8, &.{ 30, 40 }, iterator.as_slice());
    try std.testing.expectEqualSlices(u8, &.{40}, cloned.as_slice());
}

test "core::iter slice iterator mixes both ends and exhausts through nth" {
    const data = [_]u8{ 1, 2, 3, 4, 5 };
    var iterator = sliceIter(u8, &data);

    try std.testing.expectEqual(@as(u8, 1), iterator.next().?.*);
    try std.testing.expectEqual(@as(u8, 5), iterator.next_back().?.*);
    try std.testing.expectEqual(@as(u8, 3), iterator.nth(1).?.*);
    try std.testing.expectEqual(@as(u8, 4), iterator.next_back().?.*);
    try std.testing.expect(iterator.next() == null);
    try std.testing.expect(iterator.next_back() == null);

    var exhausted = sliceIter(u8, &data);
    try std.testing.expect(exhausted.nth(data.len) == null);
    try std.testing.expectEqual(@as(usize, 0), exhausted.len());
    try std.testing.expectEqual(@as(usize, 0), exhausted.as_slice().len);
    try std.testing.expect(exhausted.next() == null);
}

test "core::iter mutable slice iterator yields disjoint elements" {
    var data = [_]u8{ 1, 2, 3, 4 };
    var iterator = sliceIterMut(u8, &data);

    const first = iterator.next().?;
    const last = iterator.next_back().?;
    try std.testing.expect(first != last);
    first.* = 10;
    last.* = 40;

    const second = iterator.next().?;
    const third = iterator.next_back().?;
    try std.testing.expect(second != third);
    second.* = 20;
    third.* = 30;

    try std.testing.expect(iterator.next() == null);
    try std.testing.expect(iterator.next_back() == null);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40 }, &data);
}

test "core::iter range stepBy and skip preserve cursor semantics" {
    var values = range(3, 8);
    try std.testing.expectEqual(@as(?usize, 3), values.next());
    try std.testing.expectEqual(@as(?usize, 7), values.next_back());
    try std.testing.expectEqual(@as(?usize, 5), values.nth(1));
    try std.testing.expectEqual(@as(?usize, 6), values.next());
    try std.testing.expectEqual(@as(?usize, null), values.next());

    var empty = range(4, 2);
    try std.testing.expectEqual(@as(usize, 0), empty.len());
    try std.testing.expectEqual(@as(?usize, null), empty.next());
    try std.testing.expectEqual(@as(?usize, null), empty.next_back());

    var exhausted = range(0, 3);
    try std.testing.expectEqual(@as(?usize, null), exhausted.nth(3));
    try std.testing.expectEqual(@as(?usize, null), exhausted.next());

    var stepped = stepBy(range(0, 8), 3);
    try std.testing.expectEqual(@as(?usize, 0), stepped.next());
    try std.testing.expectEqual(@as(?usize, 3), stepped.next());
    try std.testing.expectEqual(@as(?usize, 6), stepped.next());
    try std.testing.expectEqual(@as(?usize, null), stepped.next());
    try std.testing.expectEqual(@as(?usize, null), stepped.next());

    var skipped = skip(range(0, 5), 2);
    try std.testing.expectEqual(@as(?usize, 2), skipped.next());
    try std.testing.expectEqual(@as(?usize, 3), skipped.next());
    try std.testing.expectEqual(@as(?usize, 4), skipped.next());
    try std.testing.expectEqual(@as(?usize, null), skipped.next());
}

test "core::iter zip preserves left-first polling after exhaustion" {
    const Probe = struct {
        const Self = @This();

        label: u8,
        values: []const usize,
        index: usize = 0,
        log: *[8]u8,
        log_len: *usize,
        yielded: *usize,

        fn next(self: *Self) ?usize {
            self.log[self.log_len.*] = self.label;
            self.log_len.* += 1;
            if (self.index >= self.values.len) return null;
            const value = self.values[self.index];
            self.index += 1;
            self.yielded.* += 1;
            return value;
        }
    };

    var log: [8]u8 = undefined;
    var log_len: usize = 0;
    var left_yielded: usize = 0;
    var right_yielded: usize = 0;
    var right_short = zip(
        Probe{
            .label = 'L',
            .values = &.{ 1, 2, 3 },
            .log = &log,
            .log_len = &log_len,
            .yielded = &left_yielded,
        },
        Probe{
            .label = 'R',
            .values = &.{10},
            .log = &log,
            .log_len = &log_len,
            .yielded = &right_yielded,
        },
    );
    try std.testing.expect(right_short.next() != null);
    try std.testing.expect(right_short.next() == null);
    try std.testing.expect(right_short.next() == null);
    try std.testing.expectEqualSlices(u8, "LRLRLR", log[0..log_len]);
    try std.testing.expectEqual(@as(usize, 3), left_yielded);
    try std.testing.expectEqual(@as(usize, 1), right_yielded);

    log_len = 0;
    left_yielded = 0;
    right_yielded = 0;
    var left_short = zip(
        Probe{
            .label = 'L',
            .values = &.{1},
            .log = &log,
            .log_len = &log_len,
            .yielded = &left_yielded,
        },
        Probe{
            .label = 'R',
            .values = &.{ 10, 11 },
            .log = &log,
            .log_len = &log_len,
            .yielded = &right_yielded,
        },
    );
    try std.testing.expect(left_short.next() != null);
    try std.testing.expect(left_short.next() == null);
    try std.testing.expect(left_short.next() == null);
    try std.testing.expectEqualSlices(u8, "LRLL", log[0..log_len]);
    try std.testing.expectEqual(@as(usize, 1), left_yielded);
    try std.testing.expectEqual(@as(usize, 1), right_yielded);
}

test "core::iter zip next_back consumes unmatched borrowed source tails" {
    const BorrowedRange = struct {
        source: *Range,

        fn next(self: *@This()) ?usize {
            return self.source.next();
        }

        fn next_back(self: *@This()) ?usize {
            return self.source.next_back();
        }

        fn len(self: *const @This()) usize {
            return self.source.len();
        }
    };
    var left = range(0, 3);
    var right = range(0, 0);
    var pairs = zip(BorrowedRange{ .source = &left }, BorrowedRange{ .source = &right });
    try std.testing.expect(pairs.next_back() == null);
    try std.testing.expect(left.next() == null);
    try std.testing.expect(right.next() == null);
}

test "core::iter zip preserves a one-sided upper size bound" {
    const UnknownBound = struct {
        source: Range,

        fn next(self: *@This()) ?usize {
            return self.source.next();
        }

        fn size_hint(_: *const @This()) SizeHint {
            return .{ 0, null };
        }
    };
    inline for (.{ true, false }) |finite_first| {
        const finite = range(0, 3);
        const unknown = UnknownBound{ .source = range(0, 5) };
        var pairs = if (finite_first) zip(finite, unknown) else zip(unknown, finite);
        try std.testing.expectEqual(SizeHint{ 0, 3 }, pairs.size_hint());
        try std.testing.expect(pairs.next() != null);
        try std.testing.expectEqual(SizeHint{ 0, 2 }, pairs.size_hint());
    }
}

test "core::iter zip supports paired ranges and mutable slice items" {
    var pairs = zip(
        stepBy(range(0, 7), 2),
        stepBy(skip(range(0, 7), 1), 2),
    );
    const pair_0 = pairs.next().?;
    const pair_1 = pairs.next().?;
    const pair_2 = pairs.next().?;
    try std.testing.expectEqual(@as(usize, 0), pair_0[0]);
    try std.testing.expectEqual(@as(usize, 1), pair_0[1]);
    try std.testing.expectEqual(@as(usize, 2), pair_1[0]);
    try std.testing.expectEqual(@as(usize, 3), pair_1[1]);
    try std.testing.expectEqual(@as(usize, 4), pair_2[0]);
    try std.testing.expectEqual(@as(usize, 5), pair_2[1]);
    try std.testing.expect(pairs.next() == null);

    var totals = [_]u8{ 1, 2, 3 };
    const additions = [_]u8{ 10, 20 };
    var additions_iter = zip(
        sliceIterMut(u8, &totals),
        sliceIter(u8, &additions),
    );
    while (additions_iter.next()) |pair| {
        pair[0].* += pair[1].*;
    }
    try std.testing.expectEqualSlices(u8, &.{ 11, 22, 3 }, &totals);
}

test "core::iter enumerate rev and any preserve borrowed items" {
    const data = [_]u8{ 'a', '%', 'b', '%' };
    var indexed = enumerate(sliceIter(u8, &data));
    const first = indexed.next().?;
    const second = indexed.next().?;
    try std.testing.expectEqual(@as(usize, 0), first[0]);
    try std.testing.expect(first[1] == &data[0]);
    try std.testing.expectEqual(@as(usize, 1), second[0]);
    try std.testing.expect(second[1] == &data[1]);

    var reversed = rev(sliceIter(u8, &data));
    try std.testing.expectEqual(@as(u8, '%'), reversed.next().?.*);
    try std.testing.expectEqual(@as(u8, 'b'), reversed.next().?.*);
    try std.testing.expectEqual(@as(u8, '%'), reversed.next().?.*);
    try std.testing.expectEqual(@as(u8, 'a'), reversed.next().?.*);
    try std.testing.expect(reversed.next() == null);

    var bytes = sliceIter(u8, &data);
    const is_percent = struct {
        fn apply(byte: *const u8) bool {
            return byte.* == '%';
        }
    }.apply;
    try std.testing.expect(any(&bytes, is_percent));
    try std.testing.expectEqualSlices(u8, &.{ 'b', '%' }, bytes.as_slice());
    try std.testing.expect(any(&bytes, is_percent));
    try std.testing.expectEqual(@as(usize, 0), bytes.len());
    try std.testing.expect(!any(&bytes, is_percent));
}
