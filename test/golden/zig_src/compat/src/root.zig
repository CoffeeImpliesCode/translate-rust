//! Zig translation of Rust crate `compat`, module `crate root`.
//!
//! Zig consumer contract:
//! Import the registered `compat` module through a build dependency; child
//! modules are reached through the crate's exported namespaces.
//! Requires Zig 0.16.0. Target and optimization options belong to the consumer.
//! Rust names are preserved except native protocol hooks and name collisions.
//! Zig field access and value copying do not enforce Rust privacy or moves.
//! Pointers, slices and erased interfaces borrow their backing storage.
//! Release returned owned runtime storage with its creating allocator;
//! assignment is not a deep clone and does not create a second cleanup owner.
//! This package does not supply a borrow checker or a process-wide allocator.
//!
//! ```zig
//! const library = @import("compat");
//! ```

const std = @import("std");
const r2z = @import("r2z");

/// Runs the translated Rust operation `cast`.
pub fn cast(value: u32) u8 {
    return @as(u8, @truncate(value));
}

/// Runs the translated Rust operation `digit`.
pub fn digit(value: u21) ?u32 {
    return r2z.character.to_digit(value, 16);
}

/// Runs the translated Rust operation `narrow`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
///
pub fn narrow(allocator: std.mem.Allocator, value: u16) ?u8 {
    return r2z.convert.try_from(u8, value).ok(allocator);
}

/// Runs the translated Rust operation `finite_float_extremes`.
pub fn finite_float_extremes() [6]f64 {
    return [_]f64{ 1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000.0, 0.000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001, 179769313486231570000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000.0, 0.000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005, 0.0, -0.0 };
}

/// Runs the translated Rust operation `ignored_binding_effect`.
pub fn ignored_binding_effect() u64 {
    var calls: u64 = 0;
    _ = __r2z_value_block_1: {
        calls +%= 1;
        break :__r2z_value_block_1 calls;
    };
    return calls;
}

/// Runs the translated Rust operation `root_value`.
pub fn root_value() u32 {
    return 5;
}

/// Runs the translated Rust operation `width`.
pub fn width() usize {
    return r2z.memory.size_of(u32);
}

/// Runs the translated Rust operation `bits`.
pub fn bits(value: f32) u32 {
    return __r2z_value_block_1: {
        break :__r2z_value_block_1 r2z.memory.transmute(f32, u32)(value);
    };
}

/// Runs the translated Rust operation `bits_callable`.
pub fn bits_callable(value: f32) u32 {
    const convert: *const fn (f32) u32 = r2z.memory.transmute(f32, u32);
    return __r2z_value_block_1: {
        break :__r2z_value_block_1 convert(value);
    };
}

/// Runs the translated Rust operation `pointer_cast`.
pub fn pointer_cast(value: [*]align(1) allowzero const u8) [*]align(1) allowzero u8 {
    return @as([*]align(1) allowzero u8, @ptrCast(@constCast(value)));
}

/// Runs the translated Rust operation `render`.
pub fn render(f: *std.Io.Writer) std.Io.Writer.Error!void {
    return r2z.format.write(f, "value={} {:?}", .{ @as(u32, 42), @as(u21, '\n') });
}

/// An integer with separate Display, Debug and inherent formatting operations.
pub const ApiFormat = struct {
    const Self = @This();

    /// The integer to render.
    value: i32,

    /// Read the value through the inherent operation.
    pub fn forward(self: *const ApiFormat) i32 {
        return self.format__ApiFormat();
    }

    /// Read the value without writing it.
    pub fn format__ApiFormat(self: *const ApiFormat) i32 {
        return self.value;
    }

    /// Render the diagnostic value.
    pub fn formatDebug(self: *const ApiFormat, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return r2z.format.write(writer, "ApiFormat({})", .{ self.value });
    }

    /// Render the decimal value.
    pub fn format(self: *const ApiFormat, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return r2z.format.write(writer, "display={}", .{ self.value });
    }
};

/// A fieldless enum with a native formatting hook.
pub const ApiChoice = enum {
    /// The only active state.
    Only,

    /// Runs the translated Rust operation `fmt`.
    pub fn format(self: *const ApiChoice, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = self;
        return r2z.format.write(writer, "only", .{});
    }
};

/// Runs the translated Rust operation `render_api_debug`.
pub fn render_api_debug(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    return r2z.format.write(writer, "{:?}", .{ ApiFormat{ .value = 37 } });
}

/// Runs the translated Rust operation `owned`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// Release each returned owned runtime payload once with the allocator used
/// to create or grow it; see that runtime type's cleanup contract.
///
pub fn owned(allocator: std.mem.Allocator, input: []const u8) !r2z.alloc.String {
    return try r2z.alloc.String.from_str(allocator, input);
}

/// Runs the translated Rust operation `discard_result_error`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// By-value runtime-owned arguments transfer their storage by contract.
/// Zig copies alias that storage and are not separate cleanup owners.
///
pub fn discard_result_error(allocator: std.mem.Allocator, _value: r2z.alloc.String) ?u8 {
    var value: r2z.alloc.String = _value;
    defer value.deinit(allocator);
    var result_1: r2z.Result(u8, r2z.alloc.String) = r2z.Result(u8, r2z.alloc.String){ .Err = r2z.alloc.takeOwned(r2z.alloc.String, &value) };
    defer r2z.alloc.dropTemporary(allocator, &result_1);
    return r2z.alloc.takeOwned(r2z.Result(u8, r2z.alloc.String), &result_1).ok(allocator);
}

/// Runs the translated Rust operation `discard_result_success`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// By-value runtime-owned arguments transfer their storage by contract.
/// Zig copies alias that storage and are not separate cleanup owners.
///
pub fn discard_result_success(allocator: std.mem.Allocator, _value: r2z.alloc.String) ?u8 {
    var value: r2z.alloc.String = _value;
    defer value.deinit(allocator);
    var result_1: r2z.Result(r2z.alloc.String, u8) = r2z.Result(r2z.alloc.String, u8){ .Ok = r2z.alloc.takeOwned(r2z.alloc.String, &value) };
    defer r2z.alloc.dropTemporary(allocator, &result_1);
    return r2z.alloc.takeOwned(r2z.Result(r2z.alloc.String, u8), &result_1).err(allocator);
}

/// Runs the translated Rust operation `take_result_error`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// By-value runtime-owned arguments transfer their storage by contract.
/// Zig copies alias that storage and are not separate cleanup owners.
/// Release each returned owned runtime payload once with the allocator used
/// to create or grow it; see that runtime type's cleanup contract.
///
pub fn take_result_error(allocator: std.mem.Allocator, _value: r2z.alloc.String) r2z.alloc.String {
    var value: r2z.alloc.String = _value;
    defer value.deinit(allocator);
    var result_1: r2z.Result(u8, r2z.alloc.String) = r2z.Result(u8, r2z.alloc.String){ .Err = r2z.alloc.takeOwned(r2z.alloc.String, &value) };
    defer r2z.alloc.dropTemporary(allocator, &result_1);
    return r2z.alloc.takeOwned(r2z.Result(u8, r2z.alloc.String), &result_1).unwrap_err(allocator);
}

/// Runs the translated Rust operation `pointer_relations`.
pub fn pointer_relations(left: [*]align(1) allowzero const u8, right: [*]align(1) allowzero const u8) u8 {
    var bits_1: u8 = 0;
    if (@intFromPtr(left) < @intFromPtr(right)) {
        bits_1 |= 1;
    }
    if (@intFromPtr(left) <= @intFromPtr(right)) {
        bits_1 |= 2;
    }
    if (@intFromPtr(left) > @intFromPtr(right)) {
        bits_1 |= 4;
    }
    if (@intFromPtr(left) >= @intFromPtr(right)) {
        bits_1 |= 8;
    }
    if (@intFromPtr(left) == @intFromPtr(right)) {
        bits_1 |= 16;
    }
    if (@intFromPtr(left) != @intFromPtr(right)) {
        bits_1 |= 32;
    }
    return bits_1;
}

pub const BytePointer = [*]align(1) allowzero const u8;

/// Runs the translated Rust operation `pointer_alias_less`.
pub fn pointer_alias_less(left: BytePointer, right: BytePointer) bool {
    return @intFromPtr(left) < @intFromPtr(right);
}

/// Runs the translated Rust operation `pointer_borrowed_less`.
pub fn pointer_borrowed_less(left: *const [*]align(1) allowzero const u8, right: *const [*]align(1) allowzero const u8) bool {
    return @intFromPtr(left.*) < @intFromPtr(right.*);
}

/// Runs the translated Rust operation `mutated_local_matches`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
///
pub fn mutated_local_matches(allocator: std.mem.Allocator) !bool {
    var text: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "local");
    defer text.deinit(allocator);
    try r2z.alloc.String.push(&text, allocator, '!');
    return r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, text, "local!");
}

/// Runs the translated Rust operation `discard_local_result`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
///
pub fn discard_local_result(allocator: std.mem.Allocator) !?u8 {
    var payload: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "discarded");
    defer payload.deinit(allocator);
    var result_1: r2z.Result(u8, r2z.alloc.String) = r2z.Result(u8, r2z.alloc.String){ .Err = r2z.alloc.takeOwned(r2z.alloc.String, &payload) };
    defer r2z.alloc.dropTemporary(allocator, &result_1);
    return r2z.alloc.takeOwned(r2z.Result(u8, r2z.alloc.String), &result_1).ok(allocator);
}

/// Runs the translated Rust operation `retain_local_error`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// Release each returned owned runtime payload once with the allocator used
/// to create or grow it; see that runtime type's cleanup contract.
///
pub fn retain_local_error(allocator: std.mem.Allocator) !r2z.alloc.String {
    var payload: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "retained");
    defer payload.deinit(allocator);
    var result_1: r2z.Result(u8, r2z.alloc.String) = r2z.Result(u8, r2z.alloc.String){ .Err = r2z.alloc.takeOwned(r2z.alloc.String, &payload) };
    defer r2z.alloc.dropTemporary(allocator, &result_1);
    return r2z.alloc.takeOwned(r2z.Result(u8, r2z.alloc.String), &result_1).unwrap_err(allocator);
}

/// Runs the translated Rust operation `local_pair_length`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
///
pub fn local_pair_length(allocator: std.mem.Allocator) !usize {
    var first: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "first");
    defer first.deinit(allocator);
    var second: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "second");
    defer second.deinit(allocator);
    return first.len() +% second.len();
}

/// Runs the translated Rust operation `moved_vec_element`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// Release each returned owned runtime payload once with the allocator used
/// to create or grow it; see that runtime type's cleanup contract.
///
pub fn moved_vec_element(allocator: std.mem.Allocator) !std.ArrayListUnmanaged(r2z.alloc.String) {
    var first: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "vec-0");
    defer first.deinit(allocator);
    return __r2z_vec_value: {
        var __r2z_vec: std.ArrayListUnmanaged(r2z.alloc.String) = std.ArrayListUnmanaged(r2z.alloc.String).empty;
        errdefer r2z.alloc.dropTemporary(allocator, &__r2z_vec);
        var __r2z_vec_item: r2z.alloc.String = r2z.alloc.takeOwned(r2z.alloc.String, &first);
        errdefer r2z.alloc.dropTemporary(allocator, &__r2z_vec_item);
        try __r2z_vec.ensureUnusedCapacity(allocator, 1);
        __r2z_vec.appendAssumeCapacity(r2z.alloc.takeOwned(r2z.alloc.String, &__r2z_vec_item));
        var __r2z_vec_item_1: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "vec-1");
        errdefer r2z.alloc.dropTemporary(allocator, &__r2z_vec_item_1);
        try __r2z_vec.ensureUnusedCapacity(allocator, 1);
        __r2z_vec.appendAssumeCapacity(r2z.alloc.takeOwned(r2z.alloc.String, &__r2z_vec_item_1));
        var __r2z_vec_item_2: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "vec-2");
        errdefer r2z.alloc.dropTemporary(allocator, &__r2z_vec_item_2);
        try __r2z_vec.ensureUnusedCapacity(allocator, 1);
        __r2z_vec.appendAssumeCapacity(r2z.alloc.takeOwned(r2z.alloc.String, &__r2z_vec_item_2));
        var __r2z_vec_item_3: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "vec-3");
        errdefer r2z.alloc.dropTemporary(allocator, &__r2z_vec_item_3);
        try __r2z_vec.ensureUnusedCapacity(allocator, 1);
        __r2z_vec.appendAssumeCapacity(r2z.alloc.takeOwned(r2z.alloc.String, &__r2z_vec_item_3));
        var __r2z_vec_item_4: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "vec-4");
        errdefer r2z.alloc.dropTemporary(allocator, &__r2z_vec_item_4);
        try __r2z_vec.ensureUnusedCapacity(allocator, 1);
        __r2z_vec.appendAssumeCapacity(r2z.alloc.takeOwned(r2z.alloc.String, &__r2z_vec_item_4));
        var __r2z_vec_item_5: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "vec-5");
        errdefer r2z.alloc.dropTemporary(allocator, &__r2z_vec_item_5);
        try __r2z_vec.ensureUnusedCapacity(allocator, 1);
        __r2z_vec.appendAssumeCapacity(r2z.alloc.takeOwned(r2z.alloc.String, &__r2z_vec_item_5));
        var __r2z_vec_item_6: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "vec-6");
        errdefer r2z.alloc.dropTemporary(allocator, &__r2z_vec_item_6);
        try __r2z_vec.ensureUnusedCapacity(allocator, 1);
        __r2z_vec.appendAssumeCapacity(r2z.alloc.takeOwned(r2z.alloc.String, &__r2z_vec_item_6));
        var __r2z_vec_item_7: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "vec-7");
        errdefer r2z.alloc.dropTemporary(allocator, &__r2z_vec_item_7);
        try __r2z_vec.ensureUnusedCapacity(allocator, 1);
        __r2z_vec.appendAssumeCapacity(r2z.alloc.takeOwned(r2z.alloc.String, &__r2z_vec_item_7));
        var __r2z_vec_item_8: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "vec-8");
        errdefer r2z.alloc.dropTemporary(allocator, &__r2z_vec_item_8);
        try __r2z_vec.ensureUnusedCapacity(allocator, 1);
        __r2z_vec.appendAssumeCapacity(r2z.alloc.takeOwned(r2z.alloc.String, &__r2z_vec_item_8));
        break :__r2z_vec_value __r2z_vec;
    };
}

/// Runs the translated Rust operation `moved_branch_value`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// Release each returned owned runtime payload once with the allocator used
/// to create or grow it; see that runtime type's cleanup contract.
///
pub fn moved_branch_value(allocator: std.mem.Allocator, upper: bool) !r2z.alloc.String {
    var text: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "branched");
    defer text.deinit(allocator);
    return if (upper) __r2z_value_block_1: {
        break :__r2z_value_block_1 r2z.alloc.takeOwned(r2z.alloc.String, &text);
    } else __r2z_value_block_1: {
        break :__r2z_value_block_1 r2z.alloc.takeOwned(r2z.alloc.String, &text);
    };
}

/// Runs the translated Rust operation `moved_match_value`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// Release each returned owned runtime payload once with the allocator used
/// to create or grow it; see that runtime type's cleanup contract.
///
pub fn moved_match_value(allocator: std.mem.Allocator, mode: u8) !r2z.alloc.String {
    var text: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "matched");
    defer text.deinit(allocator);
    return switch (mode) {
        0 => r2z.alloc.takeOwned(r2z.alloc.String, &text),
        else => r2z.alloc.takeOwned(r2z.alloc.String, &text),
    };
}

/// Runs the translated Rust operation `moved_loop_value`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// Release each returned owned runtime payload once with the allocator used
/// to create or grow it; see that runtime type's cleanup contract.
///
pub fn moved_loop_value(allocator: std.mem.Allocator) !r2z.alloc.String {
    var text: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "looped");
    defer text.deinit(allocator);
    var index: u32 = 0;
    return __r2z_value_loop_1: {
while (true) {
        index +%= 1;
        if (index >= 2) {
            break :__r2z_value_loop_1 r2z.alloc.takeOwned(r2z.alloc.String, &text);
        }
    }};
}

/// Runs the translated Rust operation `lossy`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// Release each returned owned runtime payload once with the allocator used
/// to create or grow it; see that runtime type's cleanup contract.
///
pub fn lossy(allocator: std.mem.Allocator, input: []const u8) !r2z.alloc.CowStr {
    return try r2z.alloc.String.from_utf8_lossy(allocator, input);
}

/// Runs the translated Rust operation `borrowed_bytes`.
///
/// Release each returned owned runtime payload once with the allocator used
/// to create or grow it; see that runtime type's cleanup contract.
///
pub fn borrowed_bytes(input: []const u8) r2z.alloc.CowSlice(u8) {
    return r2z.alloc.CowSlice(u8){ .Borrowed = input };
}

/// Runs the translated Rust operation `sum`.
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

/// Runs the translated Rust operation `generic_narrow`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
///
pub fn generic_narrow(comptime T: type, allocator: std.mem.Allocator, _value: T) ?u8 {
    var value = if (switch (@typeInfo(@TypeOf(_value))) {
        .pointer => |__r2z_bufread_pointer| switch (__r2z_bufread_pointer.size) {
            .slice => false,
            else => true,
        },
        else => false,
    }) @as(void, {}) else _value;
    defer r2z.alloc.dropTemporary(allocator, &value);
    return r2z.convert.try_from(u8, if (switch (@typeInfo(@TypeOf(_value))) {
        .pointer => |__r2z_bufread_pointer_1| switch (__r2z_bufread_pointer_1.size) {
            .slice => false,
            else => true,
        },
        else => false,
    }) _value else value).ok(allocator);
}

/// Runs the translated Rust operation `byte_sum`.
pub fn byte_sum(input: []const u8) u32 {
    var sum_1: u32 = 0;
    for (input) |byte| {
        sum_1 +%= @as(u32, byte);
    }
    return sum_1;
}

/// Runs the translated Rust operation `collected`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// Release each returned owned runtime payload once with the allocator used
/// to create or grow it; see that runtime type's cleanup contract.
///
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

/// Runs the translated Rust operation `owner`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// Release each returned owned runtime payload once with the allocator used
/// to create or grow it; see that runtime type's cleanup contract.
///
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

/// Runs the translated Rust operation `flattened`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// Release each returned owned runtime payload once with the allocator used
/// to create or grow it; see that runtime type's cleanup contract.
///
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

/// Runs the translated Rust operation `stateful_flattened`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// Release each returned owned runtime payload once with the allocator used
/// to create or grow it; see that runtime type's cleanup contract.
///
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
                __r2z_capture_iter_0_end +%= 1;
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

/// Runs the translated Rust operation `reversed`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// Release each returned owned runtime payload once with the allocator used
/// to create or grow it; see that runtime type's cleanup contract.
///
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

/// Runs the translated Rust operation `signed_flattened`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// Release each returned owned runtime payload once with the allocator used
/// to create or grow it; see that runtime type's cleanup contract.
///
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

/// Runs the translated Rust operation `signed_range_sum`.
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

/// Runs the translated Rust operation `inclusive_range_sum`.
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

/// Runs the translated Rust operation `reverse_range_fold`.
pub fn reverse_range_fold(start: u8, end: u8) u32 {
    var result_1: u32 = 0;
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
            result_1 = result_1 *% 10 +% @as(u32, value);
        }
    }
    return result_1;
}

/// Runs the translated Rust operation `continued_range_sum`.
pub fn continued_range_sum(end: u8) u32 {
    var result_1: u32 = 0;
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
                result_1 +%= @as(u32, value);
            }
        }
    }
    return result_1;
}

/// Runs the translated Rust operation `indexed_sum`.
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

/// Runs the translated Rust operation `zipped_sum`.
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

/// Runs the translated Rust operation `apply_capture`.
pub fn apply_capture(base: u32, value: u32) u32 {
    return __r2z_value_block_1: {
        const x = value;
        break :__r2z_value_block_1 x +% base;
    };
}

/// Runs the translated Rust operation `apply_move_capture`.
pub fn apply_move_capture(base: u32, value: u32) u32 {
    var captured: u32 = base;
    const __r2z_capture_add_captured = captured;
    captured = 20;
    return (__r2z_value_block_1: {
        const x = value;
        break :__r2z_value_block_1 x +% __r2z_capture_add_captured;
    }) +% captured;
}

/// Runs the translated Rust operation `apply_mut_capture`.
pub fn apply_mut_capture(base: u32, value: u32) u32 {
    var total_1: u32 = base;
    _ = __r2z_value_block_1: {
        const x = value;
        break :__r2z_value_block_1 __r2z_value_block_2: {
            total_1 +%= x;
            break :__r2z_value_block_2 total_1;
        };
    };
    return __r2z_value_block_1: {
        const x = value;
        break :__r2z_value_block_1 __r2z_value_block_2: {
            total_1 +%= x;
            break :__r2z_value_block_2 total_1;
        };
    };
}

/// Runs the translated Rust operation `apply_mut_move_capture`.
pub fn apply_mut_move_capture(base: u32, value: u32) u32 {
    const captured: u32 = base;
    var __r2z_capture_add_captured = captured;
    _ = __r2z_value_block_1: {
        const x = value;
        break :__r2z_value_block_1 __r2z_value_block_2: {
            __r2z_capture_add_captured +%= x;
            break :__r2z_value_block_2 __r2z_capture_add_captured;
        };
    };
    return __r2z_value_block_1: {
        const x = value;
        break :__r2z_value_block_1 __r2z_value_block_2: {
            __r2z_capture_add_captured +%= x;
            break :__r2z_value_block_2 __r2z_capture_add_captured;
        };
    };
}

/// Runs the translated Rust operation `borrowed_sum`.
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

/// Runs the translated Rust operation `increment_sum`.
pub fn increment_sum(input: []u32) u32 {
    var __r2z_sum: u32 = 0;
    for (input[0..]) |*__r2z_item| {
        {
            const x = __r2z_item;
            const __r2z_item_value = __r2z_value_block_3: {
                x.* +%= 1;
                break :__r2z_value_block_3 x.*;
            };
            __r2z_sum += __r2z_item_value;
        }
    }
    return __r2z_sum;
}

/// Runs the translated Rust operation `filtered_index_sum`.
pub fn filtered_index_sum(input: []const u32) u32 {
    var __r2z_sum: u32 = 0;
    var __r2z_enumerate_index_1: usize = 0;
    for (input) |__r2z_item| {
        {
            const x = &__r2z_item;
            if (@rem(x.*, 2) == 0) {
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

/// Runs the translated Rust operation `filtered_zip_sum`.
pub fn filtered_zip_sum(left: []const u32, right: []const u32) u32 {
    var __r2z_sum: u32 = 0;
    const __r2z_zip_right_1 = right;
    var __r2z_zip_index_1: usize = 0;
    for (left) |__r2z_item| {
        {
            const x = &__r2z_item;
            if (@rem(x.*, 2) == 0) {
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

/// Runs the translated Rust operation `for_adapter_sum`.
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
                        total_1 +%= value;
                    }
                }
            }
        }
    }
    return total_1;
}

/// Runs the translated Rust operation `moved_adapter_sum`.
pub fn moved_adapter_sum(input: []const u32, base: u32) u32 {
    const running: u32 = base;
    const result_1: u32 = __r2z_value_block_1: {
        var __r2z_sum: u32 = 0;
        var __r2z_capture_iter_0_running = running;
        for (input) |__r2z_item| {
            {
                const x = __r2z_item;
                const __r2z_item_value = __r2z_value_block_4: {
                    __r2z_capture_iter_0_running +%= x;
                    break :__r2z_value_block_4 __r2z_capture_iter_0_running;
                };
                __r2z_sum += __r2z_item_value;
            }
        }
        break :__r2z_value_block_1 __r2z_sum;
    };
    return result_1 +% running;
}

/// Runs the translated Rust operation `counted_filter_sum`.
pub fn counted_filter_sum(input: []const u32) u32 {
    var calls: u32 = 0;
    const total_1: u32 = __r2z_value_block_1: {
        var __r2z_sum: u32 = 0;
        for (input) |__r2z_item| {
            {
                const x = __r2z_item;
                const __r2z_item_value = __r2z_value_block_4: {
                    calls +%= 1;
                    break :__r2z_value_block_4 x;
                };
                {
                    const x_1 = (&__r2z_item_value).*;
                    if (@rem(x_1, 2) == 0) {
                        __r2z_sum += __r2z_item_value;
                    }
                }
            }
        }
        break :__r2z_value_block_1 __r2z_sum;
    };
    return total_1 +% calls *% 100;
}

/// Rust `OptionalValue` state with Zig value semantics.
pub const OptionalValue = struct {
    const Self = @This();

    value: ?u8,

    /// Runs the translated Rust operation `consume`.
    pub fn consume(self: *OptionalValue) u8 {
        return __r2z_value_block_2: {
            const __r2z_option_match = __r2z_value_block_3: {
                const __r2z_option_take_813: ?u8 = self.value;
                self.value = null;
                break :__r2z_value_block_3 __r2z_option_take_813;
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

/// Runs the translated Rust operation `temporary_equal`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
///
pub fn temporary_equal(allocator: std.mem.Allocator, input: []const u8) !bool {
    return __r2z_value_block_1: {
        var __r2z_compare: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, input);
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare);
        var __r2z_compare_1: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "same");
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare_1);
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare, __r2z_compare_1);
    };
}

/// Runs the translated Rust operation `temporary_result`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// Release each returned owned runtime payload once with the allocator used
/// to create or grow it; see that runtime type's cleanup contract.
///
pub fn temporary_result(allocator: std.mem.Allocator, input: []const u8) !r2z.Result(r2z.alloc.String, u8) {
    return if (r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, input, "bad")) __r2z_value_block_1: {
        break :__r2z_value_block_1 r2z.Result(r2z.alloc.String, u8){ .Err = 7 };
    } else __r2z_value_block_1: {
        break :__r2z_value_block_1 r2z.Result(r2z.alloc.String, u8){ .Ok = try r2z.alloc.String.from_str(allocator, input) };
    };
}

/// Runs the translated Rust operation `temporary_result_equal`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
///
pub fn temporary_result_equal(allocator: std.mem.Allocator, input: []const u8) !bool {
    return __r2z_value_block_1: {
        var __r2z_compare: r2z.Result(r2z.alloc.String, u8) = try temporary_result(allocator, input);
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare);
        var __r2z_compare_1: r2z.Result(r2z.alloc.String, u8) = try temporary_result(allocator, "same");
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare_1);
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare, __r2z_compare_1);
    };
}

/// Runs the translated Rust operation `temporary_unwrap_equal`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
///
pub fn temporary_unwrap_equal(allocator: std.mem.Allocator, input: []const u8) !bool {
    return __r2z_value_block_1: {
        var __r2z_compare: r2z.alloc.String = (try temporary_result(allocator, input)).unwrap(allocator);
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare);
        var __r2z_compare_1: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "same");
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare_1);
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare, __r2z_compare_1);
    };
}

/// Runs the translated Rust operation `temporary_ordered`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// Release each returned owned runtime payload once with the allocator used
/// to create or grow it; see that runtime type's cleanup contract.
///
pub fn temporary_ordered(allocator: std.mem.Allocator, input: []const u8, sequence: *u32) !r2z.alloc.String {
    sequence.* = sequence.* *% 10 +% 1;
    return try r2z.alloc.String.from_str(allocator, input);
}

/// Runs the translated Rust operation `temporary_conditional`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
///
pub fn temporary_conditional(allocator: std.mem.Allocator, enabled: bool, sequence: *u32) !bool {
    return enabled and (__r2z_value_block_1: {
        var __r2z_compare: r2z.alloc.String = try temporary_ordered(allocator, "same", sequence);
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare);
        var __r2z_compare_1: r2z.alloc.String = __r2z_value_block_2: {
            sequence.* = sequence.* *% 10 +% 2;
            break :__r2z_value_block_2 try r2z.alloc.String.from_str(allocator, "same");
        };
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare_1);
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare, __r2z_compare_1);
    });
}

/// Runs the translated Rust operation `temporary_borrowed_equal`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
///
pub fn temporary_borrowed_equal(allocator: std.mem.Allocator, input: *const r2z.alloc.String) !bool {
    return __r2z_value_block_1: {
        const __r2z_compare = &input.*;
        var __r2z_compare_1: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, "same");
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare_1);
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare.*, __r2z_compare_1);
    };
}

/// Runs the translated Rust operation `temporary_vec`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// Release each returned owned runtime payload once with the allocator used
/// to create or grow it; see that runtime type's cleanup contract.
///
pub fn temporary_vec(allocator: std.mem.Allocator, input: u8) !r2z.Result(std.ArrayListUnmanaged(u8), u8) {
    return r2z.Result(std.ArrayListUnmanaged(u8), u8){ .Ok = __r2z_vec_value: {
        var __r2z_vec: std.ArrayListUnmanaged(u8) = std.ArrayListUnmanaged(u8).empty;
        errdefer __r2z_vec.deinit(allocator);
        try __r2z_vec.append(allocator, input);
        break :__r2z_vec_value __r2z_vec;
    } };
}

/// Runs the translated Rust operation `temporary_vec_equal`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
///
pub fn temporary_vec_equal(allocator: std.mem.Allocator, input: u8) !bool {
    return __r2z_value_block_1: {
        var __r2z_compare: std.ArrayListUnmanaged(u8) = (try temporary_vec(allocator, input)).unwrap(allocator);
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare);
        const __r2z_compare_1 = [_]u8{ 7 };
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare, __r2z_compare_1);
    };
}

/// Rust `UserError` state with Zig value semantics.
pub const UserError = struct {
    const Self = @This();

    code: u8,

    /// Runs the translated Rust operation `deinit`.
    pub fn deinit(self: *UserError) void {
        self.code = 0;
    }
};

/// Runs the translated Rust operation `user_error_code`.
pub fn user_error_code(@"error": *const UserError) u8 {
    return @"error".code;
}

/// Runs the translated Rust operation `user_error`.
///
/// Release each returned owned runtime payload once with the allocator used
/// to create or grow it; see that runtime type's cleanup contract.
///
pub fn user_error() r2z.Result(r2z.alloc.String, UserError) {
    return r2z.Result(r2z.alloc.String, UserError){ .Err = UserError{ .code = 7 } };
}

/// Runs the translated Rust operation `temporary_user_error_equal`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
///
pub fn temporary_user_error_equal(allocator: std.mem.Allocator, code: u8) bool {
    return __r2z_value_block_1: {
        var __r2z_compare: r2z.Result(r2z.alloc.String, UserError) = user_error();
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare);
        var __r2z_compare_1: r2z.Result(r2z.alloc.String, UserError) = r2z.Result(r2z.alloc.String, UserError){ .Err = UserError{ .code = code } };
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare_1);
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare, __r2z_compare_1);
    };
}

/// Runs the translated Rust operation `temporary_user_error_caller`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
///
pub fn temporary_user_error_caller(allocator: std.mem.Allocator, code: u8) bool {
    return temporary_user_error_equal(allocator, code);
}

/// Alternatives of Rust `TagError`; the active tag determines the payload.
pub const TagError = enum {
    Rejected,
    Accepted,
};

/// Runs the translated Rust operation `tagged_result`.
pub fn tagged_result(accept: bool) anyerror!u8 {
    return if (accept) __r2z_value_block_1: {
        break :__r2z_value_block_1 @as(u8, 7);
    } else __r2z_value_block_1: {
        break :__r2z_value_block_1 error.Rejected;
    };
}

/// Runs the translated Rust operation `contextual_tagged_result`.
pub fn contextual_tagged_result(accept: bool) ?anyerror!u8 {
    const result_1: anyerror!u8 = if (accept) __r2z_value_block_1: {
        break :__r2z_value_block_1 @as(u8, 7);
    } else __r2z_value_block_1: {
        break :__r2z_value_block_1 error.Rejected;
    };
    return @as(?anyerror!u8, result_1);
}

/// Runs the translated Rust operation `native_ok_variant`.
pub fn native_ok_variant() anyerror!TagError {
    return TagError.Accepted;
}

/// Runs the translated Rust operation `identity_tag_error`.
pub fn identity_tag_error(@"error": TagError) TagError {
    return @"error";
}

/// Runs the translated Rust operation `native_dynamic_error`.
pub fn native_dynamic_error() anyerror!u8 {
    return switch (identity_tag_error(TagError.Rejected)) {
        .Rejected => error.Rejected,
        .Accepted => error.Accepted,
    };
}

/// Runs the translated Rust operation `temporary_empty_string`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// Release each returned owned runtime payload once with the allocator used
/// to create or grow it; see that runtime type's cleanup contract.
///
pub fn temporary_empty_string(allocator: std.mem.Allocator) !r2z.alloc.String {
    return try r2z.alloc.String.from_str(allocator, "");
}

/// Runs the translated Rust operation `temporary_empty_equal`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
///
pub fn temporary_empty_equal(allocator: std.mem.Allocator, input: []const u8) !bool {
    return __r2z_value_block_1: {
        var __r2z_compare: r2z.alloc.String = try temporary_empty_string(allocator);
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare);
        var __r2z_compare_1: r2z.alloc.String = try r2z.alloc.String.from_str(allocator, input);
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare_1);
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare, __r2z_compare_1);
    };
}

/// Runs the translated Rust operation `temporary_moved_result_equal`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// By-value runtime-owned arguments transfer their storage by contract.
/// Zig copies alias that storage and are not separate cleanup owners.
///
pub fn temporary_moved_result_equal(allocator: std.mem.Allocator, _value: r2z.Result(r2z.alloc.String, u8)) bool {
    var value: r2z.Result(r2z.alloc.String, u8) = _value;
    defer r2z.alloc.dropTemporary(allocator, &value);
    return __r2z_value_block_1: {
        var __r2z_compare: r2z.alloc.String = r2z.alloc.takeOwned(r2z.Result(r2z.alloc.String, u8), &value).unwrap(allocator);
        defer r2z.alloc.dropTemporary(allocator, &__r2z_compare);
        const __r2z_compare_1 = "same";
        break :__r2z_value_block_1 r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, __r2z_compare, __r2z_compare_1);
    };
}

/// Runs the translated Rust operation `temporary_moved_result_caller`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
/// By-value runtime-owned arguments transfer their storage by contract.
/// Zig copies alias that storage and are not separate cleanup owners.
///
pub fn temporary_moved_result_caller(allocator: std.mem.Allocator, _value: r2z.Result(r2z.alloc.String, u8)) bool {
    var value: r2z.Result(r2z.alloc.String, u8) = _value;
    defer r2z.alloc.dropTemporary(allocator, &value);
    return temporary_moved_result_equal(allocator, r2z.alloc.takeOwned(r2z.Result(r2z.alloc.String, u8), &value));
}

/// Rust `ArrayViewStorage` state with Zig value semantics.
const ArrayViewStorage = struct {
    bytes: [2]u8,
};

/// Runs the translated Rust operation `write_inferred_nested_array`.
fn write_inferred_nested_array(value: u8) u8 {
    var rows: [2][2]u8 = [_][2]u8{ [_]u8{ 0 } ** 2 } ** 2;
    const view: []u8 = (&rows[1])[0..];
    view[0] = value;
    return rows[1][0];
}

/// Alternatives of Rust `OrPayload`; the active tag determines the payload.
const OrPayload = union(enum) {
    A: struct { n: u8 },
    B: struct { flag: bool, n: u8 },
    C: u8,
    Other: void,
};

/// Runs the translated Rust operation `or_payload`.
fn or_payload(mode: u8, n: u8, guarded: bool) u8 {
    const value: OrPayload = if (mode == 0) __r2z_value_block_1: {
        break :__r2z_value_block_1 OrPayload{ .A = .{ .n = n } };
    } else if (mode == 1) __r2z_value_block_1: {
        break :__r2z_value_block_1 OrPayload{ .B = .{ .flag = true, .n = n } };
    } else if (mode == 2) __r2z_value_block_1: {
        break :__r2z_value_block_1 OrPayload{ .C = n };
    } else __r2z_value_block_1: {
        break :__r2z_value_block_1 OrPayload{ .Other = @as(void, {}) };
    };
    return if (guarded) __r2z_match_block: {
        const __r2z_match_subject = value;
        switch (__r2z_match_subject) {
            .A => |__r2z_match_payload| {
                const n_1 = __r2z_match_payload.n;
                if (n_1 > 0) {
                    break :__r2z_match_block n_1 +% 1;
                }
            },
            else => @as(void, {}),
        }
        switch (__r2z_match_subject) {
            .B => |__r2z_match_payload_1| {
                const n_1 = __r2z_match_payload_1.n;
                if (n_1 > 0) {
                    break :__r2z_match_block n_1 +% 1;
                }
            },
            else => @as(void, {}),
        }
        switch (__r2z_match_subject) {
            .C => |n_1| {
                if (n_1 > 0) {
                    break :__r2z_match_block n_1 +% 1;
                }
            },
            else => @as(void, {}),
        }
        switch (__r2z_match_subject) {
            else => {
                break :__r2z_match_block 99;
            },
        }
        unreachable;
    } else __r2z_match_block_1: {
        const __r2z_match_subject_1 = value;
        switch (__r2z_match_subject_1) {
            .A => |__r2z_match_payload_2| {
                const n_4 = __r2z_match_payload_2.n;
                break :__r2z_match_block_1 n_4;
            },
            else => @as(void, {}),
        }
        switch (__r2z_match_subject_1) {
            .B => |__r2z_match_payload_3| {
                const n_4 = __r2z_match_payload_3.n;
                break :__r2z_match_block_1 n_4;
            },
            else => @as(void, {}),
        }
        switch (__r2z_match_subject_1) {
            .C => |n_4| {
                break :__r2z_match_block_1 n_4;
            },
            else => @as(void, {}),
        }
        switch (__r2z_match_subject_1) {
            else => {
                break :__r2z_match_block_1 99;
            },
        }
        unreachable;
    };
}

/// Runs the translated Rust operation `tuple_u8`.
fn tuple_u8(value: u8) u8 {
    return value;
}

/// Runs the translated Rust operation `tuple_i64`.
fn tuple_i64(value: i64) i64 {
    return value;
}

const DECODED_NEWLINE: []const u8 = "\n";

const DECODED_TAB: []const u8 = "\t";

const DECODED_HEX: []const u8 = "A";

const DECODED_UNICODE: []const u8 = "\xc3\xa9";

const DECODED_CONTINUATION: []const u8 = "AB";

const RAW_ESCAPE: []const u8 = "\\n";

/// Alternatives of Rust `OwnedOrPayload`; the active tag determines the payload.
const OwnedOrPayload = union(enum) {
    A: r2z.alloc.String,
    B: r2z.alloc.String,
    C: r2z.alloc.String,
};

/// Runs the translated Rust operation `owned_or_payload_length`.
///
/// `allocator` supplies memory operations and cleanup; use an allocator
/// compatible with any pre-existing storage passed into this call.
///
fn owned_or_payload_length(allocator: std.mem.Allocator, mode: u8, guarded: bool) !usize {
    var value: OwnedOrPayload = if (mode == 0) __r2z_value_block_1: {
        break :__r2z_value_block_1 OwnedOrPayload{ .A = try r2z.format.toString(allocator, "first") };
    } else if (mode == 1) __r2z_value_block_1: {
        break :__r2z_value_block_1 OwnedOrPayload{ .B = try r2z.format.toString(allocator, "second") };
    } else __r2z_value_block_1: {
        break :__r2z_value_block_1 OwnedOrPayload{ .C = try r2z.format.toString(allocator, "third") };
    };
    defer r2z.alloc.dropTemporary(allocator, &value);
    return if (guarded) __r2z_match_block: {
        const __r2z_match_place = &value;
        switch (__r2z_match_place.*) {
            .A => |*__r2z_match_payload| {
                const text = __r2z_match_payload.*;
                if (text.len() > 5) {
                    var __r2z_release = text;
                    _ = r2z.alloc.takeOwned(r2z.alloc.String, &__r2z_match_payload.*);
                    defer __r2z_release.deinit(allocator);
                    break :__r2z_match_block __r2z_release.len();
                }
            },
            else => @as(void, {}),
        }
        switch (__r2z_match_place.*) {
            .B => |*__r2z_match_payload_1| {
                const text = __r2z_match_payload_1.*;
                if (text.len() > 5) {
                    var __r2z_release_1 = text;
                    _ = r2z.alloc.takeOwned(r2z.alloc.String, &__r2z_match_payload_1.*);
                    defer __r2z_release_1.deinit(allocator);
                    break :__r2z_match_block __r2z_release_1.len();
                }
            },
            else => @as(void, {}),
        }
        switch (__r2z_match_place.*) {
            .C => |*__r2z_match_payload_2| {
                const text_2 = __r2z_match_payload_2.*;
                var __r2z_release_2 = text_2;
                _ = r2z.alloc.takeOwned(r2z.alloc.String, &__r2z_match_payload_2.*);
                defer __r2z_release_2.deinit(allocator);
                break :__r2z_match_block __r2z_release_2.len();
            },
            else => @as(void, {}),
        }
        switch (__r2z_match_place.*) {
            .A => |*__r2z_match_payload_3| {
                const text_3 = __r2z_match_payload_3.*;
                var __r2z_release_3 = text_3;
                _ = r2z.alloc.takeOwned(r2z.alloc.String, &__r2z_match_payload_3.*);
                defer __r2z_release_3.deinit(allocator);
                break :__r2z_match_block __r2z_release_3.len();
            },
            else => @as(void, {}),
        }
        switch (__r2z_match_place.*) {
            .B => |*__r2z_match_payload_4| {
                const text_3 = __r2z_match_payload_4.*;
                var __r2z_release_4 = text_3;
                _ = r2z.alloc.takeOwned(r2z.alloc.String, &__r2z_match_payload_4.*);
                defer __r2z_release_4.deinit(allocator);
                break :__r2z_match_block __r2z_release_4.len();
            },
            else => @as(void, {}),
        }
        unreachable;
    } else __r2z_match_block_1: {
        const __r2z_match_place_1 = &value;
        switch (__r2z_match_place_1.*) {
            .A => |*__r2z_match_payload_5| {
                const text_5 = __r2z_match_payload_5.*;
                var __r2z_release_5 = text_5;
                _ = r2z.alloc.takeOwned(r2z.alloc.String, &__r2z_match_payload_5.*);
                defer __r2z_release_5.deinit(allocator);
                break :__r2z_match_block_1 __r2z_release_5.len();
            },
            else => @as(void, {}),
        }
        switch (__r2z_match_place_1.*) {
            .B => |*__r2z_match_payload_6| {
                const text_5 = __r2z_match_payload_6.*;
                var __r2z_release_6 = text_5;
                _ = r2z.alloc.takeOwned(r2z.alloc.String, &__r2z_match_payload_6.*);
                defer __r2z_release_6.deinit(allocator);
                break :__r2z_match_block_1 __r2z_release_6.len();
            },
            else => @as(void, {}),
        }
        switch (__r2z_match_place_1.*) {
            .C => |*__r2z_match_payload_7| {
                const text_7 = __r2z_match_payload_7.*;
                var __r2z_release_7 = text_7;
                _ = r2z.alloc.takeOwned(r2z.alloc.String, &__r2z_match_payload_7.*);
                defer __r2z_release_7.deinit(allocator);
                break :__r2z_match_block_1 __r2z_release_7.len();
            },
            else => @as(void, {}),
        }
        unreachable;
    };
}

pub const support = @import("./support.zig");

pub const child = @import("./support/child.zig");

test "numeric_check" {
    const allocator: std.mem.Allocator = std.testing.allocator;
    try std.testing.expect(cast(511) == 255);
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, digit('f'), @as(?u32, 15)));
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, narrow(allocator, 255), @as(?u8, 255)));
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, narrow(allocator, 256), @as(?u8, null)));
}

test "ignored_binding_preserves_initialization" {
    try std.testing.expect(ignored_binding_effect() == 1);
}

test "module_reference_check" {
    try std.testing.expect(child.total() == 26);
}

test "memory_check" {
    try std.testing.expect(width() == 4);
    try std.testing.expect(bits(1.0) == 1065353216);
    try std.testing.expect(bits_callable(1.0) == 1065353216);
}

test "api_format_check" {
    try std.testing.expect((ApiFormat{ .value = 37 }).forward() == 37);
}

test "iterator_check" {
    try std.testing.expect(sum(&[_]u32{ 1, 2, 3, 4 }) == 14);
}

test "generic_check" {
    const allocator: std.mem.Allocator = std.testing.allocator;
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, generic_narrow(u16, allocator, 255), @as(?u8, 255)));
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, generic_narrow(u16, allocator, 256), @as(?u8, null)));
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

test "user_error_cleanup_check" {
    const allocator: std.mem.Allocator = std.testing.allocator;
    try std.testing.expect(temporary_user_error_caller(allocator, 7));
    try std.testing.expect(!temporary_user_error_caller(allocator, 8));
}

test "user_error_deinit_check" {
    var @"error": UserError = UserError{ .code = 7 };
    try std.testing.expect(user_error_code(&@"error") == 7);
    @"error".deinit();
    try std.testing.expect(@"error".code == 0);
    try std.testing.expect(user_error_code(&@"error") == 0);
}

test "tagged_result_check" {
    try std.testing.expect(try tagged_result(true) == 7);
    try std.testing.expect(try r2z.option.unwrap(contextual_tagged_result(true)) == 7);
    const payload: bool = switch (try native_ok_variant()) {
        .Accepted => true,
        .Rejected => false,
    };
    try std.testing.expect(payload);
}

test "moved_result_comparison_check" {
    const allocator: std.mem.Allocator = std.testing.allocator;
    try std.testing.expect(temporary_moved_result_caller(allocator, try temporary_result(allocator, "same")));
    try std.testing.expect(!temporary_moved_result_caller(allocator, try temporary_result(allocator, "other")));
}

test "empty_string_cleanup_check" {
    const allocator: std.mem.Allocator = std.testing.allocator;
    try std.testing.expect(try temporary_empty_equal(allocator, ""));
    try std.testing.expect(!try temporary_empty_equal(allocator, "other"));
}

test "indexed_any_advances_original_cursor" {
    const bytes: []const u8 = "a%b";
    var iters: [1]r2z.SliceIter(u8) = [_]r2z.SliceIter(u8){ r2z.sliceIter(u8, bytes) };
    try std.testing.expect(__r2z_value_block_1: {
        var __r2z_any_found = false;
        while (iters[0].next()) |__r2z_any_item| {
            if (__r2z_value_block_3: {
                const byte = __r2z_any_item.*;
                break :__r2z_value_block_3 byte == 37;
            }) {
                __r2z_any_found = true;
                break;
            }
        }
        break :__r2z_value_block_1 __r2z_any_found;
    });
    try std.testing.expect(iters[0].len() == 1);
    try std.testing.expect(!(__r2z_value_block_1: {
        var __r2z_any_found_1 = false;
        while (iters[0].next()) |__r2z_any_item_1| {
            if (__r2z_value_block_3: {
                const byte_1 = __r2z_any_item_1.*;
                break :__r2z_value_block_3 byte_1 == 37;
            }) {
                __r2z_any_found_1 = true;
                break;
            }
        }
        break :__r2z_value_block_1 __r2z_any_found_1;
    }));
    try std.testing.expect(iters[0].len() == 0);
}

test "dereferenced_any_advances_original_cursor" {
    const bytes: []const u8 = "a%b";
    var iter: r2z.SliceIter(u8) = r2z.sliceIter(u8, bytes);
    const pointer: *r2z.SliceIter(u8) = &iter;
    try std.testing.expect(__r2z_value_block_1: {
        var __r2z_any_found = false;
        while (pointer.*.next()) |__r2z_any_item| {
            if (__r2z_value_block_3: {
                const byte = __r2z_any_item.*;
                break :__r2z_value_block_3 byte == 37;
            }) {
                __r2z_any_found = true;
                break;
            }
        }
        break :__r2z_value_block_1 __r2z_any_found;
    });
    try std.testing.expect(iter.len() == 1);
    try std.testing.expect(!(__r2z_value_block_1: {
        var __r2z_any_found_1 = false;
        while (iter.next()) |__r2z_any_item_1| {
            if (__r2z_value_block_3: {
                const byte_1 = __r2z_any_item_1.*;
                break :__r2z_value_block_3 byte_1 == 37;
            }) {
                __r2z_any_found_1 = true;
                break;
            }
        }
        break :__r2z_value_block_1 __r2z_any_found_1;
    }));
    try std.testing.expect(iter.len() == 0);
}

test "mutable_array_views_reach_owned_places" {
    var storage: ArrayViewStorage = ArrayViewStorage{ .bytes = [_]u8{ 0 } ** 2 };
    const field_view: []u8 = (&storage.bytes)[0..];
    field_view[0] = 37;
    try std.testing.expect(storage.bytes[0] == 37);
    var rows: [2][2]u8 = [_][2]u8{ [_]u8{ 0 } ** 2 } ** 2;
    const indexed_view: []u8 = (&rows[1])[0..];
    indexed_view[0] = 91;
    try std.testing.expect(rows[1][0] == 91);
    try std.testing.expect(write_inferred_nested_array(143) == 143);
}

test "or_patterns_keep_payload_identity_and_guarded_fallthrough" {
    try std.testing.expect(or_payload(0, 4, true) == 5);
    try std.testing.expect(or_payload(1, 7, true) == 8);
    try std.testing.expect(or_payload(2, 12, true) == 13);
    try std.testing.expect(or_payload(1, 0, true) == 99);
    try std.testing.expect(or_payload(3, 4, true) == 99);
    try std.testing.expect(or_payload(0, 4, false) == 4);
    try std.testing.expect(or_payload(1, 7, false) == 7);
    try std.testing.expect(or_payload(2, 0, false) == 0);
    try std.testing.expect(or_payload(3, 4, false) == 99);
}

test "tuple_literals_keep_distinct_contextual_element_types" {
    const first: struct { u8, bool } = .{ 7, true };
    const second: struct { i64, bool } = .{ 9, false };
    try std.testing.expect(tuple_u8(first.@"0") == 7);
    try std.testing.expect(tuple_i64(second.@"0") == 9);
    try std.testing.expect(first.@"1");
    try std.testing.expect(!second.@"1");
}

test "constant_and_expression_strings_have_identical_bytes" {
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, DECODED_NEWLINE, "\n"));
    try std.testing.expect(DECODED_NEWLINE.len == 1);
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, DECODED_TAB, "\t"));
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, DECODED_HEX, "A"));
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, DECODED_UNICODE, "\xc3\xa9"));
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, DECODED_CONTINUATION, "AB"));
    try std.testing.expect(r2z.ops.binary(r2z.ops.Operation.eq, r2z.ops.Overflow.wrapping, RAW_ESCAPE, "\\n"));
}

test "owned_or_patterns_release_only_the_selected_arm" {
    const allocator: std.mem.Allocator = std.testing.allocator;
    try std.testing.expect(try owned_or_payload_length(allocator, 0, false) == 5);
    try std.testing.expect(try owned_or_payload_length(allocator, 1, false) == 6);
    try std.testing.expect(try owned_or_payload_length(allocator, 2, false) == 5);
    try std.testing.expect(try owned_or_payload_length(allocator, 0, true) == 5);
    try std.testing.expect(try owned_or_payload_length(allocator, 1, true) == 6);
    try std.testing.expect(try owned_or_payload_length(allocator, 2, true) == 5);
}

test "translated tests reachable through ./support.zig" {
    _ = support;
}

test "translated tests reachable through ./support/child.zig" {
    _ = child;
}
