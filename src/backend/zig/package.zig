//! translate_rust.backend.zig.package — package writer and promotion boundary.
//! Renders an `ast.Package` to a complete standalone Zig package directory:
//! build.zig, build.zig.zon, every `pkg.files[i]` source file, and — for a
//! package whose sources import the Rust-core runtime — the whole `r2z-core`
//! package vendored under `r2z-core/`. Promotion stages all output, validates
//! and tests it, then publishes it atomically.

const std = @import("std");
const ast = @import("ast.zig");
const emit = @import("emit.zig");
const runtime_assets = @import("r2z_core_assets");

/// The compiler running this build, resolved once by build.zig. Promotion
/// builds and tests the generated package with it, so the gate is reproducible
/// and never depends on a `zig` that PATH happens to name: the anyzig shim
/// fails silently outside a checkout that pins a version.
const zig_executable = @import("toolchain").zig_executable;

// ---------------------------------------------------------------------------
// Package name helpers
// ---------------------------------------------------------------------------

/// Resolve the package's own build module name.
fn packageIdName(pkg: *const ast.Package) []const u8 {
    return pkg.name;
}

// ── The vendored runtime ───────────────────────────────────────────────

/// The module a lowered package imports to reach the Rust-core runtime.
const runtime_module_name = "r2z";

/// The dependency name and vendored directory of that runtime. One string
/// serves both, because in Zig the dependency's `.path` *is* the directory it
/// resolves to.
const runtime_directory = runtime_assets.directory;
const runtime_dependency_name = runtime_assets.directory;

fn dependencyModuleName(dep_name: []const u8) []const u8 {
    return if (std.mem.eql(u8, dep_name, runtime_dependency_name))
        runtime_module_name
    else
        dep_name;
}

/// Whether the writer, rather than the caller, supplies the runtime: no
/// declared dependency already claims the name, and some source file imports
/// `r2z`.
///
/// A caller that declares the dependency itself keeps whatever path it
/// declared. Resolving that path, or overwriting it, would be the writer
/// rewriting a decision the caller already made.
fn needsVendoredRuntime(pkg: *const ast.Package) bool {
    for (pkg.zon_deps) |dep| {
        if (std.mem.eql(u8, dep.name, runtime_dependency_name)) return false;
    }
    for (pkg.files) |file| {
        for (file.imports) |import| {
            if (std.mem.eql(u8, import.module_or_path, runtime_module_name)) return true;
        }
    }
    return false;
}

/// The package plus what the writer added to it. `vendored_runtime` is the one
/// fact manifest emission needs and the package itself can no longer answer:
/// once the dependency is appended, the augmented package declares a runtime
/// it does not ship.
///
/// `appendRuntimeDependency` allocates its dependency slice from the caller's
/// allocator, so that allocator owns everything reachable from `pkg`.
const RuntimeWiring = struct {
    pkg: ast.Package,
    vendored_runtime: bool,
};

fn appendRuntimeDependency(
    allocator: std.mem.Allocator,
    pkg: *const ast.Package,
) !RuntimeWiring {
    if (!needsVendoredRuntime(pkg)) {
        return .{ .pkg = pkg.*, .vendored_runtime = false };
    }
    const deps = try allocator.alloc(ast.ZonDep, pkg.zon_deps.len + 1);
    @memcpy(deps[0..pkg.zon_deps.len], pkg.zon_deps);
    // The runtime ships inside the package, so the path is the one directory
    // name that is always there. Resolving a checkout at write time made the
    // manifest name an absolute path *outside* the package, which is why a
    // copied generated directory could not find it.
    deps[pkg.zon_deps.len] = .{
        .name = runtime_dependency_name,
        .path = runtime_directory,
    };
    var result = pkg.*;
    result.zon_deps = deps;
    return .{ .pkg = result, .vendored_runtime = true };
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

/// The compiler's package name is a fixed-width enum, so `build.zig.zon`
/// refuses any `.name` past this many bytes before the package is configured
/// at all. A legal Rust crate name can be longer, so the writer has to shorten
/// it rather than emit a manifest that cannot be read.
const zon_name_max_len = 32;

/// Hex digits of Wyhash appended to a shortened package name. They, the `_`
/// that separates them from the prefix, and the prefix itself split the same
/// 32-byte budget, so the `{x:0>8}` in `zonPackageName` and this width are one
/// number written twice.
const zon_hash_len = 8;

/// Sanitize a crate name into a package name the compiler will accept.
///
/// Sanitization alone is not enough: `zonIdentName` maps one byte to one byte,
/// so a 33-byte crate name still yields a 33-byte name. Cutting on length
/// alone would map two crates that share a prefix onto one package identity,
/// which is worse than the original failure — the second crate to reach the
/// package cache would silently overwrite the first. The dropped tail is
/// therefore replaced by a hash of the *whole* sanitized name, the byte string
/// actually being shortened. The hash is a pure function of that input
/// because the manifest is regenerated on every promotion and compared byte
/// for byte against golden text.
fn zonPackageName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const sanitized = try zonIdentName(allocator, name);
    defer allocator.free(sanitized);
    if (sanitized.len <= zon_name_max_len) return allocator.dupe(u8, sanitized);
    // Wyhash returns 64 bits and `{x:0>8}` is a minimum width, so the full
    // value can render as 16 digits and overrun the buffer. The low half is
    // as well mixed as the whole after Wyhash's final avalanche.
    const hash: u32 = @truncate(std.hash.Wyhash.hash(0, sanitized));
    var out: [zon_name_max_len]u8 = undefined;
    const prefix = sanitized[0 .. zon_name_max_len - zon_hash_len - 1];
    const text = try std.fmt.bufPrint(&out, "{s}_{x:0>8}", .{ prefix, hash });
    return allocator.dupe(u8, text);
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
            \\    ) orelse switch (b.graph.release_mode) {{
            \\        .off, .any => .safe,
            \\        .fast => .fast,
            \\        .safe => .safe,
            \\        .small => .small,
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
            \\    //
            \\    // The promotion gate drives this package through two invocations
            \\    // per optimize mode: `check` compiles it and `test` runs it.
            \\    // Depending on the artifacts' own compile steps is what makes
            \\    // the first one a build-only gate, so a non-zero exit from the
            \\    // second is known to be a runtime failure rather than a source
            \\    // that never compiled. Without this step the two are one
            \\    // invocation, and a package that only compiles is a package
            \\    // nobody has run.
            \\    const check_step = b.step("check", "Compile the package and its tests without running them");
            \\    check_step.dependOn(&lib.step);
            \\    check_step.dependOn(&tests.step);
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
        // Every dependency is a Zig package that may build for a target and
        // an optimize mode of its own. Without these, a dependency keeps the
        // defaults its own `standardTargetOptions`/`standardOptimizeOption`
        // produce: the vendored runtime stayed Debug in a ReleaseFast consumer
        // and stayed native in a cross-compiled one, so what a consumer
        // compiled was not what it ran.
        try appendFmt(
            "    const {s} = b.dependency(\"{s}\", .{{ .target = target, .optimize = optimize }});\n",
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
        \\    ) orelse switch (b.graph.release_mode) {{
        \\        .off, .any => .safe,
        \\        .fast => .fast,
        \\        .safe => .safe,
        \\        .small => .small,
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
        \\    //
        \\    // The promotion gate drives this package through two invocations
        \\    // per optimize mode: `check` compiles it and `test` runs it.
        \\    // Depending on the artifacts' own compile steps is what makes
        \\    // the first one a build-only gate, so a non-zero exit from the
        \\    // second is known to be a runtime failure rather than a source
        \\    // that never compiled. Without this step the two are one
        \\    // invocation, and a package that only compiles is a package
        \\    // nobody has run.
        \\    const check_step = b.step("check", "Compile the package and its tests without running them");
        \\    check_step.dependOn(&lib.step);
        \\    check_step.dependOn(&tests.step);
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

/// Render `wiring.pkg` as a `build.zig.zon`.
///
/// `wiring` rather than the bare package: `.paths` has to list the vendored
/// runtime, and only `wiring` can still tell a runtime this package *ships*
/// from one it merely declares a dependency on.
fn generateBuildZigZon(
    allocator: std.mem.Allocator,
    wiring: RuntimeWiring,
) ![]const u8 {
    const pkg = &wiring.pkg;
    try validatePackageShape(pkg);
    const zon_name = try zonPackageName(allocator, packageIdName(pkg));
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
                \\    .minimum_zig_version = "0.17.0",
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
            \\    .minimum_zig_version = "0.17.0",
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
    try buf.appendSlice(allocator, "    .minimum_zig_version = \"0.17.0\",\n");
    try buf.appendSlice(allocator, "    .dependencies = .{\n");
    for (pkg.zon_deps) |dep| {
        const dep_id = try zonIdentName(allocator, dep.name);
        defer allocator.free(dep_id);
        try buf.appendSlice(allocator, "        .");
        try buf.appendSlice(allocator, dep_id);
        try buf.appendSlice(allocator, " = .{ ");
        if (dep.path) |path| {
            // The path a caller declared is the path they meant. The writer
            // resolves nothing here and rewrites nothing here: the runtime it
            // supplies is already vendored inside the package under exactly
            // the name it declares, so a generated package has no dependency
            // that reaches outside itself.
            try buf.appendSlice(allocator, ".path = \"");
            try buf.appendSlice(allocator, path);
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
    if (wiring.vendored_runtime) {
        // Listing a directory that is not shipped would let the package cache
        // drop it; omitting one that is would make the package it is fetched
        // as unable to resolve its own runtime dependency.
        try buf.appendSlice(allocator, "        \"");
        try buf.appendSlice(allocator, runtime_directory);
        try buf.appendSlice(allocator, "\",\n");
    }
    try buf.appendSlice(allocator, "    },\n");
    try buf.appendSlice(allocator, "}\n");

    return buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Package writer
// ---------------------------------------------------------------------------

/// Write an `ast.Package` to a staging directory: build.zig, build.zig.zon,
/// every `pkg.files[i]` rendered via `emit.emitFile`, and the vendored runtime
/// when the package uses one.
///
/// Everything lands before the caller verifies anything, so a staged package
/// is complete or the promotion fails.
fn writeToDisk(io: std.Io, pkg: *const ast.Package, staging_dir: []const u8) !void {
    try validatePackageShape(pkg);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var dir = std.Io.Dir.cwd();
    try dir.createDirPath(io, staging_dir);

    const wiring = try appendRuntimeDependency(allocator, pkg);

    // 1. build.zig
    const build_zig = try generateBuildZig(allocator, &wiring.pkg);
    try writeFile(allocator, io, staging_dir, "build.zig", build_zig);

    // 2. build.zig.zon
    const build_zig_zon = try generateBuildZigZon(allocator, wiring);
    try writeFile(allocator, io, staging_dir, "build.zig.zon", build_zig_zon);

    // 3. Source files
    for (pkg.files) |file| {
        const content = try emit.emitFile(allocator, &file);
        try writeFile(allocator, io, staging_dir, file.path, content);
    }

    // 4. The vendored runtime, straight out of the translator's image. Each
    // asset is one write of bytes that are already in memory: no parse, no
    // staged copy, no per-file scratch beyond the joined path.
    if (wiring.vendored_runtime) {
        try writeVendoredRuntime(allocator, io, staging_dir);
    }
}

fn writeVendoredRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    staging_dir: []const u8,
) !void {
    if (runtime_assets.license) |license| {
        try writeFile(allocator, io, staging_dir, license.path, license.contents);
    }
    for (runtime_assets.files) |file| {
        try writeFile(allocator, io, staging_dir, file.path, file.contents);
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
    GeneratedPackageRunFailed,
    InvalidOutputDirectory,
    InvalidGeneratedManifest,
    InvalidGeneratedSource,
    StagingPathExhausted,
    StagingCleanupFailed,
};

/// Which half of the promotion gate a result came from.
///
/// The gate drives the staged package through two invocations per optimize
/// mode: one that compiles it and one that runs it. `zig build test` alone
/// cannot tell the two apart — it compiles and runs in one process, so a
/// source that never compiled and a test that aborted at runtime both arrive
/// as the same non-zero exit. Those are different defects: the first is in
/// what the emitter wrote, the second is in what the emitted code does, and
/// a caller that has to choose between them cannot while both arrive as
/// `GeneratedPackageBuildFailed`.
pub const GatePhase = enum {
    /// The package, its test artifact included, was compiled and not run.
    compile,
    /// The package compiled, and the test binary then failed to run clean.
    run,
};

pub const BuildTestResult = struct {
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
    /// The gate phase this result came from. `compile` is the default so a
    /// hook that reports only a process outcome is read as the failure it
    /// always was before the gate had phases.
    phase: GatePhase = .compile,
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

/// Sink for the output of a staged gate run that did not pass. Split out of
/// `promoteWithHooks` so a test can read the diagnostics a user sees. The
/// result carries the phase that failed, which is what lets the message say
/// "build" or "run" instead of one word for both.
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

/// The error a gate failure raises. A package that never compiled and a package
/// that compiled and then aborted are different facts about the translator,
/// so they are different errors.
fn gateFailure(phase: GatePhase) anyerror {
    return switch (phase) {
        .compile => error.GeneratedPackageBuildFailed,
        .run => error.GeneratedPackageRunFailed,
    };
}

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
    // A vendored runtime is as load-bearing as a translated source file: the
    // package cannot resolve its own dependency without it. The question is
    // asked of `pkg`, the package the writer was handed, because the staged
    // manifest now declares the dependency whether or not the writer added it.
    if (needsVendoredRuntime(pkg)) {
        if (runtime_assets.license) |license| {
            try validateStagedFile(allocator, io, staging_dir, license.path);
        }
        for (runtime_assets.files) |file| {
            try validateStagedFile(allocator, io, staging_dir, file.path);
        }
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
    "-Doptimize=debug",
    "-Doptimize=safe",
};

/// The build-system step each gate phase runs. `check` compiles the staged
/// package and its test artifact; `test` does the same and then runs the
/// artifact. Both are emitted by `generateBuildZig`.
const gate_phases = [_]GatePhase{ .compile, .run };

fn gateStepName(phase: GatePhase) []const u8 {
    return switch (phase) {
        .compile => "check",
        .run => "test",
    };
}

const RunGateMode = *const fn (
    allocator: std.mem.Allocator,
    context: ?*anyopaque,
    phase: GatePhase,
    flag: []const u8,
) anyerror!BuildTestResult;

/// Compile and run the staged package once per optimize mode. Every mode gets
/// both phases, so a package that compiles is also run before it is published.
/// The first failure is returned unchanged apart from the phase it came from: a
/// second run would repeat the same manifest fingerprint hint, and
/// `resolveFingerprint` rejects a hint it sees twice.
fn runGateOptimizeModes(
    allocator: std.mem.Allocator,
    run_mode: RunGateMode,
    context: ?*anyopaque,
) anyerror!BuildTestResult {
    for (promotion_optimize_flags) |flag| {
        for (gate_phases) |phase| {
            var result = try run_mode(allocator, context, phase, flag);
            if (result.term == .exited and result.term.exited == 0) {
                releaseBuildTestResult(allocator, result);
                continue;
            }
            // The phase is a property of which invocation failed, not of what
            // the runner chooses to report, so the loop stamps it.
            result.phase = phase;
            return result;
        }
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
    phase: GatePhase,
    flag: []const u8,
) anyerror!BuildTestResult {
    const context: *GeneratedGateContext = @ptrCast(@alignCast(opaque_context.?));
    const result = try std.process.run(allocator, context.io, .{
        .argv = &.{ zig_executable, "build", gateStepName(phase), flag },
        .cwd = .{ .path = context.staging_dir },
    });
    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .phase = phase,
    };
}

fn runGeneratedBuildTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    _: ?*anyopaque,
    staging_dir: []const u8,
) anyerror!BuildTestResult {
    var context: GeneratedGateContext = .{
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

/// Report a staged gate run that did not pass. The child's own output is the
/// only diagnostic a promotion failure carries, and it is reported on every
/// failing pass: the retry pass always did, the first pass dropped it, so a
/// one-pass compile error surfaced as a bare error with no message at all.
/// The phase decides the word, because a runtime abort and a source that does
/// not compile are not the same failure to read about.
fn printBuildFailure(_: ?*anyopaque, result: *const BuildTestResult) void {
    const label = switch (result.phase) {
        .compile => "generated package build failed",
        .run => "generated package run failed",
    };
    var reported = false;
    if (hasCapturedOutput(result.stdout)) {
        std.debug.print("{s} (stdout):\n{s}\n", .{ label, result.stdout });
        reported = true;
    }
    if (hasCapturedOutput(result.stderr)) {
        std.debug.print("{s}:\n{s}\n", .{ label, result.stderr });
        reported = true;
    }
    if (!reported) {
        std.debug.print("{s}: no output captured\n", .{label});
    }
}

/// True when a captured stream carries anything but whitespace.
fn hasCapturedOutput(bytes: []const u8) bool {
    return std.mem.trim(u8, bytes, " \t\r\n").len != 0;
}

/// Whether `candidate` is the staging directory this promotion created beside
/// `out_dir`, and not a directory the caller owns.
///
/// `stagingPath` names that directory `.{basename}.staging.{32 hex digits}`
/// inside `dirname(out_dir)`, so every directory this promotion creates matches
/// this shape and nothing else beside `out_dir` does. `deleteTree` is
/// recursive, so the check is the difference between removing this run's own
/// scratch space and removing whatever the caller pointed at: `out_dir`
/// itself, a sibling named by the caller, or a directory some other run owns.
fn isStagingSiblingOf(out_dir: []const u8, candidate: []const u8) bool {
    if (std.mem.eql(u8, out_dir, candidate)) return false;
    const out_parent = std.fs.path.dirname(out_dir) orelse "";
    const candidate_parent = std.fs.path.dirname(candidate) orelse "";
    if (!std.mem.eql(u8, out_parent, candidate_parent)) return false;
    var prefix_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prefix = std.fmt.bufPrint(
        &prefix_buf,
        ".{s}.staging.",
        .{std.fs.path.basename(out_dir)},
    ) catch return false;
    const name = std.fs.path.basename(candidate);
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    const nonce_hex = name[prefix.len..];
    if (nonce_hex.len != promotion_nonce_len * 2) return false;
    for (nonce_hex) |character| {
        // `stagingPath` writes the nonce with `bytesToHex(..., .lower)`, so an
        // uppercase digit is in a name this promotion did not create.
        // `isHex` accepts both cases, and a name that merely looks like this
        // run's scratch space belongs to some other run or to the caller.
        if (!std.ascii.isHex(character) or std.ascii.isUpper(character)) return false;
    }
    return true;
}

/// Remove the staging tree of a promotion that failed, and keep the failure.
///
/// A failed promotion must not leave a package directory behind, so the tree
/// goes first. `deleteTree` was allowed to raise, which replaced the real
/// diagnosis with a filesystem error and left the debris unnamed: the operator
/// was told the staging directory could not be touched and nothing about the
/// source that could not be compiled. Now the debris is named on stderr and
/// the promotion's own error still reaches the caller.
fn cleanupPromotion(
    io: std.Io,
    out_dir: []const u8,
    staging_dir: []const u8,
    primary_error: anyerror,
) anyerror {
    // Never hand a recursive delete a path this promotion did not create.
    if (!isStagingSiblingOf(out_dir, staging_dir)) return primary_error;
    var dir = std.Io.Dir.cwd();
    // `deleteTree` already treats an absent path as the outcome this function
    // exists to reach: `deleteTreeOpenInitialSubpath` answers null and the
    // call returns success. So there is no "not found" arm to write — naming
    // one would not compile, because `DeleteTreeError` has no such member, and
    // every real failure below is one an operator has to hear about.
    dir.deleteTree(io, staging_dir) catch |failure| {
        std.debug.print(
            "generated package promotion failed ({s}) and its staging directory {s} could not be removed ({s}); that directory holds an unpublished partial package, so remove it before promoting again\n",
            .{ @errorName(primary_error), staging_dir, @errorName(failure) },
        );
        return error.StagingCleanupFailed;
    };
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

    writeToDisk(io, pkg, staging_dir) catch |err|
        return cleanupPromotion(io, out_dir, staging_dir, err);
    validateStagedPackage(
        allocator,
        io,
        pkg,
        staging_dir,
        pkg.fingerprint,
        false,
    ) catch |err| return cleanupPromotion(io, out_dir, staging_dir, err);

    var build_result = hooks.run_build_test(allocator, io, hooks.context, staging_dir) catch |err|
        return cleanupPromotion(io, out_dir, staging_dir, err);
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
                    out_dir,
                    staging_dir,
                    gateFailure(build_result.phase),
                );
            },
        }
        // A run failure is not a hint that the manifest is wrong. Patching and
        // re-running would execute the same tests again and then report a
        // build failure, which is the one thing this split exists to stop: the
        // package compiled, and what it does at runtime is what failed.
        if (build_result.phase == .run or fingerprint_patched) {
            hooks.report_build_failure(hooks.context, &build_result);
            releaseBuildTestResult(allocator, build_result);
            return cleanupPromotion(
                io,
                out_dir,
                staging_dir,
                gateFailure(build_result.phase),
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
            return cleanupPromotion(io, out_dir, staging_dir, err);
        };
        const resolved_fingerprint = fingerprint orelse {
            hooks.report_build_failure(hooks.context, &build_result);
            releaseBuildTestResult(allocator, build_result);
            return cleanupPromotion(io, out_dir, staging_dir, error.GeneratedPackageBuildFailed);
        };
        releaseBuildTestResult(allocator, build_result);
        patchManifestFingerprint(
            allocator,
            io,
            staging_dir,
            resolved_fingerprint,
        ) catch |err| return cleanupPromotion(io, out_dir, staging_dir, err);
        final_fingerprint = resolved_fingerprint;
        fingerprint_patched = true;
        build_result = hooks.run_build_test(allocator, io, hooks.context, staging_dir) catch |err|
            return cleanupPromotion(io, out_dir, staging_dir, err);
    }
    releaseBuildTestResult(allocator, build_result);
    validateStagedPackage(
        allocator,
        io,
        pkg,
        staging_dir,
        final_fingerprint,
        true,
    ) catch |err| return cleanupPromotion(io, out_dir, staging_dir, err);

    publishStagedPackage(io, staging_dir, out_dir) catch |err|
        return cleanupPromotion(io, out_dir, staging_dir, err);
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

/// A package whose root imports the `r2z` module, which is what makes the
/// writer responsible for shipping the runtime. The declaration is incidental;
/// it only keeps the fixture on the real code path, since a root that declares
/// nothing is rejected before it is written.
fn buildRuntimeTestPackage() ast.Package {
    const marker_decl: ast.Decl = .{ .const_decl = .{
        .name = "MARKER",
        .init = ast.Expr{ .lit = .{ .int = 1 } },
    } };
    return .{
        .name = "demo",
        .files = &.{.{
            .path = "src/root.zig",
            .imports = &.{
                .{ .local_name = "std", .module_or_path = "std" },
                .{ .local_name = "r2z", .module_or_path = "r2z" },
            },
            .decls = &.{marker_decl},
        }},
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
    const pkg = buildRuntimeTestPackage();
    const wiring = try appendRuntimeDependency(allocator, &pkg);
    // The only thing `appendRuntimeDependency` allocates; the rest of this test
    // frees what it takes explicitly.
    defer allocator.free(wiring.pkg.zon_deps);
    try std.testing.expect(wiring.vendored_runtime);
    try std.testing.expectEqualStrings(runtime_dependency_name, wiring.pkg.zon_deps[0].name);
    try std.testing.expectEqualStrings(runtime_directory, wiring.pkg.zon_deps[0].path.?);

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
    // The dependency resolves inside the package it belongs to. A path naming
    // anything outside it is exactly what made a copied generated directory
    // report its runtime as missing.
    try std.testing.expect(
        std.mem.indexOf(u8, zon, ".r2z_core = .{ .path = \"r2z-core\" }") != null,
    );
}

/// Render the manifest for a package called `name` and hand back the `.name`
/// enum literal the writer emitted, copied out so the caller owns the buffer.
fn zonNameLineFor(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    // The writer validates the package shape it is handed, so the fixture
    // needs a real root file even though only its name is under test.
    const marker_decl: ast.Decl = .{ .const_decl = .{
        .name = "MARKER",
        .init = ast.Expr{ .lit = .{ .int = 1 } },
    } };
    const pkg: ast.Package = .{
        .name = name,
        .version = "1.2.3",
        .fingerprint = 0xabcd,
        .files = &.{.{
            .path = "src/root.zig",
            .imports = &.{.{ .local_name = "std", .module_or_path = "std" }},
            .decls = &.{marker_decl},
        }},
    };
    const zon = try generateBuildZigZon(allocator, try appendRuntimeDependency(allocator, &pkg));
    defer allocator.free(zon);
    const marker = "    .name = .";
    const start = std.mem.indexOf(u8, zon, marker) orelse
        return error.InvalidGeneratedManifest;
    const rest = zon[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse
        return error.InvalidGeneratedManifest;
    return allocator.dupe(u8, std.mem.trimEnd(u8, rest[0..end], ","));
}

test "generateBuildZigZon: a name that exactly fills the package name budget is emitted verbatim" {
    const allocator = std.testing.allocator;
    // 32 bytes is the whole of the compiler's package name enum. A name that
    // fits has no tail to trade away, so shortening it here would rename a
    // package that already builds under the name its consumer expects.
    const name = "r4_control_guard_labeled_continu";
    try std.testing.expectEqual(zon_name_max_len, name.len);

    const emitted = try zonNameLineFor(allocator, name);
    defer allocator.free(emitted);
    try std.testing.expectEqualStrings(name, emitted);
}

test "generateBuildZigZon: a name past the package name budget is shortened to a readable prefix" {
    const allocator = std.testing.allocator;
    // The unrepaired writer emitted this 33-byte name verbatim and produced a
    // package that could not even be configured, so a legal Rust crate name
    // translated to nothing at all.
    const emitted = try zonNameLineFor(allocator, "r4_control_guard_labeled_continue");
    defer allocator.free(emitted);

    // The budget is filled exactly. One byte over is what the compiler
    // rejects; the room left is what pays for the discriminator.
    try std.testing.expectEqual(@as(usize, 32), emitted.len);
    // Only the tail changes: the readable head of the crate name is still
    // there, and what replaces the dropped tail is the discriminator.
    const prefix_len = zon_name_max_len - zon_hash_len - 1;
    try std.testing.expectEqualStrings(
        "r4_control_guard_labeled_continue"[0..prefix_len],
        emitted[0..prefix_len],
    );
    try std.testing.expectEqual(
        @as(u8, '_'),
        emitted[emitted.len - zon_hash_len - 1],
    );
}

test "generateBuildZigZon: two long names sharing a prefix stay distinct packages" {
    const allocator = std.testing.allocator;
    // Cutting on length alone would give both crates one identity, and the
    // second to reach the package cache would overwrite the first build.
    const first_name = "r4_control_guard_labeled_continue";
    const second_name = "r4_control_guard_labeled_continue2";

    // The two crate names agree on every byte the 32-byte budget can hold, so
    // the discriminator is the only thing that can keep them apart.
    try std.testing.expectEqualStrings(
        "r4_control_guard_labeled_continu",
        first_name[0..zon_name_max_len],
    );
    try std.testing.expectEqualStrings(
        first_name[0..zon_name_max_len],
        second_name[0..zon_name_max_len],
    );

    const first = try zonNameLineFor(allocator, first_name);
    defer allocator.free(first);
    const second = try zonNameLineFor(allocator, second_name);
    defer allocator.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "generateBuildZigZon: shortening one long name twice is byte-identical" {
    const allocator = std.testing.allocator;
    // Promotion rewrites the manifest on every run and golden files compare it
    // verbatim, so the discriminator may not drift between invocations.
    const first = try zonNameLineFor(allocator, "r4_control_guard_labeled_continue");
    defer allocator.free(first);
    const second = try zonNameLineFor(allocator, "r4_control_guard_labeled_continue");
    defer allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expectEqual(@as(usize, 32), first.len);
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
    run_failure,
    fingerprint_then_success,
    fingerprint_then_failure,
    fingerprint_then_run_failure,
    resolver_failure,
    success_without_fingerprint,
};

const reported_output_capacity = 256;

/// What a generated package's test binary writes when the emitted code
/// misbehaves at runtime rather than failing to compile.
const run_panic_text = "thread 1 panicked at root.zig:1: reached unreachable code";

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
    reported_phase: GatePhase = .compile,
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
        .run_failure => run_panic_text,
        .fingerprint_then_success, .resolver_failure => if (context.build_calls == 1)
            "fingerprint: 0x81677af28f9d3b4e"
        else
            "",
        .fingerprint_then_failure => if (context.build_calls == 1)
            "fingerprint: 0x81677af28f9d3b4e"
        else
            "optimized build still rejects the generated source",
        .fingerprint_then_run_failure => if (context.build_calls == 1)
            "fingerprint: 0x81677af28f9d3b4e"
        else
            run_panic_text,
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
        .run_failure, .fingerprint_then_run_failure => 1,
        .success_without_fingerprint => 0,
    };
    const phase: GatePhase = switch (context.mode) {
        // A run failure from the first pass: the package compiled and the
        // run that followed it aborted.
        .run_failure => .run,
        // Two passes: the first is the compile that hands the resolver its
        // manifest hint, the second is the run that aborts.
        .fingerprint_then_run_failure => if (context.build_calls == 1) .compile else .run,
        else => .compile,
    };
    const stdout = try allocator.dupe(u8, stdout_text);
    errdefer allocator.free(stdout);
    const stderr_copy = try allocator.dupe(u8, stderr);
    return .{
        .term = .{ .exited = exit_code },
        .stdout = stdout,
        .stderr = stderr_copy,
        .phase = phase,
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
        .compile_failure, .compile_failure_on_stdout, .run_failure => null,
        .fingerprint_then_success,
        .fingerprint_then_failure,
        .fingerprint_then_run_failure,
        => 0x81677af28f9d3b4e,
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
    context.reported_phase = result.phase;
}

const GateModeTestContext = struct {
    allocator: std.mem.Allocator,
    flags: std.ArrayListUnmanaged([]const u8) = .empty,
    phases: std.ArrayListUnmanaged(GatePhase) = .empty,
    fail_flag: ?[]const u8 = null,
    fail_phase: ?GatePhase = null,
    fail_stderr: []const u8 = "",
};

fn fakeGateModeBuild(
    allocator: std.mem.Allocator,
    opaque_context: ?*anyopaque,
    phase: GatePhase,
    flag: []const u8,
) anyerror!BuildTestResult {
    const context: *GateModeTestContext = @ptrCast(@alignCast(opaque_context.?));
    try context.flags.append(context.allocator, flag);
    try context.phases.append(context.allocator, phase);
    const flag_fails = if (context.fail_flag) |fail| std.mem.eql(u8, fail, flag) else false;
    const phase_fails = if (context.fail_phase) |fail| fail == phase else false;
    const fails = flag_fails or phase_fails;
    const stdout = try allocator.dupe(u8, "");
    errdefer allocator.free(stdout);
    const stderr = try allocator.dupe(u8, if (fails) context.fail_stderr else "");
    return .{
        .term = .{ .exited = if (fails) 1 else 0 },
        .stdout = stdout,
        .stderr = stderr,
    };
}

test "promotion gate compiles and runs the staged package in Debug and ReleaseSafe" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    var context: GateModeTestContext = .{ .allocator = allocator };
    defer context.flags.deinit(allocator);
    defer context.phases.deinit(allocator);

    const result = try runGateOptimizeModes(allocator, fakeGateModeBuild, &context);
    defer releaseBuildTestResult(allocator, result);

    // Debug alone left every ReleaseSafe-only defect (elided
    // `std.debug.assert` guards, optimizer-exposed UB) unpublished, and a
    // compile-only pass would leave every runtime defect unpublished instead.
    // Each mode is compiled and then run, in that order: a package that only
    // compiles must not reach the caller as a promoted package.
    const expected = [_]struct { flag: []const u8, phase: GatePhase }{
        .{ .flag = "-Doptimize=debug", .phase = .compile },
        .{ .flag = "-Doptimize=debug", .phase = .run },
        .{ .flag = "-Doptimize=safe", .phase = .compile },
        .{ .flag = "-Doptimize=safe", .phase = .run },
    };
    try std.testing.expectEqual(expected.len, context.flags.items.len);
    for (expected, 0..) |want, index| {
        try std.testing.expectEqualStrings(want.flag, context.flags.items[index]);
        try std.testing.expectEqual(want.phase, context.phases.items[index]);
    }
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
    var context: GateModeTestContext = .{
        .allocator = allocator,
        .fail_flag = "-Doptimize=debug",
        .fail_stderr = "error: use this value: 0xdeadbeefcafebabe",
    };
    defer context.flags.deinit(allocator);
    defer context.phases.deinit(allocator);

    const result = try runGateOptimizeModes(allocator, fakeGateModeBuild, &context);
    defer releaseBuildTestResult(allocator, result);

    // Running the second mode would repeat the same manifest fingerprint
    // hint, and `resolveFingerprint` rejects a hint it sees twice. The
    // fingerprint is read during configuration, so the compile phase is
    // where it has to be found.
    try std.testing.expectEqual(@as(usize, 1), context.flags.items.len);
    try std.testing.expectEqual(GatePhase.compile, result.phase);
    try std.testing.expectEqual(@as(u8, 1), result.term.exited);
    try std.testing.expectEqual(
        @as(?u64, 0xdeadbeefcafebabe),
        try resolveFingerprint(allocator, test_io, null, "unused", &result),
    );
}

test "promotion gate fails when the package breaks only under ReleaseSafe" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    var context: GateModeTestContext = .{
        .allocator = allocator,
        .fail_flag = "-Doptimize=safe",
        .fail_stderr = "error: use of undeclared identifier 'undefined_value'",
    };
    defer context.flags.deinit(allocator);
    defer context.phases.deinit(allocator);

    const result = try runGateOptimizeModes(allocator, fakeGateModeBuild, &context);
    defer releaseBuildTestResult(allocator, result);

    // Debug compiled and ran; the ReleaseSafe compile is the only thing that
    // catches this, and its output carries no fingerprint hint, so promotion
    // must report a build failure rather than patch the manifest and re-run.
    try std.testing.expectEqual(@as(usize, 3), context.flags.items.len);
    try std.testing.expectEqualStrings("-Doptimize=safe", context.flags.items[2]);
    try std.testing.expectEqual(GatePhase.compile, result.phase);
    try std.testing.expectEqual(@as(u8, 1), result.term.exited);
    try std.testing.expectEqual(@as(?u64, null), try resolveFingerprint(
        allocator,
        test_io,
        null,
        "unused",
        &result,
    ));
}

test "promotion gate names a failure that comes from running the package" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    var context: GateModeTestContext = .{
        .allocator = allocator,
        .fail_phase = .run,
        .fail_stderr = "thread 1 panicked at root.zig:1: reached unreachable code",
    };
    defer context.flags.deinit(allocator);
    defer context.phases.deinit(allocator);

    const result = try runGateOptimizeModes(allocator, fakeGateModeBuild, &context);
    defer releaseBuildTestResult(allocator, result);

    // The compile phase of the first mode passed, so a non-zero exit from the
    // run phase that follows it can only be what the emitted code did when it
    // ran. Calling that a build failure points whoever reads it at the
    // emitter when the emitter wrote exactly what it meant to.
    try std.testing.expectEqual(@as(usize, 2), context.flags.items.len);
    try std.testing.expectEqual(GatePhase.compile, context.phases.items[0]);
    try std.testing.expectEqual(GatePhase.run, context.phases.items[1]);
    try std.testing.expectEqual(GatePhase.run, result.phase);
    try std.testing.expectEqual(@as(u8, 1), result.term.exited);
    // A panic message is not a manifest fingerprint hint, and treating one as
    // such is what made a run failure come back labelled as a build failure.
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

// ── The staging boundary, property by property ─────────────────────────────
// `cleanupPromotion` answers a failed promotion with a recursive delete of the
// tree that promotion wrote. Each claim below is therefore about what that
// delete may reach and what a failure may leave behind, and none of them is
// answered by naming the one staging path a test can compute for itself.

test "a failed promotion leaves nothing under the output directory to find" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    const pkg = buildTestPackage();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    const out_dir = try std.fs.path.join(allocator, &.{ tmp_root, "published" });
    defer allocator.free(out_dir);

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

    // The other promotion tests name the one staging path their own fixed
    // nonce produces and check it is gone. What is pinned here is every *other*
    // name: a staging directory left under a nonce this test never computed, or
    // a destination that was created and then abandoned, both land in the same
    // parent, and both are a package a later run into this output directory
    // could read as a finished one. The parent is empty, so there is nothing to
    // read.
    var parent = try std.Io.Dir.cwd().openDir(test_io, tmp_root, .{ .iterate = true });
    defer parent.close(test_io);
    var entries = parent.iterate();
    var remaining: usize = 0;
    while (try entries.next(test_io)) |entry| {
        std.debug.print("failed promotion left `{s}` beside the output directory\n", .{entry.name});
        remaining += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), remaining);
}

/// `cleanupPromotion` keeps the failure as a value rather than as an error
/// union, so `std.testing.expectError`, which destructures an error union,
/// cannot read it directly. This puts the error that function chose to keep
/// into the shape it expects: nothing is translated and nothing substituted.
fn cleanupFailure(err: anyerror) anyerror!void {
    return err;
}

test "cleanupPromotion removes the run's own staging directory and nothing else" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_root);
    const out_dir = try std.fs.path.join(allocator, &.{ tmp_root, "published" });
    defer allocator.free(out_dir);
    const sibling = try std.fs.path.join(allocator, &.{ tmp_root, "other-package" });
    defer allocator.free(sibling);
    const zon_path = try std.fs.path.join(allocator, &.{ out_dir, "build.zig.zon" });
    defer allocator.free(zon_path);
    const keep_path = try std.fs.path.join(allocator, &.{ sibling, "keep.txt" });
    defer allocator.free(keep_path);

    // Two directories this promotion did not create: the package an earlier run
    // published, and a sibling the caller owns.
    try writeFile(allocator, test_io, out_dir, "build.zig.zon", ".name = .published\n");
    try writeFile(allocator, test_io, sibling, "keep.txt", "owned by the caller\n");

    // `deleteTree` is recursive. Handed the destination it would destroy the
    // one package here that is complete; handed the caller's sibling it would
    // destroy something no promotion of this package ever wrote.
    try std.testing.expectError(
        error.GeneratedPackageBuildFailed,
        cleanupFailure(cleanupPromotion(test_io, out_dir, out_dir, error.GeneratedPackageBuildFailed)),
    );
    try std.testing.expectError(
        error.GeneratedPackageBuildFailed,
        cleanupFailure(cleanupPromotion(test_io, out_dir, sibling, error.GeneratedPackageBuildFailed)),
    );
    const published = try readFileContent(allocator, test_io, zon_path);
    defer allocator.free(published);
    try std.testing.expectEqualStrings(".name = .published\n", published);
    const kept = try readFileContent(allocator, test_io, keep_path);
    defer allocator.free(kept);
    try std.testing.expectEqualStrings("owned by the caller\n", kept);

    // The guard is not "never delete". The directory this promotion did create
    // is the one thing `cleanupPromotion` exists to remove, so a test that read
    // only the two refusals would also pass against a function that had given
    // up on removing anything at all.
    var nonce: [promotion_nonce_len]u8 = undefined;
    @memset(&nonce, 0xa5);
    const staging_dir = try stagingPath(allocator, out_dir, nonce);
    defer allocator.free(staging_dir);
    try writeFile(allocator, test_io, staging_dir, "src/root.zig", "pub const LIMIT: u32 = 42;\n");

    try std.testing.expectError(
        error.GeneratedPackageBuildFailed,
        cleanupFailure(cleanupPromotion(test_io, out_dir, staging_dir, error.GeneratedPackageBuildFailed)),
    );
    try expectDirectoryAbsent(test_io, staging_dir);
}

test "a package that compiles and then fails its tests is a run failure" {
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
        .mode = .run_failure,
    };
    try std.testing.expectError(
        error.GeneratedPackageRunFailed,
        promoteWithHooks(allocator, test_io, &pkg, out_dir, .{
            .context = &context,
            .fill_nonce = fixedPromotionNonce,
            .run_build_test = fakePromotionBuildTest,
            .resolve_fingerprint = fakePromotionFingerprint,
            .report_build_failure = recordBuildFailure,
        }),
    );

    // The package compiled and the run that followed it aborted, so this is a
    // fact about the emitted code and not about the manifest. Reporting it as a
    // build failure points whoever reads it at the emitter, which wrote exactly
    // what it meant to. The resolver is never consulted either: an aborting
    // test is not a fingerprint hint, so patching the manifest would run the
    // same tests again and then name the wrong phase for the same failure.
    try std.testing.expectEqual(@as(u32, 1), context.build_calls);
    try std.testing.expectEqual(@as(u32, 0), context.resolver_calls);
    try std.testing.expectEqual(@as(u32, 1), context.report_calls);
    try std.testing.expectEqual(GatePhase.run, context.reported_phase);
    try std.testing.expectEqualStrings(
        run_panic_text,
        context.reported_stderr[0..context.reported_stderr_len],
    );
    try expectDirectoryAbsent(test_io, out_dir);
    try expectDirectoryAbsent(test_io, staging_dir);
}

test "a run failure after the manifest was patched is still a run failure" {
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
        .mode = .fingerprint_then_run_failure,
    };
    try std.testing.expectError(
        error.GeneratedPackageRunFailed,
        promoteWithHooks(allocator, test_io, &pkg, out_dir, .{
            .context = &context,
            .fill_nonce = fixedPromotionNonce,
            .run_build_test = fakePromotionBuildTest,
            .resolve_fingerprint = fakePromotionFingerprint,
            .report_build_failure = recordBuildFailure,
        }),
    );

    // The first pass failed to configure and handed the resolver a real
    // fingerprint hint, so the manifest was patched and the package then
    // compiled. The second pass is the run, and it aborted. A promotion that
    // had just fixed the manifest is the one place where "it compiled, so the
    // manifest was wrong" is most tempting and most wrong: the phase is a
    // property of which invocation failed, and a package whose tests fail is
    // not promoted even once it compiles.
    try std.testing.expectEqual(@as(u32, 2), context.build_calls);
    try std.testing.expectEqual(@as(u32, 1), context.resolver_calls);
    try std.testing.expect(context.resolver_saw_missing_fingerprint);
    try std.testing.expectEqual(@as(u32, 1), context.report_calls);
    try std.testing.expectEqual(GatePhase.run, context.reported_phase);
    try expectDirectoryAbsent(test_io, out_dir);
    try expectDirectoryAbsent(test_io, staging_dir);
}

test "the staging check admits the name promotion creates and no other" {
    const allocator = std.testing.allocator;

    // The names are taken from `stagingPath` rather than copied out of the
    // implementation: the check exists to admit exactly what the naming
    // produces, so if the two ever drift apart a real staging directory would
    // stop being cleaned up and a test that only spelled the shape out by hand
    // would still pass.
    const nested_out = "zig-out/staging-audit/published";
    var nonce: [promotion_nonce_len]u8 = undefined;
    @memset(&nonce, 0xa5);
    const nested_staging = try stagingPath(allocator, nested_out, nonce);
    defer allocator.free(nested_staging);
    try std.testing.expect(isStagingSiblingOf(nested_out, nested_staging));

    // A bare output directory has no parent to compare against, which is the
    // `-o out` spelling a caller actually writes.
    @memset(&nonce, 0xff);
    const bare_staging = try stagingPath(allocator, "published", nonce);
    defer allocator.free(bare_staging);
    try std.testing.expect(isStagingSiblingOf("published", bare_staging));

    const short_nonce = try std.fmt.allocPrint(
        allocator,
        "zig-out/staging-audit/.published.staging.{s}",
        .{@as([31]u8, @splat('a'))},
    );
    defer allocator.free(short_nonce);
    const long_nonce = try std.fmt.allocPrint(
        allocator,
        "zig-out/staging-audit/.published.staging.{s}",
        .{@as([33]u8, @splat('a'))},
    );
    defer allocator.free(long_nonce);
    const non_hex_nonce = try std.fmt.allocPrint(
        allocator,
        "zig-out/staging-audit/.published.staging.{s}",
        .{@as([32]u8, @splat('g'))},
    );
    defer allocator.free(non_hex_nonce);
    const upper_hex_nonce = try std.fmt.allocPrint(
        allocator,
        "zig-out/staging-audit/.published.staging.{s}",
        .{@as([32]u8, @splat('A'))},
    );
    defer allocator.free(upper_hex_nonce);
    const elsewhere = try std.fmt.allocPrint(
        allocator,
        "zig-out/elsewhere/.published.staging.{s}",
        .{@as([32]u8, @splat('a'))},
    );
    defer allocator.free(elsewhere);
    const below_staging = try std.fmt.allocPrint(
        allocator,
        "zig-out/staging-audit/.published.staging.{s}/src",
        .{@as([32]u8, @splat('a'))},
    );
    defer allocator.free(below_staging);

    const rejected = [_][]const u8{
        // The destination itself, spelled with and without its trailing
        // separator. A recursive delete of either one is the one mistake here
        // that costs a caller a package which is complete.
        nested_out,
        "zig-out/staging-audit/published/",
        // Names that merely begin with the output directory's name, or with
        // the staging prefix, and then continue as something else.
        "zig-out/staging-audit/published-extra",
        "zig-out/staging-audit/published2",
        short_nonce,
        long_nonce,
        non_hex_nonce,
        // A nonce no promotion writes: `stagingPath` hex-encodes in lower
        // case, so this name belongs to whoever made it.
        upper_hex_nonce,
        // The right name in the wrong place — beside another output directory,
        // or below the staging directory rather than beside it.
        elsewhere,
        below_staging,
    };
    for (rejected) |candidate| {
        std.testing.expect(!isStagingSiblingOf(nested_out, candidate)) catch |err| {
            std.debug.print("the staging check admitted `{s}`\n", .{candidate});
            return err;
        };
    }
    try std.testing.expect(!isStagingSiblingOf("published", "published"));
}
