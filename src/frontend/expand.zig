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
    write,
    writeln,
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
    if (std.mem.eql(u8, ident, "write")) return .write;
    if (std.mem.eql(u8, ident, "writeln")) return .writeln;
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
/// (`\'`, `'\n'`, `'\x41'`, `'\u{...}'`, ...) so an escaped quote is not treated
/// as the terminator.
fn findCharEnd(s: []const u8, start: usize) ?usize {
    if (start >= s.len or s[start] != '\'') return null;
    if (start + 2 >= s.len) return null;
    var i: usize = start + 1;
    if (s[i] == '\\') {
        i += 1;
        if (i >= s.len) return null;
        switch (s[i]) {
            'u' => {
                i += 1;
                if (i >= s.len or s[i] != '{') return null;
                i += 1;
                const digits_start = i;
                while (i < s.len and std.ascii.isHex(s[i])) : (i += 1) {}
                if (i == digits_start or i >= s.len or s[i] != '}') return null;
                i += 1;
            },
            'x' => {
                i += 1;
                if (i + 2 > s.len) return null;
                if (!std.ascii.isHex(s[i]) or !std.ascii.isHex(s[i + 1])) return null;
                i += 2;
            },
            else => i += 1,
        }
    } else {
        i += 1;
    }
    if (i < s.len and s[i] == '\'') return i;
    return null;
}

fn findStringEnd(s: []const u8, start: usize) ?usize {
    if (start >= s.len or s[start] != '"') return null;
    var i = start + 1;
    var escaped = false;
    while (i < s.len) : (i += 1) {
        if (escaped) {
            escaped = false;
        } else if (s[i] == '\\') {
            escaped = true;
        } else if (s[i] == '"') {
            return i;
        }
    }
    return null;
}

/// Validate token-tree structure before any splitter or matcher consumes it.
/// The old implementation treated malformed delimiters and quotes as plain
/// text, which allowed malformed macro invocations to disappear downstream.
fn validateMacroTokenStream(raw_tokens: []const u8) !void {
    var delimiters: [macro_parse_depth_max]u8 = undefined;
    var delimiter_count: usize = 0;
    var in_double_quote = false;
    var escape = false;
    var i: usize = 0;
    while (i < raw_tokens.len) : (i += 1) {
        const c = raw_tokens[i];
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

        if (c == '/' and i + 1 < raw_tokens.len) {
            if (raw_tokens[i + 1] == '/') {
                i += 2;
                while (i < raw_tokens.len and raw_tokens[i] != '\n') : (i += 1) {}
                continue;
            }
            if (raw_tokens[i + 1] == '*') {
                i = findBlockCommentEnd(raw_tokens, i) orelse
                    return error.MalformedMacroInvocation;
                continue;
            }
        }

        if (c == 'r' or (c == 'b' and i + 1 < raw_tokens.len and raw_tokens[i + 1] == 'r')) {
            const prefix_len: usize = if (c == 'r') 1 else 2;
            var marker = i + prefix_len;
            while (marker < raw_tokens.len and raw_tokens[marker] == '#') : (marker += 1) {}
            if (marker < raw_tokens.len and raw_tokens[marker] == '"') {
                const hash_count = marker - i - prefix_len;
                i = findRawStringEnd(raw_tokens, marker + 1, hash_count) orelse
                    return error.MalformedMacroInvocation;
                continue;
            }
        }

        if (c == '"') {
            in_double_quote = true;
            continue;
        }
        if (c == '\'') {
            if (findCharEnd(raw_tokens, i)) |end| {
                i = end;
                continue;
            }
            // Rust lifetimes are the only valid unmatched single-quote form.
            if (i + 1 < raw_tokens.len and isIdentStart(raw_tokens[i + 1])) continue;
            return error.MalformedMacroInvocation;
        }

        switch (c) {
            '(' => {
                if (delimiter_count == delimiters.len) return error.MalformedMacroInvocation;
                delimiters[delimiter_count] = ')';
                delimiter_count += 1;
            },
            '[' => {
                if (delimiter_count == delimiters.len) return error.MalformedMacroInvocation;
                delimiters[delimiter_count] = ']';
                delimiter_count += 1;
            },
            '{' => {
                if (delimiter_count == delimiters.len) return error.MalformedMacroInvocation;
                delimiters[delimiter_count] = '}';
                delimiter_count += 1;
            },
            ')', ']', '}' => {
                if (delimiter_count == 0) return error.MalformedMacroInvocation;
                if (delimiters[delimiter_count - 1] != c) return error.MalformedMacroInvocation;
                delimiter_count -= 1;
            },
            else => {},
        }
    }
    if (in_double_quote or escape or delimiter_count != 0) {
        return error.MalformedMacroInvocation;
    }
}

/// Return the content of a single outer delimiter pair after validating the
/// complete token stream. Bare token streams remain unchanged.
fn getEnclosedContent(raw_tokens: []const u8) ![]const u8 {
    const trimmed: []const u8 = std.mem.trim(u8, raw_tokens, " \t\r\n");
    try validateMacroTokenStream(trimmed);
    if (trimmed.len < 2) return trimmed;

    const first: u8 = trimmed[0];
    const last: u8 = trimmed[trimmed.len - 1];
    const is_pair: bool = (first == '(' and last == ')') or
        (first == '[' and last == ']') or
        (first == '{' and last == '}');
    if (!is_pair) return trimmed;

    const close_idx = findClosingDelimiterChecked(trimmed, 0) catch
        return error.MalformedMacroInvocation;
    if (close_idx != trimmed.len - 1) return trimmed;
    return std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
}

fn findClosingDelimiterChecked(s: []const u8, start: usize) !usize {
    if (start >= s.len) return error.MalformedMacroInvocation;
    const opener = s[start];
    if (opener != '(' and opener != '[' and opener != '{') {
        return error.MalformedMacroInvocation;
    }
    var delimiters: [macro_parse_depth_max]u8 = undefined;
    var delimiter_count: usize = 0;
    var in_double_quote = false;
    var escape = false;
    var i = start;
    while (i < s.len) : (i += 1) {
        const c = s[i];
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
        if (c == '/' and i + 1 < s.len) {
            if (s[i + 1] == '/') {
                i += 2;
                while (i < s.len and s[i] != '\n') : (i += 1) {}
                continue;
            }
            if (s[i + 1] == '*') {
                i = findBlockCommentEnd(s, i) orelse return error.MalformedMacroInvocation;
                continue;
            }
        }
        if (c == 'r' or (c == 'b' and i + 1 < s.len and s[i + 1] == 'r')) {
            const prefix_len: usize = if (c == 'r') 1 else 2;
            var marker = i + prefix_len;
            while (marker < s.len and s[marker] == '#') : (marker += 1) {}
            if (marker < s.len and s[marker] == '"') {
                const hash_count = marker - i - prefix_len;
                i = findRawStringEnd(s, marker + 1, hash_count) orelse
                    return error.MalformedMacroInvocation;
                continue;
            }
        }
        if (c == '"') {
            in_double_quote = true;
            continue;
        }
        if (c == '\'') {
            if (findCharEnd(s, i)) |end| {
                i = end;
                continue;
            }
            if (i + 1 < s.len and isIdentStart(s[i + 1])) continue;
            return error.MalformedMacroInvocation;
        }

        switch (c) {
            '(' => {
                if (delimiter_count == delimiters.len) return error.MalformedMacroInvocation;
                delimiters[delimiter_count] = ')';
                delimiter_count += 1;
            },
            '[' => {
                if (delimiter_count == delimiters.len) return error.MalformedMacroInvocation;
                delimiters[delimiter_count] = ']';
                delimiter_count += 1;
            },
            '{' => {
                if (delimiter_count == delimiters.len) return error.MalformedMacroInvocation;
                delimiters[delimiter_count] = '}';
                delimiter_count += 1;
            },
            ')', ']', '}' => {
                if (delimiter_count == 0) return error.MalformedMacroInvocation;
                if (delimiters[delimiter_count - 1] != c) return error.MalformedMacroInvocation;
                delimiter_count -= 1;
                if (delimiter_count == 0) return i;
            },
            else => {},
        }
    }
    return error.MalformedMacroInvocation;
}

/// Return the matching delimiter or reject malformed nesting and literals.
pub fn findClosingDelimiter(s: []const u8, start: usize) !usize {
    return findClosingDelimiterChecked(s, start);
}

/// Trims outer delimiter pairs `(...)`, `[...]`, `{...}` if present.
/// Respects nested parenthesis, brackets, braces, strings, and char literals.
/// Returns an allocated slice of trimmed argument token slices.
pub fn splitMacroArgs(alloc: std.mem.Allocator, raw_tokens: []const u8) ![]const []const u8 {
    const text: []const u8 = try getEnclosedContent(raw_tokens);
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

/// Parsed token shape for Rust's built-in `vec!` macro.
///
/// Element and repeat token slices borrow `raw_tokens`. The outer `elements`
/// slice is allocator-owned.
pub const VecInvocation = union(enum) {
    elements: []const []const u8,
    repeat: struct {
        element: []const u8,
        count: []const u8,
    },

    pub fn deinit(self: *VecInvocation, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .elements => |items| alloc.free(items),
            .repeat => {},
        }
        self.* = undefined;
    }
};

fn findBlockCommentEnd(text: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var i = start + 2;
    while (i + 1 < text.len) {
        if (text[i] == '/' and text[i + 1] == '*') {
            depth += 1;
            i += 2;
            continue;
        }
        if (text[i] == '*' and text[i + 1] == '/') {
            depth -= 1;
            if (depth == 0) return i + 1;
            i += 2;
            continue;
        }
        i += 1;
    }
    return null;
}

fn findRawStringEnd(text: []const u8, body_start: usize, hash_count: usize) ?usize {
    var i = body_start;
    while (i < text.len) : (i += 1) {
        if (text[i] != '"') continue;
        if (i + 1 + hash_count > text.len) return null;

        var matched_hashes: usize = 0;
        while (matched_hashes < hash_count and text[i + 1 + matched_hashes] == '#') {
            matched_hashes += 1;
        }
        if (matched_hashes == hash_count) return i + hash_count;
    }
    return null;
}

fn findVecRepeatSeparator(
    alloc: std.mem.Allocator,
    text: []const u8,
) !?usize {
    var delimiters: std.ArrayListUnmanaged(u8) = .empty;
    defer delimiters.deinit(alloc);

    var separator: ?usize = null;
    var in_double_quote: bool = false;
    var escape: bool = false;

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];

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

        if (c == '/' and i + 1 < text.len) {
            if (text[i + 1] == '/') {
                i += 2;
                while (i < text.len and text[i] != '\n') : (i += 1) {}
                if (i == text.len) break;
                continue;
            }
            if (text[i + 1] == '*') {
                i = findBlockCommentEnd(text, i) orelse return error.MalformedVecInvocation;
                continue;
            }
        }

        if (c == 'r' or (c == 'b' and i + 1 < text.len and text[i + 1] == 'r')) {
            const prefix_len: usize = if (c == 'r') 1 else 2;
            var marker = i + prefix_len;
            while (marker < text.len and text[marker] == '#') : (marker += 1) {}
            if (marker < text.len and text[marker] == '"') {
                const hash_count = marker - i - prefix_len;
                i = findRawStringEnd(text, marker + 1, hash_count) orelse
                    return error.MalformedVecInvocation;
                continue;
            }
        }

        if (c == '"') {
            in_double_quote = true;
            continue;
        }

        if (c == '\'') {
            if (findCharEnd(text, i)) |end| {
                i = end;
                continue;
            }
        }

        const expected_closer: ?u8 = switch (c) {
            '(' => ')',
            '[' => ']',
            '{' => '}',
            else => null,
        };
        if (expected_closer) |closer| {
            try delimiters.append(alloc, closer);
            continue;
        }

        if (c == ')' or c == ']' or c == '}') {
            if (delimiters.items.len == 0) return error.MalformedVecInvocation;
            const last = delimiters.items.len - 1;
            if (delimiters.items[last] != c) return error.MalformedVecInvocation;
            delimiters.items.len = last;
            continue;
        }

        if (c == ';' and delimiters.items.len == 0) {
            if (separator != null) return error.MalformedVecInvocation;
            separator = i;
        }
    }

    if (in_double_quote) return error.MalformedVecInvocation;
    if (escape) return error.MalformedVecInvocation;
    if (delimiters.items.len != 0) return error.MalformedVecInvocation;
    return separator;
}

/// Parse explicit and literal-repeat `vec!` token forms.
pub fn parseVecInvocation(
    alloc: std.mem.Allocator,
    raw_tokens: []const u8,
) !VecInvocation {
    const text = try getEnclosedContent(raw_tokens);
    const separator = try findVecRepeatSeparator(alloc, text);

    if (separator) |index| {
        const element = std.mem.trim(u8, text[0..index], " \t\r\n");
        const count = std.mem.trim(u8, text[index + 1 ..], " \t\r\n");
        if (element.len == 0) return error.MalformedVecInvocation;
        if (count.len == 0) return error.MalformedVecInvocation;
        return .{ .repeat = .{
            .element = element,
            .count = count,
        } };
    }

    const elements = try splitMacroArgs(alloc, raw_tokens);
    errdefer alloc.free(elements);
    for (elements) |element| {
        if (element.len == 0) return error.MalformedVecInvocation;
    }
    return .{ .elements = elements };
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

/// Metavariable kinds supported in macro_rules! matchers.
pub const MetavarKind = enum {
    ident,
    ty,
    expr,
    path,
    tt,
    pat,
    stmt,
    block,
    item,
    literal,
    lifetime,
    vis,

    pub fn fromString(s: []const u8) ?MetavarKind {
        if (std.mem.eql(u8, s, "ident")) return .ident;
        if (std.mem.eql(u8, s, "ty")) return .ty;
        if (std.mem.eql(u8, s, "expr")) return .expr;
        if (std.mem.eql(u8, s, "path")) return .path;
        if (std.mem.eql(u8, s, "tt")) return .tt;
        if (std.mem.eql(u8, s, "pat")) return .pat;
        if (std.mem.eql(u8, s, "stmt")) return .stmt;
        if (std.mem.eql(u8, s, "block")) return .block;
        if (std.mem.eql(u8, s, "item")) return .item;
        if (std.mem.eql(u8, s, "literal")) return .literal;
        if (std.mem.eql(u8, s, "lifetime")) return .lifetime;
        if (std.mem.eql(u8, s, "vis")) return .vis;
        return null;
    }
};

pub const RepetitionOp = enum {
    zero_or_more, // *
    one_or_more, // +
    zero_or_one, // ?
};

/// Maximum runtime repetition nesting. Matching fails if a macro exceeds it.
pub const macro_repetition_depth_max: usize = 16;

/// Maximum number of output tokens emitted by one macro expansion.
pub const macro_output_token_max: usize = 16_384;

pub const MatcherElement = union(enum) {
    token: []const u8,
    metavar: struct {
        name: []const u8,
        kind: MetavarKind,
    },
    repetition: struct {
        elements: []const MatcherElement,
        separator: ?[]const u8,
        op: RepetitionOp,
    },
};

pub const TemplateElement = union(enum) {
    text: []const u8,
    metavar: []const u8,
    repetition: struct {
        elements: []const TemplateElement,
        separator: ?[]const u8,
        op: RepetitionOp,
    },
};

pub const MacroRule = struct {
    matcher: []const MatcherElement,
    template: []const TemplateElement,
    raw_matcher: []const u8,
    raw_template: []const u8,
};

pub const MacroDef = struct {
    name: []const u8,
    rules: []const MacroRule,

    /// Deep-free matcher/template and owned source slices.
    pub fn deinit(self: *MacroDef, alloc: std.mem.Allocator) void {
        for (self.rules) |rule| {
            freeMatcherElements(alloc, rule.matcher);
            freeTemplateElements(alloc, rule.template);
            alloc.free(rule.raw_matcher);
            alloc.free(rule.raw_template);
        }
        alloc.free(self.rules);
        alloc.free(self.name);
        self.* = undefined;
    }
};

fn freeMatcherElements(alloc: std.mem.Allocator, elems: []const MatcherElement) void {
    for (elems) |elem| {
        if (elem == .repetition) freeMatcherElements(alloc, elem.repetition.elements);
    }
    alloc.free(elems);
}

fn freeTemplateElements(alloc: std.mem.Allocator, elems: []const TemplateElement) void {
    for (elems) |elem| {
        if (elem == .repetition) freeTemplateElements(alloc, elem.repetition.elements);
    }
    alloc.free(elems);
}

fn isIdentifier(s: []const u8) bool {
    var value = s;
    if (std.mem.startsWith(u8, value, "r#")) value = value[2..];
    if (value.len == 0 or !isIdentStart(value[0])) return false;
    for (value[1..]) |c| {
        if (!isIdentChar(c)) return false;
    }
    return true;
}

fn tokenStreamIsValid(value: []const u8) bool {
    if (value.len == 0) return false;
    validateMacroTokenStream(value) catch return false;
    return true;
}

fn isPathFragment(value: []const u8) bool {
    var rest = value;
    if (std.mem.startsWith(u8, rest, "::")) rest = rest[2..];
    if (rest.len == 0) return false;
    while (rest.len > 0) {
        const separator = std.mem.indexOf(u8, rest, "::");
        const part = if (separator) |index| rest[0..index] else rest;
        if (!isIdentifier(part) and
            !std.mem.eql(u8, part, "self") and
            !std.mem.eql(u8, part, "Self") and
            !std.mem.eql(u8, part, "crate") and
            !std.mem.eql(u8, part, "super"))
        {
            return false;
        }
        if (separator) |index| {
            rest = rest[index + 2 ..];
            if (rest.len == 0) return false;
        } else {
            break;
        }
    }
    return true;
}

fn isLiteralFragment(value: []const u8) bool {
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) return true;
    if (value.len >= 2 and
        ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
    {
        return tokenStreamIsValid(value);
    }
    if (value.len >= 3 and value[0] == 'b' and value[1] == '\'') {
        return tokenStreamIsValid(value);
    }
    const has_raw_prefix = value.len > 0 and
        (value[0] == 'r' or (value.len > 1 and value[0] == 'b' and value[1] == 'r'));
    if (std.mem.startsWith(u8, value, "r\"") or
        std.mem.startsWith(u8, value, "b\"") or
        (has_raw_prefix and rawLiteralHasQuote(value)))
    {
        return tokenStreamIsValid(value);
    }
    if (value.len == 0 or !std.ascii.isDigit(value[0])) return false;
    for (value) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.')) return false;
    }
    return true;
}

fn rawLiteralHasQuote(value: []const u8) bool {
    const prefix_len: usize = if (value[0] == 'r') 1 else 2;
    if (value.len <= prefix_len) return false;
    var marker = prefix_len;
    while (marker < value.len and value[marker] == '#') : (marker += 1) {}
    return marker < value.len and value[marker] == '"';
}

fn hasTopLevelComma(value: []const u8) bool {
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] == '/' and index + 1 < value.len) {
            if (value[index + 1] == '/') {
                index += 2;
                while (index < value.len and value[index] != '\n') : (index += 1) {}
                continue;
            }
            if (value[index + 1] == '*') {
                const close = findBlockCommentEnd(value, index) orelse return false;
                index = close + 1;
                continue;
            }
        }
        if (value[index] == 'r' or
            (value[index] == 'b' and index + 1 < value.len and value[index + 1] == 'r'))
        {
            const prefix_len: usize = if (value[index] == 'r') 1 else 2;
            var marker = index + prefix_len;
            while (marker < value.len and value[marker] == '#') : (marker += 1) {}
            if (marker < value.len and value[marker] == '"') {
                const hash_count = marker - index - prefix_len;
                const close = findRawStringEnd(value, marker + 1, hash_count) orelse return false;
                index = close + 1;
                continue;
            }
        }
        if (value[index] == '"') {
            index += 1;
            var escaped = false;
            while (index < value.len) : (index += 1) {
                if (escaped) {
                    escaped = false;
                } else if (value[index] == '\\') {
                    escaped = true;
                } else if (value[index] == '"') {
                    index += 1;
                    break;
                }
            }
            continue;
        }
        if (value[index] == '\'') {
            if (findCharEnd(value, index)) |close| {
                index = close + 1;
                continue;
            }
            if (index + 1 < value.len and isIdentStart(value[index + 1])) {
                index += 1;
                continue;
            }
            return false;
        }
        switch (value[index]) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '{' => brace_depth += 1,
            '}' => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            ',' => if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) return true,
            else => {},
        }
        index += 1;
    }
    return false;
}

fn isExpressionFragment(value: []const u8) bool {
    if (!tokenStreamIsValid(value)) return false;
    if (std.mem.indexOfScalar(u8, value, ',') != null and hasTopLevelComma(value)) return false;
    if (std.mem.eql(u8, value, "???") or std.mem.indexOf(u8, value, "??") != null) return false;
    if (value[0] == ';' or value[0] == ',' or value[0] == '+') return false;
    const keywords = [_][]const u8{
        "const", "enum",   "extern", "fn",    "impl", "let",   "mod",
        "pub",   "static", "struct", "trait", "type", "union", "use",
    };
    for (keywords) |keyword| {
        if (std.mem.eql(u8, value, keyword)) return false;
        if (std.mem.startsWith(u8, value, keyword) and value.len > keyword.len) {
            const next = value[keyword.len];
            if (std.ascii.isWhitespace(next) or next == '(') return false;
        }
    }
    const last = value[value.len - 1];
    if (last == '+' or last == '-' or last == '*' or last == '/' or
        last == '%' or last == '=' or last == '&' or last == '|' or
        last == '^' or last == '<' or last == '>' or last == '.')
    {
        return false;
    }
    return true;
}

fn isTypeFragment(value: []const u8) bool {
    if (!tokenStreamIsValid(value)) return false;
    if (std.mem.eql(u8, value, "???") or std.mem.indexOf(u8, value, "??") != null) return false;
    const first = value[0];
    if (std.ascii.isDigit(first) or first == ';' or first == ',') return false;
    return true;
}

fn isBlockFragment(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') {
        return false;
    }
    return tokenStreamIsValid(trimmed);
}

fn isItemFragment(value: []const u8) bool {
    if (!tokenStreamIsValid(value)) return false;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const item_keywords = [_][]const u8{
        "const ",  "enum ",   "extern ", "fn ",   "impl ",  "mod ", "pub ",
        "static ", "struct ", "trait ",  "type ", "union ", "use ",
    };
    for (item_keywords) |keyword| {
        if (std.mem.startsWith(u8, trimmed, keyword)) return true;
    }
    return false;
}

fn isVisibilityFragment(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return true;
    return std.mem.eql(u8, trimmed, "pub") or
        std.mem.startsWith(u8, trimmed, "pub(") or
        std.mem.eql(u8, trimmed, "crate") or
        std.mem.eql(u8, trimmed, "self") or
        std.mem.eql(u8, trimmed, "super");
}

fn validateMetavar(kind: MetavarKind, value: []const u8) !void {
    const valid = switch (kind) {
        .ident => isIdentifier(value),
        .ty => isTypeFragment(value),
        .expr => isExpressionFragment(value),
        .path => isPathFragment(value),
        .tt => tokenStreamIsValid(value),
        .pat => isExpressionFragment(value),
        .stmt => isExpressionFragment(value),
        .block => isBlockFragment(value),
        .item => isItemFragment(value),
        .literal => isLiteralFragment(value),
        .lifetime => value.len > 1 and value[0] == '\'' and isIdentifier(value[1..]),
        .vis => isVisibilityFragment(value),
    };
    if (!valid) return error.FragmentMismatch;
}

const CapturePath = struct {
    len: usize = 0,
    indices: [macro_repetition_depth_max]usize = undefined,
};

const Capture = struct {
    path: CapturePath,
    value: []const u8,
};

const CaptureList = std.ArrayListUnmanaged(Capture);

fn pathHasPrefix(path: CapturePath, prefix: CapturePath) bool {
    if (path.len < prefix.len) return false;
    for (0..prefix.len) |index| {
        if (path.indices[index] != prefix.indices[index]) return false;
    }
    return true;
}

pub const Bindings = struct {
    alloc: std.mem.Allocator,
    top_vars: std.StringHashMapUnmanaged([]const u8) = .empty,
    rep_vars: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty,
    captures: std.StringHashMapUnmanaged(CaptureList) = .empty,
    capture_log: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(alloc: std.mem.Allocator) Bindings {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Bindings) void {
        self.top_vars.deinit(self.alloc);
        var rep_it = self.rep_vars.iterator();
        while (rep_it.next()) |entry| entry.value_ptr.deinit(self.alloc);
        self.rep_vars.deinit(self.alloc);
        var capture_it = self.captures.iterator();
        while (capture_it.next()) |entry| entry.value_ptr.deinit(self.alloc);
        self.captures.deinit(self.alloc);
        self.capture_log.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn setTop(self: *Bindings, name: []const u8, val: []const u8) !void {
        try self.top_vars.put(self.alloc, name, val);
    }

    pub fn addRep(self: *Bindings, name: []const u8, val: []const u8) !void {
        var gop = try self.rep_vars.getOrPut(self.alloc, name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.alloc, val);
    }

    fn addCapture(self: *Bindings, name: []const u8, value: []const u8, path: CapturePath) !void {
        var gop = try self.captures.getOrPut(self.alloc, name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try self.capture_log.append(self.alloc, name);
        errdefer self.capture_log.items.len -= 1;
        try gop.value_ptr.append(self.alloc, .{ .path = path, .value = value });
    }

    fn mark(self: *const Bindings) usize {
        return self.capture_log.items.len;
    }

    fn rollback(self: *Bindings, checkpoint: usize) void {
        while (self.capture_log.items.len > checkpoint) {
            const name = self.capture_log.items[self.capture_log.items.len - 1];
            self.capture_log.items.len -= 1;
            const list = self.captures.getPtr(name) orelse continue;
            list.items.len -= 1;
            if (list.items.len == 0) {
                list.deinit(self.alloc);
                _ = self.captures.remove(name);
            }
        }
    }

    fn hasCapture(self: *const Bindings, name: []const u8) bool {
        return self.captures.get(name) != null;
    }

    fn getCapture(self: *const Bindings, name: []const u8, path: CapturePath) ?[]const u8 {
        const list = self.captures.get(name) orelse return null;
        var index = list.items.len;
        while (index > 0) {
            index -= 1;
            const capture = list.items[index];
            if (capture.path.len <= path.len and pathHasPrefix(path, capture.path)) {
                return capture.value;
            }
        }
        return null;
    }

    fn repetitionCount(self: *const Bindings, name: []const u8, prefix: CapturePath) ?usize {
        const list = self.captures.get(name) orelse return null;
        var found = false;
        var count: usize = 0;
        for (list.items) |capture| {
            if (capture.path.len <= prefix.len or !pathHasPrefix(capture.path, prefix)) continue;
            const index = capture.path.indices[prefix.len];
            if (!found or index + 1 > count) count = index + 1;
            found = true;
        }
        return if (found) count else null;
    }
    pub fn getTop(self: *const Bindings, name: []const u8) ?[]const u8 {
        if (self.top_vars.get(name)) |value| return value;
        const path: CapturePath = .{};
        return self.getCapture(name, path);
    }

    pub fn getRep(self: *const Bindings, name: []const u8, idx: usize) ?[]const u8 {
        if (self.rep_vars.get(name)) |list| {
            if (idx < list.items.len) return list.items[idx];
        }
        var path: CapturePath = .{};
        path.len = 1;
        path.indices[0] = idx;
        return self.getCapture(name, path);
    }

    pub fn hasRep(self: *const Bindings, name: []const u8) bool {
        return self.rep_vars.get(name) != null or self.hasCapture(name);
    }

    pub fn getRepLen(self: *const Bindings, name: []const u8) usize {
        if (self.rep_vars.get(name)) |list| return list.items.len;
        const path: CapturePath = .{};
        return self.repetitionCount(name, path) orelse 0;
    }
};

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

pub fn skipWhitespaceAndComments(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len) {
        const c = s[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            i += 1;
            continue;
        }
        if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '/') {
            i += 2;
            while (i < s.len and s[i] != '\n') : (i += 1) {}
            if (i < s.len and s[i] == '\n') i += 1;
            continue;
        }
        if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '*') {
            i += 2;
            while (i + 1 < s.len and !(s[i] == '*' and s[i + 1] == '/')) : (i += 1) {}
            if (i + 1 < s.len) i += 2;
            continue;
        }
        break;
    }
    return i;
}

const macro_parse_depth_max: usize = 128;

pub fn parseMatcher(alloc: std.mem.Allocator, raw: []const u8) ![]const MatcherElement {
    validateMacroTokenStream(raw) catch return error.InvalidMacroMatcher;
    return parseMatcherDepth(alloc, raw, 0);
}

fn parseMatcherDepth(
    alloc: std.mem.Allocator,
    raw: []const u8,
    depth: usize,
) ![]const MatcherElement {
    if (depth >= macro_parse_depth_max) return error.InvalidMacroMatcher;

    var list: std.ArrayListUnmanaged(MatcherElement) = .empty;
    errdefer {
        for (list.items) |element| {
            if (element == .repetition) freeMatcherElements(alloc, element.repetition.elements);
        }
        list.deinit(alloc);
    }

    var i: usize = 0;
    while (i < raw.len) {
        i = skipWhitespaceAndComments(raw, i);
        if (i >= raw.len) break;

        if (raw[i] == '$' and i + 1 < raw.len and raw[i + 1] == '(') {
            const open_idx = i + 1;
            const close_idx = findClosingDelimiterChecked(raw, open_idx) catch
                return error.InvalidMacroMatcher;
            const inner_text = raw[open_idx + 1 .. close_idx];
            const inner_elems = try parseMatcherDepth(alloc, inner_text, depth + 1);
            if (inner_elems.len == 0) return error.InvalidMacroMatcher;
            var inner_elems_owned = true;
            errdefer {
                if (inner_elems_owned) freeMatcherElements(alloc, inner_elems);
            }

            var post = close_idx + 1;
            post = skipWhitespaceAndComments(raw, post);
            var sep: ?[]const u8 = null;
            var op: RepetitionOp = .zero_or_more;
            if (post < raw.len and (raw[post] == '*' or raw[post] == '+' or raw[post] == '?')) {
                op = if (raw[post] == '*') .zero_or_more else if (raw[post] == '+') .one_or_more else .zero_or_one;
                i = post + 1;
            } else {
                var op_idx = post;
                while (op_idx < raw.len and raw[op_idx] != '*' and raw[op_idx] != '+' and raw[op_idx] != '?') : (op_idx += 1) {}
                if (op_idx >= raw.len) return error.InvalidMacroMatcher;
                const raw_sep = std.mem.trim(u8, raw[post..op_idx], " \t\r\n");
                sep = if (raw_sep.len > 0) raw_sep else null;
                op = if (raw[op_idx] == '*') .zero_or_more else if (raw[op_idx] == '+') .one_or_more else .zero_or_one;
                i = op_idx + 1;
            }
            try list.append(alloc, .{ .repetition = .{ .elements = inner_elems, .separator = sep, .op = op } });
            inner_elems_owned = false;
        } else if (raw[i] == '$' and i + 1 < raw.len and isIdentStart(raw[i + 1])) {
            i += 1;
            const var_start = i;
            while (i < raw.len and isIdentChar(raw[i])) : (i += 1) {}
            const var_name = raw[var_start..i];

            var kind: MetavarKind = .ident;
            const after_ws = skipWhitespaceAndComments(raw, i);
            if (after_ws < raw.len and raw[after_ws] == ':') {
                var kind_pos = skipWhitespaceAndComments(raw, after_ws + 1);
                const kind_start = kind_pos;
                while (kind_pos < raw.len and isIdentChar(raw[kind_pos])) : (kind_pos += 1) {}
                if (kind_pos == kind_start) return error.InvalidMacroMatcher;
                const kind_name = raw[kind_start..kind_pos];
                kind = MetavarKind.fromString(kind_name) orelse return error.InvalidMacroMatcher;
                i = kind_pos;
            }
            try list.append(alloc, .{ .metavar = .{ .name = var_name, .kind = kind } });
        } else if (raw[i] == '$') {
            return error.InvalidMacroMatcher;
        } else {
            const tok_start = i;
            if (i + 1 < raw.len and (std.mem.startsWith(u8, raw[i..], "=>") or std.mem.startsWith(u8, raw[i..], "->") or std.mem.startsWith(u8, raw[i..], "::"))) {
                i += 2;
            } else if (isIdentStart(raw[i])) {
                while (i < raw.len and isIdentChar(raw[i])) : (i += 1) {}
            } else {
                i += 1;
            }
            try list.append(alloc, .{ .token = raw[tok_start..i] });
        }
    }
    return list.toOwnedSlice(alloc);
}
pub fn parseTemplate(alloc: std.mem.Allocator, raw: []const u8) ![]const TemplateElement {
    validateMacroTokenStream(raw) catch return error.InvalidMacroTemplate;
    return parseTemplateDepth(alloc, raw, 0);
}

fn parseTemplateDepth(
    alloc: std.mem.Allocator,
    raw: []const u8,
    depth: usize,
) ![]const TemplateElement {
    if (depth >= macro_parse_depth_max) return error.InvalidMacroTemplate;

    var list: std.ArrayListUnmanaged(TemplateElement) = .empty;
    errdefer {
        for (list.items) |element| {
            if (element == .repetition) freeTemplateElements(alloc, element.repetition.elements);
        }
        list.deinit(alloc);
    }

    var i: usize = 0;
    var text_start: usize = 0;

    while (i < raw.len) {
        if (raw[i] == '$') {
            if (i > text_start) {
                try list.append(alloc, .{ .text = raw[text_start..i] });
            }
            if (i + 1 < raw.len and raw[i + 1] == '(') {
                const open_idx = i + 1;
                const close_idx = findClosingDelimiterChecked(raw, open_idx) catch
                    return error.InvalidMacroTemplate;
                const inner_text = raw[open_idx + 1 .. close_idx];
                const inner_elems = try parseTemplateDepth(alloc, inner_text, depth + 1);
                if (inner_elems.len == 0) return error.InvalidMacroTemplate;
                var inner_elems_owned = true;
                errdefer {
                    if (inner_elems_owned) freeTemplateElements(alloc, inner_elems);
                }

                var post = close_idx + 1;
                post = skipWhitespaceAndComments(raw, post);
                var sep: ?[]const u8 = null;
                var op: RepetitionOp = .zero_or_more;

                if (post < raw.len and (raw[post] == '*' or raw[post] == '+' or raw[post] == '?')) {
                    op = if (raw[post] == '*') .zero_or_more else if (raw[post] == '+') .one_or_more else .zero_or_one;
                    i = post + 1;
                } else {
                    var op_idx = post;
                    while (op_idx < raw.len and raw[op_idx] != '*' and raw[op_idx] != '+' and raw[op_idx] != '?') : (op_idx += 1) {}
                    if (op_idx >= raw.len) return error.InvalidMacroTemplate;
                    const raw_sep = std.mem.trim(u8, raw[post..op_idx], " \t\r\n");
                    sep = if (raw_sep.len > 0) raw_sep else null;
                    op = if (raw[op_idx] == '*') .zero_or_more else if (raw[op_idx] == '+') .one_or_more else .zero_or_one;
                    i = op_idx + 1;
                }
                try list.append(alloc, .{ .repetition = .{ .elements = inner_elems, .separator = sep, .op = op } });
                inner_elems_owned = false;
                text_start = i;
            } else if (i + 1 < raw.len and isIdentStart(raw[i + 1])) {
                i += 1;
                const var_start = i;
                while (i < raw.len and isIdentChar(raw[i])) : (i += 1) {}
                const var_name = raw[var_start..i];
                try list.append(alloc, .{ .metavar = var_name });
                text_start = i;
            } else {
                return error.InvalidMacroTemplate;
            }
        } else {
            i += 1;
        }
    }

    if (i > text_start) {
        try list.append(alloc, .{ .text = raw[text_start..i] });
    }
    return list.toOwnedSlice(alloc);
}

fn tokenPrefixMatches(input_text: []const u8, input_idx: usize, token: []const u8) bool {
    if (token.len == 0 or input_idx + token.len > input_text.len) return false;
    if (!std.mem.startsWith(u8, input_text[input_idx..], token)) return false;

    const token_end = input_idx + token.len;
    if (isIdentChar(token[token.len - 1]) and
        token_end < input_text.len and
        isIdentChar(input_text[token_end]))
    {
        return false;
    }
    if (token.len > 1 and token_end < input_text.len) {
        const next = input_text[token_end];
        switch (token[token.len - 1]) {
            '=', '!', '<', '>', '+', '-', '*', '/', '%', '&', '|', ':', '.' => {
                if (next == token[token.len - 1]) return false;
            },
            else => {},
        }
    }
    if (token.len == 1 and token_end < input_text.len) {
        const next = input_text[token_end];
        switch (token[0]) {
            '=', '!', '<', '>', '+', '-', '*', '/', '%', '&', '|', ':', '.' => {
                if (next == token[0] or
                    (token[0] == '=' and next == '>') or
                    (token[0] == '-' and next == '>') or
                    (token[0] == ':' and next == ':') or
                    (token[0] == '.' and next == '.'))
                {
                    return false;
                }
            },
            else => {},
        }
    }
    return true;
}

fn scanUntilDelimited(
    input_text: []const u8,
    start: usize,
    next_elem: ?MatcherElement,
    sep: ?[]const u8,
    follow_tok: ?[]const u8,
    stop_at_whitespace: bool,
) usize {
    var i = start;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var in_double_quote = false;
    var escape = false;

    while (i < input_text.len) {
        const c = input_text[i];
        if (escape) {
            escape = false;
            i += 1;
            continue;
        }
        if (in_double_quote) {
            if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_double_quote = false;
            }
            i += 1;
            continue;
        }
        if (c == '"') {
            in_double_quote = true;
            i += 1;
            continue;
        }
        if (c == '\'') {
            if (findCharEnd(input_text, i)) |end| {
                i = end + 1;
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
        } else if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
            if (next_elem) |ne| {
                if (ne == .token and tokenPrefixMatches(input_text, i, ne.token)) {
                    return i;
                }
            }
            if (sep) |s| {
                if (tokenPrefixMatches(input_text, i, s)) return i;
            } else if (stop_at_whitespace and std.ascii.isWhitespace(c)) {
                return i;
            }
            if (follow_tok) |ft| {
                if (tokenPrefixMatches(input_text, i, ft)) return i;
            }
        }
        i += 1;
    }
    return i;
}

const MacroMatchError = error{
    OutOfMemory,
    FragmentMismatch,
    MacroRepetitionDepthExceeded,
};

fn pathWithIndex(path: CapturePath, index: usize) MacroMatchError!CapturePath {
    if (path.len >= macro_repetition_depth_max) return error.MacroRepetitionDepthExceeded;
    var result = path;
    result.indices[result.len] = index;
    result.len += 1;
    return result;
}

fn matchSequence(
    alloc: std.mem.Allocator,
    elements: []const MatcherElement,
    input_text: []const u8,
    start: usize,
    bindings: *Bindings,
    path: CapturePath,
    separator: ?[]const u8,
    follow_tok: ?[]const u8,
) MacroMatchError!?usize {
    var input_idx = start;
    for (elements, 0..) |elem, elem_idx| {
        input_idx = skipWhitespaceAndComments(input_text, input_idx);
        switch (elem) {
            .token => |tok| {
                if (!tokenPrefixMatches(input_text, input_idx, tok)) return null;
                input_idx += tok.len;
            },
            .metavar => |mv| {
                const next_elem = if (elem_idx + 1 < elements.len) elements[elem_idx + 1] else null;
                const value_start = input_idx;
                input_idx = scanUntilDelimited(
                    input_text,
                    input_idx,
                    next_elem,
                    separator,
                    follow_tok,
                    if (next_elem) |next|
                        next != .token
                    else
                        path.len > 0 and separator == null and follow_tok == null,
                );
                const value = std.mem.trim(u8, input_text[value_start..input_idx], " \t\r\n");
                if (value.len == 0) return null;
                try validateMetavar(mv.kind, value);
                try bindings.addCapture(mv.name, value, path);
            },
            .repetition => |rep| {
                const next_elem = if (elem_idx + 1 < elements.len) elements[elem_idx + 1] else null;
                const next_token = if (next_elem != null and next_elem.? == .token)
                    next_elem.?.token
                else
                    separator;
                input_idx = (try matchRepetition(
                    alloc,
                    rep,
                    input_text,
                    input_idx,
                    bindings,
                    path,
                    next_token,
                )) orelse return null;
            },
        }
    }
    return input_idx;
}

fn matchRepetition(
    alloc: std.mem.Allocator,
    repetition: @FieldType(MatcherElement, "repetition"),
    input_text: []const u8,
    start: usize,
    bindings: *Bindings,
    path: CapturePath,
    follow_tok: ?[]const u8,
) MacroMatchError!?usize {
    var repetition_count: usize = 0;
    var input_idx = start;
    var next_start = start;

    while (true) {
        next_start = skipWhitespaceAndComments(input_text, next_start);
        if (next_start >= input_text.len) break;
        if (follow_tok) |token| {
            if (tokenPrefixMatches(input_text, next_start, token)) break;
        }

        const binding_mark = bindings.mark();
        const iteration_path = try pathWithIndex(path, repetition_count);
        const iteration_end = (try matchSequence(
            alloc,
            repetition.elements,
            input_text,
            next_start,
            bindings,
            iteration_path,
            repetition.separator orelse follow_tok,
            follow_tok,
        )) orelse {
            bindings.rollback(binding_mark);
            break;
        };
        if (iteration_end <= next_start) {
            bindings.rollback(binding_mark);
            break;
        }
        input_idx = iteration_end;
        repetition_count += 1;
        if (repetition.op == .zero_or_one) break;

        if (repetition.separator) |separator| {
            const separator_start = skipWhitespaceAndComments(input_text, input_idx);
            if (!tokenPrefixMatches(input_text, separator_start, separator)) break;
            next_start = separator_start + separator.len;
        } else {
            next_start = input_idx;
        }
    }

    if (repetition.op == .one_or_more and repetition_count == 0) return null;
    return input_idx;
}

pub fn matchPattern(
    alloc: std.mem.Allocator,
    elements: []const MatcherElement,
    input_text: []const u8,
    bindings: *Bindings,
) !bool {
    const path: CapturePath = .{};
    const end = (try matchSequence(
        alloc,
        elements,
        input_text,
        0,
        bindings,
        path,
        null,
        null,
    )) orelse return false;
    const input_idx = skipWhitespaceAndComments(input_text, end);
    return input_idx >= input_text.len;
}

const OutputBudget = struct {
    token_count: usize = 0,
    in_word: bool = false,
    in_string: bool = false,
    escaped: bool = false,

    fn append(
        self: *OutputBudget,
        alloc: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(u8),
        text: []const u8,
    ) !void {
        for (text) |c| {
            if (self.in_string) {
                if (self.escaped) {
                    self.escaped = false;
                } else if (c == '\\') {
                    self.escaped = true;
                } else if (c == '"') {
                    self.in_string = false;
                }
                continue;
            }
            if (c == '"') {
                if (!self.in_word) self.token_count += 1;
                self.in_string = true;
                self.in_word = false;
            } else if (std.ascii.isWhitespace(c)) {
                self.in_word = false;
            } else if (isIdentChar(c) or std.ascii.isDigit(c)) {
                if (!self.in_word) self.token_count += 1;
                self.in_word = true;
            } else {
                self.token_count += 1;
                self.in_word = false;
            }
            if (self.token_count > macro_output_token_max) {
                return error.MacroExpansionTokenLimit;
            }
        }
        try out.appendSlice(alloc, text);
    }
};

fn templateRepetitionCount(
    elements: []const TemplateElement,
    bindings: *const Bindings,
    path: CapturePath,
) !usize {
    var count: ?usize = null;
    for (elements) |elem| {
        switch (elem) {
            .text => {},
            .metavar => |var_name| {
                if (bindings.repetitionCount(var_name, path)) |length| {
                    if (count) |existing| {
                        if (existing != length) return error.InvalidMacroRepetition;
                    } else {
                        count = length;
                    }
                }
            },
            .repetition => |nested| {
                const nested_count = try templateRepetitionCount(nested.elements, bindings, path);
                if (count) |existing| {
                    if (existing != nested_count) return error.InvalidMacroRepetition;
                } else {
                    count = nested_count;
                }
            },
        }
    }
    return count orelse error.UnboundMacroRepetition;
}

fn expandTemplateElements(
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    budget: *OutputBudget,
    elements: []const TemplateElement,
    bindings: *const Bindings,
    path: CapturePath,
) !void {
    for (elements) |elem| {
        switch (elem) {
            .text => |text| try budget.append(alloc, out, text),
            .metavar => |var_name| {
                const value = bindings.getCapture(var_name, path) orelse
                    return if (bindings.hasRep(var_name))
                        error.UnboundMacroRepetition
                    else
                        error.UnboundMacroVariable;
                try budget.append(alloc, out, value);
            },
            .repetition => |rep| {
                const count = try templateRepetitionCount(rep.elements, bindings, path);
                if (rep.op == .one_or_more and count == 0) return error.InvalidMacroRepetition;
                if (rep.op == .zero_or_one and count > 1) return error.InvalidMacroRepetition;
                for (0..count) |index| {
                    if (index > 0 and rep.separator != null) {
                        try budget.append(alloc, out, rep.separator.?);
                        try budget.append(alloc, out, "\n");
                    }
                    const child_path = try pathWithIndex(path, index);
                    try expandTemplateElements(alloc, out, budget, rep.elements, bindings, child_path);
                }
            },
        }
    }
}

pub fn expandMacroRules(
    alloc: std.mem.Allocator,
    def: MacroDef,
    raw_args: []const u8,
) ![]const u8 {
    const trimmed_args = try getEnclosedContent(raw_args);
    if (def.rules.len == 0) return error.InvalidMacroDefinition;
    var saw_fragment_mismatch = false;
    for (def.rules) |rule| {
        var bindings = Bindings.init(alloc);
        defer bindings.deinit();

        const matched = matchPattern(alloc, rule.matcher, trimmed_args, &bindings) catch |err| switch (err) {
            error.FragmentMismatch => {
                saw_fragment_mismatch = true;
                continue;
            },
            else => return err,
        };
        if (!matched) continue;

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(alloc);
        var budget: OutputBudget = .{};
        try expandTemplateElements(alloc, &out, &budget, rule.template, &bindings, .{});
        if (std.mem.trim(u8, out.items, " \t\r\n").len == 0) {
            return error.EmptyMacroExpansion;
        }
        const expanded = try out.toOwnedSlice(alloc);
        return expanded;
    }
    return if (saw_fragment_mismatch) error.FragmentMismatch else error.UnmatchedMacroRule;
}

pub fn parseMacroRulesDefinition(alloc: std.mem.Allocator, raw_def: []const u8) !MacroDef {
    validateMacroTokenStream(raw_def) catch return error.InvalidMacroDefinition;

    var i = skipWhitespaceAndComments(raw_def, 0);
    if (!std.mem.startsWith(u8, raw_def[i..], "macro_rules!")) {
        return error.InvalidMacroDefinition;
    }
    i += "macro_rules!".len;
    i = skipWhitespaceAndComments(raw_def, i);
    if (i >= raw_def.len or !isIdentStart(raw_def[i])) return error.InvalidMacroDefinition;

    const name_start = i;
    while (i < raw_def.len and isIdentChar(raw_def[i])) : (i += 1) {}
    const name = raw_def[name_start..i];

    i = skipWhitespaceAndComments(raw_def, i);
    if (i >= raw_def.len or (raw_def[i] != '{' and raw_def[i] != '(' and raw_def[i] != '[')) {
        return error.InvalidMacroDefinition;
    }

    const body_open = i;
    const body_close = findClosingDelimiterChecked(raw_def, body_open) catch
        return error.InvalidMacroDefinition;
    const rules_body = raw_def[body_open + 1 .. body_close];
    i = skipWhitespaceAndComments(raw_def, body_close + 1);
    if (i < raw_def.len and raw_def[i] == ';') {
        i = skipWhitespaceAndComments(raw_def, i + 1);
    }
    if (i != raw_def.len) return error.InvalidMacroDefinition;

    var rules_list: std.ArrayListUnmanaged(MacroRule) = .empty;
    errdefer {
        for (rules_list.items) |rule| {
            freeMatcherElements(alloc, rule.matcher);
            freeTemplateElements(alloc, rule.template);
            alloc.free(rule.raw_matcher);
            alloc.free(rule.raw_template);
        }
        rules_list.deinit(alloc);
    }

    var idx: usize = 0;
    while (idx < rules_body.len) {
        idx = skipWhitespaceAndComments(rules_body, idx);
        if (idx >= rules_body.len) break;
        if (rules_body[idx] == ';') return error.InvalidMacroDefinition;
        if (rules_body[idx] != '(' and rules_body[idx] != '[' and rules_body[idx] != '{') {
            return error.InvalidMacroDefinition;
        }

        const matcher_open = idx;
        const matcher_close = findClosingDelimiterChecked(rules_body, matcher_open) catch
            return error.InvalidMacroDefinition;
        const raw_matcher = rules_body[matcher_open + 1 .. matcher_close];
        idx = matcher_close + 1;
        idx = skipWhitespaceAndComments(rules_body, idx);
        if (idx + 2 > rules_body.len or !std.mem.startsWith(u8, rules_body[idx..], "=>")) {
            return error.InvalidMacroDefinition;
        }
        idx += 2;
        idx = skipWhitespaceAndComments(rules_body, idx);
        if (idx >= rules_body.len or (rules_body[idx] != '{' and rules_body[idx] != '(' and rules_body[idx] != '[')) {
            return error.InvalidMacroDefinition;
        }
        const tmpl_open = idx;
        const tmpl_close = findClosingDelimiterChecked(rules_body, tmpl_open) catch
            return error.InvalidMacroDefinition;
        const raw_tmpl = rules_body[tmpl_open + 1 .. tmpl_close];
        idx = tmpl_close + 1;

        const owned_matcher = try alloc.dupe(u8, raw_matcher);
        var matcher_source_owned = true;
        errdefer if (matcher_source_owned) alloc.free(owned_matcher);
        const owned_template = try alloc.dupe(u8, raw_tmpl);
        var template_source_owned = true;
        errdefer if (template_source_owned) alloc.free(owned_template);
        const matcher_elems = try parseMatcher(alloc, owned_matcher);
        var matcher_owned = true;
        errdefer if (matcher_owned) freeMatcherElements(alloc, matcher_elems);
        const tmpl_elems = try parseTemplate(alloc, owned_template);
        var template_owned = true;
        errdefer if (template_owned) freeTemplateElements(alloc, tmpl_elems);
        try rules_list.append(alloc, .{
            .matcher = matcher_elems,
            .template = tmpl_elems,
            .raw_matcher = owned_matcher,
            .raw_template = owned_template,
        });
        matcher_owned = false;
        template_owned = false;
        matcher_source_owned = false;
        template_source_owned = false;

        idx = skipWhitespaceAndComments(rules_body, idx);
        if (idx < rules_body.len and rules_body[idx] == ';') {
            idx += 1;
            idx = skipWhitespaceAndComments(rules_body, idx);
            if (idx < rules_body.len and rules_body[idx] == ';') {
                return error.InvalidMacroDefinition;
            }
        }
    }
    if (rules_list.items.len == 0) return error.InvalidMacroDefinition;

    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    const owned_rules = try rules_list.toOwnedSlice(alloc);
    return .{
        .name = owned_name,
        .rules = owned_rules,
    };
}

/// Configuration used when evaluating `cfg` attributes during source macro
/// expansion. The defaults match the frontend's disabled-feature behavior.
pub const MacroSourceOptions = struct {
    features: []const []const u8 = &.{},
    target_pointer_width: ?u16 = null,
    docsrs: bool = false,
    include_tests: bool = false,
    expansion_depth_max: usize = 64,
};

const SourceCfgState = enum {
    none,
    enabled,
    disabled,
};

const SourceCfgAttribute = struct {
    end: usize,
    state: SourceCfgState,
};

const SourceAttributePrefix = struct {
    end: usize,
    disabled: bool,
};

const SourceMacroInvocation = struct {
    name: []const u8,
    end: usize,
};

const MacroScope = struct {
    alloc: std.mem.Allocator,
    macros: std.StringHashMapUnmanaged(MacroDef) = .empty,

    fn init(alloc: std.mem.Allocator) MacroScope {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *MacroScope) void {
        var values = self.macros.valueIterator();
        while (values.next()) |definition| {
            definition.deinit(self.alloc);
        }
        self.macros.deinit(self.alloc);
        self.* = undefined;
    }

    fn register(self: *MacroScope, definition: MacroDef) !void {
        if (self.macros.get(definition.name)) |old_definition| {
            _ = self.macros.remove(definition.name);
            var owned_old = old_definition;
            owned_old.deinit(self.alloc);
        }
        try self.macros.put(self.alloc, definition.name, definition);
    }

    fn get(self: *const MacroScope, name: []const u8) ?MacroDef {
        return self.macros.get(name);
    }
};

const MacroScopeStack = struct {
    alloc: std.mem.Allocator,
    outer: *const MacroTable,
    scopes: std.ArrayListUnmanaged(MacroScope) = .empty,

    fn init(alloc: std.mem.Allocator, outer: *const MacroTable) MacroScopeStack {
        return .{ .alloc = alloc, .outer = outer };
    }

    fn deinit(self: *MacroScopeStack) void {
        while (self.scopes.items.len > 0) {
            var scope = self.scopes.pop().?;
            scope.deinit();
        }
        self.scopes.deinit(self.alloc);
        self.* = undefined;
    }

    fn push(self: *MacroScopeStack) !void {
        try self.scopes.append(self.alloc, MacroScope.init(self.alloc));
    }

    fn pop(self: *MacroScopeStack) void {
        var scope = self.scopes.pop() orelse return;
        scope.deinit();
    }

    fn register(self: *MacroScopeStack, definition: MacroDef) !void {
        if (self.scopes.items.len == 0) return error.MacroScopeUnavailable;
        try self.scopes.items[self.scopes.items.len - 1].register(definition);
    }

    fn get(self: *const MacroScopeStack, name: []const u8) ?MacroDef {
        var index = self.scopes.items.len;
        while (index > 0) {
            index -= 1;
            if (self.scopes.items[index].get(name)) |definition| return definition;
        }
        return self.outer.get(name);
    }
};

fn sourceCfgSkipWhitespace(input: []const u8, index: *usize) void {
    while (index.* < input.len and
        (input[index.*] == ' ' or input[index.*] == '\t' or
            input[index.*] == '\r' or input[index.*] == '\n'))
    {
        index.* += 1;
    }
}

fn sourceCfgIdentifier(input: []const u8, index: *usize) ?[]const u8 {
    sourceCfgSkipWhitespace(input, index);
    const start = index.*;
    while (index.* < input.len and
        (std.ascii.isAlphanumeric(input[index.*]) or input[index.*] == '_'))
    {
        index.* += 1;
    }
    if (index.* == start) return null;
    return input[start..index.*];
}

fn sourceCfgString(input: []const u8, index: *usize) ![]const u8 {
    sourceCfgSkipWhitespace(input, index);
    if (index.* >= input.len or input[index.*] != '"') {
        return error.UnsupportedCfgPredicate;
    }
    index.* += 1;
    const start = index.*;
    while (index.* < input.len and input[index.*] != '"') {
        if (input[index.*] == '\\') return error.UnsupportedCfgPredicate;
        index.* += 1;
    }
    if (index.* >= input.len) return error.UnsupportedCfgPredicate;
    const result = input[start..index.*];
    index.* += 1;
    return result;
}

fn sourceCfgExpect(input: []const u8, index: *usize, expected: u8) !void {
    sourceCfgSkipWhitespace(input, index);
    if (index.* >= input.len or input[index.*] != expected) {
        return error.UnsupportedCfgPredicate;
    }
    index.* += 1;
}

fn sourceCfgFeatureEnabled(options: MacroSourceOptions, feature: []const u8) bool {
    for (options.features) |enabled| {
        if (std.mem.eql(u8, enabled, feature)) return true;
    }
    return false;
}

fn sourceCfgTargetBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "unix") or
        std.mem.eql(u8, name, "windows") or
        std.mem.eql(u8, name, "target_os") or
        std.mem.eql(u8, name, "target_arch") or
        std.mem.eql(u8, name, "target_env") or
        std.mem.eql(u8, name, "target_family") or
        std.mem.eql(u8, name, "target_vendor") or
        std.mem.eql(u8, name, "debug_assertions") or
        std.mem.eql(u8, name, "panic") or
        std.mem.eql(u8, name, "proc_macro") or
        std.mem.eql(u8, name, "miri") or
        std.mem.eql(u8, name, "sanitize");
}

fn sourceCfgPredicate(
    input: []const u8,
    index: *usize,
    options: MacroSourceOptions,
) !bool {
    const name = sourceCfgIdentifier(input, index) orelse
        return error.UnsupportedCfgPredicate;
    if (std.mem.eql(u8, name, "feature")) {
        try sourceCfgExpect(input, index, '=');
        return sourceCfgFeatureEnabled(options, try sourceCfgString(input, index));
    }
    if (std.mem.eql(u8, name, "target_pointer_width")) {
        try sourceCfgExpect(input, index, '=');
        const target_text = try sourceCfgString(input, index);
        const target_width = std.fmt.parseInt(u16, target_text, 10) catch
            return error.UnsupportedCfgPredicate;
        const configured_width = options.target_pointer_width orelse @as(u16, @bitSizeOf(usize));
        return configured_width == target_width;
    }
    if (std.mem.eql(u8, name, "test")) return options.include_tests;
    if (std.mem.eql(u8, name, "docsrs")) return options.docsrs;
    if (std.mem.eql(u8, name, "not")) {
        try sourceCfgExpect(input, index, '(');
        const value = try sourceCfgPredicate(input, index, options);
        try sourceCfgExpect(input, index, ')');
        return !value;
    }

    const is_all = std.mem.eql(u8, name, "all");
    const is_any = std.mem.eql(u8, name, "any");
    if (!is_all and !is_any) {
        if (sourceCfgTargetBuiltin(name)) return error.UnsupportedCfgPredicate;
        sourceCfgSkipWhitespace(input, index);
        if (index.* < input.len and
            (input[index.*] == '=' or input[index.*] == '('))
        {
            return error.UnsupportedCfgPredicate;
        }
        return false;
    }

    try sourceCfgExpect(input, index, '(');
    sourceCfgSkipWhitespace(input, index);
    if (index.* < input.len and input[index.*] == ')') {
        index.* += 1;
        return is_all;
    }

    var value = is_all;
    while (true) {
        const operand = try sourceCfgPredicate(input, index, options);
        value = if (is_all) value and operand else value or operand;
        sourceCfgSkipWhitespace(input, index);
        if (index.* >= input.len) return error.UnsupportedCfgPredicate;
        if (input[index.*] == ')') {
            index.* += 1;
            return value;
        }
        if (input[index.*] != ',') return error.UnsupportedCfgPredicate;
        index.* += 1;
    }
}

fn sourceCfgPredicateText(input: []const u8, options: MacroSourceOptions) !bool {
    var index: usize = 0;
    const value = try sourceCfgPredicate(input, &index, options);
    sourceCfgSkipWhitespace(input, &index);
    if (index != input.len) return error.UnsupportedCfgPredicate;
    return value;
}

fn sourceCfgAttributeAt(
    source: []const u8,
    start: usize,
    end: usize,
    options: MacroSourceOptions,
) !?SourceCfgAttribute {
    if (start >= end or source[start] != '#') return null;
    const bracket = if (start + 1 < end and source[start + 1] == '[')
        start + 1
    else if (start + 2 < end and source[start + 1] == '!' and source[start + 2] == '[')
        start + 2
    else
        return null;
    const close = try findClosingDelimiterChecked(source, bracket);
    if (close >= end) return error.MalformedMacroInvocation;

    const attr_end = close + 1;
    const body_start = bracket + 1;
    const body = std.mem.trim(u8, source[body_start..close], " \t\r\n");
    if (std.mem.startsWith(u8, body, "cfg(") and body.len >= 5 and body[body.len - 1] == ')') {
        const enabled = try sourceCfgPredicateText(body[4 .. body.len - 1], options);
        return .{ .end = attr_end, .state = if (enabled) .enabled else .disabled };
    }
    if (std.mem.startsWith(u8, body, "cfg_attr(") and
        body.len >= 10 and body[body.len - 1] == ')')
    {
        const inner = body[9 .. body.len - 1];
        var depth: usize = 0;
        var in_string = false;
        var escaped = false;
        var separator: ?usize = null;
        for (inner, 0..) |character, index| {
            if (in_string) {
                if (escaped) {
                    escaped = false;
                } else if (character == '\\') {
                    escaped = true;
                } else if (character == '"') {
                    in_string = false;
                }
                continue;
            }
            if (character == '"') {
                in_string = true;
            } else if (character == '(') {
                depth += 1;
            } else if (character == ')') {
                if (depth == 0) return error.UnsupportedCfgPredicate;
                depth -= 1;
            } else if (character == ',' and depth == 0) {
                separator = index;
                break;
            }
        }
        const split = separator orelse return error.UnsupportedCfgPredicate;
        const condition = std.mem.trim(u8, inner[0..split], " \t\r\n");
        const payload = std.mem.trim(u8, inner[split + 1 ..], " \t\r\n");
        if (condition.len == 0 or payload.len == 0) return error.UnsupportedCfgPredicate;
        if (!try sourceCfgPredicateText(condition, options)) {
            return .{ .end = attr_end, .state = .none };
        }
        if (std.mem.startsWith(u8, payload, "cfg(") and
            payload.len >= 5 and payload[payload.len - 1] == ')')
        {
            const enabled = try sourceCfgPredicateText(payload[4 .. payload.len - 1], options);
            return .{ .end = attr_end, .state = if (enabled) .enabled else .disabled };
        }
    }
    return .{ .end = attr_end, .state = .none };
}

fn sourceAttributePrefixAt(
    source: []const u8,
    start: usize,
    end: usize,
    options: MacroSourceOptions,
) !?SourceAttributePrefix {
    if (start >= end or source[start] != '#') return null;
    var cursor = start;
    var found = false;
    var disabled = false;
    while (cursor < end and source[cursor] == '#') {
        const attribute = (try sourceCfgAttributeAt(source, cursor, end, options)) orelse break;
        found = true;
        if (attribute.state == .disabled) disabled = true;
        const next = skipWhitespaceAndComments(source, attribute.end);
        cursor = if (next > end) end else next;
    }
    if (!found) return null;
    return .{ .end = cursor, .disabled = disabled };
}

fn sourceMacroDefinitionAt(source: []const u8, start: usize, end: usize) ?usize {
    const keyword = "macro_rules!";
    if (start + keyword.len > end or !std.mem.startsWith(u8, source[start..end], keyword)) {
        return null;
    }
    if (start + keyword.len < end and isIdentChar(source[start + keyword.len])) return null;
    var cursor = skipWhitespaceAndComments(source, start + keyword.len);
    if (cursor >= end or !isIdentStart(source[cursor])) return null;
    while (cursor < end and isIdentChar(source[cursor])) : (cursor += 1) {}
    cursor = skipWhitespaceAndComments(source, cursor);
    if (cursor >= end or
        (source[cursor] != '(' and source[cursor] != '[' and source[cursor] != '{'))
    {
        return null;
    }
    const close = findClosingDelimiterChecked(source, cursor) catch return null;
    if (close >= end) return null;
    const next = skipWhitespaceAndComments(source, close + 1);
    cursor = if (next > end) end else next;
    if (cursor < end and source[cursor] == ';') cursor += 1;
    return cursor;
}

fn sourceMacroNameEnd(source: []const u8, start: usize, end: usize) ?usize {
    if (start >= end or !isIdentStart(source[start])) return null;
    var cursor = start;
    while (cursor < end and isIdentChar(source[cursor])) : (cursor += 1) {}
    while (cursor + 2 < end and source[cursor] == ':' and source[cursor + 1] == ':') {
        cursor = skipWhitespaceAndComments(source, cursor + 2);
        if (cursor >= end or !isIdentStart(source[cursor])) return null;
        while (cursor < end and isIdentChar(source[cursor])) : (cursor += 1) {}
    }
    return cursor;
}

fn sourceMacroInvocationAt(source: []const u8, start: usize, end: usize) ?SourceMacroInvocation {
    const name_end = sourceMacroNameEnd(source, start, end) orelse return null;
    var cursor = skipWhitespaceAndComments(source, name_end);
    if (cursor >= end or source[cursor] != '!') return null;
    cursor = skipWhitespaceAndComments(source, cursor + 1);
    if (cursor >= end or
        (source[cursor] != '(' and source[cursor] != '[' and source[cursor] != '{'))
    {
        return null;
    }
    const close = findClosingDelimiterChecked(source, cursor) catch return null;
    if (close >= end) return null;
    return .{ .name = source[start..name_end], .end = close + 1 };
}

fn sourceLiteralEnd(source: []const u8, start: usize, end: usize) !?usize {
    if (start >= end) return null;
    if (start + 1 < end and source[start] == '/' and source[start + 1] == '/') {
        var cursor = start + 2;
        while (cursor < end and source[cursor] != '\n') : (cursor += 1) {}
        return cursor;
    }
    if (start + 1 < end and source[start] == '/' and source[start + 1] == '*') {
        const close = findBlockCommentEnd(source, start) orelse return null;
        return close + 1;
    }
    if (source[start] == '"') {
        const close = findStringEnd(source, start) orelse
            return error.MalformedMacroInvocation;
        if (close >= end) return error.MalformedMacroInvocation;
        return close + 1;
    }
    if (source[start] == '\'') {
        const close = findCharEnd(source, start) orelse return null;
        if (close >= end) return error.MalformedMacroInvocation;
        return close + 1;
    }
    if (source[start] == 'r' or
        (source[start] == 'b' and start + 1 < end and source[start + 1] == 'r'))
    {
        const prefix_len: usize = if (source[start] == 'r') 1 else 2;
        var marker = start + prefix_len;
        while (marker < end and source[marker] == '#') : (marker += 1) {}
        if (marker < end and source[marker] == '"') {
            const hash_count = marker - start - prefix_len;
            const close = findRawStringEnd(source, marker + 1, hash_count) orelse
                return error.MalformedMacroInvocation;
            if (close >= end) return error.MalformedMacroInvocation;
            return close + 1;
        }
    }
    if (source[start] == 'b' and start + 1 < end) {
        if (source[start + 1] == '"') {
            const close = findStringEnd(source, start + 1) orelse
                return error.MalformedMacroInvocation;
            if (close >= end) return error.MalformedMacroInvocation;
            return close + 1;
        }
        if (source[start + 1] == '\'') {
            const close = findCharEnd(source, start + 1) orelse
                return error.MalformedMacroInvocation;
            if (close >= end) return error.MalformedMacroInvocation;
            return close + 1;
        }
    }
    return null;
}

fn expandSourceRange(
    alloc: std.mem.Allocator,
    source: []const u8,
    start: usize,
    end: usize,
    stack: *MacroScopeStack,
    options: MacroSourceOptions,
    depth: usize,
    output: *std.ArrayListUnmanaged(u8),
) !void {
    var cursor = start;
    while (cursor < end) {
        if (try sourceLiteralEnd(source, cursor, end)) |literal_end| {
            if (literal_end > end) return error.MalformedMacroInvocation;
            try output.appendSlice(alloc, source[cursor..literal_end]);
            cursor = literal_end;
            continue;
        }

        if (source[cursor] == '#') {
            if (try sourceAttributePrefixAt(source, cursor, end, options)) |prefix| {
                const target_start = prefix.end;
                if (sourceMacroDefinitionAt(source, target_start, end)) |definition_end| {
                    if (!prefix.disabled) {
                        const raw_definition = source[target_start..definition_end];
                        var definition = try parseMacroRulesDefinition(alloc, raw_definition);
                        var definition_owned = true;
                        errdefer if (definition_owned) definition.deinit(alloc);
                        try stack.register(definition);
                        definition_owned = false;
                    }
                    cursor = definition_end;
                    continue;
                }
                if (sourceMacroInvocationAt(source, target_start, end)) |invocation| {
                    if (prefix.disabled) {
                        cursor = invocation.end;
                        if (cursor < end and source[cursor] == ';') cursor += 1;
                        continue;
                    }
                    if (stack.get(invocation.name)) |definition| {
                        if (depth >= options.expansion_depth_max) {
                            return error.MacroExpansionRecursionLimit;
                        }
                        const bang = std.mem.indexOfScalar(u8, source[target_start..invocation.end], '!') orelse
                            return error.MalformedMacroInvocation;
                        const token_start = target_start + bang + 1;
                        const token_tree = std.mem.trim(
                            u8,
                            source[token_start..invocation.end],
                            " \t\r\n",
                        );
                        const expanded = try expandMacroRules(alloc, definition, token_tree);
                        defer alloc.free(expanded);
                        try expandSourceRange(
                            alloc,
                            expanded,
                            0,
                            expanded.len,
                            stack,
                            options,
                            depth + 1,
                            output,
                        );
                        cursor = invocation.end;
                        continue;
                    }
                }
                try output.appendSlice(alloc, source[cursor..prefix.end]);
                cursor = prefix.end;
                continue;
            }
        }

        if (sourceMacroDefinitionAt(source, cursor, end)) |definition_end| {
            const raw_definition = source[cursor..definition_end];
            var definition = try parseMacroRulesDefinition(alloc, raw_definition);
            var definition_owned = true;
            errdefer if (definition_owned) definition.deinit(alloc);
            try stack.register(definition);
            definition_owned = false;
            cursor = definition_end;
            continue;
        }

        if (sourceMacroInvocationAt(source, cursor, end)) |invocation| {
            if (stack.get(invocation.name)) |definition| {
                if (depth >= options.expansion_depth_max) {
                    return error.MacroExpansionRecursionLimit;
                }
                const bang = std.mem.indexOfScalar(u8, source[cursor..invocation.end], '!') orelse
                    return error.MalformedMacroInvocation;
                const token_start = cursor + bang + 1;
                const token_tree = std.mem.trim(
                    u8,
                    source[token_start..invocation.end],
                    " \t\r\n",
                );
                const expanded = try expandMacroRules(alloc, definition, token_tree);
                defer alloc.free(expanded);
                try expandSourceRange(
                    alloc,
                    expanded,
                    0,
                    expanded.len,
                    stack,
                    options,
                    depth + 1,
                    output,
                );
                cursor = invocation.end;
                continue;
            }
            if (identifyMacro(invocation.name) == .custom) {
                try output.appendSlice(alloc, source[cursor..invocation.end]);
                cursor = invocation.end;
                continue;
            }
            const bang = std.mem.indexOfScalar(u8, source[cursor..invocation.end], '!') orelse
                return error.MalformedMacroInvocation;
            const token_start = cursor + bang + 1;
            try output.appendSlice(alloc, source[cursor..token_start]);
            try expandSourceRange(
                alloc,
                source,
                token_start,
                invocation.end,
                stack,
                options,
                depth,
                output,
            );
            cursor = invocation.end;
            continue;
        }

        if (source[cursor] == '{') {
            const close = try findClosingDelimiterChecked(source, cursor);
            if (close >= end) return error.MalformedMacroInvocation;
            try output.append(alloc, '{');
            try stack.push();
            expandSourceRange(
                alloc,
                source,
                cursor + 1,
                close,
                stack,
                options,
                depth,
                output,
            ) catch |err| {
                stack.pop();
                return err;
            };
            stack.pop();
            try output.append(alloc, '}');
            cursor = close + 1;
            continue;
        }

        try output.append(alloc, source[cursor]);
        cursor += 1;
    }
}

/// Expand in-source `macro_rules!` definitions and invocations with lexical
/// scopes. Definitions are removed from the result, while unknown and built-in
/// invocations remain unchanged for later frontend diagnostics or lowering.
pub fn expandSourceMacros(
    alloc: std.mem.Allocator,
    outer: *const MacroTable,
    source: []const u8,
    options: MacroSourceOptions,
) ![]const u8 {
    var stack = MacroScopeStack.init(alloc, outer);
    defer stack.deinit();
    try stack.push();

    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(alloc);
    try expandSourceRange(alloc, source, 0, source.len, &stack, options, 0, &output);
    return output.toOwnedSlice(alloc);
}

/// Maximum number of lexical tables visited by `MacroTable.get`.
pub const macro_scope_depth_max: usize = 128;

/// A lexical table of declarative macros.
///
/// Child tables borrow their parent. A child owns only definitions registered
/// on that table; callers must keep every parent alive until its descendants
/// are deinitialized.
pub const MacroTable = struct {
    alloc: std.mem.Allocator,
    parent: ?*const MacroTable = null,
    macros: std.StringHashMapUnmanaged(MacroDef) = .empty,

    /// Create a root macro scope.
    pub fn init(alloc: std.mem.Allocator) MacroTable {
        return .{ .alloc = alloc };
    }

    /// Create a child scope that borrows `parent` for ancestor lookup.
    pub fn initChild(parent: *const MacroTable) MacroTable {
        return .{
            .alloc = parent.alloc,
            .parent = parent,
        };
    }

    pub fn deinit(self: *MacroTable) void {
        var values = self.macros.valueIterator();
        while (values.next()) |def| {
            def.deinit(self.alloc);
        }
        self.macros.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn register(self: *MacroTable, name: []const u8, def: MacroDef) !void {
        if (self.macros.get(name)) |old_definition| {
            _ = self.macros.remove(name);
            var owned_old = old_definition;
            owned_old.deinit(self.alloc);
        }
        try self.macros.put(self.alloc, name, def);
    }

    pub fn get(self: *const MacroTable, name: []const u8) ?MacroDef {
        var clean_name = name;
        if (std.mem.endsWith(u8, clean_name, "!")) {
            clean_name = clean_name[0 .. clean_name.len - 1];
        }
        if (std.mem.indexOf(u8, clean_name, "::") != null) return null;

        var scope: ?*const MacroTable = self;
        var depth: usize = 0;
        while (scope) |current| {
            if (current.macros.get(clean_name)) |definition| return definition;
            depth += 1;
            if (depth >= macro_scope_depth_max) return null;
            scope = current.parent;
        }
        return null;
    }
};

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
    try std.testing.expectEqual(MacroKind.write, identifyMacro("write!"));
    try std.testing.expectEqual(MacroKind.writeln, identifyMacro("writeln!"));
    try std.testing.expectEqual(MacroKind.write, identifyMacro("core::write!"));
    try std.testing.expectEqual(MacroKind.writeln, identifyMacro("std::writeln!"));
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

fn nestedMacroRepetitionTextForTest(
    alloc: std.mem.Allocator,
    nesting: usize,
    leaf: []const u8,
) ![]const u8 {
    var text: std.ArrayListUnmanaged(u8) = .empty;
    errdefer text.deinit(alloc);

    for (0..nesting) |_| try text.appendSlice(alloc, "$(");
    try text.appendSlice(alloc, leaf);
    for (0..nesting) |_| try text.appendSlice(alloc, ")*");
    return text.toOwnedSlice(alloc);
}

test "parseMatcher and parseTemplate preserve nested repetitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const matcher_text = try nestedMacroRepetitionTextForTest(alloc, 2, "$value:expr");
    const matcher = try parseMatcher(alloc, matcher_text);
    try std.testing.expectEqual(@as(usize, 1), matcher.len);
    try std.testing.expect(matcher[0] == .repetition);
    try std.testing.expectEqual(@as(usize, 1), matcher[0].repetition.elements.len);
    try std.testing.expect(matcher[0].repetition.elements[0] == .repetition);
    try std.testing.expectEqual(
        @as(usize, 1),
        matcher[0].repetition.elements[0].repetition.elements.len,
    );
    try std.testing.expect(
        matcher[0].repetition.elements[0].repetition.elements[0] == .metavar,
    );

    const template_text = try nestedMacroRepetitionTextForTest(alloc, 2, "$value");
    const template = try parseTemplate(alloc, template_text);
    try std.testing.expectEqual(@as(usize, 1), template.len);
    try std.testing.expect(template[0] == .repetition);
    try std.testing.expectEqual(@as(usize, 1), template[0].repetition.elements.len);
    try std.testing.expect(template[0].repetition.elements[0] == .repetition);
    try std.testing.expectEqual(
        @as(usize, 1),
        template[0].repetition.elements[0].repetition.elements.len,
    );
    try std.testing.expect(
        template[0].repetition.elements[0].repetition.elements[0] == .metavar,
    );
}

test "parseMatcher and parseTemplate reject nesting at recursion limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const accepted_nesting = @as(usize, macro_parse_depth_max) - 1;
    const accepted_matcher_text = try nestedMacroRepetitionTextForTest(
        alloc,
        accepted_nesting,
        "$value:expr",
    );
    _ = try parseMatcher(alloc, accepted_matcher_text);
    const rejected_matcher_text = try nestedMacroRepetitionTextForTest(
        alloc,
        macro_parse_depth_max,
        "$value:expr",
    );
    try std.testing.expectError(
        error.InvalidMacroMatcher,
        parseMatcher(alloc, rejected_matcher_text),
    );

    const accepted_template_text = try nestedMacroRepetitionTextForTest(
        alloc,
        accepted_nesting,
        "$value",
    );
    _ = try parseTemplate(alloc, accepted_template_text);
    const rejected_template_text = try nestedMacroRepetitionTextForTest(
        alloc,
        macro_parse_depth_max,
        "$value",
    );
    try std.testing.expectError(
        error.InvalidMacroTemplate,
        parseTemplate(alloc, rejected_template_text),
    );
}
