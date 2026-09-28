const std = @import("std");
const Result = @import("result.zig").Result;
const alloc = @import("alloc.zig");

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
/// True when Zig's own `==` is valid for `T`.
///
/// Every scalar, enumeration, and aggregate whose own fields are all natively
/// comparable qualifies. A slice anywhere in the graph disqualifies the whole
/// type: Zig refuses `==` on it, so the caller must recurse instead.
fn isNativelyComparable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int,
        .comptime_int,
        .float,
        .comptime_float,
        .bool,
        .void,
        .noreturn,
        .enum_literal,
        .error_set,
        .null,
        .undefined,
        .type,
        .vector,
        .@"fn",
        => true,
        .array => |array| isNativelyComparable(array.child),
        .optional => |optional| isNativelyComparable(optional.child),
        .error_union => |error_union| isNativelyComparable(error_union.payload),
        .pointer => |pointer| if (pointer.size == .slice)
            false
        else
            isNativelyComparable(pointer.child),
        .@"struct" => |structure| blk: {
            if (structure.layout == .@"packed") break :blk true;
            for (structure.fields) |field| {
                if (!isNativelyComparable(field.type)) break :blk false;
            }
            break :blk true;
        },
        // An `enum` is always integer-backed, so its tag type is comparable
        // whatever the individual members are.
        .@"enum" => true,
        .@"union" => |union_type| blk: {
            for (union_type.fields) |field| {
                if (!isNativelyComparable(field.type)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

/// `r2z.alloc.Vec(T)` is `std.ArrayList(T)`, which owns no allocator field and
/// therefore cannot carry an `eq` method. Rust compares a `Vec` by its
/// contents and never by spare capacity, so that is what the field walk must
/// do for this shape.
fn isUnmanagedList(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    const fields = @typeInfo(T).@"struct".fields;
    if (fields.len != 2) return false;
    const items = @typeInfo(fields[0].type);
    const capacity = @typeInfo(fields[1].type);
    return std.mem.eql(u8, fields[0].name, "items") and
        items == .pointer and items.pointer.size == .slice and
        std.mem.eql(u8, fields[1].name, "capacity") and
        capacity == .int and capacity.int.bits >= 0;
}

/// A list container owns a list directly (`Vec(T)`) or behind its single
/// field (`String` is one `bytes` field). Rust answers `String == "x"` and
/// `Vec<T> == "x"` from the list contents, so an owner of that shape has to
/// be able to meet a bare borrow. A struct with any other field count is not
/// one: Rust gives those no borrow comparison, and they keep the field walk.
fn isListContainer(comptime T: type) bool {
    if (isUnmanagedList(T)) return true;
    if (@typeInfo(T) != .@"struct") return false;
    const fields = @typeInfo(T).@"struct".fields;
    if (fields.len != 1) return false;
    return isUnmanagedList(fields[0].type);
}

/// The field to descend into for a type `isListContainer` accepted: the list
/// itself, or the sole field holding it.
fn listContainerFieldName(comptime T: type) []const u8 {
    if (isUnmanagedList(T)) return "items";
    return @typeInfo(T).@"struct".fields[0].name;
}

/// Compare two structs field by field. Only reached when the type is not
/// natively comparable, so at least one field is a slice or an aggregate that
/// eventually bottoms out in one.
fn equalFields(left: anytype, right: anytype) bool {
    const Left = @TypeOf(left);
    inline for (@typeInfo(Left).@"struct".fields) |field| {
        if (!equal(@field(left, field.name), @field(right, field.name))) return false;
    }
    return true;
}

/// Compare two unions by active tag, then by the active payload. Inactive
/// payloads are never read: a tagged union stores every variant in the same
/// bytes, so comparing them would compare uninitialized storage.
fn equalUnion(left: anytype, right: anytype) bool {
    const union_type = @typeInfo(@TypeOf(left)).@"union";
    if (union_type.tag_type != null and std.meta.activeTag(left) != std.meta.activeTag(right)) {
        return false;
    }
    return switch (std.meta.activeTag(left)) {
        inline else => |tag| equal(
            @field(left, @tagName(tag)),
            @field(right, @tagName(tag)),
        ),
    };
}

/// Structural equality with a native fast path.
///
/// Arrays, slices, optionals, and one-pointers recurse element by element
/// because Zig's `==` refuses them. Every other aggregate uses Zig's own `==`
/// when its whole type is comparable, and otherwise walks its own fields so
/// that a slice buried inside a struct, a tagged union, or a `Result` payload
/// still compares by value. An owner of a list and a bare borrow are the same
/// Rust value in two forms, so one of them descends into the list it holds
/// before any of the above applies.
pub fn equal(left: anytype, right: anytype) bool {
    const Left = @TypeOf(left);
    const Right = @TypeOf(right);
    // An owner of a list and a bare borrow describe the same Rust value, so
    // the owner descends into the list it holds and the borrow meets its
    // items. Either side may be the owner; when both are, the switch below
    // decides as before.
    if (comptime isListContainer(Left) != isListContainer(Right)) {
        if (comptime isListContainer(Left)) return equal(@field(left, listContainerFieldName(Left)), right);
        return equal(left, @field(right, listContainerFieldName(Right)));
    }
    return switch (@typeInfo(Left)) {
        .void => true,
        .array => blk: {
            if (left.len != right.len) break :blk false;
            for (left, right) |a, b| if (!equal(a, b)) break :blk false;
            break :blk true;
        },
        .pointer => |pointer| if (pointer.size == .slice) blk: {
            if (left.len != right.len) break :blk false;
            for (left, right) |a, b| if (!equal(a, b)) break :blk false;
            break :blk true;
        } else if (pointer.size == .one) blk: {
            // A Zig string literal is a pointer to a sentinel-terminated
            // array, so it IS the borrow: dereferencing the peer to reach a
            // value that is not there is an error.
            if (comptime @typeInfo(pointer.child) == .array) break :blk equal(left.*, right);
            break :blk equal(left.*, right.*);
        } else left == right,
        .optional => if (left) |a| if (right) |b| equal(a, b) else false else right == null,
        // The `comptime` conditions gate which body is analyzed at all: a
        // natively comparable aggregate must never reach Zig's `==` check
        // through the field-walk branch, and a slice-bearing one must never
        // reach the `==` branch that the compiler would reject.
        .@"struct" => blk: {
            if (comptime isUnmanagedList(Left)) break :blk equal(left.items, right.items);
            if (comptime isNativelyComparable(Left)) break :blk std.meta.eql(left, right);
            break :blk equalFields(left, right);
        },
        .@"union" => blk: {
            if (comptime isNativelyComparable(Left)) break :blk std.meta.eql(left, right);
            break :blk equalUnion(left, right);
        },
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

test "generic equality compares a tagged union by tag then payload" {
    const DecodeError = union(enum) {
        odd_length,
        invalid_character: struct { value: u8, index: usize },
    };

    const ok_value: Result(u8, DecodeError) = .{ .Ok = 7 };
    const same_ok: Result(u8, DecodeError) = .{ .Ok = 7 };
    try std.testing.expect(equal(ok_value, same_ok));

    const short: Result(u8, DecodeError) = .{ .Err = .odd_length };
    const long: Result(u8, DecodeError) = .{ .Err = .{ .invalid_character = .{ .value = 'g', .index = 3 } } };
    // Same tag, different payload shape: equal would recurse into the
    // inactive payload, so the tags must decide first.
    try std.testing.expect(equal(short, short));
    try std.testing.expect(!equal(short, long));
    try std.testing.expect(!equal(ok_value, short));
}

test "generic equality walks struct fields that hold slices" {
    const Owned = struct { items: []const u8, count: usize };
    const left: Owned = .{ .items = "abc", .count = 3 };
    const same: Owned = .{ .items = "abc", .count = 3 };
    const other_text: Owned = .{ .items = "abd", .count = 3 };
    const other_count: Owned = .{ .items = "abc", .count = 4 };
    try std.testing.expect(equal(left, same));
    try std.testing.expect(!equal(left, other_text));
    try std.testing.expect(!equal(left, other_count));
}

test "generic equality descends through a slice field of a union payload" {
    const DecodeError = union(enum) {
        odd_length,
        invalid_character: struct { value: u8, index: usize },
    };
    // A `Result` whose payload carries a list: neither the tagged union nor
    // the list itself is natively comparable, so the whole chain must recurse.
    const Bytes = std.ArrayList(u8);
    var first: Bytes = .empty;
    defer first.deinit(std.testing.allocator);
    try first.appendSlice(std.testing.allocator, "abc");
    var second: Bytes = .empty;
    defer second.deinit(std.testing.allocator);
    try second.appendSlice(std.testing.allocator, "abc");
    var third: Bytes = .empty;
    defer third.deinit(std.testing.allocator);
    try third.appendSlice(std.testing.allocator, "abd");

    const ok_first: Result(Bytes, DecodeError) = .{ .Ok = first };
    const ok_second: Result(Bytes, DecodeError) = .{ .Ok = second };
    const ok_third: Result(Bytes, DecodeError) = .{ .Ok = third };
    try std.testing.expect(equal(ok_first, ok_second));
    try std.testing.expect(!equal(ok_first, ok_third));

    // Rust compares a `Vec` by its contents, so spare capacity is not part of
    // its identity. This pins that the list arm does not fall through to a
    // field-by-field struct walk that would compare `capacity`.
    var roomier: Bytes = .empty;
    defer roomier.deinit(std.testing.allocator);
    try roomier.ensureTotalCapacity(std.testing.allocator, 64);
    try roomier.appendSlice(std.testing.allocator, "abc");
    const ok_roomier: Result(Bytes, DecodeError) = .{ .Ok = roomier };
    try std.testing.expect(equal(ok_first, ok_roomier));

    const err_first: Result(Bytes, DecodeError) = .{ .Err = .odd_length };
    const err_second: Result(Bytes, DecodeError) = .{ .Err = .odd_length };
    try std.testing.expect(equal(err_first, err_second));
}

test "generic equality prefers native comparison for scalar payloads" {
    // A struct with no slice-bearing field must still compare true when every
    // field matches, and must not need any generated `eq` method.
    const Point = struct { x: i32, y: i32 };
    const a: Point = .{ .x = 1, .y = 2 };
    const b: Point = .{ .x = 1, .y = 2 };
    const c: Point = .{ .x = 1, .y = 3 };
    try std.testing.expect(equal(a, b));
    try std.testing.expect(!equal(a, c));
}

test "generic equality compares an owned string against a borrowed literal" {
    const gpa = std.testing.allocator;
    var owned = try alloc.String.from_str(gpa, "666f6f626172");
    defer owned.deinit(gpa);

    // A Rust `String` meets a `&str` from either side, because both describe
    // the same bytes.
    try std.testing.expect(binary(.eq, .wrapping, owned, "666f6f626172"));
    try std.testing.expect(binary(.eq, .wrapping, "666f6f626172", owned));

    // Same length, different bytes. A comparison that returned true because
    // the two shared spare capacity would pass this.
    try std.testing.expect(binary(.ne, .wrapping, owned, "666F6F626172"));
    try std.testing.expect(binary(.ne, .wrapping, "666F6F626172", owned));

    // A borrow is any slice over the same bytes, not only a literal.
    try std.testing.expect(binary(.eq, .wrapping, owned, owned.as_str()));
    try std.testing.expect(binary(.eq, .wrapping, owned.as_str(), owned));

    // A differing length is never equal, whichever side carries it.
    try std.testing.expect(binary(.ne, .wrapping, owned, "666f6f6261"));
    try std.testing.expect(binary(.ne, .wrapping, "666f6f6261", owned));
    try std.testing.expect(binary(.ne, .wrapping, owned, "666f6f626172666f"));
    try std.testing.expect(binary(.ne, .wrapping, "666f6f626172666f", owned));
    try std.testing.expect(binary(.ne, .wrapping, owned, ""));
    try std.testing.expect(binary(.ne, .wrapping, "", owned));
}

test "generic equality ignores spare capacity between owned strings" {
    const gpa = std.testing.allocator;
    var tight: alloc.String = .{ .bytes = try alloc.Vec(u8).initCapacity(gpa, 4) };
    defer tight.deinit(gpa);
    try tight.push_str(gpa, "same");
    var roomy: alloc.String = .{ .bytes = try alloc.Vec(u8).initCapacity(gpa, 64) };
    defer roomy.deinit(gpa);
    try roomy.push_str(gpa, "same");

    // Identical content, capacities 4 and 64. Capacity is storage, not
    // identity, so it must not decide the answer.
    try std.testing.expect(tight.as_bytes().len == 4);
    try std.testing.expect(roomy.as_bytes().len == 4);
    try std.testing.expect(equal(tight, roomy));
    try std.testing.expect(equal(roomy, tight));
    try std.testing.expect(equal(tight, "same"));
    try std.testing.expect(equal(roomy, "same"));
}

test "generic equality compares a vector against a borrowed literal" {
    const gpa = std.testing.allocator;
    var vec: alloc.Vec(u8) = .empty;
    defer vec.deinit(gpa);
    try vec.appendSlice(gpa, "xyz");

    try std.testing.expect(equal(vec, "xyz"));
    try std.testing.expect(equal("xyz", vec));
    try std.testing.expect(equal(vec, vec.items));
    try std.testing.expect(!equal(vec, "xy"));
    try std.testing.expect(!equal("xy", vec));
    try std.testing.expect(!equal(vec, "xyzq"));
    try std.testing.expect(!equal("xyzq", vec));
}

test "generic equality descends a single-field list container to meet a borrow" {
    // The shape `String` itself has: a struct whose one field is a list.
    const Nested = struct { bytes: alloc.Vec(u8) };
    const gpa = std.testing.allocator;
    var nested: Nested = .{ .bytes = .empty };
    defer nested.bytes.deinit(gpa);
    try nested.bytes.appendSlice(gpa, "abc");

    try std.testing.expect(equal(nested, "abc"));
    try std.testing.expect(equal("abc", nested));
    try std.testing.expect(equal(nested, "abc"[0..]));
    try std.testing.expect(equal("abc"[0..], nested));
    try std.testing.expect(!equal(nested, "abd"));
    try std.testing.expect(!equal("abd", nested));
    try std.testing.expect(!equal(nested, "ab"));
    try std.testing.expect(!equal("ab", nested));

    // Descending onto the list must reach the items and stop there, so a
    // roomier twin of the same content still compares equal.
    var roomier: Nested = .{ .bytes = try alloc.Vec(u8).initCapacity(gpa, 64) };
    defer roomier.bytes.deinit(gpa);
    try roomier.bytes.appendSlice(gpa, "abc");
    try std.testing.expect(equal(nested, roomier));
    try std.testing.expect(equal(nested, roomier.bytes.items));
}

test "generic equality does not treat a list owner as equal to every borrow" {
    const gpa = std.testing.allocator;
    var vec: alloc.Vec(u8) = .empty;
    defer vec.deinit(gpa);
    try vec.appendSlice(gpa, "abc");

    // A one-field struct over a bare slice is NOT a list container, so two of
    // them never take the cross-form branch and the field walk still decides.
    const Borrowed = struct { items: []const u8 };
    try std.testing.expect(equal(Borrowed{ .items = "abc" }, Borrowed{ .items = "abc" }));
    try std.testing.expect(!equal(Borrowed{ .items = "abc" }, Borrowed{ .items = "abd" }));
    try std.testing.expect(!equal(Borrowed{ .items = "abc" }, Borrowed{ .items = "ab" }));

    // A list in a struct that owns more than that list is NOT a list
    // container: Rust grants no borrow comparison, and none is invented here.
    // The ordinary field walk decides, so a differing count still counts and a
    // same-length byte difference inside the list still differs.
    const Mixed = struct { count: usize, bytes: alloc.Vec(u8) };
    var mixed: Mixed = .{ .count = 3, .bytes = .empty };
    defer mixed.bytes.deinit(gpa);
    try mixed.bytes.appendSlice(gpa, "abc");
    var same: Mixed = .{ .count = 3, .bytes = .empty };
    defer same.bytes.deinit(gpa);
    try same.bytes.appendSlice(gpa, "abc");
    var other_count: Mixed = .{ .count = 4, .bytes = .empty };
    defer other_count.bytes.deinit(gpa);
    try other_count.bytes.appendSlice(gpa, "abc");
    var other_bytes: Mixed = .{ .count = 3, .bytes = .empty };
    defer other_bytes.bytes.deinit(gpa);
    try other_bytes.bytes.appendSlice(gpa, "abd");
    try std.testing.expect(equal(mixed, same));
    try std.testing.expect(!equal(mixed, other_count));
    try std.testing.expect(!equal(mixed, other_bytes));

    // An empty owner equals only an empty borrow.
    try std.testing.expect(equal(alloc.Vec(u8).empty, ""));
    try std.testing.expect(!equal(alloc.Vec(u8).empty, "a"));
    try std.testing.expect(!equal("a", alloc.Vec(u8).empty));
}
