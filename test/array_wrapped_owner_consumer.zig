//! Consumer tests for the translated `array-wrapped-owner` package.
//!
//! The crate builds a `[String; 2]`, hands it to a callee BY VALUE, and lets
//! that callee take the elements out one at a time. The array is a WRAPPED
//! owner, so the two halves of the contract are separate claims and each needs
//! its own measurement:
//!
//! - each element reaches its new owner as the allocation it already was, and
//!   is released by exactly one owner afterwards; and
//! - the array's own release frees what is still standing in it and nothing
//!   that has already left.
//!
//! The allocator below answers both by COUNT rather than by leaving them to a
//! leak report. `std.testing.allocator` underneath still catches a leak and
//! still catches a double free, but "released once" and "released twice here
//! and once elsewhere" both look fine in a heap that only complains at the end,
//! so every allocation and every release that crosses the boundary is recorded
//! and the tests ask how many releases reached one address, and how many
//! releases ran at all inside one call.
//!
//! No test reads printed text and no test reimplements the crate: every byte
//! and every number compared below came out of the translated package.
//!
//! Built like the `test/compat_consumer.zig` invocation in `test/e2e_test.zig`,
//! with the generated package root in place of the compat one. The root module
//! imports `r2z` itself, so it needs its own `--dep r2z`; this consumer names no
//! `r2z` type and needs none:
//!
//!     zig test \
//!         --dep translated \
//!         -Mroot=test/array_wrapped_owner_consumer.zig \
//!         --dep r2z \
//!         -Mtranslated=<generated>/src/root.zig \
//!         -Mr2z=r2z-core/src/root.zig

const std = @import("std");
const translated = @import("translated");

/// Every allocation and every release that crossed this allocator.
///
/// `child` does the work. This records the two lists the proof compares, so a
/// single address can be asked how many times it was released, every address can
/// be asked whether it was released at all, and a whole call can be asked how
/// many releases ran inside it. A record is an ADDRESS rather than a slice,
/// because the question is about ownership and not about size: the same bytes
/// under a second owner is the failure, whatever their length.
///
/// `overflow` reports a ledger too small for the run instead of dropping a
/// record, so a truncated ledger cannot turn a leak into a silent pass.
const Ledger = struct {
    const capacity = 32;

    child: std.mem.Allocator,
    handed_out: [capacity]usize = undefined,
    released: [capacity]usize = undefined,
    handed_out_count: usize = 0,
    released_count: usize = 0,
    overflow: bool = false,

    fn init(child: std.mem.Allocator) Ledger {
        return .{ .child = child };
    }

    /// This ledger as an allocator. The ledger itself must not move once this is
    /// called: the vtable holds its address.
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

/// Every allocation this ledger handed out was released exactly once, and the
/// two lists are the same length.
///
/// The first half is the leak check the caller can state as a number: an address
/// with no release is storage nobody freed, and an address with two is storage
/// two owners freed. Equal lengths make the second half exact rather than
/// statistical — every release is accounted for by an allocation this run made,
/// so a release of something the run never allocated would have to displace one
/// that was, and the count would not match.
fn expectReleasedOnceEach(ledger: *const Ledger) !void {
    try std.testing.expect(!ledger.overflow);
    try std.testing.expectEqual(ledger.handed_out_count, ledger.released_count);
    for (ledger.handed_out[0..ledger.handed_out_count]) |address| {
        try std.testing.expectEqual(@as(usize, 1), ledger.releasesOf(address));
    }
}

/// Release a list of owning elements the way the runtime releases one: every
/// element on its own, and the list's own storage last.
fn releaseElements(gpa: std.mem.Allocator, list: anytype) void {
    for (list.items) |*element| element.deinit(gpa);
    list.deinit(gpa);
}

// Both elements left the array by a move, so the array's own release ran at the
// end of the callee and found nothing to free. That is the whole claim of this
// route, and it is a COUNT: a release that walked the array regardless of what
// had already moved would show up here as one or two releases before the caller
// has released anything.
test "both elements move out of the array and reach the caller as separate owners" {
    var ledger = Ledger.init(std.testing.allocator);
    const gpa = ledger.allocator();

    var elements = try translated.array_owner_elements(gpa);

    // The frame is gone and it released nothing: both elements had left by the
    // time its scope ended.
    try std.testing.expectEqual(@as(usize, 0), ledger.released_count);

    try std.testing.expectEqual(@as(usize, 2), elements.items.len);
    const left_address = @intFromPtr(elements.items[0].as_bytes().ptr);
    const right_address = @intFromPtr(elements.items[1].as_bytes().ptr);

    // Two owners, not one owner named twice: the elements carry separate
    // allocations, so releasing either does not reach the other's bytes.
    try std.testing.expect(left_address != right_address);
    try std.testing.expect(ledger.handedOut(left_address));
    try std.testing.expect(ledger.handedOut(right_address));

    // The moved-out values are usable after the move, in the order the array
    // held them.
    try std.testing.expectEqualStrings("left", elements.items[0].as_str());
    try std.testing.expectEqualStrings("right", elements.items[1].as_str());

    // The caller's own releases are the first and only ones on those bytes.
    try std.testing.expectEqual(@as(usize, 0), ledger.releasesOf(left_address));
    try std.testing.expectEqual(@as(usize, 0), ledger.releasesOf(right_address));

    releaseElements(gpa, &elements);
    try std.testing.expectEqual(@as(usize, 1), ledger.releasesOf(left_address));
    try std.testing.expectEqual(@as(usize, 1), ledger.releasesOf(right_address));

    try expectReleasedOnceEach(&ledger);
}

// The contrast for the test above. The same array of the same two elements goes
// into a callee that takes both out and keeps them, so the releases happen
// INSIDE the call instead of in the caller: the count of releases before and
// after is what separates "the callee released each element once" from "the
// callee released one element twice and the other not at all".
test "elements moved out and released inside the callee are released once each" {
    var ledger = Ledger.init(std.testing.allocator);
    const gpa = ledger.allocator();

    // "left" and "right" are four and five bytes, and the answer is their sum,
    // so the number also says WHICH elements were measured.
    try std.testing.expectEqual(@as(usize, 9), try translated.array_owner_lengths(gpa));

    try expectReleasedOnceEach(&ledger);
}

// A partial drain. One element leaves and one stays, so the array's own release
// has exactly one element left to free — and the element that left must not be
// among them, which is what a release count taken across the call says.
test "the element that stayed in the array is released once, by the array" {
    var ledger = Ledger.init(std.testing.allocator);
    const gpa = ledger.allocator();

    var moved = try translated.array_owner_first_element(gpa);

    // Two elements went in and the callee released one of them. A release that
    // walked both would make this two; a callee that leaked the element it kept
    // would make it zero.
    try std.testing.expectEqual(@as(usize, 1), ledger.released_count);

    const address = @intFromPtr(moved.as_bytes().ptr);
    try std.testing.expect(ledger.handedOut(address));

    // The bytes the caller holds were not among the release inside the call, so
    // they are still the bytes the array was holding.
    try std.testing.expectEqual(@as(usize, 0), ledger.releasesOf(address));
    try std.testing.expectEqualStrings("moved", moved.as_str());

    moved.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), ledger.releasesOf(address));

    try expectReleasedOnceEach(&ledger);
}

// Every route above builds owned elements and then hands them on or keeps them,
// so the failures their constructors can report are what this sweep exists for:
// whatever a frame already owns has to be released when the NEXT allocation
// fails, or the sweep reports a leak rather than a bug in the frame. A release
// that runs twice on a failure path is caught the same way, by the allocator
// underneath.
fn everyRouteWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var elements = try translated.array_owner_elements(gpa);
    defer releaseElements(gpa, &elements);
    try std.testing.expectEqualStrings("left", elements.items[0].as_str());

    var moved = try translated.array_owner_first_element(gpa);
    defer moved.deinit(gpa);
    try std.testing.expectEqualStrings("moved", moved.as_str());

    try std.testing.expectEqual(@as(usize, 9), try translated.array_owner_lengths(gpa));
}

test "a failing allocator leaks nothing on any route" {
    try everyRouteWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        everyRouteWithAllocationFailures,
        .{},
    );
}
