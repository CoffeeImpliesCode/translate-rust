//! shadowed-inner-owner — a fixture for a shadowed inner owner.
//!
//! Every entry point binds an owned value, opens an inner scope that binds the
//! SAME NAME to a different owned value, moves the inner one out of that scope,
//! and returns the outer one. In the two same-type frames the two payloads are
//! also the same length, so nothing but the bytes can tell the owners apart: a
//! release or a move attributed to the wrong one of the two bindings that share
//! a source name shows up as the wrong payload, as two owners of one
//! allocation, or as a leak.
//!
//! Two of the frames return the outer value ALONE, so the inner one the frame
//! still owes is observable only through the testing allocator: a release that
//! never runs leaks, and one that runs twice frees memory the caller still
//! holds. The other two hand BOTH values back in a fixed order, which is what
//! says the move belonged to the inner binding and not the outer one.
//!
//! The last two frames shadow the outer name with a `Vec<u8>` rather than a
//! `String`, so the two owners that collide do not even share a release. Their
//! payloads differ in length, which is deliberate: a `String` and a vector are
//! told apart by their type as well as their bytes, so these frames carry the
//! distinct-type case and the first two carry the same-type one.

/// Both values, outer first.
///
/// The inner binding is the one that moves, and it crosses the scope boundary
/// that declared the outer binding of the same name, so the frame holds two
/// owners called `owner` at the same moment. Element zero is the outer value
/// and element one is the moved inner one: a move attributed to the outer
/// handle would hand them back the other way round, or alias them onto one
/// allocation.
pub fn shadowed_move_pair() -> Vec<String> {
    let owner = String::from("outer-owner");
    let moved = {
        let owner = String::from("inner-inner");
        owner
    };
    vec![owner, moved]
}

/// The outer value alone, with the moved inner one released by this frame.
///
/// The inner owner is read before the frame ends so the binding is not merely
/// unused, and it is released here rather than by the caller — which is the
/// only witness of that release, since the caller receives the outer value and
/// nothing else. A release that reached the outer handle instead would free the
/// bytes this function returns.
pub fn shadowed_outer_returned() -> String {
    let owner = String::from("outer-owner");
    let moved = {
        let owner = String::from("inner-inner");
        owner
    };
    let _length = moved.len();
    owner
}

/// The moved inner one, of a DIFFERENT type from the outer one it shadows.
///
/// The inner binding is a `Vec<u8>` and the outer one is a `String`, so the two
/// owners share a source name and nothing else. The vector travels to the
/// caller and this frame releases the string it was declared beside, so the
/// two release routes are as different as the two types are.
pub fn shadowed_distinct_type_moved() -> Vec<u8> {
    let owner = String::from("outer-owner");
    let moved = {
        let owner: Vec<u8> = vec![b'i', b'n', b'n', b'e', b'r'];
        owner
    };
    let _outer_length = owner.len();
    moved
}

/// The outer value alone, with a moved inner one of a DIFFERENT type released
/// by this frame.
///
/// The inner binding is a `Vec<u8>`: an owner whose release is not a
/// `String` release, reached through the same source name as the `String` the
/// frame returns. The payload the caller reads is what says the returned owner
/// is the outer one; the allocator is what says the vector was released once.
pub fn shadowed_distinct_type_outer_returned() -> String {
    let owner = String::from("outer-owner");
    let moved = {
        let owner: Vec<u8> = vec![b'i', b'n', b'n', b'e', b'r'];
        owner
    };
    let _length = moved.len();
    owner
}

#[test]
fn the_outer_value_is_the_one_that_comes_back() {
    assert_eq!(shadowed_outer_returned(), "outer-owner");
    assert_eq!(shadowed_distinct_type_outer_returned(), "outer-owner");
}

#[test]
fn the_inner_value_is_the_one_that_moves() {
    assert_eq!(
        shadowed_move_pair(),
        vec![String::from("outer-owner"), String::from("inner-inner")]
    );
    assert_eq!(
        shadowed_distinct_type_moved(),
        vec![b'i', b'n', b'n', b'e', b'r']
    );
}
