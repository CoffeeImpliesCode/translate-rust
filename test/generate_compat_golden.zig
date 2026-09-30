//! Regenerate the pinned compat emitted-source goldens from validated IR.
//!
//! `golden_test.zig` pins this fixture by emitted source alone, so no RustIr or
//! Zig AST snapshot is written here: those payloads would grow for reasons that
//! do not change the text a staged crate ships.

const std = @import("std");
const translate_rust = @import("translate_rust");

const crate_dir = "test/crates/compat";

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

    const pkg = try translate_rust.backend.zig.lower.lowerRustIr(allocator, &rust_ir, null);
    for (pkg.files) |*file| {
        const source = try translate_rust.backend.zig.emit.emitFile(allocator, file);
        const source_path = try std.fmt.allocPrint(
            allocator,
            "test/golden/zig_src/compat/{s}",
            .{file.path},
        );
        const source_temporary_path = try std.fmt.allocPrint(
            allocator,
            "test/golden/zig_src/compat/{s}.tmp",
            .{file.path},
        );
        try writeCanonicalFile(init.io, source_path, source_temporary_path, source);
    }
}
