//! Linter for the ownership fixtures under `test/crates/`.
//!
//! An ownership fixture is a small Rust crate plus a Zig consumer that proves
//! what the translated package does. The fixture alone proves nothing, and a
//! consumer that merely compiles proves nothing either, so this linter reads
//! both halves and reports what is missing.
//!
//! # Rules
//!
//! | rule | what it rejects |
//! | --- | --- |
//! | `fixture_without_rust_source` | a fixture directory with no `src/lib.rs` and no `src/main.rs` |
//! | `fixture_without_public_items` | a fixture whose Rust source exports nothing |
//! | `fixture_without_consumer` | a fixture with no consumer file |
//! | `consumer_does_not_parse` | a consumer that is not valid Zig |
//! | `consumer_without_tests` | a consumer with no `test` declaration |
//! | `consumer_does_not_execute` | a consumer that never calls or builds a value from the package |
//! | `consumer_never_names_an_export` | a consumer that names none of the fixture's public items |
//! | `test_without_value_assertion` | one `test` that asserts nothing: it did not throw |
//! | `consumer_only_asserts_shape` | a consumer whose every assertion is a size or a length |
//! | `consumer_asserts_emitted_text` | an assertion that searches or prints text instead of comparing a value |
//! | `consumer_reads_translated_source` | a consumer that reads the translated `.zig` or the IR JSON |
//!
//! Every rule is decided from tokens, never from a file-name pattern. A
//! consumer counts as executing only when a call or a value construction is
//! rooted at the module it imports the package from, an assertion counts as a
//! value assertion only when it is not purely a size or length claim, and a
//! `test` inherits the assertions of every helper it calls, so a consumer may
//! factor its expectations into functions without losing them.
//!
//! # Which module is the fixture's
//!
//! Every import binding is the fixture's module unless its `@import` name is on
//! the runtime and standard-library deny list: `r2z`, `std`, `builtin`,
//! `testing`, `posix`, `fmt` and `mem`. A consumer that names its module after
//! the fixture, as `loop_ownership_exits`, is therefore read correctly, and one
//! that imports a staged package under a generic name such as `translated` is
//! read as the fixture's as well. The deny list is what keeps a call into the
//! runtime from being counted as a call into the package, and what keeps
//! `std.testing.expect...` from being read as a package call. A consumer that
//! imports nothing but the runtime and the standard library names no package
//! module at all, so it never executes the fixture and both
//! `consumer_does_not_execute` and `consumer_never_names_an_export` fire.
//!
//! # Consumer discovery
//!
//! For a fixture directory `name`, these three candidates are used when they
//! exist, and all of them when more than one does:
//!
//!   1. `consumer_dir/name_with_underscores_consumer.zig`
//!   2. `fixture_root/name/consumer.zig`
//!   3. `fixture_root/name/name_with_underscores_consumer.zig`
//!
//! When none of them exists, every `consumer_dir/*_consumer.zig` that
//! `@import`s a module named `name` or `name_with_underscores` is a shared
//! consumer and counts instead. `consumer_dir` defaults to the parent of the
//! fixture root, so `--root test/crates` finds `test/<name>_consumer.zig`.
//!
//! # Run
//!
//!     zig run test/ownership_fixture_lint.zig -- --root test/crates
//!     zig run test/ownership_fixture_lint.zig -- --root test/crates \
//!         --only loop-ownership-exits --only closure-capture-ownership
//!
//! Without `--only`, every fixture directory under the root is checked. Each
//! finding becomes one line on stdout and the exit status is 1 when there is at
//! least one finding, 2 when the run could not read the tree at all.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// The largest consumer or Rust source the linter reads. A consumer is a test
/// file and a fixture is a hand-written crate, so anything past this is not one.
const max_file_bytes = 1 << 24;

/// Every kind of finding this linter reports.
pub const Rule = enum {
    fixture_without_rust_source,
    fixture_without_public_items,
    fixture_without_consumer,
    consumer_does_not_parse,
    consumer_without_tests,
    consumer_does_not_execute,
    consumer_never_names_an_export,
    test_without_value_assertion,
    consumer_only_asserts_shape,
    consumer_asserts_emitted_text,
    consumer_reads_translated_source,
};

/// One finding: the rule, the fixture it belongs to, where it was read and on
/// which line.
pub const Finding = struct {
    rule: Rule,
    /// The fixture directory name, without its path.
    fixture: []const u8,
    /// The file the finding was read from, relative to the consumer directory,
    /// or null for a finding about the fixture itself.
    path: ?[]const u8,
    /// The one-based line, or 0 when the finding belongs to no line.
    line: usize,
};

/// What one lint run found. The caller owns it and frees it with `deinit`.
pub const Summary = struct {
    /// The fixtures this run looked at.
    fixtures: usize,
    /// The consumers this run read.
    consumers: usize,
    findings: []Finding,

    pub fn hasFindings(self: Summary) bool {
        return self.findings.len != 0;
    }

    /// True when at least one finding carries `rule`.
    pub fn reports(self: Summary, rule: Rule) bool {
        for (self.findings) |finding| {
            if (finding.rule == rule) return true;
        }
        return false;
    }

    /// How many findings carry `rule`.
    pub fn count(self: Summary, rule: Rule) usize {
        var total: usize = 0;
        for (self.findings) |finding| {
            if (finding.rule == rule) total += 1;
        }
        return total;
    }

    pub fn deinit(self: Summary, gpa: Allocator) void {
        freeFindings(gpa, self.findings);
    }
};

/// What to check, and where.
pub const Options = struct {
    /// The directory holding one subdirectory per fixture crate.
    fixture_root: []const u8,
    /// Where consumers live. Defaults to the parent of `fixture_root`.
    consumer_dir: ?[]const u8 = null,
    /// The fixtures to check. Empty checks every one under the root.
    only: []const []const u8 = &.{},
};

/// The fixture a consumer is read against.
pub const Fixture = struct {
    /// The fixture directory name.
    name: []const u8,
    /// Every `pub` item name in the fixture's Rust source.
    exports: []const []const u8,
};

/// What one `test` declaration asserts, counting the helpers it calls.
pub const TestFacts = struct {
    name: []const u8,
    line: usize,
    value_assertions: usize,
};

/// What a consumer's tokens say about it.
pub const ConsumerFacts = struct {
    tests: []const TestFacts,
    /// Every `std.testing.expect...` call in the file.
    assertions: usize,
    /// The assertions among them that claim a value rather than a size.
    value_assertions: usize,
    /// Calls and value constructions rooted at the package module.
    runtime_touches: usize,
    /// True when some path names an item the fixture exports.
    names_an_export: bool,
    reads_translated_source: bool,
    /// The line of the first generated-artifact read, or 0.
    first_read_line: usize,
    /// The lines of the assertions that search or print text.
    text_assertions: []const usize,
};

/// Why a consumer could not be read at all.
pub const ParseProblem = struct {
    /// The one-based line of the first parse error.
    line: usize,
    /// The parse error's tag name, for the finding line.
    tag: []const u8,
};

/// What reading one consumer produced.
pub const Analysis = union(enum) {
    parsed: ConsumerFacts,
    invalid: ParseProblem,
};

// ── Run ─────────────────────────────────────────────────────────────────────

/// Check every selected fixture under `options.fixture_root` and write one line
/// per finding to `out`.
pub fn run(gpa: Allocator, io: std.Io, options: Options, out: *Writer) !Summary {
    var findings: std.ArrayList(Finding) = .empty;
    const consumer_dir = options.consumer_dir orelse
        std.fs.path.dirname(options.fixture_root) orelse "";

    const fixture_root = try openDirectory(io, options.fixture_root);
    defer fixture_root.close(io);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| gpa.free(name);
        names.deinit(gpa);
    }
    var iterator = fixture_root.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!selects(options.only, entry.name)) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, lessThanName);

    var fixtures: usize = 0;
    var consumers: usize = 0;
    for (names.items) |name| {
        fixtures += 1;
        consumers += try lintFixture(gpa, io, options, consumer_dir, name, &findings, out);
    }

    const owned = findings.toOwnedSlice(gpa) catch |err| {
        freeFindings(gpa, findings.items);
        return err;
    };
    return .{ .fixtures = fixtures, .consumers = consumers, .findings = owned };
}

pub fn main(init: std.process.Init) u8 {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var root: []const u8 = "test/crates";
    var consumer_dir: ?[]const u8 = null;
    var only: std.ArrayList([]const u8) = .empty;
    const args = init.minimal.args.toSlice(arena) catch |err| {
        std.log.err("ownership_fixture_lint: cannot read the command line: {t}", .{err});
        return 2;
    };
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg: []const u8 = args[index];
        if (std.mem.eql(u8, arg, "--root")) {
            index += 1;
            if (index == args.len) return usage("--root needs a directory", .{});
            root = args[index];
        } else if (std.mem.eql(u8, arg, "--consumers")) {
            index += 1;
            if (index == args.len) return usage("--consumers needs a directory", .{});
            consumer_dir = args[index];
        } else if (std.mem.eql(u8, arg, "--only")) {
            index += 1;
            if (index == args.len) return usage("--only needs a fixture name", .{});
            only.append(arena, args[index]) catch |err| {
                std.log.err("ownership_fixture_lint: {t}", .{err});
                return 2;
            };
        } else {
            return usage("unknown argument: {s}", .{arg});
        }
    }

    var out: std.Io.Writer.Allocating = .init(init.gpa);
    defer out.deinit();
    const summary = run(init.gpa, init.io, .{
        .fixture_root = root,
        .consumer_dir = consumer_dir,
        .only = only.items,
    }, &out.writer) catch |err| {
        std.log.err("ownership_fixture_lint: {s}: {t}", .{ root, err });
        return 2;
    };
    defer summary.deinit(init.gpa);

    try std.Io.File.stdout().writeStreamingAll(init.io, out.written());
    if (summary.fixtures == 0) {
        std.log.err("ownership_fixture_lint: no fixture under {s}", .{root});
        return 2;
    }
    return if (summary.hasFindings()) 1 else 0;
}

// ── One fixture ─────────────────────────────────────────────────────────────

fn lintFixture(
    gpa: Allocator,
    io: std.Io,
    options: Options,
    consumer_dir: []const u8,
    name: []const u8,
    findings: *std.ArrayList(Finding),
    out: *Writer,
) !usize {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const consumer_paths = try findConsumers(arena, io, options.fixture_root, consumer_dir, name);
    if (consumer_paths.len == 0) {
        try report(gpa, findings, out, .{
            .rule = .fixture_without_consumer,
            .fixture = name,
            .path = null,
            .line = 0,
        }, "no consumer: expected {s}/{s}_consumer.zig or {s}/consumer.zig", .{
            consumer_dir, try underscoredName(arena, name), name,
        });
        return 0;
    }

    const source_path = try rustSourcePath(arena, io, options.fixture_root, name);
    if (source_path == null) {
        try report(gpa, findings, out, .{
            .rule = .fixture_without_rust_source,
            .fixture = name,
            .path = null,
            .line = 0,
        }, "no src/lib.rs and no src/main.rs, so there is no crate to translate", .{});
        return consumer_paths.len;
    }
    const rust_source = try readFile(arena, io, source_path.?);
    const exports = try rustPublicNames(arena, rust_source);
    if (exports.len == 0) {
        try report(gpa, findings, out, .{
            .rule = .fixture_without_public_items,
            .fixture = name,
            .path = null,
            .line = 0,
        }, "the Rust source exports no pub item, so no consumer could call anything", .{});
        return consumer_paths.len;
    }

    const fixture: Fixture = .{ .name = name, .exports = exports };
    for (consumer_paths) |path| {
        try lintConsumer(gpa, arena, io, fixture, path, findings, out);
    }
    return consumer_paths.len;
}

fn lintConsumer(
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    fixture: Fixture,
    path: []const u8,
    findings: *std.ArrayList(Finding),
    out: *Writer,
) !void {
    const source = try readFile(arena, io, path);
    switch (try analyze(arena, source, fixture)) {
        .invalid => |problem| {
            try report(gpa, findings, out, .{
                .rule = .consumer_does_not_parse,
                .fixture = fixture.name,
                .path = path,
                .line = problem.line,
            }, "not valid Zig: {s}", .{problem.tag});
            return;
        },
        .parsed => |facts| try reportFacts(gpa, findings, out, fixture, path, facts),
    }
}

fn reportFacts(
    gpa: Allocator,
    findings: *std.ArrayList(Finding),
    out: *Writer,
    fixture: Fixture,
    path: []const u8,
    facts: ConsumerFacts,
) !void {
    if (facts.tests.len == 0) {
        try report(gpa, findings, out, .{
            .rule = .consumer_without_tests,
            .fixture = fixture.name,
            .path = path,
            .line = 1,
        }, "no test declaration, so nothing in it ever runs", .{});
        return;
    }
    if (facts.runtime_touches == 0) {
        try report(gpa, findings, out, .{
            .rule = .consumer_does_not_execute,
            .fixture = fixture.name,
            .path = path,
            .line = 1,
        }, "never calls or builds a value from the package", .{});
    }
    if (!facts.names_an_export) {
        try report(gpa, findings, out, .{
            .rule = .consumer_never_names_an_export,
            .fixture = fixture.name,
            .path = path,
            .line = 1,
        }, "names none of the fixture's public items", .{});
    }
    if (facts.reads_translated_source) {
        try report(gpa, findings, out, .{
            .rule = .consumer_reads_translated_source,
            .fixture = fixture.name,
            .path = path,
            .line = facts.first_read_line,
        }, "reads a generated artifact instead of calling the package", .{});
    }
    if (facts.assertions != 0 and facts.value_assertions == 0) {
        try report(gpa, findings, out, .{
            .rule = .consumer_only_asserts_shape,
            .fixture = fixture.name,
            .path = path,
            .line = 1,
        }, "every assertion is a size or a length; assert a value the package computes", .{});
    }
    for (facts.text_assertions) |line| {
        try report(gpa, findings, out, .{
            .rule = .consumer_asserts_emitted_text,
            .fixture = fixture.name,
            .path = path,
            .line = line,
        }, "the assertion searches or prints text instead of comparing a value", .{});
    }
    for (facts.tests) |test_case| {
        if (test_case.value_assertions != 0) continue;
        try report(gpa, findings, out, .{
            .rule = .test_without_value_assertion,
            .fixture = fixture.name,
            .path = path,
            .line = test_case.line,
        }, "test '{s}' asserts nothing: it only proves that nothing threw", .{test_case.name});
    }
}

// ── Consumer discovery ──────────────────────────────────────────────────────

fn findConsumers(
    arena: Allocator,
    io: std.Io,
    fixture_root: []const u8,
    consumer_dir: []const u8,
    name: []const u8,
) ![][]const u8 {
    const underscored = try underscoredName(arena, name);
    var found: std.ArrayList([]const u8) = .empty;

    const direct = [_][]const u8{
        try std.fs.path.join(arena, &.{ consumer_dir, underscored, "_consumer.zig" }),
        try std.fs.path.join(arena, &.{ fixture_root, name, "consumer.zig" }),
        try std.fs.path.join(arena, &.{ fixture_root, name, underscored, "_consumer.zig" }),
    };
    for (direct) |candidate| {
        if (try isFile(io, candidate)) try found.append(arena, candidate);
    }
    if (found.items.len != 0) return found.items;
    if (consumer_dir.len == 0) return found.items;

    // A shared consumer counts when it imports the fixture's module by name.
    const directory = try openDirectory(io, consumer_dir);
    defer directory.close(io);
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, "_consumer.zig")) continue;
        const path = try std.fs.path.join(arena, &.{ consumer_dir, entry.name });
        const source = readFile(arena, io, path) catch continue;
        if (importsModule(source, name) or importsModule(source, underscored)) {
            try found.append(arena, path);
        }
    }
    std.mem.sort([]const u8, found.items, {}, lessThanText);
    return found.items;
}

fn underscoredName(gpa: Allocator, name: []const u8) ![]const u8 {
    const copy = try gpa.dupe(u8, name);
    for (copy) |*byte| {
        if (byte.* == '-') byte.* = '_';
    }
    return copy;
}

fn importsModule(source: []const u8, name: []const u8) bool {
    var rest = source;
    while (std.mem.indexOf(u8, rest, "@import(")) |open| {
        rest = rest[open + "@import(".len ..];
        const closing = std.mem.indexOfScalar(u8, rest, ')') orelse return false;
        const argument = std.mem.trim(u8, rest[0..closing], " \t\"");
        if (std.mem.eql(u8, argument, name)) return true;
        rest = rest[closing + 1 ..];
    }
    return false;
}

// ── Rust source ─────────────────────────────────────────────────────────────

fn rustSourcePath(
    arena: Allocator,
    io: std.Io,
    fixture_root: []const u8,
    name: []const u8,
) !?[]const u8 {
    const library = try std.fs.path.join(arena, &.{ fixture_root, name, "src", "lib.rs" });
    if (try isFile(io, library)) return library;
    const binary = try std.fs.path.join(arena, &.{ fixture_root, name, "src", "main.rs" });
    if (try isFile(io, binary)) return binary;
    return null;
}

/// Every `pub` item name in a Rust source, in source order.
///
/// This is a scanner, not a Rust parser. It skips whitespace, comments, strings,
/// raw strings and character literals, then reads `pub`, an item keyword and the
/// name behind it. That is enough for the one question the linter asks of a
/// Rust source, which is whether a consumer names anything the fixture exports.
pub fn rustPublicNames(gpa: Allocator, source: []const u8) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);
    var index: usize = 0;
    while (index < source.len) {
        index = skipTrivia(source, index);
        if (index >= source.len) break;
        const byte = source[index];
        if (byte == '"') {
            index = skipString(source, index);
            continue;
        }
        if (byte == '\'') {
            index = skipCharOrLifetime(source, index);
            continue;
        }
        if (byte == 'r' and index + 1 < source.len and
            (source[index + 1] == '"' or source[index + 1] == '#'))
        {
            index = skipRawString(source, index);
            continue;
        }
        if (byte == 'b' and index + 1 < source.len and source[index + 1] == '"') {
            index = skipString(source, index + 1);
            continue;
        }
        const word = readWord(source, index) orelse {
            index += 1;
            continue;
        };
        if (!std.mem.eql(u8, word, "pub")) {
            index += word.len;
            continue;
        }

        // `pub(crate)`, `pub(in path)` and `pub(super)` are not exports.
        const after = skipTrivia(source, index + word.len);
        if (after < source.len and source[after] == '(') {
            index = skipGroup(source, after);
            continue;
        }
        const keyword = readWord(source, after) orelse {
            index += word.len;
            continue;
        };
        if (!isItemKeyword(keyword)) {
            index += word.len;
            continue;
        }
        const name_start = skipTrivia(source, after + keyword.len);
        const item = readWord(source, name_start) orelse {
            index = after + keyword.len;
            continue;
        };
        try appendUnique(gpa, &names, item);
        index = name_start + item.len;
    }
    return names.toOwnedSlice(gpa);
}

/// True when `word` is a Rust item keyword that a `pub` can precede. Zig has
/// no switch on strings, so this is a scan over the list.
fn isItemKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{
        "fn",
        "struct",
        "enum",
        "union",
        "trait",
        "const",
        "static",
        "type",
        "mod",
        "use",
    };
    for (keywords) |keyword| {
        if (std.mem.eql(u8, word, keyword)) return true;
    }
    return false;
}

fn appendUnique(gpa: Allocator, names: *std.ArrayList([]const u8), name: []const u8) !void {
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try names.append(gpa, name);
}

/// The next index past whitespace and comments, stopping anywhere else.
fn skipTrivia(source: []const u8, from: usize) usize {
    var index = from;
    while (index < source.len) {
        switch (source[index]) {
            ' ', '\t', '\r', '\n' => index += 1,
            '/' => {
                if (index + 1 >= source.len) return index;
                if (source[index + 1] == '/') {
                    index = skipLine(source, index);
                } else if (source[index + 1] == '*') {
                    index = skipBlock(source, index);
                } else {
                    return index;
                }
            },
            else => return index,
        }
    }
    return index;
}

fn skipLine(source: []const u8, from: usize) usize {
    var index = from;
    while (index < source.len and source[index] != '\n') : (index += 1) {}
    return index;
}

/// The index just past a `/* */` comment, counting nested comments the way Rust
/// counts them.
fn skipBlock(source: []const u8, from: usize) usize {
    var index = from + 2;
    var depth: usize = 1;
    while (index < source.len and depth != 0) {
        if (source[index] == '/' and index + 1 < source.len and source[index + 1] == '*') {
            depth += 1;
            index += 2;
        } else if (source[index] == '*' and index + 1 < source.len and source[index + 1] == '/') {
            depth -= 1;
            index += 2;
        } else {
            index += 1;
        }
    }
    return index;
}

/// The index just past the bracket group that starts at `from`.
fn skipGroup(source: []const u8, from: usize) usize {
    var index = from + 1;
    var depth: usize = 1;
    while (index < source.len and depth != 0) : (index += 1) {
        switch (source[index]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            '"' => index = skipString(source, index) - 1,
            else => {},
        }
    }
    return index;
}

/// The index just past the ordinary string that starts at `from`. A string
/// that never closes reports the end of the source, so a caller that assigns
/// the result to its cursor always moves forward.
fn skipString(source: []const u8, from: usize) usize {
    var index = from + 1;
    while (index < source.len) {
        switch (source[index]) {
            '\\' => index += 2,
            '"' => return index + 1,
            else => index += 1,
        }
    }
    return source.len;
}

/// The index just past the raw string that starts at `from`, or past the `r`
/// when what follows it is not a string.
fn skipRawString(source: []const u8, from: usize) usize {
    var index = from + 1;
    var hashes: usize = 0;
    while (index < source.len and source[index] == '#') : (index += 1) {
        hashes += 1;
    }
    if (index >= source.len or source[index] != '"') return from + 1;
    index += 1;
    while (index < source.len) : (index += 1) {
        if (source[index] != '"') continue;
        var closing = index + 1;
        var seen: usize = 0;
        while (seen < hashes and closing < source.len and source[closing] == '#') : (closing += 1) {
            seen += 1;
        }
        if (seen == hashes) return closing;
    }
    return from + 1;
}

/// The index just past a character literal at `from`, or past the quote when it
/// is a lifetime instead.
fn skipCharOrLifetime(source: []const u8, from: usize) usize {
    if (from + 1 >= source.len) return from + 1;
    if (source[from + 1] == '\\') return @min(from + 4, source.len);
    if (from + 2 < source.len and source[from + 2] == '\'') return from + 3;
    return from + 1;
}

/// The identifier or keyword at `from`, or null when there is none.
fn readWord(source: []const u8, from: usize) ?[]const u8 {
    if (from >= source.len) return null;
    const first = source[from];
    if (!std.ascii.isAlphabetic(first) and first != '_') return null;
    var end = from;
    while (end < source.len) : (end += 1) {
        if (!isNameByte(source[end])) break;
    }
    return source[from..end];
}

fn isNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

// ── Reading one consumer ────────────────────────────────────────────────────

/// Read what `source` says about itself as a consumer of `fixture`.
///
/// Everything the result points at is allocated from `arena`, so the caller
/// frees it by dropping the arena.
pub fn analyze(arena: Allocator, source: []const u8, fixture: Fixture) !Analysis {
    const sentinel = try arena.dupeZ(u8, source);
    const tree = try std.zig.Ast.parse(arena, sentinel, .zig);
    if (tree.errors.len != 0) {
        const problem = tree.errors[0];
        return .{ .invalid = .{
            .line = lineOfSource(sentinel, tree.tokens.items(.start)[problem.token]),
            .tag = @tagName(problem.tag),
        } };
    }

    const tokens: ConsumerTokens = .{
        .source = sentinel,
        .tags = tree.tokens.items(.tag),
        .starts = tree.tokens.items(.start),
        .tests = try findTests(arena, &tree),
        .functions = try findFunctions(arena, &tree),
        .imports = try findImports(arena, &tree),
        .paths = try collectPaths(arena, &tree, 0, tree.tokens.items(.tag).len),
        .builtin_paths = try findBuiltinPaths(arena, &tree),
        .calls = try findCalls(arena, &tree),
    };

    var aliases: std.ArrayList([]const u8) = .empty;
    for (tokens.imports) |entry| {
        if (!isPackageModule(entry.module)) continue;
        try aliases.append(arena, entry.alias);
    }

    var facts: ConsumerFacts = .{
        .tests = try testFacts(arena, &tokens),
        .assertions = 0,
        .value_assertions = 0,
        .runtime_touches = 0,
        .names_an_export = false,
        .reads_translated_source = false,
        .first_read_line = 0,
        .text_assertions = &.{},
    };

    for (aliases.items) |alias| {
        for (tokens.paths) |path| {
            if (!isRootedAt(pathText(&tokens, path), alias)) continue;
            if (touchesPackage(&tokens, path)) facts.runtime_touches += 1;
        }
    }
    for (tokens.paths) |path| {
        if (namesExport(pathText(&tokens, path), fixture.exports)) facts.names_an_export = true;
    }
    for (tokens.calls) |call| {
        if (!readsGeneratedSource(&tokens, call)) continue;
        facts.reads_translated_source = true;
        if (facts.first_read_line == 0) facts.first_read_line = lineOf(&tokens, call.open);
    }

    var text_lines: std.ArrayList(usize) = .empty;
    for (tokens.calls) |call| {
        if (!isAssertionCall(&tokens, call)) continue;
        facts.assertions += 1;
        switch (classifyAssertion(&tokens, call)) {
            .value => facts.value_assertions += 1,
            .shape => {},
            .text => try text_lines.append(arena, lineOf(&tokens, call.open)),
        }
    }
    facts.text_assertions = try text_lines.toOwnedSlice(arena);
    return .{ .parsed = facts };
}

/// True when an import is the fixture's package rather than the runtime or the
/// standard library. Zig has no switch on strings, so this is a scan over the
/// deny list.
fn isPackageModule(module: []const u8) bool {
    const denied = [_][]const u8{
        "r2z",
        "std",
        "builtin",
        "testing",
        "posix",
        "fmt",
        "mem",
    };
    for (denied) |name| {
        if (std.mem.eql(u8, module, name)) return false;
    }
    return true;
}

// ── Token passes ────────────────────────────────────────────────────────────

const TokenRange = struct {
    start: u32,
    end: u32,
};

const Function = struct {
    name: []const u8,
    range: TokenRange,
};

const Import = struct {
    alias: []const u8,
    module: []const u8,
};

const Call = struct {
    /// The index of the `(` token.
    open: u32,
    /// The index of the `)` token.
    close: u32,
    /// The index of the callee's first token.
    path_first: u32,
    /// One token range per argument, split on commas at depth zero.
    arguments: []const []TokenRange,
};

const Path = struct {
    first: u32,
    last: u32,
};

const ConsumerTokens = struct {
    source: [:0]const u8,
    tags: []const std.zig.Token.Tag,
    starts: []const std.zig.Ast.ByteOffset,
    tests: []const TokenRange,
    functions: []const Function,
    imports: []const Import,
    paths: []const Path,
    builtin_paths: []const Path,
    calls: []const Call,
};

fn findTests(arena: Allocator, tree: *const std.zig.Ast) ![]const TokenRange {
    const tags = tree.tokens.items(.tag);
    var found: std.ArrayList(TokenRange) = .empty;
    var index: usize = 0;
    while (index < tags.len) : (index += 1) {
        if (tags[index] != .keyword_test) continue;
        var cursor = index + 1;
        while (cursor < tags.len and tags[cursor] != .l_brace) : (cursor += 1) {}
        if (cursor == tags.len) break;
        const close = matching(tags, cursor, .l_brace, .r_brace);
        try found.append(arena, .{ .start = @intCast(index), .end = @intCast(close) });
        index = close;
    }
    return found.items;
}

fn findFunctions(arena: Allocator, tree: *const std.zig.Ast) ![]const Function {
    const tags = tree.tokens.items(.tag);
    var found: std.ArrayList(Function) = .empty;
    var index: usize = 0;
    var depth: usize = 0;
    while (index < tags.len) : (index += 1) {
        switch (tags[index]) {
            .l_brace => depth += 1,
            .r_brace => {
                if (depth != 0) depth -= 1;
            },
            .keyword_fn => {
                if (depth != 0) continue;
                const name_index = index + 1;
                if (name_index >= tags.len or tags[name_index] != .identifier) continue;
                var cursor = name_index;
                while (cursor < tags.len and tags[cursor] != .l_brace) : (cursor += 1) {}
                if (cursor == tags.len) break;
                const close = matching(tags, cursor, .l_brace, .r_brace);
                try found.append(arena, .{
                    .name = tree.tokenSlice(@intCast(name_index)),
                    .range = .{ .start = @intCast(index), .end = @intCast(close) },
                });
                index = close;
            },
            else => {},
        }
    }
    return found.items;
}

fn findImports(arena: Allocator, tree: *const std.zig.Ast) ![]const Import {
    const tags = tree.tokens.items(.tag);
    var found: std.ArrayList(Import) = .empty;
    var index: usize = 0;
    while (index + 3 < tags.len) : (index += 1) {
        if (tags[index] != .identifier) continue;
        if (tags[index + 1] != .equal) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(@intCast(index + 2)), "@import")) continue;
        if (tags[index + 3] != .l_paren) continue;
        const close = matching(tags, index + 3, .l_paren, .r_paren);
        const module = stringArgument(tree, index + 3, close) orelse continue;
        try found.append(arena, .{
            .alias = tree.tokenSlice(@intCast(index)),
            .module = module,
        });
    }
    return found.items;
}

fn collectPaths(
    arena: Allocator,
    tree: *const std.zig.Ast,
    from: usize,
    to: usize,
) ![]const Path {
    const tags = tree.tokens.items(.tag);
    var found: std.ArrayList(Path) = .empty;
    var index = from;
    while (index < to) : (index += 1) {
        if (!isPathToken(tags[index])) continue;
        var end = index;
        while (end + 2 < to and tags[end + 1] == .period and isPathToken(tags[end + 2])) {
            end += 2;
        }
        try found.append(arena, .{ .first = @intCast(index), .last = @intCast(end) });
        index = end;
    }
    return found.items;
}

fn findBuiltinPaths(arena: Allocator, tree: *const std.zig.Ast) ![]const Path {
    const tags = tree.tokens.items(.tag);
    var found: std.ArrayList(Path) = .empty;
    var index: usize = 0;
    while (index + 1 < tags.len) : (index += 1) {
        if (tags[index] != .builtin) continue;
        if (tags[index + 1] != .l_paren) continue;
        const close = matching(tags, index + 1, .l_paren, .r_paren);
        try found.appendSlice(arena, try collectPaths(arena, tree, index + 1, close));
        index = close;
    }
    return found.items;
}

fn findCalls(arena: Allocator, tree: *const std.zig.Ast) ![]const Call {
    const tags = tree.tokens.items(.tag);
    var found: std.ArrayList(Call) = .empty;
    var index: usize = 1;
    while (index < tags.len) : (index += 1) {
        if (tags[index] != .l_paren) continue;
        if (!isPathToken(tags[index - 1])) continue;
        var path_first = index - 1;
        while (path_first >= 2 and
            tags[path_first - 1] == .period and
            isPathToken(tags[path_first - 2])) : (path_first -= 2)
        {}
        const close = matching(tags, index, .l_paren, .r_paren);
        try found.append(arena, .{
            .open = @intCast(index),
            .close = @intCast(close),
            .path_first = @intCast(path_first),
            .arguments = try splitArguments(arena, tags, index, close),
        });
    }
    return found.items;
}

fn splitArguments(
    arena: Allocator,
    tags: []const std.zig.Token.Tag,
    open: usize,
    close: usize,
) ![]const []TokenRange {
    var arguments: std.ArrayList(TokenRange) = .empty;
    var depth: usize = 0;
    var start = open + 1;
    var index = open;
    while (index < close) : (index += 1) {
        switch (tags[index]) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -= 1,
            .comma => {
                if (depth != 0) continue;
                try arguments.append(arena, .{ .start = @intCast(start), .end = @intCast(index) });
                start = index + 1;
            },
            else => {},
        }
    }
    if (start < close) {
        try arguments.append(arena, .{ .start = @intCast(start), .end = @intCast(close) });
    }
    return arguments.items;
}

fn stringArgument(tree: *const std.zig.Ast, open: usize, close: usize) ?[]const u8 {
    const tags = tree.tokens.items(.tag);
    var index = open + 1;
    while (index < close and tags[index] != .string_literal) : (index += 1) {}
    if (index >= close) return null;
    return std.mem.trim(u8, tree.tokenSlice(@intCast(index)), "\"");
}

// ── Questions about tokens ──────────────────────────────────────────────────

fn isPathToken(tag: std.zig.Token.Tag) bool {
    return tag == .identifier or tag == .builtin;
}

fn tokenText(tokens: *const ConsumerTokens, token: usize) []const u8 {
    const start: usize = tokens.starts[token];
    const end: usize = if (token + 1 < tokens.starts.len)
        tokens.starts[token + 1]
    else
        tokens.source.len;
    return std.mem.trim(u8, tokens.source[start..end], " \t\r\n");
}

fn pathText(tokens: *const ConsumerTokens, path: Path) []const u8 {
    const start: usize = tokens.starts[path.first];
    const end: usize = if (path.last + 1 < tokens.starts.len)
        tokens.starts[path.last + 1]
    else
        tokens.source.len;
    return std.mem.trim(u8, tokens.source[start..end], " \t\r\n");
}

fn calleeText(tokens: *const ConsumerTokens, call: Call) []const u8 {
    const start: usize = tokens.starts[call.path_first];
    const end: usize = tokens.starts[call.open];
    return std.mem.trim(u8, tokens.source[start..end], " \t\r\n");
}

fn lastSegment(path: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfScalar(u8, path, '.') orelse return path;
    return path[cut + 1 ..];
}

fn isRootedAt(text: []const u8, alias: []const u8) bool {
    if (!std.mem.startsWith(u8, text, alias)) return false;
    if (text.len <= alias.len) return false;
    return text[alias.len] == '.';
}

/// True when the path runs the package rather than naming a type: `build(2)`
/// does, `Foo(u8){}` only builds a type.
fn touchesPackage(tokens: *const ConsumerTokens, path: Path) bool {
    const next: usize = path.last + 1;
    if (next >= tokens.tags.len) return false;
    if (tokens.tags[next] == .l_brace) return true;
    if (tokens.tags[next] != .l_paren) return false;
    const close = matching(tokens.tags, next, .l_paren, .r_paren);
    if (close + 1 >= tokens.tags.len) return true;
    return tokens.tags[close + 1] != .l_brace;
}

/// True when some segment of the dotted name is one of the fixture's exports.
fn namesExport(text: []const u8, exports: []const []const u8) bool {
    var rest = text;
    while (true) {
        const end = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
        if (containsName(exports, rest[0..end])) return true;
        if (end == rest.len) return false;
        rest = rest[end + 1 ..];
    }
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn isInsideBuiltin(tokens: *const ConsumerTokens, path: Path) bool {
    for (tokens.builtin_paths) |builtin| {
        if (builtin.first == path.first) return true;
    }
    return false;
}

/// Path name suffixes that turn an assertion into a search over text.
const text_names = [_][]const u8{
    "indexOf",
    "indexOfScalar",
    "indexOfAny",
    "indexOfNone",
    "indexOfPos",
    "lastIndexOf",
    "contains",
    "startsWith",
    "endsWith",
    "print",
};

/// Path name suffixes that make a path a size or a length claim.
const shape_names = [_][]const u8{
    "@sizeOf",
    "@bitSizeOf",
    "@alignOf",
    "@offsetOf",
    "@typeInfo",
    "@TypeOf",
};

/// Path name suffixes that mean a consumer read a generated artifact.
const generated_suffixes = [_][]const u8{ ".zig", ".json", ".rustir" };

/// Path name suffixes that mean a consumer read a file at all.
const read_names = [_][]const u8{ "readFileAlloc", "readFile", "readToEndAlloc" };

fn isShapeText(text: []const u8) bool {
    if (std.mem.eql(u8, lastSegment(text), "len")) return true;
    for (shape_names) |name| {
        if (std.mem.eql(u8, text, name)) return true;
    }
    return false;
}

fn isTextText(text: []const u8) bool {
    const segment = lastSegment(text);
    for (text_names) |name| {
        if (std.mem.eql(u8, segment, name)) return true;
    }
    return false;
}

const AssertionClass = enum { value, shape, text };

/// Decide what one assertion claims.
///
/// A shape claim is made entirely of sizes and lengths: no string literal, no
/// call, nothing but size expressions and constants, and at least one size
/// expression. An assertion that searches or prints text claims text. Everything
/// else claims a value.
fn classifyAssertion(tokens: *const ConsumerTokens, call: Call) AssertionClass {
    var size_markers: usize = 0;
    var claims_a_value = false;
    var searches_text = false;
    for (call.arguments) |argument| {
        if (hasStringLiteral(tokens, argument)) claims_a_value = true;
        if (hasCall(tokens, argument)) claims_a_value = true;
        var index: usize = argument.start;
        while (index < argument.end) : (index += 1) {
            if (!isPathToken(tokens.tags[index])) continue;
            const path = pathsEndingAt(tokens, @intCast(index));
            const text = pathText(tokens, path);
            if (isTextText(text)) searches_text = true;
            if (isInsideBuiltin(tokens, path)) continue;
            if (isShapeText(text)) {
                size_markers += 1;
                continue;
            }
            // A bare name is an operand, not a claim of its own: `@sizeOf(T)`
            // is a size claim, and `expect(a == b)` has no size marker at all.
            if (path.last == path.first) continue;
            claims_a_value = true;
        }
    }
    if (searches_text) return .text;
    if (claims_a_value or size_markers == 0) return .value;
    return .shape;
}

/// The maximal path that ends at `token`.
fn pathsEndingAt(tokens: *const ConsumerTokens, token: u32) Path {
    var first = token;
    while (first >= 2 and
        tokens.tags[first - 1] == .period and
        isPathToken(tokens.tags[first - 2])) : (first -= 2)
    {}
    return .{ .first = first, .last = token };
}

fn hasStringLiteral(tokens: *const ConsumerTokens, argument: TokenRange) bool {
    var index: usize = argument.start;
    while (index < argument.end) : (index += 1) {
        if (tokens.tags[index] == .string_literal) return true;
    }
    return false;
}

/// True when the argument runs something. A builtin is not a run: `@as(T, x)`,
/// `@TypeOf(x)` and `@sizeOf(T)` are conversions and queries, and a size query
/// claims nothing about a value.
fn hasCall(tokens: *const ConsumerTokens, argument: TokenRange) bool {
    var index: usize = argument.start;
    while (index + 1 < argument.end) : (index += 1) {
        if (tokens.tags[index] == .builtin) continue;
        if (!isPathToken(tokens.tags[index])) continue;
        if (tokens.tags[index + 1] != .l_paren) continue;
        return true;
    }
    return false;
}

fn readsGeneratedSource(tokens: *const ConsumerTokens, call: Call) bool {
    const callee = calleeText(tokens, call);
    var is_read = false;
    for (read_names) |name| {
        if (std.mem.eql(u8, lastSegment(callee), name)) is_read = true;
    }
    if (!is_read) return false;
    for (call.arguments) |argument| {
        var index: usize = argument.start;
        while (index < argument.end) : (index += 1) {
            if (tokens.tags[index] != .string_literal) continue;
            const literal = std.mem.trim(u8, tokenText(tokens, index), "\"");
            for (generated_suffixes) |suffix| {
                if (std.mem.endsWith(u8, literal, suffix)) return true;
            }
        }
    }
    return false;
}

// ── Test verdicts ───────────────────────────────────────────────────────────

fn testFacts(arena: Allocator, tokens: *const ConsumerTokens) ![]const TestFacts {
    var out: std.ArrayList(TestFacts) = .empty;
    for (tokens.tests) |range| {
        var reachable: std.ArrayList(TokenRange) = .empty;
        defer reachable.deinit(arena);
        try appendClosure(arena, tokens, range, &reachable);

        var value_assertions: usize = 0;
        for (tokens.calls) |call| {
            if (call.open < range.start or call.close > range.end) {
                if (!containsCall(reachable.items, call)) continue;
            }
            if (!isAssertionCall(tokens, call)) continue;
            if (classifyAssertion(tokens, call) == .value) value_assertions += 1;
        }
        try out.append(arena, .{
            .name = try testName(arena, tokens, range),
            .line = lineOf(tokens, range.start),
            .value_assertions = value_assertions,
        });
    }
    return out.items;
}

fn containsCall(ranges: []const TokenRange, call: Call) bool {
    for (ranges) |range| {
        if (call.open >= range.start and call.close <= range.end) return true;
    }
    return false;
}

fn isAssertionCall(tokens: *const ConsumerTokens, call: Call) bool {
    return std.mem.startsWith(u8, calleeText(tokens, call), "std.testing.expect");
}

/// The test's own tokens plus the body of every helper it calls, which is what
/// lets a consumer factor its expectations into functions without losing them.
///
/// Naming a helper counts as calling it. That errs toward accepting a fixture,
/// never toward rejecting one.
fn appendClosure(
    arena: Allocator,
    tokens: *const ConsumerTokens,
    start: TokenRange,
    out: *std.ArrayList(TokenRange),
) !void {
    var pending: std.ArrayList(TokenRange) = .empty;
    defer pending.deinit(arena);
    try pending.append(arena, start);
    while (pending.pop()) |range| {
        if (containsRange(out.items, range.start)) continue;
        try out.append(arena, range);
        for (tokens.functions) |function| {
            if (!namesInside(tokens, range, function.name)) continue;
            try pending.append(arena, function.range);
        }
    }
}

fn containsRange(ranges: []const TokenRange, start: u32) bool {
    for (ranges) |range| {
        if (range.start == start) return true;
    }
    return false;
}

fn namesInside(tokens: *const ConsumerTokens, range: TokenRange, name: []const u8) bool {
    var index: usize = range.start;
    while (index < range.end) : (index += 1) {
        if (tokens.tags[index] != .identifier) continue;
        if (!std.mem.eql(u8, tokenText(tokens, index), name)) continue;
        return true;
    }
    return false;
}

fn testName(arena: Allocator, tokens: *const ConsumerTokens, range: TokenRange) ![]const u8 {
    var index: usize = range.start;
    while (index < range.end) : (index += 1) {
        if (tokens.tags[index] != .string_literal) continue;
        return try arena.dupe(u8, std.mem.trim(u8, tokenText(tokens, index), "\""));
    }
    return "unnamed";
}

// ── Brackets and lines ──────────────────────────────────────────────────────

fn matching(
    tags: []const std.zig.Token.Tag,
    open: usize,
    open_tag: std.zig.Token.Tag,
    close_tag: std.zig.Token.Tag,
) usize {
    var depth: usize = 0;
    var index = open;
    while (index < tags.len) : (index += 1) {
        if (tags[index] == open_tag) depth += 1;
        if (tags[index] != close_tag) continue;
        depth -= 1;
        if (depth == 0) return index;
    }
    return tags.len - 1;
}

fn lineOfSource(source: []const u8, offset: u32) usize {
    return std.mem.count(u8, source[0..@min(offset, source.len)], "\n") + 1;
}

fn lineOf(tokens: *const ConsumerTokens, token: u32) usize {
    return lineOfSource(tokens.source, tokens.starts[token]);
}

// ── Files ───────────────────────────────────────────────────────────────────

fn openDirectory(io: std.Io, path: []const u8) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    }
    return std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
}

fn readFile(gpa: Allocator, io: std.Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes));
}

fn isFile(io: std.Io, path: []const u8) !bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return stat.kind == .file;
}

// ── Reporting ───────────────────────────────────────────────────────────────

fn report(
    gpa: Allocator,
    findings: *std.ArrayList(Finding),
    out: *Writer,
    finding: Finding,
    comptime format: []const u8,
    args: anytype,
) !void {
    const owned: Finding = .{
        .rule = finding.rule,
        .fixture = try gpa.dupe(u8, finding.fixture),
        .path = if (finding.path) |path| try gpa.dupe(u8, path) else null,
        .line = finding.line,
    };
    // The finding joins the list only after the line is written, so the
    // `errdefer` can never free memory the list already owns.
    errdefer {
        gpa.free(owned.fixture);
        if (owned.path) |path| gpa.free(path);
    }
    try out.print("{s}: {s}: ", .{ @tagName(finding.rule), finding.fixture });
    if (owned.path) |path| try out.print("{s}:{d}: ", .{ path, owned.line });
    try out.print(format, args);
    try out.writeByte('\n');
    try findings.append(gpa, owned);
}

fn freeFindings(gpa: Allocator, findings: []Finding) void {
    for (findings) |finding| {
        gpa.free(finding.fixture);
        if (finding.path) |path| gpa.free(path);
    }
    gpa.free(findings);
}

fn selects(only: []const []const u8, name: []const u8) bool {
    if (only.len == 0) return true;
    for (only) |wanted| {
        if (std.mem.eql(u8, wanted, name)) return true;
    }
    return false;
}

fn lessThanName(_: void, left: []u8, right: []u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn lessThanText(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn usage(comptime format: []const u8, args: anytype) u8 {
    std.log.err("ownership_fixture_lint: " ++ format, args);
    std.log.err("usage: ownership_fixture_lint [--root DIR] [--consumers DIR] [--only NAME]", .{});
    return 2;
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// One fixture directory to stage.
const FixtureSpec = struct {
    name: []const u8,
    /// The `src/lib.rs` content, or null for a fixture with no Rust source.
    rust: ?[]const u8 = null,
    /// The `Cargo.toml` content, or null to stage no manifest.
    manifest: ?[]const u8 = "[package]\nname = \"fixture\"\nversion = \"0.1.0\"\n",
};

/// One consumer file to stage in the consumer directory.
const ConsumerSpec = struct {
    /// The file name, without a directory.
    file_name: []const u8,
    source: []const u8,
};

/// A staged tree, so a test reads the same absolute layout the linter does.
const Tree = struct {
    tmp: std.testing.TmpDir,
    /// The absolute fixture root.
    root: []u8,
    /// The absolute consumer directory.
    consumers: []u8,

    /// `TmpDir.cleanup` takes a pointer, and this struct travels by value, so
    /// the handle is copied into a mutable local before it is closed. The copy
    /// holds the same open directory handles, so closing it closes them once.
    fn deinit(self: Tree, gpa: Allocator) void {
        var tmp = self.tmp;
        tmp.cleanup();
        gpa.free(self.root);
        gpa.free(self.consumers);
    }
};

fn stageTree(
    gpa: Allocator,
    fixtures: []const FixtureSpec,
    consumers: []const ConsumerSpec,
) !Tree {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try tmp.dir.createDirPath(io, "crates");
    for (fixtures) |fixture| {
        const directory = try std.fmt.allocPrint(gpa, "crates/{s}", .{fixture.name});
        defer gpa.free(directory);
        try tmp.dir.createDirPath(io, directory);
        if (fixture.manifest) |manifest| {
            const manifest_path = try std.fmt.allocPrint(gpa, "{s}/Cargo.toml", .{directory});
            defer gpa.free(manifest_path);
            try tmp.dir.writeFile(io, .{ .sub_path = manifest_path, .data = manifest });
        }
        if (fixture.rust) |rust| {
            const source_path = try std.fmt.allocPrint(gpa, "{s}/src/lib.rs", .{directory});
            defer gpa.free(source_path);
            try tmp.dir.writeFile(io, .{ .sub_path = source_path, .data = rust });
        }
    }
    for (consumers) |consumer| {
        try tmp.dir.writeFile(io, .{ .sub_path = consumer.file_name, .data = consumer.source });
    }
    const absolute = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(absolute);
    return .{
        .tmp = tmp,
        .root = try std.fmt.allocPrint(gpa, "{s}/crates", .{absolute}),
        .consumers = try gpa.dupe(u8, absolute),
    };
}

fn lintTree(tree: Tree, only: []const []const u8) !Summary {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    return run(std.testing.allocator, std.testing.io, .{
        .fixture_root = tree.root,
        .consumer_dir = tree.consumers,
        .only = only,
    }, &out.writer);
}

const good_rust: []const u8 =
    \\//! A fixture crate with one exported function.
    \\
    \\pub struct Token;
    \\
    \\pub fn build(seed: u8) []const u8 {
    \\    var out: [2]u8 = undefined;
    \\    out[0] = 'a' + seed;
    \\    out[1] = out[0];
    \\    return &out;
    \\}
;

const good_consumer: []const u8 =
    \\const std = @import("std");
    \\const translated = @import("translated");
    \\
    \\test "the package builds the value the Rust side builds" {
    \\    const owned = translated.build(1);
    \\    try std.testing.expectEqual(@as(usize, 2), owned.len);
    \\    try std.testing.expectEqualStrings("bb", owned);
    \\}
;

test "a fixture whose consumer asserts a value passes" {
    const gpa = std.testing.allocator;
    const tree = try stageTree(gpa, &.{
        .{ .name = "moved-owner", .rust = good_rust },
    }, &.{
        .{ .file_name = "moved_owner_consumer.zig", .source = good_consumer },
    });
    defer tree.deinit(gpa);

    const summary = try lintTree(tree, &.{});
    defer summary.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), summary.fixtures);
    try std.testing.expectEqual(@as(usize, 1), summary.consumers);
    try std.testing.expect(!summary.hasFindings());
}

test "a fixture whose consumer only proves that nothing threw is rejected" {
    const gpa = std.testing.allocator;
    const tree = try stageTree(gpa, &.{
        .{ .name = "no-throw", .rust = good_rust },
    }, &.{
        .{ .file_name = "no_throw_consumer.zig", .source =
        \\const translated = @import("translated");
        \\
        \\test "moving the owner out does not trap" {
        \\    _ = translated.build(1);
        \\}
        \\
        },
    });
    defer tree.deinit(gpa);

    const summary = try lintTree(tree, &.{});
    defer summary.deinit(gpa);
    try std.testing.expect(summary.reports(.test_without_value_assertion));
    try std.testing.expect(!summary.reports(.consumer_does_not_execute));
    try std.testing.expect(!summary.reports(.consumer_never_names_an_export));
}

test "a consumer whose only assertion is a length is rejected" {
    const gpa = std.testing.allocator;
    const tree = try stageTree(gpa, &.{
        .{ .name = "length-only", .rust = good_rust },
    }, &.{
        .{ .file_name = "length_only_consumer.zig", .source =
        \\const std = @import("std");
        \\const translated = @import("translated");
        \\
        \\test "the package emits two bytes" {
        \\    const owned = translated.build(1);
        \\    try std.testing.expectEqual(@as(usize, 2), owned.len);
        \\}
        \\
        },
    });
    defer tree.deinit(gpa);

    const summary = try lintTree(tree, &.{});
    defer summary.deinit(gpa);
    try std.testing.expect(summary.reports(.consumer_only_asserts_shape));
    try std.testing.expect(summary.reports(.test_without_value_assertion));
    try std.testing.expect(!summary.reports(.consumer_does_not_execute));
}

test "a fixture with no consumer is rejected" {
    const gpa = std.testing.allocator;
    const tree = try stageTree(gpa, &.{
        .{ .name = "lonely", .rust = good_rust },
    }, &.{});
    defer tree.deinit(gpa);

    const summary = try lintTree(tree, &.{});
    defer summary.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), summary.consumers);
    try std.testing.expect(summary.reports(.fixture_without_consumer));
}

test "a consumer that reads the emitted Zig source is rejected" {
    const gpa = std.testing.allocator;
    const tree = try stageTree(gpa, &.{
        .{ .name = "scrapes-source", .rust = good_rust },
    }, &.{
        .{ .file_name = "scrapes_source_consumer.zig", .source =
        \\const std = @import("std");
        \\
        \\test "the emitted package declares the type" {
        \\    const gpa = std.testing.allocator;
        \\    const emitted = try std.Io.Dir.cwd().readFileAlloc(
        \\        std.testing.io,
        \\        "zig-out/e2e-scrapes-source/src/root.zig",
        \\        gpa,
        \\        .limited(4096),
        \\    );
        \\    defer gpa.free(emitted);
        \\    try std.testing.expect(std.mem.indexOf(u8, emitted, "pub const Token") != null);
        \\}
        \\
        },
    });
    defer tree.deinit(gpa);

    const summary = try lintTree(tree, &.{});
    defer summary.deinit(gpa);
    try std.testing.expect(summary.reports(.consumer_reads_translated_source));
    try std.testing.expect(summary.reports(.consumer_asserts_emitted_text));
}

test "a consumer that only asks about types is rejected as not executing" {
    const gpa = std.testing.allocator;
    const tree = try stageTree(gpa, &.{
        .{ .name = "types-only", .rust = good_rust },
    }, &.{
        .{ .file_name = "types_only_consumer.zig", .source =
        \\const std = @import("std");
        \\const translated = @import("translated");
        \\
        \\test "the token type has no fields" {
        \\    try std.testing.expectEqual(@as(usize, 0), @sizeOf(translated.Token));
        \\}
        \\
        },
    });
    defer tree.deinit(gpa);

    const summary = try lintTree(tree, &.{});
    defer summary.deinit(gpa);
    try std.testing.expect(summary.reports(.consumer_does_not_execute));
    try std.testing.expect(!summary.reports(.consumer_never_names_an_export));
}

test "a consumer that calls only the runtime names no export" {
    const gpa = std.testing.allocator;
    const tree = try stageTree(gpa, &.{
        .{ .name = "runtime-only", .rust = good_rust },
    }, &.{
        .{ .file_name = "runtime_only_consumer.zig", .source =
        \\const std = @import("std");
        \\const r2z = @import("r2z");
        \\
        \\test "the runtime formats a number" {
        \\    var buffer: [8]u8 = undefined;
        \\    var writer: std.Io.Writer = .fixed(&buffer);
        \\    try r2z.format.write(&writer, "{}", .{7});
        \\    try std.testing.expectEqualStrings("7", writer.buffered());
        \\}
        \\
        },
    });
    defer tree.deinit(gpa);

    const summary = try lintTree(tree, &.{});
    defer summary.deinit(gpa);
    try std.testing.expect(summary.reports(.consumer_never_names_an_export));
    try std.testing.expect(summary.reports(.consumer_does_not_execute));
    try std.testing.expect(!summary.reports(.test_without_value_assertion));
}

test "an assertion inside a helper the test calls counts for that test" {
    const gpa = std.testing.allocator;
    const tree = try stageTree(gpa, &.{
        .{ .name = "helper-asserts", .rust = good_rust },
    }, &.{
        .{ .file_name = "helper_asserts_consumer.zig", .source =
        \\const std = @import("std");
        \\const translated = @import("translated");
        \\
        \\fn expectBuilt(seed: u8) !void {
        \\    try std.testing.expectEqualStrings("bb", translated.build(seed));
        \\}
        \\
        \\test "the helper asserts for the test that calls it" {
        \\    try expectBuilt(1);
        \\}
        \\
        },
    });
    defer tree.deinit(gpa);

    const summary = try lintTree(tree, &.{});
    defer summary.deinit(gpa);
    try std.testing.expect(!summary.hasFindings());
}

test "a fixture with no public item is rejected" {
    const gpa = std.testing.allocator;
    const tree = try stageTree(gpa, &.{
        .{ .name = "no-exports", .rust = "fn helper() void {}\n" },
    }, &.{
        .{ .file_name = "no_exports_consumer.zig", .source = good_consumer },
    });
    defer tree.deinit(gpa);

    const summary = try lintTree(tree, &.{});
    defer summary.deinit(gpa);
    try std.testing.expect(summary.reports(.fixture_without_public_items));
}

test "a fixture with no Rust source is rejected" {
    const gpa = std.testing.allocator;
    const tree = try stageTree(gpa, &.{
        .{ .name = "no-source", .rust = null },
    }, &.{
        .{ .file_name = "no_source_consumer.zig", .source = good_consumer },
    });
    defer tree.deinit(gpa);

    const summary = try lintTree(tree, &.{});
    defer summary.deinit(gpa);
    try std.testing.expect(summary.reports(.fixture_without_rust_source));
}

test "a consumer that is not valid Zig is rejected" {
    const gpa = std.testing.allocator;
    const tree = try stageTree(gpa, &.{
        .{ .name = "broken", .rust = good_rust },
    }, &.{
        .{ .file_name = "broken_consumer.zig", .source = "test \"unterminated {\n" },
    });
    defer tree.deinit(gpa);

    const summary = try lintTree(tree, &.{});
    defer summary.deinit(gpa);
    try std.testing.expect(summary.reports(.consumer_does_not_parse));
}

test "only the fixtures named are checked" {
    const gpa = std.testing.allocator;
    const tree = try stageTree(gpa, &.{
        .{ .name = "checked", .rust = good_rust },
        .{ .name = "skipped", .rust = good_rust },
    }, &.{
        .{ .file_name = "checked_consumer.zig", .source = good_consumer },
    });
    defer tree.deinit(gpa);

    const named = try lintTree(tree, &.{"checked"});
    defer named.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), named.fixtures);
    try std.testing.expect(!named.hasFindings());

    const all = try lintTree(tree, &.{});
    defer all.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), all.fixtures);
    try std.testing.expect(all.reports(.fixture_without_consumer));
}

test "the Rust scanner reports public items and nothing else" {
    const gpa = std.testing.allocator;
    const source =
        \\//! A doc comment about pub fn ghost.
        \\// pub fn commented_out() {}
        \\/* pub fn block_commented() {} */
        \\pub(crate) fn restricted() {}
        \\const S: &str = "pub fn inside_a_string";
        \\const R: &str = r"pub fn inside_a_raw_string";
        \\
        \\pub struct Token;
        \\pub fn build(seed: u8) u8 {
        \\    seed
        \\}
        \\pub const LIMIT: u8 = 4;
        \\fn private() {}
        \\impl Token {
        \\    pub fn weight(&self) u8 {
        \\        0
        \\    }
        \\}
    ;
    const names = try rustPublicNames(gpa, source);
    defer gpa.free(names);
    try std.testing.expectEqual(@as(usize, 4), names.len);
    try std.testing.expectEqualStrings("Token", names[0]);
    try std.testing.expectEqualStrings("build", names[1]);
    try std.testing.expectEqualStrings("LIMIT", names[2]);
    try std.testing.expectEqualStrings("weight", names[3]);
}

test "reading a consumer reports the facts it decided on" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture: Fixture = .{ .name = "read-facts", .exports = &.{"build"} };
    const analysis = try analyze(arena, good_consumer, fixture);
    const facts = switch (analysis) {
        .invalid => |problem| {
            std.debug.print("unexpected parse problem at line {d}: {s}\n", .{
                problem.line, problem.tag,
            });
            return error.UnexpectedParseProblem;
        },
        .parsed => |parsed| parsed,
    };
    try std.testing.expectEqual(@as(usize, 1), facts.tests.len);
    try std.testing.expectEqualStrings(
        "the package builds the value the Rust side builds",
        facts.tests[0].name,
    );
    try std.testing.expectEqual(@as(usize, 2), facts.assertions);
    try std.testing.expectEqual(@as(usize, 1), facts.value_assertions);
    try std.testing.expectEqual(@as(usize, 1), facts.runtime_touches);
    try std.testing.expect(facts.names_an_export);
    try std.testing.expect(!facts.reads_translated_source);
    try std.testing.expectEqual(@as(usize, 0), facts.text_assertions.len);
    try std.testing.expectEqual(@as(usize, 1), facts.tests[0].value_assertions);
}
