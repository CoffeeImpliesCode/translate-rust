const std = @import("std");
fn pointer_info(comptime Ptr: type) std.builtin.Type.Pointer {
    return switch (@typeInfo(Ptr)) {
        .pointer => |info| info,
        else => @compileError("expected a pointer type, found " ++ @typeName(Ptr)),
    };
}

fn require_many_pointer(comptime Ptr: type, comptime T: type) std.builtin.Type.Pointer {
    const info = pointer_info(Ptr);
    if (info.size != .many) {
        @compileError("expected a many-item pointer, found " ++ @typeName(Ptr));
    }
    if (info.child != T) {
        @compileError("pointer child does not match " ++ @typeName(T));
    }
    return info;
}

fn require_pointer(comptime Ptr: type, comptime T: type) std.builtin.Type.Pointer {
    const info = pointer_info(Ptr);
    if (info.child != T) {
        @compileError("pointer child does not match " ++ @typeName(T));
    }
    return info;
}

const max_isize_value: usize = @intCast(std.math.maxInt(isize));

fn checked_byte_extent(comptime T: type, element_count: usize) usize {
    const result = @mulWithOverflow(element_count, @sizeOf(T));
    std.debug.assert(result[1] == 0);
    const byte_extent = result[0];
    std.debug.assert(byte_extent <= max_isize_value);
    return byte_extent;
}

fn checked_address_add(address: usize, byte_offset: usize) usize {
    const result = @addWithOverflow(address, byte_offset);
    std.debug.assert(result[1] == 0);
    return result[0];
}

fn checked_address_sub(address: usize, byte_offset: usize) usize {
    const result = @subWithOverflow(address, byte_offset);
    std.debug.assert(result[1] == 0);
    return result[0];
}

fn checked_element_size(comptime T: type) isize {
    if (comptime @sizeOf(T) > max_isize_value) {
        @compileError("element size does not fit in isize");
    }
    return @intCast(@sizeOf(T));
}

fn checked_signed_address_offset(address: usize, byte_offset: isize) usize {
    if (byte_offset >= 0) {
        return checked_address_add(address, @intCast(byte_offset));
    }
    const magnitude: usize = @as(usize, @intCast(-(byte_offset + 1))) + 1;
    return checked_address_sub(address, magnitude);
}

fn raw_pointer_type(comptime Ptr: type) type {
    const info = pointer_info(Ptr);
    return @Pointer(.many, .{
        .@"const" = info.is_const,
        .@"volatile" = info.is_volatile,
        .@"allowzero" = info.is_allowzero,
        .@"align" = @min(info.alignment orelse @alignOf(info.child), @alignOf(info.child)),
        .@"addrspace" = info.address_space,
    }, info.child, info.sentinel());
}

fn unaligned_pointer_type(comptime Ptr: type, comptime T: type) type {
    const info = require_pointer(Ptr, T);
    return @Pointer(.one, .{
        .@"const" = true,
        .@"volatile" = info.is_volatile,
        .@"allowzero" = info.is_allowzero,
        .@"align" = 1,
        .@"addrspace" = info.address_space,
    }, T, null);
}

fn immutable_slice_type(comptime Ptr: type, comptime T: type) type {
    const info = require_many_pointer(Ptr, T);
    return @Pointer(.slice, .{
        .@"const" = true,
        .@"volatile" = info.is_volatile,
        .@"allowzero" = info.is_allowzero,
        .@"align" = info.alignment,
        .@"addrspace" = info.address_space,
    }, T, null);
}

fn mutable_slice_type(comptime Ptr: type, comptime T: type) type {
    const info = require_many_pointer(Ptr, T);
    if (info.is_const) {
        @compileError("mutable raw slice requires a mutable pointer");
    }
    return @Pointer(.slice, .{
        .@"const" = false,
        .@"volatile" = info.is_volatile,
        .@"allowzero" = info.is_allowzero,
        .@"align" = info.alignment,
        .@"addrspace" = info.address_space,
    }, T, null);
}

pub inline fn size_of(comptime T: type) usize {
    return @sizeOf(T);
}

pub inline fn size_of_val(comptime T: type, value: anytype) usize {
    switch (@typeInfo(@TypeOf(value))) {
        .pointer => |pointer| {
            if (pointer.size == .slice) return value.len * @sizeOf(pointer.child);
        },
        else => {},
    }
    return @sizeOf(T);
}

/// Instantiate Rust's size-checked bitwise move. The result bits must be valid for `To`.
pub fn transmute(comptime From: type, comptime To: type) fn (From) To {
    if (@sizeOf(From) != @sizeOf(To)) {
        @compileError("transmute requires source and destination of equal size");
    }
    return struct {
        fn convert(value: From) To {
            const Source = if (From == bool) u8 else if (From == u21) u32 else From;
            const Destination = if (To == bool) u8 else if (To == u21) u32 else To;
            const source: Source = if (From == bool) @intFromBool(value) else if (From == u21) @intCast(value) else value;
            var destination: Destination = undefined;
            @memcpy(std.mem.asBytes(&destination), std.mem.asBytes(&source));
            if (To == bool) {
                std.debug.assert(destination <= 1);
                return destination == 1;
            }
            if (To == u21) return @intCast(destination);
            return destination;
        }
    }.convert;
}

/// Return `ptr` advanced by `element_count` elements.
pub inline fn add(
    comptime T: type,
    ptr: anytype,
    element_count: usize,
) raw_pointer_type(@TypeOf(ptr)) {
    _ = require_many_pointer(@TypeOf(ptr), T);
    const byte_extent = checked_byte_extent(T, element_count);
    const address = checked_address_add(@intFromPtr(ptr), byte_extent);
    return @ptrFromInt(address);
}

/// Return `ptr` moved backward by `element_count` elements.
pub inline fn sub(
    comptime T: type,
    ptr: anytype,
    element_count: usize,
) raw_pointer_type(@TypeOf(ptr)) {
    _ = require_many_pointer(@TypeOf(ptr), T);
    const byte_extent = checked_byte_extent(T, element_count);
    const address = checked_address_sub(@intFromPtr(ptr), byte_extent);
    return @ptrFromInt(address);
}

/// Return `ptr` advanced by a signed number of elements.
pub inline fn offset(
    comptime T: type,
    ptr: anytype,
    element_offset: isize,
) raw_pointer_type(@TypeOf(ptr)) {
    _ = require_many_pointer(@TypeOf(ptr), T);
    const byte_offset_result = @mulWithOverflow(element_offset, checked_element_size(T));
    std.debug.assert(byte_offset_result[1] == 0);
    const address = checked_signed_address_offset(@intFromPtr(ptr), byte_offset_result[0]);
    return @ptrFromInt(address);
}

/// Read `T` from `ptr` without requiring natural alignment.
pub inline fn read_unaligned(comptime T: type, ptr: anytype) T {
    const value_ptr: unaligned_pointer_type(@TypeOf(ptr), T) = @ptrCast(ptr);
    return value_ptr.*;
}

/// Copy `element_count` elements from `source` to `destination` without overlap.
pub inline fn copy_nonoverlapping(
    comptime T: type,
    source: anytype,
    destination: anytype,
    element_count: usize,
) void {
    const source_info = require_many_pointer(@TypeOf(source), T);
    const destination_info = require_many_pointer(@TypeOf(destination), T);
    if (destination_info.is_const) {
        @compileError("copy destination requires a mutable pointer");
    }
    _ = source_info;
    const byte_extent = checked_byte_extent(T, element_count);
    if (byte_extent == 0) return;
    const source_bytes: [*]const u8 = @ptrCast(source);
    const destination_bytes: [*]u8 = @ptrCast(destination);
    @memcpy(destination_bytes[0..byte_extent], source_bytes[0..byte_extent]);
}

/// Fill `element_count` elements with the byte value `value`.
pub inline fn write_bytes(
    comptime T: type,
    destination: anytype,
    value: u8,
    element_count: usize,
) void {
    const destination_info = require_many_pointer(@TypeOf(destination), T);
    if (destination_info.is_const) {
        @compileError("write destination requires a mutable pointer");
    }
    const byte_extent = checked_byte_extent(T, element_count);
    if (byte_extent == 0) return;
    const destination_bytes: [*]u8 = @ptrCast(destination);
    @memset(destination_bytes[0..byte_extent], value);
}

/// Construct an immutable slice over `length` elements at `ptr`.
pub fn from_raw_parts(
    comptime T: type,
    ptr: anytype,
    length: usize,
) immutable_slice_type(@TypeOf(ptr), T) {
    _ = require_many_pointer(@TypeOf(ptr), T);
    _ = checked_byte_extent(T, length);
    return ptr[0..length];
}

/// Construct a mutable slice over `length` elements at `ptr`.
pub fn from_raw_parts_mut(
    comptime T: type,
    ptr: anytype,
    length: usize,
) mutable_slice_type(@TypeOf(ptr), T) {
    _ = require_many_pointer(@TypeOf(ptr), T);
    _ = checked_byte_extent(T, length);
    return ptr[0..length];
}

test "read_unaligned loads a value from a misaligned address" {
    const expected: u32 = 0x1234_5678;
    var storage: [@sizeOf(u32) + 1]u8 = undefined;
    @memcpy(storage[1..], std.mem.asBytes(&expected));

    const pointer: [*]align(1) const u32 = @ptrCast(&storage[1]);
    try std.testing.expectEqual(expected, read_unaligned(u32, pointer));
}

test "copy_nonoverlapping and write_bytes use element byte extents" {
    const source = [_]u32{ 0x0102_0304, 0x1112_1314 };
    var destination = [_]u32{ 0, 0, 0xfeed_beef };
    copy_nonoverlapping(u32, source[0..].ptr, destination[0..].ptr, source.len);
    try std.testing.expectEqualSlices(u32, &source, destination[0..source.len]);
    try std.testing.expectEqual(@as(u32, 0xfeed_beef), destination[2]);

    write_bytes(u32, destination[0..].ptr, 0xa5, 2);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5 },
        std.mem.sliceAsBytes(destination[0..2]),
    );
    try std.testing.expectEqual(@as(u32, 0xfeed_beef), destination[2]);
}

test "add and offset support positive and negative element offsets" {
    var values align(16) = [_]u32{ 10, 20, 30, 40 };
    const base: [*]align(16) u32 = @ptrCast(&values);
    const third = add(u32, base, 2);
    const second = offset(u32, third, -1);
    const fourth = offset(u32, second, 2);

    try std.testing.expectEqual(@as(u32, 30), third[0]);
    try std.testing.expectEqual(@as(u32, 20), second[0]);
    try std.testing.expectEqual(@as(u32, 40), fourth[0]);

    const const_base: [*]align(16) const u32 = base;
    const const_result = offset(u32, const_base, 1);
    const result_info = @typeInfo(@TypeOf(const_result)).pointer;
    try std.testing.expect(result_info.is_const);
    try std.testing.expectEqual(@as(u32, 20), const_result[0]);
}

test "raw slice constructors preserve length and mutability" {
    var values = [_]u16{ 3, 5, 8, 13 };
    const immutable = from_raw_parts(u16, @as([*]const u16, values[0..].ptr), 3);
    try std.testing.expectEqualSlices(u16, &.{ 3, 5, 8 }, immutable);
    try std.testing.expect(@typeInfo(@TypeOf(immutable)).pointer.is_const);

    const mutable = from_raw_parts_mut(u16, values[0..].ptr, values.len);
    mutable[1] = 21;
    try std.testing.expectEqual(@as(u16, 21), values[1]);
    try std.testing.expect(!@typeInfo(@TypeOf(mutable)).pointer.is_const);

    const empty = from_raw_parts(u16, @as([*]const u16, values[0..].ptr), 0);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "size_of_val distinguishes slice contents from a borrowed slice descriptor" {
    const values = [_]u16{ 1, 2, 3 };
    const slice: []const u16 = &values;
    try std.testing.expectEqual(@as(usize, 6), size_of([3]u16));
    try std.testing.expectEqual(@as(usize, 6), size_of_val([3]u16, &values));
    try std.testing.expectEqual(@as(usize, 6), size_of_val([]const u16, slice));
    try std.testing.expectEqual(@sizeOf([]const u16), size_of_val([]const u16, &slice));
}

test "transmute function items preserve bytes and Rust scalar representations" {
    const byte = transmute([1]u8, u8);
    try std.testing.expectEqual(@as(u8, 0xa5), byte(.{0xa5}));
    try std.testing.expectEqual(@as(u8, 1), transmute(bool, u8)(true));
    try std.testing.expectEqual(@as(u32, 0x1f980), transmute(u21, u32)(0x1f980));
    const negative: i32 = -12345;
    const bits = transmute(i32, u32)(negative);
    try std.testing.expectEqual(negative, transmute(u32, i32)(bits));
}
