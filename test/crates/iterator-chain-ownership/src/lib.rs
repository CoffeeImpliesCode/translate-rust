//! Ownership across the iterator adapters: what each one produces, and who is
//! left holding it.
//!
//! Every function here is one adapter over a borrowed source, collecting into a
//! `Vec`. The `map` at the end of each chain is what builds the owner, so the
//! claim each function makes is the one the adapter in front of it can make:
//! whether the adapter's own intermediate owns storage, and what the frame is
//! therefore holding when it hands the collection back.
//!
//! The rule the whole fixture rests on: the adapter under test never holds an
//! owner. A `filter` drops a `u32`, a `zip` pairs two `u32`s, an `enumerate`
//! pairs a `usize` with a `u32`, and a `chunks_exact` window is a borrow of the
//! caller's slice. Each of those intermediates is `Copy` or borrowed, so the
//! frame owes no release for any of them, and the only allocations live are
//! the owner the `map` built and the slab the collection grew. A lowering that
//! released a dropped element, released an owner it had already deposited, or
//! released a borrowed window would change what the caller still owns, and
//! `test/iterator_chain_consumer.zig` counts exactly that.
//!
//! There is no `#[test]` module here and nothing runs `cargo test` on this
//! crate, so a test module would be items the translator has to read and that
//! never execute. What checks every claim below is
//! `test/iterator_chain_consumer.zig`, which drives the translated package
//! under an allocator that records how many times each allocation was
//! released, and reads the staged package's own declarations through Zig types
//! rather than through its emitted text.
//!
//! Every function builds at most eight elements. The collection grows its slab
//! in steps, so a short chain leaves exactly one slab behind and a long one
//! leaves a history of slabs already released; the counts below depend on the
//! first of those two facts and not on the second.

// ── 1. `map` produces an owned value ───────────────────────────────────────

/// One owner per element, and the collection is what holds them when the frame
/// is done.
///
/// This is the shape every other function here is a variation of, so it carries
/// the claim the rest are read against: the `map` builds an owner, the owner
/// moves into the collection, and the frame's own release has nothing left to
/// free. Each element's text is chosen from the element that produced it, so a
/// chain that dropped one, reordered two, or aliased them onto one allocation
/// fails on the bytes rather than only on the length.
///
/// Two elements whose text matches still hold separate allocations. That is the
/// difference between handing an owner over and handing a pointer at one over,
/// and only the allocator can tell them apart.
pub fn mapped_owners(input: &[u32]) -> Vec<String> {
    input
        .iter()
        .copied()
        .map(|value| {
            if value % 2 == 0 {
                String::from("even")
            } else {
                String::from("odd")
            }
        })
        .collect()
}

// ── 2. `filter` drops one element ──────────────────────────────────────────

/// The filter rejects the elements a modulus of three divides, and the `map`
/// behind it builds one owner for each survivor.
///
/// The dropped element is a `u32` the caller's slice produced, so the filter
/// discards a copy and the frame owes no release for it. That is the whole
/// claim: the survivors' owners are the only storage the frame is holding when
/// it returns, and the number of them is the number the predicate kept.
///
/// An input the predicate rejects entirely is the boundary that makes the count
/// meaningful. Nothing is built, nothing is deposited, and the collection
/// never grows a slab at all, so the frame hands back an empty collection that
/// owns nothing.
pub fn filtered_owners(input: &[u32]) -> Vec<String> {
    input
        .iter()
        .copied()
        .filter(|value| *value % 3 != 0)
        .map(|value| {
            if value % 2 == 0 {
                String::from("even")
            } else {
                String::from("odd")
            }
        })
        .collect()
}

// ── 3. `zip` pairs two sources ─────────────────────────────────────────────

/// Two slices zipped element by element, with one owner built from each pair.
///
/// `zip` runs out at the shorter side, so the left side carrying more elements
/// than the right is the case that says whether the pair was taken by position
/// or by re-reading the right side. The owner an element gets records whether
/// the left value of that position was below the right value, so a zip that
/// paired the wrong two, or reused one side, leaves different bytes behind
/// rather than the same count.
///
/// Neither side owns anything here: both are borrows of the caller's slices, so
/// the only owner the frame holds is the one the `map` built.
pub fn zipped_owners(left: &[u32], right: &[u32]) -> Vec<String> {
    left.iter()
        .copied()
        .zip(right.iter().copied())
        .map(|(first, second)| {
            if first < second {
                String::from("ascending")
            } else {
                String::from("descending")
            }
        })
        .collect()
}

// ── 4. `enumerate` numbers the elements ────────────────────────────────────

/// The counter the `enumerate` puts beside each element decides the owner that
/// element gets.
///
/// The predicate compares the value against its own position, so the text an
/// element receives is a claim about the number that was paired with it. A
/// counter that started at one, that never advanced, or that advanced twice
/// moves which elements read `aligned` and which read `shifted`, and no count
/// check can see that.
///
/// The counter is a `usize` and the value a `u32`, so the pair is two scalars
/// and the frame owns nothing until the `map` runs. The length of the result is
/// the input's length, which says that numbering skipped nothing and numbered
/// nothing twice.
pub fn numbered_owners(input: &[u32]) -> Vec<String> {
    input
        .iter()
        .copied()
        .enumerate()
        .map(|(index, value)| {
            if value == index as u32 {
                String::from("aligned")
            } else {
                String::from("shifted")
            }
        })
        .collect()
}

// ── 5. `chunks_exact` yields borrowed windows ──────────────────────────────

/// Whole windows of two bytes, and one owner per window.
///
/// `chunks_exact` keeps a partial tail back rather than yielding it, so the
/// input is longer than a whole number of windows on purpose: the tail byte is
/// in the caller's slice and must not appear in any window, and the collection
/// holds one element fewer than a `chunks` of the same size would have given.
///
/// The window is a borrow of the caller's bytes, and the text an element
/// receives is a claim about the two bytes that window covered. A frame that
/// released the window would free storage the caller still holds, and one that
/// built the element by aliasing the window instead of copying it would leave
/// the caller reading a vector whose bytes are its own slice. Neither shows up
/// as a length.
pub fn window_owners(input: &[u8]) -> Vec<String> {
    input
        .chunks_exact(2)
        .map(|pair| {
            if pair[0] == pair[1] {
                String::from("twin")
            } else {
                String::from("mixed")
            }
        })
        .collect()
}

// ── 6. `collect` builds the collection ─────────────────────────────────────

/// The terminal on its own: a range of `count` elements, one owner each.
///
/// The adapters above all put something in front of the `collect`. This one
/// puts nothing there, so the claim is the collection's own: each owner the map
/// built is deposited exactly once, the slab the list grew is a separate
/// allocation from every element it holds, and a range that yields nothing
/// leaves a collection that owns nothing at all.
///
/// A `count` of zero is the boundary the other five cannot reach, because they
/// all take their elements from a slice the caller built.
pub fn collected_owners(count: u32) -> Vec<String> {
    (0u32..count)
        .map(|value| {
            if value == 0 {
                String::from("start")
            } else {
                String::from("step")
            }
        })
        .collect()
}
