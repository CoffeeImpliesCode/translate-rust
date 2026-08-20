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

pub const wire_format_version: u32 = 2;

pub const Bodies = bodies_mod.Bodies;
pub const BodyKind = bodies_mod.BodyKind;
pub const ConstBody = bodies_mod.ConstBody;
pub const FnBody = bodies_mod.FnBody;
pub const StructBody = bodies_mod.StructBody;
pub const StructMethod = bodies_mod.StructMethod;
pub const TraitBody = bodies_mod.TraitBody;
pub const TraitMethodSig = bodies_mod.TraitMethodSig;
pub const TypeAliasBody = bodies_mod.TypeAliasBody;

pub const RustIr = struct {
    crate_name: []const u8,
    edition: []const u8 = "2021",
    graph: graph.CrateGraph,
    types: []const types.Type = &.{},
    bodies: bodies_mod.Bodies,
};

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

fn reqU32(o: ObjectMap, key: []const u8) !u32 {
    const v = try req(o, key);
    return switch (v) {
        .integer => |i| @intCast(i),
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
        .integer => |i| @intCast(i),
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
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |i| @intCast(i),
        .null => null,
        else => error.BadWireFormat,
    };
}

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
        try list.append(allocator, @intCast(x));
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
        try list.append(allocator, @intCast(x));
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
    const parent = try optU32(o, "parent");
    const source_path: ?[]u8 = if (try optStr(o, "source_path")) |sp|
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
    const parent = try optU32(o, "parent");
    const resolved = try optU32(o, "resolved");
    const renamed_to: ?[]u8 = if (try optStr(o, "renamed_to")) |rn|
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
    const kind: graph.UseKind = if (std.mem.eql(u8, kind_str, "plain"))
        .{ .plain = target }
    else if (std.mem.eql(u8, kind_str, "alias"))
        .{ .alias = target }
    else if (std.mem.eql(u8, kind_str, "glob"))
        .glob
    else
        return error.BadWireFormat;
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
    for (arr.items) |dv| {
        const d = try getObj(dv);
        var extern_name: ?[]u8 = try allocator.dupe(u8, try reqStr(d, "extern_name"));
        errdefer if (extern_name) |owned| allocator.free(owned);
        var local_alias: ?[]u8 = try allocator.dupe(u8, try reqStr(d, "local_alias"));
        errdefer if (local_alias) |owned| allocator.free(owned);
        const id = @as(u32, @intCast(try reqU32(d, "id")));
        try list.append(allocator, .{
            .extern_name = extern_name.?,
            .local_alias = local_alias.?,
            .id = id,
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
    const suffix = try optStr(o, "ty_suffix");
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

fn decodeTypeList(allocator: std.mem.Allocator, v: Json) anyerror![]const types.Type {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(types.Type) = .empty;
    errdefer list.deinit(allocator);
    for (arr.items) |it| try list.append(allocator, try decodeType(allocator, it));
    return list.toOwnedSlice(allocator);
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
    return .dyn_trait;
}

fn decodeType(allocator: std.mem.Allocator, v: Json) !types.Type {
    const o = try getObj(v);
    const tag = try reqStr(o, "kind");
    const val = try req(o, "value");

    if (std.mem.eql(u8, tag, "path")) {
        const p = try getObj(val);
        return .{ .path = .{ .segments = try decodePathSegments(allocator, try req(p, "segments")) } };
    }
    if (std.mem.eql(u8, tag, "prim")) return .{ .prim = try decodePrim(try reqStrArray(val)) };
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
            .len = if (std.mem.eql(u8, try reqStr(len_o, "kind"), "literal"))
                .{ .literal = try reqU32(len_o, "value") }
            else
                .{ .generic = try reqU32(len_o, "value") },
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
    const labelled = try optStr(o, "labelled");
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
        const repeat: ?usize = switch (try req(p, "repeat")) {
            .integer => |i| @intCast(@max(i, 0)),
            .null => null,
            else => return error.BadWireFormat,
        };
        return .{ .array = .{
            .elements = try decodeIdList(allocator, try req(p, "elements")),
            .repeat = repeat,
        } };
    }
    if (std.mem.eql(u8, tag, "vec_lit")) {
        const p = try getObj(val);
        const repeat: ?usize = switch (try req(p, "repeat")) {
            .integer => |i| @intCast(@max(i, 0)),
            .null => null,
            else => return error.BadWireFormat,
        };
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
        const label = try optStr(q, "label");
        return .{ .break_ = .{
            .label = if (label) |s| try allocator.dupe(u8, s) else null,
            .value = try reqOptionalId(q, "value"),
        } };
    }
    if (std.mem.eql(u8, tag, "continue_")) {
        const q = try getObj(val);
        const label = try optStr(q, "label");
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
        return .{ .unsupported = .{
            .reason = try allocator.dupe(u8, try reqStr(q, "reason")),
            .suggested_version = .v1,
        } };
    }
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
        const variant = try optStr(p, "variant");
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
        return .{ .unsupported = .{
            .reason = try allocator.dupe(u8, try reqStr(t, "reason")),
            .suggested_version = .v1,
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
        return .{ .expr = @intCast(e) };
    }
    if (std.mem.eql(u8, tag, "item")) {
        const e = switch (val) {
            .integer => |i| i,
            else => return error.BadWireFormat,
        };
        return .{ .item = @intCast(e) };
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

// ── Bodies ──────────────────────────────────────────────────────────────────

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

fn decodeBodyKind(allocator: std.mem.Allocator, v: Json) !BodyKind {
    const o = try getObj(v);
    const kind_str = try reqStr(o, "kind");
    if (std.mem.eql(u8, kind_str, "none")) return .none;
    if (std.mem.eql(u8, kind_str, "const_")) {
        const co = try getObj(try req(o, "value"));
        const ty = try decodeType(allocator, try req(co, "ty"));
        const init = try reqU32(co, "init");
        return .{ .const_ = .{
            .ty = ty,
            .init = init,
        } };
    }
    if (std.mem.eql(u8, kind_str, "fn_")) {
        const fo = try getObj(try req(o, "value"));
        const params_arr = switch (try req(fo, "params")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var params_list: std.ArrayListUnmanaged(items.Param) = .empty;
        errdefer freeDecodedParamList(allocator, &params_list);
        for (params_arr.items) |pv| {
            const param = try decodeParam(allocator, pv);
            var param_transferred = false;
            errdefer if (!param_transferred) freeDecodedParam(allocator, param);
            try params_list.append(allocator, param);
            param_transferred = true;
        }
        const params = try params_list.toOwnedSlice(allocator);
        errdefer freeDecodedParams(allocator, params);
        const ret = try decodeType(allocator, try req(fo, "ret"));
        const body = try reqU32(fo, "body");
        return .{ .fn_ = .{
            .params = params,
            .ret = ret,
            .body = body,
        } };
    }
    if (std.mem.eql(u8, kind_str, "struct_")) return .{ .struct_ = .{} };
    if (std.mem.eql(u8, kind_str, "enum_")) return .{ .enum_ = .{} };
    if (std.mem.eql(u8, kind_str, "trait_")) return .{ .trait_ = .{ .name = "" } };
    if (std.mem.eql(u8, kind_str, "type_alias")) {
        return .{ .type_alias = .{ .target = .{ .prim = .unit } } };
    }
    return error.BadWireFormat;
}

fn decodeBodies(allocator: std.mem.Allocator, v: Json) !Bodies {
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
    errdefer types_list.deinit(allocator);
    for (types_arr.items) |tv| try types_list.append(allocator, try decodeType(allocator, tv));
    const decoded_types = try types_list.toOwnedSlice(allocator);
    errdefer allocator.free(decoded_types);

    const bodies_arr = switch (try req(o, "bodies")) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var bodies_list: std.ArrayListUnmanaged(BodyKind) = .empty;
    errdefer bodies_list.deinit(allocator);
    for (bodies_arr.items) |bv| try bodies_list.append(allocator, try decodeBodyKind(allocator, bv));
    const decoded_bodies = try bodies_list.toOwnedSlice(allocator);
    errdefer allocator.free(decoded_bodies);

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
        const edition: u16 = @intCast(try reqU32(c, "edition"));
        const kind = try decodeCrateKind(try reqStr(c, "kind"));
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
            _ = try g.symbol_table.add(e);
        }
        const modules_arr = switch (try req(c, "modules")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        for (modules_arr.items) |mv| {
            const m = try decodeModule(allocator, mv);
            _ = try g.addModule(m);
        }
        const uses_arr = switch (try req(c, "uses")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        for (uses_arr.items) |uv| {
            const u = try decodeUseDecl(allocator, uv);
            try g.addUse(u);
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
    };
    try o.put(allocator, "kind", .{ .string = kind });
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
    return .{ .object = o };
}

fn crateMembers(
    allocator: std.mem.Allocator,
    g: *const graph.CrateGraph,
    root: spine.EntityId,
) ![]bool {
    const n = g.symbol_table.count();
    const member = try allocator.alloc(bool, n);
    @memset(member, false);
    if (root < n) member[root] = true;

    var changed = true;
    while (changed) {
        changed = false;
        for (g.modules.items) |m| {
            if (m.id >= n or member[m.id]) continue;
            var in_crate = if (m.parent) |p| p < n and member[p] else false;
            if (!in_crate) {
                for (m.items) |it| {
                    if (it < n and member[it]) {
                        in_crate = true;
                        break;
                    }
                }
            }
            if (in_crate) {
                member[m.id] = true;
                changed = true;
            }
        }
        for (g.symbol_table.entities.items) |e| {
            if (e.id >= n or member[e.id]) continue;
            if (e.parent) |p| {
                if (p < n and member[p]) {
                    member[e.id] = true;
                    changed = true;
                }
            }
        }
    }
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
    for (g.modules.items) |m| {
        if (m.id < member.len and member[m.id]) try mods.append(try encodeModule(allocator, m));
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
        if (use_decl.id < member.len and member[use_decl.id]) {
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
            try o.put(allocator, "value", .{ .object = vo });
        },
        .closure, .iterator_chain => return error.UnsupportedWireVariant,
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
            try vo.put(allocator, "body", mkInt(fb.body));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .struct_ => try o.put(allocator, "kind", .{ .string = "struct_" }),
        .enum_ => try o.put(allocator, "kind", .{ .string = "enum_" }),
        .trait_ => try o.put(allocator, "kind", .{ .string = "trait_" }),
        .type_alias => try o.put(allocator, "kind", .{ .string = "type_alias" }),
    }
    return .{ .object = o };
}

fn encodeBodies(allocator: std.mem.Allocator, b: *const Bodies) !Json {
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

    var body_arr = Array.init(allocator);
    for (b.bodies) |bk| try body_arr.append(try encodeBodyKind(allocator, bk));
    try o.put(allocator, "bodies", .{ .array = body_arr });

    return .{ .object = o };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Encode a `RustIr` instance into a JSON string.
/// The returned slice is allocated with `allocator` and must be freed by caller.
pub fn encode(allocator: std.mem.Allocator, ir_data: *const RustIr) ![]const u8 {
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

    var types_arr = Array.init(allocator);
    for (ir_data.types) |t| {
        try types_arr.append(try encodeType(allocator, t));
    }
    try root_map.put(allocator, "types", .{ .array = types_arr });

    try root_map.put(allocator, "bodies", try encodeBodies(allocator, &ir_data.bodies));

    var root_val: Json = .{ .object = root_map };
    defer freeValue(allocator, &root_val);

    return std.json.Stringify.valueAlloc(allocator, root_val, .{});
}

/// Decode a JSON string into a `RustIr` instance.
/// Allocations made during decoding use `allocator`.
pub fn decode(allocator: std.mem.Allocator, json_bytes: []const u8) !RustIr {
    var parsed = std.json.parseFromSlice(Json, allocator, json_bytes, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    const root_map = getObj(parsed.value) catch return error.BadWireFormat;
    const ver: u32 = @intCast(try reqU32(root_map, "format_version"));
    if (ver != 1 and ver != 2) return error.InvalidFormatVersion;

    var g = try decodeGraph(allocator, root_map);
    errdefer g.deinit();

    var crate_name: []const u8 = "";
    var crate_name_owned = false;
    errdefer if (crate_name_owned) allocator.free(crate_name);
    if (try optStr(root_map, "crate_name")) |cn| {
        crate_name = try allocator.dupe(u8, cn);
        crate_name_owned = true;
    } else if (g.crates.items.len > 0) {
        crate_name = try allocator.dupe(u8, g.crates.items[0].name);
        crate_name_owned = true;
    }

    var edition: []const u8 = "2021";
    var edition_owned = false;
    errdefer if (edition_owned) allocator.free(edition);
    if (try optStr(root_map, "edition")) |ed| {
        edition = try allocator.dupe(u8, ed);
        edition_owned = true;
    }

    var ir_types: []const types.Type = &.{};
    var ir_types_owned = false;
    errdefer if (ir_types_owned) allocator.free(ir_types);
    if (root_map.get("types")) |tv| {
        ir_types = try decodeTypeList(allocator, tv);
        ir_types_owned = true;
    }

    const b = if (root_map.get("bodies")) |bv|
        try decodeBodies(allocator, bv)
    else
        emptyBodies();

    return .{
        .crate_name = crate_name,
        .edition = edition,
        .graph = g,
        .types = ir_types,
        .bodies = b,
    };
}
