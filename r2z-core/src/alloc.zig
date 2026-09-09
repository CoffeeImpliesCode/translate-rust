//! Explicit-allocation compatibility types for Rust `alloc` operations.
//!
//! Mapping contract:
//! * `alloc::vec::Vec<T>` maps to `r2z.alloc.Vec(T)`.
//! * `alloc::string::String` maps to `r2z.alloc.String`.
//! * `alloc::borrow::Cow<[T]>` maps to `r2z.alloc.CowSlice(T)`.
//! * `alloc::borrow::Cow<str>` maps to `r2z.alloc.CowStr`.
//!
//! `Vec` is an unmanaged list. `String` and owned `Cow` values carry storage
//! only; callers pass the creating allocator to every fallible mutation and
//! deinitialization operation. Borrowed `Cow` values never free their input.

const std = @import("std");
const character = @import("character.zig");
const Result = @import("result.zig").Result;
/// A growable, explicitly allocator-threaded byte or element vector.
///
/// `Vec` is an unmanaged standard-library list. It never stores an allocator, so
/// every operation which can allocate takes the allocator at the call site.
pub fn Vec(comptime T: type) type {
    return std.ArrayList(T);
}

pub const StringError = std.mem.Allocator.Error || error{
    InvalidUtf8,
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,
};

/// A UTF-8 validation failure that retains the original owned bytes.
pub const FromUtf8Error = struct {
    bytes: Vec(u8),
    detail: character.Utf8Error,

    pub fn utf8_error(self: *const @This()) character.Utf8Error {
        return self.detail;
    }

    /// Transfer the invalid bytes to the caller and leave this error empty.
    pub fn into_bytes(self: *@This()) Vec(u8) {
        const bytes = self.bytes;
        self.* = .{
            .bytes = .empty,
            .detail = .{ .valid_up_to = 0, .error_len = null },
        };
        return bytes;
    }

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
        self.* = .{
            .bytes = .empty,
            .detail = .{ .valid_up_to = 0, .error_len = null },
        };
    }
};

/// An owned, valid UTF-8 string.
pub const String = struct {
    bytes: Vec(u8) = .empty,

    pub const empty: String = .{ .bytes = .empty };

    /// Return an empty string with no allocation.
    pub fn new() String {
        return .empty;
    }

    /// Allocate an empty string with room for `capacity` bytes.
    pub fn with_capacity(
        gpa: std.mem.Allocator,
        capacity_bytes: usize,
    ) std.mem.Allocator.Error!String {
        return .{ .bytes = try Vec(u8).initCapacity(gpa, capacity_bytes) };
    }

    /// Copy a validated string into newly allocated owned storage.
    pub fn from_str(gpa: std.mem.Allocator, input: []const u8) StringError!String {
        if (character.validate_utf8(input)) |_| return error.InvalidUtf8;
        return .{ .bytes = try vec_from_slice(u8, gpa, input) };
    }

    /// Consume a vector and validate its bytes without copying.
    ///
    /// Both result branches own the consumed allocation. The input vector is
    /// reset before validation returns so it cannot be deinitialized twice.
    pub fn from_utf8(bytes: *Vec(u8)) Result(String, FromUtf8Error) {
        const owned = bytes.*;
        bytes.* = .empty;
        if (character.validate_utf8(owned.items)) |detail| {
            return .{ .Err = .{ .bytes = owned, .detail = detail } };
        }
        return .{ .Ok = .{ .bytes = owned } };
    }

    /// Consume a vector whose bytes are already known to be valid UTF-8.
    pub fn from_utf8_unchecked(bytes: *Vec(u8)) String {
        const owned = bytes.*;
        bytes.* = .empty;
        return .{ .bytes = owned };
    }

    /// Return a borrowed view when valid, otherwise allocate Rust-compatible
    /// maximal-subpart replacement output.
    pub fn from_utf8_lossy(gpa: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error!CowStr {
        const first_error = character.validate_utf8(input) orelse {
            return .{ .Borrowed = input };
        };
        return .{ .Owned = .{ .bytes = try lossy_copy(gpa, input, first_error) } };
    }

    pub fn as_str(self: *const @This()) []const u8 {
        return self.bytes.items;
    }

    pub fn as_bytes(self: *const @This()) []const u8 {
        return self.bytes.items;
    }

    pub fn fmt(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.bytes.items);
    }

    /// Return a mutable view. The caller must preserve UTF-8 validity.
    pub fn as_mut_str(self: *@This()) []u8 {
        return self.bytes.items;
    }

    pub fn len(self: *const @This()) usize {
        return self.bytes.items.len;
    }

    pub fn is_empty(self: *const @This()) bool {
        return self.bytes.items.len == 0;
    }

    pub fn capacity(self: *const @This()) usize {
        return self.bytes.capacity;
    }

    pub fn reserve(self: *@This(), gpa: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
        try self.bytes.ensureUnusedCapacity(gpa, additional);
    }

    pub fn clear(self: *@This()) void {
        self.bytes.clearRetainingCapacity();
    }

    pub fn push(self: *@This(), gpa: std.mem.Allocator, codepoint: u21) StringError!void {
        var encoded: [4]u8 = undefined;
        const encoded_len = try std.unicode.utf8Encode(codepoint, &encoded);
        try self.bytes.appendSlice(gpa, encoded[0..encoded_len]);
    }

    pub fn push_str(self: *@This(), gpa: std.mem.Allocator, input: []const u8) StringError!void {
        if (character.validate_utf8(input)) |_| return error.InvalidUtf8;
        try self.bytes.appendSlice(gpa, input);
    }

    /// Append either UTF-8 chunks (`[]const u8`) or Unicode scalar values
    /// (`u21`) from an iterator exposing `next()`.
    pub fn extend(self: *@This(), gpa: std.mem.Allocator, iterator: anytype) StringError!void {
        var it = iterator;
        while (it.next()) |item| {
            try append_string_item(self, gpa, item);
        }
    }

    pub fn from_chars(gpa: std.mem.Allocator, iterator: anytype) StringError!String {
        var result: String = .empty;
        errdefer result.deinit(gpa);
        try result.extend(gpa, iterator);
        return result;
    }

    /// Transfer the backing vector and leave this string empty.
    pub fn into_bytes(self: *@This()) Vec(u8) {
        const bytes = self.bytes;
        self.* = .empty;
        return bytes;
    }

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
        self.* = .empty;
    }
};

fn append_string_item(
    string: *String,
    gpa: std.mem.Allocator,
    item: anytype,
) StringError!void {
    const Item = @TypeOf(item);
    if (comptime Item == u21) {
        return string.push(gpa, item);
    }
    if (comptime (Item == []const u8 or Item == []u8)) {
        return string.push_str(gpa, item);
    }
    @compileError("String.extend expects an iterator of u21 or []const u8");
}

/// A borrowed or owned byte slice with explicit ownership transfer.
pub fn CowSlice(comptime T: type) type {
    return union(enum) {
        Borrowed: []const T,
        Owned: Vec(T),

        const Self = @This();

        pub fn from_borrowed(input: []const T) Self {
            return .{ .Borrowed = input };
        }

        pub fn from_owned(bytes: *Vec(T)) Self {
            const owned = bytes.*;
            bytes.* = .empty;
            return .{ .Owned = owned };
        }

        pub fn as_ref(self: *const Self) []const T {
            return switch (self.*) {
                .Borrowed => |bytes| bytes,
                .Owned => |*bytes| bytes.items,
            };
        }

        pub fn into_owned(self: *Self, gpa: std.mem.Allocator) std.mem.Allocator.Error!Vec(T) {
            return switch (self.*) {
                .Borrowed => |bytes| blk: {
                    const owned = try vec_from_slice(T, gpa, bytes);
                    self.* = .{ .Borrowed = &.{} };
                    break :blk owned;
                },
                .Owned => |*bytes| blk: {
                    const owned = bytes.*;
                    self.* = .{ .Borrowed = &.{} };
                    break :blk owned;
                },
            };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            switch (self.*) {
                .Borrowed => {},
                .Owned => |*bytes| bytes.deinit(gpa),
            }
            self.* = .{ .Borrowed = &.{} };
        }
    };
}

/// A borrowed or owned valid UTF-8 string.
pub const CowStr = union(enum) {
    Borrowed: []const u8,
    Owned: String,

    pub fn from_borrowed(input: []const u8) CowStr {
        return .{ .Borrowed = input };
    }

    pub fn from_owned(string: *String) CowStr {
        const owned = string.*;
        string.* = .empty;
        return .{ .Owned = owned };
    }

    pub fn as_ref(self: *const @This()) []const u8 {
        return switch (self.*) {
            .Borrowed => |input| input,
            .Owned => |*string| string.as_bytes(),
        };
    }

    pub fn fmt(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(switch (self) {
            .Borrowed => |input| input,
            .Owned => |string| string.bytes.items,
        });
    }

    pub fn into_owned(self: *@This(), gpa: std.mem.Allocator) StringError!String {
        return switch (self.*) {
            .Borrowed => |input| blk: {
                const owned = try String.from_str(gpa, input);
                self.* = .{ .Borrowed = &.{} };
                break :blk owned;
            },
            .Owned => |*string| blk: {
                const owned = string.*;
                self.* = .{ .Borrowed = &.{} };
                break :blk owned;
            },
        };
    }

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        switch (self.*) {
            .Borrowed => {},
            .Owned => |*string| string.deinit(gpa),
        }
        self.* = .{ .Borrowed = &.{} };
    }
};

/// Convert a byte `Cow` to a strict UTF-8 `Cow` without allocating.
///
/// Invalid input leaves the original `CowSlice` untouched and returns the
/// Rust-compatible first-error detail. Valid owned bytes transfer directly.
pub fn cow_bytes_to_utf8(cow: *CowSlice(u8)) Result(CowStr, character.Utf8Error) {
    switch (cow.*) {
        .Borrowed => |input| {
            if (character.validate_utf8(input)) |detail| {
                return .{ .Err = detail };
            }
            return .{ .Ok = .{ .Borrowed = input } };
        },
        .Owned => |bytes| {
            if (character.validate_utf8(bytes.items)) |detail| {
                return .{ .Err = detail };
            }
            var moved = bytes;
            cow.* = .{ .Borrowed = &.{} };
            return .{ .Ok = .{ .Owned = String.from_utf8_unchecked(&moved) } };
        },
    }
}

/// Convert a byte `Cow` to UTF-8 with Rust's maximal-subpart replacement.
///
/// Valid borrowed input remains borrowed. Valid owned input reuses its
/// allocation. Invalid owned input keeps the original allocation until the
/// replacement copy succeeds, then releases it exactly once.
pub fn cow_bytes_to_utf8_lossy(
    gpa: std.mem.Allocator,
    cow: *CowSlice(u8),
) std.mem.Allocator.Error!CowStr {
    switch (cow.*) {
        .Borrowed => |input| return String.from_utf8_lossy(gpa, input),
        .Owned => |bytes| {
            const first_error = character.validate_utf8(bytes.items) orelse {
                var moved = bytes;
                cow.* = .{ .Borrowed = &.{} };
                return .{ .Owned = String.from_utf8_unchecked(&moved) };
            };

            const replacement = try lossy_copy(gpa, bytes.items, first_error);
            var original = bytes;
            original.deinit(gpa);
            cow.* = .{ .Borrowed = &.{} };
            return .{ .Owned = .{ .bytes = replacement } };
        },
    }
}

pub fn vec_from_slice(
    comptime T: type,
    gpa: std.mem.Allocator,
    input: []const T,
) std.mem.Allocator.Error!Vec(T) {
    var result: Vec(T) = .empty;
    errdefer result.deinit(gpa);
    try result.appendSlice(gpa, input);
    return result;
}

pub fn vec_collect(
    comptime T: type,
    gpa: std.mem.Allocator,
    iterator: anytype,
) std.mem.Allocator.Error!Vec(T) {
    var result: Vec(T) = .empty;
    errdefer result.deinit(gpa);
    var it = iterator;
    while (it.next()) |item| {
        if (comptime @TypeOf(item) != T) {
            @compileError("Vec collection item type does not match the vector element type");
        }
        try result.append(gpa, item);
    }
    return result;
}

pub fn vec_extend(
    comptime T: type,
    gpa: std.mem.Allocator,
    destination: *Vec(T),
    input: []const T,
) std.mem.Allocator.Error!void {
    try destination.appendSlice(gpa, input);
}

pub fn collect_result(
    comptime T: type,
    comptime E: type,
    gpa: std.mem.Allocator,
    iterator: anytype,
) std.mem.Allocator.Error!Result(Vec(T), E) {
    var result: Vec(T) = .empty;
    errdefer result.deinit(gpa);
    var it = iterator;
    while (it.next()) |item| {
        switch (item) {
            .Ok => |value| try result.append(gpa, value),
            .Err => |err| {
                result.deinit(gpa);
                return .{ .Err = err };
            },
        }
    }
    return .{ .Ok = result };
}

fn lossy_copy(
    gpa: std.mem.Allocator,
    input: []const u8,
    first_error: character.Utf8Error,
) std.mem.Allocator.Error!Vec(u8) {
    var result: Vec(u8) = .empty;
    errdefer result.deinit(gpa);
    var index: usize = 0;
    var invalid: ?character.Utf8Error = first_error;
    while (invalid) |detail| {
        std.debug.assert(detail.valid_up_to < input.len - index);
        try result.appendSlice(gpa, input[index..][0..detail.valid_up_to]);
        try result.appendSlice(gpa, std.unicode.replacement_character_utf8[0..]);
        index += detail.valid_up_to;
        const error_len = detail.error_len orelse {
            index = input.len;
            break;
        };
        std.debug.assert(error_len > 0);
        index += error_len;
        invalid = character.validate_utf8(input[index..]);
    }
    try result.appendSlice(gpa, input[index..]);
    return result;
}

const CollectError = enum { invalid };

const ResultByteIterator = struct {
    index: usize = 0,

    fn next(self: *@This()) ?Result(u8, CollectError) {
        const result: ?Result(u8, CollectError) = switch (self.index) {
            0 => .{ .Ok = 0x12 },
            1 => .{ .Err = .invalid },
            else => null,
        };
        self.index += 1;
        return result;
    }
};

test "String takes valid UTF-8 byte ownership without copying" {
    const gpa = std.testing.allocator;
    var bytes = try vec_from_slice(u8, gpa, "h\xc3\xa9");
    const allocation_address = @intFromPtr(bytes.items.ptr);

    var conversion = String.from_utf8(&bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.items.len);
    try std.testing.expectEqual(@as(usize, 0), bytes.capacity);

    switch (conversion) {
        .Ok => |*string| {
            try std.testing.expectEqualStrings("h\xc3\xa9", string.as_str());
            try std.testing.expectEqual(allocation_address, @intFromPtr(string.as_bytes().ptr));

            var round_trip = string.into_bytes();
            defer round_trip.deinit(gpa);
            try std.testing.expectEqual(allocation_address, @intFromPtr(round_trip.items.ptr));
            try std.testing.expectEqual(@as(usize, 0), string.as_bytes().len);
            string.deinit(gpa);
        },
        .Err => |*invalid| {
            invalid.deinit(gpa);
            return error.ExpectedValidUtf8;
        },
    }
}

test "String UTF-8 failure retains byte ownership and error detail" {
    const gpa = std.testing.allocator;
    var bytes = try vec_from_slice(u8, gpa, "ok\xf0\x90");
    const allocation_address = @intFromPtr(bytes.items.ptr);

    var conversion = String.from_utf8(&bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.items.len);
    try std.testing.expectEqual(@as(usize, 0), bytes.capacity);

    switch (conversion) {
        .Ok => |*string| {
            string.deinit(gpa);
            return error.ExpectedInvalidUtf8;
        },
        .Err => |*invalid| {
            try std.testing.expectEqual(allocation_address, @intFromPtr(invalid.bytes.items.ptr));
            try std.testing.expectEqual(
                character.Utf8Error{ .valid_up_to = 2, .error_len = null },
                invalid.utf8_error(),
            );
            invalid.deinit(gpa);
        },
    }
}

test "Cow leaves borrowed storage alone and transfers owned storage once" {
    const gpa = std.testing.allocator;
    const literal = "borrowed";
    var borrowed = CowStr.from_borrowed(literal);
    try std.testing.expectEqual(@intFromPtr(literal.ptr), @intFromPtr(borrowed.as_ref().ptr));
    borrowed.deinit(gpa);

    var string = try String.from_str(gpa, "owned");
    const allocation_address = @intFromPtr(string.as_bytes().ptr);
    var owned = CowStr.from_owned(&string);
    defer owned.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), string.as_bytes().len);

    var moved = try owned.into_owned(gpa);
    defer moved.deinit(gpa);
    try std.testing.expectEqual(allocation_address, @intFromPtr(moved.as_bytes().ptr));
    try std.testing.expectEqual(@as(usize, 0), owned.as_ref().len);
}

test "Cow borrowed conversion keeps ownership when allocation fails" {
    const gpa = std.testing.allocator;
    const literal = "copy me";
    var cow = CowStr.from_borrowed(literal);
    defer cow.deinit(gpa);

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, cow.into_owned(failing.allocator()));
    try std.testing.expectEqual(@intFromPtr(literal.ptr), @intFromPtr(cow.as_ref().ptr));
}

test "lossy UTF-8 borrows valid input and owns standard replacement output" {
    const gpa = std.testing.allocator;
    const valid_input = "valid \xe2\x98\x83";
    var valid = try String.from_utf8_lossy(gpa, valid_input);
    defer valid.deinit(gpa);
    switch (valid) {
        .Borrowed => |utf8| {
            try std.testing.expectEqual(@intFromPtr(valid_input.ptr), @intFromPtr(utf8.ptr));
        },
        .Owned => return error.ExpectedBorrowedUtf8,
    }

    var lossy = try String.from_utf8_lossy(gpa, "a\xf0\x90b");
    defer lossy.deinit(gpa);
    switch (lossy) {
        .Borrowed => return error.ExpectedOwnedUtf8,
        .Owned => |*utf8| try std.testing.expectEqualStrings("a\xef\xbf\xbdb", utf8.as_str()),
    }
}

test "lossy UTF-8 follows Rust maximal-subpart grouping" {
    const gpa = std.testing.allocator;
    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "x\xc2", .expected = "x\xef\xbf\xbd" },
        .{ .input = "x\xe1\x80A", .expected = "x\xef\xbf\xbdA" },
        .{ .input = "x\xf0\x90", .expected = "x\xef\xbf\xbd" },
        .{ .input = "x\xe1\x80\xff", .expected = "x\xef\xbf\xbd\xef\xbf\xbd" },
        .{ .input = "x\xe0\x80A", .expected = "x\xef\xbf\xbd\xef\xbf\xbdA" },
    };

    for (cases) |case| {
        var lossy = try String.from_utf8_lossy(gpa, case.input);
        defer lossy.deinit(gpa);
        switch (lossy) {
            .Borrowed => return error.ExpectedOwnedUtf8,
            .Owned => |*utf8| try std.testing.expectEqualStrings(case.expected, utf8.as_str()),
        }
    }
}

test "owned byte Cow strict conversion reuses storage and lossy OOM preserves it" {
    const gpa = std.testing.allocator;

    var valid_bytes = try vec_from_slice(u8, gpa, "owned \xe2\x98\x83");
    const valid_address = @intFromPtr(valid_bytes.items.ptr);
    var valid_cow = CowSlice(u8).from_owned(&valid_bytes);
    var strict = cow_bytes_to_utf8(&valid_cow);
    switch (strict) {
        .Err => return error.ExpectedValidUtf8,
        .Ok => |*utf8| {
            switch (utf8.*) {
                .Borrowed => return error.ExpectedOwnedUtf8,
                .Owned => |*string| {
                    try std.testing.expectEqual(valid_address, @intFromPtr(string.as_bytes().ptr));
                    string.deinit(gpa);
                },
            }
        },
    }

    var invalid_bytes = try vec_from_slice(u8, gpa, "bad\xf0\x90");
    const invalid_address = @intFromPtr(invalid_bytes.items.ptr);
    var invalid_cow = CowSlice(u8).from_owned(&invalid_bytes);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        cow_bytes_to_utf8_lossy(failing.allocator(), &invalid_cow),
    );
    switch (invalid_cow) {
        .Borrowed => return error.ExpectedOwnedUtf8,
        .Owned => |bytes| try std.testing.expectEqual(invalid_address, @intFromPtr(bytes.items.ptr)),
    }
    invalid_cow.deinit(gpa);
}

test "result collection releases partial Vec on item error" {
    const gpa = std.testing.allocator;
    const iterator: ResultByteIterator = .{};
    var collected = try collect_result(u8, CollectError, gpa, iterator);

    switch (collected) {
        .Ok => |*bytes| {
            bytes.deinit(gpa);
            return error.ExpectedCollectionError;
        },
        .Err => |collection_error| {
            try std.testing.expectEqual(CollectError.invalid, collection_error);
        },
    }
}
