//! Owned payloads that outlive a failed guard and a nested dispatch.
//!
//! Two contracts, each reachable on every path it names:
//!
//! 1. A match whose first arm binds an owned label and then refuses it with a
//!    guard. The label belongs to the scrutinee, so the next arm has to bind the
//!    same allocation and be its only owner. A release on the guard's failure
//!    path would hand the next arm storage the frame no longer owns.
//! 2. An enum with an owned tuple variant, dispatched by a match nested in the
//!    arm that binds it. The label the inner arm hands out is the caller's to
//!    release, and the wrapper it left behind owns nothing afterwards.
//!
//! Every function returns the label it selected rather than a length or a flag,
//! so the consumer reads the bytes that had to survive.
//!
//! ## Coverage
//!
//! The generated crate runs its own translated tests. The end-to-end test also
//! stages the crate and runs its six-case Zig consumer in Debug and ReleaseSafe.
//!
//! The consumer checks that wildcard tuple fields are released once, while the
//! selected label remains caller-owned. A failed guard keeps its label for the
//! next arm. Allocation failures release labels already live in the frame.

/// An owned label, and a variant that binds no label at all.
pub enum Signal {
    /// The label a guard inspects.
    Label(String),
    /// A payload no arm binds a label from.
    Bare,
}

/// The signal the match will see. `mode` decides which arm answers.
fn signal_for(mode: u8) -> Signal {
    match mode {
        0 => Signal::Label("guarded-long".to_string()),
        1 => Signal::Label("tiny".to_string()),
        _ => Signal::Bare,
    }
}

/// The first arm binds the label and the guard measures it. Mode 1 fails that
/// guard, so the second arm binds the same allocation and reads the same bytes;
/// mode 2 binds no label at all. The caller's release is the only one, whatever
/// arm answered.
pub fn guarded_fallthrough(mode: u8) -> String {
    let signal = signal_for(mode);
    match signal {
        Signal::Label(text) if text.len() > 6 => text,
        Signal::Label(text) => text,
        Signal::Bare => String::from("bare"),
    }
}

/// An inner payload: one owned label, or two in tuple order.
pub enum Shape {
    /// One owned label.
    Solo(String),
    /// Two owned labels, the first of which no arm hands out.
    Duo(String, String),
}

/// The outer payload: a nested `Shape`, an owned tuple variant, or nothing.
pub enum Node {
    /// A payload the arm has to look at one level deeper.
    Nested(Shape),
    /// Two owned labels, dispatched without nesting.
    Pair(String, String),
    /// No owned payload at all.
    Bare,
}

/// The node the nested dispatch starts from. `shape` decides which arm answers.
fn node_for(shape: u8) -> Node {
    match shape {
        0 => Node::Nested(Shape::Solo("inner-solo".to_string())),
        1 => Node::Nested(Shape::Duo(
            "inner-left".to_string(),
            "inner-right".to_string(),
        )),
        2 => Node::Pair("outer-left".to_string(), "outer-right".to_string()),
        _ => Node::Bare,
    }
}

/// The outer match binds an owned `Shape`, and the inner match binds the labels
/// inside it. A label the inner arm does not hand out is released inside this
/// frame; the one it does is the caller's alone.
pub fn nested_owned_dispatch(shape: u8) -> String {
    let node = node_for(shape);
    match node {
        Node::Nested(inner) => {
            match inner {
                Shape::Solo(text) => text,
                Shape::Duo(_, right) => right,
            }
        }
        Node::Pair(_, right) => right,
        Node::Bare => String::from("bare"),
    }
}

#[test]
fn guarded_fallthrough_hands_one_label_to_both_label_arms() {
    let accepted = guarded_fallthrough(0);
    assert!(accepted == "guarded-long");
    // The guard refused the same pattern's label, so these are the bytes it
    // measured and the second arm moved.
    let refused = guarded_fallthrough(1);
    assert!(refused == "tiny");
}

#[test]
fn nested_dispatch_hands_out_one_inner_label() {
    let solo = nested_owned_dispatch(0);
    assert!(solo == "inner-solo");
    // The second element of the inner tuple variant, not the first.
    let duo = nested_owned_dispatch(1);
    assert!(duo == "inner-right");
    let pair = nested_owned_dispatch(2);
    assert!(pair == "outer-right");
}
