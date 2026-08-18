//! translate_rust.model.driver — direct Rust-source → package driver.
//!
//! `translate(<crate-dir>, <out-dir>)` shells out to the v0 sidecar producer
//! (`tools/sidecar/rustdoc-json.sh` — rustdoc `--output-format json`,
//! format_version 60) to obtain raw rustdoc JSON for a Cargo package, then
//! maps its REAL items and types into the wire model (`CrateGraph` + `Bodies`)
//! and emits the standalone `r2z-<crate>/` package via `package.generatePackage`.
//!
//! Unlike the earlier skeleton, the generated package carries real `struct`
//! definitions (named fields, tuple/unit layouts), `enum` definitions
//! (C-like and data-carrying variants), `pub fn` signatures (params + return
//! type, empty body block since rustdoc carries no fn bodies), typed `const`s
//! with simple literal inits, `type_alias` bodies, and `pub use` re-exports.
//!
//! This is deliberately BEST-EFFORT: anything rustdoc yields that does not map
//! cheaply (generic params, unmappable type positions, non-literal const
//! exprs, cross-crate / unresolvable imports) degrades to `// unsupported`
//! markers or is skipped rather than crashing. If rustdoc yields no parseable
//! items (or the toolchain is missing), it still emits the package skeleton.

const std = @import("std");
const spine = @import("spine.zig");
const graph = @import("graph.zig");
const package = @import("package.zig");
const items = @import("items.zig");
const types = @import("types.zig");
const exprs = @import("exprs.zig");
const emit = @import("emit.zig");

const Span = spine.Span;
const EntityId = spine.EntityId;

const default_span: Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };
/// The synthetic module under which rustdoc/`mod error;` parent error enums;
/// emit.zig lowers error-set enums found here to Zig `error{...}` sets.
const error_module_name = "error";

/// Read a whole file into `allocator` (caller owns the returned slice).
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

/// Parse `Cargo.toml` `[package] name = "..."` (line-based, comment-aware,
/// best-effort). The returned slice is owned by `allocator`.
fn crateNameFromManifestImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
) ![]const u8 {
    const cargo_path = try std.fs.path.join(allocator, &.{ dir, "Cargo.toml" });
    defer allocator.free(cargo_path);

    const bytes = try readFileAlloc(allocator, io, cargo_path);
    defer allocator.free(bytes);

    var it = std.mem.splitScalar(u8, bytes, '\n');
    var in_pkg = false;
    while (it.next()) |raw_line| {
        // Strip trailing comment and surrounding whitespace.
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            const section = std.mem.trim(u8, line, "[] \t");
            in_pkg = std.mem.eql(u8, section, "package");
            continue;
        }
        if (!in_pkg) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, key, "name")) continue;

        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        var val_it = std.mem.splitScalar(u8, val, '"');
        _ = val_it.next(); // discard anything before the opening quote
        if (val_it.next()) |name| return allocator.dupe(u8, name);
        return error.CargoManifestMissingName;
    }
    return error.CargoManifestMissingPackageSection;
}

fn crateNameFromManifestPage(io: std.Io, dir: []const u8) anyerror![]const u8 {
    return crateNameFromManifestImpl(std.heap.page_allocator, io, dir);
}

/// Best-effort crate-name extraction, exposed with the required fn-pointer
/// shape. Page-allocated (caller frees); the driver uses the allocator-aware
/// implementation directly to avoid leaking.
pub const crate_name_from_manifest: *const fn (io: std.Io, dir: []const u8) anyerror![]const u8 =
    &crateNameFromManifestPage;

/// Returns the raw JSON value for `key` on object `v`, or null if absent.
fn getField(v: std.json.Value, key: []const u8) !?std.json.Value {
    if (v != .object) return error.RustdocNotObject;
    return v.object.get(key);
}

/// Best-effort source span from a rustdoc item (`span.begin/end = [line, col]`,
/// 1-based). Drops to the default span when absent or malformed.
fn spanFromJson(v: std.json.Value) Span {
    if (v == .object) {
        if (v.object.get("span")) |sp| {
            if (sp == .object) {
                if (sp.object.get("begin")) |b| {
                    if (b == .array and b.array.items.len >= 2 and
                        b.array.items[0] == .integer and b.array.items[1] == .integer)
                    {
                        var end_line: u32 = @intCast(b.array.items[0].integer);
                        var end_col: u32 = @intCast(b.array.items[1].integer);
                        if (sp.object.get("end")) |e| {
                            if (e == .array and e.array.items.len >= 2 and
                                e.array.items[0] == .integer and e.array.items[1] == .integer)
                            {
                                end_line = @intCast(e.array.items[0].integer);
                                end_col = @intCast(e.array.items[1].integer);
                            }
                        }
                        return .{
                            .start_line = @intCast(b.array.items[0].integer),
                            .start_col = @intCast(b.array.items[1].integer),
                            .end_line = end_line,
                            .end_col = end_col,
                        };
                    }
                }
            }
        }
    }
    return default_span;
}

/// rustdoc `visibility` string → spine.Visibility (public/private only; the
/// finer Rust lattice is reduced here — the emitter only needs pub/private).
fn visFromJson(v: std.json.Value) spine.Visibility {
    if (v == .string and std.mem.eql(u8, v.string, "public")) return .public;
    return .private;
}

// ── rustdoc → wire Type mapper ────────────────────────────────────────────
//
// rustdoc type JSON is `{ "<tag>": <payload> }`. We map the cheap, common
// subset (primitives, resolved paths, slices, arrays, references, tuples);
// everything else degrades to `.unsupported`. Compound types carry pointers
// into the arena (allocated with `arena.create`); the caller passes the model
// allocator (an ArenaAllocator), so no per-node free is required.

fn unsupportedType() types.Type {
    return .{ .unsupported = .{
        .reason = .std_prelude,
        .message = "rustdoc type not mapped",
        .span = default_span,
    } };
}

/// "u8".."f64", "bool", "char", "unit", "never" → Prim; else null.
fn mapPrim(name: []const u8) ?types.Prim {
    if (std.mem.eql(u8, name, "i8")) return .i8;
    if (std.mem.eql(u8, name, "i16")) return .i16;
    if (std.mem.eql(u8, name, "i32")) return .i32;
    if (std.mem.eql(u8, name, "i64")) return .i64;
    if (std.mem.eql(u8, name, "i128")) return .i128;
    if (std.mem.eql(u8, name, "u8")) return .u8;
    if (std.mem.eql(u8, name, "u16")) return .u16;
    if (std.mem.eql(u8, name, "u32")) return .u32;
    if (std.mem.eql(u8, name, "u64")) return .u64;
    if (std.mem.eql(u8, name, "u128")) return .u128;
    if (std.mem.eql(u8, name, "isize")) return .isize;
    if (std.mem.eql(u8, name, "usize")) return .usize;
    if (std.mem.eql(u8, name, "f32")) return .f32;
    if (std.mem.eql(u8, name, "f64")) return .f64;
    if (std.mem.eql(u8, name, "bool")) return .bool;
    if (std.mem.eql(u8, name, "char")) return .char;
    if (std.mem.eql(u8, name, "unit") or std.mem.eql(u8, name, "()")) return .unit;
    if (std.mem.eql(u8, name, "never") or std.mem.eql(u8, name, "!")) return .never;
    return null;
}

fn mapRustdocType(
    arena: std.mem.Allocator,
    tv: std.json.Value,
) types.Type {
    if (tv != .object) return unsupportedType();
    var it = tv.object.iterator();
    const kv = it.next() orelse return unsupportedType();
    const tag = kv.key_ptr.*;
    const payload = kv.value_ptr.*;

    if (std.mem.eql(u8, tag, "primitive")) {
        if (payload == .string) {
            if (std.mem.eql(u8, payload.string, "str")) {
                const s = arena.create(types.Slice) catch return unsupportedType();
                s.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
                return .{ .slice = s };
            }
            if (mapPrim(payload.string)) |p| return .{ .prim = p };
        }
        return unsupportedType();
    }

    if (std.mem.eql(u8, tag, "resolved_path")) {
        var segs: std.ArrayListUnmanaged(types.PathSegment) = .empty;
        if (payload == .object) {
            if (payload.object.get("path")) |p| {
                if (p == .string) {
                    var seg_it = std.mem.splitScalar(u8, p.string, ':');
                    while (seg_it.next()) |seg| {
                        if (seg.len == 0) continue; // drop leading "::"
                        segs.append(arena, .{ .name = seg, .id = null }) catch return unsupportedType();
                    }
                }
            }
        }
        if (segs.items.len == 0) return unsupportedType();
        return .{ .path = .{ .segments = segs.toOwnedSlice(arena) catch return unsupportedType() } };
    }

    if (std.mem.eql(u8, tag, "borrowed_ref") or std.mem.eql(u8, tag, "raw_pointer")) {
        var mut = false;
        var pointee: types.Type = unsupportedType();
        if (payload == .object) {
            if (payload.object.get("is_mutable")) |m| {
                if (m == .bool) mut = m.bool;
            }
            if (payload.object.get("type")) |t| pointee = mapRustdocType(arena, t);
        }
        if (std.mem.eql(u8, tag, "raw_pointer")) {
            const rp = arena.create(types.RawPtr) catch return unsupportedType();
            rp.* = .{ .mut = mut, .pointee = pointee };
            return .{ .raw_ptr = rp };
        }
        // Rust `&str` or `&[T]` is already a fat slice in Zig (`[]const T`), not a pointer to a slice.
        if (pointee == .slice) return pointee;
        const r = arena.create(types.Ref) catch return unsupportedType();
        r.* = .{ .mut = mut, .pointee = pointee };
        return .{ .reference = r };
    }

    if (std.mem.eql(u8, tag, "slice")) {
        const elem = mapRustdocType(arena, payload);
        const s = arena.create(types.Slice) catch return unsupportedType();
        s.* = .{ .const_ = true, .elem = elem };
        return .{ .slice = s };
    }

    if (std.mem.eql(u8, tag, "array")) {
        var elem: types.Type = unsupportedType();
        var len: u32 = 0;
        if (payload == .object) {
            if (payload.object.get("type")) |t| elem = mapRustdocType(arena, t);
            if (payload.object.get("len")) |l| {
                if (l == .string) len = std.fmt.parseInt(u32, l.string, 10) catch 0;
            }
        }
        const a = arena.create(types.Array) catch return unsupportedType();
        a.* = .{ .elem = elem, .len = .{ .literal = len } };
        return .{ .array = a };
    }

    if (std.mem.eql(u8, tag, "tuple")) {
        if (payload == .array) {
            if (payload.array.items.len == 0) return .{ .prim = .unit };
            var tup: std.ArrayListUnmanaged(types.Type) = .empty;
            for (payload.array.items) |t| {
                tup.append(arena, mapRustdocType(arena, t)) catch return unsupportedType();
            }
            return .{ .tuple = tup.toOwnedSlice(arena) catch return unsupportedType() };
        }
        return .{ .prim = .unit };
    }

    return unsupportedType();
}

// ── const-init literal mapping ────────────────────────────────────────────
//
// rustdoc constants carry their source expression as text (`inner.<k>.const.
// expr`). We map only trivially-parsable literals (bool, char, string,
// byte-string, integer) into expression nodes; anything else causes the
// constant to be skipped (its body cannot lower without a real expression
// model, and a placeholder would break the emitted file's syntax).

/// Decode a Rust string/byte-string body (escapes: \n \t \r \0 \\ \' \" \xNN).
/// Returns `error.UnknownEscape` on unknown escapes (caller skips the constant).
fn decodeStringBody(arena: std.mem.Allocator, in: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < in.len) {
        const c = in[i];
        if (c == '\\' and i + 1 < in.len) {
            const e = in[i + 1];
            switch (e) {
                'n' => try out.append(arena, '\n'),
                't' => try out.append(arena, '\t'),
                'r' => try out.append(arena, '\r'),
                '0' => try out.append(arena, 0),
                '\\' => try out.append(arena, '\\'),
                '\'' => try out.append(arena, '\''),
                '"' => try out.append(arena, '"'),
                'x' => {
                    if (i + 3 < in.len) {
                        const hi = std.fmt.charToDigit(in[i + 2], 16) catch return error.UnknownEscape;
                        const lo = std.fmt.charToDigit(in[i + 3], 16) catch return error.UnknownEscape;
                        try out.append(arena, @as(u8, hi * 16 + lo));
                        i += 2;
                    } else return error.UnknownEscape;
                },
                else => return error.UnknownEscape,
            }
            i += 2;
        } else {
            try out.append(arena, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(arena);
}

/// Try to map a rustdoc const `expr` source string to an expression node that
/// the v1 emitter can lower. Returns null when the expr is not a trivial
/// literal (caller should skip the constant).
fn mapConstLiteral(arena: std.mem.Allocator, expr_str: []const u8) ?exprs.Expr {
    const s = std.mem.trim(u8, expr_str, " \t\r\n");
    const span = default_span;
    if (s.len == 0) return null;

    if (std.mem.eql(u8, s, "true")) {
        return .{ .id = 0, .span = span, .ty = null, .kind = .{ .literal = .{ .boolean = true } } };
    }
    if (std.mem.eql(u8, s, "false")) {
        return .{ .id = 0, .span = span, .ty = null, .kind = .{ .literal = .{ .boolean = false } } };
    }

    // Byte string `b"..."`.
    if (s.len >= 3 and std.mem.startsWith(u8, s, "b\"") and s[s.len - 1] == '"') {
        const body = decodeStringBody(arena, s[2 .. s.len - 1]) catch return null;
        return .{ .id = 0, .span = span, .ty = null, .kind = .{ .literal = .{ .byte_array = .{ .items = body } } } };
    }

    // Plain string `"..."`.
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        const body = decodeStringBody(arena, s[1 .. s.len - 1]) catch return null;
        return .{ .id = 0, .span = span, .ty = null, .kind = .{ .literal = .{ .string = .{ .bytes = body } } } };
    }

    // Character `'x'`.
    if (s.len >= 3 and s[0] == '\'' and s[s.len - 1] == '\'') {
        const body = s[1 .. s.len - 1];
        var ch: u32 = 0;
        if (body.len == 1) {
            ch = body[0];
        } else if (body.len == 2 and body[0] == '\\') {
            switch (body[1]) {
                'n' => ch = '\n',
                't' => ch = '\t',
                'r' => ch = '\r',
                '0' => ch = 0,
                '\\' => ch = '\\',
                '\'' => ch = '\'',
                '"' => ch = '"',
                else => return null,
            }
        } else if (body.len == 5 and std.mem.startsWith(u8, body, "\\u{")) {
            const hex = body[3 .. body.len - 1];
            if (hex.len >= 1 and hex[hex.len - 1] == '}') {
                ch = std.fmt.parseInt(u32, hex[0 .. hex.len - 1], 16) catch return null;
            } else return null;
        } else return null;
        return .{ .id = 0, .span = span, .ty = null, .kind = .{ .literal = .{ .character = .{ .text = s, .value = ch } } } };
    }

    // Integer literal (optional sign + 0x/0o/0b prefix + optional type suffix).
    {
        var body = s;
        var neg = false;
        if (body.len > 0 and body[0] == '-') {
            neg = true;
            body = body[1..];
        } else if (body.len > 0 and body[0] == '+') {
            body = body[1..];
        }
        var base: u8 = 10;
        if (body.len >= 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'X')) {
            base = 16;
            body = body[2..];
        } else if (body.len >= 2 and body[0] == '0' and (body[1] == 'o' or body[1] == 'O')) {
            base = 8;
            body = body[2..];
        } else if (body.len >= 2 and body[0] == '0' and (body[1] == 'b' or body[1] == 'B')) {
            base = 2;
            body = body[2..];
        }
        var end: usize = 0;
        while (end < body.len) : (end += 1) {
            const c = body[end];
            const is_digit = switch (base) {
                16 => std.ascii.isHex(c),
                8 => c >= '0' and c <= '7',
                2 => c == '0' or c == '1',
                else => std.ascii.isDigit(c),
            };
            if (!is_digit and c != '_') break;
        }
        if (end == 0) return null;
        const cleaned = std.mem.trim(u8, body[0..end], "_");
        if (cleaned.len == 0) return null;
        const value = (std.fmt.parseInt(i128, cleaned, base) catch return null) * @as(i128, if (neg) -1 else 1);
        // Reconstruct a Zig-valid literal (emitted verbatim): keep the sign +
        // base prefix + digit run, dropping any int-type suffix (e.g. "10u64").
        const prefix = s[0 .. s.len - body.len]; // sign + base prefix (if any)
        const text = std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, body[0..end] }) catch return null;
        return .{ .id = 0, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = text,
            .value = value,
            .base = switch (base) {
                16 => .hex,
                8 => .oct,
                2 => .bin,
                else => .dec,
            },
            .ty_suffix = null,
        } } } };
    }
}

// ── item mapping ──────────────────────────────────────────────────────────

/// Map a rustdoc `inner.kind` tag to an EntityKind the v1 emitter handles,
/// or null if the item should be skipped entirely (not even skeletoned).
fn rustdocKindToEntityKind(inner_key: []const u8) ?spine.EntityKind {
    if (std.mem.eql(u8, inner_key, "struct")) return .struct_;
    if (std.mem.eql(u8, inner_key, "enum")) return .enum_;
    if (std.mem.eql(u8, inner_key, "union")) return .union_;
    if (std.mem.eql(u8, inner_key, "function")) return .fn_;
    if (std.mem.eql(u8, inner_key, "constant")) return .const_;
    if (std.mem.eql(u8, inner_key, "static")) return .static_;
    if (std.mem.eql(u8, inner_key, "trait")) return .trait_;
    if (std.mem.eql(u8, inner_key, "type_alias")) return .type_alias;
    if (std.mem.eql(u8, inner_key, "macro")) return .macro_;
    return null;
}

/// Per-item mapping scratch state. All allocations come from the arena.
const State = struct {
    arena: std.mem.Allocator,
    g: *graph.CrateGraph,
    index: std.json.ObjectMap,
    /// rustdoc DefId (item id integer) → our dense EntityId.
    def_map: std.AutoHashMap(i64, spine.EntityId),
    /// Parallel to the symbol table: exprs for fn bodies / const inits.
    exprs: std.ArrayListUnmanaged(exprs.Expr),
    /// Parallel to the symbol table: one BodyKind per entity.
    bodies: std.ArrayListUnmanaged(emit.BodyKind),
};

/// Create an entity in the symbol table and push a matching `.none` body slot.
fn addEntity(
    state: *State,
    kind: spine.EntityKind,
    name: []const u8,
    vis: spine.Visibility,
    span: Span,
    parent: ?spine.EntityId,
) !spine.EntityId {
    const duped = try state.arena.dupe(u8, name);
    const id = try state.g.symbol_table.add(.{
        .id = 0,
        .kind = kind,
        .name = duped,
        .span = span,
        .visibility = vis,
        .parent = parent,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try state.bodies.append(state.arena, .none);
    return id;
}

/// Append an expression node, returning its id.
fn appendExpr(state: *State, e: exprs.Expr) !exprs.NodeId {
    const id: exprs.NodeId = @intCast(state.exprs.items.len);
    var ee = e;
    ee.id = id;
    try state.exprs.append(state.arena, ee);
    return id;
}

/// Arena-allocated string key for a rustdoc item id (the `index` map is
/// string-keyed).
fn indexKey(state: *State, id: i64) ![]const u8 {
    return std.fmt.allocPrint(state.arena, "{d}", .{id});
}

/// Map the struct's fields from rustdoc field DefIds (each an index item whose
/// `inner.struct_field` is the field's type; the field name is the item's
/// `name`). `is_tuple` selects numeric tuple field naming.
fn mapFields(
    state: *State,
    field_ids_json: std.json.Value,
    is_tuple: bool,
) ![]const items.Field {
    if (field_ids_json != .array) return &.{};
    var out: std.ArrayListUnmanaged(items.Field) = .empty;
    for (field_ids_json.array.items, 0..) |fid_v, i| {
        if (fid_v != .integer) continue;
        const fitem = state.index.get(try indexKey(state, fid_v.integer)) orelse continue;
        if (fitem != .object) continue;
        const fname = if (is_tuple)
            try std.fmt.allocPrint(state.arena, "{d}", .{i})
        else if (fitem.object.get("name")) |n|
            (if (n == .string) n.string else "")
        else
            "";
        if (fname.len == 0) continue;
        var fty: types.Type = unsupportedType();
        if (fitem.object.get("inner")) |inner| {
            if (inner == .object) {
                if (inner.object.get("struct_field")) |sf| fty = mapRustdocType(state.arena, sf);
            }
        }
        try out.append(state.arena, .{
            .name = try state.arena.dupe(u8, fname),
            .ty = fty,
            // Zig struct fields are never `pub`; emit.zig's visPrefix would
            // render a `pub ` prefix for `.public` fields, which is invalid
            // inside a struct body. Always lower field visibility to private.
            .visibility = .private,
            .span = spanFromJson(fitem),
        });
    }
    return out.toOwnedSlice(state.arena);
}

/// Map a named rustdoc item (struct/enum/function/constant/static/type_alias/
/// module/other) into the graph + bodies. Returns the created entity id, or
/// null if the item should be skipped. `parent_mod` is the containing module
/// entity id (null for the crate root).
fn mapNamedItem(state: *State, item: std.json.Value, parent_mod: ?spine.EntityId) anyerror!?spine.EntityId {
    const name_v = item.object.get("name") orelse return null;
    if (name_v != .string) return null;
    const name = name_v.string;
    if (name.len == 0) return null;
    const vis = if (item.object.get("visibility")) |vv| visFromJson(vv) else .private;
    const span = spanFromJson(item);

    const inner = item.object.get("inner") orelse return null;
    if (inner != .object or inner.object.count() == 0) return null;
    var inner_it = inner.object.iterator();
    const kind_kv = inner_it.next() orelse return null;
    const kind_tag = kind_kv.key_ptr.*;
    const kind_payload = kind_kv.value_ptr.*;

    // ── struct → StructBody ─────────────────────────────────────────
    if (std.mem.eql(u8, kind_tag, "struct")) {
        var layout: items.struct_kind = .named;
        var fields: []const items.Field = &.{};
        if (kind_payload == .object) {
            if (kind_payload.object.get("kind")) |kind_v| {
                if (kind_v == .object) {
                    var kit = kind_v.object.iterator();
                    if (kit.next()) |sk| {
                        const sk_payload = sk.value_ptr.*;
                        if (std.mem.eql(u8, sk.key_ptr.*, "plain")) {
                            layout = .named;
                            if (sk_payload.object.get("fields")) |f| fields = try mapFields(state, f, false);
                        } else if (std.mem.eql(u8, sk.key_ptr.*, "tuple")) {
                            layout = .tuple;
                            fields = try mapFields(state, sk_payload, true);
                        } else {
                            layout = .unit;
                        }
                    }
                }
            }
        }
        const eid = try addEntity(state, .struct_, name, vis, span, parent_mod);
        state.bodies.items[eid] = .{ .struct_ = .{ .layout = layout, .fields = fields } };
        return eid;
    }

    // ── enum → EnumBody (+ variant entities for error-set enums) ────
    if (std.mem.eql(u8, kind_tag, "enum")) {
        var variants: std.ArrayListUnmanaged(items.Variant) = .empty;
        var all_plain = true;
        if (kind_payload == .object) {
            if (kind_payload.object.get("variants")) |variants_v| {
                if (variants_v == .array) {
                    for (variants_v.array.items) |vid_v| {
                        if (vid_v != .integer) continue;
                        const vitem = state.index.get(try indexKey(state, vid_v.integer)) orelse continue;
                        if (vitem != .object) continue;
                        const vname = if (vitem.object.get("name")) |n| (if (n == .string) n.string else "") else "";
                        if (vname.len == 0) continue;
                        var vfields: items.VariantFields = .none;
                        if (vitem.object.get("inner")) |vinner| {
                            if (vinner == .object) {
                                if (vinner.object.get("variant")) |var_v| {
                                    if (var_v == .object) {
                                        if (var_v.object.get("kind")) |vk| {
                                            if (vk == .object) {
                                                var vit = vk.object.iterator();
                                                if (vit.next()) |vkv| {
                                                    const vp = vkv.value_ptr.*;
                                                    if (std.mem.eql(u8, vkv.key_ptr.*, "tuple")) {
                                                        all_plain = false;
                                                        var tup: std.ArrayListUnmanaged(types.Type) = .empty;
                                                        if (vp == .array) {
                                                            for (vp.array.items) |tfv| {
                                                                if (tfv != .integer) continue;
                                                                const titem = state.index.get(try indexKey(state, tfv.integer)) orelse continue;
                                                                var tty: types.Type = unsupportedType();
                                                                if (titem.object.get("inner")) |ti| {
                                                                    if (ti == .object) {
                                                                        if (ti.object.get("struct_field")) |sf| tty = mapRustdocType(state.arena, sf);
                                                                    }
                                                                }
                                                                try tup.append(state.arena, tty);
                                                            }
                                                        }
                                                        vfields = .{ .tuple = tup.toOwnedSlice(state.arena) catch &.{} };
                                                    } else if (std.mem.eql(u8, vkv.key_ptr.*, "struct")) {
                                                        all_plain = false;
                                                        const named = if (vp == .object) blk: {
                                                            if (vp.object.get("fields")) |f| break :blk try mapFields(state, f, false) else break :blk &.{};
                                                        } else &.{};
                                                        vfields = .{ .named = named };
                                                    } // else: "plain" → .none
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        try variants.append(state.arena, .{
                            .name = try state.arena.dupe(u8, vname),
                            .fields = vfields,
                            .discriminant = null,
                        });
                    }
                }
            }
        }
        const eid = try addEntity(state, .enum_, name, vis, span, parent_mod);
        state.bodies.items[eid] = .{ .enum_ = .{
            .kind = if (all_plain) .c_like else .data,
            .variants = variants.toOwnedSlice(state.arena) catch &.{},
            .repr_int = null,
            .non_exhaustive = false,
        } };
        // An enum under the synthetic error module lowers to a Zig error set
        // (emit.zig `emitErrorSetDef`), which reads variants as *entities*.
        if (parent_mod != null and isErrorModule(state, parent_mod.?)) {
            for (state.bodies.items[eid].enum_.variants) |v| {
                _ = try addEntity(state, .variant, v.name, vis, span, eid);
            }
        }
        return eid;
    }

    // ── function → FnBody (empty block: rustdoc carries no bodies) ──
    if (std.mem.eql(u8, kind_tag, "function")) {
        var params: std.ArrayListUnmanaged(items.Param) = .empty;
        var ret: types.Type = .{ .prim = .unit };
        if (kind_payload == .object) {
            if (kind_payload.object.get("sig")) |sig_v| {
                if (sig_v == .object) {
                    if (sig_v.object.get("inputs")) |ins| {
                        if (ins == .array) {
                            for (ins.array.items) |inp| {
                                if (inp != .array or inp.array.items.len < 2) continue;
                                const pname = if (inp.array.items[0] == .string) inp.array.items[0].string else "";
                                const pty = mapRustdocType(state.arena, inp.array.items[1]);
                                try params.append(state.arena, .{
                                    .name = try state.arena.dupe(u8, pname),
                                    .ty = pty,
                                    .span = span,
                                });
                            }
                        }
                    }
                    if (sig_v.object.get("output")) |out| {
                        ret = mapRustdocType(state.arena, out);
                    }
                }
            }
        }
        const body_id = try appendExpr(state, .{
            .id = 0,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{ .statements = &.{}, .tail = null, .labelled = null } },
        });
        const eid = try addEntity(state, .fn_, name, vis, span, parent_mod);
        state.bodies.items[eid] = .{ .fn_ = .{
            .params = params.toOwnedSlice(state.arena) catch &.{},
            .ret = ret,
            .body = body_id,
        } };
        return eid;
    }

    // ── constant / static → typed const (literal init when possible) ──
    if (std.mem.eql(u8, kind_tag, "constant") or std.mem.eql(u8, kind_tag, "static")) {
        var ty: types.Type = unsupportedType();
        var expr_str: []const u8 = "";
        if (kind_payload == .object) {
            if (kind_payload.object.get("type")) |t| ty = mapRustdocType(state.arena, t);
            if (kind_payload.object.get("const")) |cv| {
                if (cv == .object) {
                    if (cv.object.get("expr")) |ev| {
                        if (ev == .string) expr_str = ev.string;
                    }
                }
            }
        }
        const const_kind: spine.EntityKind = if (std.mem.eql(u8, kind_tag, "static")) .static_ else .const_;
        const eid = try addEntity(state, const_kind, name, vis, span, parent_mod);
        if (const_kind == .const_ and expr_str.len > 0) {
            if (mapConstLiteral(state.arena, expr_str)) |lit| {
                const init_id = try appendExpr(state, lit);
                state.bodies.items[eid] = .{ .const_ = .{ .ty = ty, .init = init_id } };
            }
        }
        return eid;
    }

    // ── type_alias → TypeAliasBody ───────────────────────────────────
    if (std.mem.eql(u8, kind_tag, "type_alias")) {
        var ty: types.Type = unsupportedType();
        if (kind_payload == .object) {
            if (kind_payload.object.get("type")) |t| ty = mapRustdocType(state.arena, t);
        }
        const eid = try addEntity(state, .type_alias, name, vis, span, parent_mod);
        state.bodies.items[eid] = .{ .type_alias = .{ .target = ty } };
        return eid;
    }

    // ── module → handled by mapModule (recursion) ────────────────────
    if (std.mem.eql(u8, kind_tag, "module")) {
        return @as(?spine.EntityId, try mapModule(state, item, parent_mod));
    }

    // ── other named kinds: keep as skeleton `// unsupported` entities ──
    const mapped_kind = rustdocKindToEntityKind(kind_tag) orelse return null;
    return @as(?spine.EntityId, try addEntity(state, mapped_kind, name, vis, span, parent_mod));
}

/// True when `mod_id` is the synthetic error module (its enums lower to Zig
/// error sets).
fn isErrorModule(state: *const State, mod_id: spine.EntityId) bool {
    const m = state.g.module(mod_id) orelse return false;
    return std.mem.eql(u8, m.name, error_module_name);
}

/// Map a rustdoc `module` item (a child module) into the graph: a module
/// entity + a Module table entry, recursing into its items.
fn mapModule(state: *State, item: std.json.Value, parent_mod: ?spine.EntityId) anyerror!spine.EntityId {
    const name_v = item.object.get("name") orelse return 0;
    const name = if (name_v == .string) name_v.string else "";
    const vis = if (item.object.get("visibility")) |vv| visFromJson(vv) else .private;
    const span = spanFromJson(item);

    const mod_ent = try addEntity(state, .module, name, vis, span, parent_mod);

    // Source path from the module's span (best-effort).
    var source_path: ?[]const u8 = null;
    if (item.object.get("span")) |sp| {
        if (sp == .object) {
            if (sp.object.get("filename")) |fn_| {
                if (fn_ == .string and fn_.string.len > 0) {
                    source_path = try state.arena.dupe(u8, fn_.string);
                }
            }
        }
    }

    // Register the Module table entry BEFORE recursing into its items, so that
    // `isErrorModule` (checked while mapping child enums) resolves correctly.
    const mod_idx = state.g.modules.items.len;
    _ = try state.g.addModule(.{
        .id = mod_ent,
        .kind = if (name.len == 0) .root else .file,
        .name = try state.arena.dupe(u8, name),
        .parent = parent_mod,
        .source_path = source_path,
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });

    var child_items: []const spine.EntityId = &.{};
    if (item.object.get("inner")) |inner| {
        if (inner == .object) {
            if (inner.object.get("module")) |mod_v| {
                if (mod_v == .object) {
                    if (mod_v.object.get("items")) |items_v| {
                        child_items = try mapModuleItems(state, items_v, mod_ent);
                    }
                }
            }
        }
    }
    // Populate the just-added module entry's items.
    state.g.modules.items[mod_idx].items = child_items;

    return mod_ent;
}

/// Map a module's `items` JSON array into ordered entity ids, recursing into
/// child modules and resolving `use` re-exports. `parent_mod` is the module
/// entity id that owns these items.
fn mapModuleItems(
    state: *State,
    items_v: std.json.Value,
    parent_mod: spine.EntityId,
) anyerror![]const spine.EntityId {
    if (items_v != .array) return &.{};
    const raw_ids = items_v.array.items;

    var ordered: std.ArrayListUnmanaged(spine.EntityId) = .empty;
    // Deferred uses: mapped after named items so their targets are registered.
    var use_items: std.ArrayListUnmanaged(std.json.Value) = .empty;

    // Pass 1 — named items.
    for (raw_ids) |idv| {
        if (idv != .integer) continue;
        const item = state.index.get(try indexKey(state, idv.integer)) orelse continue;
        if (item != .object) continue;
        const inner = item.object.get("inner") orelse continue;
        if (inner != .object or inner.object.count() == 0) continue;
        var inner_it = inner.object.iterator();
        const first = inner_it.next() orelse continue;
        if (std.mem.eql(u8, first.key_ptr.*, "use")) {
            try use_items.append(state.arena, item);
            continue;
        }
        if (try mapNamedItem(state, item, parent_mod)) |eid| {
            try state.def_map.put(idv.integer, eid);
            try ordered.append(state.arena, eid);
        }
    }

    // Pass 2 — uses (re-exports), resolved against the now-complete def_map.
    for (use_items.items) |item| {
        const inner = item.object.get("inner").?;
        const use_payload = inner.object.get("use") orelse continue;
        const id_v = if (use_payload == .object) use_payload.object.get("id") else null;
        const target_rid: i64 = if (id_v) |iv|
            (if (iv == .integer) iv.integer else continue)
        else
            continue;
        const target_eid = state.def_map.get(target_rid) orelse continue;
        if (target_eid >= state.g.symbol_table.entities.items.len) continue;

        var local_name: []const u8 = "";
        if (use_payload == .object) {
            if (use_payload.object.get("name")) |nv| {
                if (nv == .string) local_name = nv.string;
            }
        }
        if (local_name.len == 0) continue;

        var is_glob = false;
        if (use_payload == .object) {
            if (use_payload.object.get("is_glob")) |gv| {
                if (gv == .bool) is_glob = gv.bool;
            }
        }

        const vis = if (item.object.get("visibility")) |vv| visFromJson(vv) else .private;
        const use_ent = try addEntity(state, .use_, local_name, vis, spanFromJson(item), parent_mod);
        // Do not bind a name to itself (would be a cyclic alias in Zig).
        if (target_eid != use_ent) {
            try state.g.addUse(.{
                .id = use_ent,
                .kind = if (is_glob) .glob else .{ .plain = target_eid },
                .local_name = try state.arena.dupe(u8, local_name),
                .is_pub_export = vis == .public,
                .target = target_eid,
                .span = spanFromJson(item),
            });
            try ordered.append(state.arena, use_ent);
        }
    }

    return ordered.toOwnedSlice(state.arena);
}

/// Walk the rustdoc JSON root module and map every reachable item into the
/// CrateGraph + Bodies. Best effort: any structural parse hiccup returns an
/// error and the caller falls back to an empty skeleton.
fn scrapeRustdoc(
    state: *State,
    bytes: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, state.arena, @ptrCast(bytes), .{});
    defer parsed.deinit();
    const value = parsed.value;

    const index = (try getField(value, "index")) orelse return error.RustdocNoIndex;
    if (index != .object) return error.RustdocIndexNotObject;
    state.index = index.object;

    const root_v = (try getField(value, "root")) orelse return error.RustdocNoRoot;
    if (root_v != .integer) return error.RustdocRootNotInteger;
    const root_item = state.index.get(try indexKey(state, root_v.integer)) orelse return error.RustdocNoRootItem;
    if (root_item != .object) return error.RustdocRootItemNotObject;
    const root_inner = (try getField(root_item, "inner")) orelse return error.RustdocNoRootInner;
    if (root_inner != .object) return error.RustdocRootInnerNotObject;
    const root_mod = (try getField(root_inner, "module")) orelse return error.RustdocNoRootModule;
    if (root_mod != .object) return error.RustdocRootModuleNotObject;
    const items_v = root_mod.object.get("items") orelse return error.RustdocNoItems;

    // Root module entity is id 0 (already added by translate); map its items.
    const root_items = try mapModuleItems(state, items_v, 0);
    state.g.modules.items[0].items = root_items;
}

// ── driver entrypoint ─────────────────────────────────────────────────────

/// Translate a Rust crate directory into a standalone r2z package at `out_dir`.
/// Best-effort: degrades gracefully to a package skeleton.
pub fn translate(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    crate_dir: []const u8,
    out_dir: []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const name = try crateNameFromManifestImpl(arena, io, crate_dir);

    // Sidecar output directory, scoped under the output dir so we never write
    // into the crate's own tree. Removed at the end of this call.
    const sidecar_out = try std.fs.path.join(arena, &.{ out_dir, ".r2z-rustdoc" });
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, sidecar_out);
    defer cwd.deleteTree(io, sidecar_out) catch {};

    // 1. Run the sidecar producer to obtain raw rustdoc JSON (best-effort).
    var had_rustdoc = false;
    if (std.process.run(gpa, io, .{
        .argv = &.{ "sh", "tools/sidecar/rustdoc-json.sh", crate_dir, sidecar_out },
    })) |res| {
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);
        switch (res.term) {
            .exited => |code| {
                if (code == 0) {
                    had_rustdoc = true;
                } else {
                    try writeMessage("warning: sidecar exited with code {d}; emitting package skeleton\n", arena, io, stdout, .{code});
                }
            },
            else => try writeMessage("warning: sidecar terminated abnormally; emitting package skeleton\n", arena, io, stdout, .{}),
        }
    } else |err| {
        try writeMessage("warning: sidecar failed ({s}); emitting package skeleton\n", arena, io, stdout, .{@errorName(err)});
    }

    // 2. Build a best-effort wire CrateGraph + Bodies (real items when the
    //    rustdoc mapped, null bodies -> bare skeleton otherwise).
    var g = graph.CrateGraph.init(arena);
    const span = default_span;

    // Root module entity (id 0, matching dense symbol/module tables).
    const root_entity_name = try arena.dupe(u8, "");
    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = root_entity_name,
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });

    var state: State = .{
        .arena = arena,
        .g = &g,
        .index = undefined,
        .def_map = std.AutoHashMap(i64, spine.EntityId).init(arena),
        .exprs = .empty,
        .bodies = .empty,
    };
    // One body slot for the root module entity.
    try state.bodies.append(arena, .none);

    var mapped_ok = false;
    if (had_rustdoc) {
        const rustdoc_path = try std.fs.path.join(arena, &.{
            sidecar_out,
            try std.fmt.allocPrint(arena, "crate-{s}.json", .{name}),
        });
        if (readFileAlloc(arena, io, rustdoc_path)) |rdb| {
            if (scrapeRustdoc(&state, rdb)) |_| {
                mapped_ok = true;
            } else |_| {
                try writeMessage("warning: could not map rustdoc items; emitting package skeleton\n", arena, io, stdout, .{});
            }
        } else |_| {
            try writeMessage("warning: could not read rustdoc JSON; emitting package skeleton\n", arena, io, stdout, .{});
        }
    }

    try g.addCrate(.{
        .name = try arena.dupe(u8, name),
        .edition = 2018,
        .kind = .lib,
        .root = 0,
        .deps = &.{},
        .is_translated = true,
    });

    // 3. Assemble Bodies (dense exprs + sparse BodyKind), then emit the
    //    standalone package to disk.
    var bodies_opt: ?emit.Bodies = null;
    if (mapped_ok) {
        bodies_opt = .{
            .exprs = try state.exprs.toOwnedSlice(arena),
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = try state.bodies.toOwnedSlice(arena),
        };
    }

    var pkg = try package.generatePackage(arena, &g, if (bodies_opt) |*bb| bb else null, 0);
    try pkg.writeToDisk(io, out_dir);
    try fixFingerprint(gpa, io, out_dir);
    try writeMessage("emitted package {s} to {s} ({d} files)\n", arena, io, stdout, .{ pkg.package_name, out_dir, pkg.files.len });
}

/// Zig requires a package manifest `.fingerprint` that is a hash of the
/// package contents. The generator cannot compute it itself, so after writing
/// the package we run `zig build`, read the "suggested value: 0x..." error,
/// and patch `build.zig.zon`. This keeps generated packages valid for
/// arbitrary crate names (not just the 4 hand-tuned corpus crates).
fn fixFingerprint(gpa: std.mem.Allocator, io: std.Io, out_dir: []const u8) !void {
    const cmd = try std.fmt.allocPrint(gpa, "cd {s} && zig build 2>&1", .{out_dir});
    defer gpa.free(cmd);

    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sh", "-c", cmd },
    }) catch return;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    const dump = if (res.stdout.len > 0) res.stdout else res.stderr;
    const marker = "use this value: 0x";
    const idx = std.mem.indexOf(u8, dump, marker) orelse return; // build already valid
    const rest = dump[idx + marker.len ..];
    var hex: [16]u8 = undefined;
    var len: usize = 0;
    for (rest) |ch| {
        if (len >= hex.len or !std.ascii.isHex(ch)) break;
        hex[len] = ch;
        len += 1;
    }
    if (len == 0) return;
    const fp = std.fmt.parseUnsigned(u64, hex[0..len], 16) catch return;

    // Patch build.zig.zon: replace its `.fingerprint = 0x{old}` with the
    // discovered value so the emitted package has a valid manifest.
    const zon_path = try std.fs.path.join(gpa, &.{ out_dir, "build.zig.zon" });
    defer gpa.free(zon_path);
    var dir = std.Io.Dir.cwd();
    var io_buf: [4096]u8 = undefined;
    const f = try dir.openFile(io, zon_path, .{});
    defer f.close(io);
    var reader = f.reader(io, &io_buf);
    const zon = try reader.interface.allocRemaining(gpa, .limited(1 << 20));
    defer gpa.free(zon);

    const old_key = ".fingerprint = 0x";
    const old_idx = std.mem.indexOf(u8, zon, old_key) orelse return;
    const fp_hex = try std.fmt.allocPrint(gpa, "{x}", .{fp});
    defer gpa.free(fp_hex);
    // Old value is exactly 16 hex digits after "0x"; keep everything else.
    const fp_end = old_idx + old_key.len + 16;
    var patched: std.ArrayListUnmanaged(u8) = .empty;
    defer patched.deinit(gpa);
    try patched.appendSlice(gpa, zon[0 .. old_idx + old_key.len]);
    try patched.appendSlice(gpa, fp_hex);
    if (fp_end < zon.len) try patched.appendSlice(gpa, zon[fp_end..]);

    const w = try dir.createFile(io, zon_path, .{});
    defer w.close(io);
    try w.writeStreamingAll(io, patched.items);
}

/// Resolve + print a formatted message to `stdout` (arena-backed).
fn writeMessage(
    comptime fmt: []const u8,
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    args: anytype,
) !void {
    const msg = try std.fmt.allocPrint(gpa, fmt, args);
    try stdout.writeStreamingAll(io, msg);
}
