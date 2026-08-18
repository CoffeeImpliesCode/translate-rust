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

// ── Rust `core::iter` → Zig iterator protocol ────────────────────────────
//
// Translated Rust iterator chains (`iter()`, then `map`/`filter`/`take`/
// `fold`) lower onto two cooperating forms:
//   * concrete, monomorphized iterators — the default, what translated code
//     actually names — each exposing `next(self: *Self) ?T`;
//   * `Iterator(T)`, a type-erased box (function pointer + `*anyopaque`
//     context) for the rare spots that need one uniform iterator type.
// Every adapter holds its source iterator BY VALUE (no allocation, no
// `*anyopaque` in the hot path) and is exhausted lazily, one element per
// `next()` call, matching Rust's `core::iter` semantics.

/// Element type yielded by an iterator: unwraps the optional return of its
/// `next(self: *Self) ?T` method.
fn Elem(comptime Base: type) type {
    const ret = @typeInfo(@TypeOf(Base.next)).@"fn".return_type.?;
    return switch (@typeInfo(ret)) {
        .optional => |o| o.child,
        else => ret,
    };
}

/// Iterator yielding the elements of a slice (Rust `slice.iter()`).
pub fn SliceIter(comptime T: type) type {
    return struct {
        const Self = @This();

        slice: []const T,
        index: usize = 0,

        pub fn next(self: *Self) ?T {
            if (self.index >= self.slice.len) return null;
            const result = self.slice[self.index];
            self.index += 1;
            return result;
        }
    };
}

/// Create a slice iterator over `slice` (mutable `[]T` coerces implicitly).
pub fn sliceIter(comptime T: type, slice: []const T) SliceIter(T) {
    return .{ .slice = slice };
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
            return self.base.next();
        }
    };
}

/// Wrap `iter` so each element becomes `F(el)`.
pub fn map(iter: anytype, comptime F: anytype, comptime Out: type) Map(@TypeOf(iter), F, Out) {
    return .{ .base = iter };
}

/// Wrap `iter`, keeping only the elements for which `F` returns true.
pub fn filter(iter: anytype, comptime F: anytype) Filter(@TypeOf(iter), F) {
    return .{ .base = iter };
}

/// Wrap `iter`, ending after at most `n` elements.
pub fn take(iter: anytype, n: usize) Take(@TypeOf(iter)) {
    return .{ .base = iter, .remaining = n };
}

/// Consume `iter`, accumulating `F(acc, el)` starting from `init`
/// (Rust `iter.fold(init, F)`).
pub fn fold(iter: anytype, comptime Acc: type, init: Acc, comptime F: anytype) Acc {
    var acc = init;
    var it = iter;
    while (it.next()) |el| {
        acc = F(acc, el);
    }
    return acc;
}

/// Type-erased iterator box: a `next` function pointer over an `*anyopaque`
/// context, giving one uniform iterator type. Prefer the concrete adapters
/// above where the concrete type is known; this box serves the spots that
/// need type erasure.
pub fn Iterator(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Next element, or `null` when the iterator is exhausted.
        next_fn: *const fn (context: *anyopaque) ?T,
        /// Opaque state that `next_fn` reads from.
        context: *anyopaque,

        pub fn init(next_fn: *const fn (context: *anyopaque) ?T, context: *anyopaque) Self {
            return .{ .next_fn = next_fn, .context = context };
        }

        /// Plug the box into the common `next(self: *Self) ?T` iterator
        /// protocol by calling through the stored function pointer.
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
}

test "assertions and panic helpers" {
    assert(true);
    debugAssert(true);
}

// Test-only comptime functions shared by the `core::iter` tests below.
const iterfns = struct {
    const IsEven = struct {
        fn apply(x: u32) bool {
            return x % 2 == 0;
        }
    };
    const Square = struct {
        fn apply(x: u32) u64 {
            return @as(u64, x) * x;
        }
    };
    const SumSquares = struct {
        fn apply(acc: u64, x: u32) u64 {
            return acc + Square.apply(x);
        }
    };
    const BoxNext = struct {
        fn next(context: *anyopaque) ?u32 {
            const s: *SliceIter(u32) = @ptrCast(@alignCast(context));
            return s.next();
        }
    };
};

test "core::iter sliceIter produces elements" {
    const data = [_]u8{ 4, 5, 6 };
    var it = sliceIter(u8, &data);
    try std.testing.expectEqual(@as(?u8, 4), it.next());
    try std.testing.expectEqual(@as(?u8, 5), it.next());
    try std.testing.expectEqual(@as(?u8, 6), it.next());
    try std.testing.expectEqual(@as(?u8, null), it.next());
}

test "core::iter map/filter chains and take" {
    const data = [_]u32{ 1, 2, 3, 4, 5, 6 };

    // filter → map: evens squared = 4, 16, 36.
    var it = map(filter(sliceIter(u32, &data), iterfns.IsEven.apply), iterfns.Square.apply, u64);
    try std.testing.expectEqual(@as(?u64, 4), it.next());
    try std.testing.expectEqual(@as(?u64, 16), it.next());
    try std.testing.expectEqual(@as(?u64, 36), it.next());
    try std.testing.expectEqual(@as(?u64, null), it.next());

    // take after filter yields at most n.
    var limited = take(filter(sliceIter(u32, &data), iterfns.IsEven.apply), 2);
    try std.testing.expectEqual(@as(?u32, 2), limited.next());
    try std.testing.expectEqual(@as(?u32, 4), limited.next());
    try std.testing.expectEqual(@as(?u32, null), limited.next());

    // take(0) terminates immediately without consuming the source.
    var none = take(sliceIter(u32, &data), 0);
    try std.testing.expectEqual(@as(?u32, null), none.next());
}

test "core::iter fold accumulates" {
    const data = [_]u32{ 1, 2, 3, 4, 5, 6 };

    // Sum of squares of all elements: 1+4+9+16+25+36 = 91.
    try std.testing.expectEqual(@as(u64, 91), fold(sliceIter(u32, &data), u64, 0, iterfns.SumSquares.apply));

    // Sum of squares of evens: 4+16+36 = 56.
    try std.testing.expectEqual(@as(u64, 56), fold(filter(sliceIter(u32, &data), iterfns.IsEven.apply), u64, 0, iterfns.SumSquares.apply));

    // Mutable slice `[]T` coerces into the `[]const T` parameter.
    var mut = [_]u8{ 1, 2, 3 };
    try std.testing.expectEqual(@as(usize, 3), fold(sliceIter(u8, &mut), usize, 0, struct {
        fn apply(acc: usize, _: u8) usize {
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
