//! Rust grammar via tree-sitter: parse Rust source into a lossless syntax
//! tree. Syntax-only — no name resolution, types, or macro expansion; those
//! belong to the semantic sidecar (see notes/research/parsing-tooling.md).

const std = @import("std");
const ts = @import("tree_sitter");

/// tree-sitter-rust v0.24.2, vendored from tree-sitter/tree-sitter-rust
/// @ 77a3747266f4d621d0757825e6b11edcbf991ca5 (MIT). See vendor/.
extern fn tree_sitter_rust() callconv(.c) *const ts.Language;

/// Language handle for the Rust grammar (a static; never null).
pub fn language() *const ts.Language {
    return tree_sitter_rust();
}

/// An owned tree-sitter Parser bound to the Rust grammar.
/// Create one per parse; `deinit` releases it.
pub const Parser = struct {
    parser: *ts.Parser,

    pub fn init() !Parser {
        const parser = ts.Parser.create();
        errdefer parser.destroy();
        try parser.setLanguage(language());
        return .{ .parser = parser };
    }

    pub fn deinit(self: *Parser) void {
        self.parser.destroy();
        self.* = undefined;
    }

    /// Parse `source` into a syntax tree. Caller destroys the tree. Returns
    /// null only on out-of-memory or an interrupted parse.
    pub fn parse(self: *Parser, source: []const u8) ?*ts.Tree {
        return self.parser.parseString(source, null);
    }
};

const minimal_fixture = @embedFile("fixtures/minimal.rs");

test "parse a minimal rust fn" {
    var parser = try Parser.init();
    defer parser.deinit();

    const tree = (parser.parse("pub fn main() {}")).?;
    defer tree.destroy();

    const root = tree.rootNode();
    try std.testing.expectEqualStrings("source_file", root.kind());
    try std.testing.expect(!root.hasError());

    var found_fn = false;
    var i: u32 = 0;
    while (root.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), "function_item")) found_fn = true;
    }
    try std.testing.expect(found_fn);
}

test "parse struct + enum + fn items" {
    var parser = try Parser.init();
    defer parser.deinit();

    const tree = (parser.parse(
        \\struct Point { x: i32, y: i32 }
        \\enum Shape { Circle(f64), Rect { width: f64, height: f64 } }
        \\fn area(s: Shape) -> f64 { match s { Shape::Circle(r) => r * r * 3.14, _ => 0.0 } }
    )).?;
    defer tree.destroy();

    const root = tree.rootNode();
    try std.testing.expect(!root.hasError());

    var counts: [3]u32 = .{ 0, 0, 0 };
    var i: u32 = 0;
    while (root.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), "struct_item")) counts[0] += 1;
        if (std.mem.eql(u8, child.kind(), "enum_item")) counts[1] += 1;
        if (std.mem.eql(u8, child.kind(), "function_item")) counts[2] += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), counts[0]);
    try std.testing.expectEqual(@as(u32, 1), counts[1]);
    try std.testing.expectEqual(@as(u32, 1), counts[2]);
}

test "parse the minimal.rs fixture" {
    var parser = try Parser.init();
    defer parser.deinit();

    const tree = (parser.parse(minimal_fixture)).?;
    defer tree.destroy();

    const root = tree.rootNode();
    try std.testing.expect(!root.hasError());
    // The fixture declares Point's constructor, so we expect an impl block
    // plus the top-level struct/enum/fn items.
    try std.testing.expect(root.namedChildCount() >= 5);
}

test "reports errors on malformed input" {
    var parser = try Parser.init();
    defer parser.deinit();

    const tree = (parser.parse("fn main( {")).?;
    defer tree.destroy();

    try std.testing.expect(tree.rootNode().hasError());
}

test "node navigation preserves byte spans and absent children" {
    const source = "fn café() {} fn other() {}";
    var parser = try Parser.init();
    defer parser.deinit();
    const tree = parser.parse(source).?;
    defer tree.destroy();

    const root = tree.rootNode();
    try std.testing.expect(!root.hasError());
    try std.testing.expectEqual(@as(u32, 2), root.namedChildCount());
    const first = root.namedChild(0).?;
    const name = first.childByFieldName("name").?;
    try std.testing.expect(name.isNamed());
    try std.testing.expectEqualStrings("café", source[name.startByte()..name.endByte()]);
    try std.testing.expectEqualStrings("name", first.fieldNameForNamedChild(0).?);
    try std.testing.expect(root.fieldNameForNamedChild(0) == null);
    try std.testing.expect(first.fieldNameForNamedChild(first.namedChildCount()) == null);

    const punctuation = first.childByFieldName("body").?.child(0).?;
    try std.testing.expect(!punctuation.isNamed());
    try std.testing.expectEqualStrings("{", source[punctuation.startByte()..punctuation.endByte()]);

    const second = first.nextNamedSibling().?;
    try std.testing.expect(!first.eql(second));
    try std.testing.expect(first.eql(second.prevNamedSibling().?));
    const second_name = second.childByFieldName("name").?;
    try std.testing.expectEqualStrings("other", source[second_name.startByte()..second_name.endByte()]);
    const previous_name = second.prevNamedSibling().?.childByFieldName("name").?;
    try std.testing.expectEqualStrings("café", source[previous_name.startByte()..previous_name.endByte()]);
    try std.testing.expect(first.prevNamedSibling() == null);
    try std.testing.expect(second.nextNamedSibling() == null);
    try std.testing.expect(root.namedChild(2) == null);
    try std.testing.expect(first.childByFieldName("return_type") == null);
}

test "unicode escapes with underscore separators lex as one token" {
    const source =
        \\fn escapes() {
        \\    let astral = '\u{1_F980}';
        \\    let max = '\u{10_FFFF}';
        \\    let padded = '\u{1_F980__}';
        \\    let text = "a\u{1_F980} b\u{10_FFFF} c\u{1_F980__}";
        \\}
    ;
    const char_spellings = [_][]const u8{
        "'\\u{1_F980}'",
        "'\\u{10_FFFF}'",
        "'\\u{1_F980__}'",
    };
    const escape_spellings = [_][]const u8{
        "\\u{1_F980}",
        "\\u{10_FFFF}",
        "\\u{1_F980__}",
    };
    var parser = try Parser.init();
    defer parser.deinit();
    const tree = parser.parse(source).?;
    defer tree.destroy();
    const root = tree.rootNode();
    try std.testing.expect(!root.hasError());
    const function = root.namedChild(0).?;
    try std.testing.expectEqualStrings("function_item", function.kind());
    const body = function.childByFieldName("body").?;
    try std.testing.expectEqual(@as(u32, char_spellings.len + 1), body.namedChildCount());

    for (char_spellings, 0..) |spelling, index| {
        const value = body.namedChild(@intCast(index)).?.childByFieldName("value").?;
        try std.testing.expectEqualStrings("char_literal", value.kind());
        try std.testing.expectEqualStrings(spelling, source[value.startByte()..value.endByte()]);
    }
    const string = body.namedChild(char_spellings.len).?.childByFieldName("value").?;
    try std.testing.expectEqualStrings("string_literal", string.kind());
    var escape_index: usize = 0;
    var child_index: u32 = 0;
    while (string.namedChild(child_index)) |child| : (child_index += 1) {
        if (!std.mem.eql(u8, child.kind(), "escape_sequence")) continue;
        try std.testing.expectEqualStrings(
            escape_spellings[escape_index],
            source[child.startByte()..child.endByte()],
        );
        escape_index += 1;
    }
    try std.testing.expectEqual(escape_spellings.len, escape_index);
}
