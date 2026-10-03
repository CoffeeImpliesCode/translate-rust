//! Overwritten-owner fixture.
//!
//! Every entry point here replaces an owner a place ALREADY holds. That is a
//! different claim from releasing an owner a frame built and then dropped: at
//! the moment the replacement is evaluated the place has a live handle AND a
//! live slab, so the frame owes exactly one release of what the place held —
//! after the replacement exists, and before the replacement lands in it.
//!
//! The order is load-bearing, and it is the only order these three cases can
//! distinguish:
//!
//!   1. the replacement is built first, so a replacement that cannot be built
//!      leaves this frame still holding — and still able to release — the
//!      owner the place held;
//!   2. the value the place held is released once;
//!   3. the replacement moves in, once.
//!
//! A release that never fires leaks the discarded value. One that runs before
//! the replacement is built frees bytes the replacement is built out of. One
//! that runs after the replacement moves in frees the survivor a second time.
//!
//! There is no `#[test]` module here and nothing runs `cargo test` on this
//! crate, so a test module would be items the translator has to read and that
//! never execute. What checks every claim below is
//! `test/overwritten_owner_consumer.zig`: it counts the blocks the generated
//! package builds, the blocks it releases and the bytes still live, through an
//! allocator of its own, so every number there is the package's rather than this
//! crate's, and it sweeps every allocation with `checkAllAllocationFailures` so
//! step 1 above is checked on the failing path too.

// ── 1. one local owner replaced by a later assignment ─────────────────────

/// One owner, replaced by a second one built in the same frame.
///
/// `"first"` is the value the place held and `"second"` is the replacement, so
/// the frame releases `"first"` exactly once and the caller receives
/// `"second"`. This is the same shape as the two-owner assignment the
/// `differential` fixture proves across a parameter boundary; here the
/// replacement is built inside the frame, so the frame's own `String` build is
/// the allocation that has to survive.
pub fn overwrite_local() -> String {
    let mut text = String::from("first");
    text = String::from("second");
    text
}

// ── 2. a shadowing `let` of the same name, holding an owned value ─────────

/// Two bindings share one source name and both own storage while they are live
/// at the same time, so a release keyed by the source NAME rather than by the
/// binding reaches the wrong one of the two.
pub fn overwrite_shadowed() -> String {
    let text = String::from("outer");
    {
        let mut text = String::from("inner");
        text = String::from("inner-second");
        // Reading and writing the binding through the name the outer owner also
        // uses is what separates the two: this reaches the INNER slab, and the
        // value the block ends holding is the one whose release the source name
        // has to resolve correctly.
        text.push('!');
    }
    text
}

// ── 3. one owner overwritten once per loop round ──────────────────────────

/// Every round replaces the owner the round before installed, so the number of
/// owners still live at the end is one however many rounds ran — not one per
/// round.
///
/// `"seed"` is what the first round's assignment discards, and each round after
/// that discards the previous round's `"round"`. What the caller receives is the
/// value the LAST round installed, and a zero-round call performs no assignment
/// at all, so `"seed"` is what leaves then and nothing is released inside the
/// frame.
pub fn overwrite_loop(rounds: u8) -> String {
    let mut current = String::from("seed");
    let mut index = 0u8;
    while index < rounds {
        current = String::from("round");
        index += 1;
    }
    current
}