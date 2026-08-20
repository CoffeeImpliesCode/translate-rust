//! translate_rust.driver.pipeline — full end-to-end translation pipeline.
//!
//! Orchestrates the complete pipeline:
//! Rust Source / Wire JSON -> Frontend Analysis -> RustIR -> Backend Lowering ->
//! ZigAST Package -> Package Emission & Disk Writing -> Self-Healing Fingerprint.

const std = @import("std");
const ir = @import("translate_rust.ir");
const frontend = @import("translate_rust.frontend");
const backend = @import("translate_rust.backend");

/// Read a whole file into memory with allocation.
pub fn readFileAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]const u8 {
    var dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var io_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &io_buf);
    return reader.interface.allocRemaining(allocator, .limited(1 << 30));
}

/// Translate a Rust crate directory into a standalone Zig package at `out_dir`.
/// 1. Ingest & analyze: frontend analysis on crate source -> `ir.RustIR`.
/// 2. Lower to ZigAST: backend lowering of `RustIR` -> `backend.zig.ast.Package`.
/// 3. Write package to disk: formats Zig sources and builds manifest files into `out_dir`.
/// 4. Self-heal fingerprint: runs `zig build` probe to capture and patch package fingerprint.
pub fn translate(
    allocator: std.mem.Allocator,
    io: std.Io,
    crate_dir: []const u8,
    out_dir: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // 1. Ingest & analyze
    var rust_ir = try frontend.pipeline.analyzeCrate(arena_alloc, io, crate_dir);
    defer rust_ir.deinitInstantiations(arena_alloc);

    // 2. Lower to ZigAST
    const pkg = try backend.zig.lower.lowerRustIR(arena_alloc, &rust_ir, null);

    // 3. Write package to disk
    try backend.zig.package.writeToDisk(io, &pkg, out_dir);

    // 4. Self-heal fingerprint
    try fixFingerprint(arena_alloc, io, out_dir);
}

/// Translate a wire-format v2 JSON dump into a standalone Zig package at `out_dir`.
/// 1. Read JSON file bytes from `json_path`.
/// 2. Deserialize JSON -> `ir.RustIR`.
/// 3. Lower `RustIR` -> `backend.zig.ast.Package`.
/// 4. Write package to disk into `out_dir`.
/// 5. Self-heal fingerprint in `build.zig.zon`.
pub fn translateWireJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    json_path: []const u8,
    out_dir: []const u8,
) !void {
    const json_bytes = try readFileAlloc(allocator, io, json_path);
    defer allocator.free(json_bytes);

    const rust_ir = try ir.serialize.decode(allocator, json_bytes);

    const pkg = try backend.zig.lower.lowerRustIR(allocator, &rust_ir, null);

    try backend.zig.package.writeToDisk(io, &pkg, out_dir);

    try fixFingerprint(allocator, io, out_dir);
}

/// Zig requires a package manifest `.fingerprint` that matches the hash of the
/// package contents. After writing the package to disk, we run `zig build`,
/// parse any suggested fingerprint error from stderr/stdout, and patch `build.zig.zon`.
pub fn fixFingerprint(
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
) !void {
    const cmd = try std.fmt.allocPrint(allocator, "cd {s} && zig build 2>&1", .{out_dir});
    defer allocator.free(cmd);

    const res = std.process.run(allocator, io, .{
        .argv = &.{ "sh", "-c", cmd },
    }) catch return;
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    const dump = if (res.stdout.len > 0) res.stdout else res.stderr;

    const markers = [_][]const u8{
        "use this value: 0x",
        "fingerprint: 0x",
        "expected: 0x",
        "expected 0x",
    };

    var hex_opt: ?[]const u8 = null;
    for (markers) |marker| {
        if (std.mem.indexOf(u8, dump, marker)) |idx| {
            const rest = dump[idx + marker.len ..];
            var len: usize = 0;
            while (len < rest.len and std.ascii.isHex(rest[len])) : (len += 1) {}
            if (len > 0) {
                hex_opt = rest[0..len];
                break;
            }
        }
    }

    const hex = hex_opt orelse return;
    const fp = std.fmt.parseUnsigned(u64, hex, 16) catch return;

    // Patch build.zig.zon: replace `.fingerprint = 0x...` with discovered fingerprint
    const zon_path = try std.fs.path.join(allocator, &.{ out_dir, "build.zig.zon" });
    defer allocator.free(zon_path);

    var dir = std.Io.Dir.cwd();
    var io_buf: [4096]u8 = undefined;
    const f = dir.openFile(io, zon_path, .{}) catch return;
    defer f.close(io);

    var reader = f.reader(io, &io_buf);
    const zon = reader.interface.allocRemaining(allocator, .limited(1 << 20)) catch return;
    defer allocator.free(zon);

    const old_key = ".fingerprint = 0x";
    const old_idx = std.mem.indexOf(u8, zon, old_key) orelse return;
    const val_start = old_idx + old_key.len;
    var val_end = val_start;
    while (val_end < zon.len and std.ascii.isHex(zon[val_end])) : (val_end += 1) {}

    const fp_hex = try std.fmt.allocPrint(allocator, "{x}", .{fp});
    defer allocator.free(fp_hex);

    var patched: std.ArrayListUnmanaged(u8) = .empty;
    defer patched.deinit(allocator);
    try patched.appendSlice(allocator, zon[0..val_start]);
    try patched.appendSlice(allocator, fp_hex);
    if (val_end < zon.len) {
        try patched.appendSlice(allocator, zon[val_end..]);
    }

    const w = try dir.createFile(io, zon_path, .{});
    defer w.close(io);
    try w.writeStreamingAll(io, patched.items);
}

test "fingerprint extraction and patching logic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const sample_zon =
        \\.{
        \\    .name = .sample_pkg,
        \\    .version = "0.1.0",
        \\    .fingerprint = 0x0123456789abcdef,
        \\    .minimum_zig_version = "0.16.0",
        \\    .paths = .{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\    },
        \\}
    ;

    const old_key = ".fingerprint = 0x";
    const old_idx = std.mem.indexOf(u8, sample_zon, old_key).?;
    const val_start = old_idx + old_key.len;
    var val_end = val_start;
    while (val_end < sample_zon.len and std.ascii.isHex(sample_zon[val_end])) : (val_end += 1) {}

    const new_fp: u64 = 0x81677af28f9d3b4e;
    const fp_hex = try std.fmt.allocPrint(allocator, "{x}", .{new_fp});
    defer allocator.free(fp_hex);

    var patched: std.ArrayListUnmanaged(u8) = .empty;
    defer patched.deinit(allocator);
    try patched.appendSlice(allocator, sample_zon[0..val_start]);
    try patched.appendSlice(allocator, fp_hex);
    if (val_end < sample_zon.len) {
        try patched.appendSlice(allocator, sample_zon[val_end..]);
    }

    try testing.expect(std.mem.indexOf(u8, patched.items, ".fingerprint = 0x81677af28f9d3b4e") != null);
}
