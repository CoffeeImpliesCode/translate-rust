//! End-to-end integration test for translate-rust (P7, "Drop the Sidecar").
//!
//! Executed as a small standalone program (see build.zig) so that child
//! processes spawned by `driver.translate` (the fingerprint-fix `zig build`)
//! run as normal processes. Zig's test runner (`--listen=-` protocol) cannot
//! reliably spawn grandchildren, so this is intentionally an executable.
//!
//! The mini, fnv, and compat source fixtures are complete positive cases. Compat
//! also runs through Rust IR and Zig AST serialization. The legacy fnv and
//! fletcher wire fixtures must reject translation with a typed frontend, IR, or
//! driver error and no package output. The test also exercises the
//! fingerprint boundary with both failing and valid probes.

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

fn expectFilePresent(io: std.Io, path: []const u8) !void {
    var cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, path, .{});
    file.close(io);
}

fn expectPackageFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
    relative_path: []const u8,
) !void {
    const path = try std.fs.path.join(gpa, &.{ out_dir, relative_path });
    defer gpa.free(path);
    try expectFilePresent(io, path);
}

fn expectSourceCrateTranslated(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    crate_dir: []const u8,
    out_dir: []const u8,
    expected_source_paths: []const []const u8,
) !void {
    try deleteTreeIfExists(io, out_dir);
    try expectOutputDirectoryAbsent(io, out_dir);
    errdefer deleteTreeIfExists(io, out_dir) catch {};

    try writeMsg(io, stdout, "e2e: translating complete source fixture `{s}`", .{crate_dir});
    try driver.translate(gpa, io, crate_dir, out_dir);
    try expectPackageFile(gpa, io, out_dir, "build.zig");
    try expectPackageFile(gpa, io, out_dir, "build.zig.zon");
    for (expected_source_paths) |source_path| {
        try expectPackageFile(gpa, io, out_dir, source_path);
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
    try expectPackageFile(gpa, io, out_dir, "build.zig");
    try expectPackageFile(gpa, io, out_dir, "build.zig.zon");
    try expectPackageFile(gpa, io, out_dir, "src/root.zig");

    try expectPackageFile(gpa, io, out_dir, "src/test.zig");

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
    try expectPackageFile(gpa, io, out_dir, "build.zig");
    try expectPackageFile(gpa, io, out_dir, "build.zig.zon");
    try expectPackageFile(gpa, io, out_dir, "src/root.zig");
    try expectPackageFile(gpa, io, out_dir, "src/util.zig");
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
        &.{ "src/root.zig", "src/util.zig" },
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
    try writeMsg(
        io,
        stdout,
        "e2e: mini/fnv/compat translated; fletcher/crc16 macro rejects; fnv/fletcher wire rejected",
        .{},
    );
}
