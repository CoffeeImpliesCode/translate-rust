//! A `match` that moves its own subject's payload out to the caller.
//!
//! The frame here OWNS a cow by value, destructures it with `match`, and hands
//! the payload of the matching arm straight back. That is the shape
//! `percent-encoding`'s `decode_utf8_lossy` is: it takes a `Cow<'_, [u8]>` and,
//! on the owned arm, re-wraps the very bytes it was given as a `Cow<'_, str>`
//! rather than copying them.
//!
//! Rust settles ownership for this shape by hand. `match cow` MOVES the
//! subject, so an arm that binds the owned payload by value takes it OUT of the
//! subject and the subject is spent; an arm that binds nothing leaves the
//! subject holding exactly what it had, and the frame still owes the release.
//! Between the frame and the caller there is exactly one owner either way, and
//! every function here is a question about which one it is and how many times
//! its bytes are released.
//!
//! A lowering that READS the subject where Rust moves it leaves two owners of
//! one slab, and the difference between the two failures is worth stating: a
//! frame that still holds its subject while the caller holds the payload frees
//! the caller's bytes on the way out, which is a use-after-free rather than a
//! plain double free, and it reads as one. The caller's bytes are gone by the
//! time the caller looks at them.
//!
//! Four exports, because "who holds the bytes" has four answers and a fix that
//! gets three of them is not a fix:
//!
//!   * `owned_bytes` binds the owned payload by value out of a temporary and
//!     returns it, so the CALLER is the one owner and the frame owes nothing.
//!   * `round_trip_bytes` does the same through a by-VALUE PARAMETER, which is
//!     the shape percent-encoding is written in and the one where a frame holds
//!     a release over the very binding the dispatch moves out of.
//!   * `moved_bytes` binds an armed local by value and only reads it, so the
//!     payload moves into the arm and the ARM's release is the one that frees
//!     it. Reading the subject instead would leave both the subject and the arm
//!     holding the same slab, and both would free it.
//!   * `kept_bytes` binds nothing at all, so the subject is never spent and the
//!     frame's own release is the only one. A rule that drained EVERY match
//!     subject would empty this one and leak the slab it still owns.
//!
//! Nothing here reaches for an operation only a borrow checker could check, and
//! nothing re-implements the crate under test. The assertions live in
//! `test/match_subject_handoff_consumer.zig`, which drives the translated
//! package, reads the caller's own storage back after each call, and counts the
//! releases the frame actually performed.

/// The cow every function here starts from, built over the caller's own slice.
///
/// This is a free function rather than something each body repeats, because the
/// OWNED arm is the one under test: three copies of the same construction would
/// differ only in which of them the consumer forgets to check.
fn borrow_or_own<'a>(input: &'a [u8], owned: bool) -> std::borrow::Cow<'a, [u8]> {
    if owned {
        std::borrow::Cow::Owned(input.to_vec())
    } else {
        std::borrow::Cow::Borrowed(input)
    }
}

/// Destructure a cow this frame was handed BY VALUE, moving the payload out.
///
/// This is the whole mechanism the exports differ in WHERE they call, and the
/// frame that calls it still holds a binding of its own over the same bytes.
fn handed_back(input: std::borrow::Cow<'_, [u8]>) -> Vec<u8> {
    match input {
        std::borrow::Cow::Borrowed(bytes) => bytes.to_vec(),
        std::borrow::Cow::Owned(bytes) => bytes,
    }
}

/// Hand the owned payload straight back, so the CALLER becomes its one owner.
///
/// The `match` moves the owned payload out of the cow and this function returns
/// it. A frame that still held a release over that cow would free the caller's
/// bytes before the caller read them, which is the use-after-free this fixture
/// exists to catch.
pub fn owned_bytes(input: &[u8], owned: bool) -> Vec<u8> {
    handed_back(borrow_or_own(input, owned))
}

/// The same hand-off written the way percent-encoding writes it.
///
/// Here the cow crosses a FUNCTION BOUNDARY by value, so the frame that
/// destructures it owns a parameter rather than a temporary, and the lowering
/// arms a release over that parameter for the whole body. That release is the
/// one a rule that failed to spend the subject would leave armed over bytes the
/// caller now holds.
pub fn round_trip_bytes(input: &[u8], owned: bool) -> Vec<u8> {
    let cow = borrow_or_own(input, owned);
    handed_back(cow)
}

/// Bind an armed local by value and only read it, so the ARM owns the payload.
///
/// `match cow` moves the owned payload out of `cow` and into the arm's binding
/// even though the body only asks for its length, because a by-value binding is
/// a move whatever the body does with it. The arm's release is therefore the one
/// that frees the slab, and `cow` has nothing left to free. A lowering that read
/// the subject instead would leave both handles naming one slab.
pub fn moved_bytes(input: &[u8], owned: bool) -> usize {
    let cow = borrow_or_own(input, owned);
    match cow {
        std::borrow::Cow::Borrowed(bytes) => bytes.len(),
        std::borrow::Cow::Owned(bytes) => bytes.len(),
    }
}

/// Bind nothing at all, so the subject is never spent and the frame still owes
/// the release it was armed with.
///
/// This is the control for `moved_bytes`: the two differ only in whether an arm
/// binds the owned payload, so the release counts say WHICH owner the frame was
/// rather than that some number of releases happened. A rule that drained every
/// match subject would empty `cow` here and leak the slab it still owns.
pub fn kept_bytes(input: &[u8], owned: bool) -> usize {
    let cow = borrow_or_own(input, owned);
    match cow {
        std::borrow::Cow::Borrowed(_) => 0,
        std::borrow::Cow::Owned(_) => 1,
    }
}
