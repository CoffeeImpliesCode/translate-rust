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

fn writeMsg(io: std.Io, out: std.Io.File, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(std.heap.page_allocator, fmt ++ "\n", args);
    defer std.heap.page_allocator.free(msg);
    try out.writeStreamingAll(io, msg);
}

/// Read a whole file into `allocator` (caller owns the returned slice).
fn readFileAlloc(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    var dir = std.Io.Dir.cwd();
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var io_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &io_buf);
    return reader.interface.allocRemaining(gpa, .limited(1 << 24));
}

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

    try writeMsg(io, stdout, "e2e: translating `{s}`", .{crate_dir});

    // 1. In-process native translation (no cargo/rustdoc/sidecar).
    try driver.translate(gpa, io, stdout, crate_dir, out_dir);

    // 2. Assert the emitted package layout exists on disk.
    const rel_paths = [_][]const u8{ "build.zig", "build.zig.zon", "src/root.zig" };
    for (rel_paths) |rel| {
        const full = try std.fs.path.join(gpa, &.{ out_dir, rel });
        defer gpa.free(full);
        var file = try cwd.openFile(io, full, .{});
        file.close(io);
    }

    // 3. Assert `build.zig.zon` names the package.
    const zon_rel = try std.fs.path.join(gpa, &.{ out_dir, "build.zig.zon" });
    defer gpa.free(zon_rel);
    const zon_content = try readFileAlloc(gpa, io, zon_rel);
    defer gpa.free(zon_content);
    if (std.mem.indexOf(u8, zon_content, package_stem) == null) {
        try writeMsg(io, stdout, "e2e: FAIL — build.zig.zon lacks package name `{s}`", .{package_stem});
        return error.PackageNameMissing;
    }

    // 4. Assert `src/root.zig` carries the expected translated symbols.
    const root_rel = try std.fs.path.join(gpa, &.{ out_dir, "src", "root.zig" });
    defer gpa.free(root_rel);
    const root_content = try readFileAlloc(gpa, io, root_rel);
    defer gpa.free(root_content);
    for (expected_symbols) |sym| {
        if (std.mem.indexOf(u8, root_content, sym) == null) {
            try writeMsg(io, stdout, "e2e: FAIL — root.zig lacks symbol `{s}`", .{sym});
            return error.SymbolMissing;
        }
    }

    // 5. Prove the emitted package compiles and its tests pass.
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
                try writeMsg(io, stdout, "e2e: FAIL — zig build test in `{s}` exited", .{out_dir});
                try stdout.writeStreamingAll(io, res.stderr);
                try stdout.writeStreamingAll(io, res.stdout);
                return error.PackageTestFailed;
            }
        },
        else => {
            try writeMsg(io, stdout, "e2e: FAIL — zig build test in `{s}` terminated abnormally", .{out_dir});
            return error.PackageTestTerminatedAbnormally;
        },
    }

    // Clean up on success.
    try cwd.deleteTree(io, out_dir);
    try writeMsg(io, stdout, "e2e: `{s}` translated, compiles, and passes zig build test", .{crate_dir});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdout = std.Io.File.stdout();

    try runCrate(
        init.gpa,
        io,
        stdout,
        "test/crates/mini",
        "zig-out/e2e-test-mini",
        "r2z_mini",
        &.{ "Point", "Shape", "area" },
    );
    try runCrate(
        init.gpa,
        io,
        stdout,
        "test/crates/fnv",
        "zig-out/e2e-test-fnv",
        "r2z_fnv",
        &.{ "FnvHasher", "FnvBuildHasher" },
    );
    try runCrate(
        init.gpa,
        io,
        stdout,
        "test/crates/fletcher",
        "zig-out/e2e-test-fletcher",
        "r2z_fletcher",
        &.{ "calc_fletcher16", "calc_fletcher64" },
    );

    try writeMsg(io, stdout, "e2e: all crates translated and tested successfully", .{});
}
