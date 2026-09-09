//! CLI for the Rust → Zig translation tool.
//! Source and canonical wire inputs use the driver pipeline. `--dump model`
//! reads legacy sidecar data for crate/module inventory diagnostics only.

const std = @import("std");
const translate_rust = @import("translate_rust");

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| {
        std.log.err("translate-rust failed: {s}", .{@errorName(err)});
        return err;
    };
}

fn run(init: std.process.Init) !void {
    const io = init.io;
    const stdout = std.Io.File.stdout();

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer arg_it.deinit();

    // argv[0] — program name.
    if (arg_it.next() == null) {
        try printUsage(io, stdout);
        return error.MissingCliArgument;
    }

    const arg = arg_it.next() orelse {
        try printUsage(io, stdout);
        return error.MissingCliArgument;
    };
    const arg_slice = arg;

    if (std.mem.eql(u8, arg_slice, "--version")) {
        try expectNoMoreArguments(io, stdout, &arg_it);
        try stdout.writeStreamingAll(io, "translate-rust " ++ translate_rust.version ++ "\n");
        return;
    }
    if (std.mem.eql(u8, arg_slice, "--help") or std.mem.eql(u8, arg_slice, "-h")) {
        try expectNoMoreArguments(io, stdout, &arg_it);
        try printUsage(io, stdout);
        return;
    }
    // `--strategy <name>` must be read before the subcommand token when it
    // precedes a dump verb. Consume it now and validate the value up front.
    var strategy_name: ?[]const u8 = null;
    var first = arg_slice;
    if (std.mem.eql(u8, first, "--strategy")) {
        const strategy = arg_it.next() orelse {
            try stdout.writeStreamingAll(
                io,
                "usage: translate-rust --strategy <default|embedded> --dump <mode> <path>\n",
            );
            return error.MissingCliArgument;
        };
        if (!validateStrategy(strategy)) {
            try stdout.writeStreamingAll(io, "translate-rust: unknown strategy '");
            try stdout.writeStreamingAll(io, strategy);
            try stdout.writeStreamingAll(
                io,
                "'\nusage: translate-rust --strategy <default|embedded> --dump <mode> <path>\n",
            );
            return error.UnknownStrategy;
        }
        strategy_name = strategy;
        first = arg_it.next() orelse {
            try printUsage(io, stdout);
            return error.MissingCliArgument;
        };
    }

    if (std.mem.eql(u8, first, "--dump")) {
        try dumpDispatch(io, init, stdout, &arg_it, strategy_name);
        return;
    }
    if (std.mem.eql(u8, first, "--dump-types")) {
        const path = arg_it.next() orelse {
            try stdout.writeStreamingAll(io, "usage: translate-rust --dump-types <crate-dir>\n");
            return error.MissingCliArgument;
        };
        if (path.len == 0 or std.mem.startsWith(u8, path, "-")) {
            try stdout.writeStreamingAll(io, "usage: translate-rust --dump-types <crate-dir>\n");
            return error.MissingCliArgument;
        }
        try expectNoMoreArguments(io, stdout, &arg_it);
        try dumpTypes(io, init, stdout, path);
        return;
    }
    if (std.mem.eql(u8, first, "--dump-names")) {
        const path = arg_it.next() orelse {
            try stdout.writeStreamingAll(io, "usage: translate-rust --dump-names <crate-dir>\n");
            return error.MissingCliArgument;
        };
        if (path.len == 0 or std.mem.startsWith(u8, path, "-")) {
            try stdout.writeStreamingAll(io, "usage: translate-rust --dump-names <crate-dir>\n");
            return error.MissingCliArgument;
        }
        try expectNoMoreArguments(io, stdout, &arg_it);
        try dumpNames(io, init, stdout, path);
        return;
    }
    if (std.mem.eql(u8, first, "--dump-infer")) {
        const path = arg_it.next() orelse {
            try stdout.writeStreamingAll(io, "usage: translate-rust --dump-infer <crate-dir>\n");
            return error.MissingCliArgument;
        };
        if (path.len == 0 or std.mem.startsWith(u8, path, "-")) {
            try stdout.writeStreamingAll(io, "usage: translate-rust --dump-infer <crate-dir>\n");
            return error.MissingCliArgument;
        }
        try expectNoMoreArguments(io, stdout, &arg_it);
        try dumpInfer(io, init, stdout, path);
        return;
    }
    if (std.mem.eql(u8, first, "--translate")) {
        const path = arg_it.next() orelse {
            try printUsage(io, stdout);
            return error.MissingCliArgument;
        };
        if (path.len == 0 or std.mem.startsWith(u8, path, "-")) {
            try printUsage(io, stdout);
            return error.MissingCliArgument;
        }
        const out_dir = try parseOutputArgument(io, stdout, &arg_it, false);
        try translateCrate(io, init, stdout, path, out_dir);
        return;
    }
    if (std.mem.eql(u8, first, "--emit-package")) {
        const path = arg_it.next() orelse {
            try printUsage(io, stdout);
            return error.MissingCliArgument;
        };
        if (path.len == 0 or std.mem.startsWith(u8, path, "-")) {
            try printUsage(io, stdout);
            return error.MissingCliArgument;
        }
        const out_dir = (try parseOutputArgument(io, stdout, &arg_it, true)).?;
        try translateCrate(io, init, stdout, path, out_dir);
        return;
    }

    // Default positional behavior: if passed a .json file, translate it.
    if (std.mem.endsWith(u8, first, ".json")) {
        const out_dir = try parseOutputArgument(io, stdout, &arg_it, false);
        try translateCrate(io, init, stdout, first, out_dir);
        return;
    }

    if (std.mem.startsWith(u8, first, "-")) {
        try stdout.writeStreamingAll(io, "translate-rust: unknown option '");
        try stdout.writeStreamingAll(io, first);
        try stdout.writeStreamingAll(io, "'\n");
        try printUsage(io, stdout);
        return error.UnknownOption;
    }

    // A non-JSON positional path selects the source-native frontend.
    // Package output requires -o.
    const out_dir = (try parseOutputArgument(io, stdout, &arg_it, true)).?;
    try translate_rust.driver.translate(init.gpa, io, first, out_dir);
}

fn expectNoMoreArguments(
    io: std.Io,
    stdout: std.Io.File,
    arg_it: *std.process.Args.Iterator,
) !void {
    const unexpected = arg_it.next() orelse return;
    try stdout.writeStreamingAll(io, "translate-rust: unexpected argument '");
    try stdout.writeStreamingAll(io, unexpected);
    try stdout.writeStreamingAll(io, "'\n");
    try printUsage(io, stdout);
    return error.UnexpectedCliArgument;
}

fn parseOutputArgument(
    io: std.Io,
    stdout: std.Io.File,
    arg_it: *std.process.Args.Iterator,
    required: bool,
) !?[]const u8 {
    const flag = arg_it.next() orelse {
        if (!required) return null;
        try stdout.writeStreamingAll(
            io,
            "translate-rust: package mode requires -o <out-dir>\n",
        );
        try printUsage(io, stdout);
        return error.OutputPathRequired;
    };
    if (!std.mem.eql(u8, flag, "-o") and !std.mem.eql(u8, flag, "--output")) {
        try stdout.writeStreamingAll(io, "translate-rust: unexpected argument '");
        try stdout.writeStreamingAll(io, flag);
        try stdout.writeStreamingAll(io, "'\n");
        try printUsage(io, stdout);
        return error.UnexpectedCliArgument;
    }

    const out_dir = arg_it.next() orelse {
        try stdout.writeStreamingAll(io, "translate-rust: -o requires an output path\n");
        try printUsage(io, stdout);
        return error.OutputPathMissing;
    };
    if (out_dir.len == 0 or std.mem.startsWith(u8, out_dir, "-")) {
        try stdout.writeStreamingAll(io, "translate-rust: -o requires an output path\n");
        try printUsage(io, stdout);
        return error.OutputPathMissing;
    }
    try expectNoMoreArguments(io, stdout, arg_it);
    return out_dir;
}

fn resolveLibSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    crate_dir: []const u8,
) ![]const u8 {
    for ([_][]const u8{ "src/lib.rs", "lib.rs" }) |candidate| {
        const joined = try std.fs.path.join(allocator, &.{ crate_dir, candidate });
        const file = std.Io.Dir.cwd().openFile(io, joined, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return error.SourceRootReadFailed,
        };
        file.close(io);
        return joined;
    }
    return error.SourceRootNotFound;
}

fn reportSourceRootError(
    io: std.Io,
    stdout: std.Io.File,
    crate_dir: []const u8,
    err: anyerror,
) !void {
    switch (err) {
        error.SourceRootNotFound => {
            try stdout.writeStreamingAll(io, "translate-rust: no lib source found in ");
            try stdout.writeStreamingAll(io, crate_dir);
            try stdout.writeStreamingAll(io, "\n");
        },
        error.SourceRootReadFailed => {
            try stdout.writeStreamingAll(io, "translate-rust: unable to read source root ");
            try stdout.writeStreamingAll(io, crate_dir);
            try stdout.writeStreamingAll(io, "\n");
        },
        else => {
            try stdout.writeStreamingAll(io, "translate-rust: unable to read source root ");
            try stdout.writeStreamingAll(io, crate_dir);
            try stdout.writeStreamingAll(io, "\n");
        },
    }
}

/// `--dump-types <crate-dir>`: parse the crate's source with tree-sitter and
/// print the extracted type model (module tree + per-entity kinds/types).
fn dumpTypes(io: std.Io, init: std.process.Init, stdout: std.Io.File, crate_dir: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const model = translate_rust.model;

    // Resolve the lib source file (src/lib.rs or lib.rs).
    const path = resolveLibSource(allocator, io, crate_dir) catch |err| {
        try reportSourceRootError(io, stdout, crate_dir, err);
        return err;
    };
    const lib_dir = std.fs.path.dirname(path) orelse crate_dir;

    var dir = std.Io.Dir.cwd();
    const file = dir.openFile(io, path, .{}) catch |err| {
        try reportSourceRootError(io, stdout, crate_dir, err);
        return err;
    };
    defer file.close(io);
    var io_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &io_buf);
    const src = reader.interface.allocRemaining(allocator, .limited(1 << 24)) catch |err| {
        try reportSourceRootError(io, stdout, crate_dir, err);
        return err;
    };

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
        .base_dir = lib_dir,
        .io = io,
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
    _ = g.symbol_table.get(mod_id) orelse return error.IncompleteDiagnosticGraph;
    const m = g.module(mod_id) orelse return error.IncompleteDiagnosticGraph;
    for (m.items) |item_id| {
        const e = g.symbol_table.get(item_id) orelse return error.IncompleteDiagnosticGraph;
        try buf.appendNTimes(allocator, ' ', depth * 2);
        const line = try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ @tagName(e.kind), e.name });
        try buf.appendSlice(allocator, line);
        if (e.kind == .use_) {
            const use_decl = g.useById(item_id) orelse return error.IncompleteDiagnosticGraph;
            if (use_decl.target != 0) {
                _ = g.symbol_table.get(use_decl.target) orelse return error.IncompleteDiagnosticGraph;
            }
        }
        if (e.kind == .module) {
            try dumpEntities(allocator, buf, g, item_id, depth + 1);
        }
    }
}

/// `--dump-names <crate-dir>`: parse the crate's source with tree-sitter, run
/// the P1 name-resolution pass, and print each resolved use declaration as
/// `use <entity name> -> <resolved target name>` (or `<unresolved>` when the
/// target is 0).
fn dumpNames(io: std.Io, init: std.process.Init, stdout: std.Io.File, crate_dir: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const model = translate_rust.model;

    // Resolve the lib source file (src/lib.rs or lib.rs).
    const path = resolveLibSource(allocator, io, crate_dir) catch |err| {
        try reportSourceRootError(io, stdout, crate_dir, err);
        return err;
    };
    const lib_dir = std.fs.path.dirname(path) orelse crate_dir;

    var dir = std.Io.Dir.cwd();
    const file = dir.openFile(io, path, .{}) catch |err| {
        try reportSourceRootError(io, stdout, crate_dir, err);
        return err;
    };
    defer file.close(io);
    var io_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &io_buf);
    const src = reader.interface.allocRemaining(allocator, .limited(1 << 24)) catch |err| {
        try reportSourceRootError(io, stdout, crate_dir, err);
        return err;
    };

    // Build a fresh graph + tables (mirrors dumpTypes).
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
        .base_dir = lib_dir,
        .io = io,
    };
    try model.cst.extractFile(&ctx);

    // P1 name resolution fills each UseDecl's kind/target.
    try model.names.resolveGraph(allocator, &g);

    // Print each resolved use declaration.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    for (g.uses.items) |u| {
        const e = g.symbol_table.get(u.id) orelse return error.IncompleteDiagnosticGraph;
        try out.appendSlice(allocator, "use ");
        try out.appendSlice(allocator, e.name);
        try out.appendSlice(allocator, " -> ");
        if (u.target != 0) {
            const target = g.symbol_table.get(u.target) orelse return error.IncompleteDiagnosticGraph;
            try out.appendSlice(allocator, target.name);
        } else {
            try out.appendSlice(allocator, "<unresolved>");
        }
        try out.append(allocator, '\n');
    }
    try stdout.writeStreamingAll(io, out.items);
}
/// `--dump-infer <crate-dir>`: parse the crate's source with tree-sitter, run
/// the P1 name-resolution pass, extract function bodies, run P3 type inference,
/// and print inferred types for all lowered expressions.
fn dumpInfer(io: std.Io, init: std.process.Init, stdout: std.Io.File, crate_dir: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const model = translate_rust.model;

    // Resolve the lib source file (src/lib.rs or lib.rs).
    const path = resolveLibSource(allocator, io, crate_dir) catch |err| {
        try reportSourceRootError(io, stdout, crate_dir, err);
        return err;
    };
    const lib_dir = std.fs.path.dirname(path) orelse crate_dir;

    var dir = std.Io.Dir.cwd();
    const file = dir.openFile(io, path, .{}) catch |err| {
        try reportSourceRootError(io, stdout, crate_dir, err);
        return err;
    };
    defer file.close(io);
    var io_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &io_buf);
    const src = reader.interface.allocRemaining(allocator, .limited(1 << 24)) catch |err| {
        try reportSourceRootError(io, stdout, crate_dir, err);
        return err;
    };

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
        .base_dir = lib_dir,
        .io = io,
    };
    try model.cst.extractFile(&ctx);
    try model.names.resolveGraph(allocator, &g);

    var exprs_list: std.ArrayListUnmanaged(model.exprs.Expr) = .empty;
    var stmts_list: std.ArrayListUnmanaged(model.exprs.Statement) = .empty;
    var pats_list: std.ArrayListUnmanaged(model.exprs.Pattern) = .empty;

    var module_srcs: std.AutoHashMapUnmanaged(model.spine.EntityId, []const u8) = .empty;
    defer module_srcs.deinit(allocator);
    try module_srcs.put(allocator, 0, src);
    for (g.modules.items) |m| {
        if (m.id == 0) continue;
        if (m.source_path) |sp| {
            var mdir = std.Io.Dir.cwd();
            const mf = mdir.openFile(io, sp, .{}) catch |err| {
                try reportSourceRootError(io, stdout, crate_dir, err);
                return err;
            };
            defer mf.close(io);
            var mio_buf: [4096]u8 = undefined;
            var mreader = mf.reader(io, &mio_buf);
            const m_src = mreader.interface.allocRemaining(allocator, .limited(1 << 24)) catch |err| {
                try reportSourceRootError(io, stdout, crate_dir, err);
                return err;
            };
            try module_srcs.put(allocator, m.id, m_src);
        }
    }
    var ts_ctx: model.ts_ext.Ctx = .{
        .alloc = allocator,
        .g = &g,
        .exprs = &exprs_list,
        .stmts = &stmts_list,
        .pats = &pats_list,
        .types = &types_list,
        .bodies_list = &bodies_list,
        .src = src,
        .mod_id = 0,
    };

    for (g.symbol_table.entities.items) |ent| {
        if (ent.kind != .fn_) continue;
        var cur = ent.parent orelse return error.IncompleteDiagnosticGraph;
        var m_src: ?[]const u8 = null;
        while (g.module(cur)) |m| {
            if (module_srcs.get(cur)) |s| {
                m_src = s;
                break;
            }
            cur = m.parent orelse break;
        }
        const fn_src = m_src orelse return error.IncompleteDiagnosticGraph;
        ts_ctx.src = fn_src;
        ts_ctx.mod_id = ent.parent.?;
        const extracted = try model.ts_ext.extractFunction(&ts_ctx, ent.id);
        if (!extracted) return error.IncompleteDiagnosticGraph;
    }

    const b: model.bodies.Bodies = .{
        .exprs = exprs_list.items,
        .stmts = stmts_list.items,
        .pats = pats_list.items,
        .types = types_list.items,
        .bodies = bodies_list.items,
    };

    var inferred = try model.infer.solve(allocator, &b);
    defer inferred.deinit(allocator);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    for (b.exprs, 0..) |e, idx| {
        const tid = inferred.getType(@intCast(idx)) orelse
            return error.IncompleteDiagnosticGraph;
        if (tid >= b.types.len) return error.IncompleteDiagnosticGraph;
        const t = b.types[tid];
        const ty_str = switch (t) {
            .prim => |p| @tagName(p),
            else => @tagName(t),
        };
        const line = try std.fmt.allocPrint(
            allocator,
            "expr {d} ({s}): {s}\n",
            .{ idx, @tagName(e.kind), ty_str },
        );
        try out.appendSlice(allocator, line);
    }

    try stdout.writeStreamingAll(io, out.items);
}

/// `--dump model <file>`: parse a sidecar wire-format JSON dump and print the
/// crate/module inventory.
fn dumpJsonModel(
    io: std.Io,
    init: std.process.Init,
    stdout: std.Io.File,
    path: []const u8,
) !void {
    var dir = std.Io.Dir.cwd();
    const file = dir.openFile(io, path, .{}) catch |err| {
        try stdout.writeStreamingAll(io, "translate-rust: unable to read dump file ");
        try stdout.writeStreamingAll(io, path);
        try stdout.writeStreamingAll(io, "\n");
        return err;
    };
    defer file.close(io);
    var io_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &io_buf);
    const bytes = reader.interface.allocRemaining(init.gpa, .limited(1 << 30)) catch |err| {
        try stdout.writeStreamingAll(io, "translate-rust: unable to read dump file ");
        try stdout.writeStreamingAll(io, path);
        try stdout.writeStreamingAll(io, "\n");
        return err;
    };
    defer init.gpa.free(bytes);

    var g = translate_rust.model.json.parse(init.gpa, bytes) catch |err| {
        try stdout.writeStreamingAll(io, "translate-rust: invalid or incomplete diagnostic graph\n");
        return err;
    };
    defer g.deinit();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(init.gpa);

    if (g.crates.items.len == 0) {
        try stdout.writeStreamingAll(io, "translate-rust: incomplete diagnostic graph\n");
        return error.IncompleteDiagnosticGraph;
    }
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

/// Dispatch for `--dump <mode>`. Modes that operate on Wire JSON remain in
/// the classic `dumpModel`; Rust-source modes (`rustir`, `zigast`) call the
/// frontend and serialize the resulting IR or ZigAST.
fn dumpDispatch(
    io: std.Io,
    init: std.process.Init,
    stdout: std.Io.File,
    arg_it: *std.process.Args.Iterator,
    strategy_name: ?[]const u8,
) !void {
    const mode = arg_it.next() orelse {
        try stdout.writeStreamingAll(io,
            \\usage: translate-rust --dump <model|rustir|zigast> <path>
            \\
        );
        return error.MissingCliArgument;
    };

    if (std.mem.eql(u8, mode, "model")) {
        const path = arg_it.next() orelse {
            try stdout.writeStreamingAll(io, "usage: translate-rust --dump model <file.json>\n");
            return error.MissingCliArgument;
        };
        if (path.len == 0 or std.mem.startsWith(u8, path, "-")) {
            try stdout.writeStreamingAll(io, "usage: translate-rust --dump model <file.json>\n");
            return error.MissingCliArgument;
        }
        try expectNoMoreArguments(io, stdout, arg_it);
        try dumpJsonModel(io, init, stdout, path);
        return;
    }

    if (std.mem.eql(u8, mode, "rustir")) {
        const crate_dir = arg_it.next() orelse {
            try stdout.writeStreamingAll(io, "usage: translate-rust --dump rustir <crate-dir>\n");
            return error.MissingCliArgument;
        };
        if (crate_dir.len == 0 or std.mem.startsWith(u8, crate_dir, "-")) {
            try stdout.writeStreamingAll(io, "usage: translate-rust --dump rustir <crate-dir>\n");
            return error.MissingCliArgument;
        }
        try expectNoMoreArguments(io, stdout, arg_it);
        try dumpRustIr(io, init, stdout, crate_dir);
        return;
    }

    if (std.mem.eql(u8, mode, "zigast")) {
        const crate_dir = arg_it.next() orelse {
            try stdout.writeStreamingAll(io, "usage: translate-rust --dump zigast <crate-dir>\n");
            return error.MissingCliArgument;
        };
        if (crate_dir.len == 0 or std.mem.startsWith(u8, crate_dir, "-")) {
            try stdout.writeStreamingAll(io, "usage: translate-rust --dump zigast <crate-dir>\n");
            return error.MissingCliArgument;
        }
        try expectNoMoreArguments(io, stdout, arg_it);
        try dumpZigAst(io, init, stdout, crate_dir, strategy_name);
        return;
    }

    try stdout.writeStreamingAll(io, "translate-rust: unknown dump mode '");
    try stdout.writeStreamingAll(io, mode);
    try stdout.writeStreamingAll(io, "'\n");
    try stdout.writeStreamingAll(
        io,
        "usage: translate-rust --dump <model|rustir|zigast> <path>\n",
    );
    return error.UnknownDumpMode;
}

/// `--dump rustir <crate-dir>`: run the full frontend analysis and print the
/// serialized `ir.RustIr` JSON to stdout.
fn dumpRustIr(
    io: std.Io,
    init: std.process.Init,
    stdout: std.Io.File,
    crate_dir: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rust_ir = try translate_rust.frontend.analyzeCrate(allocator, io, crate_dir);
    const ser_ir: translate_rust.ir.serialize.RustIr = rust_ir;
    const json_bytes = try translate_rust.ir.serialize.encode(allocator, &ser_ir);
    try stdout.writeStreamingAll(io, json_bytes);
    try stdout.writeStreamingAll(io, "\n");
}

/// Resolve the selected lowering strategy into a vtable-backed pointer, or
/// null to let the lowering engine pick the default.
fn resolveStrategy(
    name: ?[]const u8,
    out: *translate_rust.backend.strategy.LoweringStrategy,
    context: *anyopaque,
) ?*const translate_rust.backend.strategy.LoweringStrategy {
    if (name) |n| {
        if (std.mem.eql(u8, n, "embedded")) {
            out.* = .{
                .ptr = context,
                .vtable = &.{
                    .lowerType = translate_rust.backend.zig.strategies.embedded.EmbeddedStrategy.lowerType,
                    .lowerStdGeneric = translate_rust.backend.zig.strategies.embedded.EmbeddedStrategy.lowerStdGeneric,
                },
            };
            return out;
        }
        // "default" falls through to the engine default by returning null.
    }
    return null;
}

/// `--dump zigast <crate-dir>`: run the frontend analysis, lower to ZigAST, and
/// print the serialized `backend.zig.ast.Package` JSON to stdout.
fn dumpZigAst(
    io: std.Io,
    init: std.process.Init,
    stdout: std.Io.File,
    crate_dir: []const u8,
    strategy_name: ?[]const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rust_ir = try translate_rust.frontend.analyzeCrate(allocator, io, crate_dir);
    try translate_rust.ir.validateForTranslation(&rust_ir);

    var default_strategy: translate_rust.backend.zig.strategies.default.DefaultStrategy = .{};
    var strat: translate_rust.backend.strategy.LoweringStrategy = .{
        .ptr = &default_strategy,
        .vtable = &.{
            .lowerType = translate_rust.backend.zig.strategies.embedded.EmbeddedStrategy.lowerType,
            .lowerStdGeneric = translate_rust.backend.zig.strategies.embedded.EmbeddedStrategy.lowerStdGeneric,
        },
    };
    const maybe_strat = resolveStrategy(strategy_name, &strat, &default_strategy);

    const pkg = try translate_rust.backend.zig.lower.lowerRustIr(allocator, &rust_ir, maybe_strat);
    const json_bytes = try translate_rust.backend.zig.serialize.encode(allocator, &pkg);
    try stdout.writeStreamingAll(io, json_bytes);
    try stdout.writeStreamingAll(io, "\n");
}

fn validateStrategy(name: []const u8) bool {
    return std.mem.eql(u8, name, "default") or std.mem.eql(u8, name, "embedded");
}

fn dumpModule(
    gpa: std.mem.Allocator,
    g: *const translate_rust.model.graph.CrateGraph,
    buf: *std.ArrayListUnmanaged(u8),
    mod_id: translate_rust.model.spine.EntityId,
    depth: usize,
) !void {
    _ = g.symbol_table.get(mod_id) orelse return error.IncompleteDiagnosticGraph;
    const m = g.module(mod_id) orelse return error.IncompleteDiagnosticGraph;

    for (m.items) |item_id| {
        const e = g.symbol_table.get(item_id) orelse return error.IncompleteDiagnosticGraph;

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
                const use_decl = g.useById(item_id) orelse return error.IncompleteDiagnosticGraph;
                if (use_decl.target != 0) {
                    const target = g.symbol_table.get(use_decl.target) orelse
                        return error.IncompleteDiagnosticGraph;
                    try buf.appendSlice(gpa, target.name);
                } else {
                    try buf.appendSlice(gpa, "<unresolved>");
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
    if (out_dir) |dest| {
        try translate_rust.driver.translateWireJson(init.gpa, io, path, dest);
        const msg = try std.fmt.allocPrint(init.gpa, "translated {s} to {s}\n", .{ path, dest });
        defer init.gpa.free(msg);
        try stdout.writeStreamingAll(io, msg);
        return;
    }
    try translate_rust.driver.emitWireJson(init.gpa, io, stdout, path);
}

fn printUsage(io: std.Io, stdout: std.Io.File) !void {
    try stdout.writeStreamingAll(io,
        \\translate-rust — Rust → Zig translation pipeline
        \\
        \\usage: translate-rust <crate-dir> -o <dir>  translate Rust source to a Zig package
        \\       translate-rust <file.json> [-o dir]  translate canonical v6 wire JSON
        \\       translate-rust --emit-package <file.json> -o <dir>  emit a standalone Zig package
        \\       translate-rust --dump model <file>   parse a sidecar wire-format JSON dump and print
        \\                                            the crate/module inventory
        \\       translate-rust --dump rustir <crate-dir>  run the frontend analysis and print the
        \\                                            serialized Rust semantic IR (JSON)
        \\       translate-rust --dump zigast <crate-dir>  lower to ZigAST and print the serialized
        \\                                            package AST (JSON)
        \\       translate-rust --strategy <default|embedded>  select the Zig lowering strategy
        \\       translate-rust --version             print version
        \\       translate-rust --help                show this help
        \\
    );
}
