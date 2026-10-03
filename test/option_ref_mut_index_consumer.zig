//! Consumer tests for the translated `option-ref-mut-index` package.
//!
//! One test per claim `test/crates/option-ref-mut-index/src/lib.rs` makes, and
//! every claim is stated twice: once through the package's `&mut Vec<Option<u32>>`
//! receiver and once through its `&mut [Option<u32>]` one. Both name one element
//! of storage the caller owns, and both have to yield a place the arm's
//! `Some(ref mut …)` borrow can point into.
//!
//! Every vector in this file is built over a buffer the test itself declares, so
//! a write the package made is read back out of the caller's own bytes and not
//! out of anything the package reports about itself. Nothing here reimplements
//! the fixture: it only writes a value it is handed through an index, so the
//! sole question each answer asks is where that write landed, what it left
//! behind, and how many times the receiver ran to do it.
//!
//! The element type is the real `Option<u32>` and is spelled as one throughout:
//! the seeds below are optionals, the storage is `?u32` storage, and
//! `read_vec_entry` / `read_slice_entry` hand a `?u32` back that this file
//! compares against the one it built. A stand-in enum with a tag of its own
//! could not appear in any of those places.
//!
//! Built like the `test/compat_consumer.zig` invocation in `test/e2e_test.zig`,
//! with the generated package root in place of the compat one. The package root
//! imports `r2z` itself — reading an element's payload by value goes through
//! `r2z.option.unwrap` — so it needs its own `--dep r2z`:
//!
//!     zig test --dep translated \
//!         -Mroot=test/option_ref_mut_index_consumer.zig \
//!         --dep r2z -Mtranslated=<generated>/src/root.zig \
//!         -Mr2z=r2z-core/src/root.zig

const std = @import("std");
const translated = @import("translated");

/// The elements a vector starts with: three distinguishable payloads and one
/// empty slot among them.
///
/// Each payload is a value no other element holds, so a write that reached the
/// wrong element, reached every element, or reached the empty one is told apart
/// from a write that reached the element the index named. The empty slot sits
/// between two populated ones, so a write that ran past the index in either
/// direction lands on something this file can see.
const seeds = [_]?u32{ 10, 11, null, 13 };

/// A vector over the buffer `storage` names, filled with `seeds`.
///
/// The list is built on a caller-owned buffer rather than an allocated one, so
/// the package is handed storage this file already holds and every element is
/// read back here afterwards. The buffer's length is the capacity `initBuffer`
/// takes, and the appends below are what make the elements visible to the
/// package; `storage` must outlive the list, so every test declares its own.
///
/// `std.ArrayList` is the type the translated signature spells as
/// `std.ArrayListUnmanaged`: one type under two names, and the newer name is
/// the one this file writes.
fn seeded(storage: *[seeds.len]?u32) std.ArrayList(?u32) {
    var list: std.ArrayList(?u32) = .initBuffer(storage);
    for (seeds) |seed| list.appendAssumeCapacity(seed);
    return list;
}

// `Some(ref mut …)` bound out of an INDEXED element writes that element and no
// other, and the indexed receiver is evaluated exactly once to do it.
//
// `cursor` is what says "once": the index expression moves it, so a lowering
// that read the scrutinee twice — once to test it against `None` and once to
// borrow the payload — moves it twice for one write.
test "a vector write reaches the element the index named and no other" {
    var storage: [seeds.len]?u32 = undefined;
    var values = seeded(&storage);
    var cursor: u32 = 0;

    try std.testing.expectEqual(@as(u32, 99), translated.write_vec_slot(&values, 0, 99, &cursor));
    try std.testing.expectEqual(@as(u32, 1), cursor);

    // The element the index named holds the write, read back out of this test's
    // own storage through the vector the package was handed.
    try std.testing.expectEqual(@as(?u32, 99), values.items[0]);
    try std.testing.expectEqual(@as(u32, 99), values.items[0].?);

    // Every element the index did not name kept the value it was built with,
    // including the empty one, which is still empty rather than turned into a
    // payload by the write beside it.
    try std.testing.expectEqual(@as(?u32, 11), values.items[1]);
    try std.testing.expect(values.items[2] == null);
    try std.testing.expectEqual(@as(?u32, 13), values.items[3]);
    try std.testing.expectEqualSlices(?u32, &.{ 99, 11, null, 13 }, values.items);
}

// The same claim through the slice parameter. The storage is the caller's
// either way; the receiver is reached through a slice header here rather than
// through a vector's own buffer.
test "a slice write reaches the element the index named and no other" {
    var storage: [seeds.len]?u32 = undefined;
    var values = seeded(&storage);
    var cursor: u32 = 0;

    try std.testing.expectEqual(
        @as(u32, 99),
        translated.write_slice_slot(values.items, 0, 99, &cursor),
    );
    try std.testing.expectEqual(@as(u32, 1), cursor);

    try std.testing.expectEqual(@as(?u32, 99), values.items[0]);
    try std.testing.expectEqual(@as(u32, 99), values.items[0].?);
    try std.testing.expectEqual(@as(?u32, 11), values.items[1]);
    try std.testing.expect(values.items[2] == null);
    try std.testing.expectEqual(@as(?u32, 13), values.items[3]);
    try std.testing.expectEqualSlices(?u32, &.{ 99, 11, null, 13 }, values.items);

    // The write is visible through the ORIGINAL vector, not only through the
    // slice the call was handed: the two receivers name the same storage, and
    // the package's own vector reader agrees with what this test can see.
    try std.testing.expectEqual(@as(u32, 99), translated.read_vec_payload(&values, 0));
    try std.testing.expectEqual(@as(u32, 11), translated.read_vec_payload(&values, 1));
    try std.testing.expectEqual(@as(u32, 0), translated.read_vec_payload(&values, 2));
    try std.testing.expectEqual(@as(u32, 13), translated.read_vec_payload(&values, 3));
}

// An index that names an element holding no payload has nothing to borrow, so
// the arm answers zero and no write happens at all. The element stays empty —
// the zero the arm answers is not a payload written into it — the rest of the
// vector is exactly as it was built, and the receiver still ran once: an
// evaluation is owed for the index whatever the arm it feeds has to do.
test "a vector write at an empty element leaves it empty and the rest untouched" {
    var storage: [seeds.len]?u32 = undefined;
    var values = seeded(&storage);
    var cursor: u32 = 0;

    try std.testing.expectEqual(@as(u32, 0), translated.write_vec_slot(&values, 2, 99, &cursor));
    try std.testing.expectEqual(@as(u32, 1), cursor);
    try std.testing.expect(values.items[2] == null);
    try std.testing.expectEqualSlices(?u32, &seeds, values.items);
}

test "a slice write at an empty element leaves it empty and the rest untouched" {
    var storage: [seeds.len]?u32 = undefined;
    var values = seeded(&storage);
    var cursor: u32 = 0;

    try std.testing.expectEqual(
        @as(u32, 0),
        translated.write_slice_slot(values.items, 2, 99, &cursor),
    );
    try std.testing.expectEqual(@as(u32, 1), cursor);
    try std.testing.expect(values.items[2] == null);
    try std.testing.expectEqualSlices(?u32, &seeds, values.items);

    // The empty element is still empty when read back through the vector.
    try std.testing.expectEqual(@as(u32, 0), translated.read_vec_payload(&values, 2));
}

// Successive writes at three different indices. This is what tells "the borrow
// points at the element the index named" apart from "the borrow points at one
// fixed element": a receiver that always wrote index 0, or always wrote the
// first element holding a payload, leaves a different vector behind after the
// second call.
//
// The answer each call gives is the payload read back through the borrow AFTER
// the write, and every value written here differs from the one that element
// held, so an answer that came from somewhere else cannot match.
test "successive vector writes follow the index rather than a fixed element" {
    var storage: [seeds.len]?u32 = undefined;
    var values = seeded(&storage);
    var cursor: u32 = 0;

    try std.testing.expectEqual(@as(u32, 20), translated.write_vec_slot(&values, 1, 20, &cursor));
    try std.testing.expectEqualSlices(?u32, &.{ 10, 20, null, 13 }, values.items);

    try std.testing.expectEqual(@as(u32, 40), translated.write_vec_slot(&values, 3, 40, &cursor));
    try std.testing.expectEqualSlices(?u32, &.{ 10, 20, null, 40 }, values.items);

    try std.testing.expectEqual(@as(u32, 60), translated.write_vec_slot(&values, 0, 60, &cursor));
    try std.testing.expectEqualSlices(?u32, &.{ 60, 20, null, 40 }, values.items);

    // Three writes, three receiver evaluations, and no element written twice.
    try std.testing.expectEqual(@as(u32, 3), cursor);
}

test "successive slice writes follow the index rather than a fixed element" {
    var storage: [seeds.len]?u32 = undefined;
    var values = seeded(&storage);
    var cursor: u32 = 0;

    try std.testing.expectEqual(
        @as(u32, 20),
        translated.write_slice_slot(values.items, 1, 20, &cursor),
    );
    try std.testing.expectEqualSlices(?u32, &.{ 10, 20, null, 13 }, values.items);

    try std.testing.expectEqual(
        @as(u32, 40),
        translated.write_slice_slot(values.items, 3, 40, &cursor),
    );
    try std.testing.expectEqualSlices(?u32, &.{ 10, 20, null, 40 }, values.items);

    try std.testing.expectEqual(
        @as(u32, 60),
        translated.write_slice_slot(values.items, 0, 60, &cursor),
    );
    try std.testing.expectEqualSlices(?u32, &.{ 60, 20, null, 40 }, values.items);

    // Every element the vector reader sees matches the vector this test owns,
    // so the three writes all went through the slice it handed out.
    try std.testing.expectEqual(@as(u32, 20), translated.read_vec_payload(&values, 1));
    try std.testing.expectEqual(@as(u32, 0), translated.read_vec_payload(&values, 2));
    try std.testing.expectEqual(@as(u32, 40), translated.read_vec_payload(&values, 3));

    try std.testing.expectEqual(@as(u32, 3), cursor);
}

// Reading the same storage back through the package. The fixture's readers match
// on the element BY VALUE, so this also says a by-value arm left the caller's
// element alone — and that the element is a real optional, because
// `read_vec_entry` hands back a `?u32` this file compares against the one it
// built, element for element, `null` included.
test "the package reads the caller's vector back and its reads leave it alone" {
    var storage: [seeds.len]?u32 = undefined;
    var values = seeded(&storage);
    var cursor: u32 = 0;
    try std.testing.expectEqual(@as(u32, 7), translated.write_vec_slot(&values, 0, 7, &cursor));

    try std.testing.expectEqual(@as(u32, 7), translated.read_vec_payload(&values, 0));
    try std.testing.expectEqual(@as(u32, 11), translated.read_vec_payload(&values, 1));
    try std.testing.expectEqual(@as(u32, 0), translated.read_vec_payload(&values, 2));
    try std.testing.expectEqual(@as(u32, 13), translated.read_vec_payload(&values, 3));

    try std.testing.expectEqual(@as(?u32, 7), translated.read_vec_entry(&values, 0));
    try std.testing.expectEqual(@as(?u32, 11), translated.read_vec_entry(&values, 1));
    try std.testing.expectEqual(@as(?u32, null), translated.read_vec_entry(&values, 2));
    try std.testing.expectEqual(@as(?u32, 13), translated.read_vec_entry(&values, 3));

    // Nothing a by-value read did reached the caller's storage.
    try std.testing.expectEqualSlices(?u32, &.{ 7, 11, null, 13 }, values.items);
}

test "the package reads the caller's slice back and its reads leave it alone" {
    var storage: [seeds.len]?u32 = undefined;
    var values = seeded(&storage);
    var cursor: u32 = 0;
    try std.testing.expectEqual(
        @as(u32, 7),
        translated.write_slice_slot(values.items, 0, 7, &cursor),
    );

    try std.testing.expectEqual(@as(u32, 7), translated.read_slice_payload(values.items, 0));
    try std.testing.expectEqual(@as(u32, 11), translated.read_slice_payload(values.items, 1));
    try std.testing.expectEqual(@as(u32, 0), translated.read_slice_payload(values.items, 2));
    try std.testing.expectEqual(@as(u32, 13), translated.read_slice_payload(values.items, 3));

    try std.testing.expectEqual(@as(?u32, 7), translated.read_slice_entry(values.items, 0));
    try std.testing.expectEqual(@as(?u32, 11), translated.read_slice_entry(values.items, 1));
    try std.testing.expectEqual(@as(?u32, null), translated.read_slice_entry(values.items, 2));
    try std.testing.expectEqual(@as(?u32, 13), translated.read_slice_entry(values.items, 3));

    // The vector reader agrees with the slice readers element for element, so
    // both name this test's own storage.
    try std.testing.expectEqual(@as(u32, 7), translated.read_vec_payload(&values, 0));
    try std.testing.expectEqual(@as(u32, 11), translated.read_vec_payload(&values, 1));
    try std.testing.expectEqual(@as(u32, 0), translated.read_vec_payload(&values, 2));
    try std.testing.expectEqual(@as(u32, 13), translated.read_vec_payload(&values, 3));
    try std.testing.expectEqualSlices(?u32, &.{ 7, 11, null, 13 }, values.items);
}
