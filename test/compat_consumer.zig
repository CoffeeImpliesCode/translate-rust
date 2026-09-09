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
