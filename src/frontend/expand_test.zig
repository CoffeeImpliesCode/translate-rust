//! expand_test — unit tests for P6 built-in macro expansion.
//!
//! Pure C-free Zig tests running under `zig build test`.
//! Verifies macro kind classification, argument splitting with nested delimiter
//! support and quote literals, empty argument handling, and message formatters.

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

test "parseVecInvocation ignores a semicolon inside a raw string literal" {
    const alloc = std.testing.allocator;
    var invocation: expand.VecInvocation =
        try expand.parseVecInvocation(alloc, "[r#\"left;right\"#, 7]");
    defer invocation.deinit(alloc);

    const elements = switch (invocation) {
        .elements => |items| items,
        .repeat => {
            try std.testing.expect(false);
            return;
        },
    };

    try std.testing.expectEqual(@as(usize, 2), elements.len);
}

test "parseVecInvocation ignores a semicolon inside a block comment" {
    const alloc = std.testing.allocator;
    var invocation: expand.VecInvocation =
        try expand.parseVecInvocation(alloc, "[1 /* ; */, 2]");
    defer invocation.deinit(alloc);

    const elements = switch (invocation) {
        .elements => |items| items,
        .repeat => {
            try std.testing.expect(false);
            return;
        },
    };

    try std.testing.expectEqual(@as(usize, 2), elements.len);
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

test "cst rejects unsupported cfg predicates before disabled results" {
    try expectCstError(
        error.UnsupportedCfgPredicate,
        "#[cfg(all(feature = \"std\", unix))]\nstruct PlatformOnly;",
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
        \\//! A documentation comment is CST trivia, not an item.
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
    try std.testing.expectEqual(@as(usize, 1), g.modules.items[0].attributes.len);
    try std.testing.expectEqualStrings("no_std", g.modules.items[0].attributes[0].name);

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
    try std.testing.expectEqual(@as(usize, 0), g.modules.items[0].items.len);
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
