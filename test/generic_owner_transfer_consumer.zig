//! Consumer tests for the translated `generic-owner-transfer` package.
//!
//! A generic function that takes an owned value BY VALUE owns it from the
//! moment it is called. So for every instantiation the only question that
//! matters is where that one owner ends up, and how many times its bytes are
//! released on the way. Every test here answers that with a counting allocator:
//! `std.testing.FailingAllocator` wraps the leak-checking test allocator, so
//! `deallocations` counts the real frees while a leak or a double free is
//! still reported by the runner underneath it.
//!
//! The two instantiations are a `String`, which is a runtime container in its
//! own right, and a `Vec<u8>`, which owns a byte slab and nothing else. Nothing
//! here reimplements the crate: every owner is built by the package under test
//! or by the runtime containers it hands back, and every count is a count of
//! releases the package actually performed.
//!
//! ## Invocation
//!
//! Built like the `test/percent_encoding_consumer.zig` invocation in
//! `test/e2e_test.zig`, with the generated package root in place of the
//! percent-encoding one. The root module imports `r2z` itself, so it needs its
//! own `--dep r2z`:
//!
//!     zig test --dep translated --dep r2z \
//!         -Mroot=test/generic_owner_transfer_consumer.zig \
//!         --dep r2z -Mtranslated=<generated>/src/root.zig \
//!         -Mr2z=r2z-core/src/root.zig
//!
//! ## Reading the counts
//!
//! An explicit release is followed by putting the handle back to its empty
//! state, so the `defer` armed at the top of the test finds nothing there and
//! the count each test reads is exactly the count of the release under test.

const std = @import("std");
const r2z = @import("r2z");
const translated = @import("translated");

/// The byte payload `new_bytes` builds, as the crate's own `vec![1, 2, 3]`
/// literal reads back. Spelled out here so the expectation comes from the
/// fixture's source rather than from the call under test.
const expected_bytes = [_]u8{ 1, 2, 3 };

/// The text `new_text` builds, as its `String::from("alpha")` reads back.
const expected_text = "alpha";

/// A one-element vector of owned strings.
///
/// The string is released by its own `defer` until the vector has taken it,
/// so an append that runs out of room frees it instead of losing it.
fn ownedTextVector(
    gpa: std.mem.Allocator,
    text: []const u8,
) !std.ArrayListUnmanaged(r2z.alloc.String) {
    var owned: std.ArrayListUnmanaged(r2z.alloc.String) = .empty;
    errdefer r2z.alloc.dropTemporary(gpa, &owned);
    var one = try r2z.alloc.String.from_str(gpa, text);
    defer one.deinit(gpa);
    try owned.append(gpa, one);
    one = .empty;
    return owned;
}

/// A one-element vector holding one owned byte vector, built the same way.
fn ownedByteVector(gpa: std.mem.Allocator) !std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)) {
    var inner: std.ArrayListUnmanaged(u8) = .empty;
    errdefer inner.deinit(gpa);
    try inner.append(gpa, 1);
    try inner.append(gpa, 2);
    try inner.append(gpa, 3);

    var outer: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)) = .empty;
    errdefer r2z.alloc.dropTemporary(gpa, &outer);
    var moved = r2z.alloc.takeOwned(std.ArrayListUnmanaged(u8), &inner);
    defer moved.deinit(gpa);
    try outer.append(gpa, moved);
    moved = .empty;
    return outer;
}

// `relay` instantiated at `T = String`. The callee owns the text from the call
// and hands the same owner back, so the call releases nothing and the caller's
// single release of the answer frees its bytes exactly once.
test "relay at String hands back the one owner it was given and frees it once" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    var text = try translated.new_text(gpa);
    const text_address = @intFromPtr(text.as_bytes().ptr);
    const frees_before_handoff = tracking.deallocations;

    // Rust moved `text` into `relay`. The runtime transfer says so in Zig by
    // emptying the source, which is what makes the scope's own release below
    // find nothing instead of freeing the same bytes a second time.
    const moved = r2z.alloc.takeOwned(r2z.alloc.String, &text);
    defer text.deinit(gpa);
    try std.testing.expectEqual(frees_before_handoff, tracking.deallocations);

    var returned = translated.relay(r2z.alloc.String, gpa, moved);
    defer returned.deinit(gpa);
    try std.testing.expectEqual(frees_before_handoff, tracking.deallocations);
    try std.testing.expectEqualStrings(expected_text, returned.as_str());
    try std.testing.expectEqual(text_address, @intFromPtr(returned.as_bytes().ptr));

    // One owner, one release. A release that did not happen is a leak and a
    // second one is a double free, and both are visible here.
    const frees_before_release = tracking.deallocations;
    returned.deinit(gpa);
    returned = .empty;
    try std.testing.expectEqual(frees_before_release + 1, tracking.deallocations);
}

// The same source text instantiated at `T = Vec<u8>`, where the owner is a
// byte slab and releases through `deinit` rather than an element walk.
test "relay at Vec<u8> hands back the one owner it was given and frees it once" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    var bytes = try translated.new_bytes(gpa);
    const bytes_address = @intFromPtr(bytes.items.ptr);
    const frees_before_handoff = tracking.deallocations;

    const moved = r2z.alloc.takeOwned(std.ArrayListUnmanaged(u8), &bytes);
    defer bytes.deinit(gpa);
    try std.testing.expectEqual(frees_before_handoff, tracking.deallocations);
    try std.testing.expectEqual(@as(usize, 0), bytes.items.len);

    var returned = translated.relay(std.ArrayListUnmanaged(u8), gpa, moved);
    defer returned.deinit(gpa);
    try std.testing.expectEqual(frees_before_handoff, tracking.deallocations);
    try std.testing.expectEqualSlices(u8, &expected_bytes, returned.items);
    try std.testing.expectEqual(bytes_address, @intFromPtr(returned.items.ptr));

    const frees_before_release = tracking.deallocations;
    returned.deinit(gpa);
    returned = .empty;
    try std.testing.expectEqual(frees_before_release + 1, tracking.deallocations);
}

// `relay_or_release` at `T = String`. The dropped arm releases the vector and
// the one string it carries inside the callee; the returned arm releases
// nothing there and hands both to the caller instead.
test "relay_or_release at String releases the owner once on each arm" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    const dropped = try ownedTextVector(gpa, "dropped");
    const dropped_address = @intFromPtr(dropped.items[0].as_bytes().ptr);
    const frees_before_dropped_call = tracking.deallocations;

    const dropped_answer = translated.relay_or_release(r2z.alloc.String, gpa, false, dropped);
    try std.testing.expect(dropped_answer == null);
    // Two releases, not one: the vector's slab and the owner it was carrying.
    // Freeing the slab alone would strand the string.
    try std.testing.expectEqual(frees_before_dropped_call + 2, tracking.deallocations);

    const returned_source = try ownedTextVector(gpa, "returned");
    const returned_address = @intFromPtr(returned_source.items[0].as_bytes().ptr);
    const frees_before_returned_call = tracking.deallocations;

    var maybe = translated.relay_or_release(r2z.alloc.String, gpa, true, returned_source);
    // The owner left the frame, so the release the callee armed found nothing
    // to free. A copy left behind is what a second free of these bytes would
    // come from.
    try std.testing.expectEqual(frees_before_returned_call, tracking.deallocations);
    try std.testing.expect(maybe != null);
    defer r2z.alloc.dropTemporary(gpa, &maybe.?);

    const kept = &maybe.?;
    try std.testing.expectEqual(@as(usize, 1), kept.items.len);
    try std.testing.expectEqualStrings("returned", kept.items[0].as_str());
    try std.testing.expectEqual(returned_address, @intFromPtr(kept.items[0].as_bytes().ptr));
    try std.testing.expect(dropped_address != returned_address);

    const frees_before_owner_release = tracking.deallocations;
    r2z.alloc.dropTemporary(gpa, kept);
    maybe.? = .empty;
    try std.testing.expectEqual(frees_before_owner_release + 2, tracking.deallocations);
}

// The same generic at `T = Vec<u8>`, where the vector it is handed owns byte
// slabs rather than runtime containers. The count is the same on the dropped
// arm and the element walk costs nothing extra.
test "relay_or_release at Vec<u8> releases the owner once on each arm" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    const dropped = try ownedByteVector(gpa);
    const dropped_address = @intFromPtr(dropped.items[0].items.ptr);
    const frees_before_dropped_call = tracking.deallocations;

    const dropped_answer = translated.relay_or_release(std.ArrayListUnmanaged(u8), gpa, false, dropped);
    try std.testing.expect(dropped_answer == null);
    try std.testing.expectEqual(frees_before_dropped_call + 2, tracking.deallocations);

    const returned_source = try ownedByteVector(gpa);
    const returned_address = @intFromPtr(returned_source.items[0].items.ptr);
    const frees_before_returned_call = tracking.deallocations;

    var maybe = translated.relay_or_release(std.ArrayListUnmanaged(u8), gpa, true, returned_source);
    try std.testing.expectEqual(frees_before_returned_call, tracking.deallocations);
    try std.testing.expect(maybe != null);
    defer r2z.alloc.dropTemporary(gpa, &maybe.?);

    const kept = &maybe.?;
    try std.testing.expectEqual(@as(usize, 1), kept.items.len);
    try std.testing.expectEqualSlices(u8, &expected_bytes, kept.items[0].items);
    try std.testing.expectEqual(returned_address, @intFromPtr(kept.items[0].items.ptr));
    try std.testing.expect(dropped_address != returned_address);

    const frees_before_owner_release = tracking.deallocations;
    r2z.alloc.dropTemporary(gpa, kept);
    maybe.? = .empty;
    try std.testing.expectEqual(frees_before_owner_release + 2, tracking.deallocations);
}

// `into_vec` is the generic that answers with a DIFFERENT owned type. The
// transferred owner is reachable inside the answer at the address it already
// had, and the caller's release frees the new slab and that owner once each.
test "into_vec at String answers with a vector that releases the owner once" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    var text = try translated.new_text(gpa);
    const text_address = @intFromPtr(text.as_bytes().ptr);
    const moved = r2z.alloc.takeOwned(r2z.alloc.String, &text);
    defer text.deinit(gpa);

    var wrapped = try translated.into_vec(r2z.alloc.String, gpa, moved);
    defer r2z.alloc.dropTemporary(gpa, &wrapped);
    try std.testing.expectEqual(@as(usize, 1), wrapped.items.len);
    try std.testing.expectEqualStrings(expected_text, wrapped.items[0].as_str());
    try std.testing.expectEqual(text_address, @intFromPtr(wrapped.items[0].as_bytes().ptr));

    const frees_before_release = tracking.deallocations;
    r2z.alloc.dropTemporary(gpa, &wrapped);
    wrapped = .empty;
    try std.testing.expectEqual(frees_before_release + 2, tracking.deallocations);
}

test "into_vec at Vec<u8> answers with a vector that releases the owner once" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    var bytes = try translated.new_bytes(gpa);
    const bytes_address = @intFromPtr(bytes.items.ptr);
    const moved = r2z.alloc.takeOwned(std.ArrayListUnmanaged(u8), &bytes);
    defer bytes.deinit(gpa);

    var wrapped = try translated.into_vec(std.ArrayListUnmanaged(u8), gpa, moved);
    defer r2z.alloc.dropTemporary(gpa, &wrapped);
    try std.testing.expectEqual(@as(usize, 1), wrapped.items.len);
    try std.testing.expectEqualSlices(u8, &expected_bytes, wrapped.items[0].items);
    try std.testing.expectEqual(bytes_address, @intFromPtr(wrapped.items[0].items.ptr));

    const frees_before_release = tracking.deallocations;
    r2z.alloc.dropTemporary(gpa, &wrapped);
    wrapped = .empty;
    try std.testing.expectEqual(frees_before_release + 2, tracking.deallocations);
}

// Both instantiations of one generic body, live at the same time. Releasing
// one must not touch the other's storage: the byte vector still reads at its
// own address after the string is gone, and each release counts one.
test "the two relay instantiations release their own storage and never each other's" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    var text = try translated.new_text(gpa);
    defer text.deinit(gpa);
    var bytes = try translated.new_bytes(gpa);
    defer bytes.deinit(gpa);
    const text_address = @intFromPtr(text.as_bytes().ptr);
    const bytes_address = @intFromPtr(bytes.items.ptr);

    // One source text, two owners, each moved in through its own instantiation.
    var returned_text = translated.relay(
        r2z.alloc.String,
        gpa,
        r2z.alloc.takeOwned(r2z.alloc.String, &text),
    );
    defer returned_text.deinit(gpa);
    var returned_bytes = translated.relay(
        std.ArrayListUnmanaged(u8),
        gpa,
        r2z.alloc.takeOwned(std.ArrayListUnmanaged(u8), &bytes),
    );
    defer returned_bytes.deinit(gpa);

    try std.testing.expectEqual(text_address, @intFromPtr(returned_text.as_bytes().ptr));
    try std.testing.expectEqual(bytes_address, @intFromPtr(returned_bytes.items.ptr));

    const frees_before_text_release = tracking.deallocations;
    returned_text.deinit(gpa);
    returned_text = .empty;
    try std.testing.expectEqual(frees_before_text_release + 1, tracking.deallocations);
    try std.testing.expectEqual(bytes_address, @intFromPtr(returned_bytes.items.ptr));
    try std.testing.expectEqualSlices(u8, &expected_bytes, returned_bytes.items);

    const frees_before_bytes_release = tracking.deallocations;
    returned_bytes.deinit(gpa);
    returned_bytes = .empty;
    try std.testing.expectEqual(frees_before_bytes_release + 1, tracking.deallocations);
}
