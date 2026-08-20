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

        if (c == '/' and i + 1 < trimmed.len) {
            if (trimmed[i + 1] == '/') {
                i += 2;
                while (i < trimmed.len and trimmed[i] != '\n') : (i += 1) {}
                if (i == trimmed.len) break;
                continue;
            }
            if (trimmed[i + 1] == '*') {
                i = findBlockCommentEnd(trimmed, i) orelse return trimmed;
                continue;
            }
        }

        if (c == 'r' or (c == 'b' and i + 1 < trimmed.len and trimmed[i + 1] == 'r')) {
            const prefix_len: usize = if (c == 'r') 1 else 2;
            var marker = i + prefix_len;
            while (marker < trimmed.len and trimmed[marker] == '#') : (marker += 1) {}
            if (marker < trimmed.len and trimmed[marker] == '"') {
                const hash_count = marker - i - prefix_len;
                i = findRawStringEnd(trimmed, marker + 1, hash_count) orelse return trimmed;
                continue;
            }
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
    const text = getEnclosedContent(raw_tokens);
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

    /// Deep-free matcher/template slices including nested repetition arrays.
    pub fn deinit(self: *MacroDef, alloc: std.mem.Allocator) void {
        for (self.rules) |rule| {
            freeMatcherElements(alloc, rule.matcher);
            freeTemplateElements(alloc, rule.template);
        }
        alloc.free(self.rules);
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
    if (s.len == 0 or !isIdentStart(s[0])) return false;
    for (s[1..]) |c| {
        if (!isIdentChar(c)) return false;
    }
    return true;
}

fn metavarAccepts(kind: MetavarKind, val: []const u8) bool {
    return switch (kind) {
        .ident => isIdentifier(val),
        .lifetime => val.len > 0 and val[0] == '\'' and isIdentifier(val[1..]),
        .literal => val.len > 0 and (std.ascii.isDigit(val[0]) or val[0] == '"' or val[0] == '\'' or val[0] == 'b' or val[0] == 'r'),
        .ty, .expr, .path, .tt, .pat, .stmt, .block, .item, .vis => true,
    };
}

pub const Bindings = struct {
    alloc: std.mem.Allocator,
    top_vars: std.StringHashMapUnmanaged([]const u8) = .empty,
    rep_vars: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty,

    pub fn init(alloc: std.mem.Allocator) Bindings {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Bindings) void {
        self.top_vars.deinit(self.alloc);
        var it = self.rep_vars.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.alloc);
        }
        self.rep_vars.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn setTop(self: *Bindings, name: []const u8, val: []const u8) !void {
        try self.top_vars.put(self.alloc, name, val);
    }

    pub fn addRep(self: *Bindings, name: []const u8, val: []const u8) !void {
        var gop = try self.rep_vars.getOrPut(self.alloc, name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(self.alloc, val);
    }

    pub fn getTop(self: *const Bindings, name: []const u8) ?[]const u8 {
        return self.top_vars.get(name);
    }

    pub fn getRep(self: *const Bindings, name: []const u8, idx: usize) ?[]const u8 {
        if (self.rep_vars.get(name)) |list| {
            if (idx < list.items.len) return list.items[idx];
        }
        return null;
    }

    pub fn getRepLen(self: *const Bindings, name: []const u8) usize {
        if (self.rep_vars.get(name)) |list| {
            return list.items.len;
        }
        return 0;
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

pub fn findClosingDelimiter(s: []const u8, start: usize) ?usize {
    if (start >= s.len) return null;
    const open_char = s[start];
    const close_char: u8 = switch (open_char) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        else => return null,
    };

    var depth: usize = 0;
    var in_double_quote: bool = false;
    var escape: bool = false;
    var i: usize = start;

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
        if (c == '"') {
            in_double_quote = true;
            continue;
        }
        if (c == '\'') {
            if (findCharEnd(s, i)) |end| {
                i = end;
                continue;
            }
        }

        if (c == open_char) {
            depth += 1;
        } else if (c == close_char) {
            if (depth > 0) depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

const macro_parse_depth_max: usize = 128;

pub fn parseMatcher(alloc: std.mem.Allocator, raw: []const u8) ![]const MatcherElement {
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
            const close_idx = findClosingDelimiter(raw, open_idx) orelse return error.InvalidMacroMatcher;
            const inner_text = raw[open_idx + 1 .. close_idx];
            const inner_elems = try parseMatcherDepth(alloc, inner_text, depth + 1);
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
                if (op_idx < raw.len) {
                    const raw_sep = std.mem.trim(u8, raw[post..op_idx], " \t\r\n");
                    sep = if (raw_sep.len > 0) raw_sep else null;
                    op = if (raw[op_idx] == '*') .zero_or_more else if (raw[op_idx] == '+') .one_or_more else .zero_or_one;
                    i = op_idx + 1;
                } else {
                    i = post;
                }
            }
            try list.append(alloc, .{ .repetition = .{ .elements = inner_elems, .separator = sep, .op = op } });
            inner_elems_owned = false;
        } else if (raw[i] == '$' and i + 1 < raw.len and isIdentStart(raw[i + 1])) {
            i += 1;
            const var_start = i;
            while (i < raw.len and isIdentChar(raw[i])) : (i += 1) {}
            const var_name = raw[var_start..i];

            var kind: MetavarKind = .ident;
            const saved_i = i;
            const after_ws = skipWhitespaceAndComments(raw, i);
            if (after_ws < raw.len and raw[after_ws] == ':') {
                var kind_pos = skipWhitespaceAndComments(raw, after_ws + 1);
                const kind_start = kind_pos;
                while (kind_pos < raw.len and isIdentChar(raw[kind_pos])) : (kind_pos += 1) {}
                if (kind_pos > kind_start) {
                    const kind_name = raw[kind_start..kind_pos];
                    if (MetavarKind.fromString(kind_name)) |k| {
                        kind = k;
                        i = kind_pos;
                    } else {
                        i = saved_i;
                    }
                } else {
                    i = saved_i;
                }
            }
            try list.append(alloc, .{ .metavar = .{ .name = var_name, .kind = kind } });
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
                const close_idx = findClosingDelimiter(raw, open_idx) orelse return error.InvalidMacroTemplate;
                const inner_text = raw[open_idx + 1 .. close_idx];
                const inner_elems = try parseTemplateDepth(alloc, inner_text, depth + 1);
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
                    if (op_idx < raw.len) {
                        const raw_sep = std.mem.trim(u8, raw[post..op_idx], " \t\r\n");
                        sep = if (raw_sep.len > 0) raw_sep else null;
                        op = if (raw[op_idx] == '*') .zero_or_more else if (raw[op_idx] == '+') .one_or_more else .zero_or_one;
                        i = op_idx + 1;
                    } else {
                        i = post;
                    }
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
                i += 1;
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

fn scanUntilDelimited(
    input_text: []const u8,
    start: usize,
    next_elem: ?MatcherElement,
    sep: ?[]const u8,
    follow_tok: ?[]const u8,
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
                if (ne == .token) {
                    if (std.mem.startsWith(u8, input_text[i..], ne.token)) {
                        return i;
                    }
                }
            }
            if (sep) |s| {
                if (std.mem.startsWith(u8, input_text[i..], s)) {
                    return i;
                }
            } else if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                // No explicit separator: a whitespace-separated repetition
                // matcher like `$($len:expr)+` yields one value per token.
                return i;
            }
            if (follow_tok) |ft| {
                if (std.mem.startsWith(u8, input_text[i..], ft)) {
                    return i;
                }
            }
        }
        i += 1;
    }
    return i;
}

pub fn matchPattern(
    alloc: std.mem.Allocator,
    elements: []const MatcherElement,
    input_text: []const u8,
    bindings: *Bindings,
) !bool {
    _ = alloc;
    var input_idx: usize = 0;
    var elem_idx: usize = 0;

    while (elem_idx < elements.len) {
        input_idx = skipWhitespaceAndComments(input_text, input_idx);
        const elem = elements[elem_idx];

        switch (elem) {
            .token => |tok| {
                if (input_idx + tok.len <= input_text.len and std.mem.startsWith(u8, input_text[input_idx..], tok)) {
                    input_idx += tok.len;
                    elem_idx += 1;
                } else {
                    return false;
                }
            },
            .metavar => |mv| {
                const next_elem = if (elem_idx + 1 < elements.len) elements[elem_idx + 1] else null;
                const val_start = input_idx;
                input_idx = scanUntilDelimited(input_text, input_idx, next_elem, null, null);
                const val = std.mem.trim(u8, input_text[val_start..input_idx], " \t\r\n");
                if (val.len == 0 or !metavarAccepts(mv.kind, val)) return false;
                try bindings.setTop(mv.name, val);
                elem_idx += 1;
            },
            .repetition => |rep| {
                const next_elem = if (elem_idx + 1 < elements.len) elements[elem_idx + 1] else null;
                const follow_tok = if (next_elem != null and next_elem.? == .token) next_elem.?.token else null;

                while (true) {
                    input_idx = skipWhitespaceAndComments(input_text, input_idx);
                    if (input_idx >= input_text.len) break;
                    if (follow_tok) |ft| {
                        if (std.mem.startsWith(u8, input_text[input_idx..], ft)) break;
                    }

                    for (rep.elements, 0..) |inner_elem, j| {
                        input_idx = skipWhitespaceAndComments(input_text, input_idx);
                        switch (inner_elem) {
                            .metavar => |mv| {
                                const inner_next = if (j + 1 < rep.elements.len) rep.elements[j + 1] else null;
                                const val_start = input_idx;
                                input_idx = scanUntilDelimited(input_text, input_idx, inner_next, rep.separator, follow_tok);
                                const val = std.mem.trim(u8, input_text[val_start..input_idx], " \t\r\n");
                                if (val.len == 0 or !metavarAccepts(mv.kind, val)) return false;
                                try bindings.addRep(mv.name, val);
                            },
                            .token => |tok| {
                                if (input_idx + tok.len <= input_text.len and std.mem.startsWith(u8, input_text[input_idx..], tok)) {
                                    input_idx += tok.len;
                                } else {
                                    return false;
                                }
                            },
                            .repetition => {
                                return false; // Nested matcher repetition not yet required
                            },
                        }
                    }

                    input_idx = skipWhitespaceAndComments(input_text, input_idx);
                    if (rep.separator) |s| {
                        if (input_idx + s.len <= input_text.len and std.mem.startsWith(u8, input_text[input_idx..], s)) {
                            input_idx += s.len;
                        } else if (follow_tok != null and std.mem.startsWith(u8, input_text[input_idx..], follow_tok.?)) {
                            break;
                        } else if (input_idx >= input_text.len) {
                            break;
                        } else {
                            break;
                        }
                    }
                }
                elem_idx += 1;
            },
        }
    }

    input_idx = skipWhitespaceAndComments(input_text, input_idx);
    if (input_idx < input_text.len and (input_text[input_idx] == ',' or input_text[input_idx] == ';')) {
        input_idx = skipWhitespaceAndComments(input_text, input_idx + 1);
    }
    return (input_idx >= input_text.len and elem_idx >= elements.len);
}

fn findRepCount(elem: TemplateElement, bindings: *const Bindings, count: *usize) void {
    switch (elem) {
        .metavar => |var_name| {
            const len = bindings.getRepLen(var_name);
            if (len > count.*) {
                count.* = len;
            }
        },
        .repetition => |rep| {
            for (rep.elements) |child| {
                findRepCount(child, bindings, count);
            }
        },
        .text => {},
    }
}

fn expandTemplateElements(
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    elements: []const TemplateElement,
    bindings: *const Bindings,
    rep_idx: ?usize,
) !void {
    for (elements) |elem| {
        switch (elem) {
            .text => |t| {
                try out.appendSlice(alloc, t);
            },
            .metavar => |var_name| {
                if (rep_idx) |idx| {
                    if (bindings.getRep(var_name, idx)) |val| {
                        try out.appendSlice(alloc, val);
                        continue;
                    }
                }
                if (bindings.getTop(var_name)) |val| {
                    try out.appendSlice(alloc, val);
                } else if (rep_idx == null and bindings.getRepLen(var_name) > 0) {
                    if (bindings.getRep(var_name, 0)) |val| {
                        try out.appendSlice(alloc, val);
                    }
                }
            },
            .repetition => |rep| {
                var count: usize = 0;
                for (rep.elements) |child| {
                    findRepCount(child, bindings, &count);
                }
                for (0..count) |idx| {
                    if (idx > 0 and rep.separator != null) {
                        try out.appendSlice(alloc, rep.separator.?);
                        try out.appendSlice(alloc, "\n");
                    }
                    try expandTemplateElements(alloc, out, rep.elements, bindings, idx);
                }
            },
        }
    }
}

pub fn expandMacroRules(
    alloc: std.mem.Allocator,
    def: MacroDef,
    raw_args: []const u8,
) !?[]const u8 {
    const trimmed_args = getEnclosedContent(raw_args);
    for (def.rules) |rule| {
        var bindings = Bindings.init(alloc);
        defer bindings.deinit();

        if (try matchPattern(alloc, rule.matcher, trimmed_args, &bindings)) {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out.deinit(alloc);
            try expandTemplateElements(alloc, &out, rule.template, &bindings, null);
            const expanded = try out.toOwnedSlice(alloc);
            return expanded;
        }
    }
    return null;
}

pub fn parseMacroRulesDefinition(alloc: std.mem.Allocator, raw_def: []const u8) !?MacroDef {
    var i = skipWhitespaceAndComments(raw_def, 0);
    if (std.mem.startsWith(u8, raw_def[i..], "macro_rules!")) {
        i += "macro_rules!".len;
    }
    i = skipWhitespaceAndComments(raw_def, i);
    if (i >= raw_def.len or !isIdentStart(raw_def[i])) return null;

    const name_start = i;
    while (i < raw_def.len and isIdentChar(raw_def[i])) : (i += 1) {}
    const name = raw_def[name_start..i];

    i = skipWhitespaceAndComments(raw_def, i);
    if (i >= raw_def.len or (raw_def[i] != '{' and raw_def[i] != '(' and raw_def[i] != '[')) return null;

    const body_open = i;
    const body_close = findClosingDelimiter(raw_def, body_open) orelse return null;
    const rules_body = raw_def[body_open + 1 .. body_close];

    var rules_list: std.ArrayListUnmanaged(MacroRule) = .empty;
    errdefer rules_list.deinit(alloc);

    var idx: usize = 0;
    while (idx < rules_body.len) {
        idx = skipWhitespaceAndComments(rules_body, idx);
        if (idx >= rules_body.len) break;
        if (rules_body[idx] == ';') {
            idx += 1;
            continue;
        }
        if (rules_body[idx] != '(' and rules_body[idx] != '[' and rules_body[idx] != '{') {
            break;
        }
        const matcher_open = idx;
        const matcher_close = findClosingDelimiter(rules_body, matcher_open) orelse break;
        const raw_matcher = rules_body[matcher_open + 1 .. matcher_close];
        idx = matcher_close + 1;
        idx = skipWhitespaceAndComments(rules_body, idx);
        if (idx + 2 > rules_body.len or !std.mem.startsWith(u8, rules_body[idx..], "=>")) break;
        idx += 2;
        idx = skipWhitespaceAndComments(rules_body, idx);
        if (idx >= rules_body.len or (rules_body[idx] != '{' and rules_body[idx] != '(' and rules_body[idx] != '[')) break;
        const tmpl_open = idx;
        const tmpl_close = findClosingDelimiter(rules_body, tmpl_open) orelse break;
        const raw_tmpl = rules_body[tmpl_open + 1 .. tmpl_close];
        idx = tmpl_close + 1;

        const matcher_elems = try parseMatcher(alloc, raw_matcher);
        const tmpl_elems = try parseTemplate(alloc, raw_tmpl);
        try rules_list.append(alloc, .{
            .matcher = matcher_elems,
            .template = tmpl_elems,
            .raw_matcher = raw_matcher,
            .raw_template = raw_tmpl,
        });

        idx = skipWhitespaceAndComments(rules_body, idx);
        if (idx < rules_body.len and rules_body[idx] == ';') {
            idx += 1;
        }
    }

    return .{
        .name = name,
        .rules = try rules_list.toOwnedSlice(alloc),
    };
}

pub const MacroTable = struct {
    alloc: std.mem.Allocator,
    macros: std.StringHashMapUnmanaged(MacroDef) = .empty,

    pub fn init(alloc: std.mem.Allocator) MacroTable {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *MacroTable) void {
        self.macros.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn register(self: *MacroTable, name: []const u8, def: MacroDef) !void {
        try self.macros.put(self.alloc, name, def);
    }

    pub fn get(self: *const MacroTable, name: []const u8) ?MacroDef {
        var clean_name = name;
        if (std.mem.endsWith(u8, clean_name, "!")) {
            clean_name = clean_name[0 .. clean_name.len - 1];
        }
        return self.macros.get(clean_name);
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
