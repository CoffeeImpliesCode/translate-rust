const std = @import("std");
const invokeMapper = @import("result.zig").invokeMapper;

pub fn unwrap(value: anytype) @typeInfo(@TypeOf(value)).optional.child {
    return value orelse @panic("Option.unwrap called on None");
}

pub fn unwrap_or(value: anytype, fallback: @typeInfo(@TypeOf(value)).optional.child) @typeInfo(@TypeOf(value)).optional.child {
    return value orelse fallback;
}

pub fn as_ref(value: anytype) ?*const @typeInfo(@typeInfo(@TypeOf(value)).pointer.child).optional.child {
    if (value.*) |*payload| return payload;
    return null;
}

pub fn map(value: anytype, mapper: anytype) ?@TypeOf(invokeMapper(
    @typeInfo(@TypeOf(value)).optional.child,
    mapper,
    @as(@typeInfo(@TypeOf(value)).optional.child, undefined),
)) {
    const Input = @typeInfo(@TypeOf(value)).optional.child;
    if (value) |payload| return invokeMapper(Input, mapper, payload);
    return null;
}

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
