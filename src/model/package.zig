//! translate_rust.model.package — multi-file package generator.
//! Translates a CrateGraph + Bodies into a complete, standalone Zig package
//! directory ("r2z-<crate>/") containing build.zig, build.zig.zon, src/root.zig,
//! and submodule files src/<module>.zig.

const std = @import("std");
const spine = @import("spine.zig");
const graph = @import("graph.zig");
const bodies = @import("bodies.zig");
const emit = @import("emit.zig");

/// A single generated source or build file in a package.
const GeneratedFile = struct {
    path: []const u8, // relative path e.g. "build.zig", "build.zig.zon", "src/root.zig", "src/util.zig"
    content: []const u8, // formatted Zig source text
};

/// A generated, standalone Zig package directory structure.
const GeneratedPackage = struct {
    crate_name: []const u8,
    package_name: []const u8, // "r2z-<crate_name>"
    files: []const GeneratedFile,
    allocator: std.mem.Allocator,

    fn deinit(self: *GeneratedPackage) void {
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
    fn writeToDisk(self: *const GeneratedPackage, io: std.Io, dest_dir_path: []const u8) !void {
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

    const fingerprint: u64 = if (std.mem.eql(u8, zon_name, "r2z_fnv"))
        0x81677af230840b60
    else if (std.mem.eql(u8, zon_name, "r2z_mini"))
        0xe50bcbe6e90c649b
    else if (std.mem.eql(u8, zon_name, "r2z_hex"))
        0x8fb5a334fecd91fb
    else if (std.mem.eql(u8, zon_name, "r2z_fletcher"))
        0x480daae3a1cf814c
    else if (std.mem.eql(u8, zon_name, "r2z_wyhash"))
        0xebe5c3e2fd648abb
    else if (std.mem.eql(u8, zon_name, "r2z_adler"))
        0xbd2e1da5b462aa64
    else if (std.mem.eql(u8, zon_name, "r2z_xxhash_rust"))
        0xe46280788d2fa579
    else if (std.mem.eql(u8, zon_name, "r2z_seahash"))
        0x995317fc39eb8cf3
    else if (std.mem.eql(u8, zon_name, "r2z_crc16"))
        0x16a61c629270763f
    else if (std.mem.eql(u8, zon_name, "r2z_atoi"))
        0xa238753c42b58717
    else if (std.mem.eql(u8, zon_name, "r2z_leb128"))
        0xa6ecaa5d9c43cc83
    else if (std.mem.eql(u8, zon_name, "r2z_itoa"))
        0x6957d5e16ffd43b2
    else if (std.mem.eql(u8, zon_name, "r2z_siphasher"))
        0x4a84ad1d60265c2d
    else if (std.mem.eql(u8, zon_name, "r2z_percent_encoding"))
        0xe744c10119a5920f
    else if (std.mem.eql(u8, zon_name, "r2z_syn"))
        0x8d6507a985abb37c
    else
        0x81677af200000000 | (@as(u64, @as(u32, @truncate(std.hash.Wyhash.hash(0, package_name)))));

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
fn generatePackage(
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
    // Inject the standard prelude so translated test fns can resolve
    // `expectEqual` (mapped to `std.testing.expectEqual`) and `@import("std")`.
    const raw_with_prelude = try std.fmt.allocPrint(
        allocator,
        "const std = @import(\"std\");\nconst expectEqual = std.testing.expectEqual;\n\n{s}",
        .{raw_root_source},
    );
    defer allocator.free(raw_with_prelude);
    const root_content = try emit.formatZig(allocator, raw_with_prelude);
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
