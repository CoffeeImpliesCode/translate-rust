//! Consumer tests for the translated `zero-field-shapes` package.
//!
//! The fixture in `test/crates/zero-field-shapes/src/lib.rs` declares the three
//! ways a Rust struct can hold no field — `struct Unit;`, `struct Record {}` and
//! `struct Tuple();` — and one enum whose variants all hold no field. Every
//! assertion below reads the staged package's own declarations through Zig
//! reflection: field counts, sizes, and `@TypeOf` over real values. Nothing
//! matches emitted text, and nothing reimplements the crate, which computes no
//! values at all — it publishes types and the values built from them.
//!
//! Built like the `test/percent_encoding_consumer.zig` invocation in
//! `test/e2e_test.zig`, with the generated package root in place of the
//! percent-encoding one. `r2z` is passed because a staged root that needs the
//! runtime import needs it, and a root that does not is unaffected:
//!
//!     zig test --dep translated --dep r2z \
//!         -Mroot=test/zero_field_shapes_consumer.zig \
//!         --dep r2z \
//!         -Mtranslated=<staged>/src/root.zig \
//!         -Mr2z=r2z-core/src/root.zig

const std = @import("std");
const translated = @import("translated");

// The three struct forms, each named once so every test below reads the same
// nominal it is talking about.
const Unit = translated.Unit;
const Record = translated.Record;
const Tuple = translated.Tuple;

// The fieldless enum, which is the control: it carries no field either and is
// still not a zero-field struct.
const Choice = translated.Choice;

/// The fields of the struct type `T`. The `else` arm names what `T` turned
/// out to be, so a form that stopped arriving as a struct fails to build here
/// instead of passing an assertion written for a struct.
fn structFields(comptime T: type) []const std.builtin.Type.StructField {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.fields,
        else => @compileError("expected a struct type, found " ++ @typeName(T)),
    };
}

/// The fields of the enum type `T`, failing the same way for the same reason.
fn enumFields(comptime T: type) []const std.builtin.Type.EnumField {
    return switch (@typeInfo(T)) {
        .@"enum" => |info| info.fields,
        else => @compileError("expected an enum type, found " ++ @typeName(T)),
    };
}

/// The tag type of the enum `T`, which is what an enum occupies and nothing
/// more. The tag width itself is deliberately not pinned.
fn enumTagType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .@"enum" => |fields| fields.tag_type,
        else => @compileError("expected an enum type, found " ++ @typeName(T)),
    };
}

// Nothing but the nominal separates the three forms: no field, no tag and no
// size. So the type each declaration published is the whole claim, and it has
// to survive on its own.
test "the three zero-field struct forms are three distinct nominal types" {
    try std.testing.expect(@TypeOf(Unit{}) != @TypeOf(Record{}));
    try std.testing.expect(@TypeOf(Unit{}) != @TypeOf(Tuple{}));
    try std.testing.expect(@TypeOf(Record{}) != @TypeOf(Tuple{}));

    // Each value carries the type of the declaration it was built from, so a
    // use site that named one form while building another cannot pass.
    try std.testing.expect(@TypeOf(Unit{}) == Unit);
    try std.testing.expect(@TypeOf(Record{}) == Record);
    try std.testing.expect(@TypeOf(Tuple{}) == Tuple);

    // An erased empty type would satisfy nothing above if the comparisons were
    // structural. They are nominal: each of the three is its own declaration,
    // and none of them is `void` — the type an omitted return type means — nor
    // the anonymous `struct {}` written here.
    try std.testing.expect(@TypeOf(Unit{}) != void);
    try std.testing.expect(@TypeOf(Unit{}) != struct {});
    try std.testing.expect(@TypeOf(Record{}) != struct {});
    try std.testing.expect(@TypeOf(Tuple{}) != struct {});
}

// Each form reaches Zig as a struct with no member at all: nothing was
// invented to fill the declaration, and nothing was lost from it.
test "each zero-field struct form is an empty struct of size zero" {
    inline for (.{ Unit, Record, Tuple }) |T| {
        try std.testing.expectEqual(@as(usize, 0), structFields(T).len);
        try std.testing.expectEqual(@as(usize, 0), @sizeOf(T));
        try std.testing.expectEqual(@as(usize, 1), @alignOf(T));
    }
}

// A function that returns a form returns that form, not `void` and not one of
// the others. The fixture cannot make that claim about itself; the type of the
// call is the claim.
test "each nominal survives being returned" {
    try std.testing.expect(@TypeOf(translated.unit_value()) == Unit);
    try std.testing.expect(@TypeOf(translated.record_value()) == Record);
    try std.testing.expect(@TypeOf(translated.tuple_value()) == Tuple);
    try std.testing.expect(@TypeOf(translated.left_value()) == Choice);
}

// The parameter type and the return type of a round trip are the same nominal,
// so what went in comes back typed as what went in. Handing a `Record` to
// `unit_round_trip` would not compile, which is the assertion.
test "each nominal round-trips through a parameter and a return" {
    try std.testing.expect(
        @TypeOf(translated.unit_round_trip(translated.unit_value())) == Unit,
    );
    try std.testing.expect(
        @TypeOf(translated.record_round_trip(translated.record_value())) == Record,
    );
    try std.testing.expect(
        @TypeOf(translated.tuple_round_trip(translated.tuple_value())) == Tuple,
    );
    try std.testing.expect(
        @TypeOf(translated.choice_round_trip(translated.Choice.Right)) == Choice,
    );
}

// The variant handed to a call is the variant the call returns, which is a
// claim about the value and not about its type.
test "the enum variant a call was given is the variant it returns" {
    try std.testing.expectEqualStrings("Left", @tagName(translated.left_value()));
    try std.testing.expectEqualStrings(
        "Left",
        @tagName(translated.choice_round_trip(translated.Choice.Left)),
    );
    try std.testing.expectEqualStrings(
        "Right",
        @tagName(translated.choice_round_trip(translated.Choice.Right)),
    );
    try std.testing.expectEqualStrings(
        "Left",
        @tagName(translated.choice_round_trip(translated.left_value())),
    );
}

// One call, four arguments of four different nominal types. Each argument is
// checked against its own parameter type where it is written, so these lines
// compile only if all four stayed distinct on the way in; the number that
// comes back is the one the enum argument named, and that is what the
// comparisons claim.
test "one call accepts all four nominals as arguments" {
    try std.testing.expectEqual(@as(u8, 10), translated.shape_code(
        translated.unit_value(),
        translated.record_value(),
        translated.tuple_value(),
        translated.Choice.Left,
    ));
    try std.testing.expectEqual(@as(u8, 20), translated.shape_code(
        Unit{},
        Record{},
        Tuple{},
        translated.Choice.Right,
    ));
    try std.testing.expectEqual(@as(u8, 10), translated.shape_code(
        translated.unit_round_trip(translated.Unit{}),
        translated.record_round_trip(translated.Record{}),
        translated.tuple_round_trip(translated.Tuple{}),
        translated.left_value(),
    ));
}

// The control for the size assertions above. `Choice` is fieldless everywhere
// too, and it is still not an empty struct: it is inhabited, so it occupies
// its tag, it keeps both variant names, and it is a fifth nominal. Without it
// "size zero" would be satisfied by any zero-sized type at all.
test "the fieldless enum is inhabited and carries both variant names" {
    const fields = enumFields(Choice);
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("Left", fields[0].name);
    try std.testing.expectEqualStrings("Right", fields[1].name);

    // An enum occupies its tag and nothing else, so its size is the tag's.
    // The tag width is not asserted: a narrower tag would still satisfy this,
    // and only the emptiness of the structs above is under test.
    try std.testing.expect(@sizeOf(Choice) > 0);
    try std.testing.expectEqual(@sizeOf(Choice), @sizeOf(enumTagType(Choice)));

    try std.testing.expect(@TypeOf(translated.left_value()) != Unit);
    try std.testing.expect(@TypeOf(translated.left_value()) != Record);
    try std.testing.expect(@TypeOf(translated.left_value()) != Tuple);
}
