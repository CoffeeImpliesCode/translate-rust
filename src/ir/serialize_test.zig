//! serialize_test.zig — roundtrip encoding and decoding tests for RustIr.

const std = @import("std");
const root = @import("root.zig");
const spine = root.spine;
const graph = root.graph;
const types = root.types;
const exprs = root.exprs;
const bodies = root.bodies;
const items = root.items;
const serialize = root.serialize;

const valid_crates_json =
    "\"crates\":[{\"name\":\"fixture\",\"edition\":2021,\"kind\":\"lib\",\"root\":0," ++
    "\"is_translated\":true,\"deps\":[],\"entities\":[{\"id\":0,\"kind\":\"module\"," ++
    "\"name\":\"fixture\",\"span\":{\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":1}," ++
    "\"visibility\":{\"kind\":\"public\"},\"parent\":null,\"resolved\":null,\"renamed_to\":null," ++
    "\"attributes\":[]}],\"modules\":[{\"id\":0,\"kind\":\"root\",\"name\":\"fixture\"," ++
    "\"parent\":null,\"source_path\":null,\"is_crate\":true,\"is_extern\":false," ++
    "\"span\":{\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":1}," ++
    "\"items\":[],\"attributes\":[]}],\"uses\":[]}]";

const canonical_empty_payload =
    "{\"format_version\":6,\"crate_name\":\"fixture\",\"edition\":\"2021\"," ++
    "\"sidecar\":null,\"toolchain\":null," ++ valid_crates_json ++
    ",\"types\":[],\"instantiations\":[],\"bodies\":{\"exprs\":[],\"stmts\":[]," ++
    "\"pats\":[],\"types\":[],\"bodies\":[{\"owner\":0,\"body\":{\"kind\":\"none\"}}]}}";
const canonical_cast_types_json =
    "[{\"kind\":\"prim\",\"value\":\"u8\"},{\"kind\":\"prim\",\"value\":\"u64\"}]";
const canonical_cast_exprs_json =
    "[{\"id\":0,\"span\":{\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":1}," ++
    "\"ty\":0,\"kind\":\"literal\",\"value\":{\"kind\":\"int\",\"value\":{\"text\":\"1\"," ++
    "\"value\":\"1\",\"base\":\"dec\",\"ty_suffix\":\"u8\"}}}," ++
    "{\"id\":1,\"span\":{\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":1}," ++
    "\"ty\":1,\"kind\":\"cast\",\"value\":{\"operand\":0,\"source_type\":{\"kind\":\"prim\"," ++
    "\"value\":\"u8\"},\"target\":1,\"conversion\":\"as\"}}]";
const tampered_cast_exprs_json =
    "[{\"id\":0,\"span\":{\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":1}," ++
    "\"ty\":0,\"kind\":\"literal\",\"value\":{\"kind\":\"int\",\"value\":{\"text\":\"1\"," ++
    "\"value\":\"1\",\"base\":\"dec\",\"ty_suffix\":\"u32\"}}}," ++
    "{\"id\":1,\"span\":{\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":1}," ++
    "\"ty\":1,\"kind\":\"cast\",\"value\":{\"operand\":0,\"source_type\":{\"kind\":\"prim\"," ++
    "\"value\":\"u32\"},\"target\":1,\"conversion\":\"primitive_from\"}}]";
const tampered_cast_payload =
    "{\"format_version\":6,\"crate_name\":\"fixture\",\"edition\":\"2021\"," ++
    "\"sidecar\":null,\"toolchain\":null," ++ valid_crates_json ++
    ",\"types\":[{\"kind\":\"prim\",\"value\":\"u32\"},{\"kind\":\"prim\",\"value\":\"u8\"}]," ++
    "\"instantiations\":[],\"bodies\":{\"exprs\":" ++ tampered_cast_exprs_json ++
    ",\"stmts\":[],\"pats\":[],\"types\":[{\"kind\":\"prim\",\"value\":\"u32\"}," ++
    "{\"kind\":\"prim\",\"value\":\"u64\"}],\"bodies\":[{\"owner\":0,\"body\":{\"kind\":\"none\"}}]}}";

const valid_dependency_crates_json =
    "\"crates\":[{\"name\":\"fixture\",\"edition\":2021,\"kind\":\"lib\",\"root\":0," ++
    "\"is_translated\":true,\"deps\":[" ++
    "{\"extern_name\":\"nullable\",\"local_alias\":\"nullable_alias\",\"id\":1,\"version\":null,\"path\":null,\"git\":null,\"optional\":false,\"default_features\":null,\"features\":[]}," ++
    "{\"extern_name\":\"disabled\",\"local_alias\":\"disabled_alias\",\"id\":2,\"version\":null,\"path\":null,\"git\":null,\"optional\":false,\"default_features\":false,\"features\":[\"zeta\",\"alpha\",\"middle\"]}," ++
    "{\"extern_name\":\"enabled\",\"local_alias\":\"enabled_alias\",\"id\":3,\"version\":null,\"path\":null,\"git\":null,\"optional\":true,\"default_features\":true,\"features\":[\"enabled_feature\"]}" ++
    "],\"entities\":[{\"id\":0,\"kind\":\"module\"," ++
    "\"name\":\"fixture\",\"span\":{\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":1}," ++
    "\"visibility\":{\"kind\":\"public\"},\"parent\":null,\"resolved\":null,\"renamed_to\":null," ++
    "\"attributes\":[]}],\"modules\":[{\"id\":0,\"kind\":\"root\",\"name\":\"fixture\"," ++
    "\"parent\":null,\"source_path\":null,\"is_crate\":true,\"is_extern\":false," ++
    "\"span\":{\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":1}," ++
    "\"items\":[],\"attributes\":[]}],\"uses\":[]}]";

const canonical_dependency_payload =
    "{\"format_version\":6,\"crate_name\":\"fixture\",\"edition\":\"2021\"," ++
    "\"sidecar\":null,\"toolchain\":null," ++ valid_dependency_crates_json ++
    ",\"types\":[],\"instantiations\":[],\"bodies\":{\"exprs\":[],\"stmts\":[]," ++
    "\"pats\":[],\"types\":[],\"bodies\":[{\"owner\":0,\"body\":{\"kind\":\"none\"}}]}}";

fn initDependencyIr(allocator: std.mem.Allocator) !serialize.RustIr {
    var crate_graph = try initTestGraph(allocator, "dependency_fixture", &.{});
    const deps = try allocator.alloc(graph.CrateDep, 3);

    const disabled_features = try allocator.alloc([]const u8, 3);
    disabled_features[0] = try allocator.dupe(u8, "zeta");
    disabled_features[1] = try allocator.dupe(u8, "alpha");
    disabled_features[2] = try allocator.dupe(u8, "middle");
    const enabled_features = try allocator.alloc([]const u8, 1);
    enabled_features[0] = try allocator.dupe(u8, "enabled_feature");

    deps[0] = .{
        .extern_name = try allocator.dupe(u8, "nullable"),
        .local_alias = try allocator.dupe(u8, "nullable_alias"),
        .id = 1,
        .version = null,
        .path = null,
        .git = null,
        .optional = false,
        .default_features = null,
        .features = &.{},
    };
    deps[1] = .{
        .extern_name = try allocator.dupe(u8, "disabled"),
        .local_alias = try allocator.dupe(u8, "disabled_alias"),
        .id = 2,
        .version = null,
        .path = null,
        .git = null,
        .optional = false,
        .default_features = false,
        .features = disabled_features,
    };
    deps[2] = .{
        .extern_name = try allocator.dupe(u8, "enabled"),
        .local_alias = try allocator.dupe(u8, "enabled_alias"),
        .id = 3,
        .version = null,
        .path = null,
        .git = null,
        .optional = true,
        .default_features = true,
        .features = enabled_features,
    };
    crate_graph.crates.items[0].deps = deps;

    const body_kinds = try allocator.alloc(bodies.BodyKind, 1);
    body_kinds[0] = .none;
    return .{
        .crate_name = "dependency_fixture",
        .edition = "2021",
        .graph = crate_graph,
        .bodies = .{
            .exprs = &.{},
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = body_kinds,
        },
    };
}

fn expectDependencyMetadata(deps: []const graph.CrateDep) !void {
    try std.testing.expectEqual(@as(usize, 3), deps.len);
    try std.testing.expectEqualStrings("nullable", deps[0].extern_name);
    try std.testing.expectEqual(@as(?bool, null), deps[0].default_features);
    try std.testing.expectEqual(@as(usize, 0), deps[0].features.len);

    try std.testing.expectEqualStrings("disabled", deps[1].extern_name);
    try std.testing.expectEqual(@as(?bool, false), deps[1].default_features);
    try std.testing.expectEqual(@as(usize, 3), deps[1].features.len);
    try std.testing.expectEqualStrings("zeta", deps[1].features[0]);
    try std.testing.expectEqualStrings("alpha", deps[1].features[1]);
    try std.testing.expectEqualStrings("middle", deps[1].features[2]);

    try std.testing.expectEqualStrings("enabled", deps[2].extern_name);
    try std.testing.expectEqual(@as(?bool, true), deps[2].default_features);
    try std.testing.expectEqual(@as(usize, 1), deps[2].features.len);
    try std.testing.expectEqualStrings("enabled_feature", deps[2].features[0]);
}

fn expectCanonicalMissingField(field: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        canonical_empty_payload,
        .{},
    );
    defer parsed.deinit();
    _ = parsed.value.object.swapRemove(field);
    const payload = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
    try std.testing.expectError(
        error.MissingField,
        serialize.decode(allocator, payload),
    );
}
fn makeCanonicalCastPayload(
    allocator: std.mem.Allocator,
    conversion: ?std.json.Value,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        canonical_empty_payload,
        .{},
    );
    defer parsed.deinit();
    var type_rows = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        canonical_cast_types_json,
        .{},
    );
    defer type_rows.deinit();
    var expr_rows = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        canonical_cast_exprs_json,
        .{},
    );
    defer expr_rows.deinit();

    const cast_value =
        expr_rows.value.array.items[1].object.getPtr("value") orelse return error.BadWireFormat;
    if (conversion) |tag| {
        try cast_value.object.put(allocator, "conversion", tag);
    } else {
        _ = cast_value.object.swapRemove("conversion");
    }

    const root_types = parsed.value.object.getPtr("types") orelse return error.BadWireFormat;
    root_types.* = type_rows.value;
    const body_tables = parsed.value.object.getPtr("bodies") orelse return error.BadWireFormat;
    const body_types = body_tables.object.getPtr("types") orelse return error.BadWireFormat;
    body_types.* = type_rows.value;
    const body_exprs = body_tables.object.getPtr("exprs") orelse return error.BadWireFormat;
    body_exprs.* = expr_rows.value;
    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
}

fn initTestGraph(
    allocator: std.mem.Allocator,
    crate_name: []const u8,
    item_kinds: []const spine.EntityKind,
) !graph.CrateGraph {
    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 1,
    };
    var crate_graph = graph.CrateGraph.init(allocator);
    _ = try crate_graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try allocator.dupe(u8, crate_name),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const item_ids = try allocator.alloc(spine.EntityId, item_kinds.len);
    for (item_kinds, 0..) |kind, index| {
        const id: spine.EntityId = @intCast(index + 1);
        item_ids[index] = id;
        _ = try crate_graph.symbol_table.add(.{
            .id = id,
            .kind = kind,
            .name = try std.fmt.allocPrint(allocator, "item_{d}", .{id}),
            .span = span,
            .visibility = .public,
            .parent = 0,
            .resolved = if (kind == .use_) 0 else null,
            .renamed_to = null,
            .attributes = &.{},
        });
        if (kind == .use_) {
            try crate_graph.addUse(.{
                .id = id,
                .kind = .{ .plain = 0 },
                .local_name = try std.fmt.allocPrint(allocator, "item_{d}", .{id}),
                .is_pub_export = false,
                .target = 0,
                .span = span,
            });
        }
    }

    _ = try crate_graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = try allocator.dupe(u8, crate_name),
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = item_ids,
        .attributes = &.{},
    });
    try crate_graph.addCrate(.{
        .name = try allocator.dupe(u8, crate_name),
        .edition = 2021,
        .kind = .lib,
        .root = 0,
        .deps = &.{},
        .is_translated = true,
    });
    return crate_graph;
}

fn initCoreCallIr(allocator: std.mem.Allocator) !serialize.RustIr {
    const crate_graph = try initTestGraph(allocator, "core_call_fixture", &.{.fn_});
    const expression_table = try allocator.dupe(exprs.Expr, &.{
        .{
            .id = 0,
            .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{},
                .tail = 1,
                .labelled = null,
            } },
        },
        .{
            .id = 1,
            .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
            .ty = null,
            .kind = .{ .core_call = .{
                .function = .mem_size_of,
                .generic_args = &.{.{ .prim = .u8 }},
                .args = &.{},
            } },
        },
        .{
            .id = 2,
            .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
            .ty = null,
            .kind = .{ .core_call = .{
                .function = .default_value,
                .generic_args = &.{.{ .prim = .u16 }},
                .args = &.{},
            } },
        },
        .{
            .id = 3,
            .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
            .ty = null,
            .kind = .{ .core_call = .{
                .function = .convert_from,
                .generic_args = &.{.{ .prim = .u32 }},
                .args = &.{1},
            } },
        },
        .{
            .id = 4,
            .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
            .ty = null,
            .kind = .{ .core_call = .{
                .function = .string_from_utf8,
                .generic_args = &.{},
                .args = &.{1},
            } },
        },
        .{
            .id = 5,
            .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
            .ty = null,
            .kind = .{ .core_call = .{
                .function = .string_from_utf8_lossy,
                .generic_args = &.{},
                .args = &.{1},
            } },
        },
        .{
            .id = 6,
            .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
            .ty = null,
            .kind = .{ .core_call = .{
                .function = .string_from_utf8_unchecked,
                .generic_args = &.{},
                .args = &.{1},
            } },
        },
    });
    const body_table = try allocator.alloc(bodies.BodyKind, 2);
    body_table[0] = .none;
    body_table[1] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 0,
    } };
    return .{
        .crate_name = "core_call_fixture",
        .edition = "2021",
        .graph = crate_graph,
        .types = &.{},
        .instantiations = &.{},
        .bodies = .{
            .exprs = expression_table,
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = body_table,
        },
    };
}

/// A method-call fixture carrying one turbofish (`parse::<u32>()`) and one
/// bare call (`len()`), so a round-trip proves the optional field both
/// round-trips a populated list and leaves an absent one empty.
fn initMethodCallIr(allocator: std.mem.Allocator) !serialize.RustIr {
    const crate_graph = try initTestGraph(allocator, "method_call_fixture", &.{.fn_});
    const expression_table = try allocator.dupe(exprs.Expr, &.{
        .{
            .id = 0,
            .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{},
                .tail = 1,
                .labelled = null,
            } },
        },
        .{
            .id = 1,
            .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 2,
                .receiver_mode = .value,
                .method = 1,
                .generic_args = &.{.{ .prim = .u32 }},
                .args = &.{},
            } },
        },
        .{
            .id = 2,
            .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
            .ty = null,
            .kind = .{ .unit = {} },
        },
        .{
            .id = 3,
            .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 2,
                .receiver_mode = .shared,
                .method = 1,
                .generic_args = &.{},
                .args = &.{},
            } },
        },
    });
    const body_table = try allocator.alloc(bodies.BodyKind, 2);
    body_table[0] = .none;
    body_table[1] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 0,
    } };
    return .{
        .crate_name = "method_call_fixture",
        .edition = "2021",
        .graph = crate_graph,
        .types = &.{},
        .instantiations = &.{},
        .bodies = .{
            .exprs = expression_table,
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = body_table,
        },
    };
}

test "method call turbofish round-trips and an absent key decodes as empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ir = try initMethodCallIr(allocator);

    const encoded = try serialize.encode(allocator, &ir);
    // The field is always emitted, so a populated turbofish is on the wire and
    // a call without one still carries an explicit empty list.
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"kind\":\"method_call\"") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded,
        "\"generic_args\":[{\"kind\":\"prim\",\"value\":\"u32\"}]",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"generic_args\":[]") != null);

    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();
    const turbofished = switch (decoded.bodies.exprs[1].kind) {
        .method_call => |value| value,
        else => return error.ExpectedMethodCallExpression,
    };
    try std.testing.expectEqual(@as(usize, 1), turbofished.generic_args.len);
    try std.testing.expectEqual(types.Prim.u32, turbofished.generic_args[0].prim);
    try std.testing.expectEqual(exprs.ReceiverMode.value, turbofished.receiver_mode);
    const bare = switch (decoded.bodies.exprs[3].kind) {
        .method_call => |value| value,
        else => return error.ExpectedBareMethodCallExpression,
    };
    try std.testing.expectEqual(@as(usize, 0), bare.generic_args.len);

    const reencoded = try serialize.encode(allocator, &decoded);
    try std.testing.expectEqualStrings(encoded, reencoded);

    // A `method_call` object with no `generic_args` key at all is what every
    // pre-existing v6 fixture carries. Decoding must not need the key: the
    // field is additive, so no wire version bump is required.
    var legacy = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer legacy.deinit();
    const exprs_root = legacy.value.object.getPtr("bodies").?.object.getPtr("exprs").?.array;
    var stripped = false;
    for (exprs_root.items) |*entry| {
        const row = &entry.object;
        if (!std.mem.eql(u8, row.get("kind").?.string, "method_call")) continue;
        // The expression's own fields live under `value`, beside `kind`.
        const fields = @constCast(&row.getPtr("value").?.object);
        _ = fields.orderedRemove("generic_args");
        stripped = true;
    }
    if (!stripped) return error.NoMethodCallRowInPayload;
    const legacy_json = try std.json.Stringify.valueAlloc(allocator, legacy.value, .{});
    var legacy_decoded = try serialize.decode(allocator, legacy_json);
    defer legacy_decoded.graph.deinit();
    for (legacy_decoded.bodies.exprs) |expression| {
        const call = switch (expression.kind) {
            .method_call => |value| value,
            else => continue,
        };
        try std.testing.expectEqual(@as(usize, 0), call.generic_args.len);
    }
}

fn initSemanticNodesIr(allocator: std.mem.Allocator) !serialize.RustIr {
    const crate_graph = try initTestGraph(allocator, "semantic_nodes_fixture", &.{.fn_});
    const owner: types.ExternalNominal = .{
        .path = &.{ "alloc", "borrow", "Cow" },
        .args = &.{.{ .prim = .u8 }},
    };
    const array_type = try allocator.create(types.Array);
    array_type.* = .{
        .elem = .{ .prim = .u8 },
        .len = .{ .expression = 1 },
    };
    const expression_table = try allocator.dupe(exprs.Expr, &.{
        .{
            .id = 0,
            .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{},
                .tail = 1,
                .labelled = null,
            } },
        },
        .{
            .id = 1,
            .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
            .ty = null,
            .kind = .{ .unit = {} },
        },
        .{
            .id = 2,
            .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
            .ty = null,
            .kind = .{ .core_function = .{
                .function = .mem_transmute,
                .generic_args = &.{ .{ .prim = .u8 }, .{ .prim = .u16 } },
            } },
        },
        .{
            .id = 3,
            .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
            .ty = null,
            .kind = .{ .external_variant = .{
                .owner = owner,
                .variant = "Owned",
                .tuple_fields = &.{1},
                .named_fields = &.{.{
                    .field = "value",
                    .value = 1,
                    .shorthand = false,
                }},
            } },
        },
    });
    const pattern_table = try allocator.dupe(exprs.Pattern, &.{
        .{
            .id = 0,
            .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
            .ty = null,
            .kind = .{ .external_variant = .{
                .owner = owner,
                .variant = "Borrowed",
                .fields = &.{.{
                    .field = "value",
                    .pat = null,
                    .shorthand = false,
                }},
                .rest = false,
            } },
        },
    });
    const body_table = try allocator.alloc(bodies.BodyKind, 2);
    body_table[0] = .none;
    body_table[1] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 0,
    } };
    return .{
        .crate_name = "semantic_nodes_fixture",
        .edition = "2021",
        .graph = crate_graph,
        .types = &.{},
        .instantiations = &.{},
        .bodies = .{
            .exprs = expression_table,
            .stmts = &.{},
            .pats = pattern_table,
            .types = &.{.{ .array = array_type }},
            .bodies = body_table,
        },
    };
}

test "semantic variants and array expression lengths round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ir = try initSemanticNodesIr(allocator);

    const encoded = try serialize.encode(allocator, &ir);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"kind\":\"core_function\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"function\":\"mem_transmute\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"kind\":\"external_variant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"kind\":\"expression\",\"value\":1") != null);

    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();
    const function = switch (decoded.bodies.exprs[2].kind) {
        .core_function => |value| value,
        else => return error.ExpectedCoreFunctionExpression,
    };
    try std.testing.expectEqual(exprs.CoreFunction.mem_transmute, function.function);
    try std.testing.expectEqual(@as(usize, 2), function.generic_args.len);
    const variant = switch (decoded.bodies.exprs[3].kind) {
        .external_variant => |value| value,
        else => return error.ExpectedExternalVariantExpression,
    };
    try std.testing.expectEqualStrings("alloc", variant.owner.path[0]);
    try std.testing.expectEqualStrings("Owned", variant.variant);
    const pattern = switch (decoded.bodies.pats[0].kind) {
        .external_variant => |value| value,
        else => return error.ExpectedExternalVariantPattern,
    };
    try std.testing.expectEqualStrings("Borrowed", pattern.variant);
    switch (decoded.bodies.types[0]) {
        .array => |array| switch (array.len) {
            .expression => |expression| try std.testing.expectEqual(@as(u32, 1), expression),
            else => return error.ExpectedExpressionArrayLength,
        },
        else => return error.ExpectedArrayType,
    }
}

test "core calls round-trip with canonical wire tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ir = try initCoreCallIr(allocator);

    const encoded = try serialize.encode(allocator, &ir);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"kind\":\"core_call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"function\":\"mem_size_of\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"function\":\"default_value\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"function\":\"convert_from\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"function\":\"string_from_utf8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"function\":\"string_from_utf8_lossy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"function\":\"string_from_utf8_unchecked\"") != null);

    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();
    const call = switch (decoded.bodies.exprs[1].kind) {
        .core_call => |value| value,
        else => return error.ExpectedCoreCallExpression,
    };
    try std.testing.expectEqual(exprs.CoreFunction.mem_size_of, call.function);
    try std.testing.expectEqual(@as(usize, 1), call.generic_args.len);
    try std.testing.expectEqual(@as(usize, 0), call.args.len);
    const default_call = switch (decoded.bodies.exprs[2].kind) {
        .core_call => |value| value,
        else => return error.ExpectedDefaultValueCall,
    };
    try std.testing.expectEqual(exprs.CoreFunction.default_value, default_call.function);
    try std.testing.expectEqual(@as(usize, 1), default_call.generic_args.len);
    try std.testing.expectEqual(@as(usize, 0), default_call.args.len);
    const convert_call = switch (decoded.bodies.exprs[3].kind) {
        .core_call => |value| value,
        else => return error.ExpectedConvertFromCall,
    };
    try std.testing.expectEqual(exprs.CoreFunction.convert_from, convert_call.function);
    try std.testing.expectEqual(@as(usize, 1), convert_call.generic_args.len);
    try std.testing.expectEqual(@as(usize, 1), convert_call.args.len);
    const string_functions = [_]exprs.CoreFunction{
        .string_from_utf8,
        .string_from_utf8_lossy,
        .string_from_utf8_unchecked,
    };
    for (string_functions, 0..) |expected, offset| {
        const index = offset + 4;
        const string_call = switch (decoded.bodies.exprs[index].kind) {
            .core_call => |value| value,
            else => return error.ExpectedStringCoreCall,
        };
        try std.testing.expectEqual(expected, string_call.function);
        try std.testing.expectEqual(@as(usize, 0), string_call.generic_args.len);
        try std.testing.expectEqual(@as(usize, 1), string_call.args.len);
    }

    const reencoded = try serialize.encode(allocator, &decoded);
    try std.testing.expectEqualStrings(encoded, reencoded);
}
fn expectCanonicalDependencyMissingField(field: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        canonical_dependency_payload,
        .{},
    );
    defer parsed.deinit();
    const crates = parsed.value.object.getPtr("crates") orelse return error.BadWireFormat;
    const deps = crates.array.items[0].object.getPtr("deps") orelse return error.BadWireFormat;
    const dep = &deps.array.items[0].object;
    _ = dep.swapRemove(field);
    const payload = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
    try std.testing.expectError(
        error.MissingField,
        serialize.decode(allocator, payload),
    );
}

fn expectCanonicalDependencyWrongType(field: []const u8, value: std.json.Value) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        canonical_dependency_payload,
        .{},
    );
    defer parsed.deinit();
    const crates = parsed.value.object.getPtr("crates") orelse return error.BadWireFormat;
    const deps = crates.array.items[0].object.getPtr("deps") orelse return error.BadWireFormat;
    const dep = &deps.array.items[0].object;
    try dep.put(allocator, field, value);
    const payload = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
    try std.testing.expectError(
        error.BadWireFormat,
        serialize.decode(allocator, payload),
    );
}

fn expectCanonicalDependencyFeatureElementWrongType() !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        canonical_dependency_payload,
        .{},
    );
    defer parsed.deinit();
    const crates = parsed.value.object.getPtr("crates") orelse return error.BadWireFormat;
    const deps = crates.array.items[0].object.getPtr("deps") orelse return error.BadWireFormat;
    const dep = &deps.array.items[1].object;
    const features = dep.getPtr("features") orelse return error.BadWireFormat;
    features.array.items[0] = .{ .bool = true };
    const payload = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
    try std.testing.expectError(
        error.BadWireFormat,
        serialize.decode(allocator, payload),
    );
}

test "serialize: allocation exhaustion is not invalid JSON" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, serialize.decode(failing.allocator(), canonical_empty_payload));
}

test "serialize: two crate roots roundtrip with non-zero allocator memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 1,
    };

    var crate_graph = graph.CrateGraph.init(allocator);
    defer crate_graph.deinit();
    const crate_names = [_][]const u8{ "alpha", "beta" };
    for (crate_names, 0..) |crate_name, index| {
        const root_id: spine.EntityId = @intCast(index);
        _ = try crate_graph.symbol_table.add(.{
            .id = root_id,
            .kind = .module,
            .name = try allocator.dupe(u8, crate_name),
            .span = span,
            .visibility = .public,
            .parent = null,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
        });
        _ = try crate_graph.addModule(.{
            .id = root_id,
            .kind = .root,
            .name = try allocator.dupe(u8, crate_name),
            .parent = null,
            .source_path = null,
            .is_crate = true,
            .is_extern = false,
            .span = span,
            .items = &.{},
            .attributes = &.{},
        });
        try crate_graph.addCrate(.{
            .name = try allocator.dupe(u8, crate_name),
            .edition = 2021,
            .kind = .lib,
            .root = root_id,
            .deps = &.{},
            .is_translated = true,
        });
    }
    const child_id = try crate_graph.symbol_table.add(.{
        .id = 2,
        .kind = .module,
        .name = try allocator.dupe(u8, "child"),
        .span = span,
        .visibility = .public,
        .parent = 0,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    crate_graph.modules.items[0].items = try allocator.dupe(spine.EntityId, &.{child_id});
    const child_module_id = try crate_graph.addModule(.{
        .id = child_id,
        .kind = .@"inline",
        .name = try allocator.dupe(u8, "child"),
        .parent = 0,
        .source_path = null,
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });

    const body_kinds = [_]bodies.BodyKind{ .none, .none, .none };
    const ir: serialize.RustIr = .{
        .crate_name = "alpha",
        .graph = crate_graph,
        .bodies = .{
            .exprs = &.{},
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = &body_kinds,
        },
    };

    var encode_memory: [64 * 1024]u8 = undefined;
    @memset(&encode_memory, 1);
    var encode_fba = std.heap.FixedBufferAllocator.init(&encode_memory);
    const encoded = try serialize.encode(encode_fba.allocator(), &ir);

    var decode_memory: [128 * 1024]u8 = undefined;
    @memset(&decode_memory, 1);
    var decode_fba = std.heap.FixedBufferAllocator.init(&decode_memory);
    var decoded = try serialize.decode(decode_fba.allocator(), encoded);
    defer decoded.graph.deinit();

    try std.testing.expectEqual(@as(usize, 2), decoded.graph.crates.items.len);
    try std.testing.expectEqual(@as(usize, 3), decoded.graph.symbol_table.entities.items.len);
    try std.testing.expectEqual(@as(usize, 0), decoded.graph.crates.items[0].deps.len);
    try std.testing.expectEqual(@as(usize, 0), decoded.graph.crates.items[1].deps.len);
    try std.testing.expectEqual(@as(spine.EntityId, 0), decoded.graph.crates.items[0].root);
    try std.testing.expectEqual(@as(spine.EntityId, 1), decoded.graph.crates.items[1].root);
    try std.testing.expectEqualStrings("alpha", decoded.graph.symbol_table.entities.items[0].name);
    try std.testing.expectEqualStrings("beta", decoded.graph.symbol_table.entities.items[1].name);
    try std.testing.expectEqualStrings("child", decoded.graph.symbol_table.get(child_id).?.name);
    try std.testing.expectEqual(@as(?spine.EntityId, 0), decoded.graph.modules.items[child_module_id].parent);
    try std.testing.expectEqualSlices(spine.EntityId, &.{child_id}, decoded.graph.modules.items[0].items);
}

test "serialize: instantiation cleanup preserves borrowed nested arguments" {
    const allocator = std.testing.allocator;
    const nested = try allocator.create(types.Ref);
    nested.* = .{
        .mut = false,
        .pointee = .{ .prim = .u8 },
    };

    const params = try allocator.alloc(types.Type, 1);
    params[0] = .{ .reference = nested };
    const params_shared = try allocator.alloc(types.Type, 1);
    params_shared[0] = .{ .reference = nested };
    const suffix = try allocator.dupe(u8, "_u8");
    const suffix_shared = try allocator.dupe(u8, "_u8_again");
    const records = try allocator.alloc(types.Instantiation, 2);
    records[0] = .{
        .generic_id = 0,
        .args = .{ .params = params },
        .zig_suffix = suffix,
    };
    records[1] = .{
        .generic_id = 0,
        .args = .{ .params = params_shared },
        .zig_suffix = suffix_shared,
    };

    var ir: serialize.RustIr = .{
        .crate_name = "borrowed",
        .graph = undefined,
        .bodies = undefined,
        .instantiations = records,
    };
    ir.deinitInstantiations(allocator);
    allocator.destroy(nested);
}

test "serialize: canonical dependency metadata encodes all states and order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ir = try initDependencyIr(allocator);
    defer ir.graph.deinit();

    const encoded = try serialize.encode(allocator, &ir);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(
        @as(i128, 6),
        parsed.value.object.get("format_version").?.integer,
    );
    const crates = parsed.value.object.get("crates").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), crates.len);
    const deps = crates[0].object.get("deps").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), deps.len);

    try std.testing.expectEqual(
        std.json.Value{ .null = {} },
        deps[0].object.get("default_features").?,
    );
    try std.testing.expect(!deps[1].object.get("default_features").?.bool);
    try std.testing.expect(deps[2].object.get("default_features").?.bool);
    try std.testing.expectEqual(@as(usize, 0), deps[0].object.get("features").?.array.items.len);

    const disabled_features = deps[1].object.get("features").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), disabled_features.len);
    try std.testing.expectEqualStrings("zeta", disabled_features[0].string);
    try std.testing.expectEqualStrings("alpha", disabled_features[1].string);
    try std.testing.expectEqualStrings("middle", disabled_features[2].string);

    const enabled_features = deps[2].object.get("features").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), enabled_features.len);
    try std.testing.expectEqualStrings("enabled_feature", enabled_features[0].string);
}

test "serialize: canonical dependency metadata decodes owned and roundtrips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const payload = try allocator.dupe(u8, canonical_dependency_payload);
    var decoded = try serialize.decode(allocator, payload);
    defer decoded.graph.deinit();

    @memset(payload, 0xa5);
    try expectDependencyMetadata(decoded.graph.crates.items[0].deps);

    const encoded = try serialize.encode(allocator, &decoded);
    var roundtripped = try serialize.decode(allocator, encoded);
    defer roundtripped.graph.deinit();
    try expectDependencyMetadata(roundtripped.graph.crates.items[0].deps);
}

test "serialize: canonical dependency metadata requires exact fields and types" {
    try expectCanonicalDependencyMissingField("default_features");
    try expectCanonicalDependencyMissingField("features");
    try expectCanonicalDependencyWrongType("default_features", .{ .string = "yes" });
    try expectCanonicalDependencyWrongType("default_features", .{ .integer = 1 });
    try expectCanonicalDependencyWrongType("features", .{ .string = "not-an-array" });
    try expectCanonicalDependencyFeatureElementWrongType();
}

test "serialize: RustIr roundtrip with entities, types, and bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = graph.CrateGraph.init(alloc);
    g.sidecar = "sidecar";
    g.toolchain = "toolchain";
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 10, .end_col = 1 };

    // Add root module entity (0)
    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, "test_crate"),
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
        .name = "test_crate",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{ 1, 2 },
        .attributes = &.{},
    });

    _ = try g.addCrate(.{
        .name = "test_crate",
        .edition = 2021,
        .kind = .lib,
        .root = 0,
        .deps = &.{},
        .is_translated = true,
    });
    _ = try g.symbol_table.add(.{
        .id = 1,
        .kind = .struct_,
        .name = try alloc.dupe(u8, "Point"),
        .span = span,
        .visibility = .public,
        .parent = 0,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Add a function entity new_point (2)
    _ = try g.symbol_table.add(.{
        .id = 2,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "new_point"),
        .span = span,
        .visibility = .public,
        .parent = 0,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const ir_types = try alloc.alloc(types.Type, 4);
    ir_types[0] = .{ .prim = .i32 };
    ir_types[1] = .{ .path = .{ .segments = &.{.{ .name = "Point", .id = 1 }} } };
    ir_types[2] = .{ .prim = .u64 };
    ir_types[3] = .{ .prim = .u8 };

    const expr_arr = try alloc.alloc(exprs.Expr, 5);
    expr_arr[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{ .text = "42", .value = 42, .base = .dec, .ty_suffix = null } } },
    };
    expr_arr[1] = .{
        .id = 1,
        .span = span,
        .ty = 2,
        .kind = .{ .cast = .{
            .kind = .as_,
            .operand = 0,
            .source_type = .{ .prim = .i32 },
            .target = 2,
        } },
    };
    expr_arr[2] = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{ .statements = &.{}, .tail = 1, .labelled = null } },
    };
    expr_arr[3] = .{
        .id = 3,
        .span = span,
        .ty = 3,
        .kind = .{ .literal = .{ .int = .{
            .text = "1",
            .value = 1,
            .base = .dec,
            .ty_suffix = "u8",
        } } },
    };
    expr_arr[4] = .{
        .id = 4,
        .span = span,
        .ty = 2,
        .kind = .{ .cast = .{
            .kind = .primitive_from,
            .operand = 3,
            .source_type = .{ .prim = .u8 },
            .target = 2,
        } },
    };

    const bodies_arr = try alloc.alloc(bodies.BodyKind, 3);
    bodies_arr[0] = .none;
    bodies_arr[1] = .{ .struct_ = .{
        .generic_params = &.{"T"},
        .layout = .named,
        .fields = &.{
            .{ .name = "x", .ty = .{ .prim = .i32 }, .visibility = .public, .span = span },
            .{ .name = "y", .ty = .{ .prim = .i32 }, .visibility = .public, .span = span },
        },
    } };
    bodies_arr[2] = .{ .fn_ = .{
        .params = &.{},
        .ret = ir_types[1],
        .body = 2,
    } };

    const instantiation_params = [_]types.Type{.{ .prim = .i32 }};
    const instantiations = [_]types.Instantiation{.{
        .generic_id = 1,
        .args = .{ .params = &instantiation_params },
        .zig_suffix = "_i32",
    }};

    const sample_ir: serialize.RustIr = .{
        .crate_name = "test_crate",
        .edition = "2021",
        .graph = g,
        .types = ir_types,
        .instantiations = &instantiations,
        .bodies = .{
            .exprs = expr_arr,
            .stmts = &.{},
            .pats = &.{},
            .types = ir_types,
            .bodies = bodies_arr,
        },
    };
    const encoded = try serialize.encode(alloc, &sample_ir);
    try std.testing.expect(encoded.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"owner\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"instantiations\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"conversion\":\"as\"") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, encoded, "\"conversion\":\"primitive_from\"") != null,
    );

    var decoded = try serialize.decode(alloc, encoded);
    defer decoded.graph.deinit();

    try std.testing.expectEqualStrings("test_crate", decoded.crate_name);
    try std.testing.expectEqualStrings("2021", decoded.edition);
    try std.testing.expectEqual(@as(usize, 3), decoded.graph.symbol_table.entities.items.len);
    try std.testing.expectEqualStrings("Point", decoded.graph.symbol_table.entities.items[1].name);
    try std.testing.expectEqualStrings("new_point", decoded.graph.symbol_table.entities.items[2].name);
    try std.testing.expectEqualStrings("sidecar", decoded.graph.sidecar.?);
    try std.testing.expectEqualStrings("toolchain", decoded.graph.toolchain.?);
    try std.testing.expectEqual(@as(usize, 1), decoded.instantiations.len);
    try std.testing.expectEqual(@as(spine.EntityId, 1), decoded.instantiations[0].generic_id);
    try std.testing.expectEqualStrings("_i32", decoded.instantiations[0].zig_suffix);
    try std.testing.expectEqual(@as(usize, 5), decoded.bodies.exprs.len);
    const decoded_cast = switch (decoded.bodies.exprs[1].kind) {
        .cast => |cast| cast,
        else => return error.ExpectedCastExpression,
    };
    try std.testing.expectEqual(exprs.ConversionKind.as_, decoded_cast.kind);
    try std.testing.expectEqual(@as(exprs.NodeId, 0), decoded_cast.operand);
    try std.testing.expectEqual(types.Type{ .prim = .i32 }, decoded_cast.source_type);
    try std.testing.expectEqual(@as(exprs.TypeId, 2), decoded_cast.target);
    const decoded_primitive_from = switch (decoded.bodies.exprs[4].kind) {
        .cast => |cast| cast,
        else => return error.ExpectedCastExpression,
    };
    try std.testing.expectEqual(
        exprs.ConversionKind.primitive_from,
        decoded_primitive_from.kind,
    );
    try std.testing.expectEqual(@as(exprs.NodeId, 3), decoded_primitive_from.operand);
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, decoded_primitive_from.source_type);
    try std.testing.expectEqual(@as(exprs.TypeId, 2), decoded_primitive_from.target);
}

test "serialize: canonical cast conversion tags decode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixtures = [_]struct {
        wire: []const u8,
        expected: exprs.ConversionKind,
    }{
        .{ .wire = "as", .expected = .as_ },
        .{ .wire = "primitive_from", .expected = .primitive_from },
    };

    for (fixtures) |fixture| {
        const payload = try makeCanonicalCastPayload(
            allocator,
            .{ .string = fixture.wire },
        );
        var decoded = try serialize.decode(allocator, payload);
        defer decoded.graph.deinit();
        const cast = switch (decoded.bodies.exprs[1].kind) {
            .cast => |value| value,
            else => return error.ExpectedCastExpression,
        };
        try std.testing.expectEqual(fixture.expected, cast.kind);
    }
}

test "serialize: cast target root mismatch is rejected before lowering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var decoded = try serialize.decode(allocator, tampered_cast_payload);
    defer decoded.graph.deinit();
    try std.testing.expectError(
        error.UnsupportedExpression,
        root.validateForTranslation(&decoded),
    );
}
test "serialize: canonical cast conversion is required" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const payload = try makeCanonicalCastPayload(allocator, null);
    try std.testing.expectError(
        error.MissingField,
        serialize.decode(allocator, payload),
    );
}

test "serialize: canonical cast conversion rejects malformed tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const unknown = try makeCanonicalCastPayload(
        allocator,
        .{ .string = "unchecked" },
    );
    try std.testing.expectError(
        error.BadWireFormat,
        serialize.decode(allocator, unknown),
    );

    const wrong_type = try makeCanonicalCastPayload(
        allocator,
        .{ .integer = 1 },
    );
    try std.testing.expectError(
        error.BadWireFormat,
        serialize.decode(allocator, wrong_type),
    );
}

test "serialize: range bounds and panic preserve wire payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const span: spine.Span = .{
        .start_line = 3,
        .start_col = 5,
        .end_line = 3,
        .end_col = 18,
    };
    const table_types = [_]types.Type{
        .{ .prim = .usize },
        .{ .prim = .never },
    };
    const expressions = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = 0,
            .kind = .{ .literal = .{ .int = .{
                .text = "4",
                .value = 4,
                .base = .dec,
                .ty_suffix = "usize",
            } } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = 0,
            .kind = .{ .literal = .{ .int = .{
                .text = "8",
                .value = 8,
                .base = .dec,
                .ty_suffix = "usize",
            } } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .range = .{
                .start = 0,
                .end = null,
                .inclusive = false,
            } },
        },
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{ .range = .{
                .start = 0,
                .end = 1,
                .inclusive = true,
            } },
        },
        .{
            .id = 4,
            .span = span,
            .ty = 1,
            .kind = .{ .panic_ = .{ .message = "unreachable branch" } },
        },
    };
    const sample_ir: serialize.RustIr = .{
        .crate_name = "range_panic",
        .edition = "2021",
        .graph = try initTestGraph(allocator, "range_panic", &.{}),
        .types = &table_types,
        .bodies = .{
            .exprs = &expressions,
            .stmts = &.{},
            .pats = &.{},
            .types = &table_types,
            .bodies = &.{.none},
        },
    };

    const encoded = try serialize.encode(allocator, &sample_ir);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded,
        "\"kind\":\"range\",\"value\":{\"start\":0,\"end\":null,\"inclusive\":false}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded,
        "\"kind\":\"range\",\"value\":{\"start\":0,\"end\":1,\"inclusive\":true}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded,
        "\"kind\":\"panic_\",\"value\":{\"message\":\"unreachable branch\"}",
    ) != null);

    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();
    const open_range = switch (decoded.bodies.exprs[2].kind) {
        .range => |range| range,
        else => return error.ExpectedRangeExpression,
    };
    try std.testing.expectEqual(@as(?exprs.NodeId, null), open_range.end);
    const bounded_range = switch (decoded.bodies.exprs[3].kind) {
        .range => |range| range,
        else => return error.ExpectedRangeExpression,
    };
    try std.testing.expectEqual(@as(?exprs.NodeId, 1), bounded_range.end);
    try std.testing.expect(bounded_range.inclusive);
    const panic_expr = switch (decoded.bodies.exprs[4].kind) {
        .panic_ => |panic_value| panic_value,
        else => return error.ExpectedPanicExpression,
    };
    try std.testing.expectEqualStrings("unreachable branch", panic_expr.message);
}

test "serialize: explicit Vec literal preserves wire payload and roundtrips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const span: spine.Span = .{
        .start_line = 3,
        .start_col = 5,
        .end_line = 3,
        .end_col = 20,
    };
    const element_ids = [_]exprs.NodeId{ 2, 0, 1 };
    const expr_arr = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .unit = {} } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .unit = {} } },
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{ .vec_lit = .{
                .elements = &element_ids,
                .repeat = null,
            } },
        },
    };
    const body_kinds = [_]bodies.BodyKind{.none};
    const ir_types = [_]types.Type{};
    const sample_ir: serialize.RustIr = .{
        .crate_name = "vec_list",
        .edition = "2021",
        .graph = try initTestGraph(alloc, "vec_list", &.{}),
        .types = &ir_types,
        .bodies = .{
            .exprs = &expr_arr,
            .stmts = &.{},
            .pats = &.{},
            .types = &ir_types,
            .bodies = &body_kinds,
        },
    };

    const encoded = try serialize.encode(alloc, &sample_ir);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded,
        "\"kind\":\"vec_lit\",\"value\":{\"elements\":[2,0,1],\"repeat\":null}",
    ) != null);

    var decoded = try serialize.decode(alloc, encoded);
    defer decoded.graph.deinit();
    const decoded_vec = switch (decoded.bodies.exprs[3].kind) {
        .vec_lit => |vec| vec,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualSlices(exprs.NodeId, &element_ids, decoded_vec.elements);
    try std.testing.expectEqual(@as(?usize, null), decoded_vec.repeat);
}

test "serialize: repeat Vec literal preserves wire payload and roundtrips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const span: spine.Span = .{
        .start_line = 7,
        .start_col = 9,
        .end_line = 7,
        .end_col = 18,
    };
    const element_ids = [_]exprs.NodeId{0};
    const expr_arr = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .unit = {} } },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .vec_lit = .{
                .elements = &element_ids,
                .repeat = 13,
            } },
        },
    };
    const body_kinds = [_]bodies.BodyKind{.none};
    const ir_types = [_]types.Type{};
    const sample_ir: serialize.RustIr = .{
        .crate_name = "vec_repeat",
        .edition = "2021",
        .graph = try initTestGraph(alloc, "vec_repeat", &.{}),
        .types = &ir_types,
        .bodies = .{
            .exprs = &expr_arr,
            .stmts = &.{},
            .pats = &.{},
            .types = &ir_types,
            .bodies = &body_kinds,
        },
    };

    const encoded = try serialize.encode(alloc, &sample_ir);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded,
        "\"kind\":\"vec_lit\",\"value\":{\"elements\":[0],\"repeat\":13}",
    ) != null);

    var decoded = try serialize.decode(alloc, encoded);
    defer decoded.graph.deinit();
    const decoded_vec = switch (decoded.bodies.exprs[1].kind) {
        .vec_lit => |vec| vec,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualSlices(exprs.NodeId, &element_ids, decoded_vec.elements);
    try std.testing.expectEqual(@as(?usize, 13), decoded_vec.repeat);
}

test "serialize: explicit unsupported diagnostics preserve tagged metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expr_span: spine.Span = .{
        .start_line = 7,
        .start_col = 3,
        .end_line = 7,
        .end_col = 18,
    };
    const pattern_span: spine.Span = .{
        .start_line = 11,
        .start_col = 9,
        .end_line = 11,
        .end_col = 28,
    };
    const type_span: spine.Span = .{
        .start_line = 13,
        .start_col = 4,
        .end_line = 13,
        .end_col = 17,
    };
    const expressions = [_]exprs.Expr{.{
        .id = 0,
        .span = expr_span,
        .ty = null,
        .kind = .{ .unsupported = .{
            .reason = "match guards",
            .suggested_version = .v2,
        } },
    }};
    const patterns = [_]exprs.Pattern{.{
        .id = 0,
        .span = pattern_span,
        .ty = null,
        .kind = .{ .unsupported = .{
            .reason = "slice pattern",
            .suggested_version = .v3,
        } },
    }};
    const diagnostic_types = [_]types.Type{.{
        .unsupported = .{
            .reason = .dyn_trait,
            .message = "dynamic trait object",
            .span = type_span,
        },
    }};
    const sample_ir: serialize.RustIr = .{
        .crate_name = "unsupported_diagnostics",
        .edition = "2021",
        .graph = try initTestGraph(allocator, "unsupported_diagnostics", &.{}),
        .types = &diagnostic_types,
        .bodies = .{
            .exprs = &expressions,
            .stmts = &.{},
            .pats = &patterns,
            .types = &diagnostic_types,
            .bodies = &.{.none},
        },
    };

    const encoded = try serialize.encode(allocator, &sample_ir);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded,
        "\"kind\":\"unsupported\",\"value\":{\"reason\":\"match guards\",\"suggested_version\":\"v2\"}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded,
        "\"kind\":\"unsupported\",\"value\":{\"reason\":\"slice pattern\",\"suggested_version\":\"v3\"}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded,
        "\"kind\":\"unsupported\",\"value\":{\"reason\":\"dyn_trait\",\"message\":\"dynamic trait object\"",
    ) != null);
    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();

    const decoded_expr = switch (decoded.bodies.exprs[0].kind) {
        .unsupported => |diagnostic| diagnostic,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("match guards", decoded_expr.reason);
    try std.testing.expectEqual(.v2, decoded_expr.suggested_version);

    const decoded_pattern = switch (decoded.bodies.pats[0].kind) {
        .unsupported => |diagnostic| diagnostic,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("slice pattern", decoded_pattern.reason);
    try std.testing.expectEqual(.v3, decoded_pattern.suggested_version);

    const decoded_type = switch (decoded.bodies.types[0]) {
        .unsupported => |diagnostic| diagnostic,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(spine.UnsupportedReason.dyn_trait, decoded_type.reason);
    try std.testing.expectEqualStrings("dynamic trait object", decoded_type.message);
    try std.testing.expectEqual(type_span, decoded_type.span);
}

test "serialize: decoder frees owned data on malformed literal" {
    const malformed =
        "{\"format_version\":6,\"crate_name\":\"malformed\",\"edition\":\"2021\"," ++
        "\"sidecar\":null,\"toolchain\":null," ++ valid_crates_json ++
        ",\"types\":[],\"instantiations\":[],\"bodies\":{\"exprs\":[{\"id\":0," ++
        "\"span\":{\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":4}," ++
        "\"ty\":null,\"kind\":\"literal\",\"value\":{\"kind\":\"float\"," ++
        "\"value\":{\"text\":\"1.0\",\"value\":\"invalid\"}}}],\"stmts\":[]," ++
        "\"pats\":[],\"types\":[],\"bodies\":[]}}";

    try std.testing.expectError(
        error.BadWireFormat,
        serialize.decode(std.testing.allocator, malformed),
    );
}

test "serialize: nonempty uses preserve their wire payload and roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const span: spine.Span = .{
        .start_line = 2,
        .start_col = 1,
        .end_line = 2,
        .end_col = 17,
    };
    var crate_graph = graph.CrateGraph.init(allocator);
    _ = try crate_graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try allocator.dupe(u8, "uses"),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try crate_graph.symbol_table.add(.{
        .id = 1,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "original"),
        .span = span,
        .visibility = .public,
        .parent = 0,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try crate_graph.symbol_table.add(.{
        .id = 2,
        .kind = .use_,
        .name = try allocator.dupe(u8, "original as Renamed"),
        .span = span,
        .visibility = .public,
        .parent = 0,
        .resolved = 1,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try crate_graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = try allocator.dupe(u8, "uses"),
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{ 1, 2 },
        .attributes = &.{},
    });
    try crate_graph.addUse(.{
        .id = 2,
        .kind = .{ .alias = 1 },
        .local_name = try allocator.dupe(u8, "Renamed"),
        .is_pub_export = true,
        .target = 1,
        .span = span,
    });
    try crate_graph.addCrate(.{
        .name = try allocator.dupe(u8, "uses"),
        .edition = 2021,
        .kind = .lib,
        .root = 0,
        .deps = &.{},
        .is_translated = true,
    });

    const body_kinds = [_]bodies.BodyKind{ .none, .none, .none };
    const sample_ir: serialize.RustIr = .{
        .crate_name = "uses",
        .graph = crate_graph,
        .bodies = .{
            .exprs = &.{},
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = &body_kinds,
        },
    };
    const encoded = try serialize.encode(allocator, &sample_ir);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded,
        "\"uses\":[{\"id\":2,\"kind\":\"alias\",\"local_name\":\"Renamed\"," ++ "\"is_pub_export\":true,\"target\":1",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"kind\":\"use_\"") != null);

    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), decoded.graph.uses.items.len);
    try std.testing.expectEqual(
        spine.EntityKind.use_,
        decoded.graph.symbol_table.entities.items[2].kind,
    );
    const decoded_use = decoded.graph.uses.items[0];
    try std.testing.expectEqual(@as(spine.EntityId, 2), decoded_use.id);
    try std.testing.expectEqualStrings("Renamed", decoded_use.local_name);
    try std.testing.expect(decoded_use.is_pub_export);
    try std.testing.expectEqual(@as(spine.EntityId, 1), decoded_use.target);
    try std.testing.expectEqual(@as(spine.EntityId, 1), decoded_use.kind.alias);
}

test "serialize: external uses preserve path and unresolved sentinels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const span: spine.Span = .{
        .start_line = 3,
        .start_col = 1,
        .end_line = 3,
        .end_col = 24,
    };

    var crate_graph = graph.CrateGraph.init(allocator);
    _ = try crate_graph.symbol_table.add(.{
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
    _ = try crate_graph.symbol_table.add(.{
        .id = 0,
        .kind = .use_,
        .name = try allocator.dupe(u8, "core::hash::Hasher"),
        .span = span,
        .visibility = .private,
        .parent = 0,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try crate_graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{1},
        .attributes = &.{},
    });
    const path = try allocator.alloc([]const u8, 3);
    path[0] = try allocator.dupe(u8, "core");
    path[1] = try allocator.dupe(u8, "hash");
    path[2] = try allocator.dupe(u8, "Hasher");
    try crate_graph.addUse(.{
        .id = 1,
        .kind = .{ .external = .{ .path = path } },
        .local_name = try allocator.dupe(u8, "Hasher"),
        .is_pub_export = false,
        .target = 0,
        .span = span,
    });
    try crate_graph.addCrate(.{
        .name = try allocator.dupe(u8, "uses"),
        .edition = 2021,
        .kind = .lib,
        .root = 0,
        .deps = &.{},
        .is_translated = true,
    });

    const body_kinds = [_]bodies.BodyKind{ .none, .none };
    const sample_ir: serialize.RustIr = .{
        .crate_name = "uses",
        .graph = crate_graph,
        .bodies = .{
            .exprs = &.{},
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = &body_kinds,
        },
    };
    const encoded = try serialize.encode(allocator, &sample_ir);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded,
        "\"kind\":\"external\",\"path\":[\"core\",\"hash\",\"Hasher\"]",
    ) != null);

    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), decoded.graph.uses.items.len);
    const decoded_use = decoded.graph.uses.items[0];
    try std.testing.expectEqual(@as(spine.EntityId, 0), decoded_use.target);
    try std.testing.expectEqual(null, decoded.graph.symbol_table.entities.items[1].resolved);
    const external = switch (decoded_use.kind) {
        .external => |value| value,
        else => return error.ExpectedExternalKind,
    };
    try std.testing.expectEqualSlices(u8, "core", external.path[0]);
    try std.testing.expectEqualSlices(u8, "hash", external.path[1]);
    try std.testing.expectEqualSlices(u8, "Hasher", external.path[2]);
}

test "serialize: every entity kind tag roundtrips exactly" {
    const entity_kinds = [_]spine.EntityKind{
        .module,
        .crate_,
        .struct_,
        .enum_,
        .union_,
        .fn_,
        .method_ref,
        .const_,
        .static_,
        .trait_,
        .impl_,
        .type_alias,
        .use_,
        .extern_crate,
        .macro_,
        .field,
        .variant,
    };
    const entity_tags = [_][]const u8{
        "module",
        "crate_",
        "struct_",
        "enum_",
        "union_",
        "fn_",
        "method_ref",
        "const_",
        "static_",
        "trait_",
        "impl_",
        "type_alias",
        "use_",
        "extern_crate",
        "macro_",
        "field",
        "variant",
    };
    try std.testing.expectEqual(entity_kinds.len, entity_tags.len);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 1,
    };

    var crate_graph = graph.CrateGraph.init(allocator);
    for (entity_kinds, 0..) |kind, index| {
        const id: spine.EntityId = @intCast(index);
        _ = try crate_graph.symbol_table.add(.{
            .id = id,
            .kind = kind,
            .name = try allocator.dupe(u8, "entity"),
            .span = span,
            .visibility = .public,
            .parent = if (index == 0) null else if (kind == .method_ref)
                @intCast(index - 1)
            else
                0,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
        });
        if (kind == .use_) {
            try crate_graph.addUse(.{
                .id = id,
                .kind = .{ .plain = 0 },
                .local_name = try allocator.dupe(u8, "entity"),
                .is_pub_export = false,
                .target = 0,
                .span = span,
            });
        }
    }

    const entity_items = try allocator.alloc(spine.EntityId, entity_kinds.len - 2);
    var module_item_index: usize = 0;
    for (entity_kinds, 0..) |kind, index| {
        if (index == 0 or kind == .method_ref) continue;
        entity_items[module_item_index] = @intCast(index);
        module_item_index += 1;
    }
    _ = try crate_graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = try allocator.dupe(u8, "entity"),
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = entity_items,
        .attributes = &.{},
    });
    try crate_graph.addCrate(.{
        .name = try allocator.dupe(u8, "entity_kinds"),
        .edition = 2021,
        .kind = .lib,
        .root = 0,
        .deps = &.{},
        .is_translated = true,
    });

    const body_kinds = try allocator.alloc(bodies.BodyKind, entity_kinds.len);
    for (body_kinds, entity_kinds) |*body, kind| {
        body.* = switch (kind) {
            .const_, .static_ => .{ .const_ = .{
                .ty = .{ .prim = .unit },
                .init = 0,
            } },
            else => .none,
        };
    }
    const sample_ir: serialize.RustIr = .{
        .crate_name = "entity_kinds",
        .edition = "2021",
        .graph = crate_graph,
        .bodies = .{
            .exprs = &.{.{
                .id = 0,
                .span = span,
                .ty = null,
                .kind = .unit,
            }},
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = body_kinds,
        },
    };
    const encoded = try serialize.encode(allocator, &sample_ir);
    for (entity_tags) |tag| {
        const needle = try std.fmt.allocPrint(allocator, "\"kind\":\"{s}\"", .{tag});
        try std.testing.expect(std.mem.indexOf(u8, encoded, needle) != null);
    }

    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();
    try std.testing.expectEqual(entity_kinds.len, decoded.graph.symbol_table.entities.items.len);
    for (entity_kinds, 0..) |expected_kind, index| {
        try std.testing.expectEqual(
            expected_kind,
            decoded.graph.symbol_table.entities.items[index].kind,
        );
    }
}
test "serialize: v1 translation input is rejected" {
    const payload = "{\"format_version\":1}";
    try std.testing.expectError(
        error.InvalidFormatVersion,
        serialize.decode(std.testing.allocator, payload),
    );
}
test "serialize: partial body data is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const payload =
        "{\"format_version\":6,\"crate_name\":\"partial\",\"edition\":\"2021\"," ++
        "\"sidecar\":null,\"toolchain\":null," ++ valid_crates_json ++
        ",\"types\":[],\"instantiations\":[],\"bodies\":{\"exprs\":[],\"stmts\":[],\"pats\":[]," ++
        "\"types\":[],\"bodies\":[{\"owner\":0,\"body\":{\"kind\":\"struct_\"}}]}}";
    try std.testing.expectError(
        error.MissingField,
        serialize.decode(arena.allocator(), payload),
    );
}
test "serialize: absent supported body metadata is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const payload =
        "{\"format_version\":6,\"crate_name\":\"partial\",\"edition\":\"2021\"," ++
        "\"sidecar\":null,\"toolchain\":null," ++ valid_crates_json ++
        ",\"types\":[],\"instantiations\":[],\"bodies\":{\"exprs\":[],\"stmts\":[],\"pats\":[]," ++
        "\"types\":[],\"bodies\":[{\"owner\":0,\"body\":{\"kind\":\"fn_\",\"value\":{\"params\":[]," ++
        "\"ret\":{\"kind\":\"prim\",\"value\":\"unit\"},\"body\":0," ++
        "\"is_allocating\":false}}}]}}";
    try std.testing.expectError(
        error.MissingField,
        serialize.decode(arena.allocator(), payload),
    );
}

test "serialize: absent nullable node field is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const payload =
        "{\"format_version\":6,\"crate_name\":\"partial\",\"edition\":\"2021\"," ++
        "\"sidecar\":null,\"toolchain\":null," ++ valid_crates_json ++
        ",\"types\":[],\"instantiations\":[],\"bodies\":{\"exprs\":[{\"id\":0," ++
        "\"span\":{\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":1}," ++
        "\"kind\":\"unit\",\"value\":null}],\"stmts\":[],\"pats\":[]," ++
        "\"types\":[],\"bodies\":[]}}";
    try std.testing.expectError(
        error.MissingField,
        serialize.decode(arena.allocator(), payload),
    );
}

test "serialize: canonical wire requires every root field" {
    const fields = [_][]const u8{
        "format_version",
        "crate_name",
        "edition",
        "sidecar",
        "toolchain",
        "crates",
        "types",
        "instantiations",
        "bodies",
    };
    for (fields) |field| try expectCanonicalMissingField(field);
}

test "serialize: v2 translation input is rejected" {
    try std.testing.expectError(
        error.InvalidFormatVersion,
        serialize.decode(std.testing.allocator, "{\"format_version\":2}"),
    );
}

test "serialize: v3 translation input is rejected after external-use schema bump" {
    try std.testing.expectError(
        error.InvalidFormatVersion,
        serialize.decode(std.testing.allocator, "{\"format_version\":3}"),
    );
}
test "serialize: v4 translation input is rejected after dependency metadata schema bump" {
    try std.testing.expectError(
        error.InvalidFormatVersion,
        serialize.decode(std.testing.allocator, "{\"format_version\":4}"),
    );
}

test "serialize: canonical body owner must name a real entity" {
    const payload =
        "{\"format_version\":6,\"crate_name\":\"fixture\",\"edition\":\"2021\"," ++
        "\"sidecar\":null,\"toolchain\":null," ++ valid_crates_json ++
        ",\"types\":[],\"instantiations\":[],\"bodies\":{\"exprs\":[],\"stmts\":[]," ++
        "\"pats\":[],\"types\":[],\"bodies\":[{\"owner\":1,\"body\":{\"kind\":\"none\"}}]}}";
    try std.testing.expectError(
        error.InvalidBodyOwner,
        serialize.decode(std.testing.allocator, payload),
    );
}

test "serialize: canonical body kind must match its owner" {
    const payload =
        "{\"format_version\":6,\"crate_name\":\"fixture\",\"edition\":\"2021\"," ++
        "\"sidecar\":null,\"toolchain\":null," ++ valid_crates_json ++
        ",\"types\":[],\"instantiations\":[],\"bodies\":{\"exprs\":[],\"stmts\":[]," ++
        "\"pats\":[],\"types\":[],\"bodies\":[{\"owner\":0,\"body\":{\"kind\":\"fn_\"," ++
        "\"value\":{\"params\":[],\"ret\":{\"kind\":\"prim\",\"value\":\"unit\"}," ++
        "\"generic_params\":[],\"body\":0,\"is_allocating\":false}}}]}}";
    try std.testing.expectError(
        error.BodyKindMismatch,
        serialize.decode(std.testing.allocator, payload),
    );
}

test "serialize: canonical nominal paths require graph bindings" {
    const payload =
        "{\"format_version\":6,\"crate_name\":\"fixture\",\"edition\":\"2021\"," ++
        "\"sidecar\":null,\"toolchain\":null," ++ valid_crates_json ++
        ",\"types\":[{\"kind\":\"path\",\"value\":{\"segments\":[{\"name\":\"Missing\"," ++
        "\"id\":null}]}}],\"instantiations\":[],\"bodies\":{\"exprs\":[],\"stmts\":[]," ++
        "\"pats\":[],\"types\":[],\"bodies\":[{\"owner\":0,\"body\":{\"kind\":\"none\"}}]}}";
    try std.testing.expectError(
        error.UnresolvedTypePath,
        serialize.decode(std.testing.allocator, payload),
    );
}

test "serialize: nominal failure frees every decoded body table" {
    const payload =
        "{\"format_version\":6,\"crate_name\":\"fixture\",\"edition\":\"2021\"," ++
        "\"sidecar\":null,\"toolchain\":null," ++ valid_crates_json ++
        ",\"types\":[{\"kind\":\"path\",\"value\":{\"segments\":[{\"name\":\"Missing\"," ++
        "\"id\":null}]}}],\"instantiations\":[],\"bodies\":{\"exprs\":[{\"id\":0," ++
        "\"span\":{\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":1}," ++
        "\"ty\":0,\"kind\":\"literal\",\"value\":{\"kind\":\"int\",\"value\":{\"text\":\"1\"," ++
        "\"value\":\"1\",\"base\":\"dec\",\"ty_suffix\":null}}}],\"stmts\":[{\"id\":0," ++
        "\"span\":{\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":1}," ++
        "\"ty\":null,\"kind\":\"expr\",\"value\":0}],\"pats\":[{\"id\":0," ++
        "\"span\":{\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":1}," ++
        "\"ty\":null,\"kind\":\"binding\",\"value\":{\"name\":\"x\",\"mode\":\"value\"," ++
        "\"mutable\":false}}],\"types\":[{\"kind\":\"prim\",\"value\":\"u8\"}]," ++
        "\"bodies\":[{\"owner\":0,\"body\":{\"kind\":\"none\"}}]}}";
    try std.testing.expectError(
        error.UnresolvedTypePath,
        serialize.decode(std.testing.allocator, payload),
    );
}
test "serialize: canonical primitive paths and alloc external nominal roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const payload =
        "{\"format_version\":6,\"crate_name\":\"fixture\",\"edition\":\"2021\"," ++
        "\"sidecar\":null,\"toolchain\":null," ++ valid_crates_json ++
        ",\"types\":[{\"kind\":\"prim\",\"value\":\"i32\"},{\"kind\":\"path\",\"value\":{\"segments\":[{\"name\":\"fixture\",\"id\":0}]}},{\"kind\":\"external_nominal\",\"value\":{\"path\":[\"alloc\",\"vec\",\"Vec\"]," ++
        "\"args\":[{\"kind\":\"prim\",\"value\":\"u8\"}]}}]," ++
        "\"instantiations\":[],\"bodies\":{\"exprs\":[],\"stmts\":[],\"pats\":[]," ++
        "\"types\":[],\"bodies\":[{\"owner\":0,\"body\":{\"kind\":\"none\"}}]}}";

    var decoded = try serialize.decode(allocator, payload);
    defer decoded.graph.deinit();
    try root.validateForTranslation(&decoded);

    const encoded = try serialize.encode(allocator, &decoded);
    var roundtripped = try serialize.decode(allocator, encoded);
    defer roundtripped.graph.deinit();
    try root.validateForTranslation(&roundtripped);
    try std.testing.expectEqual(@as(usize, 3), roundtripped.types.len);

    try std.testing.expectEqual(
        types.Prim.i32,
        switch (roundtripped.types[0]) {
            .prim => |prim| prim,
            else => return error.TestUnexpectedResult,
        },
    );

    const path = switch (roundtripped.types[1]) {
        .path => |path| path,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), path.segments.len);
    try std.testing.expectEqualStrings("fixture", path.segments[0].name);
    try std.testing.expectEqual(@as(?spine.EntityId, 0), path.segments[0].id);

    const external = switch (roundtripped.types[2]) {
        .external_nominal => |external| external,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 3), external.path.len);
    try std.testing.expectEqualStrings("alloc", external.path[0]);
    try std.testing.expectEqualStrings("vec", external.path[1]);
    try std.testing.expectEqualStrings("Vec", external.path[2]);
    try std.testing.expectEqual(@as(usize, 1), external.args.len);
    try std.testing.expectEqual(
        types.Prim.u8,
        switch (external.args[0]) {
            .prim => |prim| prim,
            else => return error.TestUnexpectedResult,
        },
    );
}

test "serialize: canonical external nominal rejects unknown root" {
    const payload =
        "{\"format_version\":6,\"crate_name\":\"fixture\",\"edition\":\"2021\"," ++
        "\"sidecar\":null,\"toolchain\":null," ++ valid_crates_json ++
        ",\"types\":[{\"kind\":\"external_nominal\",\"value\":{\"path\":[\"unknown\"," ++
        "\"vec\",\"Vec\"],\"args\":[{\"kind\":\"prim\",\"value\":\"u8\"}]}}]," ++
        "\"instantiations\":[],\"bodies\":{\"exprs\":[],\"stmts\":[],\"pats\":[]," ++
        "\"types\":[],\"bodies\":[{\"owner\":0,\"body\":{\"kind\":\"none\"}}]}}";
    try std.testing.expectError(
        error.UnsupportedExternalNominalType,
        serialize.decode(std.testing.allocator, payload),
    );
}

test "serialize: canonical instantiation metadata is complete" {
    const payload =
        "{\"format_version\":6,\"crate_name\":\"bad\",\"edition\":\"2021\"," ++
        "\"sidecar\":null,\"toolchain\":null," ++ valid_crates_json ++
        ",\"types\":[],\"instantiations\":[{\"generic_id\":0,\"args\":{\"params\":[]}}]," ++
        "\"bodies\":{\"exprs\":[],\"stmts\":[],\"pats\":[],\"types\":[]," ++
        "\"bodies\":[{\"owner\":0,\"body\":{\"kind\":\"none\"}}]}}";
    try std.testing.expectError(
        error.MissingField,
        serialize.decode(std.testing.allocator, payload),
    );
}

test "serialize: unknown wire tags and negative repeats are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const unknown_length =
        "{\"format_version\":6,\"crate_name\":\"bad\",\"edition\":\"2021\"," ++
        "\"sidecar\":null,\"toolchain\":null," ++ valid_crates_json ++
        ",\"types\":[{\"kind\":\"array\",\"value\":{\"elem\":{\"kind\":\"prim\"," ++
        "\"value\":\"u8\"},\"len\":{\"kind\":\"unknown\",\"value\":1}}}]," ++
        "\"instantiations\":[],\"bodies\":{\"exprs\":[],\"stmts\":[],\"pats\":[],\"types\":[]," ++
        "\"bodies\":[{\"owner\":0,\"body\":{\"kind\":\"none\"}}]}}";
    try std.testing.expectError(
        error.BadWireFormat,
        serialize.decode(allocator, unknown_length),
    );

    const negative_repeat =
        "{\"format_version\":6,\"crate_name\":\"bad\",\"edition\":\"2021\"," ++
        "\"sidecar\":null,\"toolchain\":null," ++ valid_crates_json ++
        ",\"instantiations\":[],\"types\":[],\"bodies\":{\"exprs\":[{\"id\":0," ++
        "\"span\":{\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":1}," ++
        "\"ty\":null,\"kind\":\"vec_lit\",\"value\":{\"elements\":[],\"repeat\":-1}}]," ++
        "\"stmts\":[],\"pats\":[],\"types\":[],\"bodies\":[{\"owner\":0,\"body\":{\"kind\":\"none\"}}]}}";
    try std.testing.expectError(
        error.BadWireFormat,
        serialize.decode(allocator, negative_repeat),
    );

    const unknown_reason =
        "{\"format_version\":6,\"crate_name\":\"bad\",\"edition\":\"2021\"," ++
        "\"sidecar\":null,\"toolchain\":null," ++ valid_crates_json ++
        ",\"types\":[{\"kind\":\"unsupported\",\"value\":{\"reason\":\"unknown_reason\"," ++
        "\"message\":\"bad\",\"span\":{\"start_line\":1,\"start_col\":1," ++
        "\"end_line\":1,\"end_col\":1}}}],\"instantiations\":[],\"bodies\":{\"exprs\":[],\"stmts\":[]," ++
        "\"pats\":[],\"types\":[],\"bodies\":[{\"owner\":0,\"body\":{\"kind\":\"none\"}}]}}";
    try std.testing.expectError(
        error.BadWireFormat,
        serialize.decode(allocator, unknown_reason),
    );
    const incomplete_expr_unsupported =
        "{\"format_version\":6,\"crate_name\":\"bad\",\"edition\":\"2021\"," ++
        "\"sidecar\":null,\"toolchain\":null," ++ valid_crates_json ++
        ",\"types\":[],\"instantiations\":[],\"bodies\":{\"exprs\":[{\"id\":0," ++
        "\"span\":{\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":1}," ++
        "\"ty\":null,\"kind\":\"unsupported\",\"value\":{\"reason\":\"cast expression\"}}]," ++
        "\"stmts\":[],\"pats\":[],\"types\":[],\"bodies\":[{\"owner\":0,\"body\":{\"kind\":\"none\"}}]}}";
    try std.testing.expectError(
        error.MissingField,
        serialize.decode(allocator, incomplete_expr_unsupported),
    );

    const incomplete_pattern_unsupported =
        "{\"format_version\":6,\"crate_name\":\"bad\",\"edition\":\"2021\"," ++
        "\"sidecar\":null,\"toolchain\":null," ++ valid_crates_json ++
        ",\"types\":[],\"instantiations\":[],\"bodies\":{\"exprs\":[],\"stmts\":[],\"pats\":[{\"id\":0," ++
        "\"span\":{\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":1}," ++
        "\"ty\":null,\"kind\":\"unsupported\",\"value\":{\"reason\":\"slice pattern\"}}]," ++
        "\"types\":[],\"bodies\":[{\"owner\":0,\"body\":{\"kind\":\"none\"}}]}}";
    try std.testing.expectError(
        error.MissingField,
        serialize.decode(allocator, incomplete_pattern_unsupported),
    );
}

test "serialize: rich bodies preserve all supported metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 4,
    };
    const field = items.Field{
        .name = "value",
        .ty = .{ .prim = .i32 },
        .visibility = .public,
        .span = span,
    };
    const param = items.Param{ .name = "input", .ty = .{ .prim = .i32 }, .span = span };
    const method = bodies.StructMethod{
        .name = "make",
        .visibility = .public,
        .params = &.{param},
        .ret = .{ .prim = .i32 },
        .generic_params = &.{"U"},
        .body = 1,
        .receiver = .ref_,
        .is_allocating = true,
    };
    const trait_method = bodies.TraitMethodSig{
        .name = "convert",
        .params = &.{param},
        .ret = .{ .prim = .i32 },
        .receiver = .mut_ref,
    };
    const path_segments = [_]types.PathSegment{.{ .name = "item_5", .id = 5 }};
    const alias_target: types.Type = .{ .path = .{ .segments = &path_segments } };
    const body_kinds = [_]bodies.BodyKind{
        .none,
        .{ .fn_ = .{
            .params = &.{param},
            .ret = .{ .prim = .i32 },
            .generic_params = &.{"T"},
            .body = 0,
            .is_allocating = true,
        } },
        .{ .struct_ = .{
            .generic_params = &.{"T"},
            .trait_bounds = &.{"T: Copy"},
            .layout = .tuple,
            .fields = &.{field},
            .methods = &.{method},
            .has_dynamic_resources = true,
        } },
        .{ .enum_ = .{
            .kind = .data,
            .variants = &.{
                .{ .name = "Value", .fields = .{ .named = &.{field} }, .discriminant = 7 },
            },
            .repr_int = .u32,
            .non_exhaustive = true,
        } },
        .{ .trait_ = .{
            .name = "Convert",
            .supertraits = &.{"Display"},
            .methods = &.{trait_method},
        } },
        .{ .type_alias = .{ .target = alias_target } },
    };
    const root_types = [_]types.Type{.{ .prim = .i32 }};
    const ir = serialize.RustIr{
        .crate_name = "rich",
        .edition = "2021",
        .graph = try initTestGraph(
            allocator,
            "rich",
            &.{ .fn_, .struct_, .enum_, .trait_, .type_alias },
        ),
        .types = &root_types,
        .bodies = .{
            .exprs = &.{
                .{ .id = 0, .span = span, .ty = 0, .kind = .{ .literal = .{ .int = .{
                    .text = "7",
                    .value = 7,
                    .base = .dec,
                    .ty_suffix = "i32",
                } } } },
                .{ .id = 1, .span = span, .ty = 0, .kind = .{ .literal = .{ .int = .{
                    .text = "8",
                    .value = 8,
                    .base = .dec,
                    .ty_suffix = "i32",
                } } } },
            },
            .stmts = &.{},
            .pats = &.{},
            .types = &root_types,
            .bodies = &body_kinds,
        },
    };

    const encoded = try serialize.encode(allocator, &ir);
    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();
    const fn_body = decoded.bodies.bodies[1].fn_;
    try std.testing.expect(fn_body.is_allocating);
    try std.testing.expectEqualStrings("T", fn_body.generic_params[0]);
    try std.testing.expectEqualStrings("input", fn_body.params[0].name);
    try std.testing.expectEqual(@as(exprs.NodeId, 0), fn_body.body);
    switch (fn_body.ret) {
        .prim => |prim| try std.testing.expectEqual(types.Prim.i32, prim),
        else => return error.TestUnexpectedResult,
    }
    const struct_body = decoded.bodies.bodies[2].struct_;
    try std.testing.expectEqualStrings("T", struct_body.generic_params[0]);
    try std.testing.expectEqualStrings("T: Copy", struct_body.trait_bounds[0]);
    try std.testing.expectEqual(items.struct_kind.tuple, struct_body.layout);
    try std.testing.expectEqualStrings("value", struct_body.fields[0].name);
    try std.testing.expectEqual(spine.Visibility.public, struct_body.fields[0].visibility);
    try std.testing.expectEqualStrings("make", struct_body.methods[0].name);
    try std.testing.expectEqualStrings("U", struct_body.methods[0].generic_params[0]);
    try std.testing.expectEqual(@as(exprs.NodeId, 1), struct_body.methods[0].body);
    try std.testing.expectEqual(items.Receiver.ref_, struct_body.methods[0].receiver.?);
    try std.testing.expect(struct_body.methods[0].is_allocating);
    try std.testing.expectEqual(@as(usize, 1), struct_body.fields.len);
    try std.testing.expectEqual(@as(usize, 1), struct_body.methods.len);
    try std.testing.expect(struct_body.has_dynamic_resources);
    const enum_body = decoded.bodies.bodies[3].enum_;
    try std.testing.expectEqual(@as(usize, 1), enum_body.variants.len);
    try std.testing.expectEqual(@as(?items.int_repr, .u32), enum_body.repr_int);
    try std.testing.expectEqual(items.enum_kind.data, enum_body.kind);
    try std.testing.expectEqualStrings("Value", enum_body.variants[0].name);
    try std.testing.expectEqual(@as(?i128, 7), enum_body.variants[0].discriminant);
    switch (enum_body.variants[0].fields) {
        .named => |fields| try std.testing.expectEqualStrings("value", fields[0].name),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(enum_body.non_exhaustive);
    const trait_body = decoded.bodies.bodies[4].trait_;
    try std.testing.expectEqualStrings("Convert", trait_body.name);
    try std.testing.expectEqualStrings("convert", trait_body.methods[0].name);
    try std.testing.expectEqual(items.Receiver.mut_ref, trait_body.methods[0].receiver);
    try std.testing.expectEqualStrings("input", trait_body.methods[0].params[0].name);
    try std.testing.expectEqualStrings("Display", trait_body.supertraits[0]);
    try std.testing.expectEqual(@as(usize, 1), trait_body.methods.len);
    const alias_body = decoded.bodies.bodies[5].type_alias;
    switch (alias_body.target) {
        .path => |path| {
            try std.testing.expectEqualStrings("item_5", path.segments[0].name);
            try std.testing.expectEqual(@as(?spine.EntityId, 5), path.segments[0].id);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "serialize: type alias generic parameters roundtrip and validate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const key_type = types.Type{ .path = .{ .segments = &.{
        .{ .name = "K", .id = null },
    } } };
    const value_type = types.Type{ .path = .{ .segments = &.{
        .{ .name = "V", .id = null },
    } } };
    const alias_target = types.Type{ .external_nominal = .{
        .path = &.{ "std", "collections", "HashMap" },
        .args = &.{ key_type, value_type },
    } };
    const ir = serialize.RustIr{
        .crate_name = "alias_fixture",
        .edition = "2021",
        .graph = try initTestGraph(allocator, "alias_fixture", &.{.type_alias}),
        .bodies = .{
            .exprs = &.{},
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = &.{
                .none,
                .{ .type_alias = .{
                    .target = alias_target,
                    .generic_params = &.{ "K", "V" },
                } },
            },
        },
    };

    const encoded = try serialize.encode(allocator, &ir);
    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();
    // The target's arguments are id-free path segments, so the parameter names
    // are the only thing that makes them resolvable. They must cross the wire.
    const alias_body = decoded.bodies.bodies[1].type_alias;
    try std.testing.expectEqual(@as(usize, 2), alias_body.generic_params.len);
    try std.testing.expectEqualStrings("K", alias_body.generic_params[0]);
    try std.testing.expectEqualStrings("V", alias_body.generic_params[1]);
    const external = switch (alias_body.target) {
        .external_nominal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 2), external.args.len);
    try std.testing.expectEqualStrings("K", external.args[0].path.segments[0].name);
    try std.testing.expectEqualStrings("V", external.args[1].path.segments[0].name);
    try root.validateForTranslation(&decoded);
}

test "serialize: a type alias body without generic parameters still decodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A payload written before the field existed omits it entirely. The
    // decoder must read that as "no parameters" rather than fail, which is
    // what keeps the additive field from needing a wire format version bump.
    const payload =
        \\{
        \\  "format_version": 6,
        \\  "crate_name": "legacy",
        \\  "edition": "2021",
        \\  "sidecar": null,
        \\  "toolchain": null,
        \\  "crates": [{
        \\    "name": "legacy", "edition": 2021, "kind": "lib", "root": 0,
        \\    "is_translated": true, "deps": [],
        \\    "entities": [
        \\      {"id":0,"kind":"module","name":"legacy","span":{"start_line":1,"start_col":1,"end_line":1,"end_col":1},"visibility":{"kind":"public"},"parent":null,"resolved":null,"renamed_to":null,"attributes":[]},
        \\      {"id":1,"kind":"type_alias","name":"Alias","span":{"start_line":1,"start_col":1,"end_line":1,"end_col":1},"visibility":{"kind":"public"},"parent":0,"resolved":null,"renamed_to":null,"attributes":[]}
        \\    ],
        \\    "modules": [{"id":0,"kind":"root","name":"legacy","parent":null,"source_path":null,"is_crate":true,"is_extern":false,"span":{"start_line":1,"start_col":1,"end_line":1,"end_col":1},"items":[1],"attributes":[]}],
        \\    "uses": []
        \\  }],
        \\  "types": [],
        \\  "instantiations": [],
        \\  "bodies": {
        \\    "exprs": [], "stmts": [], "pats": [], "types": [],
        \\    "bodies": [
        \\      {"owner":0,"body":{"kind":"none"}},
        \\      {"owner":1,"body":{"kind":"type_alias","value":{"target":{"kind":"prim","value":"u32"}}}}
        \\    ]
        \\  }
        \\}
    ;
    var decoded = try serialize.decode(arena.allocator(), payload);
    defer decoded.graph.deinit();
    const alias_body = decoded.bodies.bodies[1].type_alias;
    try std.testing.expectEqual(@as(usize, 0), alias_body.generic_params.len);
}

test "serialize: trait impl and generic metadata roundtrip" {
    // This fixture keeps associated items as child entities.
    // It exercises every new metadata field through encode, decode, and validation.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 8,
    };

    var crate_graph = try initTestGraph(
        allocator,
        "metadata",
        &.{ .trait_, .struct_, .impl_, .fn_, .const_, .type_alias, .fn_ },
    );
    crate_graph.modules.items[0].items = try allocator.dupe(
        spine.EntityId,
        &.{ 1, 2, 3, 7 },
    );
    for ([_]spine.EntityId{ 4, 5, 6 }) |child_id| {
        crate_graph.symbol_table.entities.items[child_id].parent = 3;
    }

    const trait_path: types.Path = .{
        .segments = &.{.{ .name = "item_1", .id = 1 }},
    };
    const self_path: types.Path = .{
        .segments = &.{.{ .name = "item_2", .id = 2 }},
    };
    const external_trait_path: types.Path = .{
        .segments = &.{
            .{ .name = "std", .id = null },
            .{ .name = "hash", .id = null },
            .{ .name = "Hasher", .id = null },
        },
    };
    const method_generic_path: types.Path = .{
        .segments = &.{.{ .name = "U", .id = null }},
    };
    const function_generic_path: types.Path = .{
        .segments = &.{.{ .name = "V", .id = null }},
    };
    const trait_generic_path: types.Path = .{
        .segments = &.{.{ .name = "T", .id = null }},
    };
    const trait_method_generic_path: types.Path = .{
        .segments = &.{.{ .name = "M", .id = null }},
    };
    const trait_bound: types.Bound = .{
        .path = trait_path,
        .args = &.{.{ .prim = .u8 }},
        .associated_types = &.{.{
            .name = "Output",
            .ty = .{ .prim = .u8 },
        }},
        .optional = true,
    };
    const external_trait_bound: types.Bound = .{ .path = external_trait_path };
    const trait_generics: types.Generics = .{
        .params = &.{.{ .type_ = .{
            .name = "T",
            .bounds = &.{trait_bound},
        } }},
        .where_clauses = &.{},
    };
    const trait_method_generics: types.Generics = .{
        .params = &.{.{ .type_ = .{
            .name = "M",
            .bounds = &.{trait_bound},
        } }},
        .where_clauses = &.{},
    };
    const impl_generics: types.Generics = .{
        .params = &.{.{ .type_ = .{
            .name = "T",
            .bounds = &.{ trait_bound, external_trait_bound },
        } }},
        .where_clauses = &.{},
    };
    const method_generics: types.Generics = .{
        .params = &.{.{ .type_ = .{
            .name = "U",
            .bounds = &.{trait_bound},
        } }},
        .where_clauses = &.{.{
            .self_ty = method_generic_path,
            .bounds = &.{trait_bound},
        }},
    };
    const function_generics: types.Generics = .{
        .params = &.{.{ .type_ = .{
            .name = "V",
            .bounds = &.{trait_bound},
        } }},
        .where_clauses = &.{.{
            .self_ty = function_generic_path,
            .bounds = &.{trait_bound},
        }},
    };

    const method_param: items.Param = .{
        .name = "value",
        .ty = .{ .path = method_generic_path },
        .span = span,
    };
    const method: bodies.StructMethod = .{
        .name = "convert",
        .params = &.{method_param},
        .ret = .{ .path = method_generic_path },
        .generic_params = &.{"U"},
        .generics = method_generics,
        .body = 1,
        .receiver = .ref_,
    };
    const function_param: items.Param = .{
        .name = "value",
        .ty = .{ .path = function_generic_path },
        .span = span,
    };
    const trait_method_param: items.Param = .{
        .name = "value",
        .ty = .{ .path = trait_method_generic_path },
        .span = span,
    };
    const trait_method: bodies.TraitMethodSig = .{
        .name = "collect",
        .params = &.{trait_method_param},
        .ret = .{ .path = trait_generic_path },
        .generic_params = &.{"M"},
        .generics = trait_method_generics,
        .receiver = .ref_,
    };
    const type_rows = [_]types.Type{.{ .prim = .u64 }};
    const expression_rows = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = 0,
            .kind = .{ .literal = .{ .int = .{
                .text = "7u64",
                .value = 7,
                .base = .dec,
                .ty_suffix = "u64",
            } } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{},
                .tail = 0,
                .labelled = null,
            } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{},
                .tail = 0,
                .labelled = null,
            } },
        },
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{},
                .tail = 0,
                .labelled = null,
            } },
        },
    };
    const body_rows = [_]bodies.BodyKind{
        .none,
        .{ .trait_ = .{
            .name = "item_1",
            .generic_params = &.{"T"},
            .generics = trait_generics,
            .methods = &.{trait_method},
            .assoc_types = &.{.{
                .name = "Output",
                .generics = null,
                .bounds = &.{trait_bound},
                .default = .{ .path = self_path },
            }},
            .assoc_consts = &.{.{
                .name = "LIMIT",
                .ty = .{ .prim = .u64 },
                .default = 0,
            }},
        } },
        .{ .struct_ = .{
            .layout = .unit,
            .methods = &.{method},
        } },
        .{ .impl_ = .{
            .self_ty = .{ .path = self_path },
            .trait_path = trait_path,
            .trait_args = &.{.{ .path = self_path }},
            .trait_associated_types = &.{.{
                .name = "InputType",
                .ty = .{ .prim = .u8 },
            }},
            .generics = impl_generics,
            .assoc_items = &.{ 4, 5, 6 },
        } },
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .u64 },
            .body = 2,
        } },
        .{ .const_ = .{
            .ty = .{ .prim = .u64 },
            .init = 0,
        } },
        .{ .type_alias = .{
            .target = .{ .path = self_path },
        } },
        .{ .fn_ = .{
            .params = &.{function_param},
            .ret = .{ .path = function_generic_path },
            .generic_params = &.{"V"},
            .generics = function_generics,
            .body = 3,
        } },
    };
    var fixture_ir: serialize.RustIr = .{
        .crate_name = "metadata",
        .edition = "2021",
        .graph = crate_graph,
        .types = &type_rows,
        .bodies = .{
            .exprs = &expression_rows,
            .stmts = &.{},
            .pats = &.{},
            .types = &type_rows,
            .bodies = &body_rows,
        },
    };
    defer fixture_ir.graph.deinit();
    try root.validateForTranslation(&fixture_ir);
    const encoded = try serialize.encode(allocator, &fixture_ir);
    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();
    try root.validateForTranslation(&decoded);

    const decoded_trait = decoded.bodies.bodies[1].trait_;
    try std.testing.expectEqual(@as(usize, 1), decoded_trait.generic_params.len);
    try std.testing.expectEqualStrings("T", decoded_trait.generic_params[0]);
    const decoded_trait_generics = decoded_trait.generics orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), decoded_trait_generics.params.len);
    switch (decoded_trait_generics.params[0]) {
        .type_ => |param| {
            try std.testing.expectEqualStrings("T", param.name);
            try std.testing.expectEqual(@as(usize, 1), param.bounds.len);
            const bound = param.bounds[0];
            try std.testing.expect(bound.optional);
            try std.testing.expectEqual(@as(usize, 1), bound.args.len);
            switch (bound.args[0]) {
                .prim => |primitive| try std.testing.expectEqual(types.Prim.u8, primitive),
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqual(@as(usize, 1), bound.associated_types.len);
            try std.testing.expectEqualStrings("Output", bound.associated_types[0].name);
            switch (bound.associated_types[0].ty) {
                .prim => |primitive| try std.testing.expectEqual(types.Prim.u8, primitive),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), decoded_trait.methods.len);
    const decoded_trait_method = decoded_trait.methods[0];
    try std.testing.expectEqualStrings("M", decoded_trait_method.generic_params[0]);
    const decoded_trait_method_generics = decoded_trait_method.generics orelse
        return error.TestUnexpectedResult;
    switch (decoded_trait_method_generics.params[0]) {
        .type_ => |param| try std.testing.expectEqualStrings("M", param.name),
        else => return error.TestUnexpectedResult,
    }
    switch (decoded_trait_method.ret) {
        .path => |path| try std.testing.expectEqualStrings("T", path.segments[0].name),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), decoded_trait.assoc_types.len);
    try std.testing.expectEqualStrings("Output", decoded_trait.assoc_types[0].name);
    try std.testing.expect(decoded_trait.assoc_types[0].generics == null);
    try std.testing.expectEqual(@as(usize, 1), decoded_trait.assoc_types[0].bounds.len);
    try std.testing.expectEqual(
        @as(?spine.EntityId, 1),
        decoded_trait.assoc_types[0].bounds[0].path.segments[0].id,
    );
    const assoc_default = decoded_trait.assoc_types[0].default orelse
        return error.TestUnexpectedResult;
    switch (assoc_default) {
        .path => |path| {
            try std.testing.expectEqualStrings("item_2", path.segments[0].name);
            try std.testing.expectEqual(@as(?spine.EntityId, 2), path.segments[0].id);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), decoded_trait.assoc_consts.len);
    try std.testing.expectEqualStrings("LIMIT", decoded_trait.assoc_consts[0].name);
    try std.testing.expectEqual(
        @as(?exprs.NodeId, 0),
        decoded_trait.assoc_consts[0].default,
    );

    const decoded_impl = decoded.bodies.bodies[3].impl_;
    switch (decoded_impl.self_ty) {
        .path => |path| {
            try std.testing.expectEqualStrings("item_2", path.segments[0].name);
            try std.testing.expectEqual(@as(?spine.EntityId, 2), path.segments[0].id);
        },
        else => return error.TestUnexpectedResult,
    }
    const decoded_trait_path = decoded_impl.trait_path orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(
        "item_1",
        decoded_trait_path.segments[0].name,
    );
    try std.testing.expectEqual(
        @as(?spine.EntityId, 1),
        decoded_trait_path.segments[0].id,
    );
    try std.testing.expectEqual(@as(usize, 1), decoded_impl.trait_args.len);
    switch (decoded_impl.trait_args[0]) {
        .path => |path| {
            try std.testing.expectEqualStrings("item_2", path.segments[0].name);
            try std.testing.expectEqual(@as(?spine.EntityId, 2), path.segments[0].id);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), decoded_impl.trait_associated_types.len);
    try std.testing.expectEqualStrings(
        "InputType",
        decoded_impl.trait_associated_types[0].name,
    );
    switch (decoded_impl.trait_associated_types[0].ty) {
        .prim => |primitive| try std.testing.expectEqual(types.Prim.u8, primitive),
        else => return error.TestUnexpectedResult,
    }
    const decoded_impl_generics = decoded_impl.generics orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), decoded_impl_generics.params.len);
    switch (decoded_impl_generics.params[0]) {
        .type_ => |param| {
            try std.testing.expectEqualStrings("T", param.name);
            try std.testing.expectEqual(
                @as(?spine.EntityId, 1),
                param.bounds[0].path.segments[0].id,
            );
            try std.testing.expectEqual(@as(usize, 2), param.bounds.len);
            try std.testing.expectEqualStrings(
                "std",
                param.bounds[1].path.segments[0].name,
            );
            try std.testing.expectEqualStrings(
                "Hasher",
                param.bounds[1].path.segments[2].name,
            );
            try std.testing.expect(param.bounds[1].path.segments[2].id == null);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 0), decoded_impl_generics.where_clauses.len);
    try std.testing.expectEqualSlices(
        spine.EntityId,
        &.{ 4, 5, 6 },
        decoded_impl.assoc_items,
    );
    for (decoded_impl.assoc_items) |child_id| {
        try std.testing.expectEqual(
            @as(?spine.EntityId, 3),
            decoded.graph.symbol_table.entities.items[child_id].parent,
        );
    }

    const decoded_method = decoded.bodies.bodies[2].struct_.methods[0];
    const decoded_method_generics = decoded_method.generics orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("U", decoded_method.generic_params[0]);
    switch (decoded_method_generics.params[0]) {
        .type_ => |param| {
            try std.testing.expectEqualStrings("U", param.name);
            try std.testing.expectEqual(
                @as(?spine.EntityId, 1),
                param.bounds[0].path.segments[0].id,
            );
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings(
        "U",
        decoded_method_generics.where_clauses[0].self_ty.segments[0].name,
    );
    try std.testing.expect(
        decoded_method_generics.where_clauses[0].self_ty.segments[0].id == null,
    );
    try std.testing.expectEqual(
        @as(?spine.EntityId, 1),
        decoded_method_generics.where_clauses[0].bounds[0].path.segments[0].id,
    );

    const decoded_function = decoded.bodies.bodies[7].fn_;
    const decoded_function_generics = decoded_function.generics orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("V", decoded_function.generic_params[0]);
    switch (decoded_function.params[0].ty) {
        .path => |path| {
            try std.testing.expectEqualStrings("V", path.segments[0].name);
            try std.testing.expect(path.segments[0].id == null);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (decoded_function_generics.params[0]) {
        .type_ => |param| {
            try std.testing.expectEqualStrings("V", param.name);
            try std.testing.expectEqual(
                @as(?spine.EntityId, 1),
                param.bounds[0].path.segments[0].id,
            );
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings(
        "V",
        decoded_function_generics.where_clauses[0].self_ty.segments[0].name,
    );
    try std.testing.expectEqual(
        @as(?spine.EntityId, 1),
        decoded_function_generics.where_clauses[0].bounds[0].path.segments[0].id,
    );
    try std.testing.expectEqual(@as(exprs.NodeId, 0), decoded.bodies.bodies[5].const_.init);
    switch (decoded.bodies.bodies[6].type_alias.target) {
        .path => |path| {
            try std.testing.expectEqualStrings("item_2", path.segments[0].name);
            try std.testing.expectEqual(@as(?spine.EntityId, 2), path.segments[0].id);
        },
        else => return error.TestUnexpectedResult,
    }

    var malformed_body_rows = body_rows;
    var malformed_ir = fixture_ir;
    malformed_ir.bodies.bodies = &malformed_body_rows;
    malformed_body_rows[3].impl_.assoc_items = &.{7};
    try std.testing.expectError(
        error.InvalidEntityReference,
        root.validateForTranslation(&malformed_ir),
    );
    malformed_body_rows[3].impl_.assoc_items = &.{ 4, 4 };
    try std.testing.expectError(
        error.InvalidEntityReference,
        root.validateForTranslation(&malformed_ir),
    );
}

test "serialize: bound Self keeps its concrete identity and abstract projection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 8,
    };

    var crate_graph = try initTestGraph(
        allocator,
        "self_identity",
        &.{ .struct_, .struct_, .trait_ },
    );
    defer crate_graph.deinit();

    const concrete_self_path: types.Path = .{
        .segments = &.{.{ .name = "Self", .id = 1 }},
    };
    const concrete_self_param: items.Param = .{
        .name = "other",
        .ty = .{ .path = concrete_self_path },
        .span = span,
    };
    const concrete_method: bodies.StructMethod = .{
        .name = "combine",
        .params = &.{concrete_self_param},
        .ret = .{ .path = concrete_self_path },
        .body = 0,
        .receiver = .ref_,
    };
    const abstract_projection: types.Path = .{
        .segments = &.{
            .{ .name = "Self", .id = null },
            .{ .name = "item_3", .id = 3 },
            .{ .name = "Output", .id = null },
        },
    };
    const expression_rows = [_]exprs.Expr{.{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{
            .statements = &.{},
            .tail = null,
            .labelled = null,
        } },
    }};
    const body_rows = [_]bodies.BodyKind{
        .none,
        .{ .struct_ = .{
            .layout = .unit,
            .methods = &.{concrete_method},
        } },
        .{ .struct_ = .{ .layout = .unit } },
        .{ .trait_ = .{
            .name = "item_3",
            .assoc_types = &.{.{
                .name = "Output",
                .generics = null,
                .bounds = &.{},
                .default = .{ .path = abstract_projection },
            }},
        } },
    };
    const fixture_ir: serialize.RustIr = .{
        .crate_name = "self_identity",
        .graph = crate_graph,
        .bodies = .{
            .exprs = &expression_rows,
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = &body_rows,
        },
    };

    try root.validateForTranslation(&fixture_ir);
    const encoded = try serialize.encode(allocator, &fixture_ir);
    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();
    try root.validateForTranslation(&decoded);

    const decoded_self = decoded.bodies.bodies[1].struct_.methods[0].ret.path.segments[0];
    try std.testing.expectEqualStrings("Self", decoded_self.name);
    try std.testing.expectEqual(@as(?spine.EntityId, 1), decoded_self.id);
    const decoded_default = decoded.bodies.bodies[3].trait_.assoc_types[0].default orelse
        return error.TestUnexpectedResult;
    const decoded_projection = switch (decoded_default) {
        .path => |path| path.segments,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Self", decoded_projection[0].name);
    try std.testing.expectEqual(@as(?spine.EntityId, null), decoded_projection[0].id);
    try std.testing.expectEqual(@as(?spine.EntityId, 3), decoded_projection[1].id);

    const wrong_self_path: types.Path = .{
        .segments = &.{.{ .name = "Self", .id = 2 }},
    };
    const wrong_self_param: items.Param = .{
        .name = "other",
        .ty = .{ .path = wrong_self_path },
        .span = span,
    };
    var wrong_method = concrete_method;
    wrong_method.params = &.{wrong_self_param};
    wrong_method.ret = .{ .path = wrong_self_path };
    var wrong_body_rows = body_rows;
    wrong_body_rows[1].struct_.methods = &.{wrong_method};
    var wrong_ir = fixture_ir;
    wrong_ir.bodies.bodies = &wrong_body_rows;
    try std.testing.expectError(error.InvalidTypePath, root.validateForTranslation(&wrong_ir));

    const invalid_self_path: types.Path = .{
        .segments = &.{.{ .name = "Self", .id = 99 }},
    };
    var invalid_method = concrete_method;
    invalid_method.ret = .{ .path = invalid_self_path };
    var invalid_body_rows = body_rows;
    invalid_body_rows[1].struct_.methods = &.{invalid_method};
    var invalid_ir = fixture_ir;
    invalid_ir.bodies.bodies = &invalid_body_rows;
    try std.testing.expectError(error.InvalidTypePath, root.validateForTranslation(&invalid_ir));
}

test "serialize: declared dependency trait validates while unknown root fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 8,
    };

    var crate_graph = try initTestGraph(allocator, "dependency_bound", &.{.fn_});
    defer crate_graph.deinit();
    const dependencies = try allocator.alloc(graph.CrateDep, 1);
    dependencies[0] = .{
        .extern_name = try allocator.dupe(u8, "num-traits"),
        .local_alias = try allocator.dupe(u8, "num-traits"),
        .id = 1,
    };
    crate_graph.crates.items[0].deps = dependencies;

    const dependency_trait_path: types.Path = .{
        .segments = &.{
            .{ .name = "num_traits", .id = null },
            .{ .name = "Bounded", .id = null },
        },
    };
    const dependency_bound: types.Bound = .{ .path = dependency_trait_path };
    const function_generics: types.Generics = .{
        .params = &.{.{ .type_ = .{
            .name = "T",
            .bounds = &.{dependency_bound},
        } }},
        .where_clauses = &.{},
    };
    const expression_rows = [_]exprs.Expr{.{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{
            .statements = &.{},
            .tail = null,
            .labelled = null,
        } },
    }};
    const body_rows = [_]bodies.BodyKind{
        .none,
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .generic_params = &.{"T"},
            .generics = function_generics,
            .body = 0,
        } },
    };
    const fixture_ir: serialize.RustIr = .{
        .crate_name = "dependency_bound",
        .graph = crate_graph,
        .bodies = .{
            .exprs = &expression_rows,
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = &body_rows,
        },
    };

    try root.validateForTranslation(&fixture_ir);
    const encoded = try serialize.encode(allocator, &fixture_ir);
    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();
    try root.validateForTranslation(&decoded);
    try std.testing.expectEqualStrings(
        "num-traits",
        decoded.graph.crates.items[0].deps[0].extern_name,
    );
    const decoded_bound = decoded.bodies.bodies[1].fn_.generics.?.params[0].type_.bounds[0];
    try std.testing.expectEqualStrings("num_traits", decoded_bound.path.segments[0].name);
    try std.testing.expectEqual(@as(?spine.EntityId, null), decoded_bound.path.segments[0].id);

    const unknown_trait_path: types.Path = .{
        .segments = &.{
            .{ .name = "unknown_dependency", .id = null },
            .{ .name = "Bounded", .id = null },
        },
    };
    const unknown_bound: types.Bound = .{ .path = unknown_trait_path };
    const unknown_generics: types.Generics = .{
        .params = &.{.{ .type_ = .{
            .name = "T",
            .bounds = &.{unknown_bound},
        } }},
        .where_clauses = &.{},
    };
    var unknown_function = body_rows[1].fn_;
    unknown_function.generics = unknown_generics;
    var unknown_body_rows = body_rows;
    unknown_body_rows[1] = .{ .fn_ = unknown_function };
    var unknown_ir = fixture_ir;
    unknown_ir.bodies.bodies = &unknown_body_rows;
    try std.testing.expectError(error.UnresolvedTypePath, root.validateForTranslation(&unknown_ir));
}

test "serialize: format write preserves template and references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 8,
    };

    var crate_graph = try initTestGraph(allocator, "format_write", &.{.fn_});
    defer crate_graph.deinit();
    const expression_rows = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{},
                .tail = null,
                .labelled = null,
            } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .unit,
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .unit,
        },
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{ .format_write = .{
                .writer = 1,
                .template = "value={}\n",
                .args = &.{2},
            } },
        },
    };
    const body_rows = [_]bodies.BodyKind{
        .none,
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = 0,
        } },
    };
    const fixture_ir: serialize.RustIr = .{
        .crate_name = "format_write",
        .graph = crate_graph,
        .bodies = .{
            .exprs = &expression_rows,
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = &body_rows,
        },
    };

    try root.validateForTranslation(&fixture_ir);
    const encoded = try serialize.encode(allocator, &fixture_ir);
    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();
    try root.validateForTranslation(&decoded);

    const decoded_format = switch (decoded.bodies.exprs[3].kind) {
        .format_write => |format_write| format_write,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(exprs.NodeId, 1), decoded_format.writer);
    try std.testing.expectEqualStrings("value={}\n", decoded_format.template);
    try std.testing.expectEqualSlices(exprs.NodeId, &.{2}, decoded_format.args);

    var malformed_expr_rows = expression_rows;
    malformed_expr_rows[3].kind = .{ .format_write = .{
        .writer = 99,
        .template = "value={}\n",
        .args = &.{2},
    } };
    var malformed_ir = fixture_ir;
    malformed_ir.bodies.exprs = &malformed_expr_rows;
    try std.testing.expectError(
        error.InvalidExprRef,
        root.validateForTranslation(&malformed_ir),
    );
}
