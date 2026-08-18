//! Built-in macro expansion module for Rust to Zig translation.
//!
//! Provides macro kind classification, argument token splitting respecting nested
//! delimiters and quote literals, and helper expansions for testing and panic macros.

const std = @import("std");

/// Built-in Rust macro kinds recognized by translate-rust.
pub const MacroKind = enum {
    assert,
    assert_eq,
    assert_ne,
    panic,
    vec,
    unreachable_,
    todo,
    unimplemented,
    println,
    eprintln,
    format,
    custom,
};

/// Identify the MacroKind from a macro name or invocation path.
/// Handles names with or without trailing '!' and module qualifiers (e.g. "core::panic!").
pub fn identifyMacro(name: []const u8) MacroKind {
    var ident: []const u8 = name;
    if (std.mem.lastIndexOf(u8, ident, "::")) |idx| {
        ident = ident[idx + 2 ..];
    }
    if (std.mem.endsWith(u8, ident, "!")) {
        ident = ident[0 .. ident.len - 1];
    }
    ident = std.mem.trim(u8, ident, " \t\r\n");

    if (std.mem.eql(u8, ident, "assert")) return .assert;
    if (std.mem.eql(u8, ident, "assert_eq")) return .assert_eq;
    if (std.mem.eql(u8, ident, "assert_ne")) return .assert_ne;
    if (std.mem.eql(u8, ident, "panic")) return .panic;
    if (std.mem.eql(u8, ident, "vec")) return .vec;
    if (std.mem.eql(u8, ident, "unreachable")) return .unreachable_;
    if (std.mem.eql(u8, ident, "todo")) return .todo;
    if (std.mem.eql(u8, ident, "unimplemented")) return .unimplemented;
    if (std.mem.eql(u8, ident, "println")) return .println;
    if (std.mem.eql(u8, ident, "eprintln")) return .eprintln;
    if (std.mem.eql(u8, ident, "format")) return .format;
    return .custom;
}

/// Returns true if the macro is a testing assertion (assert, assert_eq, assert_ne).
pub fn isTestingAssert(kind: MacroKind) bool {
    return switch (kind) {
        .assert, .assert_eq, .assert_ne => true,
        else => false,
    };
}

/// Returns the index of the closing single quote for a char literal whose
/// opening single quote is at `start`, or `null` if the literal is unterminated
/// (e.g. a Rust lifetime like `'a` in an argument position). Handles escapes
/// (`\'`, `'\n'`, `'\u{...}'`, ...) so an escaped quote is not treated as the
/// terminator.
fn findCharEnd(s: []const u8, start: usize) ?usize {
    if (start + 2 >= s.len) return null;
    var i: usize = start + 1;
    if (s[i] == '\\') {
        i += 1;
        if (i < s.len and s[i] == 'u') {
            while (i < s.len and s[i] != '}') : (i += 1) {}
            if (i >= s.len) return null;
            i += 1;
        } else if (i < s.len) {
            i += 1;
        }
    } else {
        i += 1;
    }
    if (i < s.len and s[i] == '\'') return i;
    return null;
}

/// Helper function to check if raw tokens are fully enclosed by a matching delimiter pair.
fn getEnclosedContent(raw_tokens: []const u8) []const u8 {
    const trimmed: []const u8 = std.mem.trim(u8, raw_tokens, " \t\r\n");
    if (trimmed.len < 2) return trimmed;

    const first: u8 = trimmed[0];
    const last: u8 = trimmed[trimmed.len - 1];

    const is_pair: bool = (first == '(' and last == ')') or
        (first == '[' and last == ']') or
        (first == '{' and last == '}');

    if (!is_pair) return trimmed;

    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var in_double_quote: bool = false;
    var escape: bool = false;

    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const c: u8 = trimmed[i];

        if (escape) {
            escape = false;
            continue;
        }

        if (in_double_quote) {
            if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_double_quote = false;
            }
            continue;
        }

        if (c == '"') {
            in_double_quote = true;
            continue;
        }

        if (c == '\'') {
            // Skip a char literal (e.g. `','`, `'\''`, `'\n'`) so its body is
            // not mistaken for delimiters or its closing quote treated as a
            // string opener. Unmatched single quotes (lifetimes) are left as-is.
            if (findCharEnd(trimmed, i)) |end| {
                i = end;
                continue;
            }
        }

        if (c == '(') {
            paren_depth += 1;
        } else if (c == ')') {
            if (paren_depth > 0) paren_depth -= 1;
        } else if (c == '[') {
            bracket_depth += 1;
        } else if (c == ']') {
            if (bracket_depth > 0) bracket_depth -= 1;
        } else if (c == '{') {
            brace_depth += 1;
        } else if (c == '}') {
            if (brace_depth > 0) brace_depth -= 1;
        }

        // If all depths reach zero before the final character, it is not a single outer pair.
        if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and i < trimmed.len - 1) {
            return trimmed;
        }
    }

    if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
        return std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
    }

    return trimmed;
}

/// Splits macro arguments by top-level commas.
/// Trims outer delimiter pairs `(...)`, `[...]`, `{...}` if present.
/// Respects nested parenthesis, brackets, braces, strings, and char literals.
/// Returns an allocated slice of trimmed argument token slices.
pub fn splitMacroArgs(alloc: std.mem.Allocator, raw_tokens: []const u8) ![]const []const u8 {
    const text: []const u8 = getEnclosedContent(raw_tokens);
    if (text.len == 0) {
        const empty = try alloc.alloc([]const u8, 0);
        return empty;
    }

    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer args_list.deinit(alloc);

    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var in_double_quote: bool = false;
    var escape: bool = false;
    var start: usize = 0;

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c: u8 = text[i];

        if (escape) {
            escape = false;
            continue;
        }

        if (in_double_quote) {
            if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_double_quote = false;
            }
            continue;
        }

        if (c == '"') {
            in_double_quote = true;
            continue;
        }

        if (c == '\'') {
            // Skip a char literal so commas inside its body (or its closing
            // quote) are not misread as argument separators.
            if (findCharEnd(text, i)) |end| {
                i = end;
                continue;
            }
        }

        if (c == '(') {
            paren_depth += 1;
        } else if (c == ')') {
            if (paren_depth > 0) paren_depth -= 1;
        } else if (c == '[') {
            bracket_depth += 1;
        } else if (c == ']') {
            if (bracket_depth > 0) bracket_depth -= 1;
        } else if (c == '{') {
            brace_depth += 1;
        } else if (c == '}') {
            if (brace_depth > 0) brace_depth -= 1;
        } else if (c == ',' and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
            const arg: []const u8 = std.mem.trim(u8, text[start..i], " \t\r\n");
            try args_list.append(alloc, arg);
            start = i + 1;
        }
    }

    const last_arg: []const u8 = std.mem.trim(u8, text[start..text.len], " \t\r\n");
    if (last_arg.len > 0) {
        try args_list.append(alloc, last_arg);
    }

    const res = try args_list.toOwnedSlice(alloc);
    return res;
}

/// Expands panic, todo, and unimplemented message arguments into an allocated message string.
/// If args is empty, returns an empty string.
/// If args contains a single string literal, strips surrounding quotes.
/// If args contains multiple parts, joins or unquotes as needed.
pub fn expandPanicMessage(alloc: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    if (args.len == 0) {
        const empty = try alloc.dupe(u8, "");
        return empty;
    }

    if (args.len == 1) {
        const arg: []const u8 = args[0];
        if (arg.len >= 2 and arg[0] == '"' and arg[arg.len - 1] == '"') {
            const unquoted = try alloc.dupe(u8, arg[1 .. arg.len - 1]);
            return unquoted;
        }
        const duped = try alloc.dupe(u8, arg);
        return duped;
    }

    // Multiple arguments (e.g. format string + values)
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(alloc);

    for (args, 0..) |arg, idx| {
        if (idx > 0) {
            try list.appendSlice(alloc, ", ");
        }
        if (arg.len >= 2 and arg[0] == '"' and arg[arg.len - 1] == '"') {
            try list.appendSlice(alloc, arg[1 .. arg.len - 1]);
        } else {
            try list.appendSlice(alloc, arg);
        }
    }

    const res = try list.toOwnedSlice(alloc);
    return res;
}

test "identifyMacro classifications" {
    try std.testing.expectEqual(MacroKind.assert, identifyMacro("assert"));
    try std.testing.expectEqual(MacroKind.assert, identifyMacro("assert!"));
    try std.testing.expectEqual(MacroKind.assert_eq, identifyMacro("assert_eq!"));
    try std.testing.expectEqual(MacroKind.assert_ne, identifyMacro("assert_ne!"));
    try std.testing.expectEqual(MacroKind.panic, identifyMacro("core::panic!"));
    try std.testing.expectEqual(MacroKind.panic, identifyMacro("std::panic"));
    try std.testing.expectEqual(MacroKind.vec, identifyMacro("vec!"));
    try std.testing.expectEqual(MacroKind.unreachable_, identifyMacro("unreachable!"));
    try std.testing.expectEqual(MacroKind.todo, identifyMacro("todo!"));
    try std.testing.expectEqual(MacroKind.unimplemented, identifyMacro("unimplemented!"));
    try std.testing.expectEqual(MacroKind.println, identifyMacro("println!"));
    try std.testing.expectEqual(MacroKind.eprintln, identifyMacro("eprintln!"));
    try std.testing.expectEqual(MacroKind.format, identifyMacro("format!"));
    try std.testing.expectEqual(MacroKind.custom, identifyMacro("my_macro!"));
}

test "isTestingAssert predicate" {
    try std.testing.expect(isTestingAssert(.assert));
    try std.testing.expect(isTestingAssert(.assert_eq));
    try std.testing.expect(isTestingAssert(.assert_ne));
    try std.testing.expect(!isTestingAssert(.panic));
    try std.testing.expect(!isTestingAssert(.vec));
    try std.testing.expect(!isTestingAssert(.todo));
    try std.testing.expect(!isTestingAssert(.custom));
}

test "splitMacroArgs basic and empty" {
    const alloc = std.testing.allocator;

    {
        const args = try splitMacroArgs(alloc, "");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 0), args.len);
    }
    {
        const args = try splitMacroArgs(alloc, "()");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 0), args.len);
    }
    {
        const args = try splitMacroArgs(alloc, "[]");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 0), args.len);
    }
    {
        const args = try splitMacroArgs(alloc, "{}");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 0), args.len);
    }
}

test "splitMacroArgs nested delimiters and commas" {
    const alloc = std.testing.allocator;

    {
        const args = try splitMacroArgs(alloc, "(a, b, c)");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 3), args.len);
        try std.testing.expectEqualStrings("a", args[0]);
        try std.testing.expectEqualStrings("b", args[1]);
        try std.testing.expectEqualStrings("c", args[2]);
    }
    {
        const args = try splitMacroArgs(alloc, "[vec![1, 2], foo(3, 4), { 5; 6 },]");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 3), args.len);
        try std.testing.expectEqualStrings("vec![1, 2]", args[0]);
        try std.testing.expectEqualStrings("foo(3, 4)", args[1]);
        try std.testing.expectEqualStrings("{ 5; 6 }", args[2]);
    }
    {
        const args = try splitMacroArgs(alloc, "(\"hello, world\", 'a', \",\", 42)");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 4), args.len);
        try std.testing.expectEqualStrings("\"hello, world\"", args[0]);
        try std.testing.expectEqualStrings("'a'", args[1]);
        try std.testing.expectEqualStrings("\",\"", args[2]);
        try std.testing.expectEqualStrings("42", args[3]);
    }
}

test "expandPanicMessage" {
    const alloc = std.testing.allocator;

    {
        const msg = try expandPanicMessage(alloc, &.{});
        defer alloc.free(msg);
        try std.testing.expectEqualStrings("", msg);
    }
    {
        const args = [_][]const u8{"\"explicit failure\""};
        const msg = try expandPanicMessage(alloc, &args);
        defer alloc.free(msg);
        try std.testing.expectEqualStrings("explicit failure", msg);
    }
    {
        const args = [_][]const u8{ "\"code: {}\"", "404" };
        const msg = try expandPanicMessage(alloc, &args);
        defer alloc.free(msg);
        try std.testing.expectEqualStrings("code: {}, 404", msg);
    }
}
