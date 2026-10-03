//! Regenerate canonical source-derived FNV goldens.

const std = @import("std");
const translate_rust = @import("translate_rust");

const crate_dir = "test/crates/fnv";
const zig_ast_path = "test/golden/zig_ast/fnv.zigast.json";
const zig_ast_temp_path = "test/golden/zig_ast/fnv.zigast.json.tmp";

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

    // The same pinned configuration the golden test analyses this fixture
    // with. A snapshot regenerated under anything else cannot be compared
    // against a golden produced under this, so the two must agree.
    var rust_ir = try translate_rust.frontend.pipeline.analyzeCrateWithOptions(
        allocator,
        init.io,
        crate_dir,
        .{
            .include_tests = false,
            .cfg = .{
                .features = &.{},
                .target_pointer_width = 64,
                .docsrs = false,
            },
        },
    );

    const pkg = try translate_rust.backend.zig.lower.lowerRustIr(allocator, &rust_ir, null);
    const zig_ast_json = try translate_rust.backend.zig.serialize.encode(allocator, &pkg);
    try writeCanonicalFile(init.io, zig_ast_path, zig_ast_temp_path, zig_ast_json);
    // Only the `zig_ast` package is written. It is the one golden for this
    // fixture that an assertion reads: `src/backend/zig/documentation_test.zig`
    // decodes it into a typed AST and checks every documentation sentence
    // against the signature it names.
    //
    // This generator used to write the RustIR document and every emitted
    // source file as well. `fnv` is a `typed` golden fixture — its RustIR
    // document is a table of row indices and its emitted text is mostly the
    // crate's own rustdoc — so nothing compared either. They were dead files
    // that looked like coverage, and
    // `test/golden_test.zig`'s "every golden file is read by an assertion" test
    // now rejects any golden file no assertion opens. Writing them again would
    // resurrect exactly that, so they are not written.
}
