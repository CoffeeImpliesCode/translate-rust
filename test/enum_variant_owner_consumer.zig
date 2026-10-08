//! Consumer tests for the translated `enum-variant-owner-move` package.
//!
//! The fixture declares an enum that owns a `String` in every one of its four
//! variants, dispatches it with `match`, and moves the payload out of whichever
//! arm ran. What these tests claim is narrow and exact: for each variant, the
//! payload's bytes are allocated once and released once, and the carrier that
//! held them releases nothing of its own.
//!
//! That claim is not what a leak-checking allocator can answer on its own. A
//! payload that MOVED out of its carrier is released by the caller, so a frame
//! that released it as well would still leave the test allocator balanced when
//! the test ended — one free too many, against an allocation the caller also
//! freed, and reported as no leak at all. And a release that reached an emptied
//! handle frees nothing, so the second release a wrong lowering performs is a
//! silent no-op rather than a crash. `Ledger` exists for that gap: it counts
//! every allocation by ADDRESS and every release of that address, so "exactly
//! once" is a number a test reads rather than an absence it infers.
//!
//! Nothing here reimplements the fixture's dispatch, and no test reads emitted
//! text or printed output. The variant a payload belongs to is read off the
//! carrier's own tag by `tagName`; the payload itself is read off the bytes the
//! allocator handed out.
//!
//! Built like the `test/compat_consumer.zig` invocation in `test/e2e_test.zig`,
//! with the generated package root in place of the compat one. The root module
//! imports `r2z` itself, so it needs its own `--dep r2z`:
//!
//!     zig test --dep translated --dep r2z \
//!         -Mroot=test/enum_variant_owner_consumer.zig \
//!         --dep r2z -Mtranslated=<generated>/src/root.zig \
//!         -Mr2z=r2z-core/src/root.zig

const std = @import("std");
const translated = @import("translated");

// ── what the fixture promises, spelled out here ──────────────────────────

/// One variant of the fixture's enum: the tag the carrier's own union names,
/// and the bytes the arm that selected it must hand back.
///
/// The texts are written down rather than read from the package, so a package
/// that returned the wrong arm's payload fails instead of agreeing with itself.
const Variant = struct {
    tag: []const u8,
    text: []const u8,
};

/// All four variants, in declaration order. The order is also the mode each one
/// is selected by: `build`, `dispatch` and `measure` all read the same chain.
const variants = [_]Variant{
    .{ .tag = "Text", .text = "alpha" },
    .{ .tag = "Number", .text = "bravo" },
    .{ .tag = "Flag", .text = "charlie" },
    .{ .tag = "Blank", .text = "delta" },
};

/// A mode past the end of the chain, which Rust routes to the last arm. It
/// reaches the final variant rather than one of the arms above it, so the
/// chain's own fallback is covered as well as each named arm.
const out_of_range_mode = 200;

// ── the release ledger ───────────────────────────────────────────────────

/// Every allocation the frames under test make, counted by ADDRESS.
///
/// The claim these tests make is about how many times ONE payload's bytes are
/// released, so the ledger keeps what each address was handed out for and how
/// often it has been freed since. Two outcomes are failures that the testing
/// allocator's own reporting cannot separate from correct code:
///
/// * a SECOND free of an address — the carrier releasing what an arm already
///   moved, which is the defect this fixture exists to catch;
/// * a free of an address this ledger never handed out, which is a release that
///   reached storage it does not own.
///
/// The ledger allocates nothing itself. It wraps `std.testing.allocator`, so a
/// genuine double free still panics there and a genuine leak is still reported
/// when the test ends; the ledger adds only the counts neither of those can
/// report when the second release lands on an emptied handle.
const Ledger = struct {
    /// One frame under test allocates once and frees once, and each test here
    /// starts a fresh ledger for the variant it is checking, so the deepest any
    /// of them nests is one live payload at a time. An eighth is headroom for a
    /// frame that legitimately builds more than one owned value; running past it
    /// is counted rather than ignored, so an under-count cannot pass silently.
    const capacity = 8;

    const Record = struct {
        address: usize,
        releases: u16,
    };

    child: std.mem.Allocator,
    records: [capacity]Record,
    count: usize,
    /// Allocations made with no room left to record them.
    overflows: usize,
    /// Frees of an address this ledger never handed out.
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
    /// ledger. An index rather than a pointer, so a reader that holds the
    /// ledger as a `const` can ask the same question a mutating caller can.
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
    ///
    /// A caller compares an answer's own bytes against this, so a frame that
    /// released what it built and built it again would answer with the second
    /// address rather than the first.
    fn onlyLiveAddress(self: *const Ledger) ?usize {
        if (self.liveCount() != 1) return null;
        for (self.records[0..self.count]) |record| {
            if (record.releases == 0) return record.address;
        }
        return null;
    }

    /// The only address the ledger ever handed out, released or not, or null
    /// when it saw anything else. This is how a test names the payload whose
    /// release count it is about to assert.
    fn onlyAddress(self: *const Ledger) ?usize {
        if (self.count != 1) return null;
        return self.records[0].address;
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
        // address and must not be counted as one. The allocator underneath drops
        // those itself; the ledger forwards and forgets.
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

/// The end state both release paths have to reach, whoever performed the one
/// release: the payload's bytes freed exactly once, nothing else freed, and
/// nothing left live.
fn expectPayloadReleasedExactlyOnce(ledger: *const Ledger, address: usize) !void {
    try std.testing.expectEqual(@as(usize, 0), ledger.liveCount());
    try std.testing.expectEqual(@as(u16, 1), ledger.releasesOf(address));
    try std.testing.expectEqual(@as(usize, 1), ledger.totalReleases());
    try std.testing.expectEqual(@as(usize, 0), ledger.unowned_releases);
    try std.testing.expectEqual(@as(usize, 0), ledger.overflows);
}

// ── reading the carrier ──────────────────────────────────────────────────

/// The variant `value` carries, read off its own tag.
///
/// The switch names all four variants and offers no `else`, so this is the
/// coverage claim in the strongest form the language offers: a carrier declared
/// without one of these variants would not compile here, and a carrier carrying
/// a variant the fixture never declared would not compile either. Only the tag
/// is read, never the payload, so the caller keeps the one owner of it.
fn tagName(value: translated.Payload) []const u8 {
    return switch (value) {
        .Text => "Text",
        .Number => "Number",
        .Flag => "Flag",
        .Blank => "Blank",
    };
}

// ── the tests ────────────────────────────────────────────────────────────

test "generated enum build returns each variant and its owned payload to the caller" {
    const modes = [_]u8{ 0, 1, 2, 3, out_of_range_mode };
    for (modes, 0..) |mode, index| {
        const variant = variants[@min(index, variants.len - 1)];
        var ledger = Ledger.init(std.testing.allocator);
        const gpa = ledger.allocator();

        const carrier = try translated.build(gpa, mode);
        try std.testing.expectEqualStrings(variant.tag, tagName(carrier));
        const address = ledger.onlyAddress() orelse
            return error.PayloadBytesNotRecorded;
        try std.testing.expectEqual(address, ledger.onlyLiveAddress() orelse
            return error.PayloadBytesNotHeldOnce);
        try std.testing.expectEqual(@as(usize, 0), ledger.totalReleases());

        // `build` returns the carrier, unlike `dispatch`, which constructs it
        // internally. The caller owns and releases this carrier's payload.
        switch (carrier) {
            .Text, .Number, .Flag, .Blank => |payload| {
                var owned = payload;
                try std.testing.expectEqualStrings(variant.text, owned.as_str());
                try std.testing.expectEqual(address, @intFromPtr(owned.as_bytes().ptr));
                owned.deinit(gpa);
            },
        }
        try expectPayloadReleasedExactlyOnce(&ledger, address);
    }
}

test "generated enum variants move their payload out to the caller exactly once" {
    // Each variant gets its own ledger, so "exactly once" is a per-variant
    // claim rather than a running total that a second release could hide
    // behind a first.
    for (variants, 0..) |variant, mode| {
        var ledger = Ledger.init(std.testing.allocator);
        const gpa = ledger.allocator();

        // `dispatch` constructs the carrier internally and moves its payload
        // out. The ledger observes that construction without creating a second,
        // unrelated carrier in the caller.
        var moved = try translated.dispatch(gpa, @intCast(mode));
        const address = ledger.onlyAddress() orelse
            return error.PayloadBytesNotRecorded;
        try std.testing.expectEqual(address, ledger.onlyLiveAddress() orelse
            return error.PayloadBytesNotHeldOnce);

        // Before the caller releases anything, the moved payload remains live
        // and the dispatch frame must not have released it.
        try std.testing.expectEqualStrings(variant.text, moved.as_str());
        try std.testing.expectEqual(@as(usize, 0), ledger.totalReleases());
        try std.testing.expectEqual(@as(usize, 1), ledger.liveCount());
        // The bytes that came back are the bytes that were allocated. A copy
        // would have allocated a second buffer and left this one unreleased.
        try std.testing.expectEqual(address, @intFromPtr(moved.as_bytes().ptr));

        moved.deinit(gpa);
        try expectPayloadReleasedExactlyOnce(&ledger, address);
    }
}

test "generated enum variants release a payload an arm only read, once and in frame" {
    for (variants, 0..) |variant, mode| {
        var ledger = Ledger.init(std.testing.allocator);
        const gpa = ledger.allocator();

        // `measure` builds the carrier, reads the payload through the arm it
        // selected, and answers a length. The answer owns nothing, so the only
        // owner of the payload is the frame — and the frame is the only place a
        // release of it can come from.
        const measured = try translated.measure(gpa, @intCast(mode));
        try std.testing.expectEqual(variant.text.len, measured);

        try std.testing.expectEqual(@as(usize, 1), ledger.totalReleases());
        const address = ledger.onlyAddress() orelse
            return error.PayloadBytesNotRecorded;
        try expectPayloadReleasedExactlyOnce(&ledger, address);
    }
}

test "generated enum carriers route an unlisted mode to the chain's last variant" {
    // Rust sends a mode past the end of the chain to its final arm, so the
    // fallback is a variant like any other and carries the same claim.
    var ledger = Ledger.init(std.testing.allocator);
    const gpa = ledger.allocator();

    var moved = try translated.dispatch(gpa, out_of_range_mode);
    const address = ledger.onlyAddress() orelse
        return error.PayloadBytesNotRecorded;
    try std.testing.expectEqual(address, ledger.onlyLiveAddress() orelse
        return error.PayloadBytesNotHeldOnce);
    try std.testing.expectEqualStrings(variants[variants.len - 1].text, moved.as_str());
    try std.testing.expectEqual(@as(usize, 0), ledger.totalReleases());
    try std.testing.expectEqual(address, @intFromPtr(moved.as_bytes().ptr));

    moved.deinit(gpa);
    try expectPayloadReleasedExactlyOnce(&ledger, address);
}

// Every frame below builds an owned payload and hands it on, so the failures
// its constructors can report are the ones this sweep exists for: whatever a
// frame already owns has to be released when the next allocation fails, or the
// sweep reports a leak rather than a bug in the frame. The build here is the
// first allocation the body makes, so the frames that would have to release on
// the way out are exactly the ones under test.
fn movedPayloadWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var moved = try translated.dispatch(gpa, 0);
    defer moved.deinit(gpa);
    try std.testing.expectEqualStrings("alpha", moved.as_str());
}

test "generated enum dispatch releases a payload it could not build in full" {
    try movedPayloadWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        movedPayloadWithAllocationFailures,
        .{},
    );
}
