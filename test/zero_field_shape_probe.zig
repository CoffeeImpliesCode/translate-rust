//! Nominal-shape probe for a generated package root module.
//!
//! A generated package makes claims about the types it exports: a zero-field
//! Rust struct becomes a zero-sized Zig type, and two crates that both export
//! `Token` must not share one Zig type. Reading the emitted source settles none
//! of that. This file settles it from the types themselves.
//!
//! It reports, for every public declaration of a generated package root module:
//!
//!   * the Zig type name the translator gave the declaration,
//!   * its size, its alignment, its kind and how many fields it has,
//!   * and, for every two declarations carrying the same Rust name, whether
//!     their Zig types are one type or two distinct ones.
//!
//! The last question is why this file exists. Two `struct {}` literals are two
//! distinct types with the same size and the same field count, so no size claim
//! can tell "one distinct type per Rust declaration" from "one shared empty
//! type". Only nominal identity can.
//!
//! # Two halves
//!
//! `declarationFacts` and `sameRustNameFacts` compute the report from comptime
//! types. The generated program imports this file as `probe` and hands its
//! declarations to them, so every report runs the code this file tests.
//!
//! `render` writes that generated program from a `Spec`, so the report format
//! and the program that produces it cannot drift apart.
//!
//! # Use
//!
//! Describe the staged package, generate the probe program, then compile and run
//! it against that package:
//!
//!     zig run test/zero_field_shape_probe.zig -- -o shape-probe.zig \
//!         --module translated=stage/let-bound-result-match/src/root.zig \
//!         --decl translated:Token:Token \
//!         --decl translated:RustToken:Token
//!     zig run -Mroot=shape-probe.zig --dep probe --dep translated \
//!         -Mprobe=test/zero_field_shape_probe.zig \
//!         -Mtranslated=stage/let-bound-result-match/src/root.zig
//!
//! Each `--decl` is `module:zig_name:rust_name`. The two names differ only when
//! the translator renamed the declaration. Each `--module` is `name=root.zig
//! path`, and only documents the compile command: the probe reads a module
//! under the name it imports, wherever that name resolves. The program writes
//! one JSON object on stdout and nothing else.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// A module the probe reads declarations from.
pub const Module = struct {
    /// The name the generated program imports the module under.
    name: []const u8,
    /// The generated package root that name resolves to. The probe never opens
    /// this path: it documents the `-M<name>=` flag of the compile command.
    root: []const u8,
};

/// One public declaration of a generated package root module.
pub const Decl = struct {
    /// The module the declaration is read from.
    module: []const u8,
    /// The exported Zig identifier.
    zig_name: []const u8,
    /// The Rust name the declaration came from.
    rust_name: []const u8,
};

/// The declarations and modules one probe run reports on.
pub const Spec = struct {
    modules: []const Module,
    decls: []const Decl,

    /// Every pair of declarations that carries the same Rust name, in
    /// declaration order: the first declaration pairs with each later
    /// declaration of the same name, then the second with each later one, and so
    /// on. The caller owns the returned slice and frees it with `freePairs`.
    ///
    /// The `left` and `right` type fields stay undefined. A `Spec` names
    /// declarations; only a compiled program can resolve a name to a type, so
    /// the generated program builds its own pair list and names both sides of
    /// each one with `@TypeOf`.
    pub fn pairs(self: Spec, gpa: Allocator) ![]SameRustName {
        var out: std.ArrayList(SameRustName) = .empty;
        errdefer out.deinit(gpa);
        for (self.decls, 0..) |left, left_index| {
            for (self.decls[left_index + 1 ..]) |right| {
                if (!std.mem.eql(u8, left.rust_name, right.rust_name)) continue;
                try out.append(gpa, .{
                    .rust_name = left.rust_name,
                    .left_label = try label(gpa, left),
                    .right_label = try label(gpa, right),
                    .left = undefined,
                    .right = undefined,
                });
            }
        }
        return out.toOwnedSlice(gpa);
    }
};

/// One public declaration, named the way the generated program sees it.
pub const Declaration = struct {
    /// The module name the declaration is read from.
    module: []const u8,
    /// The exported Zig identifier.
    zig_name: []const u8,
    /// The Rust name the declaration came from.
    rust_name: []const u8,
    /// `@TypeOf(module.zig_name)`, the type the probe reports on.
    declaration_type: type,
};

/// Two declarations that carry the same Rust name.
pub const SameRustName = struct {
    /// The Rust name both declarations carry.
    rust_name: []const u8,
    /// `module.zig_name` of the left declaration.
    left_label: []const u8,
    /// `module.zig_name` of the right declaration.
    right_label: []const u8,
    /// The left declaration's own type.
    left: type,
    /// The right declaration's own type.
    right: type,
};

/// What the probe reports about one declaration.
pub const DeclarationFacts = struct {
    module: []const u8,
    zig_name: []const u8,
    rust_name: []const u8,
    type_name: []const u8,
    size: usize,
    alignment: usize,
    /// The tag name of the declaration's type kind: `struct`, `enum`, `fn`, ...
    kind: []const u8,
    /// The fields the type declares, or null for a type that declares none.
    field_count: ?usize,
    /// True when the type is a container with no fields at all.
    zero_field: bool,
};

/// What the probe reports about one pair of declarations with one Rust name.
pub const SameRustNameFacts = struct {
    rust_name: []const u8,
    left_label: []const u8,
    right_label: []const u8,
    /// True when both sides are the very same Zig type.
    same_type: bool,
    /// True when both sides print the same type name. `@typeName` is fully
    /// qualified, so two declarations from two modules never print one name:
    /// this mirrors `same_type` and exists so a reader of the JSON can see the
    /// printed names the verdict came from.
    same_type_name: bool,
};

/// The whole probe report. `write` emits this exact shape as JSON, so a reader
/// can parse a report back into the type it was computed from.
pub const Report = struct {
    declarations: []const DeclarationFacts,
    same_rust_names: []const SameRustNameFacts,
};

/// The report for `entries`, computed at compile time from the declarations the
/// generated program names.
pub fn declarationFacts(comptime entries: []const Declaration) [entries.len]DeclarationFacts {
    var out: [entries.len]DeclarationFacts = undefined;
    for (entries, 0..) |entry, index| out[index] = declarationFactsOf(entry);
    return out;
}

/// What one declaration reports on its own.
fn declarationFactsOf(entry: Declaration) DeclarationFacts {
    const T = entry.declaration_type;
    const fields = fieldCount(T);
    return .{
        .module = entry.module,
        .zig_name = entry.zig_name,
        .rust_name = entry.rust_name,
        .type_name = @typeName(T),
        .size = @sizeOf(T),
        .alignment = @alignOf(T),
        .kind = typeKindName(T),
        .field_count = fields,
        .zero_field = fields == 0,
    };
}

/// The report for `pairs`, computed at compile time.
pub fn sameRustNameFacts(comptime pairs: []const SameRustName) [pairs.len]SameRustNameFacts {
    var out: [pairs.len]SameRustNameFacts = undefined;
    for (pairs, 0..) |pair, index| out[index] = .{
        .rust_name = pair.rust_name,
        .left_label = pair.left_label,
        .right_label = pair.right_label,
        .same_type = pair.left == pair.right,
        .same_type_name = std.mem.eql(u8, @typeName(pair.left), @typeName(pair.right)),
    };
    return out;
}

/// Write `report` as one JSON object followed by a newline.
pub fn write(writer: *Writer, report: Report) !void {
    try writer.writeAll("{\"declarations\":[");
    for (report.declarations, 0..) |facts, index| {
        if (index != 0) try writer.writeByte(',');
        try writeDeclarationFacts(writer, facts);
    }
    try writer.writeAll("],\"same_rust_names\":[");
    for (report.same_rust_names, 0..) |facts, index| {
        if (index != 0) try writer.writeByte(',');
        try writeSameRustNameFacts(writer, facts);
    }
    try writer.writeAll("]}\n");
}

/// The dotted path inside every `@TypeOf(...)` call in `tree`, in source order.
///
/// This is how a test reads a generated probe program back as structure: it
/// finds the `@TypeOf` calls in the token stream and returns the declaration
/// each one names. An argument that is not a plain dotted path reads back as an
/// empty slice. The caller owns the returned slices.
pub fn typeOfPaths(gpa: Allocator, tree: *const std.zig.Ast) ![][]const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| gpa.free(path);
        paths.deinit(gpa);
    }

    const tags = tree.tokens.items(.tag);
    var token_index: usize = 0;
    while (token_index < tags.len) : (token_index += 1) {
        if (tags[token_index] != .builtin) continue;
        const slice = tree.tokenSlice(@intCast(token_index));
        if (!std.mem.eql(u8, slice, "@TypeOf")) continue;
        try paths.append(gpa, try typeOfArgument(gpa, tree, token_index + 1));
    }
    return paths.toOwnedSlice(gpa);
}

/// Write the probe program for `spec`: a file that reports every declaration in
/// `spec` and every same-Rust-name pair among them.
///
/// The program is a compile-and-run file, not a test. It carries no assertion,
/// so it states only what the types are and leaves the claim to whoever reads
/// the report.
pub fn render(gpa: Allocator, writer: *Writer, spec: Spec) !void {
    const probe_module = "test/zero_field_shape_probe.zig";
    // Every name the generated program carries lands inside a Zig identifier or
    // a Zig string literal, so a quote or a backslash in any of them would
    // emit source that does not parse.
    for (spec.modules) |module| {
        if (!isIdentifier(module.name)) return error.InvalidName;
        if (!isPlainText(module.root)) return error.InvalidName;
    }
    for (spec.decls) |decl| {
        if (!isIdentifier(decl.zig_name)) return error.InvalidName;
        if (!isPlainText(decl.rust_name)) return error.InvalidName;
        if (moduleIndex(spec, decl.module) == null) return error.UndeclaredModule;
    }
    const pairs = try spec.pairs(gpa);
    defer freePairs(gpa, pairs);

    try writer.writeAll("//! Generated by " ++ probe_module ++ ". Do not edit it.\n");
    try writer.writeAll("//!\n");
    try writer.writeAll("//! Compile and run it with:\n");
    try writer.writeAll("//!     zig run -Mroot=shape-probe.zig --dep probe");
    for (spec.modules) |module| try writer.print(" --dep {s}", .{module.name});
    try writer.writeAll(" \\\n//!         -Mprobe=" ++ probe_module);
    for (spec.modules) |module| try writer.print(" -M{s}={s}", .{ module.name, module.root });
    try writer.writeAll("\n\n");
    try writer.writeAll("const std = @import(\"std\");\n");
    try writer.writeAll("const probe = @import(\"probe\");\n");
    for (spec.modules) |module| {
        try writer.print("const {s} = @import(\"{s}\");\n", .{ module.name, module.name });
    }

    try writer.writeAll("\n/// The public declarations this probe reports on.\n");
    try writer.writeAll("const declarations: []const probe.Declaration = &.{\n");
    for (spec.decls) |decl| {
        try writer.writeAll("    .{\n");
        try writer.print("        .module = \"{s}\",\n", .{decl.module});
        try writer.print("        .zig_name = \"{s}\",\n", .{decl.zig_name});
        try writer.print("        .rust_name = \"{s}\",\n", .{decl.rust_name});
        try writer.print("        .declaration_type = @TypeOf({s}.{s}),\n", .{
            decl.module, decl.zig_name,
        });
        try writer.writeAll("    },\n");
    }
    try writer.writeAll("};\n");

    try writer.writeAll("\n/// The declaration pairs that carry the same Rust name.\n");
    try writer.writeAll("const same_rust_name: []const probe.SameRustName = &.{\n");
    for (pairs) |pair| {
        try writer.writeAll("    .{\n");
        try writer.print("        .rust_name = \"{s}\",\n", .{pair.rust_name});
        try writer.print("        .left_label = \"{s}\",\n", .{pair.left_label});
        try writer.print("        .right_label = \"{s}\",\n", .{pair.right_label});
        try writer.print("        .left = @TypeOf({s}),\n", .{pair.left_label});
        try writer.print("        .right = @TypeOf({s}),\n", .{pair.right_label});
        try writer.writeAll("    },\n");
    }
    try writer.writeAll("};\n");

    try writer.writeAll(
        \\pub fn main(init: std.process.Init) !void {
        \\    var out: std.Io.Writer.Allocating = .init(init.gpa);
        \\    defer out.deinit();
        \\    try probe.write(&out.writer, .{
        \\        .declarations = probe.declarationFacts(declarations),
        \\        .same_rust_names = probe.sameRustNameFacts(same_rust_name),
        \\    });
        \\    try std.Io.File.stdout().writeStreamingAll(init.io, out.written());
        \\}
        \\
    );
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var modules: std.ArrayList(Module) = .empty;
    var decls: std.ArrayList(Decl) = .empty;
    var output_path: ?[]const u8 = null;

    const args = try init.minimal.args.toSlice(arena);
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg: []const u8 = args[index];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            index += 1;
            if (index == args.len) return fail("-o needs a path", .{});
            output_path = args[index];
        } else if (std.mem.eql(u8, arg, "--module")) {
            index += 1;
            if (index == args.len) return fail("--module needs name=root.zig", .{});
            const module = moduleArgument(arena, args[index]) catch |err| switch (err) {
                error.OutOfMemory => |out_of_memory| return out_of_memory,
                error.InvalidArgument => {
                    return fail("--module argument '{s}' is not name=root.zig", .{args[index]});
                },
            };
            try modules.append(arena, module);
        } else if (std.mem.eql(u8, arg, "--decl")) {
            index += 1;
            if (index == args.len) return fail("--decl needs module:zig_name:rust_name", .{});
            const decl = declArgument(arena, args[index]) catch |err| switch (err) {
                error.OutOfMemory => |out_of_memory| return out_of_memory,
                error.InvalidArgument => {
                    return fail("--decl argument '{s}' is not module:zig_name:rust_name", .{
                        args[index],
                    });
                },
            };
            try decls.append(arena, decl);
        } else {
            return fail("unknown argument: {s}", .{arg});
        }
    }

    const spec: Spec = .{ .modules = modules.items, .decls = decls.items };
    if (spec.decls.len == 0) return fail("no --decl declaration was given", .{});
    if (spec.modules.len == 0) return fail("no --module was given", .{});
    for (spec.decls) |decl| {
        if (moduleIndex(spec, decl.module) == null) {
            return fail("--decl names module '{s}', which no --module declares", .{decl.module});
        }
    }

    var out: std.Io.Writer.Allocating = .init(init.gpa);
    defer out.deinit();
    try render(arena, &out.writer, spec);

    const path = output_path orelse "-";
    if (std.mem.eql(u8, path, "-")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, out.written());
        return;
    }
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = out.written() });
}

// ── Report writing ──────────────────────────────────────────────────────────

fn writeDeclarationFacts(writer: *Writer, facts: DeclarationFacts) !void {
    try writer.writeAll("{\"module\":");
    try writeJsonString(writer, facts.module);
    try writer.writeAll(",\"zig_name\":");
    try writeJsonString(writer, facts.zig_name);
    try writer.writeAll(",\"rust_name\":");
    try writeJsonString(writer, facts.rust_name);
    try writer.writeAll(",\"type_name\":");
    try writeJsonString(writer, facts.type_name);
    try writer.writeAll(",\"kind\":");
    try writeJsonString(writer, facts.kind);
    try writer.writeAll(",\"size\":");
    try writer.print("{d}", .{facts.size});
    try writer.writeAll(",\"alignment\":");
    try writer.print("{d}", .{facts.alignment});
    try writer.writeAll(",\"field_count\":");
    if (facts.field_count) |count| {
        try writer.print("{d}", .{count});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"zero_field\":");
    try writer.writeAll(if (facts.zero_field) "true" else "false");
    try writer.writeByte('}');
}

fn writeSameRustNameFacts(writer: *Writer, facts: SameRustNameFacts) !void {
    try writer.writeAll("{\"rust_name\":");
    try writeJsonString(writer, facts.rust_name);
    try writer.writeAll(",\"left_label\":");
    try writeJsonString(writer, facts.left_label);
    try writer.writeAll(",\"right_label\":");
    try writeJsonString(writer, facts.right_label);
    try writer.writeAll(",\"same_type\":");
    try writer.writeAll(if (facts.same_type) "true" else "false");
    try writer.writeAll(",\"same_type_name\":");
    try writer.writeAll(if (facts.same_type_name) "true" else "false");
    try writer.writeByte('}');
}

/// A Zig type name can carry quotes and braces, so every string is escaped the
/// way JSON requires rather than copied through.
fn writeJsonString(writer: *Writer, text: []const u8) !void {
    const digits = "0123456789abcdef";
    try writer.writeByte('"');
    for (text) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
            try writer.writeAll("\\u00");
            try writer.writeByte(digits[byte >> 4]);
            try writer.writeByte(digits[byte & 0x0f]);
        },
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

// ── Type facts ──────────────────────────────────────────────────────────────

/// The fields the type declares, or null when the type is not a container that
/// declares fields. An opaque type declares functions and variables rather than
/// fields, so it counts as zero.
fn fieldCount(comptime T: type) ?usize {
    return switch (@typeInfo(T)) {
        .@"struct" => |structure| structure.field_names.len,
        .@"union" => |union_type| union_type.field_names.len,
        .@"enum" => |enum_type| enum_type.field_names.len,
        .@"opaque" => 0,
        else => null,
    };
}

/// The tag name of the declaration's type kind.
fn typeKindName(comptime T: type) []const u8 {
    const tag = comptime std.meta.activeTag(@typeInfo(T));
    return @tagName(tag);
}

// ── Token reading ───────────────────────────────────────────────────────────

fn typeOfArgument(gpa: Allocator, tree: *const std.zig.Ast, open_index: usize) ![]const u8 {
    const tags = tree.tokens.items(.tag);
    if (open_index >= tags.len or tags[open_index] != .l_paren) return gpa.dupe(u8, "");
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(gpa);
    var depth: usize = 0;
    var token_index = open_index;
    while (token_index < tags.len) : (token_index += 1) {
        switch (tags[token_index]) {
            .l_paren => depth += 1,
            .r_paren => {
                depth -= 1;
                if (depth == 0) break;
            },
            .period => {},
            .identifier, .builtin => {
                try segments.append(gpa, tree.tokenSlice(@intCast(token_index)));
            },
            else => return gpa.dupe(u8, ""),
        }
    }
    return std.mem.join(gpa, ".", segments.items);
}

// ── Command line ────────────────────────────────────────────────────────────

fn moduleArgument(gpa: Allocator, text: []const u8) !Module {
    const separator = std.mem.indexOfScalar(u8, text, '=') orelse {
        return error.InvalidArgument;
    };
    if (separator == 0 or separator + 1 == text.len) return error.InvalidArgument;
    const name = text[0..separator];
    if (!isIdentifier(name)) return error.InvalidArgument;
    return .{ .name = name, .root = try gpa.dupe(u8, text[separator + 1 ..]) };
}

fn declArgument(gpa: Allocator, text: []const u8) !Decl {
    var parts: [3][]const u8 = undefined;
    var count: usize = 0;
    var rest = text;
    while (count < parts.len) {
        const next = std.mem.indexOfScalar(u8, rest, ':');
        if (count == parts.len - 1) {
            parts[count] = rest;
            count += 1;
            break;
        }
        parts[count] = if (next) |cut| rest[0..cut] else rest;
        count += 1;
        if (next == null) break;
        rest = rest[next.? + 1 ..];
    }
    if (count != 3) return error.InvalidArgument;
    if (!isIdentifier(parts[1])) return error.InvalidArgument;
    if (parts[2].len == 0) return error.InvalidArgument;
    return .{
        .module = parts[0],
        .zig_name = try gpa.dupe(u8, parts[1]),
        .rust_name = try gpa.dupe(u8, parts[2]),
    };
}

fn fail(comptime format: []const u8, args: anytype) error{InvalidArgument} {
    std.log.err("zero_field_shape_probe: " ++ format, args);
    return error.InvalidArgument;
}

// ── Shared helpers ──────────────────────────────────────────────────────────

fn moduleIndex(spec: Spec, name: []const u8) ?usize {
    for (spec.modules, 0..) |module, index| {
        if (std.mem.eql(u8, module.name, name)) return index;
    }
    return null;
}

fn label(gpa: Allocator, decl: Decl) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}.{s}", .{ decl.module, decl.zig_name });
}

/// Free a slice `Spec.pairs` returned, labels included.
pub fn freePairs(gpa: Allocator, pairs: []SameRustName) void {
    for (pairs) |pair| {
        gpa.free(pair.left_label);
        gpa.free(pair.right_label);
    }
    gpa.free(pairs);
}

fn isIdentifier(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!std.ascii.isAlphabetic(text[0]) and text[0] != '_') return false;
    for (text[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

/// True when `text` can sit inside a generated Zig string literal unescaped.
fn isPlainText(text: []const u8) bool {
    if (text.len == 0) return false;
    return std.mem.indexOfAny(u8, text, "\"\\\n\r\t") == null;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "a zero-field struct reports its type name, its size and no fields" {
    const Zero = struct {};
    const One = struct { tag: u8 };
    const entries: []const Declaration = &.{
        .{
            .module = "translated",
            .zig_name = "Zero",
            .rust_name = "Zero",
            .declaration_type = Zero,
        },
        .{
            .module = "translated",
            .zig_name = "One",
            .rust_name = "One",
            .declaration_type = One,
        },
    };
    const facts = declarationFacts(entries);
    try std.testing.expectEqual(@as(usize, 2), facts.len);
    // `@typeName` is fully qualified, so a local declaration names its
    // enclosing scope: only the last segment is predictable.
    try std.testing.expect(std.mem.endsWith(u8, facts[0].type_name, ".Zero"));
    try std.testing.expectEqualStrings("struct", facts[0].kind);
    try std.testing.expectEqual(@as(usize, 0), facts[0].size);
    try std.testing.expectEqual(@as(usize, 0), facts[0].field_count.?);
    try std.testing.expect(facts[0].zero_field);
    try std.testing.expectEqual(@as(usize, 1), facts[1].size);
    try std.testing.expectEqual(@as(usize, 1), facts[1].field_count.?);
    try std.testing.expect(!facts[1].zero_field);
}

test "a type with no field container reports no field count" {
    const entries: []const Declaration = &.{
        .{
            .module = "translated",
            .zig_name = "build",
            .rust_name = "build",
            .declaration_type = fn () void,
        },
    };
    const facts = declarationFacts(entries);
    try std.testing.expectEqual(@as(?usize, null), facts[0].field_count);
    try std.testing.expect(!facts[0].zero_field);
}

test "a renamed declaration keeps both names" {
    const entries: []const Declaration = &.{
        .{
            .module = "translated",
            .zig_name = "RustToken",
            .rust_name = "Token",
            .declaration_type = struct {},
        },
    };
    const facts = declarationFacts(entries);
    try std.testing.expectEqualStrings("RustToken", facts[0].zig_name);
    try std.testing.expectEqualStrings("Token", facts[0].rust_name);
}

test "two empty structs with one Rust name are two distinct Zig types" {
    const Left = struct {
        pub const Token = struct {};
    };
    const Right = struct {
        pub const Token = struct {};
    };
    const pairs: []const SameRustName = &.{
        .{
            .rust_name = "Token",
            .left_label = "left.Token",
            .right_label = "right.Token",
            .left = Left.Token,
            .right = Right.Token,
        },
    };
    const facts = sameRustNameFacts(pairs);
    // The load-bearing claim: one size and one field count cannot make this
    // distinction, so the probe has to ask the types themselves.
    try std.testing.expect(!facts[0].same_type);
    try std.testing.expectEqual(
        std.mem.eql(u8, @typeName(Left.Token), @typeName(Right.Token)),
        facts[0].same_type_name,
    );
}

test "one type against itself is the same type" {
    const Left = struct {
        pub const Token = struct {};
    };
    const pairs: []const SameRustName = &.{
        .{
            .rust_name = "Token",
            .left_label = "left.Token",
            .right_label = "left.Token",
            .left = Left.Token,
            .right = Left.Token,
        },
    };
    const facts = sameRustNameFacts(pairs);
    try std.testing.expect(facts[0].same_type);
    try std.testing.expect(facts[0].same_type_name);
}

test "only declarations that share a Rust name are paired" {
    const gpa = std.testing.allocator;
    const spec: Spec = .{
        .modules = &.{
            .{ .name = "translated", .root = "stage/one/src/root.zig" },
            .{ .name = "other", .root = "stage/two/src/root.zig" },
        },
        .decls = &.{
            .{ .module = "translated", .zig_name = "Token", .rust_name = "Token" },
            .{ .module = "other", .zig_name = "Token", .rust_name = "Token" },
            .{ .module = "translated", .zig_name = "RustToken", .rust_name = "Token" },
            .{ .module = "translated", .zig_name = "Hash", .rust_name = "Hash" },
        },
    };
    const pairs = try spec.pairs(gpa);
    defer freePairs(gpa, pairs);
    try std.testing.expectEqual(@as(usize, 3), pairs.len);
    for (pairs) |pair| try std.testing.expectEqualStrings("Token", pair.rust_name);
    try std.testing.expectEqualStrings("translated.Token", pairs[0].left_label);
    try std.testing.expectEqualStrings("other.Token", pairs[0].right_label);
    try std.testing.expectEqualStrings("translated.Token", pairs[1].left_label);
    try std.testing.expectEqualStrings("translated.RustToken", pairs[1].right_label);
    try std.testing.expectEqualStrings("other.Token", pairs[2].left_label);
    try std.testing.expectEqualStrings("translated.RustToken", pairs[2].right_label);
}

test "the generated program names every declaration and every pair" {
    const gpa = std.testing.allocator;
    const spec: Spec = .{
        .modules = &.{
            .{ .name = "translated", .root = "stage/one/src/root.zig" },
            .{ .name = "other", .root = "stage/two/src/root.zig" },
        },
        .decls = &.{
            .{ .module = "translated", .zig_name = "Token", .rust_name = "Token" },
            .{ .module = "other", .zig_name = "Token", .rust_name = "Token" },
            .{ .module = "translated", .zig_name = "RustToken", .rust_name = "Token" },
            .{ .module = "translated", .zig_name = "Hash", .rust_name = "Hash" },
        },
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try render(gpa, &out.writer, spec);
    const source = try gpa.dupeZ(u8, out.written());
    defer gpa.free(source);

    var tree = try std.zig.Ast.parse(gpa, source, .zig);
    defer tree.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);

    // One `@TypeOf` per declaration, then two per same-name pair.
    const paths = try typeOfPaths(gpa, &tree);
    defer {
        for (paths) |path| gpa.free(path);
        gpa.free(paths);
    }
    const expected = [_][]const u8{
        "translated.Token",
        "other.Token",
        "translated.RustToken",
        "translated.Hash",
        "translated.Token",
        "other.Token",
        "translated.Token",
        "translated.RustToken",
        "other.Token",
        "translated.RustToken",
    };
    try std.testing.expectEqual(expected.len, paths.len);
    for (expected, paths) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "a module name that is not an identifier is refused" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.testing.expectError(error.InvalidName, render(gpa, &out.writer, .{
        .modules = &.{.{ .name = "not a name", .root = "stage/one/src/root.zig" }},
        .decls = &.{.{ .module = "not a name", .zig_name = "Token", .rust_name = "Token" }},
    }));
}

test "a declaration from an undeclared module is refused" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.testing.expectError(error.UndeclaredModule, render(gpa, &out.writer, .{
        .modules = &.{.{ .name = "translated", .root = "stage/one/src/root.zig" }},
        .decls = &.{.{ .module = "elsewhere", .zig_name = "Token", .rust_name = "Token" }},
    }));
}

test "a decl argument splits into module, Zig name and Rust name" {
    const gpa = std.testing.allocator;
    const decl = try declArgument(gpa, "translated:RustToken:Token");
    defer {
        gpa.free(decl.zig_name);
        gpa.free(decl.rust_name);
    }
    try std.testing.expectEqualStrings("translated", decl.module);
    try std.testing.expectEqualStrings("RustToken", decl.zig_name);
    try std.testing.expectEqualStrings("Token", decl.rust_name);
    try std.testing.expectError(error.InvalidArgument, declArgument(gpa, "translated:Token"));
    try std.testing.expectError(error.InvalidArgument, declArgument(gpa, "translated:1Token:x"));
}

test "a module argument splits into a name and a path" {
    const gpa = std.testing.allocator;
    const module = try moduleArgument(gpa, "translated=stage/one/src/root.zig");
    defer gpa.free(module.root);
    try std.testing.expectEqualStrings("translated", module.name);
    try std.testing.expectEqualStrings("stage/one/src/root.zig", module.root);
    try std.testing.expectError(error.InvalidArgument, moduleArgument(gpa, "translated"));
    try std.testing.expectError(error.InvalidArgument, moduleArgument(gpa, "1translated=x"));
}

test "the report reads back as the data it was computed from" {
    const gpa = std.testing.allocator;
    const Left = struct {
        pub const Token = struct { value: u8 };
    };
    const Right = struct {
        pub const Token = struct {};
    };
    const entries: []const Declaration = &.{
        .{
            .module = "left",
            .zig_name = "Token",
            .rust_name = "Token",
            .declaration_type = Left.Token,
        },
        .{
            .module = "left",
            .zig_name = "build",
            .rust_name = "build",
            .declaration_type = fn () void,
        },
    };
    const same_name: []const SameRustName = &.{
        .{
            .rust_name = "Token",
            .left_label = "left.Token",
            .right_label = "right.Token",
            .left = Left.Token,
            .right = Right.Token,
        },
    };
    const report: Report = .{
        .declarations = declarationFacts(entries),
        .same_rust_names = sameRustNameFacts(same_name),
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(&out.writer, report);

    const parsed = try std.json.parseFromSlice(Report, gpa, out.written(), .{});
    defer parsed.deinit();

    try std.testing.expectEqual(report.declarations.len, parsed.value.declarations.len);
    for (report.declarations, parsed.value.declarations) |want, got| {
        try std.testing.expectEqualStrings(want.module, got.module);
        try std.testing.expectEqualStrings(want.zig_name, got.zig_name);
        try std.testing.expectEqualStrings(want.rust_name, got.rust_name);
        try std.testing.expectEqualStrings(want.type_name, got.type_name);
        try std.testing.expectEqualStrings(want.kind, got.kind);
        try std.testing.expectEqual(want.size, got.size);
        try std.testing.expectEqual(want.alignment, got.alignment);
        try std.testing.expectEqual(want.field_count, got.field_count);
        try std.testing.expectEqual(want.zero_field, got.zero_field);
    }
    try std.testing.expectEqual(report.same_rust_names.len, parsed.value.same_rust_names.len);
    for (report.same_rust_names, parsed.value.same_rust_names) |want, got| {
        try std.testing.expectEqualStrings(want.rust_name, got.rust_name);
        try std.testing.expectEqualStrings(want.left_label, got.left_label);
        try std.testing.expectEqualStrings(want.right_label, got.right_label);
        try std.testing.expectEqual(want.same_type, got.same_type);
        try std.testing.expectEqual(want.same_type_name, got.same_type_name);
    }
}
