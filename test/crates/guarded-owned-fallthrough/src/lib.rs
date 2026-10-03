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
//! ## A known boundary this fixture pins rather than hides
//!
//! `nested_owned_dispatch` DOES NOT pass, and the failure is named here rather
//! than left for a reader to discover as a leak report. It is a RUN failure and
//! not a typed refusal: the crate analyses, lowers and compiles, the generated
//! package builds, and its own test run is what reports the leak. So the
//! boundary surfaces as `GeneratedPackageRunFailed` and is pinned by that name
//! in `rejected_source_specs`.
//!
//! `Shape::Duo(_, right)` and `Node::Pair(_, right)` drop the FIRST element — a
//! `String` — and nothing releases it. The obstacle is specific. An arm that
//! binds a variant field gets that field's capture release armed, and for a
//! TWO-field variant `matchCapturePayload` still finds the one binding among
//! the fields and releases it, so `right` is handed out and the caller's
//! `deinit` stays the only release of it. The WILDCARD field is the gap: it
//! carries no name, and `emitMatchDestructureBody` emits a binding only for a
//! field whose pattern is a binding, so `payload.0` is never bound and never
//! released. That the arm takes an owned payload also suppresses the release
//! armed over the scrutinee as a whole, so nothing covers it from that side
//! either.
//!
//! The crate's own two translated tests split the same way. The one calling
//! `nested_owned_dispatch` leaks on both tuple paths, for exactly two leaked
//! allocations, and the one calling only `guarded_fallthrough` passes — every
//! variant that function matches carries exactly one field.
//!
//! `test/guarded_owned_fallthrough_consumer.zig` is the reproducer for this gap
//! and is deliberately unwired from `test/e2e_test.zig` while it is open, so its
//! assertions are written and ready rather than running against a package this
//! crate cannot publish. It comes back the moment the lowering gap closes.
//!
//! This is NOT the same boundary as "a named struct is not an owner type", which
//! is documented elsewhere and pinned by its own tests. Here the enum carries
//! its payload in a VARIANT FIELD and the lowering binds and releases only the
//! fields a pattern names. A correct lowering exists — bind the wildcard field
//! to a synthetic name, arm `defer` on it in the arm — and it needs the pattern
//! field-naming contract reworked; it is not a spelling fix.
//!
//! Until that lands, this crate's `nested_owned_dispatch` is a RED FIXTURE that
//! documents a real gap. Do not weaken its consumer to make it green.

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
