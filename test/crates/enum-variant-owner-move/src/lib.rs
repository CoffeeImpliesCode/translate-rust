//! Ownership fixture: an enum that OWNS a payload in every variant, dispatched
//! by `match`, where every arm moves the payload out of the variant it chose.
//!
//! The enum is the carrier, and the carrier goes out of scope in every frame
//! here. That is what makes the two failure modes separate claims rather than
//! one: an arm that MOVES its payload must leave nothing behind for the carrier
//! to release, or the bytes are freed twice, and an arm that only READS its
//! payload has to release it itself, because nothing else will.
//!
//! Four variants carry four different texts, so a frame that selected the wrong
//! arm cannot produce the bytes its caller asked for, and a frame that released
//! the wrong payload still returns the right bytes but frees the wrong address.
//!
//! The payloads are spelled out in each frame rather than built by one shared
//! helper on purpose. The consumer's own signatures — an allocator parameter
//! and an error union on each of these three — are exactly what construction
//! inside a frame buys, and routing it through a callee would make both of them
//! a fact about the helper instead of a fact about the function under test.

/// One owned `String` per variant.
///
/// Every variant owns storage, so no arm can be a bare tag whose release is a
/// no-op by accident, and the four payloads are independent allocations that a
/// wrong arm cannot mistake for one another.
pub enum Payload {
    Text(String),
    Number(String),
    Flag(String),
    Blank(String),
}

/// Build the variant `mode` names, so a caller can hold a carrier of its own.
///
/// The value is the caller's to hand on: `dispatch` takes it and moves the
/// payload out of it, which is why nothing here releases what it builds.
pub fn build(mode: u8) -> Payload {
    if mode == 0 {
        Payload::Text(String::from("alpha"))
    } else if mode == 1 {
        Payload::Number(String::from("bravo"))
    } else if mode == 2 {
        Payload::Flag(String::from("charlie"))
    } else {
        Payload::Blank(String::from("delta"))
    }
}

/// The carrier built, dispatched and dropped in ONE frame.
///
/// Each arm moves its payload out of the enum and hands the bytes back, and the
/// local the enum was bound to goes out of scope here. This is the frame in
/// which a second release of a moved payload is a double free rather than a
/// leak nobody notices: the carrier is still in scope while the arm's release
/// runs, so both owners exist at the same moment.
pub fn dispatch(mode: u8) -> String {
    let value = if mode == 0 {
        Payload::Text(String::from("alpha"))
    } else if mode == 1 {
        Payload::Number(String::from("bravo"))
    } else if mode == 2 {
        Payload::Flag(String::from("charlie"))
    } else {
        Payload::Blank(String::from("delta"))
    };
    match value {
        Payload::Text(text) => text,
        Payload::Number(text) => text,
        Payload::Flag(text) => text,
        Payload::Blank(text) => text,
    }
}

/// The same carrier, dispatched by arms that only READ the payload.
///
/// The arm's own release is then the one and only release of the bytes that
/// arm selected, and the frame ends holding nothing: the answer is a length,
/// which owns nothing. This is the same claim as `dispatch` measured from the
/// other side, because "released exactly once" has to hold for the frame that
/// hands the payload on AND for the frame that keeps it.
pub fn measure(mode: u8) -> usize {
    let value = if mode == 0 {
        Payload::Text(String::from("alpha"))
    } else if mode == 1 {
        Payload::Number(String::from("bravo"))
    } else if mode == 2 {
        Payload::Flag(String::from("charlie"))
    } else {
        Payload::Blank(String::from("delta"))
    };
    match value {
        Payload::Text(text) => text.len(),
        Payload::Number(text) => text.len(),
        Payload::Flag(text) => text.len(),
        Payload::Blank(text) => text.len(),
    }
}
