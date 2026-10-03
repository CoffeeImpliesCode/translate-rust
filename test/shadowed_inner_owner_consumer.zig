//! Consumer tests for the translated `shadowed-inner-owner` package.
//!
//! The fixture in `test/crates/shadowed-inner-owner/src/lib.rs` binds an owned
//! value, opens an inner scope that binds the SAME NAME to a different owned
//! value, moves the inner one out of that scope, and returns the outer one.
//! Three things about that are checkable from outside, and this file checks
//! all three:
//!
//!   * the outer value arrives whole — its bytes are read back through the
//!     owner the frame returned,
//!   * the inner value is released exactly once — a release that never runs
//!     leaks, and one that runs twice frees memory the caller still holds, and
//!     the testing allocator reports both,
//!   * the collision changed no decision — the two owners share a source name
//!     and carry the same number of bytes in the same-type cases, so only their
//!     bytes can say which of them a release or a move was attributed to.
//!
//! Nothing here reimplements the fixture's logic and no assertion reads emitted
//! text: each expectation is a claim about what the generated package returns
//! and about what the allocator did with what it handed over.
//!
//! Built like the `test/compat_consumer.zig` invocation in `test/e2e_test.zig`,
//! with the generated package root in place of the compat one. The root module
//! imports `r2z` itself, so it needs its own `--dep r2z`:
//!
//!     zig test --dep translated --dep r2z \
//!         -Mroot=test/shadowed_inner_owner_consumer.zig \
//!         --dep r2z -Mtranslated=<generated>/src/root.zig \
//!         -Mr2z=r2z-core/src/root.zig

const std = @import("std");
const translated = @import("translated");

/// The payload the fixture's OUTER binding carries, and the one its inner
/// scope shadows that name with. They are the same length on purpose: a fixture
/// whose two payloads differed in length could be partly checked by counting
/// bytes, and this one cannot be. The test named "the two colliding payloads"
/// below pins that property.
const outer_payload = "outer-owner";
const inner_payload = "inner-inner";

/// The payload the distinct-type frames' moved VECTOR carries. The fixture
/// spells it as byte literals rather than borrowing a string, so that vector
/// and the string shadowing its name share a source name and nothing else.
const moved_bytes_payload = "inner";

/// A `Vec<String>` hands its slab back through `deinit`, but each element owns
/// bytes of its own that the slab release does not reach.
fn releaseStringVec(gpa: std.mem.Allocator, list: anytype) void {
    for (list.items) |*element| element.deinit(gpa);
    list.deinit(gpa);
}

/// The two owners the pair frame hands back, in the order it hands them over.
///
/// The order is the claim about which binding the move was attributed to: the
/// outer binding is what a release keyed by the outer name would free, and the
/// inner binding is what this frame moved.
fn expectPair(pair: anytype) !void {
    try std.testing.expectEqual(@as(usize, 2), pair.items.len);
    try std.testing.expectEqualStrings(outer_payload, pair.items[0].as_str());
    try std.testing.expectEqualStrings(inner_payload, pair.items[1].as_str());
    // Two allocations rather than one reached twice: an owner aliased onto the
    // value the frame did not move would share this pointer, and releasing both
    // would free one allocation twice.
    try std.testing.expect(pair.items[0].as_bytes().ptr != pair.items[1].as_bytes().ptr);
}

// ── one frame per entry point, each releasing exactly what it was handed ──
//
// Every frame below builds the owners it hands on, so the failures their
// constructors can report are what the sweeps exist for: whatever a frame
// already owns has to be released when the next allocation fails, or the sweep
// reports a leak instead of the bug in the frame.

fn pairWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var pair = try translated.shadowed_move_pair(gpa);
    defer releaseStringVec(gpa, &pair);
    try expectPair(&pair);
}

fn outerWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var outer = try translated.shadowed_outer_returned(gpa);
    defer outer.deinit(gpa);
    try std.testing.expectEqualStrings(outer_payload, outer.as_str());
}

fn distinctMovedWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var moved = try translated.shadowed_distinct_type_moved(gpa);
    defer moved.deinit(gpa);
    try std.testing.expectEqualSlices(u8, moved_bytes_payload, moved.items);
}

fn distinctOuterWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var outer = try translated.shadowed_distinct_type_outer_returned(gpa);
    defer outer.deinit(gpa);
    try std.testing.expectEqualStrings(outer_payload, outer.as_str());
}

// The same-type pair frame. The inner owner is moved out of the scope that
// shadows the outer owner's name and both arrive at the caller, so each is
// released once by the consumer, and a release inside the frame would be the
// second one the testing allocator refuses.
test "a shadowed inner owner is moved out and both owners reach the caller" {
    const gpa = std.testing.allocator;
    try pairWithAllocationFailures(gpa);
    try std.testing.checkAllAllocationFailures(gpa, pairWithAllocationFailures, .{});
}

// The same-type outer frame. The caller receives the outer owner alone, so the
// inner owner the frame still owed is released inside it, and the allocator is
// the only witness of that release.
test "a shadowed inner owner is released and the outer one is returned whole" {
    const gpa = std.testing.allocator;
    try outerWithAllocationFailures(gpa);
    try std.testing.checkAllAllocationFailures(gpa, outerWithAllocationFailures, .{});
}

// The distinct-type moved frame, where the owner that moves is a `Vec<u8>`
// reached through the same source name as the `String` declared beside it, so
// the two owners that collide do not even share a release. This frame returns
// the moved vector alone and releases the string it was declared beside, so
// both release routes run and only one of them is observable by payload.
test "a shadowed inner owner of another type is moved out and reaches the caller" {
    const gpa = std.testing.allocator;
    try distinctMovedWithAllocationFailures(gpa);
    try std.testing.checkAllAllocationFailures(gpa, distinctMovedWithAllocationFailures, .{});
}

// The distinct-type outer frame, where the released owner is a vector and the
// returned one is a string.
test "a shadowed inner owner of another type is released and the outer string is returned" {
    const gpa = std.testing.allocator;
    try distinctOuterWithAllocationFailures(gpa);
    try std.testing.checkAllAllocationFailures(gpa, distinctOuterWithAllocationFailures, .{});
}

// The claim every assertion above rests on: the two payloads of the same-type
// frames are the same length, so their bytes are the only thing that can tell
// the two owners apart. A fixture that lost this property would let a length
// comparison stand in for the byte comparison that actually names the owner.
test "the two colliding payloads differ only in their bytes" {
    try std.testing.expectEqual(outer_payload.len, inner_payload.len);
    try std.testing.expect(!std.mem.eql(u8, outer_payload, inner_payload));
}

// What the sweeps cannot state, against plain runs: the outer value is the one
// that comes back, the inner one is the one that travels, and each is released
// exactly once.
test "the shadowed name changed no decision about which value moves or is released" {
    const gpa = std.testing.allocator;

    // Both owners come back, the outer one first and the moved inner one
    // second. Releasing the first and then reading the second is the claim
    // that they are independent: a frame that handed one allocation over under
    // both names would free it twice here, and a frame that left them aliased
    // would hand back the same bytes twice.
    var pair = try translated.shadowed_move_pair(gpa);
    defer pair.deinit(gpa);
    try expectPair(&pair);
    pair.items[0].deinit(gpa);
    try std.testing.expectEqualStrings(inner_payload, pair.items[1].as_str());
    pair.items[1].deinit(gpa);

    // The outer value alone, from the frame that released the inner owner
    // shadowing its name. Reading it is the claim that the frame did not
    // release the handle it returned.
    var outer = try translated.shadowed_outer_returned(gpa);
    defer outer.deinit(gpa);
    try std.testing.expectEqualStrings(outer_payload, outer.as_str());

    // The moved inner one, of a type the outer one is not.
    var moved = try translated.shadowed_distinct_type_moved(gpa);
    defer moved.deinit(gpa);
    try std.testing.expectEqualSlices(u8, moved_bytes_payload, moved.items);

    // And the outer value alone again, beside a moved vector the frame
    // released. Its payload is the outer's, not the vector's.
    var distinct_outer = try translated.shadowed_distinct_type_outer_returned(gpa);
    defer distinct_outer.deinit(gpa);
    try std.testing.expectEqualStrings(outer_payload, distinct_outer.as_str());
}
