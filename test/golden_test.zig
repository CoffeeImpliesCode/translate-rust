//! translate-rust golden serialization tests.
//!
//! The source-native `mini`, `fnv`, and `hex` fixtures must complete this
//! path and provide canonical RustIR and Zig AST snapshots plus non-empty
//! emitted sources. `hex` is analyzed with its `#[cfg(test)]` module kept, so
//! its package carries the translated `src/test.zig` next to `src/root.zig`.
//! The `compat`, `wyhash`, `adler` and `multimod` fixtures are pinned by
//! emitted-source snapshots, so a change to the text shape of a staged crate
//! that still compiles is still a visible diff. Every snapshot is produced at
//! `golden_target_pointer_width`, never at the host ABI. The separate inline
//! source test below preserves generic-instantiation extraction coverage,
//! then removes the generic definition body and requires a typed lowering
//! rejection for the resulting incomplete IR.
//!
//!   1. `frontend.pipeline.analyzeCrateWithOptions` → `ir.RustIr`
//!   2. `ir.validateForTranslation` → typed frontend/IR validation
//!   3. `backend.Lowering`        → package emission or typed rejection

const std = @import("std");
const translate_rust = @import("translate_rust");

const frontend = translate_rust.frontend;
const ir = translate_rust.ir;
const backend = translate_rust.backend;

/// The target pointer width every snapshot in `test/golden/**` is analysed
/// at. `usize`/`isize` fall back to `@bitSizeOf(usize)` when
/// `CfgOptions.target_pointer_width` is null, which would make the goldens
/// depend on the host ABI: on a 32-bit or wasm32 host every snapshot changes
/// bytes and the failure reads as a translator regression. Pinning the width
/// here makes the snapshots reproducible on any host.
const golden_target_pointer_width: u16 = 64;

/// The analysis configuration the goldens were produced with. Fixtures whose
/// goldens keep `#[cfg(test)]` modules pass `include_tests = true` so the
/// analysis reproduces the snapshot bytes.
fn goldenAnalysisOptions(include_tests: bool) frontend.pipeline.AnalysisOptions {
    return .{
        .include_tests = include_tests,
        .cfg = .{
            .features = &.{},
            .target_pointer_width = golden_target_pointer_width,
            .docsrs = false,
        },
    };
}

/// Compare the golden payload to `actual`. A single final newline is ignored
/// because text editors and generated snapshots use different file endings;
/// every other byte remains strict.
fn checkGolden(
    allocator: std.mem.Allocator,
    test_io: std.Io,
    gold_path: []const u8,
    actual: []const u8,
) !void {
    var dir = std.Io.Dir.cwd();

    if (dir.openFile(test_io, gold_path, .{})) |file| {
        defer file.close(test_io);
        var io_buf: [4096]u8 = undefined;
        var reader = file.reader(test_io, &io_buf);
        const golden = try reader.interface.allocRemaining(allocator, .limited(1 << 28));
        defer allocator.free(golden);
        const golden_payload = if (golden.len > 0 and golden[golden.len - 1] == '\n')
            golden[0 .. golden.len - 1]
        else
            golden;
        if (!std.mem.eql(u8, golden_payload, actual)) {
            std.debug.print(
                "golden mismatch for {s}\n--- golden ({d} bytes) ---\n{s}\n--- actual ({d} bytes) ---\n{s}\n",
                .{ gold_path, golden_payload.len, golden_payload, actual.len, actual },
            );
            return error.GoldenMismatch;
        }
    } else |_| {
        return error.GoldenMissing;
    }
}

fn expectPackageShape(
    pkg: *const backend.zig.ast.Package,
    expected_paths: []const []const u8,
    source_claims_tests: bool,
) !*const backend.zig.ast.File {
    if (pkg.files.len == 0) return error.EmptyPackage;
    if (pkg.files.len != expected_paths.len) return error.SourceFileSetMismatch;

    var root_file: ?*const backend.zig.ast.File = null;
    for (pkg.files, 0..) |*file, index| {
        for (pkg.files[index + 1 ..]) |other| {
            if (std.mem.eql(u8, file.path, other.path)) return error.DuplicateSourceFilePath;
        }

        var expected = false;
        for (expected_paths) |expected_path| {
            if (std.mem.eql(u8, file.path, expected_path)) {
                expected = true;
                break;
            }
        }
        if (!expected) return error.UnexpectedSourceFile;

        if (std.mem.eql(u8, file.path, "src/root.zig")) {
            if (root_file != null) return error.DuplicateRootFile;
            root_file = file;
        }
    }

    for (expected_paths) |expected_path| {
        var found = false;
        for (pkg.files) |file| {
            if (std.mem.eql(u8, file.path, expected_path)) {
                found = true;
                break;
            }
        }
        if (!found) return error.MissingSourceFile;
    }

    // A root that carries no declaration and no test emits 0 bytes, which the
    // staged-package checks and `ast.validateForTranslation` both reject. An
    // import on its own is not content: a root that only pulls in a submodule
    // is the same failure one level down.
    const root = root_file orelse return error.RootFileMissing;
    if (root.decls.len == 0 and root.tests.len == 0) {
        return error.EmptyRoot;
    }

    if (source_claims_tests) {
        var test_count: usize = 0;
        for (pkg.files) |file| test_count += file.tests.len;
        if (test_count == 0) return error.NoTranslatedTests;
    }
    return root;
}

/// The snapshots a golden fixture is pinned by. `full` fixtures are checked
/// against the canonical RustIR, Zig AST and emitted source; `source_only`
/// fixtures are pinned by their emitted source only, which is what catches a
/// change to the text shape of a staged crate that still compiles and still
/// satisfies that crate's own tests.
const SnapshotCoverage = enum { full, source_only };

/// What the analysis and IR validation boundary did with a fixture.
const RejectionOutcome = union(enum) {
    /// Both stages succeeded: the fixture would translate.
    accepted,
    /// A stage failed with exactly this error.
    rejected: anyerror,
};

/// Run the analysis and IR validation boundary for a fixture and report what
/// it did. A rejection carries the error the pipeline actually raised, so the
/// caller compares it against the error it declared.
fn rejectionOutcome(
    allocator: std.mem.Allocator,
    test_io: std.Io,
    crate_dir: []const u8,
    options: frontend.pipeline.AnalysisOptions,
) !RejectionOutcome {
    const rust_ir = frontend.pipeline.analyzeCrateWithOptions(
        allocator,
        test_io,
        crate_dir,
        options,
    ) catch |err| return .{ .rejected = err };
    if (ir.validateForTranslation(&rust_ir)) |_| {
        return .accepted;
    } else |err| {
        return .{ .rejected = err };
    }
}

fn runGoldenFixture(
    fixture_name: []const u8,
    crate_dir: []const u8,
    expected_rejection: ?anyerror,
    expected_paths: []const []const u8,
    include_tests: bool,
    source_claims_tests: bool,
    coverage: SnapshotCoverage,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const test_io = std.testing.io;

    const analysis_options = goldenAnalysisOptions(include_tests);

    if (expected_rejection) |expected_error| {
        // The declared error is the contract: a fixture that translates
        // cleanly, or that fails for a different reason, is a failure here.
        switch (try rejectionOutcome(allocator, test_io, crate_dir, analysis_options)) {
            .accepted => return error.IncompleteFixtureAccepted,
            .rejected => |observed| {
                if (observed != expected_error) return observed;
                return;
            },
        }
    }

    // 1. Frontend analysis → RustIr.
    const rust_ir = try frontend.pipeline.analyzeCrateWithOptions(
        allocator,
        test_io,
        crate_dir,
        analysis_options,
    );

    // 2. Encode the complete canonical RustIr to JSON and snapshot. The
    // frontend and serializer intentionally share the same nominal model;
    // assigning the value directly preserves every field, including graph
    // metadata and monomorphization instantiations.
    const wire_ir: ir.serialize.RustIr = rust_ir;
    try ir.validateForTranslation(&rust_ir);
    if (coverage == .full) {
        const rust_ir_path = try std.fmt.allocPrint(
            allocator,
            "test/golden/rust_ir/{s}.rustir.json",
            .{fixture_name},
        );
        const rust_ir_json = try ir.serialize.encode(allocator, &wire_ir);
        defer allocator.free(rust_ir_json);
        try checkGolden(allocator, test_io, rust_ir_path, rust_ir_json);
    }

    // 3. Lower RustIr → ast.Package via the default strategy.
    const pkg = try backend.zig.lower.lowerRustIr(allocator, &rust_ir, null);
    const root_file = try expectPackageShape(&pkg, expected_paths, source_claims_tests);
    var package_for_structural_validation = pkg;
    package_for_structural_validation.fingerprint =
        package_for_structural_validation.fingerprint orelse 0;
    try backend.zig.ast.validateForTranslation(&package_for_structural_validation);

    // 4. Encode the package AST to JSON and snapshot.
    if (coverage == .full) {
        const zig_ast_path = try std.fmt.allocPrint(
            allocator,
            "test/golden/zig_ast/{s}.zigast.json",
            .{fixture_name},
        );
        const zig_ast_json = try backend.zig.serialize.encode(allocator, &pkg);
        defer allocator.free(zig_ast_json);
        try checkGolden(allocator, test_io, zig_ast_path, zig_ast_json);
    }

    // 5. Emit each source file; assert it produces valid, non-empty Zig and
    // matches the emitted-source snapshot.
    for (pkg.files) |*file| {
        const src = try backend.zig.emit.emitFile(allocator, file);
        defer allocator.free(src);
        if (src.len == 0) {
            if (std.mem.eql(u8, file.path, "src/root.zig")) return error.EmptyRootEmit;
            return error.EmptyEmit;
        }
        const source_payload = if (src[src.len - 1] == '\n') src[0 .. src.len - 1] else src;
        const source_golden_path = try std.fmt.allocPrint(
            allocator,
            "test/golden/zig_src/{s}/{s}",
            .{ fixture_name, file.path },
        );
        try checkGolden(allocator, test_io, source_golden_path, source_payload);
    }

    // `expectPackageShape` matched the root by path; the post-condition worth
    // keeping is that the root carries emitted declarations, which is what
    // makes `src/root.zig` non-empty.
    try std.testing.expect(root_file.decls.len > 0);
}

test "golden: mini translates to canonical package" {
    try runGoldenFixture(
        "mini",
        "test/crates/mini",
        null,
        &.{ "src/root.zig", "src/util.zig" },
        false,
        false,
        .full,
    );
}
test "golden: fnv source translates to canonical package" {
    try runGoldenFixture(
        "fnv",
        "test/crates/fnv",
        null,
        &.{"src/root.zig"},
        false,
        false,
        .full,
    );
}

// The remaining accepted fixtures are pinned by their emitted source. Their
// RustIR/Zig AST snapshots would be large and change for reasons that do not
// affect the text a staged crate ships, so only the emitted files are
// snapshotted for them.
test "golden: compat source translates to pinned emitted package" {
    try runGoldenFixture(
        "compat",
        "test/crates/compat",
        null,
        &.{ "src/root.zig", "src/support.zig", "src/support/child.zig" },
        true,
        true,
        .source_only,
    );
}

test "golden: wyhash source translates to pinned emitted package" {
    try runGoldenFixture(
        "wyhash",
        "test/crates/wyhash",
        null,
        &.{ "src/root.zig", "src/functions.zig", "src/functions/tests.zig" },
        true,
        true,
        .source_only,
    );
}

test "golden: adler source translates to pinned emitted package" {
    try runGoldenFixture(
        "adler",
        "test/crates/adler",
        null,
        &.{ "src/root.zig", "src/algo.zig", "src/tests.zig" },
        true,
        true,
        .source_only,
    );
}

// The three discovered modules must land on their own emitted files, with the
// `#[path]`-attributed module named after its declaration, not its source.
test "golden: multimod maps every discovered module to its own emitted file" {
    try runGoldenFixture(
        "multimod",
        "test/crates/multimod",
        null,
        &.{ "src/root.zig", "src/foo.zig", "src/foo/bar.zig", "src/custom_pub.zig" },
        false,
        false,
        .source_only,
    );
}

test "golden: fnv included tests contain only assertion unsupported expressions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var rust_ir = try frontend.pipeline.analyzeCrateWithOptions(
        allocator,
        std.testing.io,
        "test/crates/fnv",
        .{ .include_tests = true },
    );
    defer rust_ir.deinitInstantiations(allocator);

    const assertion_prefix = "assertion:";
    var only_assertion_markers = true;
    for (rust_ir.bodies.exprs) |expression| {
        const reason = switch (expression.kind) {
            .unsupported => |unsupported| unsupported.reason,
            else => continue,
        };

        var is_assertion_marker =
            std.mem.startsWith(u8, reason, assertion_prefix) and
            reason.len > assertion_prefix.len;
        if (is_assertion_marker) {
            for (reason[assertion_prefix.len..]) |character| {
                if (character < '0' or character > '9') {
                    is_assertion_marker = false;
                    break;
                }
            }
        }
        if (!is_assertion_marker) {
            only_assertion_markers = false;
            std.debug.print(
                "unexpected FNV unsupported expression reason: \"{s}\"\n",
                .{reason},
            );
        }
    }
    try std.testing.expect(only_assertion_markers);

    var test_module_id: ?u32 = null;
    for (rust_ir.graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .module and std.mem.eql(u8, entity.name, "test")) {
            test_module_id = entity.id;
            break;
        }
    }
    try std.testing.expect(test_module_id != null);

    var basic_tests_id: ?u32 = null;
    for (rust_ir.graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .fn_ and
            std.mem.eql(u8, entity.name, "basic_tests") and
            entity.parent != null and
            entity.parent.? == test_module_id.?)
        {
            basic_tests_id = entity.id;
            break;
        }
    }
    try std.testing.expect(basic_tests_id != null);
    try std.testing.expect(basic_tests_id.? < rust_ir.bodies.bodies.len);

    const basic_tests_body = switch (rust_ir.bodies.bodies[basic_tests_id.?]) {
        .fn_ => |function_body| function_body,
        else => return error.MissingFnvBasicTestsBody,
    };
    try std.testing.expect(basic_tests_body.body < rust_ir.bodies.exprs.len);
    const basic_tests_block = switch (rust_ir.bodies.exprs[basic_tests_body.body].kind) {
        .block => |block| block,
        else => return error.InvalidFnvBasicTestsBody,
    };
    try std.testing.expect(basic_tests_block.statements.len > 0);
}

test "golden: fnv preserves hasher methods" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var rust_ir = try frontend.analyzeCrate(allocator, std.testing.io, "test/crates/fnv");
    defer rust_ir.deinitInstantiations(allocator);
    try ir.validateForTranslation(&rust_ir);
    const pkg = try backend.zig.lower.lowerRustIr(allocator, &rust_ir, null);
    const root = try expectPackageShape(&pkg, &.{"src/root.zig"}, false);

    var hasher: ?backend.zig.ast.StructDecl = null;
    for (root.decls) |decl| {
        if (decl == .struct_decl and std.mem.eql(u8, decl.struct_decl.name, "FnvHasher")) {
            hasher = decl.struct_decl;
            break;
        }
    }
    const decl = hasher orelse return error.MissingFnvHasher;

    var found_default = false;
    var found_finish = false;
    var found_write = false;
    for (decl.decls) |member| {
        if (member != .fn_decl) continue;
        const function = member.fn_decl;
        if (function.body == null) return error.EmptyFnvMethod;
        if (std.mem.eql(u8, function.name, "default")) found_default = true;
        if (std.mem.eql(u8, function.name, "finish")) found_finish = true;
        if (std.mem.eql(u8, function.name, "write")) found_write = true;
    }
    try std.testing.expect(found_default);
    try std.testing.expect(found_finish);
    try std.testing.expect(found_write);
}

test "golden: hex library and test module translate to canonical package" {
    try runGoldenFixture(
        "hex",
        "test/crates/hex",
        null,
        &.{ "src/root.zig", "src/error.zig", "src/error/tests.zig", "src/test.zig" },
        true,
        true,
        .full,
    );
}

test "golden: missing source directory propagates ingestion failure" {
    // The declared rejection is the contract: the harness compares the error
    // the pipeline actually raised against the one declared here, so a
    // fixture that fails for some other reason is a failure, not a pass.
    try runGoldenFixture(
        "missing",
        "test/crates/missing",
        error.RootSourceNotFound,
        &.{},
        false,
        false,
        .source_only,
    );
}

test "golden: a rejected fixture reports the error the pipeline raised" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const test_io = std.testing.io;

    // A crate that analyses and validates cleanly is `accepted`, not a
    // rejection that happens to carry no error.
    try std.testing.expectEqual(
        RejectionOutcome.accepted,
        try rejectionOutcome(allocator, test_io, "test/crates/mini", goldenAnalysisOptions(false)),
    );
    // A crate that fails reports the error the pipeline actually raised.
    try std.testing.expectEqual(
        RejectionOutcome{ .rejected = error.RootSourceNotFound },
        try rejectionOutcome(allocator, test_io, "test/crates/missing", goldenAnalysisOptions(false)),
    );
    // Declaring a different error is a mismatch, not a silent pass: the
    // observed error is returned to the caller.
    try std.testing.expectError(
        error.RootSourceNotFound,
        runGoldenFixture(
            "missing",
            "test/crates/missing",
            error.UnsupportedExpression,
            &.{},
            false,
            false,
            .source_only,
        ),
    );
    // A fixture that must be rejected but is not is a failure too.
    try std.testing.expectError(
        error.IncompleteFixtureAccepted,
        runGoldenFixture(
            "mini",
            "test/crates/mini",
            error.UnsupportedExpression,
            &.{ "src/root.zig", "src/util.zig" },
            false,
            false,
            .full,
        ),
    );
}

test "golden: empty packages and claimed tests fail closed" {
    const empty_package = backend.zig.ast.Package{
        .name = "empty",
        .fingerprint = 1,
        .files = &.{},
    };
    try std.testing.expectError(
        error.EmptyPackage,
        expectPackageShape(&empty_package, &.{"src/root.zig"}, false),
    );

    // A root that only imports a submodule still emits no declaration of its
    // own, so it is rejected for the same reason an empty root is.
    const root_without_tests = backend.zig.ast.File{
        .path = "src/root.zig",
        .imports = &.{.{ .local_name = "std", .module_or_path = "std" }},
    };
    const no_tests_package = backend.zig.ast.Package{
        .name = "no_tests",
        .fingerprint = 1,
        .files = &.{root_without_tests},
    };
    try std.testing.expectError(
        error.EmptyRoot,
        expectPackageShape(&no_tests_package, &.{"src/root.zig"}, false),
    );

    const root_with_decl = backend.zig.ast.File{
        .path = "src/root.zig",
        .imports = &.{.{ .local_name = "std", .module_or_path = "std" }},
        .decls = &.{.{ .const_decl = .{
            .name = "marker",
            .init = .{ .lit = .{ .int = 1 } },
        } }},
    };
    const marker_package = backend.zig.ast.Package{
        .name = "marker",
        .fingerprint = 1,
        .files = &.{root_with_decl},
    };
    // A root that does carry a declaration is accepted, and the declaration
    // survives the shape check.
    const marker_root = try expectPackageShape(&marker_package, &.{"src/root.zig"}, false);
    try std.testing.expectEqual(@as(usize, 1), marker_root.decls.len);
    try std.testing.expectError(
        error.NoTranslatedTests,
        expectPackageShape(&marker_package, &.{"src/root.zig"}, true),
    );
}

test "golden: package validation rejects null fingerprints" {
    const missing_fingerprint = backend.zig.ast.Package{
        .name = "missing_fingerprint",
        .fingerprint = null,
        .files = &.{.{ .path = "src/root.zig" }},
    };
    try std.testing.expectError(
        error.MissingFingerprint,
        backend.zig.ast.validateForTranslation(&missing_fingerprint),
    );
}

test "source pipeline rejects incomplete generic definitions before package emission" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const src =
        \\pub struct Foo<T>(pub T);
        \\
        \\pub fn make_u32(value: u32) -> Foo<u32> {
        \\    Foo::<u32>(value)
        \\}
        \\
        \\pub fn make_slice(value: &[u8]) -> Foo<&[u8]> {
        \\    Foo(value)
        \\}
    ;

    var rust_ir = try frontend.pipeline.analyzeSource(
        allocator,
        "generic_source",
        "2021",
        src,
    );

    var foo_id: ?ir.spine.EntityId = null;
    for (rust_ir.graph.symbol_table.entities.items) |entity| {
        if (entity.kind != .struct_ or !std.mem.eql(u8, entity.name, "Foo")) continue;
        try std.testing.expect(foo_id == null);
        foo_id = entity.id;
    }
    const expected_foo_id = foo_id orelse return error.FooEntityMissing;

    try std.testing.expectEqual(@as(usize, 2), rust_ir.instantiations.len);
    // Both instantiations name a generated Zig symbol, so their suffixes must
    // differ or the two monomorphisations would collide in one package.
    var suffixes: [2][]const u8 = undefined;
    var suffix_count: usize = 0;
    for (rust_ir.instantiations) |instantiation| {
        try std.testing.expectEqual(expected_foo_id, instantiation.generic_id);
        try std.testing.expectEqual(@as(usize, 1), instantiation.args.params.len);

        switch (instantiation.args.params[0]) {
            .prim => |prim| {
                try std.testing.expectEqual(ir.types.Prim.u32, prim);
                try std.testing.expectEqualStrings("_u32", instantiation.zig_suffix);
                try std.testing.expect(suffix_count < suffixes.len);
                suffixes[suffix_count] = instantiation.zig_suffix;
                suffix_count += 1;
            },
            .slice => |slice| {
                try std.testing.expect(slice.const_);
                switch (slice.elem) {
                    .prim => |prim| try std.testing.expectEqual(ir.types.Prim.u8, prim),
                    else => return error.UnexpectedFooSliceElement,
                }
                try std.testing.expectEqualStrings("_u8_slice", instantiation.zig_suffix);
                try std.testing.expect(suffix_count < suffixes.len);
                suffixes[suffix_count] = instantiation.zig_suffix;
                suffix_count += 1;
            },
            else => return error.UnexpectedFooInstantiation,
        }
    }
    try ir.validateForTranslation(&rust_ir);
    try std.testing.expect(expected_foo_id < rust_ir.bodies.bodies.len);
    const incomplete_bodies = try allocator.dupe(ir.bodies.BodyKind, rust_ir.bodies.bodies);
    incomplete_bodies[expected_foo_id] = .{ .none = {} };
    rust_ir.bodies.bodies = incomplete_bodies;
    try std.testing.expect(!std.mem.eql(u8, suffixes[0], suffixes[1]));
    try std.testing.expectError(
        error.DeclarationBodyMismatch,
        backend.zig.lower.lowerRustIr(allocator, &rust_ir, null),
    );
}

/// Emit the root source of a one-file package built from `source` under
/// `cfg`. Caller owns the returned slice.
fn emitInlineSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    cfg: frontend.cst.CfgOptions,
) ![]const u8 {
    var rust_ir = try frontend.pipeline.analyzeSourceWithOptions(
        allocator,
        "golden_cfg_source",
        "2021",
        source,
        .{ .cfg = cfg },
    );
    defer rust_ir.deinitInstantiations(allocator);
    try ir.validateForTranslation(&rust_ir);
    const pkg = try backend.zig.lower.lowerRustIr(allocator, &rust_ir, null);
    for (pkg.files) |*file| {
        if (!std.mem.eql(u8, file.path, "src/root.zig")) continue;
        return backend.zig.emit.emitFile(allocator, file);
    }
    return error.MissingRootFile;
}

fn emittedContains(source: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, source, needle) != null;
}

test "golden: snapshots are analysed at a fixed target width, not the host ABI" {
    // A null `target_pointer_width` makes the frontend follow the host ABI, so
    // every snapshot under `test/golden/**` would change bytes on a 32-bit or
    // wasm32 host and the mismatch would read as a translator regression. The
    // harness must pin the width it snapshots at, for both analysis modes.
    try std.testing.expectEqual(
        golden_target_pointer_width,
        goldenAnalysisOptions(false).cfg.target_pointer_width.?,
    );
    try std.testing.expectEqual(
        golden_target_pointer_width,
        goldenAnalysisOptions(true).cfg.target_pointer_width.?,
    );

    // The pin is load-bearing rather than decorative: the configured width
    // decides which declarations survive cfg expansion, so an unpinned harness
    // really would produce different snapshot bytes on another host.
    const source =
        \\#[cfg(target_pointer_width = "32")]
        \\pub fn narrow() -> u8 {
        \\    1
        \\}
        \\#[cfg(target_pointer_width = "64")]
        \\pub fn wide() -> u8 {
        \\    2
        \\}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const at_32 = try emitInlineSource(allocator, source, .{ .target_pointer_width = 32 });
    const at_64 = try emitInlineSource(allocator, source, .{ .target_pointer_width = 64 });
    try std.testing.expect(emittedContains(at_32, "fn narrow"));
    try std.testing.expect(!emittedContains(at_32, "fn wide"));
    try std.testing.expect(emittedContains(at_64, "fn wide"));
    try std.testing.expect(!emittedContains(at_64, "fn narrow"));

    // With nothing configured the frontend follows the host, which is exactly
    // the divergence the pinned width removes.
    const at_host = try emitInlineSource(allocator, source, .{});
    try std.testing.expect(emittedContains(
        at_host,
        if (@bitSizeOf(usize) == 32) "fn narrow" else "fn wide",
    ));
}

fn appendFileContents(
    corpus: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    test_io: std.Io,
    path: []const u8,
) !void {
    var dir = std.Io.Dir.cwd();
    const file = try dir.openFile(test_io, path, .{});
    defer file.close(test_io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(test_io, &buffer);
    const contents = try reader.interface.allocRemaining(allocator, .limited(1 << 26));
    defer allocator.free(contents);
    try corpus.appendSlice(allocator, contents);
    // NUL-separate so a name can never straddle two files.
    try corpus.append(allocator, 0);
}

/// Everything a test or build step says: `build.zig` plus every Zig source in
/// `test/`. A fixture counts as referenced only when one of those names it.
fn namingCorpus(allocator: std.mem.Allocator, test_io: std.Io) ![]const u8 {
    var corpus: std.ArrayList(u8) = .empty;
    try appendFileContents(&corpus, allocator, test_io, "build.zig");

    var test_dir = try std.Io.Dir.cwd().openDir(test_io, "test", .{ .iterate = true });
    defer test_dir.close(test_io);
    var walker = try test_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(test_io)) |entry| {
        if (entry.kind != .file) continue;
        // Only `test/*.zig` names fixtures; `test/crates/**` and
        // `test/golden/**` are the fixtures themselves, not the tests.
        if (entry.depth() != 1) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(allocator, "test/{s}", .{entry.path});
        try appendFileContents(&corpus, allocator, test_io, path);
    }
    return corpus.items;
}

/// True when `corpus` quotes `token` as a standalone string literal, so a
/// fixture name is not satisfied by a longer identifier containing it.
fn corpusQuotes(corpus: []const u8, token: []const u8) bool {
    var needle: [512]u8 = undefined;
    const quoted = std.fmt.bufPrint(&needle, "\"{s}\"", .{token}) catch return false;
    return std.mem.indexOf(u8, corpus, quoted) != null;
}

/// The fixture a golden belongs to: `zig_src/<fixture>/<path>`,
/// `rust_ir/<fixture>.rustir.json`, or `zig_ast/<fixture>.zigast.json`.
fn goldenFixtureKey(relative_path: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, relative_path, "zig_src/"))
        relative_path["zig_src/".len..]
    else if (std.mem.startsWith(u8, relative_path, "rust_ir/"))
        relative_path["rust_ir/".len..]
    else if (std.mem.startsWith(u8, relative_path, "zig_ast/"))
        relative_path["zig_ast/".len..]
    else
        return null;
    const end = std.mem.indexOfAny(u8, rest, "/.") orelse return null;
    if (end == 0) return null;
    return rest[0..end];
}

// A snapshot or wire fixture that no test or build step names is invisible:
// it can drift from the translator and still be green. That is how
// `test/golden/zig_src/hex/**` sat unread while the emitted text changed
// underneath it. This test walks the fixture trees and fails on any file no
// test or build step names.
test "no golden or wire fixture file is orphaned" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const test_io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const corpus = try namingCorpus(allocator, test_io);
    // The harness must build golden paths at all, or the walk below is
    // checking nothing.
    if (std.mem.indexOf(u8, corpus, "test/golden/zig_src/") == null) {
        return error.GoldenHarnessUnreferenced;
    }

    var golden_dir = try cwd.openDir(test_io, "test/golden", .{ .iterate = true });
    defer golden_dir.close(test_io);
    var golden_walker = try golden_dir.walk(allocator);
    defer golden_walker.deinit();
    while (try golden_walker.next(test_io)) |entry| {
        if (entry.kind != .file) continue;
        const fixture_name = goldenFixtureKey(entry.path) orelse {
            std.debug.print("orphaned snapshot: `test/golden/{s}` has no known layout\n", .{entry.path});
            return error.OrphanedGolden;
        };
        if (corpusQuotes(corpus, fixture_name)) continue;
        std.debug.print(
            "orphaned snapshot: `test/golden/{s}` belongs to fixture `{s}`, which no test or build step names\n",
            .{ entry.path, fixture_name },
        );
        return error.OrphanedGolden;
    }

    var test_dir = try cwd.openDir(test_io, "test", .{ .iterate = true });
    defer test_dir.close(test_io);
    var test_entries = test_dir.iterate();
    while (try test_entries.next(test_io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const reference = try std.fmt.allocPrint(allocator, "test/{s}", .{entry.name});
        if (std.mem.indexOf(u8, corpus, reference) != null) continue;
        std.debug.print(
            "orphaned fixture: `{s}` is named by no test or build step\n",
            .{reference},
        );
        return error.OrphanedFixture;
    }
}
