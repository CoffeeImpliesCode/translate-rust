//! The Zig half of the differential pair.
//!
//! `test/differential_rust_oracle.rs` prints the canonical records for
//! `test/crates/differential/src/lib.rs` by calling the Rust functions through
//! `#[path]`; this program prints the same records by calling the translated
//! Zig package, so the two stdout streams can be compared byte for byte. Every
//! record below comes from the generated function for the same fixture entry
//! point — nothing here reimplements the fixture's logic, and no record is an
//! expectation about what the translation "should" produce.
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
//! reaches a record, so the same bytes come out of any target and from either
//! optimization mode.
//!
//! Built like the `test/compat_consumer.zig` invocation in `test/e2e_test.zig`,
//! with the generated package root in place of the compat one. The root module
//! imports `r2z` itself, so it needs its own `--dep r2z`:
//!
//!     zig build-exe --dep translated --dep r2z \
//!         -Mroot=test/differential_zig_oracle.zig \
//!         --dep r2z -Mtranslated=<generated>/src/root.zig \
//!         -Mr2z=r2z-core/src/root.zig
//!
//! `test/differential_consumer.zig` imports this file and reuses `writeRecords`,
//! so the records exist once and the consumer compares them against the bytes
//! Rust prints.

const std = @import("std");
const r2z = @import("r2z");
const translated = @import("translated");

// ── the record encoding ─────────────────────────────────────────────────

/// `key=<hex>`, two lowercase hex digits per byte with no separator.
fn writeHex(writer: *std.Io.Writer, key: []const u8, bytes: []const u8) !void {
    try writer.print("{s}=", .{key});
    try writeHexBytes(writer, bytes);
    try writer.writeAll("\n");
}

fn writeHexBytes(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    const digits = "0123456789abcdef";
    for (bytes) |byte| {
        const encoded = [2]u8{ digits[byte >> 4], digits[byte & 0xf] };
        try writer.writeAll(&encoded);
    }
}

/// `key=tag:<hex>`, which is how a record says WHICH arm produced the value.
fn writeTaggedHex(
    writer: *std.Io.Writer,
    key: []const u8,
    tag: []const u8,
    bytes: []const u8,
) !void {
    try writer.print("{s}={s}:", .{ key, tag });
    try writeHexBytes(writer, bytes);
    try writer.writeAll("\n");
}

/// `key=<decimal>`.
fn writeCount(writer: *std.Io.Writer, key: []const u8, value: anytype) !void {
    try writer.print("{s}={d}\n", .{ key, value });
}

/// `key=tag:<decimal>`.
fn writeTaggedCount(
    writer: *std.Io.Writer,
    key: []const u8,
    tag: []const u8,
    value: anytype,
) !void {
    try writer.print("{s}={s}:{d}\n", .{ key, tag, value });
}

/// `key=1,2,3`, empty for an empty vector.
fn writeCountList(writer: *std.Io.Writer, key: []const u8, values: []const u32) !void {
    try writer.print("{s}=", .{key});
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("{d}", .{value});
    }
    try writer.writeAll("\n");
}

/// `key=<hex>,<hex>`, the payloads an owner per element.
fn writeHexList(writer: *std.Io.Writer, key: []const u8, values: []const r2z.alloc.String) !void {
    try writer.print("{s}=", .{key});
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(",");
        try writeHexBytes(writer, value.as_bytes());
    }
    try writer.writeAll("\n");
}

/// `key=<decimal>,<decimal>` — an answer beside the counter that observed it.
fn writeCountPair(
    writer: *std.Io.Writer,
    key: []const u8,
    answer: anytype,
    counter: anytype,
) !void {
    try writer.print("{s}={d},{d}\n", .{ key, answer, counter });
}

// ── one record per owner shape, each releasing exactly what it was handed ──

/// One owner, one release. The place is handed in rather than a copy, so the
/// value this frame stops owning is the value that gets released.
fn writeStringRecord(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    key: []const u8,
    value: *r2z.alloc.String,
) !void {
    defer value.deinit(gpa);
    try writeHex(writer, key, value.as_bytes());
}

/// The tag is part of the record: a `Cow` that borrows the caller's bytes and
/// one that owns repaired bytes are different answers to the same call.
fn writeCowRecord(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    key: []const u8,
    value: *r2z.alloc.CowStr,
) !void {
    defer r2z.alloc.dropTemporary(gpa, value);
    switch (value.*) {
        .Borrowed => |bytes| try writeTaggedHex(writer, key, "borrowed", bytes),
        .Owned => |text| try writeTaggedHex(writer, key, "owned", text.as_bytes()),
    }
}

/// The same tag for the byte cow: a borrow of the caller's bytes and an owner
/// of copied ones are different answers to the same call.
fn writeCowSliceRecord(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    key: []const u8,
    value: *r2z.alloc.CowSlice(u8),
) !void {
    defer r2z.alloc.dropTemporary(gpa, value);
    switch (value.*) {
        .Borrowed => |bytes| try writeTaggedHex(writer, key, "borrowed", bytes),
        .Owned => |bytes| try writeTaggedHex(writer, key, "owned", bytes.items),
    }
}

/// `dropTemporary` walks a tagged union into its payload and a vector into its
/// elements, so the payload of either arm is released here exactly once.
fn writeStringResultRecord(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    key: []const u8,
    result: *r2z.Result(r2z.alloc.String, u8),
) !void {
    defer r2z.alloc.dropTemporary(gpa, result);
    switch (result.*) {
        .Ok => |text| try writeTaggedHex(writer, key, "ok", text.as_bytes()),
        .Err => |code| try writeTaggedCount(writer, key, "err", code),
    }
}

/// The failing arm hands the error to the caller rather than dropping it, so
/// the record says how far into the bytes it still owns the invalid sequence
/// starts: an error that had lost them could not report a position in them.
fn writeUtf8ErrorResultRecord(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    key: []const u8,
    result: *r2z.Result(r2z.alloc.String, r2z.alloc.FromUtf8Error),
) !void {
    defer r2z.alloc.dropTemporary(gpa, result);
    switch (result.*) {
        .Ok => |text| try writeTaggedHex(writer, key, "ok", text.as_bytes()),
        .Err => |failure| try writer.print("{s}=err:{d}\n", .{
            key,
            failure.utf8_error().valid_up_to,
        }),
    }
}

fn writeStringListResultRecord(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    key: []const u8,
    result: *r2z.Result(std.ArrayListUnmanaged(r2z.alloc.String), u8),
) !void {
    defer r2z.alloc.dropTemporary(gpa, result);
    switch (result.*) {
        .Ok => |list| try writeTaggedHexList(writer, key, "ok", list.items),
        .Err => |code| try writeTaggedCount(writer, key, "err", code),
    }
}

fn writeTaggedHexList(
    writer: *std.Io.Writer,
    key: []const u8,
    tag: []const u8,
    values: []const r2z.alloc.String,
) !void {
    try writer.print("{s}={s}:", .{ key, tag });
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(",");
        try writeHexBytes(writer, value.as_bytes());
    }
    try writer.writeAll("\n");
}

fn writeCountResultRecord(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    key: []const u8,
    result: *r2z.Result(u32, u8),
) !void {
    defer r2z.alloc.dropTemporary(gpa, result);
    switch (result.*) {
        .Ok => |value| try writeTaggedCount(writer, key, "ok", value),
        .Err => |code| try writeTaggedCount(writer, key, "err", code),
    }
}

fn writeCountStringResultRecord(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    key: []const u8,
    result: *r2z.Result(u32, r2z.alloc.String),
) !void {
    defer r2z.alloc.dropTemporary(gpa, result);
    switch (result.*) {
        .Ok => |value| try writeTaggedCount(writer, key, "ok", value),
        .Err => |text| try writeTaggedHex(writer, key, "err", text.as_bytes()),
    }
}

fn writeZipMutableRecord(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    key: []const u8,
    pairs: anytype,
) !void {
    defer r2z.alloc.dropTemporary(gpa, pairs);
    try writer.print("{s}=", .{key});
    for (pairs.items, 0..) |*pair, index| {
        pair[1].* += 10;
        if (index != 0) try writer.writeAll(",");
        try writeHexBytes(writer, pair[0].as_bytes());
        try writer.print(":{d}", .{pair[1].*});
    }
    try writer.writeAll("\n");
}

/// The records, in the order the Rust oracle writes them. Both programs call
/// the same fixture entry points with the same literals, so the two streams
/// agree byte for byte or one of the two is wrong.
pub fn writeRecords(gpa: std.mem.Allocator, writer: *std.Io.Writer) !void {
    try writer.writeAll("format=differential-records-v1\n");

    // 1. owners in nested scopes.
    var lexical = try translated.nested_lexical_owner(gpa);
    try writeStringRecord(gpa, writer, "nested_lexical", &lexical);
    const branch_modes = [_]u8{ 0, 1, 2 };
    const branch_keys = [_][]const u8{ "nested_branch_0", "nested_branch_1", "nested_branch_2" };
    for (branch_modes, branch_keys) |mode, key| {
        var selected = try translated.nested_branch_owner(gpa, mode);
        try writeStringRecord(gpa, writer, key, &selected);
    }
    const loop_limits = [_]u8{ 0, 3 };
    const loop_keys = [_][]const u8{ "nested_loop_0", "nested_loop_3" };
    for (loop_limits, loop_keys) |limit, key| {
        var rounds = try translated.nested_loop_owner(gpa, limit);
        try writeStringRecord(gpa, writer, key, &rounds);
    }
    var rendered = try translated.nested_method_render(gpa, "|");
    try writeStringRecord(gpa, writer, "nested_method_render", &rendered);
    var joined = try translated.nested_method_joined(gpa);
    try writeStringRecord(gpa, writer, "nested_method_joined", &joined);
    try writeCount(writer, "shadowed", try translated.shadowed_length(gpa));

    // 2. moves that depend on a branch.
    var moved = try translated.conditional_move_parameter(
        gpa,
        try translated.owned(gpa, "given"),
        true,
    );
    try writeStringRecord(gpa, writer, "conditional_move_taken", &moved);
    var kept = try translated.conditional_move_parameter(
        gpa,
        try translated.owned(gpa, "given"),
        false,
    );
    try writeStringRecord(gpa, writer, "conditional_move_released", &kept);
    const match_modes = [_]u8{ 0, 1, 2 };
    const match_keys = [_][]const u8{
        "conditional_match_0",
        "conditional_match_1",
        "conditional_match_2",
    };
    for (match_modes, match_keys) |mode, key| {
        var selected = try translated.conditional_move_match(
            gpa,
            mode,
            try translated.owned(gpa, "given"),
        );
        try writeStringRecord(gpa, writer, key, &selected);
    }
    try writeCount(
        writer,
        "cleanup_only_callee_first",
        try translated.cleanup_only_caller_callee_first(gpa),
    );
    try writeCount(
        writer,
        "cleanup_only_caller_first",
        try translated.cleanup_only_caller_first(gpa),
    );

    // 3. overwrites whose right-hand side can fail.
    var replaced = try translated.overwrite_from_utf8(gpa, "held", true);
    try writeStringResultRecord(gpa, writer, "overwrite_utf8", &replaced);
    var refused = try translated.overwrite_from_utf8(gpa, "held", false);
    try writeStringResultRecord(gpa, writer, "overwrite_utf8", &refused);
    var collection = try translated.overwrite_collection(gpa, true);
    try writeStringListResultRecord(gpa, writer, "overwrite_collection", &collection);
    var rejected = try translated.overwrite_collection(gpa, false);
    try writeStringListResultRecord(gpa, writer, "overwrite_collection", &rejected);
    var replaced_params = blk: {
        var first_param = try translated.owned(gpa, "first");
        errdefer first_param.deinit(gpa);
        const second_param = try translated.owned(gpa, "second");
        break :blk translated.overwrite_owner_params(gpa, first_param, second_param);
    };
    try writeStringRecord(gpa, writer, "overwrite_params", &replaced_params);
    var same_length = try translated.nested_cow_text(gpa, "p", "ab");
    try writeCowRecord(gpa, writer, "cow_same_length", &same_length);
    var borrowed = try translated.nested_cow_text(gpa, "p", "abc");
    try writeCowRecord(gpa, writer, "cow_borrowed", &borrowed);
    var repaired = try translated.nested_cow_text(gpa, "p", "a\xffb");
    try writeCowRecord(gpa, writer, "cow_repaired", &repaired);
    try writeCount(writer, "utf8_detail_ok", try translated.utf8_error_detail(gpa, "ok"));
    try writeCount(writer, "utf8_detail_invalid", try translated.utf8_error_detail(gpa, "\xff"));

    // 4. frames that leave early.
    var checked = try translated.early_exit(gpa, true);
    try writeStringResultRecord(gpa, writer, "early_exit", &checked);
    var unchecked = try translated.early_exit(gpa, false);
    try writeStringResultRecord(gpa, writer, "early_exit", &unchecked);
    var rejected_depth = try translated.fallible_exit(gpa, 0);
    try writeStringResultRecord(gpa, writer, "fallible_exit", &rejected_depth);
    var accepted_depth = try translated.fallible_exit(gpa, 1);
    try writeStringResultRecord(gpa, writer, "fallible_exit", &accepted_depth);

    // 5. a scan whose effects reach the caller's own counter.
    var cursor: u32 = 0;
    var kept_values = try translated.cursor_predicate_effects(gpa, &.{ 1, 2, 3, 4 }, &cursor);
    defer r2z.alloc.dropTemporary(gpa, &kept_values);
    try writeCountList(writer, "cursor_predicate", kept_values.items);
    try writeCount(writer, "cursor_predicate_counter", cursor);

    var owned_cursor: u32 = 0;
    var owned_values = try translated.cursor_owned_predicate(gpa, &.{ 1, 2, 3, 4 }, &owned_cursor);
    defer r2z.alloc.dropTemporary(gpa, &owned_values);
    try writeHexList(writer, "cursor_owned_predicate", owned_values.items);
    try writeCount(writer, "cursor_owned_counter", owned_cursor);

    // The same filter when it rejects everything and when it has nothing to
    // reject, which are the two routes the retained case above cannot show: a
    // result with no owner in it at all, and a predicate that never ran.
    var rejected_cursor: u32 = 0;
    var rejected_values = try translated.cursor_owned_predicate(gpa, &.{ 2, 4 }, &rejected_cursor);
    defer r2z.alloc.dropTemporary(gpa, &rejected_values);
    try writeHexList(writer, "cursor_owned_reject", rejected_values.items);
    try writeCount(writer, "cursor_owned_reject_cursor", rejected_cursor);

    var empty_cursor: u32 = 0;
    var empty_values = try translated.cursor_owned_predicate(gpa, &.{}, &empty_cursor);
    defer r2z.alloc.dropTemporary(gpa, &empty_values);
    try writeHexList(writer, "cursor_owned_empty", empty_values.items);
    try writeCount(writer, "cursor_owned_empty_cursor", empty_cursor);

    // 6. generic calls whose instantiation the call site decides.
    for ([_]bool{ true, false }) |take_first| {
        var selected = try translated.generic_string_or(gpa, take_first);
        try writeStringRecord(gpa, writer, "generic_string_or", &selected);
    }
    for ([_]bool{ true, false }) |take_first| {
        var selected = try translated.generic_vector_or(gpa, take_first);
        defer r2z.alloc.dropTemporary(gpa, &selected);
        try writeHexList(writer, "generic_vector_or", selected.items);
    }
    var present = try translated.generic_context_only(gpa, true);
    defer r2z.alloc.dropTemporary(gpa, &present);
    if (present) |values| {
        try writeCountList(writer, "generic_context", values.items);
    } else {
        try writer.writeAll("generic_context=none\n");
    }
    var absent = try translated.generic_context_only(gpa, false);
    defer r2z.alloc.dropTemporary(gpa, &absent);
    if (absent) |values| {
        try writeCountList(writer, "generic_context", values.items);
    } else {
        try writer.writeAll("generic_context=none\n");
    }

    // 7. explicit exits: the condition, the `continue`, the `break`, and the
    // `break` that carries a value out of the loop.
    var natural_exit = try translated.loop_exit_owners(gpa, 2, 9, false);
    try writeStringRecord(gpa, writer, "loop_exit_natural", &natural_exit);
    var continued_exit = try translated.loop_exit_owners(gpa, 4, 9, true);
    try writeStringRecord(gpa, writer, "loop_exit_continue", &continued_exit);
    var broken_exit = try translated.loop_exit_owners(gpa, 4, 1, false);
    try writeStringRecord(gpa, writer, "loop_exit_break", &broken_exit);
    var skipped_and_broken = try translated.loop_exit_owners(gpa, 4, 1, true);
    try writeStringRecord(gpa, writer, "loop_exit_continue_break", &skipped_and_broken);
    var round_exit = try translated.loop_value_owner(gpa, 1);
    try writeStringRecord(gpa, writer, "loop_value_round", &round_exit);
    var fallback_exit = try translated.loop_value_owner(gpa, 5);
    try writeStringRecord(gpa, writer, "loop_value_fallback", &fallback_exit);

    // 8. the method boundary again through the arm that releases the local.
    var released_render = try translated.nested_method_render_released(gpa, "|");
    try writeStringRecord(gpa, writer, "method_render_released", &released_render);
    var released_join = try translated.nested_method_joined_released(gpa);
    try writeStringRecord(gpa, writer, "method_joined_released", &released_join);

    // 9. the owner hand-offs: a generic call, a block that hands a byte vector
    // to a core call, a push, a move closure, the repetition cases with a fixed
    // count, the tuple wrapper, and the repetition whose count is a `usize` the
    // caller chooses at run time.
    var generic_owner = try translated.owner_scope_generic_string(gpa);
    try writeStringRecord(gpa, writer, "owner_scope_generic", &generic_owner);
    var core_block = try translated.owner_scope_core_argument_block(gpa);
    try writeStringRecord(gpa, writer, "owner_scope_core_block", &core_block);
    var pushed = try translated.owner_scope_push_string(gpa);
    defer r2z.alloc.dropTemporary(gpa, &pushed);
    try writeHexList(writer, "owner_scope_push", pushed.items);
    var closed_over = try translated.owner_scope_move_closure(gpa);
    try writeStringRecord(gpa, writer, "owner_scope_closure", &closed_over);

    // A fixed count of zero builds the owner and releases it, one moves it
    // whole, and two clone it. The counter says the element ran once in every
    // one of those cases, which is what separates an evaluated count from a
    // consumed one.
    var zero_repeat_cursor: u32 = 0;
    var zero_repeat = try translated.owner_scope_repeat_zero(gpa, &zero_repeat_cursor);
    defer r2z.alloc.dropTemporary(gpa, &zero_repeat);
    try writeHexList(writer, "owner_scope_repeat_zero", zero_repeat.items);
    try writeCount(writer, "owner_scope_repeat_zero_cursor", zero_repeat_cursor);

    var one_repeat_cursor: u32 = 0;
    var one_repeat = try translated.owner_scope_repeat_one(gpa, &one_repeat_cursor);
    defer r2z.alloc.dropTemporary(gpa, &one_repeat);
    try writeHexList(writer, "owner_scope_repeat_one", one_repeat.items);
    try writeCount(writer, "owner_scope_repeat_one_cursor", one_repeat_cursor);

    var two_repeat_cursor: u32 = 0;
    var two_repeat = try translated.owner_scope_repeat_two(gpa, &two_repeat_cursor);
    defer r2z.alloc.dropTemporary(gpa, &two_repeat);
    try writeHexList(writer, "owner_scope_repeat_two", two_repeat.items);
    try writeCount(writer, "owner_scope_repeat_two_cursor", two_repeat_cursor);

    var local_repeat = try translated.owner_scope_repeat_local(gpa);
    defer r2z.alloc.dropTemporary(gpa, &local_repeat);
    try writeHexList(writer, "owner_scope_repeat_local", local_repeat.items);

    // The owning wrapper: zero releases the string it built, one moves it out
    // whole, and three take two clones plus one move, each total read back
    // through the wrapper rather than out of it.
    const tuple_repeat_counts = [_]usize{ 0, 1, 3 };
    const tuple_repeat_keys = [_][]const u8{
        "owner_tuple_repeat_0",
        "owner_tuple_repeat_1",
        "owner_tuple_repeat_3",
    };
    for (tuple_repeat_counts, tuple_repeat_keys) |count, key| {
        try writeCount(writer, key, try translated.owner_tuple_repeat(gpa, count));
    }
    try writeCount(writer, "owner_tuple_push", try translated.owner_tuple_push(gpa));

    // The non-owning element has no bytes to clone and nothing to release, so
    // the count the caller passes decides the length and is the only thing it
    // decides — while the element expression still runs once per call,
    // including for the zero-length case that stores nothing.
    const ByteRepeat = struct { count: usize, key: []const u8 };
    const byte_repeat_cases = [_]ByteRepeat{
        .{ .count = 0, .key = "owner_byte_repeat_0" },
        .{ .count = 1, .key = "owner_byte_repeat_1" },
        .{ .count = 3, .key = "owner_byte_repeat_3" },
    };
    for (byte_repeat_cases) |case| {
        var repeat_cursor: u32 = 0;
        try writeCount(
            writer,
            case.key,
            try translated.owner_byte_repeat(gpa, case.count, &repeat_cursor),
        );
        try writer.print("{s}_cursor={d}\n", .{ case.key, repeat_cursor });
    }

    // 10. the dispatch shapes: a guard decides between two arms that name the
    // same selector, a constant false guard hands the answer to the arm behind
    // it, and a side-effecting indexed scrutinee is read once however many
    // dispatches read it.
    try writeCount(writer, "guard_dispatch_true", translated.guard_dispatch(1, true));
    try writeCount(writer, "guard_dispatch_false", translated.guard_dispatch(1, false));
    try writeCount(writer, "guard_dispatch_other", translated.guard_dispatch(2, true));
    try writeCount(writer, "constant_guard", translated.constant_guard_dispatch());

    var guarded_cursor: u32 = 0;
    const guarded_true = translated.guarded_index_dispatch(&.{1}, 0, true, &guarded_cursor);
    try writeCountPair(writer, "guarded_index_true", guarded_true[0], guarded_true[1]);
    guarded_cursor = 0;
    const guarded_false = translated.guarded_index_dispatch(&.{1}, 0, false, &guarded_cursor);
    try writeCountPair(writer, "guarded_index_false", guarded_false[0], guarded_false[1]);
    guarded_cursor = 0;
    const guarded_other = translated.guarded_index_dispatch(&.{9}, 0, true, &guarded_cursor);
    try writeCountPair(writer, "guarded_index_other", guarded_other[0], guarded_other[1]);

    // 11. a payload bound by mutable reference writes into the caller's own
    // element. Both slots are read back here, so a write that stayed in a copy
    // the callee made of the dispatch subject shows up as the old value.
    var filled: [2]translated.Slot = .{ .{ .Filled = 9 }, .{ .Filled = 9 } };
    var slot_cursor: u32 = 0;
    const written = translated.optional_slot_write(&filled, 0, 42, &slot_cursor);
    try writeCountPair(writer, "optional_slot_write", written, slot_cursor);
    try writeCount(writer, "optional_slot_filled", translated.slot_payload(filled[0]));
    try writeCount(writer, "optional_slot_untouched", translated.slot_payload(filled[1]));

    var mixed: [2]translated.Slot = .{ .{ .Filled = 1 }, .{ .Empty = {} } };
    slot_cursor = 0;
    const slot_refused = translated.optional_slot_write(&mixed, 1, 7, &slot_cursor);
    try writeCountPair(writer, "optional_slot_empty", slot_refused, slot_cursor);
    try writeCount(writer, "optional_slot_empty_kept", translated.slot_payload(mixed[0]));

    // 12. the same write through a real `Option` scrutinee, so the dispatch
    // binds the subject itself. Both elements are read back, so a write that
    // stayed in the copy the callee made of that binding shows up as the old
    // value, and the counter says the index expression ran once.
    var option_filled: [2]?u32 = .{ 9, 9 };
    var option_cursor: u32 = 0;
    const option_written = translated.optional_entry_write(&option_filled, 0, 42, &option_cursor);
    try writeCountPair(writer, "optional_entry_write", option_written, option_cursor);
    try writeCount(
        writer,
        "optional_entry_filled",
        translated.optional_entry_value(option_filled[0]),
    );
    try writeCount(
        writer,
        "optional_entry_untouched",
        translated.optional_entry_value(option_filled[1]),
    );

    var option_mixed: [2]?u32 = .{ 1, null };
    option_cursor = 0;
    const option_refused = translated.optional_entry_write(&option_mixed, 1, 7, &option_cursor);
    try writeCountPair(writer, "optional_entry_empty", option_refused, option_cursor);
    try writeCount(
        writer,
        "optional_entry_empty_kept",
        translated.optional_entry_value(option_mixed[0]),
    );

    // 13. the ownership witnesses: an arm that binds the payload of a
    // temporary subject, a local union whose arm only reads what it bound, a
    // shadowed binding whose move has to be attributed to it rather than to
    // the outer binding it hides, a guard that refuses an owned payload the arm
    // behind it still owns, and every route out of a variant nested inside a
    // union.
    var arm_moved = try translated.owner_arm_payload_move(gpa, true);
    try writeStringRecord(gpa, writer, "owner_arm_move_ok", &arm_moved);
    var arm_refused = try translated.owner_arm_payload_move(gpa, false);
    try writeStringRecord(gpa, writer, "owner_arm_move_err", &arm_refused);
    try writeCount(
        writer,
        "owner_local_result_ok",
        try translated.owner_local_result_match(gpa, true),
    );
    try writeCount(
        writer,
        "owner_local_result_err",
        try translated.owner_local_result_match(gpa, false),
    );
    try writeCount(writer, "shadowed_move", try translated.shadowed_move_length(gpa));
    try writeCount(
        writer,
        "guarded_owned_pass",
        try translated.guarded_owned_payload(gpa, false, "named-value"),
    );
    try writeCount(
        writer,
        "guarded_owned_refused",
        try translated.guarded_owned_payload(gpa, false, "named"),
    );
    try writeCount(
        writer,
        "guarded_owned_other",
        try translated.guarded_owned_payload(gpa, true, "bare"),
    );
    // Every route out of the tagged union is recorded, not just the two an
    // owner-carrying subject reaches: the string arm, the scalar arm beside it
    // and the error arm own three different things.
    try writeCount(writer, "nested_owned_text", try translated.nested_owned_payload(gpa, 0));
    try writeCount(writer, "nested_owned_width", try translated.nested_owned_payload(gpa, 1));
    try writeCount(writer, "nested_owned_err", try translated.nested_owned_payload(gpa, 2));

    // Both cows are locals this frame owns and the return moves them whole, so
    // the tag each one carries is the answer to whether the caller's bytes or
    // the cow's own slab crossed the boundary.
    var local_cow_borrowed = try translated.cow_str_local_move(gpa, "abc");
    try writeCowRecord(gpa, writer, "cow_str_local_borrowed", &local_cow_borrowed);
    var local_cow_owned = try translated.cow_str_local_move(gpa, "a\xffb");
    try writeCowRecord(gpa, writer, "cow_str_local_owned", &local_cow_owned);
    var local_slice_borrowed = try translated.cow_slice_local_move(gpa, "abc");
    try writeCowSliceRecord(gpa, writer, "cow_slice_local_borrowed", &local_slice_borrowed);
    var local_slice_owned = try translated.cow_slice_local_move(gpa, "abcd");
    try writeCowSliceRecord(gpa, writer, "cow_slice_local_owned", &local_slice_owned);

    // The conversion error hands its owned bytes to the caller, so the record
    // carries how far into those bytes the invalid sequence starts: one that
    // had been dropped and rebuilt would have nothing left to describe.
    var handoff_ok = try translated.utf8_error_handoff(gpa, "ok");
    try writeUtf8ErrorResultRecord(gpa, writer, "utf8_handoff", &handoff_ok);
    var handoff_invalid = try translated.utf8_error_handoff(gpa, "\xff");
    try writeUtf8ErrorResultRecord(gpa, writer, "utf8_handoff", &handoff_invalid);
    var handoff_partial = try translated.utf8_error_handoff(gpa, "ab\xff");
    try writeUtf8ErrorResultRecord(gpa, writer, "utf8_handoff", &handoff_partial);

    // Both elements of the array are owners and the whole array crossed a call,
    // so the record carries each element's bytes and releases each of them.
    var array_owners = try translated.array_owner_move(gpa);
    defer r2z.alloc.dropTemporary(gpa, &array_owners);
    try writeHexList(writer, "array_owner_move", array_owners[0..]);

    // Each enum field is an independent owner, and a rejected guard reaches
    // the arm that selects the first field rather than the second.
    var pair_second = try translated.owner_pair_payload(gpa, 0, true);
    try writeStringRecord(gpa, writer, "owner_pair_second", &pair_second);
    var pair_first = try translated.owner_pair_payload(gpa, 0, false);
    try writeStringRecord(gpa, writer, "owner_pair_first", &pair_first);
    var pair_absent = try translated.owner_pair_payload(gpa, 2, true);
    try writeStringRecord(gpa, writer, "owner_pair_absent", &pair_absent);
    try writeCount(writer, "staged_scalar_true", try translated.staged_scalar_owner_call(gpa, true));
    try writeCount(writer, "staged_scalar_false", try translated.staged_scalar_owner_call(gpa, false));

    {
        var flat = try translated.owner_flat_map_consume(gpa, 3);
        defer flat.deinit(gpa);
        try writeCountList(writer, "owner_flat_map", flat.items);
    }
    {
        var flat_empty = try translated.owner_flat_map_consume(gpa, 0);
        defer flat_empty.deinit(gpa);
        try writeCountList(writer, "owner_flat_map_empty", flat_empty.items);
    }

    var zip_input = [_]u32{ 4, 5, 6 };
    var zip_pairs = try translated.owner_zip_mut(gpa, &zip_input, 2);
    try writeZipMutableRecord(gpa, writer, "owner_zip_mut", &zip_pairs);
    try writeCountList(writer, "owner_zip_source", &zip_input);
    var zip_short_input = [_]u32{8};
    var zip_short = try translated.owner_zip_mut(gpa, &zip_short_input, 4);
    try writeZipMutableRecord(gpa, writer, "owner_zip_short", &zip_short);
    try writeCountList(writer, "owner_zip_short_source", &zip_short_input);
    var zip_empty_input = [_]u32{9};
    var zip_empty = try translated.owner_zip_mut(gpa, &zip_empty_input, 0);
    try writeZipMutableRecord(gpa, writer, "owner_zip_empty", &zip_empty);
    try writeCountList(writer, "owner_zip_empty_source", &zip_empty_input);

    var map_ok = try translated.owner_result_map(gpa, true);
    try writeCountResultRecord(gpa, writer, "owner_result_map_ok", &map_ok);
    var map_err = try translated.owner_result_map(gpa, false);
    try writeCountResultRecord(gpa, writer, "owner_result_map_err", &map_err);
    var map_err_ok = try translated.owner_result_map_err(gpa, true);
    try writeCountResultRecord(gpa, writer, "owner_result_map_err_ok", &map_err_ok);
    var map_err_err = try translated.owner_result_map_err(gpa, false);
    try writeCountResultRecord(gpa, writer, "owner_result_map_err_err", &map_err_err);
    var map_kept_ok = try translated.owner_result_map_passthrough(gpa, true);
    try writeCountStringResultRecord(gpa, writer, "owner_result_map_kept_ok", &map_kept_ok);
    var map_kept_err = try translated.owner_result_map_passthrough(gpa, false);
    try writeCountStringResultRecord(gpa, writer, "owner_result_map_kept_err", &map_kept_err);
    var map_err_kept_ok = try translated.owner_result_map_err_passthrough(gpa, true);
    try writeStringResultRecord(gpa, writer, "owner_result_map_err_kept_ok", &map_err_kept_ok);
    var map_err_kept_err = try translated.owner_result_map_err_passthrough(gpa, false);
    try writeStringResultRecord(gpa, writer, "owner_result_map_err_kept_err", &map_err_kept_err);

    var parameter_map_ok = translated.owner_result_map_parameter(gpa, .{
        .Ok = try translated.owned(gpa, "mapped"),
    });
    try writeCountResultRecord(gpa, writer, "owner_result_parameter_map_ok", &parameter_map_ok);
    var parameter_map_err = translated.owner_result_map_parameter(gpa, .{ .Err = 7 });
    try writeCountResultRecord(gpa, writer, "owner_result_parameter_map_err", &parameter_map_err);
    var parameter_map_err_ok = translated.owner_result_map_err_parameter(gpa, .{ .Ok = 9 });
    try writeCountResultRecord(gpa, writer, "owner_result_parameter_map_err_ok", &parameter_map_err_ok);
    var parameter_map_err_err = translated.owner_result_map_err_parameter(gpa, .{
        .Err = try translated.owned(gpa, "mapped-error"),
    });
    try writeCountResultRecord(gpa, writer, "owner_result_parameter_map_err_err", &parameter_map_err_err);
    var parameter_map_kept_ok = translated.owner_result_map_passthrough_parameter(gpa, .{
        .Ok = try translated.owned(gpa, "mapped"),
    });
    try writeCountStringResultRecord(gpa, writer, "owner_result_parameter_map_kept_ok", &parameter_map_kept_ok);
    var parameter_map_kept_err = translated.owner_result_map_passthrough_parameter(gpa, .{
        .Err = try translated.owned(gpa, "kept-error"),
    });
    try writeCountStringResultRecord(gpa, writer, "owner_result_parameter_map_kept_err", &parameter_map_kept_err);
    var parameter_map_err_kept_ok = translated.owner_result_map_err_passthrough_parameter(gpa, .{
        .Ok = try translated.owned(gpa, "kept-ok"),
    });
    try writeStringResultRecord(gpa, writer, "owner_result_parameter_map_err_kept_ok", &parameter_map_err_kept_ok);
    var parameter_map_err_kept_err = translated.owner_result_map_err_passthrough_parameter(gpa, .{
        .Err = try translated.owned(gpa, "mapped-error"),
    });
    try writeStringResultRecord(gpa, writer, "owner_result_parameter_map_err_kept_err", &parameter_map_err_kept_err);

    try writeCount(writer, "copy_local_u32", translated.copy_local_u32(42));
    try writeCount(writer, "copy_local_u8", translated.copy_local_u8(7));
    try writeCount(writer, "transitive_copy_local_u32", translated.transitive_copy_local_u32(43));
    try writeCount(writer, "transitive_copy_local_u8", translated.transitive_copy_local_u8(8));

    // A source Err leaves during the scalar initializer after the tuple's
    // String exists; only a successful tuple transfers an owner to us.
    const tuple_try_flags = [_]bool{ true, false };
    const tuple_try_keys = [_][]const u8{ "owner_tuple_try_ok", "owner_tuple_try_err" };
    for (tuple_try_flags, tuple_try_keys) |accept, key| {
        var result = try translated.owner_tuple_try(gpa, accept);
        defer r2z.alloc.dropTemporary(gpa, &result);
        switch (result) {
            .Ok => |pair| {
                try writer.print("{s}=ok:", .{key});
                try writeHexBytes(writer, pair[0].as_bytes());
                try writer.print(",{d}\n", .{pair[1]});
            },
            .Err => |code| try writeTaggedCount(writer, key, "err", code),
        }
    }

    const compound = translated.primitive_compound_order();
    try writer.print("primitive_compound_order={d},{d},{d}\n", .{
        compound[0],
        compound[1],
        compound[2],
    });

    var projected_solo = try translated.owner_projected_pair(gpa, false);
    try writeStringRecord(gpa, writer, "owner_projected_pair_solo", &projected_solo);
    var projected_empty = try translated.owner_projected_pair(gpa, true);
    try writeStringRecord(gpa, writer, "owner_projected_pair_empty", &projected_empty);
    const nested_iflet_modes = [_]u8{ 0, 1, 2 };
    const nested_iflet_keys = [_][]const u8{
        "owner_nested_iflet_matched",
        "owner_nested_iflet_unmatched",
        "owner_nested_iflet_absent",
    };
    for (nested_iflet_modes, nested_iflet_keys) |mode, key| {
        var selected = try translated.owner_nested_iflet(gpa, mode);
        try writeStringRecord(gpa, writer, key, &selected);
    }
    try writeCount(
        writer,
        "owner_projected_option_borrow_twice",
        try translated.owner_projected_option_borrow_twice(gpa),
    );
    try writeCount(
        writer,
        "owner_projected_option_none_inspection",
        try translated.owner_projected_option_none_inspection(gpa),
    );
    var projected_option = try translated.owner_projected_option_move(
        gpa,
        try translated.owned(gpa, "abc"),
    );
    try writeStringRecord(gpa, writer, "owner_projected_option_move", &projected_option);
    try writeCount(
        writer,
        "source_string_constructor_value",
        translated.source_string_constructor_value(),
    );
}

pub fn main(init: std.process.Init) !void {
    var records: std.Io.Writer.Allocating = .init(init.gpa);
    defer records.deinit();
    try writeRecords(init.gpa, &records.writer);
    try std.Io.File.stdout().writeStreamingAll(init.io, records.written());
}
