const std = @import("std");

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

pub fn Result(comptime T: type, comptime E: type) type {
    return union(enum) {
        Ok: T,
        Err: E,

        const Self = @This();

        pub fn unwrap(self: Self) T {
            return switch (self) {
                .Ok => |value| value,
                .Err => @panic("Result.unwrap called on Err"),
            };
        }

        pub fn unwrap_err(self: Self) E {
            return switch (self) {
                .Ok => @panic("Result.unwrap_err called on Ok"),
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
    _ = success.unwrap();

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
    try std.testing.expectEqual(@as(u8, 7), mapped.unwrap());
}

test "Result reference adapters borrow original value and error storage" {
    var value_result: Result(u16, DecodeError) = .{ .Ok = 11 };
    const value_ref = value_result.as_ref().unwrap();
    try std.testing.expectEqual(@as(u16, 11), value_ref.*);

    value_result.as_mut().unwrap().* = 29;
    try std.testing.expectEqual(@as(u16, 29), value_result.unwrap());

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
    try std.testing.expectEqual(@as(u16, 5), referenced_result.map(increment).unwrap());
    try std.testing.expectEqual(@as(u16, 5), referenced_value);

    var calls: u8 = 0;
    const callable: AddCaptured = .{ .delta = 9, .calls = &calls };
    const success: Result(u8, DecodeError) = .{ .Ok = 6 };
    try std.testing.expectEqual(@as(u16, 15), success.map(callable).unwrap());
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
    try std.testing.expectEqual(@as(u16, 23), input.map(genericIdentity).unwrap());
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
    try std.testing.expectEqual(@as(u8, 31), success.map_err(trap).unwrap());
}
