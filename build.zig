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
    const model = b.addModule("translate_rust.model", .{
        .root_source_file = b.path("src/model/root.zig"),
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

    // ── translate: run the CLI on a wire-format JSON in `zig-out/` ─────
    // `zig build translate -- test/mini.json` → parses + emits.
    const translate_step = b.step("translate", "Run translate-rust --translate on a JSON dump");
    const translate_cmd = b.addRunArtifact(exe);
    translate_cmd.addArgs(&.{"--translate"});
    if (b.args) |args| translate_cmd.addArgs(args);
    translate_step.dependOn(&translate_cmd.step);

    // ── test-crates: run `zig test` on each translated crate golden ──────
    // The translated outputs (test/r2z-*.zig) carry the crate's own #[test]
    // blocks translated to Zig `test` blocks — the differential oracle.
    // `zig build test-crates` runs them all.
    const test_crates_step = b.step("test-crates", "Run zig test on every translated crate (test/r2z-*.zig)");
    // Only goldens that are real compilable translation targets go here.
    // r2z-hex.zig is a reduced textual subset (the emitter's `for (bytes) |byte|`
    // has an unused capture, so it is not valid Zig) — excluded until hex truly
    // translates (errors/alloc/arrays).
    const goldens = [_][]const u8{ "test/r2z-fnv.zig", "test/r2z-fletcher.zig" };
    for (goldens) |golden| {
        const tc = b.addSystemCommand(&.{ "zig", "test", golden });
        test_crates_step.dependOn(&tc.step);
    }

    // ── unit tests (one artifact per module, per house convention) ──
    const test_step = b.step("test", "Run unit tests");

    const lib_tests = b.addTest(.{ .root_module = translate_rust });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    const rust_tests = b.addTest(.{ .root_module = rust });
    test_step.dependOn(&b.addRunArtifact(rust_tests).step);

    const model_tests = b.addTest(.{ .root_module = model });
    test_step.dependOn(&b.addRunArtifact(model_tests).step);
}
