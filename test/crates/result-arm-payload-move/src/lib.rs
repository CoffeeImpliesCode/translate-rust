//! Match-arm payload moves out of a temporary `Result`.
//!
//! Every function here matches a `Result` its own frame builds inline and never
//! names, so the storage the arms bind is live only for the duration of the
//! `match` and reaches the caller only by being moved out of an arm. Both arms
//! bind an OWNED payload: an arm that bound a borrow would exercise no
//! transfer at all, and an arm that bound nothing would owe nothing.
//!
//! The error type is `String` rather than an enum on purpose. A Rust `Result`
//! whose error type is a payload-free enum lowers to a Zig error union, which
//! carries a tag rather than a value, and there is nothing on the `Err` side of
//! one for an arm to move. Naming an owning type on both sides keeps the tagged
//! union, so each of its arms holds storage of its own.
//!
//! The consumer in `test/result_arm_payload_consumer.zig` is the proof: it
//! drives both arms, releases what comes back once, and repeats every call at
//! each failing allocation index.

/// The label a lookup found, or the reason it found none. Both answers are text
/// this frame owns, so the match below binds storage on either arm.
///
/// Moving the bound payload out is what hands the caller the allocation the arm
/// was given. A frame that also released that payload would free the caller's
/// bytes a second time, and one that released nothing would leak the allocation
/// the caller now owns.
pub fn payload_move(present: bool) -> String {
    match if present {
        Ok(String::from("present"))
    } else {
        Err(String::from("absent"))
    } {
        Ok(found) => found,
        Err(reason) => reason,
    }
}

/// The same temporary, read rather than moved. Neither arm hands its payload
/// on, so each arm's scope owes the single release the move would otherwise
/// have performed: skipping it leaks the string this frame built, and running
/// it twice frees the same bytes twice.
pub fn payload_length(present: bool) -> usize {
    match if present {
        Ok(String::from("present"))
    } else {
        Err(String::from("absent"))
    } {
        Ok(found) => found.len(),
        Err(reason) => reason.len(),
    }
}
