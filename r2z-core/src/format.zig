const std = @import("std");
const printable = @import("format_printable.zig");
const alloc = @import("alloc.zig");
const Mode = enum { display, debug };

pub fn write(writer: *std.Io.Writer, comptime template: []const u8, args: anytype) std.Io.Writer.Error!void {
    const info = @typeInfo(@TypeOf(args));
    if (info != .@"struct" or (!info.@"struct".is_tuple and info.@"struct".fields.len != 0)) {
        @compileError("Rust format arguments must be a tuple");
    }
    comptime var cursor: usize = 0;
    comptime var argument: usize = 0;
    inline while (cursor < template.len) {
        comptime var end = cursor;
        inline while (end < template.len and template[end] != '{' and template[end] != '}') : (end += 1) {}
        if (end != cursor) try writer.writeAll(template[cursor..end]);
        if (end == template.len) break;
        if (end + 1 < template.len and template[end + 1] == template[end]) {
            try writer.writeByte(template[end]);
            cursor = end + 2;
            continue;
        }
        if (template[end] == '}') @compileError("unmatched closing Rust format brace");
        const close = comptime std.mem.indexOfScalarPos(u8, template, end + 1, '}') orelse
            @compileError("unmatched opening Rust format brace");
        const spec = template[end + 1 .. close];
        const mode: Mode = comptime if (spec.len == 0)
            .display
        else if (std.mem.eql(u8, spec, ":?"))
            .debug
        else
            @compileError("unsupported Rust format specification");
        if (argument >= info.@"struct".fields.len) @compileError("missing Rust format argument");
        try writeValue(writer, args[argument], mode);
        argument += 1;
        cursor = close + 1;
    }
    if (argument != info.@"struct".fields.len) @compileError("unused Rust format argument");
}

/// Rust `ToString::to_string`: render `value` through its `Display`
/// implementation and return the result as owned storage.
///
/// This deliberately reuses `write` with the `"{}"` template instead of
/// introducing a second formatting route: the receiver reaches the same
/// `Display::fmt` writer every `format!` expansion uses. A partially written
/// buffer is released by `errdefer`, so a failing `fmt` leaks nothing.
pub fn toString(gpa: std.mem.Allocator, value: anytype) std.Io.Writer.Error!alloc.String {
    var writer: std.Io.Writer.Allocating = .init(gpa);
    errdefer writer.deinit();
    try write(&writer.writer, "{}", .{value});
    var bytes: alloc.Vec(u8) = writer.toArrayList();
    return alloc.String.from_utf8_unchecked(&bytes);
}

fn writeValue(writer: *std.Io.Writer, value: anytype, comptime mode: Mode) std.Io.Writer.Error!void {
    const Value = @TypeOf(value);
    switch (@typeInfo(Value)) {
        .int => |integer| {
            if (integer.bits == 21 and integer.signedness == .unsigned) {
                if (mode == .debug) return writeDebugChar(writer, value);
                return writeChar(writer, value);
            }
            return writer.print("{d}", .{value});
        },
        .comptime_int => return writer.print("{d}", .{value}),
        .bool => return writer.writeAll(if (value) "true" else "false"),
        .pointer => |pointer| {
            if (pointer.size == .slice and pointer.child == u8 and mode == .display) {
                return writer.writeAll(value);
            }
            if (pointer.size == .one) {
                const child = @typeInfo(pointer.child);
                if (child == .array and child.array.child == u8 and child.array.sentinel_ptr != null and mode == .display) {
                    return writer.writeAll(value[0..child.array.len]);
                }
                return writeValue(writer, value.*, mode);
            }
            @compileError("unsupported Rust formatting pointer");
        },
        .@"struct", .@"union", .@"enum" => {
            if (mode == .display and @hasDecl(Value, "fmt")) return value.fmt(writer);
            @compileError("Rust formatting requires the corresponding trait implementation");
        },
        else => @compileError("unsupported Rust formatting value"),
    }
}

fn writeChar(writer: *std.Io.Writer, value: u21) std.Io.Writer.Error!void {
    var bytes: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(value, &bytes) catch @panic("invalid Rust char");
    try writer.writeAll(bytes[0..len]);
}

fn writeDebugChar(writer: *std.Io.Writer, value: u21) std.Io.Writer.Error!void {
    if (value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) @panic("invalid Rust char");
    try writer.writeByte('\'');
    switch (value) {
        0 => try writer.writeAll("\\0"),
        '\t' => try writer.writeAll("\\t"),
        '\r' => try writer.writeAll("\\r"),
        '\n' => try writer.writeAll("\\n"),
        '\'' => try writer.writeAll("\\'"),
        '\\' => try writer.writeAll("\\\\"),
        else => if (printable.isPrintable(value)) {
            try writeChar(writer, value);
        } else {
            try writer.print("\\u{{{x}}}", .{value});
        },
    }
    try writer.writeByte('\'');
}

test "Rust formatting preserves debug chars, display values, and escaped braces" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const character: u21 = '\n';
    const index: usize = 513;
    try write(&writer, "{{Invalid character {:?} at position {}}}", .{ &character, &index });
    try std.testing.expectEqualStrings("{Invalid character '\\n' at position 513}", writer.buffered());
}

test "Rust debug chars preserve Unicode printability and scalar encoding" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write(&writer, "{:?} {:?} {}", .{ @as(u21, 0x301), @as(u21, 0x200d), @as(u21, 0x1f642) });
    try std.testing.expectEqualStrings("'\\u{301}' '\\u{200d}' \xf0\x9f\x99\x82", writer.buffered());
}

test "Rust formatting propagates writer failure" {
    var buffer: [3]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.WriteFailed, write(&writer, "abc{}", .{@as(u8, 7)}));
    try std.testing.expectEqualStrings("abc", writer.buffered());
}

test "toString renders Display output into owned storage" {
    const Point = struct {
        x: i32,

        pub fn fmt(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("({d})", .{self.x});
        }
    };

    const gpa = std.testing.allocator;

    var rendered = try toString(gpa, Point{ .x = 7 });
    defer rendered.deinit(gpa);
    try std.testing.expectEqualStrings("(7)", rendered.as_str());

    // A `&str` receiver copies its bytes; the borrow is not retained.
    var copied = try toString(gpa, "borrowed");
    defer copied.deinit(gpa);
    try std.testing.expectEqualStrings("borrowed", copied.as_str());

    // An empty render is an empty owned string, never a null or undefined
    // slice pointer.
    var empty = try toString(gpa, "");
    defer empty.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), empty.len());
    try std.testing.expectEqualStrings("", empty.as_bytes());
}

test "toString frees the partial buffer when Display fails part-way" {
    const HalfWritten = struct {
        pub fn fmt(_: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll("partial");
            return error.WriteFailed;
        }
    };

    // `std.testing.allocator` fails the test if the half-built buffer leaks.
    try std.testing.expectError(
        error.WriteFailed,
        toString(std.testing.allocator, HalfWritten{}),
    );
}
