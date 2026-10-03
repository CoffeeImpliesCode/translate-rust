//! Consumer tests for the translated `match-subject-handoff` package.
//!
//! Every function in that package OWNS a cow by value, `match`es it, and
//! decides from what the arm bound who holds the bytes afterwards. These tests
//! ask the only question that matters about such a frame: which owner holds them
//! once the frame has returned, and how many times were they released on the
//! way out.
//!
//! Nothing here reimplements the fixture. Every value compared is read out of
//! the package's own return value or out of storage this file built before the
//! call, and every count is a count of releases the package actually performed.
//!
//! The defect these tests are here for is a USE-AFTER-FREE, not a leak and not
//! a double free: a frame that reads its match subject where Rust moves it still
//! holds the slab the returned value names, so the bytes are already gone by the
//! time the caller looks at them. The release counts below catch that without
//! depending on the symptom — `forwarded_releases` is read while the frame is
//! still on the stack — and the byte comparisons catch it again on the values
//! themselves, so a regression is reported as a number that is wrong rather
//! than as a crash that happens to be somewhere else.
//!
//! ## Why the counts and not just the bytes
//!
//! A value whose bytes read back correctly can already have been freed. The
//! counting allocator is what separates "the frame released nothing and the
//! caller is the one owner" from "the frame released once and so did the
//! caller", and it is what separates "the frame released exactly what it kept"
//! from a frame that drained a subject no arm moved and leaked the slab it
//! still owned. `std.testing.allocator` reports a leak or a double free
//! underneath all of it; the count is what names which of the two happened.
//!
//! ## Invocation
//!
//! Built like the `test/cow_handoff_consumer.zig` invocation in
//! `test/e2e_test.zig`, with this package's generated root in place of that
//! one. The generated root imports the runtime itself — a `Cow` and a `Vec` are
//! both named through it — so it is given `--dep r2z`, which is also how
//! `expectOwnershipFixtureTranslated` is called for this fixture:
//!
//!     zig test --dep translated --dep r2z \
//!         -Mroot=test/match_subject_handoff_consumer.zig \
//!         --dep r2z -Mtranslated=<generated>/src/root.zig \
//!         -Mr2z=r2z-core/src/root.zig

const std = @import("std");
const translated = @import("translated");

/// The bytes every call here is made over, and the length the two measuring
/// frames must report for them.
///
/// The value is spelled out here rather than taken from the fixture, so each
/// expectation is a claim about the specification and not a restatement of
/// whatever the package happens to do.
const input = "ab%20cd";

/// Every release the counting allocator below has forwarded.
///
/// A release is counted rather than merely detected: "released nothing" and
/// "released exactly once" are different facts about a hand-off, and only a
/// count tells them apart.
var forwarded_releases: usize = 0;

fn countAndFree(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
    forwarded_releases += 1;
    std.heap.page_allocator.rawFree(memory, alignment, return_address);
}

/// `page_allocator` with every release counted.
///
/// The page allocator sits underneath because the claim is a count rather than
/// a leak report, and a count is what separates "released once" from "released
/// twice" for a value that is still perfectly readable.
fn countingAllocator() std.mem.Allocator {
    const vtable = comptime blk: {
        var table = std.heap.page_allocator.vtable.*;
        table.free = countAndFree;
        break :blk table;
    };
    return .{ .ptr = std.heap.page_allocator.ptr, .vtable = &vtable };
}

// The hand-off the fixture is built around, taken straight from a temporary.
// `owned_bytes` binds the owned payload by value and returns it, so the caller
// receives the very allocation the frame was handed and the frame owes it no
// release of its own.
//
// Two independent claims. The byte comparison says the value that arrived is
// the value that was sent. The count says the frame let go of nothing: a frame
// that freed that allocation on its way out would leave the caller reading
// freed storage, which is the whole defect.
test "the owned payload reaches the caller intact and the frame releases none of it" {
    {
        forwarded_releases = 0;
        const gpa = countingAllocator();
        var handed = try translated.owned_bytes(gpa, input, true);
        try std.testing.expectEqual(@as(usize, 0), forwarded_releases);
        // Read AFTER the frame returned. This is the read the defect made
        // impossible, and it is deliberately past the point where the frame's
        // own release would have run.
        try std.testing.expectEqualStrings(input, handed.items);
        handed.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), forwarded_releases);
    }
}

// The same hand-off across a FUNCTION BOUNDARY, which is how
// `percent-encoding` writes it: the destructuring frame owns a by-value
// PARAMETER, and the lowering arms a release over that parameter for the whole
// body. A rule that failed to spend the subject would leave that release armed
// over bytes the caller now holds, and the count below is where it shows.
test "the hand-off survives a frame that owns the payload as a parameter" {
    {
        forwarded_releases = 0;
        const gpa = countingAllocator();
        var handed = try translated.round_trip_bytes(gpa, input, true);
        try std.testing.expectEqual(@as(usize, 0), forwarded_releases);
        try std.testing.expectEqualStrings(input, handed.items);
        handed.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), forwarded_releases);
    }
}

// The opposite claim, on a frame whose arm DOES bind the owned payload by
// value. A by-value binding is a move whatever the body does with it, so the
// payload moves out of the subject into the arm, and the ARM's release is the
// one that frees the slab. The subject's own release finds nothing, and a
// lowering that read the subject instead would leave both handles naming one
// slab — which is the double-free half of the same defect.
test "a frame whose arm binds the payload by value releases it exactly once" {
    forwarded_releases = 0;
    {
        const gpa = countingAllocator();
        try std.testing.expectEqual(input.len, try translated.moved_bytes(gpa, input, true));
        try std.testing.expectEqual(@as(usize, 1), forwarded_releases);
    }
    // The borrowed path of that same frame owns nothing, so it owes no release
    // at all. A frame that freed a borrow would be freeing the caller's own
    // buffer, which is the other half of the same mistake.
    forwarded_releases = 0;
    {
        const gpa = countingAllocator();
        try std.testing.expectEqual(input.len, try translated.moved_bytes(gpa, input, false));
        try std.testing.expectEqual(@as(usize, 0), forwarded_releases);
    }
}

// The control for `moved_bytes`, and the claim that keeps the fix honest. Here
// no arm binds anything, so the dispatch spends nothing and the frame's own
// release over the subject is the only one there is. A rule that drained EVERY
// match subject would empty this one and leak the slab it still owns — a leak
// rather than a crash, which is why it needs a test of its own to be caught.
test "a frame whose arm binds nothing still releases the slab its subject holds" {
    forwarded_releases = 0;
    {
        const gpa = countingAllocator();
        try std.testing.expectEqual(@as(usize, 1), try translated.kept_bytes(gpa, input, true));
        try std.testing.expectEqual(@as(usize, 1), forwarded_releases);
    }
    // The borrowed arm names the caller's own slice, so there is nothing for
    // the frame to free and nothing for the caller to double free.
    forwarded_releases = 0;
    {
        const gpa = countingAllocator();
        try std.testing.expectEqual(@as(usize, 0), try translated.kept_bytes(gpa, input, false));
        try std.testing.expectEqual(@as(usize, 0), forwarded_releases);
    }
}

// The borrowed payload the frame is handed is the CALLER's storage, so it must
// come back unchanged and still be the caller's to release. The buffer is
// allocated here rather than borrowed from a literal precisely so that a frame
// which freed what it borrowed shows up as freed memory this file then reads.
test "the borrowed payload is the caller's own storage and outlives the frame" {
    forwarded_releases = 0;
    {
        const gpa = countingAllocator();
        const buffer = try gpa.dupe(u8, input);
        defer gpa.free(buffer);

        try std.testing.expectEqual(@as(usize, 0), try translated.kept_bytes(gpa, buffer, false));
        try std.testing.expectEqual(@as(usize, 0), forwarded_releases);
        try std.testing.expectEqualStrings(input, buffer);

        // The value that comes back is a COPY: a borrow would hand back the
        // caller's own address, and the frame's release would then be a free of
        // storage this file still holds.
        var copied = try translated.owned_bytes(gpa, buffer, false);
        try std.testing.expectEqualStrings(input, copied.items);
        try std.testing.expect(copied.items.ptr != buffer.ptr);
        copied.deinit(gpa);

        // Read once more after the copy's own release: the bytes the frame
        // borrowed are still the caller's, and still readable.
        try std.testing.expectEqualStrings(input, buffer);
        try std.testing.expectEqual(@as(usize, 1), forwarded_releases);
    }
}

// Every call above, driven against the leak-checking allocator and then against
// every failing allocation index. A frame that abandoned storage it still owned
// leaks at whichever index the allocator fails; a frame that released a payload
// it had already handed on frees the caller's bytes a second time on the path
// that succeeded. Both are reported by the runner underneath this sweep.
fn everyCall(gpa: std.mem.Allocator) !void {
    var handed = try translated.owned_bytes(gpa, input, true);
    try std.testing.expectEqualStrings(input, handed.items);
    handed.deinit(gpa);

    var through = try translated.round_trip_bytes(gpa, input, true);
    try std.testing.expectEqualStrings(input, through.items);
    through.deinit(gpa);

    try std.testing.expectEqual(input.len, try translated.moved_bytes(gpa, input, true));
    try std.testing.expectEqual(@as(usize, 1), try translated.kept_bytes(gpa, input, true));
}

test "the hand-off leaks nothing and frees nothing twice at any failing allocation" {
    try everyCall(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        everyCall,
        .{},
    );
}
