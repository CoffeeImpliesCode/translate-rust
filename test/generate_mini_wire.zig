//! Regenerate the canonical wire fixture for `test/crates/mini`.

const std = @import("std");
const translate_rust = @import("translate_rust");

const crate_dir = "test/crates/mini";
const fixture_path = "test/mini.json";
const fixture_temporary_path = "test/mini.json.tmp";
const golden_path = "test/golden/rust_ir/mini.rustir.json";
const golden_temporary_path = "test/golden/rust_ir/mini.rustir.json.tmp";
const zig_ast_golden_path = "test/golden/zig_ast/mini.zigast.json";
const zig_ast_golden_temporary_path = "test/golden/zig_ast/mini.zigast.json.tmp";

fn deleteTemporaryFile(io: std.Io, temporary_path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, temporary_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn writeCanonicalFile(
    io: std.Io,
    path: []const u8,
    temporary_path: []const u8,
    canonical_json: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(temporary_path)) |parent_path| {
        try cwd.createDirPath(io, parent_path);
    }
    try deleteTemporaryFile(io, temporary_path);
    errdefer deleteTemporaryFile(io, temporary_path) catch {};

    {
        const temporary = try cwd.createFile(io, temporary_path, .{ .exclusive = true });
        defer temporary.close(io);
        try temporary.writeStreamingAll(io, canonical_json);
    }

    try cwd.rename(temporary_path, cwd, path, io);
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rust_ir = try translate_rust.frontend.pipeline.analyzeCrate(
        allocator,
        init.io,
        crate_dir,
    );
    defer rust_ir.deinitInstantiations(allocator);
    try translate_rust.ir.validateForTranslation(&rust_ir);

    const canonical_json = try translate_rust.ir.serialize.encode(allocator, &rust_ir);

    try writeCanonicalFile(
        init.io,
        fixture_path,
        fixture_temporary_path,
        canonical_json,
    );
    try writeCanonicalFile(
        init.io,
        golden_path,
        golden_temporary_path,
        canonical_json,
    );
    const pkg = try translate_rust.backend.zig.lower.lowerRustIr(allocator, &rust_ir, null);
    const zig_ast_json = try translate_rust.backend.zig.serialize.encode(allocator, &pkg);
    try writeCanonicalFile(
        init.io,
        zig_ast_golden_path,
        zig_ast_golden_temporary_path,
        zig_ast_json,
    );
    for (pkg.files) |*file| {
        const source = try translate_rust.backend.zig.emit.emitFile(allocator, file);
        const source_path = try std.fmt.allocPrint(
            allocator,
            "test/golden/zig_src/mini/{s}",
            .{file.path},
        );
        const source_temporary_path = try std.fmt.allocPrint(
            allocator,
            "test/golden/zig_src/mini/{s}.tmp",
            .{file.path},
        );
        try writeCanonicalFile(init.io, source_path, source_temporary_path, source);
    }
}
