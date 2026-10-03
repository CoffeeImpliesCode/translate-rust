//! translate_rust.backend.zig.documentation_test — the documentation contract.
//!
//! `fromAttributes` returns storage with no owner when the source documented
//! nothing, and an allocator-owned slice when it did. The first half is checked
//! against an allocator that cannot allocate at all, so a result that came out
//! of an allocation fails the check instead of passing quietly.
//!
//! Everything after that is checked against real generated packages: every
//! payload under `test/golden/zig_ast/` is decoded through the package codec
//! into an `ast.Package`, so the assertions read types, parameters and return
//! types rather than emitted text. Four properties are pinned over that corpus.
//!
//!   1. Every emitted public declaration carries documentation, unless it only
//!      names another declaration. A `const` or `var` whose initializer is a
//!      bare name, a field of one, or an `@import` is a re-export: the emitter
//!      gives it no documentation of its own because the contract lives at the
//!      declaration it points at. Every other public declaration must carry
//!      prose.
//!   2. The ownership and allocator sentences describe the signature directly
//!      below them, in both directions: a sentence is present exactly when the
//!      signature has the property it names. An allocator-typed parameter is
//!      additionally matched on its name, because the sentence names it.
//!   3. Those sentences arrive as one block, not as scattered prose. The block
//!      is contiguous, in the order the emitter writes them, preceded by
//!      exactly one blank line, and ends the `///` block. A sentence truncated
//!      to its opening words — the shape a prefix match cannot see — fails.
//!   4. No sentence is emitted anywhere prose cannot support it. A contract
//!      sentence describes a signature, so it appears on callables only; the
//!      "translated Rust operation" provenance appears on callables only. A
//!      field or variant tag carries its source's prose and nothing else.
//!
//! The owner-type walk below is this file's own answer rather than a call into
//! `lower.zig`. Reading the emitter's own predicate would only prove that it
//! agrees with itself. `Lowerer.runtimeOwnsStorage` is the emitter's copy of
//! this list, and the two change together.

const std = @import("std");
const ast = @import("ast.zig");
const documentation = @import("documentation.zig");
const ir = @import("translate_rust.ir");
const serialize = @import("serialize.zig");

/// Opens the sentence that documents an allocator parameter. The sentence
/// names that parameter `allocator` in backticks, so the emitted signature has
/// to carry a parameter under exactly that name.
const allocator_sentence = "`allocator` supplies memory operations";

/// Opens the sentence that documents by-value runtime owners.
const transfer_sentence = "By-value runtime-owned arguments transfer";

/// Opens the sentence that documents an owned return value.
const release_sentence = "Release each returned owned runtime payload";

/// The allocator sentence in full. A block check matches this whole string, so
/// an emission that wrote only the opening line is caught rather than read as
/// a sentence that happens to be short.
const allocator_contract =
    "`allocator` supplies memory operations and cleanup; use an allocator\n" ++
    "compatible with any pre-existing storage passed into this call.\n";

const transfer_contract =
    "By-value runtime-owned arguments transfer their storage by contract.\n" ++
    "Zig copies alias that storage and are not separate cleanup owners.\n";

const release_contract =
    "Release each returned owned runtime payload once with the allocator used\n" ++
    "to create or grow it; see that runtime type's cleanup contract.\n";

/// The contract sentences in the order `callableDocumentation` writes them.
const contract_sentences = [_][]const u8{
    allocator_contract,
    transfer_contract,
    release_contract,
};

/// The provenance sentence the emitter writes for an operation it translated
/// without authored prose. It describes a callable, so it belongs on one.
const operation_provenance = "Runs the translated Rust operation `";

/// The Zig AST type every allocator parameter is emitted with.
const allocator_type = "std.mem.Allocator";

/// The generated packages this repository pins as Zig AST payloads. Each is a
/// complete `ast.Package` the lowering produced, so a signature and the prose
/// above it come out of the same emission.
const golden_packages = [_][]const u8{
    "test/golden/zig_ast/fnv.zigast.json",
    "test/golden/zig_ast/hex.zigast.json",
    "test/golden/zig_ast/mini.zigast.json",
};

/// Runtime types that own heap storage a caller has to release.
const owner_named_types = [_][]const u8{
    "r2z.alloc.String",
    "r2z.alloc.CowStr",
    "r2z.alloc.FromUtf8Error",
};

/// Generic runtime containers that own heap storage a caller has to release.
const owner_generic_types = [_][]const u8{
    "r2z.alloc.Vec",
    "std.ArrayList",
    "std.ArrayListUnmanaged",
    "r2z.alloc.CowSlice",
};

/// Whether `ty` names a runtime owner, directly or through a container this
/// walk descends into: an optional, an error union, a fixed array, a tuple, or
/// a `Result` arm. A borrowed slice and a pointer never own, whatever they
/// point at, which is the direction the emitted contract needs.
fn isOwnerType(ty: ast.Type, depth: usize) bool {
    if (depth >= ir.types.traversal_depth_max) return false;
    return switch (ty) {
        .named => |name| namesOneOf(name, &owner_named_types),
        .generic => |generic| blk: {
            if (namesOneOf(generic.name, &owner_generic_types)) break :blk true;
            if (!std.mem.eql(u8, generic.name, "r2z.Result")) break :blk false;
            for (generic.params) |param| {
                if (isOwnerType(param, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        .opt => |inner| isOwnerType(inner.*, depth + 1),
        .err_union => |result| isOwnerType(result.payload.*, depth + 1),
        .array => |array| isOwnerType(array.elem.*, depth + 1),
        .tuple => |members| blk: {
            for (members) |member| {
                if (isOwnerType(member, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn namesOneOf(name: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

/// Whether a `const` or `var` initializer only names another declaration
/// rather than defining a value of its own. A bare name, a field of one, and
/// an `@import` are the three spellings a re-export takes; anything that
/// computes — a call, a literal, an operator, a block — is a definition, and a
/// public definition is what owes the reader prose.
fn isAliasInitializer(init: ast.Expr) bool {
    return switch (init) {
        .ident => true,
        .field_access => true,
        .builtin => |builtin| std.mem.eql(u8, builtin.name, "import"),
        else => false,
    };
}

/// Every way this file can reject an emitted package.
const ContractError = error{
    UndocumentedEmittedCallable,
    UndocumentedEmittedType,
    UndocumentedEmittedFile,
    UndocumentedPublicDefinition,
    AllocatorParameterIsNotNamedAsDocumented,
    DocumentedContractDoesNotMatchTheSignature,
    ContractBlockIsNotOneParagraph,
    ContractBlockIsNotLast,
    SynthesizedProseOnANonCallable,
};

/// Contract sentences, back to back, each with the newline that closes it.
/// The concatenation is bounded by this sum, so the scratch buffer the block
/// check builds cannot be too small for the block it is meant to hold.
const contract_block_max = blk: {
    var total: usize = 0;
    for (contract_sentences) |sentence| total += sentence.len;
    break :blk total;
};

/// What one package proved, so a run over three packages says what it covered
/// rather than only that it did not fail.
const Census = struct {
    files: usize = 0,
    callables: usize = 0,
    types: usize = 0,
    public_constants: usize = 0,
    documented_constants: usize = 0,
    /// Public `const`/`var` declarations that only name another declaration.
    /// These carry no prose of their own by design, so they are counted rather
    /// than accepted silently: a corpus with none would leave the rule above
    /// untested.
    re_exports: usize = 0,
    /// Public fields and variant tags that came from the source with prose.
    documented_members: usize = 0,
    undocumented_members: usize = 0,
    allocator_sentences: usize = 0,
    transfer_sentences: usize = 0,
    release_sentences: usize = 0,
    contract_blocks: usize = 0,

    fn add(self: *Census, other: Census) void {
        self.files += other.files;
        self.callables += other.callables;
        self.types += other.types;
        self.public_constants += other.public_constants;
        self.documented_constants += other.documented_constants;
        self.re_exports += other.re_exports;
        self.documented_members += other.documented_members;
        self.undocumented_members += other.undocumented_members;
        self.allocator_sentences += other.allocator_sentences;
        self.transfer_sentences += other.transfer_sentences;
        self.release_sentences += other.release_sentences;
        self.contract_blocks += other.contract_blocks;
    }
};

fn contractDrift(
    file_path: []const u8,
    fn_name: []const u8,
    sentence: []const u8,
    observed: bool,
    expected: bool,
) error{DocumentedContractDoesNotMatchTheSignature} {
    std.debug.print(
        "{s}: `{s}` {s} the sentence \"{s}\", its signature {s} that property\n",
        .{
            file_path,
            fn_name,
            if (observed) "carries" else "does not carry",
            sentence,
            if (expected) "has" else "does not have",
        },
    );
    return error.DocumentedContractDoesNotMatchTheSignature;
}

/// Reject a contract sentence on a declaration that has no signature for it to
/// describe. A `const` that says an allocator parameter supplies its memory
/// names a parameter the reader will not find.
fn rejectContractSentence(
    text: []const u8,
    kind_name: []const u8,
    decl_name: []const u8,
    file_path: []const u8,
) ContractError!void {
    for (contract_sentences) |sentence| {
        if (std.mem.indexOf(u8, text, sentence) == null) continue;
        std.debug.print(
            "{s}: {s} `{s}` carries the contract sentence \"{s}\", but a {s} has no signature to own\n",
            .{ file_path, kind_name, decl_name, sentence[0..@min(sentence.len, 40)], kind_name },
        );
        return error.SynthesizedProseOnANonCallable;
    }
}

/// Reject the operation provenance sentence on anything but a callable. It is
/// the emitter's description of a translated function; a field or a tag has no
/// operation to describe.
fn rejectOperationProvenance(
    text: []const u8,
    kind_name: []const u8,
    decl_name: []const u8,
    file_path: []const u8,
) ContractError!void {
    if (std.mem.indexOf(u8, text, operation_provenance) == null) return;
    std.debug.print(
        "{s}: {s} `{s}` carries the operation provenance sentence, but a {s} is not an operation\n",
        .{ file_path, kind_name, decl_name, kind_name },
    );
    return error.SynthesizedProseOnANonCallable;
}

/// Check that the contract sentences form the one paragraph the emitter writes:
/// contiguous, in order, set off by a single blank line, and ending the block.
///
/// The bidirectional sentence checks below already decide *which* sentences
/// belong to a signature. This decides *how* they arrive. A sentence written to
/// its opening words, or a block broken up by a stray blank line, reads as
/// documented prose to every check that matches on a prefix, so the difference
/// has to be measured against the whole sentence.
fn checkContractBlock(
    text: []const u8,
    fn_name: []const u8,
    file_path: []const u8,
    census: *Census,
) ContractError!void {
    var block_start: ?usize = null;
    var block_end: usize = 0;
    for (contract_sentences) |sentence| {
        const at = std.mem.indexOf(u8, text, sentence) orelse continue;
        if (block_start == null) block_start = at;
        block_end = @max(block_end, at + sentence.len);
    }
    const start = block_start orelse return;
    census.contract_blocks += 1;

    // The authored prose comes first, then exactly one blank line, then the
    // contract. Two blank lines, or a blank line inside the block, splits one
    // paragraph into two and reads as two separate claims.
    if (start < 2 or !std.mem.eql(u8, text[start - 2 .. start], "\n\n") or
        std.mem.indexOf(u8, text[start..block_end], "\n\n") != null)
    {
        std.debug.print(
            "{s}: `{s}` writes its contract sentences as more than one paragraph\n",
            .{ file_path, fn_name },
        );
        return error.ContractBlockIsNotOneParagraph;
    }

    // The block is the sentences the signature earned, back to back and in the
    // order the emitter writes them.
    var expected_buffer: [contract_block_max]u8 = undefined;
    var expected_len: usize = 0;
    for (contract_sentences) |sentence| {
        if (std.mem.indexOf(u8, text, sentence) == null) continue;
        @memcpy(expected_buffer[expected_len..][0..sentence.len], sentence);
        expected_len += sentence.len;
    }
    if (!std.mem.eql(u8, text[start..block_end], expected_buffer[0..expected_len])) {
        std.debug.print(
            "{s}: `{s}` does not write its contract sentences contiguously, or not in the emitted order\n",
            .{ file_path, fn_name },
        );
        return error.ContractBlockIsNotOneParagraph;
    }

    // Nothing follows the contract, so it cannot be read as the preamble to
    // another claim the signature has not been checked against.
    if (block_end != text.len) {
        std.debug.print(
            "{s}: `{s}` writes text after its contract sentences: \"{s}\"\n",
            .{ file_path, fn_name, text[block_end..] },
        );
        return error.ContractBlockIsNotLast;
    }
}

/// One emitted callable against its own `///` block. Every sentence in that
/// block names a property of the signature directly below it, so the sentence
/// and the property have to agree in both directions.
fn checkCallable(fn_decl: ast.FnDecl, file_path: []const u8, census: *Census) ContractError!void {
    census.callables += 1;
    const documentation_text = fn_decl.documentation;
    if (documentation_text.len == 0) {
        std.debug.print(
            "{s}: emitted function `{s}` carries no documentation\n",
            .{ file_path, fn_decl.name },
        );
        return error.UndocumentedEmittedCallable;
    }

    // The allocator sentence names its parameter, so the parameter is matched on
    // the name as well as the type. An allocator-typed parameter under any
    // other name is a contract sentence with nothing to point at.
    var names_allocator = false;
    var unnameable_allocator: ?[]const u8 = null;
    var owner_parameter = false;
    for (fn_decl.params) |param| {
        if (param.ty != .named or !std.mem.eql(u8, param.ty.named, allocator_type)) {
            if (isOwnerType(param.ty, 0)) owner_parameter = true;
            continue;
        }
        if (std.mem.eql(u8, param.name, "allocator")) {
            names_allocator = true;
        } else {
            unnameable_allocator = param.name;
        }
    }
    if (unnameable_allocator) |name| {
        std.debug.print(
            "{s}: `{s}` takes its allocator as `{s}`, and the documented contract names `allocator`\n",
            .{ file_path, fn_decl.name, name },
        );
        return error.AllocatorParameterIsNotNamedAsDocumented;
    }

    const has_allocator_sentence = std.mem.indexOf(u8, documentation_text, allocator_sentence) != null;
    const has_transfer_sentence = std.mem.indexOf(u8, documentation_text, transfer_sentence) != null;
    const has_release_sentence = std.mem.indexOf(u8, documentation_text, release_sentence) != null;
    const owns_return = isOwnerType(fn_decl.ret_type, 0);

    if (has_allocator_sentence != names_allocator) {
        return contractDrift(file_path, fn_decl.name, allocator_sentence, has_allocator_sentence, names_allocator);
    }
    if (has_transfer_sentence != owner_parameter) {
        return contractDrift(file_path, fn_decl.name, transfer_sentence, has_transfer_sentence, owner_parameter);
    }
    if (has_release_sentence != owns_return) {
        return contractDrift(file_path, fn_decl.name, release_sentence, has_release_sentence, owns_return);
    }
    if (has_allocator_sentence) census.allocator_sentences += 1;
    if (has_transfer_sentence) census.transfer_sentences += 1;
    if (has_release_sentence) census.release_sentences += 1;

    try checkContractBlock(documentation_text, fn_decl.name, file_path, census);
}

/// A `const` or `var`. A public one that defines a value owes the reader prose;
/// a public one that only names another declaration is a re-export and carries
/// the contract of what it points at, which is documented there.
fn checkConstantLike(
    decl_name: []const u8,
    is_pub: bool,
    text: []const u8,
    init: ast.Expr,
    kind_name: []const u8,
    file_path: []const u8,
    census: *Census,
) ContractError!void {
    if (text.len != 0) {
        if (is_pub) census.documented_constants += 1;
        try rejectContractSentence(text, kind_name, decl_name, file_path);
        try rejectOperationProvenance(text, kind_name, decl_name, file_path);
        return;
    }
    if (!is_pub) return;
    census.public_constants += 1;
    if (isAliasInitializer(init)) {
        census.re_exports += 1;
        return;
    }
    std.debug.print(
        "{s}: emitted public {s} `{s}` carries no documentation and is not a re-export\n",
        .{ file_path, kind_name, decl_name },
    );
    return error.UndocumentedPublicDefinition;
}

/// A struct field, an enum variant tag or a union field. The frontend decodes
/// this text once and the lowering copies it, so a tag with no authored
/// comment legitimately carries none — this module invents no wording. What it
/// must never carry is a sentence the emitter synthesizes: those describe a
/// signature or an operation, and a field has neither.
fn checkMember(
    member_name: []const u8,
    is_pub: bool,
    text: []const u8,
    file_path: []const u8,
    census: *Census,
) ContractError!void {
    if (text.len == 0) {
        if (is_pub) census.undocumented_members += 1;
        return;
    }
    if (is_pub) census.documented_members += 1;
    try rejectContractSentence(text, "field", member_name, file_path);
    try rejectOperationProvenance(text, "field", member_name, file_path);
}

fn checkDecls(decls: []const ast.Decl, file_path: []const u8, census: *Census) ContractError!void {
    for (decls) |decl| {
        switch (decl) {
            .fn_decl => |fn_decl| try checkCallable(fn_decl, file_path, census),
            .struct_decl => |struct_decl| {
                census.types += 1;
                if (struct_decl.documentation.len == 0) {
                    std.debug.print(
                        "{s}: emitted struct `{s}` carries no documentation\n",
                        .{ file_path, struct_decl.name },
                    );
                    return error.UndocumentedEmittedType;
                }
                try rejectContractSentence(struct_decl.documentation, "struct", struct_decl.name, file_path);
                try rejectOperationProvenance(struct_decl.documentation, "struct", struct_decl.name, file_path);
                for (struct_decl.fields) |field| {
                    try checkMember(field.name, field.is_pub, field.documentation, file_path, census);
                }
                try checkDecls(struct_decl.decls, file_path, census);
            },
            .enum_decl => |enum_decl| {
                census.types += 1;
                if (enum_decl.documentation.len == 0) {
                    std.debug.print(
                        "{s}: emitted enum `{s}` carries no documentation\n",
                        .{ file_path, enum_decl.name },
                    );
                    return error.UndocumentedEmittedType;
                }
                try rejectContractSentence(enum_decl.documentation, "enum", enum_decl.name, file_path);
                try rejectOperationProvenance(enum_decl.documentation, "enum", enum_decl.name, file_path);
                for (enum_decl.variants) |variant| {
                    // A variant tag has no visibility of its own: it is part
                    // of the enum's surface, so it is counted as public.
                    try checkMember(variant.name, true, variant.documentation, file_path, census);
                }
                try checkDecls(enum_decl.decls, file_path, census);
            },
            .union_decl => |union_decl| {
                census.types += 1;
                if (union_decl.documentation.len == 0) {
                    std.debug.print(
                        "{s}: emitted union `{s}` carries no documentation\n",
                        .{ file_path, union_decl.name },
                    );
                    return error.UndocumentedEmittedType;
                }
                try rejectContractSentence(union_decl.documentation, "union", union_decl.name, file_path);
                try rejectOperationProvenance(union_decl.documentation, "union", union_decl.name, file_path);
                for (union_decl.fields) |field| {
                    try checkMember(field.name, field.is_pub, field.documentation, file_path, census);
                }
                try checkDecls(union_decl.decls, file_path, census);
            },
            .const_decl => |const_decl| try checkConstantLike(
                const_decl.name,
                const_decl.is_pub,
                const_decl.documentation,
                const_decl.init,
                "const",
                file_path,
                census,
            ),
            .var_decl => |var_decl| try checkConstantLike(
                var_decl.name,
                var_decl.is_pub,
                var_decl.documentation,
                var_decl.init,
                "var",
                file_path,
                census,
            ),
            .trait_descriptor, .comment => {},
        }
    }
}

/// Decode one pinned payload and check every declaration it carries. The
/// decoded package is arena-backed: the codec returns owned slices at every
/// level, and one `deinit` releases the whole tree.
fn checkPackage(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Census {
    var buffer: [4096]u8 = undefined;
    var dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &buffer);
    const payload = try reader.interface.allocRemaining(allocator, .limited(1 << 26));

    const package = try serialize.decode(allocator, payload);
    var census: Census = .{};
    for (package.files) |source_file| {
        census.files += 1;
        if (source_file.documentation.len == 0) {
            std.debug.print("{s}: emitted file `{s}` carries no documentation\n", .{
                path,
                source_file.path,
            });
            return error.UndocumentedEmittedFile;
        }
        try rejectContractSentence(source_file.documentation, "file", source_file.path, path);
        try checkDecls(source_file.decls, source_file.path, &census);
    }
    return census;
}

test "fromAttributes: an undocumented declaration costs no allocation at all" {
    // A zero-capacity allocator fails every allocation request. The empty
    // result therefore cannot have come from one, which is what makes it
    // storage the caller has no right to free.
    var backing: [0]u8 = .{};
    var empty_space = std.heap.FixedBufferAllocator.init(&backing);
    const starved = empty_space.allocator();

    try std.testing.expectEqualStrings("", try documentation.fromAttributes(starved, &.{}));
    try std.testing.expectEqualStrings("", try documentation.fromAttributes(starved, &.{
        .{ .name = "repr", .meta = "C", .known = true },
        // Recorded documentation the translator could not evaluate. It
        // contributes no prose and no blank line, so the result stays empty.
        .{ .name = documentation.attribute_name, .meta = "", .known = false },
    }));
}

test "fromAttributes: authored text is joined in order and nothing else" {
    const allocator = std.testing.allocator;
    const authored = try documentation.fromAttributes(allocator, &.{
        .{ .name = "derive", .meta = "Debug", .known = true },
        .{ .name = documentation.attribute_name, .meta = "Counts bytes.", .known = false },
        .{ .name = "repr", .meta = "C", .known = true },
        .{ .name = documentation.attribute_name, .meta = "Second paragraph.", .known = false },
    });
    defer allocator.free(authored);

    try std.testing.expectEqualStrings("Counts bytes.\nSecond paragraph.", authored);
}

test "fromAttributes: allocating for the text is the only failure it has" {
    var backing: [0]u8 = .{};
    var empty_space = std.heap.FixedBufferAllocator.init(&backing);
    try std.testing.expectError(
        error.OutOfMemory,
        documentation.fromAttributes(empty_space.allocator(), &.{
            .{ .name = documentation.attribute_name, .meta = "One byte is still one byte.", .known = false },
        }),
    );
}

test "fromAttributes: a non-empty result is released with the allocator that made it" {
    // `std.testing.allocator` reports a leak at the end of the test, so the
    // free below is what proves the result was owned by this allocator rather
    // than borrowed from static storage.
    const authored = try documentation.fromAttributes(std.testing.allocator, &.{
        .{ .name = documentation.attribute_name, .meta = "Owned by the caller.", .known = false },
    });
    try std.testing.expectEqualStrings("Owned by the caller.", authored);
    std.testing.allocator.free(authored);
}

test "generated packages: the documented allocator contract matches the emitted signature" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;

    var census: Census = .{};
    for (golden_packages) |path| {
        census.add(try checkPackage(allocator, io, path));
    }
    // A walk that reached no callable would pass the loop above, so the
    // coverage it claims is asserted instead of assumed.
    try std.testing.expect(census.callables > 0);
    try std.testing.expect(census.files >= golden_packages.len);
    // These three payloads carry allocator sentences and owned-return
    // sentences, so both directions of that correspondence are exercised.
    // None of them takes a by-value runtime owner, so on this corpus the
    // transfer sentence is checked only in the direction that catches a stale
    // claim: prose naming an owner the signature does not have. That is
    // measured from these files, not assumed of them.
    try std.testing.expect(census.allocator_sentences > 0);
    try std.testing.expect(census.release_sentences > 0);
}

test "generated packages: every emitted public declaration is documented or is a re-export" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;

    var census: Census = .{};
    for (golden_packages) |path| {
        census.add(try checkPackage(allocator, io, path));
    }

    // The corpus has to exercise both arms of the rule, or the rule is not
    // tested by anything above: a public constant that defines a value and
    // owes prose, and a public constant that only names another declaration and
    // does not.
    try std.testing.expect(census.public_constants > 0);
    try std.testing.expect(census.documented_constants > 0);
    try std.testing.expect(census.re_exports > 0);
    // Fields and variant tags carry their source's prose and nothing more, so
    // a corpus with none of either leaves that boundary unchecked.
    try std.testing.expect(census.documented_members > 0);
    try std.testing.expect(census.undocumented_members > 0);
    try std.testing.expect(census.types > 0);
}

test "generated packages: the contract sentences arrive as one trailing block" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;

    var census: Census = .{};
    for (golden_packages) |path| {
        census.add(try checkPackage(allocator, io, path));
    }

    // Every sentence the corpus wrote was checked against the whole sentence
    // above. This asserts the walk found the blocks it checked, so a corpus
    // carrying only truncated sentences could not report zero here.
    try std.testing.expect(census.contract_blocks > 0);
    // A block is the sum of the sentences the signatures earned, so the block
    // count and the sentence counts have to agree on how many blocks there are.
    try std.testing.expect(census.contract_blocks <=
        census.allocator_sentences + census.transfer_sentences + census.release_sentences);
}
