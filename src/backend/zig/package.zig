//! translate_rust.backend.zig.package — package writer.
//! Renders an `ast.Package` to a complete standalone Zig package directory:
//! build.zig, build.zig.zon, and every `pkg.files[i]` source file.

const std = @import("std");
const ast = @import("ast.zig");
const emit = @import("emit.zig");

// ---------------------------------------------------------------------------
// Package name helpers
// ---------------------------------------------------------------------------

/// Resolve the build.zig module/package name: the package name is used,
/// unless zon_deps are present, in which case the first dependency's name is
/// used (per the package spec).
fn packageIdName(pkg: *const ast.Package) []const u8 {
    if (pkg.zon_deps.len > 0) {
        return pkg.zon_deps[0].name;
    }
    return pkg.name;
}

/// Sanitize a package name into a valid Zig identifier for build.zig.zon
/// (hyphens and other non-identifier chars become underscores).
fn zonIdentName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out = try allocator.dupe(u8, name);
    for (0..out.len) |i| {
        const c = out[i];
        const valid = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
        if (!valid) out[i] = '_';
    }
    return out;
}

// ---------------------------------------------------------------------------
// build.zig / build.zig.zon generation
// ---------------------------------------------------------------------------

fn generateBuildZig(allocator: std.mem.Allocator, module_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const target = b.standardTargetOptions(.{{}});
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\
        \\    const pkg_mod = b.addModule("{s}", .{{
        \\        .root_source_file = b.path("src/root.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    }});
        \\
        \\    const tests = b.addTest(.{{ .root_module = pkg_mod }});
        \\    const run_tests = b.addRunArtifact(tests);
        \\    const test_step = b.step("test", "Run unit tests");
        \\    test_step.dependOn(&run_tests.step);
        \\
        \\    const lib = b.addLibrary(.{{
        \\        .name = "{s}",
        \\        .root_module = pkg_mod,
        \\        .linkage = .static,
        \\    }});
        \\    b.installArtifact(lib);
        \\}}
        \\
    ,
        .{ module_name, module_name },
    );
}

fn generateBuildZigZon(allocator: std.mem.Allocator, pkg: *const ast.Package) ![]const u8 {
    const zon_name = try zonIdentName(allocator, packageIdName(pkg));
    defer allocator.free(zon_name);

    const fingerprint: u64 = pkg.fingerprint orelse 0;

    // Common single-package manifest (no dependencies).
    if (pkg.zon_deps.len == 0) {
        return std.fmt.allocPrint(
            allocator,
            \\.{{
            \\    .name = .{s},
            \\    .version = "{s}",
            \\    .fingerprint = 0x{x:0>16},
            \\    .minimum_zig_version = "0.16.0",
            \\    .paths = .{{
            \\        "build.zig",
            \\        "build.zig.zon",
            \\        "src",
            \\    }},
            \\}}
            \\
        ,
            .{ zon_name, pkg.version, fingerprint },
        );
    }

    // Manifest with declared dependencies.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, ".{\n");
    try buf.appendSlice(allocator, "    .name = .");
    try buf.appendSlice(allocator, zon_name);
    try buf.appendSlice(allocator, ",\n");
    try buf.appendSlice(allocator, "    .version = \"");
    try buf.appendSlice(allocator, pkg.version);
    try buf.appendSlice(allocator, "\",\n");
    try buf.appendSlice(allocator, "    .fingerprint = 0x");
    var fp_buf: [16]u8 = undefined;
    const fp_str = try std.fmt.bufPrint(&fp_buf, "{x:0>16}", .{fingerprint});
    try buf.appendSlice(allocator, fp_str);
    try buf.appendSlice(allocator, ",\n");
    try buf.appendSlice(allocator, "    .minimum_zig_version = \"0.16.0\",\n");
    try buf.appendSlice(allocator, "    .dependencies = .{\n");
    for (pkg.zon_deps) |dep| {
        const dep_id = try zonIdentName(allocator, dep.name);
        defer allocator.free(dep_id);
        try buf.appendSlice(allocator, "        .");
        try buf.appendSlice(allocator, dep_id);
        try buf.appendSlice(allocator, " = .{ .url = \"");
        try buf.appendSlice(allocator, dep.url);
        try buf.appendSlice(allocator, "\", .hash = \"");
        try buf.appendSlice(allocator, dep.hash);
        try buf.appendSlice(allocator, "\" },\n");
    }
    try buf.appendSlice(allocator, "    },\n");
    try buf.appendSlice(allocator, "    .paths = .{\n");
    try buf.appendSlice(allocator, "        \"build.zig\",\n");
    try buf.appendSlice(allocator, "        \"build.zig.zon\",\n");
    try buf.appendSlice(allocator, "        \"src\",\n");
    for (pkg.zon_deps) |dep| {
        const dep_id = try zonIdentName(allocator, dep.name);
        defer allocator.free(dep_id);
        try buf.appendSlice(allocator, "        \"");
        try buf.appendSlice(allocator, dep_id);
        try buf.appendSlice(allocator, "\",\n");
    }
    try buf.appendSlice(allocator, "    },\n");
    try buf.appendSlice(allocator, "}\n");

    return buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Package writer
// ---------------------------------------------------------------------------

/// Write an `ast.Package` to `out_dir` on disk: build.zig, build.zig.zon, and
/// every `pkg.files[i]` rendered via `emit.emitFile`. Parent directories are
/// created as needed.
pub fn writeToDisk(io: std.Io, pkg: *const ast.Package, out_dir: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var dir = std.Io.Dir.cwd();
    try dir.createDirPath(io, out_dir);

    // 1. build.zig
    const module_name = packageIdName(pkg);
    const build_zig = try generateBuildZig(allocator, module_name);
    try writeFile(allocator, io, out_dir, "build.zig", build_zig);

    // 2. build.zig.zon
    const build_zig_zon = try generateBuildZigZon(allocator, pkg);
    try writeFile(allocator, io, out_dir, "build.zig.zon", build_zig_zon);

    // 3. Source files
    for (pkg.files) |file| {
        const content = try emit.emitFile(allocator, &file);
        try writeFile(allocator, io, out_dir, file.path, content);
    }
}

/// Write `content` to `out_dir/<rel_path>`, creating parent directories.
fn writeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
    rel_path: []const u8,
    content: []const u8,
) !void {
    var dir = std.Io.Dir.cwd();

    const full_path = try std.fs.path.join(allocator, &.{ out_dir, rel_path });
    defer allocator.free(full_path);

    if (std.fs.path.dirname(full_path)) |parent_dir| {
        try dir.createDirPath(io, parent_dir);
    }

    const file = try dir.createFile(io, full_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn buildTestPackage() ast.Package {
    const std_import: ast.Import = .{ .local_name = "std", .module_or_path = "std" };

    const limit_decl: ast.Decl = .{ .const_decl = .{
        .name = "LIMIT",
        .ty = ast.Type{ .prim = .u32 },
        .init = .{ .lit = .{ .int = 42 } },
    } };

    const add_fn: ast.Decl = .{ .fn_decl = .{
        .name = "add",
        .params = &.{
            .{ .name = "a", .ty = ast.Type{ .prim = .u32 } },
            .{ .name = "b", .ty = ast.Type{ .prim = .u32 } },
        },
        .ret_type = ast.Type{ .prim = .u32 },
        .body = .{
            .expr = &ast.Expr{ .bin_op = .{
                .op = .add,
                .lhs = &ast.Expr{ .ident = "a" },
                .rhs = &ast.Expr{ .ident = "b" },
            } },
        },
    } };

    const file: ast.File = .{
        .path = "src/root.zig",
        .imports = &.{std_import},
        .decls = &.{ limit_decl, add_fn },
        .tests = &.{
            .{
                .name = "add sums",
                .body = .{
                    .stmts = &.{
                        .{ .expr_stmt = &ast.Expr{ .call = .{
                            .callee = &ast.Expr{ .field_access = .{
                                .target = &ast.Expr{ .field_access = .{
                                    .target = &ast.Expr{ .ident = "std" },
                                    .field_name = "testing",
                                } },
                                .field_name = "expectEqual",
                            } },
                            .args = &.{
                                .{ .lit = .{ .int = 7 } },
                                .{ .call = .{
                                    .callee = &ast.Expr{ .ident = "add" },
                                    .args = &.{
                                        .{ .lit = .{ .int = 3 } },
                                        .{ .lit = .{ .int = 4 } },
                                    },
                                } },
                            },
                        } } },
                    },
                },
            },
        },
    };

    return .{
        .name = "demo",
        .version = "1.2.3",
        .fingerprint = 0xabcd,
        .files = &.{file},
    };
}

fn readFileContent(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    var io_buf: [4096]u8 = undefined;
    var dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &io_buf);
    return reader.interface.allocRemaining(allocator, .limited(1 << 20));
}

test "writeToDisk: writes build files and sources to a temp dir" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;

    const pkg = buildTestPackage();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);

    try writeToDisk(test_io, &pkg, tmp_root);

    // build.zig
    const build_zig_path = try std.fs.path.join(allocator, &.{ tmp_root, "build.zig" });
    defer allocator.free(build_zig_path);
    const build_zig = try readFileContent(allocator, test_io, build_zig_path);
    defer allocator.free(build_zig);

    // build.zig.zon
    const build_zon_path = try std.fs.path.join(allocator, &.{ tmp_root, "build.zig.zon" });
    defer allocator.free(build_zon_path);
    const build_zon = try readFileContent(allocator, test_io, build_zon_path);
    defer allocator.free(build_zon);

    // src/root.zig
    const src_path = try std.fs.path.join(allocator, &.{ tmp_root, "src/root.zig" });
    defer allocator.free(src_path);
    const src = try readFileContent(allocator, test_io, src_path);
    defer allocator.free(src);

    try std.testing.expect(std.mem.indexOf(u8, build_zig, "const std = @import(\"std\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig, "b.addModule(\"demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig, "src/root.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig, "b.addTest") != null);

    // build.zig.zon markers
    try std.testing.expect(std.mem.indexOf(u8, build_zon, ".name = .demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zon, ".version = \"1.2.3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zon, ".fingerprint = 0x000000000000abcd") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zon, "\"src\",") != null);

    // src/root.zig markers
    try std.testing.expect(std.mem.indexOf(u8, src, "const std = @import(\"std\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const LIMIT: u32 = 42;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn add(a: u32, b: u32) u32 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "return (a + b);") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "test \"add sums\" {") != null);
}
