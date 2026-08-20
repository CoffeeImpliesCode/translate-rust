//! translate_rust.emit — P2/P3 item-level emitter: translate a `CrateGraph`
//! into Zig source text.
//!
//! Scope (P2, deferred work called out explicitly):
//!   * `struct_`  → `pub const Name = struct { // unsupported: struct Name };`
//!                  (no field lowering; type bodies are P3)
//!   * `enum_`    → `pub const Name = enum(u8) { // unsupported: enum Name };`
//!                  (C-like; data-carrying variants are P3)
//!   * `fn_`      → `pub fn name() void { // body not yet lowered }` (no bodies)
//!                  With bodies: `pub fn name(params) ret { block }`.
//!   * `const_`   → `pub const NAME: void = // init not yet lowered\n;` (no bodies)
//!                  With bodies: `pub const NAME: ty = init;`.
//!   * `use_`     → `pub const local = target_name;` (pub iff `is_pub_export`),
//!                  resolved through the symbol table.
//!   * `module`   → a `// module: <name>` banner then the module's items.
//!   * anything else → `// unsupported: <kind> <name>` (never silent).
//!
//! Visibility: the emitter honors `spine.Visibility` — `.public` produces the
//! `pub ` prefix; all other variants (private, crate_restricted,
//! super_restricted, in_path) reduce to no prefix. This may diverge from a
//! hand-written golden file (the fnv fixture marks its private consts
//! `private` in the wire but `pub` in the golden); the golden-file test
//! normalizes and compares structurally.
//!
//! The emitter is not streaming: it builds a single `ArrayListUnmanaged(u8)`
//! and returns it to the caller, who owns the slice and frees it with the
//! same allocator.

const std = @import("std");
const spine = @import("spine.zig");
const graph = @import("graph.zig");
const items = @import("items.zig");
const types = @import("types.zig");
const json = @import("json.zig");
const exprs = @import("exprs.zig");

// ── P3 body data structures ───────────────────────────────────────────────

/// Body of a `const` declaration (type + init expression).
// Shared body tables live in bodies.zig (leaf) so json and emit do not
// create an import cycle. Re-export as aliases — emit.Bodies == json.Bodies.
pub const bodies_mod = @import("bodies.zig");
pub const ConstBody = bodies_mod.ConstBody;
pub const FnBody = bodies_mod.FnBody;
pub const StructMethod = bodies_mod.StructMethod;
pub const StructBody = bodies_mod.StructBody;
pub const TraitMethodSig = bodies_mod.TraitMethodSig;
pub const TraitBody = bodies_mod.TraitBody;
pub const TypeAliasBody = bodies_mod.TypeAliasBody;
pub const BodyKind = bodies_mod.BodyKind;
pub const Bodies = bodies_mod.Bodies;

// ── Public entry points ───────────────────────────────────────────────────

/// Translate `g` into Zig source text.  The returned slice is owned by the
/// caller and must be freed with `allocator`.
pub fn emit(allocator: std.mem.Allocator, g: *const graph.CrateGraph) ![]u8 {
    return emitImpl(allocator, g, null);
}

/// Translate `g` into Zig source text with full body lowering.
/// `bodies` carries per-entity body data (expressions, statements, types)
/// so that `const` and `fn` items emit their actual Zig rather than placeholders.
pub fn emitRich(
    allocator: std.mem.Allocator,
    g: *const graph.CrateGraph,
    bodies: *const Bodies,
) ![]u8 {
    return emitImpl(allocator, g, bodies);
}
/// Translate a single module into Zig source text for multi-file package output.
/// Child file/directory modules are emitted as `@import("<name>.zig")` statements.
pub fn emitModuleFile(
    allocator: std.mem.Allocator,
    g: *const graph.CrateGraph,
    bodies: ?*const Bodies,
    mod_id: spine.EntityId,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    const m = g.module(mod_id) orelse return buf.toOwnedSlice(allocator);

    // 1. Emit submodule imports for all child modules that are separate files.
    for (g.modules.items) |child_m| {
        if (child_m.parent == mod_id and (child_m.kind == .file or child_m.kind == .directory)) {
            const child_name = child_m.name;
            if (child_name.len > 0) {
                try buf.appendSlice(allocator, "pub const ");
                try emitIdent(allocator, &buf, child_name);
                try buf.appendSlice(allocator, " = @import(\"");
                try buf.appendSlice(allocator, child_name);
                try buf.appendSlice(allocator, ".zig\");\n");
            }
        }
    }

    // 2. Emit this module's own items.
    for (m.items) |item_id| {
        const e = g.symbol_table.get(item_id) orelse continue;
        if (e.kind == .module) {
            if (g.module(e.id)) |child_m| {
                if (child_m.kind == .file or child_m.kind == .directory) {
                    // Handled as import above; do not duplicate items inline.
                    continue;
                }
            }
        }
        try emitEntity(allocator, &buf, g, e, bodies);
    }

    return buf.toOwnedSlice(allocator);
}
/// Format a Zig source buffer canonically using std.zig.Ast (identical to `zig fmt`).
/// If there are syntax errors (e.g. placeholder comments), returns a copy of `source`.
pub fn formatZig(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const src_z = try allocator.dupeZ(u8, source);
    defer allocator.free(src_z);

    var tree = try std.zig.Ast.parse(allocator, src_z, .zig);
    defer tree.deinit(allocator);

    if (tree.errors.len == 0) {
        return tree.renderAlloc(allocator);
    } else {
        return allocator.dupe(u8, source);
    }
}

fn emitImpl(
    allocator: std.mem.Allocator,
    g: *const graph.CrateGraph,
    bodies: ?*const Bodies,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (g.crates.items) |c| {
        try emitModule(allocator, &buf, g, c.root, bodies);
    }

    return buf.toOwnedSlice(allocator);
}

// ── Module / entity dispatch ──────────────────────────────────────────────

fn emitModule(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    mod_id: spine.EntityId,
    bodies: ?*const Bodies,
) !void {
    const m = g.module(mod_id) orelse return;

    // Banner: skip the root (its name is ""), emit a comment for child modules
    // so the output is human-readable while the file layout stays flat.
    if (m.name.len > 0) {
        try buf.appendSlice(allocator, "// module: ");
        try buf.appendSlice(allocator, m.name);
        try buf.append(allocator, '\n');
    }

    for (m.items) |item_id| {
        const e = g.symbol_table.get(item_id) orelse continue;
        try emitEntity(allocator, buf, g, e, bodies);
    }
}

fn emitEntity(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    e: spine.Entity,
    bodies: ?*const Bodies,
) !void {
    const pub_ = visPrefix(e.visibility);

    switch (e.kind) {
        .module => {
            // Recurse into the submodule's items.
            if (g.module(e.id)) |m| {
                if (m.name.len > 0) {
                    try buf.appendSlice(allocator, "// module: ");
                    try buf.appendSlice(allocator, m.name);
                    try buf.append(allocator, '\n');
                }
                for (m.items) |child_id| {
                    const child = g.symbol_table.get(child_id) orelse continue;
                    try emitEntity(allocator, buf, g, child, bodies);
                }
            }
        },
        .struct_ => {
            if (bodies) |bb| {
                if (e.id < bb.bodies.len) switch (bb.bodies[e.id]) {
                    .struct_ => |sb| {
                        try emitStructDef(allocator, buf, g, bb, e, sb);
                        return;
                    },
                    else => {},
                };
            }
            try buf.appendSlice(allocator, pub_);
            try buf.appendSlice(allocator, "const ");
            try emitIdent(allocator, buf, entityName(e));
            try buf.appendSlice(allocator, " = struct { // unsupported: struct ");
            try buf.appendSlice(allocator, e.name);
            try buf.appendSlice(allocator, "\n};\n");
        },
        .enum_ => {
            // Rust error enums (parented under the synthetic `error` module)
            // lower to Zig error sets, so `FromHexError!u8` error-union
            // signatures type-check and `error.InvalidHexCharacter` values
            // coerce to the set.
            if (isErrorSetEnum(g, e)) {
                try emitErrorSetDef(allocator, buf, g, e, pub_);
                return;
            }
            if (bodies) |bb| {
                if (e.id < bb.bodies.len) switch (bb.bodies[e.id]) {
                    .enum_ => |eb| {
                        try emitEnumDef(allocator, buf, g, e, eb);
                        return;
                    },
                    else => {},
                };
            }
            try buf.appendSlice(allocator, pub_);
            try buf.appendSlice(allocator, "const ");
            try emitIdent(allocator, buf, entityName(e));
            try buf.appendSlice(allocator, " = enum(u8) { // unsupported: enum ");
            try buf.appendSlice(allocator, e.name);
            try buf.appendSlice(allocator, "\n};\n");
        },
        .fn_ => {
            const is_test = hasAttr(e, "test");
            if (is_test) {
                // Rust #[test] fn -> Zig `test "name" { body }` block.
                if (bodies) |bb| {
                    if (e.id < bb.bodies.len) switch (bb.bodies[e.id]) {
                        .fn_ => |fb| {
                            try buf.appendSlice(allocator, "test \"");
                            try buf.appendSlice(allocator, e.name);
                            try buf.appendSlice(allocator, "\" ");
                            try emitFnBody(allocator, buf, g, bb, fb.body, fb.params, fb.ret, 1);
                            try buf.append(allocator, '\n');
                            return;
                        },
                        else => {},
                    };
                }
                try buf.appendSlice(allocator, "test \"");
                try buf.appendSlice(allocator, e.name);
                try buf.appendSlice(allocator, "\" {}\n");
                return;
            }
            try buf.appendSlice(allocator, pub_);
            try buf.appendSlice(allocator, "fn ");
            try emitIdent(allocator, buf, entityName(e));
            // P3: emit real signature + body when available.
            if (bodies) |bb| {
                if (e.id < bb.bodies.len) switch (bb.bodies[e.id]) {
                    .fn_ => |fb| {
                        try emitFnSignature(allocator, buf, g, fb.params, fb.ret, fb.is_allocating);
                        try buf.append(allocator, ' ');
                        try emitFnBody(allocator, buf, g, bb, fb.body, fb.params, fb.ret, 1);
                        try buf.append(allocator, '\n');
                        return;
                    },
                    else => {},
                };
            }
            // Fallback: P2 placeholder signature.
            try buf.appendSlice(allocator, "() void {\n");
            try buf.appendSlice(allocator, "    // body not yet lowered\n");
            try buf.append(allocator, '}');
            try buf.append(allocator, '\n');
        },
        .const_ => {
            try buf.appendSlice(allocator, pub_);
            try buf.appendSlice(allocator, "const ");
            try emitIdent(allocator, buf, entityName(e));
            // P3: emit real type + init when available.
            if (bodies) |bb| {
                if (e.id < bb.bodies.len) switch (bb.bodies[e.id]) {
                    .const_ => |cb| {
                        try buf.appendSlice(allocator, ": ");
                        try emitType(allocator, buf, g, cb.ty);
                        try buf.appendSlice(allocator, " = ");
                        try emitExpr(allocator, buf, g, bb, cb.init, 0, true, true);
                        try buf.appendSlice(allocator, ";\n");
                        return;
                    },
                    else => {},
                };
            }
            // Fallback: P2 placeholder.
            try buf.appendSlice(allocator, ": void = // init not yet lowered\n");
            try buf.append(allocator, ';');
            try buf.append(allocator, '\n');
        },
        .use_ => {
            const use_decl = g.useById(e.id) orelse {
                try unsupported(allocator, buf, e, "use (no decl)");
                return;
            };
            const target = g.symbol_table.get(use_decl.target) orelse {
                try unsupported(allocator, buf, e, "use (unresolved target)");
                return;
            };
            if (target.name.len == 0) {
                try unsupported(allocator, buf, e, "use (anonymous target)");
                return;
            }
            try buf.appendSlice(allocator, if (use_decl.is_pub_export) "pub " else "");
            try buf.appendSlice(allocator, "const ");
            try emitIdent(allocator, buf, use_decl.local_name);
            try buf.appendSlice(allocator, " = ");
            // Zig has no re-export; when the target lives in another module we
            // must qualify the path (`pub const FromHexError = @"error".FromHexError;`)
            // or the alias would be a cyclic self-reference.
            if (!try writeQualifiedTarget(allocator, buf, g, e.parent, target)) {
                try emitIdent(allocator, buf, entityName(target));
            }
            try buf.appendSlice(allocator, ";\n");
        },
        .crate_ => try unsupported(allocator, buf, e, "crate"),
        .union_ => try unsupported(allocator, buf, e, "union"),
        .static_ => try unsupported(allocator, buf, e, "static"),
        .trait_ => {
            if (bodies) |bb| {
                if (e.id < bb.bodies.len) switch (bb.bodies[e.id]) {
                    .trait_ => |tb| {
                        try emitTraitDef(allocator, buf, g, bb, e, tb);
                        return;
                    },
                    else => {},
                };
            }
            try unsupported(allocator, buf, e, "trait");
        },
        .impl_ => {
            // Inherent and trait impls for structs/enums are emitted directly
            // as members of their target struct in emitStructInner; skip emitting
            // top-level stub comments for them.
        },
        .type_alias => {
            if (bodies) |bb| {
                if (e.id < bb.bodies.len) switch (bb.bodies[e.id]) {
                    .type_alias => |ab| {
                        try buf.appendSlice(allocator, pub_);
                        try buf.appendSlice(allocator, "const ");
                        try emitIdent(allocator, buf, entityName(e));
                        try buf.appendSlice(allocator, " = ");
                        try emitType(allocator, buf, g, ab.target);
                        try buf.appendSlice(allocator, ";\n");
                        return;
                    },
                    else => {},
                };
            }
            try unsupported(allocator, buf, e, "type alias");
        },
        .extern_crate => try unsupported(allocator, buf, e, "extern crate"),
        .macro_ => try unsupported(allocator, buf, e, "macro"),
        .field => try unsupported(allocator, buf, e, "field"),
        .variant => try unsupported(allocator, buf, e, "variant"),
    }
}

// ── Identifier and keyword escaping helpers (P4) ──────────────────────────

fn entityName(e: spine.Entity) []const u8 {
    return e.renamed_to orelse e.name;
}

/// True if the entity carries an attribute with the given name (e.g. "#[test]").
fn hasAttr(e: spine.Entity, attr_name: []const u8) bool {
    for (e.attributes) |a| {
        if (std.mem.eql(u8, a.name, attr_name)) return true;
    }
    return false;
}

fn emitIdent(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), name: []const u8) !void {
    if (std.mem.startsWith(u8, name, "error.")) {
        try buf.appendSlice(allocator, "error.");
        return emitIdent(allocator, buf, name["error.".len..]);
    }
    if (std.mem.indexOfScalar(u8, name, '(') != null) {
        try buf.appendSlice(allocator, name);
        return;
    }
    const formatted = try std.fmt.allocPrint(allocator, "{f}", .{std.zig.fmtId(name)});
    defer allocator.free(formatted);
    try buf.appendSlice(allocator, formatted);
}

/// The synthetic module under which the sidecar parents Rust error enums.
/// Its name is a Zig keyword, but emitIdent escapes it (`@"error"`).
const error_module_name = "error";

/// If `variant_id` resolves to a variant of an enum living in the synthetic
/// `error` module (an error-set enum), return that enum entity; else null.
fn errorSetEnumOf(g: *const graph.CrateGraph, variant_id: spine.EntityId) ?spine.Entity {
    const variant_ent = g.symbol_table.get(variant_id) orelse return null;
    if (variant_ent.parent) |enum_id| {
        const enum_ent = g.symbol_table.get(enum_id) orelse return null;
        if (enum_ent.kind == .enum_ and isErrorSetEnum(g, enum_ent)) return enum_ent;
    }
    return null;
}

/// True when `e` is an enum whose parent module is the synthetic `error`
/// module (i.e. it lowers to a Zig error set, not a tagged union).
fn isErrorSetEnum(g: *const graph.CrateGraph, e: spine.Entity) bool {
    const pid = e.parent orelse return false;
    const parent_ent = g.symbol_table.get(pid) orelse return false;
    if (parent_ent.kind != .module) return false;
    const m = g.module(pid) orelse return false;
    return std.mem.eql(u8, m.name, error_module_name);
}

/// Emit a Rust error enum as a Zig error set: `pub const Name = error{ ... };`.
/// Variant names come from the enum's child `.variant` entities, in entity order.
fn emitErrorSetDef(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    e: spine.Entity,
    pub_: []const u8,
) !void {
    try buf.appendSlice(allocator, pub_);
    try buf.appendSlice(allocator, "const ");
    try emitIdent(allocator, buf, entityName(e));
    try buf.appendSlice(allocator, " = error{");
    var first = true;
    for (g.symbol_table.entities.items) |ent| {
        if (ent.kind == .variant and ent.parent == e.id) {
            if (!first) try buf.appendSlice(allocator, ", ");
            first = false;
            try emitIdent(allocator, buf, ent.name);
        }
    }
    try buf.appendSlice(allocator, "};\n");
}

/// Write the module-qualified path to `target` as seen from `from_mod`, e.g.
/// `@"error".FromHexError`. Returns false when no qualifying prefix applies
/// (target already in `from_mod`, or no resolvable module chain), in which case
/// the caller should emit the plain target name.
fn writeQualifiedTarget(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    from_mod: ?spine.EntityId,
    target: spine.Entity,
) !bool {
    // Climb from the target's parent until we reach its defining module.
    var mod_id: ?spine.EntityId = target.parent;
    while (mod_id) |mid| {
        const ent = g.symbol_table.get(mid) orelse return false;
        if (ent.kind == .module) break;
        mod_id = ent.parent;
    }
    const tmod = mod_id orelse return false;
    if (from_mod != null and tmod == from_mod.?) return false;

    // Build the chain of module names from tmod up to (not including) from_mod.
    var chain: std.ArrayListUnmanaged([]const u8) = .empty;
    defer chain.deinit(allocator);
    var cur: ?spine.EntityId = tmod;
    while (cur) |cid| {
        const ce = g.symbol_table.get(cid) orelse return false;
        if (ce.kind != .module) return false;
        if (from_mod != null and cid == from_mod.?) break;
        try chain.append(allocator, ce.name);
        cur = ce.parent;
    }
    if (chain.items.len == 0) return false;

    var i = chain.items.len;
    while (i > 0) {
        i -= 1;
        if (i < chain.items.len - 1) try buf.append(allocator, '.');
        try emitIdent(allocator, buf, chain.items[i]);
    }
    try buf.append(allocator, '.');
    try emitIdent(allocator, buf, entityName(target));
    return true;
}

// ── P3 body emission helpers ──────────────────────────────────────────────
fn writeIndent(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), depth: u32) !void {
    var i: u32 = 0;
    while (i < depth) : (i += 1) {
        try buf.appendSlice(allocator, "    ");
    }
}

fn primName(p: types.Prim) []const u8 {
    return switch (p) {
        .i8 => "i8",
        .i16 => "i16",
        .i32 => "i32",
        .i64 => "i64",
        .i128 => "i128",
        .u8 => "u8",
        .u16 => "u16",
        .u32 => "u32",
        .u64 => "u64",
        .u128 => "u128",
        .isize => "isize",
        .usize => "usize",
        .f32 => "f32",
        .f64 => "f64",
        .bool => "bool",
        .char => "u21",
        .unit => "void",
        .never => "noreturn",
    };
}

fn emitType(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    ty: types.Type,
) !void {
    switch (ty) {
        .prim => |p| try buf.appendSlice(allocator, primName(p)),
        .slice => |s| {
            try buf.appendSlice(allocator, "[]");
            if (s.const_) try buf.appendSlice(allocator, "const ");
            try emitType(allocator, buf, g, s.elem);
        },
        .path => |p| {
            for (p.segments, 0..) |seg, i| {
                if (i > 0) try buf.append(allocator, '.');
                try emitIdent(allocator, buf, seg.name);
            }
        },
        .reference => |r| {
            if (r.mut) {
                try buf.appendSlice(allocator, "*");
            } else {
                try buf.appendSlice(allocator, "*const ");
            }
            try emitType(allocator, buf, g, r.pointee);
        },
        .raw_ptr => |rp| {
            if (rp.mut) {
                try buf.appendSlice(allocator, "[*]");
            } else {
                try buf.appendSlice(allocator, "[*]const ");
            }
            try emitType(allocator, buf, g, rp.pointee);
        },
        .array => |a| {
            try buf.append(allocator, '[');
            switch (a.len) {
                .literal => |lit| {
                    const formatted = try std.fmt.allocPrint(allocator, "{d}", .{lit});
                    defer allocator.free(formatted);
                    try buf.appendSlice(allocator, formatted);
                },
                .generic => |idx| {
                    const formatted = try std.fmt.allocPrint(allocator, "N{d}", .{idx});
                    defer allocator.free(formatted);
                    try buf.appendSlice(allocator, formatted);
                },
            }
            try buf.append(allocator, ']');
            try emitType(allocator, buf, g, a.elem);
        },
        .tuple => |tup| {
            if (tup.len == 0) {
                try buf.appendSlice(allocator, "void");
                return;
            }
            try buf.appendSlice(allocator, "struct { ");
            for (tup, 0..) |elem_ty, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                const fld_name = try std.fmt.allocPrint(allocator, "@{s}{d}{s}", .{ "\"", i, "\"" });
                defer allocator.free(fld_name);
                try buf.appendSlice(allocator, fld_name);
                try buf.appendSlice(allocator, ": ");
                try emitType(allocator, buf, g, elem_ty);
            }
            try buf.appendSlice(allocator, " }");
        },
        .result => |res| {
            if (res.is_error_unionable) {
                var is_anyerror = false;
                switch (res.err) {
                    .path => |p| {
                        if (p.segments.len == 1 and std.mem.eql(u8, p.segments[0].name, "anyerror")) {
                            is_anyerror = true;
                        }
                    },
                    .prim => |p| {
                        if (p == .unit) is_anyerror = true;
                    },
                    else => {},
                }
                if (!is_anyerror) {
                    try emitType(allocator, buf, g, res.err);
                }
                try buf.append(allocator, '!');
                try emitType(allocator, buf, g, res.ok);
            } else {
                try buf.appendSlice(allocator, "Result(");
                try emitType(allocator, buf, g, res.ok);
                try buf.appendSlice(allocator, ", ");
                try emitType(allocator, buf, g, res.err);
                try buf.append(allocator, ')');
            }
        },
        .option => |opt| {
            try buf.append(allocator, '?');
            try emitType(allocator, buf, g, opt.*);
        },
        .generic_inst => |gi| {
            const base_name = if (g.symbol_table.get(gi.decl)) |ent| ent.name else "";
            const params = gi.args.params;
            if (std.mem.eql(u8, base_name, "BuildHasherDefault")) {
                try buf.appendSlice(allocator, "std.hash.BuildHasherDefault(");
                if (params.len >= 1) {
                    try emitType(allocator, buf, g, params[0]);
                } else {
                    try buf.appendSlice(allocator, "anyopaque");
                }
                try buf.append(allocator, ')');
            } else if (std.mem.eql(u8, base_name, "HashMap")) {
                try buf.appendSlice(allocator, "std.AutoHashMap(");
                if (params.len >= 1) {
                    try emitType(allocator, buf, g, params[0]);
                } else {
                    try buf.appendSlice(allocator, "anyopaque");
                }
                try buf.appendSlice(allocator, ", ");
                if (params.len >= 2) {
                    try emitType(allocator, buf, g, params[1]);
                } else {
                    try buf.appendSlice(allocator, "void");
                }
                try buf.append(allocator, ')');
            } else if (std.mem.eql(u8, base_name, "HashSet")) {
                try buf.appendSlice(allocator, "std.AutoHashMap(");
                if (params.len >= 1) {
                    try emitType(allocator, buf, g, params[0]);
                } else {
                    try buf.appendSlice(allocator, "anyopaque");
                }
                try buf.appendSlice(allocator, ", void)");
            } else {
                try buf.appendSlice(allocator, "anyopaque");
            }
        },
        .fn_ptr => |fp| {
            try buf.appendSlice(allocator, "*const fn (");
            for (fp.params, 0..) |pt, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try emitType(allocator, buf, g, pt);
            }
            try buf.appendSlice(allocator, ") ");
            try emitType(allocator, buf, g, fp.ret);
        },
        .boxed => |bx| {
            try buf.append(allocator, '*');
            try emitType(allocator, buf, g, bx.*);
        },
        else => try buf.appendSlice(allocator, "anyopaque"),
    }
}

fn emitPattern(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    b: *const Bodies,
    pat_id: exprs.NodeId,
) !void {
    const p = b.pats[pat_id];
    switch (p.kind) {
        .binding => |bd| try emitIdent(allocator, buf, bd.name),
        .wildcard => try buf.append(allocator, '_'),
        .literal => |lit| switch (lit) {
            .int => |i| try buf.appendSlice(allocator, i.text),
            .character => |c| {
                const formatted = try std.fmt.allocPrint(allocator, "'{c}'", .{@as(u8, @truncate(c.value))});
                defer allocator.free(formatted);
                try buf.appendSlice(allocator, formatted);
            },
            .string => |s| {
                try buf.append(allocator, '"');
                try buf.appendSlice(allocator, s.bytes);
                try buf.append(allocator, '"');
            },
            .boolean => |v| try buf.appendSlice(allocator, if (v) "true" else "false"),
            else => try buf.append(allocator, '_'),
        },
        .path => |pp| {
            if (pp.variant) |vname| {
                try buf.append(allocator, '.');
                try emitIdent(allocator, buf, vname);
            } else {
                try buf.append(allocator, '_');
            }
        },
        .range => |rp| {
            if (rp.lo) |lo_id| {
                const lo_expr = b.exprs[lo_id];
                switch (lo_expr.kind) {
                    .literal => |lit| switch (lit) {
                        .int => |i| try buf.appendSlice(allocator, i.text),
                        .character => |c| {
                            const formatted = try std.fmt.allocPrint(allocator, "'{c}'", .{@as(u8, @truncate(c.value))});
                            defer allocator.free(formatted);
                            try buf.appendSlice(allocator, formatted);
                        },
                        else => {},
                    },
                    else => {},
                }
            }
            try buf.appendSlice(allocator, "...");
            if (rp.hi) |hi_id| {
                const hi_expr = b.exprs[hi_id];
                switch (hi_expr.kind) {
                    .literal => |lit| switch (lit) {
                        .int => |i| try buf.appendSlice(allocator, i.text),
                        .character => |c| {
                            const formatted = try std.fmt.allocPrint(allocator, "'{c}'", .{@as(u8, @truncate(c.value))});
                            defer allocator.free(formatted);
                            try buf.appendSlice(allocator, formatted);
                        },
                        else => {},
                    },
                    else => {},
                }
            }
        },
        .@"or" => |op| {
            for (op.alternatives, 0..) |alt_id, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try emitPattern(allocator, buf, b, alt_id);
            }
        },
        .reference => |rp| {
            try emitPattern(allocator, buf, b, rp.inner);
        },
        .tuple => |tp| {
            for (tp.elements, 0..) |elem_id, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try emitPattern(allocator, buf, b, elem_id);
            }
        },
        .struct_pat => |sp| {
            // `Some(x)` / `Ok(x)` style while-let captures: emit the payload
            // binding(s), which is what Zig's while-capture (and for-pattern)
            // actually binds.
            for (sp.fields, 0..) |f, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                if (f.pat) |fpid| {
                    try emitPattern(allocator, buf, b, fpid);
                } else {
                    // Shorthand (`{ x }`) binds a same-named local: the field
                    // name itself is the capture identifier.
                    try emitIdent(allocator, buf, f.field);
                }
            }
        },
        else => try buf.append(allocator, '_'),
    }
}

fn emitStructDef(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    b: *const Bodies,
    e: spine.Entity,
    sb: bodies_mod.StructBody,
) !void {
    const pub_ = visPrefix(e.visibility);
    const is_generic = sb.generic_params.len > 0;

    if (is_generic) {
        try buf.appendSlice(allocator, pub_);
        try buf.appendSlice(allocator, "fn ");
        try emitIdent(allocator, buf, entityName(e));
        try buf.append(allocator, '(');
        for (sb.generic_params, 0..) |gp, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            try buf.appendSlice(allocator, "comptime ");
            try emitIdent(allocator, buf, gp);
            try buf.appendSlice(allocator, ": type");
        }
        try buf.appendSlice(allocator, ") type {\n");

        if (sb.trait_bounds.len > 0) {
            try buf.appendSlice(allocator, "    comptime {\n");
            for (sb.trait_bounds) |tb| {
                try buf.appendSlice(allocator, "        // bound: ");
                try buf.appendSlice(allocator, tb);
                try buf.append(allocator, '\n');
            }
            try buf.appendSlice(allocator, "    }\n");
        }

        try buf.appendSlice(allocator, "    return struct {\n");
        try emitStructInner(allocator, buf, g, b, entityName(e), sb, 2);
        try buf.appendSlice(allocator, "    };\n");
        try buf.appendSlice(allocator, "}\n");
    } else {
        try buf.appendSlice(allocator, pub_);
        try buf.appendSlice(allocator, "const ");
        try emitIdent(allocator, buf, entityName(e));
        try buf.appendSlice(allocator, " = struct {\n");
        try emitStructInner(allocator, buf, g, b, entityName(e), sb, 1);
        try buf.appendSlice(allocator, "};\n");
    }
}

fn emitStructInner(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    b: *const Bodies,
    struct_name: []const u8,
    sb: bodies_mod.StructBody,
    depth: u32,
) !void {
    // 1. Fields
    switch (sb.layout) {
        .named => {
            for (sb.fields) |f| {
                try writeIndent(allocator, buf, depth);
                try emitIdent(allocator, buf, f.name);
                try buf.appendSlice(allocator, ": ");
                try emitType(allocator, buf, g, f.ty);
                try buf.appendSlice(allocator, ",\n");
            }
        },
        .tuple => {
            for (sb.fields, 0..) |f, i| {
                try writeIndent(allocator, buf, depth);
                const tuple_name = try std.fmt.allocPrint(allocator, "{d}", .{i});
                defer allocator.free(tuple_name);
                try emitIdent(allocator, buf, tuple_name);
                try buf.appendSlice(allocator, ": ");
                try emitType(allocator, buf, g, f.ty);
                try buf.appendSlice(allocator, ",\n");
            }
        },
        .unit => {},
    }
    if (sb.fields.len > 0 and (sb.methods.len > 0 or sb.has_dynamic_resources)) {
        try buf.append(allocator, '\n');
    }

    // 2. Self type alias
    if (sb.methods.len > 0 or sb.has_dynamic_resources) {
        try writeIndent(allocator, buf, depth);
        try buf.appendSlice(allocator, "pub const Self = @This();\n\n");
    }

    // 3. Dynamic resource init if needed
    if (sb.has_dynamic_resources) {
        try writeIndent(allocator, buf, depth);
        try buf.appendSlice(allocator, "pub fn init(allocator: std.mem.Allocator) Self {\n");
        try writeIndent(allocator, buf, depth + 1);
        try buf.appendSlice(allocator, "return .{\n");
        for (sb.fields) |f| {
            try writeIndent(allocator, buf, depth + 2);
            try buf.append(allocator, '.');
            try emitIdent(allocator, buf, f.name);
            if (std.mem.eql(u8, f.name, "allocator")) {
                try buf.appendSlice(allocator, " = allocator,\n");
            } else {
                try buf.appendSlice(allocator, " = undefined,\n");
            }
        }
        try writeIndent(allocator, buf, depth + 1);
        try buf.appendSlice(allocator, "};\n");
        try writeIndent(allocator, buf, depth);
        try buf.appendSlice(allocator, "}\n\n");
    }

    // 4. Inherent methods
    for (sb.methods, 0..) |m, i| {
        if (i > 0) try buf.append(allocator, '\n');
        try writeIndent(allocator, buf, depth);
        const m_pub = visPrefix(m.visibility);
        try buf.appendSlice(allocator, m_pub);
        try buf.appendSlice(allocator, "fn ");
        try emitIdent(allocator, buf, m.name);
        try emitMethodSignature(allocator, buf, g, m.receiver, m.params, m.ret, m.is_allocating);
        try buf.append(allocator, ' ');
        try emitExpr(allocator, buf, g, b, m.body, depth + 1, true, false);
        try buf.append(allocator, '\n');
    }

    // 5. Hoist inherent methods from `impl <StructName>` blocks.
    var prev_was_method = sb.methods.len > 0;
    for (g.symbol_table.entities.items) |ent| {
        if (ent.kind != .impl_) continue;
        if (!std.mem.eql(u8, ent.name, struct_name) and !std.mem.endsWith(u8, ent.name, struct_name)) continue;
        for (g.symbol_table.entities.items) |child| {
            if (child.parent != ent.id) continue;
            if (child.kind != .fn_) continue;
            const already = blk: {
                for (sb.methods) |m| {
                    if (std.mem.eql(u8, m.name, child.name)) break :blk true;
                }
                break :blk false;
            };
            if (already) continue;
            if (prev_was_method) try buf.append(allocator, '\n');
            prev_was_method = true;

            try writeIndent(allocator, buf, depth);
            const c_pub = visPrefix(child.visibility);
            try buf.appendSlice(allocator, c_pub);
            try buf.appendSlice(allocator, "fn ");
            try emitIdent(allocator, buf, entityName(child));
            if (child.id < b.bodies.len) {
                switch (b.bodies[child.id]) {
                    .fn_ => |fb| {
                        try emitFnSignature(allocator, buf, g, fb.params, fb.ret, fb.is_allocating);
                        try buf.append(allocator, ' ');
                        if (fb.body < b.exprs.len) {
                            try emitFnBody(allocator, buf, g, b, fb.body, fb.params, fb.ret, depth + 1);
                        } else {
                            try buf.appendSlice(allocator, "{\n");
                            for (fb.params) |p| {
                                try writeIndent(allocator, buf, depth + 1);
                                try buf.appendSlice(allocator, "_ = ");
                                try emitIdent(allocator, buf, p.name);
                                try buf.appendSlice(allocator, ";\n");
                            }
                            try writeIndent(allocator, buf, depth);
                            try buf.append(allocator, '}');
                        }
                        try buf.append(allocator, '\n');
                        continue;
                    },
                    else => {},
                }
            }
            // Signature-only fallback.
            try buf.appendSlice(allocator, "() void {\n");
            try writeIndent(allocator, buf, depth + 1);
            try buf.appendSlice(allocator, "// body not yet lowered\n");
            try writeIndent(allocator, buf, depth);
            try buf.append(allocator, '}');
            try buf.append(allocator, '\n');
        }
    }
}

fn emitTraitDef(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    b: *const Bodies,
    e: spine.Entity,
    tb: bodies_mod.TraitBody,
) !void {
    _ = b;
    const pub_ = visPrefix(e.visibility);
    const trait_name = entityName(e);

    try buf.appendSlice(allocator, pub_);
    try buf.appendSlice(allocator, "const ");
    try emitIdent(allocator, buf, trait_name);
    try buf.appendSlice(allocator, " = struct {\n");

    // 1. VTable definition
    try buf.appendSlice(allocator, "    pub const VTable = struct {\n");
    for (tb.supertraits) |st| {
        try buf.appendSlice(allocator, "        ");
        try emitIdent(allocator, buf, st);
        try buf.appendSlice(allocator, ": ");
        try emitIdent(allocator, buf, st);
        try buf.appendSlice(allocator, ".VTable,\n");
    }
    for (tb.methods) |m| {
        try buf.appendSlice(allocator, "        ");
        try emitIdent(allocator, buf, m.name);
        try buf.appendSlice(allocator, ": *const fn (ctx: *anyopaque");
        for (m.params) |p| {
            try buf.appendSlice(allocator, ", ");
            try emitIdent(allocator, buf, p.name);
            try buf.appendSlice(allocator, ": ");
            try emitType(allocator, buf, g, p.ty);
        }
        try buf.appendSlice(allocator, ") ");
        try emitType(allocator, buf, g, m.ret);
        try buf.appendSlice(allocator, ",\n");
    }
    try buf.appendSlice(allocator, "    };\n\n");

    // 2. TraitObject fat pointer wrapper
    try buf.appendSlice(allocator, "    pub const TraitObject = struct {\n");
    try buf.appendSlice(allocator, "        ptr: *anyopaque,\n");
    try buf.appendSlice(allocator, "        vtable: *const VTable,\n\n");

    // Dispatch methods
    for (tb.methods) |m| {
        try buf.appendSlice(allocator, "        pub fn ");
        try emitIdent(allocator, buf, m.name);
        try buf.appendSlice(allocator, "(self: TraitObject");
        for (m.params) |p| {
            try buf.appendSlice(allocator, ", ");
            try emitIdent(allocator, buf, p.name);
            try buf.appendSlice(allocator, ": ");
            try emitType(allocator, buf, g, p.ty);
        }
        try buf.appendSlice(allocator, ") ");
        try emitType(allocator, buf, g, m.ret);
        try buf.appendSlice(allocator, " {\n");
        try buf.appendSlice(allocator, "            return self.vtable.");
        try emitIdent(allocator, buf, m.name);
        try buf.appendSlice(allocator, "(self.ptr");
        for (m.params) |p| {
            try buf.appendSlice(allocator, ", ");
            try emitIdent(allocator, buf, p.name);
        }
        try buf.appendSlice(allocator, ");\n");
        try buf.appendSlice(allocator, "        }\n");
    }

    // Supertrait upcasting helpers
    for (tb.supertraits) |st| {
        try buf.appendSlice(allocator, "        pub fn as");
        try emitIdent(allocator, buf, st);
        try buf.appendSlice(allocator, "(self: TraitObject) ");
        try emitIdent(allocator, buf, st);
        try buf.appendSlice(allocator, ".TraitObject {\n");
        try buf.appendSlice(allocator, "            return .{\n");
        try buf.appendSlice(allocator, "                .ptr = self.ptr,\n");
        try buf.appendSlice(allocator, "                .vtable = &self.vtable.");
        try emitIdent(allocator, buf, st);
        try buf.appendSlice(allocator, ",\n");
        try buf.appendSlice(allocator, "            };\n");
        try buf.appendSlice(allocator, "        }\n");
    }

    try buf.appendSlice(allocator, "    };\n");
    try buf.appendSlice(allocator, "};\n");
}
fn emitEnumDef(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    e: spine.Entity,
    eb: bodies_mod.EnumBody,
) !void {
    const pub_ = visPrefix(e.visibility);
    try buf.appendSlice(allocator, pub_);
    try buf.appendSlice(allocator, "const ");
    try emitIdent(allocator, buf, entityName(e));

    if (eb.kind == .c_like) {
        if (eb.repr_int) |r| {
            const repr_name = switch (r) {
                .i8 => "i8",
                .i16 => "i16",
                .i32 => "i32",
                .i64 => "i64",
                .i128 => "i128",
                .u8 => "u8",
                .u16 => "u16",
                .u32 => "u32",
                .u64 => "u64",
                .u128 => "u128",
                .isize => "isize",
                .usize => "usize",
            };
            try buf.appendSlice(allocator, " = enum(");
            try buf.appendSlice(allocator, repr_name);
            try buf.appendSlice(allocator, ") {\n");
        } else {
            try buf.appendSlice(allocator, " = enum(u8) {\n");
        }

        for (eb.variants) |v| {
            try writeIndent(allocator, buf, 1);
            try emitIdent(allocator, buf, v.name);
            if (v.discriminant) |disc| {
                const disc_str = try std.fmt.allocPrint(allocator, " = {d}", .{disc});
                defer allocator.free(disc_str);
                try buf.appendSlice(allocator, disc_str);
            }
            try buf.appendSlice(allocator, ",\n");
        }
        try buf.appendSlice(allocator, "};\n");
    } else {
        // Data-carrying tagged union: `pub const Name = union(enum) { ... };`
        try buf.appendSlice(allocator, " = union(enum) {\n");
        for (eb.variants) |v| {
            try writeIndent(allocator, buf, 1);
            try emitIdent(allocator, buf, v.name);
            switch (v.fields) {
                .none => {
                    try buf.appendSlice(allocator, ",\n");
                },
                .tuple => |tup| {
                    if (tup.len == 1) {
                        try buf.appendSlice(allocator, ": ");
                        try emitType(allocator, buf, g, tup[0]);
                        try buf.appendSlice(allocator, ",\n");
                    } else {
                        try buf.appendSlice(allocator, ": struct {\n");
                        for (tup, 0..) |ty, i| {
                            try writeIndent(allocator, buf, 2);
                            const tuple_field_name = try std.fmt.allocPrint(allocator, "{d}", .{i});
                            defer allocator.free(tuple_field_name);
                            try emitIdent(allocator, buf, tuple_field_name);
                            try buf.appendSlice(allocator, ": ");
                            try emitType(allocator, buf, g, ty);
                            try buf.appendSlice(allocator, ",\n");
                        }
                        try writeIndent(allocator, buf, 1);
                        try buf.appendSlice(allocator, "},\n");
                    }
                },
                .named => |nf| {
                    try buf.appendSlice(allocator, ": struct {\n");
                    for (nf) |f| {
                        try writeIndent(allocator, buf, 2);
                        try emitIdent(allocator, buf, f.name);
                        try buf.appendSlice(allocator, ": ");
                        try emitType(allocator, buf, g, f.ty);
                        try buf.appendSlice(allocator, ",\n");
                    }
                    try writeIndent(allocator, buf, 1);
                    try buf.appendSlice(allocator, "},\n");
                },
            }
        }
        try buf.appendSlice(allocator, "};\n");
    }
}

fn emitMatch(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    b: *const Bodies,
    m: exprs.MatchExpr,
    depth: u32,
    is_comptime: bool,
) !void {
    try buf.appendSlice(allocator, "switch (");
    try emitExpr(allocator, buf, g, b, m.scrutinee, depth, true, is_comptime);
    try buf.appendSlice(allocator, ") {\n");

    for (m.arms) |arm| {
        try writeIndent(allocator, buf, depth + 1);

        var capture_name: ?[]const u8 = null;
        var struct_fields_slice: ?[]const exprs.FieldPat = null;
        for (arm.patterns, 0..) |pid, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            const pat = b.pats[pid];
            switch (pat.kind) {
                .wildcard => {
                    try buf.appendSlice(allocator, "else");
                },
                .path => |pp| {
                    if (pp.variant) |vname| {
                        try buf.append(allocator, '.');
                        try emitIdent(allocator, buf, vname);
                    } else if (g.symbol_table.get(pp.def)) |ent| {
                        if (ent.kind == .variant) {
                            try buf.append(allocator, '.');
                            try emitIdent(allocator, buf, entityName(ent));
                        } else {
                            try emitIdent(allocator, buf, entityName(ent));
                        }
                    } else {
                        try buf.append(allocator, '_');
                    }
                },
                .struct_pat => |sp| {
                    // A tuple-struct variant `Shape::Circle(r)` lowers to Zig
                    // `switch` prong `.Circle => |r|`. Resolve the variant
                    // name from its entity (enum variant or the extractor's
                    // synthetic leaf entity); data payloads bind a capture.
                    if (g.symbol_table.get(sp.def)) |ent| {
                        if (ent.kind == .variant or ent.kind == .field) {
                            try buf.append(allocator, '.');
                            try emitIdent(allocator, buf, entityName(ent));
                        } else if (ent.name.len > 0) {
                            try emitIdent(allocator, buf, entityName(ent));
                        } else {
                            try buf.append(allocator, '_');
                        }
                    } else {
                        try buf.append(allocator, '_');
                    }
                    // Bind payload as the Zig switch capture:
                    // If multiple named fields (e.g. `Rect { width, height }`), bind single struct capture `_rect`
                    // or if single field `Circle(r)`, bind `r`.
                    if (sp.fields.len == 1) {
                        if (sp.fields[0].pat) |fpat_id| {
                            const fpat = b.pats[fpat_id];
                            switch (fpat.kind) {
                                .binding => |bd| capture_name = bd.name,
                                else => capture_name = sp.fields[0].field,
                            }
                        } else {
                            capture_name = sp.fields[0].field;
                        }
                    } else if (sp.fields.len > 1) {
                        capture_name = "_payload";
                        struct_fields_slice = sp.fields;
                    }
                },
                .tuple => |tp| {
                    if (tp.elements.len > 0) {
                        const first_pat = b.pats[tp.elements[0]];
                        switch (first_pat.kind) {
                            .binding => |bd| capture_name = bd.name,
                            else => {},
                        }
                    }
                },
                .binding => |bd| {
                    capture_name = bd.name;
                    try emitIdent(allocator, buf, bd.name);
                },
                else => {
                    try emitPattern(allocator, buf, b, pid);
                },
            }
        }

        try buf.appendSlice(allocator, " => ");
        const has_payload_unpack = (capture_name != null and std.mem.eql(u8, capture_name.?, "_payload") and struct_fields_slice != null);
        if (capture_name) |cap| {
            try buf.append(allocator, '|');
            try emitIdent(allocator, buf, cap);
            try buf.appendSlice(allocator, "| ");
        }

        if (has_payload_unpack) {
            try buf.appendSlice(allocator, "{\n");
            for (struct_fields_slice.?) |fld| {
                try writeIndent(allocator, buf, depth + 2);
                try buf.appendSlice(allocator, "const ");
                try emitIdent(allocator, buf, fld.field);
                try buf.appendSlice(allocator, " = _payload.");
                try emitIdent(allocator, buf, fld.field);
                try buf.appendSlice(allocator, ";\n");
            }
            try writeIndent(allocator, buf, depth + 2);
            if (arm.guard) |gid| {
                try buf.appendSlice(allocator, "if (");
                try emitExpr(allocator, buf, g, b, gid, depth + 2, true, is_comptime);
                try buf.appendSlice(allocator, ") ");
                try emitExpr(allocator, buf, g, b, arm.body, depth + 2, true, is_comptime);
                try buf.appendSlice(allocator, " else unreachable;\n");
            } else {
                try buf.appendSlice(allocator, "return ");
                try emitExpr(allocator, buf, g, b, arm.body, depth + 2, true, is_comptime);
                try buf.appendSlice(allocator, ";\n");
            }
            try writeIndent(allocator, buf, depth + 1);
            try buf.append(allocator, '}');
        } else {
            if (arm.guard) |gid| {
                try buf.appendSlice(allocator, "if (");
                try emitExpr(allocator, buf, g, b, gid, depth + 1, true, is_comptime);
                try buf.appendSlice(allocator, ") ");
                try emitExpr(allocator, buf, g, b, arm.body, depth + 1, true, is_comptime);
                try buf.appendSlice(allocator, " else unreachable");
            } else {
                try emitExpr(allocator, buf, g, b, arm.body, depth + 1, true, is_comptime);
            }
        }
        try buf.appendSlice(allocator, ",\n");
    }

    try writeIndent(allocator, buf, depth);
    try buf.append(allocator, '}');
}

/// Append `bytes` as the BODY of a valid Zig string literal (no surrounding
/// quotes): backslashes, double quotes, and control characters are escaped
/// (`\\`, `\"`, `\n`, `\r`, `\t`, `\xNN`). Printable ASCII and UTF-8 pass
/// through, so the result is always a syntactically valid literal.
fn appendEscapedString(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    bytes: []const u8,
) !void {
    for (bytes) |ch| {
        switch (ch) {
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 0x20 or ch == 0x7f) {
                    const hex = try std.fmt.allocPrint(allocator, "\\x{x:0>2}", .{ch});
                    defer allocator.free(hex);
                    try buf.appendSlice(allocator, hex);
                } else {
                    try buf.append(allocator, ch);
                }
            },
        }
    }
}

fn emitUnsupportedExpr(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    reason: []const u8,
    is_comptime: bool,
) !void {
    if (is_comptime) {
        // Never @panic at comptime: const/static initializers are evaluated
        // at compile time, where a panic is a compile error.
        try buf.appendSlice(allocator, "// translate-rust: unsupported ");
        try appendEscapedString(allocator, buf, reason);
        try buf.append(allocator, '\n');
        try buf.appendSlice(allocator, "undefined");
    } else {
        // `if (true) @panic(...)` prevents unreachable code errors while
        // coercing in value positions so downstream references typecheck.
        try buf.appendSlice(allocator, "if (true) @panic(\"translate-rust: unsupported: ");
        try appendEscapedString(allocator, buf, reason);
        try buf.appendSlice(allocator, "\")");
    }
}

fn emitExpr(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    b: *const Bodies,
    expr_id: exprs.NodeId,
    depth: u32,
    value_position: bool,
    is_comptime: bool,
) anyerror!void {
    const e = b.exprs[expr_id];
    switch (e.kind) {
        .literal => |lit| switch (lit) {
            .int => |i| try buf.appendSlice(allocator, i.text),
            .string => |s| {
                try buf.append(allocator, '"');
                try buf.appendSlice(allocator, s.bytes);
                try buf.append(allocator, '"');
            },
            .byte_array => |ba| try emitByteArrayLit(allocator, buf, ba.items),
            .float => |fl| {
                if (fl.text.len > 0) {
                    // Ensure the token reads as a float literal for Zig
                    // (Rust allows `1` or `1.` which Zig requires as `1.0`).
                    if (std.mem.indexOfAny(u8, fl.text, ".eE") != null) {
                        try buf.appendSlice(allocator, fl.text);
                    } else {
                        try buf.appendSlice(allocator, fl.text);
                        try buf.appendSlice(allocator, ".0");
                    }
                } else {
                    var tmp: [64]u8 = undefined;
                    const formatted = try std.fmt.bufPrint(&tmp, "{d}", .{fl.value});
                    try buf.appendSlice(allocator, formatted);
                    if (std.mem.indexOfAny(u8, formatted, ".eE") == null) {
                        try buf.appendSlice(allocator, ".0");
                    }
                }
            },
            .character => |c| {
                const formatted = try std.fmt.allocPrint(allocator, "'{c}'", .{@as(u8, @truncate(c.value))});
                defer allocator.free(formatted);
                try buf.appendSlice(allocator, formatted);
            },
            .boolean => |v| try buf.appendSlice(allocator, if (v) "true" else "false"),
        },
        .path => |pe| {
            if (g.symbol_table.get(pe.def)) |ent| {
                const ename = entityName(ent);
                if (std.mem.startsWith(u8, ename, "@")) {
                    try buf.appendSlice(allocator, ename);
                } else if (ent.kind == .variant) {
                    try buf.append(allocator, '.');
                    try emitIdent(allocator, buf, ename);
                } else {
                    try emitIdent(allocator, buf, ename);
                }
            } else {
                try buf.appendSlice(allocator, "/* unknown path */");
            }
        },
        .block => |blk| try emitBlock(allocator, buf, g, b, blk, depth, is_comptime),
        .unit => {},
        .return_ => |ret| {
            try buf.appendSlice(allocator, "return");
            if (ret.value) |vid| {
                try buf.append(allocator, ' ');
                try emitExpr(allocator, buf, g, b, vid, depth, true, is_comptime);
            }
        },
        .assign => |asgn| {
            try emitExpr(allocator, buf, g, b, asgn.target, depth, false, is_comptime);
            try buf.append(allocator, ' ');
            try buf.appendSlice(allocator, assignOpString(asgn.op, asgn.overflow));
            try buf.append(allocator, ' ');
            try emitExpr(allocator, buf, g, b, asgn.value, depth, true, is_comptime);
        },
        .for_ => |fe| {
            const iter_expr = b.exprs[fe.iterable];
            var is_chunks = false;
            var chunk_receiver: ?exprs.NodeId = null;
            var chunk_size: ?exprs.NodeId = null;

            if (iter_expr.kind == .method_call) {
                const mc = iter_expr.kind.method_call;
                if (mc.args.len >= 1) {
                    const m_ent = g.symbol_table.get(mc.method);
                    const m_name = if (m_ent) |me| me.name else "";
                    if (std.mem.eql(u8, m_name, "chunks") or std.mem.indexOf(u8, m_name, "chunks") != null) {
                        is_chunks = true;
                        chunk_receiver = mc.receiver;
                        chunk_size = mc.args[0];
                    }
                }
            }

            if (is_chunks) {
                try buf.appendSlice(allocator, "{\n");
                try writeIndent(allocator, buf, depth);
                try buf.appendSlice(allocator, "var chunk_i: usize = 0;\n");
                try writeIndent(allocator, buf, depth);
                try buf.appendSlice(allocator, "while (chunk_i < ");
                try emitExpr(allocator, buf, g, b, chunk_receiver.?, depth, true, is_comptime);
                try buf.appendSlice(allocator, ".len) : (chunk_i += ");
                try emitExpr(allocator, buf, g, b, chunk_size.?, depth, true, is_comptime);
                try buf.appendSlice(allocator, ") {\n");
                try writeIndent(allocator, buf, depth + 1);
                try buf.appendSlice(allocator, "const ");
                try emitPattern(allocator, buf, b, fe.pattern);
                try buf.appendSlice(allocator, " = ");
                try emitExpr(allocator, buf, g, b, chunk_receiver.?, depth, true, is_comptime);
                try buf.appendSlice(allocator, "[chunk_i..@min(chunk_i + ");
                try emitExpr(allocator, buf, g, b, chunk_size.?, depth, true, is_comptime);
                try buf.appendSlice(allocator, ", ");
                try emitExpr(allocator, buf, g, b, chunk_receiver.?, depth, true, is_comptime);
                try buf.appendSlice(allocator, ".len)];\n");
                try emitBlockBody(allocator, buf, g, b, fe.body, depth + 1, is_comptime);
                try writeIndent(allocator, buf, depth);
                try buf.appendSlice(allocator, "}\n");
                if (depth > 0) try writeIndent(allocator, buf, depth - 1);
                try buf.append(allocator, '}');
            } else {
                try buf.appendSlice(allocator, "for (");
                try emitExpr(allocator, buf, g, b, fe.iterable, depth, true, is_comptime);
                try buf.appendSlice(allocator, ") |");
                try emitPattern(allocator, buf, b, fe.pattern);
                try buf.appendSlice(allocator, "| ");
                try emitBlock(allocator, buf, g, b, fe.body, depth + 1, is_comptime);
            }
        },
        .while_ => |we| {
            try buf.appendSlice(allocator, "while (");
            try emitExpr(allocator, buf, g, b, we.cond, depth, true, is_comptime);
            try buf.appendSlice(allocator, ")");
            if (we.capture) |cap_id| {
                try buf.appendSlice(allocator, " |");
                try emitPattern(allocator, buf, b, cap_id);
                try buf.appendSlice(allocator, "|");
            }
            try buf.appendSlice(allocator, " ");
            try emitBlock(allocator, buf, g, b, we.body, depth + 1, is_comptime);
        },
        .if_else => |ie| {
            try buf.appendSlice(allocator, "if (");
            try emitExpr(allocator, buf, g, b, ie.cond, depth, true, is_comptime);
            try buf.appendSlice(allocator, ") ");
            try emitBranch(allocator, buf, g, b, ie.then_, depth, value_position, is_comptime);
            switch (ie.@"else") {
                .none => {},
                .block => |blk| {
                    try buf.appendSlice(allocator, " else ");
                    try emitBranch(allocator, buf, g, b, blk, depth, value_position, is_comptime);
                },
                .chain => |cid| {
                    try buf.appendSlice(allocator, " else ");
                    try emitExpr(allocator, buf, g, b, cid, depth, value_position, is_comptime);
                },
            }
        },
        .if_let => |ile| {
            try buf.appendSlice(allocator, "if (");
            try emitExpr(allocator, buf, g, b, ile.scrutinee, depth, true, is_comptime);
            try buf.appendSlice(allocator, ") |");
            try emitPattern(allocator, buf, b, ile.pattern);
            try buf.appendSlice(allocator, "| ");
            try emitBlock(allocator, buf, g, b, ile.then_, depth, is_comptime);
            switch (ile.@"else") {
                .none => {},
                .block => |blk| {
                    try buf.appendSlice(allocator, " else ");
                    try emitBlock(allocator, buf, g, b, blk, depth, is_comptime);
                },
                .chain => |cid| {
                    try buf.appendSlice(allocator, " else ");
                    try emitExpr(allocator, buf, g, b, cid, depth, value_position, is_comptime);
                },
            }
        },
        .match => |me| {
            try emitMatch(allocator, buf, g, b, me, depth, is_comptime);
        },
        .break_ => |be| {
            try buf.appendSlice(allocator, "break");
            if (be.value) |vid| {
                try buf.append(allocator, ' ');
                try emitExpr(allocator, buf, g, b, vid, depth, true, is_comptime);
            }
        },
        .continue_ => {
            try buf.appendSlice(allocator, "continue");
        },
        .loop_ => |le| {
            try buf.appendSlice(allocator, "while (true) ");
            try emitBlock(allocator, buf, g, b, le.body, depth + 1, is_comptime);
        },
        .binary => |be| {
            try emitOperand(allocator, buf, g, b, be.lhs, depth, is_comptime);
            try buf.append(allocator, ' ');
            try buf.appendSlice(allocator, binaryOpString(be.op, be.overflow));
            try buf.append(allocator, ' ');
            // Zig requires the shift amount of `<<`/`>>` to be a narrow unsigned
            // type (e.g. `u6` for a `u64` LHS), not a runtime `u64`. Comptime
            // integer literals are accepted as-is, but a dynamic RHS must be
            // narrowed explicitly or the emitted code fails to compile.
            const is_shift = be.op == .shl or be.op == .shr;
            const rhs_is_literal_int = switch (b.exprs[be.rhs].kind) {
                .literal => |lit| switch (lit) {
                    .int => true,
                    else => false,
                },
                else => false,
            };
            if (is_shift and !rhs_is_literal_int) {
                try buf.appendSlice(allocator, "@as(u6, @intCast(");
                try emitOperand(allocator, buf, g, b, be.rhs, depth, is_comptime);
                try buf.appendSlice(allocator, "))");
            } else {
                try emitOperand(allocator, buf, g, b, be.rhs, depth, is_comptime);
            }
        },
        .unary => |ue| {
            switch (ue.op) {
                .negate => {
                    try buf.append(allocator, '-');
                    try emitExpr(allocator, buf, g, b, ue.operand, depth, true, is_comptime);
                },
                .logical_not => {
                    try buf.append(allocator, '!');
                    try emitExpr(allocator, buf, g, b, ue.operand, depth, true, is_comptime);
                },
                .bit_not => {
                    try buf.appendSlice(allocator, "~");
                    try emitExpr(allocator, buf, g, b, ue.operand, depth, true, is_comptime);
                },
                .deref => {
                    try emitExpr(allocator, buf, g, b, ue.operand, depth, true, is_comptime);
                    try buf.appendSlice(allocator, ".*");
                },
                .ref => {
                    try buf.append(allocator, '&');
                    try emitExpr(allocator, buf, g, b, ue.operand, depth, true, is_comptime);
                },
            }
        },
        .call => |c| {
            switch (c.call_kind) {
                .free => |def| {
                    if (g.symbol_table.get(def)) |ent| {
                        const ename = entityName(ent);
                        if (std.mem.startsWith(u8, ename, "@")) {
                            try buf.appendSlice(allocator, ename);
                        } else {
                            try emitIdent(allocator, buf, ename);
                        }
                    } else {
                        try buf.appendSlice(allocator, "func");
                    }
                },
                .associated, .constructor => |def| {
                    if (g.symbol_table.get(def)) |ent| {
                        var owner: ?spine.Entity = null;
                        var parent_id = ent.parent;
                        while (parent_id) |pid| {
                            const parent_ent = g.symbol_table.get(pid) orelse break;
                            switch (parent_ent.kind) {
                                .struct_, .enum_, .union_ => {
                                    owner = parent_ent;
                                    break;
                                },
                                .impl_ => {
                                    for (g.symbol_table.entities.items) |candidate| {
                                        if (candidate.kind != .struct_ and candidate.kind != .enum_ and candidate.kind != .union_) continue;
                                        if (std.mem.eql(u8, parent_ent.name, candidate.name) or std.mem.startsWith(u8, parent_ent.name, candidate.name)) {
                                            owner = candidate;
                                            break;
                                        }
                                    }
                                    if (owner != null) break;
                                    parent_id = parent_ent.parent;
                                },
                                else => parent_id = parent_ent.parent,
                            }
                        }
                        if (owner) |type_ent| {
                            try emitIdent(allocator, buf, entityName(type_ent));
                            try buf.append(allocator, '.');
                        }
                        try emitIdent(allocator, buf, entityName(ent));
                    } else {
                        try buf.appendSlice(allocator, "Self.func");
                    }
                },
            }
            try buf.append(allocator, '(');
            for (c.args, 0..) |aid, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try emitExpr(allocator, buf, g, b, aid, depth, true, is_comptime);
            }
            try buf.append(allocator, ')');
        },
        .method_call => |mc| {
            try emitExpr(allocator, buf, g, b, mc.receiver, depth, true, is_comptime);
            try buf.append(allocator, '.');
            if (g.symbol_table.get(mc.method)) |me| {
                try emitIdent(allocator, buf, entityName(me));
            } else {
                try buf.appendSlice(allocator, "method");
            }
            try buf.append(allocator, '(');
            for (mc.args, 0..) |aid, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try emitExpr(allocator, buf, g, b, aid, depth, true, is_comptime);
            }
            try buf.append(allocator, ')');
        },
        .field => |fe| {
            try emitExpr(allocator, buf, g, b, fe.base, depth, true, is_comptime);
            try buf.append(allocator, '.');
            try emitIdent(allocator, buf, fe.field);
        },
        .index => |ie| {
            try emitExpr(allocator, buf, g, b, ie.base, depth, true, is_comptime);
            try buf.append(allocator, '[');
            try emitExpr(allocator, buf, g, b, ie.index, depth, true, is_comptime);
            try buf.append(allocator, ']');
        },
        .struct_lit => |sl| {
            // Emit a named struct literal (`Point{ .x = 0, .y = 0 }`) when the
            // target resolves to a named struct; otherwise fall back to an
            // anonymous `.{ .field = val }` literal.
            const named = blk: {
                if (g.symbol_table.get(sl.def)) |ent| {
                    if (ent.name.len > 0 and ent.kind != .field) break :blk true;
                }
                break :blk false;
            };
            if (named) {
                if (g.symbol_table.get(sl.def)) |ent| {
                    try emitIdent(allocator, buf, entityName(ent));
                } else {
                    try buf.append(allocator, '.');
                }
                try buf.append(allocator, '{');
            } else {
                try buf.appendSlice(allocator, ".{");
            }
            if (sl.fields.len > 0) {
                for (sl.fields, 0..) |fld, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try buf.appendSlice(allocator, " .");
                    try emitIdent(allocator, buf, fld.field);
                    try buf.appendSlice(allocator, " = ");
                    try emitExpr(allocator, buf, g, b, fld.value, depth, true, is_comptime);
                }
                try buf.appendSlice(allocator, " }");
            } else {
                try buf.append(allocator, '}');
            }
        },
        .try_ => |te| {
            try buf.appendSlice(allocator, "try ");
            try emitExpr(allocator, buf, g, b, te.inner, depth, true, is_comptime);
        },
        .enum_variant => |ev| {
            // A variant of an error-set enum (parent enum lives in the
            // synthetic `error` module) emits as a native error value
            // (`error.InvalidHexCharacter`) rather than a tagged-union
            // construction, so it type-checks as the error side of an
            // error-union return.
            if (errorSetEnumOf(g, ev.def)) |enum_ent| {
                _ = enum_ent;
                try buf.appendSlice(allocator, "error.");
                try emitIdent(allocator, buf, ev.variant);
                return;
            }
            try buf.appendSlice(allocator, ".{ .");
            try emitIdent(allocator, buf, ev.variant);
            if (ev.tuple_fields.len == 1) {
                try buf.appendSlice(allocator, " = ");
                try emitExpr(allocator, buf, g, b, ev.tuple_fields[0], depth, value_position, is_comptime);
            } else if (ev.tuple_fields.len > 1) {
                try buf.appendSlice(allocator, " = .{ ");
                for (ev.tuple_fields, 0..) |tf, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    const tf_name = try std.fmt.allocPrint(allocator, "@{s}{d}{s}", .{ "\"", i, "\"" });
                    defer allocator.free(tf_name);
                    try buf.appendSlice(allocator, tf_name);
                    try buf.appendSlice(allocator, " = ");
                    try emitExpr(allocator, buf, g, b, tf, depth, value_position, is_comptime);
                }
                try buf.appendSlice(allocator, " }");
            } else if (ev.named_fields.len > 0) {
                try buf.appendSlice(allocator, " = .{ ");
                for (ev.named_fields, 0..) |nf, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try buf.append(allocator, '.');
                    try emitIdent(allocator, buf, nf.field);
                    try buf.appendSlice(allocator, " = ");
                    try emitExpr(allocator, buf, g, b, nf.value, depth, value_position, is_comptime);
                }
                try buf.appendSlice(allocator, " }");
            }
            try buf.appendSlice(allocator, " }");
        },
        .vec_lit => try emitUnsupportedExpr(
            allocator,
            buf,
            "Vec literal: allocator-backed Vec adapter unavailable",
            is_comptime,
        ),
        .unsupported => |u| try emitUnsupportedExpr(allocator, buf, u.reason, is_comptime),
        else => {
            // Genuinely unhandled kinds (closure, iterator_chain, future seams).
            if (is_comptime) {
                try buf.appendSlice(allocator, "// translate-rust: unsupported expression\nundefined");
            } else if (value_position) {
                try buf.appendSlice(allocator, "if (true) @panic(\"translate-rust: unsupported expression\")");
            } else {
                try buf.appendSlice(allocator, "if (true) @panic(\"translate-rust: unsupported expression\")");
            }
        },
    }
}

fn emitStmt(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    b: *const Bodies,
    stmt_id: exprs.NodeId,
    depth: u32,
    is_comptime: bool,
) !void {
    const s = b.stmts[stmt_id];
    switch (s.kind) {
        .let => |ls| {
            try writeIndent(allocator, buf, depth);
            const pat = b.pats[ls.pattern];
            const mutable = switch (pat.kind) {
                .binding => |bd| bd.mutable,
                else => false,
            };
            try buf.appendSlice(allocator, if (mutable) "var " else "const ");
            try emitPattern(allocator, buf, b, ls.pattern);
            if (ls.ty) |ty_id| {
                try buf.appendSlice(allocator, ": ");
                try emitType(allocator, buf, g, b.types[ty_id]);
            }
            if (ls.init) |init_id| {
                try buf.appendSlice(allocator, " = ");
                try emitExpr(allocator, buf, g, b, init_id, depth, true, is_comptime);
            }
            try buf.appendSlice(allocator, ";\n");
        },
        .expr => |eid| {
            try writeIndent(allocator, buf, depth);
            try emitExpr(allocator, buf, g, b, eid, depth, false, is_comptime);
            // Control-flow exprs (for, while, if, …) are used as statements
            // without a trailing `;` in Zig; value expressions require one.
            const needs_semi = switch (b.exprs[eid].kind) {
                .for_, .while_, .loop_, .if_else, .if_let, .match, .block => false,
                else => true,
            };
            if (needs_semi) try buf.append(allocator, ';');
            try buf.append(allocator, '\n');
        },
        .item => {
            try writeIndent(allocator, buf, depth);
            try buf.appendSlice(allocator, "// unsupported: nested item in statement position");
            try buf.append(allocator, '\n');
        },
        .let_else => {
            try writeIndent(allocator, buf, depth);
            try buf.appendSlice(allocator, "// unsupported: let-else");
            try buf.append(allocator, '\n');
        },
    }
}

/// Emit block contents (statements + optional tail) without the outer braces.
/// Used when the caller already opened `{` (e.g. the fn_ emit path).
fn emitBlockBody(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    b: *const Bodies,
    block: exprs.BlockExpr,
    depth: u32,
    is_comptime: bool,
) !void {
    for (block.statements) |sid| {
        try emitStmt(allocator, buf, g, b, sid, depth, is_comptime);
    }
    if (block.tail) |tid| {
        try writeIndent(allocator, buf, depth);
        try emitExpr(allocator, buf, g, b, tid, depth, true, is_comptime);
        // Tail expressions always need `;` (return already handled via
        // emitStmt or emitBlock context — here we add unconditionally for
        // non-control-flow tails, which is the common case for value tails).
        const kind = b.exprs[tid].kind;
        switch (kind) {
            .return_ => try buf.append(allocator, ';'),
            .for_, .while_, .loop_, .if_else, .if_let, .match, .block => {},
            else => try buf.append(allocator, ';'),
        }
        try buf.append(allocator, '\n');
    }
}

fn emitBlock(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    b: *const Bodies,
    block: exprs.BlockExpr,
    depth: u32,
    is_comptime: bool,
) !void {
    if (block.statements.len == 0 and block.tail == null) {
        try buf.appendSlice(allocator, "{}");
        return;
    }
    try buf.append(allocator, '{');
    try buf.append(allocator, '\n');
    try emitBlockBody(allocator, buf, g, b, block, depth, is_comptime);
    // Closing brace at parent indentation.
    if (depth > 0) try writeIndent(allocator, buf, depth - 1);
    try buf.append(allocator, '}');
}

/// True when the type is a unit/void value (no data to return). A fn returning
/// an error union over unit (`FromHexError!void`) still returns no data.
fn typeIsUnit(ty: types.Type) bool {
    return switch (ty) {
        .prim => |p| p == .unit,
        .result => |r| if (r.is_error_unionable) typeIsUnit(r.ok) else false,
        else => false,
    };
}

/// Emit a fn body block. Unlike a generic block tail, a fn body whose tail is a
/// bare VALUE expression (a value-`if`, an operator expr, a path) must emit an
/// explicit `return <tail>;`: Zig parses a trailing value in a block as a
/// statement needing `;`, so `{ if (c) a else b }` (no semicolon) is a syntax
/// error. Existing `return <value>;` tails are emitted unchanged, and a void
fn isUnsupportedOrEmptyBody(b: *const Bodies, body_id: exprs.NodeId) bool {
    if (body_id >= b.exprs.len) return true;
    const body = b.exprs[body_id];
    if (body.kind != .block) return body.kind == .unsupported or body.kind == .vec_lit;
    const block = body.kind.block;
    if (block.statements.len == 0 and block.tail == null) return true;
    if (block.statements.len == 1 and block.tail == null) {
        const sid = block.statements[0];
        if (sid < b.stmts.len) {
            const stmt = b.stmts[sid];
            if (stmt.kind == .expr and stmt.kind.expr < b.exprs.len) {
                const e = b.exprs[stmt.kind.expr];
                if (e.kind == .unsupported or e.kind == .vec_lit) return true;
            }
        }
    }
    return false;
}

fn emitFnBody(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    b: *const Bodies,
    body_id: exprs.NodeId,
    params: []const items.Param,
    ret: types.Type,
    depth: u32,
) !void {
    const body = b.exprs[body_id];
    if (body.kind != .block) {
        try buf.append(allocator, '{');
        try buf.append(allocator, '\n');
        try writeIndent(allocator, buf, depth);
        if (!typeIsUnit(ret)) {
            try buf.appendSlice(allocator, "return ");
        }
        try emitExpr(allocator, buf, g, b, body_id, depth, true, false);
        try buf.append(allocator, ';');
        try buf.append(allocator, '\n');
        try writeIndent(allocator, buf, depth - 1);
        try buf.append(allocator, '}');
        return;
    }
    const block = body.kind.block;
    if (block.statements.len == 0 and block.tail == null) {
        if (params.len == 0) {
            try buf.appendSlice(allocator, "{}");
            return;
        }
        try buf.appendSlice(allocator, "{\n");
        for (params) |p| {
            try writeIndent(allocator, buf, depth);
            try buf.appendSlice(allocator, "_ = ");
            try emitIdent(allocator, buf, p.name);
            try buf.appendSlice(allocator, ";\n");
        }
        try writeIndent(allocator, buf, depth - 1);
        try buf.append(allocator, '}');
        return;
    }
    const returns_no_value = typeIsUnit(ret);
    const should_discard_params = isUnsupportedOrEmptyBody(b, body_id);

    try buf.append(allocator, '{');
    try buf.append(allocator, '\n');
    if (should_discard_params) {
        for (params) |p| {
            try writeIndent(allocator, buf, depth);
            try buf.appendSlice(allocator, "_ = ");
            try emitIdent(allocator, buf, p.name);
            try buf.appendSlice(allocator, ";\n");
        }
    }
    for (block.statements) |sid| {
        try emitStmt(allocator, buf, g, b, sid, depth, false);
    }
    if (block.tail) |tid| {
        try writeIndent(allocator, buf, depth);
        const te = b.exprs[tid];
        switch (te.kind) {
            .return_ => {
                // `return <value>;` — the return_ expr already writes "return".
                try emitExpr(allocator, buf, g, b, tid, depth, true, false);
                try buf.append(allocator, ';');
            },
            .for_, .while_, .loop_ => {
                // Statement-kind control flow; no trailing `;`.
                try emitExpr(allocator, buf, g, b, tid, depth, false, false);
            },
            else => {
                // `if`/`match`/bare-value tail. For a void fn, an `if`/`match`
                // is a statement (no `;`); any other value tail is discarded
                // (`<value>;`). For a data-returning fn the tail is the return
                // value and must be wrapped in an explicit `return`.
                if (returns_no_value) {
                    switch (te.kind) {
                        .if_else, .if_let, .match => try emitExpr(allocator, buf, g, b, tid, depth, false, false),
                        else => {
                            try emitExpr(allocator, buf, g, b, tid, depth, true, false);
                            try buf.append(allocator, ';');
                        },
                    }
                } else {
                    try buf.appendSlice(allocator, "return ");
                    try emitExpr(allocator, buf, g, b, tid, depth, true, false);
                    try buf.append(allocator, ';');
                }
            },
        }
        try buf.append(allocator, '\n');
    }
    if (depth > 0) try writeIndent(allocator, buf, depth - 1);
    try buf.append(allocator, '}');
}

/// Emit a fixed byte-array literal as a Zig array expression that coerces to
/// `[]const u8` (the `&` of a comptime array). Non-uniform bytes produce an
/// explicit `&[_]u8{ 0x.., ... }` list; an all-equal array collapses to the
/// repeat form `&([_]u8{V} ** N)` so long runs (e.g. fletcher's 200k-zero
/// vectors) do not balloon the output.
fn emitByteArrayLit(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    bytes: []const u8,
) !void {
    if (bytes.len == 0) {
        try buf.appendSlice(allocator, "&[_]u8{}");
        return;
    }
    var all_equal = true;
    for (bytes[1..]) |x| {
        if (x != bytes[0]) {
            all_equal = false;
            break;
        }
    }
    if (all_equal) {
        const byte = try std.fmt.allocPrint(allocator, "0x{x:0>2}", .{bytes[0]});
        defer allocator.free(byte);
        const n = try std.fmt.allocPrint(allocator, "{d}", .{bytes.len});
        defer allocator.free(n);
        try buf.appendSlice(allocator, "&([_]u8{");
        try buf.appendSlice(allocator, byte);
        try buf.appendSlice(allocator, "} ** ");
        try buf.appendSlice(allocator, n);
        try buf.append(allocator, ')');
        return;
    }
    try buf.appendSlice(allocator, "&[_]u8{");
    for (bytes, 0..) |byte, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        const hex = try std.fmt.allocPrint(allocator, "0x{x:0>2}", .{byte});
        defer allocator.free(hex);
        try buf.appendSlice(allocator, hex);
    }
    try buf.append(allocator, '}');
}

/// Emit an `if` branch. When the branch block is a pure value (statement-less
/// with a tail expression), emit it as a bare value so the `if` reads as a
/// value expression (`if (c) 0 else result`) rather than a discarding block.
/// In value position, a `return X` tail is unwrapped to its value `X`, since a
/// bare `return` is not a valid if-branch value expression.
fn emitBranch(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    b: *const Bodies,
    block: exprs.BlockExpr,
    depth: u32,
    value_position: bool,
    is_comptime: bool,
) !void {
    if (block.statements.len == 0) {
        if (block.tail) |tid| {
            const te = b.exprs[tid];
            if (value_position and te.kind == .return_) {
                if (te.kind.return_.value) |vid| {
                    try emitExpr(allocator, buf, g, b, vid, depth, true, is_comptime);
                } else {
                    try buf.appendSlice(allocator, "{}");
                }
                return;
            }
            try emitExpr(allocator, buf, g, b, tid, depth, value_position, is_comptime);
            return;
        }
        try buf.appendSlice(allocator, "{}");
        return;
    }
    try emitBlock(allocator, buf, g, b, block, depth, is_comptime);
}

fn emitOperand(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    b: *const Bodies,
    expr_id: exprs.NodeId,
    depth: u32,
    is_comptime: bool,
) !void {
    // Parenthesize nested operator expressions so Zig's precedence preserves
    // the IR's AST grouping (e.g. `(a & b) + (c >> d)`).
    const needs_paren = switch (b.exprs[expr_id].kind) {
        .binary, .assign, .try_ => true,
        else => false,
    };
    if (needs_paren) {
        try buf.append(allocator, '(');
        try emitExpr(allocator, buf, g, b, expr_id, depth, true, is_comptime);
        try buf.append(allocator, ')');
    } else {
        try emitExpr(allocator, buf, g, b, expr_id, depth, true, is_comptime);
    }
}

fn emitFnSignature(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    params: []const items.Param,
    ret: types.Type,
    is_allocating: bool,
) !void {
    try buf.append(allocator, '(');
    var count: usize = 0;
    if (is_allocating) {
        try buf.appendSlice(allocator, "allocator: std.mem.Allocator");
        count += 1;
    }
    for (params) |p| {
        if (count > 0) try buf.appendSlice(allocator, ", ");
        try emitIdent(allocator, buf, p.name);
        try buf.appendSlice(allocator, ": ");
        try emitType(allocator, buf, g, p.ty);
        count += 1;
    }
    try buf.appendSlice(allocator, ") ");
    try emitType(allocator, buf, g, ret);
}

fn emitMethodSignature(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    receiver: ?items.Receiver,
    params: []const items.Param,
    ret: types.Type,
    is_allocating: bool,
) !void {
    try buf.append(allocator, '(');
    var count: usize = 0;
    if (is_allocating) {
        try buf.appendSlice(allocator, "allocator: std.mem.Allocator");
        count += 1;
    }
    if (receiver) |rec| {
        if (count > 0) try buf.appendSlice(allocator, ", ");
        switch (rec) {
            .owned => try buf.appendSlice(allocator, "self: Self"),
            .ref_ => try buf.appendSlice(allocator, "self: *const Self"),
            .mut_ref => try buf.appendSlice(allocator, "self: *Self"),
        }
        count += 1;
    }
    for (params) |p| {
        if (count > 0) try buf.appendSlice(allocator, ", ");
        try emitIdent(allocator, buf, p.name);
        try buf.appendSlice(allocator, ": ");
        try emitType(allocator, buf, g, p.ty);
        count += 1;
    }
    try buf.appendSlice(allocator, ") ");
    try emitType(allocator, buf, g, ret);
}

fn binaryOpString(op: exprs.BinaryOp, ov: exprs.Overflow) []const u8 {
    return switch (op) {
        .add => if (ov == .wrapping) "+%" else "+",
        .sub => if (ov == .wrapping) "-%" else "-",
        .mul => if (ov == .wrapping) "*%" else "*",
        .div => if (ov == .wrapping) "/%" else "/",
        .rem => if (ov == .wrapping) "%" else "%",
        .bit_and => "&",
        .bit_or => "|",
        .bit_xor => "^",
        .shl => "<<",
        .shr => ">>",
        .eq => "==",
        .ne => "!=",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        .boolean_and => "and",
        .boolean_or => "or",
    };
}

fn assignOpString(op: exprs.AssignOp, ov: exprs.Overflow) []const u8 {
    return switch (op) {
        .plain => "=",
        .add => if (ov == .wrapping) "+%=" else "+=",
        .sub => if (ov == .wrapping) "-%=" else "-=",
        .mul => if (ov == .wrapping) "*%=" else "*=",
        .div => if (ov == .wrapping) "/%=" else "/=",
        .rem => "%=",
        .bit_and => "&=",
        .bit_or => "|=",
        .bit_xor => "^=",
        .shl => "<<=",
        .shr => ">>=",
    };
}

// ── Vis / unsupported (unchanged from P2) ─────────────────────────────────

fn visPrefix(v: spine.Visibility) []const u8 {
    return switch (v) {
        .public => "pub ",
        else => "",
    };
}

fn unsupported(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    e: spine.Entity,
    label: []const u8,
) !void {
    try buf.appendSlice(allocator, "// unsupported: ");
    try buf.appendSlice(allocator, label);
    if (e.name.len > 0) {
        try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, e.name);
    }
    try buf.append(allocator, '\n');
}

// ---------------------------------------------------------------------------
// Test infrastructure (shared by P2 golden test and P3 golden test)
//
// Reads fixture files at runtime via `std.testing.io` + `std.Io.Dir.cwd()`.
// `@embedFile` would resolve relative to this file and could not reach `..`,
// which is the failure mode the P1 fixture tests already worked around.
// ---------------------------------------------------------------------------

fn readFixture(allocator: std.mem.Allocator, test_io: std.Io, path: []const u8) ![]const u8 {
    var io_buf: [4096]u8 = undefined;
    var dir = std.Io.Dir.cwd();
    const file = try dir.openFile(test_io, path, .{});
    defer file.close(test_io);
    var reader = file.reader(test_io, &io_buf);
    return reader.interface.allocRemaining(allocator, .limited(1 << 20));
}

/// Normalize text for comparison: strip `\r`, drop trailing whitespace per
/// line, and trim trailing blank lines. Returns a freshly allocated slice.
fn normalize(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= raw.len) {
        if (i == raw.len or raw[i] == '\n') {
            // Line = raw[line_start..i]. Strip trailing whitespace and `\r`.
            var end = i;
            while (end > line_start) {
                const c = raw[end - 1];
                if (c == ' ' or c == '\t' or c == '\r') {
                    end -= 1;
                } else break;
            }
            try out.appendSlice(allocator, raw[line_start..end]);
            try out.append(allocator, '\n');
            line_start = i + 1;
        }
        i += 1;
    }

    // Drop trailing blank lines so a `\n`-only terminator does not pad the
    // output. Keep at least one trailing `\n` so the result is a valid file.
    while (out.items.len >= 2 and out.items[out.items.len - 2] == '\n') {
        _ = out.pop();
    }
    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') {
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// P2 golden-file test — wire-driven (no bodies, P2 placeholder output)
// ---------------------------------------------------------------------------

test "emit fnv golden" {
    const allocator = std.testing.allocator;
    const test_io = std.testing.io;

    // 1) Read and parse the wire input (v2, with bodies).
    const json_bytes = try readFixture(allocator, test_io, "test/fnv.json");
    defer allocator.free(json_bytes);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const model = try json.parseFull(arena.allocator(), json_bytes);

    // 2) Emit Zig source text with full body lowering.
    const emitted = try emitRich(allocator, &model.graph, &model.bodies);
    defer allocator.free(emitted);

    // The golden model carries a struct (FnvHasher, tuple layout @"0": u64)
    // alongside the constants and fnv1a_hash function.
    //
    // 3a) FNV_OFFSET_BASIS — private const.
    try std.testing.expect(
        std.mem.indexOf(u8, emitted, "const FNV_OFFSET_BASIS") != null,
    );
    // 3b) FNV_PRIME — private const.
    try std.testing.expect(
        std.mem.indexOf(u8, emitted, "const FNV_PRIME") != null,
    );
    // 3c) fnv1a_hash — public fn with a real body (no placeholder).
    try std.testing.expect(
        std.mem.indexOf(u8, emitted, "pub fn fnv1a_hash") != null,
    );
    // 3d) FnvHasher — public tuple struct with @"0": u64 field.
    try std.testing.expect(
        std.mem.indexOf(u8, emitted, "pub const FnvHasher = struct {") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, emitted, "@\"0\": u64,") != null,
    );
    // 3e) Declarations appear in wire order: consts before fn.
    const basis_pos = std.mem.indexOf(u8, emitted, "const FNV_OFFSET_BASIS").?;
    const fn_pos = std.mem.indexOf(u8, emitted, "pub fn fnv1a_hash").?;
    try std.testing.expect(basis_pos < fn_pos);
}

// ---------------------------------------------------------------------------
// Smoke test: emit a hand-built CrateGraph and confirm the dispatcher
// produces structurally well-formed Zig without panicking on placeholder
// kinds. All strings passed to the graph are allocator-duped so that
// `g.deinit()` can safely free them via the debug allocator.
// ---------------------------------------------------------------------------

test "emit: dispatches every EntityKind without crashing" {
    const allocator = std.testing.allocator;
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();

    // Root module — name "" is safe because graph.deinit handles it.
    const root_id = try g.addModule(.{
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

    // All entity names must be allocator-duped so g.deinit() can free them.
    const fn_name = try allocator.dupe(u8, "do_thing");
    const const_name = try allocator.dupe(u8, "MAGIC");
    const struct_name = try allocator.dupe(u8, "Point");
    const enum_name = try allocator.dupe(u8, "Color");
    const trait_name = try allocator.dupe(u8, "Greet");

    const fn_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = fn_name,
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const const_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .const_,
        .name = const_name,
        .span = span,
        .visibility = .private,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const struct_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = struct_name,
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const enum_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .enum_,
        .name = enum_name,
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const trait_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .trait_,
        .name = trait_name,
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Wire the items into the root module.
    const items_slice = try allocator.alloc(spine.EntityId, 5);
    items_slice[0] = fn_id;
    items_slice[1] = const_id;
    items_slice[2] = struct_id;
    items_slice[3] = enum_id;
    items_slice[4] = trait_id;
    g.modules.items[root_id].items = items_slice;

    try g.addCrate(.{
        .name = try allocator.dupe(u8, "smoke"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    const out = try emit(allocator, &g);
    defer allocator.free(out);

    // Spot-check the structural pieces that the emitter must produce.
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn do_thing() void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "const MAGIC: void = // init not yet lowered") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const Point = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const Color = enum(u8) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "// unsupported: trait Greet") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "// body not yet lowered") != null);
}

test "emit: keyword escaping and renamed_to" {
    const allocator = std.testing.allocator;
    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();

    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };
    const root_id = try g.addModule(.{
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

    // Rust fn named "type" (a Zig keyword)
    const type_fn_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "type"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Rust const with explicit renamed_to="renamed_magic"
    const renamed_const_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .const_,
        .name = try allocator.dupe(u8, "orig_magic"),
        .span = span,
        .visibility = .private,
        .parent = root_id,
        .resolved = null,
        .renamed_to = try allocator.dupe(u8, "renamed_magic"),
        .attributes = &.{},
    });

    const items_slice = try allocator.alloc(spine.EntityId, 2);
    items_slice[0] = type_fn_id;
    items_slice[1] = renamed_const_id;
    g.modules.items[root_id].items = items_slice;

    try g.addCrate(.{
        .name = try allocator.dupe(u8, "keyword_smoke"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    const out = try emit(allocator, &g);
    defer allocator.free(out);
    // "type" must be escaped as @"type"
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn @\"type\"() void {") != null);
    // "orig_magic" with renamed_to="renamed_magic" must emit "renamed_magic"
    try std.testing.expect(std.mem.indexOf(u8, out, "const renamed_magic: void =") != null);
}

test "formatZig: formats unformatted valid Zig into canonical style" {
    const allocator = std.testing.allocator;
    const unformatted = "pub fn add( a:u64, b:u64 )u64{return a+b;}";
    const formatted = try formatZig(allocator, unformatted);
    defer allocator.free(formatted);

    try std.testing.expect(
        std.mem.indexOf(u8, formatted, "pub fn add(a: u64, b: u64) u64 {\n    return a + b;\n}") != null,
    );
}

test "M1: struct fields (named, tuple, unit) and methods" {
    const allocator = std.testing.allocator;
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();

    const root_id = try g.addModule(.{
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

    const named_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = try allocator.dupe(u8, "Point"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const tuple_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = try allocator.dupe(u8, "Pair"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const unit_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = try allocator.dupe(u8, "Marker"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const items_slice = try allocator.alloc(spine.EntityId, 3);
    items_slice[0] = named_id;
    items_slice[1] = tuple_id;
    items_slice[2] = unit_id;
    g.modules.items[root_id].items = items_slice;

    try g.addCrate(.{
        .name = try allocator.dupe(u8, "struct_test"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    const named_fields = try allocator.alloc(items.Field, 2);
    named_fields[0] = .{ .name = "x", .ty = .{ .prim = .i32 }, .visibility = .public, .span = span };
    named_fields[1] = .{ .name = "y", .ty = .{ .prim = .i32 }, .visibility = .public, .span = span };

    const tuple_fields = try allocator.alloc(items.Field, 2);
    tuple_fields[0] = .{ .name = "0", .ty = .{ .prim = .u64 }, .visibility = .public, .span = span };
    tuple_fields[1] = .{ .name = "1", .ty = .{ .prim = .bool }, .visibility = .public, .span = span };

    const methods = try allocator.alloc(bodies_mod.StructMethod, 1);
    methods[0] = .{
        .name = "distance",
        .visibility = .public,
        .params = &.{},
        .ret = .{ .prim = .f64 },
        .body = 1,
        .receiver = .ref_,
    };

    const exprs_store = try allocator.alloc(exprs.Expr, 2);
    exprs_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .literal = .{ .float = .{ .text = "0.0", .value = 0.0 } } },
    };
    exprs_store[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{ .statements = &.{}, .tail = 0, .labelled = null } },
    };

    const bodies_store = try allocator.alloc(bodies_mod.BodyKind, 4);
    bodies_store[0] = .none;
    bodies_store[named_id] = .{ .struct_ = .{
        .layout = .named,
        .fields = named_fields,
        .methods = methods,
    } };
    bodies_store[tuple_id] = .{ .struct_ = .{
        .layout = .tuple,
        .fields = tuple_fields,
    } };
    bodies_store[unit_id] = .{ .struct_ = .{
        .layout = .unit,
        .fields = &.{},
    } };

    const bodies: Bodies = .{
        .exprs = exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = bodies_store,
    };
    defer {
        allocator.free(named_fields);
        allocator.free(tuple_fields);
        allocator.free(methods);
        allocator.free(exprs_store);
        allocator.free(bodies_store);
    }

    const out = try emitRich(allocator, &g, &bodies);
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "pub const Point = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "x: i32,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "y: i32,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn distance(self: *const Self) f64 {") != null);

    try std.testing.expect(std.mem.indexOf(u8, out, "pub const Pair = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@\"0\": u64,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@\"1\": bool,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const Marker = struct {") != null);

    const formatted = try formatZig(allocator, out);
    defer allocator.free(formatted);
    try std.testing.expect(formatted.len > 0);
}

test "M1: enum variants (C-like, data tagged union, discriminants)" {
    const allocator = std.testing.allocator;
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();

    const root_id = try g.addModule(.{
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

    const clike_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .enum_,
        .name = try allocator.dupe(u8, "Color"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const data_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .enum_,
        .name = try allocator.dupe(u8, "Shape"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const items_slice = try allocator.alloc(spine.EntityId, 2);
    items_slice[0] = clike_id;
    items_slice[1] = data_id;
    g.modules.items[root_id].items = items_slice;

    try g.addCrate(.{
        .name = try allocator.dupe(u8, "enum_test"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    const color_variants = try allocator.alloc(items.Variant, 3);
    color_variants[0] = .{ .name = "red", .fields = .none, .discriminant = 0 };
    color_variants[1] = .{ .name = "green", .fields = .none, .discriminant = 1 };
    color_variants[2] = .{ .name = "blue", .fields = .none, .discriminant = 2 };

    const rect_fields = try allocator.alloc(items.Field, 2);
    rect_fields[0] = .{ .name = "width", .ty = .{ .prim = .f64 }, .visibility = .public, .span = span };
    rect_fields[1] = .{ .name = "height", .ty = .{ .prim = .f64 }, .visibility = .public, .span = span };

    const shape_variants = try allocator.alloc(items.Variant, 3);
    shape_variants[0] = .{ .name = "circle", .fields = .{ .tuple = &.{.{ .prim = .f64 }} }, .discriminant = null };
    shape_variants[1] = .{ .name = "rect", .fields = .{ .named = rect_fields }, .discriminant = null };
    shape_variants[2] = .{ .name = "dot", .fields = .none, .discriminant = null };

    const bodies_store = try allocator.alloc(bodies_mod.BodyKind, 3);
    bodies_store[0] = .none;
    bodies_store[clike_id] = .{ .enum_ = .{
        .kind = .c_like,
        .repr_int = .u8,
        .variants = color_variants,
    } };
    bodies_store[data_id] = .{ .enum_ = .{
        .kind = .data,
        .variants = shape_variants,
        .non_exhaustive = true,
    } };

    const bodies: Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = bodies_store,
    };
    defer {
        allocator.free(color_variants);
        allocator.free(rect_fields);
        allocator.free(shape_variants);
        allocator.free(bodies_store);
    }

    const out = try emitRich(allocator, &g, &bodies);
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "pub const Color = enum(u8) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "red = 0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "green = 1,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "blue = 2,") != null);

    try std.testing.expect(std.mem.indexOf(u8, out, "pub const Shape = union(enum) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "circle: f64,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "rect: struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "width: f64,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "height: f64,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "dot,") != null);

    const formatted = try formatZig(allocator, out);
    defer allocator.free(formatted);
    try std.testing.expect(formatted.len > 0);
}

test "M2: match and switch lowering (tagged union, ranges, guards)" {
    const allocator = std.testing.allocator;
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();

    const root_id = try g.addModule(.{
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

    const fn_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "eval_val"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const val_param_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try allocator.dupe(u8, "val"),
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const items_slice = try allocator.alloc(spine.EntityId, 1);
    items_slice[0] = fn_id;
    g.modules.items[root_id].items = items_slice;

    try g.addCrate(.{
        .name = try allocator.dupe(u8, "match_test"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    const exprs_store = try allocator.alloc(exprs.Expr, 9);
    exprs_store[0] = .{ .id = 0, .span = span, .ty = null, .kind = .{ .path = .{ .def = val_param_id, .generic_args = &.{} } } };
    exprs_store[1] = .{ .id = 1, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{ .text = "0", .value = 0, .base = .dec, .ty_suffix = null } } } };
    exprs_store[2] = .{ .id = 2, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{ .text = "100", .value = 100, .base = .dec, .ty_suffix = null } } } };
    exprs_store[3] = .{ .id = 3, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{ .text = "1", .value = 1, .base = .dec, .ty_suffix = null } } } };
    exprs_store[4] = .{ .id = 4, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{ .text = "5", .value = 5, .base = .dec, .ty_suffix = null } } } };
    exprs_store[5] = .{ .id = 5, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{ .text = "200", .value = 200, .base = .dec, .ty_suffix = null } } } };
    exprs_store[6] = .{ .id = 6, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{ .text = "300", .value = 300, .base = .dec, .ty_suffix = null } } } };

    const pats_store = try allocator.alloc(exprs.Pattern, 3);
    pats_store[0] = .{ .id = 0, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{ .text = "0", .value = 0, .base = .dec, .ty_suffix = null } } } };
    pats_store[1] = .{ .id = 1, .span = span, .ty = null, .kind = .{ .range = .{ .lo = 3, .hi = 4, .inclusive = true } } };
    pats_store[2] = .{ .id = 2, .span = span, .ty = null, .kind = .{ .wildcard = {} } };

    const arms = try allocator.alloc(exprs.MatchArm, 3);
    arms[0] = .{ .patterns = &.{0}, .guard = null, .body = 2 };
    arms[1] = .{ .patterns = &.{1}, .guard = null, .body = 5 };
    arms[2] = .{ .patterns = &.{2}, .guard = null, .body = 6 };

    exprs_store[7] = .{ .id = 7, .span = span, .ty = null, .kind = .{ .match = .{ .scrutinee = 0, .arms = arms } } };
    exprs_store[8] = .{ .id = 8, .span = span, .ty = null, .kind = .{ .block = .{ .statements = &.{}, .tail = 7, .labelled = null } } };

    const params = try allocator.alloc(items.Param, 1);
    params[0] = .{ .name = "val", .ty = .{ .prim = .i32 }, .span = span };

    const bodies_store = try allocator.alloc(bodies_mod.BodyKind, 2);
    bodies_store[0] = .none;
    bodies_store[fn_id] = .{ .fn_ = .{
        .params = params,
        .ret = .{ .prim = .i32 },
        .body = 8,
    } };

    const bodies: Bodies = .{
        .exprs = exprs_store,
        .stmts = &.{},
        .pats = pats_store,
        .types = &.{},
        .bodies = bodies_store,
    };
    defer {
        allocator.free(exprs_store);
        allocator.free(pats_store);
        allocator.free(arms);
        allocator.free(params);
        allocator.free(bodies_store);
    }

    const out = try emitRich(allocator, &g, &bodies);
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn eval_val(val: i32) i32 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "switch (val) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0 => 100,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1...5 => 200,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "else => 300,") != null);

    const formatted = try formatZig(allocator, out);
    defer allocator.free(formatted);
    try std.testing.expect(formatted.len > 0);
}

test "M2: error handling, try expressions, and while loop stepping" {
    const allocator = std.testing.allocator;
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();

    const root_id = try g.addModule(.{
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

    const parse_fn_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "parse_hex"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const i_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try allocator.dupe(u8, "i"),
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const len_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try allocator.dupe(u8, "len"),
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const err_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try allocator.dupe(u8, "error.InvalidHexCharacter"),
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const items_slice = try allocator.alloc(spine.EntityId, 1);
    items_slice[0] = parse_fn_id;
    g.modules.items[root_id].items = items_slice;

    try g.addCrate(.{
        .name = try allocator.dupe(u8, "err_while_test"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    const res_ptr = try allocator.create(types.Result);
    res_ptr.* = .{
        .ok = .{ .prim = .u8 },
        .err = .{ .prim = .unit },
        .is_error_unionable = true,
    };
    const res_type: types.Type = .{ .result = res_ptr };
    defer allocator.destroy(res_ptr);

    const exprs_store = try allocator.alloc(exprs.Expr, 10);
    exprs_store[0] = .{ .id = 0, .span = span, .ty = null, .kind = .{ .path = .{ .def = i_id, .generic_args = &.{} } } };
    exprs_store[1] = .{ .id = 1, .span = span, .ty = null, .kind = .{ .path = .{ .def = len_id, .generic_args = &.{} } } };
    exprs_store[2] = .{ .id = 2, .span = span, .ty = null, .kind = .{ .binary = .{ .op = .lt, .overflow = .checked, .lhs = 0, .rhs = 1 } } };
    exprs_store[3] = .{ .id = 3, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{ .text = "2", .value = 2, .base = .dec, .ty_suffix = null } } } };
    exprs_store[4] = .{ .id = 4, .span = span, .ty = null, .kind = .{ .assign = .{ .target = 0, .op = .add, .value = 3, .overflow = .checked } } };
    exprs_store[5] = .{ .id = 5, .span = span, .ty = null, .kind = .{ .path = .{ .def = err_id, .generic_args = &.{} } } };
    exprs_store[6] = .{ .id = 6, .span = span, .ty = null, .kind = .{ .return_ = .{ .value = 5 } } };
    exprs_store[7] = .{ .id = 7, .span = span, .ty = null, .kind = .{ .block = .{ .statements = &.{}, .tail = 6, .labelled = null } } };
    exprs_store[8] = .{ .id = 8, .span = span, .ty = null, .kind = .{ .while_ = .{ .cond = 2, .body = exprs_store[7].kind.block } } };
    exprs_store[9] = .{ .id = 9, .span = span, .ty = null, .kind = .{ .block = .{ .statements = &.{0}, .tail = null, .labelled = null } } };

    const stmts_store = try allocator.alloc(exprs.Statement, 1);
    stmts_store[0] = .{ .id = 0, .span = span, .ty = null, .kind = .{ .expr = 8 } };

    const params = try allocator.alloc(items.Param, 2);
    params[0] = .{ .name = "i", .ty = .{ .prim = .usize }, .span = span };
    params[1] = .{ .name = "len", .ty = .{ .prim = .usize }, .span = span };

    const bodies_store = try allocator.alloc(bodies_mod.BodyKind, 6);
    bodies_store[0] = .none;
    bodies_store[parse_fn_id] = .{ .fn_ = .{
        .params = params,
        .ret = res_type,
        .body = 9,
    } };

    const bodies: Bodies = .{
        .exprs = exprs_store,
        .stmts = stmts_store,
        .pats = &.{},
        .types = &.{},
        .bodies = bodies_store,
    };
    defer {
        allocator.free(exprs_store);
        allocator.free(stmts_store);
        allocator.free(params);
        allocator.free(bodies_store);
    }

    const out = try emitRich(allocator, &g, &bodies);
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn parse_hex(i: usize, len: usize) !u8 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "while (i < len) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "return error.InvalidHexCharacter;") != null);

    const formatted = try formatZig(allocator, out);
    defer allocator.free(formatted);
    try std.testing.expect(formatted.len > 0);
}

test "M2: function calls, method calls, and builtin calls" {
    const allocator = std.testing.allocator;
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();

    const root_id = try g.addModule(.{
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

    const caller_fn_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "call_demo"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const helper_fn_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "helper"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const as_builtin_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "@as"),
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const intcast_builtin_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "@intCast"),
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const obj_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try allocator.dupe(u8, "obj"),
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const method_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "process"),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const items_slice = try allocator.alloc(spine.EntityId, 2);
    items_slice[0] = caller_fn_id;
    items_slice[1] = helper_fn_id;
    g.modules.items[root_id].items = items_slice;

    try g.addCrate(.{
        .name = try allocator.dupe(u8, "calls_test"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    // Expressions:
    // 0: 42 (IntLit)
    // 1: Call(free: helper_fn_id, args: [0])
    // 2: PathExpr @as
    // 3: PathExpr u64
    // 4: Call(free: as_builtin_id, args: [0])
    // 5: Call(free: intcast_builtin_id, args: [0])
    // 6: PathExpr obj
    // 7: MethodCall(receiver: 6, method: method_id, args: [0])
    // 8: Block
    const exprs_store = try allocator.alloc(exprs.Expr, 9);
    exprs_store[0] = .{ .id = 0, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{ .text = "42", .value = 42, .base = .dec, .ty_suffix = null } } } };
    exprs_store[1] = .{ .id = 1, .span = span, .ty = null, .kind = .{ .call = .{ .call_kind = .{ .free = helper_fn_id }, .args = &.{0} } } };
    exprs_store[2] = .{ .id = 2, .span = span, .ty = null, .kind = .{ .path = .{ .def = as_builtin_id, .generic_args = &.{} } } };
    exprs_store[3] = .{ .id = 3, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{ .text = "u64", .value = 0, .base = .dec, .ty_suffix = null } } } };
    exprs_store[4] = .{ .id = 4, .span = span, .ty = null, .kind = .{ .call = .{ .call_kind = .{ .free = as_builtin_id }, .args = &.{ 3, 0 } } } };
    exprs_store[5] = .{ .id = 5, .span = span, .ty = null, .kind = .{ .call = .{ .call_kind = .{ .free = intcast_builtin_id }, .args = &.{0} } } };
    exprs_store[6] = .{ .id = 6, .span = span, .ty = null, .kind = .{ .path = .{ .def = obj_id, .generic_args = &.{} } } };
    exprs_store[7] = .{ .id = 7, .span = span, .ty = null, .kind = .{ .method_call = .{ .receiver = 6, .receiver_mode = .shared, .method = method_id, .args = &.{0} } } };
    exprs_store[8] = .{ .id = 8, .span = span, .ty = null, .kind = .{ .block = .{ .statements = &.{ 0, 1, 2, 3 }, .tail = null, .labelled = null } } };

    const stmts_store = try allocator.alloc(exprs.Statement, 4);
    stmts_store[0] = .{ .id = 0, .span = span, .ty = null, .kind = .{ .expr = 1 } };
    stmts_store[1] = .{ .id = 1, .span = span, .ty = null, .kind = .{ .expr = 4 } };
    stmts_store[2] = .{ .id = 2, .span = span, .ty = null, .kind = .{ .expr = 5 } };
    stmts_store[3] = .{ .id = 3, .span = span, .ty = null, .kind = .{ .expr = 7 } };

    const bodies_store = try allocator.alloc(bodies_mod.BodyKind, 7);
    bodies_store[0] = .none;
    bodies_store[caller_fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 8,
    } };
    bodies_store[helper_fn_id] = .none;
    bodies_store[as_builtin_id] = .none;
    bodies_store[intcast_builtin_id] = .none;
    bodies_store[obj_id] = .none;
    bodies_store[method_id] = .none;

    const bodies: Bodies = .{
        .exprs = exprs_store,
        .stmts = stmts_store,
        .pats = &.{},
        .types = &.{},
        .bodies = bodies_store,
    };
    defer {
        allocator.free(exprs_store);
        allocator.free(stmts_store);
        allocator.free(bodies_store);
    }

    const out = try emitRich(allocator, &g, &bodies);
    defer allocator.free(out);

    // Free function call
    try std.testing.expect(std.mem.indexOf(u8, out, "helper(42);") != null);
    // Builtin calls
    try std.testing.expect(std.mem.indexOf(u8, out, "@as(u64, 42);") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@intCast(42);") != null);
    // Method call
    try std.testing.expect(std.mem.indexOf(u8, out, "obj.process(42);") != null);

    const formatted = try formatZig(allocator, out);
    defer allocator.free(formatted);
    try std.testing.expect(formatted.len > 0);
}

test "emit: associated call from generic impl uses nominal owner" {
    const allocator = std.testing.allocator;
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();

    const root_id = try g.addModule(.{
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

    const fletcher_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = try allocator.dupe(u8, "Fletcher"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const impl_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = try allocator.dupe(u8, "Fletcher<T>"),
        .span = span,
        .visibility = .private,
        .parent = fletcher_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const new_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "new"),
        .span = span,
        .visibility = .public,
        .parent = impl_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const caller_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "make_fletcher"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const root_items = try allocator.alloc(spine.EntityId, 1);
    root_items[0] = caller_id;
    g.modules.items[root_id].items = root_items;

    try g.addCrate(.{
        .name = try allocator.dupe(u8, "generic_impl_call"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    const exprs_store = try allocator.alloc(exprs.Expr, 2);
    exprs_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .call = .{ .call_kind = .{ .associated = new_id }, .args = &.{} } },
    };
    exprs_store[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{ .statements = &.{0}, .tail = null, .labelled = null } },
    };

    const stmts_store = try allocator.alloc(exprs.Statement, 1);
    stmts_store[0] = .{ .id = 0, .span = span, .ty = null, .kind = .{ .expr = 0 } };

    const bodies_store = try allocator.alloc(bodies_mod.BodyKind, 4);
    bodies_store[fletcher_id] = .none;
    bodies_store[impl_id] = .none;
    bodies_store[new_id] = .none;
    bodies_store[caller_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 1,
    } };

    const bodies: Bodies = .{
        .exprs = exprs_store,
        .stmts = stmts_store,
        .pats = &.{},
        .types = &.{},
        .bodies = bodies_store,
    };
    defer {
        allocator.free(exprs_store);
        allocator.free(stmts_store);
        allocator.free(bodies_store);
    }

    const out = try emitRich(allocator, &g, &bodies);
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "Fletcher.new();") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@\"Fletcher<T>\".new();") == null);
}

// Wire in the P2 `.unsupported`-expr emission tests.
test {
    _ = @import("emit_unsupported_test.zig");
}
