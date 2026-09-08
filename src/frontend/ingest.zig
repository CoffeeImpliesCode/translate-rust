//! ingest — Cargo.toml parsing and crate source resolution for frontend pipeline.
//!
//! Inspects Cargo.toml in a crate directory to extract package metadata
//! (name, edition, version) and locate the root source file (e.g. `src/lib.rs`, `lib.rs`, `src/main.rs`).

const std = @import("std");
const serde = @import("serde");

pub const Dependency = struct {
    name: []const u8,
    package: ?[]const u8 = null,
    version: ?[]const u8 = null,
    path: ?[]const u8 = null,
    git: ?[]const u8 = null,
    optional: bool = false,
    default_features: ?bool = null,
    features: []const []const u8 = &.{},
};
pub const Feature = struct {
    name: []const u8,
    members: []const []const u8,
};

pub const Manifest = struct {
    name: []const u8,
    edition: []const u8 = "2021",
    version: ?[]const u8 = null,
    root_path: []const u8,
    is_bin: bool = false,
    dependencies: []const Dependency = &.{},
    dev_dependencies: []const Dependency = &.{},
    features: []const Feature = &.{},
};

pub const ParsedManifest = struct {
    name: []const u8,
    edition: []const u8,
    version: ?[]const u8,
    lib_path: ?[]const u8,
    bin_path: ?[]const u8,
    dependencies: []const Dependency,
    dev_dependencies: []const Dependency,
    features: []const Feature,
};

pub const IngestError = error{
    CargoManifestNotFound,
    CargoManifestMissingPackageSection,
    CargoManifestMissingName,
    CargoManifestConfiguredRootSourceNotFound,
    CargoManifestMultipleBinsUnsupported,
    CargoManifestUnsupportedDependencySection,
    CargoManifestUnsupportedDependencySource,
    CargoManifestUnsupportedDependencyField,
    CargoManifestWorkspaceInheritanceUnsupported,
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

const supported_dependency_fields = [_][]const u8{
    "package",
    "version",
    "path",
    "git",
    "optional",
    "default-features",
    "features",
};

const unsupported_dependency_sources = [_][]const u8{
    "branch",
    "tag",
    "rev",
    "registry",
};

fn isSupportedDependencyField(key: []const u8) bool {
    for (supported_dependency_fields) |supported| {
        if (std.mem.eql(u8, key, supported)) return true;
    }
    return false;
}

fn isUnsupportedDependencySource(key: []const u8) bool {
    for (unsupported_dependency_sources) |unsupported| {
        if (std.mem.eql(u8, key, unsupported)) return true;
    }
    return false;
}

fn rejectWorkspaceValue(value: serde.toml.Value) !void {
    if (value != .table) return;
    const table = value.table;
    if (table.get("workspace")) |_| {
        _ = try tomlBool(&table, "workspace");
        return error.CargoManifestWorkspaceInheritanceUnsupported;
    }
}

fn rejectUnsupportedDependencySections(root: *const serde.toml.Table) !void {
    for ([_][]const u8{ "build-dependencies", "target" }) |key| {
        if (root.get(key)) |value| {
            if (std.mem.eql(u8, key, "target")) _ = try tomlTable(value);
            return error.CargoManifestUnsupportedDependencySection;
        }
    }
    if (root.get("workspace")) |_| {
        return error.CargoManifestWorkspaceInheritanceUnsupported;
    }
}

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

fn freeDependency(allocator: std.mem.Allocator, dependency: Dependency) void {
    allocator.free(dependency.name);
    if (dependency.package) |package| allocator.free(package);
    if (dependency.version) |version| allocator.free(version);
    if (dependency.path) |path| allocator.free(path);
    if (dependency.git) |git| allocator.free(git);
    for (dependency.features) |feature| allocator.free(feature);
    if (dependency.features.len != 0) allocator.free(dependency.features);
}

fn freeDependencies(allocator: std.mem.Allocator, dependencies: []const Dependency) void {
    if (dependencies.len == 0) return;
    for (dependencies) |dependency| freeDependency(allocator, dependency);
    allocator.free(dependencies);
}

fn freeFeature(allocator: std.mem.Allocator, feature: Feature) void {
    allocator.free(feature.name);
    for (feature.members) |member| allocator.free(member);
    if (feature.members.len != 0) allocator.free(feature.members);
}

fn freeFeatures(allocator: std.mem.Allocator, features: []const Feature) void {
    if (features.len == 0) return;
    for (features) |feature| freeFeature(allocator, feature);
    allocator.free(features);
}

fn deinitParsedManifest(allocator: std.mem.Allocator, parsed: ParsedManifest) void {
    allocator.free(parsed.name);
    allocator.free(parsed.edition);
    if (parsed.version) |version| allocator.free(version);
    if (parsed.lib_path) |path| allocator.free(path);
    if (parsed.bin_path) |path| allocator.free(path);
    freeDependencies(allocator, parsed.dependencies);
    freeDependencies(allocator, parsed.dev_dependencies);
    freeFeatures(allocator, parsed.features);
}

fn deinitTomlTable(allocator: std.mem.Allocator, table: *serde.toml.Table) void {
    var iterator = table.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    table.deinit(allocator);
}

fn tomlTable(value: serde.toml.Value) !serde.toml.Table {
    return switch (value) {
        .table => |table| table,
        else => error.BadWireFormat,
    };
}

fn tomlString(table: *const serde.toml.Table, key: []const u8) !?[]const u8 {
    const value = table.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => error.BadWireFormat,
    };
}

fn tomlBool(table: *const serde.toml.Table, key: []const u8) !?bool {
    const value = table.get(key) orelse return null;
    return switch (value) {
        .boolean => |boolean| boolean,
        else => error.BadWireFormat,
    };
}

fn parseSingleTargetPath(value: serde.toml.Value) !?[]const u8 {
    switch (value) {
        .table => |table| {
            return try tomlString(&table, "path");
        },
        .array => |array| {
            if (array.len == 0) return error.BadWireFormat;
            if (array.len > 1) return error.CargoManifestMultipleBinsUnsupported;
            return switch (array[0]) {
                .table => |table| try tomlString(&table, "path"),
                else => error.BadWireFormat,
            };
        },
        else => return error.BadWireFormat,
    }
}

fn parseDependencyValue(
    allocator: std.mem.Allocator,
    name_text: []const u8,
    value: serde.toml.Value,
) !Dependency {
    var dependency: Dependency = .{
        .name = try allocator.dupe(u8, name_text),
    };
    errdefer freeDependency(allocator, dependency);
    switch (value) {
        .string => |version| dependency.version = try allocator.dupe(u8, version),
        .table => |dep_table| {
            try rejectWorkspaceValue(value);
            var fields = dep_table.iterator();
            while (fields.next()) |entry| {
                if (isUnsupportedDependencySource(entry.key_ptr.*)) {
                    return error.CargoManifestUnsupportedDependencySource;
                }
                if (!isSupportedDependencyField(entry.key_ptr.*)) {
                    return error.CargoManifestUnsupportedDependencyField;
                }
            }
            if (try tomlString(&dep_table, "package")) |package| {
                dependency.package = try allocator.dupe(u8, package);
            }
            if (try tomlString(&dep_table, "version")) |version| {
                dependency.version = try allocator.dupe(u8, version);
            }
            if (try tomlString(&dep_table, "path")) |path| {
                dependency.path = try allocator.dupe(u8, path);
            }
            if (try tomlString(&dep_table, "git")) |git| {
                dependency.git = try allocator.dupe(u8, git);
            }
            dependency.optional = (try tomlBool(&dep_table, "optional")) orelse false;
            dependency.default_features = try tomlBool(&dep_table, "default-features");
            if (dep_table.get("features")) |features_value| {
                const feature_values = switch (features_value) {
                    .array => |array| array,
                    else => return error.BadWireFormat,
                };
                var features_list: std.ArrayListUnmanaged([]const u8) = .empty;
                errdefer {
                    for (features_list.items) |feature| allocator.free(feature);
                    features_list.deinit(allocator);
                }
                for (feature_values) |feature_value| {
                    const feature_text = switch (feature_value) {
                        .string => |string| string,
                        else => return error.BadWireFormat,
                    };
                    const feature = try allocator.dupe(u8, feature_text);
                    features_list.append(allocator, feature) catch |err| {
                        allocator.free(feature);
                        return err;
                    };
                }
                if (features_list.items.len != 0) {
                    dependency.features = try features_list.toOwnedSlice(allocator);
                }
            }
        },
        else => return error.BadWireFormat,
    }
    return dependency;
}

fn parseDependencies(
    allocator: std.mem.Allocator,
    root: *const serde.toml.Table,
    section_name: []const u8,
) ![]const Dependency {
    const value = root.get(section_name) orelse return &.{};
    const table = try tomlTable(value);
    var list: std.ArrayListUnmanaged(Dependency) = .empty;
    errdefer {
        for (list.items) |dependency| freeDependency(allocator, dependency);
        list.deinit(allocator);
    }

    var iterator = table.iterator();
    while (iterator.next()) |entry| {
        const dependency = try parseDependencyValue(allocator, entry.key_ptr.*, entry.value_ptr.*);
        list.append(allocator, dependency) catch |err| {
            freeDependency(allocator, dependency);
            return err;
        };
    }
    if (list.items.len == 0) return &.{};
    return list.toOwnedSlice(allocator);
}

fn parseFeatureValue(
    allocator: std.mem.Allocator,
    name_text: []const u8,
    value: serde.toml.Value,
) !Feature {
    const name = try allocator.dupe(u8, name_text);
    errdefer allocator.free(name);
    const values = switch (value) {
        .array => |array| array,
        else => return error.BadWireFormat,
    };

    var members_list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (members_list.items) |member| allocator.free(member);
        members_list.deinit(allocator);
    }
    for (values) |member_value| {
        const member_text = switch (member_value) {
            .string => |string| string,
            else => return error.BadWireFormat,
        };
        const member = try allocator.dupe(u8, member_text);
        members_list.append(allocator, member) catch |err| {
            allocator.free(member);
            return err;
        };
    }

    const members = if (members_list.items.len == 0)
        &.{}
    else
        try members_list.toOwnedSlice(allocator);
    return .{
        .name = name,
        .members = members,
    };
}

fn parseFeatures(
    allocator: std.mem.Allocator,
    root: *const serde.toml.Table,
) ![]const Feature {
    const value = root.get("features") orelse return &.{};
    const table = try tomlTable(value);
    var list: std.ArrayListUnmanaged(Feature) = .empty;
    errdefer {
        for (list.items) |feature| freeFeature(allocator, feature);
        list.deinit(allocator);
    }

    var iterator = table.iterator();
    while (iterator.next()) |entry| {
        const feature = try parseFeatureValue(allocator, entry.key_ptr.*, entry.value_ptr.*);
        list.append(allocator, feature) catch |err| {
            freeFeature(allocator, feature);
            return err;
        };
    }
    if (list.items.len == 0) return &.{};
    return list.toOwnedSlice(allocator);
}

/// Parse Cargo.toml with serde.zig's TOML parser.
pub fn parseManifestContent(
    allocator: std.mem.Allocator,
    content: []const u8,
) !ParsedManifest {
    var root = try serde.toml.parse(allocator, content);
    defer deinitTomlTable(allocator, &root);

    try rejectUnsupportedDependencySections(&root);
    const package = try tomlTable(root.get("package") orelse return error.CargoManifestMissingPackageSection);
    var package_fields = package.iterator();
    while (package_fields.next()) |entry| {
        try rejectWorkspaceValue(entry.value_ptr.*);
    }
    const name_text = (try tomlString(&package, "name")) orelse return error.CargoManifestMissingName;
    const name = try allocator.dupe(u8, name_text);
    errdefer allocator.free(name);
    const edition = try allocator.dupe(u8, (try tomlString(&package, "edition")) orelse "2021");
    errdefer allocator.free(edition);
    const version = if (try tomlString(&package, "version")) |version_text|
        try allocator.dupe(u8, version_text)
    else
        null;
    errdefer if (version) |value| allocator.free(value);

    const lib_path: ?[]const u8 = try (if (root.get("lib")) |value| switch (value) {
        .table => |table| if (try tomlString(&table, "path")) |path|
            try allocator.dupe(u8, path)
        else
            null,
        else => error.BadWireFormat,
    } else null);
    errdefer if (lib_path) |value| allocator.free(value);

    const bin_path = if (root.get("bin")) |value|
        if (try parseSingleTargetPath(value)) |path|
            try allocator.dupe(u8, path)
        else
            null
    else
        null;
    errdefer if (bin_path) |value| allocator.free(value);

    const dependencies = try parseDependencies(allocator, &root, "dependencies");
    errdefer freeDependencies(allocator, dependencies);
    const dev_dependencies = try parseDependencies(allocator, &root, "dev-dependencies");
    errdefer freeDependencies(allocator, dev_dependencies);
    const features = try parseFeatures(allocator, &root);
    errdefer freeFeatures(allocator, features);

    return .{
        .name = name,
        .edition = edition,
        .version = version,
        .lib_path = lib_path,
        .bin_path = bin_path,
        .dependencies = dependencies,
        .dev_dependencies = dev_dependencies,
        .features = features,
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

    const manifest_bytes = readFileAlloc(allocator, io, cargo_path) catch |err| {
        if (err != error.FileNotFound) return err;
        const dir_name = std.fs.path.basename(crate_dir);
        if (dir_name.len == 0) return error.CargoManifestNotFound;

        const root_path = try resolveFallbackRoot(allocator, io, crate_dir) orelse return error.RootSourceNotFound;
        const is_bin = std.mem.endsWith(u8, root_path, "main.rs");
        const name = allocator.dupe(u8, dir_name) catch |dupe_err| {
            allocator.free(root_path);
            return dupe_err;
        };
        return .{
            .name = name,
            .edition = "2021",
            .version = null,
            .root_path = root_path,
            .is_bin = is_bin,
            .dependencies = &.{},
            .dev_dependencies = &.{},
            .features = &.{},
        };
    };
    defer allocator.free(manifest_bytes);

    const parsed = try parseManifestContent(allocator, manifest_bytes);
    errdefer deinitParsedManifest(allocator, parsed);

    var explicit_lib: ?[]const u8 = null;
    var explicit_bin: ?[]const u8 = null;
    errdefer if (explicit_lib) |path| allocator.free(path);
    errdefer if (explicit_bin) |path| allocator.free(path);

    if (parsed.lib_path) |path| {
        const full_path = try std.fs.path.join(allocator, &.{ crate_dir, path });
        explicit_lib = full_path;
        if (!(try fileExists(io, full_path))) {
            return error.CargoManifestConfiguredRootSourceNotFound;
        }
    }

    if (parsed.bin_path) |path| {
        const full_path = try std.fs.path.join(allocator, &.{ crate_dir, path });
        explicit_bin = full_path;
        if (!(try fileExists(io, full_path))) {
            return error.CargoManifestConfiguredRootSourceNotFound;
        }
    }

    if (explicit_lib) |root_path| {
        if (explicit_bin) |path| allocator.free(path);
        if (parsed.lib_path) |path| allocator.free(path);
        if (parsed.bin_path) |path| allocator.free(path);
        return .{
            .name = parsed.name,
            .edition = parsed.edition,
            .version = parsed.version,
            .root_path = root_path,
            .is_bin = false,
            .dependencies = parsed.dependencies,
            .dev_dependencies = parsed.dev_dependencies,
            .features = parsed.features,
        };
    }

    if (explicit_bin) |root_path| {
        if (parsed.lib_path) |path| allocator.free(path);
        if (parsed.bin_path) |path| allocator.free(path);
        return .{
            .name = parsed.name,
            .edition = parsed.edition,
            .version = parsed.version,
            .root_path = root_path,
            .is_bin = true,
            .dependencies = parsed.dependencies,
            .dev_dependencies = parsed.dev_dependencies,
            .features = parsed.features,
        };
    }

    if (try resolveFallbackRoot(allocator, io, crate_dir)) |root_path| {
        const is_bin = std.mem.endsWith(u8, root_path, "main.rs");
        if (parsed.lib_path) |path| allocator.free(path);
        if (parsed.bin_path) |path| allocator.free(path);
        return .{
            .name = parsed.name,
            .edition = parsed.edition,
            .version = parsed.version,
            .root_path = root_path,
            .is_bin = is_bin,
            .dependencies = parsed.dependencies,
            .dev_dependencies = parsed.dev_dependencies,
            .features = parsed.features,
        };
    }

    return error.RootSourceNotFound;
}

fn fileExists(io: std.Io, path: []const u8) !bool {
    var dir = std.Io.Dir.cwd();
    const f = dir.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
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
    for (candidates) |candidate| {
        const joined = try std.fs.path.join(allocator, &.{ crate_dir, candidate });
        const exists = fileExists(io, joined) catch |err| {
            allocator.free(joined);
            return err;
        };
        if (exists) {
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
    defer freeDependencies(testing.allocator, parsed.dependencies);

    try testing.expectEqualStrings("my_crate", parsed.name);
    try testing.expectEqualStrings("2024", parsed.edition);
    try testing.expectEqualStrings("0.1.0", parsed.version.?);
    try testing.expectEqual(@as(usize, 1), parsed.dependencies.len);
    try testing.expectEqualStrings("serde", parsed.dependencies[0].name);
    try testing.expectEqualStrings("1.0", parsed.dependencies[0].version.?);
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
    defer freeDependencies(testing.allocator, parsed.dependencies);

    try testing.expectEqualStrings("cli_tool", parsed.name);
    try testing.expectEqualStrings("custom/lib.rs", parsed.lib_path.?);
    try testing.expectEqualStrings("custom/main.rs", parsed.bin_path.?);
}
test "parseManifestContent captures dependency sources" {
    const testing = std.testing;
    const toml =
        \\[package]
        \\name = "consumer"
        \\
        \\[dependencies]
        \\helper = { version = "1.2", path = "../helper", optional = true }
    ;
    const parsed = try parseManifestContent(testing.allocator, toml);
    defer testing.allocator.free(parsed.name);
    defer testing.allocator.free(parsed.edition);
    defer freeDependencies(testing.allocator, parsed.dependencies);

    try testing.expectEqual(@as(usize, 1), parsed.dependencies.len);
    const dependency = parsed.dependencies[0];
    try testing.expectEqualStrings("helper", dependency.name);
    try testing.expectEqualStrings("1.2", dependency.version.?);
    try testing.expectEqualStrings("../helper", dependency.path.?);
    try testing.expect(dependency.optional);
}

test "parseManifestContent preserves dependency feature metadata" {
    const testing = std.testing;
    const toml =
        \\[package]
        \\name = "consumer"
        \\
        \\[dependencies]
        \\omitted = { version = "1" }
        \\explicit = { version = "1", default-features = false, features = ["derive"] }
    ;

    const parsed = try parseManifestContent(testing.allocator, toml);
    defer deinitParsedManifest(testing.allocator, parsed);

    try testing.expectEqual(@as(usize, 2), parsed.dependencies.len);
    var omitted_dependency: ?Dependency = null;
    var explicit_dependency: ?Dependency = null;
    for (parsed.dependencies) |dependency| {
        if (std.mem.eql(u8, dependency.name, "omitted")) {
            omitted_dependency = dependency;
        } else if (std.mem.eql(u8, dependency.name, "explicit")) {
            explicit_dependency = dependency;
        }
    }

    try testing.expect(omitted_dependency != null);
    try testing.expect(explicit_dependency != null);
    try testing.expect(omitted_dependency.?.default_features == null);
    try testing.expectEqual(@as(usize, 0), omitted_dependency.?.features.len);
    try testing.expect(explicit_dependency.?.default_features != null);
    try testing.expect(!explicit_dependency.?.default_features.?);
    try testing.expectEqual(@as(usize, 1), explicit_dependency.?.features.len);
    try testing.expectEqualStrings("derive", explicit_dependency.?.features[0]);
}

test "parseManifestContent rejects malformed dependency feature metadata" {
    const cases = [_][]const u8{
        \\[package]
        \\name = "consumer"
        \\[dependencies]
        \\helper = { default-features = "false" }
        ,
        \\[package]
        \\name = "consumer"
        \\[dependencies]
        \\helper = { features = "derive" }
        ,
        \\[package]
        \\name = "consumer"
        \\[dependencies]
        \\helper = { features = [1] }
        ,
    };

    for (cases) |toml| {
        try std.testing.expectError(
            error.BadWireFormat,
            parseManifestContent(std.testing.allocator, toml),
        );
    }
}

test "parseManifestContent separates dev dependencies and preserves features" {
    const testing = std.testing;
    const toml =
        \\[package]
        \\name = "consumer"
        \\
        \\[dependencies]
        \\runtime_dep = "1"
        \\
        \\[dev-dependencies]
        \\test_dep = "2"
        \\
        \\[features]
        \\default = ["alloc"]
        \\alloc = []
    ;

    const parsed = try parseManifestContent(testing.allocator, toml);
    defer deinitParsedManifest(testing.allocator, parsed);

    try testing.expectEqual(@as(usize, 1), parsed.dependencies.len);
    try testing.expectEqualStrings("runtime_dep", parsed.dependencies[0].name);
    try testing.expectEqualStrings("1", parsed.dependencies[0].version.?);

    try testing.expectEqual(@as(usize, 1), parsed.dev_dependencies.len);
    try testing.expectEqualStrings("test_dep", parsed.dev_dependencies[0].name);
    try testing.expectEqualStrings("2", parsed.dev_dependencies[0].version.?);

    try testing.expectEqual(@as(usize, 2), parsed.features.len);
    var default_feature: ?Feature = null;
    var alloc_feature: ?Feature = null;
    for (parsed.features) |feature| {
        if (std.mem.eql(u8, feature.name, "default")) {
            default_feature = feature;
        } else if (std.mem.eql(u8, feature.name, "alloc")) {
            alloc_feature = feature;
        }
    }

    try testing.expect(default_feature != null);
    try testing.expect(alloc_feature != null);
    try testing.expectEqualStrings("default", default_feature.?.name);
    try testing.expectEqualStrings("alloc", alloc_feature.?.name);
    try testing.expectEqual(@as(usize, 1), default_feature.?.members.len);
    try testing.expectEqualStrings("alloc", default_feature.?.members[0]);
    try testing.expectEqual(@as(usize, 0), alloc_feature.?.members.len);
}

test "parseManifestContent rejects malformed optional field types" {
    const toml =
        \\[package]
        \\name = "consumer"
        \\version = 1
    ;

    try std.testing.expectError(
        error.BadWireFormat,
        parseManifestContent(std.testing.allocator, toml),
    );
}

test "parseManifestContent rejects multiple binary declarations" {
    const toml =
        \\[package]
        \\name = "consumer"
        \\
        \\[[bin]]
        \\name = "first"
        \\path = "src/first.rs"
        \\
        \\[[bin]]
        \\name = "second"
        \\path = "src/second.rs"
    ;

    try std.testing.expectError(
        error.CargoManifestMultipleBinsUnsupported,
        parseManifestContent(std.testing.allocator, toml),
    );
}

test "parseManifestContent rejects unsupported dependency declarations" {
    const Case = struct {
        content: []const u8,
        expected: anyerror,
    };
    const cases = [_]Case{
        .{
            .content =
            \\[package]
            \\name = "consumer"
            \\[build-dependencies]
            \\helper = "1"
            ,
            .expected = error.CargoManifestUnsupportedDependencySection,
        },
        .{
            .content =
            \\[package]
            \\name = "consumer"
            \\[target.'cfg(unix)'.dependencies]
            \\helper = "1"
            ,
            .expected = error.CargoManifestUnsupportedDependencySection,
        },
        .{
            .content =
            \\[package]
            \\name = "consumer"
            \\[dependencies]
            \\helper = { workspace = true }
            ,
            .expected = error.CargoManifestWorkspaceInheritanceUnsupported,
        },
        .{
            .content =
            \\[package]
            \\name = "consumer"
            \\[dependencies]
            \\helper = { git = "https://example.invalid/helper", branch = "main" }
            ,
            .expected = error.CargoManifestUnsupportedDependencySource,
        },
        .{
            .content =
            \\[package]
            \\name = "consumer"
            \\[dependencies]
            \\helper = { git = "https://example.invalid/helper", tag = "v1" }
            ,
            .expected = error.CargoManifestUnsupportedDependencySource,
        },
        .{
            .content =
            \\[package]
            \\name = "consumer"
            \\[dependencies]
            \\helper = { git = "https://example.invalid/helper", rev = "abc123" }
            ,
            .expected = error.CargoManifestUnsupportedDependencySource,
        },
        .{
            .content =
            \\[package]
            \\name = "consumer"
            \\[dependencies]
            \\helper = { version = "1", registry = "private" }
            ,
            .expected = error.CargoManifestUnsupportedDependencySource,
        },
    };

    for (cases) |case| {
        try std.testing.expectError(
            case.expected,
            parseManifestContent(std.testing.allocator, case.content),
        );
    }
}

fn writeTestFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    relative_path: []const u8,
    content: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ root, relative_path });
    if (std.fs.path.dirname(path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

test "loadCrateManifest rejects a missing configured root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(
        allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path },
    );
    try writeTestFile(
        allocator,
        io,
        root,
        "Cargo.toml",
        \\[package]
        \\name = "consumer"
        \\[lib]
        \\path = "missing/lib.rs"
        ,
    );
    try writeTestFile(allocator, io, root, "src/lib.rs", "");

    try std.testing.expectError(
        error.CargoManifestConfiguredRootSourceNotFound,
        loadCrateManifest(allocator, io, root),
    );
}
