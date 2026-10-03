//! Ownership proofs for the elements of a FIXED-LENGTH array moved out.
//!
//! An array of owners is a WRAPPED owner: the array itself holds no allocation
//! of its own, and every byte it answers for belongs to one element standing in
//! it. Two claims therefore have to be settled separately, and neither settles
//! the other:
//!
//! - each element reaches its new owner as the allocation it already was, and
//!   exactly one owner releases it afterwards; and
//! - the array's own release frees whatever is still standing in it, and
//!   nothing that has already left.
//!
//! Every function here builds a `[String; 2]`, hands it to a callee BY VALUE,
//! and lets that callee take the elements out one at a time. The three callees
//! differ only in what happens to the elements afterwards, so the three
//! measurements in `test/array_wrapped_owner_consumer.zig` separate the claims
//! instead of restating them:
//!
//! - [`array_owner_elements`] moves both elements out and hands them back;
//! - [`array_owner_lengths`] moves both out and releases them here; and
//! - [`array_owner_first_element`] moves one out and leaves the other standing,
//!   so the array's own release has work left to do.
//!
//! A fixed-length array is also the one aggregate whose elements are addressed
//! by index, so an element leaves through `owners[0]` rather than through a
//! destructuring: `let [first, second] = owners;` is a SLICE PATTERN to the
//! parser, and it is refused as one rather than emitted as a copy that two
//! owners would then release.

/// Builds a fixed-length array of two owners and hands it, by value, to a
/// callee that takes both elements out and gives them back in a list.
///
/// The call moves the whole array, so the array literal this frame built is
/// empty once this function returns and the frame's release frees nothing. The
/// list comes back owning both elements, one allocation each, and the caller is
/// the only owner of either.
pub fn array_owner_elements() -> Vec<String> {
    let owners = [String::from("left"), String::from("right")];
    drain_elements(owners)
}

/// Builds the same array and hands it, by value, to a callee that takes both
/// elements out, measures them, and releases them itself.
///
/// Nothing survives the call except the number, so two allocations go in and two
/// come back out. That is the contrast that makes [`array_owner_elements`]'s
/// single release a measurement: the same two elements, the same array, and a
/// callee that owes a release for each of them instead of handing them on.
pub fn array_owner_lengths() -> usize {
    let owners = [String::from("left"), String::from("right")];
    measure_elements(owners)
}

/// Builds an array whose two elements have different lengths and different
/// bytes, and hands it, by value, to a callee that takes only the first one out.
///
/// The second element never leaves the callee, so the array's own release has
/// real work to do on exactly one element. A release that walked the whole array
/// regardless of what had already moved would free the element that left a
/// second time, and the caller would read freed bytes.
pub fn array_owner_first_element() -> String {
    let owners = [String::from("moved"), String::from("stayed")];
    take_first_element(owners)
}

/// Moves both elements out of the array it was handed and hands them on.
///
/// Each element leaves through its own index, so the array is left standing and
/// empty, and its release at the end of this call finds nothing to free. The
/// list returned here is what owns the two allocations afterwards.
fn drain_elements(owners: [String; 2]) -> Vec<String> {
    let first = owners[0];
    let second = owners[1];
    vec![first, second]
}

/// Moves both elements out of the array it was handed and measures them.
///
/// The bindings are released at the end of this call, which is where each
/// element's single release happens; the array's release runs afterwards and
/// finds both slots empty.
fn measure_elements(owners: [String; 2]) -> usize {
    let first = owners[0];
    let second = owners[1];
    first.len() + second.len()
}

/// Moves the first element out of the array it was handed and leaves the rest.
///
/// `owners` is partially moved on the way out: the first slot is empty and the
/// second still holds its own allocation, so the array's release frees exactly
/// one element here and the caller is left the only owner of the other.
fn take_first_element(owners: [String; 2]) -> String {
    owners[0]
}
