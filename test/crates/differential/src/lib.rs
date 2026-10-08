//! Differential ownership fixture.
//!
//! Every entry point here is ordinary, valid Rust and produces a value that
//! depends on nothing but its arguments: no clock, no addresses, no hashing,
//! and no unordered collection. That is what lets `test/differential_rust_oracle.rs`
//! and the generated Zig package be compared byte for byte — the Rust side runs
//! these functions through `#[path]`, the Zig side runs the same calls through
//! the translated module, and both print the canonical records
//! `test/differential_zig_oracle.zig` pins in `test/differential_consumer.zig`.
//!
//! The file is organised by the ownership shape under test, not by return
//! type. Several of them overlap on purpose: a move inside an `if` is both a
//! conditional move and an owner that lives in a nested scope, and the frame
//! that exits early owns the values its exits have to release.
//!
//! Nothing here carries a `#[test]` module, and nothing runs `cargo test` on
//! this crate: `tools/rust-corpus-oracle.sh` does not stage it, and `build.zig`
//! builds the Rust oracle with a plain `rustc --edition 2021 -O`, which strips
//! `#[test]` items. A test module here would therefore never run, while every
//! assertion in it is still an item the translator has to read and refuse.
//!
//! The Rust side of each claim below is checked by `test/differential_rust_oracle.rs`,
//! which includes this file with `#[path]` and calls these very functions.
//! `test/differential_zig_oracle.zig` prints the same records from the
//! translated package, `build.zig` compares the two stdout streams in Debug and
//! in ReleaseSafe, and `test/differential_consumer.zig` pins the bytes and
//! checks what the bytes cannot carry. Every claim above is either a record in
//! that stream or an assertion in that consumer; nothing here is checked only
//! by a test that never runs.

// ── inputs the caller owns ──────────────────────────────────────────────

/// A parameter the consumer builds and hands in, so the entry points below can
/// be called with an owner that existed before the call rather than one the
/// generated package built itself.
pub fn owned(input: &str) -> String {
    String::from(input)
}

// ── 1. owners in nested lexical, branch, match, loop and method scopes ──

/// The block builds an owner, uses it and ends, so that owner is released
/// while the one the block never saw is what the function hands on.
pub fn nested_lexical_owner() -> String {
    let carried = String::from("lexical");
    {
        let mut released = String::from("released");
        released.push('!');
    }
    carried
}

/// Three owners, three exit routes. The `if` arm moves the owner the block
/// created, the `match` arm moves a second one, and the fallback arm moves the
/// owner from outside the block — so two of the three are released inside the
/// block and whichever one was moved arrives whole.
pub fn nested_branch_owner(mode: u8) -> String {
    let lexical = String::from("lexical");
    let value = {
        let selected = String::from("selected");
        if mode == 0 {
            selected
        } else {
            let matched = String::from("matched");
            match mode {
                1 => matched,
                _ => lexical,
            }
        }
    };
    value
}

/// Every iteration builds one owner and releases it when the iteration ends,
/// and the owner built before the loop is released when the function returns.
/// Only the string the loop accumulated leaves.
pub fn nested_loop_owner(limit: u8) -> String {
    let carried = String::from("carried");
    let mut rounds = String::from("");
    let mut index = 0u8;
    while index < limit {
        let round = String::from(".");
        rounds.push_str(&round);
        index += 1;
    }
    rounds.push_str(&carried);
    rounds
}

/// A receiver that owns nothing: both of its fields are scalars, so the only
/// storage this case is about is what the methods build in their own frames.
/// No field has to be dropped with the receiver, and the by-value receiver
/// keeps the method boundary in the case.
pub struct ScopeOwner {
    pub tag: u8,
    pub joined: bool,
}

impl ScopeOwner {
    /// Builds two owners: one is moved out of an inner block on the selected
    /// arm and released there on the other, and the one that survives is
    /// released by the method frame when it returns.
    pub fn render(self, separator: &str) -> String {
        let mut text = String::from("c");
        text.push_str(separator);
        let selected = {
            let owner = String::from("r");
            if self.tag == 0 {
                owner
            } else {
                String::from("")
            }
        };
        text.push_str(&selected);
        text
    }

    /// The same shape with the arms decided by the other field and the
    /// separator spelled out here, so neither method can share a release with
    /// the other.
    pub fn joined(self) -> String {
        let mut text = String::from("r");
        text.push('-');
        let selected = {
            let owner = String::from("c");
            if self.joined {
                owner
            } else {
                String::from("")
            }
        };
        text.push_str(&selected);
        text
    }
}

/// The method boundary is where the method's own locals change hands, so this
/// frame builds the receiver and immediately calls across it.
pub fn nested_method_render(separator: &str) -> String {
    ScopeOwner {
        tag: 0,
        joined: false,
    }
    .render(separator)
}

/// The same receiver through the method whose arms the other field decides.
pub fn nested_method_joined() -> String {
    ScopeOwner {
        tag: 1,
        joined: true,
    }
    .joined()
}

/// The same method through the arm that releases the block-local owner instead
/// of moving it out, so `render`'s conditional move runs in both directions and
/// the wrapper keeps the Zig-side API of the pair identical.
pub fn nested_method_render_released(separator: &str) -> String {
    ScopeOwner {
        tag: 1,
        joined: true,
    }
    .render(separator)
}

/// The other method through its other arm, for the same reason.
pub fn nested_method_joined_released() -> String {
    ScopeOwner {
        tag: 0,
        joined: false,
    }
    .joined()
}

/// Two bindings with one source name, both live at once: the inner `s` shadows
/// the outer one, so whichever of the two a release is keyed by, the other
/// owner is still live when its frame ends.
pub fn shadowed_length() -> usize {
    let s = String::from("outer");
    let outer_len = s.len();
    {
        let s = String::from("inner-inner");
        outer_len + s.len()
    }
}

// ── 2. moves that depend on a branch ───────────────────────────────────

/// The parameter is the owner's only route out on the first arm and a value
/// the frame has to release on the second, so the caller keeps an owner only
/// when the first arm ran.
pub fn conditional_move_parameter(text: String, take: bool) -> String {
    let fallback = String::from("fallback");
    if take {
        text
    } else {
        fallback
    }
}

/// Each arm moves a different owner, so the two that were not selected have to
/// be released here rather than by the caller.
pub fn conditional_move_match(mode: u8, text: String) -> String {
    let first = String::from("first");
    let second = String::from("second");
    match mode {
        0 => text,
        1 => first,
        _ => second,
    }
}

/// A by-value owner parameter this frame only reads. Nothing is handed back,
/// so the caller owns nothing afterwards and the frame has to release exactly
/// what the caller built.
pub fn cleanup_only_text(text: String) -> usize {
    text.len()
}

/// The caller declared AFTER the callee it calls, so the callee's declaration
/// is the first of the pair the translator settles.
pub fn cleanup_only_caller_callee_first() -> usize {
    cleanup_only_text(String::from("foobar"))
}

/// The same call with the caller declared BEFORE the callee it calls. The
/// callee settles its emitted arguments from a fixed point taken before any
/// declaration is lowered, so this order is the one that decides whether the
/// caller hands over an allocator at all.
pub fn cleanup_only_caller_first() -> usize {
    cleanup_only_text_early(String::from("foobar"))
}

/// The second callee, declared after its own caller, so the file holds both
/// declaration orders for the same shape.
pub fn cleanup_only_text_early(text: String) -> usize {
    text.len()
}

// ── 3. overwrites whose right-hand side can fail ────────────────────────

/// Builds the replacement the overwrite assigns. It is a separate frame so the
/// failing path allocates nothing and hands nothing back.
fn build_collection(valid: bool) -> Result<Vec<String>, u8> {
    if valid {
        Ok(vec![String::from("replacement")])
    } else {
        Err(4u8)
    }
}

/// The owner already in `text` when the right-hand side runs is still owned by
/// this frame on the failing path, and the conversion that failed owns the
/// bytes it could not turn into text. Both have to be released there.
pub fn overwrite_from_utf8(held: &str, valid: bool) -> Result<String, u8> {
    let mut text = String::from(held);
    text = if valid {
        String::from_utf8(vec![b'o', b'k']).map_err(|_| 1u8)?
    } else {
        String::from_utf8(vec![b'b', 0xff]).map_err(|_| 2u8)?
    };
    Ok(text)
}

/// The vector holds one owner per element while the replacement is built, so a
/// failing replacement releases the elements it never replaces without
/// releasing the ones the successful replacement brought.
pub fn overwrite_collection(valid: bool) -> Result<Vec<String>, u8> {
    let mut owned = vec![String::from("first"), String::from("second")];
    owned = build_collection(valid)?;
    Ok(owned)
}

/// Both operands arrive as by-value owners. The frame holds one of them as a
/// local and the assignment releases it only after the replacement exists, so
/// a release that ran first would free the bytes the caller still reads.
pub fn overwrite_owner_params(first: String, second: String) -> String {
    let mut owned = first;
    owned = second;
    owned
}

/// The frame owns a string it releases on the way out while the cow that
/// crosses the boundary either borrows the caller's bytes or owns the repaired
/// ones. Which of the two it is depends on the input, and both are reachable.
pub fn nested_cow_text<'a>(prefix: &str, input: &'a [u8]) -> std::borrow::Cow<'a, str> {
    let mut released = String::from(prefix);
    released.push('-');
    if input.len() == released.len() {
        return std::borrow::Cow::Borrowed("same-length");
    }
    String::from_utf8_lossy(input)
}

/// The error that `String::from_utf8` hands back owns the bytes that failed to
/// validate, and `utf8_error` only borrows it, so the wrapper still owes a
/// release after the borrow has been read. The successful arm is the one that
/// shows the payload is untouched by the rule the failing arm needs.
pub fn utf8_error_detail(raw: &[u8]) -> usize {
    match String::from_utf8(raw.to_vec()) {
        Ok(text) => text.len(),
        Err(error) => error.utf8_error().valid_up_to(),
    }
}

// ── 4. frames that leave early ──────────────────────────────────────────

/// Two exits, and the frame owns a value at each of them: the checked exit
/// releases what the function built so far, and the fallible one releases the
/// value it built on the way to the return.
pub fn early_exit(checked: bool) -> Result<String, u8> {
    let carried = String::from("carried");
    if checked {
        return Err(1u8);
    }
    let mut released = String::from("released");
    released.push('!');
    Ok(carried)
}

/// The `?` leaves through a frame that already owns the string it built, and
/// the error it reports owns the bytes that failed the conversion.
pub fn fallible_exit(depth: u8) -> Result<String, u8> {
    let mut text = String::from("outer");
    {
        let inner = String::from("inner");
        text.push_str(&inner);
    }
    if depth == 0 {
        let payload = String::from_utf8(vec![0xff]).map_err(|_| 4u8)?;
        return Ok(payload);
    }
    let tail = String::from_utf8(vec![b't']).map_err(|_| 5u8)?;
    text.push_str(&tail);
    Ok(text)
}

/// Owners are declared before both exits inside the body. `stop_at` decides
/// whether the loop ends on its own condition or on the `break`, and
/// `skip_first` decides whether one iteration leaves through the `continue`;
/// the string and the vector the body built are released on every route,
/// including the one that hands nothing on.
pub fn loop_exit_owners(limit: u8, stop_at: u8, skip_first: bool) -> String {
    let carried = String::from("carried");
    let mut rounds = String::from("");
    let mut index = 0u8;
    while index < limit {
        let round = String::from(".");
        let mut marks: Vec<u8> = vec![b'.'];
        if skip_first && index == 0 {
            index += 1;
            continue;
        }
        if index >= stop_at {
            break;
        }
        marks.push(b'+');
        rounds.push_str(&round);
        index += 1;
    }
    rounds.push_str(&carried);
    rounds
}

/// The loop hands on one of two owners: the one built inside its body or the
/// one built outside it. The owner the loop did not take stays live in this
/// frame and is released here, whichever route ran.
pub fn loop_value_owner(limit: u8) -> String {
    let fallback = String::from("fallback");
    let mut index = 0u8;
    let value = loop {
        let round = String::from("round");
        index += 1;
        if index >= limit {
            break round;
        }
        break fallback;
    };
    value
}

// ── 5. an iterator run whose effects reach the caller's state ───────────

/// The predicate runs once per element and writes the step it is on into the
/// caller's counter, so the counter says how far the scan got even though the
/// result only carries the values that survived.
pub fn cursor_predicate_effects(input: &[u32], cursor: &mut u32) -> Vec<u32> {
    let mut calls = 0u32;
    let kept: Vec<u32> = input
        .iter()
        .copied()
        .filter(|value| {
            calls += 1;
            *cursor = *cursor * 10 + calls;
            *value % 2 == 1
        })
        .collect();
    kept
}

/// The map allocates every element before the predicate borrows it. Rejected
/// tags are released by the filter; retained tags move into the result.
pub fn cursor_owned_predicate(input: &[u32], cursor: &mut u32) -> Vec<String> {
    let mut calls = 0u32;
    let kept: Vec<String> = input
        .iter()
        .copied()
        .map(|value| {
            let mut tag = if value % 2 == 1 {
                String::from("item")
            } else {
                String::from("reject")
            };
            if value > 2 {
                tag.push('+');
            }
            tag
        })
        .filter(|tag| {
            calls += 1;
            *cursor = *cursor * 10 + calls;
            tag.len() <= 5
        })
        .collect();
    kept
}

// ── 6. generic calls whose instantiation the call site decides ──────────

/// One body, three owners: two parameters and one result. Whichever arm did
/// not run released its parameter inside this frame.
pub fn generic_owner_or<T>(first: T, second: T, take_first: bool) -> T {
    if take_first {
        first
    } else {
        second
    }
}

/// The same body reached with an owner, so the result is a string the caller
/// releases once and the parameter that lost is released here.
pub fn generic_string_or(take_first: bool) -> String {
    generic_owner_or(String::from("first"), String::from("second"), take_first)
}

/// The same body reached with a vector of owners. The surviving arm hands its
/// slab over whole and the discarded one frees its element and its slab.
pub fn generic_vector_or(take_first: bool) -> Vec<String> {
    generic_owner_or(vec![String::from("kept")], vec![String::from("lost")], take_first)
}

/// Nothing in the expression names the element type, so the type the local
/// binding declares is the only thing that decides the instantiation.
pub fn generic_context_only(present: bool) -> Option<Vec<u32>> {
    let collected: Option<Vec<u32>> = if present {
        Some((0u32..3).collect())
    } else {
        None
    };
    collected
}

// ── 7. hand-offs the record stream carries ───────────────────────────────

fn owner_scope_identity<T>(value: T) -> T {
    value
}

/// The generic callee consumes the concrete String rather than borrowing it.
pub fn owner_scope_generic_string() -> String {
    let value = String::from("generic-owner");
    owner_scope_identity(value)
}

/// A nested block moves the byte vector before its core-call consumer runs.
pub fn owner_scope_core_argument_block() -> String {
    let value = vec![b'a', b'b', b'c'];
    String::from_utf8({
        let bytes = value;
        bytes
    }).unwrap()
}

/// Push consumes its element, including when destination growth fails in Zig.
pub fn owner_scope_push_string() -> Vec<String> {
    let value = String::from("push-owner");
    let mut values: Vec<String> = vec![];
    values.push(value);
    values
}

/// The move closure owns its capture after the surrounding local is moved.
pub fn owner_scope_move_closure() -> String {
    {
        let value = String::from("capture-owner");
        let closure = move |_: ()| { value };
        closure(())
    }
}

/// Rust evaluates and releases the repeated owner even for zero elements.
pub fn owner_scope_repeat_zero(counter: &mut u32) -> Vec<String> {
    vec![{
        *counter += 1;
        String::from("repeat-owner")
    }; 0]
}

/// One element moves the evaluated owner without cloning it.
pub fn owner_scope_repeat_one(counter: &mut u32) -> Vec<String> {
    vec![{
        *counter += 1;
        String::from("repeat-owner")
    }; 1]
}

/// Two elements evaluate once, clone once and move the original once.
pub fn owner_scope_repeat_two(counter: &mut u32) -> Vec<String> {
    vec![{
        *counter += 1;
        String::from("repeat-owner")
    }; 2]
}

/// A scoped local must be taken once, not once per destination element.
pub fn owner_scope_repeat_local() -> Vec<String> {
    let value = String::from("repeat-local");
    vec![value; 2]
}

/// A tuple wrapper owns its string and carries a tag beside it, so repeating
/// one moves the string out of the wrapper: zero elements release it, one moves
/// it whole, and more clone it for every element but the last. The scan then
/// reads each string and tag through the wrapper without taking either out.
pub fn owner_tuple_repeat(count: usize) -> usize {
    let values: Vec<(String, u8)> = vec![(String::from("nested"), 7u8); count];
    let mut total = values.len();
    for entry in &values {
        total += entry.0.len() + entry.1 as usize;
    }
    total
}

/// The other side of the same runtime count. An element that owns nothing has
/// no bytes to clone and nothing to release, so the `usize` the caller picks
/// decides how many copies the destination holds and is the only thing it
/// decides. The element is still evaluated exactly once — a count of zero
/// stores nothing and the counter still moves — so the total is the length
/// plus the value the one evaluation produced, as many times as there are
/// slots.
pub fn owner_byte_repeat(count: usize, cursor: &mut u32) -> usize {
    let values: Vec<u8> = vec![{
        *cursor += 1;
        *cursor as u8
    }; count];
    let mut total = values.len();
    for byte in &values {
        total += *byte as usize;
    }
    total
}

/// Push consumes a tuple wrapper the way it consumes a bare string: the
/// destination takes the string and the tag together, including when growth
/// fails in Zig, and the scan reads them back through the stored wrapper.
pub fn owner_tuple_push() -> usize {
    let mut values: Vec<(String, u8)> = vec![];
    values.push((String::from("nested"), 7u8));
    let mut total = 0usize;
    for entry in &values {
        total += entry.0.len() + entry.1 as usize;
    }
    total
}

// ── dispatch shapes: a guard, a repeated selector, a borrowed payload ────

/// One slot of caller-owned storage. The payload is a plain variant field, so
/// the dispatch needs no binding of its own for the scrutinee and the arm's
/// `ref mut` points straight into the element the index named. The same write
/// through a scrutinee that has to be bound first is `optional_entry_write`
/// below.
///
/// Both variants are scalars, so nothing here has storage to release and the
/// case is about the reference the arm binds.
#[derive(Clone, Copy)]
pub enum Slot {
    Filled(u32),
    Empty,
}

/// The index and the counter travel together, so a caller can see that the
/// index expression ran exactly once per call rather than once per read.
fn counted_index(cursor: &mut u32, index: usize) -> usize {
    *cursor += 1;
    index
}

/// The guard decides between two arms that name the same selector, so the
/// second one has to stay reachable behind the first one's guard, and the
/// catch-all answers everything the literal did not cover.
pub fn guard_dispatch(x: u8, hit: bool) -> u8 {
    match x {
        1 if hit => 10u8,
        1 => 11u8,
        _ => 12u8,
    }
}

/// The scrutinee and the guard are both constants and the selector is
/// repeated, so only the arm behind the false guard can produce the answer:
/// dropping the guard would answer 10 and losing the second arm would have
/// nothing left to answer at all.
pub fn constant_guard_dispatch() -> u8 {
    match 7u8 {
        7 if false => 10u8,
        7 => 11u8,
        _ => 12u8,
    }
}

/// The scrutinee is an indexed expression whose index runs the caller's
/// counter, and three dispatches read it. The counter says whether the
/// expression ran once or once per dispatch, and the answer says which arm it
/// reached; the pair carries both back out.
pub fn guarded_index_dispatch(
    input: &[u8],
    index: usize,
    hit: bool,
    cursor: &mut u32,
) -> (u8, u32) {
    let answer: u8 = match input[counted_index(cursor, index)] {
        1 if hit => 10u8,
        1 => 11u8,
        _ => 12u8,
    };
    (answer, *cursor)
}

/// The storage is the caller's and the payload is bound by mutable reference,
/// so the arm writes into the caller's own element rather than into a copy of
/// it. The slot the call did not reach keeps the value it had, and the counter
/// says the index expression ran once.
///
/// The binding is spelled `ref mut` rather than borrowed from a `&mut`
/// scrutinee on purpose: the reference itself is what is under test here. A
/// scrutinee borrowed as `&mut slots[i]` would carry its payload by value
/// through default binding modes, which is a copy — so the write would stay in
/// this frame and the caller's element would never change.
pub fn optional_slot_write(
    slots: &mut [Slot],
    index: usize,
    value: u32,
    cursor: &mut u32,
) -> u32 {
    match slots[counted_index(cursor, index)] {
        Slot::Filled(ref mut slot) => {
            *slot = value;
            *slot
        }
        Slot::Empty => 0u32,
    }
}

/// Reads one slot's payload back, so a caller can see what a write left in the
/// storage it owns. An empty slot has no payload to report and answers zero.
pub fn slot_payload(slot: Slot) -> u32 {
    match slot {
        Slot::Filled(value) => value,
        Slot::Empty => 0u32,
    }
}

/// One element of caller-owned storage whose payload may be there or may not
/// be. The scrutinee is a real `Option`, so the dispatch binds the subject
/// itself and the arm's binding has to reach through that binding into the
/// caller's own element rather than into a copy the frame made of it. An
/// element with no payload has nothing to write and answers zero, the element
/// the call did not reach keeps what the caller built, and the counter says
/// the index expression ran once.
///
/// The binding is spelled `ref mut` on purpose: the reference itself is what
/// is under test here, over a scrutinee the dispatch has to bind before the
/// arm can reach it. `optional_slot_write` above binds the same way over a
/// plain variant field, so the two together are what say a reference binding
/// reaches the caller's element whatever the dispatch subject was.
pub fn optional_entry_write(
    entries: &mut [Option<u32>],
    index: usize,
    value: u32,
    cursor: &mut u32,
) -> u32 {
    match entries[counted_index(cursor, index)] {
        Some(ref mut entry) => {
            *entry = value;
            *entry
        }
        None => 0u32,
    }
}

/// Reads one element back, so a caller can see what the write left in the
/// storage it owns. An element with no payload has nothing to report and
/// answers zero.
pub fn optional_entry_value(entry: Option<u32>) -> u32 {
    match entry {
        Some(value) => value,
        None => 0u32,
    }
}

// ── ownership witnesses: the transfers nothing else reaches ─────────────

/// The subject is a temporary this frame never names, and the first arm binds
/// its payload and hands it to the caller. Those bytes have to cross as the
/// allocation the arm built: a release that missed the transfer frees them a
/// second time, and a transfer that never happened leaves the arm's payload
/// with no owner at all. The second arm binds no payload and builds its own,
/// so the release the refused arm owes is the one this frame performs.
pub fn owner_arm_payload_move(take: bool) -> String {
    match if take {
        Ok(String::from("moved"))
    } else {
        Err(3u8)
    } {
        Ok(inner) => inner,
        Err(_) => String::from("other"),
    }
}

/// The subject here is a local this frame owns, and the arm reads the payload
/// instead of moving it, so the frame owes exactly one release for the whole
/// union. A second one for the arm payload frees the same bytes twice.
pub fn owner_local_result_match(take: bool) -> usize {
    let result: Result<String, u8> = if take {
        Ok(String::from("held"))
    } else {
        Err(5u8)
    };
    match result {
        Ok(inner) => inner.len(),
        Err(code) => code as usize,
    }
}

/// Two bindings that share one source name and are both live at once, where
/// the inner one is the binding that moves. Its bytes have to reach the caller
/// as the allocation they already were, while the outer string is released
/// here: a move attributed to the outer handle frees bytes the returned value
/// still names. Reading both owners, as `shadowed_length` does, cannot say
/// which of the two a move belongs to.
pub fn shadowed_move_length() -> usize {
    let s = String::from("outer");
    let outer_len = s.len();
    let moved = {
        let s = String::from("inner-inner");
        s
    };
    outer_len + moved.len()
}

/// Two variants that both own a string, so a dispatch over this type has an
/// owned payload on every route it can take.
pub enum Labeled {
    Named(String),
    Bare(String),
}

/// The first arm reads the payload of the variant it names before it decides
/// whether to run at all, so the route where the guard refuses has to release
/// that string before the arm behind it runs — and that arm still owns it. A
/// release that fires on the refused route frees the string the following arm
/// reads, and one that never fires leaks it.
pub fn guarded_owned_payload(plain: bool, text: &str) -> usize {
    let subject = if plain {
        Labeled::Bare(String::from(text))
    } else {
        Labeled::Named(String::from(text))
    };
    match subject {
        Labeled::Named(value) if value.len() > 5 => value.len() + 1,
        Labeled::Named(_) => 0,
        Labeled::Bare(value) => value.len() * 10,
    }
}

/// A variant nested inside a tagged union, so the payload has to travel out
/// of the inner variant on the arm that selected it. Its other variant carries
/// a scalar instead of an owner, so the arm naming it owns nothing at all.
pub enum Payload {
    Text(String),
    Width(u8),
}

/// Three subjects, so every route out of the union is reachable and recorded:
/// the arm that matches the nested variant moves the string out of it, the arm
/// behind it owns nothing but the tag the union carries, and the error route
/// owns nothing either. The three routes release very differently, and the
/// width arm answers from its byte the same way the string arm answers from its
/// length.
pub fn nested_owned_payload(kind: u8) -> usize {
    let subject: Result<Payload, u8> = if kind == 0 {
        Ok(Payload::Text(String::from("nested")))
    } else if kind == 1 {
        Ok(Payload::Width(9u8))
    } else {
        Err(4u8)
    };
    match subject {
        Ok(Payload::Text(text)) => text.len() + 1,
        Ok(Payload::Width(width)) => width as usize + 1,
        Err(code) => code as usize + 1,
    }
}

/// The cow is a local this frame owns and the return moves it whole, so the
/// borrowed arm still names the caller's bytes after the call and the owned
/// arm still owns the slab it built rather than a borrow of the input.
pub fn cow_str_local_move(input: &[u8]) -> std::borrow::Cow<'_, str> {
    let cow = String::from_utf8_lossy(input);
    cow
}

/// The byte cow moves its local the same way, and both of its arms are
/// reachable: three bytes stay the caller's and anything else is copied into
/// storage the returned value owns.
pub fn cow_slice_local_move(input: &[u8]) -> std::borrow::Cow<'_, [u8]> {
    let cow = if input.len() == 3 {
        std::borrow::Cow::Borrowed(input)
    } else {
        std::borrow::Cow::Owned(input.to_vec())
    };
    cow
}

/// The conversion error owns the bytes that failed to validate, and the
/// failing arm hands that payload to the caller instead of dropping it here,
/// so the caller owes the release this frame does not perform.
pub fn utf8_error_handoff(raw: &[u8]) -> Result<String, std::string::FromUtf8Error> {
    let converted = String::from_utf8(raw.to_vec());
    match converted {
        Ok(text) => Ok(text),
        Err(error) => Err(error),
    }
}

/// Both elements are owners and the whole array crosses a call by value, so
/// each one has to arrive as the allocation it already was and each is
/// released on its own afterwards.
pub fn array_owner_move() -> [String; 2] {
    let owners = [String::from("first"), String::from("second")];
    owner_array_identity(owners)
}

/// The callee that consumes the array and hands it back whole, so the move
/// this case is about happens at a call boundary rather than at a return of
/// the frame that built the array.
fn owner_array_identity(owners: [String; 2]) -> [String; 2] {
    owners
}

/// Both payload fields own a string, so selecting either one leaves the other
/// field to be released without releasing the field the caller receives.
pub enum PairPayload {
    Pair(String, String),
    Absent,
}

/// A refused guard must leave both explicitly bound fields available to the
/// next arm; the absent variant has no fields to release.
pub fn owner_pair_payload(mode: u8, take_second: bool) -> String {
    let subject = if mode == 2 {
        PairPayload::Absent
    } else {
        PairPayload::Pair(String::from("first"), String::from("second"))
    };
    match subject {
        PairPayload::Pair(a, b) if take_second => b,
        PairPayload::Pair(a, b) => a,
        PairPayload::Absent => String::from("absent"),
    }
}

/// An owner is staged before a conditional scalar argument and another owner
/// is built afterwards, so neither owner belongs to the scalar's branch.
pub fn staged_scalar_owner_call(flag: bool) -> usize {
    let first = String::from("first");
    consume_staged_owners(first, if flag { 1 } else { 2 }, String::from("later"))
}

fn consume_staged_owners(first: String, n: u32, later: String) -> usize {
    first.len() + n as usize + later.len()
}

/// Each outer element moves into a helper before its scalar inner iterator
/// runs, so the iterator must not retain an owner the helper already consumed.
pub fn owner_flat_map_consume(count: u32) -> Vec<u32> {
    (0u32..count)
        .map(|_| String::from("x"))
        .flat_map(|s| 0u32..consume_flat_map_string(s))
        .collect()
}

fn consume_flat_map_string(s: String) -> u32 {
    s.len() as u32
}

/// The left element owns bytes while the right element borrows mutable source
/// storage; stopping at either iterator must preserve those distinct lifetimes.
pub fn owner_zip_mut<'a>(input: &'a mut [u32], count: u32) -> Vec<(String, &'a mut u32)> {
    (0u32..count)
        .map(|_| String::from("zip"))
        .zip(input.iter_mut())
        .collect()
}

/// Mapping the success arm discards its owned payload, while an error carries
/// only a scalar through unchanged.
pub fn owner_result_map(take: bool) -> Result<u32, u8> {
    let result: Result<String, u8> = if take {
        Ok(String::from("mapped"))
    } else {
        Err(7u8)
    };
    result.map(|_| 1u32)
}

/// Mapping the error arm discards its owned payload, while a success carries
/// only a scalar through unchanged.
pub fn owner_result_map_err(take: bool) -> Result<u32, u8> {
    let result: Result<u32, String> = if take {
        Ok(9u32)
    } else {
        Err(String::from("mapped-error"))
    };
    result.map_err(|_| 3u8)
}

/// The mapped owner is released but the error owner travels to the caller.
pub fn owner_result_map_passthrough(take: bool) -> Result<u32, String> {
    let result: Result<String, String> = if take {
        Ok(String::from("mapped"))
    } else {
        Err(String::from("kept-error"))
    };
    result.map(|_| 1u32)
}

/// The mapped error owner is released but the success owner travels onward.
pub fn owner_result_map_err_passthrough(take: bool) -> Result<String, u8> {
    let result: Result<String, String> = if take {
        Ok(String::from("kept-ok"))
    } else {
        Err(String::from("mapped-error"))
    };
    result.map_err(|_| 3u8)
}

/// The success owner arrives through a by-value parameter before it is mapped.
pub fn owner_result_map_parameter(result: Result<String, u8>) -> Result<u32, u8> {
    result.map(|_| 1u32)
}

/// The error owner arrives through a by-value parameter before it is mapped.
pub fn owner_result_map_err_parameter(result: Result<u32, String>) -> Result<u32, u8> {
    result.map_err(|_| 3u8)
}

/// A by-value receiver releases its mapped owner and transfers its error owner.
pub fn owner_result_map_passthrough_parameter(
    result: Result<String, String>,
) -> Result<u32, String> {
    result.map(|_| 1u32)
}

/// A by-value receiver releases its mapped error and transfers its success.
pub fn owner_result_map_err_passthrough_parameter(
    result: Result<String, String>,
) -> Result<String, u8> {
    result.map_err(|_| 3u8)
}

/// Copying a generic scalar through a local must not add an allocator boundary.
pub fn generic_copy_local<T: Copy>(value: T) -> T {
    let kept = value;
    kept
}

trait CopyRoot: Copy {}

trait CopyLeaf: CopyRoot {}

impl CopyRoot for u32 {}
impl CopyRoot for u8 {}
impl CopyLeaf for u32 {}
impl CopyLeaf for u8 {}

/// The Copy guarantee also reaches this local through two supertrait edges.
pub fn generic_transitive_copy_local<T: CopyLeaf>(value: T) -> T {
    let kept = value;
    kept
}

pub fn copy_local_u32(value: u32) -> u32 {
    generic_copy_local(value)
}

pub fn copy_local_u8(value: u8) -> u8 {
    generic_copy_local(value)
}

pub fn transitive_copy_local_u32(value: u32) -> u32 {
    generic_transitive_copy_local(value)
}

pub fn transitive_copy_local_u8(value: u8) -> u8 {
    generic_transitive_copy_local(value)
}

/// An early source Err releases the String in the partially initialized tuple.
pub fn owner_tuple_try(accept: bool) -> Result<(String, u32), u8> {
    Ok((String::from("held"), scalar_result(accept)?))
}

fn scalar_result(accept: bool) -> Result<u32, u8> {
    if accept {
        Ok(7u32)
    } else {
        Err(2u8)
    }
}

/// Signed division truncates toward zero; the remainder keeps the dividend's sign.
/// Primitive compound assignment evaluates the RHS before the assignee.
pub fn primitive_compound_order() -> (isize, isize, u32) {
    let mut values = [-9isize];
    let mut counter = 0u32;
    values[compound_index(&mut counter, 2u32)] /= compound_divisor(&mut counter, 1u32);
    let quotient = values[0];
    values[0] = -9isize;
    values[compound_index(&mut counter, 4u32)] %= compound_divisor(&mut counter, 3u32);
    (quotient, values[0], counter)
}

fn compound_index(counter: &mut u32, digit: u32) -> usize {
    *counter = *counter * 10 + digit;
    0usize
}

fn compound_divisor(counter: &mut u32, digit: u32) -> isize {
    *counter = *counter * 10 + digit;
    2isize
}

/// A projected sibling may own a String or carry no payload.
pub enum ProjectedShape {
    Solo(String),
    Empty,
}

/// The tuple carrier owns both the shape sibling and the selected String.
pub enum ProjectedCarrier {
    Payload((ProjectedShape, String)),
}

/// A nested shape stays in its source carrier until its owned leaf is moved.
pub enum ProjectedNode {
    Nested(ProjectedShape),
    Absent,
}

/// Moving the selected tuple field still releases its owning shape sibling.
pub fn owner_projected_pair(empty: bool) -> String {
    let carrier = if empty {
        ProjectedCarrier::Payload((ProjectedShape::Empty, String::from("selected-empty")))
    } else {
        ProjectedCarrier::Payload((
            ProjectedShape::Solo(String::from("sibling")),
            String::from("selected-solo"),
        ))
    };
    match carrier {
        ProjectedCarrier::Payload(pair) => pair.1,
    }
}

/// Only the successful nested if-let transfers an owned leaf from its carrier.
pub fn owner_nested_iflet(mode: u8) -> String {
    let node = if mode == 0 {
        ProjectedNode::Nested(ProjectedShape::Solo(String::from("nested")))
    } else if mode == 1 {
        ProjectedNode::Nested(ProjectedShape::Empty)
    } else {
        ProjectedNode::Absent
    };
    match node {
        ProjectedNode::Nested(inner) => if let ProjectedShape::Solo(text) = inner {
            text
        } else {
            String::from("fallback")
        },
        ProjectedNode::Absent => String::from("absent"),
    }
}

/// The sibling stays owned by the fresh outer carrier during Option inspection.
pub enum ProjectedOptionInner {
    Hold(String),
}

pub enum ProjectedOptionOuter {
    Bundle((Option<String>, ProjectedOptionInner)),
}

/// Repeated shared leaf borrows leave the Some allocation in its carrier.
pub fn owner_projected_option_borrow_twice() -> usize {
    let outer = ProjectedOptionOuter::Bundle((
        Some(String::from("abc")),
        ProjectedOptionInner::Hold(String::from("sibling")),
    ));
    match outer {
        ProjectedOptionOuter::Bundle(pair) => {
            let first = if let Some(text) = &pair.0 {
                text.len()
            } else {
                0
            };
            let second = if let Some(text) = &pair.0 {
                text.len()
            } else {
                0
            };
            first + second
        },
    }
}

/// A nonmatching None inspector leaves the Some leaf available for a borrow.
pub fn owner_projected_option_none_inspection() -> usize {
    let outer = ProjectedOptionOuter::Bundle((
        Some(String::from("abc")),
        ProjectedOptionInner::Hold(String::from("sibling")),
    ));
    match outer {
        ProjectedOptionOuter::Bundle(pair) => {
            if let None = pair.0 {
                return 0;
            }
            if let Some(text) = &pair.0 {
                text.len()
            } else {
                0
            }
        },
    }
}

/// Moving the Option leaf retains its allocation and releases the inner sibling.
pub fn owner_projected_option_move(input: String) -> String {
    let outer = ProjectedOptionOuter::Bundle((
        Some(input),
        ProjectedOptionInner::Hold(String::from("sibling")),
    ));
    match outer {
        ProjectedOptionOuter::Bundle(pair) => match pair.0 {
            Some(text) => text,
            None => String::new(),
        },
    }
}

mod source_namespace {
    pub struct String {
        pub value: u32,
    }

    impl String {
        pub fn new() -> Self {
            Self { value: 41 }
        }
    }
}

pub fn source_string_constructor_value() -> u32 {
    source_namespace::String::new().value
}

// ── how the Rust side of every claim above is checked ─────────────────────

// There is no `#[test]` module here and nothing runs `cargo test` on this
// crate, so a test module would never run while every assertion in it is still
// an item the translator has to read and refuse. What stands in its place is
// stronger than a `#[test]` could be: `test/differential_rust_oracle.rs` calls
// these very functions through `#[path]` and prints a record per case,
// `test/differential_zig_oracle.zig` prints the same records from the
// translated package, `build.zig` compares the two stdout streams in Debug and
// in ReleaseSafe, and `test/differential_consumer.zig` pins those bytes and
// checks the addresses the bytes cannot carry. Every claim above is either a
// record in that stream or an assertion in that consumer, and none of them
// rests on a test that does not run.
