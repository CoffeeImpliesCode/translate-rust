const std = @import("std");
const r2z = @import("r2z");

pub fn cast(value: u32) u8 {
    return @as(u8, @truncate(value));
}

pub fn digit(value: u21) ?u32 {
    return r2z.character.to_digit(value, 16);
}

pub fn narrow(value: u16) ?u8 {
    return r2z.convert.try_from(u8, value).ok();
}

pub fn root_value() u32 {
    return 5;
}

pub fn width() usize {
    return r2z.memory.size_of(u32);
}

pub fn bits(value: f32) u32 {
    return __r2z_value_block_1: {
        break :__r2z_value_block_1 r2z.memory.transmute(f32, u32)(value);
    };
}

pub fn bits_callable(value: f32) u32 {
    const convert: *const fn (f32) u32 = r2z.memory.transmute(f32, u32);
    return __r2z_value_block_1: {
        break :__r2z_value_block_1 convert(value);
    };
}

pub fn pointer_cast(value: [*]align(1) const u8) [*]align(1) u8 {
    return @as([*]align(1) u8, @ptrCast(@constCast(value)));
}

pub fn render(f: *std.Io.Writer) std.Io.Writer.Error!void {
    return r2z.format.write(f, "value={} {:?}", .{ @as(u32, 42), @as(u21, '\n') });
}

pub fn owned(allocator: std.mem.Allocator, input: []const u8) !r2z.alloc.String {
    return try r2z.alloc.String.from_str(allocator, input);
}

pub fn lossy(allocator: std.mem.Allocator, input: []const u8) !r2z.alloc.CowStr {
    return try r2z.alloc.String.from_utf8_lossy(allocator, input);
}

pub fn borrowed_bytes(input: []const u8) r2z.alloc.CowSlice(u8) {
    return r2z.alloc.CowSlice(u8){ .Borrowed = input };
}

pub fn sum(input: []const u32) u32 {
    var __r2z_sum: u32 = 0;
    for (input) |__r2z_item| {
        {
            const x = __r2z_item;
            const __r2z_item_value = x *% 2;
            {
                const x_1 = &__r2z_item_value;
                if (x_1.* > 4) {
                    __r2z_sum += __r2z_item_value;
                }
            }
        }
    }
    return __r2z_sum;
}

pub fn generic_narrow(comptime T: type, value: T) ?u8 {
    return r2z.convert.try_from(u8, value).ok();
}

pub fn byte_sum(input: []const u8) u32 {
    var sum_1: u32 = 0;
    for (input) |byte| {
        sum_1 += @as(u32, byte);
    }
    return sum_1;
}

pub fn collected(allocator: std.mem.Allocator, input: []const u32) !std.ArrayListUnmanaged(u32) {
    var __r2z_owner: std.ArrayListUnmanaged(u32) = std.ArrayListUnmanaged(u32).empty;
    errdefer __r2z_owner.deinit(allocator);
    for (input) |__r2z_item| {
        {
            const x = __r2z_item;
            const __r2z_item_value = x *% 2;
            {
                const x_1 = &__r2z_item_value;
                if (x_1.* > 4) {
                    try __r2z_owner.append(allocator, __r2z_item_value);
                }
            }
        }
    }
    return __r2z_owner;
}

pub fn owner(allocator: std.mem.Allocator, owner_1: []const u8) !std.ArrayListUnmanaged(u8) {
    var owner_2: std.ArrayListUnmanaged(u8) = std.ArrayListUnmanaged(u8).empty;
    errdefer owner_2.deinit(allocator);
    const __r2z_range_start: i32 = 0;
    const __r2z_range_end: i32 = 2;
    var __r2z_range_cursor: i32 = __r2z_range_start;
    while (__r2z_range_cursor < __r2z_range_end) : ({
        __r2z_range_cursor += 1;
    }) {
        for (owner_1) |_byte| {
            try owner_2.append(allocator, _byte);
        }
    }
    return owner_2;
}

pub fn flattened(allocator: std.mem.Allocator) !std.ArrayListUnmanaged(u32) {
    var __r2z_owner: std.ArrayListUnmanaged(u32) = std.ArrayListUnmanaged(u32).empty;
    errdefer __r2z_owner.deinit(allocator);
    const __r2z_range_start: u32 = 0;
    const __r2z_range_end: u32 = 3;
    var __r2z_range_cursor: u32 = __r2z_range_start;
    while (__r2z_range_cursor < __r2z_range_end) : ({
        __r2z_range_cursor += 1;
    }) {
        {
            const x = __r2z_range_cursor;
            const __r2z_range_start_1: u32 = x;
            const __r2z_range_end_1: u32 = x +% 2;
            var __r2z_range_cursor_1: u32 = __r2z_range_start_1;
            while (__r2z_range_cursor_1 < __r2z_range_end_1) : ({
                __r2z_range_cursor_1 += 1;
            }) {
                try __r2z_owner.append(allocator, __r2z_range_cursor_1);
            }
        }
    }
    return __r2z_owner;
}

pub fn stateful_flattened(allocator: std.mem.Allocator) !std.ArrayListUnmanaged(u32) {
    const end: u32 = 0;
    return __r2z_value_block_1: {
        var __r2z_owner: std.ArrayListUnmanaged(u32) = std.ArrayListUnmanaged(u32).empty;
        errdefer __r2z_owner.deinit(allocator);
        const __r2z_range_start: u32 = 0;
        const __r2z_range_end: u32 = 3;
        var __r2z_range_cursor: u32 = __r2z_range_start;
        var __r2z_capture_iter_0_end = end;
        while (__r2z_range_cursor < __r2z_range_end) : ({
            __r2z_range_cursor += 1;
        }) {
            {
                const x = __r2z_range_cursor;
                __r2z_capture_iter_0_end += 1;
                const __r2z_range_start_1: u32 = x;
                const __r2z_range_end_1: u32 = __r2z_capture_iter_0_end;
                var __r2z_range_cursor_1: u32 = __r2z_range_start_1;
                while (__r2z_range_cursor_1 < __r2z_range_end_1) : ({
                    __r2z_range_cursor_1 += 1;
                }) {
                    try __r2z_owner.append(allocator, __r2z_range_cursor_1);
                }
            }
        }
        break :__r2z_value_block_1 __r2z_owner;
    };
}

pub fn reversed(allocator: std.mem.Allocator, end: u32) !std.ArrayListUnmanaged(u32) {
    var __r2z_owner: std.ArrayListUnmanaged(u32) = std.ArrayListUnmanaged(u32).empty;
    errdefer __r2z_owner.deinit(allocator);
    const __r2z_range_start: u32 = 0;
    const __r2z_range_end: u32 = end;
    var __r2z_range_cursor: u32 = __r2z_range_end;
    while (__r2z_range_cursor > __r2z_range_start) {
        __r2z_range_cursor -= 1;
        try __r2z_owner.append(allocator, __r2z_range_cursor);
    }
    return __r2z_owner;
}

pub fn signed_flattened(allocator: std.mem.Allocator) !std.ArrayListUnmanaged(i32) {
    var __r2z_owner: std.ArrayListUnmanaged(i32) = std.ArrayListUnmanaged(i32).empty;
    errdefer __r2z_owner.deinit(allocator);
    const __r2z_range_start: i32 = -1;
    const __r2z_range_end: i32 = 1;
    var __r2z_range_cursor: i32 = __r2z_range_start;
    while (__r2z_range_cursor < __r2z_range_end) : ({
        __r2z_range_cursor += 1;
    }) {
        {
            const x = __r2z_range_cursor;
            const __r2z_range_start_1: i32 = x;
            const __r2z_range_end_1: i32 = x +% 1;
            var __r2z_range_cursor_1: i32 = __r2z_range_start_1;
            var __r2z_range_done: bool = false;
            while (__r2z_range_cursor_1 <= __r2z_range_end_1 and !__r2z_range_done) : (if (!__r2z_range_done) {
                __r2z_range_cursor_1 += 1;
            } else @as(void, {})) {
                __r2z_range_done = __r2z_range_cursor_1 == __r2z_range_end_1;
                try __r2z_owner.append(allocator, __r2z_range_cursor_1);
            }
        }
    }
    return __r2z_owner;
}

pub fn signed_range_sum(start: i32, end: i32) i32 {
    var __r2z_sum: i32 = 0;
    const __r2z_range_start: i32 = start;
    const __r2z_range_end: i32 = end;
    var __r2z_range_cursor: i32 = __r2z_range_start;
    while (__r2z_range_cursor < __r2z_range_end) : ({
        __r2z_range_cursor += 1;
    }) {
        {
            const x = __r2z_range_cursor;
            const __r2z_item_value = x *% 2;
            __r2z_sum += __r2z_item_value;
        }
    }
    return __r2z_sum;
}

pub fn inclusive_range_sum(start: u8, end: u8) u32 {
    var __r2z_sum: u32 = 0;
    const __r2z_range_start: u8 = start;
    const __r2z_range_end: u8 = end;
    var __r2z_range_cursor: u8 = __r2z_range_start;
    var __r2z_range_done: bool = false;
    while (__r2z_range_cursor <= __r2z_range_end and !__r2z_range_done) : (if (!__r2z_range_done) {
        __r2z_range_cursor += 1;
    } else @as(void, {})) {
        __r2z_range_done = __r2z_range_cursor == __r2z_range_end;
        {
            const x = __r2z_range_cursor;
            const __r2z_item_value = @as(u32, x);
            __r2z_sum += __r2z_item_value;
        }
    }
    return __r2z_sum;
}

pub fn reverse_range_fold(start: u8, end: u8) u32 {
    var result: u32 = 0;
    {
        const __r2z_range_start: u8 = start;
        const __r2z_range_end: u8 = end;
        var __r2z_range_cursor: u8 = __r2z_range_end;
        var __r2z_range_done: bool = false;
        while (__r2z_range_cursor >= __r2z_range_start and !__r2z_range_done) : (if (!__r2z_range_done) {
            __r2z_range_cursor -= 1;
        } else @as(void, {})) {
            __r2z_range_done = __r2z_range_cursor == __r2z_range_start;
            const value = __r2z_range_cursor;
            result = result *% 10 +% @as(u32, value);
        }
    }
    return result;
}

pub fn continued_range_sum(end: u8) u32 {
    var result: u32 = 0;
    {
        const __r2z_range_start: u8 = 0;
        const __r2z_range_end: u8 = end;
        var __r2z_range_cursor: u8 = __r2z_range_start;
        var __r2z_range_done: bool = false;
        while (__r2z_range_cursor <= __r2z_range_end and !__r2z_range_done) : (if (!__r2z_range_done) {
            __r2z_range_cursor += 1;
        } else @as(void, {})) {
            __r2z_range_done = __r2z_range_cursor == __r2z_range_end;
            {
                const x = __r2z_range_cursor;
                const __r2z_item_value = x;
                const value = __r2z_item_value;
                if (value == end) {
                    continue;
                }
                result += @as(u32, value);
            }
        }
    }
    return result;
}

pub fn indexed_sum(input: []const u32) u32 {
    var __r2z_sum: u32 = 0;
    var __r2z_enumerate_index_0: usize = 0;
    for (input) |__r2z_item| {
        {
            const __r2z_enumerate_item_0 = .{ __r2z_enumerate_index_0, __r2z_item };
            __r2z_enumerate_index_0 += 1;
            {
                const __r2z_tuple = __r2z_enumerate_item_0;
                const index = __r2z_tuple[0];
                const value = __r2z_tuple[1];
                const __r2z_item_value = @as(u32, @truncate(index)) +% value;
                __r2z_sum += __r2z_item_value;
            }
        }
    }
    return __r2z_sum;
}

pub fn zipped_sum(left: []const u32, right: []const u32) u32 {
    var __r2z_sum: u32 = 0;
    const __r2z_zip_right_0 = right;
    var __r2z_zip_index_0: usize = 0;
    for (left) |__r2z_item| {
        if (__r2z_zip_index_0 < __r2z_zip_right_0.len) {
            const __r2z_zip_item_0 = .{ __r2z_item, __r2z_zip_right_0[__r2z_zip_index_0] };
            __r2z_zip_index_0 += 1;
            {
                const __r2z_tuple = __r2z_zip_item_0;
                const a = __r2z_tuple[0];
                const b = __r2z_tuple[1];
                const __r2z_item_value = a *% b;
                __r2z_sum += __r2z_item_value;
            }
        }
    }
    return __r2z_sum;
}

pub fn apply_capture(base: u32, value: u32) u32 {
    return __r2z_value_block_1: {
        const x = value;
        break :__r2z_value_block_1 x +% base;
    };
}

pub fn apply_move_capture(base: u32, value: u32) u32 {
    var captured: u32 = base;
    const __r2z_capture_add_captured = captured;
    captured = 20;
    return (__r2z_value_block_1: {
        const x = value;
        break :__r2z_value_block_1 x +% __r2z_capture_add_captured;
    }) +% captured;
}

pub fn apply_mut_capture(base: u32, value: u32) u32 {
    var total_1: u32 = base;
    _ = __r2z_value_block_1: {
        const x = value;
        break :__r2z_value_block_1 __r2z_value_block_2: {
            total_1 += x;
            break :__r2z_value_block_2 total_1;
        };
    };
    return __r2z_value_block_1: {
        const x = value;
        break :__r2z_value_block_1 __r2z_value_block_2: {
            total_1 += x;
            break :__r2z_value_block_2 total_1;
        };
    };
}

pub fn apply_mut_move_capture(base: u32, value: u32) u32 {
    var captured: u32 = base;
    var __r2z_capture_add_captured = captured;
    _ = __r2z_value_block_1: {
        const x = value;
        break :__r2z_value_block_1 __r2z_value_block_2: {
            __r2z_capture_add_captured += x;
            break :__r2z_value_block_2 __r2z_capture_add_captured;
        };
    };
    return __r2z_value_block_1: {
        const x = value;
        break :__r2z_value_block_1 __r2z_value_block_2: {
            __r2z_capture_add_captured += x;
            break :__r2z_value_block_2 __r2z_capture_add_captured;
        };
    };
}

pub fn borrowed_sum(input: []const u32) u32 {
    var __r2z_sum: u32 = 0;
    for (input[0..]) |*__r2z_item| {
        {
            const x = __r2z_item;
            const __r2z_item_value = x.* +% 1;
            __r2z_sum += __r2z_item_value;
        }
    }
    return __r2z_sum;
}

pub fn increment_sum(input: []u32) u32 {
    var __r2z_sum: u32 = 0;
    for (input[0..]) |*__r2z_item| {
        {
            const x = __r2z_item;
            const __r2z_item_value = __r2z_value_block_3: {
                x.* += 1;
                break :__r2z_value_block_3 x.*;
            };
            __r2z_sum += __r2z_item_value;
        }
    }
    return __r2z_sum;
}

pub fn filtered_index_sum(input: []const u32) u32 {
    var __r2z_sum: u32 = 0;
    var __r2z_enumerate_index_1: usize = 0;
    for (input) |__r2z_item| {
        {
            const x = &__r2z_item;
            if (x.* % 2 == 0) {
                {
                    const __r2z_enumerate_item_1 = .{ __r2z_enumerate_index_1, __r2z_item };
                    __r2z_enumerate_index_1 += 1;
                    {
                        const __r2z_tuple = __r2z_enumerate_item_1;
                        const index = __r2z_tuple[0];
                        const value = __r2z_tuple[1];
                        const __r2z_item_value = @as(u32, @truncate(index)) *% 100 +% value;
                        __r2z_sum += __r2z_item_value;
                    }
                }
            }
        }
    }
    return __r2z_sum;
}

pub fn filtered_zip_sum(left: []const u32, right: []const u32) u32 {
    var __r2z_sum: u32 = 0;
    const __r2z_zip_right_1 = right;
    var __r2z_zip_index_1: usize = 0;
    for (left) |__r2z_item| {
        {
            const x = &__r2z_item;
            if (x.* % 2 == 0) {
                if (__r2z_zip_index_1 < __r2z_zip_right_1.len) {
                    const __r2z_zip_item_1 = .{ __r2z_item, __r2z_zip_right_1[__r2z_zip_index_1] };
                    __r2z_zip_index_1 += 1;
                    {
                        const __r2z_tuple = __r2z_zip_item_1;
                        const a = __r2z_tuple[0];
                        const b = __r2z_tuple[1];
                        const __r2z_item_value = a *% b;
                        __r2z_sum += __r2z_item_value;
                    }
                }
            }
        }
    }
    return __r2z_sum;
}

pub fn for_adapter_sum(input: []const u32, offset: u32) u32 {
    var total_1: u32 = 0;
    {
        for (input) |__r2z_item| {
            {
                const x = __r2z_item;
                const __r2z_item_value = x +% offset;
                {
                    const x_1 = &__r2z_item_value;
                    if (x_1.* > 4) {
                        const value = __r2z_item_value;
                        total_1 += value;
                    }
                }
            }
        }
    }
    return total_1;
}

pub fn moved_adapter_sum(input: []const u32, base: u32) u32 {
    const running: u32 = base;
    const result: u32 = __r2z_value_block_1: {
        var __r2z_sum: u32 = 0;
        var __r2z_capture_iter_0_running = running;
        for (input) |__r2z_item| {
            {
                const x = __r2z_item;
                const __r2z_item_value = __r2z_value_block_4: {
                    __r2z_capture_iter_0_running += x;
                    break :__r2z_value_block_4 __r2z_capture_iter_0_running;
                };
                __r2z_sum += __r2z_item_value;
            }
        }
        break :__r2z_value_block_1 __r2z_sum;
    };
    return result +% running;
}

pub fn counted_filter_sum(input: []const u32) u32 {
    var calls: u32 = 0;
    const total_1: u32 = __r2z_value_block_1: {
        var __r2z_sum: u32 = 0;
        for (input) |__r2z_item| {
            {
                const x = __r2z_item;
                const __r2z_item_value = __r2z_value_block_4: {
                    calls += 1;
                    break :__r2z_value_block_4 x;
                };
                {
                    const x_1 = (&__r2z_item_value).*;
                    if (x_1 % 2 == 0) {
                        __r2z_sum += __r2z_item_value;
                    }
                }
            }
        }
        break :__r2z_value_block_1 __r2z_sum;
    };
    return total_1 +% calls *% 100;
}

pub const OptionalValue = struct {
    const Self = @This();

    value: ?u8,

    pub fn consume(self: *OptionalValue) u8 {
        return __r2z_value_block_2: {
            const __r2z_option_match = __r2z_value_block_3: {
                const __r2z_option_take_582: ?u8 = self.value;
                self.value = null;
                break :__r2z_value_block_3 __r2z_option_take_582;
            };
            break :__r2z_value_block_2 switch (__r2z_option_match != null) {
                true => __r2z_value_block_4: {
                    const value = r2z.option.unwrap(__r2z_option_match);
                    break :__r2z_value_block_4 value;
                },
                false => 0,
            };
        };
    }
};

pub const support = @import("./support.zig");

pub const child = @import("./support/child.zig");

test "numeric_check" {
    try std.testing.expect(cast(511) == 255);
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, digit('f'), @as(?u32, 15)));
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, narrow(255), @as(?u8, 255)));
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, narrow(256), @as(?u8, null)));
}

test "module_reference_check" {
    try std.testing.expect(child.total() == 26);
}

test "memory_check" {
    try std.testing.expect(width() == 4);
    try std.testing.expect(bits(1.0) == 1065353216);
    try std.testing.expect(bits_callable(1.0) == 1065353216);
}

test "iterator_check" {
    try std.testing.expect(sum(&[_]u32{ 1, 2, 3, 4 }) == 14);
}

test "generic_check" {
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, generic_narrow(u16, 255), @as(?u8, 255)));
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, generic_narrow(u16, 256), @as(?u8, null)));
}

test "slice_value_check" {
    try std.testing.expect(byte_sum(&[_]u8{ 1, 127, 255 }) == 383);
    try std.testing.expect(byte_sum(&[_]u8{}) == 0);
}

test "range_boundaries_check" {
    try std.testing.expect(signed_range_sum(-2, 2) == -4);
    try std.testing.expect(inclusive_range_sum(254, 255) == 509);
    try std.testing.expect(reverse_range_fold(254, 255) == 2804);
    try std.testing.expect(reverse_range_fold(255, 254) == 0);
    try std.testing.expect(continued_range_sum(255) == 32385);
}

test "adapter_boundaries_check" {
    try std.testing.expect(indexed_sum(&[_]u32{ 10, 20, 30 }) == 63);
    try std.testing.expect(indexed_sum(&[_]u32{}) == 0);
    try std.testing.expect(borrowed_sum(&[_]u32{ 1, 3 }) == 6);
    try std.testing.expect(zipped_sum(&[_]u32{ 2, 3, 99 }, &[_]u32{ 4, 5 }) == 23);
    try std.testing.expect(zipped_sum(&[_]u32{}, &[_]u32{ 4, 5 }) == 0);
    try std.testing.expect(zipped_sum(&[_]u32{ 4, 5 }, &[_]u32{}) == 0);
    try std.testing.expect(filtered_index_sum(&[_]u32{ 1, 2, 3, 4 }) == 106);
    try std.testing.expect(filtered_zip_sum(&[_]u32{ 1, 2, 3, 4 }, &[_]u32{ 10, 20, 30 }) == 100);
    try std.testing.expect(for_adapter_sum(&[_]u32{ 1, 2, 3, 4 }, 2) == 11);
    try std.testing.expect(moved_adapter_sum(&[_]u32{ 2, 3 }, 1) == 10);
    try std.testing.expect(counted_filter_sum(&[_]u32{ 1, 2, 3 }) == 302);
}

test "closure_capture_check" {
    try std.testing.expect(apply_capture(7, 3) == 10);
    try std.testing.expect(apply_move_capture(7, 3) == 30);
    try std.testing.expect(apply_mut_capture(7, 3) == 13);
    try std.testing.expect(apply_mut_move_capture(7, 3) == 13);
}

test "option_take_check" {
    var state: OptionalValue = OptionalValue{ .value = @as(?u8, 7) };
    try std.testing.expect(state.consume() == 7);
    try std.testing.expect(state.consume() == 0);
}

test "translated tests reachable through ./support.zig" {
    _ = support;
}

test "translated tests reachable through ./support/child.zig" {
    _ = child;
}
