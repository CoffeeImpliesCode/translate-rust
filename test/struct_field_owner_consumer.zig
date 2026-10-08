//! Consumer tests for the translated `struct-field-owner-move` package.
//!
//! One test per operation in `test/crates/struct-field-owner-move/src/lib.rs`,
//! each measuring the allocation and deallocation counters the runtime's own
//! allocator reports. Nothing here reimplements the crate's moves and no test
//! reads emitted text: "released once" is a count the translated package has to
//! match, and a second release of an already-released owner has to move that
//! count by zero.
//!
//! Built like the `test/percent_encoding_consumer.zig` invocation in
//! `test/e2e_test.zig`, with the generated package root in place of that one.
//! The root module imports `r2z` itself, so it needs its own `--dep r2z`:
//!
//!     zig test --dep translated --dep r2z \
//!         -Mroot=test/struct_field_owner_consumer.zig \
//!         --dep r2z -Mtranslated=<generated>/src/root.zig \
//!         -Mr2z=r2z-core/src/root.zig

const std = @import("std");
const r2z = @import("r2z");
const translated = @import("translated");

// The `let` destructuring route. Two strings are built inside the call, one is
// freed before the call returns and one leaves the call still owned by the
// caller. A record that released the field it had already handed over would
// show two deallocations here and would hand back a descriptor whose bytes were
// already gone.
test "a let destructuring moves the owned field out and frees the field the record kept" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();
    const allocations_before = tracking.allocations;
    const deallocations_before = tracking.deallocations;

    var moved: r2z.alloc.String = try translated.split_record(gpa, "moved-field", "kept-field");

    try std.testing.expectEqual(allocations_before + 2, tracking.allocations);
    try std.testing.expectEqual(deallocations_before + 1, tracking.deallocations);
    try std.testing.expectEqualStrings("moved-field", moved.as_str());

    // The caller is the only owner of the field that left, so this is the one
    // release that frees it. `deinit` writes the released state back through
    // the handle, so the descriptor answers with no bytes afterwards.
    moved.deinit(gpa);
    try std.testing.expectEqual(deallocations_before + 2, tracking.deallocations);
    try std.testing.expectEqual(@as(usize, 0), moved.len());

    // A second release of the same owner reaches an empty descriptor. The bytes
    // the caller was holding cannot be freed twice.
    const after_release = tracking.deallocations;
    moved.deinit(gpa);
    try std.testing.expectEqual(after_release, tracking.deallocations);
}

// The control for the test above. The same record is destructured, but neither
// field leaves the call, so both bindings are still full when the scope ends
// and both allocations come back out. One release in the destructuring route is
// therefore the field that left, not a release the record skipped.
test "a record whose fields stay in the call is released whole" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();
    const allocations_before = tracking.allocations;
    const deallocations_before = tracking.deallocations;

    const lengths = try translated.record_field_lengths(gpa, "aa", "bbbb");

    try std.testing.expectEqual(@as(usize, 2), lengths[0]);
    try std.testing.expectEqual(@as(usize, 4), lengths[1]);
    try std.testing.expectEqual(allocations_before + 2, tracking.allocations);
    try std.testing.expectEqual(deallocations_before + 2, tracking.deallocations);
}

// The `self`-by-value route. `self` is the whole struct and the field leaves it,
// so the partially moved struct the method drops on the way out still carries
// only the field that owns nothing. Nothing was freed inside the method, and the
// caller is the label's single owner.
test "a method that takes self by value moves the field out and the dropped self frees nothing" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();
    const allocations_before = tracking.allocations;
    const deallocations_before = tracking.deallocations;

    var bag = try translated.owned_bag(gpa, "self-moved", 7);
    try std.testing.expectEqual(@as(usize, 10), bag.label_len());
    try std.testing.expectEqual(@as(u32, 7), bag.count);

    var moved: r2z.alloc.String = bag.into_label(gpa);

    try std.testing.expectEqual(allocations_before + 1, tracking.allocations);
    try std.testing.expectEqual(deallocations_before, tracking.deallocations);
    try std.testing.expectEqualStrings("self-moved", moved.as_str());

    moved.deinit(gpa);
    try std.testing.expectEqual(deallocations_before + 1, tracking.deallocations);
}

// A move hands the same allocation over. A copy would have left the struct
// holding a second owner of the same bytes, and the caller's release above would
// then have freed storage the struct still named.
test "the field that leaves keeps the allocation it was built at" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    var bag = try translated.owned_bag(gpa, "same-bytes", 3);
    const address = @intFromPtr(bag.label.as_bytes().ptr);

    var moved = bag.into_label(gpa);
    try std.testing.expectEqual(address, @intFromPtr(moved.as_bytes().ptr));

    moved.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), moved.len());
}

// The consumption contract this package carries: a named struct is a foreign
// type as far as the runtime's generic release is concerned, so `dropTemporary`
// reaches no field of one. The owned field is therefore released through the
// handle the caller already holds, and this pins both halves of that statement.
test "the runtime's generic release reaches no field of a named struct" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    var bag = try translated.owned_bag(gpa, "field-release", 1);
    const deallocations_before = tracking.deallocations;

    r2z.alloc.dropTemporary(gpa, &bag);
    try std.testing.expectEqual(deallocations_before, tracking.deallocations);

    bag.label.deinit(gpa);
    try std.testing.expectEqual(deallocations_before + 1, tracking.deallocations);
    try std.testing.expectEqual(@as(usize, 0), bag.label.len());
}
