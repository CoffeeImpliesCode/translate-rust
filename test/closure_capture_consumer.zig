//! Consumer tests for the translated `closure-capture-ownership` package.
//!
//! Built like the `test/percent_encoding_consumer.zig` invocation in
//! `test/e2e_test.zig`, with the generated package root in place of the
//! percent-encoding one. The root module imports `r2z` itself, so it needs its
//! own `--dep r2z`:
//!
//!     zig test --dep translated --dep r2z \
//!         -Mroot=test/closure_capture_consumer.zig \
//!         --dep r2z -Mtranslated=<generated>/src/root.zig \
//!         -Mr2z=r2z-core/src/root.zig
//!
//! Every claim here is about ownership and none of it is about emitted text. A
//! frame that leaks a captured value, releases one twice, or hands back a value
//! its capture already released is caught by the allocator the frame was given,
//! and `ReleaseLedger` states the count the capture contract is about: each
//! allocation the frame made, released exactly once.

const std = @import("std");
const r2z = @import("r2z");
const translated = @import("translated");

/// An allocator that records how many times each allocation it handed out has
/// been released.
///
/// It wraps the testing allocator, so everything that allocator already proves
/// still holds: a leak and a double free are both reported by it. The ledger
/// adds the one thing it cannot state — how many times — which is what tells a
/// released-once capture apart from one that was released twice and survived by
/// luck.
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
        return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ReleaseLedger = @ptrCast(@alignCast(ctx));
        if (self.releases.getPtr(@intFromPtr(memory))) |count| count.* += 1;
        self.inner.rawFree(memory, alignment, ret_addr);
    }

    /// Assert that `expected` allocations came out of this ledger and that
    /// every one of them has been released exactly once.
    ///
    /// The count is part of the claim, not decoration. A frame that built one
    /// `String` and released nothing is a leak; a frame that built one and
    /// released it twice is a double free; a frame whose two captures only ever
    /// shared one allocation is not the frame under test at all. Each leaves a
    /// number that is not one per allocation, and an "nothing is outstanding"
    /// check would accept all three.
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
    /// This is the claim that a capture emptied itself on the way out. The
    /// value a frame hands back is the same allocation its capture held, so a
    /// release that ran on the way out would leave the caller nothing to own —
    /// and would leave the caller with a double free to find instead.
    fn expectOutstanding(self: *const ReleaseLedger, expected: usize) !void {
        try std.testing.expectEqual(expected, @as(usize, self.releases.count()));
        var entries = self.releases.iterator();
        while (entries.next()) |entry| {
            try std.testing.expectEqual(@as(u32, 0), entry.value_ptr.*);
        }
    }
};

// `move` closure, one capture, two calls. `String::from("hello")` allocates
// once and the frame adds no allocation of its own, so the single release this
// ledger records has to be that one allocation. A release for the frame binding
// the capture was taken from would make it two; a capture that never reached
// its own release would leave it at zero.
test "a by-move capture read through two calls is released exactly once" {
    var ledger = ReleaseLedger.init();
    defer ledger.deinit();
    const gpa = ledger.allocator();

    try std.testing.expectEqual(
        @as(usize, 17),
        try translated.move_capture_len_twice(gpa, "hello", 3),
    );
    try ledger.expectEachReleasedExactlyOnce(1);
}

// The closure gives the capture back, so the value the caller receives is the
// one allocation the frame built and nothing else has claimed it. It is
// unclaimed, not freed: the capture's release has to have found an empty handle,
// and the caller's own release is the only release the ledger may record.
test "a by-move capture handed out of the closure reaches its caller unclaimed" {
    var ledger = ReleaseLedger.init();
    defer ledger.deinit();
    const gpa = ledger.allocator();

    var handed = try translated.move_capture_handover(gpa, "handed over", 0);
    // `String.deinit` empties the handle it frees, so this trailing release
    // finds nothing once the explicit one below has run.
    defer handed.deinit(gpa);

    try ledger.expectOutstanding(1);
    try std.testing.expectEqualStrings("handed over", handed.as_str());
    // The return type is the runtime owner itself, not a view of the frame's
    // storage: a view could not be released here at all, and the ledger count
    // below would then be describing storage nobody ever owned.
    try std.testing.expect(r2z.alloc.String == @TypeOf(handed));

    handed.deinit(gpa);
    try ledger.expectEachReleasedExactlyOnce(1);
}

// No `move` keyword, and the capture is still by value: the closure body moves
// it out through a method that takes `self`. The bytes the caller receives are
// the bytes the frame allocated, and the capture the lowering introduced in
// between has to be empty by the time they leave it.
test "a capture the closure body moves out of is released once by its caller" {
    var ledger = ReleaseLedger.init();
    defer ledger.deinit();
    const gpa = ledger.allocator();

    var bytes = try translated.consumed_capture_into_bytes(gpa, "moved bytes", 0);
    defer bytes.deinit(gpa);

    try ledger.expectOutstanding(1);
    try std.testing.expectEqualStrings("moved bytes", bytes.items);
    // `Vec<u8>` reaches the caller as the owning list, not as a slice of the
    // capture's bytes, for the same reason the handover returns the owner.
    try std.testing.expect(std.ArrayListUnmanaged(u8) == @TypeOf(bytes));

    bytes.deinit(gpa);
    try ledger.expectEachReleasedExactlyOnce(1);
}

// Two captures, two frame bindings, four owners that the two allocations passed
// through, and still two releases. Any one of them releasing twice, or one
// capture releasing the other's storage, shows up here as a count that is not
// one per allocation.
test "two captures in one frame are each released exactly once" {
    var ledger = ReleaseLedger.init();
    defer ledger.deinit();
    const gpa = ledger.allocator();

    try std.testing.expectEqual(
        @as(usize, 14),
        try translated.two_owned_captures(gpa, "capture", "release"),
    );
    try ledger.expectEachReleasedExactlyOnce(2);
}

fn twoOwnedCapturesWithAllocationFailures(gpa: std.mem.Allocator) !void {
    try std.testing.expectEqual(
        @as(usize, 14),
        try translated.two_owned_captures(gpa, "capture", "release"),
    );
}

// The second capture is created while the first is already captured and already
// armed, so the allocation it needs can fail with the first still holding
// storage. The sweep makes each allocation in turn the failing one; a frame
// that kept a capture across the failure reports it as a leak.
test "a capture is released when the next capture cannot be built" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        twoOwnedCapturesWithAllocationFailures,
        .{},
    );
}
