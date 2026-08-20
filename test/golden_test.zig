//! translate-rust golden serialization tests.
//!
//! For each standard fixture crate (`mini`, `fnv`, `hex`), runs the full
//! pipeline and snapshots the intermediate and final representations:
//!
//!   1. `frontend.analyzeCrate`   → `ir.RustIR`
//!   2. `ir.serialize.encode`     → `test/golden/rust_ir/<name>.rustir.json`
//!   3. `backend.Lowering`        → `ast.Package`
//!   4. `backend.serialize.encode`→ `test/golden/zig_ast/<name>.zigast.json`
//!   5. `backend.emit.emitFile`   → valid, non-empty Zig source per file
//!
//! When a golden file does not exist yet it is written from the current
//! output (used for initial check-in); once present, the output must match
//! it byte-for-byte.

const std = @import("std");
const translate_rust = @import("translate_rust");

const frontend = translate_rust.frontend;
const ir = translate_rust.ir;
const backend = translate_rust.backend;

/// Compare `actual` to the golden file at `gold_path`. If the golden file is
/// absent, write `actual` to it (initial check-in generation).
fn checkGolden(
    allocator: std.mem.Allocator,
    test_io: std.Io,
    gold_path: []const u8,
    actual: []const u8,
) !void {
    var dir = std.Io.Dir.cwd();

    if (dir.openFile(test_io, gold_path, .{})) |file| {
        defer file.close(test_io);
        var io_buf: [4096]u8 = undefined;
        var reader = file.reader(test_io, &io_buf);
        const golden = try reader.interface.allocRemaining(allocator, .limited(1 << 28));
        defer allocator.free(golden);
        if (!std.mem.eql(u8, golden, actual)) {
            std.debug.print(
                "golden mismatch for {s}\n--- golden ({d} bytes) ---\n{s}\n--- actual ({d} bytes) ---\n{s}\n",
                .{ gold_path, golden.len, golden, actual.len, actual },
            );
            return error.GoldenMismatch;
        }
    } else |_| {
        // Generate the golden file from the current output.
        const dirname = std.fs.path.dirname(gold_path) orelse ".";
        try dir.createDirPath(test_io, dirname);
        const f = try dir.createFile(test_io, gold_path, .{});
        defer f.close(test_io);
        try f.writeStreamingAll(test_io, actual);
    }
}

/// Run the full pipeline for one fixture crate and assert every golden.
fn runGoldenFixture(
    fixture_name: []const u8,
    crate_dir: []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const test_io = std.testing.io;

    const rust_ir_path = try std.fmt.allocPrint(allocator, "test/golden/rust_ir/{s}.rustir.json", .{fixture_name});
    const zig_ast_path = try std.fmt.allocPrint(allocator, "test/golden/zig_ast/{s}.zigast.json", .{fixture_name});

    // 1. Frontend analysis → RustIR.
    const rust_ir = try frontend.analyzeCrate(allocator, test_io, crate_dir);

    // 2. Encode RustIR to JSON and snapshot. The frontend returns the IR
    // module's canonical `root.RustIR`; `ir.serialize` keeps a
    // self-contained copy of the struct for wire round-tripping, with
    // identical field types — convert surgically.
    const wire_ir: ir.serialize.RustIR = .{
        .crate_name = rust_ir.crate_name,
        .edition = rust_ir.edition,
        .graph = rust_ir.graph,
        .types = rust_ir.types,
        .bodies = rust_ir.bodies,
    };
    const rust_ir_json = try ir.serialize.encode(allocator, &wire_ir);
    defer allocator.free(rust_ir_json);
    try checkGolden(allocator, test_io, rust_ir_path, rust_ir_json);

    // 3. Lower RustIR → ast.Package via the default strategy.
    const pkg = try backend.zig.lower.lowerRustIR(allocator, &rust_ir, null);

    // 4. Encode the package AST to JSON and snapshot.
    const zig_ast_json = try backend.zig.serialize.encode(allocator, &pkg);
    defer allocator.free(zig_ast_json);
    try checkGolden(allocator, test_io, zig_ast_path, zig_ast_json);

    // 5. Emit each source file; assert it produces valid, non-empty Zig.
    for (pkg.files) |*file| {
        const src = try backend.zig.emit.emitFile(allocator, file);
        defer allocator.free(src);
        if (src.len == 0) return error.EmptyEmit;
    }
}

test "golden: mini" {
    try runGoldenFixture("mini", "test/crates/mini");
}

test "golden: fnv" {
    try runGoldenFixture("fnv", "test/crates/fnv");
}

test "golden: hex" {
    try runGoldenFixture("hex", "test/crates/hex");
}

test "source pipeline preserves generic instantiations through Zig emission" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const src =
        \\pub struct Foo<T>(pub T);
        \\
        \\pub fn make_u32(value: u32) -> Foo<u32> {
        \\    Foo::<u32>(value)
        \\}
        \\
        \\pub fn make_slice(value: &[u8]) -> Foo<&[u8]> {
        \\    Foo(value)
        \\}
    ;

    const rust_ir = try frontend.pipeline.analyzeSource(
        allocator,
        "generic_source",
        "2021",
        src,
    );

    var foo_id: ?ir.spine.EntityId = null;
    for (rust_ir.graph.symbol_table.entities.items) |entity| {
        if (entity.kind != .struct_ or !std.mem.eql(u8, entity.name, "Foo")) continue;
        try std.testing.expect(foo_id == null);
        foo_id = entity.id;
    }
    const expected_foo_id = foo_id orelse return error.FooEntityMissing;

    try std.testing.expectEqual(@as(usize, 2), rust_ir.instantiations.len);
    var saw_u32 = false;
    var saw_u8_slice = false;
    for (rust_ir.instantiations) |instantiation| {
        try std.testing.expectEqual(expected_foo_id, instantiation.generic_id);
        try std.testing.expectEqual(@as(usize, 1), instantiation.args.params.len);

        switch (instantiation.args.params[0]) {
            .prim => |prim| {
                try std.testing.expectEqual(ir.types.Prim.u32, prim);
                try std.testing.expectEqualStrings("_u32", instantiation.zig_suffix);
                try std.testing.expect(!saw_u32);
                saw_u32 = true;
            },
            .slice => |slice| {
                try std.testing.expect(slice.const_);
                switch (slice.elem) {
                    .prim => |prim| try std.testing.expectEqual(ir.types.Prim.u8, prim),
                    else => return error.UnexpectedFooSliceElement,
                }
                try std.testing.expectEqualStrings("_u8_slice", instantiation.zig_suffix);
                try std.testing.expect(!saw_u8_slice);
                saw_u8_slice = true;
            },
            else => return error.UnexpectedFooInstantiation,
        }
    }
    try std.testing.expect(saw_u32);
    try std.testing.expect(saw_u8_slice);

    const pkg = try backend.zig.lower.lowerRustIR(allocator, &rust_ir, null);
    var emitted_root: ?[]const u8 = null;
    for (pkg.files) |*file| {
        if (!std.mem.eql(u8, file.path, "src/root.zig")) continue;
        emitted_root = try backend.zig.emit.emitFile(allocator, file);
        break;
    }
    const emitted = emitted_root orelse return error.RootFileMissing;
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.indexOf(u8, emitted, "Foo(comptime T: type)") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "Foo(u32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "Foo([]const u8)") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, ") Foo {") == null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "Foo(value)") == null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "Foo(u32, value)") == null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "Foo([]const u8, value)") == null);
}
