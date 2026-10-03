//! Consumer tests for the translated `let-bound-result-match` package.
//!
//! The crate binds one owning `Result<String, String>` to the name `outcome`
//! and then matches that name by value, so every arm moves the payload the
//! carrier was holding. What the caller receives is therefore the whole
//! question: the payload has to survive the frame, the carrier has to be
//! released exactly once, and nothing may be released twice.
//!
//! The allocator below answers the second and third questions directly instead
//! of leaving them to a leak report. `std.testing.allocator` underneath still
//! catches a leak and still catches a double free, but what the proof needs is
//! the COUNT, because "released once" and "released twice and once elsewhere"
//! are both invisible in a heap that only complains at the end. So every
//! allocation and every release is recorded here, and the tests ask how many
//! releases reached one address.
//!
//! No test reads printed text and no test reimplements the crate: every number
//! and every byte compared below came out of the translated package.
//!
//! Built like the `test/compat_consumer.zig` invocation in `test/e2e_test.zig`,
//! with the generated package root in place of the compat one. The root module
//! imports `r2z` itself, so it needs its own `--dep r2z`; this consumer names no
//! `r2z` type and needs none:
//!
//!     zig test \
//!         --dep translated \
//!         -Mroot=test/let_bound_result_consumer.zig \
//!         --dep r2z \
//!         -Mtranslated=<generated>/src/root.zig \
//!         -Mr2z=r2z-core/src/root.zig

const std = @import("std");
const translated = @import("translated");

/// Every allocation and every release that crossed this allocator.
///
/// `child` does the work. This records the two lists the proof compares, so a
/// single address can be asked how many times it was released and every address
/// can be asked whether it was released at all. A record is an ADDRESS rather
/// than a slice, because the question is about ownership and not about size: the
/// same bytes under a second owner is the failure, whatever their length.
///
/// `overflow` reports a ledger too small for the run instead of dropping a
/// record, so a truncated ledger cannot turn a leak into a silent pass.
const Ledger = struct {
    const capacity = 256;

    child: std.mem.Allocator,
    handed_out: [capacity]usize = undefined,
    released: [capacity]usize = undefined,
    handed_out_count: usize = 0,
    released_count: usize = 0,
    overflow: bool = false,

    fn init(child: std.mem.Allocator) Ledger {
        return .{ .child = child };
    }

    /// This ledger as an allocator. The ledger itself must not move once this
    /// is called: the vtable holds its address.
    fn allocator(self: *Ledger) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Whether `address` was one of the allocations this ledger handed out.
    fn handedOut(self: *const Ledger, address: usize) bool {
        for (self.handed_out[0..self.handed_out_count]) |entry| {
            if (entry == address) return true;
        }
        return false;
    }

    /// How many releases reached `address`.
    fn releasesOf(self: *const Ledger, address: usize) usize {
        var releases: usize = 0;
        for (self.released[0..self.released_count]) |entry| {
            if (entry == address) releases += 1;
        }
        return releases;
    }

    fn recordHandedOut(self: *Ledger, address: usize) void {
        if (self.handed_out_count == capacity) {
            self.overflow = true;
            return;
        }
        self.handed_out[self.handed_out_count] = address;
        self.handed_out_count += 1;
    }

    fn recordReleased(self: *Ledger, address: usize) void {
        if (self.released_count == capacity) {
            self.overflow = true;
            return;
        }
        self.released[self.released_count] = address;
        self.released_count += 1;
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    fn allocFn(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Ledger = @ptrCast(@alignCast(context));
        const memory = self.child.rawAlloc(len, alignment, return_address) orelse return null;
        self.recordHandedOut(@intFromPtr(memory));
        return memory;
    }

    fn resizeFn(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *Ledger = @ptrCast(@alignCast(context));
        return self.child.rawResize(memory, alignment, new_len, return_address);
    }

    // A remap that keeps its address leaves both lists alone; one that moves
    // ends the old storage and begins the new, so both are recorded and the two
    // lists stay in step.
    fn remapFn(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Ledger = @ptrCast(@alignCast(context));
        const moved = self.child.rawRemap(memory, alignment, new_len, return_address) orelse return null;
        if (@intFromPtr(moved) != @intFromPtr(memory.ptr)) {
            self.recordReleased(@intFromPtr(memory.ptr));
            self.recordHandedOut(@intFromPtr(moved));
        }
        return moved;
    }

    fn freeFn(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *Ledger = @ptrCast(@alignCast(context));
        self.recordReleased(@intFromPtr(memory.ptr));
        self.child.rawFree(memory, alignment, return_address);
    }
};

/// Every allocation this ledger handed out was released exactly once, and no
/// release reached an address it never handed out.
///
/// The first half is the leak check the caller can state as a number: an address
/// with no release is storage nobody freed, and an address with two is storage
/// two owners freed. The second half catches a release of something this run
/// never allocated, which is how a carrier that freed a moved-from payload's
/// former neighbour would show up.
fn expectReleasedOnceEach(ledger: *const Ledger) !void {
    try std.testing.expect(!ledger.overflow);
    try std.testing.expectEqual(ledger.handed_out_count, ledger.released_count);
    for (ledger.handed_out[0..ledger.handed_out_count]) |address| {
        try std.testing.expectEqual(@as(usize, 1), ledger.releasesOf(address));
    }
}

// The `Ok` arm. Mode 0 builds `Ok(String::from("payload"))`.
test "the Ok arm's payload survives the carrier and reaches the caller whole" {
    var ledger = Ledger.init(std.testing.allocator);
    const gpa = ledger.allocator();

    var payload = try translated.let_bound_result_match(gpa, 0);
    const address = @intFromPtr(payload.as_bytes().ptr);

    // The bytes the caller holds are the ones the carrier was holding, so the
    // ledger has to have seen that address handed out.
    try std.testing.expect(ledger.handedOut(address));

    // The frame returned and its scope ended before this read. A carrier
    // release that ran after the match would have freed these bytes, and the
    // bytes would not read back as the text the arm moved out.
    try std.testing.expectEqualStrings("payload", payload.as_str());
    try std.testing.expectEqual(@as(usize, 0), ledger.releasesOf(address));

    // The caller's own release is the first and only one this run performs on
    // those bytes, so it is also the last: nothing downstream can reach them.
    payload.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), ledger.releasesOf(address));

    try expectReleasedOnceEach(&ledger);
}

// The `Err` arm, and the same three claims. Mode 1 builds
// `Err(String::from("rejected"))`, so this is a second owned payload of a
// second length rather than the first one again.
test "the Err arm's payload survives the carrier and reaches the caller whole" {
    var ledger = Ledger.init(std.testing.allocator);
    const gpa = ledger.allocator();

    var payload = try translated.let_bound_result_match(gpa, 1);
    const address = @intFromPtr(payload.as_bytes().ptr);

    try std.testing.expect(ledger.handedOut(address));
    try std.testing.expectEqualStrings("rejected", payload.as_str());
    try std.testing.expectEqual(@as(usize, 0), ledger.releasesOf(address));

    payload.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), ledger.releasesOf(address));

    try expectReleasedOnceEach(&ledger);
}

// The control. No arm moves anything out here, so the payload stays inside the
// frame and has to be freed before the frame returns. Its length is what proves
// WHICH arm ran: the two payloads are seven and eight bytes.
test "a payload no arm moved is released exactly once, on both arms" {
    var ledger = Ledger.init(std.testing.allocator);
    const gpa = ledger.allocator();

    try std.testing.expectEqual(@as(usize, 7), try translated.let_bound_result_match_length(gpa, 0));
    try expectReleasedOnceEach(&ledger);

    try std.testing.expectEqual(@as(usize, 8), try translated.let_bound_result_match_length(gpa, 1));
    try expectReleasedOnceEach(&ledger);
}

// Every frame below builds its owned payload and hands it on, so the failures
// its constructor can report are the ones this sweep exists for: whatever a
// frame already owns has to be released when the next allocation fails, or the
// sweep reports a leak rather than a bug in the frame. Both arms run on both
// allocations.
fn bothArmsWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var ok_payload = try translated.let_bound_result_match(gpa, 0);
    defer ok_payload.deinit(gpa);
    try std.testing.expectEqualStrings("payload", ok_payload.as_str());

    var err_payload = try translated.let_bound_result_match(gpa, 1);
    defer err_payload.deinit(gpa);
    try std.testing.expectEqualStrings("rejected", err_payload.as_str());

    try std.testing.expectEqual(@as(usize, 7), try translated.let_bound_result_match_length(gpa, 0));
    try std.testing.expectEqual(@as(usize, 8), try translated.let_bound_result_match_length(gpa, 1));
}

test "a failing allocator leaks nothing on either arm" {
    try bothArmsWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        bothArmsWithAllocationFailures,
        .{},
    );
}
