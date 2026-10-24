//! translate-rust golden serialization tests.
//!
//! A golden fixture runs the whole pipeline — frontend analysis, IR
//! validation, backend lowering, package-shape validation, and a per-file
//! emit — and is then pinned at one of three depths, declared per fixture by
//! its `SnapshotCoverage`.
//!
//! Which depth a fixture gets is a judgement about what that fixture's bytes
//! MEAN, and the five fixtures that moved this session were classified before
//! any of them was touched:
//!
//!   - `fnv` — INCIDENTAL. The canonical RustIR and Zig AST documents are
//!     tables of row indices: `ty`, `def` and `method` are positions in arrays
//!     the frontend may intern in any order, and a type alias reached first
//!     moves every later row by one. The measured change was exactly that —
//!     both documents stayed 23014 bytes and differed only by a permutation of
//!     the type table, a swap of entity rows 22 and 23, and the indices that
//!     follow from them. Not one literal, operator, receiver or body node
//!     changed. Its emitted source carries the same problem in a different
//!     costume: a verbatim copy of the crate's rustdoc plus generated block
//!     labels (`__r2z_value_block_7`) whose numbers are an artefact of
//!     lowering order. `fnv` therefore pins NO bytes and its contract is the
//!     typed AST asserted below.
//!
//!   - `hex` — INCIDENTAL, for the same two reasons, at twenty times the
//!     volume: two table-indexed JSON documents and a 1955-line emitted file
//!     that is mostly the crate's own documentation. Its package shape, its
//!     module map, its imports and the public names it publishes are asserted
//!     against the typed AST instead, and every one of those is a declaration
//!     this fixture could actually lose.
//!
//!   - `wyhash` — GENUINE IMPROVEMENT, re-pin done. The pinned root is the
//!     TRIMMED crate's module documentation and module map, and the fixture
//!     under `test/crates/wyhash/src` is the pristine upstream 0.4.0. Upstream's
//!     root really does declare `mod traits;`, so the emission gained the
//!     `./traits.zig` import, the `pub const WyHash = traits.WyHash;` and
//!     `pub const WyRng = traits.WyRng;` re-exports that mirror
//!     `pub use crate::traits::{WyHash, WyRng};`, a second
//!     `translated tests reachable through ./traits.zig` test, and the upstream
//!     module documentation with its `Hasher`, `RngCore` and `SeedableRng`
//!     usage sections. `test/golden/zig_src/wyhash/src/traits.zig` is present
//!     and pinned, so every file this fixture emits is compared; the earlier
//!     note here recorded that file as absent, which stopped being true once
//!     `zig build generate-wyhash-golden` had been run. Text shape
//!     is what this fixture pins — the module map and the public surface under
//!     an upstream crate — so it follows the emission and stays `source_only`.
//!
//!   - `compat` — MIXED. Each region was classified against the pinned text
//!     before anything was regenerated, and the regions do not all land the
//!     same way:
//!
//!       * Ownership and release — GENUINE IMPROVEMENT. `discard_result_error`,
//!         `discard_result_success`, `take_result_error`, `discard_local_result`,
//!         `retain_local_error`, `moved_vec_element`, `moved_branch_value`,
//!         `moved_match_value`, `moved_loop_value`, `local_pair_length`,
//!         `mutated_local_matches`, `temporary_moved_result_equal` and
//!         `temporary_moved_result_caller` each hand an owned `String` or
//!         `Result` from one owner to another. The pinned text ALIASES that
//!         storage — `const result_1: r2z.Result(u8, r2z.alloc.String) =
//!         r2z.Result(u8, r2z.alloc.String){ .Err = payload };` gives the one
//!         buffer a second owner — while the emission transfers it with
//!         `r2z.alloc.takeOwned(…, &payload)` and arms
//!         `r2z.alloc.dropTemporary(…)` on the destination, so exactly one
//!         owner survives every path.
//!
//!       * Explicit types on derived bindings — GENUINE IMPROVEMENT.
//!         `write_inferred_nested_array` pins `const view = (&rows[1])[0..];`,
//!         which infers a many-item pointer, so the `view[0] = value` that
//!         follows it cannot compile; `const view: []u8 = …` can.
//!         `or_payload` and `owned_or_payload_length` likewise write
//!         `const value: OrPayload =` and `const value: OwnedOrPayload =`
//!         instead of leaving the type to inference.
//!
//!       * Guarded chain tails — NO CHANGE TO THE PIN. `or_payload` and
//!         `owned_or_payload_length` keep the pinned spelling, where every arm
//!         leaves through `break :__r2z_match_block …` inside a labelled value
//!         block and the block ends in `unreachable;`. The chain is lowered
//!         WHOLE — `lowerGuardedMatch` returns `.{ .block = .{ .label = label,
//!         .stmts = … } }` — and `emitBlockScoped` writes that label, so the
//!         exits resolve to a block the reader can see. A run that flattened
//!         these two and emitted bare `break` was reading a chain whose label
//!         had been dropped; the labelled-tail rule fixes that, and the pinned
//!         text is already the fixed spelling.
//!
//!       * Integer literal types in `numeric_check` and `generic_check` — NOT
//!         PINNABLE IF IT PERSISTS. `digit` returns `Option<u32>` and `narrow`
//!         returns `Option<u8>`, so `Some(15)` and `Some(255)` have to be typed
//!         `@as(?u32, 15)`, `@as(?u8, 255)` and `@as(?u8, 255)`. One recorded
//!         run emitted `@as(?i32, 15)` and `@as(?i32, 255)` instead, which
//!         compares a `?u32` with a `?i32`. If the regeneration still emits
//!         `?i32` there, that is a REGRESSION in literal typing rather than a
//!         shape change, and it belongs in the emitter, not in this golden.
//!
//!   - `adler` — GENUINE IMPROVEMENT, re-pin required, same cause. The
//!     pristine upstream 1.0.2 `Adler32` carries the `Default` impl, the
//!     `Hasher` impl and `write_slice`/`compute` that the trimmed fixture did
//!     not, and the emitted root grows from 7447 to 9658 bytes because of
//!     them. Keeping a smaller text pin here would pin the absence of the
//!     crate's own API.
//!
//!   - `mini` stays `full`: it is small enough that a reviewer can read the
//!     whole snapshot, and it is the one fixture whose table indices are few
//!     enough that byte equality says something.
//!
//!   - `compat`, `multimod`, `wyhash` and `adler` stay `source_only`: their
//!     emitted text IS the contract they exist for. The `compat` and `wyhash`
//!     re-pins go through the repository's own generators —
//!     `zig build generate-compat-golden` and
//!     `zig build generate-wyhash-golden` — and neither golden file
//!     is never hand-edited. `test/crates/percent-encoding` is NOT named by any
//!     fixture here, and that is an omission with a reason rather than a claim
//!     about the crate: it is a `corpus_rows` POSITIVE row (`build.zig`), and
//!     `test/e2e_test.zig` translates it and runs doctest and ownership
//!     consumers over the staged package. What it is not is a golden fixture —
//!     it has no `SnapshotCoverage` row, so `expectedGoldenPaths` below has no
//!     entry for it and no byte of it is pinned here. Its coverage is executed
//!     coverage, which this harness would only weaken by duplicating.
//!
//! Every snapshot is produced at `golden_target_pointer_width`, never at the
//! host ABI. The separate inline source test below preserves generic-
//! instantiation extraction coverage, then removes the generic definition
//! body and requires a typed lowering rejection for the resulting incomplete
//! IR.
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

    // A root that carries no declaration and no test emits 0 bytes, and that
    // is a valid package, not a failure: a crate whose manifest enables
    // nothing cfg's out every module and genuinely reduces to an empty root.
    // The backend boundary accepts that shape and so does the emit loop
    // below, where a 0-byte emit is compared against a pinned 0-byte golden —
    // the source text of a root with no declarations is a real golden, not an
    // exempt one. What this check still pins is that the fixture stages
    // exactly the files it declares and that a source claiming tests really
    // produced them.
    const root = root_file orelse return error.RootFileMissing;

    if (source_claims_tests) {
        var test_count: usize = 0;
        for (pkg.files) |file| test_count += file.tests.len;
        if (test_count == 0) return error.NoTranslatedTests;
    }
    return root;
}

/// What a golden fixture is pinned by. The depth is per fixture and says what
/// that fixture's bytes are FOR; see the file header for why each fixture sits
/// where it does.
///
/// `full` pins all three layers — the canonical RustIR document, the Zig AST
/// document, and every emitted source file. It is reserved for a fixture small
/// enough that a reviewer can read the whole snapshot and tell a change from
/// churn.
///
/// `source_only` pins the emitted text alone. That is the right depth for a
/// fixture whose text shape IS the contract: its module→file map, or the
/// public surface its configuration is the reason the fixture exists.
///
/// `typed` pins no bytes at all. The pipeline still runs end to end and still
/// has to produce a valid package — the shape check, the backend AST
/// validation and the non-empty emit below all still apply — but what the
/// package CONTAINS is claimed by a typed-AST test instead of by a document
/// whose bytes are mostly row indices. Dropping a declaration is still a
/// failure; renumbering a table is not.
const SnapshotCoverage = enum { full, source_only, typed };

/// Every fixture `runGoldenFixture` translates, and the depth its bytes are
/// pinned at.
///
/// This table is the SINGLE place a fixture's coverage is written down.
/// `runGoldenFixture` reads its depth from here instead of taking it as an
/// argument, because the orphan walk in "no golden or wire fixture file is
/// orphaned" has to answer a question the old shape could not: not "is this
/// fixture named somewhere?" but "does any assertion in this file READ these
/// bytes?". A golden that only its fixture's name survives in the naming
/// corpus is read by nothing, drifts from the translator, and still reports
/// green — which is precisely the failure the walk exists to prevent.
///
/// The paths are the files the package is required to emit, so the table
/// states the module→file map as well as the depth, and both are checked.
/// `zig_ast` is listed separately in `foreign_golden_readers`: those documents
/// are decoded into a typed AST by `src/backend/zig/documentation_test.zig`, so
/// they are read by a real contract even for a `typed` fixture that pins no
/// bytes here.
const golden_fixtures = [_]struct {
    name: []const u8,
    coverage: SnapshotCoverage,
    emitted_paths: []const []const u8,
}{
    .{ .name = "mini", .coverage = .full, .emitted_paths = &.{ "src/root.zig", "src/util.zig" } },
    .{ .name = "fnv", .coverage = .typed, .emitted_paths = &.{"src/root.zig"} },
    .{
        .name = "compat",
        .coverage = .source_only,
        .emitted_paths = &.{ "src/root.zig", "src/support.zig", "src/support/child.zig" },
    },
    .{
        .name = "wyhash",
        .coverage = .source_only,
        .emitted_paths = &.{
            "src/root.zig",
            "src/functions.zig",
            "src/functions/tests.zig",
            "src/traits.zig",
        },
    },
    .{
        .name = "adler",
        .coverage = .source_only,
        .emitted_paths = &.{ "src/root.zig", "src/algo.zig", "src/tests.zig" },
    },
    .{
        .name = "multimod",
        .coverage = .source_only,
        // `src/foo/tests.zig` is `foo.rs`'s own `#[cfg(test)] mod tests`, and it
        // is a fourth discovered module rather than a document of the first
        // three. It has to be declared here because `generate-multimod-golden`
        // analyses with `include_tests = true` — the row below must run the
        // frontend the same way the generator did, or the pinned bytes come
        // from a configuration the assertion never reproduces.
        .emitted_paths = &.{
            "src/root.zig",
            "src/foo.zig",
            "src/foo/bar.zig",
            "src/foo/tests.zig",
            "src/custom_pub.zig",
        },
    },
    .{
        .name = "hex",
        .coverage = .typed,
        .emitted_paths = &.{
            "src/root.zig",
            "src/error.zig",
            "src/error/tests.zig",
            "src/test.zig",
        },
    },
};

/// The declared row for `fixture_name`, or null when no fixture declares one.
///
/// The row type is the table's ELEMENT type. `@TypeOf(golden_fixtures)` is the
/// array, whose field 0 is `name`, so a field lookup there does not name the
/// row every caller below reads `.coverage`, `.name` and `.emitted_paths` off.
fn declaredFixture(fixture_name: []const u8) ?@TypeOf(golden_fixtures[0]) {
    for (golden_fixtures) |fixture| {
        if (std.mem.eql(u8, fixture.name, fixture_name)) return fixture;
    }
    return null;
}

/// The golden documents under `test/golden/` that some assertion READS but this
/// file does not, with the program that reads each one.
///
/// `documentation_test.zig` decodes each of these through the package codec
/// into a typed `ast.Package` and fails when a documentation sentence outlives
/// the signature it names, so a change to one is a build failure. They are
/// listed by path rather than discovered so that deleting the program which
/// reads them, or a path that stops decoding, cannot pass unnoticed here.
const foreign_golden_readers = [_]struct { path: []const u8, reader: []const u8 }{
    .{ .path = "zig_ast/mini.zigast.json", .reader = "src/backend/zig/documentation_test.zig" },
    .{ .path = "zig_ast/fnv.zigast.json", .reader = "src/backend/zig/documentation_test.zig" },
    .{ .path = "zig_ast/hex.zigast.json", .reader = "src/backend/zig/documentation_test.zig" },
};

/// Every golden path under `test/golden/` that `runGoldenFixture` compares, as
/// paths relative to that directory.
///
/// Derived from `golden_fixtures`, never written out by hand, so a fixture
/// cannot be declared at one depth and pinned at another.
fn expectedGoldenPaths(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    relative_prefix: []const u8,
) !void {
    for (golden_fixtures) |fixture| {
        if (fixture.coverage == .full) {
            try out.append(allocator, try std.fmt.allocPrint(
                allocator,
                "{s}rust_ir/{s}.rustir.json",
                .{ relative_prefix, fixture.name },
            ));
        }
        // `zig_ast` is deliberately absent: this harness compares it only under
        // `full`, and for every other fixture it is a `foreign_golden_reader`
        // instead, so counting it twice would let one reader's disappearance
        // hide behind the other.
        if (fixture.coverage == .typed) continue;
        for (fixture.emitted_paths) |path| {
            try out.append(allocator, try std.fmt.allocPrint(
                allocator,
                "{s}zig_src/{s}/{s}",
                .{ relative_prefix, fixture.name, path },
            ));
        }
    }
    for (foreign_golden_readers) |entry| {
        try out.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{s}{s}",
            .{ relative_prefix, entry.path },
        ));
    }
}

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

    // Resolved AFTER the rejection branch, so a fixture that never reaches the
    // package — the `missing` directory, which exists only to prove the harness
    // compares the error the pipeline raised — needs no row and pins no bytes.
    const declared = declaredFixture(fixture_name) orelse
        return error.UndeclaredGoldenFixture;
    const coverage = declared.coverage;
    // The module→file map is declared twice — here by the caller and in
    // `golden_fixtures` — and the orphan walk below reads the table's copy, so
    // a caller that disagreed with it would stage a package the walk believes
    // is pinned at a path nothing reads. One table, checked against itself.
    if (!std.mem.eql(u8, declared.name, fixture_name)) return error.UndeclaredGoldenFixture;
    if (declared.emitted_paths.len != expected_paths.len) return error.GoldenTableDisagrees;
    for (expected_paths, declared.emitted_paths) |actual, wanted| {
        if (!std.mem.eql(u8, actual, wanted)) return error.GoldenTableDisagrees;
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
    _ = try expectPackageShape(&pkg, expected_paths, source_claims_tests);
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

    // 5. Emit every source file. A module file must carry emitted code: 0
    // bytes there is a truncation, not a shape. `src/root.zig` is the one file
    // allowed to emit nothing, and where a fixture pins text that is captured
    // by a 0-byte golden rather than waved through. A `typed` fixture emits
    // for exactly the same reason and then pins nothing.
    for (pkg.files) |*file| {
        const src = try backend.zig.emit.emitFile(allocator, file);
        defer allocator.free(src);
        if (src.len == 0 and !std.mem.eql(u8, file.path, "src/root.zig")) return error.EmptyEmit;
        if (coverage == .typed) continue;
        const source_payload = if (src[src.len - 1] == '\n') src[0 .. src.len - 1] else src;
        const source_golden_path = try std.fmt.allocPrint(
            allocator,
            "test/golden/zig_src/{s}/{s}",
            .{ fixture_name, file.path },
        );
        try checkGolden(allocator, test_io, source_golden_path, source_payload);
    }
    // What the root declares is not asserted here: it is a validity question
    // the boundary has answered, and each byte-pinned fixture's declarations
    // are pinned by its emitted-source golden text above.
}

test "golden: mini translates to canonical package" {
    try runGoldenFixture(
        "mini",
        "test/crates/mini",
        null,
        &.{ "src/root.zig", "src/util.zig" },
        false,
        false,
    );
}
// `fnv`'s snapshot layers are table indices and generated-label numbering, so
// this row pins no bytes: it states that the crate still analyses, validates,
// lowers to a valid one-file package, and emits code, and the content claim
// lives in the typed-AST test further down.
test "golden: fnv source translates to a valid package" {
    try runGoldenFixture(
        "fnv",
        "test/crates/fnv",
        null,
        &.{"src/root.zig"},
        false,
        false,
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
    );
}

test "golden: wyhash source translates to pinned emitted package" {
    try runGoldenFixture(
        "wyhash",
        "test/crates/wyhash",
        null,
        &.{
            "src/root.zig",
            "src/functions.zig",
            "src/functions/tests.zig",
            "src/traits.zig",
        },
        true,
        true,
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
    );
}

// The four discovered modules must land on their own emitted files, with the
// `#[path]`-attributed module named after its declaration, not its source.
// `include_tests` matches `generate-multimod-golden`: `foo.rs` declares a
// `#[cfg(test)] mod tests`, so a false here cfg's that module out of the
// analysis and compares the other files against bytes regenerated with it
// present.
test "golden: multimod maps every discovered module to its own emitted file" {
    try runGoldenFixture(
        "multimod",
        "test/crates/multimod",
        null,
        &.{
            "src/root.zig",
            "src/foo.zig",
            "src/foo/bar.zig",
            "src/foo/tests.zig",
            "src/custom_pub.zig",
        },
        true,
        true,
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

/// The name a top-level declaration publishes, or null for a bare comment,
/// which publishes nothing.
fn declaredName(decl: backend.zig.ast.Decl) ?[]const u8 {
    return switch (decl) {
        .struct_decl => |value| value.name,
        .enum_decl => |value| value.name,
        .union_decl => |value| value.name,
        .fn_decl => |value| value.name,
        .const_decl => |value| value.name,
        .var_decl => |value| value.name,
        .trait_descriptor => |value| value.name,
        .comment => null,
    };
}

/// The top-level declaration `name` in `file`, whatever kind it lowers to. A
/// fixture contract asks "does this package still publish X", and a
/// declaration can legitimately land as a struct, a const or a generic
/// function without any of those being wrong — so this reports presence, and
/// the typed tests below ask the kind-specific questions separately.
fn topLevelDecl(file: *const backend.zig.ast.File, name: []const u8) ?backend.zig.ast.Decl {
    for (file.decls) |decl| {
        const published = declaredName(decl) orelse continue;
        if (std.mem.eql(u8, published, name)) return decl;
    }
    return null;
}

/// The top-level struct declaration `name`, or null when the package
/// publishes no struct by that name.
fn topLevelStruct(file: *const backend.zig.ast.File, name: []const u8) ?backend.zig.ast.StructDecl {
    for (file.decls) |decl| {
        if (decl == .struct_decl and std.mem.eql(u8, decl.struct_decl.name, name)) {
            return decl.struct_decl;
        }
    }
    return null;
}

/// The method `name` declared inside `container`, or null.
fn methodNamed(container: backend.zig.ast.StructDecl, name: []const u8) ?backend.zig.ast.FnDecl {
    for (container.decls) |decl| {
        if (decl == .fn_decl and std.mem.eql(u8, decl.fn_decl.name, name)) return decl.fn_decl;
    }
    return null;
}

/// Whether `file` carries an `@import` naming `module_or_path`.
fn importsModule(file: *const backend.zig.ast.File, module_or_path: []const u8) bool {
    for (file.imports) |entry| {
        if (std.mem.eql(u8, entry.module_or_path, module_or_path)) return true;
    }
    return false;
}

/// One file of `pkg` by its emitted path, or null.
fn packageFile(pkg: *const backend.zig.ast.Package, path: []const u8) ?*const backend.zig.ast.File {
    for (pkg.files) |*file| {
        if (std.mem.eql(u8, file.path, path)) return file;
    }
    return null;
}

// `fnv` is a `typed` fixture: what it must publish is stated here, against
// the typed AST, instead of against a RustIR document whose `ty` fields are
// row indices and a 129-line emitted file that is mostly the crate's rustdoc.
// Everything asserted here is something the package could actually lose.
test "golden: fnv publishes the hasher its source declares" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var rust_ir = try frontend.analyzeCrate(allocator, std.testing.io, "test/crates/fnv");
    defer rust_ir.deinitInstantiations(allocator);
    try ir.validateForTranslation(&rust_ir);
    const pkg = try backend.zig.lower.lowerRustIr(allocator, &rust_ir, null);
    const root = try expectPackageShape(&pkg, &.{"src/root.zig"}, false);

    // `pub struct FnvHasher(u64);` is a one-field tuple struct, so the field is
    // named "0" and its type is the u64 the source wrote. Emitting a named
    // field here would still compile and still hash correctly; it would be
    // the wrong declaration.
    const hasher = topLevelStruct(root, "FnvHasher") orelse return error.MissingFnvHasher;
    try std.testing.expect(hasher.is_pub);
    try std.testing.expectEqual(@as(usize, 1), hasher.fields.len);
    try std.testing.expectEqualStrings("0", hasher.fields[0].name);
    try std.testing.expectEqual(backend.zig.ast.Type{ .prim = .u64 }, hasher.fields[0].ty);

    // Every method the source declares, each with a body: an empty one would
    // still be a method, and the package would still build.
    const method_names = [_][]const u8{ "default", "with_key", "finish", "write" };
    for (method_names) |method_name| {
        const method = methodNamed(hasher, method_name) orelse {
            std.debug.print("fnv: FnvHasher no longer declares `{s}`\n", .{method_name});
            return error.MissingFnvMethod;
        };
        if (method.body == null) return error.EmptyFnvMethod;
    }

    // `default` and `with_key` are associated: the source writes them without
    // a receiver, so a receiver parameter here would mean the lowering picked
    // a different declaration of the same name.
    const constructor = methodNamed(hasher, "default").?;
    try std.testing.expectEqual(@as(usize, 0), constructor.params.len);
    const keyed = methodNamed(hasher, "with_key").?;
    try std.testing.expectEqual(@as(usize, 1), keyed.params.len);
    try std.testing.expectEqualStrings("key", keyed.params[0].name);
    try std.testing.expectEqual(backend.zig.ast.Type{ .prim = .u64 }, keyed.params[0].ty);

    // `finish(&self)` only reads, so its receiver is a const pointer; `write`
    // mutates, so its receiver is not. Collapsing the two would free or write
    // through storage the frame does not own.
    const finish = methodNamed(hasher, "finish").?;
    try std.testing.expectEqual(@as(usize, 1), finish.params.len);
    try std.testing.expectEqualStrings("self", finish.params[0].name);
    const finish_receiver = switch (finish.params[0].ty) {
        .ptr => |pointer| pointer,
        else => return error.FnvFinishReceiverIsNotAPointer,
    };
    try std.testing.expect(finish_receiver.is_const);

    const write = methodNamed(hasher, "write").?;
    try std.testing.expectEqual(@as(usize, 2), write.params.len);
    const write_receiver = switch (write.params[0].ty) {
        .ptr => |pointer| pointer,
        else => return error.FnvWriteReceiverIsNotAPointer,
    };
    try std.testing.expect(!write_receiver.is_const);
    try std.testing.expectEqualStrings("bytes", write.params[1].name);
    const bytes = switch (write.params[1].ty) {
        .slice => |slice| slice,
        else => return error.FnvWriteArgumentIsNotASlice,
    };
    try std.testing.expect(bytes.is_const);
    try std.testing.expectEqual(backend.zig.ast.Type{ .prim = .u8 }, bytes.elem.*);

    // The three public aliases the crate's own documentation promises.
    for ([_][]const u8{ "FnvBuildHasher", "FnvHashMap", "FnvHashSet" }) |alias| {
        if (topLevelDecl(root, alias) == null) {
            std.debug.print("fnv: root no longer publishes `{s}`\n", .{alias});
            return error.MissingFnvAlias;
        }
    }
}

// The same argument as `fnv`, at twenty times the volume. `hex` publishes a
// crate whose API is its whole point, so the contract is the module map, the
// imports that reach it, and the names the crate's docs promise — all read
// off the typed AST rather than off a 1955-line emitted file.
test "golden: hex publishes its error type and its decoders" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var rust_ir = try frontend.pipeline.analyzeCrateWithOptions(
        allocator,
        std.testing.io,
        "test/crates/hex",
        goldenAnalysisOptions(true),
    );
    defer rust_ir.deinitInstantiations(allocator);
    try ir.validateForTranslation(&rust_ir);
    const pkg = try backend.zig.lower.lowerRustIr(allocator, &rust_ir, null);
    // The shape check is still the contract on the module map and on the
    // translated tests the crate really carries; only the byte snapshots went.
    const root = try expectPackageShape(
        &pkg,
        &.{ "src/root.zig", "src/error.zig", "src/error/tests.zig", "src/test.zig" },
        true,
    );
    const error_file = packageFile(&pkg, "src/error.zig") orelse return error.MissingHexErrorModule;

    // The error type is declared by its own module and re-exported from the
    // root, which is the pair of names the generated decoders spell as
    // `r2z.Result(u8, error_1.FromHexError)`.
    if (topLevelDecl(error_file, "FromHexError") == null) return error.MissingHexErrorType;
    if (topLevelDecl(root, "FromHexError") == null) return error.MissingHexErrorReExport;

    // The module map, read off the import list: the root reaches its error
    // module and its test module, the error module reaches its own test child,
    // and the runtime is available to whichever of them needs it.
    try std.testing.expect(importsModule(root, "./error.zig"));
    try std.testing.expect(importsModule(root, "./test.zig"));
    try std.testing.expect(importsModule(error_file, "./error/tests.zig"));
    try std.testing.expect(importsModule(root, "r2z"));

    // The encoders and decoders the crate's rustdoc examples call.
    const published = [_][]const u8{
        "encode",
        "encode_upper",
        "encode_to_slice",
        "decode",
        "decode_to_slice",
        "from_hex",
        "BytesToHexChars",
    };
    for (published) |name| {
        if (topLevelDecl(root, name) == null) {
            std.debug.print("hex: root no longer publishes `{s}`\n", .{name});
            return error.MissingHexDeclaration;
        }
    }

    // `impl<'a> Iterator for BytesToHexChars` is what the decoder walks, so it
    // has to lower to a struct whose `next` is callable rather than to a bare
    // alias over the opaque carrier.
    const chars = topLevelStruct(root, "BytesToHexChars") orelse return error.MissingHexIteratorStruct;
    if (methodNamed(chars, "next") == null) return error.MissingHexIteratorNext;
    if (methodNamed(chars, "len") == null) return error.MissingHexIteratorLen;

    // `impl<'a, const N: usize> FromHex for [u8; N]` is monomorphised per array
    // length. What matters is that the per-length entry points exist at all,
    // not how the instantiation suffixes happen to be spelled, so this asks
    // for at least one and not for an exact set.
    const array_impl_prefix = "from_hex__u8_";
    var array_impls: usize = 0;
    for (root.decls) |decl| {
        const impl_name = declaredName(decl) orelse continue;
        if (std.mem.startsWith(u8, impl_name, array_impl_prefix)) array_impls += 1;
    }
    try std.testing.expect(array_impls > 0);
}

// Same reasoning as `fnv`, at twenty times the emitted volume: what `hex`
// must publish is stated against the typed AST below, not against two
// table-indexed JSON documents and a 1955-line file that is mostly the
// crate's own rustdoc.
test "golden: hex library and test module translate to a valid package" {
    try runGoldenFixture(
        "hex",
        "test/crates/hex",
        null,
        &.{ "src/root.zig", "src/error.zig", "src/error/tests.zig", "src/test.zig" },
        true,
        true,
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

/// Every file under `root_path`, as a path relative to that directory.
///
/// `Dir.walk` is not usable here. Its `Entry.kind` comes straight from the
/// directory read, and this repository lives on an NFSv3 mount that reports
/// `.unknown` for every entry — so a walker's `entry.kind != .file` skips the
/// whole tree, and the walk does not even descend, because it only enters an
/// entry it already knows is a directory. The golden-tree guard and the
/// naming corpus below both walked nothing and passed vacuously, which is how
/// `zig_src/hex/**` survived an earlier session as unread weight. `statFile`
/// is the one call that reports the real kind, so it is resolved per entry
/// here instead of trusted from the directory read.
fn walkFiles(
    allocator: std.mem.Allocator,
    test_io: std.Io,
    root_path: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var pending: std.ArrayList([]const u8) = .empty;
    defer {
        for (pending.items) |queued| allocator.free(queued);
        pending.deinit(allocator);
    }
    try pending.append(allocator, try allocator.dupe(u8, root_path));

    // Breadth-first over `pending`: a directory is appended with its own
    // children, so the walk terminates on any tree and needs no recursion
    // depth budget.
    var index: usize = 0;
    while (index < pending.items.len) : (index += 1) {
        const dir_path = pending.items[index];
        var dir = std.Io.Dir.cwd().openDir(test_io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
            // A directory that vanished between the listing and the open is
            // not this walk's business; anything else is.
            error.FileNotFound => continue,
            else => |other| return other,
        };
        defer dir.close(test_io);

        var entries = dir.iterate();
        while (try entries.next(test_io)) |entry| {
            const child_path = try std.fmt.allocPrint(
                allocator,
                "{s}/{s}",
                .{ dir_path, entry.name },
            );
            const stat = dir.statFile(test_io, entry.name, .{}) catch continue;
            switch (stat.kind) {
                .directory => try pending.append(allocator, child_path),
                .file => try out.append(allocator, child_path),
                else => allocator.free(child_path),
            }
        }
    }
}

/// `walkFiles` reduced to paths relative to `root_path`.
fn walkFilesRelative(
    allocator: std.mem.Allocator,
    test_io: std.Io,
    root_path: []const u8,
) ![][]const u8 {
    var absolute: std.ArrayList([]const u8) = .empty;
    try walkFiles(allocator, test_io, root_path, &absolute);
    const prefix_len = root_path.len + 1;
    for (absolute.items, 0..) |path, index| {
        absolute.items[index] = path[prefix_len..];
    }
    return absolute.toOwnedSlice(allocator);
}

/// Everything a test or build step says: `build.zig` plus every Zig source in
/// `test/`. A fixture counts as referenced only when one of those names it.
fn namingCorpus(allocator: std.mem.Allocator, test_io: std.Io) ![]const u8 {
    var corpus: std.ArrayList(u8) = .empty;
    try appendFileContents(&corpus, allocator, test_io, "build.zig");

    // Only `test/*.zig` names fixtures; `test/crates/**` and
    // `test/golden/**` are the fixtures themselves, not the tests, so the
    // depth filter is a slash count rather than a walk depth.
    const relative = try walkFilesRelative(allocator, test_io, "test");
    defer allocator.free(relative);
    for (relative) |path| {
        if (std.mem.indexOfScalar(u8, path, '/') != null) continue;
        if (!std.mem.endsWith(u8, path, ".zig")) continue;
        const full = try std.fmt.allocPrint(allocator, "test/{s}", .{path});
        try appendFileContents(&corpus, allocator, test_io, full);
    }
    return corpus.items;
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

// A snapshot that no assertion READS is invisible: it can drift from the
// translator and still be green. That is how `test/golden/zig_src/hex/**` sat
// unread while the emitted text changed underneath it.
//
// The earlier form of this walk asked the weaker question — "is this fixture's
// NAME quoted by some test or build step?" — and that is exactly the question
// that let the dead files through. `hex` and `fnv` are named in a dozen
// places, so every one of their bytes passed a name check while `runGoldenFixture`
// compared none of them, because both fixtures are `typed`. A file nobody reads
// and a file somebody reads are indistinguishable by name, so the walk now
// enumerates the paths some assertion opens — `expectedGoldenPaths`, derived
// from the same `golden_fixtures` table the fixtures themselves run from — and
// fails on any golden file outside that set.
test "every golden file is read by an assertion, and no wire fixture is orphaned" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const test_io = std.testing.io;

    // The set has to be non-empty or the walk below is checking nothing, which
    // is the failure mode this test exists to remove.
    var expected: std.ArrayList([]const u8) = .empty;
    try expectedGoldenPaths(allocator, &expected, "test/golden/");
    if (expected.items.len == 0) return error.GoldenHarnessUnreferenced;
    for (expected.items) |path| {
        // `relative` resolves both operands against `cwd` before walking them,
        // so the anchor has to be stated. These paths are repository-relative
        // and share a prefix, so anchoring at the root makes the result the
        // layout under `test/golden/` whatever the binary's cwd is; `null` is
        // the documented stand-in for an absent Windows per-drive cwd.
        if (goldenFixtureKey(std.fs.path.relative(allocator, "/", null, "test/golden", path) catch
            return error.GoldenHarnessUnreferenced) == null)
        {
            std.debug.print("expected golden path `{s}` has no known layout\n", .{path});
            return error.GoldenHarnessUnreferenced;
        }
    }

    const golden_files = try walkFilesRelative(allocator, test_io, "test/golden");
    defer allocator.free(golden_files);
    for (golden_files) |golden_path| {
        if (goldenFixtureKey(golden_path) == null) {
            std.debug.print("orphaned snapshot: `test/golden/{s}` has no known layout\n", .{golden_path});
            return error.OrphanedGolden;
        }
        const absolute = try std.fmt.allocPrint(allocator, "test/golden/{s}", .{golden_path});
        var read = false;
        for (expected.items) |path| {
            if (!std.mem.eql(u8, path, absolute)) continue;
            read = true;
            break;
        }
        if (read) continue;
        // Name the fixture whose table row would have to change to adopt this
        // file, because "nothing reads it" is a diagnosis and not a repair.
        const fixture_name = goldenFixtureKey(golden_path).?;
        const declared = declaredFixture(fixture_name);
        std.debug.print(
            "unread snapshot: `test/golden/{s}` is compared by no assertion." ++
                " Fixture `{s}` is declared `{s}`{s}, so either the file is dead" ++
                " weight left by an earlier re-pin or the table is understating" ++
                " what this fixture pins.\n",
            .{
                golden_path,
                fixture_name,
                if (declared) |row| @tagName(row.coverage) else "no-row",
                if (declared != null and declared.?.coverage == .typed)
                    " and therefore compares no bytes at all"
                else
                    "",
            },
        );
        return error.UnreadGolden;
    }

    // The wire fixtures keep the name-based check: nothing pins their bytes, so
    // being named by a node is all the claim they carry.
    const corpus = try namingCorpus(allocator, test_io);
    if (std.mem.indexOf(u8, corpus, "test/golden/zig_src/") == null) {
        return error.GoldenHarnessUnreferenced;
    }
    const wire_fixtures = try walkFilesRelative(allocator, test_io, "test");
    defer allocator.free(wire_fixtures);
    for (wire_fixtures) |wire_path| {
        if (std.mem.indexOfScalar(u8, wire_path, '/') != null) continue;
        if (!std.mem.endsWith(u8, wire_path, ".json")) continue;
        const reference = try std.fmt.allocPrint(allocator, "test/{s}", .{wire_path});
        if (std.mem.indexOf(u8, corpus, reference) != null) continue;
        std.debug.print(
            "orphaned fixture: `{s}` is named by no test or build step\n",
            .{reference},
        );
        return error.OrphanedFixture;
    }
}

// ── An owned parameter the body only reads ───────────────────────────────────
// The real extraction path, on source rather than on a hand-built model: a
// hand-built fixture states what the lowerer is handed, and a model that
// leaves an owner's population unstated can make a lowering look correct
// against a state the frontend would never produce. These four declarations
// are analysed by the frontend, validated as IR and lowered exactly as a
// staged crate is, so what the assertions below read is what the translator
// emits for Rust a user can write.
//
// The distinction the contract turns on is whether the parameter owns storage
// this frame has to release. `String` does, and Rust drops it when the frame
// ends, so the frame needs a mutable handle: the runtime releases a `String`
// through `deinit(self: *String, gpa)`, and a Zig parameter is immutable. A
// `&str` and a `Copy` `u32` own nothing, so both keep a plain signature and a
// body that releases nothing — a release there would free the caller's bytes.
const readonly_owner_source =
    \\pub fn read_only_text(text: String) -> usize {
    \\    text.len()
    \\}
    \\
    \\pub fn read_only_text_early(checked: bool, text: String) -> Result<usize, u8> {
    \\    if checked {
    \\        return Err(1u8);
    \\    }
    \\    Ok(text.len())
    \\}
    \\
    \\pub fn read_only_borrowed(text: &str) -> usize {
    \\    text.len()
    \\}
    \\
    \\pub fn read_only_scalar(count: u32) -> u32 {
    \\    count
    \\}
;

/// The declaration `name` in an emitted root file.
fn rootFnDecl(file: backend.zig.ast.File, name: []const u8) !backend.zig.ast.FnDecl {
    for (file.decls) |decl| {
        if (decl == .fn_decl and std.mem.eql(u8, decl.fn_decl.name, name)) return decl.fn_decl;
    }
    return error.MissingTranslatedFunction;
}

/// The one source parameter a frame declares. A comptime type parameter is an
/// artefact of the generic lowering rather than a source parameter, and a
/// second value parameter would make "the parameter" ambiguous, so both are
/// refused rather than guessed at.
fn rootSoleValueParam(decl: backend.zig.ast.FnDecl) !backend.zig.ast.FnParam {
    var found: ?backend.zig.ast.FnParam = null;
    for (decl.params) |param| {
        if (param.is_comptime) continue;
        if (found != null) return error.AmbiguousValueParameter;
        found = param;
    }
    return found orelse return error.MissingValueParameter;
}

/// The binding an expression is about: the receiver a field access or a
/// method call reads through, the payload of an `Ok(..)` the source returned,
/// or the value itself. Every other shape answers null rather than a guess, so
/// a read this cannot account for fails instead of passing on a name that
/// happened to appear nearby.
fn rootNamedTarget(expression: backend.zig.ast.Expr) ?[]const u8 {
    return rootNamedTargetAt(expression, 0);
}

fn rootNamedTargetAt(expression: backend.zig.ast.Expr, depth: usize) ?[]const u8 {
    if (depth >= 32) return null;
    switch (expression) {
        .ident => |name| return name,
        .field_access => |access| return rootNamedTargetAt(access.target.*, depth + 1),
        .call => |call_expr| return rootNamedTargetAt(call_expr.callee.*, depth + 1),
        .return_expr => |value| {
            const held = value orelse return null;
            return rootNamedTargetAt(held.*, depth + 1);
        },
        // `Ok(..)` names the value the source returned in a field; the read
        // that produced it is inside that field.
        .struct_init => |literal| {
            if (literal.fields.len == 0) return null;
            return rootNamedTargetAt(literal.fields[0].expr, depth + 1);
        },
        else => return null,
    }
}

/// Whether an expression reaches a `return`, looking only through blocks and
/// conditionals. A shape this does not traverse answers false, so one it has
/// not been taught cannot make a missing early exit look present.
fn rootContainsReturn(expression: backend.zig.ast.Expr, depth: usize) bool {
    if (depth >= 64) return false;
    switch (expression) {
        .return_expr => return true,
        .if_expr => |conditional| {
            if (rootContainsReturn(conditional.then_body.*, depth + 1)) return true;
            if (conditional.else_body) |otherwise| {
                return rootContainsReturn(otherwise.*, depth + 1);
            }
            return false;
        },
        .block => |block| {
            if (block.expr) |tail| {
                if (rootContainsReturn(tail.*, depth + 1)) return true;
            }
            for (block.stmts) |statement| {
                if (statement == .expr_stmt and
                    rootContainsReturn(statement.expr_stmt.*, depth + 1)) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// How one frame released a parameter it owned. A release armed inside a body
/// statement would be armed by that statement and would miss the exits taken
/// before it, so where it is armed matters as much as what it names.
const FrameRelease = struct {
    /// The mutable local the owned parameter's value was moved into.
    handle: []const u8,
    /// Where in the frame's own statement list the release is armed.
    armed_at: usize,
};

/// The one release this frame arms on the handle it declared for the parameter
/// it owns.
///
/// The chain starts at a DECLARATION rather than at a name: the handle is the
/// local initialised from a parameter the signature declares, and the release
/// has to name that same local. Nothing here depends on how the parameter or
/// the handle happens to be spelled.
fn frameOwnerRelease(decl: backend.zig.ast.FnDecl) !FrameRelease {
    const body = decl.body orelse return error.EmptyTranslatedBody;
    var parameter: ?backend.zig.ast.FnParam = null;
    var handle: ?[]const u8 = null;
    var handle_type: ?[]const u8 = null;
    for (body.stmts) |statement| {
        if (statement != .let_stmt) continue;
        const binding = statement.let_stmt;
        if (binding.init != .ident) continue;
        for (decl.params) |candidate| {
            if (candidate.is_comptime) continue;
            if (!std.mem.eql(u8, candidate.name, binding.init.ident)) continue;
            if (parameter != null) return error.DuplicateOwnerHandle;
            // The frame owns what this parameter owns BY VALUE. A borrow
            // arrives as a slice or a pointer and a `Copy` value as a
            // primitive; releasing either would free storage this frame never
            // owned.
            if (candidate.ty != .named) return error.OwnedParameterIsNotAValue;
            parameter = candidate;
            handle = binding.name;
            handle_type = switch (binding.ty orelse return error.UntypedOwnerHandle) {
                .named => |name| name,
                else => return error.UnexpectedOwnerType,
            };
        }
    }
    const owned = parameter orelse return error.MissingOwnerHandle;
    const owned_handle = handle orelse return error.MissingOwnerHandle;
    // The handle holds the parameter's own type: mutable storage the runtime
    // can release through a pointer, not a pointer onto the caller's value.
    try std.testing.expectEqualStrings(owned.ty.named, handle_type.?);

    var armed_at: ?usize = null;
    var releases: usize = 0;
    for (body.stmts, 0..) |statement, index| {
        if (statement != .defer_stmt) continue;
        releases += 1;
        const release = statement.defer_stmt;
        if (release.is_errdefer) return error.OwnerReleaseIsErrorDefer;
        if (release.expr != .call) return error.OwnerReleaseIsNotACall;
        const release_call = release.expr.call;
        // A transfer carries an explicit type argument and an element walk
        // takes the handle by address alongside the allocator. Neither can be
        // spelled as one plain method call on the handle.
        if (release_call.generic_args.len != 0) return error.OwnerReleasePassesAType;
        if (release_call.callee.* != .field_access) return error.OwnerReleaseIsNotAMethod;
        const method = release_call.callee.field_access;
        if (!std.mem.eql(u8, method.field_name, "deinit")) return error.OwnerReleaseIsNotDeinit;
        if (release_call.args.len != 1) return error.OwnerReleaseArgumentCount;
        if (release_call.args[0] != .ident) return error.OwnerReleaseAllocatorIsNotAnIdent;
        if (method.target.* != .ident) return error.OwnerReleaseTargetIsNotAHandle;
        if (!std.mem.eql(u8, method.target.ident, owned_handle)) {
            return error.ReleaseNamesAnotherHandle;
        }
        if (armed_at != null) return error.DuplicateOwnerRelease;
        armed_at = index;
    }
    // Exactly one release for the whole frame. A `defer` runs once per scope
    // exit, so a single one covers every exit the frame can take.
    try std.testing.expectEqual(@as(usize, 1), releases);
    return .{
        .handle = owned_handle,
        .armed_at = armed_at orelse return error.MissingOwnerRelease,
    };
}

/// The package's root file, which is where a single-module crate lands.
fn packageRootFile(pkg: *const backend.zig.ast.Package) !*const backend.zig.ast.File {
    for (pkg.files) |*file| {
        if (std.mem.eql(u8, file.path, "src/root.zig")) return file;
    }
    return error.MissingRootFile;
}

test "golden: an owned parameter the body only reads releases through one mutable handle" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var rust_ir = try frontend.pipeline.analyzeSourceWithOptions(
        allocator,
        "readonly_owner",
        "2021",
        readonly_owner_source,
        goldenAnalysisOptions(false),
    );
    defer rust_ir.deinitInstantiations(allocator);
    try ir.validateForTranslation(&rust_ir);
    const pkg = try backend.zig.lower.lowerRustIr(allocator, &rust_ir, null);
    const file = try packageRootFile(&pkg);

    // 1. The plain read. Rust drops the string when the frame ends, so the
    // frame has to release what the caller built, and it cannot do that on the
    // parameter: the runtime releases a `String` through `deinit(self: *String,
    // gpa)` and a Zig parameter is immutable. One mutable handle holds the
    // value, the read resolves the parameter's VALUE through it, and one
    // release frees it.
    const plain_decl = try rootFnDecl(file.*, "read_only_text");
    const plain = try frameOwnerRelease(plain_decl);
    const plain_body = plain_decl.body orelse return error.EmptyTranslatedBody;
    const plain_read = rootNamedTarget((plain_body.expr orelse
        return error.MissingTailExpression).*) orelse return error.BodyReadHasNoReceiver;
    try std.testing.expectEqualStrings(plain.handle, plain_read);
    // The release is armed in the frame's OWN statement list, immediately
    // after the mutable handle it names, so it is armed before every statement
    // the body runs.
    try std.testing.expect(plain.armed_at > 0);
    const declared = plain_body.stmts[plain.armed_at - 1];
    if (declared != .let_stmt) return error.OwnerReleaseIsNotArmedAfterItsHandle;
    try std.testing.expect(declared.let_stmt.is_mut);
    // Nothing is invented to answer a read of an owned value: no transfer out,
    // no deep copy, and no walk of elements the one buffer release covers.
    // None of the four declarations here may reach for any of them.
    const emitted = try backend.zig.emit.emitFile(allocator, file);
    for ([_][]const u8{ "dropTemporary", "takeOwned", "cloneFrom", ".clone(" }) |forbidden| {
        try std.testing.expect(std.mem.indexOf(u8, emitted, forbidden) == null);
    }

    // 2. The same read behind a fallible early return. That exit leaves the
    // frame from a nested scope, so the release has to be armed in the frame's
    // OWN statement list above that scope: armed inside the statement holding
    // the exit, it would never run on the exit itself. What has to hold is the
    // ORDER, so no statement ahead of the release carries an exit and at least
    // one behind it does — not that the exit is any particular statement.
    const fallible_decl = try rootFnDecl(file.*, "read_only_text_early");
    const fallible = try frameOwnerRelease(fallible_decl);
    const fallible_body = fallible_decl.body orelse return error.EmptyTranslatedBody;
    try std.testing.expect(fallible.armed_at > 0);
    var exits_after_release: usize = 0;
    for (fallible_body.stmts, 0..) |statement, index| {
        const carries_exit = statement == .expr_stmt and
            rootContainsReturn(statement.expr_stmt.*, 0);
        if (index <= fallible.armed_at) {
            if (carries_exit) return error.ExitAheadOfOwnerRelease;
            continue;
        }
        if (carries_exit) exits_after_release += 1;
    }
    try std.testing.expect(exits_after_release > 0);
    // The source's return value is intact: the tail still hands back what the
    // caller built, read through the handle this frame releases.
    const fallible_read = rootNamedTarget((fallible_body.expr orelse
        return error.MissingTailExpression).*) orelse return error.BodyReadHasNoReceiver;
    try std.testing.expectEqualStrings(fallible.handle, fallible_read);

    // 3. A borrow and a `Copy` value own nothing this frame may release, so
    // both keep a plain signature and a body that declares no handle and arms
    // no release. The read reaches the parameter itself.
    for ([_][]const u8{ "read_only_borrowed", "read_only_scalar" }) |name| {
        const decl = try rootFnDecl(file.*, name);
        const param = try rootSoleValueParam(decl);
        const body = decl.body orelse return error.EmptyTranslatedBody;
        var read: ?[]const u8 = null;
        for (body.stmts) |statement| {
            if (statement == .defer_stmt) return error.UnownedParameterIsReleased;
            if (statement == .let_stmt) return error.UnownedParameterIsCopied;
            if (statement == .expr_stmt) {
                read = rootNamedTarget(statement.expr_stmt.*) orelse read;
            }
        }
        if (body.expr) |tail| {
            read = rootNamedTarget(tail.*) orelse read;
        }
        try std.testing.expectEqualStrings(param.name, read orelse return error.MissingParameterRead);
    }
}
