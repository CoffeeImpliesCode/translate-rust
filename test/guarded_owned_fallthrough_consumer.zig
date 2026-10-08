//! Consumer tests for the translated `guarded-owned-fallthrough` package.
//!
//! The crate under test builds owned `String` payloads and hands exactly one of
//! them back, so what these tests pin is a release rather than a value: the
//! bytes the selected arm returns have to be the bytes the frame owned, and the
//! caller's single `deinit` has to be the only release that runs.
//!
//! Two allocator properties turn a wrong release into a failure.
//! `std.testing.allocator` aborts on a second free instead of reading the slab
//! again, so a frame that released the payload its failed guard bound fails on
//! the `deinit` below. It also reports a leak when the test ends, so a frame
//! that kept a label its nested dispatch did not hand out fails there instead.
//!
//! Nothing here restates the fixture's logic: every expectation is bytes the
//! package returned, and every release claim is the allocator's.
//!
//! The end-to-end test stages the generated crate and runs this six-case
//! consumer in Debug and ReleaseSafe.

const std = @import("std");
const translated = @import("translated");

// ── the release ledger ───────────────────────────────────────────────────

/// Every allocation the frames under test make, counted by ADDRESS.
///
/// The claim this file's own tests can make with `std.testing.allocator` alone
/// is weaker than it looks. A payload the failed guard bound belongs to the
/// SCRUTINEE, so a release on that arm's failure path frees storage the next
/// arm then binds and hands to the caller: the caller's `deinit` would be the
/// second free of one slab, and the testing allocator aborts there rather than
/// reporting anything a test could read. The other way round is quieter still —
/// a release that reached an already-emptied handle frees nothing at all, so
/// "the frame released the payload twice" can look like a clean run.
///
/// `Ledger` exists for that gap. It counts every allocation by ADDRESS and
/// every release of that address, so "exactly once" is a number a test reads
/// rather than an absence it infers. It allocates nothing itself: it wraps
/// `std.testing.allocator`, so a genuine double free still panics underneath
/// and a genuine leak is still reported when the test ends.
const Ledger = struct {
    /// One call under test allocates once and frees once, and each test starts
    /// a fresh ledger, so the deepest any of them nests is one live payload at
    /// a time. Four is headroom for a frame that legitimately builds more than
    /// one owned value; running past it is counted rather than ignored, so an
    /// under-count cannot pass silently.
    const capacity = 4;

    const Record = struct {
        address: usize,
        releases: u16,
    };

    child: std.mem.Allocator,
    records: [capacity]Record,
    count: usize,
    /// Allocations made with no room left to record them.
    overflows: usize,
    /// Releases of an address this ledger never handed out — storage this
    /// frame did not own.
    unowned_releases: usize,

    fn init(child: std.mem.Allocator) Ledger {
        return .{
            .child = child,
            .records = undefined,
            .count = 0,
            .overflows = 0,
            .unowned_releases = 0,
        };
    }

    fn allocator(self: *Ledger) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocSlot,
        .resize = resizeSlot,
        .remap = remapSlot,
        .free = freeSlot,
    };

    /// The index of the record for `address`, released or not. A record
    /// outlives its release on purpose: a second free of the same address has
    /// to find it again and count twice, which is the whole point of the
    /// ledger. An index rather than a pointer, so a reader holding the ledger
    /// as a `const` can ask the same question a mutating caller can.
    fn find(self: *const Ledger, address: usize) ?usize {
        for (self.records[0..self.count], 0..) |record, index| {
            if (record.address == address) return index;
        }
        return null;
    }

    /// How many of the recorded allocations have not been released.
    fn liveCount(self: *const Ledger) usize {
        var count: usize = 0;
        for (self.records[0..self.count]) |record| {
            if (record.releases == 0) count += 1;
        }
        return count;
    }

    /// The only address still held, or null when the count is not exactly one.
    fn onlyLiveAddress(self: *const Ledger) ?usize {
        if (self.liveCount() != 1) return null;
        for (self.records[0..self.count]) |record| {
            if (record.releases == 0) return record.address;
        }
        return null;
    }

    /// How many times `address` has been freed.
    fn releasesOf(self: *const Ledger, address: usize) u16 {
        const index = self.find(address) orelse return 0;
        return self.records[index].releases;
    }

    /// Every release the ledger saw, recorded or not.
    fn totalReleases(self: *const Ledger) usize {
        var total = self.unowned_releases;
        for (self.records[0..self.count]) |record| total += record.releases;
        return total;
    }

    fn allocSlot(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Ledger = @ptrCast(@alignCast(context));
        const result = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        if (self.count == capacity) {
            self.overflows += 1;
            return result;
        }
        self.records[self.count] = .{ .address = @intFromPtr(result), .releases = 0 };
        self.count += 1;
        return result;
    }

    fn resizeSlot(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *Ledger = @ptrCast(@alignCast(context));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remapSlot(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Ledger = @ptrCast(@alignCast(context));
        const result = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        // A remap that moved the allocation releases the old address and hands
        // back this one, so the record follows it. One that did not move keeps
        // the address it already has.
        const relocated = @intFromPtr(result);
        if (relocated != @intFromPtr(memory.ptr)) {
            if (self.find(@intFromPtr(memory.ptr))) |index| self.records[index].address = relocated;
        }
        return result;
    }

    fn freeSlot(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *Ledger = @ptrCast(@alignCast(context));
        // A zero-length free releases nothing, so it is not a release of any
        // address and must not be counted as one. The allocator underneath
        // drops those itself; the ledger forwards and forgets.
        if (memory.len != 0) {
            if (self.find(@intFromPtr(memory.ptr))) |index| {
                self.records[index].releases += 1;
            } else {
                self.unowned_releases += 1;
            }
        }
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

/// One path through a fixture function: what selects it, and what it returns.
const Path = struct {
    /// The selector the fixture's own function reads.
    selector: u8,
    /// The bytes the selected arm hands back to the caller.
    bytes: []const u8,
};

/// The arms of the guarded match, in source order.
const fall_through_paths = [_]Path{
    // The guard accepts what the first arm bound, so that arm owns the label.
    .{ .selector = 0, .bytes = "guarded-long" },
    // The guard refuses what the SAME pattern bound. The next arm has to bind
    // that allocation, and the frame must still own it when it does: a release
    // on the guard's failure path would leave the caller's `deinit` a second
    // free of one slab.
    .{ .selector = 1, .bytes = "tiny" },
    // Neither label arm applies, so the arm that binds nothing answers.
    .{ .selector = 2, .bytes = "bare" },
};

/// The arms of the nested dispatch, in source order.
const nested_paths = [_]Path{
    // The nested single-payload variant: the inner arm hands out the label the
    // outer arm's payload owned.
    .{ .selector = 0, .bytes = "inner-solo" },
    // The nested tuple variant: the inner arm hands out the SECOND label, and
    // the first one is released inside the frame instead of being returned.
    .{ .selector = 1, .bytes = "inner-right" },
    // The outer tuple variant, dispatched without nesting.
    .{ .selector = 2, .bytes = "outer-right" },
    // No payload arm applies at all.
    .{ .selector = 3, .bytes = "bare" },
};

test "a failed guard hands its own payload to the next arm" {
    const gpa = std.testing.allocator;
    for (fall_through_paths) |path| {
        var label = try translated.guarded_fallthrough(gpa, path.selector);
        defer label.deinit(gpa);
        try std.testing.expectEqualStrings(path.bytes, label.as_str());
    }
}

test "a refused guard returns an allocation the frame still owned" {
    const gpa = std.testing.allocator;
    var first = try translated.guarded_fallthrough(gpa, 1);
    defer first.deinit(gpa);
    var second = try translated.guarded_fallthrough(gpa, 1);
    defer second.deinit(gpa);
    try std.testing.expectEqualStrings("tiny", first.as_str());
    try std.testing.expectEqualStrings("tiny", second.as_str());
    // Equal bytes from two separate slabs. A frame that released the payload its
    // failed guard bound, and then handed that same slab on to the next arm,
    // would return storage it had already given back: either `deinit` above
    // would then be that slab's second free.
    try std.testing.expect(first.as_bytes().ptr != second.as_bytes().ptr);
}

/// The end state the refused guard's path has to reach: the payload the second
/// arm handed out freed exactly once, nothing else freed, nothing left live.
fn expectReleasedExactlyOnce(ledger: *const Ledger, address: usize) !void {
    try std.testing.expectEqual(@as(usize, 0), ledger.liveCount());
    try std.testing.expectEqual(@as(u16, 1), ledger.releasesOf(address));
    try std.testing.expectEqual(@as(usize, 1), ledger.totalReleases());
    try std.testing.expectEqual(@as(usize, 0), ledger.unowned_releases);
    try std.testing.expectEqual(@as(usize, 0), ledger.overflows);
}

// A guard's failure path is the one path no allocator complaint covers on its
// own, so this counts the payload's releases by address instead. The frame
// binds the label twice over the refused selector — once for the guard that
// declines it and once for the arm that hands it back — and both bindings name
// ONE allocation, which is the whole claim: released once by the caller, and
// released by nobody in between.
test "a refused guard's payload falls through to the next arm and is released once" {
    for (fall_through_paths) |path| {
        var ledger = Ledger.init(std.testing.allocator);
        const gpa = ledger.allocator();

        var label = try translated.guarded_fallthrough(gpa, path.selector);

        // The frame owns the payload at this point and has released nothing:
        // the label the guard measured is the label the caller is being handed,
        // so a release on the way out would free what this call still owns.
        try std.testing.expectEqualStrings(path.bytes, label.as_str());
        try std.testing.expectEqual(@as(usize, 0), ledger.totalReleases());

        const address = ledger.onlyLiveAddress() orelse
            return error.PayloadBytesNotHeldOnce;
        // The bytes that came back are the bytes the frame allocated. A copy
        // would have left the original live as a second allocation, and the
        // caller's release would then have freed the copy rather than the
        // frame's own bytes.
        try std.testing.expectEqual(address, @intFromPtr(label.as_bytes().ptr));

        label.deinit(gpa);
        try expectReleasedExactlyOnce(&ledger, address);
    }
}

// The refused selector is the claim above; this is the neighbouring one, that
// the ACCEPTED selector releases nothing in the frame either. An arm that
// released its payload and then handed it on would show up here as a release
// before the caller's `deinit`, which the caller's `deinit` would then double.
test "an accepted guard's payload reaches the caller without an in-frame release" {
    var ledger = Ledger.init(std.testing.allocator);
    const gpa = ledger.allocator();

    var label = try translated.guarded_fallthrough(gpa, 0);
    defer label.deinit(gpa);

    try std.testing.expectEqualStrings("guarded-long", label.as_str());
    // Nothing was freed before the caller released anything, and nothing was
    // freed that this call did not allocate: one slab, alive, untouched.
    try std.testing.expectEqual(@as(usize, 0), ledger.totalReleases());
    try std.testing.expectEqual(@as(usize, 1), ledger.liveCount());
    try std.testing.expectEqual(@as(usize, 0), ledger.unowned_releases);
}

test "nested owned variant dispatch hands out one label per call" {
    const gpa = std.testing.allocator;
    for (nested_paths) |path| {
        var label = try translated.nested_owned_dispatch(gpa, path.selector);
        defer label.deinit(gpa);
        try std.testing.expectEqualStrings(path.bytes, label.as_str());
    }
}

// Each frame below builds every payload it needs and hands the selected one on,
// so the sweep asks the one question the base run cannot: when a constructor
// fails, has the frame already released what it owned at that point?
fn fallThroughWithAllocationFailures(gpa: std.mem.Allocator) !void {
    for (fall_through_paths) |path| {
        var label = try translated.guarded_fallthrough(gpa, path.selector);
        defer label.deinit(gpa);
        try std.testing.expectEqualStrings(path.bytes, label.as_str());
    }
}

fn nestedDispatchWithAllocationFailures(gpa: std.mem.Allocator) !void {
    for (nested_paths) |path| {
        var label = try translated.nested_owned_dispatch(gpa, path.selector);
        defer label.deinit(gpa);
        try std.testing.expectEqualStrings(path.bytes, label.as_str());
    }
}

test "a constructor failure releases the payload the frame already owned" {
    const gpa = std.testing.allocator;
    try fallThroughWithAllocationFailures(gpa);
    try std.testing.checkAllAllocationFailures(gpa, fallThroughWithAllocationFailures, .{});
    try nestedDispatchWithAllocationFailures(gpa);
    try std.testing.checkAllAllocationFailures(gpa, nestedDispatchWithAllocationFailures, .{});
}
