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
    // canonical v3 encoder path and atomically refreshes test/mini.json.
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
    const test_crates_step = b.step("test-crates", "Translate mini and reject legacy wire fixtures");
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

    // ── unit tests (one artifact per module, per house convention) ──
    const test_step = b.step("test", "Run unit tests");

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
}
