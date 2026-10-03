//! Consumer tests for the translated `result-arm-payload-move` package.
//!
//! Every expectation here is a claim about what the package does with the
//! storage it is handed: which arm's payload reaches the caller, who releases
//! it, and what is left over when an allocation fails. Nothing reimplements the
//! translated code, and no test reads printed text.
//!
//! Built like the `test/compat_consumer.zig` invocation in `test/e2e_test.zig`,
//! with the generated package root in place of the compat one. This root module
//! imports nothing but the generated package and `std`, so it needs only
//! `--dep translated`:
//!
//!     zig test --dep translated \
//!         -Mroot=test/result_arm_payload_consumer.zig \
//!         -Mtranslated=<generated>/src/root.zig

const std = @import("std");
const translated = @import("translated");

/// What each arm of the temporary carries. `payload_move` hands that text over
/// and `payload_length` reads it, so every expectation below is stated against
/// this table rather than against the translated code.
const arms = [_]struct { present: bool, text: []const u8, length: usize }{
    .{ .present = true, .text = "present", .length = 7 },
    .{ .present = false, .text = "absent", .length = 6 },
};

/// Every release the counting allocator below has forwarded.
///
/// `std.testing.allocator` reports a leak and aborts on a double free, so a
/// test that completes has already shown that nothing was left behind and
/// nothing was freed twice. It cannot say HOW MANY releases there were, which
/// is the claim these tests make on their own: one per payload, and none at all
/// on the arm that handed its payload to the caller.
var forwarded_releases: usize = 0;

fn countAndFree(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
    forwarded_releases += 1;
    std.heap.page_allocator.rawFree(memory, alignment, return_address);
}

/// `page_allocator` with every release counted.
///
/// The page allocator is used underneath because the claim here is a count, not
/// a leak report: the count is what separates "released once" from "released
/// twice". The leak and double-free claims are made separately, against the
/// testing allocator, over the same calls.
fn countingAllocator() std.mem.Allocator {
    const vtable = comptime blk: {
        var table = std.heap.page_allocator.vtable.*;
        table.free = countAndFree;
        break :blk table;
    };
    return .{ .ptr = std.heap.page_allocator.ptr, .vtable = &vtable };
}

// Both arms move. The `Ok` arm hands over the string the frame built for the
// lookup, and the `Err` arm hands over the string it built for the reason the
// lookup found nothing, so the caller owns the payload either way.
test "both arms hand the temporary's owned payload to the caller" {
    const gpa = std.testing.allocator;

    var found = try translated.payload_move(gpa, true);
    defer found.deinit(gpa);
    try std.testing.expectEqualStrings(arms[0].text, found.as_str());

    var reason = try translated.payload_move(gpa, false);
    defer reason.deinit(gpa);
    try std.testing.expectEqualStrings(arms[1].text, reason.as_str());

    // Two calls, two allocations. A value that borrowed a literal or a shared
    // static would hand the same bytes back both times, and the caller could
    // not tell a move from a copy of storage somebody else still holds.
    var again = try translated.payload_move(gpa, true);
    defer again.deinit(gpa);
    try std.testing.expectEqualStrings(arms[0].text, again.as_str());
    try std.testing.expect(found.as_bytes().ptr != again.as_bytes().ptr);
    try std.testing.expect(reason.as_bytes().ptr != again.as_bytes().ptr);
}

// Neither arm moves, so each arm's scope owes the release the move would have
// performed. One call is one release: none of them leaks the string the frame
// built, and two of them free the same bytes twice.
test "an arm that keeps its payload releases it exactly once" {
    for (arms) |arm| {
        forwarded_releases = 0;
        {
            const gpa = countingAllocator();
            const length = try translated.payload_length(gpa, arm.present);
            try std.testing.expectEqual(arm.length, length);
        }
        try std.testing.expectEqual(@as(usize, 1), forwarded_releases);
    }
}

// The other half of the same count. A moved payload is released by whoever owns
// it AFTER the arm ends, so the frame itself frees nothing, and a release
// inside the frame would be counted here as the caller's second release of
// bytes the caller still holds.
test "an arm that moves its payload out releases nothing itself" {
    for (arms) |arm| {
        forwarded_releases = 0;
        {
            const gpa = countingAllocator();
            var moved = try translated.payload_move(gpa, arm.present);
            try std.testing.expectEqual(@as(usize, 0), forwarded_releases);
            try std.testing.expectEqualStrings(arm.text, moved.as_str());
            moved.deinit(gpa);
        }
        try std.testing.expectEqual(@as(usize, 1), forwarded_releases);
    }
}

// Every call above, driven against the testing allocator and then against every
// failing allocation index. A frame that abandoned the payload it built, or
// released one it had already handed on, leaks or double-frees at whichever
// index the allocator fails, and this is where that shows.
fn armsWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var found = try translated.payload_move(gpa, true);
    defer found.deinit(gpa);
    try std.testing.expectEqualStrings(arms[0].text, found.as_str());

    var reason = try translated.payload_move(gpa, false);
    defer reason.deinit(gpa);
    try std.testing.expectEqualStrings(arms[1].text, reason.as_str());

    for (arms) |arm| {
        try std.testing.expectEqual(arm.length, try translated.payload_length(gpa, arm.present));
    }
}

test "the payload survives every allocation failure without a leak or a double release" {
    try armsWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        armsWithAllocationFailures,
        .{},
    );
}
