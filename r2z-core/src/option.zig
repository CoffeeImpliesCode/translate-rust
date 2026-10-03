//! Rust `Option` operations over Zig's own optional, for source whose `T` or
//! `F` is decided only at the call site.
//!
//! Every function here is a free function taking the optional by value or by
//! pointer, because a lowered `Option<T>` is `?T` and a method cannot be added
//! to it. Nothing here owns or releases anything: a payload the call drops is
//! dropped without a release, so a value holding runtime storage leaks on the
//! arms that drop one. A mapper runs on the calling thread, synchronously,
//! inside the call that reached it, and only for the arm that maps.

const std = @import("std");
const alloc = @import("alloc.zig");
const invokeMapper = @import("result.zig").invokeMapper;

/// Return the payload, or panic with the fixed message.
///
/// The payload is moved out whole and is the caller's to release. On the `null`
/// arm there is nothing to release, and the process panics.
pub fn unwrap(value: anytype) @typeInfo(@TypeOf(value)).optional.child {
    return value orelse @panic("Option.unwrap called on None");
}

/// Return the payload, or `fallback` when the value is `null`.
///
/// `fallback` is an ordinary argument and is always evaluated, whether or not
/// the value holds a payload. Neither value is released here.
pub fn unwrap_or(value: anytype, fallback: @typeInfo(@TypeOf(value)).optional.child) @typeInfo(@TypeOf(value)).optional.child {
    return value orelse fallback;
}

/// Borrow the payload instead of moving it out, or return `null` for a `null`
/// value.
///
/// `value` is a pointer to the optional, so the borrow names that optional's own
/// storage: a read through it is a read of the original, a write through the
/// caller's own optional is visible here, and the borrow is invalidated once
/// the optional is overwritten or released.
pub fn as_ref(value: anytype) ?*const @typeInfo(@typeInfo(@TypeOf(value)).pointer.child).optional.child {
    if (value.*) |*payload| return payload;
    return null;
}

/// Apply `mapper` to the payload, or return `null` for a `null` value.
///
/// The result's payload type is read from the mapper's own result, so the mapper
/// decides it. It runs once, on the calling thread, and only for the arm that
/// holds a payload.
pub fn map(value: anytype, mapper: anytype) ?@TypeOf(invokeMapper(
    @typeInfo(@TypeOf(value)).optional.child,
    mapper,
    @as(@typeInfo(@TypeOf(value)).optional.child, undefined),
)) {
    const Input = @typeInfo(@TypeOf(value)).optional.child;
    if (value) |payload| return invokeMapper(Input, mapper, payload);
    return null;
}

/// Apply `mapper`, which itself returns an optional, or return `null` for a
/// `null` value.
///
/// This is `map` for a mapper that can answer "absent": a `null` from `mapper`
/// is the caller's answer, not an error, and it is indistinguishable from the
/// `null` this returns for a `null` input. The mapper runs once, on the calling
/// thread, and only for the arm that holds a payload.
pub fn and_then(value: anytype, mapper: anytype) @TypeOf(invokeMapper(
    @typeInfo(@TypeOf(value)).optional.child,
    mapper,
    @as(@typeInfo(@TypeOf(value)).optional.child, undefined),
)) {
    const Input = @typeInfo(@TypeOf(value)).optional.child;
    const Output = @TypeOf(invokeMapper(Input, mapper, @as(Input, undefined)));
    if (@typeInfo(Output) != .optional) @compileError("Option.and_then requires an optional return value");
    if (value) |payload| return invokeMapper(Input, mapper, payload);
    return null;
}

test "optional combinators preserve callback effects and nested absence" {
    const Mapper = struct {
        calls: *u8,
        pub fn call(self: *@This(), value: u8) ?u16 {
            self.calls.* += 1;
            return if (value == 0) null else @as(u16, value) * 2;
        }
    };
    var calls: u8 = 0;
    const mapper: Mapper = .{ .calls = &calls };
    try std.testing.expectEqual(@as(?u16, null), and_then(@as(?u8, null), mapper));
    try std.testing.expectEqual(@as(u8, 0), calls);
    try std.testing.expectEqual(@as(?u16, 12), and_then(@as(?u8, 6), mapper));
    try std.testing.expectEqual(@as(u8, 1), calls);
    const nested = map(@as(?u8, 0), mapper);
    try std.testing.expect(nested != null);
    try std.testing.expectEqual(@as(?u16, null), nested.?);
    try std.testing.expectEqual(@as(u8, 2), calls);
    try std.testing.expectEqual(@as(?u16, null), and_then(@as(?u8, 0), mapper));
    try std.testing.expectEqual(@as(u8, 3), calls);
}

test "optional references borrow payload storage" {
    var value: ?u32 = 12;
    const borrowed = as_ref(&value).?;
    value.? = 31;
    try std.testing.expectEqual(@as(u32, 31), borrowed.*);
    value = null;
    try std.testing.expect(as_ref(&value) == null);
    try std.testing.expectEqual(@as(u32, 7), unwrap_or(value, 7));
    try std.testing.expectEqual(@as(u32, 9), unwrap(@as(?u32, 9)));
}

// ── the emitted surface ────────────────────────────────────────────────

// Every free function the backend emits as `r2z.option.<name>`.
//
// A lowered `Option<T>` is Zig's `?T` and a method cannot be added to it, so
// each of these is a free function the call site names by the source's own
// method spelling.
//
// `is_some`, `is_none` and `take` are deliberately absent. The backend
// emits those inline — a `null` comparison, and a block that copies the
// optional out of its place and empties the place — so they reach no
// runtime counterpart at all.
test "the option module publishes every free function the backend emits" {
    // The pin is on the SHAPE the backend emits, not just the names: `as_ref`
    // is the one the backend hands a pointer to (`r2z.option.as_ref(&opt)`),
    // the other four take the optional by value, and each takes exactly the
    // argument count the call carries. A counterpart that went missing,
    // changed arity, or stopped taking the receiver the backend passes is a
    // generated crate that fails to compile with `no function named` — and it
    // fails here first, in the file that owns the surface.
    const Shape = struct { name: []const u8, args: usize };
    const surface = comptime [_]Shape{
        .{ .name = "unwrap", .args = 1 },
        .{ .name = "unwrap_or", .args = 2 },
        .{ .name = "as_ref", .args = 1 },
        .{ .name = "map", .args = 2 },
        .{ .name = "and_then", .args = 2 },
    };
    comptime {
        for (surface) |entry| {
            const info = @typeInfo(@TypeOf(@field(@This(), entry.name)));
            if (info != .@"fn") {
                @compileError("r2z.option." ++ entry.name ++ " is no longer a free function the backend can call");
            }
            if (info.@"fn".params.len != entry.args) {
                @compileError("r2z.option." ++ entry.name ++ " no longer takes the argument count the backend emits");
            }
        }
    }

    // The emitted calls instantiate in exactly that shape over a payload and
    // over the empty slot, and the borrow comes back as a pointer into the
    // caller's own slot rather than a copy of the payload: a value where the
    // caller expected a borrow would satisfy the shape above while no borrow
    // reached anyone.
    const slot: ?u32 = 6;
    try std.testing.expectEqual(@as(u32, 6), unwrap(slot));
    try std.testing.expectEqual(@as(u32, 6), unwrap_or(slot, 0));
    try std.testing.expect(as_ref(&slot) != null);
    comptime {
        if (@TypeOf(as_ref(@as(*?u32, undefined))) != ?*const u32) {
            @compileError("r2z.option.as_ref no longer hands back a borrow of the caller's slot");
        }
    }
    const absent: ?u32 = null;
    try std.testing.expect(as_ref(&absent) == null);
    try std.testing.expectEqual(@as(u32, 7), unwrap_or(absent, 7));
}

// ── owned payloads: exactly one owner on every arm ─────────────────────

/// What `map` and `and_then` hand an owned payload to.
///
/// Rust passes the closure its value BY VALUE, so from the moment the
/// combinator calls this the payload has exactly one owner: the closure.
/// It releases the allocation once and reports what it read. A combinator
/// that also released the payload on the way in would free those bytes twice
/// the moment a real allocation was behind them.
const OwnedSink = struct {
    gpa: std.mem.Allocator,
    seen: *u8,

    pub fn call(self: *@This(), owned: alloc.String) usize {
        self.seen.* += 1;
        var held = owned;
        defer held.deinit(self.gpa);
        return held.len();
    }
};

/// What `and_then` hands an owned payload to: a mapper whose own answer may
/// be absent, which is the whole difference from `map`.
const OwnedOptionalSink = struct {
    gpa: std.mem.Allocator,
    seen: *u8,
    answer: ?usize,

    pub fn call(self: *@This(), owned: alloc.String) ?usize {
        self.seen.* += 1;
        var held = owned;
        defer held.deinit(self.gpa);
        return self.answer;
    }
};

test "unwrap hands an owned payload to the caller without releasing it" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    // The move the backend emits for an owned payload read out of a slot:
    // `takeOwned` empties the place, and `unwrap` hands the transferred
    // descriptor over whole. The emptied place keeps a release armed over it,
    // so it must find nothing to free; the caller's own release is the only
    // one, which the deallocation count below counts exactly.
    var held: ?alloc.String = try alloc.String.from_str(gpa, "owned");
    const address = @intFromPtr(held.?.as_bytes().ptr);
    var taken = unwrap(alloc.takeOwned(?alloc.String, &held));

    const before_source_release = tracking.deallocations;
    alloc.dropTemporary(gpa, &held);
    try std.testing.expectEqual(before_source_release, tracking.deallocations);
    try std.testing.expect(held == null or held.?.is_empty());

    try std.testing.expectEqualStrings("owned", taken.as_str());
    try std.testing.expectEqual(address, @intFromPtr(taken.as_bytes().ptr));
    const before_owner_release = tracking.deallocations;
    taken.deinit(gpa);
    try std.testing.expectEqual(before_owner_release + 1, tracking.deallocations);
}

test "unwrap_or hands the payload out on one arm and releases nothing on the other" {
    const gpa = std.testing.allocator;
    const held: ?alloc.String = try alloc.String.from_str(gpa, "held");
    var taken = unwrap_or(held, alloc.String.empty);
    try std.testing.expectEqualStrings("held", taken.as_str());
    taken.deinit(gpa);

    // A `null` optional owns nothing, so the fallback that comes back owns
    // nothing either and there is no release to observe here.
    const absent: ?alloc.String = null;
    try std.testing.expect(unwrap_or(absent, alloc.String.empty).is_empty());
}

test "map hands an owned payload to the mapper and runs it only for the arm that has one" {
    const gpa = std.testing.allocator;
    var seen: u8 = 0;
    const mapper: OwnedSink = .{ .gpa = gpa, .seen = &seen };

    const held: ?alloc.String = try alloc.String.from_str(gpa, "owned");
    try std.testing.expectEqual(@as(?usize, "owned".len), map(held, mapper));
    try std.testing.expectEqual(@as(u8, 1), seen);

    // A `null` input runs no mapper, so nothing is handed out and nothing is
    // released on that arm either.
    const absent: ?alloc.String = null;
    try std.testing.expect(map(absent, mapper) == null);
    try std.testing.expectEqual(@as(u8, 1), seen);
}

test "and_then releases an owned payload once on every arm" {
    const gpa = std.testing.allocator;
    var seen: u8 = 0;
    var refused_seen: u8 = 0;

    const present_mapper: OwnedOptionalSink = .{
        .gpa = gpa,
        .seen = &seen,
        .answer = @as(?usize, 5),
    };
    const held: ?alloc.String = try alloc.String.from_str(gpa, "owned");
    try std.testing.expectEqual(@as(?usize, 5), and_then(held, present_mapper));
    try std.testing.expectEqual(@as(u8, 1), seen);

    // The mapper's OWN absent answer is the caller's answer, not an error,
    // and the payload it was handed is still released exactly once on the way
    // there — the same count the present arm produced.
    const absent_mapper: OwnedOptionalSink = .{
        .gpa = gpa,
        .seen = &refused_seen,
        .answer = null,
    };
    const rejected: ?alloc.String = try alloc.String.from_str(gpa, "rejected");
    try std.testing.expect(and_then(rejected, absent_mapper) == null);
    try std.testing.expectEqual(@as(u8, 1), refused_seen);

    const empty: ?alloc.String = null;
    try std.testing.expect(and_then(empty, absent_mapper) == null);
    try std.testing.expectEqual(@as(u8, 1), refused_seen);
}

test "as_ref borrows the payload out of the caller's own optional" {
    const gpa = std.testing.allocator;
    var held: ?alloc.String = try alloc.String.from_str(gpa, "borrowed");
    const borrowed = as_ref(&held) orelse return error.ExpectedPayload;
    try std.testing.expectEqualStrings("borrowed", borrowed.as_str());
    // The borrow names the optional's OWN storage rather than a copy of it:
    // both views are one allocation, so the single release below frees it.
    try std.testing.expectEqual(
        @intFromPtr(held.?.as_bytes().ptr),
        @intFromPtr(borrowed.as_bytes().ptr),
    );
    held.?.deinit(gpa);
    held = null;
    try std.testing.expect(as_ref(&held) == null);
}

// ── the emitted shapes ─────────────────────────────────────────────────

test "the emitted Option<u32> match reads its payload back through the runtime" {
    // `match value { Some(v) => .., None => 0 }` lowers to an
    // `if (subject != null)` whose payload arm is `r2z.option.unwrap`. Zig
    // cannot switch an optional, so this two-arm spelling is the whole shape.
    const held: ?u32 = 26;
    try std.testing.expectEqual(@as(u32, 26), switch (held != null) {
        true => unwrap(held),
        false => 0,
    });

    const absent: ?u32 = null;
    try std.testing.expectEqual(@as(u32, 0), switch (absent != null) {
        true => unwrap(absent),
        false => 0,
    });
}

/// The storage a projected payload is taken out of. `self.value` is the place
/// the emitted `take` block reads and empties, so the field is the whole of
/// what the projection adds.
const Projected = struct {
    value: ?alloc.String,
};

/// `self.value.take()` in the shape the backend emits it.
///
/// Rust's `take` MOVES the payload out and leaves the place empty, so the
/// copy and the emptying are two halves of one move: a shape that emptied the
/// place afterwards would leave two owners of one allocation, and a shape
/// that copied without emptying would leave the caller with nothing.
fn takeProjected(holder: *Projected) ?alloc.String {
    const taken: ?alloc.String = holder.value;
    holder.value = null;
    return taken;
}

test "take of a projected payload hands the owned payload over exactly once" {
    const gpa = std.testing.allocator;
    var holder: Projected = .{ .value = try alloc.String.from_str(gpa, "projected") };
    var taken = takeProjected(&holder) orelse return error.ExpectedPayload;
    try std.testing.expectEqualStrings("projected", taken.as_str());
    // The projected place is empty afterwards, so nothing else can release
    // the bytes the caller now holds.
    try std.testing.expect(holder.value == null);
    taken.deinit(gpa);

    // An empty place takes nothing, owns nothing, and answers absent.
    try std.testing.expect(takeProjected(&holder) == null);
}

/// One slot of caller-owned storage, as `Slot` lowers: a tagged union whose
/// payload arm carries the value and whose empty arm carries nothing.
const Slot = union(enum) {
    Filled: u32,
    Empty,
};

/// The counter the emitted index expression runs, so a dispatch that
/// evaluated it more than once is visible from outside.
fn countedIndex(cursor: *u32, index: usize) usize {
    cursor.* += 1;
    return index;
}

/// `optional_slot_write`: the subject is a plain variant field, so the arm's
/// `ref mut` needs no binding of the subject and reaches the caller's own
/// element straight away.
fn optionalSlotWrite(slots: []Slot, index: usize, value: u32, cursor: *u32) u32 {
    const at = countedIndex(cursor, index);
    return switch (slots[at]) {
        .Filled => |*slot| blk: {
            slot.* = value;
            break :blk slot.*;
        },
        .Empty => 0,
    };
}

/// `optional_entry_write`: the subject is a real `Option`, so the dispatch
/// binds the subject's PLACE and the arm's `ref mut` reaches through that
/// binding into the caller's own element rather than into a copy.
fn optionalEntryWrite(entries: []?u32, index: usize, value: u32, cursor: *u32) u32 {
    const subject = &entries[countedIndex(cursor, index)];
    return switch (subject.* != null) {
        true => blk: {
            const payload = if (subject.*) |*entry| entry else unreachable;
            payload.* = value;
            break :blk payload.*;
        },
        false => 0,
    };
}

test "the emitted indexed-storage shapes write through to the caller's own element" {
    var cursor: u32 = 0;
    var filled = [_]Slot{ .{ .Filled = 1 }, .{ .Filled = 2 } };
    try std.testing.expectEqual(@as(u32, 42), optionalSlotWrite(&filled, 0, 42, &cursor));
    // The index expression ran once, whatever the dispatch read.
    try std.testing.expectEqual(@as(u32, 1), cursor);
    // The write landed in the element the index named ...
    try std.testing.expectEqual(@as(u32, 42), filled[0].Filled);
    // ... and the element it did not reach still holds what the caller built.
    try std.testing.expectEqual(@as(u32, 2), filled[1].Filled);

    // An empty slot has no payload to write, answers zero, and leaves the
    // element it did not reach alone.
    var mixed = [_]Slot{ .{ .Filled = 1 }, .Empty };
    try std.testing.expectEqual(@as(u32, 0), optionalSlotWrite(&mixed, 1, 7, &cursor));
    try std.testing.expectEqual(@as(u32, 1), mixed[0].Filled);

    cursor = 0;
    var entries = [_]?u32{ 1, 42 };
    try std.testing.expectEqual(@as(u32, 7), optionalEntryWrite(&entries, 1, 7, &cursor));
    try std.testing.expectEqual(@as(u32, 1), cursor);
    try std.testing.expectEqual(@as(?u32, 1), entries[0]);
    try std.testing.expectEqual(@as(?u32, 7), entries[1]);

    // An element with no payload answers zero and keeps the state it had.
    var option_mixed = [_]?u32{ 1, null };
    try std.testing.expectEqual(@as(u32, 0), optionalEntryWrite(&option_mixed, 1, 7, &cursor));
    try std.testing.expectEqual(@as(?u32, 1), option_mixed[0]);
    try std.testing.expectEqual(@as(?u32, null), option_mixed[1]);
}

test "a borrowed payload binding reaches the element the index named" {
    // `Some(ref mut entry)` in a match over `entries[index]`: the binding is
    // a borrow, so a write through it is a write to the caller's storage. The
    // payload has to carry heap storage for that claim to be checkable at
    // all — `as_ref` over a scalar optional hands the value back by value, so
    // a scalar could not distinguish a borrow from a copy. The identity check
    // is therefore on the SLICE the borrowed payload points at, against the
    // slice the caller's own element holds.
    const gpa = std.testing.allocator;
    var entries = [_]?alloc.String{
        try alloc.String.from_str(gpa, "first"),
        try alloc.String.from_str(gpa, "second"),
    };
    defer {
        for (&entries) |*entry| entry.*.?.deinit(gpa);
    }
    const borrowed = as_ref(&entries[1]) orelse return error.ExpectedPayload;
    try std.testing.expectEqualStrings("second", borrowed.as_str());
    // The borrow names the element's OWN allocation rather than a copy of
    // it: the addresses are the same, which is exactly what makes a write
    // through one view visible through the other.
    try std.testing.expectEqual(
        @intFromPtr(entries[1].?.as_bytes().ptr),
        @intFromPtr(borrowed.as_bytes().ptr),
    );
    try std.testing.expectEqualStrings("first", entries[0].?.as_str());
    try std.testing.expectEqualStrings("second", entries[1].?.as_str());
}

test "a comparison names the option the None slot stands for" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    // The shapes the backend emits for `is_some` and `is_none` are comparisons
    // against `null`, so both arms answer from the caller's own slot: filling
    // the slot changes the answer, and neither comparison moves or releases
    // the payload it looked at.
    var slot: ?alloc.String = try alloc.String.from_str(gpa, "present");
    const address = @intFromPtr(slot.?.as_bytes().ptr);

    const before_present_reads = tracking.deallocations;
    try std.testing.expect(slot != null);
    try std.testing.expect(!(slot == null));
    try std.testing.expectEqual(before_present_reads, tracking.deallocations);
    try std.testing.expectEqual(address, @intFromPtr(slot.?.as_bytes().ptr));

    slot.?.deinit(gpa);
    slot = null;

    // The same slot now stands for None, and the comparison says so without
    // reading or releasing anything at all.
    const before_absent_reads = tracking.deallocations;
    try std.testing.expect(slot == null);
    try std.testing.expect(!(slot != null));
    try std.testing.expectEqual(before_absent_reads, tracking.deallocations);
}

test "a transferred slot stands for the state the borrow and the release see" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    // The move the backend emits for an owned payload read out of a slot:
    // `takeOwned` hands the descriptor over and empties the place in the same
    // step. From then on the slot carries the emptied state — a borrow sees
    // the empty payload rather than the moved one, and the release the frame
    // still carries over the place frees nothing.
    var slot: ?alloc.String = try alloc.String.from_str(gpa, "moved");
    const address = @intFromPtr(slot.?.as_bytes().ptr);
    const moved = alloc.takeOwned(?alloc.String, &slot);

    const emptied = as_ref(&slot) orelse return error.ExpectedPayload;
    try std.testing.expect(emptied.is_empty());

    const before_source_release = tracking.deallocations;
    alloc.dropTemporary(gpa, &slot);
    try std.testing.expectEqual(before_source_release, tracking.deallocations);

    // The descriptor is the payload's only owner, so `unwrap` hands the
    // caller the same allocation and the caller's own release is the single
    // one that frees it.
    var taken = unwrap(moved);
    try std.testing.expectEqualStrings("moved", taken.as_str());
    try std.testing.expectEqual(address, @intFromPtr(taken.as_bytes().ptr));
    const before_owner_release = tracking.deallocations;
    taken.deinit(gpa);
    try std.testing.expectEqual(before_owner_release + 1, tracking.deallocations);
}

test "the emitted as_ref read-back hands back the payload the borrow names" {
    // `opt.as_ref().unwrap()` is `r2z.option.unwrap(r2z.option.as_ref(&opt))`:
    // the same read-back a payload arm performs, over the borrow rather than
    // over the option, and the value it hands back aliases the caller's bytes
    // instead of copying them.
    const gpa = std.testing.allocator;
    var held: ?alloc.String = try alloc.String.from_str(gpa, "shared");
    defer held.?.deinit(gpa);

    const read_back = unwrap(as_ref(&held));
    try std.testing.expectEqualStrings("shared", read_back.as_str());
    try std.testing.expectEqual(
        @intFromPtr(held.?.as_bytes().ptr),
        @intFromPtr(read_back.as_bytes().ptr),
    );

    // The same borrow through a shared pointer: a place the source reaches
    // only for reading still hands back the caller's own storage.
    const const_view: *const ?alloc.String = &held;
    const const_borrowed = as_ref(const_view) orelse return error.ExpectedPayload;
    try std.testing.expectEqualStrings("shared", const_borrowed.as_str());
    try std.testing.expectEqual(
        @intFromPtr(held.?.as_bytes().ptr),
        @intFromPtr(const_borrowed.as_bytes().ptr),
    );
}
