//! Ownership exits reached while a scope still holds an owner.
//!
//! Rust releases a `let` binding when the scope that declared it ends, and it
//! ends on whichever construct left it: an early `return`, a `break` or a
//! `continue` out of a loop body, the propagation of a `?`, or the allocation
//! failure that unwinds the frame before any of those. Each function below
//! takes one of those routes while at least one owner is live, so the frame the
//! translator emits has to reach the same release whichever route ran.
//!
//! `test/allocator_failure_ownership_consumer.zig` re-runs every function once
//! per injected allocation failure and checks the frame's own books after each
//! run, so two properties of every function here are load-bearing:
//!
//!   * Every parameter is borrowed or a scalar. A run therefore allocates only
//!     what its own body builds, and the fixture the consumer hands in never
//!     mixes its storage with the storage the frame under test allocates.
//!   * Every run of a function allocates a fixed number of times. A loop
//!     therefore runs a fixed number of rounds, decided by its parameters and
//!     by nothing the caller supplies.
//!
//! Every body stays inside the operations the runtime lowers today:
//! `String::from`, `String::push`, `String::len`, a `Vec<u8>` literal, and
//! `Vec::push`/`Vec::len`. Nothing here reaches for an operation that only a
//! rustc borrow checker could check, because this crate is read by a
//! translator and not by rustc.

/// The step `question_exit` propagates from.
///
/// A separate frame on purpose: the propagating call then has an error of its
/// own, so `?` has a real `Err` to convert and leave through. The `Ok` arm
/// hands back an owner the caller has to release; the `Err` arm allocates
/// nothing, which is what makes the caller's mid-scope releases the only
/// storage at risk when the propagation fires.
fn build_step(accept: bool) -> Result<String, u8> {
    if accept {
        Ok(String::from("step"))
    } else {
        Err(9u8)
    }
}

/// The `return` exit.
///
/// `carried` is already live when the early return runs, and the release it
/// skips past is the same release the end of the function reaches. Nothing
/// here is handed on: the value is a length, so every owner this frame built
/// belongs to the frame and to nobody else.
pub fn return_exit(held: &str, stop: bool) -> Result<usize, u8> {
    let carried = String::from(held);
    if stop {
        return Err(1u8);
    }
    let mut marked = String::from("marked");
    marked.push('!');
    Ok(carried.len() + marked.len())
}

/// The `break` exit.
///
/// Three owners, three release scopes, in one body:
///
///   * `marks` is declared by the loop BODY, so the body block owns it. The
///     `break` leaves that block with `marks` still live, and so does the
///     iteration that ends on the condition.
///   * `shadow` is declared by the frame and never handed on, so one release
///     covers every route out of the loop, whatever ended it.
///   * `carried` is handed on as the tail. The hand-on empties the frame's own
///     handle before the frame's release runs, so that release finds nothing
///     and frees nothing. A release that ran against storage the caller still
///     reads would free what the caller holds, and a second owner of the same
///     allocation would free it twice.
pub fn break_exit(held: &str, limit: u8, stop_at: u8) -> String {
    let mut carried = String::from(held);
    let mut shadow = String::from("");
    let mut index = 0u8;
    while index < limit {
        let mut marks: Vec<u8> = vec![b'.'];
        marks.push(b'+');
        if index >= stop_at {
            break;
        }
        carried.push('.');
        shadow.push('.');
        index += 1;
    }
    carried
}

/// The `continue` exit.
///
/// The same three owners as `break_exit`, with `continue` in place of `break`.
/// `limit` of one with `skip_first` set is the case that matters: the body runs
/// exactly once and leaves through `continue`, so the loop then ends on its
/// condition with nothing accumulated.
pub fn continue_exit(held: &str, limit: u8, skip_first: bool) -> String {
    let mut carried = String::from(held);
    let mut shadow = String::from("");
    let mut index = 0u8;
    while index < limit {
        let mut marks: Vec<u8> = vec![b'.'];
        marks.push(b'+');
        if skip_first {
            if index == 0 {
                index += 1;
                continue;
            }
        }
        carried.push('.');
        shadow.push('.');
        index += 1;
    }
    carried
}

/// The `?` exit.
///
/// `carried` and `marked` are live ACROSS the propagation, so the error arm of
/// `build_step` has to reach both releases before it leaves the frame. The
/// success arm adds a third owner, `step`, which the end of the frame releases
/// instead: it is read for its length and never handed on.
pub fn question_exit(held: &str, accept: bool) -> Result<usize, u8> {
    let carried = String::from(held);
    let mut marked = String::from("marked");
    marked.push('!');
    let step = build_step(accept)?;
    Ok(carried.len() + marked.len() + step.len())
}

/// The allocation that fails in the middle of a scope.
///
/// No exit of its own: the frame allocates a string, allocates and grows a
/// second one, then allocates and grows a list, and returns a length. Every
/// allocation after the first therefore fails with `carried` already live, and
/// `marked` and `marks` join it one allocation later. Each of them has to be
/// released on the way out, which is the same requirement the four exits above
/// impose by a different route.
pub fn grow_exit(held: &str) -> usize {
    let carried = String::from(held);
    let mut marked = String::from("marked");
    marked.push('!');
    let mut marks: Vec<u8> = vec![b'.'];
    marks.push(b'+');
    marks.push(b'-');
    marks.push(b'*');
    carried.len() + marked.len() + marks.len()
}
