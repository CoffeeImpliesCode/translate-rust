//! Consumer tests for the translated `overwritten-owner` package.
//!
//! `test/crates/overwritten-owner/src/lib.rs` is a fixture about one thing: an
//! owner a place ALREADY holds being replaced. Every entry point there
//! overwrites a live owner, so the frame owes exactly one release of what the
//! place held — after the replacement exists, and before the replacement lands
//! in it — and the value that lands is what the caller reaches.
//!
//! Bytes alone cannot say any of that, so this file counts. `Counter` is an
//! allocator that forwards every request to `std.testing.allocator` and keeps
//! how many blocks were built, how many were released, how many are live and
//! how many bytes those hold, so every claim below is a number the generated
//! package produced rather than a sentence about it:
//!
//!   * every owner a frame built is either released inside it or is the one the
//!     caller now holds — `built`, `released` and `blocks` together say which,
//!     and a frame that leaked a discarded value leaves a block live that the
//!     caller's own release cannot account for;
//!   * a frame that released one twice reaches `std.testing.allocator` as a
//!     double free, which is a failure in its own right;
//!   * a frame that kept a second reference to the survivor, or copied the
//!     survivor instead of moving it, leaves live bytes that are not the
//!     survivor's own capacity;
//!   * a loop that accumulated one owner per round leaves one live block per
//!     round instead of one.
//!
//! Nothing here reimplements a fixture function or states what the emitted
//! source looks like; every expectation is about the value the package returns
//! and about who owns it afterwards.
//!
//! Built like the `test/compat_consumer.zig` invocation in `test/e2e_test.zig`,
//! with the generated package root in place of the compat one. The root module
//! imports `r2z` itself, so it needs its own `--dep r2z`:
//!
//!     zig test --dep translated --dep r2z \
//!         -Mroot=test/overwritten_owner_consumer.zig \
//!         --dep r2z -Mtranslated=<generated>/src/root.zig \
//!         -Mr2z=r2z-core/src/root.zig

const std = @import("std");
const r2z = @import("r2z");
const translated = @import("translated");

/// The owner an overwrite hands the caller. Naming the type is what makes a
/// changed return type a compile error here rather than a silent success in
/// every test below.
const Survivor = r2z.alloc.String;

/// An allocator that counts what the generated package built and released
/// through it.
///
/// It forwards to `std.testing.allocator`, so a double free and a leak remain
/// the failures that allocator reports. What the tally adds is the count those
/// two verdicts cannot state: a frame that leaked and a frame that released too
/// much can both leave the testing allocator with nothing outstanding, and the
/// difference between them is the whole claim here.
///
/// Blocks and bytes are counted separately because `resize` and `remap` change
/// a live block without making or releasing one, and because a release is
/// handed the length the block currently has — so the two counts cancel without
/// a table of live blocks.
const Counter = struct {
    child: std.mem.Allocator,
    /// Blocks handed out and not yet given back.
    blocks: usize = 0,
    /// Blocks this allocator handed out. A `resize` or `remap` is not one: it
    /// changes a block that already exists and is already counted.
    built: usize = 0,
    /// Blocks given back through `free`. Releasing an owner a move already
    /// emptied is not one: `Allocator.free` returns before its vtable for a
    /// zero-length slice.
    released: usize = 0,
    /// Bytes held by the live blocks.
    bytes: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const memory = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.blocks += 1;
        self.built += 1;
        self.bytes += len;
        return memory;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.resizeBytes(memory.len, new_len);
        return true;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const moved = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.resizeBytes(memory.len, new_len);
        return moved;
    }

    fn free(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        // Forwarded FIRST, so a release of storage this allocator never handed
        // out is reported by `std.testing.allocator`, which names both sides of
        // it, rather than by the bookkeeping below disagreeing first.
        self.child.rawFree(memory, alignment, ret_addr);
        // Both subtractions are checked. A release larger than everything this
        // allocator believes it holds is a release of something it never handed
        // out, and saying so is what a test failure on it should read as — an
        // unchecked `usize` subtraction would report an integer overflow and
        // name neither the block nor the count.
        if (self.blocks == 0 or memory.len > self.bytes) {
            std.debug.panic(
                "overwritten_owner_consumer: released {d} bytes with {d} live blocks and {d} live bytes",
                .{ memory.len, self.blocks, self.bytes },
            );
        }
        self.blocks -= 1;
        self.released += 1;
        self.bytes -= memory.len;
    }

    fn resizeBytes(self: *@This(), old_len: usize, new_len: usize) void {
        if (new_len >= old_len) {
            self.bytes += new_len - old_len;
        } else {
            self.bytes -= old_len - new_len;
        }
    }
};

/// Every owner the frame built has been accounted for: each was either
/// released inside the frame or is the survivor the caller holds, and the
/// survivor's own slab is the only live storage.
///
/// `survivor` is read for its capacity, so a caller that passes a value it has
/// already released cannot make these pass.
fn expectOneOwnerLive(
    counter: *const Counter,
    survivor: *const Survivor,
    built: usize,
    released: usize,
) !void {
    try std.testing.expectEqual(built, counter.built);
    try std.testing.expectEqual(released, counter.released);
    try std.testing.expectEqual(@as(usize, 1), counter.blocks);
    try std.testing.expectEqual(survivor.capacity(), counter.bytes);
}

test "an overwritten local owner releases the value the place held exactly once" {
    var counter: Counter = .{ .child = std.testing.allocator };
    const gpa = counter.allocator();

    // Two owners are built here and one crosses the boundary: the frame
    // allocated `"first"`, allocated `"second"` in its place, and released
    // `"first"` on the way. A release that ran BEFORE the replacement was built
    // would free bytes the replacement was built out of; one that never ran
    // would leave the discarded value live, which is a second live block here
    // and a leak the testing allocator reports once the survivor is released.
    var survivor: Survivor = try translated.overwrite_local(gpa);
    try std.testing.expectEqualStrings("second", survivor.as_str());
    try expectOneOwnerLive(&counter, &survivor, 2, 1);

    // The caller owns the survivor exactly once; a frame that had released it
    // on the way out would make this a double free.
    survivor.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), counter.released);
    try std.testing.expectEqual(@as(usize, 0), counter.blocks);
    try std.testing.expectEqual(@as(usize, 0), counter.bytes);
}

test "a shadowing binding of the same name releases the inner owner, not the outer one" {
    var counter: Counter = .{ .child = std.testing.allocator };
    const gpa = counter.allocator();

    // Three owners are built and two are released inside the frame: the
    // `"inner"` the shadowed `text` held before its own assignment replaced it,
    // and the `"inner-second!"` the block's end released. What the caller
    // receives is the OUTER `text`, which was live at the same time under the
    // same source name — so a release keyed by that name instead of by the
    // binding frees exactly the bytes this call still returns, and shows up as
    // a double free on the `deinit` below.
    var survivor: Survivor = try translated.overwrite_shadowed(gpa);
    try std.testing.expectEqualStrings("outer", survivor.as_str());
    try expectOneOwnerLive(&counter, &survivor, 3, 2);

    survivor.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), counter.released);
    try std.testing.expectEqual(@as(usize, 0), counter.blocks);
    try std.testing.expectEqual(@as(usize, 0), counter.bytes);
}

test "an owner overwritten once per loop round keeps one owner live, not one per round" {
    var counter: Counter = .{ .child = std.testing.allocator };
    const gpa = counter.allocator();

    // Five rounds build `"seed"` and then five `"round"` owners, and every round
    // released the owner the round before installed. ONE block is live however
    // many rounds ran, and it holds the value the LAST round installed — a loop
    // that accumulated leaves five live blocks, and a loop that released after
    // moving the replacement in leaves one block too few released and frees the
    // survivor a second time on the `deinit` below.
    var survivor: Survivor = try translated.overwrite_loop(gpa, 5);
    try std.testing.expectEqualStrings("round", survivor.as_str());
    try expectOneOwnerLive(&counter, &survivor, 6, 5);

    survivor.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 6), counter.released);
    try std.testing.expectEqual(@as(usize, 0), counter.blocks);
    try std.testing.expectEqual(@as(usize, 0), counter.bytes);
}

test "a loop that runs no round overwrites nothing and releases nothing" {
    var counter: Counter = .{ .child = std.testing.allocator };
    const gpa = counter.allocator();

    // The zero-round case is the other end of the same contract. With no
    // assignment there is nothing to release inside the frame, so the seed
    // reaches the caller whole — and a frame that released it here would free
    // the bytes this call still returns, which is a double free on the `deinit`
    // below rather than a wrong count.
    var survivor: Survivor = try translated.overwrite_loop(gpa, 0);
    try std.testing.expectEqualStrings("seed", survivor.as_str());
    try expectOneOwnerLive(&counter, &survivor, 1, 0);

    survivor.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), counter.released);
    try std.testing.expectEqual(@as(usize, 0), counter.blocks);
    try std.testing.expectEqual(@as(usize, 0), counter.bytes);
}

/// Every entry point, through every round count the loop is reachable at, with
/// each survivor read back and released exactly once.
///
/// The COUNT assertions the tests above pin are deliberately absent here: an
/// induced failure changes how far a frame gets, and a count from a run that did
/// not finish is not a count of the translator. The VALUE assertions are not
/// absent, and they are what this function is for: `checkAllAllocationFailures`
/// below is the only thing here that can reach the frame's own release when the
/// REPLACEMENT cannot be built — a path none of the counts above can see,
/// because they only ever observe allocations that succeeded. A frame that
/// returned the value the place still held on that path fails on the read-back.
fn overwrittenOwnersWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var local: Survivor = try translated.overwrite_local(gpa);
    try std.testing.expectEqualStrings("second", local.as_str());
    local.deinit(gpa);

    var shadowed: Survivor = try translated.overwrite_shadowed(gpa);
    try std.testing.expectEqualStrings("outer", shadowed.as_str());
    shadowed.deinit(gpa);

    const rounds = [_]u8{ 0, 1, 2, 3, 5 };
    const expected = [_][]const u8{ "seed", "round", "round", "round", "round" };
    for (rounds, expected) |count, want| {
        var looped: Survivor = try translated.overwrite_loop(gpa, count);
        try std.testing.expectEqualStrings(want, looped.as_str());
        looped.deinit(gpa);
    }
}

test "an overwrite that cannot build its replacement still releases what the place held" {
    try overwrittenOwnersWithAllocationFailures(std.testing.allocator);
    // In every overwrite here the first allocation is the owner already in the
    // place and the second is the replacement. Failing the second has to leave
    // the first released by the frame's own scope release: an overwrite that
    // released the discarded owner only once the replacement was in place would
    // leak it on exactly this path, and no allocation that SUCCEEDED can see
    // that.
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        overwrittenOwnersWithAllocationFailures,
        .{},
    );
}
