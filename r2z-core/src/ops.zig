const std = @import("std");

pub const Operation = enum { add, sub, mul, div, rem, bit_and, bit_or, bit_xor, shl, shr, eq, ne, lt, le, gt, ge };
pub const Overflow = enum { checked, wrapping, saturating };

fn methodName(comptime operation: Operation) []const u8 {
    return switch (operation) {
        .bit_and => "bitand",
        .bit_or => "bitor",
        .bit_xor => "bitxor",
        else => @tagName(operation),
    };
}

fn isComparison(comptime operation: Operation) bool {
    return switch (operation) {
        .eq, .ne, .lt, .le, .gt, .ge => true,
        else => false,
    };
}

fn BinaryResult(comptime operation: Operation, comptime Left: type, comptime Right: type) type {
    if (isComparison(operation)) return bool;
    return switch (@typeInfo(Left)) {
        .int, .comptime_int, .float, .comptime_float => Left,
        else => @TypeOf(@call(.auto, @field(Left, methodName(operation)), .{ @as(Left, undefined), @as(Right, undefined) })),
    };
}

pub fn binary(comptime operation: Operation, comptime overflow: Overflow, left: anytype, right: anytype) BinaryResult(operation, @TypeOf(left), @TypeOf(right)) {
    if (operation == .eq) return equal(left, right);
    if (operation == .ne) return !equal(left, right);
    const Left = @TypeOf(left);
    switch (@typeInfo(Left)) {
        .int, .comptime_int, .float, .comptime_float, .bool => {},
        else => {
            if (comptime isComparison(operation)) return @call(.auto, @field(Left, methodName(operation)), .{ &left, &right });
            return @call(.auto, @field(Left, methodName(operation)), .{ left, right });
        },
    }
    return switch (operation) {
        .add => switch (overflow) {
            .checked => left + right,
            .wrapping => left +% right,
            .saturating => left +| right,
        },
        .sub => switch (overflow) {
            .checked => left - right,
            .wrapping => left -% right,
            .saturating => left -| right,
        },
        .mul => switch (overflow) {
            .checked => left * right,
            .wrapping => left *% right,
            .saturating => left *| right,
        },
        .div => if (@typeInfo(Left) == .float or @typeInfo(Left) == .comptime_float) left / right else @divTrunc(left, right),
        .rem => @rem(left, right),
        .bit_and => left & right,
        .bit_or => left | right,
        .bit_xor => left ^ right,
        .shl => left << @intCast(right),
        .shr => left >> @intCast(right),
        .lt => left < right,
        .le => left <= right,
        .gt => left > right,
        .ge => left >= right,
        .eq, .ne => unreachable,
    };
}

pub fn assign(comptime operation: Operation, comptime overflow: Overflow, target: anytype, value: anytype) void {
    const Target = @typeInfo(@TypeOf(target)).pointer.child;
    switch (@typeInfo(Target)) {
        .int, .float => target.* = binary(operation, overflow, target.*, value),
        else => @call(.auto, @field(Target, methodName(operation) ++ "_assign"), .{ target, value }),
    }
}

pub fn equal(left: anytype, right: anytype) bool {
    const Left = @TypeOf(left);
    return switch (@typeInfo(Left)) {
        .array => blk: {
            if (left.len != right.len) break :blk false;
            for (left, right) |a, b| if (!equal(a, b)) break :blk false;
            break :blk true;
        },
        .pointer => |pointer| if (pointer.size == .slice) blk: {
            if (left.len != right.len) break :blk false;
            for (left, right) |a, b| if (!equal(a, b)) break :blk false;
            break :blk true;
        } else if (pointer.size == .one) equal(left.*, right.*) else left == right,
        .optional => if (left) |a| if (right) |b| equal(a, b) else false else right == null,
        .@"struct", .@"union" => @call(.auto, @field(Left, "eq"), .{ &left, &right }),
        else => left == right,
    };
}

test "generic operators preserve primitive arithmetic and trait outputs" {
    const Number = struct {
        value: u8,
        pub fn add(self: @This(), other: u16) u32 {
            return @as(u32, self.value) + other;
        }
        pub fn add_assign(self: *@This(), other: u16) void {
            self.value += @intCast(other);
        }
    };
    try std.testing.expectEqual(@as(u8, 0), binary(.add, .wrapping, @as(u8, 255), @as(u8, 1)));
    try std.testing.expectEqual(@as(i16, -2), binary(.div, .checked, @as(i16, -5), @as(i16, 2)));
    try std.testing.expectEqual(@as(u16, 256), binary(.shl, .checked, @as(u16, 1), @as(u16, 8)));
    try std.testing.expectEqual(@as(u32, 305), binary(.add, .checked, Number{ .value = 5 }, @as(u16, 300)));
    var number: Number = .{ .value = 5 };
    assign(.add, .checked, &number, @as(u16, 7));
    try std.testing.expectEqual(@as(u8, 12), number.value);
}

test "generic equality compares slice elements and optional values" {
    const first = [_]u8{ 1, 2, 3 };
    var second = [_]u8{ 1, 2, 3 };
    try std.testing.expect(equal(first[0..], second[0..]));
    second[1] = 4;
    try std.testing.expect(!equal(first[0..], second[0..]));
    try std.testing.expect(!equal(first[0..2], second[0..]));
    try std.testing.expect(equal(@as(?u8, null), @as(?u8, null)));
    try std.testing.expect(!equal(@as(?u8, 0), @as(?u8, null)));
}
