const std = @import("std");

/// Fills `dest` with little-endian bytes using rand_core 0.5 RngCore semantics.
/// `generator` is a mutable handle exposing `next_u64() u64` and `next_u32() u32`.
/// Eight-byte chunks and five-to-seven-byte tails consume `next_u64`; one-to-four
/// byte tails consume `next_u32`. An empty destination consumes nothing.
pub fn fill_bytes_via_next(generator: anytype, dest: []u8) void {
    var left = dest;
    while (left.len >= 8) {
        std.mem.writeInt(u64, left[0..8], generator.next_u64(), .little);
        left = left[8..];
    }
    if (left.len > 4) {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, generator.next_u64(), .little);
        @memcpy(left, bytes[0..left.len]);
    } else if (left.len > 0) {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, generator.next_u32(), .little);
        @memcpy(left, bytes[0..left.len]);
    }
}

test "fill_bytes_via_next matches rand_core 0.5 byte and state boundaries" {
    const ScriptedRng = struct {
        state: usize = 0,
        calls32: usize = 0,
        calls64: usize = 0,

        pub fn next_u32(self: *@This()) u32 {
            const values = [_]u32{ 0xd4c3b2a1, 0x48372615, 0x9c8b7a69, 0xe0cfbead };
            const value = values[self.state];
            self.state += 1;
            self.calls32 += 1;
            return value;
        }

        pub fn next_u64(self: *@This()) u64 {
            const values = [_]u64{ 0x8877665544332211, 0x1020304050607080, 0xd8c7b6a594837261, 0x0f1e2d3c4b5a6978 };
            const value = values[self.state];
            self.state += 1;
            self.calls64 += 1;
            return value;
        }
    };
    const cases = [_]struct {
        bytes: []const u8,
        calls32: usize,
        calls64: usize,
        next64: u64,
        next32: u32,
    }{
        .{ .bytes = "", .calls32 = 0, .calls64 = 0, .next64 = 0x8877665544332211, .next32 = 0x48372615 },
        .{ .bytes = "\xa1", .calls32 = 1, .calls64 = 0, .next64 = 0x1020304050607080, .next32 = 0x9c8b7a69 },
        .{ .bytes = "\xa1\xb2\xc3\xd4", .calls32 = 1, .calls64 = 0, .next64 = 0x1020304050607080, .next32 = 0x9c8b7a69 },
        .{ .bytes = "\x11\x22\x33\x44\x55", .calls32 = 0, .calls64 = 1, .next64 = 0x1020304050607080, .next32 = 0x9c8b7a69 },
        .{ .bytes = "\x11\x22\x33\x44\x55\x66\x77", .calls32 = 0, .calls64 = 1, .next64 = 0x1020304050607080, .next32 = 0x9c8b7a69 },
        .{ .bytes = "\x11\x22\x33\x44\x55\x66\x77\x88", .calls32 = 0, .calls64 = 1, .next64 = 0x1020304050607080, .next32 = 0x9c8b7a69 },
        .{ .bytes = "\x11\x22\x33\x44\x55\x66\x77\x88\x15", .calls32 = 1, .calls64 = 1, .next64 = 0xd8c7b6a594837261, .next32 = 0xe0cfbead },
        .{ .bytes = "\x11\x22\x33\x44\x55\x66\x77\x88\x15\x26\x37\x48", .calls32 = 1, .calls64 = 1, .next64 = 0xd8c7b6a594837261, .next32 = 0xe0cfbead },
        .{ .bytes = "\x11\x22\x33\x44\x55\x66\x77\x88\x80\x70\x60\x50\x40", .calls32 = 0, .calls64 = 2, .next64 = 0xd8c7b6a594837261, .next32 = 0xe0cfbead },
        .{ .bytes = "\x11\x22\x33\x44\x55\x66\x77\x88\x80\x70\x60\x50\x40\x30\x20", .calls32 = 0, .calls64 = 2, .next64 = 0xd8c7b6a594837261, .next32 = 0xe0cfbead },
        .{ .bytes = "\x11\x22\x33\x44\x55\x66\x77\x88\x80\x70\x60\x50\x40\x30\x20\x10", .calls32 = 0, .calls64 = 2, .next64 = 0xd8c7b6a594837261, .next32 = 0xe0cfbead },
    };
    const untouched = [_]u8{0xa5} ** 40;
    for (cases) |case| {
        for (0..8) |offset| {
            var rng: ScriptedRng = .{};
            var buffer: [40]u8 align(8) = untouched;
            const start = 8 + offset;
            const end = start + case.bytes.len;

            @This().fill_bytes_via_next(&rng, buffer[start..end]);

            try std.testing.expectEqualSlices(u8, case.bytes, buffer[start..end]);
            try std.testing.expectEqualSlices(u8, untouched[0..start], buffer[0..start]);
            try std.testing.expectEqualSlices(u8, untouched[end..], buffer[end..]);
            try std.testing.expectEqual(case.calls32, rng.calls32);
            try std.testing.expectEqual(case.calls64, rng.calls64);
            try std.testing.expectEqual(case.calls32 + case.calls64, rng.state);
            try std.testing.expectEqual(case.next64, rng.next_u64());
            try std.testing.expectEqual(case.next32, rng.next_u32());
        }
    }
}

// ── rand_core 0.5.1 `Error`, as the wyhash corpus resolves it ─────────────
//
// rand_core 0.5.1 declares no `default` feature and Cargo activates nothing,
// so this is the `no_std`, no-`getrandom`, no-`serde1` shape: `Error` stores a
// `NonZeroU32` code and nothing else. Its `std` sibling is a different type —
// it stores a `Box<dyn Error>` — and is deliberately not bound here; nothing in
// this repository builds rand_core with `std`, and a `std` `Error` carries no
// code for `code()` or `raw_os_error()` to report.

/// Rust `core::num::NonZeroU32`: a `u32` that is never zero.
///
/// Zig 0.16 has no non-zero integer type — the language has no `non_zero` int
/// flag and `std` ships no replacement — so this wraps the `u32` and keeps the
/// invariant where it can be checked: `init` is the only way to build one and
/// it answers `null` for zero, which is what turns a zero code away before it
/// can reach `Error`. `Error` below is its only user.
pub const NonZeroU32 = struct {
    /// The wrapped value, which is never zero.
    value: u32,

    /// Wrap `value`, or answer `null` when it is zero.
    pub fn init(value: u32) ?@This() {
        if (value == 0) return null;
        return .{ .value = value };
    }
};

/// rand_core 0.5.1's `Error`, in the configuration the wyhash corpus resolves.
///
/// This is the value `RngCore::try_fill_bytes` fails with, so it is a real
/// value and not a fieldless enum: `Result<(), Error>` carries this struct, so a
/// failure keeps the code that caused it instead of collapsing to a tag. It is
/// deliberately not `anyerror`, which would erase exactly that and let a
/// result helper mistake it for an error set.
///
/// The value owns nothing. Its one field is a `NonZeroU32`, so there is no
/// allocator, no release step and nothing for a cleanup pass to track; copying
/// an `Error` copies its code.
pub const Error = struct {
    /// Upstream's private `code: NonZeroU32` field.
    ///
    /// It cannot be spelled `code`, because Zig gives a struct's fields and its
    /// declarations one namespace and this type needs both the field and
    /// upstream's `fn code()`. It stays private the way upstream's does:
    /// `code()` is how a caller reads it.
    code_value: NonZeroU32,

    /// Codes below this point represent OS errors, i.e. positive `i32` values.
    /// Codes at or above this point, but below `CUSTOM_START`, are reserved
    /// for use by the `rand` and `getrandom` crates.
    pub const INTERNAL_START: u32 = 1 << 31;

    /// Codes at or above this point can be used by users to define their own
    /// custom errors.
    pub const CUSTOM_START: u32 = (1 << 31) + (1 << 30);

    /// Rust `impl From<NonZeroU32> for Error`, the only constructor this
    /// configuration exposes.
    ///
    /// The argument is already known to be non-zero, so this cannot fail and a
    /// zero never reaches it: `NonZeroU32.init` answers `null` for zero, which
    /// is where the rejection happens. Allocating nothing.
    pub fn from_code(nonzero: NonZeroU32) @This() {
        return .{ .code_value = nonzero };
    }

    /// The error code, Rust `Error::code`.
    ///
    /// In this configuration it always answers the code the value was built
    /// from. The optional stays because upstream's signature is an `Option`:
    /// the `std` configuration can hold an error carrying no code, and one
    /// shape serves both.
    pub fn code(self: @This()) ?NonZeroU32 {
        return self.code_value;
    }

    /// The raw OS error code, Rust `Error::raw_os_error`.
    ///
    /// Identical to `std::io::Error::raw_os_error` except that it works in
    /// `no_std` contexts. A code below `INTERNAL_START` is an OS error and is
    /// reported as the `i32` it stands for; a code at or above it belongs to
    /// `rand`, `getrandom` or the user, and answers `null`. Allocating nothing.
    pub fn raw_os_error(self: @This()) ?i32 {
        const value = self.code_value.value;
        if (value >= INTERNAL_START) return null;
        return @intCast(value);
    }

    /// Rust `Display for Error`: the `no_std`, no-`getrandom` arm,
    /// `write!(f, "error code {}", self.code)`.
    ///
    /// This is the native Zig `{f}` hook, so the same receiver serves
    /// `std.Io.Writer.print` and `r2z.format.write`. The writer is borrowed for
    /// the call and retains nothing, and its own failure — a short buffer
    /// included — comes back unchanged with the bytes written before it left in
    /// place.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("error code {d}", .{self.code_value.value});
    }

    /// Rust `Debug for Error`: the `no_std`, no-`getrandom` arm,
    /// `write!(f, "Error {{ code: {} }}", self.code)`.
    ///
    /// `Debug` has no `{f}` specifier; this is reachable through `{:?}`.
    pub fn formatDebug(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Error {{ code: {d} }}", .{self.code_value.value});
    }
};

test "INTERNAL_START and CUSTOM_START carry the upstream values" {
    // rand_core 0.5.1 src/error.rs: `1 << 31` and `(1 << 31) + (1 << 30)`.
    try std.testing.expectEqual(@as(u32, 0x8000_0000), Error.INTERNAL_START);
    try std.testing.expectEqual(@as(u32, 0xc000_0000), Error.CUSTOM_START);
    try std.testing.expectEqual(1 << 31, Error.INTERNAL_START);
    try std.testing.expectEqual((1 << 31) + (1 << 30), Error.CUSTOM_START);
    // The two boundaries are what the reserved bands are stated in terms of,
    // so the lower one has to stay below the upper one.
    try std.testing.expect(Error.INTERNAL_START < Error.CUSTOM_START);
}

test "the Error constructor rejects a zero code" {
    // Rust's `From<NonZeroU32>` takes a type with no zero in it, and this
    // takes the same, so there is no zero for the constructor to accept. The
    // refusal happens where a zero first becomes a value at all.
    try std.testing.expectEqual(@as(?NonZeroU32, null), NonZeroU32.init(0));
    try std.testing.expectEqual(
        NonZeroU32,
        @typeInfo(@TypeOf(Error.from_code)).@"fn".params[0].type.?,
    );

    // Nor can one be stored, so every value the constructor can produce reads
    // back as the non-zero code it was handed.
    for ([_]u32{ 1, 2, Error.INTERNAL_START, std.math.maxInt(u32) }) |value| {
        const failure = Error.from_code(NonZeroU32.init(value).?);
        const code = failure.code() orelse return error.ExpectedCode;
        try std.testing.expect(code.value != 0);
        try std.testing.expectEqual(value, code.value);
    }
}

test "code round-trips the code the Error was built from" {
    // Both ends of each band `raw_os_error` distinguishes, and both ends of the
    // whole `u32` range.
    const values = [_]u32{
        1,
        2,
        Error.INTERNAL_START - 1,
        Error.INTERNAL_START,
        Error.CUSTOM_START,
        std.math.maxInt(u32),
    };
    for (values) |value| {
        const code = NonZeroU32.init(value).?;
        const failure = Error.from_code(code);
        try std.testing.expectEqual(@as(?NonZeroU32, code), failure.code());
        try std.testing.expectEqual(value, failure.code().?.value);
    }
}

test "raw_os_error reports a code below INTERNAL_START and nothing at or above it" {
    const cases = [_]struct { code: u32, expected: ?i32 }{
        .{ .code = 1, .expected = 1 },
        .{ .code = 0x7fff_fffe, .expected = 0x7fff_fffe },
        .{ .code = Error.INTERNAL_START - 1, .expected = @as(i32, @intCast(Error.INTERNAL_START - 1)) },
        .{ .code = Error.INTERNAL_START, .expected = null },
        .{ .code = Error.INTERNAL_START + 1, .expected = null },
        .{ .code = Error.CUSTOM_START, .expected = null },
        .{ .code = std.math.maxInt(u32), .expected = null },
    };
    for (cases) |case| {
        const failure = Error.from_code(NonZeroU32.init(case.code).?);
        try std.testing.expectEqual(case.expected, failure.raw_os_error());
    }
}

test "Display and Debug render the code in decimal" {
    const format = @import("format.zig");
    const values = [_]u32{
        1,
        9,
        0x0bad_f00d,
        Error.INTERNAL_START,
        std.math.maxInt(u32),
    };
    for (values) |value| {
        const failure = Error.from_code(NonZeroU32.init(value).?);

        // The expected text is built by formatting the same code rather than
        // typed in, so a hexadecimal, octal or fixed-width rendering cannot
        // pass: `0x0bad_f00d` and `0xffffffff` are spelled differently in each
        // base.
        var expected_display: [64]u8 = undefined;
        var display_expected: std.Io.Writer = .fixed(&expected_display);
        try display_expected.print("error code {d}", .{value});
        var expected_debug: [64]u8 = undefined;
        var debug_expected: std.Io.Writer = .fixed(&expected_debug);
        try debug_expected.print("Error {{ code: {d} }}", .{value});

        var display_buffer: [64]u8 = undefined;
        var display: std.Io.Writer = .fixed(&display_buffer);
        try failure.format(&display);
        try std.testing.expectEqualStrings(display_expected.buffered(), display.buffered());

        var debug_buffer: [64]u8 = undefined;
        var debug: std.Io.Writer = .fixed(&debug_buffer);
        try failure.formatDebug(&debug);
        try std.testing.expectEqualStrings(debug_expected.buffered(), debug.buffered());

        // Both hooks are also reached through the Rust template, which is the
        // route a translated `format!("{}", err)` and `format!("{:?}", err)`
        // take.
        var template_buffer: [128]u8 = undefined;
        var templated: std.Io.Writer = .fixed(&template_buffer);
        try format.write(&templated, "{} {:?}", .{ failure, failure });
        var template_expected: [128]u8 = undefined;
        var expected_template: std.Io.Writer = .fixed(&template_expected);
        try expected_template.print(
            "error code {d} Error {{ code: {d} }}",
            .{ value, value },
        );
        try std.testing.expectEqualStrings(expected_template.buffered(), templated.buffered());
    }
}

test "Error is a value a Result carries and it owns nothing" {
    const Result = @import("result.zig").Result;

    // `RngCore::try_fill_bytes` returns `Result<(), Error>`, so the failure has
    // to be a value the union can hold rather than a tag it erases to.
    const failure: Result(void, Error) = .{ .Err = Error.from_code(NonZeroU32.init(7).?) };
    try std.testing.expect(failure.is_err());
    try std.testing.expect(!failure.is_ok());
    try std.testing.expectEqual(@as(u32, 7), failure.Err.code().?.value);

    // Nothing to release: the only field is a `NonZeroU32`, which is a `u32`,
    // so a copy costs the code it carries and a cleanup pass has nothing to do.
    try std.testing.expectEqual(@as(usize, 1), @typeInfo(Error).@"struct".fields.len);
    try std.testing.expectEqual(@sizeOf(NonZeroU32), @sizeOf(Error));
    try std.testing.expect(!@hasDecl(Error, "deinit"));
}
