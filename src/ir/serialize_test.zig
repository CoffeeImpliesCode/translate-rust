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
        // No declared features and no `default-features` key, in a fixture
        // whose consuming crate forwards nothing: the one shape the frontend
        // may call certainly empty.
        .resolved_features_known_empty = true,
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
        // `default-features = false` already removed the defaults, so the
        // resolved set is not certainly empty even with no declared features.
        .resolved_features_known_empty = false,
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
        // A declared feature is on whatever anything forwards.
        .resolved_features_known_empty = false,
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
            .types = try allocator.dupe(types.Type, &.{.{ .array = array_type }}),
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

// ── Typed core calls ────────────────────────────────────────────────────────

const core_span: spine.Span = .{
    .start_line = 1,
    .start_col = 1,
    .end_line = 1,
    .end_col = 1,
};

/// `[N]u8`, the byte image both little-endian conversions carry. A fixed-width
/// integer spells its length as a literal; `usize`/`isize` name the target's
/// own `mem_size_of` expression instead, so a width only the compilation
/// target knows is never the translator host's.
fn coreByteImage(allocator: std.mem.Allocator, len: types.ArrayLen) !types.Type {
    return coreArrayOf(allocator, .{ .prim = .u8 }, len);
}

/// The `core_call` payload of `expr`, or the refusal to read one.
fn coreCallAt(expr: exprs.Expr) !exprs.CoreCall {
    return switch (expr.kind) {
        .core_call => |value| value,
        else => error.ExpectedCoreCallExpression,
    };
}

/// The child of the canonical semantic wrapper, not its erased backend layout.
fn maybeUninitChild(ty: types.Type) !types.Type {
    const wrapper = switch (ty) {
        .external_nominal => |value| value,
        else => return error.ExpectedMaybeUninitResultType,
    };
    try std.testing.expectEqual(@as(usize, 3), wrapper.path.len);
    try std.testing.expectEqualStrings("core", wrapper.path[0]);
    try std.testing.expectEqualStrings("mem", wrapper.path[1]);
    try std.testing.expectEqualStrings("MaybeUninit", wrapper.path[2]);
    try std.testing.expectEqual(@as(usize, 1), wrapper.args.len);
    return wrapper.args[0];
}

/// The body type table row an expression names.
fn bodyTypeAt(ir: serialize.RustIr, id: exprs.TypeId) !types.Type {
    if (@as(usize, id) >= ir.bodies.types.len) return error.InvalidTypeRef;
    return ir.bodies.types[id];
}

/// A private copy of `ir` whose expression table differs in exactly one row, so
/// every rejection case below names the node it rewrites.
fn withExprRow(
    allocator: std.mem.Allocator,
    ir: serialize.RustIr,
    index: usize,
    row: exprs.Expr,
) !serialize.RustIr {
    var malformed = ir;
    const rows = try allocator.dupe(exprs.Expr, ir.bodies.exprs);
    rows[index] = row;
    malformed.bodies.exprs = rows;
    return malformed;
}

/// Rewrite the first occurrence of `from`, refusing to continue when the text
/// is absent or appears twice. A wire edit that quietly did nothing would leave
/// the case asserting nothing at all.
fn replaceOnce(
    allocator: std.mem.Allocator,
    payload: []const u8,
    from: []const u8,
    to: []const u8,
) ![]u8 {
    const at = std.mem.indexOf(u8, payload, from) orelse return error.MissingWireFragment;
    if (std.mem.indexOf(u8, payload[at + from.len ..], from) != null) {
        return error.AmbiguousWireFragment;
    }
    const out = try allocator.alloc(u8, payload.len - from.len + to.len);
    @memcpy(out[0..at], payload[0..at]);
    @memcpy(out[at..][0..to.len], to);
    @memcpy(out[at + to.len ..], payload[at + from.len ..]);
    return out;
}

/// Decode `payload` and require the DECODER to refuse it. Wire admission is
/// strict: a core call whose arity or types disagree never becomes a loaded
/// graph. This is a precedence assertion — the malformed bytes are turned away
/// at the boundary rather than decoded and only then caught by the validator.
fn expectDecodedRefusal(payload: []const u8, expected: anyerror) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(expected, serialize.decode(allocator, payload));
}

/// One fixture carrying all five typed core operations with every operand and
/// result type the validator reads.
///
/// Entity ids: 0 root module, 1 the fixture fn, 2 the generator, 3 the hasher.
/// `initTestGraph` names items `item_<id>`, and the encoder requires a type
/// path segment to carry the entity's own name, so the receiver pointees are
/// spelled exactly that way.
///
/// Expression ids, in table order:
///   0 block (fn body)          1 `from_le_bytes`      2 its `[4]u8` bytes
///   3 `to_le_bytes`            4 its `u32` value       5 `maybe_uninit_uninit`
///   6 `fill_bytes_via_next`    7 its generator         8 its `[]u8` dest
///  12 `fill_bytes_via_next`   13 its `&mut [u8]` dest
///   9 `hash_write_primitive`  10 its hasher           11 its `u64` value
///  14 `[MaybeUninit::<u8>::uninit(); 4]` — the repeat that OWNS the length
///
/// Type-table rows:
///   0 `u32`      1 `[4]u8`    2 `u8`      3 `&mut item_2`
///   4 `[]u8`     5 `()`       6 `u64`     7 `&mut item_3`   8 `&mut [u8]`
///   9 `MaybeUninit<u8>`       10 `[MaybeUninit<u8>; 4]`
fn initTypedCoreCallIr(allocator: std.mem.Allocator) !serialize.RustIr {
    const crate_graph = try initTestGraph(
        allocator,
        "core_typed_fixture",
        &.{ .fn_, .field, .field },
    );
    const type_rows = try allocator.alloc(types.Type, 11);
    type_rows[0] = .{ .prim = .u32 };
    type_rows[1] = try coreByteImage(allocator, .{ .literal = 4 });
    type_rows[2] = .{ .prim = .u8 };
    type_rows[3] = .{ .reference = &.{
        .mut = true,
        .pointee = .{ .path = .{ .segments = &.{.{ .name = "item_2", .id = 2 }} } },
    } };
    type_rows[4] = .{ .slice = &.{ .const_ = false, .elem = .{ .prim = .u8 } } };
    type_rows[5] = .{ .prim = .unit };
    type_rows[6] = .{ .prim = .u64 };
    type_rows[7] = .{ .reference = &.{
        .mut = true,
        .pointee = .{ .path = .{ .segments = &.{.{ .name = "item_3", .id = 3 }} } },
    } };
    type_rows[8] = .{ .reference = &.{
        .mut = true,
        .pointee = .{ .slice = &.{ .const_ = false, .elem = .{ .prim = .u8 } } },
    } };
    type_rows[9] = .{ .external_nominal = .{
        .path = &.{ "core", "mem", "MaybeUninit" },
        .args = &.{.{ .prim = .u8 }},
    } };
    type_rows[10] = try coreArrayOf(allocator, type_rows[9], .{ .literal = 4 });
    const expression_table = try allocator.dupe(exprs.Expr, &.{
        .{
            .id = 0,
            .span = core_span,
            .ty = null,
            .kind = .{ .block = .{ .statements = &.{}, .tail = 1, .labelled = null } },
        },
        .{
            .id = 1,
            .span = core_span,
            .ty = 0,
            .kind = .{ .core_call = .{
                .function = .prim_from_le_bytes,
                .generic_args = &.{.{ .prim = .u32 }},
                .args = &.{2},
            } },
        },
        .{
            .id = 2,
            .span = core_span,
            .ty = 1,
            .kind = .{ .literal = .{ .byte_array = .{ .items = "abcd" } } },
        },
        .{
            .id = 3,
            .span = core_span,
            .ty = 1,
            .kind = .{ .core_call = .{
                .function = .prim_to_le_bytes,
                .generic_args = &.{.{ .prim = .u32 }},
                .args = &.{4},
            } },
        },
        .{
            .id = 4,
            .span = core_span,
            .ty = 0,
            .kind = .{ .literal = .{ .int = .{
                .text = "7",
                .value = 7,
                .base = .dec,
                .ty_suffix = "u32",
            } } },
        },
        .{
            .id = 5,
            .span = core_span,
            .ty = 9,
            .kind = .{ .core_call = .{
                .function = .maybe_uninit_uninit,
                .generic_args = &.{.{ .prim = .u8 }},
                .args = &.{},
            } },
        },
        .{
            .id = 6,
            .span = core_span,
            .ty = 5,
            .kind = .{ .core_call = .{
                .function = .rng_fill_bytes_via_next,
                .generic_args = &.{},
                .args = &.{ 7, 8 },
            } },
        },
        .{
            .id = 7,
            .span = core_span,
            .ty = 3,
            .kind = .{ .path = .{ .def = 2, .generic_args = &.{} } },
        },
        .{
            .id = 8,
            .span = core_span,
            .ty = 4,
            .kind = .{ .literal = .{ .byte_array = .{ .items = "wxyz" } } },
        },
        .{
            .id = 9,
            .span = core_span,
            .ty = 5,
            .kind = .{ .core_call = .{
                .function = .hash_write_primitive,
                .generic_args = &.{.{ .prim = .u64 }},
                .args = &.{ 10, 11 },
            } },
        },
        .{
            .id = 10,
            .span = core_span,
            .ty = 7,
            .kind = .{ .path = .{ .def = 3, .generic_args = &.{} } },
        },
        .{
            .id = 11,
            .span = core_span,
            .ty = 6,
            .kind = .{ .literal = .{ .int = .{
                .text = "5",
                .value = 5,
                .base = .dec,
                .ty_suffix = "u64",
            } } },
        },
        .{
            .id = 12,
            .span = core_span,
            .ty = 5,
            .kind = .{ .core_call = .{
                .function = .rng_fill_bytes_via_next,
                .generic_args = &.{},
                .args = &.{ 7, 13 },
            } },
        },
        .{
            .id = 13,
            .span = core_span,
            .ty = 8,
            .kind = .{ .literal = .{ .byte_array = .{ .items = "pqrs" } } },
        },
        .{
            .id = 14,
            .span = core_span,
            .ty = 10,
            .kind = .{ .array = .{ .elements = &.{5}, .repeat = 4 } },
        },
    });
    const body_table = try allocator.alloc(bodies.BodyKind, 4);
    body_table[0] = .none;
    body_table[1] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 0,
    } };
    body_table[2] = .none;
    body_table[3] = .none;
    return .{
        .crate_name = "core_typed_fixture",
        .edition = "2021",
        .graph = crate_graph,
        .types = &.{},
        .instantiations = &.{},
        .bodies = .{
            .exprs = expression_table,
            .stmts = &.{},
            .pats = &.{},
            .types = type_rows,
            .bodies = body_table,
        },
    };
}

test "core calls: five typed operations round-trip with their canonical tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ir = try initTypedCoreCallIr(allocator);

    const encoded = try serialize.encode(allocator, &ir);
    const canonical_tags = [_][]const u8{
        "\"function\":\"prim_from_le_bytes\"",
        "\"function\":\"prim_to_le_bytes\"",
        "\"function\":\"maybe_uninit_uninit\"",
        "\"function\":\"rng_fill_bytes_via_next\"",
        "\"function\":\"hash_write_primitive\"",
    };
    for (canonical_tags) |tag| {
        try std.testing.expect(std.mem.indexOf(u8, encoded, tag) != null);
    }

    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();
    try root.validateForTranslation(&decoded);

    const reencoded = try serialize.encode(allocator, &decoded);
    try std.testing.expectEqualStrings(encoded, reencoded);

    // The decode direction: `[4]u8` and a mutable `u8` dest both survived as
    // structured types rather than as opaque bytes.
    const decode_call = try coreCallAt(decoded.bodies.exprs[1]);
    try std.testing.expectEqual(exprs.CoreFunction.prim_from_le_bytes, decode_call.function);
    try std.testing.expectEqual(@as(usize, 1), decode_call.generic_args.len);
    try std.testing.expectEqual(@as(usize, 1), decode_call.args.len);
    switch (try bodyTypeAt(decoded, decoded.bodies.exprs[1].ty.?)) {
        .prim => |prim| try std.testing.expectEqual(types.Prim.u32, prim),
        else => return error.ExpectedIntegerResultType,
    }
    switch (try bodyTypeAt(decoded, decoded.bodies.exprs[2].ty.?)) {
        .array => |array| {
            try std.testing.expectEqual(@as(u64, 4), switch (array.len) {
                .literal => |literal| literal,
                else => return error.ExpectedLiteralByteImageLength,
            });
            switch (array.elem) {
                .prim => |prim| try std.testing.expectEqual(types.Prim.u8, prim),
                else => return error.ExpectedByteElementType,
            }
        },
        else => return error.ExpectedByteImageType,
    }

    const encode_call = try coreCallAt(decoded.bodies.exprs[3]);
    try std.testing.expectEqual(exprs.CoreFunction.prim_to_le_bytes, encode_call.function);
    switch (try bodyTypeAt(decoded, decoded.bodies.exprs[4].ty.?)) {
        .prim => |prim| try std.testing.expectEqual(types.Prim.u32, prim),
        else => return error.ExpectedIntegerValueType,
    }

    // `MaybeUninit::uninit()` names no value argument, and its own type is the
    // semantic MaybeUninit<u8> element — neither live u8 nor the repeated array.
    const uninit_call = try coreCallAt(decoded.bodies.exprs[5]);
    try std.testing.expectEqual(exprs.CoreFunction.maybe_uninit_uninit, uninit_call.function);
    try std.testing.expectEqual(@as(usize, 1), uninit_call.generic_args.len);
    try std.testing.expectEqual(types.Prim.u8, uninit_call.generic_args[0].prim);
    try std.testing.expectEqual(@as(usize, 0), uninit_call.args.len);
    switch (try maybeUninitChild(try bodyTypeAt(decoded, decoded.bodies.exprs[5].ty.?))) {
        .prim => |prim| try std.testing.expectEqual(types.Prim.u8, prim),
        else => return error.ExpectedElementResultType,
    }

    // `fill_bytes_via_next` names no generic argument: the receiver's own type
    // is the generator, and a mutable destination reaches it either directly
    // or behind the reference a `&mut [u8]` binding carries.
    const rng_call = try coreCallAt(decoded.bodies.exprs[6]);
    try std.testing.expectEqual(exprs.CoreFunction.rng_fill_bytes_via_next, rng_call.function);
    try std.testing.expectEqual(@as(usize, 0), rng_call.generic_args.len);
    try std.testing.expectEqual(@as(usize, 2), rng_call.args.len);
    const borrowed_dest = try coreCallAt(decoded.bodies.exprs[12]);
    try std.testing.expectEqual(@as(usize, 0), borrowed_dest.generic_args.len);
    switch (try bodyTypeAt(decoded, decoded.bodies.exprs[12].ty.?)) {
        .prim => |prim| try std.testing.expectEqual(types.Prim.unit, prim),
        else => return error.ExpectedUnitResultType,
    }

    const hash_call = try coreCallAt(decoded.bodies.exprs[9]);
    try std.testing.expectEqual(exprs.CoreFunction.hash_write_primitive, hash_call.function);
    try std.testing.expectEqual(@as(usize, 1), hash_call.generic_args.len);
    try std.testing.expectEqual(@as(usize, 2), hash_call.args.len);
    switch (try bodyTypeAt(decoded, decoded.bodies.exprs[11].ty.?)) {
        .prim => |prim| try std.testing.expectEqual(types.Prim.u64, prim),
        else => return error.ExpectedIntegerValueType,
    }
}

test "core calls: a wrong generic or value count is refused on both paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ir = try initTypedCoreCallIr(allocator);
    const encoded = try serialize.encode(allocator, &ir);

    // `MaybeUninit::uninit()` takes no value arguments; handing it one would
    // invent a value the source never passed.
    const model_arity = try withExprRow(allocator, ir, 5, .{
        .id = 5,
        .span = core_span,
        .ty = 9,
        .kind = .{ .core_call = .{
            .function = .maybe_uninit_uninit,
            .generic_args = &.{.{ .prim = .u8 }},
            .args = &.{2},
        } },
    });
    try std.testing.expectError(
        error.InvalidCoreCallArity,
        serialize.encode(allocator, &model_arity),
    );
    try std.testing.expectError(
        error.InvalidCoreCallArity,
        root.validateForTranslation(&model_arity),
    );

    // The same refusal read back off the wire, which proves the decoder turns
    // away an arity the encoder would never have written rather than quietly
    // repairing it into a graph.
    const wire_arity = try replaceOnce(
        allocator,
        encoded,
        "\"function\":\"maybe_uninit_uninit\",\"generic_args\":" ++
            "[{\"kind\":\"prim\",\"value\":\"u8\"}],\"args\":[]",
        "\"function\":\"maybe_uninit_uninit\",\"generic_args\":" ++
            "[{\"kind\":\"prim\",\"value\":\"u8\"}],\"args\":[2]",
    );
    try expectDecodedRefusal(wire_arity, error.InvalidCoreCallArity);

    // The owner type argument is required even though no value is constructed.
    // Neither an omitted argument nor two arguments may be repaired on load.
    const wrong_uninit_generics = [_]struct {
        generic_args: []const types.Type,
        wire: []const u8,
    }{
        .{ .generic_args = &.{}, .wire = "[]" },
        .{
            .generic_args = &.{ .{ .prim = .u8 }, .{ .prim = .u16 } },
            .wire = "[{\"kind\":\"prim\",\"value\":\"u8\"},{\"kind\":\"prim\",\"value\":\"u16\"}]",
        },
    };
    for (wrong_uninit_generics) |wrong| {
        var expression = ir.bodies.exprs[5];
        expression.kind.core_call.generic_args = wrong.generic_args;
        const malformed = try withExprRow(allocator, ir, 5, expression);
        try std.testing.expectError(
            error.InvalidCoreCallArity,
            serialize.encode(allocator, &malformed),
        );
        try std.testing.expectError(
            error.InvalidCoreCallArity,
            root.validateForTranslation(&malformed),
        );
        const replacement = try std.fmt.allocPrint(
            allocator,
            "\"function\":\"maybe_uninit_uninit\",\"generic_args\":{s},\"args\":[]",
            .{wrong.wire},
        );
        const malformed_wire = try replaceOnce(
            allocator,
            encoded,
            "\"function\":\"maybe_uninit_uninit\",\"generic_args\":" ++
                "[{\"kind\":\"prim\",\"value\":\"u8\"}],\"args\":[]",
            replacement,
        );
        try expectDecodedRefusal(malformed_wire, error.InvalidCoreCallArity);
    }

    // `fill_bytes_via_next` names the generator through its receiver, so a
    // generic argument is one too many even with the right value count.
    const model_generics = try withExprRow(allocator, ir, 6, .{
        .id = 6,
        .span = core_span,
        .ty = 5,
        .kind = .{ .core_call = .{
            .function = .rng_fill_bytes_via_next,
            .generic_args = &.{.{ .prim = .u64 }},
            .args = &.{ 7, 8 },
        } },
    });
    try std.testing.expectError(
        error.InvalidCoreCallArity,
        serialize.encode(allocator, &model_generics),
    );
    try std.testing.expectError(
        error.InvalidCoreCallArity,
        root.validateForTranslation(&model_generics),
    );
    // The same refusal off the wire: the value count is already right, and the
    // generic argument the encoder would never write is the whole defect.
    const wire_generics = try replaceOnce(
        allocator,
        encoded,
        "\"function\":\"rng_fill_bytes_via_next\",\"generic_args\":[],\"args\":[7,8]",
        "\"function\":\"rng_fill_bytes_via_next\",\"generic_args\":" ++
            "[{\"kind\":\"prim\",\"value\":\"u64\"}],\"args\":[7,8]",
    );
    try expectDecodedRefusal(wire_generics, error.InvalidCoreCallArity);
}

/// A private copy of `ir` whose body type table differs in exactly one row, so
/// a case that rejects a TYPE names the row it rewrote.
fn withTypeRow(
    allocator: std.mem.Allocator,
    ir: serialize.RustIr,
    index: usize,
    row: types.Type,
) !serialize.RustIr {
    var malformed = ir;
    const rows = try allocator.dupe(types.Type, ir.bodies.types);
    rows[index] = row;
    malformed.bodies.types = rows;
    return malformed;
}

/// Replace one indexed body type row without also changing its copy in an array.
fn withWireBodyTypeRow(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    index: usize,
    row_json: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    var row = try std.json.parseFromSlice(std.json.Value, allocator, row_json, .{});
    defer row.deinit();
    const body_section = parsed.value.object.getPtr("bodies") orelse return error.BadWireFormat;
    const type_section = body_section.object.getPtr("types") orelse return error.BadWireFormat;
    if (index >= type_section.array.items.len) return error.BadWireFormat;
    type_section.array.items[index] = row.value;
    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
}

/// Assert both wire boundaries refuse `ir` for the reason the typed core-call
/// contract names. The encoder and the translation validator share one rule, so
/// a model that cannot be written must not be loadable either.
fn expectCoreTypeRefused(allocator: std.mem.Allocator, ir: serialize.RustIr) !void {
    try std.testing.expectError(error.InvalidCoreCallType, serialize.encode(allocator, &ir));
    try std.testing.expectError(error.InvalidCoreCallType, root.validateForTranslation(&ir));
}

/// An array type node, the shape a byte image and a repeat's element both take.
fn coreArrayOf(allocator: std.mem.Allocator, elem: types.Type, len: types.ArrayLen) !types.Type {
    const array = try allocator.create(types.Array);
    array.* = .{ .elem = elem, .len = len };
    return .{ .array = array };
}

/// The pointer-width spelling of the little-endian pair, plus the symbolic form
/// a fixed-width integer is also allowed to use.
///
/// Entities: 0 root module, 1 the fixture fn, 2 the `usize` binding.
/// Expression ids, in table order:
///   0 block  1 `mem_size_of::<usize>`  2 `to_le_bytes::<usize>`  3 the value
///   4 `from_le_bytes::<usize>`  5 its bytes  6 `mem_size_of::<u32>`
///   7 `to_le_bytes::<u32>`     8 the `u32` value
///   9 `mem_size_of::<u32>` typed `usize` — the right SHAPE, the wrong integer
///
/// A `mem_size_of` call answers `usize` for whatever integer it measures, so
/// rows 6 and 9 are the same call; row 2 types the `u32` value instead.
///
/// Type rows: 0 `usize`  1 `[u8; mem_size_of::<usize>()]`  2 `u32`  3 `[u8; 8]`
///             4 `[u8; mem_size_of::<u32>()]`
fn initTargetWidthCoreCallIr(allocator: std.mem.Allocator) !serialize.RustIr {
    const crate_graph = try initTestGraph(allocator, "core_width_fixture", &.{ .fn_, .field });
    const type_rows = try allocator.alloc(types.Type, 5);
    type_rows[0] = .{ .prim = .usize };
    type_rows[1] = try coreByteImage(allocator, .{ .expression = 1 });
    // The `u32` value `to_le_bytes::<u32>` encodes, and the only row a value
    // expression is typed by.
    type_rows[2] = .{ .prim = .u32 };
    // Eight bytes is the width of `usize` on the compilation target, whatever
    // this translator host's own pointer size happens to be.
    type_rows[3] = try coreByteImage(allocator, .{ .literal = 8 });
    type_rows[4] = try coreByteImage(allocator, .{ .expression = 6 });
    const expression_table = try allocator.dupe(exprs.Expr, &.{
        .{
            .id = 0,
            .span = core_span,
            .ty = null,
            .kind = .{ .block = .{ .statements = &.{}, .tail = 1, .labelled = null } },
        },
        .{
            .id = 1,
            .span = core_span,
            .ty = 0,
            .kind = .{ .core_call = .{
                .function = .mem_size_of,
                .generic_args = &.{.{ .prim = .usize }},
                .args = &.{},
            } },
        },
        .{
            .id = 2,
            .span = core_span,
            .ty = 1,
            .kind = .{ .core_call = .{
                .function = .prim_to_le_bytes,
                .generic_args = &.{.{ .prim = .usize }},
                .args = &.{3},
            } },
        },
        .{
            .id = 3,
            .span = core_span,
            .ty = 0,
            .kind = .{ .path = .{ .def = 2, .generic_args = &.{} } },
        },
        .{
            .id = 4,
            .span = core_span,
            .ty = 0,
            .kind = .{ .core_call = .{
                .function = .prim_from_le_bytes,
                .generic_args = &.{.{ .prim = .usize }},
                .args = &.{5},
            } },
        },
        .{
            .id = 5,
            .span = core_span,
            .ty = 3,
            .kind = .{ .literal = .{ .byte_array = .{ .items = "abcdefgh" } } },
        },
        .{
            .id = 6,
            .span = core_span,
            .ty = 0,
            .kind = .{ .core_call = .{
                .function = .mem_size_of,
                .generic_args = &.{.{ .prim = .u32 }},
                .args = &.{},
            } },
        },
        .{
            .id = 7,
            .span = core_span,
            .ty = 4,
            .kind = .{ .core_call = .{
                .function = .prim_to_le_bytes,
                .generic_args = &.{.{ .prim = .u32 }},
                .args = &.{8},
            } },
        },
        .{
            .id = 8,
            .span = core_span,
            .ty = 2,
            .kind = .{ .literal = .{ .int = .{
                .text = "1",
                .value = 1,
                .base = .dec,
                .ty_suffix = "u32",
            } } },
        },
        .{
            .id = 9,
            .span = core_span,
            .ty = 0,
            .kind = .{ .core_call = .{
                .function = .mem_size_of,
                .generic_args = &.{.{ .prim = .u32 }},
                .args = &.{},
            } },
        },
    });
    const body_table = try allocator.alloc(bodies.BodyKind, 3);
    body_table[0] = .none;
    body_table[1] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 0,
    } };
    body_table[2] = .none;
    return .{
        .crate_name = "core_width_fixture",
        .edition = "2021",
        .graph = crate_graph,
        .types = &.{},
        .instantiations = &.{},
        .bodies = .{
            .exprs = expression_table,
            .stmts = &.{},
            .pats = &.{},
            .types = type_rows,
            .bodies = body_table,
        },
    };
}

test "core calls: a byte image may name the target's own width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ir = try initTargetWidthCoreCallIr(allocator);

    const encoded = try serialize.encode(allocator, &ir);
    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();
    try root.validateForTranslation(&decoded);
    try std.testing.expectEqualStrings(encoded, try serialize.encode(allocator, &decoded));

    // The encode direction: `usize` names its width through the target's own
    // `mem_size_of`, never through a number the host happened to have.
    switch (try bodyTypeAt(decoded, decoded.bodies.exprs[2].ty.?)) {
        .array => |array| switch (array.len) {
            .expression => |width| try std.testing.expectEqual(@as(u32, 1), width),
            else => return error.ExpectedSymbolicByteImageLength,
        },
        else => return error.ExpectedByteImageType,
    }
    const width_call = try coreCallAt(decoded.bodies.exprs[1]);
    try std.testing.expectEqual(exprs.CoreFunction.mem_size_of, width_call.function);
    try std.testing.expectEqual(@as(usize, 0), width_call.args.len);
    switch (try bodyTypeAt(decoded, decoded.bodies.exprs[1].ty.?)) {
        .prim => |prim| try std.testing.expectEqual(types.Prim.usize, prim),
        else => return error.ExpectedSizeResultType,
    }

    // A fixed-width integer may state its width the same symbolic way.
    switch (try bodyTypeAt(decoded, decoded.bodies.exprs[7].ty.?)) {
        .array => |array| switch (array.len) {
            .expression => |width| try std.testing.expectEqual(@as(u32, 6), width),
            else => return error.ExpectedSymbolicByteImageLength,
        },
        else => return error.ExpectedByteImageType,
    }
}

/// The width fixture carrying the one declaration a `.generic` array length
/// needs: `const N: usize`. `generic_params` carries TYPE parameters only, so
/// the const parameter belongs to the full `generics` list, and the block tail
/// moves to the `to_le_bytes` call so the owner walk reads the byte-image row
/// in the fn's own scope rather than through the crate-wide fallback.
fn withWidthConstGeneric(allocator: std.mem.Allocator, ir: serialize.RustIr) !serialize.RustIr {
    const body_rows = try allocator.dupe(bodies.BodyKind, ir.bodies.bodies);
    var fn_body = body_rows[1].fn_;
    fn_body.generics = .{
        .params = &.{.{ .const_ = .{ .name = "N", .ty = .{ .prim = .usize } } }},
        .where_clauses = &.{},
    };
    body_rows[1] = .{ .fn_ = fn_body };
    var declared = ir;
    declared.bodies.bodies = body_rows;
    return withExprRow(allocator, declared, 0, .{
        .id = 0,
        .span = core_span,
        .ty = null,
        .kind = .{ .block = .{ .statements = &.{}, .tail = 2, .labelled = null } },
    });
}

test "core calls: a byte image width that names something else is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ir = try initTargetWidthCoreCallIr(allocator);

    // A symbolic width with the right SHAPE that measures a DIFFERENT integer
    // sizes the wrong image.
    try expectCoreTypeRefused(
        allocator,
        try withTypeRow(allocator, ir, 1, try coreByteImage(allocator, .{ .expression = 9 })),
    );
    // A symbolic width that is not a `mem_size_of` at all answers nothing about
    // this integer.
    try expectCoreTypeRefused(
        allocator,
        try withTypeRow(allocator, ir, 1, try coreByteImage(allocator, .{ .expression = 3 })),
    );
    // A symbolic width typed something other than `usize` is not a byte count:
    // the right `mem_size_of::<usize>` shape and arity, answering `u32`. The
    // byte-image row already names expression 1, so only the result type moves.
    try expectCoreTypeRefused(allocator, try withExprRow(allocator, ir, 1, .{
        .id = 1,
        .span = core_span,
        .ty = 2,
        .kind = .{ .core_call = .{
            .function = .mem_size_of,
            .generic_args = &.{.{ .prim = .usize }},
            .args = &.{},
        } },
    }));
    // A width that measures `usize` while the call encodes `u32` is the right
    // measurement of the wrong integer.
    try expectCoreTypeRefused(
        allocator,
        try withTypeRow(allocator, ir, 4, try coreByteImage(allocator, .{ .expression = 1 })),
    );
    // A literal width that contradicts a fixed-width integer is a different
    // array, not the same integer's bytes.
    try expectCoreTypeRefused(
        allocator,
        try withTypeRow(allocator, ir, 4, try coreByteImage(allocator, .{ .literal = 8 })),
    );
    // A byte image holds bytes.
    try expectCoreTypeRefused(
        allocator,
        try withTypeRow(
            allocator,
            ir,
            1,
            try coreArrayOf(allocator, .{ .prim = .u32 }, .{ .literal = 8 }),
        ),
    );
    // A generic parameter is a compile-time length, not this integer's width.
    // The declaration below binds `N`, so a `.generic` row is well-formed
    // metadata rather than an incomplete one — which the control proves before
    // the row itself is rewritten, leaving the width rule as the only refusal.
    const declared = try withWidthConstGeneric(allocator, ir);
    const declared_encoded = try serialize.encode(allocator, &declared);
    var declared_decoded = try serialize.decode(allocator, declared_encoded);
    defer declared_decoded.graph.deinit();
    try root.validateForTranslation(&declared_decoded);
    try expectCoreTypeRefused(
        allocator,
        try withTypeRow(allocator, declared, 1, try coreByteImage(allocator, .{ .generic = 0 })),
    );
}

test "core calls: an operand, result, or receiver the tag does not admit is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ir = try initTypedCoreCallIr(allocator);

    // A decode that produces something other than the integer it names.
    try expectCoreTypeRefused(allocator, try withExprRow(allocator, ir, 1, .{
        .id = 1,
        .span = core_span,
        .ty = 6,
        .kind = .{ .core_call = .{
            .function = .prim_from_le_bytes,
            .generic_args = &.{.{ .prim = .u32 }},
            .args = &.{2},
        } },
    }));
    // A decode whose bytes are not a byte image.
    try expectCoreTypeRefused(allocator, try withExprRow(allocator, ir, 2, .{
        .id = 2,
        .span = core_span,
        .ty = 0,
        .kind = .{ .literal = .{ .byte_array = .{ .items = "abcd" } } },
    }));
    // An encode whose value is not the integer it names.
    try expectCoreTypeRefused(allocator, try withExprRow(allocator, ir, 4, .{
        .id = 4,
        .span = core_span,
        .ty = 6,
        .kind = .{ .literal = .{ .int = .{
            .text = "7",
            .value = 7,
            .base = .dec,
            .ty_suffix = "u32",
        } } },
    }));
    // An encode whose result is not a byte image.
    try expectCoreTypeRefused(allocator, try withExprRow(allocator, ir, 3, .{
        .id = 3,
        .span = core_span,
        .ty = 2,
        .kind = .{ .core_call = .{
            .function = .prim_to_le_bytes,
            .generic_args = &.{.{ .prim = .u32 }},
            .args = &.{4},
        } },
    }));
    // An uninit call whose own type is not the canonical wrapper it names.
    try expectCoreTypeRefused(allocator, try withExprRow(allocator, ir, 5, .{
        .id = 5,
        .span = core_span,
        .ty = 0,
        .kind = .{ .core_call = .{
            .function = .maybe_uninit_uninit,
            .generic_args = &.{.{ .prim = .u8 }},
            .args = &.{},
        } },
    }));
    // An unattributed call has no result type to check the contract against.
    try expectCoreTypeRefused(allocator, try withExprRow(allocator, ir, 5, .{
        .id = 5,
        .span = core_span,
        .ty = null,
        .kind = .{ .core_call = .{
            .function = .maybe_uninit_uninit,
            .generic_args = &.{.{ .prim = .u8 }},
            .args = &.{},
        } },
    }));
    // A LE pair over something with no byte image at all.
    try expectCoreTypeRefused(allocator, try withExprRow(allocator, ir, 3, .{
        .id = 3,
        .span = core_span,
        .ty = 1,
        .kind = .{ .core_call = .{
            .function = .prim_to_le_bytes,
            .generic_args = &.{.{ .prim = .f64 }},
            .args = &.{4},
        } },
    }));

    // `fill_bytes_via_next` takes the receiver by the borrow `fill_bytes` makes.
    try expectCoreTypeRefused(
        allocator,
        try withTypeRow(allocator, ir, 3, .{ .reference = &.{
            .mut = false,
            .pointee = .{ .path = .{ .segments = &.{.{ .name = "item_2", .id = 2 }} } },
        } }),
    );
    try expectCoreTypeRefused(
        allocator,
        try withTypeRow(allocator, ir, 3, .{ .prim = .u8 }),
    );
    // A destination the call cannot fill.
    try expectCoreTypeRefused(
        allocator,
        try withTypeRow(allocator, ir, 4, .{ .slice = &.{
            .const_ = true,
            .elem = .{ .prim = .u8 },
        } }),
    );
    try expectCoreTypeRefused(
        allocator,
        try withTypeRow(allocator, ir, 4, .{ .slice = &.{
            .const_ = false,
            .elem = .{ .prim = .u32 },
        } }),
    );
    // A default body that hands something back.
    try expectCoreTypeRefused(allocator, try withExprRow(allocator, ir, 6, .{
        .id = 6,
        .span = core_span,
        .ty = 0,
        .kind = .{ .core_call = .{
            .function = .rng_fill_bytes_via_next,
            .generic_args = &.{},
            .args = &.{ 7, 8 },
        } },
    }));

    // The `Hasher` writers share the receiver and unit rules.
    try expectCoreTypeRefused(
        allocator,
        try withTypeRow(allocator, ir, 7, .{ .reference = &.{
            .mut = false,
            .pointee = .{ .path = .{ .segments = &.{.{ .name = "item_3", .id = 3 }} } },
        } }),
    );
    // A value that is not the primitive the writer names.
    try expectCoreTypeRefused(allocator, try withExprRow(allocator, ir, 11, .{
        .id = 11,
        .span = core_span,
        .ty = 0,
        .kind = .{ .literal = .{ .int = .{
            .text = "5",
            .value = 5,
            .base = .dec,
            .ty_suffix = "u32",
        } } },
    }));
    try expectCoreTypeRefused(allocator, try withExprRow(allocator, ir, 9, .{
        .id = 9,
        .span = core_span,
        .ty = 0,
        .kind = .{ .core_call = .{
            .function = .hash_write_primitive,
            .generic_args = &.{.{ .prim = .u64 }},
            .args = &.{ 10, 11 },
        } },
    }));

    // The same refusal read back off the wire.
    const encoded = try serialize.encode(allocator, &ir);
    const wire_generic = try replaceOnce(
        allocator,
        encoded,
        "\"function\":\"prim_to_le_bytes\",\"generic_args\":" ++
            "[{\"kind\":\"prim\",\"value\":\"u32\"}]",
        "\"function\":\"prim_to_le_bytes\",\"generic_args\":" ++
            "[{\"kind\":\"prim\",\"value\":\"f64\"}]",
    );
    try expectDecodedRefusal(wire_generic, error.InvalidCoreCallType);
}

test "core calls: an uninit result that is not the canonical wrapper is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ir = try initTypedCoreCallIr(allocator);
    const encoded = try serialize.encode(allocator, &ir);
    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();
    try root.validateForTranslation(&decoded);
    try std.testing.expectEqualStrings(encoded, try serialize.encode(allocator, &decoded));

    // Supported roots and primitive children keep these cases focused on the
    // core-call contract, not unsupported roots or undeclared generic paths.
    const wrong_results = [_]struct {
        ty: types.Type,
        wire: []const u8,
    }{
        // The old erased result is no longer a semantic result type.
        .{
            .ty = .{ .prim = .u8 },
            .wire = "{\"kind\":\"prim\",\"value\":\"u8\"}",
        },
        .{
            .ty = .{ .external_nominal = .{
                .path = &.{ "std", "mem", "MaybeUninit" },
                .args = &.{.{ .prim = .u8 }},
            } },
            .wire = "{\"kind\":\"external_nominal\",\"value\":{\"path\":[\"std\",\"mem\",\"MaybeUninit\"],\"args\":[{\"kind\":\"prim\",\"value\":\"u8\"}]}}",
        },
        .{
            .ty = .{ .external_nominal = .{
                .path = &.{ "core", "cell", "MaybeUninit" },
                .args = &.{.{ .prim = .u8 }},
            } },
            .wire = "{\"kind\":\"external_nominal\",\"value\":{\"path\":[\"core\",\"cell\",\"MaybeUninit\"],\"args\":[{\"kind\":\"prim\",\"value\":\"u8\"}]}}",
        },
        .{
            .ty = .{ .external_nominal = .{
                .path = &.{ "core", "mem", "ManuallyDrop" },
                .args = &.{.{ .prim = .u8 }},
            } },
            .wire = "{\"kind\":\"external_nominal\",\"value\":{\"path\":[\"core\",\"mem\",\"ManuallyDrop\"],\"args\":[{\"kind\":\"prim\",\"value\":\"u8\"}]}}",
        },
        .{
            .ty = .{ .external_nominal = .{
                .path = &.{ "core", "MaybeUninit" },
                .args = &.{.{ .prim = .u8 }},
            } },
            .wire = "{\"kind\":\"external_nominal\",\"value\":{\"path\":[\"core\",\"MaybeUninit\"],\"args\":[{\"kind\":\"prim\",\"value\":\"u8\"}]}}",
        },
        .{
            .ty = .{ .external_nominal = .{
                .path = &.{ "core", "mem", "MaybeUninit", "Assoc" },
                .args = &.{.{ .prim = .u8 }},
            } },
            .wire = "{\"kind\":\"external_nominal\",\"value\":{\"path\":[\"core\",\"mem\",\"MaybeUninit\",\"Assoc\"],\"args\":[{\"kind\":\"prim\",\"value\":\"u8\"}]}}",
        },
        .{
            .ty = .{ .external_nominal = .{
                .path = &.{ "core", "mem", "MaybeUninit" },
                .args = &.{.{ .prim = .u32 }},
            } },
            .wire = "{\"kind\":\"external_nominal\",\"value\":{\"path\":[\"core\",\"mem\",\"MaybeUninit\"],\"args\":[{\"kind\":\"prim\",\"value\":\"u32\"}]}}",
        },
        .{
            .ty = .{ .external_nominal = .{
                .path = &.{ "core", "mem", "MaybeUninit" },
                .args = &.{},
            } },
            .wire = "{\"kind\":\"external_nominal\",\"value\":{\"path\":[\"core\",\"mem\",\"MaybeUninit\"],\"args\":[]}}",
        },
        .{
            .ty = .{ .external_nominal = .{
                .path = &.{ "core", "mem", "MaybeUninit" },
                .args = &.{ .{ .prim = .u8 }, .{ .prim = .u8 } },
            } },
            .wire = "{\"kind\":\"external_nominal\",\"value\":{\"path\":[\"core\",\"mem\",\"MaybeUninit\"],\"args\":[{\"kind\":\"prim\",\"value\":\"u8\"},{\"kind\":\"prim\",\"value\":\"u8\"}]}}",
        },
    };
    for (wrong_results) |wrong| {
        try expectCoreTypeRefused(allocator, try withTypeRow(allocator, ir, 9, wrong.ty));
        try expectDecodedRefusal(
            try withWireBodyTypeRow(allocator, encoded, 9, wrong.wire),
            error.InvalidCoreCallType,
        );
    }
}

test "core calls: a repeat of an uninit call keeps the element and the length apart" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ir = try initTypedCoreCallIr(allocator);

    const encoded = try serialize.encode(allocator, &ir);
    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();
    try root.validateForTranslation(&decoded);
    try std.testing.expectEqualStrings(encoded, try serialize.encode(allocator, &decoded));

    const repeat = switch (decoded.bodies.exprs[14].kind) {
        .array => |value| value,
        else => return error.ExpectedArrayExpression,
    };
    // Rust evaluates `MaybeUninit::<u8>::uninit()` ONCE and repeats the value.
    // One element node plus a repeat count is how the wire says so; an array
    // whose own type were the element's would re-run the evaluation.
    try std.testing.expectEqual(@as(usize, 1), repeat.elements.len);
    try std.testing.expectEqual(@as(exprs.NodeId, 5), repeat.elements[0]);
    try std.testing.expectEqual(@as(?u64, 4), repeat.repeat);

    // Only the array owns the count; its element is the semantic wrapper.
    switch (try bodyTypeAt(decoded, decoded.bodies.exprs[14].ty.?)) {
        .array => |array| {
            switch (array.len) {
                .literal => |literal| try std.testing.expectEqual(@as(u64, 4), literal),
                else => return error.ExpectedLiteralArrayLength,
            }
            switch (try maybeUninitChild(array.elem)) {
                .prim => |prim| try std.testing.expectEqual(types.Prim.u8, prim),
                else => return error.ExpectedElementResultType,
            }
        },
        else => return error.ExpectedArrayType,
    }
    const uninit = try coreCallAt(decoded.bodies.exprs[5]);
    try std.testing.expectEqual(exprs.CoreFunction.maybe_uninit_uninit, uninit.function);
    try std.testing.expectEqual(@as(usize, 1), uninit.generic_args.len);
    try std.testing.expectEqual(types.Prim.u8, uninit.generic_args[0].prim);
    try std.testing.expectEqual(@as(usize, 0), uninit.args.len);
    switch (try maybeUninitChild(try bodyTypeAt(decoded, decoded.bodies.exprs[5].ty.?))) {
        .prim => |prim| try std.testing.expectEqual(types.Prim.u8, prim),
        else => return error.ExpectedElementResultType,
    }
}

test "core calls: an uninit result over a declared generic keeps one child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ir = try initTypedCoreCallIr(allocator);
    const declared: types.Type = .{ .path = .{ .segments = &.{.{ .name = "T", .id = null }} } };
    const generic_arguments = try allocator.dupe(types.Type, &.{declared});
    const wrapper: types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "mem", "MaybeUninit" },
        .args = generic_arguments,
    } };
    const type_rows = try allocator.dupe(types.Type, ir.bodies.types);
    type_rows[9] = wrapper;
    type_rows[10] = try coreArrayOf(allocator, wrapper, .{ .literal = 4 });
    ir.bodies.types = type_rows;

    // Reach the call through the repeated array in this function's own scope.
    const expression_rows = try allocator.dupe(exprs.Expr, ir.bodies.exprs);
    expression_rows[0].kind.block.tail = 14;
    expression_rows[5].kind.core_call.generic_args = generic_arguments;
    ir.bodies.exprs = expression_rows;
    const body_rows = try allocator.dupe(bodies.BodyKind, ir.bodies.bodies);
    body_rows[1].fn_.generic_params = &.{"T"};
    ir.bodies.bodies = body_rows;

    const encoded = try serialize.encode(allocator, &ir);
    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();
    try root.validateForTranslation(&decoded);
    try std.testing.expectEqualStrings(encoded, try serialize.encode(allocator, &decoded));
    try std.testing.expectEqual(@as(usize, 1), decoded.bodies.bodies[1].fn_.generic_params.len);
    try std.testing.expectEqualStrings("T", decoded.bodies.bodies[1].fn_.generic_params[0]);

    const call = try coreCallAt(decoded.bodies.exprs[5]);
    try std.testing.expectEqual(exprs.CoreFunction.maybe_uninit_uninit, call.function);
    try std.testing.expectEqual(@as(usize, 1), call.generic_args.len);
    try std.testing.expectEqual(@as(usize, 0), call.args.len);
    const repeat = switch (decoded.bodies.exprs[14].kind) {
        .array => |value| value,
        else => return error.ExpectedArrayExpression,
    };
    try std.testing.expectEqual(@as(usize, 1), repeat.elements.len);
    try std.testing.expectEqual(@as(exprs.NodeId, 5), repeat.elements[0]);
    try std.testing.expectEqual(@as(?u64, 4), repeat.repeat);
    const array = switch (try bodyTypeAt(decoded, decoded.bodies.exprs[14].ty.?)) {
        .array => |value| value,
        else => return error.ExpectedArrayType,
    };
    switch (array.len) {
        .literal => |length| try std.testing.expectEqual(@as(u64, 4), length),
        else => return error.ExpectedLiteralArrayLength,
    }
    const declared_children = [_]types.Type{
        call.generic_args[0],
        try maybeUninitChild(try bodyTypeAt(decoded, decoded.bodies.exprs[5].ty.?)),
        try maybeUninitChild(array.elem),
    };
    for (declared_children) |child| {
        switch (child) {
            .path => |path| {
                try std.testing.expectEqual(@as(usize, 1), path.segments.len);
                try std.testing.expectEqualStrings("T", path.segments[0].name);
                try std.testing.expect(path.segments[0].id == null);
            },
            else => return error.ExpectedDeclaredGenericChildType,
        }
    }
}

/// One call whose function VALUE carries `generic_args` verbatim, so a generic
/// count or element the rules refuse can be spelled exactly. Both boundaries
/// decide the generic contract from this single node.
fn initCoreFunctionValueIr(
    allocator: std.mem.Allocator,
    function: exprs.CoreFunction,
    generic_args: []const types.Type,
) !serialize.RustIr {
    const crate_graph = try initTestGraph(allocator, "core_function_fixture", &.{.fn_});
    const expression_table = try allocator.dupe(exprs.Expr, &.{
        .{
            .id = 0,
            .span = core_span,
            .ty = null,
            .kind = .{ .block = .{ .statements = &.{}, .tail = 1, .labelled = null } },
        },
        .{
            .id = 1,
            .span = core_span,
            .ty = null,
            .kind = .{ .core_function = .{
                .function = function,
                .generic_args = generic_args,
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
        .crate_name = "core_function_fixture",
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

/// The `num_traits` bounds and constants: one type argument, no value arguments,
/// and a result of that same type. `generic_params` lets a case name a declared
/// type parameter instead of an integer primitive.
fn initNumericCoreCallIr(
    allocator: std.mem.Allocator,
    function: exprs.CoreFunction,
    generic_arg: types.Type,
    result_ty: types.Type,
    generic_params: []const []const u8,
) !serialize.RustIr {
    const crate_graph = try initTestGraph(allocator, "core_numeric_fixture", &.{.fn_});
    const type_rows = try allocator.alloc(types.Type, 1);
    type_rows[0] = result_ty;
    // The expression table is arena-owned and read long after this helper
    // returns, so the argument slice has to outlive this frame too.
    const generic_arguments = try allocator.dupe(types.Type, &.{generic_arg});
    const expression_table = try allocator.dupe(exprs.Expr, &.{
        .{
            .id = 0,
            .span = core_span,
            .ty = null,
            .kind = .{ .block = .{ .statements = &.{}, .tail = 1, .labelled = null } },
        },
        .{
            .id = 1,
            .span = core_span,
            .ty = 0,
            .kind = .{ .core_call = .{
                .function = function,
                .generic_args = generic_arguments,
                .args = &.{},
            } },
        },
    });
    const body_table = try allocator.alloc(bodies.BodyKind, 2);
    body_table[0] = .none;
    body_table[1] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .generic_params = generic_params,
        .body = 0,
    } };
    return .{
        .crate_name = "core_numeric_fixture",
        .edition = "2021",
        .graph = crate_graph,
        .types = &.{},
        .instantiations = &.{},
        .bodies = .{
            .exprs = expression_table,
            .stmts = &.{},
            .pats = &.{},
            .types = type_rows,
            .bodies = body_table,
        },
    };
}

/// The bound and constant tags, in the order the enum declares them.
const numeric_core_functions = [_]exprs.CoreFunction{
    .numeric_min_value,
    .numeric_max_value,
    .numeric_zero,
    .numeric_one,
};

/// The tags whose single type argument must be an integer primitive.
const integer_core_writers = [_]exprs.CoreFunction{
    .prim_from_le_bytes,
    .prim_to_le_bytes,
    .hash_write_primitive,
};

test "core calls: the numeric bound tags round-trip over an integer" {
    for (numeric_core_functions) |function| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const ir = try initNumericCoreCallIr(
            allocator,
            function,
            .{ .prim = .i64 },
            .{ .prim = .i64 },
            &.{},
        );

        const encoded = try serialize.encode(allocator, &ir);
        const tag = try std.fmt.allocPrint(
            allocator,
            "\"function\":\"{s}\"",
            .{@tagName(function)},
        );
        try std.testing.expect(std.mem.indexOf(u8, encoded, tag) != null);

        var decoded = try serialize.decode(allocator, encoded);
        defer decoded.graph.deinit();
        try root.validateForTranslation(&decoded);
        try std.testing.expectEqualStrings(encoded, try serialize.encode(allocator, &decoded));

        const call = try coreCallAt(decoded.bodies.exprs[1]);
        try std.testing.expectEqual(function, call.function);
        try std.testing.expectEqual(@as(usize, 1), call.generic_args.len);
        // A bound or a constant names no value argument: `T::MIN_VALUE` and
        // `T::zero()` are path functions, not calls taking arguments.
        try std.testing.expectEqual(@as(usize, 0), call.args.len);
        switch (try bodyTypeAt(decoded, decoded.bodies.exprs[1].ty.?)) {
            .prim => |prim| try std.testing.expectEqual(types.Prim.i64, prim),
            else => return error.ExpectedNumericResultType,
        }
    }
}

test "core calls: a numeric bound accepts a declared generic and refuses a mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A declared type parameter is a concrete numeric type at this call site,
    // and the contextual type validator is what resolves it — never an
    // unattributed fallback.
    const declared: types.Type = .{ .path = .{ .segments = &.{.{ .name = "I", .id = null }} } };
    const declared_ir = try initNumericCoreCallIr(
        allocator,
        .numeric_zero,
        declared,
        declared,
        &.{"I"},
    );
    const declared_encoded = try serialize.encode(allocator, &declared_ir);
    var declared_decoded = try serialize.decode(allocator, declared_encoded);
    defer declared_decoded.graph.deinit();
    try root.validateForTranslation(&declared_decoded);
    try std.testing.expectEqualStrings(
        declared_encoded,
        try serialize.encode(allocator, &declared_decoded),
    );

    // A result that is not the type the tag names.
    const mismatched = try initNumericCoreCallIr(
        allocator,
        .numeric_max_value,
        .{ .prim = .u64 },
        .{ .prim = .u32 },
        &.{},
    );
    try expectCoreTypeRefused(allocator, mismatched);

    // A type with no numeric reading at all: a float never has a Rust integer
    // bound, so the tag cannot stand in for one.
    for ([_]types.Prim{ .f32, .f64, .bool, .char, .unit }) |primitive| {
        const floating = try initNumericCoreCallIr(
            allocator,
            .numeric_one,
            .{ .prim = primitive },
            .{ .prim = primitive },
            &.{},
        );
        try expectCoreTypeRefused(allocator, floating);
        const value = try initCoreFunctionValueIr(
            allocator,
            .numeric_min_value,
            &.{.{ .prim = primitive }},
        );
        try std.testing.expectError(
            error.InvalidCoreFunctionType,
            serialize.encode(allocator, &value),
        );
        try std.testing.expectError(
            error.InvalidCoreFunctionType,
            root.validateForTranslation(&value),
        );
    }

    // The same refusal read back off the wire.
    const encoded = try serialize.encode(allocator, &declared_ir);
    const wire_numeric = try replaceOnce(
        allocator,
        encoded,
        "\"function\":\"numeric_zero\",\"generic_args\":[" ++
            "{\"kind\":\"path\",\"value\":{\"segments\":[" ++
            "{\"name\":\"I\",\"id\":null}]}}]",
        "\"function\":\"numeric_zero\",\"generic_args\":[" ++
            "{\"kind\":\"prim\",\"value\":\"f64\"}]",
    );
    try expectDecodedRefusal(wire_numeric, error.InvalidCoreCallType);
}

test "core function values: the LE and hash writers name one integer" {
    for (integer_core_writers) |function| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const ir = try initCoreFunctionValueIr(allocator, function, &.{.{ .prim = .i32 }});

        const encoded = try serialize.encode(allocator, &ir);
        var decoded = try serialize.decode(allocator, encoded);
        defer decoded.graph.deinit();
        try root.validateForTranslation(&decoded);
        try std.testing.expectEqualStrings(encoded, try serialize.encode(allocator, &decoded));
        switch (decoded.bodies.exprs[1].kind) {
            .core_function => |value| try std.testing.expectEqual(function, value.function),
            else => return error.ExpectedCoreFunctionExpression,
        }
    }
}

test "core function values: a non-integer generic has no byte image or written value" {
    const rejected = [_]types.Prim{ .f32, .f64, .bool, .char, .unit, .never };
    for (integer_core_writers) |function| {
        for (rejected) |primitive| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            const ir = try initCoreFunctionValueIr(allocator, function, &.{.{ .prim = primitive }});
            try std.testing.expectError(
                error.InvalidCoreFunctionType,
                serialize.encode(allocator, &ir),
            );
            try std.testing.expectError(
                error.InvalidCoreFunctionType,
                root.validateForTranslation(&ir),
            );
        }
    }
}

test "core function values: a generic count the tag does not declare is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const wrong_counts = [_]struct {
        function: exprs.CoreFunction,
        generic_args: []const types.Type,
    }{
        // One integer, no more and no fewer.
        .{ .function = .prim_from_le_bytes, .generic_args = &.{} },
        .{ .function = .prim_to_le_bytes, .generic_args = &.{} },
        .{
            .function = .prim_from_le_bytes,
            .generic_args = &.{ .{ .prim = .u32 }, .{ .prim = .u8 } },
        },
        .{ .function = .hash_write_primitive, .generic_args = &.{} },
        // The generator is the receiver's own type, so there is nothing for a
        // generic argument to name.
        .{ .function = .rng_fill_bytes_via_next, .generic_args = &.{.{ .prim = .u64 }} },
        .{ .function = .maybe_uninit_uninit, .generic_args = &.{} },
        .{ .function = .numeric_min_value, .generic_args = &.{} },
        .{ .function = .numeric_max_value, .generic_args = &.{} },
        .{ .function = .numeric_zero, .generic_args = &.{} },
        .{ .function = .numeric_one, .generic_args = &.{} },
        .{
            .function = .numeric_zero,
            .generic_args = &.{ .{ .prim = .u32 }, .{ .prim = .u8 } },
        },
    };
    for (wrong_counts) |wrong| {
        const ir = try initCoreFunctionValueIr(allocator, wrong.function, wrong.generic_args);
        try std.testing.expectError(
            error.InvalidCoreFunctionArity,
            serialize.encode(allocator, &ir),
        );
        try std.testing.expectError(
            error.InvalidCoreFunctionArity,
            root.validateForTranslation(&ir),
        );
    }
}

test "core calls: an unattributed `_` generic is incomplete metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ir = try initTypedCoreCallIr(allocator);

    // A single-segment `_` is the type table's placeholder for a Rust `_`:
    // inference rewrites it in place once the constraints name a concrete type.
    // It is not an unsupported external root, and the row exists while its
    // element does not.
    const placeholder: types.Type = .{ .external_nominal = .{ .path = &.{"_"} } };
    const call = try withExprRow(allocator, ir, 3, .{
        .id = 3,
        .span = core_span,
        .ty = 1,
        .kind = .{ .core_call = .{
            .function = .prim_to_le_bytes,
            .generic_args = &.{placeholder},
            .args = &.{4},
        } },
    });
    try std.testing.expectError(
        error.IncompleteGenericMetadata,
        serialize.encode(allocator, &call),
    );
    try std.testing.expectError(
        error.IncompleteGenericMetadata,
        root.validateForTranslation(&call),
    );

    // The placeholder is caught while the generic argument is attributed, which
    // is why it never reads as a type the writer could not name.
    const value = try initCoreFunctionValueIr(
        allocator,
        .hash_write_primitive,
        &.{placeholder},
    );
    try std.testing.expectError(
        error.IncompleteGenericMetadata,
        serialize.encode(allocator, &value),
    );
    try std.testing.expectError(
        error.IncompleteGenericMetadata,
        root.validateForTranslation(&value),
    );
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

    // The frontend's answer about this build's resolved feature set is written
    // as a plain boolean on every dependency: `nullable` is the one shape that
    // may be called certainly empty, the other two may not.
    try std.testing.expect(deps[0].object.get("resolved_features_known_empty").?.bool);
    try std.testing.expect(!deps[1].object.get("resolved_features_known_empty").?.bool);
    try std.testing.expect(!deps[2].object.get("resolved_features_known_empty").?.bool);
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

test "serialize: a dependency's resolved-empty fact round-trips and an absent key is false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // This payload predates the key, and a wire that cannot answer the
    // question must not be read as answering it. Absence is "not known to be
    // empty", which is the value the field's own default gives — never the
    // stronger claim a reader might otherwise invent for a missing key.
    {
        const absent = try allocator.dupe(u8, canonical_dependency_payload);
        var decoded = try serialize.decode(allocator, absent);
        defer decoded.graph.deinit();
        for (decoded.graph.crates.items[0].deps) |dependency| {
            try std.testing.expect(!dependency.resolved_features_known_empty);
        }
    }

    // With the key present the answer is the frontend's, and it survives both
    // directions of the wire rather than being re-guessed on the way through.
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        canonical_dependency_payload,
        .{},
    );
    defer parsed.deinit();
    const crates = parsed.value.object.getPtr("crates") orelse return error.BadWireFormat;
    const deps = crates.array.items[0].object.getPtr("deps") orelse return error.BadWireFormat;
    try deps.array.items[0].object.put(allocator, "resolved_features_known_empty", .{
        .bool = true,
    });
    const payload = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});

    var decoded = try serialize.decode(allocator, payload);
    defer decoded.graph.deinit();
    try std.testing.expect(decoded.graph.crates.items[0].deps[0].resolved_features_known_empty);
    try std.testing.expect(!decoded.graph.crates.items[0].deps[1].resolved_features_known_empty);

    const encoded = try serialize.encode(allocator, &decoded);
    var roundtripped = try serialize.decode(allocator, encoded);
    defer roundtripped.graph.deinit();
    try std.testing.expect(roundtripped.graph.crates.items[0].deps[0].resolved_features_known_empty);
    try std.testing.expect(!roundtripped.graph.crates.items[0].deps[1].resolved_features_known_empty);
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
    try std.testing.expectEqual(@as(?exprs.VecRepeatCount, null), decoded_vec.repeat);
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
                .repeat = .{ .literal = 13 },
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
    try std.testing.expectEqual(
        @as(?exprs.VecRepeatCount, .{ .literal = 13 }),
        decoded_vec.repeat,
    );
}

/// A `vec![e; n]` whose count the target evaluates: the repeated value, the
/// node that produces the count, and the literal that joins them.
///
/// `count_type` is what the count node is typed as — null leaves it
/// unattributed, which is its own refusal — and `count_id` is the node it
/// names, so a fixture can point the count at a row that is not there.
fn initVecRepeatCountIr(
    allocator: std.mem.Allocator,
    count_type: ?types.Type,
    count_id: exprs.NodeId,
) !serialize.RustIr {
    const span: spine.Span = .{
        .start_line = 3,
        .start_col = 5,
        .end_line = 3,
        .end_col = 14,
    };
    const type_rows = if (count_type) |ty|
        try allocator.dupe(types.Type, &.{ty})
    else
        try allocator.dupe(types.Type, &.{});
    const count_type_id: ?exprs.TypeId = if (count_type == null) null else 0;
    const expression_rows = try allocator.dupe(exprs.Expr, &.{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = count_type_id, .kind = .{ .unit = {} } },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .vec_lit = .{
                .elements = try allocator.dupe(exprs.NodeId, &.{0}),
                .repeat = .{ .expression = count_id },
            } },
        },
    });
    const body_kinds = [_]bodies.BodyKind{.none};
    return serialize.RustIr{
        .crate_name = "vec_dynamic",
        .edition = "2021",
        .graph = try initTestGraph(allocator, "vec_dynamic", &.{}),
        .types = type_rows,
        .bodies = .{
            .exprs = expression_rows,
            .stmts = &.{},
            .pats = &.{},
            .types = type_rows,
            .bodies = &body_kinds,
        },
    };
}

test "serialize: a Vec literal count the target evaluates preserves its wire payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fixture_ir = try initVecRepeatCountIr(alloc, .{ .prim = .usize }, 1);
    defer fixture_ir.graph.deinit();

    const encoded = try serialize.encode(alloc, &fixture_ir);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded,
        "\"kind\":\"vec_lit\",\"value\":{\"elements\":[0]," ++
            "\"repeat\":{\"tag\":\"expression\",\"value\":1}}",
    ) != null);

    var decoded = try serialize.decode(alloc, encoded);
    defer decoded.graph.deinit();
    const decoded_vec = switch (decoded.bodies.exprs[2].kind) {
        .vec_lit => |vec| vec,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), decoded_vec.elements.len);
    try std.testing.expectEqual(@as(exprs.NodeId, 0), decoded_vec.elements[0]);
    try std.testing.expectEqual(
        @as(?exprs.VecRepeatCount, .{ .expression = 1 }),
        decoded_vec.repeat,
    );
    // The count is still a `usize` on the far side of the wire, which is what
    // makes it a count rather than a number the reader has to take on trust.
    try root.validateForTranslation(&decoded);
}

// `vec![e; n]` counts in `usize` by the language. `u32` is a number the node
// really can evaluate to, and it is still not a count.
test "validate: a Vec literal count typed as something other than usize is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fixture_ir = try initVecRepeatCountIr(allocator, .{ .prim = .u32 }, 1);
    defer fixture_ir.graph.deinit();

    try std.testing.expectError(error.UnsupportedType, root.validateForTranslation(&fixture_ir));
}

// No type is invented for a count nothing typed: inference owes that node one,
// and a count read without one would be a number the IR never established.
test "validate: a Vec literal count no declaration typed is incomplete metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fixture_ir = try initVecRepeatCountIr(allocator, null, 1);
    defer fixture_ir.graph.deinit();

    try std.testing.expectError(
        error.IncompleteGenericMetadata,
        root.validateForTranslation(&fixture_ir),
    );
}

test "validate: a Vec literal count naming no expression is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fixture_ir = try initVecRepeatCountIr(allocator, .{ .prim = .usize }, 99);
    defer fixture_ir.graph.deinit();

    try std.testing.expectError(error.InvalidExprRef, root.validateForTranslation(&fixture_ir));
}

test "serialize: a Vec literal count object the wire cannot read exactly is rejected" {
    const allocator = std.testing.allocator;
    // The count is read before the element list, so every one of these is
    // refused on the count alone and hands back nothing of the literal.
    const rejected = [_][]const u8{
        // A third key: a count this decoder cannot read exactly is never one it
        // is free to guess at.
        "{\"tag\":\"expression\",\"value\":1,\"note\":\"extra\"}",
        // A tag other than the one form the wire has, and a tag that is not a
        // string at all.
        "{\"tag\":\"literal\",\"value\":1}",
        "{\"tag\":1,\"value\":1}",
        // No node id beside the tag.
        "{\"tag\":\"expression\"}",
        // A node id that is not an integer node id.
        "{\"tag\":\"expression\",\"value\":\"1\"}",
        "{\"tag\":\"expression\",\"value\":true}",
        "{\"tag\":\"expression\",\"value\":1.5}",
        "{\"tag\":\"expression\",\"value\":18446744073709551616}",
        "{\"tag\":\"expression\",\"value\":-1}",
    };
    for (rejected) |count| {
        const payload = try std.fmt.allocPrint(
            allocator,
            "{{\"format_version\":6,\"crate_name\":\"bad\",\"edition\":\"2021\"," ++
                "\"sidecar\":null,\"toolchain\":null,{s}" ++
                ",\"instantiations\":[],\"types\":[],\"bodies\":{{\"exprs\":[{{\"id\":0," ++
                "\"span\":{{\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":1}}," ++
                "\"ty\":null,\"kind\":\"vec_lit\",\"value\":{{\"elements\":[],\"repeat\":{s}}}}}]," ++
                "\"stmts\":[],\"pats\":[],\"types\":[],\"bodies\":[{{\"owner\":0," ++
                "\"body\":{{\"kind\":\"none\"}}}}]}}}}",
            .{ valid_crates_json, count },
        );
        defer allocator.free(payload);
        try std.testing.expectError(error.BadWireFormat, serialize.decode(allocator, payload));
    }
}

test "serialize: a Vec literal with no repeat key is a missing field" {
    const payload =
        "{\"format_version\":6,\"crate_name\":\"bad\",\"edition\":\"2021\"," ++
        "\"sidecar\":null,\"toolchain\":null," ++ valid_crates_json ++
        ",\"instantiations\":[],\"types\":[],\"bodies\":{\"exprs\":[{\"id\":0," ++
        "\"span\":{\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":1}," ++
        "\"ty\":null,\"kind\":\"vec_lit\",\"value\":{\"elements\":[]}}]," ++
        "\"stmts\":[],\"pats\":[],\"types\":[],\"bodies\":[{\"owner\":0," ++
        "\"body\":{\"kind\":\"none\"}}]}}";
    try std.testing.expectError(
        error.MissingField,
        serialize.decode(std.testing.allocator, payload),
    );
}

fn checkVecRepeatCountAllocationFailures(allocator: std.mem.Allocator) !void {
    // The fixture is built over the INJECTED allocator, so the validation
    // scratch and every table of the round trip are fault-injected too
    // rather than served from a pool the test already paid for.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var fixture_ir = try initVecRepeatCountIr(arena.allocator(), .{ .prim = .usize }, 1);
    defer fixture_ir.graph.deinit();

    try root.validateForTranslation(&fixture_ir);
    const encoded = try serialize.encode(allocator, &fixture_ir);
    defer allocator.free(encoded);
    // `decode` has NO whole-value deinitializer. Its contract is a
    // caller-owned arena, and everything it owns — the crate name and
    // edition, every interned type, every element and parameter list, every
    // body row — comes from that one allocator. Releasing `decoded.graph`
    // alone frees the crate and strands all of it. So the ARENA is what is
    // given back, and it is registered BEFORE the decode: a decode that fails
    // part way still releases what it had already taken.
    var decoded_arena = std.heap.ArenaAllocator.init(allocator);
    defer decoded_arena.deinit();
    var decoded = try serialize.decode(decoded_arena.allocator(), encoded);
    try root.validateForTranslation(&decoded);
}

test "serialize: a Vec literal expression count round-trips under allocation faults" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkVecRepeatCountAllocationFailures,
        .{},
    );
}

// Counts are target metadata. Their wire form must remain an exact JSON
// number, including values above i64, on32-bit and64-bit translator hosts.
test "serialize: array repeat counts stay exact and numeric through u64::MAX" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const span: spine.Span = .{
        .start_line = 2,
        .start_col = 1,
        .end_line = 2,
        .end_col = 6,
    };
    const counts = [_]u64{
        4294967296, // u32::MAX + 1, the count a 32-bit host used to refuse
        9007199254740993, // 2^53 + 1, the first count an f64 would round
        9223372036854775808, // 2^63, the first count an i64 cannot hold
        18446744073709551615, // u64::MAX
    };
    for (counts) |count| {
        const element_ids = [_]exprs.NodeId{0};
        const expr_arr = [_]exprs.Expr{
            .{ .id = 0, .span = span, .ty = null, .kind = .{ .unit = {} } },
            .{
                .id = 1,
                .span = span,
                .ty = null,
                .kind = .{ .array = .{
                    .elements = &element_ids,
                    .repeat = count,
                } },
            },
        };
        const body_kinds = [_]bodies.BodyKind{.none};
        const ir_types = [_]types.Type{.{ .array = &.{
            .elem = .{ .prim = .unit },
            .len = .{ .literal = count },
        } }};
        const sample_ir: serialize.RustIr = .{
            .crate_name = "array_repeat",
            .edition = "2021",
            .graph = try initTestGraph(alloc, "array_repeat", &.{}),
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
        // Unquoted, no exponent: a quoted string or a float would both change
        // the wire format, and a float would round the count.
        var needle: [48]u8 = undefined;
        const needle_text = try std.fmt.bufPrint(&needle, "\"repeat\":{d}", .{count});
        try std.testing.expect(std.mem.indexOf(u8, encoded, needle_text) != null);

        var decoded = try serialize.decode(alloc, encoded);
        defer decoded.graph.deinit();
        const decoded_array = switch (decoded.bodies.exprs[1].kind) {
            .array => |array| array,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(?u64, count), decoded_array.repeat);
        try std.testing.expectEqual(count, decoded.types[0].array.len.literal);
    }
}

fn checkCanonicalEncodeAllocationFailures(
    allocator: std.mem.Allocator,
    ir: serialize.RustIr,
) !void {
    const encoded = try serialize.encode(allocator, &ir);
    // Only the wire bytes belong to `allocator`; freeing them here is the
    // proof that the caller's free matches the caller's own allocation.
    allocator.free(encoded);
}

// An encode owns nothing but its output bytes. Everything else it builds — the
// JSON tree, the crate member masks, the printed count and literal texts, and
// the validation scratch — belongs to one arena over the caller's allocator,
// so a fault at any point of the walk must be refused with nothing retained.
test "serialize: canonical encode owns only its output bytes under allocation faults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 4,
    };
    // The widest count the wire format carries, printed twice: as an array
    // expression's repeat and as an array type's length.
    const count: u64 = std.math.maxInt(u64);
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
        .body = 0,
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
    const ir_types = [_]types.Type{
        .{ .prim = .i32 },
        .{ .array = &.{ .elem = .{ .prim = .unit }, .len = .{ .literal = count } } },
    };
    const ir: serialize.RustIr = .{
        .crate_name = "encode_fault",
        .edition = "2021",
        .graph = try initTestGraph(
            alloc,
            "encode_fault",
            &.{ .fn_, .struct_, .enum_, .trait_, .type_alias },
        ),
        .types = &ir_types,
        .bodies = .{
            .exprs = &.{
                .{ .id = 0, .span = span, .ty = 0, .kind = .{ .block = .{
                    .statements = &.{},
                    .tail = 1,
                    .labelled = "fault_block",
                } } },
                .{ .id = 1, .span = span, .ty = 0, .kind = .{ .array = .{
                    .elements = &.{2},
                    .repeat = count,
                } } },
                .{ .id = 2, .span = span, .ty = 0, .kind = .{ .unit = {} } },
            },
            .stmts = &.{},
            .pats = &.{},
            .types = &ir_types,
            .bodies = &body_kinds,
        },
    };

    // The returned bytes are the caller's and outlive the temporary arena:
    // both counts are still exact, unquoted numbers.
    const encoded = try serialize.encode(std.testing.allocator, &ir);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(
        std.mem.indexOf(u8, encoded, "\"repeat\":18446744073709551615") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            encoded,
            "\"len\":{\"kind\":\"literal\",\"value\":18446744073709551615}",
        ) != null,
    );

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkCanonicalEncodeAllocationFailures,
        .{ir},
    );
}

// `decodeExprKind` reads the count before it reads the element id list, so a
// count that names no describable array is refused before any of that list is
// allocated. It is refused, not clamped and not rounded down.
test "serialize: a repeat count wider than u64 is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const over_u64 =
        "{\"format_version\":6,\"crate_name\":\"bad\",\"edition\":\"2021\"," ++
        "\"sidecar\":null,\"toolchain\":null," ++ valid_crates_json ++
        ",\"instantiations\":[],\"types\":[],\"bodies\":{\"exprs\":[{\"id\":0," ++
        "\"span\":{\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":1}," ++
        "\"ty\":null,\"kind\":\"array\",\"value\":{\"elements\":[0,1]," ++
        "\"repeat\":18446744073709551616}}]," ++
        "\"stmts\":[],\"pats\":[],\"types\":[],\"bodies\":[{\"owner\":0,\"body\":{\"kind\":\"none\"}}]}}";
    try std.testing.expectError(
        error.BadWireFormat,
        serialize.decode(allocator, over_u64),
    );
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
    try std.testing.expectEqual(items.StructKind.tuple, struct_body.layout);
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
    try std.testing.expectEqual(@as(?items.IntRepr, .u32), enum_body.repr_int);
    try std.testing.expectEqual(items.EnumKind.data, enum_body.kind);
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

test "serialize: field and variant documentation roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 4,
    };

    const fields = [_]items.Field{
        .{
            .name = "documented",
            .ty = .{ .prim = .i32 },
            .visibility = .public,
            .span = span,
            .documentation = "Counts bytes.\nSecond line.",
        },
        .{
            .name = "plain",
            .ty = .{ .prim = .u8 },
            .visibility = .private,
            .span = span,
        },
    };
    const variants = [_]items.Variant{
        .{
            .name = "Value",
            .fields = .{ .named = &fields },
            .discriminant = 1,
            .documentation = "Carries a payload.",
        },
        .{ .name = "Empty", .fields = .none, .discriminant = 0 },
    };
    const body_kinds = [_]bodies.BodyKind{
        .none,
        .{ .struct_ = .{ .fields = &fields } },
        .{ .enum_ = .{ .kind = .data, .variants = &variants } },
    };
    const root_types = [_]types.Type{.{ .prim = .i32 }};
    const ir = serialize.RustIr{
        .crate_name = "documented",
        .edition = "2021",
        .graph = try initTestGraph(allocator, "documented", &.{ .struct_, .enum_ }),
        .types = &root_types,
        .bodies = .{
            .exprs = &.{},
            .stmts = &.{},
            .pats = &.{},
            .types = &root_types,
            .bodies = &body_kinds,
        },
    };

    const encoded = try serialize.encode(allocator, &ir);
    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();

    // A record that carried documentation keeps it; one that carried none
    // decodes to the empty default without allocating.
    const struct_fields = decoded.bodies.bodies[1].struct_.fields;
    try std.testing.expectEqual(@as(usize, 2), struct_fields.len);
    try std.testing.expectEqualStrings("Counts bytes.\nSecond line.", struct_fields[0].documentation);
    try std.testing.expectEqualStrings("", struct_fields[1].documentation);

    const enum_variants = decoded.bodies.bodies[2].enum_.variants;
    try std.testing.expectEqual(@as(usize, 2), enum_variants.len);
    try std.testing.expectEqualStrings("Carries a payload.", enum_variants[0].documentation);
    try std.testing.expectEqualStrings("", enum_variants[1].documentation);
    switch (enum_variants[0].fields) {
        .named => |named| {
            try std.testing.expectEqualStrings("Counts bytes.\nSecond line.", named[0].documentation);
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

/// A struct whose method and associated type both arrive from one `impl` — the
/// shape `finalizePendingImpls` produces. The struct's `StructBody.methods`
/// holds the method, the impl keeps the generics, and nothing on the struct
/// records that either was written inside the impl.
///
/// The struct declares no parameters of its own, so `method_param_ty` and
/// `assoc_target` can name an impl parameter (`I`, `T`) or a name no scope
/// binds (`Absent`) — and nothing else decides which.
fn initImplOwnedItemIr(
    allocator: std.mem.Allocator,
    method_param_ty: types.Type,
    assoc_target: types.Type,
) !serialize.RustIr {
    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 8,
    };
    var crate_graph = try initTestGraph(
        allocator,
        "impl_owned",
        &.{ .struct_, .impl_, .fn_, .type_alias },
    );
    // Only the struct is a module item. The impl and its two associated items
    // hang off the struct, so the module list must not claim them.
    crate_graph.modules.items[0].items = try allocator.dupe(spine.EntityId, &.{1});
    // Every name and slice the returned IR keeps is allocator-owned: the graph
    // frees its entity names on `deinit`, and a `&.{...}` literal holding a
    // runtime value would be a stack temporary that dies with this frame.
    crate_graph.symbol_table.entities.items[1].name = try allocator.dupe(u8, "DropGuard");
    crate_graph.symbol_table.entities.items[2].name = try allocator.dupe(u8, "Deref for DropGuard");
    crate_graph.symbol_table.entities.items[2].parent = 1;
    crate_graph.symbol_table.entities.items[3].name = try allocator.dupe(u8, "from");
    crate_graph.symbol_table.entities.items[3].parent = 2;
    crate_graph.symbol_table.entities.items[4].name = try allocator.dupe(u8, "Target");
    crate_graph.symbol_table.entities.items[4].parent = 2;

    const self_segments = try allocator.alloc(types.PathSegment, 1);
    self_segments[0] = .{ .name = "Self", .id = null };
    const self_type: types.Type = .{ .path = .{ .segments = self_segments } };
    const param_rows = try allocator.dupe(items.Param, &.{.{
        .name = "into",
        .ty = method_param_ty,
        .span = span,
    }});
    const method_rows = try allocator.dupe(bodies.StructMethod, &.{.{
        .name = "from",
        .params = param_rows,
        .ret = self_type,
        .body = 0,
        .receiver = .owned,
    }});
    const expression_rows = try allocator.dupe(exprs.Expr, &.{.{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{ .statements = &.{}, .tail = 0, .labelled = null } },
    }});
    const impl_self_segments = try allocator.alloc(types.PathSegment, 1);
    impl_self_segments[0] = .{ .name = "DropGuard", .id = 1 };
    const trait_segments = try allocator.dupe(types.PathSegment, &.{
        .{ .name = "core", .id = null },
        .{ .name = "ops", .id = null },
        .{ .name = "Deref", .id = null },
    });
    const generic_params = try allocator.dupe(types.GenericParam, &.{
        .{ .type_ = .{ .name = "I", .bounds = &.{} } },
        .{ .type_ = .{ .name = "T", .bounds = &.{} } },
    });
    const body_rows = try allocator.dupe(bodies.BodyKind, &.{
        .none,
        .{ .struct_ = .{ .layout = .unit, .methods = method_rows } },
        .{ .impl_ = .{
            .self_ty = .{ .path = .{ .segments = impl_self_segments } },
            .trait_path = .{ .segments = trait_segments },
            .generics = .{ .params = generic_params, .where_clauses = &.{} },
            .assoc_items = try allocator.dupe(spine.EntityId, &.{ 3, 4 }),
        } },
        .{ .fn_ = .{ .params = &.{}, .ret = self_type, .body = 0 } },
        .{ .type_alias = .{ .target = assoc_target } },
    });
    return serialize.RustIr{
        .crate_name = "impl_owned",
        .edition = "2021",
        .graph = crate_graph,
        .bodies = .{
            .exprs = expression_rows,
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = body_rows,
        },
    };
}

// The `wrapping` shape: `impl<I, T> From<I> for DropGuard { fn from(into: I)
// -> Self }`, re-parented onto the struct. `I` is bound by the impl and by
// nothing the struct records, so the struct's copy of the method encodes only
// if the owning impl's scope is read.
test "serialize: a reparented struct method may name the impl's parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fixture_ir = try initImplOwnedItemIr(
        allocator,
        .{ .path = .{ .segments = &.{.{ .name = "I", .id = null }} } },
        .{ .path = .{ .segments = &.{.{ .name = "T", .id = null }} } },
    );
    defer fixture_ir.graph.deinit();

    _ = try serialize.encode(allocator, &fixture_ir);
}

// The `drop_guard` shape: `impl Deref for DropGuard<T, F> { type Target = T;
// }`. The method's parameter is `Self` so the struct body cannot reject it,
// leaving the associated type as the only thing the impl's scope can save.
test "serialize: an associated type may name the impl's parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fixture_ir = try initImplOwnedItemIr(
        allocator,
        .{ .path = .{ .segments = &.{.{ .name = "Self", .id = null }} } },
        .{ .path = .{ .segments = &.{.{ .name = "T", .id = null }} } },
    );
    defer fixture_ir.graph.deinit();

    _ = try serialize.encode(allocator, &fixture_ir);
}

// Reading the owning impl must not become a blanket admission: a method
// parameter that no scope declares is still an unresolved path.
test "serialize: a reparented struct method naming an undeclared type is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fixture_ir = try initImplOwnedItemIr(
        allocator,
        .{ .path = .{ .segments = &.{.{ .name = "Absent", .id = null }} } },
        .{ .path = .{ .segments = &.{.{ .name = "T", .id = null }} } },
    );
    defer fixture_ir.graph.deinit();

    try std.testing.expectError(
        error.UnresolvedTypePath,
        serialize.encode(allocator, &fixture_ir),
    );
}

// The same, for the associated type: the impl's parameters do not make every
// name resolvable in its target.
test "serialize: an associated type naming an undeclared type is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fixture_ir = try initImplOwnedItemIr(
        allocator,
        .{ .path = .{ .segments = &.{.{ .name = "Self", .id = null }} } },
        .{ .path = .{ .segments = &.{.{ .name = "Absent", .id = null }} } },
    );
    defer fixture_ir.graph.deinit();

    try std.testing.expectError(
        error.UnresolvedTypePath,
        serialize.encode(allocator, &fixture_ir),
    );
}

/// A function generic over `I` whose one parameter is `projection`.
///
/// `Sealed` (entity 2) declares the associated type `Buffer`. `Marker`
/// (entity 3) is a plain struct and `BufferForU8` (entity 4) is the alias an
/// `impl` leaves behind once it has carried the projection out for one
/// concrete type, so each slot a canonical projection can be wrong in has a
/// real declaration to point at. Nothing here is feature metadata carried for
/// a test: the rule reads the trait's own `assoc_types`, the same list a
/// `Self::Sealed::Buffer` is checked against.
fn initGenericProjectionIr(
    allocator: std.mem.Allocator,
    projection: types.Type,
) !serialize.RustIr {
    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 8,
    };
    var crate_graph = try initTestGraph(
        allocator,
        "projection_fixture",
        &.{ .fn_, .trait_, .struct_, .type_alias },
    );
    // Every name the returned IR keeps is allocator-owned: `deinit` frees the
    // entity names, and a literal holding a stack value would outlive it.
    crate_graph.symbol_table.entities.items[1].name = try allocator.dupe(u8, "project");
    crate_graph.symbol_table.entities.items[2].name = try allocator.dupe(u8, "Sealed");
    crate_graph.symbol_table.entities.items[3].name = try allocator.dupe(u8, "Marker");
    crate_graph.symbol_table.entities.items[4].name = try allocator.dupe(u8, "BufferForU8");

    const param_rows = try allocator.dupe(items.Param, &.{.{
        .name = "buf",
        .ty = projection,
        .span = span,
    }});
    const assoc_rows = try allocator.dupe(items.AssocType, &.{.{
        .name = try allocator.dupe(u8, "Buffer"),
        .generics = null,
        .bounds = &.{},
        .default = null,
    }});
    const expression_rows = try allocator.dupe(exprs.Expr, &.{.{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{ .statements = &.{}, .tail = 0, .labelled = null } },
    }});
    const body_rows = try allocator.dupe(bodies.BodyKind, &.{
        .none,
        .{ .fn_ = .{
            .params = param_rows,
            .ret = .{ .prim = .u8 },
            .generic_params = &.{"I"},
            .body = 0,
        } },
        .{ .trait_ = .{
            .name = try allocator.dupe(u8, "Sealed"),
            .assoc_types = assoc_rows,
        } },
        .{ .struct_ = .{ .layout = .unit } },
        .{ .type_alias = .{ .target = .{ .prim = .u8 } } },
    });
    return serialize.RustIr{
        .crate_name = "projection_fixture",
        .edition = "2021",
        .graph = crate_graph,
        .bodies = .{
            .exprs = expression_rows,
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = body_rows,
        },
    };
}

/// `<I as Sealed>::Buffer` with the `as` clause and the `private::` module
/// prefix already gone: the receiver, the trait it resolves to, and the member
/// that trait declares.
const sealed_projection: types.Path = .{
    .segments = &[_]types.PathSegment{
        .{ .name = "I", .id = null },
        .{ .name = "Sealed", .id = 2 },
        .{ .name = "Buffer", .id = null },
    },
};

test "serialize: a generic projection naming a member its trait declares round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fixture_ir = try initGenericProjectionIr(allocator, .{ .path = sealed_projection });
    defer fixture_ir.graph.deinit();

    try root.validateForTranslation(&fixture_ir);
    const encoded = try serialize.encode(allocator, &fixture_ir);
    var decoded = try serialize.decode(allocator, encoded);
    defer decoded.graph.deinit();
    try root.validateForTranslation(&decoded);

    // The three slots survive the wire exactly: a receiver no declaration
    // resolves, the trait it does, and a terminal that is still the trait's
    // member name rather than one impl's answer to it.
    const decoded_param = decoded.bodies.bodies[1].fn_.params[0];
    const decoded_path = switch (decoded_param.ty) {
        .path => |path| path,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 3), decoded_path.segments.len);
    try std.testing.expectEqualStrings("I", decoded_path.segments[0].name);
    try std.testing.expectEqual(@as(?spine.EntityId, null), decoded_path.segments[0].id);
    try std.testing.expectEqualStrings("Sealed", decoded_path.segments[1].name);
    try std.testing.expectEqual(@as(?spine.EntityId, 2), decoded_path.segments[1].id);
    try std.testing.expectEqualStrings("Buffer", decoded_path.segments[2].name);
    try std.testing.expectEqual(@as(?spine.EntityId, null), decoded_path.segments[2].id);
    try std.testing.expectEqual(@as(usize, 1), decoded.bodies.bodies[2].trait_.assoc_types.len);
}

// An `impl`'s `type Buffer` is the projection already carried out for one
// concrete type. Reading it back as the trait's member is what would let that
// one layout stand in for the parameter the signature is still written on.
test "serialize: a projection terminal resolved against one impl is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const resolved_terminal: types.Path = .{
        .segments = &[_]types.PathSegment{
            .{ .name = "I", .id = null },
            .{ .name = "Sealed", .id = 2 },
            .{ .name = "Buffer", .id = 4 },
        },
    };
    var fixture_ir = try initGenericProjectionIr(allocator, .{ .path = resolved_terminal });
    defer fixture_ir.graph.deinit();

    try std.testing.expectError(
        error.InvalidTypePath,
        root.validateForTranslation(&fixture_ir),
    );
}

// A struct can sit where the trait slot spells a name, but it declares no
// associated type, so the projection it appears in does not exist.
test "serialize: a projection whose middle segment is not a trait is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const non_trait_owner: types.Path = .{
        .segments = &[_]types.PathSegment{
            .{ .name = "I", .id = null },
            .{ .name = "Marker", .id = 3 },
            .{ .name = "Buffer", .id = null },
        },
    };
    var fixture_ir = try initGenericProjectionIr(allocator, .{ .path = non_trait_owner });
    defer fixture_ir.graph.deinit();

    try std.testing.expectError(
        error.InvalidTypePath,
        root.validateForTranslation(&fixture_ir),
    );
}

// The trait is right and its name matches, so the member list is the only
// thing left to decide.
test "serialize: a projection naming a member the trait does not declare is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const missing_member: types.Path = .{
        .segments = &[_]types.PathSegment{
            .{ .name = "I", .id = null },
            .{ .name = "Sealed", .id = 2 },
            .{ .name = "Missing", .id = null },
        },
    };
    var fixture_ir = try initGenericProjectionIr(allocator, .{ .path = missing_member });
    defer fixture_ir.graph.deinit();

    try std.testing.expectError(
        error.UnresolvedTypePath,
        root.validateForTranslation(&fixture_ir),
    );
}

// An id alone is not enough: the segment has to name the declaration it
// resolves to, or it is spelling one the id does not reach.
test "serialize: a projection naming another declaration in its trait slot is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const misnamed_trait: types.Path = .{
        .segments = &[_]types.PathSegment{
            .{ .name = "I", .id = null },
            .{ .name = "Marker", .id = 2 },
            .{ .name = "Buffer", .id = null },
        },
    };
    var fixture_ir = try initGenericProjectionIr(allocator, .{ .path = misnamed_trait });
    defer fixture_ir.graph.deinit();

    try std.testing.expectError(
        error.InvalidTypePath,
        root.validateForTranslation(&fixture_ir),
    );
}

// Only a RESOLVED middle segment makes this shape a projection. Spelling a
// module prefix after a parameter produces nothing, so it is left exactly as
// the segment loop already decided.
test "serialize: a module path spelled after a parameter is not a projection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const unresolved_middle: types.Path = .{
        .segments = &[_]types.PathSegment{
            .{ .name = "I", .id = null },
            .{ .name = "enc", .id = null },
            .{ .name = "Iter", .id = null },
        },
    };
    var fixture_ir = try initGenericProjectionIr(allocator, .{ .path = unresolved_middle });
    defer fixture_ir.graph.deinit();

    try root.validateForTranslation(&fixture_ir);
}

// The rule is three slots wide, so a bare parameter and an unqualified
// associated step keep whatever they decided before it existed.
test "serialize: a bare parameter and an unqualified associated step keep their shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bare_parameter: types.Path = .{
        .segments = &[_]types.PathSegment{.{ .name = "I", .id = null }},
    };
    var bare_ir = try initGenericProjectionIr(allocator, .{ .path = bare_parameter });
    defer bare_ir.graph.deinit();
    try root.validateForTranslation(&bare_ir);

    const unqualified_step: types.Path = .{
        .segments = &[_]types.PathSegment{
            .{ .name = "I", .id = null },
            .{ .name = "Buffer", .id = null },
        },
    };
    var step_ir = try initGenericProjectionIr(allocator, .{ .path = unqualified_step });
    defer step_ir.graph.deinit();
    try root.validateForTranslation(&step_ir);
}

// Reading the head as a parameter is what makes the other two slots a
// projection. A head no declaration binds is still a name nothing resolves.
test "serialize: a projection on a head no declaration binds is still unresolved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const unknown_head: types.Path = .{
        .segments = &[_]types.PathSegment{
            .{ .name = "Absent", .id = null },
            .{ .name = "Sealed", .id = 2 },
            .{ .name = "Buffer", .id = null },
        },
    };
    var fixture_ir = try initGenericProjectionIr(allocator, .{ .path = unknown_head });
    defer fixture_ir.graph.deinit();

    try std.testing.expectError(
        error.UnresolvedTypePath,
        root.validateForTranslation(&fixture_ir),
    );
}

fn checkGenericProjectionAllocationFailures(allocator: std.mem.Allocator) !void {
    // Arena growth must allocate at every boundary, independent of backing
    // allocator resize opportunities between fault-injection runs.
    var fixed_growth = std.testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
    // The fixture is built over the INJECTED allocator, so the validation
    // scratch and every table of the round trip are fault-injected too
    // rather than served from a pool the test already paid for.
    var arena = std.heap.ArenaAllocator.init(fixed_growth.allocator());
    defer arena.deinit();

    var fixture_ir = try initGenericProjectionIr(
        arena.allocator(),
        .{ .path = sealed_projection },
    );
    defer fixture_ir.graph.deinit();

    try root.validateForTranslation(&fixture_ir);
    const encoded = try serialize.encode(fixed_growth.allocator(), &fixture_ir);
    defer fixed_growth.allocator().free(encoded);
    // `decode` has NO whole-value deinitializer. Its contract is a
    // caller-owned arena, and everything it owns — the crate name and
    // edition, every interned type, every element and parameter list, every
    // body row — comes from that one allocator. Releasing `decoded.graph`
    // alone frees the crate and strands all of it. So the ARENA is what is
    // given back, and it is registered BEFORE the decode: a decode that fails
    // part way still releases what it had already taken.
    var decoded_arena = std.heap.ArenaAllocator.init(fixed_growth.allocator());
    defer decoded_arena.deinit();
    var decoded = try serialize.decode(decoded_arena.allocator(), encoded);
    try root.validateForTranslation(&decoded);
}

test "serialize: the canonical generic projection round-trips under allocation faults" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkGenericProjectionAllocationFailures,
        .{},
    );
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
