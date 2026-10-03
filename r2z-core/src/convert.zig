//! Rust `Default` and `From` adapters for generated generic code.
//!
//! Only Rust core primitive conversions and explicit translated trait methods
//! are accepted. Unsupported types and conversions fail at compile time.
//!
//! # What a conversion may consume
//!
//! A conversion is handed its source BY VALUE, so that one decision settles
//! every question of ownership here. A source the runtime owns no storage for
//! is read and handed on, and the caller keeps exactly what it had — a
//! borrowed `&str`, a `&[u8]`, a scalar, or a foreign struct the runtime has
//! no release for. A source that DOES own storage cannot be consumed this
//! way: the copy the callee receives and the caller's own binding would name
//! one allocation, and whichever was released second would be a double free.
//! `from` and `try_from` therefore REFUSE that pair instead of performing it,
//! and the transfer the runtime spells for an owning source stays
//! `r2z.alloc.takeOwned`, which empties the source where it stands so the
//! value it returns is the only owner left.

const std = @import("std");
const alloc = @import("alloc.zig");
const Result = @import("result.zig").Result;

const NonZeroDefault = struct {
    value: u32,

    pub fn default() @This() {
        return .{ .value = 0xa5a5_5a5a };
    }
};

const OffsetFromByte = struct {
    value: u16,

    pub fn from(value: u8) @This() {
        return .{ .value = @as(u16, value) + 1_000 };
    }
};

/// A destination whose `from` copies borrowed bytes out of the source.
///
/// This is the shape a translated `From<&str>` reaches: the source is a
/// borrow, the destination keeps no pointer into it, and nothing here owns
/// storage, so releasing the destination can never free the caller's bytes.
const CopiedWords = struct {
    text: [64]u8 = undefined,
    len: usize = 0,

    pub fn from(input: []const u8) @This() {
        var result: @This() = .{};
        result.len = @min(input.len, result.text.len);
        @memcpy(result.text[0..result.len], input[0..result.len]);
        return result;
    }

    fn as_str(self: *const @This()) []const u8 {
        return self.text[0..self.len];
    }
};

/// The same destination, reached through a borrow it keeps instead of
/// copying. It is here so the "borrowed source" property can be pinned in both
/// directions: the conversion neither frees the borrow NOR copies it, and the
/// caller keeps the only owner either way.
const RetainedWords = struct {
    text: []const u8,

    pub fn from(input: []const u8) @This() {
        return .{ .text = input };
    }

    fn as_str(self: *const @This()) []const u8 {
        return self.text;
    }
};

fn hasValidDefaultMethod(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return false,
    }
    if (!@hasDecl(T, "default")) return false;
    const method_info = @typeInfo(@TypeOf(T.default));
    if (method_info != .@"fn") return false;
    const function = method_info.@"fn";
    if (function.is_generic) return false;
    if (function.is_var_args) return false;
    if (function.params.len != 0) return false;
    const return_type = function.return_type orelse return false;
    return return_type == T;
}

fn hasValidFromMethod(comptime T: type, comptime Source: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return false,
    }
    if (!@hasDecl(T, "from")) return false;
    const method_info = @typeInfo(@TypeOf(T.from));
    if (method_info != .@"fn") return false;
    const function = method_info.@"fn";
    if (function.is_generic) return false;
    if (function.is_var_args) return false;
    if (function.params.len != 1) return false;
    const parameter_type = function.params[0].type orelse return false;
    if (parameter_type != Source) return false;
    const return_type = function.return_type orelse return false;
    return return_type == T;
}

fn isIntegerType(comptime T: type) bool {
    return @typeInfo(T) == .int;
}

fn isLosslessIntegerConversion(comptime Source: type, comptime T: type) bool {
    if (!isIntegerType(Source) or !isIntegerType(T)) return false;

    // Zig's u21 is the translated Rust `char`; only Rust's `From<u8> for char`
    // is represented by this primitive adapter.
    if (T == u21) return Source == u8;

    // Rust's portable From implementations use pointer-sized integers only as
    // destinations. Same-width u16/u8 and i16/i8 cases are explicit here.
    if (T == usize) return Source == u8 or Source == u16;
    if (T == isize) return Source == u8 or Source == i8 or Source == i16;
    if (Source == usize or Source == isize) return false;
    if (Source == u21) return false;

    const source_info = @typeInfo(Source).int;
    const destination_info = @typeInfo(T).int;
    if (source_info.signedness == .signed and destination_info.signedness == .unsigned) {
        return false;
    }
    return destination_info.bits > source_info.bits;
}

/// The one ownership question a conversion pair has to answer, asked before
/// any conversion runs.
///
/// A conversion is handed its source BY VALUE, so a source that owns runtime
/// storage arrives as a COPY of the caller's handle: two owners of one
/// allocation, of which whichever is released second is a double free. This
/// function cannot reach the caller's handle to empty it — that transfer is
/// `alloc.takeOwned`, spelled at the call site that still holds the handle —
/// so the pair is refused rather than converted.
///
/// The same answer covers a DESTINATION that owns storage, and for the
/// mirror reason: no allocator reaches this function, so it cannot build one.
/// The runtime's owned containers are spelled through the constructors that
/// take the call site's allocator — `alloc.String.from_str`,
/// `alloc.String.from_utf8`, `alloc.vec_from_slice` — and through
/// `alloc.takeOwned` for a transfer. Those names, and not this function, are
/// what an `alloc::string::String` type argument reaches.
///
/// The types refused are the five containers the runtime owns and the finite
/// wrappers built over them — a tuple, a nonempty array, an `Option`, an error
/// union, and the runtime `Result` — so a wrapper that wraps an owner is
/// refused with the owner inside it. A borrow, a slice, a scalar, and a
/// foreign named struct are all spelled, because none of them names storage
/// this runtime would release.
fn conversionIsSpelled(comptime T: type, comptime Source: type) bool {
    return !alloc.supportsOwnedMove(T) and !alloc.supportsOwnedMove(Source);
}

/// The message a pair refused by `conversionIsSpelled` reports. It names the
/// side that owns storage, because the two refusals are fixed differently.
fn unspelledConversionError(comptime T: type, comptime Source: type) []const u8 {
    if (alloc.supportsOwnedMove(Source)) {
        return "Rust From conversion from " ++ @typeName(Source) ++ " to " ++ @typeName(T) ++
            " is unavailable: the source owns runtime storage and this conversion " ++
            "is handed it by value, so both owners would release one allocation. " ++
            "Transfer the source with r2z.alloc.takeOwned first";
    }
    return "Rust From conversion from " ++ @typeName(Source) ++ " to " ++ @typeName(T) ++
        " is unavailable: the destination owns runtime storage and this " ++
        "conversion is reached with no allocator, so it cannot build one. Use " ++
        "the runtime constructor that takes the call site's allocator instead";
}

/// Return Rust's primitive or explicitly translated custom default.
pub fn default_value(comptime T: type) T {
    switch (@typeInfo(T)) {
        .int, .float => return @as(T, 0),
        .bool => return false,
        else => {},
    }

    if (comptime hasValidDefaultMethod(T)) return T.default();
    @compileError("Rust Default is unavailable for " ++ @typeName(T));
}

/// Apply Rust's identity, lossless primitive, or explicit custom conversion.
///
/// A pair `conversionIsSpelled` refuses never reaches an arm below: the
/// refusal is reported instead, naming the side that owns runtime storage and
/// the runtime spelling that handles that side.
pub fn from(comptime T: type, value: anytype) T {
    const Source = @TypeOf(value);
    if (comptime !conversionIsSpelled(T, Source)) {
        @compileError(unspelledConversionError(T, Source));
    }
    if (Source == T) return value;

    if (comptime isLosslessIntegerConversion(Source, T)) return @intCast(value);

    if (comptime Source == bool and isIntegerType(T) and T != u21) {
        return @intCast(@intFromBool(value));
    }

    if (comptime hasValidFromMethod(T, Source)) return T.from(value);
    @compileError(
        "Rust From conversion from " ++ @typeName(Source) ++
            " to " ++ @typeName(T) ++ " is unavailable",
    );
}

pub const Infallible = enum {};

/// The failure `TryFromIntError` names, rendered by every fallible integer
/// conversion this module drives.
pub const TryFromIntError = struct {
    /// Rust `Display for TryFromIntError`: write the fixed message. This is
    /// the native Zig `{f}` hook as well, so the same value renders through
    /// `std.Io.Writer.print` and `r2z.format.write`. `writer` is borrowed for
    /// the call and its own failure is returned unchanged.
    pub fn format(_: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("out of range integral type conversion attempted");
    }
};

fn hasConversionMethod(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(T, name),
        else => false,
    };
}

fn conversionError(comptime Converted: type) type {
    return switch (@typeInfo(Converted)) {
        .error_union => |value| value.error_set,
        .@"union" => std.meta.FieldType(Converted, .Err),
        else => @compileError("Rust TryFrom and TryInto must return Result"),
    };
}

/// The failure type a `TryFrom`/`TryInto` conversion reports.
///
/// The ownership refusal comes FIRST, before `Infallible` is offered, because
/// every arm below it reaches the conversion the same way `try_from` does:
/// the source is passed by value. A pair `conversionIsSpelled` refuses is
/// therefore refused here too, and neither an infallible nor a fallible
/// answer is offered for a pair whose source or destination would be two
/// owners of one allocation.
pub fn Error(comptime Source: type, comptime Target: type) type {
    if (comptime !conversionIsSpelled(Target, Source)) {
        @compileError(unspelledConversionError(Target, Source));
    }
    if (Source == Target or isLosslessIntegerConversion(Source, Target) or
        (Source == bool and isIntegerType(Target) and Target != u21) or hasValidFromMethod(Target, Source)) return Infallible;
    if (isIntegerType(Source) and isIntegerType(Target) and Source != u21 and Target != u21) return TryFromIntError;
    if (hasConversionMethod(Source, "try_into")) {
        return conversionError(@TypeOf((@as(Source, undefined)).try_into()));
    }
    if (hasConversionMethod(Target, "try_from")) {
        return conversionError(@TypeOf(Target.try_from(@as(Source, undefined))));
    }
    @compileError("Rust TryInto conversion is unavailable for these types");
}

fn convertedResult(comptime Target: type, comptime Failure: type, result: anytype) Result(Target, Failure) {
    if (@typeInfo(@TypeOf(result)) == .error_union) {
        return .{ .Ok = result catch |failure| return .{ .Err = failure } };
    }
    return result;
}

/// The fallible `From`/`TryInto` conversion.
///
/// `Error` is asked first and refuses an unspelled pair on its own, so no arm
/// below this one has to repeat the check: a value that reached the infallible
/// arm was already proven spelled, and the two remaining arms hand the source
/// to a method that consumes it, which is a transfer the caller has already
/// spelled.
pub fn try_from(comptime Target: type, value: anytype) Result(Target, Error(@TypeOf(value), Target)) {
    const Source = @TypeOf(value);
    const Failure = Error(Source, Target);
    if (Failure == Infallible) return .{ .Ok = from(Target, value) };
    if (comptime isIntegerType(Source) and isIntegerType(Target) and Source != u21 and Target != u21) {
        return .{ .Ok = std.math.cast(Target, value) orelse return .{ .Err = .{} } };
    }
    if (comptime hasConversionMethod(Source, "try_into")) {
        return convertedResult(Target, Failure, value.try_into());
    }
    return convertedResult(Target, Failure, Target.try_from(value));
}

test "fallible integer conversion preserves Rust range boundaries" {
    try std.testing.expectEqual(@as(u8, 255), try_from(u8, @as(u16, 255)).unwrap(std.testing.allocator));
    try std.testing.expect(try_from(u8, @as(u16, 256)).is_err());
    try std.testing.expect(try_from(u64, @as(i64, -1)).is_err());
    try std.testing.expectEqual(@as(i8, -128), try_from(i8, @as(i16, -128)).unwrap(std.testing.allocator));
    try std.testing.expect(try_from(i8, @as(i16, -129)).is_err());
    try std.testing.expectEqual(@as(u16, 255), try_from(u16, @as(u8, 255)).unwrap(std.testing.allocator));
    try std.testing.expectEqual(@as(i32, 17), try_from(i32, @as(i32, 17)).unwrap(std.testing.allocator));
}

test "default_value matches Rust primitive defaults" {
    try std.testing.expectEqual(@as(u8, 0), default_value(u8));
    try std.testing.expectEqual(@as(i128, 0), default_value(i128));
    try std.testing.expectEqual(@as(u21, 0), default_value(u21));
    try std.testing.expectEqual(@as(f32, 0.0), default_value(f32));
    try std.testing.expectEqual(@as(f64, 0.0), default_value(f64));
    try std.testing.expect(!default_value(bool));
}

test "default_value calls an explicit custom default" {
    try std.testing.expectEqual(
        NonZeroDefault{ .value = 0xa5a5_5a5a },
        default_value(NonZeroDefault),
    );
}

test "from preserves Rust lossless integer boundaries" {
    try std.testing.expectEqual(
        @as(u16, std.math.maxInt(u8)),
        from(u16, @as(u8, std.math.maxInt(u8))),
    );
    try std.testing.expectEqual(
        @as(i128, std.math.minInt(i8)),
        from(i128, @as(i8, std.math.minInt(i8))),
    );
    try std.testing.expectEqual(
        @as(i16, std.math.maxInt(u8)),
        from(i16, @as(u8, std.math.maxInt(u8))),
    );
    try std.testing.expectEqual(
        @as(u128, std.math.maxInt(u64)),
        from(u128, @as(u64, std.math.maxInt(u64))),
    );
    try std.testing.expectEqual(
        @as(usize, std.math.maxInt(u16)),
        from(usize, @as(u16, std.math.maxInt(u16))),
    );
    try std.testing.expectEqual(
        @as(isize, std.math.minInt(i16)),
        from(isize, @as(i16, std.math.minInt(i16))),
    );
}

test "from handles identity, bool, char, and explicit custom conversions" {
    try std.testing.expectEqual(std.math.maxInt(u32), from(u32, @as(u32, std.math.maxInt(u32))));
    try std.testing.expectEqual(@as(u128, 1), from(u128, true));
    try std.testing.expectEqual(@as(i8, 0), from(i8, false));
    try std.testing.expectEqual(@as(u21, 0xff), from(u21, @as(u8, std.math.maxInt(u8))));
    try std.testing.expectEqual(
        OffsetFromByte{ .value = 1_255 },
        from(OffsetFromByte, @as(u8, 255)),
    );

    const original = NonZeroDefault{ .value = 7 };
    try std.testing.expectEqual(original, from(NonZeroDefault, original));
}

test "a conversion releases the source it consumed instead of aliasing it" {
    // The property: a conversion whose SOURCE owns storage hands over that
    // storage rather than copying it. `conversionIsSpelled` is what refuses
    // the by-value spelling, and the transfer that handles it is
    // `alloc.takeOwned` — which empties the source where it stands, so the
    // scope release that runs afterwards frees nothing and the value returned
    // is the only owner left.
    //
    // Every allocation here is made by `std.testing.allocator`, which fails
    // this test on a leak and on a double free alike. So the count of owners
    // is what is actually being asserted, not the absence of an error.
    const gpa = std.testing.allocator;

    // A `String::from`-shaped conversion: bytes are built into ONE allocation
    // and handed to a single owner.
    var source = try alloc.String.from_str(gpa, "consumed source");
    const address = @intFromPtr(source.as_bytes().ptr);
    try std.testing.expectEqualStrings("consumed source", source.as_str());

    // The transfer the runtime spells for this pair hands the SAME allocation
    // over rather than copying it. A copy would show here as a different
    // address, and would leave two owners of one allocation.
    var moved = alloc.takeOwned(alloc.String, &source);
    try std.testing.expectEqual(address, @intFromPtr(moved.as_bytes().ptr));

    // The source the conversion consumed is RELEASED: it holds nothing now, so
    // the release its own scope runs frees nothing, and the moved value is the
    // one owner of the bytes.
    try std.testing.expectEqual(@as(usize, 0), source.as_str().len);
    try std.testing.expectEqualStrings("consumed source", moved.as_str());
    source.deinit(gpa);

    moved.deinit(gpa);
}

test "a conversion reads a borrowed source without freeing the caller's bytes" {
    // The property is about what the conversion does NOT do: a borrowed source
    // stays the caller's. The bytes are read, the destination is filled, and
    // the allocation the caller still owns is byte-identical afterwards and is
    // still theirs to release. A conversion that consumed the borrow would
    // double free at the `gpa.free` below, which is the caller's own and only
    // release, and `std.testing.allocator` reports exactly that.
    const gpa = std.testing.allocator;
    const borrowed: []const u8 = try gpa.dupe(u8, "borrowed bytes");
    defer gpa.free(borrowed);

    // A destination that COPIES: the borrow is read and the destination is
    // independent of it, which is the shape a translated `From<&str>` reaches.
    const copied = from(CopiedWords, borrowed);
    try std.testing.expectEqualStrings("borrowed bytes", copied.as_str());
    try std.testing.expect(!alloc.supportsOwnedMove(CopiedWords));

    // A destination that RETAINS the borrow: it is not copied, and it is not
    // freed either. The destination points INTO the caller's allocation, which
    // is what proves no copy was made, and the source is still whole, which is
    // what proves no release was made.
    const retained = from(RetainedWords, borrowed);
    try std.testing.expectEqual(@intFromPtr(borrowed.ptr), @intFromPtr(retained.as_str().ptr));
    try std.testing.expectEqualStrings("borrowed bytes", retained.as_str());

    // The caller's bytes are untouched by both conversions: still allocated,
    // still byte-identical, still owned here.
    try std.testing.expectEqualSlices(u8, "borrowed bytes", borrowed);
}

test "the runtime String type argument is refused rather than answered as a copy" {
    // `alloc::string::String` is the type argument `String::from(..)` arrives
    // with, and it owns its slab. A conversion is reached with no allocator,
    // so it cannot build one and must not be asked to: the pair is refused at
    // compile time. The runtime spells that conversion through
    // `alloc.String.from_str`, which takes the call site's allocator.
    try std.testing.expect(!conversionIsSpelled(alloc.String, []const u8));
    try std.testing.expect(!conversionIsSpelled([]const u8, alloc.String));
    try std.testing.expect(!conversionIsSpelled(alloc.String, alloc.String));

    // The other four runtime containers, and the finite wrappers over an
    // owner, are refused for the same reason: the wrapper reaches storage just
    // as the container it wraps does.
    try std.testing.expect(!conversionIsSpelled(alloc.String, alloc.CowStr));
    try std.testing.expect(!conversionIsSpelled(alloc.Vec(u8), []const u8));
    try std.testing.expect(!conversionIsSpelled(alloc.CowStr, alloc.String));
    try std.testing.expect(!conversionIsSpelled(alloc.CowSlice(u8), alloc.String));
    try std.testing.expect(!conversionIsSpelled(alloc.FromUtf8Error, []const u8));

    // A pair that owns nothing IS spelled, which is what makes the refusals
    // above refusals rather than a blanket ban. These are exactly the
    // conversions the corpus lowers: the primitive arms, the `char` arm, and
    // a translated `From` method over a borrow.
    try std.testing.expect(conversionIsSpelled(OffsetFromByte, u8));
    try std.testing.expect(conversionIsSpelled(u16, u8));
    try std.testing.expect(conversionIsSpelled(usize, u16));
    try std.testing.expect(conversionIsSpelled(u128, bool));
    try std.testing.expect(conversionIsSpelled(u21, u8));
    try std.testing.expect(conversionIsSpelled(CopiedWords, []const u8));
    try std.testing.expect(conversionIsSpelled(RetainedWords, []const u8));

    // The type argument the backend emits for `String::from(..)` names exactly
    // this runtime's `alloc.String` — `alloc::string::String` and its
    // `std::string::String` re-export both lower to that one declaration — and
    // it is a movable owner, which is why the pairs above are refused and why
    // the constructor the backend actually calls is the one that takes the
    // call site's allocator. That constructor copies the borrowed bytes into
    // FRESH storage, so the source and the result are separate allocations and
    // the caller still owns the source it passed.
    const gpa = std.testing.allocator;
    const source: []const u8 = try gpa.dupe(u8, "the type argument");
    defer gpa.free(source);
    const source_address = @intFromPtr(source.ptr);

    var built = try alloc.String.from_str(gpa, source);
    defer built.deinit(gpa);
    try std.testing.expectEqualStrings("the type argument", built.as_str());
    try std.testing.expect(alloc.supportsOwnedMove(alloc.String));

    // The copy is a SEPARATE allocation from the borrow it was made from, and
    // the borrow is still whole: this is the conversion the refused pair would
    // have performed if it had an allocator, and it leaves one owner each.
    try std.testing.expect(@intFromPtr(built.as_bytes().ptr) != source_address);
    try std.testing.expectEqualSlices(u8, "the type argument", source);
}
