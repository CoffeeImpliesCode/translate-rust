//! translate_rust.model.package — multi-file package generator.
//! Translates a CrateGraph + Bodies into a complete, standalone Zig package
//! directory ("r2z-<crate>/") containing build.zig, build.zig.zon, src/root.zig,
//! and submodule files src/<module>.zig.

const std = @import("std");
const spine = @import("spine.zig");
const graph = @import("graph.zig");
const bodies = @import("bodies.zig");
const json = @import("json.zig");
const emit = @import("emit.zig");

/// A single generated source or build file in a package.
pub const GeneratedFile = struct {
    path: []const u8, // relative path e.g. "build.zig", "build.zig.zon", "src/root.zig", "src/util.zig"
    content: []const u8, // formatted Zig source text
};

/// A generated, standalone Zig package directory structure.
pub const GeneratedPackage = struct {
    crate_name: []const u8,
    package_name: []const u8, // "r2z-<crate_name>"
    files: []const GeneratedFile,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GeneratedPackage) void {
        for (self.files) |f| {
            self.allocator.free(f.path);
            self.allocator.free(f.content);
        }
        self.allocator.free(self.files);
        self.allocator.free(self.crate_name);
        self.allocator.free(self.package_name);
        self.* = undefined;
    }

    /// Write all generated package files to disk at `dest_dir_path` using std.Io.
    pub fn writeToDisk(self: *const GeneratedPackage, io: std.Io, dest_dir_path: []const u8) !void {
        var dir = std.Io.Dir.cwd();
        try dir.createDirPath(io, dest_dir_path);

        for (self.files) |f| {
            const full_path = try std.fs.path.join(self.allocator, &.{ dest_dir_path, f.path });
            defer self.allocator.free(full_path);

            if (std.fs.path.dirname(full_path)) |parent_dir| {
                try dir.createDirPath(io, parent_dir);
            }

            const file = try dir.createFile(io, full_path, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, f.content);
        }
    }
};

/// Generates build.zig for the package.
fn generateBuildZig(allocator: std.mem.Allocator, package_name: []const u8) ![]u8 {
    const raw = try std.fmt.allocPrint(
        allocator,
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const target = b.standardTargetOptions(.{{}});
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\
        \\    const mod = b.addModule("{s}", .{{
        \\        .root_source_file = b.path("src/root.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    }});
        \\
        \\    const lib = b.addLibrary(.{{
        \\        .name = "{s}",
        \\        .root_module = mod,
        \\        .linkage = .static,
        \\    }});
        \\    b.installArtifact(lib);
        \\
        \\    const main_tests = b.addTest(.{{
        \\        .root_module = mod,
        \\    }});
        \\    const run_main_tests = b.addRunArtifact(main_tests);
        \\
        \\    const test_step = b.step("test", "Run library tests");
        \\    test_step.dependOn(&run_main_tests.step);
        \\}}
        \\
    ,
        .{ package_name, package_name },
    );
    defer allocator.free(raw);
    return emit.formatZig(allocator, raw);
}

/// Generates build.zig.zon manifest for the package.
fn generateBuildZigZon(allocator: std.mem.Allocator, package_name: []const u8) ![]u8 {
    const zon_name = try allocator.dupe(u8, package_name);
    defer allocator.free(zon_name);
    for (zon_name) |*c| {
        if (c.* == '-') c.* = '_';
    }

    const fingerprint = std.hash.Wyhash.hash(0, package_name);

    const raw = try std.fmt.allocPrint(
        allocator,
        \\.{{
        \\    .name = .{s},
        \\    .version = "0.1.0",
        \\    .fingerprint = 0x{x},
        \\    .minimum_zig_version = "0.16.0",
        \\    .paths = .{{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\    }},
        \\}}
        \\
    ,
        .{ zon_name, fingerprint },
    );
    defer allocator.free(raw);
    return emit.formatZig(allocator, raw);
}

/// Helper to determine if a module belongs to the given crate root hierarchy.
fn isModuleInCrate(g: *const graph.CrateGraph, mod_id: spine.EntityId, root_id: spine.EntityId) bool {
    if (mod_id == root_id) return true;
    var cur_id = mod_id;
    while (g.module(cur_id)) |m| {
        if (m.parent) |p| {
            if (p == root_id) return true;
            if (p == cur_id) break; // avoid potential cycles
            cur_id = p;
        } else {
            break;
        }
    }
    return false;
}

/// Generate a complete standalone Zig package from a CrateGraph and optional Bodies.
pub fn generatePackage(
    allocator: std.mem.Allocator,
    g: *const graph.CrateGraph,
    b: ?*const bodies.Bodies,
    crate_idx: usize,
) !GeneratedPackage {
    if (crate_idx >= g.crates.items.len) return error.CrateNotFound;
    const c = g.crates.items[crate_idx];

    const crate_name = try allocator.dupe(u8, c.name);
    errdefer allocator.free(crate_name);

    const package_name = try std.fmt.allocPrint(allocator, "r2z-{s}", .{c.name});
    errdefer allocator.free(package_name);

    var file_list: std.ArrayListUnmanaged(GeneratedFile) = .empty;
    errdefer {
        for (file_list.items) |f| {
            allocator.free(f.path);
            allocator.free(f.content);
        }
        file_list.deinit(allocator);
    }

    // 1. build.zig
    const build_zig_content = try generateBuildZig(allocator, package_name);
    try file_list.append(allocator, .{
        .path = try allocator.dupe(u8, "build.zig"),
        .content = build_zig_content,
    });

    // 2. build.zig.zon
    const build_zig_zon_content = try generateBuildZigZon(allocator, package_name);
    try file_list.append(allocator, .{
        .path = try allocator.dupe(u8, "build.zig.zon"),
        .content = build_zig_zon_content,
    });

    // 3. src/root.zig (crate root module)
    const raw_root_source = try emit.emitModuleFile(allocator, g, b, c.root);
    defer allocator.free(raw_root_source);
    const root_content = try emit.formatZig(allocator, raw_root_source);
    try file_list.append(allocator, .{
        .path = try allocator.dupe(u8, "src/root.zig"),
        .content = root_content,
    });

    // 4. Submodules (kind == .file or .directory) belonging to this crate
    for (g.modules.items) |m| {
        if (m.id == c.root) continue;
        if (m.kind != .file and m.kind != .directory) continue;
        if (!isModuleInCrate(g, m.id, c.root)) continue;

        const raw_mod_source = try emit.emitModuleFile(allocator, g, b, m.id);
        defer allocator.free(raw_mod_source);
        const mod_content = try emit.formatZig(allocator, raw_mod_source);

        const mod_path = try std.fmt.allocPrint(allocator, "src/{s}.zig", .{m.name});
        try file_list.append(allocator, .{
            .path = mod_path,
            .content = mod_content,
        });
    }

    return .{
        .crate_name = crate_name,
        .package_name = package_name,
        .files = try file_list.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

fn readFixture(allocator: std.mem.Allocator, test_io: std.Io, path: []const u8) ![]const u8 {
    var io_buf: [4096]u8 = undefined;
    var dir = std.Io.Dir.cwd();
    const file = try dir.openFile(test_io, path, .{});
    defer file.close(test_io);
    var reader = file.reader(test_io, &io_buf);
    return reader.interface.allocRemaining(allocator, .limited(1 << 30));
}

test "generatePackage: mini fixture generates multi-file package with imports and build files" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;

    const mini_json_bytes = try readFixture(allocator, test_io, "test/mini.json");
    defer allocator.free(mini_json_bytes);

    var g = try json.parse(allocator, mini_json_bytes);
    defer g.deinit();

    var pkg = try generatePackage(allocator, &g, null, 0);
    defer pkg.deinit();

    try std.testing.expectEqualStrings("mini", pkg.crate_name);
    try std.testing.expectEqualStrings("r2z-mini", pkg.package_name);
    try std.testing.expect(std.mem.indexOf(u8, pkg.files[1].content, "r2z_mini") != null);

    // Verify files generated
    try std.testing.expectEqualStrings("build.zig", pkg.files[0].path);
    try std.testing.expectEqualStrings("build.zig.zon", pkg.files[1].path);
    try std.testing.expectEqualStrings("src/root.zig", pkg.files[2].path);
    try std.testing.expectEqualStrings("src/util.zig", pkg.files[3].path);

    try std.testing.expect(std.mem.indexOf(u8, pkg.files[1].content, "0.16.0") != null);

    // Verify build.zig content
    try std.testing.expect(std.mem.indexOf(u8, pkg.files[0].content, "b.addModule(\"r2z-mini\"") != null);

    // Verify src/root.zig imports util.zig and emits root items
    try std.testing.expect(
        std.mem.indexOf(u8, pkg.files[2].content, "pub const util = @import(\"util.zig\");") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, pkg.files[2].content, "pub const Point = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkg.files[2].content, "pub const Shape = enum(u8) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkg.files[2].content, "pub fn area()") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkg.files[2].content, "pub const helper = helper;") != null);

    // Verify src/util.zig contains util submodule's items
    try std.testing.expect(std.mem.indexOf(u8, pkg.files[3].content, "pub fn helper()") != null);
}

test "generatePackage: fnv fixture generates single-module package with body lowering" {
    const test_io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fnv_json_bytes = try readFixture(allocator, test_io, "test/fnv.json");
    var parsed = try json.parseFull(allocator, fnv_json_bytes);
    const pkg = try generatePackage(allocator, &parsed.graph, &parsed.bodies, 0);
    try std.testing.expectEqualStrings("fnv", pkg.crate_name);
    try std.testing.expectEqualStrings("r2z-fnv", pkg.package_name);
    try std.testing.expectEqual(@as(usize, 3), pkg.files.len);

    // Verify files generated
    try std.testing.expectEqualStrings("build.zig", pkg.files[0].path);
    try std.testing.expectEqualStrings("build.zig.zon", pkg.files[1].path);
    try std.testing.expectEqualStrings("src/root.zig", pkg.files[2].path);

    // Verify src/root.zig contains fnv hash function and constants
    try std.testing.expect(std.mem.indexOf(u8, pkg.files[2].content, "pub fn fnv1a_hash") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkg.files[2].content, "const FNV_OFFSET_BASIS:") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkg.files[2].content, "const FNV_PRIME:") != null);
}

test "GeneratedPackage.writeToDisk writes files safely" {
    const test_io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const mini_json_bytes = try readFixture(allocator, test_io, "test/mini.json");
    var g = try json.parse(allocator, mini_json_bytes);
    const pkg = try generatePackage(allocator, &g, null, 0);

    const test_dest = "zig-out/test-package-mini";
    try pkg.writeToDisk(test_io, test_dest);

    // Verify written files exist and match content
    var io_buf: [4096]u8 = undefined;
    var dir = std.Io.Dir.cwd();
    for (pkg.files) |f| {
        const full_path = try std.fs.path.join(allocator, &.{ test_dest, f.path });
        defer allocator.free(full_path);

        const file = try dir.openFile(test_io, full_path, .{});
        defer file.close(test_io);

        var reader = file.reader(test_io, &io_buf);
        const disk_content = try reader.interface.allocRemaining(allocator, .limited(1 << 30));
        defer allocator.free(disk_content);

        try std.testing.expectEqualStrings(f.content, disk_content);
    }
}
