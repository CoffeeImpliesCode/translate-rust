//! Consumer tests for the translated `percent-encoding` package.
//!
//! One test per rustdoc example in `test/crates/percent-encoding/src/lib.rs`,
//! each keeping the original expected value verbatim. Every expectation is a
//! claim about the package's own output: nothing here reimplements the crate's
//! encoding, decoding, or set arithmetic, and no test reads printed text.
//!
//! Built like the `test/compat_consumer.zig` invocation in `test/e2e_test.zig`,
//! with the generated package root in place of the compat one. The root module
//! imports `r2z` itself, so it needs its own `--dep r2z`:
//!
//!     zig test --dep translated --dep r2z \
//!         -Mroot=test/percent_encoding_consumer.zig \
//!         --dep r2z -Mtranslated=<generated>/src/root.zig \
//!         -Mr2z=r2z-core/src/root.zig

const std = @import("std");
const r2z = @import("r2z");
const translated = @import("translated");

/// The fragment percent-encode set both `AsciiSet` examples build:
/// `&CONTROLS.add(b' ').add(b'"').add(b'<').add(b'>').add(b'`')`.
const FRAGMENT = translated.CONTROLS.add(' ').add('"').add('<').add('>').add('`');

/// The `%XX` escape of `byte`, in the uppercase hexadecimal the crate's own
/// table uses. Spelled out here so the expectation comes from the
/// specification rather than from the function under test.
fn escapeOf(byte: u8, buffer: *[3]u8) []const u8 {
    const digits: []const u8 = "0123456789ABCDEF";
    buffer[0] = '%';
    buffer[1] = digits[byte >> 4];
    buffer[2] = digits[byte & 0x0f];
    return buffer[0..];
}

/// <https://url.spec.whatwg.org/#fragment-percent-encode-set>: the C0 controls
/// and DEL inherited from `CONTROLS`, plus the five bytes `FRAGMENT` adds, and
/// no other ASCII byte.
fn fragmentSetHas(byte: u8) bool {
    return byte < 0x20 or byte == 0x7f or switch (byte) {
        ' ', '"', '<', '>', '`' => true,
        else => false,
    };
}

// The module-level example: the set is built the way the crate documents it,
// and encoding the documented string over it yields the documented bytes.
test "module example: the fragment set escapes the space and the brackets" {
    const gpa = std.testing.allocator;
    var rendered = try r2z.format.toString(
        gpa,
        translated.utf8_percent_encode("foo <bar>", &FRAGMENT),
    );
    defer rendered.deinit(gpa);
    try std.testing.expectEqualStrings("foo%20%3Cbar%3E", rendered.as_str());
}

// The `AsciiSet` example only constructs the constant, so the membership it
// means to express is checked here byte by byte: every C0 control, DEL, and
// the five added bytes are escaped, and no other ASCII byte is.
test "AsciiSet add chain extends CONTROLS with exactly the fragment set" {
    var escape: [3]u8 = undefined;
    var buffer: [4]u8 = undefined;
    for (0..128) |index| {
        const byte: u8 = @intCast(index);
        var writer: std.Io.Writer = .fixed(&buffer);
        try r2z.format.write(&writer, "{}", .{translated.percent_encode(&.{byte}, &FRAGMENT)});
        if (fragmentSetHas(byte)) {
            try std.testing.expectEqualStrings(escapeOf(byte, &escape), writer.buffered());
        } else {
            try std.testing.expectEqualSlices(u8, &.{byte}, writer.buffered());
        }
    }
}

// The `percent_encode_byte` example maps every byte of `"foo bar"` and collects
// the escapes into one string.
test "percent_encode_byte escapes each byte of foo bar on its own" {
    const gpa = std.testing.allocator;
    const input: []const u8 = "foo bar";
    var encoded = r2z.alloc.String.new();
    defer encoded.deinit(gpa);
    for (input) |byte| {
        try encoded.push_str(gpa, translated.percent_encode_byte(byte));
    }
    try std.testing.expectEqualStrings("%66%6F%6F%20%62%61%72", encoded.as_str());
}

// The `percent_encode` example, rendered through the same `Display` route the
// original `.to_string()` takes.
test "percent_encode renders foo bar? through the non-alphanumeric set" {
    const gpa = std.testing.allocator;
    var rendered = try r2z.format.toString(
        gpa,
        translated.percent_encode("foo bar?", translated.NON_ALPHANUMERIC),
    );
    defer rendered.deinit(gpa);
    try std.testing.expectEqualStrings("foo%20bar%3F", rendered.as_str());
}

// The `utf8_percent_encode` example expects the same bytes as `percent_encode`
// over the byte string, and a non-ASCII character is escaped one UTF-8 byte at
// a time rather than dropped or replaced.
test "utf8_percent_encode agrees with percent_encode over a UTF-8 string" {
    const gpa = std.testing.allocator;
    var rendered = try r2z.format.toString(
        gpa,
        translated.utf8_percent_encode("foo bar?", translated.NON_ALPHANUMERIC),
    );
    defer rendered.deinit(gpa);
    try std.testing.expectEqualStrings("foo%20bar%3F", rendered.as_str());

    var non_ascii = try r2z.format.toString(
        gpa,
        translated.utf8_percent_encode("caf\xc3\xa9", translated.NON_ALPHANUMERIC),
    );
    defer non_ascii.deinit(gpa);
    try std.testing.expectEqualStrings("caf%C3%A9", non_ascii.as_str());
}

// The `percent_decode` example. The input carries percent sequences, so the
// decoded result owns storage rather than borrowing the input, and the
// consumer releases it.
test "percent_decode reverses percent encoding through decode_utf8" {
    const gpa = std.testing.allocator;
    const decode = translated.percent_decode("foo%20bar%3f");
    const decoded = try decode.decode_utf8(gpa);
    try std.testing.expect(decoded == .Ok);

    var text = decoded.Ok;
    defer text.deinit(gpa);
    try std.testing.expect(text == .Owned);
    try std.testing.expectEqualStrings("foo bar?", text.as_ref());
}

test "strict UTF8 decoding borrows unchanged input and rejects invalid borrowed and owned bytes" {
    const gpa = std.testing.allocator;
    const input: []const u8 = "plain";
    const result = try translated.percent_decode(input).decode_utf8(gpa);
    try std.testing.expect(result == .Ok);
    var text = result.Ok;
    defer text.deinit(gpa);
    try std.testing.expect(text == .Borrowed);
    try std.testing.expectEqualStrings(input, text.as_ref());
    try std.testing.expect(text.as_ref().ptr == input.ptr);

    const invalid_inputs = [_][]const u8{ "\xff", "%FF" };
    for (invalid_inputs) |invalid_input| {
        const invalid = try translated.percent_decode(invalid_input).decode_utf8(gpa);
        try std.testing.expect(invalid == .Err);
        try std.testing.expectEqual(@as(usize, 0), invalid.Err.valid_up_to);
    }
}

test "lossy UTF8 decoding owns repaired or decoded text and preserves valid borrowed storage" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { input: []const u8, expected: []const u8, owned: bool }{
        .{ .input = "plain", .expected = "plain", .owned = false },
        .{ .input = "a%20b", .expected = "a b", .owned = true },
        .{ .input = "\xff", .expected = "\xef\xbf\xbd", .owned = true },
        .{ .input = "%FF", .expected = "\xef\xbf\xbd", .owned = true },
    };
    for (cases) |case| {
        var text = try translated.percent_decode(case.input).decode_utf8_lossy(gpa);
        defer text.deinit(gpa);
        try std.testing.expectEqual(case.owned, text == .Owned);
        try std.testing.expectEqualStrings(case.expected, text.as_ref());
        if (!case.owned) try std.testing.expect(text.as_ref().ptr == case.input.ptr);
    }
}

test "AsciiSet removal clears high chunk bits without changing neighbouring controls" {
    const reduced = translated.CONTROLS.remove(31).remove(127);
    const cases = [_]struct { byte: u8, expected: []const u8 }{
        .{ .byte = 31, .expected = "\x1f" },
        .{ .byte = 127, .expected = "\x7f" },
        .{ .byte = 0, .expected = "%00" },
        .{ .byte = 30, .expected = "%1E" },
    };
    for (cases) |case| {
        var buffer: [4]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try r2z.format.write(&writer, "{}", .{translated.percent_encode(&.{case.byte}, &reduced)});
        try std.testing.expectEqualStrings(case.expected, writer.buffered());
    }
}
