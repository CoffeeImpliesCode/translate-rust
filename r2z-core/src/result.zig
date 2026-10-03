//! Rust `Result` in both shapes a lowered crate reaches for: the tagged
//! `Result(T, E)` union, and the free functions that serve a fieldless error
//! enum which became a Zig error union.
//!
//! A source `Result<T, E>` reaches here in one of two shapes. A fieldless error
//! enum lowers to a Zig error union, and the free functions below serve it: the
//! union has no runtime value to call a method on, so `expect_error_union`
//! reads the `Ok` payload out and `expect_error_union_err` maps a native error
//! back to the source enum's own variant. An error type whose variants carry
//! payloads lowers to the `Result(T, E)` union declared here, which has real
//! methods.
//!
//! Neither shape owns anything on the caller's behalf except through the
//! allocator the abandoning paths are given. Every function here runs on the
//! calling thread, synchronously, and a mapper runs inside the call that
//! reached it and may reenter the value it was handed.

const std = @import("std");
const alloc = @import("alloc.zig");
const panic_probe = @import("panic_probe.zig");

/// Apply a Rust closure or `Fn`-shaped callable to one payload of type
/// `Input`, at compile time.
///
/// `mapper` is a function or a struct with `call`. It runs exactly once on the
/// calling thread and receives `value` by value. Ownership follows the mapper's
/// contract. This helper does not release it. The mapper may reenter its input.
pub fn invokeMapper(
    comptime Input: type,
    mapper: anytype,
    value: Input,
) @TypeOf(switch (@typeInfo(@TypeOf(mapper))) {
    .@"fn" => mapper(value),
    .@"struct" => (@as(*@TypeOf(mapper), undefined)).call(value),
    else => @compileError("Result mapper must be a function or callable struct"),
}) {
    const Mapper = @TypeOf(mapper);
    return switch (@typeInfo(Mapper)) {
        .@"fn" => mapper(value),
        .@"struct" => blk: {
            if (!@hasDecl(Mapper, "call")) {
                @compileError("Result mapper must be a function or expose call");
            }
            var callback = mapper;
            break :blk callback.call(value);
        },
        else => @compileError("Result mapper must be a function or callable struct"),
    };
}

/// Release a payload that is about to be abandoned, the way Rust runs a
/// dropped value's destructor on its way into a panic.
///
/// Zig has no destructor, so a payload holding runtime storage would be
/// abandoned by a bare `@panic`. `alloc.dropTemporary` is the runtime's own
/// bounded release and is what decides here: it frees only the containers the
/// runtime itself owns — `String`, `FromUtf8Error`, `Vec(T)`, and the active
/// payload of a tagged union, an `Option`, or an error union — and never calls
/// a method on a type the runtime does not own.
///
/// It deliberately does NOT duck-type for a release hook. A user's own
/// `deinit(self)` is an ordinary method that Rust never calls on a drop, and
/// invoking one here would invent a destructor the source does not have. A
/// payload the runtime does not own is somebody else's value and is left
/// exactly as it was found.
fn releaseAbandonedPayload(gpa: std.mem.Allocator, value: anytype) void {
    var abandoned = value;
    alloc.dropTemporary(gpa, &abandoned);
}

/// `Result::expect` for a receiver that lowered to a Zig error union.
///
/// A fieldless error enum becomes an error set, and an error union carries no
/// runtime `Result` for a method to be called on, so the `Ok` payload is read
/// out here and the failure reports the caller's own message. `msg` is an
/// ordinary parameter, so a call site that builds one has already run by the
/// time the union is inspected — the eagerness Rust gives the `expect`
/// argument, and the reason the message is not a second, deferred step.
pub fn expect_error_union(
    value: anytype,
    msg: []const u8,
) @typeInfo(@TypeOf(value)).error_union.payload {
    return value catch @panic(msg);
}

/// `Result::expect_err` for a receiver that lowered to a Zig error union.
///
/// A fieldless error enum kept its variants as tags when it became an error
/// set, so the failure an error union carries IS that tag: this hands the
/// source's own error value back rather than the tag the union happened to
/// spell it with. `E` is the type the Rust `Result` named, and it is named
/// here because the emitted call site is what still knows it.
///
/// The `Ok` payload is the value the caller does not get back, so it is
/// released on the way into the panic exactly as `Result.expect_err` releases
/// it — through `alloc.dropTemporary`, which frees only storage the runtime
/// itself owns and never calls a method on a value it does not. That release
/// needs an allocator, so `gpa` leads the runtime arguments after the source
/// error type. The emitted call site owns one. `msg` is an ordinary parameter, so a call
/// site that builds one has already run by the time the union is inspected.
pub fn expect_error_union_err(
    comptime E: type,
    gpa: std.mem.Allocator,
    value: anytype,
    msg: []const u8,
) E {
    if (value) |payload| {
        releaseAbandonedPayload(gpa, payload);
        @panic(msg);
    } else |err| return errorTagValue(E, err);
}

/// The value of the source's `E` that one native error stands for.
///
/// A `Result<T, E>` lowers to an error union whose error set is the source
/// enum's OWN members, so each member is simultaneously (1) a member of
/// `anyerror`, reachable as the static `@field(anyerror, name)`, and (2) a
/// declaration of `E` under that same name. The correspondence is therefore
/// walked from `E`: the loop below is an inline `for` over the source enum's
/// own fields, so every name is known while the program is compiled, and each
/// arm compares the error the union actually carried against that field's
/// static error value. Nothing is allocated and no name is looked up while the
/// program runs.
///
/// The error set is `anyerror`, which no program can enumerate, so the loop
/// deliberately runs over the CLOSED source enum rather than over the members
/// the error set can carry: a tag that is not one of the enum's own variants
/// has no value in `E`, and reporting an invented one would hand the caller a
/// failure the source never produced. That case panics instead.
pub fn errorTagValue(comptime E: type, tag: anyerror) E {
    // The value a tag stands for is a declaration of `E`, so `E` has to be an
    // ordinary enum with something to declare. A `Result` is lowered to an
    // error union only when that fieldless enum is what the error type
    // actually is, so an error set or `void` here means the backend chose the
    // wrong representation and this must not paper over it.
    const enumeration = switch (@typeInfo(E)) {
        .@"enum" => |declared| declared,
        else => @compileError("r2z: expect_error_union_err needs the source fieldless error enum"),
    };
    if (enumeration.fields.len == 0) {
        @compileError("r2z: expect_error_union_err needs a nonempty source error enum");
    }
    inline for (enumeration.fields) |field| {
        // The field's name is the variant's, and `@field` reads it twice: once
        // out of the error set, where it is the static value a union carrying
        // this member holds, and once out of `E`, where it is the value the
        // caller gets. Both reads happen while the program is compiled.
        if (tag == @field(anyerror, field.name)) return @field(E, field.name);
    }
    std.debug.panic(
        "r2z: native error {s} has no value in the source error enum {s}",
        .{ @errorName(tag), @typeName(E) },
    );
}

/// Rust `Result<T, E>` for an error type that cannot become a Zig error set,
/// which is exactly an error type whose variants carry payloads.
///
/// The union owns whichever arm is active, and the caller owns that storage:
/// this type has no `deinit`, so a `T` or `E` that owns memory is released by
/// the caller, exactly once, after the payload has been taken out. `unwrap`,
/// `expect`, `unwrap_err` and `expect_err` move the active payload out whole,
/// so the storage that comes back is the storage the union was holding.
///
/// Assignment copies the handle, not its allocation. Release an owned payload
/// once. Consuming extraction moves the selected payload and releases the
/// discarded payload through `gpa`. Use the allocator that created its storage.
/// The runtime never calls an arbitrary user method named `deinit`.
///
/// A mapper runs on the calling thread, synchronously, inside the call that
/// reached it, and only for the arm it maps.
///
pub fn Result(comptime T: type, comptime E: type) type {
    return union(enum) {
        /// The success arm, holding the source's `T`.
        Ok: T,
        /// The failure arm, holding the source's `E`.
        Err: E,

        const Self = @This();

        /// Return the `Ok` payload, or panic with the fixed message.
        ///
        /// The payload is moved out whole and is the caller's to release; a
        /// release on this path would free bytes that are still live. On the
        /// `Err` arm the error is released through `gpa` first, so a runtime
        /// container the union owned is freed exactly once, and then the
        /// process panics. `gpa` is borrowed for the call and never retained.
        ///
        pub fn unwrap(self: Self, gpa: std.mem.Allocator) T {
            return switch (self) {
                .Ok => |value| value,
                .Err => |error_value| {
                    releaseAbandonedPayload(gpa, error_value);
                    @panic("Result.unwrap called on Err");
                },
            };
        }

        /// Move the `Err` payload to the caller, or release `Ok` and panic.
        /// `gpa` must be compatible with the discarded runtime storage.
        pub fn unwrap_err(self: Self, gpa: std.mem.Allocator) E {
            return switch (self) {
                .Ok => |value| {
                    releaseAbandonedPayload(gpa, value);
                    @panic("Result.unwrap_err called on Ok");
                },
                .Err => |error_value| error_value,
            };
        }

        /// `unwrap` with a message the caller chose, reported in place of the
        /// fixed one. The `Err` is consumed on the way into the panic, so an
        /// `Err` that owns storage is released first, exactly as `unwrap`
        /// does.
        ///
        /// `msg` is evaluated before the union is inspected, so a caller that
        /// builds one has already paid for it when the panic fires.
        pub fn expect(self: Self, gpa: std.mem.Allocator, msg: []const u8) T {
            return switch (self) {
                .Ok => |value| value,
                .Err => |error_value| {
                    releaseAbandonedPayload(gpa, error_value);
                    @panic(msg);
                },
            };
        }

        /// `unwrap_err` with a message the caller chose. The `Ok` payload is
        /// the one abandoned on the panicking arm here, so it is released
        /// first — the mirror of what `expect` does to an `Err`.
        ///
        /// `msg` is evaluated before the union is inspected, so a caller that
        /// builds one has already paid for it when the panic fires.
        pub fn expect_err(self: Self, gpa: std.mem.Allocator, msg: []const u8) E {
            return switch (self) {
                .Ok => |value| {
                    releaseAbandonedPayload(gpa, value);
                    @panic(msg);
                },
                .Err => |error_value| error_value,
            };
        }

        /// Whether the active arm is `Ok`. Changes nothing.
        pub fn is_ok(self: Self) bool {
            return switch (self) {
                .Ok => true,
                .Err => false,
            };
        }

        /// Whether the active arm is `Err`. Changes nothing.
        pub fn is_err(self: Self) bool {
            return switch (self) {
                .Ok => false,
                .Err => true,
            };
        }

        /// Move the `Ok` payload to the caller, or release `Err` and return null.
        /// This consumes the union. Release returned runtime storage once.
        pub fn ok(self: Self, gpa: std.mem.Allocator) ?T {
            return switch (self) {
                .Ok => |value| value,
                .Err => |error_value| {
                    releaseAbandonedPayload(gpa, error_value);
                    return null;
                },
            };
        }

        /// Move the `Err` payload to the caller, or release `Ok` and return null.
        /// This consumes the union. Release returned runtime storage once.
        pub fn err(self: Self, gpa: std.mem.Allocator) ?E {
            return switch (self) {
                .Ok => |value| {
                    releaseAbandonedPayload(gpa, value);
                    return null;
                },
                .Err => |error_value| error_value,
            };
        }

        /// Borrow the active payload instead of moving it out.
        ///
        /// The returned union names this value's own storage, so a read through
        /// it is a read of the original and the borrow is invalidated once the
        /// original is released or overwritten.
        pub fn as_ref(self: *const Self) Result(*const T, *const E) {
            return switch (self.*) {
                .Ok => |*value| .{ .Ok = value },
                .Err => |*error_value| .{ .Err = error_value },
            };
        }

        /// Borrow the active payload mutably instead of moving it out.
        ///
        /// The returned union names this value's own storage, so a write
        /// through it changes the original and the borrow is invalidated once
        /// the original is released or overwritten.
        pub fn as_mut(self: *Self) Result(*T, *E) {
            return switch (self.*) {
                .Ok => |*value| .{ .Ok = value },
                .Err => |*error_value| .{ .Err = error_value },
            };
        }

        /// Apply `mapper` to the `Ok` payload, leaving an `Err` untouched.
        ///
        /// The result's payload type is read from the mapper's own result, so
        /// the mapper decides `T`. It runs once, on the calling thread, and
        /// only on the `Ok` arm; the `Err` arm is moved through without it.
        pub fn map(self: Self, mapper: anytype) Result(
            @TypeOf(invokeMapper(T, mapper, @as(T, undefined))),
            E,
        ) {
            return switch (self) {
                .Ok => |value| .{
                    .Ok = invokeMapper(T, mapper, value),
                },
                .Err => |error_value| .{ .Err = error_value },
            };
        }

        /// Apply `mapper` to the `Err` payload, leaving an `Ok` untouched.
        ///
        /// The result's error type is read from the mapper's own result, so the
        /// mapper decides `E`. It runs once, on the calling thread, and only on
        /// the `Err` arm; the `Ok` arm is moved through without it.
        pub fn map_err(self: Self, mapper: anytype) Result(
            T,
            @TypeOf(invokeMapper(E, mapper, @as(E, undefined))),
        ) {
            return switch (self) {
                .Ok => |value| .{ .Ok = value },
                .Err => |error_value| .{
                    .Err = invokeMapper(E, mapper, error_value),
                },
            };
        }
    };
}

const DecodeError = union(enum) {
    odd_length,
    invalid_character: struct {
        value: u8,
        index: usize,
    },
};

/// Test-only fieldless error enum: the Rust `E` behind a `Result` that
/// lowered to a Zig error union. Its variants are the error set's members, and
/// the value `expect_err` owes the caller is one of them rather than the tag.
const Fault = enum {
    Bad,
    Overflow,
};

/// Test-only message built at runtime rather than spelled as a literal, so a
/// panic guard can tell the caller's own message apart from a constant the
/// runtime could have substituted for it.
fn runtimeMessage(comptime template: []const u8, detail: usize) []const u8 {
    return std.fmt.allocPrint(std.heap.page_allocator, template, .{detail}) catch unreachable;
}

fn unitToByte(_: void) u8 {
    return 7;
}

fn genericIdentity(value: anytype) @TypeOf(value) {
    return value;
}

fn increment(value: *u16) u16 {
    value.* += 1;
    return value.*;
}

const AddCaptured = struct {
    delta: u16,
    calls: *u8,

    pub fn call(self: *@This(), value: u8) u16 {
        self.calls.* += 1;
        return @as(u16, value) + self.delta;
    }
};

const ErrorIndex = struct {
    calls: *u8,

    pub fn call(self: *@This(), decode_error: DecodeError) usize {
        self.calls.* += 1;
        return switch (decode_error) {
            .odd_length => 0,
            .invalid_character => |detail| detail.index,
        };
    }
};

const PanicValueMapper = struct {
    pub fn call(_: *@This(), _: u8) u16 {
        @panic("map called for Err");
    }
};

const PanicErrorMapper = struct {
    pub fn call(_: *@This(), _: DecodeError) usize {
        @panic("map_err called for Ok");
    }
};

/// The `free` a release-observing allocator runs: it reports the release on
/// stderr, then frees for real.
///
/// An abandoning arm panics, so the only evidence it leaves behind is what it
/// wrote on the way out. Each body below runs in a child process whose stderr
/// the parent matches against `required`, so an arm that released its payload
/// before dying prints exactly this line and an arm that did not stays silent.
fn announceReleaseFree(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
    std.heap.page_allocator.rawFree(memory, alignment, return_address);
    std.debug.print("released the abandoned payload before the panic\n", .{});
}

/// A page-backed allocator whose every release announces itself on stderr.
///
/// `table` holds the spliced vtable, so it must outlive the allocator the
/// call site keeps: a local the test body owns, never a temporary.
fn announcingAllocator(table: *std.mem.Allocator.VTable) std.mem.Allocator {
    table.* = std.heap.page_allocator.vtable.*;
    table.free = announceReleaseFree;
    return .{ .ptr = std.heap.page_allocator.ptr, .vtable = table };
}

/// A mapper that must never run: `map_err` over the `Ok` arm hands the success
/// through without calling it. (`PanicValueMapper` above already traps the
/// `Err` arm of `map`, so the `map` passthrough test reuses it.)
const NeverMapErrMapper = struct {
    pub fn call(_: *@This(), _: u8) u8 {
        @panic("map_err called for Ok");
    }
};

test "unit Result supports state, extraction, and option conversion" {
    const UnitResult = Result(void, DecodeError);
    const success: UnitResult = .{ .Ok = {} };

    try std.testing.expect(success.is_ok());
    try std.testing.expect(!success.is_err());
    try std.testing.expect(success.ok(std.testing.allocator) != null);
    try std.testing.expect(success.err(std.testing.allocator) == null);
    _ = success.unwrap(std.testing.allocator);

    const failure: UnitResult = .{ .Err = .odd_length };
    try std.testing.expect(failure.is_err());
    try std.testing.expect(!failure.is_ok());
    try std.testing.expect(failure.ok(std.testing.allocator) == null);
    const decode_error = failure.err(std.testing.allocator) orelse return error.ExpectedError;
    switch (decode_error) {
        .odd_length => {},
        .invalid_character => return error.ExpectedOddLength,
    }
    switch (failure.unwrap_err(std.testing.allocator)) {
        .odd_length => {},
        .invalid_character => return error.ExpectedOddLength,
    }

    const mapped = success.map(unitToByte);
    try std.testing.expectEqual(@as(u8, 7), mapped.unwrap(std.testing.allocator));
}

test "Result reference adapters borrow original value and error storage" {
    var value_result: Result(u16, DecodeError) = .{ .Ok = 11 };
    const value_ref = value_result.as_ref().unwrap(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 11), value_ref.*);

    value_result.as_mut().unwrap(std.testing.allocator).* = 29;
    try std.testing.expectEqual(@as(u16, 29), value_result.unwrap(std.testing.allocator));

    var error_result: Result(u16, DecodeError) = .{
        .Err = .{ .invalid_character = .{ .value = 'x', .index = 3 } },
    };
    const error_ref = error_result.as_ref().unwrap_err(std.testing.allocator);
    const original_index = switch (error_ref.*) {
        .odd_length => return error.ExpectedInvalidCharacter,
        .invalid_character => |detail| detail.index,
    };
    try std.testing.expectEqual(@as(usize, 3), original_index);

    const error_mut = error_result.as_mut().unwrap_err(std.testing.allocator);
    switch (error_mut.*) {
        .odd_length => return error.ExpectedInvalidCharacter,
        .invalid_character => |*detail| {
            detail.value = 'z';
            detail.index = 8;
        },
    }
    const moved_error = error_result.unwrap_err(std.testing.allocator);
    const moved_detail = switch (moved_error) {
        .odd_length => return error.ExpectedInvalidCharacter,
        .invalid_character => |detail| detail,
    };
    try std.testing.expectEqual(@as(u8, 'z'), moved_detail.value);
    try std.testing.expectEqual(@as(usize, 8), moved_detail.index);
}

test "map invokes function and captured callable only for Ok" {
    var referenced_value: u16 = 4;
    const referenced_result: Result(*u16, DecodeError) = .{ .Ok = &referenced_value };
    try std.testing.expectEqual(@as(u16, 5), referenced_result.map(increment).unwrap(std.testing.allocator));
    try std.testing.expectEqual(@as(u16, 5), referenced_value);

    var calls: u8 = 0;
    const callable: AddCaptured = .{ .delta = 9, .calls = &calls };
    const success: Result(u8, DecodeError) = .{ .Ok = 6 };
    try std.testing.expectEqual(@as(u16, 15), success.map(callable).unwrap(std.testing.allocator));
    try std.testing.expectEqual(@as(u8, 1), calls);

    const failure: Result(u8, DecodeError) = .{
        .Err = .{ .invalid_character = .{ .value = 'q', .index = 12 } },
    };
    const trap: PanicValueMapper = .{};
    const unchanged = failure.map(trap).unwrap_err(std.testing.allocator);
    const unchanged_detail = switch (unchanged) {
        .odd_length => return error.ExpectedInvalidCharacter,
        .invalid_character => |detail| detail,
    };
    try std.testing.expectEqual(@as(u8, 'q'), unchanged_detail.value);
    try std.testing.expectEqual(@as(usize, 12), unchanged_detail.index);
}

test "map infers output from a generic function payload" {
    const input: Result(u16, DecodeError) = .{ .Ok = 23 };
    try std.testing.expectEqual(@as(u16, 23), input.map(genericIdentity).unwrap(std.testing.allocator));
}

test "map_err invokes captured callable only for Err" {
    var calls: u8 = 0;
    const callable: ErrorIndex = .{ .calls = &calls };
    const failure: Result(u8, DecodeError) = .{
        .Err = .{ .invalid_character = .{ .value = 'g', .index = 14 } },
    };
    try std.testing.expectEqual(@as(usize, 14), failure.map_err(callable).unwrap_err(std.testing.allocator));
    try std.testing.expectEqual(@as(u8, 1), calls);

    const success: Result(u8, DecodeError) = .{ .Ok = 31 };
    const trap: PanicErrorMapper = .{};
    try std.testing.expectEqual(@as(u8, 31), success.map_err(trap).unwrap(std.testing.allocator));
}

// A payload the caller DOES get back must not be released on the way through.
// Rust's `unwrap`, `expect` and `expect_err` move their payload out whole, so
// the storage still belongs to whoever received it: a spurious release would
// free bytes that are still live. These use a real runtime container under the
// test allocator, so a release that should not happen shows up as a double
// free and a release that should happen shows up as a leak.
test "unwrap hands the Ok payload back without releasing it" {
    const string = try alloc.String.from_str(std.testing.allocator, "okdata");
    const owned: Result(alloc.String, DecodeError) = .{ .Ok = string };
    var taken = owned.unwrap(std.testing.allocator);
    try std.testing.expectEqualStrings("okdata", taken.as_str());
    taken.deinit(std.testing.allocator);
}

test "expect hands the Ok payload back without releasing it" {
    const message = runtimeMessage("Should read number at index {d}", 3);
    defer std.heap.page_allocator.free(message);

    const scalar: Result(u8, DecodeError) = .{ .Ok = 7 };
    try std.testing.expectEqual(@as(u8, 7), scalar.expect(std.testing.allocator, message));

    const string = try alloc.String.from_str(std.testing.allocator, "okdata");
    const owned: Result(alloc.String, DecodeError) = .{ .Ok = string };
    var taken = owned.expect(std.testing.allocator, message);
    try std.testing.expectEqualStrings("okdata", taken.as_str());
    taken.deinit(std.testing.allocator);
}

test "expect_err returns the whole Err value, not just its tag" {
    const message = runtimeMessage("Should not be Ok at index {d}", 5);
    defer std.heap.page_allocator.free(message);

    const failure: Result(u8, DecodeError) = .{
        .Err = .{ .invalid_character = .{ .value = 'x', .index = 5 } },
    };
    const taken = failure.expect_err(std.testing.allocator, message);
    const detail = switch (taken) {
        .odd_length => return error.ExpectedInvalidCharacter,
        .invalid_character => |fields| fields,
    };
    try std.testing.expectEqual(@as(u8, 'x'), detail.value);
    try std.testing.expectEqual(@as(usize, 5), detail.index);
}

test "unwrap reports its fixed message when the receiver is Err" {
    try panic_probe.expectPanic(.{
        .case_name = "unwrap-err",
        .expected = "Result.unwrap called on Err",
        .body = struct {
            fn body() void {
                const failure: Result(u8, DecodeError) = .{ .Err = .odd_length };
                _ = failure.unwrap(std.testing.allocator);
            }
        }.body,
    });
}

test "expect reports the caller's own message when the receiver is Err" {
    try panic_probe.expectPanic(.{
        .case_name = "expect-message",
        .expected = "no leb128 byte at index 3",
        .body = struct {
            fn body() void {
                const message = runtimeMessage("no leb128 byte at index {d}", 3);
                const failure: Result(u8, DecodeError) = .{ .Err = .odd_length };
                _ = failure.expect(std.testing.allocator, message);
            }
        }.body,
    });
}

test "expect_err reports the caller's message when the receiver is Ok" {
    try panic_probe.expectPanic(.{
        .case_name = "expect-err-message",
        .expected = "Should not be Ok at index 0",
        .body = struct {
            fn body() void {
                const message = runtimeMessage("Should not be Ok at index {d}", 0);
                const success: Result(u8, DecodeError) = .{ .Ok = 7 };
                _ = success.expect_err(std.testing.allocator, message);
            }
        }.body,
    });
}

test "the abandoned-payload release frees a real runtime container" {
    // This is the mechanism every abandoning arm above, and in
    // `expect_error_union_err`, uses: `alloc.dropTemporary`, which frees only
    // the containers the runtime itself owns and never calls a method on a
    // value it does not. Exercised where it is observable — the test allocator
    // reports a leak the moment the release stops happening, and nothing is read
    // afterwards because an abandoned payload is exactly the value nobody gets
    // back.
    const owned = try alloc.String.from_str(std.testing.allocator, "owned");
    releaseAbandonedPayload(std.testing.allocator, owned);
}

// A `Result` whose error cannot be spelled as a Zig error set — one whose
// variants carry payloads — lowers to the tagged `r2z.Result` union and uses
// the methods above. A fieldless error enum CAN be one, and then the value is
// a Zig error union with no runtime `Result` to call a method on: the `Ok`
// payload still has to come out and the failure still has to report the
// caller's message, which is what these two free functions are for.
test "expect_error_union returns the Ok payload of a native error union" {
    const Payload = error{ Bad, Overflow };

    const message = runtimeMessage("Should read number at index {d}", 3);
    defer std.heap.page_allocator.free(message);

    const success: Payload!u8 = 7;
    try std.testing.expectEqual(@as(u8, 7), expect_error_union(success, message));
}

test "expect_error_union hands the owned Ok payload to the caller" {
    // The union is consumed and its payload moved out whole, the same way the
    // tagged union's `expect` moves one: nothing was released on the way
    // through, and the storage that came back is the storage the union was
    // holding, still owned by whoever received it.
    const string = try alloc.String.from_str(std.testing.allocator, "tag!");
    const success: anyerror!alloc.String = string;
    var taken = expect_error_union(success, "Should read number");
    try std.testing.expectEqualStrings("tag!", taken.as_str());
    taken.deinit(std.testing.allocator);
}

test "expect_error_union panics with the caller's message on the error path" {
    try panic_probe.expectPanic(.{
        .case_name = "expect-error-union",
        .expected = "no leb128 byte at index 3",
        .body = struct {
            fn body() void {
                const message = runtimeMessage("no leb128 byte at index {d}", 3);
                const failure: anyerror!u8 = error.Bad;
                _ = expect_error_union(failure, message);
            }
        }.body,
    });
}

test "expect_error_union_err returns the source error value a native error union carries" {
    const message = runtimeMessage("Should not be Ok at index {d}", 5);
    defer std.heap.page_allocator.free(message);

    // The backend represents a lowered `Result<T, E>` as `anyerror!T`, so this
    // is the union the emitted call site actually hands over: the error is
    // `anyerror`, not the closed set of the source enum's own members.
    const failure: anyerror!u8 = error.Overflow;
    // The fieldless error enum became an error set, so its variants survived
    // as tags — but `expect_err` owes the caller the Rust `E`, not the tag the
    // union spells it with. The value handed back is `Fault.Overflow`, and its
    // type is `Fault`: an expression typed `Fault` has to accept it.
    const failure_value: Fault = expect_error_union_err(Fault, std.testing.allocator, failure, message);
    try std.testing.expectEqual(Fault.Overflow, failure_value);
}

test "expect_error_union_err maps each native error to its own variant" {
    // Both members stand for a different variant of the same source enum, so
    // the correspondence is per error rather than one answer for the whole
    // union, and it holds for an `anyerror` receiver as it does for a closed
    // set: the mapping is decided from the source enum, not from the set.
    const bad: anyerror!u8 = error.Bad;
    const overflow: anyerror!u8 = error.Overflow;
    try std.testing.expectEqual(Fault.Bad, expect_error_union_err(Fault, std.testing.allocator, bad, "unused"));
    try std.testing.expectEqual(Fault.Overflow, expect_error_union_err(Fault, std.testing.allocator, overflow, "unused"));
}

test "expect_error_union_err refuses a native error the source enum never declared" {
    // `anyerror` is open: a union can carry an error the source enum never
    // declared, and that member has no value in `E`. Reporting one of the
    // enum's own variants instead would hand the caller a failure the source
    // never produced, so the mapping has to stop.
    try panic_probe.expectPanic(.{
        .case_name = "expect-error-union-err-undeclared",
        .expected = "native error Unexpected has no value in the source error enum",
        .body = struct {
            fn body() void {
                const failure: anyerror!u8 = error.Unexpected;
                const unexpected = expect_error_union_err(Fault, std.testing.allocator, failure, "unused");
                std.debug.panic("expect_error_union_err returned {s} for an undeclared error", .{@tagName(unexpected)});
            }
        }.body,
    });
}

test "expect_error_union_err panics with the caller's message on the Ok path" {
    try panic_probe.expectPanic(.{
        .case_name = "expect-error-union-err-ok",
        .expected = "Should not be Ok at index 0",
        .body = struct {
            fn body() void {
                const message = runtimeMessage("Should not be Ok at index {d}", 0);
                const success: anyerror!u8 = 7;
                // This path must never return at all, so the value is consumed
                // by an explicit failure that reports it: an `Ok` union that
                // somehow did return fails the guard instead of passing it
                // silently.
                const unexpected = expect_error_union_err(Fault, std.testing.allocator, success, message);
                std.debug.panic("expect_error_union_err returned {s} for an Ok union", .{@tagName(unexpected)});
            }
        }.body,
    });
}

test "Result option extraction releases discarded owners and moves retained owners" {
    const gpa = std.testing.allocator;
    const failed: Result(u8, alloc.String) = .{
        .Err = try alloc.String.from_str(gpa, "discarded error"),
    };
    try std.testing.expect(failed.ok(gpa) == null);
    const succeeded: Result(alloc.String, u8) = .{
        .Ok = try alloc.String.from_str(gpa, "discarded success"),
    };
    try std.testing.expect(succeeded.err(gpa) == null);

    const kept: Result(alloc.String, u8) = .{
        .Ok = try alloc.String.from_str(gpa, "kept success"),
    };
    var success = kept.ok(gpa) orelse return error.ExpectedSuccess;
    defer success.deinit(gpa);
    try std.testing.expectEqualStrings("kept success", success.as_str());
    try std.testing.expectEqual(@intFromPtr(kept.Ok.as_bytes().ptr), @intFromPtr(success.as_bytes().ptr));

    const kept_error: Result(u8, alloc.String) = .{
        .Err = try alloc.String.from_str(gpa, "kept error"),
    };
    var failure = kept_error.err(gpa) orelse return error.ExpectedError;
    defer failure.deinit(gpa);
    try std.testing.expectEqualStrings("kept error", failure.as_str());
    try std.testing.expectEqual(@intFromPtr(kept_error.Err.as_bytes().ptr), @intFromPtr(failure.as_bytes().ptr));
}

test "unwrap_err releases the owned success payload before panicking" {
    try panic_probe.expectPanic(.{
        .case_name = "unwrap-err-owned-ok",
        .expected = "Result.unwrap_err called on Ok",
        .required = &.{"released owned success before panic"},
        .body = struct {
            fn body() void {
                const vtable = comptime blk: {
                    var table = std.heap.page_allocator.vtable.*;
                    table.free = free;
                    break :blk table;
                };
                const gpa: std.mem.Allocator = .{
                    .ptr = std.heap.page_allocator.ptr,
                    .vtable = &vtable,
                };
                const value: Result(alloc.String, u8) = .{
                    .Ok = alloc.String.from_str(gpa, "owned success") catch unreachable,
                };
                _ = value.unwrap_err(gpa);
            }

            fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
                std.heap.page_allocator.rawFree(memory, alignment, return_address);
                std.debug.print("released owned success before panic\n", .{});
            }
        }.body,
    });
}

test "unwrap releases an owned Err payload before it panics" {
    try panic_probe.expectPanic(.{
        .case_name = "unwrap-owned-err",
        .expected = "Result.unwrap called on Err",
        .required = &.{"released the abandoned payload before the panic"},
        .body = struct {
            fn body() void {
                var table: std.mem.Allocator.VTable = undefined;
                const gpa = announcingAllocator(&table);
                const failure: Result(u8, alloc.String) = .{
                    .Err = alloc.String.from_str(gpa, "owned error") catch unreachable,
                };
                _ = failure.unwrap(gpa);
            }
        }.body,
    });
}

test "expect releases an owned Err payload before it panics" {
    try panic_probe.expectPanic(.{
        .case_name = "expect-owned-err",
        .expected = "Should read number at index 3",
        .required = &.{"released the abandoned payload before the panic"},
        .body = struct {
            fn body() void {
                var table: std.mem.Allocator.VTable = undefined;
                const gpa = announcingAllocator(&table);
                const failure: Result(u8, alloc.String) = .{
                    .Err = alloc.String.from_str(gpa, "owned error") catch unreachable,
                };
                _ = failure.expect(gpa, runtimeMessage("Should read number at index {d}", 3));
            }
        }.body,
    });
}

test "expect_err releases an owned Ok payload before it panics" {
    try panic_probe.expectPanic(.{
        .case_name = "expect-err-owned-ok",
        .expected = "Should not be Ok at index 0",
        .required = &.{"released the abandoned payload before the panic"},
        .body = struct {
            fn body() void {
                var table: std.mem.Allocator.VTable = undefined;
                const gpa = announcingAllocator(&table);
                const success: Result(alloc.String, u8) = .{
                    .Ok = alloc.String.from_str(gpa, "owned success") catch unreachable,
                };
                _ = success.expect_err(gpa, runtimeMessage("Should not be Ok at index {d}", 0));
            }
        }.body,
    });
}

test "expect_error_union_err releases an owned Ok payload before it panics" {
    // The native-union twin of the tagged union's `unwrap_err`: the `Ok` arm
    // the caller abandons still owns its storage, so it is released on the
    // way into the panic and the payload the union was holding is freed
    // exactly once.
    try panic_probe.expectPanic(.{
        .case_name = "expect-error-union-err-owned-ok",
        .expected = "Should not be Ok at index 0",
        .required = &.{"released the abandoned payload before the panic"},
        .body = struct {
            fn body() void {
                var table: std.mem.Allocator.VTable = undefined;
                const gpa = announcingAllocator(&table);
                const success: anyerror!alloc.String = alloc.String.from_str(gpa, "owned success") catch unreachable;
                _ = expect_error_union_err(Fault, gpa, success, runtimeMessage("Should not be Ok at index {d}", 0));
            }
        }.body,
    });
}

test "map hands an untouched owned Err through without releasing it" {
    // The `Err` arm of `map` is a move, not a release: the payload that
    // reaches the caller is the same allocation the union held, the mapper
    // never ran, and the caller's own release below is the only one.
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    const carried: Result(u8, alloc.String) = .{
        .Err = try alloc.String.from_str(gpa, "carried error"),
    };
    const address = @intFromPtr(carried.Err.as_bytes().ptr);
    const trap: PanicValueMapper = .{};
    const passed = carried.map(trap);
    try std.testing.expect(passed.is_err());

    var taken = passed.unwrap_err(gpa);
    try std.testing.expectEqualStrings("carried error", taken.as_str());
    try std.testing.expectEqual(address, @intFromPtr(taken.as_bytes().ptr));
    const before_release = tracking.deallocations;
    taken.deinit(gpa);
    try std.testing.expectEqual(before_release + 1, tracking.deallocations);
}

test "map_err hands an untouched owned Ok through without releasing it" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    const carried: Result(alloc.String, u8) = .{
        .Ok = try alloc.String.from_str(gpa, "carried success"),
    };
    const address = @intFromPtr(carried.Ok.as_bytes().ptr);
    const trap: NeverMapErrMapper = .{};
    const passed = carried.map_err(trap);
    try std.testing.expect(passed.is_ok());

    var taken = passed.unwrap(gpa);
    try std.testing.expectEqualStrings("carried success", taken.as_str());
    try std.testing.expectEqual(address, @intFromPtr(taken.as_bytes().ptr));
    const before_release = tracking.deallocations;
    taken.deinit(gpa);
    try std.testing.expectEqual(before_release + 1, tracking.deallocations);
}

test "a borrow of a runtime Result reaches the caller's storage and releases nothing" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    // `as_ref` hands back a second union whose payloads are pointers into the
    // caller's own union. Consuming the borrowed union (`unwrap` on it)
    // releases nothing — the payload is a borrow, and the generic release
    // does not follow one — while the caller's own union keeps its release,
    // which frees exactly once.
    var held: Result(alloc.String, u8) = .{
        .Ok = try alloc.String.from_str(gpa, "borrowed success"),
    };
    const address = @intFromPtr(held.Ok.as_bytes().ptr);
    const borrowed = held.as_ref();

    const before_borrow_release = tracking.deallocations;
    const read = borrowed.unwrap(gpa);
    try std.testing.expectEqualStrings("borrowed success", read.as_str());
    try std.testing.expectEqual(address, @intFromPtr(read.as_bytes().ptr));
    alloc.dropTemporary(gpa, &borrowed);
    try std.testing.expectEqual(before_borrow_release, tracking.deallocations);

    const before_owner_release = tracking.deallocations;
    alloc.dropTemporary(gpa, &held);
    try std.testing.expectEqual(before_owner_release + 1, tracking.deallocations);
}

test "a moved runtime Result leaves its handle empty so the scope release frees nothing" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    // The shape the backend emits for an owned payload moved out of a `Result`
    // binding: `takeOwned` transfers the active arm and empties the handle in
    // place, so the `defer dropTemporary` the frame armed over it finds
    // nothing to free, and the moved descriptor is the payload's only owner.
    var error_held: Result(u8, alloc.String) = .{
        .Err = try alloc.String.from_str(gpa, "moved error"),
    };
    const error_address = @intFromPtr(error_held.Err.as_bytes().ptr);
    const moved_error = alloc.takeOwned(Result(u8, alloc.String), &error_held);

    const before_error_release = tracking.deallocations;
    alloc.dropTemporary(gpa, &error_held);
    try std.testing.expectEqual(before_error_release, tracking.deallocations);
    try std.testing.expect(error_held.Err.is_empty());

    var taken_error = moved_error.unwrap_err(gpa);
    try std.testing.expectEqualStrings("moved error", taken_error.as_str());
    try std.testing.expectEqual(error_address, @intFromPtr(taken_error.as_bytes().ptr));
    const before_taken_error_release = tracking.deallocations;
    taken_error.deinit(gpa);
    try std.testing.expectEqual(before_taken_error_release + 1, tracking.deallocations);

    var success_held: Result(alloc.String, u8) = .{
        .Ok = try alloc.String.from_str(gpa, "moved success"),
    };
    const success_address = @intFromPtr(success_held.Ok.as_bytes().ptr);
    const moved_success = alloc.takeOwned(Result(alloc.String, u8), &success_held);

    const before_success_release = tracking.deallocations;
    alloc.dropTemporary(gpa, &success_held);
    try std.testing.expectEqual(before_success_release, tracking.deallocations);
    try std.testing.expect(success_held.Ok.is_empty());

    var taken_success = moved_success.ok(gpa) orelse return error.ExpectedSuccess;
    try std.testing.expectEqualStrings("moved success", taken_success.as_str());
    try std.testing.expectEqual(success_address, @intFromPtr(taken_success.as_bytes().ptr));
    const before_taken_success_release = tracking.deallocations;
    taken_success.deinit(gpa);
    try std.testing.expectEqual(before_taken_success_release + 1, tracking.deallocations);
}
