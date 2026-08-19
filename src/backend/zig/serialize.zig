//! translate_rust.backend.zig.serialize — JSON serialization and deserialization
//! for the Zig AST DOM (ast.Package).
//!
//! Enables lossless JSON encoding/decoding of Zig AST packages for snapshot testing,
//! inter-tool boundaries, and tooling inspection.

const std = @import("std");
const ast = @import("ast.zig");

const Json = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Array = std.json.Array;

pub const format_version: u32 = 1;

// ---------------------------------------------------------------------------
// Free Helper for Memory Management of Json Objects
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

fn reqU64(o: ObjectMap, key: []const u8) !u64 {
    const v = try req(o, key);
    return switch (v) {
        .integer => |i| @intCast(i),
        .string => |s| try std.fmt.parseInt(u64, s, 10),
        else => error.BadWireFormat,
    };
}

fn optU64(o: ObjectMap, key: []const u8) !?u64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |i| @intCast(i),
        .string => |s| try std.fmt.parseInt(u64, s, 10),
        .null => null,
        else => error.BadWireFormat,
    };
}

fn reqUsize(o: ObjectMap, key: []const u8) !usize {
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

fn optStr(o: ObjectMap, key: []const u8) !?[]const u8 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        .null => null,
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

// ---------------------------------------------------------------------------
// Type Serialization
// ---------------------------------------------------------------------------

fn encodePrim(p: ast.Prim) []const u8 {
    return @tagName(p);
}

fn decodePrim(s: []const u8) !ast.Prim {
    inline for (std.meta.fields(ast.Prim)) |f| {
        if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    }
    return error.UnknownPrim;
}

fn encodePtrSize(ps: ast.PtrSize) []const u8 {
    return @tagName(ps);
}

fn decodePtrSize(s: []const u8) !ast.PtrSize {
    inline for (std.meta.fields(ast.PtrSize)) |f| {
        if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    }
    return error.UnknownPtrSize;
}

pub fn encodeType(allocator: std.mem.Allocator, ty: ast.Type) anyerror!Json {
    var o = ObjectMap.empty;
    switch (ty) {
        .prim => |p| {
            try o.put(allocator, "kind", .{ .string = "prim" });
            try o.put(allocator, "value", .{ .string = encodePrim(p) });
        },
        .ptr => |ptr| {
            try o.put(allocator, "kind", .{ .string = "ptr" });
            try o.put(allocator, "elem", try encodeType(allocator, ptr.elem.*));
            try o.put(allocator, "is_const", .{ .bool = ptr.is_const });
            try o.put(allocator, "is_allowzero", .{ .bool = ptr.is_allowzero });
            try o.put(allocator, "size", .{ .string = encodePtrSize(ptr.size) });
        },
        .slice => |sl| {
            try o.put(allocator, "kind", .{ .string = "slice" });
            try o.put(allocator, "elem", try encodeType(allocator, sl.elem.*));
            try o.put(allocator, "is_const", .{ .bool = sl.is_const });
        },
        .opt => |inner| {
            try o.put(allocator, "kind", .{ .string = "opt" });
            try o.put(allocator, "elem", try encodeType(allocator, inner.*));
        },
        .err_union => |eu| {
            try o.put(allocator, "kind", .{ .string = "err_union" });
            try o.put(allocator, "err_set", encodeOptStr(eu.err_set));
            try o.put(allocator, "payload", try encodeType(allocator, eu.payload.*));
        },
        .named => |name| {
            try o.put(allocator, "kind", .{ .string = "named" });
            try o.put(allocator, "name", .{ .string = name });
        },
        .generic => |gi| {
            try o.put(allocator, "kind", .{ .string = "generic" });
            try o.put(allocator, "name", .{ .string = gi.name });
            var params_arr = Array.init(allocator);
            for (gi.params) |p| {
                try params_arr.append(try encodeType(allocator, p));
            }
            try o.put(allocator, "params", .{ .array = params_arr });
        },
        .array => |arr| {
            try o.put(allocator, "kind", .{ .string = "array" });
            try o.put(allocator, "elem", try encodeType(allocator, arr.elem.*));
            try o.put(allocator, "len", mkInt(arr.len));
        },
        .tuple => |tup| {
            try o.put(allocator, "kind", .{ .string = "tuple" });
            var elements_arr = Array.init(allocator);
            for (tup) |t| {
                try elements_arr.append(try encodeType(allocator, t));
            }
            try o.put(allocator, "elements", .{ .array = elements_arr });
        },
        .anon_struct => |as| {
            try o.put(allocator, "kind", .{ .string = "anon_struct" });
            var fields_arr = Array.init(allocator);
            for (as.fields) |f| {
                try fields_arr.append(try encodeStructField(allocator, f));
            }
            try o.put(allocator, "fields", .{ .array = fields_arr });
        },
        .any_opaque => {
            try o.put(allocator, "kind", .{ .string = "any_opaque" });
        },
        .void_type => {
            try o.put(allocator, "kind", .{ .string = "void_type" });
        },
    }
    return .{ .object = o };
}

pub fn decodeType(allocator: std.mem.Allocator, v: Json) anyerror!ast.Type {
    const o = try getObj(v);
    const kind = try reqStr(o, "kind");

    if (std.mem.eql(u8, kind, "prim")) {
        const val = try reqStr(o, "value");
        return .{ .prim = try decodePrim(val) };
    } else if (std.mem.eql(u8, kind, "ptr")) {
        const elem_ptr = try allocator.create(ast.Type);
        elem_ptr.* = try decodeType(allocator, try req(o, "elem"));
        const is_const = try reqBool(o, "is_const");
        const is_allowzero = if (o.get("is_allowzero")) |b| (switch (b) {
            .bool => |x| x,
            else => false,
        }) else false;
        const size_str = try reqStr(o, "size");
        const size = try decodePtrSize(size_str);
        return .{
            .ptr = .{
                .elem = elem_ptr,
                .is_const = is_const,
                .is_allowzero = is_allowzero,
                .size = size,
            },
        };
    } else if (std.mem.eql(u8, kind, "slice")) {
        const elem_ptr = try allocator.create(ast.Type);
        elem_ptr.* = try decodeType(allocator, try req(o, "elem"));
        const is_const = try reqBool(o, "is_const");
        return .{
            .slice = .{
                .elem = elem_ptr,
                .is_const = is_const,
            },
        };
    } else if (std.mem.eql(u8, kind, "opt")) {
        const elem_ptr = try allocator.create(ast.Type);
        elem_ptr.* = try decodeType(allocator, try req(o, "elem"));
        return .{ .opt = elem_ptr };
    } else if (std.mem.eql(u8, kind, "err_union")) {
        const payload_ptr = try allocator.create(ast.Type);
        payload_ptr.* = try decodeType(allocator, try req(o, "payload"));
        const err_set = if (try optStr(o, "err_set")) |es| try allocator.dupe(u8, es) else null;
        return .{
            .err_union = .{
                .err_set = err_set,
                .payload = payload_ptr,
            },
        };
    } else if (std.mem.eql(u8, kind, "named")) {
        const name = try reqStr(o, "name");
        return .{ .named = try allocator.dupe(u8, name) };
    } else if (std.mem.eql(u8, kind, "generic")) {
        const name = try reqStr(o, "name");
        const params_v = try req(o, "params");
        const params_arr = switch (params_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var params_list: std.ArrayListUnmanaged(ast.Type) = .empty;
        for (params_arr.items) |pv| {
            try params_list.append(allocator, try decodeType(allocator, pv));
        }
        return .{
            .generic = .{
                .name = try allocator.dupe(u8, name),
                .params = try params_list.toOwnedSlice(allocator),
            },
        };
    } else if (std.mem.eql(u8, kind, "array")) {
        const elem_ptr = try allocator.create(ast.Type);
        elem_ptr.* = try decodeType(allocator, try req(o, "elem"));
        const len = try reqUsize(o, "len");
        return .{
            .array = .{
                .elem = elem_ptr,
                .len = len,
            },
        };
    } else if (std.mem.eql(u8, kind, "tuple")) {
        const elem_v = try req(o, "elements");
        const elem_arr = switch (elem_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var elem_list: std.ArrayListUnmanaged(ast.Type) = .empty;
        for (elem_arr.items) |ev| {
            try elem_list.append(allocator, try decodeType(allocator, ev));
        }
        return .{ .tuple = try elem_list.toOwnedSlice(allocator) };
    } else if (std.mem.eql(u8, kind, "anon_struct")) {
        const fields_v = try req(o, "fields");
        const fields_arr = switch (fields_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var fields_list: std.ArrayListUnmanaged(ast.StructField) = .empty;
        for (fields_arr.items) |fv| {
            try fields_list.append(allocator, try decodeStructField(allocator, fv));
        }
        return .{
            .anon_struct = .{
                .fields = try fields_list.toOwnedSlice(allocator),
            },
        };
    } else if (std.mem.eql(u8, kind, "any_opaque")) {
        return .any_opaque;
    } else if (std.mem.eql(u8, kind, "void_type")) {
        return .void_type;
    }

    return error.UnknownTypeKind;
}

// ---------------------------------------------------------------------------
// Literal Serialization
// ---------------------------------------------------------------------------

pub fn encodeLiteral(allocator: std.mem.Allocator, lit: ast.Literal) anyerror!Json {
    var o = ObjectMap.empty;
    switch (lit) {
        .int => |v| {
            try o.put(allocator, "kind", .{ .string = "int" });
            const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
            try o.put(allocator, "value", .{ .string = s });
        },
        .uint => |v| {
            try o.put(allocator, "kind", .{ .string = "uint" });
            const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
            try o.put(allocator, "value", .{ .string = s });
        },
        .float => |v| {
            try o.put(allocator, "kind", .{ .string = "float" });
            try o.put(allocator, "value", .{ .float = v });
        },
        .bool_lit => |v| {
            try o.put(allocator, "kind", .{ .string = "bool_lit" });
            try o.put(allocator, "value", .{ .bool = v });
        },
        .char_lit => |v| {
            try o.put(allocator, "kind", .{ .string = "char_lit" });
            try o.put(allocator, "value", mkInt(v));
        },
        .str => |v| {
            try o.put(allocator, "kind", .{ .string = "str" });
            try o.put(allocator, "value", .{ .string = v });
        },
        .null_lit => {
            try o.put(allocator, "kind", .{ .string = "null_lit" });
        },
        .undefined_lit => {
            try o.put(allocator, "kind", .{ .string = "undefined_lit" });
        },
    }
    return .{ .object = o };
}

pub fn decodeLiteral(allocator: std.mem.Allocator, v: Json) anyerror!ast.Literal {
    const o = try getObj(v);
    const kind = try reqStr(o, "kind");

    if (std.mem.eql(u8, kind, "int")) {
        const val = try req(o, "value");
        return switch (val) {
            .integer => |i| .{ .int = i },
            .string => |s| .{ .int = try std.fmt.parseInt(i128, s, 10) },
            else => error.BadWireFormat,
        };
    } else if (std.mem.eql(u8, kind, "uint")) {
        const val = try req(o, "value");
        return switch (val) {
            .integer => |i| .{ .uint = @intCast(i) },
            .string => |s| .{ .uint = try std.fmt.parseInt(u128, s, 10) },
            else => error.BadWireFormat,
        };
    } else if (std.mem.eql(u8, kind, "float")) {
        return .{ .float = try reqFloat(o, "value") };
    } else if (std.mem.eql(u8, kind, "bool_lit")) {
        return .{ .bool_lit = try reqBool(o, "value") };
    } else if (std.mem.eql(u8, kind, "char_lit")) {
        return .{ .char_lit = @intCast(try reqU32(o, "value")) };
    } else if (std.mem.eql(u8, kind, "str")) {
        const s = try reqStr(o, "value");
        return .{ .str = try allocator.dupe(u8, s) };
    } else if (std.mem.eql(u8, kind, "null_lit")) {
        return .null_lit;
    } else if (std.mem.eql(u8, kind, "undefined_lit")) {
        return .undefined_lit;
    }

    return error.UnknownLiteralKind;
}

// ---------------------------------------------------------------------------
// Pattern Serialization
// ---------------------------------------------------------------------------

pub fn encodePattern(allocator: std.mem.Allocator, pat: ast.Pattern) anyerror!Json {
    var o = ObjectMap.empty;
    switch (pat) {
        .wildcard => {
            try o.put(allocator, "kind", .{ .string = "wildcard" });
        },
        .binding => |name| {
            try o.put(allocator, "kind", .{ .string = "binding" });
            try o.put(allocator, "name", .{ .string = name });
        },
        .lit => |l| {
            try o.put(allocator, "kind", .{ .string = "lit" });
            try o.put(allocator, "value", try encodeLiteral(allocator, l));
        },
        .enum_literal => |name| {
            try o.put(allocator, "kind", .{ .string = "enum_literal" });
            try o.put(allocator, "name", .{ .string = name });
        },
        .tuple => |pats| {
            try o.put(allocator, "kind", .{ .string = "tuple" });
            var arr = Array.init(allocator);
            for (pats) |p| {
                try arr.append(try encodePattern(allocator, p));
            }
            try o.put(allocator, "elements", .{ .array = arr });
        },
        .struct_pat => |sp| {
            try o.put(allocator, "kind", .{ .string = "struct_pat" });
            try o.put(allocator, "name", encodeOptStr(sp.name));
            var fields_arr = Array.init(allocator);
            for (sp.fields) |f| {
                var fo = ObjectMap.empty;
                try fo.put(allocator, "name", .{ .string = f.name });
                try fo.put(allocator, "pat", try encodePattern(allocator, f.pat));
                try fields_arr.append(.{ .object = fo });
            }
            try o.put(allocator, "fields", .{ .array = fields_arr });
        },
    }
    return .{ .object = o };
}

pub fn decodePattern(allocator: std.mem.Allocator, v: Json) anyerror!ast.Pattern {
    const o = try getObj(v);
    const kind = try reqStr(o, "kind");

    if (std.mem.eql(u8, kind, "wildcard")) {
        return .wildcard;
    } else if (std.mem.eql(u8, kind, "binding")) {
        const name = try reqStr(o, "name");
        return .{ .binding = try allocator.dupe(u8, name) };
    } else if (std.mem.eql(u8, kind, "lit")) {
        return .{ .lit = try decodeLiteral(allocator, try req(o, "value")) };
    } else if (std.mem.eql(u8, kind, "enum_literal")) {
        const name = try reqStr(o, "name");
        return .{ .enum_literal = try allocator.dupe(u8, name) };
    } else if (std.mem.eql(u8, kind, "tuple")) {
        const arr_v = try req(o, "elements");
        const arr = switch (arr_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var list: std.ArrayListUnmanaged(ast.Pattern) = .empty;
        for (arr.items) |item| {
            try list.append(allocator, try decodePattern(allocator, item));
        }
        return .{ .tuple = try list.toOwnedSlice(allocator) };
    } else if (std.mem.eql(u8, kind, "struct_pat")) {
        const name = if (try optStr(o, "name")) |s| try allocator.dupe(u8, s) else null;
        const fields_v = try req(o, "fields");
        const fields_arr = switch (fields_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var list: std.ArrayListUnmanaged(ast.StructPatternField) = .empty;
        for (fields_arr.items) |item| {
            const fo = try getObj(item);
            const fname = try reqStr(fo, "name");
            const fpat = try decodePattern(allocator, try req(fo, "pat"));
            try list.append(allocator, .{
                .name = try allocator.dupe(u8, fname),
                .pat = fpat,
            });
        }
        return .{
            .struct_pat = .{
                .name = name,
                .fields = try list.toOwnedSlice(allocator),
            },
        };
    }

    return error.UnknownPatternKind;
}

// ---------------------------------------------------------------------------
// Operators Serialization
// ---------------------------------------------------------------------------

fn encodeBinOpKind(b: ast.BinOpKind) []const u8 {
    return @tagName(b);
}

fn decodeBinOpKind(s: []const u8) !ast.BinOpKind {
    inline for (std.meta.fields(ast.BinOpKind)) |f| {
        if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    }
    return error.UnknownBinOpKind;
}

fn encodeUnaryOpKind(u: ast.UnaryOpKind) []const u8 {
    return @tagName(u);
}

fn decodeUnaryOpKind(s: []const u8) !ast.UnaryOpKind {
    inline for (std.meta.fields(ast.UnaryOpKind)) |f| {
        if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    }
    return error.UnknownUnaryOpKind;
}

fn encodeAssignOp(a: ast.AssignOp) []const u8 {
    return @tagName(a);
}

fn decodeAssignOp(s: []const u8) !ast.AssignOp {
    inline for (std.meta.fields(ast.AssignOp)) |f| {
        if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    }
    return error.UnknownAssignOp;
}

// ---------------------------------------------------------------------------
// Expr Serialization
// ---------------------------------------------------------------------------

pub fn encodeExpr(allocator: std.mem.Allocator, expr: ast.Expr) anyerror!Json {
    var o = ObjectMap.empty;
    switch (expr) {
        .lit => |l| {
            try o.put(allocator, "kind", .{ .string = "lit" });
            try o.put(allocator, "value", try encodeLiteral(allocator, l));
        },
        .ident => |id| {
            try o.put(allocator, "kind", .{ .string = "ident" });
            try o.put(allocator, "name", .{ .string = id });
        },
        .field_access => |fa| {
            try o.put(allocator, "kind", .{ .string = "field_access" });
            try o.put(allocator, "target", try encodeExpr(allocator, fa.target.*));
            try o.put(allocator, "field_name", .{ .string = fa.field_name });
        },
        .call => |c| {
            try o.put(allocator, "kind", .{ .string = "call" });
            try o.put(allocator, "callee", try encodeExpr(allocator, c.callee.*));
            var args_arr = Array.init(allocator);
            for (c.args) |a| {
                try args_arr.append(try encodeExpr(allocator, a));
            }
            try o.put(allocator, "args", .{ .array = args_arr });
        },
        .block => |b| {
            try o.put(allocator, "kind", .{ .string = "block" });
            try o.put(allocator, "block", try encodeBlock(allocator, b));
        },
        .match_expr => |m| {
            try o.put(allocator, "kind", .{ .string = "match_expr" });
            try o.put(allocator, "target", try encodeExpr(allocator, m.target.*));
            var arms_arr = Array.init(allocator);
            for (m.arms) |arm| {
                var ao = ObjectMap.empty;
                var pat_arr = Array.init(allocator);
                for (arm.patterns) |p| {
                    try pat_arr.append(try encodePattern(allocator, p));
                }
                try ao.put(allocator, "patterns", .{ .array = pat_arr });
                try ao.put(allocator, "body", try encodeExpr(allocator, arm.body));
                try arms_arr.append(.{ .object = ao });
            }
            try o.put(allocator, "arms", .{ .array = arms_arr });
        },
        .bin_op => |b| {
            try o.put(allocator, "kind", .{ .string = "bin_op" });
            try o.put(allocator, "op", .{ .string = encodeBinOpKind(b.op) });
            try o.put(allocator, "lhs", try encodeExpr(allocator, b.lhs.*));
            try o.put(allocator, "rhs", try encodeExpr(allocator, b.rhs.*));
        },
        .unary_op => |u| {
            try o.put(allocator, "kind", .{ .string = "unary_op" });
            try o.put(allocator, "op", .{ .string = encodeUnaryOpKind(u.op) });
            try o.put(allocator, "operand", try encodeExpr(allocator, u.operand.*));
        },
        .struct_init => |si| {
            try o.put(allocator, "kind", .{ .string = "struct_init" });
            if (si.type_name) |tn| {
                try o.put(allocator, "type_name", try encodeType(allocator, tn));
            } else {
                try o.put(allocator, "type_name", .{ .null = {} });
            }
            var fields_arr = Array.init(allocator);
            for (si.fields) |f| {
                var fo = ObjectMap.empty;
                try fo.put(allocator, "name", .{ .string = f.name });
                try fo.put(allocator, "expr", try encodeExpr(allocator, f.expr));
                try fields_arr.append(.{ .object = fo });
            }
            try o.put(allocator, "fields", .{ .array = fields_arr });
        },
        .array_init => |ai| {
            try o.put(allocator, "kind", .{ .string = "array_init" });
            if (ai.type_name) |tn| {
                try o.put(allocator, "type_name", try encodeType(allocator, tn));
            } else {
                try o.put(allocator, "type_name", .{ .null = {} });
            }
            var elem_arr = Array.init(allocator);
            for (ai.elements) |e| {
                try elem_arr.append(try encodeExpr(allocator, e));
            }
            try o.put(allocator, "elements", .{ .array = elem_arr });
        },
        .builtin => |bc| {
            try o.put(allocator, "kind", .{ .string = "builtin" });
            try o.put(allocator, "name", .{ .string = bc.name });
            var args_arr = Array.init(allocator);
            for (bc.args) |a| {
                try args_arr.append(try encodeExpr(allocator, a));
            }
            try o.put(allocator, "args", .{ .array = args_arr });
        },
        .unsupported => |reason| {
            try o.put(allocator, "kind", .{ .string = "unsupported" });
            try o.put(allocator, "reason", .{ .string = reason });
        },
        .if_expr => |ife| {
            try o.put(allocator, "kind", .{ .string = "if_expr" });
            try o.put(allocator, "cond", try encodeExpr(allocator, ife.cond.*));
            try o.put(allocator, "then_body", try encodeExpr(allocator, ife.then_body.*));
            if (ife.else_body) |eb| {
                try o.put(allocator, "else_body", try encodeExpr(allocator, eb.*));
            } else {
                try o.put(allocator, "else_body", .{ .null = {} });
            }
        },
        .while_expr => |we| {
            try o.put(allocator, "kind", .{ .string = "while_expr" });
            try o.put(allocator, "cond", try encodeExpr(allocator, we.cond.*));
            if (we.continue_expr) |ce| {
                try o.put(allocator, "continue_expr", try encodeExpr(allocator, ce.*));
            } else {
                try o.put(allocator, "continue_expr", .{ .null = {} });
            }
            try o.put(allocator, "body", try encodeBlock(allocator, we.body));
            if (we.else_body) |eb| {
                try o.put(allocator, "else_body", try encodeExpr(allocator, eb.*));
            } else {
                try o.put(allocator, "else_body", .{ .null = {} });
            }
        },
        .for_expr => |fe| {
            try o.put(allocator, "kind", .{ .string = "for_expr" });
            var in_arr = Array.init(allocator);
            for (fe.inputs) |in_e| {
                try in_arr.append(try encodeExpr(allocator, in_e));
            }
            try o.put(allocator, "inputs", .{ .array = in_arr });

            var cap_arr = Array.init(allocator);
            for (fe.captures) |cap| {
                try cap_arr.append(.{ .string = cap });
            }
            try o.put(allocator, "captures", .{ .array = cap_arr });

            try o.put(allocator, "body", try encodeBlock(allocator, fe.body));
            if (fe.else_body) |eb| {
                try o.put(allocator, "else_body", try encodeExpr(allocator, eb.*));
            } else {
                try o.put(allocator, "else_body", .{ .null = {} });
            }
        },
        .return_expr => |re| {
            try o.put(allocator, "kind", .{ .string = "return_expr" });
            if (re) |val| {
                try o.put(allocator, "value", try encodeExpr(allocator, val.*));
            } else {
                try o.put(allocator, "value", .{ .null = {} });
            }
        },
        .break_expr => |be| {
            try o.put(allocator, "kind", .{ .string = "break_expr" });
            if (be) |val| {
                try o.put(allocator, "value", try encodeExpr(allocator, val.*));
            } else {
                try o.put(allocator, "value", .{ .null = {} });
            }
        },
        .continue_expr => {
            try o.put(allocator, "kind", .{ .string = "continue_expr" });
        },
    }
    return .{ .object = o };
}

pub fn decodeExpr(allocator: std.mem.Allocator, v: Json) anyerror!ast.Expr {
    const o = try getObj(v);
    const kind = try reqStr(o, "kind");

    if (std.mem.eql(u8, kind, "lit")) {
        return .{ .lit = try decodeLiteral(allocator, try req(o, "value")) };
    } else if (std.mem.eql(u8, kind, "ident")) {
        const name = try reqStr(o, "name");
        return .{ .ident = try allocator.dupe(u8, name) };
    } else if (std.mem.eql(u8, kind, "field_access")) {
        const target_ptr = try allocator.create(ast.Expr);
        target_ptr.* = try decodeExpr(allocator, try req(o, "target"));
        const fname = try reqStr(o, "field_name");
        return .{
            .field_access = .{
                .target = target_ptr,
                .field_name = try allocator.dupe(u8, fname),
            },
        };
    } else if (std.mem.eql(u8, kind, "call")) {
        const callee_ptr = try allocator.create(ast.Expr);
        callee_ptr.* = try decodeExpr(allocator, try req(o, "callee"));
        const args_v = try req(o, "args");
        const args_arr = switch (args_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var list: std.ArrayListUnmanaged(ast.Expr) = .empty;
        for (args_arr.items) |item| {
            try list.append(allocator, try decodeExpr(allocator, item));
        }
        return .{
            .call = .{
                .callee = callee_ptr,
                .args = try list.toOwnedSlice(allocator),
            },
        };
    } else if (std.mem.eql(u8, kind, "block")) {
        const blk = try decodeBlock(allocator, try req(o, "block"));
        return .{ .block = blk };
    } else if (std.mem.eql(u8, kind, "match_expr")) {
        const target_ptr = try allocator.create(ast.Expr);
        target_ptr.* = try decodeExpr(allocator, try req(o, "target"));
        const arms_v = try req(o, "arms");
        const arms_arr = switch (arms_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var arms_list: std.ArrayListUnmanaged(ast.MatchArm) = .empty;
        for (arms_arr.items) |item| {
            const ao = try getObj(item);
            const pat_v = try req(ao, "patterns");
            const pat_arr = switch (pat_v) {
                .array => |a| a,
                else => return error.BadWireFormat,
            };
            var pats_list: std.ArrayListUnmanaged(ast.Pattern) = .empty;
            for (pat_arr.items) |pv| {
                try pats_list.append(allocator, try decodePattern(allocator, pv));
            }
            const body = try decodeExpr(allocator, try req(ao, "body"));
            try arms_list.append(allocator, .{
                .patterns = try pats_list.toOwnedSlice(allocator),
                .body = body,
            });
        }
        return .{
            .match_expr = .{
                .target = target_ptr,
                .arms = try arms_list.toOwnedSlice(allocator),
            },
        };
    } else if (std.mem.eql(u8, kind, "bin_op")) {
        const op_str = try reqStr(o, "op");
        const op = try decodeBinOpKind(op_str);
        const lhs_ptr = try allocator.create(ast.Expr);
        lhs_ptr.* = try decodeExpr(allocator, try req(o, "lhs"));
        const rhs_ptr = try allocator.create(ast.Expr);
        rhs_ptr.* = try decodeExpr(allocator, try req(o, "rhs"));
        return .{
            .bin_op = .{
                .op = op,
                .lhs = lhs_ptr,
                .rhs = rhs_ptr,
            },
        };
    } else if (std.mem.eql(u8, kind, "unary_op")) {
        const op_str = try reqStr(o, "op");
        const op = try decodeUnaryOpKind(op_str);
        const operand_ptr = try allocator.create(ast.Expr);
        operand_ptr.* = try decodeExpr(allocator, try req(o, "operand"));
        return .{
            .unary_op = .{
                .op = op,
                .operand = operand_ptr,
            },
        };
    } else if (std.mem.eql(u8, kind, "struct_init")) {
        const type_name = if (o.get("type_name")) |tn| (switch (tn) {
            .null => null,
            else => try decodeType(allocator, tn),
        }) else null;
        const fields_v = try req(o, "fields");
        const fields_arr = switch (fields_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var fields_list: std.ArrayListUnmanaged(ast.StructInitField) = .empty;
        for (fields_arr.items) |item| {
            const fo = try getObj(item);
            const fname = try reqStr(fo, "name");
            const fexpr = try decodeExpr(allocator, try req(fo, "expr"));
            try fields_list.append(allocator, .{
                .name = try allocator.dupe(u8, fname),
                .expr = fexpr,
            });
        }
        return .{
            .struct_init = .{
                .type_name = type_name,
                .fields = try fields_list.toOwnedSlice(allocator),
            },
        };
    } else if (std.mem.eql(u8, kind, "array_init")) {
        const type_name = if (o.get("type_name")) |tn| (switch (tn) {
            .null => null,
            else => try decodeType(allocator, tn),
        }) else null;
        const elem_v = try req(o, "elements");
        const elem_arr = switch (elem_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var elem_list: std.ArrayListUnmanaged(ast.Expr) = .empty;
        for (elem_arr.items) |item| {
            try elem_list.append(allocator, try decodeExpr(allocator, item));
        }
        return .{
            .array_init = .{
                .type_name = type_name,
                .elements = try elem_list.toOwnedSlice(allocator),
            },
        };
    } else if (std.mem.eql(u8, kind, "builtin")) {
        const bname = try reqStr(o, "name");
        const args_v = try req(o, "args");
        const args_arr = switch (args_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var args_list: std.ArrayListUnmanaged(ast.Expr) = .empty;
        for (args_arr.items) |item| {
            try args_list.append(allocator, try decodeExpr(allocator, item));
        }
        return .{
            .builtin = .{
                .name = try allocator.dupe(u8, bname),
                .args = try args_list.toOwnedSlice(allocator),
            },
        };
    } else if (std.mem.eql(u8, kind, "unsupported")) {
        const reason = try reqStr(o, "reason");
        return .{ .unsupported = try allocator.dupe(u8, reason) };
    } else if (std.mem.eql(u8, kind, "if_expr")) {
        const cond_ptr = try allocator.create(ast.Expr);
        cond_ptr.* = try decodeExpr(allocator, try req(o, "cond"));
        const then_ptr = try allocator.create(ast.Expr);
        then_ptr.* = try decodeExpr(allocator, try req(o, "then_body"));
        const else_ptr: ?*const ast.Expr = if (o.get("else_body")) |eb| (switch (eb) {
            .null => null,
            else => blk: {
                const ep = try allocator.create(ast.Expr);
                ep.* = try decodeExpr(allocator, eb);
                break :blk ep;
            },
        }) else null;
        return .{
            .if_expr = .{
                .cond = cond_ptr,
                .then_body = then_ptr,
                .else_body = else_ptr,
            },
        };
    } else if (std.mem.eql(u8, kind, "while_expr")) {
        const cond_ptr = try allocator.create(ast.Expr);
        cond_ptr.* = try decodeExpr(allocator, try req(o, "cond"));
        const cont_ptr: ?*const ast.Expr = if (o.get("continue_expr")) |ce| (switch (ce) {
            .null => null,
            else => blk: {
                const cp = try allocator.create(ast.Expr);
                cp.* = try decodeExpr(allocator, ce);
                break :blk cp;
            },
        }) else null;
        const body = try decodeBlock(allocator, try req(o, "body"));
        const else_ptr: ?*const ast.Expr = if (o.get("else_body")) |eb| (switch (eb) {
            .null => null,
            else => blk: {
                const ep = try allocator.create(ast.Expr);
                ep.* = try decodeExpr(allocator, eb);
                break :blk ep;
            },
        }) else null;
        return .{
            .while_expr = .{
                .cond = cond_ptr,
                .continue_expr = cont_ptr,
                .body = body,
                .else_body = else_ptr,
            },
        };
    } else if (std.mem.eql(u8, kind, "for_expr")) {
        const in_v = try req(o, "inputs");
        const in_arr = switch (in_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var in_list: std.ArrayListUnmanaged(ast.Expr) = .empty;
        for (in_arr.items) |item| {
            try in_list.append(allocator, try decodeExpr(allocator, item));
        }

        const cap_v = try req(o, "captures");
        const cap_arr = switch (cap_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var cap_list: std.ArrayListUnmanaged([]const u8) = .empty;
        for (cap_arr.items) |item| {
            const s = switch (item) {
                .string => |str| str,
                else => return error.BadWireFormat,
            };
            try cap_list.append(allocator, try allocator.dupe(u8, s));
        }

        const body = try decodeBlock(allocator, try req(o, "body"));
        const else_ptr: ?*const ast.Expr = if (o.get("else_body")) |eb| (switch (eb) {
            .null => null,
            else => blk: {
                const ep = try allocator.create(ast.Expr);
                ep.* = try decodeExpr(allocator, eb);
                break :blk ep;
            },
        }) else null;

        return .{
            .for_expr = .{
                .inputs = try in_list.toOwnedSlice(allocator),
                .captures = try cap_list.toOwnedSlice(allocator),
                .body = body,
                .else_body = else_ptr,
            },
        };
    } else if (std.mem.eql(u8, kind, "return_expr")) {
        const val_ptr: ?*const ast.Expr = if (o.get("value")) |v_node| (switch (v_node) {
            .null => null,
            else => blk: {
                const p = try allocator.create(ast.Expr);
                p.* = try decodeExpr(allocator, v_node);
                break :blk p;
            },
        }) else null;
        return .{ .return_expr = val_ptr };
    } else if (std.mem.eql(u8, kind, "break_expr")) {
        const val_ptr: ?*const ast.Expr = if (o.get("value")) |v_node| (switch (v_node) {
            .null => null,
            else => blk: {
                const p = try allocator.create(ast.Expr);
                p.* = try decodeExpr(allocator, v_node);
                break :blk p;
            },
        }) else null;
        return .{ .break_expr = val_ptr };
    } else if (std.mem.eql(u8, kind, "continue_expr")) {
        return .{ .continue_expr = {} };
    }

    return error.UnknownExprKind;
}

// ---------------------------------------------------------------------------
// Block & Stmt Serialization
// ---------------------------------------------------------------------------

pub fn encodeBlock(allocator: std.mem.Allocator, b: ast.Block) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "label", encodeOptStr(b.label));

    var stmts_arr = Array.init(allocator);
    for (b.stmts) |s| {
        try stmts_arr.append(try encodeStmt(allocator, s));
    }
    try o.put(allocator, "stmts", .{ .array = stmts_arr });

    if (b.expr) |ex| {
        try o.put(allocator, "expr", try encodeExpr(allocator, ex.*));
    } else {
        try o.put(allocator, "expr", .{ .null = {} });
    }

    return .{ .object = o };
}

pub fn decodeBlock(allocator: std.mem.Allocator, v: Json) anyerror!ast.Block {
    const o = try getObj(v);
    const label = if (try optStr(o, "label")) |l| try allocator.dupe(u8, l) else null;

    const stmts_v = try req(o, "stmts");
    const stmts_arr = switch (stmts_v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var stmts_list: std.ArrayListUnmanaged(ast.Stmt) = .empty;
    for (stmts_arr.items) |sv| {
        try stmts_list.append(allocator, try decodeStmt(allocator, sv));
    }

    const expr_ptr: ?*const ast.Expr = if (o.get("expr")) |ev| (switch (ev) {
        .null => null,
        else => blk: {
            const ep = try allocator.create(ast.Expr);
            ep.* = try decodeExpr(allocator, ev);
            break :blk ep;
        },
    }) else null;

    return .{
        .label = label,
        .stmts = try stmts_list.toOwnedSlice(allocator),
        .expr = expr_ptr,
    };
}

pub fn encodeStmt(allocator: std.mem.Allocator, stmt: ast.Stmt) anyerror!Json {
    var o = ObjectMap.empty;
    switch (stmt) {
        .let_stmt => |let| {
            try o.put(allocator, "kind", .{ .string = "let_stmt" });
            try o.put(allocator, "name", .{ .string = let.name });
            if (let.ty) |ty| {
                try o.put(allocator, "ty", try encodeType(allocator, ty));
            } else {
                try o.put(allocator, "ty", .{ .null = {} });
            }
            try o.put(allocator, "init", try encodeExpr(allocator, let.init));
            try o.put(allocator, "is_mut", .{ .bool = let.is_mut });
        },
        .assign => |asg| {
            try o.put(allocator, "kind", .{ .string = "assign" });
            try o.put(allocator, "target", try encodeExpr(allocator, asg.target));
            try o.put(allocator, "val", try encodeExpr(allocator, asg.val));
            try o.put(allocator, "op", .{ .string = encodeAssignOp(asg.op) });
        },
        .expr_stmt => |ex| {
            try o.put(allocator, "kind", .{ .string = "expr_stmt" });
            try o.put(allocator, "expr", try encodeExpr(allocator, ex.*));
        },
    }
    return .{ .object = o };
}

pub fn decodeStmt(allocator: std.mem.Allocator, v: Json) anyerror!ast.Stmt {
    const o = try getObj(v);
    const kind = try reqStr(o, "kind");

    if (std.mem.eql(u8, kind, "let_stmt")) {
        const name = try reqStr(o, "name");
        const ty = if (o.get("ty")) |ty_val| (switch (ty_val) {
            .null => null,
            else => try decodeType(allocator, ty_val),
        }) else null;
        const init = try decodeExpr(allocator, try req(o, "init"));
        const is_mut = if (o.get("is_mut")) |b| (switch (b) {
            .bool => |x| x,
            else => false,
        }) else false;

        return .{
            .let_stmt = .{
                .name = try allocator.dupe(u8, name),
                .ty = ty,
                .init = init,
                .is_mut = is_mut,
            },
        };
    } else if (std.mem.eql(u8, kind, "assign")) {
        const target = try decodeExpr(allocator, try req(o, "target"));
        const val = try decodeExpr(allocator, try req(o, "val"));
        const op_str = if (try optStr(o, "op")) |s| s else "assign";
        const op = try decodeAssignOp(op_str);
        return .{
            .assign = .{
                .target = target,
                .val = val,
                .op = op,
            },
        };
    } else if (std.mem.eql(u8, kind, "expr_stmt")) {
        const ep = try allocator.create(ast.Expr);
        ep.* = try decodeExpr(allocator, try req(o, "expr"));
        return .{ .expr_stmt = ep };
    }

    return error.UnknownStmtKind;
}

// ---------------------------------------------------------------------------
// GenericParam, StructField, Variant, Param Serialization
// ---------------------------------------------------------------------------

pub fn encodeGenericParam(allocator: std.mem.Allocator, gp: ast.GenericParam) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = gp.name });
    try o.put(allocator, "is_comptime", .{ .bool = gp.is_comptime });
    if (gp.ty) |ty| {
        try o.put(allocator, "ty", try encodeType(allocator, ty));
    } else {
        try o.put(allocator, "ty", .{ .null = {} });
    }
    return .{ .object = o };
}

pub fn decodeGenericParam(allocator: std.mem.Allocator, v: Json) anyerror!ast.GenericParam {
    const o = try getObj(v);
    const name = try reqStr(o, "name");
    const is_comptime = if (o.get("is_comptime")) |b| (switch (b) {
        .bool => |x| x,
        else => true,
    }) else true;
    const ty = if (o.get("ty")) |ty_v| (switch (ty_v) {
        .null => null,
        else => try decodeType(allocator, ty_v),
    }) else null;
    return .{
        .name = try allocator.dupe(u8, name),
        .is_comptime = is_comptime,
        .ty = ty,
    };
}

pub fn encodeStructField(allocator: std.mem.Allocator, sf: ast.StructField) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = sf.name });
    try o.put(allocator, "ty", try encodeType(allocator, sf.ty));
    if (sf.default_val) |dv| {
        try o.put(allocator, "default_val", try encodeExpr(allocator, dv.*));
    } else {
        try o.put(allocator, "default_val", .{ .null = {} });
    }
    try o.put(allocator, "is_pub", .{ .bool = sf.is_pub });
    return .{ .object = o };
}

pub fn decodeStructField(allocator: std.mem.Allocator, v: Json) anyerror!ast.StructField {
    const o = try getObj(v);
    const name = try reqStr(o, "name");
    const ty = try decodeType(allocator, try req(o, "ty"));
    const dv_ptr: ?*const ast.Expr = if (o.get("default_val")) |dv| (switch (dv) {
        .null => null,
        else => blk: {
            const p = try allocator.create(ast.Expr);
            p.* = try decodeExpr(allocator, dv);
            break :blk p;
        },
    }) else null;
    const is_pub = if (o.get("is_pub")) |b| (switch (b) {
        .bool => |x| x,
        else => true,
    }) else true;

    return .{
        .name = try allocator.dupe(u8, name),
        .ty = ty,
        .default_val = dv_ptr,
        .is_pub = is_pub,
    };
}

pub fn encodeEnumVariant(allocator: std.mem.Allocator, ev: ast.EnumVariant) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = ev.name });
    if (ev.value) |val| {
        try o.put(allocator, "value", try encodeExpr(allocator, val.*));
    } else {
        try o.put(allocator, "value", .{ .null = {} });
    }
    return .{ .object = o };
}

pub fn decodeEnumVariant(allocator: std.mem.Allocator, v: Json) anyerror!ast.EnumVariant {
    const o = try getObj(v);
    const name = try reqStr(o, "name");
    const val_ptr: ?*const ast.Expr = if (o.get("value")) |val| (switch (val) {
        .null => null,
        else => blk: {
            const p = try allocator.create(ast.Expr);
            p.* = try decodeExpr(allocator, val);
            break :blk p;
        },
    }) else null;
    return .{
        .name = try allocator.dupe(u8, name),
        .value = val_ptr,
    };
}

pub fn encodeUnionField(allocator: std.mem.Allocator, uf: ast.UnionField) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = uf.name });
    try o.put(allocator, "ty", try encodeType(allocator, uf.ty));
    try o.put(allocator, "is_pub", .{ .bool = uf.is_pub });
    return .{ .object = o };
}

pub fn decodeUnionField(allocator: std.mem.Allocator, v: Json) anyerror!ast.UnionField {
    const o = try getObj(v);
    const name = try reqStr(o, "name");
    const ty = try decodeType(allocator, try req(o, "ty"));
    const is_pub = if (o.get("is_pub")) |b| (switch (b) {
        .bool => |x| x,
        else => true,
    }) else true;
    return .{
        .name = try allocator.dupe(u8, name),
        .ty = ty,
        .is_pub = is_pub,
    };
}

pub fn encodeFnParam(allocator: std.mem.Allocator, fp: ast.FnParam) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = fp.name });
    try o.put(allocator, "ty", try encodeType(allocator, fp.ty));
    try o.put(allocator, "is_comptime", .{ .bool = fp.is_comptime });
    return .{ .object = o };
}

pub fn decodeFnParam(allocator: std.mem.Allocator, v: Json) anyerror!ast.FnParam {
    const o = try getObj(v);
    const name = try reqStr(o, "name");
    const ty = try decodeType(allocator, try req(o, "ty"));
    const is_comptime = if (o.get("is_comptime")) |b| (switch (b) {
        .bool => |x| x,
        else => false,
    }) else false;
    return .{
        .name = try allocator.dupe(u8, name),
        .ty = ty,
        .is_comptime = is_comptime,
    };
}

// ---------------------------------------------------------------------------
// Decl Serialization
// ---------------------------------------------------------------------------

pub fn encodeDecl(allocator: std.mem.Allocator, decl: ast.Decl) anyerror!Json {
    var o = ObjectMap.empty;
    switch (decl) {
        .struct_decl => |sd| {
            try o.put(allocator, "kind", .{ .string = "struct_decl" });
            var so = ObjectMap.empty;
            try so.put(allocator, "name", .{ .string = sd.name });
            try so.put(allocator, "is_pub", .{ .bool = sd.is_pub });
            try so.put(allocator, "is_tuple", .{ .bool = sd.is_tuple });

            var fields_arr = Array.init(allocator);
            for (sd.fields) |f| {
                try fields_arr.append(try encodeStructField(allocator, f));
            }
            try so.put(allocator, "fields", .{ .array = fields_arr });

            var decls_arr = Array.init(allocator);
            for (sd.decls) |d| {
                try decls_arr.append(try encodeDecl(allocator, d));
            }
            try so.put(allocator, "decls", .{ .array = decls_arr });

            var gps_arr = Array.init(allocator);
            for (sd.generic_params) |gp| {
                try gps_arr.append(try encodeGenericParam(allocator, gp));
            }
            try so.put(allocator, "generic_params", .{ .array = gps_arr });

            try o.put(allocator, "value", .{ .object = so });
        },
        .enum_decl => |ed| {
            try o.put(allocator, "kind", .{ .string = "enum_decl" });
            var eo = ObjectMap.empty;
            try eo.put(allocator, "name", .{ .string = ed.name });
            try eo.put(allocator, "is_pub", .{ .bool = ed.is_pub });
            if (ed.tag_type) |tt| {
                try eo.put(allocator, "tag_type", try encodeType(allocator, tt));
            } else {
                try eo.put(allocator, "tag_type", .{ .null = {} });
            }

            var vars_arr = Array.init(allocator);
            for (ed.variants) |vr| {
                try vars_arr.append(try encodeEnumVariant(allocator, vr));
            }
            try eo.put(allocator, "variants", .{ .array = vars_arr });

            var decls_arr = Array.init(allocator);
            for (ed.decls) |d| {
                try decls_arr.append(try encodeDecl(allocator, d));
            }
            try eo.put(allocator, "decls", .{ .array = decls_arr });

            try o.put(allocator, "value", .{ .object = eo });
        },
        .union_decl => |ud| {
            try o.put(allocator, "kind", .{ .string = "union_decl" });
            var uo = ObjectMap.empty;
            try uo.put(allocator, "name", .{ .string = ud.name });
            try uo.put(allocator, "is_pub", .{ .bool = ud.is_pub });
            if (ud.tag_type) |tt| {
                try uo.put(allocator, "tag_type", try encodeType(allocator, tt));
            } else {
                try uo.put(allocator, "tag_type", .{ .null = {} });
            }

            var fields_arr = Array.init(allocator);
            for (ud.fields) |f| {
                try fields_arr.append(try encodeUnionField(allocator, f));
            }
            try uo.put(allocator, "fields", .{ .array = fields_arr });

            var decls_arr = Array.init(allocator);
            for (ud.decls) |d| {
                try decls_arr.append(try encodeDecl(allocator, d));
            }
            try uo.put(allocator, "decls", .{ .array = decls_arr });

            try o.put(allocator, "value", .{ .object = uo });
        },
        .fn_decl => |fd| {
            try o.put(allocator, "kind", .{ .string = "fn_decl" });
            var fo = ObjectMap.empty;
            try fo.put(allocator, "name", .{ .string = fd.name });
            try fo.put(allocator, "is_pub", .{ .bool = fd.is_pub });
            try fo.put(allocator, "is_test", .{ .bool = fd.is_test });

            var params_arr = Array.init(allocator);
            for (fd.params) |p| {
                try params_arr.append(try encodeFnParam(allocator, p));
            }
            try fo.put(allocator, "params", .{ .array = params_arr });

            try fo.put(allocator, "ret_type", try encodeType(allocator, fd.ret_type));
            if (fd.body) |body| {
                try fo.put(allocator, "body", try encodeBlock(allocator, body));
            } else {
                try fo.put(allocator, "body", .{ .null = {} });
            }

            var gps_arr = Array.init(allocator);
            for (fd.generic_params) |gp| {
                try gps_arr.append(try encodeGenericParam(allocator, gp));
            }
            try fo.put(allocator, "generic_params", .{ .array = gps_arr });

            try o.put(allocator, "value", .{ .object = fo });
        },
        .const_decl => |cd| {
            try o.put(allocator, "kind", .{ .string = "const_decl" });
            var co = ObjectMap.empty;
            try co.put(allocator, "name", .{ .string = cd.name });
            try co.put(allocator, "is_pub", .{ .bool = cd.is_pub });
            if (cd.ty) |ty| {
                try co.put(allocator, "ty", try encodeType(allocator, ty));
            } else {
                try co.put(allocator, "ty", .{ .null = {} });
            }
            try co.put(allocator, "init", try encodeExpr(allocator, cd.init));
            try o.put(allocator, "value", .{ .object = co });
        },
        .var_decl => |vd| {
            try o.put(allocator, "kind", .{ .string = "var_decl" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "name", .{ .string = vd.name });
            try vo.put(allocator, "is_pub", .{ .bool = vd.is_pub });
            try vo.put(allocator, "is_mut", .{ .bool = vd.is_mut });
            if (vd.ty) |ty| {
                try vo.put(allocator, "ty", try encodeType(allocator, ty));
            } else {
                try vo.put(allocator, "ty", .{ .null = {} });
            }
            try vo.put(allocator, "init", try encodeExpr(allocator, vd.init));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .comment => |c| {
            try o.put(allocator, "kind", .{ .string = "comment" });
            try o.put(allocator, "value", .{ .string = c });
        },
    }
    return .{ .object = o };
}

pub fn decodeDecl(allocator: std.mem.Allocator, v: Json) anyerror!ast.Decl {
    const o = try getObj(v);
    const kind = try reqStr(o, "kind");

    if (std.mem.eql(u8, kind, "struct_decl")) {
        const so = try getObj(try req(o, "value"));
        const name = try reqStr(so, "name");
        const is_pub = if (so.get("is_pub")) |b| (switch (b) {
            .bool => |x| x,
            else => true,
        }) else true;
        const is_tuple = if (so.get("is_tuple")) |b| (switch (b) {
            .bool => |x| x,
            else => false,
        }) else false;

        const fields_v = try req(so, "fields");
        const fields_arr = switch (fields_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var fields_list: std.ArrayListUnmanaged(ast.StructField) = .empty;
        for (fields_arr.items) |item| {
            try fields_list.append(allocator, try decodeStructField(allocator, item));
        }

        const decls_v = try req(so, "decls");
        const decls_arr = switch (decls_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var decls_list: std.ArrayListUnmanaged(ast.Decl) = .empty;
        for (decls_arr.items) |item| {
            try decls_list.append(allocator, try decodeDecl(allocator, item));
        }

        const gps_arr = if (so.get("generic_params")) |gp_v| (switch (gp_v) {
            .array => |a| a,
            else => Array.init(allocator),
        }) else Array.init(allocator);
        var gps_list: std.ArrayListUnmanaged(ast.GenericParam) = .empty;
        for (gps_arr.items) |item| {
            try gps_list.append(allocator, try decodeGenericParam(allocator, item));
        }

        return .{
            .struct_decl = .{
                .name = try allocator.dupe(u8, name),
                .is_pub = is_pub,
                .is_tuple = is_tuple,
                .fields = try fields_list.toOwnedSlice(allocator),
                .decls = try decls_list.toOwnedSlice(allocator),
                .generic_params = try gps_list.toOwnedSlice(allocator),
            },
        };
    } else if (std.mem.eql(u8, kind, "enum_decl")) {
        const eo = try getObj(try req(o, "value"));
        const name = try reqStr(eo, "name");
        const is_pub = if (eo.get("is_pub")) |b| (switch (b) {
            .bool => |x| x,
            else => true,
        }) else true;
        const tag_type = if (eo.get("tag_type")) |tt| (switch (tt) {
            .null => null,
            else => try decodeType(allocator, tt),
        }) else null;

        const vars_v = try req(eo, "variants");
        const vars_arr = switch (vars_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var vars_list: std.ArrayListUnmanaged(ast.EnumVariant) = .empty;
        for (vars_arr.items) |item| {
            try vars_list.append(allocator, try decodeEnumVariant(allocator, item));
        }

        const decls_v = try req(eo, "decls");
        const decls_arr = switch (decls_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var decls_list: std.ArrayListUnmanaged(ast.Decl) = .empty;
        for (decls_arr.items) |item| {
            try decls_list.append(allocator, try decodeDecl(allocator, item));
        }

        return .{
            .enum_decl = .{
                .name = try allocator.dupe(u8, name),
                .is_pub = is_pub,
                .tag_type = tag_type,
                .variants = try vars_list.toOwnedSlice(allocator),
                .decls = try decls_list.toOwnedSlice(allocator),
            },
        };
    } else if (std.mem.eql(u8, kind, "union_decl")) {
        const uo = try getObj(try req(o, "value"));
        const name = try reqStr(uo, "name");
        const is_pub = if (uo.get("is_pub")) |b| (switch (b) {
            .bool => |x| x,
            else => true,
        }) else true;
        const tag_type = if (uo.get("tag_type")) |tt| (switch (tt) {
            .null => null,
            else => try decodeType(allocator, tt),
        }) else null;

        const fields_v = try req(uo, "fields");
        const fields_arr = switch (fields_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var fields_list: std.ArrayListUnmanaged(ast.UnionField) = .empty;
        for (fields_arr.items) |item| {
            try fields_list.append(allocator, try decodeUnionField(allocator, item));
        }

        const decls_v = try req(uo, "decls");
        const decls_arr = switch (decls_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var decls_list: std.ArrayListUnmanaged(ast.Decl) = .empty;
        for (decls_arr.items) |item| {
            try decls_list.append(allocator, try decodeDecl(allocator, item));
        }

        return .{
            .union_decl = .{
                .name = try allocator.dupe(u8, name),
                .is_pub = is_pub,
                .tag_type = tag_type,
                .fields = try fields_list.toOwnedSlice(allocator),
                .decls = try decls_list.toOwnedSlice(allocator),
            },
        };
    } else if (std.mem.eql(u8, kind, "fn_decl")) {
        const fo = try getObj(try req(o, "value"));
        const name = try reqStr(fo, "name");
        const is_pub = if (fo.get("is_pub")) |b| (switch (b) {
            .bool => |x| x,
            else => true,
        }) else true;
        const is_test = if (fo.get("is_test")) |b| (switch (b) {
            .bool => |x| x,
            else => false,
        }) else false;

        const params_v = try req(fo, "params");
        const params_arr = switch (params_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var params_list: std.ArrayListUnmanaged(ast.FnParam) = .empty;
        for (params_arr.items) |item| {
            try params_list.append(allocator, try decodeFnParam(allocator, item));
        }

        const ret_type = try decodeType(allocator, try req(fo, "ret_type"));
        const body = if (fo.get("body")) |bv| (switch (bv) {
            .null => null,
            else => try decodeBlock(allocator, bv),
        }) else null;

        const gps_arr = if (fo.get("generic_params")) |gp_v| (switch (gp_v) {
            .array => |a| a,
            else => Array.init(allocator),
        }) else Array.init(allocator);
        var gps_list: std.ArrayListUnmanaged(ast.GenericParam) = .empty;
        for (gps_arr.items) |item| {
            try gps_list.append(allocator, try decodeGenericParam(allocator, item));
        }

        return .{
            .fn_decl = .{
                .name = try allocator.dupe(u8, name),
                .is_pub = is_pub,
                .is_test = is_test,
                .params = try params_list.toOwnedSlice(allocator),
                .ret_type = ret_type,
                .body = body,
                .generic_params = try gps_list.toOwnedSlice(allocator),
            },
        };
    } else if (std.mem.eql(u8, kind, "const_decl")) {
        const co = try getObj(try req(o, "value"));
        const name = try reqStr(co, "name");
        const is_pub = if (co.get("is_pub")) |b| (switch (b) {
            .bool => |x| x,
            else => true,
        }) else true;
        const ty = if (co.get("ty")) |ty_v| (switch (ty_v) {
            .null => null,
            else => try decodeType(allocator, ty_v),
        }) else null;
        const init = try decodeExpr(allocator, try req(co, "init"));

        return .{
            .const_decl = .{
                .name = try allocator.dupe(u8, name),
                .is_pub = is_pub,
                .ty = ty,
                .init = init,
            },
        };
    } else if (std.mem.eql(u8, kind, "var_decl")) {
        const vo = try getObj(try req(o, "value"));
        const name = try reqStr(vo, "name");
        const is_pub = if (vo.get("is_pub")) |b| (switch (b) {
            .bool => |x| x,
            else => true,
        }) else true;
        const is_mut = if (vo.get("is_mut")) |b| (switch (b) {
            .bool => |x| x,
            else => true,
        }) else true;
        const ty = if (vo.get("ty")) |ty_v| (switch (ty_v) {
            .null => null,
            else => try decodeType(allocator, ty_v),
        }) else null;
        const init = try decodeExpr(allocator, try req(vo, "init"));

        return .{
            .var_decl = .{
                .name = try allocator.dupe(u8, name),
                .is_pub = is_pub,
                .is_mut = is_mut,
                .ty = ty,
                .init = init,
            },
        };
    } else if (std.mem.eql(u8, kind, "comment")) {
        const c = try reqStr(o, "value");
        return .{ .comment = try allocator.dupe(u8, c) };
    }

    return error.UnknownDeclKind;
}

// ---------------------------------------------------------------------------
// Import, TestDecl, File, ZonDep, Package Serialization
// ---------------------------------------------------------------------------

pub fn encodeImport(allocator: std.mem.Allocator, imp: ast.Import) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "local_name", .{ .string = imp.local_name });
    try o.put(allocator, "module_or_path", .{ .string = imp.module_or_path });
    try o.put(allocator, "is_pub", .{ .bool = imp.is_pub });
    return .{ .object = o };
}

pub fn decodeImport(allocator: std.mem.Allocator, v: Json) anyerror!ast.Import {
    const o = try getObj(v);
    const local_name = try reqStr(o, "local_name");
    const module_or_path = try reqStr(o, "module_or_path");
    const is_pub = if (o.get("is_pub")) |b| (switch (b) {
        .bool => |x| x,
        else => false,
    }) else false;
    return .{
        .local_name = try allocator.dupe(u8, local_name),
        .module_or_path = try allocator.dupe(u8, module_or_path),
        .is_pub = is_pub,
    };
}

pub fn encodeTestDecl(allocator: std.mem.Allocator, td: ast.TestDecl) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = td.name });
    try o.put(allocator, "body", try encodeBlock(allocator, td.body));
    return .{ .object = o };
}

pub fn decodeTestDecl(allocator: std.mem.Allocator, v: Json) anyerror!ast.TestDecl {
    const o = try getObj(v);
    const name = try reqStr(o, "name");
    const body = try decodeBlock(allocator, try req(o, "body"));
    return .{
        .name = try allocator.dupe(u8, name),
        .body = body,
    };
}

pub fn encodeFile(allocator: std.mem.Allocator, f: ast.File) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "path", .{ .string = f.path });

    var imps_arr = Array.init(allocator);
    for (f.imports) |imp| {
        try imps_arr.append(try encodeImport(allocator, imp));
    }
    try o.put(allocator, "imports", .{ .array = imps_arr });

    var decls_arr = Array.init(allocator);
    for (f.decls) |d| {
        try decls_arr.append(try encodeDecl(allocator, d));
    }
    try o.put(allocator, "decls", .{ .array = decls_arr });

    var tests_arr = Array.init(allocator);
    for (f.tests) |t| {
        try tests_arr.append(try encodeTestDecl(allocator, t));
    }
    try o.put(allocator, "tests", .{ .array = tests_arr });

    return .{ .object = o };
}

pub fn decodeFile(allocator: std.mem.Allocator, v: Json) anyerror!ast.File {
    const o = try getObj(v);
    const path = try reqStr(o, "path");

    const imps_v = try req(o, "imports");
    const imps_arr = switch (imps_v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var imps_list: std.ArrayListUnmanaged(ast.Import) = .empty;
    for (imps_arr.items) |item| {
        try imps_list.append(allocator, try decodeImport(allocator, item));
    }

    const decls_v = try req(o, "decls");
    const decls_arr = switch (decls_v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var decls_list: std.ArrayListUnmanaged(ast.Decl) = .empty;
    for (decls_arr.items) |item| {
        try decls_list.append(allocator, try decodeDecl(allocator, item));
    }

    const tests_v = try req(o, "tests");
    const tests_arr = switch (tests_v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var tests_list: std.ArrayListUnmanaged(ast.TestDecl) = .empty;
    for (tests_arr.items) |item| {
        try tests_list.append(allocator, try decodeTestDecl(allocator, item));
    }

    return .{
        .path = try allocator.dupe(u8, path),
        .imports = try imps_list.toOwnedSlice(allocator),
        .decls = try decls_list.toOwnedSlice(allocator),
        .tests = try tests_list.toOwnedSlice(allocator),
    };
}

pub fn encodeZonDep(allocator: std.mem.Allocator, zd: ast.ZonDep) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = zd.name });
    try o.put(allocator, "url", .{ .string = zd.url });
    try o.put(allocator, "hash", .{ .string = zd.hash });
    return .{ .object = o };
}

pub fn decodeZonDep(allocator: std.mem.Allocator, v: Json) anyerror!ast.ZonDep {
    const o = try getObj(v);
    const name = try reqStr(o, "name");
    const url = if (try optStr(o, "url")) |u| try allocator.dupe(u8, u) else "";
    const hash = if (try optStr(o, "hash")) |h| try allocator.dupe(u8, h) else "";
    return .{
        .name = try allocator.dupe(u8, name),
        .url = url,
        .hash = hash,
    };
}

pub fn encodePackage(allocator: std.mem.Allocator, pkg: ast.Package) anyerror!Json {
    var root_map = ObjectMap.empty;
    try root_map.put(allocator, "format_version", mkInt(format_version));
    try root_map.put(allocator, "name", .{ .string = pkg.name });
    try root_map.put(allocator, "version", .{ .string = pkg.version });
    if (pkg.fingerprint) |fp| {
        const fp_str = try std.fmt.allocPrint(allocator, "{d}", .{fp});
        try root_map.put(allocator, "fingerprint", .{ .string = fp_str });
    } else {
        try root_map.put(allocator, "fingerprint", .{ .null = {} });
    }

    var files_arr = Array.init(allocator);
    for (pkg.files) |f| {
        try files_arr.append(try encodeFile(allocator, f));
    }
    try root_map.put(allocator, "files", .{ .array = files_arr });

    var deps_arr = Array.init(allocator);
    for (pkg.zon_deps) |zd| {
        try deps_arr.append(try encodeZonDep(allocator, zd));
    }
    try root_map.put(allocator, "zon_deps", .{ .array = deps_arr });

    return .{ .object = root_map };
}

pub fn decodePackage(allocator: std.mem.Allocator, v: Json) anyerror!ast.Package {
    const o = try getObj(v);
    const ver = try reqU32(o, "format_version");
    if (ver != format_version) return error.InvalidFormatVersion;

    const name = try reqStr(o, "name");
    const version = if (try optStr(o, "version")) |ver_str| try allocator.dupe(u8, ver_str) else "0.0.0";
    const fingerprint = try optU64(o, "fingerprint");

    const files_v = try req(o, "files");
    const files_arr = switch (files_v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var files_list: std.ArrayListUnmanaged(ast.File) = .empty;
    for (files_arr.items) |item| {
        try files_list.append(allocator, try decodeFile(allocator, item));
    }

    const deps_v = if (o.get("zon_deps")) |zd_val| zd_val else Json{ .array = Array.init(allocator) };
    const deps_arr = switch (deps_v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var deps_list: std.ArrayListUnmanaged(ast.ZonDep) = .empty;
    for (deps_arr.items) |item| {
        try deps_list.append(allocator, try decodeZonDep(allocator, item));
    }

    return .{
        .name = try allocator.dupe(u8, name),
        .version = version,
        .fingerprint = fingerprint,
        .files = try files_list.toOwnedSlice(allocator),
        .zon_deps = try deps_list.toOwnedSlice(allocator),
    };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Encode a `Package` AST instance into a JSON string.
/// The returned slice is allocated with `allocator` and must be freed by caller.
pub fn encode(allocator: std.mem.Allocator, pkg: *const ast.Package) ![]const u8 {
    var root_val = try encodePackage(allocator, pkg.*);
    defer freeValue(allocator, &root_val);

    return std.json.Stringify.valueAlloc(allocator, root_val, .{ .whitespace = .indent_2 });
}

/// Convenience value-taking encode.
pub fn encodeVal(allocator: std.mem.Allocator, pkg: ast.Package) ![]const u8 {
    return encode(allocator, &pkg);
}

/// Decode a JSON string into an `ast.Package` instance.
/// Allocations made during decoding use `allocator`.
pub fn decode(allocator: std.mem.Allocator, json_bytes: []const u8) !ast.Package {
    var parsed = std.json.parseFromSlice(Json, allocator, json_bytes, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    return decodePackage(allocator, parsed.value);
}

pub const serialize = encodeVal;
pub const deserialize = decode;
