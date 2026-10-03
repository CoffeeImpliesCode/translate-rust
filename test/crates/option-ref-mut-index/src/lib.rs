//! Genuine `Option` payload borrowed by mutable reference out of INDEXED
//! storage.
//!
//! The element type is the real `Option<u32>` throughout. A stand-in enum with
//! a tag of its own would answer the same questions about a discriminant but
//! nothing about `Some(ref mut …)`, which is about borrowing the payload
//! storage the optional already holds. So there is no such enum here, and every
//! function below names `Option` and its `Some`/`None` variants directly.
//!
//! Three claims are under test, and each is stated twice: once through a
//! `&mut Vec<Option<u32>>` receiver and once through a `&mut [Option<u32>]` one.
//! Both receivers name one element of storage the caller owns, and both have
//! to yield a place the arm's borrow can point into, but they reach that
//! storage differently — a vector through its own buffer, a slice through the
//! caller's slice header — so a lowering that only holds for one of them is
//! only half checked by either.
//!
//! 1. The write lands in the element the index named. `Some(ref mut slot)`
//!    binds a borrow of the element's own storage, so `*slot = value` has to
//!    reach past the frame the dispatch made for itself.
//! 2. Every element the index did not name keeps the value it had. A borrow
//!    that landed in a copy would either miss the target entirely or write one
//!    fixed element whatever index it was given, and the neighbours are what
//!    tells those two failures apart.
//! 3. The indexed receiver is evaluated exactly once. The index expression runs
//!    the caller's counter, so a lowering that read the scrutinee twice — once
//!    to test it against `None` and once to borrow the payload — would move
//!    that counter twice for a single write.
//!
//! Nothing here allocates and nothing is owned: every payload is a `u32` the
//! caller supplies, and every element is storage the caller built and reads
//! back itself.
//!
//! There is no `#[test]` module here. A test module in a corpus crate is an
//! item the translator still has to read and lower while nothing in this
//! repository ever runs it, so the assertions live in
//! `test/option_ref_mut_index_consumer.zig`, which drives the translated
//! package and checks the caller's own storage after each call.

// ── the index the receiver evaluates ──────────────────────────────────────

/// The index and the counter travel together, so a caller can see how many
/// times the indexed receiver ran rather than how many times it was read.
///
/// The container is reached through a parameter and is named once by
/// construction, so the index is the only part of the receiver with an
/// observable effect. That is what makes the effect countable: one write must
/// move the counter once however many reads the dispatch performs.
fn counted_index(cursor: &mut u32, index: usize) -> usize {
    *cursor += 1;
    index
}

// ── the write, through a vector receiver and through a slice receiver ────

/// Write `value` into the payload the element at `index` holds, and answer
/// what that element holds once the arm is done.
///
/// The storage is the caller's own vector, and the binding is spelled
/// `ref mut` on purpose: the reference is what is under test here. A scrutinee
/// borrowed as `&mut values[index]` would carry its payload by value through
/// default binding modes, which is a copy, so the write would stay in this
/// frame and the caller's element would never change at all.
///
/// An element that holds no payload has nothing to write. It answers zero, it
/// stays empty rather than being turned into a payload, and the index still ran
/// exactly once.
pub fn write_vec_slot(
    values: &mut Vec<Option<u32>>,
    index: usize,
    value: u32,
    cursor: &mut u32,
) -> u32 {
    match values[counted_index(cursor, index)] {
        Some(ref mut slot) => {
            *slot = value;
            *slot
        }
        None => 0u32,
    }
}

/// The same write through a slice parameter, on the terms `write_vec_slot`
/// states.
///
/// The storage is still the caller's and the binding is still spelled
/// `ref mut`, but the receiver is reached through a slice header rather than
/// through a vector's own buffer. Both name one element; each has its own way
/// of failing to.
pub fn write_slice_slot(
    values: &mut [Option<u32>],
    index: usize,
    value: u32,
    cursor: &mut u32,
) -> u32 {
    match values[counted_index(cursor, index)] {
        Some(ref mut slot) => {
            *slot = value;
            *slot
        }
        None => 0u32,
    }
}

// ── reading the same storage back, by value ───────────────────────────────

/// Read one element's payload back through the vector.
///
/// This answers what the vector holds, through the package, for a caller that
/// does not keep the vector in its own target-language storage. An element
/// that holds no payload has nothing to report and answers zero.
pub fn read_vec_payload(values: &Vec<Option<u32>>, index: usize) -> u32 {
    match values[index] {
        Some(payload) => payload,
        None => 0u32,
    }
}

/// Read one element's payload back through the slice, on the terms
/// `read_vec_payload` states.
pub fn read_slice_payload(values: &[Option<u32>], index: usize) -> u32 {
    match values[index] {
        Some(payload) => payload,
        None => 0u32,
    }
}

/// The element itself rather than a number read out of it.
///
/// A caller that builds its vector in target-language storage can compare this
/// answer against the optional it built, which is what says the element is a
/// real optional rather than a stand-in with a tag of its own. The payload is
/// read BY VALUE here — the arm binds a copy — so the element the caller owns
/// is left exactly as the write left it.
pub fn read_vec_entry(values: &Vec<Option<u32>>, index: usize) -> Option<u32> {
    match values[index] {
        Some(payload) => Some(payload),
        None => None,
    }
}

/// The element itself through the slice, on the terms `read_vec_entry` states.
pub fn read_slice_entry(values: &[Option<u32>], index: usize) -> Option<u32> {
    match values[index] {
        Some(payload) => Some(payload),
        None => None,
    }
}
