//! Ownership proofs for a field moved OUT of the value that held it.
//!
//! Two spellings of the same move live here, and each leaves its holder
//! drained behind the field that left:
//!
//! - [`split_record`] moves the owned field out through a `let` destructuring.
//! - [`Bag::into_label`] moves it out through a method that takes `self` by
//!   value.
//!
//! Every route here has to answer one question: does the holder's own release
//! free the field that already left? `test/struct_field_owner_consumer.zig`
//! counts allocations and deallocations around both routes, so "released once"
//! is a measured count rather than a reading of the emitted text.
//!
//! The record [`split_record`] destructures is a tuple, because a tuple is the
//! aggregate whose fields this pipeline tracks one at a time. Moving a field
//! out of a NAMED struct is a different construct, and `let Bag { label, .. } =
//! bag;` is refused rather than emitted: no release follows a foreign named
//! struct, so an emitted one would free the moved field a second time.
//!
//! A record the pipeline hands back is therefore consumed through the field
//! that leaves it. `dropTemporary` on a `Bag` frees nothing, because the
//! runtime discovers no destructor for a foreign named struct.

/// A struct whose first field owns heap storage and whose second does not.
pub struct Bag {
    /// The owned field: one allocation this struct is responsible for.
    pub label: String,
    /// A `Copy` field, so whatever moves out of the struct never has to
    /// release it.
    pub count: u32,
}

impl Bag {
    /// Bytes held by the owned field, read through a borrow.
    ///
    /// `&self` borrows the record, so the field is still owned by the struct
    /// when this returns and the struct still owes the release.
    pub fn label_len(&self) -> usize {
        self.label.len()
    }

    /// Moves the owned field out through a `self` taken by value.
    ///
    /// `self` is the whole struct and the field leaves it, so the partially
    /// moved `self` this method drops on the way out still carries `count`,
    /// which owns nothing, and no longer carries `label`. The caller is the
    /// label's only owner afterwards and releases it exactly once.
    pub fn into_label(self) -> String {
        self.label
    }
}

/// Builds a `Bag` whose owned field the caller takes over.
///
/// Nothing is released here. The returned record is the label's only owner, so
/// the caller either moves the field out through [`Bag::into_label`] or keeps
/// the record and releases the field itself.
pub fn owned_bag(label: &str, count: u32) -> Bag {
    Bag {
        label: String::from(label),
        count,
    }
}

/// Moves one owned field out of a record through a `let` destructuring.
///
/// The destructuring binds both fields, so each binding takes its slot out of
/// `record` and the record itself owns nothing when the scope ends. `kept` still
/// owns a string there, so its own release is the one that frees inside this
/// call. `moved` leaves as the return value, so its release finds nothing and
/// the caller is the one owner left.
///
/// The count the record allocated and the count the call freed differ by
/// exactly the field that left, and that is the whole claim: the record's own
/// release found nothing to free, and neither did the release on the binding
/// that handed its field back out.
pub fn split_record(label: &str, note: &str) -> String {
    let record = (String::from(label), String::from(note));
    let (moved, kept) = record;
    moved
}

/// Reads both field lengths out of a record and lets the record go whole.
///
/// The destructuring drains the record here too, but neither field leaves the
/// call, so both bindings are still full when the scope ends. Two allocations
/// go in and two come back out, and that contrast is what makes
/// [`split_record`]'s single release a measurement rather than an assumption.
pub fn record_field_lengths(label: &str, note: &str) -> (usize, usize) {
    let record = (String::from(label), String::from(note));
    let (moved, kept) = record;
    (moved.len(), kept.len())
}