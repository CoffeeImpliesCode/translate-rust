//! Rust `Default` and `From` adapters for generated generic code.
//!
//! Only Rust core primitive conversions and explicit translated trait methods
//! are accepted. Unsupported types and conversions fail at compile time.

const std = @import("std");
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
pub fn from(comptime T: type, value: anytype) T {
    const Source = @TypeOf(value);
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

pub const TryFromIntError = struct {
    pub fn fmt(_: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
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

pub fn Error(comptime Source: type, comptime Target: type) type {
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
    try std.testing.expectEqual(@as(u8, 255), try_from(u8, @as(u16, 255)).unwrap());
    try std.testing.expect(try_from(u8, @as(u16, 256)).is_err());
    try std.testing.expect(try_from(u64, @as(i64, -1)).is_err());
    try std.testing.expectEqual(@as(i8, -128), try_from(i8, @as(i16, -128)).unwrap());
    try std.testing.expect(try_from(i8, @as(i16, -129)).is_err());
    try std.testing.expectEqual(@as(u16, 255), try_from(u16, @as(u8, 255)).unwrap());
    try std.testing.expectEqual(@as(i32, 17), try_from(i32, @as(i32, 17)).unwrap());
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
