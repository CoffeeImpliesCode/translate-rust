const std = @import("std");
const translated = @import("translated");

// Every claim in this file is made under `std.testing.allocator`, so "released
// exactly once" is not a matter of trusting the emitted cleanup: a release that
// never runs is a leak this allocator reports, and a release that runs twice
// is a double free it reports. Each test drives one loop exit route and then
// checks the value that route produced, because a frame that leaks its owners
// can still hand back the right bytes.

// The list the loop hands back owns a slab and one string per element, so
// releasing it means releasing each element before the slab that holds them.
fn releaseStringList(gpa: std.mem.Allocator, list: anytype) void {
    for (list.items) |*element| element.deinit(gpa);
    list.deinit(gpa);
}

fn expectStringList(expected: []const []const u8, actual: anytype) !void {
    try std.testing.expectEqual(@as(usize, expected.len), actual.items.len);
    for (expected, actual.items) |want, got| {
        try std.testing.expectEqualStrings(want, got.as_str());
    }
}

test "a break that carries a value hands the loop's owner on and frees what it did not" {
    const gpa = std.testing.allocator;

    // The counter is raised before the condition is read, so a limit of zero
    // still runs one iteration: that iteration builds an owner, releases it as
    // its scope ends and hands the accumulator on.
    var none = try translated.break_carries_owner(gpa, 0);
    defer none.deinit(gpa);
    try std.testing.expectEqualStrings("ab", none.as_str());

    var once = try translated.break_carries_owner(gpa, 1);
    defer once.deinit(gpa);
    try std.testing.expectEqualStrings("ab", once.as_str());

    // Three iterations, so three owners the loop released and one accumulator
    // it did not. A frame that released the accumulator as well would free the
    // bytes this result still names.
    var thrice = try translated.break_carries_owner(gpa, 3);
    defer thrice.deinit(gpa);
    try std.testing.expectEqualStrings("ababab", thrice.as_str());
}

test "a valueless break frees the owner the breaking iteration built" {
    const gpa = std.testing.allocator;

    // The loop never runs, so no iteration built an owner at all.
    var empty = try translated.break_releases_owner(gpa, 0, 1);
    defer releaseStringList(gpa, &empty);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);

    // The condition ended the loop after three iterations, and each of them
    // moved what it built into the list the loop hands back.
    var by_condition = try translated.break_releases_owner(gpa, 3, 9);
    defer releaseStringList(gpa, &by_condition);
    try expectStringList(&.{ "round", "round", "round" }, &by_condition);

    // The `break` ended the loop on its second iteration. That iteration built
    // an owner, never moved it, and its scope ended right there, so the body
    // had to release it — a leak otherwise, and a double free if the release
    // also ran on the iterations that moved theirs.
    var by_break = try translated.break_releases_owner(gpa, 3, 2);
    defer releaseStringList(gpa, &by_break);
    try expectStringList(&.{"round"}, &by_break);

    // The `break` ended the loop on its first iteration. Nothing was moved, so
    // the list is empty and the owner that iteration built was released by the
    // body alone.
    var immediately = try translated.break_releases_owner(gpa, 3, 1);
    defer releaseStringList(gpa, &immediately);
    try expectStringList(&.{}, &immediately);
}

test "a continue after a move frees the moved owner once" {
    const gpa = std.testing.allocator;

    // `skip` of zero names no iteration, so every iteration fell through and
    // every element is the plain string.
    var plain = try translated.continue_after_move(gpa, 3, 0);
    defer releaseStringList(gpa, &plain);
    try expectStringList(&.{ "round", "round", "round" }, &plain);

    // The second iteration moved its owner and then continued. The `!` is
    // appended only on that route, so a loop that continued on some other
    // iteration cannot pass — and the moved owner is released once, by this
    // list, while the byte list the body never moved was released by the body.
    var skipped = try translated.continue_after_move(gpa, 3, 2);
    defer releaseStringList(gpa, &skipped);
    try expectStringList(&.{ "round", "round!", "round" }, &skipped);

    var empty = try translated.continue_after_move(gpa, 0, 1);
    defer releaseStringList(gpa, &empty);
    try expectStringList(&.{}, &empty);
}

test "an early return from inside a loop frees both owners it still holds" {
    const gpa = std.testing.allocator;

    // The loop never runs, so the frame's own owner is released by the frame
    // and the empty accumulator is what leaves.
    var never = try translated.return_holds_owner(gpa, 0, 1);
    defer never.deinit(gpa);
    try std.testing.expectEqualStrings("", never.as_str());

    // The first iteration returned. Its own owner was still live and the
    // frame's owner was only borrowed, so the return released both while
    // handing the accumulator on.
    var first = try translated.return_holds_owner(gpa, 4, 1);
    defer first.deinit(gpa);
    try std.testing.expectEqualStrings("carried", first.as_str());

    // The second iteration returned, after one round was already folded in.
    var second = try translated.return_holds_owner(gpa, 4, 2);
    defer second.deinit(gpa);
    try std.testing.expectEqualStrings(".carried", second.as_str());

    // No iteration returned, so the loop ran out and the frame handed on what
    // it accumulated. The frame's own owner is released either way.
    var ran_out = try translated.return_holds_owner(gpa, 4, 9);
    defer ran_out.deinit(gpa);
    try std.testing.expectEqualStrings("....", ran_out.as_str());
}

test "a while let drains its iterator into one owner the caller releases" {
    const gpa = std.testing.allocator;

    // An empty iterator: the `while let` never enters its body, so no
    // iteration owner existed and the result is the empty accumulator.
    var empty = try translated.while_let_drains(gpa, &.{});
    defer empty.deinit(gpa);
    try std.testing.expectEqualStrings("", empty.as_str());

    // One step. The `!` proves the loop read the item the iterator yielded
    // rather than a fixed value, and the accumulated string is the only owner
    // that left the frame.
    var single = try translated.while_let_drains(gpa, &.{2});
    defer single.deinit(gpa);
    try std.testing.expectEqualStrings("ab!", single.as_str());

    // Three steps, and only the middle one appended the `!`. Each iteration
    // built an owner, read it into the accumulator and released it when the
    // iteration ended, so three owners were released and one was handed on.
    var several = try translated.while_let_drains(gpa, &.{ 1, 2, 3 });
    defer several.deinit(gpa);
    try std.testing.expectEqualStrings("abab!ab", several.as_str());
}

// Every frame above builds an owner per iteration and hands the frame's own
// owner on, so the failure a constructor can report lands exactly where a
// release that never runs would strand what the frame already owns. Running
// all five exit routes under that fault injection is what makes the cleanup
// claim cover the failing paths and not only the ones that succeed.
fn exitPathsUnderAllocationFailures(gpa: std.mem.Allocator) !void {
    var carried = try translated.break_carries_owner(gpa, 3);
    defer carried.deinit(gpa);
    try std.testing.expectEqualStrings("ababab", carried.as_str());

    var by_condition = try translated.break_releases_owner(gpa, 3, 9);
    defer releaseStringList(gpa, &by_condition);
    try expectStringList(&.{ "round", "round", "round" }, &by_condition);

    var by_break = try translated.break_releases_owner(gpa, 3, 2);
    defer releaseStringList(gpa, &by_break);
    try expectStringList(&.{"round"}, &by_break);

    var continued = try translated.continue_after_move(gpa, 3, 2);
    defer releaseStringList(gpa, &continued);
    try expectStringList(&.{ "round", "round!", "round" }, &continued);

    var returned = try translated.return_holds_owner(gpa, 4, 2);
    defer returned.deinit(gpa);
    try std.testing.expectEqualStrings(".carried", returned.as_str());

    var ran_out = try translated.return_holds_owner(gpa, 4, 9);
    defer ran_out.deinit(gpa);
    try std.testing.expectEqualStrings("....", ran_out.as_str());

    var drained = try translated.while_let_drains(gpa, &.{ 1, 2, 3 });
    defer drained.deinit(gpa);
    try std.testing.expectEqualStrings("abab!ab", drained.as_str());
}

test "every loop exit releases what it still holds when an allocation fails" {
    try exitPathsUnderAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exitPathsUnderAllocationFailures,
        .{},
    );
}
