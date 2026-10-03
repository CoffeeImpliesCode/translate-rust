//! expand_test — unit tests for P6 built-in and declarative macro expansion.
//!
//! Pure C-free Zig tests running under `zig build test`.
//! Verifies macro kind classification, argument splitting with nested delimiter
//! support and quote literals, empty argument handling, message formatters, and
//! lexical source expansion with cfg filtering and nested macro_rules!.

const std = @import("std");
const expand = @import("expand.zig");
const cst = @import("cst.zig");
const pipeline = @import("pipeline.zig");
const ir = @import("translate_rust.ir");
const graph = ir.graph;
const types = ir.types;
const exprs = ir.exprs;
const bodies = ir.bodies;

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
    try std.testing.expectEqual(expand.MacroKind.write, expand.identifyMacro("write"));
    try std.testing.expectEqual(expand.MacroKind.write, expand.identifyMacro("write!"));
    try std.testing.expectEqual(expand.MacroKind.writeln, expand.identifyMacro("writeln"));
    try std.testing.expectEqual(expand.MacroKind.writeln, expand.identifyMacro("writeln!"));

    // Path-qualified built-in macros
    try std.testing.expectEqual(expand.MacroKind.panic, expand.identifyMacro("core::panic!"));
    try std.testing.expectEqual(expand.MacroKind.panic, expand.identifyMacro("std::panic!"));
    try std.testing.expectEqual(expand.MacroKind.vec, expand.identifyMacro("alloc::vec::vec!"));
    try std.testing.expectEqual(expand.MacroKind.todo, expand.identifyMacro("core::todo!"));
    try std.testing.expectEqual(expand.MacroKind.unimplemented, expand.identifyMacro("core::unimplemented!"));
    try std.testing.expectEqual(expand.MacroKind.write, expand.identifyMacro("core::write!"));
    try std.testing.expectEqual(expand.MacroKind.writeln, expand.identifyMacro("std::writeln!"));

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

test "splitMacroArgs rejects unbalanced delimiters and quotes" {
    const alloc = std.testing.allocator;

    try std.testing.expectError(
        error.MalformedMacroInvocation,
        expand.splitMacroArgs(alloc, "(value, [other)"),
    );
    try std.testing.expectError(
        error.MalformedMacroInvocation,
        expand.splitMacroArgs(alloc, "(\"unterminated)"),
    );
    try std.testing.expectError(
        error.MalformedMacroInvocation,
        expand.splitMacroArgs(alloc, "(r#\"unterminated)"),
    );
}

test "parseMacroRulesDefinition rejects partial and trailing rules" {
    const alloc = std.testing.allocator;
    const partial =
        \\macro_rules! make {
        \\    ($name:ident) => { struct $name; };
        \\    ($value:expr)
        \\}
    ;

    try std.testing.expectError(
        error.InvalidMacroDefinition,
        expand.parseMacroRulesDefinition(alloc, partial),
    );
    try std.testing.expectError(
        error.InvalidMacroDefinition,
        expand.parseMacroRulesDefinition(
            alloc,
            "macro_rules! make { ($name:ident) => { struct $name; }; ; }",
        ),
    );
}

test "expandMacroRules rejects unmatched invocations" {
    const alloc = std.testing.allocator;
    var def = try expand.parseMacroRulesDefinition(
        alloc,
        "macro_rules! make { ($name:ident) => { struct $name; }; }",
    );
    defer def.deinit(alloc);

    try std.testing.expectError(
        error.FragmentMismatch,
        expand.expandMacroRules(alloc, def, "(123)"),
    );
}

test "expandMacroRules rejects separators absent from matcher" {
    const alloc = std.testing.allocator;
    var def = try expand.parseMacroRulesDefinition(
        alloc,
        "macro_rules! literal { (a) => { struct A; }; }",
    );
    defer def.deinit(alloc);

    try std.testing.expectError(
        error.UnmatchedMacroRule,
        expand.expandMacroRules(alloc, def, "(a,)"),
    );
    try std.testing.expectError(
        error.UnmatchedMacroRule,
        expand.expandMacroRules(alloc, def, "(a;)"),
    );
}

test "expandMacroRules recursively matches nested repetitions" {
    const alloc = std.testing.allocator;
    var def = try expand.parseMacroRulesDefinition(alloc,
        \\macro_rules! nested {
        \\    ($($( $x:ident ),*);*) => { $( $( struct $x; )* )* };
        \\}
    );
    defer def.deinit(alloc);

    const expanded = try expand.expandMacroRules(alloc, def, "(a,b; c,d)");
    defer alloc.free(expanded);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "struct a;") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "struct b;") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "struct c;") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "struct d;") != null);
}

test "expandMacroRules resolves enclosing captures inside nested repetitions" {
    const alloc = std.testing.allocator;
    var def = try expand.parseMacroRulesDefinition(alloc,
        \\macro_rules! tagged {
        \\    ($($tag:ident ; $($x:ident),*);*) => { [ $( $( $tag + $x , )* )* ] };
        \\}
    );
    defer def.deinit(alloc);

    const expanded = try expand.expandMacroRules(alloc, def, "(outer_a; a,b; outer_b; c)");
    defer alloc.free(expanded);
    const first = std.mem.indexOf(u8, expanded, "outer_a + a") orelse return error.MissingFirstCapture;
    const second = std.mem.indexOf(u8, expanded, "outer_a + b") orelse return error.MissingSecondCapture;
    const third = std.mem.indexOf(u8, expanded, "outer_b + c") orelse return error.MissingThirdCapture;
    try std.testing.expect(first < second and second < third);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, expanded, " + "));
}

test "expandMacroRules rejects repetition depth overflow" {
    const alloc = std.testing.allocator;
    var raw: std.ArrayListUnmanaged(u8) = .empty;
    defer raw.deinit(alloc);
    try raw.appendSlice(alloc, "macro_rules! deep { (");
    for (0..expand.macro_repetition_depth_max + 1) |_| {
        try raw.appendSlice(alloc, "$(");
    }
    try raw.appendSlice(alloc, "$x:ident");
    for (0..expand.macro_repetition_depth_max + 1) |_| {
        try raw.appendSlice(alloc, ")*");
    }
    try raw.appendSlice(alloc, ") => { $x }; }");

    var def = try expand.parseMacroRulesDefinition(alloc, raw.items);
    defer def.deinit(alloc);
    try std.testing.expectError(
        error.MacroRepetitionDepthExceeded,
        expand.expandMacroRules(alloc, def, "(x)"),
    );
}

test "expandMacroRules rejects expansion token overflow" {
    const alloc = std.testing.allocator;
    var def = try expand.parseMacroRulesDefinition(
        alloc,
        "macro_rules! many { ($($x:ident),*) => { $( $x ; )* }; }",
    );
    defer def.deinit(alloc);

    var args: std.ArrayListUnmanaged(u8) = .empty;
    defer args.deinit(alloc);
    try args.append(alloc, '(');
    for (0..expand.macro_output_token_max + 1) |index| {
        if (index != 0) try args.appendSlice(alloc, ",");
        try args.appendSlice(alloc, "x");
    }
    try args.append(alloc, ')');

    try std.testing.expectError(
        error.MacroExpansionTokenLimit,
        expand.expandMacroRules(alloc, def, args.items),
    );
}

test "expandMacroRules rejects fragment mismatches explicitly" {
    const alloc = std.testing.allocator;
    var ident_def = try expand.parseMacroRulesDefinition(
        alloc,
        "macro_rules! ident_only { ($value:ident) => { $value }; }",
    );
    defer ident_def.deinit(alloc);
    try std.testing.expectError(
        error.FragmentMismatch,
        expand.expandMacroRules(alloc, ident_def, "(123)"),
    );

    var expr_def = try expand.parseMacroRulesDefinition(
        alloc,
        "macro_rules! expr_only { ($value:expr) => { $value }; }",
    );
    defer expr_def.deinit(alloc);
    try std.testing.expectError(
        error.FragmentMismatch,
        expand.expandMacroRules(alloc, expr_def, "(???)"),
    );
}

test "expandMacroRules accepts raw identifiers as ident fragments" {
    const alloc = std.testing.allocator;
    var def = try expand.parseMacroRulesDefinition(
        alloc,
        "macro_rules! raw_ident { ($value:ident) => { $value }; }",
    );
    defer def.deinit(alloc);

    const expanded = try expand.expandMacroRules(alloc, def, "(r#type)");
    defer alloc.free(expanded);
    try std.testing.expectEqualStrings(" r#type ", expanded);
}

test "expandMacroRules matches literal identifiers at token boundaries" {
    const alloc = std.testing.allocator;
    var def = try expand.parseMacroRulesDefinition(
        alloc,
        "macro_rules! choose { (foo $tail:ident) => { struct Wrong; }; (foobar) => { struct Correct; }; }",
    );
    defer def.deinit(alloc);

    const expanded = try expand.expandMacroRules(alloc, def, "(foobar)");
    defer alloc.free(expanded);
    try std.testing.expectEqualStrings(" struct Correct; ", expanded);
}

test "expandMacroRules rejects unbound template metavariables" {
    const alloc = std.testing.allocator;
    var def = try expand.parseMacroRulesDefinition(
        alloc,
        "macro_rules! make { ($name:ident) => { struct $missing; }; }",
    );
    defer def.deinit(alloc);

    try std.testing.expectError(
        error.UnboundMacroVariable,
        expand.expandMacroRules(alloc, def, "(Present)"),
    );
}

test "expandMacroRules rejects invalid template repetitions" {
    const alloc = std.testing.allocator;

    var unbound = try expand.parseMacroRulesDefinition(
        alloc,
        "macro_rules! make { () => { $(struct Missing;)* }; }",
    );
    defer unbound.deinit(alloc);
    try std.testing.expectError(
        error.UnboundMacroRepetition,
        expand.expandMacroRules(alloc, unbound, "()"),
    );

    var escaped = try expand.parseMacroRulesDefinition(
        alloc,
        "macro_rules! make { ($($name:ident),*) => { struct $name; }; }",
    );
    defer escaped.deinit(alloc);
    try std.testing.expectError(
        error.UnboundMacroRepetition,
        expand.expandMacroRules(alloc, escaped, "(First, Second)"),
    );

    var nonempty = try expand.parseMacroRulesDefinition(
        alloc,
        "macro_rules! make { ($($name:ident),*) => { $(struct $name;)+ }; }",
    );
    defer nonempty.deinit(alloc);
    try std.testing.expectError(
        error.UnboundMacroRepetition,
        expand.expandMacroRules(alloc, nonempty, "()"),
    );
}

test "expandMacroRules rejects empty expansions" {
    const alloc = std.testing.allocator;
    var def = try expand.parseMacroRulesDefinition(
        alloc,
        "macro_rules! empty { () => {}; }",
    );
    defer def.deinit(alloc);

    try std.testing.expectError(
        error.EmptyMacroExpansion,
        expand.expandMacroRules(alloc, def, "()"),
    );
}

test "parseVecInvocation preserves explicit vec element token slices" {
    const alloc = std.testing.allocator;
    const raw = "[1, (2, 3), 4]";
    var invocation: expand.VecInvocation = try expand.parseVecInvocation(alloc, raw);
    defer invocation.deinit(alloc);

    const elements = switch (invocation) {
        .elements => |items| items,
        .repeat => {
            try std.testing.expect(false);
            return;
        },
    };

    try std.testing.expectEqual(@as(usize, 3), elements.len);
    try std.testing.expectEqualStrings("1", elements[0]);
    try std.testing.expectEqualStrings("(2, 3)", elements[1]);
    try std.testing.expectEqualStrings("4", elements[2]);
    try std.testing.expectEqual(@intFromPtr(raw[1..2].ptr), @intFromPtr(elements[0].ptr));
    try std.testing.expectEqual(@intFromPtr(raw[4..9].ptr), @intFromPtr(elements[1].ptr));
    try std.testing.expectEqual(@intFromPtr(raw[12..13].ptr), @intFromPtr(elements[2].ptr));
}

test "parseVecInvocation recognizes literal repeat tokens" {
    const alloc = std.testing.allocator;
    const raw = "[0xff; 200_000]";
    var invocation: expand.VecInvocation = try expand.parseVecInvocation(alloc, raw);
    defer invocation.deinit(alloc);

    const repeat = switch (invocation) {
        .repeat => |parts| parts,
        .elements => {
            try std.testing.expect(false);
            return;
        },
    };
    try std.testing.expectEqualStrings("0xff", repeat.element);
    try std.testing.expectEqualStrings("200_000", repeat.count);
    try std.testing.expectEqual(@intFromPtr(raw[1..5].ptr), @intFromPtr(repeat.element.ptr));
    try std.testing.expectEqual(@intFromPtr(raw[7..14].ptr), @intFromPtr(repeat.count.ptr));
}

test "parseVecInvocation ignores a semicolon inside a nested block" {
    const alloc = std.testing.allocator;
    var invocation: expand.VecInvocation =
        try expand.parseVecInvocation(alloc, "[{ let value = 1; value }, 2]");
    defer invocation.deinit(alloc);

    const elements = switch (invocation) {
        .elements => |items| items,
        .repeat => {
            try std.testing.expect(false);
            return;
        },
    };

    try std.testing.expectEqual(@as(usize, 2), elements.len);
    try std.testing.expectEqualStrings("{ let value = 1; value }", elements[0]);
    try std.testing.expectEqualStrings("2", elements[1]);
}

test "parseVecInvocation ignores a semicolon inside a string literal" {
    const alloc = std.testing.allocator;
    var invocation: expand.VecInvocation =
        try expand.parseVecInvocation(alloc, "[\"left;right\", 7]");
    defer invocation.deinit(alloc);

    const elements = switch (invocation) {
        .elements => |items| items,
        .repeat => {
            try std.testing.expect(false);
            return;
        },
    };

    try std.testing.expectEqual(@as(usize, 2), elements.len);
    try std.testing.expectEqualStrings("\"left;right\"", elements[0]);
    try std.testing.expectEqualStrings("7", elements[1]);
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

test "expandMacroRules expands simple ident repetition" {
    const alloc = std.testing.allocator;
    const raw_def =
        \\macro_rules! impl_integer {
        \\    ($($t:ident),*) => { $(
        \\        impl Integer for $t {}
        \\    )* };
        \\}
    ;
    var def = try expand.parseMacroRulesDefinition(alloc, raw_def);
    defer def.deinit(alloc);

    const expanded = try expand.expandMacroRules(alloc, def, "(i8, i16, i32)");
    defer alloc.free(expanded);

    try std.testing.expect(std.mem.indexOf(u8, expanded, "impl Integer for i8") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "impl Integer for i16") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "impl Integer for i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "impl Integer for i64") == null);
}

test "expandMacroRules expands ty repetition" {
    const alloc = std.testing.allocator;
    const raw_def =
        \\macro_rules! make_a {
        \\    ($($t:ty),*) => { $(
        \\        pub struct Wrapper$t { inner: $t }
        \\    )* };
        \\}
    ;
    var def = try expand.parseMacroRulesDefinition(alloc, raw_def);
    defer def.deinit(alloc);

    const expanded = try expand.expandMacroRules(alloc, def, "(u8, Vec<u32>, &str)");
    defer alloc.free(expanded);

    try std.testing.expect(std.mem.indexOf(u8, expanded, "inner: u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "inner: Vec<u32>") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "inner: &str") != null);
}

test "expandMacroRules expands itoa impl_Integer pattern" {
    const alloc = std.testing.allocator;
    const raw_def =
        \\macro_rules! impl_Integer {
        \\    ($($max_len:expr => $t:ident),* as $conv_fn:ident) => {$(
        \\        impl Integer for $t {}
        \\        impl private::Sealed for $t {
        \\            type Buffer = [MaybeUninit<u8>; $max_len];
        \\            fn write(self, buf: &mut [MaybeUninit<u8>; $max_len]) -> &str {
        \\                let n = self as $conv_fn;
        \\                let _ = n;
        \\                ""
        \\            }
        \\        }
        \\    )*};
        \\}
    ;
    var def = try expand.parseMacroRulesDefinition(alloc, raw_def);
    defer def.deinit(alloc);

    const expanded = try expand.expandMacroRules(
        alloc,
        def,
        "(I8_MAX_LEN => i8, U8_MAX_LEN => u8, I16_MAX_LEN => i16 as u32)",
    );
    defer alloc.free(expanded);

    try std.testing.expect(std.mem.indexOf(u8, expanded, "impl Integer for i8") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "type Buffer = [MaybeUninit<u8>; I8_MAX_LEN];") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "impl Integer for u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "type Buffer = [MaybeUninit<u8>; U8_MAX_LEN];") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "impl Integer for i16") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "type Buffer = [MaybeUninit<u8>; I16_MAX_LEN];") != null);
    // $conv_fn is a top-level metavar — used inside the repetition below.
    try std.testing.expect(std.mem.indexOf(u8, expanded, "self as u32") != null);
}

test "expandMacroRules expands whitespace-separated expr repetition" {
    const alloc = std.testing.allocator;
    const raw_def =
        \\macro_rules! from_hex_array_impl {
        \\    ($($len:expr)+) => {$(
        \\        impl FromHex for [u8; $len] { fn x() {} }
        \\    )+}
        \\}
    ;
    var def = try expand.parseMacroRulesDefinition(alloc, raw_def);
    defer def.deinit(alloc);

    const expanded = try expand.expandMacroRules(alloc, def, "(1 2 3 4)");
    defer alloc.free(expanded);

    try std.testing.expect(std.mem.indexOf(u8, expanded, "[u8; 1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "[u8; 2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "[u8; 3]") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "[u8; 4]") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "[u8; 1 2") == null);
    // Each repetition yields a separate impl block.
    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, expanded, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trim(u8, line, " "), "impl FromHex for [u8;")) {
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 4), count);
}

test "expandMacroRules rejects unmatched args" {
    const alloc = std.testing.allocator;
    const raw_def = "macro_rules! m { ($($t:ident),*) => { $(struct $t;)* }; }";
    var def = try expand.parseMacroRulesDefinition(alloc, raw_def);
    defer def.deinit(alloc);
    try std.testing.expectError(
        error.FragmentMismatch,
        expand.expandMacroRules(alloc, def, "(a, 123)"),
    );
}

test "parseMacroRulesDefinition extracts gated rules" {
    const alloc = std.testing.allocator;
    const raw =
        \\macro_rules! tag {
        \\    ($($t:ident),*) => { $(struct $t;)* };
        \\    ($x:expr) => { $x };
        \\}
    ;
    var def = try expand.parseMacroRulesDefinition(alloc, raw);
    try std.testing.expectEqual(@as(usize, 2), def.rules.len);
    try std.testing.expectEqualStrings("tag", def.name);
    defer def.deinit(alloc);

    const expanded = try expand.expandMacroRules(alloc, def, "(x)");
    defer alloc.free(expanded);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "struct x;") != null);
}

test "expandSourceMacros preserves lexical macro shadowing" {
    const allocator = std.testing.allocator;
    var table = expand.MacroTable.init(allocator);
    defer table.deinit();

    var root_definition = try expand.parseMacroRulesDefinition(
        allocator,
        "macro_rules! choose { () => { root_call(); }; }",
    );
    table.register(root_definition.name, root_definition) catch |err| {
        root_definition.deinit(allocator);
        return err;
    };

    const source =
        \\fn demo() {
        \\    choose!();
        \\    macro_rules! choose { () => { local_call(); }; }
        \\    choose!();
        \\    {
        \\        macro_rules! choose { () => { inner_call(); }; }
        \\        choose!();
        \\    }
        \\    choose!();
        \\}
    ;
    const expanded = try expand.expandSourceMacros(allocator, &table, source, .{});
    defer allocator.free(expanded);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, expanded, "root_call"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, expanded, "local_call"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, expanded, "inner_call"));
    try std.testing.expect(std.mem.indexOf(u8, expanded, "macro_rules!") == null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "choose!") == null);

    const root_expansion = try expand.expandMacroRules(
        allocator,
        table.get("choose").?,
        "()",
    );
    defer allocator.free(root_expansion);
    try std.testing.expect(std.mem.indexOf(u8, root_expansion, "root_call") != null);
}

test "MacroTable child scopes inherit without sibling leakage" {
    const allocator = std.testing.allocator;
    var root = expand.MacroTable.init(allocator);
    defer root.deinit();
    var child = expand.MacroTable.initChild(&root);
    defer child.deinit();
    var sibling = expand.MacroTable.initChild(&root);
    defer sibling.deinit();

    var root_definition = try expand.parseMacroRulesDefinition(
        allocator,
        "macro_rules! choose { () => { root_call(); }; }",
    );
    root.register(root_definition.name, root_definition) catch |err| {
        root_definition.deinit(allocator);
        return err;
    };
    var child_definition = try expand.parseMacroRulesDefinition(
        allocator,
        "macro_rules! choose { () => { child_call(); }; }",
    );
    child.register(child_definition.name, child_definition) catch |err| {
        child_definition.deinit(allocator);
        return err;
    };

    const child_expansion = try expand.expandMacroRules(allocator, child.get("choose").?, "()");
    defer allocator.free(child_expansion);
    const sibling_expansion = try expand.expandMacroRules(allocator, sibling.get("choose").?, "()");
    defer allocator.free(sibling_expansion);
    try std.testing.expect(std.mem.indexOf(u8, child_expansion, "child_call") != null);
    try std.testing.expect(std.mem.indexOf(u8, sibling_expansion, "root_call") != null);
}

test "expandSourceMacros excludes cfg-disabled definitions and invocations" {
    const allocator = std.testing.allocator;
    var table = expand.MacroTable.init(allocator);
    defer table.deinit();

    const source =
        \\fn demo() {
        \\    #[cfg(feature = "fast")]
        \\    macro_rules! selected { () => { fast_path(); }; }
        \\    #[cfg(not(feature = "fast"))]
        \\    macro_rules! selected { () => { slow_path(); }; }
        \\    selected!();
        \\    #[cfg(feature = "missing")]
        \\    selected!();
        \\}
    ;
    const expanded = try expand.expandSourceMacros(
        allocator,
        &table,
        source,
        .{ .features = &.{"fast"} },
    );
    defer allocator.free(expanded);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, expanded, "fast_path"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, expanded, "slow_path"));
    try std.testing.expect(std.mem.indexOf(u8, expanded, "macro_rules!") == null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "selected!") == null);
}

test "expandSourceMacros preserves write token trees" {
    const allocator = std.testing.allocator;
    var table = expand.MacroTable.init(allocator);
    defer table.deinit();

    const source =
        \\fn emit(writer: &mut Formatter, value: Value) {
        \\    write ! (writer, "value = {:?}", value /* keep */);
        \\    writeln!(writer, "value = {}", value);
        \\}
    ;
    const expanded = try expand.expandSourceMacros(allocator, &table, source, .{});
    defer allocator.free(expanded);
    try std.testing.expectEqualStrings(source, expanded);
}

test "expandSourceMacros preserves Rust byte literals" {
    const allocator = std.testing.allocator;
    var table = expand.MacroTable.init(allocator);
    defer table.deinit();

    const source =
        \\fn bytes() {
        \\    let cooked = b"macro!({})\n\x00\xff";
        \\    let raw = br##"macro!({}) "# remains raw"##;
        \\    let hex = b'\x7b';
        \\    let quote = b'\'';
        \\}
    ;
    const expanded = try expand.expandSourceMacros(allocator, &table, source, .{});
    defer allocator.free(expanded);
    try std.testing.expectEqualStrings(source, expanded);
}

test "expandSourceMacros rejects malformed byte literals and token trees" {
    const allocator = std.testing.allocator;
    var table = expand.MacroTable.init(allocator);
    defer table.deinit();

    const malformed_sources = [_][]const u8{
        "fn broken() { let byte = b'\\x4'; }",
        "fn broken() { let bytes = br#\"unterminated; }",
        "fn broken() { panic!([value); }",
    };
    for (malformed_sources) |source| {
        try std.testing.expectError(
            error.MalformedMacroInvocation,
            expand.expandSourceMacros(allocator, &table, source, .{}),
        );
    }
}

test "expandSourceMacros recursively expands nested and token-tree macros" {
    const allocator = std.testing.allocator;
    var table = expand.MacroTable.init(allocator);
    defer table.deinit();

    var compress = try expand.parseMacroRulesDefinition(allocator,
        \\macro_rules! compress {
        \\    ($state:expr) => {{ compress!($state.0, $state.1) }};
        \\    ($left:expr, $right:expr) => {{ $left = $left.wrapping_add($right); }};
        \\}
    );
    table.register(compress.name, compress) catch |err| {
        compress.deinit(allocator);
        return err;
    };
    var round_loop = try expand.parseMacroRulesDefinition(allocator,
        \\macro_rules! round_loop {
        \\    ($input:ident => $($value:tt)+) => {
        \\        $($value)+.0 = round($($value)+.0, chunk($input, 0));
        \\        $input = &$input[16..];
        \\    };
        \\}
    );
    table.register(round_loop.name, round_loop) catch |err| {
        round_loop.deinit(allocator);
        return err;
    };

    const source =
        \\fn consume(mut input: &[u8], mut state: State) {
        \\    compress!(state);
        \\    round_loop!(input => state.values);
        \\}
    ;
    const expanded = try expand.expandSourceMacros(allocator, &table, source, .{});
    defer allocator.free(expanded);

    try std.testing.expect(std.mem.indexOf(u8, expanded, "compress!") == null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "round_loop!") == null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "state.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "state.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "state.values.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "input = &input[16..]") != null);
}

fn expectCstError(
    expected_error: anyerror,
    src: []const u8,
    base_dir: ?[]const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, ""),
        .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
        .items = &.{},
        .attributes = &.{},
    });

    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    var bodies_list: std.ArrayListUnmanaged(bodies.BodyKind) = .empty;
    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;
    try bodies_list.append(alloc, .none);

    var ctx: cst.Ctx = .{
        .alloc = alloc,
        .g = &g,
        .src = src,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
        .base_dir = base_dir,
        .io = if (base_dir != null) std.testing.io else null,
    };
    try std.testing.expectError(expected_error, cst.extractFile(&ctx));
    try std.testing.expectEqual(@as(usize, 0), g.modules.items[0].items.len);
}
fn expectCstSuccess(src: []const u8, base_dir: ?[]const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, ""),
        .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
        .items = &.{},
        .attributes = &.{},
    });

    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    var bodies_list: std.ArrayListUnmanaged(bodies.BodyKind) = .empty;
    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;
    try bodies_list.append(alloc, .none);
    var ctx: cst.Ctx = .{
        .alloc = alloc,
        .g = &g,
        .src = src,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
        .base_dir = base_dir,
        .io = if (base_dir != null) std.testing.io else null,
    };
    try cst.extractFile(&ctx);
    return g.modules.items[0].items.len;
}

test "cst rejects malformed const initializers and arrays" {
    try expectCstError(error.ParseFailed, "const BROKEN: u8 = ;", null);
    try expectCstError(
        error.UnsupportedConstInitializer,
        "const VALUES: [u8; 2] = [1, make_value()];",
        null,
    );
    try expectCstError(
        error.InvalidConstArray,
        "const VALUES: [u8; 2] = [1; make_len()];",
        null,
    );
}

test "cst rejects missing modules and unsupported top-level items" {
    try expectCstError(
        error.ModuleNotFound,
        "mod translate_rust_definitely_missing;",
        "test",
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try expectCstSuccess(
            "#[cfg(any(feature = \"serde\", feature = \"std\"))]\nmod unsupported_cfg_missing;",
            "test",
        ),
    );
    try expectCstError(
        error.UnsupportedCfgPredicate,
        "#[cfg(unix)]\nstruct PlatformOnly;",
        null,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try expectCstSuccess("#[cfg(test)]\nstruct TestOnly;", null),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try expectCstSuccess(
            "#[cfg_attr(test, allow(dead_code))]\nstruct ConditionalAttribute;",
            null,
        ),
    );
    try expectCstError(
        error.UnsupportedCfgPredicate,
        "#[cfg(feature = \"serde\")]\nimpl Missing { fn value() {} }\n" ++
            "#[cfg(feature = \"std\")]\nmod disabled_missing;\n" ++
            "#[cfg(unix)]\nstruct PlatformOnly;",
        null,
    );
    try expectCstError(error.UnsupportedItem, "static VALUE: u8 = 1;", null);
    try expectCstError(error.UnsupportedItem, "extern \"C\" { fn foreign(); }", null);
}

test "cst evaluates FNV cfg predicates with fixed project features" {
    const source =
        \\#![cfg_attr(feature = "std", doc = "std documentation")]
        \\#![cfg_attr(not(feature = "std"), no_std)]
        \\#[cfg(all(not(feature = "std"), test))]
        \\extern crate alloc;
        \\#[cfg(feature = "std")]
        \\struct StdOnly;
        \\#[cfg(not(feature = "std"))]
        \\struct CoreOnly;
    ;
    try std.testing.expectEqual(@as(usize, 1), try expectCstSuccess(source, null));
}

test "cst rejects malformed cfg predicates after disabled results" {
    try expectCstError(
        error.UnsupportedCfgPredicate,
        "#[cfg(all(feature = \"std\", unix = \"enabled\"))]\nstruct PlatformOnly;",
        null,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try expectCstSuccess(
            "#![cfg_attr(docsrs, doc = \"documentation\")]\nstruct Value;",
            null,
        ),
    );
}

test "cst rejects unresolved impl and macro paths" {
    try expectCstError(error.UnresolvedImplTarget, "impl Missing { fn value() {} }", null);
    try expectCstError(
        error.UnresolvedImplTarget,
        "trait Display { fn value(); } impl Display for Missing { fn value() {} }",
        null,
    );
    try expectCstError(
        error.ExternalMacroSourceUnavailable,
        "unknown_item_macro!(Value);",
        null,
    );
    try expectCstError(
        error.FragmentMismatch,
        "macro_rules! make { ($name:ident) => { struct $name; }; } make!(123);",
        null,
    );
    try expectCstError(
        error.ExternalMacroSourceUnavailable,
        "module::unknown_item_macro!(Value);",
        null,
    );
    try expectCstError(error.ParseFailed, "unknown_item_macro!;", null);
    try expectCstError(
        error.ParseFailed,
        "macro_rules! broken { () => { struct ; }; } broken!();",
        null,
    );
    try expectCstError(
        error.UnsupportedItem,
        "macro_rules! partial { () => { struct Generated; static BAD: u8 = 1; }; } partial!();",
        null,
    );
}

test "cst resolves same-module impl targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, ""),
        .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
        .items = &.{},
        .attributes = &.{},
    });

    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    var bodies_list: std.ArrayListUnmanaged(bodies.BodyKind) = .empty;
    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;
    try bodies_list.append(alloc, .none);

    const src =
        \\mod file {
        \\    enum FromHexError { OddLength }
        \\    trait Display { fn value(); }
        \\    impl Display for FromHexError { fn value() {} }
        \\}
    ;
    var ctx: cst.Ctx = .{
        .alloc = alloc,
        .g = &g,
        .src = src,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
    };
    try cst.extractFile(&ctx);

    var file_module_id: ?ir.spine.EntityId = null;
    var error_id: ?ir.spine.EntityId = null;
    var impl_parent: ?ir.spine.EntityId = null;
    for (g.symbol_table.entities.items) |entity| {
        if (entity.kind == .module and std.mem.eql(u8, entity.name, "file")) {
            file_module_id = entity.id;
        }
        if (entity.kind == .enum_ and std.mem.eql(u8, entity.name, "FromHexError")) {
            error_id = entity.id;
        }
        if (entity.kind == .impl_ and
            std.mem.eql(u8, entity.name, "Display for FromHexError"))
        {
            impl_parent = entity.parent;
        }
    }
    const module_id = file_module_id orelse return error.TestUnexpectedResult;
    const enum_id = error_id orelse return error.TestUnexpectedResult;
    const enum_entity = g.symbol_table.get(enum_id) orelse return error.TestUnexpectedResult;
    const enum_parent = enum_entity.parent orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(module_id, enum_parent);
    try std.testing.expectEqual(enum_id, impl_parent orelse return error.TestUnexpectedResult);
}

test "cst rejects incomplete itoa impl_Integer expansion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, ""),
        .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
        .items = &.{},
        .attributes = &.{},
    });

    // The parser-only expansion test above remains successful. This CST test
    // verifies that strict ingestion rejects the generated aliases when the
    // external itoa declarations are not present.
    const src =
        \\struct Sealed {}
        \\macro_rules! impl_Integer {
        \\    ($($max_len:expr => $t:ident),* as $conv_fn:ident) => {$(
        \\        impl Integer for $t {}
        \\        impl private::Sealed for $t {
        \\            type Buffer = [MaybeUninit<u8>; $max_len];
        \\            fn write(self, buf: &mut [MaybeUninit<u8>; $max_len]) -> &str { "" }
        \\        }
        \\    )*};
        \\}
        \\const U8_MAX_LEN: usize = 3;
        \\const I8_MAX_LEN: usize = 4;
        \\const I32_MAX_LEN: usize = 11;
        \\impl_Integer!(I8_MAX_LEN => i8, U8_MAX_LEN => u8 as u32);
        \\impl_Integer!(I32_MAX_LEN => i32 as u32);
    ;

    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    var bodies_list: std.ArrayListUnmanaged(bodies.BodyKind) = .empty;
    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;
    try bodies_list.append(alloc, .none);

    var ctx: cst.Ctx = .{
        .alloc = alloc,
        .g = &g,
        .src = src,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
    };
    try std.testing.expectError(error.UnresolvedNominalType, cst.extractFile(&ctx));
    try std.testing.expectEqual(@as(usize, 0), g.modules.items[0].items.len);
}

test "cst skips disabled extern crates and preserves inner attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, ""),
        .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
        .items = &.{},
        .attributes = &.{},
    });

    const src =
        \\//! Crate documentation.
        \\#![no_std]
        \\#[cfg(feature = "alloc")]
        \\extern crate alloc as allocator;
        \\pub fn use_alloc() {}
    ;
    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    var bodies_list: std.ArrayListUnmanaged(bodies.BodyKind) = .empty;
    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;
    try bodies_list.append(alloc, .none);
    var ctx: cst.Ctx = .{
        .alloc = alloc,
        .g = &g,
        .src = src,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
    };
    try cst.extractFile(&ctx);

    try std.testing.expectEqual(@as(usize, 1), g.modules.items[0].items.len);
    const no_std = for (g.modules.items[0].attributes) |attribute| {
        if (std.mem.eql(u8, attribute.name, "no_std")) break attribute;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("", no_std.meta);

    var found_extern = false;
    var found_function = false;
    for (g.symbol_table.entities.items) |entity| {
        if (entity.kind == .extern_crate) {
            found_extern = true;
        }
        if (entity.kind == .fn_ and std.mem.eql(u8, entity.name, "use_alloc")) {
            found_function = true;
        }
    }
    try std.testing.expect(!found_extern);
    try std.testing.expect(found_function);
}

test "cst extracts macro-expanded items into the graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, ""),
        .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
        .items = &.{},
        .attributes = &.{},
    });

    const src =
        \\macro_rules! impl_integer {
        \\    ($($t:ident),*) => { $(
        \\        impl Integer for $t {}
        \\        pub fn size_of_$t() -> usize { 0 }
        \\    )* };
        \\}
        \\impl_integer!(i8, i16, i32);
    ;

    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    var bodies_list: std.ArrayListUnmanaged(bodies.BodyKind) = .empty;
    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;
    try bodies_list.append(alloc, .none);

    var ctx: cst.Ctx = .{
        .alloc = alloc,
        .g = &g,
        .src = src,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
    };
    try cst.extractFile(&ctx);

    // The expanded impls and fns must be ingested as real items.
    var found_impls: usize = 0;
    var found_fns: usize = 0;
    for (g.symbol_table.entities.items) |ent| {
        if (ent.kind == .impl_ and std.mem.indexOf(u8, ent.name, "Integer for ") != null) found_impls += 1;
        if (ent.kind == .fn_ and std.mem.startsWith(u8, ent.name, "size_of_")) found_fns += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), found_impls);
    try std.testing.expectEqual(@as(usize, 3), found_fns);
}

test "cst records impl-only macro expansions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, ""),
        .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
        .items = &.{},
        .attributes = &.{},
    });

    const src =
        \\macro_rules! impl_integer {
        \\    ($($t:ident),*) => { $(
        \\        impl Integer for $t {}
        \\    )* };
        \\}
        \\impl_integer!(i8, i16, i32);
    ;

    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    var bodies_list: std.ArrayListUnmanaged(bodies.BodyKind) = .empty;
    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;
    try bodies_list.append(alloc, .none);

    var ctx: cst.Ctx = .{
        .alloc = alloc,
        .g = &g,
        .src = src,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
    };
    try cst.extractFile(&ctx);

    const expected_names = [_][]const u8{
        "Integer for i8",
        "Integer for i16",
        "Integer for i32",
    };
    var found_impl_count: usize = 0;
    for (expected_names) |expected_name| {
        var found = false;
        for (g.symbol_table.entities.items) |entity| {
            if (entity.kind == .impl_ and std.mem.eql(u8, entity.name, expected_name)) {
                found = true;
                found_impl_count += 1;
                break;
            }
        }
        try std.testing.expect(found);
    }
    try std.testing.expectEqual(expected_names.len, found_impl_count);
}

test "cst retains EmptyMacroExpansion for true empty transcribers" {
    try expectCstError(
        error.EmptyMacroExpansion,
        "macro_rules! empty { () => {}; } empty!();",
        null,
    );
}

const CstTestAnalysis = struct {
    g: graph.CrateGraph,
    types_list: std.ArrayListUnmanaged(types.Type),
    bodies_list: std.ArrayListUnmanaged(bodies.BodyKind),
    exprs_list: std.ArrayListUnmanaged(exprs.Expr),
};

fn analyzeCstForTest(
    allocator: std.mem.Allocator,
    source: []const u8,
    base_dir: ?[]const u8,
    include_tests: bool,
) !CstTestAnalysis {
    var analysis: CstTestAnalysis = .{
        .g = graph.CrateGraph.init(allocator),
        .types_list = .empty,
        .bodies_list = .empty,
        .exprs_list = .empty,
    };
    errdefer analysis.g.deinit();
    _ = try analysis.g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try allocator.dupe(u8, ""),
        .span = cst.span_of,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try analysis.g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = cst.span_of,
        .items = &.{},
        .attributes = &.{},
    });
    try analysis.bodies_list.append(allocator, .none);

    var ctx: cst.Ctx = .{
        .alloc = allocator,
        .g = &analysis.g,
        .src = source,
        .types_list = &analysis.types_list,
        .bodies_list = &analysis.bodies_list,
        .exprs_list = &analysis.exprs_list,
        .base_dir = base_dir,
        .io = if (base_dir != null) std.testing.io else null,
        .include_tests = include_tests,
    };
    try cst.extractFile(&ctx);
    return analysis;
}

fn findEntityId(
    crate_graph: *const graph.CrateGraph,
    kind: ir.spine.EntityKind,
    name: []const u8,
) ?ir.spine.EntityId {
    for (crate_graph.symbol_table.entities.items) |entity| {
        if (entity.kind == kind and std.mem.eql(u8, entity.name, name)) return entity.id;
    }
    return null;
}

fn expectPipelineConstValue(
    rust_ir: *const ir.RustIr,
    name: []const u8,
    expected: i128,
) !void {
    const entity_id = findEntityId(&rust_ir.graph, .const_, name) orelse
        return error.TestUnexpectedResult;
    const init_id = switch (rust_ir.bodies.bodies[entity_id]) {
        .const_ => |constant| constant.init,
        else => return error.TestUnexpectedResult,
    };
    switch (rust_ir.bodies.exprs[init_id].kind) {
        .literal => |literal| switch (literal) {
            .int => |integer| try std.testing.expectEqual(expected, integer.value),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

fn expectStructArrayLength(
    analysis: *const CstTestAnalysis,
    struct_name: []const u8,
    expected: u32,
) !void {
    const entity_id = findEntityId(&analysis.g, .struct_, struct_name) orelse
        return error.TestUnexpectedResult;
    const structure = switch (analysis.bodies_list.items[entity_id]) {
        .struct_ => |body| body,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), structure.fields.len);
    const array = switch (structure.fields[0].ty) {
        .array => |value| value,
        else => return error.TestUnexpectedResult,
    };
    switch (array.len) {
        .literal => |length| try std.testing.expectEqual(expected, length),
        else => return error.TestUnexpectedResult,
    }
}

test "pipeline preserves 128-bit integer casts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\const UNSIGNED: u128 = 1u8 as u128;
        \\const SIGNED: i128 = 1u8 as i128;
    ;

    const rust_ir = try pipeline.analyzeSource(allocator, "wide_casts", "2021", source);
    try expectPipelineConstValue(&rust_ir, "UNSIGNED", 1);
    try expectPipelineConstValue(&rust_ir, "SIGNED", 1);
}

test "pipeline folds usize casts at configured pointer width" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source = "const VALUE: usize = 0x1_0000_0001u64 as usize;";

    const rust_ir = try pipeline.analyzeSourceWithOptions(
        allocator,
        "pointer_cast",
        "2021",
        source,
        .{ .cfg = .{ .target_pointer_width = 32 } },
    );
    try expectPipelineConstValue(&rust_ir, "VALUE", 1);
}

test "cst forwards include_tests into file modules" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "child.rs",
        .data = "#[cfg(test)]\n#[test]\nfn child_test() {}\n",
    });
    const base_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);

    var analysis = try analyzeCstForTest(allocator, "mod child;", base_dir, true);
    defer analysis.g.deinit();
    try std.testing.expect(findEntityId(&analysis.g, .fn_, "child_test") != null);
}

test "cst keeps module entity ids for extern crates and inner attributes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var extern_analysis = try analyzeCstForTest(
        allocator,
        "struct Marker; mod child { extern crate core; }",
        null,
        false,
    );
    defer extern_analysis.g.deinit();
    const extern_child_id = findEntityId(&extern_analysis.g, .module, "child") orelse
        return error.TestUnexpectedResult;
    const extern_id = findEntityId(&extern_analysis.g, .extern_crate, "core") orelse
        return error.TestUnexpectedResult;
    const extern_entity = extern_analysis.g.symbol_table.get(extern_id) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(extern_child_id, extern_entity.parent.?);

    var attribute_analysis = try analyzeCstForTest(
        allocator,
        "struct Marker; mod child { #![allow(dead_code)] }",
        null,
        false,
    );
    defer attribute_analysis.g.deinit();
    const attribute_child_id = findEntityId(&attribute_analysis.g, .module, "child") orelse
        return error.TestUnexpectedResult;
    const child_module = attribute_analysis.g.moduleForEntity(attribute_child_id) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), child_module.attributes.len);
    try std.testing.expectEqualStrings("allow", child_module.attributes[0].name);
    try std.testing.expectEqualStrings("dead_code", child_module.attributes[0].meta);
}

test "cst preserves const and alias provenance across module files" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "child.rs",
        .data = "use super::OUTER_LEN;\nmake_alias!();\n",
    });
    const base_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const source =
        \\macro_rules! make_alias {
        \\    () => { type Alias = [u8; OUTER_LEN]; };
        \\}
        \\const OUTER_LEN: usize = 4;
        \\mod child;
    ;

    var analysis = try analyzeCstForTest(allocator, source, base_dir, false);
    defer analysis.g.deinit();
    const alias_id = findEntityId(&analysis.g, .type_alias, "Alias") orelse
        return error.TestUnexpectedResult;
    const target = switch (analysis.bodies_list.items[alias_id]) {
        .type_alias => |alias| alias.target,
        else => return error.TestUnexpectedResult,
    };
    const array = switch (target) {
        .array => |value| value,
        else => return error.TestUnexpectedResult,
    };
    switch (array.len) {
        .literal => |length| try std.testing.expectEqual(@as(u32, 4), length),
        else => return error.TestUnexpectedResult,
    }
}

test "cst resolves parent const before child shadowing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\const BASE: usize = 4;
        \\const OUTER: usize = BASE;
        \\mod child {
        \\    use super::OUTER;
        \\    const BASE: usize = 1;
        \\    struct Buffer { bytes: [u8; OUTER] }
        \\}
    ;

    var analysis = try analyzeCstForTest(allocator, source, null, false);
    defer analysis.g.deinit();
    try expectStructArrayLength(&analysis, "Buffer", 4);
}

test "cst resolves generic nominal declarations after their use" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\struct Holder { value: Item<u8> }
        \\struct Item<T> { value: T }
    ;

    const rust_ir = try pipeline.analyzeSource(allocator, "generic_forward", "2021", source);
    const holder_id = findEntityId(&rust_ir.graph, .struct_, "Holder") orelse
        return error.TestUnexpectedResult;
    const item_id = findEntityId(&rust_ir.graph, .struct_, "Item") orelse
        return error.TestUnexpectedResult;
    const holder = switch (rust_ir.bodies.bodies[holder_id]) {
        .struct_ => |structure| structure,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), holder.fields.len);
    const generic = switch (holder.fields[0].ty) {
        .generic_inst => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(item_id, generic.decl);
    try std.testing.expectEqual(@as(usize, 1), generic.args.params.len);
    try std.testing.expect(generic.args.params[0] == .prim);
    try std.testing.expect(generic.args.params[0].prim == .u8);
}

test "parseMacroRulesDefinition owns definition source" {
    const allocator = std.testing.allocator;
    const raw = try allocator.dupe(
        u8,
        "macro_rules! inner { () => { struct Generated; }; }",
    );
    var definition = try expand.parseMacroRulesDefinition(allocator, raw);
    allocator.free(raw);
    defer definition.deinit(allocator);

    const expanded = try expand.expandMacroRules(allocator, definition, "()");
    defer allocator.free(expanded);
    try std.testing.expectEqualStrings(" struct Generated; ", expanded);
}

test "cst expands macros emitted by macros" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\macro_rules! define {
        \\    () => { macro_rules! inner { () => { struct Generated; }; } };
        \\}
        \\define!();
        \\inner!();
    ;

    const rust_ir = try pipeline.analyzeSource(allocator, "nested_macros", "2021", source);
    try std.testing.expect(findEntityId(&rust_ir.graph, .struct_, "Generated") != null);
}

fn pipelineConstInitializer(rust_ir: *const ir.RustIr, name: []const u8) !exprs.Expr {
    const entity_id = findEntityId(&rust_ir.graph, .const_, name) orelse
        return error.TestUnexpectedResult;
    if (entity_id >= rust_ir.bodies.bodies.len) return error.TestUnexpectedResult;
    const initializer_id = switch (rust_ir.bodies.bodies[entity_id]) {
        .const_ => |constant| constant.init,
        else => return error.TestUnexpectedResult,
    };
    if (initializer_id >= rust_ir.bodies.exprs.len) return error.TestUnexpectedResult;
    return rust_ir.bodies.exprs[initializer_id];
}

test "cst treats unset bare cfg names as false but rejects malformed values" {
    const source =
        \\#![cfg_attr(not(std), no_std)]
        \\#[cfg(std)]
        \\struct StdOnly;
        \\struct CoreOnly;
    ;
    try std.testing.expectEqual(@as(usize, 1), try expectCstSuccess(source, null));
    try expectCstError(
        error.UnsupportedCfgPredicate,
        "#[cfg(std = \"enabled\")]\nstruct Invalid;",
        null,
    );
}

test "cst uses host pointer width by default and preserves explicit targets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const host_width = @bitSizeOf(usize);
    const other_width = if (host_width == 64) 32 else 64;
    const source = try std.fmt.allocPrint(
        allocator,
        "#[cfg(target_pointer_width = \"{d}\")]\nstruct HostWidth;\n" ++
            "#[cfg(target_pointer_width = \"{d}\")]\nstruct OtherWidth;",
        .{ host_width, other_width },
    );

    try std.testing.expectEqual(@as(usize, 1), try expectCstSuccess(source, null));

    const explicit = try pipeline.analyzeSourceWithOptions(
        allocator,
        "explicit_pointer_width",
        "2021",
        source,
        .{ .cfg = .{ .target_pointer_width = other_width } },
    );
    try std.testing.expect(findEntityId(&explicit.graph, .struct_, "HostWidth") == null);
    try std.testing.expect(findEntityId(&explicit.graph, .struct_, "OtherWidth") != null);
}

test "cst accepts wildcard trait function parameters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\struct State;
        \\trait Sip {
        \\    fn c_rounds(_: &mut State);
        \\    fn d_rounds(_: &mut State);
        \\}
    ;

    var analysis = try analyzeCstForTest(allocator, source, null, false);
    defer analysis.g.deinit();
    const state_id = findEntityId(&analysis.g, .struct_, "State") orelse
        return error.TestUnexpectedResult;
    const trait_id = findEntityId(&analysis.g, .trait_, "Sip") orelse
        return error.TestUnexpectedResult;
    const trait_body = switch (analysis.bodies_list.items[trait_id]) {
        .trait_ => |body| body,
        else => return error.TestUnexpectedResult,
    };
    const expected_names = [_][]const u8{ "c_rounds", "d_rounds" };
    try std.testing.expectEqual(expected_names.len, trait_body.methods.len);
    for (trait_body.methods, expected_names) |method, expected_name| {
        try std.testing.expectEqualStrings(expected_name, method.name);
        try std.testing.expectEqual(@as(usize, 1), method.params.len);
        try std.testing.expectEqualStrings("__r2z_param_0", method.params[0].name);
        const reference = switch (method.params[0].ty) {
            .reference => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expect(reference.mut);
        const path = switch (reference.pointee) {
            .path => |value| value,
            else => return error.TestUnexpectedResult,
        };
        const target_id = path.segments[path.segments.len - 1].id orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(state_id, target_id);
    }
}

test "cst accepts raw pointer function parameters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\pub unsafe fn read_u64(ptr: *const u8) -> u64 {
        \\    0
        \\}
    ;

    var analysis = try analyzeCstForTest(allocator, source, null, false);
    defer analysis.g.deinit();
    const function_id = findEntityId(&analysis.g, .fn_, "read_u64") orelse
        return error.TestUnexpectedResult;
    const function_body = switch (analysis.bodies_list.items[function_id]) {
        .fn_ => |body| body,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), function_body.params.len);
    try std.testing.expectEqualStrings("ptr", function_body.params[0].name);
    const pointer = switch (function_body.params[0].ty) {
        .raw_ptr => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(!pointer.mut);
    try std.testing.expect(pointer.pointee == .prim);
    try std.testing.expectEqual(types.Prim.u8, pointer.pointee.prim);
}

test "cst accepts tuple mut function parameters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\struct State;
        \\fn hash(
        \\    buf: &[u8],
        \\    (mut a, mut b, mut c, mut d): (u64, u64, u64, u64),
        \\) -> State {
        \\    let _ = buf;
        \\    State
        \\}
    ;

    var analysis = try analyzeCstForTest(allocator, source, null, false);
    defer analysis.g.deinit();
    const state_id = findEntityId(&analysis.g, .struct_, "State") orelse
        return error.TestUnexpectedResult;
    const function_id = findEntityId(&analysis.g, .fn_, "hash") orelse
        return error.TestUnexpectedResult;
    const function_body = switch (analysis.bodies_list.items[function_id]) {
        .fn_ => |body| body,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 2), function_body.params.len);
    try std.testing.expectEqualStrings("buf", function_body.params[0].name);
    try std.testing.expectEqualStrings("__r2z_param_1", function_body.params[1].name);
    const tuple = switch (function_body.params[1].ty) {
        .tuple => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 4), tuple.len);
    for (tuple) |element| {
        try std.testing.expect(element == .prim);
        try std.testing.expect(element.prim == .u64);
    }
    const return_path = switch (function_body.ret) {
        .path => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const return_id = return_path.segments[return_path.segments.len - 1].id orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(state_id, return_id);

    const full_ir = try pipeline.analyzeSource(allocator, "tuple_parameter", "2021", source);
    const lowered_function_id = findEntityId(&full_ir.graph, .fn_, "hash") orelse
        return error.TestUnexpectedResult;
    const lowered_function = switch (full_ir.bodies.bodies[lowered_function_id]) {
        .fn_ => |body| body,
        else => return error.TestUnexpectedResult,
    };
    if (lowered_function.body >= full_ir.bodies.exprs.len) {
        return error.TestUnexpectedResult;
    }
    const body_block = switch (full_ir.bodies.exprs[lowered_function.body].kind) {
        .block => |block| block,
        else => return error.TestUnexpectedResult,
    };
    if (body_block.statements.len == 0) return error.TestUnexpectedResult;
    const prologue_statement_id = body_block.statements[0];
    if (prologue_statement_id >= full_ir.bodies.stmts.len) {
        return error.TestUnexpectedResult;
    }
    const prologue = switch (full_ir.bodies.stmts[prologue_statement_id].kind) {
        .let => |statement| statement,
        else => return error.TestUnexpectedResult,
    };
    if (prologue.pattern >= full_ir.bodies.pats.len) return error.TestUnexpectedResult;
    const parameter_pattern = switch (full_ir.bodies.pats[prologue.pattern].kind) {
        .tuple => |pattern| pattern,
        else => return error.TestUnexpectedResult,
    };
    const expected_bindings = [_][]const u8{ "a", "b", "c", "d" };
    try std.testing.expectEqual(expected_bindings.len, parameter_pattern.elements.len);
    for (parameter_pattern.elements, expected_bindings) |pattern_id, expected_name| {
        if (pattern_id >= full_ir.bodies.pats.len) return error.TestUnexpectedResult;
        const binding = switch (full_ir.bodies.pats[pattern_id].kind) {
            .binding => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqualStrings(expected_name, binding.name);
        try std.testing.expect(binding.mutable);
    }
    const initializer_id = prologue.init orelse return error.TestUnexpectedResult;
    if (initializer_id >= full_ir.bodies.exprs.len) return error.TestUnexpectedResult;
    const initializer = switch (full_ir.bodies.exprs[initializer_id].kind) {
        .path => |path| path,
        else => return error.TestUnexpectedResult,
    };
    const synthetic_parameter = full_ir.graph.symbol_table.get(initializer.def) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("__r2z_param_1", synthetic_parameter.name);
    var synthetic_uses: usize = 0;
    for (full_ir.bodies.exprs) |expression| {
        switch (expression.kind) {
            .path => |path| {
                if (path.def == initializer.def) synthetic_uses += 1;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), synthetic_uses);
}

test "cst retains xxh32 tuple-typed struct fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\pub struct Xxh32 {
        \\    total_len: u32,
        \\    is_large_len: bool,
        \\    v: (u32, u32, u32, u32),
        \\    mem: [u32; 4],
        \\    mem_size: u32,
        \\}
    ;

    var analysis = try analyzeCstForTest(allocator, source, null, false);
    defer analysis.g.deinit();
    const struct_id = findEntityId(&analysis.g, .struct_, "Xxh32") orelse
        return error.TestUnexpectedResult;
    const structure = switch (analysis.bodies_list.items[struct_id]) {
        .struct_ => |body| body,
        else => return error.TestUnexpectedResult,
    };
    const expected_names = [_][]const u8{
        "total_len",
        "is_large_len",
        "v",
        "mem",
        "mem_size",
    };
    try std.testing.expectEqual(expected_names.len, structure.fields.len);
    for (structure.fields, expected_names) |field, expected_name| {
        try std.testing.expectEqualStrings(expected_name, field.name);
    }
    const tuple = switch (structure.fields[2].ty) {
        .tuple => |elements| elements,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 4), tuple.len);
    for (tuple) |element| {
        try std.testing.expect(element == .prim);
        try std.testing.expectEqual(types.Prim.u32, element.prim);
    }
}

test "cst resolves Self returns in generic local impls" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\trait Make<T> {
        \\    fn make() -> Self;
        \\}
        \\impl<T> Make<T> for u16 {
        \\    fn make() -> Self {
        \\        0
        \\    }
        \\}
    ;

    var analysis = try analyzeCstForTest(allocator, source, null, false);
    defer analysis.g.deinit();
    const function_id = findEntityId(&analysis.g, .fn_, "make") orelse
        return error.TestUnexpectedResult;
    const function_body = switch (analysis.bodies_list.items[function_id]) {
        .fn_ => |body| body,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(function_body.ret == .prim);
    try std.testing.expect(function_body.ret.prim == .u16);
}

test "cst preserves local associated InputType projections" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\trait FletcherAccumulator { type InputType; }
        \\struct Fletcher<T: FletcherAccumulator> { value: T }
        \\impl<T: FletcherAccumulator> Fletcher<T> {
        \\    fn update(
        \\        &mut self,
        \\        input: T::InputType,
        \\    ) {
        \\        let _ = input;
        \\    }
        \\}
    ;

    var analysis = try analyzeCstForTest(allocator, source, null, false);
    defer analysis.g.deinit();
    const trait_id = findEntityId(&analysis.g, .trait_, "FletcherAccumulator") orelse
        return error.TestUnexpectedResult;
    const function_id = findEntityId(&analysis.g, .fn_, "update") orelse
        return error.TestUnexpectedResult;
    const function_body = switch (analysis.bodies_list.items[function_id]) {
        .fn_ => |body| body,
        else => return error.TestUnexpectedResult,
    };
    var projection: ?types.Path = null;
    for (function_body.params) |parameter| {
        if (!std.mem.eql(u8, parameter.name, "input")) continue;
        projection = switch (parameter.ty) {
            .path => |path| path,
            else => return error.TestUnexpectedResult,
        };
    }
    const path = projection orelse return error.TestUnexpectedResult;
    const expected_segments = [_][]const u8{ "T", "FletcherAccumulator", "InputType" };
    try std.testing.expectEqual(expected_segments.len, path.segments.len);
    for (path.segments, expected_segments) |segment, expected| {
        try std.testing.expectEqualStrings(expected, segment.name);
    }
    try std.testing.expect(path.segments[0].id == null);
    try std.testing.expectEqual(trait_id, path.segments[1].id.?);
    try std.testing.expect(path.segments[2].id == null);
}

test "cst resolves array impl targets used by hex" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\trait FromHex { type Error; }
        \\impl FromHex for [u8; 1] {
        \\    type Error = u8;
        \\    fn from_hex() {}
        \\}
    ;

    var analysis = try analyzeCstForTest(allocator, source, null, false);
    defer analysis.g.deinit();
    try std.testing.expect(findEntityId(&analysis.g, .fn_, "from_hex") != null);
}

test "cst resolves Self associated types in generic trait methods" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\trait Integer {
        \\    type Buffer: 'static;
        \\    fn write(self, buf: &mut Self::Buffer) -> &str;
        \\}
    ;

    var analysis = try analyzeCstForTest(allocator, source, null, false);
    defer analysis.g.deinit();
    const trait_id = findEntityId(&analysis.g, .trait_, "Integer") orelse
        return error.TestUnexpectedResult;
    const trait_body = switch (analysis.bodies_list.items[trait_id]) {
        .trait_ => |body| body,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), trait_body.methods.len);
    try std.testing.expectEqual(@as(usize, 1), trait_body.methods[0].params.len);
    const buffer_type = switch (trait_body.methods[0].params[0].ty) {
        .reference => |value| value.pointee,
        else => return error.TestUnexpectedResult,
    };
    const buffer_path = switch (buffer_type) {
        .path => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const expected_segments = [_][]const u8{ "Self", "Integer", "Buffer" };
    try std.testing.expectEqual(expected_segments.len, buffer_path.segments.len);
    for (buffer_path.segments, expected_segments) |segment, expected| {
        try std.testing.expectEqualStrings(expected, segment.name);
    }
    try std.testing.expect(buffer_path.segments[0].id == null);
    try std.testing.expectEqual(trait_id, buffer_path.segments[1].id.?);
    try std.testing.expect(buffer_path.segments[2].id == null);
}

test "cst resolves concrete impl Self associated returns in both method bodies" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\trait Iterator {
        \\    type Item;
        \\    fn next(&mut self) -> Option<Self::Item>;
        \\}
        \\struct BytesToHexChars;
        \\impl Iterator for BytesToHexChars {
        \\    type Item = char;
        \\    fn next(&mut self) -> Option<Self::Item> { None }
        \\}
    ;

    var analysis = try analyzeCstForTest(allocator, source, null, false);
    defer analysis.g.deinit();
    const function_id = findEntityId(&analysis.g, .fn_, "next") orelse
        return error.TestUnexpectedResult;
    const function_body = switch (analysis.bodies_list.items[function_id]) {
        .fn_ => |body| body,
        else => return error.TestUnexpectedResult,
    };
    const function_item = switch (function_body.ret) {
        .option => |item| item.*,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(function_item == .prim);
    try std.testing.expect(function_item.prim == .char);

    const struct_id = findEntityId(&analysis.g, .struct_, "BytesToHexChars") orelse
        return error.TestUnexpectedResult;
    const structure = switch (analysis.bodies_list.items[struct_id]) {
        .struct_ => |body| body,
        else => return error.TestUnexpectedResult,
    };
    var copied_return: ?types.Type = null;
    for (structure.methods) |method| {
        if (!std.mem.eql(u8, method.name, "next")) continue;
        copied_return = method.ret;
    }
    const copied_item = switch (copied_return orelse return error.TestUnexpectedResult) {
        .option => |item| item.*,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(copied_item == .prim);
    try std.testing.expect(copied_item.prim == .char);
}

test "cst resolves Self in primitive trait impl associated constants" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\trait FletcherAccumulator: Sized {
        \\    const MASK: Self;
        \\}
        \\impl FletcherAccumulator for u16 {
        \\    const MASK: Self = 255;
        \\}
    ;

    var analysis = try analyzeCstForTest(allocator, source, null, false);
    defer analysis.g.deinit();
    try std.testing.expect(
        findEntityId(&analysis.g, .impl_, "FletcherAccumulator for u16") != null,
    );
    const mask_id = findEntityId(&analysis.g, .const_, "MASK") orelse
        return error.TestUnexpectedResult;
    const mask_body = switch (analysis.bodies_list.items[mask_id]) {
        .const_ => |body| body,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(mask_body.ty == .prim);
    try std.testing.expect(mask_body.ty.prim == .u16);
}

// These initializer tests use the full pipeline because their assertions inspect
// expression nodes after CST extraction and method resolution.

test "pipeline resolves referenced struct literal const initializers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\struct AsciiSet { mask: [u32; 4] }
        \\const CONTROLS: &AsciiSet = &AsciiSet {
        \\    mask: [!0_u32, 0, 0, 1 << (0x7F_u32 % 32)],
        \\};
    ;

    const rust_ir = try pipeline.analyzeSource(allocator, "percent_controls", "2021", source);
    try ir.validateForTranslation(&rust_ir);
    const ascii_set_id = findEntityId(&rust_ir.graph, .struct_, "AsciiSet") orelse
        return error.TestUnexpectedResult;
    const initializer = try pipelineConstInitializer(&rust_ir, "CONTROLS");
    const reference = switch (initializer.kind) {
        .unary => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const reference_mode = switch (reference.op) {
        .ref => |mode| mode,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(exprs.ReceiverMode.shared, reference_mode);
    if (reference.operand >= rust_ir.bodies.exprs.len) return error.TestUnexpectedResult;
    const literal = switch (rust_ir.bodies.exprs[reference.operand].kind) {
        .struct_lit => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(ascii_set_id, literal.def);
    try std.testing.expectEqual(@as(usize, 1), literal.fields.len);
    try std.testing.expectEqualStrings("mask", literal.fields[0].field);
    if (literal.fields[0].value >= rust_ir.bodies.exprs.len) {
        return error.TestUnexpectedResult;
    }
    const mask_expr = rust_ir.bodies.exprs[literal.fields[0].value];
    const mask = switch (mask_expr.kind) {
        .array => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const mask_type_id = mask_expr.ty orelse return error.TestUnexpectedResult;
    if (mask_type_id >= rust_ir.types.len) return error.TestUnexpectedResult;
    try std.testing.expectEqual(types.Type{ .prim = .u32 }, rust_ir.types[mask_type_id]);
    const expected_values = [_]i128{ 4_294_967_295, 0, 0, 2_147_483_648 };
    try std.testing.expectEqual(expected_values.len, mask.elements.len);
    try std.testing.expect(mask.repeat == null);
    for (mask.elements, expected_values) |element_id, expected| {
        if (element_id >= rust_ir.bodies.exprs.len) return error.TestUnexpectedResult;
        const value = switch (rust_ir.bodies.exprs[element_id].kind) {
            .literal => |literal_value| switch (literal_value) {
                .int => |int_value| int_value.value,
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(expected, value);
    }
}

test "pipeline resolves chained const method initializers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\struct AsciiSet { mask: [u32; 2] }
        \\impl AsciiSet {
        \\    const fn add(&self, byte: u8) -> Self {
        \\        AsciiSet { mask: self.mask }
        \\    }
        \\}
        \\const CONTROLS: &AsciiSet = &AsciiSet { mask: [0, 0] };
        \\const NON_ALPHANUMERIC: &AsciiSet = &CONTROLS.add(b' ').add(b'!');
    ;

    const rust_ir = try pipeline.analyzeSource(allocator, "percent_chain", "2021", source);
    try ir.validateForTranslation(&rust_ir);
    const controls_id = findEntityId(&rust_ir.graph, .const_, "CONTROLS") orelse
        return error.TestUnexpectedResult;
    const add_id = findEntityId(&rust_ir.graph, .fn_, "add") orelse
        return error.TestUnexpectedResult;
    const ascii_set_id = findEntityId(&rust_ir.graph, .struct_, "AsciiSet") orelse
        return error.TestUnexpectedResult;
    const initializer = try pipelineConstInitializer(&rust_ir, "NON_ALPHANUMERIC");
    const reference = switch (initializer.kind) {
        .unary => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const reference_mode = switch (reference.op) {
        .ref => |mode| mode,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(exprs.ReceiverMode.shared, reference_mode);

    var receiver_id = reference.operand;
    for ([_]i128{ 33, 32 }) |expected_byte| {
        if (receiver_id >= rust_ir.bodies.exprs.len) return error.TestUnexpectedResult;
        const call = switch (rust_ir.bodies.exprs[receiver_id].kind) {
            .method_call => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(add_id, call.method);
        const call_type_id = rust_ir.bodies.exprs[receiver_id].ty orelse
            return error.TestUnexpectedResult;
        if (call_type_id >= rust_ir.types.len) return error.TestUnexpectedResult;
        const call_type = switch (rust_ir.types[call_type_id]) {
            .path => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(usize, 1), call_type.segments.len);
        try std.testing.expectEqual(ascii_set_id, call_type.segments[0].id orelse
            return error.TestUnexpectedResult);
        try std.testing.expectEqual(exprs.ReceiverMode.shared, call.receiver_mode);
        try std.testing.expectEqual(@as(usize, 1), call.args.len);
        if (call.args[0] >= rust_ir.bodies.exprs.len) return error.TestUnexpectedResult;
        const argument = switch (rust_ir.bodies.exprs[call.args[0]].kind) {
            .literal => |literal_value| switch (literal_value) {
                .int => |int_value| int_value,
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(expected_byte, argument.value);
        try std.testing.expectEqualStrings("u8", argument.ty_suffix orelse
            return error.TestUnexpectedResult);
        receiver_id = call.receiver;
    }
    if (receiver_id >= rust_ir.bodies.exprs.len) return error.TestUnexpectedResult;
    const base = switch (rust_ir.bodies.exprs[receiver_id].kind) {
        .path => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(controls_id, base.def);
}

/// The value expression of a function whose body is a block with a tail.
fn fnBodyTail(rust_ir: *const ir.RustIr, fn_id: ir.spine.EntityId) exprs.NodeId {
    const body_id = switch (rust_ir.bodies.bodies[fn_id]) {
        .fn_ => |body| body.body,
        else => return 0,
    };
    const block = switch (rust_ir.bodies.exprs[body_id].kind) {
        .block => |value| value,
        else => return body_id,
    };
    return block.tail orelse 0;
}

test "pipeline lowers a unit enum variant path to an enum_variant value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\pub enum Signal {
        \\    Stop,
        \\    Level(u8),
        \\}
        \\pub fn stop() -> Signal {
        \\    Signal::Stop
        \\}
    ;

    const rust_ir = try pipeline.analyzeSource(allocator, "unit_variant_path", "2021", source);
    try ir.validateForTranslation(&rust_ir);
    const signal_id = findEntityId(&rust_ir.graph, .enum_, "Signal") orelse
        return error.TestUnexpectedResult;
    const stop_id = findEntityId(&rust_ir.graph, .fn_, "stop") orelse
        return error.TestUnexpectedResult;
    const body_id = fnBodyTail(&rust_ir, stop_id);
    // A unit variant is a value in Rust, so the path must not survive as a
    // bare path naming the enum type.
    const variant = switch (rust_ir.bodies.exprs[body_id].kind) {
        .enum_variant => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(signal_id, variant.def);
    try std.testing.expectEqualStrings("Stop", variant.variant);
    try std.testing.expectEqual(@as(usize, 0), variant.tuple_fields.len);
    try std.testing.expectEqual(@as(usize, 0), variant.named_fields.len);
}

test "pipeline lowers a unit variant payload wrapped in Result::Err" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\pub enum Signal {
        \\    Stop,
        \\    Level(u8),
        \\}
        \\pub fn stop() -> Result<u8, Signal> {
        \\    Err(Signal::Stop)
        \\}
    ;

    const rust_ir = try pipeline.analyzeSource(allocator, "unit_variant_payload", "2021", source);
    try ir.validateForTranslation(&rust_ir);
    const signal_id = findEntityId(&rust_ir.graph, .enum_, "Signal") orelse
        return error.TestUnexpectedResult;
    const stop_id = findEntityId(&rust_ir.graph, .fn_, "stop") orelse
        return error.TestUnexpectedResult;
    const body_id = fnBodyTail(&rust_ir, stop_id);
    const wrapper = switch (rust_ir.bodies.exprs[body_id].kind) {
        .enum_variant => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Err", wrapper.variant);
    try std.testing.expectEqual(@as(usize, 1), wrapper.tuple_fields.len);
    const payload_id = wrapper.tuple_fields[0];
    if (payload_id >= rust_ir.bodies.exprs.len) return error.TestUnexpectedResult;
    const payload = switch (rust_ir.bodies.exprs[payload_id].kind) {
        .enum_variant => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(signal_id, payload.def);
    try std.testing.expectEqualStrings("Stop", payload.variant);
    try std.testing.expectEqual(@as(usize, 0), payload.tuple_fields.len);
    try std.testing.expectEqual(@as(usize, 0), payload.named_fields.len);
}

test "expression macro captures retain whitespace before delimiters" {
    const alloc = std.testing.allocator;
    var definition = try expand.parseMacroRulesDefinition(alloc, "macro_rules! pick { ($buf:expr, $index:expr, $ty:ident) => { ($buf[$index] as $ty) }; }");
    defer definition.deinit(alloc);
    const output = try expand.expandMacroRules(alloc, definition, "(buf, start + i, u32)");
    defer alloc.free(output);
    try std.testing.expectEqualStrings("(buf[start + i] as u32)", std.mem.trim(u8, output, " \t\r\n"));
}

// ── built-in macro shape audit ───────────────────────────────────────────────
//
// Every built-in macro the corpus uses is classified here and handed to the
// frontend as a token-tree argument list (or a `vec!` element/repeat pair).
// These tests pin that expanded SHAPE — the items, their order and their
// count — because that is what the lowering consumes. Asserting the source
// text would pin nothing: the same text yields a different shape as soon as
// one comment, raw string or wildcard changes what the item scan sees.

test "splitMacroArgs keeps comment and raw string bytes inside one argument" {
    const alloc = std.testing.allocator;

    {
        // The comma lives in a comment, so it separates nothing: three
        // arguments here would bind operands that the source never had.
        const args = try expand.splitMacroArgs(alloc, "(a /*,*/ b, c)");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 2), args.len);
        try std.testing.expectEqualStrings("a /*,*/ b", args[0]);
        try std.testing.expectEqualStrings("c", args[1]);
    }
    {
        // A delimiter inside a comment opens no nesting level; if it did,
        // every comma after it would stop being top level.
        const args = try expand.splitMacroArgs(alloc, "(a /* ( ) ; */ b, c)");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 2), args.len);
        try std.testing.expectEqualStrings("a /* ( ) ; */ b", args[0]);
        try std.testing.expectEqualStrings("c", args[1]);
    }
    {
        // A line comment runs to the newline, and its comma stays in the
        // argument it was written in.
        const args = try expand.splitMacroArgs(alloc, "(a // ,\n b, c)");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 2), args.len);
        try std.testing.expectEqualStrings("a // ,\n b", args[0]);
        try std.testing.expectEqualStrings("c", args[1]);
    }
    {
        // A raw string ends at its own terminator, not at its first quote.
        const args = try expand.splitMacroArgs(alloc, "(r#\"a\"b, c\"#, d)");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 2), args.len);
        try std.testing.expectEqualStrings("r#\"a\"b, c\"#", args[0]);
        try std.testing.expectEqualStrings("d", args[1]);
    }
}

test "splitMacroArgs pins the corpus assert family shapes" {
    const alloc = std.testing.allocator;

    try std.testing.expect(expand.isTestingAssert(expand.identifyMacro("assert!")));
    try std.testing.expect(expand.isTestingAssert(expand.identifyMacro("assert_eq!")));
    try std.testing.expect(expand.isTestingAssert(expand.identifyMacro("assert_ne!")));
    try std.testing.expect(!expand.isTestingAssert(expand.identifyMacro("format!")));

    {
        // No message: the condition is the whole argument list.
        const args = try expand.splitMacroArgs(alloc, "(a > b)");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 1), args.len);
        try std.testing.expectEqualStrings("a > b", args[0]);
    }
    {
        // With a message: condition, format literal, then its arguments.
        const args = try expand.splitMacroArgs(alloc, "(a > b, \"a must exceed b: {}\", a)");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 3), args.len);
        try std.testing.expectEqualStrings("a > b", args[0]);
        try std.testing.expectEqualStrings("\"a must exceed b: {}\"", args[1]);
        try std.testing.expectEqualStrings("a", args[2]);
    }
    {
        const args = try expand.splitMacroArgs(alloc, "(left, right)");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 2), args.len);
        try std.testing.expectEqualStrings("left", args[0]);
        try std.testing.expectEqualStrings("right", args[1]);
    }
    {
        const args = try expand.splitMacroArgs(
            alloc,
            "(left, right, \"{} != {}\", left, right)",
        );
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 5), args.len);
        try std.testing.expectEqualStrings("left", args[0]);
        try std.testing.expectEqualStrings("right", args[1]);
        try std.testing.expectEqualStrings("\"{} != {}\"", args[2]);
        try std.testing.expectEqualStrings("left", args[3]);
        try std.testing.expectEqualStrings("right", args[4]);
    }
    {
        const args = try expand.splitMacroArgs(alloc, "(left, right, \"not equal\")");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 3), args.len);
        try std.testing.expectEqualStrings("left", args[0]);
        try std.testing.expectEqualStrings("right", args[1]);
        try std.testing.expectEqualStrings("\"not equal\"", args[2]);
    }
    {
        // A nested `matches!` is one condition: its own commas and its `_`
        // wildcard stay inside it.
        const args = try expand.splitMacroArgs(alloc, "(matches!(e, Some(Variant(_, b))), true)");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 2), args.len);
        try std.testing.expectEqualStrings("matches!(e, Some(Variant(_, b)))", args[0]);
        try std.testing.expectEqualStrings("true", args[1]);
    }
}

test "splitMacroArgs pins the write, writeln and format shapes" {
    const alloc = std.testing.allocator;

    try std.testing.expectEqual(expand.MacroKind.write, expand.identifyMacro("write!"));
    try std.testing.expectEqual(expand.MacroKind.writeln, expand.identifyMacro("writeln!"));
    try std.testing.expectEqual(expand.MacroKind.format, expand.identifyMacro("format!"));
    try std.testing.expectEqual(expand.MacroKind.format, expand.identifyMacro("std::format!"));

    {
        // writer, format literal, then one value per placeholder.
        const args = try expand.splitMacroArgs(alloc, "(out, \"{}\", value)");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 3), args.len);
        try std.testing.expectEqualStrings("out", args[0]);
        try std.testing.expectEqualStrings("\"{}\"", args[1]);
        try std.testing.expectEqualStrings("value", args[2]);
    }
    {
        // A comma inside the format literal is part of the literal.
        const args = try expand.splitMacroArgs(alloc, "(out, \"{0},{1}\", a, b)");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 4), args.len);
        try std.testing.expectEqualStrings("out", args[0]);
        try std.testing.expectEqualStrings("\"{0},{1}\"", args[1]);
        try std.testing.expectEqualStrings("a", args[2]);
        try std.testing.expectEqualStrings("b", args[3]);
    }
    {
        // `writeln!(out)` carries the writer alone; the template is empty.
        const args = try expand.splitMacroArgs(alloc, "(out)");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 1), args.len);
        try std.testing.expectEqualStrings("out", args[0]);
    }
    {
        // `format!` has no writer: the literal is the first argument.
        const args = try expand.splitMacroArgs(alloc, "(\"{} and {}\", a, b)");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 3), args.len);
        try std.testing.expectEqualStrings("\"{} and {}\"", args[0]);
        try std.testing.expectEqualStrings("a", args[1]);
        try std.testing.expectEqualStrings("b", args[2]);
    }
    {
        // A raw string literal keeps its own commas and quotes, so the writer
        // stays first and the values stay last.
        const args = try expand.splitMacroArgs(alloc, "(out, r#\"a, \"b\"\"#, c)");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 3), args.len);
        try std.testing.expectEqualStrings("out", args[0]);
        try std.testing.expectEqualStrings("r#\"a, \"b\"\"#", args[1]);
        try std.testing.expectEqualStrings("c", args[2]);
    }
}

test "matches token trees keep both operands and their wildcards" {
    const alloc = std.testing.allocator;

    // `matches!` is not a built-in kind. It must survive expansion untouched so
    // that the pattern it carries reaches the pattern lowering whole.
    try std.testing.expectEqual(expand.MacroKind.custom, expand.identifyMacro("matches!"));
    try std.testing.expectEqual(expand.MacroKind.custom, expand.identifyMacro("std::matches"));
    try std.testing.expectEqual(expand.MacroKind.custom, expand.identifyMacro("core::matches!"));

    {
        const args = try expand.splitMacroArgs(
            alloc,
            "(limits, RangeLimits::HalfOpen(_) | RangeLimits::Closed(_))",
        );
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 2), args.len);
        try std.testing.expectEqualStrings("limits", args[0]);
        try std.testing.expectEqualStrings(
            "RangeLimits::HalfOpen(_) | RangeLimits::Closed(_)",
            args[1],
        );
    }
    {
        const args = try expand.splitMacroArgs(alloc, "(&*body, Expr::Block(_) | Expr::Path(_))");
        defer alloc.free(args);
        try std.testing.expectEqual(@as(usize, 2), args.len);
        try std.testing.expectEqualStrings("&*body", args[0]);
        try std.testing.expectEqualStrings("Expr::Block(_) | Expr::Path(_)", args[1]);
    }
}

test "expandSourceMacros preserves every builtin invocation while expanding siblings" {
    const allocator = std.testing.allocator;
    var table = expand.MacroTable.init(allocator);
    defer table.deinit();

    var definition = try expand.parseMacroRulesDefinition(
        allocator,
        // `{2}` not `{ 2 }`: expansion is byte-preserving, so template padding
        // lands in the output and would make the `const N` assertion below
        // depend on whitespace the fixture chose, not on what it pins.
        "macro_rules! two { () => {2}; }",
    );
    table.register(definition.name, definition) catch |err| {
        definition.deinit(allocator);
        return err;
    };

    const source =
        \\fn probe(e: u8, x: i64, out: u8, y: i64) -> bool {
        \\    matches!(e, Variant(_, 2))
        \\}
        \\const N: u8 = two!();
        \\fn shapes(n: usize) {
        \\    let a = vec![1, 2, 3];
        \\    let b = vec![0u8; 4];
        \\    let c = vec![7u8; n];
        \\    assert!(x > 0, "x must be positive");
        \\    assert_eq!(x, y);
        \\    write!(out, "{}", x);
        \\    format!("{} + {}", x, y);
        \\}
    ;
    const expanded = try expand.expandSourceMacros(allocator, &table, source, .{});
    defer allocator.free(expanded);

    // The built-ins are not rewritten here — the frontend lowers them from the
    // same token trees — so every separator and every `_` must still be there.
    try std.testing.expect(std.mem.indexOf(u8, expanded, "matches!(e, Variant(_, 2))") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "vec![1, 2, 3]") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "vec![0u8; 4]") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "vec![7u8; n]") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, expanded, "assert!(x > 0, \"x must be positive\")") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, expanded, "assert_eq!(x, y)") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "write!(out, \"{}\", x)") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "format!(\"{} + {}\", x, y)") != null);
    // The sibling macro_rules! still expands, so the pass-through above is not
    // the whole of what this pass does.
    try std.testing.expect(std.mem.indexOf(u8, expanded, "const N: u8 = 2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "two!") == null);
}

test "parseVecInvocation keeps every item of a corpus vec" {
    const alloc = std.testing.allocator;

    {
        // A wildcard is an item. Dropping it — as a named-child walk drops an
        // anonymous `_` — is what makes the backend bind the wrong element.
        const raw = "[Pair(_, 2), 3]";
        var invocation: expand.VecInvocation = try expand.parseVecInvocation(alloc, raw);
        defer invocation.deinit(alloc);
        const elements = switch (invocation) {
            .elements => |items| items,
            .repeat => {
                try std.testing.expect(false);
                return;
            },
        };
        try std.testing.expectEqual(@as(usize, 2), elements.len);
        try std.testing.expectEqualStrings("Pair(_, 2)", elements[0]);
        try std.testing.expectEqualStrings("3", elements[1]);
        try std.testing.expectEqual(
            @intFromPtr(raw[1..2].ptr),
            @intFromPtr(elements[0].ptr),
        );
    }
    {
        // A semicolon inside a literal or a comment is not the repeat
        // separator, and a comma inside a comment is not an item boundary.
        const cases = [_]struct { raw: []const u8, first: []const u8, second: []const u8 }{
            .{ .raw = "[\"left;right\", 7]", .first = "\"left;right\"", .second = "7" },
            .{ .raw = "[r#\"left;right\"#, 7]", .first = "r#\"left;right\"#", .second = "7" },
            .{ .raw = "[1 /* ; */, 7]", .first = "1 /* ; */", .second = "7" },
            .{ .raw = "[a /* , */, c]", .first = "a /* , */", .second = "c" },
            .{ .raw = "[a /* ( */, c]", .first = "a /* ( */", .second = "c" },
        };
        for (cases) |case| {
            var invocation: expand.VecInvocation = try expand.parseVecInvocation(alloc, case.raw);
            defer invocation.deinit(alloc);
            const elements = switch (invocation) {
                .elements => |items| items,
                .repeat => {
                    try std.testing.expect(false);
                    return;
                },
            };
            try std.testing.expectEqual(@as(usize, 2), elements.len);
            try std.testing.expectEqualStrings(case.first, elements[0]);
            try std.testing.expectEqualStrings(case.second, elements[1]);
        }
    }
    {
        // `vec![e; N]` is one element and one count, both borrowed from the
        // token tree, never merged into a single item.
        const raw = "[0u8; n]";
        var invocation: expand.VecInvocation = try expand.parseVecInvocation(alloc, raw);
        defer invocation.deinit(alloc);
        const repeat = switch (invocation) {
            .repeat => |parts| parts,
            .elements => {
                try std.testing.expect(false);
                return;
            },
        };
        try std.testing.expectEqualStrings("0u8", repeat.element);
        try std.testing.expectEqualStrings("n", repeat.count);
        try std.testing.expectEqual(
            @intFromPtr(raw[1..2].ptr),
            @intFromPtr(repeat.element.ptr),
        );
    }
    {
        // A block element keeps its own semicolons; only the top-level one
        // separates the element from the count.
        var invocation: expand.VecInvocation =
            try expand.parseVecInvocation(alloc, "[{ let n = 2; n }; 3]");
        defer invocation.deinit(alloc);
        const repeat = switch (invocation) {
            .repeat => |parts| parts,
            .elements => {
                try std.testing.expect(false);
                return;
            },
        };
        try std.testing.expectEqualStrings("{ let n = 2; n }", repeat.element);
        try std.testing.expectEqualStrings("3", repeat.count);
    }
    {
        // An empty vec has no elements and no repeat.
        var invocation: expand.VecInvocation = try expand.parseVecInvocation(alloc, "[]");
        defer invocation.deinit(alloc);
        const elements = switch (invocation) {
            .elements => |items| items,
            .repeat => {
                try std.testing.expect(false);
                return;
            },
        };
        try std.testing.expectEqual(@as(usize, 0), elements.len);
    }
}

test "macro_rules fragment captures ignore separators inside comments" {
    const alloc = std.testing.allocator;
    var definition = try expand.parseMacroRulesDefinition(
        alloc,
        "macro_rules! list_all { ($($e:expr),*) => { [$($e),*] }; }",
    );
    defer definition.deinit(alloc);

    // The comma inside the comment is not the repetition separator, so the
    // first capture is the whole `a /*,*/ b` expression. Truncating it at the
    // comment's comma yields a fragment that does not parse.
    const output = try expand.expandMacroRules(alloc, definition, "(a /*,*/ b, c)");
    defer alloc.free(output);
    try std.testing.expectEqualStrings(
        "[a /*,*/ b,\nc]",
        std.mem.trim(u8, output, " \t\r\n"),
    );
}

test "macro_rules fragment captures ignore separators inside raw strings" {
    const alloc = std.testing.allocator;
    var definition = try expand.parseMacroRulesDefinition(
        alloc,
        "macro_rules! list_all { ($($e:expr),*) => { [$($e),*] }; }",
    );
    defer definition.deinit(alloc);

    // The raw string holds a quote, so only its own terminator ends it; the
    // comma it holds is not the repetition separator.
    const output = try expand.expandMacroRules(alloc, definition, "(r#\"a\"b, c\"#, d)");
    defer alloc.free(output);
    try std.testing.expectEqualStrings(
        "[r#\"a\"b, c\"#,\nd]",
        std.mem.trim(u8, output, " \t\r\n"),
    );
}

/// The block of a function whose body is a block, or null when it is not one.
fn fnBodyBlock(rust_ir: *const ir.RustIr, fn_id: ir.spine.EntityId) ?exprs.BlockExpr {
    const body_id = switch (rust_ir.bodies.bodies[fn_id]) {
        .fn_ => |body| body.body,
        else => return null,
    };
    return switch (rust_ir.bodies.exprs[body_id].kind) {
        .block => |value| value,
        else => return null,
    };
}

/// The one expression statement of a function body, or null when the body is
/// not exactly one expression statement.
fn fnBodyStatementExpr(rust_ir: *const ir.RustIr, fn_id: ir.spine.EntityId) ?exprs.NodeId {
    const block = fnBodyBlock(rust_ir, fn_id) orelse return null;
    if (block.statements.len != 1 or block.tail != null) return null;
    const statement = rust_ir.bodies.stmts[block.statements[0]];
    return switch (statement.kind) {
        .expr => |id| id,
        else => null,
    };
}

/// The condition node an assertion marker carries.
fn assertionCondition(marker: exprs.Unsupported) ?exprs.NodeId {
    const prefix = "assertion:";
    if (!std.mem.startsWith(u8, marker.reason, prefix)) return null;
    return std.fmt.parseUnsigned(exprs.NodeId, marker.reason[prefix.len..], 10) catch null;
}

test "pipeline expands the corpus vec forms into lowerable literal shapes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\pub fn vecs(n: usize) {
        \\    let listed = vec![1, 2, 3];
        \\    let counted = vec![0u8; 4];
        \\    let computed = vec![7u8; n];
        \\}
    ;

    const rust_ir = try pipeline.analyzeSource(allocator, "vec_macro_shapes", "2021", source);

    var listed: ?exprs.VecLit = null;
    var literal_repeat: ?exprs.VecLit = null;
    var expression_repeat: ?exprs.VecLit = null;
    for (rust_ir.bodies.exprs) |expr| {
        const vector = switch (expr.kind) {
            .vec_lit => |value| value,
            else => continue,
        };
        const repeat = vector.repeat orelse {
            listed = vector;
            continue;
        };
        switch (repeat) {
            .literal => literal_repeat = vector,
            .expression => expression_repeat = vector,
        }
    }

    const listed_vec = listed orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), listed_vec.elements.len);
    for (listed_vec.elements, 0..) |element_id, index| {
        const element = rust_ir.bodies.exprs[element_id];
        const literal = switch (element.kind) {
            .literal => |value| value,
            else => return error.TestUnexpectedResult,
        };
        const value = switch (literal) {
            .int => |integer| integer.value,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(i128, @intCast(index + 1)), value);
    }

    const counted = literal_repeat orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), counted.elements.len);
    try std.testing.expectEqual(@as(u64, 4), counted.repeat.?.literal);

    const computed = expression_repeat orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), computed.elements.len);
    const count_expr = rust_ir.bodies.exprs[computed.repeat.?.expression];
    try std.testing.expect(switch (count_expr.kind) {
        .path => true,
        else => false,
    });
}

test "pipeline expands the assert family into markers over lowered conditions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\pub fn eq_check(a: i64, b: i64) {
        \\    assert_eq!(a, b);
        \\}
        \\pub fn ne_check(a: i64, b: i64) {
        \\    assert_ne!(a, b);
        \\}
        \\pub fn bare_check(a: i64) {
        \\    assert!(a > 0);
        \\}
        \\pub fn message_check(a: i64, b: i64) {
        \\    assert!(a > b, "a must exceed b");
        \\}
    ;

    const rust_ir = try pipeline.analyzeSource(allocator, "assert_macro_shapes", "2021", source);

    const cases = [_]struct {
        fn_name: []const u8,
        op: exprs.BinaryOp,
        rhs_int: ?i128,
    }{
        .{ .fn_name = "eq_check", .op = .eq, .rhs_int = null },
        .{ .fn_name = "ne_check", .op = .ne, .rhs_int = null },
        .{ .fn_name = "bare_check", .op = .gt, .rhs_int = 0 },
        .{ .fn_name = "message_check", .op = .gt, .rhs_int = null },
    };
    for (cases) |entry| {
        const fn_id = findEntityId(&rust_ir.graph, .fn_, entry.fn_name) orelse
            return error.TestUnexpectedResult;
        const marker_id = fnBodyStatementExpr(&rust_ir, fn_id) orelse
            return error.TestUnexpectedResult;
        const marker = switch (rust_ir.bodies.exprs[marker_id].kind) {
            .unsupported => |value| value,
            else => return error.TestUnexpectedResult,
        };
        // The marker names the condition node the backend asserts on, so the
        // condition is a real expression rather than dropped macro text.
        const condition_id = assertionCondition(marker) orelse
            return error.TestUnexpectedResult;
        if (condition_id >= rust_ir.bodies.exprs.len) return error.TestUnexpectedResult;
        const condition = rust_ir.bodies.exprs[condition_id];
        const binary = switch (condition.kind) {
            .binary => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(entry.op, binary.op);
        try std.testing.expect(binary.lhs != binary.rhs);
        if (binary.lhs >= rust_ir.bodies.exprs.len) return error.TestUnexpectedResult;
        if (binary.rhs >= rust_ir.bodies.exprs.len) return error.TestUnexpectedResult;
        const lhs = rust_ir.bodies.exprs[binary.lhs];
        try std.testing.expect(switch (lhs.kind) {
            .path => true,
            else => false,
        });
        const rhs = rust_ir.bodies.exprs[binary.rhs];
        if (entry.rhs_int) |expected| {
            const literal = switch (rhs.kind) {
                .literal => |value| value,
                else => return error.TestUnexpectedResult,
            };
            const value = switch (literal) {
                .int => |integer| integer.value,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(expected, value);
        } else {
            try std.testing.expect(switch (rhs.kind) {
                .path => true,
                else => false,
            });
        }
    }
}

test "pipeline expands the write family into a writer, a template and its values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\pub struct Sink {
        \\    count: u32,
        \\}
        \\pub fn emit(sink: &mut Sink, x: i64) {
        \\    write!(sink, "v={}", x);
        \\    writeln!(sink, "w={}", x);
        \\}
    ;

    const rust_ir = try pipeline.analyzeSource(allocator, "write_macro_shapes", "2021", source);

    var saw_write = false;
    var saw_writeln = false;
    for (rust_ir.bodies.exprs) |expr| {
        const format_write = switch (expr.kind) {
            .format_write => |value| value,
            else => continue,
        };
        // One writer, one template and one lowered value per placeholder: the
        // shape the Zig backend formats through.
        try std.testing.expectEqual(@as(usize, 1), format_write.args.len);
        if (format_write.writer >= rust_ir.bodies.exprs.len) return error.TestUnexpectedResult;
        if (format_write.args[0] >= rust_ir.bodies.exprs.len) return error.TestUnexpectedResult;
        try std.testing.expect(switch (rust_ir.bodies.exprs[format_write.writer].kind) {
            .path => true,
            else => false,
        });
        try std.testing.expect(switch (rust_ir.bodies.exprs[format_write.args[0]].kind) {
            .path => true,
            else => false,
        });
        if (std.mem.eql(u8, format_write.template, "v={}")) {
            saw_write = true;
        } else if (std.mem.eql(u8, format_write.template, "w={}\n")) {
            saw_writeln = true;
        } else {
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(saw_write);
    try std.testing.expect(saw_writeln);
}
