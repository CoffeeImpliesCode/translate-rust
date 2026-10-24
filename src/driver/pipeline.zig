//! translate_rust.driver.pipeline — full end-to-end translation pipeline.
//!
//! Orchestrates the complete pipeline:
//! Rust Source / Wire JSON -> Frontend Analysis -> RustIr -> Backend Lowering ->
//! ZigAST Package -> Staged Package Validation, Build Test, and Atomic Promotion.

const std = @import("std");
const ir = @import("translate_rust.ir");
const frontend = @import("translate_rust.frontend");
const backend = @import("translate_rust.backend");

/// The compiler running this build, resolved once by build.zig. The fingerprint
/// probe builds the staged package, and a bare `zig` would be whatever PATH
/// names: the anyzig shim resolves on every invocation and fails silently
/// outside a checkout that pins a version.
const zig_executable = @import("toolchain").zig_executable;

/// Error reported when the driver rejects a wire version before canonical decode.
pub const WireCompatibilityError = error{
    UnsupportedWireVersion,
};

/// The process result consumed by the fingerprint patcher.
pub const FingerprintProbeResult = struct {
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
};

pub const FingerprintProbe = *const fn (
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
) anyerror!FingerprintProbeResult;

/// Errors reported when the fingerprint probe does not produce one usable value.
pub const FingerprintError = error{
    ProbeNonZero,
    ProbeTerminated,
    ProbeOutputUnrecognized,
    ProbeOutputAmbiguous,
    ManifestFingerprintMissing,
};

/// Read a whole file into memory with allocation.
pub fn readFileAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]const u8 {
    var dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var io_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &io_buf);
    return reader.interface.allocRemaining(allocator, .limited(1 << 30));
}

fn decodeWireJson(
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
) !ir.serialize.RustIr {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.BadWireFormat,
    };
    const version_value = root.get("format_version") orelse return error.MissingField;
    const version = switch (version_value) {
        .integer => |value| blk: {
            if (value < 0 or value > @as(i128, std.math.maxInt(u32))) return error.BadWireFormat;
            break :blk @as(u32, @intCast(value));
        },
        else => return error.BadWireFormat,
    };
    if (version != ir.serialize.wire_format_version) {
        return error.UnsupportedWireVersion;
    }
    return ir.serialize.decode(allocator, json_bytes);
}

/// Package promotion hooks are public so driver tests can force build
/// failures and inspect the publish boundary without writing partial output.
pub const PackagePromotionHooks = backend.zig.package.PromotionHooks;
pub const PackagePromotionError = backend.zig.package.PromotionError;
pub const PackageBuildTestResult = backend.zig.package.BuildTestResult;
pub const PackageFillPromotionNonce = backend.zig.package.FillPromotionNonce;
pub const PackageRunBuildTest = backend.zig.package.RunBuildTest;
pub const PackageResolveFingerprint = backend.zig.package.ResolveFingerprint;

/// Promote an already lowered package with production staging, build, and
/// fingerprint behavior.
pub fn promotePackage(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg: *const backend.zig.ast.Package,
    out_dir: []const u8,
) !void {
    return backend.zig.package.promoteToDisk(allocator, io, pkg, out_dir);
}

/// Promote a package through injectable build and fingerprint seams.
pub fn promotePackageWithHooks(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg: *const backend.zig.ast.Package,
    out_dir: []const u8,
    hooks: PackagePromotionHooks,
) !void {
    return backend.zig.package.promoteWithHooks(allocator, io, pkg, out_dir, hooks);
}

/// Translate a Rust crate directory into a standalone Zig package at `out_dir`
/// using the default host analysis configuration. No feature selection is
/// made here, so the manifest's `default` feature closure applies.
pub fn translate(
    allocator: std.mem.Allocator,
    io: std.Io,
    crate_dir: []const u8,
    out_dir: []const u8,
) !void {
    return translateWithFeatures(allocator, io, crate_dir, out_dir, &.{});
}

/// Translate a Rust crate directory with an explicit `#[cfg(feature = ...)]`
/// selection. An empty `features` list means no selection was made, so the
/// manifest's `default` feature closure applies; a non-empty list replaces it.
pub fn translateWithFeatures(
    allocator: std.mem.Allocator,
    io: std.Io,
    crate_dir: []const u8,
    out_dir: []const u8,
    features: []const []const u8,
) !void {
    return translateWithOptions(allocator, io, crate_dir, out_dir, .{
        .include_tests = true,
        .cfg = .{
            .features = features,
            .target_pointer_width = @bitSizeOf(usize),
            .docsrs = false,
        },
    });
}

/// Translate a Rust crate directory with explicit frontend analysis options.
/// The package is generated in a sibling staging directory and is not
/// published until its manifest, sources, and `zig build test` pass.
/// An empty `cfg.features` is not "no features": it means no selection was
/// made, so the manifest's `default` feature closure applies.
pub fn translateWithOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    crate_dir: []const u8,
    out_dir: []const u8,
    options: frontend.pipeline.AnalysisOptions,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // 1. Ingest & analyze
    var rust_ir = try frontend.pipeline.analyzeCrateWithOptions(
        arena_alloc,
        io,
        crate_dir,
        options,
    );
    defer rust_ir.deinitInstantiations(arena_alloc);

    // 2. Validate before lowering. Invalid IR must not reach a package writer.
    try ir.validateForTranslation(&rust_ir);
    const pkg = try backend.zig.lower.lowerRustIr(arena_alloc, &rust_ir, null);

    // 3. Stage, test, fingerprint, and publish as one promotion.
    try promotePackage(arena_alloc, io, &pkg, out_dir);
}

/// Which boundary of INPUT AVAILABILITY a translation refusal sits on.
///
/// These four are not lowering limits. Each one is raised because the run asked
/// for an input it cannot have: an artifact only a build script can produce, a
/// macro body only another crate's source can define, a crate root no manifest
/// entry admits, or a `cfg` predicate no target configuration answers. Naming
/// them separately from `UnsupportedExpression` and friends is what keeps a
/// missing input from being read as an unimplemented construct — the two need
/// opposite responses, and only one of them is fixed by writing more lowering.
pub const RefusalKind = enum {
    /// A Cargo build script's generated artifact.
    build_script_artifact,
    /// A `macro_rules!` body defined outside this crate.
    external_macro_source,
    /// A `use` root no manifest entry admits.
    undeclared_crate_root,
    /// A `cfg`/`cfg_attr` predicate no target configuration answers.
    cfg_predicate,
};

/// What the run could not obtain, and which boundary stopped it.
pub const RefusalExplanation = struct {
    kind: RefusalKind,
    /// The class of input that was missing, in the words a reader needs. This is
    /// deliberately a description of the CLASS and not of one crate's instance:
    /// which file, macro, crate root or predicate is missing is a fact about the
    /// crate being translated, and that crate's own text is where it is stated.
    missing: []const u8,
};

/// Every input-availability refusal, with the class of input each one names.
///
/// The table is the whole policy: a refusal absent from it is not an
/// input-availability boundary, and `explainRefusal` answering null for one is
/// what keeps a lowering gap from being filed under a missing input.
const refusal_table = [_]struct { err: anyerror, kind: RefusalKind, missing: []const u8 }{
    .{
        .err = error.BuildScriptArtifactUnavailable,
        .kind = .build_script_artifact,
        // `include!(concat!(env!("OUT_DIR"), "/tables.rs"))` names a file that
        // exists only after `build.rs` has been run as a PROGRAM. Translating
        // Rust to Zig never runs it, so the artifact is not merely missing from
        // the input set — producing it is a different kind of work than
        // analysis, and no amount of lowering reaches it.
        .missing = "a build script's generated artifact under `$OUT_DIR`, which exists only " ++
            "once `build.rs` has been EXECUTED as a program",
    },
    .{
        .err = error.ExternalMacroSourceUnavailable,
        .kind = .external_macro_source,
        // The invocation's `macro_rules!` body lives in the DEFINING crate's
        // source. A crate this translator did not read cannot supply it, so the
        // expansion has no text to re-parse — this is the macro's own body
        // missing, not the invocation being unrecognised.
        .missing = "the `macro_rules!` body of a macro exported by another crate, whose " ++
            "defining source is not part of this translation input",
    },
    .{
        .err = error.UnsupportedExternalUse,
        .kind = .undeclared_crate_root,
        // The `use` names a root that is neither a module of this crate nor an
        // entry in the dependency table the manifest built. Dropping the import
        // instead would stage a package naming a type the translator never
        // defined, so the run stops and says which root was unadmitted.
        .missing = "a `use` root that is neither a module of this crate nor a dependency " ++
            "its manifest declares",
    },
    .{
        .err = error.UnsupportedCfgPredicate,
        .kind = .cfg_predicate,
        // `cfg` decides only what to DROP, so an unanswered predicate that is
        // false for the target may prune safely and one that is true may not.
        // With no target configuration to answer it, the run cannot tell which
        // case it is in and must not guess.
        .missing = "the value of a `cfg`/`cfg_attr` predicate naming a target property " ++
            "this translation has no configuration for",
    },
};

/// The input-availability boundary `err` sits on, or null when it is not one.
///
/// A lowering refusal answers null here on purpose: `UnsupportedExpression` and
/// `UnsupportedPattern` mean a construct this translator does not implement,
/// which is answered by writing lowering, not by obtaining an input.
pub fn explainRefusal(err: anyerror) ?RefusalExplanation {
    inline for (refusal_table) |row| {
        if (err == row.err) {
            return .{ .kind = row.kind, .missing = row.missing };
        }
    }
    return null;
}

/// Every input-availability boundary, for tests that must all stay reachable.
// `&refusal_table` is a pointer to the ARRAY, which coerces to a slice of the
// array's ELEMENT type; naming the array itself would ask for a slice of
// arrays, for which no such coercion exists.
pub fn refusalTable() []const @TypeOf(refusal_table[0]) {
    return &refusal_table;
}

/// Translate canonical v6 wire JSON into a standalone Zig package.
/// Unsupported wire versions fail before decoding or package creation.
pub fn translateWireJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    json_path: []const u8,
    out_dir: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const json_bytes = try readFileAlloc(arena_alloc, io, json_path);
    const rust_ir = try decodeWireJson(arena_alloc, json_bytes);
    try ir.validateForTranslation(&rust_ir);
    const pkg = try backend.zig.lower.lowerRustIr(arena_alloc, &rust_ir, null);

    try promotePackage(arena_alloc, io, &pkg, out_dir);
}

/// Translate canonical v6 wire JSON and write canonical emitted source files
/// to stdout. Unsupported wire versions fail before lowering.
pub fn emitWireJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    json_path: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const json_bytes = try readFileAlloc(arena_alloc, io, json_path);
    const rust_ir = try decodeWireJson(arena_alloc, json_bytes);
    try ir.validateForTranslation(&rust_ir);
    const pkg = try backend.zig.lower.lowerRustIr(arena_alloc, &rust_ir, null);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout.writerStreaming(io, &stdout_buffer);
    try emitPackageFramed(arena_alloc, &pkg, &stdout_writer.interface);
    try stdout_writer.interface.flush();
}

fn emitPackageFramed(
    allocator: std.mem.Allocator,
    pkg: *const backend.zig.ast.Package,
    writer: *std.Io.Writer,
) !void {
    for (pkg.files, 0..) |*file, index| {
        if (index != 0) try writer.writeByte('\n');
        try writer.print("// --- {s} ---\n", .{file.path});
        const source = try backend.zig.emit.emitFile(allocator, file);
        defer allocator.free(source);
        try writer.writeAll(source);
        if (source.len == 0 or source[source.len - 1] != '\n') {
            try writer.writeByte('\n');
        }
    }
}

fn runFingerprintProbe(
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
) !FingerprintProbeResult {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ zig_executable, "build" },
        .cwd = .{ .path = out_dir },
    });
    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn recordFingerprint(
    dump: []const u8,
    marker: []const u8,
    value: *?u64,
    count: *usize,
) FingerprintError!void {
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, dump, search_start, marker)) |marker_index| {
        const value_start = marker_index + marker.len;
        const rest = dump[value_start..];
        var value_len: usize = 0;
        while (value_len < rest.len and std.ascii.isHex(rest[value_len])) : (value_len += 1) {}
        if (value_len == 0) return error.ProbeOutputUnrecognized;

        const parsed = std.fmt.parseUnsigned(u64, rest[0..value_len], 16) catch
            return error.ProbeOutputUnrecognized;
        count.* += 1;
        if (count.* > 1) return error.ProbeOutputAmbiguous;
        value.* = parsed;
        search_start = value_start + value_len;
    }
}

fn fingerprintFromProbe(result: FingerprintProbeResult) FingerprintError!u64 {
    const markers = [_][]const u8{
        "use this value: 0x",
        "fingerprint: 0x",
        "expected: 0x",
        "expected 0x",
    };
    var value: ?u64 = null;
    var count: usize = 0;
    for (markers) |marker| {
        try recordFingerprint(result.stdout, marker, &value, &count);
        try recordFingerprint(result.stderr, marker, &value, &count);
    }

    if (value) |fingerprint| {
        return switch (result.term) {
            .exited => fingerprint,
            else => error.ProbeTerminated,
        };
    }

    return switch (result.term) {
        .exited => |code| if (code != 0) error.ProbeNonZero else error.ProbeOutputUnrecognized,
        else => error.ProbeTerminated,
    };
}

/// Run a fingerprint probe through an injected seam, then patch the manifest.
pub fn fixFingerprintWithProbe(
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
    probe: FingerprintProbe,
) !void {
    const result = try probe(allocator, io, out_dir);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const fp = try fingerprintFromProbe(result);

    const zon_path = try std.fs.path.join(allocator, &.{ out_dir, "build.zig.zon" });
    defer allocator.free(zon_path);

    var dir = std.Io.Dir.cwd();
    var io_buf: [4096]u8 = undefined;
    const file = try dir.openFile(io, zon_path, .{});
    defer file.close(io);

    var reader = file.reader(io, &io_buf);
    const zon = try reader.interface.allocRemaining(allocator, .limited(1 << 20));
    defer allocator.free(zon);

    const old_key = ".fingerprint = 0x";
    const old_idx = std.mem.indexOf(u8, zon, old_key) orelse
        return error.ManifestFingerprintMissing;
    const val_start = old_idx + old_key.len;
    var val_end = val_start;
    while (val_end < zon.len and std.ascii.isHex(zon[val_end])) : (val_end += 1) {}
    if (val_end == val_start) return error.ManifestFingerprintMissing;

    const fp_hex = try std.fmt.allocPrint(allocator, "{x}", .{fp});
    defer allocator.free(fp_hex);

    var patched: std.ArrayListUnmanaged(u8) = .empty;
    defer patched.deinit(allocator);
    try patched.appendSlice(allocator, zon[0..val_start]);
    try patched.appendSlice(allocator, fp_hex);
    if (val_end < zon.len) {
        try patched.appendSlice(allocator, zon[val_end..]);
    }

    const output = try dir.createFile(io, zon_path, .{});
    defer output.close(io);
    try output.writeStreamingAll(io, patched.items);
}

/// Run the production fingerprint probe and propagate every failure.
pub fn fixFingerprint(
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
) !void {
    return fixFingerprintWithProbe(allocator, io, out_dir, runFingerprintProbe);
}

fn failedFingerprintDiagnosticProbe(
    allocator: std.mem.Allocator,
    _: std.Io,
    _: []const u8,
) anyerror!FingerprintProbeResult {
    return .{
        .term = .{ .exited = 1 },
        .stdout = try allocator.dupe(u8, ""),
        .stderr = try allocator.dupe(u8, "error: use this value: 0x81677af28f9d3b4e"),
    };
}

fn unrelatedFingerprintProbe(
    allocator: std.mem.Allocator,
    _: std.Io,
    _: []const u8,
) anyerror!FingerprintProbeResult {
    return .{
        .term = .{ .exited = 1 },
        .stdout = try allocator.dupe(u8, ""),
        .stderr = try allocator.dupe(u8, "error: unrelated build failure"),
    };
}

test "fingerprint patch accepts failed diagnostic and propagates unrelated failure" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    const out_dir = try std.fs.path.join(allocator, &.{ tmp_root, "fingerprint" });
    defer allocator.free(out_dir);
    const zon_path = try std.fs.path.join(allocator, &.{ out_dir, "build.zig.zon" });
    defer allocator.free(zon_path);

    var dir = std.Io.Dir.cwd();
    try dir.createDirPath(test_io, out_dir);
    {
        const zon_file = try dir.createFile(test_io, zon_path, .{});
        defer zon_file.close(test_io);
        try zon_file.writeStreamingAll(test_io,
            \\.{
            \\    .fingerprint = 0x0123456789abcdef,
            \\}
        );
    }

    try fixFingerprintWithProbe(allocator, test_io, out_dir, failedFingerprintDiagnosticProbe);
    const patched = try readFileAlloc(allocator, test_io, zon_path);
    defer allocator.free(patched);
    try std.testing.expect(std.mem.indexOf(
        u8,
        patched,
        ".fingerprint = 0x81677af28f9d3b4e",
    ) != null);

    try std.testing.expectError(
        error.ProbeNonZero,
        fixFingerprintWithProbe(allocator, test_io, out_dir, unrelatedFingerprintProbe),
    );
}

test "fingerprint extraction and patching logic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const sample_zon =
        \\.{
        \\    .name = .sample_pkg,
        \\    .version = "0.1.0",
        \\    .fingerprint = 0x0123456789abcdef,
        \\    .minimum_zig_version = "0.17.0",
        \\    .paths = .{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\    },
        \\}
    ;

    const old_key = ".fingerprint = 0x";
    const old_idx = std.mem.indexOf(u8, sample_zon, old_key).?;
    const val_start = old_idx + old_key.len;
    var val_end = val_start;
    while (val_end < sample_zon.len and std.ascii.isHex(sample_zon[val_end])) : (val_end += 1) {}

    const new_fp: u64 = 0x81677af28f9d3b4e;
    const fp_hex = try std.fmt.allocPrint(allocator, "{x}", .{new_fp});
    defer allocator.free(fp_hex);

    var patched: std.ArrayListUnmanaged(u8) = .empty;
    defer patched.deinit(allocator);
    try patched.appendSlice(allocator, sample_zon[0..val_start]);
    try patched.appendSlice(allocator, fp_hex);
    if (val_end < sample_zon.len) {
        try patched.appendSlice(allocator, sample_zon[val_end..]);
    }

    try testing.expect(std.mem.indexOf(u8, patched.items, ".fingerprint = 0x81677af28f9d3b4e") != null);
}

test "translate uses native target pointer width by default" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    const crate_dir = try std.fs.path.join(allocator, &.{ tmp_root, "crate" });
    defer allocator.free(crate_dir);
    const source_dir = try std.fs.path.join(allocator, &.{ crate_dir, "src" });
    defer allocator.free(source_dir);
    const manifest_path = try std.fs.path.join(allocator, &.{ crate_dir, "Cargo.toml" });
    defer allocator.free(manifest_path);
    const source_path = try std.fs.path.join(allocator, &.{ source_dir, "lib.rs" });
    defer allocator.free(source_path);
    const out_dir = try std.fs.path.join(allocator, &.{ tmp_root, "out" });
    defer allocator.free(out_dir);

    var dir = std.Io.Dir.cwd();
    try dir.createDirPath(test_io, source_dir);
    {
        const manifest = try dir.createFile(test_io, manifest_path, .{});
        defer manifest.close(test_io);
        try manifest.writeStreamingAll(test_io,
            \\[package]
            \\name = "driver_native_width"
            \\version = "0.1.0"
            \\edition = "2021"
            \\
        );
    }

    const source = try std.fmt.allocPrint(
        allocator,
        \\#[cfg(target_pointer_width = "{d}")]
        \\pub fn native_width_selected() -> u8 {{ 1 }}
        \\
    ,
        .{@bitSizeOf(usize)},
    );
    defer allocator.free(source);
    {
        const input = try dir.createFile(test_io, source_path, .{});
        defer input.close(test_io);
        try input.writeStreamingAll(test_io, source);
    }

    try translate(allocator, test_io, crate_dir, out_dir);

    const output_path = try std.fs.path.join(allocator, &.{ out_dir, "src/root.zig" });
    defer allocator.free(output_path);
    const output = try readFileAlloc(allocator, test_io, output_path);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "pub fn native_width_selected()") != null);
}

const canonical_wire_payload_suffix =
    ",\"crate_name\":\"fixture\",\"edition\":\"2021\",\"sidecar\":null,\"toolchain\":null," ++
    "\"crates\":[{\"name\":\"fixture\",\"edition\":2021,\"kind\":\"lib\",\"root\":0," ++
    "\"is_translated\":true,\"deps\":[],\"entities\":[{\"id\":0,\"kind\":\"module\"," ++
    "\"name\":\"fixture\",\"span\":{\"start_line\":1,\"start_col\":1,\"end_line\":1," ++
    "\"end_col\":1},\"visibility\":{\"kind\":\"public\"},\"parent\":null," ++
    "\"resolved\":null,\"renamed_to\":null,\"attributes\":[]}],\"modules\":[{\"id\":0," ++
    "\"kind\":\"root\",\"name\":\"fixture\",\"parent\":null,\"source_path\":null," ++
    "\"is_crate\":true,\"is_extern\":false,\"span\":{\"start_line\":1,\"start_col\":1," ++
    "\"end_line\":1,\"end_col\":1},\"items\":[],\"attributes\":[]}],\"uses\":[]}]," ++
    "\"types\":[],\"instantiations\":[],\"bodies\":{\"exprs\":[],\"stmts\":[]," ++
    "\"pats\":[],\"types\":[],\"bodies\":[{\"owner\":0,\"body\":{\"kind\":\"none\"}}]}}";

test "wire dispatch sends canonical v6 to canonical decoder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var decoded = try decodeWireJson(
        arena.allocator(),
        "{\"format_version\":6" ++ canonical_wire_payload_suffix,
    );
    defer decoded.graph.deinit();
    defer decoded.deinitInstantiations(arena.allocator());

    try std.testing.expectEqualStrings("fixture", decoded.crate_name);
    try std.testing.expectEqualStrings("2021", decoded.edition);
}

test "wire dispatch preserves JSON parser allocation errors" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        decodeWireJson(failing.allocator(), "{\"format_version\":6" ++ canonical_wire_payload_suffix),
    );
    try std.testing.expectError(
        error.InvalidJson,
        decodeWireJson(std.testing.allocator, "this is not json {"),
    );
}

test "framed package emission labels each source file" {
    const root_file: backend.zig.ast.File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .const_decl = .{
            .name = "root_value",
            .ty = .{ .prim = .u8 },
            .init = .{ .lit = .{ .int = 17 } },
        } }},
    };
    const util_file: backend.zig.ast.File = .{
        .path = "src/util.zig",
        .decls = &.{.{ .const_decl = .{
            .name = "util_value",
            .ty = .{ .prim = .u8 },
            .init = .{ .lit = .{ .int = 29 } },
        } }},
    };
    const files = [_]backend.zig.ast.File{ root_file, util_file };
    const pkg: backend.zig.ast.Package = .{
        .name = "framed_fixture",
        .files = &files,
    };

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try emitPackageFramed(std.testing.allocator, &pkg, &output.writer);

    const expected =
        "// --- src/root.zig ---\n" ++
        "pub const root_value: u8 = 17;\n" ++
        "\n" ++
        "// --- src/util.zig ---\n" ++
        "pub const util_value: u8 = 29;\n";
    try std.testing.expectEqualStrings(expected, output.writer.buffered());
}

test "wire dispatch rejects v1 before canonical decode" {
    try std.testing.expectError(
        error.UnsupportedWireVersion,
        decodeWireJson(
            std.testing.allocator,
            "{\"format_version\":1" ++ canonical_wire_payload_suffix,
        ),
    );
}

test "wire dispatch rejects v2 before canonical decode" {
    try std.testing.expectError(
        error.UnsupportedWireVersion,
        decodeWireJson(
            std.testing.allocator,
            "{\"format_version\":2" ++ canonical_wire_payload_suffix,
        ),
    );
}

test "wire dispatch rejects v4 before canonical decode" {
    try std.testing.expectError(
        error.UnsupportedWireVersion,
        decodeWireJson(
            std.testing.allocator,
            "{\"format_version\":4" ++ canonical_wire_payload_suffix,
        ),
    );
}

test "wire dispatch rejects v5 before canonical decode" {
    try std.testing.expectError(
        error.UnsupportedWireVersion,
        decodeWireJson(
            std.testing.allocator,
            "{\"format_version\":5" ++ canonical_wire_payload_suffix,
        ),
    );
}

fn expectWireFailureLeavesNoPackage(payload: []const u8, expected: anyerror) !void {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);

    const json_path = try std.fs.path.join(allocator, &.{ tmp_root, "input.json" });
    defer allocator.free(json_path);
    const out_dir = try std.fs.path.join(allocator, &.{ tmp_root, "out" });
    defer allocator.free(out_dir);

    var dir = std.Io.Dir.cwd();
    const input = try dir.createFile(test_io, json_path, .{});
    defer input.close(test_io);
    try input.writeStreamingAll(test_io, payload);

    try std.testing.expectError(
        expected,
        translateWireJson(allocator, test_io, json_path, out_dir),
    );

    const first_output = try std.fs.path.join(allocator, &.{ out_dir, "build.zig" });
    defer allocator.free(first_output);
    const output = dir.openFile(test_io, first_output, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    output.close(test_io);
    return error.UnexpectedPackageOutput;
}

test "wire v1 failure leaves no package output" {
    try expectWireFailureLeavesNoPackage(
        "{\"format_version\":1" ++ canonical_wire_payload_suffix,
        error.UnsupportedWireVersion,
    );
}

test "wire v2 failure leaves no package output" {
    try expectWireFailureLeavesNoPackage(
        "{\"format_version\":2" ++ canonical_wire_payload_suffix,
        error.UnsupportedWireVersion,
    );
}

test "wire v4 failure leaves no package output" {
    try expectWireFailureLeavesNoPackage(
        "{\"format_version\":4" ++ canonical_wire_payload_suffix,
        error.UnsupportedWireVersion,
    );
}
