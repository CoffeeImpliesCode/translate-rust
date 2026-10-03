//! translate_rust.frontend.pipeline — full frontend orchestration pipeline.
//!
//! Orchestrates:
//! Ingestion -> CST extraction -> Name resolution -> Declaration type binding ->
//! Function body extraction -> Built-in Macro Expansion -> Type Inference ->
//! Method & Trait Resolution -> Generic Monomorphization -> returns completed
//! `ir.RustIr`.
//!
//! Zero backend dependencies: does NOT depend on emit.zig, package.zig, or driver.zig.

const std = @import("std");
const ir = @import("translate_rust.ir");
const spine = ir.spine;
const graph = ir.graph;
const types = ir.types;
const exprs = ir.exprs;
const bodies = ir.bodies;

pub const ingest = @import("ingest.zig");
pub const cst = @import("cst.zig");
pub const ts_ext = @import("ts_ext.zig");
pub const expand = @import("expand.zig");
pub const names = @import("names.zig");
pub const infer = @import("infer.zig");
pub const resolve_methods = @import("resolve_methods.zig");
pub const monomorphize = @import("monomorphize.zig");

pub const AnalysisOptions = struct {
    include_tests: bool = false,
    cfg: cst.CfgOptions = .{},
};
const default_span: spine.Span = .{
    .start_line = 1,
    .start_col = 1,
    .end_line = 1,
    .end_col = 1,
};

fn materializeInferredConstructorTypes(
    allocator: std.mem.Allocator,
    type_list: *std.ArrayListUnmanaged(types.Type),
    expr_list: []exprs.Expr,
    inferred: infer.InstantiationMap,
) !void {
    var it = inferred.iterator();
    while (it.next()) |entry| {
        const node = entry.key_ptr.*;
        if (node >= expr_list.len) continue;
        const decl = switch (expr_list[node].kind) {
            .call => |call| switch (call.call_kind) {
                .constructor => |constructor| constructor,
                .free, .associated => continue,
            },
            .struct_lit => |literal| literal.def,
            else => continue,
        };
        if (decl != entry.value_ptr.generic_id) continue;
        var found = false;
        for (type_list.items, 0..) |existing, existing_id| {
            switch (existing) {
                .generic_inst => |generic| {
                    if (generic.decl == decl and
                        monomorphize.genericArgsEquals(generic.args, entry.value_ptr.args))
                    {
                        expr_list[node].ty = @intCast(existing_id);
                        found = true;
                        break;
                    }
                },
                else => {},
            }
        }
        if (!found) {
            const owned_args = try allocator.dupe(types.Type, entry.value_ptr.args.params);
            errdefer if (owned_args.len > 0) allocator.free(owned_args);
            const type_id: exprs.TypeId = @intCast(type_list.items.len);
            try type_list.append(allocator, .{ .generic_inst = .{
                .decl = decl,
                .args = .{ .params = owned_args },
            } });
            expr_list[node].ty = type_id;
        }
    }
}

fn materializeOpaqueFunctionReturns(
    allocator: std.mem.Allocator,
    type_list: *std.ArrayListUnmanaged(types.Type),
    expr_list: []const exprs.Expr,
    body_list: []bodies.BodyKind,
) !void {
    for (body_list) |*body| {
        const fn_body = switch (body.*) {
            .fn_ => |*function| function,
            else => continue,
        };
        const declared = switch (fn_body.ret) {
            .@"opaque" => |*opaque_type| opaque_type,
            else => continue,
        };
        if (declared.concrete != null or fn_body.body >= expr_list.len) continue;
        const block = switch (expr_list[fn_body.body].kind) {
            .block => |value| value,
            else => continue,
        };
        const tail = block.tail orelse continue;
        if (tail >= expr_list.len) continue;
        const type_id = expr_list[tail].ty orelse continue;
        if (type_id >= type_list.items.len) continue;
        const actual = type_list.items[type_id];
        if (!infer.isConcreteType(actual)) continue;

        const concrete = try allocator.create(types.Type);
        concrete.* = actual;
        declared.concrete = concrete;
        for (type_list.items) |*entry| {
            switch (entry.*) {
                .@"opaque" => |*entry_opaque| {
                    if (entry_opaque.bounds.ptr == declared.bounds.ptr and
                        entry_opaque.bounds.len == declared.bounds.len)
                    {
                        entry_opaque.concrete = concrete;
                    }
                },
                else => {},
            }
        }
    }
}

/// Orchestrates the entire frontend analysis on a crate directory:
/// 1. Ingestion (`Cargo.toml` name/edition/entry point resolution).
/// 2. CST extraction (`cst.extractFile` across root + submodules).
/// 3. Name resolution and declaration type-path binding (`cst.extractFile`).
/// 4. Body lowering (`ts_ext.extractFunction` across fn entities).
/// 5. Macro expansion (`expand`).
/// 6. Type inference (`infer.solve` + constraint propagation).
/// 7. Method & trait resolution (`resolve_methods.resolveMethods`).
/// 8. Monomorphization (`monomorphize.collectInstantiations`).
/// Returns the completed `ir.RustIr`.
/// Use a caller-owned arena for all analysis allocations. Keep it alive while
/// using the returned IR, and release it after the last use.
pub fn analyzeCrate(
    allocator: std.mem.Allocator,
    io: std.Io,
    crate_dir: []const u8,
) !ir.RustIr {
    return analyzeCrateWithOptions(allocator, io, crate_dir, .{ .cfg = .{} });
}

/// Analyze a crate directory with explicit frontend options. An empty
/// `cfg.features` means "no selection was made", so the manifest's `default`
/// feature closure applies; a non-empty list is the caller's explicit
/// selection and replaces the manifest default.
/// Uses the caller-owned arena lifetime described by `analyzeCrate`.
pub fn analyzeCrateWithOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    crate_dir: []const u8,
    options: AnalysisOptions,
) !ir.RustIr {
    // 1. Ingestion
    const manifest = try ingest.loadCrateManifest(allocator, io, crate_dir);
    const src = try ingest.readFileAlloc(allocator, io, manifest.root_path);

    var resolved = options;
    // A caller's list replaces the manifest default and arrives exactly as
    // written, so it may name a feature whose own members are what enable a
    // dependency; nothing may be concluded from what it leaves out.
    const caller_selected = resolved.cfg.features.len != 0;
    if (!caller_selected) {
        resolved.cfg.features = try ingest.defaultFeatureClosure(allocator, manifest.features);
    }
    const dependency_closure: DependencyClosure = .{
        .features = manifest.features,
        .active = resolved.cfg.features,
        // `ingest.defaultFeatureClosure` returns a transitively expanded
        // closure, so an implicit feature missing from it is definitely off.
        .complete = !caller_selected,
    };
    return analyzeSourceWithGraph(allocator, io, crate_dir, manifest, src, resolved, dependency_closure);
}

/// Analyze a crate when source is already loaded in memory.
/// Use a caller-owned arena for all analysis allocations. Keep it alive while
/// using the returned IR, and release it after the last use.
pub fn analyzeSource(
    allocator: std.mem.Allocator,
    crate_name: []const u8,
    edition: []const u8,
    source: []const u8,
) !ir.RustIr {
    return analyzeSourceWithOptions(allocator, crate_name, edition, source, .{ .cfg = .{} });
}

/// Analyze source with explicit frontend options.
/// Uses the caller-owned arena lifetime described by `analyzeSource`.
pub fn analyzeSourceWithOptions(
    allocator: std.mem.Allocator,
    crate_name: []const u8,
    edition: []const u8,
    source: []const u8,
    options: AnalysisOptions,
) !ir.RustIr {
    const manifest: ingest.Manifest = .{
        .name = crate_name,
        .edition = edition,
        .version = null,
        .root_path = "src/lib.rs",
        .is_bin = false,
    };
    // Source loaded from memory has no manifest and so no feature table: there
    // is nothing a selection could fail to expand, and nothing that could
    // enable an optional dependency behind a feature.
    const dependency_closure: DependencyClosure = .{
        .active = options.cfg.features,
        .complete = true,
    };
    return analyzeSourceWithGraph(allocator, null, ".", manifest, source, options, dependency_closure);
}

fn manifestEdition(edition: []const u8) !u16 {
    const value = std.fmt.parseUnsigned(u16, edition, 10) catch return error.InvalidEdition;
    return switch (value) {
        2015, 2018, 2021, 2024 => value,
        else => error.InvalidEdition,
    };
}

const ModuleSources = std.AutoHashMapUnmanaged(spine.EntityId, []const u8);

fn moduleForEntity(g: *const graph.CrateGraph, module_id: spine.EntityId) ?graph.Module {
    const ent = g.symbol_table.get(module_id) orelse return null;
    if (ent.kind != .module) return null;
    for (g.modules.items) |module| {
        if (module.parent == ent.parent and std.mem.eql(u8, module.name, ent.name)) {
            return module;
        }
    }
    return null;
}

fn sourceForFunction(
    g: *const graph.CrateGraph,
    module_sources: *const ModuleSources,
    fn_id: spine.EntityId,
) ![]const u8 {
    const ent = g.symbol_table.get(fn_id) orelse return error.FunctionBodyMissing;
    var module_id = ent.parent orelse return error.FunctionModuleSourceMissing;
    var depth: usize = 0;
    while (depth < g.symbol_table.entities.items.len) : (depth += 1) {
        const owner = g.symbol_table.get(module_id) orelse return error.FunctionModuleSourceMissing;
        if (owner.kind != .module) {
            module_id = owner.parent orelse return error.FunctionModuleSourceMissing;
            continue;
        }
        const module = moduleForEntity(g, module_id) orelse return error.FunctionModuleSourceMissing;
        if (module_sources.get(module.id)) |source| return source;
        switch (module.kind) {
            .root => return error.FunctionModuleSourceMissing,
            .file, .directory => return error.FunctionModuleSourceMissing,
            .@"inline" => module_id = module.parent orelse return error.FunctionModuleSourceMissing,
        }
    }
    return error.FunctionModuleSourceMissing;
}

fn assertionConditionForNode(
    reason: []const u8,
    node: exprs.NodeId,
    expr_count: usize,
) ?exprs.NodeId {
    const prefix = "assertion:";
    if (!std.mem.startsWith(u8, reason, prefix)) return null;

    const suffix = reason[prefix.len..];
    if (suffix.len == 0) return null;
    for (suffix) |character| {
        if (character < '0' or character > '9') return null;
    }

    const condition = std.fmt.parseInt(exprs.NodeId, suffix, 10) catch return null;
    if (condition >= expr_count or condition == node) return null;
    return condition;
}

const CollectionEffectScanner = struct {
    exprs: []const exprs.Expr,
    stmts: []const exprs.Statement,

    fn exprAllocates(self: *const CollectionEffectScanner, node_id: exprs.NodeId) bool {
        if (@as(usize, node_id) >= self.exprs.len) return false;
        return switch (self.exprs[node_id].kind) {
            .literal, .path, .unit, .continue_, .panic_ => false,
            .array => |array| self.nodeListAllocates(array.elements),
            .vec_lit => |vec| self.nodeListAllocates(vec.elements) or
                self.repeatCountAllocates(vec.repeat),
            .range => |range| self.exprAllocates(range.start) or
                (if (range.end) |end| self.exprAllocates(end) else false),
            .block => |block| self.blockAllocates(block),
            .if_else => |if_expr| self.ifElseAllocates(if_expr),
            .if_let => |if_let| self.ifLetAllocates(if_let),
            .match => |match_expr| self.matchAllocates(match_expr),
            .loop_ => |loop_expr| self.blockAllocates(loop_expr.body),
            .while_ => |while_expr| self.exprAllocates(while_expr.cond) or self.blockAllocates(while_expr.body),
            .for_ => |for_expr| self.exprAllocates(for_expr.iterable) or
                self.blockAllocates(for_expr.body) or
                self.iterKindAllocates(for_expr.iter_kind),
            .break_ => |break_expr| if (break_expr.value) |value| self.exprAllocates(value) else false,
            .call => |call| self.nodeListAllocates(call.args),
            .method_call => |method_call| self.exprAllocates(method_call.receiver) or
                self.nodeListAllocates(method_call.args),
            .struct_lit => |literal| self.structLiteralAllocates(literal),
            .enum_variant => |variant| self.enumVariantAllocates(variant),
            .field => |field| self.exprAllocates(field.base),
            .index => |index| self.exprAllocates(index.base) or self.exprAllocates(index.index),
            .cast => |cast| self.exprAllocates(cast.operand),
            .format_write => |format| self.exprAllocates(format.writer) or
                self.nodeListAllocates(format.args),
            .core_call => |call| self.nodeListAllocates(call.args),
            .core_function => false,
            .external_variant => |variant| blk: {
                if (self.nodeListAllocates(variant.tuple_fields)) break :blk true;
                for (variant.named_fields) |field| {
                    if (self.exprAllocates(field.value)) break :blk true;
                }
                break :blk false;
            },
            .binary => |binary| self.exprAllocates(binary.lhs) or self.exprAllocates(binary.rhs),
            .unary => |unary| self.exprAllocates(unary.operand),
            .assign => |assign| self.exprAllocates(assign.target) or self.exprAllocates(assign.value),
            .try_ => |try_expr| self.exprAllocates(try_expr.inner),
            .return_ => |return_expr| if (return_expr.value) |value| self.exprAllocates(value) else false,
            .closure => |closure| self.blockAllocates(closure.body),
            .iterator_chain => |chain| self.iteratorChainAllocates(chain),
            .unsupported => |unsupported| if (assertionConditionForNode(
                unsupported.reason,
                node_id,
                self.exprs.len,
            )) |condition| self.exprAllocates(condition) else false,
        };
    }

    fn nodeListAllocates(self: *const CollectionEffectScanner, node_ids: []const exprs.NodeId) bool {
        for (node_ids) |node_id| {
            if (self.exprAllocates(node_id)) return true;
        }
        return false;
    }

    /// The count of a `vec![e; n]` is an ordinary expression, evaluated after
    /// the element and free to allocate in its own right, so it is scanned
    /// like any other child. A literal count is a number the translator
    /// already holds, and a missing count is the element-list form.
    fn repeatCountAllocates(self: *const CollectionEffectScanner, repeat: ?exprs.VecRepeatCount) bool {
        const count = repeat orelse return false;
        return switch (count) {
            .literal => false,
            .expression => |node| self.exprAllocates(node),
        };
    }

    fn blockAllocates(self: *const CollectionEffectScanner, block: exprs.BlockExpr) bool {
        for (block.statements) |statement_id| {
            if (@as(usize, statement_id) >= self.stmts.len) continue;
            if (self.statementAllocates(self.stmts[statement_id])) return true;
        }
        if (block.tail) |tail| return self.exprAllocates(tail);
        return false;
    }

    fn statementAllocates(self: *const CollectionEffectScanner, statement: exprs.Statement) bool {
        return switch (statement.kind) {
            .let => |let_statement| if (let_statement.init) |init| self.exprAllocates(init) else false,
            .let_else => |let_else| self.exprAllocates(let_else.init) or self.blockAllocates(let_else.else_block),
            .expr => |expression| self.exprAllocates(expression),
            .item => false,
        };
    }

    fn ifElseAllocates(self: *const CollectionEffectScanner, if_expr: exprs.IfExpr) bool {
        if (self.exprAllocates(if_expr.cond)) return true;
        if (self.blockAllocates(if_expr.then_)) return true;
        return self.elseAllocates(if_expr.@"else");
    }

    fn ifLetAllocates(self: *const CollectionEffectScanner, if_let: exprs.IfLetExpr) bool {
        if (self.exprAllocates(if_let.scrutinee)) return true;
        if (self.blockAllocates(if_let.then_)) return true;
        return self.elseAllocates(if_let.@"else");
    }

    fn elseAllocates(self: *const CollectionEffectScanner, branch: exprs.ElseBranch) bool {
        return switch (branch) {
            .none => false,
            .block => |block| self.blockAllocates(block),
            .chain => |chain| self.exprAllocates(chain),
        };
    }

    fn matchAllocates(self: *const CollectionEffectScanner, match_expr: exprs.MatchExpr) bool {
        if (self.exprAllocates(match_expr.scrutinee)) return true;
        for (match_expr.arms) |arm| {
            if (arm.guard) |guard| {
                if (self.exprAllocates(guard)) return true;
            }
            if (self.exprAllocates(arm.body)) return true;
        }
        return false;
    }

    fn structLiteralAllocates(self: *const CollectionEffectScanner, literal: exprs.StructLit) bool {
        for (literal.fields) |field| {
            if (self.exprAllocates(field.value)) return true;
        }
        if (literal.base) |base| return self.exprAllocates(base);
        return false;
    }

    fn enumVariantAllocates(self: *const CollectionEffectScanner, variant: exprs.EnumVariant) bool {
        if (self.nodeListAllocates(variant.tuple_fields)) return true;
        for (variant.named_fields) |field| {
            if (self.exprAllocates(field.value)) return true;
        }
        return false;
    }

    fn iterKindAllocates(self: *const CollectionEffectScanner, iter_kind: exprs.IterKind) bool {
        return switch (iter_kind) {
            .range, .slice, .enumerate => false,
            .multi => |nodes| self.nodeListAllocates(nodes),
            .adapter => |chain| self.iteratorChainAllocates(chain),
        };
    }

    fn iteratorChainAllocates(
        self: *const CollectionEffectScanner,
        chain: exprs.IteratorChainExpr,
    ) bool {
        if (chain.terminal == .collect_vec) return true;
        if (self.exprAllocates(chain.source)) return true;
        for (chain.adapters) |adapter| {
            if (self.adapterAllocates(adapter)) return true;
        }
        return false;
    }

    fn adapterAllocates(self: *const CollectionEffectScanner, adapter: exprs.IteratorAdapter) bool {
        return switch (adapter) {
            .map => |map| self.blockAllocates(map.closure.body),
            .filter => |filter| self.blockAllocates(filter.closure.body),
            .flat_map => |closure| self.blockAllocates(closure.body),
            .enumerate, .range_rev, .other => false,
            .zip => |zip| self.exprAllocates(zip.other),
        };
    }
};

fn markDirectCollectionEffects(
    bodies_list: *std.ArrayListUnmanaged(bodies.BodyKind),
    expr_table: []const exprs.Expr,
    stmt_table: []const exprs.Statement,
) void {
    const scanner: CollectionEffectScanner = .{
        .exprs = expr_table,
        .stmts = stmt_table,
    };
    for (bodies_list.items) |*body| {
        switch (body.*) {
            .fn_ => |*function| {
                if (scanner.exprAllocates(function.body)) function.is_allocating = true;
            },
            .struct_ => |*structure| {
                for (@constCast(structure.methods)) |*method| {
                    if (scanner.exprAllocates(method.body)) method.is_allocating = true;
                }
            },
            else => {},
        }
    }
}
const ResolvedCallEffectScanner = struct {
    exprs: []const exprs.Expr,
    stmts: []const exprs.Statement,
    bodies: []const bodies.BodyKind,
    /// The graph and the typed body view, needed only for the one std method
    /// this scanner asks about by its declared trait bound rather than by a
    /// callee in `bodies`: a std trait method has no entity in this table, so
    /// `bodyAllocates` cannot see it.
    g: *const graph.CrateGraph,
    view: *const bodies.Bodies,

    fn exprCallsAllocating(self: *const ResolvedCallEffectScanner, node_id: exprs.NodeId) bool {
        if (@as(usize, node_id) >= self.exprs.len) return false;
        return switch (self.exprs[node_id].kind) {
            .literal, .path, .unit, .continue_, .panic_ => false,
            .array => |array| self.nodeListCallsAllocating(array.elements),
            .vec_lit => |vec| self.nodeListCallsAllocating(vec.elements) or
                self.repeatCountCallsAllocating(vec.repeat),
            .range => |range| self.exprCallsAllocating(range.start) or
                (if (range.end) |end| self.exprCallsAllocating(end) else false),
            .block => |block| self.blockCallsAllocating(block),
            .if_else => |if_expr| self.exprCallsAllocating(if_expr.cond) or
                self.blockCallsAllocating(if_expr.then_) or
                self.elseCallsAllocating(if_expr.@"else"),
            .if_let => |if_let| self.exprCallsAllocating(if_let.scrutinee) or
                self.blockCallsAllocating(if_let.then_) or
                self.elseCallsAllocating(if_let.@"else"),
            .match => |match_expr| self.matchCallsAllocating(match_expr),
            .loop_ => |loop_expr| self.blockCallsAllocating(loop_expr.body),
            .while_ => |while_expr| self.exprCallsAllocating(while_expr.cond) or
                self.blockCallsAllocating(while_expr.body),
            .for_ => |for_expr| self.exprCallsAllocating(for_expr.iterable) or
                self.blockCallsAllocating(for_expr.body) or
                self.iterKindCallsAllocating(for_expr.iter_kind),
            .break_ => |break_expr| if (break_expr.value) |value| self.exprCallsAllocating(value) else false,
            .call => |call| self.callTargetAllocates(call.call_kind) or
                self.nodeListCallsAllocating(call.args),
            // `methodTargetAllocates` reads the callee's OWN body, which is how
            // a call into this crate propagates. Two std-shaped calls have no
            // callee body here at all — the traits are outside the crate — so
            // their effect comes from the call's resolved identity instead: a
            // `std::io::Write::write_all`, which grows a buffer under an
            // explicit `gpa`, and a `Result` method that releases a heap-owning
            // payload through `alloc.dropTemporary(gpa)`. Both are the same
            // question, "does executing this expression reach an allocator",
            // asked of the arm of the switch that has no entity to ask it of.
            .method_call => |method_call| self.methodTargetAllocates(method_call.method) or
                resolve_methods.stdIoWriteMethodAllocates(self.g, self.view, node_id) or
                resolve_methods.stdResultCleanupAllocates(self.g, self.view, node_id) or
                self.exprCallsAllocating(method_call.receiver) or
                self.nodeListCallsAllocating(method_call.args),
            .struct_lit => |literal| self.structLiteralCallsAllocating(literal),
            .enum_variant => |variant| self.enumVariantCallsAllocating(variant),
            .field => |field| self.exprCallsAllocating(field.base),
            .format_write => |format| self.exprCallsAllocating(format.writer) or
                self.nodeListCallsAllocating(format.args),
            // `Vec::from(sequence)` allocates the vector it copies into, and the
            // runtime lowers it as `r2z.alloc.vec_from_slice(T, gpa, sequence)`,
            // so it needs the `gpa` this flag is what causes the enclosing
            // callable to source. It arrives as a CORE call rather than a method
            // call, so it belongs on this arm and not on the one above.
            .core_call => |call| self.nodeListCallsAllocating(call.args) or
                resolve_methods.stdVecConversionAllocates(self.g, self.view, node_id),
            .core_function => false,
            .external_variant => |variant| blk: {
                if (self.nodeListCallsAllocating(variant.tuple_fields)) break :blk true;
                for (variant.named_fields) |field| {
                    if (self.exprCallsAllocating(field.value)) break :blk true;
                }
                break :blk false;
            },
            .index => |index| self.exprCallsAllocating(index.base) or self.exprCallsAllocating(index.index),
            .cast => |cast| self.exprCallsAllocating(cast.operand),
            .binary => |binary| self.exprCallsAllocating(binary.lhs) or self.exprCallsAllocating(binary.rhs),
            .unary => |unary| self.exprCallsAllocating(unary.operand),
            .assign => |assign| self.exprCallsAllocating(assign.target) or self.exprCallsAllocating(assign.value),
            .try_ => |try_expr| self.exprCallsAllocating(try_expr.inner),
            .return_ => |return_expr| if (return_expr.value) |value| self.exprCallsAllocating(value) else false,
            .closure => |closure| self.blockCallsAllocating(closure.body),
            .iterator_chain => |chain| self.iteratorChainCallsAllocating(chain),
            .unsupported => |unsupported| if (assertionConditionForNode(
                unsupported.reason,
                node_id,
                self.exprs.len,
            )) |condition| self.exprCallsAllocating(condition) else false,
        };
    }

    fn nodeListCallsAllocating(self: *const ResolvedCallEffectScanner, node_ids: []const exprs.NodeId) bool {
        for (node_ids) |node_id| {
            if (self.exprCallsAllocating(node_id)) return true;
        }
        return false;
    }

    /// The count of a `vec![e; n]` is an ordinary expression, evaluated after
    /// the element and free to reach an allocator in its own right, so it is
    /// scanned like any other child. A literal count is a number the
    /// translator already holds, and a missing count is the element-list form.
    fn repeatCountCallsAllocating(self: *const ResolvedCallEffectScanner, repeat: ?exprs.VecRepeatCount) bool {
        const count = repeat orelse return false;
        return switch (count) {
            .literal => false,
            .expression => |node| self.exprCallsAllocating(node),
        };
    }

    fn blockCallsAllocating(self: *const ResolvedCallEffectScanner, block: exprs.BlockExpr) bool {
        for (block.statements) |statement_id| {
            if (@as(usize, statement_id) >= self.stmts.len) continue;
            if (self.statementCallsAllocating(self.stmts[statement_id])) return true;
        }
        if (block.tail) |tail| return self.exprCallsAllocating(tail);
        return false;
    }

    fn statementCallsAllocating(self: *const ResolvedCallEffectScanner, statement: exprs.Statement) bool {
        return switch (statement.kind) {
            .let => |let_statement| if (let_statement.init) |init| self.exprCallsAllocating(init) else false,
            .let_else => |let_else| self.exprCallsAllocating(let_else.init) or
                self.blockCallsAllocating(let_else.else_block),
            .expr => |expression| self.exprCallsAllocating(expression),
            .item => false,
        };
    }

    fn elseCallsAllocating(self: *const ResolvedCallEffectScanner, branch: exprs.ElseBranch) bool {
        return switch (branch) {
            .none => false,
            .block => |block| self.blockCallsAllocating(block),
            .chain => |chain| self.exprCallsAllocating(chain),
        };
    }

    fn matchCallsAllocating(self: *const ResolvedCallEffectScanner, match_expr: exprs.MatchExpr) bool {
        if (self.exprCallsAllocating(match_expr.scrutinee)) return true;
        for (match_expr.arms) |arm| {
            if (arm.guard) |guard| {
                if (self.exprCallsAllocating(guard)) return true;
            }
            if (self.exprCallsAllocating(arm.body)) return true;
        }
        return false;
    }

    fn structLiteralCallsAllocating(self: *const ResolvedCallEffectScanner, literal: exprs.StructLit) bool {
        for (literal.fields) |field| {
            if (self.exprCallsAllocating(field.value)) return true;
        }
        if (literal.base) |base| return self.exprCallsAllocating(base);
        return false;
    }

    fn enumVariantCallsAllocating(self: *const ResolvedCallEffectScanner, variant: exprs.EnumVariant) bool {
        if (self.nodeListCallsAllocating(variant.tuple_fields)) return true;
        for (variant.named_fields) |field| {
            if (self.exprCallsAllocating(field.value)) return true;
        }
        return false;
    }

    fn iterKindCallsAllocating(self: *const ResolvedCallEffectScanner, iter_kind: exprs.IterKind) bool {
        return switch (iter_kind) {
            .range, .slice, .enumerate => false,
            .multi => |nodes| self.nodeListCallsAllocating(nodes),
            .adapter => |chain| self.iteratorChainCallsAllocating(chain),
        };
    }

    fn iteratorChainCallsAllocating(
        self: *const ResolvedCallEffectScanner,
        chain: exprs.IteratorChainExpr,
    ) bool {
        if (self.exprCallsAllocating(chain.source)) return true;
        for (chain.adapters) |adapter| {
            switch (adapter) {
                .map => |map| {
                    if (self.blockCallsAllocating(map.closure.body)) return true;
                },
                .filter => |filter| {
                    if (self.blockCallsAllocating(filter.closure.body)) return true;
                },
                .flat_map => |closure| {
                    if (self.blockCallsAllocating(closure.body)) return true;
                },
                .enumerate, .range_rev, .other => {},
                .zip => |zip| {
                    if (self.exprCallsAllocating(zip.other)) return true;
                },
            }
        }
        return false;
    }

    fn callTargetAllocates(self: *const ResolvedCallEffectScanner, call_kind: exprs.CallKind) bool {
        return switch (call_kind) {
            .free => |target| self.bodyAllocates(target),
            .associated => |target| self.bodyAllocates(target),
            .constructor => false,
        };
    }

    fn methodTargetAllocates(self: *const ResolvedCallEffectScanner, target: exprs.DefId) bool {
        return self.bodyAllocates(target);
    }

    fn bodyAllocates(self: *const ResolvedCallEffectScanner, target: spine.EntityId) bool {
        if (@as(usize, target) >= self.bodies.len) return false;
        return switch (self.bodies[target]) {
            .fn_ => |function| function.is_allocating,
            else => false,
        };
    }
};

fn markStructMethodAllocating(
    bodies_list: *std.ArrayListUnmanaged(bodies.BodyKind),
    g: *const graph.CrateGraph,
    fn_id: spine.EntityId,
) bool {
    const entity = g.symbol_table.get(fn_id) orelse return false;
    if (entity.kind != .fn_) return false;
    if (fn_id >= bodies_list.items.len) return false;
    const method_body = switch (bodies_list.items[fn_id]) {
        .fn_ => |function| function.body,
        else => return false,
    };

    var parent_id = entity.parent;
    while (parent_id) |id| {
        const parent = g.symbol_table.get(id) orelse return false;
        if (parent.kind == .struct_ or parent.kind == .enum_ or parent.kind == .union_) {
            if (id >= bodies_list.items.len) return false;
            const body = &bodies_list.items[id];
            switch (body.*) {
                .struct_ => |*structure| {
                    var changed = false;
                    for (@constCast(structure.methods)) |*method| {
                        if (method.body != method_body) continue;
                        if (!method.is_allocating) {
                            method.is_allocating = true;
                            changed = true;
                        }
                    }
                    return changed;
                },
                else => return false,
            }
        }
        parent_id = parent.parent;
    }
    return false;
}

fn markFunctionAllocating(
    bodies_list: *std.ArrayListUnmanaged(bodies.BodyKind),
    g: *const graph.CrateGraph,
    fn_id: spine.EntityId,
) bool {
    if (fn_id >= bodies_list.items.len) return false;
    var changed = false;
    const body = &bodies_list.items[fn_id];
    switch (body.*) {
        .fn_ => |*function| {
            if (!function.is_allocating) {
                function.is_allocating = true;
                changed = true;
            }
        },
        else => return false,
    }
    if (markStructMethodAllocating(bodies_list, g, fn_id)) changed = true;
    return changed;
}

fn propagateResolvedCallEffects(
    bodies_list: *std.ArrayListUnmanaged(bodies.BodyKind),
    view: *const bodies.Bodies,
    g: *const graph.CrateGraph,
) void {
    // The caller's own body view, so the std-method question this scanner asks
    // reads exactly the expression and type tables `resolveMethods` just read.
    // Every write still goes through `bodies_list`; this only reads.
    const scanner: ResolvedCallEffectScanner = .{
        .exprs = view.exprs,
        .stmts = view.stmts,
        .bodies = bodies_list.items,
        .g = g,
        .view = view,
    };
    var round: usize = 0;
    while (round < bodies_list.items.len) : (round += 1) {
        var changed = false;
        for (bodies_list.items, 0..) |body, owner_id| {
            switch (body) {
                .fn_ => |function| {
                    if (scanner.exprCallsAllocating(function.body) and
                        markFunctionAllocating(bodies_list, g, @intCast(owner_id)))
                    {
                        changed = true;
                    }
                },
                else => {},
            }
        }
        if (!changed) break;
    }
}

/// The feature names that decide which optional dependencies this build has.
///
/// `features` is the manifest's own feature table and `active` is what this
/// translation enabled. `complete` records whether `active` is already
/// transitively expanded: only then may an implicit feature missing from it be
/// read as "this build does not have that dependency".
const DependencyClosure = struct {
    features: []const ingest.Feature = &.{},
    active: []const []const u8 = &.{},
    complete: bool = false,
};

/// Cargo's explicit spelling for enabling an optional dependency: the feature
/// name is `dep:<name>` with the dependency's own name, dashes and all.
const dependency_feature_prefix = "dep:";

/// Whether `feature` is the implicit feature Cargo creates for `dependency`.
/// The name is the dependency's, with `-` written `_`, so `foo-bar` is enabled
/// by a feature called `foo_bar`.
fn isImplicitDependencyFeature(feature: []const u8, dependency: []const u8) bool {
    if (std.mem.eql(u8, feature, dependency)) return true;
    if (feature.len != dependency.len) return false;
    for (feature, dependency) |left, right| {
        if ((if (left == '_') '-' else left) != right) return false;
    }
    return true;
}

fn activeNamesDependency(active: []const []const u8, dependency: []const u8) bool {
    for (active) |entry| {
        if (!std.mem.startsWith(u8, entry, dependency_feature_prefix)) continue;
        if (std.mem.eql(u8, entry[dependency_feature_prefix.len..], dependency)) return true;
    }
    return false;
}

/// Whether any ACTIVE feature lists `dep:<dependency>` among its own members.
/// The members are the manifest's raw strings, which is what keeps the `dep:`
/// prefix visible here; an inactive feature's `dep:` reference enables nothing,
/// so only features this build enabled are consulted.
fn activeFeatureMemberNamesDependency(
    closure: DependencyClosure,
    dependency: []const u8,
) bool {
    for (closure.active) |active_name| {
        for (closure.features) |feature| {
            if (!std.mem.eql(u8, feature.name, active_name)) continue;
            for (feature.members) |member| {
                if (!std.mem.startsWith(u8, member, dependency_feature_prefix)) continue;
                if (std.mem.eql(u8, member[dependency_feature_prefix.len..], dependency)) {
                    return true;
                }
            }
            break;
        }
    }
    return false;
}

/// Whether the active feature closure gives this build `dependency`.
///
/// A dependency that is not optional is always a dependency: no feature turns
/// one off. An optional one is built only when the closure enables it — through
/// the implicit feature Cargo creates for its name, through a `dep:<name>`
/// named outright, or through an active feature that lists it — and an optional
/// dependency the closure never mentions is one this build does not have.
/// Recording it anyway is what made adler's `compiler_builtins` and `core`
/// dependencies of a build that enables neither, and the backend then refused
/// the crate for two crates its source never names.
///
/// Nothing is concluded from a selection that may be under-expanded: a caller
/// list replaces the manifest default and arrives exactly as written, so a
/// dependency it leaves out may still be reachable through a feature the list
/// names but does not expand. Such a dependency stays a dependency.
fn dependencyEnabled(dependency: ingest.Dependency, closure: DependencyClosure) bool {
    if (!dependency.optional) return true;
    if (!closure.complete) return true;
    for (closure.active) |active_name| {
        if (isImplicitDependencyFeature(active_name, dependency.name)) return true;
    }
    if (activeNamesDependency(closure.active, dependency.name)) return true;
    return activeFeatureMemberNamesDependency(closure, dependency.name);
}

/// Whether any ACTIVE feature of the consuming crate forwards one of its own
/// features to `dependency`.
///
/// Cargo spells that edge `dep:<name>` or `<name>/<feature>`, optionally weak
/// as `<name>?/<feature>`. All three can switch a dependency feature on, and
/// the weak form still can: it declines only when the dependency is absent
/// from the graph, which is a fact about the resolution and not a promise that
/// no feature is enabled. A dependency whose name merely prefixes this member
/// — `foo` against `foo-bar/alloc` — is not a forward to `foo`.
fn activeFeatureForwardsDependency(
    closure: DependencyClosure,
    dependency: []const u8,
) bool {
    for (closure.active) |active_name| {
        for (closure.features) |feature| {
            if (!std.mem.eql(u8, feature.name, active_name)) continue;
            for (feature.members) |member| {
                if (std.mem.startsWith(u8, member, dependency_feature_prefix)) {
                    if (std.mem.eql(u8, member[dependency_feature_prefix.len..], dependency)) {
                        return true;
                    }
                    continue;
                }
                if (!std.mem.startsWith(u8, member, dependency)) continue;
                const tail = member[dependency.len..];
                if (tail.len != 0 and
                    (tail[0] == '/' or (tail[0] == '?' and tail.len > 1 and tail[1] == '/')))
                {
                    return true;
                }
            }
            break;
        }
    }
    return false;
}

/// Whether this build's RESOLVED feature set for `dependency` is certainly
/// empty.
///
/// The dependency's own declaration is necessary but not sufficient. It says
/// what the dependency table asked for and nothing about the forward edge that
/// lives in this crate's feature table, which is why
/// `num-traits = { default-features = false }` under a
/// `std = ["num-traits/std"]` feature is NOT an empty set: `default-features =
/// false` already removed the defaults, and the forward puts `std` on. wyhash
/// is the other shape: `rand_core = { version = "0.5" }` with no
/// `default-features` key and no `[features]` table at all, so nothing was
/// removed and nothing forwards.
///
/// Nothing is read from the dependency's own manifest, and nothing from the
/// runtime binding: both are facts about other crates. And an under-expanded
/// selection answers nothing at all, which is why `complete` gates the whole
/// question rather than only its last step.
fn resolvedFeaturesKnownEmpty(
    dependency: ingest.Dependency,
    closure: DependencyClosure,
) bool {
    if (!closure.complete) return false;
    if (dependency.features.len != 0) return false;
    if (dependency.default_features == false) return false;
    return !activeFeatureForwardsDependency(closure, dependency.name);
}

fn manifestDependency(
    allocator: std.mem.Allocator,
    dependency: ingest.Dependency,
    index: usize,
    closure: DependencyClosure,
) !graph.CrateDep {
    // Initialised so the record's OWN defaults apply. `undefined` suppresses
    // them, which would leave any field this function forgets to assign
    // reading garbage — and the backend reads `resolved_features_known_empty`
    // to decide whether a package may be omitted, so a field left unassigned
    // here is a wrong answer rather than a crash. Every field is still assigned
    // explicitly below; this only makes a future one safe by default.
    var result: graph.CrateDep = .{ .extern_name = &.{}, .local_alias = &.{}, .id = 0 };
    result.extern_name = try allocator.dupe(u8, dependency.package orelse dependency.name);
    errdefer allocator.free(result.extern_name);
    result.local_alias = try allocator.dupe(u8, dependency.name);
    result.id = @intCast(index + 1);
    result.version = if (dependency.version) |value| try allocator.dupe(u8, value) else null;
    errdefer if (result.version) |value| allocator.free(value);
    result.path = if (dependency.path) |value| try allocator.dupe(u8, value) else null;
    errdefer if (result.path) |value| allocator.free(value);
    result.git = if (dependency.git) |value| try allocator.dupe(u8, value) else null;
    errdefer if (result.git) |value| allocator.free(value);
    result.optional = dependency.optional;
    result.default_features = dependency.default_features;
    var owned_features: [][]const u8 = &.{};
    if (dependency.features.len > 0) {
        owned_features = try allocator.alloc([]const u8, dependency.features.len);
        var initialized_features: usize = 0;
        errdefer {
            for (owned_features[0..initialized_features]) |feature| allocator.free(feature);
            allocator.free(owned_features);
        }
        for (dependency.features, 0..) |feature, feature_index| {
            owned_features[feature_index] = try allocator.dupe(u8, feature);
            initialized_features += 1;
        }
    }
    result.features = owned_features;
    // Read from this crate's own feature table and nothing else, so the answer
    // is about this build and not about the dependency's crate.
    result.resolved_features_known_empty = resolvedFeaturesKnownEmpty(dependency, closure);
    return result;
}

fn manifestDependencies(
    allocator: std.mem.Allocator,
    dependencies: []const ingest.Dependency,
    closure: DependencyClosure,
) ![]const graph.CrateDep {
    // Count first and allocate exactly that many: a dependency the closure does
    // not enable is skipped before `manifestDependency` duplicates a single
    // string of its own, so nothing it would have owned is allocated here and
    // there is nothing of its to unwind.
    var enabled_count: usize = 0;
    for (dependencies) |dependency| {
        if (dependencyEnabled(dependency, closure)) enabled_count += 1;
    }
    if (enabled_count == 0) return &.{};
    const result = try allocator.alloc(graph.CrateDep, enabled_count);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |entry| {
            allocator.free(entry.extern_name);
            allocator.free(entry.local_alias);
            if (entry.version) |version| allocator.free(version);
            if (entry.path) |path| allocator.free(path);
            if (entry.git) |git| allocator.free(git);
            for (entry.features) |feature| allocator.free(feature);
            if (entry.features.len > 0) allocator.free(entry.features);
        }
        allocator.free(result);
    }
    var index: usize = 0;
    for (dependencies) |dependency| {
        if (!dependencyEnabled(dependency, closure)) continue;
        // Ids stay dense and one-based over the dependencies this build
        // actually has. `CrateGraph.validateTopology` requires
        // `dependency.id == position + 1`, so a skipped dependency must leave
        // no gap behind it.
        result[index] = try manifestDependency(allocator, dependency, index, closure);
        initialized += 1;
        index += 1;
    }
    return result;
}

fn analyzeSourceWithGraph(
    allocator: std.mem.Allocator,
    maybe_io: ?std.Io,
    crate_dir: []const u8,
    manifest: ingest.Manifest,
    src: []const u8,
    options: AnalysisOptions,
    dependency_closure: DependencyClosure,
) !ir.RustIr {
    const edition = try manifestEdition(manifest.edition);
    // 1. Construct root module and symbol table in CrateGraph
    var g = graph.CrateGraph.init(allocator);

    const root_entity_name = try allocator.dupe(u8, "");
    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = root_entity_name,
        .span = default_span,
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
        .span = default_span,
        .items = &.{},
        .attributes = &.{},
    });
    const crate_deps = try manifestDependencies(allocator, manifest.dependencies, dependency_closure);
    try g.addCrate(.{
        .name = try allocator.dupe(u8, manifest.name),
        .edition = edition,
        .kind = if (manifest.is_bin) .bin else .lib,
        .root = 0,
        .deps = crate_deps,
        .is_translated = true,
    });

    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    var bodies_list: std.ArrayListUnmanaged(bodies.BodyKind) = .empty;
    // Slot 0 for root module
    try bodies_list.append(allocator, .none);
    // Const initializers are lowered into the expr table by cst, so the table
    // must exist (and share the allocator) before CST extraction runs.
    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;

    // 2. CST extraction across root and submodules
    var fn_origins: cst.FunctionOriginTable = .empty;
    defer {
        var it = fn_origins.valueIterator();
        while (it.next()) |origin| {
            allocator.free(origin.source);
        }
        fn_origins.deinit(allocator);
    }

    const root_dir = std.fs.path.dirname(manifest.root_path) orelse crate_dir;
    var cst_ctx: cst.Ctx = .{
        .alloc = allocator,
        .g = &g,
        .src = src,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
        .base_dir = root_dir,
        .io = maybe_io,
        .include_tests = options.include_tests,
        .cfg = options.cfg,
        .function_origins = &fn_origins,
    };
    // `extractFile` resolves names and binds declaration types before return.
    try cst.extractFile(&cst_ctx);

    // 4. Function body lowering
    var stmts_list: std.ArrayListUnmanaged(exprs.Statement) = .empty;
    var pats_list: std.ArrayListUnmanaged(exprs.Pattern) = .empty;

    var ts_ctx: ts_ext.Ctx = .{
        .alloc = allocator,
        .g = &g,
        .exprs = &exprs_list,
        .stmts = &stmts_list,
        .pats = &pats_list,
        .types = &types_list,
        .bodies_list = &bodies_list,
        .src = src,
        .mod_id = 0,
    };

    // Step 4 walks every function body there is, in the order the graph
    // registered them.
    //
    // The cursor is what makes one pass enough. Every function the FILE
    // declared is registered before this loop starts, and a function that only
    // comes into existence while a body is being lowered — a block-local helper
    // — is registered during it, so it necessarily lands at a LATER index:
    // `symbol_table.add` hands ids out in registration order and appends.
    // Advancing a cursor therefore reaches the newly registered ones without a
    // second sweep, and the array's length is re-read each step precisely
    // because lowering a body can grow it.
    //
    // Nothing here is keyed on a name or on a counted offset: identity is the
    // graph's own `EntityId` throughout, so a block-local helper that shadows
    // a name in the enclosing scope keeps its own identity and the order a body
    // happens to be discovered in never becomes part of it. Nothing here
    // resolves a call either — the resolution pass runs over the whole tree
    // once every body exists, which is what makes a call written before the
    // helper it names resolve the same way a call written after it does.
    var cursor: usize = 0;
    while (true) {
        const entities = g.symbol_table.entities.items;
        if (cursor >= entities.len) break;
        // Copied, not referenced: lowering a body below can reallocate the
        // array this slice points into.
        const ent = entities[cursor];
        cursor += 1;
        if (ent.kind != .fn_) continue;
        // Whether this is a BLOCK-LOCAL helper — one declared inside another
        // function's body — is answered by the parent, and by nothing else.
        //
        // Such a helper is lowered IN PLACE, under its own scope, while the body
        // enclosing it is read, so it is finished before this cursor reaches its
        // id; picking it would ask `extractFunction` to find a CST node by a
        // name the source never wrote, since such a helper carries a
        // collision-safe emitted identity rather than its own spelling.
        //
        // The parent kind enumerates every case without ambiguity: a module
        // function is parented to a `.module`, an inherent or trait method to a
        // `.struct_` / `.enum_` / `.union_` / `.impl_`, and a block-local helper to
        // the `.fn_` that holds it — including a helper declared inside another
        // helper, which is parented to the outer one. It is also the same test
        // the backend applies when it hoosts these, so declaration, extraction
        // and emission share ONE definition of "block-local helper" instead of
        // three that could drift.
        //
        // No body-derived test is OR'd in beside it. A body id cannot tell a
        // lowered helper from an unlowered module function: `fn outer() { fn
        // noop() {} noop(); }` puts the helper's block at expr id 0, and a module
        // function also sits at body 0 until this loop reaches it — so any
        // sentinel keyed on the id either refuses the crate's very first helper
        // or skips a module function that still owes a body, and neither reading
        // of the number is about ownership at all.
        if (ent.parent) |parent_id| {
            if (g.symbol_table.get(parent_id)) |parent| {
                if (parent.kind == .fn_) continue;
                // A std owner SEEDED into the graph — `Cursor::new` and the
                // rest of the prelude surfaces `ensureExternalModule` builds —
                // lives under an EXTERN module and has its body row already
                // written. No source declared it, so there is no origin to
                // find and no source text to extract it from; asking for one
                // would refuse every crate that touches a seeded std item. The
                // extern module is the whole evidence, and it is asked of the
                // module row itself rather than inferred from a name.
                if (parent.kind == .module) {
                    if (g.moduleForEntity(parent_id)) |module| {
                        if (module.is_extern) continue;
                    }
                }
            }
        }
        // Everything left is this loop's work and is lowered from its OWN
        // source. The function extracted just before this one is no guide to
        // this one's text: the module's own functions are all registered first,
        // so whichever of them ran last can be a completely unrelated sibling —
        // or a different `#[test]` altogether — and reading this body out of
        // that source would silently lower it against the wrong file. A missing
        // origin is therefore refused outright rather than guessed at.
        if (ent.id >= bodies_list.items.len) return error.FunctionBodyMissing;
        const origin = fn_origins.get(ent.id) orelse return error.FunctionModuleSourceMissing;
        ts_ctx.src = origin.source;
        ts_ctx.mod_id = origin.lexical_module;
        const extracted = try ts_ext.extractFunction(&ts_ctx, ent.id);
        if (!extracted) return error.FunctionBodyMissing;
    }
    // Seed allocation effects from direct collection producers.
    markDirectCollectionEffects(&bodies_list, exprs_list.items, stmts_list.items);

    // 5. Type inference, method resolution, and generic monomorphization
    var b_temp: bodies.Bodies = .{
        .exprs = exprs_list.items,
        .stmts = stmts_list.items,
        .pats = pats_list.items,
        .types = types_list.items,
        .bodies = bodies_list.items,
    };

    var instantiation_table: monomorphize.InstantiationTable = .{};
    defer instantiation_table.deinit(allocator);
    var generated = try infer.genWithGraph(allocator, &b_temp, &g);
    defer generated.deinit(allocator);
    generated.defer_pending_casts = true;
    try infer.materializeDerivedTypes(allocator, &types_list, pats_list.items, &generated);
    b_temp.types = types_list.items;
    var solved = try infer.solveWithGen(allocator, &b_temp, &generated);
    defer solved.deinit(allocator);
    solved.apply(exprs_list.items);
    try infer.materializeSolvedSourceTypes(allocator, &b_temp, &types_list, &generated, &solved, &g);
    try materializeOpaqueFunctionReturns(
        allocator,
        &types_list,
        exprs_list.items,
        bodies_list.items,
    );
    try materializeInferredConstructorTypes(
        allocator,
        &types_list,
        exprs_list.items,
        solved.instantiations,
    );
    b_temp.types = types_list.items;
    _ = try resolve_methods.resolveMethods(&g, &b_temp);
    // Resolution may replace either table when it appends typed operands.
    // Both tables use this allocator; adopt them without copying their prefix.
    if (b_temp.exprs.ptr != exprs_list.items.ptr) {
        exprs_list.deinit(allocator);
        exprs_list = .fromOwnedSlice(@constCast(b_temp.exprs));
    } else {
        exprs_list.items.len = b_temp.exprs.len;
    }
    if (b_temp.types.ptr != types_list.items.ptr) {
        types_list.deinit(allocator);
        types_list = .fromOwnedSlice(@constCast(b_temp.types));
    } else {
        types_list.items.len = b_temp.types.len;
    }
    if (generated.source_completion_pending) {
        try infer.materializeSolvedSourceTypes(allocator, &b_temp, &types_list, &generated, &solved, &g);
    }
    try infer.completePendingCasts(&b_temp);
    propagateResolvedCallEffects(&bodies_list, &b_temp, &g);
    instantiation_table = try monomorphize.collectInstantiations(allocator, &g, &b_temp);
    // Inference records are keyed by source expression. Copy their
    // concrete argument slices into the long-lived table before `solved`
    // releases its map and arena-owned temporary buffers.
    try instantiation_table.mergeInferred(allocator, solved.instantiations);

    const final_exprs = try exprs_list.toOwnedSlice(allocator);
    errdefer allocator.free(final_exprs);
    const final_stmts = try stmts_list.toOwnedSlice(allocator);
    errdefer allocator.free(final_stmts);
    const final_pats = try pats_list.toOwnedSlice(allocator);
    errdefer allocator.free(final_pats);
    const final_types = try types_list.toOwnedSlice(allocator);
    errdefer allocator.free(final_types);
    const final_body_kinds = try bodies_list.toOwnedSlice(allocator);
    errdefer allocator.free(final_body_kinds);

    const final_bodies: bodies.Bodies = .{
        .exprs = final_exprs,
        .stmts = final_stmts,
        .pats = final_pats,
        .types = final_types,
        .bodies = final_body_kinds,
    };

    return .{
        .crate_name = manifest.name,
        .edition = manifest.edition,
        .graph = g,
        .types = final_bodies.types,
        .bodies = final_bodies,
        .instantiations = try instantiation_table.instantiations.toOwnedSlice(allocator),
    };
}

fn writeTestFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    relative_path: []const u8,
    content: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ root, relative_path });
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

test "analyzeSource on simple Rust function" {
    // The pipeline's internal allocations (cst param names, infer result
    // types) are arena-owned like the reference driver; use an arena here so
    // the strict testing allocator stays leak-clean.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const src =
        \\//! Crate documentation.
        \\#![no_std]
        \\pub fn add(a: i32, b: i32) -> i32 {
        \\    a + b
        \\}
    ;

    const rust_ir = try analyzeSource(allocator, "mini", "2021", src);

    try std.testing.expectEqualStrings("mini", rust_ir.crate_name);
    try std.testing.expectEqualStrings("2021", rust_ir.edition);
    const no_std = for (rust_ir.graph.modules.items[0].attributes) |attribute| {
        if (std.mem.eql(u8, attribute.name, "no_std")) break attribute;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("", no_std.meta);
}

test "analyzeSourceWithOptions includes cfg test module and function body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const source =
        \\fn normal() {}
        \\
        \\#[cfg(test)]
        \\mod tests {
        \\    #[test]
        \\    fn smoke() {
        \\        assert_eq!(1, 1);
        \\    }
        \\}
    ;

    const options: AnalysisOptions = .{ .include_tests = true };
    const rust_ir = try analyzeSourceWithOptions(
        allocator,
        "include_tests",
        "2021",
        source,
        options,
    );
    const helpers = struct {
        fn findEntity(
            rust_ir_: *const ir.RustIr,
            kind: spine.EntityKind,
            name: []const u8,
        ) ?spine.Entity {
            for (rust_ir_.graph.symbol_table.entities.items) |entity| {
                if (entity.kind != kind) continue;
                if (std.mem.eql(u8, entity.name, name)) return entity;
            }
            return null;
        }

        fn hasAttribute(attributes: []const spine.Attribute, name: []const u8) bool {
            for (attributes) |attribute| {
                if (std.mem.eql(u8, attribute.name, name)) return true;
            }
            return false;
        }
    };

    try std.testing.expect(helpers.findEntity(&rust_ir, .fn_, "normal") != null);

    const tests_module = helpers.findEntity(&rust_ir, .module, "tests") orelse
        return error.TestUnexpectedResult;
    const smoke = helpers.findEntity(&rust_ir, .fn_, "smoke") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?spine.EntityId, tests_module.id), smoke.parent);
    try std.testing.expect(helpers.hasAttribute(smoke.attributes, "test"));

    try std.testing.expect(smoke.id < rust_ir.bodies.bodies.len);
    const smoke_body = switch (rust_ir.bodies.bodies[smoke.id]) {
        .fn_ => |function_body| function_body,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(smoke_body.body < rust_ir.bodies.exprs.len);
    const root_block = switch (rust_ir.bodies.exprs[smoke_body.body].kind) {
        .block => |block| block,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), root_block.statements.len);

    const assertion_statement_id = root_block.statements[0];
    try std.testing.expect(assertion_statement_id < rust_ir.bodies.stmts.len);
    const assertion_expression_id = switch (rust_ir.bodies.stmts[assertion_statement_id].kind) {
        .expr => |expression_id| expression_id,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(assertion_expression_id < rust_ir.bodies.exprs.len);
    const assertion_marker = switch (rust_ir.bodies.exprs[assertion_expression_id].kind) {
        .unsupported => |unsupported| unsupported.reason,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.startsWith(u8, assertion_marker, "assertion:"));

    const assertion_condition_id = try std.fmt.parseInt(
        exprs.NodeId,
        assertion_marker["assertion:".len..],
        10,
    );
    try std.testing.expect(assertion_condition_id < rust_ir.bodies.exprs.len);
    const assertion_condition = switch (rust_ir.bodies.exprs[assertion_condition_id].kind) {
        .binary => |binary| binary,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(assertion_condition.op == .eq);
    try std.testing.expect(assertion_condition.lhs < rust_ir.bodies.exprs.len);
    try std.testing.expect(assertion_condition.rhs < rust_ir.bodies.exprs.len);

    const lhs = rust_ir.bodies.exprs[assertion_condition.lhs];
    try std.testing.expect(lhs.kind == .literal);
    try std.testing.expect(lhs.kind.literal == .int);
    try std.testing.expectEqual(@as(i128, 1), lhs.kind.literal.int.value);

    const rhs = rust_ir.bodies.exprs[assertion_condition.rhs];
    try std.testing.expect(rhs.kind == .literal);
    try std.testing.expect(rhs.kind.literal == .int);
    try std.testing.expectEqual(@as(i128, 1), rhs.kind.literal.int.value);
}

test "analyzeSourceWithOptions resolves a qualified trait call" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // `<[u8; 2] as FromHex>::from_hex(..)` names the trait explicitly. The self
    // type is only a coercion target, so the call must resolve through
    // `FromHex` rather than through a `[u8; 2]` impl.
    const source =
        \\#[derive(Debug, PartialEq)]
        \\enum DecodeError { OddLength, BadDigit { index: usize } }
        \\
        \\trait FromHex { fn from_hex(text: &str) -> Result<Self, DecodeError>; }
        \\
        \\impl FromHex for [u8; 2] {
        \\    fn from_hex(text: &str) -> Result<Self, DecodeError> {
        \\        if text.len() != 2 { return Err(DecodeError::OddLength); }
        \\        Ok([0, 0])
        \\    }
        \\}
        \\
        \\fn check() -> bool {
        \\    <[u8; 2] as FromHex>::from_hex("ab") == Ok([0x61, 0x62])
        \\}
    ;

    const rust_ir = try analyzeSourceWithOptions(
        allocator,
        "qualified_trait_call",
        "2021",
        source,
        .{ .include_tests = true },
    );

    var saw_call = false;
    for (rust_ir.bodies.exprs) |expression| {
        switch (expression.kind) {
            .unsupported => |unresolved| {
                if (std.mem.eql(u8, unresolved.reason, "unresolved call")) {
                    return error.UnresolvedCallStillRejected;
                }
            },
            .call => |call| switch (call.call_kind) {
                .associated => saw_call = true,
                else => {},
            },
            else => {},
        }
    }
    try std.testing.expect(saw_call);
}

test "shift and arithmetic on a reference operand yield the pointee type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // Rust auto-derefs reference operands for `>>` and `-`, so both results are
    // `u8`. Equating a result with `&u8` makes the following `as usize` cast
    // record a `u8` source against a `&u8` operand, which IR validation rejects.
    const source =
        \\pub fn nibble(byte: &u8) -> usize {
        \\    (byte >> 4) as usize + (byte - 1) as usize
        \\}
    ;

    const rust_ir = try analyzeSourceWithOptions(allocator, "shift", "2021", source, .{});
    try ir.validateForTranslation(&rust_ir);
}

test "a declared Option return type reaches the returned variant expressions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // `Option<u32>` is not interned as a TypeId, so the solver's `ret` edge and
    // tail unification cannot type the variants. A bare `return None;` and a
    // `Some(x)` tail both reached the backend untyped without this.
    const source =
        \\pub fn maybe(x: u32) -> Option<u32> {
        \\    if x == 0 { return None; }
        \\    Some(x)
        \\}
    ;

    const rust_ir = try analyzeSourceWithOptions(allocator, "option_ret", "2021", source, .{});
    try ir.validateForTranslation(&rust_ir);

    // Both variant expressions must carry the declared Option type.
    var option_typed = false;
    for (rust_ir.bodies.exprs) |expression| {
        const kind = switch (expression.kind) {
            .enum_variant => |value| value.variant,
            else => continue,
        };
        const type_id = expression.ty orelse continue;
        if (type_id >= rust_ir.bodies.types.len) continue;
        if (std.meta.activeTag(rust_ir.bodies.types[type_id]) == .option) {
            option_typed = true;
        }
        std.debug.assert(kind.len > 0);
    }
    try std.testing.expect(option_typed);
}

test "a declared std::io::Result carries std::io::Error as its error arm" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // `std::io::Result<T>` is the alias `Result<T, io::Error>`. Read as an
    // untranslated external nominal it names no type the backend could lower,
    // and the runtime's `r2z.io.Result` is written in exactly this two-arm
    // shape, so the declaration has to arrive as one.
    const source =
        \\use std::io;
        \\
        \\pub fn read_all(bytes: &[u8]) -> io::Result<&[u8]> {
        \\    bytes
        \\}
    ;

    const rust_ir = try analyzeSourceWithOptions(allocator, "io_result", "2021", source, .{});
    try ir.validateForTranslation(&rust_ir);

    var declared: ?types.Type = null;
    for (rust_ir.graph.symbol_table.entities.items, 0..) |entity, index| {
        if (entity.kind != .fn_) continue;
        if (!std.mem.eql(u8, entity.name, "read_all")) continue;
        declared = switch (rust_ir.bodies.bodies[index]) {
            .fn_ => |fn_body| fn_body.ret,
            else => return error.TestUnexpectedResult,
        };
    }
    const result = switch (declared orelse return error.TestUnexpectedResult) {
        .result => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(result.is_error_unionable);
    const err = switch (result.err) {
        .external_nominal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 3), err.path.len);
    try std.testing.expectEqualStrings("std", err.path[0]);
    try std.testing.expectEqualStrings("io", err.path[1]);
    try std.testing.expectEqualStrings("Error", err.path[2]);
}

test "a user-defined Iterator impl keeps next on its struct" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // A `for` over a user iterator lowers through `next()`, so the trait
    // method must land on the struct rather than being left unresolved.
    const source =
        \\pub struct Counter { left: u32 }
        \\
        \\impl Iterator for Counter {
        \\    type Item = u32;
        \\    fn next(&mut self) -> Option<u32> {
        \\        if self.left == 0 { return None; }
        \\        self.left -= 1;
        \\        Some(self.left)
        \\    }
        \\}
        \\
        \\pub fn total() -> u32 {
        \\    let mut sum = 0;
        \\    for value in Counter { sum += value; }
        \\    sum
        \\}
    ;

    const rust_ir = try analyzeSourceWithOptions(allocator, "user_iter", "2021", source, .{});
    try ir.validateForTranslation(&rust_ir);
}

test "Rust documentation survives source analysis and canonical serialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\//! Counts bytes without retaining the input.
        \\/// Returns the fixed count.
        \\#[doc = "The result is seven."]
        \\pub fn count() -> u8 { 7 }
        \\// This is implementation commentary, not documentation.
        \\pub fn plain() -> u8 { 0 }
    ;
    const rust_ir = try analyzeSource(allocator, "documented", "2021", source);
    const encoded = try ir.serialize.encode(allocator, &rust_ir);
    const decoded = try ir.serialize.decode(allocator, encoded);

    const module_attributes = decoded.graph.modules.items[0].attributes;
    try std.testing.expectEqual(@as(usize, 1), module_attributes.len);
    try std.testing.expectEqualStrings("doc", module_attributes[0].name);
    try std.testing.expectEqualStrings(
        "Counts bytes without retaining the input.",
        module_attributes[0].meta,
    );
    var found_count = false;
    for (decoded.graph.symbol_table.entities.items) |entity| {
        if (std.mem.eql(u8, entity.name, "count")) {
            found_count = true;
            try std.testing.expectEqual(@as(usize, 2), entity.attributes.len);
            try std.testing.expectEqualStrings("doc", entity.attributes[0].name);
            try std.testing.expectEqualStrings("Returns the fixed count.", entity.attributes[0].meta);
            try std.testing.expectEqualStrings("The result is seven.", entity.attributes[1].meta);
        } else if (std.mem.eql(u8, entity.name, "plain")) {
            try std.testing.expectEqual(@as(usize, 0), entity.attributes.len);
        }
    }
    try std.testing.expect(found_count);
}

test "analyzeSourceWithOptions selects configured feature-gated entity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const source =
        \\#[cfg(feature = "alloc")]
        \\pub struct AllocOnly;
    ;

    const configured_ir = try analyzeSourceWithOptions(
        allocator,
        "configured_cfg",
        "2021",
        source,
        .{ .cfg = .{ .features = &.{"alloc"} } },
    );
    const default_ir = try analyzeSource(
        allocator,
        "default_cfg",
        "2021",
        source,
    );
    const helpers = struct {
        fn hasEntity(
            rust_ir_: *const ir.RustIr,
            kind: spine.EntityKind,
            name: []const u8,
        ) bool {
            for (rust_ir_.graph.symbol_table.entities.items) |entity| {
                if (entity.kind != kind) continue;
                if (std.mem.eql(u8, entity.name, name)) return true;
            }
            return false;
        }
    };

    try std.testing.expect(helpers.hasEntity(&configured_ir, .struct_, "AllocOnly"));
    try std.testing.expect(!helpers.hasEntity(&default_ir, .struct_, "AllocOnly"));
}

test "analyzeSource rejects invalid edition metadata" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const src =
        \\pub fn valid() {}
    ;
    try std.testing.expectError(
        error.InvalidEdition,
        analyzeSource(allocator, "invalid_edition", "not-an-edition", src),
    );
}

test "analyzeSource rejects a bodyless function declaration during parsing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const src =
        \\pub fn missing()
    ;
    try std.testing.expectError(
        error.ParseFailed,
        analyzeSource(allocator, "missing_body", "2021", src),
    );
}

test "analysis rejects a function whose module source is unavailable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var crate_graph = graph.CrateGraph.init(allocator);
    _ = try crate_graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try allocator.dupe(u8, ""),
        .span = default_span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try crate_graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = try allocator.dupe(u8, ""),
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = default_span,
        .items = &.{},
        .attributes = &.{},
    });
    _ = try crate_graph.symbol_table.add(.{
        .id = 1,
        .kind = .module,
        .name = try allocator.dupe(u8, "missing"),
        .span = default_span,
        .visibility = .public,
        .parent = 0,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try crate_graph.addModule(.{
        .id = 1,
        .kind = .file,
        .name = try allocator.dupe(u8, "missing"),
        .parent = 0,
        .source_path = try allocator.dupe(u8, "missing.rs"),
        .is_crate = false,
        .is_extern = false,
        .span = default_span,
        .items = &.{},
        .attributes = &.{},
    });
    const function_id = try crate_graph.symbol_table.add(.{
        .id = 2,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "missing_source"),
        .span = default_span,
        .visibility = .public,
        .parent = 1,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    var module_sources: ModuleSources = .empty;
    try module_sources.put(allocator, 0, "root module source");
    defer module_sources.deinit(allocator);

    try std.testing.expectError(
        error.FunctionModuleSourceMissing,
        sourceForFunction(&crate_graph, &module_sources, function_id),
    );
}

test "analyzeSource rejects malformed expressions and patterns" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const malformed_sources = [_][]const u8{
        "pub fn broken() -> u8 { 1 + }",
        "pub fn broken(value: u8) -> u8 { match value { mut => 1 } }",
        "pub fn broken(value: u8) -> u8 { match value { => 1 } }",
        "pub fn broken() { missing( }",
        "pub fn broken() { if { 1 } }",
        "pub fn broken() { let mut = 1; }",
        "pub fn broken(values: [u8; 1]) { for in values {} }",
    };
    for (malformed_sources) |source| {
        try std.testing.expectError(
            error.ParseFailed,
            analyzeSource(allocator, "malformed", "2021", source),
        );
    }
}

test "analyzeSource preserves valid body and lowers scalar casts and shared references" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const src =
        \\pub fn good(value: u16) -> u16 {
        \\    let incremented = value + 1;
        \\    incremented
        \\}
        \\
        \\pub fn refuse() -> u16 {
        \\    let value = 7u8;
        \\    let casted = value as u16;
        \\    let borrowed = &value;
        \\    casted
        \\}
    ;

    const rust_ir = try analyzeSource(allocator, "cast_ref", "2021", src);
    const helpers = struct {
        fn findFunction(
            rust_ir_: *const ir.RustIr,
            name: []const u8,
        ) ?spine.Entity {
            for (rust_ir_.graph.symbol_table.entities.items) |entity| {
                if (entity.kind != .fn_) continue;
                if (std.mem.eql(u8, entity.name, name)) return entity;
            }
            return null;
        }

        fn findBody(
            rust_ir_: *const ir.RustIr,
            entity: spine.Entity,
        ) ?exprs.BlockExpr {
            if (entity.id >= rust_ir_.bodies.bodies.len) return null;
            const fn_body = switch (rust_ir_.bodies.bodies[entity.id]) {
                .fn_ => |body| body,
                else => return null,
            };
            if (fn_body.body >= rust_ir_.bodies.exprs.len) return null;
            return switch (rust_ir_.bodies.exprs[fn_body.body].kind) {
                .block => |block| block,
                else => null,
            };
        }
    };

    const good_entity = helpers.findFunction(&rust_ir, "good") orelse
        return error.MissingGoodFunction;
    const refuse_entity = helpers.findFunction(&rust_ir, "refuse") orelse
        return error.MissingRefuseFunction;
    try std.testing.expect(good_entity.id < rust_ir.bodies.bodies.len);
    try std.testing.expect(refuse_entity.id < rust_ir.bodies.bodies.len);

    const good_body = helpers.findBody(&rust_ir, good_entity) orelse
        return error.MissingGoodBody;
    for (good_body.statements) |statement_id| {
        try std.testing.expect(statement_id < rust_ir.bodies.stmts.len);
    }
    try std.testing.expectEqual(@as(usize, 1), good_body.statements.len);
    const good_statement = rust_ir.bodies.stmts[good_body.statements[0]];
    const good_let = switch (good_statement.kind) {
        .let => |statement| statement,
        else => return error.ExpectedGoodLet,
    };
    const good_init = good_let.init orelse return error.ExpectedGoodInitializer;
    try std.testing.expect(good_init < rust_ir.bodies.exprs.len);
    const good_expression = rust_ir.bodies.exprs[good_init];
    const good_binary = switch (good_expression.kind) {
        .binary => |binary| binary,
        else => return error.ExpectedGoodBinary,
    };
    try std.testing.expect(good_binary.lhs < rust_ir.bodies.exprs.len);
    try std.testing.expect(good_binary.rhs < rust_ir.bodies.exprs.len);
    try std.testing.expect(
        rust_ir.bodies.exprs[good_binary.lhs].kind == .path,
    );
    try std.testing.expect(
        rust_ir.bodies.exprs[good_binary.rhs].kind == .literal,
    );
    const good_tail_id = good_body.tail orelse return error.ExpectedGoodTail;
    try std.testing.expect(good_tail_id < rust_ir.bodies.exprs.len);
    try std.testing.expect(rust_ir.bodies.exprs[good_tail_id].kind == .path);

    const refuse_body = helpers.findBody(&rust_ir, refuse_entity) orelse
        return error.MissingRefuseBody;
    for (refuse_body.statements) |statement_id| {
        try std.testing.expect(statement_id < rust_ir.bodies.stmts.len);
    }
    try std.testing.expectEqual(@as(usize, 3), refuse_body.statements.len);

    const cast_statement = rust_ir.bodies.stmts[refuse_body.statements[1]];
    const cast_let = switch (cast_statement.kind) {
        .let => |statement| statement,
        else => return error.ExpectedCastLet,
    };
    const cast_init = cast_let.init orelse return error.ExpectedCastInitializer;
    try std.testing.expect(cast_init < rust_ir.bodies.exprs.len);
    const cast_expr = switch (rust_ir.bodies.exprs[cast_init].kind) {
        .cast => |cast| cast,
        else => return error.ExpectedSupportedCast,
    };
    try std.testing.expect(cast_expr.operand < rust_ir.bodies.exprs.len);
    try std.testing.expect(cast_expr.target < rust_ir.bodies.types.len);
    try std.testing.expectEqual(
        types.Type{ .prim = .u16 },
        rust_ir.bodies.types[cast_expr.target],
    );
    try std.testing.expectEqual(cast_expr.target, rust_ir.bodies.exprs[cast_init].ty.?);

    const reference_statement = rust_ir.bodies.stmts[refuse_body.statements[2]];
    const reference_let = switch (reference_statement.kind) {
        .let => |statement| statement,
        else => return error.ExpectedReferenceLet,
    };
    const reference_init =
        reference_let.init orelse return error.ExpectedReferenceInitializer;
    try std.testing.expect(reference_init < rust_ir.bodies.exprs.len);
    const reference_kind = rust_ir.bodies.exprs[reference_init].kind;
    try std.testing.expect(reference_kind != .path);
    try std.testing.expect(reference_kind != .unit);
    const reference = switch (reference_kind) {
        .unary => |unary| unary,
        else => return error.ExpectedSharedReference,
    };
    switch (reference.op) {
        .ref => |mode| try std.testing.expect(mode == .shared),
        else => return error.ExpectedSharedReference,
    }
    try std.testing.expect(reference.operand < rust_ir.bodies.exprs.len);
    try std.testing.expect(
        rust_ir.bodies.exprs[reference.operand].kind == .path,
    );

    const refuse_tail_id = refuse_body.tail orelse return error.ExpectedRefuseTail;
    try std.testing.expect(refuse_tail_id < rust_ir.bodies.exprs.len);
    try std.testing.expect(rust_ir.bodies.exprs[refuse_tail_id].kind == .path);
}

test "analyzeSource retains literal and empty macro refusals without dropping valid function" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const src =
        \\pub fn oversized_literal() -> u128 {
        \\    340282366920938463463374607431768211455u128
        \\}
        \\
        \\pub fn empty_macro_argument() {
        \\    vec![1,,2]
        \\}
        \\
        \\pub fn valid() -> u8 {
        \\    7
        \\}
    ;

    const rust_ir = try analyzeSource(allocator, "expr_refusal", "2021", src);
    const helpers = struct {
        fn functionBlock(
            rust_ir_: *const ir.RustIr,
            name: []const u8,
        ) ?exprs.BlockExpr {
            var function: ?spine.Entity = null;
            for (rust_ir_.graph.symbol_table.entities.items) |entity| {
                if (entity.kind != .fn_) continue;
                if (std.mem.eql(u8, entity.name, name)) {
                    function = entity;
                    break;
                }
            }
            const entity = function orelse return null;
            if (entity.id >= rust_ir_.bodies.bodies.len) return null;
            const fn_body = switch (rust_ir_.bodies.bodies[entity.id]) {
                .fn_ => |body| body,
                else => return null,
            };
            if (fn_body.body >= rust_ir_.bodies.exprs.len) return null;
            return switch (rust_ir_.bodies.exprs[fn_body.body].kind) {
                .block => |block| block,
                else => null,
            };
        }

        fn tailExpression(
            rust_ir_: *const ir.RustIr,
            name: []const u8,
        ) ?exprs.Expr {
            const block = functionBlock(rust_ir_, name) orelse return null;
            const tail = block.tail orelse return null;
            if (tail >= rust_ir_.bodies.exprs.len) return null;
            return rust_ir_.bodies.exprs[tail];
        }
    };

    const oversized = helpers.tailExpression(&rust_ir, "oversized_literal") orelse
        return error.MissingOversizedLiteralBody;
    try std.testing.expectEqual(.unsupported, std.meta.activeTag(oversized.kind));

    const empty_macro = helpers.tailExpression(&rust_ir, "empty_macro_argument") orelse
        return error.MissingEmptyMacroBody;
    try std.testing.expectEqual(.unsupported, std.meta.activeTag(empty_macro.kind));

    const valid = helpers.tailExpression(&rust_ir, "valid") orelse
        return error.MissingValidBody;
    const valid_literal = switch (valid.kind) {
        .literal => |literal| switch (literal) {
            .int => |integer| integer,
            else => return error.ExpectedValidIntegerLiteral,
        },
        else => return error.ExpectedValidLiteralBody,
    };
    try std.testing.expectEqual(@as(i128, 7), valid_literal.value);
}

test "analyzeSource resolves enum variant match patterns and refuses missing scoped path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const src =
        \\pub enum State {
        \\    Ready,
        \\    Done,
        \\}
        \\
        \\pub fn classify(state: State) -> u8 {
        \\    match state {
        \\        State::Ready => 1,
        \\        State::Done => 2,
        \\    }
        \\}
        \\
        \\pub fn missing(state: State) -> u8 {
        \\    match state {
        \\        Missing::Ready => 0,
        \\        _ => 1,
        \\    }
        \\}
    ;

    const rust_ir = try analyzeSource(allocator, "scoped_patterns", "2021", src);
    const helpers = struct {
        fn findEntity(
            rust_ir_: *const ir.RustIr,
            kind: spine.EntityKind,
            name: []const u8,
        ) ?spine.Entity {
            for (rust_ir_.graph.symbol_table.entities.items) |entity| {
                if (entity.kind != kind) continue;
                if (std.mem.eql(u8, entity.name, name)) return entity;
            }
            return null;
        }

        fn findBody(
            rust_ir_: *const ir.RustIr,
            entity: spine.Entity,
        ) ?exprs.BlockExpr {
            if (entity.id >= rust_ir_.bodies.bodies.len) return null;
            const fn_body = switch (rust_ir_.bodies.bodies[entity.id]) {
                .fn_ => |body| body,
                else => return null,
            };
            if (fn_body.body >= rust_ir_.bodies.exprs.len) return null;
            return switch (rust_ir_.bodies.exprs[fn_body.body].kind) {
                .block => |block| block,
                else => null,
            };
        }
    };

    const state_entity = helpers.findEntity(&rust_ir, .enum_, "State") orelse
        return error.MissingStateEnum;
    const expected_variants = [_][]const u8{ "Ready", "Done" };
    try std.testing.expect(state_entity.id != 0);

    const classify_entity = helpers.findEntity(&rust_ir, .fn_, "classify") orelse
        return error.MissingClassifyFunction;
    const classify_body = helpers.findBody(&rust_ir, classify_entity) orelse
        return error.MissingClassifyBody;
    const classify_tail = classify_body.tail orelse return error.MissingClassifyTail;
    const classify_match = switch (rust_ir.bodies.exprs[classify_tail].kind) {
        .match => |match| match,
        else => return error.ExpectedClassifyMatch,
    };
    try std.testing.expectEqual(@as(usize, 2), classify_match.arms.len);

    for (classify_match.arms, expected_variants) |arm, expected_variant| {
        try std.testing.expectEqual(@as(usize, 1), arm.patterns.len);
        const pattern_id = arm.patterns[0];
        try std.testing.expect(pattern_id < rust_ir.bodies.pats.len);
        const pattern = rust_ir.bodies.pats[pattern_id];
        const path = switch (pattern.kind) {
            .path => |path| path,
            .binding => return error.ScopedVariantPatternBecameBinding,
            .unsupported => return error.ScopedVariantPatternUnsupported,
            else => return error.ExpectedScopedVariantPath,
        };
        try std.testing.expect(path.def != 0);
        try std.testing.expectEqual(state_entity.id, path.def);
        try std.testing.expect(path.variant != null);
        try std.testing.expectEqualStrings(expected_variant, path.variant.?);
    }

    const missing_entity = helpers.findEntity(&rust_ir, .fn_, "missing") orelse
        return error.MissingMissingFunction;
    const missing_body = helpers.findBody(&rust_ir, missing_entity) orelse
        return error.MissingMissingBody;
    try std.testing.expect(missing_body.tail != null);

    var unsupported_pattern_count: usize = 0;
    for (rust_ir.bodies.pats) |pattern| {
        switch (pattern.kind) {
            .unsupported => |unsupported| {
                unsupported_pattern_count += 1;
                try std.testing.expect(unsupported.reason.len > 0);
            },
            .path => |path| try std.testing.expect(path.def != 0),
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), unsupported_pattern_count);
}

test "analyzeSource refuses slice match pattern without dropping valid function" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const src =
        \\pub fn first(values: &[u8]) -> u8 {
        \\    match values {
        \\        [first, ..] => first,
        \\    }
        \\}
        \\
        \\pub fn valid(value: u8) -> u8 {
        \\    value + 1
        \\}
    ;

    const rust_ir = try analyzeSource(allocator, "slice_match", "2021", src);
    const helpers = struct {
        fn findFunction(
            rust_ir_: *const ir.RustIr,
            name: []const u8,
        ) ?spine.Entity {
            for (rust_ir_.graph.symbol_table.entities.items) |entity| {
                if (entity.kind != .fn_) continue;
                if (std.mem.eql(u8, entity.name, name)) return entity;
            }
            return null;
        }

        fn findBody(
            rust_ir_: *const ir.RustIr,
            entity: spine.Entity,
        ) ?exprs.BlockExpr {
            if (entity.id >= rust_ir_.bodies.bodies.len) return null;
            const fn_body = switch (rust_ir_.bodies.bodies[entity.id]) {
                .fn_ => |body| body,
                else => return null,
            };
            if (fn_body.body >= rust_ir_.bodies.exprs.len) return null;
            return switch (rust_ir_.bodies.exprs[fn_body.body].kind) {
                .block => |block| block,
                else => null,
            };
        }
    };

    const first_entity = helpers.findFunction(&rust_ir, "first") orelse
        return error.MissingSliceFunction;
    const valid_entity = helpers.findFunction(&rust_ir, "valid") orelse
        return error.MissingValidFunction;

    const first_body = helpers.findBody(&rust_ir, first_entity) orelse
        return error.MissingSliceBody;
    const first_tail_id = first_body.tail orelse return error.MissingSliceTail;
    try std.testing.expect(first_tail_id < rust_ir.bodies.exprs.len);
    const first_tail_kind = rust_ir.bodies.exprs[first_tail_id].kind;
    const match_reason = switch (first_tail_kind) {
        .unsupported => |unsupported| unsupported.reason,
        else => return error.ExpectedUnsupportedMatch,
    };
    try std.testing.expect(
        std.mem.indexOf(u8, match_reason, "unsupported match pattern") != null,
    );

    var found_slice_pattern = false;
    for (rust_ir.bodies.pats) |pattern| {
        switch (pattern.kind) {
            .wildcard => return error.UnexpectedWildcardSlicePattern,
            .unsupported => |unsupported| {
                if (std.mem.indexOf(u8, unsupported.reason, "slice pattern") != null) {
                    found_slice_pattern = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(found_slice_pattern);

    const valid_body = helpers.findBody(&rust_ir, valid_entity) orelse
        return error.MissingValidBody;
    const valid_tail_id = valid_body.tail orelse return error.MissingValidTail;
    try std.testing.expect(valid_tail_id < rust_ir.bodies.exprs.len);
    try std.testing.expect(rust_ir.bodies.exprs[valid_tail_id].kind != .unsupported);
}

test "analyzeSource: const array + primitive initializers parsed into const body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const src =
        \\pub const BIT_REVERSE_TABLE: [u16; 4] = [0x00, 0x80, 0x40, 0xC0];
        \\pub const ZEROES: [u8; 256] = [0u8; 256];
        \\pub const FLAG: bool = true;
        \\pub const COUNT: u32 = 42;
    ;

    const rust_ir = try analyzeSource(allocator, "consts", "2021", src);
    const body_tables = rust_ir.bodies;

    var saw_table = false;
    var saw_zeroes = false;
    var saw_flag = false;
    var saw_count = false;
    for (rust_ir.graph.symbol_table.entities.items) |ent| {
        if (ent.kind != .const_) continue;
        const cb = switch (body_tables.bodies[ent.id]) {
            .const_ => |c| c,
            else => continue,
        };
        if (std.mem.eql(u8, ent.name, "BIT_REVERSE_TABLE")) {
            try std.testing.expect(cb.ty == .array);
            try std.testing.expectEqual(@as(u32, 4), cb.ty.array.len.literal);
            try std.testing.expect(cb.ty.array.elem.prim == .u16);
            const ex = body_tables.exprs[cb.init];
            try std.testing.expect(ex.kind == .array);
            try std.testing.expectEqual(@as(?u64, null), ex.kind.array.repeat);
            try std.testing.expectEqual(@as(usize, 4), ex.kind.array.elements.len);
            // First element 0x00 → 0; third element 0x40 → 64.
            const first = body_tables.exprs[ex.kind.array.elements[0]];
            try std.testing.expectEqual(@as(i128, 0), first.kind.literal.int.value);
            const third = body_tables.exprs[ex.kind.array.elements[2]];
            try std.testing.expectEqual(@as(i128, 64), third.kind.literal.int.value);
            saw_table = true;
        } else if (std.mem.eql(u8, ent.name, "ZEROES")) {
            try std.testing.expect(cb.ty == .array);
            try std.testing.expectEqual(@as(u32, 256), cb.ty.array.len.literal);
            const ex = body_tables.exprs[cb.init];
            try std.testing.expect(ex.kind == .array);
            try std.testing.expect(ex.kind == .array);
            try std.testing.expectEqual(@as(?u64, 256), ex.kind.array.repeat);
            try std.testing.expectEqual(@as(usize, 1), ex.kind.array.elements.len);
            saw_zeroes = true;
        } else if (std.mem.eql(u8, ent.name, "FLAG")) {
            const ex = body_tables.exprs[cb.init];
            try std.testing.expect(ex.kind == .literal);
            try std.testing.expect(ex.kind.literal == .boolean);
            try std.testing.expectEqual(true, ex.kind.literal.boolean);
            saw_flag = true;
        } else if (std.mem.eql(u8, ent.name, "COUNT")) {
            const ex = body_tables.exprs[cb.init];
            try std.testing.expect(ex.kind == .literal);
            try std.testing.expect(ex.kind.literal == .int);
            try std.testing.expectEqual(@as(i128, 42), ex.kind.literal.int.value);
            saw_count = true;
        }
    }
    try std.testing.expect(saw_table);
    try std.testing.expect(saw_zeroes);
    try std.testing.expect(saw_flag);
    try std.testing.expect(saw_count);
}

test "analyzeSource decodes char constants to their scalar value, not their first byte" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // The token text is not the value. `'\n'` carries no backslash and `'é'`
    // is two UTF-8 bytes whose lead byte is 0xc3, so a const initializer that
    // reads the first byte of the token emits 92 for every escape and 195 for
    // `'é'` — a wrong number that still compiles.
    const src =
        \\pub const PLAIN: char = 'a';
        \\pub const NEWLINE: char = '\n';
        \\pub const TAB: char = '\t';
        \\pub const CARRIAGE_RETURN: char = '\r';
        \\pub const NUL: char = '\0';
        \\pub const SINGLE_QUOTE: char = '\'';
        \\pub const DOUBLE_QUOTE: char = '"';
        \\pub const BACKSLASH: char = '\\';
        \\pub const HEX_ASCII: char = '\x41';
        \\pub const RAW_LATIN: char = 'é';
        \\pub const ESCAPED_BMP: char = '\u{E9}';
        \\pub const ASTRAL: char = '\u{1F600}';
        \\
        \\pub struct Marker {
        \\    pub id: u32,
        \\}
        \\
        \\impl Marker {
        \\    pub const ASSOCIATED_TAB: char = '\t';
        \\}
    ;

    const rust_ir = try analyzeSource(allocator, "char_consts", "2021", src);
    try ir.validateForTranslation(&rust_ir);

    const expected = [_]struct { name: []const u8, value: u32 }{
        .{ .name = "PLAIN", .value = 'a' },
        .{ .name = "NEWLINE", .value = 0x0a },
        .{ .name = "TAB", .value = 0x09 },
        .{ .name = "CARRIAGE_RETURN", .value = 0x0d },
        .{ .name = "NUL", .value = 0x00 },
        .{ .name = "SINGLE_QUOTE", .value = '\'' },
        .{ .name = "DOUBLE_QUOTE", .value = '"' },
        .{ .name = "BACKSLASH", .value = '\\' },
        .{ .name = "HEX_ASCII", .value = 0x41 },
        .{ .name = "RAW_LATIN", .value = 0x00e9 },
        .{ .name = "ESCAPED_BMP", .value = 0x00e9 },
        .{ .name = "ASTRAL", .value = 0x1f600 },
        .{ .name = "ASSOCIATED_TAB", .value = 0x09 },
    };
    for (expected) |want| {
        var entity_id: ?spine.EntityId = null;
        for (rust_ir.graph.symbol_table.entities.items) |entity| {
            if (entity.kind != .const_) continue;
            if (!std.mem.eql(u8, entity.name, want.name)) continue;
            entity_id = entity.id;
            break;
        }
        const id = entity_id orelse return error.MissingCharConstant;
        const constant = switch (rust_ir.bodies.bodies[id]) {
            .const_ => |value| value,
            else => return error.UnexpectedConstantBody,
        };
        // The declared type drives the emitter, which writes a u21 scalar;
        // the value is the Unicode scalar the Rust compiler computes.
        try std.testing.expectEqual(types.Type{ .prim = .char }, constant.ty);
        const expression = rust_ir.bodies.exprs[constant.init];
        try std.testing.expect(expression.kind == .literal);
        try std.testing.expect(expression.kind.literal == .character);
        try std.testing.expectEqual(want.value, expression.kind.literal.character.value);
    }
}

test "analyzeSource preserves Unicode character and string values across contexts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const src =
        \\pub const ASTRAL: char = '\u{1_f_642___}';
        \\pub const MAXIMUM: char = '\u{10_ffff_}';
        \\
        \\pub fn body_char() -> char { '\u{1_f_642___}' }
        \\pub fn accented() -> char { 'é' }
        \\pub fn astral() -> char { '🙂' }
        \\pub fn body_text() -> &'static str { "\u{1_f_642___}\u{10_ffff_}" }
        \\
        \\pub fn classify(value: char) -> u8 {
        \\    match value {
        \\        '\u{1_f_642___}' => 1,
        \\        '\u{10_ffff_}' => 2,
        \\        _ => 0,
        \\    }
        \\}
    ;
    const rust_ir = try analyzeSource(allocator, "underscored_escapes", "2021", src);
    try ir.validateForTranslation(&rust_ir);

    const char_consts = [_]struct { name: []const u8, value: u32 }{
        .{ .name = "ASTRAL", .value = 0x1f642 },
        .{ .name = "MAXIMUM", .value = 0x10ffff },
    };
    for (char_consts) |want| {
        var entity_id: ?spine.EntityId = null;
        for (rust_ir.graph.symbol_table.entities.items) |entity| {
            if (entity.kind != .const_) continue;
            if (!std.mem.eql(u8, entity.name, want.name)) continue;
            entity_id = entity.id;
            break;
        }
        const id = entity_id orelse return error.MissingUnderscoredCharConstant;
        const constant = switch (rust_ir.bodies.bodies[id]) {
            .const_ => |value| value,
            else => return error.UnexpectedConstantBody,
        };
        try std.testing.expectEqual(types.Type{ .prim = .char }, constant.ty);
        const expression = rust_ir.bodies.exprs[constant.init];
        try std.testing.expect(expression.kind == .literal);
        try std.testing.expect(expression.kind.literal == .character);
        try std.testing.expectEqual(want.value, expression.kind.literal.character.value);
    }

    const helpers = struct {
        fn bodyTail(rust_ir_: *const ir.RustIr, name: []const u8) ?exprs.NodeId {
            for (rust_ir_.graph.symbol_table.entities.items) |entity| {
                if (entity.kind != .fn_ or !std.mem.eql(u8, entity.name, name)) continue;
                const fn_body = switch (rust_ir_.bodies.bodies[entity.id]) {
                    .fn_ => |body| body,
                    else => return null,
                };
                const block = switch (rust_ir_.bodies.exprs[fn_body.body].kind) {
                    .block => |value| value,
                    else => return null,
                };
                return block.tail;
            }
            return null;
        }
    };

    const body_chars = [_]struct { name: []const u8, value: u32 }{
        .{ .name = "body_char", .value = 0x1f642 },
        .{ .name = "accented", .value = 0xe9 },
        .{ .name = "astral", .value = 0x1f642 },
    };
    for (body_chars) |want| {
        const char_tail = helpers.bodyTail(&rust_ir, want.name) orelse
            return error.MissingBodyChar;
        const char_literal = switch (rust_ir.bodies.exprs[char_tail].kind) {
            .literal => |literal| literal,
            else => return error.ExpectedBodyCharLiteral,
        };
        try std.testing.expect(char_literal == .character);
        try std.testing.expectEqual(want.value, char_literal.character.value);
    }

    const text_tail = helpers.bodyTail(&rust_ir, "body_text") orelse
        return error.MissingBodyText;
    const text_literal = switch (rust_ir.bodies.exprs[text_tail].kind) {
        .literal => |literal| literal,
        else => return error.ExpectedBodyTextLiteral,
    };
    try std.testing.expect(text_literal == .string);
    try std.testing.expectEqualStrings("\xF0\x9F\x99\x82\xF4\x8F\xBF\xBF", text_literal.string.bytes);

    const classify_tail = helpers.bodyTail(&rust_ir, "classify") orelse
        return error.MissingClassifyTail;
    const classify_match = switch (rust_ir.bodies.exprs[classify_tail].kind) {
        .match => |match| match,
        else => return error.ExpectedClassifyMatch,
    };
    try std.testing.expectEqual(@as(usize, 3), classify_match.arms.len);
    const expected_arms = [_]struct { value: u32, result: i128 }{
        .{ .value = 0x1f642, .result = 1 },
        .{ .value = 0x10ffff, .result = 2 },
    };
    for (classify_match.arms[0..expected_arms.len], expected_arms) |arm, want| {
        try std.testing.expectEqual(@as(usize, 1), arm.patterns.len);
        const pattern = rust_ir.bodies.pats[arm.patterns[0]];
        try std.testing.expect(pattern.kind == .literal);
        try std.testing.expect(pattern.kind.literal == .character);
        try std.testing.expectEqual(want.value, pattern.kind.literal.character.value);
        const arm_literal = switch (rust_ir.bodies.exprs[arm.body].kind) {
            .literal => |literal| literal,
            else => return error.ExpectedArmIntegerLiteral,
        };
        try std.testing.expect(arm_literal == .int);
        try std.testing.expectEqual(want.result, arm_literal.int.value);
    }
    const fallback = classify_match.arms[expected_arms.len];
    try std.testing.expectEqual(@as(usize, 1), fallback.patterns.len);
    try std.testing.expect(rust_ir.bodies.pats[fallback.patterns[0]].kind == .wildcard);
    const fallback_literal = switch (rust_ir.bodies.exprs[fallback.body].kind) {
        .literal => |literal| literal,
        else => return error.ExpectedArmIntegerLiteral,
    };
    try std.testing.expect(fallback_literal == .int);
    try std.testing.expectEqual(@as(i128, 0), fallback_literal.int.value);
}

test "analyzeSource resolves generic alias inherent method chain" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const src =
        \\pub struct Fletcher<T> {}
        \\pub type Fletcher16 = Fletcher<u16>;
        \\impl<T> Fletcher<T> {
        \\    pub fn new() -> Fletcher<T> {
        \\        Fletcher {}
        \\    }
        \\    pub fn update(self, state: u16) -> Fletcher<T> {
        \\        Fletcher {}
        \\    }
        \\    pub fn value(self) -> u16 {
        \\        0
        \\    }
        \\}
        \\pub fn calculate(input: u16) -> u16 {
        \\    Fletcher16::new().update(input + 1).value()
        \\}
    ;

    const rust_ir = try analyzeSource(allocator, "fletcher", "2021", src);

    var new_id: ?spine.EntityId = null;
    var update_id: ?spine.EntityId = null;
    var value_id: ?spine.EntityId = null;
    for (rust_ir.graph.symbol_table.entities.items) |entity| {
        if (entity.kind != .fn_) continue;
        if (std.mem.eql(u8, entity.name, "new")) {
            new_id = entity.id;
        } else if (std.mem.eql(u8, entity.name, "update")) {
            update_id = entity.id;
        } else if (std.mem.eql(u8, entity.name, "value")) {
            value_id = entity.id;
        }
    }
    try std.testing.expect(new_id != null);
    try std.testing.expect(update_id != null);
    try std.testing.expect(value_id != null);

    var saw_new = false;
    var saw_update = false;
    var saw_value = false;
    var saw_primitive_add = false;
    for (rust_ir.bodies.exprs) |expression| {
        try std.testing.expect(expression.kind != .unsupported);
        switch (expression.kind) {
            .call => |call| switch (call.call_kind) {
                .associated => |target| {
                    try std.testing.expectEqual(new_id.?, target);
                    saw_new = true;
                },
                else => {},
            },
            .method_call => |method_call| {
                const target = rust_ir.graph.symbol_table.get(method_call.method) orelse
                    return error.TestUnexpectedResult;
                try std.testing.expect(target.kind == .fn_);
                if (target.id == update_id.?) {
                    saw_update = true;
                } else if (target.id == value_id.?) {
                    saw_value = true;
                } else {
                    return error.TestUnexpectedResult;
                }
            },
            .binary => |binary| {
                try std.testing.expect(binary.op == .add);
                saw_primitive_add = true;
            },
            else => {},
        }
    }

    try std.testing.expect(saw_new);
    try std.testing.expect(saw_update);
    try std.testing.expect(saw_value);
    try std.testing.expect(saw_primitive_add);
}

test "analyzeSource propagates generic alias constructor type through a local receiver" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const src =
        \\pub struct Fletcher<T> { state: u16, marker: T }
        \\pub type Fletcher16 = Fletcher<u16>;
        \\impl Fletcher<u16> {
        \\    pub fn new() -> Fletcher<u16> {
        \\        Fletcher { state: 0u16, marker: 0u16 }
        \\    }
        \\}
        \\impl<T> Fletcher<T> {
        \\    pub fn update(&mut self, data: &[u8]) {}
        \\    pub fn value(&self) -> u16 {
        \\        self.state
        \\    }
        \\}
        \\pub fn calculate(data: &[u8]) {
        \\    let mut checksum = Fletcher16::new();
        \\    checksum.update(data);
        \\    checksum.value();
        \\}
    ;

    const rust_ir = try analyzeSource(allocator, "fletcher_local", "2021", src);

    var fletcher_id: ?spine.EntityId = null;
    var calculate_id: ?spine.EntityId = null;
    var new_id: ?spine.EntityId = null;
    var update_id: ?spine.EntityId = null;
    var value_id: ?spine.EntityId = null;
    for (rust_ir.graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .struct_ and std.mem.eql(u8, entity.name, "Fletcher")) {
            fletcher_id = entity.id;
        } else if (entity.kind == .fn_ and std.mem.eql(u8, entity.name, "calculate")) {
            calculate_id = entity.id;
        } else if (entity.kind == .fn_ and std.mem.eql(u8, entity.name, "new")) {
            new_id = entity.id;
        } else if (entity.kind == .fn_ and std.mem.eql(u8, entity.name, "update")) {
            update_id = entity.id;
        } else if (entity.kind == .fn_ and std.mem.eql(u8, entity.name, "value")) {
            value_id = entity.id;
        }
    }
    try std.testing.expect(fletcher_id != null);
    try std.testing.expect(calculate_id != null);
    try std.testing.expect(new_id != null);
    try std.testing.expect(update_id != null);
    try std.testing.expect(value_id != null);

    var checksum_id: ?spine.EntityId = null;
    for (rust_ir.graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .field and
            entity.parent == calculate_id.? and
            std.mem.eql(u8, entity.name, "checksum"))
        {
            checksum_id = entity.id;
            break;
        }
    }
    try std.testing.expect(checksum_id != null);

    const target_chain = struct {
        fn hasNode(ir_: *const ir.RustIr, node: exprs.NodeId) bool {
            if (node >= ir_.bodies.exprs.len) return false;
            return switch (ir_.bodies.exprs[node].kind) {
                .unsupported => true,
                .call => |call| hasArgs(ir_, call.args),
                .method_call => |method| hasNode(ir_, method.receiver) or
                    hasArgs(ir_, method.args),
                .struct_lit => |literal| hasFields(ir_, literal.fields),
                .enum_variant => |variant| hasArgs(ir_, variant.tuple_fields) or
                    hasNamedFields(ir_, variant.named_fields),
                .cast => |cast| hasNode(ir_, cast.operand),
                .field => |field| hasNode(ir_, field.base),
                .index => |index| hasNode(ir_, index.base) or hasNode(ir_, index.index),
                .binary => |binary| hasNode(ir_, binary.lhs) or hasNode(ir_, binary.rhs),
                .unary => |unary| hasNode(ir_, unary.operand),
                .assign => |assign| hasNode(ir_, assign.target) or hasNode(ir_, assign.value),
                .try_ => |try_expr| hasNode(ir_, try_expr.inner),
                .return_ => |return_expr| if (return_expr.value) |value|
                    hasNode(ir_, value)
                else
                    false,
                .array => |array| hasArgs(ir_, array.elements),
                .vec_lit => |vec_lit| hasArgs(ir_, vec_lit.elements) or
                    hasVecRepeatCount(ir_, vec_lit.repeat),
                else => false,
            };
        }

        fn hasArgs(ir_: *const ir.RustIr, args: []const exprs.NodeId) bool {
            for (args) |arg| {
                if (hasNode(ir_, arg)) return true;
            }
            return false;
        }

        fn hasFields(ir_: *const ir.RustIr, fields: []const exprs.FieldInit) bool {
            for (fields) |field| {
                if (hasNode(ir_, field.value)) return true;
            }
            return false;
        }

        /// A `vec![e; n]` count is an ordinary expression, so a failure
        /// reachable only through it is still reachable through the literal.
        fn hasVecRepeatCount(ir_: *const ir.RustIr, repeat: ?exprs.VecRepeatCount) bool {
            const count = repeat orelse return false;
            return switch (count) {
                .literal => false,
                .expression => |node| hasNode(ir_, node),
            };
        }

        fn hasNamedFields(ir_: *const ir.RustIr, fields: []const exprs.FieldInit) bool {
            for (fields) |field| {
                if (hasNode(ir_, field.value)) return true;
            }
            return false;
        }
    }.hasNode;

    var new_node: ?exprs.NodeId = null;
    var update_node: ?exprs.NodeId = null;
    var value_node: ?exprs.NodeId = null;
    var saw_new = false;
    var saw_update = false;
    var saw_value = false;
    for (rust_ir.bodies.exprs) |expression| {
        switch (expression.kind) {
            .call => |call| switch (call.call_kind) {
                .associated => |target| {
                    try std.testing.expectEqual(new_id.?, target);
                    new_node = expression.id;
                    saw_new = true;
                },
                else => {},
            },
            .method_call => |method_call| {
                if (method_call.method != update_id.? and method_call.method != value_id.?) {
                    continue;
                }
                try std.testing.expect(method_call.receiver < rust_ir.bodies.exprs.len);
                const receiver = rust_ir.bodies.exprs[method_call.receiver];
                try std.testing.expect(receiver.kind == .path);
                try std.testing.expectEqual(checksum_id.?, receiver.kind.path.def);
                const target = rust_ir.graph.symbol_table.get(method_call.method) orelse
                    return error.TestUnexpectedResult;
                try std.testing.expect(target.kind == .fn_);
                const owner_id = target.parent orelse return error.TestUnexpectedResult;
                const owner = rust_ir.graph.symbol_table.get(owner_id) orelse
                    return error.TestUnexpectedResult;
                try std.testing.expect(owner.kind == .impl_);
                try std.testing.expectEqualStrings("Fletcher<T>", owner.name);
                try std.testing.expectEqual(fletcher_id.?, owner.parent orelse
                    return error.TestUnexpectedResult);

                if (method_call.method == update_id.?) {
                    update_node = expression.id;
                    saw_update = true;
                } else {
                    value_node = expression.id;
                    saw_value = true;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(saw_new);
    try std.testing.expect(saw_update);
    try std.testing.expect(saw_value);
    try std.testing.expect(!target_chain(&rust_ir, new_node.?));
    try std.testing.expect(!target_chain(&rust_ir, update_node.?));
    try std.testing.expect(!target_chain(&rust_ir, value_node.?));
}
test "cst.extractFile resolves hex error module and skips disabled strict core impl" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const error_source_path = "test/crates/hex/src/error.rs";
    var crate_graph = graph.CrateGraph.init(allocator);
    defer crate_graph.deinit();
    _ = try crate_graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try allocator.dupe(u8, ""),
        .span = default_span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try crate_graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = default_span,
        .items = &.{},
        .attributes = &.{},
    });
    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    var bodies_list: std.ArrayListUnmanaged(bodies.BodyKind) = .empty;
    try bodies_list.append(allocator, .none);
    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;
    var cst_ctx: cst.Ctx = .{
        .alloc = allocator,
        .g = &crate_graph,
        .src =
        \\#[cfg(feature = "serde")]
        \\pub mod serde;
        \\#[cfg(feature = "std")]
        \\impl Missing { fn fail() {} }
        \\mod error;
        ,
        .types_list = &types_list,
        .bodies_list = &bodies_list,
        .exprs_list = &exprs_list,
        .base_dir = "test/crates/hex/src",
        .io = std.testing.io,
    };

    try cst.extractFile(&cst_ctx);
    var error_module_id: ?spine.EntityId = null;
    var error_type_id: ?spine.EntityId = null;
    var display_impl_parent: ?spine.EntityId = null;
    var saw_serde_module = false;
    var saw_tests_module = false;
    var saw_std_error_impl = false;
    for (crate_graph.modules.items) |module| {
        if (std.mem.eql(u8, module.name, "serde")) {
            saw_serde_module = true;
            continue;
        }
        if (!std.mem.eql(u8, module.name, "error")) continue;
        try std.testing.expectEqualStrings(error_source_path, module.source_path orelse
            return error.MissingHexErrorSource);
        try std.testing.expect(module.items.len > 0);
    }
    for (crate_graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .module and std.mem.eql(u8, entity.name, "error")) {
            error_module_id = entity.id;
        }
        if (entity.kind == .module and std.mem.eql(u8, entity.name, "tests")) {
            saw_tests_module = true;
        }
        if (entity.kind == .enum_ and std.mem.eql(u8, entity.name, "FromHexError")) {
            error_type_id = entity.id;
        }
        if (entity.kind == .impl_ and
            std.mem.eql(u8, entity.name, "fmt::Display for FromHexError"))
        {
            display_impl_parent = entity.parent;
        }
        if (entity.kind == .impl_ and
            std.mem.indexOf(u8, entity.name, "std::error::Error") != null)
        {
            saw_std_error_impl = true;
        }
    }
    const module_id = error_module_id orelse return error.MissingHexErrorModule;
    const error_id = error_type_id orelse return error.MissingHexErrorType;
    const error_entity = crate_graph.symbol_table.get(error_id) orelse
        return error.MissingHexErrorType;
    try std.testing.expectEqual(module_id, error_entity.parent orelse
        return error.MissingHexErrorModule);
    try std.testing.expectEqual(error_id, display_impl_parent orelse
        return error.MissingHexDisplayImpl);
    try std.testing.expect(!saw_serde_module);
    try std.testing.expect(!saw_tests_module);
    try std.testing.expect(!saw_std_error_impl);
}

test "analyzeCrate preserves inactive dependency feature metadata" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(
        allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path },
    );
    try writeTestFile(
        allocator,
        io,
        root,
        "Cargo.toml",
        \\[package]
        \\name = "consumer"
        \\
        \\[dependencies]
        \\helper = { default-features = false, features = ["derive", "std"] }
        ,
    );
    try writeTestFile(allocator, io, root, "src/lib.rs", "pub fn marker() {}\n");

    const rust_ir = try analyzeCrate(allocator, io, root);

    try std.testing.expectEqual(@as(usize, 1), rust_ir.graph.crates.items.len);
    const crate = rust_ir.graph.crates.items[0];
    try std.testing.expectEqual(@as(usize, 1), crate.deps.len);
    const dependency = crate.deps[0];
    try std.testing.expectEqualStrings("helper", dependency.local_alias);
    try std.testing.expect(dependency.default_features != null);
    try std.testing.expect(!dependency.default_features.?);
    try std.testing.expectEqual(@as(usize, 2), dependency.features.len);
    try std.testing.expectEqualStrings("derive", dependency.features[0]);
    try std.testing.expectEqualStrings("std", dependency.features[1]);
}

test "analyzeCrate: recursive multi-file submodule discovery (nested + #[path])" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // `test/crates/multimod` exercises:
    //  - `mod foo;` -> `src/foo.rs`
    //  - `mod bar;` inside `foo.rs` -> `src/foo/bar.rs` (two-level recursion)
    //  - `#[path = "custom.rs"] pub mod custom_pub;` (attribute-resolved path)
    const rust_ir = try analyzeCrate(allocator, std.testing.io, "test/crates/multimod");

    // The dense `modules[]` table is indexed by module id (see `addModule`),
    // which is independent of the entity ids in the symbol table. Look each
    // module up by scanning `modules[]` and matching its name.
    const find_mod = struct {
        fn find(
            ir_: *const ir.RustIr,
            name_: []const u8,
        ) ?graph.Module {
            for (ir_.graph.modules.items) |m| {
                if (std.mem.eql(u8, m.name, name_)) return m;
            }
            return null;
        }
    }.find;

    // A root entity for `enter` must exist (root items intact).
    const enter_ent = struct {
        fn find(ir_: *const ir.RustIr) ?spine.EntityId {
            for (ir_.graph.symbol_table.entities.items) |ent| {
                if (std.mem.eql(u8, ent.name, "enter")) return ent.id;
            }
            return null;
        }
    }.find(&rust_ir);
    if (enter_ent == null) return error.MissingRootFn;

    // `mod foo;` was found as an out-of-line file module and populated.
    const foo_mod = find_mod(&rust_ir, "foo") orelse return error.MissingFooModule;
    try std.testing.expect(foo_mod.kind == .file);
    try std.testing.expect(foo_mod.source_path != null);
    try std.testing.expect(foo_mod.items.len > 0);

    // Two-level recursion: `foo` contains its child `bar` module.
    const bar_mod = find_mod(&rust_ir, "bar") orelse return error.MissingBarModule;
    try std.testing.expect(bar_mod.kind == .file);
    try std.testing.expect(bar_mod.source_path != null);
    try std.testing.expect(bar_mod.items.len > 0);

    // A `foo_fn` fn entity exists under module `foo`.
    const foo_fn = struct {
        fn find(ir_: *const ir.RustIr) ?spine.EntityId {
            for (ir_.graph.symbol_table.entities.items) |ent| {
                if (std.mem.eql(u8, ent.name, "foo_fn")) return ent.id;
            }
            return null;
        }
    }.find(&rust_ir);
    if (foo_fn == null) return error.MissingFooFn;

    // `#[path = "custom.rs"]` resolved the module from the attrs.
    const custom_mod = find_mod(&rust_ir, "custom_pub") orelse return error.MissingCustomModule;
    try std.testing.expect(custom_mod.source_path != null);
    try std.testing.expect(custom_mod.items.len > 0);
}

test "analyzeCrate lowers out-of-line impl methods and disambiguates inline ranges" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(
        allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path },
    );

    try writeTestFile(
        allocator,
        io,
        root,
        "Cargo.toml",
        \\[package]
        \\name = "cross_file_impl"
        \\edition = "2021"
        ,
    );
    try writeTestFile(
        allocator,
        io,
        root,
        "src/lib.rs",
        \\pub struct RootType;
        \\
        \\mod methods;
        ,
    );
    try writeTestFile(
        allocator,
        io,
        root,
        "src/methods.rs",
        \\impl crate::RootType {
        \\    pub fn from_module(&self) -> u32 {
        \\        37
        \\    }
        \\}
        \\
        \\mod first {
        \\    pub fn same_name() -> u32 {
        \\        11
        \\    }
        \\}
        \\
        \\mod second {
        \\    pub fn same_name() -> u32 {
        \\        22
        \\    }
        \\}
        ,
    );

    const rust_ir = try analyzeCrate(allocator, io, root);
    const helpers = struct {
        fn findEntity(
            rust_ir_: *const ir.RustIr,
            kind: spine.EntityKind,
            name: []const u8,
        ) ?spine.Entity {
            for (rust_ir_.graph.symbol_table.entities.items) |entity| {
                if (entity.kind != kind) continue;
                if (std.mem.eql(u8, entity.name, name)) return entity;
            }
            return null;
        }

        fn tailInteger(
            rust_ir_: *const ir.RustIr,
            entity: spine.Entity,
        ) !i128 {
            if (entity.id >= rust_ir_.bodies.bodies.len) return error.MissingFunctionBody;
            const function_body = switch (rust_ir_.bodies.bodies[entity.id]) {
                .fn_ => |body| body,
                else => return error.ExpectedFunctionBody,
            };
            if (function_body.body >= rust_ir_.bodies.exprs.len) {
                return error.MissingFunctionBlock;
            }
            const block = switch (rust_ir_.bodies.exprs[function_body.body].kind) {
                .block => |value| value,
                else => return error.ExpectedFunctionBlock,
            };
            const tail = block.tail orelse return error.ExpectedFunctionTail;
            if (tail >= rust_ir_.bodies.exprs.len) return error.MissingFunctionTail;
            return switch (rust_ir_.bodies.exprs[tail].kind) {
                .literal => |literal| switch (literal) {
                    .int => |value| value.value,
                    else => error.ExpectedIntegerTail,
                },
                else => error.ExpectedIntegerTail,
            };
        }
    };

    const root_type = helpers.findEntity(&rust_ir, .struct_, "RootType") orelse
        return error.MissingRootType;
    const method = helpers.findEntity(&rust_ir, .fn_, "from_module") orelse
        return error.MissingCrossFileMethod;
    const impl_id = method.parent orelse return error.MissingMethodImpl;
    const impl_entity = rust_ir.graph.symbol_table.get(impl_id) orelse
        return error.MissingMethodImpl;
    try std.testing.expectEqual(spine.EntityKind.impl_, impl_entity.kind);
    try std.testing.expectEqual(root_type.id, impl_entity.parent orelse
        return error.MissingImplTarget);
    try std.testing.expectEqual(
        @as(i128, 37),
        try helpers.tailInteger(&rust_ir, method),
    );

    var same_name_values: [2]i128 = undefined;
    var same_name_count: usize = 0;
    for (rust_ir.graph.symbol_table.entities.items) |entity| {
        if (entity.kind != .fn_ or !std.mem.eql(u8, entity.name, "same_name")) continue;
        if (same_name_count == same_name_values.len) return error.UnexpectedDuplicateFunction;
        same_name_values[same_name_count] = try helpers.tailInteger(&rust_ir, entity);
        same_name_count += 1;
    }
    try std.testing.expectEqual(same_name_values.len, same_name_count);
    try std.testing.expect(
        (same_name_values[0] == 11 and same_name_values[1] == 22) or
            (same_name_values[0] == 22 and same_name_values[1] == 11),
    );
}

test "analyzeSource: pre-P4 declarations and body graph stay lossless" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const src =
        \\mod state {
        \\    pub struct State(pub u8);
        \\
        \\    pub trait Inspect {
        \\        fn value(&self) -> u8;
        \\    }
        \\
        \\    pub fn initial() -> State {
        \\        State(1)
        \\    }
        \\}
        \\
        \\pub use state::State;
        \\
        \\mod tests {
        \\    use super::State;
        \\
        \\    #[test]
        \\    fn state_body_is_lossless() {
        \\        let mut value = 7;
        \\        let State(inner) = State(value);
        \\        value = if true { inner } else { 3 };
        \\    }
        \\}
    ;

    const rust_ir = try analyzeSource(allocator, "pre_p4", "2021", src);
    const helpers = struct {
        fn findEntity(
            rust_ir_: *const ir.RustIr,
            kind: spine.EntityKind,
            name: []const u8,
        ) ?spine.Entity {
            for (rust_ir_.graph.symbol_table.entities.items) |entity| {
                if (entity.kind != kind) continue;
                if (std.mem.eql(u8, entity.name, name)) return entity;
            }
            return null;
        }

        fn findModule(rust_ir_: *const ir.RustIr, name: []const u8) ?graph.Module {
            for (rust_ir_.graph.modules.items) |module| {
                if (std.mem.eql(u8, module.name, name)) return module;
            }
            return null;
        }

        fn hasAttribute(
            attributes: []const spine.Attribute,
            name: []const u8,
            meta_fragment: []const u8,
        ) bool {
            for (attributes) |attribute| {
                if (!std.mem.eql(u8, attribute.name, name)) continue;
                if (meta_fragment.len == 0) return true;
                if (std.mem.indexOf(u8, attribute.meta, meta_fragment) != null) return true;
            }
            return false;
        }
    };

    const state_module = helpers.findEntity(&rust_ir, .module, "state");
    try std.testing.expect(state_module != null);
    const state_module_entity = state_module.?;
    try std.testing.expect(state_module_entity.visibility == .private);
    try std.testing.expectEqual(@as(?spine.EntityId, 0), state_module_entity.parent);

    const state_entity = helpers.findEntity(&rust_ir, .struct_, "State");
    try std.testing.expect(state_entity != null);
    const state = state_entity.?;
    try std.testing.expect(state.visibility == .public);
    try std.testing.expectEqual(@as(?spine.EntityId, state_module_entity.id), state.parent);
    try std.testing.expect(state.id < rust_ir.bodies.bodies.len);
    try std.testing.expect(rust_ir.bodies.bodies[state.id] == .struct_);
    const state_body = rust_ir.bodies.bodies[state.id].struct_;
    try std.testing.expect(state_body.layout == .tuple);
    try std.testing.expectEqual(@as(usize, 1), state_body.fields.len);
    try std.testing.expectEqualStrings("0", state_body.fields[0].name);
    try std.testing.expect(state_body.fields[0].ty == .prim);
    try std.testing.expect(state_body.fields[0].ty.prim == .u8);

    const inspect_entity = helpers.findEntity(&rust_ir, .trait_, "Inspect");
    try std.testing.expect(inspect_entity != null);
    const inspect = inspect_entity.?;
    try std.testing.expect(inspect.visibility == .public);
    try std.testing.expectEqual(@as(?spine.EntityId, state_module_entity.id), inspect.parent);
    try std.testing.expect(inspect.id < rust_ir.bodies.bodies.len);
    try std.testing.expect(rust_ir.bodies.bodies[inspect.id] == .trait_);
    const inspect_body = rust_ir.bodies.bodies[inspect.id].trait_;
    try std.testing.expectEqual(@as(usize, 1), inspect_body.methods.len);
    try std.testing.expectEqualStrings("value", inspect_body.methods[0].name);
    try std.testing.expect(inspect_body.methods[0].receiver == .ref_);
    try std.testing.expect(inspect_body.methods[0].ret == .prim);
    try std.testing.expect(inspect_body.methods[0].ret.prim == .u8);

    const initial_entity = helpers.findEntity(&rust_ir, .fn_, "initial");
    try std.testing.expect(initial_entity != null);
    const initial = initial_entity.?;
    try std.testing.expect(initial.visibility == .public);
    try std.testing.expectEqual(@as(?spine.EntityId, state_module_entity.id), initial.parent);
    try std.testing.expect(initial.id < rust_ir.bodies.bodies.len);
    try std.testing.expect(rust_ir.bodies.bodies[initial.id] == .fn_);

    var state_reexport: ?graph.UseDecl = null;
    for (rust_ir.graph.uses.items) |use_decl| {
        if (!use_decl.is_pub_export) continue;
        if (!std.mem.eql(u8, use_decl.local_name, "State")) continue;
        state_reexport = use_decl;
        break;
    }
    try std.testing.expect(state_reexport != null);
    const reexport = state_reexport.?;
    try std.testing.expectEqual(state.id, reexport.target);
    try std.testing.expect(reexport.kind == .plain);
    try std.testing.expectEqual(state.id, reexport.kind.plain);
    const reexport_entity = rust_ir.graph.symbol_table.get(reexport.id);
    try std.testing.expect(reexport_entity != null);
    try std.testing.expect(reexport_entity.?.visibility == .public);
    try std.testing.expectEqual(@as(?spine.EntityId, 0), reexport_entity.?.parent);

    const tests_module = helpers.findEntity(&rust_ir, .module, "tests");
    try std.testing.expect(tests_module != null);
    const tests_module_entity = tests_module.?;
    try std.testing.expect(tests_module_entity.visibility == .private);
    try std.testing.expectEqual(@as(usize, 0), tests_module_entity.attributes.len);
    const tests_module_row = helpers.findModule(&rust_ir, "tests");
    try std.testing.expect(tests_module_row != null);
    try std.testing.expectEqual(@as(usize, 0), tests_module_row.?.attributes.len);

    const test_entity = helpers.findEntity(&rust_ir, .fn_, "state_body_is_lossless");
    try std.testing.expect(test_entity != null);
    const test_fn = test_entity.?;
    try std.testing.expect(test_fn.visibility == .private);
    try std.testing.expectEqual(@as(?spine.EntityId, tests_module_entity.id), test_fn.parent);
    try std.testing.expect(helpers.hasAttribute(test_fn.attributes, "test", ""));
    try std.testing.expect(test_fn.id < rust_ir.bodies.bodies.len);
    try std.testing.expect(rust_ir.bodies.bodies[test_fn.id] == .fn_);

    const test_body = rust_ir.bodies.bodies[test_fn.id].fn_;
    try std.testing.expect(test_body.body < rust_ir.bodies.exprs.len);
    const body_expression = rust_ir.bodies.exprs[test_body.body];
    try std.testing.expect(body_expression.kind == .block);
    const body_block = body_expression.kind.block;
    try std.testing.expectEqual(@as(usize, 3), body_block.statements.len);
    try std.testing.expect(body_block.tail == null);

    const mutable_statement = rust_ir.bodies.stmts[body_block.statements[0]];
    try std.testing.expect(mutable_statement.kind == .let);
    const mutable_let = mutable_statement.kind.let;
    const mutable_pattern = rust_ir.bodies.pats[mutable_let.pattern];
    try std.testing.expect(mutable_pattern.kind == .binding);
    try std.testing.expectEqualStrings("value", mutable_pattern.kind.binding.name);
    try std.testing.expect(mutable_pattern.kind.binding.mutable);
    try std.testing.expect(mutable_let.init != null);
    const seven = rust_ir.bodies.exprs[mutable_let.init.?];
    try std.testing.expect(seven.kind == .literal);
    try std.testing.expect(seven.kind.literal == .int);
    try std.testing.expectEqual(@as(i128, 7), seven.kind.literal.int.value);

    const destructure_statement = rust_ir.bodies.stmts[body_block.statements[1]];
    try std.testing.expect(destructure_statement.kind == .let);
    const destructure_let = destructure_statement.kind.let;
    const destructure_pattern = rust_ir.bodies.pats[destructure_let.pattern];
    try std.testing.expect(destructure_pattern.kind == .struct_pat);
    const tuple_pattern = destructure_pattern.kind.struct_pat;
    try std.testing.expectEqual(state.id, tuple_pattern.def);
    try std.testing.expectEqual(@as(usize, 1), tuple_pattern.fields.len);
    try std.testing.expectEqualStrings("0", tuple_pattern.fields[0].field);
    try std.testing.expect(tuple_pattern.fields[0].pat != null);
    const inner_pattern = rust_ir.bodies.pats[tuple_pattern.fields[0].pat.?];
    try std.testing.expect(inner_pattern.kind == .binding);
    try std.testing.expectEqualStrings("inner", inner_pattern.kind.binding.name);
    try std.testing.expect(!inner_pattern.kind.binding.mutable);

    try std.testing.expect(destructure_let.init != null);
    const constructor = rust_ir.bodies.exprs[destructure_let.init.?];
    try std.testing.expect(constructor.kind == .call);
    try std.testing.expect(constructor.kind.call.call_kind == .constructor);
    try std.testing.expectEqual(state.id, constructor.kind.call.call_kind.constructor);
    try std.testing.expectEqual(@as(usize, 1), constructor.kind.call.args.len);
    const constructor_arg = rust_ir.bodies.exprs[constructor.kind.call.args[0]];
    try std.testing.expect(constructor_arg.kind == .path);

    const assignment_statement = rust_ir.bodies.stmts[body_block.statements[2]];
    try std.testing.expect(assignment_statement.kind == .expr);
    const assignment = rust_ir.bodies.exprs[assignment_statement.kind.expr];
    try std.testing.expect(assignment.kind == .assign);
    try std.testing.expect(assignment.kind.assign.op == .plain);
    try std.testing.expect(rust_ir.bodies.exprs[assignment.kind.assign.target].kind == .path);
    const conditional = rust_ir.bodies.exprs[assignment.kind.assign.value];
    try std.testing.expect(conditional.kind == .if_else);
    const if_else = conditional.kind.if_else;
    const condition = rust_ir.bodies.exprs[if_else.cond];
    try std.testing.expect(condition.kind == .literal);
    try std.testing.expect(condition.kind.literal == .boolean);
    try std.testing.expect(condition.kind.literal.boolean);
    try std.testing.expect(if_else.then_.tail != null);
    try std.testing.expectEqual(@as(usize, 0), if_else.then_.statements.len);
    try std.testing.expect(rust_ir.bodies.exprs[if_else.then_.tail.?].kind == .path);
    try std.testing.expect(if_else.@"else" == .block);
    const else_block = if_else.@"else".block;
    try std.testing.expect(else_block.tail != null);
    try std.testing.expectEqual(@as(usize, 0), else_block.statements.len);
    const three = rust_ir.bodies.exprs[else_block.tail.?];
    try std.testing.expect(three.kind == .literal);
    try std.testing.expect(three.kind.literal == .int);
    try std.testing.expectEqual(@as(i128, 3), three.kind.literal.int.value);

    const body_expression_ids = [_]exprs.NodeId{
        test_body.body,
        mutable_let.init.?,
        destructure_let.init.?,
        constructor.kind.call.args[0],
        assignment_statement.kind.expr,
        assignment.kind.assign.target,
        assignment.kind.assign.value,
        if_else.cond,
        if_else.then_.tail.?,
        else_block.tail.?,
    };
    for (body_expression_ids) |expression_id| {
        try std.testing.expect(expression_id < rust_ir.bodies.exprs.len);
        try std.testing.expect(rust_ir.bodies.exprs[expression_id].kind != .unsupported);
    }
}

test "analyzeSource fills test body with literal built-in macros" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const src =
        \\mod tests {
        \\    #[test]
        \\    fn literal_macros_fill() {
        \\        assert_eq!(1 + 1, 2);
        \\        let values = vec![1, 2, 3];
        \\        let repeated = vec![0xff; 4];
        \\        panic!("expected");
        \\    }
        \\}
    ;

    const rust_ir = try analyzeSource(allocator, "literal_macros", "2021", src);

    var test_entity: ?spine.Entity = null;
    for (rust_ir.graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .fn_ and std.mem.eql(u8, entity.name, "literal_macros_fill")) {
            test_entity = entity;
            break;
        }
    }
    const test_fn = test_entity orelse return error.TestUnexpectedResult;
    try std.testing.expect(test_fn.id < rust_ir.bodies.bodies.len);
    const test_body = switch (rust_ir.bodies.bodies[test_fn.id]) {
        .fn_ => |fn_body| fn_body,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(test_body.body < rust_ir.bodies.exprs.len);
    const root_block = switch (rust_ir.bodies.exprs[test_body.body].kind) {
        .block => |block| block,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(root_block.statements.len > 0);
    try std.testing.expectEqual(@as(usize, 4), root_block.statements.len);

    const assert_eq_statement = rust_ir.bodies.stmts[root_block.statements[0]];
    const assert_eq_expression = switch (assert_eq_statement.kind) {
        .expr => |expression| rust_ir.bodies.exprs[expression],
        else => return error.TestUnexpectedResult,
    };
    const assert_eq_marker = switch (assert_eq_expression.kind) {
        .unsupported => |unsupported| unsupported.reason,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.startsWith(u8, assert_eq_marker, "assertion:"));
    const assert_eq_condition_id = try std.fmt.parseInt(
        exprs.NodeId,
        assert_eq_marker["assertion:".len..],
        10,
    );
    try std.testing.expect(assert_eq_condition_id < rust_ir.bodies.exprs.len);
    const assert_eq_condition = rust_ir.bodies.exprs[assert_eq_condition_id];
    try std.testing.expect(assert_eq_condition.kind == .binary);
    try std.testing.expect(assert_eq_condition.kind.binary.op == .eq);

    var sum_id: ?exprs.NodeId = null;
    for (rust_ir.bodies.exprs, 0..) |candidate, candidate_index| {
        const binary = switch (candidate.kind) {
            .binary => |binary| binary,
            else => continue,
        };
        if (binary.op != .add) continue;

        try std.testing.expect(sum_id == null);
        sum_id = @intCast(candidate_index);
    }
    const sum = rust_ir.bodies.exprs[sum_id orelse return error.TestUnexpectedResult];
    try std.testing.expect(sum.kind == .binary);
    try std.testing.expect(sum.kind.binary.op == .add);

    const values_statement = rust_ir.bodies.stmts[root_block.statements[1]];
    const values_let = switch (values_statement.kind) {
        .let => |let_statement| let_statement,
        else => return error.TestUnexpectedResult,
    };
    const values_init = values_let.init orelse return error.TestUnexpectedResult;
    const values_vec = switch (rust_ir.bodies.exprs[values_init].kind) {
        .vec_lit => |vec_lit| vec_lit,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(values_vec.repeat == null);
    try std.testing.expectEqual(@as(usize, 3), values_vec.elements.len);
    for (values_vec.elements, 1..) |element_id, expected| {
        const element = rust_ir.bodies.exprs[element_id];
        try std.testing.expect(element.kind == .literal);
        try std.testing.expect(element.kind.literal == .int);
        try std.testing.expectEqual(@as(i128, @intCast(expected)), element.kind.literal.int.value);
    }

    const repeated_statement = rust_ir.bodies.stmts[root_block.statements[2]];
    const repeated_let = switch (repeated_statement.kind) {
        .let => |let_statement| let_statement,
        else => return error.TestUnexpectedResult,
    };
    const repeated_init = repeated_let.init orelse return error.TestUnexpectedResult;
    const repeated_vec = switch (rust_ir.bodies.exprs[repeated_init].kind) {
        .vec_lit => |vec_lit| vec_lit,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        @as(u64, 4),
        (repeated_vec.repeat orelse return error.TestUnexpectedResult).literal,
    );
    try std.testing.expectEqual(@as(usize, 1), repeated_vec.elements.len);
    const repeated_element = rust_ir.bodies.exprs[repeated_vec.elements[0]];
    try std.testing.expect(repeated_element.kind == .literal);
    try std.testing.expect(repeated_element.kind.literal == .int);
    try std.testing.expectEqual(@as(i128, 0xff), repeated_element.kind.literal.int.value);

    const panic_statement = rust_ir.bodies.stmts[root_block.statements[3]];
    const panic_expression = switch (panic_statement.kind) {
        .expr => |expression| rust_ir.bodies.exprs[expression],
        else => return error.TestUnexpectedResult,
    };
    const panic_value = switch (panic_expression.kind) {
        .panic_ => |panic| panic,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("panic: expected", panic_value.message);
    const panic_type_id = panic_expression.ty orelse return error.TestUnexpectedResult;
    const panic_type = rust_ir.bodies.types[panic_type_id];
    switch (panic_type) {
        .prim => |primitive| try std.testing.expectEqual(types.Prim.never, primitive),
        else => return error.TestUnexpectedResult,
    }
}
test "analyzeSource exposes bound declaration paths before inference" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const source =
        \\pub struct Shape {}
        \\pub struct Point {
        \\    shape: crate::Shape,
        \\}
    ;
    const rust_ir = try analyzeSource(allocator, "declaration_paths", "2021", source);

    var shape_id: ?spine.EntityId = null;
    var point_id: ?spine.EntityId = null;
    for (rust_ir.graph.symbol_table.entities.items) |entity| {
        if (entity.kind != .struct_) continue;
        if (std.mem.eql(u8, entity.name, "Shape")) shape_id = entity.id;
        if (std.mem.eql(u8, entity.name, "Point")) point_id = entity.id;
    }
    const shape = shape_id orelse return error.TestUnexpectedResult;
    const point = point_id orelse return error.TestUnexpectedResult;
    const point_body = switch (rust_ir.bodies.bodies[point]) {
        .struct_ => |body| body,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), point_body.fields.len);
    const path = switch (point_body.fields[0].ty) {
        .path => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 2), path.segments.len);
    try std.testing.expectEqual(shape, path.segments[1].id.?);
}

test "analyzeSource rejects unresolved declaration paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source = "pub struct Point { shape: Missing }";
    try std.testing.expectError(
        error.UnresolvedNominalType,
        analyzeSource(allocator, "unresolved_declaration_path", "2021", source),
    );
}
test "analyzeSource lowers FNV dereference scalar cast" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const source =
        \\pub fn hash_byte(bytes: &[u8]) -> u64 {
        \\    for byte in bytes.iter() {
        \\        return *byte as u64;
        \\    }
        \\    0u64
        \\}
    ;
    const rust_ir = try analyzeSource(allocator, "fnv_cast", "2021", source);

    var found_cast = false;
    for (rust_ir.bodies.exprs) |expression| {
        if (expression.kind != .cast) continue;
        const cast = expression.kind.cast;
        try std.testing.expectEqual(cast.source_type, types.Type{ .prim = .u8 });
        try std.testing.expectEqual(cast.target, expression.ty.?);
        try std.testing.expect(cast.operand < rust_ir.bodies.exprs.len);
        try std.testing.expectEqual(
            types.Type{ .prim = .u64 },
            rust_ir.bodies.types[cast.target],
        );
        switch (rust_ir.bodies.exprs[cast.operand].kind) {
            .unary => |unary| try std.testing.expect(unary.op == .deref),
            else => return error.ExpectedDereferenceOperand,
        }
        found_cast = true;
    }
    try std.testing.expect(found_cast);
}

test "analyzeSource keeps cast operand types through source expressions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const source =
        \\use core::slice;
        \\
        \\pub unsafe fn cast_sources(
        \\    bytes: &[u8],
        \\    iter: &mut slice::Iter<'_, u8>,
        \\    offset: usize,
        \\    value: i64,
        \\) -> Option<char> {
        \\    let ptr = bytes.as_ptr();
        \\    let _wide = ptr as *const u16;
        \\    let _advanced = bytes.as_ptr().add(offset) as *const u16;
        \\    let n = if value >= 0 {
        \\        value as u64
        \\    } else {
        \\        (!(value as u64)).wrapping_add(1)
        \\    };
        \\    let _signed = n as isize;
        \\    let mut cloned_iter = iter.clone();
        \\    let decoded = char::from(*cloned_iter.next()?);
        \\    bytes.iter().next().map(|byte| {
        \\        let _index = (byte >> 4) as usize;
        \\        decoded
        \\    })
        \\}
    ;
    const rust_ir = try analyzeSource(allocator, "cast_source_flow", "2021", source);

    var binary_source = false;
    var local_integer_source = false;
    var local_pointer_source = false;
    var method_pointer_source = false;
    var unary_source = false;
    for (rust_ir.bodies.exprs) |expression| {
        const cast = switch (expression.kind) {
            .cast => |value| value,
            else => continue,
        };
        switch (rust_ir.bodies.exprs[cast.operand].kind) {
            .binary => binary_source = cast.source_type == .prim and cast.source_type.prim == .u8,
            .path => switch (rust_ir.bodies.types[cast.target]) {
                .prim => |primitive| {
                    if (primitive == .isize) {
                        local_integer_source =
                            cast.source_type == .prim and cast.source_type.prim == .u64;
                    }
                },
                .raw_ptr => local_pointer_source = cast.source_type == .raw_ptr,
                else => {},
            },
            .method_call => method_pointer_source = cast.source_type == .raw_ptr,
            .unary => unary_source =
                cast.kind == .primitive_from and
                cast.source_type == .prim and
                cast.source_type.prim == .u8,
            else => {},
        }
    }
    try std.testing.expect(binary_source);
    try std.testing.expect(local_integer_source);
    try std.testing.expect(local_pointer_source);
    try std.testing.expect(method_pointer_source);
    try std.testing.expect(unary_source);
}

test "analyzeSource propagates allocation effects through resolved free calls" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const source =
        \\#[cfg(test)]
        \\#[test]
        \\fn repeat_bytes_assert_test(bytes: &[u8]) {
        \\    assert!(repeat_bytes_transitive(bytes));
        \\}
        \\
        \\#[cfg(test)]
        \\#[test]
        \\fn repeat_bytes_assert_eq_test(bytes: &[u8]) {
        \\    assert_eq!(repeat_bytes_transitive(bytes), repeat_bytes_transitive(bytes));
        \\}
        \\
        \\#[cfg(test)]
        \\#[test]
        \\fn direct_collection_assertion(bytes: &[u8]) {
        \\    assert!((0..4).flat_map(|_| bytes.iter().cloned()).collect());
        \\}
        \\
        \\#[cfg(test)]
        \\#[test]
        \\fn invalid_assertions() {
        \\    assert!();
        \\    assert_eq!();
        \\    panic!("ordinary unsupported");
        \\}
        \\
        \\fn repeat_bytes_transitive(bytes: &[u8]) {
        \\    repeat_bytes_caller(bytes);
        \\}
        \\
        \\fn repeat_bytes_caller(bytes: &[u8]) {
        \\    repeat_bytes(bytes);
        \\}
        \\
        \\fn repeat_bytes(bytes: &[u8]) {
        \\    (0..4).flat_map(|_| bytes.iter().cloned()).collect()
        \\}
        \\
        \\fn collect_nothing() {}
    ;
    const rust_ir = try analyzeSourceWithOptions(
        allocator,
        "free_collection_effect",
        "2021",
        source,
        .{ .include_tests = true },
    );

    var producer_effect: ?bool = null;
    var direct_caller_effect: ?bool = null;
    var transitive_caller_effect: ?bool = null;
    var assert_test_effect: ?bool = null;
    var assert_eq_test_effect: ?bool = null;
    var invalid_assertion_effect: ?bool = null;
    var direct_assertion_effect: ?bool = null;
    var ordinary_effect: ?bool = null;
    for (rust_ir.graph.symbol_table.entities.items) |entity| {
        if (entity.kind != .fn_) continue;
        const function_body = switch (rust_ir.bodies.bodies[entity.id]) {
            .fn_ => |body| body,
            else => return error.TestUnexpectedResult,
        };
        if (std.mem.eql(u8, entity.name, "repeat_bytes")) {
            producer_effect = function_body.is_allocating;
        } else if (std.mem.eql(u8, entity.name, "repeat_bytes_caller")) {
            direct_caller_effect = function_body.is_allocating;
        } else if (std.mem.eql(u8, entity.name, "repeat_bytes_transitive")) {
            transitive_caller_effect = function_body.is_allocating;
        } else if (std.mem.eql(u8, entity.name, "repeat_bytes_assert_test")) {
            assert_test_effect = function_body.is_allocating;
        } else if (std.mem.eql(u8, entity.name, "repeat_bytes_assert_eq_test")) {
            assert_eq_test_effect = function_body.is_allocating;
        } else if (std.mem.eql(u8, entity.name, "direct_collection_assertion")) {
            direct_assertion_effect = function_body.is_allocating;
        } else if (std.mem.eql(u8, entity.name, "invalid_assertions")) {
            invalid_assertion_effect = function_body.is_allocating;
        } else if (std.mem.eql(u8, entity.name, "collect_nothing")) {
            ordinary_effect = function_body.is_allocating;
        }
    }

    try std.testing.expect(producer_effect orelse return error.TestUnexpectedResult);
    try std.testing.expect(direct_caller_effect orelse return error.TestUnexpectedResult);
    try std.testing.expect(transitive_caller_effect orelse return error.TestUnexpectedResult);
    try std.testing.expect(assert_test_effect orelse return error.TestUnexpectedResult);
    try std.testing.expect(assert_eq_test_effect orelse return error.TestUnexpectedResult);
    try std.testing.expect(direct_assertion_effect orelse return error.TestUnexpectedResult);
    try std.testing.expect(!(invalid_assertion_effect orelse return error.TestUnexpectedResult));
    try std.testing.expect(!(ordinary_effect orelse return error.TestUnexpectedResult));
}

test "analyzeSource propagates allocation effects through resolved struct methods" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const source =
        \\struct Collector {}
        \\
        \\impl Collector {
        \\    fn repeat_again(&self, other: &Collector, bytes: &[u8]) {
        \\        other.repeat(bytes);
        \\    }
        \\
        \\    fn repeat_associated(other: &Collector, bytes: &[u8]) {
        \\        Collector::repeat(other, bytes);
        \\    }
        \\
        \\    fn repeat(&self, bytes: &[u8]) {
        \\        (0..4).flat_map(|_| bytes.iter().cloned()).collect()
        \\    }
        \\
        \\    fn collect_nothing(&self) {}
        \\}
    ;
    const rust_ir = try analyzeSource(allocator, "method_collection_effect", "2021", source);

    var collector_id: ?spine.EntityId = null;
    for (rust_ir.graph.symbol_table.entities.items) |entity| {
        if (entity.kind != .struct_) continue;
        if (std.mem.eql(u8, entity.name, "Collector")) collector_id = entity.id;
    }
    const collector_body = switch (rust_ir.bodies.bodies[collector_id orelse return error.TestUnexpectedResult]) {
        .struct_ => |body| body,
        else => return error.TestUnexpectedResult,
    };

    var producer_effect: ?bool = null;
    var method_caller_effect: ?bool = null;
    var associated_caller_effect: ?bool = null;
    var ordinary_effect: ?bool = null;
    for (collector_body.methods) |method| {
        if (std.mem.eql(u8, method.name, "repeat")) {
            producer_effect = method.is_allocating;
        } else if (std.mem.eql(u8, method.name, "repeat_again")) {
            method_caller_effect = method.is_allocating;
        } else if (std.mem.eql(u8, method.name, "repeat_associated")) {
            associated_caller_effect = method.is_allocating;
        } else if (std.mem.eql(u8, method.name, "collect_nothing")) {
            ordinary_effect = method.is_allocating;
        }
    }

    try std.testing.expect(producer_effect orelse return error.TestUnexpectedResult);
    try std.testing.expect(method_caller_effect orelse return error.TestUnexpectedResult);
    try std.testing.expect(associated_caller_effect orelse return error.TestUnexpectedResult);
    try std.testing.expect(!(ordinary_effect orelse return error.TestUnexpectedResult));
}

test "byte match patterns retain their numeric value and width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try analyzeSource(arena.allocator(), "byte_pattern", "2021",
        \\pub fn classify(value: u8) -> u8 {
        \\    match value { b'0' => 1u8, _ => 0u8 }
        \\}
    );
    for (result.bodies.pats) |pattern| {
        if (pattern.kind != .literal) continue;
        const literal = pattern.kind.literal;
        try std.testing.expect(literal == .int);
        try std.testing.expectEqual(@as(i128, 48), literal.int.value);
        try std.testing.expectEqualStrings("u8", literal.int.ty_suffix.?);
        return;
    }
    return error.MissingBytePattern;
}

test "analyzeSource preserves a trailing formatting macro as the block value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\pub fn render(f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        \\    write!(f, "ready")
        \\    // The comment must not turn the value into a statement.
        \\}
    ;
    const rust_ir = try analyzeSource(arena.allocator(), "macro_tail", "2021", source);
    for (rust_ir.graph.symbol_table.entities.items) |entity| {
        if (entity.kind != .fn_ or !std.mem.eql(u8, entity.name, "render")) continue;
        const function = rust_ir.bodies.bodies[entity.id].fn_;
        const block = rust_ir.bodies.exprs[function.body].kind.block;
        const tail = block.tail orelse return error.MissingMacroTail;
        try std.testing.expectEqual(.format_write, std.meta.activeTag(rust_ir.bodies.exprs[tail].kind));
        return;
    }
    return error.MissingRenderFunction;
}

test "generic conversion results remain dispatchable in their declaration scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try analyzeSource(arena.allocator(), "generic_result", "2021",
        \\pub fn narrow<T: core::convert::TryInto<u8>>(value: T) -> Option<u8> {
        \\    value.try_into().ok()
        \\}
    );
    try ir.validateForTranslation(&result);
}

test "analyzeCrate enables the manifest default feature closure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(
        allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path },
    );
    // `gated` is the crate's only item, and it sits behind `gated`, which the
    // manifest enables by default. `default` also pulls in `extra` through
    // one hop, so the closure has to be followed rather than read off the
    // `default` list alone.
    try writeTestFile(
        allocator,
        io,
        root,
        "Cargo.toml",
        \\[package]
        \\name = "gated_crate"
        \\edition = "2021"
        \\
        \\[features]
        \\default = ["gated", "extra"]
        \\gated = ["shared"]
        \\shared = []
        \\extra = ["shared"]
        ,
    );
    try writeTestFile(allocator, io, root, "src/lib.rs",
        \\#[cfg(feature = "gated")]
        \\pub fn gated() -> u8 { 1 }
    );

    const defaults = try analyzeCrate(allocator, io, root);
    const overridden = try analyzeCrateWithOptions(allocator, io, root, .{
        .cfg = .{ .features = &.{"extra"} },
    });

    const find = struct {
        fn fnEntity(rust_ir_: *const ir.RustIr, name_: []const u8) ?spine.Entity {
            for (rust_ir_.graph.symbol_table.entities.items) |entity| {
                if (entity.kind != .fn_) continue;
                if (std.mem.eql(u8, entity.name, name_)) return entity;
            }
            return null;
        }
    }.fnEntity;

    const gated = find(&defaults, "gated") orelse return error.MissingGatedFunction;
    try std.testing.expect(gated.id < defaults.bodies.bodies.len);
    const function_body = switch (defaults.bodies.bodies[gated.id]) {
        .fn_ => |body| body,
        else => return error.MissingGatedBody,
    };
    try std.testing.expect(function_body.body < defaults.bodies.exprs.len);
    const block = switch (defaults.bodies.exprs[function_body.body].kind) {
        .block => |value| value,
        else => return error.MissingGatedBlock,
    };
    // `{ 1 }` is a tail expression, so a lowered body carries the literal as
    // the block's value rather than as a statement.
    const tail = block.tail orelse return error.MissingGatedValue;
    const literal = switch (defaults.bodies.exprs[tail].kind) {
        .literal => |value| value,
        else => return error.MissingGatedLiteral,
    };
    const integer = switch (literal) {
        .int => |value| value,
        else => return error.MissingGatedLiteral,
    };
    try std.testing.expectEqual(@as(i128, 1), integer.value);

    // A caller-supplied selection replaces the manifest default, so the same
    // item drops back out when `gated` is not among the requested features.
    try std.testing.expect(find(&overridden, "gated") == null);
}

test "analyzeCrate: an optional dependency behind an inactive feature is not a dependency" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // adler's own manifest (test/crates/adler/Cargo.toml:50-64) declares two
    // optional dependencies — `compiler_builtins`, and `core` under the package
    // `rustc-std-workspace-core` — and its default closure is `std` alone, so a
    // plain build has neither. Recording them anyway is what made the backend
    // refuse the crate for two crates its source never names: `src/lib.rs`
    // reaches `crate::`, `std::` and nothing else.
    const defaulted = try analyzeCrate(allocator, std.testing.io, "test/crates/adler");
    try std.testing.expectEqual(@as(usize, 1), defaulted.graph.crates.items.len);
    try std.testing.expectEqual(@as(usize, 0), defaulted.graph.crates.items[0].deps.len);

    const manifest = try ingest.loadCrateManifest(allocator, std.testing.io, "test/crates/adler");
    // Two, not three: `criterion` is a dev-dependency and never reaches
    // `graph.Crate.deps`.
    try std.testing.expectEqual(@as(usize, 2), manifest.dependencies.len);

    // `rustc-dep-of-std = ["core", "compiler_builtins"]` names both implicit
    // features and expands to nothing further, so its transitive closure is
    // exactly these two names. Handed over as a completed closure, both
    // optional dependencies are dependencies again, numbered densely from one
    // because `CrateGraph.validateTopology` requires id == position + 1.
    const rustc_dep_of_std = try manifestDependencies(allocator, manifest.dependencies, .{
        .features = manifest.features,
        .active = &.{ "core", "compiler_builtins" },
        .complete = true,
    });
    try std.testing.expectEqual(@as(usize, 2), rustc_dep_of_std.len);
    try std.testing.expectEqualStrings("compiler_builtins", rustc_dep_of_std[0].local_alias);
    try std.testing.expectEqualStrings("compiler_builtins", rustc_dep_of_std[0].extern_name);
    try std.testing.expectEqual(@as(u32, 1), rustc_dep_of_std[0].id);
    try std.testing.expectEqualStrings("core", rustc_dep_of_std[1].local_alias);
    try std.testing.expectEqualStrings("rustc-std-workspace-core", rustc_dep_of_std[1].extern_name);
    try std.testing.expectEqual(@as(u32, 2), rustc_dep_of_std[1].id);

    // A caller's feature list replaces the manifest default and reaches this
    // function exactly as written, so it may name a feature whose own members
    // are what enable a dependency. An incomplete selection therefore keeps
    // every optional dependency rather than concluding from what it leaves out.
    const unexpanded_selection = try manifestDependencies(allocator, manifest.dependencies, .{
        .features = manifest.features,
        .active = &.{"std"},
        .complete = false,
    });
    try std.testing.expectEqual(@as(usize, 2), unexpanded_selection.len);
}

test "a dependency's resolved feature set is called empty only when no forward reaches it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // atoi's own manifest (test/crates/atoi/Cargo.toml:30-38) declares
    // `num-traits = { version = "0.2.14", default-features = false }` with no
    // `features` key at all, and its `std = ["num-traits/std"]` forwards one.
    // The declared list is empty, so only the forward edge stands between this
    // dependency and a certainly-empty resolved set — and it is there.
    const atoi = try ingest.loadCrateManifest(allocator, std.testing.io, "test/crates/atoi");
    const atoi_deps = try manifestDependencies(allocator, atoi.dependencies, .{
        .features = atoi.features,
        .active = try ingest.defaultFeatureClosure(allocator, atoi.features),
        .complete = true,
    });
    try std.testing.expectEqual(@as(usize, 1), atoi_deps.len);
    try std.testing.expectEqualStrings("num-traits", atoi_deps[0].local_alias);
    try std.testing.expectEqual(@as(?bool, false), atoi_deps[0].default_features);
    try std.testing.expectEqual(@as(usize, 0), atoi_deps[0].features.len);
    try std.testing.expect(!atoi_deps[0].resolved_features_known_empty);

    // wyhash's own manifest declares `rand_core = { version = "0.5" }` and has
    // no `[features]` table at all, so nothing forwards and nothing was turned
    // off: this build's resolved set for it is certainly empty. This is the
    // record the backend's omission rule asks about, so the flag landing here
    // is what lets that rule answer instead of refusing.
    const wyhash = try ingest.loadCrateManifest(allocator, std.testing.io, "test/crates/wyhash");
    const wyhash_deps = try manifestDependencies(allocator, wyhash.dependencies, .{
        .features = wyhash.features,
        .active = try ingest.defaultFeatureClosure(allocator, wyhash.features),
        .complete = true,
    });
    try std.testing.expectEqual(@as(usize, 1), wyhash_deps.len);
    try std.testing.expectEqualStrings("rand_core", wyhash_deps[0].local_alias);
    try std.testing.expectEqual(@as(?bool, null), wyhash_deps[0].default_features);
    try std.testing.expect(wyhash_deps[0].resolved_features_known_empty);

    // The forward alone is enough to withhold the answer. Both dependencies
    // here leave the defaults on and declare no features, and the only
    // difference between them is that one feature reaches one of them — so
    // without this case atoi's `false` would be equally explained by its
    // `default-features = false`, and the forward would never be shown to run.
    const mixed = try ingest.parseManifestContent(allocator,
        \\[package]
        \\name = "mixed"
        \\version = "1.0"
        \\
        \\[dependencies.forwarded_dep]
        \\version = "1"
        \\[dependencies.plain_dep]
        \\version = "1"
        \\
        \\[features]
        \\default = ["std"]
        \\std = ["forwarded_dep/std"]
    );
    const mixed_active = try ingest.defaultFeatureClosure(allocator, mixed.features);
    const mixed_deps = try manifestDependencies(allocator, mixed.dependencies, .{
        .features = mixed.features,
        .active = mixed_active,
        .complete = true,
    });
    try std.testing.expectEqual(@as(usize, 2), mixed_deps.len);
    try std.testing.expectEqualStrings("forwarded_dep", mixed_deps[0].local_alias);
    try std.testing.expect(!mixed_deps[0].resolved_features_known_empty);
    try std.testing.expectEqualStrings("plain_dep", mixed_deps[1].local_alias);
    try std.testing.expect(mixed_deps[1].resolved_features_known_empty);

    // An under-expanded selection answers nothing at all, so it answers this
    // nothing either — even for the dependency nothing forwards.
    const unanswered = try manifestDependencies(allocator, mixed.dependencies, .{
        .features = mixed.features,
        .active = mixed_active,
        .complete = false,
    });
    try std.testing.expectEqual(@as(usize, 2), unanswered.len);
    try std.testing.expect(!unanswered[0].resolved_features_known_empty);
    try std.testing.expect(!unanswered[1].resolved_features_known_empty);
}

test "keys solves the tuple it returns from nested field reads" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // `(self.0.k0, self.0.k1)` names no element type where the literal is
    // lowered — a field read carries none of its own — so both slots open as
    // the inference placeholder and the solver owes the row their `u64`.
    // Nothing else about the pair is unusual, which is what makes it the
    // ordinary `keys()` a caller writes.
    const source =
        \\pub struct State {
        \\    k0: u64,
        \\    k1: u64,
        \\}
        \\
        \\pub struct Tagged(State);
        \\
        \\impl Tagged {
        \\    pub fn keys(&self) -> (u64, u64) {
        \\        (self.0.k0, self.0.k1)
        \\    }
        \\}
    ;

    const rust_ir = try analyzeSourceWithOptions(allocator, "tuple_row", "2021", source, .{});

    const keys = for (rust_ir.graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .fn_ and std.mem.eql(u8, entity.name, "keys")) break entity;
    } else return error.MissingKeys;
    const body = switch (rust_ir.bodies.bodies[keys.id]) {
        .fn_ => |function| function,
        else => return error.MissingKeysBody,
    };
    const literal_id = switch (rust_ir.bodies.exprs[body.body].kind) {
        .block => |block| block.tail orelse return error.MissingKeysTail,
        else => return error.MissingKeysBlock,
    };
    const literal_type_id = rust_ir.bodies.exprs[literal_id].ty orelse
        return error.UntypedTupleLiteral;
    const slots = switch (rust_ir.bodies.types[literal_type_id]) {
        .tuple => |tuple| tuple,
        else => return error.ReturnedPairIsNotATuple,
    };
    try std.testing.expectEqual(@as(usize, 2), slots.len);
    for (slots) |slot| {
        const slot_prim = switch (slot) {
            .prim => |value| value,
            else => return error.TupleSlotIsNotU64,
        };
        try std.testing.expectEqual(types.Prim.u64, slot_prim);
    }

    // Each element is a read the source named, so it carries the same `u64`
    // the row now records for its slot. An unsolved read leaves a placeholder
    // here and the slot above unsolved with it.
    const elements = switch (rust_ir.bodies.exprs[literal_id].kind) {
        .array => |array| array.elements,
        else => return error.ReturnedPairIsNotAnArray,
    };
    try std.testing.expectEqual(@as(usize, 2), elements.len);
    for (elements) |element| {
        const read_type_id = rust_ir.bodies.exprs[element].ty orelse
            return error.UntypedFieldRead;
        const read_prim = switch (rust_ir.bodies.types[read_type_id]) {
            .prim => |value| value,
            else => return error.FieldReadIsNotU64,
        };
        try std.testing.expectEqual(types.Prim.u64, read_prim);
    }
}
