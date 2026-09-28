//! End-to-end integration test for translate-rust (P7, "Drop the Sidecar").
//!
//! Executed as a small standalone program (see build.zig) so that child
//! processes spawned by `driver.translate` (the fingerprint-fix `zig build`)
//! run as normal processes. Zig's test runner (`--listen=-` protocol) cannot
//! reliably spawn grandchildren, so this is intentionally an executable.
//!
//! The mini, fnv, compat, wyhash, adler, hex and multimod source fixtures are
//! complete positive cases. Compat also runs through Rust IR and Zig AST
//! serialization. Multimod covers the three-file, two-level module→file
//! mapping (`foo.rs`→`foo.zig`, `foo/bar.rs`→`foo/bar.zig`,
//! `custom.rs`→`custom_pub.zig`) that no other fixture exercises. A staged
//! package counts as translated only when its sources hold emitted code, not
//! merely when the files exist. The legacy fnv and fletcher wire fixtures, and
//! the source fixtures whose analysis, lowering or package shape is
//! incomplete, must reject translation with a typed frontend, IR, or driver
//! error and no package output. The test also exercises the fingerprint
//! boundary with both failing and valid probes, and drives
//! `driver.translateWithOptions` to a published package with non-default
//! analysis options.

const std = @import("std");
const translate_rust = @import("translate_rust");
const driver = translate_rust.driver;

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

fn expectSourceCrateRejectedWithError(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    crate_dir: []const u8,
    out_dir: []const u8,
    expected_error: anyerror,
) !void {
    try deleteTreeIfExists(io, out_dir);
    defer deleteTreeIfExists(io, out_dir) catch {};

    try writeMsg(io, stdout, "e2e: rejecting unsupported source fixture `{s}`", .{crate_dir});
    if (driver.translate(gpa, io, crate_dir, out_dir)) |_| {
        return error.UnsupportedSourceTranslated;
    } else |err| {
        if (err != expected_error) return err;
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
/// top-level Zig items it must hold. Presence alone is not translation: a
/// zero-byte or item-less `src/root.zig` is a failed lowering that an
/// existence check happily reports as a translated crate.
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

/// Require `path` to hold real translated code, not merely to exist.
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

    const translated_test = try std.process.run(gpa, io, .{
        .argv = &.{
            "zig",
            "test",
            "--dep",
            "r2z",
            "-Mroot=src/test.zig",
            "-Mr2z=../../r2z-core/src/root.zig",
        },
        .cwd = .{ .path = out_dir },
    });
    defer gpa.free(translated_test.stdout);
    defer gpa.free(translated_test.stderr);
    const exit_code = switch (translated_test.term) {
        .exited => |code| code,
        else => return error.FnvTestModuleFailed,
    };
    if (exit_code != 0) {
        try stdout.writeStreamingAll(io, translated_test.stdout);
        try std.Io.File.stderr().writeStreamingAll(io, translated_test.stderr);
        return error.FnvTestModuleFailed;
    }

    try deleteTreeIfExists(io, out_dir);
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
    const consumer = try std.process.run(gpa, io, .{
        .argv = &.{
            "zig",
            "test",
            "--dep",
            "translated",
            "-Mroot=test/compat_consumer.zig",
            "--dep",
            "r2z",
            "-Mtranslated=zig-out/e2e-translated-compat/src/root.zig",
            "-Mr2z=r2z-core/src/root.zig",
        },
    });
    defer gpa.free(consumer.stdout);
    defer gpa.free(consumer.stderr);
    switch (consumer.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    try stdout.writeStreamingAll(io, consumer.stdout);
    try std.Io.File.stderr().writeStreamingAll(io, consumer.stderr);
    return error.CompatConsumerFailed;
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
        },
    );
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
    try expectWireCrateTranslated(
        init.gpa,
        io,
        stdout,
        "test/mini.json",
        "zig-out/e2e-translated-wire-mini",
    );
    try expectFnvSourceCrateTranslated(init.gpa, io, stdout);
    try expectCompatSourceCrateTranslated(init.gpa, io, stdout);
    try expectSourceCrateRejectedWithError(
        init.gpa,
        io,
        stdout,
        "test/crates/fletcher",
        "zig-out/e2e-rejected-source-fletcher",
        error.ExternalMacroSourceUnavailable,
    );
    try expectSourceCrateRejectedWithError(
        init.gpa,
        io,
        stdout,
        "test/crates/crc16",
        "zig-out/e2e-rejected-source-crc16",
        error.BuildScriptArtifactUnavailable,
    );
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
    // `xxhash-rust` analyses and lowers, but its `src/root.zig` carries no
    // declaration, so the package would publish a 0-byte root. Promotion must
    // reject it with the typed AST error instead of reporting success.
    try expectSourceCrateRejectedWithError(
        init.gpa,
        io,
        stdout,
        "test/crates/xxhash-rust",
        "zig-out/e2e-rejected-source-xxhash-rust",
        error.EmptyRootFile,
    );
    try expectAnalysisOptionsReachStagedPackage(init.gpa, io, stdout);
    try writeMsg(
        io,
        stdout,
        "e2e: mini/fnv/wyhash/adler/compat/hex/multimod translated; fletcher/crc16/xxhash-rust reject; fnv/fletcher wire rejected; translateWithOptions honoured",
        .{},
    );
}
