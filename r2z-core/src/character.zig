//! Allocation-free adapters for Rust `char` and UTF-8 primitives.
//!
//! `to_digit` follows `library/core/src/char/methods.rs`: it asserts radix
//! 2 through 36, then recognizes only ASCII digits and letters. UTF-8 error
//! offsets and lengths follow `library/core/src/str/validations.rs`; Zig's
//! decoder is used for start-byte widths, with Rust's stricter F4 maximum.

const std = @import("std");
const Result = @import("result.zig").Result;

/// The first error reported while validating a UTF-8 byte slice.
pub const Utf8Error = struct {
    valid_up_to: usize,
    error_len: ?u8,
};

pub fn from_utf8(bytes: []const u8) Result([]const u8, Utf8Error) {
    if (validate_utf8(bytes)) |err| return .{ .Err = err };
    return .{ .Ok = bytes };
}

/// The caller must supply valid UTF-8, as required by Rust's unchecked conversion.
pub inline fn from_utf8_unchecked(bytes: []const u8) []const u8 {
    return bytes;
}

/// Convert an ASCII digit or letter to its value in `radix`.
///
/// Rust panics outside the inclusive radix range 2...36.
pub fn to_digit(value: u21, radix: u32) ?u32 {
    if (radix < 2 or radix > 36) {
        @panic("to_digit: invalid radix -- radix must be in the range 2 to 36 inclusive");
    }

    const digit: u32 = switch (value) {
        '0'...'9' => @as(u32, value - '0'),
        'A'...'Z' => @as(u32, value - 'A') + 10,
        'a'...'z' => @as(u32, value - 'a') + 10,
        else => return null,
    };
    if (digit >= radix) return null;
    return digit;
}

/// Return Rust-compatible detail for the first malformed UTF-8 sequence.
///
/// A null `error_len` means that a valid sequence prefix reached end of input.
pub fn validate_utf8(bytes: []const u8) ?Utf8Error {
    var index: usize = 0;
    while (index < bytes.len) {
        const remaining = bytes[index..];
        const first = remaining[0];
        if (first < 0x80) {
            index += 1;
            continue;
        }

        // Rust's width table rejects continuation bytes and C0/C1 as
        // one-byte errors. Zig's width helper intentionally accepts C0/C1.
        if (first < 0xC2) return .{ .valid_up_to = index, .error_len = 1 };
        // Rust rejects F5..FF as a one-byte error. Zig accepts F5..F7 as
        // four-byte starts, so cap the lead byte before consulting its table.
        if (first > 0xF4) return .{ .valid_up_to = index, .error_len = 1 };
        const sequence_len = std.unicode.utf8ByteSequenceLength(first) catch {
            return .{ .valid_up_to = index, .error_len = 1 };
        };
        switch (sequence_len) {
            2 => {
                if (remaining.len < 2) return .{ .valid_up_to = index, .error_len = null };
                if (!is_continuation_byte(remaining[1])) {
                    return .{ .valid_up_to = index, .error_len = 1 };
                }
                index += 2;
            },
            3 => {
                if (remaining.len < 2) return .{ .valid_up_to = index, .error_len = null };
                const second_valid = switch (first) {
                    0xE0 => remaining[1] >= 0xA0 and remaining[1] <= 0xBF,
                    0xE1...0xEC, 0xEE...0xEF => is_continuation_byte(remaining[1]),
                    0xED => remaining[1] >= 0x80 and remaining[1] <= 0x9F,
                    else => unreachable,
                };
                if (!second_valid) return .{ .valid_up_to = index, .error_len = 1 };
                if (remaining.len < 3) return .{ .valid_up_to = index, .error_len = null };
                if (!is_continuation_byte(remaining[2])) {
                    return .{ .valid_up_to = index, .error_len = 2 };
                }
                index += 3;
            },
            4 => {
                if (remaining.len < 2) return .{ .valid_up_to = index, .error_len = null };
                const second_valid = switch (first) {
                    0xF0 => remaining[1] >= 0x90 and remaining[1] <= 0xBF,
                    0xF1...0xF3 => is_continuation_byte(remaining[1]),
                    0xF4 => remaining[1] >= 0x80 and remaining[1] <= 0x8F,
                    else => unreachable,
                };
                if (!second_valid) return .{ .valid_up_to = index, .error_len = 1 };
                if (remaining.len < 3) return .{ .valid_up_to = index, .error_len = null };
                if (!is_continuation_byte(remaining[2])) {
                    return .{ .valid_up_to = index, .error_len = 2 };
                }
                if (remaining.len < 4) return .{ .valid_up_to = index, .error_len = null };
                if (!is_continuation_byte(remaining[3])) {
                    return .{ .valid_up_to = index, .error_len = 3 };
                }
                index += 4;
            },
            else => unreachable,
        }
    }
    return null;
}

fn is_continuation_byte(byte: u8) bool {
    return byte >= 0x80 and byte <= 0xBF;
}

test "to_digit handles supported radix boundaries" {
    try std.testing.expectEqual(@as(?u32, 0), to_digit('0', 2));
    try std.testing.expectEqual(@as(?u32, 1), to_digit('1', 2));
    try std.testing.expectEqual(@as(?u32, null), to_digit('2', 2));
    try std.testing.expectEqual(@as(?u32, 10), to_digit('A', 36));
    try std.testing.expectEqual(@as(?u32, 35), to_digit('Z', 36));
    try std.testing.expectEqual(@as(?u32, 35), to_digit('z', 36));
    try std.testing.expectEqual(@as(?u32, null), to_digit('G', 16));
    try std.testing.expectEqual(@as(?u32, null), to_digit(':', 36));
    try std.testing.expectEqual(@as(?u32, null), to_digit('１', 10));
}

test "validate_utf8 accepts scalar boundary encodings" {
    const cases = [_][]const u8{
        "\xC2\x80",
        "\xDF\xBF",
        "\xE0\xA0\x80",
        "\xED\x9F\xBF",
        "\xEE\x80\x80",
        "\xF0\x90\x80\x80",
        "\xF4\x8F\xBF\xBF",
    };
    for (cases) |bytes| {
        try std.testing.expect(validate_utf8(bytes) == null);
    }
}

test "validate_utf8 distinguishes malformed sequence lengths" {
    const cases = [_]struct {
        bytes: []const u8,
        expected: Utf8Error,
    }{
        .{ .bytes = "ok\x80", .expected = .{ .valid_up_to = 2, .error_len = 1 } },
        .{ .bytes = "ok\xC0", .expected = .{ .valid_up_to = 2, .error_len = 1 } },
        .{ .bytes = "ok\xC1", .expected = .{ .valid_up_to = 2, .error_len = 1 } },
        .{ .bytes = "ok\xED\xA0\x80", .expected = .{ .valid_up_to = 2, .error_len = 1 } },
        .{ .bytes = "ok\xF0\x8F\xBF\xBF", .expected = .{ .valid_up_to = 2, .error_len = 1 } },
        .{ .bytes = "ok\xF4\x90\x80\x80", .expected = .{ .valid_up_to = 2, .error_len = 1 } },
        .{ .bytes = "ok\xF5", .expected = .{ .valid_up_to = 2, .error_len = 1 } },
        .{ .bytes = "ok\xE1\x80" ++ "A", .expected = .{ .valid_up_to = 2, .error_len = 2 } },
        .{ .bytes = "ok\xF1\x80\x80" ++ "A", .expected = .{ .valid_up_to = 2, .error_len = 3 } },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, validate_utf8(case.bytes).?);
    }
}

test "validate_utf8 reports truncated sequence prefixes" {
    const cases = [_][]const u8{
        "ok\xC2",
        "ok\xE1",
        "ok\xE1\x80",
        "ok\xF1",
        "ok\xF1\x80",
        "ok\xF1\x80\x80",
    };
    const expected: Utf8Error = .{ .valid_up_to = 2, .error_len = null };
    for (cases) |bytes| {
        try std.testing.expectEqual(expected, validate_utf8(bytes).?);
    }
}
