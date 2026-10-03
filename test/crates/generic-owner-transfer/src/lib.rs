//! Generic owner-transfer fixture.
//!
//! A generic function that TAKES an owned value BY VALUE owns it from the
//! moment it is called: Rust moved the bytes in, so nobody outside the callee
//! will ever release them. The whole ownership question is therefore where that
//! one owner ends up and how many times it is released on the way there.
//!
//! Three shapes are here, and `String` and `Vec<u8>` are the two
//! instantiations: one owned type carries a runtime container of its own, the
//! other owns nothing but a byte slab.
//!
//! * [`relay`] hands the very same owner back to its caller;
//! * [`relay_or_release`] either hands it back or lets the frame release it;
//! * [`into_vec`] answers with a DIFFERENT owned type.
//!
//! Every owner here is one of the runtime containers the target releases by
//! itself. Nothing in this fixture claims general Rust `Drop` support.

use std::string::String;
use std::vec::Vec;

/// Take `value` by value and hand the SAME owner back to the caller.
///
/// The body reads `value` in tail position, so the one owner the callee holds
/// leaves through the return instead of being released here.
pub fn relay<T>(value: T) -> T {
    value
}

/// Take `value` by value. `keep` chooses where that one owner goes: returned to
/// the caller, or released with this frame.
///
/// The two arms disagree about a single allocation, and that disagreement is
/// the whole point. The arm that returns hands the owner on, so the release
/// this frame armed finds the emptied handle and frees nothing; the arm that
/// drops leaves the frame holding it, so that release frees the vector and
/// everything it carries, exactly once.
pub fn relay_or_release<T>(keep: bool, value: Vec<T>) -> Option<Vec<T>> {
    if keep {
        Some(value)
    } else {
        None
    }
}

/// Take `value` by value and answer with a DIFFERENT owned type.
///
/// The transferred owner becomes the single element of a fresh vector, so the
/// caller releases one vector and reaches the owner it was given whole inside
/// it.
pub fn into_vec<T>(value: T) -> Vec<T> {
    vec![value]
}

/// An owned `String`, built through the allocator the call takes and released
/// by whoever owns the answer.
pub fn new_text() -> String {
    String::from("alpha")
}

/// An owned `Vec<u8>`, built through the allocator the call takes and released
/// by whoever owns the answer.
pub fn new_bytes() -> Vec<u8> {
    vec![1, 2, 3]
}

#[cfg(test)]
mod tests {
    use super::{into_vec, new_bytes, relay};

    /// `relay` at `T = Vec<u8>`: the owner that comes back is the owner that
    /// went in, at the length it had.
    #[test]
    fn relay_bytes_hands_the_owner_back() {
        let bytes = new_bytes();
        let returned = relay(bytes);
        assert_eq!(returned.len(), 3);
    }

    /// `into_vec` answers with a different owned type, and the owner it was
    /// given rides inside it rather than beside it.
    #[test]
    fn into_vec_wraps_the_transferred_owner() {
        let wrapped = into_vec(new_bytes());
        assert_eq!(wrapped.len(), 1);
    }
}