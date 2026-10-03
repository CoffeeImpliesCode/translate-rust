//! Ownership proof: a let-bound owning `Result` matched on both arms.
//!
//! `outcome` is a binding, not a temporary. Each function here names it and
//! then matches THAT NAME by value, which moves the value out of the place it
//! stands: an arm receives the payload the carrier was holding, and the carrier
//! is left holding nothing.
//!
//! Both arms carry owned bytes. `String` is a `Vec<u8>`, so the `Ok` arm and the
//! `Err` arm each own a heap allocation, and neither arm is a copy. The carrier
//! is a union rather than an allocation of its own, so the only thing it can
//! release is the payload it still holds: it must release that payload exactly
//! once when an arm leaves it behind, and not at all when an arm moved it out.
//!
//! `let_bound_result_match` is the moving shape. `let_bound_result_match_length`
//! is its control, matching the same binding and only reading the payload, so
//! the arm owns those bytes when the arm ends. Between them they separate the
//! two failures a carrier release can have: freeing a payload an arm already
//! moved out, and never freeing one it kept.

/// The payload the `Ok` arm built, or the payload the `Err` arm built, moved out
/// of the carrier and handed to the caller.
///
/// The caller owns exactly one `String` and releases it exactly once. Nothing
/// inside the frame may release those bytes, or the handle this returns would
/// name storage that is already gone.
pub fn let_bound_result_match(mode: u8) -> String {
    let outcome: Result<String, String> = build(mode);
    match outcome {
        Ok(found) => found,
        Err(problem) => problem,
    }
}

/// The length of the payload the carrier was holding, measured while the arm
/// still owned it.
///
/// Nothing moves out here, so the arm is what owns the payload at the end of
/// the arm. The number is a copy and outlives both arms; the bytes it was
/// measured from do not.
pub fn let_bound_result_match_length(mode: u8) -> usize {
    let outcome: Result<String, String> = build(mode);
    match outcome {
        Ok(found) => found.len(),
        Err(problem) => problem.len(),
    }
}

/// `mode == 0` builds the success arm, and every other mode builds the failure
/// arm. Both payloads are owned, so both arms of a match over this value have
/// something to move out and something to release.
fn build(mode: u8) -> Result<String, String> {
    if mode == 0 {
        Ok(String::from("payload"))
    } else {
        Err(String::from("rejected"))
    }
}