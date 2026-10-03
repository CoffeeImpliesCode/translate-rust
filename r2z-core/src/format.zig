//! Rust `format!`, `write!` and `ToString::to_string` → one `std.Io.Writer`
//! route.
//!
//! A translated `impl Display for T` lowers to a native Zig `format` method,
//! `format(self: T, writer: *std.Io.Writer) std.Io.Writer.Error!void`, so the
//! same value renders through Zig's own `{f}` specifier and through this
//! module's Rust-compatible template. The receiver shape, the writer, and the
//! failure channel are identical on both routes; only the template syntax
//! differs. `Debug` has no `{f}` specifier, so a translated
//! `impl Debug for T` lowers to `formatDebug` with the same signature and is
//! reachable only through `{:?}` here.
//!
//! The two Rust templates this module accepts are `{}` for `Display` and `{:?}`
//! for `Debug`. Each position requires its own hook and neither stands in for
//! the other: `{}` reaches `format` and `{:?}` reaches `formatDebug`, so a type
//! implementing only one of them is refused in the other position rather than
//! rendered with the implementation that happens to exist. A `char` has no hook
//! of either kind and is rendered by this module itself, escaping under Rust's
//! rules for `{:?}`.
//!
//! What a translated `impl` block produces is one declaration on the type
//! itself, and it is the only thing this module ever calls on a value it does
//! not render itself:
//!
//! ```zig
//! pub fn format(self: *const T, writer: *std.Io.Writer) std.Io.Writer.Error!void
//! pub fn formatDebug(self: *const T, writer: *std.Io.Writer) std.Io.Writer.Error!void
//! ```
//!
//! Three facts about that declaration are the protocol. The name is reserved
//! for the trait: a translated `Display::fmt` is `format` and a translated
//! `Debug::fmt` is `formatDebug`, and an inherent method that wanted one of
//! those names is emitted under a mangled one (`format__Type`) instead, so no
//! method of the translated crate can take the name a position looks for. The
//! declaration is public, because `@hasDecl` sees a private one only from the
//! file that declares it, and a hook another module cannot reach is a hook
//! `to_string` cannot call. The receiver is a value this module holds by name,
//! so the shared `*const T` the emitter writes and the by-value one the
//! runtime types declare are answered from the same call.
//!
//! Every shape a translated impl lands on satisfies that requirement, because
//! the emitter writes the hook onto the declaration the Rust aggregate lowers
//! to, and every such declaration is one of the kinds `writeValue` asks
//! `@hasDecl` about: a `struct` (record, tuple struct, or unit struct), a
//! `union` (tagged or untagged), or a plain `enum`. `Shape` enumerates one
//! receiver of each kind carrying both hooks, and each is answered in the
//! position that asks for it.
//!
//! A value that carries no hook is one this module renders itself — an
//! integer, a `bool`, a `char`, or the `str` behind a Rust `&str` — or one
//! Rust never gives the trait to, and the second is refused rather than
//! guessed at. Every refusal names its reason, because the one receiver shape
//! this module cannot tell apart is `[]const u8`: Rust's `Debug for str`
//! prints it quoted and `Debug for [u8]` prints it as an element list, and
//! both reach this module as the same Zig type.
//!
//! `write` stores no allocator and allocates no storage of its own. A writer or
//! hook may allocate according to its own contract.
//!
//! `toString` makes the render's storage once and hands that one block to the
//! `String` it returns, so the caller releases it exactly once. The blocks the
//! writer replaced while growing are released by that growth, not by the
//! caller.

const std = @import("std");
const printable = @import("format_printable.zig");
const alloc = @import("alloc.zig");
const io = @import("io.zig");
const Mode = enum { display, debug };

/// Write `template` to `writer` with Rust's `format!` placeholder syntax.
///
/// `{}` renders an argument through its `Display` implementation, which is a
/// `format` method, and `{d}` renders an integer. `{:?}` renders a `char` with
/// Rust's debug escapes and any other value through its `Debug`
/// implementation, which is a `formatDebug` method. `{{` and `}}` write one
/// literal brace each. An unsupported specification, a value whose position
/// lacks its own hook, and an argument count that disagrees with the
/// template's placeholders are all compile errors, never a silent default.
/// A writer failure leaves its written prefix intact. This function allocates
/// no storage of its own; writers and hooks control their own storage.
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
/// `format` method and writer every `format!` expansion uses, and therefore
/// the same `{f}` route Zig itself calls.
///
/// `gpa` allocates the render's storage once and releases nothing on the way
/// out; the one block the writer built is moved into the returned `String`,
/// which the caller releases with `deinit(gpa)`, exactly once. A second
/// release reaches the emptied `String` and frees nothing. The blocks the
/// writer replaced while growing are released by that growth, so the caller
/// releases only the final one. On `error.WriteFailed` the partially built
/// buffer is released before the error returns, so a failing `format` leaks
/// nothing and leaves no string behind.
pub fn toString(gpa: std.mem.Allocator, value: anytype) std.Io.Writer.Error!alloc.String {
    var writer: std.Io.Writer.Allocating = .init(gpa);
    errdefer writer.deinit();
    try write(&writer.writer, "{}", .{value});
    var bytes: alloc.Vec(u8) = writer.toArrayList();
    return alloc.String.from_utf8_unchecked(&bytes);
}

/// Renders one argument in the position its template asked for.
///
/// Every branch here is decided at comptime: the receiver's type, the position,
/// and the declarations the receiver carries are all known before the body
/// runs, so a receiver this module cannot render the way Rust renders it is a
/// compile error naming the reason rather than a default spelling. `value` is
/// a parameter and therefore an lvalue, which is what lets one call answer
/// both hook shapes: a `*const T` receiver is reached by address and a
/// by-value one by copy.
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
            if (pointer.size == .slice and pointer.child == u8) {
                // A Rust `&str` arrives as a byte slice, and `str` is the only
                // sequence Rust gives a `Display`, so `{}` writes the bytes.
                // `Debug` has no answer this receiver can be given: `Debug for
                // str` prints the bytes quoted, `Debug for [u8]` prints them
                // as an element list, and both are this one Zig type.
                if (mode == .display) return writer.writeAll(value);
                @compileError(
                    "Rust debug of a byte sequence is ambiguous here: []const u8 is " ++
                        "`str`, whose Debug is the quoted spelling, and `[u8]`, whose Debug " ++
                        "is the element list. Hold the value in r2z.alloc.String or " ++
                        "r2z.alloc.CowStr to name one.",
                );
            }
            if (pointer.size == .one) {
                const child = @typeInfo(pointer.child);
                if (child == .array and child.array.child == u8 and child.array.sentinel_ptr != null and mode == .display) {
                    return writer.writeAll(value[0..child.array.len]);
                }
                return writeValue(writer, value.*, mode);
            }
            @compileError(
                "Rust formatting has no runtime rendering for the pointer type " ++
                    @typeName(Value) ++ ": a sequence renders as its elements and a " ++
                    "borrowed string as its bytes, and neither reaches this arm",
            );
        },
        .@"struct", .@"union", .@"enum" => {
            // Each position reaches its own hook. `{f}` and `{}` share the
            // `format` a translated `Display` lowers to; `{:?}` reaches the
            // `formatDebug` a translated `Debug` lowers to. Neither position
            // accepts the other's hook, so a `Debug`-only type is not a
            // `Display` and a `Display`-only type is not a `Debug`.
            if (mode == .display and @hasDecl(Value, "format")) return value.format(writer);
            if (mode == .debug and @hasDecl(Value, "formatDebug")) return value.formatDebug(writer);
            const hook = if (mode == .display) "format" else "formatDebug";
            const spec = if (mode == .display) "`{}`" else "`{:?}`";
            @compileError(
                "Rust formatting requires the corresponding trait implementation: " ++
                    @typeName(Value) ++ " declares no " ++ hook ++ ", which " ++ spec ++ " calls",
            );
        },
        .float, .comptime_float => @compileError(
            "Rust spells a float differently in each position: `{}` writes 1 and `{:?}` " ++
                "writes 1.0. This module renders neither, and a float that has to render " ++
                "needs a type carrying both hooks rather than a bare receiver.",
        ),
        else => @compileError(
            "Rust formatting has no runtime rendering for " ++ @typeName(Value) ++ " in this position",
        ),
    }
}

/// Writes the Rust `Debug for str` spelling of valid UTF-8 `input`.
///
/// Quotes and escapes the borrowed bytes without allocating or retaining them.
/// On `error.WriteFailed`, the writer retains the prefix already written.
pub fn writeDebugString(writer: *std.Io.Writer, input: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    var cursor: usize = 0;
    while (cursor < input.len) {
        const length = std.unicode.utf8ByteSequenceLength(input[cursor]) catch
            @panic("invalid Rust str");
        const end = cursor + length;
        if (end > input.len) @panic("invalid Rust str");
        const scalar = std.unicode.utf8Decode(input[cursor..end]) catch
            @panic("invalid Rust str");
        switch (scalar) {
            0 => try writer.writeAll("\\0"),
            '\t' => try writer.writeAll("\\t"),
            '\r' => try writer.writeAll("\\r"),
            '\n' => try writer.writeAll("\\n"),
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            else => if (printable.isPrintable(scalar)) {
                try writer.writeAll(input[cursor..end]);
            } else {
                try writer.print("\\u{{{x}}}", .{scalar});
            },
        }
        cursor = end;
    }
    try writer.writeByte('"');
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

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
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

test "one Display hook serves Zig's {f} and the Rust template" {
    const gpa = std.testing.allocator;

    var string = try alloc.String.from_str(gpa, "owned text");
    defer string.deinit(gpa);
    var cow = alloc.CowStr.from_owned(&string);
    defer cow.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), string.as_bytes().len);

    var failure = io.Error.new(.PermissionDenied, "read access denied");
    var dynamic = io.DynError.init(&failure);

    var buffer: [128]u8 = undefined;
    var native: std.Io.Writer = .fixed(&buffer);
    try native.print("native {f} {f} {f} {f}", .{ cow, alloc.CowStr.from_borrowed("borrowed"), failure, dynamic });
    try std.testing.expectEqualStrings(
        "native owned text borrowed read access denied read access denied",
        native.buffered(),
    );

    var compatible_buffer: [128]u8 = undefined;
    var compatible: std.Io.Writer = .fixed(&compatible_buffer);
    try write(&compatible, "native {} {} {} {}", .{ cow, alloc.CowStr.from_borrowed("borrowed"), failure, dynamic });
    try std.testing.expectEqualStrings(native.buffered(), compatible.buffered());
    try std.testing.expect(dynamic.source() == null);
}

test "a truncated writer fails through a Display hook and keeps its prefix" {
    const gpa = std.testing.allocator;
    var string = try alloc.String.from_str(gpa, "0123456789");
    defer string.deinit(gpa);

    var buffer: [4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.WriteFailed, write(&writer, "<{}>", .{string}));
    try std.testing.expectEqualStrings("<012", writer.buffered());
}

test "Display and Debug each reach their own hook" {
    const Both = struct {
        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            _ = self;
            try writer.writeAll("display");
        }

        pub fn formatDebug(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            _ = self;
            try writer.writeAll("debug");
        }
    };
    const DisplayOnly = struct {
        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            _ = self;
            try writer.writeAll("display");
        }
    };
    const DebugOnly = struct {
        pub fn formatDebug(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            _ = self;
            try writer.writeAll("debug");
        }
    };

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write(&writer, "{} {:?} {} {:?}", .{ Both{}, Both{}, DisplayOnly{}, DebugOnly{} });
    try std.testing.expectEqualStrings("display debug display debug", writer.buffered());
}

/// The declarations a translated crate's formatting impls produce.
///
/// Each is written the way the emitter writes it — a shared `*const` receiver,
/// a public hook, the runtime writer — so a test over these types tests the
/// protocol `writeValue` reaches rather than a shape this module invented.
/// `Tagged` is a payload-carrying Rust enum and `Choice` a field-free one,
/// which is the difference between a tagged `union` and a plain `enum`, and
/// `Format` carries the mangled name an inherent method is given so that the
/// Display hook keeps the plain one.
const Emitted = struct {
    pub const Choice = enum {
        Only,

        pub fn format(self: *const Choice, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            _ = self;
            try writer.writeAll("only");
        }
    };

    pub const Tagged = union(enum) {
        InvalidHexCharacter: struct { c: u21, index: usize },
        OddLength: void,

        pub fn format(self: *const Tagged, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self.*) {
                .InvalidHexCharacter => |payload| try write(
                    writer,
                    "Invalid character {:?} at position {}",
                    .{ payload.c, payload.index },
                ),
                .OddLength => try writer.writeAll("Odd number of digits"),
            }
        }

        pub fn formatDebug(self: *const Tagged, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self.*) {
                .InvalidHexCharacter => |payload| try write(
                    writer,
                    "InvalidHexCharacter {{ c: {:?}, index: {d} }}",
                    .{ payload.c, payload.index },
                ),
                .OddLength => try writer.writeAll("OddLength"),
            }
        }
    };

    pub const Format = struct {
        value: i32,

        pub fn format__Format(self: *const Format) i32 {
            return self.value;
        }

        pub fn format(self: *const Format, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try write(writer, "display={}", .{self.value});
        }

        pub fn formatDebug(self: *const Format, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try write(writer, "ApiFormat({})", .{self.value});
        }
    };
};

/// Every aggregate shape a translated `impl Display` / `impl Debug` lands on.
///
/// A translated trait impl becomes one declaration on the type itself, and
/// `writeValue` refuses any receiver that does not carry the declaration the
/// position asks for. These are the type shapes a Rust aggregate lowers to, so
/// they are exactly the receivers the gate has to accept: `Named` a record,
/// `Tuple` a Rust tuple struct, `Unit` a unit struct, `Tagged` a
/// payload-carrying enum, `Untagged` a Rust `union`, and `Choice` a fieldless
/// enum. Each carries both hooks, under the shared `*const` receiver the
/// emitter writes.
///
/// `Tuple` and `Untagged` reach the shared `write` route from inside a hook,
/// which is also what pins the `{{` / `}}` escape through a nested template.
const Shape = struct {
    pub const Named = struct {
        value: i32,

        pub fn format(self: *const Named, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("named({d})", .{self.value});
        }

        pub fn formatDebug(self: *const Named, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try write(writer, "Named {{ value: {d} }}", .{self.value});
        }
    };

    // A Rust tuple struct lowers to a named record rather than staying an
    // anonymous tuple struct, because Zig cannot attach a declaration to an
    // anonymous tuple struct and the hook is a declaration on the type.
    pub const Tuple = struct {
        count: i32,
        flag: bool,

        pub fn format(self: *const Tuple, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try write(writer, "tuple({},{})", .{ self.count, self.flag });
        }

        pub fn formatDebug(self: *const Tuple, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try write(writer, "Tuple {{ count: {}, flag: {} }}", .{ self.count, self.flag });
        }
    };

    pub const Unit = struct {
        pub fn format(_: *const Unit, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll("unit");
        }

        pub fn formatDebug(_: *const Unit, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll("Unit");
        }
    };

    pub const Tagged = union(enum) {
        Absent,
        Present: i32,

        pub fn format(self: *const Tagged, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self.*) {
                .Absent => try writer.writeAll("absent"),
                .Present => |payload| try writer.print("present({d})", .{payload}),
            }
        }

        pub fn formatDebug(self: *const Tagged, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self.*) {
                .Absent => try writer.writeAll("Absent"),
                .Present => |payload| try writer.print("Present({d})", .{payload}),
            }
        }
    };

    pub const Untagged = union {
        number: i32,
        flag: bool,

        pub fn format(self: *const Untagged, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self.*) {
                .number => |payload| try writer.print("un:{d}", .{payload}),
                .flag => |payload| try write(writer, "un:{}", .{payload}),
            }
        }

        pub fn formatDebug(self: *const Untagged, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self.*) {
                .number => |payload| try writer.print("Untagged({d})", .{payload}),
                .flag => |payload| try write(writer, "Untagged({})", .{payload}),
            }
        }
    };

    pub const Choice = enum {
        Left,
        Right,

        pub fn format(_: *const Choice, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll("choice");
        }

        pub fn formatDebug(_: *const Choice, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll("Choice");
        }
    };
};

test "a translated Display hook formats a struct, a tagged enum, and a fieldless enum" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write(&writer, "{} {} {}", .{
        Emitted.Format{ .value = 37 },
        Emitted.Tagged{ .InvalidHexCharacter = .{ .c = '\n', .index = 5 } },
        Emitted.Choice.Only,
    });
    try std.testing.expectEqualStrings(
        "display=37 Invalid character '\\n' at position 5 only",
        writer.buffered(),
    );
}

test "a translated Debug hook renders through {:?} and never through {}" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write(&writer, "{:?} {:?}", .{
        Emitted.Format{ .value = 37 },
        Emitted.Tagged{ .InvalidHexCharacter = .{ .c = '\n', .index = 5 } },
    });
    try std.testing.expectEqualStrings(
        "ApiFormat(37) InvalidHexCharacter { c: '\\n', index: 5 }",
        writer.buffered(),
    );

    // A type that declares a Display hook alone answers `{}` and nothing else.
    var choice_buffer: [64]u8 = undefined;
    var choice_writer: std.Io.Writer = .fixed(&choice_buffer);
    try write(&choice_writer, "{}", .{Emitted.Choice.Only});
    try std.testing.expectEqualStrings("only", choice_writer.buffered());
}

test "one translated hook serves Zig's {f} and the Rust template" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.print("{f}|{f}|{f}", .{
        Emitted.Format{ .value = 37 },
        Emitted.Choice.Only,
        Emitted.Tagged{ .OddLength = @as(void, {}) },
    });
    try std.testing.expectEqualStrings("display=37|only|Odd number of digits", writer.buffered());
}

test "toString renders every shape a translated Display hook is emitted on" {
    const gpa = std.testing.allocator;

    var format = try toString(gpa, Emitted.Format{ .value = 37 });
    defer format.deinit(gpa);
    try std.testing.expectEqualStrings("display=37", format.as_str());

    var tagged = try toString(gpa, Emitted.Tagged{ .InvalidHexCharacter = .{ .c = '\n', .index = 5 } });
    defer tagged.deinit(gpa);
    try std.testing.expectEqualStrings("Invalid character '\\n' at position 5", tagged.as_str());

    var choice = try toString(gpa, Emitted.Choice.Only);
    defer choice.deinit(gpa);
    try std.testing.expectEqualStrings("only", choice.as_str());

    // A receiver that arrives by address is the same receiver: the one-item
    // pointer arm hands the hook the value the pointer addressed.
    var held = Emitted.Format{ .value = 37 };
    var addressed = try toString(gpa, &held);
    defer addressed.deinit(gpa);
    try std.testing.expectEqualStrings("display=37", addressed.as_str());
}

test "a borrowed &str argument is written, copied, and never retained" {
    const gpa = std.testing.allocator;

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write(&writer, "<{}>", .{"borrowed"});
    try std.testing.expectEqualStrings("<borrowed>", writer.buffered());

    var rendered = try toString(gpa, "borrowed");
    defer rendered.deinit(gpa);
    try std.testing.expectEqualStrings("borrowed", rendered.as_str());

    // The value that carries the hooks renders the same bytes the bare borrow
    // does, from the same borrowed storage.
    var cow = alloc.CowStr.from_borrowed("borrowed");
    defer cow.deinit(gpa);
    var from_cow = try toString(gpa, cow);
    defer from_cow.deinit(gpa);
    try std.testing.expectEqualStrings(rendered.as_str(), from_cow.as_str());

    // The owned result outlives the storage the receiver borrowed: `{}` of a
    // `&str` copies the bytes into the result rather than aliasing them.
    var source: [11]u8 = undefined;
    @memcpy(source[0..], "local slice");
    var copied = try toString(gpa, source[0..]);
    defer copied.deinit(gpa);
    @memset(source[0..], 'x');
    try std.testing.expectEqualStrings("local slice", copied.as_str());
}

// The result borrows the caller-owned buffer.
fn renderDebug(buffer: []u8, value: anytype) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try write(&writer, "{:?}", .{value});
    return writer.buffered();
}

// Expected bytes were checked against Rust's Debug implementation. The String
// stays owned by the test; rendering neither consumes it nor allocates storage.
test "Rust debug quotes and escapes String bytes" {
    const gpa = std.testing.allocator;
    var buffer: [128]u8 = undefined;
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "", .expected = "\"\"" },
        .{ .input = "plain bytes", .expected = "\"plain bytes\"" },
        .{ .input = "\x00\t\r\n\\\"'", .expected = "\"\\0\\t\\r\\n\\\\\\\"'\"" },
        .{ .input = "caf\xc3\xa9", .expected = "\"caf\xc3\xa9\"" },
        .{ .input = "\x07", .expected = "\"\\u{7}\"" },
        .{ .input = "\xf0\x9f\x99\x82", .expected = "\"\xf0\x9f\x99\x82\"" },
        .{ .input = "\xe2\x80\x8d", .expected = "\"\\u{200d}\"" },
        .{ .input = "\xc2\xa0", .expected = "\"\\u{a0}\"" },
    };
    for (cases) |case| {
        var string = try alloc.String.from_str(gpa, case.input);
        defer string.deinit(gpa);
        try std.testing.expectEqualStrings(case.expected, try renderDebug(&buffer, string));
    }
}

test "Rust debug quotes and escapes both CowStr arms" {
    const gpa = std.testing.allocator;
    var buffer: [128]u8 = undefined;

    try std.testing.expectEqualStrings(
        "\"borrowed\"",
        try renderDebug(&buffer, alloc.CowStr.from_borrowed("borrowed")),
    );
    try std.testing.expectEqualStrings(
        "\"borrowed\\tbytes\"",
        try renderDebug(&buffer, alloc.CowStr.from_borrowed("borrowed\tbytes")),
    );

    // The owned arm renders the same bytes the Display arm does, quoted and
    // escaped the same way, and the string it came from is left empty.
    var owned = try alloc.String.from_str(gpa, "owned\x07bytes");
    var cow = alloc.CowStr.from_owned(&owned);
    defer cow.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), owned.as_bytes().len);
    try std.testing.expectEqualStrings("\"owned\\u{7}bytes\"", try renderDebug(&buffer, cow));
}

test "a short writer fails part-way through a debug render and keeps its prefix" {
    const gpa = std.testing.allocator;
    var owned = try alloc.String.from_str(gpa, "plain bytes");
    var cow = alloc.CowStr.from_owned(&owned);
    defer cow.deinit(gpa);

    // Four bytes hold the opening quote and `pla`, so the residue is the
    // quoted prefix a Display render of the same value would not have written.
    var buffer: [4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.WriteFailed, write(&writer, "{:?}", .{cow}));
    try std.testing.expectEqualStrings("\"pla", writer.buffered());
}

test "toString frees the partial buffer when a dynamic handle fails part-way" {
    const HalfWritten = struct {
        renders: *usize,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            self.renders.* += 1;
            try writer.writeAll("half");
            return error.WriteFailed;
        }
    };

    var renders: usize = 0;
    var failure: HalfWritten = .{ .renders = &renders };
    const dynamic = io.DynError.init(&failure);

    // `std.testing.allocator` fails the test if the half-built buffer leaks.
    try std.testing.expectError(error.WriteFailed, toString(std.testing.allocator, dynamic));
    // One render proves the handle reached the live error instead of a copy.
    try std.testing.expectEqual(@as(usize, 1), renders);
}

test "toString frees the partial buffer when Display fails part-way" {
    const HalfWritten = struct {
        pub fn format(_: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
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

test "every shape a translated Display hook lands on answers the {} position" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    // One receiver per aggregate a Rust `impl Display` can be written on. Each
    // carries the hook `format.zig` requires, so each is a value this module
    // renders rather than a compile error naming the missing declaration.
    try write(&writer, "{} {} {} {} {} {}", .{
        Shape.Named{ .value = 37 },
        Shape.Tuple{ .count = 2, .flag = true },
        Shape.Unit{},
        Shape.Tagged{ .Absent = @as(void, {}) },
        Shape.Untagged{ .number = 5 },
        Shape.Choice.Left,
    });
    try std.testing.expectEqualStrings(
        "named(37) tuple(2,true) unit absent un:5 choice",
        writer.buffered(),
    );
}

test "every shape a translated Debug hook lands on answers the {:?} position" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    // The same six shapes through `formatDebug`, which is a different
    // declaration on the same types rather than the Display hook standing in.
    try write(&writer, "{:?} {:?} {:?} {:?} {:?} {:?}", .{
        Shape.Named{ .value = 37 },
        Shape.Tuple{ .count = 2, .flag = true },
        Shape.Unit{},
        Shape.Tagged{ .Absent = @as(void, {}) },
        Shape.Untagged{ .number = 5 },
        Shape.Choice.Right,
    });
    try std.testing.expectEqualStrings(
        "Named { value: 37 } Tuple { count: 2, flag: true } Unit Absent Untagged(5) Choice",
        writer.buffered(),
    );
}

test "toString renders every shape a translated Display hook lands on" {
    const gpa = std.testing.allocator;

    // `to_string()` is the one route every generated call lands on, so each
    // shape a translated `Display` can be written on has to reach its hook
    // through here and not only through a template this module never emits.
    var named = try toString(gpa, Shape.Named{ .value = 37 });
    defer named.deinit(gpa);
    try std.testing.expectEqualStrings("named(37)", named.as_str());

    var tuple = try toString(gpa, Shape.Tuple{ .count = 2, .flag = true });
    defer tuple.deinit(gpa);
    try std.testing.expectEqualStrings("tuple(2,true)", tuple.as_str());

    var unit = try toString(gpa, Shape.Unit{});
    defer unit.deinit(gpa);
    try std.testing.expectEqualStrings("unit", unit.as_str());

    var absent = try toString(gpa, Shape.Tagged{ .Absent = @as(void, {}) });
    defer absent.deinit(gpa);
    try std.testing.expectEqualStrings("absent", absent.as_str());

    var present = try toString(gpa, Shape.Tagged{ .Present = 9 });
    defer present.deinit(gpa);
    try std.testing.expectEqualStrings("present(9)", present.as_str());

    var untagged = try toString(gpa, Shape.Untagged{ .number = 5 });
    defer untagged.deinit(gpa);
    try std.testing.expectEqualStrings("un:5", untagged.as_str());

    var choice = try toString(gpa, Shape.Choice.Left);
    defer choice.deinit(gpa);
    try std.testing.expectEqualStrings("choice", choice.as_str());

    // A receiver that arrives by address is answered from the same call: the
    // one-item pointer arm hands the hook the value the pointer addressed.
    var held = Shape.Tagged{ .Present = 4 };
    var addressed = try toString(gpa, &held);
    defer addressed.deinit(gpa);
    try std.testing.expectEqualStrings("present(4)", addressed.as_str());
}

test "toString hands its buffer to the String and the caller releases it once" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    const before = tracking.allocations;
    var rendered = try toString(gpa, Shape.Named{ .value = 37 });
    const freed = tracking.deallocations;
    rendered.deinit(gpa);
    // Exactly one allocation became exactly one release: the buffer the
    // writer built was moved into the String rather than copied beside it
    // with the writer still holding the original.
    try std.testing.expectEqual(@as(usize, 1), tracking.allocations - before);
    try std.testing.expectEqual(@as(usize, 1), tracking.deallocations - freed);

    // A second release reaches the emptied String and frees nothing, so the
    // ownership the caller was handed can only be released once. The backing
    // `std.testing.allocator` panics on a double free of the block.
    rendered.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), tracking.deallocations - freed);
    try std.testing.expectEqual(@as(usize, 0), rendered.len());
}

test "toString releases a grown render whole rather than leaving the writer's blocks behind" {
    const Wide = struct {
        pub fn format(self: *const @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            _ = self;
            // Enough bytes that the allocating writer cannot hold the render
            // in the block it first asked for, so growth has to reallocate
            // before the render completes.
            var written: usize = 0;
            while (written < 512) : (written += 10) try writer.writeAll("0123456789");
        }
    };

    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    var rendered = try toString(gpa, Wide{});
    try std.testing.expectEqual(@as(usize, 512), rendered.len());

    const freed = tracking.deallocations;
    // The grown buffer is the one the caller releases: the blocks the writer
    // replaced on the way there were released by the growth itself, and the
    // final one is released exactly here. `std.testing.allocator` fails the
    // test if any replaced block leaked, so one release is the whole story.
    try std.testing.expectEqual(@as(usize, 1), tracking.deallocations - freed);
}
