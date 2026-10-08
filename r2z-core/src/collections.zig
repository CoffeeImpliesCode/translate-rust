//! Rust `std::collections` → Zig `std.hash_map`.
//!
//! Rust's `HashMap<K, V, S>` and `HashSet<T, S>` take a *builder* as their
//! last parameter: `S: BuildHasher` constructs a fresh `Hasher` for every
//! lookup. Zig's `std.HashMap(K, V, Context, max_load)` has no builder; its
//! third parameter is a `Context` whose `hash`/`eql` are plain functions.
//!
//! `KeyContext` is the bridge. It is built from the same `S` the Rust source
//! named, so `HashMap<K, V, BuildHasherDefault<FnvHasher>>` hashes with FNV and
//! not with the Wyhash that `std.AutoHashMap` would substitute. That
//! substitution is the whole point of a crate like `fnv`, so it must never
//! happen silently: every container here is a `std.HashMap` with *our*
//! context, never a `std.AutoHashMap`.
//!
//! Key bytes follow Rust's default `Hasher::write_*` fallbacks: a byte-slice
//! key is written as-is, and any other key is written member by member down
//! to its bytes, exactly as `write_u32` and friends do for an integer.
//! Slices, `String`, and `Vec(T)` hash by CONTENTS, never by address or
//! capacity, so `hash` and `eql` can never disagree: two keys `eql` calls
//! equal digest alike. One deviation is documented and deliberate: `Hash for
//! str` and `Hash for String` append a `0xff` terminator, but `&str` and
//! `&[u8]` are the same Zig type (`[]const u8`), so the terminator is not
//! reproduced. Key equality uses the same structural walk the rest of
//! r2z-core uses.
//!
//! Map-key contract (for the lowering owner):
//! * A key is BORROWED, never owned: `put` copies the key descriptor and
//!   aliases its slab, so every slab behind a key or a value must outlive
//!   the map. `deinit` frees the table allocation only, never entries.
//! * Method names are `std.HashMap`'s: `put`, `get`, `contains`, `getPtr`,
//!   `remove`, `deinit` (a set is `put(key, {})` plus `contains`). Rust's
//!   `insert`, `contains_key`, and `entry` MUST be rewritten by lowering,
//!   and every map container MUST have `deinit` armed, or the table leaks.

const std = @import("std");
const core = @import("root.zig");

/// Zig's `std.hash_map.Context` implementation for a Rust key type `K` and a
/// Rust `BuildHasher` builder `Builder`.
///
/// The returned struct is zero-sized and holds no state, so `std.HashMap.init`
/// stays usable without an explicit context argument and every copy of a
/// context is interchangeable. `hash` and `eql` are the two callbacks
/// `std.HashMap` calls: both run on the calling thread, synchronously, inside
/// the map operation that reached them, receive their arguments by value, and
/// retain nothing.
///
/// A builder this runtime cannot construct from its type alone, and a key type
/// with no byte image, is a compile error here rather than a silent
/// substitution.
pub fn KeyContext(comptime K: type, comptime Builder: type) type {
    return struct {
        const Self = @This();

        /// Digest of one key, as Rust's `Hasher` would produce after writing
        /// that key's bytes.
        ///
        /// Called by `std.HashMap` on the calling thread with `key` borrowed for
        /// the call, and a grow path borrows the map's own storage to do it:
        /// `std.HashMap.grow` rebuilds the table from the old allocation, so
        /// every key the map already holds is hashed where it stands and the
        /// table is reallocated under the call. The builder reached here must
        /// therefore not reach the map that called it — Rust refuses the same
        /// reentry by withholding `&self` from a lookup that needs `&mut self`,
        /// and a callback has no way to enforce it here. Any other map is fine,
        /// and so is any allocation: storage the builder moves for itself is
        /// storage the caller is not holding. Builds a fresh hasher per call,
        /// exactly as Rust's per-lookup `build_hasher` does, so the result
        /// depends on the builder alone and never on a previous lookup, and
        /// neither this call nor `eql` releases the key or keeps it.
        pub fn hash(self: Self, key: K) u64 {
            _ = self;
            var state: BuilderHasher(Builder) = newHasher(Builder);
            feed(&state, key);
            return state.finish();
        }

        /// Whether two keys are the same key, structurally.
        ///
        /// Called by `std.HashMap` on the calling thread with both keys borrowed
        /// for the call, and it must agree with `hash`: two keys it calls equal
        /// must digest alike. Returns `false` rather than releasing anything on
        /// either side, so a key type that owns storage is not freed here.
        pub fn eql(self: Self, left: K, right: K) bool {
            _ = self;
            return core.ops.equal(left, right);
        }
    };
}

/// Rust `HashMap<K, V, S>` → `std.HashMap` keyed through `KeyContext(K, S)`.
///
/// `S` must be supplied: Rust's two-parameter `HashMap<K, V>` defaults to the
/// randomly seeded `RandomState`, which has no static Zig equivalent, so the
/// translator only ever emits this form when the source named a builder.
pub fn HashMap(comptime K: type, comptime V: type, comptime Builder: type) type {
    return std.HashMap(K, V, KeyContext(K, Builder), std.hash_map.default_max_load_percentage);
}

/// Rust `HashSet<T, S>` → the set idiom `std.HashMap(T, void, Context, max_load)`.
///
/// Zig 0.16 removed `std.HashSet`; a `void` value is its exact replacement, so
/// `contains` is `get(key) != null` and `insert` is `put(key, {})`.
pub fn HashSet(comptime T: type, comptime Builder: type) type {
    return std.HashMap(T, void, KeyContext(T, Builder), std.hash_map.default_max_load_percentage);
}

/// The concrete hasher type a builder produces.
fn BuilderHasher(comptime Builder: type) type {
    if (!@hasDecl(Builder, "build_hasher")) {
        @compileError("r2z.collections: " ++ @typeName(Builder) ++
            " is not a Rust `BuildHasher`: it has no `build_hasher` fn.");
    }
    // A lookup names no builder. `std.HashMap` carries the context, never a
    // value, so every digest is built from the builder type alone, and only
    // two shapes survive that. A zero-sized builder has exactly one value, so
    // reading one invents nothing: `BuildHasherDefault<H>`, which every
    // translated `HashMap<K, V, BuildHasherDefault<F>>` maps to, is that shape.
    // A `default` decl names the value, which is how a builder that stores
    // state still reaches a map that declared one, as `RandomState` does. A
    // builder that is neither stores state this runtime cannot supply — Rust
    // reaches it only through `with_hasher`, which carries the value the
    // caller holds — and digesting a key out of undefined state would file
    // every entry in the table under a bucket nothing will ever look in.
    if (@sizeOf(Builder) != 0 and !@hasDecl(Builder, "default")) {
        @compileError("r2z.collections: " ++ @typeName(Builder) ++
            " stores state and has no `default` fn, so no hasher can be built " ++
            "from it for a lookup. Rust reaches such a builder through " ++
            "`HashMap::with_hasher`, which passes the value the caller holds; " ++
            "map it to a zero-sized builder, as `BuildHasherDefault<H>` is, " ++
            "or give it a `default` fn.");
    }
    return @TypeOf(@as(Builder, undefined).build_hasher());
}

/// Build one fresh hasher, mirroring Rust's per-lookup `build_hasher` call.
///
/// The builder is reconstructed from its type alone, and `BuilderHasher` has
/// already reduced the type to the two shapes that admit it: a `default` decl
/// names the value, and a zero-sized builder has only the one value to read.
fn newHasher(comptime Builder: type) BuilderHasher(Builder) {
    const builder: Builder = if (@hasDecl(Builder, "default"))
        Builder.default()
    else
        @as(Builder, undefined);
    return builder.build_hasher();
}

/// Whether `T` is the unmanaged-list shape `eql` compares by contents:
/// `std.ArrayList(T)`, which is `{ items: []T, capacity: usize }`.
///
/// The test is the same field shape `core.ops.equal` walks, so the two can
/// never disagree about whether a value of this shape is a list. Capacity is
/// spare storage Rust never compares, so it is hashed never.
fn isUnmanagedListShape(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    const fields = @typeInfo(T).@"struct".fields;
    if (fields.len != 2) return false;
    const items = @typeInfo(fields[0].type);
    const capacity = @typeInfo(fields[1].type);
    return std.mem.eql(u8, fields[0].name, "items") and
        items == .pointer and items.pointer.size == .slice and
        std.mem.eql(u8, fields[1].name, "capacity") and
        capacity == .int and capacity.int.bits >= 0;
}
/// Whether `T` is one field around the list shape above. `String` is the
/// live case: one `bytes` field holding a `Vec(u8)`.
///
/// Same mirror rule: `equal` descends through the sole field to the list
/// contents, so the digest must descend the same way instead of imaging the
/// descriptor, whose slice pointer is an address.
fn isListWrapperShape(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    const fields = @typeInfo(T).@"struct".fields;
    if (fields.len != 1) return false;
    return isUnmanagedListShape(fields[0].type);
}
/// Feed a slice's CONTENTS, the bytes Rust's `Hash` would walk.
fn feedSliceContents(state: anytype, slice: anytype) void {
    const Child = @typeInfo(@TypeOf(slice)).pointer.child;
    if (comptime Child == u8) {
        state.write(slice);
        return;
    }
    for (slice) |element| {
        feed(state, element);
    }
}
/// Feed a key's bytes into a freshly built hasher.
///
/// Every branch mirrors `core.ops.equal`, which is what `KeyContext.eql`
/// answers with: slices, arrays, and one-pointers hash the contents `equal`
/// compares, lists and one-field wrappers around them hash the list contents,
/// tagged aggregates hash tag then member by member in declaration order,
/// and only the types `equal` answers with `==` — ints, bools, vectors,
/// enums, error sets, `fn` pointers, and many/C pointers — are written as
/// their in-memory image, floats modulo the signed-zero canonicalization
/// below. A list's spare capacity is hashed never, for the same reason it is
/// compared never. The `comptime` conditions gate which body is analyzed at
/// all, so a type with no branch never reaches `std.mem.asBytes`; anything
/// unhandled is a compile error rather than an address digest no lookup will
/// reproduce.
fn feed(state: anytype, key: anytype) void {
    const K = @TypeOf(key);
    if (comptime @typeInfo(K) == .pointer and @typeInfo(K).pointer.size == .slice) {
        feedSliceContents(state, key);
        return;
    }
    if (comptime @typeInfo(K) == .array) {
        for (key) |element| {
            feed(state, element);
        }
        return;
    }
    if (comptime @typeInfo(K) == .pointer and @typeInfo(K).pointer.size == .one) {
        feed(state, key.*);
        return;
    }
    if (comptime @typeInfo(K) == .@"struct" and isUnmanagedListShape(K)) {
        feedSliceContents(state, key.items);
        return;
    }
    if (comptime @typeInfo(K) == .@"struct" and isListWrapperShape(K)) {
        feed(state, @field(key, @typeInfo(K).@"struct".fields[0].name));
        return;
    }
    if (comptime @typeInfo(K) == .@"struct") {
        inline for (@typeInfo(K).@"struct".fields) |field| {
            if (comptime !field.is_comptime) {
                feed(state, @field(key, field.name));
            }
        }
        return;
    }
    if (comptime @typeInfo(K) == .optional) {
        if (key) |payload| {
            state.write(&[_]u8{0x01});
            feed(state, payload);
        } else {
            state.write(&[_]u8{0x00});
        }
        return;
    }
    if (comptime @typeInfo(K) == .error_union) {
        if (key) |payload| {
            state.write(&[_]u8{0x01});
            feed(state, payload);
        } else |err| {
            state.write(&[_]u8{0x00});
            // The integer, not the error value: `equal` answers errors with
            // `==`, and the int image agrees without depending on the error
            // set's representation.
            feed(state, @intFromError(err));
        }
        return;
    }
    if (comptime @typeInfo(K) == .@"union") {
        if (comptime @typeInfo(K).@"union".tag_type == null) {
            @compileError("r2z.collections: cannot hash key type " ++ @typeName(K) ++
                " — it is an untagged union, so there is no tag to feed before " ++
                "the payload. Lower this key to a byte slice or an integer first.");
        }
        feed(state, @intFromEnum(std.meta.activeTag(key)));
        switch (key) {
            inline else => |payload| feed(state, payload),
        }
        return;
    }
    if (comptime @typeInfo(K) == .void) {
        return;
    }
    // The remaining types are exactly the ones `equal` answers with `==`, so
    // imaging is agreeing — except for one value: `-0.0 == 0.0` while their
    // images differ, so signed zero is fed as positive zero.
    if (comptime @typeInfo(K) == .float) {
        if (comptime std.meta.hasUniqueRepresentation(K)) {
            const zero: K = 0.0;
            const canonical = if (key == zero) zero else key;
            state.write(std.mem.asBytes(&canonical));
            return;
        }
    }
    if (comptime @typeInfo(K) == .bool or
        @typeInfo(K) == .int or
        @typeInfo(K) == .vector or
        @typeInfo(K) == .@"enum" or
        @typeInfo(K) == .error_set or
        @typeInfo(K) == .@"fn" or
        (@typeInfo(K) == .pointer and
            (@typeInfo(K).pointer.size == .many or @typeInfo(K).pointer.size == .c)))
    {
        if (comptime std.meta.hasUniqueRepresentation(K)) {
            state.write(std.mem.asBytes(&key));
            return;
        }
    }
    @compileError("r2z.collections: cannot hash key type " ++ @typeName(K) ++
        " — it has no unique representation, so the byte stream Rust's " ++
        "`Hasher::write` would receive is undefined. Lower this key to a byte " ++
        "slice or an integer first.");
}

fn FnvContext() type {
    return KeyContext([]const u8, core.BuildHasherDefault(core.FnvHasher));
}

fn FnvMap() type {
    return HashMap([]const u8, u64, core.BuildHasherDefault(core.FnvHasher));
}

fn repeat(bytes: []const u8, count: usize) ![]u8 {
    const out = try std.testing.allocator.alloc(u8, bytes.len * count);
    for (0..count) |i| @memcpy(out[i * bytes.len ..][0..bytes.len], bytes);
    return out;
}

test "collections: the hasher adapter reproduces the fnv crate's own vectors" {
    const context: FnvContext() = .{};

    // Digests copied from test/crates/fnv: `basic_tests`, the crate this
    // mapping exists for. Running them through the *builder adapter* — not
    // straight through `FnvHasher` — is the point: the adapter is the only
    // code a translated `HashMap<K, V, BuildHasherDefault<FnvHasher>>` uses to
    // hash, so a bug here silently changes every map the crate declares.
    const vectors = [_]struct { input: []const u8, digest: u64 }{
        .{ .input = "", .digest = 0xcbf29ce484222325 },
        .{ .input = "a", .digest = 0xaf63dc4c8601ec8c },
        .{ .input = "b", .digest = 0xaf63df4c8601f1a5 },
        .{ .input = "f", .digest = 0xaf63db4c8601ead9 },
        .{ .input = "fo", .digest = 0x08985907b541d342 },
        .{ .input = "foo", .digest = 0xdcb27518fed9d577 },
        .{ .input = "foob", .digest = 0xdd120e790c2512af },
        .{ .input = "fooba", .digest = 0xcac165afa2fef40a },
        .{ .input = "foobar", .digest = 0x85944171f73967e8 },
        .{ .input = "\x00", .digest = 0xaf63bd4c8601b7df },
        .{ .input = "a\x00", .digest = 0x089be207b544f1e4 },
        .{ .input = "foobar\x00", .digest = 0x34531ca7168b8f38 },
        .{ .input = "chongo", .digest = 0xe150688c8217b8fd },
        .{ .input = "chongo was here!\n", .digest = 0x46810940eff5f915 },
        .{ .input = "\xff\x00\x00\x01", .digest = 0x6961196491cc682d },
        .{ .input = "\x01\x00\x00\xff", .digest = 0xad2bb1774799dfe9 },
        .{ .input = "\x40\x51\x4e\x44", .digest = 0xe3b36596127cd6d8 },
        .{ .input = "127.0.0.1", .digest = 0xaabafe7104d914be },
        .{ .input = "feedfacedeadbeef", .digest = 0xcac54572bb1a6fc8 },
        .{ .input = "line 1\nline 2\nline 3", .digest = 0x7829851fac17b143 },
    };
    for (vectors) |vector| {
        try std.testing.expectEqual(vector.digest, context.hash(vector.input));
    }

    const ten_21701 = try repeat("21701", 10);
    defer std.testing.allocator.free(ten_21701);
    try std.testing.expectEqual(@as(u64, 0xc4112ffb337a82fb), context.hash(ten_21701));

    const ten_merkle = try repeat("2^21701-1", 10);
    defer std.testing.allocator.free(ten_merkle);
    try std.testing.expectEqual(@as(u64, 0x4cfc32329edebcbb), context.hash(ten_merkle));

    const five_hundred_null = try repeat("\x00", 500);
    defer std.testing.allocator.free(five_hundred_null);
    try std.testing.expectEqual(@as(u64, 0x1fe3fce62bd816b5), context.hash(five_hundred_null));
}

test "collections: the builder, not the container, decides the digest" {
    // The builder is the only source of the hash function, so swapping it must
    // swap the digest. That is what makes this a real `HashMap<K, V, S>` and
    // not a hard-wired FNV table.
    const NullHasher = struct {
        pub fn default() @This() {
            return .{};
        }
        pub fn write(self: *@This(), bytes: []const u8) void {
            _ = self;
            _ = bytes;
        }
        pub fn finish(self: *const @This()) u64 {
            _ = self;
            return 0x5a5a5a5a5a5a5a5a;
        }
    };
    const context: KeyContext([]const u8, core.BuildHasherDefault(NullHasher)) = .{};
    try std.testing.expectEqual(@as(u64, 0x5a5a5a5a5a5a5a5a), context.hash("foobar"));
    try std.testing.expectEqual(
        @as(u64, 0x5a5a5a5a5a5a5a5a),
        context.hash("a completely different key"),
    );
}

test "collections: the map is std.HashMap keyed by the crate hasher, not AutoHashMap" {
    // `std.AutoHashMap` would hash with Wyhash. Pin the difference explicitly
    // on both key shapes: if a later edit swaps in the auto context, these
    // digests change and the test fails.
    const context: FnvContext() = .{};
    try std.testing.expectEqual(@as(u64, 0x85944171f73967e8), context.hash("foobar"));
    const strings: std.hash_map.StringContext = .{};
    try std.testing.expect(strings.hash("foobar") != context.hash("foobar"));

    // `AutoContext` refuses a slice key, which is exactly why substituting
    // `std.AutoHashMap` is not even possible for a `HashMap<String, _>`.
    const auto: std.hash_map.AutoContext(u64) = .{};
    const int: KeyContext(u64, core.BuildHasherDefault(core.FnvHasher)) = .{};
    var expected = core.FnvHasher.init();
    expected.write(&std.mem.toBytes(@as(u64, 42)));
    try std.testing.expectEqual(expected.finish(), int.hash(42));
    try std.testing.expect(auto.hash(42) != int.hash(42));

    try std.testing.expectEqual(
        std.HashMap(
            []const u8,
            u64,
            FnvContext(),
            std.hash_map.default_max_load_percentage,
        ),
        FnvMap(),
    );
}

test "collections: integer keys hash as their native-endian bytes" {
    // Rust's `Hasher::write_u32` default is `self.write(&x.to_ne_bytes())`, so
    // an integer key must reach the hasher the same way the fnv crate's own
    // test vectors feed `\xff\x00\x00\x01`. On a little-endian target that
    // makes `0x010000ff` the value whose bytes are `ff 00 00 01`.
    const context: KeyContext(u32, core.BuildHasherDefault(core.FnvHasher)) = .{};

    var expected_ff = core.FnvHasher.init();
    expected_ff.write(&std.mem.toBytes(@as(u32, 0x010000ff)));
    try std.testing.expectEqual(expected_ff.finish(), context.hash(@as(u32, 0x010000ff)));
    try std.testing.expectEqual(@as(u64, 0x6961196491cc682d), context.hash(@as(u32, 0x010000ff)));

    var expected_01 = core.FnvHasher.init();
    expected_01.write(&std.mem.toBytes(@as(u32, 0xff000001)));
    try std.testing.expectEqual(expected_01.finish(), context.hash(@as(u32, 0xff000001)));
    try std.testing.expectEqual(@as(u64, 0xad2bb1774799dfe9), context.hash(@as(u32, 0xff000001)));
}

test "collections: HashMap stores, finds, and removes FNV-hashed keys" {
    var map = FnvMap().init(std.testing.allocator);
    defer map.deinit();

    try map.put("one", 1);
    try map.put("two", 2);
    try map.put("", 0);
    try std.testing.expectEqual(@as(usize, 3), map.count());

    try std.testing.expectEqual(@as(?u64, 1), map.get("one"));
    try std.testing.expectEqual(@as(?u64, 2), map.get("two"));
    try std.testing.expectEqual(@as(?u64, 0), map.get(""));
    try std.testing.expectEqual(@as(?u64, null), map.get("three"));

    // Re-putting an existing key replaces the value without growing.
    try map.put("one", 11);
    try std.testing.expectEqual(@as(usize, 3), map.count());
    try std.testing.expectEqual(@as(?u64, 11), map.get("one"));

    // Every key must still be reachable after the table has rehashed: a
    // context whose `eql` disagreed with its `hash` would strand entries.
    var it = map.iterator();
    var seen: usize = 0;
    while (it.next()) |entry| {
        try std.testing.expectEqual(@as(?u64, entry.value_ptr.*), map.get(entry.key_ptr.*));
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), seen);

    try std.testing.expect(map.remove("two"));
    try std.testing.expectEqual(@as(?u64, null), map.get("two"));
    try std.testing.expectEqual(@as(usize, 2), map.count());
}

test "collections: HashSet is a void-valued map and behaves as a set" {
    const Set = HashSet([]const u8, core.BuildHasherDefault(core.FnvHasher));
    var set = Set.init(std.testing.allocator);
    defer set.deinit();

    try std.testing.expect(!set.contains("a"));
    try set.put("a", {});
    try set.put("b", {});
    try std.testing.expect(set.contains("a"));
    try std.testing.expect(set.contains("b"));
    try std.testing.expect(!set.contains("c"));
    try std.testing.expectEqual(@as(usize, 2), set.count());

    try set.put("a", {});
    try std.testing.expectEqual(@as(usize, 2), set.count());

    try std.testing.expect(set.remove("a"));
    try std.testing.expect(!set.contains("a"));
    try std.testing.expectEqual(@as(usize, 1), set.count());
}

test "collections: key equality is structural, not pointer identity" {
    const context: FnvContext() = .{};
    const a: []const u8 = "same key";
    var storage: [8]u8 = "same key".*;
    const b: []const u8 = &storage;
    try std.testing.expect(a.ptr != b.ptr);
    try std.testing.expect(context.eql(a, b));
    try std.testing.expect(!context.eql(a, "other key"));
    try std.testing.expect(!context.eql(a, "same keY"));
    try std.testing.expectEqual(context.hash(a), context.hash(b));

    const int: KeyContext(u64, core.BuildHasherDefault(core.FnvHasher)) = .{};
    try std.testing.expect(int.eql(42, 42));
    try std.testing.expect(!int.eql(42, 43));
}
test "collections: an owning String key finds an equal entry at another address" {
    // `feed` used to hash the descriptor's byte image, which for a `String`
    // is the slab ADDRESS, while `eql` compares contents — so an equal
    // `String` at another address missed its entry. Both sides hash contents
    // now, and capacity (which `eql` ignores) is hashed never.
    const gpa = std.testing.allocator;
    const StringMap = HashMap(core.alloc.String, u64, core.BuildHasherDefault(core.FnvHasher));
    const context: KeyContext(core.alloc.String, core.BuildHasherDefault(core.FnvHasher)) = .{};

    var stored = try core.alloc.String.from_str(gpa, "same contents");
    defer stored.deinit(gpa);
    var lookup = try core.alloc.String.from_str(gpa, "same contents");
    defer lookup.deinit(gpa);
    try std.testing.expect(stored.as_str().ptr != lookup.as_str().ptr);
    try std.testing.expect(context.eql(stored, lookup));
    try std.testing.expectEqual(context.hash(stored), context.hash(lookup));

    var map = StringMap.init(gpa);
    defer map.deinit();
    try map.put(stored, 7);
    try std.testing.expect(map.contains(lookup));
    try std.testing.expectEqual(@as(?u64, 7), map.get(lookup));
}

test "collections: a slice key finds an equal entry at another address (control)" {
    // The slice path always hashed contents; this is the control the `String`
    // case above has to match.
    const gpa = std.testing.allocator;
    var map = FnvMap().init(gpa);
    defer map.deinit();

    const stored = try gpa.dupe(u8, "same contents");
    defer gpa.free(stored);
    const lookup = try gpa.dupe(u8, "same contents");
    defer gpa.free(lookup);
    try std.testing.expect(stored.ptr != lookup.ptr);

    try map.put(stored, 7);
    try std.testing.expect(map.contains(lookup));
    try std.testing.expectEqual(@as(?u64, 7), map.get(lookup));
}

test "collections: both constructible builder shapes answer every lookup alike" {
    // A lookup carries no builder value, so the two shapes `BuilderHasher`
    // admits have to keep answering: the zero-sized builder Rust's
    // `BuildHasherDefault<H>` names, which holds nothing to invent, and a
    // builder whose `default` names the one value a lookup can have.
    const Stateless = struct {
        pub fn build_hasher(self: @This()) core.FnvHasher {
            _ = self;
            return core.FnvHasher.init();
        }
    };
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(Stateless));
    const stateless: KeyContext([]const u8, Stateless) = .{};
    var plain = core.FnvHasher.init();
    plain.write("foobar");
    try std.testing.expectEqual(plain.finish(), stateless.hash("foobar"));

    // The seeded builder stands in for a `S: Default` such as `RandomState`:
    // it stores state, so the digest it returns is the only evidence of which
    // value the lookup was given.
    const Seeded = struct {
        seed: u64,
        pub fn default() @This() {
            return .{ .seed = 0x0123456789abcdef };
        }
        pub fn build_hasher(self: @This()) core.FnvHasher {
            var state = core.FnvHasher.init();
            state.write(&std.mem.toBytes(self.seed));
            return state;
        }
    };
    const seeded: KeyContext([]const u8, Seeded) = .{};
    var with_seed = core.FnvHasher.init();
    with_seed.write(&std.mem.toBytes(@as(u64, 0x0123456789abcdef)));
    with_seed.write("foobar");
    try std.testing.expectEqual(with_seed.finish(), seeded.hash("foobar"));

    // Every lookup builds its own hasher, so no digest can carry the state of
    // the call before it. That is what makes a rehash reproducible.
    const repeated = seeded.hash("foobar");
    for (0..8) |_| try std.testing.expectEqual(repeated, seeded.hash("foobar"));
}

test "collections: a grow path rehashes borrowed keys and strands none of them" {
    // `std.HashMap.grow` rebuilds the table by hashing every key it already
    // holds out of the old allocation and then releasing that allocation, so
    // each key is borrowed across a reallocation on its way in. A digest that
    // answered from anything but the key would file the entry under a bucket
    // the next lookup never reads, and the loss would show here rather than at
    // the first insert.
    const gpa = std.testing.allocator;
    const count = 512;
    const key_width = 8; // "key-0511"

    var map = FnvMap().init(gpa);
    defer map.deinit();

    // The keys live in storage this test still owns, because a key the table
    // borrows must outlive the call that handed it over.
    var key_bytes = try gpa.alloc(u8, count * key_width);
    defer gpa.free(key_bytes);
    const digests = try gpa.alloc(u64, count);
    defer gpa.free(digests);

    const context: FnvContext() = .{};
    var capacity_after_first: ?usize = null;
    for (0..count) |index| {
        const key = key_bytes[index * key_width ..][0..key_width];
        const formatted = try std.fmt.bufPrint(key, "key-{d:0>4}", .{index});
        try std.testing.expectEqual(key_width, formatted.len);
        // Recorded before the insert, so the comparison below is against the
        // table this key was hashed in, not the one it ended up in.
        digests[index] = context.hash(key);
        try map.put(key, @intCast(index));
        if (index == 0) capacity_after_first = map.capacity();
    }

    // The table reallocated at least once, so the borrow really was taken
    // across a reallocation.
    try std.testing.expect(map.capacity() > capacity_after_first.?);
    try std.testing.expectEqual(@as(usize, count), map.count());

    for (0..count) |index| {
        const key = key_bytes[index * key_width ..][0..key_width];
        try std.testing.expectEqual(digests[index], context.hash(key));
        try std.testing.expectEqual(@as(?u64, @intCast(index)), map.get(key));
    }

    var seen: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        try std.testing.expectEqual(@as(?u64, entry.value_ptr.*), map.get(entry.key_ptr.*));
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, count), seen);
}

test "collections: a grow path leaves the caller's key storage where it was" {
    // The keys below are storage the caller owns and the map borrows, which is
    // what a translated crate hands `HashMap::insert` when the key is a slice
    // of a `Vec<u8>`. `grow` hashes each of them in place and reallocates
    // under the call, so a callback that wrote through the key, released it,
    // or kept it would move the address or change the bytes.
    const gpa = std.testing.allocator;
    const key_width = 8;
    const key_count = 32;
    var storage = try gpa.alloc(u8, key_count * key_width);
    defer gpa.free(storage);
    @memset(storage, 'k');
    const address = @intFromPtr(storage.ptr);

    var map = FnvMap().init(gpa);
    defer map.deinit();

    var capacity_after_first: ?usize = null;
    // Different slice lengths make distinct keys without changing the caller's
    // all-'k' bytes, so every insertion can contribute to the grow path.
    for (0..key_count) |index| {
        try map.put(storage[index * key_width ..], @intCast(index));
        if (index == 0) capacity_after_first = map.capacity();
    }
    try std.testing.expect(map.capacity() > capacity_after_first.?);
    try std.testing.expectEqual(@as(usize, key_count), map.count());

    for (0..key_count) |index| {
        try std.testing.expectEqual(
            @as(?u64, @intCast(index)),
            map.get(storage[index * key_width ..]),
        );
    }
    try std.testing.expectEqual(address, @intFromPtr(storage.ptr));
    try std.testing.expectEqualSlices(u8, &([_]u8{'k'} ** (key_count * key_width)), storage);
}

test "collections: no read path reallocates while a caller holds a borrowed key or value" {
    // Zig 0.16 gives `std.HashMap` a `SafetyLock` that turns "this call would
    // move a key or a value under a live pointer" into an assertion. Only the
    // growing paths take that lock (`getOrPutContextAdapted`,
    // `putNoClobberContext`, `ensureTotalCapacityContext`,
    // `clearRetainingCapacity`, `clearAndFree`); every read below reaches the
    // table without it, which is the runtime assertion that none of them
    // reallocates.
    //
    // Skipped where std compiles the lock out, so the claim is never pinned
    // by an unarmed test that cannot fail.
    if (!comptime std.debug.runtime_safety) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var map = FnvMap().init(gpa);
    defer map.deinit();

    const count = 64;
    const key_width = 8;
    var storage = try gpa.alloc(u8, count * key_width);
    defer gpa.free(storage);
    for (0..count) |index| {
        const key = storage[index * key_width ..][0..key_width];
        _ = try std.fmt.bufPrint(key, "key-{d:0>4}", .{index});
        try map.put(key, @intCast(index));
    }

    const first_borrow = map.getPtr(storage[0..key_width]).?;
    const first_address = @intFromPtr(first_borrow);
    const capacity_before = map.capacity();

    map.lockPointers();

    // Lookups, contains, getPtr, remove of another entry, and iteration:
    // none of them reallocates, so none of them trips the lock.
    for (0..count) |index| {
        const key = storage[index * key_width ..][0..key_width];
        try std.testing.expectEqual(@as(?u64, @intCast(index)), map.get(key));
        try std.testing.expect(map.contains(key));
        const ptr = map.getPtr(key) orelse return error.ExpectedEntry;
        try std.testing.expectEqual(@as(u64, @intCast(index)), ptr.*);
    }

    var seen: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        try std.testing.expectEqual(@as(?u64, entry.value_ptr.*), map.get(entry.key_ptr.*));
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, count), seen);

    // Removing another entry tombstones in place and reallocates nothing.
    const last_key = storage[(count - 1) * key_width ..][0..key_width];
    try std.testing.expect(map.remove(last_key));
    try std.testing.expect(!map.contains(last_key));
    try std.testing.expectEqual(@as(?u64, null), map.get(last_key));
    try std.testing.expectEqual(@as(usize, count - 1), map.count());

    // The borrow taken before the locked sweep still names the same slot and
    // still reads the same value.
    try std.testing.expectEqual(first_address, @intFromPtr(first_borrow));
    try std.testing.expectEqual(@as(u64, 0), first_borrow.*);

    map.unlockPointers();
    try std.testing.expectEqual(capacity_before, map.capacity());
}

test "collections: the runtime releases a map's table and never its entries" {
    // `std.HashMap` is a non-tuple named struct, so `ownsTemporaryStorage`
    // answers false for it and `dropTemporary` stops at the descriptor. That
    // answer is what keeps the runtime from walking entries: it owns no
    // release for a key or a value it did not create, and one that it cannot
    // name must not be freed twice.
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    var storage: [32]u8 = undefined;
    @memset(&storage, 'k');
    const borrowed_first: []const u8 = storage[0..8];
    // Unequal lengths distinguish the keys while every caller-owned byte stays 'k'.
    const borrowed_second: []const u8 = storage[8..24];
    const frees = table: {
        var map = FnvMap().init(gpa);
        defer map.deinit();
        try map.put(borrowed_first, 1);
        try map.put(borrowed_second, 2);

        const before_release = tracking.deallocations;
        core.alloc.dropTemporary(gpa, &map);
        try std.testing.expectEqual(before_release, tracking.deallocations);

        // The table is untouched, so the entries are still there to be reached.
        try std.testing.expectEqual(@as(usize, 2), map.count());
        try std.testing.expectEqual(@as(?u64, 1), map.get(borrowed_first));
        try std.testing.expectEqual(@as(?u64, 2), map.get(borrowed_second));
        break :table before_release;
    };

    // The map is not a no-op owner: its own `deinit` frees exactly the table
    // allocation, and the caller's key storage is untouched by the release.
    try std.testing.expectEqual(frees + 1, tracking.deallocations);
    for (storage) |byte| try std.testing.expectEqual(@as(u8, 'k'), byte);
}

test "collections: an owned move is refused for a foreign struct where a tuple over the same field is granted one" {
    // The refusal is a guard, not a gap: the runtime reaches exactly the same
    // `String` storage in both shapes and releases it in both, and only the
    // wrapper differs. A named struct's fields are the user's destructor to
    // run, so the runtime declines to move one — but it does not decline
    // because it could not see inside.
    const Visible = struct { text: core.alloc.String };
    try std.testing.expect(!core.alloc.supportsOwnedMove(Visible));
    try std.testing.expect(core.alloc.supportsOwnedMove(core.alloc.String));

    const AsTuple = @TypeOf(@as(@Tuple(&.{core.alloc.String}), undefined));
    try std.testing.expect(core.alloc.supportsOwnedMove(AsTuple));

    // And a map, whose value type may be exactly such a struct, is refused as
    // well: the runtime does not claim to have moved a container it did not
    // construct.
    try std.testing.expect(!core.alloc.supportsOwnedMove(FnvMap()));

    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    // The named struct owns storage a release would free, and no release runs.
    var named = Visible{ .text = try core.alloc.String.from_str(gpa, "same storage") };
    const frees = tracking.deallocations;
    core.alloc.dropTemporary(gpa, &named);
    try std.testing.expectEqual(frees, tracking.deallocations);
    try std.testing.expectEqualStrings("same storage", named.text.as_str());
    named.text.deinit(gpa);

    // The same storage in a tuple IS released, and a second pass frees nothing
    // because the first left the slot empty.
    const frees_tuple = tracking.deallocations;
    var tuple: AsTuple = .{try core.alloc.String.from_str(gpa, "same storage")};
    core.alloc.dropTemporary(gpa, &tuple);
    try std.testing.expectEqual(frees_tuple + 1, tracking.deallocations);
    core.alloc.dropTemporary(gpa, &tuple);
    try std.testing.expectEqual(frees_tuple + 1, tracking.deallocations);
}
