//! Closure capture ownership: what a captured value becomes, and who releases
//! it.
//!
//! Every frame here builds an owned `String`, captures it by value, and then
//! lets the frame end without touching the captured binding again. Each shape
//! is a different way a capture can come to own storage, so a release that is
//! missing, run twice, or aimed at the wrong binding shows up in the allocator
//! the caller supplies rather than in the value the frame returns.

// A `move` closure takes its capture by value when it is created and only
// borrows it in the body. The frame reads one capture through two calls, so the
// same captured string has to survive the first call and reach the second one.
// One capture, two calls, one release: the value the second call reads has to be
// the copy the capture owns, and that copy has to still be holding its
// allocation.
pub fn move_capture_len_twice(input: &str, extra: usize) -> usize {
    let owned = String::from(input);
    let measure = move |bonus: usize| owned.len() + bonus;
    measure(extra) + measure(extra + 1)
}

// A `move` closure that gives its capture back out. The capture leaves the
// closure, so the release the capture was given has to find nothing left to
// free, and the caller becomes the single owner of the allocation. A release
// that ran anyway would free storage the caller still holds, and one that never
// ran would leak it.
pub fn move_capture_handover(input: &str, tag: u32) -> String {
    let owned = String::from(input);
    let hand_over = move |_: u32| owned;
    hand_over(tag)
}

// No `move` here, and the capture is still by value: the body moves it out
// through `into_bytes`, which takes `self` by value, so the closure owns the
// capture from the moment it is created. This is the shape where the capture
// snapshot the lowering introduces is the only owner until the closure empties
// it.
pub fn consumed_capture_into_bytes(input: &str, tag: u32) -> Vec<u8> {
    let owned = String::from(input);
    let extract = |_: u32| owned.into_bytes();
    extract(tag)
}

// Two captures in one frame, both created from a `move` closure, both read by
// one call. The second capture's construction is the point: if it fails, the
// first capture and the first frame binding both owe a release, and neither may
// release the other's storage.
pub fn two_owned_captures(left: &str, right: &str) -> usize {
    let first = String::from(left);
    let second = String::from(right);
    let first_len = move |_: u32| first.len();
    let second_len = move |_: u32| second.len();
    first_len(0) + second_len(0)
}