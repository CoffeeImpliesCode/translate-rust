const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Two of this graph's steps drive the HOST toolchain: the CLI contract
    // runs the shipped executable through `sh`, and the e2e program spawns
    // `zig test` / `zig build` on generated packages. Neither can drive a
    // foreign binary, so their execution belongs to the host build while both
    // artifacts keep compiling for every target.
    const host = b.graph.host.result;
    const native_target = isHostTarget(host, target.result);
    // One policy, computed once, for every artifact the matrix can execute.
    const cross_linkage = matrixLinkage(host, target.result);

    // Every named step this graph publishes, collected as it is registered.
    var steps: PublishedSteps = .{};

    // Every Zig child this build spawns resolves to the compiler running the
    // build. A PATH lookup for `zig` can land on the anyzig shim, which has no
    // version to resolve outside this checkout and then fails silently.
    const toolchain_options = b.addOptions();
    toolchain_options.addOption([:0]const u8, "zig_executable", b.allocator.dupeSentinel(u8, b.graph.zig_exe, 0) catch @panic("OOM"));
    const toolchain = toolchain_options.createModule();

    // Forward compiler cache roots to child builds. Atomic cache writes
    // require a local filesystem; NFSv3 does not provide the needed rename.
    const e2e_host_options = b.addOptions();
    const local_cache = b.graph.path(.local_cache, "");
    const global_cache = b.graph.path(.global_cache, "");
    e2e_host_options.addOptionPathUntracked("local_cache_dir", local_cache);
    e2e_host_options.addOptionPathUntracked("global_cache_dir", global_cache);
    const e2e_host = e2e_host_options.createModule();

    // ── tree-sitter C runtime + private pointer-only aggregate boundary ────
    const tree_sitter = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
        .amalgamated = true,
        .@"build-shared" = false,
        .@"enable-wasm" = false,
    });
    const ts_mod = b.createModule(.{
        .root_source_file = b.path("src/tree_sitter.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ts_mod.addIncludePath(tree_sitter.path("lib/include"));
    ts_mod.addCSourceFile(.{ .file = b.path("src/tree_sitter.c"), .flags = &.{"-std=c11"} });
    ts_mod.linkLibrary(tree_sitter.artifact("tree-sitter"));
    const serde = b.dependency("serde", .{
        .target = target,
        .optimize = optimize,
    });
    const serde_mod = serde.module("serde");

    // ── translate_rust.rust — the Rust grammar (vendored C), syntax-only ────
    // Vendored from tree-sitter/tree-sitter-rust @ 77a3747 (v0.24.2), MIT:
    //   vendor/tree-sitter-rust/parser.c, scanner.c, tree_sitter/{alloc,array,parser}.h
    const rust = b.addModule("translate_rust.rust", .{
        .root_source_file = b.path("src/rust.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tree_sitter", .module = ts_mod },
        },
    });
    rust.addCSourceFile(.{ .file = b.path("vendor/tree-sitter-rust/parser.c"), .flags = &.{} });
    rust.addCSourceFile(.{ .file = b.path("vendor/tree-sitter-rust/scanner.c"), .flags = &.{} });
    rust.addIncludePath(b.path("vendor/tree-sitter-rust"));
    rust.link_libc = true;

    // ── translate_rust.model — the lossless semantic IR (P1) ─────────────
    // The model and frontend share the private tree-sitter boundary. That
    // module links the C runtime; `rust` supplies the vendored Rust grammar.
    const model = b.addModule("translate_rust.model", .{
        .root_source_file = b.path("src/model/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tree_sitter", .module = ts_mod },
            .{ .name = "rust", .module = rust },
        },
    });
    // ── translate_rust.ir — pure semantic IR and serialization ───────────
    const ir = b.addModule("translate_rust.ir", .{
        .root_source_file = b.path("src/ir/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── translate_rust.frontend — pure Rust understanding pipeline ───────
    const frontend = b.addModule("translate_rust.frontend", .{
        .root_source_file = b.path("src/frontend/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tree_sitter", .module = ts_mod },
            .{ .name = "rust", .module = rust },
            .{ .name = "translate_rust.ir", .module = ir },
            .{ .name = "serde", .module = serde_mod },
        },
    });

    // ── r2z-core runtime assets ────────────────────────────────────────
    // A generated package vendors this runtime under `r2z-core/`, so its
    // bytes have to travel inside the translator executable: an installed
    // `translate-rust` has no source checkout to resolve a path against.
    // The module is private — it is translator implementation, not a name
    // this package publishes to its own consumers.
    const runtime_options = b.addOptions();
    runtime_options.addOption(?[]const u8, "r2z_core_license", runtimeLicense(b));
    const r2z_core_assets = b.createModule(.{
        .root_source_file = b.path("r2z-core/package_assets.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = runtime_options.createModule() },
        },
    });

    // ── translate_rust.backend — target representations & lowering ───────
    const backend = b.addModule("translate_rust.backend", .{
        .root_source_file = b.path("src/backend/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "translate_rust.ir", .module = ir },
            // The package writer is the only file that names the runtime
            // assets, and it lives in this module, so one entry here reaches
            // every artifact that compiles the backend: the executable, the
            // library tests, the backend and driver tests, the golden
            // generators, and the e2e test.
            .{ .name = "r2z_core_assets", .module = r2z_core_assets },
            // Package promotion builds and tests a generated package with a
            // Zig compiler, reached from this module's writer.
            .{ .name = "toolchain", .module = toolchain },
        },
    });

    // ── translate_rust.driver — end-to-end translation pipeline ─────────
    const driver = b.addModule("translate_rust.driver", .{
        .root_source_file = b.path("src/driver/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "translate_rust.ir", .module = ir },
            .{ .name = "translate_rust.frontend", .module = frontend },
            .{ .name = "translate_rust.backend", .module = backend },
            // The fingerprint probe builds the staged package.
            .{ .name = "toolchain", .module = toolchain },
        },
    });

    // ── translate_rust — library root ─────────────────────────
    const translate_rust = b.addModule("translate_rust", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "translate_rust.rust", .module = rust },
            .{ .name = "translate_rust.model", .module = model },
            .{ .name = "translate_rust.ir", .module = ir },
            .{ .name = "translate_rust.frontend", .module = frontend },
            .{ .name = "translate_rust.backend", .module = backend },
            .{ .name = "translate_rust.driver", .module = driver },
        },
    });
    // ── translate-rust executable ─────────────────────────
    const exe = b.addExecutable(.{
        .name = "translate-rust",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "translate_rust", .module = translate_rust },
            },
        }),
    });
    b.installArtifact(exe);
    if (cross_linkage) |mode| exe.linkage = mode;

    const run_step = steps.add(b, "run", "Run translate-rust");
    const run_cmd = declinedRunArtifact(b, exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    // `zig build generate-mini-wire` runs the trusted source → validation →
    // canonical encoder path and atomically refreshes test/mini.json.
    const mini_wire_generator = b.addExecutable(.{
        .name = "generate-mini-wire",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/generate_mini_wire.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "translate_rust", .module = translate_rust },
            },
        }),
    });
    const generate_mini_wire_step = steps.add(
        b,
        "generate-mini-wire",
        "Regenerate test/mini.json from validated canonical IR",
    );
    const generate_mini_wire_cmd = declinedRunArtifact(b, mini_wire_generator);
    generate_mini_wire_step.dependOn(&generate_mini_wire_cmd.step);

    const fnv_golden_generator = b.addExecutable(.{
        .name = "generate-fnv-golden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/generate_fnv_golden.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "translate_rust", .module = translate_rust },
            },
        }),
    });
    const generate_fnv_golden_step = steps.add(
        b,
        "generate-fnv-golden",
        "Regenerate FNV source goldens from validated canonical IR",
    );
    const generate_fnv_golden_cmd = declinedRunArtifact(b, fnv_golden_generator);
    generate_fnv_golden_step.dependOn(&generate_fnv_golden_cmd.step);

    const hex_golden_generator = b.addExecutable(.{
        .name = "generate-hex-golden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/generate_hex_golden.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "translate_rust", .module = translate_rust },
            },
        }),
    });
    const generate_hex_golden_step = steps.add(
        b,
        "generate-hex-golden",
        "Regenerate hex source goldens from validated canonical IR",
    );
    const generate_hex_golden_cmd = declinedRunArtifact(b, hex_golden_generator);
    generate_hex_golden_step.dependOn(&generate_hex_golden_cmd.step);

    const mini_golden_generator = b.addExecutable(.{
        .name = "generate-mini-golden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/generate_mini_golden.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "translate_rust", .module = translate_rust },
            },
        }),
    });
    const generate_mini_golden_step = steps.add(
        b,
        "generate-mini-golden",
        "Regenerate mini source goldens from validated canonical IR",
    );
    const generate_mini_golden_cmd = declinedRunArtifact(b, mini_golden_generator);
    generate_mini_golden_step.dependOn(&generate_mini_golden_cmd.step);

    const compat_golden_generator = b.addExecutable(.{
        .name = "generate-compat-golden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/generate_compat_golden.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "translate_rust", .module = translate_rust },
            },
        }),
    });
    const generate_compat_golden_step = steps.add(
        b,
        "generate-compat-golden",
        "Regenerate compat source goldens from validated canonical IR",
    );
    const generate_compat_golden_cmd = declinedRunArtifact(b, compat_golden_generator);
    generate_compat_golden_step.dependOn(&generate_compat_golden_cmd.step);

    const wyhash_golden_generator = b.addExecutable(.{
        .name = "generate-wyhash-golden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/generate_wyhash_golden.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "translate_rust", .module = translate_rust },
            },
        }),
    });
    const generate_wyhash_golden_step = steps.add(
        b,
        "generate-wyhash-golden",
        "Regenerate wyhash source goldens from validated canonical IR",
    );
    const generate_wyhash_golden_cmd = declinedRunArtifact(b, wyhash_golden_generator);
    generate_wyhash_golden_step.dependOn(&generate_wyhash_golden_cmd.step);

    const adler_golden_generator = b.addExecutable(.{
        .name = "generate-adler-golden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/generate_adler_golden.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "translate_rust", .module = translate_rust },
            },
        }),
    });
    const generate_adler_golden_step = steps.add(
        b,
        "generate-adler-golden",
        "Regenerate adler source goldens from validated canonical IR",
    );
    const generate_adler_golden_cmd = declinedRunArtifact(b, adler_golden_generator);
    generate_adler_golden_step.dependOn(&generate_adler_golden_cmd.step);

    const multimod_golden_generator = b.addExecutable(.{
        .name = "generate-multimod-golden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/generate_multimod_golden.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "translate_rust", .module = translate_rust },
            },
        }),
    });
    const generate_multimod_golden_step = steps.add(
        b,
        "generate-multimod-golden",
        "Regenerate multimod source goldens from validated canonical IR",
    );
    const generate_multimod_golden_cmd = declinedRunArtifact(b, multimod_golden_generator);
    generate_multimod_golden_step.dependOn(&generate_multimod_golden_cmd.step);

    // `zig build source` translates the complete mini source fixture and
    // checks that staged promotion publishes the generated package.
    const source_step = steps.add(b, "source", "Translate the complete mini source fixture");
    const corpus_dir = local_cache.path(b, "r2z-check");
    const source_cmd = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\set -eu
        \\out=$2
        \\test ! -e "$out"
        \\trap 'rm -rf "$out"' EXIT
        \\"$1" "$3" -o "$out"
        \\test -f "$out/build.zig"
        \\test -f "$out/build.zig.zon"
        \\test -f "$out/src/root.zig"
        \\test -f "$out/src/util.zig"
        ,
        "verify-mini-source",
    });
    source_cmd.addArtifactArg(exe);
    source_cmd.addDirectoryArg(corpus_dir.path(b, "source-mini"));
    source_cmd.addDirectoryArg(b.path("test/crates/mini"));
    source_step.dependOn(&source_cmd.step);

    // ── e2e: fail-loud source and wire translation boundaries ───────────
    // `--listen` test-runner protocol cannot spawn grandchildren; the
    // executable translates the complete source fixtures positively, runs
    // their consumers, and rejects incomplete wire fixtures before a package
    // is written.
    const e2e_mod = b.addModule("e2e_test", .{
        .root_source_file = b.path("test/e2e_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "translate_rust", .module = translate_rust },
            .{ .name = "toolchain", .module = toolchain },
            .{ .name = "e2e_host", .module = e2e_host },
        },
    });
    const e2e_exe = b.addExecutable(.{
        .name = "e2e-test",
        .root_module = e2e_mod,
    });
    if (cross_linkage) |mode| e2e_exe.linkage = mode;
    const run_e2e = declinedRunArtifact(b, e2e_exe);
    const e2e_step = steps.add(
        b,
        "test-e2e",
        "Translate every complete source fixture, run its consumer, and reject the incomplete wire fixtures",
    );
    e2e_step.dependOn(&run_e2e.step);

    // ── generated corpus: stage fresh packages, then cross-run them ─────
    // The producer owns exactly the directory named by `--output`: it creates
    // it, refuses to write into /tmp, /var/tmp or any non-local filesystem,
    // and never erases a path that already exists. This step therefore
    // forwards the run arguments and supplies no default, so the required
    // invocation is
    //     zig build generated-corpus -- --output <abs-local-dir>
    // which is exactly what `tools/test-generated-corpus.sh` runs.
    const generated_corpus_exe = b.addExecutable(.{
        .name = "generated-corpus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/generated_corpus.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "translate_rust", .module = translate_rust },
                .{ .name = "toolchain", .module = toolchain },
            },
        }),
    });
    if (cross_linkage) |mode| generated_corpus_exe.linkage = mode;
    const generated_corpus_step = steps.add(
        b,
        "generated-corpus",
        "Stage fresh generated packages and the cross-matrix aggregate (`-- --output <abs-local-dir>`)",
    );
    const run_generated_corpus = declinedRunArtifact(b, generated_corpus_exe);
    run_generated_corpus.addPassthruArgs();
    if (native_target) {
        generated_corpus_step.dependOn(&run_generated_corpus.step);
    } else {
        // A foreign target publishes nothing here: the producer drives the host
        // toolchain to build and promote every package it writes. Compiling it
        // and reporting success would be a step that ran nothing, so the row
        // says so instead, the same way `test-differential` reports a foreign
        // target.
        generated_corpus_step.dependOn(&b.addSystemCommand(&.{ "printf", "%s\\n", "generated-corpus: the producer publishes packages with the host toolchain; this target stages nothing" }).step);
    }

    // ── translate: emit source from a wire-format JSON ──────────────────
    // `zig build translate -- test/mini.json` → parses + emits to stdout.
    const translate_step = steps.add(b, "translate", "Emit Zig source from a JSON dump");
    const translate_cmd = declinedRunArtifact(b, exe);
    translate_cmd.addPassthruArgs();
    translate_step.dependOn(&translate_cmd.step);

    // Mini is the one complete positive wire fixture. The other wire fixtures
    // stay rejection-only under the strict IR contract, and the source crates
    // below are split the same honest way: each crate either translates and is
    // compiled by a consumer, or it is refused with a named typed error.
    const test_crates_step = steps.add(
        b,
        "test-crates",
        "Translate mini, compile every promoted source fixture, reject the legacy wire and unsupported source fixtures",
    );
    {
        // r2z-core runtime library (standalone package, part of the pipeline).
        const tc = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "--build-file" });
        tc.addFileArg(b.path("r2z-core/build.zig"));
        tc.addArg("--cache-dir");
        tc.addDirectoryArg(local_cache.path(b, "r2z-core-tests"));
        tc.addArgs(&.{ "test", "--summary", "all" });
        test_crates_step.dependOn(&tc.step);
    }
    const mini_wire_cmd = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\set -eu
        \\out=$2
        \\test ! -e "$out"
        \\trap 'rm -rf "$out"' EXIT
        \\"$1" "$3" -o "$out"
        \\test -f "$out/build.zig"
        \\test -f "$out/build.zig.zon"
        \\test -f "$out/src/root.zig"
        \\test -f "$out/src/util.zig"
        ,
        "verify-mini-wire",
    });
    mini_wire_cmd.addArtifactArg(exe);
    mini_wire_cmd.addDirectoryArg(corpus_dir.path(b, "mini"));
    mini_wire_cmd.addFileArg(b.path("test/mini.json"));
    test_crates_step.dependOn(&mini_wire_cmd.step);
    const rejected_specs = [_][2][]const u8{
        .{ "test/fnv.json", "fnv" },
        .{ "test/fletcher.json", "fletcher" },
        .{ "test/hex.json", "hex" },
        .{ "test/wyhash.json", "wyhash" },
        .{ "test/adler.json", "adler" },
        .{ "test/xxhash-rust.json", "xxhash-rust" },
        .{ "test/seahash.json", "seahash" },
        .{ "test/crc16.json", "crc16" },
        .{ "test/atoi.json", "atoi" },
        .{ "test/leb128.json", "leb128" },
        .{ "test/itoa.json", "itoa" },
        .{ "test/siphasher.json", "siphasher" },
        .{ "test/percent-encoding.json", "percent-encoding" },
        .{ "test/syn.json", "syn" },
    };
    for (rejected_specs) |spec| {
        const reject = b.addSystemCommand(&.{
            "sh",
            "-c",
            \\set -eu
            \\out=$2
            \\test ! -e "$out"
            \\trap 'rm -rf "$out"' EXIT
            \\if "$1" "$3" -o "$out"; then
            \\  echo "expected incomplete fixture $3 to be rejected" >&2
            \\  exit 1
            \\fi
            \\test ! -e "$out"
            ,
            "verify-wire-refusal",
        });
        reject.addArtifactArg(exe);
        reject.addDirectoryArg(corpus_dir.path(b, spec[1]));
        reject.addFileArg(b.path(spec[0]));
        test_crates_step.dependOn(&reject.step);
    }
    // Source crates the translator must still refuse. The wire loop above only
    // proves "exits non-zero", which stays green when a fixture starts failing
    // with a *different* error, so each entry asserts the typed error by name:
    // the CLI reports it as `translate-rust failed: <Error>`. It records where
    // coverage stops; it does not excuse wrong output for valid Rust. Pinning
    // the error makes the boundary explicit and turns an accidental change in
    // which error a crate fails with into a build failure.
    //
    // Where the other refusals are pinned: `test/e2e_test.zig` holds one
    // expectation per crate, each bound to its exact typed error, and
    // `test-crates` runs that program, so every refusal it names is already
    // asserted by this step. This table is the second pin for the crates it
    // names, driven through the shipped CLI rather than the in-process driver,
    // and it is deliberately not a copy of e2e's table: two tables of the same
    // rows are two things to keep in step by hand. What must never drift is a
    // crate called positive in one file and refused in the other, and
    // `check-corpus` fails on exactly that disagreement rather than leaving it
    // to a reader. A crate leaves this table only by actually working, never
    // by being deleted from it.
    for (rejected_source_specs) |spec| {
        const reject = b.addSystemCommand(&.{
            "sh",
            "-c",
            b.fmt(
                \\set -eu
                \\out=$2
                \\test ! -e "$out"
                \\trap 'rm -rf "$out"' EXIT
                \\if log=$("$1" "$3" -o "$out" 2>&1); then
                \\  echo "expected source crate {s} to be rejected" >&2
                \\  exit 1
                \\fi
                \\printf '%s\n' "$log" | grep -q "translate-rust failed: {s}" || {{
                \\  echo "expected source crate {s} to fail with {s}, got:" >&2
                \\  printf '%s\n' "$log" >&2
                \\  exit 1
                \\}}
                \\test ! -e "$out"
            , .{ spec[1], spec[2], spec[1], spec[2] }),
            "verify-source-refusal",
        });
        reject.addArtifactArg(exe);
        reject.addDirectoryArg(corpus_dir.path(b, b.fmt("source-{s}", .{spec[1]})));
        reject.addDirectoryArg(b.path(spec[0]));
        test_crates_step.dependOn(&reject.step);
    }

    // ── promoted crates: stage what publishes, run the one shared consumer ─
    // `promoted_crate_names` is the whole set of source fixtures that publish
    // a package today. Each is staged into its own package on the local cache
    // root, and the one shared consumer in `test/promoted_crates_consumer.zig`
    // is compiled and run against exactly those packages. The consumer owns
    // every vector; this step owns only the staging, the compiler and the
    // runner, so the build graph repeats no assertion the consumer already
    // makes. Its `--dep` and `-M` flags are generated from the same list the
    // staging loop walks, so a crate cannot be staged and then not handed to
    // the consumer.
    //
    // The list was four crates: `itoa`, `siphasher`, `seahash` and `atoi`.
    // The last three analyse with no unsupported node and still refuse, and
    // they refuse at `ir.validateForTranslation` — `IncompleteGenericMetadata`
    // from an instantiation whose arity does not match its declaration,
    // `UnsupportedPattern` from an `.unsupported` pattern node, and
    // `UnsupportedExpression` from an operator node the frontend declined to
    // type — so no package ever reaches the backend to emit and there is
    // nothing for the consumer to `@import`. A vector kept for one would pass
    // against a package that does not exist. They are not attempted here:
    // `test/e2e_test.zig` pins each of them to that exact typed error, and
    // `check-corpus` fails if this graph calls a crate positive that the e2e
    // program refuses. The day one publishes, its e2e row fails with
    // `UnsupportedSourceTranslated` and its name comes back into this table.
    //
    // Staging, consuming and cleaning up happen in one `sh` invocation so the
    // staged packages cannot outlive the run that needs them, and the whole
    // scratch directory is a `build.zig` path on the local cache root: this
    // repository is on an NFSv3 mount, where Zig's atomic rename aborts, and
    // the consumer's own `--cache-dir` keeps it from writing `.zig-cache`
    // into the checkout.
    //
    // The step has a name because a foreign target cannot run it: the consumer
    // drives the host toolchain, and the packages it would compile are host
    // packages. `test-crates` depends on the step rather than on the command,
    // so that target reports the row as not executed instead of reporting a
    // pass it never earned.
    const promoted_crates_step = steps.add(
        b,
        "test-promoted-crates",
        "Stage every promoted source fixture and run the shared consumer against it",
    );
    if (native_target) {
        const promoted_crates_cmd = b.addSystemCommand(&.{
            "sh",
            "-c",
            b.fmt(
                \\set -eu
                \\stage=$1
                \\zig=$2
                \\translator=$3
                \\shift 3
                \\test ! -e "$stage"
                \\trap 'rm -rf "$stage"' EXIT
                \\mkdir -p "$stage"
                \\for crate in "$@"; do
                \\  out="$stage/$crate"
                \\  test ! -e "$out"
                \\  "$translator" "test/crates/$crate" -o "$out"
                \\  test -f "$out/build.zig"
                \\  test -f "$out/build.zig.zon"
                \\  test -f "$out/src/root.zig"
                \\done
                \\"$zig" test \
                \\  --cache-dir "$stage/zig-cache" \
                \\  --global-cache-dir "$stage/zig-global-cache" \
                \\  {s} --dep r2z \
                \\  -Mroot=test/promoted_crates_consumer.zig \
                \\  --dep r2z \
                \\  {s} -Mr2z=r2z-core/src/root.zig
            , .{ promotedDepFlags(b), promotedModuleFlags(b) }),
            "verify-promoted-crates",
        });
        promoted_crates_cmd.addDirectoryArg(corpus_dir.path(b, "promoted-crates"));
        promoted_crates_cmd.addArg(b.graph.zig_exe);
        promoted_crates_cmd.addArtifactArg(exe);
        for (promoted_crate_names) |crate_name| promoted_crates_cmd.addArg(crate_name);
        promoted_crates_step.dependOn(&promoted_crates_cmd.step);
    } else {
        promoted_crates_step.dependOn(&b.addSystemCommand(&.{ "printf", "%s\\n", "test-promoted-crates: the consumer runs zig test over host packages; this target stages and runs nothing" }).step);
    }
    test_crates_step.dependOn(promoted_crates_step);

    // ── differential: the Rust and Zig oracles must print the same bytes ─
    // Both oracles take baked-in inputs and write one canonical ASCII record
    // stream to stdout. The Zig side is built twice from the same staged
    // package — Debug and ReleaseSafe — because a divergence that only one
    // optimization mode exposes is still a divergence; the Rust side is a
    // single `rustc` build of the self-contained oracle. A plain byte
    // comparison of the two recorded streams is the whole contract, and the
    // consumer's own assertions run in both modes as well.
    //
    // The Rust oracle is compiled AND RUN before the translator has staged
    // anything, and that ordering is the guarantee: `set -eu` exits at the
    // first failing command, so a Rust source that stopped compiling — or an
    // oracle that stopped running — would otherwise be reported as a
    // translator or consumer finding the first time either of those ran.
    //
    // Staging, both Zig oracle builds, the consumer in either mode and the
    // three captured streams share one scratch tree on the local cache root,
    // because this repository is on an NFSv3 mount where Zig's atomic rename
    // aborts. Nothing here writes into the checkout, and no Cargo is involved:
    // `rustc` compiles the single oracle file directly. That tree is not
    // pruned by this step; the script keeps each run's directory and names it
    // on stderr, so a recorded stream stays available for inspection and
    // removal stays an operator decision.
    const rustc_option = b.option(
        []const u8,
        "rustc",
        "Path to the rustc that compiles the Rust differential oracle (default: rustc on PATH)",
    );
    // A foreign target compiles and runs neither oracle — the Zig ones drive
    // the host toolchain and the Rust one is not a Zig artifact — so it must
    // not need rustc at all. The lookup is skipped there too: a configuration
    // that invokes no rustc cannot be failed for lacking one.
    //
    const rustc: ?[]const u8 = if (native_target) rustc_option orelse "rustc" else null;
    const differential_step = steps.add(
        b,
        "test-differential",
        "Compare the Rust and Zig differential oracles in Debug and ReleaseSafe (each run's directory is kept for inspection)",
    );
    if (native_target and rustc != null) {
        const differential_root = corpus_dir.path(b, "differential");
        const differential_cmd = b.addSystemCommand(&.{
            "sh",
            "-c",
            \\set -eu
            \\root=$1
            \\zig=$2
            \\rustc=$3
            \\translator=$4
            \\# Unique to this invocation, and nothing is ever deleted here.
            \\# `mktemp -d` creates it 0700 and owned by this user, atomically,
            \\# so two concurrent runs of this step never share a path: neither
            \\# can erase the package, the compiler cache or a captured stream
            \\# the other is still reading, and whatever an earlier killed run
            \\# left behind is not this run's to remove.
            \\if [ -L "$root" ]; then
            \\  echo "verify-differential-oracles: refusing to stage through the symlinked root $root" >&2
            \\  exit 1
            \\fi
            \\mkdir -p -- "$root"
            \\run="$(mktemp -d "$root/run-XXXXXXXX")"
            \\echo "verify-differential-oracles: run directory kept at $run" >&2
            \\# This step deletes nothing at all, on either outcome. A recursive
            \\# erase needs descendant ownership, mount and live-use facts that
            \\# only the operator has, so the run directory is kept and
            \\# reported just above, and removing it is a separate decision
            \\# made by someone who can check those. A success leaves its
            \\# recorded streams behind; a failure leaves them and the staged
            \\# package.
            \\# Rust first, and executed: a Rust build error, or an oracle that
            \\# no longer runs, reports as itself rather than as whatever
            \\# translation or consumer failure follows it.
            \\"$rustc" --edition 2021 -O --crate-name differential_rust_oracle -o "$run/differential-rust-oracle" test/differential_rust_oracle.rs
            \\"$run/differential-rust-oracle" > "$run/rust.stdout"
            \\pkg="$run/package"
            \\"$translator" test/crates/differential -o "$pkg"
            \\test -f "$pkg/build.zig"
            \\test -f "$pkg/build.zig.zon"
            \\test -f "$pkg/src/root.zig"
            \\# One cache per run, shared by every child compiler, so r2z-core
            \\# and the translated package are built once each instead of once
            \\# per optimization mode. It is per run rather than shared between
            \\# runs because concurrent Zig builds over one cache abort.
            \\build_oracle() {
            \\  "$zig" build-exe -O"$1" --cache-dir "$run/zig-cache" --global-cache-dir "$run/zig-global-cache" --dep translated --dep r2z -Mroot=test/differential_zig_oracle.zig --dep r2z -Mtranslated="$pkg/src/root.zig" -Mr2z=r2z-core/src/root.zig -femit-bin="$2"
            \\}
            \\# The consumer is the other half of this contract, so it runs in
            \\# both optimization modes too: an assertion that only ReleaseSafe
            \\# fails is still a failure, and a Debug-only run would never
            \\# compile it at all.
            \\build_consumer() {
            \\  "$zig" test -O"$1" --cache-dir "$run/zig-cache" --global-cache-dir "$run/zig-global-cache" --dep translated --dep r2z -Mroot=test/differential_consumer.zig --dep r2z -Mtranslated="$pkg/src/root.zig" -Mr2z=r2z-core/src/root.zig
            \\}
            \\build_oracle Debug "$run/differential-zig-oracle-debug"
            \\build_oracle ReleaseSafe "$run/differential-zig-oracle-release-safe"
            \\build_consumer Debug
            \\build_consumer ReleaseSafe
            \\"$run/differential-zig-oracle-debug" > "$run/zig-debug.stdout"
            \\"$run/differential-zig-oracle-release-safe" > "$run/zig-release-safe.stdout"
            \\cmp "$run/rust.stdout" "$run/zig-debug.stdout"
            \\cmp "$run/rust.stdout" "$run/zig-release-safe.stdout"
            ,
            "verify-differential-oracles",
        });
        differential_cmd.addDirectoryArg(differential_root);
        differential_cmd.addArg(b.graph.zig_exe);
        differential_cmd.addArg(rustc.?);
        differential_cmd.addArtifactArg(exe);
        test_crates_step.dependOn(&differential_cmd.step);
        differential_step.dependOn(&differential_cmd.step);
    } else if (!native_target) {
        // A foreign target cannot run either oracle: they drive the host
        // toolchain and the Rust one is not a Zig artifact. Report the row as
        // not executed rather than as a pass. The branch is chosen on the
        // target alone, so `-Dtarget=<cross>` says this whether or not a rustc
        // happens to be on PATH — and, per the lookup above, without asking.
        differential_step.dependOn(&b.addSystemCommand(&.{ "printf", "%s\\n", "test-differential: the oracles drive the host toolchain; this target compiles no differential artifact" }).step);
    } else {
        // A host without rustc cannot build the Rust oracle, so the comparison
        // has not run. Say so and fail: a silently shorter `test-crates` would
        // report a pass for a contract nobody checked.
        differential_step.dependOn(&b.addFail("test-differential: no rustc on PATH; pass -Drustc=<path>").step);
    }
    // `test-crates` depends on the step in every branch: a host with no rustc
    // sees the failure instead of a quietly shorter run, and a foreign target
    // sees the note the step prints.
    test_crates_step.dependOn(differential_step);

    // ── unit tests (one artifact per module) ────────────────────────────
    const test_step = steps.add(b, "test", "Run unit tests");

    // ── dead-source guard ───────────────────────────────────────────────
    // Zig only type-checks files inside some root's import graph, so a
    // `src/` file that no test root reaches is never compiled at all: its
    // tests do not run, and its type errors stay invisible. The walk runs at
    // configure time; only `check-sources` (and therefore `test`) fails on
    // what it finds.
    unreachable_sources = findUnreachableSources(b) catch |err| {
        std.log.err("check-sources: {s}", .{@errorName(err)});
        @panic("check-sources: reachability walk failed");
    };
    const check_sources_step = steps.add(
        b,
        "check-sources",
        "Fail when a src/**/*.zig file is reachable from no test root",
    );
    if (unreachable_sources.len != 0) {
        for (unreachable_sources) |path| {
            check_sources_step.dependOn(&b.addFail(b.fmt("check-sources: unreachable from every test root: {s}", .{path})).step);
        }
    }
    test_step.dependOn(check_sources_step);

    // ── graph guards ─────────────────────────────────────────────────────
    // Two facts about the graph itself, each computed at configure time and
    // each reported by a step rather than by the build script, so a command
    // that has nothing to do with either still runs.
    //
    //   check-commands  every command the prose documents is a step here
    //   check-corpus    every crate fixture has a row, and no two files call
    //                   the same crate positive and refused
    const check_commands_step = steps.add(
        b,
        "check-commands",
        "Fail when the documentation names a command this graph does not publish",
    );
    test_step.dependOn(check_commands_step);

    const check_corpus_step = steps.add(
        b,
        "check-corpus",
        "Fail when a crate fixture has no row, or when one file calls a crate positive that another refuses",
    );
    corpus_faults = findCorpusFaults(b) catch |err| {
        std.log.err("check-corpus: {s}", .{@errorName(err)});
        @panic("check-corpus: the corpus coverage scan failed");
    };
    if (corpus_faults.len != 0) {
        for (corpus_faults) |fault| {
            check_corpus_step.dependOn(&b.addFail(b.fmt("check-corpus: {s}", .{fault})).step);
        }
    }
    test_crates_step.dependOn(check_corpus_step);

    // The corpus runner checks placement, filesystem and toolchain rules
    // without creating scratch files or invoking a compiler.
    const entry_points_step = steps.add(
        b,
        "check-entry-points",
        "Run each pinned shell entry point's own placement, transport and toolchain self-check",
    );
    for ([_][]const u8{"tools/test-generated-corpus.sh"}) |entry_point| {
        const check = b.addRunFile(b.path(entry_point));
        check.addArg("--self-check");
        entry_points_step.dependOn(&check.step);
    }
    test_crates_step.dependOn(entry_points_step);

    const lib_tests = b.addTest(.{ .root_module = translate_rust });
    test_step.dependOn(&declinedRunArtifact(b, lib_tests).step);

    const ir_unit_tests = b.addTest(.{
        .root_module = ir,
    });
    test_step.dependOn(&declinedRunArtifact(b, ir_unit_tests).step);

    const ir_serialize_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ir/serialize_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "translate_rust.ir", .module = ir },
            },
        }),
    });
    test_step.dependOn(&declinedRunArtifact(b, ir_serialize_tests).step);

    const rust_tests = b.addTest(.{ .root_module = rust });
    const run_rust_tests = declinedRunArtifact(b, rust_tests);
    test_step.dependOn(&run_rust_tests.step);
    const test_rust_step = steps.add(b, "test-rust", "Run the Rust parser unit tests only");
    test_rust_step.dependOn(&run_rust_tests.step);

    const model_tests = b.addTest(.{ .root_module = model });
    test_step.dependOn(&declinedRunArtifact(b, model_tests).step);

    // Focused steps reuse the very Compile and Run steps `test` already
    // owns, so a focused run is one test binary executed, not a second
    // copy of the test root.
    const frontend_tests = b.addTest(.{ .root_module = frontend });
    // Select a backend explicitly for frontend test comparisons.
    // It sets this compile's own `use_llvm`; left unset the field stays
    // null and the toolchain keeps its own backend selection, so ordinary
    // builds are byte-identical. Whether LLVM changes the outcome is not
    // measured; the option only makes the comparison runnable.
    if (b.option(bool, "frontend-llvm", "Compile the frontend unit tests with LLVM (true) or the self-hosted backend (false); unset keeps the toolchain default")) |use_llvm| {
        frontend_tests.use_llvm = use_llvm;
    }
    const run_frontend_tests = declinedRunArtifact(b, frontend_tests);
    test_step.dependOn(&run_frontend_tests.step);
    const test_frontend_step = steps.add(b, "test-frontend", "Run the frontend unit tests only");
    test_frontend_step.dependOn(&run_frontend_tests.step);

    const backend_tests = b.addTest(.{ .root_module = backend });
    const run_backend_tests = declinedRunArtifact(b, backend_tests);
    test_step.dependOn(&run_backend_tests.step);
    const test_backend_step = steps.add(b, "test-backend", "Run the backend unit tests only");
    test_backend_step.dependOn(&run_backend_tests.step);

    const driver_tests = b.addTest(.{ .root_module = driver });
    test_step.dependOn(&declinedRunArtifact(b, driver_tests).step);

    const backend_serialize_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/backend/zig/serialize_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "translate_rust.ir", .module = ir },
            },
        }),
    });
    test_step.dependOn(&declinedRunArtifact(b, backend_serialize_tests).step);

    // Every target compiles the e2e program and the shipped CLI; only the
    // host build runs them, because both drive the host toolchain.
    test_step.dependOn(&e2e_exe.step);
    test_step.dependOn(&exe.step);

    // E2E integration tests (in-process native translation → working Zig pkgs).
    if (native_target) test_step.dependOn(&run_e2e.step);
    test_crates_step.dependOn(&run_e2e.step);

    // Every child of `test-crates` drives a host artifact: the shipped CLI
    // through `sh`, the shared consumers through `zig test` over packages the
    // translator just published, the runtime package through the host `zig
    // build`, and the differential oracle through `rustc`. A foreign target
    // can compile some of those and execute none of them, so this step says
    // so once instead of each child discovering it separately — and the two
    // children that already report a foreign target for themselves
    // (`test-promoted-crates`, `test-differential`) keep that report for a
    // direct invocation of either.
    if (!native_target) {
        test_crates_step.dependOn(&b.addSystemCommand(&.{ "printf", "%s\\n", "test-crates: this foreign target executes no host-tool checks" }).step);
    }

    // Explicit CLI modes must keep distinct output contracts: `--translate`
    // emits framed source to stdout without `-o`, while `--emit-package`
    // rejects the same invocation with OutputPathRequired.
    const cli_contract = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\set -eu
        \\binary="$0"
        \\output=$("$binary" --translate test/mini.json)
        \\case "$output" in
        \\  *"// --- src/root.zig ---"*) ;;
        \\  *) echo "missing root source frame" >&2; exit 1 ;;
        \\esac
        \\case "$output" in
        \\  *"// --- src/util.zig ---"*) ;;
        \\  *) echo "missing util source frame" >&2; exit 1 ;;
        \\esac
        \\if package_output=$("$binary" --emit-package test/mini.json 2>&1); then
        \\  echo "expected --emit-package without -o to fail" >&2
        \\  exit 1
        \\fi
        \\case "$package_output" in
        \\  *"translate-rust: package mode requires -o <out-dir>"*) ;;
        \\  *) echo "missing package-mode output-path error" >&2; exit 1 ;;
        \\esac
        \\case "$package_output" in
        \\  *"OutputPathRequired"*) ;;
        \\  *) echo "missing OutputPathRequired error" >&2; exit 1 ;;
        \\esac
    });
    cli_contract.addArtifactArg(exe);
    if (native_target) test_step.dependOn(&cli_contract.step);

    // ── golden serialization tests (RustIr + ZigAST snapshots) ─────────────
    const golden_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/golden_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "translate_rust", .module = translate_rust },
            },
        }),
    });
    test_step.dependOn(&declinedRunArtifact(b, golden_tests).step);

    // The same single policy as the CLI and the e2e program, applied to every
    // test binary the matrix builds.
    for ([_]*std.Build.Step.Compile{
        lib_tests,
        ir_unit_tests,
        ir_serialize_tests,
        rust_tests,
        model_tests,
        frontend_tests,
        backend_tests,
        driver_tests,
        backend_serialize_tests,
        golden_tests,
    }) |compile| {
        if (cross_linkage) |mode| compile.linkage = mode;
    }

    const install_docs = b.addInstallDirectory(.{
        .source_dir = exe.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = steps.add(b, "docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);

    // Registered BEFORE the documented-command scan below, so the scan can see
    // it: a step published after the scan would read as undocumented to any
    // prose that names it.
    const check_cross_target_step = steps.add(
        b,
        "check-cross-target",
        "Fail when a published Run step could fail a row this host cannot launch instead of compiling it",
    );
    test_step.dependOn(check_cross_target_step);
    declined_run_faults = findDeclinedRunFaults(b) catch |err| {
        std.log.err("check-cross-target: {s}", .{@errorName(err)});
        @panic("check-cross-target: the declined-run audit failed");
    };
    if (declined_run_faults.len != 0) {
        for (declined_run_faults) |fault| {
            check_cross_target_step.dependOn(&b.addFail(b.fmt("check-cross-target: {s}", .{fault})).step);
        }
    }

    // Every step this graph publishes exists by now, so the documented-command
    // scan can answer honestly.
    undocumented = findUndocumentedCommands(b, &steps) catch |err| {
        std.log.err("check-commands: {s}", .{@errorName(err)});
        @panic("check-commands: the documented-command scan failed");
    };
    if (undocumented.len != 0) {
        for (undocumented) |entry| {
            check_commands_step.dependOn(&b.addFail(b.fmt("check-commands: {s} documents `{s}`, which no step publishes", .{ entry.doc, entry.command })).step);
        }
    }
}

// ---------------------------------------------------------------------------
// Cross-target run policy
// ---------------------------------------------------------------------------

/// Every Run step this graph publishes, so the declined-run policy on each one
/// can be asserted rather than assumed.
var declined_run_steps: std.ArrayListUnmanaged(*std.Build.Step.Run) = .empty;

/// Faults in the declined-run policy, computed at configure time and already
/// spelled out.
var declined_run_faults: []const []const u8 = &.{};

/// `b.addRunArtifact` with this graph's declined-foreign-run policy applied.
///
/// The policy is that a row whose binary this host cannot launch is COMPILED
/// and reported as not executed — never failed. Zig's default is the opposite:
/// `std/Build/Step/Run.zig`'s `failForeign` turns an unlaunchable foreign run
/// into a build error, so a matrix row for a target with no local interpreter
/// (no `wine` for the Windows rows, no user-mode environment for the BSD and
/// Apple rows) aborts the whole build and reports no coverage at all. That is
/// what the sibling graph in `test/generated_corpus_build.zig` already works
/// around, and this graph is the one that had not caught up.
///
/// `skip_foreign_checks` is what turns that failure into a decline. It is set
/// here and ONLY here; `failing_to_execute_foreign_is_an_error` is deliberately
/// left at its default, so once a runner has been permitted and chosen, a
/// runner that fails to launch is still an error rather than being quietly
/// downgraded to a compile. The distinction this draws is between "this host
/// cannot run that row" (declined, compile-only, reported with its reason) and
/// "this row claims a runner and the runner is broken" (failed). A reader must
/// be able to see that this is a declined run and not a suppressed failure,
/// which is why the flag is named here rather than swept into a blanket.
///
/// A `b.addSystemCommand` step does not need this: Zig foreign-checks only the
/// binaries a Run step was built to EXECUTE, and a system command executes a
/// host program. Several of them additionally depend on foreign artifacts
/// (the shell scripts driving the shipped CLI), which is why the host-target
/// guards around them — not this flag — are what decline those rows.
fn declinedRunArtifact(b: *std.Build, artifact: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = b.addRunArtifact(artifact);
    run.skip_foreign_checks = true;
    declined_run_steps.append(b.allocator, run) catch @panic("declined-run registry: out of memory");
    return run;
}

/// Reasons the declined-run policy is not in force on a published Run step.
///
/// Three things can go wrong and all three are silent, so each is checked
/// against something other than this file's own good intentions:
///
///   * the flag is cleared on a step after the helper set it — caught by
///     re-reading the registry;
///   * a new Run step is created by calling `b.addRunArtifact` directly and so
///     never passes through the helper — caught by requiring this file to hold
///     exactly one such call, the helper's own;
///   * the registry itself goes empty — caught by refusing an empty set, since
///     "every step passed" and "no step was checked" look identical otherwise.
fn findDeclinedRunFaults(b: *std.Build) ![]const []const u8 {
    const gpa = b.allocator;
    var faults: std.ArrayListUnmanaged([]const u8) = .empty;
    if (declined_run_steps.items.len == 0) {
        try faults.append(
            gpa,
            "no Run step was registered, so the declined-run policy is vacuous: a vacuous check is not a passing one",
        );
        return faults.items;
    }
    for (declined_run_steps.items) |run| {
        if (run.skip_foreign_checks) continue;
        try faults.append(
            gpa,
            "a Run step lost `skip_foreign_checks`, so a row this host cannot launch fails the build instead of compiling",
        );
        break;
    }
    // There is no public API to enumerate every Run step in a graph, so the
    // two counts below are what make the registry trustworthy. Both are read
    // out of this file's own source rather than assumed:
    //
    //   * exactly one raw artifact-run call site — the helper's own. A second
    //     one is a Run step built outside the policy, flag simply absent.
    //   * one helper call per registration — so the helper did not stop
    //     registering, which would make the first count pass vacuously.
    const source = try std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        "build.zig",
        gpa,
        .limited(doc_limit),
    );
    // Both needles are assembled at comptime rather than written out whole, and
    // neither is spelled out in this comment or in the message below: a
    // contiguous occurrence in either place would be counted by this file's
    // own search, and the check would fail on a tree that had done nothing
    // wrong.
    const raw_needle = "b.addRun" ++ "Artifact(";
    const raw_sites = countOccurrences(source, raw_needle);
    if (raw_sites != 1) {
        try faults.append(gpa, b.fmt(
            "build.zig holds {d} raw artifact-run call sites; exactly one is allowed and it is `declinedRunArtifact`'s own, so every published Run step carries the declined-run policy",
            .{raw_sites},
        ));
    }
    const helper_needle = "declinedRunArtifact" ++ "(b, ";
    const helper_sites = countOccurrences(source, helper_needle);
    if (helper_sites != declined_run_steps.items.len) {
        try faults.append(gpa, b.fmt(
            "build.zig calls `declinedRunArtifact` {d} time(s) but {d} Run step(s) were registered; the two must agree or the policy is not being applied",
            .{ helper_sites, declined_run_steps.items.len },
        ));
    }
    return faults.items;
}

/// How many times `needle` occurs in `source`.
fn countOccurrences(source: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, needle)) |at| {
        count += 1;
        cursor = at + needle.len;
    }
    return count;
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

// ---------------------------------------------------------------------------
// Vendored runtime license
// ---------------------------------------------------------------------------

/// A license file is a whole document, and a generated package that reproduces
/// one must reproduce all of it.
const runtime_license_limit = 256 << 10;

/// The license text a generated package must carry alongside the vendored
/// runtime, or null when this checkout has none. The runtime's own file wins;
/// the project's is the fallback, because the runtime is part of the project
/// and inherits its terms.
///
/// `@embedFile` cannot express a file that is absent, so the optional text
/// travels as a build option instead of being embedded unconditionally.
fn runtimeLicense(b: *std.Build) ?[]const u8 {
    b.dependOnDirectoryContents(b.path(""));
    b.dependOnDirectoryContents(b.path("r2z-core"));
    const candidates = [_][]const u8{ "r2z-core/LICENSE", "LICENSE" };
    for (candidates) |candidate| {
        const text = std.Io.Dir.cwd().readFileAlloc(
            b.graph.io,
            candidate,
            b.allocator,
            .limited(runtime_license_limit),
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => @panic("reading the project license failed"),
        };
        b.dependOnFileContents(b.path(candidate));
        return text;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Dead-source guard
// ---------------------------------------------------------------------------

/// `src/` files that no build root reaches, computed at configure time.
var unreachable_sources: []const []const u8 = &.{};

/// Every file the build graph compiles a test or artifact from. A `src/` file
/// is compiled if and only if one of these reaches it through `@import`.
const source_roots = [_][]const u8{
    "src/root.zig",
    "src/main.zig",
    "src/ir/serialize_test.zig",
    "src/backend/zig/serialize_test.zig",
    "test/generate_mini_wire.zig",
    "test/generate_fnv_golden.zig",
    "test/generate_hex_golden.zig",
    "test/generate_mini_golden.zig",
    "test/generate_compat_golden.zig",
    "test/generate_wyhash_golden.zig",
    "test/generate_adler_golden.zig",
    "test/generate_multimod_golden.zig",
    "test/e2e_test.zig",
    // The corpus producer is a build root like every other generator here: it
    // imports `translate_rust`, so registering it keeps the walk honest if it
    // ever grows its own module imports.
    "test/generated_corpus.zig",
    "test/golden_test.zig",
};

/// Project modules, mapped to the root file that defines them. Names outside
/// this table (`std`, `rust`, `serde`, `r2z_core_assets`) are not ours to walk.
const module_roots = [_]struct { name: []const u8, path: []const u8 }{
    .{ .name = "tree_sitter", .path = "src/tree_sitter.zig" },
    .{ .name = "translate_rust", .path = "src/root.zig" },
    .{ .name = "translate_rust.rust", .path = "src/rust.zig" },
    .{ .name = "translate_rust.model", .path = "src/model/root.zig" },
    .{ .name = "translate_rust.ir", .path = "src/ir/root.zig" },
    .{ .name = "translate_rust.frontend", .path = "src/frontend/root.zig" },
    .{ .name = "translate_rust.backend", .path = "src/backend/root.zig" },
    .{ .name = "translate_rust.driver", .path = "src/driver/root.zig" },
};

const unreachable_limit = 8 << 20;

/// The quoted operand of every `@import("...")` in `source`, as slices into
/// `source`.
fn importTargets(allocator: std.mem.Allocator, source: []const u8) ![][]const u8 {
    const needle = "@import(\"";
    var targets: std.ArrayListUnmanaged([]const u8) = .empty;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, needle)) |start| {
        const name_start = start + needle.len;
        const end = std.mem.indexOfScalarPos(u8, source, name_start, '"') orelse break;
        try targets.append(allocator, source[name_start..end]);
        cursor = end + 1;
    }
    return targets.items;
}

/// Resolve one `@import` operand seen in `from` to a project file, or null
/// when it names a module this build does not own.
fn resolveImport(
    allocator: std.mem.Allocator,
    from: []const u8,
    target: []const u8,
) !?[]const u8 {
    if (std.mem.endsWith(u8, target, ".zig")) {
        const dir = std.fs.path.dirname(from) orelse ".";
        const joined = try std.fs.path.join(allocator, &.{ dir, target });
        return joined;
    }
    for (module_roots) |module| {
        if (std.mem.eql(u8, module.name, target)) return module.path;
    }
    if (std.mem.startsWith(u8, target, "translate_rust")) {
        std.log.err("check-sources: '{s}' imports unknown module '{s}'", .{ from, target });
        return error.UnknownModule;
    }
    return null;
}

fn byPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Every `src/**/*.zig` file no build root reaches through `@import`.
fn findUnreachableSources(b: *std.Build) ![][]const u8 {
    const gpa = b.allocator;
    const io = b.graph.io;
    b.dependOnDirectoryContents(b.path("src"));
    var present: std.StringHashMapUnmanaged(void) = .empty;
    {
        var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .directory) {
                b.dependOnDirectoryContents(b.path(b.fmt("src/{s}", .{entry.path})));
            }
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            try present.put(gpa, try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path}), {});
        }
    }

    var reached: std.StringHashMapUnmanaged(void) = .empty;
    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    for (source_roots) |root| {
        try reached.put(gpa, root, {});
        try queue.append(gpa, root);
    }
    while (queue.pop()) |path| {
        b.dependOnFileContents(b.path(path));
        const source = try std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            gpa,
            .limited(unreachable_limit),
        );
        for (try importTargets(gpa, source)) |target| {
            const resolved = (try resolveImport(gpa, path, target)) orelse continue;
            if (!present.contains(resolved)) continue;
            if (reached.contains(resolved)) continue;
            try reached.put(gpa, resolved, {});
            try queue.append(gpa, resolved);
        }
    }

    var dead: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = present.keyIterator();
    while (it.next()) |key| {
        if (!reached.contains(key.*)) try dead.append(gpa, key.*);
    }
    std.mem.sort([]const u8, dead.items, {}, byPath);
    return dead.items;
}

// ---------------------------------------------------------------------------
// Published steps
// ---------------------------------------------------------------------------

/// The named steps this graph publishes, collected as each one is registered.
///
/// `zig build --help` lists whatever is in the graph, and the prose in
/// README.md is written against that list, so the two have to be
/// able to disagree loudly. Registering through `add` is what makes
/// `check-commands` a complete claim: a step added with a raw `b.step` call
/// would be absent here, and a documented command naming it would fail the
/// check rather than pass unnoticed.
const PublishedSteps = struct {
    names: std.ArrayListUnmanaged([]const u8) = .empty,

    fn add(
        self: *PublishedSteps,
        b: *std.Build,
        name: []const u8,
        description: []const u8,
    ) *std.Build.Step {
        const step = b.step(name, description);
        self.names.append(b.allocator, name) catch @panic("step registry: out of memory");
        return step;
    }

    fn declares(self: *const PublishedSteps, name: []const u8) bool {
        for (self.names.items) |published| {
            if (std.mem.eql(u8, published, name)) return true;
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// Documented commands
// ---------------------------------------------------------------------------

/// A command the prose documents and this graph does not publish.
const UndocumentedCommand = struct { doc: []const u8, command: []const u8 };

/// Documented commands, computed at configure time.
var undocumented: []const UndocumentedCommand = &.{};

/// Files that document this build graph's commands.
const command_docs = [_][]const u8{
    "README.md",
    "tools/test-generated-corpus.sh",
};

/// Build invocations in the documentation.
const documented_prefix = "zig build";

const doc_limit = 8 << 20;

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9');
}

/// The step following a documented build invocation, or null for flags,
/// paths and the default install step.
fn documentedStep(source: []const u8, after: usize) ?[]const u8 {
    var cursor = after;
    while (cursor < source.len and (source[cursor] == ' ' or source[cursor] == '\t')) {
        cursor += 1;
    }
    if (cursor >= source.len or source[cursor] == '\n' or source[cursor] == '\r') {
        return null;
    }
    if (source[cursor] == '#') return null;
    const start = cursor;
    while (cursor < source.len) : (cursor += 1) {
        const c = source[cursor];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') break;
    }
    const token = source[start..cursor];
    if (token.len == 0 or !isWordChar(token[0])) return null;
    for (token) |c| {
        if (!isWordChar(c) and c != '-' and c != '_') return null;
    }
    return token;
}

/// Every documented command no registered step answers to, with the file that
/// documents it.
fn findUndocumentedCommands(
    b: *std.Build,
    steps: *const PublishedSteps,
) ![]const UndocumentedCommand {
    const gpa = b.allocator;
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    var missing: std.ArrayListUnmanaged(UndocumentedCommand) = .empty;
    for (command_docs) |doc| {
        b.dependOnFileContents(b.path(doc));
        const source = cwd.readFileAlloc(io, doc, gpa, .limited(doc_limit)) catch |err| switch (err) {
            // A file that documents this graph and is not here is a hole in the
            // check, so it is reported rather than skipped.
            error.FileNotFound => {
                std.log.err("check-commands: the documented file {s} is missing", .{doc});
                return error.DocumentationMissing;
            },
            else => return err,
        };
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, source, cursor, documented_prefix)) |at| {
            cursor = at + documented_prefix.len;
            const command = documentedStep(source, cursor) orelse continue;
            if (steps.declares(command)) continue;
            try missing.append(gpa, .{ .doc = doc, .command = command });
        }
    }
    return missing.items;
}

// ---------------------------------------------------------------------------
// Corpus rows
// ---------------------------------------------------------------------------

/// Source fixtures this graph drives through the shipped CLI to prove they
/// refuse, with the exact typed error each one must report. The CLI prints it
/// as `translate-rust failed: <Error>`, which is what the assertion greps for.
///
/// This is the second pin for the crates it names, not the only one:
/// `test/e2e_test.zig` holds one expectation per refused crate and
/// `test-crates` runs that program, so a refusal pinned only there is already
/// asserted. Duplicating all of e2e's table here would be a second list of the
/// same rows to keep in step by hand, and the disagreement that would cause is
/// checked mechanically instead — see `corpus_rows`.
///
/// The two rows sit on different boundaries, and the table records which:
///
///   allocating-fmt  a CONSTRUCT this translator does not implement. Its
///                   `Display` body allocates, and the native `format` hook
///                   takes no allocator.
///   syn             an INPUT this translation was never given. `syn` reaches
///                   a `#[cfg(...)]` predicate naming a target property, and
///                   `src/frontend/cst.zig`'s `cfgBuiltinRequiresTarget`
///                   refuses exactly those keys rather than guessing.
///
/// The `syn` boundary is deliberate and fail-closed, not an oversight: `cfg`
/// only ever decides what to DROP, so a predicate that is false for the target
/// may prune safely and one that is true may not, and with no target
/// configuration the run cannot tell which case it is in. That is why this row
/// exists rather than a claim that the crate was never looked at — the census
/// ran the same CLI this table drives and the diagnostic is the boundary
/// speaking. `src/driver/pipeline.zig`'s `refusal_table` classifies the error
/// as `.cfg_predicate` and names the missing input, and
/// `src/driver/pipeline_test.zig` pins that classification, so the row cannot
/// drift from how the code reports it.
const rejected_source_specs = [_][3][]const u8{
    .{ "test/crates/allocating-fmt", "allocating-fmt", "UnsupportedAllocatingFormatter" },
    .{ "test/crates/syn", "syn", "UnsupportedCfgPredicate" },
};

/// Source fixtures that publish a package today, and therefore have a consumer
/// to run over it. `test/promoted_crates_consumer.zig` imports exactly these,
/// and the `--dep`/`-M` flags of the staging step are generated from this list
/// so the two cannot disagree about which crates are handed over.
const promoted_crate_names = [_][]const u8{
    "itoa",
};

/// `--dep <name>` for each promoted crate, in table order.
fn promotedDepFlags(b: *std.Build) []const u8 {
    var flags: std.ArrayListUnmanaged([]const u8) = .empty;
    for (promoted_crate_names) |crate_name| {
        flags.append(b.allocator, b.fmt("--dep {s}", .{crate_name})) catch @panic("promoted dep flags: out of memory");
    }
    return std.mem.join(b.allocator, " ", flags.items) catch @panic("promoted dep flags: out of memory");
}

/// `-M<name>="$stage/<name>/src/root.zig"` for each promoted crate. `$stage` is
/// the shell's own variable and is resolved there, not here, so the staged
/// tree never has to be spelled twice.
fn promotedModuleFlags(b: *std.Build) []const u8 {
    var flags: std.ArrayListUnmanaged([]const u8) = .empty;
    for (promoted_crate_names) |crate_name| {
        flags.append(
            b.allocator,
            b.fmt("-M{s}=\"$stage/{s}/src/root.zig\"", .{ crate_name, crate_name }),
        ) catch @panic("promoted module flags: out of memory");
    }
    return std.mem.join(b.allocator, " ", flags.items) catch @panic("promoted module flags: out of memory");
}

// ---------------------------------------------------------------------------
// Corpus coverage
// ---------------------------------------------------------------------------

/// What the graph claims about one crate fixture.
const CorpusRow = enum {
    /// A node stages the crate and a consumer runs over what it publishes.
    positive,
    /// A node pins the crate's exact typed refusal.
    refusal,
    /// Measured by neither, on purpose. That is still a claim, so the reason
    /// beside it is required: "we did not look at this one" has to be written
    /// down by somebody rather than inferred from an omission.
    ///
    /// Reserved for a crate NOBODY has run. A crate that has been run and
    /// refuses is `refusal`, not this: a row here whose reason is really about
    /// the crate being inconvenient (`too large`, `slow`) describes an absence
    /// of effort rather than a property of the input, and it contradicts every
    /// census that has since measured the crate. `check-corpus` cannot see the
    /// difference, because the only node that could contradict the row is the
    /// one this row declares it has.
    unmeasured,
};

/// The node that owns a crate's row, and what holding it proves. Each owner is
/// verified against the file that has to name the crate, so an owner cannot
/// survive the row it claimed to cover.
const CorpusOwner = enum {
    /// The e2e program names `test/crates/<name>` and runs a consumer over the
    /// package it publishes.
    e2e_positive,
    /// The e2e program's refusal table holds a `.name = "<name>"` row bound to
    /// one typed error.
    e2e_refusal,
    /// `promoted_crate_names` names it: this graph stages it and compiles the
    /// shared consumer against it.
    promoted_crates,
    /// `rejected_source_specs` names it: this graph pins its typed error.
    refused_source,
    /// The differential oracle step compiles the crate's translated sources
    /// into an oracle and compares its output with the Rust oracle's byte for
    /// byte. This owner alone does not claim that a crate publishes a package;
    /// the corpus row and its staging owner record that separate contract.
    differential_oracle,
};

/// Every crate fixture under `test/crates/`, with the row it has and the nodes
/// that own it.
///
/// A crate directory missing from this table is covered by nothing at all, and a
/// run that never mentions it looks exactly like a run that passed — which is
/// what `check-corpus` exists to report. Adding a crate fixture means adding its
/// row here, and the owner beside it is checked against the artifact that has
/// to name the crate, so the row cannot quietly become a fiction.
const corpus_rows = [_]struct {
    name: []const u8,
    row: CorpusRow,
    owners: []const CorpusOwner,
    reason: []const u8,
}{
    .{ .name = "adler", .row = .positive, .owners = &.{.e2e_positive}, .reason = "" },
    .{
        .name = "allocator-failure-ownership",
        .row = .positive,
        .owners = &.{.e2e_positive},
        .reason = "",
    },
    .{
        .name = "allocating-fmt",
        .row = .refusal,
        .owners = &.{ .e2e_refusal, .refused_source },
        .reason = "",
    },
    .{
        .name = "array-wrapped-owner",
        .row = .positive,
        .owners = &.{.e2e_positive},
        .reason = "",
    },
    .{ .name = "atoi", .row = .refusal, .owners = &.{.e2e_refusal}, .reason = "" },
    .{
        .name = "closure-capture-ownership",
        .row = .positive,
        .owners = &.{.e2e_positive},
        .reason = "",
    },
    .{ .name = "compat", .row = .positive, .owners = &.{.e2e_positive}, .reason = "" },
    .{
        .name = "cow-handoff",
        .row = .positive,
        .owners = &.{.e2e_positive},
        .reason = "",
    },
    .{ .name = "crc16", .row = .refusal, .owners = &.{.e2e_refusal}, .reason = "" },
    .{
        .name = "differential",
        .row = .positive,
        .owners = &.{ .e2e_positive, .differential_oracle },
        .reason = "",
    },
    .{
        .name = "enum-variant-owner-move",
        .row = .positive,
        .owners = &.{.e2e_positive},
        .reason = "",
    },
    .{ .name = "fletcher", .row = .refusal, .owners = &.{.e2e_refusal}, .reason = "" },
    .{ .name = "fnv", .row = .positive, .owners = &.{.e2e_positive}, .reason = "" },
    .{
        .name = "generic-owner-transfer",
        .row = .positive,
        .owners = &.{.e2e_positive},
        .reason = "",
    },
    .{
        .name = "guarded-owned-fallthrough",
        .row = .positive,
        .owners = &.{.e2e_positive},
        .reason = "",
    },
    .{ .name = "hex", .row = .positive, .owners = &.{.e2e_positive}, .reason = "" },
    .{
        .name = "iterator-chain-ownership",
        .row = .positive,
        .owners = &.{.e2e_positive},
        .reason = "",
    },
    .{
        .name = "itoa",
        .row = .positive,
        .owners = &.{ .e2e_positive, .promoted_crates },
        .reason = "",
    },
    .{
        .name = "let-bound-result-match",
        .row = .positive,
        .owners = &.{.e2e_positive},
        .reason = "",
    },
    .{ .name = "leb128", .row = .refusal, .owners = &.{.e2e_refusal}, .reason = "" },
    .{
        .name = "loop-ownership-exits",
        .row = .positive,
        .owners = &.{.e2e_positive},
        .reason = "",
    },
    .{ .name = "match-subject-handoff", .row = .positive, .owners = &.{.e2e_positive}, .reason = "" },
    .{ .name = "mini", .row = .positive, .owners = &.{.e2e_positive}, .reason = "" },
    .{ .name = "multimod", .row = .positive, .owners = &.{.e2e_positive}, .reason = "" },
    .{
        .name = "option-ref-mut-index",
        .row = .positive,
        .owners = &.{.e2e_positive},
        .reason = "",
    },
    .{
        .name = "overwritten-owner",
        .row = .positive,
        .owners = &.{.e2e_positive},
        .reason = "",
    },
    .{
        .name = "percent-encoding",
        .row = .positive,
        .owners = &.{.e2e_positive},
        .reason = "",
    },
    .{
        .name = "result-arm-payload-move",
        .row = .positive,
        .owners = &.{.e2e_positive},
        .reason = "",
    },
    .{ .name = "seahash", .row = .refusal, .owners = &.{.e2e_refusal}, .reason = "" },
    .{
        .name = "shadowed-inner-owner",
        .row = .positive,
        .owners = &.{.e2e_positive},
        .reason = "",
    },
    .{ .name = "siphasher", .row = .refusal, .owners = &.{.e2e_refusal}, .reason = "" },
    .{
        .name = "struct-field-owner-move",
        .row = .positive,
        .owners = &.{.e2e_positive},
        .reason = "",
    },
    // Measured: the census ran the shipped CLI over this crate and it refuses
    // `UnsupportedCfgPredicate`, which `rejected_source_specs` now pins. The
    // boundary is a `cfg` predicate naming a target property this translation
    // has no configuration for, and the frontend refuses those keys on purpose
    // rather than guessing which way they fall. No `corpus_rows` owner claims
    // `e2e_*` for it, so `check-corpus` is satisfied by `refused_source` alone
    // and `test/e2e_test.zig` is free to name it later.
    .{
        .name = "syn",
        .row = .refusal,
        .owners = &.{.refused_source},
        .reason = "",
    },
    .{ .name = "wyhash", .row = .positive, .owners = &.{.e2e_positive}, .reason = "" },
    .{ .name = "xxhash-rust", .row = .positive, .owners = &.{.e2e_positive}, .reason = "" },
    .{
        .name = "zero-field-shapes",
        .row = .positive,
        .owners = &.{.e2e_positive},
        .reason = "",
    },
};

/// Corpus coverage faults, computed at configure time and already spelled out.
var corpus_faults: []const []const u8 = &.{};

const e2e_program = "test/e2e_test.zig";
const corpus_root_dir = "test/crates";

/// Whether `source` names the crate fixture directory itself, rather than the
/// crate's basename somewhere in prose.
fn namesCrateFixture(
    gpa: std.mem.Allocator,
    source: []const u8,
    name: []const u8,
) bool {
    const needle = std.fmt.allocPrint(gpa, "{s}/{s}", .{ corpus_root_dir, name }) catch
        return false;
    return std.mem.indexOf(u8, source, needle) != null;
}

/// Whether `source` holds a `.name = "<name>"` row, the field the e2e program's
/// refusal table keys each expectation on.
fn namesRefusalRow(
    gpa: std.mem.Allocator,
    source: []const u8,
    name: []const u8,
) bool {
    const needle = std.fmt.allocPrint(gpa, ".name = \"{s}\"", .{name}) catch return false;
    return std.mem.indexOf(u8, source, needle) != null;
}

fn promotesHere(name: []const u8) bool {
    for (promoted_crate_names) |crate_name| {
        if (std.mem.eql(u8, crate_name, name)) return true;
    }
    return false;
}

/// Whether `rejected_source_specs` names the crate fixture directory whose
/// basename is exactly `name`. The comparison is on the basename, not a
/// suffix of the whole path: `syn` is a suffix of `test/crates/async` and of
/// `test/crates/syn`, so a suffix test would let one crate's row satisfy
/// another's owner.
fn refusesHere(name: []const u8) bool {
    for (rejected_source_specs) |spec| {
        const basename = std.fs.path.basename(spec[0]);
        if (std.mem.eql(u8, basename, name)) return true;
    }
    return false;
}

const test_dir = "test";
const consumer_suffix = "_consumer.zig";

/// Everything wrong with the corpus coverage claims, each fault already a
/// sentence naming the crate, the artifact and the disagreement.
///
/// Six things are checked, and each of them is a way a crate, or the consumer
/// that would prove it, could end up covered by nothing while every run stays
/// green:
///   * a crate directory with no row in `corpus_rows`;
///   * a row naming a crate directory that is not there;
///   * the same crate listed twice;
///   * an owner that no longer names its crate in the artifact it stands for;
///   * a crate one file stages as positive and another pins as a refusal;
///   * a `test/*_consumer.zig` program that no step compiles.
fn findCorpusFaults(b: *std.Build) ![]const []const u8 {
    const gpa = b.allocator;
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    var faults: std.ArrayListUnmanaged([]const u8) = .empty;

    var present: std.StringHashMapUnmanaged(void) = .empty;
    {
        b.dependOnDirectoryContents(b.path(corpus_root_dir));
        var dir = try cwd.openDir(io, corpus_root_dir, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            // `walk` descends into every crate; a fixture is a direct child.
            if (std.mem.indexOfScalar(u8, entry.path, '/') != null) continue;
            // The walker's `basename` points into a buffer the next
            // `walker.next` call reuses, so a map key taken from it dangles and
            // the next insert finds a phantom duplicate. `fetchPut`, not
            // `put`: a genuinely repeated name is a fault this checker exists
            // to report, and a map that asserted would abort the build before
            // it could say so.
            const name = try gpa.dupe(u8, entry.basename);
            if (present.fetchPut(gpa, name, {}) catch @panic("check-corpus: out of memory") != null) {
                try faults.append(gpa, b.fmt(
                    "the crate directory `{s}` was discovered more than once under {s}; the walk and the tree disagree",
                    .{ name, corpus_root_dir },
                ));
            }
        }
    }

    b.dependOnFileContents(b.path(e2e_program));
    b.dependOnFileContents(b.path("build.zig"));
    b.dependOnFileContents(b.path("test/generated_corpus.zig"));
    const e2e_source = try cwd.readFileAlloc(io, e2e_program, gpa, .limited(doc_limit));
    const build_source = try cwd.readFileAlloc(io, "build.zig", gpa, .limited(doc_limit));
    const producer_source = try cwd.readFileAlloc(
        io,
        "test/generated_corpus.zig",
        gpa,
        .limited(doc_limit),
    );
    // Those three are every program that compiles a consumer program. A
    // consumer none of them names is coverage that exists only as a file: its
    // assertions run nowhere, and nothing about the run says so.
    const compiled_sources = [_][]const u8{ e2e_source, build_source, producer_source };

    {
        b.dependOnDirectoryContents(b.path(test_dir));
        var dir = try cwd.openDir(io, test_dir, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            // A consumer is a direct child of `test/`; the fixtures and goldens
            // below it are not programs of this shape.
            if (std.mem.indexOfScalar(u8, entry.path, '/') != null) continue;
            if (!std.mem.endsWith(u8, entry.basename, consumer_suffix)) continue;
            var compiled = false;
            for (compiled_sources) |source| {
                if (std.mem.indexOf(u8, source, entry.basename) == null) continue;
                compiled = true;
                break;
            }
            if (compiled) continue;
            try faults.append(gpa, b.fmt(
                "test/{s} is a consumer program no step compiles; its assertions run nowhere",
                .{entry.basename},
            ));
        }
    }

    var declared: std.StringHashMapUnmanaged(void) = .empty;
    for (corpus_rows) |entry| {
        if (declared.fetchPut(gpa, entry.name, {}) catch @panic("check-corpus: out of memory")) |_| {
            try faults.append(gpa, b.fmt(
                "the crate `{s}` has more than one row in corpus_rows; one crate is one row",
                .{entry.name},
            ));
        }
        if (!present.contains(entry.name)) {
            try faults.append(gpa, b.fmt(
                "corpus_rows names `{s}`, which is not a crate fixture under {s}",
                .{ entry.name, corpus_root_dir },
            ));
        }
    }
    var it = present.keyIterator();
    while (it.next()) |key| {
        if (declared.contains(key.*)) continue;
        try faults.append(gpa, b.fmt(
            "the crate `{s}` has no row in corpus_rows: nothing in this graph stages it and nothing pins an error for it",
            .{key.*},
        ));
    }

    for (corpus_rows) |entry| {
        var positives: usize = 0;
        var refusals: usize = 0;
        for (entry.owners) |owner| switch (owner) {
            .e2e_positive => {
                positives += 1;
                if (!namesCrateFixture(gpa, e2e_source, entry.name)) {
                    try faults.append(gpa, b.fmt(
                        "`{s}` claims {s} stages `{s}`, but {s} no longer names its fixture directory",
                        .{ entry.name, @tagName(owner), entry.name, e2e_program },
                    ));
                }
            },
            .e2e_refusal => {
                refusals += 1;
                if (!namesRefusalRow(gpa, e2e_source, entry.name)) {
                    try faults.append(gpa, b.fmt(
                        "`{s}` claims {s} pins its typed error, but {s} holds no `.name = \"{s}\"` row",
                        .{ entry.name, @tagName(owner), e2e_program, entry.name },
                    ));
                }
            },
            .promoted_crates => {
                positives += 1;
                if (!promotesHere(entry.name)) {
                    try faults.append(gpa, b.fmt(
                        "`{s}` claims {s} stages it, but promoted_crate_names no longer names it",
                        .{ entry.name, @tagName(owner) },
                    ));
                }
            },
            .refused_source => {
                refusals += 1;
                if (!refusesHere(entry.name)) {
                    try faults.append(gpa, b.fmt(
                        "`{s}` claims {s} pins its typed error, but rejected_source_specs no longer names it",
                        .{ entry.name, @tagName(owner) },
                    ));
                }
            },
            // Neutral: the oracle step consumes the crate's sources without
            // claiming the crate publishes, so it counts as neither side.
            .differential_oracle => {
                if (!namesCrateFixture(gpa, build_source, entry.name)) {
                    try faults.append(gpa, b.fmt(
                        "`{s}` claims {s} stages it, but no differential step in build.zig names its fixture directory",
                        .{ entry.name, @tagName(owner) },
                    ));
                }
            },
        };
        switch (entry.row) {
            .positive => {
                if (positives == 0) try faults.append(gpa, b.fmt(
                    "`{s}` is declared positive but no owner stages it",
                    .{entry.name},
                ));
                if (refusals != 0) try faults.append(gpa, b.fmt(
                    "`{s}` is declared positive, and {d} of its owners pin it as a refusal; one file stages a crate another refuses",
                    .{ entry.name, refusals },
                ));
            },
            .refusal => {
                if (refusals == 0) try faults.append(gpa, b.fmt(
                    "`{s}` is declared a refusal but no owner pins its typed error",
                    .{entry.name},
                ));
                if (positives != 0) try faults.append(gpa, b.fmt(
                    "`{s}` is declared a refusal, and {d} of its owners stage it as a package; one file stages a crate another refuses",
                    .{ entry.name, positives },
                ));
            },
            .unmeasured => {
                if (entry.owners.len != 0) try faults.append(gpa, b.fmt(
                    "`{s}` is declared unmeasured yet lists {d} owner(s); an unmeasured crate has none",
                    .{ entry.name, entry.owners.len },
                ));
                if (entry.reason.len == 0) try faults.append(gpa, b.fmt(
                    "`{s}` is declared unmeasured with no recorded reason; refusing to look is still a claim",
                    .{entry.name},
                ));
                // "Unmeasured" is a claim about the whole graph, so it is
                // checked like one: if the e2e program has started naming the
                // crate, this row is stale, and it is said here rather than by
                // a run that quietly asserts less than the table claims.
                if (namesCrateFixture(gpa, e2e_source, entry.name) or
                    namesRefusalRow(gpa, e2e_source, entry.name))
                {
                    try faults.append(gpa, b.fmt(
                        "`{s}` is declared unmeasured, but {s} now names it; give it the row it has",
                        .{ entry.name, e2e_program },
                    ));
                }
            },
        }
    }
    return faults.items;
}
