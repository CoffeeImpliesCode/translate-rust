const std = @import("std");
const alloc = @import("alloc.zig");
const panic_probe = @import("panic_probe.zig");

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

pub fn Result(comptime T: type, comptime E: type) type {
    return union(enum) {
        Ok: T,
        Err: E,

        const Self = @This();

        pub fn unwrap(self: Self, gpa: std.mem.Allocator) T {
            return switch (self) {
                .Ok => |value| value,
                .Err => |error_value| {
                    releaseAbandonedPayload(gpa, error_value);
                    @panic("Result.unwrap called on Err");
                },
            };
        }

        pub fn unwrap_err(self: Self) E {
            return switch (self) {
                .Ok => @panic("Result.unwrap_err called on Ok"),
                .Err => |error_value| error_value,
            };
        }

        /// `unwrap` with a message the caller chose, reported in place of the
        /// fixed one. The `Err` is consumed on the way into the panic, so an
        /// `Err` that owns storage is released first, exactly as `unwrap`
        /// does.
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
        pub fn expect_err(self: Self, gpa: std.mem.Allocator, msg: []const u8) E {
            return switch (self) {
                .Ok => |value| {
                    releaseAbandonedPayload(gpa, value);
                    @panic(msg);
                },
                .Err => |error_value| error_value,
            };
        }

        pub fn is_ok(self: Self) bool {
            return switch (self) {
                .Ok => true,
                .Err => false,
            };
        }

        pub fn is_err(self: Self) bool {
            return switch (self) {
                .Ok => false,
                .Err => true,
            };
        }

        pub fn ok(self: Self) ?T {
            return switch (self) {
                .Ok => |value| value,
                .Err => null,
            };
        }

        pub fn err(self: Self) ?E {
            return switch (self) {
                .Ok => null,
                .Err => |error_value| error_value,
            };
        }

        pub fn as_ref(self: *const Self) Result(*const T, *const E) {
            return switch (self.*) {
                .Ok => |*value| .{ .Ok = value },
                .Err => |*error_value| .{ .Err = error_value },
            };
        }

        pub fn as_mut(self: *Self) Result(*T, *E) {
            return switch (self.*) {
                .Ok => |*value| .{ .Ok = value },
                .Err => |*error_value| .{ .Err = error_value },
            };
        }

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

test "unit Result supports state, extraction, and option conversion" {
    const UnitResult = Result(void, DecodeError);
    const success: UnitResult = .{ .Ok = {} };

    try std.testing.expect(success.is_ok());
    try std.testing.expect(!success.is_err());
    try std.testing.expect(success.ok() != null);
    try std.testing.expect(success.err() == null);
    _ = success.unwrap(std.testing.allocator);

    const failure: UnitResult = .{ .Err = .odd_length };
    try std.testing.expect(failure.is_err());
    try std.testing.expect(!failure.is_ok());
    try std.testing.expect(failure.ok() == null);
    const decode_error = failure.err() orelse return error.ExpectedError;
    switch (decode_error) {
        .odd_length => {},
        .invalid_character => return error.ExpectedOddLength,
    }
    switch (failure.unwrap_err()) {
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
    const error_ref = error_result.as_ref().unwrap_err();
    const original_index = switch (error_ref.*) {
        .odd_length => return error.ExpectedInvalidCharacter,
        .invalid_character => |detail| detail.index,
    };
    try std.testing.expectEqual(@as(usize, 3), original_index);

    const error_mut = error_result.as_mut().unwrap_err();
    switch (error_mut.*) {
        .odd_length => return error.ExpectedInvalidCharacter,
        .invalid_character => |*detail| {
            detail.value = 'z';
            detail.index = 8;
        },
    }
    const moved_error = error_result.unwrap_err();
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
    const unchanged = failure.map(trap).unwrap_err();
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
    try std.testing.expectEqual(@as(usize, 14), failure.map_err(callable).unwrap_err());
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
