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

    // ── translate_rust — library root ─────────────────────────
    const translate_rust = b.addModule("translate_rust", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "translate_rust.rust", .module = rust },
            .{ .name = "translate_rust.model", .module = model },
            .{ .name = "translate_rust.ir", .module = ir },
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

    // ── sidecar: drive the v0 Rust producer against a fixture crate ──────
    // `zig build sidecar` runs tools/sidecar/rustdoc-json.sh on the mini
    // fixture crate, emitting its raw rustdoc JSON to zig-out/ (the v1
    // wire-format normalization is a later phase — P4+).
    const sidecar_step = b.step("sidecar", "Run the Rust sidecar (cargo +nightly rustdoc) on the mini fixture");
    const sidecar = b.addSystemCommand(&.{
        "sh",               "tools/sidecar/rustdoc-json.sh",
        "test/crates/mini", "zig-out",
    });
    sidecar_step.dependOn(&sidecar.step);

    // ── source: run the Rust-source driver on a crate dir ─────────────
    // `zig build source` → cargo +nightly rustdoc (via sidecar) on
    // test/crates/fnv, producing zig-out/r2z-fnv/ as a standalone package.
    const source_step = b.step("source", "Run the Rust-source driver on the fnv crate -> zig-out/r2z-fnv");
    const source_cmd = b.addSystemCommand(&.{
        "sh",                                                                                        "-c",
        "rm -rf zig-out/r2z-fnv && ./zig-out/bin/translate-rust test/crates/fnv -o zig-out/r2z-fnv",
    });
    source_cmd.step.dependOn(b.getInstallStep());
    source_step.dependOn(&source_cmd.step);

    // ── e2e: in-process native translation of Rust source → Zig packages ──
    // Runs test/e2e_test.zig as a normal executable (NOT a b.addTest: Zig's
    // `--listen` test-runner protocol cannot spawn grandchildren, but the e2e
    // test must run `zig build test` inside each emitted package). Exercises
    // `driver.translate` on test/crates/{mini,fnv} and asserts the emitted
    // packages compile + pass `zig build test` with no Rust toolchain.
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
    const e2e_step = b.step("test-e2e", "E2E: translate Rust source crates -> working Zig packages");
    e2e_step.dependOn(&run_e2e.step);

    // ── translate: run the CLI on a wire-format JSON in `zig-out/` ─────
    // `zig build translate -- test/mini.json` → parses + emits.
    const translate_step = b.step("translate", "Run translate-rust --translate on a JSON dump");
    const translate_cmd = b.addRunArtifact(exe);
    translate_cmd.addArgs(&.{"--translate"});
    if (b.args) |args| translate_cmd.addArgs(args);
    translate_step.dependOn(&translate_cmd.step);
    // ── r2z translated packages — exported as first-class Zig modules & libs ──
    const r2z_fnv_mod = b.addModule("r2z-fnv", .{
        .root_source_file = b.path("test/r2z-fnv.zig"),
        .target = target,
        .optimize = optimize,
    });
    const r2z_fletcher_mod = b.addModule("r2z-fletcher", .{
        .root_source_file = b.path("test/r2z-fletcher.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = r2z_fletcher_mod;

    const r2z_fnv_lib = b.addLibrary(.{
        .name = "r2z-fnv",
        .root_module = r2z_fnv_mod,
        .linkage = .static,
    });
    b.installArtifact(r2z_fnv_lib);

    // ── test-crates: verify the TRANSLATION OUTPUT (not just translator src) ──
    // Regenerates every r2z package from its wire model, then ast-checks and
    // builds each emitted .zig. This is what makes the gate genuinely parse
    // (and compile) the actual translation output, not merely the translator's
    // own source. All 4 corpus crates (incl. generated fletcher/hex) run here.
    const test_crates_step = b.step("test-crates", "Regenerate + ast-check + build every generated r2z package");
    {
        // r2z-core runtime library (standalone package, part of the pipeline).
        const tc = b.addSystemCommand(&.{ "sh", "-c", "cd r2z-core && zig build test --summary all" });
        test_crates_step.dependOn(&tc.step);
    }
    const specs = [_][2][]const u8{
        .{ "test/fnv.json", "fnv" },
        .{ "test/mini.json", "mini" },
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
    for (specs) |spec| {
        const regen = b.addSystemCommand(&.{
            "sh",                                                                                                                                                                                                                                                                                            "-c",
            b.fmt("rm -rf zig-out/r2z-check/{s} && ./zig-out/bin/translate-rust {s} -o zig-out/r2z-check/{s} && for f in $(find zig-out/r2z-check/{s} -name '*.zig'); do zig ast-check $f || exit 1; done && cd zig-out/r2z-check/{s} && zig build test", .{ spec[1], spec[0], spec[1], spec[1], spec[1] }),
        });
        test_crates_step.dependOn(&regen.step);
    }
    // Hand-authored goldens (fnv 203 vectors, fletcher 6 vectors) also parse.
    const goldens = [_][]const u8{ "test/r2z-fnv.zig", "test/r2z-fletcher.zig" };
    for (goldens) |golden| {
        const tc = b.addSystemCommand(&.{ "zig", "test", golden });
        test_crates_step.dependOn(&tc.step);
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

    // E2E integration tests (in-process native translation → working Zig pkgs).
    test_step.dependOn(&run_e2e.step);
    test_crates_step.dependOn(&run_e2e.step);
}
