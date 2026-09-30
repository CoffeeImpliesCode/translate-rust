const std = @import("std");
const translated = @import("translated");

test "generated raw pointer mutability casts preserve addresses" {
    const bytes = [_]u8{7};
    const pointer = bytes[0..].ptr;
    const result = translated.pointer_cast(pointer);
    try std.testing.expectEqual(@intFromPtr(pointer), @intFromPtr(result));
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
    try std.testing.expect(try translated.temporary_user_error_caller(gpa, 7));
    try std.testing.expect(!try translated.temporary_user_error_caller(gpa, 8));

    // The `Ok` payload is handed over by move. Nothing here releases it a
    // second time: the callee owns it from here on, and a second `deinit`
    // would be a double free rather than a leak the allocator could report.
    try std.testing.expect(try translated.temporary_moved_result_caller(
        gpa,
        .{ .Ok = try translated.owned(gpa, "same") },
    ));
    try std.testing.expect(!try translated.temporary_moved_result_caller(
        gpa,
        .{ .Ok = try translated.owned(gpa, "different") },
    ));
    try std.testing.expect(try translated.temporary_empty_equal(gpa, ""));
    try std.testing.expect(!try translated.temporary_empty_equal(gpa, "other"));
}
