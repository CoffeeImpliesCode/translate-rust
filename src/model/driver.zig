//! translate_rust.model.driver — direct Rust-source → package driver.
//!
//! `translate(<crate-dir>, <out-dir>)` shells out to the v0 sidecar producer
//! (`tools/sidecar/rustdoc-json.sh`) to obtain raw rustdoc JSON for a Cargo
//! package, builds a best-effort wire-model `CrateGraph`, and emits the
//! standalone `r2z-<crate>/` package via `package.generatePackage`.
//!
//! This is deliberately BEST-EFFORT: it does not perform full semantic
//! lowering. If rustdoc yields no parseable items (or the toolchain is
//! missing), it still emits the package skeleton (build.zig, build.zig.zon,
//! src/root.zig) carrying whatever top-level items could be cheaply mapped.

const std = @import("std");
const spine = @import("spine.zig");
const graph = @import("graph.zig");
const package = @import("package.zig");

/// Read a whole file into `allocator` (caller owns the returned slice).
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
    return reader.interface.allocRemaining(allocator, .limited(1 << 30));
}

/// Parse `Cargo.toml` `[package] name = "..."` (line-based, comment-aware,
/// best-effort). The returned slice is owned by `allocator`.
fn crateNameFromManifestImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
) ![]const u8 {
    const cargo_path = try std.fs.path.join(allocator, &.{ dir, "Cargo.toml" });
    defer allocator.free(cargo_path);

    const bytes = try readFileAlloc(allocator, io, cargo_path);
    defer allocator.free(bytes);

    var it = std.mem.splitScalar(u8, bytes, '\n');
    var in_pkg = false;
    while (it.next()) |raw_line| {
        // Strip trailing comment and surrounding whitespace.
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            const section = std.mem.trim(u8, line, "[] \t");
            in_pkg = std.mem.eql(u8, section, "package");
            continue;
        }
        if (!in_pkg) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, key, "name")) continue;

        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        var val_it = std.mem.splitScalar(u8, val, '"');
        _ = val_it.next(); // discard anything before the opening quote
        if (val_it.next()) |name| return allocator.dupe(u8, name);
        return error.CargoManifestMissingName;
    }
    return error.CargoManifestMissingPackageSection;
}

fn crateNameFromManifestPage(io: std.Io, dir: []const u8) anyerror![]const u8 {
    return crateNameFromManifestImpl(std.heap.page_allocator, io, dir);
}

/// Best-effort crate-name extraction, exposed with the required fn-pointer
/// shape. Page-allocated (caller frees); the driver uses the allocator-aware
/// implementation directly to avoid leaking.
pub const crate_name_from_manifest: *const fn (io: std.Io, dir: []const u8) anyerror![]const u8 =
    &crateNameFromManifestPage;

/// Map a rustdoc `inner` kind tag to an EntityKind the v1 emitter handles,
/// or null if the item should be skipped.
fn rustdocKindToEntityKind(inner_key: []const u8) ?spine.EntityKind {
    if (std.mem.eql(u8, inner_key, "struct")) return .struct_;
    if (std.mem.eql(u8, inner_key, "enum")) return .enum_;
    if (std.mem.eql(u8, inner_key, "union")) return .union_;
    if (std.mem.eql(u8, inner_key, "function")) return .fn_;
    if (std.mem.eql(u8, inner_key, "constant")) return .const_;
    if (std.mem.eql(u8, inner_key, "static")) return .static_;
    if (std.mem.eql(u8, inner_key, "trait")) return .trait_;
    if (std.mem.eql(u8, inner_key, "type_alias")) return .type_alias;
    if (std.mem.eql(u8, inner_key, "macro")) return .macro_;
    return null;
}

/// Returns the raw JSON value for `key` on object `v`, or null if absent.
/// Errors if `v` is not an object (callers check the returned value's tag).
fn getField(v: std.json.Value, key: []const u8) !?std.json.Value {
    if (v != .object) return error.RustdocNotObject;
    return v.object.get(key);
}

/// Walk the rustdoc JSON's root module and map each top-level item into the
/// CrateGraph's symbol table + module item list. Best effort: any parse hiccup
/// returns an error and the caller falls back to an empty skeleton.
fn scrapeRustdoc(
    gpa: std.mem.Allocator,
    g: *graph.CrateGraph,
    bytes: []const u8,
    items: *std.ArrayListUnmanaged(spine.EntityId),
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, @ptrCast(bytes), .{});
    defer parsed.deinit();
    const value = parsed.value;

    const index = (try getField(value, "index")) orelse return error.RustdocNoIndex;
    if (index != .object) return error.RustdocIndexNotObject;

    // `root` is a JSON number that indexes the string-keyed `index` map.
    const root_v = (try getField(value, "root")) orelse return error.RustdocNoRoot;
    if (root_v != .integer) return error.RustdocRootNotInteger;
    const root_key = try std.fmt.allocPrint(gpa, "{d}", .{root_v.integer});

    const root_item = index.object.get(root_key) orelse return error.RustdocNoRootItem;
    if (root_item != .object) return error.RustdocRootItemNotObject;
    const root_inner = (try getField(root_item, "inner")) orelse return error.RustdocNoRootInner;
    if (root_inner != .object) return error.RustdocRootInnerNotObject;
    const root_mod = (try getField(root_inner, "module")) orelse return error.RustdocNoRootModule;
    if (root_mod != .object) return error.RustdocRootModuleNotObject;
    const items_v = root_mod.object.get("items") orelse return error.RustdocNoItems;
    if (items_v != .array) return error.RustdocBadItems;
    const raw_ids = items_v.array.items;

    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };
    for (raw_ids) |idv| {
        if (idv != .integer) continue;
        const key_buf = try std.fmt.allocPrint(gpa, "{d}", .{idv.integer});
        const item = index.object.get(key_buf) orelse continue;

        const name_v = item.object.get("name") orelse continue;
        if (name_v != .string) continue;
        if (name_v.string.len == 0) continue;

        const inner = item.object.get("inner") orelse continue;
        if (inner != .object) continue;
        if (inner.object.count() == 0) continue;
        var inner_it = inner.object.iterator();
        const first = inner_it.next() orelse continue;
        const kind = rustdocKindToEntityKind(first.key_ptr.*) orelse continue;

        const vis: spine.Visibility = if (item.object.get("visibility")) |vv|
            (if (vv == .string and std.mem.eql(u8, vv.string, "public")) .public else .private)
        else
            .private;

        const ent_id = try g.symbol_table.add(.{
            .id = 0,
            .kind = kind,
            .name = try gpa.dupe(u8, name_v.string),
            .span = span,
            .visibility = vis,
            .parent = null,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
        });
        try items.append(gpa, ent_id);
    }
}

/// Resolve + print a formatted message to `stdout` (arena-backed).
fn writeMessage(
    comptime fmt: []const u8,
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    args: anytype,
) !void {
    const msg = try std.fmt.allocPrint(gpa, fmt, args);
    try stdout.writeStreamingAll(io, msg);
}

/// Translate a Rust crate directory into a standalone r2z package at `out_dir`.
/// Best-effort: degrades gracefully to a package skeleton.
pub fn translate(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    crate_dir: []const u8,
    out_dir: []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const name = try crateNameFromManifestImpl(arena, io, crate_dir);

    // Sidecar output directory, scoped under the output dir so we never write
    // into the crate's own tree. Removed at the end of this call.
    const sidecar_out = try std.fs.path.join(arena, &.{ out_dir, ".r2z-rustdoc" });
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, sidecar_out);
    defer cwd.deleteTree(io, sidecar_out) catch {};

    // 1. Run the sidecar producer to obtain raw rustdoc JSON (best-effort).
    var had_rustdoc = false;
    if (std.process.run(gpa, io, .{
        .argv = &.{ "sh", "tools/sidecar/rustdoc-json.sh", crate_dir, sidecar_out },
    })) |res| {
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);
        switch (res.term) {
            .exited => |code| {
                if (code == 0) {
                    had_rustdoc = true;
                } else {
                    try writeMessage("warning: sidecar exited with code {d}; emitting package skeleton\n", arena, io, stdout, .{code});
                }
            },
            else => try writeMessage("warning: sidecar terminated abnormally; emitting package skeleton\n", arena, io, stdout, .{}),
        }
    } else |err| {
        try writeMessage("warning: sidecar failed ({s}); emitting package skeleton\n", arena, io, stdout, .{@errorName(err)});
    }

    // 2. Build a best-effort wire CrateGraph + Bodies (null bodies -> items only).
    var g = graph.CrateGraph.init(arena);
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    // Root module entity (id 0, matching dense symbol/module tables).
    const root_entity_name = try arena.dupe(u8, "");
    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = root_entity_name,
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    var items: std.ArrayListUnmanaged(spine.EntityId) = .empty;
    if (had_rustdoc) {
        const rustdoc_path = try std.fs.path.join(arena, &.{
            sidecar_out,
            try std.fmt.allocPrint(arena, "crate-{s}.json", .{name}),
        });
        if (readFileAlloc(arena, io, rustdoc_path)) |rdb| {
            if (scrapeRustdoc(arena, &g, rdb, &items)) |_| {
                // items mapped
            } else |_| {
                try writeMessage("warning: could not map rustdoc items; emitting package skeleton\n", arena, io, stdout, .{});
            }
        } else |_| {
            try writeMessage("warning: could not read rustdoc JSON; emitting package skeleton\n", arena, io, stdout, .{});
        }
    }

    const item_slice = try items.toOwnedSlice(arena);
    _ = try g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = item_slice,
        .attributes = &.{},
    });
    try g.addCrate(.{
        .name = try arena.dupe(u8, name),
        .edition = 2018,
        .kind = .lib,
        .root = 0,
        .deps = &.{},
        .is_translated = true,
    });

    // 3. Emit the standalone package to disk.
    var pkg = try package.generatePackage(arena, &g, null, 0);
    try pkg.writeToDisk(io, out_dir);
    try writeMessage("emitted package {s} to {s} ({d} files)\n", arena, io, stdout, .{ pkg.package_name, out_dir, pkg.files.len });
}
