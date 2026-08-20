//! resolve_methods — Method, Trait, Operator and Constructor resolution (P4).
//!
//! See notes/design/source-model-type-inference.md §3.3 + §5 (P4).
//!
//! After type inference gives concrete receiver types (P3), this pass
//! resolves method calls (`r.m(args)`), constructors (`T::new(...)`),
//! operators (`+`, `*`, `^`, ...), and trait implementations against:
//! 1. Inherent `impl <SelfTy> { fn m }` blocks defined in the crate.
//! 2. Trait `impl <Trait> for <SelfTy>` blocks defined in the crate.
//! 3. Built-in std prelude type methods (`Option`, `Result`, slice/array, numerics).
//!
//! Ambiguity or unresolvable methods cleanly degrade to `.unsupported` per-node.
//!
//! Pure Zig (C-free): imports only graph, spine, types, bodies, items, exprs.

const std = @import("std");
const ir = @import("translate_rust.ir");
const spine = ir.spine;
const graph = ir.graph;
const types = ir.types;
const bodies = ir.bodies;
const items = ir.items;
const exprs = ir.exprs;

pub const StdMethod = enum {
    option_is_some,
    option_is_none,
    option_unwrap,
    option_unwrap_or,
    option_map,
    option_as_ref,
    option_take,

    result_is_ok,
    result_is_err,
    result_unwrap,
    result_unwrap_or,
    result_map,
    result_map_err,
    result_as_ref,

    slice_len,
    slice_is_empty,
    slice_as_bytes,
    slice_as_slice,
    slice_iter,

    num_wrapping_add,
    num_wrapping_sub,
    num_wrapping_mul,
    num_saturating_add,
    num_saturating_sub,
    num_saturating_mul,
    num_count_ones,
    num_leading_zeros,
    num_trailing_zeros,

    default,
    clone,
};

pub const ResolutionStats = struct {
    inherent_resolved: usize = 0,
    trait_resolved: usize = 0,
    std_resolved: usize = 0,
    constructors_resolved: usize = 0,
    unsupported_methods: usize = 0,
    unsupported_operators: usize = 0,
};

const TraitImplParts = struct {
    trait_name: []const u8,
    type_name: []const u8,
};

const TraitMethodLookup = struct {
    candidate: ?spine.EntityId = null,
    count: usize = 0,
};

const reason_method_name_unavailable = "method name unavailable";
const reason_receiver_unavailable = "method receiver unavailable";
const reason_method_dispatch_unavailable = "method dispatch unavailable";
const reason_method_dispatch_ambiguous = "method dispatch ambiguous";
const reason_operator_operands_unresolved = "operator operands unresolved";
const reason_operator_requires_primitives = "operator requires primitive operands";

/// Strip references, paths, and generic arguments from a nominal spelling.
fn normalizeNominalName(name: []const u8) []const u8 {
    var normalized = std.mem.trim(u8, name, " \t\r\n&*");
    if (std.mem.startsWith(u8, normalized, "mut ")) normalized = normalized[4..];
    if (std.mem.startsWith(u8, normalized, "impl ")) normalized = normalized[5..];
    if (std.mem.indexOf(u8, normalized, "<")) |generic_start| {
        normalized = normalized[0..generic_start];
    }
    if (std.mem.lastIndexOf(u8, normalized, "::")) |path_separator| {
        normalized = normalized[path_separator + 2 ..];
    }
    return std.mem.trim(u8, normalized, " \t\r\n&*");
}

fn nominalNamesEqual(left: []const u8, right: []const u8) bool {
    const left_name = normalizeNominalName(left);
    const right_name = normalizeNominalName(right);
    return left_name.len > 0 and right_name.len > 0 and std.mem.eql(u8, left_name, right_name);
}

fn parseTraitImplName(name: []const u8) ?TraitImplParts {
    const separator = std.mem.indexOf(u8, name, " for ") orelse return null;
    const trait_name = std.mem.trim(u8, name[0..separator], " \t\r\n");
    const type_name = std.mem.trim(u8, name[separator + 5 ..], " \t\r\n");
    if (trait_name.len == 0 or type_name.len == 0) return null;
    return .{ .trait_name = trait_name, .type_name = type_name };
}

fn lookupTraitMethodCandidates(
    g: *const graph.CrateGraph,
    type_name: []const u8,
    method_name: []const u8,
    trait_name: ?[]const u8,
) TraitMethodLookup {
    var lookup: TraitMethodLookup = .{};
    if (normalizeNominalName(type_name).len == 0 or method_name.len == 0) return lookup;

    for (g.symbol_table.entities.items) |ent| {
        if (ent.kind != .impl_) continue;
        const parts = parseTraitImplName(ent.name) orelse continue;
        if (!nominalNamesEqual(parts.type_name, type_name)) continue;
        if (trait_name) |wanted_trait| {
            if (!nominalNamesEqual(parts.trait_name, wanted_trait)) continue;
        }

        for (g.symbol_table.entities.items) |child| {
            if (child.kind == .fn_ and child.parent == ent.id and
                std.mem.eql(u8, child.name, method_name))
            {
                lookup.candidate = child.id;
                lookup.count += 1;
            }
        }
    }
    return lookup;
}

/// Lookup an inherent method for `type_name` with `method_name`.
/// Returns the EntityId of the matching `fn` if found.
pub fn lookupInherentMethod(
    g: *const graph.CrateGraph,
    type_name: []const u8,
    method_name: []const u8,
) ?spine.EntityId {
    std.debug.assert(type_name.len >= 0);
    std.debug.assert(method_name.len >= 0);
    if (normalizeNominalName(type_name).len == 0 or method_name.len == 0) return null;

    for (g.symbol_table.entities.items) |ent| {
        if (ent.kind == .impl_ and parseTraitImplName(ent.name) == null and
            nominalNamesEqual(ent.name, type_name))
        {
            for (g.symbol_table.entities.items) |child| {
                if (child.kind == .fn_ and child.parent == ent.id and
                    std.mem.eql(u8, child.name, method_name))
                {
                    return child.id;
                }
            }
        }
    }
    return null;
}

/// Lookup a trait method `impl <trait_name> for <type_name> { fn <method_name> }`.
/// Returns the EntityId if a single candidate is found, or null on ambiguity/missing.
pub fn lookupTraitMethod(
    g: *const graph.CrateGraph,
    trait_name: []const u8,
    type_name: []const u8,
    method_name: []const u8,
) ?spine.EntityId {
    std.debug.assert(trait_name.len >= 0);
    std.debug.assert(type_name.len >= 0);
    std.debug.assert(method_name.len >= 0);
    if (trait_name.len == 0 or type_name.len == 0 or method_name.len == 0) return null;

    const lookup = lookupTraitMethodCandidates(g, type_name, method_name, trait_name);
    if (lookup.count == 1) return lookup.candidate;
    return null;
}

/// Lookup constructor or associated function `Type::fn_name(...)`.
pub fn lookupConstructor(
    g: *const graph.CrateGraph,
    type_name: []const u8,
    fn_name: []const u8,
) ?spine.EntityId {
    return lookupInherentMethod(g, type_name, fn_name);
}

/// Match std prelude methods on known types, automatically unwrapping references/pointers/boxes.
pub fn lookupStdMethod(
    t: types.Type,
    method_name: []const u8,
) ?StdMethod {
    std.debug.assert(method_name.len >= 0);
    if (method_name.len == 0) return null;

    // Unpeel reference / raw_ptr / boxed to find underlying concrete type.
    var cur_t = t;
    while (true) {
        switch (cur_t) {
            .reference => |r| cur_t = r.pointee,
            .raw_ptr => |ptr| cur_t = ptr.pointee,
            .boxed => |b| cur_t = b.*,
            else => break,
        }
    }

    switch (cur_t) {
        .option => {
            if (std.mem.eql(u8, method_name, "is_some")) return .option_is_some;
            if (std.mem.eql(u8, method_name, "is_none")) return .option_is_none;
            if (std.mem.eql(u8, method_name, "unwrap")) return .option_unwrap;
            if (std.mem.eql(u8, method_name, "unwrap_or")) return .option_unwrap_or;
            if (std.mem.eql(u8, method_name, "map")) return .option_map;
            if (std.mem.eql(u8, method_name, "as_ref")) return .option_as_ref;
            if (std.mem.eql(u8, method_name, "take")) return .option_take;
        },
        .result => {
            if (std.mem.eql(u8, method_name, "is_ok")) return .result_is_ok;
            if (std.mem.eql(u8, method_name, "is_err")) return .result_is_err;
            if (std.mem.eql(u8, method_name, "unwrap")) return .result_unwrap;
            if (std.mem.eql(u8, method_name, "unwrap_or")) return .result_unwrap_or;
            if (std.mem.eql(u8, method_name, "map")) return .result_map;
            if (std.mem.eql(u8, method_name, "map_err")) return .result_map_err;
            if (std.mem.eql(u8, method_name, "as_ref")) return .result_as_ref;
        },
        .slice, .array => {
            if (std.mem.eql(u8, method_name, "len")) return .slice_len;
            if (std.mem.eql(u8, method_name, "is_empty")) return .slice_is_empty;
            if (std.mem.eql(u8, method_name, "as_bytes")) return .slice_as_bytes;
            if (std.mem.eql(u8, method_name, "as_slice")) return .slice_as_slice;
            if (std.mem.eql(u8, method_name, "iter")) return .slice_iter;
        },
        .prim => |p| {
            switch (p) {
                .u8, .u16, .u32, .u64, .u128, .usize, .i8, .i16, .i32, .i64, .i128, .isize => {
                    if (std.mem.eql(u8, method_name, "wrapping_add")) return .num_wrapping_add;
                    if (std.mem.eql(u8, method_name, "wrapping_sub")) return .num_wrapping_sub;
                    if (std.mem.eql(u8, method_name, "wrapping_mul")) return .num_wrapping_mul;
                    if (std.mem.eql(u8, method_name, "saturating_add")) return .num_saturating_add;
                    if (std.mem.eql(u8, method_name, "saturating_sub")) return .num_saturating_sub;
                    if (std.mem.eql(u8, method_name, "saturating_mul")) return .num_saturating_mul;
                    if (std.mem.eql(u8, method_name, "count_ones")) return .num_count_ones;
                    if (std.mem.eql(u8, method_name, "leading_zeros")) return .num_leading_zeros;
                    if (std.mem.eql(u8, method_name, "trailing_zeros")) return .num_trailing_zeros;
                },
                else => {},
            }
        },
        else => {},
    }

    if (std.mem.eql(u8, method_name, "default")) return .default;
    if (std.mem.eql(u8, method_name, "clone")) return .clone;

    return null;
}

/// Helper to get a type's simple name from `types.Type` / symbol table.
pub fn getTypeName(g: *const graph.CrateGraph, t: types.Type) ?[]const u8 {
    switch (t) {
        .path => |p| {
            if (p.segments.len > 0) {
                const last = p.segments[p.segments.len - 1];
                if (last.name.len > 0) return last.name;
                if (last.id) |id| {
                    if (g.symbol_table.get(id)) |ent| return ent.name;
                }
            }
            return null;
        },
        .generic_inst => |gi| {
            if (g.symbol_table.get(gi.decl)) |ent| return ent.name;
            return null;
        },
        .prim => |p| return @tagName(p),
        .reference => |r| return getTypeName(g, r.pointee),
        .raw_ptr => |ptr| return getTypeName(g, ptr.pointee),
        .boxed => |b| return getTypeName(g, b.*),
        .option => return "Option",
        .result => return "Result",
        .slice => return "slice",
        .array => return "array",
        else => return null,
    }
}

fn inherentImplTypeName(g: *const graph.CrateGraph, target: spine.EntityId) ?[]const u8 {
    const method = g.symbol_table.get(target) orelse return null;
    if (method.kind != .fn_) return null;
    const parent_id = method.parent orelse return null;
    const impl = g.symbol_table.get(parent_id) orelse return null;
    if (impl.kind != .impl_ or parseTraitImplName(impl.name) != null) return null;

    const type_name = normalizeNominalName(impl.name);
    if (type_name.len == 0) return null;
    return type_name;
}

const LocalInitializerFinder = struct {
    b: *const bodies.Bodies,
    target_name: []const u8,
    target_ordinal: usize,
    binding_ordinal: usize,
    result: ?exprs.NodeId = null,

    fn visitPattern(self: *LocalInitializerFinder, pattern_id: exprs.NodeId, init: ?exprs.NodeId) void {
        if (self.result != null or pattern_id >= self.b.pats.len) return;
        switch (self.b.pats[pattern_id].kind) {
            .binding => |binding| {
                if (std.mem.eql(u8, binding.name, self.target_name)) {
                    if (self.binding_ordinal == self.target_ordinal) {
                        self.result = init;
                        return;
                    }
                    self.binding_ordinal += 1;
                }
            },
            .tuple => |tuple| for (tuple.elements) |element| self.visitPattern(element, init),
            .slice => |slice| {
                for (slice.elements) |element| self.visitPattern(element, init);
                if (slice.rest) |rest| self.visitPattern(rest, init);
            },
            .struct_pat => |struct_pat| for (struct_pat.fields) |field| {
                if (field.pat) |field_pattern| {
                    self.visitPattern(field_pattern, init);
                } else if (field.shorthand) {
                    if (std.mem.eql(u8, field.field, self.target_name)) {
                        if (self.binding_ordinal == self.target_ordinal) {
                            self.result = init;
                            return;
                        }
                        self.binding_ordinal += 1;
                    }
                }
            },
            .reference => |reference| self.visitPattern(reference.inner, init),
            .@"or" => |or_pattern| for (or_pattern.alternatives) |alternative| {
                self.visitPattern(alternative, init);
            },
            .wildcard, .literal, .path, .range => {},
        }
    }

    fn visitBlock(self: *LocalInitializerFinder, block: exprs.BlockExpr) void {
        if (self.result != null) return;
        for (block.statements) |statement| self.visitStmt(statement);
        if (block.tail) |tail| self.visitExpr(tail);
    }

    fn visitStmt(self: *LocalInitializerFinder, statement_id: exprs.NodeId) void {
        if (self.result != null or statement_id >= self.b.stmts.len) return;
        switch (self.b.stmts[statement_id].kind) {
            .let => |let_stmt| {
                if (let_stmt.init) |init| self.visitExpr(init);
                self.visitPattern(let_stmt.pattern, let_stmt.init);
            },
            .let_else => |let_else| {
                self.visitExpr(let_else.init);
                self.visitPattern(let_else.pattern, let_else.init);
                self.visitBlock(let_else.else_block);
            },
            .expr => |expression| self.visitExpr(expression),
            .item => {},
        }
    }

    fn visitElse(self: *LocalInitializerFinder, branch: exprs.ElseBranch) void {
        switch (branch) {
            .none => {},
            .block => |block| self.visitBlock(block),
            .chain => |node| self.visitExpr(node),
        }
    }

    fn visitExpr(self: *LocalInitializerFinder, node: exprs.NodeId) void {
        if (self.result != null or node >= self.b.exprs.len) return;
        switch (self.b.exprs[node].kind) {
            .block => |block| self.visitBlock(block),
            .if_else => |if_expr| {
                self.visitExpr(if_expr.cond);
                self.visitBlock(if_expr.then_);
                self.visitElse(if_expr.@"else");
            },
            .if_let => |if_let| {
                self.visitExpr(if_let.scrutinee);
                self.visitPattern(if_let.pattern, null);
                self.visitBlock(if_let.then_);
                self.visitElse(if_let.@"else");
            },
            .match => |match_expr| {
                self.visitExpr(match_expr.scrutinee);
                for (match_expr.arms) |arm| {
                    for (arm.patterns) |pattern| self.visitPattern(pattern, null);
                    if (arm.guard) |guard| self.visitExpr(guard);
                    self.visitExpr(arm.body);
                }
            },
            .loop_ => |loop_expr| self.visitBlock(loop_expr.body),
            .while_ => |while_expr| {
                self.visitExpr(while_expr.cond);
                if (while_expr.capture) |capture| self.visitPattern(capture, null);
                self.visitBlock(while_expr.body);
            },
            .for_ => |for_expr| {
                self.visitPattern(for_expr.pattern, null);
                self.visitExpr(for_expr.iterable);
                self.visitBlock(for_expr.body);
            },
            .break_ => |break_expr| if (break_expr.value) |value| self.visitExpr(value),
            .call => |call| for (call.args) |arg| self.visitExpr(arg),
            .method_call => |method| {
                self.visitExpr(method.receiver);
                for (method.args) |arg| self.visitExpr(arg);
            },
            .struct_lit => |literal| {
                for (literal.fields) |field| self.visitExpr(field.value);
                if (literal.base) |base| self.visitExpr(base);
            },
            .enum_variant => |variant| {
                for (variant.tuple_fields) |field| self.visitExpr(field);
                for (variant.named_fields) |field| self.visitExpr(field.value);
            },
            .field => |field| self.visitExpr(field.base),
            .index => |index| {
                self.visitExpr(index.base);
                self.visitExpr(index.index);
            },
            .binary => |binary| {
                self.visitExpr(binary.lhs);
                self.visitExpr(binary.rhs);
            },
            .unary => |unary| self.visitExpr(unary.operand),
            .assign => |assign| {
                self.visitExpr(assign.target);
                self.visitExpr(assign.value);
            },
            .try_ => |try_expr| self.visitExpr(try_expr.inner),
            .return_ => |return_expr| if (return_expr.value) |value| self.visitExpr(value),
            .array => |array| for (array.elements) |element| self.visitExpr(element),
            .literal, .unit, .path, .continue_, .closure, .iterator_chain, .unsupported => {},
        }
    }
};

fn findLocalInitializer(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    path: exprs.PathExpr,
) ?exprs.NodeId {
    const entity = g.symbol_table.get(path.def) orelse return null;
    const fn_id = entity.parent orelse return null;
    if (fn_id >= b.bodies.len) return null;
    const fn_body = switch (b.bodies[fn_id]) {
        .fn_ => |body| body,
        else => return null,
    };

    var target_ordinal: usize = 0;
    for (g.symbol_table.entities.items) |candidate| {
        if (candidate.id == path.def) break;
        if (candidate.kind == .field and candidate.parent == fn_id and
            std.mem.eql(u8, candidate.name, entity.name))
        {
            target_ordinal += 1;
        }
    }
    var parameter_ordinal: usize = 0;
    for (fn_body.params) |param| {
        if (std.mem.eql(u8, param.name, entity.name)) parameter_ordinal += 1;
    }

    var finder: LocalInitializerFinder = .{
        .b = b,
        .target_name = entity.name,
        .target_ordinal = target_ordinal,
        .binding_ordinal = parameter_ordinal,
    };
    finder.visitExpr(fn_body.body);
    return finder.result orelse null;
}

fn initializerReturnType(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    path: exprs.PathExpr,
) ?types.Type {
    const init = findLocalInitializer(g, b, path) orelse return null;
    if (init >= b.exprs.len) return null;
    return switch (b.exprs[init].kind) {
        .call => |call| switch (call.call_kind) {
            .associated, .free => |target| if (target < b.bodies.len)
                switch (b.bodies[target]) {
                    .fn_ => |fn_body| fn_body.ret,
                    else => null,
                }
            else
                null,
            .constructor => null,
        },
        else => null,
    };
}

fn initializerNominalName(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    path: exprs.PathExpr,
) ?[]const u8 {
    const init = findLocalInitializer(g, b, path) orelse return null;
    if (init >= b.exprs.len) return null;
    return switch (b.exprs[init].kind) {
        .call => |call| switch (call.call_kind) {
            .associated => |target| inherentImplTypeName(g, target),
            .constructor => |target| if (g.symbol_table.get(target)) |entity| entity.name else null,
            .free => null,
        },
        else => null,
    };
}

fn receiverNominalName(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    receiver_node: exprs.NodeId,
) ?[]const u8 {
    if (receiver_node >= b.exprs.len) return null;
    const receiver = b.exprs[receiver_node];

    var receiver_ty: ?types.Type = null;
    if (receiver.ty) |type_id| {
        if (type_id < b.types.len) receiver_ty = b.types[type_id];
    } else if (receiver.kind == .path) {
        // The path's resolved EntityId is the local binding identity. Use its
        // declaration/inferred type directly; never infer a type from spelling.
        receiver_ty = pathDeclaredType(g, b, receiver.kind.path);
    }
    if (receiver_ty) |ty| {
        if (getTypeName(g, ty)) |type_name| {
            const nominal_name = normalizeNominalName(type_name);
            if (nominal_name.len > 0) return nominal_name;
        }
    }

    if (receiver.kind == .path) {
        // A local initializer can carry the only available nominal linkage
        // when inference has not materialized a TypeId. Follow that exact
        // associated-call EntityId; never infer from the local's spelling.
        if (initializerNominalName(g, b, receiver.kind.path)) |type_name| {
            const nominal_name = normalizeNominalName(type_name);
            if (nominal_name.len > 0) return nominal_name;
        }
    }

    return switch (receiver.kind) {
        .call => |call| switch (call.call_kind) {
            .associated => |target| inherentImplTypeName(g, target),
            else => null,
        },
        .method_call => |method| inherentImplTypeName(g, method.method),
        else => null,
    };
}

fn pathDeclaredType(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    path: exprs.PathExpr,
) ?types.Type {
    const entity = g.symbol_table.get(path.def) orelse return null;
    const fn_id = entity.parent orelse return null;
    if (fn_id >= b.bodies.len) return null;
    const fn_body = switch (b.bodies[fn_id]) {
        .fn_ => |body| body,
        else => return null,
    };
    for (fn_body.params) |param| {
        if (std.mem.eql(u8, param.name, entity.name)) return param.ty;
    }

    // Local bindings have no declaration-type slot in the body model. If a
    // sibling occurrence of the same resolved EntityId was already inferred,
    // reuse that concrete type for this path as well.
    for (b.exprs) |expression| {
        if (expression.kind != .path) continue;
        if (expression.kind.path.def != path.def) continue;
        const type_id = expression.ty orelse continue;
        if (type_id < b.types.len) return b.types[type_id];
    }
    // If no sibling path was assigned a TypeId, preserve the local's exact
    // initializer return type for nominal dispatch and primitive checks.
    return initializerReturnType(g, b, path);
}

fn operandTypeResolved(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    node: exprs.NodeId,
) bool {
    if (node >= b.exprs.len) return false;
    const operand = b.exprs[node];
    if (operand.kind == .unsupported) return false;
    if (operand.ty) |type_id| {
        if (type_id >= b.types.len) return false;
        return b.types[type_id] != .unsupported;
    }
    return switch (operand.kind) {
        .literal => true,
        .path => |path| pathDeclaredType(g, b, path) != null,
        else => false,
    };
}

fn operandIsPrimitive(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    node: exprs.NodeId,
) bool {
    if (node >= b.exprs.len) return false;
    const operand = b.exprs[node];
    if (operand.ty) |type_id| {
        if (type_id >= b.types.len) return false;
        return b.types[type_id] == .prim;
    }
    return switch (operand.kind) {
        .literal => |literal| switch (literal) {
            .int, .float, .character, .boolean => true,
            .string, .byte_array => false,
        },
        .path => |path| switch (pathDeclaredType(g, b, path) orelse return false) {
            .prim => true,
            else => false,
        },
        else => false,
    };
}

fn replaceWithUnsupported(e: *exprs.Expr, reason: []const u8) void {
    e.kind = .{ .unsupported = .{
        .reason = reason,
        .suggested_version = .v1,
    } };
}

/// Resolve all method calls in `b.exprs` using the crate graph and types table.
pub fn resolveMethods(
    g: *const graph.CrateGraph,
    b: *bodies.Bodies,
) ResolutionStats {
    var stats: ResolutionStats = .{};
    for (@constCast(b.exprs)) |*e| {
        if (e.kind == .method_call) {
            const mc = &e.kind.method_call;
            const method_ent = g.symbol_table.get(mc.method);
            const method_name = if (method_ent) |ent| ent.name else "";
            if (method_name.len == 0) {
                replaceWithUnsupported(e, reason_method_name_unavailable);
                stats.unsupported_methods += 1;
                continue;
            }

            const receiver_node = mc.receiver;
            if (receiver_node >= b.exprs.len) {
                replaceWithUnsupported(e, reason_receiver_unavailable);
                stats.unsupported_methods += 1;
                continue;
            }

            const receiver = b.exprs[receiver_node];
            var receiver_ty: ?types.Type = null;
            if (receiver.ty) |type_id| {
                if (type_id < b.types.len) receiver_ty = b.types[type_id];
            } else if (receiver.kind == .path) {
                receiver_ty = pathDeclaredType(g, b, receiver.kind.path);
            }

            const receiver_name = receiverNominalName(g, b, receiver_node);
            if (receiver_name == null) {
                replaceWithUnsupported(e, reason_receiver_unavailable);
                stats.unsupported_methods += 1;
                continue;
            }

            var resolved = false;
            // Inherent methods have precedence over trait methods.
            if (lookupInherentMethod(g, receiver_name.?, method_name)) |fn_id| {
                mc.method = fn_id;
                stats.inherent_resolved += 1;
                resolved = true;
            }

            if (!resolved) {
                const trait_lookup =
                    lookupTraitMethodCandidates(g, receiver_name.?, method_name, null);
                if (trait_lookup.count > 1) {
                    replaceWithUnsupported(e, reason_method_dispatch_ambiguous);
                    stats.unsupported_methods += 1;
                    continue;
                }
                if (trait_lookup.count == 1) {
                    if (trait_lookup.candidate) |fn_id| {
                        mc.method = fn_id;
                        stats.trait_resolved += 1;
                        resolved = true;
                    }
                }
            }

            // Keep the standard-library table as the final method fallback.
            if (!resolved) {
                if (receiver_ty) |ty| {
                    if (lookupStdMethod(ty, method_name) != null) {
                        stats.std_resolved += 1;
                        resolved = true;
                    }
                }
            }

            if (!resolved) {
                replaceWithUnsupported(e, reason_method_dispatch_unavailable);
                stats.unsupported_methods += 1;
            }
        } else if (e.kind == .binary) {
            const binary = e.kind.binary;
            if (!operandTypeResolved(g, b, binary.lhs) or !operandTypeResolved(g, b, binary.rhs)) {
                replaceWithUnsupported(e, reason_operator_operands_unresolved);
                stats.unsupported_operators += 1;
            } else if (!operandIsPrimitive(g, b, binary.lhs) or !operandIsPrimitive(g, b, binary.rhs)) {
                replaceWithUnsupported(e, reason_operator_requires_primitives);
                stats.unsupported_operators += 1;
            }
        }
    }

    return stats;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "lookupInherentMethod and lookupConstructor" {
    const allocator = std.testing.allocator;
    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    const impl_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = try allocator.dupe(u8, "Point"),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const new_fn_id = try g.symbol_table.add(.{
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

    const dist_fn_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "distance"),
        .span = span,
        .visibility = .public,
        .parent = impl_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    try std.testing.expectEqual(dist_fn_id, lookupInherentMethod(&g, "Point", "distance"));
    try std.testing.expectEqual(new_fn_id, lookupConstructor(&g, "Point", "new"));
    try std.testing.expectEqual(@as(?spine.EntityId, null), lookupInherentMethod(&g, "Point", "nonexistent"));
    try std.testing.expectEqual(@as(?spine.EntityId, null), lookupInherentMethod(&g, "Other", "distance"));
}

test "lookupTraitMethod single candidate vs ambiguity" {
    const allocator = std.testing.allocator;
    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    const trait_impl_1 = try g.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = try allocator.dupe(u8, "Display for Point"),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const fmt_fn_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "fmt"),
        .span = span,
        .visibility = .public,
        .parent = trait_impl_1,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Single candidate -> resolves
    try std.testing.expectEqual(fmt_fn_id, lookupTraitMethod(&g, "Display", "Point", "fmt"));

    // Add ambiguous second impl of same trait & type
    const trait_impl_2 = try g.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = try allocator.dupe(u8, "Display for Point"),
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
        .name = try allocator.dupe(u8, "fmt"),
        .span = span,
        .visibility = .public,
        .parent = trait_impl_2,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Multiple candidates -> null
    try std.testing.expectEqual(@as(?spine.EntityId, null), lookupTraitMethod(&g, "Display", "Point", "fmt"));
}

test "lookupStdMethod coverage" {
    const opt_ty: types.Type = .{ .option = &.{ .prim = .i32 } };
    try std.testing.expectEqual(StdMethod.option_is_some, lookupStdMethod(opt_ty, "is_some"));
    try std.testing.expectEqual(StdMethod.option_unwrap, lookupStdMethod(opt_ty, "unwrap"));

    const res_ty: types.Type = .{ .result = &.{ .ok = .{ .prim = .i32 }, .err = .{ .prim = .u32 }, .is_error_unionable = true } };
    try std.testing.expectEqual(StdMethod.result_is_ok, lookupStdMethod(res_ty, "is_ok"));
    try std.testing.expectEqual(StdMethod.result_map_err, lookupStdMethod(res_ty, "map_err"));

    const slice_ty: types.Type = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } };
    try std.testing.expectEqual(StdMethod.slice_len, lookupStdMethod(slice_ty, "len"));

    const ref_slice: types.Type = .{ .reference = &.{ .mut = false, .pointee = slice_ty } };
    try std.testing.expectEqual(StdMethod.slice_is_empty, lookupStdMethod(ref_slice, "is_empty"));

    const prim_ty: types.Type = .{ .prim = .u64 };
    try std.testing.expectEqual(StdMethod.num_wrapping_add, lookupStdMethod(prim_ty, "wrapping_add"));
    try std.testing.expectEqual(StdMethod.num_count_ones, lookupStdMethod(prim_ty, "count_ones"));

    try std.testing.expectEqual(StdMethod.clone, lookupStdMethod(prim_ty, "clone"));
    try std.testing.expectEqual(StdMethod.default, lookupStdMethod(prim_ty, "default"));
}

test "resolveMethods pass updates method_call entity id and gathers stats" {
    const allocator = std.testing.allocator;
    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    const impl_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = try allocator.dupe(u8, "Fletcher16"),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const update_fn_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "update"),
        .span = span,
        .visibility = .public,
        .parent = impl_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const placeholder_update_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "update"),
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const placeholder_len_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "len"),
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const placeholder_unknown_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "unknown_method"),
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const seg = try allocator.alloc(types.PathSegment, 1);
    defer allocator.free(seg);
    seg[0] = .{ .name = "Fletcher16", .id = null };

    const types_store = try allocator.alloc(types.Type, 2);
    defer allocator.free(types_store);
    types_store[0] = .{ .path = .{ .segments = seg } };
    types_store[1] = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } };

    const exprs_store = try allocator.alloc(exprs.Expr, 6);
    defer allocator.free(exprs_store);
    // Node 0: receiver (Fletcher16)
    exprs_store[0] = .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } };
    // Node 1: fletcher.update(...) -> inherent
    exprs_store[1] = .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{ .receiver = 0, .receiver_mode = .mutable, .method = placeholder_update_id, .args = &.{} } } };
    // Node 2: receiver (slice)
    exprs_store[2] = .{ .id = 2, .span = span, .ty = 1, .kind = .{ .unit = {} } };
    // Node 3: slice.len() -> std
    exprs_store[3] = .{ .id = 3, .span = span, .ty = null, .kind = .{ .method_call = .{ .receiver = 2, .receiver_mode = .shared, .method = placeholder_len_id, .args = &.{} } } };
    // Node 4: receiver (Fletcher16)
    exprs_store[4] = .{ .id = 4, .span = span, .ty = 0, .kind = .{ .unit = {} } };
    // Node 5: fletcher.unknown_method() -> unsupported
    exprs_store[5] = .{ .id = 5, .span = span, .ty = null, .kind = .{ .method_call = .{ .receiver = 4, .receiver_mode = .shared, .method = placeholder_unknown_id, .args = &.{} } } };

    var b: bodies.Bodies = .{
        .exprs = exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = types_store,
        .bodies = &.{},
    };

    const stats = resolveMethods(&g, &b);

    try std.testing.expectEqual(@as(usize, 1), stats.inherent_resolved);
    try std.testing.expectEqual(@as(usize, 1), stats.std_resolved);
    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_methods);
    try std.testing.expectEqual(update_fn_id, b.exprs[1].kind.method_call.method);
}
