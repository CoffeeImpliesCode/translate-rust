//! translate_rust.backend.zig.lower — Lowering engine from RustIr to ZigAST.
//!
//! Transforms target-agnostic semantic IR (RustIr) into a structured Zig package AST
//! (ast.Package). Handles module-to-file mapping, item translation, method hoisting
//! (injecting inherent and trait impl methods into struct/enum bodies), type mapping
//! via pluggable LoweringStrategy, and full expression/statement/pattern lowering.

const std = @import("std");
const ir = @import("translate_rust.ir");
const ast = @import("ast.zig");
const strategy = @import("../strategy.zig");
const default_strat = @import("strategies/default.zig");

/// Lower a complete Rust semantic model (RustIr) into a target-language Zig package.
pub fn lowerRustIr(
    allocator: std.mem.Allocator,
    rust_ir: *const ir.RustIr,
    custom_strat: ?*const strategy.LoweringStrategy,
) !ast.Package {
    var lowerer = Lowerer.init(allocator, rust_ir, custom_strat);
    const package = try lowerer.lowerPackage();
    return package;
}

const MethodTypeContext = struct {
    struct_name: []const u8,
    generic_params: []const ast.GenericParam,
};

const OwnedCollectionPlan = struct {
    range_start: ir.exprs.NodeId,
    range_end: ir.exprs.NodeId,
    source_name: []const u8,
    item_name: []const u8,
};
const OwnedTemporaryPlan = struct {
    return_type: ir.types.Type,
};
const ValueCaptureScope = struct {
    names: []const []const u8,
    value_name: ?[]const u8,
};
const ShadowScope = struct {
    names: []const []const u8,
    parent: ?*const ShadowScope,
};

fn allocationAssertionCondition(
    reason: []const u8,
    node_id: ir.exprs.NodeId,
    expr_count: usize,
) ?ir.exprs.NodeId {
    const prefix = "assertion:";
    if (!std.mem.startsWith(u8, reason, prefix)) return null;
    const suffix = reason[prefix.len..];
    if (suffix.len == 0) return null;
    for (suffix) |character| {
        if (character < '0' or character > '9') return null;
    }
    const condition = std.fmt.parseInt(ir.exprs.NodeId, suffix, 10) catch return null;
    if (condition >= expr_count or condition == node_id) return null;
    return condition;
}

/// Analyze allocation effects in the source body graph without lowering it.
/// The call graph is resolved in the IR, so direct free, associated, and
/// method calls can be followed before declaration order becomes observable.
const AllocationEffectScanner = struct {
    exprs: []const ir.exprs.Expr,
    stmts: []const ir.exprs.Statement,
    effects: []const bool,

    fn exprAllocates(self: *const AllocationEffectScanner, node_id: ir.exprs.NodeId) bool {
        if (@as(usize, node_id) >= self.exprs.len) return false;
        return switch (self.exprs[node_id].kind) {
            .literal, .path, .unit, .continue_ => false,
            .array => |array| self.nodeListAllocates(array.elements),
            .vec_lit => |vec| self.nodeListAllocates(vec.elements),
            .range => |range| self.exprAllocates(range.start) or self.exprAllocates(range.end),
            .block => |block| self.blockAllocates(block),
            .if_else => |if_expr| self.exprAllocates(if_expr.cond) or
                self.blockAllocates(if_expr.then_) or
                self.elseAllocates(if_expr.@"else"),
            .if_let => |if_let| self.exprAllocates(if_let.scrutinee) or
                self.blockAllocates(if_let.then_) or
                self.elseAllocates(if_let.@"else"),
            .match => |match_expr| self.matchAllocates(match_expr),
            .loop_ => |loop_expr| self.blockAllocates(loop_expr.body),
            .while_ => |while_expr| self.exprAllocates(while_expr.cond) or
                self.blockAllocates(while_expr.body),
            .for_ => |for_expr| self.exprAllocates(for_expr.iterable) or
                self.blockAllocates(for_expr.body) or
                self.iterKindAllocates(for_expr.iter_kind),
            .break_ => |break_expr| if (break_expr.value) |value|
                self.exprAllocates(value)
            else
                false,
            .call => |call| self.callTargetAllocates(call.call_kind) or
                self.nodeListAllocates(call.args),
            .method_call => |method_call| self.methodTargetAllocates(method_call.method) or
                self.exprAllocates(method_call.receiver) or
                self.nodeListAllocates(method_call.args),
            .struct_lit => |literal| self.structLiteralAllocates(literal),
            .enum_variant => |variant| self.enumVariantAllocates(variant),
            .field => |field| self.exprAllocates(field.base),
            .index => |index| self.exprAllocates(index.base) or self.exprAllocates(index.index),
            .cast => |cast| self.exprAllocates(cast.operand),
            .binary => |binary| self.exprAllocates(binary.lhs) or self.exprAllocates(binary.rhs),
            .unary => |unary| self.exprAllocates(unary.operand),
            .assign => |assign| self.exprAllocates(assign.target) or self.exprAllocates(assign.value),
            .try_ => |try_expr| self.exprAllocates(try_expr.inner),
            .return_ => |return_expr| if (return_expr.value) |value|
                self.exprAllocates(value)
            else
                false,
            .closure => |closure| self.blockAllocates(closure.body),
            .iterator_chain => |chain| self.iteratorChainAllocates(chain),
            .unsupported => |unsupported| if (allocationAssertionCondition(
                unsupported.reason,
                node_id,
                self.exprs.len,
            )) |condition|
                self.exprAllocates(condition)
            else
                false,
        };
    }

    fn nodeListAllocates(
        self: *const AllocationEffectScanner,
        node_ids: []const ir.exprs.NodeId,
    ) bool {
        for (node_ids) |node_id| {
            if (self.exprAllocates(node_id)) return true;
        }
        return false;
    }

    fn blockAllocates(self: *const AllocationEffectScanner, block: ir.exprs.BlockExpr) bool {
        for (block.statements) |statement_id| {
            if (@as(usize, statement_id) >= self.stmts.len) continue;
            if (self.statementAllocates(self.stmts[statement_id])) return true;
        }
        if (block.tail) |tail| return self.exprAllocates(tail);
        return false;
    }

    fn statementAllocates(
        self: *const AllocationEffectScanner,
        statement: ir.exprs.Statement,
    ) bool {
        return switch (statement.kind) {
            .let => |let_statement| if (let_statement.init) |init|
                self.exprAllocates(init)
            else
                false,
            .let_else => |let_else| self.exprAllocates(let_else.init) or
                self.blockAllocates(let_else.else_block),
            .expr => |expression| self.exprAllocates(expression),
            .item => false,
        };
    }

    fn elseAllocates(self: *const AllocationEffectScanner, branch: ir.exprs.ElseBranch) bool {
        return switch (branch) {
            .none => false,
            .block => |block| self.blockAllocates(block),
            .chain => |chain| self.exprAllocates(chain),
        };
    }

    fn matchAllocates(self: *const AllocationEffectScanner, match_expr: ir.exprs.MatchExpr) bool {
        if (self.exprAllocates(match_expr.scrutinee)) return true;
        for (match_expr.arms) |arm| {
            if (arm.guard) |guard| {
                if (self.exprAllocates(guard)) return true;
            }
            if (self.exprAllocates(arm.body)) return true;
        }
        return false;
    }

    fn structLiteralAllocates(
        self: *const AllocationEffectScanner,
        literal: ir.exprs.StructLit,
    ) bool {
        for (literal.fields) |field| {
            if (self.exprAllocates(field.value)) return true;
        }
        if (literal.base) |base| return self.exprAllocates(base);
        return false;
    }

    fn enumVariantAllocates(
        self: *const AllocationEffectScanner,
        variant: ir.exprs.EnumVariant,
    ) bool {
        if (self.nodeListAllocates(variant.tuple_fields)) return true;
        for (variant.named_fields) |field| {
            if (self.exprAllocates(field.value)) return true;
        }
        return false;
    }

    fn iterKindAllocates(
        self: *const AllocationEffectScanner,
        iter_kind: ir.exprs.IterKind,
    ) bool {
        return switch (iter_kind) {
            .range, .slice, .enumerate => false,
            .multi => |nodes| self.nodeListAllocates(nodes),
            .adapter => |chain| self.iteratorChainAllocates(chain),
        };
    }

    fn iteratorChainAllocates(
        self: *const AllocationEffectScanner,
        chain: ir.exprs.IteratorChainExpr,
    ) bool {
        if (chain.terminal == .collect_vec) return true;
        if (self.exprAllocates(chain.source)) return true;
        for (chain.adapters) |adapter| {
            if (self.adapterAllocates(adapter)) return true;
        }
        return false;
    }

    fn adapterAllocates(
        self: *const AllocationEffectScanner,
        adapter: ir.exprs.IteratorAdapter,
    ) bool {
        return switch (adapter) {
            .map => |map| self.blockAllocates(map.closure.body),
            .filter => |filter| self.blockAllocates(filter.closure.body),
            .flat_map => |closure| self.blockAllocates(closure.body),
            .enumerate, .range_rev, .other => false,
            .zip => |zip| self.exprAllocates(zip.other),
        };
    }

    fn callTargetAllocates(
        self: *const AllocationEffectScanner,
        call_kind: ir.exprs.CallKind,
    ) bool {
        return switch (call_kind) {
            .free => |target| self.bodyAllocates(target),
            .associated => |target| self.bodyAllocates(target),
            .constructor => false,
        };
    }

    fn methodTargetAllocates(
        self: *const AllocationEffectScanner,
        target: ir.exprs.DefId,
    ) bool {
        return self.bodyAllocates(target);
    }

    fn bodyAllocates(self: *const AllocationEffectScanner, target: ir.spine.EntityId) bool {
        if (@as(usize, target) >= self.effects.len) return false;
        return self.effects[target];
    }
};

const ModuleImportKey = struct {
    importing: ir.spine.EntityId,
    target: ir.spine.EntityId,
};
const StdImportDemand = struct {
    fn isQualifiedStdName(name: []const u8) bool {
        return name.len > "std.".len and std.mem.startsWith(u8, name, "std.");
    }

    fn startsStdNamespace(value: ast.Expr) bool {
        return switch (value) {
            .ident => |name| std.mem.eql(u8, name, "std") or isQualifiedStdName(name),
            .field_access => |field_access| startsStdNamespace(field_access.target.*),
            else => false,
        };
    }

    fn typeRequiresStd(ty: ast.Type) bool {
        return switch (ty) {
            .prim, .any_opaque, .void_type => false,
            .named => |name| isQualifiedStdName(name),
            .ptr => |ptr| typeRequiresStd(ptr.elem.*),
            .slice => |slice| typeRequiresStd(slice.elem.*),
            .opt => |inner| typeRequiresStd(inner.*),
            .err_union => |err_union| (if (err_union.err_set) |err_set|
                isQualifiedStdName(err_set)
            else
                false) or typeRequiresStd(err_union.payload.*),
            .generic => |generic| isQualifiedStdName(generic.name) or
                typesRequireStd(generic.params),
            .array => |array| typeRequiresStd(array.elem.*),
            .tuple => |tuple| typesRequireStd(tuple),
            .anon_struct => |anon| {
                for (anon.fields) |field| {
                    if (typeRequiresStd(field.ty)) return true;
                    if (field.default_val) |value| {
                        if (exprRequiresStd(value.*)) return true;
                    }
                }
                return false;
            },
        };
    }

    fn typesRequireStd(types: []const ast.Type) bool {
        for (types) |ty| {
            if (typeRequiresStd(ty)) return true;
        }
        return false;
    }

    fn patternRequiresStd(pattern: ast.Pattern) bool {
        return switch (pattern) {
            .wildcard, .binding, .lit => false,
            .enum_literal => |name| isQualifiedStdName(name),
            .tuple => |patterns| patternsRequireStd(patterns),
            .struct_pat => |struct_pat| {
                if (struct_pat.name) |name| {
                    if (isQualifiedStdName(name)) return true;
                }
                for (struct_pat.fields) |field| {
                    if (patternRequiresStd(field.pat)) return true;
                }
                return false;
            },
        };
    }

    fn patternsRequireStd(patterns: []const ast.Pattern) bool {
        for (patterns) |pattern| {
            if (patternRequiresStd(pattern)) return true;
        }
        return false;
    }

    fn stmtRequiresStd(stmt: ast.Stmt) bool {
        return switch (stmt) {
            .let_stmt => |let_stmt| (if (let_stmt.ty) |ty| typeRequiresStd(ty) else false) or
                exprRequiresStd(let_stmt.init),
            .assign => |assign| exprRequiresStd(assign.target) or exprRequiresStd(assign.val),
            .defer_stmt => |defer_stmt| exprRequiresStd(defer_stmt.expr),
            .expr_stmt => |expr| exprRequiresStd(expr.*),
        };
    }

    fn blockRequiresStd(block: ast.Block) bool {
        for (block.stmts) |stmt| {
            if (stmtRequiresStd(stmt)) return true;
        }
        if (block.expr) |expr| return exprRequiresStd(expr.*);
        return false;
    }

    fn exprRequiresStd(expr: ast.Expr) bool {
        return switch (expr) {
            .lit, .unsupported, .continue_expr => false,
            .ident => |name| isQualifiedStdName(name),
            .field_access => |field_access| startsStdNamespace(expr) or
                exprRequiresStd(field_access.target.*),
            .call => |call| exprRequiresStd(call.callee.*) or
                typesRequireStd(call.generic_args) or
                exprsRequireStd(call.args),
            .block => |block| blockRequiresStd(block),
            .match_expr => |match| {
                if (exprRequiresStd(match.target.*)) return true;
                for (match.arms) |arm| {
                    if (patternsRequireStd(arm.patterns)) return true;
                    if (exprRequiresStd(arm.body)) return true;
                }
                return false;
            },
            .bin_op => |bin_op| exprRequiresStd(bin_op.lhs.*) or exprRequiresStd(bin_op.rhs.*),
            .unary_op => |unary_op| exprRequiresStd(unary_op.operand.*),
            .cast => |cast| typeRequiresStd(cast.target) or exprRequiresStd(cast.operand.*),
            .struct_init => |struct_init| {
                if (struct_init.type_name) |type_name| {
                    if (typeRequiresStd(type_name)) return true;
                }
                for (struct_init.fields) |field| {
                    if (exprRequiresStd(field.expr)) return true;
                }
                return false;
            },
            .array_init => |array_init| {
                if (array_init.type_name) |type_name| {
                    if (typeRequiresStd(type_name)) return true;
                }
                return exprsRequireStd(array_init.elements);
            },
            .repeat => |repeat| {
                if (repeat.type_name) |type_name| {
                    if (typeRequiresStd(type_name)) return true;
                }
                return exprRequiresStd(repeat.elem.*);
            },
            .multi_array => |multi_array| {
                if (multi_array.type_name) |type_name| {
                    if (typeRequiresStd(type_name)) return true;
                }
                return exprsRequireStd(multi_array.elements);
            },
            .builtin => |builtin| isQualifiedStdName(builtin.name) or
                exprsRequireStd(builtin.args),
            .if_expr => |if_expr| exprRequiresStd(if_expr.cond.*) or
                exprRequiresStd(if_expr.then_body.*) or
                (if (if_expr.else_body) |else_body| exprRequiresStd(else_body.*) else false),
            .while_expr => |while_expr| exprRequiresStd(while_expr.cond.*) or
                (if (while_expr.continue_expr) |continue_expr|
                    exprRequiresStd(continue_expr.*)
                else
                    false) or
                blockRequiresStd(while_expr.body) or
                (if (while_expr.else_body) |else_body| exprRequiresStd(else_body.*) else false),
            .for_expr => |for_expr| exprsRequireStd(for_expr.inputs) or
                blockRequiresStd(for_expr.body) or
                (if (for_expr.else_body) |else_body| exprRequiresStd(else_body.*) else false),
            .range => |range| exprRequiresStd(range.start.*) or
                (if (range.end) |end| exprRequiresStd(end.*) else false),
            .return_expr => |value| if (value) |expr_value| exprRequiresStd(expr_value.*) else false,
            .break_expr => |value| if (value) |expr_value| exprRequiresStd(expr_value.*) else false,
        };
    }

    fn exprsRequireStd(exprs: []const ast.Expr) bool {
        for (exprs) |expr| {
            if (exprRequiresStd(expr)) return true;
        }
        return false;
    }

    fn genericParamsRequireStd(params: []const ast.GenericParam) bool {
        for (params) |param| {
            if (param.ty) |ty| {
                if (typeRequiresStd(ty)) return true;
            }
        }
        return false;
    }

    fn declRequiresStd(decl: ast.Decl) bool {
        return switch (decl) {
            .comment => false,
            .struct_decl => |struct_decl| {
                for (struct_decl.fields) |field| {
                    if (typeRequiresStd(field.ty)) return true;
                    if (field.default_val) |value| {
                        if (exprRequiresStd(value.*)) return true;
                    }
                }
                if (genericParamsRequireStd(struct_decl.generic_params)) return true;
                return declsRequireStd(struct_decl.decls);
            },
            .enum_decl => |enum_decl| {
                if (enum_decl.tag_type) |tag_type| {
                    if (typeRequiresStd(tag_type)) return true;
                }
                for (enum_decl.variants) |variant| {
                    if (variant.value) |value| {
                        if (exprRequiresStd(value.*)) return true;
                    }
                }
                return declsRequireStd(enum_decl.decls);
            },
            .union_decl => |union_decl| {
                if (union_decl.tag_type) |tag_type| {
                    if (typeRequiresStd(tag_type)) return true;
                }
                for (union_decl.fields) |field| {
                    if (typeRequiresStd(field.ty)) return true;
                }
                return declsRequireStd(union_decl.decls);
            },
            .fn_decl => |fn_decl| {
                if (typeRequiresStd(fn_decl.ret_type)) return true;
                if (genericParamsRequireStd(fn_decl.generic_params)) return true;
                for (fn_decl.params) |param| {
                    if (typeRequiresStd(param.ty)) return true;
                }
                if (fn_decl.body) |body| return blockRequiresStd(body);
                return false;
            },
            .const_decl => |const_decl| {
                if (const_decl.ty) |ty| {
                    if (typeRequiresStd(ty)) return true;
                }
                return exprRequiresStd(const_decl.init);
            },
            .var_decl => |var_decl| {
                if (var_decl.ty) |ty| {
                    if (typeRequiresStd(ty)) return true;
                }
                return exprRequiresStd(var_decl.init);
            },
        };
    }

    fn declsRequireStd(decls: []const ast.Decl) bool {
        for (decls) |decl| {
            if (declRequiresStd(decl)) return true;
        }
        return false;
    }

    fn fileRequiresStd(decls: []const ast.Decl, tests: []const ast.TestDecl) bool {
        if (declsRequireStd(decls)) return true;
        if (tests.len > 0) {
            for (tests) |test_decl| {
                if (blockRequiresStd(test_decl.body)) return true;
            }
            // The emitter binds expectEqual through std.testing for every test file.
            return true;
        }
        return false;
    }
};

test "std demand detects qualified error-set names" {
    var payload: ast.Type = .{ .prim = .u32 };
    const std_error_union: ast.Type = .{ .err_union = .{
        .err_set = "std.SomeError",
        .payload = &payload,
    } };
    try std.testing.expect(StdImportDemand.typeRequiresStd(std_error_union));

    const local_error_union: ast.Type = .{ .err_union = .{
        .err_set = "SomeError",
        .payload = &payload,
    } };
    try std.testing.expect(!StdImportDemand.typeRequiresStd(local_error_union));
}

const Lowerer = struct {
    alloc: std.mem.Allocator,
    ir: *const ir.RustIr,
    strat: strategy.LoweringStrategy,
    def_strat_inst: default_strat.DefaultStrategy = .{},
    current_module_id: ?ir.spine.EntityId = null,
    current_imports: ?*std.ArrayListUnmanaged(ast.Import) = null,
    pending_module_imports: std.AutoHashMapUnmanaged(ModuleImportKey, []const u8) = .empty,
    runtime_import_modules: std.AutoHashMapUnmanaged(ir.spine.EntityId, void) = .empty,
    /// The inherent struct/enum/union whose method body is being lowered.
    current_struct_id: ?ir.spine.EntityId = null,
    /// Return type of the function currently being lowered.
    current_return_type: ?ir.types.Type = null,
    /// Stable allocation effects computed before any declaration is lowered.
    allocation_effects: ?[]bool = null,
    /// Allocation effect accumulated while lowering the current callable.
    current_callable_is_allocating: bool = false,
    /// Direct call expression currently lowered by an explicit source `try`.
    explicit_try_expr: ?ir.exprs.NodeId = null,
    /// An explicit floating-point function result supplies the expected type
    /// for nested arithmetic whose operands lack inferred type metadata.
    float_context: bool = false,
    /// Expected source parameter type for the active direct-call argument.
    expected_argument_type: ?ir.types.Type = null,
    /// Source expression node receiving the active expected argument type.
    expected_argument_expr_id: ?ir.exprs.NodeId = null,
    /// Statement-local owner acquisitions emitted before the current statement.
    current_owner_prelude: ?*std.ArrayListUnmanaged(ast.Stmt) = null,
    /// Names reserved while lowering the current statement.
    current_owner_reserved: ?*std.ArrayListUnmanaged([]const u8) = null,
    /// Parameter bindings visible while lowering the current callable body.
    current_parameter_names: []const ast.FnParam = &.{},
    /// Declaration name visible while lowering the current callable body.
    current_callable_name: ?[]const u8 = null,
    /// Loop capture names visible while lowering the current loop body.
    current_capture_names: []const []const u8 = &.{},
    /// Value-capture bindings visible while lowering the current loop body.
    current_value_capture_scopes: []const ValueCaptureScope = &.{},
    /// Lexical local bindings that shadow loop captures.
    current_shadow_scope: ?*const ShadowScope = null,

    /// True only while lowering a translated test body.
    lowering_test_entity: bool = false,

    /// Map from target struct/enum EntityId to hoisted method declarations
    hoisted_by_id: std.AutoHashMapUnmanaged(ir.spine.EntityId, std.ArrayListUnmanaged(ast.Decl)) = .empty,

    fn init(
        allocator: std.mem.Allocator,
        rust_ir: *const ir.RustIr,
        custom_strat: ?*const strategy.LoweringStrategy,
    ) Lowerer {
        var lowerer: Lowerer = .{
            .alloc = allocator,
            .ir = rust_ir,
            .strat = undefined,
        };

        if (custom_strat) |cs| {
            lowerer.strat = cs.*;
        } else {
            lowerer.strat = .{
                .ptr = &lowerer.def_strat_inst,
                .vtable = &.{
                    .lowerType = default_strat.DefaultStrategy.lowerType,
                    .lowerStdGeneric = default_strat.DefaultStrategy.lowerStdGeneric,
                },
            };
        }

        return lowerer;
    }
    fn methodEntityForDefinition(
        self: *const Lowerer,
        owner_id: ir.spine.EntityId,
        method: ir.bodies.StructMethod,
    ) ?ir.spine.EntityId {
        for (self.ir.graph.symbol_table.entities.items) |entity| {
            if (entity.kind != .fn_) continue;
            if (!std.mem.eql(u8, entity.name, method.name)) continue;
            if (entity.id >= self.ir.bodies.bodies.len) continue;
            const body = switch (self.ir.bodies.bodies[entity.id]) {
                .fn_ => |function| function,
                else => continue,
            };
            if (body.body != method.body) continue;

            var parent_id = entity.parent;
            while (parent_id) |id| {
                if (id == owner_id) return entity.id;
                const parent = self.ir.graph.symbol_table.get(id) orelse break;
                parent_id = parent.parent;
            }
        }
        return null;
    }

    fn callableAllocates(
        self: *const Lowerer,
        entity_id: ir.spine.EntityId,
        fallback: bool,
    ) bool {
        if (self.allocation_effects) |effects| {
            if (entity_id < effects.len and effects[entity_id]) return true;
        }
        return fallback;
    }

    fn computeAllocationEffects(self: *Lowerer) !void {
        if (self.allocation_effects != null) return;

        const effect_count = @max(
            self.ir.graph.symbol_table.count(),
            self.ir.bodies.bodies.len,
        );
        const effects = try self.alloc.alloc(bool, effect_count);
        errdefer self.alloc.free(effects);
        for (effects) |*effect| effect.* = false;

        const direct_scanner: AllocationEffectScanner = .{
            .exprs = self.ir.bodies.exprs,
            .stmts = self.ir.bodies.stmts,
            .effects = &.{},
        };

        for (self.ir.graph.symbol_table.entities.items) |entity| {
            if (entity.id >= effects.len) continue;
            if (entity.kind != .fn_) continue;
            if (entity.id >= self.ir.bodies.bodies.len) continue;
            const body = switch (self.ir.bodies.bodies[entity.id]) {
                .fn_ => |function| function,
                else => continue,
            };
            if (body.is_allocating or direct_scanner.exprAllocates(body.body)) {
                effects[entity.id] = true;
            }
            if (self.structMethodForDef(entity.id)) |method| {
                if (method.is_allocating) effects[entity.id] = true;
            }
        }

        // Some recovered fixtures retain method metadata only on StructBody.
        // Bind those effects to the resolved method entity before propagation.
        for (self.ir.graph.symbol_table.entities.items) |owner| {
            if (owner.kind != .struct_ and owner.kind != .enum_ and owner.kind != .union_) {
                continue;
            }
            if (owner.id >= self.ir.bodies.bodies.len) continue;
            const structure = switch (self.ir.bodies.bodies[owner.id]) {
                .struct_ => |body| body,
                else => continue,
            };
            for (structure.methods) |method| {
                if (!method.is_allocating and !direct_scanner.exprAllocates(method.body)) {
                    continue;
                }
                if (self.methodEntityForDefinition(owner.id, method)) |method_id| {
                    if (method_id < effects.len) effects[method_id] = true;
                }
            }
        }

        const scanner: AllocationEffectScanner = .{
            .exprs = self.ir.bodies.exprs,
            .stmts = self.ir.bodies.stmts,
            .effects = effects,
        };

        // Each round can turn at least one callable from false to true. The
        // number of rounds is therefore bounded by the finite effect table.
        var round: usize = 0;
        while (round < effect_count) : (round += 1) {
            var changed = false;
            for (self.ir.graph.symbol_table.entities.items) |entity| {
                if (entity.kind != .fn_) continue;
                if (entity.id >= effects.len or entity.id >= self.ir.bodies.bodies.len) continue;
                const body = switch (self.ir.bodies.bodies[entity.id]) {
                    .fn_ => |function| function,
                    else => continue,
                };
                if (effects[entity.id]) continue;
                if (scanner.exprAllocates(body.body)) {
                    effects[entity.id] = true;
                    changed = true;
                }
            }
            if (!changed) break;
        }

        self.allocation_effects = effects;
    }

    fn allocType(self: *Lowerer, t: ast.Type) !*const ast.Type {
        const ptr = try self.alloc.create(ast.Type);
        ptr.* = t;
        return ptr;
    }

    fn allocExpr(self: *Lowerer, e: ast.Expr) !*const ast.Expr {
        const ptr = try self.alloc.create(ast.Expr);
        ptr.* = e;
        return ptr;
    }

    fn appendCrateDependencyImports(
        self: *Lowerer,
        imports: *std.ArrayListUnmanaged(ast.Import),
    ) !void {
        if (self.ir.graph.crates.items.len == 0) return;
        for (self.ir.graph.crates.items[0].deps) |dependency| {
            const module_name = try std.fmt.allocPrint(self.alloc, "r2z-{s}", .{dependency.extern_name});
            defer self.alloc.free(module_name);
            try self.appendImport(imports, dependency.local_alias, module_name, false);
        }
    }

    fn lowerZonDeps(self: *Lowerer) ![]const ast.ZonDep {
        if (self.ir.graph.crates.items.len == 0) return &.{};
        const dependencies = self.ir.graph.crates.items[0].deps;
        if (dependencies.len == 0) return &.{};
        var list: std.ArrayListUnmanaged(ast.ZonDep) = .empty;
        errdefer list.deinit(self.alloc);
        for (dependencies) |dependency| {
            const name = try std.fmt.allocPrint(self.alloc, "r2z-{s}", .{dependency.extern_name});
            errdefer self.alloc.free(name);
            const path = if (dependency.path) |value| try self.alloc.dupe(u8, value) else null;
            errdefer if (path) |value| self.alloc.free(value);
            if (path == null) return error.DependencySourceUnavailable;
            try list.append(self.alloc, .{ .name = name, .path = path });
        }
        return list.toOwnedSlice(self.alloc);
    }

    pub fn lowerPackage(self: *Lowerer) !ast.Package {
        defer self.runtime_import_modules.deinit(self.alloc);
        defer self.pending_module_imports.deinit(self.alloc);
        try self.computeAllocationEffects();
        defer if (self.allocation_effects) |effects| self.alloc.free(effects);
        try self.collectHoistedMethods();

        var files_list: std.ArrayListUnmanaged(ast.File) = .empty;

        if (self.ir.graph.modules.items.len == 0) {
            // No explicit module graph: synthesize a root file from all entities
            const root_file = try self.lowerRootFileFromSymbolTable();
            try files_list.append(self.alloc, root_file);
        } else {
            // Lower each module into a corresponding file
            for (self.ir.graph.modules.items) |mod| {
                const file = try self.lowerModule(mod);
                try files_list.append(self.alloc, file);
            }
        }

        const pkg_name = try self.alloc.dupe(u8, self.ir.crate_name);
        errdefer self.alloc.free(pkg_name);
        const files = try files_list.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(files);
        const zon_deps = try self.lowerZonDeps();

        return .{
            .name = pkg_name,
            .version = "0.0.0",
            .fingerprint = null,
            .files = files,
            .zon_deps = zon_deps,
        };
    }

    fn collectHoistedMethods(self: *Lowerer) !void {
        const count = self.ir.graph.symbol_table.count();
        for (0..count) |idx| {
            const entity_id: ir.spine.EntityId = @intCast(idx);
            const ent = self.ir.graph.symbol_table.get(entity_id) orelse {
                return error.MissingEntityId;
            };

            if (ent.kind == .fn_ and ent.parent != null) {
                const parent_id = ent.parent.?;
                const parent_ent = self.ir.graph.symbol_table.get(parent_id) orelse {
                    return error.MissingParentId;
                };

                const target_id: ?ir.spine.EntityId = blk: {
                    if (parent_ent.kind == .struct_ or
                        parent_ent.kind == .enum_ or
                        parent_ent.kind == .union_)
                    {
                        break :blk parent_id;
                    }
                    if (parent_ent.kind == .impl_) {
                        break :blk parent_ent.parent orelse return error.MissingParentId;
                    }
                    break :blk null;
                };
                if (target_id) |tid| {
                    _ = self.ir.graph.symbol_table.get(tid) orelse return error.MissingDefinition;
                    // A method already registered on the target's StructBody
                    // is rendered directly from `StructBody.methods` by
                    // `lowerEntityDecl`; skip re-hoisting its `.fn_` entity to
                    // avoid a duplicate declaration in the emitted struct.
                    if (try self.isStructMethodRegistered(tid, ent.name)) continue;
                    // Both inherent (`impl Target`) and trait (`impl Trait for
                    // Target`) blocks collect methods onto the target here.
                    // Guard by method name so an identical name supplied by a
                    // second impl block is not appended twice.
                    if (self.isHoistedMethodRegistered(tid, ent.name)) continue;
                    const fn_decl = try self.lowerFnEntity(entity_id, ent);
                    const decl: ast.Decl = .{ .fn_decl = fn_decl };
                    var list: std.ArrayListUnmanaged(ast.Decl) =
                        self.hoisted_by_id.get(tid) orelse .empty;
                    try list.append(self.alloc, decl);
                    try self.hoisted_by_id.put(self.alloc, tid, list);
                }
            }
        }
    }

    /// True when the target entity carries a `.struct_` body whose
    /// `StructBody.methods` already registers a method named `name`.
    fn isStructMethodRegistered(
        self: *Lowerer,
        tid: ir.spine.EntityId,
        name: []const u8,
    ) !bool {
        if (tid >= self.ir.bodies.bodies.len) return error.MissingBodyId;
        switch (self.ir.bodies.bodies[tid]) {
            .struct_ => |sb| {
                for (sb.methods) |m| {
                    if (std.mem.eql(u8, m.name, name)) return true;
                }
                return false;
            },
            else => return error.DeclarationBodyMismatch,
        }
    }

    /// True when a hoisted declaration already exists for `name` on `tid`.
    fn isHoistedMethodRegistered(self: *Lowerer, tid: ir.spine.EntityId, name: []const u8) bool {
        if (self.hoisted_by_id.get(tid)) |list| {
            for (list.items) |d| {
                if (d == .fn_decl and std.mem.eql(u8, d.fn_decl.name, name)) return true;
            }
        }
        return false;
    }

    fn appendImport(
        self: *Lowerer,
        imports: *std.ArrayListUnmanaged(ast.Import),
        local_name: []const u8,
        module_or_path: []const u8,
        is_pub: bool,
    ) !void {
        for (imports.items) |existing| {
            if (std.mem.eql(u8, existing.local_name, local_name) and
                std.mem.eql(u8, existing.module_or_path, module_or_path))
            {
                return;
            }
        }
        const owned_local_name = try self.alloc.dupe(u8, local_name);
        errdefer self.alloc.free(owned_local_name);
        const owned_module_or_path = try self.alloc.dupe(u8, module_or_path);
        errdefer self.alloc.free(owned_module_or_path);
        try imports.append(self.alloc, .{
            .local_name = owned_local_name,
            .module_or_path = owned_module_or_path,
            .is_pub = is_pub,
        });
    }
    fn appendStdImportIfNeeded(
        self: *Lowerer,
        imports: *std.ArrayListUnmanaged(ast.Import),
        decls: []const ast.Decl,
        tests: []const ast.TestDecl,
    ) !void {
        if (!StdImportDemand.fileRequiresStd(decls, tests)) return;
        for (imports.items) |existing| {
            if (std.mem.eql(u8, existing.local_name, "std") and
                std.mem.eql(u8, existing.module_or_path, "std"))
            {
                return;
            }
        }
        try imports.insert(self.alloc, 0, .{
            .local_name = "std",
            .module_or_path = "std",
            .is_pub = false,
        });
    }

    fn moduleImportNameTaken(
        self: *const Lowerer,
        current_module: ir.graph.Module,
        target_module_id: ir.spine.EntityId,
        candidate: []const u8,
        module_path: []const u8,
    ) bool {
        if (self.current_owner_reserved) |reserved| {
            for (reserved.items) |name| {
                if (std.mem.eql(u8, name, candidate)) return true;
            }
        }
        if (self.current_imports) |imports| {
            for (imports.items) |existing| {
                if (!std.mem.eql(u8, existing.local_name, candidate)) continue;
                return !std.mem.eql(u8, existing.module_or_path, module_path);
            }
        }

        if (std.mem.eql(u8, candidate, "std")) return true;
        for (current_module.items) |item_id| {
            const entity = self.ir.graph.symbol_table.get(item_id) orelse continue;
            if (entity.kind == .module and entity.id == target_module_id) continue;
            if (entity.kind == .use_) {
                const use_decl = self.ir.graph.useById(entity.id) orelse continue;
                if (std.mem.eql(u8, use_decl.local_name, candidate)) return true;
                continue;
            }
            const name = entity.renamed_to orelse entity.name;
            if (std.mem.eql(u8, name, candidate)) return true;
        }

        if (current_module.is_crate and self.ir.graph.crates.items.len > 0) {
            for (self.ir.graph.crates.items[0].deps) |dependency| {
                if (std.mem.eql(u8, dependency.local_alias, candidate)) return true;
            }
        }
        return false;
    }

    fn moduleImportAlias(
        self: *Lowerer,
        current_module: ir.graph.Module,
        target_module: ir.graph.Module,
        target_module_id: ir.spine.EntityId,
        module_path: []const u8,
    ) ![]const u8 {
        const base_name = if (target_module.name.len == 0) "root" else target_module.name;
        var candidate: []const u8 = base_name;
        var suffix: usize = 1;
        while (self.moduleImportNameTaken(
            current_module,
            target_module_id,
            candidate,
            module_path,
        )) {
            candidate = try std.fmt.allocPrint(self.alloc, "{s}_{d}", .{ base_name, suffix });
            suffix += 1;
        }
        return candidate;
    }

    fn ensureModuleImport(self: *Lowerer, target_module_id: ir.spine.EntityId) ![]const u8 {
        const importing_module_id = self.current_module_id orelse return error.MissingModule;
        const current_module = self.moduleForEntity(importing_module_id) orelse {
            return error.MissingModule;
        };
        const target_module = self.moduleForEntity(target_module_id) orelse {
            return error.MissingModule;
        };
        const module_path = try self.moduleImportPath(current_module, target_module);
        defer self.alloc.free(module_path);

        const key: ModuleImportKey = .{
            .importing = importing_module_id,
            .target = target_module_id,
        };
        if (self.pending_module_imports.get(key)) |alias| {
            if (self.current_imports) |imports| {
                try self.appendImport(imports, alias, module_path, false);
            }
            return alias;
        }

        const alias = try self.moduleImportAlias(
            current_module,
            target_module,
            target_module_id,
            module_path,
        );
        try self.pending_module_imports.put(self.alloc, key, alias);
        if (self.current_imports) |imports| {
            try self.appendImport(imports, alias, module_path, false);
        }
        return alias;
    }

    fn appendPendingModuleImports(
        self: *Lowerer,
        imports: *std.ArrayListUnmanaged(ast.Import),
        importing_module: ir.graph.Module,
        importing_module_id: ir.spine.EntityId,
    ) !void {
        var pending = self.pending_module_imports.iterator();
        while (pending.next()) |entry| {
            const key = entry.key_ptr.*;
            if (key.importing != importing_module_id) continue;
            const target_module = self.moduleForEntity(key.target) orelse {
                return error.MissingModule;
            };
            const module_path = try self.moduleImportPath(importing_module, target_module);
            defer self.alloc.free(module_path);
            try self.appendImport(imports, entry.value_ptr.*, module_path, false);
        }
    }

    fn markRuntimeImport(self: *Lowerer) !void {
        const module_id = self.current_module_id orelse return error.MissingModule;
        try self.runtime_import_modules.put(self.alloc, module_id, {});
    }

    fn appendRuntimeImport(
        self: *Lowerer,
        imports: *std.ArrayListUnmanaged(ast.Import),
        module_id: ir.spine.EntityId,
    ) !void {
        if (self.runtime_import_modules.contains(module_id)) {
            try self.appendImport(imports, "r2z", "r2z", false);
        }
    }

    /// Find the module row for a module entity. Module rows are dense, while
    /// symbol entities also contain non-module items, so their ids can differ.
    fn moduleForEntity(self: *const Lowerer, entity_id: ir.spine.EntityId) ?ir.graph.Module {
        const entity = self.ir.graph.symbol_table.get(entity_id) orelse {
            return self.ir.graph.module(entity_id);
        };

        // Some hand-built IR fixtures contain module rows without matching
        // module entities. Preserve the dense row lookup for those graphs,
        // but prefer a name/parent match when the entity table is complete.
        if (self.ir.graph.module(entity_id)) |dense_module| {
            var has_matching_module_entity = false;
            for (self.ir.graph.symbol_table.entities.items) |candidate| {
                if (candidate.kind != .module) continue;
                if (candidate.parent == dense_module.parent and
                    std.mem.eql(u8, candidate.name, dense_module.name))
                {
                    has_matching_module_entity = true;
                    break;
                }
            }
            if (!has_matching_module_entity) return dense_module;
            if (dense_module.parent == entity.parent and
                std.mem.eql(u8, dense_module.name, entity.name))
            {
                return dense_module;
            }
        }

        for (self.ir.graph.modules.items) |module| {
            if (module.parent == entity.parent and std.mem.eql(u8, module.name, entity.name)) {
                return module;
            }
        }
        return null;
    }

    fn moduleEntityId(self: *const Lowerer, module: ir.graph.Module) ?ir.spine.EntityId {
        for (self.ir.graph.symbol_table.entities.items) |entity| {
            if (entity.kind != .module) continue;
            if (entity.parent == module.parent and std.mem.eql(u8, entity.name, module.name)) {
                return entity.id;
            }
        }
        return null;
    }

    /// Return the generated source path for a module. The Rust module ancestry
    /// forms the directory hierarchy so equal leaf names under different
    /// parents cannot collide.
    fn moduleFilePath(self: *Lowerer, module: ir.graph.Module) ![]const u8 {
        if (module.kind == .root or module.is_crate) {
            return self.alloc.dupe(u8, "src/root.zig");
        }

        var components: std.ArrayListUnmanaged([]const u8) = .empty;
        defer components.deinit(self.alloc);

        var current = module;
        var remaining = self.ir.graph.modules.items.len + 1;
        while (current.kind != .root and !current.is_crate) {
            if (remaining == 0) return error.ModuleHierarchyCycle;
            remaining -= 1;

            if (current.name.len > 0) {
                try components.append(self.alloc, current.name);
            }
            const parent_id = current.parent orelse break;
            current = self.moduleForEntity(parent_id) orelse {
                return error.ModuleParentMissing;
            };
        }

        if (components.items.len == 0) {
            return self.alloc.dupe(u8, "src/root.zig");
        }

        var path: std.ArrayListUnmanaged(u8) = .empty;
        errdefer path.deinit(self.alloc);
        try path.appendSlice(self.alloc, "src/");

        var index = components.items.len;
        while (index > 0) {
            index -= 1;
            try path.appendSlice(self.alloc, components.items[index]);
            if (index > 0) try path.append(self.alloc, '/');
        }
        try path.appendSlice(self.alloc, ".zig");
        return path.toOwnedSlice(self.alloc);
    }

    /// Return the target module path relative to the importing module file.
    fn moduleImportPath(
        self: *Lowerer,
        importing_module: ir.graph.Module,
        target_module: ir.graph.Module,
    ) ![]const u8 {
        const importing_path = try self.moduleFilePath(importing_module);
        defer self.alloc.free(importing_path);
        const target_path = try self.moduleFilePath(target_module);
        defer self.alloc.free(target_path);

        const importing_dir = std.fs.path.dirname(importing_path) orelse ".";
        const relative_path = try std.fs.path.relativePosix(
            self.alloc,
            ".",
            importing_dir,
            target_path,
        );
        if (relative_path.len > 0 and relative_path[0] == '.') {
            return relative_path;
        }
        defer self.alloc.free(relative_path);
        return std.fmt.allocPrint(self.alloc, "./{s}", .{relative_path});
    }

    /// Add the import required by a sibling path or call.
    fn appendUseSiblingImport(
        self: *Lowerer,
        imports: *std.ArrayListUnmanaged(ast.Import),
        current_mod_id: ir.spine.EntityId,
        use_id: ir.spine.EntityId,
    ) !void {
        const use_decl = self.ir.graph.useById(use_id) orelse return error.MissingUseDeclaration;
        if (!(try self.useHasLowerableTarget(use_decl))) return;
        if (use_decl.kind == .glob) return;

        const target = self.ir.graph.symbol_table.get(use_decl.target) orelse {
            return error.MissingUseTarget;
        };
        const parent_id = if (target.kind == .module)
            target.id
        else
            target.parent orelse return error.MissingParentId;
        if (parent_id == current_mod_id or parent_id == 0) return;

        const parent_module = self.moduleForEntity(parent_id) orelse return error.MissingModule;
        if (parent_module.name.len == 0 or parent_module.is_extern) return;
        const current_module = self.moduleForEntity(current_mod_id) orelse return error.MissingModule;
        const module_path = try self.moduleImportPath(current_module, parent_module);
        defer self.alloc.free(module_path);
        const parent_entity = self.ir.graph.symbol_table.get(parent_id) orelse {
            return error.MissingParentId;
        };
        try self.appendImport(
            imports,
            parent_module.name,
            module_path,
            use_decl.is_pub_export and parent_entity.visibility == .public,
        );
    }

    fn owningModuleEntity(self: *const Lowerer, entity_id: ir.spine.EntityId) !?ir.spine.EntityId {
        var current: ?ir.spine.EntityId = entity_id;
        while (current) |id| {
            const entity = self.ir.graph.symbol_table.get(id) orelse return error.MissingEntityId;
            if (entity.kind == .module) return id;
            current = entity.parent;
        }
        return null;
    }

    /// Return the nominal type that owns an inherent method entity.
    fn inherentStructForEntity(
        self: *const Lowerer,
        entity_id: ir.spine.EntityId,
    ) !?ir.spine.EntityId {
        const entity = self.ir.graph.symbol_table.get(entity_id) orelse {
            return error.MissingEntityId;
        };
        if (entity.kind != .fn_) return null;

        var parent_id = entity.parent;
        while (parent_id) |id| {
            const parent = self.ir.graph.symbol_table.get(id) orelse return error.MissingParentId;
            switch (parent.kind) {
                .struct_, .enum_, .union_ => return id,
                .impl_ => {
                    // An impl whose name contains " for " is a trait impl.
                    // Trait methods are not inherent members of the target.
                    if (std.mem.indexOf(u8, parent.name, " for ") != null) return null;
                    const target_id = parent.parent orelse return error.MissingParentId;
                    const target = self.ir.graph.symbol_table.get(target_id) orelse {
                        return error.MissingDefinition;
                    };
                    switch (target.kind) {
                        .struct_, .enum_, .union_ => return target_id,
                        else => parent_id = target.parent,
                    }
                },
                else => parent_id = parent.parent,
            }
        }
        return null;
    }

    /// Qualify an inherent method with its type namespace. Methods called from
    /// their own struct use `Self`; calls from another scope use the type name.
    fn qualifyInherentMethod(
        self: *Lowerer,
        entity_id: ir.spine.EntityId,
        resolved: ast.Expr,
    ) !ast.Expr {
        const owner_id = (try self.inherentStructForEntity(entity_id)) orelse return resolved;
        const owner = self.ir.graph.symbol_table.get(owner_id) orelse return error.MissingDefinition;
        const owner_name = owner.renamed_to orelse owner.name;
        if (owner_name.len == 0) return error.MissingDefinitionName;
        const entity = self.ir.graph.symbol_table.get(entity_id) orelse return error.MissingDefinition;
        const name = entity.renamed_to orelse entity.name;
        if (name.len == 0) return error.MissingDefinitionName;

        const target = if (self.current_struct_id) |current_id|
            if (current_id == owner_id)
                try self.allocExpr(.{ .ident = try self.alloc.dupe(u8, "Self") })
            else
                try self.allocExpr(try self.lowerResolvedEntity(owner_id))
        else
            try self.allocExpr(try self.lowerResolvedEntity(owner_id));
        return .{ .field_access = .{
            .target = target,
            .field_name = try self.alloc.dupe(u8, name),
        } };
    }
    fn lowerPathExpr(self: *Lowerer, path: ir.exprs.PathExpr) !ast.Expr {
        const resolved = try self.lowerResolvedEntity(path.def);
        const preferred: ?[]const ir.types.Type =
            if (path.generic_args.len > 0) path.generic_args else null;
        const generic_args = try self.lowerGenericArgs(path.def, preferred);
        if (generic_args.len == 0) return resolved;
        const callee = try self.allocExpr(resolved);
        errdefer self.alloc.destroy(callee);
        return .{
            .call = .{
                .callee = callee,
                .generic_args = generic_args,
                .args = &.{},
            },
        };
    }

    fn resolvedEntityModuleAlias(
        self: *Lowerer,
        owner_id: ?ir.spine.EntityId,
    ) !?[]const u8 {
        const owner = owner_id orelse return null;
        const current_module = self.current_module_id orelse return null;
        if (current_module == owner) return null;
        const module_alias = try self.ensureModuleImport(owner);
        return module_alias;
    }

    fn lowerResolvedEntityName(self: *Lowerer, def: ir.spine.EntityId) ![]const u8 {
        const entity = self.ir.graph.symbol_table.get(def) orelse {
            return error.MissingDefinition;
        };
        const name = entity.renamed_to orelse entity.name;
        if (name.len == 0) return error.MissingDefinitionName;
        const owner = try self.owningModuleEntity(def);
        if (owner == null and entity.parent != null) return error.MissingModuleOwner;
        if (try self.resolvedEntityModuleAlias(owner)) |module_alias| {
            return std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ module_alias, name });
        }
        return self.alloc.dupe(u8, name);
    }

    /// Emit a resolved entity as a bare name in its module, or as
    /// `module.name` when the target belongs to another translated module.
    fn lowerResolvedEntity(self: *Lowerer, def: ir.spine.EntityId) !ast.Expr {
        const entity = self.ir.graph.symbol_table.get(def) orelse {
            return error.MissingDefinition;
        };
        const name = entity.renamed_to orelse entity.name;
        if (name.len == 0) return error.MissingDefinitionName;
        const owner = try self.owningModuleEntity(def);
        if (owner == null) {
            if (entity.parent != null) return error.MissingModuleOwner;
            return .{ .ident = try self.alloc.dupe(u8, name) };
        }
        if (try self.resolvedEntityModuleAlias(owner)) |module_alias| {
            const target = try self.allocExpr(.{
                .ident = try self.alloc.dupe(u8, module_alias),
            });
            return .{ .field_access = .{
                .target = target,
                .field_name = try self.alloc.dupe(u8, name),
            } };
        }
        return .{ .ident = try self.alloc.dupe(u8, name) };
    }

    fn traitImplReceiverForEntity(
        self: *const Lowerer,
        entity_id: ir.spine.EntityId,
    ) !?ir.spine.EntityId {
        const entity = self.ir.graph.symbol_table.get(entity_id) orelse {
            return error.MissingDefinition;
        };
        if (entity.kind != .fn_) return null;
        const impl_id = entity.parent orelse return null;
        const impl = self.ir.graph.symbol_table.get(impl_id) orelse {
            return error.MissingParentId;
        };
        if (impl.kind != .impl_ or std.mem.indexOf(u8, impl.name, " for ") == null) return null;

        if (impl.parent) |target_id| {
            const target = self.ir.graph.symbol_table.get(target_id) orelse {
                return error.MissingDefinition;
            };
            switch (target.kind) {
                .struct_, .enum_, .union_ => return target_id,
                else => {},
            }
        }

        const separator = std.mem.indexOf(u8, impl.name, " for ") orelse return null;
        var receiver_name = std.mem.trim(u8, impl.name[separator + 5 ..], " \t\r\n");
        if (std.mem.indexOf(u8, receiver_name, "<")) |generic_start| {
            receiver_name = receiver_name[0..generic_start];
        }
        if (std.mem.lastIndexOf(u8, receiver_name, "::")) |path_separator| {
            receiver_name = receiver_name[path_separator + 2 ..];
        }

        var match: ?ir.spine.EntityId = null;
        for (self.ir.graph.symbol_table.entities.items) |candidate| {
            switch (candidate.kind) {
                .struct_, .enum_, .union_ => {},
                else => continue,
            }
            if (!std.mem.eql(u8, candidate.name, receiver_name)) continue;
            if (match != null) return null;
            match = candidate.id;
        }
        return match;
    }

    fn qualifyTraitImplMethod(
        self: *Lowerer,
        entity_id: ir.spine.EntityId,
    ) !?ast.Expr {
        const receiver_id = (try self.traitImplReceiverForEntity(entity_id)) orelse return null;
        const receiver = try self.lowerResolvedEntity(receiver_id);
        const entity = self.ir.graph.symbol_table.get(entity_id) orelse {
            return error.MissingDefinition;
        };
        const name = entity.renamed_to orelse entity.name;
        if (name.len == 0) return error.MissingDefinitionName;
        const target = try self.allocExpr(receiver);
        errdefer self.alloc.destroy(target);
        const field_name = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(field_name);
        return .{ .field_access = .{
            .target = target,
            .field_name = field_name,
        } };
    }
    /// Register the module that owns a qualified public re-export.
    fn appendUseModuleImport(
        self: *Lowerer,
        imports: *std.ArrayListUnmanaged(ast.Import),
        current_mod_id: ir.spine.EntityId,
        use_id: ir.spine.EntityId,
    ) !void {
        const use_decl = self.ir.graph.useById(use_id) orelse return error.MissingUseDeclaration;
        if (!use_decl.is_pub_export) return;
        if (!(try self.useHasLowerableTarget(use_decl))) return;
        if (use_decl.kind == .glob) return;

        const target = self.ir.graph.symbol_table.get(use_decl.target) orelse {
            return error.MissingUseTarget;
        };
        const parent_id = target.parent orelse return error.MissingParentId;
        if (parent_id == current_mod_id or parent_id == 0) return;
        const current_module = self.moduleForEntity(current_mod_id) orelse return error.MissingModule;
        const parent_module = self.moduleForEntity(parent_id) orelse return error.MissingModule;
        const module_path = try self.moduleImportPath(current_module, parent_module);
        defer self.alloc.free(module_path);
        const parent_entity = self.ir.graph.symbol_table.get(parent_id) orelse {
            return error.MissingParentId;
        };
        try self.appendImport(
            imports,
            parent_module.name,
            module_path,
            parent_entity.visibility == .public,
        );
    }

    fn lowerModule(self: *Lowerer, mod: ir.graph.Module) !ast.File {
        const file_path = try self.moduleFilePath(mod);
        const current_mod_id = self.moduleEntityId(mod) orelse mod.id;

        var imports_list: std.ArrayListUnmanaged(ast.Import) = .empty;
        if (mod.id == 0) {
            try self.appendCrateDependencyImports(&imports_list);
        }

        var decls_list: std.ArrayListUnmanaged(ast.Decl) = .empty;
        var tests_list: std.ArrayListUnmanaged(ast.TestDecl) = .empty;
        const previous_imports = self.current_imports;
        self.current_imports = &imports_list;
        defer self.current_imports = previous_imports;
        try self.appendPendingModuleImports(&imports_list, mod, current_mod_id);

        for (mod.items) |item_id| {
            const ent = self.ir.graph.symbol_table.get(item_id) orelse {
                return error.MissingEntityId;
            };

            if (ent.kind == .module) {
                const child_mod = self.moduleForEntity(item_id) orelse return error.MissingModule;
                const module_path = try self.moduleImportPath(mod, child_mod);
                defer self.alloc.free(module_path);
                try self.appendImport(
                    &imports_list,
                    child_mod.name,
                    module_path,
                    ent.visibility == .public,
                );
                continue;
            }

            if (ent.kind == .use_) {
                const use_decl = self.ir.graph.useById(item_id) orelse {
                    return error.MissingUseDeclaration;
                };
                if (!(try self.useHasLowerableTarget(use_decl))) continue;
                try self.appendUseModuleImport(&imports_list, current_mod_id, item_id);
                try self.appendUseSiblingImport(&imports_list, current_mod_id, item_id);
            }
            if (ent.kind == .fn_ and isTestEntity(ent)) {
                if (try self.lowerTestEntity(item_id, ent)) |td| {
                    try tests_list.append(self.alloc, td);
                    continue;
                }
            }

            if (try self.lowerEntityDecl(item_id, ent, current_mod_id)) |decl| {
                try decls_list.append(self.alloc, decl);
            }
        }

        try self.appendRuntimeImport(&imports_list, current_mod_id);
        try self.appendStdImportIfNeeded(&imports_list, decls_list.items, tests_list.items);
        const imports = try imports_list.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(imports);
        const decls = try decls_list.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(decls);
        const tests = try tests_list.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(tests);

        return .{
            .path = file_path,
            .imports = imports,
            .decls = decls,
            .tests = tests,
        };
    }

    fn lowerRootFileFromSymbolTable(self: *Lowerer) !ast.File {
        var imports_list: std.ArrayListUnmanaged(ast.Import) = .empty;
        try self.appendCrateDependencyImports(&imports_list);
        var decls_list: std.ArrayListUnmanaged(ast.Decl) = .empty;
        var tests_list: std.ArrayListUnmanaged(ast.TestDecl) = .empty;
        const previous_imports = self.current_imports;
        self.current_imports = &imports_list;
        defer self.current_imports = previous_imports;
        if (self.moduleForEntity(0)) |root_module| {
            try self.appendPendingModuleImports(&imports_list, root_module, 0);
        }

        const count = self.ir.graph.symbol_table.count();
        for (0..count) |idx| {
            const entity_id: ir.spine.EntityId = @intCast(idx);
            const ent = self.ir.graph.symbol_table.get(entity_id) orelse {
                return error.MissingEntityId;
            };

            // Skip nested methods (they are hoisted into structs)
            if (ent.parent != null and ent.kind == .fn_) continue;
            if (ent.kind == .use_) {
                const use_decl = self.ir.graph.useById(entity_id) orelse {
                    return error.MissingUseDeclaration;
                };
                if (!(try self.useHasLowerableTarget(use_decl))) continue;
                try self.appendUseModuleImport(&imports_list, 0, entity_id);
                try self.appendUseSiblingImport(&imports_list, 0, entity_id);
            }

            if (ent.kind == .fn_ and isTestEntity(ent)) {
                if (try self.lowerTestEntity(entity_id, ent)) |td| {
                    try tests_list.append(self.alloc, td);
                    continue;
                }
            }

            if (try self.lowerEntityDecl(entity_id, ent, 0)) |decl| {
                try decls_list.append(self.alloc, decl);
            }
        }

        try self.appendRuntimeImport(&imports_list, 0);
        try self.appendStdImportIfNeeded(&imports_list, decls_list.items, tests_list.items);
        const imports = try imports_list.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(imports);
        const decls = try decls_list.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(decls);
        const tests = try tests_list.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(tests);

        return .{
            .path = "src/root.zig",
            .imports = imports,
            .decls = decls,
            .tests = tests,
        };
    }

    fn isExternalMarkerPath(path: []const []const u8) bool {
        if (path.len != 3) return false;
        if (!std.mem.eql(u8, path[0], "core") and
            !std.mem.eql(u8, path[0], "std"))
        {
            return false;
        }
        return (std.mem.eql(u8, path[1], "default") and
            std.mem.eql(u8, path[2], "Default")) or
            (std.mem.eql(u8, path[1], "hash") and
                std.mem.eql(u8, path[2], "Hasher"));
    }

    fn isBuildHasherDefaultPath(path: []const []const u8) bool {
        if (path.len != 3 or !std.mem.eql(u8, path[1], "hash") or
            !std.mem.eql(u8, path[2], "BuildHasherDefault"))
        {
            return false;
        }
        return std.mem.eql(u8, path[0], "core") or std.mem.eql(u8, path[0], "std");
    }

    fn isAllocVecPath(path: []const []const u8) bool {
        if (path.len != 3) return false;
        return std.mem.eql(u8, path[0], "alloc") and
            std.mem.eql(u8, path[1], "vec") and
            std.mem.eql(u8, path[2], "Vec");
    }

    fn useHasLowerableTarget(
        self: *const Lowerer,
        use_decl: ir.graph.UseDecl,
    ) !bool {
        switch (use_decl.kind) {
            .external => |external| {
                if (use_decl.is_pub_export) return error.UnsupportedExternalUse;
                if (isExternalMarkerPath(external.path)) return false;
                // The nominal type lowering adds the r2z import when needed;
                // the lexical use itself does not emit a declaration.
                if (isBuildHasherDefaultPath(external.path) or isAllocVecPath(external.path)) {
                    return false;
                }
                return error.UnsupportedExternalUse;
            },
            else => {},
        }
        if (use_decl.kind == .glob) return false;
        if (use_decl.local_name.len == 0) return error.MissingUseTarget;
        if (std.mem.eql(u8, use_decl.local_name, "_")) return false;

        const use_entity = self.ir.graph.symbol_table.get(use_decl.id) orelse {
            return error.MissingUseDeclaration;
        };
        if (use_entity.kind != .use_) return error.UseDeclarationMismatch;
        if (use_entity.resolved == null) return error.UnresolvedUseTarget;

        const target = self.ir.graph.symbol_table.get(use_decl.target) orelse {
            return error.MissingUseTarget;
        };
        if (target.name.len == 0) return error.MissingUseTarget;
        if (std.mem.eql(u8, target.name, "_")) return false;
        if (target.kind == .extern_crate) return false;

        if (target.parent) |parent_id| {
            const parent_module = self.moduleForEntity(parent_id) orelse {
                return error.MissingModule;
            };
            if (parent_module.is_extern) return false;
        } else if (target.kind != .module) {
            return error.MissingParentId;
        }

        return true;
    }

    /// Return true for a Rust `#[test]` function. The name fallback preserves
    /// compatibility with older in-memory fixtures that predate attributes.
    fn isTestEntity(ent: ir.spine.Entity) bool {
        for (ent.attributes) |attribute| {
            if (std.mem.eql(u8, attribute.name, "test")) return true;
        }
        return std.mem.startsWith(u8, ent.name, "test_") or
            std.mem.eql(u8, ent.name, "test");
    }

    fn lowerEntityDecl(
        self: *Lowerer,
        entity_id: ir.spine.EntityId,
        ent: ir.spine.Entity,
        current_mod_id: ?ir.spine.EntityId,
    ) !?ast.Decl {
        const previous_module_id = self.current_module_id;
        self.current_module_id = current_mod_id;
        defer self.current_module_id = previous_module_id;
        const is_pub = switch (ent.visibility) {
            .public => true,
            else => false,
        };
        if (ent.kind == .extern_crate) {
            return switch (ent.visibility) {
                .private => null,
                else => error.UnsupportedEntityKind,
            };
        }
        if (ent.kind == .field or ent.kind == .variant) return null;

        if (entity_id >= self.ir.bodies.bodies.len) {
            return error.MissingBodyId;
        }
        const body_kind = self.ir.bodies.bodies[entity_id];

        switch (ent.kind) {
            .struct_ => {
                const previous_struct_id = self.current_struct_id;
                self.current_struct_id = entity_id;
                defer self.current_struct_id = previous_struct_id;
                var fields_list: std.ArrayListUnmanaged(ast.StructField) = .empty;
                var inner_decls: std.ArrayListUnmanaged(ast.Decl) = .empty;
                var generic_params_list: std.ArrayListUnmanaged(ast.GenericParam) = .empty;

                switch (body_kind) {
                    .struct_ => |sb| {
                        if (sb.generic_params.len > 0) {
                            for (sb.generic_params) |gp| {
                                try generic_params_list.append(self.alloc, .{
                                    .name = try self.alloc.dupe(u8, gp),
                                    .is_comptime = true,
                                    .ty = null,
                                });
                            }
                        } else {
                            for (sb.fields) |f| {
                                try self.collectGenericTypeParams(f.ty, &generic_params_list);
                            }
                        }

                        for (sb.fields) |f| {
                            const f_ty = try self.lowerType(f.ty);
                            try fields_list.append(self.alloc, .{
                                .name = try self.alloc.dupe(u8, f.name),
                                .ty = f_ty,
                                .is_pub = switch (f.visibility) {
                                    .public => true,
                                    else => false,
                                },
                            });
                        }

                        // Inherent methods from StructBody
                        for (sb.methods) |m| {
                            const m_decl = try self.lowerStructMethod(
                                m,
                                ent.name,
                                generic_params_list.items,
                                entity_id,
                            );
                            try inner_decls.append(self.alloc, ast.Decl{ .fn_decl = m_decl });
                        }
                    },
                    else => return error.DeclarationBodyMismatch,
                }

                // Append any hoisted methods from impl blocks
                if (self.hoisted_by_id.get(entity_id)) |hoisted| {
                    for (hoisted.items) |d| {
                        try inner_decls.append(self.alloc, d);
                    }
                }

                const fields = try fields_list.toOwnedSlice(self.alloc);
                errdefer self.alloc.free(fields);
                const decls = try inner_decls.toOwnedSlice(self.alloc);
                errdefer self.alloc.free(decls);
                const generic_params = try generic_params_list.toOwnedSlice(self.alloc);
                errdefer self.alloc.free(generic_params);

                return ast.Decl{
                    .struct_decl = .{
                        .name = try self.alloc.dupe(u8, ent.name),
                        .is_pub = is_pub,
                        .fields = fields,
                        .decls = decls,
                        .generic_params = generic_params,
                    },
                };
            },
            .enum_ => {
                var variants_list: std.ArrayListUnmanaged(ast.EnumVariant) = .empty;
                var union_fields: std.ArrayListUnmanaged(ast.UnionField) = .empty;
                var inner_decls: std.ArrayListUnmanaged(ast.Decl) = .empty;
                var is_data_carrying = false;

                switch (body_kind) {
                    .enum_ => |eb| {
                        if (eb.kind == .data) is_data_carrying = true;
                        for (eb.variants) |v| {
                            if (is_data_carrying) {
                                var v_ty: ast.Type = ast.Type{ .void_type = {} };
                                switch (v.fields) {
                                    .none => {
                                        v_ty = ast.Type{ .void_type = {} };
                                    },
                                    .tuple => |tup| {
                                        if (tup.len == 1) {
                                            v_ty = try self.lowerType(tup[0]);
                                        } else if (tup.len > 1) {
                                            v_ty = try self.lowerType(ir.types.Type{ .tuple = tup });
                                        }
                                    },
                                    .named => |flds| {
                                        var sf_list: std.ArrayListUnmanaged(ast.StructField) = .empty;
                                        for (flds) |f| {
                                            const f_ty = try self.lowerType(f.ty);
                                            try sf_list.append(self.alloc, .{
                                                .name = try self.alloc.dupe(u8, f.name),
                                                .ty = f_ty,
                                            });
                                        }
                                        v_ty = ast.Type{
                                            .anon_struct = .{
                                                .fields = try sf_list.toOwnedSlice(self.alloc),
                                            },
                                        };
                                    },
                                }
                                try union_fields.append(self.alloc, .{
                                    .name = try self.alloc.dupe(u8, v.name),
                                    .ty = v_ty,
                                });
                            } else {
                                try variants_list.append(self.alloc, .{
                                    .name = try self.alloc.dupe(u8, v.name),
                                    .value = null,
                                });
                            }
                        }
                    },
                    else => return error.DeclarationBodyMismatch,
                }

                if (self.hoisted_by_id.get(entity_id)) |hoisted| {
                    for (hoisted.items) |d| {
                        try inner_decls.append(self.alloc, d);
                    }
                }

                if (is_data_carrying) {
                    const fields = try union_fields.toOwnedSlice(self.alloc);
                    errdefer self.alloc.free(fields);
                    const decls = try inner_decls.toOwnedSlice(self.alloc);
                    errdefer self.alloc.free(decls);

                    return ast.Decl{
                        .union_decl = .{
                            .name = try self.alloc.dupe(u8, ent.name),
                            .is_pub = is_pub,
                            .tag_type = ast.Type{ .named = "enum" },
                            .fields = fields,
                            .decls = decls,
                        },
                    };
                }

                const variants = try variants_list.toOwnedSlice(self.alloc);
                errdefer self.alloc.free(variants);
                const decls = try inner_decls.toOwnedSlice(self.alloc);
                errdefer self.alloc.free(decls);

                return ast.Decl{
                    .enum_decl = .{
                        .name = try self.alloc.dupe(u8, ent.name),
                        .is_pub = is_pub,
                        .variants = variants,
                        .decls = decls,
                    },
                };
            },
            .fn_ => {
                const fn_d = try self.lowerFnEntity(entity_id, ent);
                return ast.Decl{ .fn_decl = fn_d };
            },
            .const_ => {
                var ty: ?ast.Type = null;
                var init_expr: ?ast.Expr = null;

                switch (body_kind) {
                    .const_ => |cb| {
                        ty = try self.lowerType(cb.ty);
                        init_expr = try self.lowerExpr(cb.init);
                    },
                    else => return error.DeclarationBodyMismatch,
                }

                return ast.Decl{
                    .const_decl = .{
                        .name = try self.alloc.dupe(u8, ent.name),
                        .is_pub = is_pub,
                        .ty = ty,
                        .init = init_expr orelse return error.EmptyDeclaration,
                    },
                };
            },
            .static_ => {
                var ty: ?ast.Type = null;
                var init_expr: ?ast.Expr = null;

                switch (body_kind) {
                    .const_ => |cb| {
                        ty = try self.lowerType(cb.ty);
                        init_expr = try self.lowerExpr(cb.init);
                    },
                    else => return error.DeclarationBodyMismatch,
                }

                return ast.Decl{
                    .var_decl = .{
                        .name = try self.alloc.dupe(u8, ent.name),
                        .is_pub = is_pub,
                        .is_mut = true,
                        .ty = ty,
                        .init = init_expr orelse return error.EmptyDeclaration,
                    },
                };
            },
            .type_alias => {
                const target_ty = switch (body_kind) {
                    .type_alias => |tab| try self.lowerType(tab.target),
                    else => return error.DeclarationBodyMismatch,
                };

                const init_expr: ast.Expr = switch (target_ty) {
                    .named => |n| ast.Expr{ .ident = try self.alloc.dupe(u8, n) },
                    .generic => |g| ast.Expr{
                        .call = .{
                            .callee = try self.allocExpr(ast.Expr{
                                .ident = try self.alloc.dupe(u8, g.name),
                            }),
                            .generic_args = g.params,
                            .args = &.{},
                        },
                    },
                    .prim => |p| ast.Expr{ .ident = try self.alloc.dupe(u8, @tagName(p)) },
                    else => return error.UnsupportedTypeAliasTarget,
                };

                return ast.Decl{
                    .const_decl = .{
                        .name = try self.alloc.dupe(u8, ent.name),
                        .is_pub = is_pub,
                        .ty = null,
                        .init = init_expr,
                    },
                };
            },
            .use_ => {
                const use_decl = self.ir.graph.useById(entity_id) orelse {
                    return error.MissingUseDeclaration;
                };
                if (!use_decl.is_pub_export) return null;
                if (!(try self.useHasLowerableTarget(use_decl))) return null;
                if (use_decl.kind == .glob) return null;

                const target_entity = self.ir.graph.symbol_table.get(use_decl.target) orelse {
                    return error.MissingUseTarget;
                };
                var init_expr: ?ast.Expr = null;

                if (target_entity.parent) |parent_id| {
                    const cur_mod_id = current_mod_id orelse 0;
                    if (parent_id != cur_mod_id and parent_id != 0) {
                        const parent_module = self.moduleForEntity(parent_id) orelse {
                            return error.MissingModule;
                        };
                        if (parent_module.name.len == 0) return error.MissingModule;
                        const target_name = try self.alloc.dupe(u8, parent_module.name);
                        errdefer self.alloc.free(target_name);
                        const target = try self.allocExpr(ast.Expr{ .ident = target_name });
                        errdefer self.alloc.destroy(target);
                        const field_name = try self.alloc.dupe(u8, target_entity.name);
                        errdefer self.alloc.free(field_name);
                        init_expr = ast.Expr{
                            .field_access = .{
                                .target = target,
                                .field_name = field_name,
                            },
                        };
                    }
                }

                if (init_expr == null) {
                    const cur_mod_id = current_mod_id orelse 0;
                    const target_parent = target_entity.parent orelse 0;
                    if (target_parent == cur_mod_id and
                        std.mem.eql(u8, use_decl.local_name, target_entity.name))
                    {
                        return null;
                    }
                    init_expr = ast.Expr{ .ident = try self.alloc.dupe(u8, target_entity.name) };
                }

                return ast.Decl{
                    .const_decl = .{
                        .name = try self.alloc.dupe(u8, use_decl.local_name),
                        .is_pub = true,
                        .ty = null,
                        .init = init_expr orelse return error.EmptyDeclaration,
                    },
                };
            },
            .impl_ => {
                // Impl items are hoisted into their target structs/enums; skip at module root.
                return null;
            },
            else => return error.UnsupportedEntityKind,
        }
    }

    fn appendFunctionGenericParams(
        self: *Lowerer,
        generic_params: []const []const u8,
        params: *std.ArrayListUnmanaged(ast.FnParam),
    ) !void {
        for (generic_params) |generic_name| {
            try params.append(self.alloc, .{
                .name = try self.alloc.dupe(u8, generic_name),
                .ty = .{ .named = "type" },
                .is_comptime = true,
            });
        }
    }
    fn isConstU8SliceValue(ty: ir.types.Type) bool {
        return switch (ty) {
            .slice => |slice| {
                if (!slice.const_) return false;
                return switch (slice.elem) {
                    .prim => |primitive| primitive == .u8,
                    else => false,
                };
            },
            .reference => |reference| if (reference.mut) false else switch (reference.pointee) {
                .slice => |slice| {
                    if (!slice.const_) return false;
                    return switch (slice.elem) {
                        .prim => |primitive| primitive == .u8,
                        else => false,
                    };
                },
                else => false,
            },
            else => false,
        };
    }

    fn isPlainU8VecType(ty: ir.types.Type) bool {
        return switch (ty) {
            .external_nominal => |external| blk: {
                if (!isAllocVecPath(external.path)) break :blk false;
                if (external.args.len != 1) break :blk false;
                break :blk switch (external.args[0]) {
                    .prim => |primitive| primitive == .u8,
                    else => false,
                };
            },
            else => false,
        };
    }

    fn isConstU8SliceType(self: *Lowerer, type_id: ir.exprs.TypeRef) bool {
        const ty = self.typeById(type_id) catch return false;
        return switch (ty) {
            .slice => |slice| {
                if (!slice.const_) return false;
                return switch (slice.elem) {
                    .prim => |primitive| primitive == .u8,
                    else => false,
                };
            },
            else => false,
        };
    }

    fn ownedCollectionCapturePath(
        self: *Lowerer,
        expr_id: ir.exprs.NodeId,
        capture_name: []const u8,
    ) bool {
        if (expr_id >= self.ir.bodies.exprs.len) return false;
        return switch (self.ir.bodies.exprs[expr_id].kind) {
            .path => |path| {
                if (path.generic_args.len != 0) return false;
                const entity = self.ir.graph.symbol_table.get(path.def) orelse return false;
                return std.mem.eql(u8, entity.name, capture_name);
            },
            .method_call => |cloned| {
                if (cloned.args.len != 0) return false;
                const cloned_entity = self.ir.graph.symbol_table.get(cloned.method) orelse {
                    return false;
                };
                if (!std.mem.eql(u8, cloned_entity.name, "cloned")) return false;
                if (cloned.receiver >= self.ir.bodies.exprs.len) return false;
                const iter = switch (self.ir.bodies.exprs[cloned.receiver].kind) {
                    .method_call => |value| value,
                    else => return false,
                };
                if (iter.args.len != 0) return false;
                const iter_entity = self.ir.graph.symbol_table.get(iter.method) orelse {
                    return false;
                };
                if (!std.mem.eql(u8, iter_entity.name, "iter")) return false;
                return self.ownedCollectionCapturePath(iter.receiver, capture_name);
            },
            else => false,
        };
    }

    fn matchOwnedTemporary(
        self: *Lowerer,
        arg_id: ir.exprs.NodeId,
        expected_type: ir.types.Type,
    ) ?OwnedTemporaryPlan {
        if (arg_id >= self.ir.bodies.exprs.len) return null;
        const borrowed = switch (self.ir.bodies.exprs[arg_id].kind) {
            .unary => |unary| unary,
            else => return null,
        };
        if (borrowed.op != .ref) return null;
        const producer_expr = borrowed.operand;
        if (producer_expr >= self.ir.bodies.exprs.len) return null;
        var producer_call_id = producer_expr;
        switch (self.ir.bodies.exprs[producer_expr].kind) {
            .call => {},
            .try_ => |try_expr| {
                if (try_expr.inner >= self.ir.bodies.exprs.len) return null;
                producer_call_id = try_expr.inner;
            },
            else => return null,
        }
        if (self.ir.bodies.exprs[producer_call_id].kind != .call) return null;
        const producer_call = self.ir.bodies.exprs[producer_call_id].kind.call;
        const producer_def = switch (producer_call.call_kind) {
            .free => |def| def,
            .associated => |def| def,
            .constructor => |def| def,
        };
        if (!self.directCallAllocates(producer_def)) return null;
        const return_type = self.exprType(producer_call_id) orelse return null;
        if (!isPlainU8VecType(return_type)) return null;
        if (!isConstU8SliceValue(expected_type)) return null;
        return .{ .return_type = return_type };
    }

    fn matchOwnedCollection(
        self: *Lowerer,
        body_id: ir.exprs.NodeId,
        return_type: ir.types.Type,
        is_allocating: bool,
    ) ?OwnedCollectionPlan {
        if (!is_allocating) return null;
        if (!isPlainU8VecType(return_type)) return null;
        if (body_id >= self.ir.bodies.exprs.len) return null;

        const body = switch (self.ir.bodies.exprs[body_id].kind) {
            .block => |value| value,
            else => return null,
        };
        if (body.statements.len != 0 or body.labelled != null) return null;
        const tail_id = body.tail orelse return null;
        if (tail_id >= self.ir.bodies.exprs.len) return null;
        const chain = switch (self.ir.bodies.exprs[tail_id].kind) {
            .iterator_chain => |value| value,
            else => return null,
        };
        if (chain.terminal != .collect_vec or chain.adapters.len != 1) return null;
        const closure = switch (chain.adapters[0]) {
            .flat_map => |value| value,
            else => return null,
        };
        if (chain.source >= self.ir.bodies.exprs.len) return null;
        const range = switch (self.ir.bodies.exprs[chain.source].kind) {
            .range => |value| value,
            else => return null,
        };
        if (range.inclusive) return null;
        if (range.start >= self.ir.bodies.exprs.len) return null;
        if (range.end >= self.ir.bodies.exprs.len) return null;

        if (closure.trait != .@"fn" or closure.captures.len != 1) return null;
        const capture = closure.captures[0];
        if (capture.name.len == 0 or capture.mode != .by_ref) return null;
        if (!self.isConstU8SliceType(capture.ty)) return null;
        if (closure.params.len != 1) return null;
        if (closure.params[0] >= self.ir.bodies.pats.len) return null;
        const item_name = switch (self.ir.bodies.pats[closure.params[0]].kind) {
            .wildcard => "_",
            .binding => |value| blk: {
                if (value.name.len == 0 or value.mutable) return null;
                switch (value.mode) {
                    .value => {},
                    else => return null,
                }
                break :blk value.name;
            },
            else => return null,
        };
        if (closure.body.statements.len != 0 or closure.body.labelled != null) return null;
        const closure_tail = closure.body.tail orelse return null;
        if (!self.ownedCollectionCapturePath(closure_tail, capture.name)) return null;

        return .{
            .range_start = range.start,
            .range_end = range.end,
            .source_name = capture.name,
            .item_name = item_name,
        };
    }

    fn lowerOwnedCollectionReturnType(
        self: *Lowerer,
        return_type: ir.types.Type,
    ) !ast.Type {
        const payload = try self.allocType(try self.lowerType(return_type));
        return .{ .err_union = .{
            .err_set = null,
            .payload = payload,
        } };
    }

    fn appendCollectorStmtIdentifiers(
        self: *Lowerer,
        stmt: ast.Stmt,
        reserved: *std.ArrayListUnmanaged([]const u8),
    ) std.mem.Allocator.Error!void {
        switch (stmt) {
            .let_stmt => |let_stmt| {
                try reserved.append(self.alloc, let_stmt.name);
                try self.appendCollectorExprIdentifiers(let_stmt.init, reserved);
            },
            .assign => |assign| {
                try self.appendCollectorExprIdentifiers(assign.target, reserved);
                try self.appendCollectorExprIdentifiers(assign.val, reserved);
            },
            .defer_stmt => |defer_stmt| {
                try self.appendCollectorExprIdentifiers(defer_stmt.expr, reserved);
            },
            .expr_stmt => |expr| {
                try self.appendCollectorExprIdentifiers(expr.*, reserved);
            },
        }
    }
    fn appendShadowBindingName(
        self: *Lowerer,
        stmt: ast.Stmt,
        names: *std.ArrayListUnmanaged([]const u8),
    ) std.mem.Allocator.Error!void {
        switch (stmt) {
            .let_stmt => |let_stmt| try names.append(self.alloc, let_stmt.name),
            else => {},
        }
    }

    fn appendPatternBindingName(
        self: *Lowerer,
        pat_id: ir.exprs.NodeId,
        reserved: *std.ArrayListUnmanaged([]const u8),
    ) std.mem.Allocator.Error!void {
        if (pat_id >= self.ir.bodies.pats.len) return;
        switch (self.ir.bodies.pats[pat_id].kind) {
            .binding => |binding| try reserved.append(self.alloc, binding.name),
            .reference => |reference| try self.appendPatternBindingName(reference.inner, reserved),
            .tuple => |tuple| for (tuple.elements) |element| {
                try self.appendPatternBindingName(element, reserved);
            },
            .slice => |slice| {
                for (slice.elements) |element| {
                    try self.appendPatternBindingName(element, reserved);
                }
                if (slice.rest) |rest| try self.appendPatternBindingName(rest, reserved);
            },
            .struct_pat => |struct_pat| for (struct_pat.fields) |field| {
                if (field.pat) |field_pat| {
                    try self.appendPatternBindingName(field_pat, reserved);
                } else if (field.shorthand) {
                    try reserved.append(self.alloc, field.field);
                }
            },
            .@"or" => |or_pattern| for (or_pattern.alternatives) |alternative| {
                try self.appendPatternBindingName(alternative, reserved);
            },
            else => {},
        }
    }

    fn appendBlockBindingNames(
        self: *Lowerer,
        statement_ids: []const ir.exprs.NodeId,
        reserved: *std.ArrayListUnmanaged([]const u8),
    ) std.mem.Allocator.Error!void {
        for (statement_ids) |stmt_id| {
            if (stmt_id >= self.ir.bodies.stmts.len) continue;
            switch (self.ir.bodies.stmts[stmt_id].kind) {
                .let => |let_stmt| try self.appendPatternBindingName(let_stmt.pattern, reserved),
                .let_else => |let_else| try self.appendPatternBindingName(let_else.pattern, reserved),
                else => {},
            }
        }
    }

    fn appendCollectorBlockIdentifiers(
        self: *Lowerer,
        block: ast.Block,
        reserved: *std.ArrayListUnmanaged([]const u8),
    ) std.mem.Allocator.Error!void {
        for (block.stmts) |stmt| {
            try self.appendCollectorStmtIdentifiers(stmt, reserved);
        }
        if (block.expr) |expr| {
            try self.appendCollectorExprIdentifiers(expr.*, reserved);
        }
    }

    fn ensureErrorUnion(self: *Lowerer, ty: ast.Type) !ast.Type {
        return switch (ty) {
            .err_union => ty,
            else => .{ .err_union = .{
                .err_set = null,
                .payload = try self.allocType(ty),
            } },
        };
    }

    fn paramsWithAllocator(
        self: *Lowerer,
        params: []const ast.FnParam,
        position: usize,
    ) ![]const ast.FnParam {
        if (position > params.len) return error.InvalidAllocatorPosition;
        const result = try self.alloc.alloc(ast.FnParam, params.len + 1);
        @memcpy(result[0..position], params[0..position]);
        result[position] = .{
            .name = "allocator",
            .ty = ast.Type{ .named = "std.mem.Allocator" },
        };
        @memcpy(result[position + 1 ..], params[position..]);
        return result;
    }

    fn appendCollectorExprIdentifiers(
        self: *Lowerer,
        expr: ast.Expr,
        reserved: *std.ArrayListUnmanaged([]const u8),
    ) std.mem.Allocator.Error!void {
        switch (expr) {
            .lit, .unsupported, .continue_expr => {},
            .ident => |name| try reserved.append(self.alloc, name),
            .field_access => |field_access| {
                try self.appendCollectorExprIdentifiers(field_access.target.*, reserved);
            },
            .call => |call| {
                try self.appendCollectorExprIdentifiers(call.callee.*, reserved);
                for (call.args) |arg| {
                    try self.appendCollectorExprIdentifiers(arg, reserved);
                }
            },
            .block => |block| try self.appendCollectorBlockIdentifiers(block, reserved),
            .match_expr => |match| {
                try self.appendCollectorExprIdentifiers(match.target.*, reserved);
                for (match.arms) |arm| {
                    try self.appendCollectorExprIdentifiers(arm.body, reserved);
                }
            },
            .bin_op => |bin_op| {
                try self.appendCollectorExprIdentifiers(bin_op.lhs.*, reserved);
                try self.appendCollectorExprIdentifiers(bin_op.rhs.*, reserved);
            },
            .unary_op => |unary_op| {
                try self.appendCollectorExprIdentifiers(unary_op.operand.*, reserved);
            },
            .cast => |cast| {
                try self.appendCollectorExprIdentifiers(cast.operand.*, reserved);
            },
            .struct_init => |struct_init| {
                for (struct_init.fields) |field| {
                    try self.appendCollectorExprIdentifiers(field.expr, reserved);
                }
            },
            .array_init => |array_init| {
                for (array_init.elements) |element| {
                    try self.appendCollectorExprIdentifiers(element, reserved);
                }
            },
            .repeat => |repeat| {
                try self.appendCollectorExprIdentifiers(repeat.elem.*, reserved);
            },
            .multi_array => |multi_array| {
                for (multi_array.elements) |element| {
                    try self.appendCollectorExprIdentifiers(element, reserved);
                }
            },
            .builtin => |builtin| {
                for (builtin.args) |arg| {
                    try self.appendCollectorExprIdentifiers(arg, reserved);
                }
            },
            .if_expr => |if_expr| {
                try self.appendCollectorExprIdentifiers(if_expr.cond.*, reserved);
                try self.appendCollectorExprIdentifiers(if_expr.then_body.*, reserved);
                if (if_expr.else_body) |else_body| {
                    try self.appendCollectorExprIdentifiers(else_body.*, reserved);
                }
            },
            .while_expr => |while_expr| {
                try self.appendCollectorExprIdentifiers(while_expr.cond.*, reserved);
                try self.appendCollectorBlockIdentifiers(while_expr.body, reserved);
                if (while_expr.else_body) |else_body| {
                    try self.appendCollectorExprIdentifiers(else_body.*, reserved);
                }
            },
            .for_expr => |for_expr| {
                for (for_expr.inputs) |input| {
                    try self.appendCollectorExprIdentifiers(input, reserved);
                }
                try self.appendCollectorBlockIdentifiers(for_expr.body, reserved);
                if (for_expr.else_body) |else_body| {
                    try self.appendCollectorExprIdentifiers(else_body.*, reserved);
                }
            },
            .range => |range| {
                try self.appendCollectorExprIdentifiers(range.start.*, reserved);
                if (range.end) |end| {
                    try self.appendCollectorExprIdentifiers(end.*, reserved);
                }
            },
            .return_expr => |value| {
                if (value) |expr_ptr| {
                    try self.appendCollectorExprIdentifiers(expr_ptr.*, reserved);
                }
            },
            .break_expr => |value| {
                if (value) |expr_ptr| {
                    try self.appendCollectorExprIdentifiers(expr_ptr.*, reserved);
                }
            },
        }
    }

    fn appendCollectorImportAliases(
        self: *Lowerer,
        reserved: *std.ArrayListUnmanaged([]const u8),
    ) !void {
        if (self.current_imports) |imports| {
            for (imports.items) |import| {
                try reserved.append(self.alloc, import.local_name);
            }
        }
    }

    fn collectorBindingName(
        self: *Lowerer,
        base_name: []const u8,
        reserved: []const []const u8,
    ) ![]const u8 {
        var candidate = base_name;
        var suffix: usize = 1;
        while (true) {
            var taken = false;
            for (reserved) |name| {
                if (std.mem.eql(u8, name, candidate)) {
                    taken = true;
                    break;
                }
            }
            if (!taken) return candidate;
            candidate = try std.fmt.allocPrint(self.alloc, "{s}_{d}", .{ base_name, suffix });
            suffix += 1;
        }
    }

    fn lowerOwnedCollectionBlock(
        self: *Lowerer,
        plan: OwnedCollectionPlan,
        return_type: ir.types.Type,
        params: []const ast.FnParam,
        declaration_name: []const u8,
    ) !ast.Block {
        const owner_type = try self.lowerType(return_type);
        const range_start = try self.allocExpr(try self.lowerExpr(plan.range_start));
        const range_end = try self.allocExpr(try self.lowerExpr(plan.range_end));

        var reserved_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer reserved_names.deinit(self.alloc);
        for (params) |param| {
            try reserved_names.append(self.alloc, param.name);
        }
        try reserved_names.append(self.alloc, declaration_name);
        try reserved_names.append(self.alloc, plan.source_name);
        try reserved_names.append(self.alloc, plan.item_name);
        try self.appendCollectorExprIdentifiers(range_start.*, &reserved_names);
        try self.appendCollectorExprIdentifiers(range_end.*, &reserved_names);
        try self.appendCollectorImportAliases(&reserved_names);

        const owner_name = try self.collectorBindingName("owner", reserved_names.items);
        try reserved_names.append(self.alloc, owner_name);
        const byte_name = try self.collectorBindingName("_byte", reserved_names.items);

        const owner_generic = switch (owner_type) {
            .generic => |generic| generic,
            else => unreachable,
        };
        const owner_type_expr = try self.allocExpr(.{ .call = .{
            .callee = try self.allocExpr(.{ .ident = owner_generic.name }),
            .generic_args = owner_generic.params,
            .args = &.{},
        } });
        const owner_init: ast.Expr = .{ .field_access = .{
            .target = owner_type_expr,
            .field_name = "empty",
        } };
        const range: ast.Expr = .{ .range = .{
            .start = range_start,
            .end = range_end,
        } };

        const append_target = try self.allocExpr(.{ .ident = owner_name });
        const append_callee = try self.allocExpr(.{ .field_access = .{
            .target = append_target,
            .field_name = "append",
        } });
        const append_args = try self.alloc.alloc(ast.Expr, 2);
        append_args[0] = .{ .ident = "allocator" };
        append_args[1] = .{ .ident = byte_name };
        const append_call = try self.allocExpr(.{ .call = .{
            .callee = append_callee,
            .args = append_args,
        } });
        const append_try = try self.allocExpr(.{ .unary_op = .{
            .op = .try_op,
            .operand = append_call,
        } });
        const inner_stmts = try self.alloc.alloc(ast.Stmt, 1);
        inner_stmts[0] = .{ .expr_stmt = append_try };
        const inner_inputs = try self.alloc.alloc(ast.Expr, 1);
        inner_inputs[0] = .{ .ident = plan.source_name };
        const inner_captures = try self.alloc.alloc([]const u8, 1);
        inner_captures[0] = byte_name;
        const inner_loop = try self.allocExpr(.{ .for_expr = .{
            .inputs = inner_inputs,
            .captures = inner_captures,
            .body = .{ .stmts = inner_stmts },
        } });

        const outer_stmts = try self.alloc.alloc(ast.Stmt, 1);
        outer_stmts[0] = .{ .expr_stmt = inner_loop };
        const outer_inputs = try self.alloc.alloc(ast.Expr, 1);
        outer_inputs[0] = range;
        const outer_captures = try self.alloc.alloc([]const u8, 1);
        outer_captures[0] = "_";
        const outer_loop = try self.allocExpr(.{ .for_expr = .{
            .inputs = outer_inputs,
            .captures = outer_captures,
            .body = .{ .stmts = outer_stmts },
        } });

        const statements = try self.alloc.alloc(ast.Stmt, 3);
        statements[0] = .{ .let_stmt = .{
            .name = owner_name,
            .ty = owner_type,
            .init = owner_init,
            .is_mut = true,
        } };
        statements[1] = .{ .defer_stmt = .{
            .expr = .{ .call = .{
                .callee = try self.allocExpr(.{ .field_access = .{
                    .target = try self.allocExpr(.{ .ident = owner_name }),
                    .field_name = "deinit",
                } }),
                .args = &.{.{ .ident = "allocator" }},
            } },
            .is_errdefer = true,
        } };
        statements[2] = .{ .expr_stmt = outer_loop };

        return .{
            .stmts = statements,
            .expr = try self.allocExpr(.{ .ident = owner_name }),
        };
    }

    fn lowerFnEntity(self: *Lowerer, entity_id: ir.spine.EntityId, ent: ir.spine.Entity) !ast.FnDecl {
        const previous_module_id = self.current_module_id;
        self.current_module_id = (try self.owningModuleEntity(entity_id)) orelse previous_module_id;
        defer self.current_module_id = previous_module_id;
        const previous_struct_id = self.current_struct_id;
        self.current_struct_id =
            (try self.inherentStructForEntity(entity_id)) orelse previous_struct_id;
        defer self.current_struct_id = previous_struct_id;
        const previous_callable_name = self.current_callable_name;
        self.current_callable_name = ent.name;
        defer self.current_callable_name = previous_callable_name;

        const is_pub = switch (ent.visibility) {
            .public => true,
            else => false,
        };

        if (entity_id >= self.ir.bodies.bodies.len) {
            return error.MissingBodyId;
        }
        const body_kind = self.ir.bodies.bodies[entity_id];

        var params_list: std.ArrayListUnmanaged(ast.FnParam) = .empty;
        var ret_type: ast.Type = ast.Type{ .void_type = {} };
        var fn_block: ?ast.Block = null;
        var callable_is_allocating = false;
        var allocator_param_index: usize = 0;
        var has_allocator_param = false;

        switch (body_kind) {
            .fn_ => |fb| {
                const previous_callable_effect = self.current_callable_is_allocating;
                const stable_callable_effect = self.callableAllocates(entity_id, fb.is_allocating);
                self.current_callable_is_allocating = stable_callable_effect;
                defer self.current_callable_is_allocating = previous_callable_effect;
                callable_is_allocating = stable_callable_effect;
                allocator_param_index = fb.generic_params.len;
                has_allocator_param = stable_callable_effect;
                try self.appendFunctionGenericParams(fb.generic_params, &params_list);
                if (stable_callable_effect) {
                    try params_list.append(self.alloc, .{
                        .name = "allocator",
                        .ty = ast.Type{ .named = "std.mem.Allocator" },
                    });
                }

                for (fb.params) |p| {
                    const p_ty = try self.lowerType(p.ty);
                    try params_list.append(self.alloc, .{
                        .name = try self.alloc.dupe(u8, p.name),
                        .ty = p_ty,
                    });
                }

                // Explicit Rust `-> T` (including `-> ()`) wins. Only when the
                // return type was left implicit (unit) do we try to infer a
                // concrete type from the tail expression so the emitted fn
                // carries a real `ret_type` (e.g. `origin() -> Point`,
                // `area(s) -> f64`).
                const effective_ret = if (fb.ret == .prim and fb.ret.prim == .unit)
                    if (self.inferTailReturnType(fb.body)) |t| t else fb.ret
                else
                    fb.ret;
                const owned_collection =
                    self.matchOwnedCollection(fb.body, effective_ret, stable_callable_effect);
                ret_type = if (owned_collection != null)
                    try self.lowerOwnedCollectionReturnType(effective_ret)
                else
                    try self.lowerType(effective_ret);
                const previous_return_type = self.current_return_type;
                const previous_parameter_names = self.current_parameter_names;
                self.current_parameter_names = params_list.items;
                defer self.current_parameter_names = previous_parameter_names;

                self.current_return_type = effective_ret;
                defer self.current_return_type = previous_return_type;
                const previous_float_context = self.float_context;
                self.float_context = isFloatType(effective_ret);
                defer self.float_context = previous_float_context;

                if (owned_collection) |plan| {
                    fn_block = try self.lowerOwnedCollectionBlock(
                        plan,
                        effective_ret,
                        params_list.items,
                        ent.name,
                    );
                } else {
                    if (fb.body >= self.ir.bodies.exprs.len) {
                        return error.MissingExpressionNode;
                    }
                    const expr_node = self.ir.bodies.exprs[fb.body];
                    switch (expr_node.kind) {
                        .block => |be| {
                            var body = try self.lowerBlock(be);
                            switch (ret_type) {
                                .void_type => {},
                                else => promoteTrailingMatch(&body),
                            }
                            fn_block = body;
                        },
                        else => {
                            const lowered_e = try self.lowerExpr(fb.body);
                            fn_block = ast.Block{
                                .stmts = &.{},
                                .expr = try self.allocExpr(lowered_e),
                            };
                        },
                    }
                }
                callable_is_allocating = self.current_callable_is_allocating;
            },
            else => return error.DeclarationBodyMismatch,
        }

        const final_params = if (callable_is_allocating and !has_allocator_param) blk: {
            const params = try self.paramsWithAllocator(
                params_list.items,
                allocator_param_index,
            );
            params_list.deinit(self.alloc);
            break :blk params;
        } else try params_list.toOwnedSlice(self.alloc);
        if (callable_is_allocating) {
            ret_type = try self.ensureErrorUnion(ret_type);
        }

        const body = fn_block orelse return error.EmptyFunctionBody;

        return .{
            .name = try self.alloc.dupe(u8, ent.name),
            .is_pub = is_pub,
            .params = final_params,
            .ret_type = ret_type,
            .body = body,
        };
    }

    /// Tree-sitter represents a final Rust match as an expression statement.
    /// Restore value position when the function has a non-void return type.
    fn promoteTrailingMatch(block: *ast.Block) void {
        if (block.expr != null) return;
        if (block.stmts.len == 0) return;

        const tail = switch (block.stmts[block.stmts.len - 1]) {
            .expr_stmt => |expr| expr,
            else => return,
        };
        if (tail.* != .match_expr and tail.* != .if_expr) return;

        block.stmts = block.stmts[0 .. block.stmts.len - 1];
        block.expr = tail;
    }

    /// Infer a concrete return type from a function body's tail expression when
    /// the return type was left implicit (Rust `-> ()` desugars to unit). Used
    /// only to surface an accurate `ret_type` on the emitted fn; never attempts
    /// full type inference. Returns `null` when the tail is unit/empty or an
    /// explicit `return ...;` statement owns the value (the statement set has
    /// no tail).
    fn inferTailReturnType(self: *Lowerer, body: ir.exprs.NodeId) ?ir.types.Type {
        if (body >= self.ir.bodies.exprs.len) return null;
        const tail = switch (self.ir.bodies.exprs[body].kind) {
            .block => |be| blk: {
                if (be.tail) |tail_id| {
                    if (tail_id >= self.ir.bodies.exprs.len) return null;
                    break :blk tail_id;
                }
                if (be.statements.len == 0) return null;

                const stmt_id = be.statements[be.statements.len - 1];
                if (stmt_id >= self.ir.bodies.stmts.len) return null;
                break :blk switch (self.ir.bodies.stmts[stmt_id].kind) {
                    .expr => |expr_id| expr_id,
                    else => return null,
                };
            },
            else => body,
        };
        if (tail >= self.ir.bodies.exprs.len) return null;

        const e = self.ir.bodies.exprs[tail];
        // A wired concerete type annotation on the tail expr is authoritative.
        if (e.ty) |ty_id| {
            if (ty_id < self.ir.types.len) {
                const ct = self.ir.types[ty_id];
                if (ct != .unsupported) return ct;
            }
        }

        return switch (e.kind) {
            .literal => |lit| switch (lit) {
                .int => |il| blk: {
                    const nm = il.ty_suffix orelse break :blk .{ .prim = .i32 };
                    const prim: ir.types.Prim = if (std.mem.eql(u8, nm, "i8"))
                        .i8
                    else if (std.mem.eql(u8, nm, "i16"))
                        .i16
                    else if (std.mem.eql(u8, nm, "i32"))
                        .i32
                    else if (std.mem.eql(u8, nm, "i64"))
                        .i64
                    else if (std.mem.eql(u8, nm, "i128"))
                        .i128
                    else if (std.mem.eql(u8, nm, "isize"))
                        .isize
                    else if (std.mem.eql(u8, nm, "u8"))
                        .u8
                    else if (std.mem.eql(u8, nm, "u16"))
                        .u16
                    else if (std.mem.eql(u8, nm, "u32"))
                        .u32
                    else if (std.mem.eql(u8, nm, "u64"))
                        .u64
                    else if (std.mem.eql(u8, nm, "u128"))
                        .u128
                    else if (std.mem.eql(u8, nm, "usize"))
                        .usize
                    else
                        .i32;
                    break :blk .{ .prim = prim };
                },
                .float => .{ .prim = .f64 },
                .boolean => .{ .prim = .bool },
                .character => .{ .prim = .u8 },
                .string => .{ .slice = (self.sliceU8Alloc() orelse return null) },
                .byte_array => .{ .slice = (self.sliceU8Alloc() orelse return null) },
            },
            .struct_lit => |sl| self.namedFromDef(sl.def),
            .enum_variant => |ev| self.namedFromDef(ev.def),
            .call => |c| switch (c.call_kind) {
                .free => |def_id| self.namedFromDef(def_id),
                .associated => |def_id| self.namedFromDef(def_id),
                .constructor => |def_id| self.namedFromDef(def_id),
            },
            .path => |pe| self.namedFromDef(pe.def),
            .binary => |b| self.binopResultType(b),
            .unary => |u| switch (u.op) {
                .negate, .deref => self.exprType(u.operand),
                else => null,
            },
            .if_else => |ie| self.exprType(ie.then_.tail orelse return null),
            .match => |match| self.matchResultType(match),
            else => null,
        };
    }

    /// Re-wrap a concrete ir type as a fresh slice-of-u8 (for string/byte-array
    /// tail literals). The returned slice is arena-backed.
    fn sliceU8Alloc(self: *Lowerer) ?*const ir.types.Slice {
        const s = self.alloc.create(ir.types.Slice) catch return null;
        s.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
        return s;
    }

    /// Resolve a def id to its emitted name as a `.named` type; null when
    /// unresolvable in the symbol table.
    fn namedFromDef(self: *Lowerer, def: ir.spine.EntityId) ?ir.types.Type {
        const ent = self.ir.graph.symbol_table.get(def) orelse return null;
        const nm = ent.renamed_to orelse ent.name;
        if (nm.len == 0) return null;
        return .{ .path = .{ .segments = &.{.{ .name = nm, .id = def }} } };
    }

    /// Best-effort concrete type of a sub-expression (used by binary/unary/if
    /// inference), recursing one level only.
    fn exprType(self: *Lowerer, id: ir.exprs.NodeId) ?ir.types.Type {
        if (id >= self.ir.bodies.exprs.len) return null;
        const e = self.ir.bodies.exprs[id];
        if (e.ty) |ty_id| {
            const ct: ?ir.types.Type = if (ty_id < self.ir.types.len)
                self.ir.types[ty_id]
            else if (ty_id < self.ir.bodies.types.len)
                self.ir.bodies.types[ty_id]
            else
                null;
            if (ct) |resolved| {
                if (resolved != .unsupported) return resolved;
            }
        }
        return switch (e.kind) {
            .literal => |lit| switch (lit) {
                .int => .{ .prim = .i32 },
                .float => .{ .prim = .f64 },
                .boolean => .{ .prim = .bool },
                else => null,
            },
            .struct_lit => |sl| self.namedFromDef(sl.def),
            .path => |pe| self.namedFromDef(pe.def),
            .binary => |binary| self.binopResultType(binary),
            .match => |match| self.matchResultType(match),
            else => null,
        };
    }

    fn matchResultType(self: *Lowerer, match: ir.exprs.MatchExpr) ?ir.types.Type {
        for (match.arms) |arm| {
            if (self.exprType(arm.body)) |result_type| return result_type;
        }
        return null;
    }

    /// Result type of a binary expression: comparisons/boolean ops are bool;
    /// otherwise prefer an operand's concrete type (float vs int), falling back
    /// to any operand concrete type.
    fn binopResultType(self: *Lowerer, b: ir.exprs.BinaryExpr) ?ir.types.Type {
        return switch (b.op) {
            .eq, .ne, .lt, .le, .gt, .ge, .boolean_and, .boolean_or => .{ .prim = .bool },
            else => blk: {
                const lt = self.exprType(b.lhs);
                if (isFloatType(lt)) break :blk lt;
                const rt = self.exprType(b.rhs);
                if (isFloatType(rt)) break :blk rt;
                break :blk if (lt) |t| t else rt;
            },
        };
    }

    /// True for a resolved f32/f64 type. Float arithmetic must never use
    /// integer wrapping operators, even when the source overflow mode is
    /// `.wrapping`.
    fn isFloatType(t: ?ir.types.Type) bool {
        return if (t) |ty| ty == .prim and (ty.prim == .f32 or ty.prim == .f64) else false;
    }
    fn lowerStructMethod(
        self: *Lowerer,
        m: ir.bodies.StructMethod,
        struct_name: []const u8,
        generic_params: []const ast.GenericParam,
        owner_id: ir.spine.EntityId,
    ) !ast.FnDecl {
        const previous_callable_name = self.current_callable_name;
        self.current_callable_name = m.name;
        defer self.current_callable_name = previous_callable_name;

        var params_list: std.ArrayListUnmanaged(ast.FnParam) = .empty;
        const method_is_allocating = self.methodAllocates(owner_id, m);
        var callable_is_allocating = method_is_allocating;
        const allocator_param_index =
            (if (m.receiver != null) @as(usize, 1) else 0) + m.generic_params.len;
        const has_allocator_param = method_is_allocating;
        const previous_callable_effect = self.current_callable_is_allocating;
        self.current_callable_is_allocating = method_is_allocating;
        defer self.current_callable_is_allocating = previous_callable_effect;
        var generic_args: []ast.Type = &.{};
        if (generic_params.len > 0) {
            generic_args = try self.alloc.alloc(ast.Type, generic_params.len);
            for (generic_params, 0..) |gp, i| {
                generic_args[i] = .{ .named = try self.alloc.dupe(u8, gp.name) };
            }
        }
        const is_generic = generic_params.len > 0;
        const self_type = if (is_generic)
            ast.Type{ .generic = .{
                .name = try self.alloc.dupe(u8, struct_name),
                .params = generic_args,
            } }
        else
            ast.Type{ .named = try self.alloc.dupe(u8, struct_name) };

        if (m.receiver) |rec| {
            // A generic struct is emitted as a comptime type function. Keep the
            // receiver tied to that type so its AST matches the method return.
            const self_type_ptr = try self.allocType(self_type);

            const rec_ty: ast.Type = switch (rec) {
                .ref_ => ast.Type{
                    .ptr = .{
                        .elem = self_type_ptr,
                        .is_const = true,
                        .size = .one,
                    },
                },
                .mut_ref => ast.Type{
                    .ptr = .{
                        .elem = self_type_ptr,
                        .is_const = false,
                        .size = .one,
                    },
                },
                .owned => self_type,
            };

            try params_list.append(self.alloc, .{
                .name = "self",
                .ty = rec_ty,
            });
        }
        try self.appendFunctionGenericParams(m.generic_params, &params_list);
        if (method_is_allocating) {
            try params_list.append(self.alloc, .{
                .name = "allocator",
                .ty = ast.Type{ .named = "std.mem.Allocator" },
            });
        }

        for (m.params) |p| {
            const p_ty = try self.lowerType(p.ty);
            try params_list.append(self.alloc, .{
                .name = try self.alloc.dupe(u8, p.name),
                .ty = p_ty,
            });
        }
        const previous_parameter_names = self.current_parameter_names;
        self.current_parameter_names = params_list.items;
        defer self.current_parameter_names = previous_parameter_names;

        const owned_collection = self.matchOwnedCollection(m.body, m.ret, method_is_allocating);
        var ret_type = if (owned_collection != null)
            try self.lowerOwnedCollectionReturnType(m.ret)
        else if (is_generic and isSelfPath(m.ret))
            self_type
        else
            try self.lowerType(m.ret);
        const previous_float_context = self.float_context;
        self.float_context = isFloatType(m.ret);
        defer self.float_context = previous_float_context;

        if (m.name.len == 0) return error.MissingDefinitionName;
        if (m.body >= self.ir.bodies.exprs.len) return error.MissingExpressionNode;
        const fn_block: ast.Block = if (owned_collection) |plan|
            try self.lowerOwnedCollectionBlock(
                plan,
                m.ret,
                params_list.items,
                m.name,
            )
        else blk: {
            const expr_node = self.ir.bodies.exprs[m.body];
            break :blk switch (expr_node.kind) {
                .block => |be| try self.lowerBlock(be),
                else => .{
                    .stmts = &.{},
                    .expr = try self.allocExpr(try self.lowerExpr(m.body)),
                },
            };
        };
        callable_is_allocating = self.current_callable_is_allocating;
        const final_params = if (callable_is_allocating and !has_allocator_param) blk: {
            const params = try self.paramsWithAllocator(
                params_list.items,
                allocator_param_index,
            );
            params_list.deinit(self.alloc);
            break :blk params;
        } else try params_list.toOwnedSlice(self.alloc);
        if (callable_is_allocating) {
            ret_type = try self.ensureErrorUnion(ret_type);
        }

        return .{
            .name = try self.alloc.dupe(u8, m.name),
            .is_pub = switch (m.visibility) {
                .public => true,
                else => false,
            },
            .params = final_params,
            .ret_type = ret_type,
            .body = fn_block,
        };
    }

    /// Collect generic type parameters referenced by a struct's field types so
    /// a generic struct (e.g. `Fletcher<T>` with `a: T`) is recognized even
    /// when the StructBody did not populate its own `generic_params` list.
    /// Recurses through container types; appends each new parameter once.
    fn collectGenericTypeParams(self: *Lowerer, ty: ir.types.Type, out: *std.ArrayListUnmanaged(ast.GenericParam)) !void {
        switch (ty) {
            .path => |p| {
                // A generic type parameter reference (e.g. `a: T`) lowers to a
                // single-segment path with a resolved `id` of null — the symbol
                // table has no entity for a type parameter. Resolved nominal
                // types always carry a non-null id, so null id is a safe
                // discriminator for an undeclared generic parameter.
                if (p.segments.len == 1) {
                    const seg = p.segments[0];
                    if (seg.id == null and isGenericParamName(seg.name) and
                        !hasGenericParam(seg.name, out.items))
                    {
                        try out.append(self.alloc, .{
                            .name = try self.alloc.dupe(u8, seg.name),
                            .is_comptime = true,
                            .ty = null,
                        });
                    }
                }
            },
            .reference => |r| try self.collectGenericTypeParams(r.pointee, out),
            .raw_ptr => |r| try self.collectGenericTypeParams(r.pointee, out),
            .slice => |s| try self.collectGenericTypeParams(s.elem, out),
            .array => |a| try self.collectGenericTypeParams(a.elem, out),
            .tuple => |tup| for (tup) |t| try self.collectGenericTypeParams(t, out),
            .generic_inst => |gi| for (gi.args.params) |arg| try self.collectGenericTypeParams(arg, out),
            .external_nominal => |external| {
                for (external.args) |arg| try self.collectGenericTypeParams(arg, out);
            },
            .option => |inner| try self.collectGenericTypeParams(inner.*, out),
            .result => |r| {
                try self.collectGenericTypeParams(r.ok, out);
                try self.collectGenericTypeParams(r.err, out);
            },
            .boxed => |inner| try self.collectGenericTypeParams(inner.*, out),
            else => {},
        }
    }

    fn hasGenericParam(name: []const u8, list: []const ast.GenericParam) bool {
        for (list) |gp| {
            if (std.mem.eql(u8, gp.name, name)) return true;
        }
        return false;
    }

    /// Heuristic: a bare single segment whose name looks like a type parameter
    /// (single uppercase letter `T`/`U`/`V`, or an uppercase-leading identifier
    /// that is not a known resolved nominal type). Used only to recover generic
    /// structs when `StructBody.generic_params` is empty.
    fn isGenericParamName(name: []const u8) bool {
        if (name.len == 0) return false;
        // Single uppercase letter type params (T, U, V, ...)
        if (name.len == 1 and name[0] >= 'A' and name[0] <= 'Z') return true;
        // Already declared as a generic param somewhere? Treat any
        // non-resolved uppercase-leading identifier as a type parameter.
        if (name[0] >= 'A' and name[0] <= 'Z') return true;
        return false;
    }

    fn lowerTestEntity(self: *Lowerer, entity_id: ir.spine.EntityId, ent: ir.spine.Entity) !?ast.TestDecl {
        const previous_module_id = self.current_module_id;
        self.current_module_id = (try self.owningModuleEntity(entity_id)) orelse previous_module_id;
        defer self.current_module_id = previous_module_id;
        const previous_struct_id = self.current_struct_id;
        self.current_struct_id =
            (try self.inherentStructForEntity(entity_id)) orelse previous_struct_id;
        defer self.current_struct_id = previous_struct_id;
        const previous_callable_name = self.current_callable_name;
        self.current_callable_name = ent.name;
        defer self.current_callable_name = previous_callable_name;

        if (entity_id >= self.ir.bodies.bodies.len) return error.MissingBodyId;
        const body_kind = self.ir.bodies.bodies[entity_id];

        const fb = switch (body_kind) {
            .fn_ => |value| value,
            else => return error.DeclarationBodyMismatch,
        };
        const previous_callable_effect = self.current_callable_is_allocating;
        const stable_callable_effect = self.callableAllocates(entity_id, fb.is_allocating);
        self.current_callable_is_allocating = stable_callable_effect;
        defer self.current_callable_is_allocating = previous_callable_effect;
        if (fb.body >= self.ir.bodies.exprs.len) return error.MissingExpressionNode;

        const expr_node = self.ir.bodies.exprs[fb.body];

        var test_block: ast.Block = blk: {
            const previous_test_context = self.lowering_test_entity;
            self.lowering_test_entity = true;
            defer self.lowering_test_entity = previous_test_context;
            break :blk switch (expr_node.kind) {
                .block => |be| try self.lowerBlock(be),
                else => .{
                    .stmts = &.{},
                    .expr = try self.allocExpr(try self.lowerExpr(fb.body)),
                },
            };
        };

        const test_is_allocating = self.current_callable_is_allocating;
        if (test_is_allocating) {
            const std_target = try self.allocExpr(.{ .ident = "std" });
            const testing_target = try self.allocExpr(.{ .field_access = .{
                .target = std_target,
                .field_name = "testing",
            } });
            const allocator_init: ast.Expr = .{ .field_access = .{
                .target = testing_target,
                .field_name = "allocator",
            } };
            const stmts = try self.alloc.alloc(ast.Stmt, test_block.stmts.len + 1);
            stmts[0] = .{ .let_stmt = .{
                .name = "allocator",
                .ty = ast.Type{ .named = "std.mem.Allocator" },
                .init = allocator_init,
            } };
            @memcpy(stmts[1..], test_block.stmts);
            test_block.stmts = stmts;
        }

        return .{
            .name = try self.alloc.dupe(u8, ent.name),
            .body = test_block,
        };
    }

    // -------------------------------------------------------------------------
    // Type Lowering
    // -------------------------------------------------------------------------

    /// A path can come from a partially recovered sidecar or from a temporary
    /// model slice. Reject null-ish/corrupt metadata before indexing it.
    fn validPathSegments(segments: []const ir.types.PathSegment) bool {
        if (segments.len == 0 or segments.len > 4096) return false;
        const address = @intFromPtr(segments.ptr);
        return address >= 4096 and address % @alignOf(ir.types.PathSegment) == 0;
    }

    /// Validate a path name before passing it to an allocator. In particular,
    /// a stale slice can carry a huge length even when its pointer is non-null.
    fn validPathName(name: []const u8) bool {
        if (name.len == 0 or name.len > 4096) return false;
        if (@intFromPtr(name.ptr) < 4096) return false;
        for (name) |c| {
            if (c == 0) return false;
        }
        return true;
    }

    fn lastPathSegment(segments: []const ir.types.PathSegment) ?ir.types.PathSegment {
        var last: ?ir.types.PathSegment = null;
        for (segments) |segment| {
            last = segment;
        }
        return last;
    }

    fn genericPathParam(segments: []const ir.types.PathSegment) ?[]const u8 {
        if (segments.len < 2) return null;
        const first = segments[0];
        if (first.id != null or !validPathName(first.name)) return null;
        if (first.name.len != 1) return null;
        if (first.name[0] < 'A' or first.name[0] > 'Z') return null;
        return first.name;
    }
    fn isSelfPath(ty: ir.types.Type) bool {
        return switch (ty) {
            .path => |p| blk: {
                if (!validPathSegments(p.segments)) break :blk false;
                const last = lastPathSegment(p.segments) orelse break :blk false;
                break :blk validPathName(last.name) and std.mem.eql(u8, last.name, "Self");
            },
            else => false,
        };
    }

    fn pathTypeEquals(a: ir.types.Path, b: ir.types.Path) bool {
        if (a.segments.len != b.segments.len) return false;
        for (a.segments, b.segments) |left, right| {
            if (!std.mem.eql(u8, left.name, right.name)) return false;
        }
        return true;
    }

    fn arrayLenEquals(a: ir.types.ArrayLen, b: ir.types.ArrayLen) bool {
        return switch (a) {
            .literal => |av| switch (b) {
                .literal => |bv| av == bv,
                else => false,
            },
            .generic => |av| switch (b) {
                .generic => |bv| av == bv,
                else => false,
            },
        };
    }

    fn typeSliceEquals(a: []const ir.types.Type, b: []const ir.types.Type) bool {
        if (a.len != b.len) return false;
        for (a, 0..) |value, index| {
            if (!typeEquals(value, b[index])) return false;
        }
        return true;
    }

    fn typeEquals(a: ir.types.Type, b: ir.types.Type) bool {
        return switch (a) {
            .path => |ap| switch (b) {
                .path => |bp| pathTypeEquals(ap, bp),
                else => false,
            },
            .external_nominal => |ae| switch (b) {
                .external_nominal => |be| {
                    if (ae.path.len != be.path.len or ae.args.len != be.args.len) return false;
                    for (ae.path, be.path) |left, right| {
                        if (!std.mem.eql(u8, left, right)) return false;
                    }
                    return typeSliceEquals(ae.args, be.args);
                },
                else => false,
            },
            .prim => |ap| switch (b) {
                .prim => |bp| ap == bp,
                else => false,
            },
            .reference => |ap| switch (b) {
                .reference => |bp| ap.mut == bp.mut and typeEquals(ap.pointee, bp.pointee),
                else => false,
            },
            .raw_ptr => |ap| switch (b) {
                .raw_ptr => |bp| ap.mut == bp.mut and typeEquals(ap.pointee, bp.pointee),
                else => false,
            },
            .slice => |ap| switch (b) {
                .slice => |bp| ap.const_ == bp.const_ and typeEquals(ap.elem, bp.elem),
                else => false,
            },
            .array => |ap| switch (b) {
                .array => |bp| arrayLenEquals(ap.len, bp.len) and typeEquals(ap.elem, bp.elem),
                else => false,
            },
            .tuple => |ap| switch (b) {
                .tuple => |bp| typeSliceEquals(ap, bp),
                else => false,
            },
            .fn_ptr => |ap| switch (b) {
                .fn_ptr => |bp| typeSliceEquals(ap.params, bp.params) and typeEquals(ap.ret, bp.ret),
                else => false,
            },
            .generic_inst => |ap| switch (b) {
                .generic_inst => |bp| ap.decl == bp.decl and
                    typeSliceEquals(ap.args.params, bp.args.params),
                else => false,
            },
            .option => |ap| switch (b) {
                .option => |bp| typeEquals(ap.*, bp.*),
                else => false,
            },
            .result => |ap| switch (b) {
                .result => |bp| ap.is_error_unionable == bp.is_error_unionable and
                    typeEquals(ap.ok, bp.ok) and typeEquals(ap.err, bp.err),
                else => false,
            },
            .boxed => |ap| switch (b) {
                .boxed => |bp| typeEquals(ap.*, bp.*),
                else => false,
            },
            .unsupported => |ap| switch (b) {
                .unsupported => |bp| ap.reason == bp.reason and
                    std.mem.eql(u8, ap.message, bp.message),
                else => false,
            },
        };
    }

    fn genericParamIndex(
        pattern: ir.types.Type,
        names: []const []const u8,
    ) ?usize {
        return switch (pattern) {
            .path => |path| if (path.segments.len == 1 and path.segments[0].id == null) blk: {
                for (names, 0..) |name, index| {
                    if (std.mem.eql(u8, name, path.segments[0].name)) break :blk index;
                }
                break :blk null;
            } else null,
            else => null,
        };
    }

    fn matchGenericType(
        pattern: ir.types.Type,
        actual: ir.types.Type,
        names: []const []const u8,
        slots: []?ir.types.Type,
    ) void {
        if (genericParamIndex(pattern, names)) |index| {
            if (slots[index] == null) slots[index] = actual;
            return;
        }

        switch (pattern) {
            .external_nominal => |p| switch (actual) {
                .external_nominal => |a| {
                    if (p.path.len != a.path.len) return;
                    for (p.path, a.path) |left, right| {
                        if (!std.mem.eql(u8, left, right)) return;
                    }
                    const count = @min(p.args.len, a.args.len);
                    for (0..count) |index| {
                        matchGenericType(p.args[index], a.args[index], names, slots);
                    }
                },
                else => {},
            },
            .reference => |p| switch (actual) {
                .reference => |a| matchGenericType(p.pointee, a.pointee, names, slots),
                else => {},
            },
            .raw_ptr => |p| switch (actual) {
                .raw_ptr => |a| matchGenericType(p.pointee, a.pointee, names, slots),
                else => {},
            },
            .slice => |p| switch (actual) {
                .slice => |a| matchGenericType(p.elem, a.elem, names, slots),
                else => {},
            },
            .array => |p| switch (actual) {
                .array => |a| matchGenericType(p.elem, a.elem, names, slots),
                else => {},
            },
            .tuple => |p| switch (actual) {
                .tuple => |a| {
                    const count = @min(p.len, a.len);
                    for (0..count) |index| matchGenericType(p[index], a[index], names, slots);
                },
                else => {},
            },
            .generic_inst => |p| switch (actual) {
                .generic_inst => |a| {
                    if (p.decl != a.decl) return;
                    const count = @min(p.args.params.len, a.args.params.len);
                    for (0..count) |index| {
                        matchGenericType(p.args.params[index], a.args.params[index], names, slots);
                    }
                },
                else => {},
            },
            .option => |p| switch (actual) {
                .option => |a| matchGenericType(p.*, a.*, names, slots),
                else => {},
            },
            .result => |p| switch (actual) {
                .result => |a| {
                    matchGenericType(p.ok, a.ok, names, slots);
                    matchGenericType(p.err, a.err, names, slots);
                },
                else => {},
            },
            .boxed => |p| switch (actual) {
                .boxed => |a| matchGenericType(p.*, a.*, names, slots),
                else => {},
            },
            else => {},
        }
    }

    fn concreteExprType(self: *Lowerer, expr_id: ir.exprs.NodeId) ?ir.types.Type {
        if (expr_id >= self.ir.bodies.exprs.len) return null;
        const expr = self.ir.bodies.exprs[expr_id];
        const type_id = expr.ty orelse return null;
        if (type_id < self.ir.types.len) return self.ir.types[type_id];
        if (type_id < self.ir.bodies.types.len) return self.ir.bodies.types[type_id];
        return null;
    }

    fn inferGenericArgs(
        self: *Lowerer,
        names: []const []const u8,
        param_types: []const ir.types.Type,
        arg_ids: []const ir.exprs.NodeId,
    ) !?[]const ir.types.Type {
        if (names.len == 0) return null;
        const slots = try self.alloc.alloc(?ir.types.Type, names.len);
        defer self.alloc.free(slots);
        for (slots) |*slot| slot.* = null;

        const count = @min(param_types.len, arg_ids.len);
        for (0..count) |index| {
            if (self.concreteExprType(arg_ids[index])) |actual| {
                matchGenericType(param_types[index], actual, names, slots);
            }
        }

        var complete = true;
        for (slots) |slot| {
            if (slot == null) {
                complete = false;
                break;
            }
        }
        if (!complete) return null;

        const result = try self.alloc.alloc(ir.types.Type, names.len);
        for (slots, 0..) |slot, index| result[index] = slot.?;
        return result;
    }

    fn genericArgsFromExprType(
        self: *Lowerer,
        expr_id: ir.exprs.NodeId,
        def: ir.spine.EntityId,
    ) ?[]const ir.types.Type {
        const actual = self.concreteExprType(expr_id) orelse return null;
        return switch (actual) {
            .generic_inst => |inst| if (inst.decl == def) inst.args.params else null,
            else => null,
        };
    }

    fn genericParamsForDef(
        self: *Lowerer,
        def: ir.spine.EntityId,
    ) ?[]const []const u8 {
        if (def >= self.ir.bodies.bodies.len) return null;
        return switch (self.ir.bodies.bodies[def]) {
            .fn_ => |fb| if (fb.generic_params.len > 0) fb.generic_params else null,
            .struct_ => |sb| if (sb.generic_params.len > 0) sb.generic_params else null,
            else => null,
        };
    }

    fn genericArityForDef(self: *Lowerer, def: ir.spine.EntityId) !usize {
        const entity = self.ir.graph.symbol_table.get(def) orelse {
            return error.MissingDefinition;
        };
        // Local pattern bindings and values have no generic application.
        if (entity.kind == .field or entity.kind == .const_ or entity.kind == .static_) return 0;
        if (def < self.ir.bodies.bodies.len) {
            switch (self.ir.bodies.bodies[def]) {
                .fn_ => |fb| return fb.generic_params.len,
                .struct_ => |sb| return sb.generic_params.len,
                else => {},
            }
        }
        const method = self.structMethodForDef(def) orelse {
            return error.GenericDefinitionMismatch;
        };
        return method.generic_params.len;
    }

    fn inferredCallArgs(
        self: *Lowerer,
        def: ir.spine.EntityId,
        arg_ids: []const ir.exprs.NodeId,
    ) !?[]const ir.types.Type {
        const names = self.genericParamsForDef(def) orelse return null;
        if (def >= self.ir.bodies.bodies.len) return null;

        switch (self.ir.bodies.bodies[def]) {
            .fn_ => |fb| {
                const param_types = try self.alloc.alloc(ir.types.Type, fb.params.len);
                defer self.alloc.free(param_types);
                for (fb.params, 0..) |param, index| param_types[index] = param.ty;
                return self.inferGenericArgs(names, param_types, arg_ids);
            },
            .struct_ => |sb| {
                const field_types = try self.alloc.alloc(ir.types.Type, sb.fields.len);
                defer self.alloc.free(field_types);
                for (sb.fields, 0..) |field, index| field_types[index] = field.ty;
                return self.inferGenericArgs(names, field_types, arg_ids);
            },
            else => return null,
        }
    }

    fn structMethodForDef(self: *Lowerer, def: ir.spine.EntityId) ?ir.bodies.StructMethod {
        const entity = self.ir.graph.symbol_table.get(def) orelse return null;
        var parent_id = entity.parent;
        while (parent_id) |id| {
            if (id < self.ir.bodies.bodies.len) {
                switch (self.ir.bodies.bodies[id]) {
                    .struct_ => |sb| {
                        for (sb.methods) |method| {
                            if (std.mem.eql(u8, method.name, entity.name)) return method;
                        }
                    },
                    else => {},
                }
            }
            const parent = self.ir.graph.symbol_table.get(id) orelse break;
            parent_id = parent.parent;
        }
        return null;
    }
    fn methodAllocates(
        self: *Lowerer,
        owner_id: ir.spine.EntityId,
        method: ir.bodies.StructMethod,
    ) bool {
        if (self.methodEntityForDefinition(owner_id, method)) |method_id| {
            return self.callableAllocates(method_id, method.is_allocating);
        }
        if (method.is_allocating) return true;
        const effects: []const bool = if (self.allocation_effects) |values| values else &.{};
        const scanner: AllocationEffectScanner = .{
            .exprs = self.ir.bodies.exprs,
            .stmts = self.ir.bodies.stmts,
            .effects = effects,
        };
        return scanner.exprAllocates(method.body);
    }

    fn directCallAllocates(self: *Lowerer, def: ir.spine.EntityId) bool {
        if (self.allocation_effects) |effects| {
            if (def < effects.len and effects[def]) return true;
        }
        if (self.structMethodForDef(def)) |method| {
            if (method.is_allocating) return true;
        }
        if (def >= self.ir.bodies.bodies.len) return false;
        return switch (self.ir.bodies.bodies[def]) {
            .fn_ => |function| function.is_allocating,
            else => false,
        };
    }
    fn directFreeCallArgumentType(
        self: *Lowerer,
        call_kind: ir.exprs.CallKind,
        arg_index: usize,
    ) ?ir.types.Type {
        const def = switch (call_kind) {
            .free => |free_def| free_def,
            else => return null,
        };
        if (def >= self.ir.bodies.bodies.len) return null;
        const params = switch (self.ir.bodies.bodies[def]) {
            .fn_ => |function| function.params,
            else => return null,
        };
        if (arg_index >= params.len) return null;
        return params[arg_index].ty;
    }
    fn methodCallArgumentType(
        self: *Lowerer,
        method_def: ir.spine.EntityId,
        arg_index: usize,
    ) ?ir.types.Type {
        const method = self.structMethodForDef(method_def) orelse return null;
        if (arg_index >= method.params.len) return null;
        return method.params[arg_index].ty;
    }

    fn lowerDirectCallResult(
        self: *Lowerer,
        expr_id: ir.exprs.NodeId,
        expr: ast.Expr,
        allocates: bool,
    ) !ast.Expr {
        if (!allocates) return expr;
        self.current_callable_is_allocating = true;
        if (self.explicit_try_expr) |explicit_expr| {
            if (explicit_expr == expr_id) return expr;
        }
        return .{ .unary_op = .{
            .op = .try_op,
            .operand = try self.allocExpr(expr),
        } };
    }

    fn inferredMethodArgs(
        self: *Lowerer,
        def: ir.spine.EntityId,
        arg_ids: []const ir.exprs.NodeId,
    ) !?[]const ir.types.Type {
        const method = self.structMethodForDef(def) orelse return null;
        if (method.generic_params.len == 0) return null;
        const param_types = try self.alloc.alloc(ir.types.Type, method.params.len);
        defer self.alloc.free(param_types);
        for (method.params, 0..) |param, index| param_types[index] = param.ty;
        return self.inferGenericArgs(method.generic_params, param_types, arg_ids);
    }

    fn inferredStructLitArgs(
        self: *Lowerer,
        def: ir.spine.EntityId,
        fields: []const ir.exprs.FieldInit,
    ) !?[]const ir.types.Type {
        const names = self.genericParamsForDef(def) orelse return null;
        if (def >= self.ir.bodies.bodies.len) return null;
        const sb = switch (self.ir.bodies.bodies[def]) {
            .struct_ => |body| body,
            else => return null,
        };

        const slots = try self.alloc.alloc(?ir.types.Type, names.len);
        defer self.alloc.free(slots);
        for (slots) |*slot| slot.* = null;
        for (fields) |field| {
            if (self.concreteExprType(field.value)) |actual| {
                for (sb.fields) |declared| {
                    if (std.mem.eql(u8, declared.name, field.field)) {
                        matchGenericType(declared.ty, actual, names, slots);
                        break;
                    }
                }
            }
        }

        var complete = true;
        for (slots) |slot| {
            if (slot == null) {
                complete = false;
                break;
            }
        }
        if (!complete) return null;

        const result = try self.alloc.alloc(ir.types.Type, names.len);
        for (slots, 0..) |slot, index| result[index] = slot.?;
        return result;
    }
    /// Select concrete arguments for this expression only. A missing
    /// preference is intentionally not resolved by declaration-wide order:
    /// two call sites may instantiate the same generic with different types.
    fn claimInstantiation(
        self: *Lowerer,
        def: ir.spine.EntityId,
        preferred: ?[]const ir.types.Type,
    ) ?ir.types.GenericArgs {
        const args = preferred orelse return null;
        for (self.ir.instantiations) |inst| {
            if (inst.generic_id == def and typeSliceEquals(inst.args.params, args)) {
                return inst.args;
            }
        }
        return .{ .params = args };
    }

    fn lowerGenericArgs(
        self: *Lowerer,
        def: ir.spine.EntityId,
        preferred: ?[]const ir.types.Type,
    ) ![]const ast.Type {
        const expected_arity = try self.genericArityForDef(def);
        const selected = if (preferred) |args| blk: {
            if (args.len != expected_arity) return error.GenericArgumentArityMismatch;
            break :blk self.claimInstantiation(def, args) orelse ir.types.GenericArgs{ .params = args };
        } else blk: {
            if (expected_arity != 0) return error.GenericInferenceFailed;
            break :blk ir.types.GenericArgs{ .params = &.{} };
        };
        if (selected.params.len != expected_arity) {
            return error.GenericArgumentArityMismatch;
        }
        if (selected.params.len == 0) return &.{};
        const result = try self.alloc.alloc(ast.Type, selected.params.len);
        for (selected.params, 0..) |param, index| {
            result[index] = try self.lowerType(param);
        }
        return result;
    }

    fn lowerCallGenericArgs(
        self: *Lowerer,
        expr_id: ir.exprs.NodeId,
        def: ir.spine.EntityId,
        arg_ids: []const ir.exprs.NodeId,
    ) ![]const ast.Type {
        if (self.concreteExprType(expr_id)) |actual| {
            switch (actual) {
                .generic_inst => |inst| {
                    if (inst.decl == def) {
                        return self.lowerGenericArgs(def, inst.args.params);
                    }
                },
                else => {},
            }
        }
        if (try self.inferredCallArgs(def, arg_ids)) |inferred| {
            return self.lowerGenericArgs(def, inferred);
        }
        if (try self.inferredMethodArgs(def, arg_ids)) |inferred| {
            return self.lowerGenericArgs(def, inferred);
        }
        return self.lowerGenericArgs(def, null);
    }
    /// Lower a tuple-struct constructor as a typed struct literal. A
    /// constructor's generic arguments belong to the type application
    /// (`Foo(T)`), while its source arguments initialize tuple fields.
    fn lowerTupleStructConstructor(
        self: *Lowerer,
        def: ir.spine.EntityId,
        generic_args: []const ast.Type,
        args: []const ast.Expr,
    ) !ast.Expr {
        if (def >= self.ir.bodies.bodies.len) return error.MissingBodyId;
        const entity = self.ir.graph.symbol_table.get(def) orelse {
            return error.MissingDefinition;
        };
        if (entity.kind != .struct_) return error.InvalidConstructorDefinition;
        const struct_body = switch (self.ir.bodies.bodies[def]) {
            .struct_ => |body| body,
            else => return error.DeclarationBodyMismatch,
        };
        if (struct_body.layout != .tuple) return error.InvalidConstructorDefinition;
        if (args.len != struct_body.fields.len) return error.ConstructorArityMismatch;

        const name = try self.lowerResolvedEntityName(def);
        const type_name: ast.Type = if (generic_args.len > 0)
            ast.Type{ .generic = .{ .name = name, .params = generic_args } }
        else
            ast.Type{ .named = name };

        var fields = try self.alloc.alloc(ast.StructInitField, args.len);
        errdefer self.alloc.free(fields);
        for (args, 0..) |arg, index| {
            const field_name = try std.fmt.allocPrint(self.alloc, "{d}", .{index});
            errdefer self.alloc.free(field_name);
            fields[index] = .{
                .name = field_name,
                .expr = arg,
            };
        }

        return .{
            .struct_init = .{
                .type_name = type_name,
                .fields = fields,
            },
        };
    }

    fn externalPathEqual(path: []const []const u8, expected: []const []const u8) bool {
        if (path.len != expected.len) return false;
        for (path, expected) |actual, wanted| {
            if (!std.mem.eql(u8, actual, wanted)) return false;
        }
        return true;
    }

    fn lowerExternalNominal(
        self: *Lowerer,
        external: ir.types.ExternalNominal,
    ) !ast.Type {
        if (external.path.len == 0) return error.InvalidTypePath;

        if (externalPathEqual(external.path, &.{ "core", "option", "Option" }) or
            externalPathEqual(external.path, &.{ "std", "option", "Option" }))
        {
            if (external.args.len != 1) return error.GenericArgumentArityMismatch;
            return .{ .opt = try self.allocType(try self.lowerType(external.args[0])) };
        }

        if (externalPathEqual(external.path, &.{ "core", "result", "Result" }) or
            externalPathEqual(external.path, &.{ "std", "result", "Result" }))
        {
            if (external.args.len != 2) return error.GenericArgumentArityMismatch;
            return .{ .err_union = .{
                .err_set = null,
                .payload = try self.allocType(try self.lowerType(external.args[0])),
            } };
        }

        if (externalPathEqual(external.path, &.{ "std", "string", "String" })) {
            if (external.args.len != 0) return error.GenericArgumentArityMismatch;
            return .{ .named = "[]const u8" };
        }

        if (isAllocVecPath(external.path)) {
            if (external.args.len != 1) return error.GenericArgumentArityMismatch;
            const params = try self.alloc.alloc(ast.Type, 1);
            errdefer self.alloc.free(params);
            params[0] = try self.lowerType(external.args[0]);
            return .{ .generic = .{
                .name = try self.alloc.dupe(u8, "std.ArrayListUnmanaged"),
                .params = params,
            } };
        }

        if (externalPathEqual(external.path, &.{
            "core",
            "hash",
            "BuildHasherDefault",
        }) or externalPathEqual(external.path, &.{
            "std",
            "hash",
            "BuildHasherDefault",
        })) {
            if (external.args.len != 1) return error.GenericArgumentArityMismatch;
            try self.markRuntimeImport();
            const params = try self.alloc.alloc(ast.Type, 1);
            params[0] = try self.lowerType(external.args[0]);
            return .{ .generic = .{
                .name = try self.alloc.dupe(u8, "r2z.BuildHasherDefault"),
                .params = params,
            } };
        }

        // Unknown external nominals have no faithful Zig equivalent here.
        // Do not emit a plausible-looking name or a null type.
        return error.UnsupportedExternalNominalType;
    }

    fn isTypeDefinition(kind: ir.spine.EntityKind) bool {
        return switch (kind) {
            .struct_, .enum_, .union_, .trait_, .type_alias => true,
            else => false,
        };
    }

    fn validateTypePath(self: *Lowerer, path: ir.types.Path) !void {
        if (!validPathSegments(path.segments)) return error.InvalidTypePath;
        for (path.segments) |segment| {
            if (!validPathName(segment.name)) return error.InvalidTypePath;
            if (segment.id) |id| {
                const entity = self.ir.graph.symbol_table.get(id) orelse {
                    return error.MissingTypeDefinition;
                };
                if (!isTypeDefinition(entity.kind)) return error.InvalidTypeDefinition;
            }
        }
    }

    pub fn lowerType(self: *Lowerer, ir_ty: ir.types.Type) anyerror!ast.Type {
        // Structural lowering is arena-backed and always safe to retain. The
        // pluggable strategy is consulted only for standard generic name
        // mapping (returns `.named` values — never transient pointers).
        return switch (ir_ty) {
            .prim => |p| ast.Type{ .prim = lowerPrim(p) },
            .slice => |s| ast.Type{
                .slice = .{
                    .elem = try self.allocType(try self.lowerType(s.elem)),
                    .is_const = s.const_,
                },
            },
            .reference => |r| ast.Type{
                .ptr = .{
                    .elem = try self.allocType(try self.lowerType(r.pointee)),
                    .is_const = !r.mut,
                    .size = .one,
                },
            },
            .raw_ptr => |r| ast.Type{
                .ptr = .{
                    .elem = try self.allocType(try self.lowerType(r.pointee)),
                    .is_const = !r.mut,
                    .size = .many,
                },
            },
            .array => |a| blk: {
                const elem_ty = try self.allocType(try self.lowerType(a.elem));
                switch (a.len) {
                    .literal => |len| break :blk ast.Type{
                        .array = .{
                            .elem = elem_ty,
                            .len = len,
                        },
                    },
                    .generic => break :blk ast.Type{
                        .slice = .{
                            .elem = elem_ty,
                            .is_const = true,
                        },
                    },
                }
            },
            .option => |opt| ast.Type{
                .opt = try self.allocType(try self.lowerType(opt.*)),
            },
            .result => |r| blk: {
                if (r.is_error_unionable) {
                    const payload_ty = try self.allocType(try self.lowerType(r.ok));
                    break :blk ast.Type{
                        .err_union = .{
                            .err_set = null,
                            .payload = payload_ty,
                        },
                    };
                } else {
                    break :blk ast.Type{ .named = "anyerror" };
                }
            },
            .tuple => |elems| blk: {
                var arr = try self.alloc.alloc(ast.Type, elems.len);
                for (elems, 0..) |e, i| {
                    arr[i] = try self.lowerType(e);
                }
                break :blk ast.Type{ .tuple = arr };
            },
            .path => |p| blk: {
                try self.validateTypePath(p);
                if (genericPathParam(p.segments)) |generic_name| {
                    break :blk ast.Type{ .named = try self.alloc.dupe(u8, generic_name) };
                }
                const last_segment = lastPathSegment(p.segments) orelse {
                    return error.InvalidTypePath;
                };
                if (try self.strat.lowerStdGeneric(last_segment.name, &.{})) |std_ty| {
                    break :blk std_ty;
                }
                if (last_segment.id) |def| {
                    break :blk ast.Type{
                        .named = try self.lowerResolvedEntityName(def),
                    };
                }
                break :blk ast.Type{ .named = try self.alloc.dupe(u8, last_segment.name) };
            },
            .external_nominal => |external| try self.lowerExternalNominal(external),
            .generic_inst => |gi| blk: {
                const entity = self.ir.graph.symbol_table.get(gi.decl) orelse {
                    return error.MissingTypeDefinition;
                };
                if (!isTypeDefinition(entity.kind)) return error.InvalidTypeDefinition;
                const decl_name = entity.renamed_to orelse entity.name;
                if (decl_name.len == 0) return error.MissingTypeDefinition;
                const expected_arity = try self.genericArityForDef(gi.decl);
                if (gi.args.params.len != expected_arity) {
                    return error.GenericArgumentArityMismatch;
                }
                if (try self.strat.lowerStdGeneric(decl_name, gi.args.params)) |std_ty| {
                    break :blk std_ty;
                }
                var params = try self.alloc.alloc(ast.Type, gi.args.params.len);
                for (gi.args.params, 0..) |p, i| {
                    params[i] = try self.lowerType(p);
                }
                break :blk ast.Type{
                    .generic = .{
                        .name = try self.lowerResolvedEntityName(gi.decl),
                        .params = params,
                    },
                };
            },
            .boxed => |b| try self.lowerType(b.*),
            .fn_ptr => ast.Type{ .named = "fn_ptr" },
            .unsupported => return error.UnsupportedType,
        };
    }

    fn lowerPrim(p: ir.types.Prim) ast.Prim {
        return switch (p) {
            .i8 => .i8,
            .i16 => .i16,
            .i32 => .i32,
            .i64 => .i64,
            .i128 => .i128,
            .u8 => .u8,
            .u16 => .u16,
            .u32 => .u32,
            .u64 => .u64,
            .u128 => .u128,
            .isize => .isize,
            .usize => .usize,
            .f32 => .f32,
            .f64 => .f64,
            .bool => .bool,
            .char => .u21,
            .unit => .void_type,
            .never => .noreturn_type,
        };
    }

    // -------------------------------------------------------------------------
    // Expression Lowering
    // -------------------------------------------------------------------------

    /// True when the declared type of `expr_id` is (or reference-wraps) an array.
    fn receiverIsArray(self: *const Lowerer, expr_id: ir.exprs.NodeId) bool {
        if (expr_id >= self.ir.bodies.exprs.len) return false;
        const e = self.ir.bodies.exprs[expr_id];
        if (e.ty) |tid| {
            if (tid < self.ir.bodies.types.len) {
                var t = self.ir.bodies.types[tid];
                while (true) {
                    switch (t) {
                        .array => return true,
                        .reference => |r| t = r.pointee,
                        else => return false,
                    }
                }
            }
        }
        return false;
    }

    /// Grok the lowered receiver when it is a `&x` / `&mut x` unary-expression node,
    /// producing `x` for use as a by-value operand.
    fn lowerDeref(self: *Lowerer, recv_node: ir.exprs.NodeId, receiver: *const ast.Expr) anyerror!*const ast.Expr {
        if (recv_node < self.ir.bodies.exprs.len) {
            const re = self.ir.bodies.exprs[recv_node];
            if (re.kind == .unary and re.kind.unary.op == .ref) {
                return receiver;
            }
        }
        return receiver;
    }

    /// Slice-coercion helper: cite `receiver[0..]` for array receivers, else the
    /// receiver expression itself (slices/references are already slice-compatible).
    fn lowerAsRef(self: *Lowerer, receiver_node: ir.exprs.NodeId, receiver: *const ast.Expr) anyerror!*const ast.Expr {
        if (self.receiverIsArray(receiver_node)) {
            const zero = try self.allocExpr(ast.Expr{ .lit = .{ .int = 0 } });
            const open = try self.allocExpr(ast.Expr{ .range = .{ .start = zero, .end = null } });
            var args = try self.alloc.alloc(ast.Expr, 2);
            args[0] = receiver.*;
            args[1] = open.*;
            const result = try self.allocExpr(ast.Expr{ .builtin = .{ .name = "index", .args = args } });
            return result;
        }
        return receiver;
    }

    fn validateMethodTopology(
        self: *const Lowerer,
        method: ir.spine.Entity,
    ) !void {
        if (method.kind == .field) return;
        if (method.kind != .fn_) return error.GenericDefinitionMismatch;

        const parent_id = method.parent orelse return error.GenericDefinitionMismatch;
        const parent = self.ir.graph.symbol_table.get(parent_id) orelse {
            return error.GenericDefinitionMismatch;
        };
        switch (parent.kind) {
            .trait_, .struct_, .enum_, .union_ => {},
            .impl_ => {
                const target_id = parent.parent orelse return error.GenericDefinitionMismatch;
                const target = self.ir.graph.symbol_table.get(target_id) orelse {
                    return error.GenericDefinitionMismatch;
                };
                switch (target.kind) {
                    .struct_, .enum_, .union_ => {},
                    else => return error.GenericDefinitionMismatch,
                }
            },
            else => return error.GenericDefinitionMismatch,
        }
    }
    const RecognizedStdMethod = enum {
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
        slice_chunks,

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

    /// Classify a resolver-recognized standard method from the typed receiver.
    /// Keeping this type-aware prevents an inherent method with the same name
    /// from being mistaken for a prelude method.
    fn lookupRecognizedStdMethod(
        self: *Lowerer,
        receiver_node: ir.exprs.NodeId,
        method_name: []const u8,
    ) ?RecognizedStdMethod {
        const receiver_ty = self.exprType(receiver_node) orelse return null;
        var cur_t = receiver_ty;
        while (true) {
            switch (cur_t) {
                .reference => |r| cur_t = r.pointee,
                .raw_ptr => |ptr| cur_t = ptr.pointee,
                .boxed => |boxed| cur_t = boxed.*,
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
                if (std.mem.eql(u8, method_name, "chunks")) return .slice_chunks;
            },
            .prim => |prim| switch (prim) {
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
            },
            else => {},
        }

        if (std.mem.eql(u8, method_name, "default")) return .default;
        if (std.mem.eql(u8, method_name, "clone")) return .clone;
        return null;
    }

    fn lowerUnsupportedStdMethod(
        self: *Lowerer,
        method_name: []const u8,
    ) !*const ast.Expr {
        _ = self;
        _ = method_name;
        return error.UnsupportedStandardMethod;
    }

    /// Lower a prelude method call to native Zig or an explicit unsupported
    /// node. Returns null only for an ordinary method that the resolver did
    /// not classify as a standard-library method.
    fn lowerStdMethodCall(
        self: *Lowerer,
        method_name: []const u8,
        receiver_node: ir.exprs.NodeId,
        receiver: *const ast.Expr,
        args: []const ast.Expr,
    ) anyerror!?*const ast.Expr {
        const recognized_std_method = self.lookupRecognizedStdMethod(receiver_node, method_name);
        if (std.mem.eql(u8, method_name, "as_ref") or
            std.mem.eql(u8, method_name, "as_bytes") or
            std.mem.eql(u8, method_name, "borrow") or
            std.mem.eql(u8, method_name, "as_slice"))
        {
            const result = try self.lowerAsRef(receiver_node, receiver);
            return result;
        }
        if (std.mem.eql(u8, method_name, "clone") or
            std.mem.eql(u8, method_name, "to_vec"))
        {
            // Zig assignments (and by-value params/returns) copy already.
            return receiver;
        }
        if (std.mem.eql(u8, method_name, "len")) {
            const result = try self.allocExpr(ast.Expr{
                .field_access = .{
                    .target = receiver,
                    .field_name = try self.alloc.dupe(u8, "len"),
                },
            });
            return result;
        }
        if (std.mem.eql(u8, method_name, "is_empty")) {
            if (args.len != 0) return null;
            const len = try self.allocExpr(ast.Expr{
                .field_access = .{
                    .target = receiver,
                    .field_name = try self.alloc.dupe(u8, "len"),
                },
            });
            const zero = try self.allocExpr(ast.Expr{ .lit = .{ .int = 0 } });
            const result = try self.allocExpr(ast.Expr{
                .bin_op = .{ .op = .equal, .lhs = len, .rhs = zero },
            });
            return result;
        }
        if (recognized_std_method) |std_method| {
            switch (std_method) {
                .slice_chunks => {
                    if (args.len != 1) return try self.lowerUnsupportedStdMethod(method_name);
                    const builtin_args = try self.alloc.alloc(ast.Expr, 2);
                    builtin_args[0] = receiver.*;
                    builtin_args[1] = args[0];
                    return try self.allocExpr(.{ .builtin = .{
                        .name = "sliceChunks",
                        .args = builtin_args,
                    } });
                },
                .option_is_some => {
                    if (args.len != 0) return try self.lowerUnsupportedStdMethod(method_name);
                    const null_value = try self.allocExpr(ast.Expr{ .lit = .null_lit });
                    return try self.allocExpr(ast.Expr{
                        .bin_op = .{
                            .op = .not_equal,
                            .lhs = receiver,
                            .rhs = null_value,
                        },
                    });
                },
                .num_count_ones => {
                    if (args.len != 0) return try self.lowerUnsupportedStdMethod(method_name);
                    var builtin_args = try self.alloc.alloc(ast.Expr, 1);
                    builtin_args[0] = receiver.*;
                    return try self.allocExpr(ast.Expr{
                        .builtin = .{ .name = "popCount", .args = builtin_args },
                    });
                },
                else => {},
            }
        }
        const bin_kind: ?ast.BinOpKind = if (std.mem.eql(u8, method_name, "bitxor"))
            .bit_xor
        else if (std.mem.eql(u8, method_name, "bitor"))
            .bit_or
        else if (std.mem.eql(u8, method_name, "bitand"))
            .bit_and
        else if (std.mem.eql(u8, method_name, "shl"))
            .shl
        else if (std.mem.eql(u8, method_name, "shr"))
            .shr
        else if (std.mem.eql(u8, method_name, "add"))
            .add
        else if (std.mem.eql(u8, method_name, "sub"))
            .sub
        else if (std.mem.eql(u8, method_name, "mul"))
            .mul
        else if (std.mem.eql(u8, method_name, "div"))
            .div
        else if (std.mem.eql(u8, method_name, "rem"))
            .mod
        else if (std.mem.eql(u8, method_name, "wrapping_add"))
            .add_wrap
        else if (std.mem.eql(u8, method_name, "wrapping_sub"))
            .sub_wrap
        else if (std.mem.eql(u8, method_name, "wrapping_mul"))
            .mul_wrap
        else if (std.mem.eql(u8, method_name, "saturating_add"))
            .add_sat
        else if (std.mem.eql(u8, method_name, "saturating_sub"))
            .sub_sat
        else
            null;
        if (bin_kind) |bk| {
            if (args.len < 1) return null;
            const lhs = receiver;
            const rhs = try self.allocExpr(args[0]);
            const result = try self.allocExpr(ast.Expr{
                .bin_op = .{ .op = bk, .lhs = lhs, .rhs = rhs },
            });
            return result;
        }
        if (std.mem.eql(u8, method_name, "neg")) {
            const result = try self.allocExpr(ast.Expr{
                .unary_op = .{ .op = .negate, .operand = receiver },
            });
            return result;
        }
        if (std.mem.eql(u8, method_name, "not")) {
            const result = try self.allocExpr(ast.Expr{
                .unary_op = .{ .op = .bit_not, .operand = receiver },
            });
            return result;
        }
        if (recognized_std_method != null) {
            const result = try self.lowerUnsupportedStdMethod(method_name);
            return result;
        }
        return null;
    }

    fn hoistOwnedAssertionOperand(
        self: *Lowerer,
        operand: *const ast.Expr,
        prelude: *std.ArrayListUnmanaged(ast.Stmt),
    ) !*const ast.Expr {
        if (operand.* != .block) return operand;
        const block = operand.block;
        if (block.expr == null or block.stmts.len < 2) return operand;
        if (block.stmts[0] != .let_stmt or block.stmts[1] != .defer_stmt) return operand;
        for (block.stmts) |stmt| {
            try prelude.append(self.alloc, stmt);
        }
        return block.expr.?;
    }

    fn hoistOwnedAssertionCondition(
        self: *Lowerer,
        condition: ast.Expr,
        prelude: *std.ArrayListUnmanaged(ast.Stmt),
    ) !ast.Expr {
        return switch (condition) {
            .bin_op => |binary| .{ .bin_op = .{
                .op = binary.op,
                .lhs = try self.hoistOwnedAssertionOperand(binary.lhs, prelude),
                .rhs = if (binary.op == .bool_and or binary.op == .bool_or)
                    binary.rhs
                else
                    try self.hoistOwnedAssertionOperand(binary.rhs, prelude),
            } },
            else => condition,
        };
    }

    /// Lower an assertion marker emitted by the frontend macro pass. The
    /// marker stores the condition node id as `assertion:<id>` so the
    /// condition remains a normal IR expression while the assertion call is
    /// represented in the target AST.
    fn lowerAssertionMarker(self: *Lowerer, reason: []const u8) anyerror!ast.Expr {
        if (!std.mem.startsWith(u8, reason, "assertion:")) {
            return error.MalformedAssertionMarker;
        }
        const suffix = reason["assertion:".len..];
        if (suffix.len == 0 or std.mem.eql(u8, suffix, "none")) {
            return error.MalformedAssertionMarker;
        }
        const condition_id = std.fmt.parseInt(u32, suffix, 10) catch {
            return error.MalformedAssertionMarker;
        };
        if (condition_id >= self.ir.bodies.exprs.len) {
            return error.MissingAssertionCondition;
        }

        var assertion_prelude: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        defer assertion_prelude.deinit(self.alloc);
        const lowered_condition = try self.lowerExpr(@intCast(condition_id));
        const condition = try self.hoistOwnedAssertionCondition(
            lowered_condition,
            &assertion_prelude,
        );

        var args = try self.alloc.alloc(ast.Expr, 1);
        args[0] = condition;
        const assertion = if (self.lowering_test_entity) blk: {
            const std_target = try self.allocExpr(.{ .ident = "std" });
            const testing_target = try self.allocExpr(.{ .field_access = .{
                .target = std_target,
                .field_name = "testing",
            } });
            const expect_target = try self.allocExpr(.{ .field_access = .{
                .target = testing_target,
                .field_name = "expect",
            } });
            const expect_call = try self.allocExpr(.{ .call = .{
                .callee = expect_target,
                .args = args,
            } });
            break :blk ast.Expr{ .unary_op = .{
                .op = .try_op,
                .operand = expect_call,
            } };
        } else ast.Expr{
            .call = .{
                .callee = try self.allocExpr(.{
                    .ident = try self.alloc.dupe(u8, "std.debug.assert"),
                }),
                .args = args,
            },
        };
        if (assertion_prelude.items.len == 0) return assertion;
        const statements = try assertion_prelude.toOwnedSlice(self.alloc);
        return .{ .block = .{
            .stmts = statements,
            .expr = try self.allocExpr(assertion),
        } };
    }

    fn isAssertionReason(reason: []const u8) bool {
        if (std.mem.startsWith(u8, reason, "assertion:")) return true;
        return std.mem.eql(u8, reason, "macro debug_assert") or
            std.mem.eql(u8, reason, "macro debug_assert_eq") or
            std.mem.eql(u8, reason, "macro debug_assert_ne");
    }

    fn isScalarCastType(ty: ir.types.Type) bool {
        return switch (ty) {
            .prim => |primitive| switch (primitive) {
                .i8, .i16, .i32, .i64, .i128, .u8, .u16, .u32, .u64, .u128, .isize, .usize, .f32, .f64, .char => true,
                .bool, .unit, .never => false,
            },
            else => false,
        };
    }
    const ScalarPointeeLayout = enum {
        byte_1,
        byte_2,
        byte_4,
        byte_8,
        byte_16,
        pointer,
    };

    fn scalarPointeeLayout(primitive: ir.types.Prim) ?ScalarPointeeLayout {
        return switch (primitive) {
            .i8, .u8, .bool => .byte_1,
            .i16, .u16 => .byte_2,
            .i32, .u32, .f32, .char => .byte_4,
            .i64, .u64, .f64 => .byte_8,
            .i128, .u128 => .byte_16,
            .isize, .usize => .pointer,
            .unit, .never => null,
        };
    }

    fn pointerPointeesCompatible(source: ir.types.Type, target: ir.types.Type) bool {
        return switch (source) {
            .prim => |source_primitive| switch (target) {
                .prim => |target_primitive| {
                    const source_layout = scalarPointeeLayout(source_primitive) orelse return false;
                    const target_layout = scalarPointeeLayout(target_primitive) orelse return false;
                    return source_layout == target_layout;
                },
                else => false,
            },
            else => false,
        };
    }
    fn unsignedPrimitiveWidth(primitive: ir.types.Prim) ?u16 {
        return switch (primitive) {
            .u8 => 8,
            .u16 => 16,
            .u32 => 32,
            .u64 => 64,
            .u128 => 128,
            .usize => 64,
            else => null,
        };
    }

    fn isValidPrimitiveFrom(source: ir.types.Type, target: ir.types.Type) bool {
        const source_primitive = switch (source) {
            .prim => |primitive| primitive,
            else => return false,
        };
        const target_primitive = switch (target) {
            .prim => |primitive| primitive,
            else => return false,
        };
        const source_width = unsignedPrimitiveWidth(source_primitive) orelse return false;
        const target_width = unsignedPrimitiveWidth(target_primitive) orelse return false;
        return source_width <= target_width;
    }

    fn scalarPrimitive(ty: ir.types.Type) ?ir.types.Prim {
        return switch (ty) {
            .prim => |primitive| primitive,
            else => null,
        };
    }

    fn integerWidth(primitive: ir.types.Prim) ?u16 {
        return switch (primitive) {
            .i8, .u8 => 8,
            .i16, .u16 => 16,
            .i32, .u32 => 32,
            .i64, .u64, .isize, .usize => 64,
            .i128, .u128 => 128,
            .char => 21,
            .f32, .f64, .bool, .unit, .never => null,
        };
    }

    fn isFloatPrimitive(primitive: ir.types.Prim) bool {
        return primitive == .f32 or primitive == .f64;
    }

    fn isSignedPrimitive(primitive: ir.types.Prim) bool {
        return switch (primitive) {
            .i8, .i16, .i32, .i64, .i128, .isize => true,
            else => false,
        };
    }

    fn signedCounterpart(primitive: ir.types.Prim) ?ir.types.Prim {
        return switch (primitive) {
            .u8 => .i8,
            .u16 => .i16,
            .u32 => .i32,
            .u64 => .i64,
            .u128 => .i128,
            .usize => .isize,
            else => null,
        };
    }

    fn scalarBuiltin(self: *Lowerer, name: []const u8, operand: ast.Expr) !ast.Expr {
        const args = try self.alloc.alloc(ast.Expr, 1);
        args[0] = operand;
        return .{ .builtin = .{ .name = name, .args = args } };
    }

    fn scalarCast(
        self: *Lowerer,
        source_type: ir.types.Type,
        target_type: ir.types.Type,
        operand: ast.Expr,
    ) !ast.Expr {
        const source = scalarPrimitive(source_type) orelse return error.UnsupportedExpression;
        const target = scalarPrimitive(target_type) orelse return error.UnsupportedExpression;
        const target_ast = try self.lowerType(target_type);

        if (isFloatPrimitive(source)) {
            if (isFloatPrimitive(target)) {
                const converted = if (source == target)
                    operand
                else
                    try self.scalarBuiltin("floatCast", operand);
                return .{ .cast = .{
                    .target = target_ast,
                    .operand = try self.allocExpr(converted),
                } };
            }
            const target_width = integerWidth(target) orelse return error.UnsupportedExpression;
            if (target_width >= 128) return error.UnsupportedExpression;
            const max_integer: i128 = if (isSignedPrimitive(target))
                (@as(i128, 1) << @intCast(target_width - 1)) - 1
            else
                (@as(i128, 1) << @intCast(target_width)) - 1;
            const min_integer: i128 = if (isSignedPrimitive(target))
                -(@as(i128, 1) << @intCast(target_width - 1))
            else
                0;
            const max_value: f64 = @floatFromInt(max_integer);
            const min_value: f64 = @floatFromInt(min_integer);

            var conversion: ast.Expr = try self.scalarBuiltin("intFromFloat", operand);
            const max_lhs = try self.allocExpr(operand);
            errdefer self.alloc.destroy(max_lhs);
            const max_rhs = try self.allocExpr(.{ .lit = .{ .float = max_value } });
            errdefer self.alloc.destroy(max_rhs);
            const max_condition = try self.allocExpr(.{ .bin_op = .{
                .op = .greater_than,
                .lhs = max_lhs,
                .rhs = max_rhs,
            } });
            errdefer self.alloc.destroy(max_condition);
            const max_then_body = try self.allocExpr(.{ .lit = .{ .int = max_integer } });
            errdefer self.alloc.destroy(max_then_body);
            const max_else_body = try self.allocExpr(conversion);
            errdefer self.alloc.destroy(max_else_body);
            conversion = .{ .if_expr = .{
                .cond = max_condition,
                .then_body = max_then_body,
                .else_body = max_else_body,
            } };

            const min_lhs = try self.allocExpr(operand);
            errdefer self.alloc.destroy(min_lhs);
            const min_rhs = try self.allocExpr(.{ .lit = .{ .float = min_value } });
            errdefer self.alloc.destroy(min_rhs);
            const min_condition = try self.allocExpr(.{ .bin_op = .{
                .op = .less_than,
                .lhs = min_lhs,
                .rhs = min_rhs,
            } });
            errdefer self.alloc.destroy(min_condition);
            const min_then_body = try self.allocExpr(.{ .lit = .{ .int = min_integer } });
            errdefer self.alloc.destroy(min_then_body);
            const min_else_body = try self.allocExpr(conversion);
            errdefer self.alloc.destroy(min_else_body);
            conversion = .{ .if_expr = .{
                .cond = min_condition,
                .then_body = min_then_body,
                .else_body = min_else_body,
            } };

            const nan_callee = try self.allocExpr(.{ .ident = "std.math.isNan" });
            errdefer self.alloc.destroy(nan_callee);
            const nan_condition = try self.allocExpr(.{ .call = .{
                .callee = nan_callee,
                .args = &.{operand},
            } });
            errdefer self.alloc.destroy(nan_condition);
            const nan_then_body = try self.allocExpr(.{ .lit = .{ .int = 0 } });
            errdefer self.alloc.destroy(nan_then_body);
            const nan_else_body = try self.allocExpr(conversion);
            errdefer self.alloc.destroy(nan_else_body);
            conversion = .{ .if_expr = .{
                .cond = nan_condition,
                .then_body = nan_then_body,
                .else_body = nan_else_body,
            } };
            return .{ .cast = .{
                .target = target_ast,
                .operand = try self.allocExpr(conversion),
            } };
        }

        if (isFloatPrimitive(target)) {
            const converted = try self.scalarBuiltin("floatFromInt", operand);
            return .{ .cast = .{
                .target = target_ast,
                .operand = try self.allocExpr(converted),
            } };
        }

        const source_width = integerWidth(source) orelse return error.UnsupportedExpression;
        const target_width = integerWidth(target) orelse return error.UnsupportedExpression;
        if (source_width > target_width) {
            const truncated = try self.scalarBuiltin("truncate", operand);
            return .{ .cast = .{
                .target = target_ast,
                .operand = try self.allocExpr(truncated),
            } };
        }
        if (source_width == target_width and isSignedPrimitive(source) != isSignedPrimitive(target)) {
            const reinterpreted = try self.scalarBuiltin("bitCast", operand);
            return .{ .cast = .{
                .target = target_ast,
                .operand = try self.allocExpr(reinterpreted),
            } };
        }
        if (source_width < target_width and isSignedPrimitive(source) and
            !isSignedPrimitive(target))
        {
            const signed_target = signedCounterpart(target) orelse return error.UnsupportedExpression;
            const widened: ast.Expr = .{ .cast = .{
                .target = try self.lowerType(.{ .prim = signed_target }),
                .operand = try self.allocExpr(operand),
            } };
            const reinterpreted = try self.scalarBuiltin("bitCast", widened);
            return .{ .cast = .{
                .target = target_ast,
                .operand = try self.allocExpr(reinterpreted),
            } };
        }
        return .{ .cast = .{
            .target = target_ast,
            .operand = try self.allocExpr(operand),
        } };
    }

    fn typeById(self: *Lowerer, type_id: ir.spine.TypeId) !ir.types.Type {
        if (type_id < self.ir.types.len) return self.ir.types[type_id];
        if (type_id < self.ir.bodies.types.len) return self.ir.bodies.types[type_id];
        return error.MissingTypeId;
    }

    pub fn lowerExpr(self: *Lowerer, expr_id: ir.exprs.NodeId) anyerror!ast.Expr {
        if (expr_id >= self.ir.bodies.exprs.len) {
            return error.MissingExpressionNode;
        }

        const ir_expr = self.ir.bodies.exprs[expr_id];

        return switch (ir_expr.kind) {
            .literal => |lit| switch (lit) {
                .int => |il| ast.Expr{ .lit = .{ .int = il.value } },
                .float => |fl| ast.Expr{ .lit = .{ .float = fl.value } },
                .character => |cl| ast.Expr{ .lit = .{ .char_lit = @intCast(cl.value) } },
                .string => |sl| ast.Expr{ .lit = .{ .str = try self.alloc.dupe(u8, sl.bytes) } },
                .byte_array => |ba| ast.Expr{ .lit = .{ .str = try self.alloc.dupe(u8, ba.items) } },
                .boolean => |b| ast.Expr{ .lit = .{ .bool_lit = b } },
            },
            .array => |a| blk: {
                const elem_ast: ?ast.Type = if (ir_expr.ty) |tid|
                    try self.lowerType(try self.typeById(tid))
                else
                    null;
                if (a.repeat) |len| {
                    if (a.elements.len == 0) return error.MissingArrayElement;
                    const elem = try self.allocExpr(try self.lowerExpr(a.elements[0]));
                    break :blk ast.Expr{
                        .repeat = .{
                            .type_name = elem_ast,
                            .elem = elem,
                            .len = len,
                        },
                    };
                }
                var elems = try self.alloc.alloc(ast.Expr, a.elements.len);
                for (a.elements, 0..) |el, i| elems[i] = try self.lowerExpr(el);
                break :blk ast.Expr{
                    .multi_array = .{
                        .type_name = elem_ast,
                        .elements = elems,
                    },
                };
            },
            .vec_lit => return error.UnsupportedExpression,
            .path => |pe| try self.lowerPathExpr(pe),
            .block => |be| ast.Expr{ .block = try self.lowerBlock(be) },
            .unit => ast.Expr{ .struct_init = .{ .type_name = null, .fields = &.{} } },
            .if_else => |ie| blk: {
                const cond = try self.allocExpr(try self.lowerExpr(ie.cond));
                const then_expr = try self.allocExpr(ast.Expr{ .block = try self.lowerBlock(ie.then_) });
                const else_expr: ?*const ast.Expr = switch (ie.@"else") {
                    .none => null,
                    .block => |eb| try self.allocExpr(ast.Expr{ .block = try self.lowerBlock(eb) }),
                    .chain => |chain_id| try self.allocExpr(try self.lowerExpr(chain_id)),
                };
                break :blk ast.Expr{
                    .if_expr = .{
                        .cond = cond,
                        .then_body = then_expr,
                        .else_body = else_expr,
                    },
                };
            },
            .if_let => |il| blk: {
                const cond = try self.allocExpr(try self.lowerExpr(il.scrutinee));
                const then_expr = try self.allocExpr(ast.Expr{ .block = try self.lowerBlock(il.then_) });
                const else_expr: ?*const ast.Expr = switch (il.@"else") {
                    .none => null,
                    .block => |eb| try self.allocExpr(ast.Expr{ .block = try self.lowerBlock(eb) }),
                    .chain => |chain_id| try self.allocExpr(try self.lowerExpr(chain_id)),
                };
                break :blk ast.Expr{
                    .if_expr = .{
                        .cond = cond,
                        .then_body = then_expr,
                        .else_body = else_expr,
                    },
                };
            },
            .match => |me| blk: {
                const target = try self.allocExpr(try self.lowerExpr(me.scrutinee));
                if (me.arms.len == 0) return error.MissingMatchArm;
                var arms = try self.alloc.alloc(ast.MatchArm, me.arms.len);
                for (me.arms, 0..) |arm, i| {
                    if (arm.guard != null) return error.UnsupportedMatchGuard;
                    if (arm.patterns.len == 0) return error.MissingMatchPattern;
                    if (arm.patterns.len > self.ir.bodies.pats.len) {
                        return error.MissingPatternNode;
                    }
                    var lowered_patterns = try self.alloc.alloc(ast.Pattern, arm.patterns.len);
                    for (arm.patterns, 0..) |p_id, j| {
                        lowered_patterns[j] = try self.lowerPattern(p_id);
                    }
                    var arm_shadow_names: std.ArrayListUnmanaged([]const u8) = .empty;
                    defer arm_shadow_names.deinit(self.alloc);
                    for (arm.patterns) |p_id| {
                        try self.appendPatternBindingName(p_id, &arm_shadow_names);
                    }
                    const body_expr = arm_body: {
                        const previous_shadow_scope = self.current_shadow_scope;
                        var arm_shadow_scope: ShadowScope = .{
                            .names = arm_shadow_names.items,
                            .parent = previous_shadow_scope,
                        };
                        self.current_shadow_scope = &arm_shadow_scope;
                        defer self.current_shadow_scope = previous_shadow_scope;
                        break :arm_body try self.lowerExpr(arm.body);
                    };
                    arms[i] = .{
                        .patterns = lowered_patterns,
                        .body = body_expr,
                    };
                }
                break :blk ast.Expr{
                    .match_expr = .{
                        .target = target,
                        .arms = arms,
                    },
                };
            },
            .loop_ => |le| blk: {
                const cond = try self.allocExpr(ast.Expr{ .lit = .{ .bool_lit = true } });
                break :blk ast.Expr{
                    .while_expr = .{
                        .cond = cond,
                        .body = try self.lowerBlock(le.body),
                    },
                };
            },
            .while_ => |we| blk: {
                const cond = try self.allocExpr(try self.lowerExpr(we.cond));
                const captures = if (we.capture) |cap_id|
                    try self.lowerWhileCapture(cap_id)
                else
                    null;
                const previous_shadow_scope = self.current_shadow_scope;
                var capture_shadow_scope: ShadowScope = .{
                    .names = captures orelse &.{},
                    .parent = previous_shadow_scope,
                };
                self.current_shadow_scope = &capture_shadow_scope;
                defer self.current_shadow_scope = previous_shadow_scope;
                const body = try self.lowerBlock(we.body);
                break :blk ast.Expr{
                    .while_expr = .{
                        .cond = cond,
                        .captures = captures,
                        .body = body,
                    },
                };
            },
            .for_ => |fe| blk: {
                var inputs: std.ArrayListUnmanaged(ast.Expr) = .empty;
                defer inputs.deinit(self.alloc);
                var captures_list: std.ArrayListUnmanaged([]const u8) = .empty;
                defer captures_list.deinit(self.alloc);
                var destructure: std.ArrayListUnmanaged(ast.Stmt) = .empty;
                defer destructure.deinit(self.alloc);
                var value_capture_name: ?[]const u8 = null;
                if (fe.pattern >= self.ir.bodies.pats.len) return error.MissingPatternNode;

                switch (fe.iter_kind) {
                    .slice => {
                        value_capture_name = try self.valueCaptureName(fe.pattern);
                        try inputs.append(self.alloc, try self.lowerExpr(fe.iterable));
                        try self.appendPatternCaptures(fe.pattern, &captures_list);
                    },

                    .range => {
                        // `0..end`; a Rust start that isn't 0 (or `..=` inclusive)
                        // was handled in the frontend (`..=` lowers to `end+1`).
                        const start = try self.allocExpr(ast.Expr{ .lit = .{ .int = 0 } });
                        const end = try self.allocExpr(try self.lowerExpr(fe.iterable));
                        try inputs.append(self.alloc, ast.Expr{ .range = .{ .start = start, .end = end } });
                        try self.appendPatternCaptures(fe.pattern, &captures_list);
                    },
                    .enumerate => {
                        // Rust `for (idx, elem) in xs.enumerate()` →
                        // Zig `for (xs, 0..) |elem, idx|`.
                        const pat = self.ir.bodies.pats[fe.pattern];
                        const tuple = switch (pat.kind) {
                            .tuple => |tp| tp,
                            else => return error.InvalidLoopCapture,
                        };
                        if (tuple.elements.len != 2) return error.LoopCaptureArityMismatch;
                        const slice = try self.lowerExpr(fe.iterable);
                        const zstart = try self.allocExpr(ast.Expr{ .lit = .{ .int = 0 } });
                        const open = try self.allocExpr(ast.Expr{ .range = .{ .start = zstart, .end = null } });
                        try inputs.append(self.alloc, slice);
                        try inputs.append(self.alloc, open.*);
                        const idx_name = try self.patternName(tuple.elements[0]);
                        const elem_name = try self.patternName(tuple.elements[1]);
                        value_capture_name = try self.valueCaptureName(tuple.elements[1]);

                        try captures_list.append(self.alloc, elem_name);
                        try captures_list.append(self.alloc, idx_name);
                    },
                    .multi => |ids| {
                        if (ids.len == 0) return error.MissingLoopInput;
                        const pat = self.ir.bodies.pats[fe.pattern];
                        const tuple = switch (pat.kind) {
                            .tuple => |tp| tp,
                            else => return error.InvalidLoopCapture,
                        };
                        if (tuple.elements.len != ids.len) return error.LoopCaptureArityMismatch;
                        for (ids, 0..) |mid, mi| {
                            try inputs.append(self.alloc, try self.lowerExpr(mid));
                            try self.appendMultiCapture(
                                tuple.elements[mi],
                                &captures_list,
                                &destructure,
                            );
                        }
                    },
                    .adapter => return error.UnsupportedIterableAdapter,
                }

                const previous_capture_names = self.current_capture_names;
                var capture_names: ?[][]const u8 = null;
                if (captures_list.items.len > 0) {
                    const names = try self.alloc.alloc(
                        []const u8,
                        previous_capture_names.len + captures_list.items.len,
                    );
                    @memcpy(names[0..previous_capture_names.len], previous_capture_names);
                    @memcpy(names[previous_capture_names.len..], captures_list.items);
                    capture_names = names;
                    self.current_capture_names = names;
                }
                defer if (capture_names) |names| self.alloc.free(names);
                defer self.current_capture_names = previous_capture_names;

                const previous_value_capture_scopes = self.current_value_capture_scopes;
                const value_capture_scopes = try self.alloc.alloc(
                    ValueCaptureScope,
                    previous_value_capture_scopes.len + 1,
                );
                defer self.alloc.free(value_capture_scopes);

                @memcpy(
                    value_capture_scopes[0..previous_value_capture_scopes.len],
                    previous_value_capture_scopes,
                );
                value_capture_scopes[previous_value_capture_scopes.len] = .{
                    .names = captures_list.items,
                    .value_name = value_capture_name,
                };
                self.current_value_capture_scopes = value_capture_scopes;
                defer self.current_value_capture_scopes = previous_value_capture_scopes;

                var body = try self.lowerBlock(fe.body);

                if (destructure.items.len > 0) {
                    const merged = try self.alloc.alloc(ast.Stmt, destructure.items.len + body.stmts.len);
                    @memcpy(merged[0..destructure.items.len], destructure.items);
                    @memcpy(merged[destructure.items.len..], body.stmts);
                    body.stmts = merged;
                }

                const for_inputs = try inputs.toOwnedSlice(self.alloc);
                errdefer self.alloc.free(for_inputs);
                const captures = try captures_list.toOwnedSlice(self.alloc);
                errdefer self.alloc.free(captures);

                break :blk ast.Expr{
                    .for_expr = .{
                        .inputs = for_inputs,
                        .captures = captures,
                        .body = body,
                    },
                };
            },
            .break_ => |be| blk: {
                const val = if (be.value) |v| try self.allocExpr(try self.lowerExpr(v)) else null;
                break :blk ast.Expr{ .break_expr = val };
            },
            .continue_ => ast.Expr{ .continue_expr = {} },
            .call => |c| blk: {
                const callee_def: ir.spine.EntityId = switch (c.call_kind) {
                    .free => |def_id| def_id,
                    .associated => |def_id| def_id,
                    .constructor => |def_id| def_id,
                };
                const callee_entity = self.ir.graph.symbol_table.get(callee_def) orelse {
                    return error.MissingDefinition;
                };
                const callee_name = callee_entity.renamed_to orelse callee_entity.name;
                if (callee_name.len == 0) return error.MissingDefinitionName;

                const allocates =
                    c.call_kind != .constructor and self.directCallAllocates(callee_def);

                // Trait-associated calls like `Clone::clone(&x)` / `AsRef::as_ref(&x)`
                // lower to the receiver/copy/slice expression directly.
                if (c.call_kind == .associated) {
                    if (c.args.len >= 1) {
                        const recv_ast = try self.lowerExpr(c.args[0]);
                        const recv_ptr = try self.allocExpr(recv_ast);
                        if (try self.lowerStdMethodCall(callee_name, c.args[0], recv_ptr, &.{})) |lowered| {
                            break :blk try self.lowerDirectCallResult(
                                expr_id,
                                lowered.*,
                                allocates,
                            );
                        }
                    }
                }

                const callee_expr = callee: {
                    if (c.call_kind == .associated) {
                        if (try self.qualifyTraitImplMethod(callee_def)) |trait_method| {
                            break :callee trait_method;
                        }
                    }
                    const resolved_callee = try self.lowerResolvedEntity(callee_def);
                    break :callee try self.qualifyInherentMethod(callee_def, resolved_callee);
                };
                var owned_prelude: std.ArrayListUnmanaged(ast.Stmt) = .empty;
                defer owned_prelude.deinit(self.alloc);
                var owned_reserved: std.ArrayListUnmanaged([]const u8) = .empty;
                defer owned_reserved.deinit(self.alloc);
                if (self.current_owner_reserved) |reserved| {
                    try owned_reserved.appendSlice(self.alloc, reserved.items);
                }
                const previous_owner_prelude = self.current_owner_prelude;
                const previous_owner_reserved = self.current_owner_reserved;
                self.current_owner_prelude = &owned_prelude;
                self.current_owner_reserved = &owned_reserved;
                defer {
                    self.current_owner_prelude = previous_owner_prelude;
                    self.current_owner_reserved = previous_owner_reserved;
                }

                const allocator_index: usize = if (allocates and
                    c.call_kind == .associated and
                    c.args.len > 0) 1 else 0;
                var args = try self.alloc.alloc(
                    ast.Expr,
                    c.args.len + if (allocates) @as(usize, 1) else 0,
                );
                if (allocates) args[allocator_index] = .{ .ident = "allocator" };
                for (c.args, 0..) |arg_id, i| {
                    const previous_expected_type = self.expected_argument_type;
                    const previous_expected_expr_id = self.expected_argument_expr_id;
                    self.expected_argument_type = self.directFreeCallArgumentType(c.call_kind, i);
                    self.expected_argument_expr_id = if (self.expected_argument_type != null)
                        arg_id
                    else
                        null;
                    const destination_index = i + if (allocates and i >= allocator_index)
                        @as(usize, 1)
                    else
                        0;
                    args[destination_index] = lowered_arg: {
                        defer {
                            self.expected_argument_type = previous_expected_type;
                            self.expected_argument_expr_id = previous_expected_expr_id;
                        }
                        break :lowered_arg try self.lowerExpr(arg_id);
                    };
                }
                const generic_args = try self.lowerCallGenericArgs(expr_id, callee_def, c.args);
                const lowered_call = if (c.call_kind == .constructor)
                    try self.lowerTupleStructConstructor(callee_def, generic_args, args)
                else blk_call: {
                    const call_expr = ast.Expr{
                        .call = .{
                            .callee = try self.allocExpr(callee_expr),
                            .generic_args = generic_args,
                            .args = args,
                        },
                    };
                    break :blk_call try self.lowerDirectCallResult(expr_id, call_expr, allocates);
                };
                if (owned_prelude.items.len == 0) break :blk lowered_call;
                const owned_stmts = try owned_prelude.toOwnedSlice(self.alloc);
                break :blk .{ .block = .{
                    .stmts = owned_stmts,
                    .expr = try self.allocExpr(lowered_call),
                } };
            },
            .method_call => |mc| blk: {
                const receiver = try self.allocExpr(try self.lowerExpr(mc.receiver));
                const method_entity = self.ir.graph.symbol_table.get(mc.method) orelse {
                    return error.MissingDefinition;
                };
                try self.validateMethodTopology(method_entity);
                const method_name = method_entity.renamed_to orelse method_entity.name;
                const allocates = self.directCallAllocates(mc.method);

                var owned_prelude: std.ArrayListUnmanaged(ast.Stmt) = .empty;
                defer owned_prelude.deinit(self.alloc);
                var owned_reserved: std.ArrayListUnmanaged([]const u8) = .empty;
                defer owned_reserved.deinit(self.alloc);
                if (self.current_owner_reserved) |reserved| {
                    try owned_reserved.appendSlice(self.alloc, reserved.items);
                }
                const previous_owner_prelude = self.current_owner_prelude;
                const previous_owner_reserved = self.current_owner_reserved;
                self.current_owner_prelude = &owned_prelude;
                self.current_owner_reserved = &owned_reserved;
                defer {
                    self.current_owner_prelude = previous_owner_prelude;
                    self.current_owner_reserved = previous_owner_reserved;
                }

                var args = try self.alloc.alloc(ast.Expr, mc.args.len);
                for (mc.args, 0..) |arg_id, i| {
                    const previous_expected_type = self.expected_argument_type;
                    const previous_expected_expr_id = self.expected_argument_expr_id;
                    self.expected_argument_type = self.methodCallArgumentType(mc.method, i);
                    self.expected_argument_expr_id = if (self.expected_argument_type != null)
                        arg_id
                    else
                        null;
                    defer {
                        self.expected_argument_type = previous_expected_type;
                        self.expected_argument_expr_id = previous_expected_expr_id;
                    }
                    args[i] = try self.lowerExpr(arg_id);
                }

                const lowered_call = if (try self.lowerStdMethodCall(
                    method_name,
                    mc.receiver,
                    receiver,
                    args,
                )) |lowered|
                    try self.lowerDirectCallResult(expr_id, lowered.*, allocates)
                else blk_call: {
                    const call_args = if (allocates) alloc_args: {
                        const result = try self.alloc.alloc(ast.Expr, args.len + 1);
                        result[0] = .{ .ident = "allocator" };
                        @memcpy(result[1..], args);
                        break :alloc_args result;
                    } else args;
                    const field_access = try self.allocExpr(ast.Expr{
                        .field_access = .{
                            .target = receiver,
                            .field_name = try self.alloc.dupe(u8, method_name),
                        },
                    });
                    const generic_args = try self.lowerCallGenericArgs(expr_id, mc.method, mc.args);
                    const call_expr = ast.Expr{
                        .call = .{
                            .callee = field_access,
                            .generic_args = generic_args,
                            .args = call_args,
                        },
                    };
                    break :blk_call try self.lowerDirectCallResult(expr_id, call_expr, allocates);
                };
                if (owned_prelude.items.len == 0) break :blk lowered_call;
                const owned_stmts = try owned_prelude.toOwnedSlice(self.alloc);
                break :blk .{ .block = .{
                    .stmts = owned_stmts,
                    .expr = try self.allocExpr(lowered_call),
                } };
            },
            .struct_lit => |sl| blk: {
                if (sl.base != null) return error.UnsupportedStructUpdate;
                const struct_entity = self.ir.graph.symbol_table.get(sl.def) orelse {
                    return error.MissingDefinition;
                };
                if (struct_entity.kind != .struct_) return error.InvalidStructDefinition;
                if (sl.def >= self.ir.bodies.bodies.len) return error.MissingBodyId;
                const struct_body = switch (self.ir.bodies.bodies[sl.def]) {
                    .struct_ => |body| body,
                    else => return error.DeclarationBodyMismatch,
                };
                var fields = try self.alloc.alloc(ast.StructInitField, sl.fields.len);
                for (sl.fields, 0..) |fi, i| {
                    var found = false;
                    for (struct_body.fields) |declared| {
                        if (std.mem.eql(u8, declared.name, fi.field)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return error.MissingStructField;
                    const name = try self.alloc.dupe(u8, fi.field);
                    errdefer self.alloc.free(name);
                    const expr = try self.lowerExpr(fi.value);

                    fields[i] = .{
                        .name = name,
                        .expr = expr,
                    };
                }

                const inferred_generic_args =
                    self.genericArgsFromExprType(expr_id, sl.def) orelse
                    try self.inferredStructLitArgs(sl.def, sl.fields);
                const lowered_generic_args = try self.lowerGenericArgs(
                    sl.def,
                    inferred_generic_args,
                );
                const struct_name = try self.lowerResolvedEntityName(sl.def);
                const type_name = if (lowered_generic_args.len > 0)
                    ast.Type{ .generic = .{
                        .name = struct_name,
                        .params = lowered_generic_args,
                    } }
                else
                    ast.Type{ .named = struct_name };

                break :blk ast.Expr{
                    .struct_init = .{
                        .type_name = type_name,
                        .fields = fields,
                    },
                };
            },
            .enum_variant => |ev| blk: {
                const variant_entity = self.ir.graph.symbol_table.get(ev.def) orelse {
                    return error.MissingDefinition;
                };
                if (variant_entity.kind != .variant and variant_entity.kind != .enum_) {
                    return error.InvalidVariantDefinition;
                }
                if (ev.variant.len == 0) return error.MissingVariantName;
                if (ev.named_fields.len > 0) return error.UnsupportedEnumVariantFields;
                const variant_fields = self.enumVariantFields(ev.def) orelse {
                    return error.MissingVariantDefinition;
                };
                switch (variant_fields) {
                    .none => {
                        if (ev.tuple_fields.len != 0) return error.VariantArityMismatch;
                    },
                    .tuple => |fields| {
                        if (ev.tuple_fields.len != fields.len) return error.VariantArityMismatch;
                    },
                    .named => return error.UnsupportedEnumVariantFields,
                }
                const variant_name = try self.alloc.dupe(u8, ev.variant);
                const returns_error_union = if (self.current_return_type) |return_type|
                    switch (return_type) {
                        .result => |result| result.is_error_unionable,
                        else => false,
                    }
                else
                    false;
                if (returns_error_union and ev.tuple_fields.len == 0) {
                    const error_name = try self.alloc.dupe(u8, "error");
                    const error_target = try self.allocExpr(.{ .ident = error_name });
                    break :blk .{ .field_access = .{
                        .target = error_target,
                        .field_name = variant_name,
                    } };
                }
                if (ev.tuple_fields.len > 0) {
                    var fields = try self.alloc.alloc(ast.StructInitField, ev.tuple_fields.len);
                    for (ev.tuple_fields, 0..) |tf, i| {
                        const name = try std.fmt.allocPrint(self.alloc, "{d}", .{i});
                        errdefer self.alloc.free(name);
                        const expr = try self.lowerExpr(tf);

                        fields[i] = .{
                            .name = name,
                            .expr = expr,
                        };
                    }
                    break :blk ast.Expr{
                        .struct_init = .{
                            .type_name = ast.Type{ .named = variant_name },
                            .fields = fields,
                        },
                    };
                }
                break :blk ast.Expr{ .ident = variant_name };
            },
            .field => |fe| blk: {
                const base = try self.allocExpr(try self.lowerExpr(fe.base));
                errdefer self.alloc.destroy(base);
                const field_name = try self.alloc.dupe(u8, fe.field);
                errdefer self.alloc.free(field_name);
                break :blk ast.Expr{
                    .field_access = .{
                        .target = base,
                        .field_name = field_name,
                    },
                };
            },
            .index => |ie| blk: {
                const base = try self.allocExpr(try self.lowerExpr(ie.base));
                const idx = try self.allocExpr(try self.lowerExpr(ie.index));
                var args = try self.alloc.alloc(ast.Expr, 2);
                args[0] = base.*;
                args[1] = idx.*;
                break :blk ast.Expr{
                    .builtin = .{
                        .name = "index",
                        .args = args,
                    },
                };
            },
            .cast => |cast| blk: {
                const target_ir = try self.typeById(cast.target);
                if (isScalarCastType(cast.source_type)) {
                    if (!isScalarCastType(target_ir)) return error.UnsupportedExpression;
                    switch (cast.kind) {
                        .as_ => {},
                        .primitive_from => if (!isValidPrimitiveFrom(cast.source_type, target_ir)) {
                            return error.UnsupportedExpression;
                        },
                    }
                    break :blk try self.scalarCast(
                        cast.source_type,
                        target_ir,
                        try self.lowerExpr(cast.operand),
                    );
                }

                // A From conversion exists only between unsigned scalars, so
                // anything reaching the pointer path is not a legal primitive_from.
                if (cast.kind == .primitive_from) return error.UnsupportedExpression;
                const source_pointer = switch (cast.source_type) {
                    .raw_ptr => |pointer| pointer,
                    else => return error.UnsupportedExpression,
                };
                const target_pointer = switch (target_ir) {
                    .raw_ptr => |pointer| pointer,
                    else => return error.UnsupportedExpression,
                };
                if (!pointerPointeesCompatible(source_pointer.pointee, target_pointer.pointee)) {
                    return error.UnsupportedExpression;
                }
                const target = try self.lowerType(target_ir);
                const source = try self.lowerType(cast.source_type);
                var cast_operand = try self.allocExpr(try self.lowerExpr(cast.operand));
                if (!source_pointer.mut and target_pointer.mut) {
                    const const_cast_args = try self.alloc.alloc(ast.Expr, 1);
                    const_cast_args[0] = cast_operand.*;
                    cast_operand = try self.allocExpr(.{ .builtin = .{
                        .name = "constCast",
                        .args = const_cast_args,
                    } });
                }
                const ptr_cast_args = try self.alloc.alloc(ast.Expr, 1);
                ptr_cast_args[0] = cast_operand.*;
                const pointer_cast = try self.allocExpr(.{ .builtin = .{
                    .name = "ptrCast",
                    .args = ptr_cast_args,
                } });
                break :blk ast.Expr{
                    .cast = .{
                        .target = target,
                        .operand = pointer_cast,
                        .source = source,
                    },
                };
            },
            .binary => |be| blk: {
                const uses_float = self.float_context or isFloatType(self.binopResultType(be));
                const previous_float_context = self.float_context;
                self.float_context = uses_float;
                defer self.float_context = previous_float_context;
                const lhs = try self.allocExpr(try self.lowerExpr(be.lhs));
                const lowered_rhs = try self.allocExpr(try self.lowerExpr(be.rhs));
                const rhs = if (!uses_float and (be.op == .shl or be.op == .shr)) shift: {
                    const args = try self.alloc.alloc(ast.Expr, 1);
                    args[0] = lowered_rhs.*;
                    break :shift try self.allocExpr(.{ .builtin = .{
                        .name = "intCast",
                        .args = args,
                    } });
                } else lowered_rhs;
                const op_kind: ast.BinOpKind = switch (be.op) {
                    .add => if (uses_float) .add else switch (be.overflow) {
                        .checked => .add,
                        .wrapping => .add_wrap,
                        .saturating => .add_sat,
                    },
                    .sub => if (uses_float) .sub else switch (be.overflow) {
                        .checked => .sub,
                        .wrapping => .sub_wrap,
                        .saturating => .sub_sat,
                    },
                    .mul => if (uses_float) .mul else switch (be.overflow) {
                        .checked => .mul,
                        .wrapping => .mul_wrap,
                        .saturating => .add,
                    },
                    .div => .div,
                    .rem => .mod,
                    .bit_and => .bit_and,
                    .bit_or => .bit_or,
                    .bit_xor => .bit_xor,
                    .shl => .shl,
                    .shr => .shr,
                    .eq => .equal,
                    .ne => .not_equal,
                    .lt => .less_than,
                    .le => .less_than_equal,
                    .gt => .greater_than,
                    .ge => .greater_than_equal,
                    .boolean_and => .bool_and,
                    .boolean_or => .bool_or,
                };
                break :blk ast.Expr{
                    .bin_op = .{
                        .op = op_kind,
                        .lhs = lhs,
                        .rhs = rhs,
                    },
                };
            },
            .unary => |ue| blk: {
                if (ue.op == .ref) {
                    if (try self.lowerOwnedTemporaryArgument(expr_id)) |owned| {
                        break :blk owned;
                    }
                }
                if (ue.op == .deref and self.shouldElideValueCaptureDeref(ue.operand)) {
                    break :blk try self.lowerExpr(ue.operand);
                }
                const operand = try self.allocExpr(try self.lowerExpr(ue.operand));

                const op_kind: ast.UnaryOpKind = switch (ue.op) {
                    .negate => .negate,
                    .logical_not => .bool_not,
                    .bit_not => .bit_not,
                    .deref => .deref,
                    .ref => .addr_of,
                };
                break :blk ast.Expr{
                    .unary_op = .{
                        .op = op_kind,
                        .operand = operand,
                    },
                };
            },
            .assign => return error.UnsupportedExpression,
            .try_ => |te| blk: {
                const previous_explicit_try = self.explicit_try_expr;
                self.explicit_try_expr = te.inner;
                defer self.explicit_try_expr = previous_explicit_try;
                const operand = try self.allocExpr(try self.lowerExpr(te.inner));
                break :blk ast.Expr{
                    .unary_op = .{
                        .op = .try_op,
                        .operand = operand,
                    },
                };
            },
            .return_ => |re| blk: {
                const val = if (re.value) |v| try self.allocExpr(try self.lowerExpr(v)) else null;
                break :blk ast.Expr{ .return_expr = val };
            },
            .range, .closure, .iterator_chain => return error.UnsupportedExpression,
            .unsupported => |u| blk: {
                if (isAssertionReason(u.reason)) {
                    break :blk try self.lowerAssertionMarker(u.reason);
                }
                return error.UnsupportedExpression;
            },
        };
    }

    // -------------------------------------------------------------------------
    // Statement Lowering
    // -------------------------------------------------------------------------

    pub fn lowerStmt(self: *Lowerer, stmt_id: ir.exprs.NodeId) anyerror!ast.Stmt {
        if (stmt_id >= self.ir.bodies.stmts.len) {
            return error.MissingStatementNode;
        }

        const ir_stmt = self.ir.bodies.stmts[stmt_id];

        return switch (ir_stmt.kind) {
            .let => |ls| blk: {
                if (ls.pattern >= self.ir.bodies.pats.len) return error.MissingPatternNode;
                const pat = self.ir.bodies.pats[ls.pattern];
                var tuple_field: ?[]const u8 = null;
                const binding = switch (pat.kind) {
                    .binding => |b| b,
                    .reference => |reference| blk_ref: {
                        if (reference.inner >= self.ir.bodies.pats.len) {
                            return error.MissingPatternNode;
                        }
                        break :blk_ref switch (self.ir.bodies.pats[reference.inner].kind) {
                            .binding => |b| b,
                            else => return error.UnsupportedPattern,
                        };
                    },
                    .struct_pat => |struct_pat| blk_struct: {
                        if (struct_pat.fields.len != 1) return error.UnsupportedPattern;
                        const field = struct_pat.fields[0];
                        if (!std.mem.eql(u8, field.field, "0")) return error.UnsupportedPattern;
                        const inner = field.pat orelse return error.UnsupportedPattern;
                        if (inner >= self.ir.bodies.pats.len) return error.MissingPatternNode;
                        tuple_field = field.field;
                        break :blk_struct switch (self.ir.bodies.pats[inner].kind) {
                            .binding => |b| b,
                            else => return error.UnsupportedPattern,
                        };
                    },
                    else => return error.UnsupportedPattern,
                };
                const init_id = ls.init orelse return error.MissingInitializer;
                const init_expr = if (tuple_field) |field| blk_field: {
                    const tuple_target = if (self.ir.bodies.exprs[init_id].kind == .unary and
                        self.ir.bodies.exprs[init_id].kind.unary.op == .deref)
                        try self.lowerExpr(self.ir.bodies.exprs[init_id].kind.unary.operand)
                    else
                        try self.lowerExpr(init_id);
                    const target = try self.allocExpr(tuple_target);
                    errdefer self.alloc.destroy(target);
                    const field_name = try self.alloc.dupe(u8, field);
                    errdefer self.alloc.free(field_name);
                    break :blk_field ast.Expr{ .field_access = .{
                        .target = target,
                        .field_name = field_name,
                    } };
                } else try self.lowerExpr(init_id);
                const ty: ?ast.Type = if (ls.ty) |t_id|
                    try self.lowerType(try self.typeById(t_id))
                else
                    null;

                break :blk ast.Stmt{
                    .let_stmt = .{
                        .name = try self.alloc.dupe(u8, binding.name),
                        .ty = ty,
                        .init = init_expr,
                        .is_mut = binding.mutable,
                    },
                };
            },
            .let_else => |le| blk: {
                if (le.pattern >= self.ir.bodies.pats.len) return error.MissingPatternNode;
                const pat = self.ir.bodies.pats[le.pattern];
                const binding = switch (pat.kind) {
                    .binding => |b| b,
                    .reference => |reference| blk_ref: {
                        if (reference.inner >= self.ir.bodies.pats.len) {
                            return error.MissingPatternNode;
                        }
                        break :blk_ref switch (self.ir.bodies.pats[reference.inner].kind) {
                            .binding => |b| b,
                            else => return error.UnsupportedPattern,
                        };
                    },
                    else => return error.UnsupportedPattern,
                };
                if (binding.name.len == 0) return error.MissingBindingName;
                const init_expr = try self.lowerExpr(le.init);
                break :blk ast.Stmt{
                    .let_stmt = .{
                        .name = try self.alloc.dupe(u8, binding.name),
                        .init = init_expr,
                        .is_mut = false,
                    },
                };
            },
            .expr => |e_id| blk: {
                if (e_id >= self.ir.bodies.exprs.len) return error.MissingExpressionNode;
                switch (self.ir.bodies.exprs[e_id].kind) {
                    .assign => |assignment| {
                        const target = try self.lowerExpr(assignment.target);
                        const val = try self.lowerExpr(assignment.value);
                        const wrapping = assignment.overflow == .wrapping;
                        const op: ast.AssignOp = switch (assignment.op) {
                            .plain => .assign,
                            .add => if (wrapping) .add_assign_wrap else .add_assign,
                            .sub => if (wrapping) .sub_assign_wrap else .sub_assign,
                            .mul => if (wrapping) .mul_assign_wrap else .mul_assign,
                            .div => .div_assign,
                            .rem => .mod_assign,
                            .bit_and => .bit_and_assign,
                            .bit_or => .bit_or_assign,
                            .bit_xor => .bit_xor_assign,
                            .shl => .shl_assign,
                            .shr => .shr_assign,
                        };
                        break :blk ast.Stmt{ .assign = .{
                            .target = target,
                            .val = val,
                            .op = op,
                        } };
                    },
                    else => {
                        const expr_ptr = try self.allocExpr(try self.lowerExpr(e_id));
                        break :blk ast.Stmt{ .expr_stmt = expr_ptr };
                    },
                }
            },
            .item => return error.UnsupportedStatement,
        };
    }
    fn temporaryOwnerInit(
        self: *Lowerer,
        producer: ast.Expr,
    ) !ast.Expr {
        if (producer == .unary_op and producer.unary_op.op == .try_op) {
            return producer;
        }
        return .{ .unary_op = .{
            .op = .try_op,
            .operand = try self.allocExpr(producer),
        } };
    }

    fn appendOwnedTemporaryPrelude(
        self: *Lowerer,
        plan: OwnedTemporaryPlan,
        producer: ast.Expr,
    ) !ast.Expr {
        const prelude = self.current_owner_prelude orelse return producer;
        const reserved = self.current_owner_reserved orelse return producer;
        try self.appendCollectorImportAliases(reserved);
        const owner_name = try self.collectorBindingName("owner", reserved.items);
        try reserved.append(self.alloc, owner_name);
        const owner_type = try self.lowerType(plan.return_type);
        const owner_init = try self.temporaryOwnerInit(producer);
        try prelude.append(self.alloc, .{ .let_stmt = .{
            .name = owner_name,
            .ty = owner_type,
            .init = owner_init,
            .is_mut = true,
        } });
        const owner_deinit = try self.allocExpr(.{ .field_access = .{
            .target = try self.allocExpr(.{ .ident = owner_name }),
            .field_name = "deinit",
        } });
        try prelude.append(self.alloc, .{ .defer_stmt = .{
            .expr = .{ .call = .{
                .callee = owner_deinit,
                .args = &.{.{ .ident = "allocator" }},
            } },
            .is_errdefer = false,
        } });
        return .{ .field_access = .{
            .target = try self.allocExpr(.{ .ident = owner_name }),
            .field_name = "items",
        } };
    }

    fn lowerOwnedTemporaryArgument(
        self: *Lowerer,
        expr_id: ir.exprs.NodeId,
    ) !?ast.Expr {
        const expected_expr_id = self.expected_argument_expr_id orelse return null;
        if (expected_expr_id != expr_id) return null;
        const expected_type = self.expected_argument_type orelse return null;
        if (self.current_owner_prelude == null or self.current_owner_reserved == null) {
            return null;
        }
        const plan = self.matchOwnedTemporary(expr_id, expected_type) orelse return null;
        const borrowed = switch (self.ir.bodies.exprs[expr_id].kind) {
            .unary => |unary| unary,
            else => return null,
        };
        const producer = try self.lowerExpr(borrowed.operand);
        const lowered = try self.appendOwnedTemporaryPrelude(plan, producer);
        return lowered;
    }

    // -------------------------------------------------------------------------
    // For-loop capture helpers
    // -------------------------------------------------------------------------

    /// Append the flat capture name(s) for a simple loop pattern (bindings,
    /// references and wildcards — not tuples).
    fn appendPatternCaptures(
        self: *Lowerer,
        pat_id: ir.exprs.NodeId,
        captures: *std.ArrayListUnmanaged([]const u8),
    ) anyerror!void {
        try captures.append(self.alloc, try self.patternName(pat_id));
    }

    fn valueCaptureName(self: *Lowerer, pat_id: ir.exprs.NodeId) anyerror!?[]const u8 {
        if (pat_id >= self.ir.bodies.pats.len) return error.MissingPatternNode;
        const binding = switch (self.ir.bodies.pats[pat_id].kind) {
            .binding => |value| value,
            else => return null,
        };
        switch (binding.mode) {
            .value => {},
            else => return null,
        }

        if (binding.name.len == 0) return error.MissingBindingName;
        const name = try self.alloc.dupe(u8, binding.name);
        return name;
    }
    fn shouldElideValueCaptureDeref(
        self: *const Lowerer,
        operand_id: ir.exprs.NodeId,
    ) bool {
        if (operand_id >= self.ir.bodies.exprs.len) return false;
        const path = switch (self.ir.bodies.exprs[operand_id].kind) {
            .path => |value| value,
            else => return false,
        };
        if (path.generic_args.len != 0) return false;
        const entity = self.ir.graph.symbol_table.get(path.def) orelse return false;
        const path_name = entity.renamed_to orelse entity.name;
        var shadow_scope = self.current_shadow_scope;
        while (shadow_scope) |scope| {
            for (scope.names) |shadow_name| {
                if (std.mem.eql(u8, path_name, shadow_name)) return false;
            }
            shadow_scope = scope.parent;
        }

        var scope_index = self.current_value_capture_scopes.len;
        while (scope_index > 0) {
            scope_index -= 1;
            const scope = self.current_value_capture_scopes[scope_index];
            for (scope.names) |capture_name| {
                if (!std.mem.eql(u8, path_name, capture_name)) continue;
                const value_name = scope.value_name orelse return false;
                return std.mem.eql(u8, path_name, value_name);
            }
        }
        return false;
    }

    /// The Zig capture identifier for a pattern: a binding's name, `_` for a
    /// wildcard, the inner pattern's name for a reference.
    fn patternName(self: *Lowerer, pat_id: ir.exprs.NodeId) anyerror![]const u8 {
        if (pat_id >= self.ir.bodies.pats.len) return error.MissingPatternNode;
        const pat = self.ir.bodies.pats[pat_id];
        return switch (pat.kind) {
            .binding => |b| blk: {
                if (b.name.len == 0) return error.MissingBindingName;
                break :blk try self.alloc.dupe(u8, b.name);
            },
            .reference => |r| self.patternName(r.inner),
            .wildcard => try self.alloc.dupe(u8, "_"),
            else => return error.UnsupportedPattern,
        };
    }

    /// Capture for one zip (`multi`) input. A plain binding/reference yields a
    /// single Zig capture; a tuple element yields a temporary capture plus a
    /// `const` destructure injected at the top of the loop body.
    fn appendMultiCapture(
        self: *Lowerer,
        pat_id: ir.exprs.NodeId,
        captures: *std.ArrayListUnmanaged([]const u8),
        destructure: *std.ArrayListUnmanaged(ast.Stmt),
    ) anyerror!void {
        if (pat_id >= self.ir.bodies.pats.len) return error.MissingPatternNode;
        const pat = self.ir.bodies.pats[pat_id];
        switch (pat.kind) {
            .binding => |b| {
                if (b.name.len == 0) return error.MissingBindingName;
                try captures.append(self.alloc, try self.alloc.dupe(u8, b.name));
            },
            .reference => |r| try self.appendMultiCapture(r.inner, captures, destructure),
            .wildcard => try captures.append(self.alloc, try self.alloc.dupe(u8, "_")),
            .tuple => |tp| {
                const tmp = try self.alloc.dupe(u8, "_tup");
                try captures.append(self.alloc, tmp);
                const base = try self.allocExpr(ast.Expr{ .ident = tmp });
                try self.emitTupleDestructure(tp, base, destructure);
            },
            else => return error.UnsupportedPattern,
        }
    }

    /// Emit `const a = base[i]; const b = base[j]; ...` statements for a tuple
    /// pattern, recursing into nested tuple sub-patterns.
    fn emitTupleDestructure(
        self: *Lowerer,
        tp: ir.exprs.TuplePat,
        base: *const ast.Expr,
        destructure: *std.ArrayListUnmanaged(ast.Stmt),
    ) anyerror!void {
        for (tp.elements, 0..) |el, i| {
            if (el >= self.ir.bodies.pats.len) return error.MissingPatternNode;
            const el_pat = self.ir.bodies.pats[el];
            const el_access = try self.indexExpr(base, i);
            switch (el_pat.kind) {
                .binding => |b| {
                    if (b.name.len == 0) return error.MissingBindingName;
                    try destructure.append(self.alloc, ast.Stmt{
                        .let_stmt = .{
                            .name = try self.alloc.dupe(u8, b.name),
                            .init = el_access.*,
                            .is_mut = b.mutable,
                        },
                    });
                },
                .reference => |r| {
                    if (r.inner >= self.ir.bodies.pats.len) return error.MissingPatternNode;
                    const rp = self.ir.bodies.pats[r.inner];
                    if (rp.kind != .binding) return error.UnsupportedPattern;
                    const rb = rp.kind.binding;
                    if (rb.name.len == 0) return error.MissingBindingName;
                    try destructure.append(self.alloc, ast.Stmt{
                        .let_stmt = .{
                            .name = try self.alloc.dupe(u8, rb.name),
                            .init = el_access.*,
                            .is_mut = rb.mutable,
                        },
                    });
                },
                .wildcard => {},
                .tuple => |sub| try self.emitTupleDestructure(sub, el_access, destructure),
                else => return error.UnsupportedPattern,
            }
        }
    }

    /// Allocate `base[idx]` (the emitter renders `@index` with 2 args as `[ ]`).
    fn indexExpr(self: *Lowerer, base: *const ast.Expr, idx: usize) anyerror!*const ast.Expr {
        const idx_lit = try self.allocExpr(ast.Expr{ .lit = .{ .int = @intCast(idx) } });
        var args = try self.alloc.alloc(ast.Expr, 2);
        args[0] = base.*;
        args[1] = idx_lit.*;
        return self.allocExpr(ast.Expr{ .builtin = .{ .name = "index", .args = args } });
    }

    // -------------------------------------------------------------------------
    // Pattern Lowering
    // -------------------------------------------------------------------------

    fn enumVariantFields(
        self: *Lowerer,
        variant_id: ir.spine.EntityId,
    ) ?ir.items.VariantFields {
        const variant_entity = self.ir.graph.symbol_table.get(variant_id) orelse return null;

        if (variant_entity.kind == .variant) {
            if (variant_entity.parent) |enum_id| {
                if (enum_id < self.ir.bodies.bodies.len) {
                    switch (self.ir.bodies.bodies[enum_id]) {
                        .enum_ => |enum_body| {
                            for (enum_body.variants) |variant| {
                                if (std.mem.eql(u8, variant.name, variant_entity.name)) {
                                    return variant.fields;
                                }
                            }
                        },
                        else => {},
                    }
                }
            }
        }

        // Source extraction can resolve `Shape::Circle` to a local placeholder
        // before enum variant entities are linked. Use the unique variant name.
        for (self.ir.bodies.bodies) |body_kind| {
            const enum_body = switch (body_kind) {
                .enum_ => |body| body,
                else => continue,
            };
            for (enum_body.variants) |variant| {
                if (std.mem.eql(u8, variant.name, variant_entity.name)) return variant.fields;
            }
        }
        return null;
    }
    fn enumPatternVariant(
        self: *Lowerer,
        def: ir.spine.EntityId,
        fields: []const ir.exprs.FieldPat,
    ) ?[]const u8 {
        const entity = self.ir.graph.symbol_table.get(def) orelse return null;
        if (entity.kind == .variant) return entity.name;
        if (entity.kind != .enum_ or def >= self.ir.bodies.bodies.len) return null;
        const body = switch (self.ir.bodies.bodies[def]) {
            .enum_ => |enum_body| enum_body,
            else => return null,
        };

        var match: ?[]const u8 = null;
        for (body.variants) |variant| {
            const matches = switch (variant.fields) {
                .none => fields.len == 0,
                .tuple => |tuple| fields.len == tuple.len and blk: {
                    for (fields, 0..) |field, i| {
                        var index_buf: [20]u8 = undefined;
                        const index = std.fmt.bufPrint(&index_buf, "{d}", .{i}) catch break :blk false;
                        if (!std.mem.eql(u8, field.field, index)) break :blk false;
                    }
                    break :blk true;
                },
                .named => |named| blk: {
                    if (fields.len > named.len) break :blk false;
                    for (fields) |field| {
                        var found = false;
                        for (named) |named_field| {
                            if (std.mem.eql(u8, field.field, named_field.name)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) break :blk false;
                    }
                    break :blk true;
                },
            };
            if (!matches) continue;
            if (match != null) return null;
            match = variant.name;
        }
        return match;
    }

    pub fn lowerPattern(self: *Lowerer, pat_id: ir.exprs.NodeId) anyerror!ast.Pattern {
        if (pat_id >= self.ir.bodies.pats.len) return error.MissingPatternNode;

        const ir_pat = self.ir.bodies.pats[pat_id];

        return switch (ir_pat.kind) {
            .wildcard => ast.Pattern.wildcard,
            .binding => |b| blk: {
                if (b.name.len == 0) return error.MissingBindingName;
                break :blk ast.Pattern{ .binding = try self.alloc.dupe(u8, b.name) };
            },
            .literal => |l| switch (l) {
                .int => |il| ast.Pattern{ .lit = .{ .int = il.value } },
                .float => |fl| ast.Pattern{ .lit = .{ .float = fl.value } },
                .character => |cl| ast.Pattern{ .lit = .{ .char_lit = @intCast(cl.value) } },
                .string => |sl| ast.Pattern{ .lit = .{ .str = try self.alloc.dupe(u8, sl.bytes) } },
                .byte_array => |ba| ast.Pattern{ .lit = .{ .str = try self.alloc.dupe(u8, ba.items) } },
                .boolean => |b| ast.Pattern{ .lit = .{ .bool_lit = b } },
            },
            .path => |pp| blk: {
                const entity = self.ir.graph.symbol_table.get(pp.def) orelse {
                    return error.MissingDefinition;
                };
                const name = if (pp.variant) |variant| blk_name: {
                    if (variant.len == 0) return error.MissingVariantName;
                    break :blk_name variant;
                } else entity.renamed_to orelse entity.name;
                if (name.len == 0) return error.MissingVariantName;
                break :blk ast.Pattern{ .enum_literal = try self.alloc.dupe(u8, name) };
            },
            .tuple => |tp| blk: {
                var pats = try self.alloc.alloc(ast.Pattern, tp.elements.len);
                for (tp.elements, 0..) |elem_id, i| {
                    pats[i] = try self.lowerPattern(elem_id);
                }
                break :blk ast.Pattern{ .tuple = pats };
            },
            .struct_pat => |sp| blk: {
                const entity = self.ir.graph.symbol_table.get(sp.def) orelse {
                    return error.MissingDefinition;
                };
                if (entity.kind != .struct_ and entity.kind != .enum_ and entity.kind != .variant) {
                    return error.InvalidPatternDefinition;
                }
                const struct_name = if (self.enumPatternVariant(sp.def, sp.fields)) |variant_name|
                    try self.alloc.dupe(u8, variant_name)
                else if (entity.name.len > 0)
                    try self.alloc.dupe(u8, entity.name)
                else
                    return error.MissingPatternName;
                var fields = try self.alloc.alloc(ast.StructPatternField, sp.fields.len);
                for (sp.fields, 0..) |f, i| {
                    if (f.field.len == 0) return error.MissingPatternField;
                    const f_pat = if (f.pat) |p_id|
                        try self.lowerPattern(p_id)
                    else
                        ast.Pattern{ .binding = try self.alloc.dupe(u8, f.field) };
                    const field_name = if (self.enumVariantFields(sp.def)) |variant_fields|
                        switch (variant_fields) {
                            .tuple => try std.fmt.allocPrint(self.alloc, "{d}", .{i}),
                            else => try self.alloc.dupe(u8, f.field),
                        }
                    else
                        try self.alloc.dupe(u8, f.field);
                    fields[i] = .{
                        .name = field_name,
                        .pat = f_pat,
                    };
                }
                break :blk ast.Pattern{
                    .struct_pat = .{
                        .name = struct_name,
                        .fields = fields,
                    },
                };
            },
            .@"or" => |op| blk: {
                if (op.alternatives.len == 0) return error.MissingPatternAlternative;
                break :blk try self.lowerPattern(op.alternatives[0]);
            },
            else => return error.UnsupportedPattern,
        };
    }

    /// Extract the capture identifier(s) for a `while let` pattern. Handles
    /// `Some(v)` / `Ok(v)` (struct pattern → its single field's binding) and a
    /// plain `v` (direct binding). Returns null when there is no binding.
    fn lowerWhileCapture(self: *Lowerer, pat_id: ir.exprs.NodeId) anyerror![]const []const u8 {
        if (pat_id >= self.ir.bodies.pats.len) return error.InvalidLoopCapture;
        const cap = try self.whileCaptureName(pat_id);
        var out = try self.alloc.alloc([]const u8, 1);
        out[0] = cap;
        return out;
    }

    fn whileCaptureName(self: *Lowerer, pat_id: ir.exprs.NodeId) anyerror![]const u8 {
        if (pat_id >= self.ir.bodies.pats.len) return error.InvalidLoopCapture;
        const pat = self.ir.bodies.pats[pat_id];
        return switch (pat.kind) {
            .binding => |b| blk: {
                if (b.name.len == 0) return error.InvalidLoopCapture;
                break :blk try self.alloc.dupe(u8, b.name);
            },
            .reference => |rp| try self.whileCaptureName(rp.inner),
            .struct_pat => |sp| blk: {
                if (sp.fields.len == 0) return error.InvalidLoopCapture;
                const f = sp.fields[0];
                if (f.pat) |fpid| break :blk try self.whileCaptureName(fpid);
                if (f.shorthand and f.field.len > 0) {
                    break :blk try self.alloc.dupe(u8, f.field);
                }
                return error.InvalidLoopCapture;
            },
            else => return error.InvalidLoopCapture,
        };
    }

    pub fn lowerBlock(self: *Lowerer, be: ir.exprs.BlockExpr) anyerror!ast.Block {
        const previous_owner_prelude = self.current_owner_prelude;
        const previous_owner_reserved = self.current_owner_reserved;
        const argument_block = self.expected_argument_expr_id != null;
        defer {
            self.current_owner_prelude = previous_owner_prelude;
            self.current_owner_reserved = previous_owner_reserved;
        }
        self.current_owner_prelude = null;
        self.current_owner_reserved = null;

        var stmts_list: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        defer stmts_list.deinit(self.alloc);
        var reserved_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer reserved_names.deinit(self.alloc);
        var shadow_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer shadow_names.deinit(self.alloc);
        var promoted_argument_tail: ?*const ast.Expr = null;
        const parent_reserved_start = if (previous_owner_reserved) |parent|
            parent.items.len
        else
            0;
        if (previous_owner_reserved) |parent| {
            try reserved_names.appendSlice(self.alloc, parent.items);
        }

        const previous_shadow_scope = self.current_shadow_scope;
        var shadow_scope: ShadowScope = .{
            .names = shadow_names.items,
            .parent = previous_shadow_scope,
        };
        self.current_shadow_scope = &shadow_scope;
        defer self.current_shadow_scope = previous_shadow_scope;
        var visible_shadow_scope = previous_shadow_scope;
        while (visible_shadow_scope) |scope| {
            for (scope.names) |name| {
                try reserved_names.append(self.alloc, name);
            }
            visible_shadow_scope = scope.parent;
        }
        if (self.current_module_id) |module_id| {
            if (self.moduleForEntity(module_id)) |module| {
                for (module.items) |item_id| {
                    if (self.ir.graph.symbol_table.get(item_id)) |item| {
                        try reserved_names.append(
                            self.alloc,
                            item.renamed_to orelse item.name,
                        );
                    }
                }
            }
        }

        for (self.current_capture_names) |capture_name| {
            try reserved_names.append(self.alloc, capture_name);
        }
        for (self.current_parameter_names) |param| {
            try reserved_names.append(self.alloc, param.name);
        }
        if (self.current_callable_name) |name| {
            try reserved_names.append(self.alloc, name);
        }
        try self.appendCollectorImportAliases(&reserved_names);
        try self.appendBlockBindingNames(be.statements, &reserved_names);

        for (be.statements, 0..) |stmt_id, index| {
            var statement_prelude: std.ArrayListUnmanaged(ast.Stmt) = .empty;
            defer statement_prelude.deinit(self.alloc);
            var statement_reserved: std.ArrayListUnmanaged([]const u8) = .empty;
            defer statement_reserved.deinit(self.alloc);
            const reserved_start = reserved_names.items.len;
            try statement_reserved.appendSlice(self.alloc, reserved_names.items);

            const previous_statement_prelude = self.current_owner_prelude;
            const previous_statement_reserved = self.current_owner_reserved;
            self.current_owner_prelude = &statement_prelude;
            self.current_owner_reserved = &statement_reserved;
            const stmt = lowered_stmt: {
                defer {
                    self.current_owner_prelude = previous_statement_prelude;
                    self.current_owner_reserved = previous_statement_reserved;
                }
                break :lowered_stmt try self.lowerStmt(stmt_id);
            };

            if (argument_block) {
                switch (stmt) {
                    .expr_stmt => |expr| switch (expr.*) {
                        .struct_init => |unit| {
                            if (unit.type_name == null and unit.fields.len == 0) continue;
                        },
                        .block => |nested| {
                            if (nested.expr != null and nested.stmts.len >= 2 and
                                nested.stmts[0] == .let_stmt and nested.stmts[1] == .defer_stmt)
                            {
                                for (nested.stmts) |nested_stmt| {
                                    try stmts_list.append(self.alloc, nested_stmt);
                                    try self.appendCollectorStmtIdentifiers(
                                        nested_stmt,
                                        &statement_reserved,
                                    );
                                }
                                if (nested.expr) |nested_expr| {
                                    if (be.tail == null and index + 1 == be.statements.len) {
                                        std.debug.assert(promoted_argument_tail == null);
                                        promoted_argument_tail = nested_expr;
                                    } else {
                                        const nested_stmt: ast.Stmt = .{
                                            .expr_stmt = nested_expr,
                                        };
                                        try stmts_list.append(self.alloc, nested_stmt);
                                        try self.appendCollectorStmtIdentifiers(
                                            nested_stmt,
                                            &statement_reserved,
                                        );
                                    }
                                }
                                try reserved_names.appendSlice(
                                    self.alloc,
                                    statement_reserved.items[reserved_start..],
                                );
                                continue;
                            }
                        },
                        else => {},
                    },
                    else => {},
                }
            }

            for (statement_prelude.items) |prelude_stmt| {
                try stmts_list.append(self.alloc, prelude_stmt);
                try self.appendCollectorStmtIdentifiers(prelude_stmt, &statement_reserved);
            }
            try stmts_list.append(self.alloc, stmt);
            try self.appendCollectorStmtIdentifiers(stmt, &statement_reserved);
            try self.appendShadowBindingName(stmt, &shadow_names);
            shadow_scope.names = shadow_names.items;
            try reserved_names.appendSlice(self.alloc, statement_reserved.items[reserved_start..]);
        }

        const tail_expr = if (be.tail) |t_id| blk: {
            var tail_prelude: std.ArrayListUnmanaged(ast.Stmt) = .empty;
            defer tail_prelude.deinit(self.alloc);
            var tail_reserved: std.ArrayListUnmanaged([]const u8) = .empty;
            defer tail_reserved.deinit(self.alloc);
            const reserved_start = reserved_names.items.len;
            try tail_reserved.appendSlice(self.alloc, reserved_names.items);

            const previous_tail_prelude = self.current_owner_prelude;
            const previous_tail_reserved = self.current_owner_reserved;
            self.current_owner_prelude = &tail_prelude;
            self.current_owner_reserved = &tail_reserved;
            const lowered_tail = lowered: {
                defer {
                    self.current_owner_prelude = previous_tail_prelude;
                    self.current_owner_reserved = previous_tail_reserved;
                }
                break :lowered try self.lowerExpr(t_id);
            };
            for (tail_prelude.items) |prelude_stmt| {
                try stmts_list.append(self.alloc, prelude_stmt);
                try self.appendCollectorStmtIdentifiers(prelude_stmt, &tail_reserved);
            }
            try reserved_names.appendSlice(self.alloc, tail_reserved.items[reserved_start..]);
            break :blk try self.allocExpr(lowered_tail);
        } else promoted_argument_tail;

        if (previous_owner_reserved) |parent| {
            try parent.appendSlice(self.alloc, reserved_names.items[parent_reserved_start..]);
        }

        const stmts = try stmts_list.toOwnedSlice(self.alloc);
        const label = if (be.labelled) |l| try self.alloc.dupe(u8, l) else null;
        return .{
            .label = label,
            .stmts = stmts,
            .expr = tail_expr,
        };
    }
};
