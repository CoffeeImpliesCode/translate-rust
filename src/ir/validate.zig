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
    InvalidEntityReference,
    InvalidLiteralDefinition,
    InvalidFunctionBody,
    InvalidTypePath,
    UnresolvedTypePath,
    UnsupportedExternalNominalType,
    UnsupportedExpression,
    UnsupportedPattern,
    UnsupportedType,
    IncompleteGenericMetadata,
};

/// Validate all invariants required before target-specific lowering.
///
/// This is intentionally strict. A missing record, unresolved reference, or
/// explicit unsupported marker is an error instead of an empty declaration or
/// a skipped item.
pub fn validateForTranslation(ir: *const RustIr) ValidationError!void {
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

fn validateBodies(ir: *const RustIr) ValidationError!void {
    const b = &ir.bodies;
    const entity_count = ir.graph.symbol_table.entities.items.len;
    // Wire v1 carries no body table. Reject it at the translation boundary,
    // even when the crate happens to contain no body-bearing declaration.
    if (b.bodies.len == 0) return error.InvalidBodyTable;
    if (b.bodies.len > entity_count) return error.InvalidBodyTable;

    // Validate both type tables. RustIr.types is the canonical lowering table;
    // Bodies.types is the node-side table used by Expr/Pattern/Statement.ty.
    for (ir.types) |ty| try validateType(ir, b, ty, &.{});
    for (b.types) |ty| try validateType(ir, b, ty, &.{});

    for (ir.graph.symbol_table.entities.items, 0..) |ent, entity_id| {
        const body = if (entity_id < b.bodies.len) b.bodies[entity_id] else null;
        switch (ent.kind) {
            .fn_ => {
                const body_kind = body orelse return error.MissingBodyMetadata;
                const fn_body = switch (body_kind) {
                    .fn_ => |value| value,
                    else => return error.BodyKindMismatch,
                };
                try validateFnBody(ir, b, fn_body);
            },
            .struct_ => {
                const body_kind = body orelse return error.MissingBodyMetadata;
                const struct_body = switch (body_kind) {
                    .struct_ => |value| value,
                    else => return error.BodyKindMismatch,
                };
                try validateStructBody(ir, b, struct_body);
            },
            .union_ => {
                const body_kind = body orelse return error.MissingBodyMetadata;
                const struct_body = switch (body_kind) {
                    .struct_ => |value| value,
                    else => return error.BodyKindMismatch,
                };
                try validateStructBody(ir, b, struct_body);
            },
            .enum_ => {
                const body_kind = body orelse return error.MissingBodyMetadata;
                const enum_body = switch (body_kind) {
                    .enum_ => |value| value,
                    else => return error.BodyKindMismatch,
                };
                try validateEnumBody(ir, b, enum_body);
            },
            .const_, .static_ => {
                const body_kind = body orelse return error.MissingBodyMetadata;
                const const_body = switch (body_kind) {
                    .const_ => |value| value,
                    else => return error.BodyKindMismatch,
                };
                try validateConstBody(ir, b, const_body);
            },
            .type_alias => {
                const body_kind = body orelse return error.MissingBodyMetadata;
                const alias_body = switch (body_kind) {
                    .type_alias => |value| value,
                    else => return error.BodyKindMismatch,
                };
                try validateType(ir, b, alias_body.target, &.{});
            },
            .trait_ => {
                if (body) |body_kind| {
                    switch (body_kind) {
                        .none => {},
                        .trait_ => |trait_body| try validateTraitBody(ir, b, trait_body),
                        else => return error.BodyKindMismatch,
                    }
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

    for (b.exprs, 0..) |expr, index| try validateExpr(ir, b, expr, index);
    for (b.pats, 0..) |pattern, index| try validatePattern(ir, b, pattern, index);
    for (b.stmts, 0..) |statement, index| try validateStatement(ir, b, statement, index);
}

fn validateFnBody(ir: *const RustIr, b: *const Bodies, body: bodies_mod.FnBody) ValidationError!void {
    try validateGenericNames(body.generic_params);
    for (body.params) |param| try validateType(ir, b, param.ty, body.generic_params);
    try validateType(ir, b, body.ret, body.generic_params);
    try validateExprRef(b, body.body);
    if (b.exprs[body.body].kind != .block) return error.InvalidFunctionBody;
}

fn validateStructBody(ir: *const RustIr, b: *const Bodies, body: bodies_mod.StructBody) ValidationError!void {
    try validateGenericNames(body.generic_params);
    for (body.trait_bounds) |bound| {
        if (bound.len == 0) return error.IncompleteGenericMetadata;
    }
    for (body.fields) |field| try validateField(ir, b, field, body.generic_params);
    for (body.methods) |method| {
        if (method.name.len == 0) return error.IncompleteGenericMetadata;
        try validateGenericNames(method.generic_params);
        for (method.params) |param| try validateType(ir, b, param.ty, method.generic_params);
        try validateType(ir, b, method.ret, method.generic_params);
        try validateExprRef(b, method.body);
        if (b.exprs[method.body].kind != .block) return error.InvalidFunctionBody;
    }
}

fn validateEnumBody(ir: *const RustIr, b: *const Bodies, body: bodies_mod.EnumBody) ValidationError!void {
    for (body.variants) |variant| {
        if (variant.name.len == 0) return error.IncompleteGenericMetadata;
        switch (variant.fields) {
            .none => {},
            .tuple => |field_types| for (field_types) |ty| try validateType(ir, b, ty, &.{}),
            .named => |fields| for (fields) |field| try validateField(ir, b, field, &.{}),
        }
    }
}

fn validateTraitBody(ir: *const RustIr, b: *const Bodies, body: bodies_mod.TraitBody) ValidationError!void {
    if (body.name.len == 0) return error.IncompleteGenericMetadata;
    for (body.supertraits) |supertrait| {
        if (supertrait.len == 0) return error.IncompleteGenericMetadata;
    }
    for (body.methods) |method| {
        if (method.name.len == 0) return error.IncompleteGenericMetadata;
        for (method.params) |param| try validateType(ir, b, param.ty, &.{});
        try validateType(ir, b, method.ret, &.{});
    }
}

fn validateConstBody(ir: *const RustIr, b: *const Bodies, body: bodies_mod.ConstBody) ValidationError!void {
    try validateType(ir, b, body.ty, &.{});
    try validateExprRef(b, body.init);
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

fn genericCountForEntity(ir: *const RustIr, id: spine.EntityId) ?usize {
    if (@as(usize, id) >= ir.bodies.bodies.len) return null;
    return switch (ir.bodies.bodies[id]) {
        .fn_ => |body| body.generic_params.len,
        .struct_ => |body| body.generic_params.len,
        else => null,
    };
}

fn genericNameKnown(generic_names: GenericNames, name: []const u8) bool {
    for (generic_names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}
fn isExternalRoot(path: []const []const u8) bool {
    if (path.len == 0) return false;
    return std.mem.eql(u8, path[0], "alloc") or
        std.mem.eql(u8, path[0], "core") or std.mem.eql(u8, path[0], "std");
}

fn validateType(ir: *const RustIr, b: *const Bodies, ty: Type, generic_names: GenericNames) ValidationError!void {
    switch (ty) {
        .path => |path| {
            if (path.segments.len == 0) return error.InvalidTypePath;
            var generic_root = false;
            for (path.segments, 0..) |segment, index| {
                if (segment.name.len == 0) return error.InvalidTypePath;
                if (segment.id) |id| {
                    try validateEntityRef(ir, id);
                } else if (index == 0 and genericNameKnown(generic_names, segment.name)) {
                    generic_root = true;
                } else if (!generic_root) {
                    return error.UnresolvedTypePath;
                }
            }
        },
        .external_nominal => |external| {
            if (external.path.len == 0) return error.InvalidTypePath;
            if (!isExternalRoot(external.path)) return error.UnsupportedExternalNominalType;
            for (external.path) |segment| {
                if (segment.len == 0) return error.InvalidTypePath;
            }
            for (external.args) |arg| {
                try validateType(ir, b, arg, generic_names);
            }
        },
        .prim => {},
        .reference => |reference| try validateType(ir, b, reference.pointee, generic_names),
        .raw_ptr => |raw_ptr| try validateType(ir, b, raw_ptr.pointee, generic_names),
        .slice => |slice| try validateType(ir, b, slice.elem, generic_names),
        .array => |array| {
            try validateType(ir, b, array.elem, generic_names);
            switch (array.len) {
                .literal => {},
                .generic => |index| {
                    if (@as(usize, index) >= generic_names.len) return error.IncompleteGenericMetadata;
                },
            }
        },
        .tuple => |elements| for (elements) |element| try validateType(ir, b, element, generic_names),
        .fn_ptr => |fn_ptr| {
            for (fn_ptr.params) |param| try validateType(ir, b, param, generic_names);
            try validateType(ir, b, fn_ptr.ret, generic_names);
        },
        .generic_inst => |generic| {
            try validateEntityRef(ir, generic.decl);
            const generic_count = genericCountForEntity(ir, generic.decl) orelse
                return error.IncompleteGenericMetadata;
            if (generic_count == 0 or generic.args.params.len != generic_count) {
                return error.IncompleteGenericMetadata;
            }
            for (generic.args.params) |arg| try validateType(ir, b, arg, generic_names);
        },
        .option => |option| try validateType(ir, b, option.*, generic_names),
        .result => |result| {
            try validateType(ir, b, result.ok, generic_names);
            try validateType(ir, b, result.err, generic_names);
        },
        .boxed => |boxed| try validateType(ir, b, boxed.*, generic_names),
        .unsupported => return error.UnsupportedType,
    }
}

fn typeSliceEqual(left: []const Type, right: []const Type) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_type, right_type| {
        if (!sameType(left_type, right_type)) return false;
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
const ScalarPointeeLayout = enum {
    byte_1,
    byte_2,
    byte_4,
    byte_8,
    byte_16,
    pointer,
};

fn scalarPointeeLayout(primitive: types_mod.Prim) ?ScalarPointeeLayout {
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

fn pointerPointeesCompatible(source: Type, target: Type) bool {
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
            .prim => isScalarCastType(source) and isScalarCastType(target),
            .raw_ptr => |target_pointer| switch (source) {
                .raw_ptr => |source_pointer| pointerPointeesCompatible(
                    source_pointer.pointee,
                    target_pointer.pointee,
                ),
                else => false,
            },
            else => false,
        },
        .primitive_from => isValidPrimitiveFrom(source, target),
    };
}

fn validateAssertionMarker(b: *const Bodies, reason: []const u8) ValidationError!void {
    const prefix = "assertion:";
    if (!std.mem.startsWith(u8, reason, prefix)) return error.UnsupportedExpression;

    const suffix = reason[prefix.len..];
    if (suffix.len == 0) return error.UnsupportedExpression;
    for (suffix) |character| {
        if (character < '0' or character > '9') return error.UnsupportedExpression;
    }

    const condition_id = std.fmt.parseInt(exprs.NodeId, suffix, 10) catch
        return error.UnsupportedExpression;
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
            try validateExprRef(b, range.end);
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
            for (path.generic_args) |arg| try validateType(ir, b, arg, &.{});
        },
        .block => |block| try validateBlock(ir, b, block, &.{}),
        .unit => {},
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
            try validateIterKind(ir, b, for_expr.iter_kind);
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
        .method_call => |method| {
            try validateExprRef(b, method.receiver);
            try validateEntityRef(ir, method.method);
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

            try validateType(ir, b, cast.source_type, &.{});
            const target = if (cast.target < ir.types.len)
                ir.types[cast.target]
            else
                b.types[cast.target];
            if (!isValidCastType(cast.kind, cast.source_type, target)) return error.UnsupportedExpression;

            if (b.exprs[cast.operand].ty) |source_id| {
                try validateTypeRef(b, source_id);
                const operand_type = b.types[source_id];
                if (!sameType(cast.source_type, operand_type)) {
                    return error.UnsupportedExpression;
                }
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
    try validateExprRef(b, field.value);
}

fn validateClosure(ir: *const RustIr, b: *const Bodies, closure: exprs.ClosureExpr) ValidationError!void {
    for (closure.captures) |capture| try validateTypeRef(b, capture.ty);
    for (closure.params) |param| try validatePatRef(b, param);
    if (closure.return_ty) |return_ty| try validateTypeRef(b, return_ty);
    try validateBlock(ir, b, closure.body, &.{});
}

fn validateIterKind(ir: *const RustIr, b: *const Bodies, iter_kind: exprs.IterKind) ValidationError!void {
    switch (iter_kind) {
        .range, .slice, .enumerate => {},
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
        .tuple => |tuple| for (tuple.elements) |id| try validatePatRef(b, id),
        .slice => |slice| {
            for (slice.elements) |id| try validatePatRef(b, id);
            if (slice.rest) |rest| try validatePatRef(b, rest);
        },
        .struct_pat => |struct_pat| {
            try validateEntityRef(ir, struct_pat.def);
            for (struct_pat.fields) |field| {
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
        .init = 1,
    } };
    body_table[5] = .{ .const_ = .{
        .ty = .{ .prim = .unit },
        .init = 1,
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
    const expressions = try allocator.alloc(exprs.Expr, ir.bodies.exprs.len + 2);
    @memcpy(expressions[0..ir.bodies.exprs.len], ir.bodies.exprs);
    expressions[2] = .{
        .id = 2,
        .span = test_span,
        .ty = null,
        .kind = .{ .literal = .{ .boolean = true } },
    };
    expressions[3] = .{
        .id = 3,
        .span = test_span,
        .ty = null,
        .kind = .{ .unsupported = .{
            .reason = "assertion:2",
            .suggested_version = .v3,
        } },
    };
    expressions[0].kind.block.tail = 3;
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
