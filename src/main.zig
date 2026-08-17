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
        try dumpModel(init, io, stdout, &arg_it);
        return;
    }
    if (std.mem.eql(u8, arg_slice, "--translate")) {
        const path = arg_it.next() orelse {
            try printUsage(io, stdout);
            return;
        };
        try translateCrate(init, io, stdout, path);
        return;
    }

    // Default positional behavior: if passed a .json file, translate it.
    if (std.mem.endsWith(u8, arg_slice, ".json")) {
        try translateCrate(init, io, stdout, arg_slice);
        return;
    }

    try stdout.writeStreamingAll(io,
        \\translate-rust: unrecognized argument; run with --help
        \\
    );
}

fn dumpModel(init: std.process.Init, io: std.Io, stdout: std.Io.File, arg_it: *std.process.Args.Iterator) !void {
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

fn dumpModule(gpa: std.mem.Allocator, g: *const translate_rust.model.graph.CrateGraph, buf: *std.ArrayListUnmanaged(u8), mod_id: translate_rust.model.spine.EntityId, depth: usize) !void {
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

fn translateCrate(init: std.process.Init, io: std.Io, stdout: std.Io.File, path: []const u8) !void {
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

    const zig_source = try translate_rust.model.emit.emitRich(allocator, &model.graph, &model.bodies);

    try stdout.writeStreamingAll(io, zig_source);
}

fn printUsage(io: std.Io, stdout: std.Io.File) !void {
    try stdout.writeStreamingAll(io,
        \\translate-rust — Rust → Zig translation (research phase, no full pipeline yet)
        \\
        \\usage: translate-rust <crate-path>          translate a Rust crate to Zig (not implemented)
        \\       translate-rust --dump model <file>   parse a sidecar wire-format JSON dump and print
        \\                                            the crate/module inventory
        \\       translate-rust --translate <file>     parse a sidecar wire-format JSON dump and emit
        \\                                            Zig source code (items only, P2)
        \\       translate-rust --version             print version
        \\       translate-rust --help                show this help
        \\
    );
}
