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

pub const CfgOptions = struct {
    features: []const []const u8 = &.{},
    target_pointer_width: ?u16 = null,
    docsrs: bool = false,
};

const max_const_environment_entries: usize = 4096;

const ConstDeclaration = struct {
    name: []const u8,
    item: ?ts.Node = null,
    value: ?i128 = null,
};

const TypeAliasDeclaration = struct {
    name: []const u8,
    item: ?ts.Node = null,
    target_name: ?[]const u8 = null,
};

const ConstEnvironment = struct {
    const Self = ConstEnvironment;

    consts: std.ArrayListUnmanaged(ConstDeclaration) = .empty,
    aliases: std.ArrayListUnmanaged(TypeAliasDeclaration) = .empty,
    parent: ?*const ConstEnvironment = null,
    owns_strings: bool = false,

    fn init() Self {
        return .{
            .consts = .empty,
            .aliases = .empty,
        };
    }

    fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.owns_strings) {
            for (self.consts.items) |declaration| allocator.free(declaration.name);
            for (self.aliases.items) |declaration| {
                allocator.free(declaration.name);
                if (declaration.target_name) |target_name| allocator.free(target_name);
            }
        }
        self.consts.deinit(allocator);
        self.aliases.deinit(allocator);
        self.* = undefined;
    }
};

const PendingImplMethod = struct {
    function_id: spine.EntityId,
    receiver: ?items.Receiver,
};

const PendingImpl = struct {
    impl_id: spine.EntityId,
    module_id: spine.EntityId,
    target_path: []const u8,
    methods: []const PendingImplMethod,
};

pub const PendingGenericApplication = struct {
    placeholder: spine.EntityId,
    owner_id: spine.EntityId,
    path: []const types.PathSegment,
};

fn freePendingGenericPath(alloc: std.mem.Allocator, path: []const types.PathSegment) void {
    for (path) |segment| alloc.free(segment.name);
    alloc.free(path);
}

const unresolved_generic_decl_id = std.math.maxInt(spine.EntityId);
pub const FunctionOrigin = struct {
    lexical_module: spine.EntityId,
    source: []const u8,
};

pub const FunctionOriginTable = std.AutoHashMapUnmanaged(spine.EntityId, FunctionOrigin);

pub const Ctx = struct {
    alloc: std.mem.Allocator,
    g: *graph.CrateGraph,
    src: []const u8,
    types_list: *std.ArrayListUnmanaged(types.Type),
    bodies_list: *std.ArrayListUnmanaged(bodies.BodyKind),
    exprs_list: *std.ArrayListUnmanaged(exprs.Expr),
    base_dir: ?[]const u8 = null,
    io: ?std.Io = null,
    include_tests: bool = false,
    cfg: CfgOptions = .{},
    /// Current declaration owner while its source types are mapped.
    declaration_owner: ?spine.EntityId = null,
    /// Declarations collected before the current module is lowered.
    const_environment: ?*const ConstEnvironment = null,
    /// In-crate `macro_rules!` definitions registered during CST extraction.
    /// Shared by the root module and every submodule so an item-level macro invocation can be expanded regardless of which file defined it.
    macro_table: ?*exp.MacroTable = null,
    /// Impl blocks wait here until all lexical declarations and imports exist.
    pending_impls: ?*std.ArrayListUnmanaged(PendingImpl) = null,
    /// Exact function origins recorded during CST ingestion.
    function_origins: ?*FunctionOriginTable = null,
    /// Generic applications wait here until every nominal declaration exists.
    pending_generics: ?*std.ArrayListUnmanaged(PendingGenericApplication) = null,
};
fn parseRustTree(parser: *ts.Parser, source: []const u8) !*ts.Tree {
    parser.setLanguage(rust.language()) catch return error.ParserSetupFailed;
    return parser.parseString(source, null) orelse error.ParseFailed;
}

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

fn parseAttributeText(e: *const Ctx, attr_text: []const u8) !spine.Attribute {
    var inner = std.mem.trim(u8, attr_text, " \t\r\n");
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

fn parseAttribute(e: *const Ctx, node: ts.Node) !spine.Attribute {
    return parseAttributeText(e, text(e, node));
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

/// Append an inner attribute to the owning module. Inner attributes are
/// declarations in the CST, but they are module metadata rather than items.
fn appendModuleAttribute(
    e: *Ctx,
    module_id: spine.EntityId,
    attribute: spine.Attribute,
) !void {
    const module_row = e.g.moduleForEntity(module_id) orelse {
        e.alloc.free(attribute.name);
        e.alloc.free(attribute.meta);
        return error.ModuleNotFound;
    };
    const row_id = module_row.id;
    for (e.g.modules.items) |*module| {
        if (module.id != row_id) continue;
        const old = module.attributes;
        const merged = e.alloc.alloc(spine.Attribute, old.len + 1) catch |err| {
            e.alloc.free(attribute.name);
            e.alloc.free(attribute.meta);
            return err;
        };
        @memcpy(merged[0..old.len], old);
        merged[old.len] = attribute;
        if (old.len > 0) e.alloc.free(old);
        module.attributes = merged;
        return;
    }
    e.alloc.free(attribute.name);
    e.alloc.free(attribute.meta);
    return error.ModuleNotFound;
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
/// entities take their visibility and attributes from the CST item. Callers
/// that pass no source item are restricted to graph bookkeeping declarations.
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

const TypeMapError = std.mem.Allocator.Error || error{
    InvalidType,
    TooManyTypeArguments,
    UnresolvedNominalType,
    InvalidNominalType,
};
/// Map an array length without manufacturing a value for an unresolved name.
/// The declaration environment is evaluated independently of source order.
fn mapArrayLen(e: *Ctx, node: ts.Node) TypeMapError!types.ArrayLen {
    const value = constIntegerValue(e, node) orelse return error.InvalidType;
    if (value < 0 or value > @as(i128, std.math.maxInt(u32))) {
        return error.InvalidType;
    }
    return .{ .literal = @intCast(value) };
}

/// Lower a tree-sitter type node into a wire `types.Type`.
fn mapType(e: *Ctx, node: ts.Node) TypeMapError!types.Type {
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "type")) {
        if (node.namedChildCount() > 0) {
            const mapped: types.Type = try mapType(e, node.namedChild(0).?);
            return mapped;
        }
        return unsupportedTy();
    }
    if (std.mem.eql(u8, kind, "primitive_type")) {
        const nm = text(e, node);
        if (std.mem.eql(u8, nm, "str")) {
            const s = try e.alloc.create(types.Slice);
            s.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
            return .{ .slice = s };
        }
        if (mapPrim(nm)) |p| return .{ .prim = p };
        return unsupportedTy();
    }
    if (std.mem.eql(u8, kind, "reference_type")) {
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
                if (inn.namedChildCount() > 0) elem = try mapType(e, inn.namedChild(0).?);
                const s = try e.alloc.create(types.Slice);
                s.* = .{ .const_ = !mut, .elem = elem };
                return .{ .slice = s };
            }
            if (std.mem.eql(u8, inn.kind(), "primitive_type") and std.mem.eql(u8, text(e, inn), "str")) {
                const s = try e.alloc.create(types.Slice);
                s.* = .{ .const_ = !mut, .elem = .{ .prim = .u8 } };
                return .{ .slice = s };
            }
            if (std.mem.eql(u8, inn.kind(), "array_type")) {
                const mapped: types.Type = try mapType(e, inn);
                return mapped;
            }
            const r = try e.alloc.create(types.Ref);
            errdefer e.alloc.destroy(r);
            const pointee: types.Type = try mapType(e, inn);
            r.* = .{ .mut = mut, .pointee = pointee };
            return .{ .reference = r };
        }
        return unsupportedTy();
    }
    if (std.mem.eql(u8, kind, "slice_type")) {
        var elem: types.Type = .{ .prim = .unit };
        if (node.namedChildCount() > 0) elem = try mapType(e, node.namedChild(0).?);
        const s = try e.alloc.create(types.Slice);
        s.* = .{ .const_ = true, .elem = elem };
        return .{ .slice = s };
    }
    if (std.mem.eql(u8, kind, "array_type")) {
        var elem: types.Type = .{ .prim = .unit };
        if (node.namedChild(0)) |elem_node| elem = try mapType(e, elem_node);
        if (isSliceTypeNode(node)) {
            const s = try e.alloc.create(types.Slice);
            s.* = .{ .const_ = true, .elem = elem };
            return .{ .slice = s };
        }

        const len_node = node.namedChild(1) orelse return error.InvalidType;
        const len = try mapArrayLen(e, len_node);
        const a = try e.alloc.create(types.Array);
        a.* = .{ .elem = elem, .len = len };
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
                elem = try mapType(e, c);
            }
        }
        const raw = try e.alloc.create(types.RawPtr);
        raw.* = .{ .mut = mut, .pointee = elem };
        return .{ .raw_ptr = raw };
    }
    if (std.mem.eql(u8, kind, "generic_type") or
        std.mem.eql(u8, kind, "type_identifier") or
        std.mem.eql(u8, kind, "identifier") or
        std.mem.eql(u8, kind, "scoped_type_identifier"))
    {
        const mapped: types.Type = try mapNamedType(e, node);
        return mapped;
    }
    if (std.mem.eql(u8, kind, "tuple_type") or std.mem.eql(u8, kind, "unit_type")) {
        var tup: std.ArrayListUnmanaged(types.Type) = .empty;
        defer tup.deinit(e.alloc);
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            try tup.append(e.alloc, try mapType(e, c));
        }
        if (tup.items.len == 0) return .{ .prim = .unit };
        const tuple_types: []const types.Type = try tup.toOwnedSlice(e.alloc);
        return .{ .tuple = tuple_types };
    }
    if (node.namedChildCount() > 0) {
        const mapped: types.Type = try mapType(e, node.namedChild(0).?);
        return mapped;
    }
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

fn mapReturnType(e: *Ctx, node: ts.Node) !types.Type {
    const ret = returnTypeNode(node) orelse return .{ .prim = .unit };
    const mapped: types.Type = try mapType(e, ret);
    return mapped;
}

/// A named (path) type — possibly generic `Foo<T>`, with std prelude
/// recognition (`Option`/`Result`/`Box`) into dedicated IR nodes.
fn isNominalEntityKind(kind: spine.EntityKind) bool {
    return switch (kind) {
        .struct_, .enum_, .union_, .trait_, .type_alias => true,
        else => false,
    };
}

fn freeExternalPath(e: *const Ctx, path: []const []const u8) void {
    for (path) |segment| e.alloc.free(segment);
    if (path.len > 0) e.alloc.free(path);
}

fn externalUsePath(e: *const Ctx, name: []const u8) !?[]const []const u8 {
    const owner_id = e.declaration_owner orelse return null;
    const module_id = owningModule(e.g, owner_id) orelse return null;
    var found: ?[]const []const u8 = null;
    for (e.g.symbol_table.entities.items) |entity| {
        if (entity.parent != module_id or entity.kind != .use_) continue;
        const use_decl = e.g.useById(entity.id) orelse continue;
        if (!std.mem.eql(u8, use_decl.local_name, name)) continue;
        const external = switch (use_decl.kind) {
            .external => |value| value,
            else => continue,
        };
        const path = try e.alloc.alloc([]const u8, external.path.len);
        var copied: usize = 0;
        errdefer {
            for (path[0..copied]) |segment| e.alloc.free(segment);
            e.alloc.free(path);
        }
        for (external.path, 0..) |segment, index| {
            path[index] = try e.alloc.dupe(u8, segment);
            copied += 1;
        }
        if (found) |old| {
            freeExternalPath(e, old);
            freeExternalPath(e, path);
            return null;
        }
        found = path;
    }
    return found;
}
fn makePendingGeneric(
    e: *Ctx,
    args: []const types.Type,
    path_segments: []const types.PathSegment,
) TypeMapError!types.Type {
    const pending = e.pending_generics orelse {
        e.alloc.free(path_segments);
        return error.UnresolvedNominalType;
    };
    if (pending.items.len >= @as(usize, unresolved_generic_decl_id)) {
        e.alloc.free(path_segments);
        return error.UnresolvedNominalType;
    }
    const owner_id = e.declaration_owner orelse {
        e.alloc.free(path_segments);
        return error.UnresolvedNominalType;
    };
    const owned_path = try e.alloc.alloc(types.PathSegment, path_segments.len);
    var copied: usize = 0;
    errdefer {
        for (owned_path[0..copied]) |segment| e.alloc.free(segment.name);
        e.alloc.free(owned_path);
    }
    for (path_segments, 0..) |segment, index| {
        owned_path[index] = .{
            .name = try e.alloc.dupe(u8, segment.name),
            .id = null,
        };
        copied += 1;
    }
    e.alloc.free(path_segments);
    const placeholder: spine.EntityId = unresolved_generic_decl_id -
        @as(spine.EntityId, @intCast(pending.items.len));
    try pending.append(e.alloc, .{
        .placeholder = placeholder,
        .owner_id = owner_id,
        .path = owned_path,
    });
    return .{ .generic_inst = .{
        .decl = placeholder,
        .args = .{ .params = args },
    } };
}

fn mapNamedType(e: *Ctx, node: ts.Node) TypeMapError!types.Type {
    var name: ?[]const u8 = null;
    var arg_nodes: [8]ts.Node = undefined;
    var arg_count: usize = 0;
    var segs: std.ArrayListUnmanaged(types.PathSegment) = .empty;
    defer segs.deinit(e.alloc);

    const kind = node.kind();
    if (std.mem.eql(u8, kind, "type_identifier") or std.mem.eql(u8, kind, "identifier")) {
        name = text(e, node);
    } else if (std.mem.eql(u8, kind, "scoped_type_identifier")) {
        const sub = try mapScopedSegments(e, node);
        try segs.appendSlice(e.alloc, sub);
    } else {
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            const k = c.kind();
            if (std.mem.eql(u8, k, "type_identifier") or std.mem.eql(u8, k, "identifier")) {
                name = text(e, c);
            } else if (std.mem.eql(u8, k, "scoped_type_identifier")) {
                const sub = try mapScopedSegments(e, c);
                try segs.appendSlice(e.alloc, sub);
            } else if (std.mem.eql(u8, k, "type_arguments") or
                std.mem.eql(u8, k, "generic_type"))
            {
                var j: u32 = 0;
                while (c.namedChild(j)) |a| : (j += 1) {
                    if (std.mem.eql(u8, a.kind(), "lifetime")) continue;
                    if (arg_count == arg_nodes.len) return error.TooManyTypeArguments;
                    arg_nodes[arg_count] = a;
                    arg_count += 1;
                }
            }
        }
    }
    if (name == null and segs.items.len > 0) {
        name = segs.items[segs.items.len - 1].name;
    }
    const nm = name orelse return error.UnresolvedNominalType;
    var args: []const types.Type = &.{};
    if (arg_count > 0) {
        const args_arr = try e.alloc.alloc(types.Type, arg_count);
        for (arg_nodes[0..arg_count], 0..) |an, ai| {
            args_arr[ai] = try mapType(e, an);
        }
        args = args_arr;
    }

    if (std.mem.eql(u8, nm, "Option") and args.len == 1) {
        const inner = try e.alloc.create(types.Type);
        inner.* = args[0];
        return .{ .option = inner };
    }
    if (std.mem.eql(u8, nm, "Result") and args.len == 2) {
        const r = try e.alloc.create(types.Result);
        r.* = .{
            .ok = args[0],
            .err = args[1],
            .is_error_unionable = true,
        };
        return .{ .result = r };
    }
    if (std.mem.eql(u8, nm, "Box") and args.len == 1) {
        const inner = try e.alloc.create(types.Type);
        inner.* = args[0];
        return .{ .boxed = inner };
    }
    const had_scoped_segments = segs.items.len > 0;
    if (segs.items.len > 0 and
        (std.mem.eql(u8, segs.items[0].name, "core") or
            std.mem.eql(u8, segs.items[0].name, "std") or
            std.mem.eql(u8, segs.items[0].name, "alloc")))
    {
        const external_path = try e.alloc.alloc([]const u8, segs.items.len);
        for (segs.items, 0..) |segment, index| {
            if (segment.name.len == 0) return error.InvalidType;
            external_path[index] = segment.name;
        }
        return .{ .external_nominal = .{
            .path = external_path,
            .args = args,
        } };
    }
    if (!had_scoped_segments) {
        if (try externalUsePath(e, nm)) |external_path| {
            return .{ .external_nominal = .{
                .path = external_path,
                .args = args,
            } };
        }
    }

    if (args.len > 0) {
        if (segs.items.len == 0 or
            !std.mem.eql(u8, segs.items[segs.items.len - 1].name, nm))
        {
            try segs.append(e.alloc, .{ .name = nm, .id = null });
        }
        const path_segments = try segs.toOwnedSlice(e.alloc);
        const owner_id = e.declaration_owner orelse {
            e.alloc.free(path_segments);
            return error.UnresolvedNominalType;
        };
        var path: types.Path = .{ .segments = path_segments };
        bindPath(e.g, e.bodies_list.items, owner_id, &.{}, &path) catch |err| switch (err) {
            error.UnresolvedNominalType => return makePendingGeneric(e, args, path_segments),
            else => {
                e.alloc.free(path_segments);
                return err;
            },
        };
        if (path.segments.len == 0) {
            e.alloc.free(path_segments);
            return error.UnresolvedNominalType;
        }
        const base_def = path.segments[path.segments.len - 1].id orelse {
            e.alloc.free(path_segments);
            return error.UnresolvedNominalType;
        };
        e.alloc.free(path_segments);
        return .{
            .generic_inst = .{
                .decl = base_def,
                .args = .{ .params = args },
            },
        };
    }
    if (segs.items.len == 0 or !std.mem.eql(u8, segs.items[segs.items.len - 1].name, nm)) {
        try segs.append(e.alloc, .{ .name = nm, .id = null });
    }
    const path_segments: []const types.PathSegment = try segs.toOwnedSlice(e.alloc);
    return .{ .path = .{ .segments = path_segments } };
}

/// Preserve every segment of a scoped type path. The binder resolves only the
/// terminal nominal entity; `crate`/`self`/`super` remain lexical prefixes.
fn mapScopedSegments(e: *Ctx, node: ts.Node) ![]const types.PathSegment {
    var segs: std.ArrayListUnmanaged(types.PathSegment) = .empty;
    errdefer segs.deinit(e.alloc);
    var source = std.mem.trim(u8, text(e, node), " \t\r\n");
    if (std.mem.startsWith(u8, source, "::")) source = source[2..];
    if (source.len == 0) return error.InvalidType;
    var path_parts = std.mem.splitSequence(u8, source, "::");
    while (path_parts.next()) |part| {
        const name = std.mem.trim(u8, part, " \t\r\n");
        if (name.len == 0) return error.InvalidType;
        try segs.append(e.alloc, .{ .name = name, .id = null });
    }
    return segs.toOwnedSlice(e.alloc);
}

pub const DeclarationTypeError = error{
    UnresolvedNominalType,
    InvalidNominalType,
};

fn rootModuleEntity(g: *const graph.CrateGraph) ?spine.EntityId {
    for (g.modules.items) |module| {
        if (!module.is_crate) continue;
        for (g.symbol_table.entities.items) |entity| {
            if (entity.kind != .module) continue;
            if (entity.parent == module.parent and std.mem.eql(u8, entity.name, module.name)) {
                return entity.id;
            }
        }
    }
    return null;
}

fn owningModule(g: *const graph.CrateGraph, start: spine.EntityId) ?spine.EntityId {
    var current: ?spine.EntityId = start;
    var depth: usize = 0;
    while (current) |entity_id| : (depth += 1) {
        if (depth >= g.symbol_table.entities.items.len) return null;
        const entity = g.symbol_table.get(entity_id) orelse return null;
        if (entity.kind == .module) return entity_id;
        current = entity.parent;
    }
    return null;
}

fn parentModuleEntity(g: *const graph.CrateGraph, module_id: spine.EntityId) ?spine.EntityId {
    const entity = g.symbol_table.get(module_id) orelse return null;
    if (entity.kind != .module) return null;
    return entity.parent;
}

fn resolveUseTarget(g: *const graph.CrateGraph, start: spine.EntityId) ?spine.EntityId {
    var current = start;
    var depth: usize = 0;
    while (depth < g.symbol_table.entities.items.len) : (depth += 1) {
        const entity = g.symbol_table.get(current) orelse return null;
        if (entity.kind != .use_) return current;
        if (entity.resolved) |resolved| {
            if (resolved == current) return null;
            current = resolved;
            continue;
        }
        const use_decl = g.useById(current) orelse return null;
        if (use_decl.target == 0 or use_decl.target == current) return null;
        current = use_decl.target;
    }
    return null;
}

fn resolveModuleItem(
    g: *const graph.CrateGraph,
    module_id: spine.EntityId,
    name: []const u8,
) ?spine.EntityId {
    if (g.moduleForEntity(module_id)) |module| {
        for (module.items) |item_id| {
            const entity = g.symbol_table.get(item_id) orelse continue;
            if (entity.kind == .use_) {
                const use_decl = g.useById(item_id) orelse continue;
                if (!std.mem.eql(u8, use_decl.local_name, name)) continue;
            } else if (!std.mem.eql(u8, entity.name, name)) {
                continue;
            }
            return resolveUseTarget(g, item_id) orelse item_id;
        }
    }
    // The symbol-table fallback also supports external-crate scopes, which
    // have no graph.Module row, while remaining bounded to one exact parent.
    // It also handles partially constructed graphs from direct CST unit tests.
    for (g.symbol_table.entities.items) |entity| {
        if (entity.parent != module_id) continue;
        if (entity.kind == .use_) {
            const use_decl = g.useById(entity.id) orelse continue;
            if (!std.mem.eql(u8, use_decl.local_name, name)) continue;
        } else if (!std.mem.eql(u8, entity.name, name)) {
            continue;
        }
        return resolveUseTarget(g, entity.id) orelse entity.id;
    }
    return null;
}

fn bodyHasGenericParam(body: bodies.BodyKind, name: []const u8) bool {
    const params: []const []const u8 = switch (body) {
        .fn_ => |fn_body| fn_body.generic_params,
        .struct_ => |struct_body| struct_body.generic_params,
        else => &.{},
    };
    for (params) |param| {
        if (std.mem.eql(u8, param, name)) return true;
    }
    return false;
}

fn activeGenericParam(
    g: *const graph.CrateGraph,
    bodies_list: []const bodies.BodyKind,
    owner_id: spine.EntityId,
    extra: []const []const u8,
    name: []const u8,
) bool {
    for (extra) |param| {
        if (std.mem.eql(u8, param, name)) return true;
    }
    var current: ?spine.EntityId = owner_id;
    var depth: usize = 0;
    while (current) |entity_id| : (depth += 1) {
        if (depth >= g.symbol_table.entities.items.len) return false;
        if (entity_id < bodies_list.len and bodyHasGenericParam(bodies_list[entity_id], name)) {
            return true;
        }
        const entity = g.symbol_table.get(entity_id) orelse return false;
        current = entity.parent;
    }
    return false;
}

fn selfTypeEntity(g: *const graph.CrateGraph, owner_id: spine.EntityId) ?spine.EntityId {
    var current: ?spine.EntityId = owner_id;
    var depth: usize = 0;
    while (current) |entity_id| : (depth += 1) {
        if (depth >= g.symbol_table.entities.items.len) return null;
        const entity = g.symbol_table.get(entity_id) orelse return null;
        switch (entity.kind) {
            .struct_, .enum_, .union_ => return entity.id,
            .module => return null,
            else => current = entity.parent,
        }
    }
    return null;
}

fn bindPath(
    g: *const graph.CrateGraph,
    bodies_list: []const bodies.BodyKind,
    owner_id: spine.EntityId,
    extra_generic_params: []const []const u8,
    path: *types.Path,
) DeclarationTypeError!void {
    if (path.segments.len == 0) return error.UnresolvedNominalType;
    var current = owningModule(g, owner_id) orelse return error.UnresolvedNominalType;
    var index: usize = 0;
    const first_name = path.segments[0].name;

    if (std.mem.eql(u8, first_name, "Self")) {
        if (path.segments.len != 1) return error.UnresolvedNominalType;
        const self_id = selfTypeEntity(g, owner_id) orelse return error.UnresolvedNominalType;
        @constCast(path.segments)[0].id = self_id;
        return;
    }
    if (path.segments.len == 1 and
        activeGenericParam(g, bodies_list, owner_id, extra_generic_params, first_name))
    {
        // Type parameters are lexical names, not graph entities. They remain
        // null-id paths only while their declaration scope is active.
        @constCast(path.segments)[0].id = null;
        return;
    }
    if (std.mem.eql(u8, first_name, "crate")) {
        current = rootModuleEntity(g) orelse return error.UnresolvedNominalType;
        index = 1;
    } else if (std.mem.eql(u8, first_name, "self")) {
        index = 1;
    } else {
        while (index < path.segments.len and
            std.mem.eql(u8, path.segments[index].name, "super"))
        {
            current = parentModuleEntity(g, current) orelse return error.UnresolvedNominalType;
            index += 1;
        }
    }
    if (index >= path.segments.len) return error.UnresolvedNominalType;

    while (index < path.segments.len) : (index += 1) {
        const segment = path.segments[index];
        const is_terminal = index + 1 == path.segments.len;
        const scoped_id = resolveModuleItem(g, current, segment.name);
        const found = if (segment.id) |resolved_id| blk: {
            const entity = g.symbol_table.get(resolved_id) orelse
                return error.UnresolvedNominalType;
            if (scoped_id) |scoped| {
                if (scoped != resolved_id) return error.UnresolvedNominalType;
            } else if (!std.mem.eql(u8, entity.name, segment.name)) {
                return error.UnresolvedNominalType;
            }
            if (!is_terminal and entity.kind != .module and entity.kind != .extern_crate) {
                return error.UnresolvedNominalType;
            }
            if (is_terminal and !isNominalEntityKind(entity.kind)) {
                return error.InvalidNominalType;
            }
            break :blk resolved_id;
        } else scoped_id orelse return error.UnresolvedNominalType;
        if (!is_terminal) {
            const entity = g.symbol_table.get(found) orelse return error.UnresolvedNominalType;
            if (entity.kind != .module and entity.kind != .extern_crate) {
                return error.UnresolvedNominalType;
            }
            // Module prefixes are lexical and cannot be emitted as nominal IDs.
            @constCast(path.segments)[index].id = null;
            current = found;
            continue;
        }
        const entity = g.symbol_table.get(found) orelse return error.UnresolvedNominalType;
        if (!isNominalEntityKind(entity.kind)) return error.InvalidNominalType;
        @constCast(path.segments)[index].id = entity.id;
    }
}

fn pendingGeneric(
    pending: []const PendingGenericApplication,
    placeholder: spine.EntityId,
) ?*const PendingGenericApplication {
    for (pending) |*application| {
        if (application.placeholder == placeholder) return application;
    }
    return null;
}

fn bindType(
    g: *const graph.CrateGraph,
    bodies_list: []const bodies.BodyKind,
    owner_id: spine.EntityId,
    extra_generic_params: []const []const u8,
    pending: []const PendingGenericApplication,
    ty: *types.Type,
) DeclarationTypeError!void {
    switch (ty.*) {
        .path => |*path| try bindPath(
            g,
            bodies_list,
            owner_id,
            extra_generic_params,
            path,
        ),
        .reference => |reference| {
            const mutable_reference = @constCast(reference);
            try bindType(
                g,
                bodies_list,
                owner_id,
                extra_generic_params,
                pending,
                &mutable_reference.pointee,
            );
        },
        .raw_ptr => |raw_ptr| {
            const mutable_raw_ptr = @constCast(raw_ptr);
            try bindType(
                g,
                bodies_list,
                owner_id,
                extra_generic_params,
                pending,
                &mutable_raw_ptr.pointee,
            );
        },
        .slice => |slice| {
            const mutable_slice = @constCast(slice);
            try bindType(
                g,
                bodies_list,
                owner_id,
                extra_generic_params,
                pending,
                &mutable_slice.elem,
            );
        },
        .array => |array| {
            const mutable_array = @constCast(array);
            try bindType(
                g,
                bodies_list,
                owner_id,
                extra_generic_params,
                pending,
                &mutable_array.elem,
            );
        },
        .tuple => |tuple| {
            for (@constCast(tuple)) |*element| {
                try bindType(g, bodies_list, owner_id, extra_generic_params, pending, element);
            }
        },
        .external_nominal => |external| {
            if (external.path.len == 0) return error.InvalidNominalType;
            if (!std.mem.eql(u8, external.path[0], "core") and
                !std.mem.eql(u8, external.path[0], "std") and
                !std.mem.eql(u8, external.path[0], "alloc"))
            {
                return error.UnresolvedNominalType;
            }
            for (external.path) |segment| {
                if (segment.len == 0) return error.InvalidNominalType;
            }
            for (@constCast(external.args)) |*param| {
                try bindType(g, bodies_list, owner_id, extra_generic_params, pending, param);
            }
        },
        .fn_ptr => |fn_ptr| {
            const mutable_fn_ptr = @constCast(fn_ptr);
            for (@constCast(mutable_fn_ptr.params)) |*param| {
                try bindType(g, bodies_list, owner_id, extra_generic_params, pending, param);
            }
            try bindType(
                g,
                bodies_list,
                owner_id,
                extra_generic_params,
                pending,
                &mutable_fn_ptr.ret,
            );
        },
        .generic_inst => |*generic| {
            if (pendingGeneric(pending, generic.decl)) |application| {
                var path: types.Path = .{ .segments = application.path };
                try bindPath(
                    g,
                    bodies_list,
                    application.owner_id,
                    &.{},
                    &path,
                );
                if (path.segments.len == 0) return error.UnresolvedNominalType;
                generic.decl = path.segments[path.segments.len - 1].id orelse
                    return error.UnresolvedNominalType;
            }
            const entity = g.symbol_table.get(generic.decl) orelse
                return error.UnresolvedNominalType;
            if (!isNominalEntityKind(entity.kind)) return error.InvalidNominalType;
            for (@constCast(generic.args.params)) |*param| {
                try bindType(g, bodies_list, owner_id, extra_generic_params, pending, param);
            }
        },
        .option => |inner| {
            const mutable_inner = @constCast(inner);
            try bindType(g, bodies_list, owner_id, extra_generic_params, pending, mutable_inner);
        },
        .result => |result| {
            const mutable_result = @constCast(result);
            try bindType(
                g,
                bodies_list,
                owner_id,
                extra_generic_params,
                pending,
                &mutable_result.ok,
            );
            try bindType(
                g,
                bodies_list,
                owner_id,
                extra_generic_params,
                pending,
                &mutable_result.err,
            );
        },
        .boxed => |inner| {
            const mutable_inner = @constCast(inner);
            try bindType(g, bodies_list, owner_id, extra_generic_params, pending, mutable_inner);
        },
        .prim, .unsupported => {},
    }
}

fn bindParams(
    g: *const graph.CrateGraph,
    bodies_list: []const bodies.BodyKind,
    owner_id: spine.EntityId,
    extra_generic_params: []const []const u8,
    pending: []const PendingGenericApplication,
    params: []const items.Param,
) DeclarationTypeError!void {
    for (@constCast(params)) |*param| {
        try bindType(g, bodies_list, owner_id, extra_generic_params, pending, &param.ty);
    }
}

fn bindFields(
    g: *const graph.CrateGraph,
    bodies_list: []const bodies.BodyKind,
    owner_id: spine.EntityId,
    extra_generic_params: []const []const u8,
    pending: []const PendingGenericApplication,
    fields: []const items.Field,
) DeclarationTypeError!void {
    for (@constCast(fields)) |*field| {
        try bindType(g, bodies_list, owner_id, extra_generic_params, pending, &field.ty);
    }
}

/// Bind every declaration-owned nominal type path after the complete CST graph
/// exists. Body lowering must run only after this pass succeeds.
pub fn bindDeclarationTypes(
    g: *const graph.CrateGraph,
    bodies_list: *std.ArrayListUnmanaged(bodies.BodyKind),
    pending: []const PendingGenericApplication,
) DeclarationTypeError!void {
    const body_slice = bodies_list.items;
    for (bodies_list.items, 0..) |*body, owner_id| {
        switch (body.*) {
            .const_ => |*constant| try bindType(
                g,
                body_slice,
                @intCast(owner_id),
                &.{},
                pending,
                &constant.ty,
            ),
            .fn_ => |*function| {
                try bindParams(
                    g,
                    body_slice,
                    @intCast(owner_id),
                    &.{},
                    pending,
                    function.params,
                );
                try bindType(
                    g,
                    body_slice,
                    @intCast(owner_id),
                    &.{},
                    pending,
                    &function.ret,
                );
            },
            .struct_ => |*structure| {
                try bindFields(
                    g,
                    body_slice,
                    @intCast(owner_id),
                    &.{},
                    pending,
                    structure.fields,
                );
                for (@constCast(structure.methods)) |*method| {
                    try bindParams(
                        g,
                        body_slice,
                        @intCast(owner_id),
                        method.generic_params,
                        pending,
                        method.params,
                    );
                    try bindType(
                        g,
                        body_slice,
                        @intCast(owner_id),
                        method.generic_params,
                        pending,
                        &method.ret,
                    );
                }
            },
            .enum_ => |*enumeration| {
                for (@constCast(enumeration.variants)) |*variant| {
                    switch (variant.fields) {
                        .tuple => |tuple| {
                            for (@constCast(tuple)) |*element| {
                                try bindType(
                                    g,
                                    body_slice,
                                    @intCast(owner_id),
                                    &.{},
                                    pending,
                                    element,
                                );
                            }
                        },
                        .named => |fields| try bindFields(
                            g,
                            body_slice,
                            @intCast(owner_id),
                            &.{},
                            pending,
                            fields,
                        ),
                        .none => {},
                    }
                }
            },
            .trait_ => |*trait_body| {
                for (@constCast(trait_body.methods)) |*method| {
                    try bindParams(
                        g,
                        body_slice,
                        @intCast(owner_id),
                        &.{},
                        pending,
                        method.params,
                    );
                    try bindType(
                        g,
                        body_slice,
                        @intCast(owner_id),
                        &.{},
                        pending,
                        &method.ret,
                    );
                }
            },
            .type_alias => |*alias| try bindType(
                g,
                body_slice,
                @intCast(owner_id),
                &.{},
                pending,
                &alias.target,
            ),
            .none => {},
        }
    }
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
fn mapFields(e: *Ctx, node: ts.Node) ![]const items.Field {
    var fields: std.ArrayListUnmanaged(items.Field) = .empty;
    errdefer fields.deinit(e.alloc);
    if (std.mem.eql(u8, node.kind(), "ordered_field_declaration_list")) {
        var visibility: spine.Visibility = .private;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            if (std.mem.eql(u8, c.kind(), "visibility_modifier")) {
                visibility = .public;
                continue;
            }
            const field_name = node.fieldNameForNamedChild(i) orelse return error.MalformedField;
            if (!std.mem.eql(u8, field_name, "type")) continue;

            const nm = try std.fmt.allocPrint(e.alloc, "{d}", .{fields.items.len});
            errdefer e.alloc.free(nm);
            const field_type: types.Type = try mapType(e, c);
            try fields.append(e.alloc, .{
                .name = nm,
                .ty = field_type,
                .visibility = visibility,
                .span = span_of,
            });
            visibility = .private;
        }
        const mapped_fields: []const items.Field = try fields.toOwnedSlice(e.alloc);
        return mapped_fields;
    }
    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        if (!std.mem.eql(u8, c.kind(), "field_declaration")) continue;
        var fname: ?[]const u8 = null;
        var fty: ?types.Type = null;
        var j: u32 = 0;
        while (c.namedChild(j)) |cc| : (j += 1) {
            const k = cc.kind();
            if (std.mem.eql(u8, k, "field_identifier")) fname = text(e, cc);
            if (std.mem.eql(u8, k, "type") or
                std.mem.eql(u8, k, "primitive_type") or
                std.mem.eql(u8, k, "generic_type") or
                std.mem.eql(u8, k, "type_identifier") or
                std.mem.eql(u8, k, "scoped_type_identifier") or
                std.mem.eql(u8, k, "reference_type") or
                std.mem.eql(u8, k, "array_type"))
            {
                fty = try mapType(e, cc);
            }
        }
        const field_name = fname orelse return error.MalformedField;
        const field_ty = fty orelse return error.MalformedField;
        const name_copy = try e.alloc.dupe(u8, field_name);
        errdefer e.alloc.free(name_copy);
        try fields.append(e.alloc, .{
            .name = name_copy,
            .ty = field_ty,
            .visibility = if (isPub(e, c)) .public else .private,
            .span = span_of,
        });
    }
    const mapped_fields: []const items.Field = try fields.toOwnedSlice(e.alloc);
    return mapped_fields;
}

fn nominalEntity(
    e: *Ctx,
    kind: spine.EntityKind,
    name: []const u8,
    parent: ?spine.EntityId,
    item: ts.Node,
) !spine.EntityId {
    return addEntity(e, kind, name, parent, item);
}

fn nominalItemId(e: *const Ctx) ?spine.EntityId {
    if (e.bodies_list.items.len == 0) return null;
    return @intCast(e.bodies_list.items.len - 1);
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
    if (name.len == 0) return error.MalformedItemName;
    const eid = try nominalEntity(e, .struct_, name, parent, item);
    e.declaration_owner = eid;
    const fields = if (fields_node) |fn_| try mapFields(e, fn_) else &.{};
    const layout: items.struct_kind = if (fields.len == 0) .unit else if (tuple) .tuple else .named;
    const generic_params_slice: []const []const u8 = try generic_params.toOwnedSlice(e.alloc);
    e.bodies_list.items[eid] = .{ .struct_ = .{
        .generic_params = generic_params_slice,
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
    const eid = try nominalEntity(
        e,
        .enum_,
        if (name.len > 0) name else return error.MalformedItemName,
        parent,
        item,
    );
    e.declaration_owner = eid;
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
                    const named_fields: []const items.Field = try mapFields(e, c);
                    ffields = .{ .named = named_fields };
                    vkind = .data;
                } else if (std.mem.eql(u8, kk, "ordered_field_declaration_list")) {
                    var tup: std.ArrayListUnmanaged(types.Type) = .empty;
                    defer tup.deinit(e.alloc);
                    var m: u32 = 0;
                    while (c.namedChild(m)) |t| : (m += 1) {
                        try tup.append(e.alloc, try mapType(e, t));
                    }
                    const tuple_fields: []const types.Type = try tup.toOwnedSlice(e.alloc);
                    ffields = .{ .tuple = tuple_fields };
                    vkind = .data;
                }
            }
            if (vname.len == 0) return error.MalformedVariant;
            if (kind == .c_like) kind = vkind;
            try variants.append(e.alloc, .{
                .name = try e.alloc.dupe(u8, vname),
                .fields = ffields,
                .discriminant = null,
            });
        }
    }
    const variants_slice: []const items.Variant = try variants.toOwnedSlice(e.alloc);
    e.bodies_list.items[eid] = .{ .enum_ = .{
        .kind = kind,
        .variants = variants_slice,
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
    if (name.len == 0) return error.MalformedItemName;
    const eid = try nominalEntity(e, .union_, name, parent, item);
    e.declaration_owner = eid;
    const union_fields: []const items.Field = if (fields_node) |fn_| try mapFields(e, fn_) else &.{};
    e.bodies_list.items[eid] = .{ .struct_ = .{
        .layout = .named,
        .fields = union_fields,
    } };
}

/// Map a `parameters` node into `items.Param` entries. Handles `self_parameter`
/// and `parameter` nodes, extracting the bound name from an `identifier` or a
/// `pattern` (including `mut` / destructured patterns).
fn mapParams(e: *Ctx, params_node: ?ts.Node) ![]const items.Param {
    var params: std.ArrayListUnmanaged(items.Param) = .empty;
    errdefer params.deinit(e.alloc);
    if (params_node) |pn| {
        var j: u32 = 0;
        while (pn.namedChild(j)) |p| : (j += 1) {
            const pk = p.kind();
            if (!std.mem.eql(u8, pk, "parameter") and !std.mem.eql(u8, pk, "self_parameter")) continue;
            var pname: ?[]const u8 = null;
            var pty: ?types.Type = null;
            if (std.mem.eql(u8, pk, "self_parameter")) {
                pname = "self";
                const r = try e.alloc.create(types.Ref);
                r.* = .{ .mut = false, .pointee = .{ .prim = .unit } };
                pty = .{ .reference = r };
            }
            var k: u32 = 0;
            while (p.namedChild(k)) |c| : (k += 1) {
                const kk = c.kind();
                if (std.mem.eql(u8, kk, "identifier")) {
                    if (pname == null) pname = text(e, c);
                } else if (std.mem.eql(u8, kk, "pattern") or
                    std.mem.eql(u8, kk, "mut_pattern") or
                    std.mem.eql(u8, kk, "reference_pattern"))
                {
                    if (pname == null) {
                        var m: u32 = 0;
                        while (c.namedChild(m)) |cc| : (m += 1) {
                            if (std.mem.eql(u8, cc.kind(), "identifier")) {
                                pname = text(e, cc);
                                break;
                            }
                        }
                    }
                } else if (std.mem.eql(u8, kk, "type") or
                    std.mem.eql(u8, kk, "primitive_type") or
                    std.mem.eql(u8, kk, "reference_type") or
                    std.mem.eql(u8, kk, "generic_type") or
                    std.mem.eql(u8, kk, "type_identifier") or
                    std.mem.eql(u8, kk, "scoped_type_identifier") or
                    std.mem.eql(u8, kk, "array_type") or
                    std.mem.eql(u8, kk, "slice_type") or
                    std.mem.eql(u8, kk, "tuple_type") or
                    std.mem.eql(u8, kk, "unit_type"))
                {
                    pty = try mapType(e, c);
                }
            }
            const param_name = pname orelse return error.MalformedParameter;
            const param_ty = pty orelse return error.MalformedParameter;
            const name_copy = try e.alloc.dupe(u8, param_name);
            errdefer e.alloc.free(name_copy);
            try params.append(e.alloc, .{
                .name = name_copy,
                .ty = param_ty,
                .span = span_of,
            });
        }
    }
    const mapped_params: []const items.Param = try params.toOwnedSlice(e.alloc);
    return mapped_params;
}

fn traitItem(e: *Ctx, item: ts.Node, parent: ?spine.EntityId) !void {
    var name: []const u8 = "";
    var decls: ?ts.Node = null;
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        if (std.mem.eql(u8, c.kind(), "type_identifier")) name = text(e, c);
        if (std.mem.eql(u8, c.kind(), "declaration_list")) decls = c;
    }
    const eid = try nominalEntity(e, .trait_, name, parent, item);
    e.declaration_owner = eid;
    var methods: std.ArrayListUnmanaged(bodies.TraitMethodSig) = .empty;
    errdefer methods.deinit(e.alloc);
    if (decls) |dl| {
        var j: u32 = 0;
        while (dl.namedChild(j)) |m| : (j += 1) {
            if (!std.mem.eql(u8, m.kind(), "function_signature_item")) continue;
            var mname: []const u8 = "";
            var mparams_node: ?ts.Node = null;
            var k: u32 = 0;
            while (m.namedChild(k)) |c| : (k += 1) {
                const kk = c.kind();
                if (std.mem.eql(u8, kk, "identifier")) mname = text(e, c);
                if (std.mem.eql(u8, kk, "parameters")) mparams_node = c;
            }
            if (mname.len == 0) return error.MalformedItemName;
            const mret = try mapReturnType(e, m);
            const mparams = try mapParams(e, mparams_node);
            var receiver: items.Receiver = .ref_;
            var params = mparams;
            if (mparams.len > 0 and std.mem.eql(u8, mparams[0].name, "self")) {
                if (mparams[0].ty == .reference) {
                    if (mparams[0].ty.reference.*.mut) {
                        receiver = .mut_ref;
                    } else {
                        receiver = .ref_;
                    }
                } else {
                    receiver = .owned;
                }
                params = mparams[1..];
            }
            try methods.append(e.alloc, .{
                .name = try e.alloc.dupe(u8, mname),
                .params = params,
                .ret = mret,
                .receiver = receiver,
            });
        }
    }
    const trait_name: []const u8 = try e.alloc.dupe(u8, name);
    errdefer e.alloc.free(trait_name);
    const trait_methods: []const bodies.TraitMethodSig = try methods.toOwnedSlice(e.alloc);
    e.bodies_list.items[eid] = .{ .trait_ = .{
        .name = trait_name,
        .supertraits = &.{},
        .methods = trait_methods,
    } };
}

fn typeAliasItem(e: *Ctx, item: ts.Node, parent: ?spine.EntityId) !void {
    var name: []const u8 = "";
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        if (std.mem.eql(u8, c.kind(), "type_identifier")) {
            name = text(e, c);
            break;
        }
    }
    if (name.len == 0) return error.MalformedItemName;
    const alias_id = try nominalEntity(e, .type_alias, name, parent, item);
    e.declaration_owner = alias_id;

    var target: ?types.Type = null;
    var skipped_name = false;
    i = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "type_identifier") and !skipped_name) {
            skipped_name = true;
            continue;
        }
        if (std.mem.eql(u8, k, "type") or
            std.mem.eql(u8, k, "generic_type") or
            std.mem.eql(u8, k, "primitive_type") or
            std.mem.eql(u8, k, "type_identifier") or
            std.mem.eql(u8, k, "scoped_type_identifier") or
            std.mem.eql(u8, k, "reference_type") or
            std.mem.eql(u8, k, "array_type") or
            std.mem.eql(u8, k, "slice_type") or
            std.mem.eql(u8, k, "tuple_type") or
            std.mem.eql(u8, k, "unit_type"))
        {
            target = try mapType(e, c);
        }
    }
    const alias_target = target orelse return error.MalformedTypeAlias;
    e.bodies_list.items[alias_id] = .{ .type_alias = .{ .target = alias_target } };
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
fn lowerConstString(e: *Ctx, node: ts.Node) !exprs.NodeId {
    const raw = text(e, node);
    const kind = node.kind();
    const is_byte = std.mem.eql(u8, kind, "byte_string_literal") or
        std.mem.eql(u8, kind, "byte_literal") or
        std.mem.startsWith(u8, raw, "b");
    if (try decodeRustByteLiteral(e.alloc, raw)) |bytes| {
        errdefer e.alloc.free(bytes);
        const id: exprs.NodeId = try appendExpr(e, .{ .literal = .{ .byte_array = .{ .items = bytes } } });
        return id;
    }
    if (std.mem.startsWith(u8, raw, "r")) {
        const bytes = (try decodeRawBytes(e.alloc, raw, 1)) orelse return error.InvalidLiteral;
        errdefer e.alloc.free(bytes);
        const id: exprs.NodeId = try appendExpr(e, .{ .literal = .{ .byte_array = .{ .items = bytes } } });
        return id;
    }
    if (is_byte) return error.UnsupportedConstInitializer;
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') {
        return error.InvalidLiteral;
    }
    const bytes = try e.alloc.dupe(u8, raw[1 .. raw.len - 1]);
    errdefer e.alloc.free(bytes);
    const id: exprs.NodeId = try appendExpr(e, .{ .literal = .{ .string = .{ .bytes = bytes } } });
    return id;
}

const ConstLowerError = std.mem.Allocator.Error || error{
    InvalidConstArray,
    InvalidLiteral,
    UnsupportedConstInitializer,
};

fn lowerConstArray(e: *Ctx, node: ts.Node) ConstLowerError!exprs.NodeId {
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
        const en = elem orelse return error.InvalidConstArray;
        const elem_id = try lowerConstInit(e, en);
        if (!std.mem.eql(u8, len_node.kind(), "integer_literal")) return error.InvalidConstArray;
        const len = std.fmt.parseInt(usize, text(e, len_node), 10) catch return error.InvalidConstArray;
        var elems: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
        defer elems.deinit(e.alloc);
        try elems.append(e.alloc, elem_id);
        const elements: []const exprs.NodeId = try elems.toOwnedSlice(e.alloc);
        errdefer e.alloc.free(elements);
        const id: exprs.NodeId = try appendExpr(e, .{ .array = .{
            .elements = elements,
            .repeat = len,
        } });
        return id;
    }

    var elements: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
    defer elements.deinit(e.alloc);
    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        if (isComment(c)) continue;
        try elements.append(e.alloc, try lowerConstInit(e, c));
    }
    const owned_elements: []const exprs.NodeId = try elements.toOwnedSlice(e.alloc);
    errdefer e.alloc.free(owned_elements);
    const id: exprs.NodeId = try appendExpr(e, .{ .array = .{
        .elements = owned_elements,
        .repeat = null,
    } });
    return id;
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

const max_const_eval_depth: usize = 64;

fn isConstTypeNodeKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "type") or
        std.mem.eql(u8, kind, "generic_type") or
        std.mem.eql(u8, kind, "primitive_type") or
        std.mem.eql(u8, kind, "type_identifier") or
        std.mem.eql(u8, kind, "scoped_type_identifier") or
        std.mem.eql(u8, kind, "reference_type") or
        std.mem.eql(u8, kind, "pointer_type") or
        std.mem.eql(u8, kind, "array_type") or
        std.mem.eql(u8, kind, "slice_type") or
        std.mem.eql(u8, kind, "tuple_type") or
        std.mem.eql(u8, kind, "unit_type");
}

fn constInitializerNode(e: *const Ctx, item: ts.Node) ?ts.Node {
    var found_name = false;
    var initializer: ?ts.Node = null;
    var i: u32 = 0;
    while (item.namedChild(i)) |child| : (i += 1) {
        const kind = child.kind();
        if (!found_name and std.mem.eql(u8, kind, "identifier")) {
            found_name = true;
            continue;
        }
        if (std.mem.eql(u8, kind, "visibility_modifier") or
            std.mem.eql(u8, kind, "attribute_item"))
        {
            continue;
        }
        if (isConstTypeNodeKind(kind)) continue;
        if (initializer != null) return null;
        initializer = child;
    }
    _ = e;
    return initializer;
}

fn typeAliasTargetNode(item: ts.Node) ?ts.Node {
    var found_name = false;
    var i: u32 = 0;
    while (item.namedChild(i)) |child| : (i += 1) {
        const kind = child.kind();
        if (!found_name and std.mem.eql(u8, kind, "type_identifier")) {
            found_name = true;
            continue;
        }
        if (isConstTypeNodeKind(kind)) return child;
    }
    return null;
}

fn constDeclarationByName(e: *const Ctx, name: []const u8) ?ConstDeclaration {
    var environment = e.const_environment;
    while (environment) |current| {
        var found: ?ConstDeclaration = null;
        var duplicate = false;
        for (current.consts.items) |declaration| {
            if (!std.mem.eql(u8, declaration.name, name)) continue;
            if (found != null) {
                duplicate = true;
                break;
            }
            found = declaration;
        }
        if (duplicate) return null;
        if (found) |declaration| return declaration;
        environment = current.parent;
    }
    return null;
}

fn typeAliasDeclarationByName(e: *const Ctx, name: []const u8) ?TypeAliasDeclaration {
    var environment = e.const_environment;
    while (environment) |current| {
        var found: ?TypeAliasDeclaration = null;
        var duplicate = false;
        for (current.aliases.items) |declaration| {
            if (!std.mem.eql(u8, declaration.name, name)) continue;
            if (found != null) {
                duplicate = true;
                break;
            }
            found = declaration;
        }
        if (duplicate) return null;
        if (found) |declaration| return declaration;
        environment = current.parent;
    }
    return null;
}

fn primitiveSizeOfName(e: *const Ctx, name: []const u8, depth: usize) ?i128 {
    if (depth >= max_const_eval_depth) return null;
    const primitive = mapPrim(std.mem.trim(u8, name, " \t\r\n"));
    if (primitive) |value| {
        return switch (value) {
            .i8, .u8 => 1,
            .i16, .u16 => 2,
            .i32, .u32, .f32 => 4,
            .i64, .u64, .f64 => 8,
            .i128, .u128 => 16,
            .isize, .usize => blk: {
                const width = e.cfg.target_pointer_width orelse @as(u16, @bitSizeOf(usize));
                if (width == 0 or width % 8 != 0) break :blk null;
                break :blk @as(i128, width / 8);
            },
            .bool => 1,
            .char => 4,
            .unit => 0,
            .never => null,
        };
    }
    const alias = typeAliasDeclarationByName(e, std.mem.trim(u8, name, " \t\r\n")) orelse
        return null;
    if (alias.target_name) |target_name| {
        return primitiveSizeOfName(e, target_name, depth + 1);
    }
    const alias_item = alias.item orelse return null;
    const target = typeAliasTargetNode(alias_item) orelse return null;
    return primitiveSizeOfName(e, text(e, target), depth + 1);
}
fn sizeOfTypeName(e: *const Ctx, raw: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    const prefixes = [_][]const u8{
        "core::mem::size_of::<",
        "std::mem::size_of::<",
        "::core::mem::size_of::<",
        "::std::mem::size_of::<",
    };
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, value, prefix)) continue;
        const suffix = ">()";
        if (!std.mem.endsWith(u8, value, suffix)) return null;
        const type_name = std.mem.trim(
            u8,
            value[prefix.len .. value.len - suffix.len],
            " \t\r\n",
        );
        if (type_name.len == 0) return null;
        return type_name;
    }

    const marker = "::size_of::<";
    const marker_index = std.mem.indexOf(u8, value, marker) orelse return null;
    const alias_name = std.mem.trim(u8, value[0..marker_index], " \t\r\n");
    const suffix = ">()";
    if (alias_name.len == 0 or !std.mem.endsWith(u8, value, suffix)) return null;
    const type_name = std.mem.trim(
        u8,
        value[marker_index + marker.len .. value.len - suffix.len],
        " \t\r\n",
    );
    if (type_name.len == 0) return null;

    const external_path = externalUsePath(e, alias_name) catch return null;
    if (external_path) |path| {
        defer freeExternalPath(e, path);
        if (path.len != 2) return null;
        if ((!std.mem.eql(u8, path[0], "core") and
            !std.mem.eql(u8, path[0], "std")) or
            !std.mem.eql(u8, path[1], "mem"))
        {
            return null;
        }
        return type_name;
    }
    return null;
}

fn checkedAdd(left: i128, right: i128) ?i128 {
    const result = @addWithOverflow(left, right);
    if (result[1] != 0) return null;
    return result[0];
}

fn checkedSub(left: i128, right: i128) ?i128 {
    const result = @subWithOverflow(left, right);
    if (result[1] != 0) return null;
    return result[0];
}

fn checkedMul(left: i128, right: i128) ?i128 {
    const result = @mulWithOverflow(left, right);
    if (result[1] != 0) return null;
    return result[0];
}

fn checkedNeg(value: i128) ?i128 {
    if (value == std.math.minInt(i128)) return null;
    return -value;
}

fn checkedDiv(left: i128, right: i128) ?i128 {
    if (right == 0) return null;
    if (left == std.math.minInt(i128) and right == -1) return null;
    return @divTrunc(left, right);
}

fn checkedRem(left: i128, right: i128) ?i128 {
    if (right == 0) return null;
    if (left == std.math.minInt(i128) and right == -1) return null;
    return @rem(left, right);
}

fn checkedShiftLeft(left: i128, right: i128) ?i128 {
    if (right < 0 or right >= 128) return null;
    if (right == 127) return if (left == 0) 0 else null;
    const shift: u7 = @intCast(right);
    const factor: i128 = @as(i128, 1) << shift;
    return checkedMul(left, factor);
}

fn checkedShiftRight(left: i128, right: i128) ?i128 {
    if (right < 0 or right >= 128) return null;
    return left >> @as(u7, @intCast(right));
}

const IntegerCastTarget = struct {
    bits: u16,
    signed: bool,
};

fn integerCastTarget(e: *const Ctx, node: ts.Node) ?IntegerCastTarget {
    var target_node = node.childByFieldName("type") orelse node.namedChild(1) orelse return null;
    while (std.mem.eql(u8, target_node.kind(), "type")) {
        if (target_node.namedChildCount() != 1) return null;
        target_node = target_node.namedChild(0).?;
    }
    const primitive = mapPrim(std.mem.trim(u8, text(e, target_node), " \t\r\n")) orelse return null;
    const signed = switch (primitive) {
        .i8, .i16, .i32, .i64, .i128, .isize => true,
        .u8, .u16, .u32, .u64, .u128, .usize => false,
        else => return null,
    };
    const bits: u16 = switch (primitive) {
        .i8, .u8 => 8,
        .i16, .u16 => 16,
        .i32, .u32 => 32,
        .i64, .u64 => 64,
        .i128, .u128 => 128,
        .isize, .usize => e.cfg.target_pointer_width orelse @as(u16, @bitSizeOf(usize)),
        else => return null,
    };
    if (bits == 0 or bits > 128 or bits % 8 != 0) return null;
    return .{ .bits = bits, .signed = signed };
}

fn checkedIntegerCastValue(value: i128, target: IntegerCastTarget) ?i128 {
    const mask: u128 = if (target.bits == 128) blk: {
        break :blk std.math.maxInt(u128);
    } else blk: {
        const bits: u7 = @intCast(target.bits);
        break :blk (@as(u128, 1) << bits) - 1;
    };
    const truncated: u128 = @as(u128, @bitCast(value)) & mask;
    if (!target.signed) {
        if (target.bits == 128) return @bitCast(truncated);
        return @intCast(truncated);
    }
    const sign_bit: u128 = @as(u128, 1) << @as(u7, @intCast(target.bits - 1));
    if ((truncated & sign_bit) == 0) return @intCast(truncated);
    return @bitCast(truncated | ~mask);
}

fn constIntegerCastValueAt(
    e: *const Ctx,
    node: ts.Node,
    depth: usize,
) ConstLowerError!?i128 {
    const target = integerCastTarget(e, node) orelse return error.UnsupportedConstInitializer;
    const operand = node.childByFieldName("value") orelse node.namedChild(0) orelse return null;
    const value = constIntegerValueAt(e, operand, depth + 1) orelse return null;
    return checkedIntegerCastValue(value, target);
}

fn constIntegerValueAt(e: *const Ctx, node: ts.Node, depth: usize) ?i128 {
    if (depth >= max_const_eval_depth) return null;
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "integer_literal")) {
        return (parseConstIntText(text(e, node)) orelse return null).value;
    }
    if (std.mem.eql(u8, kind, "identifier") or std.mem.eql(u8, kind, "type_identifier")) {
        const declaration = constDeclarationByName(e, text(e, node)) orelse return null;
        if (declaration.value) |value| return value;
        const item = declaration.item orelse return null;
        const initializer = constInitializerNode(e, item) orelse return null;
        return constIntegerValueAt(e, initializer, depth + 1);
    }
    if (std.mem.eql(u8, kind, "call_expression")) {
        const type_name = sizeOfTypeName(e, text(e, node)) orelse return null;
        return primitiveSizeOfName(e, type_name, depth + 1);
    }
    if (std.mem.eql(u8, kind, "type_cast_expression")) {
        return constIntegerCastValueAt(e, node, depth) catch null;
    }
    if (std.mem.eql(u8, kind, "expression") or
        std.mem.eql(u8, kind, "parenthesized_expression") or
        std.mem.eql(u8, kind, "reference_expression") or
        std.mem.eql(u8, kind, "unsafe_expression"))
    {
        if (node.namedChildCount() == 0) return null;
        return constIntegerValueAt(e, node.namedChild(0).?, depth + 1);
    }
    if (std.mem.eql(u8, kind, "unary_expression")) {
        if (node.namedChildCount() == 0) return null;
        const operand = node.namedChild(node.namedChildCount() - 1).?;
        const value = constIntegerValueAt(e, operand, depth + 1) orelse return null;
        const raw = text(e, node);
        const op_len = operand.startByte() - node.startByte();
        const op = std.mem.trim(u8, raw[0..op_len], " \t\r\n");
        if (std.mem.eql(u8, op, "-")) return checkedNeg(value);
        if (std.mem.eql(u8, op, "+")) return value;
        if (std.mem.eql(u8, op, "!")) return ~value;
        return null;
    }
    if (std.mem.eql(u8, kind, "binary_expression")) {
        if (node.namedChildCount() < 2) return null;
        const left = node.namedChild(0).?;
        const right = node.namedChild(node.namedChildCount() - 1).?;
        const lhs = constIntegerValueAt(e, left, depth + 1) orelse return null;
        const rhs = constIntegerValueAt(e, right, depth + 1) orelse return null;
        const op = constOperator(e, left, right);
        if (std.mem.eql(u8, op, "+")) return checkedAdd(lhs, rhs);
        if (std.mem.eql(u8, op, "-")) return checkedSub(lhs, rhs);
        if (std.mem.eql(u8, op, "*")) return checkedMul(lhs, rhs);
        if (std.mem.eql(u8, op, "/")) return checkedDiv(lhs, rhs);
        if (std.mem.eql(u8, op, "%")) return checkedRem(lhs, rhs);
        if (std.mem.eql(u8, op, "&")) return lhs & rhs;
        if (std.mem.eql(u8, op, "|")) return lhs | rhs;
        if (std.mem.eql(u8, op, "^")) return lhs ^ rhs;
        if (std.mem.eql(u8, op, "<<")) return checkedShiftLeft(lhs, rhs);
        if (std.mem.eql(u8, op, ">>")) return checkedShiftRight(lhs, rhs);
    }
    return null;
}

/// Evaluate the integer-only subset needed by Rust const initializers.
fn constIntegerValue(e: *const Ctx, node: ts.Node) ?i128 {
    return constIntegerValueAt(e, node, 0);
}

fn lowerConstIntegerValue(e: *Ctx, value: i128) ConstLowerError!exprs.NodeId {
    const number = try std.fmt.allocPrint(e.alloc, "{d}", .{value});
    errdefer e.alloc.free(number);
    return appendExpr(e, .{ .literal = .{ .int = .{
        .text = number,
        .value = value,
        .base = .dec,
        .ty_suffix = null,
    } } });
}

/// Lower a const initializer expression into the expr table.
fn lowerConstInit(e: *Ctx, node: ts.Node) ConstLowerError!exprs.NodeId {
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "type_cast_expression")) {
        const value = try constIntegerCastValueAt(e, node, 0);
        return lowerConstIntegerValue(e, value orelse return error.UnsupportedConstInitializer);
    }
    if (std.mem.eql(u8, kind, "expression") or
        std.mem.eql(u8, kind, "parenthesized_expression") or
        std.mem.eql(u8, kind, "reference_expression") or
        std.mem.eql(u8, kind, "unsafe_expression"))
    {
        if (node.namedChildCount() > 0) {
            const id: exprs.NodeId = try lowerConstInit(e, node.namedChild(0).?);
            return id;
        }
        return error.UnsupportedConstInitializer;
    }
    if (std.mem.eql(u8, kind, "array_expression")) {
        const id: exprs.NodeId = try lowerConstArray(e, node);
        return id;
    }
    if (std.mem.eql(u8, kind, "integer_literal")) {
        const t = text(e, node);
        const parsed = parseConstIntText(t) orelse return error.InvalidLiteral;
        const suffix = if (parsed.suffix.len == 0)
            null
        else
            try e.alloc.dupe(u8, parsed.suffix);
        errdefer if (suffix) |s| e.alloc.free(s);
        const text_copy = try e.alloc.dupe(u8, parsed.body);
        errdefer e.alloc.free(text_copy);
        const id: exprs.NodeId = try appendExpr(e, .{ .literal = .{ .int = .{
            .text = text_copy,
            .value = parsed.value,
            .base = if (parsed.base == 16) .hex else if (parsed.base == 2) .bin else if (parsed.base == 8) .oct else .dec,
            .ty_suffix = suffix,
        } } });
        return id;
    }
    if (std.mem.eql(u8, kind, "identifier") or
        std.mem.eql(u8, kind, "type_identifier") or
        std.mem.eql(u8, kind, "call_expression") or
        std.mem.eql(u8, kind, "binary_expression") or
        std.mem.eql(u8, kind, "unary_expression"))
    {
        const value = constIntegerValue(e, node) orelse return error.UnsupportedConstInitializer;
        return lowerConstIntegerValue(e, value);
    }
    if (std.mem.eql(u8, kind, "float_literal")) {
        const t = text(e, node);
        const text_copy = try e.alloc.dupe(u8, t);
        errdefer e.alloc.free(text_copy);
        const value = std.fmt.parseFloat(f64, t) catch return error.InvalidLiteral;
        const id: exprs.NodeId = try appendExpr(e, .{ .literal = .{ .float = .{
            .text = text_copy,
            .value = value,
        } } });
        return id;
    }
    if (std.mem.eql(u8, kind, "char_literal") or std.mem.eql(u8, kind, "byte_literal")) {
        const t = text(e, node);
        const is_byte = std.mem.eql(u8, kind, "byte_literal") or std.mem.startsWith(u8, t, "b");
        if (try decodeRustByteLiteral(e.alloc, t)) |bytes| {
            errdefer e.alloc.free(bytes);
            const id: exprs.NodeId = try appendExpr(e, .{ .literal = .{ .byte_array = .{ .items = bytes } } });
            return id;
        }
        if (is_byte) return error.UnsupportedConstInitializer;
        if (t.len < 3 or t[0] != '\'' or t[t.len - 1] != '\'') return error.InvalidLiteral;
        const text_copy = try e.alloc.dupe(u8, t);
        errdefer e.alloc.free(text_copy);
        const id: exprs.NodeId = try appendExpr(e, .{ .literal = .{ .character = .{
            .text = text_copy,
            .value = t[1],
        } } });
        return id;
    }
    if (std.mem.eql(u8, kind, "boolean_literal")) {
        const value = text(e, node);
        if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) {
            return error.InvalidLiteral;
        }
        const id: exprs.NodeId = try appendExpr(e, .{ .literal = .{ .boolean = std.mem.eql(u8, value, "true") } });
        return id;
    }
    if (std.mem.eql(u8, kind, "string_literal") or
        std.mem.eql(u8, kind, "byte_string_literal") or
        std.mem.eql(u8, kind, "raw_string_literal"))
    {
        const id: exprs.NodeId = try lowerConstString(e, node);
        return id;
    }
    return error.UnsupportedConstInitializer;
}

fn constItem(e: *Ctx, item: ts.Node, parent: ?spine.EntityId) !void {
    var name: []const u8 = "";
    var type_node: ?ts.Node = null;
    var init_node: ?ts.Node = null;
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "identifier") and name.len == 0) {
            name = text(e, c);
            continue;
        }
        if (std.mem.eql(u8, k, "visibility_modifier") or
            std.mem.eql(u8, k, "attribute_item"))
        {
            continue;
        }
        if (std.mem.eql(u8, k, "type") or
            std.mem.eql(u8, k, "primitive_type") or
            std.mem.eql(u8, k, "generic_type") or
            std.mem.eql(u8, k, "type_identifier") or
            std.mem.eql(u8, k, "scoped_type_identifier") or
            std.mem.eql(u8, k, "array_type") or
            std.mem.eql(u8, k, "reference_type") or
            std.mem.eql(u8, k, "pointer_type") or
            std.mem.eql(u8, k, "slice_type") or
            std.mem.eql(u8, k, "tuple_type") or
            std.mem.eql(u8, k, "unit_type"))
        {
            type_node = c;
            continue;
        }
        if (init_node != null) return error.MalformedConstInitializer;
        init_node = c;
    }
    if (name.len == 0) return error.MalformedItemName;
    const initializer = init_node orelse return error.UnsupportedConstInitializer;
    const eid = try addEntity(e, .const_, name, parent, item);
    e.declaration_owner = eid;
    const const_ty = try mapType(e, type_node orelse return error.MalformedConstType);
    const init_id = try lowerConstInit(e, initializer);
    e.bodies_list.items[eid] = .{ .const_ = .{ .ty = const_ty, .init = init_id } };

    if (arrayElemTy(const_ty)) |elem| {
        if (e.exprs_list.items[init_id].kind == .array) {
            const tid = try appendType(e, elem);
            e.exprs_list.items[init_id].ty = tid;
        }
    }
}

fn lexicalModuleForParent(g: *const graph.CrateGraph, parent: ?spine.EntityId) spine.EntityId {
    var current = parent;
    var depth: usize = 0;
    while (current) |p| : (depth += 1) {
        if (depth >= g.symbol_table.entities.items.len) break;
        const ent = g.symbol_table.get(p) orelse break;
        if (ent.kind == .module) return p;
        current = ent.parent;
    }
    return 0;
}

fn functionItem(e: *Ctx, item: ts.Node, parent: ?spine.EntityId, is_trait_sig: bool) !void {
    _ = is_trait_sig;
    var name: []const u8 = "";
    var params_node: ?ts.Node = null;
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "identifier")) name = text(e, c);
        if (std.mem.eql(u8, k, "parameters")) params_node = c;
    }
    if (name.len == 0) return error.MalformedItemName;
    const generic_params = try collectFunctionGenericParams(e, item);
    const eid = try addEntity(e, .fn_, name, parent, item);
    if (e.function_origins) |origins| {
        const lexical_mod = lexicalModuleForParent(e.g, parent);
        const fn_src = try e.alloc.dupe(u8, text(e, item));
        try origins.put(e.alloc, eid, .{
            .lexical_module = lexical_mod,
            .source = fn_src,
        });
    }
    e.declaration_owner = eid;
    const ret = try mapReturnType(e, item);
    const params = try mapParams(e, params_node);
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
/// Seed an external-use candidate before the names pass. Declaration types can
/// be mapped while the CST walk is still in progress; the names pass later
/// replaces this candidate with a local target when scope resolution succeeds.
fn provisionalExternalUsePath(
    e: *Ctx,
    full_path: []const u8,
    parent: ?spine.EntityId,
) !?[]const []const u8 {
    if (std.mem.endsWith(u8, full_path, "::*")) return null;
    var source = std.mem.trim(u8, full_path, " \t\r\n");
    if (std.mem.startsWith(u8, source, "::")) source = source[2..];
    if (std.mem.indexOf(u8, source, " as ")) |alias_index| {
        source = std.mem.trim(u8, source[0..alias_index], " \t\r\n");
    }
    var parts = std.mem.splitSequence(u8, source, "::");
    const first = parts.next() orelse return null;
    if (!std.mem.eql(u8, first, "core") and
        !std.mem.eql(u8, first, "std") and
        !std.mem.eql(u8, first, "alloc"))
        return null;
    if (parent) |module_id| {
        if (resolveModuleItem(e.g, module_id, first)) |root_id| {
            const root_entity = e.g.symbol_table.get(root_id) orelse return null;
            if (root_entity.kind != .extern_crate) return null;
        }
    }
    var count: usize = 1;
    while (parts.next()) |_| count += 1;
    const path = try e.alloc.alloc([]const u8, count);
    var copied: usize = 0;
    errdefer {
        for (path[0..copied]) |segment| e.alloc.free(segment);
        e.alloc.free(path);
    }
    var fill = std.mem.splitSequence(u8, source, "::");
    for (path) |*segment| {
        const value = fill.next() orelse return error.InvalidType;
        if (value.len == 0) return error.InvalidType;
        segment.* = try e.alloc.dupe(u8, value);
        copied += 1;
    }
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
    const kind: graph.UseKind = if (try provisionalExternalUsePath(e, full_path, parent)) |path|
        .{ .external = .{ .path = path } }
    else
        .{ .plain = 0 };
    const eid = try addEntity(e, .use_, full_path, parent, null);
    e.g.symbol_table.entities.items[eid].visibility = if (is_pub) .public else .private;
    try item_ids.append(e.alloc, eid);
    try e.g.addUse(.{
        .id = eid,
        .kind = kind,
        .local_name = if (local_name.len > 0) try e.alloc.dupe(u8, local_name) else "",
        .is_pub_export = is_pub,
        .target = 0,
        .span = span_of,
    });
}
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
/// Resolve an impl target through the current lexical module scope.
fn implTargetEntity(
    e: *const Ctx,
    mod_id: spine.EntityId,
    target_path: []const u8,
) ?spine.EntityId {
    var segments: std.ArrayListUnmanaged(types.PathSegment) = .empty;
    defer segments.deinit(e.alloc);
    var source = std.mem.trim(u8, target_path, " \t\r\n");
    if (std.mem.startsWith(u8, source, "::")) source = source[2..];
    if (source.len == 0) return null;
    var parts = std.mem.splitSequence(u8, source, "::");
    while (parts.next()) |part| {
        const name = std.mem.trim(u8, part, " \t\r\n");
        if (name.len == 0) return null;
        segments.append(e.alloc, .{ .name = name, .id = null }) catch return null;
    }
    var path: types.Path = .{ .segments = segments.items };
    bindPath(e.g, e.bodies_list.items, mod_id, &.{}, &path) catch return null;
    const target_id = path.segments[path.segments.len - 1].id orelse return null;
    const target = e.g.symbol_table.get(target_id) orelse return null;
    return switch (target.kind) {
        .struct_, .enum_, .union_ => target.id,
        else => null,
    };
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

    var first_named_type: ?[]const u8 = null;
    var final_named_type: ?[]const u8 = null;
    var named_type_count: u32 = 0;
    var i: u32 = 0;
    while (item.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "type_identifier") or
            std.mem.eql(u8, k, "generic_type") or
            std.mem.eql(u8, k, "primitive_type") or
            std.mem.eql(u8, k, "scoped_type_identifier") or
            std.mem.eql(u8, k, "type_path"))
        {
            const type_name = text(e, c);
            if (first_named_type == null) first_named_type = type_name;
            final_named_type = type_name;
            named_type_count += 1;
        } else if (std.mem.eql(u8, k, "declaration_list")) {
            if (decl_list == null) decl_list = c;
        }
    }
    if (final_named_type) |receiver_name| {
        if (named_type_count > 1) {
            if (trait_name == null) trait_name = first_named_type.?;
            self_ty_name = receiver_name;
        } else if (self_ty_name.len == 0) {
            self_ty_name = receiver_name;
        }
    }
    if (self_ty_name.len == 0) return error.MalformedImpl;
    if (decl_list == null) return error.MalformedImpl;

    var target_path = std.mem.trim(u8, self_ty_name, " \t\r\n");
    const for_separator = " for ";
    if (std.mem.lastIndexOf(u8, target_path, for_separator)) |for_index| {
        if (trait_name == null) {
            trait_name = std.mem.trim(u8, target_path[0..for_index], " \t\r\n");
        }
        self_ty_name = std.mem.trim(
            u8,
            target_path[for_index + for_separator.len ..],
            " \t\r\n",
        );
        target_path = self_ty_name;
    }
    if (std.mem.startsWith(u8, target_path, "mut ")) {
        target_path = target_path[4..];
    }
    if (std.mem.indexOf(u8, target_path, "<")) |idx| {
        target_path = target_path[0..idx];
    }
    target_path = std.mem.trim(u8, target_path, " \t\r\n");
    var target_name = target_path;
    if (std.mem.lastIndexOf(u8, target_name, "::")) |idx| {
        target_name = target_name[idx + 2 ..];
    }
    target_name = std.mem.trim(u8, target_name, " \t\r\n");

    const primitive_target = mapPrim(target_name) != null;
    const target_id = if (primitive_target)
        null
    else
        implTargetEntity(e, mod_id, target_path);
    if (target_id == null and !primitive_target and e.pending_impls == null) {
        return error.UnresolvedImplTarget;
    }

    const name = if (trait_name) |tr|
        try std.fmt.allocPrint(e.alloc, "{s} for {s}", .{ tr, self_ty_name })
    else
        try e.alloc.dupe(u8, self_ty_name);

    // Both inherent impls (`impl Type { ... }`) and trait impls
    // (`impl Trait for Type { ... }`) parent their methods to the resolved
    // target struct, allowing the backend to hoist the methods there.
    const impl_id = try addEntity(e, .impl_, name, target_id orelse mod_id, item);
    var pending_methods: std.ArrayListUnmanaged(PendingImplMethod) = .empty;
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
                                mret = try mapReturnType(e, child);
                                const generic_params = try collectFunctionGenericParams(e, child);

                                const all_params = try mapParams(e, mparams_node);
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
                if (target_id == null and !primitive_target) {
                    var receiver: ?items.Receiver = null;
                    var parameter_node: ?ts.Node = null;
                    var k: u32 = 0;
                    while (child.namedChild(k)) |c| : (k += 1) {
                        if (std.mem.eql(u8, c.kind(), "parameters")) {
                            parameter_node = c;
                            break;
                        }
                    }
                    if (parameter_node) |pn| {
                        var pi: u32 = 0;
                        while (pn.namedChild(pi)) |p| : (pi += 1) {
                            if (!std.mem.eql(u8, p.kind(), "self_parameter")) continue;
                            const p_text = text(e, p);
                            if (std.mem.indexOf(u8, p_text, "&mut") != null) {
                                receiver = .mut_ref;
                            } else if (std.mem.indexOfScalar(u8, p_text, '&') != null) {
                                receiver = .ref_;
                            } else {
                                receiver = .owned;
                            }
                            break;
                        }
                    }
                    const function_id: spine.EntityId = @intCast(e.bodies_list.items.len - 1);
                    try pending_methods.append(e.alloc, .{
                        .function_id = function_id,
                        .receiver = receiver,
                    });
                }
            } else if (std.mem.eql(u8, child.kind(), "const_item")) {
                try constItem(e, child, impl_id);
            } else if (std.mem.eql(u8, child.kind(), "type_item")) {
                try typeAliasItem(e, child, impl_id);
            }
        }
    }
    if (target_id == null and !primitive_target) {
        const pending = e.pending_impls orelse return error.UnresolvedImplTarget;
        const path_copy = try e.alloc.dupe(u8, target_path);
        const methods = try pending_methods.toOwnedSlice(e.alloc);
        try pending.append(e.alloc, .{
            .impl_id = impl_id,
            .module_id = mod_id,
            .target_path = path_copy,
            .methods = methods,
        });
    } else {
        pending_methods.deinit(e.alloc);
    }

    return impl_id;
}
fn finalizePendingImpls(
    e: *Ctx,
    pending: *std.ArrayListUnmanaged(PendingImpl),
) !void {
    for (pending.items) |impl| {
        const target_id = implTargetEntity(e, impl.module_id, impl.target_path) orelse
            return error.UnresolvedImplTarget;

        e.g.symbol_table.entities.items[impl.impl_id].parent = target_id;

        if (target_id >= e.bodies_list.items.len) continue;
        switch (e.bodies_list.items[target_id]) {
            .struct_ => |*structure| {
                for (impl.methods) |method| {
                    if (method.function_id >= e.bodies_list.items.len) {
                        return error.UnresolvedImplTarget;
                    }
                    const fn_entity = e.g.symbol_table.get(method.function_id) orelse
                        return error.UnresolvedImplTarget;
                    const function_body = switch (e.bodies_list.items[method.function_id]) {
                        .fn_ => |body| body,
                        else => return error.UnresolvedImplTarget,
                    };
                    var receiver = method.receiver;
                    var method_params = function_body.params;
                    if (receiver == null and method_params.len > 0 and
                        std.mem.eql(u8, method_params[0].name, "self"))
                    {
                        if (method_params[0].ty == .reference) {
                            receiver = if (method_params[0].ty.reference.*.mut) .mut_ref else .ref_;
                        } else {
                            receiver = .owned;
                        }
                    }
                    if (receiver != null and method_params.len > 0 and
                        std.mem.eql(u8, method_params[0].name, "self"))
                    {
                        method_params = method_params[1..];
                    }
                    var method_exists = false;
                    for (structure.methods) |existing| {
                        if (std.mem.eql(u8, existing.name, fn_entity.name)) {
                            method_exists = true;
                            break;
                        }
                    }
                    if (method_exists) continue;
                    const new_method: bodies.StructMethod = .{
                        .name = try e.alloc.dupe(u8, fn_entity.name),
                        .visibility = if (std.mem.indexOf(u8, e.g.symbol_table.entities.items[impl.impl_id].name, " for ") != null)
                            .public
                        else
                            fn_entity.visibility,
                        .params = method_params,
                        .ret = function_body.ret,
                        .generic_params = function_body.generic_params,
                        .body = 0,
                        .receiver = receiver,
                        .is_allocating = function_body.is_allocating,
                    };
                    const old_methods = structure.methods;
                    const new_methods = try e.alloc.alloc(bodies.StructMethod, old_methods.len + 1);
                    @memcpy(new_methods[0..old_methods.len], old_methods);
                    new_methods[old_methods.len] = new_method;
                    structure.methods = new_methods;
                }
            },
            else => {},
        }
    }
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

fn cfgFeatureEnabled(e: *const Ctx, feature: []const u8) bool {
    for (e.cfg.features) |enabled| {
        if (std.mem.eql(u8, enabled, feature)) return true;
    }
    return false;
}

const CfgAttributeKind = enum {
    cfg,
    cfg_attr,
};

const CfgAttributeEvaluation = struct {
    kind: CfgAttributeKind,
    enabled: bool,
    payload: []const u8,
};

fn cfgSkipWhitespace(input: []const u8, index: *usize) void {
    while (index.* < input.len and
        (input[index.*] == ' ' or input[index.*] == '\t' or
            input[index.*] == '\r' or input[index.*] == '\n'))
    {
        index.* += 1;
    }
}

fn cfgIdentifier(input: []const u8, index: *usize) ?[]const u8 {
    cfgSkipWhitespace(input, index);
    const start = index.*;
    while (index.* < input.len and
        (std.ascii.isAlphanumeric(input[index.*]) or input[index.*] == '_'))
    {
        index.* += 1;
    }
    if (index.* == start) return null;
    return input[start..index.*];
}

fn cfgString(input: []const u8, index: *usize) ![]const u8 {
    cfgSkipWhitespace(input, index);
    if (index.* >= input.len or input[index.*] != '"') {
        return error.UnsupportedCfgPredicate;
    }
    index.* += 1;
    const start = index.*;
    while (index.* < input.len and input[index.*] != '"') {
        if (input[index.*] == '\\') return error.UnsupportedCfgPredicate;
        index.* += 1;
    }
    if (index.* >= input.len) return error.UnsupportedCfgPredicate;
    const value = input[start..index.*];
    index.* += 1;
    return value;
}

fn cfgExpect(input: []const u8, index: *usize, expected: u8) !void {
    cfgSkipWhitespace(input, index);
    if (index.* >= input.len or input[index.*] != expected) {
        return error.UnsupportedCfgPredicate;
    }
    index.* += 1;
}

fn evaluateCfgPredicate(e: *const Ctx, input: []const u8, index: *usize) !bool {
    const name = cfgIdentifier(input, index) orelse return error.UnsupportedCfgPredicate;
    if (std.mem.eql(u8, name, "feature")) {
        try cfgExpect(input, index, '=');
        const feature = try cfgString(input, index);
        return cfgFeatureEnabled(e, feature);
    }
    if (std.mem.eql(u8, name, "target_pointer_width")) {
        try cfgExpect(input, index, '=');
        const target_text = try cfgString(input, index);
        const target_width = std.fmt.parseInt(u16, target_text, 10) catch
            return error.UnsupportedCfgPredicate;
        const configured_width = e.cfg.target_pointer_width orelse
            return error.UnsupportedCfgPredicate;
        return configured_width == target_width;
    }
    if (std.mem.eql(u8, name, "test")) {
        return e.include_tests;
    }
    if (std.mem.eql(u8, name, "docsrs")) {
        return e.cfg.docsrs;
    }
    if (std.mem.eql(u8, name, "not")) {
        try cfgExpect(input, index, '(');
        const value = try evaluateCfgPredicate(e, input, index);
        try cfgExpect(input, index, ')');
        return !value;
    }
    const is_all = std.mem.eql(u8, name, "all");
    const is_any = std.mem.eql(u8, name, "any");
    if (!is_all and !is_any) return error.UnsupportedCfgPredicate;

    try cfgExpect(input, index, '(');
    cfgSkipWhitespace(input, index);
    if (index.* < input.len and input[index.*] == ')') {
        index.* += 1;
        return is_all;
    }

    var value = is_all;
    while (true) {
        // Evaluate every operand even after the aggregate value is known so
        // unknown predicates never become silently active in a dead branch.
        const operand = try evaluateCfgPredicate(e, input, index);
        value = if (is_all) value and operand else value or operand;
        cfgSkipWhitespace(input, index);
        if (index.* >= input.len) return error.UnsupportedCfgPredicate;
        if (input[index.*] == ')') {
            index.* += 1;
            return value;
        }
        if (input[index.*] != ',') return error.UnsupportedCfgPredicate;
        index.* += 1;
    }
}

fn evaluateCfgPredicateText(e: *const Ctx, input: []const u8) !bool {
    var index: usize = 0;
    const value = try evaluateCfgPredicate(e, input, &index);
    cfgSkipWhitespace(input, &index);
    if (index != input.len) return error.UnsupportedCfgPredicate;
    return value;
}

fn cfgAttrSeparator(body: []const u8) !usize {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (body, 0..) |character, index| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (character == '\\') {
                escaped = true;
            } else if (character == '"') {
                in_string = false;
            }
            continue;
        }
        if (character == '"') {
            in_string = true;
        } else if (character == '(') {
            depth += 1;
        } else if (character == ')') {
            if (depth == 0) return error.UnsupportedCfgPredicate;
            depth -= 1;
        } else if (character == ',' and depth == 0) {
            return index;
        }
    }
    return error.UnsupportedCfgPredicate;
}

fn evaluateCfgAttributeText(e: *const Ctx, attr_text: []const u8) !?CfgAttributeEvaluation {
    const attr = std.mem.trim(u8, attr_text, " \t\r\n");
    const inner_start: usize = if (std.mem.startsWith(u8, attr, "#!["))
        3
    else if (std.mem.startsWith(u8, attr, "#["))
        2
    else
        return null;
    var inner = attr[inner_start..];
    var name_start: usize = 0;
    cfgSkipWhitespace(inner, &name_start);
    const absolute_name_start = inner_start + name_start;
    var kind: CfgAttributeKind = undefined;
    var prefix_len: usize = undefined;
    if (std.mem.startsWith(u8, attr[absolute_name_start..], "cfg_attr(")) {
        kind = .cfg_attr;
        prefix_len = absolute_name_start + 9;
    } else if (std.mem.startsWith(u8, attr[absolute_name_start..], "cfg(")) {
        kind = .cfg;
        prefix_len = absolute_name_start + 4;
    } else {
        return null;
    }
    if (!std.mem.endsWith(u8, attr, ")]")) {
        return error.UnsupportedCfgPredicate;
    }
    inner = attr[prefix_len .. attr.len - 2];
    if (kind == .cfg) {
        return .{
            .kind = kind,
            .enabled = try evaluateCfgPredicateText(e, inner),
            .payload = "",
        };
    }
    const separator = try cfgAttrSeparator(inner);
    const condition = std.mem.trim(u8, inner[0..separator], " \t\r\n");
    const payload = std.mem.trim(u8, inner[separator + 1 ..], " \t\r\n");
    if (condition.len == 0 or payload.len == 0) {
        return error.UnsupportedCfgPredicate;
    }
    return .{
        .kind = kind,
        .enabled = try evaluateCfgPredicateText(e, condition),
        .payload = payload,
    };
}

fn isCfgAttributeText(attr_text: []const u8) bool {
    var attr = std.mem.trim(u8, attr_text, " \t\r\n");
    if (std.mem.startsWith(u8, attr, "#![")) {
        attr = attr[3..];
    } else if (std.mem.startsWith(u8, attr, "#[")) {
        attr = attr[2..];
    } else {
        return false;
    }
    var index: usize = 0;
    cfgSkipWhitespace(attr, &index);
    return std.mem.startsWith(u8, attr[index..], "cfg(") or
        std.mem.startsWith(u8, attr[index..], "cfg_attr(");
}

fn validateOrphanCfgAttributes(e: *const Ctx, attribute: ts.Node) !void {
    var found_disabled = false;
    var current: ?ts.Node = attribute;
    while (current) |node| {
        if (std.mem.eql(u8, node.kind(), "attribute_item")) {
            const attr_text = text(e, node);
            if (isCfgAttributeText(attr_text)) {
                const evaluation = try evaluateCfgAttributeText(e, attr_text);
                if (evaluation) |result| {
                    if (result.kind == .cfg and !result.enabled) found_disabled = true;
                }
            }
            current = node.prevNamedSibling();
            continue;
        }
        if (isComment(node)) {
            current = node.prevNamedSibling();
            continue;
        }
        break;
    }
    if (found_disabled) return;
}

fn validateCfgAttributes(e: *const Ctx, item: ts.Node) !bool {
    var found_disabled = false;
    var i: u32 = 0;
    while (item.namedChild(i)) |child| : (i += 1) {
        if (!std.mem.eql(u8, child.kind(), "attribute_item")) continue;
        const attr_text = text(e, child);
        if (!isCfgAttributeText(attr_text)) continue;
        const evaluation = try evaluateCfgAttributeText(e, attr_text);
        if (evaluation) |result| {
            if (result.kind == .cfg and !result.enabled) found_disabled = true;
        }
    }
    var prev = item.prevNamedSibling();
    while (prev) |node| {
        if (std.mem.eql(u8, node.kind(), "attribute_item")) {
            const attr_text = text(e, node);
            if (isCfgAttributeText(attr_text)) {
                const evaluation = try evaluateCfgAttributeText(e, attr_text);
                if (evaluation) |result| {
                    if (result.kind == .cfg and !result.enabled) found_disabled = true;
                }
            }
        } else if (!isComment(node)) {
            break;
        }
        prev = node.prevNamedSibling();
    }
    return found_disabled;
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
    const table = e.macro_table orelse return error.MacroTableUnavailable;
    const raw_def = text(e, item);
    var def = try exp.parseMacroRulesDefinition(e.alloc, raw_def);
    errdefer def.deinit(e.alloc);
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
    const table = e.macro_table orelse return error.MacroTableUnavailable;
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
    if (mname == null) return error.MalformedMacroInvocation;
    const tt = token_tree_node orelse return error.MalformedMacroInvocation;
    const invocation_text = text(e, item);
    const bang_idx = std.mem.indexOfScalar(u8, invocation_text, '!') orelse
        return error.MalformedMacroInvocation;
    const path_text = std.mem.trim(u8, invocation_text[0..bang_idx], " \t\r\n");
    if (path_text.len == 0) return error.MalformedMacroInvocation;
    const def = table.get(path_text) orelse return error.UnknownMacro;
    const expanded = try exp.expandMacroRules(e.alloc, def, text(e, tt));
    const initial_macro_count = table.macros.count();
    defer e.alloc.free(expanded);

    // Re-parse the expanded source and ingest any generated top-level items.
    var parser = ts.Parser.create();
    defer parser.destroy();
    const tree = try parseRustTree(parser, expanded);
    defer tree.destroy();
    var generated_environment = try copyConstEnvironment(e, e.const_environment);
    defer generated_environment.deinit(e.alloc);
    var exp_ctx: Ctx = .{
        .alloc = e.alloc,
        .g = e.g,
        .src = expanded,
        .types_list = e.types_list,
        .bodies_list = e.bodies_list,
        .exprs_list = e.exprs_list,
        .base_dir = e.base_dir,
        .io = e.io,
        .include_tests = e.include_tests,
        .cfg = e.cfg,
        .const_environment = &generated_environment,
        .macro_table = e.macro_table,
        .pending_impls = e.pending_impls,
        .pending_generics = e.pending_generics,
        .function_origins = e.function_origins,
    };
    const initial_entity_count = e.g.symbol_table.entities.items.len;
    const generated = try mapItemsInner(&exp_ctx, tree.rootNode(), mod_id);
    defer e.alloc.free(generated);
    if (e.g.symbol_table.entities.items.len == initial_entity_count and
        table.macros.count() == initial_macro_count)
    {
        return error.EmptyMacroExpansion;
    }
    try item_ids.appendSlice(e.alloc, generated);
}

/// Preserve an edition-2015 `extern crate` declaration as an explicit entity.
fn externCrateItem(
    e: *Ctx,
    item: ts.Node,
    mod_id: spine.EntityId,
    item_ids: *std.ArrayListUnmanaged(spine.EntityId),
) !void {
    var crate_name: []const u8 = "";
    var alias: ?[]const u8 = null;
    var i: u32 = 0;
    while (item.namedChild(i)) |child| : (i += 1) {
        if (!std.mem.eql(u8, child.kind(), "identifier")) continue;
        if (crate_name.len == 0) {
            crate_name = text(e, child);
        } else if (alias == null) {
            alias = text(e, child);
        } else {
            return error.MalformedItemName;
        }
    }
    if (crate_name.len == 0) return error.MalformedItemName;
    if (e.g.moduleForEntity(mod_id) == null) return error.InvalidModuleItemParent;
    const id = try addEntity(e, .extern_crate, crate_name, mod_id, item);
    if (alias) |local_name| {
        e.g.symbol_table.entities.items[id].renamed_to = try e.alloc.dupe(u8, local_name);
    }
    try item_ids.append(e.alloc, id);
}

fn constDeclarationName(item: ts.Node) ?ts.Node {
    var i: u32 = 0;
    while (item.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), "identifier")) return child;
    }
    return null;
}

fn typeAliasDeclarationName(item: ts.Node) ?ts.Node {
    var i: u32 = 0;
    while (item.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), "type_identifier")) return child;
    }
    return null;
}

fn collectConstEnvironment(e: *const Ctx, node: ts.Node) !ConstEnvironment {
    var environment = ConstEnvironment.init();
    errdefer environment.deinit(e.alloc);

    var i: u32 = 0;
    while (node.namedChild(i)) |item| : (i += 1) {
        if (isComment(item)) continue;
        const kind = item.kind();
        if (std.mem.eql(u8, kind, "attribute_item") or
            std.mem.eql(u8, kind, "inner_attribute_item"))
        {
            continue;
        }
        if (try validateCfgAttributes(e, item)) continue;
        if (std.mem.eql(u8, kind, "const_item")) {
            const name = constDeclarationName(item) orelse continue;
            if (environment.consts.items.len + environment.aliases.items.len >=
                max_const_environment_entries)
            {
                return error.InvalidType;
            }
            try environment.consts.append(e.alloc, .{ .name = text(e, name), .item = item });
        } else if (std.mem.eql(u8, kind, "type_item")) {
            const name = typeAliasDeclarationName(item) orelse continue;
            if (environment.consts.items.len + environment.aliases.items.len >=
                max_const_environment_entries)
            {
                return error.InvalidType;
            }
            try environment.aliases.append(e.alloc, .{ .name = text(e, name), .item = item });
        }
    }
    return environment;
}
fn copiedConstNameExists(
    environment: *const ConstEnvironment,
    name: []const u8,
) bool {
    for (environment.consts.items) |declaration| {
        if (std.mem.eql(u8, declaration.name, name)) return true;
    }
    return false;
}

fn copiedAliasNameExists(
    environment: *const ConstEnvironment,
    name: []const u8,
) bool {
    for (environment.aliases.items) |declaration| {
        if (std.mem.eql(u8, declaration.name, name)) return true;
    }
    return false;
}

/// Copy the active lexical integer environment after all source-local
/// declarations have been materialized. Generated trees have a different
/// source buffer and must never slice nodes from their parent tree.
fn copyConstEnvironment(
    e: *const Ctx,
    source: ?*const ConstEnvironment,
) !ConstEnvironment {
    var copied = ConstEnvironment.init();
    copied.owns_strings = true;
    errdefer copied.deinit(e.alloc);

    var current = source;
    while (current) |environment| {
        for (environment.consts.items) |declaration| {
            if (copiedConstNameExists(&copied, declaration.name)) continue;
            const name_copy = try e.alloc.dupe(u8, declaration.name);
            errdefer e.alloc.free(name_copy);
            try copied.consts.append(e.alloc, .{
                .name = name_copy,
                .value = declaration.value,
            });
        }
        for (environment.aliases.items) |declaration| {
            if (copiedAliasNameExists(&copied, declaration.name)) continue;
            const name_copy = try e.alloc.dupe(u8, declaration.name);
            errdefer e.alloc.free(name_copy);
            const target_copy = if (declaration.target_name) |name|
                try e.alloc.dupe(u8, name)
            else
                null;
            errdefer if (target_copy) |name| e.alloc.free(name);
            try copied.aliases.append(e.alloc, .{
                .name = name_copy,
                .target_name = target_copy,
            });
        }
        current = environment.parent;
    }
    return copied;
}

/// Materialize values before a declaration environment crosses a source-file
/// or macro-expansion boundary. Tree-sitter nodes are only valid with their
/// original source buffer.
fn materializeConstEnvironment(e: *const Ctx, environment: *ConstEnvironment) void {
    for (environment.aliases.items) |*declaration| {
        if (declaration.target_name == null) {
            const item = declaration.item orelse continue;
            const target = typeAliasTargetNode(item) orelse continue;
            declaration.target_name = text(e, target);
        }
    }
    for (environment.consts.items) |*declaration| {
        if (declaration.value == null) {
            const item = declaration.item orelse continue;
            const initializer = constInitializerNode(e, item) orelse continue;
            declaration.value = constIntegerValueAt(e, initializer, 0);
        }
    }
}
fn hasDisabledInnerCfg(e: *const Ctx, node: ts.Node) !bool {
    var i: u32 = 0;
    while (node.namedChild(i)) |item| : (i += 1) {
        if (!std.mem.eql(u8, item.kind(), "inner_attribute_item")) continue;
        const attr_text = text(e, item);
        if (!isCfgAttributeText(attr_text)) continue;
        const evaluation = try evaluateCfgAttributeText(e, attr_text);
        if (evaluation) |result| {
            if (result.kind == .cfg and !result.enabled) return true;
        }
    }
    return false;
}

/// Like mapItems but returns the item id list (for a nested module).
fn mapItemsInner(e: *Ctx, node: ts.Node, mod_id: spine.EntityId) ![]const spine.EntityId {
    if (try hasDisabledInnerCfg(e, node)) return &.{};

    var environment = try collectConstEnvironment(e, node);
    environment.parent = e.const_environment;
    defer environment.deinit(e.alloc);
    const previous_environment = e.const_environment;
    e.const_environment = &environment;
    materializeConstEnvironment(e, &environment);
    defer e.const_environment = previous_environment;

    var item_ids: std.ArrayListUnmanaged(spine.EntityId) = .empty;
    var i: u32 = 0;
    while (node.namedChild(i)) |item| : (i += 1) {
        const item_kind = item.kind();
        if (isComment(item)) {
            // Comments are lexical extras, not Rust items; they carry no
            // semantic entity in the graph.
            continue;
        }
        if (std.mem.eql(u8, item_kind, "attribute_item")) {
            var next = item.nextNamedSibling();
            while (next) |next_node| {
                if (!isComment(next_node)) break;
                next = next_node.nextNamedSibling();
            }
            if (next == null) try validateOrphanCfgAttributes(e, item);
            continue;
        }
        if (std.mem.eql(u8, item_kind, "inner_attribute_item")) {
            const attr_text = text(e, item);
            if (isCfgAttributeText(attr_text)) {
                const evaluation = try evaluateCfgAttributeText(e, attr_text);
                if (evaluation) |result| {
                    if (!result.enabled) continue;
                    if (result.kind == .cfg_attr) {
                        try appendModuleAttribute(
                            e,
                            mod_id,
                            try parseAttributeText(e, result.payload),
                        );
                    }
                    continue;
                }
            }
            try appendModuleAttribute(e, mod_id, try parseAttribute(e, item));
            continue;
        }
        // node (e.g. `name!(...);`); descend into it so the following branch
        // sees the `macro_invocation` child directly.
        var item2 = item;
        if (std.mem.eql(u8, item.kind(), "expression_statement")) {
            const mi = item.namedChild(0) orelse return error.ParseFailed;
            if (!std.mem.eql(u8, mi.kind(), "macro_invocation")) return error.ParseFailed;
            item2 = mi;
        }
        const disabled_cfg = try validateCfgAttributes(e, item);
        if (disabled_cfg) continue;
        const k = item2.kind();
        if (std.mem.eql(u8, k, "mod_item")) {
            var mname: []const u8 = "";
            var decls: ?ts.Node = null;
            var j: u32 = 0;
            while (item2.namedChild(j)) |c| : (j += 1) {
                if (std.mem.eql(u8, c.kind(), "identifier")) mname = text(e, c);
                if (std.mem.eql(u8, c.kind(), "declaration_list")) decls = c;
            }
            if (mname.len == 0) return error.MalformedItemName;
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
                const bdir = e.base_dir orelse return error.ModuleNotFound;
                const io = e.io orelse return error.ModuleReadUnavailable;
                var sub_path: []const u8 = undefined;
                if (extractPathAttr(e, item)) |custom_rel_path| {
                    const cand = try std.fs.path.join(e.alloc, &.{ bdir, custom_rel_path });
                    defer e.alloc.free(cand);
                    var dir = std.Io.Dir.cwd();
                    const file = dir.openFile(io, cand, .{}) catch return error.ModuleNotFound;
                    file.close(io);
                    sub_path = try e.alloc.dupe(u8, cand);
                } else {
                    const rs_name = try std.fmt.allocPrint(e.alloc, "{s}.rs", .{mname});
                    defer e.alloc.free(rs_name);
                    const cand1 = try std.fs.path.join(e.alloc, &.{ bdir, rs_name });
                    defer e.alloc.free(cand1);
                    const cand2 = try std.fs.path.join(e.alloc, &.{ bdir, mname, "mod.rs" });
                    defer e.alloc.free(cand2);
                    var dir = std.Io.Dir.cwd();
                    if (dir.openFile(io, cand1, .{})) |file| {
                        file.close(io);
                        sub_path = try e.alloc.dupe(u8, cand1);
                    } else |_| {
                        if (dir.openFile(io, cand2, .{})) |file| {
                            file.close(io);
                            sub_path = try e.alloc.dupe(u8, cand2);
                        } else |_| {
                            return error.ModuleNotFound;
                        }
                    }
                }
                const sub_base_dir = try childModuleBaseDir(e.alloc, sub_path, mname);
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

                const sub_src = try readFileAlloc(e.alloc, io, sub_path);
                var sub_parser = ts.Parser.create();
                defer sub_parser.destroy();
                const sub_tree = try parseRustTree(sub_parser, sub_src);
                defer sub_tree.destroy();
                if (sub_tree.rootNode().hasError()) return error.ParseFailed;
                var sub_ctx: Ctx = .{
                    .alloc = e.alloc,
                    .g = e.g,
                    .src = sub_src,
                    .types_list = e.types_list,
                    .bodies_list = e.bodies_list,
                    .exprs_list = e.exprs_list,
                    .base_dir = sub_base_dir,
                    .io = io,
                    .include_tests = e.include_tests,
                    .cfg = e.cfg,
                    .const_environment = e.const_environment,
                    .macro_table = e.macro_table,
                    .pending_impls = e.pending_impls,
                    .pending_generics = e.pending_generics,
                    .function_origins = e.function_origins,
                };
                const child_items = try mapItemsInner(&sub_ctx, sub_tree.rootNode(), child_id);
                e.g.modules.items[child_mod_idx].items = child_items;
            }
            try item_ids.append(e.alloc, child_id);
        } else if (std.mem.eql(u8, k, "extern_crate_declaration")) {
            try externCrateItem(e, item2, mod_id, &item_ids);
        } else if (std.mem.eql(u8, k, "use_declaration")) {
            try useItem(e, item2, mod_id, &item_ids);
        } else if (std.mem.eql(u8, k, "struct_item")) {
            try structItem(e, item2, mod_id);
            try item_ids.append(
                e.alloc,
                nominalItemId(e) orelse return error.InvalidModuleItemParent,
            );
        } else if (std.mem.eql(u8, k, "enum_item")) {
            try enumItem(e, item2, mod_id);
            try item_ids.append(
                e.alloc,
                nominalItemId(e) orelse return error.InvalidModuleItemParent,
            );
        } else if (std.mem.eql(u8, k, "union_item")) {
            try unionItem(e, item2, mod_id);
            try item_ids.append(
                e.alloc,
                nominalItemId(e) orelse return error.InvalidModuleItemParent,
            );
        } else if (std.mem.eql(u8, k, "trait_item")) {
            try traitItem(e, item2, mod_id);
            try item_ids.append(
                e.alloc,
                nominalItemId(e) orelse return error.InvalidModuleItemParent,
            );
        } else if (std.mem.eql(u8, k, "type_item")) {
            try typeAliasItem(e, item2, mod_id);
            try item_ids.append(
                e.alloc,
                nominalItemId(e) orelse return error.InvalidModuleItemParent,
            );
        } else if (std.mem.eql(u8, k, "const_item")) {
            try constItem(e, item2, mod_id);
            try item_ids.append(e.alloc, @intCast(e.bodies_list.items.len - 1));
        } else if (std.mem.eql(u8, k, "function_item")) {
            try functionItem(e, item2, mod_id, false);
            try item_ids.append(e.alloc, @intCast(e.bodies_list.items.len - 1));
        } else if (std.mem.eql(u8, k, "impl_item")) {
            _ = try implItem(e, item2, mod_id);
        } else if (std.mem.eql(u8, k, "macro_definition")) {
            try registerMacroDefinition(e, item2);
        } else if (std.mem.eql(u8, k, "macro_invocation")) {
            try expandMacroInvocationItems(e, item2, mod_id, &item_ids);
        } else if (std.mem.eql(u8, k, "static_item") or
            std.mem.eql(u8, k, "foreign_mod_item"))
        {
            return error.UnsupportedItem;
        } else {
            return error.ParseFailed;
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

    var local_pending: std.ArrayListUnmanaged(PendingImpl) = .empty;
    var owns_pending = false;
    if (ctx.pending_impls == null) {
        ctx.pending_impls = &local_pending;
        owns_pending = true;
    }
    defer if (owns_pending) {
        for (local_pending.items) |impl| {
            ctx.alloc.free(impl.target_path);
            ctx.alloc.free(impl.methods);
        }
        local_pending.deinit(ctx.alloc);
        ctx.pending_impls = null;
    };
    var local_generics: std.ArrayListUnmanaged(PendingGenericApplication) = .empty;
    var owns_generics = false;
    if (ctx.pending_generics == null) {
        ctx.pending_generics = &local_generics;
        owns_generics = true;
    }
    defer if (owns_generics) {
        for (local_generics.items) |application| {
            freePendingGenericPath(ctx.alloc, application.path);
        }
        local_generics.deinit(ctx.alloc);
        ctx.pending_generics = null;
    };
    var local_origins: FunctionOriginTable = .empty;
    var owns_origins = false;
    if (ctx.function_origins == null) {
        ctx.function_origins = &local_origins;
        owns_origins = true;
    }
    defer if (owns_origins) {
        var it = local_origins.valueIterator();
        while (it.next()) |origin| {
            ctx.alloc.free(origin.source);
        }
        local_origins.deinit(ctx.alloc);
        ctx.function_origins = null;
    };

    var parser = ts.Parser.create();
    defer parser.destroy();
    const tree = try parseRustTree(parser, ctx.src);
    defer tree.destroy();
    const root = tree.rootNode();
    if (root.hasError()) return error.ParseFailed;
    var root_items_before: []const spine.EntityId = &.{};
    for (ctx.g.modules.items) |module| {
        if (module.id == 0) {
            root_items_before = module.items;
            break;
        }
    }
    try mapItems(ctx, root, 0);
    errdefer {
        for (ctx.g.modules.items) |*module| {
            if (module.id == 0) {
                if (module.items.len > 0 and module.items.ptr != root_items_before.ptr) {
                    ctx.alloc.free(module.items);
                }
                module.items = root_items_before;
                break;
            }
        }
    }
    try names.resolveGraph(ctx.alloc, ctx.g);
    if (owns_pending) try finalizePendingImpls(ctx, ctx.pending_impls.?);
    try bindDeclarationTypes(ctx.g, ctx.bodies_list, ctx.pending_generics.?.items);
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
        \\pub const TRUNCATED_BYTE: u8 = 256u16 as u8;
        \\pub const TWOS_COMPLEMENT_BYTE: u8 = -1i8 as u8;
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
        .{ .name = "TRUNCATED_BYTE", .value = 0 },
        .{ .name = "TWOS_COMPLEMENT_BYTE", .value = 255 },
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

test "cst rejects unsupported const cast targets" {
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
        \\pub const FLOAT_CAST: f32 = 1u8 as f32;
        ,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
    };

    try std.testing.expectError(error.UnsupportedConstInitializer, extractFile(&ctx));
}

test "cst resolves forward const array lengths through primitive aliases" {
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
        \\pub struct Buffer {
        \\    pub bytes: [u8; ARRAY_LEN],
        \\}
        \\type Chunk = u32;
        \\const WIDTH: usize = 8 * core::mem::size_of::<Chunk>();
        \\const ARRAY_LEN: usize = 128 / WIDTH;
        ,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
    };
    try extractFile(&ctx);

    var buffer_id: ?spine.EntityId = null;
    for (crate_graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .struct_ and std.mem.eql(u8, entity.name, "Buffer")) {
            buffer_id = entity.id;
            break;
        }
    }
    const id = buffer_id orelse return error.TestUnexpectedResult;
    const body = switch (bodies_list.items[id]) {
        .struct_ => |structure| structure,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), body.fields.len);
    try std.testing.expectEqualStrings("bytes", body.fields[0].name);
    const array = switch (body.fields[0].ty) {
        .array => |value| value,
        else => return error.TestUnexpectedResult,
    };
    switch (array.len) {
        .literal => |length| try std.testing.expectEqual(@as(u32, 4), length),
        else => return error.TestUnexpectedResult,
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
test "cst skips test cfg while preserving source visibility and trait signatures" {
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

    try std.testing.expectEqual(@as(usize, 3), crate_graph.modules.items[0].items.len);

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

    try std.testing.expect(tests_entity == null);
    try std.testing.expect(smoke_entity == null);

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

test "cst selects configured feature and target cfg predicates" {
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
    const cfg_options: CfgOptions = .{
        .features = &.{"alloc"},
        .target_pointer_width = 64,
    };
    var ctx: Ctx = .{
        .alloc = allocator,
        .g = &crate_graph,
        .src =
        \\#[cfg(any(feature = "alloc", target_pointer_width = "64"))]
        \\pub struct Selected;
        \\#[cfg(any(feature = "std", target_pointer_width = "32"))]
        \\pub struct NotSelected;
        ,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
        .cfg = cfg_options,
    };
    try extractFile(&ctx);

    var selected_found = false;
    var not_selected_found = false;
    for (crate_graph.symbol_table.entities.items) |entity| {
        if (entity.kind != .struct_) continue;
        if (std.mem.eql(u8, entity.name, "Selected")) selected_found = true;
        if (std.mem.eql(u8, entity.name, "NotSelected")) not_selected_found = true;
    }
    try std.testing.expect(selected_found);
    try std.testing.expect(!not_selected_found);
    try std.testing.expectEqual(@as(usize, 1), crate_graph.modules.items[0].items.len);
}

test "cst suppresses crate declarations behind false inner cfg" {
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
        \\#![cfg(feature = "off")]
        \\pub struct Gated;
        ,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
    };
    try extractFile(&ctx);

    var gated_found = false;
    for (crate_graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .struct_ and std.mem.eql(u8, entity.name, "Gated")) {
            gated_found = true;
            break;
        }
    }
    try std.testing.expect(!gated_found);
    try std.testing.expectEqual(@as(usize, 0), crate_graph.modules.items[0].items.len);
}

test "cst ignores cfg_attr when docsrs is disabled" {
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
    const cfg_options: CfgOptions = .{ .docsrs = false };
    var ctx: Ctx = .{
        .alloc = allocator,
        .g = &crate_graph,
        .src =
        \\#[cfg_attr(docsrs, doc(cfg(feature = "alloc")))]
        \\pub struct Documented;
        ,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
        .cfg = cfg_options,
    };
    try extractFile(&ctx);

    var documented: ?spine.Entity = null;
    for (crate_graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .struct_ and std.mem.eql(u8, entity.name, "Documented")) {
            documented = entity;
            break;
        }
    }
    const entity = documented orelse return error.TestUnexpectedResult;
    try std.testing.expect(entity.visibility == .public);
    try std.testing.expectEqual(@as(usize, 1), crate_graph.modules.items[0].items.len);
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
test "cst binds owner-scoped declaration nominal paths" {
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
        \\pub struct Shape {}
        \\pub mod child {
        \\    pub struct Point {
        \\        root: crate::Shape,
        \\        local: self::Point,
        \\        parent: super::Shape,
        \\    }
        \\}
        ,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
    };
    try extractFile(&ctx);

    var shape_id: ?spine.EntityId = null;
    var point_id: ?spine.EntityId = null;
    var child_module_id: ?spine.EntityId = null;
    for (crate_graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .module and std.mem.eql(u8, entity.name, "child")) {
            child_module_id = entity.id;
        }
        if (entity.kind != .struct_) continue;
        if (std.mem.eql(u8, entity.name, "Shape")) shape_id = entity.id;
        if (std.mem.eql(u8, entity.name, "Point")) point_id = entity.id;
    }
    const child_module = child_module_id orelse return error.TestUnexpectedResult;
    const shape = shape_id orelse return error.TestUnexpectedResult;
    const point = point_id orelse return error.TestUnexpectedResult;
    const point_body = switch (bodies_list.items[point]) {
        .struct_ => |body| body,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 3), point_body.fields.len);
    for (point_body.fields) |field| {
        const path = switch (field.ty) {
            .path => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(usize, 2), path.segments.len);
        try std.testing.expectEqual(@as(?spine.EntityId, null), path.segments[0].id);
        const terminal = path.segments[path.segments.len - 1];
        if (std.mem.eql(u8, field.name, "local")) {
            try std.testing.expectEqual(point, terminal.id.?);
        } else {
            try std.testing.expectEqual(shape, terminal.id.?);
        }
    }
    var pre_resolved_segments = [_]types.PathSegment{
        .{ .name = "child", .id = child_module },
        .{ .name = "Point", .id = point },
    };
    var pre_resolved_path: types.Path = .{ .segments = &pre_resolved_segments };
    try bindPath(
        &crate_graph,
        bodies_list.items,
        0,
        &.{},
        &pre_resolved_path,
    );
    try std.testing.expectEqual(@as(?spine.EntityId, null), pre_resolved_path.segments[0].id);
    try std.testing.expectEqual(point, pre_resolved_path.segments[1].id.?);
}

test "cst rejects unresolved declaration nominal paths" {
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
        .src = "pub struct Point { missing: Missing }",
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
    };
    try std.testing.expectError(error.UnresolvedNominalType, extractFile(&ctx));
}

test "cst extracts absolute core nominal type paths" {
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
        \\pub struct Cursor {
        \\    pub iter: ::core::slice::Iter<'a, u8>,
        \\}
        ,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
    };
    try extractFile(&ctx);

    var cursor_id: ?spine.EntityId = null;
    for (crate_graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .struct_ and std.mem.eql(u8, entity.name, "Cursor")) {
            cursor_id = entity.id;
            break;
        }
    }
    const id = cursor_id orelse return error.TestUnexpectedResult;
    const body = switch (bodies_list.items[id]) {
        .struct_ => |structure| structure,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), body.fields.len);
    const external = switch (body.fields[0].ty) {
        .external_nominal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const expected_path = [_][]const u8{ "core", "slice", "Iter" };
    try std.testing.expectEqual(@as(usize, 3), external.path.len);
    for (expected_path, external.path) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    try std.testing.expectEqual(@as(usize, 1), external.args.len);
    switch (external.args[0]) {
        .prim => |prim| try std.testing.expectEqual(types.Prim.u8, prim),
        else => return error.TestUnexpectedResult,
    }
}

test "cst resolves core mem size_of through a use alias" {
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
        \\use core::mem;
        \\type Chunk = u32;
        \\pub struct Buffer {
        \\    pub bytes: [Chunk; 128 / (8 * mem::size_of::<Chunk>())],
        \\}
        ,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
    };
    try extractFile(&ctx);

    var buffer_id: ?spine.EntityId = null;
    for (crate_graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .struct_ and std.mem.eql(u8, entity.name, "Buffer")) {
            buffer_id = entity.id;
            break;
        }
    }
    const id = buffer_id orelse return error.TestUnexpectedResult;
    const body = switch (bodies_list.items[id]) {
        .struct_ => |structure| structure,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), body.fields.len);
    const array = switch (body.fields[0].ty) {
        .array => |value| value,
        else => return error.TestUnexpectedResult,
    };
    switch (array.len) {
        .literal => |length| try std.testing.expectEqual(@as(u32, 4), length),
        else => return error.TestUnexpectedResult,
    }
}

test "cst retains outer const lengths in macro-expanded type aliases" {
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
        \\const OUTER_LEN: usize = 4;
        \\macro_rules! define_alias {
        \\    () => {
        \\        type Generated = [u8; OUTER_LEN];
        \\    };
        \\}
        \\define_alias!();
        ,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
    };
    try extractFile(&ctx);

    var alias_id: ?spine.EntityId = null;
    for (crate_graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .type_alias and std.mem.eql(u8, entity.name, "Generated")) {
            alias_id = entity.id;
            break;
        }
    }
    const id = alias_id orelse return error.TestUnexpectedResult;
    const alias_target = switch (bodies_list.items[id]) {
        .type_alias => |alias| alias.target,
        else => return error.TestUnexpectedResult,
    };
    const array = switch (alias_target) {
        .array => |value| value,
        else => return error.TestUnexpectedResult,
    };
    switch (array.len) {
        .literal => |length| try std.testing.expectEqual(@as(u32, 4), length),
        else => return error.TestUnexpectedResult,
    }
}

test "cst resolves an inline impl before its later root type" {
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
        \\mod algo {
        \\    impl super::LaterType {}
        \\}
        \\pub struct LaterType {}
        ,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
    };
    try extractFile(&ctx);

    var later_type_id: ?spine.EntityId = null;
    var algo_id: ?spine.EntityId = null;
    for (crate_graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .struct_ and std.mem.eql(u8, entity.name, "LaterType")) {
            later_type_id = entity.id;
        }
        if (entity.kind == .module and std.mem.eql(u8, entity.name, "algo")) {
            algo_id = entity.id;
        }
    }
    const target_id = later_type_id orelse return error.TestUnexpectedResult;
    try std.testing.expect(algo_id != null);

    var found_impl = false;
    for (crate_graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .impl_ and entity.parent == target_id) {
            found_impl = true;
            break;
        }
    }
    try std.testing.expect(found_impl);
}
