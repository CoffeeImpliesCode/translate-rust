const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── tree-sitter runtime + Zig bindings (transitively fetches the C core) ──
    const tree_sitter = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });
    const ts_mod = tree_sitter.module("tree_sitter");
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
    // tree-sitter Zig bindings are available to the model for the hybrid
    // body extractor (ts_ext.zig). The tree-sitter C runtime is compiled into
    // the `rust` module; the exe links both modules so the extern symbols
    // resolve.
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
    // ── translate_rust.backend — target representations & lowering ───────
    const backend = b.addModule("translate_rust.backend", .{
        .root_source_file = b.path("src/backend/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "translate_rust.ir", .module = ir },
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

    const run_step = b.step("run", "Run translate-rust");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
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
    const generate_mini_wire_step = b.step(
        "generate-mini-wire",
        "Regenerate test/mini.json from validated canonical IR",
    );
    const generate_mini_wire_cmd = b.addRunArtifact(mini_wire_generator);
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
    const generate_fnv_golden_step = b.step(
        "generate-fnv-golden",
        "Regenerate FNV source goldens from validated canonical IR",
    );
    const generate_fnv_golden_cmd = b.addRunArtifact(fnv_golden_generator);
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
    const generate_hex_golden_step = b.step(
        "generate-hex-golden",
        "Regenerate hex source goldens from validated canonical IR",
    );
    const generate_hex_golden_cmd = b.addRunArtifact(hex_golden_generator);
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
    const generate_mini_golden_step = b.step(
        "generate-mini-golden",
        "Regenerate mini source goldens from validated canonical IR",
    );
    const generate_mini_golden_cmd = b.addRunArtifact(mini_golden_generator);
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
    const generate_compat_golden_step = b.step(
        "generate-compat-golden",
        "Regenerate compat source goldens from validated canonical IR",
    );
    const generate_compat_golden_cmd = b.addRunArtifact(compat_golden_generator);
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
    const generate_wyhash_golden_step = b.step(
        "generate-wyhash-golden",
        "Regenerate wyhash source goldens from validated canonical IR",
    );
    const generate_wyhash_golden_cmd = b.addRunArtifact(wyhash_golden_generator);
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
    const generate_adler_golden_step = b.step(
        "generate-adler-golden",
        "Regenerate adler source goldens from validated canonical IR",
    );
    const generate_adler_golden_cmd = b.addRunArtifact(adler_golden_generator);
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
    const generate_multimod_golden_step = b.step(
        "generate-multimod-golden",
        "Regenerate multimod source goldens from validated canonical IR",
    );
    const generate_multimod_golden_cmd = b.addRunArtifact(multimod_golden_generator);
    generate_multimod_golden_step.dependOn(&generate_multimod_golden_cmd.step);

    // `zig build source` translates the complete mini source fixture and
    // checks that staged promotion publishes the generated package.
    const source_step = b.step("source", "Translate the complete mini source fixture");
    const source_cmd = b.addSystemCommand(&.{
        "sh",
        "-c",
        "set -eu; test ! -e zig-out/r2z-mini; trap 'rm -rf zig-out/r2z-mini' EXIT; ./zig-out/bin/translate-rust test/crates/mini -o zig-out/r2z-mini; test -f zig-out/r2z-mini/build.zig; test -f zig-out/r2z-mini/build.zig.zon; test -f zig-out/r2z-mini/src/root.zig; test -f zig-out/r2z-mini/src/util.zig",
    });
    source_cmd.step.dependOn(b.getInstallStep());
    source_step.dependOn(&source_cmd.step);

    // ── e2e: fail-loud source and wire translation boundaries ───────────
    // `--listen` test-runner protocol cannot spawn grandchildren; the
    // executable translates mini and FNV source positively and rejects
    // incomplete wire fixtures before a package is written.
    const e2e_mod = b.addModule("e2e_test", .{
        .root_source_file = b.path("test/e2e_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "translate_rust", .module = translate_rust },
        },
    });
    const e2e_exe = b.addExecutable(.{
        .name = "e2e-test",
        .root_module = e2e_mod,
    });
    const run_e2e = b.addRunArtifact(e2e_exe);
    const e2e_step = b.step("test-e2e", "Translate mini/FNV source and wire fixtures");
    e2e_step.dependOn(&run_e2e.step);

    // ── translate: emit source from a wire-format JSON ──────────────────
    // `zig build translate -- test/mini.json` → parses + emits to stdout.
    const translate_step = b.step("translate", "Emit Zig source from a JSON dump");
    const translate_cmd = b.addRunArtifact(exe);
    if (b.args) |args| translate_cmd.addArgs(args);
    translate_step.dependOn(&translate_cmd.step);

    // Mini is a complete positive wire fixture. Every other corpus fixture
    // remains rejection-only under the strict IR contract.
    const test_crates_step = b.step("test-crates", "Translate mini, reject legacy wire and unsupported source fixtures");
    {
        // r2z-core runtime library (standalone package, part of the pipeline).
        const tc = b.addSystemCommand(&.{ "sh", "-c", "cd r2z-core && zig build test --summary all" });
        test_crates_step.dependOn(&tc.step);
    }
    const mini_wire_cmd = b.addSystemCommand(&.{
        "sh",
        "-c",
        "set -eu; test ! -e zig-out/r2z-check/mini; trap 'rm -rf zig-out/r2z-check/mini' EXIT; ./zig-out/bin/translate-rust test/mini.json -o zig-out/r2z-check/mini; test -f zig-out/r2z-check/mini/build.zig; test -f zig-out/r2z-check/mini/build.zig.zon; test -f zig-out/r2z-check/mini/src/root.zig; test -f zig-out/r2z-check/mini/src/util.zig",
    });
    mini_wire_cmd.step.dependOn(b.getInstallStep());
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
            b.fmt("test ! -e zig-out/r2z-check/{s}; if ./zig-out/bin/translate-rust {s} -o zig-out/r2z-check/{s}; then echo 'expected incomplete fixture {s} to be rejected' >&2; exit 1; fi; test ! -e zig-out/r2z-check/{s}", .{ spec[1], spec[0], spec[1], spec[0], spec[1] }),
        });
        reject.step.dependOn(b.getInstallStep());
        test_crates_step.dependOn(&reject.step);
    }
    // Source crates the translator must still refuse. The wire loop above only
    // proves "exits non-zero", which stays green when a fixture starts failing
    // with a *different* error, so these entries assert the typed error by
    // name: the CLI reports it as `translate-rust failed: <Error>`. Each crate
    // is a capability gap, not a defect; pinning the error makes the gap
    // explicit and turns an accidental change in which error a crate fails
    // with into a build failure.
    const rejected_source_specs = [_][3][]const u8{
        .{ "test/crates/siphasher", "siphasher", "UnresolvedTypePath" },
        .{ "test/crates/itoa", "itoa", "InvalidCast" },
        .{ "test/crates/atoi", "atoi", "UnsupportedExpression" },
        .{ "test/crates/leb128", "leb128", "UnsupportedExpression" },
        .{ "test/crates/seahash", "seahash", "InvalidCast" },
        .{ "test/crates/percent-encoding", "percent-encoding", "UnsupportedExpression" },
    };
    for (rejected_source_specs) |spec| {
        const reject = b.addSystemCommand(&.{
            "sh",
            "-c",
            b.fmt(
                \\set -eu
                \\out=zig-out/r2z-check/source-{s}
                \\test ! -e $out
                \\trap 'rm -rf $out' EXIT
                \\if log=$(./zig-out/bin/translate-rust {s} -o $out 2>&1); then
                \\  echo "expected source crate {s} to be rejected" >&2
                \\  exit 1
                \\fi
                \\printf '%s\n' "$log" | grep -q "translate-rust failed: {s}" || {{
                \\  echo "expected source crate {s} to fail with {s}, got:" >&2
                \\  printf '%s\n' "$log" >&2
                \\  exit 1
                \\}}
                \\test ! -e $out
            , .{ spec[1], spec[0], spec[1], spec[2], spec[1], spec[2] }),
        });
        reject.step.dependOn(b.getInstallStep());
        test_crates_step.dependOn(&reject.step);
    }

    // ── unit tests (one artifact per module, per house convention) ──
    const test_step = b.step("test", "Run unit tests");

    // ── dead-source guard ───────────────────────────────────────────────
    // Zig only type-checks files inside some root's import graph, so a
    // `src/` file that no test root reaches is never compiled at all: its
    // tests do not run, and its type errors stay invisible. The walk runs at
    // configure time; only `check-sources` (and therefore `test`) fails on
    // what it finds.
    unreachable_sources = findUnreachableSources(b.graph.io, b.allocator) catch |err| {
        std.log.err("check-sources: {s}", .{@errorName(err)});
        @panic("check-sources: reachability walk failed");
    };
    const check_sources_step = b.step(
        "check-sources",
        "Fail when a src/**/*.zig file is reachable from no test root",
    );
    if (unreachable_sources.len != 0) {
        check_sources_step.makeFn = struct {
            fn make(_: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
                for (unreachable_sources) |path| {
                    std.debug.print("check-sources: unreachable from every test root: {s}\n", .{path});
                }
                return error.DeadSources;
            }
        }.make;
    }
    test_step.dependOn(check_sources_step);

    const lib_tests = b.addTest(.{ .root_module = translate_rust });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    const ir_unit_tests = b.addTest(.{
        .root_module = ir,
    });
    test_step.dependOn(&b.addRunArtifact(ir_unit_tests).step);

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
    test_step.dependOn(&b.addRunArtifact(ir_serialize_tests).step);

    const rust_tests = b.addTest(.{ .root_module = rust });
    test_step.dependOn(&b.addRunArtifact(rust_tests).step);

    const model_tests = b.addTest(.{ .root_module = model });
    test_step.dependOn(&b.addRunArtifact(model_tests).step);

    const frontend_tests = b.addTest(.{ .root_module = frontend });
    test_step.dependOn(&b.addRunArtifact(frontend_tests).step);
    const backend_tests = b.addTest(.{ .root_module = backend });
    test_step.dependOn(&b.addRunArtifact(backend_tests).step);
    const driver_tests = b.addTest(.{ .root_module = driver });
    test_step.dependOn(&b.addRunArtifact(driver_tests).step);

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
    test_step.dependOn(&b.addRunArtifact(backend_serialize_tests).step);

    // E2E integration tests (in-process native translation → working Zig pkgs).
    test_step.dependOn(&run_e2e.step);
    test_crates_step.dependOn(&run_e2e.step);
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
    test_step.dependOn(&cli_contract.step);

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
    test_step.dependOn(&b.addRunArtifact(golden_tests).step);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = exe.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);
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
    "test/golden_test.zig",
};

/// Project modules, mapped to the root file that defines them. Names outside
/// this table (`std`, `tree_sitter`, `rust`, `serde`) are not ours to walk.
const module_roots = [_]struct { name: []const u8, path: []const u8 }{
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
        return try std.fs.path.join(allocator, &.{ dir, target });
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
fn findUnreachableSources(io: std.Io, gpa: std.mem.Allocator) ![][]const u8 {
    var present: std.StringHashMapUnmanaged(void) = .empty;
    {
        var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
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
