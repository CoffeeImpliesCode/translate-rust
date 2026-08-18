//! End-to-end integration test for translate-rust (P7, "Drop the Sidecar").
//!
//! Executed as a small standalone program (see build.zig) so that child
//! processes spawned by `driver.translate` (the fingerprint-fix `zig build`)
//! and the per-package `zig build test` run as normal processes. Zig's test
//! runner (`--listen=-` protocol) cannot reliably spawn grandchildren, so this
//! is intentionally an executable, not a `test {}` block.
//!
//! Flow, per crate: in-process native translation of a Rust source directory
//! into a standalone r2z package (zero cargo/rustdoc/sidecar invocations),
//! structural + content assertions on the emitted package, then `zig build
//! test` inside the generated package to prove it compiles and passes tests.

const std = @import("std");
const translate_rust = @import("translate_rust");
const driver = translate_rust.model.driver;

/// Translate `crate_dir` into `out_dir`, assert the emitted package layout and
/// key symbols, then run `zig build test` inside the package.
fn runCrate(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    crate_dir: []const u8,
    out_dir: []const u8,
    package_stem: []const u8,
    expected_symbols: []const []const u8,
) !void {
    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, out_dir) catch {};
    try cwd.createDirPath(io, out_dir);
    errdefer cwd.deleteTree(io, out_dir) catch {};

    try stdout.writeStreamingAll(io, "e2e: translating `{s}`...\n");

    // 1. In-process native translation (no Rust toolchain).
    try driver.translate(gpa, io, stdout, crate_dir, out_dir);

    // 2. Assert the emitted package layout exists on disk.
    const rel_paths = [_][]const u8{ "build.zig", "build.zig.zon", "src/root.zig" };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    for (rel_paths) |rel| {
        buf.clearRetainingCapacity();
        try buf.appendSlice(gpa, out_dir);
        try buf.append(gpa, '/');
        try buf.appendSlice(gpa, rel);
        const full = try buf.toOwnedSlice(gpa);
        defer gpa.free(full);
        var file = try cwd.openFile(io, full, .{});
        file.close(io);
    }

    // 3. Assert content markers: `build.zig.zon` names the package, and
    //    `src/root.zig` carries the expected translated symbols.
    const zon_rel = try std.fs.path.join(gpa, &.{ out_dir, "build.zig.zon" });
    defer gpa.free(zon_rel);
    {
        var zon_file = try cwd.openFile(io, zon_rel, .{});
        defer zon_file.close(io);
        var io_buf: [4096]u8 = undefined;
        var reader = zon_file.reader(io, &io_buf);
        const zon_content = try reader.interface.allocRemaining(gpa, .limited(1 << 20));
        defer gpa.free(zon_content);
        if (std.mem.indexOf(u8, zon_content, package_stem) == null) {
            try stdout.writeStreamingAll(io, "e2e: FAIL — build.zig.zon lacks package name `{s}`\n", .{package_stem});
            return error.PackageNameMissing;
        }
    }

    const root_rel = try std.fs.path.join(gpa, &.{ out_dir, "src", "root.zig" });
    defer gpa.free(root_rel);
    {
        var root_file = try cwd.openFile(io, root_rel, .{});
        defer root_file.close(io);
        var io_buf: [4096]u8 = undefined;
        var reader = root_file.reader(io, &io_buf);
        const root_content = try reader.interface.allocRemaining(gpa, .limited(1 << 24));
        defer gpa.free(root_content);
        for (expected_symbols) |sym| {
            if (std.mem.indexOf(u8, root_content, sym) == null) {
                try stdout.writeStreamingAll(io, "e2e: FAIL — root.zig lacks symbol `{s}`\n", .{sym});
                return error.SymbolMissing;
            }
        }
    }

    // 4. Prove the emitted package compiles and its tests pass.
    const cmd = try std.fmt.allocPrint(gpa, "cd {s} && zig build test --summary all 2>&1", .{out_dir});
    defer gpa.free(cmd);

    const res = try std.process.run(gpa, io, .{
        .argv = &.{ "sh", "-c", cmd },
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    switch (res.term) {
        .exited => |code| {
            if (code != 0) {
                try stdout.writeStreamingAll(io, "e2e: FAIL — zig build test in `{s}` exited\n", .{out_dir});
                try stdout.writeStreamingAll(io, res.stderr);
                try stdout.writeStreamingAll(io, res.stdout);
                return error.PackageTestFailed;
            }
        },
        else => {
            try stdout.writeStreamingAll(io, "e2e: FAIL — zig build test in `{s}` terminated abnormally\n", .{out_dir});
            return error.PackageTestTerminatedAbnormally;
        },
    }

    // Clean up on success.
    try cwd.deleteTree(io, out_dir);
    try stdout.writeStreamingAll(io, "e2e: `{s}` → translated, compiles, and passes zig build test\n", .{crate_dir});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdout = std.Io.File.stdout();

    try runCrate(init.gpa, io, stdout,
        "test/crates/mini", "zig-out/e2e-test-mini", "r2z_mini",
        &.{ "Point", "Shape", "area" });
    try runCrate(init.gpa, io, stdout,
        "test/crates/fnv", "zig-out/e2e-test-fnv", "r2z_fnv",
        &.{ "fnv1a_hash", "FNV_OFFSET_BASIS" });

    try stdout.writeStreamingAll(io, "e2e: all crates translated and tested successfully\n");
}