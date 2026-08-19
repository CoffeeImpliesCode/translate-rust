//! expand_test — unit tests for P6 built-in macro expansion.
//!
//! Pure C-free Zig tests running under `zig build test`.
//! Verifies macro kind classification, argument splitting with nested delimiter
//! support and quote literals, empty argument handling, and message formatters.

const std = @import("std");
const expand = @import("expand.zig");
const cst = @import("cst.zig");
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
    var def = (try expand.parseMacroRulesDefinition(alloc, raw_def)).?;
    defer def.deinit(alloc);

    const expanded = (try expand.expandMacroRules(alloc, def, "(i8, i16, i32)")).?;
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
    var def = (try expand.parseMacroRulesDefinition(alloc, raw_def)).?;
    defer def.deinit(alloc);

    const expanded = (try expand.expandMacroRules(alloc, def, "(u8, Vec<u32>, &str)")).?;
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
    var def = (try expand.parseMacroRulesDefinition(alloc, raw_def)).?;
    defer def.deinit(alloc);

    const expanded = (try expand.expandMacroRules(alloc, def,
        "(I8_MAX_LEN => i8, U8_MAX_LEN => u8, I16_MAX_LEN => i16 as u32)")).?;
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
    var def = (try expand.parseMacroRulesDefinition(alloc, raw_def)).?;
    defer def.deinit(alloc);

    const expanded = (try expand.expandMacroRules(alloc, def, "(1 2 3 4)")).?;
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

test "expandMacroRules returns null for unmatched args" {
    const alloc = std.testing.allocator;
    const raw_def = "macro_rules! m { ($($t:ident),*) => { $(struct $t;)* }; }";
    var def = (try expand.parseMacroRulesDefinition(alloc, raw_def)).?;
    defer def.deinit(alloc);
    const res = try expand.expandMacroRules(alloc, def, "(a, 123)");
    try std.testing.expect(res == null);
}

test "parseMacroRulesDefinition extracts gated rules" {
    const alloc = std.testing.allocator;
    const raw =
        \\macro_rules! tag {
        \\    ($($t:ident),*) => { $(struct $t;)* };
        \\    ($x:expr) => { $x };
        \\}
    ;
    var def = (try expand.parseMacroRulesDefinition(alloc, raw)).?;
    try std.testing.expectEqual(@as(usize, 2), def.rules.len);
    try std.testing.expectEqualStrings("tag", def.name);
    defer def.deinit(alloc);

    const expanded = (try expand.expandMacroRules(alloc, def, "(x)")).?;
    defer alloc.free(expanded);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "struct x;") != null);
}

test "cst expands itoa impl_Integer invocations into integer impls" {
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

    // Faithful subset of itoa's src/lib.rs: the real impl_Integer! macro and
    // two of its invocations (the multi-pair comma form and the single-pair
    // form). The integer impls must be ingested rather than dropped.
    const src =
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
    try cst.extractFile(&ctx);

    var impl_i8 = false;
    var impl_u8 = false;
    var impl_i32 = false;
    for (g.symbol_table.entities.items) |ent| {
        if (ent.kind != .impl_) continue;
        if (std.mem.indexOf(u8, ent.name, " for i8") != null) impl_i8 = true;
        if (std.mem.indexOf(u8, ent.name, " for u8") != null) impl_u8 = true;
        if (std.mem.indexOf(u8, ent.name, " for i32") != null) impl_i32 = true;
    }
    try std.testing.expect(impl_i8);
    try std.testing.expect(impl_u8);
    try std.testing.expect(impl_i32);
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
