//! ingest — Cargo.toml parsing and crate source resolution for frontend pipeline.
//!
//! Inspects Cargo.toml in a crate directory to extract package metadata
//! (name, edition, version) and locate the root source file (e.g. `src/lib.rs`, `lib.rs`, `src/main.rs`).

const std = @import("std");

pub const Manifest = struct {
    name: []const u8,
    edition: []const u8 = "2021",
    version: ?[]const u8 = null,
    root_path: []const u8,
    is_bin: bool = false,
};

pub const IngestError = error{
    CargoManifestNotFound,
    CargoManifestMissingPackageSection,
    CargoManifestMissingName,
    RootSourceNotFound,
    OutOfMemory,
    DiskQuota,
    FileTooBig,
    DeviceBusy,
    Locked,
    AccessDenied,
    SystemResources,
    OperationAborted,
    Unexpected,
};

/// Read a file into memory with allocation.
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

/// Parse Cargo.toml text content to extract package metadata and configured root path.
pub fn parseManifestContent(
    allocator: std.mem.Allocator,
    content: []const u8,
) !struct { name: []const u8, edition: []const u8, version: ?[]const u8, lib_path: ?[]const u8, bin_path: ?[]const u8 } {
    var it = std.mem.splitScalar(u8, content, '\n');
    var current_section: enum { none, package, lib, bin } = .none;
    var name: ?[]const u8 = null;
    var edition: []const u8 = "2021";
    var version: ?[]const u8 = null;
    var lib_path: ?[]const u8 = null;
    var bin_path: ?[]const u8 = null;

    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            const section_name = std.mem.trim(u8, line, "[] \t");
            if (std.mem.eql(u8, section_name, "package")) {
                current_section = .package;
            } else if (std.mem.eql(u8, section_name, "lib")) {
                current_section = .lib;
            } else if (std.mem.eql(u8, section_name, "bin") or std.mem.startsWith(u8, section_name, "bin.")) {
                current_section = .bin;
            } else {
                current_section = .none;
            }
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val_raw = std.mem.trim(u8, line[eq + 1 ..], " \t");

        // Extract string literal value if quoted
        var val: []const u8 = val_raw;
        if (std.mem.startsWith(u8, val, "\"")) {
            var val_it = std.mem.splitScalar(u8, val, '"');
            _ = val_it.next(); // skip before opening quote
            if (val_it.next()) |unquoted| {
                val = unquoted;
            }
        }

        switch (current_section) {
            .package => {
                if (std.mem.eql(u8, key, "name") and name == null) {
                    name = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "edition")) {
                    edition = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "version") and version == null) {
                    version = try allocator.dupe(u8, val);
                }
            },
            .lib => {
                if (std.mem.eql(u8, key, "path") and lib_path == null) {
                    lib_path = try allocator.dupe(u8, val);
                }
            },
            .bin => {
                if (std.mem.eql(u8, key, "path") and bin_path == null) {
                    bin_path = try allocator.dupe(u8, val);
                }
            },
            .none => {},
        }
    }

    if (name == null) return error.CargoManifestMissingName;

    return .{
        .name = name.?,
        .edition = edition,
        .version = version,
        .lib_path = lib_path,
        .bin_path = bin_path,
    };
}

/// Inspect `Cargo.toml` in crate dir to extract package name, edition, and find root source file.
pub fn loadCrateManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    crate_dir: []const u8,
) !Manifest {
    const cargo_path = try std.fs.path.join(allocator, &.{ crate_dir, "Cargo.toml" });
    defer allocator.free(cargo_path);

    const manifest_bytes = readFileAlloc(allocator, io, cargo_path) catch {
        // Cargo.toml not found, attempt fallback based on directory name
        const dir_name = std.fs.path.basename(crate_dir);
        if (dir_name.len == 0) return error.CargoManifestNotFound;
        const root_path = try resolveFallbackRoot(allocator, io, crate_dir) orelse return error.RootSourceNotFound;
        const is_bin = std.mem.endsWith(u8, root_path, "main.rs");
        return .{
            .name = try allocator.dupe(u8, dir_name),
            .edition = "2021",
            .version = null,
            .root_path = root_path,
            .is_bin = is_bin,
        };
    };
    defer allocator.free(manifest_bytes);

    const parsed = try parseManifestContent(allocator, manifest_bytes);

    // 1. Explicit lib path
    if (parsed.lib_path) |p| {
        const full_path = try std.fs.path.join(allocator, &.{ crate_dir, p });
        if (fileExists(io, full_path)) {
            return .{
                .name = parsed.name,
                .edition = parsed.edition,
                .version = parsed.version,
                .root_path = full_path,
                .is_bin = false,
            };
        }
    }

    // 2. Explicit bin path
    if (parsed.bin_path) |p| {
        const full_path = try std.fs.path.join(allocator, &.{ crate_dir, p });
        if (fileExists(io, full_path)) {
            return .{
                .name = parsed.name,
                .edition = parsed.edition,
                .version = parsed.version,
                .root_path = full_path,
                .is_bin = true,
            };
        }
    }

    // 3. Fallback candidates
    if (try resolveFallbackRoot(allocator, io, crate_dir)) |root_path| {
        const is_bin = std.mem.endsWith(u8, root_path, "main.rs");
        return .{
            .name = parsed.name,
            .edition = parsed.edition,
            .version = parsed.version,
            .root_path = root_path,
            .is_bin = is_bin,
        };
    }

    return error.RootSourceNotFound;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd();
    const f = dir.openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

fn resolveFallbackRoot(allocator: std.mem.Allocator, io: std.Io, crate_dir: []const u8) !?[]const u8 {
    const candidates = [_][]const u8{
        "src/lib.rs",
        "lib.rs",
        "src/main.rs",
        "main.rs",
    };
    for (candidates) |c| {
        const joined = try std.fs.path.join(allocator, &.{ crate_dir, c });
        if (fileExists(io, joined)) {
            return joined;
        }
        allocator.free(joined);
    }
    return null;
}

test "parseManifestContent standard package" {
    const testing = std.testing;
    const toml =
        \\[package]
        \\name = "my_crate"
        \\version = "0.1.0"
        \\edition = "2024"
        \\
        \\[dependencies]
        \\serde = "1.0"
    ;

    const parsed = try parseManifestContent(testing.allocator, toml);
    defer testing.allocator.free(parsed.name);
    defer testing.allocator.free(parsed.edition);
    defer if (parsed.version) |v| testing.allocator.free(v);

    try testing.expectEqualStrings("my_crate", parsed.name);
    try testing.expectEqualStrings("2024", parsed.edition);
    try testing.expectEqualStrings("0.1.0", parsed.version.?);
}

test "parseManifestContent with custom lib and bin" {
    const testing = std.testing;
    const toml =
        \\[package]
        \\name = "cli_tool"
        \\edition = "2021"
        \\
        \\[lib]
        \\path = "custom/lib.rs"
        \\
        \\[[bin]]
        \\name = "cli"
        \\path = "custom/main.rs"
    ;

    const parsed = try parseManifestContent(testing.allocator, toml);
    defer testing.allocator.free(parsed.name);
    defer testing.allocator.free(parsed.edition);
    defer if (parsed.lib_path) |lp| testing.allocator.free(lp);
    defer if (parsed.bin_path) |bp| testing.allocator.free(bp);

    try testing.expectEqualStrings("cli_tool", parsed.name);
    try testing.expectEqualStrings("custom/lib.rs", parsed.lib_path.?);
    try testing.expectEqualStrings("custom/main.rs", parsed.bin_path.?);
}
