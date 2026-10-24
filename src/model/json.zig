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

const Json = std.json.Value;
const ObjectMap = std.json.ObjectMap; // unmanaged (allocator passed per call)
const Array = std.json.Array; // managed (init(allocator))

/// The wire format version this build writes and accepts (data-model.md §4).
/// v1: crate graph only (no bodies). v2: adds `bodies` (expressions,
/// statements, patterns, types, per-entity body selector). v3: lossless
/// dependency feature metadata (`default_features` and `features`).
pub const wire_format_version: u32 = 3;

// ── Wire v3 body data structures (mirror emit.Bodies) ─────────────────────
// Defined here, not in emit.zig, so the json module stays dependency-free of
// the emit layer (emit.zig imports json.zig). Field layout matches
// emit.ConstBody / emit.FnBody / emit.BodyKind / emit.Bodies id-for-id.

// Shared body tables live in bodies.zig (leaf) so json and emit do not
// create an import cycle. Re-export as aliases — emit.Bodies == json.Bodies.
pub const bodies_mod = @import("bodies.zig");
pub const ConstBody = bodies_mod.ConstBody;
pub const FnBody = bodies_mod.FnBody;
pub const StructMethod = bodies_mod.StructMethod;
pub const StructBody = bodies_mod.StructBody;
pub const TraitMethodSig = bodies_mod.TraitMethodSig;
pub const TraitBody = bodies_mod.TraitBody;
pub const EnumBody = bodies_mod.EnumBody;
pub const TypeAliasBody = bodies_mod.TypeAliasBody;
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

/// Decode a nullable string whose presence is part of the v2 body contract.
/// The value may be null, but an omitted key is incomplete wire data.
fn reqOptStr(o: ObjectMap, key: []const u8) !?[]const u8 {
    return switch (try req(o, key)) {
        .string => |s| s,
        .null => null,
        else => error.BadWireFormat,
    };
}
/// Read a full-width `u64` count off the wire.
///
/// `std.json.Value.integer` is `i64`, so a count at or above 2^63 arrives as
/// `number_string` carrying the raw digits. Both tags are the same unquoted
/// JSON number on the wire; a token no `u64` holds, and a negative one, are
/// `BadWireFormat` rather than a clamp or a truncation.
fn decodeU64Count(v: Json) !u64 {
    return switch (v) {
        .integer => |i| blk: {
            if (i < 0) return error.BadWireFormat;
            break :blk @as(u64, @intCast(i));
        },
        .number_string => |digits| std.fmt.parseInt(u64, digits, 10) catch
            error.BadWireFormat,
        else => error.BadWireFormat,
    };
}

/// A stored `vec![e; N]` count: null, a number, or an expression node.
///
/// Null and a bare integer keep the exact meaning — and the exact bytes —
/// they have always had, so a stored `vec![e; 13]` still reads as the count
/// 13 it always did. The object form is the one addition, for a count the
/// translator does not know until the target evaluates it.
///
/// That object is read strictly: exactly the keys `tag` and `value`, `tag`
/// the string `expression`, `value` an integer node id. A third key, another
/// tag, or a `value` that is not a node id is `BadWireFormat` — a count this
/// decoder cannot read exactly is never one it is free to guess at. The node
/// id is read through `decodeCountNodeId`, whose range check turns a negative
/// or too-wide `value` into that same `BadWireFormat` rather than a trap.
///
/// `decodeExprKind` reads the count before it decodes the element id list, so
/// a count no `u64` holds is rejected without having allocated any of the
/// element data it would have described. The decoded count owns nothing, so
/// that rollback stays whole.
fn decodeVecRepeatCount(o: ObjectMap, key: []const u8) !?exprs.VecRepeatCount {
    const v = try req(o, key);
    switch (v) {
        .null => return null,
        .object => |count| {
            if (count.count() != 2) return error.BadWireFormat;
            const count_tag = try reqStr(count, "tag");
            if (!std.mem.eql(u8, count_tag, "expression")) return error.BadWireFormat;
            return .{ .expression = try decodeCountNodeId(count, "value") };
        },
        else => return .{ .literal = try decodeU64Count(v) },
    }
}

/// The expression node a stored `vec![e; N]` count names, read with its range
/// checked.
///
/// The layer-wide `reqU32` is a bare `@intCast`, so it traps on an integer a
/// `u32` cannot hold; the canonical semantic-IR codec checks the range first
/// (`checkedU32` in src/ir/serialize.zig) and reports `BadWireFormat` instead.
/// Only this field takes the checked reader, so every other legacy id read
/// keeps the behaviour it has always had. `std.json.Value.integer` is `i64`,
/// so comparing in `i64` is exact — no count id is ever truncated or wrapped.
fn decodeCountNodeId(o: ObjectMap, key: []const u8) !u32 {
    const i = switch (try req(o, key)) {
        .integer => |x| x,
        else => return error.BadWireFormat,
    };
    if (i < 0 or i > @as(i64, std.math.maxInt(u32))) return error.BadWireFormat;
    return @intCast(i);
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
        const owned_value = try allocator.dupe(u8, value);
        errdefer allocator.free(owned_value);
        try list.append(allocator, owned_value);
    }
    return list.toOwnedSlice(allocator);
}
/// Decode a required v3 body string list. Empty lists are represented by
/// an explicit `[]`; an omitted key is incomplete wire data.
fn decodeRequiredStringList(
    allocator: std.mem.Allocator,
    o: ObjectMap,
    key: []const u8,
) ![]const []const u8 {
    return decodeStringList(allocator, try req(o, key));
}

fn decodeReceiver(s: []const u8) !items.Receiver {
    if (std.mem.eql(u8, s, "owned")) return .owned;
    if (std.mem.eql(u8, s, "ref_")) return .ref_;
    if (std.mem.eql(u8, s, "mut_ref")) return .mut_ref;
    return error.BadWireFormat;
}

fn freeDecodedVisibility(allocator: std.mem.Allocator, visibility: spine.Visibility) void {
    switch (visibility) {
        .in_path => |path| allocator.free(path),
        else => {},
    }
}

fn freeDecodedAttributes(allocator: std.mem.Allocator, attributes: []const spine.Attribute) void {
    for (attributes) |attribute| {
        allocator.free(attribute.name);
        allocator.free(attribute.meta);
    }
    allocator.free(attributes);
}

fn freeDecodedAttributeList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(spine.Attribute),
) void {
    for (list.items) |attribute| {
        allocator.free(attribute.name);
        allocator.free(attribute.meta);
    }
    list.deinit(allocator);
}

fn freeDecodedPathSegments(
    allocator: std.mem.Allocator,
    segments: []const types.PathSegment,
) void {
    for (segments) |segment| allocator.free(segment.name);
    allocator.free(segments);
}

fn freeDecodedPath(allocator: std.mem.Allocator, path: types.Path) void {
    freeDecodedPathSegments(allocator, path.segments);
}

/// An external nominal owns its Rust path segments and its generic arguments.
/// Neither is a graph entity, so both are released here and nowhere else.
fn freeDecodedExternalNominal(
    allocator: std.mem.Allocator,
    external: types.ExternalNominal,
) void {
    freeDecodedStringList(allocator, external.path);
    freeDecodedTypeSlice(allocator, external.args);
}

fn freeDecodedAssociatedTypeBinding(
    allocator: std.mem.Allocator,
    binding: types.AssociatedTypeBinding,
) void {
    allocator.free(binding.name);
    freeDecodedType(allocator, binding.ty);
}

fn freeDecodedAssociatedTypeBindingSlice(
    allocator: std.mem.Allocator,
    bindings: []const types.AssociatedTypeBinding,
) void {
    for (bindings) |binding| freeDecodedAssociatedTypeBinding(allocator, binding);
    if (bindings.len > 0) allocator.free(bindings);
}

fn freeDecodedAssociatedTypeBindingList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(types.AssociatedTypeBinding),
) void {
    for (list.items) |binding| freeDecodedAssociatedTypeBinding(allocator, binding);
    list.deinit(allocator);
}

fn freeDecodedBound(allocator: std.mem.Allocator, bound: types.Bound) void {
    freeDecodedPath(allocator, bound.path);
    freeDecodedTypeSlice(allocator, bound.args);
    freeDecodedAssociatedTypeBindingSlice(allocator, bound.associated_types);
}

fn freeDecodedBoundSlice(allocator: std.mem.Allocator, bounds: []const types.Bound) void {
    for (bounds) |bound| freeDecodedBound(allocator, bound);
    if (bounds.len > 0) allocator.free(bounds);
}

fn freeDecodedBoundList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(types.Bound),
) void {
    for (list.items) |bound| freeDecodedBound(allocator, bound);
    list.deinit(allocator);
}

fn freeDecodedType(allocator: std.mem.Allocator, ty: types.Type) void {
    switch (ty) {
        .path => |path| freeDecodedPathSegments(allocator, path.segments),
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
        .tuple => |tuple| freeDecodedTypeSlice(allocator, tuple),
        .fn_ptr => |fn_ptr| {
            freeDecodedTypeSlice(allocator, fn_ptr.params);
            freeDecodedType(allocator, fn_ptr.ret);
            allocator.destroy(@constCast(fn_ptr));
        },
        .generic_inst => |generic_inst| {
            freeDecodedTypeSlice(allocator, generic_inst.args.params);
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
        .external_nominal => |external| freeDecodedExternalNominal(allocator, external),
        .@"opaque" => |opaque_ty| {
            freeDecodedBoundSlice(allocator, opaque_ty.bounds);
            if (opaque_ty.concrete) |concrete| {
                freeDecodedType(allocator, concrete.*);
                allocator.destroy(@constCast(concrete));
            }
        },
        .dyn_trait => |bounds| freeDecodedBoundSlice(allocator, bounds),
        else => {},
    }
}

fn freeDecodedTypeSlice(allocator: std.mem.Allocator, types_slice: []const types.Type) void {
    for (types_slice) |ty| freeDecodedType(allocator, ty);
    allocator.free(types_slice);
}

fn freeDecodedTypeList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(types.Type),
) void {
    for (list.items) |ty| freeDecodedType(allocator, ty);
    list.deinit(allocator);
}

fn freeDecodedCrateDepList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(graph.CrateDep),
) void {
    for (list.items) |dependency| {
        allocator.free(dependency.extern_name);
        allocator.free(dependency.local_alias);
        freeDecodedStringList(allocator, dependency.features);
    }
    list.deinit(allocator);
}

fn freeDecodedIdList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(exprs.NodeId),
) void {
    list.deinit(allocator);
}

fn freeDecodedLiteral(allocator: std.mem.Allocator, literal: exprs.Literal) void {
    switch (literal) {
        .int => |int_literal| {
            allocator.free(int_literal.text);
            if (int_literal.ty_suffix) |suffix| allocator.free(suffix);
        },
        .float => |float_literal| allocator.free(float_literal.text),
        .character => |char_literal| allocator.free(char_literal.text),
        .string => |string_literal| allocator.free(string_literal.bytes),
        .byte_array => |byte_array| allocator.free(byte_array.items),
        .boolean => {},
    }
}
fn freeDecodedBlockExpr(allocator: std.mem.Allocator, block: exprs.BlockExpr) void {
    if (block.statements.len > 0) allocator.free(block.statements);
    if (block.labelled) |labelled| allocator.free(labelled);
}
fn freeDecodedElseBranch(allocator: std.mem.Allocator, branch: exprs.ElseBranch) void {
    switch (branch) {
        .block => |block| freeDecodedBlockExpr(allocator, block),
        else => {},
    }
}
fn freeDecodedIterKind(allocator: std.mem.Allocator, iter_kind: exprs.IterKind) void {
    switch (iter_kind) {
        .multi => |ids| allocator.free(ids),
        .adapter => |chain| freeDecodedIteratorChain(allocator, chain),
        else => {},
    }
}

fn freeDecodedUnsupported(allocator: std.mem.Allocator, unsupported: exprs.Unsupported) void {
    allocator.free(unsupported.reason);
}

fn freeDecodedClosure(allocator: std.mem.Allocator, closure: exprs.ClosureExpr) void {
    freeDecodedCaptures(allocator, closure.captures);
    if (closure.params.len > 0) allocator.free(closure.params);
    freeDecodedBlockExpr(allocator, closure.body);
}

fn freeDecodedCaptures(allocator: std.mem.Allocator, captures: []const exprs.Capture) void {
    for (captures) |capture| allocator.free(capture.name);
    // A zero-length slice is not an allocation the allocator handed out, so it
    // is not one it takes back — the same guard `freeDecodedStringList` uses.
    if (captures.len > 0) allocator.free(captures);
}

fn freeDecodedCaptureList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(exprs.Capture),
) void {
    for (list.items) |capture| allocator.free(capture.name);
    list.deinit(allocator);
}

fn freeDecodedIteratorAdapter(
    allocator: std.mem.Allocator,
    adapter: exprs.IteratorAdapter,
) void {
    switch (adapter) {
        .map => |map| freeDecodedClosure(allocator, map.closure),
        .filter => |filter| freeDecodedClosure(allocator, filter.closure),
        .flat_map => |closure| freeDecodedClosure(allocator, closure),
        .other => |unsupported| freeDecodedUnsupported(allocator, unsupported),
        else => {},
    }
}

fn freeDecodedIteratorChain(
    allocator: std.mem.Allocator,
    chain: exprs.IteratorChainExpr,
) void {
    for (chain.adapters) |adapter| freeDecodedIteratorAdapter(allocator, adapter);
    if (chain.adapters.len > 0) allocator.free(chain.adapters);
}

fn freeDecodedExprKind(allocator: std.mem.Allocator, kind: exprs.ExprKind) void {
    switch (kind) {
        .literal => |literal| freeDecodedLiteral(allocator, literal),
        .array => |array| allocator.free(array.elements),
        .range => {},
        .panic_ => |panic_expr| allocator.free(panic_expr.message),
        .vec_lit => |vec_lit| allocator.free(vec_lit.elements),
        .path => |path| freeDecodedTypeSlice(allocator, path.generic_args),
        .block => |block| freeDecodedBlockExpr(allocator, block),
        .if_else => |if_else| {
            freeDecodedBlockExpr(allocator, if_else.then_);
            freeDecodedElseBranch(allocator, if_else.@"else");
        },
        .if_let => |if_let| {
            freeDecodedBlockExpr(allocator, if_let.then_);
            freeDecodedElseBranch(allocator, if_let.@"else");
        },
        .match => |match_expr| {
            for (match_expr.arms) |arm| allocator.free(arm.patterns);
            allocator.free(match_expr.arms);
        },
        .loop_ => |loop_expr| freeDecodedBlockExpr(allocator, loop_expr.body),
        .while_ => |while_expr| freeDecodedBlockExpr(allocator, while_expr.body),
        .for_ => |for_expr| {
            freeDecodedBlockExpr(allocator, for_expr.body);
            freeDecodedIterKind(allocator, for_expr.iter_kind);
        },
        .break_ => |break_expr| {
            if (break_expr.label) |label| allocator.free(label);
        },
        .continue_ => |continue_expr| {
            if (continue_expr.label) |label| allocator.free(label);
        },
        .call => |call| allocator.free(call.args),
        .method_call => |method_call| allocator.free(method_call.args),
        .core_call => |core_call| {
            freeDecodedTypeSlice(allocator, core_call.generic_args);
            allocator.free(core_call.args);
        },
        .core_function => |core_function| freeDecodedTypeSlice(
            allocator,
            core_function.generic_args,
        ),
        .struct_lit => |struct_lit| freeDecodedFieldInits(allocator, struct_lit.fields),
        .enum_variant => |enum_variant| {
            allocator.free(enum_variant.variant);
            allocator.free(enum_variant.tuple_fields);
            freeDecodedFieldInits(allocator, enum_variant.named_fields);
        },
        .external_variant => |external| {
            freeDecodedExternalNominal(allocator, external.owner);
            allocator.free(external.variant);
            allocator.free(external.tuple_fields);
            freeDecodedFieldInits(allocator, external.named_fields);
        },
        .format_write => |format_write| {
            allocator.free(format_write.template);
            allocator.free(format_write.args);
        },
        .cast => |cast| freeDecodedType(allocator, cast.source_type),
        .field => |field| allocator.free(field.field),
        .closure => |closure| freeDecodedClosure(allocator, closure),
        .iterator_chain => |chain| freeDecodedIteratorChain(allocator, chain),
        .unsupported => |unsupported| freeDecodedUnsupported(allocator, unsupported),
        else => {},
    }
}

fn freeDecodedExpr(allocator: std.mem.Allocator, expression: exprs.Expr) void {
    freeDecodedExprKind(allocator, expression.kind);
}

fn freeDecodedExprList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(exprs.Expr),
) void {
    for (list.items) |expression| freeDecodedExpr(allocator, expression);
    list.deinit(allocator);
}

fn freeDecodedPatternKind(allocator: std.mem.Allocator, kind: exprs.PatternKind) void {
    switch (kind) {
        .binding => |binding| allocator.free(binding.name),
        .literal => |literal| freeDecodedLiteral(allocator, literal),
        .path => |path| {
            if (path.variant) |variant| allocator.free(variant);
        },
        .external_variant => |external| {
            freeDecodedExternalNominal(allocator, external.owner);
            allocator.free(external.variant);
            freeDecodedFieldPats(allocator, external.fields);
        },
        .tuple => |tuple| allocator.free(tuple.elements),
        .slice => |slice| allocator.free(slice.elements),
        .struct_pat => |struct_pat| {
            for (struct_pat.fields) |field| allocator.free(field.field);
            allocator.free(struct_pat.fields);
        },
        .@"or" => |or_pat| allocator.free(or_pat.alternatives),
        else => {},
    }
}

fn freeDecodedPattern(allocator: std.mem.Allocator, pattern: exprs.Pattern) void {
    freeDecodedPatternKind(allocator, pattern.kind);
}

fn freeDecodedPatternList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(exprs.Pattern),
) void {
    for (list.items) |pattern| freeDecodedPattern(allocator, pattern);
    list.deinit(allocator);
}

fn freeDecodedStatement(allocator: std.mem.Allocator, statement: exprs.Statement) void {
    switch (statement.kind) {
        .let_else => |let_else| freeDecodedBlockExpr(allocator, let_else.else_block),
        else => {},
    }
}

fn freeDecodedStatementList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(exprs.Statement),
) void {
    for (list.items) |statement| freeDecodedStatement(allocator, statement);
    list.deinit(allocator);
}

fn freeDecodedVariant(allocator: std.mem.Allocator, variant: items.Variant) void {
    allocator.free(variant.name);
    switch (variant.fields) {
        .none => {},
        .tuple => |tuple| freeDecodedTypeSlice(allocator, tuple),
        .named => |named| freeDecodedFields(allocator, named),
    }
}

fn freeDecodedStructMethod(allocator: std.mem.Allocator, method: StructMethod) void {
    allocator.free(method.name);
    freeDecodedVisibility(allocator, method.visibility);
    freeDecodedParams(allocator, method.params);
    freeDecodedType(allocator, method.ret);
    freeDecodedStringList(allocator, method.generic_params);
}

fn freeDecodedTraitMethod(allocator: std.mem.Allocator, method: TraitMethodSig) void {
    allocator.free(method.name);
    freeDecodedParams(allocator, method.params);
    freeDecodedType(allocator, method.ret);
}

fn freeDecodedStructMethods(
    allocator: std.mem.Allocator,
    methods: []const StructMethod,
) void {
    for (methods) |method| {
        allocator.free(method.name);
        freeDecodedVisibility(allocator, method.visibility);
        freeDecodedParams(allocator, method.params);
        freeDecodedType(allocator, method.ret);
        freeDecodedStringList(allocator, method.generic_params);
    }
    if (methods.len > 0) allocator.free(methods);
}

fn freeDecodedTraitMethods(
    allocator: std.mem.Allocator,
    methods: []const TraitMethodSig,
) void {
    for (methods) |method| {
        allocator.free(method.name);
        freeDecodedParams(allocator, method.params);
        freeDecodedType(allocator, method.ret);
    }
    if (methods.len > 0) allocator.free(methods);
}

fn freeDecodedVariants(allocator: std.mem.Allocator, variants: []const items.Variant) void {
    for (variants) |variant| freeDecodedVariant(allocator, variant);
    if (variants.len > 0) allocator.free(variants);
}

fn freeDecodedBodyKind(allocator: std.mem.Allocator, body: BodyKind) void {
    switch (body) {
        .const_ => |const_body| freeDecodedType(allocator, const_body.ty),
        .fn_ => |fn_body| {
            freeDecodedParams(allocator, fn_body.params);
            freeDecodedType(allocator, fn_body.ret);
            freeDecodedStringList(allocator, fn_body.generic_params);
        },
        .struct_ => |struct_body| {
            freeDecodedStringList(allocator, struct_body.generic_params);
            freeDecodedStringList(allocator, struct_body.trait_bounds);
            freeDecodedFields(allocator, struct_body.fields);
            for (struct_body.methods) |method| freeDecodedStructMethod(allocator, method);
            if (struct_body.methods.len > 0) allocator.free(struct_body.methods);
        },
        .enum_ => |enum_body| {
            for (enum_body.variants) |variant| freeDecodedVariant(allocator, variant);
            if (enum_body.variants.len > 0) allocator.free(enum_body.variants);
        },
        .trait_ => |trait_body| {
            allocator.free(trait_body.name);
            freeDecodedStringList(allocator, trait_body.supertraits);
            for (trait_body.methods) |method| freeDecodedTraitMethod(allocator, method);
            if (trait_body.methods.len > 0) allocator.free(trait_body.methods);
        },
        .type_alias => |alias_body| freeDecodedType(allocator, alias_body.target),
        .none => {},
    }
}

fn freeDecodedBodyList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(BodyKind),
) void {
    for (list.items) |body| freeDecodedBodyKind(allocator, body);
    list.deinit(allocator);
}
fn freeDecodedBodies(allocator: std.mem.Allocator, bodies: Bodies) void {
    for (bodies.exprs) |expression| freeDecodedExpr(allocator, expression);
    allocator.free(bodies.exprs);
    for (bodies.stmts) |statement| freeDecodedStatement(allocator, statement);
    allocator.free(bodies.stmts);
    for (bodies.pats) |pattern| freeDecodedPattern(allocator, pattern);
    allocator.free(bodies.pats);
    for (bodies.types) |ty| freeDecodedType(allocator, ty);
    allocator.free(bodies.types);
    for (bodies.bodies) |body| freeDecodedBodyKind(allocator, body);
    allocator.free(bodies.bodies);
}

fn freeDecodedFieldInitList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(exprs.FieldInit),
) void {
    for (list.items) |field| allocator.free(field.field);
    list.deinit(allocator);
}

fn freeDecodedFieldInits(allocator: std.mem.Allocator, fields: []const exprs.FieldInit) void {
    for (fields) |field| allocator.free(field.field);
    if (fields.len > 0) allocator.free(fields);
}

fn freeDecodedFieldPatList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(exprs.FieldPat),
) void {
    for (list.items) |field| allocator.free(field.field);
    list.deinit(allocator);
}

fn freeDecodedFieldPats(allocator: std.mem.Allocator, fields: []const exprs.FieldPat) void {
    for (fields) |field| allocator.free(field.field);
    if (fields.len > 0) allocator.free(fields);
}
fn freeDecodedMatchArmList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(exprs.MatchArm),
) void {
    for (list.items) |arm| allocator.free(arm.patterns);
    list.deinit(allocator);
}

fn freeDecodedParam(allocator: std.mem.Allocator, param: items.Param) void {
    allocator.free(param.name);
    freeDecodedType(allocator, param.ty);
}

fn freeDecodedParamList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(items.Param),
) void {
    for (list.items) |param| {
        allocator.free(param.name);
        freeDecodedType(allocator, param.ty);
    }
    list.deinit(allocator);
}

fn freeDecodedField(allocator: std.mem.Allocator, field: items.Field) void {
    allocator.free(field.name);
    freeDecodedType(allocator, field.ty);
    freeDecodedVisibility(allocator, field.visibility);
}
fn freeDecodedFields(allocator: std.mem.Allocator, fields: []const items.Field) void {
    for (fields) |field| freeDecodedField(allocator, field);
    if (fields.len > 0) allocator.free(fields);
}
fn freeDecodedCrateDeps(allocator: std.mem.Allocator, deps: []const graph.CrateDep) void {
    for (deps) |dependency| {
        allocator.free(dependency.extern_name);
        allocator.free(dependency.local_alias);
        freeDecodedStringList(allocator, dependency.features);
    }
    allocator.free(deps);
}

fn freeDecodedEntity(allocator: std.mem.Allocator, entity: spine.Entity) void {
    allocator.free(entity.name);
    freeDecodedVisibility(allocator, entity.visibility);
    if (entity.renamed_to) |renamed| allocator.free(renamed);
    freeDecodedAttributes(allocator, entity.attributes);
}

fn freeDecodedModule(allocator: std.mem.Allocator, module: graph.Module) void {
    allocator.free(module.name);
    if (module.source_path) |source_path| allocator.free(source_path);
    allocator.free(module.items);
    freeDecodedAttributes(allocator, module.attributes);
}

fn freeDecodedUseDecl(allocator: std.mem.Allocator, use_decl: graph.UseDecl) void {
    allocator.free(use_decl.local_name);
}

fn freeDecodedParams(allocator: std.mem.Allocator, params: []const items.Param) void {
    for (params) |param| freeDecodedParam(allocator, param);
    if (params.len > 0) allocator.free(params);
}

fn freeDecodedFieldList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(items.Field),
) void {
    for (list.items) |field| {
        allocator.free(field.name);
        freeDecodedType(allocator, field.ty);
        freeDecodedVisibility(allocator, field.visibility);
    }
    list.deinit(allocator);
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
        const path_text = try reqStr(o, "path");
        const path = try allocator.dupe(u8, path_text);
        errdefer allocator.free(path);
        return .{ .in_path = path };
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
    errdefer freeDecodedAttributeList(allocator, &list);
    for (arr.items) |av| {
        const o = try getObj(av);
        const name = try allocator.dupe(u8, try reqStr(o, "name"));
        errdefer allocator.free(name);
        const meta = try allocator.dupe(u8, try reqStr(o, "meta"));
        errdefer allocator.free(meta);
        const known = try reqBool(o, "known");
        try list.append(allocator, .{
            .name = name,
            .meta = meta,
            .known = known,
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
    const id: spine.EntityId = @intCast(try reqU32(o, "id"));
    const kind = try decodeModuleKind(try reqStr(o, "kind"));
    const name = try allocator.dupe(u8, try reqStr(o, "name"));
    errdefer allocator.free(name);
    const parent = try optU32(o, "parent");
    const source_path = if (try optStr(o, "source_path")) |source| blk: {
        const owned_source = try allocator.dupe(u8, source);
        break :blk owned_source;
    } else null;
    errdefer if (source_path) |source| allocator.free(source);
    const is_crate = try reqBool(o, "is_crate");
    const is_extern = try reqBool(o, "is_extern");
    const span = try decodeSpan(try req(o, "span"));
    const item_ids = try decodeIdSlice(allocator, try req(o, "items"));
    errdefer allocator.free(item_ids);
    const attributes = try decodeAttributes(allocator, try req(o, "attributes"));
    errdefer freeDecodedAttributes(allocator, attributes);
    return .{
        .id = id,
        .kind = kind,
        .name = name,
        .parent = parent,
        .source_path = source_path,
        .is_crate = is_crate,
        .is_extern = is_extern,
        .span = span,
        .items = item_ids,
        .attributes = attributes,
    };
}

fn decodeEntity(allocator: std.mem.Allocator, v: Json) !spine.Entity {
    const o = try getObj(v);
    const id: spine.EntityId = @intCast(try reqU32(o, "id"));
    const kind = try decodeEntityKind(try reqStr(o, "kind"));
    const name = try allocator.dupe(u8, try reqStr(o, "name"));
    errdefer allocator.free(name);
    const span = try decodeSpan(try req(o, "span"));
    const visibility = try decodeVisibility(allocator, try req(o, "visibility"));
    errdefer freeDecodedVisibility(allocator, visibility);
    const parent = try optU32(o, "parent");
    const resolved = try optU32(o, "resolved");
    const renamed_to = if (try optStr(o, "renamed_to")) |renamed| blk: {
        const owned_renamed = try allocator.dupe(u8, renamed);
        break :blk owned_renamed;
    } else null;
    errdefer if (renamed_to) |renamed| allocator.free(renamed);
    const attributes = try decodeAttributes(allocator, try req(o, "attributes"));
    errdefer freeDecodedAttributes(allocator, attributes);
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
    const id: spine.EntityId = @intCast(try reqU32(o, "id"));
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
    errdefer freeDecodedCrateDepList(allocator, &list);
    for (arr.items) |dv| {
        const d = try getObj(dv);
        const extern_name = try allocator.dupe(u8, try reqStr(d, "extern_name"));
        errdefer allocator.free(extern_name);
        const local_alias = try allocator.dupe(u8, try reqStr(d, "local_alias"));
        errdefer allocator.free(local_alias);
        const id: u32 = @intCast(try reqU32(d, "id"));
        const default_features = switch (try req(d, "default_features")) {
            .bool => |value| value,
            .null => null,
            else => return error.BadWireFormat,
        };
        const features = try decodeRequiredStringList(allocator, d, "features");
        errdefer freeDecodedStringList(allocator, features);
        try list.append(allocator, .{
            .extern_name = extern_name,
            .local_alias = local_alias,
            .id = id,
            .default_features = default_features,
            .features = features,
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
        .number_string => |s| blk: {
            const value = std.fmt.parseFloat(f64, s) catch return error.BadWireFormat;
            if (!std.math.isFinite(value)) return error.BadWireFormat;
            break :blk value;
        },
        else => error.BadWireFormat,
    };
}

fn reqOptionalId(o: ObjectMap, key: []const u8) !?exprs.NodeId {
    return switch (try req(o, key)) {
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
    errdefer freeDecodedIdList(allocator, &list);
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
    const value: i128 =
        std.fmt.parseInt(i128, try reqStr(o, "value"), 10) catch return error.BadWireFormat;
    const suffix = try reqOptStr(o, "ty_suffix");
    const text = try allocator.dupe(u8, try reqStr(o, "text"));
    errdefer allocator.free(text);
    const ty_suffix = if (suffix) |s| blk: {
        const owned_suffix = try allocator.dupe(u8, s);
        break :blk owned_suffix;
    } else null;
    errdefer if (ty_suffix) |owned_suffix| allocator.free(owned_suffix);
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
    const value: u32 = @intCast(try reqU32(o, "value"));
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

// ── v2 types ───────────────────────────────────────────────────────────────

fn decodePathSegments(allocator: std.mem.Allocator, v: Json) ![]const types.PathSegment {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(types.PathSegment) = .empty;
    errdefer {
        for (list.items) |segment| allocator.free(segment.name);
        list.deinit(allocator);
    }
    for (arr.items) |it| {
        const o = try getObj(it);
        const name = try allocator.dupe(u8, try reqStr(o, "name"));
        errdefer allocator.free(name);
        const id = try reqOptionalId(o, "id");
        try list.append(allocator, .{
            .name = name,
            .id = id,
        });
    }
    return list.toOwnedSlice(allocator);
}

fn decodePath(allocator: std.mem.Allocator, v: Json) !types.Path {
    const o = try getObj(v);
    return .{ .segments = try decodePathSegments(allocator, try req(o, "segments")) };
}

fn decodeAssociatedTypeBinding(
    allocator: std.mem.Allocator,
    v: Json,
) !types.AssociatedTypeBinding {
    const o = try getObj(v);
    const name = try allocator.dupe(u8, try reqStr(o, "name"));
    errdefer allocator.free(name);
    const ty = try decodeType(allocator, try req(o, "ty"));
    errdefer freeDecodedType(allocator, ty);
    return .{ .name = name, .ty = ty };
}

fn decodeAssociatedTypeBindings(
    allocator: std.mem.Allocator,
    v: Json,
) ![]const types.AssociatedTypeBinding {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(types.AssociatedTypeBinding) = .empty;
    errdefer freeDecodedAssociatedTypeBindingList(allocator, &list);
    for (arr.items) |item| {
        const value = try decodeAssociatedTypeBinding(allocator, item);
        list.append(allocator, value) catch |err| {
            freeDecodedAssociatedTypeBinding(allocator, value);
            return err;
        };
    }
    return list.toOwnedSlice(allocator);
}

fn decodeBound(allocator: std.mem.Allocator, v: Json) !types.Bound {
    const o = try getObj(v);
    const path = try decodePath(allocator, try req(o, "path"));
    errdefer freeDecodedPath(allocator, path);
    const args = try decodeTypeList(allocator, try req(o, "args"));
    errdefer freeDecodedTypeSlice(allocator, args);
    const associated_types = try decodeAssociatedTypeBindings(
        allocator,
        try req(o, "associated_types"),
    );
    errdefer freeDecodedAssociatedTypeBindingSlice(allocator, associated_types);
    const optional = try reqBool(o, "optional");
    return .{
        .path = path,
        .args = args,
        .associated_types = associated_types,
        .optional = optional,
    };
}

fn decodeBounds(allocator: std.mem.Allocator, v: Json) ![]const types.Bound {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(types.Bound) = .empty;
    errdefer freeDecodedBoundList(allocator, &list);
    for (arr.items) |item| {
        const value = try decodeBound(allocator, item);
        list.append(allocator, value) catch |err| {
            freeDecodedBound(allocator, value);
            return err;
        };
    }
    return list.toOwnedSlice(allocator);
}

/// A nominal type supplied by `alloc`/`core`/`std`. Its path is provenance
/// only and must not be empty: a nameless external type names nothing the
/// emitter could ever resolve, so it is rejected rather than defaulted.
fn decodeExternalNominal(allocator: std.mem.Allocator, v: Json) !types.ExternalNominal {
    const o = try getObj(v);
    const path = try decodeStringList(allocator, try req(o, "path"));
    errdefer freeDecodedStringList(allocator, path);
    if (path.len == 0) return error.BadWireFormat;
    for (path) |segment| {
        if (segment.len == 0) return error.BadWireFormat;
    }
    const args = try decodeTypeList(allocator, try req(o, "args"));
    errdefer freeDecodedTypeSlice(allocator, args);
    return .{ .path = path, .args = args };
}

/// The errors the `Type` decoder group can actually return. The decode side is
/// mutually recursive through `Bound.associated_types`, so an inferred error
/// set cannot be resolved; naming it here breaks the cycle the same way
/// `src/ir/serialize.zig` does for the same dialect. It is not `anyerror`:
/// every error below is produced by `getObj`/`req`/`reqStr`/`reqBool` or by an
/// allocation, and naming them keeps the constraint meaningful.
const TypeDecodeError = std.mem.Allocator.Error || error{ BadWireFormat, MissingField };

fn decodeTypeList(allocator: std.mem.Allocator, v: Json) TypeDecodeError![]const types.Type {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(types.Type) = .empty;
    errdefer freeDecodedTypeList(allocator, &list);
    for (arr.items) |it| {
        const ty = try decodeType(allocator, it);
        errdefer freeDecodedType(allocator, ty);
        try list.append(allocator, ty);
    }
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
    return std.meta.stringToEnum(spine.UnsupportedReason, s) orelse error.BadWireFormat;
}

fn decodeType(allocator: std.mem.Allocator, v: Json) TypeDecodeError!types.Type {
    const o = try getObj(v);
    const tag = try reqStr(o, "kind");
    const val = try req(o, "value");
    if (std.mem.eql(u8, tag, "path")) {
        const p = try getObj(val);
        const segments = try decodePathSegments(allocator, try req(p, "segments"));
        errdefer freeDecodedPathSegments(allocator, segments);
        return .{ .path = .{ .segments = segments } };
    }
    if (std.mem.eql(u8, tag, "external_nominal")) {
        return .{ .external_nominal = try decodeExternalNominal(allocator, val) };
    }
    if (std.mem.eql(u8, tag, "opaque")) {
        const p = try getObj(val);
        const bounds = try decodeBounds(allocator, try req(p, "bounds"));
        errdefer freeDecodedBoundSlice(allocator, bounds);
        const concrete: ?*const types.Type = switch (try req(p, "concrete")) {
            .null => null,
            else => blk: {
                const value = try decodeType(allocator, try req(p, "concrete"));
                errdefer freeDecodedType(allocator, value);
                const ptr = try allocator.create(types.Type);
                ptr.* = value;
                break :blk ptr;
            },
        };
        return .{ .@"opaque" = .{ .bounds = bounds, .concrete = concrete } };
    }
    if (std.mem.eql(u8, tag, "dyn_trait")) {
        const p = try getObj(val);
        return .{ .dyn_trait = try decodeBounds(allocator, try req(p, "bounds")) };
    }
    if (std.mem.eql(u8, tag, "prim")) {
        return .{ .prim = try decodePrim(try reqStrArray(val)) };
    }
    if (std.mem.eql(u8, tag, "slice")) {
        const p = try getObj(val);
        const inner = try allocator.create(types.Slice);
        errdefer allocator.destroy(inner);
        const const_ = try reqBool(p, "const_");
        const elem = try decodeType(allocator, try req(p, "elem"));
        errdefer freeDecodedType(allocator, elem);
        inner.* = .{ .const_ = const_, .elem = elem };
        return .{ .slice = inner };
    }
    if (std.mem.eql(u8, tag, "reference")) {
        const p = try getObj(val);
        const inner = try allocator.create(types.Ref);
        errdefer allocator.destroy(inner);
        const mut = try reqBool(p, "mut");
        const pointee = try decodeType(allocator, try req(p, "pointee"));
        errdefer freeDecodedType(allocator, pointee);
        inner.* = .{ .mut = mut, .pointee = pointee };
        return .{ .reference = inner };
    }
    if (std.mem.eql(u8, tag, "raw_ptr")) {
        const p = try getObj(val);
        const inner = try allocator.create(types.RawPtr);
        errdefer allocator.destroy(inner);
        const mut = try reqBool(p, "mut");
        const pointee = try decodeType(allocator, try req(p, "pointee"));
        errdefer freeDecodedType(allocator, pointee);
        inner.* = .{ .mut = mut, .pointee = pointee };
        return .{ .raw_ptr = inner };
    }
    if (std.mem.eql(u8, tag, "array")) {
        const p = try getObj(val);
        const inner = try allocator.create(types.Array);
        errdefer allocator.destroy(inner);
        const len_o = try getObj(try req(p, "len"));
        const elem = try decodeType(allocator, try req(p, "elem"));
        errdefer freeDecodedType(allocator, elem);
        const len_kind = try reqStr(len_o, "kind");
        const length: types.ArrayLen = if (std.mem.eql(u8, len_kind, "literal"))
            .{ .literal = try reqU32(len_o, "value") }
        else if (std.mem.eql(u8, len_kind, "generic"))
            .{ .generic = try reqU32(len_o, "value") }
        else
            return error.BadWireFormat;
        inner.* = .{ .elem = elem, .len = length };
        return .{ .array = inner };
    }
    if (std.mem.eql(u8, tag, "tuple")) {
        const tuple = try decodeTypeList(allocator, val);
        errdefer freeDecodedTypeSlice(allocator, tuple);
        return .{ .tuple = tuple };
    }
    if (std.mem.eql(u8, tag, "fn_ptr")) {
        const p = try getObj(val);
        const inner = try allocator.create(types.FnPtr);
        errdefer allocator.destroy(inner);
        const params = try decodeTypeList(allocator, try req(p, "params"));
        errdefer freeDecodedTypeSlice(allocator, params);
        const ret = try decodeType(allocator, try req(p, "ret"));
        errdefer freeDecodedType(allocator, ret);
        inner.* = .{ .params = params, .ret = ret };
        return .{ .fn_ptr = inner };
    }
    if (std.mem.eql(u8, tag, "generic_inst")) {
        const p = try getObj(val);
        const args_o = try getObj(try req(p, "args"));
        const decl: spine.EntityId = @intCast(try reqU32(p, "decl"));
        const params = try decodeTypeList(allocator, try req(args_o, "params"));
        errdefer freeDecodedTypeSlice(allocator, params);
        return .{ .generic_inst = .{
            .decl = decl,
            .args = .{ .params = params },
        } };
    }
    if (std.mem.eql(u8, tag, "option")) {
        const inner = try allocator.create(types.Type);
        errdefer allocator.destroy(inner);
        inner.* = try decodeType(allocator, val);
        return .{ .option = inner };
    }
    if (std.mem.eql(u8, tag, "result")) {
        const p = try getObj(val);
        const inner = try allocator.create(types.Result);
        errdefer allocator.destroy(inner);
        const ok = try decodeType(allocator, try req(p, "ok"));
        errdefer freeDecodedType(allocator, ok);
        const err = try decodeType(allocator, try req(p, "err"));
        errdefer freeDecodedType(allocator, err);
        inner.* = .{
            .ok = ok,
            .err = err,
            .is_error_unionable = try reqBool(p, "is_error_unionable"),
        };
        return .{ .result = inner };
    }
    if (std.mem.eql(u8, tag, "boxed")) {
        const inner = try allocator.create(types.Type);
        errdefer allocator.destroy(inner);
        inner.* = try decodeType(allocator, val);
        return .{ .boxed = inner };
    }
    if (std.mem.eql(u8, tag, "unsupported")) {
        const u = try getObj(val);
        const message = try allocator.dupe(u8, try reqStr(u, "message"));
        errdefer allocator.free(message);
        return .{ .unsupported = .{
            .reason = try decodeUnsupportedReason(try reqStr(u, "reason")),
            .message = message,
            .span = try decodeSpan(try req(u, "span")),
        } };
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

fn decodeClosureTrait(s: []const u8) !exprs.ClosureTrait {
    if (std.mem.eql(u8, s, "fn")) return .@"fn";
    if (std.mem.eql(u8, s, "fn_mut")) return .fn_mut;
    if (std.mem.eql(u8, s, "fn_once")) return .fn_once;
    return error.BadWireFormat;
}

fn decodeCaptureMode(s: []const u8) !exprs.CaptureMode {
    if (std.mem.eql(u8, s, "by_value")) return .by_value;
    if (std.mem.eql(u8, s, "by_ref")) return .by_ref;
    if (std.mem.eql(u8, s, "by_mut_ref")) return .by_mut_ref;
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

fn decodeCoreFunction(s: []const u8) !exprs.CoreFunction {
    return std.meta.stringToEnum(exprs.CoreFunction, s) orelse error.BadWireFormat;
}

/// The conversion syntax, written `as` rather than the tag name `as_` because
/// the trailing underscore is a Zig identifier guard this wire spelling drops.
fn decodeConversion(s: []const u8) !@FieldType(exprs.CastExpr, "kind") {
    if (std.mem.eql(u8, s, "as")) return .as_;
    if (std.mem.eql(u8, s, "primitive_from")) return .primitive_from;
    return error.BadWireFormat;
}

/// A chain's terminal operation. It is required on the wire: the default
/// `.iterator` is a deferred-fixture convenience, so a chain written without
/// it would silently read back as a bare iterator and lose its `for` verdict.
fn decodeIteratorTerminal(s: []const u8) !exprs.IteratorTerminal {
    if (std.mem.eql(u8, s, "iterator")) return .iterator;
    if (std.mem.eql(u8, s, "collect_vec")) return .collect_vec;
    if (std.mem.eql(u8, s, "sum")) return .sum;
    return error.BadWireFormat;
}

/// A stored `[e; N]` count: the number of elements the generated program
/// states, read at full `u64` width. Read before the element list so a count
/// no `u64` holds is rejected without allocating the data it would describe.
fn decodeRepeat(o: ObjectMap, key: []const u8) !?u64 {
    const v = try req(o, key);
    if (v == .null) return null;
    return try decodeU64Count(v);
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
    // The compound bitwise and shift assignments. The encoder writes every
    // `AssignOp` arm through `@tagName`, so a decoder that stopped at `rem`
    // refused the five arms a `<<=` or `&=` produces.
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
    const labelled = try reqOptStr(o, "labelled");
    const statements = try decodeIdList(allocator, try req(o, "statements"));
    errdefer allocator.free(statements);
    const tail = try reqOptionalId(o, "tail");
    const owned_labelled = if (labelled) |text| blk: {
        const owned = try allocator.dupe(u8, text);
        break :blk owned;
    } else null;
    errdefer if (owned_labelled) |text| allocator.free(text);
    return .{
        .statements = statements,
        .tail = tail,
        .labelled = owned_labelled,
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

/// A closure value: its captures, its parameter patterns, its declared return
/// type, its body block, and which of the three call traits it closes as. All
/// five travel; none is defaulted on the way in.
fn decodeClosure(allocator: std.mem.Allocator, v: Json) !exprs.ClosureExpr {
    const o = try getObj(v);
    const captures_array = switch (try req(o, "captures")) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var captures: std.ArrayListUnmanaged(exprs.Capture) = .empty;
    errdefer freeDecodedCaptureList(allocator, &captures);
    for (captures_array.items) |capture_value| {
        const capture = try getObj(capture_value);
        const name = try allocator.dupe(u8, try reqStr(capture, "name"));
        errdefer allocator.free(name);
        try captures.append(allocator, .{
            .name = name,
            .mode = try decodeCaptureMode(try reqStr(capture, "mode")),
            .ty = try reqU32(capture, "ty"),
        });
    }
    const capture_slice = try captures.toOwnedSlice(allocator);
    errdefer freeDecodedCaptures(allocator, capture_slice);
    const params = try decodeIdList(allocator, try req(o, "params"));
    errdefer if (params.len > 0) allocator.free(params);
    const return_ty = try reqOptionalId(o, "return_ty");
    const body = try decodeBlockExpr(allocator, try req(o, "body"));
    errdefer freeDecodedBlockExpr(allocator, body);
    return .{
        .captures = capture_slice,
        .params = params,
        .return_ty = return_ty,
        .body = body,
        .trait = try decodeClosureTrait(try reqStr(o, "trait")),
    };
}

fn decodeIteratorAdapter(allocator: std.mem.Allocator, v: Json) !exprs.IteratorAdapter {
    const o = try getObj(v);
    const tag = try reqStr(o, "kind");
    if (std.mem.eql(u8, tag, "map")) {
        return .{ .map = .{ .closure = try decodeClosure(allocator, try req(o, "closure")) } };
    }
    if (std.mem.eql(u8, tag, "filter")) {
        return .{ .filter = .{ .closure = try decodeClosure(allocator, try req(o, "closure")) } };
    }
    if (std.mem.eql(u8, tag, "flat_map")) {
        return .{ .flat_map = try decodeClosure(allocator, try req(o, "closure")) };
    }
    if (std.mem.eql(u8, tag, "enumerate")) return .{ .enumerate = {} };
    if (std.mem.eql(u8, tag, "zip")) return .{ .zip = .{ .other = try reqU32(o, "other") } };
    if (std.mem.eql(u8, tag, "range_rev")) return .{ .range_rev = {} };
    if (std.mem.eql(u8, tag, "other")) {
        const reason = try allocator.dupe(u8, try reqStr(o, "reason"));
        errdefer allocator.free(reason);
        return .{ .other = .{
            .reason = reason,
            .suggested_version = try decodeUnsupportedVersion(try reqStr(o, "suggested_version")),
        } };
    }
    return error.BadWireFormat;
}

fn decodeIteratorChain(allocator: std.mem.Allocator, v: Json) !exprs.IteratorChainExpr {
    const o = try getObj(v);
    const adapters_array = switch (try req(o, "adapters")) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var adapters: std.ArrayListUnmanaged(exprs.IteratorAdapter) = .empty;
    errdefer {
        for (adapters.items) |adapter| freeDecodedIteratorAdapter(allocator, adapter);
        adapters.deinit(allocator);
    }
    for (adapters_array.items) |adapter_value| {
        const adapter = try decodeIteratorAdapter(allocator, adapter_value);
        adapters.append(allocator, adapter) catch |err| {
            freeDecodedIteratorAdapter(allocator, adapter);
            return err;
        };
    }
    const adapter_slice = try adapters.toOwnedSlice(allocator);
    errdefer {
        for (adapter_slice) |adapter| freeDecodedIteratorAdapter(allocator, adapter);
        if (adapter_slice.len > 0) allocator.free(adapter_slice);
    }
    return .{
        .source = try reqU32(o, "source"),
        .adapters = adapter_slice,
        .terminal = try decodeIteratorTerminal(try reqStr(o, "terminal")),
    };
}

fn decodeIterKind(allocator: std.mem.Allocator, v: Json) !exprs.IterKind {
    const o = try getObj(v);
    const tag = try reqStr(o, "kind");
    if (std.mem.eql(u8, tag, "range")) return .{ .range = {} };
    if (std.mem.eql(u8, tag, "slice")) return .{ .slice = {} };
    if (std.mem.eql(u8, tag, "enumerate")) return .{ .enumerate = {} };
    if (std.mem.eql(u8, tag, "multi")) return .{ .multi = try decodeIdList(allocator, try req(o, "value")) };
    if (std.mem.eql(u8, tag, "adapter")) {
        return .{ .adapter = try decodeIteratorChain(allocator, try req(o, "value")) };
    }
    return error.BadWireFormat;
}

fn decodeExprKind(allocator: std.mem.Allocator, tag: []const u8, val: Json) !exprs.ExprKind {
    if (std.mem.eql(u8, tag, "literal")) return .{ .literal = try decodeLiteral(allocator, val) };
    if (std.mem.eql(u8, tag, "vec_lit")) {
        const p = try getObj(val);
        const repeat = try decodeVecRepeatCount(p, "repeat");
        return .{ .vec_lit = .{
            .elements = try decodeIdList(allocator, try req(p, "elements")),
            .repeat = repeat,
        } };
    }
    if (std.mem.eql(u8, tag, "array")) {
        const p = try getObj(val);
        // The count is read before the element list, so a count no `u64`
        // holds is rejected before the elements it would have sized.
        const repeat = try decodeRepeat(p, "repeat");
        return .{ .array = .{
            .elements = try decodeIdList(allocator, try req(p, "elements")),
            .repeat = repeat,
        } };
    }
    if (std.mem.eql(u8, tag, "range")) {
        const p = try getObj(val);
        return .{ .range = .{
            .start = try reqU32(p, "start"),
            .end = try reqOptionalId(p, "end"),
            .inclusive = try reqBool(p, "inclusive"),
        } };
    }
    if (std.mem.eql(u8, tag, "panic_")) {
        const p = try getObj(val);
        const message = try allocator.dupe(u8, try reqStr(p, "message"));
        errdefer allocator.free(message);
        return .{ .panic_ = .{ .message = message } };
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
        const cond = try reqU32(q, "cond");
        const then_ = try decodeBlockExpr(allocator, try req(q, "then"));
        errdefer freeDecodedBlockExpr(allocator, then_);
        const else_branch = try decodeElseBranch(allocator, try req(q, "else"));
        errdefer freeDecodedElseBranch(allocator, else_branch);
        return .{ .if_else = .{
            .cond = cond,
            .then_ = then_,
            .@"else" = else_branch,
        } };
    }
    if (std.mem.eql(u8, tag, "if_let")) {
        const q = try getObj(val);
        const pattern = try reqU32(q, "pattern");
        const scrutinee = try reqU32(q, "scrutinee");
        const then_ = try decodeBlockExpr(allocator, try req(q, "then"));
        errdefer freeDecodedBlockExpr(allocator, then_);
        const else_branch = try decodeElseBranch(allocator, try req(q, "else"));
        errdefer freeDecodedElseBranch(allocator, else_branch);
        return .{ .if_let = .{
            .pattern = pattern,
            .scrutinee = scrutinee,
            .then_ = then_,
            .@"else" = else_branch,
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
            const patterns = try decodeIdList(allocator, try req(ao, "patterns"));
            errdefer allocator.free(patterns);
            const guard = try reqOptionalId(ao, "guard");
            const body = try reqU32(ao, "body");
            try arms.append(allocator, .{
                .patterns = patterns,
                .guard = guard,
                .body = body,
            });
        }
        const scrutinee = try reqU32(q, "scrutinee");
        const arm_slice = try arms.toOwnedSlice(allocator);
        errdefer {
            for (arm_slice) |arm| allocator.free(arm.patterns);
            allocator.free(arm_slice);
        }
        const option_scrutinee = try reqBool(q, "option_scrutinee");
        return .{ .match = .{
            .scrutinee = scrutinee,
            .arms = arm_slice,
            .option_scrutinee = option_scrutinee,
        } };
    }
    if (std.mem.eql(u8, tag, "loop_")) {
        const q = try getObj(val);
        return .{ .loop_ = .{ .body = try decodeBlockExpr(allocator, try req(q, "body")) } };
    }
    if (std.mem.eql(u8, tag, "while_")) {
        const q = try getObj(val);
        const cond = try reqU32(q, "cond");
        const body = try decodeBlockExpr(allocator, try req(q, "body"));
        errdefer freeDecodedBlockExpr(allocator, body);
        const capture = try reqOptionalId(q, "capture");
        return .{ .while_ = .{
            .cond = cond,
            .body = body,
            .capture = capture,
        } };
    }
    if (std.mem.eql(u8, tag, "for_")) {
        const q = try getObj(val);
        const pattern = try reqU32(q, "pattern");
        const iterable = try reqU32(q, "iterable");
        const body = try decodeBlockExpr(allocator, try req(q, "body"));
        errdefer freeDecodedBlockExpr(allocator, body);
        const iter_kind = try decodeIterKind(allocator, try req(q, "iter_kind"));
        errdefer freeDecodedIterKind(allocator, iter_kind);
        return .{ .for_ = .{
            .pattern = pattern,
            .iterable = iterable,
            .body = body,
            .iter_kind = iter_kind,
        } };
    }
    if (std.mem.eql(u8, tag, "break_")) {
        const q = try getObj(val);
        const label = try reqOptStr(q, "label");
        const owned_label = if (label) |text| blk: {
            const owned = try allocator.dupe(u8, text);
            break :blk owned;
        } else null;
        errdefer if (owned_label) |text| allocator.free(text);
        const value = try reqOptionalId(q, "value");
        return .{ .break_ = .{
            .label = owned_label,
            .value = value,
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
    if (std.mem.eql(u8, tag, "core_call")) {
        const q = try getObj(val);
        const generic_args = try decodeTypeList(allocator, try req(q, "generic_args"));
        errdefer freeDecodedTypeSlice(allocator, generic_args);
        const args = try decodeIdList(allocator, try req(q, "args"));
        errdefer allocator.free(args);
        return .{ .core_call = .{
            .function = try decodeCoreFunction(try reqStr(q, "function")),
            .generic_args = generic_args,
            .args = args,
        } };
    }
    if (std.mem.eql(u8, tag, "core_function")) {
        const q = try getObj(val);
        const generic_args = try decodeTypeList(allocator, try req(q, "generic_args"));
        errdefer freeDecodedTypeSlice(allocator, generic_args);
        return .{ .core_function = .{
            .function = try decodeCoreFunction(try reqStr(q, "function")),
            .generic_args = generic_args,
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
        errdefer freeDecodedFieldInitList(allocator, &fields);
        for (fields_arr.items) |fv| {
            const fo = try getObj(fv);
            const field = try allocator.dupe(u8, try reqStr(fo, "field"));
            errdefer allocator.free(field);
            const value = try reqU32(fo, "value");
            const shorthand = try reqBool(fo, "shorthand");
            try fields.append(allocator, .{
                .field = field,
                .value = value,
                .shorthand = shorthand,
            });
        }
        const def: spine.EntityId = @intCast(try reqU32(q, "def"));
        const field_slice = try fields.toOwnedSlice(allocator);
        errdefer freeDecodedFieldInits(allocator, field_slice);
        const base = try reqOptionalId(q, "base");
        return .{ .struct_lit = .{
            .def = def,
            .fields = field_slice,
            .base = base,
        } };
    }
    if (std.mem.eql(u8, tag, "enum_variant")) {
        const q = try getObj(val);
        const named_arr = switch (try req(q, "named_fields")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var named: std.ArrayListUnmanaged(exprs.FieldInit) = .empty;
        errdefer freeDecodedFieldInitList(allocator, &named);
        for (named_arr.items) |fv| {
            const fo = try getObj(fv);
            const field = try allocator.dupe(u8, try reqStr(fo, "field"));
            errdefer allocator.free(field);
            const value = try reqU32(fo, "value");
            const shorthand = try reqBool(fo, "shorthand");
            try named.append(allocator, .{
                .field = field,
                .value = value,
                .shorthand = shorthand,
            });
        }
        const def: spine.EntityId = @intCast(try reqU32(q, "def"));
        const variant = try allocator.dupe(u8, try reqStr(q, "variant"));
        errdefer allocator.free(variant);
        const tuple_fields = try decodeIdList(allocator, try req(q, "tuple_fields"));
        errdefer allocator.free(tuple_fields);
        const named_fields = try named.toOwnedSlice(allocator);
        errdefer freeDecodedFieldInits(allocator, named_fields);
        return .{ .enum_variant = .{
            .def = def,
            .variant = variant,
            .tuple_fields = tuple_fields,
            .named_fields = named_fields,
        } };
    }
    if (std.mem.eql(u8, tag, "external_variant")) {
        const q = try getObj(val);
        const owner = try decodeExternalNominal(allocator, try req(q, "owner"));
        errdefer freeDecodedExternalNominal(allocator, owner);
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
            const field = try allocator.dupe(u8, try reqStr(fo, "field"));
            errdefer allocator.free(field);
            const value = try reqU32(fo, "value");
            const shorthand = try reqBool(fo, "shorthand");
            try named.append(allocator, .{
                .field = field,
                .value = value,
                .shorthand = shorthand,
            });
        }
        const named_fields = try named.toOwnedSlice(allocator);
        errdefer freeDecodedFieldInits(allocator, named_fields);
        return .{ .external_variant = .{
            .owner = owner,
            .variant = variant,
            .tuple_fields = tuple_fields,
            .named_fields = named_fields,
        } };
    }
    if (std.mem.eql(u8, tag, "format_write")) {
        const q = try getObj(val);
        const template = try allocator.dupe(u8, try reqStr(q, "template"));
        errdefer allocator.free(template);
        const args = try decodeIdList(allocator, try req(q, "args"));
        errdefer allocator.free(args);
        return .{ .format_write = .{
            .writer = try reqU32(q, "writer"),
            .template = template,
            .args = args,
        } };
    }
    if (std.mem.eql(u8, tag, "field")) {
        const q = try getObj(val);
        const base = try reqU32(q, "base");
        const field = try allocator.dupe(u8, try reqStr(q, "field"));
        errdefer allocator.free(field);
        const resolved: spine.EntityId = @intCast(try reqU32(q, "resolved"));
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
        const operand = try reqU32(q, "operand");
        const source_type = try decodeType(allocator, try req(q, "source_type"));
        errdefer freeDecodedType(allocator, source_type);
        return .{ .cast = .{
            .kind = kind,
            .operand = operand,
            .source_type = source_type,
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
    if (std.mem.eql(u8, tag, "closure")) {
        return .{ .closure = try decodeClosure(allocator, val) };
    }
    if (std.mem.eql(u8, tag, "iterator_chain")) {
        return .{ .iterator_chain = try decodeIteratorChain(allocator, val) };
    }
    if (std.mem.eql(u8, tag, "unsupported")) {
        const q = try getObj(val);
        const reason = try allocator.dupe(u8, try reqStr(q, "reason"));
        errdefer allocator.free(reason);
        return .{ .unsupported = .{
            .reason = reason,
            .suggested_version = try decodeUnsupportedVersion(try reqStr(q, "suggested_version")),
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

// ── v2 patterns ────────────────────────────────────────────────────────────

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
    if (std.mem.eql(u8, tag, "literal")) {
        return .{ .literal = try decodeLiteral(allocator, val) };
    }
    if (std.mem.eql(u8, tag, "path")) {
        const p = try getObj(val);
        const def: spine.EntityId = @intCast(try reqU32(p, "def"));
        const variant = if (try reqOptStr(p, "variant")) |text| blk: {
            const owned = try allocator.dupe(u8, text);
            break :blk owned;
        } else null;
        errdefer if (variant) |text| allocator.free(text);
        return .{ .path = .{
            .def = def,
            .variant = variant,
        } };
    }
    if (std.mem.eql(u8, tag, "external_variant")) {
        const p = try getObj(val);
        const owner = try decodeExternalNominal(allocator, try req(p, "owner"));
        errdefer freeDecodedExternalNominal(allocator, owner);
        const variant = try allocator.dupe(u8, try reqStr(p, "variant"));
        errdefer allocator.free(variant);
        const fields_arr = switch (try req(p, "fields")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var fields: std.ArrayListUnmanaged(exprs.FieldPat) = .empty;
        errdefer freeDecodedFieldPatList(allocator, &fields);
        for (fields_arr.items) |fv| {
            const fo = try getObj(fv);
            const field = try allocator.dupe(u8, try reqStr(fo, "field"));
            errdefer allocator.free(field);
            const pat = try reqOptionalId(fo, "pat");
            const shorthand = try reqBool(fo, "shorthand");
            try fields.append(allocator, .{
                .field = field,
                .pat = pat,
                .shorthand = shorthand,
            });
        }
        const field_slice = try fields.toOwnedSlice(allocator);
        errdefer freeDecodedFieldPats(allocator, field_slice);
        const rest = try reqBool(p, "rest");
        return .{ .external_variant = .{
            .owner = owner,
            .variant = variant,
            .fields = field_slice,
            .rest = rest,
        } };
    }
    if (std.mem.eql(u8, tag, "tuple")) {
        const t = try getObj(val);
        const elements = try decodeIdList(allocator, try req(t, "elements"));
        errdefer allocator.free(elements);
        const rest = try reqBool(t, "rest");
        return .{ .tuple = .{
            .elements = elements,
            .rest = rest,
        } };
    }
    if (std.mem.eql(u8, tag, "slice")) {
        const t = try getObj(val);
        const elements = try decodeIdList(allocator, try req(t, "elements"));
        errdefer allocator.free(elements);
        const rest = try reqOptionalId(t, "rest");
        return .{ .slice = .{
            .elements = elements,
            .rest = rest,
        } };
    }
    if (std.mem.eql(u8, tag, "struct_pat")) {
        const t = try getObj(val);
        const fields_arr = switch (try req(t, "fields")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var fields: std.ArrayListUnmanaged(exprs.FieldPat) = .empty;
        errdefer freeDecodedFieldPatList(allocator, &fields);
        for (fields_arr.items) |fv| {
            const fo = try getObj(fv);
            const field = try allocator.dupe(u8, try reqStr(fo, "field"));
            errdefer allocator.free(field);
            const pat = try reqOptionalId(fo, "pat");
            const shorthand = try reqBool(fo, "shorthand");
            try fields.append(allocator, .{
                .field = field,
                .pat = pat,
                .shorthand = shorthand,
            });
        }
        const def: spine.EntityId = @intCast(try reqU32(t, "def"));
        const field_slice = try fields.toOwnedSlice(allocator);
        errdefer {
            for (field_slice) |field| allocator.free(field.field);
            allocator.free(field_slice);
        }
        const rest = try reqBool(t, "rest");
        return .{ .struct_pat = .{
            .def = def,
            .fields = field_slice,
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
    const name = try allocator.dupe(u8, try reqStr(o, "name"));
    errdefer allocator.free(name);
    const ty = try decodeType(allocator, try req(o, "ty"));
    errdefer freeDecodedType(allocator, ty);
    const span = try decodeSpan(try req(o, "span"));
    return .{
        .name = name,
        .ty = ty,
        .span = span,
    };
}
fn decodeField(allocator: std.mem.Allocator, v: Json) !items.Field {
    const o = try getObj(v);
    const name = try allocator.dupe(u8, try reqStr(o, "name"));
    errdefer allocator.free(name);
    const ty = try decodeType(allocator, try req(o, "ty"));
    errdefer freeDecodedType(allocator, ty);
    const vis = try decodeVisibility(
        allocator,
        o.get("vis") orelse o.get("visibility") orelse return error.MissingField,
    );
    errdefer freeDecodedVisibility(allocator, vis);
    return .{
        .name = name,
        .ty = ty,
        .visibility = vis,
        .span = try decodeSpan(try req(o, "span")),
    };
}

fn decodeParams(allocator: std.mem.Allocator, v: Json) ![]const items.Param {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(items.Param) = .empty;
    errdefer freeDecodedParamList(allocator, &list);
    for (arr.items) |item| try list.append(allocator, try decodeParam(allocator, item));
    return list.toOwnedSlice(allocator);
}

fn decodeFields(allocator: std.mem.Allocator, v: Json) ![]const items.Field {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(items.Field) = .empty;
    errdefer freeDecodedFieldList(allocator, &list);
    for (arr.items) |item| {
        const field = try decodeField(allocator, item);
        errdefer freeDecodedField(allocator, field);
        try list.append(allocator, field);
    }
    return list.toOwnedSlice(allocator);
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

fn decodeVariants(allocator: std.mem.Allocator, v: Json) ![]const items.Variant {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(items.Variant) = .empty;
    errdefer list.deinit(allocator);
    for (arr.items) |item| try list.append(allocator, try decodeVariant(allocator, item));
    return list.toOwnedSlice(allocator);
}

fn decodeEnumKind(value: []const u8) !items.EnumKind {
    return std.meta.stringToEnum(items.EnumKind, value) orelse error.BadWireFormat;
}

fn decodeIntRepr(value: []const u8) !items.IntRepr {
    return std.meta.stringToEnum(items.IntRepr, value) orelse error.BadWireFormat;
}

fn decodeOptionalReceiver(o: ObjectMap, key: []const u8) !?items.Receiver {
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
    errdefer freeDecodedType(allocator, ret);
    const generic_params = try decodeRequiredStringList(allocator, o, "generic_params");
    errdefer freeDecodedStringList(allocator, generic_params);
    const receiver = try decodeOptionalReceiver(o, "receiver");
    const is_allocating = try reqBool(o, "is_allocating");
    return .{
        .name = name,
        .visibility = visibility,
        .params = params,
        .ret = ret,
        .generic_params = generic_params,
        .body = try reqU32(o, "body"),
        .receiver = receiver,
        .is_allocating = is_allocating,
    };
}
fn decodeStructMethods(allocator: std.mem.Allocator, v: Json) ![]const StructMethod {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var list: std.ArrayListUnmanaged(StructMethod) = .empty;
    errdefer list.deinit(allocator);
    for (arr.items) |item| try list.append(allocator, try decodeStructMethod(allocator, item));
    return list.toOwnedSlice(allocator);
}

fn decodeTraitMethod(allocator: std.mem.Allocator, v: Json) !TraitMethodSig {
    const o = try getObj(v);
    const name = try allocator.dupe(u8, try reqStr(o, "name"));
    errdefer allocator.free(name);
    const params = try decodeParams(allocator, try req(o, "params"));
    errdefer freeDecodedParams(allocator, params);
    const ret = try decodeType(allocator, try req(o, "ret"));
    errdefer freeDecodedType(allocator, ret);
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
    for (arr.items) |item| try list.append(allocator, try decodeTraitMethod(allocator, item));
    return list.toOwnedSlice(allocator);
}

fn decodeBodyKind(allocator: std.mem.Allocator, v: Json) !BodyKind {
    const o = try getObj(v);
    const kind_str = try reqStr(o, "kind");
    if (std.mem.eql(u8, kind_str, "none")) return .none;
    if (std.mem.eql(u8, kind_str, "const_")) {
        const co = try getObj(try req(o, "value"));
        const ty = try decodeType(allocator, try req(co, "ty"));
        errdefer freeDecodedType(allocator, ty);
        const init = try reqU32(co, "init");
        return .{ .const_ = .{
            .ty = ty,
            .init = init,
        } };
    }
    if (std.mem.eql(u8, kind_str, "fn_")) {
        const fo = try getObj(try req(o, "value"));
        const params = try decodeParams(allocator, try req(fo, "params"));
        errdefer freeDecodedParams(allocator, params);
        const ret = try decodeType(allocator, try req(fo, "ret"));
        errdefer freeDecodedType(allocator, ret);
        const generic_params = try decodeRequiredStringList(allocator, fo, "generic_params");
        errdefer freeDecodedStringList(allocator, generic_params);
        const body = try reqU32(fo, "body");
        const is_allocating = try reqBool(fo, "is_allocating");
        return .{ .fn_ = .{
            .params = params,
            .ret = ret,
            .generic_params = generic_params,
            .body = body,
            .is_allocating = is_allocating,
        } };
    }
    if (std.mem.eql(u8, kind_str, "struct_")) {
        const so = try getObj(try req(o, "value"));
        const layout_name = try reqStr(so, "layout");
        const layout: items.StructKind = if (std.mem.eql(u8, layout_name, "named"))
            .named
        else if (std.mem.eql(u8, layout_name, "tuple"))
            .tuple
        else if (std.mem.eql(u8, layout_name, "unit"))
            .unit
        else
            return error.BadWireFormat;
        const generic_params = try decodeRequiredStringList(allocator, so, "generic_params");
        errdefer freeDecodedStringList(allocator, generic_params);
        const trait_bounds = try decodeRequiredStringList(allocator, so, "trait_bounds");
        errdefer freeDecodedStringList(allocator, trait_bounds);
        const fields = try decodeFields(allocator, try req(so, "fields"));
        errdefer freeDecodedFields(allocator, fields);
        const methods = try decodeStructMethods(allocator, try req(so, "methods"));
        errdefer freeDecodedStructMethods(allocator, methods);
        const has_dynamic_resources = try reqBool(so, "has_dynamic_resources");
        return .{ .struct_ = .{
            .generic_params = generic_params,
            .trait_bounds = trait_bounds,
            .layout = layout,
            .fields = fields,
            .methods = methods,
            .has_dynamic_resources = has_dynamic_resources,
        } };
    }
    if (std.mem.eql(u8, kind_str, "enum_")) {
        const eo = try getObj(try req(o, "value"));
        const enum_kind = try decodeEnumKind(try reqStr(eo, "kind"));
        const variants = try decodeVariants(allocator, try req(eo, "variants"));
        errdefer freeDecodedVariants(allocator, variants);
        const repr_value = try req(eo, "repr_int");
        const repr_int = switch (repr_value) {
            .string => |name| try decodeIntRepr(name),
            .null => null,
            else => return error.BadWireFormat,
        };
        const non_exhaustive = try reqBool(eo, "non_exhaustive");
        return .{ .enum_ = .{
            .kind = enum_kind,
            .variants = variants,
            .repr_int = repr_int,
            .non_exhaustive = non_exhaustive,
        } };
    }
    if (std.mem.eql(u8, kind_str, "trait_")) {
        const to = try getObj(try req(o, "value"));
        const name = try allocator.dupe(u8, try reqStr(to, "name"));
        errdefer allocator.free(name);
        const supertraits = try decodeStringList(allocator, try req(to, "supertraits"));
        errdefer freeDecodedStringList(allocator, supertraits);
        const methods = try decodeTraitMethods(allocator, try req(to, "methods"));
        errdefer freeDecodedTraitMethods(allocator, methods);
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

fn decodeBodies(allocator: std.mem.Allocator, v: Json) !Bodies {
    const o = try getObj(v);

    const exprs_arr = switch (try req(o, "exprs")) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;
    errdefer freeDecodedExprList(allocator, &exprs_list);
    for (exprs_arr.items) |ev| {
        const expression = try decodeExpr(allocator, ev);
        errdefer freeDecodedExpr(allocator, expression);
        try exprs_list.append(allocator, expression);
    }

    const stmts_arr = switch (try req(o, "stmts")) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var stmts_list: std.ArrayListUnmanaged(exprs.Statement) = .empty;
    errdefer freeDecodedStatementList(allocator, &stmts_list);
    for (stmts_arr.items) |sv| {
        const statement = try decodeStatement(allocator, sv);
        errdefer freeDecodedStatement(allocator, statement);
        try stmts_list.append(allocator, statement);
    }

    const pats_arr = switch (try req(o, "pats")) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var pats_list: std.ArrayListUnmanaged(exprs.Pattern) = .empty;
    errdefer freeDecodedPatternList(allocator, &pats_list);
    for (pats_arr.items) |pv| {
        const pattern = try decodePattern(allocator, pv);
        errdefer freeDecodedPattern(allocator, pattern);
        try pats_list.append(allocator, pattern);
    }

    const types_arr = switch (try req(o, "types")) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    errdefer freeDecodedTypeList(allocator, &types_list);
    for (types_arr.items) |tv| {
        const ty = try decodeType(allocator, tv);
        errdefer freeDecodedType(allocator, ty);
        try types_list.append(allocator, ty);
    }

    const bodies_arr = switch (try req(o, "bodies")) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var bodies_list: std.ArrayListUnmanaged(BodyKind) = .empty;
    errdefer freeDecodedBodyList(allocator, &bodies_list);
    for (bodies_arr.items) |bv| {
        const body = try decodeBodyKind(allocator, bv);
        errdefer freeDecodedBodyKind(allocator, body);
        try bodies_list.append(allocator, body);
    }

    const exprs_slice = try exprs_list.toOwnedSlice(allocator);
    errdefer {
        for (exprs_slice) |expression| freeDecodedExpr(allocator, expression);
        allocator.free(exprs_slice);
    }
    const stmts_slice = try stmts_list.toOwnedSlice(allocator);
    errdefer {
        for (stmts_slice) |statement| freeDecodedStatement(allocator, statement);
        allocator.free(stmts_slice);
    }
    const pats_slice = try pats_list.toOwnedSlice(allocator);
    errdefer {
        for (pats_slice) |pattern| freeDecodedPattern(allocator, pattern);
        allocator.free(pats_slice);
    }
    const types_slice = try types_list.toOwnedSlice(allocator);
    errdefer {
        for (types_slice) |ty| freeDecodedType(allocator, ty);
        allocator.free(types_slice);
    }
    const bodies_slice = try bodies_list.toOwnedSlice(allocator);
    errdefer {
        for (bodies_slice) |body| freeDecodedBodyKind(allocator, body);
        allocator.free(bodies_slice);
    }
    return .{
        .exprs = exprs_slice,
        .stmts = stmts_slice,
        .pats = pats_slice,
        .types = types_slice,
        .bodies = bodies_slice,
    };
}

/// Empty Bodies (no tables; used when a v3 document has no `bodies` field or
/// when the source was a graph-only v1 document).
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
        errdefer allocator.free(name);
        const edition: u16 = @intCast(try reqU32(c, "edition"));
        const kind = try decodeCrateKind(try reqStr(c, "kind"));
        const root: spine.EntityId = @intCast(try reqU32(c, "root"));
        const is_translated = try reqBool(c, "is_translated");
        const deps = try decodeDeps(allocator, try req(c, "deps"));
        errdefer freeDecodedCrateDeps(allocator, deps);

        // Entities populate the shared symbol table first (dense ids 0..N).
        const entities_arr = switch (try req(c, "entities")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        for (entities_arr.items) |ev| {
            const entity = try decodeEntity(allocator, ev);
            errdefer freeDecodedEntity(allocator, entity);
            _ = try g.symbol_table.add(entity);
        }
        // Modules mirror the symbol table (dense id == index).
        const modules_arr = switch (try req(c, "modules")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        for (modules_arr.items) |mv| {
            const module = try decodeModule(allocator, mv);
            errdefer freeDecodedModule(allocator, module);
            _ = try g.addModule(module);
        }
        const uses_arr = switch (try req(c, "uses")) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        for (uses_arr.items) |uv| {
            const use_decl = try decodeUseDecl(allocator, uv);
            errdefer freeDecodedUseDecl(allocator, use_decl);
            try g.addUse(use_decl);
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

/// Lossless decode of the graph wire format into an owned CrateGraph.
/// Graph data accepts v1 through v3; body data is ignored — use `parseFull`
/// to recover it.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !graph.CrateGraph {
    var parsed = std.json.parseFromSlice(Json, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();
    const root_map = getObj(parsed.value) catch return error.BadWireFormat;
    const ver: u32 = @intCast(try reqU32(root_map, "format_version"));
    if (ver < 1 or ver > wire_format_version) return error.InvalidFormatVersion;
    return decodeGraph(allocator, root_map);
}

/// Lossless decode into the full model (graph + bodies). Translation wire
/// requires v3 because v1/v2 have no complete body/dependency contract.
pub fn parseFull(allocator: std.mem.Allocator, bytes: []const u8) !FullModel {
    var parsed = std.json.parseFromSlice(Json, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();
    const root_map = getObj(parsed.value) catch return error.BadWireFormat;
    const ver: u32 = @intCast(try reqU32(root_map, "format_version"));
    if (ver != wire_format_version) return error.InvalidFormatVersion;

    var g = try decodeGraph(allocator, root_map);
    errdefer g.deinit();
    const bodies = try decodeBodies(allocator, try req(root_map, "bodies"));
    return .{ .graph = g, .bodies = bodies };
}

// ---------------------------------------------------------------------------
// Encode helpers (build a Json value tree owned by `allocator`)
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
        // Only the encoder puts a `number_string` in a tree `freeValue` walks:
        // a wide count is printed into one. A token parsed out of JSON lives
        // in the parser's own arena and never reaches here.
        .number_string => |digits| allocator.free(digits),
        else => {},
    }
}

fn mkInt(x: anytype) Json {
    return .{ .integer = @intCast(x) };
}

/// Write a full-width `u64` count as an unquoted decimal number, never through
/// `f64` and never through an `i64` that cannot hold it. `std.json` writes a
/// `number_string` verbatim, so the wire form stays the same JSON number. The
/// digits are owned by `allocator`, which `encodeRoot` backs with the per-call
/// arena: they are copied into the wire bytes before that arena is released.
fn mkCount(allocator: std.mem.Allocator, n: u64) !Json {
    if (std.math.cast(i64, n)) |i| return .{ .integer = i };
    return .{ .number_string = try std.fmt.allocPrint(allocator, "{d}", .{n}) };
}

/// Write a `vec![e; N]` count. Null and a literal number are written exactly
/// as a stored count has always been written, so an expression-free literal
/// round-trips to the bytes an older producer emitted; only an expression
/// count grows the object form.
///
/// The object carries exactly `tag` and `value`, spelled the way the canonical
/// semantic-IR wire spells them, so this reader and that writer describe one
/// count rather than two dialects of it.
fn encodeVecRepeatCount(
    allocator: std.mem.Allocator,
    repeat: ?exprs.VecRepeatCount,
) !Json {
    const count = repeat orelse return .{ .null = {} };
    switch (count) {
        .literal => |n| return try mkCount(allocator, n),
        .expression => |expression| {
            var count_object = ObjectMap.empty;
            try count_object.put(allocator, "tag", .{ .string = "expression" });
            try count_object.put(allocator, "value", mkInt(expression));
            return .{ .object = count_object };
        },
    }
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
    try o.put(allocator, "default_features", if (d.default_features) |value|
        .{ .bool = value }
    else
        .{ .null = {} });
    try o.put(allocator, "features", try encodeStringList(allocator, d.features));
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

    const source_uses = g.uses.items;
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

// ── v2 bodies: encode helpers (in-memory model → wire JSON) ────────────────

fn encodeIdList(allocator: std.mem.Allocator, ids: []const exprs.NodeId) !Json {
    var arr = Array.init(allocator);
    for (ids) |id| try arr.append(mkInt(id));
    return .{ .array = arr };
}

fn encodeTypeList(allocator: std.mem.Allocator, tys: []const types.Type) std.mem.Allocator.Error!Json {
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

fn encodeByteArrayLit(allocator: std.mem.Allocator, lit: exprs.ByteArrayLit) !Json {
    var o = ObjectMap.empty;
    var arr = Array.init(allocator);
    for (lit.items) |byte| {
        try arr.append(mkInt(byte));
    }
    try o.put(allocator, "items", .{ .array = arr });
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

fn encodePath(allocator: std.mem.Allocator, path: types.Path) !Json {
    var o = ObjectMap.empty;
    var segments = Array.init(allocator);
    for (path.segments) |segment| {
        var so = ObjectMap.empty;
        try so.put(allocator, "name", .{ .string = segment.name });
        try so.put(
            allocator,
            "id",
            if (segment.id) |id| mkInt(id) else .{ .null = {} },
        );
        try segments.append(.{ .object = so });
    }
    try o.put(allocator, "segments", .{ .array = segments });
    return .{ .object = o };
}

fn encodeAssociatedTypeBinding(
    allocator: std.mem.Allocator,
    binding: types.AssociatedTypeBinding,
) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = binding.name });
    try o.put(allocator, "ty", try encodeType(allocator, binding.ty));
    return .{ .object = o };
}

fn encodeAssociatedTypeBindings(
    allocator: std.mem.Allocator,
    bindings: []const types.AssociatedTypeBinding,
) !Json {
    var arr = Array.init(allocator);
    for (bindings) |binding| {
        try arr.append(try encodeAssociatedTypeBinding(allocator, binding));
    }
    return .{ .array = arr };
}

fn encodeBound(allocator: std.mem.Allocator, bound: types.Bound) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "path", try encodePath(allocator, bound.path));
    try o.put(allocator, "args", try encodeTypeList(allocator, bound.args));
    try o.put(
        allocator,
        "associated_types",
        try encodeAssociatedTypeBindings(allocator, bound.associated_types),
    );
    try o.put(allocator, "optional", .{ .bool = bound.optional });
    return .{ .object = o };
}

fn encodeBounds(allocator: std.mem.Allocator, bounds: []const types.Bound) !Json {
    var arr = Array.init(allocator);
    for (bounds) |bound| try arr.append(try encodeBound(allocator, bound));
    return .{ .array = arr };
}

fn encodeExternalNominal(
    allocator: std.mem.Allocator,
    external: types.ExternalNominal,
) !Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "path", try encodeStringList(allocator, external.path));
    try o.put(allocator, "args", try encodeTypeList(allocator, external.args));
    return .{ .object = o };
}

fn encodeType(allocator: std.mem.Allocator, ty: types.Type) std.mem.Allocator.Error!Json {
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
        .external_nominal => |e| {
            try o.put(allocator, "kind", .{ .string = "external_nominal" });
            try o.put(allocator, "value", try encodeExternalNominal(allocator, e));
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
        .@"opaque" => |o_ty| {
            try o.put(allocator, "kind", .{ .string = "opaque" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "bounds", try encodeBounds(allocator, o_ty.bounds));
            try vo.put(
                allocator,
                "concrete",
                if (o_ty.concrete) |concrete|
                    try encodeType(allocator, concrete.*)
                else
                    .{ .null = {} },
            );
            try o.put(allocator, "value", .{ .object = vo });
        },
        .dyn_trait => |bounds| {
            try o.put(allocator, "kind", .{ .string = "dyn_trait" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "bounds", try encodeBounds(allocator, bounds));
            try o.put(allocator, "value", .{ .object = vo });
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

/// Encode a closure with every field it declares: the captures (each with its
/// own mode and type-table id), the parameter pattern ids, the return type id,
/// the body block with its own label, and the call trait. A label on the body
/// is part of the closure, so it travels with it rather than being folded into
/// the enclosing expression.
fn encodeClosure(allocator: std.mem.Allocator, closure: exprs.ClosureExpr) !Json {
    var o = ObjectMap.empty;
    var captures = Array.init(allocator);
    for (closure.captures) |capture| {
        var capture_object = ObjectMap.empty;
        try capture_object.put(allocator, "name", .{ .string = capture.name });
        try capture_object.put(allocator, "mode", .{ .string = @tagName(capture.mode) });
        try capture_object.put(allocator, "ty", mkInt(capture.ty));
        try captures.append(.{ .object = capture_object });
    }
    try o.put(allocator, "captures", .{ .array = captures });
    try o.put(allocator, "params", try encodeIdList(allocator, closure.params));
    try o.put(allocator, "return_ty", encodeOptId(closure.return_ty));
    try o.put(allocator, "body", try encodeBlockExpr(allocator, closure.body));
    try o.put(allocator, "trait", .{ .string = @tagName(closure.trait) });
    return .{ .object = o };
}

fn encodeIteratorAdapter(
    allocator: std.mem.Allocator,
    adapter: exprs.IteratorAdapter,
) !Json {
    var o = ObjectMap.empty;
    switch (adapter) {
        .map => |map| {
            try o.put(allocator, "kind", .{ .string = "map" });
            try o.put(allocator, "closure", try encodeClosure(allocator, map.closure));
        },
        .filter => |filter| {
            try o.put(allocator, "kind", .{ .string = "filter" });
            try o.put(allocator, "closure", try encodeClosure(allocator, filter.closure));
        },
        .flat_map => |closure| {
            try o.put(allocator, "kind", .{ .string = "flat_map" });
            try o.put(allocator, "closure", try encodeClosure(allocator, closure));
        },
        .enumerate => try o.put(allocator, "kind", .{ .string = "enumerate" }),
        .zip => |zip| {
            try o.put(allocator, "kind", .{ .string = "zip" });
            try o.put(allocator, "other", mkInt(zip.other));
        },
        .range_rev => try o.put(allocator, "kind", .{ .string = "range_rev" }),
        .other => |unsupported| {
            try o.put(allocator, "kind", .{ .string = "other" });
            try o.put(allocator, "reason", .{ .string = unsupported.reason });
            try o.put(
                allocator,
                "suggested_version",
                .{ .string = @tagName(unsupported.suggested_version) },
            );
        },
    }
    return .{ .object = o };
}

fn encodeIteratorChain(
    allocator: std.mem.Allocator,
    chain: exprs.IteratorChainExpr,
) !Json {
    var o = ObjectMap.empty;
    var adapters = Array.init(allocator);
    for (chain.adapters) |adapter| {
        try adapters.append(try encodeIteratorAdapter(allocator, adapter));
    }
    try o.put(allocator, "source", mkInt(chain.source));
    try o.put(allocator, "adapters", .{ .array = adapters });
    // Always written, never defaulted away: a chain that ends in `collect_vec`
    // or `sum` is a different program from one left as an iterator value, so
    // the field is part of what the wire has to say.
    try o.put(allocator, "terminal", .{ .string = @tagName(chain.terminal) });
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
        .adapter => |chain| {
            try o.put(allocator, "kind", .{ .string = "adapter" });
            try o.put(allocator, "value", try encodeIteratorChain(allocator, chain));
        },
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
        .array => |v| {
            try o.put(allocator, "kind", .{ .string = "array" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "elements", try encodeIdList(allocator, v.elements));
            try vo.put(
                allocator,
                "repeat",
                if (v.repeat) |r| try mkCount(allocator, r) else .{ .null = {} },
            );
            try o.put(allocator, "value", .{ .object = vo });
        },
        .range => |v| {
            try o.put(allocator, "kind", .{ .string = "range" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "start", mkInt(v.start));
            try vo.put(allocator, "end", encodeOptId(v.end));
            try vo.put(allocator, "inclusive", .{ .bool = v.inclusive });
            try o.put(allocator, "value", .{ .object = vo });
        },
        .panic_ => |v| {
            try o.put(allocator, "kind", .{ .string = "panic_" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "message", .{ .string = v.message });
            try o.put(allocator, "value", .{ .object = vo });
        },
        .vec_lit => |v| {
            try o.put(allocator, "kind", .{ .string = "vec_lit" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "elements", try encodeIdList(allocator, v.elements));
            try vo.put(allocator, "repeat", try encodeVecRepeatCount(allocator, v.repeat));
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
        .core_call => |v| {
            try o.put(allocator, "kind", .{ .string = "core_call" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "function", .{ .string = @tagName(v.function) });
            try vo.put(allocator, "generic_args", try encodeTypeList(allocator, v.generic_args));
            try vo.put(allocator, "args", try encodeIdList(allocator, v.args));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .core_function => |v| {
            try o.put(allocator, "kind", .{ .string = "core_function" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "function", .{ .string = @tagName(v.function) });
            try vo.put(allocator, "generic_args", try encodeTypeList(allocator, v.generic_args));
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
        .external_variant => |v| {
            try o.put(allocator, "kind", .{ .string = "external_variant" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "owner", try encodeExternalNominal(allocator, v.owner));
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
        .format_write => |v| {
            try o.put(allocator, "kind", .{ .string = "format_write" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "writer", mkInt(v.writer));
            try vo.put(allocator, "template", .{ .string = v.template });
            try vo.put(allocator, "args", try encodeIdList(allocator, v.args));
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
        .closure => |closure| {
            try o.put(allocator, "kind", .{ .string = "closure" });
            try o.put(allocator, "value", try encodeClosure(allocator, closure));
        },
        .iterator_chain => |chain| {
            try o.put(allocator, "kind", .{ .string = "iterator_chain" });
            try o.put(allocator, "value", try encodeIteratorChain(allocator, chain));
        },
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
        .external_variant => |t| {
            try o.put(allocator, "kind", .{ .string = "external_variant" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "owner", try encodeExternalNominal(allocator, t.owner));
            try vo.put(allocator, "variant", .{ .string = t.variant });
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

fn encodeStringList(allocator: std.mem.Allocator, values: []const []const u8) !Json {
    var arr = Array.init(allocator);
    errdefer arr.deinit();
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
    // Everything this function builds — the JSON tree, the crate member masks,
    // and the printed count and literal texts — lives in one arena over
    // `allocator` and is released on both the success and the failure path.
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const scratch_allocator = scratch.allocator();

    var root_map = ObjectMap.empty;
    try root_map.put(scratch_allocator, "format_version", mkInt(fmt_version));
    try root_map.put(scratch_allocator, "sidecar", encodeOptStr(g.sidecar));
    try root_map.put(scratch_allocator, "toolchain", encodeOptStr(g.toolchain));

    var crates_arr = Array.init(scratch_allocator);
    for (g.crates.items) |c| {
        const member = try crateMembers(scratch_allocator, g, c.root);
        try crates_arr.append(try encodeCrate(scratch_allocator, g, c, member));
    }
    try root_map.put(scratch_allocator, "crates", .{ .array = crates_arr });

    if (bodies) |b| {
        try root_map.put(scratch_allocator, "bodies", try encodeBodies(scratch_allocator, b));
    }

    // The only allocation that outlives this call: the wire bytes, copied out
    // of the arena tree before `defer` releases it.
    const root_val: Json = .{ .object = root_map };
    // Zig 0.16: std.json.stringify was replaced by Stringify.valueAlloc, which
    // owns and returns a []u8 buffer to be freed with the passed allocator.
    return std.json.Stringify.valueAlloc(allocator, root_val, .{});
}

/// Encode the graph as v1 JSON, without bodies. Inverses `parse`.
/// The caller frees the result with `allocator`; temporary encoding allocations
/// are released on success and failure.
pub fn encode(allocator: std.mem.Allocator, g: *const graph.CrateGraph) ![]u8 {
    return encodeRoot(allocator, g, null, 1);
}

/// Encode the full model as v3 JSON. Inverses `parseFull`.
/// The caller frees the result with `allocator`; temporary encoding allocations
/// are released on success and failure.
pub fn encodeFull(allocator: std.mem.Allocator, model: FullModel) ![]u8 {
    return encodeRoot(allocator, &model.graph, &model.bodies, wire_format_version);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// Keep the graph-codec fixture local to these legacy v1 tests. The canonical
// mini wire fixture must not be fed to this parser.
const legacy_mini_json =
    \\{
    \\  "format_version": 1,
    \\  "sidecar": "rustdoc",
    \\  "toolchain": "nightly-2025-01-01",
    \\  "crates": [{
    \\    "name": "mini",
    \\    "edition": 2021,
    \\    "kind": "lib",
    \\    "root": 0,
    \\    "is_translated": true,
    \\    "deps": [],
    \\    "entities": [
    \\      {"id": 0, "kind": "module", "name": "", "span": {"start_line": 1, "start_col": 1, "end_line": 7, "end_col": 1}, "visibility": {"kind": "public"}, "parent": null, "resolved": null, "renamed_to": null, "attributes": []},
    \\      {"id": 1, "kind": "module", "name": "util", "span": {"start_line": 3, "start_col": 1, "end_line": 3, "end_col": 9}, "visibility": {"kind": "public"}, "parent": 0, "resolved": null, "renamed_to": null, "attributes": []},
    \\      {"id": 2, "kind": "struct_", "name": "Point", "span": {"start_line": 5, "start_col": 1, "end_line": 8, "end_col": 2}, "visibility": {"kind": "public"}, "parent": 0, "resolved": null, "renamed_to": null, "attributes": [{"name": "doc", "meta": "a point", "known": false}]},
    \\      {"id": 3, "kind": "enum_", "name": "Shape", "span": {"start_line": 10, "start_col": 1, "end_line": 14, "end_col": 2}, "visibility": {"kind": "public"}, "parent": 0, "resolved": null, "renamed_to": null, "attributes": []},
    \\      {"id": 4, "kind": "fn_", "name": "area", "span": {"start_line": 16, "start_col": 1, "end_line": 21, "end_col": 2}, "visibility": {"kind": "public"}, "parent": 0, "resolved": null, "renamed_to": null, "attributes": []},
    \\      {"id": 5, "kind": "fn_", "name": "origin", "span": {"start_line": 23, "start_col": 1, "end_line": 25, "end_col": 2}, "visibility": {"kind": "public"}, "parent": 0, "resolved": null, "renamed_to": null, "attributes": []},
    \\      {"id": 6, "kind": "use_", "name": "helper", "span": {"start_line": 27, "start_col": 1, "end_line": 27, "end_col": 22}, "visibility": {"kind": "public"}, "parent": 0, "resolved": 7, "renamed_to": null, "attributes": []},
    \\      {"id": 7, "kind": "fn_", "name": "helper", "span": {"start_line": 1, "start_col": 1, "end_line": 3, "end_col": 2}, "visibility": {"kind": "public"}, "parent": 1, "resolved": null, "renamed_to": null, "attributes": []},
    \\      {"id": 8, "kind": "variant", "name": "Circle", "span": {"start_line": 11, "start_col": 5, "end_line": 11, "end_col": 16}, "visibility": {"kind": "public"}, "parent": 3, "resolved": null, "renamed_to": null, "attributes": []},
    \\      {"id": 9, "kind": "variant", "name": "Rect", "span": {"start_line": 12, "start_col": 5, "end_line": 13, "end_col": 17}, "visibility": {"kind": "public"}, "parent": 3, "resolved": null, "renamed_to": null, "attributes": []}
    \\    ],
    \\    "modules": [
    \\      {"id": 0, "kind": "root", "name": "", "parent": null, "source_path": "src/lib.rs", "is_crate": true, "is_extern": false, "span": {"start_line": 1, "start_col": 1, "end_line": 7, "end_col": 1}, "items": [1, 2, 3, 4, 5, 6], "attributes": []},
    \\      {"id": 1, "kind": "file", "name": "util", "parent": 0, "source_path": "src/util.rs", "is_crate": false, "is_extern": false, "span": {"start_line": 3, "start_col": 1, "end_line": 3, "end_col": 9}, "items": [7], "attributes": []}
    \\    ],
    \\    "uses": [
    \\      {"id": 6, "kind": "alias", "local_name": "helper", "is_pub_export": true, "target": 7, "span": {"start_line": 27, "start_col": 1, "end_line": 27, "end_col": 22}}
    \\    ]
    \\  }]
    \\}
;

fn parseMini(allocator: std.mem.Allocator) !graph.CrateGraph {
    return parse(allocator, legacy_mini_json);
}

fn expectDecodeDepsError(bytes: []const u8, expected: anyerror) !void {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(Json, allocator, bytes, .{});
    defer parsed.deinit();

    if (decodeDeps(allocator, parsed.value)) |dependencies| {
        freeDecodedCrateDeps(allocator, dependencies);
        return error.ExpectedDependencyDecodeFailure;
    } else |actual| {
        try std.testing.expectEqual(expected, actual);
    }
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

test "full-model wire format version is 3" {
    const allocator = std.testing.allocator;
    var model: FullModel = .{
        .graph = try parseMini(allocator),
        .bodies = emptyBodies(),
    };
    defer model.graph.deinit();

    const encoded = try encodeFull(allocator, model);
    defer allocator.free(encoded);
    var parsed = std.json.parseFromSlice(Json, allocator, encoded, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();
    const root = try getObj(parsed.value);
    try std.testing.expectEqual(@as(u32, 3), try reqU32(root, "format_version"));
}

test "parseFull rejects v1 translation input" {
    const payload =
        \\{"format_version":1,"sidecar":null,"toolchain":null,"crates":[]}
    ;
    try std.testing.expectError(
        error.InvalidFormatVersion,
        parseFull(std.testing.allocator, payload),
    );
}

test "parseFull rejects v2 translation input" {
    const payload =
        \\{"format_version":2,"sidecar":null,"toolchain":null,"crates":[]}
    ;
    try std.testing.expectError(
        error.InvalidFormatVersion,
        parseFull(std.testing.allocator, payload),
    );
}

test "parseFull rejects a missing body table" {
    const payload =
        \\{"format_version":3,"sidecar":null,"toolchain":null,"crates":[]}
    ;
    try std.testing.expectError(
        error.MissingField,
        parseFull(std.testing.allocator, payload),
    );
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
test "encode preserves nonempty use payloads" {
    const allocator = std.testing.allocator;
    var g = try parseMini(allocator);
    defer g.deinit();

    const encoded = try encode(allocator, &g);
    defer allocator.free(encoded);
    var parsed = std.json.parseFromSlice(Json, allocator, encoded, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    const root = try getObj(parsed.value);
    const crates = switch (try req(root, "crates")) {
        .array => |array| array,
        else => return error.BadWireFormat,
    };
    const crate = try getObj(crates.items[0]);
    const uses = switch (try req(crate, "uses")) {
        .array => |array| array,
        else => return error.BadWireFormat,
    };
    try std.testing.expectEqual(@as(usize, 1), uses.items.len);
    const use_object = try getObj(uses.items[0]);
    try std.testing.expectEqualStrings("alias", try reqStr(use_object, "kind"));
    try std.testing.expectEqualStrings("helper", try reqStr(use_object, "local_name"));
    try std.testing.expectEqual(@as(u32, 7), try reqU32(use_object, "target"));
}

fn checkGraphEncodeAllocationFailures(
    allocator: std.mem.Allocator,
    g: *const graph.CrateGraph,
) !void {
    const encoded = try encode(allocator, g);
    // Only the wire bytes belong to `allocator`; freeing them here is the
    // proof that the caller's free matches the caller's own allocation.
    allocator.free(encoded);
}

fn checkFullEncodeAllocationFailures(
    allocator: std.mem.Allocator,
    model: FullModel,
) !void {
    const encoded = try encodeFull(allocator, model);
    allocator.free(encoded);
}

// The graph-only writer owns nothing but its output bytes: the JSON tree, the
// crate member masks, and the printed texts belong to one arena over the
// caller's allocator, so a fault at any point of the walk must be refused
// with nothing retained.
test "encode releases its temporary tree at every allocation fault" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const g = try parseMini(arena.allocator());

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkGraphEncodeAllocationFailures,
        .{&g},
    );
}

// The same contract for the full-model writer, on a body table that reaches
// a nested block and the widest count the wire format carries.
test "encodeFull releases its temporary tree at every allocation fault" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 4,
    };
    const param: items.Param = .{ .name = "input", .ty = .{ .prim = .i32 }, .span = span };
    const expression_table = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .block = .{
            .statements = &.{},
            .tail = 1,
            .labelled = null,
        } } },
        .{ .id = 1, .span = span, .ty = 0, .kind = .{ .vec_lit = .{
            .elements = &.{2},
            .repeat = .{ .literal = std.math.maxInt(u64) },
        } } },
        .{ .id = 2, .span = span, .ty = 0, .kind = .{ .unit = {} } },
    };
    const body_kinds = [_]BodyKind{
        .none,
        .{ .fn_ = .{
            .params = &.{param},
            .ret = .{ .prim = .i32 },
            .body = 0,
        } },
    };
    const type_table = [_]types.Type{.{ .prim = .i32 }};
    const model: FullModel = .{
        .graph = try parseMini(allocator),
        .bodies = .{
            .exprs = &expression_table,
            .stmts = &.{},
            .pats = &.{},
            .types = &type_table,
            .bodies = &body_kinds,
        },
    };

    // The printed count is arena data, but the wire bytes carry it as an exact
    // unquoted number that outlives the tree.
    const encoded = try encodeFull(std.testing.allocator, model);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(
        std.mem.indexOf(u8, encoded, "\"repeat\":18446744073709551615") != null,
    );

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkFullEncodeAllocationFailures,
        .{model},
    );
}

test "dependency codec preserves default-feature tri-state and ordered features" {
    const allocator = std.testing.allocator;
    const expected = [_]graph.CrateDep{
        .{
            .extern_name = "omitted",
            .local_alias = "omitted",
            .id = 1,
            .default_features = null,
            .features = &.{},
        },
        .{
            .extern_name = "enabled",
            .local_alias = "enabled_alias",
            .id = 2,
            .default_features = true,
            .features = &.{ "derive", "std" },
        },
        .{
            .extern_name = "disabled",
            .local_alias = "disabled_alias",
            .id = 3,
            .default_features = false,
            .features = &.{"alloc"},
        },
    };

    var dependencies_value: Json = blk: {
        var dependencies = Array.init(allocator);
        errdefer {
            var partial: Json = .{ .array = dependencies };
            freeValue(allocator, &partial);
        }
        for (expected) |dependency| {
            try dependencies.append(try encodeDep(allocator, dependency));
        }
        break :blk .{ .array = dependencies };
    };
    defer freeValue(allocator, &dependencies_value);

    const encoded = try std.json.Stringify.valueAlloc(allocator, dependencies_value, .{});
    defer allocator.free(encoded);

    const decoded = blk: {
        var parse_arena = std.heap.ArenaAllocator.init(allocator);
        defer parse_arena.deinit();
        var parsed = std.json.parseFromSlice(Json, parse_arena.allocator(), encoded, .{}) catch
            return error.InvalidJson;
        defer parsed.deinit();

        const encoded_dependencies = switch (parsed.value) {
            .array => |array| array,
            else => return error.BadWireFormat,
        };
        try std.testing.expectEqual(expected.len, encoded_dependencies.items.len);
        for (encoded_dependencies.items) |dependency_value| {
            const dependency = try getObj(dependency_value);
            try std.testing.expect(dependency.get("default_features") != null);
            try std.testing.expect(dependency.get("features") != null);
        }

        const omitted = try getObj(encoded_dependencies.items[0]);
        switch (try req(omitted, "default_features")) {
            .null => {},
            else => return error.BadWireFormat,
        }
        const omitted_features = switch (try req(omitted, "features")) {
            .array => |array| array,
            else => return error.BadWireFormat,
        };
        try std.testing.expectEqual(@as(usize, 0), omitted_features.items.len);

        const enabled = try getObj(encoded_dependencies.items[1]);
        try std.testing.expect(try reqBool(enabled, "default_features"));
        const disabled = try getObj(encoded_dependencies.items[2]);
        try std.testing.expect(!try reqBool(disabled, "default_features"));

        break :blk try decodeDeps(allocator, parsed.value);
    };
    defer freeDecodedCrateDeps(allocator, decoded);

    @memset(encoded, 0xA5);
    try std.testing.expectEqual(expected.len, decoded.len);
    for (expected, decoded) |expected_dependency, actual_dependency| {
        try std.testing.expectEqualStrings(
            expected_dependency.extern_name,
            actual_dependency.extern_name,
        );
        try std.testing.expectEqualStrings(
            expected_dependency.local_alias,
            actual_dependency.local_alias,
        );
        try std.testing.expectEqual(expected_dependency.id, actual_dependency.id);
        try std.testing.expectEqual(
            expected_dependency.default_features,
            actual_dependency.default_features,
        );
        try std.testing.expectEqual(
            expected_dependency.features.len,
            actual_dependency.features.len,
        );
        for (expected_dependency.features, actual_dependency.features) |
            expected_feature,
            actual_feature,
        | {
            try std.testing.expectEqualStrings(expected_feature, actual_feature);
        }
    }
}

test "dependency decoder requires typed default-feature and feature metadata" {
    const cases = [_]struct {
        bytes: []const u8,
        expected: anyerror,
    }{
        .{
            .bytes =
            \\[{"extern_name":"dep","local_alias":"dep","id":1,
            \\  "features":[]}]
            ,
            .expected = error.MissingField,
        },
        .{
            .bytes =
            \\[{"extern_name":"dep","local_alias":"dep","id":1,
            \\  "default_features":"false","features":[]}]
            ,
            .expected = error.BadWireFormat,
        },
        .{
            .bytes =
            \\[{"extern_name":"dep","local_alias":"dep","id":1,
            \\  "default_features":null}]
            ,
            .expected = error.MissingField,
        },
        .{
            .bytes =
            \\[{"extern_name":"dep","local_alias":"dep","id":1,
            \\  "default_features":null,"features":false}]
            ,
            .expected = error.BadWireFormat,
        },
        .{
            .bytes =
            \\[{"extern_name":"dep","local_alias":"dep","id":1,
            \\  "default_features":null,"features":["std",1]}]
            ,
            .expected = error.BadWireFormat,
        },
    };

    for (cases) |case| {
        try expectDecodeDepsError(case.bytes, case.expected);
    }
}

test "8. invalid JSON is rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidJson, parse(allocator, "this is not json {"));
}

test "legacy JSON parsers preserve allocation errors" {
    const bytes =
        \\{"format_version":3,"crates":[],
        \\ "bodies":{"exprs":[],"stmts":[],"pats":[],"types":[],"bodies":[]}}
    ;
    inline for (.{ parse, parseFull }) |decode_json| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        try std.testing.expectError(error.OutOfMemory, decode_json(failing.allocator(), bytes));
        try std.testing.expectError(
            error.InvalidJson,
            decode_json(std.testing.allocator, "this is not json {"),
        );
    }
}
test "decoder releases partially owned values on allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const attributes_json =
        \\{"attributes":[{"name":"first","meta":"one","known":true},{"name":"second","meta":"two","known":false}]}
    ;
    var parsed_attributes = std.json.parseFromSlice(Json, allocator, attributes_json, .{}) catch
        return error.InvalidJson;
    defer parsed_attributes.deinit();
    const attributes_value = (try getObj(parsed_attributes.value)).get("attributes") orelse
        return error.BadWireFormat;

    var attribute_fail_index: usize = 0;
    while (attribute_fail_index < 8) : (attribute_fail_index += 1) {
        var failing_allocator = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = attribute_fail_index,
        });
        const result = decodeAttributes(failing_allocator.allocator(), attributes_value);
        if (result) |attributes| {
            freeDecodedAttributes(failing_allocator.allocator(), attributes);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
        try std.testing.expectEqual(
            failing_allocator.allocated_bytes,
            failing_allocator.freed_bytes,
        );
    }

    const nested_type_json =
        \\{"kind":"result","value":{"ok":{"kind":"path","value":{"segments":[{"name":"Value","id":null}]}}, "err":{"kind":"prim","value":"u8"}, "is_error_unionable":true}}
    ;
    var parsed_type = std.json.parseFromSlice(Json, allocator, nested_type_json, .{}) catch
        return error.InvalidJson;
    defer parsed_type.deinit();
    var type_fail_index: usize = 0;
    while (type_fail_index < 8) : (type_fail_index += 1) {
        var failing_allocator = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = type_fail_index,
        });
        const result = decodeType(failing_allocator.allocator(), parsed_type.value);
        if (result) |ty| {
            freeDecodedType(failing_allocator.allocator(), ty);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
        try std.testing.expectEqual(
            failing_allocator.allocated_bytes,
            failing_allocator.freed_bytes,
        );
    }
}

test "decodeBodies releases each table on final transfer failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bodies_json =
        \\{"exprs":[{"id":0,"span":{"start_line":1,"start_col":1,"end_line":1,"end_col":1},"ty":null,"kind":"unit","value":null}],"stmts":[{"id":0,"span":{"start_line":1,"start_col":1,"end_line":1,"end_col":1},"ty":null,"kind":"expr","value":0}],"pats":[{"id":0,"span":{"start_line":1,"start_col":1,"end_line":1,"end_col":1},"ty":null,"kind":"wildcard","value":null}],"types":[{"kind":"prim","value":"u8"}],"bodies":[{"kind":"none"}]}
    ;
    var parsed = std.json.parseFromSlice(Json, allocator, bodies_json, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    var fail_index: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var failing_allocator = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = fail_index,
            .resize_fail_index = 0,
        });
        const result = decodeBodies(failing_allocator.allocator(), parsed.value);
        if (result) |bodies| {
            freeDecodedBodies(failing_allocator.allocator(), bodies);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
        try std.testing.expectEqual(
            failing_allocator.allocated_bytes,
            failing_allocator.freed_bytes,
        );
    }
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

fn hexJson(allocator: std.mem.Allocator) ![]const u8 {
    const test_io = std.testing.io;
    var io_buf: [4096]u8 = undefined;
    var dir = std.Io.Dir.cwd();
    const file = try dir.openFile(test_io, "test/hex.json", .{});
    defer file.close(test_io);
    var reader = file.reader(test_io, &io_buf);
    return reader.interface.allocRemaining(allocator, .limited(1 << 22));
}

test "parse accepts v3 legacy graph inventory" {
    const allocator = std.testing.allocator;
    const bytes = try fnvJson(allocator);
    defer allocator.free(bytes);

    var g = try parse(allocator, bytes);
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 1), g.crates.items.len);
    try std.testing.expect(g.findCrate("fnv") != null);
    try std.testing.expect(g.symbol_table.count() > 0);
}

test "legacy fn body missing is_allocating is transactional" {
    const allocator = std.testing.allocator;
    const body_json =
        \\{"kind":"fn_","value":{"params":[{"name":"x","ty":{"kind":"prim","value":"u8"},"span":{"start_line":1,"start_col":1,"end_line":1,"end_col":1}}],"ret":{"kind":"prim","value":"u8"},"generic_params":[],"body":0}}
    ;
    var parsed = try std.json.parseFromSlice(Json, allocator, body_json, .{});
    defer parsed.deinit();

    try std.testing.expectError(
        error.MissingField,
        decodeBodyKind(allocator, parsed.value),
    );
}
test "parseFull rejects incomplete legacy fnv body" {
    const allocator = std.testing.allocator;
    const bytes = try fnvJson(allocator);
    defer allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.MissingField,
        parseFull(arena.allocator(), bytes),
    );
}

test "parseFull rejects legacy hex enum without body value" {
    const allocator = std.testing.allocator;
    const bytes = try hexJson(allocator);
    defer allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.MissingField,
        parseFull(arena.allocator(), bytes),
    );
}

// A `vec![e; N]` count names target elements, not host storage, so it
// describes the translated 64-bit program on any host. `std.json` parses a
// JSON number into an `i64` and keeps anything wider as decimal digits, so
// both spellings of the same bare number have to reach `u64` — through the
// literal arm, which is what a count the translator already holds means.
test "vec_lit repeat counts read the full u64 range off the wire" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        token: []const u8,
        count: ?exprs.VecRepeatCount,
    }{
        .{ .token = "0", .count = .{ .literal = 0 } },
        .{ .token = "4294967296", .count = .{ .literal = 4294967296 } },
        .{ .token = "9007199254740993", .count = .{ .literal = 9007199254740993 } },
        .{ .token = "9223372036854775808", .count = .{ .literal = 9223372036854775808 } },
        .{ .token = "18446744073709551615", .count = .{ .literal = std.math.maxInt(u64) } },
        .{ .token = "null", .count = null },
    };
    for (cases) |case| {
        var payload: [64]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&payload, "{{\"repeat\":{s}}}", .{case.token});
        var parsed = try std.json.parseFromSlice(Json, allocator, bytes, .{});
        defer parsed.deinit();
        const object = try getObj(parsed.value);
        try std.testing.expectEqual(case.count, try decodeVecRepeatCount(object, "repeat"));
    }
}

// A count no `u64` describes, and one that is not a count at all, are both
// `BadWireFormat`. Neither is clamped, rounded, or read as a float.
test "vec_lit repeat counts that no u64 describes are rejected" {
    const allocator = std.testing.allocator;
    const rejected = [_][]const u8{
        "-1",
        "18446744073709551616",
        "1e3",
        "1.5",
        "\"3\"",
    };
    for (rejected) |token| {
        var payload: [64]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&payload, "{{\"repeat\":{s}}}", .{token});
        var parsed = try std.json.parseFromSlice(Json, allocator, bytes, .{});
        defer parsed.deinit();
        const object = try getObj(parsed.value);
        try std.testing.expectError(
            error.BadWireFormat,
            decodeVecRepeatCount(object, "repeat"),
        );
    }
}

// `vec![e; n]` with a count the target evaluates: the count is an ordinary
// expression node, so it travels as one, tagged with exactly the two keys the
// canonical semantic-IR wire gives it. This reader has to agree with that
// writer byte for byte or `--dump model` reports a wire error on an IR that
// the semantic pipeline emits every day.
test "vec_lit repeat counts read the canonical dynamic-count object" {
    const allocator = std.testing.allocator;
    const bytes =
        \\{"repeat":{"tag":"expression","value":7}}
    ;
    var parsed = try std.json.parseFromSlice(Json, allocator, bytes, .{});
    defer parsed.deinit();
    const object = try getObj(parsed.value);
    try std.testing.expectEqual(
        @as(?exprs.VecRepeatCount, .{ .expression = 7 }),
        try decodeVecRepeatCount(object, "repeat"),
    );

    // The key is `tag`, not `kind`: the sibling array-length object spells it
    // the other way, and reading one as the other would invent a count.
    var kinded = try std.json.parseFromSlice(
        Json,
        allocator,
        \\{"repeat":{"kind":"expression","value":7}}
    ,
        .{},
    );
    defer kinded.deinit();
    try std.testing.expectError(
        error.MissingField,
        decodeVecRepeatCount(try getObj(kinded.value), "repeat"),
    );
}

// An object this decoder cannot read exactly is never one it guesses at: a
// missing key, a third key, another tag, or a `value` that is not a node id
// is `BadWireFormat`.
test "vec_lit repeat counts with a malformed dynamic-count object are rejected" {
    const allocator = std.testing.allocator;
    const rejected = [_][]const u8{
        \\{"repeat":{"tag":"expression"}}
        ,
        \\{"repeat":{"value":7}}
        ,
        \\{"repeat":{"tag":"expression","value":7,"extra":true}}
        ,
        \\{"repeat":{"tag":"literal","value":7}}
        ,
        \\{"repeat":{"tag":"expression","value":"7"}}
        ,
        \\{"repeat":{"tag":"expression","value":1.5}}
        ,
        \\{"repeat":{"tag":"expression","value":null}}
        ,
        \\{"repeat":{"tag":7,"value":7}}
        ,
        \\{"repeat":[]}
        ,
        \\{"repeat":{"tag":"expression","value":-1}}
        ,
        \\{"repeat":{"tag":"expression","value":4294967296}}
        ,
    };
    for (rejected) |token| {
        var parsed = try std.json.parseFromSlice(Json, allocator, token, .{});
        defer parsed.deinit();
        const object = try getObj(parsed.value);
        try std.testing.expectError(
            error.BadWireFormat,
            decodeVecRepeatCount(object, "repeat"),
        );
    }
}

// End to end through the writer this CLI reads: a body table holding one
// literal-count, one null-count, and one dynamic-count vector encodes to the
// exact canonical bytes, and `parseFull` reads every one of them back as the
// union the encoder was handed. The literal and null goldens are unchanged by
// the dynamic form — that is the whole point of growing the count rather
// than re-spelling it.
test "full model round-trips every vec_lit repeat spelling through the wire" {
    const allocator = std.testing.allocator;
    var graph_arena = std.heap.ArenaAllocator.init(allocator);
    defer graph_arena.deinit();

    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 4,
    };
    const param: items.Param = .{ .name = "input", .ty = .{ .prim = .i32 }, .span = span };
    const expression_table = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .block = .{
            .statements = &.{},
            .tail = 1,
            .labelled = null,
        } } },
        // `vec![1, 2]` — the explicit-list form, no count at all.
        .{ .id = 1, .span = span, .ty = 0, .kind = .{ .vec_lit = .{
            .elements = &.{ 4, 5 },
            .repeat = null,
        } } },
        // `vec![e; 13]` — a count the translator already holds.
        .{ .id = 2, .span = span, .ty = 0, .kind = .{ .vec_lit = .{
            .elements = &.{5},
            .repeat = .{ .literal = 13 },
        } } },
        // `vec![e; n]` — a count the target evaluates.
        .{ .id = 3, .span = span, .ty = 0, .kind = .{ .vec_lit = .{
            .elements = &.{5},
            .repeat = .{ .expression = 6 },
        } } },
        .{ .id = 4, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 5, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 6, .span = span, .ty = 0, .kind = .{ .unit = {} } },
    };
    const body_kinds = [_]BodyKind{
        .none,
        .{ .fn_ = .{
            .params = &.{param},
            .ret = .{ .prim = .i32 },
            .body = 0,
        } },
    };
    const type_table = [_]types.Type{.{ .prim = .i32 }};
    const model: FullModel = .{
        .graph = try parseMini(graph_arena.allocator()),
        .bodies = .{
            .exprs = &expression_table,
            .stmts = &.{},
            .pats = &.{},
            .types = &type_table,
            .bodies = &body_kinds,
        },
    };

    const encoded = try encodeFull(allocator, model);
    defer allocator.free(encoded);
    try std.testing.expect(
        std.mem.indexOf(u8, encoded, "\"repeat\":null") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, encoded, "\"repeat\":13") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            encoded,
            "\"repeat\":{\"tag\":\"expression\",\"value\":6}",
        ) != null,
    );

    var read_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer read_arena.deinit();
    const decoded = try parseFull(read_arena.allocator(), encoded);
    // Every vector keeps the element nodes it was built from; only the count
    // encoding is what this test is about.
    const read_elements = [_][]const exprs.NodeId{
        &.{ 4, 5 },
        &.{5},
        &.{5},
    };
    const read_repeats = [_]?exprs.VecRepeatCount{
        null,
        .{ .literal = 13 },
        .{ .expression = 6 },
    };
    for (read_repeats, read_elements, 1..) |expected_repeat, expected_elements, index| {
        const vector = switch (decoded.bodies.exprs[index].kind) {
            .vec_lit => |vec| vec,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqualSlices(
            exprs.NodeId,
            expected_elements,
            vector.elements,
        );
        try std.testing.expectEqual(expected_repeat, vector.repeat);
    }
}

// ── Shape-coverage audit ───────────────────────────────────────────────────
// Every arm the model declares has to survive encode → parseFull. The
// fixtures below build one body table holding one node per arm and read every
// field back, so an arm the codec drops is a decode refusal rather than a
// silent default.

const audit_span: spine.Span = .{
    .start_line = 2,
    .start_col = 3,
    .end_line = 4,
    .end_col = 5,
};

/// The empty slice a fixture row uses where the model says "no elements".
///
/// A static empty slice, not `allocator.alloc(T, 0)`: the allocator hands back
/// a zero-length slice it will not accept back, and the free helpers above
/// release a list without first asking whether one was allocated. Every one of
/// them now guards on length, so a static empty slice is the value they expect
/// to be handed and the value they decline to free.
fn emptySlice(comptime T: type, allocator: std.mem.Allocator) []const T {
    _ = allocator;
    return &.{};
}

/// Build a one-crate graph with every optional string set to a non-default
/// value, so a decode that substitutes a default for absent data is caught.
fn auditGraph(allocator: std.mem.Allocator) !graph.CrateGraph {
    var g = graph.CrateGraph.init(allocator);
    errdefer g.deinit();
    g.sidecar = try allocator.dupe(u8, "sidecar-probe");
    g.toolchain = try allocator.dupe(u8, "toolchain-probe");

    const entity_attributes = try allocator.alloc(spine.Attribute, 1);
    entity_attributes[0] = .{
        .name = try allocator.dupe(u8, "doc"),
        .meta = try allocator.dupe(u8, "a probed entity"),
        .known = true,
    };
    const root = try g.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = try allocator.dupe(u8, "Probe"),
        .span = audit_span,
        // The one visibility arm that carries a payload of its own.
        .visibility = .{ .in_path = try allocator.dupe(u8, "crate::probe") },
        .parent = null,
        .resolved = null,
        .renamed_to = try allocator.dupe(u8, "Probe_"),
        .attributes = entity_attributes,
    });
    const module_attributes = try allocator.alloc(spine.Attribute, 1);
    module_attributes[0] = .{
        .name = try allocator.dupe(u8, "path"),
        .meta = try allocator.dupe(u8, "src/probe.rs"),
        .known = false,
    };
    _ = try g.addModule(.{
        .id = 0,
        .kind = .directory,
        .name = try allocator.dupe(u8, "probe"),
        .parent = null,
        .source_path = try allocator.dupe(u8, "src/probe.rs"),
        .is_crate = true,
        .is_extern = true,
        .span = audit_span,
        .items = try allocator.dupe(spine.EntityId, &.{root}),
        .attributes = module_attributes,
    });
    const dependency_features = try allocator.dupe([]const u8, &.{ "derive", "std" });
    const dependencies = try allocator.alloc(graph.CrateDep, 1);
    dependencies[0] = .{
        .extern_name = try allocator.dupe(u8, "probe_dep"),
        .local_alias = try allocator.dupe(u8, "probe_alias"),
        .id = 77,
        .default_features = false,
        .features = dependency_features,
    };
    try g.addUse(.{
        .id = root,
        // The one UseKind arm with no payload.
        .kind = .glob,
        .local_name = try allocator.dupe(u8, "probe_use"),
        .is_pub_export = true,
        .target = root,
        .span = audit_span,
    });
    try g.addCrate(.{
        .name = try allocator.dupe(u8, "probe_crate"),
        .edition = 2024,
        .kind = .bin,
        .root = root,
        .deps = dependencies,
        .is_translated = false,
    });
    return g;
}

/// One type row per `types.Type` arm, with every optional and nested field
/// carrying a value that a defaulted decode would not reproduce.
fn auditTypeTable(allocator: std.mem.Allocator) ![]const types.Type {
    var table: std.ArrayListUnmanaged(types.Type) = .empty;
    errdefer {
        for (table.items) |ty| freeDecodedType(allocator, ty);
        table.deinit(allocator);
    }

    const segments = try allocator.alloc(types.PathSegment, 2);
    segments[0] = .{ .name = try allocator.dupe(u8, "core"), .id = 3 };
    segments[1] = .{ .name = try allocator.dupe(u8, "primitive"), .id = null };
    try table.append(allocator, .{ .path = .{ .segments = segments } });

    // Every primitive, so a decoder that hard-codes one cannot pass.
    inline for (@typeInfo(types.Prim).@"enum".field_names) |name| {
        try table.append(allocator, .{ .prim = @field(types.Prim, name) });
    }

    const reference = try allocator.create(types.Ref);
    reference.* = .{ .mut = true, .pointee = .{ .prim = .u8 } };
    try table.append(allocator, .{ .reference = reference });

    const raw_ptr = try allocator.create(types.RawPtr);
    raw_ptr.* = .{ .mut = false, .pointee = .{ .prim = .i64 } };
    try table.append(allocator, .{ .raw_ptr = raw_ptr });

    const slice = try allocator.create(types.Slice);
    slice.* = .{ .const_ = false, .elem = .{ .prim = .u16 } };
    try table.append(allocator, .{ .slice = slice });

    // Both ArrayLen arms: a literal length and a generic-parameter index.
    const array_literal = try allocator.create(types.Array);
    array_literal.* = .{ .elem = .{ .prim = .u8 }, .len = .{ .literal = 4 } };
    try table.append(allocator, .{ .array = array_literal });
    const array_generic = try allocator.create(types.Array);
    array_generic.* = .{ .elem = .{ .prim = .u8 }, .len = .{ .generic = 2 } };
    try table.append(allocator, .{ .array = array_generic });

    const tuple_params = try allocator.dupe(types.Type, &.{
        .{ .prim = .bool },
        .{ .prim = .char },
    });
    try table.append(allocator, .{ .tuple = tuple_params });

    const fn_params = try allocator.dupe(types.Type, &.{.{ .prim = .f32 }});
    const fn_ptr = try allocator.create(types.FnPtr);
    fn_ptr.* = .{ .params = fn_params, .ret = .{ .prim = .f64 } };
    try table.append(allocator, .{ .fn_ptr = fn_ptr });

    const generic_params = try allocator.dupe(types.Type, &.{.{ .prim = .usize }});
    try table.append(allocator, .{ .generic_inst = .{
        .decl = 91,
        .args = .{ .params = generic_params },
    } });

    const option = try allocator.create(types.Type);
    option.* = .{ .prim = .u128 };
    try table.append(allocator, .{ .option = option });

    const result = try allocator.create(types.Result);
    result.* = .{
        .ok = .{ .prim = .i32 },
        .err = .{ .prim = .u32 },
        .is_error_unionable = false,
    };
    try table.append(allocator, .{ .result = result });

    const boxed = try allocator.create(types.Type);
    boxed.* = .{ .prim = .isize };
    try table.append(allocator, .{ .boxed = boxed });

    // The three arms the model gained for types inference cannot yet resolve.
    // Each is set to a payload a defaulted decode would not produce.
    try table.append(allocator, .{ .external_nominal = .{
        .path = try allocator.dupe([]const u8, &.{ "alloc", "borrow", "Cow" }),
        .args = try allocator.dupe(types.Type, &.{.{ .prim = .u8 }}),
    } });
    // A trait bound, built once per row that needs it: each row owns its own
    // segments, args and bindings, because a rollback would otherwise release
    // the same three slices once per row that references them.
    const make_bound = struct {
        fn build(a: std.mem.Allocator, optional: bool) !types.Bound {
            const bound_segments = try a.alloc(types.PathSegment, 2);
            bound_segments[0] = .{ .name = try a.dupe(u8, "Iterator"), .id = 4 };
            bound_segments[1] = .{ .name = try a.dupe(u8, "Item"), .id = null };
            return .{
                .path = .{ .segments = bound_segments },
                .args = try a.dupe(types.Type, &.{.{ .prim = .u32 }}),
                .associated_types = try a.dupe(types.AssociatedTypeBinding, &.{.{
                    .name = try a.dupe(u8, "Item"),
                    .ty = .{ .prim = .u32 },
                }}),
                .optional = optional,
            };
        }
    }.build;

    const opaque_concrete = try allocator.create(types.Type);
    opaque_concrete.* = .{ .prim = .u32 };
    try table.append(allocator, .{ .@"opaque" = .{
        .bounds = try allocator.dupe(types.Bound, &.{try make_bound(allocator, true)}),
        .concrete = opaque_concrete,
    } });
    // An opaque whose concrete half is still absent, so the optional reads
    // back as null rather than being filled in.
    try table.append(allocator, .{ .@"opaque" = .{
        .bounds = try allocator.dupe(types.Bound, &.{try make_bound(allocator, false)}),
        .concrete = null,
    } });
    try table.append(allocator, .{ .dyn_trait = try allocator.dupe(
        types.Bound,
        &.{try make_bound(allocator, true)},
    ) });

    try table.append(allocator, .{ .unsupported = .{
        .reason = .rc_arc_refcell,
        .message = try allocator.dupe(u8, "Rc is not modelled"),
        .span = audit_span,
    } });

    return table.toOwnedSlice(allocator);
}

/// One pattern row per `PatternKind` arm.
fn auditPatternTable(allocator: std.mem.Allocator) ![]const exprs.Pattern {
    var table: std.ArrayListUnmanaged(exprs.Pattern) = .empty;
    errdefer {
        for (table.items) |pattern| freeDecodedPattern(allocator, pattern);
        table.deinit(allocator);
    }

    try table.append(allocator, .{
        .id = 0,
        .span = audit_span,
        .ty = 0,
        .kind = .{ .wildcard = {} },
    });
    try table.append(allocator, .{
        .id = 1,
        .span = audit_span,
        .ty = null,
        .kind = .{ .binding = .{
            .name = try allocator.dupe(u8, "bound"),
            .mode = .{ .mut_ref = {} },
            .mutable = true,
        } },
    });
    // Two more bindings, one per `BindMode` the fixture above does not reach,
    // so every mode's wire spelling is read back.
    inline for (.{ exprs.BindMode.value, exprs.BindMode.shared_ref }, 0..) |mode, index| {
        try table.append(allocator, .{
            .id = @intCast(100 + index),
            .span = audit_span,
            .ty = null,
            .kind = .{ .binding = .{
                .name = try allocator.dupe(u8, "mode_bound"),
                .mode = mode,
                .mutable = false,
            } },
        });
    }
    // A literal pattern: the arm `encodePatternKind` writes and the decoder
    // used to reject on the way back in.
    try table.append(allocator, .{
        .id = 2,
        .span = audit_span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{
            .text = try allocator.dupe(u8, "0xFF"),
            .value = 0xFF,
            .base = .hex,
            .ty_suffix = try allocator.dupe(u8, "u8"),
        } } },
    });
    try table.append(allocator, .{
        .id = 3,
        .span = audit_span,
        .ty = null,
        .kind = .{ .path = .{
            .def = 12,
            .variant = try allocator.dupe(u8, "Probe"),
        } },
    });
    try table.append(allocator, .{
        .id = 4,
        .span = audit_span,
        .ty = null,
        .kind = .{ .tuple = .{
            .elements = try allocator.dupe(exprs.NodeId, &.{ 1, 2 }),
            .rest = true,
        } },
    });
    try table.append(allocator, .{
        .id = 5,
        .span = audit_span,
        .ty = null,
        .kind = .{ .slice = .{
            .elements = try allocator.dupe(exprs.NodeId, &.{1}),
            .rest = 3,
        } },
    });
    const field_pats = try allocator.alloc(exprs.FieldPat, 2);
    field_pats[0] = .{
        .field = try allocator.dupe(u8, "x"),
        .pat = 1,
        .shorthand = false,
    };
    field_pats[1] = .{
        .field = try allocator.dupe(u8, "y"),
        .pat = null,
        .shorthand = true,
    };
    try table.append(allocator, .{
        .id = 6,
        .span = audit_span,
        .ty = null,
        .kind = .{ .struct_pat = .{ .def = 12, .fields = field_pats, .rest = true } },
    });
    try table.append(allocator, .{
        .id = 7,
        .span = audit_span,
        .ty = null,
        .kind = .{ .reference = .{ .mode = .{ .shared_ref = {} }, .inner = 1 } },
    });
    try table.append(allocator, .{
        .id = 8,
        .span = audit_span,
        .ty = null,
        .kind = .{ .@"or" = .{ .alternatives = try allocator.dupe(exprs.NodeId, &.{ 1, 3 }) } },
    });
    // An open-ended range: both bounds null, so a decoder that swapped `lo`
    // and `hi` still has to reproduce nulls in the right slots.
    try table.append(allocator, .{
        .id = 9,
        .span = audit_span,
        .ty = null,
        .kind = .{ .range = .{ .lo = null, .hi = 2, .inclusive = true } },
    });
    // A variant owned by an enum from outside this crate: the owner path has
    // no entity id at all, and both a bound and a shorthand field are set so
    // neither the optional pattern nor the optional rest reads back defaulted.
    const external_field_pats = try allocator.alloc(exprs.FieldPat, 2);
    external_field_pats[0] = .{
        .field = try allocator.dupe(u8, "0"),
        .pat = 4,
        .shorthand = false,
    };
    external_field_pats[1] = .{
        .field = try allocator.dupe(u8, "rest"),
        .pat = null,
        .shorthand = true,
    };
    try table.append(allocator, .{
        .id = 10,
        .span = audit_span,
        .ty = null,
        .kind = .{ .external_variant = .{
            .owner = .{
                .path = try allocator.dupe([]const u8, &.{ "core", "option", "Option" }),
                .args = try allocator.dupe(types.Type, &.{.{ .prim = .u8 }}),
            },
            .variant = try allocator.dupe(u8, "Some"),
            .fields = external_field_pats,
            .rest = true,
        } },
    });

    return table.toOwnedSlice(allocator);
}

/// One expression row per `ExprKind` arm. Cross-references point at rows in
/// this same table; the codec does not resolve them, so the audit reads the
/// ids back rather than the nodes.
fn auditExprTable(allocator: std.mem.Allocator) ![]const exprs.Expr {
    var table: std.ArrayListUnmanaged(exprs.Expr) = .empty;
    errdefer {
        for (table.items) |expression| freeDecodedExpr(allocator, expression);
        table.deinit(allocator);
    }

    // Every `Literal` arm, since `Literal` is a union of its own and a codec
    // that forgot one of them would drop the value silently.
    const literal_arms = [_]exprs.Literal{
        .{ .int = .{
            .text = try allocator.dupe(u8, "1"),
            .value = 1,
            .base = .dec,
            .ty_suffix = try allocator.dupe(u8, "u8"),
        } },
        .{ .float = .{
            .text = try allocator.dupe(u8, "1.5"),
            .value = 1.5,
        } },
        .{ .character = .{
            .text = try allocator.dupe(u8, "'a'"),
            .value = 'a',
        } },
        .{ .string = .{ .bytes = try allocator.dupe(u8, "probe") } },
        .{ .byte_array = .{ .items = try allocator.dupe(u8, &.{ 1, 2, 255 }) } },
        .{ .boolean = true },
    };
    for (literal_arms) |literal| {
        try table.append(allocator, .{
            .id = @intCast(table.items.len),
            .span = audit_span,
            .ty = null,
            .kind = .{ .literal = literal },
        });
    }

    const expr_count = table.items.len;
    try table.append(allocator, .{
        .id = @intCast(expr_count),
        .span = audit_span,
        .ty = null,
        .kind = .{
            .vec_lit = .{
                .elements = try allocator.dupe(exprs.NodeId, &.{0}),
                // The dynamic count: an expression node, not a held number.
                .repeat = .{ .expression = 1 },
            },
        },
    });
    try table.append(allocator, .{
        .id = @intCast(expr_count + 1),
        .span = audit_span,
        .ty = 0,
        .kind = .{ .path = .{
            .def = 5,
            .generic_args = try allocator.dupe(types.Type, &.{.{ .prim = .u32 }}),
        } },
    });
    // A labelled block that carries its own value: the label travels with the
    // block and the tail is a real node id, not unit.
    try table.append(allocator, .{
        .id = @intCast(expr_count + 2),
        .span = audit_span,
        .ty = null,
        .kind = .{ .block = .{
            .statements = try allocator.dupe(exprs.NodeId, &.{0}),
            .tail = 1,
            .labelled = try allocator.dupe(u8, "outer"),
        } },
    });
    try table.append(allocator, .{
        .id = @intCast(expr_count + 3),
        .span = audit_span,
        .ty = null,
        .kind = .unit,
    });
    try table.append(allocator, .{
        .id = @intCast(expr_count + 4),
        .span = audit_span,
        .ty = null,
        .kind = .{
            .if_else = .{
                .cond = 0,
                .then_ = .{
                    .statements = emptySlice(exprs.NodeId, allocator),
                    .tail = null,
                    .labelled = try allocator.dupe(u8, "then"),
                },
                // The `else` arm that owns a block, so its label is read back too.
                .@"else" = .{ .block = .{
                    .statements = try allocator.dupe(exprs.NodeId, &.{1}),
                    .tail = 0,
                    .labelled = try allocator.dupe(u8, "otherwise"),
                } },
            },
        },
    });
    // An `if` with no `else` at all, so the `.none` branch of `ElseBranch` is
    // exercised rather than inferred from the other two.
    try table.append(allocator, .{
        .id = @intCast(expr_count + 40),
        .span = audit_span,
        .ty = null,
        .kind = .{
            .if_else = .{
                .cond = 0,
                .then_ = .{
                    .statements = emptySlice(exprs.NodeId, allocator),
                    .tail = 1,
                    .labelled = null,
                },
                .@"else" = .none,
            },
        },
    });
    try table.append(allocator, .{
        .id = @intCast(expr_count + 5),
        .span = audit_span,
        .ty = null,
        .kind = .{
            .if_let = .{
                .pattern = 0,
                .scrutinee = 1,
                .then_ = .{
                    .statements = emptySlice(exprs.NodeId, allocator),
                    .tail = 2,
                    .labelled = null,
                },
                // The `else` arm that names another if node.
                .@"else" = .{ .chain = 2 },
            },
        },
    });
    try table.append(allocator, .{
        .id = @intCast(expr_count + 6),
        .span = audit_span,
        .ty = null,
        .kind = .{ .match = .{
            .scrutinee = 0,
            .arms = try allocator.dupe(exprs.MatchArm, &.{
                .{ .patterns = try allocator.dupe(exprs.NodeId, &.{ 0, 1 }), .guard = 2, .body = 3 },
                .{ .patterns = try allocator.dupe(exprs.NodeId, &.{2}), .guard = null, .body = 0 },
            }),
            .option_scrutinee = true,
        } },
    });
    try table.append(allocator, .{
        .id = @intCast(expr_count + 7),
        .span = audit_span,
        .ty = null,
        .kind = .{ .loop_ = .{ .body = .{
            .statements = try allocator.dupe(exprs.NodeId, &.{0}),
            .tail = null,
            .labelled = try allocator.dupe(u8, "spin"),
        } } },
    });
    try table.append(allocator, .{
        .id = @intCast(expr_count + 8),
        .span = audit_span,
        .ty = null,
        .kind = .{
            .while_ = .{
                .cond = 0,
                .body = .{
                    .statements = emptySlice(exprs.NodeId, allocator),
                    .tail = 1,
                    .labelled = null,
                },
                // The optional pattern capture, which must not read back as null.
                .capture = 2,
            },
        },
    });
    // Every IterKind arm, so a `for` over a chain survives the wire too.
    const multi = try allocator.dupe(exprs.NodeId, &.{ 0, 1 });
    const iter_kinds = [_]exprs.IterKind{
        .{ .range = {} },
        .{ .slice = {} },
        .{ .enumerate = {} },
        .{ .multi = multi },
        .{
            .adapter = .{
                .source = 0,
                .adapters = try auditIteratorAdapters(allocator),
                // The third terminal: `collect_vec` rides the standalone chain
                // above, so each spelling is written and read back once.
                .terminal = .sum,
            },
        },
    };
    for (iter_kinds, 0..) |iter_kind, index| {
        try table.append(allocator, .{
            .id = @intCast(expr_count + 9 + index),
            .span = audit_span,
            .ty = null,
            .kind = .{ .for_ = .{
                .pattern = 0,
                .iterable = 1,
                .body = .{
                    .statements = emptySlice(exprs.NodeId, allocator),
                    .tail = 2,
                    .labelled = null,
                },
                .iter_kind = iter_kind,
            } },
        });
    }
    const labelled_break = table.items.len;
    try table.append(allocator, .{
        .id = @intCast(labelled_break),
        .span = audit_span,
        .ty = null,
        // Both optional fields set: a break with a label AND a value.
        .kind = .{ .break_ = .{
            .label = try allocator.dupe(u8, "outer"),
            .value = 0,
        } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 1),
        .span = audit_span,
        .ty = null,
        .kind = .{ .break_ = .{ .label = null, .value = null } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 2),
        .span = audit_span,
        .ty = null,
        .kind = .{ .continue_ = .{ .label = try allocator.dupe(u8, "outer") } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 3),
        .span = audit_span,
        .ty = null,
        // Every CallKind arm in turn; all three carry a def id.
        .kind = .{ .call = .{
            .call_kind = .{ .constructor = 9 },
            .args = try allocator.dupe(exprs.NodeId, &.{ 0, 1, 2 }),
        } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 4),
        .span = audit_span,
        .ty = null,
        .kind = .{ .call = .{
            .call_kind = .{ .free = 1 },
            .args = emptySlice(exprs.NodeId, allocator),
        } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 5),
        .span = audit_span,
        .ty = null,
        .kind = .{ .call = .{
            .call_kind = .{ .associated = 2 },
            .args = try allocator.dupe(exprs.NodeId, &.{0}),
        } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 6),
        .span = audit_span,
        .ty = null,
        .kind = .{
            .method_call = .{
                .receiver = 0,
                // The receiver mode that is not the default `value`.
                .receiver_mode = .mutable,
                .method = 3,
                .args = try allocator.dupe(exprs.NodeId, &.{1}),
            },
        },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 7),
        .span = audit_span,
        .ty = null,
        .kind = .{
            .struct_lit = .{
                .def = 4,
                .fields = try allocator.dupe(exprs.FieldInit, &.{
                    // Shorthand and non-shorthand in one list, so the flag is read.
                    .{ .field = try allocator.dupe(u8, "x"), .value = 0, .shorthand = true },
                    .{ .field = try allocator.dupe(u8, "y"), .value = 1, .shorthand = false },
                }),
                // The deferred `..base` edge, which must not read back as null.
                .base = 2,
            },
        },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 8),
        .span = audit_span,
        .ty = null,
        .kind = .{ .enum_variant = .{
            .def = 5,
            .variant = try allocator.dupe(u8, "Probe"),
            .tuple_fields = try allocator.dupe(exprs.NodeId, &.{0}),
            .named_fields = try allocator.dupe(exprs.FieldInit, &.{
                .{ .field = try allocator.dupe(u8, "z"), .value = 2, .shorthand = false },
            }),
        } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 9),
        .span = audit_span,
        .ty = null,
        .kind = .{ .field = .{ .base = 0, .field = try allocator.dupe(u8, "x"), .resolved = 6 } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 10),
        .span = audit_span,
        .ty = null,
        .kind = .{ .index = .{ .base = 0, .index = 1 } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 11),
        .span = audit_span,
        .ty = null,
        // The operator and overflow pairs that are not the defaults.
        .kind = .{ .binary = .{
            .op = .boolean_or,
            .overflow = .saturating,
            .lhs = 0,
            .rhs = 1,
        } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 12),
        .span = audit_span,
        .ty = null,
        .kind = .{ .unary = .{ .op = .{ .ref = .shared }, .operand = 0 } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 13),
        .span = audit_span,
        .ty = null,
        .kind = .{ .unary = .{ .op = .deref, .operand = 0 } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 14),
        .span = audit_span,
        .ty = null,
        .kind = .{ .assign = .{
            .target = 0,
            .op = .shl,
            .value = 1,
            .overflow = .wrapping,
        } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 15),
        .span = audit_span,
        .ty = null,
        .kind = .{ .try_ = .{ .inner = 0 } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 16),
        .span = audit_span,
        .ty = null,
        .kind = .{ .return_ = .{ .value = 0 } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 17),
        .span = audit_span,
        .ty = null,
        .kind = .{ .return_ = .{ .value = null } },
    });
    // A closure: every field it declares, including a capture whose name the
    // decoder has to own and a body block with its own label.
    // One capture per `CaptureMode`, so each mode's wire spelling is read back
    // rather than the one the fixture happened to pick.
    const closure_captures = try allocator.alloc(exprs.Capture, 3);
    inline for (.{
        exprs.CaptureMode.by_value,
        exprs.CaptureMode.by_ref,
        exprs.CaptureMode.by_mut_ref,
    }, 0..) |mode, index| {
        closure_captures[index] = .{
            .name = try allocator.dupe(u8, "acc"),
            .mode = mode,
            .ty = 3,
        };
    }
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 18),
        .span = audit_span,
        .ty = null,
        .kind = .{ .closure = .{
            .captures = closure_captures,
            .params = try allocator.dupe(exprs.NodeId, &.{ 0, 1 }),
            .return_ty = 4,
            .body = .{
                .statements = try allocator.dupe(exprs.NodeId, &.{2}),
                .tail = 3,
                .labelled = try allocator.dupe(u8, "mapped"),
            },
            .trait = .fn_mut,
        } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 19),
        .span = audit_span,
        .ty = null,
        .kind = .{ .closure = .{
            .captures = emptySlice(exprs.Capture, allocator),
            .params = emptySlice(exprs.NodeId, allocator),
            .return_ty = null,
            .body = .{
                .statements = emptySlice(exprs.NodeId, allocator),
                .tail = null,
                .labelled = null,
            },
            .trait = .@"fn",
        } },
    });
    // A standalone iterator chain: every adapter arm, including the `other`
    // refusal, whose owned reason string has to survive. The terminal is the
    // one a defaulted decode would not produce, so a chain written without the
    // field on the wire fails here instead of passing as a bare iterator.
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 20),
        .span = audit_span,
        .ty = null,
        .kind = .{ .iterator_chain = .{
            .source = 0,
            .adapters = try auditIteratorAdapters(allocator),
            .terminal = .collect_vec,
        } },
    });
    // The explicit refusal: both of its fields, with the version that is not
    // the one `ts_ext` defaults to.
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 21),
        .span = audit_span,
        .ty = null,
        .kind = .{ .unsupported = .{
            .reason = try allocator.dupe(u8, "proc macro"),
            .suggested_version = .v2,
        } },
    });

    // The arms the model gained after the codec was written. Each is set to a
    // payload a defaulted decode would not produce, so a decoder that drops
    // the payload fails here instead of passing on a defaulted row.
    // `[a, b, c]` with a held repeat count, plus the list form whose count is
    // the element count and therefore absent.
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 22),
        .span = audit_span,
        .ty = null,
        .kind = .{ .array = .{
            .elements = try allocator.dupe(exprs.NodeId, &.{ 0, 1 }),
            .repeat = 4,
        } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 23),
        .span = audit_span,
        .ty = null,
        .kind = .{ .array = .{
            .elements = try allocator.dupe(exprs.NodeId, &.{0}),
            .repeat = null,
        } },
    });
    // A bounded inclusive range, then an open-ended one, so the absent end is
    // read back as null instead of a fabricated node id.
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 24),
        .span = audit_span,
        .ty = null,
        .kind = .{ .range = .{ .start = 0, .end = 1, .inclusive = true } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 25),
        .span = audit_span,
        .ty = null,
        .kind = .{ .range = .{ .start = 2, .end = null, .inclusive = false } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 26),
        .span = audit_span,
        .ty = null,
        .kind = .{ .panic_ = .{ .message = try allocator.dupe(u8, "index out of range") } },
    });
    // A core call and a core function item: the same core function name read
    // twice through two different arms, each carrying its type arguments.
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 27),
        .span = audit_span,
        .ty = null,
        .kind = .{ .core_call = .{
            .function = .mem_size_of_val,
            .generic_args = try allocator.dupe(types.Type, &.{.{ .prim = .u32 }}),
            .args = try allocator.dupe(exprs.NodeId, &.{0}),
        } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 28),
        .span = audit_span,
        .ty = null,
        .kind = .{ .core_function = .{
            .function = .mem_size_of_val,
            .generic_args = try allocator.dupe(types.Type, &.{.{ .prim = .u32 }}),
        } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 29),
        .span = audit_span,
        .ty = null,
        .kind = .{ .external_variant = .{
            .owner = .{
                .path = try allocator.dupe([]const u8, &.{ "core", "option", "Option" }),
                .args = try allocator.dupe(types.Type, &.{.{ .prim = .u8 }}),
            },
            .variant = try allocator.dupe(u8, "Some"),
            .tuple_fields = try allocator.dupe(exprs.NodeId, &.{0}),
            .named_fields = try allocator.dupe(exprs.FieldInit, &.{
                .{ .field = try allocator.dupe(u8, "z"), .value = 2, .shorthand = false },
            }),
        } },
    });
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 30),
        .span = audit_span,
        .ty = null,
        .kind = .{ .format_write = .{
            .writer = 0,
            .template = try allocator.dupe(u8, "{} {}\n"),
            .args = try allocator.dupe(exprs.NodeId, &.{ 1, 2 }),
        } },
    });
    // The conversion that is not the default `as`: `primitive_from` writes a
    // different wire spelling and has to read back as the same conversion.
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 31),
        .span = audit_span,
        .ty = null,
        .kind = .{ .cast = .{
            .kind = .primitive_from,
            .operand = 0,
            .source_type = .{ .prim = .u64 },
            .target = 1,
        } },
    });
    // `value as u8` over a slice source: the composite source type has to
    // survive the wire, so it is allocator-owned like every other fixture row.
    const cast_source = try allocator.create(types.Slice);
    cast_source.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    try table.append(allocator, .{
        .id = @intCast(labelled_break + 32),
        .span = audit_span,
        .ty = null,
        .kind = .{ .cast = .{
            .kind = .as_,
            .operand = 1,
            .source_type = .{ .slice = cast_source },
            .target = 2,
        } },
    });

    return table.toOwnedSlice(allocator);
}

/// The seven `IteratorAdapter` arms, with the payload of each one that has
/// one set to something a defaulted decode would not produce.
fn auditIteratorAdapters(allocator: std.mem.Allocator) ![]const exprs.IteratorAdapter {
    // Every slice here is allocator-owned for the same reason the node fixture
    // rows are: one teardown releases each row, so a static slice beside a
    // heap one would be freed twice over.
    const map_closure: exprs.ClosureExpr = .{
        .captures = emptySlice(exprs.Capture, allocator),
        .params = emptySlice(exprs.NodeId, allocator),
        .return_ty = null,
        .body = .{
            .statements = emptySlice(exprs.NodeId, allocator),
            .tail = 0,
            .labelled = null,
        },
        .trait = .@"fn",
    };
    const filter_params = try allocator.dupe(exprs.NodeId, &.{1});
    const filter_closure: exprs.ClosureExpr = .{
        .captures = emptySlice(exprs.Capture, allocator),
        .params = filter_params,
        .return_ty = 1,
        .body = .{
            .statements = emptySlice(exprs.NodeId, allocator),
            .tail = 0,
            .labelled = null,
        },
        .trait = .fn_once,
    };
    // `flat_map` carries the closure directly, so it needs its own closure
    // value rather than the wrapped one `map` uses.
    const flat_map_params = try allocator.dupe(exprs.NodeId, &.{2});
    const flat_map_closure: exprs.ClosureExpr = .{
        .captures = emptySlice(exprs.Capture, allocator),
        .params = flat_map_params,
        .return_ty = 2,
        .body = .{
            .statements = emptySlice(exprs.NodeId, allocator),
            .tail = 1,
            .labelled = null,
        },
        .trait = .@"fn",
    };
    const adapters = try allocator.alloc(exprs.IteratorAdapter, 7);
    adapters[0] = .{ .map = .{ .closure = map_closure } };
    adapters[1] = .{ .filter = .{ .closure = filter_closure } };
    adapters[2] = .{ .flat_map = flat_map_closure };
    adapters[3] = .{ .enumerate = {} };
    adapters[4] = .{ .zip = .{ .other = 7 } };
    adapters[5] = .{ .range_rev = {} };
    adapters[6] = .{ .other = .{
        .reason = try allocator.dupe(u8, "needs v3"),
        .suggested_version = .v3,
    } };
    return adapters;
}

/// One statement row per `StatementKind` arm.
fn auditStatementTable(allocator: std.mem.Allocator) ![]const exprs.Statement {
    var table: std.ArrayListUnmanaged(exprs.Statement) = .empty;
    errdefer {
        for (table.items) |statement| freeDecodedStatement(allocator, statement);
        table.deinit(allocator);
    }
    try table.append(allocator, .{
        .id = 0,
        .span = audit_span,
        .ty = null,
        // Both optional fields set: an initialiser and an explicit type.
        .kind = .{ .let = .{ .pattern = 0, .init = 1, .ty = 2 } },
    });
    try table.append(allocator, .{
        .id = 1,
        .span = audit_span,
        .ty = null,
        // The uninitialised and untyped `let`, so the nulls read back null.
        .kind = .{ .let = .{ .pattern = 1, .init = null, .ty = null } },
    });
    try table.append(allocator, .{
        .id = 2,
        .span = audit_span,
        .ty = null,
        .kind = .{ .let_else = .{
            .pattern = 2,
            .init = 3,
            .else_block = .{
                .statements = try allocator.dupe(exprs.NodeId, &.{0}),
                .tail = 1,
                .labelled = try allocator.dupe(u8, "diverging"),
            },
        } },
    });
    try table.append(allocator, .{
        .id = 3,
        .span = audit_span,
        .ty = null,
        .kind = .{ .expr = 4 },
    });
    try table.append(allocator, .{
        .id = 4,
        .span = audit_span,
        .ty = null,
        .kind = .{ .item = 5 },
    });
    return table.toOwnedSlice(allocator);
}

/// One body row per `BodyKind` arm, with the optional and defaulted fields of
/// each set away from their defaults.
fn auditBodyTable(allocator: std.mem.Allocator) ![]const BodyKind {
    var table: std.ArrayListUnmanaged(BodyKind) = .empty;
    errdefer {
        for (table.items) |body| freeDecodedBodyKind(allocator, body);
        table.deinit(allocator);
    }

    try table.append(allocator, .none);
    // A `Result` payload, so a const body whose type is a pointer-carrying arm
    // is checked for a flattened (and so wrong) decode.
    const const_result = try allocator.create(types.Result);
    const_result.* = .{
        .ok = .{ .prim = .u8 },
        .err = .{ .prim = .u16 },
        .is_error_unionable = true,
    };
    try table.append(allocator, .{ .const_ = .{
        .ty = .{ .result = const_result },
        .init = 0,
    } });

    const parameter_type = try allocator.create(types.Type);
    parameter_type.* = .{ .prim = .usize };
    const parameters = try allocator.alloc(items.Param, 1);
    parameters[0] = .{
        .name = try allocator.dupe(u8, "input"),
        // A nested type, so a decoder that flattens the pointer fails.
        .ty = .{ .option = parameter_type },
        .span = audit_span,
    };
    try table.append(allocator, .{
        .fn_ = .{
            .params = parameters,
            .ret = .{ .prim = .bool },
            // Non-empty generic params, and the flag that defaults to false.
            .generic_params = try allocator.dupe([]const u8, &.{"T"}),
            .body = 1,
            .is_allocating = true,
        },
    });

    // A struct whose fields carry their own visibility and span, and whose
    // methods carry a receiver mode and the same allocation flag.
    // The field-slot binding type: the type a binding of this field is declared
    // with. It has to reach the wire, or a field binding reads back with a
    // type the declaration never said.
    const slot_type = try allocator.create(types.Type);
    slot_type.* = .{ .prim = .u32 };
    const struct_fields = try allocator.alloc(items.Field, 1);
    struct_fields[0] = .{
        .name = try allocator.dupe(u8, "slot"),
        .ty = .{ .boxed = slot_type },
        .visibility = .{ .in_path = try allocator.dupe(u8, "crate::field") },
        .span = audit_span,
    };
    const struct_methods = try allocator.alloc(StructMethod, 1);
    struct_methods[0] = .{
        .name = try allocator.dupe(u8, "method"),
        .visibility = .private,
        .params = emptySlice(items.Param, allocator),
        .ret = .{ .prim = .i8 },
        .generic_params = emptySlice([]const u8, allocator),
        .body = 2,
        .receiver = .mut_ref,
        .is_allocating = true,
    };
    try table.append(allocator, .{
        .struct_ = .{
            .generic_params = try allocator.dupe([]const u8, &.{"T"}),
            .trait_bounds = try allocator.dupe([]const u8, &.{"Clone"}),
            // The layout arm that is not `named`.
            .layout = .tuple,
            .fields = struct_fields,
            .methods = struct_methods,
            .has_dynamic_resources = true,
        },
    });

    const variant_tuple_types = try allocator.dupe(types.Type, &.{.{ .prim = .f32 }});
    const enum_variants = try allocator.alloc(items.Variant, 3);
    enum_variants[0] = .{
        .name = try allocator.dupe(u8, "Unit"),
        .fields = .none,
        .discriminant = null,
    };
    enum_variants[1] = .{
        .name = try allocator.dupe(u8, "Tup"),
        .fields = .{ .tuple = variant_tuple_types },
        .discriminant = 3,
    };
    const variant_named_fields = try allocator.alloc(items.Field, 1);
    variant_named_fields[0] = .{
        .name = try allocator.dupe(u8, "named"),
        .ty = .{ .prim = .char },
        .visibility = .crate_restricted,
        .span = audit_span,
    };
    enum_variants[2] = .{
        .name = try allocator.dupe(u8, "Named"),
        .fields = .{ .named = variant_named_fields },
        .discriminant = -4,
    };
    try table.append(allocator, .{
        .enum_ = .{
            // The kind that is not the `c_like` default.
            .kind = .mixed,
            .variants = enum_variants,
            .repr_int = .i128,
            .non_exhaustive = true,
        },
    });

    const trait_methods = try allocator.alloc(TraitMethodSig, 1);
    trait_methods[0] = .{
        .name = try allocator.dupe(u8, "required"),
        .params = emptySlice(items.Param, allocator),
        .ret = .{ .prim = .u64 },
        // The receiver mode that is not the `ref_` default.
        .receiver = .owned,
    };
    try table.append(allocator, .{ .trait_ = .{
        .name = try allocator.dupe(u8, "Probe"),
        .supertraits = try allocator.dupe([]const u8, &.{"Base"}),
        .methods = trait_methods,
    } });

    try table.append(allocator, .{ .type_alias = .{ .target = .{
        .generic_inst = .{
            .decl = 42,
            .args = .{ .params = try allocator.dupe(types.Type, &.{.{ .prim = .i16 }}) },
        },
    } } });

    return table.toOwnedSlice(allocator);
}

/// Mark which arms of `tag_type` appear in `rows`, alongside the arm names so an
/// uncovered arm can be reported by name rather than by index.
fn Arms(comptime tag_type: type) type {
    return struct {
        const field_names = switch (@typeInfo(tag_type)) {
            .@"enum" => |info| info.field_names,
            .@"union" => |info| info.field_names,
            else => @compileError("expected an enum or tagged union"),
        };
        seen: [field_names.len]bool = @splat(false),

        /// Mark an arm by its tag. `tag_type` is a tagged union or a plain
        /// enum — both answer `@intFromEnum` on their active tag — so the two
        /// kinds of node tag and of plain discriminator share this helper.
        fn mark(self: *@This(), tag: anytype) void {
            self.seen[@backingInt(tag)] = true;
        }

        /// Report, by name, every arm the fixture did not exercise.
        fn expectComplete(self: *const @This(), comptime label: []const u8) !void {
            inline for (field_names, 0..) |name, tag| {
                if (!self.seen[tag]) {
                    std.debug.print(
                        "arm `{s}` of {s} is not exercised by the round-trip audit\n",
                        .{ name, label },
                    );
                    return error.ArmNotCovered;
                }
            }
        }
    };
}

/// The coverage gate for every union the wire carries. An arm added to the
/// model after this fixture was written leaves one arm unexercised here and
/// the test fails naming that arm — rather than the new shape crossing the
/// wire with nothing on either side of it proving it survives.
fn expectEveryArmCovered(
    expressions: []const exprs.Expr,
    statements: []const exprs.Statement,
    patterns: []const exprs.Pattern,
    type_table: []const types.Type,
    bodies: []const BodyKind,
) !void {
    var expr_arms = Arms(exprs.ExprKind){};
    var statement_arms = Arms(exprs.StatementKind){};
    var pattern_arms = Arms(exprs.PatternKind){};
    var type_arms = Arms(types.Type){};
    var body_arms = Arms(BodyKind){};
    var literal_arms = Arms(exprs.Literal){};
    var iter_kind_arms = Arms(exprs.IterKind){};
    var adapter_arms = Arms(exprs.IteratorAdapter){};
    var else_arms = Arms(exprs.ElseBranch){};
    var trait_arms = Arms(exprs.ClosureTrait){};
    var capture_mode_arms = Arms(exprs.CaptureMode){};
    var bind_mode_arms = Arms(exprs.BindMode){};

    for (expressions) |row| {
        expr_arms.mark(std.meta.activeTag(row.kind));
        switch (row.kind) {
            .literal => |literal| literal_arms.mark(std.meta.activeTag(literal)),
            .if_else => |branch| else_arms.mark(std.meta.activeTag(branch.@"else")),
            .if_let => |branch| else_arms.mark(std.meta.activeTag(branch.@"else")),
            .for_ => |for_expr| {
                iter_kind_arms.mark(std.meta.activeTag(for_expr.iter_kind));
                switch (for_expr.iter_kind) {
                    .adapter => |chain| markAdapters(chain, &adapter_arms, &trait_arms),
                    else => {},
                }
            },
            .iterator_chain => |chain| markAdapters(chain, &adapter_arms, &trait_arms),
            .closure => |closure| {
                trait_arms.mark(closure.trait);
                for (closure.captures) |capture| capture_mode_arms.mark(capture.mode);
            },
            else => {},
        }
    }
    for (statements) |row| statement_arms.mark(std.meta.activeTag(row.kind));
    for (patterns) |row| {
        pattern_arms.mark(std.meta.activeTag(row.kind));
        switch (row.kind) {
            .literal => |literal| literal_arms.mark(std.meta.activeTag(literal)),
            .binding => |binding| bind_mode_arms.mark(std.meta.activeTag(binding.mode)),
            .reference => |reference| bind_mode_arms.mark(std.meta.activeTag(reference.mode)),
            else => {},
        }
    }
    for (type_table) |ty| type_arms.mark(std.meta.activeTag(ty));
    for (bodies) |body| body_arms.mark(std.meta.activeTag(body));

    try expr_arms.expectComplete("exprs.ExprKind");
    try statement_arms.expectComplete("exprs.StatementKind");
    try pattern_arms.expectComplete("exprs.PatternKind");
    try type_arms.expectComplete("types.Type");
    try body_arms.expectComplete("BodyKind");
    try literal_arms.expectComplete("exprs.Literal");
    try iter_kind_arms.expectComplete("exprs.IterKind");
    try adapter_arms.expectComplete("exprs.IteratorAdapter");
    try else_arms.expectComplete("exprs.ElseBranch");
    try trait_arms.expectComplete("exprs.ClosureTrait");
    try capture_mode_arms.expectComplete("exprs.CaptureMode");
    try bind_mode_arms.expectComplete("exprs.BindMode");
}

/// Mark every adapter arm a chain reaches, and the closure traits its `map`,
/// `filter` and `flat_map` adapters close as.
fn markAdapters(
    chain: exprs.IteratorChainExpr,
    adapter_arms: *Arms(exprs.IteratorAdapter),
    trait_arms: *Arms(exprs.ClosureTrait),
) void {
    for (chain.adapters) |adapter| {
        adapter_arms.mark(std.meta.activeTag(adapter));
        switch (adapter) {
            .map => |map| trait_arms.mark(map.closure.trait),
            .filter => |filter| trait_arms.mark(filter.closure.trait),
            .flat_map => |closure| trait_arms.mark(closure.trait),
            else => {},
        }
    }
}

/// Assert that every decoded row matches the one that was encoded, field by
/// field. A row the codec cannot describe is a decode error before this runs;
/// a field it cannot read is a mismatch here.
fn expectDecodedExprsMatch(
    encoded: []const exprs.Expr,
    decoded: []const exprs.Expr,
) !void {
    try std.testing.expectEqual(encoded.len, decoded.len);
    for (encoded, decoded) |before, after| {
        try std.testing.expectEqual(before.id, after.id);
        try std.testing.expectEqual(before.span, after.span);
        try std.testing.expectEqual(before.ty, after.ty);
        try expectDecodedExprKindMatches(before.kind, after.kind);
    }
}

fn expectDecodedBlockMatches(
    before: exprs.BlockExpr,
    after: exprs.BlockExpr,
) !void {
    try std.testing.expectEqualSlices(exprs.NodeId, before.statements, after.statements);
    try std.testing.expectEqual(before.tail, after.tail);
    if (before.labelled) |label| {
        try std.testing.expectEqualStrings(label, after.labelled orelse return error.LostLabel);
    } else {
        try std.testing.expect(after.labelled == null);
    }
}

fn expectDecodedLiteralMatches(before: exprs.Literal, after: exprs.Literal) !void {
    if (std.meta.activeTag(before) != std.meta.activeTag(after)) {
        return error.LiteralArmMismatch;
    }
    switch (before) {
        .int => |literal| {
            try std.testing.expectEqualStrings(literal.text, after.int.text);
            try std.testing.expectEqual(literal.value, after.int.value);
            try std.testing.expectEqual(literal.base, after.int.base);
            if (literal.ty_suffix) |suffix| {
                try std.testing.expectEqualStrings(
                    suffix,
                    after.int.ty_suffix orelse return error.LostLiteralSuffix,
                );
            } else {
                try std.testing.expect(after.int.ty_suffix == null);
            }
        },
        .float => |literal| {
            try std.testing.expectEqualStrings(literal.text, after.float.text);
            try std.testing.expectEqual(literal.value, after.float.value);
        },
        .character => |literal| {
            try std.testing.expectEqualStrings(literal.text, after.character.text);
            try std.testing.expectEqual(literal.value, after.character.value);
        },
        .string => |literal| try std.testing.expectEqualStrings(literal.bytes, after.string.bytes),
        .byte_array => |literal| {
            try std.testing.expectEqualSlices(u8, literal.items, after.byte_array.items);
        },
        .boolean => |value| try std.testing.expectEqual(value, after.boolean),
    }
}

fn expectDecodedClosureMatches(
    before: exprs.ClosureExpr,
    after: exprs.ClosureExpr,
) !void {
    try std.testing.expectEqual(before.captures.len, after.captures.len);
    for (before.captures, after.captures) |expected, actual| {
        try std.testing.expectEqualStrings(expected.name, actual.name);
        try std.testing.expectEqual(expected.mode, actual.mode);
        try std.testing.expectEqual(expected.ty, actual.ty);
    }
    try std.testing.expectEqualSlices(exprs.NodeId, before.params, after.params);
    try std.testing.expectEqual(before.return_ty, after.return_ty);
    try expectDecodedBlockMatches(before.body, after.body);
    try std.testing.expectEqual(before.trait, after.trait);
}

fn expectDecodedAdapterMatches(
    before: exprs.IteratorAdapter,
    after: exprs.IteratorAdapter,
) !void {
    if (std.meta.activeTag(before) != std.meta.activeTag(after)) {
        return error.AdapterArmMismatch;
    }
    switch (before) {
        .map => |adapter| try expectDecodedClosureMatches(adapter.closure, after.map.closure),
        .filter => |adapter| try expectDecodedClosureMatches(adapter.closure, after.filter.closure),
        .flat_map => |adapter| try expectDecodedClosureMatches(adapter, after.flat_map),
        .enumerate => {},
        .zip => |adapter| try std.testing.expectEqual(adapter.other, after.zip.other),
        .range_rev => {},
        .other => |adapter| {
            try std.testing.expectEqualStrings(adapter.reason, after.other.reason);
            try std.testing.expectEqual(
                adapter.suggested_version,
                after.other.suggested_version,
            );
        },
    }
}

fn expectDecodedChainMatches(
    before: exprs.IteratorChainExpr,
    after: exprs.IteratorChainExpr,
) !void {
    try std.testing.expectEqual(before.source, after.source);
    try std.testing.expectEqual(before.terminal, after.terminal);
    try std.testing.expectEqual(before.adapters.len, after.adapters.len);
    for (before.adapters, after.adapters) |expected, actual| {
        try expectDecodedAdapterMatches(expected, actual);
    }
}

fn expectDecodedElseMatches(
    before: exprs.ElseBranch,
    after: exprs.ElseBranch,
) !void {
    if (std.meta.activeTag(before) != std.meta.activeTag(after)) {
        return error.ElseArmMismatch;
    }
    switch (before) {
        .none => {},
        .chain => |id| try std.testing.expectEqual(id, after.chain),
        .block => |block| try expectDecodedBlockMatches(block, after.block),
    }
}

fn expectDecodedFieldInitMatches(
    before: []const exprs.FieldInit,
    after: []const exprs.FieldInit,
) !void {
    try std.testing.expectEqual(before.len, after.len);
    for (before, after) |expected, actual| {
        try std.testing.expectEqualStrings(expected.field, actual.field);
        try std.testing.expectEqual(expected.value, actual.value);
        try std.testing.expectEqual(expected.shorthand, actual.shorthand);
    }
}

fn expectDecodedExprKindMatches(
    before: exprs.ExprKind,
    after: exprs.ExprKind,
) !void {
    if (std.meta.activeTag(before) != std.meta.activeTag(after)) {
        return error.ExprKindArmMismatch;
    }
    switch (before) {
        .literal => |literal| try expectDecodedLiteralMatches(literal, after.literal),
        .vec_lit => |vector| {
            try std.testing.expectEqualSlices(exprs.NodeId, vector.elements, after.vec_lit.elements);
            try std.testing.expectEqual(vector.repeat, after.vec_lit.repeat);
        },
        .array => |array| {
            try std.testing.expectEqualSlices(exprs.NodeId, array.elements, after.array.elements);
            try std.testing.expectEqual(array.repeat, after.array.repeat);
        },
        .range => |range_expr| {
            try std.testing.expectEqual(range_expr.start, after.range.start);
            try std.testing.expectEqual(range_expr.end, after.range.end);
            try std.testing.expectEqual(range_expr.inclusive, after.range.inclusive);
        },
        .panic_ => |panic_expr| try std.testing.expectEqualStrings(
            panic_expr.message,
            after.panic_.message,
        ),
        .path => |path| {
            try std.testing.expectEqual(path.def, after.path.def);
            try std.testing.expectEqual(
                path.generic_args.len,
                after.path.generic_args.len,
            );
        },
        .block => |block| try expectDecodedBlockMatches(block, after.block),
        .unit => {},
        .if_else => |branch| {
            try std.testing.expectEqual(branch.cond, after.if_else.cond);
            try expectDecodedBlockMatches(branch.then_, after.if_else.then_);
            try expectDecodedElseMatches(branch.@"else", after.if_else.@"else");
        },
        .if_let => |branch| {
            try std.testing.expectEqual(branch.pattern, after.if_let.pattern);
            try std.testing.expectEqual(branch.scrutinee, after.if_let.scrutinee);
            try expectDecodedBlockMatches(branch.then_, after.if_let.then_);
            try expectDecodedElseMatches(branch.@"else", after.if_let.@"else");
        },
        .match => |match_expr| {
            try std.testing.expectEqual(match_expr.scrutinee, after.match.scrutinee);
            try std.testing.expectEqual(match_expr.option_scrutinee, after.match.option_scrutinee);
            try std.testing.expectEqual(match_expr.arms.len, after.match.arms.len);
            for (match_expr.arms, after.match.arms) |expected, actual| {
                try std.testing.expectEqualSlices(exprs.NodeId, expected.patterns, actual.patterns);
                try std.testing.expectEqual(expected.guard, actual.guard);
                try std.testing.expectEqual(expected.body, actual.body);
            }
        },
        .loop_ => |loop_expr| try expectDecodedBlockMatches(
            loop_expr.body,
            after.loop_.body,
        ),
        .while_ => |while_expr| {
            try std.testing.expectEqual(while_expr.cond, after.while_.cond);
            try std.testing.expectEqual(while_expr.capture, after.while_.capture);
            try expectDecodedBlockMatches(while_expr.body, after.while_.body);
        },
        .for_ => |for_expr| {
            try std.testing.expectEqual(for_expr.pattern, after.for_.pattern);
            try std.testing.expectEqual(for_expr.iterable, after.for_.iterable);
            try expectDecodedBlockMatches(for_expr.body, after.for_.body);
            switch (for_expr.iter_kind) {
                .range => try std.testing.expect(after.for_.iter_kind == .range),
                .slice => try std.testing.expect(after.for_.iter_kind == .slice),
                .enumerate => try std.testing.expect(after.for_.iter_kind == .enumerate),
                .multi => |ids| try std.testing.expectEqualSlices(
                    exprs.NodeId,
                    ids,
                    after.for_.iter_kind.multi,
                ),
                .adapter => |chain| try expectDecodedChainMatches(
                    chain,
                    after.for_.iter_kind.adapter,
                ),
            }
        },
        .break_ => |break_expr| {
            try std.testing.expectEqual(break_expr.value, after.break_.value);
            if (break_expr.label) |label| {
                try std.testing.expectEqualStrings(
                    label,
                    after.break_.label orelse return error.LostBreakLabel,
                );
            } else {
                try std.testing.expect(after.break_.label == null);
            }
        },
        .continue_ => |continuation| {
            if (continuation.label) |label| {
                try std.testing.expectEqualStrings(
                    label,
                    after.continue_.label orelse return error.LostContinueLabel,
                );
            } else {
                try std.testing.expect(after.continue_.label == null);
            }
        },
        .call => |call| {
            try std.testing.expectEqualSlices(exprs.NodeId, call.args, after.call.args);
            if (std.meta.activeTag(call.call_kind) !=
                std.meta.activeTag(after.call.call_kind))
            {
                return error.CallKindArmMismatch;
            }
            switch (call.call_kind) {
                .free => |def| try std.testing.expectEqual(def, after.call.call_kind.free),
                .associated => |def| try std.testing.expectEqual(
                    def,
                    after.call.call_kind.associated,
                ),
                .constructor => |def| try std.testing.expectEqual(
                    def,
                    after.call.call_kind.constructor,
                ),
            }
        },
        .core_call => |core_call| {
            try std.testing.expectEqual(core_call.function, after.core_call.function);
            try expectTypeListsEqual(core_call.generic_args, after.core_call.generic_args);
            try std.testing.expectEqualSlices(
                exprs.NodeId,
                core_call.args,
                after.core_call.args,
            );
        },
        .core_function => |core_function| {
            try std.testing.expectEqual(core_function.function, after.core_function.function);
            try expectTypeListsEqual(
                core_function.generic_args,
                after.core_function.generic_args,
            );
        },
        .method_call => |method_call| {
            try std.testing.expectEqual(method_call.receiver, after.method_call.receiver);
            try std.testing.expectEqual(
                method_call.receiver_mode,
                after.method_call.receiver_mode,
            );
            try std.testing.expectEqual(method_call.method, after.method_call.method);
            try std.testing.expectEqualSlices(
                exprs.NodeId,
                method_call.args,
                after.method_call.args,
            );
        },
        .struct_lit => |struct_lit| {
            try std.testing.expectEqual(struct_lit.def, after.struct_lit.def);
            try std.testing.expectEqual(struct_lit.base, after.struct_lit.base);
            try expectDecodedFieldInitMatches(
                struct_lit.fields,
                after.struct_lit.fields,
            );
        },
        .enum_variant => |variant| {
            try std.testing.expectEqual(variant.def, after.enum_variant.def);
            try std.testing.expectEqualStrings(
                variant.variant,
                after.enum_variant.variant,
            );
            try std.testing.expectEqualSlices(
                exprs.NodeId,
                variant.tuple_fields,
                after.enum_variant.tuple_fields,
            );
            try expectDecodedFieldInitMatches(
                variant.named_fields,
                after.enum_variant.named_fields,
            );
        },
        .external_variant => |external| {
            try expectExternalNominalEquals(external.owner, after.external_variant.owner);
            try std.testing.expectEqualStrings(
                external.variant,
                after.external_variant.variant,
            );
            try std.testing.expectEqualSlices(
                exprs.NodeId,
                external.tuple_fields,
                after.external_variant.tuple_fields,
            );
            try expectDecodedFieldInitMatches(
                external.named_fields,
                after.external_variant.named_fields,
            );
        },
        .format_write => |format_write| {
            try std.testing.expectEqual(format_write.writer, after.format_write.writer);
            try std.testing.expectEqualStrings(
                format_write.template,
                after.format_write.template,
            );
            try std.testing.expectEqualSlices(
                exprs.NodeId,
                format_write.args,
                after.format_write.args,
            );
        },
        .field => |field| {
            try std.testing.expectEqual(field.base, after.field.base);
            try std.testing.expectEqualStrings(field.field, after.field.field);
            try std.testing.expectEqual(field.resolved, after.field.resolved);
        },
        .index => |index_expr| {
            try std.testing.expectEqual(index_expr.base, after.index.base);
            try std.testing.expectEqual(index_expr.index, after.index.index);
        },
        .cast => |cast| {
            try std.testing.expectEqual(cast.kind, after.cast.kind);
            try std.testing.expectEqual(cast.operand, after.cast.operand);
            try expectTypesEqual(cast.source_type, after.cast.source_type);
            try std.testing.expectEqual(cast.target, after.cast.target);
        },
        .binary => |binary| {
            try std.testing.expectEqual(binary.op, after.binary.op);
            try std.testing.expectEqual(binary.overflow, after.binary.overflow);
            try std.testing.expectEqual(binary.lhs, after.binary.lhs);
            try std.testing.expectEqual(binary.rhs, after.binary.rhs);
        },
        .unary => |unary| {
            try std.testing.expectEqual(unary.operand, after.unary.operand);
            switch (unary.op) {
                .ref => |mode| try std.testing.expectEqual(
                    mode,
                    after.unary.op.ref,
                ),
                else => try std.testing.expectEqual(unary.op, after.unary.op),
            }
        },
        .assign => |assign| {
            try std.testing.expectEqual(assign.target, after.assign.target);
            try std.testing.expectEqual(assign.op, after.assign.op);
            try std.testing.expectEqual(assign.value, after.assign.value);
            try std.testing.expectEqual(assign.overflow, after.assign.overflow);
        },
        .try_ => |try_expr| try std.testing.expectEqual(
            try_expr.inner,
            after.try_.inner,
        ),
        .return_ => |return_expr| try std.testing.expectEqual(
            return_expr.value,
            after.return_.value,
        ),
        .closure => |closure| try expectDecodedClosureMatches(
            closure,
            after.closure,
        ),
        .iterator_chain => |chain| try expectDecodedChainMatches(
            chain,
            after.iterator_chain,
        ),
        .unsupported => |unsupported| {
            try std.testing.expectEqualStrings(
                unsupported.reason,
                after.unsupported.reason,
            );
            try std.testing.expectEqual(
                unsupported.suggested_version,
                after.unsupported.suggested_version,
            );
        },
    }
}

/// The errors this structural-comparison group can return. These helpers are
/// mutually recursive over `types.Type`, so an inferred error set cannot be
/// resolved; naming it breaks the cycle the same way the codec above does.
/// It is exactly what `std.testing` assertions produce, not `anyerror`.
const TypeCompareError = error{ TestExpectedEqual, TestUnexpectedResult };

/// An external nominal's Rust path is provenance, so it is compared segment
/// by segment rather than by last name alone.
fn expectExternalNominalEquals(
    before: types.ExternalNominal,
    after: types.ExternalNominal,
) TypeCompareError!void {
    try std.testing.expectEqual(before.path.len, after.path.len);
    for (before.path, after.path) |segment, decoded_segment| {
        try std.testing.expectEqualStrings(segment, decoded_segment);
    }
    try expectTypeListsEqual(before.args, after.args);
}

fn expectBoundsEqual(
    before: []const types.Bound,
    after: []const types.Bound,
) TypeCompareError!void {
    try std.testing.expectEqual(before.len, after.len);
    for (before, after) |bound, decoded_bound| {
        try std.testing.expectEqual(bound.optional, decoded_bound.optional);
        try std.testing.expectEqual(
            bound.path.segments.len,
            decoded_bound.path.segments.len,
        );
        for (bound.path.segments, decoded_bound.path.segments) |segment, decoded_segment| {
            try std.testing.expectEqualStrings(segment.name, decoded_segment.name);
            try std.testing.expectEqual(segment.id, decoded_segment.id);
        }
        try expectTypeListsEqual(bound.args, decoded_bound.args);
        try std.testing.expectEqual(
            bound.associated_types.len,
            decoded_bound.associated_types.len,
        );
        for (bound.associated_types, decoded_bound.associated_types) |
            binding,
            decoded_binding,
        | {
            try std.testing.expectEqualStrings(binding.name, decoded_binding.name);
            try expectTypesEqual(binding.ty, decoded_binding.ty);
        }
    }
}

/// Compare two `types.Type` values structurally. A decoded type owns fresh
/// slices at different addresses from the encoded one, so pointer equality is
/// the wrong question at every depth a type nests.
fn expectTypesEqual(before: types.Type, after: types.Type) TypeCompareError!void {
    try std.testing.expectEqual(std.meta.activeTag(before), std.meta.activeTag(after));
    switch (before) {
        .path => |path| {
            try std.testing.expectEqual(path.segments.len, after.path.segments.len);
            for (path.segments, after.path.segments) |segment, decoded_segment| {
                try std.testing.expectEqualStrings(segment.name, decoded_segment.name);
                try std.testing.expectEqual(segment.id, decoded_segment.id);
            }
        },
        .external_nominal => |external| try expectExternalNominalEquals(
            external,
            after.external_nominal,
        ),
        .prim => |prim| try std.testing.expectEqual(prim, after.prim),
        .reference => |reference| {
            try std.testing.expectEqual(reference.mut, after.reference.mut);
            try expectTypesEqual(reference.pointee, after.reference.pointee);
        },
        .raw_ptr => |raw_ptr| {
            try std.testing.expectEqual(raw_ptr.mut, after.raw_ptr.mut);
            try expectTypesEqual(raw_ptr.pointee, after.raw_ptr.pointee);
        },
        .slice => |slice| {
            try std.testing.expectEqual(slice.const_, after.slice.const_);
            try expectTypesEqual(slice.elem, after.slice.elem);
        },
        .array => |array| {
            try expectTypesEqual(array.elem, after.array.elem);
            try std.testing.expectEqual(array.len, after.array.len);
        },
        .tuple => |tuple| {
            try std.testing.expectEqual(tuple.len, after.tuple.len);
            for (tuple, after.tuple) |element, decoded_element| {
                try expectTypesEqual(element, decoded_element);
            }
        },
        .fn_ptr => |fn_ptr| {
            try std.testing.expectEqual(fn_ptr.params.len, after.fn_ptr.params.len);
            for (fn_ptr.params, after.fn_ptr.params) |param, decoded_param| {
                try expectTypesEqual(param, decoded_param);
            }
            try expectTypesEqual(fn_ptr.ret, after.fn_ptr.ret);
        },
        .generic_inst => |generic_inst| {
            try std.testing.expectEqual(generic_inst.decl, after.generic_inst.decl);
            try std.testing.expectEqual(
                generic_inst.args.params.len,
                after.generic_inst.args.params.len,
            );
            for (generic_inst.args.params, after.generic_inst.args.params) |
                arg,
                decoded_arg,
            | {
                try expectTypesEqual(arg, decoded_arg);
            }
        },
        .option => |option| try expectTypesEqual(option.*, after.option.*),
        .result => |result| {
            try expectTypesEqual(result.ok, after.result.ok);
            try expectTypesEqual(result.err, after.result.err);
            try std.testing.expectEqual(
                result.is_error_unionable,
                after.result.is_error_unionable,
            );
        },
        .boxed => |boxed| try expectTypesEqual(boxed.*, after.boxed.*),
        .@"opaque" => |opaque_ty| {
            try expectBoundsEqual(opaque_ty.bounds, after.@"opaque".bounds);
            if (opaque_ty.concrete) |concrete| {
                try expectTypesEqual(concrete.*, after.@"opaque".concrete.?.*);
            } else {
                try std.testing.expect(after.@"opaque".concrete == null);
            }
        },
        .dyn_trait => |bounds| try expectBoundsEqual(bounds, after.dyn_trait),
        .unsupported => |unsupported| {
            try std.testing.expectEqual(
                unsupported.reason,
                after.unsupported.reason,
            );
            try std.testing.expectEqualStrings(
                unsupported.message,
                after.unsupported.message,
            );
            try std.testing.expectEqual(unsupported.span, after.unsupported.span);
        },
    }
}

fn expectTypeListsEqual(
    before: []const types.Type,
    after: []const types.Type,
) TypeCompareError!void {
    try std.testing.expectEqual(before.len, after.len);
    for (before, after) |element, decoded_element| {
        try expectTypesEqual(element, decoded_element);
    }
}

fn expectDecodedTypesMatch(
    before: []const types.Type,
    after: []const types.Type,
) !void {
    try expectTypeListsEqual(before, after);
}

fn expectDecodedPatternsMatch(
    before: []const exprs.Pattern,
    after: []const exprs.Pattern,
) !void {
    try std.testing.expectEqual(before.len, after.len);
    for (before, after) |expected, actual| {
        try std.testing.expectEqual(expected.id, actual.id);
        try std.testing.expectEqual(expected.span, actual.span);
        try std.testing.expectEqual(expected.ty, actual.ty);
        if (std.meta.activeTag(expected.kind) != std.meta.activeTag(actual.kind)) {
            return error.PatternArmMismatch;
        }
        const decoded_kind = actual.kind;
        switch (expected.kind) {
            .wildcard => {},
            .binding => |binding| {
                try std.testing.expectEqualStrings(binding.name, decoded_kind.binding.name);
                try std.testing.expectEqual(binding.mode, decoded_kind.binding.mode);
                try std.testing.expectEqual(binding.mutable, decoded_kind.binding.mutable);
            },
            .literal => |literal| try expectDecodedLiteralMatches(literal, decoded_kind.literal),
            .path => |path| {
                try std.testing.expectEqual(path.def, decoded_kind.path.def);
                if (path.variant) |variant| {
                    try std.testing.expectEqualStrings(
                        variant,
                        decoded_kind.path.variant orelse return error.LostPathVariant,
                    );
                } else {
                    try std.testing.expect(decoded_kind.path.variant == null);
                }
            },
            .external_variant => |external| {
                try expectExternalNominalEquals(
                    external.owner,
                    decoded_kind.external_variant.owner,
                );
                try std.testing.expectEqualStrings(
                    external.variant,
                    decoded_kind.external_variant.variant,
                );
                try std.testing.expectEqual(
                    external.rest,
                    decoded_kind.external_variant.rest,
                );
                try std.testing.expectEqual(
                    external.fields.len,
                    decoded_kind.external_variant.fields.len,
                );
                for (external.fields, decoded_kind.external_variant.fields) |
                    field,
                    decoded_field,
                | {
                    try std.testing.expectEqualStrings(field.field, decoded_field.field);
                    try std.testing.expectEqual(field.pat, decoded_field.pat);
                    try std.testing.expectEqual(field.shorthand, decoded_field.shorthand);
                }
            },
            .tuple => |tuple| {
                try std.testing.expectEqualSlices(
                    exprs.NodeId,
                    tuple.elements,
                    decoded_kind.tuple.elements,
                );
                try std.testing.expectEqual(tuple.rest, decoded_kind.tuple.rest);
            },
            .slice => |slice| {
                try std.testing.expectEqualSlices(
                    exprs.NodeId,
                    slice.elements,
                    decoded_kind.slice.elements,
                );
                try std.testing.expectEqual(slice.rest, decoded_kind.slice.rest);
            },
            .struct_pat => |struct_pat| {
                try std.testing.expectEqual(struct_pat.def, decoded_kind.struct_pat.def);
                try std.testing.expectEqual(struct_pat.rest, decoded_kind.struct_pat.rest);
                try std.testing.expectEqual(
                    struct_pat.fields.len,
                    decoded_kind.struct_pat.fields.len,
                );
                for (struct_pat.fields, decoded_kind.struct_pat.fields) |field, decoded_field| {
                    try std.testing.expectEqualStrings(field.field, decoded_field.field);
                    try std.testing.expectEqual(field.pat, decoded_field.pat);
                    try std.testing.expectEqual(field.shorthand, decoded_field.shorthand);
                }
            },
            .reference => |reference| {
                try std.testing.expectEqual(reference.mode, decoded_kind.reference.mode);
                try std.testing.expectEqual(reference.inner, decoded_kind.reference.inner);
            },
            .@"or" => |or_pat| try std.testing.expectEqualSlices(
                exprs.NodeId,
                or_pat.alternatives,
                decoded_kind.@"or".alternatives,
            ),
            .range => |range_pat| {
                try std.testing.expectEqual(range_pat.lo, decoded_kind.range.lo);
                try std.testing.expectEqual(range_pat.hi, decoded_kind.range.hi);
                try std.testing.expectEqual(
                    range_pat.inclusive,
                    decoded_kind.range.inclusive,
                );
            },
        }
    }
}

fn expectDecodedStatementsMatch(
    before: []const exprs.Statement,
    after: []const exprs.Statement,
) !void {
    try std.testing.expectEqual(before.len, after.len);
    for (before, after) |expected, actual| {
        try std.testing.expectEqual(expected.id, actual.id);
        try std.testing.expectEqual(expected.span, actual.span);
        try std.testing.expectEqual(expected.ty, actual.ty);
        if (std.meta.activeTag(expected.kind) != std.meta.activeTag(actual.kind)) {
            return error.StatementArmMismatch;
        }
        const decoded_kind = actual.kind;
        switch (expected.kind) {
            .let => |let_stmt| {
                try std.testing.expectEqual(let_stmt.pattern, decoded_kind.let.pattern);
                try std.testing.expectEqual(let_stmt.init, decoded_kind.let.init);
                try std.testing.expectEqual(let_stmt.ty, decoded_kind.let.ty);
            },
            .let_else => |let_else| {
                try std.testing.expectEqual(let_else.pattern, decoded_kind.let_else.pattern);
                try std.testing.expectEqual(let_else.init, decoded_kind.let_else.init);
                try expectDecodedBlockMatches(
                    let_else.else_block,
                    decoded_kind.let_else.else_block,
                );
            },
            .expr => |id| try std.testing.expectEqual(id, decoded_kind.expr),
            .item => |id| try std.testing.expectEqual(id, decoded_kind.item),
        }
    }
}

fn expectDecodedFieldsMatch(
    before: []const items.Field,
    after: []const items.Field,
) !void {
    try std.testing.expectEqual(before.len, after.len);
    for (before, after) |expected, actual| {
        try std.testing.expectEqualStrings(expected.name, actual.name);
        try std.testing.expectEqual(expected.span, actual.span);
        // The field-slot binding type: the declared type of the field a
        // binding of that name takes. Losing it would decode a binding whose
        // slot the wire never described.
        try expectTypesEqual(expected.ty, actual.ty);
        switch (expected.visibility) {
            .in_path => |path| switch (actual.visibility) {
                .in_path => |decoded_path| try std.testing.expectEqualStrings(
                    path,
                    decoded_path,
                ),
                else => return error.LostFieldVisibility,
            },
            else => try std.testing.expectEqual(expected.visibility, actual.visibility),
        }
    }
}

fn expectDecodedParamsMatch(
    before: []const items.Param,
    after: []const items.Param,
) !void {
    try std.testing.expectEqual(before.len, after.len);
    for (before, after) |expected, actual| {
        try std.testing.expectEqualStrings(expected.name, actual.name);
        try std.testing.expectEqual(expected.span, actual.span);
        try expectTypesEqual(expected.ty, actual.ty);
    }
}

fn expectDecodedVariantsMatch(
    before: []const items.Variant,
    after: []const items.Variant,
) !void {
    try std.testing.expectEqual(before.len, after.len);
    for (before, after) |expected, actual| {
        try std.testing.expectEqualStrings(expected.name, actual.name);
        try std.testing.expectEqual(expected.discriminant, actual.discriminant);
        if (std.meta.activeTag(expected.fields) != std.meta.activeTag(actual.fields)) {
            return error.VariantFieldsArmMismatch;
        }
        switch (expected.fields) {
            .none => {},
            .tuple => |tuple| try std.testing.expectEqual(tuple.len, actual.fields.tuple.len),
            .named => |named| try expectDecodedFieldsMatch(named, actual.fields.named),
        }
    }
}

fn expectDecodedBodiesMatch(
    before: []const BodyKind,
    after: []const BodyKind,
) !void {
    try std.testing.expectEqual(before.len, after.len);
    for (before, after) |expected, actual| {
        if (std.meta.activeTag(expected) != std.meta.activeTag(actual)) {
            return error.BodyArmMismatch;
        }
        switch (expected) {
            .none => {},
            .const_ => |const_body| {
                try expectTypesEqual(const_body.ty, actual.const_.ty);
                try std.testing.expectEqual(const_body.init, actual.const_.init);
            },
            .fn_ => |fn_body| {
                try expectDecodedParamsMatch(fn_body.params, actual.fn_.params);
                try expectTypesEqual(fn_body.ret, actual.fn_.ret);
                try std.testing.expectEqualStrings(
                    fn_body.generic_params[0],
                    actual.fn_.generic_params[0],
                );
                try std.testing.expectEqual(fn_body.body, actual.fn_.body);
                try std.testing.expectEqual(fn_body.is_allocating, actual.fn_.is_allocating);
            },
            .struct_ => |struct_body| {
                try std.testing.expectEqualStrings(
                    struct_body.generic_params[0],
                    actual.struct_.generic_params[0],
                );
                try std.testing.expectEqualStrings(
                    struct_body.trait_bounds[0],
                    actual.struct_.trait_bounds[0],
                );
                try std.testing.expectEqual(struct_body.layout, actual.struct_.layout);
                try expectDecodedFieldsMatch(struct_body.fields, actual.struct_.fields);
                try std.testing.expectEqual(
                    struct_body.methods.len,
                    actual.struct_.methods.len,
                );
                for (struct_body.methods, actual.struct_.methods) |method, decoded_method| {
                    try std.testing.expectEqualStrings(method.name, decoded_method.name);
                    try std.testing.expectEqual(method.visibility, decoded_method.visibility);
                    try expectTypesEqual(method.ret, decoded_method.ret);
                    try std.testing.expectEqual(method.body, decoded_method.body);
                    try std.testing.expectEqual(method.receiver, decoded_method.receiver);
                    try std.testing.expectEqual(
                        method.is_allocating,
                        decoded_method.is_allocating,
                    );
                }
                try std.testing.expectEqual(
                    struct_body.has_dynamic_resources,
                    actual.struct_.has_dynamic_resources,
                );
            },
            .enum_ => |enum_body| {
                try std.testing.expectEqual(enum_body.kind, actual.enum_.kind);
                try expectDecodedVariantsMatch(enum_body.variants, actual.enum_.variants);
                try std.testing.expectEqual(enum_body.repr_int, actual.enum_.repr_int);
                try std.testing.expectEqual(
                    enum_body.non_exhaustive,
                    actual.enum_.non_exhaustive,
                );
            },
            .trait_ => |trait_body| {
                try std.testing.expectEqualStrings(trait_body.name, actual.trait_.name);
                try std.testing.expectEqualStrings(
                    trait_body.supertraits[0],
                    actual.trait_.supertraits[0],
                );
                try std.testing.expectEqual(
                    trait_body.methods.len,
                    actual.trait_.methods.len,
                );
                for (trait_body.methods, actual.trait_.methods) |method, decoded_method| {
                    try std.testing.expectEqualStrings(method.name, decoded_method.name);
                    try expectTypesEqual(method.ret, decoded_method.ret);
                    try std.testing.expectEqual(method.receiver, decoded_method.receiver);
                }
            },
            .type_alias => |alias| try expectTypesEqual(
                alias.target,
                actual.type_alias.target,
            ),
        }
    }
}

// One row per arm of every union the wire carries, with each optional and
// each defaulted field set away from its default, encoded and read back
// through `parseFull`. Every arm the model declares is exercised here; an arm
// the codec cannot describe refuses the decode and names itself in the error.
test "every model shape the corpus can produce survives encode and parseFull" {
    // The fixture is built over one arena rather than the testing allocator.
    // Every row it builds is a set of owned strings and slices released
    // individually, and the point of this test is the codec's own ownership
    // rules — not the fixture's. An arena makes the fixture's teardown a single
    // call, so a failure here names the codec rather than a fixture free.
    var fixture_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer fixture_arena.deinit();
    const allocator = fixture_arena.allocator();

    const expressions = try auditExprTable(allocator);
    const statements = try auditStatementTable(allocator);
    const patterns = try auditPatternTable(allocator);
    const type_table = try auditTypeTable(allocator);
    const bodies = try auditBodyTable(allocator);
    const probe_graph = try auditGraph(allocator);
    const encoded = try encodeFull(std.testing.allocator, .{
        .graph = probe_graph,
        .bodies = .{
            .exprs = expressions,
            .stmts = statements,
            .pats = patterns,
            .types = type_table,
            .bodies = bodies,
        },
    });
    defer std.testing.allocator.free(encoded);
    var read_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer read_arena.deinit();
    const decoded = try parseFull(read_arena.allocator(), encoded);

    // The coverage gate. Every arm of every union the wire carries is counted
    // below and compared with what the codec declares it can read, so an arm
    // added to the model after this test was written shows up as a count
    // mismatch instead of a shape nothing ever exercises.
    try expectEveryArmCovered(expressions, statements, patterns, type_table, bodies);

    try expectDecodedExprsMatch(expressions, decoded.bodies.exprs);
    try expectDecodedStatementsMatch(statements, decoded.bodies.stmts);
    try expectDecodedPatternsMatch(patterns, decoded.bodies.pats);
    try expectDecodedTypesMatch(type_table, decoded.bodies.types);
    try expectDecodedBodiesMatch(bodies, decoded.bodies.bodies);

    // The graph half of the same round trip. Every field asserted here is set
    // to a non-default value in `auditGraph`, so a decoder that substitutes a
    // default for absent or dropped data fails instead of passing quietly.
    try std.testing.expectEqualStrings(
        "sidecar-probe",
        decoded.graph.sidecar orelse return error.LostSidecar,
    );
    try std.testing.expectEqualStrings(
        "toolchain-probe",
        decoded.graph.toolchain orelse return error.LostToolchain,
    );
    const crate = decoded.graph.findCrate("probe_crate") orelse
        return error.LostCrate;
    try std.testing.expectEqual(@as(u16, 2024), crate.edition);
    try std.testing.expectEqual(graph.CrateKind.bin, crate.kind);
    try std.testing.expect(!crate.is_translated);
    try std.testing.expectEqual(@as(usize, 1), crate.deps.len);
    try std.testing.expectEqualStrings("probe_dep", crate.deps[0].extern_name);
    try std.testing.expectEqualStrings("probe_alias", crate.deps[0].local_alias);
    try std.testing.expectEqual(@as(u32, 77), crate.deps[0].id);
    try std.testing.expectEqual(@as(?bool, false), crate.deps[0].default_features);
    try std.testing.expectEqual(@as(usize, 2), crate.deps[0].features.len);
    try std.testing.expectEqualStrings("derive", crate.deps[0].features[0]);
    try std.testing.expectEqualStrings("std", crate.deps[0].features[1]);

    const module = decoded.graph.module(crate.root) orelse return error.LostModule;
    try std.testing.expectEqual(graph.ModuleKind.directory, module.kind);
    try std.testing.expectEqualStrings("probe", module.name);
    try std.testing.expectEqualStrings("src/probe.rs", module.source_path.?);
    try std.testing.expect(module.is_crate);
    try std.testing.expect(module.is_extern);
    try std.testing.expectEqual(audit_span, module.span);
    try std.testing.expectEqual(@as(usize, 1), module.attributes.len);
    try std.testing.expectEqualStrings("path", module.attributes[0].name);
    try std.testing.expectEqualStrings("src/probe.rs", module.attributes[0].meta);
    try std.testing.expect(!module.attributes[0].known);

    const entity = decoded.graph.symbol_table.get(crate.root) orelse
        return error.LostEntity;
    try std.testing.expectEqualStrings("Probe_", entity.renamed_to.?);
    switch (entity.visibility) {
        .in_path => |path| try std.testing.expectEqualStrings("crate::probe", path),
        else => return error.LostVisibilityPath,
    }
    try std.testing.expectEqual(@as(usize, 1), entity.attributes.len);
    try std.testing.expect(entity.attributes[0].known);

    const use_decl = decoded.graph.useById(crate.root) orelse return error.LostUseDecl;
    try std.testing.expect(use_decl.kind == .glob);
    try std.testing.expect(use_decl.is_pub_export);
}
