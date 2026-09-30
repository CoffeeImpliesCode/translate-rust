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
    option_and_then,
    option_as_ref,
    option_take,

    result_is_ok,
    result_is_err,
    result_ok,
    result_unwrap,
    result_unwrap_err,
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
    slice_split_at,
    slice_split_first,
    slice_chunks_exact,
    slice_chunks,
    slice_copy_from_slice,
    chunks_exact_remainder,

    num_wrapping_add,
    num_wrapping_sub,
    num_wrapping_mul,
    num_saturating_add,
    num_saturating_sub,
    num_saturating_mul,
    num_count_ones,
    num_leading_zeros,
    num_trailing_zeros,
    num_rotate_left,
    num_rotate_right,
    num_to_le,
    num_to_be,
    num_swap_bytes,
    num_checked_add,
    num_checked_sub,
    num_checked_mul,
    char_to_digit,
    byte_is_ascii,
    range_contains,

    /// Rust `String::into_bytes`. The runtime hands the backing `Vec(u8)`
    /// over and leaves the string empty.
    string_into_bytes,
    format_write_str,
    /// Rust `ToString::to_string`. Blanket-implemented for `T: Display`;
    /// see `hasGraphFreeDisplay` and `isBoundStandardMethod`.
    to_string,

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
const reason_operator_operand_dispatched_call =
    "operator operand is a dispatched method call whose result type this pass does not name";
const reason_operator_requires_primitives = "operator requires primitive operands";
const reason_opaque_iterator_method =
    "opaque receiver: backend lookupRecognizedStdMethod has no arm for this iterator method";

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

/// The `method_name` a crate-local blanket `impl<T: AsRef<[u8]>> Trait for T`
/// provides, or null when no such impl has it.
///
/// A blanket impl is the one piece of evidence a receiver with no type of its
/// own can carry: the impl names no concrete self type, so it provides its
/// method for every type its bound admits, and Rust checks that bound against
/// the type inference settles on. Resolving the call therefore asserts
/// nothing the bound has not already promised — in particular it never names
/// an element type for an array literal, which is what an unsuffixed
/// `[0x66, 0x6f, ..]` has not got. Two blanket impls providing the same
/// method are ambiguous, and stay refused.
fn lookupBlanketAsRefBytesMethod(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    method_name: []const u8,
) ?spine.EntityId {
    if (method_name.len == 0) return null;
    var candidate: ?spine.EntityId = null;
    for (g.symbol_table.entities.items) |ent| {
        if (ent.kind != .impl_) continue;
        const parts = parseTraitImplName(ent.name) orelse continue;
        if (!isBlanketAsRefBytesImpl(b, ent.id, parts.type_name)) continue;
        for (g.symbol_table.entities.items) |child| {
            if (child.kind != .fn_ or child.parent != ent.id) continue;
            if (!std.mem.eql(u8, child.name, method_name)) continue;
            if (candidate != null) return null;
            candidate = child.id;
        }
    }
    return candidate;
}

/// Whether `impl_id` is a trait impl whose own self type is the type
/// parameter `self_name`, and whose only requirement on that parameter is a
/// byte-sequence `AsRef`. A concrete self type, a differently bounded
/// parameter, and an inherited bound that the impl does not itself declare
/// all fail here.
fn isBlanketAsRefBytesImpl(
    b: *const bodies.Bodies,
    impl_id: spine.EntityId,
    self_name: []const u8,
) bool {
    if (impl_id >= b.bodies.len) return false;
    const implementation = switch (b.bodies[impl_id]) {
        .impl_ => |value| value,
        else => return false,
    };
    const generics = implementation.generics orelse return false;
    for (generics.params) |parameter| {
        const type_param = switch (parameter) {
            .type_ => |value| value,
            else => continue,
        };
        if (!std.mem.eql(u8, type_param.name, self_name)) continue;
        for (type_param.bounds) |bound| {
            if (isByteSequenceAsRef(bound)) return true;
        }
    }
    return false;
}

/// `AsRef` applied to a byte sequence, however the source spelled the trait
/// path. The method this admits comes from the same impl that declared the
/// bound, so a crate that means a different `AsRef` still dispatches to its
/// own impl.
fn isByteSequenceAsRef(bound: types.Bound) bool {
    if (bound.optional) return false;
    if (bound.args.len != 1) return false;
    const segments = bound.path.segments;
    if (segments.len == 0) return false;
    if (!std.mem.eql(u8, segments[segments.len - 1].name, "AsRef")) return false;
    return isByteSequenceType(bound.args[0]);
}

fn isByteSequenceType(t: types.Type) bool {
    return switch (t) {
        .slice => |slice| slice.elem == .prim and slice.elem.prim == .u8,
        .array => |array| array.elem == .prim and array.elem.prim == .u8,
        .reference => |reference| isByteSequenceType(reference.pointee),
        else => false,
    };
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

/// How far a receiver's `&T` / `*T` / `Box<T>` / `impl Trait` chain is
/// followed before the walk gives up. It bounds the one rule every receiver
/// predicate shares, so the bound is part of that rule too.
const receiver_unpeel_depth_max: usize = 128;

/// The type a receiver really is, behind the layers that never change which
/// type is named: a reference, a raw pointer, a box, and an `impl Trait` the
/// frontend recovered a concrete carrier for. The Zig backend peels exactly
/// these before it matches a method, so every predicate here that asks
/// "what does this receiver name?" has to ask it of this walk. A copy of
/// this rule per predicate is how two of them came to disagree about one
/// type.
///
/// `null` means the walk could not finish: an `impl Trait` that recovered no
/// carrier names nothing at all, and no side downstream can peel it.
fn unpeelReceiverType(t: types.Type) ?types.Type {
    var current = t;
    for (0..receiver_unpeel_depth_max) |_| {
        switch (current) {
            .reference => |reference| current = reference.pointee,
            .raw_ptr => |raw_ptr| current = raw_ptr.pointee,
            .boxed => |boxed| current = boxed.*,
            .@"opaque" => |opaque_type| {
                const concrete = opaque_type.concrete orelse return null;
                current = concrete.*;
            },
            else => return current,
        }
    }
    return null;
}

/// Match std prelude methods on known types, automatically unwrapping
/// references/pointers/boxes.
pub fn lookupStdMethod(
    t: types.Type,
    method_name: []const u8,
) ?StdMethod {
    std.debug.assert(method_name.len >= 0);
    if (method_name.len == 0) return null;

    // An opaque that recovered no carrier still reaches the tail of this
    // function: it names nothing that `default` or `clone` would not, and
    // the switch below has no arm for it either way.
    const cur_t = unpeelReceiverType(t) orelse t;

    if (std.mem.eql(u8, method_name, "to_string") and hasGraphFreeDisplay(cur_t)) return .to_string;

    switch (cur_t) {
        .option => {
            if (std.mem.eql(u8, method_name, "is_some")) return .option_is_some;
            if (std.mem.eql(u8, method_name, "is_none")) return .option_is_none;
            if (std.mem.eql(u8, method_name, "unwrap")) return .option_unwrap;
            if (std.mem.eql(u8, method_name, "unwrap_or")) return .option_unwrap_or;
            if (std.mem.eql(u8, method_name, "map")) return .option_map;
            if (std.mem.eql(u8, method_name, "and_then")) return .option_and_then;
            if (std.mem.eql(u8, method_name, "as_ref")) return .option_as_ref;
            if (std.mem.eql(u8, method_name, "take")) return .option_take;
        },
        .result => {
            if (std.mem.eql(u8, method_name, "is_ok")) return .result_is_ok;
            if (std.mem.eql(u8, method_name, "is_err")) return .result_is_err;
            if (std.mem.eql(u8, method_name, "ok")) return .result_ok;
            if (std.mem.eql(u8, method_name, "unwrap")) return .result_unwrap;
            // `unwrap_err` is NOT decided here: whether a `Result` receiver
            // has an error VALUE to hand back depends on how it lowers, not
            // on its type, and that is `lookupResultRepresentationMethod`'s
            // one question.
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
            if (std.mem.eql(u8, method_name, "split_at")) return .slice_split_at;
            if (std.mem.eql(u8, method_name, "chunks_exact")) return .slice_chunks_exact;
            if (std.mem.eql(u8, method_name, "split_first")) return .slice_split_first;
            if (std.mem.eql(u8, method_name, "chunks")) return .slice_chunks;
            if (std.mem.eql(u8, method_name, "copy_from_slice")) return .slice_copy_from_slice;
        },
        .external_nominal => |external| {
            const is_option = external.path.len == 3 and
                (std.mem.eql(u8, external.path[0], "core") or
                    std.mem.eql(u8, external.path[0], "std")) and
                std.mem.eql(u8, external.path[1], "option") and
                std.mem.eql(u8, external.path[2], "Option");
            const is_result = external.path.len == 3 and
                (std.mem.eql(u8, external.path[0], "core") or
                    std.mem.eql(u8, external.path[0], "std")) and
                std.mem.eql(u8, external.path[1], "result") and
                std.mem.eql(u8, external.path[2], "Result");
            if (is_option) {
                if (std.mem.eql(u8, method_name, "is_some")) return .option_is_some;
                if (std.mem.eql(u8, method_name, "is_none")) return .option_is_none;
                if (std.mem.eql(u8, method_name, "unwrap")) return .option_unwrap;
                if (std.mem.eql(u8, method_name, "unwrap_or")) return .option_unwrap_or;
                if (std.mem.eql(u8, method_name, "map")) return .option_map;
                if (std.mem.eql(u8, method_name, "and_then")) return .option_and_then;
                if (std.mem.eql(u8, method_name, "as_ref")) return .option_as_ref;
                if (std.mem.eql(u8, method_name, "take")) return .option_take;
            }
            if (is_result) {
                if (std.mem.eql(u8, method_name, "is_ok")) return .result_is_ok;
                if (std.mem.eql(u8, method_name, "is_err")) return .result_is_err;
                if (std.mem.eql(u8, method_name, "unwrap")) return .result_unwrap;
                if (std.mem.eql(u8, method_name, "unwrap_err")) return .result_unwrap_err;
                if (std.mem.eql(u8, method_name, "unwrap_or")) return .result_unwrap_or;
                if (std.mem.eql(u8, method_name, "map")) return .result_map;
                if (std.mem.eql(u8, method_name, "map_err")) return .result_map_err;
                if (std.mem.eql(u8, method_name, "as_ref")) return .result_as_ref;
            }
            // `String` is the one Rust owner whose runtime type is a distinct
            // Zig type (`r2z.alloc.String`) rather than a plain list, and
            // `into_bytes` is the one method that only it has: it hands the
            // backing `Vec(u8)` over and leaves the string empty. A `&str`,
            // a `Vec<u8>`, and a slice borrow each reach a different runtime
            // type, so all of them stay refused.
            if (external.args.len == 0 and external.path.len == 3 and
                (std.mem.eql(u8, external.path[0], "alloc") or
                    std.mem.eql(u8, external.path[0], "std")) and
                std.mem.eql(u8, external.path[1], "string") and
                std.mem.eql(u8, external.path[2], "String") and
                std.mem.eql(u8, method_name, "into_bytes"))
            {
                return .string_into_bytes;
            }
            if (external.path.len == 3 and
                (std.mem.eql(u8, external.path[0], "core") or std.mem.eql(u8, external.path[0], "std")))
            {
                if (std.mem.eql(u8, external.path[1], "fmt") and
                    std.mem.eql(u8, external.path[2], "Formatter") and
                    std.mem.eql(u8, method_name, "write_str")) return .format_write_str;
                if (std.mem.eql(u8, external.path[1], "ops") and
                    (std.mem.eql(u8, external.path[2], "Range") or std.mem.eql(u8, external.path[2], "RangeInclusive")) and
                    std.mem.eql(u8, method_name, "contains")) return .range_contains;
            }
            if (external.path.len == 3 and
                std.mem.eql(u8, external.path[0], "core") and
                std.mem.eql(u8, external.path[1], "slice") and
                std.mem.eql(u8, external.path[2], "ChunksExact") and
                external.args.len == 1 and
                std.mem.eql(u8, method_name, "remainder"))
            {
                return .chunks_exact_remainder;
            }
        },
        .prim => |p| {
            if (p == .u8 and std.mem.eql(u8, method_name, "is_ascii")) return .byte_is_ascii;
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
                    if (std.mem.eql(u8, method_name, "rotate_left")) return .num_rotate_left;
                    if (std.mem.eql(u8, method_name, "rotate_right")) return .num_rotate_right;
                    if (std.mem.eql(u8, method_name, "to_le")) return .num_to_le;
                    if (std.mem.eql(u8, method_name, "to_be")) return .num_to_be;
                    if (std.mem.eql(u8, method_name, "swap_bytes")) return .num_swap_bytes;
                    if (std.mem.eql(u8, method_name, "checked_add")) return .num_checked_add;
                    if (std.mem.eql(u8, method_name, "checked_sub")) return .num_checked_sub;
                    if (std.mem.eql(u8, method_name, "checked_mul")) return .num_checked_mul;
                },
                .char => {
                    if (std.mem.eql(u8, method_name, "to_digit")) return .char_to_digit;
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

/// The `Result` method that the receiver's TYPE does not decide.
///
/// `Result<T, E>` is one Rust type and two Zig representations. When `E` is a
/// fieldless enum it lowers to the error union `E!T`, which holds the error
/// IN the union; otherwise it lowers to the runtime's tagged
/// `r2z.Result(T, E)`, which holds it in a value. `unwrap_err` returns that
/// value, so it exists for the second form and not for the first, and
/// `is_error_unionable` alone cannot say which form a receiver is: it records
/// that `E` is a FINITE error set, and a crate enum that carries data
/// (`FromHexError::InvalidHexCharacter { c, index }`) is finite and still
/// lowers to a value. The backend asks the same question with the same data
/// before it picks a representation (`resultUsesErrorUnion` in `lower.zig`).
pub fn lookupResultRepresentationMethod(
    b: *const bodies.Bodies,
    receiver: types.Type,
    method_name: []const u8,
) ?StdMethod {
    if (!std.mem.eql(u8, method_name, "unwrap_err")) return null;
    // A receiver that is not a `Result` is never this method's receiver.
    // Admitting one would be admitting a Rust type error the runtime has no
    // way to express, so the refusal has to happen before the representation
    // is even considered.
    const result = switch (unpeelReceiverType(receiver) orelse return null) {
        .result => |value| value.*,
        else => return null,
    };
    if (result.is_error_unionable and errorTypeIsZigErrorSet(b, result.err)) return null;
    return .result_unwrap_err;
}

/// The entity a type names, behind the indirections that never change which
/// type is named. This peels one layer more than the backend's own
/// `nominalEntityForType` — a raw pointer — and only ever in the direction
/// that refuses: a type this walk reaches and that one stops short of is one
/// the backend already treats as not naming an error set.
fn nominalEntityForType(t: types.Type) ?spine.EntityId {
    const current = unpeelReceiverType(t) orelse return null;
    if (current == .generic_inst) return current.generic_inst.decl;
    const path = switch (current) {
        .path => |value| value,
        else => return null,
    };
    var last: ?spine.EntityId = null;
    for (path.segments) |segment| last = segment.id;
    return last;
}

/// Whether `t` is a Zig error set: a Rust enum with at least one variant and
/// no variant that carries anything, which is the only shape that lowers to
/// one. A crate error enum that carries data does not, and a `Result` over it
/// keeps its error in a value.
fn errorTypeIsZigErrorSet(b: *const bodies.Bodies, t: types.Type) bool {
    const id = nominalEntityForType(t) orelse return false;
    if (id >= b.bodies.len) return false;
    const enum_body = switch (b.bodies[id]) {
        .enum_ => |value| value,
        else => return false,
    };
    if (enum_body.variants.len == 0) return false;
    for (enum_body.variants) |variant| {
        if (variant.fields != .none) return false;
    }
    return true;
}

/// What an adapter's own type parameter past the source iterator is.
const AdapterPayload = enum {
    /// The adapter carries only its source (`Enumerate<I>`, `Take<I>`, ...).
    none,
    /// The adapter carries a closure (`Map<I, F>`, `Filter<I, F>`, ...). The
    /// frontend never names a closure's type, and no rule reads this
    /// parameter: it is recorded so the carrier keeps Rust's own arity.
    closure,
    /// The adapter carries a second iterator, recovered from the argument the
    /// call itself supplies (`Zip<L, R>`).
    other_iterator,
};

/// A `core::iter` adapter. Rust fixes both the arguments the method call
/// takes and the parameters the adapter type carries, so a chain built from
/// these entries is typed exactly as the source names it.
const IteratorAdapter = struct {
    method: []const u8,
    /// `core::iter::<carrier>`.
    carrier: []const u8,
    call_args: usize,
    type_args: usize,
    payload: AdapterPayload,
};

const iterator_adapters = [_]IteratorAdapter{
    .{ .method = "enumerate", .carrier = "Enumerate", .call_args = 0, .type_args = 1, .payload = .none },
    .{ .method = "rev", .carrier = "Rev", .call_args = 0, .type_args = 1, .payload = .none },
    .{ .method = "peekable", .carrier = "Peekable", .call_args = 0, .type_args = 1, .payload = .none },
    .{ .method = "fuse", .carrier = "Fuse", .call_args = 0, .type_args = 1, .payload = .none },
    .{ .method = "by_ref", .carrier = "ByRef", .call_args = 0, .type_args = 1, .payload = .none },
    .{ .method = "take", .carrier = "Take", .call_args = 1, .type_args = 1, .payload = .none },
    .{ .method = "skip", .carrier = "Skip", .call_args = 1, .type_args = 1, .payload = .none },
    .{ .method = "step_by", .carrier = "StepBy", .call_args = 1, .type_args = 1, .payload = .none },
    .{ .method = "map", .carrier = "Map", .call_args = 1, .type_args = 2, .payload = .closure },
    .{ .method = "filter", .carrier = "Filter", .call_args = 1, .type_args = 2, .payload = .closure },
    .{ .method = "filter_map", .carrier = "FilterMap", .call_args = 1, .type_args = 2, .payload = .closure },
    .{ .method = "flat_map", .carrier = "FlatMap", .call_args = 1, .type_args = 2, .payload = .closure },
    .{ .method = "inspect", .carrier = "Inspect", .call_args = 1, .type_args = 2, .payload = .closure },
    .{ .method = "take_while", .carrier = "TakeWhile", .call_args = 1, .type_args = 2, .payload = .closure },
    .{ .method = "skip_while", .carrier = "SkipWhile", .call_args = 1, .type_args = 2, .payload = .closure },
    .{ .method = "zip", .carrier = "Zip", .call_args = 1, .type_args = 2, .payload = .other_iterator },
};

fn iteratorAdapter(method_name: []const u8) ?*const IteratorAdapter {
    for (&iterator_adapters) |*adapter| {
        if (std.mem.eql(u8, adapter.method, method_name)) return adapter;
    }
    return null;
}

fn iteratorAdapterCarrier(carrier: []const u8) ?*const IteratorAdapter {
    for (&iterator_adapters) |*adapter| {
        if (std.mem.eql(u8, adapter.carrier, carrier)) return adapter;
    }
    return null;
}

/// The number of type parameters an iterator carrier must carry, or null when
/// `external` names no carrier this frontend models.
/// `isRuntimeIteratorMethod` dispatches on the carrier, and the adapter
/// synthesis below refuses to extend a chain whose source is not one.
fn iteratorCarrierArgCount(external: types.ExternalNominal) ?usize {
    if (external.path.len != 3) return null;
    if (!std.mem.eql(u8, external.path[0], "core") and
        !std.mem.eql(u8, external.path[0], "std"))
    {
        return null;
    }
    // The slice-owned iterators, all `core::slice::*<T>` with one argument.
    // `Chunks` and `ChunksExact` are here because the frontend now synthesises
    // a type for them, so a chain rooted at `.chunks(n)` has a carrier to
    // dispatch on; without them `.enumerate()` off such a chain is refused.
    if (std.mem.eql(u8, external.path[1], "slice") and
        (std.mem.eql(u8, external.path[2], "Iter") or
            std.mem.eql(u8, external.path[2], "IterMut") or
            std.mem.eql(u8, external.path[2], "Chunks") or
            std.mem.eql(u8, external.path[2], "ChunksExact"))) return 1;
    if (std.mem.eql(u8, external.path[1], "iter")) {
        const adapter = iteratorAdapterCarrier(external.path[2]) orelse return null;
        return adapter.type_args;
    }
    if (std.mem.eql(u8, external.path[1], "ops") and
        std.mem.eql(u8, external.path[2], "Range")) return 1;
    return null;
}

fn isIteratorCarrier(t: types.Type) bool {
    const external = switch (t) {
        .external_nominal => |value| value,
        else => return false,
    };
    return iteratorCarrierArgCount(external) != null;
}

/// Whether a receiver type names a type the Zig backend can render in the
/// source. A nominal is named. An `impl Trait` return is an OPAQUE, and the
/// backend peels it to the concrete the frontend recovered beside it before
/// it matches anything — so an opaque WITH a carrier names exactly what the
/// carrier names, and this asks the same question of the same walk as
/// `lookupStdMethod` and `isRuntimeIteratorMethod`. An opaque with NO carrier
/// is named by nothing, and neither is the receiver.
fn hasNamedReceiverType(t: types.Type) bool {
    const current = unpeelReceiverType(t) orelse return false;
    return current == .external_nominal or current == .generic_inst;
}

/// Whether the receiver is an `impl Trait` the walk cannot peel, because the
/// frontend recovered no concrete carrier for it. Nothing downstream reads
/// such a receiver, so a call on it is a call against a type no side can
/// name.
fn isUnpeelableOpaqueReceiver(t: types.Type) bool {
    return unpeelReceiverType(t) == null;
}

/// Return whether `t` is one of the public iterator carriers whose methods
/// remain ordinary runtime-backed calls. These methods are intentionally not
/// `StdMethod` entries: the Zig backend lowers their receiver and method name
/// directly instead of routing them through `lowerUnsupportedStdMethod`.
fn isRuntimeIteratorMethod(t: types.Type, method_name: []const u8) bool {
    const current = unpeelReceiverType(t) orelse return false;

    const external = switch (current) {
        .external_nominal => |value| value,
        else => return false,
    };
    // A carrier only dispatches when it carries exactly the arguments its own
    // definition names. `iterator_adapters` is that definition for every
    // `core::iter` adapter, so `Map<I, F>` and `Zip<L, R>` are admitted by
    // the same rule as `Enumerate<I>`.
    const required_args = iteratorCarrierArgCount(external) orelse return false;
    if (external.args.len != required_args) return false;

    return isRuntimeIteratorMethodName(method_name);
}

/// The method names a public iterator carrier keeps as ordinary runtime-backed
/// calls. Which NAMES those are is a property of the runtime, not of the
/// receiver, so this half of the rule is asked of a name alone and shared by
/// the two places that need it: the carrier that dispatches them, and the
/// receiver-type refusal that says which arm is missing.
fn isRuntimeIteratorMethodName(method_name: []const u8) bool {
    return std.mem.eql(u8, method_name, "next") or
        std.mem.eql(u8, method_name, "next_back") or
        std.mem.eql(u8, method_name, "nth") or
        std.mem.eql(u8, method_name, "nth_back") or
        std.mem.eql(u8, method_name, "count") or
        std.mem.eql(u8, method_name, "last") or
        std.mem.eql(u8, method_name, "len") or
        std.mem.eql(u8, method_name, "is_empty") or
        std.mem.eql(u8, method_name, "size_hint") or
        std.mem.eql(u8, method_name, "as_slice") or
        std.mem.eql(u8, method_name, "as_mut_slice") or
        std.mem.eql(u8, method_name, "step_by") or
        std.mem.eql(u8, method_name, "chain") or
        std.mem.eql(u8, method_name, "zip") or
        std.mem.eql(u8, method_name, "map") or
        std.mem.eql(u8, method_name, "filter") or
        std.mem.eql(u8, method_name, "filter_map") or
        std.mem.eql(u8, method_name, "enumerate") or
        std.mem.eql(u8, method_name, "peekable") or
        std.mem.eql(u8, method_name, "skip_while") or
        std.mem.eql(u8, method_name, "take_while") or
        std.mem.eql(u8, method_name, "skip") or
        std.mem.eql(u8, method_name, "take") or
        std.mem.eql(u8, method_name, "scan") or
        std.mem.eql(u8, method_name, "flat_map") or
        std.mem.eql(u8, method_name, "fuse") or
        std.mem.eql(u8, method_name, "inspect") or
        std.mem.eql(u8, method_name, "by_ref") or
        std.mem.eql(u8, method_name, "collect") or
        std.mem.eql(u8, method_name, "fold") or
        std.mem.eql(u8, method_name, "all") or
        std.mem.eql(u8, method_name, "any") or
        std.mem.eql(u8, method_name, "find") or
        std.mem.eql(u8, method_name, "position") or
        std.mem.eql(u8, method_name, "rposition") or
        std.mem.eql(u8, method_name, "max") or
        std.mem.eql(u8, method_name, "min") or
        std.mem.eql(u8, method_name, "rev") or
        std.mem.eql(u8, method_name, "clone") or
        std.mem.eql(u8, method_name, "cloned") or
        std.mem.eql(u8, method_name, "copied");
}

/// Whether `Display` for `t` is reachable without consulting the crate graph,
/// which is what a graph-free whitelist entry may assert.
///
/// Rust declares exactly one blanket implementation,
/// `impl<T: fmt::Display + ?Sized> ToString for T`, so admitting a receiver
/// here is a claim that `r2z.format.writeValue` can render it in `Display`
/// mode. That holds for:
///
///  * `bool`, `char`, and every integer primitive, which the runtime prints
///    directly;
///  * `str`, which the runtime writes byte-for-byte;
///  * `alloc::string::String` and `alloc::borrow::Cow<str>`, both of which
///    carry a `fmt` method in `r2z.alloc`.
///
/// Floats are refused even though Rust gives them a `Display`: the runtime's
/// `writeValue` has no float arm, so admitting one would resolve a call the
/// backend cannot emit. They stay refused until that gap is closed.
///
/// Everything else stays refused and the table stays a whitelist: slices and
/// arrays (Rust renders `[T]` through `Debug`, not `Display`), `Vec<T>`,
/// `Option`, `Result`, and crate-local nominals. A crate-local type is
/// admitted only where the crate itself proves the bound — `isBoundStandardMethod`
/// requires a real `impl Display for T` carrying a `fmt` member.
///
/// `Debug` is deliberately not accepted anywhere on this path. There is no
/// `impl<T: Debug> ToString for T`, so a `Debug`-only type cannot call
/// `.to_string()` in Rust and must keep resolving as unsupported here.
fn hasGraphFreeDisplay(t: types.Type) bool {
    return switch (t) {
        .prim => |primitive| switch (primitive) {
            // `()` and `!` have no `Display` implementation.
            .unit, .never => false,
            // `r2z.format.writeValue` renders integers and `u21` chars only.
            .f32, .f64 => false,
            else => true,
        },
        .external_nominal => |external| {
            if (types.isStr(t)) return true;
            if (external.args.len == 0 and external.path.len == 3 and
                (std.mem.eql(u8, external.path[0], "alloc") or
                    std.mem.eql(u8, external.path[0], "std")) and
                std.mem.eql(u8, external.path[1], "string") and
                std.mem.eql(u8, external.path[2], "String"))
            {
                return true;
            }
            if (external.path.len == 3 and external.args.len == 1 and
                (std.mem.eql(u8, external.path[0], "alloc") or
                    std.mem.eql(u8, external.path[0], "std")) and
                std.mem.eql(u8, external.path[1], "borrow") and
                std.mem.eql(u8, external.path[2], "Cow") and
                types.isStr(external.args[0]))
            {
                return true;
            }
            return false;
        },
        else => false,
    };
}

fn boundTypeName(bounds: []const types.Bound) ?[]const u8 {
    for (bounds) |bound| {
        if (bound.path.segments.len == 0) continue;
        const last = bound.path.segments[bound.path.segments.len - 1];
        if (last.name.len > 0) return last.name;
    }
    return null;
}

/// Helper to get a type's simple name from `types.Type` / symbol table.
pub fn getTypeName(g: *const graph.CrateGraph, t: types.Type) ?[]const u8 {
    switch (t) {
        .path => |p| {
            if (p.segments.len > 0) {
                const last = p.segments[p.segments.len - 1];
                // A bound path segment is authoritative. In particular,
                // `Self` keeps its source spelling after CST binding, while
                // its EntityId identifies the concrete receiver declaration.
                // Prefer that declaration name for method dispatch.
                if (last.id) |id| {
                    if (g.symbol_table.get(id)) |ent| return ent.name;
                }
                if (last.name.len > 0) return last.name;
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
        .@"opaque" => |opaque_type| return if (opaque_type.concrete) |concrete|
            getTypeName(g, concrete.*)
        else
            null,
        .dyn_trait => |bounds| return boundTypeName(bounds),
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
            .external_variant => |variant| for (variant.fields) |field| {
                if (field.pat) |field_pattern| self.visitPattern(field_pattern, init, depth + 1);
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
            .external_variant => |variant| {
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
                if (range.end) |end| self.visitExpr(end, depth + 1);
            },
            .closure => |closure| self.visitClosure(closure, depth + 1),
            .iterator_chain => |chain| self.visitIteratorChain(chain, depth + 1),
            .core_function => {},
            .core_call => |call| {
                for (call.args) |arg| self.visitExpr(arg, depth + 1);
            },
            .format_write => |format| {
                self.visitExpr(format.writer, depth + 1);
                for (format.args) |arg| self.visitExpr(arg, depth + 1);
            },
            .literal, .unit, .path, .continue_, .panic_, .unsupported => {},
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

/// `&T` to a pointee the receiver's own shape fixes. A Rust literal carries
/// its own borrow — `b"kiwi"` is `&'static [u8; 4]` — so the reference is part
/// of the type rather than an inference about the call site.
fn sharedRefType(g: *const graph.CrateGraph, pointee: types.Type) ?types.Type {
    const reference = g.allocator.create(types.Ref) catch return null;
    reference.* = .{ .mut = false, .pointee = pointee };
    return .{ .reference = reference };
}

/// The type of a string or byte-array literal receiver. `"..."` is
/// `&'static str` and `b"..."` is `&'static [u8; N]`.
///
/// Numeric literals are deliberately not covered. An unsuffixed integer or
/// float literal has no type until its surrounding context fixes one, so
/// attaching a primitive here would resolve method calls that Rust itself
/// rejects. A suffixed literal already carries a `ty` and never reaches this.
fn literalReceiverType(g: *const graph.CrateGraph, receiver: exprs.Expr) ?types.Type {
    const literal = switch (receiver.kind) {
        .literal => |value| value,
        else => return null,
    };
    return switch (literal) {
        .string => sharedRefType(g, types.str_type),
        .byte_array => |bytes| blk: {
            const array = g.allocator.create(types.Array) catch break :blk null;
            array.* = .{
                .elem = .{ .prim = .u8 },
                .len = .{ .literal = @intCast(bytes.items.len) },
            };
            break :blk sharedRefType(g, .{ .array = array });
        },
        else => null,
    };
}

/// The type of an array-literal receiver, `[T; N]`. The element type is taken
/// from the element expressions themselves, and only when inference has
/// already fixed one and every element agrees. An element with no type, or a
/// heterogeneous list, is not `[T; N]` for any `T`, so the array stays
/// untyped rather than acquiring a guessed element primitive.
fn arrayReceiverType(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    receiver: exprs.Expr,
) ?types.Type {
    const array_expr = switch (receiver.kind) {
        .array => |value| value,
        else => return null,
    };
    if (array_expr.elements.len == 0) return null;

    var element_id: ?exprs.TypeId = null;
    for (array_expr.elements) |element| {
        if (element >= b.exprs.len) return null;
        const element_type = b.exprs[element].ty orelse return null;
        if (element_type >= b.types.len) return null;
        if (element_id) |first| {
            if (first != element_type) return null;
        } else {
            element_id = element_type;
        }
    }

    const array = g.allocator.create(types.Array) catch return null;
    array.* = .{
        .elem = b.types[element_id.?],
        .len = .{ .literal = @intCast(array_expr.repeat orelse array_expr.elements.len) },
    };
    return .{ .array = array };
}

/// The type of a method receiver, recovered from the node itself when
/// inference left it without a TypeId. A `path` binds to a local or parameter
/// whose declaration carries the type; an `enum_variant` is a value of the
/// enum that owns the variant and a `struct_lit` a value of the struct it
/// spells, so each is a value of the type that declares it; a string,
/// byte-array, or array literal carries its type in its own shape; a call
/// carries the return type its own signature declares; and a method call
/// carries the result of the method it applies.
fn receiverDeclaredType(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    receiver_node: exprs.NodeId,
) ?types.Type {
    return receiverDeclaredTypeAt(g, b, receiver_node, 0);
}

/// `receiverDeclaredType` bounded by its own recursion: a chain of calls is
/// followed only as deep as the expression table is walked, and a cycle in a
/// malformed table stops the walk instead of hanging it.
fn receiverDeclaredTypeAt(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    receiver_node: exprs.NodeId,
    depth: usize,
) ?types.Type {
    if (depth >= 32 or receiver_node >= b.exprs.len) return null;
    const receiver = b.exprs[receiver_node];
    if (receiver.ty) |type_id| {
        if (type_id < b.types.len) return b.types[type_id];
        return null;
    }
    return switch (receiver.kind) {
        .path => |path| pathDeclaredType(g, b, path),
        .enum_variant => |variant| ownerPathType(
            g,
            enumVariantOwner(g, variant.def) orelse return null,
            .enum_,
        ),
        .struct_lit => |literal| ownerPathType(g, literal.def, .struct_),
        .literal => literalReceiverType(g, receiver),
        .array => arrayReceiverType(g, b, receiver),
        // `Foo::new(..)` and `make(..)` produce what their own signature
        // declares, so the call node names the type without any help from
        // inference.
        .call => |call| callDeclaredReturnType(g, b, call),
        .method_call => methodCallResultType(g, b, receiver_node, depth),
        else => null,
    };
}

/// The nominal of the declaration that owns a variant or a struct literal,
/// when that entity is a `kind` at all.
fn ownerPathType(
    g: *const graph.CrateGraph,
    entity_id: spine.EntityId,
    kind: spine.EntityKind,
) ?types.Type {
    const owner = g.symbol_table.get(entity_id) orelse return null;
    if (owner.kind != kind) return null;
    const segments = g.allocator.alloc(types.PathSegment, 1) catch return null;
    segments[0] = .{ .name = owner.name, .id = entity_id };
    return .{ .path = .{ .segments = segments } };
}

/// Result type of a method call whose own type the frontend cannot name. Two
/// sources are exact. A std method the runtime types — `to_string` returns
/// the owned `String`. And a `core::iter` adapter applied to a source
/// iterator this resolver can already type: Rust gives every adapter the
/// source as its first type parameter, so naming the carrier and the source
/// is enough to know the chain is still an iterator. Everything else — an
/// inherent method the resolver cannot see, a trait method reached through a
/// bound it cannot name — stays untyped.
fn methodCallResultType(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    node: exprs.NodeId,
    depth: usize,
) ?types.Type {
    if (stdMethodResultType(g, b, node, depth + 1)) |ty| return ty;
    return iteratorAdapterType(g, b, node, depth + 1);
}

/// The `core::iter` adapter a method call builds, or null when the call is
/// not one. The source must already be a carrier this frontend models: an
/// adapter over anything else is not a chain, and the call on it stays
/// refused.
fn iteratorAdapterType(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    node: exprs.NodeId,
    depth: usize,
) ?types.Type {
    if (node >= b.exprs.len) return null;
    const method = switch (b.exprs[node].kind) {
        .method_call => |value| value,
        else => return null,
    };
    const entity = g.symbol_table.get(method.method) orelse return null;
    const adapter = iteratorAdapter(entity.name) orelse return null;
    if (method.args.len != adapter.call_args) return null;
    if (method.receiver >= b.exprs.len) return null;
    const source = receiverDeclaredTypeAt(g, b, method.receiver, depth + 1) orelse return null;
    if (!isIteratorCarrier(source)) return null;

    const path = g.allocator.alloc([]const u8, 3) catch return null;
    path[0] = "core";
    path[1] = "iter";
    path[2] = adapter.carrier;
    if (adapter.type_args == 1) {
        const args = g.allocator.alloc(types.Type, 1) catch return null;
        args[0] = source;
        return .{ .external_nominal = .{ .path = path, .args = args } };
    }
    const args = g.allocator.alloc(types.Type, 2) catch return null;
    args[0] = source;
    args[1] = switch (adapter.payload) {
        .none => return null,
        // A closure's own type is not in the table, and no rule reads this
        // parameter: it is present so `Map<I, F>` keeps Rust's arity.
        .closure => closureTypeMarker(g) orelse return null,
        .other_iterator => receiverDeclaredTypeAt(g, b, method.args[0], depth + 1) orelse
            return null,
    };
    return .{ .external_nominal = .{ .path = path, .args = args } };
}

/// A function type that names nothing, used only as the payload parameter of
/// an adapter whose payload is a closure. No rule reads that parameter, so
/// the empty signature says only "some function".
fn closureTypeMarker(g: *const graph.CrateGraph) ?types.Type {
    const signature = g.allocator.create(types.FnPtr) catch return null;
    signature.* = .{ .params = &.{}, .ret = .{ .prim = .unit } };
    return .{ .fn_ptr = signature };
}

fn receiverNominalName(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    receiver_node: exprs.NodeId,
) ?[]const u8 {
    if (receiver_node >= b.exprs.len) return null;
    const receiver = b.exprs[receiver_node];

    // The path's resolved EntityId is the local binding identity. Use its
    // declaration/inferred type directly; never infer a type from spelling.
    if (receiverDeclaredType(g, b, receiver_node)) |ty| {
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
        // `FromHexError::OddLength` is a `FromHexError`. A variant node names
        // the enum that owns it, so the receiver's type is recoverable even
        // when inference left the node untyped.
        .enum_variant => |variant| if (enumVariantOwner(g, variant.def)) |owner_id|
            (g.symbol_table.get(owner_id) orelse return null).name
        else
            null,
        else => null,
    };
}

/// The enum that owns an `enum_variant` expression. The node names the
/// variant entity when the graph linked one and the enum otherwise, so the
/// owner is one level up in the first case — the same two shapes the Zig
/// backend reads in `enumOwnerName`.
fn enumVariantOwner(g: *const graph.CrateGraph, def: spine.EntityId) ?spine.EntityId {
    const entity = g.symbol_table.get(def) orelse return null;
    return if (entity.kind == .variant) entity.parent else def;
}

fn pathDeclaredType(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    path: exprs.PathExpr,
) ?types.Type {
    const entity = g.symbol_table.get(path.def) orelse return null;
    // A field carries its declared type on the owning struct, which is
    // reachable without going through an enclosing function body.
    if (entity.kind == .field) {
        if (entity.parent) |owner| {
            if (owner < b.bodies.len) {
                switch (b.bodies[owner]) {
                    .struct_ => |structure| {
                        for (structure.fields) |field| {
                            if (std.mem.eql(u8, field.name, entity.name)) return field.ty;
                        }
                    },
                    else => {},
                }
            }
        }
    }
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
        .path => |path| blk: {
            if (pathDeclaredType(g, b, path) != null) break :blk true;
            // A binding a macro expansion introduced is parented to its
            // function rather than to a struct, and its type only becomes
            // known once inference runs. It is a real operand, so leave the
            // decision to the primitive and operator checks below.
            if (g.symbol_table.get(path.def)) |entity| {
                if (entity.kind == .field) {
                    if (entity.parent) |owner| {
                        if (owner < b.bodies.len and b.bodies[owner] == .fn_) break :blk true;
                    }
                }
            }
            break :blk false;
        },
        .binary => |binary| operandTypeResolved(g, b, binary.lhs) and operandTypeResolved(g, b, binary.rhs),
        .cast => |cast| operandTypeResolved(g, b, cast.operand),
        // A deref takes its type from the reference it dereferences, and an
        // enum variant always has its owner's type.
        .unary => |unary| operandTypeResolved(g, b, unary.operand),
        .enum_variant => true,
        // A call whose callee has a declared return type is a typed operand.
        .call => |call| callDeclaredReturnType(g, b, call) != null,
        // A method call is typed on the same rule a free call follows: once
        // its result type is known, the operand is a real value.
        .method_call => stdMethodResultType(g, b, node, 0) != null,
        else => false,
    };
}

/// Whether an operand already carries a refusal of its own.
///
/// The wrappers that carry no type of their own are followed, because they
/// read the value they wrap: `&expr`, `*expr`, `(expr as T)`, `expr.field`,
/// and `expr[i]` are all refused exactly when what they read is. Everything
/// else is a value in its own right, and only reports its own kind.
fn operandIsRefused(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    node: exprs.NodeId,
) bool {
    return operandRefused(g, b, node, 0);
}

/// `operandIsRefused` bounded by its own recursion: a chain of wrappers is
/// followed only as deep as the expression table is walked.
fn operandRefused(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    node: exprs.NodeId,
    depth: usize,
) bool {
    if (depth >= 32 or node >= b.exprs.len) return false;
    return switch (b.exprs[node].kind) {
        .unsupported => true,
        .unary => |unary| operandRefused(g, b, unary.operand, depth + 1),
        .cast => |cast| operandRefused(g, b, cast.operand, depth + 1),
        .field => |field| operandRefused(g, b, field.base, depth + 1),
        .index => |index| operandRefused(g, b, index.base, depth + 1),
        .try_ => |attempt| operandRefused(g, b, attempt.inner, depth + 1),
        .binary => |binary| operandRefused(g, b, binary.lhs, depth + 1) or
            operandRefused(g, b, binary.rhs, depth + 1),
        else => false,
    };
}

/// Whether an operator may read this type as one of its operands.
///
/// A `.path` that names a local `type` alias stands for the very value its
/// alias body names, so `type Chunk = u32;` has to answer for `u32`: the CST
/// layer records the alias path as the declared type wherever the alias is
/// spelled, and refusing an operator on it refuses `u32` arithmetic written
/// through a name. Everything else that is not a primitive once references
/// are peeled is a nominal, an aggregate, or a type this pass could not
/// name, and none of those is a scalar operand.
fn isScalarOperandType(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    t: types.Type,
) bool {
    var current = t;
    var hops: usize = 0;
    while (hops < 128) : (hops += 1) {
        switch (current) {
            .reference => current = current.reference.pointee,
            .path => current = aliasBodyType(g, b, current.path) orelse return false,
            .prim => return true,
            else => return false,
        }
    }
    return false;
}

/// The type a local `type` alias stands for, or null when the path names no
/// alias body this pass can read.
///
/// The terminal segment carries the EntityId the path resolved to, and a
/// `type_alias` body names its own target, so a chain of aliases resolves the
/// same way the CST layer resolves a single one. A path that resolved to a
/// nominal, or did not resolve at all, has no body to follow.
fn aliasBodyType(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    path: types.Path,
) ?types.Type {
    if (path.segments.len == 0) return null;
    const alias_id = path.segments[path.segments.len - 1].id orelse return null;
    const entity = g.symbol_table.get(alias_id) orelse return null;
    if (entity.kind != .type_alias) return null;
    if (alias_id >= b.bodies.len) return null;
    return switch (b.bodies[alias_id]) {
        .type_alias => |alias| alias.target,
        else => null,
    };
}

fn isRuntimeMemoryMethod(t: types.Type, name: []const u8) bool {
    var current = t;
    for (0..128) |_| {
        if (current != .reference) break;
        current = current.reference.pointee;
    }
    return switch (current) {
        .raw_ptr => std.mem.eql(u8, name, "add") or
            std.mem.eql(u8, name, "sub") or
            std.mem.eql(u8, name, "offset") or
            std.mem.eql(u8, name, "read_unaligned"),
        .slice, .array => std.mem.eql(u8, name, "as_ptr") or
            std.mem.eql(u8, name, "as_mut_ptr") or
            std.mem.eql(u8, name, "get_unchecked") or
            std.mem.eql(u8, name, "get_unchecked_mut"),
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
        return isScalarOperandType(g, b, b.types[type_id]);
    }
    return switch (operand.kind) {
        .literal => |literal| switch (literal) {
            .int, .float, .character, .boolean => true,
            .string, .byte_array => false,
        },
        .path => |path| isScalarOperandType(g, b, pathDeclaredType(g, b, path) orelse return false),
        // A method call is primitive on the same rule `operandTypeResolved`
        // already follows for it: a result type this pass names is a real
        // value, and whether it is one an operator can read is that type's
        // own question. Asking here is what keeps the two halves from
        // disagreeing — a `len()` this pass names is `usize` to both.
        .method_call => isScalarOperandType(g, b, stdMethodResultType(g, b, node, 0) orelse return false),
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

/// The method names the runtime drives over a retained slice iterator.
///
/// `cloned` erases the borrow the iterator hands out, and `rev` wraps it in
/// the `core::iter::Rev` carrier the runtime already has as `r2z.Rev`. Both
/// stay ordinary calls over the receiver this pass kept in the tree, so
/// neither needs the backend to resolve a carrier of its own before it can
/// lower them. Any other name over this receiver shape has no such arm, which
/// is why the admission is this list and not the receiver's whole method set.
fn isRetainedIteratorProjectionMethod(method_name: []const u8) bool {
    return std.mem.eql(u8, method_name, "cloned") or
        std.mem.eql(u8, method_name, "rev");
}

fn isRuntimeIoMethod(g: *const graph.CrateGraph, b: *const bodies.Bodies, method_id: exprs.DefId, receiver: types.Type, name: []const u8) bool {
    const trait_name: []const u8 = if (std.mem.eql(u8, name, "read_exact"))
        "Read"
    else if (std.mem.eql(u8, name, "write_all"))
        "Write"
    else
        return false;
    const method = g.symbol_table.get(method_id) orelse return false;
    const owner = method.parent orelse return false;
    return bodies.genericBound(g, b, owner, receiver, &.{ "std", "io", trait_name }) != null;
}

fn isBoundStandardMethod(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    expression: exprs.Expr,
    receiver: types.Type,
    name: []const u8,
) bool {
    // `ToString::to_string` is blanket-implemented for `T: Display`. The
    // method entity is a synthesized reference with no owning declaration, so
    // this bound is proven from the crate's own trait impls instead of from
    // the method's generic bounds.
    if (std.mem.eql(u8, name, "to_string")) {
        const type_name = getTypeName(g, receiver) orelse return false;
        // Requiring the `fmt` member is deliberate: it is the evidence that a
        // `Display` path exists, and it is exactly what `r2z.format.write`
        // calls on the lowered type. `Debug` is not a substitute, because
        // Rust declares only `impl<T: Display + ?Sized> ToString for T`.
        return lookupTraitMethod(g, "Display", type_name, "fmt") != null;
    }
    const method = g.symbol_table.get(expression.kind.method_call.method) orelse return false;
    const owner = method.parent orelse return false;
    if (std.mem.eql(u8, name, "as_ref")) {
        return bodies.genericBound(g, b, owner, receiver, &.{ "core", "convert", "AsRef" }) != null;
    }
    if (std.mem.eql(u8, name, "try_into")) {
        if (bodies.genericBound(g, b, owner, receiver, &.{ "core", "convert", "TryInto" }) != null) return true;
        return switch (receiver) {
            .prim => |primitive| switch (primitive) {
                .i8,
                .i16,
                .i32,
                .i64,
                .i128,
                .isize,
                .u8,
                .u16,
                .u32,
                .u64,
                .u128,
                .usize,
                => true,
                else => false,
            },
            else => false,
        };
    }
    if (std.mem.eql(u8, name, "into")) {
        if (bodies.genericBound(g, b, owner, receiver, &.{ "core", "convert", "Into" }) != null) return true;
        const result_id = expression.ty orelse return false;
        if (result_id >= b.types.len) return false;
        return bodies.genericBound(g, b, owner, b.types[result_id], &.{ "core", "convert", "From" }) != null;
    }
    return false;
}

fn associatedSelfType(declared: types.Type, actual: types.Type, depth: usize) ?types.Type {
    if (depth >= 128) return null;
    if (declared == .path and declared.path.segments.len == 1 and
        std.mem.eql(u8, declared.path.segments[0].name, "Self")) return actual;
    if (std.meta.activeTag(declared) != std.meta.activeTag(actual)) return null;
    return switch (declared) {
        .result => |result| associatedSelfType(result.ok, actual.result.ok, depth + 1) orelse
            associatedSelfType(result.err, actual.result.err, depth + 1),
        .option => |value| associatedSelfType(value.*, actual.option.*, depth + 1),
        .reference => |value| associatedSelfType(value.pointee, actual.reference.pointee, depth + 1),
        .raw_ptr => |value| associatedSelfType(value.pointee, actual.raw_ptr.pointee, depth + 1),
        .boxed => |value| associatedSelfType(value.*, actual.boxed.*, depth + 1),
        .slice => |value| associatedSelfType(value.elem, actual.slice.elem, depth + 1),
        .array => |value| associatedSelfType(value.elem, actual.array.elem, depth + 1),
        else => null,
    };
}

fn resolveAssociatedTraitCall(g: *const graph.CrateGraph, b: *const bodies.Bodies, expression: *exprs.Expr) bool {
    const call = expression.kind.call;
    if (call.call_kind != .associated) return false;
    const method = g.symbol_table.get(call.call_kind.associated) orelse return false;
    if (method.kind != .method_ref) return false;
    const trait_id = method.parent orelse return false;
    const trait_entity = g.symbol_table.get(trait_id) orelse return false;
    if (trait_entity.kind != .trait_ or trait_id >= b.bodies.len) return false;
    const trait_body = switch (b.bodies[trait_id]) {
        .trait_ => |body| body,
        else => return false,
    };
    const result_id = expression.ty orelse return false;
    if (result_id >= b.types.len) return false;
    for (trait_body.methods) |signature| {
        if (!std.mem.eql(u8, signature.name, method.name)) continue;
        const receiver = associatedSelfType(signature.ret, b.types[result_id], 0) orelse return false;
        const name = getTypeName(g, receiver) orelse return false;
        const implementation = lookupTraitMethod(g, trait_entity.name, name, method.name) orelse return false;
        expression.kind.call.call_kind = .{ .associated = implementation };
        return true;
    }
    return false;
}

fn operatorOperandType(g: *const graph.CrateGraph, b: *const bodies.Bodies, node: exprs.NodeId) ?types.Type {
    return operatorOperandTypeAt(g, b, node, 0);
}

/// A borrow or a deref carries no type of its own — the operand's type is the
/// only source — so `&output` must report `&[u8; 4]`, not a bare null. Without
/// this, every `&local == ..` comparison looks untyped to the equality checks.
/// The wrapper reference borrows storage from the crate graph's allocator,
/// which the pipeline backs with an arena spanning the whole analysis.
fn operatorOperandTypeAt(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    node: exprs.NodeId,
    depth: usize,
) ?types.Type {
    if (depth >= 128 or node >= b.exprs.len) return null;
    const expression = b.exprs[node];
    if (expression.ty) |id| return if (id < b.types.len) b.types[id] else null;
    return switch (expression.kind) {
        .path => |path| pathDeclaredType(g, b, path),
        .unary => |unary| blk: {
            const inner = operatorOperandTypeAt(g, b, unary.operand, depth + 1) orelse break :blk null;
            const mode = switch (unary.op) {
                .ref => |reference_mode| reference_mode,
                else => break :blk inner,
            };
            const reference = g.allocator.create(types.Ref) catch break :blk inner;
            reference.* = .{ .mut = mode == .mutable, .pointee = inner };
            break :blk .{ .reference = reference };
        },
        .call => |call| callDeclaredReturnType(g, b, call),
        .method_call => stdMethodResultType(g, b, node, depth),
        else => null,
    };
}

/// The `alloc::string::String` nominal. The path is allocated from the crate
/// graph's allocator, which the pipeline backs with an arena.
fn ownedStringType(g: *const graph.CrateGraph) ?types.Type {
    const path = g.allocator.alloc([]const u8, 3) catch return null;
    path[0] = "alloc";
    path[1] = "string";
    path[2] = "String";
    return .{ .external_nominal = .{ .path = path, .args = &.{} } };
}

/// Result type of a std method whose result the RUNTIME owns, read off the
/// receiver rather than from a signature in the graph.
///
/// Three methods reach this, and all three name their own result exactly:
///
/// - `to_string` returns the owned `String` of Rust's blanket
///   `impl<T: Display> ToString for T`, which the backend lowers to
///   `r2z.alloc.String`.
/// - `Result<T, E>::unwrap_err(&self) -> E` returns the error arm of the
///   receiver, and the receiver is the `Result` that arm sits in.
/// - `len()` returns the element count of the sequence it is called on, and
///   `usize` is that count's type in every Rust build. A slice and a
///   `[T; N]` are both a count, and both lower to a Zig `.len`.
///
/// Every other std method returns a primitive, an iterator, or something this
/// pass cannot name, so it stays unresolved and an operator over it is still
/// refused instead of being emitted against a guessed type.
fn stdMethodResultType(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    node: exprs.NodeId,
    depth: usize,
) ?types.Type {
    if (depth >= 128 or node >= b.exprs.len) return null;
    const expression = b.exprs[node];
    if (expression.ty) |id| return if (id < b.types.len) b.types[id] else null;
    const method = switch (expression.kind) {
        .method_call => |value| value,
        else => return null,
    };
    if (method.receiver >= b.exprs.len) return null;
    const entity = g.symbol_table.get(method.method) orelse return null;
    const is_to_string = std.mem.eql(u8, entity.name, "to_string");
    const is_len = std.mem.eql(u8, entity.name, "len");
    if (!is_to_string and !is_len and !std.mem.eql(u8, entity.name, "unwrap_err")) return null;
    const receiver_ty = receiverDeclaredType(g, b, method.receiver) orelse return null;
    if (is_len) {
        // The evidence is the dispatch the resolver admits the call on, so
        // this cannot name a `len` the resolver would refuse: only a receiver
        // `lookupStdMethod` matches the slice `len` for is typed here. A
        // `Vec`/`String` receiver, or an `ExactSizeIterator::len` on an
        // iterator, keeps its own signature and stays unresolved.
        const std_method = lookupStdMethod(receiver_ty, "len") orelse return null;
        if (std_method != .slice_len) return null;
        return .{ .prim = .usize };
    }
    if (is_to_string) {
        // The call is admitted on exactly the two rules the resolver applies to
        // it: the graph-free `Display` set, or a crate-local `impl Display`.
        // Requiring the same evidence keeps this from typing a call the
        // resolver will replace with an unsupported marker.
        const std_method = lookupStdMethod(receiver_ty, "to_string");
        if (std_method == null or std_method.? != .to_string) {
            if (!isBoundStandardMethod(g, b, expression, receiver_ty, "to_string")) return null;
        }
        return ownedStringType(g);
    }
    // The question is the one `lookupResultRepresentationMethod` already
    // answers for the CALL, so the two cannot disagree: a `Result` that lowers
    // to a Zig error union keeps its error in the union and has no value to
    // hand back, and that receiver is refused as a method call too. Reading
    // `is_error_unionable` alone would type an operand the resolver refuses,
    // and an operator over it would be emitted against a value the backend's
    // switch has no arm for.
    const representation = lookupResultRepresentationMethod(b, receiver_ty, "unwrap_err") orelse return null;
    if (representation != .result_unwrap_err) return null;
    const result = switch (unpeelReceiverType(receiver_ty) orelse return null) {
        .result => |value| value.*,
        else => return null,
    };
    return result.err;
}

/// Declared return type of a call's callee. A call is a typed operand as soon
/// as its signature is known, exactly as a `path` operand is typed by its
/// declaration. Both a plain function and a method reached through an `impl`
/// block are covered.
fn callDeclaredReturnType(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    call: exprs.Call,
) ?types.Type {
    const target: spine.EntityId = switch (call.call_kind) {
        .free, .associated, .constructor => |id| id,
    };
    if (target >= b.bodies.len) return null;
    return switch (b.bodies[target]) {
        .fn_ => |body| body.ret,
        .impl_ => |body| blk: {
            const entity = g.symbol_table.get(target) orelse break :blk null;
            for (body.assoc_items) |assoc_id| {
                const assoc = g.symbol_table.get(assoc_id) orelse continue;
                if (!std.mem.eql(u8, assoc.name, entity.name)) continue;
                if (assoc.id >= b.bodies.len) continue;
                switch (b.bodies[assoc.id]) {
                    .fn_ => |method| break :blk method.ret,
                    .struct_ => |structure| {
                        for (structure.methods) |method| {
                            if (std.mem.eql(u8, method.name, entity.name)) break :blk method.ret;
                        }
                    },
                    else => {},
                }
            }
            break :blk null;
        },
        else => null,
    };
}

fn expressionOwner(g: *const graph.CrateGraph, b: *const bodies.Bodies, node: exprs.NodeId, depth: usize) ?spine.EntityId {
    if (depth >= 128 or node >= b.exprs.len) return null;
    return switch (b.exprs[node].kind) {
        .path => |path| blk: {
            const entity = g.symbol_table.get(path.def) orelse break :blk null;
            const parent = entity.parent orelse break :blk null;
            const owner = g.symbol_table.get(parent) orelse break :blk null;
            break :blk if (owner.kind == .fn_ or owner.kind == .impl_) parent else null;
        },
        .field => |field| expressionOwner(g, b, field.base, depth + 1),
        .index => |index| expressionOwner(g, b, index.base, depth + 1),
        .unary => |unary| expressionOwner(g, b, unary.operand, depth + 1),
        .cast => |cast| expressionOwner(g, b, cast.operand, depth + 1),
        .binary => |binary| expressionOwner(g, b, binary.lhs, depth + 1) orelse
            expressionOwner(g, b, binary.rhs, depth + 1),
        .call => |call| switch (call.call_kind) {
            .free, .associated, .constructor => |id| id,
        },
        .method_call => |method| expressionOwner(g, b, method.receiver, depth + 1),
        else => null,
    };
}

fn boundOperator(g: *const graph.CrateGraph, b: *const bodies.Bodies, lhs: exprs.NodeId, rhs: exprs.NodeId, module: []const u8, name: []const u8) bool {
    const receiver = operatorOperandType(g, b, lhs) orelse return false;
    const owner = expressionOwner(g, b, lhs, 0) orelse expressionOwner(g, b, rhs, 0) orelse return false;
    return bodies.genericBound(g, b, owner, receiver, &.{ "core", module, name }) != null;
}

/// True when `r2z.ops.equal` has value semantics for `ty`.
///
/// A `Result` is admitted whenever both payloads have value semantics, because
/// the runtime compares the variant tag first and then the active payload —
/// including payloads that are themselves slices, lists, or nested results.
/// Payloads that carry no comparable value (function pointers, trait objects,
/// opaque declarations) are refused.
fn equalityPayloadComparable(ty: types.Type, depth: usize) bool {
    if (depth >= 128) return false;
    return switch (ty) {
        .fn_ptr, .boxed, .dyn_trait, .@"opaque", .unsupported => false,
        .reference => |reference| equalityPayloadComparable(reference.pointee, depth + 1),
        .result => |result| equalityPayloadComparable(result.ok, depth + 1) and
            equalityPayloadComparable(result.err, depth + 1),
        else => true,
    };
}

/// Rust owners the runtime lowers to a list-backed Zig container.
///
/// `String` lowers to `r2z.alloc.String` (one `bytes` list field) and `Vec<T>`
/// to `std.ArrayListUnmanaged(T)`. `r2z.ops.equal` reaches the list's `items`
/// for both, so the comparison is by CONTENT: the allocated capacity is never
/// read, and a string's length is only ever read as the length of the slice
/// the element walk already compares.
fn isListBackedOwnerNominal(external: types.ExternalNominal) bool {
    const path = external.path;
    if (path.len != 3) return false;
    if (!std.mem.eql(u8, path[0], "alloc") and !std.mem.eql(u8, path[0], "std")) return false;
    if (std.mem.eql(u8, path[1], "string") and std.mem.eql(u8, path[2], "String")) {
        return external.args.len == 0;
    }
    if (std.mem.eql(u8, path[1], "vec") and std.mem.eql(u8, path[2], "Vec")) {
        return external.args.len == 1 and equalityPayloadComparable(external.args[0], 0);
    }
    return false;
}

/// Whether `ty` is a Rust owner the runtime holds behind a list. A borrow of
/// one still names the owner, because the runtime walks through the pointer.
fn isListBackedOwner(ty: types.Type) bool {
    return switch (ty) {
        .reference => |reference| isListBackedOwner(reference.pointee),
        .external_nominal => |external| isListBackedOwnerNominal(external),
        else => false,
    };
}

/// Whether an operand is a Rust BORROW of a list rather than an owner of one.
///
/// `&[T]`, `&[T; N]` and `&str` are borrows, and so is the `"..."` / `b"..."`
/// literal that stands for one. A DECLARED type decides first: inference
/// sometimes types a string literal as the owned `String` it will become, and
/// reading that operand by shape would report an owner as a borrow. Only a
/// literal the frontend left untyped — the shape `assert_eq!` produces — is
/// read by shape at all, and there the literal form IS the borrow.
fn isListBackedBorrow(b: *const bodies.Bodies, node: exprs.NodeId) bool {
    if (node >= b.exprs.len) return false;
    if (b.exprs[node].ty) |id| {
        return id < b.types.len and isListBorrowType(b.types[id]);
    }
    return switch (b.exprs[node].kind) {
        .literal => |literal| switch (literal) {
            .string, .byte_array => true,
            else => false,
        },
        else => false,
    };
}

/// A type the runtime compares as a sequence. `String` and `Vec<T>` are not
/// among them: they are the owners a borrow is measured against. `str` is
/// Rust's unsized byte sequence, so it is one whatever form it is reached in.
fn isListBorrowType(ty: types.Type) bool {
    if (types.isStr(ty)) return true;
    return switch (ty) {
        .reference => |reference| isListBorrowType(reference.pointee),
        .slice, .array => true,
        else => false,
    };
}

/// Both operands of an `==` or `!=`, decided as a pair.
///
/// `r2z.ops.equal` walks a list-backed owner by descending into the list it
/// holds, so an owner and a BORROW of a list are the same Rust value in two
/// forms: either side may be the owner, and the walk meets the other side's
/// items. Rust compares `String == &str` the same way, which is why the pair is
/// admitted instead of staged as a package that cannot build. An owner against
/// a value that is neither an owner nor a borrow has no list to meet, and
/// stays refused: the walk would read a field the far side does not have.
/// Owner against owner, and borrow against borrow, keep the per-type whitelist.
fn equalityOperandsComparable(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    lhs: exprs.NodeId,
    rhs: exprs.NodeId,
) bool {
    const lhs_ty = operatorOperandType(g, b, lhs);
    const rhs_ty = operatorOperandType(g, b, rhs);
    const lhs_is_owner = lhs_ty != null and isListBackedOwner(lhs_ty.?);
    const rhs_is_owner = rhs_ty != null and isListBackedOwner(rhs_ty.?);
    if (lhs_is_owner != rhs_is_owner) {
        return if (lhs_is_owner) isListBackedBorrow(b, rhs) else isListBackedBorrow(b, lhs);
    }
    if (lhs_ty) |ty| {
        if (builtInEqualityType(b, ty)) return true;
    }
    if (rhs_ty) |ty| {
        if (builtInEqualityType(b, ty)) return true;
    }
    return false;
}

fn builtInEqualityType(b: *const bodies.Bodies, ty: types.Type) bool {
    return switch (ty) {
        .reference => |reference| builtInEqualityType(b, reference.pointee),
        .slice, .array, .option, .raw_ptr => true,
        .result => |result| equalityPayloadComparable(result.ok, 0) and
            equalityPayloadComparable(result.err, 0),
        .external_nominal => |external| isListBackedOwnerNominal(external),
        .path => |path| enumVariantsComparable(b, path),
        else => false,
    };
}

/// A crate enum, which the runtime compares as a tagged union: the tag first,
/// then the ACTIVE payload (`r2z.ops.equal`, `equalUnion`). The walk reaches
/// that payload through the same recursion it reaches a `Result` arm through,
/// so the type is comparable exactly when every variant's payload is — the
/// question `equalityPayloadComparable` already answers for a `Result`.
/// A data-carrying enum is the one this covers that has no other route: Rust
/// compares it by value through a `derive`d `PartialEq` that never appears in
/// the graph as an `impl`, and Zig cannot `==` a union with a payload at all.
///
/// A name that resolves to anything but an enum in the body table stays out. A
/// struct is not walked by this rule, an enum this pass cannot see the
/// variants of is one it cannot show the walk reaching, and a type parameter
/// names no variants at all.
fn enumVariantsComparable(b: *const bodies.Bodies, path: types.Path) bool {
    var last: ?spine.EntityId = null;
    for (path.segments) |segment| last = segment.id;
    const id = last orelse return false;
    if (id >= b.bodies.len) return false;
    const body = switch (b.bodies[id]) {
        .enum_ => |value| value,
        else => return false,
    };
    for (body.variants) |variant| {
        switch (variant.fields) {
            .none => {},
            .tuple => |fields| for (fields) |field| {
                if (!equalityPayloadComparable(field, 0)) return false;
            },
            .named => |fields| for (fields) |field| {
                if (!equalityPayloadComparable(field.ty, 0)) return false;
            },
        }
    }
    return true;
}

/// Element type a literal contributes to a comparison. A byte or string
/// literal pins the element to `u8`, which is what lets an untyped local be
/// compared against it: Rust's `PartialEq<Rhs>` fixes the left element type
/// from the right.
fn literalElementType(b: *const bodies.Bodies, node: exprs.NodeId) ?types.Type {
    if (node >= b.exprs.len) return null;
    return switch (b.exprs[node].kind) {
        .literal => |literal| switch (literal) {
            .byte_array, .string => types.Type{ .prim = .u8 },
            else => null,
        },
        else => null,
    };
}

fn arrayElementType(ty: types.Type) ?types.Type {
    return switch (ty) {
        .array => |array| array.elem,
        .reference => |reference| arrayElementType(reference.pointee),
        else => null,
    };
}

/// Repeat length of a local's `[element; N]` initializer, when the local has
/// exactly that shape. `let mut output = [0; 4 * 2];` has no declared type,
/// so its length is only recoverable from the initializer.
fn repeatedArrayInitializerLen(g: *const graph.CrateGraph, b: *const bodies.Bodies, node: exprs.NodeId) ?usize {
    if (node >= b.exprs.len) return null;
    const target = switch (b.exprs[node].kind) {
        .unary => |unary| unary.operand,
        else => node,
    };
    if (target >= b.exprs.len) return null;
    const path = switch (b.exprs[target].kind) {
        .path => |value| value,
        else => return null,
    };
    const init = findLocalInitializer(g, b, path) orelse return null;
    if (init >= b.exprs.len) return null;
    const array = switch (b.exprs[init].kind) {
        .array => |value| value,
        else => return null,
    };
    const repeat = array.repeat orelse return null;
    if (repeat == 0 or array.elements.len != 1) return null;
    return repeat;
}

/// An `&local == b"..."` comparison whose local is an untyped `[0; N]`
/// buffer. Both the length and the element type come from the operands
/// themselves, so no declared type is invented for the local.
fn untypedArrayEqualityOperand(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    lhs: exprs.NodeId,
    rhs: exprs.NodeId,
) bool {
    const len = repeatedArrayInitializerLen(g, b, lhs) orelse return false;
    const elem = literalElementType(b, rhs) orelse
        (if (operatorOperandType(g, b, rhs)) |ty| arrayElementType(ty) else null) orelse
        return false;
    const array = g.allocator.create(types.Array) catch return false;
    array.* = .{ .elem = elem, .len = .{ .literal = len } };
    return builtInEqualityType(b, .{ .array = array });
}

fn supportsBinaryOperator(g: *const graph.CrateGraph, b: *const bodies.Bodies, binary: exprs.BinaryExpr) bool {
    const operation: [3][]const u8 = switch (binary.op) {
        .add => .{ "ops", "Add", "add" },
        .sub => .{ "ops", "Sub", "sub" },
        .mul => .{ "ops", "Mul", "mul" },
        .div => .{ "ops", "Div", "div" },
        .rem => .{ "ops", "Rem", "rem" },
        .bit_and => .{ "ops", "BitAnd", "bitand" },
        .bit_or => .{ "ops", "BitOr", "bitor" },
        .bit_xor => .{ "ops", "BitXor", "bitxor" },
        .shl => .{ "ops", "Shl", "shl" },
        .shr => .{ "ops", "Shr", "shr" },
        .eq, .ne => .{ "cmp", "PartialEq", "eq" },
        .lt, .le, .gt, .ge => .{ "cmp", "PartialOrd", @tagName(binary.op) },
        .boolean_and, .boolean_or => return false,
    };
    if (binary.op == .eq or binary.op == .ne) {
        // Both sides are consulted: a comparison is admitted when the pair
        // pins a comparable type for both of its operands.
        if (equalityOperandsComparable(g, b, binary.lhs, binary.rhs)) return true;
        if (untypedArrayEqualityOperand(g, b, binary.lhs, binary.rhs)) return true;
        if (untypedArrayEqualityOperand(g, b, binary.rhs, binary.lhs)) return true;
    }
    if (boundOperator(g, b, binary.lhs, binary.rhs, operation[0], operation[1])) return true;
    const receiver = receiverNominalName(g, b, binary.lhs) orelse return false;
    return lookupTraitMethod(g, operation[1], receiver, operation[2]) != null;
}
fn resolveAssignmentOperator(g: *const graph.CrateGraph, b: *const bodies.Bodies, expression: *exprs.Expr) std.mem.Allocator.Error!bool {
    const assignment = expression.kind.assign;
    if (assignment.op == .plain or operandIsPrimitive(g, b, assignment.target)) return false;
    const operation: [2][]const u8 = switch (assignment.op) {
        .plain => return false,
        .add => .{ "AddAssign", "add_assign" },
        .sub => .{ "SubAssign", "sub_assign" },
        .mul => .{ "MulAssign", "mul_assign" },
        .div => .{ "DivAssign", "div_assign" },
        .rem => .{ "RemAssign", "rem_assign" },
        .bit_and => .{ "BitAndAssign", "bitand_assign" },
        .bit_or => .{ "BitOrAssign", "bitor_assign" },
        .bit_xor => .{ "BitXorAssign", "bitxor_assign" },
        .shl => .{ "ShlAssign", "shl_assign" },
        .shr => .{ "ShrAssign", "shr_assign" },
    };
    const receiver_name = receiverNominalName(g, b, assignment.target) orelse return false;
    const method = lookupTraitMethod(g, operation[0], receiver_name, operation[1]) orelse
        return boundOperator(g, b, assignment.target, assignment.value, "ops", operation[0]);
    const args = try g.allocator.dupe(exprs.NodeId, &.{assignment.value});
    expression.kind = .{ .method_call = .{
        .receiver = assignment.target,
        .receiver_mode = .mutable,
        .method = method,
        .args = args,
    } };
    return true;
}

/// Resolve all method calls in `b.exprs` using the crate graph and types table.
pub fn resolveMethods(
    g: *const graph.CrateGraph,
    b: *bodies.Bodies,
) std.mem.Allocator.Error!ResolutionStats {
    var stats: ResolutionStats = .{};
    for (@constCast(b.exprs)) |*e| {
        if (e.kind == .call and resolveAssociatedTraitCall(g, b, e)) {
            stats.trait_resolved += 1;
        }
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
            const receiver_ty = receiverDeclaredType(g, b, receiver_node);
            const iterator_projection = isRetainedIteratorProjection(g, b, receiver_node);
            if (iterator_projection) {
                if (isRetainedIteratorProjectionMethod(method_name)) {
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

            // Keep standard methods and canonical iterator calls dispatchable.
            // Iterator methods stay ordinary calls because their runtime
            // implementation is selected by the backend from the external
            // iterator carrier and method name.
            if (!resolved) {
                if (receiver_ty) |ty| {
                    // A runtime iterator method is lowered by the Zig backend
                    // from the receiver's EXTERNAL carrier type, and it peels
                    // an `impl Trait` to the concrete the frontend recovered
                    // beside it before it looks. An opaque that recovered a
                    // carrier therefore reaches the same arm a nominal reaches,
                    // which is why every predicate here reads the opaque's own
                    // `concrete` and they all answer alike.
                    //
                    // What no side can reach is an opaque that recovered
                    // NOTHING. There is no carrier to peel to, so a runtime
                    // iterator method on it would be emitted as a bare
                    // `receiver.method(..)` against a type nothing can write.
                    // Refuse that here, where the reason can say what is
                    // missing. Each clause below is load-bearing for the
                    // REASON, not only for the refusal: the method has to be
                    // a runtime iterator method, or no such arm is missing;
                    // the receiver has to be one no side can name; and that
                    // has to be because it is an `impl Trait` with no
                    // carrier, because a slice and a `u8` are just as
                    // unnameable and just as have no opaque arm to lack.
                    if (isRuntimeIteratorMethodName(method_name) and
                        !hasNamedReceiverType(ty) and
                        isUnpeelableOpaqueReceiver(ty))
                    {
                        replaceWithUnsupported(e, reason_opaque_iterator_method);
                        stats.unsupported_methods += 1;
                        continue;
                    }
                    if (lookupStdMethod(ty, method_name) != null or
                        lookupResultRepresentationMethod(b, ty, method_name) != null or
                        isRuntimeIteratorMethod(ty, method_name) or
                        isRuntimeMemoryMethod(ty, method_name) or
                        isBoundStandardMethod(g, b, e.*, ty, method_name) or
                        isRuntimeIoMethod(g, b, mc.method, ty, method_name))
                    {
                        stats.std_resolved += 1;
                        resolved = true;
                    }
                }
            }
            // A blanket `impl<T: AsRef<[u8]>> Trait for T` provides its method
            // for every type its bound admits, and an array receiver is one
            // of them. The impl names no concrete self type, so nothing here
            // can pick the call's method by receiver name; what it can do is
            // name the TRAIT, which is how the backend reaches the impl it
            // provides the method from.
            if (!resolved and blanketArrayReceiver(b, receiver)) {
                if (lookupBlanketAsRefBytesTrait(g, b, method_name)) |trait_id| {
                    if (bindBlanketImplMethod(g, mc.method, trait_id)) {
                        stats.trait_resolved += 1;
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
        } else if (e.kind == .assign) {
            if (try resolveAssignmentOperator(g, b, e)) {
                stats.trait_resolved += 1;
            } else if (e.kind.assign.op != .plain and !operandIsPrimitive(g, b, e.kind.assign.target)) {
                replaceWithUnsupported(e, reason_operator_requires_primitives);
                stats.unsupported_operators += 1;
            }
        } else if (e.kind == .binary) {
            const binary = e.kind.binary;
            // An operand that already carries a refusal needs no second,
            // vaguer marker here. The operator is not itself untranslatable —
            // the value it reads is — and the refusal already in the tree is
            // the one that names the cause, so re-marking the operator only
            // hides it behind a generic "operands unresolved".
            if (operandIsRefused(g, b, binary.lhs) or operandIsRefused(g, b, binary.rhs)) {
                continue;
            }
            if (!operandTypeResolved(g, b, binary.lhs) or !operandTypeResolved(g, b, binary.rhs)) {
                replaceWithUnsupported(e, operatorOperandsUnresolvedReason(b, binary));
                stats.unsupported_operators += 1;
            } else if ((!operandIsPrimitive(g, b, binary.lhs) or !operandIsPrimitive(g, b, binary.rhs)) and
                !supportsBinaryOperator(g, b, binary))
            {
                replaceWithUnsupported(e, reason_operator_requires_primitives);
                stats.unsupported_operators += 1;
            }
        }
    }

    return stats;
}

/// Whether the call's receiver is an array, the one shape a blanket
/// `AsRef<[u8]>` call can be emitted against.
///
/// The backend builds the self type from the bound's element and the
/// receiver's own length (`blanketReceiverType`), so it needs either a
/// receiver already typed as an array or an array literal to count. Anything
/// else is not evidence that this blanket impl applies, and the call keeps
/// whatever reason its own dispatch earns.
fn blanketArrayReceiver(b: *const bodies.Bodies, receiver: exprs.Expr) bool {
    if (receiver.kind == .array) return true;
    const type_id = receiver.ty orelse return false;
    if (type_id >= b.types.len) return false;
    return b.types[type_id] == .array;
}

/// The trait a crate-local blanket `impl<T: AsRef<[u8]>> Trait for T`
/// implements, when that impl declares `method_name`, or null when none does.
///
/// The answer is the TRAIT rather than the method because the trait is what
/// the backend selects the impl from: it reads the trait off the call's
/// `method_ref` (`methodRefTrait`) and finds the impl providing the method
/// from it (`blanketImplFor`). The trait is taken from the impl body's own
/// `trait_path`, the same linkage the backend reads, so the two cannot pick
/// different traits. Two blanket impls providing the same method name the
/// method ambiguously and stay refused.
fn lookupBlanketAsRefBytesTrait(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    method_name: []const u8,
) ?spine.EntityId {
    if (method_name.len == 0) return null;
    var candidate: ?spine.EntityId = null;
    for (g.symbol_table.entities.items) |ent| {
        if (ent.kind != .impl_) continue;
        const parts = parseTraitImplName(ent.name) orelse continue;
        if (!isBlanketAsRefBytesImpl(b, ent.id, parts.type_name)) continue;
        if (!implDeclaresMethod(g, ent.id, method_name)) continue;
        const trait_id = implTraitEntity(b, ent.id) orelse continue;
        if (candidate != null) return null;
        candidate = trait_id;
    }
    return candidate;
}

fn implDeclaresMethod(
    g: *const graph.CrateGraph,
    impl_id: spine.EntityId,
    method_name: []const u8,
) bool {
    for (g.symbol_table.entities.items) |child| {
        if (child.kind != .fn_ or child.parent != impl_id) continue;
        if (std.mem.eql(u8, child.name, method_name)) return true;
    }
    return false;
}

/// The trait entity an impl body implements, read off the body rather than
/// off the impl's name. A macro-generated impl carries the name spelling
/// (`ToHex for T`) and the body carries the resolved `trait_path`, and only
/// the latter names an entity the backend can look the impl up by.
fn implTraitEntity(b: *const bodies.Bodies, impl_id: spine.EntityId) ?spine.EntityId {
    if (impl_id >= b.bodies.len) return null;
    const implementation = switch (b.bodies[impl_id]) {
        .impl_ => |value| value,
        else => return null,
    };
    const path = implementation.trait_path orelse return null;
    if (path.segments.len == 0) return null;
    return path.segments[path.segments.len - 1].id;
}

/// Point a call at the trait whose blanket impl provides it, and report
/// whether the call is now bound.
///
/// The backend hoists a blanket impl's method onto the crate module as a free
/// function, and it finds that function through the trait the call names. The
/// call's own `method_ref` is synthesized per call site and carries only the
/// enclosing scope as its parent, so parenting it to the trait here is what
/// puts the whole chain in reach — and it is the shape `Trait::method(..)`
/// already arrives in, so nothing downstream meets a new one.
///
/// Only a `method_ref` that is still owned by a callable or a module is
/// re-parented. One already owned by this trait is the same binding reached
/// twice — two call sites can share one synthesized reference — and one owned
/// by a DIFFERENT trait, an impl, or a type declaration was bound by a more
/// specific rule, which overwriting would undo.
fn bindBlanketImplMethod(
    g: *const graph.CrateGraph,
    method: exprs.DefId,
    trait_id: spine.EntityId,
) bool {
    if (method >= g.symbol_table.entities.items.len) return false;
    const entity = &@constCast(&g.symbol_table.entities).items[method];
    if (entity.kind != .method_ref) return false;
    if (entity.parent) |owner| {
        if (owner == trait_id) return true;
        const owner_entity = g.symbol_table.get(owner) orelse return false;
        if (owner_entity.kind != .fn_ and owner_entity.kind != .module) return false;
    }
    entity.parent = trait_id;
    return true;
}

/// The reason an operator over an untyped operand carries.
///
/// A method call the resolver DISPATCHED and left in the tree is the one
/// operand whose own refusal is not already there to name the cause: the call
/// was admitted, so nothing on it is marked, and the operator then says only
/// that a type is missing. What is missing is the call's own result type, so
/// that is what the reason says.
///
/// `generate_iter(..).collect::<Vec<_>>() == result` is the shape this is for.
/// `collect` is a runtime iterator method: the resolver admits it on the
/// carrier the opaque recovered, and nothing downstream names what it hands
/// back, so the operator is refused over a CALL that the tree says is fine.
/// Reading the general reason for it buries which half is missing behind a
/// remark about the operator.
///
/// Every other untyped operand keeps the general reason, and the two strings
/// are what they are because a reason outlives this pass: the marker is
/// printed after the graph is gone, so it cannot borrow from the graph.
fn operatorOperandsUnresolvedReason(b: *const bodies.Bodies, binary: exprs.BinaryExpr) []const u8 {
    for ([_]exprs.NodeId{ binary.lhs, binary.rhs }) |node| {
        if (node >= b.exprs.len) continue;
        switch (b.exprs[node].kind) {
            .method_call => return reason_operator_operand_dispatched_call,
            else => {},
        }
    }
    return reason_operator_operands_unresolved;
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
    try std.testing.expectEqual(StdMethod.slice_split_at, lookupStdMethod(slice_ty, "split_at"));
    try std.testing.expectEqual(StdMethod.slice_chunks_exact, lookupStdMethod(slice_ty, "chunks_exact"));

    const ref_slice: types.Type = .{ .reference = &.{ .mut = false, .pointee = slice_ty } };
    try std.testing.expectEqual(StdMethod.slice_is_empty, lookupStdMethod(ref_slice, "is_empty"));

    const chunks_ty: types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "slice", "ChunksExact" },
        .args = &.{.{ .prim = .u8 }},
    } };
    try std.testing.expectEqual(
        StdMethod.chunks_exact_remainder,
        lookupStdMethod(chunks_ty, "remainder"),
    );
    const prim_ty: types.Type = .{ .prim = .u64 };
    try std.testing.expectEqual(StdMethod.num_wrapping_add, lookupStdMethod(prim_ty, "wrapping_add"));
    try std.testing.expectEqual(StdMethod.num_count_ones, lookupStdMethod(prim_ty, "count_ones"));

    try std.testing.expectEqual(StdMethod.clone, lookupStdMethod(prim_ty, "clone"));
    try std.testing.expectEqual(StdMethod.default, lookupStdMethod(prim_ty, "default"));
}

test "canonical iterator methods remain runtime dispatchable" {
    const iter: types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "slice", "Iter" },
        .args = &.{.{ .prim = .u8 }},
    } };
    const iter_ref: types.Type = .{ .reference = &.{ .mut = false, .pointee = iter } };
    const step_by: types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "iter", "StepBy" },
        .args = &.{iter},
    } };
    const zip: types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "iter", "Zip" },
        .args = &.{ iter, iter },
    } };
    const malformed: types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "slice", "Iter" },
        .args = &.{},
    } };

    try std.testing.expect(isRuntimeIteratorMethod(iter_ref, "next"));
    try std.testing.expect(isRuntimeIteratorMethod(iter, "next_back"));
    try std.testing.expect(isRuntimeIteratorMethod(iter, "as_slice"));
    try std.testing.expect(isRuntimeIteratorMethod(step_by, "size_hint"));
    try std.testing.expect(isRuntimeIteratorMethod(zip, "nth"));
    try std.testing.expect(!isRuntimeIteratorMethod(malformed, "next"));
    try std.testing.expect(!isRuntimeIteratorMethod(iter, "not_an_iterator_method"));
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

    const stats = try resolveMethods(&g, &b);

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

    const stats = try resolveMethods(&g, &b);

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

    const stats = try resolveMethods(&g, &b);

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

    const stats = try resolveMethods(&g, &b);

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

    const stats = try resolveMethods(&g, &b);

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
