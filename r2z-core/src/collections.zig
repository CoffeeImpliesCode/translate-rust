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
//! key is written as-is, and any other key is written as its native-endian
//! in-memory image, exactly as `write_u32` and friends do for an integer. One
//! deviation is documented and deliberate: `Hash for str` and `Hash for String`
//! append a `0xff` terminator, but `&str` and `&[u8]` are the same Zig type
//! (`[]const u8`), so the terminator is not reproduced. Key equality uses the
//! same structural walk the rest of r2z-core uses.

const std = @import("std");
const core = @import("root.zig");

/// Zig's `std.hash_map.Context` implementation for a Rust key type `K` and a
/// Rust `BuildHasher` builder `Builder`.
///
/// The returned struct is zero-sized, so `std.HashMap.init` stays usable
/// without an explicit context argument.
pub fn KeyContext(comptime K: type, comptime Builder: type) type {
    return struct {
        const Self = @This();

        pub fn hash(self: Self, key: K) u64 {
            _ = self;
            var state: BuilderHasher(Builder) = newHasher(Builder);
            feed(&state, key);
            return state.finish();
        }

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
    return @TypeOf(@as(Builder, undefined).build_hasher());
}

/// Build one fresh hasher, mirroring Rust's per-lookup `build_hasher` call.
fn newHasher(comptime Builder: type) BuilderHasher(Builder) {
    const builder: Builder = if (@hasDecl(Builder, "default"))
        Builder.default()
    else
        @as(Builder, undefined);
    return builder.build_hasher();
}

/// Feed a key's bytes into a freshly built hasher.
///
/// The `comptime` conditions gate which body is analyzed at all, so a type
/// with no byte image never reaches `std.mem.asBytes`.
fn feed(state: anytype, key: anytype) void {
    const K = @TypeOf(key);
    if (comptime @typeInfo(K) == .pointer and @typeInfo(K).pointer.size == .slice) {
        state.write(key);
        return;
    }
    if (comptime std.meta.hasUniqueRepresentation(K)) {
        state.write(std.mem.asBytes(&key));
        return;
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
