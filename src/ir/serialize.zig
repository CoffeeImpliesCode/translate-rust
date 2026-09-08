//! translate_rust.ir.serialize — JSON serialization and deserialization
//! for the Rust Semantic IR (RustIr).
//!
//! Provides lossless roundtrip encoding and decoding between in-memory `RustIr`
//! and JSON byte representations.

const std = @import("std");
const spine = @import("spine.zig");
const graph = @import("graph.zig");
const items = @import("items.zig");
const types = @import("types.zig");
const exprs = @import("exprs.zig");
const bodies_mod = @import("bodies.zig");

const Json = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Array = std.json.Array;

pub const wire_format_version: u32 = 5;

pub const Bodies = bodies_mod.Bodies;
pub const BodyKind = bodies_mod.BodyKind;

/// A canonical body entry names its owning graph entity explicitly.
pub const BodySlot = struct {
    owner: spine.EntityId,
    body: BodyKind,
};
pub const ConstBody = bodies_mod.ConstBody;
pub const FnBody = bodies_mod.FnBody;
pub const StructBody = bodies_mod.StructBody;
pub const StructMethod = bodies_mod.StructMethod;
pub const TraitBody = bodies_mod.TraitBody;
pub const EnumBody = bodies_mod.EnumBody;
pub const TraitMethodSig = bodies_mod.TraitMethodSig;
pub const TypeAliasBody = bodies_mod.TypeAliasBody;

// ---------------------------------------------------------------------------
// Decode Helpers
// ---------------------------------------------------------------------------

fn getObj(v: Json) !ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => error.BadWireFormat,
    };
}

fn req(o: ObjectMap, key: []const u8) !Json {
    return o.get(key) orelse error.MissingField;
}

fn checkedU32(value: i128) !u32 {
    if (value < 0 or value > @as(i128, std.math.maxInt(u32))) return error.BadWireFormat;
    return @intCast(value);
}

fn reqU32(o: ObjectMap, key: []const u8) !u32 {
    const v = try req(o, key);
    return switch (v) {
        .integer => |i| try checkedU32(i),
        else => error.BadWireFormat,
    };
}

fn reqBool(o: ObjectMap, key: []const u8) !bool {
    const v = try req(o, key);
    return switch (v) {
        .bool => |b| b,
        else => error.BadWireFormat,
    };
}

fn reqOptBool(o: ObjectMap, key: []const u8) !?bool {
    return switch (try req(o, key)) {
        .bool => |value| value,
        .null => null,
        else => error.BadWireFormat,
    };
}

fn reqStr(o: ObjectMap, key: []const u8) ![]const u8 {
    const v = try req(o, key);
    return switch (v) {
        .string => |s| s,
        else => error.BadWireFormat,
    };
}

fn optU32(o: ObjectMap, key: []const u8) !?u32 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |i| try checkedU32(i),
        .null => null,
        else => error.BadWireFormat,
    };
}

fn reqOptU32(o: ObjectMap, key: []const u8) !?u32 {
    const v = try req(o, key);
    return switch (v) {
        .integer => |i| try checkedU32(i),
        .null => null,
        else => error.BadWireFormat,
    };
}

fn optStr(o: ObjectMap, key: []const u8) !?[]const u8 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        .null => null,
        else => error.BadWireFormat,
    };
}
fn reqOptStr(o: ObjectMap, key: []const u8) !?[]const u8 {
    return switch (try req(o, key)) {
        .string => |s| s,
        .null => null,
        else => error.BadWireFormat,
    };
}

fn reqStrArray(v: Json) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => error.BadWireFormat,
    };
}

fn reqFloat(o: ObjectMap, key: []const u8) !f64 {
    const v = try req(o, key);
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => error.BadWireFormat,
    };
}

fn reqOptionalId(o: ObjectMap, key: []const u8) !?exprs.NodeId {
    return switch (try req(o, key)) {
        .integer => |i| try checkedU32(i),
        .null => null,
        else => error.BadWireFormat,
    };
}

fn decodeRepeat(o: ObjectMap, key: []const u8) !?usize {
    return switch (try req(o, key)) {
        .integer => |i| {
            if (i < 0 or i > @as(i128, std.math.maxInt(usize))) {
                return error.BadWireFormat;
            }
            return @intCast(i);
        },
        .null => null,
        else => error.BadWireFormat,
    };
}

fn freeDecodedStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    if (values.len > 0) allocator.free(values);
}

fn freeDecodedStringListItems(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged([]const u8),
) void {
    for (list.items) |value| allocator.free(value);
    list.deinit(allocator);
}

fn decodeStringList(allocator: std.mem.Allocator, v: Json) ![]const []const u8 {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer freeDecodedStringListItems(allocator, &list);
    for (arr.items) |item| {
        const value = switch (item) {
            .string => |string| string,
            else => return error.BadWireFormat,
        };
        const owned = try allocator.dupe(u8, value);
        list.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
    }
    return list.toOwnedSlice(allocator);
}

fn freeDecodedExternalNominal(
    allocator: std.mem.Allocator,
    external: types.ExternalNominal,
) void {
    freeDecodedStringList(allocator, external.path);
    freeDecodedTypeSlice(allocator, external.args);
}

fn decodeReceiver(s: []const u8) !items.Receiver {
    if (std.mem.eql(u8, s, "owned")) return .owned;
    if (std.mem.eql(u8, s, "ref_")) return .ref_;
    if (std.mem.eql(u8, s, "mut_ref")) return .mut_ref;
    return error.BadWireFormat;
}

/// The entire semantic model of a translated crate. This is defined beside
/// its wire codec so decoded values and frontend-produced values share one
/// nominal type.
pub const RustIr = struct {
    crate_name: []const u8,
    edition: []const u8 = "2021",
    graph: graph.CrateGraph,
    types: []const types.Type = &.{},
    bodies: bodies_mod.Bodies,
    /// Owned records produced by frontend monomorphization. Canonical v5
    /// always carries this table explicitly, including when it is empty.
    instantiations: []const types.Instantiation = &.{},

    pub fn deinitInstantiations(self: *RustIr, allocator: std.mem.Allocator) void {
        for (self.instantiations) |instantiation| {
            if (instantiation.args.params.len > 0) allocator.free(instantiation.args.params);
            if (instantiation.zig_suffix.len > 0) allocator.free(instantiation.zig_suffix);
        }
        if (self.instantiations.len > 0) allocator.free(self.instantiations);
        self.instantiations = &.{};
    }
};

fn freeDecodedAttributeList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(spine.Attribute),
) void {
    for (list.items) |attr| {
        allocator.free(attr.name);
        allocator.free(attr.meta);
    }
    list.deinit(allocator);
}

fn freeDecodedDeps(allocator: std.mem.Allocator, deps: []const graph.CrateDep) void {
    for (deps) |dep| {
        allocator.free(dep.extern_name);
        allocator.free(dep.local_alias);
        if (dep.version) |version| allocator.free(version);
        if (dep.path) |path| allocator.free(path);
        if (dep.git) |git| allocator.free(git);
        freeDecodedStringList(allocator, dep.features);
    }
    allocator.free(deps);
}

fn freeDecodedDepList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(graph.CrateDep),
) void {
    for (list.items) |dep| {
        allocator.free(dep.extern_name);
        allocator.free(dep.local_alias);
        if (dep.version) |version| allocator.free(version);
        if (dep.path) |path| allocator.free(path);
        if (dep.git) |git| allocator.free(git);
        freeDecodedStringList(allocator, dep.features);
    }
    list.deinit(allocator);
}

fn freeDecodedPathSegmentList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(types.PathSegment),
) void {
    for (list.items) |segment| allocator.free(segment.name);
    list.deinit(allocator);
}

fn freeDecodedVisibility(allocator: std.mem.Allocator, visibility: spine.Visibility) void {
    switch (visibility) {
        .in_path => |path| allocator.free(path),
        else => {},
    }
}
fn freeDecodedEntity(allocator: std.mem.Allocator, entity: spine.Entity) void {
    allocator.free(entity.name);
    freeDecodedVisibility(allocator, entity.visibility);
    if (entity.renamed_to) |renamed| allocator.free(renamed);
    freeDecodedAttributeListSlice(allocator, entity.attributes);
}

fn freeDecodedAttributeListSlice(
    allocator: std.mem.Allocator,
    attributes: []const spine.Attribute,
) void {
    for (attributes) |attribute| {
        allocator.free(attribute.name);
        allocator.free(attribute.meta);
    }
    if (attributes.len > 0) allocator.free(attributes);
}

fn freeDecodedModule(allocator: std.mem.Allocator, module: graph.Module) void {
    allocator.free(module.name);
    if (module.source_path) |source_path| allocator.free(source_path);
    if (module.items.len > 0) allocator.free(module.items);
    freeDecodedAttributeListSlice(allocator, module.attributes);
}

fn freeDecodedUseDecl(allocator: std.mem.Allocator, use_decl: graph.UseDecl) void {
    allocator.free(use_decl.local_name);
    switch (use_decl.kind) {
        .external => |external| freeDecodedStringList(allocator, external.path),
        else => {},
    }
}

fn freeDecodedFieldInits(allocator: std.mem.Allocator, fields: []const exprs.FieldInit) void {
    for (fields) |field| allocator.free(field.field);
    allocator.free(fields);
}

fn freeDecodedFieldInitList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(exprs.FieldInit),
) void {
    for (list.items) |field| allocator.free(field.field);
    list.deinit(allocator);
}

fn freeDecodedMatchArms(allocator: std.mem.Allocator, arms: []const exprs.MatchArm) void {
    for (arms) |arm| allocator.free(arm.patterns);
    allocator.free(arms);
}

fn freeDecodedMatchArmList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(exprs.MatchArm),
) void {
    for (list.items) |arm| allocator.free(arm.patterns);
    list.deinit(allocator);
}

fn freeDecodedFieldPats(allocator: std.mem.Allocator, fields: []const exprs.FieldPat) void {
    for (fields) |field| allocator.free(field.field);
    allocator.free(fields);
}

fn freeDecodedFieldPatList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(exprs.FieldPat),
) void {
    for (list.items) |field| allocator.free(field.field);
    list.deinit(allocator);
}

fn freeDecodedParam(allocator: std.mem.Allocator, param: items.Param) void {
    allocator.free(param.name);
}

fn freeDecodedParams(allocator: std.mem.Allocator, params: []const items.Param) void {
    for (params) |param| freeDecodedParam(allocator, param);
    allocator.free(params);
}

fn freeDecodedParamList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(items.Param),
) void {
    for (list.items) |param| freeDecodedParam(allocator, param);
    list.deinit(allocator);
}

fn decodeIdList(allocator: std.mem.Allocator, v: Json) ![]const exprs.NodeId {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
    errdefer list.deinit(allocator);
    for (arr.items) |it| {
        const x = switch (it) {
            .integer => |i| i,
            else => return error.BadWireFormat,
        };
        try list.append(allocator, try checkedU32(x));
    }
    return list.toOwnedSlice(allocator);
}

fn decodeSpan(v: Json) !spine.Span {
    const o = try getObj(v);
    return .{
        .start_line = @intCast(try reqU32(o, "start_line")),
        .start_col = @intCast(try reqU32(o, "start_col")),
        .end_line = @intCast(try reqU32(o, "end_line")),
        .end_col = @intCast(try reqU32(o, "end_col")),
    };
}

fn decodeVisibility(allocator: std.mem.Allocator, v: Json) !spine.Visibility {
    const o = try getObj(v);
    const kind = try reqStr(o, "kind");
    if (std.mem.eql(u8, kind, "public")) return .public;
    if (std.mem.eql(u8, kind, "crate_restricted")) return .crate_restricted;
    if (std.mem.eql(u8, kind, "super_restricted")) return .super_restricted;
    if (std.mem.eql(u8, kind, "private")) return .private;
    if (std.mem.eql(u8, kind, "in_path")) {
        return .{ .in_path = try allocator.dupe(u8, try reqStr(o, "path")) };
    }
    return error.BadWireFormat;
}

fn decodeAttributes(allocator: std.mem.Allocator, v: Json) ![]const spine.Attribute {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(spine.Attribute) = .empty;
    errdefer freeDecodedAttributeList(allocator, &list);
    for (arr.items) |av| {
        const o = try getObj(av);
        var name: ?[]u8 = try allocator.dupe(u8, try reqStr(o, "name"));
        errdefer if (name) |owned| allocator.free(owned);
        var meta: ?[]u8 = try allocator.dupe(u8, try reqStr(o, "meta"));
        errdefer if (meta) |owned| allocator.free(owned);
        const known = try reqBool(o, "known");
        try list.append(allocator, .{
            .name = name.?,
            .meta = meta.?,
            .known = known,
        });
        name = null;
        meta = null;
    }
    return list.toOwnedSlice(allocator);
}

fn decodeIdSlice(allocator: std.mem.Allocator, v: Json) ![]const spine.EntityId {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(spine.EntityId) = .empty;
    errdefer list.deinit(allocator);
    for (arr.items) |it| {
        const x = switch (it) {
            .integer => |i| i,
            else => return error.BadWireFormat,
        };
        try list.append(allocator, try checkedU32(x));
    }
    return list.toOwnedSlice(allocator);
}

fn decodeModuleKind(s: []const u8) !graph.ModuleKind {
    if (std.mem.eql(u8, s, "root")) return .root;
    if (std.mem.eql(u8, s, "inline")) return .@"inline";
    if (std.mem.eql(u8, s, "file")) return .file;
    if (std.mem.eql(u8, s, "directory")) return .directory;
    return error.BadWireFormat;
}

fn decodeEntityKind(s: []const u8) !spine.EntityKind {
    if (std.mem.eql(u8, s, "crate_")) return .crate_;
    if (std.mem.eql(u8, s, "module")) return .module;
    if (std.mem.eql(u8, s, "struct_")) return .struct_;
    if (std.mem.eql(u8, s, "enum_")) return .enum_;
    if (std.mem.eql(u8, s, "union_")) return .union_;
    if (std.mem.eql(u8, s, "fn_")) return .fn_;
    if (std.mem.eql(u8, s, "const_")) return .const_;
    if (std.mem.eql(u8, s, "static_")) return .static_;
    if (std.mem.eql(u8, s, "trait_")) return .trait_;
    if (std.mem.eql(u8, s, "impl_")) return .impl_;
    if (std.mem.eql(u8, s, "type_alias")) return .type_alias;
    if (std.mem.eql(u8, s, "use_")) return .use_;
    if (std.mem.eql(u8, s, "extern_crate")) return .extern_crate;
    if (std.mem.eql(u8, s, "macro_")) return .macro_;
    if (std.mem.eql(u8, s, "field")) return .field;
    if (std.mem.eql(u8, s, "variant")) return .variant;
    return error.BadWireFormat;
}

fn decodeModule(allocator: std.mem.Allocator, v: Json) !graph.Module {
    const o = try getObj(v);
    const id = @as(spine.EntityId, @intCast(try reqU32(o, "id")));
    const kind = try decodeModuleKind(try reqStr(o, "kind"));
    const name = try allocator.dupe(u8, try reqStr(o, "name"));
    errdefer allocator.free(name);
    const parent = try reqOptU32(o, "parent");
    const source_path: ?[]u8 = if (try reqOptStr(o, "source_path")) |sp|
        try allocator.dupe(u8, sp)
    else
        null;
    errdefer if (source_path) |path| allocator.free(path);
    const is_crate = try reqBool(o, "is_crate");
    const is_extern = try reqBool(o, "is_extern");
    const span = try decodeSpan(try req(o, "span"));
    const module_items = try decodeIdSlice(allocator, try req(o, "items"));
    errdefer allocator.free(module_items);
    const attributes = try decodeAttributes(allocator, try req(o, "attributes"));
    return .{
        .id = id,
        .kind = kind,
        .name = name,
        .parent = parent,
        .source_path = source_path,
        .is_crate = is_crate,
        .is_extern = is_extern,
        .span = span,
        .items = module_items,
        .attributes = attributes,
    };
}

fn decodeEntity(allocator: std.mem.Allocator, v: Json) !spine.Entity {
    const o = try getObj(v);
    const id = @as(spine.EntityId, @intCast(try reqU32(o, "id")));
    const kind = try decodeEntityKind(try reqStr(o, "kind"));
    const name = try allocator.dupe(u8, try reqStr(o, "name"));
    errdefer allocator.free(name);
    const span = try decodeSpan(try req(o, "span"));
    const visibility = try decodeVisibility(allocator, try req(o, "visibility"));
    errdefer freeDecodedVisibility(allocator, visibility);
    const parent = try reqOptU32(o, "parent");
    const resolved = try reqOptU32(o, "resolved");
    const renamed_to: ?[]u8 = if (try reqOptStr(o, "renamed_to")) |rn|
        try allocator.dupe(u8, rn)
    else
        null;
    errdefer if (renamed_to) |renamed| allocator.free(renamed);
    const attributes = try decodeAttributes(allocator, try req(o, "attributes"));
    return .{
        .id = id,
        .kind = kind,
        .name = name,
        .span = span,
        .visibility = visibility,
        .parent = parent,
        .resolved = resolved,
        .renamed_to = renamed_to,
        .attributes = attributes,
    };
}

fn decodeUseDecl(allocator: std.mem.Allocator, v: Json) !graph.UseDecl {
    const o = try getObj(v);
    const kind_str = try reqStr(o, "kind");
    const target: spine.EntityId = @intCast(try reqU32(o, "target"));
    var external_path: []const []const u8 = &.{};
    errdefer if (external_path.len > 0) freeDecodedStringList(allocator, external_path);
    const kind: graph.UseKind = if (std.mem.eql(u8, kind_str, "plain"))
        .{ .plain = target }
    else if (std.mem.eql(u8, kind_str, "alias"))
        .{ .alias = target }
    else if (std.mem.eql(u8, kind_str, "glob"))
        .glob
    else if (std.mem.eql(u8, kind_str, "external")) blk: {
        external_path = try decodeStringList(allocator, try req(o, "path"));
        if (external_path.len == 0) return error.BadWireFormat;
        for (external_path) |segment| {
            if (segment.len == 0) return error.BadWireFormat;
        }
        break :blk .{ .external = .{ .path = external_path } };
    } else return error.BadWireFormat;
    const id = @as(spine.EntityId, @intCast(try reqU32(o, "id")));
    const local_name = try allocator.dupe(u8, try reqStr(o, "local_name"));
    errdefer allocator.free(local_name);
    const is_pub_export = try reqBool(o, "is_pub_export");
    const span = try decodeSpan(try req(o, "span"));
    return .{
        .id = id,
        .kind = kind,
        .local_name = local_name,
        .is_pub_export = is_pub_export,
        .target = target,
        .span = span,
    };
}

fn decodeDeps(allocator: std.mem.Allocator, v: Json) ![]const graph.CrateDep {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(graph.CrateDep) = .empty;
    errdefer freeDecodedDepList(allocator, &list);
    for (arr.items, 0..) |dv, index| {
        const d = try getObj(dv);
        var extern_name: ?[]u8 = try allocator.dupe(u8, try reqStr(d, "extern_name"));
        errdefer if (extern_name) |owned| allocator.free(owned);
        var local_alias: ?[]u8 = try allocator.dupe(u8, try reqStr(d, "local_alias"));
        errdefer if (local_alias) |owned| allocator.free(owned);
        const version = if (try reqOptStr(d, "version")) |value| try allocator.dupe(u8, value) else null;
        errdefer if (version) |value| allocator.free(value);
        const path = if (try reqOptStr(d, "path")) |value| try allocator.dupe(u8, value) else null;
        errdefer if (path) |value| allocator.free(value);
        const git = if (try reqOptStr(d, "git")) |value| try allocator.dupe(u8, value) else null;
        errdefer if (git) |value| allocator.free(value);
        const default_features = try reqOptBool(d, "default_features");
        const features = try decodeStringList(allocator, try req(d, "features"));
        errdefer freeDecodedStringList(allocator, features);
        const optional = try reqBool(d, "optional");
        const id = @as(u32, @intCast(try reqU32(d, "id")));
        if (index >= @as(usize, std.math.maxInt(u32)) or
            id != @as(u32, @intCast(index + 1)))
        {
            return error.InvalidDependency;
        }
        try list.append(allocator, .{
            .extern_name = extern_name.?,
            .local_alias = local_alias.?,
            .id = id,
            .version = version,
            .path = path,
            .git = git,
            .optional = optional,
            .default_features = default_features,
            .features = features,
        });
        extern_name = null;
        local_alias = null;
    }
    return list.toOwnedSlice(allocator);
}

fn decodeCrateKind(s: []const u8) !graph.CrateKind {
    if (std.mem.eql(u8, s, "lib")) return .lib;
    if (std.mem.eql(u8, s, "bin")) return .bin;
    return error.BadWireFormat;
}

// ── Literals ────────────────────────────────────────────────────────────────

fn decodeIntLit(allocator: std.mem.Allocator, v: Json) !exprs.IntLit {
    const o = try getObj(v);
    const base_s = try reqStr(o, "base");
    const base: @FieldType(exprs.IntLit, "base") = if (std.mem.eql(u8, base_s, "dec"))
        .dec
    else if (std.mem.eql(u8, base_s, "hex"))
        .hex
    else if (std.mem.eql(u8, base_s, "oct"))
        .oct
    else if (std.mem.eql(u8, base_s, "bin"))
        .bin
    else
        return error.BadWireFormat;
    const value: i128 = std.fmt.parseInt(i128, try reqStr(o, "value"), 10) catch return error.BadWireFormat;
    const suffix = try reqOptStr(o, "ty_suffix");
    const text = try allocator.dupe(u8, try reqStr(o, "text"));
    errdefer allocator.free(text);
    const ty_suffix: ?[]u8 = if (suffix) |s| try allocator.dupe(u8, s) else null;
    errdefer if (ty_suffix) |owned| allocator.free(owned);
    return .{
        .text = text,
        .value = value,
        .base = base,
        .ty_suffix = ty_suffix,
    };
}

fn decodeFloatLit(allocator: std.mem.Allocator, v: Json) !exprs.FloatLit {
    const o = try getObj(v);
    const text = try allocator.dupe(u8, try reqStr(o, "text"));
    errdefer allocator.free(text);
    const value = try reqFloat(o, "value");
    return .{
        .text = text,
        .value = value,
    };
}

fn decodeCharLit(allocator: std.mem.Allocator, v: Json) !exprs.CharLit {
    const o = try getObj(v);
    const text = try allocator.dupe(u8, try reqStr(o, "text"));
    errdefer allocator.free(text);
    const value = @as(u32, @intCast(try reqU32(o, "value")));
    return .{
        .text = text,
        .value = value,
    };
}

fn decodeStringLit(allocator: std.mem.Allocator, v: Json) !exprs.StringLit {
    const o = try getObj(v);
    return .{ .bytes = try allocator.dupe(u8, try reqStr(o, "bytes")) };
}

fn decodeByteArrayLit(allocator: std.mem.Allocator, v: Json) !exprs.ByteArrayLit {
    const o = try getObj(v);
    const arr = switch (try req(o, "items")) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    const out = try allocator.alloc(u8, arr.items.len);
    errdefer allocator.free(out);
    for (arr.items, 0..) |item, i| {
        out[i] = switch (item) {
            .integer => |x| @intCast(x),
            else => return error.BadWireFormat,
        };
    }
    return .{ .items = out };
}

fn decodeLiteral(allocator: std.mem.Allocator, v: Json) !exprs.Literal {
    const o = try getObj(v);
    const tag = try reqStr(o, "kind");
    const val = try req(o, "value");
    if (std.mem.eql(u8, tag, "int")) return .{ .int = try decodeIntLit(allocator, val) };
    if (std.mem.eql(u8, tag, "float")) return .{ .float = try decodeFloatLit(allocator, val) };
    if (std.mem.eql(u8, tag, "character")) return .{ .character = try decodeCharLit(allocator, val) };
    if (std.mem.eql(u8, tag, "string")) return .{ .string = try decodeStringLit(allocator, val) };
    if (std.mem.eql(u8, tag, "byte_array")) return .{ .byte_array = try decodeByteArrayLit(allocator, val) };
    if (std.mem.eql(u8, tag, "boolean")) {
        const b = switch (val) {
            .bool => |x| x,
            else => return error.BadWireFormat,
        };
        return .{ .boolean = b };
    }
    return error.BadWireFormat;
}

// ── Types ───────────────────────────────────────────────────────────────────

fn decodePathSegments(allocator: std.mem.Allocator, v: Json) ![]const types.PathSegment {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(types.PathSegment) = .empty;
    errdefer freeDecodedPathSegmentList(allocator, &list);
    for (arr.items) |it| {
        const o = try getObj(it);
        var name: ?[]u8 = try allocator.dupe(u8, try reqStr(o, "name"));
        errdefer if (name) |owned| allocator.free(owned);
        const id = try reqOptionalId(o, "id");
        try list.append(allocator, .{
            .name = name.?,
            .id = id,
        });
        name = null;
    }
    return list.toOwnedSlice(allocator);
}

fn freeDecodedType(allocator: std.mem.Allocator, ty: types.Type) void {
    switch (ty) {
        .path => |path| {
            for (path.segments) |segment| allocator.free(segment.name);
            if (path.segments.len > 0) allocator.free(path.segments);
        },
        .external_nominal => |external| freeDecodedExternalNominal(allocator, external),
        .reference => |reference| {
            freeDecodedType(allocator, reference.pointee);
            allocator.destroy(@constCast(reference));
        },
        .raw_ptr => |raw_ptr| {
            freeDecodedType(allocator, raw_ptr.pointee);
            allocator.destroy(@constCast(raw_ptr));
        },
        .slice => |slice| {
            freeDecodedType(allocator, slice.elem);
            allocator.destroy(@constCast(slice));
        },
        .array => |array| {
            freeDecodedType(allocator, array.elem);
            allocator.destroy(@constCast(array));
        },
        .tuple => |tuple| {
            for (tuple) |item| freeDecodedType(allocator, item);
            if (tuple.len > 0) allocator.free(tuple);
        },
        .fn_ptr => |fn_ptr| {
            for (fn_ptr.params) |param| freeDecodedType(allocator, param);
            if (fn_ptr.params.len > 0) allocator.free(fn_ptr.params);
            freeDecodedType(allocator, fn_ptr.ret);
            allocator.destroy(@constCast(fn_ptr));
        },
        .generic_inst => |generic_inst| {
            for (generic_inst.args.params) |param| freeDecodedType(allocator, param);
            if (generic_inst.args.params.len > 0) allocator.free(generic_inst.args.params);
        },
        .option => |option| {
            freeDecodedType(allocator, option.*);
            allocator.destroy(@constCast(option));
        },
        .result => |result| {
            freeDecodedType(allocator, result.ok);
            freeDecodedType(allocator, result.err);
            allocator.destroy(@constCast(result));
        },
        .boxed => |boxed| {
            freeDecodedType(allocator, boxed.*);
            allocator.destroy(@constCast(boxed));
        },
        .unsupported => |unsupported| allocator.free(unsupported.message),
        .prim => {},
    }
}

fn freeDecodedTypeSlice(allocator: std.mem.Allocator, values: []const types.Type) void {
    for (values) |value| freeDecodedType(allocator, value);
    if (values.len > 0) allocator.free(values);
}

fn freeDecodedTypeList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(types.Type),
) void {
    for (list.items) |value| freeDecodedType(allocator, value);
    list.deinit(allocator);
}

fn decodeTypeList(allocator: std.mem.Allocator, v: Json) anyerror![]const types.Type {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(types.Type) = .empty;
    errdefer freeDecodedTypeList(allocator, &list);
    for (arr.items) |it| try list.append(allocator, try decodeType(allocator, it));
    return list.toOwnedSlice(allocator);
}

fn decodeInstantiation(allocator: std.mem.Allocator, v: Json) !types.Instantiation {
    const o = try getObj(v);
    const generic_id = @as(spine.EntityId, @intCast(try reqU32(o, "generic_id")));
    const args_obj = try getObj(try req(o, "args"));
    const params = try decodeTypeList(allocator, try req(args_obj, "params"));
    errdefer freeDecodedTypeSlice(allocator, params);
    const zig_suffix = try allocator.dupe(u8, try reqStr(o, "zig_suffix"));
    errdefer allocator.free(zig_suffix);
    return .{
        .generic_id = generic_id,
        .args = .{ .params = params },
        .zig_suffix = zig_suffix,
    };
}

fn decodeInstantiations(
    allocator: std.mem.Allocator,
    v: Json,
) ![]const types.Instantiation {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(types.Instantiation) = .empty;
    errdefer freeDecodedInstantiationList(allocator, &list);
    for (arr.items) |item| try list.append(allocator, try decodeInstantiation(allocator, item));
    return list.toOwnedSlice(allocator);
}

fn freeDecodedInstantiationList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(types.Instantiation),
) void {
    for (list.items) |instantiation| {
        freeDecodedTypeSlice(allocator, instantiation.args.params);
        if (instantiation.zig_suffix.len > 0) allocator.free(instantiation.zig_suffix);
    }
    list.deinit(allocator);
}
fn freeDecodedInstantiations(
    allocator: std.mem.Allocator,
    instantiations: []const types.Instantiation,
) void {
    for (instantiations) |instantiation| {
        freeDecodedTypeSlice(allocator, instantiation.args.params);
        if (instantiation.zig_suffix.len > 0) allocator.free(instantiation.zig_suffix);
    }
    if (instantiations.len > 0) allocator.free(instantiations);
}

fn decodePrim(s: []const u8) !types.Prim {
    if (std.mem.eql(u8, s, "i8")) return .i8;
    if (std.mem.eql(u8, s, "i16")) return .i16;
    if (std.mem.eql(u8, s, "i32")) return .i32;
    if (std.mem.eql(u8, s, "i64")) return .i64;
    if (std.mem.eql(u8, s, "i128")) return .i128;
    if (std.mem.eql(u8, s, "u8")) return .u8;
    if (std.mem.eql(u8, s, "u16")) return .u16;
    if (std.mem.eql(u8, s, "u32")) return .u32;
    if (std.mem.eql(u8, s, "u64")) return .u64;
    if (std.mem.eql(u8, s, "u128")) return .u128;
    if (std.mem.eql(u8, s, "isize")) return .isize;
    if (std.mem.eql(u8, s, "usize")) return .usize;
    if (std.mem.eql(u8, s, "f32")) return .f32;
    if (std.mem.eql(u8, s, "f64")) return .f64;
    if (std.mem.eql(u8, s, "bool")) return .bool;
    if (std.mem.eql(u8, s, "char")) return .char;
    if (std.mem.eql(u8, s, "unit")) return .unit;
    if (std.mem.eql(u8, s, "never")) return .never;
    return error.BadWireFormat;
}

fn decodeUnsupportedReason(s: []const u8) !spine.UnsupportedReason {
    inline for (std.meta.fields(spine.UnsupportedReason)) |f| {
        if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    }
    return error.BadWireFormat;
}

fn decodeExternalNominal(
    allocator: std.mem.Allocator,
    v: Json,
) !types.ExternalNominal {
    const o = try getObj(v);
    const path = try decodeStringList(allocator, try req(o, "path"));
    errdefer freeDecodedStringList(allocator, path);
    if (path.len == 0) return error.InvalidTypePath;
    for (path) |segment| {
        if (segment.len == 0) return error.InvalidTypePath;
    }
    const args = try decodeTypeList(allocator, try req(o, "args"));
    return .{ .path = path, .args = args };
}

fn decodeType(allocator: std.mem.Allocator, v: Json) !types.Type {
    const o = try getObj(v);
    const tag = try reqStr(o, "kind");
    const val = try req(o, "value");

    if (std.mem.eql(u8, tag, "path")) {
        const p = try getObj(val);
        return .{ .path = .{ .segments = try decodePathSegments(allocator, try req(p, "segments")) } };
    }
    if (std.mem.eql(u8, tag, "prim")) {
        return .{ .prim = try decodePrim(try reqStrArray(val)) };
    }
    if (std.mem.eql(u8, tag, "external_nominal")) {
        return .{ .external_nominal = try decodeExternalNominal(allocator, val) };
    }
    if (std.mem.eql(u8, tag, "slice")) {
        const p = try getObj(val);
        const inner = try allocator.create(types.Slice);
        inner.* = .{
            .const_ = try reqBool(p, "const_"),
            .elem = try decodeType(allocator, try req(p, "elem")),
        };
        return .{ .slice = inner };
    }
    if (std.mem.eql(u8, tag, "reference")) {
        const p = try getObj(val);
        const inner = try allocator.create(types.Ref);
        inner.* = .{
            .mut = try reqBool(p, "mut"),
            .pointee = try decodeType(allocator, try req(p, "pointee")),
        };
        return .{ .reference = inner };
    }
    if (std.mem.eql(u8, tag, "raw_ptr")) {
        const p = try getObj(val);
        const inner = try allocator.create(types.RawPtr);
        inner.* = .{
            .mut = try reqBool(p, "mut"),
            .pointee = try decodeType(allocator, try req(p, "pointee")),
        };
        return .{ .raw_ptr = inner };
    }
    if (std.mem.eql(u8, tag, "array")) {
        const p = try getObj(val);
        const inner = try allocator.create(types.Array);
        const len_o = try getObj(try req(p, "len"));
        inner.* = .{
            .elem = try decodeType(allocator, try req(p, "elem")),
            .len = blk: {
                const len_kind = try reqStr(len_o, "kind");
                if (std.mem.eql(u8, len_kind, "literal")) {
                    break :blk .{ .literal = try reqU32(len_o, "value") };
                }
                if (std.mem.eql(u8, len_kind, "generic")) {
                    break :blk .{ .generic = try reqU32(len_o, "value") };
                }
                return error.BadWireFormat;
            },
        };
        return .{ .array = inner };
    }
    if (std.mem.eql(u8, tag, "tuple")) return .{ .tuple = try decodeTypeList(allocator, val) };
    if (std.mem.eql(u8, tag, "fn_ptr")) {
        const p = try getObj(val);
        const inner = try allocator.create(types.FnPtr);
        inner.* = .{
            .params = try decodeTypeList(allocator, try req(p, "params")),
            .ret = try decodeType(allocator, try req(p, "ret")),
        };
        return .{ .fn_ptr = inner };
    }
    if (std.mem.eql(u8, tag, "generic_inst")) {
        const p = try getObj(val);
        const args_o = try getObj(try req(p, "args"));
        return .{ .generic_inst = .{
            .decl = @intCast(try reqU32(p, "decl")),
            .args = .{ .params = try decodeTypeList(allocator, try req(args_o, "params")) },
        } };
    }
    if (std.mem.eql(u8, tag, "option")) {
        const inner = try allocator.create(types.Type);
        inner.* = try decodeType(allocator, val);
        return .{ .option = inner };
    }
    if (std.mem.eql(u8, tag, "result")) {
        const p = try getObj(val);
        const inner = try allocator.create(types.Result);
        inner.* = .{
            .ok = try decodeType(allocator, try req(p, "ok")),
            .err = try decodeType(allocator, try req(p, "err")),
            .is_error_unionable = try reqBool(p, "is_error_unionable"),
        };
        return .{ .result = inner };
    }
    if (std.mem.eql(u8, tag, "boxed")) {
        const inner = try allocator.create(types.Type);
        inner.* = try decodeType(allocator, val);
        return .{ .boxed = inner };
    }
    if (std.mem.eql(u8, tag, "unsupported")) {
        const p = try getObj(val);
        const reason = try decodeUnsupportedReason(try reqStr(p, "reason"));
        const message = try allocator.dupe(u8, try reqStr(p, "message"));
        errdefer allocator.free(message);
        const span = try decodeSpan(try req(p, "span"));
        return .{ .unsupported = .{
            .reason = reason,
            .message = message,
            .span = span,
        } };
    }
    return error.BadWireFormat;
}

// ── Enums / Operators ───────────────────────────────────────────────────────

fn decodeOverflow(s: []const u8) !exprs.Overflow {
    if (std.mem.eql(u8, s, "checked")) return .checked;
    if (std.mem.eql(u8, s, "wrapping")) return .wrapping;
    if (std.mem.eql(u8, s, "saturating")) return .saturating;
    return error.BadWireFormat;
}

fn decodeReceiverMode(s: []const u8) !exprs.ReceiverMode {
    if (std.mem.eql(u8, s, "value")) return .value;
    if (std.mem.eql(u8, s, "shared")) return .shared;
    if (std.mem.eql(u8, s, "mutable")) return .mutable;
    return error.BadWireFormat;
}

fn decodeBindMode(s: []const u8) !exprs.BindMode {
    if (std.mem.eql(u8, s, "value")) return .{ .value = {} };
    if (std.mem.eql(u8, s, "shared_ref")) return .{ .shared_ref = {} };
    if (std.mem.eql(u8, s, "mut_ref")) return .{ .mut_ref = {} };
    return error.BadWireFormat;
}

fn decodeBinaryOp(s: []const u8) !exprs.BinaryOp {
    if (std.mem.eql(u8, s, "add")) return .add;
    if (std.mem.eql(u8, s, "sub")) return .sub;
    if (std.mem.eql(u8, s, "mul")) return .mul;
    if (std.mem.eql(u8, s, "div")) return .div;
    if (std.mem.eql(u8, s, "rem")) return .rem;
    if (std.mem.eql(u8, s, "bit_and")) return .bit_and;
    if (std.mem.eql(u8, s, "bit_or")) return .bit_or;
    if (std.mem.eql(u8, s, "bit_xor")) return .bit_xor;
    if (std.mem.eql(u8, s, "shl")) return .shl;
    if (std.mem.eql(u8, s, "shr")) return .shr;
    if (std.mem.eql(u8, s, "eq")) return .eq;
    if (std.mem.eql(u8, s, "ne")) return .ne;
    if (std.mem.eql(u8, s, "lt")) return .lt;
    if (std.mem.eql(u8, s, "le")) return .le;
    if (std.mem.eql(u8, s, "gt")) return .gt;
    if (std.mem.eql(u8, s, "ge")) return .ge;
    if (std.mem.eql(u8, s, "boolean_and")) return .boolean_and;
    if (std.mem.eql(u8, s, "boolean_or")) return .boolean_or;
    return error.BadWireFormat;
}

fn decodeAssignOp(s: []const u8) !exprs.AssignOp {
    if (std.mem.eql(u8, s, "plain")) return .plain;
    if (std.mem.eql(u8, s, "add")) return .add;
    if (std.mem.eql(u8, s, "sub")) return .sub;
    if (std.mem.eql(u8, s, "mul")) return .mul;
    if (std.mem.eql(u8, s, "div")) return .div;
    if (std.mem.eql(u8, s, "rem")) return .rem;
    if (std.mem.eql(u8, s, "bit_and")) return .bit_and;
    if (std.mem.eql(u8, s, "bit_or")) return .bit_or;
    if (std.mem.eql(u8, s, "bit_xor")) return .bit_xor;
    if (std.mem.eql(u8, s, "shl")) return .shl;
    if (std.mem.eql(u8, s, "shr")) return .shr;
    return error.BadWireFormat;
}

fn decodeCallKind(v: Json) !exprs.CallKind {
    const o = try getObj(v);
    const tag = try reqStr(o, "kind");
    const d: spine.EntityId = @intCast(try reqU32(o, "def"));
    if (std.mem.eql(u8, tag, "free")) return .{ .free = d };
    if (std.mem.eql(u8, tag, "associated")) return .{ .associated = d };
    if (std.mem.eql(u8, tag, "constructor")) return .{ .constructor = d };
    return error.BadWireFormat;
}

// ── Expressions ─────────────────────────────────────────────────────────────

fn decodeBlockExpr(allocator: std.mem.Allocator, v: Json) !exprs.BlockExpr {
    const o = try getObj(v);
    const labelled = try reqOptStr(o, "labelled");
    return .{
        .statements = try decodeIdList(allocator, try req(o, "statements")),
        .tail = try reqOptionalId(o, "tail"),
        .labelled = if (labelled) |s| try allocator.dupe(u8, s) else null,
    };
}

fn decodeElseBranch(allocator: std.mem.Allocator, v: Json) !exprs.ElseBranch {
    const o = try getObj(v);
    const tag = try reqStr(o, "kind");
    if (std.mem.eql(u8, tag, "none")) return .{ .none = {} };
    if (std.mem.eql(u8, tag, "chain")) return .{ .chain = try reqU32(o, "value") };
    if (std.mem.eql(u8, tag, "block")) return .{ .block = try decodeBlockExpr(allocator, try req(o, "value")) };
    return error.BadWireFormat;
}

fn decodeIterKind(allocator: std.mem.Allocator, v: Json) !exprs.IterKind {
    const o = try getObj(v);
    const tag = try reqStr(o, "kind");
    if (std.mem.eql(u8, tag, "range")) return .{ .range = {} };
    if (std.mem.eql(u8, tag, "slice")) return .{ .slice = {} };
    if (std.mem.eql(u8, tag, "enumerate")) return .{ .enumerate = {} };
    if (std.mem.eql(u8, tag, "multi")) return .{ .multi = try decodeIdList(allocator, try req(o, "value")) };
    return error.BadWireFormat;
}

fn decodeExprKind(allocator: std.mem.Allocator, tag: []const u8, val: Json) !exprs.ExprKind {
    if (std.mem.eql(u8, tag, "literal")) return .{ .literal = try decodeLiteral(allocator, val) };
    if (std.mem.eql(u8, tag, "array")) {
        const p = try getObj(val);
        const repeat = try decodeRepeat(p, "repeat");
        return .{ .array = .{
            .elements = try decodeIdList(allocator, try req(p, "elements")),
            .repeat = repeat,
        } };
    }
    if (std.mem.eql(u8, tag, "vec_lit")) {
        const p = try getObj(val);
        const repeat = try decodeRepeat(p, "repeat");
        return .{ .vec_lit = .{
            .elements = try decodeIdList(allocator, try req(p, "elements")),
            .repeat = repeat,
        } };
    }

    if (std.mem.eql(u8, tag, "path")) {
        const p = try getObj(val);
        return .{ .path = .{
            .def = @intCast(try reqU32(p, "def")),
            .generic_args = try decodeTypeList(allocator, try req(p, "generic_args")),
        } };
    }
    if (std.mem.eql(u8, tag, "block")) return .{ .block = try decodeBlockExpr(allocator, val) };
    if (std.mem.eql(u8, tag, "unit")) return .unit;
    if (std.mem.eql(u8, tag, "if_else")) {
        const q = try getObj(val);
        return .{ .if_else = .{
            .cond = try reqU32(q, "cond"),
            .then_ = try decodeBlockExpr(allocator, try req(q, "then")),
            .@"else" = try decodeElseBranch(allocator, try req(q, "else")),
        } };
    }
    if (std.mem.eql(u8, tag, "if_let")) {
        const q = try getObj(val);
        return .{ .if_let = .{
            .pattern = try reqU32(q, "pattern"),
            .scrutinee = try reqU32(q, "scrutinee"),
            .then_ = try decodeBlockExpr(allocator, try req(q, "then")),
            .@"else" = try decodeElseBranch(allocator, try req(q, "else")),
        } };
    }
    if (std.mem.eql(u8, tag, "match")) {
        const q = try getObj(val);
        const arms_arr = switch (try req(q, "arms")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var arms: std.ArrayListUnmanaged(exprs.MatchArm) = .empty;
        errdefer freeDecodedMatchArmList(allocator, &arms);
        for (arms_arr.items) |av| {
            const ao = try getObj(av);
            var patterns: ?[]const exprs.NodeId =
                try decodeIdList(allocator, try req(ao, "patterns"));
            errdefer if (patterns) |owned| allocator.free(owned);
            const guard = try reqOptionalId(ao, "guard");
            const body = try reqU32(ao, "body");
            try arms.append(allocator, .{
                .patterns = patterns.?,
                .guard = guard,
                .body = body,
            });
            patterns = null;
        }
        const scrutinee = try reqU32(q, "scrutinee");
        const arms_slice = try arms.toOwnedSlice(allocator);
        errdefer freeDecodedMatchArms(allocator, arms_slice);
        const option_scrutinee = try reqBool(q, "option_scrutinee");
        return .{ .match = .{
            .scrutinee = scrutinee,
            .arms = arms_slice,
            .option_scrutinee = option_scrutinee,
        } };
    }
    if (std.mem.eql(u8, tag, "loop_")) {
        const q = try getObj(val);
        return .{ .loop_ = .{ .body = try decodeBlockExpr(allocator, try req(q, "body")) } };
    }
    if (std.mem.eql(u8, tag, "while_")) {
        const q = try getObj(val);
        return .{ .while_ = .{
            .cond = try reqU32(q, "cond"),
            .body = try decodeBlockExpr(allocator, try req(q, "body")),
            .capture = try reqOptionalId(q, "capture"),
        } };
    }
    if (std.mem.eql(u8, tag, "for_")) {
        const q = try getObj(val);
        return .{ .for_ = .{
            .pattern = try reqU32(q, "pattern"),
            .iterable = try reqU32(q, "iterable"),
            .body = try decodeBlockExpr(allocator, try req(q, "body")),
            .iter_kind = try decodeIterKind(allocator, try req(q, "iter_kind")),
        } };
    }
    if (std.mem.eql(u8, tag, "break_")) {
        const q = try getObj(val);
        const label = try reqOptStr(q, "label");
        return .{ .break_ = .{
            .label = if (label) |s| try allocator.dupe(u8, s) else null,
            .value = try reqOptionalId(q, "value"),
        } };
    }
    if (std.mem.eql(u8, tag, "continue_")) {
        const q = try getObj(val);
        const label = try reqOptStr(q, "label");
        return .{ .continue_ = .{ .label = if (label) |s| try allocator.dupe(u8, s) else null } };
    }
    if (std.mem.eql(u8, tag, "call")) {
        const q = try getObj(val);
        return .{ .call = .{
            .call_kind = try decodeCallKind(try req(q, "call_kind")),
            .args = try decodeIdList(allocator, try req(q, "args")),
        } };
    }
    if (std.mem.eql(u8, tag, "method_call")) {
        const q = try getObj(val);
        return .{ .method_call = .{
            .receiver = try reqU32(q, "receiver"),
            .receiver_mode = try decodeReceiverMode(try reqStr(q, "receiver_mode")),
            .method = @intCast(try reqU32(q, "method")),
            .args = try decodeIdList(allocator, try req(q, "args")),
        } };
    }
    if (std.mem.eql(u8, tag, "struct_lit")) {
        const q = try getObj(val);
        const def = @as(exprs.DefId, @intCast(try reqU32(q, "def")));
        const fields_arr = switch (try req(q, "fields")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var fields: std.ArrayListUnmanaged(exprs.FieldInit) = .empty;
        errdefer freeDecodedFieldInitList(allocator, &fields);
        for (fields_arr.items) |fv| {
            const fo = try getObj(fv);
            var field_name: ?[]u8 = try allocator.dupe(u8, try reqStr(fo, "field"));
            errdefer if (field_name) |owned| allocator.free(owned);
            const value = try reqU32(fo, "value");
            const shorthand = try reqBool(fo, "shorthand");
            try fields.append(allocator, .{
                .field = field_name.?,
                .value = value,
                .shorthand = shorthand,
            });
            field_name = null;
        }
        const field_values = try fields.toOwnedSlice(allocator);
        errdefer freeDecodedFieldInits(allocator, field_values);
        const base = try reqOptionalId(q, "base");
        return .{ .struct_lit = .{
            .def = def,
            .fields = field_values,
            .base = base,
        } };
    }
    if (std.mem.eql(u8, tag, "enum_variant")) {
        const q = try getObj(val);
        const def = @as(exprs.DefId, @intCast(try reqU32(q, "def")));
        const variant = try allocator.dupe(u8, try reqStr(q, "variant"));
        errdefer allocator.free(variant);
        const tuple_fields = try decodeIdList(allocator, try req(q, "tuple_fields"));
        errdefer allocator.free(tuple_fields);
        const named_arr = switch (try req(q, "named_fields")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var named: std.ArrayListUnmanaged(exprs.FieldInit) = .empty;
        errdefer freeDecodedFieldInitList(allocator, &named);
        for (named_arr.items) |fv| {
            const fo = try getObj(fv);
            var field_name: ?[]u8 = try allocator.dupe(u8, try reqStr(fo, "field"));
            errdefer if (field_name) |owned| allocator.free(owned);
            const value = try reqU32(fo, "value");
            const shorthand = try reqBool(fo, "shorthand");
            try named.append(allocator, .{
                .field = field_name.?,
                .value = value,
                .shorthand = shorthand,
            });
            field_name = null;
        }
        const named_fields = try named.toOwnedSlice(allocator);
        errdefer freeDecodedFieldInits(allocator, named_fields);
        return .{ .enum_variant = .{
            .def = def,
            .variant = variant,
            .tuple_fields = tuple_fields,
            .named_fields = named_fields,
        } };
    }
    if (std.mem.eql(u8, tag, "field")) {
        const q = try getObj(val);
        const base = try reqU32(q, "base");
        const field = try allocator.dupe(u8, try reqStr(q, "field"));
        errdefer allocator.free(field);
        const resolved = @as(exprs.DefId, @intCast(try reqU32(q, "resolved")));
        return .{ .field = .{
            .base = base,
            .field = field,
            .resolved = resolved,
        } };
    }
    if (std.mem.eql(u8, tag, "index")) {
        const q = try getObj(val);
        return .{ .index = .{
            .base = try reqU32(q, "base"),
            .index = try reqU32(q, "index"),
        } };
    }
    if (std.mem.eql(u8, tag, "cast")) {
        const q = try getObj(val);
        const kind = try decodeConversion(try reqStr(q, "conversion"));
        return .{ .cast = .{
            .kind = kind,
            .operand = try reqU32(q, "operand"),
            .source_type = try decodeType(allocator, try req(q, "source_type")),
            .target = try reqU32(q, "target"),
        } };
    }
    if (std.mem.eql(u8, tag, "binary")) {
        const q = try getObj(val);
        return .{ .binary = .{
            .op = try decodeBinaryOp(try reqStr(q, "op")),
            .overflow = try decodeOverflow(try reqStr(q, "overflow")),
            .lhs = try reqU32(q, "lhs"),
            .rhs = try reqU32(q, "rhs"),
        } };
    }
    if (std.mem.eql(u8, tag, "unary")) {
        const q = try getObj(val);
        const op = try reqStr(q, "op");
        if (std.mem.eql(u8, op, "ref")) {
            return .{ .unary = .{
                .op = .{ .ref = try decodeReceiverMode(try reqStr(q, "mode")) },
                .operand = try reqU32(q, "operand"),
            } };
        }
        const unary_op: @FieldType(exprs.UnaryExpr, "op") = if (std.mem.eql(u8, op, "negate"))
            .negate
        else if (std.mem.eql(u8, op, "logical_not"))
            .logical_not
        else if (std.mem.eql(u8, op, "bit_not"))
            .bit_not
        else if (std.mem.eql(u8, op, "deref"))
            .deref
        else
            return error.BadWireFormat;
        return .{ .unary = .{
            .op = unary_op,
            .operand = try reqU32(q, "operand"),
        } };
    }
    if (std.mem.eql(u8, tag, "assign")) {
        const q = try getObj(val);
        return .{ .assign = .{
            .target = try reqU32(q, "target"),
            .op = try decodeAssignOp(try reqStr(q, "op")),
            .value = try reqU32(q, "value"),
            .overflow = try decodeOverflow(try reqStr(q, "overflow")),
        } };
    }
    if (std.mem.eql(u8, tag, "try_")) {
        const q = try getObj(val);
        return .{ .try_ = .{ .inner = try reqU32(q, "inner") } };
    }
    if (std.mem.eql(u8, tag, "return_")) {
        const q = try getObj(val);
        return .{ .return_ = .{ .value = try reqOptionalId(q, "value") } };
    }
    if (std.mem.eql(u8, tag, "unsupported")) {
        const q = try getObj(val);
        const reason = try allocator.dupe(u8, try reqStr(q, "reason"));
        errdefer allocator.free(reason);
        const suggested_version = try decodeUnsupportedVersion(
            try reqStr(q, "suggested_version"),
        );
        return .{ .unsupported = .{
            .reason = reason,
            .suggested_version = suggested_version,
        } };
    }
    return error.BadWireFormat;
}

fn decodeUnsupportedVersion(
    s: []const u8,
) !@FieldType(exprs.Unsupported, "suggested_version") {
    if (std.mem.eql(u8, s, "v1")) return .v1;
    if (std.mem.eql(u8, s, "v2")) return .v2;
    if (std.mem.eql(u8, s, "v3")) return .v3;
    return error.BadWireFormat;
}

fn decodeConversion(s: []const u8) !@FieldType(exprs.CastExpr, "kind") {
    if (std.mem.eql(u8, s, "as")) return .as_;
    if (std.mem.eql(u8, s, "primitive_from")) return .primitive_from;
    return error.BadWireFormat;
}

fn decodeExpr(allocator: std.mem.Allocator, v: Json) !exprs.Expr {
    const o = try getObj(v);
    return .{
        .id = try reqU32(o, "id"),
        .span = try decodeSpan(try req(o, "span")),
        .ty = try reqOptionalId(o, "ty"),
        .kind = try decodeExprKind(allocator, try reqStr(o, "kind"), try req(o, "value")),
    };
}

fn decodePatternKind(allocator: std.mem.Allocator, tag: []const u8, val: Json) !exprs.PatternKind {
    if (std.mem.eql(u8, tag, "wildcard")) return .{ .wildcard = {} };
    if (std.mem.eql(u8, tag, "binding")) {
        const b = try getObj(val);
        const name = try allocator.dupe(u8, try reqStr(b, "name"));
        errdefer allocator.free(name);
        const mode = try decodeBindMode(try reqStr(b, "mode"));
        const mutable = try reqBool(b, "mutable");
        return .{ .binding = .{
            .name = name,
            .mode = mode,
            .mutable = mutable,
        } };
    }
    if (std.mem.eql(u8, tag, "literal")) return .{ .literal = try decodeLiteral(allocator, val) };
    if (std.mem.eql(u8, tag, "path")) {
        const p = try getObj(val);
        const variant = try reqOptStr(p, "variant");
        return .{ .path = .{
            .def = @intCast(try reqU32(p, "def")),
            .variant = if (variant) |s| try allocator.dupe(u8, s) else null,
        } };
    }
    if (std.mem.eql(u8, tag, "tuple")) {
        const t = try getObj(val);
        return .{ .tuple = .{
            .elements = try decodeIdList(allocator, try req(t, "elements")),
            .rest = try reqBool(t, "rest"),
        } };
    }
    if (std.mem.eql(u8, tag, "slice")) {
        const t = try getObj(val);
        return .{ .slice = .{
            .elements = try decodeIdList(allocator, try req(t, "elements")),
            .rest = try reqOptionalId(t, "rest"),
        } };
    }
    if (std.mem.eql(u8, tag, "struct_pat")) {
        const t = try getObj(val);
        const def = @as(exprs.DefId, @intCast(try reqU32(t, "def")));
        const fields_arr = switch (try req(t, "fields")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var fields: std.ArrayListUnmanaged(exprs.FieldPat) = .empty;
        errdefer freeDecodedFieldPatList(allocator, &fields);
        for (fields_arr.items) |fv| {
            const fo = try getObj(fv);
            var field_name: ?[]u8 = try allocator.dupe(u8, try reqStr(fo, "field"));
            errdefer if (field_name) |owned| allocator.free(owned);
            const pat = try reqOptionalId(fo, "pat");
            const shorthand = try reqBool(fo, "shorthand");
            try fields.append(allocator, .{
                .field = field_name.?,
                .pat = pat,
                .shorthand = shorthand,
            });
            field_name = null;
        }
        const field_values = try fields.toOwnedSlice(allocator);
        errdefer freeDecodedFieldPats(allocator, field_values);
        const rest = try reqBool(t, "rest");
        return .{ .struct_pat = .{
            .def = def,
            .fields = field_values,
            .rest = rest,
        } };
    }
    if (std.mem.eql(u8, tag, "reference")) {
        const t = try getObj(val);
        return .{ .reference = .{
            .mode = try decodeBindMode(try reqStr(t, "mode")),
            .inner = try reqU32(t, "inner"),
        } };
    }
    if (std.mem.eql(u8, tag, "or")) {
        const t = try getObj(val);
        return .{ .@"or" = .{ .alternatives = try decodeIdList(allocator, try req(t, "alternatives")) } };
    }
    if (std.mem.eql(u8, tag, "range")) {
        const t = try getObj(val);
        return .{ .range = .{
            .lo = try reqOptionalId(t, "lo"),
            .hi = try reqOptionalId(t, "hi"),
            .inclusive = try reqBool(t, "inclusive"),
        } };
    }
    if (std.mem.eql(u8, tag, "unsupported")) {
        const t = try getObj(val);
        const reason = try allocator.dupe(u8, try reqStr(t, "reason"));
        errdefer allocator.free(reason);
        const suggested_version = try decodeUnsupportedVersion(
            try reqStr(t, "suggested_version"),
        );
        return .{ .unsupported = .{
            .reason = reason,
            .suggested_version = suggested_version,
        } };
    }
    return error.BadWireFormat;
}

fn decodePattern(allocator: std.mem.Allocator, v: Json) !exprs.Pattern {
    const o = try getObj(v);
    return .{
        .id = try reqU32(o, "id"),
        .span = try decodeSpan(try req(o, "span")),
        .ty = try reqOptionalId(o, "ty"),
        .kind = try decodePatternKind(allocator, try reqStr(o, "kind"), try req(o, "value")),
    };
}

// ── Statements ──────────────────────────────────────────────────────────────

fn decodeStatementKind(allocator: std.mem.Allocator, tag: []const u8, val: Json) !exprs.StatementKind {
    if (std.mem.eql(u8, tag, "let")) {
        const q = try getObj(val);
        return .{ .let = .{
            .pattern = try reqU32(q, "pattern"),
            .init = try reqOptionalId(q, "init"),
            .ty = try reqOptionalId(q, "ty"),
        } };
    }
    if (std.mem.eql(u8, tag, "let_else")) {
        const q = try getObj(val);
        return .{ .let_else = .{
            .pattern = try reqU32(q, "pattern"),
            .init = try reqU32(q, "init"),
            .else_block = try decodeBlockExpr(allocator, try req(q, "else_block")),
        } };
    }
    if (std.mem.eql(u8, tag, "expr")) {
        const e = switch (val) {
            .integer => |i| i,
            else => return error.BadWireFormat,
        };
        return .{ .expr = try checkedU32(e) };
    }
    if (std.mem.eql(u8, tag, "item")) {
        const e = switch (val) {
            .integer => |i| i,
            else => return error.BadWireFormat,
        };
        return .{ .item = try checkedU32(e) };
    }
    return error.BadWireFormat;
}

fn decodeStatement(allocator: std.mem.Allocator, v: Json) !exprs.Statement {
    const o = try getObj(v);
    return .{
        .id = try reqU32(o, "id"),
        .span = try decodeSpan(try req(o, "span")),
        .ty = try reqOptionalId(o, "ty"),
        .kind = try decodeStatementKind(allocator, try reqStr(o, "kind"), try req(o, "value")),
    };
}

fn decodeField(allocator: std.mem.Allocator, v: Json) !items.Field {
    const o = try getObj(v);
    const name = try allocator.dupe(u8, try reqStr(o, "name"));
    errdefer allocator.free(name);
    const ty = try decodeType(allocator, try req(o, "ty"));
    const visibility = try decodeVisibility(
        allocator,
        o.get("vis") orelse o.get("visibility") orelse return error.MissingField,
    );
    errdefer freeDecodedVisibility(allocator, visibility);
    return .{
        .name = name,
        .ty = ty,
        .visibility = visibility,
        .span = try decodeSpan(try req(o, "span")),
    };
}
fn decodeParam(allocator: std.mem.Allocator, v: Json) !items.Param {
    const o = try getObj(v);
    const name = try allocator.dupe(u8, try reqStr(o, "name"));
    errdefer allocator.free(name);
    const ty = try decodeType(allocator, try req(o, "ty"));
    const span = try decodeSpan(try req(o, "span"));
    return .{
        .name = name,
        .ty = ty,
        .span = span,
    };
}

fn decodeEnumKind(value: []const u8) !items.enum_kind {
    if (std.mem.eql(u8, value, "c_like")) return .c_like;
    if (std.mem.eql(u8, value, "data")) return .data;
    if (std.mem.eql(u8, value, "mixed")) return .mixed;
    return error.BadWireFormat;
}

fn decodeIntRepr(value: []const u8) !items.int_repr {
    return std.meta.stringToEnum(items.int_repr, value) orelse error.BadWireFormat;
}

fn decodeVariant(allocator: std.mem.Allocator, v: Json) !items.Variant {
    const o = try getObj(v);
    const name = try allocator.dupe(u8, try reqStr(o, "name"));
    errdefer allocator.free(name);
    const fields_obj = try getObj(try req(o, "fields"));
    const has_tuple = fields_obj.get("tuple") != null;
    const has_named = fields_obj.get("named") != null;
    const has_plain = fields_obj.get("plain") != null;
    if (has_tuple and has_named) return error.BadWireFormat;
    if (has_tuple and has_plain) return error.BadWireFormat;
    if (has_named and has_plain) return error.BadWireFormat;
    if (!has_tuple and !has_named and !has_plain) return error.BadWireFormat;
    const fields: items.VariantFields = if (has_tuple) blk: {
        const tuple_value = fields_obj.get("tuple") orelse return error.BadWireFormat;
        break :blk .{ .tuple = try decodeTypeList(allocator, tuple_value) };
    } else if (has_named) blk: {
        const named_value = fields_obj.get("named") orelse return error.BadWireFormat;
        break :blk .{ .named = try decodeFields(allocator, named_value) };
    } else blk: {
        if (!try reqBool(fields_obj, "plain")) return error.BadWireFormat;
        break :blk .none;
    };
    const discriminant = switch (try req(o, "discriminant")) {
        .integer => |integer| integer,
        .string => |text| std.fmt.parseInt(i128, text, 10) catch return error.BadWireFormat,
        .null => null,
        else => return error.BadWireFormat,
    };
    return .{ .name = name, .fields = fields, .discriminant = discriminant };
}
fn decodeParams(allocator: std.mem.Allocator, v: Json) ![]const items.Param {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(items.Param) = .empty;
    errdefer freeDecodedParamList(allocator, &list);
    for (arr.items) |item| {
        try list.append(allocator, try decodeParam(allocator, item));
    }
    return list.toOwnedSlice(allocator);
}

fn decodeFields(allocator: std.mem.Allocator, v: Json) ![]const items.Field {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(items.Field) = .empty;
    errdefer list.deinit(allocator);
    for (arr.items) |item| {
        try list.append(allocator, try decodeField(allocator, item));
    }
    return list.toOwnedSlice(allocator);
}

fn decodeVariants(allocator: std.mem.Allocator, v: Json) ![]const items.Variant {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(items.Variant) = .empty;
    errdefer list.deinit(allocator);
    for (arr.items) |item| {
        try list.append(allocator, try decodeVariant(allocator, item));
    }
    return list.toOwnedSlice(allocator);
}

fn decodeReceiverField(o: ObjectMap, key: []const u8) !?items.Receiver {
    return switch (try req(o, key)) {
        .null => null,
        .string => |name| try decodeReceiver(name),
        else => error.BadWireFormat,
    };
}

fn decodeStructMethod(allocator: std.mem.Allocator, v: Json) !StructMethod {
    const o = try getObj(v);
    const name = try allocator.dupe(u8, try reqStr(o, "name"));
    errdefer allocator.free(name);
    const visibility = try decodeVisibility(
        allocator,
        o.get("visibility") orelse o.get("vis") orelse return error.MissingField,
    );
    errdefer freeDecodedVisibility(allocator, visibility);
    const params = try decodeParams(allocator, try req(o, "params"));
    errdefer freeDecodedParams(allocator, params);
    const ret = try decodeType(allocator, try req(o, "ret"));
    const generic_params = try decodeStringList(allocator, try req(o, "generic_params"));
    errdefer freeDecodedStringList(allocator, generic_params);
    return .{
        .name = name,
        .visibility = visibility,
        .params = params,
        .ret = ret,
        .generic_params = generic_params,
        .body = try reqU32(o, "body"),
        .receiver = try decodeReceiverField(o, "receiver"),
        .is_allocating = try reqBool(o, "is_allocating"),
    };
}

fn decodeStructMethods(allocator: std.mem.Allocator, v: Json) ![]const StructMethod {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(StructMethod) = .empty;
    errdefer list.deinit(allocator);
    for (arr.items) |item| {
        try list.append(allocator, try decodeStructMethod(allocator, item));
    }
    return list.toOwnedSlice(allocator);
}

fn decodeTraitMethod(allocator: std.mem.Allocator, v: Json) !TraitMethodSig {
    const o = try getObj(v);
    const name = try allocator.dupe(u8, try reqStr(o, "name"));
    errdefer allocator.free(name);
    const params = try decodeParams(allocator, try req(o, "params"));
    errdefer freeDecodedParams(allocator, params);
    const ret = try decodeType(allocator, try req(o, "ret"));
    return .{
        .name = name,
        .params = params,
        .ret = ret,
        .receiver = try decodeReceiver(try reqStr(o, "receiver")),
    };
}

fn decodeTraitMethods(allocator: std.mem.Allocator, v: Json) ![]const TraitMethodSig {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(TraitMethodSig) = .empty;
    errdefer list.deinit(allocator);
    for (arr.items) |item| {
        try list.append(allocator, try decodeTraitMethod(allocator, item));
    }
    return list.toOwnedSlice(allocator);
}

fn decodeBodyKind(allocator: std.mem.Allocator, v: Json) !BodyKind {
    const o = try getObj(v);
    const kind_str = try reqStr(o, "kind");
    if (std.mem.eql(u8, kind_str, "none")) return .none;
    if (std.mem.eql(u8, kind_str, "const_")) {
        const co = try getObj(try req(o, "value"));
        return .{ .const_ = .{
            .ty = try decodeType(allocator, try req(co, "ty")),
            .init = try reqU32(co, "init"),
        } };
    }
    if (std.mem.eql(u8, kind_str, "fn_")) {
        const fo = try getObj(try req(o, "value"));
        return .{ .fn_ = .{
            .params = try decodeParams(allocator, try req(fo, "params")),
            .ret = try decodeType(allocator, try req(fo, "ret")),
            .generic_params = try decodeStringList(allocator, try req(fo, "generic_params")),
            .body = try reqU32(fo, "body"),
            .is_allocating = try reqBool(fo, "is_allocating"),
        } };
    }
    if (std.mem.eql(u8, kind_str, "struct_")) {
        const so = try getObj(try req(o, "value"));
        const layout_name = try reqStr(so, "layout");
        const layout: items.struct_kind = if (std.mem.eql(u8, layout_name, "named"))
            .named
        else if (std.mem.eql(u8, layout_name, "tuple"))
            .tuple
        else if (std.mem.eql(u8, layout_name, "unit"))
            .unit
        else
            return error.BadWireFormat;
        return .{ .struct_ = .{
            .generic_params = try decodeStringList(allocator, try req(so, "generic_params")),
            .trait_bounds = try decodeStringList(allocator, try req(so, "trait_bounds")),
            .layout = layout,
            .fields = try decodeFields(allocator, try req(so, "fields")),
            .methods = try decodeStructMethods(allocator, try req(so, "methods")),
            .has_dynamic_resources = try reqBool(so, "has_dynamic_resources"),
        } };
    }
    if (std.mem.eql(u8, kind_str, "enum_")) {
        const eo = try getObj(try req(o, "value"));
        const repr_value = try req(eo, "repr_int");
        return .{ .enum_ = .{
            .kind = try decodeEnumKind(try reqStr(eo, "kind")),
            .variants = try decodeVariants(allocator, try req(eo, "variants")),
            .repr_int = switch (repr_value) {
                .string => |name| try decodeIntRepr(name),
                .null => null,
                else => return error.BadWireFormat,
            },
            .non_exhaustive = try reqBool(eo, "non_exhaustive"),
        } };
    }
    if (std.mem.eql(u8, kind_str, "trait_")) {
        const to = try getObj(try req(o, "value"));
        const name = try allocator.dupe(u8, try reqStr(to, "name"));
        errdefer allocator.free(name);
        const supertraits = try decodeStringList(allocator, try req(to, "supertraits"));
        errdefer freeDecodedStringList(allocator, supertraits);
        const methods = try decodeTraitMethods(allocator, try req(to, "methods"));
        return .{ .trait_ = .{
            .name = name,
            .supertraits = supertraits,
            .methods = methods,
        } };
    }
    if (std.mem.eql(u8, kind_str, "type_alias")) {
        const ao = try getObj(try req(o, "value"));
        return .{ .type_alias = .{
            .target = try decodeType(allocator, try req(ao, "target")),
        } };
    }
    return error.BadWireFormat;
}

fn freeDecodedBodyParams(allocator: std.mem.Allocator, params: []const items.Param) void {
    for (params) |param| {
        allocator.free(param.name);
        freeDecodedType(allocator, param.ty);
    }
    if (params.len > 0) allocator.free(params);
}

fn freeDecodedBodyFields(allocator: std.mem.Allocator, fields: []const items.Field) void {
    for (fields) |field| {
        allocator.free(field.name);
        freeDecodedType(allocator, field.ty);
        freeDecodedVisibility(allocator, field.visibility);
    }
    if (fields.len > 0) allocator.free(fields);
}

fn freeDecodedBodyVariants(allocator: std.mem.Allocator, variants: []const items.Variant) void {
    for (variants) |variant| {
        allocator.free(variant.name);
        switch (variant.fields) {
            .none => {},
            .tuple => |fields| freeDecodedTypeSlice(allocator, fields),
            .named => |fields| freeDecodedBodyFields(allocator, fields),
        }
    }
    if (variants.len > 0) allocator.free(variants);
}

fn freeDecodedStructMethods(allocator: std.mem.Allocator, methods: []const StructMethod) void {
    for (methods) |method| {
        allocator.free(method.name);
        freeDecodedVisibility(allocator, method.visibility);
        freeDecodedBodyParams(allocator, method.params);
        freeDecodedType(allocator, method.ret);
        freeDecodedStringList(allocator, method.generic_params);
    }
    if (methods.len > 0) allocator.free(methods);
}

fn freeDecodedTraitMethods(allocator: std.mem.Allocator, methods: []const TraitMethodSig) void {
    for (methods) |method| {
        allocator.free(method.name);
        freeDecodedBodyParams(allocator, method.params);
        freeDecodedType(allocator, method.ret);
    }
    if (methods.len > 0) allocator.free(methods);
}

fn freeDecodedLiteral(allocator: std.mem.Allocator, literal: exprs.Literal) void {
    switch (literal) {
        .int => |int| {
            allocator.free(int.text);
            if (int.ty_suffix) |suffix| allocator.free(suffix);
        },
        .float => |float| allocator.free(float.text),
        .character => |character| allocator.free(character.text),
        .string => |string| allocator.free(string.bytes),
        .byte_array => |byte_array| {
            if (byte_array.items.len > 0) allocator.free(byte_array.items);
        },
        .boolean => {},
    }
}

fn freeDecodedBlockExpr(allocator: std.mem.Allocator, block: exprs.BlockExpr) void {
    if (block.statements.len > 0) allocator.free(block.statements);
    if (block.labelled) |labelled| allocator.free(labelled);
}

fn freeDecodedElseBranch(allocator: std.mem.Allocator, branch: exprs.ElseBranch) void {
    switch (branch) {
        .none, .chain => {},
        .block => |block| freeDecodedBlockExpr(allocator, block),
    }
}

fn freeDecodedIterKind(allocator: std.mem.Allocator, iter_kind: exprs.IterKind) void {
    switch (iter_kind) {
        .range, .slice, .enumerate => {},
        .multi => |elements| {
            if (elements.len > 0) allocator.free(elements);
        },
        .adapter => |chain| freeDecodedIteratorChain(allocator, chain),
    }
}

fn freeDecodedClosure(allocator: std.mem.Allocator, closure: exprs.ClosureExpr) void {
    for (closure.captures) |capture| allocator.free(capture.name);
    if (closure.captures.len > 0) allocator.free(closure.captures);
    if (closure.params.len > 0) allocator.free(closure.params);
    freeDecodedBlockExpr(allocator, closure.body);
}

fn freeDecodedIteratorChain(
    allocator: std.mem.Allocator,
    chain: exprs.IteratorChainExpr,
) void {
    for (chain.adapters) |adapter| {
        switch (adapter) {
            .map => |map| freeDecodedClosure(allocator, map.closure),
            .filter => |filter| freeDecodedClosure(allocator, filter.closure),
            .flat_map => |closure| freeDecodedClosure(allocator, closure),
            .enumerate, .zip, .range_rev => {},
            .other => |unsupported| allocator.free(unsupported.reason),
        }
    }
    if (chain.adapters.len > 0) allocator.free(chain.adapters);
}

fn freeDecodedExprKind(allocator: std.mem.Allocator, kind: exprs.ExprKind) void {
    switch (kind) {
        .literal => |literal| freeDecodedLiteral(allocator, literal),
        .array => |array| {
            if (array.elements.len > 0) allocator.free(array.elements);
        },
        .vec_lit => |vec_lit| {
            if (vec_lit.elements.len > 0) allocator.free(vec_lit.elements);
        },
        .range => {},
        .path => |path| freeDecodedTypeSlice(allocator, path.generic_args),
        .block => |block| freeDecodedBlockExpr(allocator, block),
        .unit => {},
        .if_else => |if_else| {
            freeDecodedBlockExpr(allocator, if_else.then_);
            freeDecodedElseBranch(allocator, if_else.@"else");
        },
        .if_let => |if_let| {
            freeDecodedBlockExpr(allocator, if_let.then_);
            freeDecodedElseBranch(allocator, if_let.@"else");
        },
        .match => |match| {
            for (match.arms) |arm| {
                if (arm.patterns.len > 0) allocator.free(arm.patterns);
            }
            if (match.arms.len > 0) allocator.free(match.arms);
        },
        .loop_ => |loop| freeDecodedBlockExpr(allocator, loop.body),
        .while_ => |while_| freeDecodedBlockExpr(allocator, while_.body),
        .for_ => |for_| {
            freeDecodedBlockExpr(allocator, for_.body);
            freeDecodedIterKind(allocator, for_.iter_kind);
        },
        .break_ => |break_| {
            if (break_.label) |label| allocator.free(label);
        },
        .continue_ => |continue_| {
            if (continue_.label) |label| allocator.free(label);
        },
        .call => |call| {
            if (call.args.len > 0) allocator.free(call.args);
        },
        .method_call => |method_call| {
            if (method_call.args.len > 0) allocator.free(method_call.args);
        },
        .struct_lit => |struct_lit| freeDecodedFieldInits(allocator, struct_lit.fields),
        .enum_variant => |enum_variant| {
            allocator.free(enum_variant.variant);
            if (enum_variant.tuple_fields.len > 0) allocator.free(enum_variant.tuple_fields);
            freeDecodedFieldInits(allocator, enum_variant.named_fields);
        },
        .field => |field| allocator.free(field.field),
        .index => {},
        .cast => |cast| freeDecodedType(allocator, cast.source_type),
        .binary, .unary, .assign, .try_, .return_ => {},
        .closure => |closure| freeDecodedClosure(allocator, closure),
        .iterator_chain => |chain| freeDecodedIteratorChain(allocator, chain),
        .unsupported => |unsupported| allocator.free(unsupported.reason),
    }
}

fn freeDecodedExpr(allocator: std.mem.Allocator, expr: exprs.Expr) void {
    freeDecodedExprKind(allocator, expr.kind);
}

fn freeDecodedExprs(allocator: std.mem.Allocator, values: []const exprs.Expr) void {
    for (values) |value| freeDecodedExpr(allocator, value);
    if (values.len > 0) allocator.free(values);
}

fn freeDecodedPatternKind(allocator: std.mem.Allocator, kind: exprs.PatternKind) void {
    switch (kind) {
        .wildcard => {},
        .binding => |binding| allocator.free(binding.name),
        .literal => |literal| freeDecodedLiteral(allocator, literal),
        .path => |path| {
            if (path.variant) |variant| allocator.free(variant);
        },
        .tuple => |tuple| {
            if (tuple.elements.len > 0) allocator.free(tuple.elements);
        },
        .slice => |slice| {
            if (slice.elements.len > 0) allocator.free(slice.elements);
        },
        .struct_pat => |struct_pat| freeDecodedFieldPats(allocator, struct_pat.fields),
        .reference => {},
        .@"or" => |or_pat| {
            if (or_pat.alternatives.len > 0) allocator.free(or_pat.alternatives);
        },
        .range => {},
        .unsupported => |unsupported| allocator.free(unsupported.reason),
    }
}

fn freeDecodedPattern(allocator: std.mem.Allocator, pattern: exprs.Pattern) void {
    freeDecodedPatternKind(allocator, pattern.kind);
}

fn freeDecodedPatterns(allocator: std.mem.Allocator, values: []const exprs.Pattern) void {
    for (values) |value| freeDecodedPattern(allocator, value);
    if (values.len > 0) allocator.free(values);
}

fn freeDecodedStatement(allocator: std.mem.Allocator, statement: exprs.Statement) void {
    switch (statement.kind) {
        .let, .expr, .item => {},
        .let_else => |let_else| freeDecodedBlockExpr(allocator, let_else.else_block),
    }
}

fn freeDecodedStatements(
    allocator: std.mem.Allocator,
    values: []const exprs.Statement,
) void {
    for (values) |value| freeDecodedStatement(allocator, value);
    if (values.len > 0) allocator.free(values);
}

fn freeDecodedBodies(allocator: std.mem.Allocator, decoded: Bodies) void {
    freeDecodedExprs(allocator, decoded.exprs);
    freeDecodedStatements(allocator, decoded.stmts);
    freeDecodedPatterns(allocator, decoded.pats);
    freeDecodedTypeSlice(allocator, decoded.types);
    freeDecodedBodyKinds(allocator, decoded.bodies);
}

fn freeDecodedBodyKind(allocator: std.mem.Allocator, body: BodyKind) void {
    switch (body) {
        .none => {},
        .const_ => |const_body| freeDecodedType(allocator, const_body.ty),
        .fn_ => |fn_body| {
            freeDecodedBodyParams(allocator, fn_body.params);
            freeDecodedType(allocator, fn_body.ret);
            freeDecodedStringList(allocator, fn_body.generic_params);
        },
        .struct_ => |struct_body| {
            freeDecodedStringList(allocator, struct_body.generic_params);
            freeDecodedStringList(allocator, struct_body.trait_bounds);
            freeDecodedBodyFields(allocator, struct_body.fields);
            freeDecodedStructMethods(allocator, struct_body.methods);
        },
        .enum_ => |enum_body| freeDecodedBodyVariants(allocator, enum_body.variants),
        .trait_ => |trait_body| {
            allocator.free(trait_body.name);
            freeDecodedStringList(allocator, trait_body.supertraits);
            freeDecodedTraitMethods(allocator, trait_body.methods);
        },
        .type_alias => |alias_body| freeDecodedType(allocator, alias_body.target),
    }
}

fn freeDecodedBodyKinds(allocator: std.mem.Allocator, body_kinds: []const BodyKind) void {
    for (body_kinds) |body| freeDecodedBodyKind(allocator, body);
    if (body_kinds.len > 0) allocator.free(body_kinds);
}

fn bodyKindMatchesEntity(entity_kind: spine.EntityKind, body_kind: BodyKind) bool {
    switch (body_kind) {
        .none => return true,
        else => {},
    }
    return switch (entity_kind) {
        .fn_ => switch (body_kind) {
            .fn_ => true,
            else => false,
        },
        .struct_, .union_ => switch (body_kind) {
            .struct_ => true,
            else => false,
        },
        .enum_ => switch (body_kind) {
            .enum_ => true,
            else => false,
        },
        .const_, .static_ => switch (body_kind) {
            .const_ => true,
            else => false,
        },
        .type_alias => switch (body_kind) {
            .type_alias => true,
            else => false,
        },
        .trait_ => switch (body_kind) {
            .trait_ => true,
            else => false,
        },
        else => false,
    };
}

fn validateBodySlot(
    entities: []const spine.Entity,
    owner: spine.EntityId,
    body: BodyKind,
) !void {
    if (@as(usize, owner) >= entities.len) return error.InvalidBodyOwner;
    if (!bodyKindMatchesEntity(entities[owner].kind, body)) return error.BodyKindMismatch;
}

fn decodeBodySlot(allocator: std.mem.Allocator, v: Json) !BodySlot {
    const o = try getObj(v);
    const owner = @as(spine.EntityId, @intCast(try reqU32(o, "owner")));
    const body = try decodeBodyKind(allocator, try req(o, "body"));
    return .{ .owner = owner, .body = body };
}

fn decodeBodies(
    allocator: std.mem.Allocator,
    v: Json,
    entities: []const spine.Entity,
) !Bodies {
    const o = try getObj(v);

    const exprs_arr = switch (try req(o, "exprs")) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;
    errdefer exprs_list.deinit(allocator);
    for (exprs_arr.items) |ev| try exprs_list.append(allocator, try decodeExpr(allocator, ev));
    const decoded_exprs = try exprs_list.toOwnedSlice(allocator);
    errdefer allocator.free(decoded_exprs);

    const stmts_arr = switch (try req(o, "stmts")) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var stmts_list: std.ArrayListUnmanaged(exprs.Statement) = .empty;
    errdefer stmts_list.deinit(allocator);
    for (stmts_arr.items) |sv| try stmts_list.append(allocator, try decodeStatement(allocator, sv));
    const decoded_stmts = try stmts_list.toOwnedSlice(allocator);
    errdefer allocator.free(decoded_stmts);

    const pats_arr = switch (try req(o, "pats")) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var pats_list: std.ArrayListUnmanaged(exprs.Pattern) = .empty;
    errdefer pats_list.deinit(allocator);
    for (pats_arr.items) |pv| try pats_list.append(allocator, try decodePattern(allocator, pv));
    const decoded_pats = try pats_list.toOwnedSlice(allocator);
    errdefer allocator.free(decoded_pats);

    const types_arr = switch (try req(o, "types")) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    errdefer freeDecodedTypeList(allocator, &types_list);
    for (types_arr.items) |tv| try types_list.append(allocator, try decodeType(allocator, tv));
    const decoded_types = try types_list.toOwnedSlice(allocator);
    errdefer freeDecodedTypeSlice(allocator, decoded_types);

    const bodies_arr = switch (try req(o, "bodies")) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    if (bodies_arr.items.len != entities.len) return error.InvalidBodyTable;
    const decoded_bodies = try allocator.alloc(BodyKind, entities.len);
    errdefer freeDecodedBodyKinds(allocator, decoded_bodies);
    for (decoded_bodies) |*body| body.* = .none;
    const seen = try allocator.alloc(bool, entities.len);
    defer allocator.free(seen);
    @memset(seen, false);
    for (bodies_arr.items) |body_value| {
        const slot = try decodeBodySlot(allocator, body_value);
        validateBodySlot(entities, slot.owner, slot.body) catch |err| {
            freeDecodedBodyKind(allocator, slot.body);
            return err;
        };
        if (seen[slot.owner]) {
            freeDecodedBodyKind(allocator, slot.body);
            return error.InvalidBodyOwner;
        }
        seen[slot.owner] = true;
        decoded_bodies[slot.owner] = slot.body;
    }
    for (seen) |was_seen| {
        if (!was_seen) return error.InvalidBodyTable;
    }

    return .{
        .exprs = decoded_exprs,
        .stmts = decoded_stmts,
        .pats = decoded_pats,
        .types = decoded_types,
        .bodies = decoded_bodies,
    };
}

pub fn emptyBodies() Bodies {
    return .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{},
    };
}

fn decodeGraph(allocator: std.mem.Allocator, root_map: ObjectMap) !graph.CrateGraph {
    var g = graph.CrateGraph.init(allocator);
    errdefer g.deinit();
    if (try optStr(root_map, "sidecar")) |s| g.sidecar = try allocator.dupe(u8, s);
    if (try optStr(root_map, "toolchain")) |t| g.toolchain = try allocator.dupe(u8, t);

    const crates_arr = switch (try req(root_map, "crates")) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    for (crates_arr.items) |cratev| {
        const c = try getObj(cratev);
        const name = try allocator.dupe(u8, try reqStr(c, "name"));
        var name_transferred = false;
        errdefer if (!name_transferred) allocator.free(name);
        const edition_value = try reqU32(c, "edition");
        if (edition_value > @as(u32, std.math.maxInt(u16))) return error.BadWireFormat;
        const edition: u16 = @intCast(edition_value);
        const kind: graph.CrateKind = try decodeCrateKind(try reqStr(c, "kind"));
        const root: spine.EntityId = @intCast(try reqU32(c, "root"));
        const is_translated = try reqBool(c, "is_translated");
        const deps = try decodeDeps(allocator, try req(c, "deps"));
        var deps_transferred = false;
        errdefer if (!deps_transferred) freeDecodedDeps(allocator, deps);

        const entities_arr = switch (try req(c, "entities")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        for (entities_arr.items) |ev| {
            const e = try decodeEntity(allocator, ev);
            var entity_transferred = false;
            errdefer if (!entity_transferred) freeDecodedEntity(allocator, e);
            if (@as(usize, e.id) != g.symbol_table.entities.items.len) {
                return error.InvalidEntityId;
            }
            _ = try g.symbol_table.add(e);
            entity_transferred = true;
        }
        const modules_arr = switch (try req(c, "modules")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        for (modules_arr.items) |mv| {
            const m = try decodeModule(allocator, mv);
            var module_transferred = false;
            errdefer if (!module_transferred) freeDecodedModule(allocator, m);
            if (@as(usize, m.id) != g.modules.items.len) return error.InvalidModuleId;
            _ = try g.addModule(m);
            module_transferred = true;
        }
        const uses_arr = switch (try req(c, "uses")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        for (uses_arr.items) |uv| {
            const u = try decodeUseDecl(allocator, uv);
            var use_transferred = false;
            errdefer if (!use_transferred) freeDecodedUseDecl(allocator, u);
            if (g.useById(u.id) != null) return error.InvalidUseMetadata;
            try g.addUse(u);
            use_transferred = true;
        }

        try g.addCrate(.{
            .name = name,
            .edition = edition,
            .kind = kind,
            .root = root,
            .deps = deps,
            .is_translated = is_translated,
        });
        name_transferred = true;
        deps_transferred = true;
    }
    try g.validateTopology();
    return g;
}

// ---------------------------------------------------------------------------
// Encode Helpers
// ---------------------------------------------------------------------------

fn freeValue(allocator: std.mem.Allocator, v: *Json) void {
    switch (v.*) {
        .object => |*o| {
            var it = o.iterator();
            while (it.next()) |entry| freeValue(allocator, entry.value_ptr);
            o.deinit(allocator);
        },
        .array => |*ar| {
            for (ar.items) |*item| freeValue(allocator, item);
            ar.deinit();
        },
        else => {},
    }
}

fn mkInt(x: anytype) Json {
    return .{ .integer = @intCast(x) };
}

fn encodeOptStr(s: ?[]const u8) Json {
    return if (s) |x| .{ .string = x } else .{ .null = {} };
}

fn encodeOptBool(value: ?bool) Json {
    return if (value) |bool_value| .{ .bool = bool_value } else .{ .null = {} };
}

fn encodeOptId(id: ?spine.EntityId) Json {
    return if (id) |x| mkInt(x) else .{ .null = {} };
}

fn encodeSpan(allocator: std.mem.Allocator, s: spine.Span) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "start_line", mkInt(s.start_line));
    try o.put(allocator, "start_col", mkInt(s.start_col));
    try o.put(allocator, "end_line", mkInt(s.end_line));
    try o.put(allocator, "end_col", mkInt(s.end_col));
    return .{ .object = o };
}

fn encodeVisibility(allocator: std.mem.Allocator, v: spine.Visibility) !Json {
    var o = ObjectMap.empty;
    switch (v) {
        .public => try o.put(allocator, "kind", .{ .string = "public" }),
        .crate_restricted => try o.put(allocator, "kind", .{ .string = "crate_restricted" }),
        .super_restricted => try o.put(allocator, "kind", .{ .string = "super_restricted" }),
        .private => try o.put(allocator, "kind", .{ .string = "private" }),
        .in_path => |p| {
            try o.put(allocator, "kind", .{ .string = "in_path" });
            try o.put(allocator, "path", .{ .string = p });
        },
    }
    return .{ .object = o };
}

fn encodeAttributes(allocator: std.mem.Allocator, attrs: []const spine.Attribute) !Json {
    var arr = Array.init(allocator);
    for (attrs) |at| {
        var o = ObjectMap.empty;
        try o.put(allocator, "name", .{ .string = at.name });
        try o.put(allocator, "meta", .{ .string = at.meta });
        try o.put(allocator, "known", .{ .bool = at.known });
        try arr.append(.{ .object = o });
    }
    return .{ .array = arr };
}

fn entityKindTag(k: spine.EntityKind) []const u8 {
    return switch (k) {
        .crate_ => "crate_",
        .module => "module",
        .struct_ => "struct_",
        .enum_ => "enum_",
        .union_ => "union_",
        .fn_ => "fn_",
        .const_ => "const_",
        .static_ => "static_",
        .trait_ => "trait_",
        .impl_ => "impl_",
        .type_alias => "type_alias",
        .use_ => "use_",
        .extern_crate => "extern_crate",
        .macro_ => "macro_",
        .field => "field",
        .variant => "variant",
    };
}

fn encodeEntity(allocator: std.mem.Allocator, e: spine.Entity) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "id", mkInt(e.id));
    try o.put(allocator, "kind", .{ .string = entityKindTag(e.kind) });
    try o.put(allocator, "name", .{ .string = e.name });
    try o.put(allocator, "span", try encodeSpan(allocator, e.span));
    try o.put(allocator, "visibility", try encodeVisibility(allocator, e.visibility));
    try o.put(allocator, "parent", encodeOptId(e.parent));
    try o.put(allocator, "resolved", encodeOptId(e.resolved));
    try o.put(allocator, "renamed_to", encodeOptStr(e.renamed_to));
    try o.put(allocator, "attributes", try encodeAttributes(allocator, e.attributes));
    return .{ .object = o };
}

fn encodeModule(allocator: std.mem.Allocator, m: graph.Module) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "id", mkInt(m.id));
    const kind = switch (m.kind) {
        .root => "root",
        .@"inline" => "inline",
        .file => "file",
        .directory => "directory",
    };
    try o.put(allocator, "kind", .{ .string = kind });
    try o.put(allocator, "name", .{ .string = m.name });
    try o.put(allocator, "parent", encodeOptId(m.parent));
    try o.put(allocator, "source_path", encodeOptStr(m.source_path));
    try o.put(allocator, "is_crate", .{ .bool = m.is_crate });
    try o.put(allocator, "is_extern", .{ .bool = m.is_extern });
    try o.put(allocator, "span", try encodeSpan(allocator, m.span));
    var items_arr = Array.init(allocator);
    for (m.items) |it| try items_arr.append(mkInt(it));
    try o.put(allocator, "items", .{ .array = items_arr });
    try o.put(allocator, "attributes", try encodeAttributes(allocator, m.attributes));
    return .{ .object = o };
}

fn encodeUseDecl(allocator: std.mem.Allocator, u: graph.UseDecl) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "id", mkInt(u.id));
    const kind = switch (u.kind) {
        .plain => "plain",
        .alias => "alias",
        .glob => "glob",
        .external => "external",
    };
    try o.put(allocator, "kind", .{ .string = kind });
    switch (u.kind) {
        .external => |external| try o.put(
            allocator,
            "path",
            try encodeStringList(allocator, external.path),
        ),
        else => {},
    }
    try o.put(allocator, "local_name", .{ .string = u.local_name });
    try o.put(allocator, "is_pub_export", .{ .bool = u.is_pub_export });
    try o.put(allocator, "target", mkInt(u.target));
    try o.put(allocator, "span", try encodeSpan(allocator, u.span));
    return .{ .object = o };
}

fn encodeDep(allocator: std.mem.Allocator, d: graph.CrateDep) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "extern_name", .{ .string = d.extern_name });
    try o.put(allocator, "local_alias", .{ .string = d.local_alias });
    try o.put(allocator, "id", mkInt(d.id));
    try o.put(allocator, "version", encodeOptStr(d.version));
    try o.put(allocator, "path", encodeOptStr(d.path));
    try o.put(allocator, "git", encodeOptStr(d.git));
    try o.put(allocator, "optional", .{ .bool = d.optional });
    try o.put(allocator, "default_features", encodeOptBool(d.default_features));
    try o.put(allocator, "features", try encodeStringList(allocator, d.features));
    return .{ .object = o };
}

fn crateMembers(
    allocator: std.mem.Allocator,
    g: *const graph.CrateGraph,
    root: spine.EntityId,
) ![]bool {
    try g.validateTopology();
    if (@as(usize, root) >= g.symbol_table.count()) return error.MissingRootModule;
    if (g.moduleForEntity(root) == null) return error.MissingRootModule;

    const member = try allocator.alloc(bool, g.symbol_table.count());
    errdefer allocator.free(member);
    @memset(member, false);
    for (g.symbol_table.entities.items) |entity| {
        if (g.entityBelongsToRoot(entity.id, root)) member[entity.id] = true;
    }
    for (g.modules.items) |module_row| {
        const module_entity_id = g.moduleEntityId(&module_row) orelse
            return error.InvalidModuleEntity;
        if (g.entityBelongsToRoot(module_entity_id, root)) {
            member[module_entity_id] = true;
        }
    }
    if (!member[root]) return error.MissingRootModule;
    return member;
}

fn encodeCrate(
    allocator: std.mem.Allocator,
    g: *const graph.CrateGraph,
    c: graph.Crate,
    member: []bool,
) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = c.name });
    try o.put(allocator, "edition", mkInt(c.edition));
    const kind = switch (c.kind) {
        .lib => "lib",
        .bin => "bin",
    };
    try o.put(allocator, "kind", .{ .string = kind });
    try o.put(allocator, "root", mkInt(c.root));
    try o.put(allocator, "is_translated", .{ .bool = c.is_translated });

    var deps = Array.init(allocator);
    for (c.deps) |d| try deps.append(try encodeDep(allocator, d));
    try o.put(allocator, "deps", .{ .array = deps });

    var mods = Array.init(allocator);
    for (g.modules.items) |module_row| {
        const module_entity_id = g.moduleEntityId(&module_row) orelse
            return error.InvalidModuleEntity;
        if (@as(usize, module_entity_id) >= member.len) return error.InvalidModuleEntity;
        if (member[module_entity_id]) {
            try mods.append(try encodeModule(allocator, module_row));
        }
    }
    try o.put(allocator, "modules", .{ .array = mods });

    var ents = Array.init(allocator);
    var idx: usize = 0;
    while (idx < g.symbol_table.count()) : (idx += 1) {
        if (member[idx]) try ents.append(try encodeEntity(allocator, g.symbol_table.entities.items[idx]));
    }
    try o.put(allocator, "entities", .{ .array = ents });

    const source_uses: []const graph.UseDecl = g.uses.items;
    var encoded_uses = Array.init(allocator);
    for (source_uses) |use_decl| {
        if (@as(usize, use_decl.id) >= member.len) return error.InvalidUseMetadata;
        if (member[use_decl.id]) {
            const encoded_use = try encodeUseDecl(allocator, use_decl);
            try encoded_uses.append(encoded_use);
        }
    }
    try o.put(allocator, "uses", .{ .array = encoded_uses });

    return .{ .object = o };
}

fn encodeIdList(allocator: std.mem.Allocator, ids: []const exprs.NodeId) !Json {
    var arr = Array.init(allocator);
    for (ids) |id| try arr.append(mkInt(id));
    return .{ .array = arr };
}

fn encodeTypeList(allocator: std.mem.Allocator, tys: []const types.Type) anyerror!Json {
    var arr = Array.init(allocator);
    for (tys) |t| try arr.append(try encodeType(allocator, t));
    return .{ .array = arr };
}

fn encodeInstantiation(
    allocator: std.mem.Allocator,
    instantiation: types.Instantiation,
) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "generic_id", mkInt(instantiation.generic_id));
    var args = ObjectMap.empty;
    try args.put(allocator, "params", try encodeTypeList(allocator, instantiation.args.params));
    try o.put(allocator, "args", .{ .object = args });
    try o.put(allocator, "zig_suffix", .{ .string = instantiation.zig_suffix });
    return .{ .object = o };
}

fn encodeInstantiations(
    allocator: std.mem.Allocator,
    instantiations: []const types.Instantiation,
) !Json {
    var arr = Array.init(allocator);
    for (instantiations) |instantiation| {
        try arr.append(try encodeInstantiation(allocator, instantiation));
    }
    return .{ .array = arr };
}

fn encodeIntLit(allocator: std.mem.Allocator, lit: exprs.IntLit) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "text", .{ .string = lit.text });
    const val_str = try std.fmt.allocPrint(allocator, "{d}", .{lit.value});
    try o.put(allocator, "value", .{ .string = val_str });
    const base = switch (lit.base) {
        .dec => "dec",
        .hex => "hex",
        .oct => "oct",
        .bin => "bin",
    };
    try o.put(allocator, "base", .{ .string = base });
    try o.put(allocator, "ty_suffix", encodeOptStr(lit.ty_suffix));
    return .{ .object = o };
}

fn encodeFloatLit(allocator: std.mem.Allocator, lit: exprs.FloatLit) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "text", .{ .string = lit.text });
    try o.put(allocator, "value", .{ .float = lit.value });
    return .{ .object = o };
}

fn encodeCharLit(allocator: std.mem.Allocator, lit: exprs.CharLit) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "text", .{ .string = lit.text });
    try o.put(allocator, "value", mkInt(lit.value));
    return .{ .object = o };
}

fn encodeStringLit(allocator: std.mem.Allocator, lit: exprs.StringLit) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "bytes", .{ .string = lit.bytes });
    return .{ .object = o };
}

fn encodeByteArrayLit(allocator: std.mem.Allocator, lit: exprs.ByteArrayLit) !Json {
    var o = ObjectMap.empty;
    var arr = Array.init(allocator);
    for (lit.items) |byte| {
        try arr.append(mkInt(byte));
    }
    try o.put(allocator, "items", .{ .array = arr });
    return .{ .object = o };
}

fn encodeLiteralObj(allocator: std.mem.Allocator, lit: exprs.Literal) !Json {
    var o = ObjectMap.empty;
    switch (lit) {
        .int => |v| {
            try o.put(allocator, "kind", .{ .string = "int" });
            try o.put(allocator, "value", try encodeIntLit(allocator, v));
        },
        .float => |v| {
            try o.put(allocator, "kind", .{ .string = "float" });
            try o.put(allocator, "value", try encodeFloatLit(allocator, v));
        },
        .character => |v| {
            try o.put(allocator, "kind", .{ .string = "character" });
            try o.put(allocator, "value", try encodeCharLit(allocator, v));
        },
        .string => |v| {
            try o.put(allocator, "kind", .{ .string = "string" });
            try o.put(allocator, "value", try encodeStringLit(allocator, v));
        },
        .byte_array => |v| {
            try o.put(allocator, "kind", .{ .string = "byte_array" });
            try o.put(allocator, "value", try encodeByteArrayLit(allocator, v));
        },
        .boolean => |v| {
            try o.put(allocator, "kind", .{ .string = "boolean" });
            try o.put(allocator, "value", .{ .bool = v });
        },
    }
    return .{ .object = o };
}

fn hasValidTypeTag(ty: types.Type) bool {
    const union_info = @typeInfo(types.Type).@"union";
    const tag = blk: {
        @setRuntimeSafety(false);
        break :blk std.meta.activeTag(ty);
    };
    return @intFromEnum(tag) < union_info.fields.len;
}

fn encodeCorruptType(allocator: std.mem.Allocator) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "kind", .{ .string = "unsupported" });
    var vo = ObjectMap.empty;
    try vo.put(allocator, "reason", .{ .string = "std_prelude" });
    try vo.put(allocator, "message", .{ .string = "corrupt type tag" });
    try vo.put(allocator, "span", try encodeSpan(allocator, .{
        .start_line = 0,
        .start_col = 0,
        .end_line = 0,
        .end_col = 0,
    }));
    try o.put(allocator, "value", .{ .object = vo });
    return .{ .object = o };
}

fn encodeType(allocator: std.mem.Allocator, ty: types.Type) !Json {
    if (!hasValidTypeTag(ty)) return encodeCorruptType(allocator);
    var o = ObjectMap.empty;
    switch (ty) {
        .path => |p| {
            try o.put(allocator, "kind", .{ .string = "path" });
            var segs = Array.init(allocator);
            for (p.segments) |s| {
                var so = ObjectMap.empty;
                try so.put(allocator, "name", .{ .string = s.name });
                try so.put(allocator, "id", if (s.id) |id| mkInt(id) else .{ .null = {} });
                try segs.append(.{ .object = so });
            }
            var vo = ObjectMap.empty;
            try vo.put(allocator, "segments", .{ .array = segs });
            try o.put(allocator, "value", .{ .object = vo });
        },
        .external_nominal => |external| {
            try o.put(allocator, "kind", .{ .string = "external_nominal" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "path", try encodeStringList(allocator, external.path));
            try vo.put(allocator, "args", try encodeTypeList(allocator, external.args));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .prim => |p| {
            try o.put(allocator, "kind", .{ .string = "prim" });
            try o.put(allocator, "value", .{ .string = @tagName(p) });
        },
        .reference => |r| {
            try o.put(allocator, "kind", .{ .string = "reference" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "mut", .{ .bool = r.mut });
            try vo.put(allocator, "pointee", try encodeType(allocator, r.pointee));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .raw_ptr => |r| {
            try o.put(allocator, "kind", .{ .string = "raw_ptr" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "mut", .{ .bool = r.mut });
            try vo.put(allocator, "pointee", try encodeType(allocator, r.pointee));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .slice => |s| {
            try o.put(allocator, "kind", .{ .string = "slice" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "const_", .{ .bool = s.const_ });
            try vo.put(allocator, "elem", try encodeType(allocator, s.elem));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .array => |a| {
            try o.put(allocator, "kind", .{ .string = "array" });
            var lo = ObjectMap.empty;
            switch (a.len) {
                .literal => |n| {
                    try lo.put(allocator, "kind", .{ .string = "literal" });
                    try lo.put(allocator, "value", mkInt(n));
                },
                .generic => |n| {
                    try lo.put(allocator, "kind", .{ .string = "generic" });
                    try lo.put(allocator, "value", mkInt(n));
                },
            }
            var vo = ObjectMap.empty;
            try vo.put(allocator, "elem", try encodeType(allocator, a.elem));
            try vo.put(allocator, "len", .{ .object = lo });
            try o.put(allocator, "value", .{ .object = vo });
        },
        .tuple => |t| {
            try o.put(allocator, "kind", .{ .string = "tuple" });
            try o.put(allocator, "value", try encodeTypeList(allocator, t));
        },
        .fn_ptr => |f| {
            try o.put(allocator, "kind", .{ .string = "fn_ptr" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "params", try encodeTypeList(allocator, f.params));
            try vo.put(allocator, "ret", try encodeType(allocator, f.ret));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .generic_inst => |g| {
            try o.put(allocator, "kind", .{ .string = "generic_inst" });
            var aro = ObjectMap.empty;
            try aro.put(allocator, "params", try encodeTypeList(allocator, g.args.params));
            var vo = ObjectMap.empty;
            try vo.put(allocator, "decl", mkInt(g.decl));
            try vo.put(allocator, "args", .{ .object = aro });
            try o.put(allocator, "value", .{ .object = vo });
        },
        .option => |opt| {
            try o.put(allocator, "kind", .{ .string = "option" });
            try o.put(allocator, "value", try encodeType(allocator, opt.*));
        },
        .result => |r| {
            try o.put(allocator, "kind", .{ .string = "result" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "ok", try encodeType(allocator, r.ok));
            try vo.put(allocator, "err", try encodeType(allocator, r.err));
            try vo.put(allocator, "is_error_unionable", .{ .bool = r.is_error_unionable });
            try o.put(allocator, "value", .{ .object = vo });
        },
        .boxed => |b| {
            try o.put(allocator, "kind", .{ .string = "boxed" });
            try o.put(allocator, "value", try encodeType(allocator, b.*));
        },
        .unsupported => |u| {
            try o.put(allocator, "kind", .{ .string = "unsupported" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "reason", .{ .string = @tagName(u.reason) });
            try vo.put(allocator, "message", .{ .string = u.message });
            try vo.put(allocator, "span", try encodeSpan(allocator, u.span));
            try o.put(allocator, "value", .{ .object = vo });
        },
    }
    return .{ .object = o };
}

fn encodeBlockExpr(allocator: std.mem.Allocator, b: exprs.BlockExpr) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "statements", try encodeIdList(allocator, b.statements));
    try o.put(allocator, "tail", encodeOptId(b.tail));
    try o.put(allocator, "labelled", encodeOptStr(b.labelled));
    return .{ .object = o };
}

fn encodeElseBranch(allocator: std.mem.Allocator, eb: exprs.ElseBranch) !Json {
    var o = ObjectMap.empty;
    switch (eb) {
        .none => try o.put(allocator, "kind", .{ .string = "none" }),
        .chain => |id| {
            try o.put(allocator, "kind", .{ .string = "chain" });
            try o.put(allocator, "value", mkInt(id));
        },
        .block => |bl| {
            try o.put(allocator, "kind", .{ .string = "block" });
            try o.put(allocator, "value", try encodeBlockExpr(allocator, bl));
        },
    }
    return .{ .object = o };
}

fn encodeIterKind(allocator: std.mem.Allocator, ik: exprs.IterKind) !Json {
    var o = ObjectMap.empty;
    switch (ik) {
        .range => try o.put(allocator, "kind", .{ .string = "range" }),
        .slice => try o.put(allocator, "kind", .{ .string = "slice" }),
        .enumerate => try o.put(allocator, "kind", .{ .string = "enumerate" }),
        .multi => |ids| {
            try o.put(allocator, "kind", .{ .string = "multi" });
            try o.put(allocator, "value", try encodeIdList(allocator, ids));
        },
        .adapter => return error.UnsupportedWireVariant,
    }
    return .{ .object = o };
}

fn encodeExprKind(allocator: std.mem.Allocator, kind: exprs.ExprKind) !Json {
    var o = ObjectMap.empty;
    switch (kind) {
        .literal => |v| {
            try o.put(allocator, "kind", .{ .string = "literal" });
            try o.put(allocator, "value", try encodeLiteralObj(allocator, v));
        },
        .array => |a| {
            try o.put(allocator, "kind", .{ .string = "array" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "elements", try encodeIdList(allocator, a.elements));
            try vo.put(allocator, "repeat", if (a.repeat) |r| mkInt(r) else .{ .null = {} });
            try o.put(allocator, "value", .{ .object = vo });
        },
        .vec_lit => |v| {
            try o.put(allocator, "kind", .{ .string = "vec_lit" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "elements", try encodeIdList(allocator, v.elements));
            try vo.put(allocator, "repeat", if (v.repeat) |r| mkInt(r) else .{ .null = {} });
            try o.put(allocator, "value", .{ .object = vo });
        },
        .path => |p| {
            try o.put(allocator, "kind", .{ .string = "path" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "def", mkInt(p.def));
            try vo.put(allocator, "generic_args", try encodeTypeList(allocator, p.generic_args));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .block => |bl| {
            try o.put(allocator, "kind", .{ .string = "block" });
            try o.put(allocator, "value", try encodeBlockExpr(allocator, bl));
        },
        .unit => {
            try o.put(allocator, "kind", .{ .string = "unit" });
            try o.put(allocator, "value", .{ .object = ObjectMap.empty });
        },
        .if_else => |v| {
            try o.put(allocator, "kind", .{ .string = "if_else" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "cond", mkInt(v.cond));
            try vo.put(allocator, "then", try encodeBlockExpr(allocator, v.then_));
            try vo.put(allocator, "else", try encodeElseBranch(allocator, v.@"else"));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .if_let => |v| {
            try o.put(allocator, "kind", .{ .string = "if_let" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "pattern", mkInt(v.pattern));
            try vo.put(allocator, "scrutinee", mkInt(v.scrutinee));
            try vo.put(allocator, "then", try encodeBlockExpr(allocator, v.then_));
            try vo.put(allocator, "else", try encodeElseBranch(allocator, v.@"else"));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .match => |v| {
            try o.put(allocator, "kind", .{ .string = "match" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "scrutinee", mkInt(v.scrutinee));
            var arms = Array.init(allocator);
            for (v.arms) |a| {
                var ao = ObjectMap.empty;
                try ao.put(allocator, "patterns", try encodeIdList(allocator, a.patterns));
                try ao.put(allocator, "guard", encodeOptId(a.guard));
                try ao.put(allocator, "body", mkInt(a.body));
                try arms.append(.{ .object = ao });
            }
            try vo.put(allocator, "arms", .{ .array = arms });
            try vo.put(allocator, "option_scrutinee", .{ .bool = v.option_scrutinee });
            try o.put(allocator, "value", .{ .object = vo });
        },
        .loop_ => |v| {
            try o.put(allocator, "kind", .{ .string = "loop_" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "body", try encodeBlockExpr(allocator, v.body));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .while_ => |v| {
            try o.put(allocator, "kind", .{ .string = "while_" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "cond", mkInt(v.cond));
            try vo.put(allocator, "capture", encodeOptId(v.capture));
            try vo.put(allocator, "body", try encodeBlockExpr(allocator, v.body));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .for_ => |v| {
            try o.put(allocator, "kind", .{ .string = "for_" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "pattern", mkInt(v.pattern));
            try vo.put(allocator, "iterable", mkInt(v.iterable));
            try vo.put(allocator, "body", try encodeBlockExpr(allocator, v.body));
            try vo.put(allocator, "iter_kind", try encodeIterKind(allocator, v.iter_kind));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .break_ => |v| {
            try o.put(allocator, "kind", .{ .string = "break_" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "label", encodeOptStr(v.label));
            try vo.put(allocator, "value", encodeOptId(v.value));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .continue_ => |v| {
            try o.put(allocator, "kind", .{ .string = "continue_" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "label", encodeOptStr(v.label));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .call => |v| {
            try o.put(allocator, "kind", .{ .string = "call" });
            var vo = ObjectMap.empty;
            var ko = ObjectMap.empty;
            switch (v.call_kind) {
                .free => |d| {
                    try ko.put(allocator, "kind", .{ .string = "free" });
                    try ko.put(allocator, "def", mkInt(d));
                },
                .associated => |d| {
                    try ko.put(allocator, "kind", .{ .string = "associated" });
                    try ko.put(allocator, "def", mkInt(d));
                },
                .constructor => |d| {
                    try ko.put(allocator, "kind", .{ .string = "constructor" });
                    try ko.put(allocator, "def", mkInt(d));
                },
            }
            try vo.put(allocator, "call_kind", .{ .object = ko });
            try vo.put(allocator, "args", try encodeIdList(allocator, v.args));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .method_call => |v| {
            try o.put(allocator, "kind", .{ .string = "method_call" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "receiver", mkInt(v.receiver));
            try vo.put(allocator, "receiver_mode", .{ .string = @tagName(v.receiver_mode) });
            try vo.put(allocator, "method", mkInt(v.method));
            try vo.put(allocator, "args", try encodeIdList(allocator, v.args));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .struct_lit => |v| {
            try o.put(allocator, "kind", .{ .string = "struct_lit" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "def", mkInt(v.def));
            var fields = Array.init(allocator);
            for (v.fields) |f| {
                var fo = ObjectMap.empty;
                try fo.put(allocator, "field", .{ .string = f.field });
                try fo.put(allocator, "value", mkInt(f.value));
                try fo.put(allocator, "shorthand", .{ .bool = f.shorthand });
                try fields.append(.{ .object = fo });
            }
            try vo.put(allocator, "fields", .{ .array = fields });
            try vo.put(allocator, "base", encodeOptId(v.base));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .enum_variant => |v| {
            try o.put(allocator, "kind", .{ .string = "enum_variant" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "def", mkInt(v.def));
            try vo.put(allocator, "variant", .{ .string = v.variant });
            try vo.put(allocator, "tuple_fields", try encodeIdList(allocator, v.tuple_fields));
            var named = Array.init(allocator);
            for (v.named_fields) |f| {
                var fo = ObjectMap.empty;
                try fo.put(allocator, "field", .{ .string = f.field });
                try fo.put(allocator, "value", mkInt(f.value));
                try fo.put(allocator, "shorthand", .{ .bool = f.shorthand });
                try named.append(.{ .object = fo });
            }
            try vo.put(allocator, "named_fields", .{ .array = named });
            try o.put(allocator, "value", .{ .object = vo });
        },
        .field => |v| {
            try o.put(allocator, "kind", .{ .string = "field" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "base", mkInt(v.base));
            try vo.put(allocator, "field", .{ .string = v.field });
            try vo.put(allocator, "resolved", mkInt(v.resolved));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .index => |v| {
            try o.put(allocator, "kind", .{ .string = "index" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "base", mkInt(v.base));
            try vo.put(allocator, "index", mkInt(v.index));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .cast => |v| {
            try o.put(allocator, "kind", .{ .string = "cast" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "operand", mkInt(v.operand));
            try vo.put(allocator, "source_type", try encodeType(allocator, v.source_type));
            try vo.put(allocator, "target", mkInt(v.target));
            try vo.put(allocator, "conversion", .{ .string = switch (v.kind) {
                .as_ => "as",
                .primitive_from => "primitive_from",
            } });
            try o.put(allocator, "value", .{ .object = vo });
        },
        .binary => |v| {
            try o.put(allocator, "kind", .{ .string = "binary" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "op", .{ .string = @tagName(v.op) });
            try vo.put(allocator, "overflow", .{ .string = @tagName(v.overflow) });
            try vo.put(allocator, "lhs", mkInt(v.lhs));
            try vo.put(allocator, "rhs", mkInt(v.rhs));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .unary => |v| {
            try o.put(allocator, "kind", .{ .string = "unary" });
            var vo = ObjectMap.empty;
            switch (v.op) {
                .ref => |m| {
                    try vo.put(allocator, "op", .{ .string = "ref" });
                    try vo.put(allocator, "mode", .{ .string = @tagName(m) });
                },
                else => {
                    try vo.put(allocator, "op", .{ .string = @tagName(v.op) });
                },
            }
            try vo.put(allocator, "operand", mkInt(v.operand));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .assign => |v| {
            try o.put(allocator, "kind", .{ .string = "assign" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "target", mkInt(v.target));
            try vo.put(allocator, "op", .{ .string = @tagName(v.op) });
            try vo.put(allocator, "value", mkInt(v.value));
            try vo.put(allocator, "overflow", .{ .string = @tagName(v.overflow) });
            try o.put(allocator, "value", .{ .object = vo });
        },
        .try_ => |v| {
            try o.put(allocator, "kind", .{ .string = "try_" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "inner", mkInt(v.inner));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .return_ => |v| {
            try o.put(allocator, "kind", .{ .string = "return_" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "value", encodeOptId(v.value));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .unsupported => |u| {
            try o.put(allocator, "kind", .{ .string = "unsupported" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "reason", .{ .string = u.reason });
            try vo.put(
                allocator,
                "suggested_version",
                .{ .string = @tagName(u.suggested_version) },
            );
            try o.put(allocator, "value", .{ .object = vo });
        },
        .range, .closure, .iterator_chain => return error.UnsupportedWireVariant,
    }
    return .{ .object = o };
}

fn spliceKindValue(allocator: std.mem.Allocator, dst: *ObjectMap, src: Json) !void {
    var sm = src.object;
    if (sm.fetchOrderedRemove("kind")) |entry| {
        try dst.put(allocator, "kind", entry.value);
    }
    if (sm.fetchOrderedRemove("value")) |entry| {
        try dst.put(allocator, "value", entry.value);
    }
    sm.deinit(allocator);
}

fn encodeExpr(allocator: std.mem.Allocator, e: exprs.Expr) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "id", mkInt(e.id));
    try o.put(allocator, "span", try encodeSpan(allocator, e.span));
    try o.put(allocator, "ty", encodeOptId(e.ty));
    const ko = try encodeExprKind(allocator, e.kind);
    try spliceKindValue(allocator, &o, ko);
    return .{ .object = o };
}

fn encodePatternKind(allocator: std.mem.Allocator, kind: exprs.PatternKind) !Json {
    var o = ObjectMap.empty;
    switch (kind) {
        .wildcard => {
            try o.put(allocator, "kind", .{ .string = "wildcard" });
            try o.put(allocator, "value", .{ .object = ObjectMap.empty });
        },
        .binding => |b| {
            try o.put(allocator, "kind", .{ .string = "binding" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "name", .{ .string = b.name });
            const mode = switch (b.mode) {
                .value => "value",
                .shared_ref => "shared_ref",
                .mut_ref => "mut_ref",
            };
            try vo.put(allocator, "mode", .{ .string = mode });
            try vo.put(allocator, "mutable", .{ .bool = b.mutable });
            try o.put(allocator, "value", .{ .object = vo });
        },
        .literal => |v| {
            try o.put(allocator, "kind", .{ .string = "literal" });
            try o.put(allocator, "value", try encodeLiteralObj(allocator, v));
        },
        .path => |p| {
            try o.put(allocator, "kind", .{ .string = "path" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "def", mkInt(p.def));
            try vo.put(allocator, "variant", encodeOptStr(p.variant));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .tuple => |t| {
            try o.put(allocator, "kind", .{ .string = "tuple" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "elements", try encodeIdList(allocator, t.elements));
            try vo.put(allocator, "rest", .{ .bool = t.rest });
            try o.put(allocator, "value", .{ .object = vo });
        },
        .slice => |t| {
            try o.put(allocator, "kind", .{ .string = "slice" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "elements", try encodeIdList(allocator, t.elements));
            try vo.put(allocator, "rest", encodeOptId(t.rest));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .struct_pat => |t| {
            var vo = ObjectMap.empty;
            try vo.put(allocator, "def", mkInt(t.def));
            var fields = Array.init(allocator);
            for (t.fields) |f| {
                var fo = ObjectMap.empty;
                try fo.put(allocator, "field", .{ .string = f.field });
                try fo.put(allocator, "pat", encodeOptId(f.pat));
                try fo.put(allocator, "shorthand", .{ .bool = f.shorthand });
                try fields.append(.{ .object = fo });
            }
            try vo.put(allocator, "fields", .{ .array = fields });
            try vo.put(allocator, "rest", .{ .bool = t.rest });
            try o.put(allocator, "kind", .{ .string = "struct_pat" });
            try o.put(allocator, "value", .{ .object = vo });
        },
        .reference => |t| {
            try o.put(allocator, "kind", .{ .string = "reference" });
            var vo = ObjectMap.empty;
            const mode = switch (t.mode) {
                .value => "value",
                .shared_ref => "shared_ref",
                .mut_ref => "mut_ref",
            };
            try vo.put(allocator, "mode", .{ .string = mode });
            try vo.put(allocator, "inner", mkInt(t.inner));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .@"or" => |t| {
            try o.put(allocator, "kind", .{ .string = "or" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "alternatives", try encodeIdList(allocator, t.alternatives));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .range => |t| {
            try o.put(allocator, "kind", .{ .string = "range" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "lo", encodeOptId(t.lo));
            try vo.put(allocator, "hi", encodeOptId(t.hi));
            try vo.put(allocator, "inclusive", .{ .bool = t.inclusive });
            try o.put(allocator, "value", .{ .object = vo });
        },
        .unsupported => |u| {
            try o.put(allocator, "kind", .{ .string = "unsupported" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "reason", .{ .string = u.reason });
            try vo.put(
                allocator,
                "suggested_version",
                .{ .string = @tagName(u.suggested_version) },
            );
            try o.put(allocator, "value", .{ .object = vo });
        },
    }
    return .{ .object = o };
}

fn encodePattern(allocator: std.mem.Allocator, p: exprs.Pattern) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "id", mkInt(p.id));
    try o.put(allocator, "span", try encodeSpan(allocator, p.span));
    try o.put(allocator, "ty", encodeOptId(p.ty));
    const ko = try encodePatternKind(allocator, p.kind);
    try spliceKindValue(allocator, &o, ko);
    return .{ .object = o };
}

fn encodeStatementKind(allocator: std.mem.Allocator, kind: exprs.StatementKind) !Json {
    var o = ObjectMap.empty;
    switch (kind) {
        .let => |v| {
            try o.put(allocator, "kind", .{ .string = "let" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "pattern", mkInt(v.pattern));
            try vo.put(allocator, "init", encodeOptId(v.init));
            try vo.put(allocator, "ty", encodeOptId(v.ty));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .let_else => |v| {
            try o.put(allocator, "kind", .{ .string = "let_else" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "pattern", mkInt(v.pattern));
            try vo.put(allocator, "init", mkInt(v.init));
            try vo.put(allocator, "else_block", try encodeBlockExpr(allocator, v.else_block));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .expr => |id| {
            try o.put(allocator, "kind", .{ .string = "expr" });
            try o.put(allocator, "value", mkInt(id));
        },
        .item => |id| {
            try o.put(allocator, "kind", .{ .string = "item" });
            try o.put(allocator, "value", mkInt(id));
        },
    }
    return .{ .object = o };
}

fn encodeStatement(allocator: std.mem.Allocator, s: exprs.Statement) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "id", mkInt(s.id));
    try o.put(allocator, "span", try encodeSpan(allocator, s.span));
    try o.put(allocator, "ty", encodeOptId(s.ty));
    const ko = try encodeStatementKind(allocator, s.kind);
    try spliceKindValue(allocator, &o, ko);
    return .{ .object = o };
}

fn encodeStringList(allocator: std.mem.Allocator, values: []const []const u8) !Json {
    var arr = Array.init(allocator);
    for (values) |value| try arr.append(.{ .string = value });
    return .{ .array = arr };
}

fn encodeField(allocator: std.mem.Allocator, field: items.Field) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = field.name });
    try o.put(allocator, "ty", try encodeType(allocator, field.ty));
    try o.put(allocator, "visibility", try encodeVisibility(allocator, field.visibility));
    try o.put(allocator, "span", try encodeSpan(allocator, field.span));
    return .{ .object = o };
}

fn encodeFields(allocator: std.mem.Allocator, fields: []const items.Field) !Json {
    var arr = Array.init(allocator);
    for (fields) |field| try arr.append(try encodeField(allocator, field));
    return .{ .array = arr };
}

fn encodeVariant(allocator: std.mem.Allocator, variant: items.Variant) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = variant.name });
    try o.put(allocator, "discriminant", if (variant.discriminant) |value|
        .{ .string = try std.fmt.allocPrint(allocator, "{d}", .{value}) }
    else
        .{ .null = {} });
    var fields = ObjectMap.empty;
    switch (variant.fields) {
        .none => try fields.put(allocator, "plain", .{ .bool = true }),
        .tuple => |tuple| {
            var values = Array.init(allocator);
            for (tuple) |ty| try values.append(try encodeType(allocator, ty));
            try fields.put(allocator, "tuple", .{ .array = values });
        },
        .named => |named| try fields.put(allocator, "named", try encodeFields(allocator, named)),
    }
    try o.put(allocator, "fields", .{ .object = fields });
    return .{ .object = o };
}

fn encodeVariants(allocator: std.mem.Allocator, variants: []const items.Variant) !Json {
    var arr = Array.init(allocator);
    for (variants) |variant| try arr.append(try encodeVariant(allocator, variant));
    return .{ .array = arr };
}

fn encodeStructMethod(allocator: std.mem.Allocator, method: StructMethod) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = method.name });
    try o.put(allocator, "visibility", try encodeVisibility(allocator, method.visibility));
    var params = Array.init(allocator);
    for (method.params) |param| try params.append(try encodeParam(allocator, param));
    try o.put(allocator, "params", .{ .array = params });
    try o.put(allocator, "ret", try encodeType(allocator, method.ret));
    try o.put(allocator, "generic_params", try encodeStringList(allocator, method.generic_params));
    try o.put(allocator, "body", mkInt(method.body));
    try o.put(allocator, "receiver", if (method.receiver) |receiver|
        .{ .string = @tagName(receiver) }
    else
        .{ .null = {} });
    try o.put(allocator, "is_allocating", .{ .bool = method.is_allocating });
    return .{ .object = o };
}

fn encodeStructMethods(allocator: std.mem.Allocator, methods: []const StructMethod) !Json {
    var arr = Array.init(allocator);
    for (methods) |method| try arr.append(try encodeStructMethod(allocator, method));
    return .{ .array = arr };
}

fn encodeTraitMethod(allocator: std.mem.Allocator, method: TraitMethodSig) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = method.name });
    var params = Array.init(allocator);
    for (method.params) |param| try params.append(try encodeParam(allocator, param));
    try o.put(allocator, "params", .{ .array = params });
    try o.put(allocator, "ret", try encodeType(allocator, method.ret));
    try o.put(allocator, "receiver", .{ .string = @tagName(method.receiver) });
    return .{ .object = o };
}

fn encodeTraitMethods(allocator: std.mem.Allocator, methods: []const TraitMethodSig) !Json {
    var arr = Array.init(allocator);
    for (methods) |method| try arr.append(try encodeTraitMethod(allocator, method));
    return .{ .array = arr };
}

fn encodeParam(allocator: std.mem.Allocator, p: items.Param) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = p.name });
    try o.put(allocator, "ty", try encodeType(allocator, p.ty));
    try o.put(allocator, "span", try encodeSpan(allocator, p.span));
    return .{ .object = o };
}

fn encodeBodyKind(allocator: std.mem.Allocator, bk: BodyKind) !Json {
    var o = ObjectMap.empty;
    switch (bk) {
        .none => try o.put(allocator, "kind", .{ .string = "none" }),
        .const_ => |cb| {
            try o.put(allocator, "kind", .{ .string = "const_" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "ty", try encodeType(allocator, cb.ty));
            try vo.put(allocator, "init", mkInt(cb.init));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .fn_ => |fb| {
            try o.put(allocator, "kind", .{ .string = "fn_" });
            var vo = ObjectMap.empty;
            var params = Array.init(allocator);
            for (fb.params) |p| try params.append(try encodeParam(allocator, p));
            try vo.put(allocator, "params", .{ .array = params });
            try vo.put(allocator, "ret", try encodeType(allocator, fb.ret));
            try vo.put(allocator, "generic_params", try encodeStringList(allocator, fb.generic_params));
            try vo.put(allocator, "body", mkInt(fb.body));
            try vo.put(allocator, "is_allocating", .{ .bool = fb.is_allocating });
            try o.put(allocator, "value", .{ .object = vo });
        },
        .struct_ => |sb| {
            try o.put(allocator, "kind", .{ .string = "struct_" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "generic_params", try encodeStringList(allocator, sb.generic_params));
            try vo.put(allocator, "trait_bounds", try encodeStringList(allocator, sb.trait_bounds));
            try vo.put(allocator, "layout", .{ .string = @tagName(sb.layout) });
            try vo.put(allocator, "fields", try encodeFields(allocator, sb.fields));
            try vo.put(allocator, "methods", try encodeStructMethods(allocator, sb.methods));
            try vo.put(allocator, "has_dynamic_resources", .{ .bool = sb.has_dynamic_resources });
            try o.put(allocator, "value", .{ .object = vo });
        },
        .enum_ => |eb| {
            try o.put(allocator, "kind", .{ .string = "enum_" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "kind", .{ .string = @tagName(eb.kind) });
            try vo.put(allocator, "variants", try encodeVariants(allocator, eb.variants));
            try vo.put(allocator, "repr_int", if (eb.repr_int) |repr|
                .{ .string = @tagName(repr) }
            else
                .{ .null = {} });
            try vo.put(allocator, "non_exhaustive", .{ .bool = eb.non_exhaustive });
            try o.put(allocator, "value", .{ .object = vo });
        },
        .trait_ => |tb| {
            try o.put(allocator, "kind", .{ .string = "trait_" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "name", .{ .string = tb.name });
            try vo.put(allocator, "supertraits", try encodeStringList(allocator, tb.supertraits));
            try vo.put(allocator, "methods", try encodeTraitMethods(allocator, tb.methods));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .type_alias => |ab| {
            try o.put(allocator, "kind", .{ .string = "type_alias" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "target", try encodeType(allocator, ab.target));
            try o.put(allocator, "value", .{ .object = vo });
        },
    }
    return .{ .object = o };
}

fn encodeBodies(
    allocator: std.mem.Allocator,
    b: *const Bodies,
    entities: []const spine.Entity,
) !Json {
    var o = ObjectMap.empty;

    var exprs_arr = Array.init(allocator);
    for (b.exprs) |e| try exprs_arr.append(try encodeExpr(allocator, e));
    try o.put(allocator, "exprs", .{ .array = exprs_arr });

    var stmts_arr = Array.init(allocator);
    for (b.stmts) |st| try stmts_arr.append(try encodeStatement(allocator, st));
    try o.put(allocator, "stmts", .{ .array = stmts_arr });

    var pats_arr = Array.init(allocator);
    for (b.pats) |p| try pats_arr.append(try encodePattern(allocator, p));
    try o.put(allocator, "pats", .{ .array = pats_arr });

    var types_arr = Array.init(allocator);
    for (b.types) |t| try types_arr.append(try encodeType(allocator, t));
    try o.put(allocator, "types", .{ .array = types_arr });

    if (b.bodies.len != entities.len) return error.InvalidBodyTable;
    var bodies_arr = Array.init(allocator);
    for (b.bodies, 0..) |body, index| {
        const owner: spine.EntityId = @intCast(index);
        try validateBodySlot(entities, owner, body);
        var slot = ObjectMap.empty;
        try slot.put(allocator, "owner", mkInt(owner));
        try slot.put(allocator, "body", try encodeBodyKind(allocator, body));
        try bodies_arr.append(.{ .object = slot });
    }
    try o.put(allocator, "bodies", .{ .array = bodies_arr });

    return .{ .object = o };
}
fn isExternalRoot(path: []const []const u8) bool {
    if (path.len == 0) return false;
    return std.mem.eql(u8, path[0], "alloc") or
        std.mem.eql(u8, path[0], "core") or
        std.mem.eql(u8, path[0], "std");
}

fn genericNameKnown(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn validateNominalType(
    entities: []const spine.Entity,
    ty: types.Type,
    generic_names: []const []const u8,
) !void {
    switch (ty) {
        .path => |path| {
            if (path.segments.len == 0) return error.InvalidTypePath;
            var generic_root = false;
            for (path.segments, 0..) |segment, index| {
                if (segment.name.len == 0) return error.InvalidTypePath;
                if (segment.id) |id| {
                    if (@as(usize, id) >= entities.len) return error.InvalidEntityReference;
                    if (!std.mem.eql(u8, entities[id].name, segment.name)) {
                        return error.InvalidTypePath;
                    }
                } else if (index == 0 and genericNameKnown(generic_names, segment.name)) {
                    generic_root = true;
                } else if (!generic_root) {
                    return error.UnresolvedTypePath;
                }
            }
        },
        .external_nominal => |external| {
            if (!isExternalRoot(external.path)) {
                return error.UnsupportedExternalNominalType;
            }
            for (external.path) |segment| {
                if (segment.len == 0) return error.InvalidTypePath;
            }
            for (external.args) |arg| {
                try validateNominalType(entities, arg, generic_names);
            }
        },
        .reference => |reference| try validateNominalType(entities, reference.pointee, generic_names),
        .raw_ptr => |raw_ptr| try validateNominalType(entities, raw_ptr.pointee, generic_names),
        .slice => |slice| try validateNominalType(entities, slice.elem, generic_names),
        .array => |array| try validateNominalType(entities, array.elem, generic_names),
        .tuple => |tuple| for (tuple) |item| {
            try validateNominalType(entities, item, generic_names);
        },
        .fn_ptr => |fn_ptr| {
            for (fn_ptr.params) |param| {
                try validateNominalType(entities, param, generic_names);
            }
            try validateNominalType(entities, fn_ptr.ret, generic_names);
        },
        .generic_inst => |generic_inst| {
            if (@as(usize, generic_inst.decl) >= entities.len) {
                return error.InvalidEntityReference;
            }
            for (generic_inst.args.params) |param| {
                try validateNominalType(entities, param, generic_names);
            }
        },
        .option => |option| try validateNominalType(entities, option.*, generic_names),
        .result => |result| {
            try validateNominalType(entities, result.ok, generic_names);
            try validateNominalType(entities, result.err, generic_names);
        },
        .boxed => |boxed| try validateNominalType(entities, boxed.*, generic_names),
        .prim, .unsupported => {},
    }
}

fn validateNominalParams(
    entities: []const spine.Entity,
    params: []const items.Param,
    generic_names: []const []const u8,
) !void {
    for (params) |param| try validateNominalType(entities, param.ty, generic_names);
}

fn validateNominalFields(
    entities: []const spine.Entity,
    fields: []const items.Field,
    generic_names: []const []const u8,
) !void {
    for (fields) |field| try validateNominalType(entities, field.ty, generic_names);
}

fn validateNominalBody(
    entities: []const spine.Entity,
    body: BodyKind,
) !void {
    switch (body) {
        .none => {},
        .const_ => |const_body| try validateNominalType(entities, const_body.ty, &.{}),
        .fn_ => |fn_body| {
            try validateNominalParams(entities, fn_body.params, fn_body.generic_params);
            try validateNominalType(entities, fn_body.ret, fn_body.generic_params);
        },
        .struct_ => |struct_body| {
            try validateNominalFields(entities, struct_body.fields, struct_body.generic_params);
            for (struct_body.methods) |method| {
                try validateNominalParams(entities, method.params, method.generic_params);
                try validateNominalType(entities, method.ret, method.generic_params);
            }
        },
        .enum_ => |enum_body| {
            for (enum_body.variants) |variant| {
                switch (variant.fields) {
                    .none => {},
                    .tuple => |fields| for (fields) |field| {
                        try validateNominalType(entities, field, &.{});
                    },
                    .named => |fields| try validateNominalFields(entities, fields, &.{}),
                }
            }
        },
        .trait_ => |trait_body| {
            for (trait_body.methods) |method| {
                try validateNominalParams(entities, method.params, &.{});
                try validateNominalType(entities, method.ret, &.{});
            }
        },
        .type_alias => |alias_body| try validateNominalType(entities, alias_body.target, &.{}),
    }
}

fn validateNominalTables(
    entities: []const spine.Entity,
    root_types: []const types.Type,
    body_data: *const Bodies,
    instantiations: []const types.Instantiation,
) !void {
    for (root_types) |ty| try validateNominalType(entities, ty, &.{});
    for (body_data.types) |ty| try validateNominalType(entities, ty, &.{});
    for (body_data.exprs) |expr| {
        switch (expr.kind) {
            .path => |path| for (path.generic_args) |arg| {
                try validateNominalType(entities, arg, &.{});
            },
            else => {},
        }
    }
    if (body_data.bodies.len != entities.len) return error.InvalidBodyTable;
    for (body_data.bodies) |body| try validateNominalBody(entities, body);
    for (instantiations, 0..) |instantiation, index| {
        if (@as(usize, instantiation.generic_id) >= entities.len) {
            return error.InvalidEntityReference;
        }
        if (instantiation.zig_suffix.len == 0) return error.IncompleteGenericMetadata;
        const generic_count = switch (body_data.bodies[instantiation.generic_id]) {
            .fn_ => |body| body.generic_params.len,
            .struct_ => |body| body.generic_params.len,
            else => return error.IncompleteGenericMetadata,
        };
        if (generic_count == 0 or instantiation.args.params.len != generic_count) {
            return error.IncompleteGenericMetadata;
        }
        for (instantiations[0..index]) |prior| {
            if (prior.generic_id == instantiation.generic_id and
                std.mem.eql(u8, prior.zig_suffix, instantiation.zig_suffix))
            {
                return error.DuplicateInstantiation;
            }
        }
        for (instantiation.args.params) |param| {
            try validateNominalType(entities, param, &.{});
        }
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Encode a `RustIr` instance into a JSON string.
/// The returned slice is allocated with `allocator` and must be freed by caller.
pub fn encode(allocator: std.mem.Allocator, ir_data: *const RustIr) ![]const u8 {
    try ir_data.graph.validateTopology();
    if (ir_data.crate_name.len == 0) return error.MissingField;
    if (ir_data.edition.len == 0) return error.MissingField;
    if (ir_data.bodies.bodies.len != ir_data.graph.symbol_table.entities.items.len) {
        return error.InvalidBodyTable;
    }
    for (ir_data.bodies.bodies, 0..) |body, index| {
        try validateBodySlot(
            ir_data.graph.symbol_table.entities.items,
            @intCast(index),
            body,
        );
    }
    try validateNominalTables(
        ir_data.graph.symbol_table.entities.items,
        ir_data.types,
        &ir_data.bodies,
        ir_data.instantiations,
    );

    var root_map = ObjectMap.empty;
    try root_map.put(allocator, "format_version", mkInt(wire_format_version));
    try root_map.put(allocator, "crate_name", .{ .string = ir_data.crate_name });
    try root_map.put(allocator, "edition", .{ .string = ir_data.edition });
    try root_map.put(allocator, "sidecar", encodeOptStr(ir_data.graph.sidecar));
    try root_map.put(allocator, "toolchain", encodeOptStr(ir_data.graph.toolchain));

    var crates_arr = Array.init(allocator);
    for (ir_data.graph.crates.items) |c| {
        const member = try crateMembers(allocator, &ir_data.graph, c.root);
        defer allocator.free(member);
        try crates_arr.append(try encodeCrate(allocator, &ir_data.graph, c, member));
    }
    try root_map.put(allocator, "crates", .{ .array = crates_arr });
    try root_map.put(allocator, "types", try encodeTypeList(allocator, ir_data.types));
    try root_map.put(
        allocator,
        "instantiations",
        try encodeInstantiations(allocator, ir_data.instantiations),
    );
    try root_map.put(
        allocator,
        "bodies",
        try encodeBodies(
            allocator,
            &ir_data.bodies,
            ir_data.graph.symbol_table.entities.items,
        ),
    );

    var root_val: Json = .{ .object = root_map };
    defer freeValue(allocator, &root_val);
    return std.json.Stringify.valueAlloc(allocator, root_val, .{});
}

/// Decode a canonical v5 JSON string into a `RustIr` instance.
/// Allocations made during decoding use `allocator`.
pub fn decode(allocator: std.mem.Allocator, json_bytes: []const u8) !RustIr {
    var parsed = std.json.parseFromSlice(Json, allocator, json_bytes, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    const root_map = getObj(parsed.value) catch return error.BadWireFormat;
    const ver: u32 = try reqU32(root_map, "format_version");
    if (ver != wire_format_version) return error.InvalidFormatVersion;

    const crate_name = try allocator.dupe(u8, try reqStr(root_map, "crate_name"));
    errdefer allocator.free(crate_name);
    const edition = try allocator.dupe(u8, try reqStr(root_map, "edition"));
    errdefer allocator.free(edition);
    _ = try reqOptStr(root_map, "sidecar");
    _ = try reqOptStr(root_map, "toolchain");

    var g = try decodeGraph(allocator, root_map);
    errdefer g.deinit();
    const ir_types = try decodeTypeList(allocator, try req(root_map, "types"));
    errdefer freeDecodedTypeSlice(allocator, ir_types);
    const instantiations = try decodeInstantiations(
        allocator,
        try req(root_map, "instantiations"),
    );
    errdefer freeDecodedInstantiations(allocator, instantiations);
    const b = try decodeBodies(
        allocator,
        try req(root_map, "bodies"),
        g.symbol_table.entities.items,
    );
    errdefer freeDecodedBodies(allocator, b);
    try validateNominalTables(
        g.symbol_table.entities.items,
        ir_types,
        &b,
        instantiations,
    );

    return .{
        .crate_name = crate_name,
        .edition = edition,
        .graph = g,
        .types = ir_types,
        .instantiations = instantiations,
        .bodies = b,
    };
}

fn expectDecodeGraphError(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected: anyerror,
) !void {
    var parsed = try std.json.parseFromSlice(Json, allocator, bytes, .{});
    defer parsed.deinit();
    const root_map = try getObj(parsed.value);
    try std.testing.expectError(expected, decodeGraph(allocator, root_map));
}

test "decodeGraph rejects duplicate entity IDs" {
    const bytes =
        \\{"crates":[{"name":"c","edition":2021,"kind":"lib","root":0,"is_translated":true,"deps":[],"entities":[
        \\{"id":0,"kind":"module","name":"","span":{"start_line":1,"start_col":1,"end_line":1,"end_col":1},"visibility":{"kind":"public"},"parent":null,"resolved":null,"renamed_to":null,"attributes":[]},
        \\{"id":0,"kind":"fn_","name":"f","span":{"start_line":1,"start_col":1,"end_line":1,"end_col":1},"visibility":{"kind":"public"},"parent":0,"resolved":null,"renamed_to":null,"attributes":[]}
        \\],"modules":[],"uses":[]}]}
    ;
    try expectDecodeGraphError(std.testing.allocator, bytes, error.InvalidEntityId);
}

test "decodeGraph rejects sparse entity IDs" {
    const bytes =
        \\{"crates":[{"name":"c","edition":2021,"kind":"lib","root":0,"is_translated":true,"deps":[],"entities":[
        \\{"id":1,"kind":"module","name":"","span":{"start_line":1,"start_col":1,"end_line":1,"end_col":1},"visibility":{"kind":"public"},"parent":null,"resolved":null,"renamed_to":null,"attributes":[]}
        \\],"modules":[],"uses":[]}]}
    ;
    try expectDecodeGraphError(std.testing.allocator, bytes, error.InvalidEntityId);
}

test "decodeGraph rejects invalid module item endpoints" {
    const bytes =
        \\{"crates":[{"name":"c","edition":2021,"kind":"lib","root":0,"is_translated":true,"deps":[],"entities":[
        \\{"id":0,"kind":"module","name":"","span":{"start_line":1,"start_col":1,"end_line":1,"end_col":1},"visibility":{"kind":"public"},"parent":null,"resolved":null,"renamed_to":null,"attributes":[]}
        \\],"modules":[
        \\{"id":0,"kind":"root","name":"","parent":null,"source_path":null,"is_crate":true,"is_extern":false,"span":{"start_line":1,"start_col":1,"end_line":1,"end_col":1},"items":[99],"attributes":[]}
        \\],"uses":[]}]}
    ;
    try expectDecodeGraphError(std.testing.allocator, bytes, error.UnknownModuleItem);
}

test "decodeGraph rejects invalid use target endpoints" {
    const bytes =
        \\{"crates":[{"name":"c","edition":2021,"kind":"lib","root":0,"is_translated":true,"deps":[],"entities":[
        \\{"id":0,"kind":"module","name":"","span":{"start_line":1,"start_col":1,"end_line":1,"end_col":1},"visibility":{"kind":"public"},"parent":null,"resolved":null,"renamed_to":null,"attributes":[]},
        \\{"id":1,"kind":"use_","name":"f","span":{"start_line":1,"start_col":1,"end_line":1,"end_col":1},"visibility":{"kind":"private"},"parent":0,"resolved":null,"renamed_to":null,"attributes":[]}
        \\],"modules":[
        \\{"id":0,"kind":"root","name":"","parent":null,"source_path":null,"is_crate":true,"is_extern":false,"span":{"start_line":1,"start_col":1,"end_line":1,"end_col":1},"items":[1],"attributes":[]}
        \\],"uses":[
        \\{"id":1,"kind":"plain","local_name":"f","is_pub_export":false,"target":99,"span":{"start_line":1,"start_col":1,"end_line":1,"end_col":1}}
        \\]}]}
    ;
    try expectDecodeGraphError(std.testing.allocator, bytes, error.InvalidUseMetadata);
}

test "decodeGraph rejects orphan entities" {
    const bytes =
        \\{"crates":[{"name":"c","edition":2021,"kind":"lib","root":0,"is_translated":true,"deps":[],"entities":[
        \\{"id":0,"kind":"module","name":"","span":{"start_line":1,"start_col":1,"end_line":1,"end_col":1},"visibility":{"kind":"public"},"parent":null,"resolved":null,"renamed_to":null,"attributes":[]},
        \\{"id":1,"kind":"fn_","name":"f","span":{"start_line":1,"start_col":1,"end_line":1,"end_col":1},"visibility":{"kind":"public"},"parent":0,"resolved":null,"renamed_to":null,"attributes":[]}
        \\],"modules":[
        \\{"id":0,"kind":"root","name":"","parent":null,"source_path":null,"is_crate":true,"is_extern":false,"span":{"start_line":1,"start_col":1,"end_line":1,"end_col":1},"items":[],"attributes":[]}
        \\],"uses":[]}]}
    ;
    try expectDecodeGraphError(std.testing.allocator, bytes, error.MissingModuleItem);
}

test "encode rejects orphan entities before producing JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 1,
    };
    var g = graph.CrateGraph.init(allocator);
    _ = try g.symbol_table.add(.{
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
    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "orphan"),
        .span = span,
        .visibility = .public,
        .parent = 0,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = try allocator.dupe(u8, ""),
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });
    try g.addCrate(.{
        .name = try allocator.dupe(u8, "orphan"),
        .edition = 2021,
        .kind = .lib,
        .root = 0,
        .deps = &.{},
        .is_translated = true,
    });
    const ir_data: RustIr = .{
        .crate_name = "orphan",
        .graph = g,
        .bodies = emptyBodies(),
    };
    try std.testing.expectError(error.MissingModuleItem, encode(allocator, &ir_data));
}

test "decodeGraph rejects sparse dependency IDs" {
    const bytes =
        \\{"crates":[{"name":"c","edition":2021,"kind":"lib","root":0,"is_translated":true,"deps":[
        \\{"extern_name":"dep","local_alias":"dep","id":2,"version":null,"path":null,"git":null,"optional":false,"default_features":null,"features":[]}
        \\],"entities":[],"modules":[],"uses":[]}]}
    ;
    try expectDecodeGraphError(std.testing.allocator, bytes, error.InvalidDependency);
}
