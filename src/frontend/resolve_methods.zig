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
    slice_iter_mut,

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
            if (std.mem.eql(u8, method_name, "iter_mut")) return .slice_iter_mut;
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
        .external_nominal => |external| {
            if (external.path.len > 0) return external.path[external.path.len - 1];
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

const local_initializer_depth_max: usize = 128;

const LocalInitializerFinder = struct {
    b: *const bodies.Bodies,
    target_name: []const u8,
    target_ordinal: usize,
    binding_ordinal: usize,
    result: ?exprs.NodeId = null,
    depth_exceeded: bool = false,

    fn visitPattern(
        self: *LocalInitializerFinder,
        pattern_id: exprs.NodeId,
        init: ?exprs.NodeId,
        depth: usize,
    ) void {
        if (self.result != null or self.depth_exceeded or pattern_id >= self.b.pats.len) return;
        if (depth >= local_initializer_depth_max) {
            self.depth_exceeded = true;
            return;
        }

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
            .tuple => |tuple| for (tuple.elements) |element| {
                self.visitPattern(element, init, depth + 1);
            },
            .slice => |slice| {
                for (slice.elements) |element| self.visitPattern(element, init, depth + 1);
                if (slice.rest) |rest| self.visitPattern(rest, init, depth + 1);
            },
            .struct_pat => |struct_pat| for (struct_pat.fields) |field| {
                if (field.pat) |field_pattern| {
                    self.visitPattern(field_pattern, init, depth + 1);
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
            .reference => |reference| self.visitPattern(reference.inner, init, depth + 1),
            .@"or" => |or_pattern| for (or_pattern.alternatives) |alternative| {
                self.visitPattern(alternative, init, depth + 1);
            },
            .unsupported => {},
            .wildcard, .literal, .path, .range => {},
        }
    }

    fn visitBlock(self: *LocalInitializerFinder, block: exprs.BlockExpr, depth: usize) void {
        if (self.result != null or self.depth_exceeded) return;
        if (depth >= local_initializer_depth_max) {
            self.depth_exceeded = true;
            return;
        }
        for (block.statements) |statement| self.visitStmt(statement, depth + 1);
        if (block.tail) |tail| self.visitExpr(tail, depth + 1);
    }

    fn visitStmt(
        self: *LocalInitializerFinder,
        statement_id: exprs.NodeId,
        depth: usize,
    ) void {
        if (self.result != null or self.depth_exceeded or statement_id >= self.b.stmts.len) return;
        if (depth >= local_initializer_depth_max) {
            self.depth_exceeded = true;
            return;
        }
        switch (self.b.stmts[statement_id].kind) {
            .let => |let_stmt| {
                if (let_stmt.init) |init| self.visitExpr(init, depth + 1);
                self.visitPattern(let_stmt.pattern, let_stmt.init, depth + 1);
            },
            .let_else => |let_else| {
                self.visitExpr(let_else.init, depth + 1);
                self.visitPattern(let_else.pattern, let_else.init, depth + 1);
                self.visitBlock(let_else.else_block, depth + 1);
            },
            .expr => |expression| self.visitExpr(expression, depth + 1),
            .item => {},
        }
    }

    fn visitElse(self: *LocalInitializerFinder, branch: exprs.ElseBranch, depth: usize) void {
        if (self.result != null or self.depth_exceeded) return;
        if (depth >= local_initializer_depth_max) {
            self.depth_exceeded = true;
            return;
        }
        switch (branch) {
            .none => {},
            .block => |block| self.visitBlock(block, depth + 1),
            .chain => |node| self.visitExpr(node, depth + 1),
        }
    }

    fn visitClosure(self: *LocalInitializerFinder, closure: exprs.ClosureExpr, depth: usize) void {
        if (self.result != null or self.depth_exceeded) return;
        if (depth >= local_initializer_depth_max) {
            self.depth_exceeded = true;
            return;
        }
        for (closure.params) |param| self.visitPattern(param, null, depth + 1);
        self.visitBlock(closure.body, depth + 1);
    }

    fn visitIteratorChain(self: *LocalInitializerFinder, chain: exprs.IteratorChainExpr, depth: usize) void {
        if (self.result != null or self.depth_exceeded) return;
        if (depth >= local_initializer_depth_max) {
            self.depth_exceeded = true;
            return;
        }
        self.visitExpr(chain.source, depth + 1);
        for (chain.adapters) |adapter| {
            switch (adapter) {
                .map => |map| self.visitClosure(map.closure, depth + 1),
                .filter => |filter| self.visitClosure(filter.closure, depth + 1),
                .flat_map => |closure| self.visitClosure(closure, depth + 1),
                .enumerate, .range_rev, .other => {},
                .zip => |zip| self.visitExpr(zip.other, depth + 1),
            }
        }
    }

    fn visitIterKind(self: *LocalInitializerFinder, iter_kind: exprs.IterKind, depth: usize) void {
        switch (iter_kind) {
            .range, .slice, .enumerate => {},
            .multi => |ids| for (ids) |id| self.visitExpr(id, depth + 1),
            .adapter => |chain| self.visitIteratorChain(chain, depth + 1),
        }
    }

    fn visitExpr(self: *LocalInitializerFinder, node: exprs.NodeId, depth: usize) void {
        if (self.result != null or self.depth_exceeded or node >= self.b.exprs.len) return;
        if (depth >= local_initializer_depth_max) {
            self.depth_exceeded = true;
            return;
        }
        switch (self.b.exprs[node].kind) {
            .block => |block| self.visitBlock(block, depth + 1),
            .if_else => |if_expr| {
                self.visitExpr(if_expr.cond, depth + 1);
                self.visitBlock(if_expr.then_, depth + 1);
                self.visitElse(if_expr.@"else", depth + 1);
            },
            .if_let => |if_let| {
                self.visitExpr(if_let.scrutinee, depth + 1);
                self.visitPattern(if_let.pattern, null, depth + 1);
                self.visitBlock(if_let.then_, depth + 1);
                self.visitElse(if_let.@"else", depth + 1);
            },
            .match => |match_expr| {
                self.visitExpr(match_expr.scrutinee, depth + 1);
                for (match_expr.arms) |arm| {
                    for (arm.patterns) |pattern| self.visitPattern(pattern, null, depth + 1);
                    if (arm.guard) |guard| self.visitExpr(guard, depth + 1);
                    self.visitExpr(arm.body, depth + 1);
                }
            },
            .loop_ => |loop_expr| self.visitBlock(loop_expr.body, depth + 1),
            .while_ => |while_expr| {
                self.visitExpr(while_expr.cond, depth + 1);
                if (while_expr.capture) |capture| self.visitPattern(capture, null, depth + 1);
                self.visitBlock(while_expr.body, depth + 1);
            },
            .for_ => |for_expr| {
                self.visitPattern(for_expr.pattern, null, depth + 1);
                self.visitExpr(for_expr.iterable, depth + 1);
                self.visitBlock(for_expr.body, depth + 1);
                self.visitIterKind(for_expr.iter_kind, depth + 1);
            },
            .break_ => |break_expr| if (break_expr.value) |value| self.visitExpr(value, depth + 1),
            .call => |call| for (call.args) |arg| self.visitExpr(arg, depth + 1),
            .method_call => |method| {
                self.visitExpr(method.receiver, depth + 1);
                for (method.args) |arg| self.visitExpr(arg, depth + 1);
            },
            .struct_lit => |literal| {
                for (literal.fields) |field| self.visitExpr(field.value, depth + 1);
                if (literal.base) |base| self.visitExpr(base, depth + 1);
            },
            .enum_variant => |variant| {
                for (variant.tuple_fields) |field| self.visitExpr(field, depth + 1);
                for (variant.named_fields) |field| self.visitExpr(field.value, depth + 1);
            },
            .field => |field| self.visitExpr(field.base, depth + 1),
            .index => |index| {
                self.visitExpr(index.base, depth + 1);
                self.visitExpr(index.index, depth + 1);
            },
            .cast => |cast| self.visitExpr(cast.operand, depth + 1),
            .binary => |binary| {
                self.visitExpr(binary.lhs, depth + 1);
                self.visitExpr(binary.rhs, depth + 1);
            },
            .unary => |unary| self.visitExpr(unary.operand, depth + 1),
            .assign => |assign| {
                self.visitExpr(assign.target, depth + 1);
                self.visitExpr(assign.value, depth + 1);
            },
            .try_ => |try_expr| self.visitExpr(try_expr.inner, depth + 1),
            .return_ => |return_expr| if (return_expr.value) |value| self.visitExpr(value, depth + 1),
            .array => |array| for (array.elements) |element| self.visitExpr(element, depth + 1),
            .vec_lit => |vec| for (vec.elements) |element| self.visitExpr(element, depth + 1),
            .range => |range| {
                self.visitExpr(range.start, depth + 1);
                self.visitExpr(range.end, depth + 1);
            },
            .closure => |closure| self.visitClosure(closure, depth + 1),
            .iterator_chain => |chain| self.visitIteratorChain(chain, depth + 1),
            .literal, .unit, .path, .continue_, .unsupported => {},
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
    finder.visitExpr(fn_body.body, 0);
    if (finder.depth_exceeded) return null;
    return finder.result;
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
    if (entity.kind == .field) {
        if (matchedVariantFieldType(g, b, entity.name, localBindingOrdinal(g, entity))) |ty| {
            return ty;
        }
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

fn matchedVariantFieldType(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    binding_name: []const u8,
    binding_ordinal: usize,
) ?types.Type {
    var seen: usize = 0;
    for (b.pats, 0..) |pattern, pattern_id| {
        const binding = switch (pattern.kind) {
            .binding => |value| value,
            else => continue,
        };
        if (!std.mem.eql(u8, binding.name, binding_name)) continue;
        if (seen != binding_ordinal) {
            seen += 1;
            continue;
        }
        for (b.pats) |container| {
            const struct_pat = switch (container.kind) {
                .struct_pat => |value| value,
                else => continue,
            };
            const nominal = g.symbol_table.get(struct_pat.def) orelse continue;
            if (nominal.kind != .enum_) continue;
            if (struct_pat.def >= b.bodies.len) continue;
            const enum_body = switch (b.bodies[struct_pat.def]) {
                .enum_ => |value| value,
                else => continue,
            };

            var matched_fields: ?items.VariantFields = null;
            for (enum_body.variants) |candidate| {
                const matches = switch (candidate.fields) {
                    .tuple => |fields| blk: {
                        if (fields.len != struct_pat.fields.len) break :blk false;
                        for (struct_pat.fields, 0..) |field, index| {
                            const parsed = std.fmt.parseInt(usize, field.field, 10) catch break :blk false;
                            if (parsed != index) break :blk false;
                        }
                        break :blk true;
                    },
                    .named => |fields| blk: {
                        if (fields.len != struct_pat.fields.len) break :blk false;
                        for (struct_pat.fields) |field| {
                            var found = false;
                            for (fields) |candidate_field| {
                                if (std.mem.eql(u8, candidate_field.name, field.field)) {
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) break :blk false;
                        }
                        break :blk true;
                    },
                    .none => struct_pat.fields.len == 0,
                };
                if (!matches) continue;
                if (matched_fields != null) return null;
                matched_fields = candidate.fields;
            }
            const variant_fields = matched_fields orelse continue;
            for (struct_pat.fields) |field| {
                if (field.pat == null or field.pat.? != pattern_id) continue;
                return switch (variant_fields) {
                    .tuple => |fields| blk: {
                        const index = std.fmt.parseInt(usize, field.field, 10) catch break :blk null;
                        if (index >= fields.len) break :blk null;
                        break :blk fields[index];
                    },
                    .named => |fields| blk: {
                        for (fields) |candidate| {
                            if (std.mem.eql(u8, candidate.name, field.field)) break :blk candidate.ty;
                        }
                        break :blk null;
                    },
                    .none => null,
                };
            }
        }
    }
    return null;
}

fn localBindingOrdinal(
    g: *const graph.CrateGraph,
    local: spine.Entity,
) usize {
    const parent = local.parent orelse return 0;
    var ordinal: usize = 0;
    for (g.symbol_table.entities.items) |candidate| {
        if (candidate.id == local.id) break;
        if (candidate.kind != .field or candidate.parent != parent) continue;
        if (std.mem.eql(u8, candidate.name, local.name)) ordinal += 1;
    }
    return ordinal;
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
        .binary => |binary| operandTypeResolved(g, b, binary.lhs) and operandTypeResolved(g, b, binary.rhs),
        .cast => |cast| operandTypeResolved(g, b, cast.operand),
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
        .binary => |binary| operandIsPrimitive(g, b, binary.lhs) and operandIsPrimitive(g, b, binary.rhs),
        .cast => true,
        else => false,
    };
}

fn replaceWithUnsupported(e: *exprs.Expr, reason: []const u8) void {
    e.kind = .{ .unsupported = .{
        .reason = reason,
        .suggested_version = .v1,
    } };
}

fn isRetainedIteratorProjection(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    receiver_node: exprs.NodeId,
) bool {
    var projection_node = receiver_node;
    var depth: usize = 0;
    while (depth < b.exprs.len) : (depth += 1) {
        if (projection_node >= b.exprs.len) return false;
        const method_call = switch (b.exprs[projection_node].kind) {
            .method_call => |value| value,
            else => return false,
        };
        const method = g.symbol_table.get(method_call.method) orelse return false;
        if (std.mem.eql(u8, method.name, "iter") or
            std.mem.eql(u8, method.name, "iter_mut"))
        {
            if (method_call.receiver >= b.exprs.len) return false;
            const receiver = b.exprs[method_call.receiver];
            const receiver_ty = if (receiver.ty) |type_id|
                if (type_id < b.types.len) b.types[type_id] else null
            else if (receiver.kind == .path)
                pathDeclaredType(g, b, receiver.kind.path)
            else
                null;
            const std_method = lookupStdMethod(receiver_ty orelse return false, method.name) orelse return false;
            return std_method == .slice_iter or std_method == .slice_iter_mut;
        }
        if (!std.mem.eql(u8, method.name, "cloned")) return false;
        projection_node = method_call.receiver;
    }
    return false;
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

            const iterator_projection = isRetainedIteratorProjection(g, b, receiver_node);
            if (iterator_projection) {
                if (std.mem.eql(u8, method_name, "cloned")) {
                    stats.std_resolved += 1;
                } else {
                    replaceWithUnsupported(e, reason_method_dispatch_unavailable);
                    stats.unsupported_methods += 1;
                }
                continue;
            }

            const receiver_name = receiverNominalName(g, b, receiver_node);
            var resolved = false;
            if (receiver_name) |name| {
                // Inherent methods have precedence over trait methods.
                if (lookupInherentMethod(g, name, method_name)) |fn_id| {
                    mc.method = fn_id;
                    stats.inherent_resolved += 1;
                    resolved = true;
                }

                if (!resolved) {
                    const trait_lookup =
                        lookupTraitMethodCandidates(g, name, method_name, null);
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
                const reason = if (receiver_name == null and receiver_ty == null)
                    reason_receiver_unavailable
                else
                    reason_method_dispatch_unavailable;
                replaceWithUnsupported(e, reason);
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

const method_resolution_test_span: spine.Span = .{
    .start_line = 1,
    .start_col = 1,
    .end_line = 1,
    .end_col = 1,
};

fn addMethodForTest(
    allocator: std.mem.Allocator,
    g: *graph.CrateGraph,
    name: []const u8,
) !spine.EntityId {
    return g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, name),
        .span = method_resolution_test_span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
}

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
    try std.testing.expectEqual(StdMethod.slice_iter_mut, lookupStdMethod(slice_ty, "iter_mut"));

    const ref_slice: types.Type = .{ .reference = &.{ .mut = false, .pointee = slice_ty } };
    try std.testing.expectEqual(StdMethod.slice_is_empty, lookupStdMethod(ref_slice, "is_empty"));

    const prim_ty: types.Type = .{ .prim = .u64 };
    try std.testing.expectEqual(StdMethod.num_wrapping_add, lookupStdMethod(prim_ty, "wrapping_add"));
    try std.testing.expectEqual(StdMethod.num_count_ones, lookupStdMethod(prim_ty, "count_ones"));

    try std.testing.expectEqual(StdMethod.clone, lookupStdMethod(prim_ty, "clone"));
    try std.testing.expectEqual(StdMethod.default, lookupStdMethod(prim_ty, "default"));
}

test "resolveMethods keeps local iterator projections dispatchable" {
    const allocator = std.testing.allocator;
    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();

    const source_impl = try g.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = try allocator.dupe(u8, "Source"),
        .span = method_resolution_test_span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const iter_method = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "iter"),
        .span = method_resolution_test_span,
        .visibility = .public,
        .parent = source_impl,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const cursor_impl = try g.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = try allocator.dupe(u8, "Cursor"),
        .span = method_resolution_test_span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const value_method = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "value"),
        .span = method_resolution_test_span,
        .visibility = .public,
        .parent = cursor_impl,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    var source_segments = [_]types.PathSegment{.{ .name = "Source", .id = null }};
    var cursor_segments = [_]types.PathSegment{.{ .name = "Cursor", .id = null }};
    var types_store = [_]types.Type{
        .{ .path = .{ .segments = &source_segments } },
        .{ .path = .{ .segments = &cursor_segments } },
    };
    var exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = method_resolution_test_span,
            .ty = 0,
            .kind = .{ .unit = {} },
        },
        .{
            .id = 1,
            .span = method_resolution_test_span,
            .ty = 1,
            .kind = .{ .method_call = .{
                .receiver = 0,
                .receiver_mode = .value,
                .method = iter_method,
                .args = &.{},
            } },
        },
        .{
            .id = 2,
            .span = method_resolution_test_span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 1,
                .receiver_mode = .value,
                .method = value_method,
                .args = &.{},
            } },
        },
    };
    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = resolveMethods(&g, &b);

    try std.testing.expectEqual(@as(usize, 2), stats.inherent_resolved);
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_methods);
    const value_call = switch (b.exprs[2].kind) {
        .method_call => |method_call| method_call,
        else => return error.ExpectedLocalValueMethodCall,
    };
    try std.testing.expectEqual(value_method, value_call.method);
}

test "resolveMethods uses typed slice standard iteration" {
    const allocator = std.testing.allocator;
    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();

    const iter_method = try addMethodForTest(allocator, &g, "iter");
    var slice_type: types.Slice = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    var types_store = [_]types.Type{.{ .slice = &slice_type }};
    var exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = method_resolution_test_span,
            .ty = 0,
            .kind = .{ .unit = {} },
        },
        .{
            .id = 1,
            .span = method_resolution_test_span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 0,
                .receiver_mode = .shared,
                .method = iter_method,
                .args = &.{},
            } },
        },
    };
    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = resolveMethods(&g, &b);

    try std.testing.expectEqual(@as(usize, 1), stats.std_resolved);
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_methods);
    const iter_call = switch (b.exprs[1].kind) {
        .method_call => |method_call| method_call,
        else => return error.ExpectedSliceIterMethodCall,
    };
    try std.testing.expectEqual(iter_method, iter_call.method);
}

test "resolveMethods preserves cloned projection on typed slice iterator" {
    const allocator = std.testing.allocator;
    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();

    const iter_method = try addMethodForTest(allocator, &g, "iter");
    const cloned_method = try addMethodForTest(allocator, &g, "cloned");
    var slice_type: types.Slice = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    var types_store = [_]types.Type{.{ .slice = &slice_type }};
    var exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = method_resolution_test_span,
            .ty = 0,
            .kind = .{ .unit = {} },
        },
        .{
            .id = 1,
            .span = method_resolution_test_span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 0,
                .receiver_mode = .shared,
                .method = iter_method,
                .args = &.{},
            } },
        },
        .{
            .id = 2,
            .span = method_resolution_test_span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 1,
                .receiver_mode = .value,
                .method = cloned_method,
                .args = &.{},
            } },
        },
    };
    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = resolveMethods(&g, &b);

    try std.testing.expectEqual(@as(usize, 2), stats.std_resolved);
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_methods);
    const cloned_call = switch (b.exprs[2].kind) {
        .method_call => |method_call| method_call,
        else => return error.ExpectedClonedMethodCall,
    };
    try std.testing.expectEqual(cloned_method, cloned_call.method);
}

test "resolveMethods rejects unknown iterator projection" {
    const allocator = std.testing.allocator;
    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();

    const iter_method = try addMethodForTest(allocator, &g, "iter");
    const unknown_method = try addMethodForTest(allocator, &g, "unknown_projection");
    var slice_type: types.Slice = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    var types_store = [_]types.Type{.{ .slice = &slice_type }};
    var exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = method_resolution_test_span,
            .ty = 0,
            .kind = .{ .unit = {} },
        },
        .{
            .id = 1,
            .span = method_resolution_test_span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 0,
                .receiver_mode = .shared,
                .method = iter_method,
                .args = &.{},
            } },
        },
        .{
            .id = 2,
            .span = method_resolution_test_span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 1,
                .receiver_mode = .value,
                .method = unknown_method,
                .args = &.{},
            } },
        },
    };
    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = resolveMethods(&g, &b);

    try std.testing.expectEqual(@as(usize, 1), stats.std_resolved);
    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_methods);
    const unsupported = switch (b.exprs[2].kind) {
        .unsupported => |value| value,
        else => return error.ExpectedUnsupportedIteratorProjection,
    };
    try std.testing.expectEqualStrings(reason_method_dispatch_unavailable, unsupported.reason);
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

fn nestedTuplePatternsForTest(
    alloc: std.mem.Allocator,
    nesting: usize,
) ![]exprs.Pattern {
    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 1,
    };
    const patterns = try alloc.alloc(exprs.Pattern, nesting + 1);
    for (0..nesting) |index| {
        const elements = try alloc.alloc(exprs.NodeId, 1);
        elements[0] = @intCast(index + 1);
        patterns[index] = .{
            .id = @intCast(index),
            .span = span,
            .ty = null,
            .kind = .{ .tuple = .{ .elements = elements, .rest = false } },
        };
    }
    patterns[nesting] = .{
        .id = @intCast(nesting),
        .span = span,
        .ty = null,
        .kind = .{ .binding = .{
            .name = "target",
            .mode = .{ .value = {} },
            .mutable = false,
        } },
    };
    return patterns;
}

fn nestedIfExpressionsForTest(
    alloc: std.mem.Allocator,
    nesting: usize,
) ![]exprs.Expr {
    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 1,
    };
    const empty_block: exprs.BlockExpr = .{
        .statements = &.{},
        .tail = null,
        .labelled = null,
    };
    const expressions = try alloc.alloc(exprs.Expr, nesting + 1);
    for (0..nesting) |index| {
        expressions[index] = .{
            .id = @intCast(index),
            .span = span,
            .ty = null,
            .kind = .{ .if_else = .{
                .cond = @intCast(index + 1),
                .then_ = empty_block,
                .@"else" = .{ .none = {} },
            } },
        };
    }
    expressions[nesting] = .{
        .id = @intCast(nesting),
        .span = span,
        .ty = null,
        .kind = .{ .literal = .{ .boolean = false } },
    };
    return expressions;
}

test "LocalInitializerFinder bounds nested patterns and expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const accepted_nesting = local_initializer_depth_max - 1;
    const accepted_patterns = try nestedTuplePatternsForTest(alloc, accepted_nesting);
    const accepted_pattern_b: bodies.Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = accepted_patterns,
        .types = &.{},
        .bodies = &.{},
    };
    var accepted_pattern_finder: LocalInitializerFinder = .{
        .b = &accepted_pattern_b,
        .target_name = "target",
        .target_ordinal = 0,
        .binding_ordinal = 0,
    };
    accepted_pattern_finder.visitPattern(0, 7, 0);
    try std.testing.expect(!accepted_pattern_finder.depth_exceeded);
    try std.testing.expectEqual(@as(?exprs.NodeId, 7), accepted_pattern_finder.result);

    const rejected_patterns = try nestedTuplePatternsForTest(alloc, local_initializer_depth_max);
    const rejected_pattern_b: bodies.Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = rejected_patterns,
        .types = &.{},
        .bodies = &.{},
    };
    var rejected_pattern_finder: LocalInitializerFinder = .{
        .b = &rejected_pattern_b,
        .target_name = "target",
        .target_ordinal = 0,
        .binding_ordinal = 0,
    };
    rejected_pattern_finder.visitPattern(0, 7, 0);
    try std.testing.expect(rejected_pattern_finder.depth_exceeded);
    try std.testing.expectEqual(@as(?exprs.NodeId, null), rejected_pattern_finder.result);

    const accepted_exprs = try nestedIfExpressionsForTest(alloc, accepted_nesting);
    const accepted_expr_b: bodies.Bodies = .{
        .exprs = accepted_exprs,
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{},
    };
    var accepted_expr_finder: LocalInitializerFinder = .{
        .b = &accepted_expr_b,
        .target_name = "target",
        .target_ordinal = 0,
        .binding_ordinal = 0,
    };
    accepted_expr_finder.visitExpr(0, 0);
    try std.testing.expect(!accepted_expr_finder.depth_exceeded);

    const rejected_exprs = try nestedIfExpressionsForTest(alloc, local_initializer_depth_max);
    const rejected_expr_b: bodies.Bodies = .{
        .exprs = rejected_exprs,
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{},
    };
    var rejected_expr_finder: LocalInitializerFinder = .{
        .b = &rejected_expr_b,
        .target_name = "target",
        .target_ordinal = 0,
        .binding_ordinal = 0,
    };
    rejected_expr_finder.visitExpr(0, 0);
    try std.testing.expect(rejected_expr_finder.depth_exceeded);
}
