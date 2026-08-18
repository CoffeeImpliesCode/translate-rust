//! translate_rust.model.items — item (declaration) layer of the lossless semantic IR.
//! See notes/design/data-model/items-types.md §1 (items).
//!
//! Every `Item` carries the common header from the spine (EntityId, Span,
//! Visibility, Attribute list) plus an `ItemKind` tagged union. The backend
//! switches on `item.kind` to decide the Zig emission strategy.
//!
//! Dependency graph: items → types → spine.

const spine = @import("spine.zig");
const types = @import("types.zig");

/// Placeholder for P3 (expressions / patterns). `null` means body not yet lowered.
pub const BodyRef = u32;

// §1 — Items ----------------------------------------------------------------

pub const Item = struct {
    id: spine.EntityId,
    span: spine.Span,
    visibility: spine.Visibility,
    attributes: []const spine.Attribute,
    kind: ItemKind,
};

pub const ItemKind = union(enum) {
    struct_: Struct,
    enum_: Enum,
    union_: Union,
    fn_: Fn,
    const_: Const,
    static_: Static,
    type_alias: Alias,
    impl: Impl,
    trait: Trait,
    extern_block: ExternBlock,
    unsupported: spine.Unsupported,
};

// §1.1 — Struct -------------------------------------------------------------

pub const Struct = struct {
    name: []const u8,
    generics: ?types.Generics,
    layout: struct_kind,
    fields: []const Field,
};

pub const Field = struct {
    name: []const u8,
    ty: types.Type,
    visibility: spine.Visibility,
    span: spine.Span,
};

pub const struct_kind = enum { named, tuple, unit };

// §1.2 — Enum ---------------------------------------------------------------

pub const Enum = struct {
    name: []const u8,
    generics: ?types.Generics,
    kind: enum_kind,
    variants: []const Variant,
    repr_int: ?int_repr,
    non_exhaustive: bool,
};

pub const Variant = struct {
    name: []const u8,
    fields: VariantFields,
    discriminant: ?i128,
};

pub const VariantFields = union(enum) {
    none,
    tuple: []const types.Type,
    named: []const Field,
};

pub const enum_kind = enum { c_like, data, mixed };

pub const int_repr = enum { i8, i16, i32, i64, i128, u8, u16, u32, u64, u128, isize, usize };

// §1.3 — Union --------------------------------------------------------------

pub const Union = struct {
    name: []const u8,
    generics: ?types.Generics,
    repr: union_repr,
    fields: []const Field,
};

pub const union_repr = enum { extern_, @"packed", untagged };

// §1.4 — Function -----------------------------------------------------------

pub const Fn = struct {
    name: []const u8,
    generics: ?types.Generics,
    params: []const Param,
    ret: types.Type,
    is_async: bool,
    is_unsafe: bool,
    is_const_fn: bool,
    receiver: ?Receiver,
    body: ?BodyRef,
};

pub const Param = struct {
    name: []const u8,
    ty: types.Type,
    span: spine.Span,
};

pub const Receiver = enum { owned, ref_, mut_ref };

// §1.5 — Const / Static -----------------------------------------------------

pub const Const = struct {
    name: []const u8,
    ty: types.Type,
    init: BodyRef,
};

pub const Static = struct {
    name: []const u8,
    ty: types.Type,
    init: BodyRef,
    mut: bool,
};

// §1.6 — Alias --------------------------------------------------------------

pub const Alias = struct {
    name: []const u8,
    ty: types.Type,
    generics: ?types.Generics,
};

// §1.7 — Impl blocks + associated items -------------------------------------

pub const Impl = union(enum) {
    inherent: Inherent,
    trait: TraitImpl,
};

pub const Inherent = struct {
    self_ty: types.Type,
    generics: ?types.Generics,
    assoc: []const AssocItem,
};

pub const TraitImpl = struct {
    trait_path: types.Path,
    self_ty: types.Type,
    generics: ?types.Generics,
    assoc: []const AssocItem,
};

pub const AssocItem = union(enum) {
    fn_: Fn,
    const_: Const,
    type_: AssocType,
};

pub const AssocType = struct {
    name: []const u8,
    generics: ?types.Generics,
    bounds: []const types.Bound,
    default: ?types.Type,
};

// §1.8 — Extern / FFI -------------------------------------------------------

pub const ExternBlock = struct {
    abi: Abi,
    items: []const Fn,
};

pub const Abi = enum { c, system, rust_intrinsic };

// §1.9 — Trait declarations --------------------------------------------------

pub const Trait = struct {
    name: []const u8,
    generics: ?types.Generics,
    supertraits: []const types.Path,
    methods: []const TraitMethod,
    assoc_types: []const AssocType,
    assoc_consts: []const Const,
};

pub const TraitMethod = struct {
    sig: Fn,
    default_body: ?BodyRef,
};

// =============================================================================
// Tests — instantiate shapes to prove every union arm and struct compiles.
// All values use compile-time static slices; no allocator needed.
// =============================================================================

test "items — every ItemKind variant compiles" {
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };
    const span2: spine.Span = .{ .start_line = 2, .start_col = 1, .end_line = 2, .end_col = 4 };

    // A reusable field and a reusable function signature
    const x_field: Field = .{
        .name = "x",
        .ty = .{ .prim = .i32 },
        .visibility = .public,
        .span = span,
    };

    const add_fn: Fn = .{
        .name = "add",
        .generics = null,
        .params = &.{},
        .ret = .{ .prim = .i32 },
        .is_async = false,
        .is_unsafe = false,
        .is_const_fn = true,
        .receiver = null,
        .body = null,
    };

    const method_fn: Fn = .{
        .name = "distance",
        .generics = null,
        .params = &.{},
        .ret = .{ .prim = .f64 },
        .is_async = false,
        .is_unsafe = false,
        .is_const_fn = false,
        .receiver = .ref_,
        .body = 0,
    };
    // §1.1 — three struct kinds
    const named_struct: Struct = .{
        .name = "Point",
        .generics = null,
        .layout = .named,
        .fields = &.{x_field},
    };
    const tuple_struct: Struct = .{
        .name = "Pair",
        .generics = null,
        .layout = .tuple,
        .fields = &.{x_field},
    };
    const unit_struct: Struct = .{
        .name = "Marker",
        .generics = null,
        .layout = .unit,
        .fields = &.{},
    };
    _ = tuple_struct;
    _ = unit_struct;

    // §1.1 — struct with generics
    const generic_struct: Struct = .{
        .name = "GenericPoint",
        .generics = .{
            .params = &.{
                .{ .type_ = .{ .name = "T", .bounds = &.{} } },
                .{ .const_ = .{ .name = "N", .ty = .{ .prim = .usize } } },
                .{ .lifetime = .{ .name = "'a" } },
            },
            .where_clauses = &.{},
        },
        .layout = .named,
        .fields = &.{},
    };
    _ = generic_struct;

    // §1.2 — C-like enum
    const color_enum: Enum = .{
        .name = "Color",
        .generics = null,
        .kind = .c_like,
        .variants = &.{},
        .repr_int = .u8,
        .non_exhaustive = false,
    };
    _ = color_enum;

    // §1.2 — data enum with tuple + named variants
    const data_enum: Enum = .{
        .name = "Shape",
        .generics = null,
        .kind = .data,
        .variants = &.{
            .{ .name = "Circle", .fields = .{ .tuple = &.{.{ .prim = .f64 }} }, .discriminant = null },
            .{ .name = "Rect", .fields = .{ .named = &.{x_field} }, .discriminant = 2 },
            .{ .name = "Dot", .fields = .none, .discriminant = 3 },
        },
        .repr_int = null,
        .non_exhaustive = true,
    };

    // §1.3 — three union reprs
    const extern_union: Union = .{ .name = "Value", .generics = null, .repr = .extern_, .fields = &.{} };
    const packed_union: Union = .{ .name = "Bits", .generics = null, .repr = .@"packed", .fields = &.{} };
    const untagged_union: Union = .{ .name = "Opaque", .generics = null, .repr = .untagged, .fields = &.{} };
    _ = packed_union;
    _ = untagged_union;

    // §1.4 — free fn + method (already defined above as add_fn / method_fn)

    // §1.5 — const & static
    const pi_const: Const = .{ .name = "PI", .ty = .{ .prim = .f64 }, .init = 0 };
    const counter_static: Static = .{ .name = "counter", .ty = .{ .prim = .u32 }, .init = 0, .mut = true };
    const max_static: Static = .{ .name = "MAX", .ty = .{ .prim = .u64 }, .init = 0, .mut = false };
    _ = max_static;

    // §1.6 — alias
    const id_alias: Alias = .{ .name = "Id", .ty = .{ .prim = .u64 }, .generics = null };

    // §1.7 — inherent impl
    const inherent: Inherent = .{
        .self_ty = .{ .prim = .i32 },
        .generics = null,
        .assoc = &.{ .{ .fn_ = add_fn }, .{ .const_ = pi_const } },
    };

    // §1.7 — trait impl
    const trait_impl: TraitImpl = .{
        .trait_path = .{ .segments = &.{.{ .name = "Display", .id = null }} },
        .self_ty = .{ .prim = .i32 },
        .generics = null,
        .assoc = &.{
            .{ .fn_ = method_fn },
            .{ .const_ = pi_const },
            .{ .type_ = .{ .name = "Error", .generics = null, .bounds = &.{}, .default = null } },
        },
    };

    // §1.8 — extern block
    const extern_block: ExternBlock = .{ .abi = .c, .items = &.{add_fn} };
    const intrinsics_block: ExternBlock = .{ .abi = .rust_intrinsic, .items = &.{} };
    _ = intrinsics_block;

    // §1.9 — trait
    const trait_def: Trait = .{
        .name = "Shape",
        .generics = null,
        .supertraits = &.{.{ .segments = &.{.{ .name = "Clone", .id = null }} }},
        .methods = &.{.{ .sig = method_fn, .default_body = null }},
        .assoc_types = &.{.{ .name = "Item", .generics = null, .bounds = &.{}, .default = null }},
        .assoc_consts = &.{pi_const},
    };

    // Wrap every variant into an Item so all ItemKind arms are exercised
    const struct_item: Item = .{
        .id = 1,
        .span = span,
        .visibility = .public,
        .attributes = &.{},
        .kind = .{ .struct_ = named_struct },
    };
    const enum_item: Item = .{
        .id = 2,
        .span = span,
        .visibility = .public,
        .attributes = &.{},
        .kind = .{ .enum_ = data_enum },
    };
    const union_item: Item = .{
        .id = 3,
        .span = span,
        .visibility = .public,
        .attributes = &.{},
        .kind = .{ .union_ = extern_union },
    };
    const fn_item: Item = .{
        .id = 4,
        .span = span,
        .visibility = .public,
        .attributes = &.{},
        .kind = .{ .fn_ = method_fn },
    };
    const const_item: Item = .{
        .id = 5,
        .span = span,
        .visibility = .public,
        .attributes = &.{},
        .kind = .{ .const_ = pi_const },
    };
    const static_item: Item = .{
        .id = 6,
        .span = span,
        .visibility = .public,
        .attributes = &.{},
        .kind = .{ .static_ = counter_static },
    };
    const alias_item: Item = .{
        .id = 7,
        .span = span,
        .visibility = .public,
        .attributes = &.{},
        .kind = .{ .type_alias = id_alias },
    };
    const impl_inherent_item: Item = .{
        .id = 8,
        .span = span,
        .visibility = .private,
        .attributes = &.{},
        .kind = .{ .impl = .{ .inherent = inherent } },
    };
    const impl_trait_item: Item = .{
        .id = 9,
        .span = span2,
        .visibility = .private,
        .attributes = &.{},
        .kind = .{ .impl = .{ .trait = trait_impl } },
    };
    const trait_item: Item = .{
        .id = 10,
        .span = span,
        .visibility = .public,
        .attributes = &.{},
        .kind = .{ .trait = trait_def },
    };
    const extern_item: Item = .{
        .id = 11,
        .span = span,
        .visibility = .public,
        .attributes = &.{},
        .kind = .{ .extern_block = extern_block },
    };
    const unsupported_item: Item = .{
        .id = 12,
        .span = span,
        .visibility = .private,
        .attributes = &.{},
        .kind = .{
            .unsupported = .{
                .reason = .proc_macro,
                .message = "procedural macros out of scope for v1",
                .span = span,
            },
        },
    };

    // Prevent unused-variable warnings in debug builds
    _ = struct_item;
    _ = enum_item;
    _ = union_item;
    _ = fn_item;
    _ = const_item;
    _ = static_item;
    _ = alias_item;
    _ = impl_inherent_item;
    _ = impl_trait_item;
    _ = trait_item;
    _ = extern_item;
    _ = unsupported_item;
}

test "items — Param, Receiver, Abi exercise all variants" {
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    // Param
    const a_param: Param = .{ .name = "a", .ty = .{ .prim = .i32 }, .span = span };
    const b_param: Param = .{ .name = "b", .ty = .{ .prim = .f64 }, .span = span };
    const multi_param_fn: Fn = .{
        .name = "lerp",
        .generics = null,
        .params = &.{ a_param, b_param },
        .ret = .{ .prim = .f64 },
        .is_async = false,
        .is_unsafe = false,
        .is_const_fn = false,
        .receiver = null,
        .body = null,
    };
    _ = multi_param_fn;

    // All three Receiver variants
    const r_owned: Receiver = .owned;
    const r_ref: Receiver = .ref_;
    const r_mut_ref: Receiver = .mut_ref;
    _ = r_owned;
    _ = r_ref;
    _ = r_mut_ref;

    // All three Abi variants
    const a_c: Abi = .c;
    const a_system: Abi = .system;
    const a_intrinsics: Abi = .rust_intrinsic;
    _ = a_c;
    _ = a_system;
    _ = a_intrinsics;
}

test "items — impl AssocItem exercises all three arms" {
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    const fn_assoc: AssocItem = .{ .fn_ = .{
        .name = "new",
        .generics = null,
        .params = &.{},
        .ret = .{ .prim = .i32 },
        .is_async = false,
        .is_unsafe = false,
        .is_const_fn = false,
        .receiver = null,
        .body = null,
    } };

    const const_assoc: AssocItem = .{ .const_ = .{
        .name = "DEFAULT",
        .ty = .{ .prim = .i32 },
        .init = 0,
    } };

    const type_assoc: AssocItem = .{ .type_ = .{
        .name = "Output",
        .generics = null,
        .bounds = &.{},
        .default = .{ .prim = .i32 },
    } };

    const impl_block: Impl = .{ .inherent = .{
        .self_ty = .{ .prim = .i32 },
        .generics = null,
        .assoc = &.{ fn_assoc, const_assoc, type_assoc },
    } };

    const item: Item = .{
        .id = 1,
        .span = span,
        .visibility = .private,
        .attributes = &.{},
        .kind = .{ .impl = impl_block },
    };
    _ = item;
}

test "types — exercise every Type union variant" {
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    const t_prim: types.Type = .{ .prim = .i32 };
    const t_path: types.Type = .{ .path = .{ .segments = &.{
        .{ .name = "std", .id = null },
        .{ .name = "io", .id = null },
        .{ .name = "Result", .id = 42 },
    } } };
    const t_ref: types.Type = .{ .reference = &.{ .mut = false, .pointee = .{ .prim = .u8 } } };
    const t_mut_ref: types.Type = .{ .reference = &.{ .mut = true, .pointee = .{ .prim = .u8 } } };
    const t_raw_ptr: types.Type = .{ .raw_ptr = &.{ .mut = false, .pointee = .{ .prim = .u8 } } };
    const t_mut_ptr: types.Type = .{ .raw_ptr = &.{ .mut = true, .pointee = .{ .prim = .u8 } } };
    const t_slice: types.Type = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } };
    const t_mut_slice: types.Type = .{ .slice = &.{ .const_ = false, .elem = .{ .prim = .u8 } } };
    const t_array: types.Type = .{ .array = &.{ .elem = .{ .prim = .u8 }, .len = .{ .literal = 32 } } };
    const t_array_generic: types.Type = .{ .array = &.{ .elem = .{ .prim = .u8 }, .len = .{ .generic = 0 } } };
    const t_tuple: types.Type = .{ .tuple = &.{ .{ .prim = .i32 }, .{ .prim = .f64 }, .{ .prim = .bool } } };
    const t_fnptr: types.Type = .{
        .fn_ptr = &.{
            .params = &.{ .{ .prim = .i32 }, .{ .prim = .f64 } },
            .ret = .{ .prim = .i32 },
        },
    };
    const t_geninst: types.Type = .{ .generic_inst = .{ .decl = 7, .args = .{ .params = &.{.{ .prim = .usize }} } } };
    const t_inner: types.Type = .{ .prim = .i32 };
    const t_option: types.Type = .{ .option = &t_inner };
    const t_result_ok: types.Type = .{ .prim = .i32 };
    const t_result_err: types.Type = .{ .prim = .u8 };
    const t_result: types.Type = .{
        .result = &.{ .ok = t_result_ok, .err = t_result_err, .is_error_unionable = true },
    };
    const t_boxed: types.Type = .{ .boxed = &t_inner };
    const t_unsup: types.Type = .{
        .unsupported = .{
            .reason = .std_prelude,
            .message = "HashMap not yet mapped",
            .span = span,
        },
    };

    _ = t_prim;
    _ = t_path;
    _ = t_ref;
    _ = t_mut_ref;
    _ = t_raw_ptr;
    _ = t_mut_ptr;
    _ = t_slice;
    _ = t_mut_slice;
    _ = t_array;
    _ = t_array_generic;
    _ = t_tuple;
    _ = t_fnptr;
    _ = t_geninst;
    _ = t_option;
    _ = t_result;
    _ = t_boxed;
    _ = t_unsup;
}

test "types — Prim covers all 18 primitive variants" {
    const p_i8: types.Prim = .i8;
    const p_i16: types.Prim = .i16;
    const p_i32: types.Prim = .i32;
    const p_i64: types.Prim = .i64;
    const p_i128: types.Prim = .i128;
    const p_u8: types.Prim = .u8;
    const p_u16: types.Prim = .u16;
    const p_u32: types.Prim = .u32;
    const p_u64: types.Prim = .u64;
    const p_u128: types.Prim = .u128;
    const p_isize: types.Prim = .isize;
    const p_usize: types.Prim = .usize;
    const p_f32: types.Prim = .f32;
    const p_f64: types.Prim = .f64;
    const p_bool: types.Prim = .bool;
    const p_char: types.Prim = .char;
    const p_unit: types.Prim = .unit;
    const p_never: types.Prim = .never;
    _ = p_i8;
    _ = p_i16;
    _ = p_i32;
    _ = p_i64;
    _ = p_i128;
    _ = p_u8;
    _ = p_u16;
    _ = p_u32;
    _ = p_u64;
    _ = p_u128;
    _ = p_isize;
    _ = p_usize;
    _ = p_f32;
    _ = p_f64;
    _ = p_bool;
    _ = p_char;
    _ = p_unit;
    _ = p_never;
}
