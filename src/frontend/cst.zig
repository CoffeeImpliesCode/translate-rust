//! cst — tree-sitter CST → item & type model extractor (P0 of the source
//! model). Replaces the rustdoc-JSON sidecar for the *type model*: parses a
//! crate's `.rs` source and populates the crate graph + `types.Type` table +
//! per-entity `BodyKind` for every item (module, use, struct, enum, union,
//! trait, type alias, const, static, fn signature, impl).
//!
//! Bodies (fn statements) are NOT lowered here — that is ts_ext (code model).
//! This module is the declaration/type axis (`data-model/items-types.md`).

const std = @import("std");
const ir = @import("translate_rust.ir");
const spine = ir.spine;
const types = ir.types;
const graph = ir.graph;
const bodies = ir.bodies;
const items = ir.items;
const names = @import("names.zig");
const ts = @import("tree_sitter");
const rust = @import("rust");

pub const span_of: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

pub const Ctx = struct {
    alloc: std.mem.Allocator,
    g: *graph.CrateGraph,
    src: []const u8,
    types_list: *std.ArrayListUnmanaged(types.Type),
    bodies_list: *std.ArrayListUnmanaged(bodies.BodyKind),
    base_dir: ?[]const u8 = null,
    io: ?std.Io = null,
};

fn readFileAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]const u8 {
    var dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var io_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &io_buf);
    return reader.interface.allocRemaining(allocator, .limited(1 << 30));
}

fn text(e: *const Ctx, node: ts.Node) []const u8 {
    return e.src[node.startByte()..node.endByte()];
}

fn isComment(node: ts.Node) bool {
    const k = node.kind();
    return std.mem.eql(u8, k, "line_comment") or std.mem.eql(u8, k, "block_comment");
}

/// Append a symbol-table entity + matching `.none` body slot. The caller
/// overwrites the body slot for items that carry one.
fn addEntity(e: *Ctx, kind: spine.EntityKind, name: []const u8, parent: ?spine.EntityId) !spine.EntityId {
    const id = try e.g.symbol_table.add(.{
        .id = 0,
        .kind = kind,
        .name = try e.alloc.dupe(u8, name),
        .span = span_of,
        .visibility = .public,
        .parent = parent,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try e.bodies_list.append(e.alloc, .none);
    return id;
}

fn appendType(e: *Ctx, t: types.Type) !types.TypeId {
    const id: types.TypeId = @intCast(e.types_list.items.len);
    try e.types_list.append(e.alloc, t);
    return id;
}

/// Visibility from a tree-sitter visibility_modifier node (or default priv).
fn visOf(e: *const Ctx, item: ts.Node) spine.Visibility {
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        if (std.mem.eql(u8, c.kind(), "visibility_modifier")) {
            const t = text(e, c);
            if (std.mem.indexOf(u8, t, "pub") != null) return .public;
        }
    }
    return .private;
}

fn isPub(e: *const Ctx, item: ts.Node) bool {
    return visOf(e, item) == .public;
}

// ── type lowering ────────────────────────────────────────────────────────────

fn mapPrim(nm: []const u8) ?types.Prim {
    if (std.mem.eql(u8, nm, "i8")) return .i8;
    if (std.mem.eql(u8, nm, "i16")) return .i16;
    if (std.mem.eql(u8, nm, "i32")) return .i32;
    if (std.mem.eql(u8, nm, "i64")) return .i64;
    if (std.mem.eql(u8, nm, "i128")) return .i128;
    if (std.mem.eql(u8, nm, "u8")) return .u8;
    if (std.mem.eql(u8, nm, "u16")) return .u16;
    if (std.mem.eql(u8, nm, "u32")) return .u32;
    if (std.mem.eql(u8, nm, "u64")) return .u64;
    if (std.mem.eql(u8, nm, "u128")) return .u128;
    if (std.mem.eql(u8, nm, "isize")) return .isize;
    if (std.mem.eql(u8, nm, "usize")) return .usize;
    if (std.mem.eql(u8, nm, "f32")) return .f32;
    if (std.mem.eql(u8, nm, "f64")) return .f64;
    if (std.mem.eql(u8, nm, "bool")) return .bool;
    if (std.mem.eql(u8, nm, "char")) return .char;
    if (std.mem.eql(u8, nm, "()")) return .unit;
    if (std.mem.eql(u8, nm, "!")) return .never;
    return null;
}

/// Lower a tree-sitter type node into a wire `types.Type`.
fn mapType(e: *Ctx, node: ts.Node) types.Type {
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "type")) {
        if (node.namedChildCount() > 0) return mapType(e, node.namedChild(0).?);
        return unsupportedTy();
    }
    if (std.mem.eql(u8, kind, "primitive_type")) {
        const nm = text(e, node);
        if (std.mem.eql(u8, nm, "str")) {
            const s = e.alloc.create(types.Slice) catch return unsupportedTy();
            s.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
            return .{ .slice = s };
        }
        if (mapPrim(nm)) |p| return .{ .prim = p };
        return unsupportedTy();
    }
    if (std.mem.eql(u8, kind, "reference_type")) {
        // &[T] / &mut [T] / &str / &T / &mut T
        var mut = false;
        var inner: ?ts.Node = null;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            const k = c.kind();
            if (std.mem.eql(u8, k, "mutable_specifier")) {
                mut = true;
            } else if (!std.mem.eql(u8, k, "lifetime")) {
                if (inner == null) inner = c;
            }
        }
        if (inner) |inn| {
            const in_kind = inn.kind();
            if (std.mem.eql(u8, in_kind, "slice_type") or std.mem.eql(u8, in_kind, "array_type")) {
                return mapType(e, inn);
            }
            if (std.mem.eql(u8, in_kind, "primitive_type") and std.mem.eql(u8, text(e, inn), "str")) {
                const s = e.alloc.create(types.Slice) catch return unsupportedTy();
                s.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
                return .{ .slice = s };
            }
            const pointee = mapType(e, inn);
            if (pointee == .slice) return pointee;
            const r = e.alloc.create(types.Ref) catch return unsupportedTy();
            r.* = .{ .mut = mut, .pointee = pointee };
            return .{ .reference = r };
        }
        return unsupportedTy();
    }
    if (std.mem.eql(u8, kind, "slice_type")) {
        var elem: types.Type = .{ .prim = .unit };
        if (node.namedChildCount() > 0) elem = mapType(e, node.namedChild(0).?);
        const s = e.alloc.create(types.Slice) catch return unsupportedTy();
        s.* = .{ .const_ = true, .elem = elem };
        return .{ .slice = s };
    }
    if (std.mem.eql(u8, kind, "array_type")) {
        var elem: types.Type = .{ .prim = .unit };
        var len_lit: u32 = 0;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            const k = c.kind();
            if (std.mem.eql(u8, k, "integer_literal")) {
                len_lit = std.fmt.parseInt(u32, text(e, c), 10) catch 0;
            } else {
                elem = mapType(e, c);
            }
        }
        const a = e.alloc.create(types.Array) catch return unsupportedTy();
        a.* = .{ .elem = elem, .len = .{ .literal = len_lit } };
        return .{ .array = a };
    }
    if (std.mem.eql(u8, kind, "pointer_type")) {
        var mut = false;
        var elem: types.Type = .{ .prim = .unit };
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            const k = c.kind();
            if (std.mem.eql(u8, k, "mutable_specifier")) {
                mut = true;
            } else if (!std.mem.eql(u8, k, "const_specifier")) {
                elem = mapType(e, c);
            }
        }
        const raw = e.alloc.create(types.RawPtr) catch return unsupportedTy();
        raw.* = .{ .mut = mut, .pointee = elem };
        return .{ .raw_ptr = raw };
    }
    if (std.mem.eql(u8, kind, "generic_type") or std.mem.eql(u8, kind, "type_identifier") or std.mem.eql(u8, kind, "identifier") or std.mem.eql(u8, kind, "scoped_type_identifier")) {
        return mapNamedType(e, node);
    }
    if (std.mem.eql(u8, kind, "tuple_type") or std.mem.eql(u8, kind, "unit_type")) {
        var tup: std.ArrayListUnmanaged(types.Type) = .empty;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            tup.append(e.alloc, mapType(e, c)) catch return unsupportedTy();
        }
        if (tup.items.len == 0) return .{ .prim = .unit };
        return .{ .tuple = tup.toOwnedSlice(e.alloc) catch return unsupportedTy() };
    }
    if (node.namedChildCount() > 0) return mapType(e, node.namedChild(0).?);
    return unsupportedTy();
}

/// A named (path) type — possibly generic `Foo<T>`, with std prelude
/// recognition (Option/Result/Box/Vec) into the dedicated IR nodes.
fn mapNamedType(e: *Ctx, node: ts.Node) types.Type {
    var name: ?[]const u8 = null;
    var arg_nodes: [8]ts.Node = undefined;
    var arg_count: usize = 0;
    var segs: std.ArrayListUnmanaged(types.PathSegment) = .empty;

    const kind = node.kind();
    if (std.mem.eql(u8, kind, "type_identifier") or std.mem.eql(u8, kind, "identifier")) {
        name = text(e, node);
    } else {
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            const k = c.kind();
            if (std.mem.eql(u8, k, "type_identifier") or std.mem.eql(u8, k, "identifier")) {
                name = text(e, c);
            } else if (std.mem.eql(u8, k, "scoped_type_identifier")) {
                const sub = mapScopedSegments(e, c);
                for (sub) |seg| segs.append(e.alloc, seg) catch return unsupportedTy();
            } else if (std.mem.eql(u8, k, "type_arguments") or std.mem.eql(u8, k, "generic_type")) {
                var j: u32 = 0;
                while (c.namedChild(j)) |a| : (j += 1) {
                    if (arg_count < arg_nodes.len) {
                        arg_nodes[arg_count] = a;
                        arg_count += 1;
                    }
                }
            }
        }
    }
    const nm = name orelse return unsupportedTy();
    var args: []const types.Type = &.{};
    if (arg_count > 0) {
        const args_arr = e.alloc.alloc(types.Type, arg_count) catch return unsupportedTy();
        for (arg_nodes[0..arg_count], 0..) |an, ai| args_arr[ai] = mapType(e, an);
        args = args_arr;
    }

    // std prelude → dedicated nodes (so emit forks structurally).
    if (std.mem.eql(u8, nm, "Option") and args.len == 1) {
        const inner = e.alloc.create(types.Type) catch return unsupportedTy();
        inner.* = args[0];
        return .{ .option = inner };
    }
    if (std.mem.eql(u8, nm, "Result") and args.len == 2) {
        const r = e.alloc.create(types.Result) catch return unsupportedTy();
        r.* = .{
            .ok = args[0],
            .err = args[1],
            .is_error_unionable = true,
        };
        return .{ .result = r };
    }
    if (std.mem.eql(u8, nm, "Box") and args.len == 1) {
        const inner = e.alloc.create(types.Type) catch return unsupportedTy();
        inner.* = args[0];
        return .{ .boxed = inner };
    }
    // Generic instantiation → GenericInst (decl resolved later by names pass).
    if (args.len > 0) {
        var base_def: spine.EntityId = 0;
        for (e.g.symbol_table.entities.items) |ent| {
            if (std.mem.eql(u8, ent.name, nm)) {
                base_def = ent.id;
                break;
            }
        }
        if (base_def == 0) {
            base_def = addEntity(e, .struct_, nm, 0) catch 0;
        }
        return .{
            .generic_inst = .{
                .decl = base_def,
                .args = .{ .params = args },
            },
        };
    }
    segs.append(e.alloc, .{ .name = nm, .id = null }) catch return unsupportedTy();
    return .{ .path = .{ .segments = segs.toOwnedSlice(e.alloc) catch return unsupportedTy() } };
}

/// All path segments of a `scoped_type_identifier` (prefix segments only; the
/// caller appends the leaf name last).
fn mapScopedSegments(e: *Ctx, node: ts.Node) []const types.PathSegment {
    var segs: std.ArrayListUnmanaged(types.PathSegment) = .empty;
    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "scoped_identifier") or std.mem.eql(u8, k, "scoped_type_identifier")) {
            const sub = mapScopedSegments(e, c);
            segs.appendSlice(e.alloc, sub) catch return &.{};
        } else if (std.mem.eql(u8, k, "identifier") or std.mem.eql(u8, k, "type_identifier")) {
            segs.append(e.alloc, .{ .name = text(e, c), .id = null }) catch return &.{};
        }
    }
    return segs.toOwnedSlice(e.alloc) catch &.{};
}

fn unsupportedTy() types.Type {
    return .{ .unsupported = .{ .reason = .cfg_gated, .message = "unsupported type", .span = span_of } };
}

// ── generics ────────────────────────────────────────────────────────────────

fn collectGenerics(e: *Ctx, item: ts.Node) types.Generics {
    var params: std.ArrayListUnmanaged(types.GenericParam) = .empty;
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        if (std.mem.eql(u8, c.kind(), "type_parameters")) {
            var j: u32 = 0;
            while (c.namedChild(j)) |tp| : (j += 1) {
                if (std.mem.eql(u8, tp.kind(), "type_parameter")) {
                    var pname: []const u8 = "";
                    var q: u32 = 0;
                    while (tp.namedChild(q)) |cc| : (q += 1) {
                        if (std.mem.eql(u8, cc.kind(), "type_identifier")) pname = text(e, cc);
                    }
                    params.append(e.alloc, .{ .type_ = .{ .name = pname, .bounds = &.{} } }) catch break;
                } else if (std.mem.eql(u8, tp.kind(), "lifetime_parameter")) {
                    params.append(e.alloc, .{ .lifetime = .{ .name = "lt" } }) catch break;
                }
            }
        }
    }
    return .{ .params = params.toOwnedSlice(e.alloc) catch &.{}, .where_clauses = &.{} };
}

// ── item lowering ────────────────────────────────────────────────────────────

/// Resolve the field list type for a field_declaration / ordered_field_list.
fn mapFields(e: *Ctx, node: ts.Node) []const items.Field {
    var fields: std.ArrayListUnmanaged(items.Field) = .empty;
    if (std.mem.eql(u8, node.kind(), "ordered_field_declaration_list")) {
        // tuple struct fields: each child is a type.
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            const nm = allocPrintOrEmpty(e, "{d}", .{i});
            fields.append(e.alloc, .{
                .name = nm,
                .ty = mapType(e, c),
                .visibility = .public,
                .span = span_of,
            }) catch break;
        }
        return fields.toOwnedSlice(e.alloc) catch &.{};
    }
    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        if (!std.mem.eql(u8, c.kind(), "field_declaration")) continue;
        var fname: []const u8 = "";
        var fty: types.Type = unsupportedTy();
        var j: u32 = 0;
        while (c.namedChild(j)) |cc| : (j += 1) {
            const k = cc.kind();
            if (std.mem.eql(u8, k, "field_identifier")) fname = text(e, cc);
            if (std.mem.eql(u8, k, "type") or std.mem.eql(u8, k, "primitive_type") or std.mem.eql(u8, k, "generic_type") or std.mem.eql(u8, k, "type_identifier") or std.mem.eql(u8, k, "reference_type") or std.mem.eql(u8, k, "array_type")) {
                fty = mapType(e, cc);
            }
        }
        if (fname.len == 0) continue;
        fields.append(e.alloc, .{
            .name = e.alloc.dupe(u8, fname) catch return &.{},
            .ty = fty,
            .visibility = if (isPub(e, c)) .public else .private,
            .span = span_of,
        }) catch break;
    }
    return fields.toOwnedSlice(e.alloc) catch &.{};
}

fn allocPrintOrEmpty(e: *Ctx, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(e.alloc, fmt, args) catch "";
}

fn structItem(e: *Ctx, item: ts.Node, parent: ?spine.EntityId) !void {
    var name: []const u8 = "";
    var fields_node: ?ts.Node = null;
    var tuple = false;
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "type_identifier")) name = text(e, c);
        if (std.mem.eql(u8, k, "field_declaration_list")) fields_node = c;
        if (std.mem.eql(u8, k, "ordered_field_declaration_list")) {
            fields_node = c;
            tuple = true;
        }
    }
    const eid = try addEntity(e, .struct_, name, parent);
    const fields = if (fields_node) |fn_| mapFields(e, fn_) else &.{};
    const layout: items.struct_kind = if (fields.len == 0) .unit else if (tuple) .tuple else .named;
    e.bodies_list.items[eid] = .{ .struct_ = .{
        .generic_params = &.{},
        .layout = layout,
        .fields = fields,
    } };
}

fn enumItem(e: *Ctx, item: ts.Node, parent: ?spine.EntityId) !void {
    var name: []const u8 = "";
    var variants_node: ?ts.Node = null;
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "type_identifier")) name = text(e, c);
        if (std.mem.eql(u8, k, "enum_variant_list")) variants_node = c;
    }
    const eid = try addEntity(e, .enum_, name, parent);
    var variants: std.ArrayListUnmanaged(items.Variant) = .empty;
    var kind: items.enum_kind = .c_like;
    if (variants_node) |vn| {
        var j: u32 = 0;
        while (vn.namedChild(j)) |v| : (j += 1) {
            if (!std.mem.eql(u8, v.kind(), "enum_variant")) continue;
            var vname: []const u8 = "";
            var ffields: items.VariantFields = .none;
            var vkind: items.enum_kind = .c_like;
            var k: u32 = 0;
            while (v.namedChild(k)) |c| : (k += 1) {
                const kk = c.kind();
                if (std.mem.eql(u8, kk, "identifier")) vname = text(e, c);
                if (std.mem.eql(u8, kk, "field_declaration_list")) {
                    ffields = .{ .named = mapFields(e, c) };
                    vkind = .data;
                } else if (std.mem.eql(u8, kk, "ordered_field_declaration_list")) {
                    var tup: std.ArrayListUnmanaged(types.Type) = .empty;
                    var m: u32 = 0;
                    while (c.namedChild(m)) |t| : (m += 1) tup.append(e.alloc, mapType(e, t)) catch break;
                    ffields = .{ .tuple = tup.toOwnedSlice(e.alloc) catch &.{} };
                    vkind = .data;
                }
            }
            if (kind == .c_like) kind = vkind;
            variants.append(e.alloc, .{ .name = try e.alloc.dupe(u8, vname), .fields = ffields, .discriminant = null }) catch break;
        }
    }
    e.bodies_list.items[eid] = .{ .enum_ = .{
        .kind = kind,
        .variants = variants.toOwnedSlice(e.alloc) catch &.{},
        .repr_int = null,
        .non_exhaustive = false,
    } };
}

fn unionItem(e: *Ctx, item: ts.Node, parent: ?spine.EntityId) !void {
    var name: []const u8 = "";
    var fields_node: ?ts.Node = null;
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        if (std.mem.eql(u8, c.kind(), "type_identifier")) name = text(e, c);
        if (std.mem.eql(u8, c.kind(), "field_declaration_list")) fields_node = c;
    }
    const eid = try addEntity(e, .union_, name, parent);
    e.bodies_list.items[eid] = .{ .struct_ = .{
        .layout = .named,
        .fields = if (fields_node) |fn_| mapFields(e, fn_) else &.{},
    } };
}

/// Map a `parameters` node into `items.Param` entries. Handles `self_parameter`
/// and `parameter` nodes, extracting the bound name from an `identifier` or a
/// `pattern` (including `mut` / destructured patterns).
fn mapParams(e: *Ctx, params_node: ?ts.Node) []const items.Param {
    var params: std.ArrayListUnmanaged(items.Param) = .empty;
    if (params_node) |pn| {
        var j: u32 = 0;
        while (pn.namedChild(j)) |p| : (j += 1) {
            const pk = p.kind();
            if (!std.mem.eql(u8, pk, "parameter") and !std.mem.eql(u8, pk, "self_parameter")) continue;
            var pname: []const u8 = "";
            var pty: types.Type = unsupportedTy();
            if (std.mem.eql(u8, pk, "self_parameter")) {
                pname = "self";
                const r = e.alloc.create(types.Ref) catch return params.toOwnedSlice(e.alloc) catch &.{};
                r.* = .{ .mut = false, .pointee = .{ .prim = .unit } };
                pty = .{ .reference = r };
            }
            var k: u32 = 0;
            while (p.namedChild(k)) |c| : (k += 1) {
                const kk = c.kind();
                if (std.mem.eql(u8, kk, "identifier")) {
                    if (pname.len == 0) pname = text(e, c);
                } else if (std.mem.eql(u8, kk, "pattern") or std.mem.eql(u8, kk, "mut_pattern") or std.mem.eql(u8, kk, "reference_pattern")) {
                    if (pname.len == 0) {
                        var m: u32 = 0;
                        while (c.namedChild(m)) |cc| : (m += 1) {
                            if (std.mem.eql(u8, cc.kind(), "identifier")) {
                                pname = text(e, cc);
                                break;
                            }
                        }
                    }
                } else if (std.mem.eql(u8, kk, "type") or std.mem.eql(u8, kk, "primitive_type") or std.mem.eql(u8, kk, "reference_type") or std.mem.eql(u8, kk, "generic_type") or std.mem.eql(u8, kk, "type_identifier") or std.mem.eql(u8, kk, "scoped_type_identifier") or std.mem.eql(u8, kk, "array_type") or std.mem.eql(u8, kk, "slice_type") or std.mem.eql(u8, kk, "tuple_type") or std.mem.eql(u8, kk, "unit_type")) {
                    pty = mapType(e, c);
                }
            }
            if (pname.len == 0) continue;
            params.append(e.alloc, .{
                .name = e.alloc.dupe(u8, pname) catch return params.toOwnedSlice(e.alloc) catch &.{},
                .ty = pty,
                .span = span_of,
            }) catch break;
        }
    }
    return params.toOwnedSlice(e.alloc) catch &.{};
}

fn traitItem(e: *Ctx, item: ts.Node, parent: ?spine.EntityId) !void {
    var name: []const u8 = "";
    var decls: ?ts.Node = null;
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        if (std.mem.eql(u8, c.kind(), "type_identifier")) name = text(e, c);
        if (std.mem.eql(u8, c.kind(), "declaration_list")) decls = c;
    }
    const eid = try addEntity(e, .trait_, name, parent);
    var methods: std.ArrayListUnmanaged(bodies.TraitMethodSig) = .empty;
    if (decls) |dl| {
        var j: u32 = 0;
        while (dl.namedChild(j)) |m| : (j += 1) {
            if (!std.mem.eql(u8, m.kind(), "function_signature_item")) continue;
            var mname: []const u8 = "";
            var mret: types.Type = .{ .prim = .unit };
            var mparams_node: ?ts.Node = null;
            var k: u32 = 0;
            while (m.namedChild(k)) |c| : (k += 1) {
                const kk = c.kind();
                if (std.mem.eql(u8, kk, "identifier")) mname = text(e, c);
                if (std.mem.eql(u8, kk, "parameters")) mparams_node = c;
                if (std.mem.eql(u8, kk, "return_type")) {
                    if (c.namedChildCount() > 0) mret = mapType(e, c.namedChild(0).?);
                }
            }
            const mparams = mapParams(e, mparams_node);
            // Split a leading `self` param into the receiver kind.
            var receiver: items.Receiver = .ref_;
            var params = mparams;
            if (mparams.len > 0 and std.mem.eql(u8, mparams[0].name, "self")) {
                receiver = .ref_;
                if (mparams[0].ty == .reference) {
                    if (mparams[0].ty.reference.*.mut) receiver = .mut_ref;
                    // `self` by value has no `&`; default owned.
                } else {
                    receiver = .owned;
                }
                params = mparams[1..];
            }
            methods.append(e.alloc, .{
                .name = try e.alloc.dupe(u8, mname),
                .params = params,
                .ret = mret,
                .receiver = receiver,
            }) catch break;
        }
    }
    e.bodies_list.items[eid] = .{ .trait_ = .{
        .name = try e.alloc.dupe(u8, name),
        .supertraits = &.{},
        .methods = methods.toOwnedSlice(e.alloc) catch &.{},
    } };
}

fn typeAliasItem(e: *Ctx, item: ts.Node, parent: ?spine.EntityId) !void {
    var name: []const u8 = "";
    var target: types.Type = unsupportedTy();
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "type_identifier")) name = text(e, c);
        if (std.mem.eql(u8, k, "generic_type") or std.mem.eql(u8, k, "primitive_type") or std.mem.eql(u8, k, "type_identifier") or std.mem.eql(u8, k, "reference_type") or std.mem.eql(u8, k, "array_type") or std.mem.eql(u8, k, "tuple_type")) {
            target = mapType(e, c);
        }
    }
    const eid = try addEntity(e, .type_alias, name, parent);
    e.bodies_list.items[eid] = .{ .type_alias = .{ .target = target } };
}

fn constItem(e: *Ctx, item: ts.Node, parent: ?spine.EntityId) !void {
    var name: []const u8 = "";
    var ty: types.Type = unsupportedTy();
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "identifier")) name = text(e, c);
        if (std.mem.eql(u8, k, "primitive_type") or std.mem.eql(u8, k, "generic_type") or std.mem.eql(u8, k, "type_identifier") or std.mem.eql(u8, k, "array_type")) {
            ty = mapType(e, c);
        }
    }
    const eid = try addEntity(e, .const_, name, parent);
    e.bodies_list.items[eid] = .{ .const_ = .{ .ty = ty, .init = 0 } };
}

fn functionItem(e: *Ctx, item: ts.Node, parent: ?spine.EntityId, is_trait_sig: bool) !void {
    _ = is_trait_sig;
    var name: []const u8 = "";
    var params_node: ?ts.Node = null;
    var ret: types.Type = .{ .prim = .unit };
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "identifier")) name = text(e, c);
        if (std.mem.eql(u8, k, "parameters")) params_node = c;
        if (std.mem.eql(u8, k, "return_type")) {
            if (c.namedChildCount() > 0) ret = mapType(e, c.namedChild(0).?);
        }
    }
    const params = mapParams(e, params_node);
    const eid = try addEntity(e, .fn_, name, parent);
    e.bodies_list.items[eid] = .{ .fn_ = .{
        .params = params,
        .ret = ret,
        .body = 0,
    } };
}

fn joinPath(alloc: std.mem.Allocator, prefix: []const u8, seg: []const u8) ![]const u8 {
    if (prefix.len == 0) {
        const dup = try alloc.dupe(u8, seg);
        return dup;
    }
    if (seg.len == 0) {
        const dup = try alloc.dupe(u8, prefix);
        return dup;
    }
    const joined = try std.fmt.allocPrint(alloc, "{s}::{s}", .{ prefix, seg });
    return joined;
}

/// The last `::`-separated segment of a path (used as the default local name).
fn lastSegment(path: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, path, "::")) |idx| return path[idx + 2 ..];
    return path;
}

/// Register one expanded use path as a `.use_` entity plus a UseDecl.
fn emitUseItem(
    e: *Ctx,
    full_path: []const u8,
    local_name: []const u8,
    is_pub: bool,
    parent: ?spine.EntityId,
    item_ids: *std.ArrayListUnmanaged(spine.EntityId),
) !void {
    const eid = try addEntity(e, .use_, full_path, parent);
    e.g.symbol_table.entities.items[eid].visibility = if (is_pub) .public else .private;
    try item_ids.append(e.alloc, eid);
    try e.g.addUse(.{
        .id = eid,
        .kind = .{ .plain = 0 }, // target resolved in P1 (names pass)
        .local_name = if (local_name.len > 0) try e.alloc.dupe(u8, local_name) else "",
        .is_pub_export = is_pub,
        .target = 0,
        .span = span_of,
    });
}

/// Recursively expand a `use` tree into individual UseDecl items. Handles
/// plain paths, nested group lists (`use a::{b, c::{d, e}}`), `as` aliases,
/// `self` imports, and trailing `::*` globs.
fn processUseClause(
    e: *Ctx,
    node: ts.Node,
    prefix: []const u8,
    is_pub: bool,
    parent: ?spine.EntityId,
    item_ids: *std.ArrayListUnmanaged(spine.EntityId),
) !void {
    if (isComment(node)) return;
    const k = node.kind();
    if (std.mem.eql(u8, k, "visibility_modifier")) return;

    if (std.mem.eql(u8, k, "scoped_use_list")) {
        // `prefix::{...}` — fold the path child into the prefix, then expand.
        var path_node: ?ts.Node = null;
        var list_node: ?ts.Node = null;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            const ck = c.kind();
            if (std.mem.eql(u8, ck, "use_list")) {
                list_node = c;
            } else if (path_node == null) {
                path_node = c;
            }
        }
        var new_prefix = prefix;
        if (path_node) |pn| {
            const ptext = text(e, pn);
            // `self` already names the current scope; keep the prefix as-is.
            if (!std.mem.eql(u8, ptext, "self")) {
                new_prefix = try joinPath(e.alloc, prefix, ptext);
            }
        }
        if (list_node) |ln| try processUseClause(e, ln, new_prefix, is_pub, parent, item_ids);
    } else if (std.mem.eql(u8, k, "use_list")) {
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            try processUseClause(e, c, prefix, is_pub, parent, item_ids);
        }
    } else if (std.mem.eql(u8, k, "use_as_clause")) {
        // `path as Alias` — emit target `path`, local name `Alias`.
        var path_child: ?ts.Node = null;
        var alias_child: ?ts.Node = null;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            if (path_child == null) {
                path_child = c;
            } else if (alias_child == null) {
                alias_child = c;
            }
        }
        if (path_child != null and alias_child != null) {
            const ptext = text(e, path_child.?);
            const atext = text(e, alias_child.?);
            const target_path = if (std.mem.eql(u8, ptext, "self"))
                prefix
            else
                try joinPath(e.alloc, prefix, ptext);
            const ent_name = try std.fmt.allocPrint(e.alloc, "{s} as {s}", .{ target_path, atext });
            try emitUseItem(e, ent_name, atext, is_pub, parent, item_ids);
        }
    } else if (std.mem.eql(u8, k, "use_wildcard")) {
        // `path::*` — glob import; local name stays empty.
        var path_child: ?ts.Node = null;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            path_child = c;
        }
        const full = if (path_child) |pc|
            try joinPath(e.alloc, prefix, text(e, pc))
        else
            prefix;
        const wildcard_path = if (full.len > 0)
            try std.fmt.allocPrint(e.alloc, "{s}::*", .{full})
        else
            "*";
        try emitUseItem(e, wildcard_path, "", is_pub, parent, item_ids);
    } else if (std.mem.eql(u8, k, "self")) {
        // `use a::{self, ...}` — re-export the current scope itself.
        try emitUseItem(e, prefix, lastSegment(prefix), is_pub, parent, item_ids);
    } else if (std.mem.eql(u8, k, "identifier") or
        std.mem.eql(u8, k, "scoped_identifier") or
        std.mem.eql(u8, k, "crate") or
        std.mem.eql(u8, k, "super"))
    {
        const seg_str = text(e, node);
        if (std.mem.eql(u8, seg_str, "self")) {
            try emitUseItem(e, prefix, lastSegment(prefix), is_pub, parent, item_ids);
        } else {
            const path_str = try joinPath(e.alloc, prefix, seg_str);
            try emitUseItem(e, path_str, lastSegment(seg_str), is_pub, parent, item_ids);
        }
    } else if (node.namedChildCount() > 0) {
        // Unknown wrapper node — recurse into its children with the same prefix.
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            try processUseClause(e, c, prefix, is_pub, parent, item_ids);
        }
    } else {
        // Bare unknown leaf — treat as a plain path segment.
        const seg_str = text(e, node);
        const path_str = try joinPath(e.alloc, prefix, seg_str);
        try emitUseItem(e, path_str, lastSegment(seg_str), is_pub, parent, item_ids);
    }
}

/// Register a `use` declaration (possibly a nested group) as individual
/// UseDecl(s). Targets are resolved later by the names pass.
fn useItem(e: *Ctx, item: ts.Node, parent: ?spine.EntityId, item_ids: *std.ArrayListUnmanaged(spine.EntityId)) !void {
    const is_pub = isPub(e, item);
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        if (std.mem.eql(u8, c.kind(), "visibility_modifier")) continue;
        try processUseClause(e, c, "", is_pub, parent, item_ids);
    }
}
fn implItem(e: *Ctx, item: ts.Node, mod_id: spine.EntityId) !spine.EntityId {
    var self_ty_name: []const u8 = "";
    var trait_name: ?[]const u8 = null;
    var decl_list: ?ts.Node = null;

    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "type_identifier") or std.mem.eql(u8, k, "generic_type") or std.mem.eql(u8, k, "primitive_type")) {
            if (self_ty_name.len == 0) {
                self_ty_name = text(e, c);
            } else {
                trait_name = self_ty_name;
                self_ty_name = text(e, c);
            }
        } else if (std.mem.eql(u8, k, "declaration_list")) {
            decl_list = c;
        }
    }

    const name = if (trait_name) |tr|
        try std.fmt.allocPrint(e.alloc, "{s} for {s}", .{ tr, self_ty_name })
    else
        try e.alloc.dupe(u8, self_ty_name);

    const impl_id = try addEntity(e, .impl_, name, mod_id);

    if (decl_list) |dl| {
        var j: u32 = 0;
        while (dl.namedChild(j)) |child| : (j += 1) {
            if (std.mem.eql(u8, child.kind(), "function_item")) {
                try functionItem(e, child, impl_id, false);
            } else if (std.mem.eql(u8, child.kind(), "const_item")) {
                try constItem(e, child, impl_id);
            } else if (std.mem.eql(u8, child.kind(), "type_item")) {
                try typeAliasItem(e, child, impl_id);
            }
        }
    }

    return impl_id;
}

// ── module tree ─────────────────────────────────────────────────────────────

/// Walk the items of `node` (a source_file) and lower each into the root
/// module, updating its item list.
fn mapItems(e: *Ctx, node: ts.Node, mod_id: spine.EntityId) !void {
    const item_list = try mapItemsInner(e, node, mod_id);
    for (e.g.modules.items) |*m| {
        if (m.id == mod_id) {
            m.items = item_list;
            break;
        }
    }
}

/// Like mapItems but returns the item id list (for a nested module).
fn mapItemsInner(e: *Ctx, node: ts.Node, mod_id: spine.EntityId) ![]const spine.EntityId {
    var item_ids: std.ArrayListUnmanaged(spine.EntityId) = .empty;
    var i: u32 = 0;
    while (node.namedChild(i)) |item| : (i += 1) {
        if (isComment(item)) continue;
        const k = item.kind();
        if (std.mem.eql(u8, k, "mod_item")) {
            var mname: []const u8 = "";
            var decls: ?ts.Node = null;
            var j: u32 = 0;
            while (item.namedChild(j)) |c| : (j += 1) {
                if (std.mem.eql(u8, c.kind(), "identifier")) mname = text(e, c);
                if (std.mem.eql(u8, c.kind(), "declaration_list")) decls = c;
            }
            const child_id = try addEntity(e, .module, mname, mod_id);
            const child_mod_idx = e.g.modules.items.len;
            if (decls) |dl| {
                _ = try e.g.addModule(.{
                    .id = child_id,
                    .kind = .@"inline",
                    .name = try e.alloc.dupe(u8, mname),
                    .parent = mod_id,
                    .source_path = null,
                    .is_crate = false,
                    .is_extern = false,
                    .span = span_of,
                    .items = &.{},
                    .attributes = &.{},
                });
                const child_items = try mapItemsInner(e, dl, child_id);
                e.g.modules.items[child_mod_idx].items = child_items;
            } else {
                var sub_path: ?[]const u8 = null;
                var sub_base_dir: ?[]const u8 = null;
                if (e.base_dir) |bdir| {
                    const rs_name = try std.fmt.allocPrint(e.alloc, "{s}.rs", .{mname});
                    defer e.alloc.free(rs_name);
                    const cand1 = try std.fs.path.join(e.alloc, &.{ bdir, rs_name });
                    defer e.alloc.free(cand1);
                    const cand2 = try std.fs.path.join(e.alloc, &.{ bdir, mname, "mod.rs" });
                    defer e.alloc.free(cand2);
                    sub_base_dir = try std.fs.path.join(e.alloc, &.{ bdir, mname });
                    if (e.io) |io| {
                        var dir = std.Io.Dir.cwd();
                        if (dir.openFile(io, cand1, .{})) |f| {
                            f.close(io);
                            sub_path = try e.alloc.dupe(u8, cand1);
                        } else |_| {}
                        if (sub_path == null) {
                            if (dir.openFile(io, cand2, .{})) |f| {
                                f.close(io);
                                sub_path = try e.alloc.dupe(u8, cand2);
                            } else |_| {}
                        }
                    }
                }
                _ = try e.g.addModule(.{
                    .id = child_id,
                    .kind = .file,
                    .name = try e.alloc.dupe(u8, mname),
                    .parent = mod_id,
                    .source_path = sub_path,
                    .is_crate = false,
                    .is_extern = false,
                    .span = span_of,
                    .items = &.{},
                    .attributes = &.{},
                });
                if (sub_path != null and e.io != null) {
                    if (readFileAlloc(e.alloc, e.io.?, sub_path.?)) |sub_src| {
                        var sub_parser = ts.Parser.create();
                        defer sub_parser.destroy();
                        if (sub_parser.setLanguage(rust.language())) |_| {} else |_| {}
                        if (sub_parser.parseString(sub_src, null)) |sub_tree| {
                            defer sub_tree.destroy();
                            var sub_ctx: Ctx = .{
                                .alloc = e.alloc,
                                .g = e.g,
                                .src = sub_src,
                                .types_list = e.types_list,
                                .bodies_list = e.bodies_list,
                                .base_dir = sub_base_dir,
                                .io = e.io,
                            };
                            const child_items = try mapItemsInner(&sub_ctx, sub_tree.rootNode(), child_id);
                            e.g.modules.items[child_mod_idx].items = child_items;
                        }
                    } else |_| {}
                }
            }
            try item_ids.append(e.alloc, child_id);
        } else if (std.mem.eql(u8, k, "use_declaration")) {
            try useItem(e, item, mod_id, &item_ids);
        } else if (std.mem.eql(u8, k, "struct_item")) {
            try structItem(e, item, mod_id);
            try item_ids.append(e.alloc, @intCast(e.bodies_list.items.len - 1));
        } else if (std.mem.eql(u8, k, "enum_item")) {
            try enumItem(e, item, mod_id);
            try item_ids.append(e.alloc, @intCast(e.bodies_list.items.len - 1));
        } else if (std.mem.eql(u8, k, "union_item")) {
            try unionItem(e, item, mod_id);
            try item_ids.append(e.alloc, @intCast(e.bodies_list.items.len - 1));
        } else if (std.mem.eql(u8, k, "trait_item")) {
            try traitItem(e, item, mod_id);
            try item_ids.append(e.alloc, @intCast(e.bodies_list.items.len - 1));
        } else if (std.mem.eql(u8, k, "type_item")) {
            try typeAliasItem(e, item, mod_id);
            try item_ids.append(e.alloc, @intCast(e.bodies_list.items.len - 1));
        } else if (std.mem.eql(u8, k, "const_item")) {
            try constItem(e, item, mod_id);
            try item_ids.append(e.alloc, @intCast(e.bodies_list.items.len - 1));
        } else if (std.mem.eql(u8, k, "function_item")) {
            try functionItem(e, item, mod_id, false);
            try item_ids.append(e.alloc, @intCast(e.bodies_list.items.len - 1));
        } else if (std.mem.eql(u8, k, "impl_item")) {
            const id = try implItem(e, item, mod_id);
            try item_ids.append(e.alloc, id);
        }
    }
    return item_ids.toOwnedSlice(e.alloc);
}

/// Entry: parse `src` and build the type model into `ctx`. The root module
/// (id 0) must already exist. Returns the root module's item list.
pub fn extractFile(ctx: *Ctx) !void {
    var parser = ts.Parser.create();
    defer parser.destroy();
    if (parser.setLanguage(rust.language())) |_| {} else |_| {}
    const tree = parser.parseString(ctx.src, null) orelse return;
    defer tree.destroy();
    const root = tree.rootNode();
    try mapItems(ctx, root, 0);
    try names.resolveGraph(ctx.alloc, ctx.g);
}
