//! Consumer tests for `itoa`, the one crate of the original promoted four that
//! stages a package, compiles it and runs it.
//!
//! ## Why this file names one crate and not four
//!
//! `siphasher`, `itoa`, `seahash` and `atoi` used to be staged together and
//! compiled here against all four packages. Three of them no longer publish a
//! package at all: each now ANALYSES — `translate-rust --dump rustir` records
//! no non-assertion unsupported node in any of them — and the backend still
//! refuses each one, so there is no `src/root.zig` for this consumer to
//! `@import`. `siphasher` refuses `IncompleteGenericMetadata` in
//! `validateInstantiations`, `seahash` refuses `UnsupportedPattern` while
//! lowering a struct pattern, and `atoi` refuses `UnsupportedExpression` on an
//! operator whose operands the frontend will not admit. A vector this file kept
//! for any of them would be a vector against a package that does not exist, so
//! it would pass for a reason that had nothing to do with the crate.
//!
//! Those three boundaries are still pinned, just not here: `test/e2e_test.zig`
//! holds one refusal expectation per crate, each bound to that exact typed
//! error. The day one of them publishes a package, that row fails with
//! `UnsupportedSourceTranslated` and the vectors come back here.
//!
//! `itoa` is the fourth. Its manifest declares no `default` feature, so the
//! `usize`/`isize` `Integer` impls are behind `target_pointer_width` and the
//! package this consumer is compiled against is analysed at the host width.
//!
//! ## Where the expectations come from
//!
//! The decimal renderings are `itoa/tests/test.rs`'s own published table, kept
//! verbatim: `test_u64_0`, `test_u64_half`, `test_u64_max`, `test_i64_min`,
//! `test_i16_0`, `test_i16_min`, `test_u128_0`, `test_u128_max`, `test_i128_min`
//! and `test_i128_max`. The two extra width rows below are named as what they
//! are — the type extremes `itoa/src/lib.rs`'s per-width `write` implementations
//! must render, not upstream table rows. Together they exercise all four
//! digit paths: the four-digits-at-a-time table, the divide-by-1e19 path, and
//! the signed and unsigned 128-bit branches.
//!
//! Nothing in this file reimplements a decimal formatter: the crate under test
//! produces every number that is compared, and no assertion reads emitted
//! source text.
//!
//! ## Invocation
//!
//! Built like the `test/compat_consumer.zig` invocation in
//! `test/e2e_test.zig`, with the one staged package this file imports:
//!
//!     zig test \
//!         --dep itoa --dep r2z \
//!         -Mroot=test/promoted_crates_consumer.zig \
//!         --dep r2z \
//!         -Mitoa=zig-out/e2e-translated-source-itoa/src/root.zig \
//!         -Mr2z=r2z-core/src/root.zig
//!
//! `--dep r2z` is required twice over: once for this root, and once for the
//! translated package, whose generated `src/root.zig` also does
//! `const r2z = @import("r2z");`. This root does not name `r2z` itself; the
//! aggregate in `test/generated_corpus.zig` supplies it from the row it picks.

const std = @import("std");
const itoa = @import("itoa");

// ── itoa ────────────────────────────────────────────────────────────────────

// `itoa::Buffer::format` is `pub fn format<I: Integer>(&mut self, i: I) -> &str`,
// so the generated method carries the type parameter explicitly ahead of the
// value.
test "itoa Buffer::format renders the upstream u64 and i64 boundaries" {
    var buffer = itoa.Buffer.new();
    try std.testing.expectEqualStrings("0", buffer.format(u64, @as(u64, 0)));
    try std.testing.expectEqualStrings("4294967295", buffer.format(u64, @as(u64, 4294967295)));
    try std.testing.expectEqualStrings("18446744073709551615", buffer.format(u64, @as(u64, std.math.maxInt(u64))));
    try std.testing.expectEqualStrings("-9223372036854775808", buffer.format(i64, @as(i64, std.math.minInt(i64))));
}

test "itoa Buffer::format renders the i16 and u16 width extremes" {
    var buffer = itoa.Buffer.new();
    try std.testing.expectEqualStrings("0", buffer.format(i16, @as(i16, 0)));
    try std.testing.expectEqualStrings("-32768", buffer.format(i16, @as(i16, std.math.minInt(i16))));
    try std.testing.expectEqualStrings("32767", buffer.format(i16, @as(i16, std.math.maxInt(i16))));
    try std.testing.expectEqualStrings("65535", buffer.format(u16, @as(u16, std.math.maxInt(u16))));
}

test "itoa Buffer::format renders the upstream 128-bit boundaries" {
    var buffer = itoa.Buffer.new();
    try std.testing.expectEqualStrings("0", buffer.format(u128, @as(u128, 0)));
    try std.testing.expectEqualStrings(
        "340282366920938463463374607431768211455",
        buffer.format(u128, @as(u128, std.math.maxInt(u128))),
    );
    try std.testing.expectEqualStrings(
        "-170141183460469231731687303715884105728",
        buffer.format(i128, @as(i128, std.math.minInt(i128))),
    );
    try std.testing.expectEqualStrings(
        "170141183460469231731687303715884105727",
        buffer.format(i128, @as(i128, std.math.maxInt(i128))),
    );
}

// The crate documents `Buffer` as safe to reuse between calls; the two
// renderings must not alias into one another.
test "itoa Buffer reuse does not alias the previous rendering" {
    var buffer = itoa.Buffer.new();
    try std.testing.expectEqualStrings("1", buffer.format(u32, @as(u32, 1)));
    try std.testing.expectEqualStrings("2", buffer.format(u32, @as(u32, 2)));
}
