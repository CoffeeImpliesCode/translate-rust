//! Host producer for the generated-package cross matrix.
//!
//! One invocation stages every corpus row as a freshly promoted standalone Zig
//! package and writes a standalone aggregate package that consumes all of them.
//! Nothing here is a checked-in golden: each row goes through the real driver,
//! and a row is only present because `driver.promotePackage` published it after
//! its manifest, its sources and its own `zig build test` passed.
//!
//!     zig build generated-corpus -- --output /abs/local/dir
//!
//! The output directory must be absolute, must not already exist, and must live
//! on a local filesystem that is neither one of the small system temporaries
//! nor a network mount. This repository itself is on NFS, where Zig's atomic
//! file write fails outright, and the small local volumes are kept clear by
//! policy.
//!
//! Every row is attempted even after one fails, so a single run reports every
//! red scenario at once. When any row failed, no aggregate is written: a
//! partial corpus must never look like a runnable matrix. Nothing is deleted on
//! the way out — the parent owns what is on disk.
//!
//! The run always writes `corpus-rows.json` beside `aggregate/`, on the way out
//! of a failing run as well as a passing one. A run that printed "12 of 22 rows
//! failed" and left nothing behind left the operator with a count and no rows;
//! the receipt names every row, says whether it staged, records the error it
//! failed with, and records whether its coverage is an assertion somebody ran
//! or only a compile. It is written before the error a red row returns, so the
//! one run that reports the most is the run that leaves the most behind.
//!
//! `test/generated_corpus_build.zig` is copied verbatim to become the
//! aggregate's `build.zig`; everything row-specific is emitted as
//! `corpus_config.zig` beside it.

const std = @import("std");
const translate_rust = @import("translate_rust");

const driver = translate_rust.driver;
const frontend = translate_rust.frontend;
const ir = translate_rust.ir;
const backend = translate_rust.backend;

/// The aggregate's build script. Copied byte for byte, so the matrix compiles
/// from the same file this repository reviews.
const aggregate_build_script = @embedFile("generated_corpus_build.zig");

/// Directory names inside the output. Every generated string the aggregate
/// build script resolves goes through `b.path`, which only accepts paths
/// relative to the aggregate build root.
const packages_dir = "packages";
const aggregate_dir = "aggregate";
const consumers_dir = "consumers";
const wire_dir = "wire";
const config_file = "corpus_config.zig";
const manifest_file = "build.zig.zon";
const profile_file = "cross-test.profile.sh";

/// The per-row receipt. Written beside `aggregate/` and never inside it,
/// because a run that failed stages no aggregate to write it into.
const results_file = "corpus-rows.json";

/// Schema version of that file. Bumped whenever a field changes meaning; a
/// reader that does not recognise it must refuse the file rather than read a
/// field it does not know as a default.
const results_schema: u32 = 1;

/// Directory the generated-package writer vendors the Rust-core runtime under.
/// One string, because the vendor prefix, the manifest dependency name and the
/// `.paths` entry are the same directory by construction.
const runtime_directory = "r2z-core";
const runtime_root_source = "src/root.zig";

/// The coverage modes the matrix pins. They are separate artifacts in one graph
/// rather than a `-Doptimize` selection: a flag would let a run quietly compile
/// only one of them.
const optimize_modes = [_]std.lang.Optimize{ .debug, .safe };

/// The package `name` a build.zig.zon declares. `zonPackageName` shortens a
/// longer crate name, so this is read back from the emitted manifest instead of
/// being computed.
const aggregate_package_name = "generated_corpus";

/// Stable legal identity in the lower 32 bits. Zig validates the upper checksum
/// against the package name, not against the generated inventory.
const aggregate_fingerprint_id: u32 = 0x4743_0001;

/// How a row's sources are produced.
const Kind = enum {
    /// A crate directory analyzed by the frontend.
    source,
    /// A checked-in canonical v6 wire fixture.
    wire_fixture,
    /// Canonical v6 wire re-encoded from a crate the producer just analyzed.
    wire_canonical,
    /// A lowered package that round-trips through serialized Zig AST bytes.
    serialized_ast,
};

/// The pointer widths a Rust `#[cfg(target_pointer_width = "...")]` item was
/// evaluated for. `any` means the fixture has no width-gated item, so the host
/// default applies and the package is valid for every matrix target.
const Width = enum { any, w32, w64 };

/// One generated package in the corpus.
const Row = struct {
    /// Stable identity: the package directory name, the aggregate dependency
    /// key, and the name a consumer can `@import`.
    id: []const u8,
    kind: Kind,
    /// Repository directory the crate came from. Meaningful for `.source`.
    crate_dir: []const u8,
    /// Checked-in wire fixture for `.wire_fixture`.
    fixture: []const u8,
    /// Explicit `#[cfg(feature = ...)]` selection. An empty list is not "no
    /// features": it means no selection was made, so the manifest's `default`
    /// closure applies.
    features: []const []const u8,
    width: Width,
    /// Whether this configuration is expected to publish an API at all.
    /// `xxhash-rust` declares no `default` feature, so its default
    /// configuration resolves to the empty set and every algorithm module drops
    /// out. That is a valid package configuration, not a missing row, and the
    /// inventory records it so no reader mistakes it for the `xxh32` one.
    has_api: bool,
    note: []const u8,
};

/// One `@import` in a consumer, and the module it resolves to.
const Binding = struct {
    /// The name the consumer source writes in `@import("…")`.
    name: []const u8,
    row: []const u8,
    kind: BindingKind,
    pointer_widths: []const u16,
};

const BindingKind = enum { package, runtime };

/// Facts read back out of a promoted package, never assumed.
const Facts = struct {
    /// The name the package registered with `b.addModule`.
    module: []const u8,
    /// The `.name` its manifest declares.
    zon_name: []const u8,
    vendored_runtime: bool,
    /// `test "` declarations across the package's own sources: the original
    /// assertions it carried, which the matrix compiles through its own module.
    original_tests: usize,
};

/// What one row's evidence is.
///
/// `executed` means somebody ran an assertion in this row. `compile_only` means
/// the row exists to prove that a configuration compiles, which is legal only
/// for a configuration that publishes no value to call. `not_staged` means the
/// row never reached a promoted package, so no claim is made about it at all.
/// `test/generated_corpus_build.zig` re-checks the first two against the graph
/// it builds, so a stale inventory cannot turn coverage into a compile.
const Coverage = enum { executed, compile_only, not_staged };

/// Why one row carries the verdict it does. This is the pinned rule, stated as
/// data so the receipt and the aggregate inventory cannot drift apart.
const CoverageReason = enum {
    /// The row never reached a promoted package.
    not_staged,
    /// The configuration publishes no API at all, so there is no value to run.
    no_api_by_configuration,
    /// The package's own translated `#[cfg(test)]` module carries the
    /// assertions.
    package_tests,
    /// A checked-in consumer binds the row and calls into it.
    consumer_binding,
    /// The row publishes an API, carries no translated test and no consumer
    /// binds it, so its only evidence is that it compiled. Always a failure:
    /// this is build-only coverage, and a compile is not a measurement.
    no_value_assertion,
};

/// One row's staging outcome, kept whether it succeeded or failed so the
/// receipt can name both.
const StagedRow = struct {
    /// What the promoted package turned out to contain. Null exactly when
    /// `error_name` is set.
    published: ?Facts,
    /// The error a red row failed with. Null exactly when it staged.
    error_name: ?[]const u8,
};

/// The coverage verdict for one row.
const Verdict = struct {
    coverage: Coverage,
    reason: CoverageReason,
    /// The checked-in consumer that runs values in this row, when that is the
    /// whole of its evidence. Empty otherwise.
    evidence: []const u8,
};

/// One row of the receipt.
const RowResult = struct {
    row: Row,
    /// Absolute path of the directory this row was staged into, published or
    /// not. A red row may have left a staging directory behind.
    package_dir: []const u8,
    verdict: Verdict,
    staged: StagedRow,
};

/// Whether a row reached a promoted package.
const RowStatus = enum { staged, failed };

/// Whether promotion published a package for this row. Independent of the
/// coverage verdict: a row can be `failed` and still be an API-bearing one
/// somebody meant to measure, and a `compile_only` row can be perfectly staged.
///
fn statusOf(result: RowResult) RowStatus {
    return if (result.staged.published != null) .staged else .failed;
}

/// All pointer widths the pinned matrix contains. Used for rows and bindings
/// that are not width-gated, and for the runtime, which is plain Zig and is the
/// same package on every target.
const all_widths = [_]u16{ 32, 64 };

/// A repository consumer file the matrix preserves verbatim.
const Consumer = struct {
    id: []const u8,
    source: []const u8,
    /// Row the conventional `translated` import name resolves to. A consumer
    /// written for a `zig test -Mtranslated=…` invocation names its package that
    /// way; one written against several packages names each of them directly and
    /// leaves this empty.
    primary_row: []const u8,
};

const rows = [_]Row{
    // ── the ten repository source fixtures that already translate ────────
    .{
        .id = "mini",
        .kind = .source,
        .crate_dir = "test/crates/mini",
        .fixture = "",
        .features = &.{},
        .width = .any,
        .has_api = true,
        .note = "no_std; file-split module, re-export, data-carrying enum",
    },
    .{
        .id = "fnv",
        .kind = .source,
        .crate_dir = "test/crates/fnv",
        .fixture = "",
        .features = &.{},
        .width = .any,
        .has_api = true,
        .note = "lib.rs at the crate root; default = [\"std\"]",
    },
    .{
        .id = "compat",
        .kind = .source,
        .crate_dir = "test/crates/compat",
        .fixture = "",
        .features = &.{},
        .width = .any,
        .has_api = true,
        .note = "runtime ownership, formatting and pointer contracts",
    },
    .{
        .id = "wyhash",
        .kind = .source,
        .crate_dir = "test/crates/wyhash",
        .fixture = "",
        .features = &.{},
        .width = .any,
        .has_api = true,
        .note = "no default feature; three-file package",
    },
    .{
        .id = "adler",
        .kind = .source,
        .crate_dir = "test/crates/adler",
        .fixture = "",
        .features = &.{},
        .width = .any,
        .has_api = true,
        .note = "default = [\"std\"]; chunked checksum loop",
    },
    .{
        .id = "multimod",
        .kind = .source,
        .crate_dir = "test/crates/multimod",
        .fixture = "",
        .features = &.{},
        .width = .any,
        .has_api = true,
        .note = "out-of-line, nested and #[path] module discovery",
    },
    // The empty default configuration and the explicit one are separate rows on
    // purpose. Collapsing them would hide which API each package actually has.
    .{
        .id = "xxhash-default",
        .kind = .source,
        .crate_dir = "test/crates/xxhash-rust",
        .fixture = "",
        .features = &.{},
        .width = .any,
        .has_api = false,
        .note = "manifest declares no default feature, so the closure is empty and no algorithm module survives",
    },
    .{
        .id = "xxhash-xxh32",
        .kind = .source,
        .crate_dir = "test/crates/xxhash-rust",
        .fixture = "",
        .features = &.{"xxh32"},
        .width = .any,
        .has_api = true,
        .note = "explicit xxh32 selection; this is the row that has the API",
    },
    .{
        .id = "hex-w32",
        .kind = .source,
        .crate_dir = "test/crates/hex",
        .fixture = "",
        .features = &.{},
        .width = .w32,
        .has_api = true,
        .note = "default = [\"std\"] pulls in alloc; FromHex for fixed arrays is gated on target_pointer_width, so this is the 32-bit half of the pair",
    },
    .{
        .id = "hex-w64",
        .kind = .source,
        .crate_dir = "test/crates/hex",
        .fixture = "",
        .features = &.{},
        .width = .w64,
        .has_api = true,
        .note = "the 64-bit half of the hex pair",
    },
    .{
        .id = "leb128",
        .kind = .source,
        .crate_dir = "test/crates/leb128",
        .fixture = "",
        .features = &.{},
        .width = .any,
        .has_api = true,
        .note = "std io::Read and io::Write boundaries",
    },
    .{
        .id = "percent-encoding",
        .kind = .source,
        .crate_dir = "test/crates/percent-encoding",
        .fixture = "",
        .features = &.{},
        .width = .any,
        .has_api = true,
        .note = "default = [\"std\"]; String and Cow ownership",
    },
    // ── new families ────────────────────────────────────────────────────
    .{
        .id = "differential",
        .kind = .source,
        .crate_dir = "test/crates/differential",
        .fixture = "",
        .features = &.{},
        .width = .any,
        .has_api = true,
        .note = "isolated differential fixture with Rust and Zig oracles",
    },
    .{
        .id = "siphasher",
        .kind = .source,
        .crate_dir = "test/crates/siphasher",
        .fixture = "",
        .features = &.{},
        .width = .any,
        .has_api = true,
        .note = "default = [\"std\"]; staged as a positive row that must translate and pass the shared consumer, which the current tree has not yet demonstrated",
    },
    .{
        .id = "itoa-w32",
        .kind = .source,
        .crate_dir = "test/crates/itoa",
        .fixture = "",
        .features = &.{},
        .width = .w32,
        .has_api = true,
        .note = "no default feature; isize and usize impls are gated on target_pointer_width, so this is the 32-bit half of the pair",
    },
    .{
        .id = "itoa-w64",
        .kind = .source,
        .crate_dir = "test/crates/itoa",
        .fixture = "",
        .features = &.{},
        .width = .w64,
        .has_api = true,
        .note = "the 64-bit half of the itoa pair",
    },
    .{
        .id = "seahash-w32",
        .kind = .source,
        .crate_dir = "test/crates/seahash",
        .fixture = "",
        .features = &.{},
        .width = .w32,
        .has_api = true,
        .note = "default = []; read_u64 has a 32-bit and a 64-bit body, so this is the 32-bit half of the pair",
    },
    .{
        .id = "seahash-w64",
        .kind = .source,
        .crate_dir = "test/crates/seahash",
        .fixture = "",
        .features = &.{},
        .width = .w64,
        .has_api = true,
        .note = "the 64-bit half of the seahash pair",
    },
    .{
        .id = "atoi",
        .kind = .source,
        .crate_dir = "test/crates/atoi",
        .fixture = "",
        .features = &.{},
        .width = .any,
        .has_api = true,
        .note = "default = [\"std\"]; positional parse radixes",
    },
    // ── canonical and serialized representations ───────────────────────
    .{
        .id = "mini-wire",
        .kind = .wire_fixture,
        .crate_dir = "",
        .fixture = "test/mini.json",
        .features = &.{},
        .width = .any,
        .has_api = true,
        .note = "checked-in canonical v6 wire fixture",
    },
    .{
        .id = "compat-canonical",
        .kind = .wire_canonical,
        .crate_dir = "test/crates/compat",
        .fixture = "",
        .features = &.{},
        .width = .any,
        .has_api = true,
        .note = "compat re-encoded to canonical v6 wire in this run",
    },
    .{
        .id = "compat-serialized-ast",
        .kind = .serialized_ast,
        .crate_dir = "test/crates/compat",
        .fixture = "",
        .features = &.{},
        .width = .any,
        .has_api = true,
        .note = "compat lowered, encoded to Zig AST JSON, decoded back, then promoted",
    },
};

/// Consumers the matrix compiles from verbatim copies. None is merged into
/// another and none is rewritten: each keeps its own assertions.
const consumers = [_]Consumer{
    .{ .id = "compat-consumer", .source = "test/compat_consumer.zig", .primary_row = "compat" },
    .{
        .id = "percent-encoding-consumer",
        .source = "test/percent_encoding_consumer.zig",
        .primary_row = "percent-encoding",
    },
    .{
        .id = "promoted-crates-consumer",
        .source = "test/promoted_crates_consumer.zig",
        .primary_row = "",
    },
    .{
        .id = "differential-consumer",
        .source = "test/differential_consumer.zig",
        .primary_row = "differential",
    },
    .{
        .id = "generated-corpus-consumer",
        .source = "test/generated_corpus_consumer.zig",
        .primary_row = "adler",
    },
};

/// The name a consumer writes for the runtime, when it imports one at all.
const runtime_import_name = "r2z";

/// The conventional name a single-package consumer gives its package. It is a
/// `zig test -Mtranslated=…` invocation name, not a crate name, so it resolves
/// through the consumer's declared primary row rather than by matching.
const primary_import_name = "translated";

/// Identifier of the runtime test artifact in the aggregate graph.
const runtime_test_id = "runtime";

/// How far a chain of relative consumer imports may reach before it is treated
/// as a cycle rather than followed forever.
const local_import_depth_limit = 16;

/// Directories this repository's policy keeps clear. A path that reaches one of
/// them through a symlink is still one of them, which is why the check resolves
/// symlinks first.
const forbidden_roots = [_][]const u8{ "/tmp", "/var/tmp", "/dev/shm" };

/// Filesystem types this producer refuses. Zig's atomic file write needs a real
/// local filesystem, and the aggregates and caches are large.
const forbidden_filesystems = [_][]const u8{
    "nfs",  "nfs4",   "cifs",  "smbfs",      "smb3",           "9p",
    "afs",  "ceph",   "coda",  "fuse.sshfs", "fuse.glusterfs", "glusterfs",
    "gpfs", "lustre", "ocfs2", "beegfs",
};

/// `/proc/mounts` is the authority on what a path actually sits on. Its
/// filesystem-type column is matched by hand because `stat -f` reports a family
/// name ("ext2/ext3") that says nothing about network transport.
const mounts_path = "/proc/mounts";

const max_inspection_file = 8 << 20;

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| {
        std.log.err("generated-corpus failed: {s}", .{@errorName(err)});
        return err;
    };
}

fn run(init: std.process.Init) !void {
    // Every path, wire fixture and generated source string this run builds is
    // short-lived and outlives nothing that runs after `deinit`. One arena over
    // the process allocator keeps that true under the Debug build's leak check.
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();
    const io = init.io;
    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next(); // argv[0]

    var output: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--output")) {
            if (output != null) return error.DuplicateOutputArgument;
            output = args.next() orelse return error.MissingOutputPath;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            try writeAll(io, stdout, usage);
            return;
        }
        std.log.err("generated-corpus: unexpected argument '{s}'", .{arg});
        try writeAll(io, stderr, usage);
        return error.UnknownArgument;
    }
    const requested = output orelse {
        try writeAll(io, stderr, usage);
        return error.MissingOutputPath;
    };

    const root = try prepareOutputRoot(gpa, io, requested);
    defer gpa.free(root);

    const aggregate_root = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, aggregate_dir });
    const packages_root = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ aggregate_root, packages_dir });
    const wire_root = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, wire_dir });
    try std.Io.Dir.cwd().createDirPath(io, packages_root);
    try std.Io.Dir.cwd().createDirPath(io, wire_root);
    try std.Io.Dir.cwd().createDirPath(io, aggregate_root);

    // Every row is attempted so one run reports every red scenario, and every
    // outcome is kept — a failure is as much of the record as a success.
    const staged = try gpa.alloc(StagedRow, rows.len);
    defer gpa.free(staged);
    var failures: usize = 0;
    for (rows, staged) |row, *slot| {
        const package_dir = try std.fmt.allocPrint(
            gpa,
            "{s}/{s}",
            .{ packages_root, row.id },
        );
        defer gpa.free(package_dir);
        var error_name: ?[]const u8 = null;
        const published = generateRow(gpa, io, stderr, wire_root, row, package_dir) catch |err| blk: {
            std.log.err("row {s} failed: {s}", .{ row.id, @errorName(err) });
            error_name = @errorName(err);
            failures += 1;
            break :blk @as(?Facts, null);
        };
        slot.* = .{ .published = published, .error_name = error_name };
        if (slot.published != null) {
            try writeAll(
                io,
                stdout,
                try std.fmt.allocPrint(gpa, "staged {s} {s}\n", .{ row.id, package_dir }),
            );
        }
    }

    // Coverage is decided from what the run actually staged and from what the
    // checked-in consumers name, never from what a row was expected to do. A
    // row that published an API, carried no translated test and is bound by no
    // consumer is build-only coverage, and it is counted as a failure here
    // rather than published as a row somebody can mistake for a measurement.
    const results = try classifyRows(gpa, io, packages_root, staged);
    defer gpa.free(results);
    for (results) |result| {
        if (result.verdict.reason != .no_value_assertion) continue;
        std.log.err(
            "generated-corpus: row {s} publishes an API, carries no translated test and no consumer binds it; its only evidence is that it compiled",
            .{result.row.id},
        );
        failures += 1;
    }

    // Written before the error a red run returns, and written whether the run
    // is red or green. A failing run that leaves no per-row record is a run
    // that reported "12 of 22 rows failed" and then threw the twelve away.
    const results_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, results_file });
    var aggregate_written = false;
    if (failures == 0) {
        try writeAggregate(gpa, io, root, aggregate_root, staged, results);
        aggregate_written = true;
    }
    try writeFile(io, results_path, try renderResults(gpa, results, aggregate_written));

    if (failures != 0) {
        std.log.err(
            "generated-corpus: {d} of {d} rows failed; no aggregate written",
            .{ failures, rows.len },
        );
        std.log.err(
            "generated-corpus: per-row results at {s}",
            .{results_path},
        );
        std.log.err(
            "generated-corpus: {s} is partial and not a runnable matrix; inspect it, then remove it yourself",
            .{root},
        );
        return error.CorpusRowsFailed;
    }

    try writeAll(
        io,
        stdout,
        try std.fmt.allocPrint(gpa, "aggregate {s}/{s}\n", .{ root, aggregate_dir }),
    );
    try writeAll(io, stdout, try std.fmt.allocPrint(gpa, "results {s}\n", .{results_path}));
    try writeAll(io, stdout, try std.fmt.allocPrint(gpa, "rows {d}\n", .{rows.len}));
}

const usage =
    \\usage: generated-corpus --output <absolute-local-directory>
    \\
    \\Stages every corpus row as a freshly promoted standalone Zig package and
    \\writes an aggregate package that consumes all of them under <output>/aggregate.
    \\The directory must be absolute, must not exist, and must be on a local
    \\filesystem that is neither a system temporary nor a network mount.
    \\
    \\Always writes <output>/corpus-rows.json: one entry per row, staged or not,
    \\with the error a red row failed with and what each row's coverage is.
    \\
;

/// Stage one row and report what the promoted package actually contains.
fn generateRow(
    gpa: std.mem.Allocator,
    io: std.Io,
    stderr: std.Io.File,
    wire_root: []const u8,
    row: Row,
    package_dir: []const u8,
) !?Facts {
    switch (row.kind) {
        .source => try generateSourceRow(gpa, io, row, package_dir),
        .wire_fixture => try driver.translateWireJson(gpa, io, row.fixture, package_dir),
        .wire_canonical => try generateCanonicalWireRow(gpa, io, wire_root, row, package_dir),
        .serialized_ast => try generateSerializedAstRow(gpa, io, row, package_dir),
    }
    try writeAll(
        io,
        stderr,
        try std.fmt.allocPrint(
            gpa,
            "generated-corpus: {s}: {s} [{s}] features={s} width={s} api={s}\n",
            .{
                row.id,
                row.crate_dir,
                @tagName(row.kind),
                try formatFeatures(gpa, row.features),
                @tagName(row.width),
                if (row.has_api) "yes" else "none-by-configuration",
            },
        ),
    );
    return try inspectPackage(gpa, io, package_dir);
}

fn generateSourceRow(gpa: std.mem.Allocator, io: std.Io, row: Row, package_dir: []const u8) !void {
    if (row.width == .any and row.features.len == 0) {
        // No width-gated item and no explicit selection: the host default
        // applies and `translate` is exactly this configuration's entry point.
        return driver.translate(gpa, io, row.crate_dir, package_dir);
    }
    try driver.translateWithOptions(gpa, io, row.crate_dir, package_dir, .{
        .include_tests = true,
        .cfg = .{
            .features = row.features,
            .target_pointer_width = switch (row.width) {
                .w32 => 32,
                .w64 => 64,
                // Unreachable: handled above.
                .any => @bitSizeOf(usize),
            },
            .docsrs = false,
        },
    });
}

/// Canonical v6 wire produced from a crate this run just analyzed, so the wire
/// row exercises the encoder against fresh input instead of a checked-in blob.
fn generateCanonicalWireRow(
    gpa: std.mem.Allocator,
    io: std.Io,
    wire_root: []const u8,
    row: Row,
    package_dir: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();

    var rust_ir = try frontend.pipeline.analyzeCrateWithOptions(
        scratch,
        io,
        row.crate_dir,
        .{ .include_tests = true },
    );
    defer rust_ir.deinitInstantiations(scratch);

    const json = try ir.serialize.encode(scratch, &rust_ir);
    const wire_path = try std.fmt.allocPrint(
        gpa,
        "{s}/{s}-canonical-v6.json",
        .{ wire_root, row.id },
    );
    defer gpa.free(wire_path);
    // The wire fixture is written outside the aggregate: it is producer input,
    // not part of the matrix a consumer compiles.
    try writeFile(io, wire_path, json);
    try driver.translateWireJson(gpa, io, wire_path, package_dir);
}

/// Lowered Zig AST carried through its own serialized JSON bytes before being
/// promoted, which is the one path the canonical wire cannot cover.
fn generateSerializedAstRow(
    gpa: std.mem.Allocator,
    io: std.Io,
    row: Row,
    package_dir: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();

    var rust_ir = try frontend.pipeline.analyzeCrateWithOptions(
        scratch,
        io,
        row.crate_dir,
        .{ .include_tests = true },
    );
    defer rust_ir.deinitInstantiations(scratch);
    try ir.validateForTranslation(&rust_ir);

    const lowered = try backend.zig.lower.lowerRustIr(scratch, &rust_ir, null);
    const ast_json = try backend.zig.serialize.encode(scratch, &lowered);
    const decoded = try backend.zig.serialize.decode(scratch, ast_json);
    try driver.promotePackage(gpa, io, &decoded, package_dir);
}

/// What the promoted package turned out to contain.
fn inspectPackage(gpa: std.mem.Allocator, io: std.Io, package_dir: []const u8) !Facts {
    const build_zig = try readOwned(gpa, io, package_dir, "build.zig");
    const zon = try readOwned(gpa, io, package_dir, "build.zig.zon");

    const module_marker = "b.addModule(\"";
    const module_start = std.mem.indexOf(u8, build_zig, module_marker) orelse
        return error.GeneratedPackageHasNoModule;
    const name_start = module_start + module_marker.len;
    const name_end = std.mem.indexOfScalarPos(u8, build_zig, name_start, '"') orelse
        return error.GeneratedPackageHasNoModule;
    if (std.mem.indexOfScalarPos(u8, build_zig, name_end, ',') == null) {
        return error.GeneratedPackageHasNoModule;
    }

    const zon_marker = ".name = .";
    const zon_start = std.mem.indexOf(u8, zon, zon_marker) orelse
        return error.GeneratedPackageHasNoManifestName;
    var zon_end = zon_start + zon_marker.len;
    while (zon_end < zon.len and isIdentifierChar(zon[zon_end])) zon_end += 1;
    if (zon_end == zon_start + zon_marker.len) return error.GeneratedPackageHasNoManifestName;

    const runtime_path = try std.fmt.allocPrint(
        gpa,
        "{s}/{s}/{s}",
        .{ package_dir, runtime_directory, runtime_root_source },
    );
    defer gpa.free(runtime_path);

    return .{
        .module = build_zig[name_start..name_end],
        .zon_name = zon[zon_start + zon_marker.len .. zon_end],
        .vendored_runtime = pathExists(io, runtime_path),
        .original_tests = try countPackageTests(gpa, io, package_dir),
    };
}

fn isIdentifierChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// `test "` declarations across the package's own translated sources: the
/// original Rust `#[test]` functions it carried, and the assertions the matrix
/// runs through the package's registered module.
fn countPackageTests(gpa: std.mem.Allocator, io: std.Io, package_dir: []const u8) !usize {
    const src = try std.fmt.allocPrint(gpa, "{s}/src", .{package_dir});
    defer gpa.free(src);
    var dir = std.Io.Dir.cwd().openDir(io, src, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const source = try readOwned(gpa, io, src, entry.path);
        defer gpa.free(source);
        total += countTestDeclarations(source);
    }
    return total;
}

fn countTestDeclarations(source: []const u8) usize {
    const needle = "test \"";
    var total: usize = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, needle)) |start| {
        // A declaration starts its own line; an occurrence inside a comment or a
        // string is not one.
        const at_line_start = start == 0 or source[start - 1] == '\n';
        if (at_line_start) total += 1;
        cursor = start + needle.len;
    }
    return total;
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn readOwned(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    name: []const u8,
) ![]u8 {
    const path = try std.fs.path.join(gpa, &.{ dir_path, name });
    defer gpa.free(path);
    // Streamed to EOF, never sized from the directory entry. `/proc/mounts`
    // reports a size of zero, so any reader that allocates from the stat size
    // returns nothing at all and every mount lookup below misses — which made
    // this producer refuse every output path on Linux.
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.initStreaming(file, io, &buffer);
    return reader.interface.allocRemaining(gpa, .limited(max_inspection_file));
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn writeAll(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    try file.writeStreamingAll(io, bytes);
}

fn formatFeatures(gpa: std.mem.Allocator, features: []const []const u8) ![]const u8 {
    if (features.len == 0) return gpa.dupe(u8, "<manifest default>");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (features, 0..) |feature, index| {
        if (index != 0) try out.appendSlice(gpa, ",");
        try out.appendSlice(gpa, feature);
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Output directory preflight
// ---------------------------------------------------------------------------

/// Validate the requested output directory and return it resolved.
///
/// Every rule here exists because getting it wrong is quiet: an NFS-backed
/// output makes Zig's atomic write panic with `EINVAL`, and a small system
/// temporary fills up silently. A path that reaches one of those volumes
/// through a symlink is still on that volume, so symlink ancestors are refused.
fn prepareOutputRoot(gpa: std.mem.Allocator, io: std.Io, requested: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(requested)) {
        std.log.err("generated-corpus: --output must be absolute, got '{s}'", .{requested});
        return error.OutputPathNotAbsolute;
    }
    // Check before normalization too: `link/..` must not erase a symlink
    // ancestor and silently change the caller's selected filesystem scope.
    const checked = try resolveExisting(gpa, io, requested);
    defer gpa.free(checked);
    const lexical = try std.fs.path.resolve(gpa, &.{requested});
    const resolved = try resolveExisting(gpa, io, lexical);

    for (forbidden_roots) |root| {
        const real_root = try resolveExisting(gpa, io, root);
        if (isInside(real_root, resolved)) {
            std.log.err(
                "generated-corpus: --output '{s}' is inside the reserved volume '{s}'",
                .{ resolved, real_root },
            );
            return error.OutputPathOnReservedVolume;
        }
    }

    const parent = std.fs.path.dirname(resolved) orelse return error.OutputHasNoParent;
    const real_parent = try resolveExisting(gpa, io, parent);
    const filesystem = try filesystemOf(gpa, io, real_parent);
    defer gpa.free(filesystem);
    for (forbidden_filesystems) |rejected| {
        if (!std.mem.eql(u8, filesystem, rejected)) continue;
        std.log.err(
            "generated-corpus: --output parent '{s}' is on filesystem '{s}', which this producer refuses",
            .{ real_parent, filesystem },
        );
        return error.OutputPathOnNetworkFilesystem;
    }
    // A pre-existing output would mean every row's "must not exist" promotion
    // check is already violated, and deleting it could destroy a corpus the
    // parent still owns. Fail closed instead.
    if (pathExists(io, resolved)) {
        std.log.err(
            "generated-corpus: --output '{s}' already exists; choose a fresh directory",
            .{resolved},
        );
        return error.OutputPathAlreadyExists;
    }
    try std.Io.Dir.cwd().createDir(io, resolved, .default_dir);
    return resolved;
}

/// Whether `path` is `root` or lies below it. Both must already be absolute and
/// normalized, which `resolveExisting` guarantees.
fn isInside(root: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, root, path)) return true;
    if (root.len == 1) return path.len > 1; // "/" contains everything
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path[root.len] == '/';
}

/// Reject symlinks in every existing component, preserving the entire selected
/// path when its missing suffix is about to be created.
fn resolveExisting(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(path)) return error.PathNotAbsolute;
    var end: usize = 1;
    while (end < path.len) {
        const next = std.mem.indexOfScalarPos(u8, path, end, '/') orelse path.len;
        const candidate = path[0..next];
        const stat = std.Io.Dir.cwd().statFile(io, candidate, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => break,
            else => return err,
        };
        if (stat.kind == .sym_link) return error.OutputPathContainsSymlink;
        end = next + 1;
    }
    return gpa.dupe(u8, path);
}

/// The owned filesystem type the kernel reports for `path`, from `/proc/mounts`.
/// The longest matching mount point wins. An unreadable table or unknown mount
/// is an error: placement must never silently bypass network-transport checks.
fn filesystemOf(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const mounts = try readOwned(gpa, io, "", mounts_path);
    defer gpa.free(mounts);
    var best: ?[]const u8 = null;
    var best_len: usize = 0;
    var lines = std.mem.splitScalar(u8, mounts, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next() orelse continue; // Device, not the mount point.
        const mount_point = try decodeMountPoint(gpa, fields.next() orelse return error.InvalidMountTable);
        defer gpa.free(mount_point);
        const fstype = fields.next() orelse return error.InvalidMountTable;
        if (!isMountAncestor(mount_point, path)) continue;
        if (best != null and best_len > mount_point.len) continue;
        best = fstype;
        best_len = mount_point.len;
    }
    return gpa.dupe(u8, best orelse return error.UnknownMountTransport);
}

/// Decode only the four escapes emitted by the kernel; unknown escapes fail
/// closed rather than hiding a more specific network mount.
fn decodeMountPoint(gpa: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(gpa);
    var index: usize = 0;
    while (index < encoded.len) {
        if (encoded[index] != '\\') {
            try decoded.append(gpa, encoded[index]);
            index += 1;
            continue;
        }
        if (encoded.len - index < 4) return error.InvalidMountTable;
        const escape = encoded[index + 1 ..][0..3];
        const byte: u8 = if (std.mem.eql(u8, escape, "040"))
            ' '
        else if (std.mem.eql(u8, escape, "011"))
            '\t'
        else if (std.mem.eql(u8, escape, "012"))
            '\n'
        else if (std.mem.eql(u8, escape, "134"))
            '\\'
        else
            return error.InvalidMountTable;
        try decoded.append(gpa, byte);
        index += 4;
    }
    if (decoded.items.len == 0 or decoded.items[0] != '/') return error.InvalidMountTable;
    return decoded.toOwnedSlice(gpa);
}

fn isMountAncestor(mount_point: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, mount_point, path)) return true;
    if (mount_point.len == 1) return path.len > 1;
    if (!std.mem.startsWith(u8, path, mount_point)) return false;
    return path[mount_point.len] == '/';
}

test "mount escapes preserve separators and ancestor boundaries" {
    const decoded = try decodeMountPoint(std.testing.allocator, "/approved/work\\040space\\011tab\\012line\\134slash");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("/approved/work space\ttab\nline\\slash", decoded);
    try std.testing.expect(isMountAncestor(decoded, "/approved/work space\ttab\nline\\slash/corpus"));
    try std.testing.expect(!isMountAncestor(decoded, "/approved/work space\ttab\nline\\slash-other/corpus"));
    try std.testing.expect(isMountAncestor("/", "/approved/corpus"));
}

test "mount decoding fails closed on malformed kernel escapes" {
    for ([_][]const u8{ "", "relative", "/bad\\", "/bad\\04", "/bad\\777" }) |encoded| {
        try std.testing.expectError(error.InvalidMountTable, decodeMountPoint(std.testing.allocator, encoded));
    }
}

fn mountDecodeAllocationFailures(gpa: std.mem.Allocator) !void {
    const decoded = try decodeMountPoint(gpa, "/approved/work\\040space\\134suffix");
    defer gpa.free(decoded);
    try std.testing.expectEqualStrings("/approved/work space\\suffix", decoded);
}

test "mount decoding releases partial allocation on OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, mountDecodeAllocationFailures, .{});
}

// ---------------------------------------------------------------------------
// Row coverage
// ---------------------------------------------------------------------------

/// The one place the coverage rule lives.
///
/// `executed` means this row's evidence is an assertion somebody ran: the
/// package's own translated `#[cfg(test)]` module, counted into
/// `original_tests`, or a checked-in consumer that binds the row and calls into
/// it. `compile_only` is legal for exactly one kind of row — one whose
/// configuration publishes no API at all, so there is no value to call and the
/// artifact proves the configuration compiles. The inventory says so instead of
/// letting the compile read as coverage.
///
/// The fourth answer, a row with an API, no tests and no consumer, is
/// `no_value_assertion`, and it is a failure: that row's only evidence is that
/// it compiled. `run` counts it as a red row, and
/// `test/generated_corpus_build.zig` refuses to configure an inventory that
/// carries one, so the hole cannot be published in either direction.
fn classifyCoverage(row: Row, published: ?Facts, evidence: []const u8) Verdict {
    // A row that never reached a promoted package has no coverage to classify.
    // Calling it `compile_only` would claim a compile nobody observed.
    const facts = published orelse return .{
        .coverage = .not_staged,
        .reason = .not_staged,
        .evidence = "",
    };
    if (!row.has_api) return .{
        .coverage = .compile_only,
        .reason = .no_api_by_configuration,
        .evidence = "",
    };
    if (facts.original_tests != 0) return .{
        .coverage = .executed,
        .reason = .package_tests,
        .evidence = "",
    };
    if (evidence.len != 0) return .{
        .coverage = .executed,
        .reason = .consumer_binding,
        .evidence = evidence,
    };
    return .{ .coverage = .compile_only, .reason = .no_value_assertion, .evidence = "" };
}

/// One result per row, in row order, decided from what this run staged.
fn classifyRows(
    gpa: std.mem.Allocator,
    io: std.Io,
    packages_root: []const u8,
    staged: []const StagedRow,
) ![]RowResult {
    const bound = try consumerBoundRows(gpa, io, staged);
    const results = try gpa.alloc(RowResult, rows.len);
    for (rows, staged, results) |row, entry, *result| {
        result.* = .{
            .row = row,
            .package_dir = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ packages_root, row.id }),
            .verdict = classifyCoverage(row, entry.published, bound.get(row.id) orelse ""),
            .staged = entry,
        };
    }
    return results;
}

/// Every row a checked-in consumer binds, mapped to the consumer that names it.
///
/// This reads the consumer sources directly rather than going through
/// `resolveConsumers`, because the coverage verdict has to be reached on a run
/// that staged no aggregate and wrote no wiring. It resolves each name exactly
/// as `resolvedBindingsFor` does, so the two agree about which row a name
/// selects, and `writeAggregate` re-checks the answer against the wiring it
/// actually built before publishing an inventory built on it.
fn consumerBoundRows(
    gpa: std.mem.Allocator,
    io: std.Io,
    staged: []const StagedRow,
) !std.StringHashMapUnmanaged([]const u8) {
    var bound: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (consumers) |consumer| {
        const source = try readOwned(gpa, io, "", consumer.source);
        for (try collectImports(gpa, source)) |name| {
            if (std.mem.eql(u8, name, "std")) continue;
            if (isLocalImport(name)) continue;
            // A consumer that imports `translated` or `r2z` and names no
            // primary row cannot be wired, so it cannot be evidence for one
            // either; `writeAggregate` reports it by name on the green path.
            if (consumer.primary_row.len == 0 and
                (std.mem.eql(u8, name, primary_import_name) or
                    std.mem.eql(u8, name, runtime_import_name))) continue;
            for (try resolvedBindingsFor(gpa, consumer, name, staged)) |binding| {
                try bound.put(gpa, binding.row, consumer.source);
            }
        }
    }
    return bound;
}

// ---------------------------------------------------------------------------
// Aggregate assembly
// ---------------------------------------------------------------------------

/// A consumer with every `@import` resolved to a corpus row.
const ResolvedConsumer = struct {
    id: []const u8,
    /// Path inside the aggregate build root.
    file: []const u8,
    bindings: []Binding,
    pointer_widths: []u16,
};

fn writeAggregate(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    aggregate_root: []const u8,
    staged: []const StagedRow,
    results: []const RowResult,
) !void {
    const consumers_root = try std.fmt.allocPrint(
        gpa,
        "{s}/{s}",
        .{ aggregate_root, consumers_dir },
    );
    try std.Io.Dir.cwd().createDirPath(io, consumers_root);

    const runtime_row_id = try chooseRuntimeRow(staged);
    const resolved = try resolveConsumers(gpa, io, consumers_root, staged);

    // The bindings this aggregate will really build, as opposed to the
    // bindings the coverage scan read out of the same consumer sources. If the
    // two ever disagree, a row the inventory calls executed is executed by
    // nothing, so the disagreement is named here instead of reaching the
    // matrix as a silent hole.
    try requireBindingsMatchVerdicts(resolved, results);

    const config_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ aggregate_root, config_file });
    const config_text = try renderConfig(gpa, staged, resolved, runtime_row_id, results);
    try writeFile(io, config_path, config_text);

    const manifest_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ aggregate_root, manifest_file });
    try writeFile(io, manifest_path, try renderManifest(gpa));

    const build_path = try std.fmt.allocPrint(gpa, "{s}/build.zig", .{aggregate_root});
    try writeFile(io, build_path, aggregate_build_script);

    const profile_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ aggregate_root, profile_file });
    try writeFile(io, profile_path, try renderProfile(gpa, root, aggregate_root));
}

/// Every row whose coverage rests on a consumer binding must be named by a
/// binding this aggregate actually resolved.
///
/// Only one direction is checked. A row that carries its own translated tests
/// is `executed` whether or not a consumer also names it, so a bound row whose
/// verdict says `package_tests` is not a disagreement. The direction that is a
/// defect is a verdict resting on a consumer the wiring does not contain: the
/// scan reads the consumer sources directly so it can also run on a failed
/// staging run, and the two answering differently would mean the receipt and
/// the matrix describe different graphs.
fn requireBindingsMatchVerdicts(
    resolved: []const ResolvedConsumer,
    results: []const RowResult,
) !void {
    for (results) |result| {
        if (result.verdict.reason != .consumer_binding) continue;
        if (bindingNamesRow(resolved, result.row.id)) continue;
        std.log.err(
            "generated-corpus: row {s} is recorded as covered by {s}, but no resolved binding names it",
            .{ result.row.id, result.verdict.evidence },
        );
        return error.ConsumerBindingsDisagreeWithVerdicts;
    }
}

fn bindingNamesRow(resolved: []const ResolvedConsumer, row_id: []const u8) bool {
    for (resolved) |consumer| {
        for (consumer.bindings) |binding| {
            if (std.mem.eql(u8, binding.row, row_id)) return true;
        }
    }
    return false;
}

/// The first staged runtime is used only for its standalone test suite.
/// Consumer imports must reuse their own primary package's runtime identity.
fn chooseRuntimeRow(staged: []const StagedRow) ![]const u8 {
    for (rows, staged) |row, entry| {
        const vendored = entry.published orelse continue;
        if (!vendored.vendored_runtime) continue;
        return row.id;
    }
    return error.NoRowVendorsTheRuntime;
}

/// Copy each consumer verbatim and resolve every name it imports.
///
/// A name resolves to a row id first, then to the base id of a width-variant
/// group, and only then to the module name a package registered for itself. The
/// order matters for the two `xxhash-rust` configurations: they share a module
/// name, so importing it is ambiguous and must be reported rather than resolved
/// to whichever row happened to be generated first.
fn resolveConsumers(
    gpa: std.mem.Allocator,
    io: std.Io,
    consumers_root: []const u8,
    staged: []const StagedRow,
) ![]ResolvedConsumer {
    const resolved = try gpa.alloc(ResolvedConsumer, consumers.len);
    for (consumers, resolved) |consumer, *slot| {
        const source = try readOwned(gpa, io, "", consumer.source);
        const basename = std.fs.path.basename(consumer.source);
        const copy_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ consumers_root, basename });
        try writeFile(io, copy_path, source);
        // A consumer may `@import` a sibling source file, which has to sit beside
        // it in the aggregate for that relative import to resolve.
        try copyLocalImports(gpa, io, consumers_root, consumer.source, 0);

        var bindings: std.ArrayListUnmanaged(Binding) = .empty;
        var widths: std.ArrayListUnmanaged(u16) = .empty;
        for (try collectImports(gpa, source)) |name| {
            if (std.mem.eql(u8, name, "std")) continue;
            // A relative import names a file, not a corpus row; it was copied
            // beside this consumer above and resolves inside this module.
            if (isLocalImport(name)) continue;
            for (try resolvedBindingsFor(gpa, consumer, name, staged)) |binding| {
                try bindings.append(gpa, binding);
                try appendWidths(gpa, &widths, binding.pointer_widths);
            }
        }
        if (bindings.items.len == 0) {
            std.log.err(
                "generated-corpus: consumer '{s}' imports nothing from the corpus",
                .{consumer.source},
            );
            return error.ConsumerImportsNothing;
        }
        slot.* = .{
            .id = consumer.id,
            .file = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ consumers_dir, basename }),
            .bindings = bindings.items,
            .pointer_widths = widths.items,
        };
    }
    return resolved;
}

/// Every binding one of a consumer's `@import` names resolves to.
///
/// The coverage scan and the wiring share this so they cannot disagree about
/// which row a name selects. `translated` names the consumer's primary package
/// and `r2z` names that same package's runtime, which is why the two share a
/// row and differ only in kind.
fn resolvedBindingsFor(
    gpa: std.mem.Allocator,
    consumer: Consumer,
    name: []const u8,
    staged: []const StagedRow,
) ![]const Binding {
    const names_primary = std.mem.eql(u8, name, primary_import_name) or
        std.mem.eql(u8, name, runtime_import_name);
    if (names_primary) {
        if (consumer.primary_row.len == 0) {
            std.log.err(
                "generated-corpus: consumer '{s}' imports '{s}' but names no primary row",
                .{ consumer.source, name },
            );
            return error.ConsumerNamesNoPrimaryRow;
        }
        const primary = try primaryBinding(gpa, consumer);
        if (!std.mem.eql(u8, name, primary_import_name)) {
            return gpa.dupe(Binding, &.{.{
                .name = name,
                .row = primary.row,
                .kind = .runtime,
                .pointer_widths = primary.pointer_widths,
            }});
        }
        return gpa.dupe(Binding, &.{primary});
    }
    // An ambiguous name is a reportable inventory defect on either path; only
    // a name that resolves to nothing is tolerated here, because a row that
    // never staged cannot be named by the module it would have registered.
    const bindings = resolveImport(gpa, consumer, name, staged) catch |err| switch (err) {
        error.UnknownConsumerImport => return &[_]Binding{},
        else => return err,
    };
    return bindings;
}

fn appendWidths(
    gpa: std.mem.Allocator,
    widths: *std.ArrayListUnmanaged(u16),
    candidates: []const u16,
) !void {
    for (candidates) |width| {
        var present = false;
        for (widths.items) |existing| {
            if (existing == width) present = true;
        }
        if (!present) try widths.append(gpa, width);
    }
}

/// The binding behind a consumer's conventional `translated` import.
fn primaryBinding(gpa: std.mem.Allocator, consumer: Consumer) !Binding {
    for (rows) |row| {
        if (!std.mem.eql(u8, row.id, consumer.primary_row)) continue;
        return .{
            .name = primary_import_name,
            .row = row.id,
            .kind = .package,
            .pointer_widths = try widthsOf(gpa, row),
        };
    }
    std.log.err(
        "generated-corpus: consumer '{s}' names row '{s}', which is not in the corpus",
        .{ consumer.source, consumer.primary_row },
    );
    return error.UnknownConsumerPrimaryRow;
}

/// Copy every sibling source file `repo_path` imports by relative path, and
/// theirs in turn.
///
/// A consumer that pulls in an oracle module keeps working in the aggregate
/// instead of failing to compile there on an unresolved file.
fn copyLocalImports(
    gpa: std.mem.Allocator,
    io: std.Io,
    consumers_root: []const u8,
    repo_path: []const u8,
    depth: usize,
) !void {
    if (depth > local_import_depth_limit) return error.LocalImportCycle;
    const source = try readOwned(gpa, io, "", repo_path);
    const directory = std.fs.path.dirname(repo_path) orelse ".";
    for (try collectImports(gpa, source)) |name| {
        if (!isLocalImport(name)) continue;
        const target = try std.fs.path.join(gpa, &.{ directory, name });
        const copied = try std.fmt.allocPrint(
            gpa,
            "{s}/{s}",
            .{ consumers_root, std.fs.path.basename(name) },
        );
        try writeFile(io, copied, try readOwned(gpa, io, "", target));
        try copyLocalImports(gpa, io, consumers_root, target, depth + 1);
    }
}

/// A module name never carries a file extension and a relative import always
/// does, so the extension is the whole test.
fn isLocalImport(name: []const u8) bool {
    return name.len != 0 and std.mem.endsWith(u8, name, ".zig");
}

/// Every `@import("…")` operand in a consumer, in source order and deduplicated.
fn collectImports(gpa: std.mem.Allocator, source: []const u8) ![][]const u8 {
    const needle = "@import(\"";
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, needle)) |start| {
        const name_start = start + needle.len;
        const end = std.mem.indexOfScalarPos(u8, source, name_start, '"') orelse break;
        const name = source[name_start..end];
        cursor = end + 1;
        var seen = false;
        for (names.items) |existing| {
            if (std.mem.eql(u8, existing, name)) seen = true;
        }
        if (!seen) try names.append(gpa, name);
    }
    return names.items;
}

fn resolveImport(
    gpa: std.mem.Allocator,
    consumer: Consumer,
    name: []const u8,
    staged: []const StagedRow,
) ![]Binding {
    var bindings: std.ArrayListUnmanaged(Binding) = .empty;

    // An exact row id names one configuration unambiguously.
    for (rows) |row| {
        if (!std.mem.eql(u8, row.id, name)) continue;
        try bindings.append(gpa, .{
            .name = name,
            .row = row.id,
            .kind = .package,
            .pointer_widths = try widthsOf(gpa, row),
        });
        return bindings.items;
    }

    // A base id names a whole width-variant group, one binding per width, so a
    // single consumer source works on both a 32-bit and a 64-bit target.
    for (rows) |row| {
        if (!std.mem.eql(u8, baseId(row.id), name)) continue;
        try bindings.append(gpa, .{
            .name = name,
            .row = row.id,
            .kind = .package,
            .pointer_widths = try widthsOf(gpa, row),
        });
    }
    if (bindings.items.len != 0) return bindings.items;

    // Finally the name the package registered for itself.
    for (rows, staged) |row, entry| {
        const published = entry.published orelse continue;
        if (!std.mem.eql(u8, published.module, name)) continue;
        try bindings.append(gpa, .{
            .name = name,
            .row = row.id,
            .kind = .package,
            .pointer_widths = try widthsOf(gpa, row),
        });
    }
    switch (bindings.items.len) {
        1 => return bindings.items,
        0 => {
            std.log.err(
                "generated-corpus: consumer '{s}' imports '{s}', which names no corpus row",
                .{ consumer.source, name },
            );
            return error.UnknownConsumerImport;
        },
        else => {
            std.log.err(
                "generated-corpus: consumer '{s}' imports '{s}', which {d} rows publish",
                .{ consumer.source, name, bindings.items.len },
            );
            for (bindings.items) |binding| {
                std.log.err(
                    "generated-corpus:   import '{s}' as @import(\"{s}\")",
                    .{ binding.row, binding.name },
                );
            }
            return error.AmbiguousConsumerImport;
        },
    }
}

/// The width-suffix-stripped identity of a row: `hex-w32` and `hex-w64` both
/// answer to `hex`.
fn baseId(id: []const u8) []const u8 {
    const suffixes = [_][]const u8{ "-w32", "-w64" };
    for (suffixes) |suffix| {
        if (!std.mem.endsWith(u8, id, suffix)) continue;
        return id[0 .. id.len - suffix.len];
    }
    return id;
}

fn widthsOf(gpa: std.mem.Allocator, row: Row) ![]u16 {
    switch (row.width) {
        .any => return gpa.dupe(u16, &all_widths),
        .w32 => return gpa.dupe(u16, &.{32}),
        .w64 => return gpa.dupe(u16, &.{64}),
    }
}

// ---------------------------------------------------------------------------
// Generated aggregate files
// ---------------------------------------------------------------------------

fn renderConfig(
    gpa: std.mem.Allocator,
    staged: []const StagedRow,
    resolved: []const ResolvedConsumer,
    runtime_row_id: []const u8,
    results: []const RowResult,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll(
        \\//! Generated by test/generated_corpus.zig. Do not edit.
        \\//!
        \\//! One entry per staged generated package, plus one entry per consumer
        \\//! file copied verbatim into this directory. `test/generated_corpus_build.zig`
        \\//! is the build script that reads this file.
        \\
        \\const std = @import("std");
        \\
        \\/// What a consumer's `@import` resolves to.
        \\pub const BindingKind = enum { package, runtime };
        \\
        \\/// What a row's evidence is. `executed` means an assertion somebody
        \\/// ran in this row; `compile_only` means the row exists to prove a
        \\/// configuration compiles, which is legal only for a configuration
        \\/// that publishes no value to call; `not_staged` names a row that
        \\/// never reached a promoted package and cannot appear here at all.
        \\/// The build script refuses to configure over an API-bearing row that
        \\/// is `compile_only` or over an `executed` row nothing runs a value in.
        \\pub const Coverage = enum { executed, compile_only, not_staged };
        \\
        \\/// One generated package: how to reach it, and what it turned out to be.
        \\pub const Row = struct {
        \\    /// The dependency key in this package's build.zig.zon.
        \\    dependency: []const u8,
        \\    /// The module name the generated package registered for itself.
        \\    module: []const u8,
        \\    /// The `.name` the generated manifest declares.
        \\    zon_name: []const u8,
        \\    /// Directory of the staged package, relative to this build root.
        \\    package_dir: []const u8,
        \\    /// The pointer widths this package was generated for.
        \\    pointer_widths: []const u16,
        \\    /// The `#[cfg(feature = ...)]` selection it was generated with.
        \\    features: []const []const u8,
        \\    /// Whether this configuration publishes an API at all.
        \\    has_api: bool,
        \\    /// Whether the package vendors the Rust-core runtime.
        \\    vendored_runtime: bool,
        \\    /// `test` declarations in the package's own translated sources.
        \\    original_tests: usize,
        \\    /// What this row's evidence is. Carried as data rather than
        \\    /// re-derived here: the producer decided it from what this run
        \\    /// staged and from what the checked-in consumers name, and the
        \\    /// build script checks the verdict against the graph it builds.
        \\    coverage: Coverage,
        \\    /// Why that verdict holds, for a reader deciding whether to trust it.
        \\    coverage_reason: []const u8,
        \\    /// How it was produced.
        \\    provenance: []const u8,
        \\    /// What is distinctive about this row.
        \\    note: []const u8,
        \\};
        \\
        \\pub const Binding = struct {
        \\    name: []const u8,
        \\    row: []const u8,
        \\    kind: BindingKind,
        \\    pointer_widths: []const u16,
        \\};
        \\
        \\pub const Consumer = struct {
        \\    id: []const u8,
        \\    file: []const u8,
        \\    pointer_widths: []const u16,
        \\    bindings: []const Binding,
        \\};
        \\
        \\/// Coverage modes pinned by the corpus. Both are built in one graph,
        \\/// so no option can drop one of them. Emitted from the producer's own
        \\/// list rather than restated here, because a second copy is a mode
        \\/// this graph silently stops covering the day the two drift apart.
        \\pub const optimize_modes = [_]std.builtin.OptimizeMode{
    );
    for (optimize_modes) |mode| {
        try w.writeAll("    .");
        try w.writeAll(@tagName(mode));
        try w.writeAll(",\n");
    }
    try w.writeAll(
        \\};
        \\
        \\/// Row whose vendored runtime supplies the standalone runtime test suite.
        \\/// Consumers instead import their primary registered module's runtime.
        \\pub const runtime_row_id =
    );
    try emitQuoted(w, runtime_row_id);
    try w.writeAll(
        \\;
        \\/// Artifact name of the runtime's own test suite.
        \\pub const runtime_test_id =
    );
    try emitQuoted(w, runtime_test_id);
    try w.writeAll(
        \\;
        \\/// Source path of that runtime copy, relative to this build root.
        \\pub const runtime_source_path =
    );
    try emitQuoted(
        w,
        try std.fmt.allocPrint(
            gpa,
            "{s}/{s}/{s}/{s}",
            .{ packages_dir, runtime_row_id, runtime_directory, runtime_root_source },
        ),
    );

    try w.writeAll(";\n\npub const rows = [_]Row{\n");
    for (rows, staged, results) |row, entry, result| {
        // The aggregate is written only when every row staged, so a missing
        // publication here means the run is not building an aggregate at all.
        // Saying so beats writing a row of invented values into an inventory
        // the build script would then have to trust.
        const published = entry.published orelse return error.RowNotStaged;
        const widths = try widthsOf(gpa, row);
        try w.writeAll("    .{\n        .dependency = ");
        try emitQuoted(w, row.id);
        try w.writeAll(",\n        .module = ");
        try emitQuoted(w, published.module);
        try w.writeAll(",\n        .zon_name = ");
        try emitQuoted(w, published.zon_name);
        try w.writeAll(",\n        .package_dir = ");
        try emitQuoted(
            w,
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ packages_dir, row.id }),
        );
        try w.writeAll(",\n        .pointer_widths = ");
        try emitU16Slice(w, widths);
        try w.writeAll(",\n        .features = ");
        try emitStringSlice(w, row.features);
        try w.writeAll(",\n        .has_api = ");
        try w.writeAll(if (row.has_api) "true" else "false");
        try w.writeAll(",\n        .vendored_runtime = ");
        try w.writeAll(if (published.vendored_runtime) "true" else "false");
        try w.print(",\n        .original_tests = {d}", .{published.original_tests});
        try w.writeAll(",\n        .coverage = .");
        try w.writeAll(@tagName(result.verdict.coverage));
        try w.writeAll(",\n        .coverage_reason = ");
        try emitQuoted(w, @tagName(result.verdict.reason));
        try w.writeAll(",\n        .provenance = ");
        try emitQuoted(w, provenanceOf(row));
        try w.writeAll(",\n        .note = ");
        try emitQuoted(w, row.note);
        try w.writeAll(",\n    },\n");
    }
    try w.writeAll("};\n\npub const consumers = [_]Consumer{\n");
    for (resolved) |consumer| {
        try w.writeAll("    .{\n        .id = ");
        try emitQuoted(w, consumer.id);
        try w.writeAll(",\n        .file = ");
        try emitQuoted(w, consumer.file);
        try w.writeAll(",\n        .pointer_widths = ");
        try emitU16Slice(w, consumer.pointer_widths);
        try w.writeAll(",\n        .bindings = &.{\n");
        for (consumer.bindings) |binding| {
            try w.writeAll("            .{ .name = ");
            try emitQuoted(w, binding.name);
            try w.writeAll(", .row = ");
            try emitQuoted(w, binding.row);
            try w.writeAll(", .kind = .");
            try w.writeAll(@tagName(binding.kind));
            try w.writeAll(", .pointer_widths = ");
            try emitU16Slice(w, binding.pointer_widths);
            try w.writeAll(" },\n");
        }
        try w.writeAll("        },\n    },\n");
    }
    try w.writeAll(
        \\};
        \\
        \\/// The corpus row a binding names. Null when the inventory is wrong, which
        \\/// the build script reports rather than compiling a consumer against a
        \\/// module it never got.
        \\pub fn rowById(id: []const u8) ?Row {
        \\    for (rows) |row| {
        \\        if (std.mem.eql(u8, row.dependency, id)) return row;
        \\    }
        \\    return null;
        \\}
        \\
    );
    return out.toOwnedSlice();
}

fn provenanceOf(row: Row) []const u8 {
    return switch (row.kind) {
        .source => row.crate_dir,
        .wire_fixture => row.fixture,
        .wire_canonical => "canonical v6 wire re-encoded in this run",
        .serialized_ast => "lowered package round-tripped through serialized Zig AST bytes",
    };
}

/// The dependency table. Dependency keys are row ids, which need not equal the
/// name a generated package declares: `xxhash-default` and `xxhash-xxh32` are
/// two configurations of one crate and would otherwise collide.
fn renderManifest(gpa: std.mem.Allocator) ![]u8 {
    const checksum = std.hash.Crc32.hash(aggregate_package_name);
    const fingerprint: u64 = (@as(u64, checksum) << 32) | aggregate_fingerprint_id;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    try w.print(
        \\.{{
        \\    .name = .{s},
        \\    .version = "0.0.0",
        \\    .fingerprint = 0x{x:0>16},
        \\    .minimum_zig_version = "0.17.0",
        \\    .dependencies = .{{
        \\
    , .{ aggregate_package_name, fingerprint });
    for (rows) |row| {
        try w.writeAll("        .@");
        try emitQuoted(w, row.id);
        try w.writeAll(" = .{ .path = ");
        try emitQuoted(w, try std.fmt.allocPrint(gpa, "{s}/{s}", .{ packages_dir, row.id }));
        try w.writeAll(" },\n");
    }
    try w.writeAll(
        \\    },
        \\    .paths = .{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "corpus_config.zig",
        \\        "consumers",
        \\        "packages",
        \\    },
        \\}
        \\
    );
    return out.toOwnedSlice();
}

fn emitQuoted(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"', '\\' => {
                try w.writeByte('\\');
                try w.writeByte(byte);
            },
            '\n' => try w.writeAll("\\n"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(byte),
        }
    }
    try w.writeByte('"');
}

fn emitU16Slice(w: *std.Io.Writer, values: []const u16) std.Io.Writer.Error!void {
    try w.writeAll("&.{");
    for (values, 0..) |value, index| {
        if (index != 0) try w.writeAll(", ");
        try w.print("{d}", .{value});
    }
    try w.writeAll("}");
}

fn emitStringSlice(w: *std.Io.Writer, values: []const []const u8) std.Io.Writer.Error!void {
    try w.writeAll("&.{");
    for (values, 0..) |value, index| {
        if (index != 0) try w.writeAll(", ");
        try emitQuoted(w, value);
    }
    try w.writeAll("}");
}

/// Quote a literal shell word without expansion, including embedded apostrophes.
fn emitShellQuoted(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('\'');
    for (text) |byte| {
        if (byte == '\'') {
            try w.writeAll("'\\''");
        } else {
            try w.writeByte(byte);
        }
    }
    try w.writeByte('\'');
}

/// The cross-test profile this aggregate is measured with.
///
/// No `CROSS_MATRIX`: cross-test then runs its own version-pinned Tier 1/2 table
/// for Zig 0.17.0 with automatic runner detection, and a row whose runner is
/// missing is reported build-only rather than as a pass. Jobs are 1 because all
/// targets share one cache directory and concurrent Zig builds over one cache
/// abort. The deadlines are the shared gate's.
///
/// The detection this relies on is cross-test's, and cross-test tells the build
/// about it: it exports `CROSS_TEST_RUNNER_KIND` into every build it starts, and
/// the aggregate's `build.zig` — this file's `generated_corpus_build.zig`, copied
/// beside it — reads it to decide whether a row may execute. The two halves are
/// one contract, so neither is described here as if it worked alone: without the
/// export every foreign row would fail to launch, and without the read the export
/// would say nothing.
///
/// `cleanup` is replaced because cross-test's own removes the per-run cache and
/// state directories on exit. Those are this run's only record of what each
/// target compiled, and the parent inspects them afterwards, so the two
/// deletions are dropped and the retained paths are recorded instead.
fn renderProfile(gpa: std.mem.Allocator, root: []const u8, aggregate_root: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll(
        \\#!/usr/bin/env bash
        \\# cross-test profile for the generated-corpus aggregate.
        \\# Generated by test/generated_corpus.zig; do not edit.
        \\#
        \\# The build step is the aggregate's own pure test graph. Every artifact in
        \\# it is a test binary or a consumer: no step spawns a compiler, a shell or
        \\# the producer, so a foreign target row cannot execute the host toolchain.
        \\#
        \\# Optimize coverage is not selected here. The aggregate builds Debug and
        \\# ReleaseSafe as separate artifacts in the same graph, so there is no flag
        \\# that could drop one of them.
        \\#
        \\# What a row may claim comes from the runner, and the runner comes from
        \\# cross-test: it exports CROSS_TEST_RUNNER_KIND into every build it starts,
        \\# and the aggregate's build.zig reads it. `native` executes here, `exec`
        \\# permits the build system to reach for qemu/wasmtime/wine for this target,
        \\# and `unavailable` compiles every artifact and skips every run, which is
        \\# what makes that row build-only rather than a build failure or a pass.
        \\# Nothing in this profile can widen that: a runner is permitted only where
        \\# the census found one, so a target with no runner is compile-only even if
        \\# an interpreter for some other target is on PATH.
        \\
        \\CROSS_BUILD_STEP=test
        \\CROSS_TIMEOUT=900
        \\CROSS_BUILD_TIMEOUT=1800
        \\CROSS_JOBS=1
        \\CROSS_BUILD_JOBS=1
        \\# Build-only coverage is explicit, never a pass, and is reported per row.
        \\CROSS_REQUIRE_RUNNERS=0
        \\
        \\# Host policy was sourced first; restore the wrapper's measured locked root.
        \\: "${R2Z_MATRIX_CACHE_ROOT:?generated corpus requires its measured cache root}"
        \\[[ $R2Z_MATRIX_CACHE_ROOT == /* && -d $R2Z_MATRIX_CACHE_ROOT ]] || {
        \\  printf 'generated corpus: invalid measured cache root\n' >&2
        \\  return 1
        \\}
        \\export TMPDIR="$R2Z_MATRIX_CACHE_ROOT" TMP="$R2Z_MATRIX_CACHE_ROOT" TEMP="$R2Z_MATRIX_CACHE_ROOT"
        \\export ZIG_GLOBAL_CACHE_DIR="$R2Z_MATRIX_CACHE_ROOT"
        \\
    );
    try w.writeAll("CROSS_PREFIX=");
    try emitShellQuoted(w, try std.fmt.allocPrint(gpa, "{s}/cross-test-out", .{root}));
    try w.writeAll(
        \\
        \\
        \\# cross-test defines cleanup() before it sources this profile, so this
        \\# definition replaces it. Everything upstream does is kept; only its two
        \\# `rm -rf` calls on the run's own cache and state are left out.
        \\corpus_cleanup() {
        \\  local rc=$?
        \\  trap - EXIT INT TERM HUP
        \\  stop_workers
        \\  if [[ ${SUMMARY_STARTED:-0} == 1 && ${SUMMARY_FINISHED:-0} != 1 ]]; then
        \\    local target
        \\    for target in "${TARGETS[@]}"; do
        \\      [[ ${FINAL_STATUS[$target]} != pending ]] || {
        \\        if [[ ${BUILD_STATUS[$target]} == pending ]]; then BUILD_STATUS[$target]=interrupted; fi
        \\        RUN_STATUS[$target]=interrupted; REASON[$target]=interrupted
        \\      }
        \\    done
        \\    recount
        \\    publish_summary interrupted "$rc" || printf 'cross-test: interrupted summary write failed\n' >&2
        \\  fi
        \\  # Upstream ends here with `rm -rf "$CACHE_DIR"` and `rm -rf "$STATE_DIR"`.
        \\  # Those are this run's only record of what each target compiled; they are
        \\  # retained for the parent and their paths recorded so a live-use guard can
        \\  # see them.
        \\  local retained=() dir
        \\  for dir in "${CACHE_DIR:-}" "${STATE_DIR:-}"; do
        \\    [[ -n $dir ]] || continue
        \\    if [[ -d $dir ]]; then
        \\      retained+=("$dir")
        \\    else
        \\      printf 'cross-test: retained path %s is already gone\n' "$dir" >&2
        \\    fi
        \\  done
        \\  if ((${#retained[@]})); then
        \\    printf '%s\n' "${retained[@]}" >
    );
    try w.writeAll(" ");
    try emitShellQuoted(w, try std.fmt.allocPrint(gpa, "{s}/retained-state.txt", .{aggregate_root}));
    try w.writeAll(
        \\ || printf 'cross-test: could not record the retained state paths\n' >&2
        \\  fi
        \\}
        \\cleanup() { corpus_cleanup "$@"; }
        \\
    );
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Per-row receipt
// ---------------------------------------------------------------------------

/// The machine-readable record of what every row did, written on every run.
///
/// A row is one entry whatever happened to it. A failure carries the error it
/// failed with and claims no package facts, because a row that never reached a
/// promoted package has no module name, no manifest name and no test count to
/// report. The coverage verdict is present on every row so a reader can tell a
/// compile-only configuration from one nobody measured, which is the
/// difference the run's exit code alone does not carry.
fn renderResults(gpa: std.mem.Allocator, results: []const RowResult, aggregate_written: bool) ![]u8 {
    var staged_count: usize = 0;
    // Counted one variable per verdict so a variant added to `Coverage` later
    // fails to compile here instead of going unreported in the receipt.
    var executed: usize = 0;
    var compile_only: usize = 0;
    var not_staged: usize = 0;
    for (results) |result| {
        if (result.staged.published != null) staged_count += 1;
        switch (result.verdict.coverage) {
            .executed => executed += 1,
            .compile_only => compile_only += 1,
            .not_staged => not_staged += 1,
        }
    }

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;

    try w.print("{{\n  \"schema\": {d},\n", .{results_schema});
    try w.print(
        \\  "aggregate_written": {s},
        \\  "row_count": {d},
        \\  "staged": {d},
        \\  "failed": {d},
        \\
    , .{
        if (aggregate_written) "true" else "false",
        results.len,
        staged_count,
        results.len - staged_count,
    });
    try w.print(
        \\  "executed": {d},
        \\  "compile_only": {d},
        \\  "not_staged": {d},
        \\
    , .{ executed, compile_only, not_staged });
    try w.writeAll("  \"rows\": [\n");
    for (results, 0..) |result, index| {
        const published = result.staged.published;
        try w.writeAll("    {\n      \"id\": ");
        try emitJsonString(w, result.row.id);
        try w.writeAll(",\n      \"kind\": ");
        try emitJsonString(w, @tagName(result.row.kind));
        try w.writeAll(",\n      \"provenance\": ");
        try emitJsonString(w, provenanceOf(result.row));
        try w.writeAll(",\n      \"package_dir\": ");
        try emitJsonString(w, result.package_dir);
        try w.writeAll(",\n      \"features\": ");
        try emitJsonArray(w, result.row.features);
        try w.writeAll(",\n      \"pointer_widths\": ");
        try emitJsonNumberArray(w, try widthsOf(gpa, result.row));
        try w.writeAll(",\n      \"has_api\": ");
        try w.writeAll(if (result.row.has_api) "true" else "false");
        try w.writeAll(",\n      \"status\": ");
        try emitJsonString(w, @tagName(statusOf(result)));
        try w.writeAll(",\n      \"error\": ");
        if (result.staged.error_name) |name| {
            try emitJsonString(w, name);
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\n      \"coverage\": ");
        try emitJsonString(w, @tagName(result.verdict.coverage));
        try w.writeAll(",\n      \"coverage_reason\": ");
        try emitJsonString(w, @tagName(result.verdict.reason));
        try w.writeAll(",\n      \"coverage_evidence\": ");
        try emitJsonString(w, result.verdict.evidence);
        try w.writeAll(",\n      \"module\": ");
        if (published) |facts| {
            try emitJsonString(w, facts.module);
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\n      \"zon_name\": ");
        if (published) |facts| {
            try emitJsonString(w, facts.zon_name);
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\n      \"vendored_runtime\": ");
        if (published) |facts| {
            try w.writeAll(if (facts.vendored_runtime) "true" else "false");
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\n      \"original_tests\": ");
        if (published) |facts| {
            try w.print("{d}", .{facts.original_tests});
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\n      \"note\": ");
        try emitJsonString(w, result.row.note);
        try w.writeAll(if (index + 1 == results.len) "\n    }\n" else "\n    },\n");
    }
    try w.writeAll("  ]\n}\n");
    return out.toOwnedSlice();
}

/// A JSON string literal.
///
/// Not `emitQuoted`: that writes Zig source and escapes only the four bytes Zig
/// needs. JSON forbids every control byte below 0x20, so a note or an error name
/// carrying one has to be escaped here or the whole receipt stops parsing.
/// Bytes above 0x7f pass through, which is correct for the UTF-8 these strings
/// already are.
fn emitJsonString(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0x08 => try w.writeAll("\\b"),
            '\t' => try w.writeAll("\\t"),
            '\n' => try w.writeAll("\\n"),
            0x0c => try w.writeAll("\\f"),
            '\r' => try w.writeAll("\\r"),
            else => {
                if (byte < 0x20) {
                    try w.print("\\u{x:0>4}", .{byte});
                } else {
                    try w.writeByte(byte);
                }
            },
        }
    }
    try w.writeByte('"');
}

fn emitJsonArray(w: *std.Io.Writer, values: []const []const u8) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (values, 0..) |value, index| {
        if (index != 0) try w.writeAll(", ");
        try emitJsonString(w, value);
    }
    try w.writeByte(']');
}

fn emitJsonNumberArray(w: *std.Io.Writer, values: []const u16) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (values, 0..) |value, index| {
        if (index != 0) try w.writeAll(", ");
        try w.print("{d}", .{value});
    }
    try w.writeByte(']');
}

// ---------------------------------------------------------------------------
// Coverage rule
// ---------------------------------------------------------------------------

test "a configuration that publishes no API is compile-only by construction" {
    const verdict = classifyCoverage(emptyRow(false), factsWithTests(0), "");
    try std.testing.expectEqual(Coverage.compile_only, verdict.coverage);
    try std.testing.expectEqual(CoverageReason.no_api_by_configuration, verdict.reason);
}

test "a row's own translated tests are executed coverage" {
    const verdict = classifyCoverage(emptyRow(true), factsWithTests(24), "");
    try std.testing.expectEqual(Coverage.executed, verdict.coverage);
    try std.testing.expectEqual(CoverageReason.package_tests, verdict.reason);
    try std.testing.expectEqualStrings("", verdict.evidence);
}

test "a consumer binding a testless row is executed coverage" {
    const verdict = classifyCoverage(emptyRow(true), factsWithTests(0), "test/some_consumer.zig");
    try std.testing.expectEqual(Coverage.executed, verdict.coverage);
    try std.testing.expectEqual(CoverageReason.consumer_binding, verdict.reason);
    try std.testing.expectEqualStrings("test/some_consumer.zig", verdict.evidence);
}

test "an API-bearing row nothing runs a value in is build-only, never a pass" {
    const verdict = classifyCoverage(emptyRow(true), factsWithTests(0), "");
    try std.testing.expectEqual(Coverage.compile_only, verdict.coverage);
    try std.testing.expectEqual(CoverageReason.no_value_assertion, verdict.reason);
}

test "a row that never staged claims no coverage at all" {
    // Neither `compile_only` nor `executed`: nobody compiled it and nobody ran
    // anything in it, so either verdict would assert an observation this run
    // never made.
    const verdict = classifyCoverage(emptyRow(true), null, "");
    try std.testing.expectEqual(Coverage.not_staged, verdict.coverage);
    try std.testing.expectEqual(CoverageReason.not_staged, verdict.reason);
}

test "the receipt status follows the promotion, not the verdict" {
    // A row that published an API and still failed to stage is `failed`, and a
    // compile-only configuration that staged is `staged`: the two fields answer
    // different questions and neither is derived from the other.
    try std.testing.expectEqual(RowStatus.failed, statusOf(.{
        .row = emptyRow(true),
        .package_dir = "",
        .verdict = classifyCoverage(emptyRow(true), null, ""),
        .staged = .{ .published = null, .error_name = "UnsupportedExpression" },
    }));
    try std.testing.expectEqual(RowStatus.staged, statusOf(.{
        .row = emptyRow(false),
        .package_dir = "",
        .verdict = classifyCoverage(emptyRow(false), factsWithTests(0), ""),
        .staged = .{ .published = factsWithTests(0), .error_name = null },
    }));
}

test "a consumer's runtime import names its primary row and nothing else" {
    // One arena over the testing allocator: the widths a binding carries are
    // released with everything else, so the leak check sees the real balance.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const none: []const StagedRow = &.{};
    const consumer: Consumer = .{ .id = "probe", .source = "test/probe.zig", .primary_row = "adler" };

    const package = try resolvedBindingsFor(gpa, consumer, "translated", none);
    try std.testing.expectEqual(@as(usize, 1), package.len);
    try std.testing.expectEqualStrings("adler", package[0].row);
    try std.testing.expectEqual(BindingKind.package, package[0].kind);

    const runtime = try resolvedBindingsFor(gpa, consumer, "r2z", none);
    try std.testing.expectEqual(@as(usize, 1), runtime.len);
    try std.testing.expectEqualStrings("adler", runtime[0].row);
    try std.testing.expectEqual(BindingKind.runtime, runtime[0].kind);
}

test "a consumer that names no primary row cannot resolve its own imports" {
    const none: []const StagedRow = &.{};
    const consumer: Consumer = .{ .id = "probe", .source = "test/probe.zig", .primary_row = "" };
    try std.testing.expectError(
        error.ConsumerNamesNoPrimaryRow,
        resolvedBindingsFor(std.testing.allocator, consumer, "translated", none),
    );
    try std.testing.expectError(
        error.ConsumerNamesNoPrimaryRow,
        resolvedBindingsFor(std.testing.allocator, consumer, "r2z", none),
    );
}

/// A row with only the field the coverage rule reads, so the tests above state
/// the rule and not a fixture's shape.
fn emptyRow(has_api: bool) Row {
    return .{
        .id = "probe",
        .kind = .source,
        .crate_dir = "",
        .fixture = "",
        .features = &.{},
        .width = .any,
        .has_api = has_api,
        .note = "",
    };
}

fn factsWithTests(count: usize) Facts {
    return .{
        .module = "probe",
        .zon_name = "probe",
        .vendored_runtime = false,
        .original_tests = count,
    };
}
