//! cst — tree-sitter CST → item & type model extractor (P0 of the source
//! model). Replaces the rustdoc-JSON sidecar for the *type model*: parses a
//! crate's `.rs` source and populates the crate graph + `types.Type` table +
//! per-entity `BodyKind` for every item (module, use, struct, enum, union,
//! trait, type alias, const, static, fn signature, impl).
//!
//! Bodies (fn statements) are NOT lowered here — that is ts_ext (code model).
//! This module is the declaration/type axis (`data-model/items-types.md`).

const std = @import("std");
const spine = @import("spine.zig");
const types = @import("types.zig");
const graph = @import("graph.zig");
const bodies = @import("bodies.zig");
const items = @import("items.zig");
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
};

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
    return null;
}

/// Lower a tree-sitter type node into a wire `types.Type`.
fn mapType(e: *Ctx, node: ts.Node) types.Type {
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "primitive_type")) {
        const nm = text(e, node);
        if (std.mem.eql(u8, nm, "str")) {
            const s = e.alloc.create(types.Slice) catch return unsupportedTy();
            s.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
            return .{ .slice = s };
        }
        if (mapPrim(nm)) |p| return .{ .prim = p };
        return .{ .prim = .unit };
    }
    if (std.mem.eql(u8, kind, "reference_type")) {
        // &[T] / &T / &mut T
        var mut = false;
        var inner: ?ts.Node = null;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            const k = c.kind();
            if (std.mem.eql(u8, k, "mutable_specifier")) mut = true;
            if (std.mem.eql(u8, k, "array_type") or std.mem.eql(u8, k, "type")) {
                if (inner == null) inner = c;
            }
        }
        var elem: types.Type = .{ .prim = .unit };
        if (inner) |inn| {
            if (inn.namedChildCount() > 0 and std.mem.eql(u8, inn.kind(), "type")) {
                elem = mapType(e, inn.namedChild(0).?);
            } else {
                elem = mapType(e, inn);
            }
        }
        const s = e.alloc.create(types.Slice) catch return unsupportedTy();
        s.* = .{ .const_ = !mut, .elem = elem };
        return .{ .slice = s };
    }
    if (std.mem.eql(u8, kind, "array_type")) {
        var elem: types.Type = .{ .prim = .unit };
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            if (std.mem.eql(u8, c.kind(), "type")) {
                if (c.namedChildCount() > 0) elem = mapType(e, c.namedChild(0).?) else elem = mapType(e, c);
            }
        }
        const a = e.alloc.create(types.Array) catch return unsupportedTy();
        a.* = .{ .elem = elem, .len = .{ .literal = 0 } };
        return .{ .array = a };
    }
    if (std.mem.eql(u8, kind, "generic_type") or std.mem.eql(u8, kind, "type_identifier") or std.mem.eql(u8, kind, "scoped_type_identifier")) {
        return mapNamedType(e, node);
    }
    if (std.mem.eql(u8, kind, "tuple_type")) {
        var tup: std.ArrayListUnmanaged(types.Type) = .empty;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            tup.append(e.alloc, mapType(e, c)) catch return unsupportedTy();
        }
        if (tup.items.len == 0) return .{ .prim = .unit };
        return .{ .tuple = tup.toOwnedSlice(e.alloc) catch return unsupportedTy() };
    }
    return unsupportedTy();
}

/// A named (path) type — possibly generic `Foo<T>`, with std prelude
/// recognition (Option/Result/Box/Vec) into the dedicated IR nodes.
fn mapNamedType(e: *Ctx, node: ts.Node) types.Type {
    // Determine the base name (leaf identifier) + generic args.
    var name: ?[]const u8 = null;
    var arg_nodes: [8]ts.Node = undefined;
    var arg_count: usize = 0;

    // Find the leaf identifier(s).
    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "type_identifier") or std.mem.eql(u8, k, "identifier")) {
            name = text(e, c);
        } else if (std.mem.eql(u8, k, "type_arguments") or std.mem.eql(u8, k, "generic_type")) {
            // generic args under type_arguments
            var j: u32 = 0;
            while (c.namedChild(j)) |a| : (j += 1) {
                if (arg_count < arg_nodes.len) {
                    arg_nodes[arg_count] = a;
                    arg_count += 1;
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
        return .{
            .generic_inst = .{
                .decl = 0, // filled by name resolution (P1)
                .args = .{ .params = args },
            },
        };
    }
    // Plain path.
    var segs: std.ArrayListUnmanaged(types.PathSegment) = .empty;
    segs.append(e.alloc, .{ .name = nm, .id = null }) catch return unsupportedTy();
    return .{ .path = .{ .segments = segs.toOwnedSlice(e.alloc) catch return unsupportedTy() } };
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
            var k: u32 = 0;
            while (m.namedChild(k)) |c| : (k += 1) {
                const kk = c.kind();
                if (std.mem.eql(u8, kk, "identifier")) mname = text(e, c);
                if (std.mem.eql(u8, kk, "return_type")) {
                    if (c.namedChildCount() > 0) mret = mapType(e, c.namedChild(0).?);
                }
            }
            methods.append(e.alloc, .{
                .name = try e.alloc.dupe(u8, mname),
                .params = &.{},
                .ret = mret,
                .receiver = .ref_,
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
    var params: std.ArrayListUnmanaged(items.Param) = .empty;
    if (params_node) |pn| {
        var j: u32 = 0;
        while (pn.namedChild(j)) |p| : (j += 1) {
            if (!std.mem.eql(u8, p.kind(), "parameter")) continue;
            var pname: []const u8 = "";
            var pty: types.Type = unsupportedTy();
            var k: u32 = 0;
            while (p.namedChild(k)) |c| : (k += 1) {
                const kk = c.kind();
                if (std.mem.eql(u8, kk, "identifier")) pname = text(e, c);
                if (std.mem.eql(u8, kk, "type") or std.mem.eql(u8, kk, "primitive_type") or std.mem.eql(u8, kk, "reference_type") or std.mem.eql(u8, kk, "generic_type") or std.mem.eql(u8, kk, "type_identifier") or std.mem.eql(u8, kk, "array_type") or std.mem.eql(u8, kk, "tuple_type")) {
                    if (std.mem.eql(u8, kk, "type") and c.namedChildCount() > 0) {
                        pty = mapType(e, c.namedChild(0).?);
                    } else {
                        pty = mapType(e, c);
                    }
                }
            }
            if (pname.len == 0) continue;
            params.append(e.alloc, .{ .name = try e.alloc.dupe(u8, pname), .ty = pty, .span = span_of }) catch break;
        }
    }
    const eid = try addEntity(e, .fn_, name, parent);
    e.bodies_list.items[eid] = .{ .fn_ = .{
        .params = params.toOwnedSlice(e.alloc) catch &.{},
        .ret = ret,
        .body = 0,
    } };
}

/// Recover the full source path of a `use` declaration from its CST text:
/// "std::collections::HashMap", "crate::foo::Bar as Baz", "super::x::*".
/// The `use_tree` subtree excludes the `use` keyword, any `pub`, and the
/// terminating `;`.
fn usePathText(e: *const Ctx, item: ts.Node) []const u8 {
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        if (std.mem.eql(u8, c.kind(), "use_tree")) return text(e, c);
    }
    // Fallback: strip a leading `use` and the trailing `;` from the raw text.
    var raw = std.mem.trim(u8, text(e, item), " \t\r\n");
    if (raw.len > 0 and raw[raw.len - 1] == ';') raw = raw[0 .. raw.len - 1];
    if (std.mem.indexOf(u8, raw, "use")) |ui| raw = raw[ui + 3 ..];
    return std.mem.trim(u8, raw, " \t\r\n");
}

/// Register a `use` declaration as a UseDecl (target not resolved yet — P1).
fn useItem(e: *Ctx, item: ts.Node, parent: ?spine.EntityId) !void {
    const path_text = usePathText(e, item);
    const eid = try addEntity(e, .use_, path_text, parent);
    var last_seg: []const u8 = "";
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        if (std.mem.eql(u8, c.kind(), "identifier")) last_seg = text(e, c);
    }
    try e.g.addUse(.{
        .id = eid,
        .kind = .{ .plain = 0 }, // target resolved in P1 (names pass)
        .local_name = if (last_seg.len > 0) try e.alloc.dupe(u8, last_seg) else "",
        .is_pub_export = isPub(e, item),
        .target = 0,
        .span = span_of,
    });
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
            if (decls) |dl| {
                const child_items = try mapItemsInner(e, dl, child_id);
                e.g.modules.items[child_mod_idx].items = child_items;
            }
            try item_ids.append(e.alloc, child_id);
        } else if (std.mem.eql(u8, k, "use_declaration")) {
            try useItem(e, item, mod_id);
            try item_ids.append(e.alloc, @intCast(e.bodies_list.items.len - 1));
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
