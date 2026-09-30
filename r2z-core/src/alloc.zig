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

/// Drop a temporary runtime container, or the active owned payload of an
/// Option/Result wrapper. `value` must point at uniquely owned storage created
/// with `gpa`; borrowed pointers and slices are never followed or freed.
///
/// The runtime has a release for the containers it maps, so the types this
/// helper frees are fixed: `String`, `FromUtf8Error`, `Vec(T)`, and the active
/// payload of a tagged union, an `Option`, or an error union. A container
/// releases what its own elements hold before it releases itself. An element
/// type that owns nothing is never walked, so a vector of bytes frees its slab
/// and generates no loop. A slice, a pointer, an untagged union, and a foreign
/// struct name no owned storage, so none of them is followed. Only the `deinit`
/// of a known runtime container is ever called, never a foreign or user method.
pub fn dropTemporary(gpa: std.mem.Allocator, value: anytype) void {
    const T = @TypeOf(value.*);
    switch (@typeInfo(T)) {
        .@"struct" => {
            if (T == String or T == FromUtf8Error) {
                value.deinit(gpa);
            } else if (comptime vecElementType(T) != null) {
                // The `comptime` gate is what lets this body name `items`:
                // a struct that is not a vector has no such field.
                dropTemporaryElements(gpa, value.items);
                value.deinit(gpa);
            }
        },
        .@"union" => |union_type| {
            // An untagged union reports no active payload, so no field of one
            // names storage this helper may release.
            if (comptime union_type.tag_type != null) {
                switch (value.*) {
                    inline else => |*payload| dropTemporary(gpa, payload),
                }
            }
        },
        .array => |array| {
            // A fixed-length list holds its elements where they stand, so the
            // rule that releases a vector's elements applies to them as well.
            dropTemporaryElements(gpa, @as([]array.child, value));
        },
        .optional => {
            if (value.*) |*payload| dropTemporary(gpa, payload);
        },
        .error_union => {
            if (value.*) |*payload| {
                dropTemporary(gpa, payload);
            } else |_| {}
        },
        else => {},
    }
}

/// Hand a runtime container's storage to a new owner and empty the source.
///
/// A translated Rust move passes an owned payload by value, so the destination
/// becomes the sole owner of the allocation and the source must not release it
/// a second time. The transfer is the descriptor itself: no byte is copied and
/// nothing is allocated, and the source is reset in place to the empty state
/// the same container writes when it releases storage. A `defer` the source
/// scope still runs therefore finds nothing to free, and the new owner is
/// freed exactly once.
///
/// The movable types are a finite set, because only the containers this file
/// owns have a state to reset: `String`, `Vec(T)`, `CowStr`, `CowSlice(T)`, and
/// `FromUtf8Error`. A borrowed `Cow` moves as well; it hands over a pointer, and
/// neither the source nor the owner ever frees the input. Every other type is a
/// compile error, not a copy that quietly leaves the source owning the
/// payload.
pub fn takeOwned(comptime T: type, source: *T) T {
    const owner = source.*;
    source.* = comptime movedFromValue(T);
    return owner;
}

/// The runtime containers `takeOwned` moves.
const OwnedContainer = enum {
    string,
    vec,
    cow_str,
    cow_slice,
    utf8_error,
};

/// The kind of runtime container `T` is, or null for a type this file does not
/// own.
///
/// Identity decides, not shape: `String`, `CowStr`, and `FromUtf8Error` are the
/// exact types declared here, `Vec(T)` is the list `Vec` builds, and a
/// `CowSlice(T)` is the union `CowSlice` builds. A user struct carrying a
/// vector, a borrowed slice, or a method named `deinit` is none of them, so a
/// move of one is refused rather than faked.
fn ownedContainerKind(comptime T: type) ?OwnedContainer {
    if (T == String) return .string;
    if (T == CowStr) return .cow_str;
    if (T == FromUtf8Error) return .utf8_error;
    if (comptime vecElementType(T) != null) return .vec;
    if (comptime cowSliceElementType(T) != null) return .cow_slice;
    return null;
}

/// The state a source holds once its payload has been handed over.
///
/// Every kind the gate accepts declares this as its own `empty`, which is the
/// state its `deinit` and its consuming conversions already write. A moved-from
/// source is therefore indistinguishable from a released one, so a release
/// reaching it can never touch the storage the new owner holds.
fn movedFromValue(comptime T: type) T {
    const kind = ownedContainerKind(T) orelse @compileError(
        "takeOwned moves r2z.alloc.String, r2z.alloc.Vec(T), r2z.alloc.CowStr, " ++
            "r2z.alloc.CowSlice(T), and r2z.alloc.FromUtf8Error, not " ++ @typeName(T),
    );
    return switch (kind) {
        .string => String.empty,
        .cow_str => CowStr.empty,
        .utf8_error => FromUtf8Error.empty,
        // A vector and a byte `Cow` are types a generic function builds, so
        // each instantiation names its own empty state.
        .vec, .cow_slice => T.empty,
    };
}

/// The element type of a `CowSlice(E)`, or null for every other type.
///
/// The borrowed arm names the elements, and the answer only stands when the
/// whole union is the one `CowSlice` builds. A foreign union that also stores a
/// slice beside a vector is a user type: the runtime owns no release for it and
/// no empty state to move it into.
fn cowSliceElementType(comptime T: type) ?type {
    const union_type = switch (@typeInfo(T)) {
        .@"union" => |declared| declared,
        else => return null,
    };
    // An untagged union reports no active payload, so it holds nothing to move.
    if (union_type.tag_type == null) return null;
    for (union_type.fields) |field| {
        if (!std.mem.eql(u8, field.name, "Owned")) continue;
        const Element = vecElementType(field.type) orelse return null;
        if (T != CowSlice(Element)) return null;
        return Element;
    }
    return null;
}

/// The element type of a `Vec(T)`, or null for every other type.
///
/// The test is identity with the vector type, not a field shape. A foreign
/// struct that carries an `items` slice is not a runtime vector, and only a
/// runtime vector has a release this helper is allowed to run.
fn vecElementType(comptime T: type) ?type {
    const structure = switch (@typeInfo(T)) {
        .@"struct" => |declared| declared,
        else => return null,
    };
    for (structure.fields) |field| {
        const pointer = switch (@typeInfo(field.type)) {
            .pointer => |declared| declared,
            else => continue,
        };
        if (pointer.size == .slice and T == Vec(pointer.child)) return pointer.child;
    }
    return null;
}

/// True when a `Vec(T)` has a slab of its own to free.
///
/// A vector of zero-sized elements never allocates, so it holds no storage at
/// all. Every known owning element takes space, so a vector that owns
/// anything keeps answering true here.
fn vecOwnsSlab(comptime T: type) bool {
    const Element = vecElementType(T) orelse return false;
    return @sizeOf(Element) != 0;
}

/// True when a value of `T` holds storage that `dropTemporary` releases.
///
/// A vector qualifies when its elements take space, because a slab of them is
/// storage. An `Option`, an error union, and a tagged union qualify when the
/// payload they can hold qualifies; a tagged union names one active variant,
/// so its answer comes from its variants. A fixed-length list qualifies when
/// it is not empty and its element qualifies. An error set holds no storage of
/// its own. A foreign struct does not qualify: the runtime has no release for
/// it, and calling a method of the same name would run a destructor the runtime
/// does not own.
fn ownsTemporaryStorage(comptime T: type) bool {
    if (T == String or T == FromUtf8Error) return true;
    if (comptime vecOwnsSlab(T)) return true;
    return switch (@typeInfo(T)) {
        .array => |array| array.len != 0 and ownsTemporaryStorage(array.child),
        .optional => |optional| ownsTemporaryStorage(optional.child),
        .error_union => |error_union| ownsTemporaryStorage(error_union.payload),
        .@"union" => |union_type| variants: {
            if (union_type.tag_type == null) break :variants false;
            for (union_type.fields) |field| {
                if (ownsTemporaryStorage(field.type)) break :variants true;
            }
            break :variants false;
        },
        else => false,
    };
}

/// Release the storage the elements of a list hold, one element at a time.
///
/// The element type alone decides, and it is a compile-time type, so a list of
/// scalars, or of elements that take no space, frees its slab and nothing
/// else: the loop below is never generated for it.
fn dropTemporaryElements(gpa: std.mem.Allocator, items: anytype) void {
    const Element = @typeInfo(@TypeOf(items)).pointer.child;
    if (comptime ownsTemporaryStorage(Element)) {
        for (items) |*element| dropTemporary(gpa, element);
    }
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

    /// The state a released or moved-from error holds: no bytes to release and
    /// no failure of its own to report.
    pub const empty: @This() = .{
        .bytes = .empty,
        .detail = .{ .valid_up_to = 0, .error_len = null },
    };

    pub fn utf8_error(self: *const @This()) character.Utf8Error {
        return self.detail;
    }

    /// Transfer the invalid bytes to the caller and leave this error empty.
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

        /// A borrow of nothing, which is the state a released or moved-from
        /// `Cow` holds: it names no storage, so releasing it frees nothing.
        pub const empty: Self = .{ .Borrowed = &.{} };

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

        /// Copy this `Cow`, deep-copying owned storage and keeping a borrow a
        /// borrow.
        ///
        /// The borrowed arm keeps naming the caller's input, so copying it
        /// costs nothing and frees nothing. The owned arm is copied element for
        /// element into fresh storage, so copy and original release
        /// independently. The source is never consumed: `into_owned` is still
        /// the operation that transfers its allocation.
        pub fn clone(self: *const Self, gpa: std.mem.Allocator) std.mem.Allocator.Error!Self {
            return switch (self.*) {
                .Borrowed => |bytes| .{ .Borrowed = bytes },
                .Owned => |bytes| .{ .Owned = try vec_from_slice(T, gpa, bytes.items) },
            };
        }

        pub fn into_owned(self: *Self, gpa: std.mem.Allocator) std.mem.Allocator.Error!Vec(T) {
            return switch (self.*) {
                .Borrowed => |bytes| blk: {
                    const owned = try vec_from_slice(T, gpa, bytes);
                    self.* = .empty;
                    break :blk owned;
                },
                .Owned => |*bytes| blk: {
                    const owned = bytes.*;
                    self.* = .empty;
                    break :blk owned;
                },
            };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            switch (self.*) {
                .Borrowed => {},
                .Owned => |*bytes| bytes.deinit(gpa),
            }
            self.* = .empty;
        }
    };
}

/// A borrowed or owned valid UTF-8 string.
pub const CowStr = union(enum) {
    Borrowed: []const u8,
    Owned: String,

    /// A borrow of nothing, which is the state a released or moved-from `Cow`
    /// holds: it names no storage, so releasing it frees nothing.
    pub const empty: @This() = .{ .Borrowed = &.{} };

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

    /// Copy this `Cow`, deep-copying owned storage and keeping a borrow a
    /// borrow.
    ///
    /// The borrowed arm keeps naming the caller's input, so copying it costs
    /// nothing and frees nothing. The owned arm is copied into fresh storage,
    /// so copy and original release independently and a write through one is
    /// invisible to the other. The source is never consumed: `into_owned` is
    /// still the operation that hands its allocation over.
    pub fn clone(self: *const @This(), gpa: std.mem.Allocator) std.mem.Allocator.Error!CowStr {
        return switch (self.*) {
            .Borrowed => |input| .{ .Borrowed = input },
            // Owned `CowStr` bytes are valid UTF-8 already, so the copy
            // revalidates nothing and can fail only on allocation.
            .Owned => |string| .{ .Owned = .{ .bytes = try vec_from_slice(u8, gpa, string.bytes.items) } },
        };
    }

    pub fn into_owned(self: *@This(), gpa: std.mem.Allocator) StringError!String {
        return switch (self.*) {
            .Borrowed => |input| blk: {
                const owned = try String.from_str(gpa, input);
                self.* = .empty;
                break :blk owned;
            },
            .Owned => |*string| blk: {
                const owned = string.*;
                self.* = .empty;
                break :blk owned;
            },
        };
    }

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        switch (self.*) {
            .Borrowed => {},
            .Owned => |*string| string.deinit(gpa),
        }
        self.* = .empty;
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
            cow.* = .empty;
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
                cow.* = .empty;
                return .{ .Owned = String.from_utf8_unchecked(&moved) };
            };

            const replacement = try lossy_copy(gpa, bytes.items, first_error);
            var original = bytes;
            original.deinit(gpa);
            cow.* = .empty;
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

/// The element type of a slice, of a fixed-length array, or of a pointer to
/// one, or null for every other type.
///
/// Each of those names a run of elements a vector absorbs in one call, which is
/// what a by-value source of Rust's `extend` is. A pointer to an array counts
/// because that is the shape a byte string literal arrives in.
fn sequenceElementType(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .array => |array| array.child,
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child,
                else => null,
            },
            else => null,
        },
        else => null,
    };
}

pub fn vec_collect(
    comptime T: type,
    gpa: std.mem.Allocator,
    iterator: anytype,
) std.mem.Allocator.Error!Vec(T) {
    var result: Vec(T) = .empty;
    errdefer result.deinit(gpa);
    try vec_extend(T, gpa, &result, iterator);
    return result;
}

/// Append everything a source holds to a vector that may already hold items.
///
/// A slice, a fixed-length array, or a pointer to one (the shape a byte string
/// literal has) appends in one call. Anything exposing `next()` appends item by
/// item straight into the destination, so nothing is collected into a second
/// vector first and the elements already held are never copied. An allocation
/// failure returns `error.OutOfMemory` with every item appended so far still in
/// the destination: the caller owns that vector either way, so the runtime does
/// not release what it appended.
pub fn vec_extend(
    comptime T: type,
    gpa: std.mem.Allocator,
    destination: *Vec(T),
    input: anytype,
) std.mem.Allocator.Error!void {
    const InputElement = comptime sequenceElementType(@TypeOf(input));
    if (comptime InputElement != null) {
        if (comptime InputElement.? != T) {
            @compileError("Vec extension input element type does not match the vector element type");
        }
        return destination.appendSlice(gpa, input[0..]);
    }
    var it = input;
    while (it.next()) |item| {
        try append_vec_element(T, gpa, destination, item);
    }
}

fn append_vec_element(
    comptime T: type,
    gpa: std.mem.Allocator,
    destination: *Vec(T),
    item: anytype,
) std.mem.Allocator.Error!void {
    if (comptime @TypeOf(item) != T) {
        @compileError("Vec extension item type does not match the vector element type");
    }
    try destination.append(gpa, item);
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

/// A byte iterator over a literal, for the source `vec_extend` drains.
const ByteIterator = struct {
    items: []const u8,
    index: usize = 0,

    fn next(self: *@This()) ?u8 {
        if (self.index >= self.items.len) return null;
        const item = self.items[self.index];
        self.index += 1;
        return item;
    }
};

test "temporary drop releases owned elements and active payloads but never follows borrows" {
    const gpa = std.testing.allocator;
    var nested: ?Result(String, String) = .{ .Err = try String.from_str(gpa, "owned error") };
    dropTemporary(gpa, &nested);
    var absent: ?Result(String, String) = null;
    dropTemporary(gpa, &absent);

    var success: error{Failed}!String = try String.from_str(gpa, "owned success");
    dropTemporary(gpa, &success);
    var failure: error{Failed}!String = error.Failed;
    dropTemporary(gpa, &failure);

    const UserValue = struct {
        number: u8,

        pub fn deinit(self: *@This()) void {
            self.number = 0;
        }
    };
    var unrelated: Result(String, UserValue) = .{ .Err = .{ .number = 7 } };
    dropTemporary(gpa, &unrelated);
    try std.testing.expectEqual(@as(u8, 7), unrelated.Err.number);

    var named = try String.from_str(gpa, "still owned");
    defer named.deinit(gpa);
    var reference = &named;
    dropTemporary(gpa, &reference);
    var slice = named.as_str();
    dropTemporary(gpa, &slice);
    try std.testing.expectEqualStrings("still owned", named.as_str());

    // A list releases what its own elements hold before it releases its slab.
    var strings: Vec(String) = .empty;
    try strings.append(gpa, try String.from_str(gpa, "first element"));
    try strings.append(gpa, try String.from_str(gpa, "second element"));
    dropTemporary(gpa, &strings);

    // An element that holds a wrapper releases only the payload that is active,
    // and an empty `Option` element releases nothing at all.
    var optional_elements: Vec(?String) = .empty;
    try optional_elements.append(gpa, try String.from_str(gpa, "present element"));
    try optional_elements.append(gpa, null);
    dropTemporary(gpa, &optional_elements);

    var result_elements: Vec(Result(String, String)) = .empty;
    try result_elements.append(gpa, .{ .Ok = try String.from_str(gpa, "ok element") });
    try result_elements.append(gpa, .{ .Err = try String.from_str(gpa, "err element") });
    dropTemporary(gpa, &result_elements);

    // A borrowed element names storage the caller still owns, so the owned
    // element beside it is the only one this helper releases.
    var moved = try String.from_str(gpa, "owned element");
    var cow_elements: Vec(CowStr) = .empty;
    try cow_elements.append(gpa, CowStr.from_borrowed("borrowed element"));
    try cow_elements.append(gpa, CowStr.from_owned(&moved));
    try std.testing.expectEqual(@as(usize, 0), moved.as_bytes().len);
    dropTemporary(gpa, &cow_elements);

    // A fixed-length list and a nested list are storage an element owns, so
    // they are released the way a top-level container is.
    var pairs: Vec([2]String) = .empty;
    try pairs.append(gpa, .{
        try String.from_str(gpa, "left element"),
        try String.from_str(gpa, "right element"),
    });
    dropTemporary(gpa, &pairs);

    var nested_lists: Vec(Vec(u8)) = .empty;
    try nested_lists.append(gpa, try vec_from_slice(u8, gpa, "inner element"));
    dropTemporary(gpa, &nested_lists);

    // A list of scalars frees its slab, and no element is walked.
    var bytes: Vec(u8) = .empty;
    try bytes.appendSlice(gpa, "no element to release");
    dropTemporary(gpa, &bytes);

    // An untagged union names no active payload, so nothing inside one is
    // released: the value it was built from stays the caller's to free.
    const Untagged = union { text: String, count: usize };
    var kept = try String.from_str(gpa, "untagged element");
    var untagged: Untagged = .{ .text = kept };
    dropTemporary(gpa, &untagged);
    var untagged_list: Vec(Untagged) = .empty;
    try untagged_list.append(gpa, .{ .text = kept });
    dropTemporary(gpa, &untagged_list);
    dropTemporary(gpa, &kept);
}

test "takeOwned hands a string to its owner and leaves the source nothing to free" {
    const gpa = std.testing.allocator;
    var owner = blk: {
        var source = try String.from_str(gpa, "take me");
        const allocation_address = @intFromPtr(source.as_bytes().ptr);

        const moved = takeOwned(String, &source);
        try std.testing.expectEqual(@as(usize, 0), source.as_bytes().len);
        try std.testing.expectEqual(@as(usize, 0), source.capacity());

        // The scope the source lived in still releases what it holds. Emptying
        // the descriptor is what keeps that release from freeing the storage
        // the owner is about to use.
        source.deinit(gpa);
        try std.testing.expectEqual(allocation_address, @intFromPtr(moved.as_bytes().ptr));
        break :blk moved;
    };
    defer owner.deinit(gpa);

    // The owner reads the bytes the source built, and writing through it reaches
    // the allocation that was moved instead of a copy of it.
    try std.testing.expectEqualStrings("take me", owner.as_str());
    owner.as_mut_str()[0] = 'T';
    try std.testing.expectEqualStrings("Take me", owner.as_str());
}

test "takeOwned hands a vector to its owner and keeps its elements writable" {
    const gpa = std.testing.allocator;
    var owner = blk: {
        var source = try vec_from_slice(u32, gpa, &.{ 1, 2, 3 });
        const allocation_address = @intFromPtr(source.items.ptr);

        const moved = takeOwned(Vec(u32), &source);
        try std.testing.expectEqual(@as(usize, 0), source.items.len);
        try std.testing.expectEqual(@as(usize, 0), source.capacity);
        source.deinit(gpa);
        try std.testing.expectEqual(allocation_address, @intFromPtr(moved.items.ptr));
        break :blk moved;
    };
    defer owner.deinit(gpa);

    owner.items[2] = 9;
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 9 }, owner.items);
}

test "takeOwned transfers on the consuming branch and the other branch keeps its owner" {
    const gpa = std.testing.allocator;

    // The two arms of a translated conditional Rust move. Each arm builds a
    // payload and releases it where it stands, and only the consuming arm also
    // hands it to the destination. The empty source that arm leaves behind is
    // what stops its release from freeing the owner.
    const arms = [_]struct {
        payload: []const u8,
        consume: bool,
    }{
        .{ .payload = "consumed payload", .consume = true },
        .{ .payload = "retained payload", .consume = false },
    };
    for (arms) |arm| {
        var owner: ?String = null;
        {
            var source = try String.from_str(gpa, arm.payload);
            defer source.deinit(gpa);
            if (arm.consume) owner = takeOwned(String, &source);

            const expected_source_len = if (arm.consume) 0 else arm.payload.len;
            try std.testing.expectEqual(expected_source_len, source.as_str().len);
        }

        if (owner) |*moved| {
            defer moved.deinit(gpa);
            try std.testing.expect(arm.consume);
            try std.testing.expectEqualStrings(arm.payload, moved.as_str());
        } else {
            // The arm that did not consume still owned its payload and released
            // it at the end of its scope, so nothing survives to be moved.
            try std.testing.expect(!arm.consume);
        }
    }
}

test "takeOwned moves owned Cow storage and leaves a borrow a borrow" {
    const gpa = std.testing.allocator;

    // A borrowed `Cow` names storage this runtime does not own. The move hands
    // the pointer over and both values release nothing.
    const literal = "borrowed text";
    var borrow_source = CowStr.from_borrowed(literal);
    var borrow_owner = takeOwned(CowStr, &borrow_source);
    try std.testing.expectEqual(@as(usize, 0), borrow_source.as_ref().len);
    try std.testing.expectEqual(@intFromPtr(literal.ptr), @intFromPtr(borrow_owner.as_ref().ptr));
    borrow_owner.deinit(gpa);
    try std.testing.expectEqualStrings("borrowed text", literal);

    // An owned `Cow` hands its allocation over the way a `String` does, and the
    // emptied source it leaves behind releases nothing.
    var string = try String.from_str(gpa, "owned text");
    const owned_address = @intFromPtr(string.as_bytes().ptr);
    var owned_source = CowStr.from_owned(&string);
    var owned_owner = takeOwned(CowStr, &owned_source);
    try std.testing.expectEqual(@as(usize, 0), owned_source.as_ref().len);
    owned_source.deinit(gpa);
    try std.testing.expectEqual(owned_address, @intFromPtr(owned_owner.as_ref().ptr));
    try std.testing.expectEqualStrings("owned text", owned_owner.as_ref());
    owned_owner.deinit(gpa);

    // A byte `Cow` carries the same promise for the elements it owns.
    var numbers = try vec_from_slice(u32, gpa, &.{ 7, 8 });
    const numbers_address = @intFromPtr(numbers.items.ptr);
    var numbers_source = CowSlice(u32).from_owned(&numbers);
    var numbers_owner = takeOwned(CowSlice(u32), &numbers_source);
    try std.testing.expectEqualSlices(u32, &.{}, numbers_source.as_ref());
    numbers_source.deinit(gpa);
    try std.testing.expectEqual(numbers_address, @intFromPtr(numbers_owner.as_ref().ptr));
    switch (numbers_owner) {
        .Borrowed => return error.ExpectedOwnedCow,
        .Owned => |*owned| owned.items[0] = 11,
    }
    try std.testing.expectEqualSlices(u32, &.{ 11, 8 }, numbers_owner.as_ref());
    numbers_owner.deinit(gpa);
}

test "takeOwned moves the invalid bytes and keeps the UTF-8 detail" {
    const gpa = std.testing.allocator;

    var bytes = try vec_from_slice(u8, gpa, "ok\xf0\x90");
    var source = switch (String.from_utf8(&bytes)) {
        .Ok => return error.ExpectedInvalidUtf8,
        .Err => |invalid| invalid,
    };
    const allocation_address = @intFromPtr(source.bytes.items.ptr);

    var moved = takeOwned(FromUtf8Error, &source);
    try std.testing.expectEqual(@as(usize, 0), source.bytes.items.len);
    try std.testing.expectEqual(@as(usize, 0), source.bytes.capacity);
    // The emptied source is no longer a failure of its own, so a release
    // reaching it cannot free the bytes the owner holds.
    try std.testing.expectEqual(
        character.Utf8Error{ .valid_up_to = 0, .error_len = null },
        source.utf8_error(),
    );
    source.deinit(gpa);

    // The detail describes the bytes the owner now holds, so the move carries it
    // over instead of restating a failure of its own.
    try std.testing.expectEqual(allocation_address, @intFromPtr(moved.bytes.items.ptr));
    try std.testing.expectEqual(
        character.Utf8Error{ .valid_up_to = 2, .error_len = null },
        moved.utf8_error(),
    );
    moved.bytes.items[0] = 'O';
    try std.testing.expectEqualSlices(u8, "Ok\xf0\x90", moved.bytes.items);
    moved.deinit(gpa);
}

test "takeOwned accepts only the containers this runtime owns" {
    try std.testing.expectEqual(OwnedContainer.string, ownedContainerKind(String).?);
    try std.testing.expectEqual(OwnedContainer.vec, ownedContainerKind(Vec(u8)).?);
    try std.testing.expectEqual(OwnedContainer.cow_str, ownedContainerKind(CowStr).?);
    try std.testing.expectEqual(OwnedContainer.cow_slice, ownedContainerKind(CowSlice(u32)).?);
    try std.testing.expectEqual(OwnedContainer.utf8_error, ownedContainerKind(FromUtf8Error).?);

    // A user type that carries the same shape is not a runtime container, so a
    // move of one is refused at compile time instead of copying a payload the
    // source then frees a second time.
    const UserVector = struct { items: Vec(u8) };
    const UserList = struct {
        items: []const u8,
        capacity: usize,
    };
    const UserCow = union(enum) {
        Borrowed: []const u8,
        Owned: Vec(u8),
    };

    try std.testing.expect(ownedContainerKind(UserVector) == null);
    try std.testing.expect(ownedContainerKind(UserList) == null);
    try std.testing.expect(ownedContainerKind(UserCow) == null);
    try std.testing.expect(ownedContainerKind(u8) == null);
}

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

test "Cow clone borrows its input and copies owned storage independently" {
    const gpa = std.testing.allocator;

    const literal = "borrowed";
    var borrowed = CowStr.from_borrowed(literal);
    defer borrowed.deinit(gpa);
    var borrowed_copy = try borrowed.clone(gpa);
    defer borrowed_copy.deinit(gpa);
    try std.testing.expectEqual(
        @intFromPtr(literal.ptr),
        @intFromPtr(borrowed_copy.as_ref().ptr),
    );

    var string = try String.from_str(gpa, "owned");
    var owned = CowStr.from_owned(&string);
    defer owned.deinit(gpa);
    var owned_copy = try owned.clone(gpa);
    defer owned_copy.deinit(gpa);
    try std.testing.expectEqualStrings("owned", owned_copy.as_ref());

    // Writing through the copy leaves the original bytes alone, so the two are
    // independent storage and either is released on its own.
    switch (owned_copy) {
        .Borrowed => return error.ExpectedOwnedCopy,
        .Owned => |*copy| copy.as_mut_str()[0] = 'O',
    }
    try std.testing.expectEqualStrings("Owned", owned_copy.as_ref());
    try std.testing.expectEqualStrings("owned", owned.as_ref());

    // A refused copy leaves the source holding exactly what it always held.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, owned.clone(failing.allocator()));
    try std.testing.expectEqualStrings("owned", owned.as_ref());
}

test "byte Cow clone copies owned elements and keeps a borrow borrowed" {
    const gpa = std.testing.allocator;

    var numbers = try vec_from_slice(u32, gpa, &.{ 1, 2, 3 });
    var owned = CowSlice(u32).from_owned(&numbers);
    defer owned.deinit(gpa);
    var owned_copy = try owned.clone(gpa);
    defer owned_copy.deinit(gpa);

    switch (owned_copy) {
        .Borrowed => return error.ExpectedOwnedCopy,
        .Owned => |*bytes| bytes.items[0] = 9,
    }
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, owned.as_ref());

    const literal = "borrowed";
    var borrowed = CowSlice(u8).from_borrowed(literal);
    defer borrowed.deinit(gpa);
    var borrowed_copy = try borrowed.clone(gpa);
    defer borrowed_copy.deinit(gpa);
    try std.testing.expectEqual(
        @intFromPtr(literal.ptr),
        @intFromPtr(borrowed_copy.as_ref().ptr),
    );
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

test "vector extension appends an iterator and a slice after the elements held" {
    const gpa = std.testing.allocator;
    var destination: Vec(u8) = .empty;
    defer destination.deinit(gpa);
    try destination.appendSlice(gpa, "ab");

    try vec_extend(u8, gpa, &destination, ByteIterator{ .items = "cde" });
    try vec_extend(u8, gpa, &destination, "fg");
    try vec_extend(u8, gpa, &destination, [_]u8{ 'h' });

    try std.testing.expectEqualStrings("abcdefgh", destination.items);

    var collected = try vec_collect(u8, gpa, ByteIterator{ .items = "ijk" });
    defer collected.deinit(gpa);
    try std.testing.expectEqualStrings("ijk", collected.items);
}

test "vector extension allocation failure leaves the prefix in the destination" {
    const gpa = std.testing.allocator;
    // The capacity is exactly the prefix length, so the first appended item has
    // to grow the slab and the failing allocator refuses that growth.
    var destination = try Vec(u8).initCapacity(gpa, 3);
    defer destination.deinit(gpa);
    destination.appendSliceAssumeCapacity("pre");

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        vec_extend(u8, failing.allocator(), &destination, ByteIterator{ .items = "fix" }),
    );
    try std.testing.expectEqualStrings("pre", destination.items);

    // The vector that failed is still the caller's to use and to release.
    try destination.appendSlice(gpa, "fix");
    try std.testing.expectEqualStrings("prefix", destination.items);
}
