//! Consumer tests for the generated-package cross matrix.
//!
//! Every expectation below is a value published by the crate's own sources: a
//! doctest in the fixture, a `#[test]` assertion, or a reference vector of the
//! algorithm the crate implements. Nothing here reimplements a hash, a checksum
//! or a byte reader — the staged package under test produces every number that
//! is compared, and this file only states what the crate said it would produce.
//!
//! ## What this file covers, and what it deliberately does not
//!
//! It covers the families that no other consumer reaches: `mini`, `multimod`,
//! `fnv`, `leb128`, `hex`, and `xxhash-rust` under an explicit `xxh32`
//! selection. `siphasher`, `itoa`, `seahash` and `atoi` belong to
//! `test/promoted_crates_consumer.zig`; `compat` and `percent-encoding` keep
//! their own consumers; the differential fixture keeps its own. Their
//! assertions are not restated here.
//!
//! It also covers `mini-wire`, the same crate reached through the other
//! pipeline: `test/mini.json` decoded from canonical v6 wire instead of
//! analysed from `test/crates/mini`. That row has no `#[cfg(test)]` module of
//! its own — `test/crates/mini` carries none — so nothing in the matrix ran a
//! value through it and its only evidence was that it compiled. A compile is
//! not an assertion, so the row belongs here.
//!
//! ## What Rust privacy keeps out
//!
//! Two families own items this file may not name, and each says so where the
//! item would have gone instead of reaching past the boundary.
//! `test/crates/multimod/src/lib.rs` declares `mod foo;` without `pub`, so
//! `multimod::foo::foo_fn` and the `mod bar;` beneath it are crate-internal.
//! `test/crates/wyhash/src/lib.rs` declares `mod functions;` without `pub` and
//! re-exports only `{wyhash, wyrng}`, so `wyhash::read64` is crate-internal
//! even though the Rust item is `pub fn`, and `wyhash::read_rest` — a private
//! `fn` — never was. What those readers do is still checked here, through the
//! public entry points whose digests depend on which reader a length selects.
//!
//! The two `xxhash-rust` configurations are separate corpus rows and this file
//! imports only the one that selects `xxh32`. The manifest declares no
//! `default` feature, so the default configuration resolves to the empty set
//! and publishes no algorithm at all; the corpus inventory records that row
//! with `has_api = false` rather than substituting the `xxh32` package for it.
//!
//! `mini` and `mini-wire` register the same module name, because both are the
//! crate `mini`: `test/mini.json` declares `crate_name: "mini"`. The corpus
//! therefore names each row by its row id rather than by the module name its
//! package published, which is what the import section below is for.
//!
//! ## Import names
//!
//! The aggregate binds each name below to a corpus row. A name equal to a row
//! id selects exactly one row; a name equal to a width-suffixed group's base
//! id — `hex` selects `hex-w32` on a 32-bit target and `hex-w64` on a 64-bit
//! one — selects one row per pointer width. Nothing here names a crate that is
//! absent from the corpus. A row id also names the row when two rows publish
//! the same module name, which is how `mini-wire` reaches the canonical v6
//! wire package instead of colliding with the `mini` one.
//! Its runtime binding comes from adler's registered module import table, so
//! buffered-reader types have exactly the identity used by that package.
//!
//! ## Trait paths
//!
//! `WyHash`'s `write`/`finish` and `WyRng`'s `next_u64`/`seed_from_u64` are
//! external trait implementations (`core::hash::Hasher`, `rand_core::{RngCore,
//! SeedableRng}`), not inherent methods: calling them is the claim that those
//! impls lowered. `FnvHasher`'s `write`/`finish` are a `core::hash::Hasher`
//! impl for the same reason. `adler`'s `adler32` is a generic function whose
//! `BufRead` bound is only satisfiable through the runtime's buffered reader, so
//! calling it is the claim that `default = ["std"]` reached the package.
//!
//! Two of those calls answer a Rust `Result` whose error arm is not a bare set
//! of variants, so the runtime gives them the TAGGED `r2z.Result` union rather
//! than a Zig error union and `try` does not apply to either. `adler32` answers
//! `io::Result<u32>` and the runtime holds `io::Error` as a payload-carrying
//! `r2z.io.Error`; `hex`'s `encode_to_slice`/`decode_to_slice` answer
//! `Result<(), FromHexError>` and `InvalidHexCharacter` carries a `c` and an
//! `index`. Success is therefore read off the `Ok` arm with `unwrap` — the same
//! call the crate's own promoted tests make — and a failure is compared against a
//! constructed `r2z.Result`, since `std.testing.expectError` inspects the else
//! arm of an error union and would be handed an enum tag where it wants an error.

const std = @import("std");
const r2z = @import("r2z");
const mini = @import("mini");
const mini_wire = @import("mini-wire");
const multimod = @import("multimod");
const fnv = @import("fnv");
const leb128 = @import("leb128");
const hex = @import("hex");
const wyhash = @import("wyhash");
const adler = @import("adler");
const xxhash_xxh32 = @import("xxhash-xxh32");

// ── mini ────────────────────────────────────────────────────────────────────

test "mini area distinguishes the two Shape payloads" {
    // `Shape::Circle(r)` is `r * r * 3.14159`; `Shape::Rect { width, height }`
    // is their product.
    try std.testing.expectEqual(9.0 * 3.14159, mini.area(.{ .Circle = 3.0 }));
    try std.testing.expectEqual(12.0, mini.area(.{ .Rect = .{ .width = 3.0, .height = 4.0 } }));
}

test "mini origin and the re-exported util helper keep their exact values" {
    const point = mini.origin();
    try std.testing.expectEqual(@as(i32, 0), point.x);
    try std.testing.expectEqual(@as(i32, 0), point.y);
    // `pub use util::helper` re-exports the submodule function at the crate root.
    try std.testing.expectEqual(@as(u8, 42), mini.helper(41));
}

// ── mini through the canonical v6 wire fixture ──────────────────────────────

test "mini-wire decodes the crate's own values out of canonical v6 wire" {
    // Same source, same numbers, a different pipeline: `test/mini.json` was
    // encoded from `test/crates/mini` and is decoded here rather than analysed.
    // `test/crates/mini/src/lib.rs:19-24` makes `Shape::Circle(r)` `r * r *
    // 3.14159` and `Shape::Rect { width, height }` their product.
    try std.testing.expectEqual(9.0 * 3.14159, mini_wire.area(.{ .Circle = 3.0 }));
    try std.testing.expectEqual(12.0, mini_wire.area(.{ .Rect = .{ .width = 3.0, .height = 4.0 } }));

    const point = mini_wire.origin();
    try std.testing.expectEqual(@as(i32, 0), point.x);
    try std.testing.expectEqual(@as(i32, 0), point.y);
    // `pub use util::helper` reaches the crate root as a namespace re-export,
    // and `util::helper(n)` answers `n + 1`.
    try std.testing.expectEqual(@as(u8, 42), mini_wire.helper(41));
}

test "mini-wire agrees with the source row value for value" {
    // The strong form. The literals above are what the crate's source says, so
    // a decoder that dropped an item could still satisfy the two it names. This
    // ties the wire row to the source row across every value the crate
    // publishes: the two rows are the same crate, so any value that differs
    // between them is a wire round trip that lost or changed something.
    try std.testing.expectEqual(mini.area(.{ .Circle = 3.0 }), mini_wire.area(.{ .Circle = 3.0 }));
    try std.testing.expectEqual(mini.area(.{ .Circle = 12.5 }), mini_wire.area(.{ .Circle = 12.5 }));
    try std.testing.expectEqual(
        mini.area(.{ .Rect = .{ .width = 3.0, .height = 4.0 } }),
        mini_wire.area(.{ .Rect = .{ .width = 3.0, .height = 4.0 } }),
    );
    try std.testing.expectEqual(
        mini.area(.{ .Rect = .{ .width = -2.5, .height = 8.0 } }),
        mini_wire.area(.{ .Rect = .{ .width = -2.5, .height = 8.0 } }),
    );
    // Field by field, not the whole struct: the two rows publish their own
    // `Point`, and comparing across two unrelated struct types would compare
    // identities rather than values.
    const from_source = mini.origin();
    const from_wire = mini_wire.origin();
    try std.testing.expectEqual(from_source.x, from_wire.x);
    try std.testing.expectEqual(from_source.y, from_wire.y);
    try std.testing.expectEqual(mini.helper(41), mini_wire.helper(41));
}

// ── multimod ────────────────────────────────────────────────────────────────

test "multimod publishes the root function and the path-declared module" {
    // `enter` is the crate root's own function, and `custom_pub` is the module
    // `#[path = "custom.rs"] pub mod custom_pub;` declares, so both are
    // nameable from outside the crate.
    try std.testing.expectEqual(@as(u32, 42), multimod.enter());
    try std.testing.expectEqual(@as(u32, 5), multimod.custom_pub.custom_fn());

    // `foo` is the one module the fixture keeps private — `mod foo;` with no
    // `pub` — so `multimod::foo::foo_fn` and the `mod bar;` beneath it are not
    // nameable here, and `enter()` does not call them either, which leaves no
    // public path to their two constants. The crate's own `#[cfg(test)]` module
    // is where an item only a sibling module can reach belongs; asking for them
    // by name from a consumer would be the fixture publishing something its
    // source never published.
}

// ── fnv ─────────────────────────────────────────────────────────────────────

/// The FNV-1a vectors `test/crates/fnv/lib.rs`'s own `basic_tests` asserts,
/// with the input kept beside the value so a mis-keyed table is visible.
const fnv_vectors = [_]struct { input: []const u8, expected: u64 }{
    .{ .input = "", .expected = 0xcbf29ce484222325 },
    .{ .input = "a", .expected = 0xaf63dc4c8601ec8c },
    .{ .input = "b", .expected = 0xaf63df4c8601f1a5 },
    .{ .input = "c", .expected = 0xaf63de4c8601eff2 },
    .{ .input = "fo", .expected = 0x08985907b541d342 },
    .{ .input = "foo", .expected = 0xdcb27518fed9d577 },
    .{ .input = "foobar", .expected = 0x85944171f73967e8 },
    .{ .input = "chongo was here!", .expected = 0x858e2fa32a55e61d },
    .{ .input = "chongo was here!\n", .expected = 0x46810940eff5f915 },
    .{ .input = "\x00", .expected = 0xaf63bd4c8601b7df },
    .{ .input = "a\x00", .expected = 0x089be207b544f1e4 },
};

/// The offset basis the crate's `Default for FnvHasher` installs. `with_key`
/// is the crate's own inherent constructor for exactly this state.
const fnv_offset_basis: u64 = 0xcbf29ce484222325;

test "fnv FnvHasher matches the crate's basic_tests vectors" {
    for (fnv_vectors) |vector| {
        var hasher = fnv.FnvHasher.with_key(fnv_offset_basis);
        hasher.write(vector.input);
        try std.testing.expectEqual(vector.expected, hasher.finish());
    }
}

test "fnv write accumulates state across calls instead of replacing it" {
    var streamed = fnv.FnvHasher.with_key(fnv_offset_basis);
    streamed.write("foo");
    streamed.write("bar");
    var one_shot = fnv.FnvHasher.with_key(fnv_offset_basis);
    one_shot.write("foobar");
    try std.testing.expectEqual(one_shot.finish(), streamed.finish());
}

// ── leb128 ──────────────────────────────────────────────────────────────────

test "leb128 clears the continuation and sign bits exactly as the crate does" {
    // `low_bits_of_byte(byte) = byte & !CONTINUATION_BIT`.
    try std.testing.expectEqual(@as(u8, 0x7f), leb128.low_bits_of_byte(0xff));
    try std.testing.expectEqual(@as(u8, 0x00), leb128.low_bits_of_byte(0x80));
    // 0x7f already has the continuation bit clear, so the clear is a no-op:
    // `0x7f & !0x80 == 0x7f`, not `0xff`.
    try std.testing.expectEqual(@as(u8, 0x7f), leb128.low_bits_of_byte(0x7f));
    // `low_bits_of_u64(val)` keeps the low byte and clears the same bit.
    try std.testing.expectEqual(@as(u8, 0x34), leb128.low_bits_of_u64(0x1234));
    // Same operation one level down: the low byte of 0x80 is 0x80, and
    // `low_bits_of_byte(0x80) == 0x00`.
    try std.testing.expectEqual(@as(u8, 0x00), leb128.low_bits_of_u64(0x80));
    try std.testing.expectEqual(@as(u8, 0x80), leb128.CONTINUATION_BIT);
    try std.testing.expectEqual(@as(u8, 0x40), leb128.SIGN_BIT);
}

// ── hex ─────────────────────────────────────────────────────────────────────

test "hex encodes and decodes kiwi through the crate's slice entry points" {
    // Both entry points answer `Result<(), FromHexError>`, and `FromHexError`'s
    // `InvalidHexCharacter` variant carries a `c` and an `index`, so the
    // runtime's shape is the TAGGED `r2z.Result` union rather than a Zig error
    // union and `try` would not accept it. Reading the `Ok` arm is spelled
    // `unwrap`, the same call the crate's own promoted `src/test.zig` makes;
    // the payload is `void`, so nothing is handed back and nothing is released.
    var encoded: [8]u8 = undefined;
    hex.encode_to_slice([]const u8, "kiwi", &encoded).unwrap(std.testing.allocator);
    try std.testing.expectEqualStrings("6b697769", &encoded);

    var decoded: [4]u8 = undefined;
    hex.decode_to_slice([]const u8, "6b697769", &decoded).unwrap(std.testing.allocator);
    try std.testing.expectEqualStrings("kiwi", &decoded);
}

test "hex refuses a mismatched destination length through the crate's error" {
    // `encode_to_slice` requires `input.len() * 2 == output.len()`; the crate
    // answers `InvalidStringLength`, not a truncated write.
    //
    // Both failures are asserted against a constructed `r2z.Result`, which is
    // the shape the crate's own promoted `src/test.zig` compares with.
    // `std.testing.expectError` cannot say it here: it reads the ELSE arm of an
    // error union and hands it to `@errorName`, and this value is a tagged
    // union whose failure arm is the crate's own `FromHexError`, not an error.
    // Comparing the whole union keeps the claim exact — the variant AND its
    // payload, so an `OddLength` can never satisfy the `InvalidStringLength`
    // row — where reading the tag alone would let any `FromHexError` through.
    var too_short: [4]u8 = undefined;
    try std.testing.expect(r2z.ops.binary(
        r2z.ops.Operation.eq,
        r2z.ops.Overflow.wrapping,
        hex.encode_to_slice([]const u8, "kiwi", &too_short),
        r2z.Result(void, hex.FromHexError){ .Err = hex.FromHexError{ .InvalidStringLength = @as(void, {}) } },
    ));
    // An odd input has no whole byte to decode. `decode_to_slice` answers
    // `OddLength` before it ever looks at `out`, so the mismatched `[4]u8`
    // destination below is deliberately never the reason this fails.
    var decoded: [4]u8 = undefined;
    try std.testing.expect(r2z.ops.binary(
        r2z.ops.Operation.eq,
        r2z.ops.Overflow.wrapping,
        hex.decode_to_slice([]const u8, "6b6977", &decoded),
        r2z.Result(void, hex.FromHexError){ .Err = hex.FromHexError{ .OddLength = @as(void, {}) } },
    ));
}

// ── xxhash-rust with an explicit xxh32 selection ────────────────────────────

/// The published XXH32 seed-0 vectors for the algorithm this crate implements.
/// The crate's own `tests/` need the C library, so the algorithm's reference
/// vectors are the published ones rather than a table checked into the fixture.
const xxh32_vectors = [_]struct { input: []const u8, expected: u32 }{
    .{ .input = "", .expected = 0x02cc5d05 },
    .{ .input = "a", .expected = 0x550d7456 },
    .{ .input = "abc", .expected = 0x32d153ff },
};

test "xxh32 one-shot hashing matches the published XXH32 seed-0 vectors" {
    for (xxh32_vectors) |vector| {
        try std.testing.expectEqual(vector.expected, xxhash_xxh32.xxh32.xxh32(vector.input, 0));
    }
}

test "xxh32 streaming digest agrees with the one-shot hash at every seed" {
    const seeds = [_]u32{ 0, 1, 0x1234_5678, 0xffff_ffff };
    for (seeds) |seed| {
        for (xxh32_vectors) |vector| {
            var streaming = xxhash_xxh32.xxh32.Xxh32.new(seed);
            streaming.update(vector.input);
            try std.testing.expectEqual(
                xxhash_xxh32.xxh32.xxh32(vector.input, seed),
                streaming.digest(),
            );
        }
    }
}

test "xxh32 reset returns the state to a freshly seeded one" {
    var hasher = xxhash_xxh32.xxh32.Xxh32.new(7);
    hasher.update("discarded");
    hasher.reset(7);
    hasher.update("abc");
    try std.testing.expectEqual(xxhash_xxh32.xxh32.xxh32("abc", 7), hasher.digest());
}

// ── wyhash ──────────────────────────────────────────────────────────────────

test "wyhash free function matches the crate's documented vector" {
    // `src/lib.rs`: `wyhash(&[0, 1, 2], 3) == 0xb0f9_4152_0b1a_d95d`.
    try std.testing.expectEqual(@as(u64, 0xb0f9_4152_0b1a_d95d), wyhash.wyhash(&.{ 0, 1, 2 }, 3));
}

/// The canonical digests `tests/back_to_back_hash.rs` records — "results from
/// the cannonical C implementation", misspelling included — each produced as
/// `wyhash(&data[..length], length)` over `data[i] = i as u8`. These are the
/// same numbers the native oracle proves against pristine Rust as
/// `wyhash_original_len{length}` and `wyhash_hasher_len{length}` in
/// `test/rust-corpus-oracle/src/main.rs`.
///
/// `read_rest` and `read64` cannot be named from here: `read64` is `pub fn`
/// but lives in `mod functions;`, which `test/crates/wyhash/src/lib.rs`
/// declares without `pub` and re-exports only `{wyhash, wyrng}`, and
/// `read_rest` is a private `fn` besides. Their byte ordering is still
/// observable, because `wyhash_core` picks the reader by length
/// (`src/functions.rs:88-117`): a `len & 31` remainder of 1..=8 goes through
/// `read_rest`, 9..=16 through `read64_swapped` plus `read_rest`, 17..=24 and
/// 25..=31 through two and three `read64_swapped` reads plus `read_rest`, and
/// only a whole 32-byte chunk reaches the big-endian `read64`. So lengths 1
/// through 8 pin every `read_rest` arm — including the two that pack
/// big-endian rather than little — 9 is the first `read64_swapped` window, 16
/// the first with a trailing `read_rest`, and 32 the `read64` path itself.
const wyhash_reader_cases = [_]struct { length: usize, digest: u64 }{
    .{ .length = 0, .digest = 0xf961_f936_e29c_9345 },
    .{ .length = 1, .digest = 0x83fc_be65_1268_30a3 },
    .{ .length = 2, .digest = 0xcaed_38c4_bfba_7448 },
    .{ .length = 3, .digest = 0xb0f9_4152_0b1a_d95d },
    .{ .length = 4, .digest = 0x22fc_0d05_b565_5593 },
    .{ .length = 5, .digest = 0xaf96_3b6c_a51a_b9dd },
    .{ .length = 6, .digest = 0x8ae9_d75b_a5a8_41b8 },
    .{ .length = 7, .digest = 0xfd1d_46ec_d66b_6c3b },
    .{ .length = 8, .digest = 0x276e_8d03_15af_0b78 },
    .{ .length = 9, .digest = 0x8712_dbf1_d543_727b },
    .{ .length = 16, .digest = 0x9510_7695_67e2_b9f5 },
    .{ .length = 32, .digest = 0x39e6_24e6_0cf0_44f5 },
};

test "wyhash byte ordering is observable through both public entry points" {
    // The free function and the `core::hash::Hasher` impl are two spellings of
    // one fold (`src/lib.rs:67-70` against `src/traits.rs:21-30`), so every
    // length is asserted through both: a reader whose byte order differs
    // changes the digest on both paths, and neither can be satisfied by
    // agreeing with itself alone. The empty row holds because `Hasher::write`
    // folds an empty argument with `mix_with_p0` (`src/traits.rs:22-23`), which
    // is exactly what `wyhash_core` does to a zero-length buffer before its
    // `len & 31` remainder turns out to be zero.
    const gpa = std.testing.allocator;
    const input = try gpa.alloc(u8, wyhash_reader_cases[wyhash_reader_cases.len - 1].length);
    defer gpa.free(input);
    for (input, 0..) |*byte, index| byte.* = @truncate(index);

    for (wyhash_reader_cases) |case| {
        const chunk = input[0..case.length];
        const seed: u64 = @intCast(case.length);
        try std.testing.expectEqual(case.digest, wyhash.wyhash(chunk, seed));

        var hasher = wyhash.WyHash.with_seed(seed);
        hasher.write(chunk);
        try std.testing.expectEqual(case.digest, hasher.finish());
    }
}

// The fixture's two upstream documents disagree about the SAME call, and the
// translator has to reproduce one of them. `test/crates/wyhash/src/lib.rs:46-49`
// says `WyHash::with_seed(3)` then `write(&[0, 1, 2])` finishes at
// `0xb0f9_4152_0b1a_d95d`; `test/crates/wyhash/README.md:27-29` says the
// identical sequence finishes at `0xcc24_2106_e707_6a48`. The fixture's own
// `#[cfg(test)]` module covers only `read_rest` and `read64`, so neither value
// is settled inside the crate. These expectations take the value from the crate
// SOURCE, because translating that source is what is under test; a literal from
// the README would assert a different program from the one being translated.
// Whichever upstream value is correct, the two tests below are the signal: they
// must agree with each other regardless, and they must agree with
// `test/crates/wyhash/src/lib.rs` for the translation to be faithful.
test "wyhash WyHash trait write and finish match the free function" {
    // `src/lib.rs`: `WyHash::with_seed(3)`, one write of `[0, 1, 2]`, then
    // `finish()` equals the same value the free function produces. `write` and
    // `finish` are a `core::hash::Hasher` impl, not inherent methods.
    var hasher = wyhash.WyHash.with_seed(3);
    hasher.write(&.{ 0, 1, 2 });
    try std.testing.expectEqual(@as(u64, 0xb0f9_4152_0b1a_d95d), hasher.finish());
}

test "wyhash WyHash streaming preserves native per-write behavior at 32-byte boundaries" {
    // `Hasher::write` (`src/traits.rs:21-30`) hands its whole argument to one
    // `wyhash_core` call, and `wyhash_core` folds `mix_with_p0` into the seed on
    // every call (`src/functions.rs:86`). A split across two writes therefore
    // folds `P0` twice and does NOT reproduce `wyhash(input, seed)`, so each
    // split carries its own digest. These are the native digests of the
    // pristine wyhash 0.4.0 rlib for this exact 96-byte input and seed;
    // `split == input.len` is a single write, so that row is also the free
    // function's value for the whole buffer.
    const gpa = std.testing.allocator;
    const input = try gpa.alloc(u8, 96);
    defer gpa.free(input);
    for (input, 0..) |*byte, index| byte.* = @truncate(index);

    const seed = 0xabcd_ef01_2345_6789;
    const split_cases = [_]struct { split: usize, digest: u64 }{
        .{ .split = 32, .digest = 0xfffc_aabc_a9ca_0496 },
        .{ .split = 64, .digest = 0xbd1d_ffa2_88b2_19f6 },
        .{ .split = 96, .digest = 0x80c2_a977_251b_aafc },
    };
    for (split_cases) |case| {
        var hasher = wyhash.WyHash.with_seed(seed);
        hasher.write(input[0..case.split]);
        if (case.split != input.len) hasher.write(input[case.split..]);
        try std.testing.expectEqual(case.digest, hasher.finish());
    }
}

test "wyhash WyHash single write reproduces the free function at 32-byte multiples" {
    // One `write` of `bytes` is exactly `wyhash(bytes, seed)`: `finish` is
    // `wyhash_finish(size, h)` with `size == bytes.len()` and
    // `h == wyhash_core(bytes, seed)` (`src/traits.rs:21-30`,
    // `src/functions.rs:67-70`). 32, 64 and 96 run one, two and three
    // `chunks_exact(32)` rounds with no tail (`src/functions.rs:79`).
    const gpa = std.testing.allocator;
    const input = try gpa.alloc(u8, 96);
    defer gpa.free(input);
    for (input, 0..) |*byte, index| byte.* = @truncate(index);

    const seed = 0xabcd_ef01_2345_6789;
    const prefix_cases = [_]struct { length: usize, digest: u64 }{
        .{ .length = 32, .digest = 0x622f_b280_62d4_8ef9 },
        .{ .length = 64, .digest = 0xe166_09e1_e867_61d4 },
        .{ .length = 96, .digest = 0x80c2_a977_251b_aafc },
    };
    for (prefix_cases) |case| {
        const chunk = input[0..case.length];
        var hasher = wyhash.WyHash.with_seed(seed);
        hasher.write(chunk);
        try std.testing.expectEqual(wyhash.wyhash(chunk, seed), hasher.finish());
        try std.testing.expectEqual(case.digest, hasher.finish());
    }
}

test "wyhash wyrng matches the crate's documented sequence and seed update" {
    // `src/lib.rs`: `wyrng(&mut seed)` with `seed = 3` returns
    // `0x3e9a_7727_50dc_be` and leaves the seed at `0xa076_1d64_78bd_6432`,
    // which is `3` plus the crate's `P0`.
    var seed: u64 = 3;
    try std.testing.expectEqual(@as(u64, 0x3e9a_7727_50dc_be), wyhash.wyrng(&seed));
    try std.testing.expectEqual(@as(u64, 0xa076_1d64_78bd_6432), seed);
}

test "wyhash WyRng seeding and drawing match the crate's documented vectors" {
    // `seed_from_u64` is a `rand_core::SeedableRng` impl and `next_u64` is a
    // `rand_core::RngCore` impl. `WyRng` derives `Default`, and `Default` for
    // `WyRng(u64)` is `WyRng(0)`, which is exactly `seed_from_u64(0)`; both
    // spellings are asserted here so the documented default is covered without
    // depending on how a derived tuple-struct default is spelled in Zig.
    var from_seed_three = wyhash.WyRng.seed_from_u64(3);
    try std.testing.expectEqual(@as(u64, 0x3e9a_7727_50dc_be), from_seed_three.next_u64());

    var from_default = wyhash.WyRng.seed_from_u64(0);
    try std.testing.expectEqual(@as(u64, 0x111c_b3a7_8f59_a58e), from_default.next_u64());

    // `from_seed` reads the eight seed bytes little-endian through `read64`.
    var from_bytes = wyhash.WyRng.from_seed(.{ 0, 1, 2, 3, 4, 5, 6, 7 });
    try std.testing.expectEqual(@as(u64, 0xd730_1357_74c6_ae31), from_bytes.next_u64());
}

test "wyhash WyRng next_u32 is the low half of the next u64" {
    var wide = wyhash.WyRng.seed_from_u64(3);
    const wide_value = wide.next_u64();
    var narrow = wyhash.WyRng.seed_from_u64(3);
    try std.testing.expectEqual(@as(u32, @truncate(wide_value)), narrow.next_u32());
}

// ── adler ───────────────────────────────────────────────────────────────────

test "adler adler32_slice matches the crate's own test vectors" {
    // `src/lib.rs` `wiki` and `zeroes`/`mixed`.
    try std.testing.expectEqual(@as(u32, 0x11e60398), adler.adler32_slice("Wikipedia"));
    try std.testing.expectEqual(@as(u32, 1), adler.adler32_slice(""));
    try std.testing.expectEqual(@as(u32, 0x0064_0001), adler.adler32_slice(&@as([100]u8, @splat(0))));
    try std.testing.expectEqual(@as(u32, 0x0400_0001), adler.adler32_slice(&@as([1024]u8, @splat(0))));
    try std.testing.expectEqual(@as(u32, 0x00f0_0001), adler.adler32_slice(&@as([1024 * 1024]u8, @splat(0))));
    try std.testing.expectEqual(@as(u32, 0xd500_9ab1), adler.adler32_slice(&@as([1024 * 1024]u8, @splat(0xA5))));
}

test "adler Adler32 resumes from a recorded checksum" {
    // `src/lib.rs` `resume`: 1 KiB of 0xff then the rest must reach the value
    // the same 1 MiB run produces, and resuming from the partial checksum must
    // reach it too.
    var whole = adler.Adler32.new();
    whole.write_slice(&@as([1024 * 1024]u8, @splat(0xff)));
    const whole_sum = whole.checksum();

    var partial_run = adler.Adler32.new();
    partial_run.write_slice(&@as([1024]u8, @splat(0xff)));
    const partial_sum = partial_run.checksum();
    try std.testing.expectEqual(@as(u32, 0x79a6_fc2e), partial_sum);

    var resumed = adler.Adler32.from_checksum(partial_sum);
    resumed.write_slice(&@as([1024 * 1024 - 1024]u8, @splat(0xff)));
    try std.testing.expectEqual(whole_sum, resumed.checksum());
}

/// The four inputs `src/lib.rs`'s `bufread` test runs. Its own comment records
/// why the sizes are what they are: the standard buffered reader holds 8 KiB, so
/// anything at or above 1 KiB exercises refilling.
const adler_bufread_cases = [_]struct { name: []const u8, length: usize, fill: u8, expected: u32 }{
    .{ .name = "empty", .length = 0, .fill = 0, .expected = 1 },
    .{ .name = "1024 zeroes", .length = 1024, .fill = 0x00, .expected = 0x0400_0001 },
    .{ .name = "1 MiB zeroes", .length = 1024 * 1024, .fill = 0x00, .expected = 0x00f0_0001 },
    .{ .name = "1 MiB of 0xA5", .length = 1024 * 1024, .fill = 0xA5, .expected = 0xd500_9ab1 },
};

/// Checksum `bytes` through the crate's `BufRead` path: a real buffered reader
/// over a borrowed slice, so the crate drains it with `fill_buf`/`consume` and
/// its 8 KiB buffer really does refill.
///
/// `adler32` is generic over `R: BufRead` and is `#[cfg(feature = "std")]`, so
/// resolving it here also proves the manifest's `default = ["std"]` closure
/// reached the package: without it neither the function nor this call exists.
fn adler32OverBufReader(bytes: []const u8) !u32 {
    // Rust's own call is `adler32(&mut buf)`, so R is a `&mut BufReader<&[u8]>`:
    // a pointer, with the mutability in the type. A Zig function parameter is
    // immutable, so the same shape needs a mutable binding and a pointer, and
    // the comptime type argument describes exactly what is passed.
    var buffered: r2z.io.BufReader(r2z.io.SliceReader) =
        r2z.io.BufReader(r2z.io.SliceReader).init(r2z.io.SliceReader.init(bytes));
    // `adler32` answers `io::Result<u32>`, and the runtime holds `io::Error` as
    // a payload-carrying `r2z.io.Error`, so the return is the TAGGED
    // `r2z.Result` union, not a Zig error union: `try` would not accept it.
    // Reading the `Ok` arm is what Rust's own `bufread` test writes as the
    // `.unwrap()` on `adler32(&mut buf)`.
    return adler.adler32(@TypeOf(&buffered), &buffered).unwrap(std.testing.allocator);
}

test "adler adler32 over a buffered reader matches the crate's bufread vectors" {
    const gpa = std.testing.allocator;
    for (adler_bufread_cases) |case| {
        const bytes = try gpa.alloc(u8, case.length);
        defer gpa.free(bytes);
        @memset(bytes, case.fill);
        try std.testing.expectEqual(case.expected, try adler32OverBufReader(bytes));
    }
}

test "adler adler32 over a buffered reader agrees with the slice path" {
    // The strong form: the streaming result is tied to the slice result for the
    // same bytes, not only to a table of constants.
    const gpa = std.testing.allocator;
    for (adler_bufread_cases) |case| {
        const bytes = try gpa.alloc(u8, case.length);
        defer gpa.free(bytes);
        @memset(bytes, case.fill);
        try std.testing.expectEqual(adler.adler32_slice(bytes), try adler32OverBufReader(bytes));
    }
}
