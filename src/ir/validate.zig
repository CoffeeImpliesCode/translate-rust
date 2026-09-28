const std = @import("std");
const bodies_mod = @import("bodies.zig");
const exprs = @import("exprs.zig");
const graph_mod = @import("graph.zig");
const items = @import("items.zig");
const serialize = @import("serialize.zig");
const spine = @import("spine.zig");
const types_mod = @import("types.zig");

const RustIr = serialize.RustIr;
const Bodies = bodies_mod.Bodies;
const Type = types_mod.Type;
const GenericNames = []const []const u8;

/// Errors returned when the IR cannot safely enter backend lowering.
pub const ValidationError = error{
    OutOfMemory,
    NoCrate,
    MissingRootModule,
    InvalidEntityId,
    InvalidModuleId,
    InvalidModuleEntity,
    InvalidParent,
    InvalidResolvedEntity,
    UnknownModuleItem,
    MissingModuleItem,
    DuplicateModuleItem,
    InvalidModuleItemParent,
    MissingUseMetadata,
    InvalidUseMetadata,
    InvalidDependency,
    UnownedEntity,
    InvalidBodyTable,
    MissingBodyMetadata,
    BodyKindMismatch,
    InvalidNodeId,
    InvalidExprRef,
    InvalidStatementRef,
    InvalidPatternRef,
    InvalidTypeRef,
    InvalidTypeTraversal,
    InvalidEntityReference,
    InvalidLiteralDefinition,
    InvalidExternalVariant,
    InvalidFunctionBody,
    InvalidTypePath,
    UnresolvedTypePath,
    UnsupportedExternalNominalType,
    UnsupportedExpression,
    UnsupportedPattern,
    UnsupportedType,
    IncompleteGenericMetadata,
    InvalidCoreCallArity,
    InvalidCoreFunctionArity,
};
/// Reason text of the most recent `.unsupported` expression this module
/// rejected, or null when none is pending. The frontend records a precise
/// reason per unsupported construct ("cast target type", "macro {s}", ...);
/// without this the only thing a caller could ever see was the bare error.
/// Thread-local so concurrent validations cannot cross-contaminate.
threadlocal var pending_unsupported_reason: ?[]const u8 = null;

/// Read and clear the pending unsupported-expression reason. Returns null
/// when the last validation failed for some other reason, or accepted the IR.
pub fn takeUnsupportedReason() ?[]const u8 {
    const reason = pending_unsupported_reason;
    pending_unsupported_reason = null;
    return reason;
}

/// Validate all invariants required before target-specific lowering.
///
/// This is intentionally strict. A missing record, unresolved reference, or
/// explicit unsupported marker is an error instead of an empty declaration or
/// a skipped item.
pub fn validateForTranslation(ir: *const RustIr) ValidationError!void {
    // A fresh run never inherits the previous run's diagnosis.
    pending_unsupported_reason = null;
    try validateGraph(ir);
    try validateInstantiations(ir);
    try validateBodies(ir);
}

fn validEntity(ir: *const RustIr, id: spine.EntityId) bool {
    return @as(usize, id) < ir.graph.symbol_table.entities.items.len;
}

fn entity(ir: *const RustIr, id: spine.EntityId) ValidationError!spine.Entity {
    if (!validEntity(ir, id)) return error.InvalidEntityReference;
    return ir.graph.symbol_table.entities.items[id];
}

fn validateEntityRef(ir: *const RustIr, id: spine.EntityId) ValidationError!void {
    _ = try entity(ir, id);
}

fn validExpr(b: *const Bodies, id: exprs.NodeId) bool {
    return @as(usize, id) < b.exprs.len;
}

fn validStmt(b: *const Bodies, id: exprs.NodeId) bool {
    return @as(usize, id) < b.stmts.len;
}

fn validPat(b: *const Bodies, id: exprs.NodeId) bool {
    return @as(usize, id) < b.pats.len;
}

fn validTypeRefInBodies(b: *const Bodies, id: exprs.TypeId) bool {
    return @as(usize, id) < b.types.len;
}

fn validateExprRef(b: *const Bodies, id: exprs.NodeId) ValidationError!void {
    if (!validExpr(b, id)) return error.InvalidExprRef;
}

fn validateStmtRef(b: *const Bodies, id: exprs.NodeId) ValidationError!void {
    if (!validStmt(b, id)) return error.InvalidStatementRef;
}

fn validatePatRef(b: *const Bodies, id: exprs.NodeId) ValidationError!void {
    if (!validPat(b, id)) return error.InvalidPatternRef;
}

fn validateTypeRef(b: *const Bodies, id: exprs.TypeId) ValidationError!void {
    if (!validTypeRefInBodies(b, id)) return error.InvalidTypeRef;
}

fn requiresParent(kind: spine.EntityKind) bool {
    return switch (kind) {
        .module, .crate_ => false,
        else => true,
    };
}

fn moduleEntityForRow(ir: *const RustIr, module: *const graph_mod.Module) ValidationError!spine.EntityId {
    var match: ?spine.EntityId = null;
    for (ir.graph.symbol_table.entities.items) |ent| {
        if (ent.kind != .module) continue;
        if (ent.parent != module.parent) continue;
        if (!std.mem.eql(u8, ent.name, module.name)) continue;
        if (match != null) return error.InvalidModuleEntity;
        match = ent.id;
    }
    return match orelse error.InvalidModuleEntity;
}

fn validateEntityOwnership(ir: *const RustIr, ent: spine.Entity) ValidationError!void {
    if (!requiresParent(ent.kind)) return;
    var owner_id = ent.parent orelse return error.MissingModuleItem;
    var depth: usize = 0;
    while (depth < ir.graph.symbol_table.entities.items.len) : (depth += 1) {
        const owner = entity(ir, owner_id) catch return error.InvalidParent;
        if (owner.kind == .module) {
            if (ir.graph.moduleForEntity(owner.id) == null) return error.InvalidModuleEntity;
            return;
        }
        owner_id = owner.parent orelse return error.MissingModuleItem;
    }
    return error.InvalidParent;
}

fn validateGraph(ir: *const RustIr) ValidationError!void {
    const graph = &ir.graph;
    try graph.validateTopology();
    const entities = graph.symbol_table.entities.items;

    if (graph.crates.items.len == 0) return error.NoCrate;
    if (graph.modules.items.len == 0) return error.MissingRootModule;

    for (entities, 0..) |ent, index| {
        if (@as(usize, ent.id) != index) return error.InvalidEntityId;
    }

    // Check crate roots before walking module rows so a bad root always fails
    // as a missing root, never as an apparently empty crate.
    for (graph.crates.items) |crate| {
        if (!validEntity(ir, crate.root)) return error.MissingRootModule;
        const root_entity = entities[crate.root];
        const root_module = graph.moduleForEntity(crate.root) orelse return error.MissingRootModule;
        if (root_entity.kind != .module or
            root_module.kind != .root or
            !root_module.is_crate or
            root_module.parent != null)
        {
            return error.MissingRootModule;
        }
    }

    for (graph.modules.items, 0..) |module, index| {
        if (@as(usize, module.id) != index) return error.InvalidModuleId;
        const module_entity_id = try moduleEntityForRow(ir, &module);
        for (graph.modules.items[0..index]) |prior| {
            const prior_entity_id = try moduleEntityForRow(ir, &prior);
            if (prior_entity_id == module_entity_id) return error.InvalidModuleId;
        }

        if (module.parent) |parent_id| {
            if (!validEntity(ir, parent_id)) return error.InvalidParent;
            if (entities[parent_id].kind != .module) return error.InvalidParent;
            if (graph.moduleForEntity(parent_id) == null) return error.InvalidParent;
        }

        for (module.items, 0..) |item_id, item_index| {
            if (!validEntity(ir, item_id)) return error.UnknownModuleItem;
            const item = entities[item_id];
            const parent_id = item.parent orelse return error.InvalidModuleItemParent;
            if (parent_id != module_entity_id) return error.InvalidModuleItemParent;
            for (module.items[0..item_index]) |prior| {
                if (prior == item_id) return error.DuplicateModuleItem;
            }
        }
    }

    for (entities) |ent| {
        if (ent.parent) |parent_id| {
            if (!validEntity(ir, parent_id)) return error.InvalidParent;
            if (entities[parent_id].kind == .module and
                !graph.moduleHasItem(parent_id, ent.id))
            {
                return error.MissingModuleItem;
            }
        } else if (requiresParent(ent.kind)) {
            return error.MissingModuleItem;
        }
        if (requiresParent(ent.kind)) try validateEntityOwnership(ir, ent);
        if (ent.kind == .method_ref) {
            const parent_id = ent.parent orelse return error.MissingModuleItem;
            const parent = entities[parent_id];
            switch (parent.kind) {
                .fn_ => {},
                .trait_ => {
                    if (@as(usize, parent_id) >= ir.bodies.bodies.len) {
                        return error.MissingBodyMetadata;
                    }
                    const trait_body = switch (ir.bodies.bodies[parent_id]) {
                        .trait_ => |body| body,
                        else => return error.BodyKindMismatch,
                    };
                    var found = false;
                    for (trait_body.methods) |method| {
                        if (std.mem.eql(u8, method.name, ent.name)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return error.InvalidParent;
                },
                else => return error.InvalidParent,
            }
            if (ent.resolved != null) return error.InvalidResolvedEntity;
        }
        if (ent.resolved) |resolved_id| {
            if (!validEntity(ir, resolved_id)) return error.InvalidResolvedEntity;
        }
        if (ent.kind == .module) {
            const module = graph.moduleForEntity(ent.id) orelse return error.InvalidModuleEntity;
            if (ent.parent == null and !module.is_extern) {
                var is_crate_root = false;
                for (graph.crates.items) |crate| {
                    if (crate.root == ent.id) {
                        is_crate_root = true;
                        break;
                    }
                }
                if (!is_crate_root or module.kind != .root or !module.is_crate) {
                    return error.MissingModuleItem;
                }
            }
        }
        if (ent.kind == .use_) {
            const use_decl = graph.useById(ent.id) orelse return error.MissingUseMetadata;
            if (use_decl.kind != .external and !validEntity(ir, use_decl.target)) {
                return error.InvalidUseMetadata;
            }
            switch (use_decl.kind) {
                .plain => |target| try validateEntityRef(ir, target),
                .alias => |target| try validateEntityRef(ir, target),
                .glob => {},
                .external => |external| {
                    if (use_decl.target != 0 or ent.resolved != null or
                        external.path.len == 0)
                    {
                        return error.InvalidUseMetadata;
                    }
                    for (external.path) |segment| {
                        if (segment.len == 0) return error.InvalidUseMetadata;
                    }
                },
            }
        }
    }

    for (graph.uses.items, 0..) |use_decl, index| {
        if (!validEntity(ir, use_decl.id)) return error.InvalidUseMetadata;
        if (entities[use_decl.id].kind != .use_) return error.InvalidUseMetadata;
        if (!validEntity(ir, use_decl.target)) return error.InvalidUseMetadata;
        for (graph.uses.items[0..index]) |prior| {
            if (prior.id == use_decl.id) return error.InvalidUseMetadata;
        }
    }
}

fn validateInstantiations(ir: *const RustIr) ValidationError!void {
    for (ir.instantiations) |instantiation| {
        if (instantiation.zig_suffix.len == 0) return error.IncompleteGenericMetadata;
        try validateEntityRef(ir, instantiation.generic_id);
        const generic_count = genericCountForEntity(ir, instantiation.generic_id) orelse
            return error.IncompleteGenericMetadata;
        if (generic_count == 0 or instantiation.args.params.len != generic_count) {
            return error.IncompleteGenericMetadata;
        }
        for (instantiation.args.params) |arg| {
            try validateType(ir, &ir.bodies, arg, &.{});
        }
    }
}

fn isTraitAssocConstDeclaration(ir: *const RustIr, id: spine.EntityId) bool {
    const entity_value = ir.graph.symbol_table.entities.items[id];
    const parent_id = entity_value.parent orelse return false;
    if (@as(usize, parent_id) >= ir.graph.symbol_table.entities.items.len) return false;
    if (ir.graph.symbol_table.entities.items[parent_id].kind != .trait_) return false;
    if (@as(usize, parent_id) >= ir.bodies.bodies.len) return false;
    const trait_body = switch (ir.bodies.bodies[parent_id]) {
        .trait_ => |body| body,
        else => return false,
    };
    for (trait_body.assoc_consts) |assoc_const| {
        if (std.mem.eql(u8, assoc_const.name, entity_value.name)) return true;
    }
    return false;
}

fn validateBodies(ir: *const RustIr) ValidationError!void {
    const b = &ir.bodies;
    const entity_count = ir.graph.symbol_table.entities.items.len;
    // Wire v1 carries no body table. Reject it at the translation boundary,
    // even when the crate happens to contain no body-bearing declaration.
    if (b.bodies.len == 0) return error.InvalidBodyTable;
    if (b.bodies.len > entity_count) return error.InvalidBodyTable;

    // Types are validated at their actual use sites below. A generic type may
    // be legal in one owner's context and invalid when reused elsewhere.
    var context_seen: ContextSeen = .{
        .expressions = &.{},
        .statements = &.{},
        .patterns = &.{},
        .body_types = &.{},
        .root_types = &.{},
        .paired_types = &.{},
    };
    defer {
        ir.graph.allocator.free(context_seen.expressions);
        ir.graph.allocator.free(context_seen.statements);
        ir.graph.allocator.free(context_seen.patterns);
        ir.graph.allocator.free(context_seen.body_types);
        ir.graph.allocator.free(context_seen.root_types);
        ir.graph.allocator.free(context_seen.paired_types);
    }
    context_seen.expressions = ir.graph.allocator.alloc(bool, b.exprs.len) catch
        return error.OutOfMemory;
    context_seen.statements = ir.graph.allocator.alloc(bool, b.stmts.len) catch
        return error.OutOfMemory;
    context_seen.patterns = ir.graph.allocator.alloc(bool, b.pats.len) catch
        return error.OutOfMemory;
    context_seen.body_types = ir.graph.allocator.alloc(bool, b.types.len) catch
        return error.OutOfMemory;
    context_seen.root_types = ir.graph.allocator.alloc(bool, ir.types.len) catch
        return error.OutOfMemory;
    const paired_count = @min(ir.types.len, b.types.len);
    context_seen.paired_types = ir.graph.allocator.alloc(bool, paired_count) catch
        return error.OutOfMemory;
    for (context_seen.paired_types, 0..) |*paired, index| {
        paired.* = types_mod.deepEqual(ir.types[index], b.types[index]);
    }
    @memset(context_seen.expressions, false);
    @memset(context_seen.statements, false);
    @memset(context_seen.patterns, false);
    @memset(context_seen.body_types, false);
    @memset(context_seen.root_types, false);

    var walker = exprs.NodeWalker.init(
        ir.graph.allocator,
        b.exprs,
        b.stmts,
        b.pats,
        b.types,
    ) catch return error.OutOfMemory;
    defer walker.deinit();

    for (ir.graph.symbol_table.entities.items, 0..) |ent, entity_id| {
        const body = if (entity_id < b.bodies.len) b.bodies[entity_id] else null;
        switch (ent.kind) {
            .fn_ => {
                const body_kind = body orelse return error.MissingBodyMetadata;
                const fn_body = switch (body_kind) {
                    .fn_ => |value| value,
                    else => return error.BodyKindMismatch,
                };
                try validateFnBody(
                    ir,
                    b,
                    @intCast(entity_id),
                    fn_body,
                    &walker,
                    &context_seen,
                );
            },
            .struct_ => {
                const body_kind = body orelse return error.MissingBodyMetadata;
                const struct_body = switch (body_kind) {
                    .struct_ => |value| value,
                    else => return error.BodyKindMismatch,
                };
                try validateStructBody(
                    ir,
                    b,
                    @intCast(entity_id),
                    struct_body,
                    &walker,
                    &context_seen,
                );
            },
            .union_ => {
                const body_kind = body orelse return error.MissingBodyMetadata;
                const struct_body = switch (body_kind) {
                    .struct_ => |value| value,
                    else => return error.BodyKindMismatch,
                };
                try validateStructBody(
                    ir,
                    b,
                    @intCast(entity_id),
                    struct_body,
                    &walker,
                    &context_seen,
                );
            },
            .enum_ => {
                const body_kind = body orelse return error.MissingBodyMetadata;
                const enum_body = switch (body_kind) {
                    .enum_ => |value| value,
                    else => return error.BodyKindMismatch,
                };
                try validateEnumBody(ir, b, @intCast(entity_id), enum_body);
            },
            .const_, .static_ => {
                const body_kind = body orelse return error.MissingBodyMetadata;
                switch (body_kind) {
                    .none => {
                        if (ent.kind != .const_ or
                            !isTraitAssocConstDeclaration(ir, @intCast(entity_id)))
                        {
                            return error.BodyKindMismatch;
                        }
                    },
                    .const_ => |const_body| try validateConstBody(
                        ir,
                        b,
                        @intCast(entity_id),
                        const_body,
                        &walker,
                        &context_seen,
                    ),
                    else => return error.BodyKindMismatch,
                }
            },
            .type_alias => {
                const body_kind = body orelse return error.MissingBodyMetadata;
                const alias_body = switch (body_kind) {
                    .type_alias => |value| value,
                    else => return error.BodyKindMismatch,
                };
                try validateGenericNames(alias_body.generic_params);
                // The alias's own parameters are in scope in its target, so the
                // target's null-id path segments must resolve against them.
                try validateType(ir, b, alias_body.target, alias_body.generic_params);
            },
            .impl_ => {
                const body_kind = body orelse return error.MissingBodyMetadata;
                const impl_body = switch (body_kind) {
                    .impl_ => |value| value,
                    else => return error.BodyKindMismatch,
                };
                try validateImplBody(ir, b, @intCast(entity_id), impl_body);
            },
            .trait_ => {
                if (body) |body_kind| {
                    switch (body_kind) {
                        .none => {},
                        .trait_ => |trait_body| try validateTraitBody(
                            ir,
                            b,
                            trait_body,
                            &walker,
                            &context_seen,
                        ),
                        else => return error.BodyKindMismatch,
                    }
                }
            },
            .method_ref => {
                const body_kind = body orelse return error.MissingBodyMetadata;
                switch (body_kind) {
                    .none => {},
                    else => return error.BodyKindMismatch,
                }
            },
            else => {
                if (body) |body_kind| {
                    switch (body_kind) {
                        .none => {},
                        else => return error.BodyKindMismatch,
                    }
                }
            },
        }
    }

    for (b.exprs, 0..) |expr, index| {
        try validateExpr(ir, b, expr, index);
        if (!context_seen.expressions[index]) {
            try validateCoreCallsInRoot(
                ir,
                b,
                @intCast(index),
                .{ .names = &.{} },
                &walker,
                &context_seen,
            );
        }
    }
    for (b.pats, 0..) |pattern, index| {
        try validatePattern(ir, b, pattern, index);
        if (!context_seen.patterns[index]) {
            try validateContextualNode(
                ir,
                b,
                .{ .pattern = @intCast(index) },
                .{ .names = &.{} },
                &context_seen,
            );
        }
    }
    for (b.stmts, 0..) |statement, index| {
        try validateStatement(ir, b, statement, index);
        if (!context_seen.statements[index]) {
            try validateContextualNode(
                ir,
                b,
                .{ .statement = @intCast(index) },
                .{ .names = &.{} },
                &context_seen,
            );
        }
    }
    for (ir.types, 0..) |ty, index| {
        if (!context_seen.root_types[index]) {
            try validateType(ir, b, ty, &.{});
        }
    }
    for (b.types, 0..) |ty, index| {
        if (!context_seen.body_types[index]) {
            try validateType(ir, b, ty, &.{});
        }
    }
}

fn validateImplBody(
    ir: *const RustIr,
    b: *const Bodies,
    owner: spine.EntityId,
    body: bodies_mod.ImplBody,
) ValidationError!void {
    const params = if (body.generics) |generics| generics.params else &.{};
    const self_entity = concreteSelfEntity(ir, body.self_ty);
    if (body.generics) |generics| {
        try validateGenericsContext(
            ir,
            b,
            generics,
            &.{},
            .{
                .names = &.{},
                .params = &.{},
                .implicit_self = true,
                .self_entity = self_entity,
            },
        );
    }
    const impl_context: GenericContext = .{
        .names = &.{},
        .params = params,
        .implicit_self = true,
        .self_entity = self_entity,
    };
    try validateTypeContext(ir, b, body.self_ty, impl_context);
    if (body.trait_path) |path| {
        try validateTraitPathContext(ir, path, impl_context);
        for (body.trait_args) |arg| try validateTypeContext(ir, b, arg, impl_context);
        try validateAssociatedTypeBindings(ir, b, body.trait_associated_types, impl_context);
    } else if (body.trait_args.len != 0 or body.trait_associated_types.len != 0) {
        return error.InvalidTypePath;
    }
    for (body.assoc_items, 0..) |assoc_id, index| {
        try validateEntityRef(ir, assoc_id);
        const assoc = ir.graph.symbol_table.entities.items[assoc_id];
        if (assoc.parent == null or assoc.parent.? != owner) {
            return error.InvalidEntityReference;
        }
        switch (assoc.kind) {
            .fn_, .const_, .static_, .type_alias => {},
            else => return error.InvalidEntityReference,
        }
        for (body.assoc_items[0..index]) |prior| {
            if (prior == assoc_id) return error.InvalidEntityReference;
        }
    }
}

fn validateFnBody(
    ir: *const RustIr,
    b: *const Bodies,
    owner: spine.EntityId,
    body: bodies_mod.FnBody,
    walker: *exprs.NodeWalker,
    context_seen: *ContextSeen,
) ValidationError!void {
    try validateGenericNames(body.generic_params);
    const outer = try ownerGenericContext(ir, b, owner);
    const params = if (body.generics) |generics| generics.params else &.{};
    const context: GenericContext = .{
        .names = body.generic_params,
        .params = params,
        .outer_names = outer.names,
        .outer_params = outer.params,
        .implicit_self = outer.implicit_self,
        .self_entity = outer.self_entity,
    };
    for (body.params) |param| try validateTypeContext(ir, b, param.ty, context);
    try validateTypeContext(ir, b, body.ret, context);
    if (body.generics) |generics| {
        try validateGenericsContext(ir, b, generics, body.generic_params, outer);
    }
    try validateExprRef(b, body.body);
    if (b.exprs[body.body].kind != .block) return error.InvalidFunctionBody;
    try validateCoreCallsInRoot(
        ir,
        b,
        body.body,
        context,
        walker,
        context_seen,
    );
}

fn validateStructBody(
    ir: *const RustIr,
    b: *const Bodies,
    owner: spine.EntityId,
    body: bodies_mod.StructBody,
    walker: *exprs.NodeWalker,
    context_seen: *ContextSeen,
) ValidationError!void {
    try validateGenericNames(body.generic_params);
    for (body.trait_bounds) |bound| {
        if (bound.len == 0) return error.IncompleteGenericMetadata;
    }
    const struct_context: GenericContext = .{
        .names = body.generic_params,
        .implicit_self = true,
        .self_entity = owner,
    };
    for (body.fields) |field| try validateTypeContext(ir, b, field.ty, struct_context);
    for (body.methods) |method| {
        if (method.name.len == 0) return error.IncompleteGenericMetadata;
        try validateGenericNames(method.generic_params);
        const method_params = if (method.generics) |generics| generics.params else &.{};
        const method_context: GenericContext = .{
            .names = method.generic_params,
            .params = method_params,
            .outer_names = struct_context.names,
            .outer_params = struct_context.params,
            .implicit_self = true,
            .self_entity = owner,
        };
        if (method.generics) |generics| {
            try validateGenericsContext(
                ir,
                b,
                generics,
                method.generic_params,
                struct_context,
            );
        }
        for (method.params) |param| try validateTypeContext(ir, b, param.ty, method_context);
        try validateTypeContext(ir, b, method.ret, method_context);
        try validateExprRef(b, method.body);
        if (b.exprs[method.body].kind != .block) return error.InvalidFunctionBody;
        try validateCoreCallsInRoot(
            ir,
            b,
            method.body,
            method_context,
            walker,
            context_seen,
        );
    }
}
fn validateEnumBody(
    ir: *const RustIr,
    b: *const Bodies,
    owner: spine.EntityId,
    body: bodies_mod.EnumBody,
) ValidationError!void {
    try validateGenericNames(body.generic_params);
    const enum_context: GenericContext = .{
        .names = body.generic_params,
        .implicit_self = true,
        .self_entity = owner,
    };
    for (body.variants) |variant| {
        if (variant.name.len == 0) return error.IncompleteGenericMetadata;
        switch (variant.fields) {
            .none => {},
            .tuple => |field_types| for (field_types) |ty| {
                try validateTypeContext(ir, b, ty, enum_context);
            },
            .named => |fields| for (fields) |field| {
                if (field.name.len == 0) return error.IncompleteGenericMetadata;
                try validateTypeContext(ir, b, field.ty, enum_context);
            },
        }
    }
}
fn validateTraitBody(
    ir: *const RustIr,
    b: *const Bodies,
    body: bodies_mod.TraitBody,
    walker: *exprs.NodeWalker,
    context_seen: *ContextSeen,
) ValidationError!void {
    if (body.name.len == 0) return error.IncompleteGenericMetadata;
    try validateGenericNames(body.generic_params);
    const trait_params: []const types_mod.GenericParam = if (body.generics) |generics| blk: {
        try validateGenericsContext(
            ir,
            b,
            generics,
            body.generic_params,
            .{ .names = &.{}, .implicit_self = true },
        );
        break :blk generics.params;
    } else &.{};
    const trait_context: GenericContext = .{
        .names = body.generic_params,
        .params = trait_params,
        .implicit_self = true,
    };
    for (body.supertraits) |supertrait| {
        if (supertrait.len == 0) return error.IncompleteGenericMetadata;
    }
    for (body.methods) |method| {
        if (method.name.len == 0) return error.IncompleteGenericMetadata;
        try validateGenericNames(method.generic_params);
        const method_params: []const types_mod.GenericParam = if (method.generics) |generics| blk: {
            try validateGenericsContext(
                ir,
                b,
                generics,
                method.generic_params,
                trait_context,
            );
            break :blk generics.params;
        } else &.{};
        const method_context: GenericContext = .{
            .names = method.generic_params,
            .params = method_params,
            .outer_names = body.generic_params,
            .outer_params = trait_params,
            .implicit_self = true,
        };
        for (method.params) |param| try validateTypeContext(ir, b, param.ty, method_context);
        try validateTypeContext(ir, b, method.ret, method_context);
    }
    for (body.assoc_types) |assoc_type| {
        if (assoc_type.name.len == 0) return error.IncompleteGenericMetadata;
        const assoc_context: GenericContext = if (assoc_type.generics) |generics| blk: {
            try validateGenericsContext(ir, b, generics, &.{}, trait_context);
            break :blk .{
                .names = &.{},
                .params = generics.params,
                .outer_names = body.generic_params,
                .outer_params = trait_params,
                .implicit_self = true,
            };
        } else trait_context;
        for (assoc_type.bounds) |bound| {
            try validateBoundContext(ir, b, bound, assoc_context);
        }
        if (assoc_type.default) |default| {
            try validateTypeContext(ir, b, default, assoc_context);
        }
    }
    for (body.assoc_consts) |assoc_const| {
        if (assoc_const.name.len == 0) return error.IncompleteGenericMetadata;
        try validateTypeContext(ir, b, assoc_const.ty, trait_context);
        if (assoc_const.default) |default| {
            try validateExprRef(b, default);
            try validateCoreCallsInRoot(
                ir,
                b,
                default,
                trait_context,
                walker,
                context_seen,
            );
        }
    }
}

fn validateConstBody(
    ir: *const RustIr,
    b: *const Bodies,
    owner: spine.EntityId,
    body: bodies_mod.ConstBody,
    walker: *exprs.NodeWalker,
    context_seen: *ContextSeen,
) ValidationError!void {
    const context = try ownerGenericContext(ir, b, owner);
    try validateTypeContext(ir, b, body.ty, context);
    try validateExprRef(b, body.init);
    try validateCoreCallsInRoot(
        ir,
        b,
        body.init,
        context,
        walker,
        context_seen,
    );
}

fn validateStructLiteralDefinition(ir: *const RustIr, id: spine.EntityId) ValidationError!void {
    const definition = try entity(ir, id);
    switch (definition.kind) {
        .struct_, .union_ => {},
        else => return error.InvalidLiteralDefinition,
    }
}

fn validateEnumLiteralDefinition(ir: *const RustIr, id: spine.EntityId) ValidationError!void {
    const definition = try entity(ir, id);
    if (definition.kind != .enum_) return error.InvalidLiteralDefinition;
}

fn validateField(ir: *const RustIr, b: *const Bodies, field: items.Field, generic_names: GenericNames) ValidationError!void {
    if (field.name.len == 0) return error.IncompleteGenericMetadata;
    try validateType(ir, b, field.ty, generic_names);
}

fn validateGenericNames(names: GenericNames) ValidationError!void {
    for (names, 0..) |name, index| {
        if (name.len == 0) return error.IncompleteGenericMetadata;
        for (names[0..index]) |prior| {
            if (std.mem.eql(u8, prior, name)) return error.IncompleteGenericMetadata;
        }
    }
}

fn validateGenericPathContext(
    ir: *const RustIr,
    b: *const Bodies,
    path: types_mod.Path,
    context: GenericContext,
) ValidationError!void {
    if (path.segments.len == 0) return error.InvalidTypePath;
    if (try validateImplicitSelfPath(ir, b, path, context)) return;
    var generic_root = false;
    for (path.segments, 0..) |segment, index| {
        if (segment.name.len == 0) return error.InvalidTypePath;
        if (segment.id) |id| {
            try validateEntityRef(ir, id);
        } else if (index == 0 and contextGenericNameKnown(context, segment.name)) {
            generic_root = true;
        } else if (!generic_root) {
            return error.UnresolvedTypePath;
        }
    }
}
fn normalizedNameEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_char, right_char| {
        const normalized_left = if (left_char == '-') '_' else left_char;
        const normalized_right = if (right_char == '-') '_' else right_char;
        if (normalized_left != normalized_right) return false;
    }
    return true;
}

fn isExternalRootName(ir: *const RustIr, name: []const u8) bool {
    if (std.mem.eql(u8, name, "alloc") or
        std.mem.eql(u8, name, "core") or
        std.mem.eql(u8, name, "std"))
    {
        return true;
    }
    for (ir.graph.crates.items) |crate| {
        for (crate.deps) |dependency| {
            if (normalizedNameEqual(dependency.local_alias, name) or
                normalizedNameEqual(dependency.extern_name, name))
            {
                return true;
            }
        }
    }
    return false;
}

fn isExternalRoot(ir: *const RustIr, path: []const []const u8) bool {
    if (path.len == 0) return false;
    return isExternalRootName(ir, path[0]);
}

fn isExternalTraitPath(ir: *const RustIr, path: types_mod.Path) bool {
    if (path.segments.len == 0) return false;
    if (!isExternalRootName(ir, path.segments[0].name)) return false;
    for (path.segments) |segment| {
        if (segment.id != null) return false;
    }
    return true;
}

fn validateTraitPath(
    ir: *const RustIr,
    path: types_mod.Path,
    generic_names: GenericNames,
    generic_params: []const types_mod.GenericParam,
) ValidationError!void {
    return validateTraitPathContext(
        ir,
        path,
        .{ .names = generic_names, .params = generic_params },
    );
}

fn validateTraitPathContext(
    ir: *const RustIr,
    path: types_mod.Path,
    context: GenericContext,
) ValidationError!void {
    if (path.segments.len == 0) return error.InvalidTypePath;
    if (isExternalTraitPath(ir, path)) {
        for (path.segments) |segment| {
            if (segment.name.len == 0) return error.InvalidTypePath;
        }
        return;
    }

    const terminal = path.segments[path.segments.len - 1];
    const terminal_id = terminal.id orelse return error.UnresolvedTypePath;
    const terminal_entity = try entity(ir, terminal_id);
    if (terminal_entity.kind != .trait_) return error.InvalidTypePath;
    for (path.segments, 0..) |segment, index| {
        if (segment.name.len == 0) return error.InvalidTypePath;
        if (segment.id) |id| {
            const resolved = try entity(ir, id);
            if (!std.mem.eql(u8, resolved.name, segment.name)) {
                return error.InvalidTypePath;
            }
            if (index + 1 < path.segments.len and
                resolved.kind != .module and resolved.kind != .extern_crate)
            {
                return error.InvalidTypePath;
            }
        } else if (index == 0 and contextGenericNameKnown(context, segment.name)) {
            continue;
        }
    }
}

fn validateAssociatedTypeBindings(
    ir: *const RustIr,
    b: *const Bodies,
    bindings: []const types_mod.AssociatedTypeBinding,
    context: GenericContext,
) ValidationError!void {
    return validateAssociatedTypeBindingsDepth(ir, b, bindings, context, 0);
}

fn validateAssociatedTypeBindingsDepth(
    ir: *const RustIr,
    b: *const Bodies,
    bindings: []const types_mod.AssociatedTypeBinding,
    context: GenericContext,
    depth: usize,
) ValidationError!void {
    for (bindings, 0..) |binding, index| {
        if (binding.name.len == 0) return error.IncompleteGenericMetadata;
        for (bindings[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, binding.name)) {
                return error.IncompleteGenericMetadata;
            }
        }
        try validateTypeContextDepth(ir, b, binding.ty, context, depth);
    }
}

fn validateBoundContext(
    ir: *const RustIr,
    b: *const Bodies,
    bound: types_mod.Bound,
    context: GenericContext,
) ValidationError!void {
    return validateBoundContextDepth(ir, b, bound, context, 0);
}

fn validateBoundContextDepth(
    ir: *const RustIr,
    b: *const Bodies,
    bound: types_mod.Bound,
    context: GenericContext,
    depth: usize,
) ValidationError!void {
    try validateTraitPathContext(ir, bound.path, context);
    for (bound.args) |arg| {
        try validateTypeContextDepth(ir, b, arg, context, depth);
    }
    try validateAssociatedTypeBindingsDepth(ir, b, bound.associated_types, context, depth);
}

fn validateGenerics(
    ir: *const RustIr,
    b: *const Bodies,
    generics: types_mod.Generics,
    generic_names: GenericNames,
) ValidationError!void {
    return validateGenericsContext(
        ir,
        b,
        generics,
        generic_names,
        .{ .names = &.{} },
    );
}
fn validateGenericsContext(
    ir: *const RustIr,
    b: *const Bodies,
    generics: types_mod.Generics,
    generic_names: GenericNames,
    outer: GenericContext,
) ValidationError!void {
    const context: GenericContext = .{
        .names = generic_names,
        .params = generics.params,
        .outer_names = outer.names,
        .outer_params = outer.params,
        .implicit_self = outer.implicit_self,
        .self_entity = outer.self_entity,
    };
    for (generics.params, 0..) |param, index| {
        const name = switch (param) {
            .type_ => |value| value.name,
            .const_ => |value| value.name,
            .lifetime => |value| value.name,
        };
        if (name.len == 0) return error.IncompleteGenericMetadata;
        for (generics.params[0..index]) |prior| {
            const prior_name = switch (prior) {
                .type_ => |value| value.name,
                .const_ => |value| value.name,
                .lifetime => |value| value.name,
            };
            if (std.mem.eql(u8, name, prior_name)) return error.IncompleteGenericMetadata;
        }
        switch (param) {
            .type_ => |value| for (value.bounds) |bound| {
                try validateBoundContext(ir, b, bound, context);
            },
            .const_ => |value| try validateTypeContext(ir, b, value.ty, context),
            .lifetime => {},
        }
    }
    for (generics.where_clauses) |clause| {
        try validateGenericPathContext(ir, b, clause.self_ty, context);
        for (clause.bounds) |bound| {
            try validateBoundContext(ir, b, bound, context);
        }
    }
}

const ContextSeen = struct {
    expressions: []bool,
    statements: []bool,
    patterns: []bool,
    body_types: []bool,
    root_types: []bool,
    paired_types: []bool,
};
/// The declared generic-parameter count of `id`, or null when the entity
/// carries none.
///
/// A `.method_ref` is a call-site reference with no body of its own, so its
/// count has to be read from the declaration it names: its parent is the
/// trait or `fn_` that declares the method, and the matching child carries
/// the signature. This is a read of already-lowered metadata — it does NOT
/// perform method resolution, which stays with `resolveMethods` and the
/// backend's `methodEntityForDefinition`.
///
/// A `.method_ref` whose parent is missing, is not a declaration, or declares
/// no child of that name yields null, so every caller keeps rejecting with
/// `IncompleteGenericMetadata` exactly as before. The walk visits entities
/// strictly below the parent, so it cannot recurse.
fn genericCountForEntity(ir: *const RustIr, id: spine.EntityId) ?usize {
    if (@as(usize, id) >= ir.bodies.bodies.len) return null;
    if (@as(usize, id) < ir.graph.symbol_table.entities.items.len and
        isTraitAssocConstDeclaration(ir, id))
    {
        return 1;
    }

    switch (ir.bodies.bodies[id]) {
        .fn_ => |body| return body.generic_params.len,
        .struct_ => |body| return body.generic_params.len,
        .enum_ => |body| return body.generic_params.len,
        else => {},
    }
    return methodRefGenericCount(ir, id);
}

/// True when `id` is a `.method_ref` that names a method no entity in this
/// crate declares — the shape a standard-library method call has.
///
/// `resolveMethods` deliberately leaves a std method as a bodiless
/// `.method_ref`, because the backend selects the implementation from the
/// receiver type and the method name. There is no arity to check against such
/// a callee, and reporting missing metadata would misdescribe the situation:
/// nothing is missing, none is owed. A `.method_ref` whose parent DOES declare
/// the method is excluded, so a real declaration is still arity-checked.
fn isUndeclaredMethodReference(ir: *const RustIr, id: spine.EntityId) bool {
    const entities = ir.graph.symbol_table.entities.items;
    if (@as(usize, id) >= entities.len) return false;
    if (entities[id].kind != .method_ref) return false;
    return methodRefGenericCount(ir, id) == null;
}

/// Generic count of the method a `.method_ref` names, found by matching its
/// name against the `fn_` children of the entity that declares it. Returns
/// null when the reference cannot be tied to a declaration.
fn methodRefGenericCount(ir: *const RustIr, method_ref: spine.EntityId) ?usize {
    const entities = ir.graph.symbol_table.entities.items;
    if (@as(usize, method_ref) >= entities.len) return null;
    if (entities[method_ref].kind != .method_ref) return null;
    const parent_id = entities[method_ref].parent orelse return null;
    if (@as(usize, parent_id) >= entities.len) return null;

    // A trait declares its methods in the body, not as child entities, so read
    // the signature from the trait's own method list.
    if (entities[parent_id].kind == .trait_) {
        if (@as(usize, parent_id) >= ir.bodies.bodies.len) return null;
        const trait_body = switch (ir.bodies.bodies[parent_id]) {
            .trait_ => |body| body,
            else => return null,
        };
        for (trait_body.methods) |method| {
            if (std.mem.eql(u8, method.name, entities[method_ref].name)) {
                return method.generic_params.len;
            }
        }
        return null;
    }

    // Otherwise the declaring owner is the parent itself, and the method is a
    // child `fn_` of it. The walk descends exactly one level, so a `fn_` parent
    // (the shape `pushMethodRef` produces) simply finds nothing and returns
    // null rather than chasing its own children.
    for (entities, 0..) |candidate, index| {
        if (candidate.parent == null or candidate.parent.? != parent_id) continue;
        if (candidate.kind != .fn_) continue;
        if (!std.mem.eql(u8, candidate.name, entities[method_ref].name)) continue;
        if (index >= ir.bodies.bodies.len) continue;
        return switch (ir.bodies.bodies[index]) {
            .fn_ => |body| body.generic_params.len,
            else => null,
        };
    }
    return null;
}

fn genericNameKnown(generic_names: GenericNames, name: []const u8) bool {
    for (generic_names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

const GenericContext = struct {
    names: GenericNames,
    params: []const types_mod.GenericParam = &.{},
    outer_names: GenericNames = &.{},
    outer_params: []const types_mod.GenericParam = &.{},
    implicit_self: bool = false,
    self_entity: ?spine.EntityId = null,
};
fn ownerGenericContext(
    ir: *const RustIr,
    b: *const Bodies,
    owner: spine.EntityId,
) ValidationError!GenericContext {
    const entities = ir.graph.symbol_table.entities.items;
    if (@as(usize, owner) >= entities.len) return error.InvalidEntityReference;

    var parent_id = entities[owner].parent orelse return .{ .names = &.{} };
    var depth: usize = 0;
    while (depth < entities.len) : (depth += 1) {
        if (@as(usize, parent_id) >= entities.len) return error.InvalidParent;
        const parent = entities[parent_id];
        switch (parent.kind) {
            .impl_ => {
                if (@as(usize, parent_id) >= b.bodies.len) return error.MissingBodyMetadata;
                const impl_body = switch (b.bodies[parent_id]) {
                    .impl_ => |body| body,
                    else => return error.BodyKindMismatch,
                };
                return .{
                    .names = &.{},
                    .params = if (impl_body.generics) |generics| generics.params else &.{},
                    .implicit_self = true,
                    .self_entity = concreteSelfEntity(ir, impl_body.self_ty),
                };
            },
            .struct_, .union_ => {
                if (@as(usize, parent_id) >= b.bodies.len) return error.MissingBodyMetadata;
                const struct_body = switch (b.bodies[parent_id]) {
                    .struct_ => |body| body,
                    else => return error.BodyKindMismatch,
                };
                return .{
                    .names = struct_body.generic_params,
                    .implicit_self = true,
                    .self_entity = parent.id,
                };
            },
            .trait_ => {
                if (@as(usize, parent_id) >= b.bodies.len) return error.MissingBodyMetadata;
                return switch (b.bodies[parent_id]) {
                    .trait_ => |body| .{
                        .names = body.generic_params,
                        .params = if (body.generics) |generics| generics.params else &.{},
                        .implicit_self = true,
                    },
                    .none => .{ .names = &.{}, .implicit_self = true },
                    else => error.BodyKindMismatch,
                };
            },
            .fn_, .module, .crate_ => return .{ .names = &.{} },
            else => {},
        }
        parent_id = parent.parent orelse return .{ .names = &.{} };
    }
    return error.InvalidParent;
}

fn genericParamNameKnown(params: []const types_mod.GenericParam, name: []const u8) bool {
    for (params) |param| {
        const candidate = switch (param) {
            .type_ => |value| value.name,
            .const_ => |value| value.name,
            .lifetime => |value| value.name,
        };
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}
fn contextGenericNameKnown(context: GenericContext, name: []const u8) bool {
    return (context.implicit_self and std.mem.eql(u8, name, "Self")) or
        genericNameKnown(context.names, name) or
        genericParamNameKnown(context.params, name) or
        genericNameKnown(context.outer_names, name) or
        genericParamNameKnown(context.outer_params, name);
}

fn concreteSelfEntity(ir: *const RustIr, ty: Type) ?spine.EntityId {
    const candidate: ?spine.EntityId = switch (ty) {
        .path => |path| if (path.segments.len == 0)
            null
        else
            path.segments[path.segments.len - 1].id,
        .generic_inst => |generic| generic.decl,
        .reference => |reference| concreteSelfEntity(ir, reference.pointee),
        .raw_ptr => |raw_ptr| concreteSelfEntity(ir, raw_ptr.pointee),
        .boxed => |boxed| concreteSelfEntity(ir, boxed.*),
        else => null,
    };
    if (candidate) |id| {
        if (validEntity(ir, id)) return id;
    }
    return null;
}

fn validateImplicitSelfPath(
    ir: *const RustIr,
    b: *const Bodies,
    path: types_mod.Path,
    context: GenericContext,
) ValidationError!bool {
    if (path.segments.len == 0) return false;
    const first = path.segments[0];
    if (!std.mem.eql(u8, first.name, "Self")) return false;
    if (!context.implicit_self) return false;
    if (first.id) |id| {
        const expected = context.self_entity orelse return error.InvalidTypePath;
        if (id != expected) return error.InvalidTypePath;
        const self_entity = try entity(ir, id);
        switch (self_entity.kind) {
            .struct_, .union_, .enum_ => {},
            else => return error.InvalidTypePath,
        }
    }
    if (path.segments.len == 1) return true;
    if (path.segments.len != 3) return error.InvalidTypePath;
    const trait_segment = path.segments[1];
    const assoc_segment = path.segments[2];
    const trait_id = trait_segment.id orelse return error.UnresolvedTypePath;
    const trait = try entity(ir, trait_id);
    if (trait.kind != .trait_ or
        !std.mem.eql(u8, trait.name, trait_segment.name) or
        assoc_segment.id != null or trait_segment.name.len == 0 or
        assoc_segment.name.len == 0)
    {
        return error.InvalidTypePath;
    }
    const trait_body = if (@as(usize, trait_id) < b.bodies.len) switch (b.bodies[trait_id]) {
        .trait_ => |body| body,
        else => return error.InvalidTypePath,
    } else return error.InvalidEntityReference;
    for (trait_body.assoc_types) |assoc_type| {
        if (std.mem.eql(u8, assoc_type.name, assoc_segment.name)) return true;
    }
    return error.UnresolvedTypePath;
}

fn validateType(
    ir: *const RustIr,
    b: *const Bodies,
    ty: Type,
    generic_names: GenericNames,
) ValidationError!void {
    return validateTypeContext(ir, b, ty, .{ .names = generic_names });
}

fn validateTypeContext(
    ir: *const RustIr,
    b: *const Bodies,
    ty: Type,
    context: GenericContext,
) ValidationError!void {
    return validateTypeContextDepth(ir, b, ty, context, 0);
}

fn validateTypeContextDepth(
    ir: *const RustIr,
    b: *const Bodies,
    ty: Type,
    context: GenericContext,
    depth: usize,
) ValidationError!void {
    if (depth >= types_mod.traversal_depth_max) return error.InvalidTypeTraversal;
    const child_depth = depth + 1;
    switch (ty) {
        .path => |path| {
            if (path.segments.len == 0) return error.InvalidTypePath;
            if (try validateImplicitSelfPath(ir, b, path, context)) return;
            var generic_root = false;
            for (path.segments, 0..) |segment, index| {
                if (segment.name.len == 0) return error.InvalidTypePath;
                if (segment.id) |id| {
                    try validateEntityRef(ir, id);
                } else if (index == 0 and contextGenericNameKnown(context, segment.name)) {
                    generic_root = true;
                } else if (!generic_root) {
                    return error.UnresolvedTypePath;
                }
            }
        },
        .external_nominal => |external| {
            try validateExternalNominal(ir, b, external, context, child_depth);
        },
        .prim => {},
        .reference => |reference| {
            try validateTypeContextDepth(ir, b, reference.pointee, context, child_depth);
        },
        .raw_ptr => |raw_ptr| {
            try validateTypeContextDepth(ir, b, raw_ptr.pointee, context, child_depth);
        },
        .slice => |slice| try validateTypeContextDepth(ir, b, slice.elem, context, child_depth),
        .array => |array| {
            try validateTypeContextDepth(ir, b, array.elem, context, child_depth);
            switch (array.len) {
                .literal => {},
                .generic => |index| {
                    if (@as(usize, index) >= context.names.len and
                        @as(usize, index) >= context.params.len)
                    {
                        return error.IncompleteGenericMetadata;
                    }
                },
                .expression => |expression| try validateExprRef(b, expression),
            }
        },
        .tuple => |elements| for (elements) |element| {
            try validateTypeContextDepth(ir, b, element, context, child_depth);
        },
        .fn_ptr => |fn_ptr| {
            for (fn_ptr.params) |param| {
                try validateTypeContextDepth(ir, b, param, context, child_depth);
            }
            try validateTypeContextDepth(ir, b, fn_ptr.ret, context, child_depth);
        },
        .generic_inst => |generic| {
            try validateEntityRef(ir, generic.decl);
            const generic_count = genericCountForEntity(ir, generic.decl) orelse
                return error.IncompleteGenericMetadata;
            if (generic_count == 0 or generic.args.params.len != generic_count) {
                return error.IncompleteGenericMetadata;
            }
            for (generic.args.params) |arg| {
                try validateTypeContextDepth(ir, b, arg, context, child_depth);
            }
        },
        .option => |option| try validateTypeContextDepth(ir, b, option.*, context, child_depth),
        .result => |result| {
            try validateTypeContextDepth(ir, b, result.ok, context, child_depth);
            try validateTypeContextDepth(ir, b, result.err, context, child_depth);
        },
        .boxed => |boxed| try validateTypeContextDepth(ir, b, boxed.*, context, child_depth),
        .@"opaque" => |opaque_ty| {
            for (opaque_ty.bounds) |bound| {
                try validateBoundContextDepth(ir, b, bound, context, child_depth);
            }
            if (opaque_ty.concrete) |concrete| {
                try validateTypeContextDepth(ir, b, concrete.*, context, child_depth);
            }
        },
        .dyn_trait => |bounds| {
            for (bounds) |bound| {
                try validateBoundContextDepth(ir, b, bound, context, child_depth);
            }
        },
        .unsupported => return error.UnsupportedType,
    }
}

fn validateExternalNominal(
    ir: *const RustIr,
    b: *const Bodies,
    external: types_mod.ExternalNominal,
    context: GenericContext,
    depth: usize,
) ValidationError!void {
    if (external.path.len == 0) return error.InvalidTypePath;
    if (!isExternalRoot(ir, external.path)) return error.UnsupportedExternalNominalType;
    for (external.path) |segment| {
        if (segment.len == 0) return error.InvalidTypePath;
    }
    for (external.args) |arg| {
        try validateTypeContextDepth(ir, b, arg, context, depth);
    }
}

fn validateExternalVariantOwner(
    ir: *const RustIr,
    b: *const Bodies,
    owner: types_mod.ExternalNominal,
    context: GenericContext,
) ValidationError!void {
    try validateExternalNominal(ir, b, owner, context, 0);
    if (owner.path.len < 3) return error.InvalidExternalVariant;
    if (!std.mem.eql(u8, owner.path[owner.path.len - 2], "borrow") or
        !std.mem.eql(u8, owner.path[owner.path.len - 1], "Cow"))
    {
        return error.InvalidExternalVariant;
    }
}

fn validateExternalVariant(
    ir: *const RustIr,
    b: *const Bodies,
    variant: exprs.ExternalVariant,
    context: GenericContext,
) ValidationError!void {
    try validateExternalVariantOwner(ir, b, variant.owner, context);
    if (!std.mem.eql(u8, variant.variant, "Owned") and
        !std.mem.eql(u8, variant.variant, "Borrowed"))
    {
        return error.InvalidExternalVariant;
    }
    for (variant.tuple_fields) |field| try validateExprRef(b, field);
    for (variant.named_fields) |field| try validateFieldInit(b, field);
}

fn validateExternalVariantPattern(
    ir: *const RustIr,
    b: *const Bodies,
    variant: exprs.ExternalVariantPattern,
    context: GenericContext,
) ValidationError!void {
    try validateExternalVariantOwner(ir, b, variant.owner, context);
    if (!std.mem.eql(u8, variant.variant, "Owned") and
        !std.mem.eql(u8, variant.variant, "Borrowed"))
    {
        return error.InvalidExternalVariant;
    }
    for (variant.fields) |field| {
        if (field.field.len == 0) return error.InvalidExternalVariant;
        if (field.pat) |pattern| try validatePatRef(b, pattern);
    }
}

const CoreCallArity = struct {
    generic_count: usize,
    value_count: usize,
};

fn coreCallArity(function: exprs.CoreFunction) CoreCallArity {
    return switch (function) {
        .mem_transmute => .{ .generic_count = 2, .value_count = 1 },
        .mem_size_of => .{ .generic_count = 1, .value_count = 0 },
        .mem_size_of_val => .{ .generic_count = 1, .value_count = 1 },
        .ptr_copy_nonoverlapping => .{ .generic_count = 1, .value_count = 3 },
        .ptr_write_bytes => .{ .generic_count = 1, .value_count = 3 },
        .ptr_read_unaligned => .{ .generic_count = 1, .value_count = 1 },
        .slice_from_raw_parts => .{ .generic_count = 1, .value_count = 2 },
        .slice_from_raw_parts_mut => .{ .generic_count = 1, .value_count = 2 },
        .str_from_utf8 => .{ .generic_count = 0, .value_count = 1 },
        .str_from_utf8_unchecked => .{ .generic_count = 0, .value_count = 1 },
        .string_from_utf8 => .{ .generic_count = 0, .value_count = 1 },
        .string_from_utf8_lossy => .{ .generic_count = 0, .value_count = 1 },
        .string_from_utf8_unchecked => .{ .generic_count = 0, .value_count = 1 },
        .cmp_min => .{ .generic_count = 1, .value_count = 2 },
        .cmp_max => .{ .generic_count = 1, .value_count = 2 },
        .default_value => .{ .generic_count = 1, .value_count = 0 },
        .convert_from => .{ .generic_count = 1, .value_count = 1 },
    };
}

fn coreFunctionGenericCount(function: exprs.CoreFunction) usize {
    return switch (function) {
        .mem_transmute => 2,
        .mem_size_of, .mem_size_of_val, .ptr_copy_nonoverlapping, .ptr_write_bytes, .ptr_read_unaligned, .slice_from_raw_parts, .slice_from_raw_parts_mut, .cmp_min, .cmp_max, .default_value, .convert_from => 1,
        .str_from_utf8, .str_from_utf8_unchecked, .string_from_utf8, .string_from_utf8_lossy, .string_from_utf8_unchecked => 0,
    };
}

fn validateCoreFunction(
    ir: *const RustIr,
    b: *const Bodies,
    function: exprs.CoreFunctionValue,
    context: GenericContext,
) ValidationError!void {
    if (function.generic_args.len != coreFunctionGenericCount(function.function)) {
        return error.InvalidCoreFunctionArity;
    }
    for (function.generic_args) |argument| {
        try validateTypeContext(ir, b, argument, context);
    }
}

fn validateCoreCallShape(b: *const Bodies, call: exprs.CoreCall) ValidationError!void {
    const arity = coreCallArity(call.function);
    if (call.generic_args.len != arity.generic_count or
        call.args.len != arity.value_count)
    {
        return error.InvalidCoreCallArity;
    }
    for (call.args) |argument| {
        try validateExprRef(b, argument);
    }
}

fn validateCoreCall(
    ir: *const RustIr,
    b: *const Bodies,
    call: exprs.CoreCall,
    context: GenericContext,
) ValidationError!void {
    try validateCoreCallShape(b, call);
    for (call.generic_args) |argument| {
        try validateTypeContext(ir, b, argument, context);
    }
}

fn markBodyTypeSeen(context_seen: *ContextSeen, index: usize) void {
    context_seen.body_types[index] = true;
    if (index < context_seen.paired_types.len and context_seen.paired_types[index]) {
        context_seen.root_types[index] = true;
    }
}

fn markRootTypeSeen(context_seen: *ContextSeen, index: usize) void {
    context_seen.root_types[index] = true;
    if (index < context_seen.paired_types.len and context_seen.paired_types[index]) {
        context_seen.body_types[index] = true;
    }
}

fn validateContextualTypeRef(
    ir: *const RustIr,
    b: *const Bodies,
    id: exprs.TypeId,
    context: GenericContext,
    context_seen: *ContextSeen,
) ValidationError!void {
    try validateTypeRef(b, id);
    const index = @as(usize, id);
    markBodyTypeSeen(context_seen, index);
    try validateTypeContext(ir, b, b.types[index], context);
    if (index < context_seen.paired_types.len and context_seen.paired_types[index]) {
        try validateTypeContext(ir, b, ir.types[index], context);
    }
}

fn validateContextualRootType(
    ir: *const RustIr,
    b: *const Bodies,
    id: exprs.TypeId,
    context: GenericContext,
    context_seen: *ContextSeen,
) ValidationError!void {
    const index = @as(usize, id);
    if (index >= ir.types.len) return error.InvalidTypeRef;
    markRootTypeSeen(context_seen, index);
    try validateTypeContext(ir, b, ir.types[index], context);
    if (index < context_seen.paired_types.len and context_seen.paired_types[index]) {
        try validateTypeContext(ir, b, b.types[index], context);
    }
}

fn validateContextualClosure(
    ir: *const RustIr,
    b: *const Bodies,
    closure: exprs.ClosureExpr,
    context: GenericContext,
    context_seen: *ContextSeen,
) ValidationError!void {
    for (closure.captures) |capture| {
        try validateContextualTypeRef(ir, b, capture.ty, context, context_seen);
    }
    if (closure.return_ty) |return_ty| {
        try validateContextualTypeRef(ir, b, return_ty, context, context_seen);
    }
}

fn validateContextualExpr(
    ir: *const RustIr,
    b: *const Bodies,
    expression: exprs.Expr,
    context: GenericContext,
    context_seen: *ContextSeen,
) ValidationError!void {
    if (expression.ty) |type_id| {
        try validateContextualTypeRef(ir, b, type_id, context, context_seen);
    }
    switch (expression.kind) {
        .path => |path| for (path.generic_args) |argument| {
            try validateTypeContext(ir, b, argument, context);
        },
        .core_call => |call| try validateCoreCall(ir, b, call, context),
        .core_function => |function| try validateCoreFunction(ir, b, function, context),
        .external_variant => |variant| try validateExternalVariant(ir, b, variant, context),
        .cast => |cast| {
            try validateTypeContext(ir, b, cast.source_type, context);
            if (@as(usize, cast.target) < ir.types.len) {
                try validateContextualRootType(ir, b, cast.target, context, context_seen);
            } else {
                try validateContextualTypeRef(ir, b, cast.target, context, context_seen);
            }
        },
        .closure => |closure| try validateContextualClosure(
            ir,
            b,
            closure,
            context,
            context_seen,
        ),
        .iterator_chain => |chain| {
            switch (chain.terminal) {
                .iterator, .collect_vec, .sum => {},
            }
            for (chain.adapters) |adapter| switch (adapter) {
                .map => |map| try validateContextualClosure(
                    ir,
                    b,
                    map.closure,
                    context,
                    context_seen,
                ),
                .filter => |filter| try validateContextualClosure(
                    ir,
                    b,
                    filter.closure,
                    context,
                    context_seen,
                ),
                .flat_map => |closure| try validateContextualClosure(
                    ir,
                    b,
                    closure,
                    context,
                    context_seen,
                ),
                .enumerate, .zip, .range_rev, .other => {},
            };
        },
        else => {},
    }
}

fn validateContextualNode(
    ir: *const RustIr,
    b: *const Bodies,
    node: exprs.ReachableNode,
    context: GenericContext,
    context_seen: *ContextSeen,
) ValidationError!void {
    switch (node) {
        .expression => |id| {
            const index = @as(usize, id);
            context_seen.expressions[index] = true;
            try validateContextualExpr(ir, b, b.exprs[index], context, context_seen);
        },
        .statement => |id| {
            const index = @as(usize, id);
            const statement = b.stmts[index];
            context_seen.statements[index] = true;
            if (statement.ty) |type_id| {
                try validateContextualTypeRef(ir, b, type_id, context, context_seen);
            }
            switch (statement.kind) {
                .let => |let_statement| {
                    if (let_statement.ty) |type_id| {
                        try validateContextualTypeRef(ir, b, type_id, context, context_seen);
                    }
                },
                else => {},
            }
        },
        .pattern => |id| {
            const index = @as(usize, id);
            const pattern = b.pats[index];
            context_seen.patterns[index] = true;
            if (pattern.ty) |type_id| {
                try validateContextualTypeRef(ir, b, type_id, context, context_seen);
            }
            switch (pattern.kind) {
                .external_variant => |variant| {
                    try validateExternalVariantPattern(ir, b, variant, context);
                },
                else => {},
            }
        },
    }
}

fn validateCoreCallsInRoot(
    ir: *const RustIr,
    b: *const Bodies,
    root: exprs.NodeId,
    context: GenericContext,
    walker: *exprs.NodeWalker,
    context_seen: *ContextSeen,
) ValidationError!void {
    try walker.reset(root);
    while (try walker.next()) |node| {
        try validateContextualNode(ir, b, node, context, context_seen);
    }
}

fn typeSliceEqual(left: []const Type, right: []const Type) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_type, right_type| {
        if (!sameType(left_type, right_type)) return false;
    }
    return true;
}
fn samePath(left: types_mod.Path, right: types_mod.Path) bool {
    if (left.segments.len != right.segments.len) return false;
    for (left.segments, right.segments) |left_segment, right_segment| {
        if (!std.mem.eql(u8, left_segment.name, right_segment.name) or
            left_segment.id != right_segment.id)
        {
            return false;
        }
    }
    return true;
}

fn sameBound(left: types_mod.Bound, right: types_mod.Bound) bool {
    if (left.optional != right.optional or !samePath(left.path, right.path)) return false;
    if (left.args.len != right.args.len or
        left.associated_types.len != right.associated_types.len)
    {
        return false;
    }
    for (left.args, right.args) |left_arg, right_arg| {
        if (!sameType(left_arg, right_arg)) return false;
    }
    for (left.associated_types, right.associated_types) |left_binding, right_binding| {
        if (!std.mem.eql(u8, left_binding.name, right_binding.name) or
            !sameType(left_binding.ty, right_binding.ty))
        {
            return false;
        }
    }
    return true;
}

fn sameBoundSlice(left: []const types_mod.Bound, right: []const types_mod.Bound) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_bound, right_bound| {
        if (!sameBound(left_bound, right_bound)) return false;
    }
    return true;
}

fn sameType(left: Type, right: Type) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .path => |left_path| {
            const right_path = right.path;
            if (left_path.segments.len != right_path.segments.len) return false;
            for (left_path.segments, right_path.segments) |left_segment, right_segment| {
                if (!std.mem.eql(u8, left_segment.name, right_segment.name)) return false;
            }
            return true;
        },
        .external_nominal => |left_external| {
            const right_external = right.external_nominal;
            if (left_external.path.len != right_external.path.len) return false;
            for (left_external.path, right_external.path) |left_name, right_name| {
                if (!std.mem.eql(u8, left_name, right_name)) return false;
            }
            return typeSliceEqual(left_external.args, right_external.args);
        },
        .prim => |left_primitive| left_primitive == right.prim,
        .reference => |left_reference| {
            const right_reference = right.reference;
            return left_reference.mut == right_reference.mut and
                sameType(left_reference.pointee, right_reference.pointee);
        },
        .raw_ptr => |left_pointer| {
            const right_pointer = right.raw_ptr;
            return left_pointer.mut == right_pointer.mut and
                sameType(left_pointer.pointee, right_pointer.pointee);
        },
        .slice => |left_slice| {
            const right_slice = right.slice;
            return left_slice.const_ == right_slice.const_ and
                sameType(left_slice.elem, right_slice.elem);
        },
        .array => |left_array| {
            const right_array = right.array;
            return std.meta.eql(left_array.len, right_array.len) and
                sameType(left_array.elem, right_array.elem);
        },
        .tuple => |left_tuple| typeSliceEqual(left_tuple, right.tuple),
        .fn_ptr => |left_fn| {
            const right_fn = right.fn_ptr;
            return typeSliceEqual(left_fn.params, right_fn.params) and
                sameType(left_fn.ret, right_fn.ret);
        },
        .generic_inst => |left_generic| {
            const right_generic = right.generic_inst;
            return left_generic.decl == right_generic.decl and
                typeSliceEqual(left_generic.args.params, right_generic.args.params);
        },
        .option => |left_option| sameType(left_option.*, right.option.*),
        .result => |left_result| {
            const right_result = right.result;
            return left_result.is_error_unionable == right_result.is_error_unionable and
                sameType(left_result.ok, right_result.ok) and
                sameType(left_result.err, right_result.err);
        },
        .boxed => |left_boxed| sameType(left_boxed.*, right.boxed.*),
        .@"opaque" => |left_opaque| {
            const right_opaque = right.@"opaque";
            if (!sameBoundSlice(left_opaque.bounds, right_opaque.bounds)) return false;
            const left_concrete = left_opaque.concrete orelse return right_opaque.concrete == null;
            const right_concrete = right_opaque.concrete orelse return false;
            return sameType(left_concrete.*, right_concrete.*);
        },
        .dyn_trait => |left_bounds| sameBoundSlice(left_bounds, right.dyn_trait),
        .unsupported => false,
    };
}

fn isScalarCastType(ty: Type) bool {
    return switch (ty) {
        .prim => |primitive| switch (primitive) {
            .i8, .i16, .i32, .i64, .i128, .u8, .u16, .u32, .u64, .u128, .isize, .usize, .f32, .f64, .char => true,
            .bool, .unit, .never => false,
        },
        else => false,
    };
}
fn isIntegerPrimitive(primitive: types_mod.Prim) bool {
    return switch (primitive) {
        .i8, .i16, .i32, .i64, .i128, .u8, .u16, .u32, .u64, .u128, .isize, .usize => true,
        .f32, .f64, .bool, .char, .unit, .never => false,
    };
}

fn isThinRawPointer(raw_ptr: *const types_mod.RawPtr) bool {
    return switch (raw_ptr.pointee) {
        .slice => false,
        else => true,
    };
}

fn rawPointeesCastCompatible(
    source_ptr: *const types_mod.RawPtr,
    target_ptr: *const types_mod.RawPtr,
) bool {
    const source_is_fat = (source_ptr.pointee == .slice);
    const target_is_fat = (target_ptr.pointee == .slice);
    if (target_is_fat and !source_is_fat) return false;
    return true;
}

fn referenceToRawPointerCompatible(source_ref: *const types_mod.Ref, target_raw: *const types_mod.RawPtr) bool {
    if (target_raw.mut and !source_ref.mut) return false;
    if (sameType(source_ref.pointee, target_raw.pointee)) return true;
    switch (source_ref.pointee) {
        .array => |arr| {
            if (sameType(arr.elem, target_raw.pointee)) return true;
            if (target_raw.pointee == .slice and sameType(arr.elem, target_raw.pointee.slice.elem)) {
                return true;
            }
        },
        else => {},
    }
    return false;
}

fn referenceArrayToSliceCompatible(
    source_ref: *const types_mod.Ref,
    target_slice: *const types_mod.Slice,
) bool {
    if (!target_slice.const_ and !source_ref.mut) return false;
    const source_array = switch (source_ref.pointee) {
        .array => |array| array,
        else => return false,
    };
    return sameType(source_array.elem, target_slice.elem);
}

fn unsignedPrimitiveWidth(primitive: types_mod.Prim) ?u16 {
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

fn isValidPrimitiveFrom(source: Type, target: Type) bool {
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

fn isValidCastType(kind: exprs.ConversionKind, source: Type, target: Type) bool {
    return switch (kind) {
        .as_ => switch (target) {
            .prim => |target_prim| blk: {
                if (isScalarCastType(target)) {
                    if (isScalarCastType(source) or (source == .prim and source.prim == .bool)) break :blk true;
                    if (source == .raw_ptr and isThinRawPointer(source.raw_ptr) and isIntegerPrimitive(target_prim)) {
                        break :blk true;
                    }
                }
                break :blk false;
            },
            .raw_ptr => |target_pointer| switch (source) {
                .raw_ptr => |source_pointer| rawPointeesCastCompatible(source_pointer, target_pointer),
                .reference => |source_reference| referenceToRawPointerCompatible(source_reference, target_pointer),
                .prim => |source_prim| isIntegerPrimitive(source_prim) and isThinRawPointer(target_pointer),
                else => false,
            },
            .slice => |target_slice| switch (source) {
                .reference => |source_ref| referenceArrayToSliceCompatible(source_ref, target_slice),
                else => false,
            },
            else => false,
        },
        .primitive_from => isValidPrimitiveFrom(source, target),
    };
}

/// Record the reason the frontend gave for an unsupported expression, then
/// return the catchable bare error. The reason stays out of the error NAME so
/// every existing `error.UnsupportedExpression` match keeps working; a caller
/// that wants the detail reads it back with `takeUnsupportedReason`.
fn rejectUnsupportedMarker(reason: []const u8) ValidationError {
    pending_unsupported_reason = reason;
    return error.UnsupportedExpression;
}

fn validateAssertionMarker(b: *const Bodies, reason: []const u8) ValidationError!void {
    const prefix = "assertion:";
    if (!std.mem.startsWith(u8, reason, prefix)) return rejectUnsupportedMarker(reason);

    const suffix = reason[prefix.len..];
    if (suffix.len == 0) return rejectUnsupportedMarker(reason);
    for (suffix) |character| {
        if (character < '0' or character > '9') return rejectUnsupportedMarker(reason);
    }

    const condition_id = std.fmt.parseInt(exprs.NodeId, suffix, 10) catch
        return rejectUnsupportedMarker(reason);
    try validateExprRef(b, condition_id);
}

fn validateExpr(ir: *const RustIr, b: *const Bodies, expr: exprs.Expr, index: usize) ValidationError!void {
    if (@as(usize, expr.id) != index) return error.InvalidNodeId;
    if (expr.ty) |type_id| try validateTypeRef(b, type_id);

    switch (expr.kind) {
        .literal => {},
        .array => |array| for (array.elements) |id| try validateExprRef(b, id),
        .vec_lit => |vector| for (vector.elements) |id| try validateExprRef(b, id),
        .range => |range| {
            try validateExprRef(b, range.start);
            if (range.end) |end| {
                try validateExprRef(b, end);
            } else if (range.inclusive) {
                return error.UnsupportedExpression;
            }
        },
        .path => |path| {
            try validateEntityRef(ir, path.def);
            if (path.generic_args.len > 0) {
                const generic_count = genericCountForEntity(ir, path.def) orelse
                    return error.IncompleteGenericMetadata;
                if (generic_count == 0 or path.generic_args.len != generic_count) {
                    return error.IncompleteGenericMetadata;
                }
            }
        },
        .block => |block| try validateBlock(ir, b, block, &.{}),
        .unit => {},
        .panic_ => {
            const type_id = expr.ty orelse return error.UnsupportedExpression;
            switch (b.types[type_id]) {
                .prim => |primitive| if (primitive != .never) return error.UnsupportedExpression,
                else => return error.UnsupportedExpression,
            }
        },
        .if_else => |if_expr| {
            try validateExprRef(b, if_expr.cond);
            try validateBlock(ir, b, if_expr.then_, &.{});
            try validateElse(ir, b, if_expr.@"else", &.{});
        },
        .if_let => |if_let| {
            try validatePatRef(b, if_let.pattern);
            try validateExprRef(b, if_let.scrutinee);
            try validateBlock(ir, b, if_let.then_, &.{});
            try validateElse(ir, b, if_let.@"else", &.{});
        },
        .match => |match_expr| {
            try validateExprRef(b, match_expr.scrutinee);
            for (match_expr.arms) |arm| {
                for (arm.patterns) |pattern| try validatePatRef(b, pattern);
                if (arm.guard) |guard| try validateExprRef(b, guard);
                try validateExprRef(b, arm.body);
            }
        },
        .loop_ => |loop_expr| try validateBlock(ir, b, loop_expr.body, &.{}),
        .while_ => |while_expr| {
            try validateExprRef(b, while_expr.cond);
            if (while_expr.capture) |capture| try validatePatRef(b, capture);
            try validateBlock(ir, b, while_expr.body, &.{});
        },
        .for_ => |for_expr| {
            try validatePatRef(b, for_expr.pattern);
            try validateExprRef(b, for_expr.iterable);
            try validateBlock(ir, b, for_expr.body, &.{});
            try validateIterKind(ir, b, for_expr.iterable, for_expr.iter_kind);
        },
        .break_ => |break_expr| if (break_expr.value) |value| try validateExprRef(b, value),
        .continue_ => {},
        .call => |call| {
            switch (call.call_kind) {
                .free => |id| try validateEntityRef(ir, id),
                .associated => |id| try validateEntityRef(ir, id),
                .constructor => |id| try validateEntityRef(ir, id),
            }
            for (call.args) |id| try validateExprRef(b, id);
        },
        .core_call => |call| try validateCoreCallShape(b, call),
        .core_function => {},
        .method_call => |method| {
            try validateExprRef(b, method.receiver);
            try validateEntityRef(ir, method.method);
            if (method.generic_args.len > 0 and
                !isUndeclaredMethodReference(ir, method.method))
            {
                // A `.method_ref` callee is a call-site reference with no body,
                // which is how a standard-library method reaches lowering: the
                // backend selects the implementation from the receiver type and
                // the method name. A callee this crate does not declare has no
                // arity to violate and no metadata is owed — the frontend is not
                // dropping anything — so the gate is skipped for exactly that
                // shape and nothing else. A declared callee, whether a `fn_` or
                // a `.method_ref` whose parent declares it, is still checked.
                const generic_count = genericCountForEntity(ir, method.method) orelse
                    return error.IncompleteGenericMetadata;
                if (generic_count == 0 or method.generic_args.len != generic_count) {
                    return error.IncompleteGenericMetadata;
                }
                for (method.generic_args) |argument| {
                    try validateType(ir, b, argument, &.{});
                }
            }
            for (method.args) |id| try validateExprRef(b, id);
        },
        .struct_lit => |literal| {
            try validateStructLiteralDefinition(ir, literal.def);
            for (literal.fields) |field| try validateFieldInit(b, field);
            if (literal.base) |base| try validateExprRef(b, base);
        },
        .enum_variant => |variant| {
            try validateEnumLiteralDefinition(ir, variant.def);
            for (variant.tuple_fields) |id| try validateExprRef(b, id);
            for (variant.named_fields) |field| try validateFieldInit(b, field);
        },
        .external_variant => {},
        .format_write => |format_write| {
            try validateExprRef(b, format_write.writer);
            for (format_write.args) |id| try validateExprRef(b, id);
        },
        .field => |field| {
            try validateExprRef(b, field.base);
            try validateEntityRef(ir, field.resolved);
        },
        .index => |index_expr| {
            try validateExprRef(b, index_expr.base);
            try validateExprRef(b, index_expr.index);
        },
        .cast => |cast| {
            try validateExprRef(b, cast.operand);
            try validateTypeRef(b, cast.target);
            if (expr.ty == null or expr.ty.? != cast.target) return error.UnsupportedExpression;

            const target = if (cast.target < ir.types.len)
                ir.types[cast.target]
            else
                b.types[cast.target];
            if (!isValidCastType(cast.kind, cast.source_type, target)) return error.UnsupportedExpression;

            if (b.exprs[cast.operand].ty) |source_id| {
                try validateTypeRef(b, source_id);
                const operand_type = b.types[source_id];
                if (!sameType(cast.source_type, operand_type)) return error.UnsupportedExpression;
            } else switch (target) {
                .raw_ptr => return error.UnsupportedExpression,
                else => {},
            }
        },
        .binary => |binary| {
            try validateExprRef(b, binary.lhs);
            try validateExprRef(b, binary.rhs);
        },
        .unary => |unary| try validateExprRef(b, unary.operand),
        .assign => |assign| {
            try validateExprRef(b, assign.target);
            try validateExprRef(b, assign.value);
        },
        .try_ => |try_expr| try validateExprRef(b, try_expr.inner),
        .return_ => |return_expr| if (return_expr.value) |value| try validateExprRef(b, value),
        .closure => |closure| try validateClosure(ir, b, closure),
        .iterator_chain => |chain| try validateIteratorChain(ir, b, chain),
        .unsupported => |unsupported| try validateAssertionMarker(b, unsupported.reason),
    }
}

fn validateBlock(ir: *const RustIr, b: *const Bodies, block: exprs.BlockExpr, generic_names: GenericNames) ValidationError!void {
    _ = generic_names;
    for (block.statements) |statement| try validateStmtRef(b, statement);
    if (block.tail) |tail| try validateExprRef(b, tail);
    _ = ir;
}

fn validateElse(ir: *const RustIr, b: *const Bodies, branch: exprs.ElseBranch, generic_names: GenericNames) ValidationError!void {
    switch (branch) {
        .none => {},
        .block => |block| try validateBlock(ir, b, block, generic_names),
        .chain => |chain| try validateExprRef(b, chain),
    }
}

fn validateFieldInit(b: *const Bodies, field: exprs.FieldInit) ValidationError!void {
    if (field.field.len == 0) return error.IncompleteGenericMetadata;
    try validateExprRef(b, field.value);
}

fn validateClosure(ir: *const RustIr, b: *const Bodies, closure: exprs.ClosureExpr) ValidationError!void {
    for (closure.captures) |capture| try validateTypeRef(b, capture.ty);
    for (closure.params) |param| try validatePatRef(b, param);
    if (closure.return_ty) |return_ty| try validateTypeRef(b, return_ty);
    try validateBlock(ir, b, closure.body, &.{});
}

fn validateIterKind(
    ir: *const RustIr,
    b: *const Bodies,
    iterable: exprs.NodeId,
    iter_kind: exprs.IterKind,
) ValidationError!void {
    switch (iter_kind) {
        .range => {
            const range = switch (b.exprs[iterable].kind) {
                .range => |value| value,
                else => return error.UnsupportedExpression,
            };
            if (range.end == null) return error.UnsupportedExpression;
        },
        .slice, .enumerate => {},
        .multi => |ids| for (ids) |id| try validateExprRef(b, id),
        .adapter => |adapter| try validateIteratorChain(ir, b, adapter),
    }
}

fn validateIteratorChain(ir: *const RustIr, b: *const Bodies, chain: exprs.IteratorChainExpr) ValidationError!void {
    try validateExprRef(b, chain.source);
    for (chain.adapters) |adapter| {
        switch (adapter) {
            .map => |map| try validateClosure(ir, b, map.closure),
            .filter => |filter| try validateClosure(ir, b, filter.closure),
            .flat_map => |closure| try validateClosure(ir, b, closure),
            .enumerate, .range_rev => {},
            .zip => |zip| try validateExprRef(b, zip.other),
            .other => return error.UnsupportedExpression,
        }
    }
}

fn validatePattern(ir: *const RustIr, b: *const Bodies, pattern: exprs.Pattern, index: usize) ValidationError!void {
    if (@as(usize, pattern.id) != index) return error.InvalidNodeId;
    if (pattern.ty) |type_id| try validateTypeRef(b, type_id);

    switch (pattern.kind) {
        .wildcard => {},
        .binding => |binding| if (binding.name.len == 0) return error.IncompleteGenericMetadata,
        .literal => {},
        .path => |path| {
            try validateEntityRef(ir, path.def);
        },
        .external_variant => {},
        .tuple => |tuple| for (tuple.elements) |id| try validatePatRef(b, id),
        .slice => |slice| {
            for (slice.elements) |id| try validatePatRef(b, id);
            if (slice.rest) |rest| try validatePatRef(b, rest);
        },
        .struct_pat => |struct_pat| {
            try validateEntityRef(ir, struct_pat.def);
            for (struct_pat.fields) |field| {
                if (field.field.len == 0) return error.IncompleteGenericMetadata;
                if (field.pat) |pat| try validatePatRef(b, pat);
            }
        },
        .reference => |reference| try validatePatRef(b, reference.inner),
        .@"or" => |or_pattern| for (or_pattern.alternatives) |id| try validatePatRef(b, id),
        .range => |range| {
            if (range.lo) |lo| try validateExprRef(b, lo);
            if (range.hi) |hi| try validateExprRef(b, hi);
        },
        .unsupported => return error.UnsupportedPattern,
    }
}

fn validateStatement(ir: *const RustIr, b: *const Bodies, statement: exprs.Statement, index: usize) ValidationError!void {
    if (@as(usize, statement.id) != index) return error.InvalidNodeId;
    if (statement.ty) |type_id| try validateTypeRef(b, type_id);

    switch (statement.kind) {
        .let => |let_stmt| {
            try validatePatRef(b, let_stmt.pattern);
            if (let_stmt.init) |init| try validateExprRef(b, init);
            if (let_stmt.ty) |type_id| try validateTypeRef(b, type_id);
        },
        .let_else => |let_else| {
            try validatePatRef(b, let_else.pattern);
            try validateExprRef(b, let_else.init);
            try validateBlock(ir, b, let_else.else_block, &.{});
        },
        .expr => |id| try validateExprRef(b, id),
        .item => |id| try validateEntityRef(ir, id),
    }
}

test {
    std.testing.refAllDecls(@This());
}

const test_span: spine.Span = .{
    .start_line = 1,
    .start_col = 1,
    .end_line = 1,
    .end_col = 1,
};

fn validReducedIr(allocator: std.mem.Allocator) !RustIr {
    var graph = graph_mod.CrateGraph.init(allocator);

    const root_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = "",
        .span = test_span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const kinds = [_]spine.EntityKind{ .fn_, .struct_, .enum_, .const_, .static_, .type_alias };
    const names = [_][]const u8{ "run", "EmptyStruct", "EmptyEnum", "VALUE", "STATE", "Alias" };
    for (kinds, names) |kind, name| {
        _ = try graph.symbol_table.add(.{
            .id = 0,
            .kind = kind,
            .name = name,
            .span = test_span,
            .visibility = .public,
            .parent = root_id,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
        });
    }

    const module_items = try allocator.dupe(spine.EntityId, &.{ 1, 2, 3, 4, 5, 6 });
    _ = try graph.addModule(.{
        .id = root_id,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = test_span,
        .items = module_items,
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "reduced",
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    const expr_table = try allocator.dupe(exprs.Expr, &.{
        .{
            .id = 0,
            .span = test_span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{},
                .tail = null,
                .labelled = null,
            } },
        },
        .{
            .id = 1,
            .span = test_span,
            .ty = null,
            .kind = .{ .unit = {} },
        },
        .{
            .id = 2,
            .span = test_span,
            .ty = null,
            .kind = .{ .unit = {} },
        },
    });

    const body_table = try allocator.alloc(bodies_mod.BodyKind, 7);
    body_table[0] = .{ .none = {} };
    body_table[1] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 0,
    } };
    body_table[2] = .{ .struct_ = .{
        .layout = .named,
        .fields = &.{},
    } };
    body_table[3] = .{ .enum_ = .{
        .kind = .c_like,
        .variants = &.{},
    } };
    body_table[4] = .{ .const_ = .{
        .ty = .{ .prim = .unit },
        .init = 2,
    } };
    body_table[5] = .{ .const_ = .{
        .ty = .{ .prim = .unit },
        .init = 2,
    } };
    body_table[6] = .{ .type_alias = .{
        .target = .{ .prim = .unit },
    } };

    return .{
        .crate_name = "reduced",
        .graph = graph,
        .types = &.{},
        .bodies = .{
            .exprs = expr_table,
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = body_table,
        },
    };
}
fn appendCoreCallForValidation(ir: *RustIr, call: exprs.CoreCall) !void {
    const allocator = ir.graph.allocator;
    const old_exprs = ir.bodies.exprs;
    const core_call_id: exprs.NodeId = @intCast(old_exprs.len);
    const new_exprs = try allocator.alloc(exprs.Expr, old_exprs.len + 1);
    @memcpy(new_exprs[0..old_exprs.len], old_exprs);
    new_exprs[@as(usize, core_call_id)] = .{
        .id = core_call_id,
        .span = test_span,
        .ty = null,
        .kind = .{ .core_call = call },
    };
    var root = new_exprs[0];
    var root_block = switch (root.kind) {
        .block => |block| block,
        else => return error.InvalidFunctionBody,
    };
    root_block.tail = core_call_id;
    root.kind = .{ .block = root_block };
    new_exprs[0] = root;
    ir.bodies.exprs = new_exprs;
}

/// Attach a method call to the root block's tail, mirroring
/// `appendCoreCallForValidation` for the call forms that carry a callee.
fn appendMethodCallForValidation(ir: *RustIr, call: exprs.MethodCall) !void {
    const allocator = ir.graph.allocator;
    const old_exprs = ir.bodies.exprs;
    const call_id: exprs.NodeId = @intCast(old_exprs.len);
    const receiver_id: exprs.NodeId = @intCast(old_exprs.len + 1);
    const new_exprs = try allocator.alloc(exprs.Expr, old_exprs.len + 2);
    @memcpy(new_exprs[0..old_exprs.len], old_exprs);
    new_exprs[call_id] = .{
        .id = call_id,
        .span = test_span,
        .ty = null,
        .kind = .{ .method_call = call },
    };
    new_exprs[receiver_id] = .{ .id = receiver_id, .span = test_span, .ty = null, .kind = .unit };
    new_exprs[call_id].kind.method_call.receiver = receiver_id;
    var root = new_exprs[0];
    var root_block = switch (root.kind) {
        .block => |block| block,
        else => return error.InvalidFunctionBody,
    };
    root_block.tail = call_id;
    root.kind = .{ .block = root_block };
    new_exprs[0] = root;
    ir.bodies.exprs = new_exprs;
}

/// Declare entity 1 (`run`) as a one-parameter generic function so a method
/// call naming it has a generic count to check a turbofish against.
fn makeMethodEntityGeneric(ir: *RustIr) !void {
    var function_body = ir.bodies.bodies[1].fn_;
    function_body.generic_params = try ir.graph.allocator.dupe([]const u8, &.{"T"});
    @constCast(ir.bodies.bodies)[1] = .{ .fn_ = function_body };
}

/// `count` distinct generic-parameter names (`T0`, `T1`, ...). Built at runtime
/// because the arity under test is a value, not a comptime constant.
fn dupRepeatedParamNames(allocator: std.mem.Allocator, count: usize) ![]const []const u8 {
    const names = try allocator.alloc([]const u8, count);
    for (names, 0..) |*name, index| {
        name.* = try std.fmt.allocPrint(allocator, "T{d}", .{index});
    }
    return names;
}

/// A crate whose `method_call` names a `.method_ref` — the shape every method
/// call has before `resolveMethods` rewrites it to a concrete `fn_`. A
/// `.method_ref` carries no body of its own, so its generic count has to come
/// from the trait that declares the method.
///
/// `method_param_count` is the declared parameter count of the trait's method.
fn methodRefIr(
    allocator: std.mem.Allocator,
    method_param_count: usize,
) !RustIr {
    var ir = try validReducedIr(allocator);
    const entities = ir.graph.symbol_table.entities.items;

    // Entity 7 = trait `Reader` declaring a generic `read`, 8 = the
    // `.method_ref` that names it, and 9 = a plain `fn_` with the same name so
    // the "walk to the fn child whose name matches" path has a target.
    const trait_id: spine.EntityId = @intCast(entities.len);
    const method_ref_id: spine.EntityId = @intCast(trait_id + 1);
    const method_fn_id: spine.EntityId = @intCast(trait_id + 2);

    _ = try ir.graph.symbol_table.add(.{
        .id = 0,
        .kind = .trait_,
        .name = try allocator.dupe(u8, "Reader"),
        .span = test_span,
        .visibility = .public,
        .parent = 0,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try ir.graph.symbol_table.add(.{
        .id = 0,
        .kind = .method_ref,
        .name = try allocator.dupe(u8, "read"),
        .span = test_span,
        .visibility = .public,
        .parent = trait_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try ir.graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try allocator.dupe(u8, "read"),
        .span = test_span,
        .visibility = .public,
        .parent = trait_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // The body table is indexed by EntityId, so extend it to cover the three
    // new entities: trait, method_ref (no body), and the method's `fn_`.
    const old_bodies = ir.bodies.bodies;
    const body_table = try allocator.alloc(bodies_mod.BodyKind, old_bodies.len + 3);
    @memcpy(body_table[0..old_bodies.len], old_bodies);

    var trait_methods = try allocator.alloc(bodies_mod.TraitMethodSig, 1);
    trait_methods[0] = .{
        .name = "read",
        .ret = .{ .prim = .unit },
        .generic_params = try dupRepeatedParamNames(allocator, method_param_count),
    };
    body_table[trait_id] = .{ .trait_ = .{
        .name = "Reader",
        .methods = trait_methods,
    } };
    // A `.method_ref` has no body by construction; that is the whole point of
    // the fix.
    body_table[method_ref_id] = .none;
    body_table[method_fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .generic_params = try dupRepeatedParamNames(allocator, method_param_count),
        .body = 0,
    } };
    ir.bodies.bodies = body_table;

    // Only the trait is a module item; the method's `fn_` is a child of the
    // trait, and the `.method_ref` points at the trait, which is what the
    // count walk follows. `validateGraph` rejects a module list containing an
    // entity whose parent is not the module, so the two lists differ.
    ir.graph.symbol_table.entities.items[@as(usize, trait_id)].parent = 0;
    ir.graph.symbol_table.entities.items[@as(usize, method_fn_id)].parent = trait_id;
    const module_items = try allocator.dupe(
        spine.EntityId,
        &.{ 1, 2, 3, 4, 5, 6, trait_id },
    );
    const module = ir.graph.moduleById(0) orelse return error.InvalidModuleId;
    @constCast(module).items = module_items;

    try appendMethodCallForValidation(&ir, .{
        .receiver = 0,
        .receiver_mode = .shared,
        .method = method_ref_id,
        .generic_args = &.{.{ .prim = .u32 }},
        .args = &.{},
    });
    return ir;
}

test "a method_ref turbofish is arity checked against the declared method" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // One declared parameter, one turbofish argument: the `.method_ref` has no
    // body, so this only validates if the count is resolved through the trait.
    const matching = try methodRefIr(allocator, 1);
    try validateForTranslation(&matching);

    // Two declared parameters against one argument still rejects. This is the
    // case that proves the rule RUNS for a `.method_ref` rather than being
    // bypassed by returning null.
    const mismatched = try methodRefIr(allocator, 2);
    try std.testing.expectError(error.IncompleteGenericMetadata, validateForTranslation(&mismatched));
}

test "a method_ref callee this crate does not declare owes no arity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The `fn_`-parented `.method_ref` is the shape `pushMethodRef` produces for
    // an ordinary `recv.method(..)`, and the shape `collect::<Vec<_>>()` has in
    // hex. Its parent is the ENCLOSING function, which owns no method of that
    // name, so this crate declares no callee and no arity is owed. The gate is
    // skipped for exactly this shape — no panic, no unbounded recursion, and no
    // misleading "missing metadata" error for something that was never owed.
    var ir = try validReducedIr(allocator);
    const entities = ir.graph.symbol_table.entities.items;
    const method_ref_id: spine.EntityId = @intCast(entities.len);

    _ = try ir.graph.symbol_table.add(.{
        .id = 0,
        .kind = .method_ref,
        .name = try allocator.dupe(u8, "unowned"),
        .span = test_span,
        .visibility = .public,
        // Parent 1 is the `run` fn_ from validReducedIr: a legal method_ref
        // parent that declares no method named `unowned`.
        .parent = 1,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const old_bodies = ir.bodies.bodies;
    const body_table = try allocator.alloc(bodies_mod.BodyKind, old_bodies.len + 1);
    @memcpy(body_table[0..old_bodies.len], old_bodies);
    body_table[method_ref_id] = .none;
    ir.bodies.bodies = body_table;

    try appendMethodCallForValidation(&ir, .{
        .receiver = 0,
        .receiver_mode = .shared,
        .method = method_ref_id,
        .generic_args = &.{.{ .prim = .u32 }},
        .args = &.{},
    });
    try validateForTranslation(&ir);
}

test "a declared method_ref callee is still arity checked after the skip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The skip is narrow: a `.method_ref` whose parent DOES declare the method
    // is excluded from it, so a wrong-length turbofish on a declared method
    // still rejects. Two declared parameters against one argument.
    const mismatched = try methodRefIr(allocator, 2);
    try std.testing.expectError(
        error.IncompleteGenericMetadata,
        validateForTranslation(&mismatched),
    );
}

test "a method_ref with a missing parent preserves the previous null count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // An out-of-range entity id never reaches the walk at all, so the count is
    // null before any dereference and the IR is refused, not crashed on.
    var ir = try validReducedIr(allocator);
    try appendMethodCallForValidation(&ir, .{
        .receiver = 0,
        .receiver_mode = .shared,
        .method = @intCast(ir.graph.symbol_table.entities.items.len + 10),
        .generic_args = &.{.{ .prim = .u32 }},
        .args = &.{},
    });
    try std.testing.expectError(error.InvalidEntityReference, validateForTranslation(&ir));
}

test "method call turbofish arity is checked only when present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // No turbofish: an unannotated generic method call stays legal, because
    // Rust infers the argument at that call site.
    var bare = try validReducedIr(allocator);
    try makeMethodEntityGeneric(&bare);
    try appendMethodCallForValidation(&bare, .{
        .receiver = 0,
        .receiver_mode = .value,
        .method = 1,
        .generic_args = &.{},
        .args = &.{},
    });
    try validateForTranslation(&bare);

    // A turbofish naming exactly the declared parameter count is accepted.
    var matched = try validReducedIr(allocator);
    try makeMethodEntityGeneric(&matched);
    try appendMethodCallForValidation(&matched, .{
        .receiver = 0,
        .receiver_mode = .value,
        .method = 1,
        .generic_args = &.{.{ .prim = .u32 }},
        .args = &.{},
    });
    try validateForTranslation(&matched);

    // Too many arguments, and too few, both reject with the same error the
    // path expression already uses for a mis-sized turbofish.
    var too_many = try validReducedIr(allocator);
    try makeMethodEntityGeneric(&too_many);
    try appendMethodCallForValidation(&too_many, .{
        .receiver = 0,
        .receiver_mode = .value,
        .method = 1,
        .generic_args = &.{ .{ .prim = .u32 }, .{ .prim = .u8 } },
        .args = &.{},
    });
    try std.testing.expectError(error.IncompleteGenericMetadata, validateForTranslation(&too_many));

    var too_few = try validReducedIr(allocator);
    try makeMethodEntityGeneric(&too_few);
    try appendMethodCallForValidation(&too_few, .{
        .receiver = 0,
        .receiver_mode = .value,
        .method = 1,
        .generic_args = &.{},
        .args = &.{},
    });
    try validateForTranslation(&too_few);

    // A turbofish on a method whose entity declares no generics at all is
    // incomplete metadata, not a silently ignored argument.
    var non_generic = try validReducedIr(allocator);
    try appendMethodCallForValidation(&non_generic, .{
        .receiver = 0,
        .receiver_mode = .value,
        .method = 1,
        .generic_args = &.{.{ .prim = .u32 }},
        .args = &.{},
    });
    try std.testing.expectError(error.IncompleteGenericMetadata, validateForTranslation(&non_generic));
}

test "method call turbofish argument types are validated in context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A type parameter the method's own generic context does not declare is
    // unresolvable, exactly as it is for a path expression's arguments.
    var ir = try validReducedIr(allocator);
    try makeMethodEntityGeneric(&ir);
    try appendMethodCallForValidation(&ir, .{
        .receiver = 0,
        .receiver_mode = .value,
        .method = 1,
        .generic_args = &.{.{ .path = .{
            .segments = &.{.{ .name = "Undeclared", .id = null }},
        } }},
        .args = &.{},
    });
    try std.testing.expectError(error.UnresolvedTypePath, validateForTranslation(&ir));
}

test "validation accepts a core call generic in its declaring function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var ir = try validReducedIr(arena.allocator());
    var function_body = ir.bodies.bodies[1].fn_;
    function_body.generic_params = &.{"T"};
    @constCast(ir.bodies.bodies)[1] = .{ .fn_ = function_body };
    try appendCoreCallForValidation(&ir, .{
        .function = .mem_size_of,
        .generic_args = &.{.{ .path = .{
            .segments = &.{.{ .name = "T", .id = null }},
        } }},
    });

    try validateForTranslation(&ir);
}
test "validation accepts owner-bound canonical body types in context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var ir = try validReducedIr(arena.allocator());
    var expressions = try arena.allocator().dupe(exprs.Expr, ir.bodies.exprs);
    expressions[1].ty = 0;
    expressions[0].kind.block.tail = 1;
    ir.bodies.exprs = expressions;
    ir.bodies.types = &.{.{
        .path = .{ .segments = &.{.{ .name = "T", .id = null }} },
    }};
    var function_body = ir.bodies.bodies[1].fn_;
    function_body.generic_params = &.{"T"};
    @constCast(ir.bodies.bodies)[1] = .{ .fn_ = function_body };

    try validateForTranslation(&ir);
}

test "validation rejects owner-bound canonical body types outside context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var ir = try validReducedIr(arena.allocator());
    var expressions = try arena.allocator().dupe(exprs.Expr, ir.bodies.exprs);
    expressions[1].ty = 0;
    expressions[0].kind.block.tail = 1;
    ir.bodies.exprs = expressions;
    ir.bodies.types = &.{.{
        .path = .{ .segments = &.{.{ .name = "T", .id = null }} },
    }};

    try std.testing.expectError(error.UnresolvedTypePath, validateForTranslation(&ir));
}

test "validation rejects an invalid core call arity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var ir = try validReducedIr(arena.allocator());
    try appendCoreCallForValidation(&ir, .{
        .function = .mem_size_of,
        .generic_args = &.{},
    });

    try std.testing.expectError(error.InvalidCoreCallArity, validateForTranslation(&ir));
}

test "validation enforces String core call arity" {
    const functions = [_]exprs.CoreFunction{
        .string_from_utf8,
        .string_from_utf8_lossy,
        .string_from_utf8_unchecked,
    };
    for (functions) |function| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ir = try validReducedIr(arena.allocator());
        try appendCoreCallForValidation(&ir, .{
            .function = function,
            .generic_args = &.{.{ .prim = .u8 }},
            .args = &.{1},
        });
        try std.testing.expectError(error.InvalidCoreCallArity, validateForTranslation(&ir));
    }
}

test "validation rejects an invalid core call value reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var ir = try validReducedIr(arena.allocator());
    try appendCoreCallForValidation(&ir, .{
        .function = .mem_size_of_val,
        .generic_args = &.{.{ .prim = .u8 }},
        .args = &.{99},
    });

    try std.testing.expectError(error.InvalidExprRef, validateForTranslation(&ir));
}

const CastValidationFixture = struct {
    ir: RustIr,
    cast_id: exprs.NodeId,
};

fn makeCastValidationFixture(
    allocator: std.mem.Allocator,
    source_primitive: types_mod.Prim,
    target_primitive: types_mod.Prim,
    indexed_source: bool,
    conversion_kind: exprs.ConversionKind,
) !CastValidationFixture {
    var ir = try validReducedIr(allocator);
    const source_type: Type = .{ .prim = source_primitive };
    const target_type: Type = .{ .prim = target_primitive };
    const type_count: usize = if (indexed_source) 3 else 2;
    const types_store = try allocator.alloc(Type, type_count);
    types_store[0] = target_type;
    types_store[1] = source_type;
    if (indexed_source) {
        const array_type = try allocator.create(types_mod.Array);
        array_type.* = .{
            .len = .{ .literal = 1 },
            .elem = source_type,
        };
        types_store[2] = .{ .array = array_type };
    }

    const expression_count: usize = if (indexed_source) 7 else 4;
    const expressions = try allocator.alloc(exprs.Expr, expression_count);
    @memcpy(expressions[0..ir.bodies.exprs.len], ir.bodies.exprs);
    var cast_id: exprs.NodeId = 3;
    if (indexed_source) {
        expressions[2] = .{
            .id = 2,
            .span = test_span,
            .ty = 1,
            .kind = .{ .literal = .{ .int = .{
                .text = "7",
                .value = 7,
                .base = .dec,
                .ty_suffix = null,
            } } },
        };
        expressions[3] = .{
            .id = 3,
            .span = test_span,
            .ty = 2,
            .kind = .{ .array = .{
                .elements = &.{2},
                .repeat = null,
            } },
        };
        expressions[4] = .{
            .id = 4,
            .span = test_span,
            .ty = 0,
            .kind = .{ .literal = .{ .int = .{
                .text = "0",
                .value = 0,
                .base = .dec,
                .ty_suffix = null,
            } } },
        };
        expressions[5] = .{
            .id = 5,
            .span = test_span,
            .ty = 1,
            .kind = .{ .index = .{ .base = 3, .index = 4 } },
        };
        cast_id = 6;
    } else {
        expressions[2] = .{
            .id = 2,
            .span = test_span,
            .ty = 1,
            .kind = .{ .literal = .{ .int = .{
                .text = "7",
                .value = 7,
                .base = .dec,
                .ty_suffix = null,
            } } },
        };
    }
    expressions[cast_id] = .{
        .id = cast_id,
        .span = test_span,
        .ty = 0,
        .kind = .{ .cast = .{
            .kind = conversion_kind,
            .operand = if (indexed_source) 5 else 2,
            .source_type = source_type,
            .target = 0,
        } },
    };

    const statements = try allocator.alloc(exprs.Statement, 1);
    statements[0] = .{
        .id = 0,
        .span = test_span,
        .ty = null,
        .kind = .{ .expr = cast_id },
    };
    expressions[0].kind.block.statements = &.{0};
    ir.bodies.exprs = expressions;
    ir.bodies.stmts = statements;
    ir.bodies.types = types_store;
    return .{
        .ir = ir,
        .cast_id = cast_id,
    };
}

fn expectAcceptedCastValidation(
    allocator: std.mem.Allocator,
    source_primitive: types_mod.Prim,
    target_primitive: types_mod.Prim,
    indexed_source: bool,
    conversion_kind: exprs.ConversionKind,
) !void {
    var fixture = try makeCastValidationFixture(
        allocator,
        source_primitive,
        target_primitive,
        indexed_source,
        conversion_kind,
    );
    try validateForTranslation(&fixture.ir);
    try std.testing.expectEqual(
        conversion_kind,
        fixture.ir.bodies.exprs[fixture.cast_id].kind.cast.kind,
    );
}

test "validation accepts unsigned identity primitive_from" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectAcceptedCastValidation(arena.allocator(), .u64, .u64, false, .primitive_from);
}

test "validation accepts unsigned widening primitive_from" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectAcceptedCastValidation(arena.allocator(), .u64, .u128, false, .primitive_from);
}

test "validation accepts index-derived u8 primitive_from" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectAcceptedCastValidation(arena.allocator(), .u8, .u64, true, .primitive_from);
}

test "validation rejects unsigned narrowing primitive_from" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try makeCastValidationFixture(
        arena.allocator(),
        .u64,
        .u8,
        false,
        .primitive_from,
    );
    try std.testing.expectError(error.UnsupportedExpression, validateForTranslation(&fixture.ir));
}

test "validation accepts explicit u128 as u64" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectAcceptedCastValidation(arena.allocator(), .u128, .u64, false, .as_);
}

fn wrongBody(entity_id: usize) bodies_mod.BodyKind {
    return if (entity_id == 1)
        .{ .struct_ = .{} }
    else
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = 0,
        } };
}

fn addNestedTestModule(
    allocator: std.mem.Allocator,
    ir: *RustIr,
    include_test_function: bool,
) !void {
    const root_id = ir.graph.crates.items[0].root;
    const module_id = try ir.graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = "tests",
        .span = test_span,
        .visibility = .private,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const function_id = try ir.graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "nested_test",
        .span = test_span,
        .visibility = .private,
        .parent = module_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const root_items_old = ir.graph.modules.items[0].items;
    const root_items = try allocator.alloc(spine.EntityId, root_items_old.len + 1);
    @memcpy(root_items[0..root_items_old.len], root_items_old);
    root_items[root_items_old.len] = module_id;
    ir.graph.modules.items[0].items = root_items;

    const nested_items: []const spine.EntityId = if (include_test_function)
        try allocator.dupe(spine.EntityId, &.{function_id})
    else
        &.{};
    _ = try ir.graph.addModule(.{
        .id = module_id,
        .kind = .@"inline",
        .name = "tests",
        .parent = root_id,
        .source_path = null,
        .is_crate = false,
        .is_extern = false,
        .span = test_span,
        .items = nested_items,
        .attributes = &.{},
    });

    const bodies_old = ir.bodies.bodies;
    const body_count: usize = @intCast(function_id + 1);
    const body_table = try allocator.alloc(bodies_mod.BodyKind, body_count);
    @memcpy(body_table[0..bodies_old.len], bodies_old);
    body_table[module_id] = .{ .none = {} };
    body_table[function_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 0,
    } };
    ir.bodies.bodies = body_table;
}

test "validation accepts a generic path in its declaring function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var ir = try validReducedIr(arena.allocator());
    var function_body = ir.bodies.bodies[1].fn_;
    function_body.generic_params = &.{"T"};
    function_body.ret = .{ .path = .{
        .segments = &.{
            .{ .name = "T", .id = null },
            .{ .name = "Output", .id = null },
        },
    } };
    @constCast(ir.bodies.bodies)[1] = .{ .fn_ = function_body };

    try validateForTranslation(&ir);
}

test "validation rejects a generic path outside its declaring function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var ir = try validReducedIr(arena.allocator());
    var function_body = ir.bodies.bodies[1].fn_;
    function_body.generic_params = &.{"T"};
    @constCast(ir.bodies.bodies)[1] = .{ .fn_ = function_body };

    var alias_body = ir.bodies.bodies[6].type_alias;
    alias_body.target = .{ .path = .{
        .segments = &.{.{ .name = "T", .id = null }},
    } };
    @constCast(ir.bodies.bodies)[6] = .{ .type_alias = alias_body };

    try std.testing.expectError(error.UnresolvedTypePath, validateForTranslation(&ir));
}

test "validation accepts a type alias naming its own generic parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var ir = try validReducedIr(arena.allocator());
    var alias_body = ir.bodies.bodies[6].type_alias;
    alias_body.generic_params = &.{ "K", "V" };
    alias_body.target = .{ .external_nominal = .{
        .path = &.{ "std", "collections", "HashMap" },
        .args = &.{
            .{ .path = .{ .segments = &.{.{ .name = "K", .id = null }} } },
            .{ .path = .{ .segments = &.{.{ .name = "V", .id = null }} } },
        },
    } };
    @constCast(ir.bodies.bodies)[6] = .{ .type_alias = alias_body };

    try validateForTranslation(&ir);
}

test "validation rejects a type alias naming an undeclared parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var ir = try validReducedIr(arena.allocator());
    var alias_body = ir.bodies.bodies[6].type_alias;
    // The alias declares `K` but its target names `V`, which is out of scope.
    alias_body.generic_params = &.{"K"};
    alias_body.target = .{ .path = .{ .segments = &.{.{ .name = "V", .id = null }} } };
    @constCast(ir.bodies.bodies)[6] = .{ .type_alias = alias_body };

    try std.testing.expectError(error.UnresolvedTypePath, validateForTranslation(&ir));
}

test "validation rejects a type alias with empty or duplicate generic names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var empty = try validReducedIr(arena.allocator());
    var empty_body = empty.bodies.bodies[6].type_alias;
    empty_body.generic_params = &.{""};
    @constCast(empty.bodies.bodies)[6] = .{ .type_alias = empty_body };
    try std.testing.expectError(
        error.IncompleteGenericMetadata,
        validateForTranslation(&empty),
    );

    var duplicate = try validReducedIr(arena.allocator());
    var duplicate_body = duplicate.bodies.bodies[6].type_alias;
    duplicate_body.generic_params = &.{ "K", "K" };
    @constCast(duplicate.bodies.bodies)[6] = .{ .type_alias = duplicate_body };
    try std.testing.expectError(
        error.IncompleteGenericMetadata,
        validateForTranslation(&duplicate),
    );
}

test "validation accepts alloc external nominal and rejects unknown root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var alloc_external = try validReducedIr(allocator);
    alloc_external.types = &.{.{
        .external_nominal = .{
            .path = &.{ "alloc", "vec", "Vec" },
            .args = &.{.{ .prim = .u8 }},
        },
    }};
    try validateForTranslation(&alloc_external);

    var unknown_external = try validReducedIr(allocator);
    unknown_external.types = &.{.{
        .external_nominal = .{
            .path = &.{ "unknown", "vec", "Vec" },
            .args = &.{.{ .prim = .u8 }},
        },
    }};
    try std.testing.expectError(
        error.UnsupportedExternalNominalType,
        validateForTranslation(&unknown_external),
    );
}

test "validation accepts nested inline test module ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var ir = try validReducedIr(arena.allocator());
    try addNestedTestModule(arena.allocator(), &ir, true);

    try validateForTranslation(&ir);
}

test "validation rejects an orphan entity in a nested module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var ir = try validReducedIr(arena.allocator());
    try addNestedTestModule(arena.allocator(), &ir, false);

    try std.testing.expectError(error.MissingModuleItem, validateForTranslation(&ir));
}

test "validation rejects a missing crate and root module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var no_crate = try validReducedIr(allocator);
    no_crate.graph.crates.items.len = 0;
    try std.testing.expectError(error.NoCrate, validateForTranslation(&no_crate));

    var no_root = try validReducedIr(allocator);
    no_root.graph.crates.items[0].root = 99;
    try std.testing.expectError(error.MissingRootModule, validateForTranslation(&no_root));
}

test "validation rejects missing and unknown module items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var orphan = try validReducedIr(allocator);
    orphan.graph.modules.items[0].items = orphan.graph.modules.items[0].items[1..];
    try std.testing.expectError(error.MissingModuleItem, validateForTranslation(&orphan));

    var unknown = try validReducedIr(allocator);
    @constCast(unknown.graph.modules.items[0].items)[0] = 99;
    try std.testing.expectError(error.UnknownModuleItem, validateForTranslation(&unknown));
}

test "validation rejects absent and mismatched entity bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var no_body_table = try validReducedIr(allocator);
    no_body_table.bodies.bodies = &.{};
    try std.testing.expectError(error.InvalidBodyTable, validateForTranslation(&no_body_table));

    var absent = try validReducedIr(allocator);
    absent.bodies.bodies = absent.bodies.bodies[0..1];
    try std.testing.expectError(error.MissingBodyMetadata, validateForTranslation(&absent));

    for (1..7) |entity_id| {
        var mismatch = try validReducedIr(allocator);
        @constCast(mismatch.bodies.bodies)[entity_id] = wrongBody(entity_id);
        try std.testing.expectError(error.BodyKindMismatch, validateForTranslation(&mismatch));
    }
}

test "validation rejects invalid body node and table references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var body_ref = try validReducedIr(allocator);
    var function_body = body_ref.bodies.bodies[1].fn_;
    function_body.body = 99;
    @constCast(body_ref.bodies.bodies)[1] = .{ .fn_ = function_body };
    try std.testing.expectError(error.InvalidExprRef, validateForTranslation(&body_ref));

    var node_id = try validReducedIr(allocator);
    @constCast(node_id.bodies.exprs)[0].id = 99;
    try std.testing.expectError(error.InvalidNodeId, validateForTranslation(&node_id));

    var expr_ref = try validReducedIr(allocator);
    @constCast(expr_ref.bodies.exprs)[1].kind = .{ .return_ = .{ .value = 99 } };
    try std.testing.expectError(error.InvalidExprRef, validateForTranslation(&expr_ref));

    var stmt_ref = try validReducedIr(allocator);
    @constCast(stmt_ref.bodies.exprs)[0].kind.block.statements = &.{99};
    try std.testing.expectError(error.InvalidStatementRef, validateForTranslation(&stmt_ref));

    var pat_ref = try validReducedIr(allocator);
    pat_ref.bodies.stmts = try allocator.dupe(exprs.Statement, &.{.{
        .id = 0,
        .span = test_span,
        .ty = null,
        .kind = .{ .let = .{
            .pattern = 99,
            .init = null,
            .ty = null,
        } },
    }});
    @constCast(pat_ref.bodies.exprs)[0].kind.block.statements = &.{0};
    try std.testing.expectError(error.InvalidPatternRef, validateForTranslation(&pat_ref));

    var type_ref = try validReducedIr(allocator);
    @constCast(type_ref.bodies.exprs)[0].ty = 0;
    try std.testing.expectError(error.InvalidTypeRef, validateForTranslation(&type_ref));
    var unresolved_type = try validReducedIr(allocator);
    unresolved_type.bodies.types = &.{.{
        .path = .{ .segments = &.{.{ .name = "Missing", .id = null }} },
    }};
    try std.testing.expectError(error.UnresolvedTypePath, validateForTranslation(&unresolved_type));

    var wrong_struct_def = try validReducedIr(allocator);
    @constCast(wrong_struct_def.bodies.exprs)[1].kind = .{ .struct_lit = .{
        .def = 1,
        .fields = &.{},
        .base = null,
    } };
    try std.testing.expectError(error.InvalidLiteralDefinition, validateForTranslation(&wrong_struct_def));

    var wrong_enum_def = try validReducedIr(allocator);
    @constCast(wrong_enum_def.bodies.exprs)[1].kind = .{ .enum_variant = .{
        .def = 2,
        .variant = "Wrong",
        .tuple_fields = &.{},
        .named_fields = &.{},
    } };
    try std.testing.expectError(error.InvalidLiteralDefinition, validateForTranslation(&wrong_enum_def));
}

test "validation rejects a raw-pointer cast with an untyped operand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var ir = try validReducedIr(arena.allocator());
    const source_type: Type = .{
        .raw_ptr = &.{ .mut = false, .pointee = .{ .prim = .u8 } },
    };
    const target_type: Type = .{
        .raw_ptr = &.{ .mut = true, .pointee = .{ .prim = .u8 } },
    };
    ir.bodies.types = &.{target_type};
    @constCast(ir.bodies.exprs)[1] = .{
        .id = 1,
        .span = test_span,
        .ty = 0,
        .kind = .{ .cast = .{
            .operand = 0,
            .source_type = source_type,
            .target = 0,
        } },
    };

    try std.testing.expectError(error.UnsupportedExpression, validateForTranslation(&ir));
}

test "validation accepts a well-formed assertion marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir = try validReducedIr(allocator);
    const condition_id: exprs.NodeId = @intCast(ir.bodies.exprs.len);
    const assertion_id = condition_id + 1;
    const expressions = try allocator.alloc(exprs.Expr, ir.bodies.exprs.len + 2);
    @memcpy(expressions[0..ir.bodies.exprs.len], ir.bodies.exprs);
    expressions[condition_id] = .{
        .id = condition_id,
        .span = test_span,
        .ty = null,
        .kind = .{ .literal = .{ .boolean = true } },
    };
    expressions[assertion_id] = .{
        .id = assertion_id,
        .span = test_span,
        .ty = null,
        .kind = .{ .unsupported = .{
            .reason = try std.fmt.allocPrint(allocator, "assertion:{d}", .{condition_id}),
            .suggested_version = .v3,
        } },
    };
    expressions[0].kind.block.tail = assertion_id;
    ir.bodies.exprs = expressions;

    try validateForTranslation(&ir);
}

test "validation rejects malformed assertion markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for ([_][]const u8{ "assertion:", "assertion:none", "assertion:not-a-node" }) |reason| {
        var ir = try validReducedIr(allocator);
        @constCast(ir.bodies.exprs)[1].kind = .{ .unsupported = .{
            .reason = reason,
            .suggested_version = .v3,
        } };
        try std.testing.expectError(error.UnsupportedExpression, validateForTranslation(&ir));
    }
}

test "validation rejects an out-of-range assertion marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var ir = try validReducedIr(arena.allocator());
    @constCast(ir.bodies.exprs)[1].kind = .{ .unsupported = .{
        .reason = "assertion:99",
        .suggested_version = .v3,
    } };
    try std.testing.expectError(error.InvalidExprRef, validateForTranslation(&ir));
}

test "validation rejects an ordinary unsupported expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var ir = try validReducedIr(arena.allocator());
    @constCast(ir.bodies.exprs)[1].kind = .{ .unsupported = .{
        .reason = "not lowered",
        .suggested_version = .v1,
    } };
    try std.testing.expectError(error.UnsupportedExpression, validateForTranslation(&ir));
}

test "validation carries the unsupported expression reason out to the caller" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A stale reason from an earlier run must not be attributed to this one.
    _ = takeUnsupportedReason();

    var ir = try validReducedIr(arena.allocator());
    @constCast(ir.bodies.exprs)[1].kind = .{ .unsupported = .{
        .reason = "cast target type",
        .suggested_version = .v1,
    } };

    // The error NAME is unchanged, so existing callers keep matching on it.
    try std.testing.expectError(error.UnsupportedExpression, validateForTranslation(&ir));
    try std.testing.expectEqualStrings("cast target type", takeUnsupportedReason().?);
    // Reading it is a one-shot: a second read must not replay it.
    try std.testing.expect(takeUnsupportedReason() == null);

    // A clean run clears whatever was pending.
    var clean = try validReducedIr(arena.allocator());
    @constCast(clean.bodies.exprs)[1].kind = .{ .unsupported = .{
        .reason = "local const initializer is not a pure scalar",
        .suggested_version = .v1,
    } };
    try std.testing.expectError(error.UnsupportedExpression, validateForTranslation(&clean));
    const reason = takeUnsupportedReason().?;
    try std.testing.expectEqualStrings("local const initializer is not a pure scalar", reason);

    var accepted = try validReducedIr(arena.allocator());
    try validateForTranslation(&accepted);
    try std.testing.expect(takeUnsupportedReason() == null);
}

test "a malformed assertion marker still reports its marker text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var ir = try validReducedIr(arena.allocator());
    @constCast(ir.bodies.exprs)[1].kind = .{ .unsupported = .{
        .reason = "assertion:not-a-node",
        .suggested_version = .v3,
    } };
    try std.testing.expectError(error.UnsupportedExpression, validateForTranslation(&ir));
    try std.testing.expectEqualStrings("assertion:not-a-node", takeUnsupportedReason().?);
}

test "validation rejects explicit unsupported pattern and type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var unsupported_pattern = try validReducedIr(allocator);
    unsupported_pattern.bodies.pats = try allocator.dupe(exprs.Pattern, &.{.{
        .id = 0,
        .span = test_span,
        .ty = null,
        .kind = .{ .unsupported = .{
            .reason = "not lowered",
            .suggested_version = .v1,
        } },
    }});
    try std.testing.expectError(error.UnsupportedPattern, validateForTranslation(&unsupported_pattern));

    var unsupported_type = try validReducedIr(allocator);
    unsupported_type.bodies.types = try allocator.dupe(types_mod.Type, &.{.{
        .unsupported = .{
            .reason = .dyn_trait,
            .message = "not lowered",
            .span = test_span,
        },
    }});
    try std.testing.expectError(error.UnsupportedType, validateForTranslation(&unsupported_type));
}

test "validation rejects incomplete generic metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir = try validReducedIr(allocator);
    var struct_body = ir.bodies.bodies[2].struct_;
    struct_body.generic_params = &.{""};
    @constCast(ir.bodies.bodies)[2] = .{ .struct_ = struct_body };
    try std.testing.expectError(error.IncompleteGenericMetadata, validateForTranslation(&ir));
}

test "validation rejects duplicate entity IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ir = try validReducedIr(allocator);
    @constCast(ir.graph.symbol_table.entities.items)[1].id = 0;
    try std.testing.expectError(error.InvalidEntityId, validateForTranslation(&ir));
}

test "validation accepts intentional empty Rust containers with complete bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const ir = try validReducedIr(arena.allocator());
    try validateForTranslation(&ir);
}
test "validation accepts a bounded flat-map collection chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir = try validReducedIr(allocator);
    const expressions = try allocator.alloc(exprs.Expr, 3);
    @memcpy(expressions[0..ir.bodies.exprs.len], ir.bodies.exprs);

    const closure: exprs.ClosureExpr = .{
        .captures = &.{},
        .params = &.{},
        .return_ty = null,
        .body = .{ .statements = &.{}, .tail = 0, .labelled = null },
        .trait = .@"fn",
    };
    expressions[1] = .{
        .id = 1,
        .span = test_span,
        .ty = null,
        .kind = .{ .iterator_chain = .{
            .source = 2,
            .adapters = &.{.{ .flat_map = closure }},
            .terminal = .collect_vec,
        } },
    };
    expressions[2] = .{
        .id = 2,
        .span = test_span,
        .ty = null,
        .kind = .{ .range = .{ .start = 0, .end = 0, .inclusive = false } },
    };
    ir.bodies.exprs = expressions;

    try validateForTranslation(&ir);
}

test "validation rejects malformed range and flat-map references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var invalid_range = try validReducedIr(allocator);
    @constCast(invalid_range.bodies.exprs)[1].kind = .{ .range = .{
        .start = 0,
        .end = 99,
    } };
    try std.testing.expectError(error.InvalidExprRef, validateForTranslation(&invalid_range));

    var invalid_closure = try validReducedIr(allocator);
    const closure: exprs.ClosureExpr = .{
        .captures = &.{},
        .params = &.{},
        .return_ty = null,
        .body = .{ .statements = &.{}, .tail = 99, .labelled = null },
        .trait = .@"fn",
    };
    @constCast(invalid_closure.bodies.exprs)[1].kind = .{ .iterator_chain = .{
        .source = 0,
        .adapters = &.{.{ .flat_map = closure }},
        .terminal = .collect_vec,
    } };
    try std.testing.expectError(error.InvalidExprRef, validateForTranslation(&invalid_closure));
}
