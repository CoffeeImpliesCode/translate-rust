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

const Json = std.json.Value;
const ObjectMap = std.json.ObjectMap; // unmanaged (allocator passed per call)
const Array = std.json.Array; // managed (init(allocator))

/// The wire format version this build writes and accepts (data-model.md §4).
pub const wire_format_version: u32 = 1;

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

/// Lossless decode of the wire format into an owned CrateGraph. The graph
/// duplicates every string and owns every slice; free it with `g.deinit()`.
/// A mismatched `format_version` is rejected with `error.InvalidFormatVersion`.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !graph.CrateGraph {
    var parsed = std.json.parseFromSlice(Json, allocator, bytes, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();
    const root_map = getObj(parsed.value) catch return error.BadWireFormat;

    const ver: u32 = @intCast(try reqU32(root_map, "format_version"));
    if (ver != wire_format_version) return error.InvalidFormatVersion;

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
    var items = Array.init(allocator);
    for (m.items) |it| try items.append(mkInt(it));
    try o.put(allocator, "items", .{ .array = items });
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

/// Write the graph back to the wire JSON. The returned `[]u8` is owned by the
/// caller and must be freed with the passed allocator. Inverses `parse`.
pub fn encode(allocator: std.mem.Allocator, g: *const graph.CrateGraph) ![]u8 {
    var root_map = ObjectMap.empty;
    try root_map.put(allocator, "format_version", mkInt(wire_format_version));
    try root_map.put(allocator, "sidecar", encodeOptStr(g.sidecar));
    try root_map.put(allocator, "toolchain", encodeOptStr(g.toolchain));

    var crates_arr = Array.init(allocator);
    for (g.crates.items) |c| {
        const member = try crateMembers(allocator, g, c.root);
        defer allocator.free(member);
        try crates_arr.append(try encodeCrate(allocator, g, c, member));
    }
    try root_map.put(allocator, "crates", .{ .array = crates_arr });

    var root_val = Json{ .object = root_map };
    defer freeValue(&root_val, allocator);

    // Zig 0.16: std.json.stringify was replaced by Stringify.valueAlloc, which
    // owns and returns a []u8 buffer to be freed with the passed allocator.
    return std.json.Stringify.valueAlloc(allocator, root_val, .{});
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
    const file = try dir.openFile(test_io, "src/fixtures/model/mini.json", .{});
    defer file.close(test_io);
    var reader = file.reader(test_io, &io_buf);
    return reader.interface.allocRemaining(allocator, .limited(1 << 20));
}

fn parseMini(allocator: std.mem.Allocator) !graph.CrateGraph {
    const bytes = try miniJson(allocator);
    defer allocator.free(bytes);
    return parse(allocator, bytes);
}

fn findItemByName(gg: *const graph.CrateGraph, items: []const spine.EntityId, nm: []const u8) ?spine.EntityId {
    for (items) |id| {
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
