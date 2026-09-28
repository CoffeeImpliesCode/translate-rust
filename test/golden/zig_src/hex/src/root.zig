const std = @import("std");
const error_1 = @import("./error.zig");
const @"error" = @import("./error.zig");
const @"test" = @import("./test.zig");
const r2z = @import("r2z");

pub const FromHexError = error.FromHexError;

const HEX_CHARS_LOWER: [16]u8 = [_]u8{ 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 97, 98, 99, 100, 101, 102 };

const HEX_CHARS_UPPER: [16]u8 = [_]u8{ 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 65, 66, 67, 68, 69, 70 };

const BytesToHexChars = struct {
    const Self = @This();

    inner: r2z.SliceIter(u8),
    table: [16]u8,
    next_field: ?u21,

    fn new(inner: []const u8, table: [16]u8) BytesToHexChars {
        return BytesToHexChars{ .inner = r2z.sliceIter(u8, inner), .table = table, .next_field = @as(?u21, null) };
    }

    pub fn next(self: *BytesToHexChars) ?u21 {
        return __r2z_value_block_2: {
            const __r2z_option_match = __r2z_value_block_3: {
                const __r2z_option_take_22: ?u21 = self.next_field;
                self.next_field = null;
                break :__r2z_value_block_3 __r2z_option_take_22;
            };
            break :__r2z_value_block_2 switch ((__r2z_option_match != null)) {
                true => __r2z_value_block_4: {
                    const current = r2z.option.unwrap(__r2z_option_match);
                    break :__r2z_value_block_4 @as(?u21, current);
                },
                false => switch (self.inner.next()) {
                    null => null,
                    else => |__r2z_in_byte| __r2z_value_block_5: {
                        const byte = __r2z_in_byte;
                        break :__r2z_value_block_5 __r2z_value_block_6: {
                            const current_1: u21 = @as(u21, self.table[@as(usize, (byte.* >> @intCast(4)))]);
                            self.next_field = @as(?u21, @as(u21, self.table[@as(usize, (byte.* & 15))]));
                            break :__r2z_value_block_6 current_1;
                        };
                    },
                },
            };
        };
    }

    pub fn size_hint(self: *const BytesToHexChars) struct { usize, ?usize } {
        const length: usize = self.len();
        return .{ length, @as(?usize, length) };
    }

    pub fn len(self: *const BytesToHexChars) usize {
        var length: usize = (self.inner.len() *% 2);
        if ((self.next_field != null)) {
            length +%= 1;
        }
        return length;
    }
};

fn encode_to_iter(comptime T: type, allocator: std.mem.Allocator, table: [16]u8, source: []const u8) !T {
    var __r2z_owner: T = T.empty;
    errdefer __r2z_owner.deinit(allocator);
    var __r2z_iter = BytesToHexChars.new(source, table);
    while (__r2z_iter.next()) |__r2z_item| {
        try __r2z_owner.append(allocator, __r2z_item);
    }
    return __r2z_owner;
}

fn val(c: u8, idx: usize) r2z.Result(u8, error_1.FromHexError) {
    return switch (c) {
        65...70 => r2z.Result(u8, error_1.FromHexError){ .Ok = ((c -% 65) +% 10) },
        97...102 => r2z.Result(u8, error_1.FromHexError){ .Ok = ((c -% 97) +% 10) },
        48...57 => r2z.Result(u8, error_1.FromHexError){ .Ok = (c -% 48) },
        else => r2z.Result(u8, error_1.FromHexError){ .Err = error_1.FromHexError{ .InvalidHexCharacter = .{ .c = @as(u21, c), .index = idx } } },
    };
}

pub fn decode_to_slice(comptime T: type, data: T, out: []u8) r2z.Result(void, error_1.FromHexError) {
    const data_1: []const u8 = data;
    if (((data_1.len % 2) != 0)) {
        return r2z.Result(void, error_1.FromHexError){ .Err = error_1.FromHexError.OddLength };
    }
    if (((data_1.len / 2) != out.len)) {
        return r2z.Result(void, error_1.FromHexError){ .Err = error_1.FromHexError.InvalidStringLength };
    }
    for (out[0..], 0..) |*byte, i| {
        byte.* = ((switch (val(data_1[(2 *% i)], (2 *% i))) {
            .Ok => |__r2z_try_ok| __r2z_try_ok,
            .Err => |__r2z_try_err| return r2z.Result(void, error_1.FromHexError){ .Err = __r2z_try_err },
        } << @intCast(4)) | switch (val(data_1[((2 *% i) +% 1)], ((2 *% i) +% 1))) {
            .Ok => |__r2z_try_ok| __r2z_try_ok,
            .Err => |__r2z_try_err| return r2z.Result(void, error_1.FromHexError){ .Err = __r2z_try_err },
        });
    }
    return r2z.Result(void, error_1.FromHexError){ .Ok = @as(void, {}) };
}

fn generate_iter(len_1: usize) r2z.Zip(r2z.StepBy(r2z.Range), r2z.StepBy(r2z.Skip(r2z.Range))) {
    return r2z.zip(r2z.stepBy(r2z.Range{ .start = 0, .end = len_1 }, 2), r2z.stepBy(r2z.skip(r2z.Range{ .start = 0, .end = len_1 }, 1), 2));
}

fn byte2hex(byte: u8, table: [16]u8) struct { u8, u8 } {
    const high: u8 = table[@as(usize, ((byte & 240) >> @intCast(4)))];
    const low: u8 = table[@as(usize, (byte & 15))];
    return .{ high, low };
}

pub fn encode_to_slice(comptime T: type, input: T, output: []u8) r2z.Result(void, error_1.FromHexError) {
    if (((input.len *% 2) != output.len)) {
        return r2z.Result(void, error_1.FromHexError){ .Err = error_1.FromHexError.InvalidStringLength };
    }
    {
        var __r2z_iter_1 = generate_iter((input.len *% 2));
        for (input.*[0..]) |*byte| {
            const __r2z_pending_1 = __r2z_iter_1.next();
            if ((__r2z_pending_1 == null)) {
                break;
            }
            const __r2z_tuple = r2z.option.unwrap(__r2z_pending_1);
            const i = __r2z_tuple[0];
            const j = __r2z_tuple[1];
            const _tuple = byte2hex(byte.*, HEX_CHARS_LOWER);
            const high = _tuple[0];
            const low = _tuple[1];
            output[i] = high;
            output[j] = low;
        }
    }
    return r2z.Result(void, error_1.FromHexError){ .Ok = @as(void, {}) };
}

pub fn encode_hex(comptime T: type, comptime U: type, allocator: std.mem.Allocator, self: *const T) !U {
    return try encode_to_iter(U, allocator, HEX_CHARS_LOWER, self);
}

pub fn encode_hex_upper(comptime T: type, comptime U: type, allocator: std.mem.Allocator, self: *const T) !U {
    return try encode_to_iter(U, allocator, HEX_CHARS_UPPER, self);
}

pub fn from_hex(comptime T: type, hex: T) r2z.Result([1]u8, error_1.FromHexError) {
    var out: [1]u8 = [_]u8{ 0 } ** 1;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([1]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([1]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_2(comptime T: type, hex: T) r2z.Result([2]u8, error_1.FromHexError) {
    var out: [2]u8 = [_]u8{ 0 } ** 2;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([2]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([2]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_3(comptime T: type, hex: T) r2z.Result([3]u8, error_1.FromHexError) {
    var out: [3]u8 = [_]u8{ 0 } ** 3;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([3]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([3]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_4(comptime T: type, hex: T) r2z.Result([4]u8, error_1.FromHexError) {
    var out: [4]u8 = [_]u8{ 0 } ** 4;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([4]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([4]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_5(comptime T: type, hex: T) r2z.Result([5]u8, error_1.FromHexError) {
    var out: [5]u8 = [_]u8{ 0 } ** 5;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([5]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([5]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_6(comptime T: type, hex: T) r2z.Result([6]u8, error_1.FromHexError) {
    var out: [6]u8 = [_]u8{ 0 } ** 6;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([6]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([6]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_7(comptime T: type, hex: T) r2z.Result([7]u8, error_1.FromHexError) {
    var out: [7]u8 = [_]u8{ 0 } ** 7;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([7]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([7]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_8(comptime T: type, hex: T) r2z.Result([8]u8, error_1.FromHexError) {
    var out: [8]u8 = [_]u8{ 0 } ** 8;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([8]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([8]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_9(comptime T: type, hex: T) r2z.Result([9]u8, error_1.FromHexError) {
    var out: [9]u8 = [_]u8{ 0 } ** 9;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([9]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([9]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_10(comptime T: type, hex: T) r2z.Result([10]u8, error_1.FromHexError) {
    var out: [10]u8 = [_]u8{ 0 } ** 10;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([10]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([10]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_11(comptime T: type, hex: T) r2z.Result([11]u8, error_1.FromHexError) {
    var out: [11]u8 = [_]u8{ 0 } ** 11;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([11]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([11]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_12(comptime T: type, hex: T) r2z.Result([12]u8, error_1.FromHexError) {
    var out: [12]u8 = [_]u8{ 0 } ** 12;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([12]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([12]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_13(comptime T: type, hex: T) r2z.Result([13]u8, error_1.FromHexError) {
    var out: [13]u8 = [_]u8{ 0 } ** 13;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([13]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([13]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_14(comptime T: type, hex: T) r2z.Result([14]u8, error_1.FromHexError) {
    var out: [14]u8 = [_]u8{ 0 } ** 14;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([14]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([14]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_15(comptime T: type, hex: T) r2z.Result([15]u8, error_1.FromHexError) {
    var out: [15]u8 = [_]u8{ 0 } ** 15;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([15]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([15]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_16(comptime T: type, hex: T) r2z.Result([16]u8, error_1.FromHexError) {
    var out: [16]u8 = [_]u8{ 0 } ** 16;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([16]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([16]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_17(comptime T: type, hex: T) r2z.Result([17]u8, error_1.FromHexError) {
    var out: [17]u8 = [_]u8{ 0 } ** 17;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([17]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([17]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_18(comptime T: type, hex: T) r2z.Result([18]u8, error_1.FromHexError) {
    var out: [18]u8 = [_]u8{ 0 } ** 18;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([18]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([18]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_19(comptime T: type, hex: T) r2z.Result([19]u8, error_1.FromHexError) {
    var out: [19]u8 = [_]u8{ 0 } ** 19;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([19]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([19]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_20(comptime T: type, hex: T) r2z.Result([20]u8, error_1.FromHexError) {
    var out: [20]u8 = [_]u8{ 0 } ** 20;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([20]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([20]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_21(comptime T: type, hex: T) r2z.Result([21]u8, error_1.FromHexError) {
    var out: [21]u8 = [_]u8{ 0 } ** 21;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([21]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([21]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_22(comptime T: type, hex: T) r2z.Result([22]u8, error_1.FromHexError) {
    var out: [22]u8 = [_]u8{ 0 } ** 22;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([22]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([22]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_23(comptime T: type, hex: T) r2z.Result([23]u8, error_1.FromHexError) {
    var out: [23]u8 = [_]u8{ 0 } ** 23;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([23]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([23]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_24(comptime T: type, hex: T) r2z.Result([24]u8, error_1.FromHexError) {
    var out: [24]u8 = [_]u8{ 0 } ** 24;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([24]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([24]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_25(comptime T: type, hex: T) r2z.Result([25]u8, error_1.FromHexError) {
    var out: [25]u8 = [_]u8{ 0 } ** 25;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([25]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([25]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_26(comptime T: type, hex: T) r2z.Result([26]u8, error_1.FromHexError) {
    var out: [26]u8 = [_]u8{ 0 } ** 26;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([26]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([26]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_27(comptime T: type, hex: T) r2z.Result([27]u8, error_1.FromHexError) {
    var out: [27]u8 = [_]u8{ 0 } ** 27;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([27]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([27]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_28(comptime T: type, hex: T) r2z.Result([28]u8, error_1.FromHexError) {
    var out: [28]u8 = [_]u8{ 0 } ** 28;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([28]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([28]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_29(comptime T: type, hex: T) r2z.Result([29]u8, error_1.FromHexError) {
    var out: [29]u8 = [_]u8{ 0 } ** 29;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([29]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([29]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_30(comptime T: type, hex: T) r2z.Result([30]u8, error_1.FromHexError) {
    var out: [30]u8 = [_]u8{ 0 } ** 30;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([30]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([30]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_31(comptime T: type, hex: T) r2z.Result([31]u8, error_1.FromHexError) {
    var out: [31]u8 = [_]u8{ 0 } ** 31;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([31]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([31]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_32(comptime T: type, hex: T) r2z.Result([32]u8, error_1.FromHexError) {
    var out: [32]u8 = [_]u8{ 0 } ** 32;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([32]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([32]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_33(comptime T: type, hex: T) r2z.Result([33]u8, error_1.FromHexError) {
    var out: [33]u8 = [_]u8{ 0 } ** 33;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([33]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([33]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_34(comptime T: type, hex: T) r2z.Result([34]u8, error_1.FromHexError) {
    var out: [34]u8 = [_]u8{ 0 } ** 34;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([34]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([34]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_35(comptime T: type, hex: T) r2z.Result([35]u8, error_1.FromHexError) {
    var out: [35]u8 = [_]u8{ 0 } ** 35;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([35]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([35]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_36(comptime T: type, hex: T) r2z.Result([36]u8, error_1.FromHexError) {
    var out: [36]u8 = [_]u8{ 0 } ** 36;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([36]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([36]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_37(comptime T: type, hex: T) r2z.Result([37]u8, error_1.FromHexError) {
    var out: [37]u8 = [_]u8{ 0 } ** 37;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([37]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([37]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_38(comptime T: type, hex: T) r2z.Result([38]u8, error_1.FromHexError) {
    var out: [38]u8 = [_]u8{ 0 } ** 38;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([38]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([38]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_39(comptime T: type, hex: T) r2z.Result([39]u8, error_1.FromHexError) {
    var out: [39]u8 = [_]u8{ 0 } ** 39;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([39]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([39]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_40(comptime T: type, hex: T) r2z.Result([40]u8, error_1.FromHexError) {
    var out: [40]u8 = [_]u8{ 0 } ** 40;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([40]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([40]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_41(comptime T: type, hex: T) r2z.Result([41]u8, error_1.FromHexError) {
    var out: [41]u8 = [_]u8{ 0 } ** 41;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([41]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([41]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_42(comptime T: type, hex: T) r2z.Result([42]u8, error_1.FromHexError) {
    var out: [42]u8 = [_]u8{ 0 } ** 42;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([42]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([42]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_43(comptime T: type, hex: T) r2z.Result([43]u8, error_1.FromHexError) {
    var out: [43]u8 = [_]u8{ 0 } ** 43;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([43]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([43]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_44(comptime T: type, hex: T) r2z.Result([44]u8, error_1.FromHexError) {
    var out: [44]u8 = [_]u8{ 0 } ** 44;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([44]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([44]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_45(comptime T: type, hex: T) r2z.Result([45]u8, error_1.FromHexError) {
    var out: [45]u8 = [_]u8{ 0 } ** 45;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([45]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([45]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_46(comptime T: type, hex: T) r2z.Result([46]u8, error_1.FromHexError) {
    var out: [46]u8 = [_]u8{ 0 } ** 46;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([46]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([46]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_47(comptime T: type, hex: T) r2z.Result([47]u8, error_1.FromHexError) {
    var out: [47]u8 = [_]u8{ 0 } ** 47;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([47]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([47]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_48(comptime T: type, hex: T) r2z.Result([48]u8, error_1.FromHexError) {
    var out: [48]u8 = [_]u8{ 0 } ** 48;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([48]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([48]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_49(comptime T: type, hex: T) r2z.Result([49]u8, error_1.FromHexError) {
    var out: [49]u8 = [_]u8{ 0 } ** 49;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([49]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([49]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_50(comptime T: type, hex: T) r2z.Result([50]u8, error_1.FromHexError) {
    var out: [50]u8 = [_]u8{ 0 } ** 50;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([50]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([50]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_51(comptime T: type, hex: T) r2z.Result([51]u8, error_1.FromHexError) {
    var out: [51]u8 = [_]u8{ 0 } ** 51;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([51]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([51]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_52(comptime T: type, hex: T) r2z.Result([52]u8, error_1.FromHexError) {
    var out: [52]u8 = [_]u8{ 0 } ** 52;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([52]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([52]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_53(comptime T: type, hex: T) r2z.Result([53]u8, error_1.FromHexError) {
    var out: [53]u8 = [_]u8{ 0 } ** 53;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([53]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([53]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_54(comptime T: type, hex: T) r2z.Result([54]u8, error_1.FromHexError) {
    var out: [54]u8 = [_]u8{ 0 } ** 54;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([54]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([54]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_55(comptime T: type, hex: T) r2z.Result([55]u8, error_1.FromHexError) {
    var out: [55]u8 = [_]u8{ 0 } ** 55;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([55]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([55]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_56(comptime T: type, hex: T) r2z.Result([56]u8, error_1.FromHexError) {
    var out: [56]u8 = [_]u8{ 0 } ** 56;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([56]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([56]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_57(comptime T: type, hex: T) r2z.Result([57]u8, error_1.FromHexError) {
    var out: [57]u8 = [_]u8{ 0 } ** 57;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([57]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([57]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_58(comptime T: type, hex: T) r2z.Result([58]u8, error_1.FromHexError) {
    var out: [58]u8 = [_]u8{ 0 } ** 58;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([58]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([58]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_59(comptime T: type, hex: T) r2z.Result([59]u8, error_1.FromHexError) {
    var out: [59]u8 = [_]u8{ 0 } ** 59;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([59]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([59]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_60(comptime T: type, hex: T) r2z.Result([60]u8, error_1.FromHexError) {
    var out: [60]u8 = [_]u8{ 0 } ** 60;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([60]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([60]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_61(comptime T: type, hex: T) r2z.Result([61]u8, error_1.FromHexError) {
    var out: [61]u8 = [_]u8{ 0 } ** 61;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([61]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([61]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_62(comptime T: type, hex: T) r2z.Result([62]u8, error_1.FromHexError) {
    var out: [62]u8 = [_]u8{ 0 } ** 62;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([62]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([62]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_63(comptime T: type, hex: T) r2z.Result([63]u8, error_1.FromHexError) {
    var out: [63]u8 = [_]u8{ 0 } ** 63;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([63]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([63]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_64(comptime T: type, hex: T) r2z.Result([64]u8, error_1.FromHexError) {
    var out: [64]u8 = [_]u8{ 0 } ** 64;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([64]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([64]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_65(comptime T: type, hex: T) r2z.Result([65]u8, error_1.FromHexError) {
    var out: [65]u8 = [_]u8{ 0 } ** 65;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([65]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([65]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_66(comptime T: type, hex: T) r2z.Result([66]u8, error_1.FromHexError) {
    var out: [66]u8 = [_]u8{ 0 } ** 66;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([66]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([66]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_67(comptime T: type, hex: T) r2z.Result([67]u8, error_1.FromHexError) {
    var out: [67]u8 = [_]u8{ 0 } ** 67;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([67]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([67]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_68(comptime T: type, hex: T) r2z.Result([68]u8, error_1.FromHexError) {
    var out: [68]u8 = [_]u8{ 0 } ** 68;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([68]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([68]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_69(comptime T: type, hex: T) r2z.Result([69]u8, error_1.FromHexError) {
    var out: [69]u8 = [_]u8{ 0 } ** 69;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([69]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([69]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_70(comptime T: type, hex: T) r2z.Result([70]u8, error_1.FromHexError) {
    var out: [70]u8 = [_]u8{ 0 } ** 70;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([70]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([70]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_71(comptime T: type, hex: T) r2z.Result([71]u8, error_1.FromHexError) {
    var out: [71]u8 = [_]u8{ 0 } ** 71;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([71]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([71]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_72(comptime T: type, hex: T) r2z.Result([72]u8, error_1.FromHexError) {
    var out: [72]u8 = [_]u8{ 0 } ** 72;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([72]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([72]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_73(comptime T: type, hex: T) r2z.Result([73]u8, error_1.FromHexError) {
    var out: [73]u8 = [_]u8{ 0 } ** 73;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([73]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([73]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_74(comptime T: type, hex: T) r2z.Result([74]u8, error_1.FromHexError) {
    var out: [74]u8 = [_]u8{ 0 } ** 74;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([74]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([74]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_75(comptime T: type, hex: T) r2z.Result([75]u8, error_1.FromHexError) {
    var out: [75]u8 = [_]u8{ 0 } ** 75;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([75]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([75]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_76(comptime T: type, hex: T) r2z.Result([76]u8, error_1.FromHexError) {
    var out: [76]u8 = [_]u8{ 0 } ** 76;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([76]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([76]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_77(comptime T: type, hex: T) r2z.Result([77]u8, error_1.FromHexError) {
    var out: [77]u8 = [_]u8{ 0 } ** 77;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([77]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([77]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_78(comptime T: type, hex: T) r2z.Result([78]u8, error_1.FromHexError) {
    var out: [78]u8 = [_]u8{ 0 } ** 78;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([78]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([78]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_79(comptime T: type, hex: T) r2z.Result([79]u8, error_1.FromHexError) {
    var out: [79]u8 = [_]u8{ 0 } ** 79;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([79]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([79]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_80(comptime T: type, hex: T) r2z.Result([80]u8, error_1.FromHexError) {
    var out: [80]u8 = [_]u8{ 0 } ** 80;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([80]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([80]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_81(comptime T: type, hex: T) r2z.Result([81]u8, error_1.FromHexError) {
    var out: [81]u8 = [_]u8{ 0 } ** 81;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([81]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([81]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_82(comptime T: type, hex: T) r2z.Result([82]u8, error_1.FromHexError) {
    var out: [82]u8 = [_]u8{ 0 } ** 82;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([82]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([82]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_83(comptime T: type, hex: T) r2z.Result([83]u8, error_1.FromHexError) {
    var out: [83]u8 = [_]u8{ 0 } ** 83;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([83]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([83]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_84(comptime T: type, hex: T) r2z.Result([84]u8, error_1.FromHexError) {
    var out: [84]u8 = [_]u8{ 0 } ** 84;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([84]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([84]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_85(comptime T: type, hex: T) r2z.Result([85]u8, error_1.FromHexError) {
    var out: [85]u8 = [_]u8{ 0 } ** 85;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([85]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([85]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_86(comptime T: type, hex: T) r2z.Result([86]u8, error_1.FromHexError) {
    var out: [86]u8 = [_]u8{ 0 } ** 86;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([86]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([86]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_87(comptime T: type, hex: T) r2z.Result([87]u8, error_1.FromHexError) {
    var out: [87]u8 = [_]u8{ 0 } ** 87;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([87]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([87]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_88(comptime T: type, hex: T) r2z.Result([88]u8, error_1.FromHexError) {
    var out: [88]u8 = [_]u8{ 0 } ** 88;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([88]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([88]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_89(comptime T: type, hex: T) r2z.Result([89]u8, error_1.FromHexError) {
    var out: [89]u8 = [_]u8{ 0 } ** 89;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([89]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([89]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_90(comptime T: type, hex: T) r2z.Result([90]u8, error_1.FromHexError) {
    var out: [90]u8 = [_]u8{ 0 } ** 90;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([90]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([90]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_91(comptime T: type, hex: T) r2z.Result([91]u8, error_1.FromHexError) {
    var out: [91]u8 = [_]u8{ 0 } ** 91;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([91]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([91]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_92(comptime T: type, hex: T) r2z.Result([92]u8, error_1.FromHexError) {
    var out: [92]u8 = [_]u8{ 0 } ** 92;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([92]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([92]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_93(comptime T: type, hex: T) r2z.Result([93]u8, error_1.FromHexError) {
    var out: [93]u8 = [_]u8{ 0 } ** 93;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([93]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([93]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_94(comptime T: type, hex: T) r2z.Result([94]u8, error_1.FromHexError) {
    var out: [94]u8 = [_]u8{ 0 } ** 94;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([94]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([94]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_95(comptime T: type, hex: T) r2z.Result([95]u8, error_1.FromHexError) {
    var out: [95]u8 = [_]u8{ 0 } ** 95;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([95]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([95]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_96(comptime T: type, hex: T) r2z.Result([96]u8, error_1.FromHexError) {
    var out: [96]u8 = [_]u8{ 0 } ** 96;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([96]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([96]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_97(comptime T: type, hex: T) r2z.Result([97]u8, error_1.FromHexError) {
    var out: [97]u8 = [_]u8{ 0 } ** 97;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([97]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([97]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_98(comptime T: type, hex: T) r2z.Result([98]u8, error_1.FromHexError) {
    var out: [98]u8 = [_]u8{ 0 } ** 98;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([98]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([98]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_99(comptime T: type, hex: T) r2z.Result([99]u8, error_1.FromHexError) {
    var out: [99]u8 = [_]u8{ 0 } ** 99;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([99]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([99]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_100(comptime T: type, hex: T) r2z.Result([100]u8, error_1.FromHexError) {
    var out: [100]u8 = [_]u8{ 0 } ** 100;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([100]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([100]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_101(comptime T: type, hex: T) r2z.Result([101]u8, error_1.FromHexError) {
    var out: [101]u8 = [_]u8{ 0 } ** 101;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([101]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([101]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_102(comptime T: type, hex: T) r2z.Result([102]u8, error_1.FromHexError) {
    var out: [102]u8 = [_]u8{ 0 } ** 102;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([102]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([102]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_103(comptime T: type, hex: T) r2z.Result([103]u8, error_1.FromHexError) {
    var out: [103]u8 = [_]u8{ 0 } ** 103;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([103]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([103]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_104(comptime T: type, hex: T) r2z.Result([104]u8, error_1.FromHexError) {
    var out: [104]u8 = [_]u8{ 0 } ** 104;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([104]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([104]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_105(comptime T: type, hex: T) r2z.Result([105]u8, error_1.FromHexError) {
    var out: [105]u8 = [_]u8{ 0 } ** 105;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([105]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([105]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_106(comptime T: type, hex: T) r2z.Result([106]u8, error_1.FromHexError) {
    var out: [106]u8 = [_]u8{ 0 } ** 106;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([106]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([106]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_107(comptime T: type, hex: T) r2z.Result([107]u8, error_1.FromHexError) {
    var out: [107]u8 = [_]u8{ 0 } ** 107;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([107]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([107]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_108(comptime T: type, hex: T) r2z.Result([108]u8, error_1.FromHexError) {
    var out: [108]u8 = [_]u8{ 0 } ** 108;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([108]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([108]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_109(comptime T: type, hex: T) r2z.Result([109]u8, error_1.FromHexError) {
    var out: [109]u8 = [_]u8{ 0 } ** 109;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([109]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([109]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_110(comptime T: type, hex: T) r2z.Result([110]u8, error_1.FromHexError) {
    var out: [110]u8 = [_]u8{ 0 } ** 110;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([110]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([110]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_111(comptime T: type, hex: T) r2z.Result([111]u8, error_1.FromHexError) {
    var out: [111]u8 = [_]u8{ 0 } ** 111;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([111]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([111]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_112(comptime T: type, hex: T) r2z.Result([112]u8, error_1.FromHexError) {
    var out: [112]u8 = [_]u8{ 0 } ** 112;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([112]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([112]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_113(comptime T: type, hex: T) r2z.Result([113]u8, error_1.FromHexError) {
    var out: [113]u8 = [_]u8{ 0 } ** 113;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([113]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([113]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_114(comptime T: type, hex: T) r2z.Result([114]u8, error_1.FromHexError) {
    var out: [114]u8 = [_]u8{ 0 } ** 114;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([114]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([114]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_115(comptime T: type, hex: T) r2z.Result([115]u8, error_1.FromHexError) {
    var out: [115]u8 = [_]u8{ 0 } ** 115;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([115]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([115]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_116(comptime T: type, hex: T) r2z.Result([116]u8, error_1.FromHexError) {
    var out: [116]u8 = [_]u8{ 0 } ** 116;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([116]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([116]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_117(comptime T: type, hex: T) r2z.Result([117]u8, error_1.FromHexError) {
    var out: [117]u8 = [_]u8{ 0 } ** 117;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([117]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([117]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_118(comptime T: type, hex: T) r2z.Result([118]u8, error_1.FromHexError) {
    var out: [118]u8 = [_]u8{ 0 } ** 118;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([118]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([118]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_119(comptime T: type, hex: T) r2z.Result([119]u8, error_1.FromHexError) {
    var out: [119]u8 = [_]u8{ 0 } ** 119;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([119]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([119]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_120(comptime T: type, hex: T) r2z.Result([120]u8, error_1.FromHexError) {
    var out: [120]u8 = [_]u8{ 0 } ** 120;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([120]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([120]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_121(comptime T: type, hex: T) r2z.Result([121]u8, error_1.FromHexError) {
    var out: [121]u8 = [_]u8{ 0 } ** 121;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([121]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([121]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_122(comptime T: type, hex: T) r2z.Result([122]u8, error_1.FromHexError) {
    var out: [122]u8 = [_]u8{ 0 } ** 122;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([122]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([122]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_123(comptime T: type, hex: T) r2z.Result([123]u8, error_1.FromHexError) {
    var out: [123]u8 = [_]u8{ 0 } ** 123;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([123]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([123]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_124(comptime T: type, hex: T) r2z.Result([124]u8, error_1.FromHexError) {
    var out: [124]u8 = [_]u8{ 0 } ** 124;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([124]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([124]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_125(comptime T: type, hex: T) r2z.Result([125]u8, error_1.FromHexError) {
    var out: [125]u8 = [_]u8{ 0 } ** 125;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([125]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([125]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_126(comptime T: type, hex: T) r2z.Result([126]u8, error_1.FromHexError) {
    var out: [126]u8 = [_]u8{ 0 } ** 126;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([126]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([126]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_127(comptime T: type, hex: T) r2z.Result([127]u8, error_1.FromHexError) {
    var out: [127]u8 = [_]u8{ 0 } ** 127;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([127]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([127]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_128(comptime T: type, hex: T) r2z.Result([128]u8, error_1.FromHexError) {
    var out: [128]u8 = [_]u8{ 0 } ** 128;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([128]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([128]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_160(comptime T: type, hex: T) r2z.Result([160]u8, error_1.FromHexError) {
    var out: [160]u8 = [_]u8{ 0 } ** 160;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([160]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([160]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_192(comptime T: type, hex: T) r2z.Result([192]u8, error_1.FromHexError) {
    var out: [192]u8 = [_]u8{ 0 } ** 192;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([192]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([192]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_200(comptime T: type, hex: T) r2z.Result([200]u8, error_1.FromHexError) {
    var out: [200]u8 = [_]u8{ 0 } ** 200;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([200]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([200]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_224(comptime T: type, hex: T) r2z.Result([224]u8, error_1.FromHexError) {
    var out: [224]u8 = [_]u8{ 0 } ** 224;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([224]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([224]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_256(comptime T: type, hex: T) r2z.Result([256]u8, error_1.FromHexError) {
    var out: [256]u8 = [_]u8{ 0 } ** 256;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([256]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([256]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_384(comptime T: type, hex: T) r2z.Result([384]u8, error_1.FromHexError) {
    var out: [384]u8 = [_]u8{ 0 } ** 384;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([384]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([384]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_512(comptime T: type, hex: T) r2z.Result([512]u8, error_1.FromHexError) {
    var out: [512]u8 = [_]u8{ 0 } ** 512;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([512]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([512]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_768(comptime T: type, hex: T) r2z.Result([768]u8, error_1.FromHexError) {
    var out: [768]u8 = [_]u8{ 0 } ** 768;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([768]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([768]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_1024(comptime T: type, hex: T) r2z.Result([1024]u8, error_1.FromHexError) {
    var out: [1024]u8 = [_]u8{ 0 } ** 1024;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([1024]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([1024]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_2048(comptime T: type, hex: T) r2z.Result([2048]u8, error_1.FromHexError) {
    var out: [2048]u8 = [_]u8{ 0 } ** 2048;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([2048]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([2048]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_4096(comptime T: type, hex: T) r2z.Result([4096]u8, error_1.FromHexError) {
    var out: [4096]u8 = [_]u8{ 0 } ** 4096;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([4096]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([4096]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_8192(comptime T: type, hex: T) r2z.Result([8192]u8, error_1.FromHexError) {
    var out: [8192]u8 = [_]u8{ 0 } ** 8192;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([8192]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([8192]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_16384(comptime T: type, hex: T) r2z.Result([16384]u8, error_1.FromHexError) {
    var out: [16384]u8 = [_]u8{ 0 } ** 16384;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([16384]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([16384]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_32768(comptime T: type, hex: T) r2z.Result([32768]u8, error_1.FromHexError) {
    var out: [32768]u8 = [_]u8{ 0 } ** 32768;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([32768]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([32768]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_65536(comptime T: type, hex: T) r2z.Result([65536]u8, error_1.FromHexError) {
    var out: [65536]u8 = [_]u8{ 0 } ** 65536;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([65536]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([65536]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_131072(comptime T: type, hex: T) r2z.Result([131072]u8, error_1.FromHexError) {
    var out: [131072]u8 = [_]u8{ 0 } ** 131072;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([131072]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([131072]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_262144(comptime T: type, hex: T) r2z.Result([262144]u8, error_1.FromHexError) {
    var out: [262144]u8 = [_]u8{ 0 } ** 262144;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([262144]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([262144]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_524288(comptime T: type, hex: T) r2z.Result([524288]u8, error_1.FromHexError) {
    var out: [524288]u8 = [_]u8{ 0 } ** 524288;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([524288]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([524288]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_1048576(comptime T: type, hex: T) r2z.Result([1048576]u8, error_1.FromHexError) {
    var out: [1048576]u8 = [_]u8{ 0 } ** 1048576;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([1048576]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([1048576]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_2097152(comptime T: type, hex: T) r2z.Result([2097152]u8, error_1.FromHexError) {
    var out: [2097152]u8 = [_]u8{ 0 } ** 2097152;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([2097152]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([2097152]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_4194304(comptime T: type, hex: T) r2z.Result([4194304]u8, error_1.FromHexError) {
    var out: [4194304]u8 = [_]u8{ 0 } ** 4194304;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([4194304]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([4194304]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_8388608(comptime T: type, hex: T) r2z.Result([8388608]u8, error_1.FromHexError) {
    var out: [8388608]u8 = [_]u8{ 0 } ** 8388608;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([8388608]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([8388608]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_16777216(comptime T: type, hex: T) r2z.Result([16777216]u8, error_1.FromHexError) {
    var out: [16777216]u8 = [_]u8{ 0 } ** 16777216;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([16777216]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([16777216]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_33554432(comptime T: type, hex: T) r2z.Result([33554432]u8, error_1.FromHexError) {
    var out: [33554432]u8 = [_]u8{ 0 } ** 33554432;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([33554432]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([33554432]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_67108864(comptime T: type, hex: T) r2z.Result([67108864]u8, error_1.FromHexError) {
    var out: [67108864]u8 = [_]u8{ 0 } ** 67108864;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([67108864]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([67108864]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_134217728(comptime T: type, hex: T) r2z.Result([134217728]u8, error_1.FromHexError) {
    var out: [134217728]u8 = [_]u8{ 0 } ** 134217728;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([134217728]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([134217728]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_268435456(comptime T: type, hex: T) r2z.Result([268435456]u8, error_1.FromHexError) {
    var out: [268435456]u8 = [_]u8{ 0 } ** 268435456;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([268435456]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([268435456]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_536870912(comptime T: type, hex: T) r2z.Result([536870912]u8, error_1.FromHexError) {
    var out: [536870912]u8 = [_]u8{ 0 } ** 536870912;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([536870912]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([536870912]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_1073741824(comptime T: type, hex: T) r2z.Result([1073741824]u8, error_1.FromHexError) {
    var out: [1073741824]u8 = [_]u8{ 0 } ** 1073741824;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([1073741824]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([1073741824]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_2147483648(comptime T: type, hex: T) r2z.Result([2147483648]u8, error_1.FromHexError) {
    var out: [2147483648]u8 = [_]u8{ 0 } ** 2147483648;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([2147483648]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([2147483648]u8, error_1.FromHexError){ .Ok = out };
}

pub fn from_hex__u8_4294967296(comptime T: type, hex: T) r2z.Result([4294967296]u8, error_1.FromHexError) {
    var out: [4294967296]u8 = [_]u8{ 0 } ** 4294967296;
    switch (decode_to_slice(T, hex, @as([]u8, &out))) {
        .Ok => @as(void, {}),
        .Err => |__r2z_try_err| return r2z.Result([4294967296]u8, error_1.FromHexError){ .Err = __r2z_try_err },
    }
    return r2z.Result([4294967296]u8, error_1.FromHexError){ .Ok = out };
}

test "translated tests reachable through ./test.zig" {
    _ = @"test";
}
