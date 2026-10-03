//! Loop-carried ownership on each way a Rust loop can end.
//!
//! Every function here builds owners INSIDE a loop and then leaves the loop by
//! a different route: a `break` that carries a value out, a `break` that
//! carries nothing, a `continue` that follows a move, a `return` that leaves
//! from inside the body, and a `while let` that drives an iterator to
//! exhaustion. Each route has to release every owner the body still holds and
//! hand on every owner it moved, exactly once, and the value the loop produced
//! has to be the one this source says it is.
//!
//! The generated package is proved by `test/loop_ownership_consumer.zig`, which
//! runs each route under the testing allocator. A release that never happens is
//! a leak that allocator reports, a release that happens twice is a double free
//! it reports, and a loop that hands on the wrong value fails the byte
//! comparison.

// ── 1. a `break` that carries a value ──────────────────────────────────────

/// Every iteration builds one owner and reads it into the accumulator. The
/// iteration whose counter reaches `limit` hands the accumulator on instead of
/// running again.
///
/// So the iteration that breaks ends its own scope with the `break`, and the
/// owner it built is released there; the accumulator it hands on is never
/// released by the loop at all, because the move emptied the handle the frame's
/// own release would have run on. The result carries one `ab` per iteration,
/// so the count of iterations and the count of releases cannot be told apart by
/// accident.
pub fn break_carries_owner(limit: u32) -> String {
    let mut index = 0u32;
    let mut carried = String::from("");
    loop {
        let owner = String::from("ab");
        carried.push_str(&owner);
        index += 1;
        if index >= limit {
            break carried;
        }
    }
}

// ── 2. a `break` that carries nothing ──────────────────────────────────────

/// The body builds one owner per iteration and moves it into the list the loop
/// hands back. `stop_at` decides whether the loop runs out on its own
/// condition or leaves through the `break`.
///
/// The iteration that breaks is the case a valueless `break` has to get right:
/// it built an owner, it never moved it, and its scope ends right there. That
/// owner is the one the body's release has to free, and the list the loop hands
/// back holds only the owners the earlier iterations moved. The routes are told
/// apart by the list itself: three elements when the condition ended the loop,
/// one when the `break` ended it on the second iteration, none when it ended it
/// on the first.
pub fn break_releases_owner(limit: u32, stop_at: u32) -> Vec<String> {
    let mut kept: Vec<String> = vec![];
    let mut index = 0u32;
    while index < limit {
        let owner = String::from("round");
        index += 1;
        if index >= stop_at {
            break;
        }
        kept.push(owner);
    }
    kept
}

// ── 3. a `continue` that follows a move ───────────────────────────────────

/// One iteration builds two owners: a byte list it never moves, and a string
/// it moves into the list the loop hands back.
///
/// `skip` names the iteration that leaves through the `continue`, and on that
/// iteration the move has already happened. The body's release therefore runs
/// on a handle the move emptied, so the moved owner is released once, by
/// whoever releases the list, and not a second time by the body that handed it
/// over. The byte list is released on every iteration, the `continue` one
/// included. The element at the `skip` position is the one that carries the
/// `!`, so a loop that continued on some other iteration cannot pass.
pub fn continue_after_move(limit: u32, skip: u32) -> Vec<String> {
    let mut kept: Vec<String> = vec![];
    let mut index = 0u32;
    while index < limit {
        let mut owner = String::from("round");
        let mut marks: Vec<u8> = vec![b'.'];
        index += 1;
        marks.push(b'+');
        if index == skip {
            owner.push('!');
            kept.push(owner);
            continue;
        }
        kept.push(owner);
    }
    kept
}

// ── 4. an early `return` from inside the loop ──────────────────────────────

/// The frame owns `carried` before the loop and `rounds` and `round` inside it,
/// and `early_at` names the iteration that returns.
///
/// That return leaves the body with the per-iteration owner still live and the
/// frame's own owner only borrowed, so it is the one route that has to release
/// two owners, hand a third on and touch none of them twice. The result says
/// which route ran: it is `carried` alone when the first iteration returned, a
/// round and then `carried` when the second did, and only rounds when no
/// iteration returned at all.
pub fn return_holds_owner(limit: u32, early_at: u32) -> String {
    let carried = String::from("carried");
    let mut rounds = String::from("");
    let mut index = 0u32;
    while index < limit {
        let round = String::from(".");
        index += 1;
        if index == early_at {
            rounds.push_str(&carried);
            return rounds;
        }
        rounds.push_str(&round);
    }
    rounds
}

// ── 5. a `while let` that consumes an iterator into an owner ───────────────

/// The loop walks a real slice iterator through `while let` and folds every
/// step into the owner it hands back.
///
/// The item the iterator yields is a borrow of the caller's slice, so the owner
/// each iteration builds is the only storage the body owns, and that owner is
/// released when the iteration ends. The loop's exit is the `while let`'s own:
/// the iterator runs dry, the body never breaks and never continues, and the
/// owner that leaves is the accumulated string and nothing else.
pub fn while_let_drains(input: &[u32]) -> String {
    let mut text = String::from("");
    let mut iter = input.iter();
    while let Some(value) = iter.next() {
        let mut piece = String::from("ab");
        if *value == 2u32 {
            piece.push('!');
        }
        text.push_str(&piece);
    }
    text
}