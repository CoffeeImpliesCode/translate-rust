//! CLI for the Rust → Zig translation tool.
//! P1: `--dump model <crate.json>` parses a sidecar wire-format dump into the
//! semantic IR (translate_rust.model) and prints the crate/module inventory.

const std = @import("std");
const translate_rust = @import("translate_rust");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdout = std.Io.File.stdout();

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer arg_it.deinit();

    // argv[0] — program name.
    _ = arg_it.next();

    const arg = arg_it.next() orelse {
        try printUsage(io, stdout);
        return;
    };
    const arg_slice = arg;

    if (std.mem.eql(u8, arg_slice, "--version")) {
        try stdout.writeStreamingAll(io, "translate-rust " ++ translate_rust.version ++ "\n");
        return;
    }
    if (std.mem.eql(u8, arg_slice, "--help") or std.mem.eql(u8, arg_slice, "-h")) {
        try printUsage(io, stdout);
        return;
    }
    if (std.mem.eql(u8, arg_slice, "--dump")) {
        try dumpModel(io, init, stdout, &arg_it);
        return;
    }
    if (std.mem.eql(u8, arg_slice, "--dump-types")) {
        const path = arg_it.next() orelse {
            try stdout.writeStreamingAll(io, "usage: translate-rust --dump-types <crate-dir>\n");
            return;
        };
        try dumpTypes(io, init, stdout, path);
        return;
    }
    if (std.mem.eql(u8, arg_slice, "--translate") or std.mem.eql(u8, arg_slice, "--emit-package")) {
        const path = arg_it.next() orelse {
            try printUsage(io, stdout);
            return;
        };
        var out_dir: ?[]const u8 = null;
        if (arg_it.next()) |next_arg| {
            if (std.mem.eql(u8, next_arg, "-o") or std.mem.eql(u8, next_arg, "--output")) {
                out_dir = arg_it.next();
            }
        }
        try translateCrate(io, init, stdout, path, out_dir);
        return;
    }

    // Default positional behavior: if passed a .json file, translate it.
    if (std.mem.endsWith(u8, arg_slice, ".json")) {
        var out_dir: ?[]const u8 = null;
        if (arg_it.next()) |next_arg| {
            if (std.mem.eql(u8, next_arg, "-o") or std.mem.eql(u8, next_arg, "--output")) {
                out_dir = arg_it.next();
            }
        }
        try translateCrate(io, init, stdout, arg_slice, out_dir);
        return;
    }

    // Non-`.json` positional arg → treat it as a Rust crate directory and run
    // the source driver (cargo +nightly rustdoc → r2z package). Requires -o.
    var crate_out_dir: ?[]const u8 = null;
    if (arg_it.next()) |next_arg| {
        if (std.mem.eql(u8, next_arg, "-o") or std.mem.eql(u8, next_arg, "--output")) {
            crate_out_dir = arg_it.next();
        }
    }
    if (crate_out_dir == null) {
        try stdout.writeStreamingAll(io,
            \\translate-rust: crate-directory mode requires -o <out-dir>
            \\usage: translate-rust <crate-dir> -o <out-dir>
            \\
        );
        return;
    }
    try translate_rust.model.driver.translate(init.gpa, io, stdout, arg_slice, crate_out_dir.?);
    return;
}

/// `--dump-types <crate-dir>`: parse the crate's source with tree-sitter and
/// print the extracted type model (module tree + per-entity kinds/types).
fn dumpTypes(io: std.Io, init: std.process.Init, stdout: std.Io.File, crate_dir: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const model = translate_rust.model;

    // Resolve the lib source file (src/lib.rs or lib.rs).
    var lib_path: ?[]const u8 = null;
    for ([_][]const u8{ "src/lib.rs", "lib.rs" }) |c| {
        const joined = try std.fs.path.join(allocator, &.{ crate_dir, c });
        if (std.Io.Dir.cwd().openFile(io, joined, .{})) |f| {
            f.close(io);
            lib_path = joined;
            break;
        } else |_| {}
    }
    const path = lib_path orelse {
        const msg = try std.fmt.allocPrint(allocator, "no lib source found in {s}\n", .{crate_dir});
        try stdout.writeStreamingAll(io, msg);
        return;
    };

    var dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var io_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &io_buf);
    const src = try reader.interface.allocRemaining(allocator, .limited(1 << 24));

    // Build a fresh graph + tables.
    var g = model.graph.CrateGraph.init(allocator);
    const span = model.cst.span_of;
    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try allocator.dupe(u8, ""),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });
    var types_list: std.ArrayListUnmanaged(model.types.Type) = .empty;
    var bodies_list: std.ArrayListUnmanaged(model.bodies.BodyKind) = .empty;
    try bodies_list.append(allocator, .none);

    var ctx: model.cst.Ctx = .{
        .alloc = allocator,
        .g = &g,
        .src = src,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
    };
    try model.cst.extractFile(&ctx);

    // Print the inventory.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try dumpEntities(allocator, &out, &g, 0, 0);
    try stdout.writeStreamingAll(io, out.items);
}

fn dumpEntities(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const translate_rust.model.graph.CrateGraph,
    mod_id: translate_rust.model.spine.EntityId,
    depth: usize,
) !void {
    const m = g.module(mod_id) orelse return;
    for (m.items) |item_id| {
        const e = g.symbol_table.get(item_id) orelse continue;
        try buf.appendNTimes(allocator, ' ', depth * 2);
        const line = try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ @tagName(e.kind), e.name });
        try buf.appendSlice(allocator, line);
        if (e.kind == .module) {
            try dumpEntities(allocator, buf, g, item_id, depth + 1);
        }
    }
}

fn dumpModel(io: std.Io, init: std.process.Init, stdout: std.Io.File, arg_it: *std.process.Args.Iterator) !void {
    const mode = arg_it.next() orelse return error.UsageMissingDumpMode;
    if (!std.mem.eql(u8, mode, "model")) {
        return error.UnknownDumpMode;
    }
    const path = arg_it.next() orelse return error.UsageMissingJsonPath;

    var dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var io_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &io_buf);
    const bytes = try reader.interface.allocRemaining(init.gpa, .limited(1 << 30));
    defer init.gpa.free(bytes);

    var g = try translate_rust.model.json.parse(init.gpa, bytes);
    defer g.deinit();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(init.gpa);

    for (g.crates.items) |c| {
        try buf.appendSlice(init.gpa, "crate ");
        try buf.appendSlice(init.gpa, c.name);
        const line = try std.fmt.allocPrint(init.gpa, " edition={d} kind={s}\n", .{ c.edition, crateKindName(c.kind) });
        defer init.gpa.free(line);
        try buf.appendSlice(init.gpa, line);
        try dumpModule(init.gpa, &g, &buf, c.root, 1);
    }

    try stdout.writeStreamingAll(io, buf.items);
}

fn dumpModule(
    gpa: std.mem.Allocator,
    g: *const translate_rust.model.graph.CrateGraph,
    buf: *std.ArrayListUnmanaged(u8),
    mod_id: translate_rust.model.spine.EntityId,
    depth: usize,
) !void {
    const m = g.module(mod_id) orelse return;

    for (m.items) |item_id| {
        const e = g.symbol_table.get(item_id) orelse continue;

        try buf.appendNTimes(gpa, ' ', depth * 2);
        switch (e.kind) {
            .module => {
                try buf.appendSlice(gpa, "mod ");
                try buf.appendSlice(gpa, e.name);
                try buf.appendSlice(gpa, "\n");
                try dumpModule(gpa, g, buf, item_id, depth + 1);
            },
            .use_ => {
                try buf.appendSlice(gpa, "use ");
                try buf.appendSlice(gpa, e.name);
                try buf.appendSlice(gpa, " -> ");
                if (g.useById(item_id)) |u| {
                    if (g.symbol_table.get(u.target)) |t| {
                        try buf.appendSlice(gpa, t.name);
                    }
                }
                try buf.appendSlice(gpa, "\n");
            },
            else => {
                try buf.appendSlice(gpa, entityKindName(e.kind));
                try buf.appendSlice(gpa, " ");
                try buf.appendSlice(gpa, e.name);
                try buf.appendSlice(gpa, "\n");
            },
        }
    }
}

fn crateKindName(k: translate_rust.model.graph.CrateKind) []const u8 {
    return switch (k) {
        .lib => "lib",
        .bin => "bin",
    };
}

fn entityKindName(k: translate_rust.model.spine.EntityKind) []const u8 {
    return switch (k) {
        .crate_ => "crate",
        .module => "mod",
        .struct_ => "struct",
        .enum_ => "enum",
        .union_ => "union",
        .fn_ => "fn",
        .const_ => "const",
        .static_ => "static",
        .trait_ => "trait",
        .impl_ => "impl",
        .type_alias => "type",
        .use_ => "use",
        .extern_crate => "extern crate",
        .macro_ => "macro",
        .field => "field",
        .variant => "variant",
    };
}

fn translateCrate(
    io: std.Io,
    init: std.process.Init,
    stdout: std.Io.File,
    path: []const u8,
    out_dir: ?[]const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var io_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &io_buf);
    const bytes = try reader.interface.allocRemaining(allocator, .limited(1 << 30));

    // Wire format v2 carries bodies; parseFull + emitRich produce full Zig.
    var model = try translate_rust.model.json.parseFull(allocator, bytes);

    if (out_dir) |dest| {
        // Package emission mode: generate multi-file package directory
        for (0..model.graph.crates.items.len) |crate_idx| {
            const pkg = try translate_rust.model.package.generatePackage(
                allocator,
                &model.graph,
                &model.bodies,
                crate_idx,
            );
            try pkg.writeToDisk(io, dest);
            const msg = try std.fmt.allocPrint(
                allocator,
                "emitted package {s} to {s} ({d} files)\n",
                .{ pkg.package_name, dest, pkg.files.len },
            );
            try stdout.writeStreamingAll(io, msg);
        }
    } else {
        // Single-stream stdout emission mode
        const raw_source = try translate_rust.model.emit.emitRich(allocator, &model.graph, &model.bodies);
        const formatted = try translate_rust.model.emit.formatZig(allocator, raw_source);
        try stdout.writeStreamingAll(io, formatted);
    }
}

fn printUsage(io: std.Io, stdout: std.Io.File) !void {
    try stdout.writeStreamingAll(io,
        \\translate-rust — Rust → Zig translation (research phase, no full pipeline yet)
        \\
        \\usage: translate-rust <crate-dir> -o <dir>  translate a Rust crate (cargo +nightly rustdoc) to an r2z package
        \\       translate-rust <file.json> [-o dir]  translate a wire-format JSON dump (stdout or package dir)
        \\       translate-rust --emit-package <file.json> -o <dir>  emit standalone Zig package
        \\       translate-rust --dump model <file>   parse a sidecar wire-format JSON dump and print
        \\                                            the crate/module inventory
        \\       translate-rust --version             print version
        \\       translate-rust --help                show this help
        \\
    );
}
