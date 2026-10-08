//! Consumer tests for the translated `differential` package.
//!
//! `test/differential_zig_oracle.zig` builds the canonical records by calling
//! the generated package and `test/differential_rust_oracle.rs` prints the same
//! records from the Rust functions themselves. This file pins those bytes and
//! checks what bytes alone cannot carry: which owner crossed a boundary as
//! which allocation, which one a frame released instead of handing over, and
//! that both arms of every branch ran.
//!
//! Nothing here reimplements a fixture function or restates what the emitted
//! source looks like; every expectation is about the value the package returns
//! and about who owns it afterwards.
//!
//! Built like the `test/compat_consumer.zig` invocation in `test/e2e_test.zig`,
//! with the generated package root in place of the compat one:
//!
//!     zig test --dep translated --dep r2z \
//!         -Mroot=test/differential_consumer.zig \
//!         --dep r2z -Mtranslated=<generated>/src/root.zig \
//!         -Mr2z=r2z-core/src/root.zig

const std = @import("std");
const r2z = @import("r2z");
const translated = @import("translated");
const oracle = @import("differential_zig_oracle.zig");

/// Exactly what `test/differential_rust_oracle.rs` prints for
/// `test/crates/differential/src/lib.rs`: one line per case, byte payloads in
/// lowercase hex, decimal for numbers, and a `tag:` prefix wherever the record
/// has to say which arm of a `Result` or a `Cow` produced the value.
const expected_records =
    \\format=differential-records-v1
    \\nested_lexical=6c65786963616c
    \\nested_branch_0=73656c6563746564
    \\nested_branch_1=6d617463686564
    \\nested_branch_2=6c65786963616c
    \\nested_loop_0=63617272696564
    \\nested_loop_3=2e2e2e63617272696564
    \\nested_method_render=637c72
    \\nested_method_joined=722d63
    \\shadowed=16
    \\conditional_move_taken=676976656e
    \\conditional_move_released=66616c6c6261636b
    \\conditional_match_0=676976656e
    \\conditional_match_1=6669727374
    \\conditional_match_2=7365636f6e64
    \\cleanup_only_callee_first=6
    \\cleanup_only_caller_first=6
    \\overwrite_utf8=ok:6f6b
    \\overwrite_utf8=err:2
    \\overwrite_collection=ok:7265706c6163656d656e74
    \\overwrite_collection=err:4
    \\overwrite_params=7365636f6e64
    \\cow_same_length=borrowed:73616d652d6c656e677468
    \\cow_borrowed=borrowed:616263
    \\cow_repaired=owned:61efbfbd62
    \\utf8_detail_ok=2
    \\utf8_detail_invalid=0
    \\early_exit=err:1
    \\early_exit=ok:63617272696564
    \\fallible_exit=err:4
    \\fallible_exit=ok:6f75746572696e6e657274
    \\cursor_predicate=1,3
    \\cursor_predicate_counter=1234
    \\cursor_owned_predicate=6974656d,6974656d2b
    \\cursor_owned_counter=1234
    \\cursor_owned_reject=
    \\cursor_owned_reject_cursor=12
    \\cursor_owned_empty=
    \\cursor_owned_empty_cursor=0
    \\generic_string_or=6669727374
    \\generic_string_or=7365636f6e64
    \\generic_vector_or=6b657074
    \\generic_vector_or=6c6f7374
    \\generic_context=0,1,2
    \\generic_context=none
    \\loop_exit_natural=2e2e63617272696564
    \\loop_exit_continue=2e2e2e63617272696564
    \\loop_exit_break=2e63617272696564
    \\loop_exit_continue_break=63617272696564
    \\loop_value_round=726f756e64
    \\loop_value_fallback=66616c6c6261636b
    \\method_render_released=637c
    \\method_joined_released=722d
    \\owner_scope_generic=67656e657269632d6f776e6572
    \\owner_scope_core_block=616263
    \\owner_scope_push=707573682d6f776e6572
    \\owner_scope_closure=636170747572652d6f776e6572
    \\owner_scope_repeat_zero=
    \\owner_scope_repeat_zero_cursor=1
    \\owner_scope_repeat_one=7265706561742d6f776e6572
    \\owner_scope_repeat_one_cursor=1
    \\owner_scope_repeat_two=7265706561742d6f776e6572,7265706561742d6f776e6572
    \\owner_scope_repeat_two_cursor=1
    \\owner_scope_repeat_local=7265706561742d6c6f63616c,7265706561742d6c6f63616c
    \\owner_tuple_repeat_0=0
    \\owner_tuple_repeat_1=14
    \\owner_tuple_repeat_3=42
    \\owner_tuple_push=13
    \\owner_byte_repeat_0=0
    \\owner_byte_repeat_0_cursor=1
    \\owner_byte_repeat_1=2
    \\owner_byte_repeat_1_cursor=1
    \\owner_byte_repeat_3=6
    \\owner_byte_repeat_3_cursor=1
    \\guard_dispatch_true=10
    \\guard_dispatch_false=11
    \\guard_dispatch_other=12
    \\constant_guard=11
    \\guarded_index_true=10,1
    \\guarded_index_false=11,1
    \\guarded_index_other=12,1
    \\optional_slot_write=42,1
    \\optional_slot_filled=42
    \\optional_slot_untouched=9
    \\optional_slot_empty=0,1
    \\optional_slot_empty_kept=1
    \\optional_entry_write=42,1
    \\optional_entry_filled=42
    \\optional_entry_untouched=9
    \\optional_entry_empty=0,1
    \\optional_entry_empty_kept=1
    \\owner_arm_move_ok=6d6f766564
    \\owner_arm_move_err=6f74686572
    \\owner_local_result_ok=4
    \\owner_local_result_err=5
    \\shadowed_move=16
    \\guarded_owned_pass=12
    \\guarded_owned_refused=0
    \\guarded_owned_other=40
    \\nested_owned_text=7
    \\nested_owned_width=10
    \\nested_owned_err=5
    \\cow_str_local_borrowed=borrowed:616263
    \\cow_str_local_owned=owned:61efbfbd62
    \\cow_slice_local_borrowed=borrowed:616263
    \\cow_slice_local_owned=owned:61626364
    \\utf8_handoff=ok:6f6b
    \\utf8_handoff=err:0
    \\utf8_handoff=err:2
    \\array_owner_move=6669727374,7365636f6e64
    \\owner_pair_second=7365636f6e64
    \\owner_pair_first=6669727374
    \\owner_pair_absent=616273656e74
    \\staged_scalar_true=11
    \\staged_scalar_false=12
    \\owner_flat_map=0,0,0
    \\owner_flat_map_empty=
    \\owner_zip_mut=7a6970:14,7a6970:15
    \\owner_zip_source=14,15,6
    \\owner_zip_short=7a6970:18
    \\owner_zip_short_source=18
    \\owner_zip_empty=
    \\owner_zip_empty_source=9
    \\owner_result_map_ok=ok:1
    \\owner_result_map_err=err:7
    \\owner_result_map_err_ok=ok:9
    \\owner_result_map_err_err=err:3
    \\owner_result_map_kept_ok=ok:1
    \\owner_result_map_kept_err=err:6b6570742d6572726f72
    \\owner_result_map_err_kept_ok=ok:6b6570742d6f6b
    \\owner_result_map_err_kept_err=err:3
    \\owner_result_parameter_map_ok=ok:1
    \\owner_result_parameter_map_err=err:7
    \\owner_result_parameter_map_err_ok=ok:9
    \\owner_result_parameter_map_err_err=err:3
    \\owner_result_parameter_map_kept_ok=ok:1
    \\owner_result_parameter_map_kept_err=err:6b6570742d6572726f72
    \\owner_result_parameter_map_err_kept_ok=ok:6b6570742d6f6b
    \\owner_result_parameter_map_err_kept_err=err:3
    \\copy_local_u32=42
    \\copy_local_u8=7
    \\transitive_copy_local_u32=43
    \\transitive_copy_local_u8=8
    \\owner_tuple_try_ok=ok:68656c64,7
    \\owner_tuple_try_err=err:2
    \\primitive_compound_order=-4,-1,1234
    \\owner_projected_pair_solo=73656c65637465642d736f6c6f
    \\owner_projected_pair_empty=73656c65637465642d656d707479
    \\owner_nested_iflet_matched=6e6573746564
    \\owner_nested_iflet_unmatched=66616c6c6261636b
    \\owner_nested_iflet_absent=616273656e74
    \\owner_projected_option_borrow_twice=6
    \\owner_projected_option_none_inspection=3
    \\owner_projected_option_move=616263
    \\source_string_constructor_value=41
    \\
;

/// A `Vec<String>` hands its slab back through `deinit`, but each element owns
/// bytes of its own that the slab release does not reach.
fn releaseStringList(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(r2z.alloc.String)) void {
    for (list.items) |*element| element.deinit(gpa);
    list.deinit(gpa);
}

/// The record bytes come from the same calls the Rust oracle makes, so the
/// comparison is Rust's answer against the package's rather than this file's
/// expectation against itself.
fn recordsWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var records: std.Io.Writer.Allocating = .init(gpa);
    defer records.deinit();
    // This exact allocating writer has no failure other than allocation.
    // Its drain erases OutOfMemory to WriteFailed; restore it for the sweep.
    oracle.writeRecords(gpa, &records.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(expected_records, records.written());
}

test "generated records are the bytes the Rust oracle prints" {
    const gpa = std.testing.allocator;
    try recordsWithAllocationFailures(gpa);
    // Every case allocates, so the sweep also covers the release each returned
    // owner needs once the record that read it is written.
    try std.testing.checkAllAllocationFailures(gpa, recordsWithAllocationFailures, .{});
}

test "the source-local String constructor preserves its value" {
    try std.testing.expectEqual(
        @as(u32, 41),
        translated.source_string_constructor_value(),
    );
}

// The bytes below cannot say WHO owns a value after the call. These are the
// claims that need the address: a moved owner is the caller's own allocation
// handed over, not a copy the caller still has to release, and an owner the
// frame released is gone — releasing it here again would be a double free and
// not releasing the frame's copy would be a leak.
test "a moved owner crosses the boundary as the caller's own allocation" {
    const gpa = std.testing.allocator;

    const parameter_given = try translated.owned(gpa, "given");
    var moved = try translated.conditional_move_parameter(gpa, parameter_given, true);
    defer moved.deinit(gpa);
    try std.testing.expectEqualStrings("given", moved.as_str());
    try std.testing.expectEqual(
        @intFromPtr(parameter_given.as_bytes().ptr),
        @intFromPtr(moved.as_bytes().ptr),
    );

    const match_given = try translated.owned(gpa, "given");
    var matched = try translated.conditional_move_match(gpa, 0, match_given);
    defer matched.deinit(gpa);
    try std.testing.expectEqualStrings("given", matched.as_str());
    try std.testing.expectEqual(
        @intFromPtr(match_given.as_bytes().ptr),
        @intFromPtr(matched.as_bytes().ptr),
    );
}

test "the arm that was not taken releases the caller's owner instead of leaking it" {
    const gpa = std.testing.allocator;

    // The frame owns the released arm and frees it; this test must not free it
    // a second time, and the testing allocator reports it if the frame leaks.
    var released = try translated.conditional_move_parameter(
        gpa,
        try translated.owned(gpa, "dropped"),
        false,
    );
    defer released.deinit(gpa);
    try std.testing.expectEqualStrings("fallback", released.as_str());

    var second_arm = try translated.conditional_move_match(
        gpa,
        1,
        try translated.owned(gpa, "dropped"),
    );
    defer second_arm.deinit(gpa);
    try std.testing.expectEqualStrings("first", second_arm.as_str());

    var third_arm = try translated.conditional_move_match(
        gpa,
        2,
        try translated.owned(gpa, "dropped"),
    );
    defer third_arm.deinit(gpa);
    try std.testing.expectEqualStrings("second", third_arm.as_str());
}

/// Every entry point of the first sections of the fixture, once, through both
/// arms of every branch. The entry points that carry a claim of their own —
/// the ownership witnesses below — have their own groups instead, each with
/// its own sweep.
/// Each returned owner is released exactly once here, so the testing allocator
/// turns a frame that kept a second reference, or released one twice, into a
/// failure — and the sweep below runs all of it again for every allocation it
/// makes, so a frame that fails to release what it already owns when the next
/// allocation fails fails too.
fn differentialOwnersWithAllocationFailures(gpa: std.mem.Allocator) !void {
    // 1. owners in nested scopes.
    var lexical = try translated.nested_lexical_owner(gpa);
    defer lexical.deinit(gpa);
    try std.testing.expectEqualStrings("lexical", lexical.as_str());

    const branch_modes = [_]u8{ 0, 1, 2 };
    const branch_expected = [_][]const u8{ "selected", "matched", "lexical" };
    for (branch_modes, branch_expected) |mode, expected| {
        var owner = try translated.nested_branch_owner(gpa, mode);
        defer owner.deinit(gpa);
        try std.testing.expectEqualStrings(expected, owner.as_str());
    }

    const loop_limits = [_]u8{ 0, 3 };
    const loop_expected = [_][]const u8{ "carried", "...carried" };
    for (loop_limits, loop_expected) |limit, expected| {
        var owner = try translated.nested_loop_owner(gpa, limit);
        defer owner.deinit(gpa);
        try std.testing.expectEqualStrings(expected, owner.as_str());
    }

    var rendered = try translated.nested_method_render(gpa, "|");
    defer rendered.deinit(gpa);
    try std.testing.expectEqualStrings("c|r", rendered.as_str());

    var joined = try translated.nested_method_joined(gpa);
    defer joined.deinit(gpa);
    try std.testing.expectEqualStrings("r-c", joined.as_str());

    // The same two methods through the arm that releases the block-local owner
    // instead of moving it out, so both directions of each conditional move
    // run and neither method is only ever seen taking the same route.
    var released_render = try translated.nested_method_render_released(gpa, "|");
    defer released_render.deinit(gpa);
    try std.testing.expectEqualStrings("c|", released_render.as_str());

    var released_join = try translated.nested_method_joined_released(gpa);
    defer released_join.deinit(gpa);
    try std.testing.expectEqualStrings("r-", released_join.as_str());

    // Two bindings, one source name: both owners are live at the same time,
    // so a release keyed by the name rather than by the binding frees the
    // wrong one.
    try std.testing.expectEqual(@as(usize, 16), try translated.shadowed_length(gpa));

    // 2. moves that depend on a branch.
    var taken = try translated.conditional_move_parameter(
        gpa,
        try translated.owned(gpa, "given"),
        true,
    );
    defer taken.deinit(gpa);
    try std.testing.expectEqualStrings("given", taken.as_str());

    const match_modes = [_]u8{ 0, 1, 2 };
    const match_expected = [_][]const u8{ "given", "first", "second" };
    for (match_modes, match_expected) |mode, expected| {
        var owner = try translated.conditional_move_match(
            gpa,
            mode,
            try translated.owned(gpa, "given"),
        );
        defer owner.deinit(gpa);
        try std.testing.expectEqualStrings(expected, owner.as_str());
    }

    // A frame that only reads its owner parameter releases it, so this one
    // hands an owner in and never frees it: a callee that leaks it shows up
    // as a leak and one that frees it twice as a double free.
    try std.testing.expectEqual(
        @as(usize, 6),
        translated.cleanup_only_text(gpa, try translated.owned(gpa, "foobar")),
    );
    try std.testing.expectEqual(
        @as(usize, 6),
        try translated.cleanup_only_caller_callee_first(gpa),
    );
    try std.testing.expectEqual(@as(usize, 6), try translated.cleanup_only_caller_first(gpa));

    // 3. overwrites whose right-hand side can fail.
    var replaced = try translated.overwrite_from_utf8(gpa, "held", true);
    defer r2z.alloc.dropTemporary(gpa, &replaced);
    try std.testing.expect(replaced == .Ok);
    try std.testing.expectEqualStrings("ok", replaced.Ok.as_str());

    var refused = try translated.overwrite_from_utf8(gpa, "held", false);
    defer r2z.alloc.dropTemporary(gpa, &refused);
    try std.testing.expect(refused == .Err);
    try std.testing.expectEqual(@as(u8, 2), refused.Err);

    var collection = try translated.overwrite_collection(gpa, true);
    defer r2z.alloc.dropTemporary(gpa, &collection);
    try std.testing.expect(collection == .Ok);
    try std.testing.expectEqual(@as(usize, 1), collection.Ok.items.len);
    try std.testing.expectEqualStrings("replacement", collection.Ok.items[0].as_str());

    var rejected = try translated.overwrite_collection(gpa, false);
    defer r2z.alloc.dropTemporary(gpa, &rejected);
    try std.testing.expect(rejected == .Err);
    try std.testing.expectEqual(@as(u8, 4), rejected.Err);

    // Both operands arrive as owners, and the surviving one leaves as the
    // caller's own allocation rather than a copy of it.
    var second_pointer: usize = undefined;
    var overwritten = blk: {
        var first_param = try translated.owned(gpa, "first");
        errdefer first_param.deinit(gpa);
        const second_param = try translated.owned(gpa, "second");
        second_pointer = @intFromPtr(second_param.as_bytes().ptr);
        break :blk translated.overwrite_owner_params(gpa, first_param, second_param);
    };
    defer overwritten.deinit(gpa);
    try std.testing.expectEqualStrings("second", overwritten.as_str());
    try std.testing.expectEqual(
        second_pointer,
        @intFromPtr(overwritten.as_bytes().ptr),
    );

    // A cow that borrows the caller's bytes must still alias them afterwards,
    // and one that owns repaired bytes must not.
    const valid = "abc";
    var borrowed = try translated.nested_cow_text(gpa, "p", valid);
    defer borrowed.deinit(gpa);
    try std.testing.expect(borrowed == .Borrowed);
    try std.testing.expectEqualStrings(valid, borrowed.as_ref());
    try std.testing.expectEqual(@intFromPtr(valid.ptr), @intFromPtr(borrowed.as_ref().ptr));

    var repaired = try translated.nested_cow_text(gpa, "p", "a\xffb");
    defer repaired.deinit(gpa);
    try std.testing.expect(repaired == .Owned);
    try std.testing.expectEqualStrings("a\xef\xbf\xbdb", repaired.as_ref());

    var same_length = try translated.nested_cow_text(gpa, "p", "ab");
    defer same_length.deinit(gpa);
    try std.testing.expect(same_length == .Borrowed);
    try std.testing.expectEqualStrings("same-length", same_length.as_ref());

    // The conversion error owns the bytes that failed, and reading its detail
    // only borrows them, so the failing arm has to release the wrapper and
    // the successful arm has to be untouched by the same rule.
    try std.testing.expectEqual(@as(usize, 2), try translated.utf8_error_detail(gpa, "ok"));
    try std.testing.expectEqual(@as(usize, 0), try translated.utf8_error_detail(gpa, "\xff"));

    // 4. frames that leave early.
    var rejected_exit = try translated.early_exit(gpa, true);
    defer r2z.alloc.dropTemporary(gpa, &rejected_exit);
    try std.testing.expect(rejected_exit == .Err);
    try std.testing.expectEqual(@as(u8, 1), rejected_exit.Err);

    var accepted_exit = try translated.early_exit(gpa, false);
    defer r2z.alloc.dropTemporary(gpa, &accepted_exit);
    try std.testing.expect(accepted_exit == .Ok);
    try std.testing.expectEqualStrings("carried", accepted_exit.Ok.as_str());

    var rejected_depth = try translated.fallible_exit(gpa, 0);
    defer r2z.alloc.dropTemporary(gpa, &rejected_depth);
    try std.testing.expect(rejected_depth == .Err);
    try std.testing.expectEqual(@as(u8, 4), rejected_depth.Err);

    var accepted_depth = try translated.fallible_exit(gpa, 1);
    defer r2z.alloc.dropTemporary(gpa, &accepted_depth);
    try std.testing.expect(accepted_depth == .Ok);
    try std.testing.expectEqualStrings("outerinnert", accepted_depth.Ok.as_str());

    // The same exits inside a loop body: every route builds the same two known
    // owners there — a string and a vector — and releases them before it
    // leaves, so these four calls between them cover the natural exit, the
    // `continue`, the `break`, and a `continue` followed by that `break`.
    const LoopExit = struct { limit: u8, stop_at: u8, skip_first: bool, expected: []const u8 };
    const loop_exit_cases = [_]LoopExit{
        .{ .limit = 2, .stop_at = 9, .skip_first = false, .expected = "..carried" },
        .{ .limit = 4, .stop_at = 9, .skip_first = true, .expected = "...carried" },
        .{ .limit = 4, .stop_at = 1, .skip_first = false, .expected = ".carried" },
        .{ .limit = 4, .stop_at = 1, .skip_first = true, .expected = "carried" },
    };
    for (loop_exit_cases) |case| {
        var owner = try translated.loop_exit_owners(gpa, case.limit, case.stop_at, case.skip_first);
        defer owner.deinit(gpa);
        try std.testing.expectEqualStrings(case.expected, owner.as_str());
    }

    // The `break` that carries a value: the loop-local owner leaves on one
    // route and the outer one on the other, and whichever was not taken is
    // released inside the frame.
    var round_route = try translated.loop_value_owner(gpa, 1);
    defer round_route.deinit(gpa);
    try std.testing.expectEqualStrings("round", round_route.as_str());

    var fallback_route = try translated.loop_value_owner(gpa, 5);
    defer fallback_route.deinit(gpa);
    try std.testing.expectEqualStrings("fallback", fallback_route.as_str());

    // 5. a scan whose effects reach the caller's own counter.
    var cursor: u32 = 0;
    var kept = try translated.cursor_predicate_effects(gpa, &.{ 1, 2, 3, 4 }, &cursor);
    defer kept.deinit(gpa);
    try std.testing.expectEqualSlices(u32, &.{ 1, 3 }, kept.items);
    try std.testing.expectEqual(@as(u32, 1234), cursor);

    var owned_cursor: u32 = 0;
    var owned_kept = try translated.cursor_owned_predicate(gpa, &.{ 1, 2, 3, 4 }, &owned_cursor);
    defer releaseStringList(gpa, &owned_kept);
    try std.testing.expectEqual(@as(usize, 2), owned_kept.items.len);
    try std.testing.expectEqualStrings("item", owned_kept.items[0].as_str());
    try std.testing.expectEqualStrings("item+", owned_kept.items[1].as_str());
    try std.testing.expectEqual(@as(u32, 1234), owned_cursor);

    // 6. generic calls whose instantiation the call site decides.
    var first_arm = try translated.generic_string_or(gpa, true);
    defer first_arm.deinit(gpa);
    try std.testing.expectEqualStrings("first", first_arm.as_str());

    var second_arm = try translated.generic_string_or(gpa, false);
    defer second_arm.deinit(gpa);
    try std.testing.expectEqualStrings("second", second_arm.as_str());

    var kept_vector = try translated.generic_vector_or(gpa, true);
    defer releaseStringList(gpa, &kept_vector);
    try std.testing.expectEqual(@as(usize, 1), kept_vector.items.len);
    try std.testing.expectEqualStrings("kept", kept_vector.items[0].as_str());

    var lost_vector = try translated.generic_vector_or(gpa, false);
    defer releaseStringList(gpa, &lost_vector);
    try std.testing.expectEqual(@as(usize, 1), lost_vector.items.len);
    try std.testing.expectEqualStrings("lost", lost_vector.items[0].as_str());

    var present = try translated.generic_context_only(gpa, true);
    defer r2z.alloc.dropTemporary(gpa, &present);
    try std.testing.expect(present != null);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, present.?.items);

    var absent = try translated.generic_context_only(gpa, false);
    defer r2z.alloc.dropTemporary(gpa, &absent);
    try std.testing.expect(absent == null);
}

test "every generated entry point hands its owner over or releases it exactly once" {
    const gpa = std.testing.allocator;
    try differentialOwnersWithAllocationFailures(gpa);
    try std.testing.checkAllAllocationFailures(gpa, differentialOwnersWithAllocationFailures, .{});
}

fn ownedFilterBoundariesWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var rejected_cursor: u32 = 0;
    var rejected = try translated.cursor_owned_predicate(gpa, &.{ 2, 4 }, &rejected_cursor);
    defer releaseStringList(gpa, &rejected);
    try std.testing.expectEqual(@as(usize, 0), rejected.items.len);
    try std.testing.expectEqual(@as(u32, 12), rejected_cursor);

    var retained_cursor: u32 = 0;
    var retained = try translated.cursor_owned_predicate(gpa, &.{ 1, 3 }, &retained_cursor);
    defer releaseStringList(gpa, &retained);
    try std.testing.expectEqual(@as(usize, 2), retained.items.len);
    try std.testing.expectEqualStrings("item", retained.items[0].as_str());
    try std.testing.expectEqualStrings("item+", retained.items[1].as_str());
    try std.testing.expectEqual(@as(u32, 12), retained_cursor);

    var empty_cursor: u32 = 7;
    var empty = try translated.cursor_owned_predicate(gpa, &.{}, &empty_cursor);
    defer releaseStringList(gpa, &empty);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    try std.testing.expectEqual(@as(u32, 7), empty_cursor);
}

test "owned filtering releases rejected elements and preserves retained allocations on every failure" {
    try ownedFilterBoundariesWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        ownedFilterBoundariesWithAllocationFailures,
        .{},
    );
}

fn ownerScopeCallsWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var generic = try translated.owner_scope_generic_string(gpa);
    defer generic.deinit(gpa);
    try std.testing.expectEqualStrings("generic-owner", generic.as_str());

    var nested = try translated.owner_scope_core_argument_block(gpa);
    defer nested.deinit(gpa);
    try std.testing.expectEqualStrings("abc", nested.as_str());

    var captured = try translated.owner_scope_move_closure(gpa);
    defer captured.deinit(gpa);
    try std.testing.expectEqualStrings("capture-owner", captured.as_str());
}

test "generic calls core argument blocks and move closures transfer owning locals" {
    try ownerScopeCallsWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        ownerScopeCallsWithAllocationFailures,
        .{},
    );
}

fn ownerScopePushWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var values = try translated.owner_scope_push_string(gpa);
    defer releaseStringList(gpa, &values);
    try std.testing.expectEqual(@as(usize, 1), values.items.len);
    try std.testing.expectEqualStrings("push-owner", values.items[0].as_str());
}

test "Vec push consumes its String on success and releases it on allocation failure" {
    try ownerScopePushWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        ownerScopePushWithAllocationFailures,
        .{},
    );
}

fn ownerScopeRepeatWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var zero_counter: u32 = 0;
    var zero = try translated.owner_scope_repeat_zero(gpa, &zero_counter);
    defer releaseStringList(gpa, &zero);
    try std.testing.expectEqual(@as(usize, 0), zero.items.len);
    try std.testing.expectEqual(@as(u32, 1), zero_counter);

    var one_counter: u32 = 0;
    var one = try translated.owner_scope_repeat_one(gpa, &one_counter);
    defer releaseStringList(gpa, &one);
    try std.testing.expectEqual(@as(usize, 1), one.items.len);
    try std.testing.expectEqualStrings("repeat-owner", one.items[0].as_str());
    try std.testing.expectEqual(@as(u32, 1), one_counter);

    var two_counter: u32 = 0;
    var two = try translated.owner_scope_repeat_two(gpa, &two_counter);
    defer releaseStringList(gpa, &two);
    try std.testing.expectEqual(@as(usize, 2), two.items.len);
    try std.testing.expectEqual(@as(u32, 1), two_counter);
    for (two.items) |value| try std.testing.expectEqualStrings("repeat-owner", value.as_str());
    try std.testing.expect(two.items[0].as_bytes().ptr != two.items[1].as_bytes().ptr);
    try two.items[0].push_str(gpa, "!");
    try std.testing.expectEqualStrings("repeat-owner!", two.items[0].as_str());
    try std.testing.expectEqualStrings("repeat-owner", two.items[1].as_str());

    var local = try translated.owner_scope_repeat_local(gpa);
    defer releaseStringList(gpa, &local);
    try std.testing.expectEqual(@as(usize, 2), local.items.len);
    for (local.items) |value| try std.testing.expectEqualStrings("repeat-local", value.as_str());
    try std.testing.expect(local.items[0].as_bytes().ptr != local.items[1].as_bytes().ptr);
    try local.items[0].push_str(gpa, "!");
    try std.testing.expectEqualStrings("repeat-local!", local.items[0].as_str());
    try std.testing.expectEqualStrings("repeat-local", local.items[1].as_str());
}

test "Vec repetition evaluates owners once and releases independent clones at every failure" {
    try ownerScopeRepeatWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        ownerScopeRepeatWithAllocationFailures,
        .{},
    );
}

fn ownerScopeTupleWrappersWithAllocationFailures(gpa: std.mem.Allocator) !void {
    // A tuple wrapper owns its string and carries a tag beside it, and nothing
    // here hands a wrapper back: every string is built, moved or cloned inside
    // the call and released there. So the testing allocator is what carries
    // the rest of the claim — a wrapper that kept a second reference to the
    // bytes it moved, or a clone that aliased the original instead of owning a
    // separate allocation, frees the same storage twice and fails here, and a
    // wrapper that dropped the source copy or the destination copy leaks it.
    //
    // Zero elements build the wrapper and release it, one moves the string
    // whole, and three take two clones plus one move; the totals are read back
    // through the wrappers rather than out of them.
    try std.testing.expectEqual(@as(usize, 0), try translated.owner_tuple_repeat(gpa, 0));
    try std.testing.expectEqual(@as(usize, 14), try translated.owner_tuple_repeat(gpa, 1));
    try std.testing.expectEqual(@as(usize, 42), try translated.owner_tuple_repeat(gpa, 3));

    // Push takes the whole wrapper: the string and its tag cross into the
    // destination together, so a push that stored the wrapper and then dropped
    // the value it already moved frees it twice, and one that drops neither
    // leaks it.
    try std.testing.expectEqual(@as(usize, 13), try translated.owner_tuple_push(gpa));
}

test "Vec repetition and push take the string out of a tuple wrapper once at every failure" {
    try ownerScopeTupleWrappersWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        ownerScopeTupleWrappersWithAllocationFailures,
        .{},
    );
}

fn ownerByteRepeatWithAllocationFailures(gpa: std.mem.Allocator) !void {
    // The element owns nothing, so the `usize` the caller passes decides the
    // length and is the only thing it decides: the returned total is that
    // length plus the one value the element expression produced, as many times
    // as there were slots. A count the caller never reaches — zero — still
    // evaluates the element, which is what the cursor records, and a count
    // that runs the element once per slot would leave the cursor at the slot
    // count instead of at one.
    var empty_cursor: u32 = 0;
    try std.testing.expectEqual(
        @as(usize, 0),
        try translated.owner_byte_repeat(gpa, 0, &empty_cursor),
    );
    try std.testing.expectEqual(@as(u32, 1), empty_cursor);

    var single_cursor: u32 = 0;
    try std.testing.expectEqual(
        @as(usize, 2),
        try translated.owner_byte_repeat(gpa, 1, &single_cursor),
    );
    try std.testing.expectEqual(@as(u32, 1), single_cursor);

    var repeated_cursor: u32 = 0;
    try std.testing.expectEqual(
        @as(usize, 6),
        try translated.owner_byte_repeat(gpa, 3, &repeated_cursor),
    );
    try std.testing.expectEqual(@as(u32, 1), repeated_cursor);

    // The vector is built and released inside the call, so a staging value
    // that outlived the loop, or a destination that kept a slot it was never
    // given, only shows up as a leak or as a total that does not match.
}

test "a runtime Vec repeat count stores one evaluated non-owning element at every failure" {
    try ownerByteRepeatWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        ownerByteRepeatWithAllocationFailures,
        .{},
    );
}

// The cases below allocate nothing — an enum payload, an `Option` payload, a
// slice element and a caller's own counter are the only things they move — so
// there is no allocation to fail here. What they carry is the aliasing: which
// storage a dispatch wrote into, how many times the scrutinee ran, and which
// arm a guard selected. The record stream above calls every one of them inside
// its own failure sweep.

test "a guard decides between two arms that name the same selector" {
    try std.testing.expectEqual(@as(u8, 10), translated.guard_dispatch(1, true));
    try std.testing.expectEqual(@as(u8, 11), translated.guard_dispatch(1, false));
    // The guard holds, but this value is not the selector the guarded arm names.
    try std.testing.expectEqual(@as(u8, 12), translated.guard_dispatch(2, true));
    // Neither arm's selector reaches it, with or without the guard.
    try std.testing.expectEqual(@as(u8, 12), translated.guard_dispatch(2, false));
}

test "a constant false guard hands the repeated selector to the next arm" {
    try std.testing.expectEqual(@as(u8, 11), translated.constant_guard_dispatch());
}

test "a side-effecting indexed scrutinee is read once and reaches the guarded arm" {
    var cursor: u32 = 0;
    const held = translated.guarded_index_dispatch(&.{1}, 0, true, &cursor);
    try std.testing.expectEqual(@as(u8, 10), held[0]);
    // One read of the scrutinee, however many dispatches look at it.
    try std.testing.expectEqual(@as(u32, 1), held[1]);

    cursor = 0;
    const refused = translated.guarded_index_dispatch(&.{1}, 0, false, &cursor);
    try std.testing.expectEqual(@as(u8, 11), refused[0]);
    try std.testing.expectEqual(@as(u32, 1), refused[1]);

    cursor = 0;
    const other = translated.guarded_index_dispatch(&.{9}, 0, true, &cursor);
    try std.testing.expectEqual(@as(u8, 12), other[0]);
    try std.testing.expectEqual(@as(u32, 1), other[1]);

    // The index the caller names is the element that is read, and reading it
    // moved the counter exactly once.
    cursor = 0;
    const second = translated.guarded_index_dispatch(&.{ 9, 1 }, 1, true, &cursor);
    try std.testing.expectEqual(@as(u8, 10), second[0]);
    try std.testing.expectEqual(@as(u32, 1), second[1]);
}

test "a reference payload writes into the caller's own slot and leaves the rest alone" {
    var filled: [2]translated.Slot = .{ .{ .Filled = 9 }, .{ .Filled = 9 } };
    var cursor: u32 = 0;
    try std.testing.expectEqual(
        @as(u32, 42),
        translated.optional_slot_write(&filled, 0, 42, &cursor),
    );
    try std.testing.expectEqual(@as(u32, 1), cursor);
    // The element the index named holds what the arm wrote, and the element it
    // did not reach still holds what the caller built it with.
    try std.testing.expectEqual(@as(u32, 42), translated.slot_payload(filled[0]));
    try std.testing.expectEqual(@as(u32, 9), translated.slot_payload(filled[1]));

    // An empty slot has nothing to write: the arm answers zero, the slot it
    // did not reach is untouched, and the index still ran once.
    var mixed: [2]translated.Slot = .{ .{ .Filled = 1 }, .{ .Empty = {} } };
    cursor = 0;
    try std.testing.expectEqual(
        @as(u32, 0),
        translated.optional_slot_write(&mixed, 1, 7, &cursor),
    );
    try std.testing.expectEqual(@as(u32, 1), cursor);
    try std.testing.expectEqual(@as(u32, 1), translated.slot_payload(mixed[0]));
    // The tag is what says the write never turned the empty slot into a filled
    // one: the payload reader answers zero for both.
    try std.testing.expect(std.meta.activeTag(mixed[1]) == .Empty);
}

// The scrutinee here is a real `Option`, so the dispatch binds the subject
// itself rather than reading a variant field out of it, and the arm's
// reference binding has to reach through that binding into the caller's own
// element. The index expression is the caller's counter and the untouched
// element is read back through the package, so a write that landed in the copy
// the frame made of the subject shows up as the old value. Nothing here
// allocates — an `Option` payload and a caller's own counter are the only
// things that move — so there is no allocation to fail; the record stream
// above runs these calls inside its own failure sweep.
test "an option payload writes into the caller's own element and leaves the rest alone" {
    var filled: [2]?u32 = .{ 9, 9 };
    var cursor: u32 = 0;
    try std.testing.expectEqual(
        @as(u32, 42),
        translated.optional_entry_write(&filled, 0, 42, &cursor),
    );
    // The index expression runs exactly once however the subject is bound.
    try std.testing.expectEqual(@as(u32, 1), cursor);
    try std.testing.expectEqual(@as(u32, 42), translated.optional_entry_value(filled[0]));
    try std.testing.expectEqual(@as(u32, 9), translated.optional_entry_value(filled[1]));

    // A `None` element has no payload to write: the arm answers zero, the
    // element the index did not reach keeps what the caller built, and the
    // empty element is still empty rather than turned into a payload.
    var mixed: [2]?u32 = .{ 1, null };
    cursor = 0;
    try std.testing.expectEqual(
        @as(u32, 0),
        translated.optional_entry_write(&mixed, 1, 7, &cursor),
    );
    try std.testing.expectEqual(@as(u32, 1), cursor);
    try std.testing.expectEqual(@as(u32, 1), translated.optional_entry_value(mixed[0]));
    try std.testing.expectEqual(@as(u32, 0), translated.optional_entry_value(mixed[1]));
    try std.testing.expect(mixed[1] == null);
}

/// The subject of this dispatch is a temporary the frame never names, and the
/// first arm binds its payload and hands it to the caller. Those bytes have to
/// cross as the allocation the arm built: a release that missed the transfer
/// frees them a second time, and a transfer that never happened leaves the
/// payload the arm stopped owning with no owner at all. The second arm binds no
/// payload, so the refusal route owes nothing and builds its own string.
fn ownerArmPayloadWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var moved = try translated.owner_arm_payload_move(gpa, true);
    defer moved.deinit(gpa);
    try std.testing.expectEqualStrings("moved", moved.as_str());

    var refused = try translated.owner_arm_payload_move(gpa, false);
    defer refused.deinit(gpa);
    try std.testing.expectEqualStrings("other", refused.as_str());
}

test "a match arm hands the payload of a temporary subject to the caller" {
    try ownerArmPayloadWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        ownerArmPayloadWithAllocationFailures,
        .{},
    );
}

/// The union here is a local this frame owns and the arm only reads the payload
/// it bound, so the frame owes exactly one release for the whole value: a
/// second one for the arm payload frees the same bytes twice.
fn ownerLocalUnionWithAllocationFailures(gpa: std.mem.Allocator) !void {
    try std.testing.expectEqual(@as(usize, 4), try translated.owner_local_result_match(gpa, true));
    try std.testing.expectEqual(@as(usize, 5), try translated.owner_local_result_match(gpa, false));
}

test "a local union is released once whichever arm read its payload" {
    try ownerLocalUnionWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        ownerLocalUnionWithAllocationFailures,
        .{},
    );
}

/// Both bindings share one source name and both are live at once, and here the
/// inner one is the binding that moves: its bytes have to reach the caller as
/// the allocation they already were while the outer string is released here.
fn shadowedMoveWithAllocationFailures(gpa: std.mem.Allocator) !void {
    try std.testing.expectEqual(@as(usize, 16), try translated.shadowed_move_length(gpa));
}

test "the shadowed binding that moves hands its own allocation over" {
    try shadowedMoveWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        shadowedMoveWithAllocationFailures,
        .{},
    );
}

/// The guarded arm reads the payload of the variant it names before it decides
/// whether to run at all, so the route where the guard refuses has to release
/// that string before the arm behind it runs — and that arm still owns it.
fn guardedOwnedPayloadWithAllocationFailures(gpa: std.mem.Allocator) !void {
    // The guard holds, so the arm that moved the payload out answers.
    try std.testing.expectEqual(
        @as(usize, 12),
        try translated.guarded_owned_payload(gpa, false, "named-value"),
    );
    // The guard refuses, and the arm behind it answers from the same value.
    try std.testing.expectEqual(
        @as(usize, 0),
        try translated.guarded_owned_payload(gpa, false, "named"),
    );
    // A variant the guarded arm does not name is released on its own route.
    try std.testing.expectEqual(
        @as(usize, 40),
        try translated.guarded_owned_payload(gpa, true, "bare"),
    );
}

test "a guarded arm releases the owned payload it refused at every failure" {
    try guardedOwnedPayloadWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        guardedOwnedPayloadWithAllocationFailures,
        .{},
    );
}

/// The payload travels out of the variant nested inside the union on the arm
/// that selected it, the arm behind it owns nothing but the tag, and the error
/// route owns nothing at all, so all three subjects release differently.
fn nestedOwnedPayloadWithAllocationFailures(gpa: std.mem.Allocator) !void {
    try std.testing.expectEqual(@as(usize, 7), try translated.nested_owned_payload(gpa, 0));
    try std.testing.expectEqual(@as(usize, 10), try translated.nested_owned_payload(gpa, 1));
    try std.testing.expectEqual(@as(usize, 5), try translated.nested_owned_payload(gpa, 2));
}

test "a nested owned variant moves its payload out of the union that held it" {
    try nestedOwnedPayloadWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        nestedOwnedPayloadWithAllocationFailures,
        .{},
    );
}

/// Both cows are locals this frame owns and the return moves them whole, so
/// the borrowed arm still names the caller's bytes after the call while the
/// owned arm owns storage nothing else points at.
fn cowLocalMovesWithAllocationFailures(gpa: std.mem.Allocator) !void {
    const valid = "abc";
    var borrowed = try translated.cow_str_local_move(gpa, valid);
    defer borrowed.deinit(gpa);
    try std.testing.expect(borrowed == .Borrowed);
    try std.testing.expectEqualStrings(valid, borrowed.as_ref());
    try std.testing.expectEqual(@intFromPtr(valid.ptr), @intFromPtr(borrowed.as_ref().ptr));

    const invalid = "a\xffb";
    var repaired = try translated.cow_str_local_move(gpa, invalid);
    defer repaired.deinit(gpa);
    try std.testing.expect(repaired == .Owned);
    try std.testing.expectEqualStrings("a\xef\xbf\xbdb", repaired.as_ref());
    // The owned arm does not name the caller's bytes at all, so the release
    // below frees storage of its own rather than the caller's input.
    try std.testing.expect(@intFromPtr(repaired.as_ref().ptr) != @intFromPtr(invalid.ptr));

    var borrowed_bytes = try translated.cow_slice_local_move(gpa, valid);
    defer borrowed_bytes.deinit(gpa);
    try std.testing.expect(borrowed_bytes == .Borrowed);
    try std.testing.expectEqualSlices(u8, valid, borrowed_bytes.as_ref());
    try std.testing.expectEqual(@intFromPtr(valid.ptr), @intFromPtr(borrowed_bytes.as_ref().ptr));

    var owned_bytes = try translated.cow_slice_local_move(gpa, "abcd");
    defer owned_bytes.deinit(gpa);
    try std.testing.expect(owned_bytes == .Owned);
    try std.testing.expectEqualSlices(u8, "abcd", owned_bytes.as_ref());
}

test "a moved cow keeps the arm it carried and the bytes it points at" {
    try cowLocalMovesWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        cowLocalMovesWithAllocationFailures,
        .{},
    );
}

/// The failing arm hands the payload to the caller, so the release below is
/// the only one: a frame that dropped the error as well frees those bytes
/// twice, and one that dropped neither leaks them. The bytes the error still
/// owns are the ones the caller handed in, which is what says the payload
/// crossed instead of being rebuilt.
fn utf8ErrorHandoffWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var accepted = try translated.utf8_error_handoff(gpa, "ok");
    defer r2z.alloc.dropTemporary(gpa, &accepted);
    try std.testing.expect(accepted == .Ok);
    try std.testing.expectEqualStrings("ok", accepted.Ok.as_str());

    var refused = try translated.utf8_error_handoff(gpa, "\xff");
    defer r2z.alloc.dropTemporary(gpa, &refused);
    try std.testing.expect(refused == .Err);
    try std.testing.expectEqualStrings("\xff", refused.Err.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), refused.Err.utf8_error().valid_up_to);

    var partial = try translated.utf8_error_handoff(gpa, "ab\xff");
    defer r2z.alloc.dropTemporary(gpa, &partial);
    try std.testing.expect(partial == .Err);
    try std.testing.expectEqualStrings("ab\xff", partial.Err.bytes.items);
    try std.testing.expectEqual(@as(usize, 2), partial.Err.utf8_error().valid_up_to);
}

test "a conversion error hands its owned bytes to the caller at every failure" {
    try utf8ErrorHandoffWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        utf8ErrorHandoffWithAllocationFailures,
        .{},
    );
}

/// Both elements are owners and the whole array crossed a call by value, so
/// each one arrives as the allocation it already was and each is released on
/// its own afterwards.
fn arrayOwnerMoveWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var owners = try translated.array_owner_move(gpa);
    defer r2z.alloc.dropTemporary(gpa, &owners);
    try std.testing.expectEqualStrings("first", owners[0].as_str());
    try std.testing.expectEqualStrings("second", owners[1].as_str());
    // Two elements and two allocations: a move that had aliased them would
    // make a write through one visible in the other.
    try std.testing.expect(owners[0].as_bytes().ptr != owners[1].as_bytes().ptr);
    try owners[0].push_str(gpa, "!");
    try std.testing.expectEqualStrings("first!", owners[0].as_str());
    try std.testing.expectEqualStrings("second", owners[1].as_str());
}

test "an array of owners crosses a call element by element at every failure" {
    try arrayOwnerMoveWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        arrayOwnerMoveWithAllocationFailures,
        .{},
    );
}

fn pairPayloadWithAllocationFailures(gpa: std.mem.Allocator) !void {
    const modes = [_]u8{ 0, 0, 2 };
    const guards = [_]bool{ true, false, true };
    const expected = [_][]const u8{ "second", "first", "absent" };
    for (modes, guards, expected) |mode, guard, bytes| {
        var selected = try translated.owner_pair_payload(gpa, mode, guard);
        defer selected.deinit(gpa);
        try std.testing.expectEqualStrings(bytes, selected.as_str());
        // A retained allocation remains writable after the unreturned field
        // has been released. A dangling alias cannot satisfy this handoff.
        try selected.push_str(gpa, "!");
        var buffer: [16]u8 = undefined;
        try std.testing.expectEqualStrings(
            try std.fmt.bufPrint(&buffer, "{s}!", .{bytes}),
            selected.as_str(),
        );
    }
}

test "a multi-owner enum transfers the selected field after guard acceptance or rejection" {
    try pairPayloadWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        pairPayloadWithAllocationFailures,
        .{},
    );
}

fn stagedScalarWithAllocationFailures(gpa: std.mem.Allocator) !void {
    try std.testing.expectEqual(@as(usize, 11), try translated.staged_scalar_owner_call(gpa, true));
    try std.testing.expectEqual(@as(usize, 12), try translated.staged_scalar_owner_call(gpa, false));
}

test "a staged scalar argument keeps its u32 context between owner transfers" {
    try stagedScalarWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        stagedScalarWithAllocationFailures,
        .{},
    );
}

fn flatMapOwnerWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var values = try translated.owner_flat_map_consume(gpa, 3);
    defer values.deinit(gpa);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0 }, values.items);

    var empty = try translated.owner_flat_map_consume(gpa, 0);
    defer empty.deinit(gpa);
    try std.testing.expectEqualSlices(u32, &.{}, empty.items);
}

test "an owning map item transfers through flat_map into its consuming closure" {
    try flatMapOwnerWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        flatMapOwnerWithAllocationFailures,
        .{},
    );
}

fn zipMutableOwnerWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var input = [_]u32{ 4, 5, 6 };
    var pairs = try translated.owner_zip_mut(gpa, &input, 2);
    defer r2z.alloc.dropTemporary(gpa, &pairs);
    try std.testing.expectEqual(@as(usize, 2), pairs.items.len);
    for (pairs.items, 0..) |*pair, index| {
        try std.testing.expectEqualStrings("zip", pair[0].as_str());
        try std.testing.expectEqual(@intFromPtr(&input[index]), @intFromPtr(pair[1]));
        pair[1].* += 10;
    }
    try std.testing.expectEqualSlices(u32, &.{ 14, 15, 6 }, &input);
    try pairs.items[0][0].push_str(gpa, "!");
    try std.testing.expectEqualStrings("zip!", pairs.items[0][0].as_str());
    try std.testing.expectEqualStrings("zip", pairs.items[1][0].as_str());

    // The right side ends first: the left owner fetched for an unmatched
    // pair must not escape or leak, even when a later allocation fails.
    var short_input = [_]u32{8};
    var short = try translated.owner_zip_mut(gpa, &short_input, 4);
    defer r2z.alloc.dropTemporary(gpa, &short);
    try std.testing.expectEqual(@as(usize, 1), short.items.len);
    try std.testing.expectEqualStrings("zip", short.items[0][0].as_str());
    short.items[0][1].* += 10;
    try std.testing.expectEqualSlices(u32, &.{18}, &short_input);

    var empty_input = [_]u32{9};
    var empty = try translated.owner_zip_mut(gpa, &empty_input, 0);
    defer r2z.alloc.dropTemporary(gpa, &empty);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    try std.testing.expectEqualSlices(u32, &.{9}, &empty_input);
}

test "an owned zip retains strings and mutable references into the caller's right input" {
    try zipMutableOwnerWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        zipMutableOwnerWithAllocationFailures,
        .{},
    );
}

fn resultMapOwnerWithAllocationFailures(gpa: std.mem.Allocator) !void {
    const mapped = try translated.owner_result_map(gpa, true);
    try std.testing.expect(mapped == .Ok);
    try std.testing.expectEqual(@as(u32, 1), mapped.Ok);
    const refused = try translated.owner_result_map(gpa, false);
    try std.testing.expect(refused == .Err);
    try std.testing.expectEqual(@as(u8, 7), refused.Err);

    var mapped_owner = try translated.owner_result_map_passthrough(gpa, true);
    defer r2z.alloc.dropTemporary(gpa, &mapped_owner);
    try std.testing.expect(mapped_owner == .Ok);
    try std.testing.expectEqual(@as(u32, 1), mapped_owner.Ok);
    var kept = try translated.owner_result_map_passthrough(gpa, false);
    defer r2z.alloc.dropTemporary(gpa, &kept);
    try std.testing.expect(kept == .Err);
    try std.testing.expectEqualStrings("kept-error", kept.Err.as_str());
    try kept.Err.push_str(gpa, "!");
    try std.testing.expectEqualStrings("kept-error!", kept.Err.as_str());
}

test "Result map releases its consumed owner once and transfers the passthrough owner" {
    try resultMapOwnerWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        resultMapOwnerWithAllocationFailures,
        .{},
    );
}

fn resultMapErrOwnerWithAllocationFailures(gpa: std.mem.Allocator) !void {
    const accepted = try translated.owner_result_map_err(gpa, true);
    try std.testing.expect(accepted == .Ok);
    try std.testing.expectEqual(@as(u32, 9), accepted.Ok);
    const mapped = try translated.owner_result_map_err(gpa, false);
    try std.testing.expect(mapped == .Err);
    try std.testing.expectEqual(@as(u8, 3), mapped.Err);

    var kept = try translated.owner_result_map_err_passthrough(gpa, true);
    defer r2z.alloc.dropTemporary(gpa, &kept);
    try std.testing.expect(kept == .Ok);
    try std.testing.expectEqualStrings("kept-ok", kept.Ok.as_str());
    try kept.Ok.push_str(gpa, "!");
    try std.testing.expectEqualStrings("kept-ok!", kept.Ok.as_str());
    var mapped_owner = try translated.owner_result_map_err_passthrough(gpa, false);
    defer r2z.alloc.dropTemporary(gpa, &mapped_owner);
    try std.testing.expect(mapped_owner == .Err);
    try std.testing.expectEqual(@as(u8, 3), mapped_owner.Err);
}

test "Result map_err releases its consumed owner once and transfers the passthrough owner" {
    try resultMapErrOwnerWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        resultMapErrOwnerWithAllocationFailures,
        .{},
    );
}

test "source Copy bounds keep scalar callers and by-value locals allocator-free" {
    const direct_u32: *const fn (u32) u32 = &translated.copy_local_u32;
    const direct_u8: *const fn (u8) u8 = &translated.copy_local_u8;
    const transitive_u32: *const fn (u32) u32 = &translated.transitive_copy_local_u32;
    const transitive_u8: *const fn (u8) u8 = &translated.transitive_copy_local_u8;
    try std.testing.expectEqual(@as(u32, 42), direct_u32(42));
    try std.testing.expectEqual(@as(u8, 7), direct_u8(7));
    try std.testing.expectEqual(@as(u32, 43), transitive_u32(43));
    try std.testing.expectEqual(@as(u8, 8), transitive_u8(8));
    try std.testing.expectEqual(@as(u32, 44), translated.generic_copy_local(u32, 44));
    try std.testing.expectEqual(@as(u8, 9), translated.generic_copy_local(u8, 9));
    try std.testing.expectEqual(@as(u32, 45), translated.generic_transitive_copy_local(u32, 45));
    try std.testing.expectEqual(@as(u8, 10), translated.generic_transitive_copy_local(u8, 10));
}

fn resultMapParameterWithAllocationFailures(gpa: std.mem.Allocator) !void {
    const mapped = translated.owner_result_map_parameter(gpa, .{
        .Ok = try translated.owned(gpa, "mapped"),
    });
    try std.testing.expect(mapped == .Ok);
    try std.testing.expectEqual(@as(u32, 1), mapped.Ok);
    const refused = translated.owner_result_map_parameter(gpa, .{ .Err = 7 });
    try std.testing.expect(refused == .Err);
    try std.testing.expectEqual(@as(u8, 7), refused.Err);

    var mapped_owner = translated.owner_result_map_passthrough_parameter(gpa, .{
        .Ok = try translated.owned(gpa, "mapped"),
    });
    defer r2z.alloc.dropTemporary(gpa, &mapped_owner);
    try std.testing.expect(mapped_owner == .Ok);
    try std.testing.expectEqual(@as(u32, 1), mapped_owner.Ok);
    const payload = try translated.owned(gpa, "kept-error");
    const original_address = @intFromPtr(payload.as_bytes().ptr);
    var kept = translated.owner_result_map_passthrough_parameter(gpa, .{ .Err = payload });
    defer r2z.alloc.dropTemporary(gpa, &kept);
    try std.testing.expect(kept == .Err);
    try std.testing.expectEqualStrings("kept-error", kept.Err.as_str());
    try std.testing.expectEqual(original_address, @intFromPtr(kept.Err.as_bytes().ptr));
    try kept.Err.push_str(gpa, "!");
    try std.testing.expectEqualStrings("kept-error!", kept.Err.as_str());
}

test "a by-value Result parameter maps or transfers its original error allocation" {
    try resultMapParameterWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        resultMapParameterWithAllocationFailures,
        .{},
    );
}

fn resultMapErrParameterWithAllocationFailures(gpa: std.mem.Allocator) !void {
    const accepted = translated.owner_result_map_err_parameter(gpa, .{ .Ok = 9 });
    try std.testing.expect(accepted == .Ok);
    try std.testing.expectEqual(@as(u32, 9), accepted.Ok);
    const mapped = translated.owner_result_map_err_parameter(gpa, .{
        .Err = try translated.owned(gpa, "mapped-error"),
    });
    try std.testing.expect(mapped == .Err);
    try std.testing.expectEqual(@as(u8, 3), mapped.Err);

    const payload = try translated.owned(gpa, "kept-ok");
    const original_address = @intFromPtr(payload.as_bytes().ptr);
    var kept = translated.owner_result_map_err_passthrough_parameter(gpa, .{ .Ok = payload });
    defer r2z.alloc.dropTemporary(gpa, &kept);
    try std.testing.expect(kept == .Ok);
    try std.testing.expectEqualStrings("kept-ok", kept.Ok.as_str());
    try std.testing.expectEqual(original_address, @intFromPtr(kept.Ok.as_bytes().ptr));
    try kept.Ok.push_str(gpa, "!");
    try std.testing.expectEqualStrings("kept-ok!", kept.Ok.as_str());
    var mapped_owner = translated.owner_result_map_err_passthrough_parameter(gpa, .{
        .Err = try translated.owned(gpa, "mapped-error"),
    });
    defer r2z.alloc.dropTemporary(gpa, &mapped_owner);
    try std.testing.expect(mapped_owner == .Err);
    try std.testing.expectEqual(@as(u8, 3), mapped_owner.Err);
}

test "a by-value Result parameter maps errors or transfers its original success allocation" {
    try resultMapErrParameterWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        resultMapErrParameterWithAllocationFailures,
        .{},
    );
}

fn tupleTryWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var accepted = try translated.owner_tuple_try(gpa, true);
    defer r2z.alloc.dropTemporary(gpa, &accepted);
    try std.testing.expect(accepted == .Ok);
    try std.testing.expectEqualStrings("held", accepted.Ok[0].as_str());
    try std.testing.expectEqual(@as(u32, 7), accepted.Ok[1]);
    try accepted.Ok[0].push_str(gpa, "!");
    try std.testing.expectEqualStrings("held!", accepted.Ok[0].as_str());
    try std.testing.expectEqual(@as(u32, 7), accepted.Ok[1]);

    // The String exists before the scalar's source Result rejects. Only the
    // frame can release that partial tuple; the Err hands no owner back.
    var rejected = try translated.owner_tuple_try(gpa, false);
    defer r2z.alloc.dropTemporary(gpa, &rejected);
    try std.testing.expect(rejected == .Err);
    try std.testing.expectEqual(@as(u8, 2), rejected.Err);
}

test "a source Result early return releases an initialized tuple owner before its scalar rejects" {
    try tupleTryWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        tupleTryWithAllocationFailures,
        .{},
    );
}

test "signed primitive compound assignment truncates and evaluates the right side before its indexed place" {
    const result = translated.primitive_compound_order();
    try std.testing.expectEqual(@as(isize, -4), result[0]);
    try std.testing.expectEqual(@as(isize, -1), result[1]);
    // Digits 1 then 2, then 3 then 4 establish RHS-before-assignee order
    // and one evaluation of each side, independently of the scalar results.
    try std.testing.expectEqual(@as(u32, 1234), result[2]);
}

fn projectedPairWithAllocationFailures(gpa: std.mem.Allocator) !void {
    const empty_cases = [_]bool{ false, true };
    const expected = [_][]const u8{ "selected-solo", "selected-empty" };
    for (empty_cases, expected) |empty, bytes| {
        var selected = try translated.owner_projected_pair(gpa, empty);
        defer selected.deinit(gpa);
        try std.testing.expectEqualStrings(bytes, selected.as_str());
        // The enclosing carrier released its other field, not the String
        // reached through pair.1. This returned owner remains writable.
        try selected.push_str(gpa, "!");
        var buffer: [32]u8 = undefined;
        try std.testing.expectEqualStrings(
            try std.fmt.bufPrint(&buffer, "{s}!", .{bytes}),
            selected.as_str(),
        );
    }
}

test "a carrier tuple field projection transfers its string and releases its owning sibling" {
    try projectedPairWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        projectedPairWithAllocationFailures,
        .{},
    );
}

fn nestedIfletWithAllocationFailures(gpa: std.mem.Allocator) !void {
    const modes = [_]u8{ 0, 1, 2 };
    const expected = [_][]const u8{ "nested", "fallback", "absent" };
    for (modes, expected) |mode, bytes| {
        var selected = try translated.owner_nested_iflet(gpa, mode);
        defer selected.deinit(gpa);
        try std.testing.expectEqualStrings(bytes, selected.as_str());
        // Only the successful leaf transfer empties the original payload;
        // the unmatched and absent branches return independent allocations.
        try selected.push_str(gpa, "!");
        var buffer: [16]u8 = undefined;
        try std.testing.expectEqualStrings(
            try std.fmt.bufPrint(&buffer, "{s}!", .{bytes}),
            selected.as_str(),
        );
    }
}

test "a nested if-let moves only its matched leaf from the original carrier place" {
    try nestedIfletWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        nestedIfletWithAllocationFailures,
        .{},
    );
}

/// Like the array-owner consumer's ledger, this records addresses without
/// allocating bookkeeping storage. Each fresh carrier owns just two strings.
/// Overflow fails the assertions rather than hiding an unrecorded owner.
const ProjectedOptionLedger = struct {
    const capacity = 8;

    child: std.mem.Allocator,
    handed_out: [capacity]usize = undefined,
    released: [capacity]usize = undefined,
    handed_out_count: usize = 0,
    released_count: usize = 0,
    overflow: bool = false,

    fn allocator(self: *ProjectedOptionLedger) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn releasesOf(self: *const ProjectedOptionLedger, address: usize) usize {
        var releases: usize = 0;
        for (self.released[0..self.released_count]) |entry| {
            if (entry == address) releases += 1;
        }
        return releases;
    }

    fn recordHandedOut(self: *ProjectedOptionLedger, address: usize) void {
        if (self.handed_out_count == capacity) {
            self.overflow = true;
            return;
        }
        self.handed_out[self.handed_out_count] = address;
        self.handed_out_count += 1;
    }

    fn recordReleased(self: *ProjectedOptionLedger, address: usize) void {
        if (self.released_count == capacity) {
            self.overflow = true;
            return;
        }
        self.released[self.released_count] = address;
        self.released_count += 1;
    }

    fn expectBothReleasedOnce(self: *const ProjectedOptionLedger) !void {
        try std.testing.expect(!self.overflow);
        try std.testing.expectEqual(@as(usize, 2), self.handed_out_count);
        try std.testing.expectEqual(@as(usize, 2), self.released_count);
        try std.testing.expect(self.handed_out[0] != self.handed_out[1]);
        for (self.handed_out[0..self.handed_out_count]) |address| {
            try std.testing.expectEqual(@as(usize, 1), self.releasesOf(address));
        }
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    fn allocFn(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *ProjectedOptionLedger = @ptrCast(@alignCast(context));
        const memory = self.child.rawAlloc(len, alignment, return_address) orelse return null;
        self.recordHandedOut(@intFromPtr(memory));
        return memory;
    }

    fn resizeFn(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *ProjectedOptionLedger = @ptrCast(@alignCast(context));
        return self.child.rawResize(memory, alignment, new_len, return_address);
    }

    fn remapFn(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *ProjectedOptionLedger = @ptrCast(@alignCast(context));
        const old_address = @intFromPtr(memory.ptr);
        const moved = self.child.rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        ) orelse return null;
        if (@intFromPtr(moved) != old_address) {
            self.recordReleased(old_address);
            self.recordHandedOut(@intFromPtr(moved));
        }
        return moved;
    }

    fn freeFn(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *ProjectedOptionLedger = @ptrCast(@alignCast(context));
        if (memory.len != 0) self.recordReleased(@intFromPtr(memory.ptr));
        self.child.rawFree(memory, alignment, return_address);
    }
};

fn projectedOptionBorrowTwiceWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var ledger: ProjectedOptionLedger = .{ .child = gpa };
    try std.testing.expectEqual(
        @as(usize, 6),
        try translated.owner_projected_option_borrow_twice(ledger.allocator()),
    );
    try ledger.expectBothReleasedOnce();
}

test "two shared borrows of a projected Some leaf preserve it until its carrier releases it once" {
    try projectedOptionBorrowTwiceWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        projectedOptionBorrowTwiceWithAllocationFailures,
        .{},
    );
}

fn projectedOptionNoneInspectionWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var ledger: ProjectedOptionLedger = .{ .child = gpa };
    try std.testing.expectEqual(
        @as(usize, 3),
        try translated.owner_projected_option_none_inspection(ledger.allocator()),
    );
    try ledger.expectBothReleasedOnce();
}

test "a nonmatching projected None inspector does not consume the Some leaf borrowed next" {
    try projectedOptionNoneInspectionWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        projectedOptionNoneInspectionWithAllocationFailures,
        .{},
    );
}

fn projectedOptionMoveWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var ledger: ProjectedOptionLedger = .{ .child = gpa };
    const tracked_gpa = ledger.allocator();
    const input = try translated.owned(tracked_gpa, "abc");
    const original_address = @intFromPtr(input.as_bytes().ptr);
    var selected = try translated.owner_projected_option_move(tracked_gpa, input);

    // Inspect the release ledger before reading or freeing the returned bytes:
    // a premature release must fail this assertion, not a dangling-pointer read.
    try std.testing.expectEqual(@as(usize, 0), ledger.releasesOf(original_address));
    {
        defer selected.deinit(tracked_gpa);
        try std.testing.expect(!ledger.overflow);
        try std.testing.expectEqual(@as(usize, 2), ledger.handed_out_count);
        try std.testing.expectEqual(@as(usize, 1), ledger.released_count);
        try std.testing.expectEqual(original_address, ledger.handed_out[0]);
        try std.testing.expect(original_address != ledger.handed_out[1]);
        try std.testing.expectEqual(
            @as(usize, 1),
            ledger.releasesOf(ledger.handed_out[1]),
        );
        try std.testing.expectEqual(
            original_address,
            @intFromPtr(selected.as_bytes().ptr),
        );
        try std.testing.expectEqualStrings("abc", selected.as_str());
    }
    try ledger.expectBothReleasedOnce();
}

test "a projected Option move returns the original allocation and releases only its inner sibling" {
    try projectedOptionMoveWithAllocationFailures(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        projectedOptionMoveWithAllocationFailures,
        .{},
    );
}
