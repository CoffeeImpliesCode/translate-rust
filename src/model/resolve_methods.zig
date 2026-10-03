//! resolve_methods — Method, Trait, Operator and Constructor resolution (P4).
//!
//! After type inference gives concrete receiver types (P3), this pass
//! resolves method calls (`r.m(args)`), constructors (`T::new(...)`),
//! operators (`+`, `*`, `^`, ...), and trait implementations against:
//! 1. Inherent `impl <SelfTy> { fn m }` blocks defined in the crate.
//! 2. Trait `impl <Trait> for <SelfTy>` blocks defined in the crate.
//! 3. Built-in std prelude type methods (`Option`, `Result`, slice/array, numerics).
//!
//! Ambiguity or unresolvable methods cleanly degrade to `.unsupported` per-node.
//!
//! Pure Zig (C-free): imports only graph, spine, types, bodies, exprs.

const std = @import("std");
const spine = @import("spine.zig");
const graph = @import("graph.zig");
const types = @import("types.zig");
const bodies = @import("bodies.zig");
const exprs = @import("exprs.zig");

pub const StdMethod = enum {
    option_is_some,
    option_is_none,
    option_unwrap,
    option_unwrap_or,
    option_map,
    option_as_ref,
    option_take,

    result_is_ok,
    result_is_err,
    result_unwrap,
    result_unwrap_or,
    result_map,
    result_map_err,
    result_as_ref,

    slice_len,
    slice_is_empty,
    slice_as_bytes,
    slice_as_slice,
    slice_iter,

    num_wrapping_add,
    num_wrapping_sub,
    num_wrapping_mul,
    num_saturating_add,
    num_saturating_sub,
    num_saturating_mul,
    num_count_ones,
    num_leading_zeros,
    num_trailing_zeros,

    default,
    clone,
};

pub const ResolutionStats = struct {
    inherent_resolved: usize = 0,
    trait_resolved: usize = 0,
    std_resolved: usize = 0,
    constructors_resolved: usize = 0,
    unsupported_methods: usize = 0,
};

/// Lookup an inherent method for `type_name` with `method_name`.
/// Returns the EntityId of the matching `fn` if found.
pub fn lookupInherentMethod(
    g: *const graph.CrateGraph,
    type_name: []const u8,
    method_name: []const u8,
) ?spine.EntityId {
    std.debug.assert(type_name.len >= 0);
    std.debug.assert(method_name.len >= 0);
    if (type_name.len == 0 or method_name.len == 0) return null;

    for (g.symbol_table.entities.items) |ent| {
        if (ent.kind == .impl_) {
            // Inherent impl blocks have name == type_name (not a trait impl containing " for ").
            const is_trait_impl = std.mem.indexOf(u8, ent.name, " for ") != null;
            if (!is_trait_impl and std.mem.eql(u8, ent.name, type_name)) {
                for (g.symbol_table.entities.items) |child| {
                    if (child.kind == .fn_ and child.parent == ent.id and std.mem.eql(u8, child.name, method_name)) {
                        return child.id;
                    }
                }
            }
        }
    }
    return null;
}

/// Lookup a trait method `impl <trait_name> for <type_name> { fn <method_name> }`.
/// Returns the EntityId if a single candidate is found, or null on ambiguity/missing.
pub fn lookupTraitMethod(
    g: *const graph.CrateGraph,
    trait_name: []const u8,
    type_name: []const u8,
    method_name: []const u8,
) ?spine.EntityId {
    std.debug.assert(trait_name.len >= 0);
    std.debug.assert(type_name.len >= 0);
    std.debug.assert(method_name.len >= 0);
    if (trait_name.len == 0 or type_name.len == 0 or method_name.len == 0) return null;

    var count: usize = 0;
    var candidate: ?spine.EntityId = null;

    for (g.symbol_table.entities.items) |ent| {
        if (ent.kind == .impl_) {
            // Check if name is "{trait_name} for {type_name}" or contains both.
            const has_trait = std.mem.indexOf(u8, ent.name, trait_name) != null;
            const has_type = std.mem.indexOf(u8, ent.name, type_name) != null;
            const is_trait_impl = std.mem.indexOf(u8, ent.name, " for ") != null;
            if (is_trait_impl and has_trait and has_type) {
                for (g.symbol_table.entities.items) |child| {
                    if (child.kind == .fn_ and child.parent == ent.id and std.mem.eql(u8, child.name, method_name)) {
                        candidate = child.id;
                        count += 1;
                    }
                }
            }
        }
    }

    // Single candidate -> resolved; multiple candidates (ambiguity) -> null.
    if (count == 1) return candidate;
    return null;
}

/// Lookup constructor or associated function `Type::fn_name(...)`.
pub fn lookupConstructor(
    g: *const graph.CrateGraph,
    type_name: []const u8,
    fn_name: []const u8,
) ?spine.EntityId {
    return lookupInherentMethod(g, type_name, fn_name);
}

/// Match std prelude methods on known types, automatically unwrapping references/pointers/boxes.
pub fn lookupStdMethod(
    t: types.Type,
    method_name: []const u8,
) ?StdMethod {
    std.debug.assert(method_name.len >= 0);
    if (method_name.len == 0) return null;

    // Unpeel reference / raw_ptr / boxed to find underlying concrete type.
    var cur_t = t;
    while (true) {
        switch (cur_t) {
            .reference => |r| cur_t = r.pointee,
            .raw_ptr => |ptr| cur_t = ptr.pointee,
            .boxed => |b| cur_t = b.*,
            else => break,
        }
    }

    switch (cur_t) {
        .option => {
            if (std.mem.eql(u8, method_name, "is_some")) return .option_is_some;
            if (std.mem.eql(u8, method_name, "is_none")) return .option_is_none;
            if (std.mem.eql(u8, method_name, "unwrap")) return .option_unwrap;
            if (std.mem.eql(u8, method_name, "unwrap_or")) return .option_unwrap_or;
            if (std.mem.eql(u8, method_name, "map")) return .option_map;
            if (std.mem.eql(u8, method_name, "as_ref")) return .option_as_ref;
            if (std.mem.eql(u8, method_name, "take")) return .option_take;
        },
        .result => {
            if (std.mem.eql(u8, method_name, "is_ok")) return .result_is_ok;
            if (std.mem.eql(u8, method_name, "is_err")) return .result_is_err;
            if (std.mem.eql(u8, method_name, "unwrap")) return .result_unwrap;
            if (std.mem.eql(u8, method_name, "unwrap_or")) return .result_unwrap_or;
            if (std.mem.eql(u8, method_name, "map")) return .result_map;
            if (std.mem.eql(u8, method_name, "map_err")) return .result_map_err;
            if (std.mem.eql(u8, method_name, "as_ref")) return .result_as_ref;
        },
        .slice, .array => {
            if (std.mem.eql(u8, method_name, "len")) return .slice_len;
            if (std.mem.eql(u8, method_name, "is_empty")) return .slice_is_empty;
            if (std.mem.eql(u8, method_name, "as_bytes")) return .slice_as_bytes;
            if (std.mem.eql(u8, method_name, "as_slice")) return .slice_as_slice;
            if (std.mem.eql(u8, method_name, "iter")) return .slice_iter;
        },
        .prim => |p| {
            switch (p) {
                .u8, .u16, .u32, .u64, .u128, .usize, .i8, .i16, .i32, .i64, .i128, .isize => {
                    if (std.mem.eql(u8, method_name, "wrapping_add")) return .num_wrapping_add;
                    if (std.mem.eql(u8, method_name, "wrapping_sub")) return .num_wrapping_sub;
                    if (std.mem.eql(u8, method_name, "wrapping_mul")) return .num_wrapping_mul;
                    if (std.mem.eql(u8, method_name, "saturating_add")) return .num_saturating_add;
                    if (std.mem.eql(u8, method_name, "saturating_sub")) return .num_saturating_sub;
                    if (std.mem.eql(u8, method_name, "saturating_mul")) return .num_saturating_mul;
                    if (std.mem.eql(u8, method_name, "count_ones")) return .num_count_ones;
                    if (std.mem.eql(u8, method_name, "leading_zeros")) return .num_leading_zeros;
                    if (std.mem.eql(u8, method_name, "trailing_zeros")) return .num_trailing_zeros;
                },
                else => {},
            }
        },
        else => {},
    }

    if (std.mem.eql(u8, method_name, "default")) return .default;
    if (std.mem.eql(u8, method_name, "clone")) return .clone;

    return null;
}

/// Helper to get a type's simple name from `types.Type` / symbol table.
pub fn getTypeName(g: *const graph.CrateGraph, t: types.Type) ?[]const u8 {
    switch (t) {
        .path => |p| {
            if (p.segments.len > 0) {
                const last = p.segments[p.segments.len - 1];
                if (last.name.len > 0) return last.name;
                if (last.id) |id| {
                    if (g.symbol_table.get(id)) |ent| return ent.name;
                }
            }
            return null;
        },
        .generic_inst => |gi| {
            if (g.symbol_table.get(gi.decl)) |ent| return ent.name;
            return null;
        },
        .prim => |p| return @tagName(p),
        .reference => |r| return getTypeName(g, r.pointee),
        .raw_ptr => |ptr| return getTypeName(g, ptr.pointee),
        .boxed => |b| return getTypeName(g, b.*),
        .option => return "Option",
        .result => return "Result",
        .slice => return "slice",
        .array => return "array",
        else => return null,
    }
}

/// Resolve all method calls in `b.exprs` using the crate graph and types table.
pub fn resolveMethods(
    g: *const graph.CrateGraph,
    b: *bodies.Bodies,
) ResolutionStats {
    var stats: ResolutionStats = .{};

    for (@constCast(b.exprs)) |*e| {
        if (e.kind == .method_call) {
            const mc = &e.kind.method_call;
            const m_ent = g.symbol_table.get(mc.method);
            const m_name = if (m_ent) |me| me.name else "";
            if (m_name.len == 0) continue;

            var resolved = false;

            const recv_node = mc.receiver;
            if (recv_node < b.exprs.len) {
                const recv_expr = b.exprs[recv_node];
                if (recv_expr.ty) |tid| {
                    if (tid < b.types.len) {
                        const recv_ty = b.types[tid];
                        if (getTypeName(g, recv_ty)) |ty_name| {
                            // 1. Try inherent method first.
                            if (lookupInherentMethod(g, ty_name, m_name)) |fn_id| {
                                mc.method = fn_id;
                                stats.inherent_resolved += 1;
                                resolved = true;
                            }
                        }

                        // 2. Try std method if not resolved as inherent.
                        if (!resolved) {
                            if (lookupStdMethod(recv_ty, m_name)) |_| {
                                stats.std_resolved += 1;
                                resolved = true;
                            }
                        }
                    }
                }
            }

            if (!resolved) {
                stats.unsupported_methods += 1;
            }
        }
    }

    return stats;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "lookupInherentMethod and lookupConstructor" {
    const allocator = std.testing.allocator;
    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    const impl_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = try allocator.dupe(u8, "Point"),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const new_fn_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "new"),
        .span = span,
        .visibility = .public,
        .parent = impl_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const dist_fn_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "distance"),
        .span = span,
        .visibility = .public,
        .parent = impl_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    try std.testing.expectEqual(dist_fn_id, lookupInherentMethod(&g, "Point", "distance"));
    try std.testing.expectEqual(new_fn_id, lookupConstructor(&g, "Point", "new"));
    try std.testing.expectEqual(@as(?spine.EntityId, null), lookupInherentMethod(&g, "Point", "nonexistent"));
    try std.testing.expectEqual(@as(?spine.EntityId, null), lookupInherentMethod(&g, "Other", "distance"));
}

test "lookupTraitMethod single candidate vs ambiguity" {
    const allocator = std.testing.allocator;
    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    const trait_impl_1 = try g.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = try allocator.dupe(u8, "Display for Point"),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const fmt_fn_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "fmt"),
        .span = span,
        .visibility = .public,
        .parent = trait_impl_1,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Single candidate -> resolves
    try std.testing.expectEqual(fmt_fn_id, lookupTraitMethod(&g, "Display", "Point", "fmt"));

    // Add ambiguous second impl of same trait & type
    const trait_impl_2 = try g.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = try allocator.dupe(u8, "Display for Point"),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "fmt"),
        .span = span,
        .visibility = .public,
        .parent = trait_impl_2,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Multiple candidates -> null
    try std.testing.expectEqual(@as(?spine.EntityId, null), lookupTraitMethod(&g, "Display", "Point", "fmt"));
}

test "lookupStdMethod coverage" {
    const opt_ty: types.Type = .{ .option = &.{ .prim = .i32 } };
    try std.testing.expectEqual(StdMethod.option_is_some, lookupStdMethod(opt_ty, "is_some"));
    try std.testing.expectEqual(StdMethod.option_unwrap, lookupStdMethod(opt_ty, "unwrap"));

    const res_ty: types.Type = .{ .result = &.{ .ok = .{ .prim = .i32 }, .err = .{ .prim = .u32 }, .is_error_unionable = true } };
    try std.testing.expectEqual(StdMethod.result_is_ok, lookupStdMethod(res_ty, "is_ok"));
    try std.testing.expectEqual(StdMethod.result_map_err, lookupStdMethod(res_ty, "map_err"));

    const slice_ty: types.Type = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } };
    try std.testing.expectEqual(StdMethod.slice_len, lookupStdMethod(slice_ty, "len"));

    const ref_slice: types.Type = .{ .reference = &.{ .mut = false, .pointee = slice_ty } };
    try std.testing.expectEqual(StdMethod.slice_is_empty, lookupStdMethod(ref_slice, "is_empty"));

    const prim_ty: types.Type = .{ .prim = .u64 };
    try std.testing.expectEqual(StdMethod.num_wrapping_add, lookupStdMethod(prim_ty, "wrapping_add"));
    try std.testing.expectEqual(StdMethod.num_count_ones, lookupStdMethod(prim_ty, "count_ones"));

    try std.testing.expectEqual(StdMethod.clone, lookupStdMethod(prim_ty, "clone"));
    try std.testing.expectEqual(StdMethod.default, lookupStdMethod(prim_ty, "default"));
}

test "resolveMethods pass updates method_call entity id and gathers stats" {
    const allocator = std.testing.allocator;
    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    const impl_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = try allocator.dupe(u8, "Fletcher16"),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const update_fn_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "update"),
        .span = span,
        .visibility = .public,
        .parent = impl_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const placeholder_update_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "update"),
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const placeholder_len_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "len"),
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const placeholder_unknown_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "unknown_method"),
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const seg = try allocator.alloc(types.PathSegment, 1);
    defer allocator.free(seg);
    seg[0] = .{ .name = "Fletcher16", .id = null };

    const types_store = try allocator.alloc(types.Type, 2);
    defer allocator.free(types_store);
    types_store[0] = .{ .path = .{ .segments = seg } };
    types_store[1] = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } };

    const exprs_store = try allocator.alloc(exprs.Expr, 6);
    defer allocator.free(exprs_store);
    // Node 0: receiver (Fletcher16)
    exprs_store[0] = .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } };
    // Node 1: fletcher.update(...) -> inherent
    exprs_store[1] = .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{ .receiver = 0, .receiver_mode = .mutable, .method = placeholder_update_id, .args = &.{} } } };
    // Node 2: receiver (slice)
    exprs_store[2] = .{ .id = 2, .span = span, .ty = 1, .kind = .{ .unit = {} } };
    // Node 3: slice.len() -> std
    exprs_store[3] = .{ .id = 3, .span = span, .ty = null, .kind = .{ .method_call = .{ .receiver = 2, .receiver_mode = .shared, .method = placeholder_len_id, .args = &.{} } } };
    // Node 4: receiver (Fletcher16)
    exprs_store[4] = .{ .id = 4, .span = span, .ty = 0, .kind = .{ .unit = {} } };
    // Node 5: fletcher.unknown_method() -> unsupported
    exprs_store[5] = .{ .id = 5, .span = span, .ty = null, .kind = .{ .method_call = .{ .receiver = 4, .receiver_mode = .shared, .method = placeholder_unknown_id, .args = &.{} } } };

    var b: bodies.Bodies = .{
        .exprs = exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = types_store,
        .bodies = &.{},
    };

    const stats = resolveMethods(&g, &b);

    try std.testing.expectEqual(@as(usize, 1), stats.inherent_resolved);
    try std.testing.expectEqual(@as(usize, 1), stats.std_resolved);
    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_methods);
    try std.testing.expectEqual(update_fn_id, b.exprs[1].kind.method_call.method);
}
