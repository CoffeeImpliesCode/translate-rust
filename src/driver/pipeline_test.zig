//! translate_rust.driver.pipeline_test — the INPUT-AVAILABILITY policy.
//!
//! Four corpus crates stop at this boundary rather than at lowering. Each test
//! below drives the real driver over the real fixture and asserts BOTH halves of
//! the claim: the error the run raises, and the input that error names. Asserting
//! only the error would let a renamed or swapped boundary pass; asserting only
//! the policy table would let the table drift away from what the crates do.
//!
//! The four are deliberately NOT interchangeable. `crc16` needs a program to be
//! executed, `fletcher` and `leb128` need source from a crate that was never
//! read, and `syn` needs a target configuration. Three of the four are named in
//! README's pinned-refusal table and `test/e2e_test.zig`'s
//! `refused_source_crates`; `syn` is recorded as `.unmeasured` in `build.zig`'s
//! `corpus_rows` because it is staged by no node and pins an error by none.

const std = @import("std");
const pipeline = @import("pipeline.zig");
const ingest = @import("translate_rust.frontend").ingest;

/// Translate `crate_dir` and return the error it refused with.
///
/// The out_dir is a fresh directory per call so a crate that DID translate
/// cannot be mistaken for one that refused, and so a refusal is observed on the
/// same path a caller would see. Analysis runs before any package is staged, so
/// these four never reach promotion and never build anything.
///
/// The return is `anyerror!void` rather than `!anyerror` because an error union
/// may not carry an error set as its payload, and no narrower named set exists:
/// `translate` names no error set of its own, so the refusal a caller compares
/// against can be any of the ones analysis raises.
///
/// A caller lifts the error back out with an `if` whose two arms are BOTH error
/// sets, so peer type resolution gives it `anyerror`:
/// `if (refusalFrom(...)) |_| error.X else |err| err`. `catch |err| err` cannot
/// do this job, because the arms it peer-resolves are the `void` payload and
/// the error, and those resolve to an error union rather than to an error set.
fn refusalFrom(
    allocator: std.mem.Allocator,
    test_io: std.Io,
    crate_dir: []const u8,
    out_dir: []const u8,
) anyerror!void {
    if (pipeline.translate(allocator, test_io, crate_dir, out_dir)) |_| {
        return error.ExpectedRefusalButTranslated;
    } else |err| {
        return err;
    }
}

fn crateOutDir(
    allocator: std.mem.Allocator,
    tmp_root: []const u8,
    name: []const u8,
) ![]const u8 {
    return std.fs.path.join(allocator, &.{ tmp_root, name });
}

// ── crc16: a build script is a program, and translating is not running it ─────

// `crc16`'s `src/lib.rs:30` is `include!(concat!(env!("OUT_DIR"), "/tables.rs"))`
// and its `build.rs` writes that file by running the CRC table loop. The
// artifact is a genuine INPUT-AVAILABILITY boundary and not a lowering gap:
// `frontend/cst.zig` reaches `artifactIncludePath`, finds the `OUT_DIR`
// `concat!` and the `tables.rs` literal, and raises
// `error.BuildScriptArtifactUnavailable` with
// `reason = .build_script_not_executed`. Nothing in this translator executes
// `build.rs`, so no lowering change can make the table appear.
test "crc16 refuses on the build script artifact, not on lowering" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    const out_dir = try crateOutDir(allocator, tmp_root, "crc16");
    defer allocator.free(out_dir);

    const err = if (refusalFrom(allocator, test_io, "test/crates/crc16", out_dir)) |_|
        error.ExpectedRefusalButTranslated
    else |refusal|
        refusal;
    try std.testing.expectEqual(error.BuildScriptArtifactUnavailable, err);

    const explanation = pipeline.explainRefusal(err) orelse
        return error.BuildScriptRefusalUnclassified;
    try std.testing.expectEqual(pipeline.RefusalKind.build_script_artifact, explanation.kind);
    try std.testing.expect(std.mem.indexOf(u8, explanation.missing, "EXECUTED") != null);

    // The artifact the refusal names is the crate's own, so the reason is
    // checkable against the fixture rather than taken on trust.
    const lib_source = try pipeline.readFileAlloc(
        allocator,
        test_io,
        "test/crates/crc16/src/lib.rs",
    );
    defer allocator.free(lib_source);
    try std.testing.expect(std.mem.indexOf(u8, lib_source, "OUT_DIR") != null);
    try std.testing.expect(std.mem.indexOf(u8, lib_source, "tables.rs") != null);
}

// The manifest handling agrees this is a build-script crate, so the refusal is
// not an accident of a missing `build` key: `ingest` resolves the root source
// and the crate really does carry a `build.rs` beside it.
test "crc16 carries the build script whose output the refusal names" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;

    const manifest = try ingest.loadCrateManifest(allocator, test_io, "test/crates/crc16");
    defer ingest.deinitLoadedManifest(allocator, manifest);
    try std.testing.expectEqualStrings("crc16", manifest.name);
    try std.testing.expectEqual(@as(usize, 0), manifest.dependencies.len);

    const build_script = try pipeline.readFileAlloc(
        allocator,
        test_io,
        "test/crates/crc16/build.rs",
    );
    defer allocator.free(build_script);
    // The script WRITES the artifact; that is what makes it a program rather
    // than a declaration the translator could read.
    try std.testing.expect(std.mem.indexOf(u8, build_script, "OUT_DIR") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_script, "tables.rs") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_script, "fn main()") != null);
}

// ── fletcher: an external macro body, NOT the checksum tables ────────────────

// fletcher's recorded reason — "the checksum tables live behind external
// `macro_rules!` expansions" — names the WRONG input, and this test pins the
// right one. The crate declares NO `macro_rules!` at all and has zero
// dependencies (`Cargo.toml` has no `[dependencies]` section), so its checksum
// tables are ordinary `const`/computed values, not expansions. What it does
// carry is `extern crate quickcheck;` at `src/lib.rs:66` and three
// `quickcheck! { ... }` invocations inside `#[cfg(test)] mod test`
// (`src/lib.rs:396`, `477`, `551`). The invocation's `macro_rules!` body is
// defined in the quickcheck crate, whose source is not part of this input.
//
// The refusal itself is correct — `frontend/cst.zig` cannot find `quickcheck` in
// the in-crate macro table, `identifyMacro` returns `.custom`, and it raises
// `error.ExternalMacroSourceUnavailable` with `reason =
// .dependency_source_unavailable` and `name = "quickcheck"`. Only the recorded
// REASON was wrong.
test "fletcher refuses on the quickcheck macro body, not on a checksum table" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    const out_dir = try crateOutDir(allocator, tmp_root, "fletcher");
    defer allocator.free(out_dir);

    const err = if (refusalFrom(allocator, test_io, "test/crates/fletcher", out_dir)) |_|
        error.ExpectedRefusalButTranslated
    else |refusal|
        refusal;
    try std.testing.expectEqual(error.ExternalMacroSourceUnavailable, err);

    const explanation = pipeline.explainRefusal(err) orelse
        return error.ExternalMacroRefusalUnclassified;
    try std.testing.expectEqual(pipeline.RefusalKind.external_macro_source, explanation.kind);
    // The explanation names a macro BODY, so a reader is told the invocation is
    // known and its definition is what is missing.
    try std.testing.expect(std.mem.indexOf(u8, explanation.missing, "macro_rules!") != null);

    const lib_source = try pipeline.readFileAlloc(
        allocator,
        test_io,
        "test/crates/fletcher/src/lib.rs",
    );
    defer allocator.free(lib_source);

    // The claim that decides the cause: the crate defines no macro at all, so
    // the tables cannot be behind an in-crate expansion either.
    try std.testing.expect(std.mem.indexOf(u8, lib_source, "macro_rules!") == null);
    // ...and the unresolvable name is the quickcheck one.
    try std.testing.expect(std.mem.indexOf(u8, lib_source, "extern crate quickcheck;") != null);
    try std.testing.expect(std.mem.indexOf(u8, lib_source, "quickcheck! {") != null);

    const manifest = try ingest.loadCrateManifest(allocator, test_io, "test/crates/fletcher");
    defer ingest.deinitLoadedManifest(allocator, manifest);
    try std.testing.expectEqual(@as(usize, 0), manifest.dependencies.len);
    try std.testing.expectEqual(@as(usize, 0), manifest.dev_dependencies.len);
}

// ── leb128: a dev-dependency the crate graph never admits ───────────────────

// `tests/quickchecks.rs` opens with `use leb128;` then `use quickcheck;`, and
// `Cargo.toml:26-27` DOES declare `[dev-dependencies.quickcheck] version =
// "0.8.0"`. So the recorded reason — "a re-export of a dev-dependency no mapped
// external declares" — is wrong twice over: nothing re-exports it, and the
// manifest does declare it.
//
// The real cause is that `frontend/pipeline.zig` builds `graph.Crate.deps`
// from `manifestDependencies(manifest.dependencies, …)` — the NORMAL
// dependencies alone. A `[dev-dependencies]` entry never becomes a crate dep,
// so `backend/zig/lower.zig`'s `isDeclaredDependencyRoot` answers false for
// `quickcheck` and `useHasLowerableTarget` falls through to
// `error.UnsupportedExternalUse`.
//
// This is a genuine boundary and not a manifest bug: quickcheck's source is not
// vendored in this tree (`test/crates/quickcheck` does not exist), so admitting
// the root would only move the failure to macro expansion. The correct reason
// names the unadmitted ROOT, which is what the policy does.
test "leb128 refuses on an unadmitted use root, not on a missing manifest entry" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    const out_dir = try crateOutDir(allocator, tmp_root, "leb128");
    defer allocator.free(out_dir);

    const err = if (refusalFrom(allocator, test_io, "test/crates/leb128", out_dir)) |_|
        error.ExpectedRefusalButTranslated
    else |refusal|
        refusal;
    try std.testing.expectEqual(error.UnsupportedExternalUse, err);

    const explanation = pipeline.explainRefusal(err) orelse
        return error.ExternalUseRefusalUnclassified;
    try std.testing.expectEqual(pipeline.RefusalKind.undeclared_crate_root, explanation.kind);
    try std.testing.expect(std.mem.indexOf(u8, explanation.missing, "`use` root") != null);

    // The manifest DOES declare quickcheck — as a dev-dependency. That is the
    // fact the previous reason contradicted, so it is asserted directly.
    const manifest = try ingest.loadCrateManifest(allocator, test_io, "test/crates/leb128");
    defer ingest.deinitLoadedManifest(allocator, manifest);
    try std.testing.expectEqual(@as(usize, 0), manifest.dependencies.len);
    var declared_as_dev = false;
    for (manifest.dev_dependencies) |dependency| {
        if (std.mem.eql(u8, dependency.name, "quickcheck")) declared_as_dev = true;
    }
    try std.testing.expect(declared_as_dev);

    // ...and the source's `use` is the one that reaches the refusal.
    const test_source = try pipeline.readFileAlloc(
        allocator,
        test_io,
        "test/crates/leb128/tests/quickchecks.rs",
    );
    defer allocator.free(test_source);
    try std.testing.expect(std.mem.indexOf(u8, test_source, "use quickcheck;") != null);

    // quickcheck is not vendored here, which is what keeps the boundary real.
    // `openFile`'s success payload is the file, so a missing file cannot
    // yield `false` here; the absence sentinel is `null`.
    const vendored: ?std.Io.File = std.Io.Dir.cwd().openFile(
        test_io,
        "test/crates/quickcheck/Cargo.toml",
        .{},
    ) catch |open_err| switch (open_err) {
        error.FileNotFound => null,
        else => return open_err,
    };
    if (vendored) |file| {
        file.close(test_io);
        return error.QuickcheckIsVendoredSoTheBoundaryWouldBeWrong;
    }
}

// ── syn: a cfg predicate Rust DOES define ───────────────────────────────────

// syn meets `miri`, and `miri` is a predicate rustc defines (it is set when
// running under Miri). So this is a GAP — a predicate Rust defines that the
// translator does not implement — not a source or fixture problem.
//
// The deciding line is `frontend/expand.zig`'s `sourceCfgTargetBuiltin`, which
// lists `miri` and so returns `error.UnsupportedCfgPredicate` from
// `sourceCfgPredicate`. `frontend/cst.zig`'s `cfgBuiltinRequiresTarget` does
// NOT list `miri`, and its own comment says the omission is deliberate: such a
// key "is statically false for a host, non-proc-macro translation target, so
// cfg pruning resolves them as false". The two evaluators therefore disagree
// about the same predicate.
//
// syn carries it at `tests/test_expr.rs:1`, `tests/test_precedence.rs:16`,
// `tests/test_round_trip.rs:2` and `tests/test_unparenthesize.rs:1`, all as
// `#![cfg(not(miri))]` — a crate-level inner attribute, so it is read on the
// include_tests path. `build.zig` records syn as `.unmeasured` with no owner,
// so no node currently pins this error.
test "syn meets miri, a predicate rustc defines and cst prunes but expand refuses" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;

    // The gap is pinned through the policy layer this file owns rather than
    // through `frontend`'s private evaluators, which belong to another slice.
    // What is asserted here is the CLAUSE syn meets and how the driver names it;
    // the evaluators' disagreement is recorded above and is checkable by reading
    // `expand.zig`'s `sourceCfgTargetBuiltin` against `cst.zig`'s
    // `cfgBuiltinRequiresTarget`.
    const test_source = try pipeline.readFileAlloc(
        allocator,
        test_io,
        "test/crates/syn/tests/test_expr.rs",
    );
    defer allocator.free(test_source);
    try std.testing.expect(std.mem.indexOf(u8, test_source, "cfg(not(miri))") != null);

    const explanation = pipeline.explainRefusal(error.UnsupportedCfgPredicate) orelse
        return error.CfgRefusalUnclassified;
    try std.testing.expectEqual(pipeline.RefusalKind.cfg_predicate, explanation.kind);
    // The reason names a PREDICATE and the missing target configuration, which
    // is what tells a reader this is an unanswered question about the target
    // rather than a key the translator has never heard of.
    try std.testing.expect(std.mem.indexOf(u8, explanation.missing, "predicate") != null);
    try std.testing.expect(std.mem.indexOf(u8, explanation.missing, "target") != null);
}

// ── the policy itself ───────────────────────────────────────────────────────

// A lowering refusal is NOT an input-availability boundary. If this ever
// answers non-null for `UnsupportedExpression`, a construct gap has been filed
// as a missing input and the two have become indistinguishable to a reader.
test "a lowering refusal is not an input-availability boundary" {
    try std.testing.expectEqual(
        @as(?pipeline.RefusalExplanation, null),
        pipeline.explainRefusal(error.UnsupportedExpression),
    );
    try std.testing.expectEqual(
        @as(?pipeline.RefusalExplanation, null),
        pipeline.explainRefusal(error.UnsupportedPattern),
    );
    try std.testing.expectEqual(
        @as(?pipeline.RefusalExplanation, null),
        pipeline.explainRefusal(error.UnsupportedWireVersion),
    );
}

// Every row of the table is reachable through `explainRefusal` and names a
// NON-EMPTY class of missing input. A row whose `missing` text were emptied
// would leave the refusal naming nothing, which is the failure this policy
// exists to prevent.
test "every refusal row is reachable and names what it could not obtain" {
    const rows = pipeline.refusalTable();
    try std.testing.expectEqual(@as(usize, 4), rows.len);

    var seen: usize = 0;
    for (rows) |row| {
        const explanation = pipeline.explainRefusal(row.err) orelse
            return error.RefusalRowUnreachable;
        try std.testing.expectEqual(row.kind, explanation.kind);
        try std.testing.expectEqual(row.missing, explanation.missing);
        try std.testing.expect(explanation.missing.len > 0);
        seen += 1;
    }
    try std.testing.expectEqual(rows.len, seen);
}

// The four boundary kinds are DISTINCT. Two rows sharing a kind would make
// `explainRefusal` unable to tell two different missing inputs apart, which is
// the whole reason the kinds exist.
test "each refusal names a distinct boundary kind" {
    const rows = pipeline.refusalTable();
    for (rows, 0..) |row, index| {
        for (rows[index + 1 ..]) |other| {
            try std.testing.expect(row.kind != other.kind);
            try std.testing.expect(row.err != other.err);
        }
    }
}
