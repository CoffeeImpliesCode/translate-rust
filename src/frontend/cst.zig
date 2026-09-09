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

pub const UnsupportedMacroReason = enum {
    dependency_source_unavailable,
    build_script_not_executed,
    source_unavailable,
};

pub const UnsupportedMacro = struct {
    name: []const u8,
    reason: UnsupportedMacroReason,
    artifact_path: ?[]const u8 = null,
};

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
    /// Current module's macro definitions, with borrowed ancestor scopes.
    macro_table: ?*exp.MacroTable = null,
    /// Impl blocks wait here until all lexical declarations and imports exist.
    pending_impls: ?*std.ArrayListUnmanaged(PendingImpl) = null,
    /// Exact function origins recorded during CST ingestion.
    function_origins: ?*FunctionOriginTable = null,
    /// Generic applications wait here until every nominal declaration exists.
    pending_generics: ?*std.ArrayListUnmanaged(PendingGenericApplication) = null,
    /// The most recent typed macro-source refusal. Slices are owned by `alloc`.
    unsupported_macro: ?UnsupportedMacro = null,
};

fn clearUnsupportedMacro(e: *Ctx) void {
    if (e.unsupported_macro) |diagnostic| {
        e.alloc.free(diagnostic.name);
        if (diagnostic.artifact_path) |path| e.alloc.free(path);
    }
    e.unsupported_macro = null;
}
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
    if (value < 0) return error.InvalidType;
    const max_len: i128 = if (e.cfg.target_pointer_width) |width| switch (width) {
        8 => @as(i128, std.math.maxInt(u8)),
        16 => @as(i128, std.math.maxInt(u16)),
        32 => @as(i128, std.math.maxInt(u32)),
        64 => @as(i128, std.math.maxInt(u64)),
        else => return error.InvalidType,
    } else @as(i128, std.math.maxInt(usize));
    if (value > max_len) return error.InvalidType;
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
        if (std.mem.eql(u8, nm, "str")) return types.str_type;
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
    if (std.mem.eql(u8, kind, "abstract_type")) {
        const trait_node = node.childByFieldName("trait") orelse return error.InvalidType;
        const bounds = try collectTraitTypeBounds(e, trait_node);
        if (bounds.len == 0) return error.InvalidType;
        return .{ .@"opaque" = .{ .bounds = bounds } };
    }
    if (std.mem.eql(u8, kind, "dynamic_type")) {
        const trait_node = node.childByFieldName("trait") orelse return error.InvalidType;
        const bounds = try collectTraitTypeBounds(e, trait_node);
        if (bounds.len == 0) return error.InvalidType;
        return .{ .dyn_trait = bounds };
    }
    if (std.mem.eql(u8, kind, "bounded_type")) {
        const bounds = try collectTraitTypeBounds(e, node);
        if (bounds.len == 0) return error.InvalidType;
        return .{ .dyn_trait = bounds };
    }
    if (std.mem.eql(u8, kind, "type_binding")) return error.InvalidType;
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
fn freePathSegments(e: *const Ctx, path: []const types.PathSegment) void {
    for (path) |segment| e.alloc.free(segment.name);
    if (path.len > 0) e.alloc.free(path);
}

fn isKnownExternalCrate(g: *const graph.CrateGraph, name: []const u8) bool {
    if (std.mem.eql(u8, name, "core") or
        std.mem.eql(u8, name, "std") or
        std.mem.eql(u8, name, "alloc"))
        return true;
    for (g.crates.items) |crate_info| {
        for (crate_info.deps) |dep| {
            if (std.mem.eql(u8, dep.local_alias, name) or
                std.mem.eql(u8, dep.extern_name, name))
                return true;
            if (dep.local_alias.len == name.len) {
                var match = true;
                for (dep.local_alias, name) |a, b| {
                    const norm_a = if (a == '-') '_' else a;
                    const norm_b = if (b == '-') '_' else b;
                    if (norm_a != norm_b) {
                        match = false;
                        break;
                    }
                }
                if (match) return true;
            }
            if (dep.extern_name.len == name.len) {
                var match = true;
                for (dep.extern_name, name) |a, b| {
                    const norm_a = if (a == '-') '_' else a;
                    const norm_b = if (b == '-') '_' else b;
                    if (norm_a != norm_b) {
                        match = false;
                        break;
                    }
                }
                if (match) return true;
            }
        }
    }
    for (g.symbol_table.entities.items) |entity| {
        if (entity.kind == .extern_crate) {
            if (std.mem.eql(u8, entity.name, name)) return true;
            if (entity.renamed_to) |renamed| {
                if (std.mem.eql(u8, renamed, name)) return true;
            }
        }
    }
    return false;
}

fn preludeExternalPath(name: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, name, "String")) return &.{ "alloc", "string", "String" };
    if (std.mem.eql(u8, name, "Vec")) return &.{ "alloc", "vec", "Vec" };
    if (std.mem.eql(u8, name, "From")) return &.{ "core", "convert", "From" };
    if (std.mem.eql(u8, name, "Into")) return &.{ "core", "convert", "Into" };
    if (std.mem.eql(u8, name, "TryFrom")) return &.{ "core", "convert", "TryFrom" };
    if (std.mem.eql(u8, name, "TryInto")) return &.{ "core", "convert", "TryInto" };
    if (std.mem.eql(u8, name, "AsRef")) return &.{ "core", "convert", "AsRef" };
    if (std.mem.eql(u8, name, "AsMut")) return &.{ "core", "convert", "AsMut" };
    if (std.mem.eql(u8, name, "Default")) return &.{ "core", "default", "Default" };
    if (std.mem.eql(u8, name, "Clone")) return &.{ "core", "clone", "Clone" };
    if (std.mem.eql(u8, name, "Copy")) return &.{ "core", "marker", "Copy" };
    if (std.mem.eql(u8, name, "Send")) return &.{ "core", "marker", "Send" };
    if (std.mem.eql(u8, name, "Sync")) return &.{ "core", "marker", "Sync" };
    if (std.mem.eql(u8, name, "Sized")) return &.{ "core", "marker", "Sized" };
    if (std.mem.eql(u8, name, "Unpin")) return &.{ "core", "marker", "Unpin" };
    if (std.mem.eql(u8, name, "Fn")) return &.{ "core", "ops", "Fn" };
    if (std.mem.eql(u8, name, "FnMut")) return &.{ "core", "ops", "FnMut" };
    if (std.mem.eql(u8, name, "FnOnce")) return &.{ "core", "ops", "FnOnce" };
    if (std.mem.eql(u8, name, "Drop")) return &.{ "core", "ops", "Drop" };
    if (std.mem.eql(u8, name, "Iterator")) return &.{ "core", "iter", "Iterator" };
    if (std.mem.eql(u8, name, "IntoIterator")) return &.{ "core", "iter", "IntoIterator" };
    if (std.mem.eql(u8, name, "DoubleEndedIterator")) return &.{ "core", "iter", "DoubleEndedIterator" };
    if (std.mem.eql(u8, name, "ExactSizeIterator")) return &.{ "core", "iter", "ExactSizeIterator" };
    if (std.mem.eql(u8, name, "Extend")) return &.{ "core", "iter", "Extend" };
    if (std.mem.eql(u8, name, "Debug")) return &.{ "core", "fmt", "Debug" };
    if (std.mem.eql(u8, name, "Display")) return &.{ "core", "fmt", "Display" };
    if (std.mem.eql(u8, name, "Hash")) return &.{ "core", "hash", "Hash" };
    if (std.mem.eql(u8, name, "Hasher")) return &.{ "core", "hash", "Hasher" };
    if (std.mem.eql(u8, name, "PartialEq")) return &.{ "core", "cmp", "PartialEq" };
    if (std.mem.eql(u8, name, "Eq")) return &.{ "core", "cmp", "Eq" };
    if (std.mem.eql(u8, name, "PartialOrd")) return &.{ "core", "cmp", "PartialOrd" };
    if (std.mem.eql(u8, name, "Ord")) return &.{ "core", "cmp", "Ord" };
    if (std.mem.eql(u8, name, "Add")) return &.{ "core", "ops", "Add" };
    if (std.mem.eql(u8, name, "Sub")) return &.{ "core", "ops", "Sub" };
    if (std.mem.eql(u8, name, "Mul")) return &.{ "core", "ops", "Mul" };
    if (std.mem.eql(u8, name, "Div")) return &.{ "core", "ops", "Div" };
    if (std.mem.eql(u8, name, "Rem")) return &.{ "core", "ops", "Rem" };
    if (std.mem.eql(u8, name, "Not")) return &.{ "core", "ops", "Not" };
    if (std.mem.eql(u8, name, "BitAnd")) return &.{ "core", "ops", "BitAnd" };
    if (std.mem.eql(u8, name, "BitOr")) return &.{ "core", "ops", "BitOr" };
    if (std.mem.eql(u8, name, "BitXor")) return &.{ "core", "ops", "BitXor" };
    if (std.mem.eql(u8, name, "Shl")) return &.{ "core", "ops", "Shl" };
    if (std.mem.eql(u8, name, "Shr")) return &.{ "core", "ops", "Shr" };
    if (std.mem.eql(u8, name, "Neg")) return &.{ "core", "ops", "Neg" };
    if (std.mem.eql(u8, name, "AddAssign")) return &.{ "core", "ops", "AddAssign" };
    if (std.mem.eql(u8, name, "SubAssign")) return &.{ "core", "ops", "SubAssign" };
    if (std.mem.eql(u8, name, "MulAssign")) return &.{ "core", "ops", "MulAssign" };
    if (std.mem.eql(u8, name, "DivAssign")) return &.{ "core", "ops", "DivAssign" };
    if (std.mem.eql(u8, name, "RemAssign")) return &.{ "core", "ops", "RemAssign" };
    if (std.mem.eql(u8, name, "BitAndAssign")) return &.{ "core", "ops", "BitAndAssign" };
    if (std.mem.eql(u8, name, "BitOrAssign")) return &.{ "core", "ops", "BitOrAssign" };
    if (std.mem.eql(u8, name, "BitXorAssign")) return &.{ "core", "ops", "BitXorAssign" };
    if (std.mem.eql(u8, name, "ShlAssign")) return &.{ "core", "ops", "ShlAssign" };
    if (std.mem.eql(u8, name, "ShrAssign")) return &.{ "core", "ops", "ShrAssign" };
    if (std.mem.eql(u8, name, "Index")) return &.{ "core", "ops", "Index" };
    if (std.mem.eql(u8, name, "IndexMut")) return &.{ "core", "ops", "IndexMut" };
    if (std.mem.eql(u8, name, "Deref")) return &.{ "core", "ops", "Deref" };
    if (std.mem.eql(u8, name, "DerefMut")) return &.{ "core", "ops", "DerefMut" };
    return null;
}

fn preludePathSegments(allocator: std.mem.Allocator, name: []const u8) !?[]const types.PathSegment {
    const external = preludeExternalPath(name) orelse return null;
    const segments = try allocator.alloc(types.PathSegment, external.len);
    for (external, 0..) |seg_name, i| {
        segments[i] = .{ .name = try allocator.dupe(u8, seg_name), .id = null };
    }
    return segments;
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
    var source_owned = true;
    defer if (source_owned) freePathSegments(e, path_segments);
    const pending = e.pending_generics orelse return error.UnresolvedNominalType;
    if (pending.items.len >= @as(usize, unresolved_generic_decl_id)) {
        return error.UnresolvedNominalType;
    }
    const owner_id = e.declaration_owner orelse return error.UnresolvedNominalType;
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
    const placeholder: spine.EntityId = unresolved_generic_decl_id -
        @as(spine.EntityId, @intCast(pending.items.len));
    try pending.append(e.alloc, .{
        .placeholder = placeholder,
        .owner_id = owner_id,
        .path = owned_path,
    });
    freePathSegments(e, path_segments);
    source_owned = false;
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
    var segs_owned = true;
    defer {
        if (segs_owned) {
            for (segs.items) |segment| e.alloc.free(segment.name);
        }
        segs.deinit(e.alloc);
    }

    const kind = node.kind();
    if (std.mem.eql(u8, kind, "type_identifier") or std.mem.eql(u8, kind, "identifier")) {
        name = text(e, node);
    } else if (std.mem.eql(u8, kind, "scoped_type_identifier")) {
        const sub = try mapScopedSegments(e, node);
        segs.appendSlice(e.alloc, sub) catch |err| {
            freePathSegments(e, sub);
            return err;
        };
        e.alloc.free(sub);
    } else {
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            const k = c.kind();
            if (std.mem.eql(u8, k, "type_identifier") or std.mem.eql(u8, k, "identifier")) {
                name = text(e, c);
            } else if (std.mem.eql(u8, k, "scoped_type_identifier")) {
                const sub = try mapScopedSegments(e, c);
                segs.appendSlice(e.alloc, sub) catch |err| {
                    freePathSegments(e, sub);
                    return err;
                };
                e.alloc.free(sub);
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
    if (segs.items.len > 0 and isKnownExternalCrate(e.g, segs.items[0].name)) {
        const external_path = try e.alloc.alloc([]const u8, segs.items.len);
        for (segs.items, 0..) |segment, index| {
            if (segment.name.len == 0) return error.InvalidType;
            external_path[index] = try e.alloc.dupe(u8, segment.name);
        }
        return .{ .external_nominal = .{
            .path = external_path,
            .args = args,
        } };
    }
    if (segs.items.len > 0) {
        // A scoped type can begin with an unscoped external-use alias:
        // `io::Error` after `use std::io;`. Resolve the alias first, then
        // append the remaining nominal segments without erasing them.
        if (try externalUsePath(e, segs.items[0].name)) |alias_path| {
            if (segs.items.len == 1) {
                return .{ .external_nominal = .{ .path = alias_path, .args = args } };
            }
            const combined = try e.alloc.alloc([]const u8, alias_path.len + segs.items.len - 1);
            var copied: usize = 0;
            errdefer {
                for (combined[0..copied]) |segment| e.alloc.free(segment);
                e.alloc.free(combined);
            }
            for (alias_path, 0..) |segment, index| {
                combined[index] = try e.alloc.dupe(u8, segment);
                copied += 1;
            }
            for (segs.items[1..], 0..) |segment, index| {
                combined[alias_path.len + index] = try e.alloc.dupe(u8, segment.name);
                copied += 1;
            }
            freeExternalPath(e, alias_path);
            return .{ .external_nominal = .{ .path = combined, .args = args } };
        }
    }
    if (!had_scoped_segments) {
        if (try externalUsePath(e, nm)) |external_path| {
            return .{ .external_nominal = .{
                .path = external_path,
                .args = args,
            } };
        }
    }

    const prelude_visible = blk: {
        const owner_id = e.declaration_owner orelse break :blk true;
        const module_id = owningModule(e.g, owner_id) orelse break :blk true;
        break :blk resolveModuleItem(e.g, module_id, nm) == null;
    };
    if (!had_scoped_segments and prelude_visible and
        (std.mem.eql(u8, nm, "String") or std.mem.eql(u8, nm, "Vec")))
    {
        const prelude_path = preludeExternalPath(nm).?;
        const external_path = try e.alloc.alloc([]const u8, prelude_path.len);
        var copied: usize = 0;
        errdefer {
            for (external_path[0..copied]) |segment| e.alloc.free(segment);
            e.alloc.free(external_path);
        }
        for (prelude_path, 0..) |segment, index| {
            external_path[index] = try e.alloc.dupe(u8, segment);
            copied += 1;
        }
        return .{ .external_nominal = .{
            .path = external_path,
            .args = args,
        } };
    }
    if (args.len > 0) {
        if (segs.items.len == 0 or
            !std.mem.eql(u8, segs.items[segs.items.len - 1].name, nm))
        {
            try segs.append(e.alloc, .{
                .name = try e.alloc.dupe(u8, nm),
                .id = null,
            });
        }
        const path_segments = try segs.toOwnedSlice(e.alloc);
        segs_owned = false;
        var path_owned = true;
        defer if (path_owned) freePathSegments(e, path_segments);
        const owner_id = e.declaration_owner orelse return error.UnresolvedNominalType;
        var path: types.Path = .{ .segments = path_segments };
        bindPath(e.g, e.bodies_list.items, owner_id, &.{}, &path) catch |err| switch (err) {
            error.UnresolvedNominalType => {
                if (!had_scoped_segments) {
                    if (preludeExternalPath(nm)) |prelude_path| {
                        const ext_path = try e.alloc.alloc([]const u8, prelude_path.len);
                        for (prelude_path, 0..) |seg, i| {
                            ext_path[i] = try e.alloc.dupe(u8, seg);
                        }
                        return .{ .external_nominal = .{
                            .path = ext_path,
                            .args = args,
                        } };
                    }
                }
                path_owned = false;
                return makePendingGeneric(e, args, path_segments);
            },
            else => return err,
        };
        if (path.segments.len == 0) return error.UnresolvedNominalType;
        const base_def = path.segments[path.segments.len - 1].id orelse
            return error.UnresolvedNominalType;
        return .{
            .generic_inst = .{
                .decl = base_def,
                .args = .{ .params = args },
            },
        };
    }
    if (segs.items.len == 0 or !std.mem.eql(u8, segs.items[segs.items.len - 1].name, nm)) {
        try segs.append(e.alloc, .{
            .name = try e.alloc.dupe(u8, nm),
            .id = null,
        });
    }
    const plain_segments = try segs.toOwnedSlice(e.alloc);
    segs_owned = false;
    return .{ .path = .{ .segments = plain_segments } };
}

fn mapScopedSegments(e: *Ctx, node: ts.Node) TypeMapError![]const types.PathSegment {
    var segs: std.ArrayListUnmanaged(types.PathSegment) = .empty;
    errdefer {
        for (segs.items) |segment| e.alloc.free(segment.name);
        segs.deinit(e.alloc);
    }
    var source = std.mem.trim(u8, text(e, node), " \t\r\n");
    if (std.mem.startsWith(u8, source, "::")) source = source[2..];
    if (source.len == 0) return error.InvalidType;
    var path_parts = std.mem.splitSequence(u8, source, "::");
    while (path_parts.next()) |part| {
        const name = std.mem.trim(u8, part, " \t\r\n");
        if (name.len == 0) return error.InvalidType;
        if (name.len >= 2 and name[0] == '<' and name[name.len - 1] == '>') {
            const inner = std.mem.trim(u8, name[1 .. name.len - 1], " \t\r\n");
            if (std.mem.indexOf(u8, inner, " as ")) |as_index| {
                const generic_name = std.mem.trim(u8, inner[0..as_index], " \t\r\n");
                const trait_name = std.mem.trim(u8, inner[as_index + 4 ..], " \t\r\n");
                if (generic_name.len == 0 or trait_name.len == 0) return error.InvalidType;
                try segs.append(e.alloc, .{
                    .name = try e.alloc.dupe(u8, generic_name),
                    .id = null,
                });
                try segs.append(e.alloc, .{
                    .name = try e.alloc.dupe(u8, trait_name),
                    .id = null,
                });
                continue;
            }
        }
        try segs.append(e.alloc, .{
            .name = try e.alloc.dupe(u8, name),
            .id = null,
        });
    }
    return segs.toOwnedSlice(e.alloc);
}

pub const DeclarationTypeError = error{
    UnresolvedNominalType,
    InvalidNominalType,
    OutOfMemory,
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
    switch (body) {
        .fn_ => |fn_body| {
            for (fn_body.generic_params) |param| {
                if (std.mem.eql(u8, param, name)) return true;
            }
        },
        .struct_ => |struct_body| {
            for (struct_body.generic_params) |param| {
                if (std.mem.eql(u8, param, name)) return true;
            }
        },
        .trait_ => |trait_body| {
            for (trait_body.generic_params) |param| {
                if (std.mem.eql(u8, param, name)) return true;
            }
        },
        .impl_ => |impl_body| {
            if (impl_body.generics) |generics| {
                for (generics.params) |param| {
                    const param_name = switch (param) {
                        .type_ => |value| value.name,
                        .const_ => |value| value.name,
                        .lifetime => |value| value.name,
                    };
                    if (std.mem.eql(u8, param_name, name)) return true;
                }
            }
        },
        else => {},
    }
    return false;
}

fn genericParamBounds(
    generics: ?types.Generics,
    name: []const u8,
) ?[]const types.Bound {
    const value = generics orelse return null;
    for (value.params) |param| {
        switch (param) {
            .type_ => |type_param| {
                if (std.mem.eql(u8, type_param.name, name)) {
                    if (type_param.bounds.len > 0) return type_param.bounds;
                }
            },
            else => {},
        }
    }
    for (value.where_clauses) |clause| {
        if (clause.self_ty.segments.len == 1 and
            std.mem.eql(u8, clause.self_ty.segments[0].name, name))
        {
            if (clause.bounds.len > 0) return clause.bounds;
        }
    }
    return null;
}

fn bodyGenericParamBounds(
    body: bodies.BodyKind,
    name: []const u8,
) ?[]const types.Bound {
    return switch (body) {
        .fn_ => |fn_body| genericParamBounds(fn_body.generics, name),
        .impl_ => |impl_body| genericParamBounds(impl_body.generics, name),
        .trait_ => |trait_body| genericParamBounds(trait_body.generics, name),
        else => null,
    };
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
fn genericBoundsFor(
    g: *const graph.CrateGraph,
    bodies_list: []const bodies.BodyKind,
    owner_id: spine.EntityId,
    extra_generic_params: []const []const u8,
    name: []const u8,
) ?[]const types.Bound {
    // An extra list belongs to the innermost method scope. An equal name in
    // an enclosing body is shadowed even when that method has no bound.
    for (extra_generic_params) |param| {
        if (std.mem.eql(u8, param, name)) return &.{};
    }

    var current: ?spine.EntityId = owner_id;
    var depth: usize = 0;
    while (current) |entity_id| : (depth += 1) {
        if (depth >= g.symbol_table.entities.items.len) return null;
        const entity = g.symbol_table.get(entity_id) orelse return null;
        if (entity_id < bodies_list.len) {
            if (bodyGenericParamBounds(bodies_list[entity_id], name)) |bounds| {
                return bounds;
            }
            if (entity.kind == .struct_) {
                for (g.symbol_table.entities.items) |candidate| {
                    if (candidate.kind == .impl_ and candidate.parent == entity_id) {
                        if (candidate.id < bodies_list.len) {
                            if (bodyGenericParamBounds(bodies_list[candidate.id], name)) |bounds| {
                                return bounds;
                            }
                        }
                    }
                }
            }
            if (bodyHasGenericParam(bodies_list[entity_id], name)) return &.{};
        }
        current = entity.parent;
    }
    return null;
}

fn traitHasAssociatedMember(
    bodies_list: []const bodies.BodyKind,
    trait_id: spine.EntityId,
    name: []const u8,
) bool {
    if (trait_id >= bodies_list.len) return false;
    const trait_body = switch (bodies_list[trait_id]) {
        .trait_ => |body| body,
        else => return false,
    };
    for (trait_body.assoc_types) |assoc| {
        if (std.mem.eql(u8, assoc.name, name)) return true;
    }
    for (trait_body.assoc_consts) |assoc| {
        if (std.mem.eql(u8, assoc.name, name)) return true;
    }
    return false;
}

fn genericBoundTrait(
    g: *const graph.CrateGraph,
    bodies_list: []const bodies.BodyKind,
    owner_id: spine.EntityId,
    extra_generic_params: []const []const u8,
    generic_name: []const u8,
    trait_name: ?[]const u8,
    associated_name: ?[]const u8,
) ?spine.EntityId {
    const bounds = genericBoundsFor(
        g,
        bodies_list,
        owner_id,
        extra_generic_params,
        generic_name,
    ) orelse return null;
    for (bounds) |bound| {
        if (bound.path.segments.len == 0) continue;
        const terminal = bound.path.segments[bound.path.segments.len - 1];
        if (trait_name) |expected| {
            if (!std.mem.eql(u8, terminal.name, expected)) continue;
        }
        var trait_id = terminal.id;
        if (trait_id == null) {
            const module_id = owningModule(g, owner_id) orelse continue;
            trait_id = resolveModuleItem(g, module_id, terminal.name);
        }
        const resolved_id = trait_id orelse continue;
        const entity = g.symbol_table.get(resolved_id) orelse continue;
        if (entity.kind != .trait_) continue;
        if (associated_name) |assoc| {
            if (!traitHasAssociatedMember(bodies_list, resolved_id, assoc)) continue;
        }
        return resolved_id;
    }
    return null;
}

fn selfTypeEntity(g: *const graph.CrateGraph, owner_id: spine.EntityId) ?spine.EntityId {
    var current: ?spine.EntityId = owner_id;
    var depth: usize = 0;
    while (current) |entity_id| : (depth += 1) {
        if (depth >= g.symbol_table.entities.items.len) return null;
        const entity = g.symbol_table.get(entity_id) orelse return null;
        switch (entity.kind) {
            .struct_, .enum_, .union_ => return entity.id,
            .trait_, .module => return null,
            else => current = entity.parent,
        }
    }
    return null;
}

fn containingTrait(g: *const graph.CrateGraph, owner_id: spine.EntityId) ?spine.EntityId {
    var current: ?spine.EntityId = owner_id;
    var depth: usize = 0;
    while (current) |entity_id| : (depth += 1) {
        if (depth >= g.symbol_table.entities.items.len) return null;
        const entity = g.symbol_table.get(entity_id) orelse return null;
        if (entity.kind == .trait_) return entity.id;
        if (entity.kind == .module) return null;
        current = entity.parent;
    }
    return null;
}

fn containingImpl(g: *const graph.CrateGraph, owner_id: spine.EntityId) ?spine.EntityId {
    var current: ?spine.EntityId = owner_id;
    var depth: usize = 0;
    while (current) |entity_id| : (depth += 1) {
        if (depth >= g.symbol_table.entities.items.len) return null;
        const entity = g.symbol_table.get(entity_id) orelse return null;
        if (entity.kind == .impl_) return entity.id;
        current = entity.parent;
    }
    return null;
}
fn implSelfType(
    g: *const graph.CrateGraph,
    bodies_list: []const bodies.BodyKind,
    owner_id: spine.EntityId,
) ?types.Type {
    const impl_id = containingImpl(g, owner_id) orelse return null;
    if (impl_id >= bodies_list.len) return null;
    const self_ty = switch (bodies_list[impl_id]) {
        .impl_ => |impl_body| impl_body.self_ty,
        else => return null,
    };
    return switch (self_ty) {
        .path => |path| blk: {
            if (path.segments.len == 0) break :blk null;
            if (path.segments.len == 1 and
                std.mem.eql(u8, path.segments[0].name, "Self"))
            {
                break :blk null;
            }
            const terminal = path.segments[path.segments.len - 1];
            if (terminal.id == null and
                !activeGenericParam(g, bodies_list, impl_id, &.{}, terminal.name))
            {
                break :blk null;
            }
            break :blk self_ty;
        },
        .generic_inst => |generic_inst| if (generic_inst.decl == unresolved_generic_decl_id)
            null
        else
            self_ty,
        else => self_ty,
    };
}

fn associatedEntity(
    g: *const graph.CrateGraph,
    parent_id: spine.EntityId,
    name: []const u8,
) ?spine.EntityId {
    for (g.symbol_table.entities.items) |entity| {
        if (entity.parent != parent_id or !std.mem.eql(u8, entity.name, name)) continue;
        return switch (entity.kind) {
            .const_, .type_alias => entity.id,
            else => null,
        };
    }
    return null;
}

fn owningImplForStructMethod(
    g: *const graph.CrateGraph,
    struct_id: spine.EntityId,
    method_name: []const u8,
) ?spine.EntityId {
    for (g.symbol_table.entities.items) |entity| {
        if (entity.kind != .fn_ or !std.mem.eql(u8, entity.name, method_name)) continue;
        const impl_id = entity.parent orelse continue;
        const impl = g.symbol_table.get(impl_id) orelse continue;
        if (impl.kind == .impl_ and impl.parent == struct_id) return impl_id;
    }
    return null;
}

fn associatedAliasTarget(
    g: *const graph.CrateGraph,
    bodies_list: []const bodies.BodyKind,
    owner_id: spine.EntityId,
    name: []const u8,
) ?types.Type {
    const impl_id = containingImpl(g, owner_id) orelse return null;
    const alias_id = associatedEntity(g, impl_id, name) orelse return null;
    if (alias_id >= bodies_list.len) return null;
    return switch (bodies_list[alias_id]) {
        .type_alias => |alias| alias.target,
        else => null,
    };
}
fn bindProjectionPath(
    g: *const graph.CrateGraph,
    bodies_list: []const bodies.BodyKind,
    owner_id: spine.EntityId,
    extra_generic_params: []const []const u8,
    path: *types.Path,
) DeclarationTypeError!void {
    if (path.segments.len == 0) return;
    const first = path.segments[0].name;
    if (std.mem.eql(u8, first, "Self")) {
        const self_id = selfTypeEntity(g, owner_id);
        if (self_id) |id| @constCast(path.segments)[0].id = id;
        if (path.segments.len == 2) {
            if (containingImpl(g, owner_id)) |impl_id| {
                const terminal = path.segments[path.segments.len - 1].name;
                if (associatedEntity(g, impl_id, terminal)) |assoc_id| {
                    @constCast(path.segments)[path.segments.len - 1].id = assoc_id;
                }
            }
            if (self_id) |id| {
                const terminal = path.segments[path.segments.len - 1].name;
                if (associatedEntity(g, id, terminal)) |assoc_id| {
                    @constCast(path.segments)[path.segments.len - 1].id = assoc_id;
                }
            }
        }
        if (self_id == null and path.segments.len == 2) {
            if (containingTrait(g, owner_id)) |trait_id| {
                const associated_name = path.segments[1].name;
                if (traitHasAssociatedMember(bodies_list, trait_id, associated_name)) {
                    const old_segments = path.segments;
                    const expanded = try g.allocator.alloc(types.PathSegment, 3);
                    expanded[0] = old_segments[0];
                    const trait = g.symbol_table.get(trait_id) orelse return;
                    expanded[1] = .{ .name = trait.name, .id = trait_id };
                    expanded[2] = old_segments[1];
                    path.segments = expanded;
                    g.allocator.free(old_segments);
                }
            }
        }
        if (path.segments.len > 2) {
            const module_id = owningModule(g, owner_id) orelse return;
            if (resolveModuleItem(g, module_id, path.segments[1].name)) |trait_id| {
                if (g.symbol_table.get(trait_id)) |trait| {
                    if (trait.kind == .trait_) {
                        @constCast(path.segments)[1].id = trait_id;
                    }
                }
            }
        }
        return;
    }
    if (!activeGenericParam(g, bodies_list, owner_id, extra_generic_params, first)) return;

    if (path.segments.len > 2) {
        const terminal = path.segments[path.segments.len - 1].name;
        var trait_id = genericBoundTrait(
            g,
            bodies_list,
            owner_id,
            extra_generic_params,
            first,
            path.segments[1].name,
            terminal,
        );
        if (trait_id == null) {
            const module_id = owningModule(g, owner_id) orelse return;
            if (resolveModuleItem(g, module_id, path.segments[1].name)) |resolved_id| {
                if (g.symbol_table.get(resolved_id)) |trait| {
                    if (trait.kind == .trait_) trait_id = resolved_id;
                }
            }
        }
        if (trait_id) |id| @constCast(path.segments)[1].id = id;
        return;
    }

    // Rust also permits the shorthand `T::Assoc`. Canonicalize it to the
    // three-segment projection expected by the backend without replacing the
    // generic receiver with a bound trait or concrete type.
    if (path.segments.len == 2) {
        const associated_name = path.segments[1].name;
        const trait_id = genericBoundTrait(
            g,
            bodies_list,
            owner_id,
            extra_generic_params,
            first,
            null,
            associated_name,
        ) orelse return;
        const trait = g.symbol_table.get(trait_id) orelse return;
        const old_segments = path.segments;
        const expanded = try g.allocator.alloc(types.PathSegment, 3);
        expanded[0] = old_segments[0];
        expanded[1] = .{ .name = trait.name, .id = trait_id };
        expanded[2] = old_segments[1];
        path.segments = expanded;
        g.allocator.free(old_segments);
    }
}

fn bindPath(
    g: *const graph.CrateGraph,
    bodies_list: []const bodies.BodyKind,
    owner_id: spine.EntityId,
    extra_generic_params: []const []const u8,
    path: *types.Path,
) DeclarationTypeError!void {
    if (path.segments.len == 0) return error.UnresolvedNominalType;
    var index: usize = 0;
    const first_name = path.segments[0].name;

    if (std.mem.eql(u8, first_name, "Self")) {
        if (path.segments.len == 1) {
            const self_id = selfTypeEntity(g, owner_id);
            if (self_id) |id| {
                @constCast(path.segments)[0].id = id;
                return;
            }
            if (containingImpl(g, owner_id)) |_| return;
            if (containingTrait(g, owner_id)) |_| return;
            return error.UnresolvedNominalType;
        }
        try bindProjectionPath(g, bodies_list, owner_id, extra_generic_params, path);
        return;
    }
    if (activeGenericParam(g, bodies_list, owner_id, extra_generic_params, first_name)) {
        @constCast(path.segments)[0].id = null;
        if (path.segments.len > 1) {
            try bindProjectionPath(g, bodies_list, owner_id, extra_generic_params, path);
        }
        return;
    }
    var current = owningModule(g, owner_id) orelse return error.UnresolvedNominalType;
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
        .path => |*path| {
            if (path.segments.len == 2 and
                std.mem.eql(u8, path.segments[0].name, "Self"))
            {
                if (associatedAliasTarget(g, bodies_list, owner_id, path.segments[path.segments.len - 1].name)) |target| {
                    ty.* = target;
                    try bindType(
                        g,
                        bodies_list,
                        owner_id,
                        extra_generic_params,
                        pending,
                        ty,
                    );
                    return;
                }
            }
            if (path.segments.len == 1 and std.mem.eql(u8, path.segments[0].name, "Self")) {
                if (implSelfType(g, bodies_list, owner_id)) |self_ty| {
                    ty.* = self_ty;
                    try bindType(
                        g,
                        bodies_list,
                        owner_id,
                        extra_generic_params,
                        pending,
                        ty,
                    );
                    return;
                }
            }
            if (bindPath(g, bodies_list, owner_id, extra_generic_params, path)) {} else |err| switch (err) {
                error.UnresolvedNominalType => {
                    if (path.segments.len == 1) {
                        if (preludePathSegments(g.allocator, path.segments[0].name) catch null) |prelude_segs| {
                            path.segments = prelude_segs;
                            return;
                        }
                    }
                    return err;
                },
                else => return err,
            }
        },
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
            if (!isKnownExternalCrate(g, external.path[0])) {
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
        .@"opaque" => |*opaque_type| {
            for (@constCast(opaque_type.bounds)) |*bound| {
                try bindBound(
                    g,
                    bodies_list,
                    owner_id,
                    extra_generic_params,
                    pending,
                    bound,
                );
            }
            if (opaque_type.concrete) |concrete| {
                try bindType(
                    g,
                    bodies_list,
                    owner_id,
                    extra_generic_params,
                    pending,
                    @constCast(concrete),
                );
            }
        },
        .dyn_trait => |bounds| {
            for (@constCast(bounds)) |*bound| {
                try bindBound(
                    g,
                    bodies_list,
                    owner_id,
                    extra_generic_params,
                    pending,
                    bound,
                );
            }
        },
        .prim, .unsupported => {},
    }
}

fn bindBound(
    g: *const graph.CrateGraph,
    bodies_list: []const bodies.BodyKind,
    owner_id: spine.EntityId,
    extra_generic_params: []const []const u8,
    pending: []const PendingGenericApplication,
    bound: *types.Bound,
) DeclarationTypeError!void {
    if (bindPath(
        g,
        bodies_list,
        owner_id,
        extra_generic_params,
        &bound.path,
    )) {} else |err| switch (err) {
        error.UnresolvedNominalType => {
            if (bound.path.segments.len == 1) {
                if (preludePathSegments(
                    g.allocator,
                    bound.path.segments[0].name,
                ) catch null) |prelude_segs| {
                    bound.path.segments = prelude_segs;
                }
            }
        },
        else => return err,
    }
    for (@constCast(bound.args)) |*arg| {
        try bindType(g, bodies_list, owner_id, extra_generic_params, pending, arg);
    }
    for (@constCast(bound.associated_types)) |*associated_type| {
        try bindType(
            g,
            bodies_list,
            owner_id,
            extra_generic_params,
            pending,
            &associated_type.ty,
        );
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
fn bindGenerics(
    g: *const graph.CrateGraph,
    bodies_list: []const bodies.BodyKind,
    owner_id: spine.EntityId,
    extra_generic_params: []const []const u8,
    pending: []const PendingGenericApplication,
    generics: *types.Generics,
) DeclarationTypeError!void {
    for (@constCast(generics.params)) |*param| {
        switch (param.*) {
            .type_ => |*type_param| {
                for (@constCast(type_param.bounds)) |*bound| {
                    try bindBound(
                        g,
                        bodies_list,
                        owner_id,
                        extra_generic_params,
                        pending,
                        bound,
                    );
                }
            },
            .const_ => |*const_param| try bindType(
                g,
                bodies_list,
                owner_id,
                extra_generic_params,
                pending,
                &const_param.ty,
            ),
            .lifetime => {},
        }
    }
    for (@constCast(generics.where_clauses)) |*clause| {
        bindPath(
            g,
            bodies_list,
            owner_id,
            extra_generic_params,
            &clause.self_ty,
        ) catch |err| switch (err) {
            error.UnresolvedNominalType => {},
            else => return err,
        };
        for (@constCast(clause.bounds)) |*bound| {
            try bindBound(
                g,
                bodies_list,
                owner_id,
                extra_generic_params,
                pending,
                bound,
            );
        }
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
                if (function.generics) |*generics| {
                    try bindGenerics(
                        g,
                        body_slice,
                        @intCast(owner_id),
                        &.{},
                        pending,
                        generics,
                    );
                }
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
                    const method_owner_id: spine.EntityId = owningImplForStructMethod(
                        g,
                        @intCast(owner_id),
                        method.name,
                    ) orelse @intCast(owner_id);
                    if (method.generics) |*generics| {
                        try bindGenerics(
                            g,
                            body_slice,
                            method_owner_id,
                            method.generic_params,
                            pending,
                            generics,
                        );
                    }
                    try bindParams(
                        g,
                        body_slice,
                        method_owner_id,
                        method.generic_params,
                        pending,
                        method.params,
                    );
                    try bindType(
                        g,
                        body_slice,
                        method_owner_id,
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
                if (trait_body.generics) |*generics| {
                    try bindGenerics(
                        g,
                        body_slice,
                        @intCast(owner_id),
                        &.{},
                        pending,
                        generics,
                    );
                }
                for (@constCast(trait_body.methods)) |*method| {
                    if (method.generics) |*generics| {
                        try bindGenerics(
                            g,
                            body_slice,
                            @intCast(owner_id),
                            method.generic_params,
                            pending,
                            generics,
                        );
                    }
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
                for (@constCast(trait_body.assoc_types)) |*assoc| {
                    if (assoc.default) |*default| {
                        try bindType(
                            g,
                            body_slice,
                            @intCast(owner_id),
                            &.{},
                            pending,
                            default,
                        );
                    }
                }
                for (@constCast(trait_body.assoc_consts)) |*assoc| {
                    try bindType(
                        g,
                        body_slice,
                        @intCast(owner_id),
                        &.{},
                        pending,
                        &assoc.ty,
                    );
                }
            },
            .impl_ => |*impl_body| {
                if (impl_body.generics) |*generics| {
                    try bindGenerics(
                        g,
                        body_slice,
                        @intCast(owner_id),
                        &.{},
                        pending,
                        generics,
                    );
                }
                bindType(
                    g,
                    body_slice,
                    @intCast(owner_id),
                    &.{},
                    pending,
                    &impl_body.self_ty,
                ) catch |err| switch (err) {
                    error.UnresolvedNominalType, error.InvalidNominalType => {},
                    else => return err,
                };
                if (impl_body.trait_path) |*trait_path| {
                    if (bindPath(
                        g,
                        body_slice,
                        @intCast(owner_id),
                        &.{},
                        trait_path,
                    )) {} else |err| switch (err) {
                        error.UnresolvedNominalType => {
                            if (trait_path.segments.len == 1) {
                                if (preludePathSegments(g.allocator, trait_path.segments[0].name) catch null) |prelude_segs| {
                                    trait_path.segments = prelude_segs;
                                }
                            }
                        },
                        else => return err,
                    }
                    for (@constCast(impl_body.trait_args)) |*arg| {
                        try bindType(g, body_slice, @intCast(owner_id), &.{}, pending, arg);
                    }
                    for (@constCast(impl_body.trait_associated_types)) |*assoc| {
                        try bindType(g, body_slice, @intCast(owner_id), &.{}, pending, &assoc.ty);
                    }
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

fn boundPathFromType(e: *Ctx, ty: types.Type) ?types.Path {
    return switch (ty) {
        .path => |path| path,
        .external_nominal => |external| blk: {
            var copied = e.alloc.alloc(types.PathSegment, external.path.len) catch break :blk null;
            for (external.path, 0..) |name, index| {
                copied[index] = .{ .name = name, .id = null };
            }
            break :blk .{ .segments = copied };
        },
        else => null,
    };
}

fn parseTraitBound(e: *Ctx, node: ts.Node) !?types.Bound {
    var actual_node = node;
    var optional = false;
    if (std.mem.eql(u8, node.kind(), "removed_trait_bound")) {
        optional = true;
        var i: u32 = 0;
        var found: ?ts.Node = null;
        while (node.namedChild(i)) |child| : (i += 1) {
            found = child;
            break;
        }
        actual_node = found orelse return null;
    }
    if (std.mem.eql(u8, actual_node.kind(), "lifetime")) return null;

    var args_list: std.ArrayListUnmanaged(types.Type) = .empty;
    errdefer args_list.deinit(e.alloc);
    var assoc_list: std.ArrayListUnmanaged(types.AssociatedTypeBinding) = .empty;
    errdefer assoc_list.deinit(e.alloc);

    var trait_node = actual_node;
    if (std.mem.eql(u8, actual_node.kind(), "generic_type")) {
        trait_node = actual_node.childByFieldName("type") orelse return error.InvalidType;
        const args_node = actual_node.childByFieldName("type_arguments") orelse
            return error.InvalidType;
        var i: u32 = 0;
        while (args_node.namedChild(i)) |arg_child| : (i += 1) {
            const arg_kind = arg_child.kind();
            if (std.mem.eql(u8, arg_kind, "lifetime")) continue;
            if (std.mem.eql(u8, arg_kind, "type_binding")) {
                if (arg_child.childByFieldName("type_arguments") != null) {
                    return error.InvalidType;
                }
                const binding_name = arg_child.childByFieldName("name") orelse
                    return error.InvalidType;
                const binding_type = arg_child.childByFieldName("type") orelse
                    return error.InvalidType;
                try assoc_list.append(e.alloc, .{
                    .name = try e.alloc.dupe(u8, text(e, binding_name)),
                    .ty = try mapType(e, binding_type),
                });
            } else {
                const arg_ty = try mapType(e, arg_child);
                try args_list.append(e.alloc, arg_ty);
            }
        }
    }

    const mapped_trait = try mapType(e, trait_node);
    var bound_path: types.Path = boundPathFromType(e, mapped_trait) orelse blk: {
        const segs = try mapScopedSegments(e, trait_node);
        break :blk .{ .segments = segs };
    };
    if (bound_path.segments.len == 1) {
        if (preludePathSegments(e.alloc, bound_path.segments[0].name) catch null) |prelude_segs| {
            bound_path.segments = prelude_segs;
        }
    }

    return .{
        .path = bound_path,
        .args = try args_list.toOwnedSlice(e.alloc),
        .associated_types = try assoc_list.toOwnedSlice(e.alloc),
        .optional = optional,
    };
}

fn appendTraitTypeBounds(
    e: *Ctx,
    node: ts.Node,
    bounds: *std.ArrayListUnmanaged(types.Bound),
) !void {
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "lifetime")) return;
    if (std.mem.eql(u8, kind, "bounded_type") or
        std.mem.eql(u8, kind, "trait_bounds") or
        std.mem.eql(u8, kind, "type_bound"))
    {
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            try appendTraitTypeBounds(e, child, bounds);
        }
        return;
    }
    if (std.mem.eql(u8, kind, "dynamic_type")) {
        const trait_node = node.childByFieldName("trait") orelse return error.InvalidType;
        try appendTraitTypeBounds(e, trait_node, bounds);
        return;
    }
    if (std.mem.eql(u8, kind, "higher_ranked_trait_bound") or
        std.mem.eql(u8, kind, "use_bounds"))
    {
        return error.InvalidType;
    }
    const bound = (try parseTraitBound(e, node)) orelse return error.InvalidType;
    try bounds.append(e.alloc, bound);
}

fn collectTraitTypeBounds(e: *Ctx, node: ts.Node) ![]const types.Bound {
    var bounds: std.ArrayListUnmanaged(types.Bound) = .empty;
    errdefer bounds.deinit(e.alloc);
    try appendTraitTypeBounds(e, node, &bounds);
    return bounds.toOwnedSlice(e.alloc);
}

fn collectGenericBounds(e: *Ctx, node: ts.Node) ![]const types.Bound {
    if (std.mem.eql(u8, node.kind(), "trait_bounds")) {
        return collectTraitTypeBounds(e, node);
    }
    var bounds: std.ArrayListUnmanaged(types.Bound) = .empty;
    errdefer bounds.deinit(e.alloc);
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        const kind = child.kind();
        if (std.mem.eql(u8, kind, "trait_bounds") or
            std.mem.eql(u8, kind, "type_bound"))
        {
            try appendTraitTypeBounds(e, child, &bounds);
        }
    }
    return bounds.toOwnedSlice(e.alloc);
}

fn collectWhereClause(
    e: *Ctx,
    where_node: ts.Node,
    where_clauses: *std.ArrayListUnmanaged(types.WhereClause),
) !void {
    var i: u32 = 0;
    while (where_node.namedChild(i)) |predicate| : (i += 1) {
        if (!std.mem.eql(u8, predicate.kind(), "where_predicate")) continue;
        const left_node = predicate.childByFieldName("left") orelse
            (if (predicate.namedChildCount() > 0) predicate.namedChild(0) else null) orelse continue;
        if (std.mem.eql(u8, left_node.kind(), "lifetime")) continue;
        const left_type = try mapType(e, left_node);
        const self_path = boundPathFromType(e, left_type) orelse return error.InvalidType;
        const bounds_node = predicate.childByFieldName("bounds") orelse blk: {
            var j: u32 = 0;
            while (predicate.namedChild(j)) |c| : (j += 1) {
                if (std.mem.eql(u8, c.kind(), "trait_bounds")) break :blk c;
            }
            break :blk null;
        };
        const clause_bounds = if (bounds_node) |bn|
            try collectGenericBounds(e, bn)
        else
            &[_]types.Bound{};
        try where_clauses.append(e.alloc, .{
            .self_ty = self_path,
            .bounds = clause_bounds,
        });
    }
}

fn collectGenericsWithSelfBounds(
    e: *Ctx,
    item: ts.Node,
    self_bounds: []const types.Bound,
) !?types.Generics {
    var params: std.ArrayListUnmanaged(types.GenericParam) = .empty;
    errdefer params.deinit(e.alloc);
    var where_clauses: std.ArrayListUnmanaged(types.WhereClause) = .empty;
    errdefer where_clauses.deinit(e.alloc);
    var found = false;
    var i: u32 = 0;
    while (item.namedChild(i)) |child| : (i += 1) {
        const ck = child.kind();
        if (std.mem.eql(u8, ck, "type_parameters")) {
            var j: u32 = 0;
            while (child.namedChild(j)) |parameter| : (j += 1) {
                const kind = parameter.kind();
                if (std.mem.eql(u8, kind, "type_parameter")) {
                    var name: []const u8 = "";
                    var k: u32 = 0;
                    while (parameter.namedChild(k)) |part| : (k += 1) {
                        if (std.mem.eql(u8, part.kind(), "type_identifier")) {
                            name = text(e, part);
                            break;
                        }
                    }
                    if (name.len == 0) continue;
                    try params.append(e.alloc, .{ .type_ = .{
                        .name = try e.alloc.dupe(u8, name),
                        .bounds = try collectGenericBounds(e, parameter),
                    } });
                    found = true;
                } else if (std.mem.eql(u8, kind, "const_parameter")) {
                    var name: []const u8 = "";
                    var ty_node: ?ts.Node = parameter.childByFieldName("type");
                    var k: u32 = 0;
                    while (parameter.namedChild(k)) |part| : (k += 1) {
                        if (std.mem.eql(u8, part.kind(), "identifier")) name = text(e, part);
                        if (ty_node == null and std.mem.eql(u8, part.kind(), "type")) ty_node = part;
                    }
                    if (name.len == 0 or ty_node == null) continue;
                    try params.append(e.alloc, .{ .const_ = .{
                        .name = try e.alloc.dupe(u8, name),
                        .ty = try mapType(e, ty_node.?),
                    } });
                    found = true;
                } else if (std.mem.eql(u8, kind, "lifetime_parameter")) {
                    try params.append(e.alloc, .{ .lifetime = .{
                        .name = try e.alloc.dupe(u8, text(e, parameter)),
                    } });
                    found = true;
                }
            }
        } else if (std.mem.eql(u8, ck, "where_clause")) {
            try collectWhereClause(e, child, &where_clauses);
            found = true;
        }
    }
    if (self_bounds.len > 0) {
        const self_segments = try e.alloc.alloc(types.PathSegment, 1);
        self_segments[0] = .{
            .name = try e.alloc.dupe(u8, "Self"),
            .id = null,
        };
        try where_clauses.append(e.alloc, .{
            .self_ty = .{ .segments = self_segments },
            .bounds = self_bounds,
        });
        found = true;
    }
    if (!found) {
        params.deinit(e.alloc);
        where_clauses.deinit(e.alloc);
        return null;
    }
    return .{
        .params = try params.toOwnedSlice(e.alloc),
        .where_clauses = try where_clauses.toOwnedSlice(e.alloc),
    };
}

fn collectGenerics(e: *Ctx, item: ts.Node) !?types.Generics {
    return collectGenericsWithSelfBounds(e, item, &.{});
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
                std.mem.eql(u8, k, "array_type") or
                std.mem.eql(u8, k, "tuple_type") or
                std.mem.eql(u8, k, "unit_type") or
                std.mem.eql(u8, k, "abstract_type") or
                std.mem.eql(u8, k, "dynamic_type") or
                std.mem.eql(u8, k, "bounded_type"))
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
/// and `parameter` nodes, preserving source bindings through a synthetic outer
/// name for nontrivial patterns.
fn isParameterPatternKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "pattern") or
        std.mem.eql(u8, kind, "mut_pattern") or
        std.mem.eql(u8, kind, "tuple_pattern") or
        std.mem.eql(u8, kind, "struct_pattern") or
        std.mem.eql(u8, kind, "tuple_struct_pattern") or
        std.mem.eql(u8, kind, "reference_pattern") or
        std.mem.eql(u8, kind, "wildcard_pattern") or
        std.mem.eql(u8, kind, "or_pattern") or
        std.mem.eql(u8, kind, "slice_pattern") or
        std.mem.eql(u8, kind, "literal_pattern") or
        std.mem.eql(u8, kind, "scoped_identifier") or
        std.mem.eql(u8, kind, "char_literal");
}

fn parameterPatternNode(node: ts.Node) ?ts.Node {
    if (std.mem.eql(u8, node.kind(), "self_parameter")) return null;
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), "identifier") or
            isParameterPatternKind(child.kind()))
        {
            return child;
        }
    }
    return null;
}

fn plainParameterName(e: *const Ctx, node: ts.Node) ?[]const u8 {
    if (std.mem.eql(u8, node.kind(), "identifier")) return text(e, node);
    if (!std.mem.eql(u8, node.kind(), "pattern") or node.namedChildCount() != 1) return null;
    return plainParameterName(e, node.namedChild(0).?);
}

fn collectParameterPatternNames(
    e: *const Ctx,
    node: ts.Node,
    pattern_names: *std.ArrayListUnmanaged([]const u8),
) !void {
    if (std.mem.eql(u8, node.kind(), "identifier")) {
        try pattern_names.append(e.alloc, text(e, node));
    }
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        try collectParameterPatternNames(e, child, pattern_names);
    }
}

fn syntheticParameterName(
    e: *Ctx,
    ordinal: usize,
    source_names: []const []const u8,
) ![]const u8 {
    var candidate = try std.fmt.allocPrint(e.alloc, "__r2z_param_{d}", .{ordinal});
    while (true) {
        var collision = false;
        for (source_names) |source_name| {
            if (std.mem.eql(u8, candidate, source_name)) {
                collision = true;
                break;
            }
        }
        if (!collision) return candidate;
        const extended = try std.fmt.allocPrint(e.alloc, "{s}_", .{candidate});
        e.alloc.free(candidate);
        candidate = extended;
    }
}

fn selfParameterType(e: *Ctx, node: ts.Node) !types.Type {
    var borrowed = false;
    var mutable = false;
    var i: u32 = 0;
    while (node.child(i)) |child| : (i += 1) {
        const kind = child.kind();
        if (std.mem.eql(u8, kind, "&")) borrowed = true;
        if (std.mem.eql(u8, kind, "mutable_specifier")) mutable = true;
    }

    const segments = try e.alloc.alloc(types.PathSegment, 1);
    errdefer e.alloc.free(segments);
    segments[0] = .{ .name = "Self", .id = null };
    const self_type: types.Type = .{ .path = .{ .segments = segments } };
    if (!borrowed) return self_type;

    const reference = try e.alloc.create(types.Ref);
    reference.* = .{ .mut = mutable, .pointee = self_type };
    return .{ .reference = reference };
}

fn mapParams(e: *Ctx, params_node: ?ts.Node) ![]const items.Param {
    var params: std.ArrayListUnmanaged(items.Param) = .empty;
    errdefer params.deinit(e.alloc);
    var source_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer source_names.deinit(e.alloc);

    if (params_node) |pn| {
        var j: u32 = 0;
        while (pn.namedChild(j)) |p| : (j += 1) {
            if (!std.mem.eql(u8, p.kind(), "parameter")) continue;
            if (parameterPatternNode(p)) |pattern| {
                try collectParameterPatternNames(e, pattern, &source_names);
            }
        }

        var nonself_ordinal: usize = 0;
        j = 0;
        while (pn.namedChild(j)) |p| : (j += 1) {
            const pk = p.kind();
            if (!std.mem.eql(u8, pk, "parameter") and !std.mem.eql(u8, pk, "self_parameter")) continue;
            var pname: ?[]const u8 = null;
            var pty: ?types.Type = null;
            var is_self = std.mem.eql(u8, pk, "self_parameter");
            if (is_self) {
                pname = "self";
                pty = try selfParameterType(e, p);
            }
            var k: u32 = 0;
            while (p.namedChild(k)) |c| : (k += 1) {
                const kk = c.kind();
                if (std.mem.eql(u8, kk, "identifier")) {
                    if (pname == null) pname = text(e, c);
                } else if (std.mem.eql(u8, kk, "self")) {
                    pname = "self";
                    is_self = true;
                } else if (std.mem.eql(u8, kk, "type") or
                    std.mem.eql(u8, kk, "primitive_type") or
                    std.mem.eql(u8, kk, "reference_type") or
                    std.mem.eql(u8, kk, "pointer_type") or
                    std.mem.eql(u8, kk, "generic_type") or
                    std.mem.eql(u8, kk, "type_identifier") or
                    std.mem.eql(u8, kk, "scoped_type_identifier") or
                    std.mem.eql(u8, kk, "array_type") or
                    std.mem.eql(u8, kk, "slice_type") or
                    std.mem.eql(u8, kk, "tuple_type") or
                    std.mem.eql(u8, kk, "unit_type") or
                    std.mem.eql(u8, kk, "abstract_type") or
                    std.mem.eql(u8, kk, "dynamic_type") or
                    std.mem.eql(u8, kk, "bounded_type"))
                {
                    pty = try mapType(e, c);
                }
            }
            var synthetic_name = false;
            if (!is_self) {
                const pattern = parameterPatternNode(p);
                if (pattern) |pattern_node| {
                    pname = plainParameterName(e, pattern_node);
                    if (pname == null) {
                        pname = try syntheticParameterName(e, nonself_ordinal, source_names.items);
                        synthetic_name = true;
                    }
                } else if (pname == null) {
                    pname = try syntheticParameterName(e, nonself_ordinal, source_names.items);
                    synthetic_name = true;
                }
                nonself_ordinal += 1;
            }
            const param_name = pname orelse return error.MalformedParameter;
            const param_ty = pty orelse return error.MalformedParameter;
            const name_copy = if (synthetic_name)
                param_name
            else
                try e.alloc.dupe(u8, param_name);
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

fn traitAssocType(e: *Ctx, item: ts.Node) !items.AssocType {
    var name: []const u8 = "";
    var i: u32 = 0;
    while (item.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), "type_identifier")) {
            name = text(e, child);
            break;
        }
    }
    if (name.len == 0) return error.MalformedItemName;
    var default_node = item.childByFieldName("type");
    if (default_node == null and std.mem.indexOfScalar(u8, text(e, item), '=') != null) {
        var child_index: u32 = 0;
        while (item.namedChild(child_index)) |child| : (child_index += 1) {
            const kind = child.kind();
            if (std.mem.eql(u8, kind, "type") or
                std.mem.eql(u8, kind, "primitive_type") or
                std.mem.eql(u8, kind, "generic_type") or
                std.mem.eql(u8, kind, "type_identifier") or
                std.mem.eql(u8, kind, "scoped_type_identifier") or
                std.mem.eql(u8, kind, "reference_type") or
                std.mem.eql(u8, kind, "array_type") or
                std.mem.eql(u8, kind, "slice_type") or
                std.mem.eql(u8, kind, "tuple_type") or
                std.mem.eql(u8, kind, "unit_type") or
                std.mem.eql(u8, kind, "abstract_type") or
                std.mem.eql(u8, kind, "dynamic_type") or
                std.mem.eql(u8, kind, "bounded_type"))
            {
                default_node = child;
            }
        }
    }
    const default_type = if (default_node) |node|
        try mapType(e, node)
    else
        null;
    return .{
        .name = try e.alloc.dupe(u8, name),
        .generics = null,
        .bounds = try collectGenericBounds(e, item),
        .default = default_type,
    };
}

fn traitAssocConst(e: *Ctx, item: ts.Node) !bodies.TraitAssocConst {
    var name: []const u8 = "";
    var i: u32 = 0;
    while (item.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), "identifier")) {
            name = text(e, child);
            break;
        }
    }
    if (name.len == 0) return error.MalformedItemName;
    var type_node = item.childByFieldName("type");
    if (type_node == null) {
        var saw_name = false;
        var child_index: u32 = 0;
        while (item.namedChild(child_index)) |child| : (child_index += 1) {
            const kind = child.kind();
            if (std.mem.eql(u8, kind, "identifier") and !saw_name) {
                saw_name = true;
                continue;
            }
            if (std.mem.eql(u8, kind, "type") or
                std.mem.eql(u8, kind, "primitive_type") or
                std.mem.eql(u8, kind, "generic_type") or
                std.mem.eql(u8, kind, "type_identifier") or
                std.mem.eql(u8, kind, "scoped_type_identifier") or
                std.mem.eql(u8, kind, "reference_type") or
                std.mem.eql(u8, kind, "array_type") or
                std.mem.eql(u8, kind, "slice_type") or
                std.mem.eql(u8, kind, "tuple_type") or
                std.mem.eql(u8, kind, "unit_type") or
                std.mem.eql(u8, kind, "abstract_type") or
                std.mem.eql(u8, kind, "dynamic_type") or
                std.mem.eql(u8, kind, "bounded_type"))
            {
                type_node = child;
                break;
            }
        }
    }
    const type_node_value = type_node orelse return error.MalformedConstType;
    return .{
        .name = try e.alloc.dupe(u8, name),
        .ty = try mapType(e, type_node_value),
        .default = null,
    };
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
    const trait_generic_params = try collectFunctionGenericParams(e, item);
    var methods: std.ArrayListUnmanaged(bodies.TraitMethodSig) = .empty;
    var assoc_types: std.ArrayListUnmanaged(items.AssocType) = .empty;
    var assoc_consts: std.ArrayListUnmanaged(bodies.TraitAssocConst) = .empty;
    var supertraits: std.ArrayListUnmanaged([]const u8) = .empty;
    var supertrait_bounds: std.ArrayListUnmanaged(types.Bound) = .empty;
    errdefer {
        methods.deinit(e.alloc);
        assoc_types.deinit(e.alloc);
        assoc_consts.deinit(e.alloc);
        supertraits.deinit(e.alloc);
        supertrait_bounds.deinit(e.alloc);
    }
    var s: u32 = 0;
    while (item.namedChild(s)) |child| : (s += 1) {
        const ck = child.kind();
        if (std.mem.eql(u8, ck, "trait_bounds")) {
            try appendTraitTypeBounds(e, child, &supertrait_bounds);
            var b: u32 = 0;
            while (child.namedChild(b)) |bound| : (b += 1) {
                if (std.mem.eql(u8, bound.kind(), "lifetime")) continue;
                try supertraits.append(e.alloc, try e.alloc.dupe(u8, text(e, bound)));
            }
        } else if (std.mem.eql(u8, ck, "type_bound")) {
            try appendTraitTypeBounds(e, child, &supertrait_bounds);
            try supertraits.append(e.alloc, try e.alloc.dupe(u8, text(e, child)));
        }
    }
    const typed_supertraits = try supertrait_bounds.toOwnedSlice(e.alloc);
    const trait_generics = try collectGenericsWithSelfBounds(e, item, typed_supertraits);
    if (decls) |dl| {
        var j: u32 = 0;
        while (dl.namedChild(j)) |m| : (j += 1) {
            if (std.mem.eql(u8, m.kind(), "function_signature_item")) {
                var mname: []const u8 = "";
                var mparams_node: ?ts.Node = null;
                var k: u32 = 0;
                while (m.namedChild(k)) |c| : (k += 1) {
                    const kk = c.kind();
                    if (std.mem.eql(u8, kk, "identifier")) mname = text(e, c);
                    if (std.mem.eql(u8, kk, "parameters")) mparams_node = c;
                }
                if (mname.len == 0) return error.MalformedItemName;
                const method_generic_params = try collectFunctionGenericParams(e, m);
                const method_generics = try collectGenerics(e, m);
                const mret = try mapReturnType(e, m);
                const mparams = try mapParams(e, mparams_node);
                var receiver: items.Receiver = .ref_;
                var params = mparams;
                if (mparams.len > 0 and std.mem.eql(u8, mparams[0].name, "self")) {
                    if (mparams[0].ty == .reference) {
                        receiver = if (mparams[0].ty.reference.*.mut) .mut_ref else .ref_;
                    } else {
                        receiver = .owned;
                    }
                    params = mparams[1..];
                }
                try methods.append(e.alloc, .{
                    .name = try e.alloc.dupe(u8, mname),
                    .params = params,
                    .ret = mret,
                    .generic_params = method_generic_params,
                    .generics = method_generics,
                    .receiver = receiver,
                });
            } else if (std.mem.eql(u8, m.kind(), "type_item") or
                std.mem.eql(u8, m.kind(), "associated_type"))
            {
                try assoc_types.append(e.alloc, try traitAssocType(e, m));
            } else if (std.mem.eql(u8, m.kind(), "const_item")) {
                try assoc_consts.append(e.alloc, try traitAssocConst(e, m));
            }
        }
    }
    const trait_name: []const u8 = try e.alloc.dupe(u8, name);
    const trait_methods: []const bodies.TraitMethodSig = try methods.toOwnedSlice(e.alloc);
    const trait_assoc_types: []const items.AssocType = try assoc_types.toOwnedSlice(e.alloc);
    const trait_assoc_consts: []const bodies.TraitAssocConst = try assoc_consts.toOwnedSlice(e.alloc);
    const trait_supertraits = try supertraits.toOwnedSlice(e.alloc);
    e.bodies_list.items[eid] = .{ .trait_ = .{
        .name = trait_name,
        .generic_params = trait_generic_params,
        .generics = trait_generics,
        .supertraits = trait_supertraits,
        .methods = trait_methods,
        .assoc_types = trait_assoc_types,
        .assoc_consts = trait_assoc_consts,
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
            std.mem.eql(u8, k, "unit_type") or
            std.mem.eql(u8, k, "abstract_type") or
            std.mem.eql(u8, k, "dynamic_type") or
            std.mem.eql(u8, k, "bounded_type"))
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
fn setConstExprType(e: *Ctx, id: exprs.NodeId, ty: types.Type) !void {
    const type_id = try appendType(e, ty);
    e.exprs_list.items[id].ty = type_id;
}

fn constExprType(e: *const Ctx, id: exprs.NodeId) ?types.Type {
    if (id >= e.exprs_list.items.len) return null;
    const type_id = e.exprs_list.items[id].ty orelse return null;
    if (type_id >= e.types_list.items.len) return null;
    return e.types_list.items[type_id];
}

fn nominalDefFromType(ty: types.Type) ?spine.EntityId {
    return switch (ty) {
        .path => |path| if (path.segments.len == 0)
            null
        else
            path.segments[path.segments.len - 1].id,
        .reference => |reference| nominalDefFromType(reference.pointee),
        .raw_ptr => |raw_ptr| nominalDefFromType(raw_ptr.pointee),
        else => null,
    };
}

fn constEntityByName(e: *const Ctx, name: []const u8) ?spine.EntityId {
    const owner = e.declaration_owner orelse return null;
    const module_id = owningModule(e.g, owner) orelse return null;
    for (e.g.symbol_table.entities.items) |entity| {
        if (entity.kind != .const_ or entity.parent != module_id) continue;
        if (std.mem.eql(u8, entity.name, name)) return entity.id;
    }
    return null;
}

fn constBodyType(e: *const Ctx, id: spine.EntityId) ?types.Type {
    if (id >= e.bodies_list.items.len) return null;
    return switch (e.bodies_list.items[id]) {
        .const_ => |body| body.ty,
        else => null,
    };
}
fn bindConstTypeForOwner(
    e: *Ctx,
    owner: spine.EntityId,
    extra_generic_params: []const []const u8,
    ty: *types.Type,
) ConstLowerError!void {
    const pending = if (e.pending_generics) |applications|
        applications.items
    else
        &[_]PendingGenericApplication{};
    bindType(
        e.g,
        e.bodies_list.items,
        owner,
        extra_generic_params,
        pending,
        ty,
    ) catch return error.UnsupportedConstInitializer;
}

fn bindConstType(e: *Ctx, ty: *types.Type) ConstLowerError!void {
    const owner = e.declaration_owner orelse return error.UnsupportedConstInitializer;
    try bindConstTypeForOwner(e, owner, &.{}, ty);
}

fn constMethodEntity(
    e: *const Ctx,
    target: spine.EntityId,
    name: []const u8,
) ?spine.EntityId {
    for (e.g.symbol_table.entities.items) |entity| {
        if (entity.kind != .fn_ or !std.mem.eql(u8, entity.name, name)) continue;
        const impl_id = entity.parent orelse continue;
        const impl = e.g.symbol_table.get(impl_id) orelse continue;
        if (impl.kind != .impl_ or impl.parent != target) continue;
        // Trait methods are not inherent const methods.
        if (std.mem.indexOf(u8, impl.name, " for ") != null) continue;
        return entity.id;
    }
    return null;
}

fn constMethodReceiver(
    e: *const Ctx,
    target: spine.EntityId,
    method_name: []const u8,
) exprs.ReceiverMode {
    if (target >= e.bodies_list.items.len) return .value;
    const body = switch (e.bodies_list.items[target]) {
        .struct_ => |value| value,
        else => return .value,
    };
    for (body.methods) |method| {
        if (!std.mem.eql(u8, method.name, method_name)) continue;
        return switch (method.receiver orelse .owned) {
            .owned => .value,
            .ref_ => .shared,
            .mut_ref => .mutable,
        };
    }
    return .value;
}

fn isConstFunction(e: *const Ctx, id: spine.EntityId) bool {
    const origins = e.function_origins orelse return false;
    const origin = origins.get(id) orelse return false;
    const fn_index = std.mem.indexOf(u8, origin.source, "fn") orelse return false;
    const prefix = origin.source[0..fn_index];
    return std.mem.indexOf(u8, prefix, "const") != null;
}

const ConstMethodParts = struct {
    receiver: ts.Node,
    method: ts.Node,
    arguments: ts.Node,
};

fn constMethodParts(_: *const Ctx, node: ts.Node) ?ConstMethodParts {
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "method_call_expression")) {
        return .{
            .receiver = node.childByFieldName("receiver") orelse return null,
            .method = node.childByFieldName("method") orelse return null,
            .arguments = node.childByFieldName("arguments") orelse return null,
        };
    }
    if (!std.mem.eql(u8, kind, "call_expression")) return null;
    const callee = node.namedChild(0) orelse return null;
    if (!std.mem.eql(u8, callee.kind(), "field_expression")) return null;
    const arguments = blk: {
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            if (std.mem.eql(u8, child.kind(), "arguments")) break :blk child;
        }
        break :blk null;
    } orelse return null;
    return .{
        .receiver = callee.namedChild(0) orelse return null,
        .method = callee.namedChild(1) orelse return null,
        .arguments = arguments,
    };
}

fn lowerConstArray(
    e: *Ctx,
    node: ts.Node,
    expected: ?types.Type,
    depth: usize,
) ConstLowerError!exprs.NodeId {
    const elem_type = if (expected) |ty| arrayElemTy(ty) else null;
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
        const elem_id = try lowerConstInit(e, en, elem_type, depth + 1);
        if (!std.mem.eql(u8, len_node.kind(), "integer_literal")) return error.InvalidConstArray;
        const parsed_len = parseConstIntText(text(e, len_node)) orelse
            return error.InvalidConstArray;
        if (parsed_len.value < 0) return error.InvalidConstArray;
        const len = std.math.cast(usize, parsed_len.value) orelse
            return error.InvalidConstArray;
        var elems: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
        defer elems.deinit(e.alloc);
        try elems.append(e.alloc, elem_id);
        const elements: []const exprs.NodeId = try elems.toOwnedSlice(e.alloc);
        errdefer e.alloc.free(elements);
        const id: exprs.NodeId = try appendExpr(e, .{ .array = .{
            .elements = elements,
            .repeat = len,
        } });
        if (elem_type) |ty| try setConstExprType(e, id, ty);
        return id;
    }

    var elements: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
    defer elements.deinit(e.alloc);
    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        if (isComment(c)) continue;
        try elements.append(e.alloc, try lowerConstInit(e, c, elem_type, depth + 1));
    }
    const owned_elements: []const exprs.NodeId = try elements.toOwnedSlice(e.alloc);
    errdefer e.alloc.free(owned_elements);
    const id: exprs.NodeId = try appendExpr(e, .{ .array = .{
        .elements = owned_elements,
        .repeat = null,
    } });
    if (elem_type) |ty| try setConstExprType(e, id, ty);
    return id;
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
    const untrimmed_digits = if (base != 10) body[2..] else body;
    const digits = std.mem.trimEnd(u8, untrimmed_digits, "_");
    if (digits.len == 0) return null;
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
        std.mem.eql(u8, kind, "unit_type") or
        std.mem.eql(u8, kind, "abstract_type") or
        std.mem.eql(u8, kind, "dynamic_type") or
        std.mem.eql(u8, kind, "bounded_type");
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

fn integerTargetForPrimitive(
    e: *const Ctx,
    primitive: types.Prim,
) ?IntegerCastTarget {
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
        if (std.mem.eql(u8, op, "!")) {
            if (parseConstIntText(text(e, operand))) |parsed| {
                if (mapPrim(parsed.suffix)) |primitive| {
                    if (integerTargetForPrimitive(e, primitive)) |target| {
                        return checkedIntegerCastValue(~value, target);
                    }
                }
            }
            return ~value;
        }
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

fn lowerConstIntegerValue(
    e: *Ctx,
    value: i128,
    expected: ?types.Type,
) ConstLowerError!exprs.NodeId {
    const number = try std.fmt.allocPrint(e.alloc, "{d}", .{value});
    errdefer e.alloc.free(number);
    const id = try appendExpr(e, .{ .literal = .{ .int = .{
        .text = number,
        .value = value,
        .base = .dec,
        .ty_suffix = null,
    } } });
    if (expected) |ty| try setConstExprType(e, id, ty);
    return id;
}

fn lowerConstPath(
    e: *Ctx,
    node: ts.Node,
    expected: ?types.Type,
) ConstLowerError!exprs.NodeId {
    const raw_name = std.mem.trim(u8, text(e, node), " \t\r\n:");
    // A leaf-only lookup cannot resolve `module::CONST` safely. Reject scoped
    // constants until this path is lowered through canonical module IDs.
    if (std.mem.indexOf(u8, raw_name, "::") != null) {
        return error.UnsupportedConstInitializer;
    }
    const def = constEntityByName(e, raw_name) orelse
        return error.UnsupportedConstInitializer;
    const ty = constBodyType(e, def) orelse return error.UnsupportedConstInitializer;
    const id = try appendExpr(e, .{ .path = .{
        .def = def,
        .generic_args = &.{},
    } });
    try setConstExprType(e, id, expected orelse ty);
    return id;
}

fn lowerConstStruct(
    e: *Ctx,
    node: ts.Node,
    expected: ?types.Type,
    depth: usize,
) ConstLowerError!exprs.NodeId {
    var name_node: ?ts.Node = null;
    var fields_node: ?ts.Node = null;
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), "field_initializer_list")) {
            fields_node = child;
        } else if (name_node == null and !isComment(child)) {
            name_node = child;
        }
    }
    const type_name = name_node orelse return error.UnsupportedConstInitializer;
    var mapped = mapNamedType(e, type_name) catch
        return error.UnsupportedConstInitializer;
    try bindConstType(e, &mapped);
    const def = nominalDefFromType(mapped) orelse
        return error.UnsupportedConstInitializer;
    if (def >= e.bodies_list.items.len) return error.UnsupportedConstInitializer;
    const struct_body = switch (e.bodies_list.items[def]) {
        .struct_ => |body| body,
        else => return error.UnsupportedConstInitializer,
    };

    var fields: std.ArrayListUnmanaged(exprs.FieldInit) = .empty;
    defer fields.deinit(e.alloc);
    if (fields_node) |list| {
        var j: u32 = 0;
        while (list.namedChild(j)) |field_node| : (j += 1) {
            const field_kind = field_node.kind();
            if (std.mem.eql(u8, field_kind, "base_field_initializer")) {
                return error.UnsupportedConstInitializer;
            }
            var field_name: []const u8 = "";
            var value_node: ?ts.Node = null;
            if (std.mem.eql(u8, field_kind, "shorthand_field_initializer")) {
                field_name = text(e, field_node);
            } else if (std.mem.eql(u8, field_kind, "field_initializer")) {
                var k: u32 = 0;
                while (field_node.namedChild(k)) |child| : (k += 1) {
                    const child_kind = child.kind();
                    if (std.mem.eql(u8, child_kind, "field_identifier") or
                        std.mem.eql(u8, child_kind, "identifier"))
                    {
                        if (field_name.len == 0) {
                            field_name = text(e, child);
                        } else {
                            value_node = child;
                        }
                    } else if (!isComment(child) and value_node == null) {
                        value_node = child;
                    }
                }
            } else {
                continue;
            }
            if (field_name.len == 0) return error.UnsupportedConstInitializer;
            var field_type: ?types.Type = null;
            for (struct_body.fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    field_type = field.ty;
                    break;
                }
            }
            var field_ty = field_type orelse return error.UnsupportedConstInitializer;
            try bindConstTypeForOwner(e, def, struct_body.generic_params, &field_ty);
            const value_id = if (value_node) |value|
                try lowerConstInit(e, value, field_ty, depth + 1)
            else blk: {
                const path_def = constEntityByName(e, field_name) orelse
                    return error.UnsupportedConstInitializer;
                const path_ty = constBodyType(e, path_def) orelse
                    return error.UnsupportedConstInitializer;
                const path_id = try appendExpr(e, .{ .path = .{
                    .def = path_def,
                    .generic_args = &.{},
                } });
                try setConstExprType(e, path_id, path_ty);
                break :blk path_id;
            };
            try fields.append(e.alloc, .{
                .field = try e.alloc.dupe(u8, field_name),
                .value = value_id,
                .shorthand = value_node == null,
            });
        }
    }
    const owned_fields = try fields.toOwnedSlice(e.alloc);
    errdefer e.alloc.free(owned_fields);
    const id = try appendExpr(e, .{ .struct_lit = .{
        .def = def,
        .fields = owned_fields,
        .base = null,
    } });
    try setConstExprType(e, id, expected orelse mapped);
    return id;
}

fn lowerConstMethodCall(
    e: *Ctx,
    node: ts.Node,
    expected: ?types.Type,
    depth: usize,
) ConstLowerError!exprs.NodeId {
    if (depth >= max_const_eval_depth) return error.UnsupportedConstInitializer;
    const parts = constMethodParts(e, node) orelse
        return error.UnsupportedConstInitializer;
    const method_name = text(e, parts.method);
    if (method_name.len == 0) return error.UnsupportedConstInitializer;
    const receiver_id = try lowerConstInit(e, parts.receiver, null, depth + 1);
    const receiver_ty = constExprType(e, receiver_id) orelse
        return error.UnsupportedConstInitializer;
    const target = nominalDefFromType(receiver_ty) orelse
        return error.UnsupportedConstInitializer;
    const method_id = constMethodEntity(e, target, method_name) orelse
        return error.UnsupportedConstInitializer;
    if (!isConstFunction(e, method_id)) return error.UnsupportedConstInitializer;
    const method_body = switch (e.bodies_list.items[method_id]) {
        .fn_ => |body| body,
        else => return error.UnsupportedConstInitializer,
    };
    var method_ret = method_body.ret;
    try bindConstTypeForOwner(e, method_id, &.{}, &method_ret);
    const params = if (method_body.params.len > 0 and
        std.mem.eql(u8, method_body.params[0].name, "self"))
        method_body.params[1..]
    else
        method_body.params;
    var args: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
    defer args.deinit(e.alloc);
    var arg_index: usize = 0;
    var i: u32 = 0;
    while (parts.arguments.namedChild(i)) |arg| : (i += 1) {
        if (arg_index >= params.len) return error.UnsupportedConstInitializer;
        try args.append(
            e.alloc,
            try lowerConstInit(e, arg, params[arg_index].ty, depth + 1),
        );
        arg_index += 1;
    }
    if (arg_index != params.len) return error.UnsupportedConstInitializer;
    const owned_args = try args.toOwnedSlice(e.alloc);
    errdefer e.alloc.free(owned_args);
    const id = try appendExpr(e, .{ .method_call = .{
        .receiver = receiver_id,
        .receiver_mode = constMethodReceiver(e, target, method_name),
        .method = method_id,
        .args = owned_args,
    } });
    try setConstExprType(e, id, expected orelse method_ret);
    return id;
}

/// Lower a const initializer expression into the expr table.
fn lowerConstInit(
    e: *Ctx,
    node: ts.Node,
    expected: ?types.Type,
    depth: usize,
) ConstLowerError!exprs.NodeId {
    if (depth >= max_const_eval_depth) return error.UnsupportedConstInitializer;
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "type_cast_expression")) {
        const value = try constIntegerCastValueAt(e, node, 0);
        return lowerConstIntegerValue(
            e,
            value orelse return error.UnsupportedConstInitializer,
            expected,
        );
    }
    if (std.mem.eql(u8, kind, "expression") or
        std.mem.eql(u8, kind, "parenthesized_expression") or
        std.mem.eql(u8, kind, "unsafe_expression"))
    {
        if (node.namedChildCount() > 0) {
            return lowerConstInit(e, node.namedChild(0).?, expected, depth + 1);
        }
        return error.UnsupportedConstInitializer;
    }
    if (std.mem.eql(u8, kind, "reference_expression")) {
        const operand = node.namedChild(0) orelse return error.UnsupportedConstInitializer;
        const operand_expected = if (expected) |ty| switch (ty) {
            .reference => |reference| reference.pointee,
            else => null,
        } else null;
        const operand_id = try lowerConstInit(e, operand, operand_expected, depth + 1);
        const mode: exprs.ReceiverMode = if (std.mem.startsWith(u8, text(e, node), "&mut"))
            .mutable
        else
            .shared;
        const id = try appendExpr(e, .{ .unary = .{
            .op = .{ .ref = mode },
            .operand = operand_id,
        } });
        if (expected) |ty| try setConstExprType(e, id, ty);
        return id;
    }
    if (std.mem.eql(u8, kind, "array_expression")) {
        return lowerConstArray(e, node, expected, depth);
    }
    if (std.mem.eql(u8, kind, "struct_expression")) {
        return lowerConstStruct(e, node, expected, depth);
    }
    if (constMethodParts(e, node) != null) {
        return lowerConstMethodCall(e, node, expected, depth);
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
        const id = try appendExpr(e, .{ .literal = .{ .int = .{
            .text = text_copy,
            .value = parsed.value,
            .base = if (parsed.base == 16) .hex else if (parsed.base == 2) .bin else if (parsed.base == 8) .oct else .dec,
            .ty_suffix = suffix,
        } } });
        if (expected) |ty| try setConstExprType(e, id, ty);
        return id;
    }
    if (std.mem.eql(u8, kind, "identifier") or
        std.mem.eql(u8, kind, "type_identifier") or
        std.mem.eql(u8, kind, "scoped_identifier"))
    {
        if (constIntegerValue(e, node)) |value| {
            return lowerConstIntegerValue(e, value, expected);
        }
        return lowerConstPath(e, node, expected);
    }
    if (std.mem.eql(u8, kind, "call_expression") or
        std.mem.eql(u8, kind, "binary_expression") or
        std.mem.eql(u8, kind, "unary_expression"))
    {
        const value = constIntegerValue(e, node) orelse
            return error.UnsupportedConstInitializer;
        return lowerConstIntegerValue(e, value, expected);
    }
    if (std.mem.eql(u8, kind, "float_literal")) {
        const t = text(e, node);
        const text_copy = try e.alloc.dupe(u8, t);
        errdefer e.alloc.free(text_copy);
        const value = std.fmt.parseFloat(f64, t) catch return error.InvalidLiteral;
        const id = try appendExpr(e, .{ .literal = .{ .float = .{
            .text = text_copy,
            .value = value,
        } } });
        if (expected) |ty| try setConstExprType(e, id, ty);
        return id;
    }
    if (std.mem.eql(u8, kind, "byte_literal") or std.mem.eql(u8, kind, "char_literal")) {
        const t = text(e, node);
        if (try decodeRustByteLiteral(e.alloc, t)) |bytes| {
            defer e.alloc.free(bytes);
            if (bytes.len != 1) return error.InvalidLiteral;
            const number = try std.fmt.allocPrint(e.alloc, "{d}", .{bytes[0]});
            errdefer e.alloc.free(number);
            const suffix = try e.alloc.dupe(u8, "u8");
            errdefer e.alloc.free(suffix);
            const id = try appendExpr(e, .{ .literal = .{ .int = .{
                .text = number,
                .value = bytes[0],
                .base = .dec,
                .ty_suffix = suffix,
            } } });
            if (expected) |ty| try setConstExprType(e, id, ty);
            return id;
        }
        if (std.mem.eql(u8, kind, "byte_literal") or std.mem.startsWith(u8, t, "b")) {
            return error.InvalidLiteral;
        }
        if (t.len < 3 or t[0] != '\'' or t[t.len - 1] != '\'') {
            return error.InvalidLiteral;
        }
        const text_copy = try e.alloc.dupe(u8, t);
        errdefer e.alloc.free(text_copy);
        const id = try appendExpr(e, .{ .literal = .{ .character = .{
            .text = text_copy,
            .value = t[1],
        } } });
        if (expected) |ty| try setConstExprType(e, id, ty);
        return id;
    }
    if (std.mem.eql(u8, kind, "boolean_literal")) {
        const value = text(e, node);
        if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) {
            return error.InvalidLiteral;
        }
        const id = try appendExpr(e, .{ .literal = .{
            .boolean = std.mem.eql(u8, value, "true"),
        } });
        if (expected) |ty| try setConstExprType(e, id, ty);
        return id;
    }
    if (std.mem.eql(u8, kind, "string_literal") or
        std.mem.eql(u8, kind, "byte_string_literal") or
        std.mem.eql(u8, kind, "raw_string_literal"))
    {
        const id = try lowerConstString(e, node);
        if (expected) |ty| try setConstExprType(e, id, ty);
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
            std.mem.eql(u8, k, "unit_type") or
            std.mem.eql(u8, k, "abstract_type") or
            std.mem.eql(u8, k, "dynamic_type") or
            std.mem.eql(u8, k, "bounded_type"))
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
    var const_ty = try mapType(e, type_node orelse return error.MalformedConstType);
    try bindConstType(e, &const_ty);
    const init_id = try lowerConstInit(e, initializer, const_ty, 0);
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
        const fn_src = if (e.macro_table) |table|
            try exp.expandSourceMacros(e.alloc, table, text(e, item), .{
                .features = e.cfg.features,
                .target_pointer_width = e.cfg.target_pointer_width,
                .docsrs = e.cfg.docsrs,
                .include_tests = e.include_tests,
            })
        else
            try e.alloc.dupe(u8, text(e, item));
        errdefer e.alloc.free(fn_src);
        try origins.put(e.alloc, eid, .{
            .lexical_module = lexical_mod,
            .source = fn_src,
        });
    }
    e.declaration_owner = eid;
    const generics = try collectGenerics(e, item);
    const params = try mapParams(e, params_node);
    const ret = try mapReturnType(e, item);
    e.bodies_list.items[eid] = .{ .fn_ = .{
        .params = params,
        .ret = ret,
        .generic_params = generic_params,
        .generics = generics,
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
    if (!isKnownExternalCrate(e.g, first)) return null;
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
fn isNonEntityImplTarget(self_ty: types.Type, generics: ?types.Generics) bool {
    return switch (self_ty) {
        .prim,
        .reference,
        .raw_ptr,
        .slice,
        .array,
        .tuple,
        .fn_ptr,
        .external_nominal,
        .option,
        .result,
        .boxed,
        .@"opaque",
        .dyn_trait,
        => true,
        .path => |path| blk: {
            if (path.segments.len != 1 or path.segments[0].id != null) break :blk false;
            const generic_parameters = generics orelse break :blk false;
            for (generic_parameters.params) |parameter| {
                const name = switch (parameter) {
                    .type_ => |type_parameter| type_parameter.name,
                    else => continue,
                };
                if (std.mem.eql(u8, name, path.segments[0].name)) break :blk true;
            }
            break :blk false;
        },
        .generic_inst, .unsupported => false,
    };
}

fn implItem(
    e: *Ctx,
    item: ts.Node,
    mod_id: spine.EntityId,
    item_ids: *std.ArrayListUnmanaged(spine.EntityId),
) !void {
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
        if (std.mem.eql(u8, k, "where_clause") or
            std.mem.eql(u8, k, "type_parameters") or
            std.mem.eql(u8, k, "generic_parameters"))
        {
            continue;
        }
        if (std.mem.eql(u8, k, "type_identifier") or
            std.mem.eql(u8, k, "generic_type") or
            std.mem.eql(u8, k, "primitive_type") or
            std.mem.eql(u8, k, "scoped_type_identifier") or
            std.mem.eql(u8, k, "type_path") or
            std.mem.eql(u8, k, "array_type") or
            std.mem.eql(u8, k, "slice_type") or
            std.mem.eql(u8, k, "reference_type") or
            std.mem.eql(u8, k, "pointer_type") or
            std.mem.eql(u8, k, "tuple_type") or
            std.mem.eql(u8, k, "unit_type") or
            std.mem.eql(u8, k, "abstract_type") or
            std.mem.eql(u8, k, "dynamic_type") or
            std.mem.eql(u8, k, "bounded_type"))
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

    const target_id = implTargetEntity(e, mod_id, target_path);
    const force_pending_target = std.mem.eql(u8, target_path, "super") or
        std.mem.startsWith(u8, target_path, "super::");

    const name = if (trait_name) |tr|
        try std.fmt.allocPrint(e.alloc, "{s} for {s}", .{ tr, self_ty_name })
    else
        try e.alloc.dupe(u8, self_ty_name);
    // Associated declarations always retain the impl entity as their parent.
    const impl_id = try addEntity(
        e,
        .impl_,
        name,
        if (force_pending_target) mod_id else target_id orelse mod_id,
        item,
    );
    e.declaration_owner = impl_id;
    const self_type_node = item.childByFieldName("type") orelse return error.MalformedImpl;
    const impl_self_ty = try mapType(e, self_type_node);
    const impl_generics = try collectGenerics(e, item);
    const non_entity_target = isNonEntityImplTarget(impl_self_ty, impl_generics);
    const pending_target = (target_id == null and !non_entity_target) or force_pending_target;
    if (pending_target and e.pending_impls == null) return error.UnresolvedImplTarget;
    const direct_target_id: ?spine.EntityId = if (pending_target) null else target_id;

    var impl_trait_path: ?types.Path = null;
    var impl_trait_args: []const types.Type = &.{};
    var impl_trait_assoc: []const types.AssociatedTypeBinding = &.{};
    if (item.childByFieldName("trait")) |trait_node| {
        if (try parseTraitBound(e, trait_node)) |tb| {
            impl_trait_path = tb.path;
            impl_trait_args = tb.args;
            impl_trait_assoc = tb.associated_types;
        } else {
            const mapped_trait = try mapType(e, trait_node);
            impl_trait_path = boundPathFromType(e, mapped_trait);
            if (impl_trait_path == null) {
                impl_trait_path = .{ .segments = try mapScopedSegments(e, trait_node) };
            }
            if (impl_trait_path) |*tp| {
                if (tp.segments.len == 1) {
                    if (preludePathSegments(e.alloc, tp.segments[0].name) catch null) |prelude_segs| {
                        tp.segments = prelude_segs;
                    }
                }
            }
        }
    }
    // Publish the impl receiver before lowering associated constants. Their
    // initializer types can contain `Self`, which must see the concrete
    // receiver while constItem appends expression type entries.
    e.bodies_list.items[impl_id] = .{ .impl_ = .{
        .self_ty = impl_self_ty,
        .trait_path = impl_trait_path,
        .trait_args = impl_trait_args,
        .trait_associated_types = impl_trait_assoc,
        .generics = impl_generics,
        .assoc_items = &.{},
    } };
    var assoc_ids: std.ArrayListUnmanaged(spine.EntityId) = .empty;
    errdefer assoc_ids.deinit(e.alloc);
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
                try assoc_ids.append(e.alloc, @intCast(e.bodies_list.items.len - 1));

                if (direct_target_id) |tid| {
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
                                if (receiver == null and all_params.len > 0 and
                                    std.mem.eql(u8, all_params[0].name, "self"))
                                {
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
                                if (receiver != null and all_params.len > 0 and
                                    std.mem.eql(u8, all_params[0].name, "self"))
                                {
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
                                        .generics = try collectGenerics(e, child),
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
                if (pending_target) {
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
                try assoc_ids.append(e.alloc, @intCast(e.bodies_list.items.len - 1));
            } else if (std.mem.eql(u8, child.kind(), "type_item") or
                std.mem.eql(u8, child.kind(), "associated_type"))
            {
                try typeAliasItem(e, child, impl_id);
                try assoc_ids.append(e.alloc, @intCast(e.bodies_list.items.len - 1));
            }
        }
    }
    const assoc_items: []const spine.EntityId = try assoc_ids.toOwnedSlice(e.alloc);
    e.bodies_list.items[impl_id] = .{ .impl_ = .{
        .self_ty = impl_self_ty,
        .trait_path = impl_trait_path,
        .trait_args = impl_trait_args,
        .trait_associated_types = impl_trait_assoc,
        .generics = impl_generics,
        .assoc_items = assoc_items,
    } };
    if (pending_target) {
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
        if (target_id == null) try item_ids.append(e.alloc, impl_id);
    }
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
                        .generics = function_body.generics,
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

fn cfgBuiltinRequiresTarget(name: []const u8) bool {
    return std.mem.eql(u8, name, "unix") or
        std.mem.eql(u8, name, "windows") or
        std.mem.eql(u8, name, "target_os") or
        std.mem.eql(u8, name, "target_arch") or
        std.mem.eql(u8, name, "target_env") or
        std.mem.eql(u8, name, "target_family") or
        std.mem.eql(u8, name, "target_vendor") or
        std.mem.eql(u8, name, "debug_assertions") or
        std.mem.eql(u8, name, "panic") or
        std.mem.eql(u8, name, "proc_macro") or
        std.mem.eql(u8, name, "miri") or
        std.mem.eql(u8, name, "sanitize");
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
        const configured_width = e.cfg.target_pointer_width orelse @as(u16, @bitSizeOf(usize));
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
    if (!is_all and !is_any) {
        if (cfgBuiltinRequiresTarget(name)) return error.UnsupportedCfgPredicate;
        cfgSkipWhitespace(input, index);
        if (index.* < input.len and
            (input[index.*] == '=' or input[index.*] == '('))
        {
            return error.UnsupportedCfgPredicate;
        }
        return false;
    }

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

fn setUnsupportedMacro(
    e: *Ctx,
    name: []const u8,
    reason: UnsupportedMacroReason,
    artifact_path: ?[]const u8,
) !void {
    e.unsupported_macro = .{
        .name = try e.alloc.dupe(u8, name),
        .reason = reason,
        .artifact_path = if (artifact_path) |path| try e.alloc.dupe(u8, path) else null,
    };
}

fn macroBaseName(path: []const u8) []const u8 {
    var name = std.mem.trim(u8, path, " \t\r\n");
    if (std.mem.lastIndexOf(u8, name, "::")) |separator| {
        name = name[separator + 2 ..];
    }
    if (std.mem.endsWith(u8, name, "!")) name = name[0 .. name.len - 1];
    return std.mem.trim(u8, name, " \t\r\n");
}

fn lastStringLiteral(raw: []const u8) ?[]const u8 {
    const end = std.mem.lastIndexOfScalar(u8, raw, '"') orelse return null;
    if (end == 0) return null;
    const start = std.mem.lastIndexOfScalar(u8, raw[0..end], '"') orelse return null;
    return raw[start + 1 .. end];
}

fn artifactIncludePath(
    e: *const Ctx,
    token_tree: ts.Node,
) ?[]const u8 {
    const raw = text(e, token_tree);
    const has_out_dir = std.mem.indexOf(u8, raw, "OUT_DIR") != null;
    const has_concat = std.mem.indexOf(u8, raw, "concat!") != null;
    const literal = lastStringLiteral(raw);
    if (has_out_dir or has_concat) {
        const path = literal orelse return "generated artifact";
        const trimmed = std.mem.trim(u8, path, " \t\r\n/");
        if (trimmed.len == 0) return "generated artifact";
        return std.fs.path.basename(trimmed);
    }
    if (literal) |path| {
        const trimmed = std.mem.trim(u8, path, " \t\r\n/");
        if (trimmed.len == 0) return "generated artifact";
        return std.fs.path.basename(trimmed);
    }
    return null;
}

fn validateGeneratedItems(node: ts.Node) !void {
    var i: u32 = 0;
    while (node.namedChild(i)) |item| : (i += 1) {
        var item2 = item;
        if (std.mem.eql(u8, item.kind(), "expression_statement")) {
            item2 = item.namedChild(0) orelse return error.ParseFailed;
        }
        const kind = item2.kind();
        if (std.mem.eql(u8, kind, "static_item") or
            std.mem.eql(u8, kind, "foreign_mod_item"))
        {
            return error.UnsupportedItem;
        }
        if (std.mem.eql(u8, kind, "mod_item")) {
            if (item2.childByFieldName("body")) |body| {
                try validateGeneratedItems(body);
            }
        }
    }
}

const MacroExpansionCheckpoint = struct {
    entity_count: usize,
    module_count: usize,
    use_count: usize,
    body_count: usize,
    type_count: usize,
    expression_count: usize,
    item_count: usize,
    pending_impl_count: usize,
    pending_generic_count: usize,
    function_origin_count: usize,
};

fn rollbackMacroExpansion(
    e: *Ctx,
    item_ids: *std.ArrayListUnmanaged(spine.EntityId),
    checkpoint: MacroExpansionCheckpoint,
) void {
    e.g.symbol_table.entities.items.len = checkpoint.entity_count;
    e.g.modules.items.len = checkpoint.module_count;
    e.g.uses.items.len = checkpoint.use_count;
    e.bodies_list.items.len = checkpoint.body_count;
    e.types_list.items.len = checkpoint.type_count;
    e.exprs_list.items.len = checkpoint.expression_count;
    item_ids.items.len = checkpoint.item_count;
    if (e.pending_impls) |pending| {
        while (pending.items.len > checkpoint.pending_impl_count) {
            const impl = pending.pop().?;
            e.alloc.free(impl.target_path);
            e.alloc.free(impl.methods);
        }
    }
    if (e.pending_generics) |pending| {
        while (pending.items.len > checkpoint.pending_generic_count) {
            const application = pending.pop().?;
            freePendingGenericPath(e.alloc, application.path);
        }
    }
    if (e.function_origins) |origins| {
        var stale_ids: std.ArrayListUnmanaged(spine.EntityId) = .empty;
        defer stale_ids.deinit(e.alloc);
        var iterator = origins.iterator();
        while (iterator.next()) |entry| {
            if (@as(usize, entry.key_ptr.*) >= checkpoint.entity_count) {
                stale_ids.append(e.alloc, entry.key_ptr.*) catch return;
            }
        }
        for (stale_ids.items) |id| {
            if (origins.fetchRemove(id)) |entry| e.alloc.free(entry.value.source);
        }
    }
    _ = checkpoint.module_count;
    _ = checkpoint.use_count;
    _ = checkpoint.function_origin_count;
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
    const def = table.get(path_text) orelse {
        const macro_name = macroBaseName(path_text);
        if (std.mem.eql(u8, macro_name, "include")) {
            const artifact_path = artifactIncludePath(e, tt);
            try setUnsupportedMacro(
                e,
                macro_name,
                if (artifact_path != null)
                    .build_script_not_executed
                else
                    .source_unavailable,
                artifact_path,
            );
            return error.BuildScriptArtifactUnavailable;
        }
        if (exp.identifyMacro(path_text) != .custom) return error.UnknownMacro;
        try setUnsupportedMacro(
            e,
            macro_name,
            .dependency_source_unavailable,
            null,
        );
        return error.ExternalMacroSourceUnavailable;
    };
    const expanded = try exp.expandMacroRules(e.alloc, def, text(e, tt));
    const initial_macro_count = table.macros.count();
    defer e.alloc.free(expanded);

    // Re-parse the expanded source and ingest any generated top-level items.
    var parser = ts.Parser.create();
    defer parser.destroy();
    const tree = try parseRustTree(parser, expanded);
    defer tree.destroy();
    if (tree.rootNode().hasError()) return error.ParseFailed;
    try validateGeneratedItems(tree.rootNode());
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
    const checkpoint: MacroExpansionCheckpoint = .{
        .entity_count = e.g.symbol_table.entities.items.len,
        .module_count = e.g.modules.items.len,
        .use_count = e.g.uses.items.len,
        .body_count = e.bodies_list.items.len,
        .type_count = e.types_list.items.len,
        .expression_count = e.exprs_list.items.len,
        .item_count = item_ids.items.len,
        .pending_impl_count = if (e.pending_impls) |pending| pending.items.len else 0,
        .pending_generic_count = if (e.pending_generics) |pending| pending.items.len else 0,
        .function_origin_count = if (e.function_origins) |origins| origins.count() else 0,
    };
    errdefer rollbackMacroExpansion(e, item_ids, checkpoint);
    const generated = mapItemsInner(&exp_ctx, tree.rootNode(), mod_id) catch |err| {
        if (exp_ctx.unsupported_macro) |diagnostic| e.unsupported_macro = diagnostic;
        return err;
    };
    defer e.alloc.free(generated);
    if (e.g.symbol_table.entities.items.len == checkpoint.entity_count and
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
            var child_macros = if (e.macro_table) |parent_macros|
                exp.MacroTable.initChild(parent_macros)
            else
                exp.MacroTable.init(e.alloc);
            defer child_macros.deinit();
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
                var sub_ctx = e.*;
                sub_ctx.macro_table = &child_macros;
                defer e.unsupported_macro = sub_ctx.unsupported_macro;
                const child_items = try mapItemsInner(&sub_ctx, dl, child_id);
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
                    .macro_table = &child_macros,
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
            try implItem(e, item2, mod_id, &item_ids);
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
    clearUnsupportedMacro(ctx);
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
    try bindDeclarationTypes(ctx.g, ctx.bodies_list, ctx.pending_generics.?.items);
    if (owns_pending) try finalizePendingImpls(ctx, ctx.pending_impls.?);
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
        .literal => |length| try std.testing.expectEqual(@as(u64, 4), length),
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

    const ExpectedKind = enum { byte_string, byte_character };
    const expected = [_]struct {
        name: []const u8,
        bytes: []const u8,
        kind: ExpectedKind,
    }{
        .{ .name = "COOKED", .bytes = "line\n\x00\xff", .kind = .byte_string },
        .{ .name = "EMPTY", .bytes = "", .kind = .byte_string },
        .{ .name = "RAW", .bytes = "raw \\n text", .kind = .byte_string },
        .{ .name = "BYTE", .bytes = "\x41", .kind = .byte_character },
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
        const constant = switch (bodies_list.items[entity_id]) {
            .const_ => |value| value,
            else => return error.TestUnexpectedResult,
        };
        switch (want.kind) {
            .byte_string => {
                const slice = switch (constant.ty) {
                    .slice => |value| value,
                    else => return error.TestUnexpectedResult,
                };
                try std.testing.expect(slice.const_);
                try std.testing.expectEqual(types.Type{ .prim = .u8 }, slice.elem);
            },
            .byte_character => {
                try std.testing.expectEqual(types.Type{ .prim = .u8 }, constant.ty);
            },
        }
        if (constant.init >= exprs_list.items.len) return error.TestUnexpectedResult;
        const initializer = exprs_list.items[constant.init];
        const initializer_type_id = initializer.ty orelse return error.TestUnexpectedResult;
        if (initializer_type_id >= types_list.items.len) return error.TestUnexpectedResult;
        try std.testing.expectEqual(constant.ty, types_list.items[initializer_type_id]);
        const literal = switch (initializer.kind) {
            .literal => |value| value,
            else => return error.TestUnexpectedResult,
        };
        switch (want.kind) {
            .byte_string => switch (literal) {
                .byte_array => |byte_array| {
                    try std.testing.expectEqualSlices(u8, want.bytes, byte_array.items);
                },
                else => return error.TestUnexpectedResult,
            },
            .byte_character => switch (literal) {
                .int => |byte| {
                    try std.testing.expectEqual(@as(usize, 1), want.bytes.len);
                    try std.testing.expectEqual(@as(i128, want.bytes[0]), byte.value);
                    try std.testing.expectEqualStrings(
                        "u8",
                        byte.ty_suffix orelse return error.TestUnexpectedResult,
                    );
                },
                else => return error.TestUnexpectedResult,
            },
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
                .int => |byte| {
                    if (byte.value == 0x42 and
                        std.mem.eql(u8, byte.ty_suffix orelse "", "u8"))
                    {
                        found_body_byte = true;
                    }
                },
                .byte_array => |byte_array| {
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
        .literal => |length| try std.testing.expectEqual(@as(u64, 4), length),
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
        .literal => |length| try std.testing.expectEqual(@as(u64, 4), length),
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

const MacroFailureObservation = struct {
    failure: anyerror,
    diagnostic: ?UnsupportedMacro,
    entity_count: usize,
    module_count: usize,
    module_item_count: usize,
    use_count: usize,
    body_count: usize,
    type_count: usize,
    expression_count: usize,
    function_origin_count: usize,
};

fn deinitMacroFailureObservation(observation: *MacroFailureObservation) void {
    if (observation.diagnostic) |diagnostic| {
        std.testing.allocator.free(diagnostic.name);
        if (diagnostic.artifact_path) |path| std.testing.allocator.free(path);
    }
    observation.* = undefined;
}

fn observeMacroFailure(
    source: []const u8,
    base_dir: ?[]const u8,
) !MacroFailureObservation {
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
        .name = try allocator.dupe(u8, ""),
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
    var function_origins: FunctionOriginTable = .empty;
    defer function_origins.deinit(allocator);
    var ctx: Ctx = .{
        .alloc = allocator,
        .g = &crate_graph,
        .src = source,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
        .base_dir = base_dir,
        .io = if (base_dir != null) std.testing.io else null,
        .function_origins = &function_origins,
    };
    var failure: ?anyerror = null;
    extractFile(&ctx) catch |err| {
        failure = err;
    };
    const diagnostic = if (ctx.unsupported_macro) |source_diagnostic|
        UnsupportedMacro{
            .name = try std.testing.allocator.dupe(u8, source_diagnostic.name),
            .reason = source_diagnostic.reason,
            .artifact_path = if (source_diagnostic.artifact_path) |path|
                try std.testing.allocator.dupe(u8, path)
            else
                null,
        }
    else
        null;
    return .{
        .failure = failure orelse return error.ExpectedMacroFailure,
        .diagnostic = diagnostic,
        .entity_count = crate_graph.symbol_table.entities.items.len,
        .module_count = crate_graph.modules.items.len,
        .module_item_count = crate_graph.modules.items[0].items.len,
        .use_count = crate_graph.uses.items.len,
        .body_count = bodies_list.items.len,
        .type_count = types_list.items.len,
        .expression_count = exprs_list.items.len,
        .function_origin_count = function_origins.count(),
    };
}

test "cst reports unavailable source for external item macro" {
    var result = try observeMacroFailure(
        "#[macro_use]\nextern crate quickcheck;\nquickcheck! { fn property() -> bool { true } }",
        null,
    );
    defer deinitMacroFailureObservation(&result);
    try std.testing.expectEqual(error.ExternalMacroSourceUnavailable, result.failure);
    const diagnostic = result.diagnostic orelse return error.ExpectedMacroDiagnostic;
    try std.testing.expectEqualStrings("quickcheck", diagnostic.name);
    try std.testing.expectEqual(
        UnsupportedMacroReason.dependency_source_unavailable,
        diagnostic.reason,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), diagnostic.artifact_path);
}

test "cst reports build artifacts unavailable without build script execution" {
    var out_dir_result = try observeMacroFailure(
        "include!(concat!(env!(\"OUT_DIR\"), \"/tables.rs\"));",
        "test/crates/crc16/src",
    );
    defer deinitMacroFailureObservation(&out_dir_result);
    try std.testing.expectEqual(error.BuildScriptArtifactUnavailable, out_dir_result.failure);
    const out_dir_diagnostic =
        out_dir_result.diagnostic orelse return error.ExpectedMacroDiagnostic;
    try std.testing.expectEqualStrings("include", out_dir_diagnostic.name);
    try std.testing.expectEqual(
        UnsupportedMacroReason.build_script_not_executed,
        out_dir_diagnostic.reason,
    );
    try std.testing.expectEqualStrings(
        "tables.rs",
        out_dir_diagnostic.artifact_path orelse return error.ExpectedArtifactPath,
    );

    var outside_result = try observeMacroFailure(
        "include!(\"../generated.rs\");",
        "test/crates/crc16/src",
    );
    defer deinitMacroFailureObservation(&outside_result);
    try std.testing.expectEqual(error.BuildScriptArtifactUnavailable, outside_result.failure);
    const outside_diagnostic =
        outside_result.diagnostic orelse return error.ExpectedMacroDiagnostic;
    try std.testing.expectEqualStrings(
        "generated.rs",
        outside_diagnostic.artifact_path orelse return error.ExpectedArtifactPath,
    );
    try std.testing.expectEqual(
        UnsupportedMacroReason.build_script_not_executed,
        outside_diagnostic.reason,
    );
}

test "cst item macro expansion failure is atomic" {
    var result = try observeMacroFailure(
        "macro_rules! partial { () => { fn generated() {} static BAD: u8 = 1; }; } partial!();",
        null,
    );
    defer deinitMacroFailureObservation(&result);
    try std.testing.expectEqual(error.UnsupportedItem, result.failure);
    try std.testing.expectEqual(@as(?UnsupportedMacro, null), result.diagnostic);
    try std.testing.expectEqual(@as(usize, 1), result.entity_count);
    try std.testing.expectEqual(@as(usize, 1), result.module_count);
    try std.testing.expectEqual(@as(usize, 0), result.module_item_count);
    try std.testing.expectEqual(@as(usize, 0), result.use_count);
    try std.testing.expectEqual(@as(usize, 1), result.body_count);
    try std.testing.expectEqual(@as(usize, 0), result.type_count);
    try std.testing.expectEqual(@as(usize, 0), result.expression_count);
    try std.testing.expectEqual(@as(usize, 0), result.function_origin_count);
}
