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
const exprs = ir.exprs;
const bodies = ir.bodies;
const items = ir.items;
const names = @import("names.zig");
const exp = @import("expand.zig");
const ts = @import("tree_sitter");
const rust = @import("rust");
const ts_ext = @import("ts_ext.zig");

pub const span_of: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

pub const Ctx = struct {
    alloc: std.mem.Allocator,
    g: *graph.CrateGraph,
    src: []const u8,
    types_list: *std.ArrayListUnmanaged(types.Type),
    bodies_list: *std.ArrayListUnmanaged(bodies.BodyKind),
    exprs_list: *std.ArrayListUnmanaged(exprs.Expr),
    base_dir: ?[]const u8 = null,
    io: ?std.Io = null,
    /// In-crate `macro_rules!` definitions registered during CST extraction.
    /// Shared by the root module and every submodule so an item-level macro
    /// invocation can be expanded regardless of which file defined it.
    macro_table: ?*exp.MacroTable = null,
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

fn parseAttribute(e: *const Ctx, node: ts.Node) !spine.Attribute {
    var inner = std.mem.trim(u8, text(e, node), " \t\r\n");
    if (std.mem.startsWith(u8, inner, "#![") and std.mem.endsWith(u8, inner, "]")) {
        inner = inner[3 .. inner.len - 1];
    } else if (std.mem.startsWith(u8, inner, "#[") and std.mem.endsWith(u8, inner, "]")) {
        inner = inner[2 .. inner.len - 1];
    }
    inner = std.mem.trim(u8, inner, " \t\r\n");

    const name_end = std.mem.indexOfAny(u8, inner, "(= \t\r\n") orelse inner.len;
    const name = inner[0..name_end];
    const rest = std.mem.trim(u8, inner[name_end..], " \t\r\n");
    var meta: []const u8 = "";
    if (rest.len >= 2 and rest[0] == '(' and rest[rest.len - 1] == ')') {
        meta = std.mem.trim(u8, rest[1 .. rest.len - 1], " \t\r\n");
    } else if (rest.len > 0 and rest[0] == '=') {
        meta = std.mem.trim(u8, rest[1..], " \t\r\n");
        if (meta.len >= 2 and meta[0] == '"' and meta[meta.len - 1] == '"') {
            meta = meta[1 .. meta.len - 1];
        }
    }

    const name_copy = try e.alloc.dupe(u8, name);
    errdefer e.alloc.free(name_copy);
    const meta_copy = try e.alloc.dupe(u8, meta);
    errdefer e.alloc.free(meta_copy);
    return .{
        .name = name_copy,
        .meta = meta_copy,
        .known = std.mem.eql(u8, name, "cfg") or std.mem.eql(u8, name, "test"),
    };
}

/// Preserve outer attributes whether the grammar attaches them to the item or
/// exposes them as preceding siblings.
fn attributesOf(e: *const Ctx, item: ts.Node) ![]const spine.Attribute {
    var preceding_count: usize = 0;
    var prev = item.prevNamedSibling();
    while (prev) |node| {
        if (std.mem.eql(u8, node.kind(), "attribute_item")) {
            preceding_count += 1;
        } else if (!isComment(node)) {
            break;
        }
        prev = node.prevNamedSibling();
    }

    var child_count: usize = 0;
    var i: u32 = 0;
    while (item.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), "attribute_item")) child_count += 1;
    }

    const count = preceding_count + child_count;
    if (count == 0) return &.{};
    const attributes = try e.alloc.alloc(spine.Attribute, count);

    var preceding_index = preceding_count;
    prev = item.prevNamedSibling();
    while (prev) |node| {
        if (std.mem.eql(u8, node.kind(), "attribute_item")) {
            preceding_index -= 1;
            attributes[preceding_index] = try parseAttribute(e, node);
        } else if (!isComment(node)) {
            break;
        }
        prev = node.prevNamedSibling();
    }

    var attribute_index = preceding_count;
    i = 0;
    while (item.namedChild(i)) |child| : (i += 1) {
        if (!std.mem.eql(u8, child.kind(), "attribute_item")) continue;
        attributes[attribute_index] = try parseAttribute(e, child);
        attribute_index += 1;
    }
    return attributes;
}
fn duplicateAttributes(e: *const Ctx, source: []const spine.Attribute) ![]const spine.Attribute {
    if (source.len == 0) return &.{};
    const result = try e.alloc.alloc(spine.Attribute, source.len);
    errdefer e.alloc.free(result);

    var initialized_count: usize = 0;
    errdefer {
        for (result[0..initialized_count]) |attribute| {
            e.alloc.free(attribute.name);
            e.alloc.free(attribute.meta);
        }
    }

    for (source, 0..) |attribute, index| {
        const name_copy = try e.alloc.dupe(u8, attribute.name);
        errdefer e.alloc.free(name_copy);
        const meta_copy = try e.alloc.dupe(u8, attribute.meta);
        errdefer e.alloc.free(meta_copy);
        result[index] = .{
            .name = name_copy,
            .meta = meta_copy,
            .known = attribute.known,
        };
        initialized_count += 1;
    }
    return result;
}

/// Append a symbol-table entity + matching `.none` body slot. Source-backed
/// entities take their visibility and attributes from the CST item; synthetic
/// entities retain the existing public, attribute-free representation.
fn addEntity(
    e: *Ctx,
    kind: spine.EntityKind,
    name: []const u8,
    parent: ?spine.EntityId,
    source_item: ?ts.Node,
) !spine.EntityId {
    const id = try e.g.symbol_table.add(.{
        .id = 0,
        .kind = kind,
        .name = try e.alloc.dupe(u8, name),
        .span = span_of,
        .visibility = if (source_item) |item| visOf(e, item) else .public,
        .parent = parent,
        .resolved = null,
        .renamed_to = null,
        .attributes = if (source_item) |item| try attributesOf(e, item) else &.{},
    });
    try e.bodies_list.append(e.alloc, .none);
    return id;
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

fn isSliceTypeNode(node: ts.Node) bool {
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "slice_type")) return true;
    if (!std.mem.eql(u8, kind, "array_type")) return false;

    var i: u32 = 0;
    while (node.child(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), ";")) return false;
    }
    return true;
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
            if (isSliceTypeNode(inn)) {
                var elem: types.Type = .{ .prim = .unit };
                if (inn.namedChildCount() > 0) elem = mapType(e, inn.namedChild(0).?);
                const s = e.alloc.create(types.Slice) catch return unsupportedTy();
                s.* = .{ .const_ = !mut, .elem = elem };
                return .{ .slice = s };
            }
            if (std.mem.eql(u8, inn.kind(), "primitive_type") and std.mem.eql(u8, text(e, inn), "str")) {
                const s = e.alloc.create(types.Slice) catch return unsupportedTy();
                s.* = .{ .const_ = !mut, .elem = .{ .prim = .u8 } };
                return .{ .slice = s };
            }
            if (std.mem.eql(u8, inn.kind(), "array_type")) return mapType(e, inn);
            const r = e.alloc.create(types.Ref) catch return unsupportedTy();
            r.* = .{ .mut = mut, .pointee = mapType(e, inn) };
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
        if (node.namedChild(0)) |elem_node| elem = mapType(e, elem_node);
        if (isSliceTypeNode(node)) {
            const s = e.alloc.create(types.Slice) catch return unsupportedTy();
            s.* = .{ .const_ = true, .elem = elem };
            return .{ .slice = s };
        }

        var len_lit: u32 = 0;
        if (node.namedChild(1)) |len_node| {
            if (std.mem.eql(u8, len_node.kind(), "integer_literal")) {
                len_lit = std.fmt.parseInt(u32, text(e, len_node), 10) catch 0;
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
/// Return the type node attached to a function's `return_type` field.
///
/// Tree-sitter exposes `return_type` as a field name on `function_item` and
/// `function_signature_item`; it does not normally create a node whose kind is
/// `"return_type"`. Keep the named-child fallback for older grammar versions.
fn returnTypeNode(node: ts.Node) ?ts.Node {
    if (node.childByFieldName("return_type")) |ret| return ret;
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), "return_type")) {
            if (child.namedChildCount() > 0) return child.namedChild(0);
            return child;
        }
    }
    return null;
}

fn mapReturnType(e: *Ctx, node: ts.Node) types.Type {
    const ret = returnTypeNode(node) orelse return .{ .prim = .unit };
    return mapType(e, ret);
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
    if (name == null and segs.items.len > 0) {
        name = segs.items[segs.items.len - 1].name;
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
            base_def = addEntity(e, .struct_, nm, 0, null) catch 0;
        }
        return .{
            .generic_inst = .{
                .decl = base_def,
                .args = .{ .params = args },
            },
        };
    }
    if (segs.items.len == 0 or !std.mem.eql(u8, segs.items[segs.items.len - 1].name, nm)) {
        segs.append(e.alloc, .{ .name = nm, .id = null }) catch return unsupportedTy();
    }
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

fn collectFunctionGenericParams(e: *Ctx, item: ts.Node) ![]const []const u8 {
    var params: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: u32 = 0;
    while (item.namedChild(i)) |child| : (i += 1) {
        if (!std.mem.eql(u8, child.kind(), "type_parameters")) continue;

        var j: u32 = 0;
        while (child.namedChild(j)) |parameter| : (j += 1) {
            if (!std.mem.eql(u8, parameter.kind(), "type_parameter")) continue;

            var name: []const u8 = "";
            var k: u32 = 0;
            while (parameter.namedChild(k)) |parameter_child| : (k += 1) {
                if (std.mem.eql(u8, parameter_child.kind(), "type_identifier")) {
                    name = text(e, parameter_child);
                    break;
                }
            }
            if (name.len == 0) continue;
            try params.append(e.alloc, try e.alloc.dupe(u8, name));
        }
    }
    return params.toOwnedSlice(e.alloc);
}

// ── item lowering ────────────────────────────────────────────────────────────

/// Resolve the field list type for a field_declaration / ordered_field_list.
fn mapFields(e: *Ctx, node: ts.Node) []const items.Field {
    var fields: std.ArrayListUnmanaged(items.Field) = .empty;
    if (std.mem.eql(u8, node.kind(), "ordered_field_declaration_list")) {
        var visibility: spine.Visibility = .private;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            if (std.mem.eql(u8, c.kind(), "visibility_modifier")) {
                visibility = .public;
                continue;
            }
            const field_name = node.fieldNameForNamedChild(i) orelse continue;
            if (!std.mem.eql(u8, field_name, "type")) continue;

            const nm = allocPrintOrEmpty(e, "{d}", .{fields.items.len});
            fields.append(e.alloc, .{
                .name = nm,
                .ty = mapType(e, c),
                .visibility = visibility,
                .span = span_of,
            }) catch break;
            visibility = .private;
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
    var generic_params: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "type_identifier")) name = text(e, c);
        if (std.mem.eql(u8, k, "type_parameters")) {
            var j: u32 = 0;
            while (c.namedChild(j)) |tp| : (j += 1) {
                const tp_k = tp.kind();
                if (std.mem.eql(u8, tp_k, "type_identifier")) {
                    try generic_params.append(e.alloc, try e.alloc.dupe(u8, text(e, tp)));
                } else if (std.mem.eql(u8, tp_k, "type_parameter") or std.mem.eql(u8, tp_k, "const_parameter")) {
                    var m: u32 = 0;
                    while (tp.namedChild(m)) |tpc| : (m += 1) {
                        if (std.mem.eql(u8, tpc.kind(), "type_identifier")) {
                            try generic_params.append(e.alloc, try e.alloc.dupe(u8, text(e, tpc)));
                            break;
                        }
                    }
                }
            }
        }
        if (std.mem.eql(u8, k, "field_declaration_list")) fields_node = c;
        if (std.mem.eql(u8, k, "ordered_field_declaration_list")) {
            fields_node = c;
            tuple = true;
        }
    }
    const eid = try addEntity(e, .struct_, name, parent, item);
    const fields = if (fields_node) |fn_| mapFields(e, fn_) else &.{};
    const layout: items.struct_kind = if (fields.len == 0) .unit else if (tuple) .tuple else .named;
    e.bodies_list.items[eid] = .{ .struct_ = .{
        .generic_params = try generic_params.toOwnedSlice(e.alloc),
        .layout = layout,
        .fields = fields,
        .methods = &.{},
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
    const eid = try addEntity(e, .enum_, name, parent, item);
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
    const eid = try addEntity(e, .union_, name, parent, item);
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
    const eid = try addEntity(e, .trait_, name, parent, item);
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
            }
            mret = mapReturnType(e, m);
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
    const eid = try addEntity(e, .type_alias, name, parent, item);
    e.bodies_list.items[eid] = .{ .type_alias = .{ .target = target } };
}

fn appendType(e: *Ctx, t: types.Type) !exprs.TypeId {
    const id: exprs.TypeId = @intCast(e.types_list.items.len);
    try e.types_list.append(e.alloc, t);
    return id;
}

/// Append an expression node, returning its dense NodeId.
fn appendExpr(e: *Ctx, kind: exprs.ExprKind) !exprs.NodeId {
    const id: exprs.NodeId = @intCast(e.exprs_list.items.len);
    try e.exprs_list.append(e.alloc, .{
        .id = id,
        .span = span_of,
        .ty = null,
        .kind = kind,
    });
    return id;
}

/// Rust integer-literal type suffixes, longest first (so `u128` beats `u8`).
const int_suffixes = [_][]const u8{ "i128", "i64", "i32", "i16", "i8", "u128", "u64", "u32", "u16", "u8", "isize", "usize" };

/// Strip a digit suffix (`0x88u8` → `0x88`) so the numeric body parses.
fn stripIntSuffix(body: []const u8) []const u8 {
    for (int_suffixes) |s| {
        if (body.len > s.len and std.mem.endsWith(u8, body, s)) {
            const pre = body[0 .. body.len - s.len];
            if (pre.len == 0) continue;
            const last = pre[pre.len - 1];
            if (std.ascii.isDigit(last) or last == '_') return pre;
        }
    }
    return body;
}

/// Element type carried by a (possibly reference/pointer-wrapped) array type.
fn arrayElemTy(ty: types.Type) ?types.Type {
    return switch (ty) {
        .array => |a| a.elem,
        .reference => |r| arrayElemTy(r.pointee),
        .raw_ptr => |p| arrayElemTy(p.pointee),
        .slice => |s| s.elem,
        else => null,
    };
}

fn hexDigit(value: u8) ?u8 {
    if (value >= '0' and value <= '9') return value - '0';
    if (value >= 'a' and value <= 'f') return value - 'a' + 10;
    if (value >= 'A' and value <= 'F') return value - 'A' + 10;
    return null;
}

fn decodeEscapedBytes(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(allocator);

    var i: usize = 0;
    while (i < body.len) {
        const current = body[i];
        if (current != '\\') {
            try bytes.append(allocator, current);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= body.len) return error.InvalidLiteral;
        const escaped = body[i];
        switch (escaped) {
            'n' => try bytes.append(allocator, '\n'),
            'r' => try bytes.append(allocator, '\r'),
            't' => try bytes.append(allocator, '\t'),
            '0' => try bytes.append(allocator, 0),
            '\\' => try bytes.append(allocator, '\\'),
            '"' => try bytes.append(allocator, '"'),
            '\'' => try bytes.append(allocator, '\''),
            'x' => {
                if (i + 2 >= body.len) return error.InvalidLiteral;
                const high = hexDigit(body[i + 1]) orelse return error.InvalidLiteral;
                const low = hexDigit(body[i + 2]) orelse return error.InvalidLiteral;
                try bytes.append(allocator, high * 16 + low);
                i += 2;
            },
            '\n' => {},
            '\r' => {
                if (i + 1 < body.len and body[i + 1] == '\n') i += 1;
            },
            else => return error.InvalidLiteral,
        }
        i += 1;
    }
    return bytes.toOwnedSlice(allocator);
}

fn decodeRawBytes(allocator: std.mem.Allocator, raw: []const u8, prefix_len: usize) !?[]const u8 {
    var marker = prefix_len;
    var hash_count: usize = 0;
    while (marker < raw.len and raw[marker] == '#') : (marker += 1) {
        hash_count += 1;
    }
    if (marker >= raw.len or raw[marker] != '"') return null;
    const body_start = marker + 1;
    if (raw.len < body_start + hash_count + 1) return null;
    const close_start = raw.len - hash_count - 1;
    if (close_start < body_start or raw[close_start] != '"') return null;
    var i: usize = 0;
    while (i < hash_count) : (i += 1) {
        if (raw[close_start + 1 + i] != '#') return null;
    }
    const bytes = try allocator.dupe(u8, raw[body_start..close_start]);
    return bytes;
}

/// Decode Rust byte strings (`b"..."`, `br#"..."#`) and byte characters.
/// A null result means that `raw` is not a byte literal.
fn decodeRustByteLiteral(allocator: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    if (std.mem.startsWith(u8, raw, "br")) return decodeRawBytes(allocator, raw, 2);
    if (!std.mem.startsWith(u8, raw, "b")) return null;
    const prefix_len: usize = 1;
    if (prefix_len >= raw.len) return null;

    const quote = raw[prefix_len];
    if (quote == '\'') {
        if (raw.len < prefix_len + 3) return null;
        if (raw[raw.len - 1] != '\'') return null;
        const bytes = try decodeEscapedBytes(allocator, raw[prefix_len + 1 .. raw.len - 1]);
        if (bytes.len == 1) return bytes;
        allocator.free(bytes);
        return null;
    }
    if (quote != '"' or raw.len < prefix_len + 2 or raw[raw.len - 1] != '"') return null;
    const bytes = try decodeEscapedBytes(allocator, raw[prefix_len + 1 .. raw.len - 1]);
    return bytes;
}

/// Lower a string / byte-string const literal. Bytes are decoded before they
/// enter the IR, so the emitter never sees Rust prefixes or escape sequences.
fn lowerConstString(e: *Ctx, node: ts.Node) ?exprs.NodeId {
    const raw = text(e, node);
    const kind = node.kind();
    const is_byte = std.mem.eql(u8, kind, "byte_string_literal") or
        std.mem.eql(u8, kind, "byte_literal") or
        std.mem.startsWith(u8, raw, "b");
    if (decodeRustByteLiteral(e.alloc, raw) catch null) |bytes| {
        return appendExpr(e, .{ .literal = .{ .byte_array = .{ .items = bytes } } }) catch null;
    }
    if (is_byte) return null;
    var s = raw;
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s = s[1 .. s.len - 1];
    const bytes = e.alloc.dupe(u8, s) catch return null;
    return appendExpr(e, .{ .literal = .{ .string = .{ .bytes = bytes } } }) catch null;
}

fn lowerConstArray(e: *Ctx, node: ts.Node) ?exprs.NodeId {
    // Repeating form `[e; N]` exposes a `length` field; the element node may
    // or may not carry an `element` field (grammar-dependent), so fall back to
    // the remaining named child when it is missing.
    if (node.childByFieldName("length")) |len_node| {
        var elem: ?ts.Node = node.childByFieldName("element");
        if (elem == null) {
            var i: u32 = 0;
            while (node.namedChild(i)) |c| : (i += 1) {
                if (c.eql(len_node)) continue;
                elem = c;
                break;
            }
        }
        const en = elem orelse return null;
        const elem_id = lowerConstInit(e, en) orelse return null;
        const len = std.fmt.parseInt(usize, text(e, len_node), 10) catch 0;
        var elems: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
        defer elems.deinit(e.alloc);
        elems.append(e.alloc, elem_id) catch return null;
        return appendExpr(e, .{ .array = .{
            .elements = elems.toOwnedSlice(e.alloc) catch return null,
            .repeat = len,
        } }) catch null;
    }
    // Explicit list `[a, b, c]`.
    var elements: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
    defer elements.deinit(e.alloc);
    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        if (isComment(c)) continue;
        const eid = lowerConstInit(e, c) orelse continue;
        elements.append(e.alloc, eid) catch return null;
    }
    if (elements.items.len == 0) return null;
    return appendExpr(e, .{ .array = .{
        .elements = elements.toOwnedSlice(e.alloc) catch return null,
        .repeat = null,
    } }) catch null;
}

/// Parsed integer text, with the Rust-only suffix separated from the digits.
const ParsedConstInt = struct {
    value: i128,
    base: u8,
    body: []const u8,
    suffix: []const u8,
};

fn parseConstIntText(raw: []const u8) ?ParsedConstInt {
    const body = stripIntSuffix(raw);
    if (body.len == 0) return null;
    const base: u8 = if (body.len > 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'X'))
        16
    else if (body.len > 2 and body[0] == '0' and (body[1] == 'b' or body[1] == 'B'))
        2
    else if (body.len > 2 and body[0] == '0' and (body[1] == 'o' or body[1] == 'O'))
        8
    else
        10;
    const digits = if (base != 10) body[2..] else body;
    const value = std.fmt.parseInt(i128, digits, base) catch return null;
    return .{
        .value = value,
        .base = base,
        .body = body,
        .suffix = raw[body.len..],
    };
}

fn constOperator(e: *const Ctx, left: ts.Node, right: ts.Node) []const u8 {
    const start = left.endByte();
    const end = right.startByte();
    if (end <= start) return "";
    return std.mem.trim(u8, e.src[start..end], " \t\r\n");
}

/// Evaluate the integer-only subset needed by Rust const initializers.
fn constIntegerValue(e: *const Ctx, node: ts.Node) ?i128 {
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "integer_literal")) {
        return (parseConstIntText(text(e, node)) orelse return null).value;
    }
    if (std.mem.eql(u8, kind, "expression") or
        std.mem.eql(u8, kind, "parenthesized_expression") or
        std.mem.eql(u8, kind, "reference_expression") or
        std.mem.eql(u8, kind, "unsafe_expression") or
        std.mem.eql(u8, kind, "type_cast_expression"))
    {
        if (node.namedChildCount() == 0) return null;
        return constIntegerValue(e, node.namedChild(0).?);
    }
    if (std.mem.eql(u8, kind, "unary_expression")) {
        if (node.namedChildCount() == 0) return null;
        const operand = node.namedChild(node.namedChildCount() - 1).?;
        const value = constIntegerValue(e, operand) orelse return null;
        const raw = text(e, node);
        const op_len = operand.startByte() - node.startByte();
        const op = std.mem.trim(u8, raw[0..op_len], " \t\r\n");
        if (std.mem.eql(u8, op, "-")) return -%value;
        if (std.mem.eql(u8, op, "+")) return value;
        if (std.mem.eql(u8, op, "!")) return ~value;
        return null;
    }
    if (std.mem.eql(u8, kind, "binary_expression")) {
        if (node.namedChildCount() < 2) return null;
        const left = node.namedChild(0).?;
        const right = node.namedChild(node.namedChildCount() - 1).?;
        const lhs = constIntegerValue(e, left) orelse return null;
        const rhs = constIntegerValue(e, right) orelse return null;
        const op = constOperator(e, left, right);
        if (std.mem.eql(u8, op, "+")) return lhs +% rhs;
        if (std.mem.eql(u8, op, "-")) return lhs -% rhs;
        if (std.mem.eql(u8, op, "*")) return lhs *% rhs;
        if (std.mem.eql(u8, op, "/")) {
            if (rhs == 0) return null;
            return @divTrunc(lhs, rhs);
        }
        if (std.mem.eql(u8, op, "%")) {
            if (rhs == 0) return null;
            return @mod(lhs, rhs);
        }
        if (std.mem.eql(u8, op, "&")) return lhs & rhs;
        if (std.mem.eql(u8, op, "|")) return lhs | rhs;
        if (std.mem.eql(u8, op, "^")) return lhs ^ rhs;
        if (std.mem.eql(u8, op, "<<") or std.mem.eql(u8, op, ">>")) {
            if (rhs < 0 or rhs >= 128) return null;
            const shift: u7 = @intCast(rhs);
            if (std.mem.eql(u8, op, "<<")) return lhs << shift;
            return lhs >> shift;
        }
    }
    return null;
}

/// Lower a const initializer expression into the expr table. Returns null when
/// the form is not representable (the const keeps its `undefined` fallback).
fn lowerConstInit(e: *Ctx, node: ts.Node) ?exprs.NodeId {
    const kind = node.kind();
    // Semantic-neutral wrappers for a const value, including Rust casts. The
    // cast type is deliberately ignored: the declared const type carries it.
    if (std.mem.eql(u8, kind, "expression") or
        std.mem.eql(u8, kind, "parenthesized_expression") or
        std.mem.eql(u8, kind, "reference_expression") or
        std.mem.eql(u8, kind, "unsafe_expression") or
        std.mem.eql(u8, kind, "type_cast_expression"))
    {
        if (node.namedChildCount() > 0) return lowerConstInit(e, node.namedChild(0).?);
        return null;
    }
    if (std.mem.eql(u8, kind, "array_expression")) return lowerConstArray(e, node);
    if (std.mem.eql(u8, kind, "integer_literal")) {
        const t = text(e, node);
        const parsed = parseConstIntText(t) orelse return null;
        const suffix = if (parsed.suffix.len == 0)
            null
        else
            e.alloc.dupe(u8, parsed.suffix) catch return null;
        return appendExpr(e, .{ .literal = .{ .int = .{
            .text = e.alloc.dupe(u8, parsed.body) catch return null,
            .value = parsed.value,
            .base = if (parsed.base == 16) .hex else if (parsed.base == 2) .bin else if (parsed.base == 8) .oct else .dec,
            .ty_suffix = suffix,
        } } }) catch null;
    }
    if (std.mem.eql(u8, kind, "binary_expression") or std.mem.eql(u8, kind, "unary_expression")) {
        const value = constIntegerValue(e, node) orelse return null;
        const number = std.fmt.allocPrint(e.alloc, "{d}", .{value}) catch return null;
        return appendExpr(e, .{ .literal = .{ .int = .{
            .text = number,
            .value = value,
            .base = .dec,
            .ty_suffix = null,
        } } }) catch null;
    }
    if (std.mem.eql(u8, kind, "float_literal")) {
        const t = text(e, node);
        return appendExpr(e, .{ .literal = .{ .float = .{
            .text = e.alloc.dupe(u8, t) catch return null,
            .value = std.fmt.parseFloat(f64, t) catch 0.0,
        } } }) catch null;
    }
    if (std.mem.eql(u8, kind, "char_literal") or std.mem.eql(u8, kind, "byte_literal")) {
        const t = text(e, node);
        const is_byte = std.mem.eql(u8, kind, "byte_literal") or std.mem.startsWith(u8, t, "b");
        if (decodeRustByteLiteral(e.alloc, t) catch null) |bytes| {
            return appendExpr(e, .{ .literal = .{ .byte_array = .{ .items = bytes } } }) catch null;
        }
        if (is_byte) return null;
        var val: u32 = 0;
        if (t.len >= 3 and t[0] == '\'' and t[t.len - 1] == '\'') val = t[1];
        return appendExpr(e, .{ .literal = .{ .character = .{
            .text = e.alloc.dupe(u8, t) catch return null,
            .value = val,
        } } }) catch null;
    }
    if (std.mem.eql(u8, kind, "boolean_literal")) {
        return appendExpr(e, .{ .literal = .{ .boolean = std.mem.eql(u8, text(e, node), "true") } }) catch null;
    }
    if (std.mem.eql(u8, kind, "string_literal") or
        std.mem.eql(u8, kind, "byte_string_literal") or
        std.mem.eql(u8, kind, "raw_string_literal"))
    {
        return lowerConstString(e, node);
    }
    return null;
}

fn constItem(e: *Ctx, item: ts.Node, parent: ?spine.EntityId) !void {
    var name: []const u8 = "";
    var ty: types.Type = unsupportedTy();
    var init_node: ?ts.Node = null;
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "identifier")) {
            name = text(e, c);
            continue;
        }
        if (std.mem.eql(u8, k, "visibility_modifier") or std.mem.eql(u8, k, "attribute_item")) continue;
        if (std.mem.eql(u8, k, "primitive_type") or std.mem.eql(u8, k, "generic_type") or std.mem.eql(u8, k, "type_identifier") or std.mem.eql(u8, k, "array_type") or std.mem.eql(u8, k, "reference_type") or std.mem.eql(u8, k, "pointer_type")) {
            ty = mapType(e, c);
            continue;
        }
        // Any other named child is the initializer expression.
        if (init_node == null) init_node = c;
    }
    const eid = try addEntity(e, .const_, name, parent, item);
    e.bodies_list.items[eid] = .{ .const_ = .{ .ty = ty, .init = 0 } };

    if (init_node) |in| {
        if (lowerConstInit(e, in)) |init_id| {
            const cb = &e.bodies_list.items[eid].const_;
            cb.init = init_id;
            // Carry the element type onto an array constant so the backend can
            // render `[_]T{ ... }` / `[_]T{ e } ** N`.
            if (arrayElemTy(cb.ty)) |elem| {
                if (e.exprs_list.items[init_id].kind == .array) {
                    const tid = try appendType(e, elem);
                    e.exprs_list.items[init_id].ty = tid;
                }
            }
        }
    }
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
    }
    ret = mapReturnType(e, item);
    const params = mapParams(e, params_node);
    const generic_params = try collectFunctionGenericParams(e, item);
    const eid = try addEntity(e, .fn_, name, parent, item);
    e.bodies_list.items[eid] = .{ .fn_ = .{
        .params = params,
        .ret = ret,
        .generic_params = generic_params,
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
    const eid = try addEntity(e, .use_, full_path, parent, null);
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
    const first_id = item_ids.items.len;
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        if (std.mem.eql(u8, c.kind(), "visibility_modifier")) continue;
        try processUseClause(e, c, "", is_pub, parent, item_ids);
    }
    for (item_ids.items[first_id..]) |id| {
        e.g.symbol_table.entities.items[id].visibility = visOf(e, item);
        e.g.symbol_table.entities.items[id].attributes = try attributesOf(e, item);
    }
}
fn implItem(e: *Ctx, item: ts.Node, mod_id: spine.EntityId) !spine.EntityId {
    var self_ty_name: []const u8 = "";
    var trait_name: ?[]const u8 = null;
    var decl_list: ?ts.Node = null;

    if (item.childByFieldName("trait")) |tn| {
        trait_name = text(e, tn);
    }
    if (item.childByFieldName("type")) |tn| {
        self_ty_name = text(e, tn);
    }
    if (item.childByFieldName("body")) |bn| {
        decl_list = bn;
    }

    if (self_ty_name.len == 0 or decl_list == null) {
        var i: u32 = 0;
        while (item.namedChild(i)) |c| : (i += 1) {
            const k = c.kind();
            if (std.mem.eql(u8, k, "type_identifier") or std.mem.eql(u8, k, "generic_type") or std.mem.eql(u8, k, "primitive_type") or std.mem.eql(u8, k, "scoped_type_identifier") or std.mem.eql(u8, k, "type_path")) {
                if (self_ty_name.len == 0) {
                    self_ty_name = text(e, c);
                } else if (trait_name == null) {
                    trait_name = self_ty_name;
                    self_ty_name = text(e, c);
                }
            } else if (std.mem.eql(u8, k, "declaration_list")) {
                if (decl_list == null) decl_list = c;
            }
        }
    }

    var target_name = std.mem.trim(u8, self_ty_name, " &*");
    if (std.mem.startsWith(u8, target_name, "mut ")) {
        target_name = target_name[4..];
    }
    if (std.mem.indexOf(u8, target_name, "<")) |idx| {
        target_name = target_name[0..idx];
    }
    if (std.mem.lastIndexOf(u8, target_name, "::")) |idx| {
        target_name = target_name[idx + 2 ..];
    }
    target_name = std.mem.trim(u8, target_name, " ");

    var target_id: ?spine.EntityId = null;
    for (e.g.symbol_table.entities.items) |ent| {
        if ((ent.kind == .struct_ or ent.kind == .enum_ or ent.kind == .union_) and std.mem.eql(u8, ent.name, target_name)) {
            if (ent.parent == mod_id or target_id == null) {
                target_id = ent.id;
            }
        }
    }

    const name = if (trait_name) |tr|
        try std.fmt.allocPrint(e.alloc, "{s} for {s}", .{ tr, self_ty_name })
    else
        try e.alloc.dupe(u8, self_ty_name);

    // Both inherent impls (`impl Type { ... }`) and trait impls
    // (`impl Trait for Type { ... }`) parent their methods to the resolved
    // target struct, allowing the backend to hoist the methods there.
    const impl_parent = target_id orelse mod_id;
    const impl_id = try addEntity(e, .impl_, name, impl_parent, item);

    if (decl_list) |dl| {
        var j: u32 = 0;
        while (dl.namedChild(j)) |child| : (j += 1) {
            if (std.mem.eql(u8, child.kind(), "function_item")) {
                // Parent the method entity on the impl block (matching the
                // model reference) so the backend's collectHoistedMethods can
                // resolve impl -> target struct and hoist the method there.
                // The method is also registered on the target's StructBody
                // below; the backend dedups the two paths by method name.
                try functionItem(e, child, impl_id, false);

                if (target_id) |tid| {
                    if (tid < e.bodies_list.items.len) {
                        switch (e.bodies_list.items[tid]) {
                            .struct_ => |*sb| {
                                var mname: []const u8 = "";
                                var mparams_node: ?ts.Node = null;
                                var mret: types.Type = .{ .prim = .unit };
                                var k: u32 = 0;
                                while (child.namedChild(k)) |c| : (k += 1) {
                                    const kk = c.kind();
                                    if (std.mem.eql(u8, kk, "identifier")) mname = text(e, c);
                                    if (std.mem.eql(u8, kk, "parameters")) mparams_node = c;
                                }
                                mret = mapReturnType(e, child);
                                const generic_params = try collectFunctionGenericParams(e, child);

                                const all_params = mapParams(e, mparams_node);
                                var receiver: ?items.Receiver = null;
                                var method_params: []const items.Param = all_params;

                                if (mparams_node) |pn| {
                                    var pi: u32 = 0;
                                    while (pn.namedChild(pi)) |p| : (pi += 1) {
                                        if (std.mem.eql(u8, p.kind(), "self_parameter")) {
                                            const p_text = text(e, p);
                                            if (std.mem.indexOf(u8, p_text, "&mut") != null) {
                                                receiver = .mut_ref;
                                            } else if (std.mem.indexOf(u8, p_text, "&") != null) {
                                                receiver = .ref_;
                                            } else {
                                                receiver = .owned;
                                            }
                                            break;
                                        }
                                    }
                                }
                                if (receiver == null and all_params.len > 0 and std.mem.eql(u8, all_params[0].name, "self")) {
                                    if (all_params[0].ty == .reference) {
                                        if (all_params[0].ty.reference.*.mut) {
                                            receiver = .mut_ref;
                                        } else {
                                            receiver = .ref_;
                                        }
                                    } else {
                                        receiver = .owned;
                                    }
                                }
                                if (receiver != null and all_params.len > 0 and std.mem.eql(u8, all_params[0].name, "self")) {
                                    method_params = all_params[1..];
                                }

                                var method_exists = false;
                                for (sb.methods) |existing_m| {
                                    if (std.mem.eql(u8, existing_m.name, mname)) {
                                        method_exists = true;
                                        break;
                                    }
                                }

                                if (!method_exists) {
                                    const vis: spine.Visibility = if (trait_name != null) .public else visOf(e, child);
                                    const sm: bodies.StructMethod = .{
                                        .name = try e.alloc.dupe(u8, mname),
                                        .visibility = vis,
                                        .params = method_params,
                                        .ret = mret,
                                        .generic_params = generic_params,
                                        .body = 0,
                                        .receiver = receiver,
                                        .is_allocating = false,
                                    };
                                    const old_methods = sb.methods;
                                    const new_methods = try e.alloc.alloc(bodies.StructMethod, old_methods.len + 1);
                                    @memcpy(new_methods[0..old_methods.len], old_methods);
                                    new_methods[old_methods.len] = sm;
                                    sb.methods = new_methods;
                                }
                            },
                            else => {},
                        }
                    }
                }
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

/// Extract the value of a `#[path = "..."]` attribute (path or not) from an
/// attribute's raw text slice. Handles `#[path = "x"], `#[ path = "x" ]`,
/// raw strings, and returns null when no path attribute is present.
fn extractPathFromAttrText(attr_text: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < attr_text.len) {
        if (std.mem.startsWith(u8, attr_text[i..], "path")) {
            const prev_ok = if (i == 0) true else blk: {
                const previous = attr_text[i - 1];
                break :blk !std.ascii.isAlphanumeric(previous) and previous != '_';
            };
            const next_idx = i + 4;
            const next_ok = (next_idx >= attr_text.len or !std.ascii.isAlphanumeric(attr_text[next_idx]) and attr_text[next_idx] != '_');
            if (prev_ok and next_ok) {
                var eq_idx = next_idx;
                while (eq_idx < attr_text.len and (attr_text[eq_idx] == ' ' or attr_text[eq_idx] == '\t')) : (eq_idx += 1) {}
                if (eq_idx < attr_text.len and attr_text[eq_idx] == '=') {
                    var quote_start = eq_idx + 1;
                    while (quote_start < attr_text.len and
                        (attr_text[quote_start] == ' ' or attr_text[quote_start] == '\t' or
                            attr_text[quote_start] == 'r' or attr_text[quote_start] == '#'))
                    {
                        if (attr_text[quote_start] == '"') break;
                        quote_start += 1;
                    }
                    if (quote_start < attr_text.len and attr_text[quote_start] == '"') {
                        const str_start = quote_start + 1;
                        if (std.mem.indexOfScalar(u8, attr_text[str_start..], '"')) |len| {
                            return attr_text[str_start .. str_start + len];
                        }
                    }
                }
            }
        }
        i += 1;
    }
    return null;
}

/// Find a `#[path = "..."]` attribute on a `mod_item`. The attribute may be a
/// child of the item or a preceding sibling of it.
fn extractPathAttr(e: *const Ctx, item: ts.Node) ?[]const u8 {
    var j: u32 = 0;
    while (item.namedChild(j)) |c| : (j += 1) {
        if (std.mem.eql(u8, c.kind(), "attribute_item")) {
            if (extractPathFromAttrText(text(e, c))) |p| return p;
        }
    }
    var prev = item.prevNamedSibling();
    while (prev) |pnode| {
        if (std.mem.eql(u8, pnode.kind(), "attribute_item")) {
            if (extractPathFromAttrText(text(e, pnode))) |p| return p;
            prev = pnode.prevNamedSibling();
        } else {
            break;
        }
    }
    return null;
}

/// Derive the directory used to resolve a file module's children from the
/// module file that was actually selected. `mod.rs` keeps its containing
/// directory; every other file gets a sibling directory named after the
/// module. This preserves nested layouts for both conventional and
/// `#[path = "..."]` modules.
fn childModuleBaseDir(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    module_name: []const u8,
) ![]const u8 {
    const source_dir = std.fs.path.dirname(source_path) orelse ".";
    const source_name = std.fs.path.basename(source_path);
    if (std.mem.eql(u8, source_name, "mod.rs")) {
        return allocator.dupe(u8, source_dir);
    }
    return std.fs.path.join(allocator, &.{ source_dir, module_name });
}

/// Register a `macro_rules! name { … }` definition into the shared macro
/// table so item-level invocations can be expanded later in this pass.
fn registerMacroDefinition(e: *Ctx, item: ts.Node) !void {
    const table = e.macro_table orelse return;
    const raw_def = text(e, item);
    const def = (try exp.parseMacroRulesDefinition(e.alloc, raw_def)) orelse return;
    try table.register(def.name, def);
}

/// Expand an item-level `name!(…);` invocation when the named macro was
/// defined in-crate. The expanded Rust source is re-parsed and its generated
/// items are ingested into the current module (so `impl_integer!(i8, i16… )`
/// produces real impl blocks instead of being dropped).
fn expandMacroInvocationItems(
    e: *Ctx,
    item: ts.Node,
    mod_id: spine.EntityId,
    item_ids: *std.ArrayListUnmanaged(spine.EntityId),
) anyerror!void {
    const table = e.macro_table orelse return;
    var mname: ?[]const u8 = null;
    var token_tree_node: ?ts.Node = null;
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        const ck = c.kind();
        if (std.mem.eql(u8, ck, "identifier") or std.mem.eql(u8, ck, "scoped_identifier")) {
            if (mname == null) mname = text(e, c);
        } else if (std.mem.eql(u8, ck, "token_tree")) {
            token_tree_node = c;
        }
    }
    const name = mname orelse return;
    const raw_args = if (token_tree_node) |tt| text(e, tt) else "";
    const def = (table.get(name)) orelse return;

    const expanded = try exp.expandMacroRules(e.alloc, def, raw_args) orelse return;
    defer e.alloc.free(expanded);

    // Re-parse the expanded source and ingest any generated top-level items.
    var parser = ts.Parser.create();
    defer parser.destroy();
    if (parser.setLanguage(rust.language())) |_| {} else |_| {}
    const tree = parser.parseString(expanded, null) orelse return;
    defer tree.destroy();

    var exp_ctx: Ctx = .{
        .alloc = e.alloc,
        .g = e.g,
        .src = expanded,
        .types_list = e.types_list,
        .bodies_list = e.bodies_list,
        .exprs_list = e.exprs_list,
        .base_dir = e.base_dir,
        .io = e.io,
        .macro_table = e.macro_table,
    };
    const generated = try mapItemsInner(&exp_ctx, tree.rootNode(), mod_id);
    try item_ids.appendSlice(e.alloc, generated);
}

/// Like mapItems but returns the item id list (for a nested module).
fn mapItemsInner(e: *Ctx, node: ts.Node, mod_id: spine.EntityId) ![]const spine.EntityId {
    var item_ids: std.ArrayListUnmanaged(spine.EntityId) = .empty;
    var i: u32 = 0;
    while (node.namedChild(i)) |item| : (i += 1) {
        if (isComment(item)) continue;
        // An item-level macro invocation is wrapped in an expression_statement
        // node (e.g. `name!(...);`); descend into it so the following branch
        // sees the `macro_invocation` child directly.
        var item2 = item;
        if (std.mem.eql(u8, item.kind(), "expression_statement")) {
            const mi = item.namedChild(0) orelse continue;
            if (std.mem.eql(u8, mi.kind(), "macro_invocation")) {
                item2 = mi;
            }
        }
        const k = item2.kind();
        if (std.mem.eql(u8, k, "mod_item")) {
            var mname: []const u8 = "";
            var decls: ?ts.Node = null;
            var j: u32 = 0;
            while (item.namedChild(j)) |c| : (j += 1) {
                if (std.mem.eql(u8, c.kind(), "identifier")) mname = text(e, c);
                if (std.mem.eql(u8, c.kind(), "declaration_list")) decls = c;
            }
            const child_id = try addEntity(e, .module, mname, mod_id, item);
            const child_attributes = e.g.symbol_table.entities.items[child_id].attributes;
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
                    .attributes = try duplicateAttributes(e, child_attributes),
                });
                const child_items = try mapItemsInner(e, dl, child_id);
                e.g.modules.items[child_mod_idx].items = child_items;
            } else {
                var sub_path: ?[]const u8 = null;
                var sub_base_dir: ?[]const u8 = null;
                if (e.base_dir) |bdir| {
                    if (extractPathAttr(e, item)) |custom_rel_path| {
                        // `#[path = "..."]` is resolved relative to the
                        // directory containing the declaring file.
                        const cand = try std.fs.path.join(e.alloc, &.{ bdir, custom_rel_path });
                        defer e.alloc.free(cand);
                        if (e.io) |io| {
                            var dir = std.Io.Dir.cwd();
                            if (dir.openFile(io, cand, .{})) |f| {
                                f.close(io);
                                sub_path = try e.alloc.dupe(u8, cand);
                            } else |_| {}
                        }
                    } else {
                        const rs_name = try std.fmt.allocPrint(e.alloc, "{s}.rs", .{mname});
                        defer e.alloc.free(rs_name);
                        const cand1 = try std.fs.path.join(e.alloc, &.{ bdir, rs_name });
                        defer e.alloc.free(cand1);
                        const cand2 = try std.fs.path.join(e.alloc, &.{ bdir, mname, "mod.rs" });
                        defer e.alloc.free(cand2);
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
                    if (sub_path) |resolved_path| {
                        sub_base_dir = try childModuleBaseDir(e.alloc, resolved_path, mname);
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
                    .attributes = try duplicateAttributes(e, child_attributes),
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
                                .exprs_list = e.exprs_list,
                                .base_dir = sub_base_dir,
                                .io = e.io,
                                .macro_table = e.macro_table,
                            };
                            const child_items = try mapItemsInner(&sub_ctx, sub_tree.rootNode(), child_id);
                            e.g.modules.items[child_mod_idx].items = child_items;
                        }
                    } else |_| {}
                }
            }
            try item_ids.append(e.alloc, child_id);
        } else if (std.mem.eql(u8, k, "use_declaration")) {
            try useItem(e, item2, mod_id, &item_ids);
        } else if (std.mem.eql(u8, k, "struct_item")) {
            try structItem(e, item2, mod_id);
            try item_ids.append(e.alloc, @intCast(e.bodies_list.items.len - 1));
        } else if (std.mem.eql(u8, k, "enum_item")) {
            try enumItem(e, item2, mod_id);
            try item_ids.append(e.alloc, @intCast(e.bodies_list.items.len - 1));
        } else if (std.mem.eql(u8, k, "union_item")) {
            try unionItem(e, item2, mod_id);
            try item_ids.append(e.alloc, @intCast(e.bodies_list.items.len - 1));
        } else if (std.mem.eql(u8, k, "trait_item")) {
            try traitItem(e, item2, mod_id);
            try item_ids.append(e.alloc, @intCast(e.bodies_list.items.len - 1));
        } else if (std.mem.eql(u8, k, "type_item")) {
            try typeAliasItem(e, item2, mod_id);
            try item_ids.append(e.alloc, @intCast(e.bodies_list.items.len - 1));
        } else if (std.mem.eql(u8, k, "const_item")) {
            try constItem(e, item2, mod_id);
            try item_ids.append(e.alloc, @intCast(e.bodies_list.items.len - 1));
        } else if (std.mem.eql(u8, k, "function_item")) {
            try functionItem(e, item2, mod_id, false);
            try item_ids.append(e.alloc, @intCast(e.bodies_list.items.len - 1));
        } else if (std.mem.eql(u8, k, "impl_item")) {
            const id = try implItem(e, item2, mod_id);
            try item_ids.append(e.alloc, id);
        } else if (std.mem.eql(u8, k, "macro_definition")) {
            try registerMacroDefinition(e, item2);
        } else if (std.mem.eql(u8, k, "macro_invocation")) {
            try expandMacroInvocationItems(e, item2, mod_id, &item_ids);
        }
    }
    return item_ids.toOwnedSlice(e.alloc);
}

/// Entry: parse `src` and build the type model into `ctx`. The root module
/// (id 0) must already exist. Returns the root module's item list.
pub fn extractFile(ctx: *Ctx) !void {
    var local_table: exp.MacroTable = undefined;
    var has_local = false;
    if (ctx.macro_table == null) {
        local_table = exp.MacroTable.init(ctx.alloc);
        ctx.macro_table = &local_table;
        has_local = true;
    }
    defer if (has_local) {
        ctx.macro_table = null;
        local_table.deinit();
    };

    var parser = ts.Parser.create();
    defer parser.destroy();
    if (parser.setLanguage(rust.language())) |_| {} else |_| {}
    const tree = parser.parseString(ctx.src, null) orelse return;
    defer tree.destroy();
    const root = tree.rootNode();
    try mapItems(ctx, root, 0);
    try names.resolveGraph(ctx.alloc, ctx.g);
}
test "cst lowers typed and cast integer constants as numeric literals" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var crate_graph = graph.CrateGraph.init(allocator);
    defer crate_graph.deinit();
    _ = try crate_graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try allocator.dupe(u8, ""),
        .span = span_of,
        .visibility = .public,
        .parent = null,
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
        .span = span_of,
        .items = &.{},
        .attributes = &.{},
    });

    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    var bodies_list: std.ArrayListUnmanaged(bodies.BodyKind) = .empty;
    try bodies_list.append(allocator, .none);
    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;
    var ctx: Ctx = .{
        .alloc = allocator,
        .g = &crate_graph,
        .src =
        \\pub const CONTINUATION_BIT: u8 = 1 << 7;
        \\pub const SIGN_BIT: u8 = 1 << 6;
        \\pub const CAST_BYTE: u8 = (0x80u8 as u16) as u8;
        ,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
    };
    try extractFile(&ctx);

    const expected = [_]struct { name: []const u8, value: i128 }{
        .{ .name = "CONTINUATION_BIT", .value = 128 },
        .{ .name = "SIGN_BIT", .value = 64 },
        .{ .name = "CAST_BYTE", .value = 128 },
    };
    for (expected) |want| {
        var entity_id: ?spine.EntityId = null;
        for (crate_graph.symbol_table.entities.items) |entity| {
            if (std.mem.eql(u8, entity.name, want.name)) {
                entity_id = entity.id;
                break;
            }
        }
        const id = entity_id orelse return error.TestUnexpectedResult;
        const body = bodies_list.items[id];
        const init_id = switch (body) {
            .const_ => |constant| constant.init,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expect(init_id < exprs_list.items.len);
        switch (exprs_list.items[init_id].kind) {
            .literal => |literal| switch (literal) {
                .int => |integer| try std.testing.expectEqual(want.value, integer.value),
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        }
    }
}
test "cst preserves generic function type parameter names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var crate_graph = graph.CrateGraph.init(allocator);
    defer crate_graph.deinit();
    _ = try crate_graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try allocator.dupe(u8, ""),
        .span = span_of,
        .visibility = .public,
        .parent = null,
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
        .span = span_of,
        .items = &.{},
        .attributes = &.{},
    });

    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    var bodies_list: std.ArrayListUnmanaged(bodies.BodyKind) = .empty;
    try bodies_list.append(allocator, .none);
    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;
    var ctx: Ctx = .{
        .alloc = allocator,
        .g = &crate_graph,
        .src =
        \\pub fn atoi<I: FromRadix10>(text: &[u8]) -> I { text; }
        \\pub fn identity<T>(value: T) -> T { value; }
        ,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
    };
    try extractFile(&ctx);

    const expected = [_]struct { name: []const u8, generic: []const u8 }{
        .{ .name = "atoi", .generic = "I" },
        .{ .name = "identity", .generic = "T" },
    };
    for (expected) |want| {
        var found: ?spine.Entity = null;
        for (crate_graph.symbol_table.entities.items) |entity| {
            if (entity.kind == .fn_ and std.mem.eql(u8, entity.name, want.name)) {
                found = entity;
                break;
            }
        }
        const entity = found orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 0), entity.attributes.len);
        try std.testing.expect(entity.id < bodies_list.items.len);
        const generic_params = switch (bodies_list.items[entity.id]) {
            .fn_ => |fb| fb.generic_params,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(usize, 1), generic_params.len);
        try std.testing.expectEqualStrings(want.generic, generic_params[0]);
    }
}

test "cst and ts_ext lower trait impl method bodies" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var crate_graph = graph.CrateGraph.init(allocator);
    defer crate_graph.deinit();
    _ = try crate_graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try allocator.dupe(u8, ""),
        .span = span_of,
        .visibility = .public,
        .parent = null,
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
        .span = span_of,
        .items = &.{},
        .attributes = &.{},
    });

    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    var bodies_list: std.ArrayListUnmanaged(bodies.BodyKind) = .empty;
    try bodies_list.append(allocator, .none);
    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;
    var ctx: Ctx = .{
        .alloc = allocator,
        .g = &crate_graph,
        .src =
        \\pub struct S { value: u64 }
        \\trait T {
        \\    fn f(&self, x: u64) -> u64;
        \\}
        \\impl T for S {
        \\    fn f(&self, x: u64) -> u64 { self.value + x }
        \\}
        ,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
    };
    try extractFile(&ctx);

    var struct_id: ?spine.EntityId = null;
    var fn_id: ?spine.EntityId = null;
    for (crate_graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .struct_ and std.mem.eql(u8, entity.name, "S")) {
            struct_id = entity.id;
        }
        if (entity.kind == .fn_ and std.mem.eql(u8, entity.name, "f")) {
            fn_id = entity.id;
        }
    }
    const sid = struct_id orelse return error.TestUnexpectedResult;
    const fid = fn_id orelse return error.TestUnexpectedResult;

    var stmts_list: std.ArrayListUnmanaged(exprs.Statement) = .empty;
    var pats_list: std.ArrayListUnmanaged(exprs.Pattern) = .empty;
    var lower_ctx: ts_ext.Ctx = .{
        .alloc = allocator,
        .g = &crate_graph,
        .exprs = &exprs_list,
        .stmts = &stmts_list,
        .pats = &pats_list,
        .types = &types_list,
        .bodies_list = &bodies_list,
        .src = ctx.src,
        .mod_id = 0,
    };
    try std.testing.expect(try ts_ext.extractFunction(&lower_ctx, fid));

    const body_id = switch (bodies_list.items[fid]) {
        .fn_ => |fb| fb.body,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(body_id > 0);

    var found_param_path = false;
    var found_self_field = false;
    for (exprs_list.items) |expression| {
        switch (expression.kind) {
            .path => found_param_path = true,
            .field => |field| {
                if (std.mem.eql(u8, field.field, "value") and field.base < exprs_list.items.len) {
                    switch (exprs_list.items[field.base].kind) {
                        .path => found_self_field = true,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    try std.testing.expect(found_param_path);
    try std.testing.expect(found_self_field);

    switch (bodies_list.items[sid]) {
        .struct_ => |sb| {
            var found_method = false;
            for (sb.methods) |method| {
                if (std.mem.eql(u8, method.name, "f")) {
                    found_method = true;
                    try std.testing.expectEqual(body_id, method.body);
                }
            }
            try std.testing.expect(found_method);
        },
        else => return error.TestUnexpectedResult,
    }
}
test "cst and ts_ext decode Rust byte string and byte character literals" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var crate_graph = graph.CrateGraph.init(allocator);
    defer crate_graph.deinit();
    _ = try crate_graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try allocator.dupe(u8, ""),
        .span = span_of,
        .visibility = .public,
        .parent = null,
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
        .span = span_of,
        .items = &.{},
        .attributes = &.{},
    });

    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    var bodies_list: std.ArrayListUnmanaged(bodies.BodyKind) = .empty;
    try bodies_list.append(allocator, .none);
    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;
    const source =
        \\pub const COOKED: &[u8] = b"line\n\x00\xff";
        \\pub const EMPTY: &[u8] = b"";
        \\pub const RAW: &[u8] = br#"raw \n text"#;
        \\pub const BYTE: u8 = b'\x41';
        \\pub fn bytes() -> &'static [u8] {
        \\    b'\x42';
        \\    br#"raw \n text"#;
        \\    b"body\n";
        \\}
    ;
    var cst_ctx: Ctx = .{
        .alloc = allocator,
        .g = &crate_graph,
        .src = source,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
    };
    try extractFile(&cst_ctx);

    const expected = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "COOKED", .bytes = "line\n\x00\xff" },
        .{ .name = "EMPTY", .bytes = "" },
        .{ .name = "RAW", .bytes = "raw \\n text" },
        .{ .name = "BYTE", .bytes = "\x41" },
    };
    for (expected) |want| {
        var found: ?spine.EntityId = null;
        for (crate_graph.symbol_table.entities.items) |entity| {
            if (entity.kind == .const_ and std.mem.eql(u8, entity.name, want.name)) {
                found = entity.id;
                break;
            }
        }
        const entity_id = found orelse return error.TestUnexpectedResult;
        const init_id = switch (bodies_list.items[entity_id]) {
            .const_ => |constant| constant.init,
            else => return error.TestUnexpectedResult,
        };
        switch (exprs_list.items[init_id].kind) {
            .literal => |literal| switch (literal) {
                .byte_array => |byte_array| try std.testing.expectEqualSlices(u8, want.bytes, byte_array.items),
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        }
    }

    var stmts_list: std.ArrayListUnmanaged(exprs.Statement) = .empty;
    var pats_list: std.ArrayListUnmanaged(exprs.Pattern) = .empty;
    var lower_ctx: ts_ext.Ctx = .{
        .alloc = allocator,
        .g = &crate_graph,
        .exprs = &exprs_list,
        .stmts = &stmts_list,
        .pats = &pats_list,
        .types = &types_list,
        .bodies_list = &bodies_list,
        .src = source,
        .mod_id = 0,
    };
    var function_id: ?spine.EntityId = null;
    for (crate_graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .fn_ and std.mem.eql(u8, entity.name, "bytes")) {
            function_id = entity.id;
            break;
        }
    }
    const body_expr_start = exprs_list.items.len;
    const body_id = function_id orelse return error.TestUnexpectedResult;
    try std.testing.expect(try ts_ext.extractFunction(&lower_ctx, body_id));

    var found_body_byte = false;
    var found_body_raw = false;
    var found_body_string = false;
    for (exprs_list.items[body_expr_start..]) |expression| {
        switch (expression.kind) {
            .literal => |literal| switch (literal) {
                .byte_array => |byte_array| {
                    if (std.mem.eql(u8, byte_array.items, "\x42")) found_body_byte = true;
                    if (std.mem.eql(u8, byte_array.items, "raw \\n text")) found_body_raw = true;
                    if (std.mem.eql(u8, byte_array.items, "body\n")) found_body_string = true;
                },
                else => {},
            },
            else => {},
        }
    }
    try std.testing.expect(found_body_byte);
    try std.testing.expect(found_body_raw);
    try std.testing.expect(found_body_string);
}

test "cst preserves file module child directories" {
    const allocator = std.testing.allocator;

    const conventional = try childModuleBaseDir(allocator, "src/foo.rs", "foo");
    defer allocator.free(conventional);
    try std.testing.expectEqualStrings("src/foo", conventional);

    const directory_module = try childModuleBaseDir(allocator, "src/foo/mod.rs", "foo");
    defer allocator.free(directory_module);
    try std.testing.expectEqualStrings("src/foo", directory_module);

    const custom_module = try childModuleBaseDir(allocator, "src/custom.rs", "custom_pub");
    defer allocator.free(custom_module);
    try std.testing.expectEqualStrings("src/custom_pub", custom_module);
}
test "cst preserves source visibility attributes and trait signatures" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var crate_graph = graph.CrateGraph.init(allocator);
    defer crate_graph.deinit();
    _ = try crate_graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try allocator.dupe(u8, ""),
        .span = span_of,
        .visibility = .public,
        .parent = null,
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
        .span = span_of,
        .items = &.{},
        .attributes = &.{},
    });

    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    var bodies_list: std.ArrayListUnmanaged(bodies.BodyKind) = .empty;
    try bodies_list.append(allocator, .none);
    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;
    var ctx: Ctx = .{
        .alloc = allocator,
        .g = &crate_graph,
        .src =
        \\#[cfg(test)]
        \\mod tests {
        \\    #[test]
        \\    fn smoke() {}
        \\}
        \\pub fn public_fn() {}
        \\fn private_fn() {}
        \\pub trait Processor {
        \\    fn process(&self, value: u32) -> u64;
        \\}
        ,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
    };
    try extractFile(&ctx);

    try std.testing.expectEqual(@as(usize, 4), crate_graph.modules.items[0].items.len);

    var tests_entity: ?spine.Entity = null;
    var smoke_entity: ?spine.Entity = null;
    var public_entity: ?spine.Entity = null;
    var private_entity: ?spine.Entity = null;
    var trait_entity: ?spine.Entity = null;
    for (crate_graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .module and std.mem.eql(u8, entity.name, "tests")) {
            tests_entity = entity;
        } else if (entity.kind == .fn_ and std.mem.eql(u8, entity.name, "smoke")) {
            smoke_entity = entity;
        } else if (entity.kind == .fn_ and std.mem.eql(u8, entity.name, "public_fn")) {
            public_entity = entity;
        } else if (entity.kind == .fn_ and std.mem.eql(u8, entity.name, "private_fn")) {
            private_entity = entity;
        } else if (entity.kind == .trait_ and std.mem.eql(u8, entity.name, "Processor")) {
            trait_entity = entity;
        }
    }

    const tests = tests_entity orelse return error.TestUnexpectedResult;
    try std.testing.expect(tests.visibility == .private);
    try std.testing.expectEqual(@as(usize, 1), tests.attributes.len);
    try std.testing.expectEqualStrings("cfg", tests.attributes[0].name);
    try std.testing.expectEqualStrings("test", tests.attributes[0].meta);

    var tests_module: ?graph.Module = null;
    for (crate_graph.modules.items) |module| {
        if (module.id == tests.id) {
            tests_module = module;
            break;
        }
    }
    const module = tests_module orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), module.items.len);
    try std.testing.expectEqual(@as(usize, 1), module.attributes.len);
    try std.testing.expectEqualStrings("cfg", module.attributes[0].name);
    try std.testing.expectEqualStrings("test", module.attributes[0].meta);

    const smoke = smoke_entity orelse return error.TestUnexpectedResult;
    try std.testing.expect(smoke.visibility == .private);
    try std.testing.expectEqual(@as(usize, 1), smoke.attributes.len);
    try std.testing.expectEqualStrings("test", smoke.attributes[0].name);
    try std.testing.expectEqualStrings("", smoke.attributes[0].meta);

    const public_fn = public_entity orelse return error.TestUnexpectedResult;
    try std.testing.expect(public_fn.visibility == .public);
    const private_fn = private_entity orelse return error.TestUnexpectedResult;
    try std.testing.expect(private_fn.visibility == .private);

    const trait = trait_entity orelse return error.TestUnexpectedResult;
    try std.testing.expect(trait.visibility == .public);
    const trait_body = switch (bodies_list.items[trait.id]) {
        .trait_ => |body| body,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), trait_body.methods.len);
    const method = trait_body.methods[0];
    try std.testing.expectEqualStrings("process", method.name);
    try std.testing.expectEqual(items.Receiver.ref_, method.receiver);
    try std.testing.expectEqual(@as(usize, 1), method.params.len);
    try std.testing.expectEqualStrings("value", method.params[0].name);
    switch (method.params[0].ty) {
        .prim => |prim| try std.testing.expectEqual(types.Prim.u32, prim),
        else => return error.TestUnexpectedResult,
    }
    switch (method.ret) {
        .prim => |prim| try std.testing.expectEqual(types.Prim.u64, prim),
        else => return error.TestUnexpectedResult,
    }
}

test "stripIntSuffix preserves a suffix without a numeric body" {
    try std.testing.expectEqualStrings("u8", stripIntSuffix("u8"));
}

test "decodeRustByteLiteral rejects a byte quote without a body" {
    try std.testing.expect((try decodeRustByteLiteral(std.testing.allocator, "b'")) == null);
}

test "extractPathFromAttrText accepts path at offset zero" {
    const path = extractPathFromAttrText("path = \"module.rs\"") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("module.rs", path);
}
