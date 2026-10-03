//! Consumer tests for the translated `iterator-chain-ownership` package.
//!
//! Built like the `test/percent_encoding_consumer.zig` invocation in
//! `test/e2e_test.zig`, with the generated package root in place of the
//! percent-encoding one. The root module imports `r2z` itself, so it needs its
//! own `--dep r2z`:
//!
//!     zig test --dep translated --dep r2z \
//!         -Mroot=test/iterator_chain_consumer.zig \
//!         --dep r2z -Mtranslated=<generated>/src/root.zig \
//!         -Mr2z=r2z-core/src/root.zig
//!
//! Every claim here is about ownership, and none of it is about emitted text.
//! Each test drives one adapter, reads the bytes that adapter's chain collected,
//! and then counts the releases. The count is the part the testing allocator
//! cannot state on its own: it reports a leak and it reports a double free, but
//! it cannot say that the frame held exactly the owners it handed over and
//! released each of them once.
//!
//! What each adapter's count means is spelled out at the fixture. In short: the
//! adapter in front never owns anything, so the allocations the frame leaves
//! outstanding are one owner per collected element plus the one slab the
//! collection grew. A count that is short is an intermediate the frame built
//! and forgot or released early; a count that is long is an intermediate it
//! materialized; a count that is right but whose elements are not distinct
//! allocations is a chain that aliased its owners onto one.

const std = @import("std");
const r2z = @import("r2z");
const translated = @import("translated");

/// An allocator that records how many times each allocation it handed out has
/// been released.
///
/// It wraps the testing allocator, so everything that allocator already proves
/// still holds: a leak and a double free are both reported by it, and a
/// `deinit` on an already-freed handle fails inside it before this file's own
/// counts are ever read. What the ledger adds is the number of allocations and
/// the number of times each was released, which is what separates "handed the
/// owner over" from "released it and handed a dangling pointer at the same
/// time".
const ReleaseLedger = struct {
    inner: std.mem.Allocator,
    /// Where the ledger's own bookkeeping lives. It is deliberately not
    /// `inner`: counting the map's growth would count the observer.
    book: std.mem.Allocator,
    /// Every allocation this ledger handed out, mapped to the number of times
    /// it has been released since. An address handed out again after a release
    /// starts over, which is a fresh allocation rather than a second owner of
    /// the first one.
    releases: std.AutoHashMapUnmanaged(usize, u32) = .empty,

    fn init() ReleaseLedger {
        return .{
            .inner = std.testing.allocator,
            .book = std.testing.allocator,
        };
    }

    fn allocator(self: *ReleaseLedger) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn deinit(self: *ReleaseLedger) void {
        self.releases.deinit(self.book);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ReleaseLedger = @ptrCast(@alignCast(ctx));
        const memory = self.inner.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.releases.put(self.book, @intFromPtr(memory), 0) catch {};
        return memory;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *ReleaseLedger = @ptrCast(@alignCast(ctx));
        // A resize keeps the address, so the count this allocation already
        // carries still describes it and nothing has to change.
        return self.inner.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *ReleaseLedger = @ptrCast(@alignCast(ctx));
        // A remap keeps the address too when the inner allocator can grow in
        // place, and a moved one is a new address the next `alloc` would not
        // describe. The count therefore follows the memory.
        const moved = self.inner.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (@intFromPtr(moved) != @intFromPtr(memory.ptr)) {
            if (self.releases.fetchRemove(self.book, @intFromPtr(memory.ptr))) |entry| {
                self.releases.put(self.book, @intFromPtr(moved), entry.value) catch {};
            }
        }
        return moved;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ReleaseLedger = @ptrCast(@alignCast(ctx));
        if (self.releases.getPtr(@intFromPtr(memory.ptr))) |count| count.* += 1;
        self.inner.rawFree(memory, alignment, ret_addr);
    }

    /// Assert that `expected` allocations came out of this ledger and that
    /// every one of them has been released exactly once.
    ///
    /// The count is the claim, not decoration. A frame that built one owner per
    /// element and released nothing is a leak the inner allocator reports; a
    /// frame that released one of them twice is a double free it reports; a
    /// frame that built one owner and materialized a second for the same
    /// element is neither, and only a count says so.
    fn expectEachReleasedExactlyOnce(self: *const ReleaseLedger, expected: usize) !void {
        try std.testing.expectEqual(expected, @as(usize, self.releases.count()));
        var entries = self.releases.iterator();
        while (entries.next()) |entry| {
            try std.testing.expectEqual(@as(u32, 1), entry.value_ptr.*);
        }
    }

    /// Assert that `expected` allocations came out of this ledger and that none
    /// of them has been released yet.
    ///
    /// This is the claim that the frame handed its owners over instead of
    /// dropping them. A release that ran on the way out would leave the caller
    /// nothing to own, and would leave the caller with a double free to find
    /// instead of a leak.
    fn expectOutstanding(self: *const ReleaseLedger, expected: usize) !void {
        try std.testing.expectEqual(expected, @as(usize, self.releases.count()));
        var entries = self.releases.iterator();
        while (entries.next()) |entry| {
            try std.testing.expectEqual(@as(u32, 0), entry.value_ptr.*);
        }
    }

    /// Assert that this ledger handed out nothing at all.
    ///
    /// The boundary the non-empty cases cannot reach: a chain that deposits no
    /// element never grows the collection's slab, and a frame that built an
    /// owner it then dropped would show up here as one.
    fn expectNothingAllocated(self: *const ReleaseLedger) !void {
        try std.testing.expectEqual(@as(usize, 0), @as(usize, self.releases.count()));
    }
};

/// The slab a `Vec<String>` of at most eight elements grows, which is one
/// allocation whatever the elements themselves number.
///
/// The list reserves in steps, so a chain this short never reallocates: the
/// counts below are the owners plus this one slab, and a count that carried a
/// second slab would be a list that grew more than once for no reason.
const collection_slab = 1;

/// The collection this fixture's chains build, named once so the tests below
/// say what they hold rather than how they spell it.
const Owners = std.ArrayListUnmanaged(r2z.alloc.String);

/// Release every element the list holds, then the slab that holds them.
///
/// The order matters and is not interchangeable. An element released after the
/// slab would write into storage the slab release already gave back, and the
/// testing allocator is what turns that into a reported failure rather than a
/// silent one.
///
/// Calling this twice is safe, and every test below does exactly that: once
/// where the ledger's count is read, and once more from the `defer` that covers
/// a failing expectation. `String.deinit` empties the handle it frees and
/// `ArrayListUnmanaged.deinit` leaves an empty list, so the second call reaches
/// nothing to free. A release that were not idempotent would make this helper
/// report a double free for a test that never made one.
fn releaseOwners(gpa: std.mem.Allocator, list: *Owners) void {
    for (list.items) |*element| element.deinit(gpa);
    list.deinit(gpa);
}

/// The bytes each element owns, in list order.
fn expectElements(expected: []const []const u8, actual: Owners) !void {
    try std.testing.expectEqual(expected.len, actual.items.len);
    for (expected, actual.items) |want, got| {
        try std.testing.expectEqualStrings(want, got.as_str());
    }
}

/// Assert that no two elements of this list name the same allocation.
///
/// Two elements holding the same text are two owners or one owner aliased
/// twice, and the text cannot tell them apart. The addresses can: a list whose
/// elements share a storage would free one allocation twice, and the frame that
/// built it either cloned what it should have moved or moved what it should
/// have cloned.
fn expectDistinctAllocations(list: Owners) !void {
    for (list.items, 0..) |first, index| {
        for (list.items[index + 1 ..]) |second| {
            try std.testing.expect(first.as_bytes().ptr != second.as_bytes().ptr);
        }
    }
}

/// Assert that this list is the owning container and not a view of storage
/// somebody else holds.
///
/// `Vec<String>` has to reach the caller as the list itself: a slice of the
/// frame's storage could not be released here at all, and the counts below
/// would then be describing bytes no caller owns. The parameter is `anytype`
/// so the check reads the type the translator actually returned rather than the
/// one this file would have coerced it to.
fn expectOwningContainer(list: anytype) !void {
    try std.testing.expect(Owners == @TypeOf(list));
}

// ── 1. `map` produces an owned value ───────────────────────────────────────

// The shape every other adapter is read against. One owner per element, the
// owner moved into the list, and the frame's own release left with nothing to
// free. Four elements is four allocations plus the slab, and each of the five
// is released exactly once — by this test, because the frame handed them over.
test "map builds one owner per element and hands every one of them over" {
    var ledger = ReleaseLedger.init();
    defer ledger.deinit();
    const gpa = ledger.allocator();

    var owners = try translated.mapped_owners(gpa, &.{ 1, 2, 3, 4 });
    defer releaseOwners(gpa, &owners);

    try expectElements(&.{ "odd", "even", "odd", "even" }, owners);
    try expectOwningContainer(owners);
    // Two elements read `odd` and two read `even`, so the text alone cannot say
    // whether the second `odd` is its own allocation or the first one's. The
    // addresses can.
    try expectDistinctAllocations(owners);
    try ledger.expectOutstanding(4 + collection_slab);

    releaseOwners(gpa, &owners);
    try ledger.expectEachReleasedExactlyOnce(4 + collection_slab);
}

// The same chain over an empty slice: nothing is built, so nothing is left
// outstanding, and the slab is never grown. A frame that released an
// intermediate here would show up as a count this boundary cannot explain.
test "a map over no elements leaves the collection owning nothing" {
    var ledger = ReleaseLedger.init();
    defer ledger.deinit();
    const gpa = ledger.allocator();

    var owners = try translated.mapped_owners(gpa, &.{});
    defer releaseOwners(gpa, &owners);

    try expectElements(&.{}, owners);
    try ledger.expectNothingAllocated();

    releaseOwners(gpa, &owners);
    try ledger.expectNothingAllocated();
}

// ── 2. `filter` drops one element ──────────────────────────────────────────

// The predicate keeps every value a modulus of three does not divide, and this
// input has exactly one it divides: the `3`. So one element is dropped and
// three survive, and the count is three owners plus the slab.
//
// What the filter drops is a `u32` the caller's slice produced — a copy — so
// the frame owes no release for it. That is the whole claim: the survivors'
// owners are the only storage the frame holds when it returns, and there are
// as many of them as the predicate kept. A filter that released what it
// dropped would either free the caller's own slice, which the testing
// allocator reports, or free one of the owners this list still holds, which it
// reports as a double free here. Neither shows up as a count.
test "filter drops the one element it rejects and the survivors reach the caller" {
    var ledger = ReleaseLedger.init();
    defer ledger.deinit();
    const gpa = ledger.allocator();

    var owners = try translated.filtered_owners(gpa, &.{ 1, 2, 3, 4 });
    defer releaseOwners(gpa, &owners);

    // The `3` is gone and the other three are not; their parity fixes which is
    // which. A predicate that read the wrong element, or a filter that dropped
    // a different one, leaves different bytes here rather than a different
    // count alone.
    try expectElements(&.{ "odd", "even", "even" }, owners);
    try expectDistinctAllocations(owners);
    try ledger.expectOutstanding(3 + collection_slab);

    releaseOwners(gpa, &owners);
    try ledger.expectEachReleasedExactlyOnce(3 + collection_slab);
}

// The boundary the non-empty case cannot reach: an input every element of which
// the predicate rejects. Nothing is built and nothing is deposited, so the
// collection never grows a slab and the frame hands back an empty list that
// owns nothing at all. A count of zero here is what says the filter dropped
// them rather than the chain never having run.
test "a filter that rejects every element leaves nothing to release" {
    var ledger = ReleaseLedger.init();
    defer ledger.deinit();
    const gpa = ledger.allocator();

    var owners = try translated.filtered_owners(gpa, &.{ 0, 3, 6 });
    defer releaseOwners(gpa, &owners);

    try expectElements(&.{}, owners);
    try ledger.expectNothingAllocated();

    releaseOwners(gpa, &owners);
    try ledger.expectNothingAllocated();
}

// ── 3. `zip` pairs two sources ─────────────────────────────────────────────

// The left side is the longer one, so this is the case that says the pair was
// taken by position: a zip that re-read the right side, or that ran past it,
// would leave a different number of elements here. The text an element carries
// records whether the left value of its position was below the right value, so
// the bytes say which two were paired as well as how many pairs there were.
test "zip pairs two sources by position and stops at the shorter one" {
    var ledger = ReleaseLedger.init();
    defer ledger.deinit();
    const gpa = ledger.allocator();

    var three_pairs = try translated.zipped_owners(gpa, &.{ 1, 2, 3, 4 }, &.{ 2, 1, 9 });
    defer releaseOwners(gpa, &three_pairs);

    // Three pairs out of four left elements: `(1,2)` ascends, `(2,1)` does
    // not, `(3,9)` does, and the fourth left element is never reached.
    try expectElements(&.{ "ascending", "descending", "ascending" }, three_pairs);
    try expectDistinctAllocations(three_pairs);
    try ledger.expectOutstanding(3 + collection_slab);

    releaseOwners(gpa, &three_pairs);
    try ledger.expectEachReleasedExactlyOnce(3 + collection_slab);
}

// The same adapter with the shorter side on the left this time. The pairing is
// by position and not by which side is longer, so the third left element pairs
// with the second right element and no element records that it had no partner.
test "zip pairs the shorter side and leaves the longer one's tail unread" {
    var ledger = ReleaseLedger.init();
    defer ledger.deinit();
    const gpa = ledger.allocator();

    var two_pairs = try translated.zipped_owners(gpa, &.{ 2, 1 }, &.{ 1, 2, 5 });
    defer releaseOwners(gpa, &two_pairs);

    // `(2,1)` descends and `(1,2)` ascends — the same two answers the previous
    // test gave for those positions, read the other way round.
    try expectElements(&.{ "descending", "ascending" }, two_pairs);
    try ledger.expectOutstanding(2 + collection_slab);

    releaseOwners(gpa, &two_pairs);
    try ledger.expectEachReleasedExactlyOnce(2 + collection_slab);
}

// ── 4. `enumerate` numbers the elements ────────────────────────────────────

// The predicate compares each value against its own position, so the text an
// element receives is a claim about the number that was paired with it. The
// input alternates aligned and shifted values, so a counter that started at
// one, never advanced, or advanced twice moves which elements read which — and
// the length says nothing about that.
test "enumerate pairs each element with its own position" {
    var ledger = ReleaseLedger.init();
    defer ledger.deinit();
    const gpa = ledger.allocator();

    var owners = try translated.numbered_owners(gpa, &.{ 0, 9, 2, 9 });
    defer releaseOwners(gpa, &owners);

    // Positions zero and two meet a value equal to themselves; positions one and
    // three meet a value that is not.
    try expectElements(
        &.{ "aligned", "shifted", "aligned", "shifted" },
        owners,
    );
    // Numbering skipped nothing: the counter ran once per element and the list
    // holds all four.
    try expectDistinctAllocations(owners);
    try ledger.expectOutstanding(4 + collection_slab);

    releaseOwners(gpa, &owners);
    try ledger.expectEachReleasedExactlyOnce(4 + collection_slab);
}

// An empty slice again, this time through the counter. A `enumerate` that
// materialized its index before asking the source for anything would leave an
// allocation behind on this path, and there is nothing else here that could.
test "an enumerate over no elements numbers nothing and allocates nothing" {
    var ledger = ReleaseLedger.init();
    defer ledger.deinit();
    const gpa = ledger.allocator();

    var owners = try translated.numbered_owners(gpa, &.{});
    defer releaseOwners(gpa, &owners);

    try expectElements(&.{}, owners);
    try ledger.expectNothingAllocated();

    releaseOwners(gpa, &owners);
    try ledger.expectNothingAllocated();
}

// ── 5. `chunks_exact` yields borrowed windows ──────────────────────────────

// The input is one byte longer than a whole number of windows, so the tail byte
// is in the caller's slice and must not appear in any window. The text an
// element receives records whether the two bytes of its window matched, which
// is a claim about the window itself: a chain that walked the wrong span,
// started a window one byte off, or yielded the tail as a fourth window leaves
// different bytes here.
//
// The window is a borrow of the caller's bytes, so the input is allocated
// through this ledger rather than declared as an array. That makes the count
// cover the storage the frame was HANDED as well as the storage it built, and
// it is what says the frame released nothing it was given: a window the chain
// treated as its own would take the caller's allocation down with it, and the
// count below would be one short.
test "chunks_exact yields whole windows and the tail stays unread" {
    var ledger = ReleaseLedger.init();
    defer ledger.deinit();
    const gpa = ledger.allocator();
    const input = try gpa.dupe(u8, &.{ 1, 1, 2, 3, 4, 4, 9 });
    defer gpa.free(input);

    var owners = try translated.window_owners(gpa, input);
    defer releaseOwners(gpa, &owners);

    // Three windows out of seven bytes: `(1,1)` matches, `(2,3)` does not,
    // `(4,4)` does, and the `9` is the tail the iterator kept back.
    try expectElements(&.{ "twin", "mixed", "twin" }, owners);
    try expectDistinctAllocations(owners);
    try ledger.expectOutstanding(3 + collection_slab + 1);

    // The other half of the borrow contract: the owners BESIDE the window are
    // separate allocations rather than views of the bytes they were read from.
    // Two elements read `twin` here, and the first of them is built from the
    // caller's first two bytes, so an owner that aliased its window would name
    // an address inside this slice.
    const window_end = input.ptr + input.len;
    for (owners.items) |element| {
        const bytes = element.as_bytes();
        try std.testing.expect(bytes.ptr < input.ptr or bytes.ptr >= window_end);
    }

    releaseOwners(gpa, &owners);
    try ledger.expectEachReleasedExactlyOnce(3 + collection_slab + 1);
}

// A source shorter than one window: `chunks_exact` yields nothing rather than
// a short window, so the collection is empty and nothing was ever borrowed.
test "a source shorter than one exact window yields nothing at all" {
    var ledger = ReleaseLedger.init();
    defer ledger.deinit();
    const gpa = ledger.allocator();

    var owners = try translated.window_owners(gpa, &.{7});
    defer releaseOwners(gpa, &owners);

    try expectElements(&.{}, owners);
    try ledger.expectNothingAllocated();

    releaseOwners(gpa, &owners);
    try ledger.expectNothingAllocated();
}

// ── 6. `collect` builds the collection ─────────────────────────────────────

// The terminal on its own, with nothing in front of it. The claim is the
// collection's own: each owner the map built is deposited once, the slab is a
// separate allocation from every element it holds, and the elements do not share
// storage with each other.
test "collect deposits each owner once into a list that owns its own slab" {
    var ledger = ReleaseLedger.init();
    defer ledger.deinit();
    const gpa = ledger.allocator();

    var owners = try translated.collected_owners(gpa, 3);
    defer releaseOwners(gpa, &owners);

    try expectElements(&.{ "start", "step", "step" }, owners);
    try expectOwningContainer(owners);
    try expectDistinctAllocations(owners);
    try ledger.expectOutstanding(3 + collection_slab);

    releaseOwners(gpa, &owners);
    try ledger.expectEachReleasedExactlyOnce(3 + collection_slab);
}

// The boundary the slice sources above cannot reach: a range that yields
// nothing. The collection is handed back empty and owns nothing, so the list's
// own release frees nothing and the ledger never saw an allocation.
test "a collect over an empty range leaves a collection that owns nothing" {
    var ledger = ReleaseLedger.init();
    defer ledger.deinit();
    const gpa = ledger.allocator();

    var owners = try translated.collected_owners(gpa, 0);
    defer releaseOwners(gpa, &owners);

    try expectElements(&.{}, owners);
    try ledger.expectNothingAllocated();

    releaseOwners(gpa, &owners);
    try ledger.expectNothingAllocated();
}
