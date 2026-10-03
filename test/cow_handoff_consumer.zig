//! Consumer tests for the translated `cow-handoff` package.
//!
//! `test/crates/cow-handoff/src/lib.rs` binds an owner in a `let` and returns
//! that binding. Rust moves it, so between the frame that built the value and
//! the caller that received it there is exactly one owner, and every question
//! this file asks is about which owner that is and how many times its bytes are
//! released.
//!
//! Four claims, each stated against storage this file owns:
//!
//!  1. A `Cow` that BORROWED keeps the caller's exact bytes and does not own
//!     them. The pointer identity is asserted, and the caller's own buffer is
//!     still readable after the cow's release — a borrowed arm that freed what
//!     it named would show up as a double free on the caller's own release.
//!  2. A `Cow` that OWNED survives the local move. Its slab is a different
//!     allocation from the caller's input, and it can still be grown after the
//!     frame is gone, which is what says the value that arrived owns what it
//!     names rather than pointing into storage the frame released.
//!  3. The `FromUtf8Error` hand-off releases the error's bytes exactly once. The
//!     error still holds the bytes the caller handed in, so the payload crossed
//!     rather than being rebuilt, and the counting allocator says one allocation
//!     was released once and not twice.
//!  4. A failing allocator leaks nothing, on every path that allocates.
//!
//! `Cow<str>` and `Cow<[u8]>` are covered separately throughout, because they
//! reach the two arms by different means and a lowering that only holds for one
//! of them is only half checked by either.
//!
//! Nothing here reimplements the fixture. Every value compared is read out of
//! the package's own return value or out of storage this file built before the
//! call, and every count is a count of releases the package actually performed.
//!
//! ## The two runs
//!
//! A NORMAL run builds the fixture input with `std.testing.allocator` and reads
//! the values back; that is where the expected bytes come from. A FAILING run,
//! repeated once per injected allocation failure, installs the failing
//! allocator over `std.testing.allocator` and checks the frame's books after
//! every run.
//!
//! The two runs are separate on purpose. An input built from the very allocator
//! that then fails would fail during construction, so the hand-off under test
//! would never run and the sweep would prove nothing. Every input here is built
//! with `std.testing.allocator` — a different allocator from the one made to
//! fail — and released with that same allocator, so the translated frame only
//! ever sees a borrowed view of it.
//!
//! The borrowed arms of both cows allocate nothing in the frame under test: a
//! borrow allocates no storage and `String::from_utf8_lossy` returns one for
//! valid UTF-8 without copying. There is no failure to inject on those routes, so
//! no sweep is run over them and the claims they carry are the pointer identity
//! and the readable-after-release assertions instead.
//!
//! ## Reading the counts
//!
//! `std.testing.FailingAllocator` wraps the leak-checking test allocator, so
//! `allocations` and `deallocations` count the real calls while a leak or a
//! double free is still reported by the runner underneath. "Exactly once" is
//! therefore stated as an equality of the two counts rather than inferred from
//! the bytes still reading back: a value whose bytes are correct can have been
//! freed twice already.
//!
//! ## Invocation
//!
//! Built like the `test/percent_encoding_consumer.zig` invocation in
//! `test/e2e_test.zig`, with this package's generated root in place of the
//! percent-encoding one. The root module imports `r2z` itself, so it needs its
//! own `--dep r2z`:
//!
//!     zig test --dep translated --dep r2z \
//!         -Mroot=test/cow_handoff_consumer.zig \
//!         --dep r2z -Mtranslated=<generated>/src/root.zig \
//!         -Mr2z=r2z-core/src/root.zig

const std = @import("std");
const r2z = @import("r2z");
const translated = @import("translated");

/// The owned input the `Cow` entry points borrow from.
///
/// Built by the normal allocator, never by the one a sweep makes fail: an input
/// built from the injected allocator would fail during construction and the
/// hand-off under test would never run.
///
/// These entry points take `&[u8]`, and one of the inputs below is
/// deliberately NOT valid UTF-8, so the storage is a plain byte buffer. A
/// `String` cannot hold that input: it validates what it is given and would
/// refuse to be built at all.
fn ownedBytes(bytes: []const u8) ![]u8 {
    return try std.testing.allocator.dupe(u8, bytes);
}

/// The owned TEXT input the error hand-off beside a string borrows from.
///
/// This one really is text — the fixture takes it as `&str` — so it is a
/// `String`, and it is released by the allocator that built it.
fn ownedFixture(text: []const u8) !r2z.alloc.String {
    return try r2z.alloc.String.from_str(std.testing.allocator, text);
}

// ── 1. a borrowed cow keeps the caller's bytes and frees nothing ───────────

// The borrowed arm of `Cow<str>`.
//
// `String::from_utf8_lossy` borrows valid UTF-8, so the value the package hands
// back has to name `held`'s own bytes. A copy would read back the same string
// and fail nothing, which is why the pointer identity is asserted and why the
// caller's buffer is read again after the cow's release: a borrowed arm that
// freed what it named would make the `defer` below a double free.
test "a borrowed cow of str keeps the caller's bytes and frees nothing" {
    const gpa = std.testing.allocator;
    const held = try ownedBytes("borrowed text");
    defer std.testing.allocator.free(held);

    var cow = try translated.text_cow_local(gpa, held);
    defer cow.deinit(gpa);

    try std.testing.expect(cow == .Borrowed);
    try std.testing.expectEqualStrings("borrowed text", cow.as_ref());
    try std.testing.expectEqual(@intFromPtr(held.ptr), @intFromPtr(cow.as_ref().ptr));

    // Explicit release before the read below, so the claim is about a released
    // cow rather than one still in scope. The release is idempotent, so the
    // `defer` that follows finds nothing to free.
    cow.deinit(gpa);
    try std.testing.expectEqualStrings("borrowed text", held);
}

// The borrowed arm of `Cow<[u8]>`, on the terms the text arm states.
//
// Three bytes is the length `byte_cow_local` keeps the caller's, so the arm is
// chosen by the fixture and not by what the bytes happen to spell.
test "a borrowed cow of bytes keeps the caller's bytes and frees nothing" {
    const gpa = std.testing.allocator;
    const held = try ownedBytes("abc");
    defer std.testing.allocator.free(held);

    var cow = try translated.byte_cow_local(gpa, held);
    defer cow.deinit(gpa);

    try std.testing.expect(cow == .Borrowed);
    try std.testing.expectEqualSlices(u8, held, cow.as_ref());
    try std.testing.expectEqual(@intFromPtr(held.ptr), @intFromPtr(cow.as_ref().ptr));

    cow.deinit(gpa);
    try std.testing.expectEqualStrings("abc", held);
}

// ── 2. an owned cow survives the move out of the frame that built it ───────

/// The owned arm of `Cow<str>`.
///
/// `a\xffb` is not valid UTF-8, so `String::from_utf8_lossy` repairs it and the
/// value owns the repair. The slab is a different allocation from the caller's
/// input — a move that had aliased it would name storage the frame released —
/// and it can still be grown after the frame is gone, which is what says the
/// value that arrived is the owner of what it names. The growth is also what
/// says the slab is LIVE: a value pointing into storage the frame released
/// would read and write memory the testing allocator has already poisoned.
fn ownedTextCow(gpa: std.mem.Allocator) !void {
    const held = try ownedBytes("a\xffb");
    defer std.testing.allocator.free(held);

    var cow = try translated.text_cow_local(gpa, held);
    defer cow.deinit(gpa);

    try std.testing.expect(cow == .Owned);
    try std.testing.expectEqualStrings("a\xef\xbf\xbdb", cow.as_ref());
    try std.testing.expect(@intFromPtr(cow.as_ref().ptr) != @intFromPtr(held.ptr));

    try cow.Owned.push_str(gpa, "!");
    try std.testing.expectEqualStrings("a\xef\xbf\xbdb!", cow.as_ref());

    // The caller's own storage is untouched throughout: it was never aliased
    // and the release above freed only the cow's slab.
    try std.testing.expectEqualSlices(u8, "a\xffb", held);
}

/// The owned arm of `Cow<[u8]>`, on the terms `ownedTextCow` states.
///
/// Four bytes is the length `byte_cow_local` copies, so the frame built the slab
/// this value owns. Growing it after the frame is gone reads and writes the very
/// allocation the caller has to release, so a value that had merely pointed at
/// the input could not do it.
fn ownedByteCow(gpa: std.mem.Allocator) !void {
    const held = try ownedBytes("abcd");
    defer std.testing.allocator.free(held);

    var cow = try translated.byte_cow_local(gpa, held);
    defer cow.deinit(gpa);

    try std.testing.expect(cow == .Owned);
    try std.testing.expectEqualSlices(u8, "abcd", cow.as_ref());
    try std.testing.expect(@intFromPtr(cow.as_ref().ptr) != @intFromPtr(held.ptr));

    try cow.Owned.append(gpa, '!');
    try std.testing.expectEqualSlices(u8, "abcd!", cow.as_ref());

    try std.testing.expectEqualSlices(u8, "abcd", held);
}

test "an owned cow of str survives the move out of the frame that built it" {
    try ownedTextCow(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        ownedTextCow,
        .{},
    );
}

test "an owned cow of bytes survives the move out of the frame that built it" {
    try ownedByteCow(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        ownedByteCow,
        .{},
    );
}

// ── 3. the conversion error hands its bytes over exactly once ─────────────

/// The hand-off from a frame that owns nothing but the value it returns.
///
/// The refused arms are the case. `raw` is copied once, the error keeps that
/// copy, and the error is what the caller releases: a frame that had dropped
/// the error as well would make that release a double free, and one that dropped
/// nothing would leak. `valid_up_to` says where in those bytes the invalid
/// sequence starts, so the detail travelled with the payload rather than being
/// rebuilt beside it.
fn utf8ErrorHandoff(gpa: std.mem.Allocator) !void {
    var accepted = try translated.utf8_error_handoff(gpa, "ok");
    defer r2z.alloc.dropTemporary(gpa, &accepted);
    try std.testing.expect(accepted == .Ok);
    try std.testing.expectEqualStrings("ok", accepted.Ok.as_str());

    var refused = try translated.utf8_error_handoff(gpa, "\xff");
    defer r2z.alloc.dropTemporary(gpa, &refused);
    try std.testing.expect(refused == .Err);
    try std.testing.expectEqualStrings("\xff", refused.Err.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), refused.Err.utf8_error().valid_up_to);

    var partial = try translated.utf8_error_handoff(gpa, "ab\xff");
    defer r2z.alloc.dropTemporary(gpa, &partial);
    try std.testing.expect(partial == .Err);
    try std.testing.expectEqualStrings("ab\xff", partial.Err.bytes.items);
    try std.testing.expectEqual(@as(usize, 2), partial.Err.utf8_error().valid_up_to);
}

/// The same hand-off from a frame that also builds and releases a string.
///
/// The frame holds two owners across two different exit routes: the block's
/// string is always released inside the frame, and the error is never released
/// there. Getting either backwards is a different defect — a leak for the first,
/// a double free for the second — so one call tells them apart. The accepted run
/// is the one where the conversion succeeds, so the frame builds the string AND
/// the error's counterpart: two owners, two different releases.
fn utf8ErrorHandoffBesideString(gpa: std.mem.Allocator) !void {
    var held = try ownedFixture("held");
    defer held.deinit(std.testing.allocator);

    var accepted = try translated.utf8_error_handoff_beside_string(gpa, "ok", held.as_str());
    defer r2z.alloc.dropTemporary(gpa, &accepted);
    try std.testing.expect(accepted == .Ok);
    try std.testing.expectEqualStrings("ok", accepted.Ok.as_str());

    var refused = try translated.utf8_error_handoff_beside_string(gpa, "\xff", held.as_str());
    defer r2z.alloc.dropTemporary(gpa, &refused);
    try std.testing.expect(refused == .Err);
    try std.testing.expectEqualStrings("\xff", refused.Err.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), refused.Err.utf8_error().valid_up_to);

    // The caller's own buffer is untouched: the frame's release reached the
    // block's string and the error it handed on, and nothing else.
    try std.testing.expectEqualStrings("held", held.as_str());
}

// The counts one refused hand-off has to balance.
//
// `utf8_error_handoff` copies `raw` once and the error keeps that copy, so the
// frame makes exactly one allocation and the caller's release has to be exactly
// one deallocation of it. The counters are read after the release, so a frame
// that freed those bytes itself would show two deallocations against one
// allocation, and a frame that freed nothing would show none.
test "a conversion error hands its bytes to the caller and releases them once" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    {
        var refused = try translated.utf8_error_handoff(counting.allocator(), "\xff");
        defer r2z.alloc.dropTemporary(counting.allocator(), &refused);
        try std.testing.expect(refused == .Err);
        try std.testing.expectEqualStrings("\xff", refused.Err.bytes.items);
    }
    try std.testing.expectEqual(@as(usize, 1), counting.allocations);
    try std.testing.expectEqual(@as(usize, 1), counting.deallocations);
    try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
}

// The same hand-off, with and without the string the frame releases beside it.
//
// Two separate sweeps, because the two frames allocate different numbers of
// times: `utf8_error_handoff` copies once per call and this one copies twice on
// the route where the block's string is still live. A frame that leaked the
// block's string would only be caught by the second.
test "a failing allocator leaks nothing on either error hand-off" {
    try utf8ErrorHandoff(std.testing.allocator);
    try utf8ErrorHandoffBesideString(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        utf8ErrorHandoff,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        utf8ErrorHandoffBesideString,
        .{},
    );
}
