const std = @import("std");
const translated = @import("translated");

test "generated raw pointer mutability casts preserve addresses" {
    const bytes = [_]u8{7};
    const pointer = bytes[0..].ptr;
    const result = translated.pointer_cast(pointer);
    try std.testing.expectEqual(@intFromPtr(pointer), @intFromPtr(result));
}

test "generated finite float extremes preserve Rust IEEE 754 encodings" {
    const expected = [_]u64{
        0x7e37e43c8800759c,
        0x01a56e1fc2f8f359,
        0x7fefffffffffffff,
        0x0000000000000001,
        0x0000000000000000,
        0x8000000000000000,
    };
    const actual = translated.finite_float_extremes();
    for (expected, actual) |bits, value| {
        try std.testing.expectEqual(bits, @as(u64, @bitCast(value)));
    }
}

test "unused underscore-prefixed bindings preserve initialization effects" {
    try std.testing.expectEqual(@as(u64, 1), translated.ignored_binding_effect());
}

test "generated mutable iterators update the original slice" {
    var values = [_]u32{ 1, 3 };
    try std.testing.expectEqual(@as(u32, 6), translated.increment_sum(&values));
    try std.testing.expectEqualSlices(u32, &.{ 2, 4 }, &values);
}

test "generated formatting preserves Rust argument types and writer errors" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try translated.render(&writer);
    try std.testing.expectEqualStrings("value=42 '\\n'", writer.buffered());

    var short_buffer: [2]u8 = undefined;
    var short_writer: std.Io.Writer = .fixed(&short_buffer);
    try std.testing.expectError(error.WriteFailed, translated.render(&short_writer));
}

test "native formatting preserves inherent collisions, enum Display, Debug and writer failures" {
    const value = translated.ApiFormat{ .value = 37 };
    try std.testing.expectEqual(@as(i32, 37), value.forward());
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.print("{f}|{f}|", .{ value, translated.ApiChoice.Only });
    try translated.render_api_debug(&writer);
    try std.testing.expectEqualStrings("display=37|only|ApiFormat(37)", writer.buffered());

    var short: [3]u8 = undefined;
    var short_writer: std.Io.Writer = .fixed(&short);
    try std.testing.expectError(error.WriteFailed, short_writer.print("{f}", .{value}));
    try std.testing.expectEqualStrings("dis", short_writer.buffered());
}

test "generated String and Cow APIs preserve bytes and ownership" {
    const gpa = std.testing.allocator;
    var owned = try translated.owned(gpa, "h\xc3\xa9");
    defer owned.deinit(gpa);
    try std.testing.expectEqualStrings("h\xc3\xa9", owned.as_str());

    const valid = "valid \xe2\x98\x83";
    var borrowed = try translated.lossy(gpa, valid);
    defer borrowed.deinit(gpa);
    try std.testing.expectEqualStrings(valid, borrowed.as_ref());
    try std.testing.expect(borrowed == .Borrowed);
    try std.testing.expectEqual(@intFromPtr(valid.ptr), @intFromPtr(borrowed.as_ref().ptr));

    var replaced = try translated.lossy(gpa, "a\xffb");
    defer replaced.deinit(gpa);
    try std.testing.expectEqualStrings("a\xef\xbf\xbdb", replaced.as_ref());
    try std.testing.expect(replaced == .Owned);

    const bytes = [_]u8{ 0xff, 0x00 };
    var byte_cow = translated.borrowed_bytes(&bytes);
    defer byte_cow.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &bytes, byte_cow.as_ref());
    try std.testing.expectEqual(@intFromPtr(bytes[0..].ptr), @intFromPtr(byte_cow.as_ref().ptr));
}

test "generated Result projections release discarded storage and transfer retained errors" {
    const gpa = std.testing.allocator;
    try std.testing.expect(translated.discard_result_error(gpa, try translated.owned(gpa, "discarded error")) == null);
    try std.testing.expect(translated.discard_result_success(gpa, try translated.owned(gpa, "discarded success")) == null);
    const owned_error = try translated.owned(gpa, "kept error");
    var taken = translated.take_result_error(gpa, owned_error);
    defer taken.deinit(gpa);
    try std.testing.expectEqualStrings("kept error", taken.as_str());
    try std.testing.expectEqual(@intFromPtr(owned_error.as_bytes().ptr), @intFromPtr(taken.as_bytes().ptr));
}

test "generated raw pointer comparisons read addresses through aliases and borrows" {
    // Values oppose address order, so a pointee comparison cannot pass.
    const bytes = [_]u8{ 20, 1 };
    const left: [*]allowzero align(1) const u8 = &bytes;
    const right = left + 1;
    try std.testing.expectEqual(@as(u8, 35), translated.pointer_relations(left, right));
    try std.testing.expectEqual(@as(u8, 44), translated.pointer_relations(right, left));
    try std.testing.expectEqual(@as(u8, 26), translated.pointer_relations(left, left));
    try std.testing.expect(translated.pointer_alias_less(left, right));
    try std.testing.expect(translated.pointer_borrowed_less(&left, &right));
    const zero: [*]allowzero align(1) const u8 = @ptrFromInt(0);
    try std.testing.expectEqual(@as(u8, 35), translated.pointer_relations(zero, left));
    try std.testing.expectEqual(@as(u8, 26), translated.pointer_relations(zero, zero));
}

fn localOwnersWithAllocationFailures(gpa: std.mem.Allocator) !void {
    try std.testing.expect(try translated.mutated_local_matches(gpa));
    try std.testing.expect(try translated.discard_local_result(gpa) == null);
    var kept = try translated.retain_local_error(gpa);
    defer kept.deinit(gpa);
    try std.testing.expectEqualStrings("retained", kept.as_str());
    try std.testing.expectEqual(@as(usize, 11), try translated.local_pair_length(gpa));
}

test "generated local owners live until scope exit and transfer into Result payloads" {
    try localOwnersWithAllocationFailures(std.testing.allocator);
    // A failure in the second constructor must release the first allocation.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, localOwnersWithAllocationFailures, .{});
}

// Every frame below builds its owned values and hands each one on, so the
// failures its constructors can report are the ones this sweep exists for:
// whatever a frame already owns has to be released when the next allocation
// fails, or the sweep reports a leak rather than a bug in the frame.
fn movedLocalsWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var branched = try translated.moved_branch_value(gpa, true);
    defer branched.deinit(gpa);
    try std.testing.expectEqualStrings("branched", branched.as_str());

    var looped = try translated.moved_loop_value(gpa);
    defer looped.deinit(gpa);
    try std.testing.expectEqualStrings("looped", looped.as_str());

    var matched = try translated.moved_match_value(gpa, 0);
    defer matched.deinit(gpa);
    try std.testing.expectEqualStrings("matched", matched.as_str());

    var fallback = try translated.moved_match_value(gpa, 7);
    defer fallback.deinit(gpa);
    try std.testing.expectEqualStrings("matched", fallback.as_str());
}

// A `Vec<String>` hands its slab back through `deinit`, but each element owns
// bytes of its own that the slab release does not reach.
fn releaseStringVec(gpa: std.mem.Allocator, list: anytype) void {
    for (list.items) |*element| element.deinit(gpa);
    list.deinit(gpa);
}

// Every element the frame hands on, in the order the list holds them. The
// count is what makes the fault injection below reach a LATER growth: the list
// reserves one element at a time and reallocates at the 1st, 4th and 9th, so
// the ninth reservation is the first that can fail with eight owned elements
// already appended — the case a list-level release has to reach.
const moved_vec_elements = [_][]const u8{
    "vec-0",
    "vec-1",
    "vec-2",
    "vec-3",
    "vec-4",
    "vec-5",
    "vec-6",
    "vec-7",
    "vec-8",
};

fn expectMovedVecElements(list: anytype) !void {
    try std.testing.expectEqual(@as(usize, moved_vec_elements.len), list.items.len);
    for (moved_vec_elements, list.items) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual.as_str());
    }
}

fn movedVecWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var list = try translated.moved_vec_element(gpa);
    defer releaseStringVec(gpa, &list);
    try expectMovedVecElements(&list);
}

test "generated moved local strings reach their destination whole" {
    const gpa = std.testing.allocator;
    try movedLocalsWithAllocationFailures(gpa);
    try std.testing.checkAllAllocationFailures(gpa, movedLocalsWithAllocationFailures, .{});
    try movedVecWithAllocationFailures(gpa);
    try std.testing.checkAllAllocationFailures(gpa, movedVecWithAllocationFailures, .{});

    // Each element of the vector IS a value the frame handed on, and each is
    // released exactly once. An early release would leave the payload the
    // testing allocator has already poisoned, and a second owner of one
    // allocation would free it twice, so order, bytes and a single release per
    // element are all part of the contract.
    var list = try translated.moved_vec_element(gpa);
    defer releaseStringVec(gpa, &list);
    try expectMovedVecElements(&list);

    var reference = try translated.owned(gpa, moved_vec_elements[0]);
    defer reference.deinit(gpa);
    try std.testing.expectEqualStrings(reference.as_str(), list.items[0].as_str());
    // Same bytes, separate allocations: the moved local was handed over, not
    // aliased onto a value the caller still owns.
    try std.testing.expect(list.items[0].as_bytes().ptr != reference.as_bytes().ptr);

    // Both arms move the same binding, so both are read back.
    var upper = try translated.moved_branch_value(gpa, true);
    defer upper.deinit(gpa);
    try std.testing.expectEqualStrings("branched", upper.as_str());

    var lower = try translated.moved_branch_value(gpa, false);
    defer lower.deinit(gpa);
    try std.testing.expectEqualStrings("branched", lower.as_str());

    // Both arms of the match move the same binding, so both are read back.
    var matched = try translated.moved_match_value(gpa, 0);
    defer matched.deinit(gpa);
    try std.testing.expectEqualStrings("matched", matched.as_str());

    var fallback = try translated.moved_match_value(gpa, 7);
    defer fallback.deinit(gpa);
    try std.testing.expectEqualStrings("matched", fallback.as_str());

    var looped = try translated.moved_loop_value(gpa);
    defer looped.deinit(gpa);
    try std.testing.expectEqualStrings("looped", looped.as_str());
}

test "generated iterator collections preserve values order and empty boundaries" {
    const gpa = std.testing.allocator;
    var filtered = try translated.collected(gpa, &.{ 1, 2, 3, 4 });
    defer filtered.deinit(gpa);
    try std.testing.expectEqualSlices(u32, &.{ 6, 8 }, filtered.items);

    var repeated = try translated.owner(gpa, &.{ 7, 11 });
    defer repeated.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 7, 11, 7, 11 }, repeated.items);
    try std.testing.checkAllAllocationFailures(gpa, collectWithAllocationFailures, .{});

    var empty = try translated.collected(gpa, &.{});
    defer empty.deinit(gpa);
    try std.testing.expectEqualSlices(u32, &.{}, empty.items);

    var flattened = try translated.flattened(gpa);
    defer flattened.deinit(gpa);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 1, 2, 2, 3 }, flattened.items);

    var stateful = try translated.stateful_flattened(gpa);
    defer stateful.deinit(gpa);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, stateful.items);

    var reversed = try translated.reversed(gpa, 4);
    defer reversed.deinit(gpa);
    try std.testing.expectEqualSlices(u32, &.{ 3, 2, 1, 0 }, reversed.items);

    var reversed_empty = try translated.reversed(gpa, 0);
    defer reversed_empty.deinit(gpa);
    try std.testing.expectEqualSlices(u32, &.{}, reversed_empty.items);

    var signed = try translated.signed_flattened(gpa);
    defer signed.deinit(gpa);
    try std.testing.expectEqualSlices(i32, &.{ -1, 0, 0, 1 }, signed.items);
}

fn collectWithAllocationFailures(allocator: std.mem.Allocator) !void {
    const input: [256]u8 = @splat(7);
    var collection = try translated.owner(allocator, &input);
    defer collection.deinit(allocator);
    const expected: [512]u8 = @splat(7);
    try std.testing.expectEqualSlices(u8, &expected, collection.items);
}

test "generated comparisons release only temporary owners and preserve branch order" {
    const gpa = std.testing.allocator;
    try compareWithAllocationFailures(gpa);
    try std.testing.checkAllAllocationFailures(gpa, compareWithAllocationFailures, .{});

    // A field-free error enum is a Zig error set, so the rejected arm has to
    // arrive as the native tag itself and not as a user value that merely
    // spells the same word.
    try std.testing.expectEqual(@as(u8, 7), try translated.tagged_result(true));
    try std.testing.expectError(error.Rejected, translated.tagged_result(false));

    // The frame that builds this `Result` returns an `Option`, so the error
    // it names comes from the local binding rather than the enclosing
    // signature. Both arms still have to arrive as native: the payload bare,
    // the rejection as the tag itself.
    try std.testing.expectEqual(@as(u8, 7), try translated.contextual_tagged_result(true).?);
    try std.testing.expectError(error.Rejected, translated.contextual_tagged_result(false).?);

    // Here the payload and the error are the same type, so only the
    // constructor says which side of the union the variant belongs to. The
    // successful value is the user's own enum, not the tag that spells the
    // same word, and the active tag is what tells the two apart.
    try std.testing.expect(try translated.native_ok_variant() == .Accepted);

    // The variant crosses an ordinary call before it reaches `Err`, so the
    // callee is handed the user's enum and the union still names the tag.
    try std.testing.expectError(error.Rejected, translated.native_dynamic_error());

    var sequence: u32 = 0;
    try std.testing.expect(!try translated.temporary_conditional(gpa, false, &sequence));
    try std.testing.expectEqual(@as(u32, 0), sequence);
    try std.testing.expect(try translated.temporary_conditional(gpa, true, &sequence));
    try std.testing.expectEqual(@as(u32, 12), sequence);

    var named = try translated.owned(gpa, "same");
    defer named.deinit(gpa);
    try std.testing.expect(try translated.temporary_borrowed_equal(gpa, &named));
    try std.testing.expectEqualStrings("same", named.as_str());

    var empty = try translated.temporary_empty_string(gpa);
    defer empty.deinit(gpa);
    try std.testing.expectEqualStrings("", empty.as_str());
}

fn compareWithAllocationFailures(gpa: std.mem.Allocator) !void {
    try std.testing.expect(try translated.temporary_equal(gpa, "same"));
    try std.testing.expect(!try translated.temporary_equal(gpa, "different"));
    try std.testing.expect(try translated.temporary_result_equal(gpa, "same"));
    try std.testing.expect(!try translated.temporary_result_equal(gpa, "bad"));
    try std.testing.expect(try translated.temporary_unwrap_equal(gpa, "same"));
    try std.testing.expect(try translated.temporary_vec_equal(gpa, 7));
    try std.testing.expect(!try translated.temporary_vec_equal(gpa, 8));
    try std.testing.expect(translated.temporary_user_error_caller(gpa, 7));
    try std.testing.expect(!translated.temporary_user_error_caller(gpa, 8));

    // The `Ok` payload is handed over by move. Nothing here releases it a
    // second time: the callee owns it from here on, and a second `deinit`
    // would be a double free rather than a leak the allocator could report.
    try std.testing.expect(translated.temporary_moved_result_caller(
        gpa,
        .{ .Ok = try translated.owned(gpa, "same") },
    ));
    try std.testing.expect(!translated.temporary_moved_result_caller(
        gpa,
        .{ .Ok = try translated.owned(gpa, "different") },
    ));
    try std.testing.expect(try translated.temporary_empty_equal(gpa, ""));
    try std.testing.expect(!try translated.temporary_empty_equal(gpa, "other"));
}

// Cleanup requires the creating allocator, but a predicate with no returned errors
// must remain usable where a caller requires a plain bool function.
test "cleanup-only consuming functions work as infallible predicates" {
    const gpa = std.testing.allocator;
    const Argument = @typeInfo(@TypeOf(translated.temporary_moved_result_caller)).@"fn".params[1].type.?;
    const predicate: *const fn (std.mem.Allocator, Argument) bool =
        translated.temporary_moved_result_caller;
    const matching = try translated.owned(gpa, "same");
    try std.testing.expect(predicate(gpa, .{ .Ok = matching }));
    const different = try translated.owned(gpa, "different");
    try std.testing.expect(!predicate(gpa, .{ .Ok = different }));
}
