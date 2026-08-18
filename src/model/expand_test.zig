//! expand_test — unit tests for P6 built-in macro expansion.
//!
//! Pure C-free Zig tests running under `zig build test`.
//! Verifies macro kind classification, argument splitting with nested delimiter
//! support and quote literals, empty argument handling, and message formatters.

const std = @import("std");
const expand = @import("expand.zig");

test "identifyMacro classifies all built-in Rust macros" {
    // Basic unqualified names with and without '!'
    try std.testing.expectEqual(expand.MacroKind.assert, expand.identifyMacro("assert"));
    try std.testing.expectEqual(expand.MacroKind.assert, expand.identifyMacro("assert!"));
    try std.testing.expectEqual(expand.MacroKind.assert_eq, expand.identifyMacro("assert_eq"));
    try std.testing.expectEqual(expand.MacroKind.assert_eq, expand.identifyMacro("assert_eq!"));
    try std.testing.expectEqual(expand.MacroKind.assert_ne, expand.identifyMacro("assert_ne"));
    try std.testing.expectEqual(expand.MacroKind.assert_ne, expand.identifyMacro("assert_ne!"));
    try std.testing.expectEqual(expand.MacroKind.panic, expand.identifyMacro("panic"));
    try std.testing.expectEqual(expand.MacroKind.panic, expand.identifyMacro("panic!"));
    try std.testing.expectEqual(expand.MacroKind.vec, expand.identifyMacro("vec"));
    try std.testing.expectEqual(expand.MacroKind.vec, expand.identifyMacro("vec!"));
    try std.testing.expectEqual(expand.MacroKind.unreachable_, expand.identifyMacro("unreachable"));
    try std.testing.expectEqual(expand.MacroKind.unreachable_, expand.identifyMacro("unreachable!"));
    try std.testing.expectEqual(expand.MacroKind.todo, expand.identifyMacro("todo"));
    try std.testing.expectEqual(expand.MacroKind.todo, expand.identifyMacro("todo!"));
    try std.testing.expectEqual(expand.MacroKind.unimplemented, expand.identifyMacro("unimplemented"));
    try std.testing.expectEqual(expand.MacroKind.unimplemented, expand.identifyMacro("unimplemented!"));
    try std.testing.expectEqual(expand.MacroKind.println, expand.identifyMacro("println"));
    try std.testing.expectEqual(expand.MacroKind.println, expand.identifyMacro("println!"));
    try std.testing.expectEqual(expand.MacroKind.eprintln, expand.identifyMacro("eprintln"));
    try std.testing.expectEqual(expand.MacroKind.eprintln, expand.identifyMacro("eprintln!"));
    try std.testing.expectEqual(expand.MacroKind.format, expand.identifyMacro("format"));
    try std.testing.expectEqual(expand.MacroKind.format, expand.identifyMacro("format!"));

    // Path-qualified built-in macros
    try std.testing.expectEqual(expand.MacroKind.panic, expand.identifyMacro("core::panic!"));
    try std.testing.expectEqual(expand.MacroKind.panic, expand.identifyMacro("std::panic!"));
    try std.testing.expectEqual(expand.MacroKind.vec, expand.identifyMacro("alloc::vec::vec!"));
    try std.testing.expectEqual(expand.MacroKind.todo, expand.identifyMacro("core::todo!"));
    try std.testing.expectEqual(expand.MacroKind.unimplemented, expand.identifyMacro("core::unimplemented!"));

    // Unknown or user-defined custom macros
    try std.testing.expectEqual(expand.MacroKind.custom, expand.identifyMacro("my_macro"));
    try std.testing.expectEqual(expand.MacroKind.custom, expand.identifyMacro("my_macro!"));
    try std.testing.expectEqual(expand.MacroKind.custom, expand.identifyMacro("custom::rule!"));
    try std.testing.expectEqual(expand.MacroKind.custom, expand.identifyMacro("concat!"));
    try std.testing.expectEqual(expand.MacroKind.custom, expand.identifyMacro("env!"));
}

test "splitMacroArgs correctly splits comma-separated arguments respecting nesting" {
    const alloc = std.testing.allocator;

    // Direct requirement case: (1 + 2, foo(3, 4), "a, b") -> ["1 + 2", "foo(3, 4)", "\"a, b\""]
    {
        const raw = "(1 + 2, foo(3, 4), \"a, b\")";
        const args = try expand.splitMacroArgs(alloc, raw);
        defer alloc.free(args);

        try std.testing.expectEqual(@as(usize, 3), args.len);
        try std.testing.expectEqualStrings("1 + 2", args[0]);
        try std.testing.expectEqualStrings("foo(3, 4)", args[1]);
        try std.testing.expectEqualStrings("\"a, b\"", args[2]);
    }

    // Deeply nested parentheses, brackets, and braces
    {
        const raw = "([1, 2, 3], { let x = (4, 5); x }, bar(baz(6, 7)))";
        const args = try expand.splitMacroArgs(alloc, raw);
        defer alloc.free(args);

        try std.testing.expectEqual(@as(usize, 3), args.len);
        try std.testing.expectEqualStrings("[1, 2, 3]", args[0]);
        try std.testing.expectEqualStrings("{ let x = (4, 5); x }", args[1]);
        try std.testing.expectEqualStrings("bar(baz(6, 7))", args[2]);
    }

    // Brackets wrapper [...]
    {
        const raw = "[a, b, c]";
        const args = try expand.splitMacroArgs(alloc, raw);
        defer alloc.free(args);

        try std.testing.expectEqual(@as(usize, 3), args.len);
        try std.testing.expectEqualStrings("a", args[0]);
        try std.testing.expectEqualStrings("b", args[1]);
        try std.testing.expectEqualStrings("c", args[2]);
    }
}

test "splitMacroArgs handles empty arguments" {
    const alloc = std.testing.allocator;

    {
        const args = try expand.splitMacroArgs(alloc, "()");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 0), args.len);
    }

    {
        const args = try expand.splitMacroArgs(alloc, "[]");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 0), args.len);
    }

    {
        const args = try expand.splitMacroArgs(alloc, "{}");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 0), args.len);
    }

    {
        const args = try expand.splitMacroArgs(alloc, "");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 0), args.len);
    }

    {
        const args = try expand.splitMacroArgs(alloc, "   ");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 0), args.len);
    }

    {
        const args = try expand.splitMacroArgs(alloc, "(   )");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 0), args.len);
    }
}

test "macro expansion helpers produce correct messages" {
    const alloc = std.testing.allocator;

    // Empty args produces empty message
    {
        const empty_args = [_][]const u8{};
        const msg = try expand.expandPanicMessage(alloc, &empty_args);
        defer alloc.free(msg);
        try std.testing.expectEqualStrings("", msg);
    }

    // Single quoted string literal strips enclosing quotes
    {
        const args = [_][]const u8{"\"not yet implemented\""};
        const msg = try expand.expandPanicMessage(alloc, &args);
        defer alloc.free(msg);
        try std.testing.expectEqualStrings("not yet implemented", msg);
    }

    // Single non-quoted token passes through
    {
        const args = [_][]const u8{"custom_panic_msg"};
        const msg = try expand.expandPanicMessage(alloc, &args);
        defer alloc.free(msg);
        try std.testing.expectEqualStrings("custom_panic_msg", msg);
    }

    // Multiple arguments format joined
    {
        const args = [_][]const u8{ "\"assertion failed: {} > {}\"", "left", "right" };
        const msg = try expand.expandPanicMessage(alloc, &args);
        defer alloc.free(msg);
        try std.testing.expectEqualStrings("assertion failed: {} > {}, left, right", msg);
    }
}

test "splitMacroArgs handles edge cases: escaped quotes, char literals, and trailing commas" {
    const alloc = std.testing.allocator;

    // Escaped quotes inside strings
    {
        const raw = "(\"hello \\\"world\\\"\", 42)";
        const args = try expand.splitMacroArgs(alloc, raw);
        defer alloc.free(args);

        try std.testing.expectEqual(@as(usize, 2), args.len);
        try std.testing.expectEqualStrings("\"hello \\\"world\\\"\"", args[0]);
        try std.testing.expectEqualStrings("42", args[1]);
    }

    // Character literals containing commas or quotes
    {
        const raw = "(',', '\\'', '\"', 100)";
        const args = try expand.splitMacroArgs(alloc, raw);
        defer alloc.free(args);

        try std.testing.expectEqual(@as(usize, 4), args.len);
        try std.testing.expectEqualStrings("','", args[0]);
        try std.testing.expectEqualStrings("'\\''", args[1]);
        // args[1] is the 4-byte sequence `'`, `\`, `'`, `'`
        try std.testing.expectEqual(@as(usize, 4), args[1].len);
        try std.testing.expectEqualStrings("'\"'", args[2]);
        try std.testing.expectEqualStrings("100", args[3]);
    }

    // Trailing comma
    {
        const raw = "(x, y, z,)";
        const args = try expand.splitMacroArgs(alloc, raw);
        defer alloc.free(args);

        try std.testing.expectEqual(@as(usize, 3), args.len);
        try std.testing.expectEqualStrings("x", args[0]);
        try std.testing.expectEqualStrings("y", args[1]);
        try std.testing.expectEqualStrings("z", args[2]);
    }
}

test "isTestingAssert correctly identifies test assertion macros" {
    try std.testing.expect(expand.isTestingAssert(.assert));
    try std.testing.expect(expand.isTestingAssert(.assert_eq));
    try std.testing.expect(expand.isTestingAssert(.assert_ne));
    try std.testing.expect(!expand.isTestingAssert(.panic));
    try std.testing.expect(!expand.isTestingAssert(.vec));
    try std.testing.expect(!expand.isTestingAssert(.unreachable_));
    try std.testing.expect(!expand.isTestingAssert(.todo));
    try std.testing.expect(!expand.isTestingAssert(.unimplemented));
    try std.testing.expect(!expand.isTestingAssert(.println));
    try std.testing.expect(!expand.isTestingAssert(.eprintln));
    try std.testing.expect(!expand.isTestingAssert(.format));
    try std.testing.expect(!expand.isTestingAssert(.custom));
}
