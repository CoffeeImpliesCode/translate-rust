const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── r2z module ───────────────────────────────────────────────
    const r2z_mod = b.addModule("r2z", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── r2z-core static library artifact ─────────────────────────
    const lib = b.addLibrary(.{
        .name = "r2z-core",
        .root_module = r2z_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // ── unit tests ───────────────────────────────────────────────
    const tests = b.addTest(.{
        .root_module = r2z_mod,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
