//! End-to-end integration test for translate-rust (P7, "Drop the Sidecar").
//!
//! Executed as a small standalone program (see build.zig) so that child
//! processes spawned by `driver.translate` (the fingerprint-fix `zig build`)
//! run as normal processes. Zig's test runner (`--listen=-` protocol) cannot
//! reliably spawn grandchildren, so this is intentionally an executable.
//!
//! Every source crate the corpus inventory in `test/generated_corpus.zig`
//! names is a row here, one way or the other. A crate that publishes a package
//! is a positive row: it is staged, its build script and manifest are checked
//! for the markers a consumable package needs, and its emitted files are
//! checked for real code rather than for their mere existence. A staged
//! package counts as translated only when its sources hold emitted code. What
//! a package *exports* is proved by a consumer calling it; this file never
//! matches text in an emitted source to claim an API exists.
//!
//! The positive rows are `mini`, `fnv`, `compat`, `wyhash`, `adler`, `hex`,
//! `multimod`, `xxhash-rust` under both its empty default and an explicit
//! `xxh32`, `percent-encoding` and `itoa`. Compat also runs through Rust IR
//! and Zig AST serialization. Multimod covers the three-file, two-level
//! module→file mapping (`foo.rs`→`foo.zig`, `foo/bar.rs`→`foo/bar.zig`,
//! `custom.rs`→`custom_pub.zig`) that no other fixture exercises. Fnv and
//! percent-encoding each compile and run a consumer against their staged
//! package, and itoa runs the shared consumer in
//! `test/promoted_crates_consumer.zig`.
//!
//! Alongside those sits the ownership block: sixteen fixture crates whose only
//! claim is a runtime ownership boundary — a zero-field struct shape, an
//! option reached through a mutable borrow, a payload moved out of a `Result`
//! arm, an owner held across a guard that falls through, an owner inside a
//! fixed-size array, an allocation that fails part way through, owners around
//! every exit a loop can take, the owned fields behind a named struct and
//! behind an enum variant, a borrowed payload handed over to an owning `Cow`,
//! an owner passed into a generic and handed back out through it, an owner
//! captured by a closure, an owner replaced in a place that already holds one,
//! and the intermediates an iterator chain builds behind an adapter. Each is
//! staged into its own directory and then compiled and RUN against the
//! consumer beside it, through `expectOwnershipFixtureTranslated`, so the
//! claim is an executed one. Four of the sixteen are red by construction and
//! stay that way until the defects they name are closed; the block above
//! their call sites says which.
//!
//! Every crate that must NOT publish a package is a row of
//! `refused_source_crates` below, each bound to the EXACT typed error it
//! refuses with. That table is the point of the negative half: a crate that
//! starts failing for a DIFFERENT reason fails this test instead of hiding
//! behind a generic "it rejected" claim, and a crate that starts succeeding
//! fails it too. A refusal is a statement that a construct cannot be
//! represented faithfully yet, never a licence to emit wrong Zig for valid
//! Rust.
//!
//! The test also exercises the fingerprint boundary with both failing and
//! valid probes, and drives `driver.translateWithOptions` to a published
//! package with non-default analysis options.

const std = @import("std");
const translate_rust = @import("translate_rust");
const driver = translate_rust.driver;

/// The compiler that built this program, resolved once by build.zig. Every
/// `zig test` below runs a generated or original module with it; a bare `zig`
/// would be whatever PATH finds, which is the anyzig shim outside a checkout
/// with a pinned version.
const zig_executable = @import("toolchain").zig_executable;

/// Where the `zig` children below must write their caches, resolved once by
/// build.zig from this build's own roots. A child with no `--cache-dir`
/// defaults to `<cwd>/.zig-cache` and `$HOME/.cache/zig`; this repository
/// lives on an NFSv3 mount, where Zig's atomic rename is not implemented and
/// writing either cache there aborts the child with EINVAL. `null` means the
/// build set no cache root, which leaves the compiler default in place.
const e2e_host = @import("e2e_host");

/// Run one `zig test` child and require it to exit 0. `args` follows the
/// `test` subcommand. Both streams of a failing child are forwarded before
/// `failure` is returned, so the compiler's own diagnostic reaches the log
/// instead of a bare error name. Routing every child through here is what
/// keeps one place responsible for the compiler and its cache roots.
fn runZigTest(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    args: []const []const u8,
    cwd: ?[]const u8,
    failure: anyerror,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, zig_executable);
    try argv.append(gpa, "test");
    if (e2e_host.local_cache_dir) |local_cache_dir| {
        try argv.append(gpa, "--cache-dir");
        try argv.append(gpa, local_cache_dir);
    }
    if (e2e_host.global_cache_dir) |global_cache_dir| {
        try argv.append(gpa, "--global-cache-dir");
        try argv.append(gpa, global_cache_dir);
    }
    try argv.appendSlice(gpa, args);

    const result = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    try stdout.writeStreamingAll(io, result.stdout);
    try std.Io.File.stderr().writeStreamingAll(io, result.stderr);
    return failure;
}

fn writeMsg(io: std.Io, out: std.Io.File, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(std.heap.page_allocator, fmt ++ "\n", args);
    defer std.heap.page_allocator.free(msg);
    try out.writeStreamingAll(io, msg);
}

/// Read a whole file into `allocator` (caller owns the returned slice).
fn readFileAlloc(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    var dir = std.Io.Dir.cwd();
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var io_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &io_buf);
    return reader.interface.allocRemaining(gpa, .limited(1 << 24));
}

fn deleteFileIfExists(io: std.Io, path: []const u8) !void {
    var cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn deleteTreeIfExists(io: std.Io, path: []const u8) !void {
    var cwd = std.Io.Dir.cwd();
    cwd.access(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try cwd.deleteTree(io, path);
}

fn expectOutputDirectoryAbsent(io: std.Io, out_dir: []const u8) !void {
    var cwd = std.Io.Dir.cwd();
    if (cwd.openDir(io, out_dir, .{})) |dir| {
        dir.close(io);
        return error.OutputDirectoryPresent;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
}

fn expectSourceCrateRejected(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    crate_dir: []const u8,
    out_dir: []const u8,
) !void {
    try expectOutputDirectoryAbsent(io, out_dir);

    try writeMsg(io, stdout, "e2e: rejecting incomplete source fixture `{s}`", .{crate_dir});
    if (driver.translate(gpa, io, crate_dir, out_dir)) |_| {
        return error.IncompleteSourceTranslated;
    } else |_| {}
    try expectOutputDirectoryAbsent(io, out_dir);
}

/// Reject a source crate, and bind it to the typed error it refuses with when
/// `expected_error` is one.
///
/// A null `expected_error` marks a row whose exact error the current tree does
/// not determine. That row is still an assertion — the crate must refuse and
/// must publish no package — but only its stop location is unpinned, and the
/// error that refused it is printed instead of compared, so the next run says
/// what the row should be pinned to. Printing rather than swallowing it is the
/// whole point: a row left unpinned without a receipt is a row nobody can
/// repair.
fn expectSourceCrateRejectedWithError(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    crate_dir: []const u8,
    out_dir: []const u8,
    expected_error: ?anyerror,
) !void {
    try deleteTreeIfExists(io, out_dir);
    defer deleteTreeIfExists(io, out_dir) catch {};

    try writeMsg(io, stdout, "e2e: rejecting unsupported source fixture `{s}`", .{crate_dir});
    if (driver.translate(gpa, io, crate_dir, out_dir)) |_| {
        return error.UnsupportedSourceTranslated;
    } else |err| {
        if (expected_error) |expected| {
            if (err != expected) return err;
        } else {
            try writeMsg(
                io,
                stdout,
                "e2e: `{s}` refused with `{s}`: RE-MEASURED, pin this row to it",
                .{ crate_dir, @errorName(err) },
            );
        }
    }
    try expectOutputDirectoryAbsent(io, out_dir);
}

fn expectWireCrateRejected(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    json_path: []const u8,
    out_dir: []const u8,
) !void {
    try expectOutputDirectoryAbsent(io, out_dir);

    try writeMsg(io, stdout, "e2e: rejecting incomplete wire fixture `{s}`", .{json_path});
    if (driver.translateWireJson(gpa, io, json_path, out_dir)) |_| {
        return error.IncompleteWireTranslated;
    } else |_| {}
    try expectOutputDirectoryAbsent(io, out_dir);
}

/// Reject `json_path` with an exact typed error, not merely any failure.
fn expectWireCrateRejectedWithError(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    json_path: []const u8,
    out_dir: []const u8,
    expected_error: anyerror,
) !void {
    try deleteTreeIfExists(io, out_dir);
    try expectOutputDirectoryAbsent(io, out_dir);
    errdefer deleteTreeIfExists(io, out_dir) catch {};

    try writeMsg(io, stdout, "e2e: rejecting foreign wire fixture `{s}`", .{json_path});
    if (driver.translateWireJson(gpa, io, json_path, out_dir)) |_| {
        return error.ForeignWireTranslated;
    } else |err| {
        if (err != expected_error) return err;
    }
    try expectOutputDirectoryAbsent(io, out_dir);
}

/// A source file the staged package must contain, together with the number of
/// top-level Zig items it must hold. Presence is the floor's job, not a
/// separate check: the file is opened, and what counts as content is decided
/// by the floor rather than by the byte count.
///
/// `minimum_items = 0` is the one request for a legitimately empty file. The
/// upstream xxhash manifest declares no `default` feature, so selecting
/// nothing cfg's out every module and the emitted root really is 0 bytes —
/// that is a valid package, not a truncation. Zero therefore means "this row
/// asserts the file is staged, not that it has content"; every other row asks
/// for content and keeps both the empty-file and the short-file failures.
const ExpectedSource = struct {
    path: []const u8,
    minimum_items: usize,
};

/// Count the top-level Zig items in a generated source file. Emitted items
/// always start at column 0; block terminators (`};`, `}`) and indented
/// continuation lines start with `}` or whitespace and never match a
/// declaration prefix.
fn countTopLevelItems(source: []const u8) usize {
    const item_prefixes = [_][]const u8{ "pub ", "const ", "var ", "test ", "comptime " };
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t' or line[0] == '}') continue;
        for (item_prefixes) |prefix| {
            if (std.mem.startsWith(u8, line, prefix)) {
                count += 1;
                break;
            }
        }
    }
    return count;
}

/// Require `path` to hold at least `minimum_items` top-level items. A caller
/// that asks for zero states only that the file is staged: this states no
/// contract on what is inside it, which is how a row whose configuration
/// legitimately produces an empty file says so.
fn expectGeneratedSource(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    path: []const u8,
    minimum_items: usize,
) !void {
    const source = try readFileAlloc(gpa, io, path);
    defer gpa.free(source);
    if (source.len == 0) {
        if (minimum_items == 0) return;
        try writeMsg(io, stdout, "e2e: staged source `{s}` is empty", .{path});
        return error.EmptyTranslatedFile;
    }
    const items = countTopLevelItems(source);
    if (items < minimum_items) {
        try writeMsg(
            io,
            stdout,
            "e2e: staged source `{s}` holds {d} top-level items, expected {d}",
            .{ path, items, minimum_items },
        );
        return error.TruncatedTranslatedFile;
    }
}

/// Require a generated manifest to carry the fields a consumable package
/// needs. A truncated `build.zig.zon` still opens, so this checks content.
fn expectGeneratedManifest(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    path: []const u8,
    required_markers: []const []const u8,
) !void {
    const text = try readFileAlloc(gpa, io, path);
    defer gpa.free(text);
    for (required_markers) |marker| {
        if (std.mem.indexOf(u8, text, marker) != null) continue;
        try writeMsg(io, stdout, "e2e: staged manifest `{s}` is missing `{s}`", .{ path, marker });
        return error.IncompleteGeneratedManifest;
    }
}

fn expectPathAbsent(io: std.Io, path: []const u8) !void {
    var cwd = std.Io.Dir.cwd();
    if (cwd.access(io, path, .{})) |_| {
        return error.UnexpectedStagedFile;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
}

/// Markers every generated `build.zig` must carry to be a real build script.
const build_script_markers = [_][]const u8{ "pub fn build", ".addTest(" };
/// Markers every generated `build.zig.zon` must carry to be a real manifest.
const package_manifest_markers = [_][]const u8{ ".name = ", ".fingerprint = ", ".version = " };

fn expectBuildScript(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    out_dir: []const u8,
) !void {
    const path = try std.fs.path.join(gpa, &.{ out_dir, "build.zig" });
    defer gpa.free(path);
    try expectGeneratedManifest(gpa, io, stdout, path, &build_script_markers);
}

fn expectPackageManifest(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    out_dir: []const u8,
) !void {
    const path = try std.fs.path.join(gpa, &.{ out_dir, "build.zig.zon" });
    defer gpa.free(path);
    try expectGeneratedManifest(gpa, io, stdout, path, &package_manifest_markers);
}

fn expectPackageFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    out_dir: []const u8,
    expected: ExpectedSource,
) !void {
    const path = try std.fs.path.join(gpa, &.{ out_dir, expected.path });
    defer gpa.free(path);
    try expectGeneratedSource(gpa, io, stdout, path, expected.minimum_items);
}

fn expectSourceCrateTranslated(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    crate_dir: []const u8,
    out_dir: []const u8,
    expected_sources: []const ExpectedSource,
) !void {
    try expectSourceCrateTranslatedWithOptions(
        gpa,
        io,
        stdout,
        crate_dir,
        out_dir,
        expected_sources,
        &.{},
        null,
    );
}

/// Translate `crate_dir` and require a published package whose sources hold
/// real emitted code. `options` selects the analysis configuration; `null`
/// means the production `driver.translate` defaults. `absent_source_paths`
/// must *not* be staged, which is how a non-default analysis option is shown
/// to have reached the frontend instead of being dropped.
fn expectSourceCrateTranslatedWithOptions(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    crate_dir: []const u8,
    out_dir: []const u8,
    expected_sources: []const ExpectedSource,
    absent_source_paths: []const []const u8,
    options: ?translate_rust.frontend.pipeline.AnalysisOptions,
) !void {
    try deleteTreeIfExists(io, out_dir);
    try expectOutputDirectoryAbsent(io, out_dir);
    errdefer deleteTreeIfExists(io, out_dir) catch {};

    try writeMsg(io, stdout, "e2e: translating complete source fixture `{s}`", .{crate_dir});
    if (options) |analysis_options| {
        try driver.translateWithOptions(gpa, io, crate_dir, out_dir, analysis_options);
    } else {
        try driver.translate(gpa, io, crate_dir, out_dir);
    }
    try expectBuildScript(gpa, io, stdout, out_dir);
    try expectPackageManifest(gpa, io, stdout, out_dir);
    for (expected_sources) |expected_source| {
        try expectPackageFile(gpa, io, stdout, out_dir, expected_source);
    }
    for (absent_source_paths) |absent_source_path| {
        const path = try std.fs.path.join(gpa, &.{ out_dir, absent_source_path });
        defer gpa.free(path);
        try expectPathAbsent(io, path);
    }
    try deleteTreeIfExists(io, out_dir);
}

fn expectFnvSourceCrateTranslated(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
) !void {
    const crate_dir = "test/crates/fnv";
    const out_dir = "zig-out/e2e-translated-source-fnv";
    try deleteTreeIfExists(io, out_dir);
    try expectOutputDirectoryAbsent(io, out_dir);
    errdefer deleteTreeIfExists(io, out_dir) catch {};

    try writeMsg(io, stdout, "e2e: translating complete source fixture `{s}`", .{crate_dir});
    try driver.translate(gpa, io, crate_dir, out_dir);
    try expectBuildScript(gpa, io, stdout, out_dir);
    try expectPackageManifest(gpa, io, stdout, out_dir);
    try expectPackageFile(
        gpa,
        io,
        stdout,
        out_dir,
        .{ .path = "src/root.zig", .minimum_items = 2 },
    );
    try expectPackageFile(
        gpa,
        io,
        stdout,
        out_dir,
        .{ .path = "src/test.zig", .minimum_items = 2 },
    );

    try runZigTest(
        gpa,
        io,
        stdout,
        &.{
            "--dep",
            "r2z",
            "-Mroot=src/test.zig",
            "-Mr2z=../../r2z-core/src/root.zig",
        },
        out_dir,
        error.FnvTestModuleFailed,
    );

    try deleteTreeIfExists(io, out_dir);
}

fn expectPercentEncodingSourceCrateTranslated(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
) !void {
    const out_dir = "zig-out/e2e-translated-source-percent-encoding";
    try deleteTreeIfExists(io, out_dir);
    defer deleteTreeIfExists(io, out_dir) catch {};
    try writeMsg(io, stdout, "e2e: translating percent-encoding and executing doctest and ownership consumers", .{});
    try driver.translate(gpa, io, "test/crates/percent-encoding", out_dir);
    try runZigTest(
        gpa,
        io,
        stdout,
        &.{
            "--dep",
            "translated",
            "--dep",
            "r2z",
            "-Mroot=test/percent_encoding_consumer.zig",
            "--dep",
            "r2z",
            "-Mtranslated=zig-out/e2e-translated-source-percent-encoding/src/root.zig",
            "-Mr2z=r2z-core/src/root.zig",
        },
        null,
        error.PercentEncodingConsumerFailed,
    );
}

/// Stage one ownership fixture and run its consumer against the staged
/// package. This is the `expectPercentEncodingSourceCrateTranslated` shape:
/// remove any stale output, translate the crate under test, then compile and
/// RUN the consumer with the staged `src/root.zig` as its module. The consumer
/// is the whole assertion — nothing here claims an API exists by matching text
/// in an emitted source, and a fixture whose lowering is wrong shows up as a
/// failing child rather than as a passing translation.
///
/// `--dep r2z` is passed twice, and the two are not interchangeable:
///
///   - The staged package gets it unconditionally. Whether a generated root
///     imports the runtime is the translator's decision — every crate that
///     hands out owned storage spells its types through it — and
///     under-supplying a module that does import it fails the child with "no
///     module named 'r2z'", which reads like a fixture defect rather than a
///     wiring one. A `--dep` nothing imports costs nothing.
///   - The consumer root gets it only when `consumer_imports_runtime` is set,
///     which is the one fact about a consumer this file cannot infer: whether
///     the source itself writes `@import("r2z")`.
fn expectOwnershipFixtureTranslated(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    crate_dir: []const u8,
    out_dir: []const u8,
    consumer_source: []const u8,
    consumer_imports_runtime: bool,
    failure: anyerror,
) !void {
    try deleteTreeIfExists(io, out_dir);
    defer deleteTreeIfExists(io, out_dir) catch {};
    try writeMsg(
        io,
        stdout,
        "e2e: translating `{s}` and executing `{s}`",
        .{ crate_dir, consumer_source },
    );
    try driver.translate(gpa, io, crate_dir, out_dir);

    const translated_module = try std.fmt.allocPrint(gpa, "-Mtranslated={s}/src/root.zig", .{out_dir});
    defer gpa.free(translated_module);
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    try args.appendSlice(gpa, &.{ "--dep", "translated" });
    if (consumer_imports_runtime) try args.appendSlice(gpa, &.{ "--dep", "r2z" });
    const consumer_module = try std.fmt.allocPrint(gpa, "-Mroot={s}", .{consumer_source});
    defer gpa.free(consumer_module);
    try args.appendSlice(gpa, &.{ consumer_module, "--dep", "r2z", translated_module });
    try args.append(gpa, "-Mr2z=r2z-core/src/root.zig");
    try runZigTest(gpa, io, stdout, args.items, null, failure);
}

/// `zero-field-shapes`: a zero-field tuple struct, a unit struct and a
/// braced struct each have to lower to the Zig shape the source form asks for
/// and to name the same nominal everywhere.
fn expectZeroFieldShapesTranslated(gpa: std.mem.Allocator, io: std.Io, stdout: std.Io.File) !void {
    try expectOwnershipFixtureTranslated(
        gpa,
        io,
        stdout,
        "test/crates/zero-field-shapes",
        "zig-out/e2e-translated-source-zero-field-shapes",
        "test/zero_field_shapes_consumer.zig",
        false,
        error.ZeroFieldShapesConsumerFailed,
    );
}

/// `option-ref-mut-index`: an optional reached through a mutable borrow, then
/// indexed. The two borrows overlap, so the consumer runs under the
/// leak-checking allocator.
fn expectOptionRefMutIndexTranslated(gpa: std.mem.Allocator, io: std.Io, stdout: std.Io.File) !void {
    try expectOwnershipFixtureTranslated(
        gpa,
        io,
        stdout,
        "test/crates/option-ref-mut-index",
        "zig-out/e2e-translated-source-option-ref-mut-index",
        "test/option_ref_mut_index_consumer.zig",
        false,
        error.OptionRefMutIndexConsumerFailed,
    );
}

/// `result-arm-payload-move`: a payload moved out of one `Result` arm. The
/// consumer reads the text back through the moved handle, so a frame that
/// released it twice, or not at all, fails the run.
fn expectResultArmPayloadMoveTranslated(gpa: std.mem.Allocator, io: std.Io, stdout: std.Io.File) !void {
    try expectOwnershipFixtureTranslated(
        gpa,
        io,
        stdout,
        "test/crates/result-arm-payload-move",
        "zig-out/e2e-translated-source-result-arm-payload-move",
        "test/result_arm_payload_consumer.zig",
        false,
        error.ResultArmPayloadConsumerFailed,
    );
}

/// `let-bound-result-match`: a `Result` bound to a name and then matched
/// through that name. This fixture currently exposes a genuine double-release
/// of the moved payload, and it is wired anyway: a red fixture naming a real
/// defect is worth more than a fixture quietly left out of the build, and the
/// assertion is not to be weakened to make it pass.
fn expectLetBoundResultMatchTranslated(gpa: std.mem.Allocator, io: std.Io, stdout: std.Io.File) !void {
    try expectOwnershipFixtureTranslated(
        gpa,
        io,
        stdout,
        "test/crates/let-bound-result-match",
        "zig-out/e2e-translated-source-let-bound-result-match",
        "test/let_bound_result_consumer.zig",
        false,
        error.LetBoundResultConsumerFailed,
    );
}

/// `shadowed-inner-owner`: an inner scope shadows an outer binding's name with
/// another owner of the same length. The two must stay distinct through the
/// shadowing, which is what makes the payload lengths in the consumer equal
/// on purpose.
fn expectShadowedInnerOwnerTranslated(gpa: std.mem.Allocator, io: std.Io, stdout: std.Io.File) !void {
    try expectOwnershipFixtureTranslated(
        gpa,
        io,
        stdout,
        "test/crates/shadowed-inner-owner",
        "zig-out/e2e-translated-source-shadowed-inner-owner",
        "test/shadowed_inner_owner_consumer.zig",
        false,
        error.ShadowedInnerOwnerConsumerFailed,
    );
}

/// `array-wrapped-owner`: an owner inside a fixed-size array, so one release
/// covers the whole carrier and no per-element walk may be invented.
fn expectArrayWrappedOwnerTranslated(gpa: std.mem.Allocator, io: std.Io, stdout: std.Io.File) !void {
    try expectOwnershipFixtureTranslated(
        gpa,
        io,
        stdout,
        "test/crates/array-wrapped-owner",
        "zig-out/e2e-translated-source-array-wrapped-owner",
        "test/array_wrapped_owner_consumer.zig",
        false,
        error.ArrayWrappedOwnerConsumerFailed,
    );
}

/// `allocator-failure-ownership`: an allocation that fails part way through,
/// so the cleanup has to release what was already built and nothing else. This
/// is the one consumer of the nine that writes `@import("r2z")` itself.
fn expectAllocatorFailureOwnershipTranslated(gpa: std.mem.Allocator, io: std.Io, stdout: std.Io.File) !void {
    try expectOwnershipFixtureTranslated(
        gpa,
        io,
        stdout,
        "test/crates/allocator-failure-ownership",
        "zig-out/e2e-translated-source-allocator-failure-ownership",
        "test/allocator_failure_ownership_consumer.zig",
        true,
        error.AllocatorFailureOwnershipConsumerFailed,
    );
}

/// `loop-ownership-exits`: owners acquired and released around every exit a
/// loop body can take, including the ones that leave through a `return`.
fn expectLoopOwnershipExitsTranslated(gpa: std.mem.Allocator, io: std.Io, stdout: std.Io.File) !void {
    try expectOwnershipFixtureTranslated(
        gpa,
        io,
        stdout,
        "test/crates/loop-ownership-exits",
        "zig-out/e2e-translated-source-loop-ownership-exits",
        "test/loop_ownership_consumer.zig",
        false,
        error.LoopOwnershipExitsConsumerFailed,
    );
}

/// `struct-field-owner-move`: owned fields reached through a named struct.
/// This fixture documents a boundary that is real today — a named struct is
/// not treated as an owner type, so its remaining owned fields get no
/// release — and its consumer asserts that boundary rather than papering over
/// it, so parts of it are red by construction until the gap is closed. The
/// assertion stands.
fn expectStructFieldOwnerMoveTranslated(gpa: std.mem.Allocator, io: std.Io, stdout: std.Io.File) !void {
    try expectOwnershipFixtureTranslated(
        gpa,
        io,
        stdout,
        "test/crates/struct-field-owner-move",
        "zig-out/e2e-translated-source-struct-field-owner-move",
        "test/struct_field_owner_consumer.zig",
        true,
        error.StructFieldOwnerConsumerFailed,
    );
}

/// `enum-variant-owner-move`: the owned fields behind an enum variant. Same
/// boundary as `struct-field-owner-move` — a named type is not an owner type
/// — asserted rather than worked around, so it is red by construction until
/// the gap closes.
fn expectEnumVariantOwnerMoveTranslated(gpa: std.mem.Allocator, io: std.Io, stdout: std.Io.File) !void {
    try expectOwnershipFixtureTranslated(
        gpa,
        io,
        stdout,
        "test/crates/enum-variant-owner-move",
        "zig-out/e2e-translated-source-enum-variant-owner-move",
        "test/enum_variant_owner_consumer.zig",
        false,
        error.EnumVariantOwnerConsumerFailed,
    );
}

/// `cow-handoff`: a borrowed payload handed over to an owning `Cow` and back,
/// including the borrowed, owned and UTF-8-error handoffs. The consumer reads
/// the owned result and the UTF-8 error's position back, so a frame that
/// released the caller's bytes, or kept two owners for one buffer, fails the
/// run rather than passing on a shape.
fn expectCowHandoffTranslated(gpa: std.mem.Allocator, io: std.Io, stdout: std.Io.File) !void {
    try expectOwnershipFixtureTranslated(
        gpa,
        io,
        stdout,
        "test/crates/cow-handoff",
        "zig-out/e2e-translated-source-cow-handoff",
        "test/cow_handoff_consumer.zig",
        true,
        error.CowHandoffConsumerFailed,
    );
}

/// `generic-owner-transfer`: an owner passed into a generic and handed back
/// out through it, plus the frame that keeps one alive beside the call. This
/// fixture documents a LIVE gap and says so in its own docs:
/// `ownedRuntimeContainerType` reaches `ownedRuntimeStorageAt(ty, 0, false)`,
/// so `allow_parameter` is false, a generic that DROPS its own `T` parameter
/// never arms a parameter release and leaks. The fixture routes its drop arm
/// through `Vec<T>` to stay on the working side of that boundary. Parts of it
/// are therefore red until the gap closes; the assertion stays.
fn expectGenericOwnerTransferTranslated(gpa: std.mem.Allocator, io: std.Io, stdout: std.Io.File) !void {
    try expectOwnershipFixtureTranslated(
        gpa,
        io,
        stdout,
        "test/crates/generic-owner-transfer",
        "zig-out/e2e-translated-source-generic-owner-transfer",
        "test/generic_owner_transfer_consumer.zig",
        true,
        error.GenericOwnerTransferConsumerFailed,
    );
}

/// `closure-capture-ownership`: an owner captured by a closure and released
/// when the closure's scope ends. The consumer's allocator records every
/// allocation and release that crossed it, so "released exactly once" is
/// measured rather than trusted.
fn expectClosureCaptureOwnershipTranslated(gpa: std.mem.Allocator, io: std.Io, stdout: std.Io.File) !void {
    try expectOwnershipFixtureTranslated(
        gpa,
        io,
        stdout,
        "test/crates/closure-capture-ownership",
        "zig-out/e2e-translated-source-closure-capture-ownership",
        "test/closure_capture_consumer.zig",
        true,
        error.ClosureCaptureOwnershipConsumerFailed,
    );
}

/// `overwritten-owner`: an owner a place ALREADY holds being replaced. The
/// frame owes exactly one release of what the place held — after the
/// replacement exists, and before it lands — and the consumer counts
/// allocations, releases and live blocks through a recording allocator, so a
/// missed release, a double free, a retained second reference and a
/// per-iteration accumulation each show up as a number the generated package
/// produced.
fn expectOverwrittenOwnerTranslated(gpa: std.mem.Allocator, io: std.Io, stdout: std.Io.File) !void {
    try expectOwnershipFixtureTranslated(
        gpa,
        io,
        stdout,
        "test/crates/overwritten-owner",
        "zig-out/e2e-translated-source-overwritten-owner",
        "test/overwritten_owner_consumer.zig",
        true,
        error.OverwrittenOwnerConsumerFailed,
    );
}

/// `iterator-chain-ownership`: an adapter in front of an iterator chain, whose
/// intermediates the frame owns and the caller does not. The consumer drives
/// each adapter, reads the bytes the chain collected, and then counts releases
/// through a recording allocator: a count that is short is an intermediate the
/// frame released early or forgot, a count that is long is one it
/// materialised, and a right count over non-distinct allocations is a chain
/// that aliased its owners onto one.
fn expectIteratorChainOwnershipTranslated(gpa: std.mem.Allocator, io: std.Io, stdout: std.Io.File) !void {
    try expectOwnershipFixtureTranslated(
        gpa,
        io,
        stdout,
        "test/crates/iterator-chain-ownership",
        "zig-out/e2e-translated-source-iterator-chain-ownership",
        "test/iterator_chain_consumer.zig",
        true,
        error.IteratorChainOwnershipConsumerFailed,
    );
}

/// `match-subject-handoff`: a `match` that moves its own subject's payload out
/// to the caller. `decode_utf8_lossy` in `percent-encoding` is the same shape —
/// it takes a `Cow<'_, [u8]>` and re-wraps the very bytes it was given — and the
/// defect it is here for is a use-after-free rather than a leak: a frame that
/// READS its subject where Rust moves it still holds the slab the returned
/// value names, so the caller reads freed bytes. The consumer counts the
/// releases the frame performed while it is still on the stack, so the failure
/// is a number that is wrong rather than a crash somewhere else.
///
/// The fixture's `kept_bytes` is the control: it matches without binding, so
/// the subject is never spent, and a rule that drained every match subject
/// would leak there instead.
fn expectMatchSubjectHandoffTranslated(gpa: std.mem.Allocator, io: std.Io, stdout: std.Io.File) !void {
    try expectOwnershipFixtureTranslated(
        gpa,
        io,
        stdout,
        "test/crates/match-subject-handoff",
        "zig-out/e2e-translated-source-match-subject-handoff",
        "test/match_subject_handoff_consumer.zig",
        true,
        error.MatchSubjectHandoffConsumerFailed,
    );
}

fn expectCompatSourceCrateTranslated(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
) !void {
    const out_dir = "zig-out/e2e-translated-compat";
    try deleteTreeIfExists(io, out_dir);
    defer deleteTreeIfExists(io, out_dir) catch {};
    try writeMsg(io, stdout, "e2e: translating runtime compatibility contracts", .{});
    try driver.translate(gpa, io, "test/crates/compat", out_dir);
    try expectCompatConsumer(gpa, io, stdout);
    try deleteTreeIfExists(io, out_dir);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var rust_ir = try translate_rust.frontend.pipeline.analyzeCrateWithOptions(
        allocator,
        io,
        "test/crates/compat",
        .{ .include_tests = true },
    );
    defer rust_ir.deinitInstantiations(allocator);
    const json = try translate_rust.ir.serialize.encode(allocator, &rust_ir);
    const json_path = "zig-out/e2e-compat.json";
    defer deleteFileIfExists(io, json_path) catch {};
    try writeFixture(io, json_path, json);
    try driver.translateWireJson(gpa, io, json_path, out_dir);
    try expectCompatConsumer(gpa, io, stdout);
    try deleteTreeIfExists(io, out_dir);

    const backend = translate_rust.backend.zig;
    const package = try backend.lower.lowerRustIr(allocator, &rust_ir, null);
    const ast_json = try backend.serialize.encode(allocator, &package);
    const decoded = try backend.serialize.decode(allocator, ast_json);
    try writeMsg(io, stdout, "e2e: executing serialized Zig AST compatibility contracts", .{});
    try driver.promotePackage(gpa, io, &decoded, out_dir);
    try expectCompatConsumer(gpa, io, stdout);
}

fn expectCompatConsumer(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
) !void {
    try runZigTest(
        gpa,
        io,
        stdout,
        &.{
            "--dep",
            "translated",
            "-Mroot=test/compat_consumer.zig",
            "--dep",
            "r2z",
            "-Mtranslated=zig-out/e2e-translated-compat/src/root.zig",
            "-Mr2z=r2z-core/src/root.zig",
        },
        null,
        error.CompatConsumerFailed,
    );
}

fn expectWireCrateTranslated(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    json_path: []const u8,
    out_dir: []const u8,
) !void {
    try deleteTreeIfExists(io, out_dir);
    try expectOutputDirectoryAbsent(io, out_dir);
    errdefer deleteTreeIfExists(io, out_dir) catch {};

    try writeMsg(io, stdout, "e2e: translating complete wire fixture `{s}`", .{json_path});
    try driver.translateWireJson(gpa, io, json_path, out_dir);
    try expectBuildScript(gpa, io, stdout, out_dir);
    try expectPackageManifest(gpa, io, stdout, out_dir);
    try expectPackageFile(
        gpa,
        io,
        stdout,
        out_dir,
        .{ .path = "src/root.zig", .minimum_items = 2 },
    );
    try expectPackageFile(
        gpa,
        io,
        stdout,
        out_dir,
        .{ .path = "src/util.zig", .minimum_items = 1 },
    );
    try deleteTreeIfExists(io, out_dir);
}

const canonical_unsupported_v6 =
    \\{
    \\  "format_version": 6,
    \\  "crate_name": "boundary",
    \\  "edition": "2021",
    \\  "sidecar": null,
    \\  "toolchain": null,
    \\  "crates": [{
    \\    "name": "boundary",
    \\    "edition": 2021,
    \\    "kind": "lib",
    \\    "root": 0,
    \\    "is_translated": true,
    \\    "deps": [],
    \\    "entities": [{
    \\      "id": 0,
    \\      "kind": "module",
    \\      "name": "",
    \\      "span": {"start_line": 1, "start_col": 1, "end_line": 1, "end_col": 1},
    \\      "visibility": {"kind": "public"},
    \\      "parent": null,
    \\      "resolved": null,
    \\      "renamed_to": null,
    \\      "attributes": []
    \\    }],
    \\    "modules": [{
    \\      "id": 0,
    \\      "kind": "root",
    \\      "name": "",
    \\      "parent": null,
    \\      "source_path": null,
    \\      "is_crate": true,
    \\      "is_extern": false,
    \\      "span": {"start_line": 1, "start_col": 1, "end_line": 1, "end_col": 1},
    \\      "items": [],
    \\      "attributes": []
    \\    }],
    \\    "uses": []
    \\  }],
    \\  "types": [],
    \\  "instantiations": [],
    \\  "bodies": {
    \\    "exprs": [{
    \\      "id": 0,
    \\      "span": {"start_line": 1, "start_col": 1, "end_line": 1, "end_col": 1},
    \\      "ty": null,
    \\      "kind": "unsupported",
    \\      "value": {"reason": "driver boundary regression", "suggested_version": "v2"}
    \\    }],
    \\    "stmts": [],
    \\    "pats": [],
    \\    "types": [],
    \\    "bodies": [{"owner": 0, "body": {"kind": "none"}}]
    \\  }
    \\}
;

fn writeFixture(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn expectOutputAbsenceRegression(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
) !void {
    const out_dir = "zig-out/e2e-stale-output-regression";
    var cwd = std.Io.Dir.cwd();
    try deleteTreeIfExists(io, out_dir);
    try cwd.createDirPath(io, out_dir);

    if (expectSourceCrateRejected(gpa, io, stdout, "test/crates/fletcher", out_dir)) |_| {
        return error.StaleOutputAccepted;
    } else |err| switch (err) {
        error.OutputDirectoryPresent => {},
        else => return err,
    }

    try deleteTreeIfExists(io, out_dir);
    try expectOutputDirectoryAbsent(io, out_dir);
}

fn expectUnsupportedIrRejected(gpa: std.mem.Allocator, io: std.Io) !void {
    const path = "zig-out/e2e-unsupported-v6.json";
    const out_dir = "zig-out/e2e-unsupported-package";
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "zig-out");
    try deleteFileIfExists(io, path);
    try expectOutputDirectoryAbsent(io, out_dir);
    try writeFixture(io, path, canonical_unsupported_v6);

    if (driver.translateWireJson(gpa, io, path, out_dir)) |_| {
        return error.UnsupportedIrReachedLowering;
    } else |err| {
        if (err != error.UnsupportedExpression) return err;
    }
    try expectOutputDirectoryAbsent(io, out_dir);
    try deleteFileIfExists(io, path);
}

fn expectWireV1Rejected(gpa: std.mem.Allocator, io: std.Io) !void {
    const path = "zig-out/e2e-wire-v1.json";
    const out_dir = "zig-out/e2e-wire-v1-package";
    const wire_v1 =
        \\{"format_version":1,"sidecar":null,"toolchain":null,"crates":[]}
    ;
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "zig-out");
    try deleteFileIfExists(io, path);
    try expectOutputDirectoryAbsent(io, out_dir);
    try writeFixture(io, path, wire_v1);

    if (driver.translateWireJson(gpa, io, path, out_dir)) |_| {
        return error.WireV1ReachedTranslation;
    } else |err| {
        if (err != error.UnsupportedWireVersion) return err;
    }
    try expectOutputDirectoryAbsent(io, out_dir);
    try deleteFileIfExists(io, path);
}

fn failingFingerprintProbe(
    _: std.mem.Allocator,
    _: std.Io,
    _: []const u8,
) anyerror!driver.FingerprintProbeResult {
    return error.TestFingerprintProbeFailure;
}

fn validFingerprintProbe(
    allocator: std.mem.Allocator,
    _: std.Io,
    _: []const u8,
) anyerror!driver.FingerprintProbeResult {
    return .{
        .term = .{ .exited = 0 },
        .stdout = try allocator.dupe(u8, "fingerprint: 0x81677af28f9d3b4e"),
        .stderr = &.{},
    };
}

fn expectFingerprintProbeFailuresPropagate(gpa: std.mem.Allocator, io: std.Io) !void {
    const out_dir = "zig-out/e2e-unused-fingerprint";
    try expectOutputDirectoryAbsent(io, out_dir);
    if (driver.fixFingerprintWithProbe(
        gpa,
        io,
        out_dir,
        failingFingerprintProbe,
    )) |_| {
        return error.FingerprintProbeFailureIgnored;
    } else |err| {
        if (err != error.TestFingerprintProbeFailure) return err;
    }
    try expectOutputDirectoryAbsent(io, out_dir);
}

fn expectValidFingerprintPatched(gpa: std.mem.Allocator, io: std.Io) !void {
    const out_dir = "zig-out/e2e-fingerprint-patch";
    const zon_path = "zig-out/e2e-fingerprint-patch/build.zig.zon";
    var cwd = std.Io.Dir.cwd();
    try deleteTreeIfExists(io, out_dir);
    try cwd.createDirPath(io, out_dir);

    try writeFixture(io, zon_path,
        \\.{
        \\    .name = .boundary,
        \\    .fingerprint = 0x0123456789abcdef,
        \\}
    );

    try driver.fixFingerprintWithProbe(gpa, io, out_dir, validFingerprintProbe);
    const zon = try readFileAlloc(gpa, io, zon_path);
    defer gpa.free(zon);
    if (std.mem.indexOf(
        u8,
        zon,
        ".fingerprint = 0x81677af28f9d3b4e",
    ) == null) return error.ValidFingerprintNotPatched;
    try deleteTreeIfExists(io, out_dir);
}

/// `driver.translate` is `translateWithOptions` with host defaults, so every
/// success path in this executable so far has gone through the default. Drive
/// the options-taking entry point itself to a published package: analysing
/// fnv with `include_tests = false` must drop the translated `#[cfg(test)]`
/// module, so the staged package carries `src/root.zig` and no
/// `src/test.zig`. The `include_tests = true` run above stages both files,
/// so the two runs together prove the option reaches the frontend and changes
/// the staged output instead of being dropped.
fn expectAnalysisOptionsReachStagedPackage(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
) !void {
    try writeMsg(
        io,
        stdout,
        "e2e: translating `test/crates/fnv` with include_tests = false",
        .{},
    );
    try expectSourceCrateTranslatedWithOptions(
        gpa,
        io,
        stdout,
        "test/crates/fnv",
        "zig-out/e2e-translated-source-fnv-without-tests",
        &.{.{ .path = "src/root.zig", .minimum_items = 2 }},
        &.{"src/test.zig"},
        .{
            .include_tests = false,
            .cfg = .{
                .features = &.{},
                .target_pointer_width = @bitSizeOf(usize),
                .docsrs = false,
            },
        },
    );
}

/// `itoa` is the one crate of the original promoted four that still publishes
/// a package. It is staged into its own directory, and the shared consumer in
/// `test/promoted_crates_consumer.zig` — which owns every vector — is compiled
/// and run against it, so the crate is covered by real execution rather than by
/// a claim that a translation happened.
///
/// `siphasher`, `seahash` and `atoi` analyse cleanly and still refuse at a
/// typed boundary, so they publish no package for a consumer to import and
/// have no row here: they are rows of `refused_source_crates` below. The day one
/// of them does publish a package, its refusal row fails with
/// `UnsupportedSourceTranslated`, which is what stops its vectors from quietly
/// disappearing from the consumer.
fn expectItoaCrateCompiled(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
) !void {
    const crate_dir = "test/crates/itoa";
    const out_dir = "zig-out/e2e-translated-source-itoa";
    defer deleteTreeIfExists(io, out_dir) catch {};

    try writeMsg(io, stdout, "e2e: promoting `{s}` into `{s}`", .{ crate_dir, out_dir });
    try deleteTreeIfExists(io, out_dir);
    try driver.translate(gpa, io, crate_dir, out_dir);
    try expectBuildScript(gpa, io, stdout, out_dir);
    try expectPackageManifest(gpa, io, stdout, out_dir);
    try expectPackageFile(
        gpa,
        io,
        stdout,
        out_dir,
        .{ .path = "src/root.zig", .minimum_items = 2 },
    );

    try writeMsg(io, stdout, "e2e: executing the shared promoted-crate consumer", .{});
    try runZigTest(
        gpa,
        io,
        stdout,
        &.{
            "--dep",
            "itoa",
            "--dep",
            "r2z",
            "-Mroot=test/promoted_crates_consumer.zig",
            "--dep",
            "r2z",
            "-Mitoa=zig-out/e2e-translated-source-itoa/src/root.zig",
            "-Mr2z=r2z-core/src/root.zig",
        },
        null,
        error.PromotedCratesConsumerFailed,
    );
}

/// Every source crate in the corpus that must refuse, with the one typed error
/// it refuses with and the construct that stops it.
///
/// The error is the contract, not a decoration: each row is compared against
/// the error the pipeline actually raised, so a crate that later refuses for a
/// different reason — or stops refusing at all — fails this executable instead
/// of moving silently between the two halves of this file. `stops_at` names
/// the boundary that raises it, because a bare error name says nothing about
/// which stage gave up, and the reason text the frontend records for an
/// unsupported node says nothing about the type of the operand that caused it.
///
/// `expected_error` is nullable for one reason only: a row whose exact error
/// the current tree does not determine. It is not a licence to guess — a
/// guessed value is worse than an absent one, because it fails on the error
/// name and reads as a measurement. Such a row says so in `stops_at`, still
/// asserts that the crate refuses, and has the refusing error printed so the
/// next run pins it.
const refused_source_crates = [_]struct {
    name: []const u8,
    expected_error: ?anyerror,
    stops_at: []const u8,
}{
    .{
        .name = "allocating-fmt",
        .expected_error = error.UnsupportedAllocatingFormatter,
        .stops_at = "its `Display` body allocates and the native `format` hook takes no allocator",
    },
    .{
        .name = "fletcher",
        .expected_error = error.ExternalMacroSourceUnavailable,
        .stops_at = "the checksum tables live behind external `macro_rules!` expansions",
    },
    .{
        .name = "crc16",
        .expected_error = error.BuildScriptArtifactUnavailable,
        .stops_at = "its `build.rs` table is an artifact no translation run can have produced",
    },
    .{
        .name = "leb128",
        .expected_error = error.UnsupportedExternalUse,
        .stops_at = "`tests/quickchecks.rs` opens with `use quickcheck;`, a re-export of a dev-dependency no mapped external declares",
    },
    .{
        .name = "siphasher",
        .expected_error = error.IncompleteGenericMetadata,
        .stops_at = "`validateInstantiations` finds an instantiation whose argument list does not match its declaration's generic arity",
    },
    .{
        .name = "seahash",
        .expected_error = error.UnsupportedPattern,
        .stops_at = "lowering a struct pattern that binds more than one field",
    },
    .{
        .name = "atoi",
        .expected_error = error.MissingExpressionType,
        .stops_at = "the BACKEND, not the frontend: `driver/pipeline.zig` validates before it lowers, so no node is left refused by the analysis and the emitter is the stage that gives up, on an expression whose type it could not read",
    },
    .{
        .name = "differential",
        .expected_error = null,
        .stops_at = "NEEDS RE-MEASUREMENT — no error is pinned here and none can be derived by reading. `error.UnsupportedExpression` reached this crate through `ir/validate.zig`'s refusal of a non-assertion `.unsupported` marker, and `src/frontend/ts_ext_test.zig` now runs `expectNothingLeftOpen` over this exact source, so that path is closed; the source carries no `assert!` at all, which is what the old count of 147 sanctioned markers counted. The backend hole `lower.zig` documents — `String::from_utf8(..).map_err(..)?` refusing as `UnsupportedStandardMethod` because the peel reached a tagged `.result` and missed the `core::result::Result` nominal — is closed by `taggedResultType`, so the error the README census measured for this crate no longer names it either. Which boundary it reaches now depends on emission order across the whole file, and reading cannot answer that",
    },
};

fn expectRefusedSourceCrates(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
) !void {
    for (refused_source_crates) |refused| {
        const crate_dir = try std.fmt.allocPrint(gpa, "test/crates/{s}", .{refused.name});
        defer gpa.free(crate_dir);
        const out_dir = try std.fmt.allocPrint(
            gpa,
            "zig-out/e2e-rejected-source-{s}",
            .{refused.name},
        );
        defer gpa.free(out_dir);
        if (refused.expected_error) |expected_error| {
            try writeMsg(
                io,
                stdout,
                "e2e: `{s}` must refuse with `{s}`: {s}",
                .{ refused.name, @errorName(expected_error), refused.stops_at },
            );
        } else {
            try writeMsg(
                io,
                stdout,
                "e2e: `{s}` must refuse, error NOT pinned: {s}",
                .{ refused.name, refused.stops_at },
            );
        }
        try expectSourceCrateRejectedWithError(
            gpa,
            io,
            stdout,
            crate_dir,
            out_dir,
            refused.expected_error,
        );
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdout = std.Io.File.stdout();
    try expectUnsupportedIrRejected(init.gpa, io);
    try expectWireV1Rejected(init.gpa, io);
    try expectFingerprintProbeFailuresPropagate(init.gpa, io);
    try expectValidFingerprintPatched(init.gpa, io);
    try expectOutputAbsenceRegression(init.gpa, io, stdout);
    try expectSourceCrateTranslated(
        init.gpa,
        io,
        stdout,
        "test/crates/mini",
        "zig-out/e2e-translated-source-mini",
        &.{
            .{ .path = "src/root.zig", .minimum_items = 2 },
            .{ .path = "src/util.zig", .minimum_items = 1 },
        },
    );
    // The pristine upstream 0.4.0 crate: `mod traits;` is unconditional, so a
    // complete translation stages it beside the root, the `functions` module
    // and that module's `#[cfg(test)]` child. The floors are this file's
    // usual ones — 2 for the root and for `functions`, 1 for the module files.
    // Promotion runs the crate's own translated tests before publishing, so
    // `functions` and its test child are exercised for real; what `traits`
    // exports is a consumer question no consumer in this tree asks yet, and
    // this row does not claim otherwise.
    try expectSourceCrateTranslated(
        init.gpa,
        io,
        stdout,
        "test/crates/wyhash",
        "zig-out/e2e-translated-source-wyhash",
        &.{
            .{ .path = "src/root.zig", .minimum_items = 2 },
            .{ .path = "src/functions.zig", .minimum_items = 2 },
            .{ .path = "src/functions/tests.zig", .minimum_items = 1 },
            .{ .path = "src/traits.zig", .minimum_items = 1 },
        },
    );
    // adler's manifest declares `default = ["std"]`, and selecting no feature
    // means "the manifest default", so this row translates the `std`
    // configuration — the crate's own test module included. It proves the
    // package publishes and holds the full module map, nothing more: what the
    // `std` surface exports is a consumer question, and no consumer in this
    // tree reads a `BufRead` through the generated `adler32` yet. A count
    // floor here would pass just as well on a package that dropped the whole
    // `std` surface, so this row deliberately does not pretend otherwise.
    try expectSourceCrateTranslated(
        init.gpa,
        io,
        stdout,
        "test/crates/adler",
        "zig-out/e2e-translated-source-adler",
        &.{
            .{ .path = "src/root.zig", .minimum_items = 2 },
            .{ .path = "src/algo.zig", .minimum_items = 1 },
            .{ .path = "src/tests.zig", .minimum_items = 1 },
        },
    );
    try expectSourceCrateTranslated(
        init.gpa,
        io,
        stdout,
        "test/crates/hex",
        "zig-out/e2e-translated-source-hex",
        &.{
            .{ .path = "src/root.zig", .minimum_items = 2 },
            .{ .path = "src/error.zig", .minimum_items = 1 },
            .{ .path = "src/test.zig", .minimum_items = 1 },
        },
    );
    // `multimod` maps three discovered modules onto three emitted files:
    // `foo.rs`→`foo.zig`, the nested `foo/bar.rs`→`foo/bar.zig`, and the
    // `#[path = "custom.rs"]` module `custom_pub`→`custom_pub.zig`. Nothing
    // else in the suite lowers or emits this fixture.
    try expectSourceCrateTranslated(
        init.gpa,
        io,
        stdout,
        "test/crates/multimod",
        "zig-out/e2e-translated-source-multimod",
        &.{
            .{ .path = "src/root.zig", .minimum_items = 2 },
            .{ .path = "src/foo.zig", .minimum_items = 1 },
            .{ .path = "src/foo/bar.zig", .minimum_items = 1 },
            .{ .path = "src/custom_pub.zig", .minimum_items = 1 },
        },
    );

    // The upstream 0.8.15 manifest declares no `default` feature, so there are
    // two distinct configurations and both are exercised.
    //
    // `driver.translate` selects no feature at all, which is not "no std" and
    // not "no modules": it means the manifest default closure, and here that
    // closure is empty. Every module in the crate — `utils` and
    // `xxh32_common` included — sits behind `#[cfg(any(feature = ...))]`, so
    // none survives and the root carries no re-export.
    //
    // The package it publishes is one Cargo would build and consume, so the
    // row is a positive one: the default configuration must publish.
    //
    // What this row pins is the configuration, not the root's byte count. The
    // five absent paths are the measurement: they prove cfg selection reached
    // the frontend and cfg'd every module out. The build-script and manifest
    // markers prove the published package is a consumable one. That an empty
    // root follows from those two facts, but the count of bytes in it is an
    // incidental consequence of this fixture's current re-exports, so it is not
    // pinned: a golden or an exact byte count here would fail the moment the
    // same empty closure legitimately re-exported something, without any of
    // the configuration facts above having changed.
    try expectSourceCrateTranslatedWithOptions(
        init.gpa,
        io,
        stdout,
        "test/crates/xxhash-rust",
        "zig-out/e2e-translated-source-xxhash-rust-default",
        &.{.{ .path = "src/root.zig", .minimum_items = 0 }},
        &.{
            "src/utils.zig",
            "src/xxh32_common.zig",
            "src/xxh32.zig",
            "src/xxh64.zig",
            "src/xxh3.zig",
        },
        null,
    );
    // The explicit `xxh32` selection is a different configuration and does
    // carry modules, so it is a second positive row: the staged package holds
    // the root plus `utils`, `xxh32_common` and `xxh32`. The floors are this
    // file's usual ones.
    try expectSourceCrateTranslatedWithOptions(
        init.gpa,
        io,
        stdout,
        "test/crates/xxhash-rust",
        "zig-out/e2e-translated-source-xxhash-rust",
        &.{
            .{ .path = "src/root.zig", .minimum_items = 2 },
            .{ .path = "src/utils.zig", .minimum_items = 1 },
            .{ .path = "src/xxh32_common.zig", .minimum_items = 1 },
            .{ .path = "src/xxh32.zig", .minimum_items = 1 },
        },
        &.{},
        .{
            .include_tests = true,
            .cfg = .{
                .features = &.{"xxh32"},
                .target_pointer_width = @bitSizeOf(usize),
                .docsrs = false,
            },
        },
    );
    try expectWireCrateTranslated(
        init.gpa,
        io,
        stdout,
        "test/mini.json",
        "zig-out/e2e-translated-wire-mini",
    );
    try expectFnvSourceCrateTranslated(init.gpa, io, stdout);
    try expectCompatSourceCrateTranslated(init.gpa, io, stdout);
    try expectPercentEncodingSourceCrateTranslated(init.gpa, io, stdout);
    //
    // ── the ownership fixtures ─────────────────────────────────────────
    // One row per fixture crate under `test/crates/` that exists to pin a
    // runtime ownership boundary. Each stages its crate and then compiles and
    // RUNS the consumer beside it, most of them under the leak-checking
    // allocator, so every claim below is an executed one rather than a
    // statement that a translation happened.
    //
    // Four of these are RED against the current lowering, by construction and
    // on purpose. `let-bound-result-match` exposes a genuine double-release of
    // a moved payload out of a let-bound owning `Result` carrier.
    // `struct-field-owner-move` and `enum-variant-owner-move` document that a
    // NAMED struct is not treated as an owner type, so a struct's or an enum
    // variant's remaining owned fields get no release; their consumers assert
    // that boundary instead of papering over it. `generic-owner-transfer`
    // documents that `ownedRuntimeContainerType` asks for
    // `ownedRuntimeStorageAt(ty, 0, false)`, so a generic that DROPS its own
    // `T` parameter never arms a parameter release and leaks. A red fixture
    // naming a real defect is worth more than a fixture quietly left out of
    // the build, so no row here is weakened and no row is commented out to go
    // green.
    try expectZeroFieldShapesTranslated(init.gpa, io, stdout);
    try expectOptionRefMutIndexTranslated(init.gpa, io, stdout);
    try expectResultArmPayloadMoveTranslated(init.gpa, io, stdout);
    try expectLetBoundResultMatchTranslated(init.gpa, io, stdout);
    try expectShadowedInnerOwnerTranslated(init.gpa, io, stdout);
    // `test/guarded_owned_fallthrough_consumer.zig` is the reproducer for an open
    // lowering gap and stays unwired until it closes: an owned variant field whose
    // pattern is a wildcard is bound by neither `matchCapturePayload`'s
    // `.struct_pat` branch nor `emitMatchDestructureBody`, so it is never released.
    try expectArrayWrappedOwnerTranslated(init.gpa, io, stdout);
    try expectAllocatorFailureOwnershipTranslated(init.gpa, io, stdout);
    try expectLoopOwnershipExitsTranslated(init.gpa, io, stdout);
    try expectStructFieldOwnerMoveTranslated(init.gpa, io, stdout);
    try expectEnumVariantOwnerMoveTranslated(init.gpa, io, stdout);
    try expectCowHandoffTranslated(init.gpa, io, stdout);
    try expectGenericOwnerTransferTranslated(init.gpa, io, stdout);
    try expectClosureCaptureOwnershipTranslated(init.gpa, io, stdout);
    try expectOverwrittenOwnerTranslated(init.gpa, io, stdout);
    try expectIteratorChainOwnershipTranslated(init.gpa, io, stdout);
    try expectMatchSubjectHandoffTranslated(init.gpa, io, stdout);
    try expectWireCrateRejected(
        init.gpa,
        io,
        stdout,
        "test/fnv.json",
        "zig-out/e2e-rejected-wire-fnv",
    );
    try expectWireCrateRejected(
        init.gpa,
        io,
        stdout,
        "test/fletcher.json",
        "zig-out/e2e-rejected-wire-fletcher",
    );
    // A complete, well-formed JSON dump from a different toolchain: it parses
    // and carries its own `format_version`, so the wire boundary must reject
    // it on the version rather than on a parse error.
    try expectWireCrateRejectedWithError(
        init.gpa,
        io,
        stdout,
        "test/mini-rustdoc.json",
        "zig-out/e2e-rejected-wire-mini-rustdoc",
        error.UnsupportedWireVersion,
    );
    // `itoa` used to sit below with `siphasher`, `atoi` and `seahash`: all four
    // were refused for an unresolved nominal type path, an unresolved call
    // target and an external nominal type with no resolved inference. `itoa` is
    // a positive row now: it is staged, then compiled and run by the shared
    // consumer. The other three analyse and still refuse, so their rows are
    // refusals below rather than staged packages with nothing to run.
    try expectItoaCrateCompiled(init.gpa, io, stdout);
    //
    // What is left stops where coverage stops. Each fixture in
    // `refused_source_crates` exercises a construct the frontend, the IR
    // validator or the backend AST does not model, so the crate must reject
    // rather than publish a wrong package. Refusing is not a licence to emit
    // wrong Zig — wrong output for valid Rust is a defect wherever it appears.
    // The contract pins the EXACT typed error each crate refuses with, so a
    // change in which error a crate fails with fails here instead of hiding
    // inside a generic "it rejected" claim — except for the one row whose exact
    // error the current tree does not determine, which is marked unpinned
    // rather than guessed at and prints the error it refused with.
    try expectRefusedSourceCrates(init.gpa, io, stdout);
    try expectAnalysisOptionsReachStagedPackage(init.gpa, io, stdout);
    try writeMsg(
        io,
        stdout,
        "e2e: mini/fnv/wyhash/adler/hex/multimod/compat/percent-encoding translated and itoa promoted through the shared consumer, xxhash-rust published under both its empty default and an explicit xxh32; allocating-fmt/fletcher/crc16/leb128/siphasher/seahash/atoi refused with pinned typed errors and differential refused with its error unpinned pending re-measurement; fnv/fletcher/mini-rustdoc wire rejected; sixteen ownership fixtures each executed against a staged package; translateWithOptions honoured",
        .{},
    );
}
