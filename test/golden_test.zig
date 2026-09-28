//! translate-rust golden serialization tests.
//!
//! The source-native `mini` and `fnv` fixtures must complete this path and
//! provide canonical RustIR and Zig AST snapshots plus non-empty emitted
//! sources. The wire corpus fixtures `fnv` and `hex` remain strict rejection
//! cases.
//! The separate inline source test below preserves generic-instantiation
//! extraction coverage, then removes the generic definition body and requires
//! a typed lowering rejection for the resulting incomplete IR.
//!
//!   1. `frontend.analyzeCrate`   → `ir.RustIr`
//!   2. `ir.validateForTranslation` → typed frontend/IR validation
//!   3. `backend.Lowering`        → package emission or typed rejection

const std = @import("std");
const translate_rust = @import("translate_rust");

const frontend = translate_rust.frontend;
const ir = translate_rust.ir;
const backend = translate_rust.backend;

/// Compare the golden payload to `actual`. A single final newline is ignored
/// because text editors and generated snapshots use different file endings;
/// every other byte remains strict.
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
        const golden_payload = if (golden.len > 0 and golden[golden.len - 1] == '\n')
            golden[0 .. golden.len - 1]
        else
            golden;
        if (!std.mem.eql(u8, golden_payload, actual)) {
            std.debug.print(
                "golden mismatch for {s}\n--- golden ({d} bytes) ---\n{s}\n--- actual ({d} bytes) ---\n{s}\n",
                .{ gold_path, golden_payload.len, golden_payload, actual.len, actual },
            );
            return error.GoldenMismatch;
        }
    } else |_| {
        return error.GoldenMissing;
    }
}

fn expectPackageShape(
    pkg: *const backend.zig.ast.Package,
    expected_paths: []const []const u8,
    source_claims_tests: bool,
) !*const backend.zig.ast.File {
    if (pkg.files.len == 0) return error.EmptyPackage;
    if (pkg.files.len != expected_paths.len) return error.SourceFileSetMismatch;

    var root_file: ?*const backend.zig.ast.File = null;
    for (pkg.files, 0..) |*file, index| {
        for (pkg.files[index + 1 ..]) |other| {
            if (std.mem.eql(u8, file.path, other.path)) return error.DuplicateSourceFilePath;
        }

        var expected = false;
        for (expected_paths) |expected_path| {
            if (std.mem.eql(u8, file.path, expected_path)) {
                expected = true;
                break;
            }
        }
        if (!expected) return error.UnexpectedSourceFile;

        if (std.mem.eql(u8, file.path, "src/root.zig")) {
            if (root_file != null) return error.DuplicateRootFile;
            root_file = file;
        }
    }

    for (expected_paths) |expected_path| {
        var found = false;
        for (pkg.files) |file| {
            if (std.mem.eql(u8, file.path, expected_path)) {
                found = true;
                break;
            }
        }
        if (!found) return error.MissingSourceFile;
    }

    const root = root_file orelse return error.RootFileMissing;
    if (root.imports.len == 0 and root.decls.len == 0 and root.tests.len == 0) {
        return error.EmptyRoot;
    }

    if (source_claims_tests) {
        var test_count: usize = 0;
        for (pkg.files) |file| test_count += file.tests.len;
        if (test_count == 0) return error.NoTranslatedTests;
    }
    return root;
}

fn runGoldenFixture(
    fixture_name: []const u8,
    crate_dir: []const u8,
    expected_rejection: ?anyerror,
    expected_paths: []const []const u8,
    source_claims_tests: bool,
    check_source_goldens: bool,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const test_io = std.testing.io;

    const rust_ir_path = try std.fmt.allocPrint(allocator, "test/golden/rust_ir/{s}.rustir.json", .{fixture_name});
    const zig_ast_path = try std.fmt.allocPrint(allocator, "test/golden/zig_ast/{s}.zigast.json", .{fixture_name});

    if (expected_rejection) |expected_error| {
        const rust_ir = frontend.analyzeCrate(allocator, test_io, crate_dir) catch |err| {
            if (err == expected_error) return;
            return err;
        };
        if (ir.validateForTranslation(&rust_ir)) |_| {
            return error.IncompleteFixtureAccepted;
        } else |err| {
            if (err == expected_error) return;
            return err;
        }
    }

    // 1. Frontend analysis → RustIr.
    const rust_ir = try frontend.analyzeCrate(allocator, test_io, crate_dir);

    // 2. Encode the complete canonical RustIr to JSON and snapshot. The
    // frontend and serializer intentionally share the same nominal model;
    // assigning the value directly preserves every field, including graph
    // metadata and monomorphization instantiations.
    const wire_ir: ir.serialize.RustIr = rust_ir;
    try ir.validateForTranslation(&rust_ir);
    const rust_ir_json = try ir.serialize.encode(allocator, &wire_ir);
    defer allocator.free(rust_ir_json);
    try checkGolden(allocator, test_io, rust_ir_path, rust_ir_json);

    // 3. Lower RustIr → ast.Package via the default strategy.
    const pkg = try backend.zig.lower.lowerRustIr(allocator, &rust_ir, null);
    const root_file = try expectPackageShape(&pkg, expected_paths, source_claims_tests);
    try std.testing.expectEqualStrings("src/root.zig", root_file.path);
    var package_for_structural_validation = pkg;
    package_for_structural_validation.fingerprint =
        package_for_structural_validation.fingerprint orelse 0;
    try backend.zig.ast.validateForTranslation(&package_for_structural_validation);

    // 4. Encode the package AST to JSON and snapshot.
    const zig_ast_json = try backend.zig.serialize.encode(allocator, &pkg);
    defer allocator.free(zig_ast_json);
    try checkGolden(allocator, test_io, zig_ast_path, zig_ast_json);

    // 5. Emit each source file; assert it produces valid, non-empty Zig.
    for (pkg.files) |*file| {
        const src = try backend.zig.emit.emitFile(allocator, file);
        defer allocator.free(src);
        if (src.len == 0) {
            if (std.mem.eql(u8, file.path, "src/root.zig")) return error.EmptyRootEmit;
            return error.EmptyEmit;
        }
        if (check_source_goldens) {
            const source_payload = if (src[src.len - 1] == '\n')
                src[0 .. src.len - 1]
            else
                src;
            const source_golden_path = try std.fmt.allocPrint(
                allocator,
                "test/golden/zig_src/{s}/{s}",
                .{ fixture_name, file.path },
            );
            try checkGolden(allocator, test_io, source_golden_path, source_payload);
        }
    }
}

test "golden: mini translates to canonical package" {
    try runGoldenFixture(
        "mini",
        "test/crates/mini",
        null,
        &.{ "src/root.zig", "src/util.zig" },
        false,
        true,
    );
}
test "golden: fnv source translates to canonical package" {
    try runGoldenFixture("fnv", "test/crates/fnv", null, &.{"src/root.zig"}, false, true);
}

test "golden: fnv included tests contain only assertion unsupported expressions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var rust_ir = try frontend.pipeline.analyzeCrateWithOptions(
        allocator,
        std.testing.io,
        "test/crates/fnv",
        .{ .include_tests = true },
    );
    defer rust_ir.deinitInstantiations(allocator);

    const assertion_prefix = "assertion:";
    var only_assertion_markers = true;
    for (rust_ir.bodies.exprs) |expression| {
        const reason = switch (expression.kind) {
            .unsupported => |unsupported| unsupported.reason,
            else => continue,
        };

        var is_assertion_marker =
            std.mem.startsWith(u8, reason, assertion_prefix) and
            reason.len > assertion_prefix.len;
        if (is_assertion_marker) {
            for (reason[assertion_prefix.len..]) |character| {
                if (character < '0' or character > '9') {
                    is_assertion_marker = false;
                    break;
                }
            }
        }
        if (!is_assertion_marker) {
            only_assertion_markers = false;
            std.debug.print(
                "unexpected FNV unsupported expression reason: \"{s}\"\n",
                .{reason},
            );
        }
    }
    try std.testing.expect(only_assertion_markers);

    var test_module_id: ?u32 = null;
    for (rust_ir.graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .module and std.mem.eql(u8, entity.name, "test")) {
            test_module_id = entity.id;
            break;
        }
    }
    try std.testing.expect(test_module_id != null);

    var basic_tests_id: ?u32 = null;
    for (rust_ir.graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .fn_ and
            std.mem.eql(u8, entity.name, "basic_tests") and
            entity.parent != null and
            entity.parent.? == test_module_id.?)
        {
            basic_tests_id = entity.id;
            break;
        }
    }
    try std.testing.expect(basic_tests_id != null);
    try std.testing.expect(basic_tests_id.? < rust_ir.bodies.bodies.len);

    const basic_tests_body = switch (rust_ir.bodies.bodies[basic_tests_id.?]) {
        .fn_ => |function_body| function_body,
        else => return error.MissingFnvBasicTestsBody,
    };
    try std.testing.expect(basic_tests_body.body < rust_ir.bodies.exprs.len);
    const basic_tests_block = switch (rust_ir.bodies.exprs[basic_tests_body.body].kind) {
        .block => |block| block,
        else => return error.InvalidFnvBasicTestsBody,
    };
    try std.testing.expect(basic_tests_block.statements.len > 0);
}

test "golden: fnv preserves hasher methods" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var rust_ir = try frontend.analyzeCrate(allocator, std.testing.io, "test/crates/fnv");
    defer rust_ir.deinitInstantiations(allocator);
    try ir.validateForTranslation(&rust_ir);
    const pkg = try backend.zig.lower.lowerRustIr(allocator, &rust_ir, null);
    const root = try expectPackageShape(&pkg, &.{"src/root.zig"}, false);

    var hasher: ?backend.zig.ast.StructDecl = null;
    for (root.decls) |decl| {
        if (decl == .struct_decl and std.mem.eql(u8, decl.struct_decl.name, "FnvHasher")) {
            hasher = decl.struct_decl;
            break;
        }
    }
    const decl = hasher orelse return error.MissingFnvHasher;

    var found_default = false;
    var found_finish = false;
    var found_write = false;
    for (decl.decls) |member| {
        if (member != .fn_decl) continue;
        const function = member.fn_decl;
        if (function.body == null) return error.EmptyFnvMethod;
        if (std.mem.eql(u8, function.name, "default")) found_default = true;
        if (std.mem.eql(u8, function.name, "finish")) found_finish = true;
        if (std.mem.eql(u8, function.name, "write")) found_write = true;
    }
    try std.testing.expect(found_default);
    try std.testing.expect(found_finish);
    try std.testing.expect(found_write);
}

test "golden: hex library translates and its test module still rejects" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const test_io = std.testing.io;

    // The library half of hex lowers now that a declared `Option` return
    // type reaches its variants, a user-defined `Iterator` drives a `for`
    // loop through `next()`, and `collect` builds an owned `String`.
    const library = try frontend.analyzeCrate(allocator, test_io, "test/crates/hex");
    try ir.validateForTranslation(&library);

    // Its `#[cfg(test)]` module still needs structural equality for `Result`
    // and for payload-carrying enums, so the full pipeline still rejects it.
    const with_tests = try frontend.pipeline.analyzeCrateWithOptions(
        allocator,
        test_io,
        "test/crates/hex",
        .{ .include_tests = true },
    );
    try std.testing.expectError(
        error.UnsupportedExpression,
        ir.validateForTranslation(&with_tests),
    );
}
test "golden: missing source directory propagates ingestion failure" {
    try std.testing.expectError(
        error.RootSourceNotFound,
        runGoldenFixture(
            "missing",
            "test/crates/missing",
            error.UnsupportedExpression,
            &.{},
            false,
            false,
        ),
    );
}

test "golden: empty packages and claimed tests fail closed" {
    const empty_package = backend.zig.ast.Package{
        .name = "empty",
        .fingerprint = 1,
        .files = &.{},
    };
    try std.testing.expectError(
        error.EmptyPackage,
        expectPackageShape(&empty_package, &.{"src/root.zig"}, false),
    );

    const root_without_tests = backend.zig.ast.File{
        .path = "src/root.zig",
        .imports = &.{.{ .local_name = "std", .module_or_path = "std" }},
    };
    const no_tests_package = backend.zig.ast.Package{
        .name = "no_tests",
        .fingerprint = 1,
        .files = &.{root_without_tests},
    };
    const no_tests_root = try expectPackageShape(&no_tests_package, &.{"src/root.zig"}, false);
    try std.testing.expectEqualStrings("src/root.zig", no_tests_root.path);
    try std.testing.expectError(
        error.NoTranslatedTests,
        expectPackageShape(&no_tests_package, &.{"src/root.zig"}, true),
    );
}

test "golden: package validation rejects null fingerprints" {
    const missing_fingerprint = backend.zig.ast.Package{
        .name = "missing_fingerprint",
        .fingerprint = null,
        .files = &.{.{ .path = "src/root.zig" }},
    };
    try std.testing.expectError(
        error.MissingFingerprint,
        backend.zig.ast.validateForTranslation(&missing_fingerprint),
    );
}

test "source pipeline rejects incomplete generic definitions before package emission" {
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

    var rust_ir = try frontend.pipeline.analyzeSource(
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
    try ir.validateForTranslation(&rust_ir);
    try std.testing.expect(expected_foo_id < rust_ir.bodies.bodies.len);
    const incomplete_bodies = try allocator.dupe(ir.bodies.BodyKind, rust_ir.bodies.bodies);
    incomplete_bodies[expected_foo_id] = .{ .none = {} };
    rust_ir.bodies.bodies = incomplete_bodies;
    try std.testing.expect(saw_u32);
    try std.testing.expect(saw_u8_slice);

    try std.testing.expectError(
        error.DeclarationBodyMismatch,
        backend.zig.lower.lowerRustIr(allocator, &rust_ir, null),
    );
}
