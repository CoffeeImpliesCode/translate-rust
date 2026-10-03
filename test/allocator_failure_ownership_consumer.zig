//! Ownership-exit tests for the translated `allocator-failure-ownership`
//! package.
//!
//! The fixture in `test/crates/allocator-failure-ownership/src/lib.rs` leaves a
//! live owner's scope through `return`, `break`, `continue`, `?`, and a plain
//! allocation failure. Rust releases those bindings on whichever route ended
//! the scope, so every one of those routes has to reach the same release in the
//! frame the translator emits.
//!
//! Each test here does two separate runs of its path:
//!
//!   1. A NORMAL run, with `std.testing.allocator`, that builds the fixture
//!      input and reads the values back. This is where the expected bytes come
//!      from.
//!   2. A FAILING run, repeated once per injected allocation failure, that
//!      installs the failing allocator over `std.testing.allocator` and checks
//!      the frame's own books after every run.
//!
//! The two runs are separate on purpose. A fixture built with the very
//! allocator that then fails would fail while the fixture was being built, so
//! the exit under test would never run and the sweep would prove nothing. Every
//! input here is built with `std.testing.allocator` — a different allocator from
//! the one that is made to fail — and is released with that same allocator, so
//! the translated frame only ever sees a borrowed view of it.
//!
//! Built like the `test/percent_encoding_consumer.zig` invocation in
//! `test/e2e_test.zig`, with this package's generated root in place of the
//! percent-encoding one. The root module imports `r2z` itself, so it needs its
//! own `--dep r2z`:
//!
//!     zig test --dep translated --dep r2z \
//!         -Mroot=test/allocator_failure_ownership_consumer.zig \
//!         --dep r2z -Mtranslated=<generated>/src/root.zig \
//!         -Mr2z=r2z-core/src/root.zig

const std = @import("std");
const r2z = @import("r2z");
const translated = @import("translated");

/// The owned input every path below borrows from.
///
/// Built by the normal allocator, never by the one the sweep makes fail: an
/// input built from the injected allocator would fail during construction and
/// the exit under test would never run.
fn ownedFixture(text: []const u8) !r2z.alloc.String {
    return try r2z.alloc.String.from_str(std.testing.allocator, text);
}

/// Run `path` once per injected allocation failure and check its books.
///
/// This is the sweep `std.testing.checkAllAllocationFailures` performs, with
/// the two halves of the contract asserted separately: the run must let the
/// induced error leave rather than carry on with half-built storage, and the
/// bytes the path allocated must be exactly the bytes it released. That
/// equality catches both defects at once — a release that never ran leaves the
/// released total short, and a release that ran twice leaves it over — and
/// `expectEqual` prints both totals, so the direction says which one it was.
///
/// The deallocation COUNT is deliberately not asserted. A `deinit` on a
/// container that owns nothing still reaches the allocator with a zero-length
/// slice, and the emptied handle a hand-on leaves behind is exactly that case.
/// Those no-op releases move no bytes, so they leave the balance exact while
/// making the counts differ by one per emptied owner.
///
/// A growth reallocation is not in this sweep either. `ensureTotalCapacity`
/// tries `remap` first and falls back to a fresh allocation when that fails,
/// so a refused resize costs one extra allocation and one extra release rather
/// than an error: it cannot make the frame fail, and there is nothing to leak.
fn expectReleasesEveryAllocation(comptime path: anytype) !void {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try @call(.auto, path, .{counting.allocator()});

    for (0..counting.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        try std.testing.expectError(
            error.OutOfMemory,
            @call(.auto, path, .{failing.allocator()}),
        );
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

/// The `return` exit.
///
/// `carried` is live when the early return runs, and `marked` only exists on
/// the fall-through. Both lengths are exact: the stopped run reports the
/// error the source returns, and the fall-through reports the sum of the two
/// owners it released.
fn returnExit(gpa: std.mem.Allocator) !void {
    var held = try ownedFixture("carried");
    defer held.deinit(std.testing.allocator);

    const stopped = try translated.return_exit(gpa, held.as_str(), true);
    try std.testing.expect(stopped == .Err);
    try std.testing.expectEqual(@as(u8, 1), stopped.Err);

    const fell_through = try translated.return_exit(gpa, held.as_str(), false);
    try std.testing.expect(fell_through == .Ok);
    // "carried" is 7 bytes and "marked!" is 7 more.
    try std.testing.expectEqual(@as(usize, 14), fell_through.Ok);
}

/// The `break` exit.
///
/// `marks` lives in the loop body, so the `break` and the iteration that ends
/// on the condition release it by different routes. `shadow` lives in the
/// frame, so one release covers both. `carried` is handed on as the tail, so
/// the frame's own release must find nothing there — and a release that found
/// something would free storage this test is about to read. The trailing `.`
/// counts the rounds that ran.
fn breakExit(gpa: std.mem.Allocator) !void {
    var held = try ownedFixture("carried");
    defer held.deinit(std.testing.allocator);

    var broken = try translated.break_exit(gpa, held.as_str(), 4, 1);
    defer broken.deinit(gpa);
    try std.testing.expectEqualStrings("carried.", broken.as_str());

    var drained = try translated.break_exit(gpa, held.as_str(), 4, 9);
    defer drained.deinit(gpa);
    try std.testing.expectEqualStrings("carried....", drained.as_str());

    var untouched = try translated.break_exit(gpa, held.as_str(), 0, 9);
    defer untouched.deinit(gpa);
    try std.testing.expectEqualStrings("carried", untouched.as_str());
}

/// The `continue` exit.
///
/// The last case is the one that separates `continue` from the loop's own
/// condition: the body runs once, leaves through `continue`, and the loop then
/// ends having accumulated nothing at all.
fn continueExit(gpa: std.mem.Allocator) !void {
    var held = try ownedFixture("carried");
    defer held.deinit(std.testing.allocator);

    var skipped = try translated.continue_exit(gpa, held.as_str(), 4, true);
    defer skipped.deinit(gpa);
    try std.testing.expectEqualStrings("carried...", skipped.as_str());

    var every_round = try translated.continue_exit(gpa, held.as_str(), 4, false);
    defer every_round.deinit(gpa);
    try std.testing.expectEqualStrings("carried....", every_round.as_str());

    var only_the_skip = try translated.continue_exit(gpa, held.as_str(), 1, true);
    defer only_the_skip.deinit(gpa);
    try std.testing.expectEqualStrings("carried", only_the_skip.as_str());
}

/// The `?` exit.
///
/// The rejecting run reaches the propagation with `carried` and `marked` live
/// and `step` never built, so those two releases are the only thing standing
/// between the propagation and a leak. The accepting run adds `step` and
/// reports the sum of all three lengths.
fn questionExit(gpa: std.mem.Allocator) !void {
    var held = try ownedFixture("carried");
    defer held.deinit(std.testing.allocator);

    const rejected = try translated.question_exit(gpa, held.as_str(), false);
    try std.testing.expect(rejected == .Err);
    try std.testing.expectEqual(@as(u8, 9), rejected.Err);

    const accepted = try translated.question_exit(gpa, held.as_str(), true);
    try std.testing.expect(accepted == .Ok);
    // 7 bytes held, 7 marked, 4 in the step the `?` handed over.
    try std.testing.expectEqual(@as(usize, 18), accepted.Ok);
}

/// The mid-scope allocation failure.
///
/// No exit of its own: every allocation past the first fails with `carried`
/// already live, so the frame has to unwind through the ordinary error return
/// and still release what its scope held.
fn growExit(gpa: std.mem.Allocator) !void {
    var held = try ownedFixture("carried");
    defer held.deinit(std.testing.allocator);

    // 7 bytes held, 7 marked, and four marks after three pushes.
    try std.testing.expectEqual(
        @as(usize, 18),
        try translated.grow_exit(gpa, held.as_str()),
    );
}

test "the return exit releases the owner the early return skips past" {
    try returnExit(std.testing.allocator);
    try expectReleasesEveryAllocation(returnExit);
}

test "the break exit releases the owners the loop body declared" {
    try breakExit(std.testing.allocator);
    try expectReleasesEveryAllocation(breakExit);
}

test "the continue exit releases the owners the loop body declared" {
    try continueExit(std.testing.allocator);
    try expectReleasesEveryAllocation(continueExit);
}

test "the question mark exit releases the owners that outlived the propagation" {
    try questionExit(std.testing.allocator);
    try expectReleasesEveryAllocation(questionExit);
}

test "an allocation failure inside the scope releases what the scope held" {
    try growExit(std.testing.allocator);
    try expectReleasesEveryAllocation(growExit);
}
