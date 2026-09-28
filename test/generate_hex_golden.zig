//! Regenerate canonical source-derived hex goldens from validated IR.

const std = @import("std");
const translate_rust = @import("translate_rust");

const crate_dir = "test/crates/hex";
const rust_ir_path = "test/golden/rust_ir/hex.rustir.json";
const rust_ir_temp_path = "test/golden/rust_ir/hex.rustir.json.tmp";
const zig_ast_path = "test/golden/zig_ast/hex.zigast.json";
const zig_ast_temp_path = "test/golden/zig_ast/hex.zigast.json.tmp";

fn writeCanonicalFile(io: std.Io, path: []const u8, temp_path: []const u8, content: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(temp_path)) |parent_path| {
        try cwd.createDirPath(io, parent_path);
    }
    cwd.deleteFile(io, temp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    errdefer cwd.deleteFile(io, temp_path) catch {};
    const temporary = try cwd.createFile(io, temp_path, .{ .exclusive = true });
    defer temporary.close(io);
    try temporary.writeStreamingAll(io, content);
    try cwd.rename(temp_path, cwd, path, io);
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rust_ir = try translate_rust.frontend.pipeline.analyzeCrateWithOptions(
        allocator,
        init.io,
        crate_dir,
        .{
            .include_tests = true,
            .cfg = .{
                .features = &.{},
                .target_pointer_width = 64,
                .docsrs = false,
            },
        },
    );
    defer rust_ir.deinitInstantiations(allocator);
    try translate_rust.ir.validateForTranslation(&rust_ir);

    const rust_ir_json = try translate_rust.ir.serialize.encode(allocator, &rust_ir);
    try writeCanonicalFile(init.io, rust_ir_path, rust_ir_temp_path, rust_ir_json);

    const pkg = try translate_rust.backend.zig.lower.lowerRustIr(allocator, &rust_ir, null);
    const zig_ast_json = try translate_rust.backend.zig.serialize.encode(allocator, &pkg);
    try writeCanonicalFile(init.io, zig_ast_path, zig_ast_temp_path, zig_ast_json);
    for (pkg.files) |*file| {
        const source = try translate_rust.backend.zig.emit.emitFile(allocator, file);
        const source_path = try std.fmt.allocPrint(
            allocator,
            "test/golden/zig_src/hex/{s}",
            .{file.path},
        );
        const source_temporary_path = try std.fmt.allocPrint(
            allocator,
            "test/golden/zig_src/hex/{s}.tmp",
            .{file.path},
        );
        try writeCanonicalFile(init.io, source_path, source_temporary_path, source);
    }
}
