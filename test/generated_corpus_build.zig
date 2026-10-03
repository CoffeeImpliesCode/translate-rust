//! The generated-corpus aggregate's `build.zig`.
//!
//! `test/generated_corpus.zig` copies this file verbatim into
//! `<output>/aggregate/build.zig`, beside the `build.zig.zon` dependency table
//! and the `corpus_config.zig` row inventory it generates. Everything it needs
//! to compile is data: this file never names a corpus row.
//!
//! Four properties the matrix depends on, each one checked at configure time
//! and each naming what broke it, because a matrix that quietly measures half
//! of what it claims is worse than one that refuses to configure:
//!
//! 1. Every staged package is reached through the generated-package contract in
//!    `README.md`: `b.dependency(<key>, .{ .target, .optimize }).module(<name>)`
//!    with the module name that package registered for itself. No row is
//!    compiled from a source path, so nothing here depends on the translator's
//!    checkout.
//! 2. The target and the optimize mode come from this build and are forwarded
//!    to every dependency; every module the graph reaches is read back and
//!    refused unless it carries them. A module reached without them keeps a
//!    null field and the compiler re-derives one from `b.release_mode`, so a
//!    ReleaseSafe row would be measured in a Debug build and a cross row would
//!    be compiled for the host. Each staged package forwards them again to the
//!    `r2z-core` runtime it vendors, which this file also reads back.
//! 3. A row is compiled only for the pointer widths it was generated for, and a
//!    consumer only where at least one of its bindings applies. A 32-bit target
//!    never compiles a package generated for 64-bit Rust `cfg`, and a consumer
//!    whose bindings are all gated away on this width is skipped whole rather
//!    than left with a half-bound import table.
//! 4. Coverage is `executed` or `compile_only`, never "it compiled". A row that
//!    publishes an API, carries no translated test and is bound by no consumer
//!    is build-only coverage, and this script refuses to configure over one.
//!
//! The graph is pure. It compiles test artifacts and runs them; it never
//! spawns a compiler, a shell, or the producer, so a foreign target row can
//! never execute the host toolchain. The one thing it does read is the
//! environment cross-test exports into every build it starts, which is what
//! says whether a row may execute at all — see `RunnerPolicy`.
//!
//! Linkage follows the repository's single cross-target policy: a foreign
//! Linux test binary is linked static, because a QEMU user-mode guest has no
//! loader and no libc to find; native and every other foreign target keep
//! Zig's default linkage, because the supplied BSD and Apple libc requires
//! dynamic linking.
//!
//! Optimize modes are pinned by `corpus_config.zig` and built as separate
//! artifacts in one graph rather than selected by a command-line option: a
//! `-Doptimize` flag would let a run silently drop one of the required
//! coverage modes. Artifact names carry the mode, so the Debug and ReleaseSafe
//! copies of one row are two artifacts in one graph rather than one artifact
//! with two callers.
//!
//! What a row may claim is decided by the runner, not by this file. cross-test
//! exports three variables into every build it starts:
//!
//!   CROSS_TEST_TARGET       the target triple this build was started for
//!   CROSS_TEST_RUNNER_KIND  `native`, `exec`, or `unavailable`
//!   CROSS_TEST_RUNNER_REASON  why the kind is what it is
//!
//! They are the only channel through which the graph learns what the host can
//! execute, and they are the authority: a row is measured only when the host
//! that starts it said a runner exists for it. Without them — a developer
//! running `zig build test -Dtarget=…` by hand — the row is compile-only, which
//! is the safe direction, because the alternative would be executing a foreign
//! binary on the assumption that something can run it.

const std = @import("std");
const config = @import("corpus_config.zig");

pub fn build(b: *std.Build) void {
    // One target and one optimize mode per iteration, both resolved here and
    // threaded through every call below. Nothing re-derives either: a helper
    // that built its own `std.Target`, or an artifact left to the compiler's
    // `release_mode` fallback, would compile a consumer for one setting and run
    // it for another.
    const target = b.standardTargetOptions(.{});
    const bits = target.result.ptrBitWidth();
    // One policy, computed once, for every artifact the matrix can execute.
    const cross_linkage = matrixLinkage(b.graph.host.result, target.result);
    // The other one: what this host may run for the target cross-test started
    // this build for. Resolved once, before any artifact exists, so every run
    // step below is attached the same way.
    const runners = resolveRunners(b);
    const test_step = b.step("test", stepDescription(runners));

    requireMeasuredCoverage();
    var claimed: std.ArrayListUnmanaged([]const u8) = .empty;

    for (config.optimize_modes) |optimize| {
        // The translated `#[cfg(test)]` module each package carried in its own
        // sources. This is the package's original assertions, run from the
        // package's own registered module rather than from a copy of it.
        for (config.rows) |row| {
            if (!appliesTo(row.pointer_widths, bits)) continue;
            const tests = b.addTest(.{
                .name = claimArtifactName(b, &claimed, row.dependency, optimize),
                .root_module = packageModule(b, row, target, optimize),
            });
            tests.linkage = cross_linkage;
            measure(b, test_step, tests);
        }

        // The vendored runtime's own tests, once per mode from a single copy.
        // Every package that vendors r2z-core carries the same bytes, so testing
        // each vendored copy again would repeat one suite N times.
        const runtime_tests = b.addTest(.{
            .name = claimArtifactName(b, &claimed, config.runtime_test_id, optimize),
            .root_module = inherited(
                config.runtime_test_id,
                b.createModule(.{
                    .root_source_file = b.path(config.runtime_source_path),
                    .target = target,
                    .optimize = optimize,
                }),
                target,
                optimize,
            ),
        });
        runtime_tests.linkage = cross_linkage;
        measure(b, test_step, runtime_tests);

        // Consumers. Each one is its own root module compiled from a verbatim
        // copy of the repository file, so an upstream consumer is preserved
        // exactly as written instead of being merged into a single combined
        // source or weakened to fit this matrix.
        for (config.consumers) |consumer| {
            if (!appliesTo(consumer.pointer_widths, bits)) continue;
            requireABindingApplies(consumer, bits);
            const root = inherited(
                consumer.id,
                b.createModule(.{
                    .root_source_file = b.path(consumer.file),
                    .target = target,
                    .optimize = optimize,
                }),
                target,
                optimize,
            );
            for (consumer.bindings) |binding| {
                if (!appliesTo(binding.pointer_widths, bits)) continue;
                const row = config.rowById(binding.row) orelse {
                    std.log.err(
                        "generated corpus: consumer '{s}' binds '{s}' to unknown row '{s}'",
                        .{ consumer.id, binding.name, binding.row },
                    );
                    @panic("generated corpus: consumer binding names no corpus row");
                };
                root.addImport(binding.name, switch (binding.kind) {
                    .package => packageModule(b, row, target, optimize),
                    .runtime => runtimeModule(b, row, target, optimize),
                });
            }
            const tests = b.addTest(.{
                .name = claimArtifactName(b, &claimed, consumer.id, optimize),
                .root_module = root,
            });
            tests.linkage = cross_linkage;
            measure(b, test_step, tests);
        }
    }
}

// ---------------------------------------------------------------------------
// What a row may claim
// ---------------------------------------------------------------------------

/// What this build is permitted to execute, and therefore what each row of the
/// matrix is allowed to claim.
const ExternalRunner = enum {
    /// The host executes this target's binaries itself.
    none,
    /// A foreign interpreter is available: qemu user-mode, Wine, or wasmtime.
    interpreter,
    /// No runner exists. Every artifact compiles; no artifact is executed.
    compile_only,
};

/// The runners this build is permitted to use, resolved from the environment
/// cross-test exports and from nothing else.
///
/// The build system already knows how to find and launch a foreign interpreter
/// — it maps each target architecture to an interpreter name and resolves that
/// name on `PATH` — but it refuses to reach for one unless it is told the host
/// actually has it. `enable_qemu`, `enable_wasmtime` and `enable_wine` are that
/// permission, and they are set from the census rather than switched on
/// wholesale, so a target the census could not give a runner is compiled and
/// skipped even where an interpreter for some other target happens to sit on
/// `PATH`.
///
/// The arch mapping is wider than any single runner: Zig 0.16 will drive
/// aarch64, arm, thumb, riscv32/64, s390x, x86, hexagon, loongarch64, mips,
/// mipsel, mips64, mips64el, powerpc64, powerpc64le and the big-endian
/// variants under qemu user-mode, so permitting the family is not a narrower
/// claim than the census makes. Where the two disagree the row fails with the
/// build system's own "consider using -fqemu" diagnostic rather than being
/// reported as executed, which is the direction a matrix must err in.
fn resolveRunners(b: *std.Build) ExternalRunner {
    const kind = b.graph.environ_map.get("CROSS_TEST_RUNNER_KIND") orelse {
        // Nobody declared a runner for this build. A row that executes anyway
        // would be claiming coverage nobody offered, so nothing executes.
        return .compile_only;
    };
    if (std.mem.eql(u8, kind, "native")) return .none;
    if (!std.mem.eql(u8, kind, "exec")) return .compile_only;
    // A declared foreign runner. Permitting the families leaves the choice of
    // interpreter to the build system, which resolves it for this target.
    b.enable_qemu = true;
    b.enable_wasmtime = true;
    b.enable_wine = true;
    return .interpreter;
}

/// Name the coverage this build can produce, so the reason a graph reports no
/// assertions is in the step's own description rather than only in the run log.
fn stepDescription(runners: ExternalRunner) []const u8 {
    return switch (runners) {
        .none => "Run every generated package test and consumer natively",
        .interpreter => "Run every generated package test and consumer under a foreign runner",
        .compile_only => "Compile every generated package test and consumer; no runner is available for this target",
    };
}

/// Attach one test artifact to the matrix, and say what it may claim.
///
/// The artifact is always compiled. Whether it is executed depends on the host,
/// and the two outcomes have to be distinguishable in the build summary rather
/// than inferred afterwards: cross-test reads `run test … skipped` as
/// compile-only coverage and anything else as an execution, so a skipped run is
/// a compile-only row, never a passing one.
///
/// `skip_foreign_checks` is what produces that distinction. Without it the
/// build system fails a run whose binary it cannot launch, which would turn
/// every target without a runner into a build failure and report no coverage at
/// all; with it, the same situation compiles the artifact and skips the run. The
/// sibling flag `failing_to_execute_foreign_is_an_error` stays at its default:
/// once an interpreter has been permitted and chosen, failing to launch it is
/// an error, so a broken runner is reported as a broken runner instead of being
/// quietly downgraded to a compile.
fn measure(b: *std.Build, test_step: *std.Build.Step, tests: *std.Build.Step.Compile) void {
    const run = b.addRunArtifact(tests);
    run.skip_foreign_checks = true;
    test_step.dependOn(&run.step);
}

/// The module a staged package registered for itself, reached the way a
/// consumer is documented to reach it.
fn packageModule(
    b: *std.Build,
    row: config.Row,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return inherited(
        row.dependency,
        b.dependency(row.dependency, .{
            .target = target,
            .optimize = optimize,
        }).module(row.module),
        target,
        optimize,
    );
}

/// The runtime copy inside one staged package. A consumer that writes
/// `@import("r2z")` gets the runtime its own `translated` package vendors, not
/// an unrelated one from another row.
fn runtimeModule(
    b: *std.Build,
    row: config.Row,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    if (!row.vendored_runtime) {
        std.log.err(
            "generated corpus: package '{s}' does not vendor the runtime a consumer imports",
            .{row.dependency},
        );
        @panic("generated corpus: consumer imports a runtime the package does not ship");
    }
    const primary = packageModule(b, row, target, optimize);
    return inherited(
        row.dependency,
        primary.import_table.get("r2z") orelse {
            std.log.err(
                "generated corpus: registered package '{s}' has no r2z import",
                .{row.dependency},
            );
            @panic("generated corpus: primary module does not import its runtime");
        },
        target,
        optimize,
    );
}

/// Refuse a module that is not carrying the target and mode this build resolved.
///
/// `b.dependency(name, .{ .target, .optimize })` forwards both into the
/// package's own `build.zig` as `-Dtarget` and `-Doptimize`, and that is the
/// only channel through which a staged package can inherit them:
/// `Module.init` stores the forwarded values verbatim, so a module reached
/// without them keeps a null field and the compiler falls back to the build's
/// own `release_mode`. Reading the fields back is what turns "forwarded" from a
/// comment into a check — a package that stopped forwarding, or a runtime that
/// stopped inheriting, is named here instead of being measured in a mode nobody
/// asked for.
fn inherited(
    owner: []const u8,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const inherited_target = module.resolved_target orelse {
        std.log.err(
            "generated corpus: '{s}' reached a module that inherited no target, so the compiler would re-derive one",
            .{owner},
        );
        @panic("generated corpus: module inherited no target");
    };
    const inherited_optimize = module.optimize orelse {
        std.log.err(
            "generated corpus: '{s}' reached a module that inherited no optimize mode, so the compiler would re-derive one",
            .{owner},
        );
        @panic("generated corpus: module inherited no optimize mode");
    };
    if (inherited_optimize != optimize or !sameTarget(inherited_target.result, target.result)) {
        std.log.err(
            "generated corpus: '{s}' reached a module built for {s}-{s} {s}, not the {s}-{s} {s} this graph resolved",
            .{
                owner,
                @tagName(inherited_target.result.cpu.arch),
                @tagName(inherited_target.result.os.tag),
                @tagName(inherited_optimize),
                @tagName(target.result.cpu.arch),
                @tagName(target.result.os.tag),
                @tagName(optimize),
            },
        );
        @panic("generated corpus: a module's settings were re-derived instead of inherited");
    }
    return module;
}

/// Two targets are the same measurement when the architecture, the OS and the
/// ABI agree. The pointer width is a consequence of the architecture, so it is
/// not compared again; the query behind them is not compared at all, because
/// `-Dcpu` features do not change what a translated package observes.
fn sameTarget(a: std.Target, b: std.Target) bool {
    return a.cpu.arch == b.cpu.arch and a.os.tag == b.os.tag and a.abi == b.abi;
}

/// The rule that separates a compile-only row from an executed one.
///
/// `executed` means the row's evidence is an assertion somebody ran: the
/// package's own translated `#[cfg(test)]` module, counted into
/// `original_tests`, or a consumer that binds the row and calls into it.
/// `compile_only` is legal for exactly one kind of row — one whose
/// configuration publishes no API at all, so there is no value to call and the
/// artifact proves the configuration compiles. `not_staged` cannot appear in a
/// written aggregate, because the producer writes one only when every row
/// reached a promoted package.
///
/// So two shapes are refused by name: a row that claims `executed` while
/// nothing in this graph runs a value in it, and an API-bearing row marked
/// `compile_only`. Both are coverage that is only a compile. The producer
/// refuses to emit either; this refuses to build one, so a stale or hand-edited
/// inventory cannot reintroduce them.
fn requireMeasuredCoverage() void {
    for (config.rows) |row| {
        switch (row.coverage) {
            .not_staged => {
                std.log.err(
                    "generated corpus: row '{s}' is inventoried as not staged, and this aggregate is written only when every row staged",
                    .{row.dependency},
                );
                @panic("generated corpus: a row that never staged cannot be measured");
            },
            .compile_only => {
                if (!row.has_api) continue;
                std.log.err(
                    "generated corpus: row '{s}' publishes an API but is compile-only ({s}); its only evidence is that it compiled",
                    .{ row.dependency, row.coverage_reason },
                );
                @panic("generated corpus: an API-bearing row may not be covered by a build only");
            },
            .executed => {
                if (row.original_tests != 0 or consumerBinds(row.dependency)) continue;
                std.log.err(
                    "generated corpus: row '{s}' claims executed coverage ({s}) but it carries no translated test and no consumer binds it",
                    .{ row.dependency, row.coverage_reason },
                );
                @panic("generated corpus: executed coverage with nothing in the graph that runs a value");
            },
        }
    }
}

/// Whether any consumer in this graph binds `id`.
///
/// Widths are deliberately not consulted. The producer records a binding with
/// the widths of the row it names, so a row a consumer binds is bound on every
/// width the row was generated for, and asking about one target here would
/// report a 64-bit row as unmeasured on a 32-bit build.
fn consumerBinds(id: []const u8) bool {
    for (config.consumers) |consumer| {
        for (consumer.bindings) |binding| {
            if (std.mem.eql(u8, binding.row, id)) return true;
        }
    }
    return false;
}

/// A consumer is built only where one of its bindings applies.
///
/// `consumer.pointer_widths` is the union of its bindings' widths, so the loop
/// above already skips a consumer nothing binds on this width. Asserting it
/// here turns that arithmetic into a named failure rather than an `@import`
/// with no module behind it, which is how a half-bound import table otherwise
/// reaches the compiler.
fn requireABindingApplies(consumer: config.Consumer, bits: u16) void {
    for (consumer.bindings) |binding| {
        if (appliesTo(binding.pointer_widths, bits)) return;
    }
    std.log.err(
        "generated corpus: consumer '{s}' is inventoried for {d}-bit targets but binds nothing that applies there",
        .{ consumer.id, bits },
    );
    @panic("generated corpus: a consumer was selected with no applicable binding");
}

/// A row or consumer exists for exactly the pointer widths it was generated
/// for. A 32-bit target must never compile a package generated for 64-bit Rust
/// `cfg`, and a 64-bit target must never compile the 32-bit one.
fn appliesTo(widths: []const u16, bits: u16) bool {
    for (widths) |width| {
        if (width == bits) return true;
    }
    return false;
}

/// Claim one artifact name inside this graph, refusing a second claim.
///
/// `zig build` identifies a compile step by its name within the graph, so two
/// artifacts that share one name are one artifact with two callers: the second
/// `addTest` never becomes a step of its own and a row silently stops being
/// measured. The mode suffix is part of the name rather than a separate
/// directory, which is what keeps the Debug and ReleaseSafe copies of one row
/// apart.
fn claimArtifactName(
    b: *std.Build,
    claimed: *std.ArrayListUnmanaged([]const u8),
    id: []const u8,
    optimize: std.builtin.OptimizeMode,
) []const u8 {
    const name = artifactName(b, id, optimize);
    for (claimed.items) |taken| {
        if (!std.mem.eql(u8, taken, name)) continue;
        std.log.err(
            "generated corpus: artifact '{s}' would be created twice; a row id and a consumer id must differ",
            .{name},
        );
        @panic("generated corpus: duplicate artifact name");
    }
    claimed.append(b.allocator, name) catch @panic("OOM");
    return name;
}

/// Artifact names are unique inside one graph, and a mode suffix keeps the
/// Debug and ReleaseSafe copies of the same row apart.
fn artifactName(b: *std.Build, id: []const u8, optimize: std.builtin.OptimizeMode) []const u8 {
    return b.fmt("corpus-{s}-{s}", .{ id, @tagName(optimize) });
}

// ---------------------------------------------------------------------------
// Cross-target linkage policy
// ---------------------------------------------------------------------------

/// Match the host architecture, OS and ABI.
fn isHostTarget(host: std.Target, target: std.Target) bool {
    return target.cpu.arch == host.cpu.arch and
        target.os.tag == host.os.tag and
        target.abi == host.abi;
}

/// Use static linkage for foreign Linux so QEMU needs no guest libc.
/// Other targets keep Zig's default linkage. Its supplied BSD and Apple
/// libc requires dynamic linking. Runner availability determines which
/// rows are compile-only; native linkage stays unchanged.
fn matrixLinkage(host: std.Target, target: std.Target) ?std.builtin.LinkMode {
    if (isHostTarget(host, target)) return null;
    if (target.os.tag == .linux) return .static;
    return null;
}
