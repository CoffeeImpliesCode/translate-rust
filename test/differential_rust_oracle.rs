//! The Rust half of the differential pair.
//!
//! `test/differential_zig_oracle.zig` prints the canonical records for
//! `test/crates/differential/src/lib.rs` by calling the translated Zig
//! package; this program prints the same records by calling the Rust
//! functions themselves, so the two stdout streams can be compared byte for
//! byte. The fixture is included with `#[path]` rather than compiled as a
//! separate crate, so every record below comes from the function the generated
//! package also has to provide — there is no copy of the logic here and no
//! expectation about what the translation "should" say.
//!
//! The record format is one `key=value` line per case:
//!
//!   * `key=hex` — the bytes an owner carries, two lowercase hex digits per
//!     byte with no separator, so a repaired `Cow` is as printable as a
//!     literal.
//!   * `key=tag:value` — `ok:`/`err:` for a `Result`, `borrowed:`/`owned:`
//!     for a `Cow`.
//!   * `key=1,2,3` — decimal elements of a `Vec<u32>`, or hex payloads joined
//!     by commas for a `Vec<String>`.
//!   * `key=none` — the arm that produced no value.
//!   * `key=a,b` — a decimal answer beside the counter that observed it, which
//!     is what says a side-effecting expression ran exactly once.
//!
//! Nothing here depends on the host: no pointer, width, endianness or hash
//! reaches a record, so the same bytes come out of any target.

#![allow(dead_code)]

#[path = "crates/differential/src/lib.rs"]
mod differential;

use std::borrow::Cow;

/// Two lowercase hex digits per byte, no separator and no prefix.
fn hex(bytes: &[u8]) -> String {
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for &byte in bytes {
        encoded.push(char::from_digit(u32::from(byte >> 4), 16).unwrap());
        encoded.push(char::from_digit(u32::from(byte & 0x0f), 16).unwrap());
    }
    encoded
}

/// Decimal elements joined by commas, which is empty for an empty vector.
fn numbers(values: &[u32]) -> String {
    values
        .iter()
        .map(|value| value.to_string())
        .collect::<Vec<String>>()
        .join(",")
}

/// The payloads of an owned vector, hex encoded and joined the same way.
fn hex_list(values: &[String]) -> String {
    values
        .iter()
        .map(|value| hex(value.as_bytes()))
        .collect::<Vec<String>>()
        .join(",")
}

fn line(out: &mut String, key: &str, value: &str) {
    out.push_str(key);
    out.push('=');
    out.push_str(value);
    out.push('\n');
}

/// A decimal answer beside the counter that observed it, which is what says a
/// side-effecting expression ran exactly once.
fn count_pair_line(out: &mut String, key: &str, answer: usize, counter: u32) {
    line(out, key, &format!("{},{}", answer, counter));
}

fn hex_line(out: &mut String, key: &str, bytes: &[u8]) {
    line(out, key, &hex(bytes));
}

fn string_result_line(out: &mut String, key: &str, result: Result<String, u8>) {
    match result {
        Ok(value) => line(out, key, &format!("ok:{}", hex(value.as_bytes()))),
        Err(code) => line(out, key, &format!("err:{}", code)),
    }
}

fn string_list_result_line(out: &mut String, key: &str, result: Result<Vec<String>, u8>) {
    match result {
        Ok(values) => line(out, key, &format!("ok:{}", hex_list(&values))),
        Err(code) => line(out, key, &format!("err:{}", code)),
    }
}

/// The tag is part of the record: a borrow of the caller's bytes and an owner
/// of repaired ones are different answers to the same call.
fn cow_line(out: &mut String, key: &str, value: Cow<'_, str>) {
    match value {
        Cow::Borrowed(bytes) => line(out, key, &format!("borrowed:{}", hex(bytes.as_bytes()))),
        Cow::Owned(text) => line(out, key, &format!("owned:{}", hex(text.as_bytes()))),
    }
}

/// The same tag for the byte cow: a borrow of the caller's bytes and an owner
/// of copied ones are different answers to the same call.
fn byte_cow_line(out: &mut String, key: &str, value: Cow<'_, [u8]>) {
    match value {
        Cow::Borrowed(bytes) => line(out, key, &format!("borrowed:{}", hex(bytes))),
        Cow::Owned(bytes) => line(out, key, &format!("owned:{}", hex(&bytes))),
    }
}

/// The failing arm hands the error to the caller rather than dropping it, so
/// the record says where the invalid sequence starts: an error that had lost
/// its bytes could not report a position in them.
fn utf8_handoff_line(
    out: &mut String,
    key: &str,
    value: Result<String, std::string::FromUtf8Error>,
) {
    match value {
        Ok(text) => line(out, key, &format!("ok:{}", hex(text.as_bytes()))),
        Err(error) => line(out, key, &format!("err:{}", error.utf8_error().valid_up_to())),
    }
}

fn main() {
    let mut out = String::new();
    out.push_str("format=differential-records-v1\n");

    // 1. owners in nested scopes.
    hex_line(
        &mut out,
        "nested_lexical",
        differential::nested_lexical_owner().as_bytes(),
    );
    hex_line(
        &mut out,
        "nested_branch_0",
        differential::nested_branch_owner(0).as_bytes(),
    );
    hex_line(
        &mut out,
        "nested_branch_1",
        differential::nested_branch_owner(1).as_bytes(),
    );
    hex_line(
        &mut out,
        "nested_branch_2",
        differential::nested_branch_owner(2).as_bytes(),
    );
    hex_line(
        &mut out,
        "nested_loop_0",
        differential::nested_loop_owner(0).as_bytes(),
    );
    hex_line(
        &mut out,
        "nested_loop_3",
        differential::nested_loop_owner(3).as_bytes(),
    );
    hex_line(
        &mut out,
        "nested_method_render",
        differential::nested_method_render("|").as_bytes(),
    );
    hex_line(
        &mut out,
        "nested_method_joined",
        differential::nested_method_joined().as_bytes(),
    );
    line(
        &mut out,
        "shadowed",
        &differential::shadowed_length().to_string(),
    );

    // 2. moves that depend on a branch.
    hex_line(
        &mut out,
        "conditional_move_taken",
        differential::conditional_move_parameter(String::from("given"), true).as_bytes(),
    );
    hex_line(
        &mut out,
        "conditional_move_released",
        differential::conditional_move_parameter(String::from("given"), false).as_bytes(),
    );
    for mode in 0..3u8 {
        hex_line(
            &mut out,
            &format!("conditional_match_{}", mode),
            differential::conditional_move_match(mode, String::from("given")).as_bytes(),
        );
    }
    line(
        &mut out,
        "cleanup_only_callee_first",
        &differential::cleanup_only_caller_callee_first().to_string(),
    );
    line(
        &mut out,
        "cleanup_only_caller_first",
        &differential::cleanup_only_caller_first().to_string(),
    );

    // 3. overwrites whose right-hand side can fail.
    string_result_line(
        &mut out,
        "overwrite_utf8",
        differential::overwrite_from_utf8("held", true),
    );
    string_result_line(
        &mut out,
        "overwrite_utf8",
        differential::overwrite_from_utf8("held", false),
    );
    string_list_result_line(
        &mut out,
        "overwrite_collection",
        differential::overwrite_collection(true),
    );
    string_list_result_line(
        &mut out,
        "overwrite_collection",
        differential::overwrite_collection(false),
    );
    hex_line(
        &mut out,
        "overwrite_params",
        differential::overwrite_owner_params(
            String::from("first"),
            String::from("second"),
        )
        .as_bytes(),
    );
    cow_line(
        &mut out,
        "cow_same_length",
        differential::nested_cow_text("p", b"ab"),
    );
    cow_line(
        &mut out,
        "cow_borrowed",
        differential::nested_cow_text("p", b"abc"),
    );
    cow_line(
        &mut out,
        "cow_repaired",
        differential::nested_cow_text("p", b"a\xffb"),
    );
    line(&mut out, "utf8_detail_ok", &differential::utf8_error_detail(b"ok").to_string());
    line(
        &mut out,
        "utf8_detail_invalid",
        &differential::utf8_error_detail(b"\xff").to_string(),
    );

    // 4. frames that leave early.
    string_result_line(&mut out, "early_exit", differential::early_exit(true));
    string_result_line(&mut out, "early_exit", differential::early_exit(false));
    string_result_line(&mut out, "fallible_exit", differential::fallible_exit(0));
    string_result_line(&mut out, "fallible_exit", differential::fallible_exit(1));

    // 5. a scan whose effects reach the caller's own counter.
    let mut cursor = 0u32;
    line(
        &mut out,
        "cursor_predicate",
        &numbers(&differential::cursor_predicate_effects(&[1, 2, 3, 4], &mut cursor)),
    );
    line(&mut out, "cursor_predicate_counter", &cursor.to_string());
    let mut owned_cursor = 0u32;
    line(
        &mut out,
        "cursor_owned_predicate",
        &hex_list(&differential::cursor_owned_predicate(&[1, 2, 3, 4], &mut owned_cursor)),
    );
    line(&mut out, "cursor_owned_counter", &owned_cursor.to_string());
    // The same filter when it rejects everything and when it has nothing to
    // reject, which are the two routes the retained case above cannot show: a
    // result with no owner in it at all, and a predicate that never ran.
    let mut rejected_cursor = 0u32;
    line(
        &mut out,
        "cursor_owned_reject",
        &hex_list(&differential::cursor_owned_predicate(&[2, 4], &mut rejected_cursor)),
    );
    line(&mut out, "cursor_owned_reject_cursor", &rejected_cursor.to_string());
    let mut empty_cursor = 0u32;
    line(
        &mut out,
        "cursor_owned_empty",
        &hex_list(&differential::cursor_owned_predicate(&[], &mut empty_cursor)),
    );
    line(&mut out, "cursor_owned_empty_cursor", &empty_cursor.to_string());

    // 6. generic calls whose instantiation the call site decides.
    for take_first in [true, false] {
        hex_line(
            &mut out,
            "generic_string_or",
            differential::generic_string_or(take_first).as_bytes(),
        );
    }
    for take_first in [true, false] {
        line(
            &mut out,
            "generic_vector_or",
            &hex_list(&differential::generic_vector_or(take_first)),
        );
    }
    match differential::generic_context_only(true) {
        Some(values) => line(&mut out, "generic_context", &numbers(&values)),
        None => line(&mut out, "generic_context", "none"),
    }
    match differential::generic_context_only(false) {
        Some(values) => line(&mut out, "generic_context", &numbers(&values)),
        None => line(&mut out, "generic_context", "none"),
    }

    // 7. explicit exits: the condition, the `continue`, the `break`, and the
    // `break` that carries a value out of the loop.
    hex_line(
        &mut out,
        "loop_exit_natural",
        differential::loop_exit_owners(2, 9, false).as_bytes(),
    );
    hex_line(
        &mut out,
        "loop_exit_continue",
        differential::loop_exit_owners(4, 9, true).as_bytes(),
    );
    hex_line(
        &mut out,
        "loop_exit_break",
        differential::loop_exit_owners(4, 1, false).as_bytes(),
    );
    hex_line(
        &mut out,
        "loop_exit_continue_break",
        differential::loop_exit_owners(4, 1, true).as_bytes(),
    );
    hex_line(
        &mut out,
        "loop_value_round",
        differential::loop_value_owner(1).as_bytes(),
    );
    hex_line(
        &mut out,
        "loop_value_fallback",
        differential::loop_value_owner(5).as_bytes(),
    );

    // 8. the method boundary again through the arm that releases the local.
    hex_line(
        &mut out,
        "method_render_released",
        differential::nested_method_render_released("|").as_bytes(),
    );
    hex_line(
        &mut out,
        "method_joined_released",
        differential::nested_method_joined_released().as_bytes(),
    );

    // 9. the owner hand-offs: a generic call, a block that hands a byte vector
    // to a core call, a push, a move closure, the repetition cases with a fixed
    // count, the tuple wrapper, and the repetition whose count is a `usize` the
    // caller chooses at run time.
    hex_line(
        &mut out,
        "owner_scope_generic",
        differential::owner_scope_generic_string().as_bytes(),
    );
    hex_line(
        &mut out,
        "owner_scope_core_block",
        differential::owner_scope_core_argument_block().as_bytes(),
    );
    line(
        &mut out,
        "owner_scope_push",
        &hex_list(&differential::owner_scope_push_string()),
    );
    hex_line(
        &mut out,
        "owner_scope_closure",
        differential::owner_scope_move_closure().as_bytes(),
    );

    // A fixed count of zero builds the owner and releases it, one moves it
    // whole, and two clone it. The counter says the element ran once in every
    // one of those cases, which is what separates an evaluated count from a
    // consumed one.
    let mut zero_repeat_cursor = 0u32;
    line(
        &mut out,
        "owner_scope_repeat_zero",
        &hex_list(&differential::owner_scope_repeat_zero(&mut zero_repeat_cursor)),
    );
    line(
        &mut out,
        "owner_scope_repeat_zero_cursor",
        &zero_repeat_cursor.to_string(),
    );

    let mut one_repeat_cursor = 0u32;
    line(
        &mut out,
        "owner_scope_repeat_one",
        &hex_list(&differential::owner_scope_repeat_one(&mut one_repeat_cursor)),
    );
    line(
        &mut out,
        "owner_scope_repeat_one_cursor",
        &one_repeat_cursor.to_string(),
    );

    let mut two_repeat_cursor = 0u32;
    line(
        &mut out,
        "owner_scope_repeat_two",
        &hex_list(&differential::owner_scope_repeat_two(&mut two_repeat_cursor)),
    );
    line(
        &mut out,
        "owner_scope_repeat_two_cursor",
        &two_repeat_cursor.to_string(),
    );

    line(
        &mut out,
        "owner_scope_repeat_local",
        &hex_list(&differential::owner_scope_repeat_local()),
    );

    // The owning wrapper: zero releases the string it built, one moves it out
    // whole, and three take two clones plus one move, each total read back
    // through the wrapper rather than out of it.
    let tuple_repeats = [
        (0usize, "owner_tuple_repeat_0"),
        (1, "owner_tuple_repeat_1"),
        (3, "owner_tuple_repeat_3"),
    ];
    for (count, key) in tuple_repeats {
        line(
            &mut out,
            key,
            &differential::owner_tuple_repeat(count).to_string(),
        );
    }
    line(
        &mut out,
        "owner_tuple_push",
        &differential::owner_tuple_push().to_string(),
    );

    // The non-owning element has no bytes to clone and nothing to release, so
    // the count the caller passes decides the length and is the only thing it
    // decides — while the element expression still runs once per call,
    // including for the zero-length case that stores nothing.
    let byte_repeats = [
        (0usize, "owner_byte_repeat_0"),
        (1, "owner_byte_repeat_1"),
        (3, "owner_byte_repeat_3"),
    ];
    for (count, key) in byte_repeats {
        let mut cursor = 0u32;
        line(
            &mut out,
            key,
            &differential::owner_byte_repeat(count, &mut cursor).to_string(),
        );
        line(&mut out, &format!("{}_cursor", key), &cursor.to_string());
    }

    // The dispatch shapes: a guard decides between two arms that name the same
    // selector, a constant false guard hands the answer to the arm behind it,
    // and a side-effecting indexed scrutinee is read once however many
    // dispatches read it.
    line(
        &mut out,
        "guard_dispatch_true",
        &differential::guard_dispatch(1, true).to_string(),
    );
    line(
        &mut out,
        "guard_dispatch_false",
        &differential::guard_dispatch(1, false).to_string(),
    );
    line(
        &mut out,
        "guard_dispatch_other",
        &differential::guard_dispatch(2, true).to_string(),
    );
    line(
        &mut out,
        "constant_guard",
        &differential::constant_guard_dispatch().to_string(),
    );

    let mut guarded_cursor = 0u32;
    let guarded_true = differential::guarded_index_dispatch(&[1u8], 0, true, &mut guarded_cursor);
    count_pair_line(&mut out, "guarded_index_true", guarded_true.0 as usize, guarded_true.1);
    guarded_cursor = 0;
    let guarded_false = differential::guarded_index_dispatch(&[1u8], 0, false, &mut guarded_cursor);
    count_pair_line(&mut out, "guarded_index_false", guarded_false.0 as usize, guarded_false.1);
    guarded_cursor = 0;
    let guarded_other = differential::guarded_index_dispatch(&[9u8], 0, true, &mut guarded_cursor);
    count_pair_line(&mut out, "guarded_index_other", guarded_other.0 as usize, guarded_other.1);

    // A payload bound by mutable reference writes into the caller's own
    // element. Both slots are read back here, so a write that stayed in a copy
    // the callee made of the dispatch subject shows up as the old value.
    let mut filled: [differential::Slot; 2] = [
        differential::Slot::Filled(9),
        differential::Slot::Filled(9),
    ];
    let mut slot_cursor = 0u32;
    let written = differential::optional_slot_write(&mut filled, 0, 42, &mut slot_cursor);
    count_pair_line(&mut out, "optional_slot_write", written as usize, slot_cursor);
    line(
        &mut out,
        "optional_slot_filled",
        &differential::slot_payload(filled[0]).to_string(),
    );
    line(
        &mut out,
        "optional_slot_untouched",
        &differential::slot_payload(filled[1]).to_string(),
    );

    let mut mixed: [differential::Slot; 2] = [differential::Slot::Filled(1), differential::Slot::Empty];
    slot_cursor = 0;
    let slot_refused = differential::optional_slot_write(&mut mixed, 1, 7, &mut slot_cursor);
    count_pair_line(&mut out, "optional_slot_empty", slot_refused as usize, slot_cursor);
    line(
        &mut out,
        "optional_slot_empty_kept",
        &differential::slot_payload(mixed[0]).to_string(),
    );

    // The same write through a real `Option` scrutinee, so the dispatch binds
    // the subject itself. Both elements are read back, so a write that stayed
    // in the copy the callee made of that binding shows up as the old value,
    // and the counter says the index expression ran once.
    let mut option_filled: [Option<u32>; 2] = [Some(9), Some(9)];
    let mut option_cursor = 0u32;
    let option_written =
        differential::optional_entry_write(&mut option_filled, 0, 42, &mut option_cursor);
    count_pair_line(&mut out, "optional_entry_write", option_written as usize, option_cursor);
    line(
        &mut out,
        "optional_entry_filled",
        &differential::optional_entry_value(option_filled[0]).to_string(),
    );
    line(
        &mut out,
        "optional_entry_untouched",
        &differential::optional_entry_value(option_filled[1]).to_string(),
    );

    let mut option_mixed: [Option<u32>; 2] = [Some(1), None];
    option_cursor = 0;
    let option_refused =
        differential::optional_entry_write(&mut option_mixed, 1, 7, &mut option_cursor);
    count_pair_line(&mut out, "optional_entry_empty", option_refused as usize, option_cursor);
    line(
        &mut out,
        "optional_entry_empty_kept",
        &differential::optional_entry_value(option_mixed[0]).to_string(),
    );

    // The ownership witnesses: an arm that binds the payload of a temporary
    // subject, a local union whose arm only reads what it bound, and a
    // shadowed binding whose move has to be attributed to it rather than to
    // the outer binding it hides.
    hex_line(
        &mut out,
        "owner_arm_move_ok",
        differential::owner_arm_payload_move(true).as_bytes(),
    );
    hex_line(
        &mut out,
        "owner_arm_move_err",
        differential::owner_arm_payload_move(false).as_bytes(),
    );
    line(
        &mut out,
        "owner_local_result_ok",
        &differential::owner_local_result_match(true).to_string(),
    );
    line(
        &mut out,
        "owner_local_result_err",
        &differential::owner_local_result_match(false).to_string(),
    );
    line(
        &mut out,
        "shadowed_move",
        &differential::shadowed_move_length().to_string(),
    );

    // A guard that reads an owned payload before it decides, the arm behind it
    // which still owns that payload, and a variant the guarded arm never
    // names — plus a variant nested inside a tagged union, whose payload moves
    // out of the inner variant on the arm that selected it.
    line(
        &mut out,
        "guarded_owned_pass",
        &differential::guarded_owned_payload(false, "named-value").to_string(),
    );
    line(
        &mut out,
        "guarded_owned_refused",
        &differential::guarded_owned_payload(false, "named").to_string(),
    );
    line(
        &mut out,
        "guarded_owned_other",
        &differential::guarded_owned_payload(true, "bare").to_string(),
    );
    // Every route out of the tagged union is recorded, not just the two an
    // owner-carrying subject reaches: the string arm, the scalar arm beside it
    // and the error arm own three different things.
    line(
        &mut out,
        "nested_owned_text",
        &differential::nested_owned_payload(0).to_string(),
    );
    line(
        &mut out,
        "nested_owned_width",
        &differential::nested_owned_payload(1).to_string(),
    );
    line(
        &mut out,
        "nested_owned_err",
        &differential::nested_owned_payload(2).to_string(),
    );

    // Both cows are locals this frame owns and the return moves them whole, so
    // the tag each one carries is the answer to whether the caller's bytes or
    // the cow's own slab crossed the boundary.
    cow_line(
        &mut out,
        "cow_str_local_borrowed",
        differential::cow_str_local_move(b"abc"),
    );
    cow_line(
        &mut out,
        "cow_str_local_owned",
        differential::cow_str_local_move(b"a\xffb"),
    );
    byte_cow_line(
        &mut out,
        "cow_slice_local_borrowed",
        differential::cow_slice_local_move(b"abc"),
    );
    byte_cow_line(
        &mut out,
        "cow_slice_local_owned",
        differential::cow_slice_local_move(b"abcd"),
    );

    // The conversion error hands its owned bytes to the caller, so the record
    // carries how far into those bytes the invalid sequence starts: one that
    // had been dropped and rebuilt would have nothing left to describe.
    utf8_handoff_line(&mut out, "utf8_handoff", differential::utf8_error_handoff(b"ok"));
    utf8_handoff_line(&mut out, "utf8_handoff", differential::utf8_error_handoff(b"\xff"));
    utf8_handoff_line(&mut out, "utf8_handoff", differential::utf8_error_handoff(b"ab\xff"));

    // Both elements of the array are owners and the whole array crossed a call,
    // so the record carries each element's bytes.
    line(
        &mut out,
        "array_owner_move",
        &hex_list(&differential::array_owner_move()),
    );

    // Pair fields are both bound even when only one moves out of the arm;
    // refusing the guard leaves both fields available to the following arm.
    hex_line(
        &mut out,
        "owner_pair_second",
        differential::owner_pair_payload(0, true).as_bytes(),
    );
    hex_line(
        &mut out,
        "owner_pair_first",
        differential::owner_pair_payload(0, false).as_bytes(),
    );
    hex_line(
        &mut out,
        "owner_pair_absent",
        differential::owner_pair_payload(2, true).as_bytes(),
    );
    line(
        &mut out,
        "staged_scalar_true",
        &differential::staged_scalar_owner_call(true).to_string(),
    );
    line(
        &mut out,
        "staged_scalar_false",
        &differential::staged_scalar_owner_call(false).to_string(),
    );
    line(
        &mut out,
        "owner_flat_map",
        &numbers(&differential::owner_flat_map_consume(3)),
    );
    line(
        &mut out,
        "owner_flat_map_empty",
        &numbers(&differential::owner_flat_map_consume(0)),
    );

    // Read the mutated source only after the vector releases its mutable
    // references; both a shorter right iterator and an empty left are covered.
    let mut zip_source = [4u32, 5, 6];
    {
        let mut pairs = differential::owner_zip_mut(&mut zip_source, 2);
        for (_, value) in &mut pairs {
            **value += 10;
        }
        let encoded = pairs
            .iter()
            .map(|(text, value)| format!("{}:{}", hex(text.as_bytes()), **value))
            .collect::<Vec<String>>()
            .join(",");
        line(&mut out, "owner_zip_mut", &encoded);
    }
    line(&mut out, "owner_zip_source", &numbers(&zip_source));
    let mut zip_short_source = [8u32];
    {
        let mut pairs = differential::owner_zip_mut(&mut zip_short_source, 4);
        for (_, value) in &mut pairs {
            **value += 10;
        }
        let encoded = pairs
            .iter()
            .map(|(text, value)| format!("{}:{}", hex(text.as_bytes()), **value))
            .collect::<Vec<String>>()
            .join(",");
        line(&mut out, "owner_zip_short", &encoded);
    }
    line(&mut out, "owner_zip_short_source", &numbers(&zip_short_source));
    let mut zip_empty_source = [9u32];
    {
        let mut pairs = differential::owner_zip_mut(&mut zip_empty_source, 0);
        for (_, value) in &mut pairs {
            **value += 10;
        }
        let encoded = pairs
            .iter()
            .map(|(text, value)| format!("{}:{}", hex(text.as_bytes()), **value))
            .collect::<Vec<String>>()
            .join(",");
        line(&mut out, "owner_zip_empty", &encoded);
    }
    line(&mut out, "owner_zip_empty_source", &numbers(&zip_empty_source));

    // A mapping closure discards an owner; the other variant is either scalar
    // or an owner the caller retains unchanged.
    for (key, result) in [
        ("owner_result_map_ok", differential::owner_result_map(true)),
        ("owner_result_map_err", differential::owner_result_map(false)),
        ("owner_result_map_err_ok", differential::owner_result_map_err(true)),
        ("owner_result_map_err_err", differential::owner_result_map_err(false)),
    ] {
        match result {
            Ok(value) => line(&mut out, key, &format!("ok:{}", value)),
            Err(code) => line(&mut out, key, &format!("err:{}", code)),
        }
    }
    for (key, take) in [
        ("owner_result_map_kept_ok", true),
        ("owner_result_map_kept_err", false),
    ] {
        match differential::owner_result_map_passthrough(take) {
            Ok(value) => line(&mut out, key, &format!("ok:{}", value)),
            Err(text) => line(&mut out, key, &format!("err:{}", hex(text.as_bytes()))),
        }
    }
    string_result_line(
        &mut out,
        "owner_result_map_err_kept_ok",
        differential::owner_result_map_err_passthrough(true),
    );
    string_result_line(
        &mut out,
        "owner_result_map_err_kept_err",
        differential::owner_result_map_err_passthrough(false),
    );

    // These receivers arrive by value, rather than being built in the frame
    // that consumes their mapped payload or transfers their other variant.
    for (key, result) in [
        (
            "owner_result_parameter_map_ok",
            differential::owner_result_map_parameter(Ok(String::from("mapped"))),
        ),
        (
            "owner_result_parameter_map_err",
            differential::owner_result_map_parameter(Err(7u8)),
        ),
        (
            "owner_result_parameter_map_err_ok",
            differential::owner_result_map_err_parameter(Ok(9u32)),
        ),
        (
            "owner_result_parameter_map_err_err",
            differential::owner_result_map_err_parameter(Err(String::from("mapped-error"))),
        ),
    ] {
        match result {
            Ok(value) => line(&mut out, key, &format!("ok:{}", value)),
            Err(code) => line(&mut out, key, &format!("err:{}", code)),
        }
    }
    for (key, result) in [
        (
            "owner_result_parameter_map_kept_ok",
            differential::owner_result_map_passthrough_parameter(Ok(String::from("mapped"))),
        ),
        (
            "owner_result_parameter_map_kept_err",
            differential::owner_result_map_passthrough_parameter(Err(String::from("kept-error"))),
        ),
    ] {
        match result {
            Ok(value) => line(&mut out, key, &format!("ok:{}", value)),
            Err(text) => line(&mut out, key, &format!("err:{}", hex(text.as_bytes()))),
        }
    }
    string_result_line(
        &mut out,
        "owner_result_parameter_map_err_kept_ok",
        differential::owner_result_map_err_passthrough_parameter(Ok(String::from("kept-ok"))),
    );
    string_result_line(
        &mut out,
        "owner_result_parameter_map_err_kept_err",
        differential::owner_result_map_err_passthrough_parameter(Err(String::from("mapped-error"))),
    );

    line(
        &mut out,
        "copy_local_u32",
        &differential::copy_local_u32(42).to_string(),
    );
    line(
        &mut out,
        "copy_local_u8",
        &differential::copy_local_u8(7).to_string(),
    );
    line(
        &mut out,
        "transitive_copy_local_u32",
        &differential::transitive_copy_local_u32(43).to_string(),
    );
    line(
        &mut out,
        "transitive_copy_local_u8",
        &differential::transitive_copy_local_u8(8).to_string(),
    );

    for (key, accept) in [
        ("owner_tuple_try_ok", true),
        ("owner_tuple_try_err", false),
    ] {
        match differential::owner_tuple_try(accept) {
            Ok((text, value)) => line(
                &mut out,
                key,
                &format!("ok:{},{}", hex(text.as_bytes()), value),
            ),
            Err(code) => line(&mut out, key, &format!("err:{}", code)),
        }
    }

    let (quotient, remainder, counter) = differential::primitive_compound_order();
    line(
        &mut out,
        "primitive_compound_order",
        &format!("{},{},{}", quotient, remainder, counter),
    );

    hex_line(
        &mut out,
        "owner_projected_pair_solo",
        differential::owner_projected_pair(false).as_bytes(),
    );
    hex_line(
        &mut out,
        "owner_projected_pair_empty",
        differential::owner_projected_pair(true).as_bytes(),
    );
    hex_line(
        &mut out,
        "owner_nested_iflet_matched",
        differential::owner_nested_iflet(0).as_bytes(),
    );
    hex_line(
        &mut out,
        "owner_nested_iflet_unmatched",
        differential::owner_nested_iflet(1).as_bytes(),
    );
    hex_line(
        &mut out,
        "owner_nested_iflet_absent",
        differential::owner_nested_iflet(2).as_bytes(),
    );
    line(
        &mut out,
        "owner_projected_option_borrow_twice",
        &differential::owner_projected_option_borrow_twice().to_string(),
    );
    line(
        &mut out,
        "owner_projected_option_none_inspection",
        &differential::owner_projected_option_none_inspection().to_string(),
    );
    hex_line(
        &mut out,
        "owner_projected_option_move",
        differential::owner_projected_option_move(String::from("abc")).as_bytes(),
    );
    line(
        &mut out,
        "source_string_constructor_value",
        &differential::source_string_constructor_value().to_string(),
    );

    // The comparison is byte for byte, so the bytes are written and flushed
    // here rather than left to whatever the runtime does at exit.
    let mut stdout = std::io::stdout();
    std::io::Write::write_all(&mut stdout, out.as_bytes()).unwrap();
    std::io::Write::flush(&mut stdout).unwrap();
}
