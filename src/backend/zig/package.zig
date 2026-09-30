//! translate_rust.backend.zig.package — package writer and promotion boundary.
//! Renders an `ast.Package` to a complete standalone Zig package directory:
//! build.zig, build.zig.zon, and every `pkg.files[i]` source file. Promotion
//! stages all output, validates and tests it, then publishes it atomically.

const std = @import("std");
const ast = @import("ast.zig");
const emit = @import("emit.zig");

// ---------------------------------------------------------------------------
// Package name helpers
// ---------------------------------------------------------------------------

/// Resolve the package's own build module name.
fn packageIdName(pkg: *const ast.Package) []const u8 {
    return pkg.name;
}

fn dependencyModuleName(dep_name: []const u8) []const u8 {
    return if (std.mem.eql(u8, dep_name, "r2z-core")) "r2z" else dep_name;
}

fn appendRuntimeDependency(
    allocator: std.mem.Allocator,
    pkg: *const ast.Package,
) !struct { pkg: ast.Package, deps: []const ast.ZonDep } {
    for (pkg.zon_deps) |dep| {
        if (std.mem.eql(u8, dep.name, "r2z-core")) {
            return .{ .pkg = pkg.*, .deps = &.{} };
        }
    }
    for (pkg.files) |file| {
        for (file.imports) |import| {
            if (std.mem.eql(u8, import.module_or_path, "r2z")) break;
        } else continue;
        break;
    } else return .{ .pkg = pkg.*, .deps = &.{} };
    const deps = try allocator.alloc(ast.ZonDep, pkg.zon_deps.len + 1);
    @memcpy(deps[0..pkg.zon_deps.len], pkg.zon_deps);
    deps[pkg.zon_deps.len] = .{
        .name = "r2z-core",
        .path = "@workspace:r2z-core",
    };
    var result = pkg.*;
    result.zon_deps = deps;
    return .{ .pkg = result, .deps = deps };
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

fn appendFmt(
    comptime format: []const u8,
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(u8),
    args: anytype,
) !void {
    const text = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(text);
    try list.appendSlice(allocator, text);
}

fn validatePackageShape(pkg: *const ast.Package) !void {
    var package_for_validation = pkg.*;
    package_for_validation.fingerprint = package_for_validation.fingerprint orelse 0;
    try ast.validateForTranslation(&package_for_validation);
}

fn generateBuildZig(allocator: std.mem.Allocator, pkg: *const ast.Package) ![]const u8 {
    try validatePackageShape(pkg);
    const module_name = packageIdName(pkg);
    if (pkg.zon_deps.len == 0) {
        return std.fmt.allocPrint(
            allocator,
            \\const std = @import("std");
            \\
            \\pub fn build(b: *std.Build) void {{
            \\    const target = b.standardTargetOptions(.{{}});
            \\    // ReleaseSafe by default: it is the mode a consumer of this
            \\    // package actually runs. -Doptimize still selects any other.
            \\    const optimize: std.builtin.OptimizeMode = b.option(
            \\        std.builtin.OptimizeMode,
            \\        "optimize",
            \\        "Prioritize performance, safety, or binary size",
            \\    ) orelse switch (b.release_mode) {{
            \\        .off, .any => .ReleaseSafe,
            \\        .fast => .ReleaseFast,
            \\        .safe => .ReleaseSafe,
            \\        .small => .ReleaseSmall,
            \\    }};
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

    var bindings: std.ArrayListUnmanaged(u8) = .empty;
    defer bindings.deinit(allocator);
    var imports: std.ArrayListUnmanaged(u8) = .empty;
    defer imports.deinit(allocator);
    for (pkg.zon_deps) |dep| {
        const dep_id = try zonIdentName(allocator, dep.name);
        defer allocator.free(dep_id);
        const binding = try std.fmt.allocPrint(allocator, "dep_{s}", .{dep_id});
        defer allocator.free(binding);
        try appendFmt(
            "    const {s} = b.dependency(\"{s}\", .{{}});\n",
            allocator,
            &bindings,
            .{ binding, dep_id },
        );
        try appendFmt(
            "        .{{ .name = \"{s}\", .module = {s}.module(\"{s}\") }},\n",
            allocator,
            &imports,
            .{ dependencyModuleName(dep.name), binding, dependencyModuleName(dep.name) },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const target = b.standardTargetOptions(.{{}});
        \\    // ReleaseSafe by default: it is the mode a consumer of this
        \\    // package actually runs. -Doptimize still selects any other.
        \\    const optimize: std.builtin.OptimizeMode = b.option(
        \\        std.builtin.OptimizeMode,
        \\        "optimize",
        \\        "Prioritize performance, safety, or binary size",
        \\    ) orelse switch (b.release_mode) {{
        \\        .off, .any => .ReleaseSafe,
        \\        .fast => .ReleaseFast,
        \\        .safe => .ReleaseSafe,
        \\        .small => .ReleaseSmall,
        \\    }};
        \\
        \\{s}
        \\    const pkg_mod = b.addModule("{s}", .{{
        \\        .root_source_file = b.path("src/root.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\        .imports = &.{{ 
        \\{s}        }},
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
        .{
            bindings.items,
            module_name,
            imports.items,
            module_name,
        },
    );
}

/// Find the workspace `r2z-core` checkout by walking `anchor` and its parents.
///
/// `@src().file` cannot drive this walk. The compiler spells it relative to
/// the directory it was invoked in, which is this module's root, not the
/// process working directory or the executable: joining a runtime anchor to
/// that relative path lands in a different tree, and the three-level climb
/// that repairs an absolute path then overshoots by one. The anchor is the
/// only runtime fact available here, so the search looks for `r2z-core`
/// itself at each level instead.
fn tryWorkspaceCoreFromAnchor(
    allocator: std.mem.Allocator,
    io: std.Io,
    anchor: []const u8,
) !?[:0]u8 {
    var cursor = try allocator.dupe(u8, anchor);
    defer allocator.free(cursor);
    const cwd = std.Io.Dir.cwd();
    while (true) {
        const core_path = std.fs.path.resolvePosix(
            allocator,
            &.{ cursor, "r2z-core" },
        ) catch return error.DependencySourceUnavailable;
        if (std.Io.Dir.accessAbsolute(io, core_path, .{})) |_| {
            const result = cwd.realPathFileAlloc(io, core_path, allocator) catch {
                allocator.free(core_path);
                return error.DependencySourceUnavailable;
            };
            allocator.free(core_path);
            return result;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => {
                allocator.free(core_path);
                return err;
            },
        }
        allocator.free(core_path);

        const parent = std.fs.path.dirname(cursor) orelse break;
        if (std.mem.eql(u8, parent, cursor)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(cursor);
        cursor = next;
    }
    return null;
}

fn workspaceCoreAbsolute(allocator: std.mem.Allocator, io: std.Io) ![:0]u8 {
    const source_file = @src().file;
    if (std.fs.path.isAbsolute(source_file)) {
        const package_dir = std.fs.path.dirname(source_file) orelse
            return error.DependencySourceUnavailable;
        const core_path = try std.fs.path.resolvePosix(
            allocator,
            &.{ package_dir, "../../..", "r2z-core" },
        );
        defer allocator.free(core_path);
        return std.Io.Dir.realPathFileAbsoluteAlloc(io, core_path, allocator) catch
            error.DependencySourceUnavailable;
    }

    const cwd_anchor = std.process.currentPathAlloc(io, allocator) catch
        return error.DependencySourceUnavailable;
    defer allocator.free(cwd_anchor);
    if (try tryWorkspaceCoreFromAnchor(allocator, io, cwd_anchor)) |path| {
        return path;
    }

    const exe_anchor = std.process.executableDirPathAlloc(io, allocator) catch
        return error.DependencySourceUnavailable;
    defer allocator.free(exe_anchor);
    if (try tryWorkspaceCoreFromAnchor(allocator, io, exe_anchor)) |path| {
        return path;
    }
    return error.DependencySourceUnavailable;
}

fn absolutePathAllowMissing(
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    path: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.path.resolvePosix(allocator, &.{path});
    }
    return std.fs.path.resolvePosix(allocator, &.{ cwd_path, path });
}

fn resolveDependencyPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd_path: []const u8,
    out_dir: []const u8,
    path: []const u8,
) ![]const u8 {
    if (std.mem.eql(u8, path, "@workspace:r2z-core")) {
        const core_absolute = try workspaceCoreAbsolute(allocator, io);
        defer allocator.free(core_absolute);
        const out_absolute = try absolutePathAllowMissing(allocator, cwd_path, out_dir);
        defer allocator.free(out_absolute);
        return std.fs.path.relativePosix(allocator, cwd_path, out_absolute, core_absolute);
    }
    return allocator.dupe(u8, path);
}

fn generateBuildZigZon(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg: *const ast.Package,
    out_dir: []const u8,
) ![]const u8 {
    try validatePackageShape(pkg);
    const zon_name = try zonIdentName(allocator, packageIdName(pkg));
    defer allocator.free(zon_name);

    // Common single-package manifest (no dependencies).
    if (pkg.zon_deps.len == 0) {
        if (pkg.fingerprint) |fingerprint| {
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
        return std.fmt.allocPrint(
            allocator,
            \\.{{
            \\    .name = .{s},
            \\    .version = "{s}",
            \\    .minimum_zig_version = "0.16.0",
            \\    .paths = .{{
            \\        "build.zig",
            \\        "build.zig.zon",
            \\        "src",
            \\    }},
            \\}}
            \\
        ,
            .{ zon_name, pkg.version },
        );
    }

    const cwd_path = std.process.currentPathAlloc(io, allocator) catch
        return error.DependencySourceUnavailable;
    defer allocator.free(cwd_path);

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
    if (pkg.fingerprint) |fingerprint| {
        try buf.appendSlice(allocator, "    .fingerprint = 0x");
        var fp_buf: [16]u8 = undefined;
        const fp_str = try std.fmt.bufPrint(&fp_buf, "{x:0>16}", .{fingerprint});
        try buf.appendSlice(allocator, fp_str);
        try buf.appendSlice(allocator, ",\n");
    }
    try buf.appendSlice(allocator, "    .minimum_zig_version = \"0.16.0\",\n");
    try buf.appendSlice(allocator, "    .dependencies = .{\n");
    for (pkg.zon_deps) |dep| {
        const dep_id = try zonIdentName(allocator, dep.name);
        defer allocator.free(dep_id);
        try buf.appendSlice(allocator, "        .");
        try buf.appendSlice(allocator, dep_id);
        try buf.appendSlice(allocator, " = .{ ");
        if (dep.path) |path| {
            const resolved_path = try resolveDependencyPath(
                allocator,
                io,
                cwd_path,
                out_dir,
                path,
            );
            defer allocator.free(resolved_path);
            try buf.appendSlice(allocator, ".path = \"");
            try buf.appendSlice(allocator, resolved_path);
            try buf.appendSlice(allocator, "\"");
        } else {
            try buf.appendSlice(allocator, ".url = \"");
            try buf.appendSlice(allocator, dep.url);
            try buf.appendSlice(allocator, "\", .hash = \"");
            try buf.appendSlice(allocator, dep.hash);
            try buf.appendSlice(allocator, "\"");
        }
        try buf.appendSlice(allocator, " },\n");
    }
    try buf.appendSlice(allocator, "    },\n");
    try buf.appendSlice(allocator, "    .paths = .{\n");
    try buf.appendSlice(allocator, "        \"build.zig\",\n");
    try buf.appendSlice(allocator, "        \"build.zig.zon\",\n");
    try buf.appendSlice(allocator, "        \"src\",\n");
    try buf.appendSlice(allocator, "    },\n");
    try buf.appendSlice(allocator, "}\n");

    return buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Package writer
// ---------------------------------------------------------------------------

/// Write an `ast.Package` to a staging directory: build.zig, build.zig.zon,
/// and every `pkg.files[i]` rendered via `emit.emitFile`.
fn writeToDisk(io: std.Io, pkg: *const ast.Package, staging_dir: []const u8) !void {
    try validatePackageShape(pkg);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var dir = std.Io.Dir.cwd();
    try dir.createDirPath(io, staging_dir);

    const with_runtime = try appendRuntimeDependency(allocator, pkg);
    defer if (with_runtime.deps.len > 0) allocator.free(with_runtime.deps);

    // 1. build.zig
    const build_zig = try generateBuildZig(allocator, &with_runtime.pkg);
    try writeFile(allocator, io, staging_dir, "build.zig", build_zig);

    // 2. build.zig.zon
    const build_zig_zon = try generateBuildZigZon(allocator, io, &with_runtime.pkg, staging_dir);
    try writeFile(allocator, io, staging_dir, "build.zig.zon", build_zig_zon);

    // 3. Source files
    for (pkg.files) |file| {
        const content = try emit.emitFile(allocator, &file);
        try writeFile(allocator, io, staging_dir, file.path, content);
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
// Staged package promotion
// ---------------------------------------------------------------------------

pub const promotion_nonce_len = 16;
const promotion_attempt_limit = 16;

pub const PromotionError = error{
    GeneratedPackageBuildFailed,
    InvalidOutputDirectory,
    InvalidGeneratedManifest,
    InvalidGeneratedSource,
    StagingPathExhausted,
};

pub const BuildTestResult = struct {
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
};

pub const FillPromotionNonce = *const fn (
    io: std.Io,
    context: ?*anyopaque,
    nonce: []u8,
) anyerror!void;

pub const RunBuildTest = *const fn (
    allocator: std.mem.Allocator,
    io: std.Io,
    context: ?*anyopaque,
    staging_dir: []const u8,
) anyerror!BuildTestResult;

pub const ResolveFingerprint = *const fn (
    allocator: std.mem.Allocator,
    io: std.Io,
    context: ?*anyopaque,
    staging_dir: []const u8,
    result: *const BuildTestResult,
) anyerror!?u64;

/// Sink for the output of a staged build that did not pass. Split out of
/// `promoteWithHooks` so a test can read the diagnostics a user sees.
pub const ReportBuildFailure = *const fn (
    context: ?*anyopaque,
    result: *const BuildTestResult,
) void;

pub const PromotionHooks = struct {
    context: ?*anyopaque = null,
    fill_nonce: FillPromotionNonce = fillPromotionNonce,
    run_build_test: RunBuildTest = runGeneratedBuildTest,
    resolve_fingerprint: ResolveFingerprint = resolveFingerprint,
    report_build_failure: ReportBuildFailure = printBuildFailure,
};

/// Return a unique sibling path for the package staging directory.
fn stagingPath(
    allocator: std.mem.Allocator,
    out_dir: []const u8,
    nonce: [promotion_nonce_len]u8,
) ![]const u8 {
    if (out_dir.len == 0) return error.InvalidOutputDirectory;
    const basename = std.fs.path.basename(out_dir);
    if (basename.len == 0 or std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..")) {
        return error.InvalidOutputDirectory;
    }
    const parent = std.fs.path.dirname(out_dir);
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    var staged_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const staged_name = try std.fmt.bufPrint(
        &staged_name_buf,
        ".{s}.staging.{s}",
        .{ basename, nonce_hex },
    );
    if (parent) |parent_path| {
        return std.fs.path.join(allocator, &.{ parent_path, staged_name });
    }
    return allocator.dupe(u8, staged_name);
}

fn fillPromotionNonce(io: std.Io, _: ?*anyopaque, nonce: []u8) anyerror!void {
    try io.randomSecure(nonce);
}

fn makeStagingDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
    hooks: PromotionHooks,
) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(out_dir)) |parent| {
        try cwd.createDirPath(io, parent);
    }

    var nonce: [promotion_nonce_len]u8 = undefined;
    var attempt: usize = 0;
    while (attempt < promotion_attempt_limit) : (attempt += 1) {
        try hooks.fill_nonce(io, hooks.context, &nonce);
        const candidate = try stagingPath(allocator, out_dir, nonce);
        cwd.createDir(io, candidate, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(candidate);
                continue;
            },
            else => {
                allocator.free(candidate);
                return err;
            },
        };
        return candidate;
    }
    return error.StagingPathExhausted;
}

fn readFileAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]const u8 {
    var dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var io_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &io_buf);
    return reader.interface.allocRemaining(allocator, .limited(1 << 20));
}

fn validateStagedFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    staging_dir: []const u8,
    path: []const u8,
) !void {
    var dir = std.Io.Dir.cwd();
    const full_path = try std.fs.path.join(allocator, &.{ staging_dir, path });
    defer allocator.free(full_path);
    const stat = try dir.statFile(io, full_path, .{});
    if (stat.kind != .file) return error.InvalidGeneratedSource;
}

fn parseManifestFingerprint(zon: []const u8) !?u64 {
    const marker = ".fingerprint = 0x";
    const marker_index = std.mem.indexOf(u8, zon, marker) orelse return null;
    const value_start = marker_index + marker.len;
    var value_end = value_start;
    while (value_end < zon.len and std.ascii.isHex(zon[value_end])) : (value_end += 1) {}
    if (value_end == value_start) return error.InvalidGeneratedManifest;
    if (std.mem.indexOfPos(u8, zon, value_end, marker) != null) {
        return error.InvalidGeneratedManifest;
    }
    return std.fmt.parseUnsigned(u64, zon[value_start..value_end], 16) catch {
        return error.InvalidGeneratedManifest;
    };
}

fn validateStagedPackage(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg: *const ast.Package,
    staging_dir: []const u8,
    expected_fingerprint: ?u64,
    require_fingerprint: bool,
) !void {
    if (require_fingerprint) {
        const fingerprint = expected_fingerprint orelse return error.MissingFingerprint;
        var package_for_validation = pkg.*;
        package_for_validation.fingerprint = fingerprint;
        try ast.validateForTranslation(&package_for_validation);
    } else {
        try validatePackageShape(pkg);
    }
    try validateStagedFile(allocator, io, staging_dir, "build.zig");
    try validateStagedFile(allocator, io, staging_dir, "build.zig.zon");
    try validateStagedFile(allocator, io, staging_dir, "src/root.zig");
    for (pkg.files) |file| {
        try validateStagedFile(allocator, io, staging_dir, file.path);
    }

    const zon_path = try std.fs.path.join(allocator, &.{ staging_dir, "build.zig.zon" });
    defer allocator.free(zon_path);
    const zon = try readFileAlloc(allocator, io, zon_path);
    defer allocator.free(zon);
    if (std.mem.indexOf(u8, zon, ".name = .") == null) return error.InvalidGeneratedManifest;
    const manifest_fingerprint = try parseManifestFingerprint(zon);
    if (require_fingerprint) {
        const fingerprint = expected_fingerprint.?;
        if (manifest_fingerprint == null) return error.InvalidGeneratedManifest;
        if (manifest_fingerprint.? != fingerprint) return error.InvalidGeneratedManifest;
    } else if (pkg.fingerprint) |fingerprint| {
        if (manifest_fingerprint == null) return error.InvalidGeneratedManifest;
        if (manifest_fingerprint.? != fingerprint) return error.InvalidGeneratedManifest;
    }
    if (std.mem.indexOf(u8, zon, "\"src\"") == null) return error.InvalidGeneratedManifest;
}

/// The `-Doptimize` flags the promotion gate compiles the staged package in.
/// Debug catches compile-time breakage; ReleaseSafe is what a consumer runs,
/// where the optimizer is on and `std.debug.assert` guards are load-bearing.
const promotion_optimize_flags = [_][]const u8{
    "-Doptimize=Debug",
    "-Doptimize=ReleaseSafe",
};

const RunGateMode = *const fn (
    allocator: std.mem.Allocator,
    context: ?*anyopaque,
    flag: []const u8,
) anyerror!BuildTestResult;

/// Compile the staged package once per optimize mode. The first failure is
/// returned unchanged: a second run would repeat the same manifest
/// fingerprint hint, and `resolveFingerprint` rejects a hint it sees twice.
fn runGateOptimizeModes(
    allocator: std.mem.Allocator,
    run_mode: RunGateMode,
    context: ?*anyopaque,
) anyerror!BuildTestResult {
    for (promotion_optimize_flags) |flag| {
        const result = try run_mode(allocator, context, flag);
        if (result.term == .exited and result.term.exited == 0) {
            releaseBuildTestResult(allocator, result);
            continue;
        }
        return result;
    }
    return .{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "" };
}

const GeneratedGateContext = struct {
    io: std.Io,
    staging_dir: []const u8,
};

fn runGeneratedGateMode(
    allocator: std.mem.Allocator,
    opaque_context: ?*anyopaque,
    flag: []const u8,
) anyerror!BuildTestResult {
    const context: *GeneratedGateContext = @ptrCast(@alignCast(opaque_context.?));
    const result = try std.process.run(allocator, context.io, .{
        .argv = &.{ "zig", "build", "test", flag },
        .cwd = .{ .path = context.staging_dir },
    });
    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn runGeneratedBuildTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    _: ?*anyopaque,
    staging_dir: []const u8,
) anyerror!BuildTestResult {
    var context = GeneratedGateContext{
        .io = io,
        .staging_dir = staging_dir,
    };
    return runGateOptimizeModes(allocator, runGeneratedGateMode, &context);
}

fn recordFingerprint(
    dump: []const u8,
    marker: []const u8,
    value: *?u64,
    count: *usize,
) !void {
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, dump, search_start, marker)) |marker_index| {
        const value_start = marker_index + marker.len;
        const rest = dump[value_start..];
        var value_len: usize = 0;
        while (value_len < rest.len and std.ascii.isHex(rest[value_len])) : (value_len += 1) {}
        if (value_len == 0) return error.FingerprintProbeUnrecognized;
        const parsed = std.fmt.parseUnsigned(u64, rest[0..value_len], 16) catch {
            return error.FingerprintProbeUnrecognized;
        };
        count.* += 1;
        if (count.* > 1) return error.FingerprintProbeAmbiguous;
        value.* = parsed;
        search_start = value_start + value_len;
    }
}

fn resolveFingerprint(
    _: std.mem.Allocator,
    _: std.Io,
    _: ?*anyopaque,
    _: []const u8,
    result: *const BuildTestResult,
) anyerror!?u64 {
    const markers = [_][]const u8{
        "use this value: 0x",
        "fingerprint: 0x",
        "expected: 0x",
        "expected 0x",
        "suggested value: 0x",
    };
    var value: ?u64 = null;
    var count: usize = 0;
    for (markers) |marker| {
        try recordFingerprint(result.stdout, marker, &value, &count);
        try recordFingerprint(result.stderr, marker, &value, &count);
    }
    return value;
}

fn patchManifestFingerprint(
    allocator: std.mem.Allocator,
    io: std.Io,
    staging_dir: []const u8,
    fingerprint: u64,
) !void {
    const zon_path = try std.fs.path.join(allocator, &.{ staging_dir, "build.zig.zon" });
    defer allocator.free(zon_path);
    const zon = try readFileAlloc(allocator, io, zon_path);
    defer allocator.free(zon);

    const fingerprint_hex = try std.fmt.allocPrint(allocator, "{x}", .{fingerprint});
    defer allocator.free(fingerprint_hex);
    var patched: std.ArrayListUnmanaged(u8) = .empty;
    defer patched.deinit(allocator);

    const old_key = ".fingerprint = 0x";
    if (std.mem.indexOf(u8, zon, old_key)) |old_idx| {
        const value_start = old_idx + old_key.len;
        var value_end = value_start;
        while (value_end < zon.len and std.ascii.isHex(zon[value_end])) : (value_end += 1) {}
        if (value_end == value_start) return error.ManifestFingerprintMissing;
        try patched.appendSlice(allocator, zon[0..value_start]);
        try patched.appendSlice(allocator, fingerprint_hex);
        try patched.appendSlice(allocator, zon[value_end..]);
    } else {
        const insert_key = "    .minimum_zig_version = ";
        const insert_idx = std.mem.indexOf(u8, zon, insert_key) orelse
            return error.ManifestFingerprintMissing;
        try patched.appendSlice(allocator, zon[0..insert_idx]);
        try patched.appendSlice(allocator, "    .fingerprint = 0x");
        try patched.appendSlice(allocator, fingerprint_hex);
        try patched.appendSlice(allocator, ",\n");
        try patched.appendSlice(allocator, zon[insert_idx..]);
    }
    try writeFile(allocator, io, staging_dir, "build.zig.zon", patched.items);
}

fn releaseBuildTestResult(allocator: std.mem.Allocator, result: BuildTestResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

/// Report a staged build that did not pass. The compiler's own output is the
/// only diagnostic a promotion failure carries, and it is reported on every
/// failing pass: the retry pass always did, the first pass dropped it, so a
/// one-pass compile error surfaced as a bare error with no message at all.
fn printBuildFailure(_: ?*anyopaque, result: *const BuildTestResult) void {
    var reported = false;
    if (hasCapturedOutput(result.stdout)) {
        std.debug.print("generated package build failed (stdout):\n{s}\n", .{result.stdout});
        reported = true;
    }
    if (hasCapturedOutput(result.stderr)) {
        std.debug.print("generated package build failed:\n{s}\n", .{result.stderr});
        reported = true;
    }
    if (!reported) {
        std.debug.print("generated package build failed: no compiler output captured\n", .{});
    }
}

/// True when a captured stream carries anything but whitespace.
fn hasCapturedOutput(bytes: []const u8) bool {
    return std.mem.trim(u8, bytes, " \t\r\n").len != 0;
}

fn cleanupPromotion(
    io: std.Io,
    staging_dir: []const u8,
    primary_error: anyerror,
) anyerror {
    var dir = std.Io.Dir.cwd();
    try dir.deleteTree(io, staging_dir);
    return primary_error;
}

fn publishStagedPackage(io: std.Io, staging_dir: []const u8, out_dir: []const u8) !void {
    if (std.fs.path.isAbsolute(staging_dir) or std.fs.path.isAbsolute(out_dir)) {
        if (!std.fs.path.isAbsolute(staging_dir) or !std.fs.path.isAbsolute(out_dir)) {
            return error.InvalidOutputDirectory;
        }
        return std.Io.Dir.renameAbsolute(staging_dir, out_dir, io);
    }
    const dir = std.Io.Dir.cwd();
    return dir.rename(staging_dir, dir, out_dir, io);
}

/// Write a complete package into staging, validate and test it, then publish it
/// with one same-filesystem rename.
pub fn promoteWithHooks(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg: *const ast.Package,
    out_dir: []const u8,
    hooks: PromotionHooks,
) !void {
    try validatePackageShape(pkg);
    const staging_dir = try makeStagingDirectory(allocator, io, out_dir, hooks);
    defer allocator.free(staging_dir);

    writeToDisk(io, pkg, staging_dir) catch |err| return cleanupPromotion(io, staging_dir, err);
    validateStagedPackage(
        allocator,
        io,
        pkg,
        staging_dir,
        pkg.fingerprint,
        false,
    ) catch |err| return cleanupPromotion(io, staging_dir, err);

    var build_result = hooks.run_build_test(allocator, io, hooks.context, staging_dir) catch |err|
        return cleanupPromotion(io, staging_dir, err);
    var fingerprint_patched = false;
    var final_fingerprint = pkg.fingerprint;
    while (true) {
        switch (build_result.term) {
            .exited => |code| {
                if (code == 0) break;
            },
            else => {
                hooks.report_build_failure(hooks.context, &build_result);
                releaseBuildTestResult(allocator, build_result);
                return cleanupPromotion(
                    io,
                    staging_dir,
                    error.GeneratedPackageBuildFailed,
                );
            },
        }
        if (fingerprint_patched) {
            hooks.report_build_failure(hooks.context, &build_result);
            releaseBuildTestResult(allocator, build_result);
            return cleanupPromotion(
                io,
                staging_dir,
                error.GeneratedPackageBuildFailed,
            );
        }

        const fingerprint = hooks.resolve_fingerprint(
            allocator,
            io,
            hooks.context,
            staging_dir,
            &build_result,
        ) catch |err| {
            hooks.report_build_failure(hooks.context, &build_result);
            releaseBuildTestResult(allocator, build_result);
            return cleanupPromotion(io, staging_dir, err);
        };
        const resolved_fingerprint = fingerprint orelse {
            hooks.report_build_failure(hooks.context, &build_result);
            releaseBuildTestResult(allocator, build_result);
            return cleanupPromotion(io, staging_dir, error.GeneratedPackageBuildFailed);
        };
        releaseBuildTestResult(allocator, build_result);
        patchManifestFingerprint(
            allocator,
            io,
            staging_dir,
            resolved_fingerprint,
        ) catch |err| return cleanupPromotion(io, staging_dir, err);
        final_fingerprint = resolved_fingerprint;
        fingerprint_patched = true;
        build_result = hooks.run_build_test(allocator, io, hooks.context, staging_dir) catch |err|
            return cleanupPromotion(io, staging_dir, err);
    }
    releaseBuildTestResult(allocator, build_result);
    validateStagedPackage(
        allocator,
        io,
        pkg,
        staging_dir,
        final_fingerprint,
        true,
    ) catch |err| return cleanupPromotion(io, staging_dir, err);

    publishStagedPackage(io, staging_dir, out_dir) catch |err|
        return cleanupPromotion(io, staging_dir, err);
}

/// Promote a generated package with the production build and fingerprint
/// resolver.
pub fn promoteToDisk(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg: *const ast.Package,
    out_dir: []const u8,
) !void {
    return promoteWithHooks(allocator, io, pkg, out_dir, .{});
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

test "generateBuildZig: runs every translated test through the root module" {
    const allocator = std.testing.allocator;
    var pkg = buildTestPackage();
    const root_file = pkg.files[0];
    const non_root_test_body: ast.Block = .{
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
                    .{ .lit = .{ .int = 42 } },
                    .{ .lit = .{ .int = 42 } },
                },
            } } },
        },
    };
    const translated_tests = [_]ast.TestDecl{
        .{ .name = "fnv32 vectors", .body = non_root_test_body },
        .{ .name = "fnv64 vectors", .body = non_root_test_body },
    };
    const test_file: ast.File = .{
        .path = "src/support/tests.zig",
        .imports = &.{.{ .local_name = "std", .module_or_path = "std" }},
        .tests = &translated_tests,
    };
    const files = [_]ast.File{ root_file, test_file };
    pkg.files = &files;

    // Exactly one test artifact, rooted at the package root. A test file that
    // is compiled as its own module root cannot import its siblings, so a
    // per-file artifact would fail to build for any nested test module. The
    // lowerer keeps nested tests reachable from the root instead.
    const build_zig = try generateBuildZig(allocator, &pkg);
    defer allocator.free(build_zig);

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            build_zig,
            "b.addTest(.{ .root_module = pkg_mod })",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            build_zig,
            ".root_source_file = b.path(\"src/root.zig\")",
        ) != null,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, build_zig, "b.addTest("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, build_zig, "b.addRunArtifact("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, build_zig, "test_step.dependOn("),
    );
}

test "generateBuildZig: selects the optimize mode explicitly, defaulting to ReleaseSafe" {
    const allocator = std.testing.allocator;
    const pkg = buildTestPackage();
    const build_zig = try generateBuildZig(allocator, &pkg);
    defer allocator.free(build_zig);

    // `b.standardOptimizeOption(.{})` resolves to Debug unless the consumer
    // passes -Doptimize, so a promoted package was only ever compiled in the
    // one mode nobody ships. ReleaseSafe is the mode a consumer runs, and it
    // keeps `std.debug.assert` guards live under the optimizer.
    try std.testing.expect(std.mem.indexOf(u8, build_zig, "standardOptimizeOption") == null);
    try std.testing.expect(
        std.mem.indexOf(u8, build_zig, "std.builtin.OptimizeMode,") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, build_zig, "\"optimize\",") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, build_zig, ".off, .any => .ReleaseSafe,") != null,
    );

    // Without this annotation the `orelse` switch yields an untyped
    // `@EnumLiteral`, and the generated build rejects itself: "value with
    // comptime-only type depends on runtime control flow".
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            build_zig,
            "const optimize: std.builtin.OptimizeMode = b.option(",
        ) != null,
    );
}

test "generateBuildZig: the ReleaseSafe default survives the dependency template" {
    const allocator = std.testing.allocator;
    var pkg = buildTestPackage();
    pkg.zon_deps = &.{.{ .name = "r2z-helper", .path = "../helper" }};
    const build_zig = try generateBuildZig(allocator, &pkg);
    defer allocator.free(build_zig);

    // The dependency-carrying template is a second copy of the same preamble;
    // a ReleaseSafe default in one and a Debug default in the other would
    // leave the gate mode-dependent on which shape a package lowers to.
    try std.testing.expect(std.mem.indexOf(u8, build_zig, "standardOptimizeOption") == null);
    try std.testing.expect(
        std.mem.indexOf(u8, build_zig, ".off, .any => .ReleaseSafe,") != null,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, build_zig, ".off, .any => .ReleaseSafe,"),
    );

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            build_zig,
            "const optimize: std.builtin.OptimizeMode = b.option(",
        ) != null,
    );
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
    // The group is gone on purpose: a top-level `bin_op` is already the whole
    // operand, so the emitter writes `return a + b;` and only re-wraps a
    // nested operator that precedence would otherwise swallow. What this test
    // pins is that the function body survived the write, not the parentheses
    // an earlier emitter sprayed around every binary expression.
    try std.testing.expect(std.mem.indexOf(u8, src, "return a + b;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "test \"add sums\" {") != null);
}

test "writeToDisk: emits path dependency wiring" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    var pkg = buildTestPackage();
    pkg.zon_deps = &.{
        .{ .name = "r2z-helper", .path = "../helper" },
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    try writeToDisk(test_io, &pkg, tmp_root);

    const build_path = try std.fs.path.join(allocator, &.{ tmp_root, "build.zig" });
    defer allocator.free(build_path);
    const build = try readFileContent(allocator, test_io, build_path);
    defer allocator.free(build);
    try std.testing.expect(std.mem.indexOf(u8, build, "b.dependency(\"r2z_helper\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, ".module(\"r2z-helper\")") != null);

    const zon_path = try std.fs.path.join(allocator, &.{ tmp_root, "build.zig.zon" });
    defer allocator.free(zon_path);
    const zon = try readFileContent(allocator, test_io, zon_path);
    defer allocator.free(zon);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".r2z_helper = .{ .path = \"../helper\" }") != null);
}

test "writeToDisk: binds r2z imports to the r2z-core dependency key" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    var pkg = buildTestPackage();
    var imports = [_]ast.Import{
        .{ .local_name = "std", .module_or_path = "std" },
        .{ .local_name = "r2z", .module_or_path = "r2z" },
    };
    var files = [_]ast.File{pkg.files[0]};
    files[0].imports = &imports;
    pkg.files = &files;
    const with_runtime = try appendRuntimeDependency(allocator, &pkg);
    defer if (with_runtime.deps.len > 0) allocator.free(with_runtime.deps);
    try std.testing.expectEqualStrings("r2z-core", with_runtime.pkg.zon_deps[0].name);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    try writeToDisk(test_io, &pkg, tmp_root);

    const build_path = try std.fs.path.join(allocator, &.{ tmp_root, "build.zig" });
    defer allocator.free(build_path);
    const build = try readFileContent(allocator, test_io, build_path);
    defer allocator.free(build);
    try std.testing.expect(std.mem.indexOf(u8, build, "b.dependency(\"r2z_core\"") != null);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            build,
            ".name = \"r2z\", .module = dep_r2z_core.module(\"r2z\")",
        ) != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, build, ".name = \"r2z-core\"") == null);

    const zon_path = try std.fs.path.join(allocator, &.{ tmp_root, "build.zig.zon" });
    defer allocator.free(zon_path);
    const zon = try readFileContent(allocator, test_io, zon_path);
    defer allocator.free(zon);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".r2z_core = .{") != null);
}

test "generateBuildZigZon: excludes runtime dependency from emitted paths" {
    const allocator = std.testing.allocator;
    // Manifest generation runs on a package that has already lowered, and a
    // root that declares nothing is not one. The declaration is incidental to
    // the manifest text these tests assert on; it only keeps the fixture on the
    // real code path.
    const marker_decl: ast.Decl = .{ .const_decl = .{
        .name = "MARKER",
        .init = ast.Expr{ .lit = .{ .int = 1 } },
    } };
    const pkg: ast.Package = .{
        .name = "demo",
        .files = &.{.{
            .path = "src/root.zig",
            .imports = &.{.{ .local_name = "r2z", .module_or_path = "r2z" }},
            .decls = &.{marker_decl},
        }},
    };
    const with_runtime = try appendRuntimeDependency(allocator, &pkg);
    defer if (with_runtime.deps.len > 0) allocator.free(with_runtime.deps);

    const zon = try generateBuildZigZon(allocator, std.testing.io, &with_runtime.pkg, ".");
    defer allocator.free(zon);

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            zon,
            ".dependencies = .{\n        .r2z_core = .{",
        ) != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, zon, "\"r2z_core\"") == null);
    try std.testing.expect(
        std.mem.indexOf(u8, zon,
            \\.paths = .{
            \\        "build.zig",
            \\        "build.zig.zon",
            \\        "src",
        ) != null,
    );
}

test "generateBuildZigZon: allows a missing absolute output directory" {
    const allocator = std.testing.allocator;
    const marker_decl: ast.Decl = .{ .const_decl = .{
        .name = "MARKER",
        .init = ast.Expr{ .lit = .{ .int = 1 } },
    } };
    const pkg: ast.Package = .{
        .name = "demo",
        .files = &.{.{
            .path = "src/root.zig",
            .imports = &.{.{ .local_name = "r2z", .module_or_path = "r2z" }},
            .decls = &.{marker_decl},
        }},
    };
    const with_runtime = try appendRuntimeDependency(allocator, &pkg);
    defer if (with_runtime.deps.len > 0) allocator.free(with_runtime.deps);

    const zon = try generateBuildZigZon(
        allocator,
        std.testing.io,
        &with_runtime.pkg,
        "/tmp/translate-rust-missing-output/backend",
    );
    defer allocator.free(zon);
    try std.testing.expect(
        std.mem.indexOf(u8, zon, ".r2z_core = .{ .path = \"") != null,
    );
}

fn expectWriteValidationError(expected: anyerror, pkg: *const ast.Package) !void {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try std.fs.path.join(
        allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path, "invalid-package" },
    );
    defer allocator.free(tmp_root);

    try std.testing.expectError(expected, writeToDisk(test_io, pkg, tmp_root));
}

test "writeToDisk: rejects a package without src/root.zig" {
    var pkg = buildTestPackage();
    var file = pkg.files[0];
    file.path = "src/lib.zig";
    pkg.files = &.{file};

    try expectWriteValidationError(error.MissingRootFile, &pkg);
}

test "writeToDisk: rejects a package whose root file declares nothing" {
    // The staged package would still link and its own `zig build test` would
    // pass on a zero-test binary, so an empty root has to stop here rather
    // than be published as a translation. Sibling declarations do not help.
    var pkg = buildTestPackage();
    var root = pkg.files[0];
    root.decls = &.{};
    root.tests = &.{};
    pkg.files = &.{ root, .{
        .path = "src/util.zig",
        .decls = &.{.{ .const_decl = .{
            .name = "util",
            .init = ast.Expr{ .lit = .{ .int = 1 } },
        } }},
    } };

    try expectWriteValidationError(error.EmptyRootFile, &pkg);
}

test "writeToDisk: rejects duplicate source files" {
    var pkg = buildTestPackage();
    pkg.files = &.{ pkg.files[0], pkg.files[0] };

    try expectWriteValidationError(error.DuplicateFilePath, &pkg);
}

test "writeToDisk: rejects empty and traversing source paths" {
    var pkg = buildTestPackage();
    var file = pkg.files[0];
    file.path = "";
    pkg.files = &.{file};
    try expectWriteValidationError(error.InvalidFilePath, &pkg);

    file.path = "src/../root.zig";
    pkg.files = &.{file};
    try expectWriteValidationError(error.InvalidFilePath, &pkg);
}

test "writeToDisk: permits a null package fingerprint for staging" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    var pkg = buildTestPackage();
    pkg.fingerprint = null;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    try writeToDisk(test_io, &pkg, tmp_root);

    const zon_path = try std.fs.path.join(allocator, &.{ tmp_root, "build.zig.zon" });
    defer allocator.free(zon_path);
    const zon = try readFileContent(allocator, test_io, zon_path);
    defer allocator.free(zon);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".fingerprint") == null);
}

test "writeToDisk: rejects an empty package name" {
    var pkg = buildTestPackage();
    pkg.name = "";

    try expectWriteValidationError(error.InvalidPackageName, &pkg);
}

test "writeToDisk: rejects invalid dependency metadata" {
    var pkg = buildTestPackage();
    pkg.zon_deps = &.{.{ .name = "helper" }};
    try expectWriteValidationError(error.DependencySourceUnavailable, &pkg);

    pkg.zon_deps = &.{.{ .name = "", .path = "../helper" }};
    try expectWriteValidationError(error.InvalidDependencyName, &pkg);

    pkg.zon_deps = &.{
        .{ .name = "helper", .path = "../helper-a" },
        .{ .name = "helper", .path = "../helper-b" },
    };
    try expectWriteValidationError(error.DuplicateDependencyName, &pkg);
}
test "writeToDisk: rejects dependency names that collide after ZON sanitization" {
    var pkg = buildTestPackage();
    pkg.zon_deps = &.{
        .{ .name = "helper-name", .path = "../helper-a" },
        .{ .name = "helper_name", .path = "../helper-b" },
    };

    try expectWriteValidationError(error.DuplicateDependencyName, &pkg);
}

const PromotionTestMode = enum {
    compile_failure,
    compile_failure_on_stdout,
    fingerprint_then_success,
    fingerprint_then_failure,
    resolver_failure,
    success_without_fingerprint,
};

const reported_output_capacity = 256;

const PromotionTestContext = struct {
    final_path: []const u8,
    mode: PromotionTestMode,
    build_calls: u32 = 0,
    resolver_calls: u32 = 0,
    resolver_saw_missing_fingerprint: bool = false,
    destination_visible_during_build: bool = false,
    report_calls: u32 = 0,
    reported_stdout: [reported_output_capacity]u8 = undefined,
    reported_stdout_len: usize = 0,
    reported_stderr: [reported_output_capacity]u8 = undefined,
    reported_stderr_len: usize = 0,
};

fn fixedPromotionNonce(
    _: std.Io,
    _: ?*anyopaque,
    nonce: []u8,
) anyerror!void {
    @memset(nonce, 0xa5);
}

fn fakePromotionBuildTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    opaque_context: ?*anyopaque,
    _: []const u8,
) anyerror!BuildTestResult {
    const context: *PromotionTestContext = @ptrCast(@alignCast(opaque_context.?));
    var dir = std.Io.Dir.cwd();
    if (dir.access(io, context.final_path, .{})) |_| {
        context.destination_visible_during_build = true;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    context.build_calls += 1;
    const stderr = switch (context.mode) {
        .compile_failure => "generated source does not compile",
        .compile_failure_on_stdout => "",
        .fingerprint_then_success, .resolver_failure => if (context.build_calls == 1)
            "fingerprint: 0x81677af28f9d3b4e"
        else
            "",
        .fingerprint_then_failure => if (context.build_calls == 1)
            "fingerprint: 0x81677af28f9d3b4e"
        else
            "optimized build still rejects the generated source",
        .success_without_fingerprint => "",
    };
    const stdout_text = switch (context.mode) {
        .compile_failure_on_stdout => "error: use of undeclared identifier 'undefined_value'",
        else => "",
    };
    const exit_code: u8 = switch (context.mode) {
        .compile_failure, .compile_failure_on_stdout, .resolver_failure => 1,
        .fingerprint_then_success => if (context.build_calls == 1) 1 else 0,
        .fingerprint_then_failure => 1,
        .success_without_fingerprint => 0,
    };
    const stdout = try allocator.dupe(u8, stdout_text);
    errdefer allocator.free(stdout);
    const stderr_copy = try allocator.dupe(u8, stderr);
    return .{
        .term = .{ .exited = exit_code },
        .stdout = stdout,
        .stderr = stderr_copy,
    };
}

fn fakePromotionFingerprint(
    allocator: std.mem.Allocator,
    io: std.Io,
    opaque_context: ?*anyopaque,
    staging_dir: []const u8,
    _: *const BuildTestResult,
) anyerror!?u64 {
    const context: *PromotionTestContext = @ptrCast(@alignCast(opaque_context.?));
    context.resolver_calls += 1;

    const zon_path = try std.fs.path.join(allocator, &.{ staging_dir, "build.zig.zon" });
    defer allocator.free(zon_path);
    const zon = try readFileContent(allocator, io, zon_path);
    defer allocator.free(zon);
    context.resolver_saw_missing_fingerprint =
        std.mem.indexOf(u8, zon, ".fingerprint") == null;

    return switch (context.mode) {
        .compile_failure, .compile_failure_on_stdout => null,
        .fingerprint_then_success, .fingerprint_then_failure => 0x81677af28f9d3b4e,
        .resolver_failure => error.FingerprintResolverFailed,
        .success_without_fingerprint => null,
    };
}

fn copyReportedOutput(destination: []u8, source: []const u8) usize {
    const kept = @min(destination.len, source.len);
    @memcpy(destination[0..kept], source[0..kept]);
    return kept;
}

/// Stand in for `printBuildFailure`, which writes to the process stderr a
/// test cannot read back.
fn recordBuildFailure(
    opaque_context: ?*anyopaque,
    result: *const BuildTestResult,
) void {
    const context: *PromotionTestContext = @ptrCast(@alignCast(opaque_context.?));
    context.report_calls += 1;
    context.reported_stdout_len = copyReportedOutput(&context.reported_stdout, result.stdout);
    context.reported_stderr_len = copyReportedOutput(&context.reported_stderr, result.stderr);
}

const GateModeTestContext = struct {
    allocator: std.mem.Allocator,
    flags: std.ArrayListUnmanaged([]const u8) = .empty,
    fail_flag: ?[]const u8 = null,
    fail_stderr: []const u8 = "",
};

fn fakeGateModeBuild(
    allocator: std.mem.Allocator,
    opaque_context: ?*anyopaque,
    flag: []const u8,
) anyerror!BuildTestResult {
    const context: *GateModeTestContext = @ptrCast(@alignCast(opaque_context.?));
    try context.flags.append(context.allocator, flag);
    const fails = if (context.fail_flag) |fail| std.mem.eql(u8, fail, flag) else false;
    const stdout = try allocator.dupe(u8, "");
    errdefer allocator.free(stdout);
    const stderr = try allocator.dupe(u8, if (fails) context.fail_stderr else "");
    return .{
        .term = .{ .exited = if (fails) 1 else 0 },
        .stdout = stdout,
        .stderr = stderr,
    };
}

test "promotion gate compiles the staged package in Debug and ReleaseSafe" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    var context = GateModeTestContext{ .allocator = allocator };
    defer context.flags.deinit(allocator);

    const result = try runGateOptimizeModes(allocator, fakeGateModeBuild, &context);
    defer releaseBuildTestResult(allocator, result);

    // Debug alone left every ReleaseSafe-only defect (elided
    // `std.debug.assert` guards, optimizer-exposed UB) unpublished.
    try std.testing.expectEqual(@as(usize, 2), context.flags.items.len);
    try std.testing.expectEqualStrings("-Doptimize=Debug", context.flags.items[0]);
    try std.testing.expectEqualStrings("-Doptimize=ReleaseSafe", context.flags.items[1]);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expectEqual(@as(?u64, null), try resolveFingerprint(
        allocator,
        test_io,
        null,
        "unused",
        &result,
    ));
}

test "promotion gate returns the first failing mode output without running later modes" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    var context = GateModeTestContext{
        .allocator = allocator,
        .fail_flag = "-Doptimize=Debug",
        .fail_stderr = "error: use this value: 0xdeadbeefcafebabe",
    };
    defer context.flags.deinit(allocator);

    const result = try runGateOptimizeModes(allocator, fakeGateModeBuild, &context);
    defer releaseBuildTestResult(allocator, result);

    // Running the second mode would repeat the same manifest fingerprint
    // hint, and `resolveFingerprint` rejects a hint it sees twice.
    try std.testing.expectEqual(@as(usize, 1), context.flags.items.len);
    try std.testing.expectEqual(@as(u8, 1), result.term.exited);
    try std.testing.expectEqual(
        @as(?u64, 0xdeadbeefcafebabe),
        try resolveFingerprint(allocator, test_io, null, "unused", &result),
    );
}

test "promotion gate fails when the package breaks only under ReleaseSafe" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    var context = GateModeTestContext{
        .allocator = allocator,
        .fail_flag = "-Doptimize=ReleaseSafe",
        .fail_stderr = "error: use of undeclared identifier 'undefined_value'",
    };
    defer context.flags.deinit(allocator);

    const result = try runGateOptimizeModes(allocator, fakeGateModeBuild, &context);
    defer releaseBuildTestResult(allocator, result);

    // Debug passed; the ReleaseSafe run is the only thing that catches this,
    // and its output carries no fingerprint hint, so promotion must report a
    // build failure rather than patch the manifest and re-run.
    try std.testing.expectEqual(@as(usize, 2), context.flags.items.len);
    try std.testing.expectEqualStrings("-Doptimize=ReleaseSafe", context.flags.items[1]);
    try std.testing.expectEqual(@as(u8, 1), result.term.exited);
    try std.testing.expectEqual(@as(?u64, null), try resolveFingerprint(
        allocator,
        test_io,
        null,
        "unused",
        &result,
    ));
}

fn expectDirectoryAbsent(io: std.Io, path: []const u8) !void {
    var dir = std.Io.Dir.cwd();
    const opened = dir.openDir(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    opened.close(io);
    return error.UnexpectedDirectory;
}

test "promotion compile failure keeps destination hidden and removes staging" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    const pkg = buildTestPackage();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    const out_dir = try std.fs.path.join(allocator, &.{ tmp_root, "published" });
    defer allocator.free(out_dir);
    var nonce: [promotion_nonce_len]u8 = undefined;
    @memset(&nonce, 0xa5);
    const staging_dir = try stagingPath(allocator, out_dir, nonce);
    defer allocator.free(staging_dir);

    var context: PromotionTestContext = .{
        .final_path = out_dir,
        .mode = .compile_failure,
    };
    try std.testing.expectError(
        error.GeneratedPackageBuildFailed,
        promoteWithHooks(allocator, test_io, &pkg, out_dir, .{
            .context = &context,
            .fill_nonce = fixedPromotionNonce,
            .run_build_test = fakePromotionBuildTest,
            .resolve_fingerprint = fakePromotionFingerprint,
        }),
    );

    try std.testing.expectEqual(@as(u32, 1), context.build_calls);
    try std.testing.expect(!context.destination_visible_during_build);
    try expectDirectoryAbsent(test_io, out_dir);
    try expectDirectoryAbsent(test_io, staging_dir);
}

test "promotion resolves a missing fingerprint before atomic publish" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    var pkg = buildTestPackage();
    pkg.fingerprint = null;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    const out_dir = try std.fs.path.join(allocator, &.{ tmp_root, "published" });
    defer allocator.free(out_dir);
    var nonce: [promotion_nonce_len]u8 = undefined;
    @memset(&nonce, 0xa5);
    const staging_dir = try stagingPath(allocator, out_dir, nonce);
    defer allocator.free(staging_dir);

    var context: PromotionTestContext = .{
        .final_path = out_dir,
        .mode = .fingerprint_then_success,
    };
    try promoteWithHooks(allocator, test_io, &pkg, out_dir, .{
        .context = &context,
        .fill_nonce = fixedPromotionNonce,
        .run_build_test = fakePromotionBuildTest,
        .resolve_fingerprint = fakePromotionFingerprint,
    });

    try std.testing.expectEqual(@as(u32, 2), context.build_calls);
    try std.testing.expectEqual(@as(u32, 1), context.resolver_calls);
    try std.testing.expect(context.resolver_saw_missing_fingerprint);
    try std.testing.expect(pkg.fingerprint == null);
    try std.testing.expect(!context.destination_visible_during_build);
    try expectDirectoryAbsent(test_io, staging_dir);

    const zon_path = try std.fs.path.join(allocator, &.{ out_dir, "build.zig.zon" });
    defer allocator.free(zon_path);
    const zon = try readFileContent(allocator, test_io, zon_path);
    defer allocator.free(zon);
    try std.testing.expect(
        std.mem.indexOf(u8, zon, ".fingerprint = 0x81677af28f9d3b4e") != null,
    );
}

test "promotion resolver failure keeps destination absent" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    var pkg = buildTestPackage();
    pkg.fingerprint = null;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    const out_dir = try std.fs.path.join(allocator, &.{ tmp_root, "published" });
    defer allocator.free(out_dir);
    var nonce: [promotion_nonce_len]u8 = undefined;
    @memset(&nonce, 0xa5);
    const staging_dir = try stagingPath(allocator, out_dir, nonce);
    defer allocator.free(staging_dir);

    var context: PromotionTestContext = .{
        .final_path = out_dir,
        .mode = .resolver_failure,
    };
    try std.testing.expectError(
        error.FingerprintResolverFailed,
        promoteWithHooks(allocator, test_io, &pkg, out_dir, .{
            .context = &context,
            .fill_nonce = fixedPromotionNonce,
            .run_build_test = fakePromotionBuildTest,
            .resolve_fingerprint = fakePromotionFingerprint,
        }),
    );

    try std.testing.expectEqual(@as(u32, 1), context.resolver_calls);
    try std.testing.expect(context.resolver_saw_missing_fingerprint);
    try expectDirectoryAbsent(test_io, out_dir);
    try expectDirectoryAbsent(test_io, staging_dir);
}

test "promotion rejects a final package without a fingerprint" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    var pkg = buildTestPackage();
    pkg.fingerprint = null;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    const out_dir = try std.fs.path.join(allocator, &.{ tmp_root, "published" });
    defer allocator.free(out_dir);
    var nonce: [promotion_nonce_len]u8 = undefined;
    @memset(&nonce, 0xa5);
    const staging_dir = try stagingPath(allocator, out_dir, nonce);
    defer allocator.free(staging_dir);

    var context: PromotionTestContext = .{
        .final_path = out_dir,
        .mode = .success_without_fingerprint,
    };
    try std.testing.expectError(
        error.MissingFingerprint,
        promoteWithHooks(allocator, test_io, &pkg, out_dir, .{
            .context = &context,
            .fill_nonce = fixedPromotionNonce,
            .run_build_test = fakePromotionBuildTest,
            .resolve_fingerprint = fakePromotionFingerprint,
        }),
    );

    try std.testing.expectEqual(@as(u32, 1), context.build_calls);
    try std.testing.expectEqual(@as(u32, 0), context.resolver_calls);
    try expectDirectoryAbsent(test_io, out_dir);
    try expectDirectoryAbsent(test_io, staging_dir);
}

test "promotion reports the compiler output when the first build fails" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    const pkg = buildTestPackage();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    const out_dir = try std.fs.path.join(allocator, &.{ tmp_root, "published" });
    defer allocator.free(out_dir);
    var nonce: [promotion_nonce_len]u8 = undefined;
    @memset(&nonce, 0xa5);
    const staging_dir = try stagingPath(allocator, out_dir, nonce);
    defer allocator.free(staging_dir);

    var context: PromotionTestContext = .{
        .final_path = out_dir,
        .mode = .compile_failure,
    };
    try std.testing.expectError(
        error.GeneratedPackageBuildFailed,
        promoteWithHooks(allocator, test_io, &pkg, out_dir, .{
            .context = &context,
            .fill_nonce = fixedPromotionNonce,
            .run_build_test = fakePromotionBuildTest,
            .resolve_fingerprint = fakePromotionFingerprint,
            .report_build_failure = recordBuildFailure,
        }),
    );

    // The first pass is the real build, and it is the pass a one-pass compile
    // error dies on. It used to return a bare error with the compiler's
    // output discarded, so a silent emission defect was only findable by
    // hand-compiling the generated package. The error value is unchanged.
    try std.testing.expectEqual(@as(u32, 1), context.build_calls);
    try std.testing.expectEqual(@as(u32, 1), context.report_calls);
    try std.testing.expectEqualStrings(
        "generated source does not compile",
        context.reported_stderr[0..context.reported_stderr_len],
    );
    try expectDirectoryAbsent(test_io, staging_dir);
}

test "promotion reports compiler output that arrives on stdout" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    const pkg = buildTestPackage();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    const out_dir = try std.fs.path.join(allocator, &.{ tmp_root, "published" });
    defer allocator.free(out_dir);
    var nonce: [promotion_nonce_len]u8 = undefined;
    @memset(&nonce, 0xa5);
    const staging_dir = try stagingPath(allocator, out_dir, nonce);
    defer allocator.free(staging_dir);

    var context: PromotionTestContext = .{
        .final_path = out_dir,
        .mode = .compile_failure_on_stdout,
    };
    try std.testing.expectError(
        error.GeneratedPackageBuildFailed,
        promoteWithHooks(allocator, test_io, &pkg, out_dir, .{
            .context = &context,
            .fill_nonce = fixedPromotionNonce,
            .run_build_test = fakePromotionBuildTest,
            .resolve_fingerprint = fakePromotionFingerprint,
            .report_build_failure = recordBuildFailure,
        }),
    );

    // `resolveFingerprint` reads both streams for its hint, so a hint can
    // arrive on either one. A failing build that writes nothing to stderr
    // still has to say something.
    try std.testing.expectEqual(@as(u32, 1), context.report_calls);
    try std.testing.expectEqualStrings(
        "error: use of undeclared identifier 'undefined_value'",
        context.reported_stdout[0..context.reported_stdout_len],
    );
    try std.testing.expectEqual(@as(usize, 0), context.reported_stderr_len);
    try expectDirectoryAbsent(test_io, staging_dir);
}

test "promotion reports the compiler output of a retried build once" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    var pkg = buildTestPackage();
    pkg.fingerprint = null;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    const out_dir = try std.fs.path.join(allocator, &.{ tmp_root, "published" });
    defer allocator.free(out_dir);
    var nonce: [promotion_nonce_len]u8 = undefined;
    @memset(&nonce, 0xa5);
    const staging_dir = try stagingPath(allocator, out_dir, nonce);
    defer allocator.free(staging_dir);

    var context: PromotionTestContext = .{
        .final_path = out_dir,
        .mode = .fingerprint_then_failure,
    };
    try std.testing.expectError(
        error.GeneratedPackageBuildFailed,
        promoteWithHooks(allocator, test_io, &pkg, out_dir, .{
            .context = &context,
            .fill_nonce = fixedPromotionNonce,
            .run_build_test = fakePromotionBuildTest,
            .resolve_fingerprint = fakePromotionFingerprint,
            .report_build_failure = recordBuildFailure,
        }),
    );

    // The manifest patch pass is not a defect: it is a fingerprint hint the
    // resolver consumes. The retried build is, so its output is reported
    // once, and the hint pass stays quiet.
    try std.testing.expectEqual(@as(u32, 2), context.build_calls);
    try std.testing.expectEqual(@as(u32, 1), context.report_calls);
    try std.testing.expectEqualStrings(
        "optimized build still rejects the generated source",
        context.reported_stderr[0..context.reported_stderr_len],
    );
    try expectDirectoryAbsent(test_io, out_dir);
    try expectDirectoryAbsent(test_io, staging_dir);
}

test "promotion reports nothing when the build passes" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    var pkg = buildTestPackage();
    pkg.fingerprint = null;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    const out_dir = try std.fs.path.join(allocator, &.{ tmp_root, "published" });
    defer allocator.free(out_dir);
    var nonce: [promotion_nonce_len]u8 = undefined;
    @memset(&nonce, 0xa5);
    const staging_dir = try stagingPath(allocator, out_dir, nonce);
    defer allocator.free(staging_dir);

    var context: PromotionTestContext = .{
        .final_path = out_dir,
        .mode = .fingerprint_then_success,
    };
    try promoteWithHooks(allocator, test_io, &pkg, out_dir, .{
        .context = &context,
        .fill_nonce = fixedPromotionNonce,
        .run_build_test = fakePromotionBuildTest,
        .resolve_fingerprint = fakePromotionFingerprint,
        .report_build_failure = recordBuildFailure,
    });

    // A first pass that fails only to hand the resolver a fingerprint hint is
    // part of a successful promotion, so it must not print a build failure.
    try std.testing.expectEqual(@as(u32, 2), context.build_calls);
    try std.testing.expectEqual(@as(u32, 1), context.resolver_calls);
    try std.testing.expectEqual(@as(u32, 0), context.report_calls);
    try expectDirectoryAbsent(test_io, staging_dir);
}
