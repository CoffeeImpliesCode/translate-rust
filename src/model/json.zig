//! translate_rust.model.json — the lossless JSON boundary of the crate graph
//! (data-model.md §4, data-model/crate-graph.md §5.2-5.3).
//!
//! Wire format: a top-level object
//!     { "format_version": u32, "sidecar": string?, "toolchain": string?,
//!       "crates": [ { name, edition, kind, root, is_translated, deps,
//!                     modules, entities, uses } ] }
//! Entities are a flat array 0..N cross-referenced by integer EntityId;
//! reserved-word tags keep their trailing underscore (`struct_`, `crate_`,
//! `extern_crate`, ...) as valid-identifier JSON strings. `parse` is the exact
//! inverse of `encode` (round-trip property, crate-graph.md §5.3). A wire
//! `format_version` that is not the current one is rejected.
//!
//! The graph owns all strings returned by `parse`; free it with
//! `graph.CrateGraph.deinit`. The `[]u8` returned by `encode` must be freed
//! with the allocator passed to it.

const std = @import("std");
const spine = @import("spine.zig");
const graph = @import("graph.zig");
const items = @import("items.zig");
const types = @import("types.zig");
const exprs = @import("exprs.zig");

// Keep json.zig compiling against the emit module (emit.zig → json.zig is a
// one-way edge; this side-effect import closes the ring without any comptime
// type dependency, so the cycle resolves lazily).
const _ = @import("emit.zig");

const Json = std.json.Value;
const ObjectMap = std.json.ObjectMap; // unmanaged (allocator passed per call)
const Array = std.json.Array; // managed (init(allocator))

/// The wire format version this build writes and accepts (data-model.md §4).
/// v1: crate graph only (no bodies). v2: adds `bodies` (expressions,
/// statements, patterns, types, per-entity body selector).
pub const wire_format_version: u32 = 2;

// ── Wire v2 body data structures (mirror emit.Bodies) ─────────────────────
// Defined here, not in emit.zig, so the json module stays dependency-free of
// the emit layer (emit.zig imports json.zig). Field layout matches
// emit.ConstBody / emit.FnBody / emit.BodyKind / emit.Bodies id-for-id.

// Shared body tables live in bodies.zig (leaf) so json and emit do not
// create an import cycle. Re-export as aliases — emit.Bodies == json.Bodies.
pub const bodies_mod = @import("bodies.zig");
pub const ConstBody = bodies_mod.ConstBody;
pub const FnBody = bodies_mod.FnBody;
pub const BodyKind = bodies_mod.BodyKind;
pub const Bodies = bodies_mod.Bodies;

/// The full lossless model: graph plus expression-level bodies.
pub const FullModel = struct {
    graph: graph.CrateGraph,
    bodies: Bodies,
};

// ---------------------------------------------------------------------------
// Decode helpers (borrow from the parsed arena; callers dupe what they keep)
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

fn decodeSpan(v: Json) !spine.Span {
    const o = try getObj(v);
    return .{
        .start_line = @intCast(try reqU32(o, "start_line")),
        .start_col = @intCast(try reqU32(o, "start_col")),
        .end_line = @intCast(try reqU32(o, "end_line")),
        .end_col = @intCast(try reqU32(o, "end_col")),
    };
}

fn decodeVisibility(
    allocator: std.mem.Allocator,
    v: Json,
) !spine.Visibility {
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

fn decodeAttributes(
    allocator: std.mem.Allocator,
    v: Json,
) ![]const spine.Attribute {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(spine.Attribute) = .empty;
    for (arr.items) |av| {
        const o = try getObj(av);
        try list.append(allocator, .{
            .name = try allocator.dupe(u8, try reqStr(o, "name")),
            .meta = try allocator.dupe(u8, try reqStr(o, "meta")),
            .known = try reqBool(o, "known"),
        });
    }
    return list.toOwnedSlice(allocator);
}

fn decodeIdSlice(allocator: std.mem.Allocator, v: Json) ![]const spine.EntityId {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(spine.EntityId) = .empty;
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
    return .{
        .id = @intCast(try reqU32(o, "id")),
        .kind = try decodeModuleKind(try reqStr(o, "kind")),
        .name = try allocator.dupe(u8, try reqStr(o, "name")),
        .parent = try optU32(o, "parent"),
        .source_path = if (try optStr(o, "source_path")) |sp|
            try allocator.dupe(u8, sp)
        else
            null,
        .is_crate = try reqBool(o, "is_crate"),
        .is_extern = try reqBool(o, "is_extern"),
        .span = try decodeSpan(try req(o, "span")),
        .items = try decodeIdSlice(allocator, try req(o, "items")),
        .attributes = try decodeAttributes(allocator, try req(o, "attributes")),
    };
}

fn decodeEntity(allocator: std.mem.Allocator, v: Json) !spine.Entity {
    const o = try getObj(v);
    return .{
        .id = @intCast(try reqU32(o, "id")),
        .kind = try decodeEntityKind(try reqStr(o, "kind")),
        .name = try allocator.dupe(u8, try reqStr(o, "name")),
        .span = try decodeSpan(try req(o, "span")),
        .visibility = try decodeVisibility(allocator, try req(o, "visibility")),
        .parent = try optU32(o, "parent"),
        .resolved = try optU32(o, "resolved"),
        .renamed_to = if (try optStr(o, "renamed_to")) |rn|
            try allocator.dupe(u8, rn)
        else
            null,
        .attributes = try decodeAttributes(allocator, try req(o, "attributes")),
    };
}

fn decodeUseDecl(allocator: std.mem.Allocator, v: Json) !graph.UseDecl {
    const o = try getObj(v);
    const kind_str = try reqStr(o, "kind");
    const target: spine.EntityId = @intCast(try reqU32(o, "target"));
    const kind: graph.UseKind = if (std.mem.eql(u8, kind_str, "plain")) .{ .plain = target } else if (std.mem.eql(u8, kind_str, "alias")) .{ .alias = target } else if (std.mem.eql(u8, kind_str, "glob")) .glob else return error.BadWireFormat;
    return .{
        .id = @intCast(try reqU32(o, "id")),
        .kind = kind,
        .local_name = try allocator.dupe(u8, try reqStr(o, "local_name")),
        .is_pub_export = try reqBool(o, "is_pub_export"),
        .target = target,
        .span = try decodeSpan(try req(o, "span")),
    };
}

fn decodeDeps(allocator: std.mem.Allocator, v: Json) ![]const graph.CrateDep {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(graph.CrateDep) = .empty;
    for (arr.items) |dv| {
        const d = try getObj(dv);
        try list.append(allocator, .{
            .extern_name = try allocator.dupe(u8, try reqStr(d, "extern_name")),
            .local_alias = try allocator.dupe(u8, try reqStr(d, "local_alias")),
            .id = @intCast(try reqU32(d, "id")),
        });
    }
    return list.toOwnedSlice(allocator);
}

fn decodeCrateKind(s: []const u8) !graph.CrateKind {
    if (std.mem.eql(u8, s, "lib")) return .lib;
    if (std.mem.eql(u8, s, "bin")) return .bin;
    return error.BadWireFormat;
}

// ── v2 string/float/id helpers ─────────────────────────────────────────────

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

fn decodeIdList(allocator: std.mem.Allocator, v: Json) ![]const exprs.NodeId {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
    for (arr.items) |it| {
        const x = switch (it) {
            .integer => |i| i,
            else => return error.BadWireFormat,
        };
        try list.append(allocator, @intCast(x));
    }
    return list.toOwnedSlice(allocator);
}

// ── v2 literals ────────────────────────────────────────────────────────────

fn decodeIntLit(allocator: std.mem.Allocator, v: Json) !exprs.IntLit {
    const o = try getObj(v);
    const base_s = try reqStr(o, "base");
    const base: @FieldType(exprs.IntLit, "base") =
        if (std.mem.eql(u8, base_s, "dec")) .dec else if (std.mem.eql(u8, base_s, "hex")) .hex else if (std.mem.eql(u8, base_s, "oct")) .oct else if (std.mem.eql(u8, base_s, "bin")) .bin else return error.BadWireFormat;
    const value: i128 = std.fmt.parseInt(i128, try reqStr(o, "value"), 10) catch return error.BadWireFormat;
    const suffix = try optStr(o, "ty_suffix");
    return .{
        .text = try allocator.dupe(u8, try reqStr(o, "text")),
        .value = value,
        .base = base,
        .ty_suffix = if (suffix) |s| try allocator.dupe(u8, s) else null,
    };
}

fn decodeFloatLit(allocator: std.mem.Allocator, v: Json) !exprs.FloatLit {
    const o = try getObj(v);
    return .{
        .text = try allocator.dupe(u8, try reqStr(o, "text")),
        .value = try reqFloat(o, "value"),
    };
}

fn decodeCharLit(allocator: std.mem.Allocator, v: Json) !exprs.CharLit {
    const o = try getObj(v);
    return .{
        .text = try allocator.dupe(u8, try reqStr(o, "text")),
        .value = @intCast(try reqU32(o, "value")),
    };
}

fn decodeStringLit(allocator: std.mem.Allocator, v: Json) !exprs.StringLit {
    const o = try getObj(v);
    return .{ .bytes = try allocator.dupe(u8, try reqStr(o, "bytes")) };
}

fn decodeLiteral(allocator: std.mem.Allocator, v: Json) !exprs.Literal {
    const o = try getObj(v);
    const tag = try reqStr(o, "kind");
    const val = try req(o, "value");
    if (std.mem.eql(u8, tag, "int")) return .{ .int = try decodeIntLit(allocator, val) };
    if (std.mem.eql(u8, tag, "float")) return .{ .float = try decodeFloatLit(allocator, val) };
    if (std.mem.eql(u8, tag, "character")) return .{ .character = try decodeCharLit(allocator, val) };
    if (std.mem.eql(u8, tag, "string")) return .{ .string = try decodeStringLit(allocator, val) };
    if (std.mem.eql(u8, tag, "boolean")) {
        const b = switch (val) {
            .bool => |x| x,
            else => return error.BadWireFormat,
        };
        return .{ .boolean = b };
    }
    return error.BadWireFormat;
}

// ── v2 types ───────────────────────────────────────────────────────────────

fn decodePathSegments(allocator: std.mem.Allocator, v: Json) ![]const types.PathSegment {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(types.PathSegment) = .empty;
    for (arr.items) |it| {
        const o = try getObj(it);
        try list.append(allocator, .{
            .name = try allocator.dupe(u8, try reqStr(o, "name")),
            .id = try reqOptionalId(o, "id"),
        });
    }
    return list.toOwnedSlice(allocator);
}

fn decodeTypeList(allocator: std.mem.Allocator, v: Json) anyerror![]const types.Type {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(types.Type) = .empty;
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
    return error.BadWireFormat;
}

// ── v2 enum discriminants ──────────────────────────────────────────────────

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

// ── v2 expressions / blocks ────────────────────────────────────────────────

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
        for (arms_arr.items) |av| {
            const ao = try getObj(av);
            try arms.append(allocator, .{
                .patterns = try decodeIdList(allocator, try req(ao, "patterns")),
                .guard = try reqOptionalId(ao, "guard"),
                .body = try reqU32(ao, "body"),
            });
        }
        return .{ .match = .{
            .scrutinee = try reqU32(q, "scrutinee"),
            .arms = try arms.toOwnedSlice(allocator),
            .option_scrutinee = try reqBool(q, "option_scrutinee"),
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
        const fields_arr = switch (try req(q, "fields")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var fields: std.ArrayListUnmanaged(exprs.FieldInit) = .empty;
        for (fields_arr.items) |fv| {
            const fo = try getObj(fv);
            try fields.append(allocator, .{
                .field = try allocator.dupe(u8, try reqStr(fo, "field")),
                .value = try reqU32(fo, "value"),
                .shorthand = try reqBool(fo, "shorthand"),
            });
        }
        return .{ .struct_lit = .{
            .def = @intCast(try reqU32(q, "def")),
            .fields = try fields.toOwnedSlice(allocator),
            .base = try reqOptionalId(q, "base"),
        } };
    }
    if (std.mem.eql(u8, tag, "enum_variant")) {
        const q = try getObj(val);
        const named_arr = switch (try req(q, "named_fields")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var named: std.ArrayListUnmanaged(exprs.FieldInit) = .empty;
        for (named_arr.items) |fv| {
            const fo = try getObj(fv);
            try named.append(allocator, .{
                .field = try allocator.dupe(u8, try reqStr(fo, "field")),
                .value = try reqU32(fo, "value"),
                .shorthand = try reqBool(fo, "shorthand"),
            });
        }
        return .{ .enum_variant = .{
            .def = @intCast(try reqU32(q, "def")),
            .variant = try allocator.dupe(u8, try reqStr(q, "variant")),
            .tuple_fields = try decodeIdList(allocator, try req(q, "tuple_fields")),
            .named_fields = try named.toOwnedSlice(allocator),
        } };
    }
    if (std.mem.eql(u8, tag, "field")) {
        const q = try getObj(val);
        return .{ .field = .{
            .base = try reqU32(q, "base"),
            .field = try allocator.dupe(u8, try reqStr(q, "field")),
            .resolved = @intCast(try reqU32(q, "resolved")),
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
        return .{ .unary = .{
            .op = if (std.mem.eql(u8, op, "negate")) .negate else if (std.mem.eql(u8, op, "logical_not")) .logical_not else if (std.mem.eql(u8, op, "bit_not")) .bit_not else if (std.mem.eql(u8, op, "deref")) .deref else return error.BadWireFormat,
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

// ── v2 patterns ────────────────────────────────────────────────────────────

fn decodePatternKind(allocator: std.mem.Allocator, tag: []const u8, val: Json) !exprs.PatternKind {
    if (std.mem.eql(u8, tag, "wildcard")) return .{ .wildcard = {} };
    if (std.mem.eql(u8, tag, "binding")) {
        const b = try getObj(val);
        return .{ .binding = .{
            .name = try allocator.dupe(u8, try reqStr(b, "name")),
            .mode = try decodeBindMode(try reqStr(b, "mode")),
            .mutable = try reqBool(b, "mutable"),
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
        const fields_arr = switch (try req(t, "fields")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var fields: std.ArrayListUnmanaged(exprs.FieldPat) = .empty;
        for (fields_arr.items) |fv| {
            const fo = try getObj(fv);
            try fields.append(allocator, .{
                .field = try allocator.dupe(u8, try reqStr(fo, "field")),
                .pat = try reqOptionalId(fo, "pat"),
                .shorthand = try reqBool(fo, "shorthand"),
            });
        }
        return .{ .struct_pat = .{
            .def = @intCast(try reqU32(t, "def")),
            .fields = try fields.toOwnedSlice(allocator),
            .rest = try reqBool(t, "rest"),
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

// ── v2 statements ──────────────────────────────────────────────────────────

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

// ── v2 bodies / params ─────────────────────────────────────────────────────

fn decodeParam(allocator: std.mem.Allocator, v: Json) !items.Param {
    const o = try getObj(v);
    return .{
        .name = try allocator.dupe(u8, try reqStr(o, "name")),
        .ty = try decodeType(allocator, try req(o, "ty")),
        .span = try decodeSpan(try req(o, "span")),
    };
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
        const params_arr = switch (try req(fo, "params")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var params_list: std.ArrayListUnmanaged(items.Param) = .empty;
        for (params_arr.items) |pv| try params_list.append(allocator, try decodeParam(allocator, pv));
        return .{ .fn_ = .{
            .params = try params_list.toOwnedSlice(allocator),
            .ret = try decodeType(allocator, try req(fo, "ret")),
            .body = try reqU32(fo, "body"),
        } };
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
    for (exprs_arr.items) |ev| try exprs_list.append(allocator, try decodeExpr(allocator, ev));

    const stmts_arr = switch (try req(o, "stmts")) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var stmts_list: std.ArrayListUnmanaged(exprs.Statement) = .empty;
    for (stmts_arr.items) |sv| try stmts_list.append(allocator, try decodeStatement(allocator, sv));

    const pats_arr = switch (try req(o, "pats")) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var pats_list: std.ArrayListUnmanaged(exprs.Pattern) = .empty;
    for (pats_arr.items) |pv| try pats_list.append(allocator, try decodePattern(allocator, pv));

    const types_arr = switch (try req(o, "types")) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    for (types_arr.items) |tv| try types_list.append(allocator, try decodeType(allocator, tv));

    const bodies_arr = switch (try req(o, "bodies")) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var bodies_list: std.ArrayListUnmanaged(BodyKind) = .empty;
    for (bodies_arr.items) |bv| try bodies_list.append(allocator, try decodeBodyKind(allocator, bv));

    return .{
        .exprs = try exprs_list.toOwnedSlice(allocator),
        .stmts = try stmts_list.toOwnedSlice(allocator),
        .pats = try pats_list.toOwnedSlice(allocator),
        .types = try types_list.toOwnedSlice(allocator),
        .bodies = try bodies_list.toOwnedSlice(allocator),
    };
}

/// Empty Bodies (no tables; used when a v2 document has no `bodies` field or
/// when the source was a v1 document).
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
        const edition: u16 = @intCast(try reqU32(c, "edition"));
        const kind = try decodeCrateKind(try reqStr(c, "kind"));
        const root: spine.EntityId = @intCast(try reqU32(c, "root"));
        const is_translated = try reqBool(c, "is_translated");
        const deps = try decodeDeps(allocator, try req(c, "deps"));

        // Entities populate the shared symbol table first (dense ids 0..N).
        const entities_arr = switch (try req(c, "entities")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        for (entities_arr.items) |ev| {
            const e = try decodeEntity(allocator, ev);
            _ = try g.symbol_table.add(e);
        }
        // Modules mirror the symbol table (dense id == index).
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
    }

    return g;
}

/// Lossless decode of the wire format (v1 or v2) into an owned CrateGraph.
/// The graph duplicates every string and owns every slice; free it with
/// `g.deinit()`. Body data (v2) is ignored — use `parseFull` to recover it.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !graph.CrateGraph {
    var parsed = std.json.parseFromSlice(Json, allocator, bytes, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();
    const root_map = getObj(parsed.value) catch return error.BadWireFormat;
    const ver: u32 = @intCast(try reqU32(root_map, "format_version"));
    if (ver != 1 and ver != 2) return error.InvalidFormatVersion;
    return decodeGraph(allocator, root_map);
}

/// Lossless decode into the full model (graph + bodies). Accepts wire
/// versions 1 and 2; a v1 document (or a v2 without `bodies`) yields an empty
/// Bodies. The graph and bodies own allocations made with `allocator`
/// (bodies include heap type-node pointers and duped strings). Recommended
/// usage: pass an `ArenaAllocator` and call `arena.deinit()` to release the
/// whole model at once; otherwise free the graph with `graph.deinit()` and
/// the bodies' individual allocations manually.
pub fn parseFull(allocator: std.mem.Allocator, bytes: []const u8) !FullModel {
    var parsed = std.json.parseFromSlice(Json, allocator, bytes, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();
    const root_map = getObj(parsed.value) catch return error.BadWireFormat;
    const ver: u32 = @intCast(try reqU32(root_map, "format_version"));
    if (ver != 1 and ver != 2) return error.InvalidFormatVersion;

    var g = try decodeGraph(allocator, root_map);
    errdefer g.deinit();

    var bodies = emptyBodies();
    if (ver == 2) {
        if (root_map.get("bodies")) |bv| {
            bodies = try decodeBodies(allocator, bv);
        }
    }

    return .{ .graph = g, .bodies = bodies };
}

// ---------------------------------------------------------------------------
// Encode helpers (build a Json value tree owned by `allocator`)
// ---------------------------------------------------------------------------

fn freeValue(v: *Json, allocator: std.mem.Allocator) void {
    switch (v.*) {
        .object => |*o| {
            var it = o.iterator();
            while (it.next()) |entry| freeValue(entry.value_ptr, allocator);
            o.deinit(allocator);
        },
        .array => |*ar| {
            for (ar.items) |*item| freeValue(item, allocator);
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

/// Compute, for a crate rooted at `root`, which entity ids belong to it
/// (the module subtree plus all entities/uses attached to it, transitively).
/// `root` seeds the set; modules and entities whose parent is in the set join,
/// and modules whose items join are pulled in, iterated to a fixpoint.
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

    var uses = Array.init(allocator);
    for (g.uses.items) |u| {
        if (u.id < member.len and member[u.id]) try uses.append(try encodeUseDecl(allocator, u));
    }
    try o.put(allocator, "uses", .{ .array = uses });

    return .{ .object = o };
}

// ── v2 bodies: encode helpers (in-memory model → wire JSON) ────────────────

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
    // i128/u64 values can exceed std.json's i64 integer range (fnv's
    // FNV_OFFSET_BASIS ≈ 1.47e19 > i64::max), so encode `value` as a decimal
    // string; decode re-parses it with std.fmt.parseInt(i128, s, 10).
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

/// Primitive encode: `{ "kind": "int", "value": {...} }` etc.
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
        .boolean => |v| {
            try o.put(allocator, "kind", .{ .string = "boolean" });
            try o.put(allocator, "value", .{ .bool = v });
        },
    }
    return .{ .object = o };
}

fn encodeType(allocator: std.mem.Allocator, ty: types.Type) !Json {
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
        .closure, .iterator_chain, .unsupported => return error.UnsupportedWireVariant,
    }
    return .{ .object = o };
}

/// Move the `kind` + `value` entries from `src` (an object built by an
/// encodeExprKind/encodePatternKind/encodeStatementKind call) into `dst`, then
/// free `src`'s map. Ownership of the value Json trees transfers to `dst`.
/// Note: ObjectMap.put stores the key slice as given (no dupe), so the keys
/// here are static string literals — they must NOT be freed.
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
            try o.put(allocator, "kind", .{ .string = "struct_pat" });
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

fn encodeRoot(
    allocator: std.mem.Allocator,
    g: *const graph.CrateGraph,
    bodies: ?*const Bodies,
    fmt_version: u32,
) ![]u8 {
    var root_map = ObjectMap.empty;
    try root_map.put(allocator, "format_version", mkInt(fmt_version));
    try root_map.put(allocator, "sidecar", encodeOptStr(g.sidecar));
    try root_map.put(allocator, "toolchain", encodeOptStr(g.toolchain));

    var crates_arr = Array.init(allocator);
    for (g.crates.items) |c| {
        const member = try crateMembers(allocator, g, c.root);
        defer allocator.free(member);
        try crates_arr.append(try encodeCrate(allocator, g, c, member));
    }
    try root_map.put(allocator, "crates", .{ .array = crates_arr });

    if (bodies) |b| {
        try root_map.put(allocator, "bodies", try encodeBodies(allocator, b));
    }

    var root_val = Json{ .object = root_map };
    defer freeValue(&root_val, allocator);

    // Zig 0.16: std.json.stringify was replaced by Stringify.valueAlloc, which
    // owns and returns a []u8 buffer to be freed with the passed allocator.
    return std.json.Stringify.valueAlloc(allocator, root_val, .{});
}

/// Write the graph back to the wire JSON as a v1 document (no bodies). The
/// returned `[]u8` is owned by the caller and must be freed with the passed
/// allocator. Inverses `parse` (graph data only; bodies are omitted).
pub fn encode(allocator: std.mem.Allocator, g: *const graph.CrateGraph) ![]u8 {
    return encodeRoot(allocator, g, null, 1);
}

/// Write the full model back to the wire JSON as a v2 document (graph + bodies).
/// The returned `[]u8` is owned by the caller and must be freed with the passed
/// allocator. Inverses `parseFull`.
pub fn encodeFull(allocator: std.mem.Allocator, model: FullModel) ![]u8 {
    return encodeRoot(allocator, &model.graph, &model.bodies, wire_format_version);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// Read the golden fixture at test runtime: `@embedFile` cannot cross the
// module boundary with `..`, and the test runner initializes `std.testing.io`.
fn miniJson(allocator: std.mem.Allocator) ![]const u8 {
    const test_io = std.testing.io;
    var io_buf: [4096]u8 = undefined;
    var dir = std.Io.Dir.cwd();
    const file = try dir.openFile(test_io, "test/mini.json", .{});
    defer file.close(test_io);
    var reader = file.reader(test_io, &io_buf);
    return reader.interface.allocRemaining(allocator, .limited(1 << 20));
}

fn parseMini(allocator: std.mem.Allocator) !graph.CrateGraph {
    const bytes = try miniJson(allocator);
    defer allocator.free(bytes);
    return parse(allocator, bytes);
}

fn findItemByName(gg: *const graph.CrateGraph, item_ids: []const spine.EntityId, nm: []const u8) ?spine.EntityId {
    for (item_ids) |id| {
        if (gg.symbol_table.get(id)) |e| {
            if (std.mem.eql(u8, e.name, nm)) return id;
        }
    }
    return null;
}

test "1. parse mini: one crate, edition 2021, lib" {
    const allocator = std.testing.allocator;
    var g = try parseMini(allocator);
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 1), g.crates.items.len);
    const c = g.findCrate("mini") orelse return error.expectedMini;
    try std.testing.expectEqual(@as(u16, 2021), c.edition);
    try std.testing.expectEqual(graph.CrateKind.lib, c.kind);
}

test "2. root module is_crate; items include module/struct/enum/fns/use" {
    const allocator = std.testing.allocator;
    var g = try parseMini(allocator);
    defer g.deinit();
    const c = g.findCrate("mini") orelse return error.expectedMini;
    const root = g.module(c.root) orelse return error.noRoot;
    try std.testing.expect(root.is_crate);

    const util_id = findItemByName(&g, root.items, "util") orelse return error.missingUtil;
    try std.testing.expectEqual(spine.EntityKind.module, g.symbol_table.get(util_id).?.kind);
    try std.testing.expectEqual(graph.ModuleKind.file, g.module(util_id).?.kind);
    _ = (findItemByName(&g, root.items, "Point")) orelse return error.missingPoint;
    _ = (findItemByName(&g, root.items, "Shape")) orelse return error.missingShape;
    _ = (findItemByName(&g, root.items, "area")) orelse return error.missingArea;
    _ = (findItemByName(&g, root.items, "origin")) orelse return error.missingOrigin;

    const use_id = findItemByName(&g, root.items, "helper") orelse return error.missingUse;
    const use_entity = g.symbol_table.get(use_id).?;
    try std.testing.expectEqual(spine.EntityKind.use_, use_entity.kind);
    try std.testing.expect(use_entity.resolved != null);
    const use = g.useById(use_id) orelse return error.missingUseDecl;
    try std.testing.expect(use.is_pub_export);
}

test "3. util module items include helper" {
    const allocator = std.testing.allocator;
    var g = try parseMini(allocator);
    defer g.deinit();
    const c = g.findCrate("mini") orelse return error.expectedMini;
    const root = g.module(c.root) orelse return error.noRoot;
    const util_id = findItemByName(&g, root.items, "util") orelse return error.missingUtil;
    const util_module = g.module(util_id) orelse return error.noUtilModule;
    var has_helper = false;
    for (util_module.items) |item_id| {
        if (g.symbol_table.get(item_id)) |e| {
            if (std.mem.eql(u8, e.name, "helper")) has_helper = true;
        }
    }
    try std.testing.expect(has_helper);
}

test "4. pub use resolves to helper EntityId and is reachable via graph" {
    const allocator = std.testing.allocator;
    var g = try parseMini(allocator);
    defer g.deinit();
    const c = g.findCrate("mini") orelse return error.expectedMini;
    const root = g.module(c.root) orelse return error.noRoot;
    const use_id = findItemByName(&g, root.items, "helper") orelse return error.missingUse;
    const use_entity = g.symbol_table.get(use_id).?;
    const target_id = use_entity.resolved orelse return error.unresolvedUse;
    const target = g.symbol_table.get(target_id) orelse return error.noTarget;
    try std.testing.expectEqualStrings("helper", target.name);
    // graph.module can reach helper via the util module.
    const util_id = findItemByName(&g, root.items, "util") orelse return error.missingUtil;
    const util_module = g.module(util_id) orelse return error.noUtilModule;
    try std.testing.expect(std.mem.indexOfScalar(spine.EntityId, util_module.items, target_id) != null);
}

test "5. wrong format_version is rejected" {
    const allocator = std.testing.allocator;
    const payload =
        \\{"format_version": 99, "sidecar": null, "toolchain": null, "crates": []}
    ;
    try std.testing.expectError(error.InvalidFormatVersion, parse(allocator, payload));
}

test "6. unknown attribute preserved (known == false, meta matches)" {
    const allocator = std.testing.allocator;
    var g = try parseMini(allocator);
    defer g.deinit();
    const c = g.findCrate("mini") orelse return error.expectedMini;
    const root = g.module(c.root) orelse return error.noRoot;
    const point_id = findItemByName(&g, root.items, "Point") orelse return error.missingPoint;
    const point = g.symbol_table.get(point_id).?;
    try std.testing.expect(point.attributes.len >= 1);
    const doc = point.attributes[0];
    try std.testing.expectEqualStrings("doc", doc.name);
    try std.testing.expect(!doc.known);
    try std.testing.expectEqualStrings("a point", doc.meta);
}

test "7. encode round-trips (crate/module/entity/use counts equal)" {
    const allocator = std.testing.allocator;
    var g = try parseMini(allocator);
    defer g.deinit();
    const encoded = try encode(allocator, &g);
    defer allocator.free(encoded);
    var g2 = try parse(allocator, encoded);
    defer g2.deinit();
    try std.testing.expectEqual(g.crates.items.len, g2.crates.items.len);
    try std.testing.expectEqual(g.modules.items.len, g2.modules.items.len);
    try std.testing.expectEqual(g.symbol_table.count(), g2.symbol_table.count());
    try std.testing.expectEqual(g.uses.items.len, g2.uses.items.len);
}

test "8. invalid JSON is rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidJson, parse(allocator, "this is not json {"));
}

fn fnvJson(allocator: std.mem.Allocator) ![]const u8 {
    const test_io = std.testing.io;
    var io_buf: [4096]u8 = undefined;
    var dir = std.Io.Dir.cwd();
    const file = try dir.openFile(test_io, "test/fnv.json", .{});
    defer file.close(test_io);
    var reader = file.reader(test_io, &io_buf);
    return reader.interface.allocRemaining(allocator, .limited(1 << 22));
}

test "parseFull fnv v2 round-trip" {
    const allocator = std.testing.allocator;
    const bytes = try fnvJson(allocator);
    defer allocator.free(bytes);

    // Parse the v2 fixture (arena-backed so all bodies allocations are freed
    // on scope exit regardless of depth).
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const model = try parseFull(arena.allocator(), bytes);
    // Bodies decode correctly and mirror the in-memory fnv model.
    try std.testing.expectEqual(@as(usize, 13), model.bodies.exprs.len);
    try std.testing.expectEqual(@as(usize, 4), model.bodies.stmts.len);
    try std.testing.expectEqual(@as(usize, 2), model.bodies.pats.len);
    try std.testing.expectEqual(@as(usize, 2), model.bodies.types.len);
    try std.testing.expectEqual(@as(usize, 7), model.bodies.bodies.len);
    // bodies[1] (FNV_OFFSET_BASIS) is a const body whose init is expr 0.
    try std.testing.expectEqual(
        BodyKind.const_,
        std.meta.activeTag(model.bodies.bodies[1]),
    );
    try std.testing.expectEqual(
        BodyKind.fn_,
        std.meta.activeTag(model.bodies.bodies[3]),
    );

    // Re-encode as v2 (with bodies).
    const encoded = try encodeFull(arena.allocator(), model);

    // The produced document carries format_version == 2.
    var parsed = std.json.parseFromSlice(Json, allocator, encoded, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();
    const root_map = getObj(parsed.value) catch return error.BadWireFormat;
    try std.testing.expectEqual(@as(u32, 2), try reqU32(root_map, "format_version"));

    // The produced output is parseable again and keeps the body tables.
    const model2 = try parseFull(arena.allocator(), encoded);
    try std.testing.expectEqual(@as(usize, 13), model2.bodies.exprs.len);
    try std.testing.expectEqual(@as(usize, 2), model2.bodies.types.len);
    try std.testing.expectEqual(@as(usize, 7), model2.bodies.bodies.len);
}
