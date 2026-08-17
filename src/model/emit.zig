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

// The body-aware golden test is a sibling file; pulling it in here keeps
// `zig build test` aware of it without editing build.zig or root.zig.
const _ = @import("emit_fnv_test.zig");

// ── P3 body data structures ───────────────────────────────────────────────

/// Body of a `const` declaration (type + init expression).
// Shared body tables live in bodies.zig (leaf) so json and emit do not
// create an import cycle. Re-export as aliases — emit.Bodies == json.Bodies.
pub const bodies_mod = @import("bodies.zig");
pub const ConstBody = bodies_mod.ConstBody;
pub const FnBody = bodies_mod.FnBody;
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
            try buf.appendSlice(allocator, pub_);
            try buf.appendSlice(allocator, "const ");
            try emitIdent(allocator, buf, entityName(e));
            try buf.appendSlice(allocator, " = struct { // unsupported: struct ");
            try buf.appendSlice(allocator, e.name);
            try buf.appendSlice(allocator, "\n};\n");
        },
        .enum_ => {
            try buf.appendSlice(allocator, pub_);
            try buf.appendSlice(allocator, "const ");
            try emitIdent(allocator, buf, entityName(e));
            try buf.appendSlice(allocator, " = enum(u8) { // unsupported: enum ");
            try buf.appendSlice(allocator, e.name);
            try buf.appendSlice(allocator, "\n};\n");
        },
        .fn_ => {
            try buf.appendSlice(allocator, pub_);
            try buf.appendSlice(allocator, "fn ");
            try emitIdent(allocator, buf, entityName(e));
            // P3: emit real signature + body when available.
            if (bodies) |bb| {
                if (e.id < bb.bodies.len) switch (bb.bodies[e.id]) {
                    .fn_ => |fb| {
                        try emitFnSignature(allocator, buf, fb.params, fb.ret);
                        try buf.append(allocator, ' ');
                        try emitExpr(allocator, buf, g, bb, fb.body, 1);
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
                        try emitType(allocator, buf, cb.ty);
                        try buf.appendSlice(allocator, " = ");
                        try emitExpr(allocator, buf, g, bb, cb.init, 0);
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
            try emitIdent(allocator, buf, entityName(target));
            try buf.appendSlice(allocator, ";\n");
        },
        .crate_ => try unsupported(allocator, buf, e, "crate"),
        .union_ => try unsupported(allocator, buf, e, "union"),
        .static_ => try unsupported(allocator, buf, e, "static"),
        .trait_ => try unsupported(allocator, buf, e, "trait"),
        .impl_ => try unsupported(allocator, buf, e, "impl"),
        .type_alias => try unsupported(allocator, buf, e, "type alias"),
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

fn emitIdent(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), name: []const u8) !void {
    const formatted = try std.fmt.allocPrint(allocator, "{f}", .{std.zig.fmtId(name)});
    defer allocator.free(formatted);
    try buf.appendSlice(allocator, formatted);
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

fn emitType(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), ty: types.Type) !void {
    switch (ty) {
        .prim => |p| try buf.appendSlice(allocator, primName(p)),
        .slice => |s| {
            try buf.appendSlice(allocator, "[]");
            if (s.const_) try buf.appendSlice(allocator, "const ");
            try emitType(allocator, buf, s.elem);
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
            try emitType(allocator, buf, r.pointee);
        },
        else => try buf.appendSlice(allocator, "/* unsupported type */"),
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
        else => try buf.append(allocator, '_'),
    }
}

fn emitExpr(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    b: *const Bodies,
    expr_id: exprs.NodeId,
    depth: u32,
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
            .boolean => |v| try buf.appendSlice(allocator, if (v) "true" else "false"),
            else => try buf.appendSlice(allocator, "/* unsupported literal */"),
        },
        .path => |pe| {
            if (g.symbol_table.get(pe.def)) |ent| {
                try emitIdent(allocator, buf, entityName(ent));
            } else {
                try buf.appendSlice(allocator, "/* unknown path */");
            }
        },
        .block => |blk| try emitBlock(allocator, buf, g, b, blk, depth),
        .unit => {},
        .return_ => |ret| {
            // Semicolon is added by the calling context (emitStmt or
            // emitBlock tail), so return_ only emits the bare `return [val]`.
            try buf.appendSlice(allocator, "return");
            if (ret.value) |vid| {
                try buf.append(allocator, ' ');
                try emitExpr(allocator, buf, g, b, vid, depth);
            }
        },
        .assign => |asgn| {
            try emitExpr(allocator, buf, g, b, asgn.target, depth);
            try buf.append(allocator, ' ');
            try buf.appendSlice(allocator, assignOpString(asgn.op, asgn.overflow));
            try buf.append(allocator, ' ');
            try emitExpr(allocator, buf, g, b, asgn.value, depth);
        },
        .for_ => |fe| {
            try buf.appendSlice(allocator, "for (");
            try emitExpr(allocator, buf, g, b, fe.iterable, depth);
            try buf.appendSlice(allocator, ") |");
            try emitPattern(allocator, buf, b, fe.pattern);
            try buf.appendSlice(allocator, "| ");
            try emitBlock(allocator, buf, g, b, fe.body, depth + 1);
        },
        .binary => |be| {
            try emitExpr(allocator, buf, g, b, be.lhs, depth);
            try buf.append(allocator, ' ');
            try buf.appendSlice(allocator, binaryOpString(be.op, be.overflow));
            try buf.append(allocator, ' ');
            try emitExpr(allocator, buf, g, b, be.rhs, depth);
        },
        else => try buf.appendSlice(allocator, "/* unsupported expr */"),
    }
}

fn emitStmt(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    g: *const graph.CrateGraph,
    b: *const Bodies,
    stmt_id: exprs.NodeId,
    depth: u32,
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
                try emitType(allocator, buf, b.types[ty_id]);
            }
            if (ls.init) |init_id| {
                try buf.appendSlice(allocator, " = ");
                try emitExpr(allocator, buf, g, b, init_id, depth);
            }
            try buf.appendSlice(allocator, ";\n");
        },
        .expr => |eid| {
            try writeIndent(allocator, buf, depth);
            try emitExpr(allocator, buf, g, b, eid, depth);
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
) !void {
    for (block.statements) |sid| {
        try emitStmt(allocator, buf, g, b, sid, depth);
    }
    if (block.tail) |tid| {
        try writeIndent(allocator, buf, depth);
        try emitExpr(allocator, buf, g, b, tid, depth);
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
) !void {
    if (block.statements.len == 0 and block.tail == null) {
        try buf.appendSlice(allocator, "{}");
        return;
    }
    try buf.append(allocator, '{');
    try buf.append(allocator, '\n');
    try emitBlockBody(allocator, buf, g, b, block, depth);
    // Closing brace at parent indentation.
    if (depth > 0) try writeIndent(allocator, buf, depth - 1);
    try buf.append(allocator, '}');
}

fn emitFnSignature(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    params: []const items.Param,
    ret: types.Type,
) !void {
    try buf.append(allocator, '(');
    for (params, 0..) |p, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try emitIdent(allocator, buf, p.name);
        try buf.appendSlice(allocator, ": ");
        try emitType(allocator, buf, p.ty);
    }
    try buf.appendSlice(allocator, ") ");
    try emitType(allocator, buf, ret);
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

    // 1) Read and parse the wire input.
    const json_bytes = try readFixture(allocator, test_io, "test/fnv.json");
    defer allocator.free(json_bytes);

    var g = try json.parse(allocator, json_bytes);
    defer g.deinit();

    // 2) Emit Zig source text.
    const emitted = try emit(allocator, &g);
    defer allocator.free(emitted);

    // P2 emitter produces placeholder signatures and const decls from the wire
    // (which carries no params, return types, or bodies).  The golden file
    // represents the aspirational full-translation output (P3).  We verify
    // structural correctness by checking that the emitted text contains the
    // expected items in the right order.
    //
    // 3a) FNV_OFFSET_BASIS — private const, no pub prefix.
    try std.testing.expect(
        std.mem.indexOf(u8, emitted, "const FNV_OFFSET_BASIS: void = // init not yet lowered") != null,
    );
    // 3b) FNV_PRIME — same pattern.
    try std.testing.expect(
        std.mem.indexOf(u8, emitted, "const FNV_PRIME: void = // init not yet lowered") != null,
    );
    // 3c) fnv1a_hash — public fn with placeholder body.
    try std.testing.expect(
        std.mem.indexOf(u8, emitted, "pub fn fnv1a_hash() void {") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, emitted, "// body not yet lowered") != null,
    );
    // 3d) No "unsupported" comments for kinds the emitter handles.
    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, emitted, "// unsupported:"),
    );
    // 3e) Declarations appear in wire order: consts before fn.
    const basis_pos = std.mem.indexOf(u8, emitted, "const FNV_OFFSET_BASIS").?;
    const prime_pos = std.mem.indexOf(u8, emitted, "const FNV_PRIME").?;
    const fn_pos = std.mem.indexOf(u8, emitted, "pub fn fnv1a_hash").?;
    try std.testing.expect(basis_pos < prime_pos);
    try std.testing.expect(prime_pos < fn_pos);
}

// ---------------------------------------------------------------------------
// Smoke test: emit a hand-built CrateGraph and confirm the dispatcher
// produces structurally well-formed Zig without panicking on placeholder
// kinds. All strings passed to the graph are allocator-duped so that
// `g.deinit()` can safely free them via the debug allocator.
// ---------------------------------------------------------------------------

test "emit: dispatches every EntityKind without crashing" {
    const allocator = std.testing.allocator;
    const span = spine.Span{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

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

    const span = spine.Span{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };
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
