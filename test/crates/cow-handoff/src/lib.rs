//! `Cow` hand-offs and the conversion error that carries bytes.
//!
//! Every function here binds an owner in a `let`, then hands that binding on as
//! the value it returns. Rust moves the binding: the scope that declared it ends
//! owning nothing, and the caller becomes the one owner. So each function is a
//! question about where the bytes ended up, and each has an answer only the
//! translated package can give — a `Cow` that borrows names the caller's storage
//! and frees nothing, a `Cow` that owns holds a slab only the caller may free,
//! and a `FromUtf8Error` keeps the bytes that failed validation until whoever
//! receives it releases them.
//!
//! Two `Cow` instantiations are covered separately, because they reach the two
//! arms by different means and a lowering that only holds for one of them is
//! only half checked by either:
//!
//!   * `Cow<'_, str>` through `String::from_utf8_lossy`, where WHICH arm the
//!     value carries is decided by the bytes the caller handed in: valid UTF-8
//!     borrows them, invalid bytes are repaired into storage the frame builds.
//!   * `Cow<'_, [u8]>` through the two variants named directly, where the arm is
//!     decided by the length of the input.
//!
//! The error hand-off is stated twice for the same reason. The first frame owns
//! nothing but the value it hands on, so its books are only about the error. The
//! second frame also builds and releases a string of its own, so a lowering that
//! released the error as well — or leaked the string — is told apart from one
//! that got both right.
//!
//! Nothing here reaches for an operation only a rustc borrow checker could
//! check. The bodies stay inside what the runtime lowers today: `String::from`,
//! `String::push`, `String::len`, `String::from_utf8_lossy`, `String::from_utf8`,
//! `slice::to_vec`, the two `Cow` variants, `FromUtf8Error::utf8_error` and
//! `Utf8Error::valid_up_to`.
//!
//! There is no `#[test]` module here. A test module in a corpus crate is an
//! item the translator still has to read and lower while nothing in this
//! repository ever runs it, so the assertions live in
//! `test/cow_handoff_consumer.zig`, which drives the translated package, reads
//! the caller's own storage back after each call, and counts the releases.

// ── Cow<'_, str> ───────────────────────────────────────────────────────────

/// The text cow, with the arm the input decides.
///
/// `String::from_utf8_lossy` borrows valid UTF-8 and repairs invalid bytes into
/// a fresh allocation, so one frame reaches both arms of `CowStr`: the value the
/// caller gets back either names the caller's bytes outright or owns bytes
/// nothing else points at. The `let` is the move under test — the binding ends
/// the frame and the return ends the caller's copy of it, so the two have to be
/// one owner between them.
pub fn text_cow_local(input: &[u8]) -> std::borrow::Cow<'_, str> {
    let cow = String::from_utf8_lossy(input);
    cow
}

// ── Cow<'_, [u8]> ──────────────────────────────────────────────────────────

/// The byte cow, with the arm the length decides.
///
/// Three bytes stay the caller's and anything else is copied into storage the
/// returned value owns, so one frame reaches both arms of `CowSlice` without
/// depending on what the bytes spell. The `Borrowed` arm names the caller's
/// slice and frees nothing on release; the `Owned` arm holds a slab this frame
/// copied, and a copy that aliased the input would be freed twice.
pub fn byte_cow_local(input: &[u8]) -> std::borrow::Cow<'_, [u8]> {
    let cow = if input.len() == 3 {
        std::borrow::Cow::Borrowed(input)
    } else {
        std::borrow::Cow::Owned(input.to_vec())
    };
    cow
}

// ── the conversion error ───────────────────────────────────────────────────

/// The failing arm owns the bytes that failed validation, and it hands that
/// error to the caller rather than dropping it here.
///
/// So the frame's own release has to leave those bytes alone: releasing them
/// here as well would leave the caller's release a double free, and the error is
/// the only thing this frame owns, so a frame that dropped nothing and a frame
/// that dropped everything differ only in what the caller finds.
pub fn utf8_error_handoff(raw: &[u8]) -> Result<String, std::string::FromUtf8Error> {
    let converted = String::from_utf8(raw.to_vec());
    match converted {
        Ok(text) => Ok(text),
        Err(error) => Err(error),
    }
}

/// The same hand-off from a frame that owns something else as well.
///
/// The nested block builds a string and releases it when the block ends, before
/// the conversion runs, so the frame holds two owners across two different exit
/// routes: the block's string is always released here, and the error is never
/// released here. Getting either backwards is a different defect — a leak for
/// the first, a double free for the second — so one call covers both.
pub fn utf8_error_handoff_beside_string(
    raw: &[u8],
    held: &str,
) -> Result<String, std::string::FromUtf8Error> {
    {
        let mut retained = String::from(held);
        retained.push('!');
    }
    let converted = String::from_utf8(raw.to_vec());
    match converted {
        Ok(text) => Ok(text),
        Err(error) => Err(error),
    }
}