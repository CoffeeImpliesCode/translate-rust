//! resolve_methods — Method, Trait, Operator and Constructor resolution (P4).
//!
//! After type inference gives concrete receiver types (P3), this pass
//! resolves method calls (`r.m(args)`), constructors (`T::new(...)`),
//! operators (`+`, `*`, `^`, ...), and trait implementations against:
//! 1. Inherent `impl <SelfTy> { fn m }` blocks defined in the crate.
//! 2. Trait `impl <Trait> for <SelfTy>` blocks defined in the crate.
//! 3. Built-in std prelude type methods (`Option`, `Result`, slice/array, numerics).
//! 4. Generic receiver bounds, including source-declared sealed supertraits.
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
    result_err,
    result_unwrap,
    result_unwrap_err,
    /// Rust `Result::expect(msg)`. Returns the Ok arm, so its type is the Ok
    /// type whichever way the error arm lowers.
    result_expect,
    /// Rust `Result::expect_err(msg)`. Returns the Err arm, which a Zig error
    /// union holds as a typed tag and a tagged `r2z.Result` holds as a value —
    /// so unlike `unwrap_err`, both representations admit it.
    result_expect_err,
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
    slice_first,
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
    /// Rust `String::as_bytes`: the same bytes, borrowed.
    string_as_bytes,
    /// Rust `String::len`: the UTF-8 byte length, not a character count.
    string_len,
    format_write_str,
    /// Rust `std::io::Error::kind`: the classification the runtime holds as
    /// `r2z.io.ErrorKind`, returned by value.
    io_error_kind,
    /// Rust `ToString::to_string`. Blanket-implemented for `T: Display`;
    /// see `hasGraphFreeDisplay` and `isBoundStandardMethod`.
    to_string,

    // ── Ownership, borrowing, and the conversions between them ──────────────
    //
    // Every variant here names one std operation whose RESULT is a different
    // owner than its receiver, or whose receiver is a borrowed value that has
    // to produce an owned one. They are grouped because they are one question
    // asked about the `alloc` runtime's three owners: what does this call hand
    // back, and who owns it afterwards.

    /// Rust `str::as_bytes`: the bytes a `&str` already borrows. No copy, and
    /// the borrow keeps pointing at the original string.
    str_as_bytes,
    /// Rust `ToOwned for str`: copies borrowed bytes into a fresh `String`.
    str_to_owned,
    /// Rust `ToOwned for [T]`: copies a borrowed slice into a fresh `Vec<T>`.
    slice_to_owned,
    /// Rust `ToOwned for Cow<'a, B>`: hands back the owned payload — a
    /// `String` for `Cow<str>`, a `Vec<T>` for `Cow<[T]>`. `into_owned` is the
    /// same operation with the receiver consumed, so both answer.
    cow_to_owned,
    /// Rust `Cow::as_bytes`: the borrowed bytes of either representation. A
    /// `Cow<str>` reaches `[]const u8` and a `Cow<[T]>` reaches `[]const T`.
    cow_as_bytes,

    /// Rust `String::push`: appends one code point to an owned string.
    string_push,
    /// Rust `String::push_str`: appends borrowed bytes to an owned string.
    string_push_str,
    /// Rust `String::extend`: appends every item an iterator yields.
    string_extend,
    /// Rust `Vec<T>::push`: appends one element to an owned vector.
    vec_push,
    /// Rust `Vec<T>::extend`: appends every item an iterator yields.
    vec_extend,

    /// Rust `FromUtf8Error::utf8_error`: the validation detail the error
    /// retains after `String::from_utf8` hands the bytes back separately.
    from_utf8_error_utf8_error,
    /// Rust `core::str::Utf8Error::valid_up_to`: the byte length of the valid
    /// UTF-8 prefix, borrowed out of the error's own validation detail.
    ///
    /// It is the same value `FromUtf8Error::utf8_error` hands back, and it is
    /// a separate variant because the two are different receivers: this one
    /// reads the detail through `&self` and gives the backend nothing to take
    /// ownership of, while `utf8_error` moves the payload out of the error
    /// that owns it.
    utf8_error_valid_up_to,

    /// Rust `Into<Cow<'_, B>>` from a value that BORROWS `B`: the same bytes,
    /// tagged `Borrowed`. `&str` into `Cow<str>` and `&[T]` into
    /// `Cow<[T]>` are this, and neither copies.
    into_cow_borrowed,
    /// Rust `Into<Cow<'a, B>>` from a value that OWNS `B`: ownership of the
    /// bytes moves into the `Cow`, tagged `Owned`. `String` into `Cow<str>`
    /// and `Vec<T>` into `Cow<[T]>` are this.
    into_cow_owned,

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

/// What a receiver IS, as distinct from how it is spelled.
///
/// A name is not an identity. siphasher declares `struct Hasher<S>` in `sip`
/// and again in `sip128`, and the `core::hash::Hasher` both of those modules
/// import normalizes to the same three letters, so every lookup that matches
/// on the bare name sees one type where the source wrote three. The declaration
/// the receiver's own type RECORDS is what dispatch reads; the spelling is
/// kept only for a receiver that records none, where it is all there is.
pub const SourceReceiver = struct {
    /// The type declaration this receiver IS, when its type carries one.
    declaration: ?spine.EntityId = null,
    /// That declaration's name, or — for a receiver with no declaration — the
    /// normalized spelling the fallback lookups match on.
    name: []const u8 = "",
};

/// The type declaration a nominal names, when the type RECORDS one.
///
/// A `path` records it on its last segment and a `generic_inst` on its `decl`,
/// so neither is a spelling and neither needs to be re-resolved. An id naming a
/// trait, a function, a module or a local binding is not a type declaration,
/// and is refused here rather than handed to a lookup that would treat any
/// entity as a receiver.
pub fn nominalDeclarationId(g: *const graph.CrateGraph, t: types.Type) ?spine.EntityId {
    const recorded: ?spine.EntityId = switch (t) {
        .path => |path| if (path.segments.len == 0) null else path.segments[path.segments.len - 1].id,
        .generic_inst => |instance| instance.decl,
        else => null,
    };
    const declaration = recorded orelse return null;
    const entity = g.symbol_table.get(declaration) orelse return null;
    return switch (entity.kind) {
        .struct_, .enum_, .union_, .type_alias => declaration,
        else => null,
    };
}

/// The receiver a declared type stands for: its declaration when the type
/// records one, and its normalized spelling otherwise.
///
/// The peel is `unpeelReceiverType`'s, so this asks the same "what does this
/// receiver really name" question every other predicate here asks. A raw
/// pointer peels to nothing `getTypeName` will name, which is the point: it
/// has no declaration of its own to dispatch on.
pub fn declaredReceiver(g: *const graph.CrateGraph, t: types.Type) SourceReceiver {
    const peeled = unpeelReceiverType(t) orelse return .{};
    if (nominalDeclarationId(g, peeled)) |declaration| {
        return receiverForDeclaration(g, declaration) orelse return .{};
    }
    const spelled = getTypeName(g, peeled) orelse return .{};
    return .{ .name = normalizeNominalName(spelled) };
}

/// The receiver one declaration entity stands for, or null when that entity is
/// not one of the kinds a type declaration takes. Both identity-carrying entry
/// points build their answer here, so an entity that names a trait or a
/// function can never become a receiver through one of them.
fn receiverForDeclaration(
    g: *const graph.CrateGraph,
    declaration: spine.EntityId,
) ?SourceReceiver {
    const entity = g.symbol_table.get(declaration) orelse return null;
    return switch (entity.kind) {
        .struct_, .enum_, .union_, .type_alias => .{
            .declaration = declaration,
            .name = entity.name,
        },
        else => null,
    };
}

/// The receiver a bare spelling stands for: no declaration, because a
/// normalized name is exactly the thing that cannot stand for one.
fn spelledReceiver(type_name: ?[]const u8) ?SourceReceiver {
    const named = type_name orelse return null;
    const normalized = normalizeNominalName(named);
    if (normalized.len == 0) return null;
    return .{ .name = normalized };
}

/// The receiver an impl block's own NAME declares, as a spelling. `null` for a
/// blanket impl, which names no receiver at all.
fn implNameReceiverText(name: []const u8) ?[]const u8 {
    if (parseTraitImplName(name)) |parts| return parts.type_name;
    return name;
}

/// Whether an impl block declares its methods FOR `receiver`.
///
/// A receiver that records its declaration is matched by DECLARATION, read
/// from the impl's own `self_ty`. An impl whose self type names a different
/// declaration is a different type that happens to share a spelling, and
/// admitting it is exactly what makes two private modules look ambiguous — or,
/// worse, binds one module's call to the other's method.
///
/// The declaration decides only when BOTH sides have one. A receiver that
/// records none — the impl's own name is all a method call on an associated
/// function or on a returned value carries — is decided by spelling, as is an
/// impl that records none either way: no body in this graph, or a blanket impl
/// over a type parameter. Every such match is counted, so two of them stay a
/// refusal rather than a silent first match.
fn implProvidesFor(
    g: *const graph.CrateGraph,
    b: ?*const bodies.Bodies,
    ent: spine.Entity,
    receiver: SourceReceiver,
) bool {
    const spelled = implNameReceiverText(ent.name) orelse return false;
    if (b) |table| {
        if (ent.id < table.bodies.len) {
            if (table.bodies[ent.id] == .impl_) {
                const self_declaration = nominalDeclarationId(g, table.bodies[ent.id].impl_.self_ty);
                if (self_declaration) |declared| {
                    if (receiver.declaration) |wanted| return declared == wanted;
                }
            }
        }
    }
    return nominalNamesEqual(spelled, receiver.name);
}

fn lookupTraitMethodCandidates(
    g: *const graph.CrateGraph,
    b: ?*const bodies.Bodies,
    receiver: SourceReceiver,
    method_name: []const u8,
    trait_name: ?[]const u8,
) TraitMethodLookup {
    var lookup: TraitMethodLookup = .{};
    if (method_name.len == 0) return lookup;
    if (receiver.declaration == null and receiver.name.len == 0) return lookup;

    for (g.symbol_table.entities.items) |ent| {
        if (ent.kind != .impl_) continue;
        const parts = parseTraitImplName(ent.name) orelse continue;
        if (trait_name) |wanted_trait| {
            if (!nominalNamesEqual(parts.trait_name, wanted_trait)) continue;
        }
        if (!implProvidesFor(g, b, ent, receiver)) continue;

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
    return lookupInherentMethodFor(g, null, .{ .name = type_name }, method_name);
}

/// The one inherent method `receiver`'s own declaration provides, or null.
///
/// Two inherent impls of ONE type declaring one method is the duplicate
/// definition rustc rejects, so there is no right answer to pick: returning
/// the first is how one module's `self.short_write(..)` reached the other
/// module's body without a marker anywhere.
pub fn lookupInherentMethodFor(
    g: *const graph.CrateGraph,
    b: ?*const bodies.Bodies,
    receiver: SourceReceiver,
    method_name: []const u8,
) ?spine.EntityId {
    if (method_name.len == 0) return null;
    if (receiver.declaration == null and receiver.name.len == 0) return null;

    var found: ?spine.EntityId = null;
    for (g.symbol_table.entities.items) |ent| {
        if (ent.kind != .impl_) continue;
        if (parseTraitImplName(ent.name) != null) continue;
        if (!implProvidesFor(g, b, ent, receiver)) continue;
        for (g.symbol_table.entities.items) |child| {
            if (child.kind == .fn_ and child.parent == ent.id and
                std.mem.eql(u8, child.name, method_name))
            {
                if (found != null) return null;
                found = child.id;
            }
        }
    }
    return found;
}

/// Source dispatch identity shared by inference and final method resolution.
/// Ambiguity is distinct from absence: callers must not fall back to a
/// standard method when competing source traits declare the same method.
pub const SourceMethodLookup = union(enum) {
    inherent: spine.EntityId,
    trait_: spine.EntityId,
    ambiguous,
    missing,
};

/// The method this crate declares for a receiver named only by its spelling,
/// or the reason there is none to name. A receiver that records a declaration
/// is dispatched by `lookupSourceMethodFor`, which is the same decision with
/// the identity the type carries.
pub fn lookupSourceMethod(
    g: *const graph.CrateGraph,
    type_name: []const u8,
    method_name: []const u8,
) SourceMethodLookup {
    return lookupSourceMethodFor(g, null, .{ .name = type_name }, method_name);
}

/// The method this crate declares for `receiver`, or the reason there is none
/// to name.
///
/// An inherent impl names its receiver as the impl ITSELF: `impl Source` is
/// this crate declaring that `Source` has inherent methods, so a receiver that
/// reads `Source` is reading that same declaration rather than guessing at
/// one. A trait impl has no such entity — its receiver lives inside a longer
/// name, `impl Default for Bar` — and what that receiver is comes from the
/// impl's own `self_ty`, never from a parser's split of the text. A receiver
/// this crate never declares therefore has nothing behind the name, and
/// answering with the impl would bind the call to a type no declaration here
/// stands for. That is the same rule `structBodyForNominal` applies before it
/// hands a receiver a field list: a declaration, never a spelling.
///
/// A blanket impl is the case that declares no receiver and still answers,
/// because `impl<T: Bound> Trait for T` does not name a type at all — it names
/// a variable. It reaches the receiver through its bound instead, in
/// `boundTraitMethod`, and never through this lookup.
pub fn lookupSourceMethodFor(
    g: *const graph.CrateGraph,
    b: ?*const bodies.Bodies,
    receiver: SourceReceiver,
    method_name: []const u8,
) SourceMethodLookup {
    if (lookupInherentMethodFor(g, b, receiver, method_name)) |method| {
        return .{ .inherent = method };
    }
    // A recorded declaration has already cleared this gate: `nominalDeclarationId`
    // answers only for a struct, enum, union or alias. Only a spelling has to
    // be proved against the crate's own type declarations.
    if (receiver.declaration == null and !declaresNominalType(g, receiver.name)) return .missing;
    const traits = lookupTraitMethodCandidates(g, b, receiver, method_name, null);
    if (traits.count > 1) return .ambiguous;
    if (traits.candidate) |method| return .{ .trait_ = method };
    return .missing;
}

/// Whether this crate declares a type under `type_name`. Only the kinds a
/// type declaration takes count: a struct, an enum, a union, or a type alias.
/// A function, a constant or a module is not a type, and neither is a trait,
/// so an impl that names one of those as its receiver is not an impl over a
/// type this dispatch can stand on.
///
/// A PRIMITIVE is the one receiver this crate never declares and still stands
/// on. `impl Label for u64` names its self type outright, and a receiver
/// typed `u64` is that same type, so requiring a declaration here would
/// refuse every impl a crate writes over a primitive — with no name to bind
/// and nothing downstream able to recover one. The gate above is about a
/// name that EXISTS and is the wrong kind of thing; a primitive is the
/// language naming a type, which is a different case.
fn declaresNominalType(g: *const graph.CrateGraph, type_name: []const u8) bool {
    const name = normalizeNominalName(type_name);
    if (name.len == 0) return false;
    if (isPrimitiveTypeName(name)) return true;
    for (g.symbol_table.entities.items) |entity| {
        switch (entity.kind) {
            .struct_, .enum_, .union_, .type_alias => {},
            else => continue,
        }
        if (nominalNamesEqual(entity.name, type_name)) return true;
    }
    return false;
}

/// Whether `name` is a primitive the language itself spells. The spellings
/// come from `types.Prim` rather than from a second list written here, so
/// they cannot drift from the names a receiver of that type actually reports.
fn isPrimitiveTypeName(name: []const u8) bool {
    inline for (std.enums.values(types.Prim)) |primitive| {
        if (std.mem.eql(u8, name, @tagName(primitive))) return true;
    }
    return false;
}

/// Lookup a trait method `impl <trait_name> for <type_name> { fn <method_name> }`.
/// Returns the EntityId if a single candidate is found, or null on ambiguity/missing.
pub fn lookupTraitMethod(
    g: *const graph.CrateGraph,
    trait_name: []const u8,
    type_name: []const u8,
    method_name: []const u8,
) ?spine.EntityId {
    return lookupTraitMethodFor(g, null, trait_name, .{ .name = type_name }, method_name);
}

/// `lookupTraitMethod` for a receiver that may record its own declaration, so
/// two same-named types in two modules never answer for each other.
pub fn lookupTraitMethodFor(
    g: *const graph.CrateGraph,
    b: ?*const bodies.Bodies,
    trait_name: []const u8,
    receiver: SourceReceiver,
    method_name: []const u8,
) ?spine.EntityId {
    if (trait_name.len == 0 or method_name.len == 0) return null;
    if (receiver.declaration == null and receiver.name.len == 0) return null;

    const lookup = lookupTraitMethodCandidates(g, b, receiver, method_name, trait_name);
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
/// Not every predicate peels. The blanket receiver gate asks for the bare
/// type parameter path itself, because the backend's `blanketReceiverType`
/// does not peel either: it builds a self type for an array or for a bare
/// one-segment path and builds none for a carrier, so peeling there would
/// admit a receiver whose call lowers to a member call on a slice.
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

/// An exact `std::io` path, all three segments and no generic arguments.
///
/// A basename is not the test. A crate that declares its own `io::ErrorKind`
/// is not this one, and neither is a std `io` type this runtime has no name
/// for, so every reader that asks "is this the io type the runtime holds"
/// asks it here rather than answering from the leaf alone.
fn isExactStdIoType(external: types.ExternalNominal, leaf: []const u8) bool {
    return external.args.len == 0 and external.path.len == 3 and
        std.mem.eql(u8, external.path[0], "std") and
        std.mem.eql(u8, external.path[1], "io") and
        std.mem.eql(u8, external.path[2], leaf);
}

/// Whether `external` is exactly `core::str::Utf8Error` (or the `std` spelling
/// of the same type), with no generic arguments.
///
/// Full path, for the reason `isExactStdIoType` gives: `Utf8Error` is a name a
/// crate can declare for something else entirely, and only the whole `str`
/// module path says this is the validation detail the runtime holds.
fn isExactStdStrUtf8Error(external: types.ExternalNominal) bool {
    return external.args.len == 0 and external.path.len == 3 and
        (std.mem.eql(u8, external.path[0], "core") or
            std.mem.eql(u8, external.path[0], "std")) and
        std.mem.eql(u8, external.path[1], "str") and
        std.mem.eql(u8, external.path[2], "Utf8Error");
}

/// Whether `external` is exactly the `alloc` (or `std`) nominal the runtime
/// owns, with the argument count its own std declaration fixes.
///
/// The whole path and the arity are the test, for the reason
/// `isExactStdIoType` gives. A crate's own `Vec` is not `alloc::vec::Vec`, a
/// `Cow<str>` is not a `Cow<[u8]>`, and a bare `Cow` with no payload names
/// nothing the runtime can build — so a reader that answered from the leaf
/// alone would hand the backend a receiver it has no arm for.
fn isExactAllocNominal(
    external: types.ExternalNominal,
    module: []const u8,
    name: []const u8,
    arg_count: usize,
) bool {
    return external.args.len == arg_count and external.path.len == 3 and
        (std.mem.eql(u8, external.path[0], "alloc") or
            std.mem.eql(u8, external.path[0], "std")) and
        std.mem.eql(u8, external.path[1], module) and
        std.mem.eql(u8, external.path[2], name);
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
            if (std.mem.eql(u8, method_name, "err")) return .result_err;
            if (std.mem.eql(u8, method_name, "unwrap")) return .result_unwrap;
            // `unwrap_err` is NOT decided here: whether a `Result` receiver
            // has an error VALUE to hand back depends on how it lowers, not
            // on its type, and that is `lookupResultRepresentationMethod`'s
            // one question.
            // `expect` and `expect_err` ARE decided here, and both `Result`
            // representations answer the same way. `expect` returns the Ok arm
            // and reads no error value. `expect_err` returns the Err arm, which
            // a Zig error union holds as a typed tag and a tagged `r2z.Result`
            // holds as a value — so unlike `unwrap_err`, neither form leaves it
            // with nothing to hand back.
            if (std.mem.eql(u8, method_name, "expect")) return .result_expect;
            if (std.mem.eql(u8, method_name, "expect_err")) return .result_expect_err;
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
            if (std.mem.eql(u8, method_name, "first")) return .slice_first;
            if (std.mem.eql(u8, method_name, "chunks")) return .slice_chunks;
            if (std.mem.eql(u8, method_name, "copy_from_slice")) return .slice_copy_from_slice;
            // `impl<T: Clone> ToOwned for [T] { type Owned = Vec<T> }` is a
            // specialization for the UNSIZED slice only. An array is `Clone` in
            // its own right — `impl<T: Clone, const N: usize> Clone for [T; N]`
            // — so the blanket `impl<T: Clone> ToOwned for T { type Owned = T }`
            // is what applies to it and `[T; N].to_owned()` is a clone of the
            // same array, not a `Vec<T>`. `str` never reaches this arm at all:
            // it is a distinct unsized primitive whose `Owned` is a `String`,
            // and `&str` carries no slice this arm could read an element from.
            if (std.mem.eql(u8, method_name, "to_owned")) {
                if (cur_t == .array) return .clone;
                return .slice_to_owned;
            }
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
                if (std.mem.eql(u8, method_name, "ok")) return .result_ok;
                if (std.mem.eql(u8, method_name, "err")) return .result_err;
                if (std.mem.eql(u8, method_name, "unwrap")) return .result_unwrap;
                if (std.mem.eql(u8, method_name, "unwrap_err")) return .result_unwrap_err;
                if (std.mem.eql(u8, method_name, "expect")) return .result_expect;
                if (std.mem.eql(u8, method_name, "expect_err")) return .result_expect_err;
                if (std.mem.eql(u8, method_name, "unwrap_or")) return .result_unwrap_or;
                if (std.mem.eql(u8, method_name, "map")) return .result_map;
                if (std.mem.eql(u8, method_name, "map_err")) return .result_map_err;
                if (std.mem.eql(u8, method_name, "as_ref")) return .result_as_ref;
            }
            // `String` is the one Rust owner whose runtime type is a distinct
            // Zig type (`r2z.alloc.String`) rather than a plain list, so its
            // methods are the ones that read or grow the bytes it owns:
            // `into_bytes` hands the backing `Vec(u8)` over and leaves the
            // string empty, `as_bytes` borrows those same bytes, `len` counts
            // them, and `push`/`push_str`/`extend` append to them. A `&str`, a
            // `Vec<u8>`, and a slice borrow each reach a different runtime type,
            // so all of them stay refused here.
            if (isExactAllocNominal(external, "string", "String", 0)) {
                if (std.mem.eql(u8, method_name, "into_bytes")) return .string_into_bytes;
                if (std.mem.eql(u8, method_name, "as_bytes")) return .string_as_bytes;
                if (std.mem.eql(u8, method_name, "len")) return .string_len;
                if (std.mem.eql(u8, method_name, "push")) return .string_push;
                if (std.mem.eql(u8, method_name, "push_str")) return .string_push_str;
                if (std.mem.eql(u8, method_name, "extend")) return .string_extend;
                // `ToOwned` is blanket-implemented for every `T: Clone` with
                // `Owned = T`, so a `String` asked for its own `to_owned` is
                // handed itself. The operation IS the clone this table already
                // names, and admitting it as anything else would claim the
                // call produces a different owner.
                if (std.mem.eql(u8, method_name, "to_owned")) return .clone;
            }
            // `str` is the unsized primitive `&str` borrows, and it is the
            // runtime's `[]const u8` rather than a `r2z.alloc.String`, so
            // `as_bytes` on it is not the owned string's and not the byte
            // slice's: it hands back the very same borrowed bytes. `to_owned`
            // is the other half of that borrow — the copy that ends it, and a
            // `String` rather than the `Vec<u8>` the slice's own `to_owned`
            // produces, because `impl ToOwned for str` names `String` and
            // `impl ToOwned for [T]` names `Vec<T>`.
            //
            // `len` and `is_empty` count the same bytes either spelling does,
            // and both are genuine `str` methods, so a borrowed string keeps
            // them now that it is not a slice here.
            if (types.isStr(.{ .external_nominal = external })) {
                if (std.mem.eql(u8, method_name, "as_bytes")) return .str_as_bytes;
                if (std.mem.eql(u8, method_name, "to_owned")) return .str_to_owned;
                if (std.mem.eql(u8, method_name, "len")) return .slice_len;
                if (std.mem.eql(u8, method_name, "is_empty")) return .slice_is_empty;
            }
            // A `Vec<T>` reads its element type off its own nominal, so both
            // growing methods are admitted for every element and the backend
            // appends whichever one the argument carries.
            if (isExactAllocNominal(external, "vec", "Vec", 1)) {
                if (std.mem.eql(u8, method_name, "iter")) return .slice_iter;
                if (std.mem.eql(u8, method_name, "iter_mut")) return .slice_iter_mut;
                if (std.mem.eql(u8, method_name, "push")) return .vec_push;
                if (std.mem.eql(u8, method_name, "extend")) return .vec_extend;
                // `len` counts the same elements `push` appends, and the
                // runtime holds them in the storage a slice is read out of, so
                // this is the slice length over that storage rather than a
                // second operation with a second answer. Naming `slice_len`
                // is what lets the backend lower it through the projection it
                // already has, and it is the same answer `str` and a slice
                // give for the same question.
                if (std.mem.eql(u8, method_name, "len")) return .slice_len;
                // Same blanket `ToOwned` as the string's, for the same reason.
                if (std.mem.eql(u8, method_name, "to_owned")) return .clone;
            }
            // A `Cow` is already the runtime's explicit-ownership union, so
            // `as_bytes` reads whichever representation the value holds, and
            // only `into_owned` trades the borrow for the owned payload it was
            // guarding.
            //
            // `to_owned` is a DIFFERENT operation and is deliberately not this
            // one. `impl<T: Clone> ToOwned for T { type Owned = T }` is the
            // blanket every `Clone` type takes, and a `Cow` is `Clone`, so
            // `to_owned` hands back a CLONE of the same `Cow` through `&self`
            // — the receiver is still usable afterwards. `into_owned` is the
            // consuming half: it moves and yields `B::Owned`. Answering both
            // names with the consuming variant would move a value Rust only
            // borrowed, so a later use of the receiver would read a moved
            // value.
            if (isExactAllocNominal(external, "borrow", "Cow", 1)) {
                if (std.mem.eql(u8, method_name, "as_bytes")) return .cow_as_bytes;
                if (std.mem.eql(u8, method_name, "into_owned")) return .cow_to_owned;
                if (std.mem.eql(u8, method_name, "to_owned")) return .clone;
            }
            // `FromUtf8Error` is what `String::from_utf8` hands back when the
            // bytes are not UTF-8. It owns the bytes AND retains why they
            // failed, and `utf8_error` is the half that says why — the same
            // `core::str::Utf8Error` a direct `str::from_utf8` produces.
            if (isExactAllocNominal(external, "string", "FromUtf8Error", 0) and
                std.mem.eql(u8, method_name, "utf8_error")) return .from_utf8_error_utf8_error;
            // `core::str::Utf8Error` is the detail a direct `str::from_utf8`
            // reports, and it is what `FromUtf8Error::utf8_error` above hands
            // back. `valid_up_to` reads the length of the valid prefix through
            // `&self`, so it borrows and gives the backend nothing to take.
            // The whole path is the test for the same reason `FromUtf8Error`
            // is: a crate that declares its own `Utf8Error` names a different
            // type, and answering from the leaf alone would claim its method.
            if (isExactStdStrUtf8Error(external) and
                std.mem.eql(u8, method_name, "valid_up_to")) return .utf8_error_valid_up_to;
            // `std::io::Error::kind` is the one std `io` method the runtime
            // owns end to end: the receiver is `r2z.io.Error`, and what it
            // hands back is `r2z.io.ErrorKind`, a payload-free enum compared by
            // value. The path is matched in full, so a crate's own `io::Error`
            // and every other std `io` nominal stay out.
            if (isExactStdIoType(external, "Error") and
                std.mem.eql(u8, method_name, "kind")) return .io_error_kind;
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
        // A raw pointer is NOT the type it points at. Every reader here asks
        // which DECLARED type a value has so it can reach THAT type's own
        // impl, and `*const Foo` has none: core's `PartialOrd for *const T`
        // compares the two POINTERS, so `a < b` over `*const Foo` is not the
        // `PartialOrd for Foo` this would answer with. Peeling here is what
        // let a pointer's operator, or its method call, dispatch to the
        // pointee's declaration. Rust reaches a pointee by dereferencing, and
        // a dereference is an EXPRESSION whose own type is the pointee, so a
        // `*p` still names `Foo` without this pretending `p` already does.
        .raw_ptr => return null,
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
            .vec_lit => |vec| {
                for (vec.elements) |element| self.visitExpr(element, depth + 1);
                // `vec![elem; count]` evaluates the element once and the
                // count once, in that order. A `.literal` count is a number
                // this pass already holds and has no node to visit; a
                // `.expression` count is a real child that can bind a local,
                // so it is visited at the same depth as the element.
                if (vec.repeat) |repeat| switch (repeat) {
                    .literal => {},
                    .expression => |count| self.visitExpr(count, depth + 1),
                };
            },
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
        .len = .{ .literal = array_expr.repeat orelse
            @as(u64, @intCast(array_expr.elements.len)) },
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
        // `self.field` is a value of the field's own declared type, and the
        // struct that declares it is one declaration walk away from the base.
        // That projection is what a canonical `std` method over a FIELD
        // receiver is decided from: `self.tail.to_le_bytes()` inside
        // `impl Hasher for SeaHasher` has a `u64` in the declaration the base
        // names and nothing else to read it from.
        .field => |field| fieldReceiverDeclaredType(g, b, field, depth),
        else => null,
    };
}

/// The declared type of a field read off a receiver that inference left
/// untyped, taken from the declaration the base names.
///
/// It answers a DECLARATION, never a guess. A tuple base answers from its own
/// element list at the position the source wrote; a nominal base answers from
/// the struct that base names — through its recorded declaration when it has
/// one — and only when that struct declares the field. Anything else leaves
/// the field untyped, which is what keeps a receiver this pass cannot name
/// refused rather than filled with a type that belongs to something else.
fn fieldReceiverDeclaredType(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    field: exprs.FieldExpr,
    depth: usize,
) ?types.Type {
    const base = receiverDeclaredTypeAt(g, b, field.base, depth + 1) orelse return null;
    // A tuple and a tuple struct are both addressed POSITIONALLY, and Rust has
    // no identifier that is all digits, so an all-digit field name is
    // unambiguously a position: `entry.0` over a `&(String, u8)` and `self.0`
    // over a `struct Lane(u64)` are the same question.
    const ordinal = std.fmt.parseInt(usize, field.field, 10) catch null;
    const named = unpeelReceiverType(base) orelse return null;
    switch (named) {
        .tuple => |elements| {
            const position = ordinal orelse return null;
            if (position >= elements.len) return null;
            return elements[position];
        },
        // A `generic_inst` is a declaration too: `Hasher<Sip13Rounds>` names
        // exactly the struct `Hasher` names, and refusing it is what made
        // `self.hasher.k0` unreadable — the one hop where the receiver is an
        // instantiation rather than a bare path.
        .path, .generic_inst => {
            const structure = structBodyForNominal(g, b, named) orelse return null;
            for (structure.fields) |declared| {
                if (std.mem.eql(u8, declared.name, field.field)) return declared.ty;
            }
            const position = ordinal orelse return null;
            if (structure.layout != .tuple or position >= structure.fields.len) return null;
            return structure.fields[position].ty;
        },
        else => return null,
    }
}

/// The struct body a nominal base names.
///
/// A base that RECORDS its declaration is read through that entity, which is
/// the whole point: `sip::Hasher` and `sip128::Hasher` are one name over two
/// layouts, and a field walk that cannot tell them apart hands the caller the
/// other module's fields. A base that records none is read by name, and only
/// when exactly one struct in the crate answers to it.
fn structBodyForNominal(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    nominal: types.Type,
) ?bodies.StructBody {
    if (nominalDeclarationId(g, nominal)) |declaration| {
        if (declaration >= b.bodies.len) return null;
        return switch (b.bodies[declaration]) {
            .struct_ => |structure| structure,
            else => null,
        };
    }
    const path = switch (nominal) {
        .path => |value| value,
        else => return null,
    };
    if (path.segments.len != 1) return null;
    return structBodyForUniqueName(g, b, path.segments[0].name);
}

/// The body of the one struct in this crate that a nominal name declares.
///
/// Two declarations under one name are two different layouts, and picking
/// either would hand a receiver a field list that is not its own, so an
/// ambiguous name answers nothing.
fn structBodyForUniqueName(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    type_name: []const u8,
) ?bodies.StructBody {
    var found: ?bodies.StructBody = null;
    for (g.symbol_table.entities.items) |entity| {
        if (entity.kind != .struct_) continue;
        if (!nominalNamesEqual(entity.name, type_name)) continue;
        if (found != null) return null;
        if (entity.id >= b.bodies.len) continue;
        switch (b.bodies[entity.id]) {
            .struct_ => |structure| found = structure,
            else => continue,
        }
    }
    return found;
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

/// The receiver a node dispatches on: its own declaration when its declared
/// type records one, and its spelling otherwise. `null` means nothing at all
/// can be named, which is a different answer from a name that matches no
/// declaration.
///
/// `receiver_ty` is the receiver's declared type, passed in rather than
/// derived here: every caller has already recovered it for the dispatch it is
/// about to make, and re-walking the receiver's expression chain to ask the
/// same question a second time is work for a value the caller holds.
fn receiverSource(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    receiver_node: exprs.NodeId,
    receiver_ty: ?types.Type,
) ?SourceReceiver {
    if (receiver_node >= b.exprs.len) return null;
    const receiver = b.exprs[receiver_node];

    // A value whose own declared type is a raw pointer names no nominal type
    // in this crate's graph, and every fallback below would answer with the
    // POINTEE's: an operator resolved against a pointee's `Add`, a method
    // dispatched to a pointee's impl. Both are a different call over a
    // different value, so the pointer answers none of them here. What a
    // pointer DOES own — `add`, `offset`, `read_unaligned` — is decided from
    // the receiver's type itself, on the arm that does not need a name.
    if (receiver_ty) |ty| {
        if (rawPointerType(g, b, ty) != null) return null;
    }

    // The path's resolved EntityId is the local binding identity. Use its
    // declaration/inferred type directly; never infer a type from spelling.
    if (receiver_ty) |ty| {
        const declared = declaredReceiver(g, ty);
        if (declared.declaration != null or declared.name.len > 0) return declared;
    }

    if (receiver.kind == .path) {
        // The linkage below is the INITIALIZER's owner, so a local that is
        // itself a pointer must not take it either: `let p = Foo::raw();` is a
        // `*const T` whose nominal is nothing, not a `Foo`. The initializer's
        // own declared return type says which case this is, and it is read on
        // the same node the linkage below reads.
        if (initializerReturnType(g, b, receiver.kind.path)) |ty| {
            if (rawPointerType(g, b, ty) != null) return null;
        }
        // A local initializer can carry the only available nominal linkage
        // when inference has not materialized a TypeId. Follow that exact
        // associated-call EntityId; never infer from the local's spelling.
        if (initializerNominalName(g, b, receiver.kind.path)) |type_name| {
            const nominal_name = normalizeNominalName(type_name);
            if (nominal_name.len > 0) return .{ .name = nominal_name };
        }
    }

    const receiver_source: ?SourceReceiver = switch (receiver.kind) {
        .call => |call| switch (call.call_kind) {
            .associated => |target| spelledReceiver(inherentImplTypeName(g, target)),
            else => null,
        },
        .method_call => |method| spelledReceiver(inherentImplTypeName(g, method.method)),
        // `FromHexError::OddLength` is a `FromHexError`. A variant node names
        // the enum that owns it, so the receiver's type is recoverable even
        // when inference left the node untyped — and by the OWNING entity,
        // which is the identity the call dispatches on.
        .enum_variant => |variant| receiverForDeclaration(
            g,
            enumVariantOwner(g, variant.def) orelse return null,
        ),
        else => null,
    };
    const named = receiver_source orelse return null;
    if (named.declaration != null or named.name.len > 0) return named;
    return null;
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

    // A `const` — and a `static`, which the body model spells the same way —
    // declares its own type beside its name. A top-level constant is parented
    // to the module rather than to a function, so the parameter walk below
    // never reaches it and the whole function gives up first. `infer`'s
    // `getKnownType` already reads this same slot without that detour, and
    // reading it here is what makes `CONTROL.contains(0)` a name lookup
    // instead of a refusal.
    if (path.def < b.bodies.len) {
        switch (b.bodies[path.def]) {
            .const_ => |constant| return constant.ty,
            else => {},
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
        // Match the resolved-type gate for source calls as well: the
        // callee's declaration, not the missing inference pin, names its value.
        .call => |call| isScalarOperandType(g, b, callDeclaredReturnType(g, b, call) orelse return false),
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

/// The retained slice-iterator shape a method call's receiver has.
///
/// `slice.iter()` is a receiver the Zig backend lowers to the runtime's own
/// `r2z.SliceIter`, so a method over it lands on a real runtime iterator.
/// `slice.iter().cloned()` keeps the borrow-erasing call itself in the tree
/// instead, and that call has no runtime value: the backend reaches no
/// `cloned` member on the iterator it would hand back, so a method over
/// THIS shape is a call it cannot satisfy whatever the name is. The two
/// shapes therefore admit different names.
const RetainedIteratorProjection = enum {
    slice_iterator,
    cloned_projection,
};

fn retainedIteratorProjection(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    receiver_node: exprs.NodeId,
) ?RetainedIteratorProjection {
    var projection_node = receiver_node;
    var crossed_cloned = false;
    var depth: usize = 0;
    while (depth < b.exprs.len) : (depth += 1) {
        if (projection_node >= b.exprs.len) return null;
        const method_call = switch (b.exprs[projection_node].kind) {
            .method_call => |value| value,
            else => return null,
        };
        const method = g.symbol_table.get(method_call.method) orelse return null;
        if (std.mem.eql(u8, method.name, "iter") or
            std.mem.eql(u8, method.name, "iter_mut"))
        {
            if (method_call.receiver >= b.exprs.len) return null;
            const receiver = b.exprs[method_call.receiver];
            const receiver_ty = if (receiver.ty) |type_id|
                if (type_id < b.types.len) b.types[type_id] else null
            else if (receiver.kind == .path)
                pathDeclaredType(g, b, receiver.kind.path)
            else
                null;
            const std_method = lookupStdMethod(receiver_ty orelse return null, method.name) orelse return null;
            if (std_method != .slice_iter and std_method != .slice_iter_mut) return null;
            return if (crossed_cloned) .cloned_projection else .slice_iterator;
        }
        if (!std.mem.eql(u8, method.name, "cloned")) return null;
        crossed_cloned = true;
        projection_node = method_call.receiver;
    }
    return null;
}

/// The method names the runtime drives over a retained slice iterator.
///
/// `cloned` erases the borrow the iterator hands out, and `rev` wraps it in
/// the `core::iter::Rev` carrier the runtime already has as `r2z.Rev`. Both
/// stay ordinary calls over the receiver this pass kept in the tree, so
/// neither needs the backend to resolve a carrier of its own before it can
/// lower them. Any other name over this receiver shape has no such arm, which
/// is why the admission is this list and not the receiver's whole method set.
fn isRetainedIteratorProjectionMethod(
    projection: RetainedIteratorProjection,
    method_name: []const u8,
) bool {
    // Copied retains this canonical slice projection in IR so its value Item
    // mode survives extraction. It is not a copied stage over a cloned source.
    if (projection == .slice_iterator and std.mem.eql(u8, method_name, "copied")) {
        return true;
    }
    if (std.mem.eql(u8, method_name, "cloned") or
        std.mem.eql(u8, method_name, "rev"))
    {
        return true;
    }
    return projection == .slice_iterator and
        isRetainedSliceIteratorMemberMethod(method_name);
}

/// The names a BARE `slice.iter()` receiver adds to that list.
///
/// Such a receiver lowers to `r2z.sliceIter(T, xs)`, and `len` and `clone`
/// are the two members of `r2z.SliceIter`/`r2z.SliceIterMut` that a method
/// call on that value reaches: both take `self: *const Self`, and Zig binds
/// a `*const` receiver from a temporary. `next`, `next_back` and `nth` take
/// `self: *Self` and do not compile on one — the backend has to bind the
/// iterator to a local first, exactly as its `for` hoisting does — so they
/// stay refused. Nothing else belongs here either: `count`, `last`,
/// `position` and `rev` name no member at all, the backend answers
/// `as_slice` with the receiver itself rather than a call to it, and
/// `size_hint` returns a two-field struct where Rust has a `Range`.
fn isRetainedSliceIteratorMemberMethod(method_name: []const u8) bool {
    return std.mem.eql(u8, method_name, "len") or
        std.mem.eql(u8, method_name, "clone");
}

/// The `std::io` trait methods the runtime owns end to end, each with the one
/// trait that declares it.
///
/// A trait method with no entity of its own has to be recognized by the trait
/// that declares it, so the pair is the whole fact: `read_exact` is `Read`'s,
/// `write_all` is `Write`'s, and `fill_buf`/`consume` are `BufRead`'s. Rust
/// declares `fill_buf` on `BufRead` and not on `Read`, so a receiver bounded
/// only by `Read` is not one this answers — which is exactly the distinction a
/// name-keyed rule would lose, and the reason `stdIoWriteMethodAllocates`
/// below asks this same table rather than a name of its own.
///
/// `BufRead: Read` is the supertrait relation, so a receiver bounded by
/// `BufRead` also carries `read_exact`. That direction is not walked here: a
/// source that declares only `BufRead` and calls `read_exact` is one the
/// frontend cannot prove from the declaration alone, so it keeps its own
/// refusal rather than being answered from a bound that was never written.
const RuntimeIoMethod = struct { name: []const u8, trait_path: []const []const u8 };

const runtime_io_methods = [_]RuntimeIoMethod{
    .{ .name = "read_exact", .trait_path = &.{ "std", "io", "Read" } },
    .{ .name = "write_all", .trait_path = &.{ "std", "io", "Write" } },
    // `pub trait BufRead { fn fill_buf(&mut self) -> Result<&[u8]>; fn consume(&mut self, amt: usize); }`
    // — both borrowed through `&mut self`, and `fill_buf` returns the same
    // `io::Result` every other fallible `io` method returns.
    .{ .name = "fill_buf", .trait_path = &.{ "std", "io", "BufRead" } },
    .{ .name = "consume", .trait_path = &.{ "std", "io", "BufRead" } },
};

/// Whether `name` is one of the `std::io` methods the runtime owns end to
/// end, called on a receiver that is proven to implement the trait that
/// declares it.
///
/// The proof is `bodies.genericBound`, which is what keeps a crate's own
/// `Read` from standing in for `std::io::Read`. Where it is asked from differs
/// by receiver, because the two shapes keep their bounds in different places:
///
/// - `fn f<R: ?Sized + io::Read>(r: &mut R)` and `fn f(w: &mut dyn Write)`.
///   The bound is on the signature, so the `fn` is the scope that declares it
///   and either the method's own parent or the receiver expression's owner
///   names that scope.
/// - `fn f(w: &mut impl Write)`. The bound is on the `impl Trait` itself, so
///   the only thing the method's parent adds is noise; the receiver's own
///   scope answers it.
///
/// A std trait method has no entity in the crate graph, so `method_id` names
/// nothing here and the receiver's own scope is the only scope available. That
/// is why the second lookup is not merely a fallback: for `&mut dyn Read` it is
/// the arm that resolves.
fn isRuntimeIoMethod(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    receiver_node: exprs.NodeId,
    method_id: exprs.DefId,
    receiver: types.Type,
    name: []const u8,
) bool {
    // One std trait method, one std trait it hangs from, so the identity
    // question is always the same one and it is asked against the receiver's
    // DECLARED bound rather than the method's name.
    const io_trait: []const []const u8 = for (runtime_io_methods) |entry| {
        if (std.mem.eql(u8, entry.name, name)) break entry.trait_path;
    } else return false;
    if (g.symbol_table.get(method_id)) |method| {
        if (method.parent) |owner| {
            if (bodies.genericBound(g, b, owner, receiver, io_trait) != null) return true;
        }
    }
    const owner = expressionOwner(g, b, receiver_node, 0) orelse return false;
    return bodies.genericBound(g, b, owner, receiver, io_trait) != null;
}

/// Whether the expression at `node` is the general `std::io::Write::write_all`
/// the runtime lowers through an explicit allocator.
///
/// The `read_exact`/`write_all` pair is not alike here. `read_exact` fills a
/// buffer the caller already owns and copies nothing, so a body that calls it
/// allocates nothing and must not be marked for it. `write_all` hands the
/// writer's own bytes to `r2z.io.write_all`, which can grow a `Vec` and so
/// needs a `gpa` the runtime has no way to invent; a body that calls it is
/// allocating and the backend sources one. Marking the wrong one is not a
/// missed effect but a fabricated one, so `read_exact` is not answered here at
/// all.
///
/// `fill_buf` and `consume` are answered here at all: `fill_buf` borrows the
/// reader's existing buffer and copies nothing, and `consume` only advances
/// how much of it has been handed back. Neither allocates, and neither is
/// named by this function, which is the point — this asks the table for the
/// ONE method whose effect the runtime has to be handed an allocator for.
///
/// The proof is `isRuntimeIoMethod` — the same one the dispatch in
/// `resolveMethods` admits the call with — so the effect recorded here and the
/// arm the backend lowers can never disagree about which calls they cover.
/// Nothing is keyed off the name alone: a crate's own `write_all`, or an
/// inherent method that happens to share the name, has no `std::io::Write`
/// receiver and is not this.
pub fn stdIoWriteMethodAllocates(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    node: exprs.NodeId,
) bool {
    if (node >= b.exprs.len) return false;
    const method = switch (b.exprs[node].kind) {
        .method_call => |value| value,
        else => return false,
    };
    if (method.receiver >= b.exprs.len) return false;
    const receiver_ty = receiverDeclaredType(g, b, method.receiver) orelse return false;
    return isRuntimeIoMethod(g, b, method.receiver, method.method, receiver_ty, "write_all");
}

/// Whether the expression at `node` is the std `Vec` conversion that copies its
/// argument sequence into a freshly owned vector.
///
/// This is a real allocation and has to be marked as one: the runtime lowers it
/// as `r2z.alloc.vec_from_slice(T, gpa, sequence)`, so the backing store is
/// allocated under the `gpa` this flag is what causes the enclosing callable to
/// source. Marking it and the backend emitting the `gpa` it needs are the same
/// fact seen from two sides, and a caller that skips the mark hands that
/// expression an allocator it never declared.
///
/// The evidence is the resolved target, not the name: the call has to be a
/// `convert_from` whose recorded target IS the `alloc` `Vec`. A `From` impl
/// this crate wrote, or a conversion into some other owner, is a different
/// question and is not answered here.
pub fn stdVecConversionAllocates(
    _: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    node: exprs.NodeId,
) bool {
    if (node >= b.exprs.len) return false;
    const call = switch (b.exprs[node].kind) {
        .core_call => |value| value,
        else => return false,
    };
    if (call.function != .convert_from) return false;
    if (call.generic_args.len != 1) return false;
    const external = switch (call.generic_args[0]) {
        .external_nominal => |value| value,
        else => return false,
    };
    return externalPathIs(external.path, &.{ "alloc", "vec", "Vec" });
}

/// Whether the expression at `node` is a `Result` method the runtime reaches
/// for an allocator, and so makes its enclosing body allocating.
///
/// This deliberately makes NO claim about whether the payload owns anything,
/// because the backend cannot make one either: the runtime's PUBLIC
/// `r2z.Result::unwrap` / `expect` / `expect_err` take the `gpa` on every call,
/// pure payload or not. A frontend that answered "no" for a `Result<u64,
/// Fault>` would decline to inject an allocator, the backend would still emit
/// `allocator` at that call, and the result would be a reference to a binding
/// that does not exist — so the two sides have to agree by construction rather
/// than by each reasoning separately. Asking about the payload would make that
/// agreement accidental, and would be wrong the moment either side changed its
/// mind about a type.
///
/// The REPRESENTATION is the real question, and it is asked through the same
/// `errorTypeIsZigErrorSet` `lookupResultRepresentationMethod` uses rather than
/// re-derived. On the native error union the error lives IN the union as a
/// typed tag, so there is no error value to release and nothing to hand a
/// `gpa` to: `expect` stays the two-argument builtin, and `unwrap` is Zig's own
/// over the union. Only `expect_err` reaches the runtime there, as
/// `r2z.expect_error_union_err(gpa, E, union, msg)`.
///
/// Nothing here is keyed off a name alone. A crate's own `unwrap`, or an
/// inherent method that shares one, has no `Result` receiver and is not this.
pub fn stdResultCleanupAllocates(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    node: exprs.NodeId,
) bool {
    if (node >= b.exprs.len) return false;
    const method = switch (b.exprs[node].kind) {
        .method_call => |value| value,
        else => return false,
    };
    if (method.receiver >= b.exprs.len) return false;
    const receiver_ty = receiverDeclaredType(g, b, method.receiver) orelse return false;
    const result = switch (unpeelReceiverType(receiver_ty) orelse return false) {
        .result => |value| value.*,
        else => return false,
    };
    const native_error_union = result.is_error_unionable and errorTypeIsZigErrorSet(b, result.err);
    const name = g.symbol_table.get(method.method) orelse return false;
    const is_unwrap = std.mem.eql(u8, name.name, "unwrap");
    const is_expect = std.mem.eql(u8, name.name, "expect");
    const is_expect_err = std.mem.eql(u8, name.name, "expect_err");
    if (!is_unwrap and !is_expect and !is_expect_err) return false;
    // The PUBLIC `r2z.Result` takes the allocator on all three, and the
    // backend emits it on all three, so this side must too — or the emitted
    // `allocator` names a binding that was never introduced.
    if (!native_error_union) return true;
    return is_expect_err;
}

pub const BoundTraitMethod = struct {
    trait_id: spine.EntityId,
    signature: bodies.TraitMethodSig,
};

const BoundMethodSearch = struct {
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    name: []const u8,
    visited: [128]spine.EntityId = undefined,
    visited_len: usize = 0,
    result: ?BoundTraitMethod = null,
    ambiguous: bool = false,

    fn visit(self: *BoundMethodSearch, bounds: []const types.Bound) void {
        for (bounds) |bound| {
            if (bound.optional or bound.path.segments.len == 0) continue;
            const terminal = bound.path.segments[bound.path.segments.len - 1];
            var id = terminal.id orelse continue;
            if (self.g.useById(id)) |use_decl| {
                if (use_decl.kind == .external) continue;
                id = use_decl.target;
            }
            const entity = self.g.symbol_table.get(id) orelse continue;
            if (entity.kind != .trait_ or id >= self.b.bodies.len) continue;
            var seen = false;
            for (self.visited[0..self.visited_len]) |previous| {
                if (previous == id) seen = true;
            }
            if (seen or self.visited_len == self.visited.len) continue;
            self.visited[self.visited_len] = id;
            self.visited_len += 1;
            const trait_body = switch (self.b.bodies[id]) {
                .trait_ => |value| value,
                else => continue,
            };
            var declared = false;
            for (trait_body.methods) |signature| {
                if (!std.mem.eql(u8, signature.name, self.name)) continue;
                if (self.result != null and self.result.?.trait_id != id) self.ambiguous = true;
                self.result = .{ .trait_id = id, .signature = signature };
                declared = true;
            }
            // A redeclared method shadows that name on its supertraits.
            if (declared) continue;
            if (trait_body.generics) |generics| {
                for (generics.where_clauses) |clause| {
                    if (clause.self_ty.segments.len == 1 and
                        std.mem.eql(u8, clause.self_ty.segments[0].name, "Self"))
                    {
                        self.visit(clause.bounds);
                    }
                }
            }
        }
    }
};

/// The source declaration providing a generic receiver's method. A bare
/// parameter name is not evidence: only its bounds in the enclosing callable
/// and impl scopes can reach a trait signature, including a sealed supertrait.
pub fn boundTraitMethod(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    owner: spine.EntityId,
    receiver: types.Type,
    name: []const u8,
) ?BoundTraitMethod {
    var search: BoundMethodSearch = .{ .g = g, .b = b, .name = name };
    var value = receiver;
    peel: for (0..128) |_| {
        switch (value) {
            .reference => |reference| value = reference.pointee,
            .boxed => |boxed| value = boxed.*,
            else => break :peel,
        }
    } else return null;
    switch (value) {
        .dyn_trait => |bounds| search.visit(bounds),
        .@"opaque" => |opaque_type| search.visit(opaque_type.bounds),
        .path => |path| {
            if (path.segments.len != 1) return null;
            const parameter_name = path.segments[0].name;
            var current: ?spine.EntityId = owner;
            var remaining = g.symbol_table.entities.items.len;
            while (current) |id| {
                if (remaining == 0 or id >= b.bodies.len) break;
                remaining -= 1;
                const generics = switch (b.bodies[id]) {
                    .fn_ => |function| function.generics,
                    .impl_ => |implementation| implementation.generics,
                    .trait_ => |trait_body| trait_body.generics,
                    else => null,
                };
                if (generics) |parameters| {
                    for (parameters.params) |parameter| {
                        if (parameter == .type_ and
                            std.mem.eql(u8, parameter.type_.name, parameter_name))
                        {
                            search.visit(parameter.type_.bounds);
                        }
                    }
                    for (parameters.where_clauses) |clause| {
                        if (clause.self_ty.segments.len == 1 and
                            std.mem.eql(u8, clause.self_ty.segments[0].name, parameter_name))
                        {
                            search.visit(clause.bounds);
                        }
                    }
                }
                const entity = g.symbol_table.get(id) orelse break;
                current = entity.parent;
            }
        },
        else => return null,
    }
    return if (search.ambiguous) null else search.result;
}

/// The exact num_traits declaration for an overflow-checked operation.
pub fn numericMethodTrait(name: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, name, "checked_add")) return &.{ "num_traits", "ops", "checked", "CheckedAdd" };
    if (std.mem.eql(u8, name, "checked_sub")) return &.{ "num_traits", "ops", "checked", "CheckedSub" };
    if (std.mem.eql(u8, name, "checked_mul")) return &.{ "num_traits", "ops", "checked", "CheckedMul" };
    return null;
}

pub fn hasCheckedNumericBound(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    owner: spine.EntityId,
    receiver: types.Type,
    name: []const u8,
) bool {
    const canonical = numericMethodTrait(name) orelse return false;
    if (bodies.genericBound(g, b, owner, receiver, canonical) != null) return true;
    // num_traits publicly re-exports these same traits at its crate root.
    const exported = [_][]const u8{ "num_traits", canonical[3] };
    return bodies.genericBound(g, b, owner, receiver, &exported) != null;
}

fn methodBoundOwner(g: *const graph.CrateGraph, b: *const bodies.Bodies, method: exprs.MethodCall) ?spine.EntityId {
    if (g.symbol_table.get(method.method)) |entity| {
        if (entity.parent) |parent| {
            if (g.symbol_table.get(parent)) |scope| {
                if (scope.kind == .fn_ or scope.kind == .impl_) return parent;
            }
        }
    }
    return expressionOwner(g, b, method.receiver, 0);
}

/// Keep generic Hasher writes deferred until their actual receiver is known.
/// A translated implementation may override the native-endian std default.
pub fn hasHasherPrimitiveBound(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    owner: spine.EntityId,
    receiver: types.Type,
    name: []const u8,
) bool {
    const names = [_][]const u8{
        "write_u8", "write_u16", "write_u32", "write_u64", "write_u128", "write_usize",
        "write_i8", "write_i16", "write_i32", "write_i64", "write_i128", "write_isize",
    };
    for (names) |method_name| {
        if (std.mem.eql(u8, method_name, name)) {
            return bodies.genericBound(g, b, owner, receiver, &.{ "core", "hash", "Hasher" }) != null;
        }
    }
    return false;
}

/// Standard Hash/Hasher signatures on a receiver whose own scope proves the
/// trait. Keep the call deferred: translated Bytes::hash and Hasher overrides
/// must still be selected when the generic receiver becomes concrete.
pub fn boundHashMethodReturnType(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    owner: spine.EntityId,
    receiver: types.Type,
    name: []const u8,
) ?types.Type {
    if (std.mem.eql(u8, name, "hash")) {
        if (bodies.genericBound(g, b, owner, receiver, &.{ "core", "hash", "Hash" }) == null) return null;
        return .{ .prim = .unit };
    }
    if (std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "finish")) {
        if (bodies.genericBound(g, b, owner, receiver, &.{ "core", "hash", "Hasher" }) == null) return null;
        return .{ .prim = if (std.mem.eql(u8, name, "finish")) .u64 else .unit };
    }
    if (hasHasherPrimitiveBound(g, b, owner, receiver, name)) return .{ .prim = .unit };
    return null;
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
        // Requiring the `fmt` member is deliberate: it is the evidence that a
        // `Display` path exists, and it is exactly what `r2z.format.write`
        // calls on the lowered type. `Debug` is not a substitute, because
        // Rust declares only `impl<T: Display + ?Sized> ToString for T`. The
        // impl is found through the receiver's own declaration when it has
        // one, so two private types that share a name cannot lend each other
        // a `fmt`.
        return lookupTraitMethodFor(g, b, "Display", declaredReceiver(g, receiver), "fmt") != null;
    }
    const owner = methodBoundOwner(g, b, expression.kind.method_call) orelse return false;
    if (hasCheckedNumericBound(g, b, owner, receiver, name)) return true;
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

/// The type `x.into()` is being converted INTO, once inference has settled it.
///
/// Rust leaves that to inference — `&str` converts to both a `String` and a
/// `Cow<str>`, and neither is the default — so this reads the type the call
/// was already given and never picks one. A call inference could not settle is
/// refused here, which keeps a missing target from being answered with a
/// conversion that happens to exist.
fn intoCallTarget(b: *const bodies.Bodies, expression: exprs.Expr) ?types.Type {
    const type_id = expression.ty orelse return null;
    if (type_id >= b.types.len) return null;
    return b.types[type_id];
}

/// The std ownership conversion a concrete `x.into()` names, or null when
/// std declares no such pair.
///
/// The target has to be a `Cow` with exactly one payload, because that is the
/// only std owner whose `From` impls are about ownership and not about
/// reformatting: `String` into `Cow<str>` hands the backing vector over,
/// `Vec<T>` into `Cow<[T]>` does the same, and a borrowed `&B` into
/// `Cow<B>` is the identity tagged `Borrowed`. Every pair is matched on both
/// types, so `String` into `Cow<[u8]>`, `&str` into `Cow<[u8]>`, and a
/// receiver that is neither owned nor a reference stay out — each is a pair
/// std does not declare, and admitting one would emit a conversion the runtime
/// has no arm for.
pub fn lookupStdIntoMethod(receiver: types.Type, target: types.Type) ?StdMethod {
    const target_external = switch (target) {
        .external_nominal => |value| value,
        else => return null,
    };
    if (!isExactAllocNominal(target_external, "borrow", "Cow", 1)) return null;
    const payload = target_external.args[0];

    // The borrowed half. A `&B` and a `&mut B` both become `Cow::Borrowed`
    // over the very bytes the reference points at, so only the pointee is
    // compared — the mutability is not part of the payload the `Cow` holds.
    // A raw pointer is deliberately not admitted: Rust has no `From<&*const B>`
    // for `Cow`, and a pointer-to-pointer deref is not something this pass can
    // prove is the same bytes.
    //
    // A `Cow<'a, str>` payload is the `str` PRIMITIVE, read straight off the
    // source's own spelling, and a `&str` receiver's pointee is that same
    // primitive. There is nothing to normalize between them, so the literal
    // comparison below is the whole rule — and it is exact: `&[u8]` does not
    // match a `Cow<str>`, which is Rust's own answer, because `From<&[u8]>` for
    // `Cow<'a, str>` does not exist and the two borrows are not the same value.
    if (receiver == .reference) {
        if (types.deepEqual(receiver.reference.pointee, payload)) return .into_cow_borrowed;
    }

    // The owned half. `String` is the owner of `str` and `Vec<T>` the owner of
    // `[T]`, and each moves into the `Cow` rather than being copied: the
    // element type is compared, not just the owner, so a `Vec<u8>` is not an
    // owner of `[u16]`.
    const source_external = switch (receiver) {
        .external_nominal => |value| value,
        else => return null,
    };
    if (types.isStr(payload)) {
        if (isExactAllocNominal(source_external, "string", "String", 0)) return .into_cow_owned;
        return null;
    }
    const slice = switch (payload) {
        .slice => |value| value.elem,
        else => return null,
    };
    if (!isExactAllocNominal(source_external, "vec", "Vec", 1)) return null;
    if (!types.deepEqual(source_external.args[0], slice)) return null;
    return .into_cow_owned;
}

/// `core::convert::From`, the trait a concrete `.into()` is resolved through
/// when the crate's own impl is what provides it. `std::convert::From` proves
/// the same path, since std re-exports core's.
const core_convert_from: []const []const u8 = &.{ "core", "convert", "From" };

/// The crate-local `From` impl a concrete `x.into()` is written as.
///
/// `into()` reaches `<Target as Into<Source>>::into`, and the blanket
/// `impl<U, T> Into<U> for T where U: From<T>` forwards that to
/// `<Target as From<Source>>::from`. So the call the source really names is an
/// impl block IN this crate — `impl<'a> From<PercentDecode<'a>> for
/// Cow<'a, [u8]>` is what makes `percent_decode(..).into()` a `Cow<[u8]>` —
/// and neither the receiver's nominal nor any std table holds it, because the
/// impl names a type this crate itself declares.
///
/// The trait is proved by its FULL path through `bodies.boundPathMatches`, not
/// by a leaf name: a crate that declares its own `trait From<T>` writes
/// `impl From<A> for B` there, and comparing the last segment alone would let
/// that homonym answer a call Rust resolves through core's blanket `Into` to
/// `core::convert::From` — rebinding the callee to a function the source does
/// not name. The impl is the owner its own path is resolved in, which is what
/// lets a short `From` reach the right answer through the module's `use`.
///
/// Both ends are matched on the impl's own types, never on their spellings: an
/// impl of some other `From`, or of this `From` for another source or another
/// target, is a different conversion and does not answer this call.
pub fn userFromImplMethod(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    source: types.Type,
    target: types.Type,
) ?spine.EntityId {
    for (g.symbol_table.entities.items) |entity| {
        if (entity.kind != .impl_) continue;
        if (entity.id >= b.bodies.len) continue;
        const implementation = switch (b.bodies[entity.id]) {
            .impl_ => |body| body,
            else => continue,
        };
        const trait_path = implementation.trait_path orelse continue;
        if (!bodies.boundPathMatches(g, entity.id, trait_path, core_convert_from)) continue;
        if (implementation.trait_args.len != 1) continue;
        if (!types.deepEqual(implementation.trait_args[0], source)) continue;
        if (!types.deepEqual(implementation.self_ty, target)) continue;
        for (g.symbol_table.entities.items) |child| {
            if (child.kind == .fn_ and child.parent == entity.id and
                std.mem.eql(u8, child.name, "from")) return child.id;
        }
    }
    return null;
}

/// Whether an external nominal's path is exactly `wanted`, segment for segment.
///
/// The arity is deliberately not part of this. It is the answer to "which enum
/// is this", and an enum's payload is the very thing a caller here is asking
/// someone else to supply.
pub fn externalPathIs(actual: []const []const u8, wanted: []const []const u8) bool {
    if (actual.len != wanted.len) return false;
    for (actual, wanted) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

/// The one crate `From` impl that turns `source` into a target whose enum is
/// exactly `owner_path`, or null when there is not exactly one.
///
/// `owner_path` is what a `match` pattern says about its scrutinee: matching
/// `Cow::Borrowed(..)` names the scrutinee's enum — `alloc::borrow::Cow` —
/// without saying anything about the payload `B`. That is enough to choose the
/// conversion, because the IMPL carries the payload. The crate's
/// `impl From<PercentDecode<'a>> for Cow<'a, [u8]>` is the only way a
/// `PercentDecode` becomes a `Cow`, and its own `self_ty` says which `B`. The
/// pattern therefore fixes the owner and the impl fixes the argument, and
/// neither is guessed.
///
/// Two impls for the same source into the same owner are genuinely ambiguous in
/// Rust as well, so more than one is null rather than whichever the entity table
/// happens to yield first. The trait is proved by full path exactly as
/// `userFromImplMethod` proves it, for the same reason.
pub fn uniqueFromImplTargetForOwner(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    source: types.Type,
    owner_path: []const []const u8,
) ?types.Type {
    var found: ?types.Type = null;
    for (g.symbol_table.entities.items) |entity| {
        if (entity.kind != .impl_) continue;
        if (entity.id >= b.bodies.len) continue;
        const implementation = switch (b.bodies[entity.id]) {
            .impl_ => |body| body,
            else => continue,
        };
        const trait_path = implementation.trait_path orelse continue;
        if (!bodies.boundPathMatches(g, entity.id, trait_path, core_convert_from)) continue;
        if (implementation.trait_args.len != 1) continue;
        if (!types.deepEqual(implementation.trait_args[0], source)) continue;
        const target = switch (implementation.self_ty) {
            .external_nominal => |value| value,
            else => continue,
        };
        if (!externalPathIs(target.path, owner_path)) continue;
        if (found != null) return null;
        found = implementation.self_ty;
    }
    return found;
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
        const receiver_source = declaredReceiver(g, receiver);
        if (receiver_source.declaration == null and receiver_source.name.len == 0) return false;
        const implementation = lookupTraitMethodFor(g, b, trait_entity.name, receiver_source, method.name) orelse return false;
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

/// The `std::io::ErrorKind` nominal. The path is allocated from the crate
/// graph's allocator, which the pipeline backs with an arena.
fn ioErrorKindType(g: *const graph.CrateGraph) ?types.Type {
    const path = g.allocator.alloc([]const u8, 3) catch return null;
    path[0] = "std";
    path[1] = "io";
    path[2] = "ErrorKind";
    return .{ .external_nominal = .{ .path = path, .args = &.{} } };
}

/// Result type of a std method whose result the RUNTIME owns, read off the
/// receiver rather than from a signature in the graph.
///
/// Seven methods reach this, and all seven name their own result exactly:
///
/// - `to_string` returns the owned `String` of Rust's blanket
///   `impl<T: Display> ToString for T`, which the backend lowers to
///   `r2z.alloc.String`.
/// - `Result<T, E>::unwrap_err(&self) -> E` returns the error arm of the
///   receiver, and the receiver is the `Result` that arm sits in.
/// - `Result<T, E>::expect(msg) -> T` and `expect_err(msg) -> E` return the two
///   arms of that same `Result`. `unwrap_err` is decided by the representation
///   having an error VALUE; these two are admitted on every `Result`, because
///   a Zig error union holds its error as a typed tag and a tagged
///   `r2z.Result` holds it as a payload, so neither form comes up empty. Each
///   still names the arm its own receiver has.
/// - `len()` returns the element count of the sequence it is called on, and
///   `usize` is that count's type in every Rust build. A slice, a `[T; N]`,
///   a `str`, an owned `String`, and a `Vec<T>` are all a count of what the
///   receiver holds, and all lower to a Zig `.len` over that storage.
/// - `String::as_bytes(&self) -> &[u8]` names the bytes the string owns. Only
///   the owned `String` receiver names it; a slice's own `as_bytes` and a
///   `&str` reach different runtime types and stay unresolved here. The shape
///   is inference's own, byte for byte: the two halves have to name the same
///   value or an operator over one of them reads a type the other never built.
/// - `std::io::Error::kind(&self) -> ErrorKind` names the classification the
///   receiver's own io type carries, which the backend lowers to
///   `r2z.io.ErrorKind`. Both ends are the exact `std::io` path, so a crate's
///   own `kind` and every other std `io` nominal stay out of it.
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
    const is_as_bytes = std.mem.eql(u8, entity.name, "as_bytes");
    const is_expect = std.mem.eql(u8, entity.name, "expect");
    const is_expect_err = std.mem.eql(u8, entity.name, "expect_err");
    const is_error_kind = std.mem.eql(u8, entity.name, "kind");
    if (!is_to_string and !is_len and !is_as_bytes and !is_expect and
        !is_expect_err and !is_error_kind and
        !std.mem.eql(u8, entity.name, "unwrap_err")) return null;
    const receiver_ty = receiverDeclaredType(g, b, method.receiver) orelse return null;
    if (is_len) {
        // The evidence is the dispatch the resolver admits the call on, so
        // this cannot name a `len` the resolver would refuse: only a receiver
        // `lookupStdMethod` matches for is typed here. That is a slice and a
        // `str`, through `slice_len`, the owned `String` through
        // `string_len`, and a `Vec<T>` — whose elements live in the storage
        // the slice length already reads — through the same `slice_len`. All
        // of them count what the receiver holds and all answer `usize`.
        //
        // An `ExactSizeIterator::len` on an iterator is what stays unresolved:
        // no runtime `len` backs it, it keeps its own signature, and naming a
        // result for it would hand an operator a value nothing builds.
        const std_method = lookupStdMethod(receiver_ty, "len") orelse return null;
        if (std_method != .slice_len and std_method != .string_len) return null;
        return .{ .prim = .usize };
    }
    if (is_as_bytes) {
        // The same evidence rule as `len`, for the same reason: a `Vec<u8>`,
        // a `&str`, and a slice each reach a different runtime type here, and
        // typing them from this receiver's dispatch would hand an operator a
        // value the backend never builds.
        const std_method = lookupStdMethod(receiver_ty, "as_bytes") orelse return null;
        if (std_method != .string_as_bytes) return null;
        const bytes = g.allocator.create(types.Slice) catch return null;
        bytes.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
        return .{ .slice = bytes };
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
    if (is_expect or is_expect_err) {
        // The same evidence rule as `len` and `as_bytes`: a `Result` is the only
        // receiver either of these has, and the arm each returns is named off
        // that same receiver. `expect` returns the Ok arm and `expect_err` the
        // Err arm, and the Err arm is a value for BOTH representations — a
        // typed tag inside a Zig error union, a payload inside a tagged
        // `r2z.Result` — so neither representation is a reason to leave this
        // unresolved.
        const name: []const u8 = if (is_expect) "expect" else "expect_err";
        const admitted = lookupStdMethod(receiver_ty, name) orelse return null;
        const wanted: StdMethod = if (is_expect) .result_expect else .result_expect_err;
        if (admitted != wanted) return null;
        const result = switch (unpeelReceiverType(receiver_ty) orelse return null) {
            .result => |value| value.*,
            else => return null,
        };
        return if (is_expect) result.ok else result.err;
    }
    if (is_error_kind) {
        // `std::io::Error::kind` names the classification its receiver is
        // io-shaped for. Both the receiver and the result are the exact
        // `std::io` path, so a crate's own `kind`, and every other std `io`
        // nominal, stay out of it.
        const external = switch (unpeelReceiverType(receiver_ty) orelse return null) {
            .external_nominal => |value| value,
            else => return null,
        };
        if (!isExactStdIoType(external, "Error")) return null;
        const admitted = lookupStdMethod(receiver_ty, "kind") orelse return null;
        if (admitted != .io_error_kind) return null;
        return ioErrorKindType(g);
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

/// Whether `node`'s own operand type carries `trait_path` as a declared bound.
///
/// `bodies.genericBound` answers that, but it answers it about a SCOPE: it
/// walks up from `owner` through the scopes that can declare a parameter's
/// bound. Both operands of an operator have an owner and a type of their own,
/// and a comparison is admitted when the pair pins the bound on EITHER side,
/// so the operand and the scope it is asked about stay one node.
fn operandHasGenericBound(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    node: exprs.NodeId,
    trait_path: []const []const u8,
) bool {
    const receiver = operatorOperandType(g, b, node) orelse return false;
    const owner = expressionOwner(g, b, node, 0) orelse return false;
    return bodies.genericBound(g, b, owner, receiver, trait_path) != null;
}

fn boundOperator(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    lhs: exprs.NodeId,
    rhs: exprs.NodeId,
    module: []const u8,
    name: []const u8,
) bool {
    const trait_path: []const []const u8 = &.{ "core", module, name };
    return operandHasGenericBound(g, b, lhs, trait_path) or
        operandHasGenericBound(g, b, rhs, trait_path);
}

/// One edge of a std supertrait graph, as that std's own declaration spells
/// it: `core/src/cmp.rs` gives `PartialOrd<Rhs>: PartialEq<Rhs>`,
/// `Eq: PartialEq<Self>` and `Ord: Eq + PartialOrd<Self>`, and
/// `num_traits/src/identities.rs` gives `Zero: Add<Self, Output = Self>`.
///
/// These are the whole table because they are the supertraits this pass is
/// asked about, and each edge is one std's own declaration spelled out. A
/// bound that reaches an operator trait through the table is therefore a
/// bound Rust admits, which is what makes the operator valid source before it
/// ever reaches this pass. Nothing here is an unrelated capability granted to
/// a bound that does not have it: `Eq` buys `==` and not `<`, because only
/// the edges below are walked.
///
/// The `num_traits::Zero` edge is there because it is that crate's own
/// declaration, and it is what a bound written `I: Zero` proves: atoi's `nth`
/// is `fn nth<I: Zero + One>(..) { .. i = i + I::one(); .. }`, which is valid
/// Rust because `Zero` already requires `Add`. Refusing it says the frontend
/// does not know a supertrait, not that the source is wrong.
///
/// Every path in the table is EXTERNAL, which is what keeps a crate's own
/// `trait Eq` — or its own `trait Zero` — out of it: `bodies.genericBound`
/// decides through `boundPathMatches`, and a crate-local trait can never
/// answer for a path rooted in another crate's module.
const CoreSupertrait = struct {
    from: []const []const u8,
    to: []const []const u8,
};

const core_supertraits = [_]CoreSupertrait{
    .{ .from = &.{ "core", "cmp", "PartialOrd" }, .to = &.{ "core", "cmp", "PartialEq" } },
    .{ .from = &.{ "core", "cmp", "Eq" }, .to = &.{ "core", "cmp", "PartialEq" } },
    .{ .from = &.{ "core", "cmp", "Ord" }, .to = &.{ "core", "cmp", "Eq" } },
    .{ .from = &.{ "core", "cmp", "Ord" }, .to = &.{ "core", "cmp", "PartialOrd" } },
    .{ .from = &.{ "num_traits", "Zero" }, .to = &.{ "core", "ops", "Add" } },
};

/// How deep the table is followed. Its longest chain is two edges, so this is
/// what keeps an edge added to it later from looping, not what the chain
/// needs.
const core_supertrait_depth_max: usize = 8;

fn traitPathEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_part, right_part| {
        if (!std.mem.eql(u8, left_part, right_part)) return false;
    }
    return true;
}

/// Whether core's supertrait graph reaches `wanted` from `declared`.
fn coreSupertraitReaches(
    declared: []const []const u8,
    wanted: []const []const u8,
    depth: usize,
) bool {
    if (depth >= core_supertrait_depth_max) return false;
    for (core_supertraits) |edge| {
        if (!traitPathEqual(edge.from, declared)) continue;
        if (traitPathEqual(edge.to, wanted)) return true;
        if (coreSupertraitReaches(edge.to, wanted, depth + 1)) return true;
    }
    return false;
}

/// Whether either operand's own declared bounds reach the operator's trait
/// through core's supertrait graph rather than through the trait itself.
///
/// `T: Eq` is `T: PartialEq` in Rust, so `assert_eq!(hashed, expected)` over
/// such a `T` is valid source and its `==` is a typed binary operator. Nothing
/// else about the operator changes: it stays a `binary` node over two
/// operands whose types stay the generic parameter each was declared with, so
/// the backend still emits the comparison it emits for any other typed
/// operator.
fn coreSupertraitOperator(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    binary: exprs.BinaryExpr,
    module: []const u8,
    name: []const u8,
) bool {
    const wanted: []const []const u8 = &.{ "core", module, name };
    for ([_]exprs.NodeId{ binary.lhs, binary.rhs }) |node| {
        for (core_supertraits) |edge| {
            if (!coreSupertraitReaches(edge.from, wanted, 0)) continue;
            if (operandHasGenericBound(g, b, node, edge.from)) return true;
        }
    }
    return false;
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
        // A Rust tuple lowers to an anonymous Zig `struct`, and `r2z.ops.equal`
        // is what every non-primitive operand already routes through: it
        // compares a struct with `std.meta.eql` when the whole type is
        // comparable and walks it FIELD BY FIELD when it is not. A tuple is
        // comparable exactly when every element is, which is the same question
        // the `Result` arm above asks of its two payloads and the same walk
        // that reaches them.
        //
        // The tuple is the type `atoi`'s own `#[cfg(test)]` module compares:
        // `assert_eq!((Some(255), 3), u8::from_radix_10_checked(b"255"))` is
        // valid Rust, and the emitter spells it `r2z.ops.equal(.{ a, b }, .{
        // c, d })` over two `struct { ?u8, usize }` values. Refusing it said the
        // frontend does not know a tuple, not that the source was wrong.
        .tuple => |elements| tupleElementsComparable(elements),
        // `std::io::ErrorKind` is a payload-free std enum the backend lowers to
        // `r2z.io.ErrorKind`, and Zig compares a tag by value. The path is
        // matched in full, so no other std `io` nominal and no crate's own
        // `ErrorKind` rides in on the leaf.
        //
        // `str` is here for the same reason the byte slice is: it is Rust's
        // unsized byte sequence, and `&str == &str` compares the bytes. It
        // reaches this arm on its own now that a borrowed string is a
        // `reference` to the `str` PRIMITIVE rather than a `[]const u8`.
        .external_nominal => |external| isListBackedOwnerNominal(external) or
            isExactStdIoType(external, "ErrorKind") or
            types.isStr(ty),
        .path => |path| enumVariantsComparable(b, path),
        else => false,
    };
}

/// Whether every element of a tuple is a value `r2z.ops.equal` can compare.
///
/// The tuple itself lowers to an anonymous Zig `struct`, so the walk the
/// runtime performs is the one it performs for any other struct: it compares
/// the whole value with `std.meta.eql` when every field is natively
/// comparable, and otherwise descends field by field. Either way it reaches
/// each element through the same `equal` this recursion asks about, so one
/// element that carries no comparable value — a trait object, a function
/// pointer — refuses the whole tuple, exactly as it refuses a `Result` that
/// carries one.
///
/// The depth bound and the recursion are `equalityPayloadComparable`'s own: it
/// is the same question the `Result` arm above asks, and the tuple only adds
/// the step that asks it once per element.
fn tupleElementsComparable(elements: []const types.Type) bool {
    for (elements) |element| {
        if (!equalityPayloadComparable(element, 0)) return false;
    }
    return true;
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
///
/// The length is a target count and is `u64`; it is compared against an
/// array type literal, which is `u64` too.
fn repeatedArrayInitializerLen(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    node: exprs.NodeId,
) ?u64 {
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

/// The operators core implements over a raw pointer.
///
/// `impl PartialEq for *const T` and `impl PartialOrd for *const T` compare
/// the two ADDRESSES, so a comparison of two `*const u8` is a typed binary
/// operator over two values of the same pointer type — `end_ptr > ptr` in
/// `seahash/src/buffer.rs:47` and `ptr == scope` in `syn/src/buffer.rs:137`
/// are both this. Nothing else reads a pointer through a binary operator:
/// Rust has no `Add`/`Sub`/`Mul`/`BitAnd` for one (`ptr + n` is `offset`), so
/// every arithmetic spelling stays a method call the runtime owns and a
/// pointer never becomes a scalar operand.
fn isRawPointerComparison(op: exprs.BinaryOp) bool {
    return switch (op) {
        .eq, .ne, .lt, .le, .gt, .ge => true,
        else => false,
    };
}

/// The raw pointer a type is, behind the two layers that never change which
/// pointer it names: a borrow of one, and a local `type` alias that stands for
/// one. Both are followed exactly as `isScalarOperandType` follows them,
/// because `&*const u8` and `type BytePtr = *const u8` are the same pointer
/// value spelled two ways, and percent-encoding writes the second one.
fn rawPointerType(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    t: types.Type,
) ?types.RawPtr {
    var current = t;
    var hops: usize = 0;
    while (hops < 128) : (hops += 1) {
        switch (current) {
            .reference => current = current.reference.pointee,
            .path => current = aliasBodyType(g, b, current.path) orelse return null,
            .raw_ptr => return current.raw_ptr.*,
            else => return null,
        }
    }
    return null;
}

/// Whether a pointee is one the emitter writes as a single machine word.
///
/// `*const [T]` — a pointer to a slice — lowers to a Zig SLICE rather than to
/// a pointer, and `*const dyn Trait` to a descriptor; Zig has no `<` for
/// either, and neither is a thin pointer Rust could have compared by address
/// alone. Every other pointee here is a value: a primitive, a slice's ELEMENT
/// type, a nominal, a tuple, a reference. That is the boundary of what this
/// rule admits, and a fat pointer comparison stays a refusal rather than a
/// comparison the emitter cannot spell.
fn isThinRawPointerPointee(pointee: types.Type) bool {
    return switch (pointee) {
        .slice, .dyn_trait => false,
        .@"opaque" => |opaque_type| opaque_type.concrete != null,
        else => true,
    };
}

/// Whether both operands of a comparison are raw pointers this pass can name.
///
/// Both sides must name thin raw pointers after aliases and references are
/// resolved. Pointee operators do not participate in address comparisons.
fn rawPointerComparisonOperands(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    binary: exprs.BinaryExpr,
) bool {
    if (!isRawPointerComparison(binary.op)) return false;
    const lhs = rawPointerType(g, b, operatorOperandType(g, b, binary.lhs) orelse return false) orelse return false;
    const rhs = rawPointerType(g, b, operatorOperandType(g, b, binary.rhs) orelse return false) orelse return false;
    return isThinRawPointerPointee(lhs.pointee) and isThinRawPointerPointee(rhs.pointee);
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
    // Two raw pointers compare by ADDRESS, and that impl lives in core rather
    // than in this crate's graph, so no trait lookup below can ever find it.
    // The operator itself stays a binary node: nothing here rewrites it, and
    // nothing here may hand it to the pointee's `PartialEq`/`PartialOrd`,
    // which is a different comparison over different values.
    if (rawPointerComparisonOperands(g, b, binary)) return true;
    if (boundOperator(g, b, binary.lhs, binary.rhs, operation[0], operation[1])) return true;
    if (coreSupertraitOperator(g, b, binary, operation[0], operation[1])) return true;
    const receiver = receiverSource(g, b, binary.lhs, receiverDeclaredType(g, b, binary.lhs)) orelse return false;
    return lookupTraitMethodFor(g, b, operation[1], receiver, operation[2]) != null;
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
    const receiver = receiverSource(g, b, assignment.target, receiverDeclaredType(g, b, assignment.target)) orelse return false;
    const method = lookupTraitMethodFor(g, b, operation[0], receiver, operation[1]) orelse
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

const ResolveTableGrowth = struct {
    exprs_owned: bool = false,
    types_owned: bool = false,
};

fn internResolvedType(g: *const graph.CrateGraph, b: *bodies.Bodies, growth: *ResolveTableGrowth, ty: types.Type) !exprs.TypeId {
    for (b.types, 0..) |existing, index| {
        if (types.deepEqual(existing, ty)) return @intCast(index);
    }
    const table = if (growth.types_owned)
        try g.allocator.realloc(@constCast(b.types), b.types.len + 1)
    else table: {
        const fresh = try g.allocator.alloc(types.Type, b.types.len + 1);
        @memcpy(fresh[0..b.types.len], b.types);
        break :table fresh;
    };
    growth.types_owned = true;
    table[b.types.len] = ty;
    const id: exprs.TypeId = @intCast(b.types.len);
    b.types = table;
    return id;
}

fn dereferenceCoreReceiver(
    g: *const graph.CrateGraph,
    b: *bodies.Bodies,
    growth: *ResolveTableGrowth,
    node: exprs.NodeId,
    receiver: types.Type,
) !exprs.NodeId {
    var value = receiver;
    var count: usize = 0;
    while (value == .reference) {
        count += 1;
        value = value.reference.pointee;
    }
    if (count == 0) return node;
    const original_len = b.exprs.len;
    const source_span = b.exprs[node].span;
    const expressions = if (growth.exprs_owned)
        try g.allocator.realloc(@constCast(b.exprs), original_len + count)
    else table: {
        const fresh = try g.allocator.alloc(exprs.Expr, original_len + count);
        @memcpy(fresh[0..original_len], b.exprs);
        break :table fresh;
    };
    growth.exprs_owned = true;
    b.exprs = expressions;
    var operand = node;
    value = receiver;
    for (expressions[original_len..], original_len..) |*expression, index| {
        value = value.reference.pointee;
        const id: exprs.NodeId = @intCast(index);
        expression.* = .{
            .id = id,
            .span = source_span,
            .ty = try internResolvedType(g, b, growth, value),
            .kind = .{ .unary = .{ .op = .deref, .operand = operand } },
        };
        operand = id;
    }
    return operand;
}

/// The byte width an integer's little-endian image always has, or null when
/// the width belongs to the compilation target.
///
/// `usize` and `isize` are exactly the two whose image is the TARGET's width
/// rather than a number the language fixes, and only the `mem_size_of` node
/// the lowering layer builds for them carries that answer. Everything else
/// has one width on every target, which is what lets this pass state it.
fn fixedIntegerByteWidth(primitive: types.Prim) ?u64 {
    return switch (primitive) {
        .i8, .u8 => 1,
        .i16, .u16 => 2,
        .i32, .u32 => 4,
        .i64, .u64 => 8,
        .i128, .u128 => 16,
        .usize, .isize => null,
        // A float, a `char` and a `bool` have no byte image these operations
        // produce, so there is no width to state for them at all.
        else => null,
    };
}

/// The integer a standard `Hasher` primitive writer writes, read from the
/// method's own name. `null` for anything else: only the twelve integer
/// spellings core declares are admitted, because `hash_write_primitive` takes
/// an integer argument and a `write_f32` would build a call the IR's own
/// validation refuses. The list is `hasHasherPrimitiveBound`'s, so the two
/// readers of the same family cannot drift apart.
fn hasherPrimitiveWriter(name: []const u8) ?types.Prim {
    if (!std.mem.startsWith(u8, name, "write_")) return null;
    const suffix = name["write_".len..];
    // A runtime search over the twelve spellings, not an `inline for` over the
    // enum's fields: the suffix is a runtime string, and comparing it against
    // each tag name is ordinary runtime work rather than comptime control flow.
    const writers = [_]types.Prim{
        .u8, .u16, .u32, .u64, .u128, .usize,
        .i8, .i16, .i32, .i64, .i128, .isize,
    };
    for (writers) |primitive| {
        if (std.mem.eql(u8, suffix, @tagName(primitive))) return primitive;
    }
    return null;
}

/// The one `core::hash::Hasher` impl this crate writes for `receiver`'s own
/// declaration, or null.
///
/// The trait identity is `boundPathMatches`, not the text of an impl name, so
/// a crate's own `Hasher` never stands in for core's — siphasher imports
/// `core::hash::Hasher as _` in both of its modules precisely so its two
/// private `struct Hasher` declarations cannot answer for it. The receiver
/// identity is the impl's own `self_ty`, so `sip::Hasher` never reaches
/// sip128's impl. Two impls of core's `Hasher` for one declaration is the
/// coherence error rustc rejects long before here, so it answers null rather
/// than picking one.
fn coreHasherImpl(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    receiver: SourceReceiver,
) ?spine.EntityId {
    const declaration = receiver.declaration orelse return null;
    var found: ?spine.EntityId = null;
    for (g.symbol_table.entities.items) |ent| {
        if (ent.kind != .impl_ or ent.id >= b.bodies.len) continue;
        const implementation = switch (b.bodies[ent.id]) {
            .impl_ => |value| value,
            else => continue,
        };
        const self_declaration = nominalDeclarationId(g, implementation.self_ty) orelse continue;
        if (self_declaration != declaration) continue;
        const trait_path = implementation.trait_path orelse continue;
        if (!bodies.boundPathMatches(g, ent.id, trait_path, &.{ "core", "hash", "Hasher" })) continue;
        if (found != null) return null;
        found = ent.id;
    }
    return found;
}

/// The node a core call takes as its mutable hasher: the receiver itself when
/// it is already a mutable borrow, and one borrow of it otherwise.
///
/// A `hash_write_primitive` hasher argument is a `&mut`, because that is what
/// every one of core's writers takes. A receiver written `self.hasher` is a
/// PLACE rather than a borrow, and `lowerHasherDefaultWrite` distinguishes
/// the two by exactly this: a borrowed handle is passed through, a place is
/// addressed. Stating the borrow here is what makes the node say which of the
/// two it is.
fn mutableHasherReceiver(
    g: *const graph.CrateGraph,
    b: *bodies.Bodies,
    growth: *ResolveTableGrowth,
    node: exprs.NodeId,
    receiver: types.Type,
) !exprs.NodeId {
    if (receiver == .reference and receiver.reference.mut) return node;
    const borrow = try g.allocator.create(types.Ref);
    borrow.* = .{ .mut = true, .pointee = receiver };
    const index = b.exprs.len;
    const expressions = if (growth.exprs_owned)
        try g.allocator.realloc(@constCast(b.exprs), index + 1)
    else table: {
        const fresh = try g.allocator.alloc(exprs.Expr, index + 1);
        @memcpy(fresh[0..index], b.exprs);
        break :table fresh;
    };
    growth.exprs_owned = true;
    expressions[index] = .{
        .id = @intCast(index),
        .span = expressions[node].span,
        .ty = try internResolvedType(g, b, growth, .{ .reference = borrow }),
        .kind = .{ .unary = .{ .op = .{ .ref = .mutable }, .operand = node } },
    };
    b.exprs = expressions;
    return @intCast(index);
}

/// Extraction cannot lower methods whose receiver type is only learned by
/// inference. Finish those same admissions here, after source overrides have
/// had precedence, using the existing cores and their original argument order.
fn resolveTypedCoreMethod(
    g: *const graph.CrateGraph,
    b: *bodies.Bodies,
    growth: *ResolveTableGrowth,
    source_expression: *exprs.Expr,
    receiver: types.Type,
    name: []const u8,
) !bool {
    var replacement = source_expression.*;
    const expression = &replacement;
    const method = expression.kind.method_call;
    if (std.mem.eql(u8, name, "copy_to_nonoverlapping")) {
        if (method.args.len != 2) return false;
        const pointer = rawPointerType(g, b, receiver) orelse return false;
        const args = try g.allocator.alloc(exprs.NodeId, 3);
        errdefer g.allocator.free(args);
        args[0] = try dereferenceCoreReceiver(g, b, growth, method.receiver, receiver);
        @memcpy(args[1..], method.args);
        const generic_args = try g.allocator.dupe(types.Type, &.{pointer.pointee});
        errdefer g.allocator.free(generic_args);
        expression.ty = try internResolvedType(g, b, growth, .{ .prim = .unit });
        expression.kind = .{ .core_call = .{
            .function = .ptr_copy_nonoverlapping,
            .generic_args = generic_args,
            .args = args,
        } };
        @constCast(b.exprs)[replacement.id] = replacement;
        return true;
    }
    const value = unpeelReceiverType(receiver) orelse return false;
    if (std.mem.eql(u8, name, "to_vec")) {
        if (method.args.len != 0) return false;
        const element = switch (value) {
            .slice => |slice| slice.elem,
            .array => |array| array.elem,
            else => return false,
        };
        var target_args_owned = false;
        const target: types.Type = target: {
            if (expression.ty) |id| {
                if (id < b.types.len and b.types[id] == .external_nominal) {
                    const nominal = b.types[id].external_nominal;
                    if (isExactAllocNominal(nominal, "vec", "Vec", 1) and
                        types.deepEqual(nominal.args[0], element)) break :target b.types[id];
                }
            }
            const params = try g.allocator.dupe(types.Type, &.{element});
            target_args_owned = true;
            break :target .{ .external_nominal = .{
                .path = &.{ "alloc", "vec", "Vec" },
                .args = params,
            } };
        };
        errdefer if (target_args_owned) g.allocator.free(target.external_nominal.args);
        const generic_args = try g.allocator.dupe(types.Type, &.{target});
        errdefer g.allocator.free(generic_args);
        const args = try g.allocator.dupe(exprs.NodeId, &.{method.receiver});
        errdefer g.allocator.free(args);
        expression.ty = try internResolvedType(g, b, growth, target);
        expression.kind = .{ .core_call = .{
            .function = .convert_from,
            .generic_args = generic_args,
            .args = args,
        } };
        @constCast(b.exprs)[replacement.id] = replacement;
        return true;
    }
    if (std.mem.eql(u8, name, "to_le_bytes")) {
        if (method.args.len != 0 or value != .prim) return false;
        switch (value.prim) {
            .u8,
            .u16,
            .u32,
            .u64,
            .u128,
            .usize,
            .i8,
            .i16,
            .i32,
            .i64,
            .i128,
            .isize,
            => {},
            else => return false,
        }
        // `value.to_le_bytes()` is `[size_of::<T>()]u8`, and for a FIXED-width
        // integer that length is a number this pass can state. Inference owns
        // that record when it typed the call itself, and it stays
        // authoritative here — including the symbolic `size_of::<usize>()` and
        // `size_of::<isize>()` lengths, which are the TARGET's width and not a
        // number this module may restate.
        //
        // What is not authoritative is its ABSENCE. A receiver whose own type
        // only inference could recover — `self.tail` in a trait impl, where
        // `&Self` is what the signature declares — leaves the lowering layer
        // with nothing to measure at extraction time, so the call reaches this
        // pass as a plain method call carrying no result type at all. The
        // width is in the receiver all the same, so the admission is finished
        // HERE rather than lost: without it `impl Hasher for SeaHasher`'s
        // `finish` is refused as "method dispatch unavailable" over a call
        // whose receiver is a `u64` and whose answer is `[u8; 8]`.
        //
        // Where the record IS there it has to AGREE: a literal length that is
        // not this receiver's width is not this call's image, and emitting it
        // would answer with a byte count the source never wrote. A length that
        // is an expression states no number here, which is exactly the
        // pointer-sized case this pass must not second-guess.
        const width = fixedIntegerByteWidth(value.prim);
        const result: exprs.TypeId = blk: {
            if (expression.ty) |recorded| {
                if (recorded >= b.types.len or b.types[recorded] != .array or
                    !types.deepEqual(b.types[recorded].array.elem, .{ .prim = .u8 }))
                {
                    return false;
                }
                if (width) |expected| {
                    switch (b.types[recorded].array.len) {
                        .literal => |count| {
                            if (count != expected) return false;
                        },
                        .generic, .expression => {},
                    }
                }
                break :blk recorded;
            }
            const known_width = width orelse return false;
            const image = try g.allocator.create(types.Array);
            image.* = .{ .elem = .{ .prim = .u8 }, .len = .{ .literal = known_width } };
            break :blk try internResolvedType(g, b, growth, .{ .array = image });
        };
        const generic_args = try g.allocator.dupe(types.Type, &.{value});
        errdefer g.allocator.free(generic_args);
        const source = try dereferenceCoreReceiver(g, b, growth, method.receiver, receiver);
        const args = try g.allocator.dupe(exprs.NodeId, &.{source});
        expression.ty = result;
        expression.kind = .{ .core_call = .{
            .function = .prim_to_le_bytes,
            .generic_args = generic_args,
            .args = args,
        } };
        @constCast(b.exprs)[replacement.id] = replacement;
        return true;
    }

    // A primitive `Hasher` writer this crate's own impl does not declare is
    // the TRAIT's default method, and Rust admits the call because the impl
    // makes the receiver a `core::hash::Hasher` at all — not because any
    // `write_u16` exists to bind. The default body writes the value's own
    // native bytes through `write`, which is exactly what `hash_write_primitive`
    // asks the runtime for, so the call becomes that core rather than a
    // refusal. siphasher's `impl<S: Sip> hash::Hasher for Hasher<S>` declares
    // `write_u8` and `write_u32` but no `write_u16`, and
    // `self.hasher.write_u16(i)` is valid Rust for exactly that reason.
    if (hasherPrimitiveWriter(name)) |written| {
        if (method.args.len != 1) return false;
        if (coreHasherImpl(g, b, declaredReceiver(g, receiver)) == null) return false;
        const generic_args = try g.allocator.dupe(types.Type, &.{.{ .prim = written }});
        errdefer g.allocator.free(generic_args);
        // The core call takes the hasher by mutable borrow. A receiver the
        // source already holds as one is passed as it stands; a receiver that
        // is a PLACE takes the borrow Rust's `&mut self` would have taken,
        // which is the shape `lowerHasherDefaultWrite` already lowers.
        const hasher = try mutableHasherReceiver(g, b, growth, method.receiver, receiver);
        const args = try g.allocator.dupe(exprs.NodeId, &.{ hasher, method.args[0] });
        errdefer g.allocator.free(args);
        // The payload is the integer the method NAME fixes, so the argument's
        // own record is stated here rather than left to whatever inference
        // pinned. The enclosing signature is core's own `write_u16(&mut self,
        // i: u16)`, which is what says the argument is that integer.
        @constCast(b.exprs)[method.args[0]].ty = try internResolvedType(g, b, growth, .{
            .prim = written,
        });
        expression.ty = try internResolvedType(g, b, growth, .{ .prim = .unit });
        expression.kind = .{ .core_call = .{
            .function = .hash_write_primitive,
            .generic_args = generic_args,
            .args = args,
        } };
        @constCast(b.exprs)[replacement.id] = replacement;
        return true;
    }
    return false;
}

/// Resolve all method calls in `b.exprs` using the crate graph and types table.
/// If expression or type tables grow, their new slices are allocated by the
/// graph allocator; the caller owns those slices and still owns the inputs.
pub fn resolveMethods(
    g: *const graph.CrateGraph,
    b: *bodies.Bodies,
) std.mem.Allocator.Error!ResolutionStats {
    var stats: ResolutionStats = .{};
    var growth: ResolveTableGrowth = .{};
    const source_count = b.exprs.len;
    var expression_index: usize = 0;
    while (expression_index < source_count) : (expression_index += 1) {
        const e = &@constCast(b.exprs)[expression_index];
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
            if (retainedIteratorProjection(g, b, receiver_node)) |projection| {
                if (isRetainedIteratorProjectionMethod(projection, method_name)) {
                    stats.std_resolved += 1;
                } else {
                    replaceWithUnsupported(e, reason_method_dispatch_unavailable);
                    stats.unsupported_methods += 1;
                }
                continue;
            }

            const receiver_source = receiverSource(g, b, receiver_node, receiver_ty);
            var resolved = false;
            if (receiver_source) |source| {
                switch (lookupSourceMethodFor(g, b, source, method_name)) {
                    .inherent => |fn_id| {
                        mc.method = fn_id;
                        stats.inherent_resolved += 1;
                        resolved = true;
                    },
                    .trait_ => |fn_id| {
                        mc.method = fn_id;
                        stats.trait_resolved += 1;
                        resolved = true;
                    },
                    .ambiguous => {
                        replaceWithUnsupported(e, reason_method_dispatch_ambiguous);
                        stats.unsupported_methods += 1;
                        continue;
                    },
                    .missing => {},
                }
            }
            if (!resolved) {
                if (receiver_ty) |ty| {
                    const owner = methodBoundOwner(g, b, mc.*);
                    if (owner) |scope| {
                        if (boundTraitMethod(g, b, scope, ty, method_name)) |bound_method| {
                            if (bindBlanketImplMethod(g, mc.method, bound_method.trait_id)) {
                                stats.trait_resolved += 1;
                                resolved = true;
                            }
                        }
                    }
                }
            }
            if (!resolved) {
                if (receiver_ty) |ty| {
                    if (try resolveTypedCoreMethod(g, b, &growth, e, ty, method_name)) {
                        stats.std_resolved += 1;
                        continue;
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
                    const runtime_io = isRuntimeIoMethod(g, b, receiver_node, mc.method, ty, method_name);
                    const bound_hash = if (methodBoundOwner(g, b, mc.*)) |owner|
                        boundHashMethodReturnType(g, b, owner, ty, method_name)
                    else
                        null;
                    if (lookupStdMethod(ty, method_name) != null or
                        lookupResultRepresentationMethod(b, ty, method_name) != null or
                        isRuntimeIteratorMethod(ty, method_name) or
                        isRuntimeMemoryMethod(ty, method_name) or
                        isBoundStandardMethod(g, b, e.*, ty, method_name) or
                        bound_hash != null or
                        runtime_io)
                    {
                        if (runtime_io) mc.receiver_mode = .mutable;
                        if (bound_hash != null) {
                            mc.receiver_mode = if (std.mem.eql(u8, method_name, "finish") or
                                std.mem.eql(u8, method_name, "hash")) .shared else .mutable;
                        }
                        stats.std_resolved += 1;
                        resolved = true;
                        if (e.ty == null) {
                            if (stdMethodResultType(g, b, @intCast(expression_index), 0)) |result_type| {
                                e.ty = try internResolvedType(g, b, &growth, result_type);
                            }
                        }
                    }

                    // `x.into()` is written against the blanket
                    // `Into<U> for T where U: From<T>`, so the target is not
                    // anywhere in the receiver — Rust reads it off the
                    // context and this reads it off the type inference already
                    // gave the call. Two questions follow from having both
                    // ends: is the pair one of std's own ownership
                    // conversions, or is it an impl block this crate wrote?
                    // A pair that is neither stays unresolved, because
                    // answering it with the nearest std conversion would emit
                    // a call the source never wrote.
                    if (!resolved and std.mem.eql(u8, method_name, "into")) {
                        if (intoCallTarget(b, e.*)) |target| {
                            if (lookupStdIntoMethod(ty, target) != null) {
                                stats.std_resolved += 1;
                                resolved = true;
                            } else if (userFromImplMethod(g, b, ty, target)) |from_id| {
                                mc.method = from_id;
                                stats.trait_resolved += 1;
                                resolved = true;
                            }
                        }
                    }
                }
            }
            // A blanket `impl<T: AsRef<[u8]>> Trait for T` provides its method
            // for every type its bound admits, and a receiver that carries
            // that bound is one of them: an array, or the type parameter a
            // generic wrapper bounds in its own signature. The impl names no
            // concrete self type, so nothing here can pick the call's method
            // by receiver name; what it can do is name the TRAIT, which is
            // how the backend reaches the impl it provides the method from.
            // The receiver's type is the one derived above, so the gate asks
            // about the same value this branch has been reading.
            if (!resolved and blanketReceiver(g, b, receiver_node, receiver, receiver_ty)) {
                if (lookupBlanketAsRefBytesTrait(g, b, method_name)) |trait_id| {
                    if (bindBlanketImplMethod(g, mc.method, trait_id)) {
                        stats.trait_resolved += 1;
                        resolved = true;
                    }
                }
            }
            if (!resolved) {
                const reason = if (receiver_source == null and receiver_ty == null)
                    reason_receiver_unavailable
                else
                    reason_method_dispatch_unavailable;
                replaceWithUnsupported(e, reason);
                stats.unsupported_methods += 1;
            }
            if (resolved and e.ty == null and mc.method < b.bodies.len) {
                if (b.bodies[mc.method] == .fn_ and b.bodies[mc.method].fn_.ret == .prim) {
                    e.ty = try internResolvedType(g, b, &growth, b.bodies[mc.method].fn_.ret);
                }
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
        if (e.kind == .call and e.ty == null) {
            if (callDeclaredReturnType(g, b, e.kind.call)) |declared| {
                if (declared == .prim) {
                    e.ty = try internResolvedType(g, b, &growth, declared);
                }
            }
        }
    }

    // Runs last, and on the tree the loop above has finished rewriting: an
    // assignment this pass refuses is no longer an assignment, so a
    // late-initialized binding has to read what is left.
    try typeLateInitializedBindings(g, b);

    return stats;
}

/// What the solver decided about one local binding: the name its source
/// spelling carries, and the type its occurrences were typed as.
const TypedBinding = struct {
    name: []const u8,
    ty: exprs.TypeId,
};

/// A `let` the source declares with NO initializer, so an assignment that
/// follows is the only thing in the program that fixes its type.
const LateLetBinding = struct {
    name: []const u8,
    pattern: exprs.NodeId,
    statement: exprs.NodeId,
};

/// The late-initialized bindings currently in scope, innermost last, so a name
/// an inner block shadows is the one an assignment inside it reaches.
const LateLetScope = struct {
    entries: std.ArrayListUnmanaged(LateLetBinding) = .empty,
    allocator: std.mem.Allocator,

    fn deinit(self: *LateLetScope) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Nesting bound for the walk below. A body's own structure nests a handful of
/// blocks deep; this is the same kind of stop every other expression walk in
/// this file uses, not a limit on what Rust can write.
const late_let_depth_max = 512;

/// Type every `let` the source declares without an initializer, from the
/// assignments that fill it.
///
/// `let mut byte;` is a real Rust declaration with a real type, and inference
/// already has it: `byte = buf[0]` emits an ordinary unification edge between
/// the assignment's target and its value, so the solver types every occurrence
/// of the binding and the `.ty` on those expressions is that type. What was
/// missing was the type ON THE DECLARATION — both the `let` statement and its
/// pattern carry a `ty`, and both were null, so a backend reading the binding
/// found a declaration it could not name.
///
/// Nothing is inferred here and nothing is defaulted. The recorded type is a
/// TypeId the solver already produced for this very binding, copied to the two
/// places a declaration is read from. A binding no assignment ever types — a
/// declaration the source itself annotates is already handled upstream, and an
/// assignment the compiler refused is not an assignment any more — keeps its
/// null type, exactly as before.
///
/// The cost is one pass over the expressions and one walk of each body, not a
/// walk per declaration: the typed-binding table is built once for the crate
/// and every declaration in every function reads from it.
fn typeLateInitializedBindings(
    g: *const graph.CrateGraph,
    b: *bodies.Bodies,
) std.mem.Allocator.Error!void {
    // Most crates declare none of these, and the answer costs one scan.
    var declared = false;
    for (b.stmts) |statement| switch (statement.kind) {
        .let => |ls| {
            if (ls.init == null and ls.ty == null) declared = true;
        },
        else => {},
    };
    if (!declared) return;

    var typed: std.AutoHashMapUnmanaged(exprs.DefId, TypedBinding) = .empty;
    defer typed.deinit(g.allocator);
    for (b.exprs) |expression| {
        const path = switch (expression.kind) {
            .path => |value| value,
            else => continue,
        };
        const ty = expression.ty orelse continue;
        const entity = g.symbol_table.get(path.def) orelse continue;
        try typed.put(g.allocator, path.def, .{ .name = entity.name, .ty = ty });
    }
    if (typed.count() == 0) return;

    var scope: LateLetScope = .{ .allocator = g.allocator };
    defer scope.deinit();
    for (b.bodies) |body| {
        const function = switch (body) {
            .fn_ => |value| value,
            else => continue,
        };
        if (function.body >= b.exprs.len) continue;
        const block = switch (b.exprs[function.body].kind) {
            .block => |value| value,
            else => continue,
        };
        try resolveLateLetsInBlock(b, block, &scope, &typed, 0);
    }
}

fn resolveLateLetsInBlock(
    b: *bodies.Bodies,
    block: exprs.BlockExpr,
    scope: *LateLetScope,
    typed: *const std.AutoHashMapUnmanaged(exprs.DefId, TypedBinding),
    depth: usize,
) std.mem.Allocator.Error!void {
    if (depth >= late_let_depth_max) return;
    const frame = scope.entries.items.len;
    // A block's own declarations leave scope with it, so an assignment below
    // cannot reach a binding declared inside a sibling block.
    defer scope.entries.shrinkRetainingCapacity(frame);
    for (block.statements) |statement| {
        if (statement >= b.stmts.len) continue;
        switch (b.stmts[statement].kind) {
            .let => |ls| {
                try declareLateLet(b, scope, frame, statement, ls);
                if (ls.init) |init| {
                    try resolveLateLetsInExpr(b, init, scope, typed, depth + 1);
                }
            },
            .let_else => |let_else| {
                try resolveLateLetsInExpr(b, let_else.init, scope, typed, depth + 1);
                try resolveLateLetsInBlock(b, let_else.else_block, scope, typed, depth + 1);
            },
            .expr => |expression| try resolveLateLetsInExpr(b, expression, scope, typed, depth + 1),
            .item => {},
        }
    }
    if (block.tail) |tail| try resolveLateLetsInExpr(b, tail, scope, typed, depth + 1);
}

/// Enter a `let` into the current block's frame.
///
/// A declaration WITH an initializer is the value of that name in this scope,
/// so it shadows whatever an earlier `let` of the same name declared, and the
/// shadowed entry goes: an assignment after this point belongs to the new
/// binding, not to the late-initialized one underneath it.
fn declareLateLet(
    b: *bodies.Bodies,
    scope: *LateLetScope,
    frame: usize,
    statement: exprs.NodeId,
    ls: exprs.LetStmt,
) std.mem.Allocator.Error!void {
    if (ls.pattern >= b.pats.len) return;
    const binding = switch (b.pats[ls.pattern].kind) {
        .binding => |value| value,
        else => return,
    };
    if (binding.name.len == 0) return;
    if (ls.init != null or ls.ty != null) {
        var index = scope.entries.items.len;
        while (index > frame) {
            index -= 1;
            if (!std.mem.eql(u8, scope.entries.items[index].name, binding.name)) continue;
            _ = scope.entries.orderedRemove(index);
            break;
        }
        return;
    }
    try scope.entries.append(scope.allocator, .{
        .name = binding.name,
        .pattern = ls.pattern,
        .statement = statement,
    });
}

/// Record the type the solver produced for a late-initialized binding on the
/// two nodes a declaration is read from.
///
/// `Bodies` keeps its tables as const slices, and this pass already rewrites
/// expression nodes through `@constCast` for the same reason: the tables are
/// the pipeline's to hand over, and a declaration's own type is filled in
/// here because nothing before the solve has one to fill in with.
fn recordLateLetType(
    b: *bodies.Bodies,
    pattern: exprs.NodeId,
    statement: exprs.NodeId,
    ty: exprs.TypeId,
) void {
    if (ty >= b.types.len) return;
    if (pattern < b.pats.len) @constCast(b.pats)[pattern].ty = ty;
    if (statement < b.stmts.len) @constCast(b.stmts)[statement].ty = ty;
}

fn resolveLateLetsInExpr(
    b: *bodies.Bodies,
    node: exprs.NodeId,
    scope: *LateLetScope,
    typed: *const std.AutoHashMapUnmanaged(exprs.DefId, TypedBinding),
    depth: usize,
) std.mem.Allocator.Error!void {
    if (node >= b.exprs.len or depth >= late_let_depth_max) return;
    switch (b.exprs[node].kind) {
        // `x = value` is what fixes a late-initialized binding: the solver has
        // already unified the target with the value, so the target's own type
        // is this binding's type and the compound forms need nothing more than
        // that either.
        .assign => |assign| {
            if (assign.op == .plain and assign.target < b.exprs.len) {
                if (b.exprs[assign.target].kind == .path) {
                    const def = b.exprs[assign.target].kind.path.def;
                    if (typed.get(def)) |found| {
                        var index = scope.entries.items.len;
                        while (index > 0) {
                            index -= 1;
                            const entry = scope.entries.items[index];
                            if (!std.mem.eql(u8, entry.name, found.name)) continue;
                            recordLateLetType(b, entry.pattern, entry.statement, found.ty);
                            break;
                        }
                    }
                }
            }
            // Either side may itself hold one: `*slot = { let n; n = 1; n }`
            // binds nothing late, but the block on the right owns one.
            try resolveLateLetsInExpr(b, assign.target, scope, typed, depth + 1);
            try resolveLateLetsInExpr(b, assign.value, scope, typed, depth + 1);
        },
        // Every position that can hold a `let` statement. The child set is the
        // one `exprs.NodeWalker` enqueues, so an assignment hiding in a call
        // argument, an iterator adapter's closure, a struct field's
        // initializer or an index base is found where the graph says it is —
        // while the scope stack this pass keeps is what a flat walk cannot
        // supply: a block's declarations still leave scope with it, and a
        // `let` WITH an initializer still shadows the late-initialized binding
        // of the same name underneath it.
        .block => |block| try resolveLateLetsInBlock(b, block, scope, typed, depth + 1),
        .if_else => |if_else| {
            try resolveLateLetsInExpr(b, if_else.cond, scope, typed, depth + 1);
            try resolveLateLetsInBlock(b, if_else.then_, scope, typed, depth + 1);
            try resolveLateLetsInElse(b, if_else.@"else", scope, typed, depth + 1);
        },
        .if_let => |if_let| {
            try resolveLateLetsInPattern(b, if_let.pattern, scope, typed, depth + 1);
            try resolveLateLetsInExpr(b, if_let.scrutinee, scope, typed, depth + 1);
            try resolveLateLetsInBlock(b, if_let.then_, scope, typed, depth + 1);
            try resolveLateLetsInElse(b, if_let.@"else", scope, typed, depth + 1);
        },
        .while_ => |while_| {
            try resolveLateLetsInExpr(b, while_.cond, scope, typed, depth + 1);
            if (while_.capture) |capture| {
                try resolveLateLetsInPattern(b, capture, scope, typed, depth + 1);
            }
            try resolveLateLetsInBlock(b, while_.body, scope, typed, depth + 1);
        },
        .loop_ => |loop_| try resolveLateLetsInBlock(b, loop_.body, scope, typed, depth + 1),
        .for_ => |for_| {
            try resolveLateLetsInPattern(b, for_.pattern, scope, typed, depth + 1);
            try resolveLateLetsInExpr(b, for_.iterable, scope, typed, depth + 1);
            try resolveLateLetsInBlock(b, for_.body, scope, typed, depth + 1);
            try resolveLateLetsInIterKind(b, for_.iter_kind, scope, typed, depth + 1);
        },
        .match => |match| {
            try resolveLateLetsInExpr(b, match.scrutinee, scope, typed, depth + 1);
            for (match.arms) |arm| {
                for (arm.patterns) |pattern| {
                    try resolveLateLetsInPattern(b, pattern, scope, typed, depth + 1);
                }
                if (arm.guard) |guard| try resolveLateLetsInExpr(b, guard, scope, typed, depth + 1);
                try resolveLateLetsInExpr(b, arm.body, scope, typed, depth + 1);
            }
        },
        .closure => |closure| try resolveLateLetsInClosure(b, closure, scope, typed, depth + 1),
        .iterator_chain => |chain| try resolveLateLetsInChain(b, chain, scope, typed, depth + 1),
        .break_ => |brk| {
            if (brk.value) |value| try resolveLateLetsInExpr(b, value, scope, typed, depth + 1);
        },
        .array => |array| {
            for (array.elements) |element| {
                try resolveLateLetsInExpr(b, element, scope, typed, depth + 1);
            }
        },
        .vec_lit => |vector| {
            for (vector.elements) |element| {
                try resolveLateLetsInExpr(b, element, scope, typed, depth + 1);
            }
            // The count of `vec![elem; count]` is an ordinary expression, so
            // a `let` bound inside it resolves here against the same enclosing
            // scope the element already sees. A `.literal` count is a number
            // with no node; `ArrayExpr` repeats keep their own `?u64` form.
            if (vector.repeat) |repeat| switch (repeat) {
                .literal => {},
                .expression => |count| try resolveLateLetsInExpr(b, count, scope, typed, depth + 1),
            };
        },
        .range => |range| {
            try resolveLateLetsInExpr(b, range.start, scope, typed, depth + 1);
            if (range.end) |end| try resolveLateLetsInExpr(b, end, scope, typed, depth + 1);
        },
        .call => |call| {
            for (call.args) |argument| {
                try resolveLateLetsInExpr(b, argument, scope, typed, depth + 1);
            }
        },
        .core_call => |call| {
            for (call.args) |argument| {
                try resolveLateLetsInExpr(b, argument, scope, typed, depth + 1);
            }
        },
        .method_call => |method| {
            try resolveLateLetsInExpr(b, method.receiver, scope, typed, depth + 1);
            for (method.args) |argument| {
                try resolveLateLetsInExpr(b, argument, scope, typed, depth + 1);
            }
        },
        .struct_lit => |literal| {
            for (literal.fields) |field| {
                try resolveLateLetsInExpr(b, field.value, scope, typed, depth + 1);
            }
            if (literal.base) |base| {
                try resolveLateLetsInExpr(b, base, scope, typed, depth + 1);
            }
        },
        .enum_variant => |variant| {
            for (variant.tuple_fields) |field| {
                try resolveLateLetsInExpr(b, field, scope, typed, depth + 1);
            }
            for (variant.named_fields) |field| {
                try resolveLateLetsInExpr(b, field.value, scope, typed, depth + 1);
            }
        },
        .external_variant => |variant| {
            for (variant.tuple_fields) |field| {
                try resolveLateLetsInExpr(b, field, scope, typed, depth + 1);
            }
            for (variant.named_fields) |field| {
                try resolveLateLetsInExpr(b, field.value, scope, typed, depth + 1);
            }
        },
        .format_write => |format_write| {
            try resolveLateLetsInExpr(b, format_write.writer, scope, typed, depth + 1);
            for (format_write.args) |argument| {
                try resolveLateLetsInExpr(b, argument, scope, typed, depth + 1);
            }
        },
        .field => |field| try resolveLateLetsInExpr(b, field.base, scope, typed, depth + 1),
        .index => |index| {
            try resolveLateLetsInExpr(b, index.base, scope, typed, depth + 1);
            try resolveLateLetsInExpr(b, index.index, scope, typed, depth + 1);
        },
        .cast => |cast| try resolveLateLetsInExpr(b, cast.operand, scope, typed, depth + 1),
        .binary => |binary| {
            try resolveLateLetsInExpr(b, binary.lhs, scope, typed, depth + 1);
            try resolveLateLetsInExpr(b, binary.rhs, scope, typed, depth + 1);
        },
        .unary => |unary| try resolveLateLetsInExpr(b, unary.operand, scope, typed, depth + 1),
        .try_ => |try_expr| try resolveLateLetsInExpr(b, try_expr.inner, scope, typed, depth + 1),
        .return_ => |ret| {
            if (ret.value) |value| try resolveLateLetsInExpr(b, value, scope, typed, depth + 1);
        },
        // A name, a literal, a type, or a recorded refusal holds no
        // statements.
        .path, .literal, .unit, .panic_, .continue_, .core_function, .unsupported => {},
    }
}

/// The `else` half of an `if` or an `if let`.
fn resolveLateLetsInElse(
    b: *bodies.Bodies,
    branch: exprs.ElseBranch,
    scope: *LateLetScope,
    typed: *const std.AutoHashMapUnmanaged(exprs.DefId, TypedBinding),
    depth: usize,
) std.mem.Allocator.Error!void {
    switch (branch) {
        .none => {},
        .block => |block| try resolveLateLetsInBlock(b, block, scope, typed, depth + 1),
        .chain => |chain| try resolveLateLetsInExpr(b, chain, scope, typed, depth + 1),
    }
}

fn resolveLateLetsInClosure(
    b: *bodies.Bodies,
    closure: exprs.ClosureExpr,
    scope: *LateLetScope,
    typed: *const std.AutoHashMapUnmanaged(exprs.DefId, TypedBinding),
    depth: usize,
) std.mem.Allocator.Error!void {
    for (closure.params) |parameter| {
        try resolveLateLetsInPattern(b, parameter, scope, typed, depth + 1);
    }
    try resolveLateLetsInBlock(b, closure.body, scope, typed, depth + 1);
}

/// One `core::iter` adapter. `map` / `filter` / `flat_map` carry a closure —
/// a block of statements like any other — and `zip` names a second iterable
/// written right here, so both can own a `let` no initializer reaches.
fn resolveLateLetsInAdapter(
    b: *bodies.Bodies,
    adapter: exprs.IteratorAdapter,
    scope: *LateLetScope,
    typed: *const std.AutoHashMapUnmanaged(exprs.DefId, TypedBinding),
    depth: usize,
) std.mem.Allocator.Error!void {
    switch (adapter) {
        .map => |map| try resolveLateLetsInClosure(b, map.closure, scope, typed, depth + 1),
        .filter => |filter| try resolveLateLetsInClosure(b, filter.closure, scope, typed, depth + 1),
        .flat_map => |closure| try resolveLateLetsInClosure(b, closure, scope, typed, depth + 1),
        .zip => |zip| try resolveLateLetsInExpr(b, zip.other, scope, typed, depth + 1),
        .enumerate, .range_rev, .other => {},
    }
}

fn resolveLateLetsInChain(
    b: *bodies.Bodies,
    chain: exprs.IteratorChainExpr,
    scope: *LateLetScope,
    typed: *const std.AutoHashMapUnmanaged(exprs.DefId, TypedBinding),
    depth: usize,
) std.mem.Allocator.Error!void {
    try resolveLateLetsInExpr(b, chain.source, scope, typed, depth + 1);
    for (chain.adapters) |adapter| {
        try resolveLateLetsInAdapter(b, adapter, scope, typed, depth + 1);
    }
}

fn resolveLateLetsInIterKind(
    b: *bodies.Bodies,
    kind: exprs.IterKind,
    scope: *LateLetScope,
    typed: *const std.AutoHashMapUnmanaged(exprs.DefId, TypedBinding),
    depth: usize,
) std.mem.Allocator.Error!void {
    switch (kind) {
        .range, .slice, .enumerate => {},
        .multi => |expressions| {
            for (expressions) |expression| {
                try resolveLateLetsInExpr(b, expression, scope, typed, depth + 1);
            }
        },
        .adapter => |chain| try resolveLateLetsInChain(b, chain, scope, typed, depth + 1),
    }
}

/// A pattern's own expressions. Only a range's bounds are written as code,
/// so that is the only place a `let` can hide inside a pattern — but the
/// sub-patterns are followed either way, because a range can sit inside any
/// of them.
fn resolveLateLetsInPattern(
    b: *bodies.Bodies,
    node: exprs.NodeId,
    scope: *LateLetScope,
    typed: *const std.AutoHashMapUnmanaged(exprs.DefId, TypedBinding),
    depth: usize,
) std.mem.Allocator.Error!void {
    if (node >= b.pats.len or depth >= late_let_depth_max) return;
    switch (b.pats[node].kind) {
        .range => |range| {
            if (range.lo) |lo| try resolveLateLetsInExpr(b, lo, scope, typed, depth + 1);
            if (range.hi) |hi| try resolveLateLetsInExpr(b, hi, scope, typed, depth + 1);
        },
        .tuple => |tuple| {
            for (tuple.elements) |element| {
                try resolveLateLetsInPattern(b, element, scope, typed, depth + 1);
            }
        },
        .slice => |slice| {
            for (slice.elements) |element| {
                try resolveLateLetsInPattern(b, element, scope, typed, depth + 1);
            }
            if (slice.rest) |rest| try resolveLateLetsInPattern(b, rest, scope, typed, depth + 1);
        },
        .struct_pat => |struct_pat| {
            for (struct_pat.fields) |field| {
                if (field.pat) |field_pattern| {
                    try resolveLateLetsInPattern(b, field_pattern, scope, typed, depth + 1);
                }
            }
        },
        .external_variant => |external_variant| {
            for (external_variant.fields) |field| {
                if (field.pat) |field_pattern| {
                    try resolveLateLetsInPattern(b, field_pattern, scope, typed, depth + 1);
                }
            }
        },
        .reference => |reference| {
            try resolveLateLetsInPattern(b, reference.inner, scope, typed, depth + 1);
        },
        .@"or" => |or_pattern| {
            for (or_pattern.alternatives) |alternative| {
                try resolveLateLetsInPattern(b, alternative, scope, typed, depth + 1);
            }
        },
        .wildcard, .binding, .literal, .path, .unsupported => {},
    }
}

/// Whether the receiver is one a crate-local blanket
/// `impl<T: AsRef<[u8]>> Trait for T` provides its method for, and the trait
/// it provides it from is the one the backend selects the impl by.
///
/// The impl provides the method for every type its bound admits, so the
/// receiver has to be one that bound admits. Two shapes are, and they are the
/// two the backend builds a self type for (`blanketReceiverType`), so the two
/// sides cannot disagree about what a blanket call is:
///
/// - An array, typed or not. The self type is the bound's element with the
///   receiver's own length.
/// - A type parameter an enclosing declaration bounded by a byte-sequence
///   `AsRef`: `fn encode<T: AsRef<[u8]>>(data: T) -> String { data.encode_hex() }`
///   is hex/src/lib.rs:259-261, and it is the shape a generic wrapper is
///   written in. There is no length and no element type to read here, and none
///   is invented — the hoisted method takes the parameter itself as its self
///   type, which is only right because the declaration says the parameter
///   implements `AsRef<[u8]>`.
///
/// A CARRIER around the parameter — `&T`, `*T`, `Box<T>`, an `impl Trait` —
/// is not one of the two, and is refused here rather than peeled. The backend
/// hands the receiver's own type to `blanketReceiverType` and builds a self
/// type only for an array or that bare path, so a peeled carrier would resolve
/// the call and then leave `receiver.encode_hex(..)` in the output: a Zig
/// member call on a slice, for a method Zig has no such field of. Refusing it
/// in this pass is what turns that into a diagnostic.
///
/// Anything else is not evidence that this blanket impl applies, so the call
/// keeps whatever reason its own dispatch earns.
///
/// `receiver_ty` is the type the call site already derived for this receiver;
/// `receiver_node` is kept for the owner lookup, which is about the scope the
/// receiver sits in rather than about its type.
fn blanketReceiver(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    receiver_node: exprs.NodeId,
    receiver: exprs.Expr,
    receiver_ty: ?types.Type,
) bool {
    if (blanketArrayReceiver(b, receiver)) return true;
    return blanketBoundedTypeParamReceiver(g, b, receiver_node, receiver_ty);
}

/// Whether the receiver is an array, the shape whose self type the backend
/// builds from the bound's element and the receiver's own length.
fn blanketArrayReceiver(b: *const bodies.Bodies, receiver: exprs.Expr) bool {
    if (receiver.kind == .array) return true;
    const type_id = receiver.ty orelse return false;
    if (type_id >= b.types.len) return false;
    return b.types[type_id] == .array;
}

/// Whether the receiver's declared type IS a type parameter that an enclosing
/// declaration bounded by a byte-sequence `AsRef`.
///
/// The declared type is read as it stands and never peeled, because the
/// backend does not peel it either: `blanketReceiverType` tests the receiver's
/// own type with `isTypeParameterPath`, which accepts a bare one-segment path
/// and nothing else. A `&T` that this pass peeled to `T` would be admitted
/// here and refused there, and a refused blanket call lowers to a member call
/// on the slice rather than to anything that names the missing conversion.
fn blanketBoundedTypeParamReceiver(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    receiver_node: exprs.NodeId,
    receiver_ty: ?types.Type,
) bool {
    const path = switch (receiver_ty orelse return false) {
        .path => |value| value,
        else => return false,
    };
    if (path.segments.len != 1) return false;
    const segment = path.segments[0];
    // A segment that names a declaration is not a type parameter. No
    // declaration is named `T`, so a bare name with no entity id is exactly
    // how the IR spells one — the same rule the backend's
    // `isTypeParameterPath` reads before it takes the parameter itself as
    // the self type, and the two must not disagree about which receivers are
    // parameters at all.
    if (segment.id != null or segment.name.len == 0) return false;
    const owner = expressionOwner(g, b, receiver_node, 0) orelse return false;
    return typeParamDeclaresByteAsRef(g, b, owner, segment.name);
}

/// How far a receiver's type parameter is looked for through the scopes that
/// enclose it. It bounds the walk so a malformed or cyclic entity table stops
/// it rather than looping, the way every other bounded walk in this pass does
/// (`receiver_unpeel_depth_max`, `expressionOwner`).
const generic_scope_depth_max: usize = 128;

/// Whether any scope enclosing `owner` declares a type parameter named
/// `param_name` whose own bounds include a byte-sequence `AsRef`.
///
/// A callable, an impl, and a trait are the scopes Rust lets such a bound be
/// written in, and they are the three `bodies.genericBound` reads for the
/// same walk. This pass reads them itself because the question is not which
/// trait a bound names but what it requires of its argument — `AsRef<[u8]>`,
/// not any `AsRef` — and `isByteSequenceAsRef` is the rule the blanket impl's
/// own side is read by, so the receiver and the impl it reaches are judged by
/// one rule rather than two.
fn typeParamDeclaresByteAsRef(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    owner: spine.EntityId,
    param_name: []const u8,
) bool {
    var current: ?spine.EntityId = owner;
    var remaining = generic_scope_depth_max;
    while (current) |id| {
        if (remaining == 0 or @as(usize, id) >= b.bodies.len) return false;
        remaining -= 1;
        const generics = switch (b.bodies[id]) {
            .fn_ => |function| function.generics,
            .impl_ => |implementation| implementation.generics,
            .trait_ => |trait_body| trait_body.generics,
            else => null,
        };
        if (generics) |parameters| {
            for (parameters.params) |parameter| {
                const type_param = switch (parameter) {
                    .type_ => |value| value,
                    else => continue,
                };
                if (!std.mem.eql(u8, type_param.name, param_name)) continue;
                for (type_param.bounds) |bound| {
                    if (isByteSequenceAsRef(bound)) return true;
                }
            }
            for (parameters.where_clauses) |clause| {
                if (clause.self_ty.segments.len != 1) continue;
                if (!std.mem.eql(u8, clause.self_ty.segments[0].name, param_name)) continue;
                for (clause.bounds) |bound| {
                    if (isByteSequenceAsRef(bound)) return true;
                }
            }
        }
        const entity = g.symbol_table.get(id) orelse return false;
        current = entity.parent;
    }
    return false;
}

/// The trait a crate-local blanket `impl<T: AsRef<[u8]>> Trait for T`
/// implements, when that impl declares `method_name`, or null when none does.
///
/// The answer is the TRAIT rather than the method because the trait is what
/// the backend selects the impl from. `blanketImplForMethod` is the one
/// classifier over a blanket call, and for a call whose method is the trait's
/// `method_ref` — the shape parenting that reference to the trait produces —
/// it reads the trait off the reference's own parent and hands it, together
/// with the method name, to `blanketImplFor`. That second step answers
/// `unique`, `none`, or `ambiguous` rather than picking between candidates,
/// which is the same refusal this function makes. The trait is taken from the
/// impl body's own `trait_path`, the same linkage the backend reads, so the
/// two cannot pick different traits. Two blanket impls providing the same
/// method name the method ambiguously and stay refused.
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
    // Every allocation this fixture makes — the entity names the graph owns and
    // the tables the pass grows — comes from one arena. `resolveMethods`
    // grows `b.types` through the graph allocator and hands back no handle to
    // free it with, which is the contract the pipeline's arena-backed graph
    // already meets and a bare testing allocator does not.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
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
    seg[0] = .{ .name = "Fletcher16", .id = null };

    const types_store = try allocator.alloc(types.Type, 2);
    types_store[0] = .{ .path = .{ .segments = seg } };
    types_store[1] = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } };

    const exprs_store = try allocator.alloc(exprs.Expr, 6);

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

// A `let` the source declares with no initializer is typed by the assignment
// that fills it. Here one such assignment sits inside the closure an
// `iter().map(..)` adapter carries, which the walk used to stop before — the
// adapter is neither a block nor a call shape the walk descended into — so
// the declaration reached the backend with no type at all.
//
// The two `y` bindings are declared with DIFFERENT types on purpose. A walk
// that ignored the closure's own scope would type both from one assignment,
// and the two numbers would be indistinguishable; here each declaration can
// only be right if it was reached from the assignment that fills it.
test "late bindings inside an iterator adapter closure are typed from their own scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    const y_def = try g.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try alloc.dupe(u8, "y"),
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // A second `let y` in a nested block is a SECOND binding, not the first
    // one written again: it gets its own entity, and only the NAME is what the
    // scope scan matches on. Sharing one id here would collapse the two
    // declarations into one in the typed-binding table itself.
    const y_inner_def = try g.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try alloc.dupe(u8, "y"),
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const types_store = try alloc.alloc(types.Type, 2);
    types_store[0] = .{ .prim = .u8 };
    types_store[1] = .{ .prim = .u32 };

    const closure_body: exprs.BlockExpr = .{
        .statements = &.{2},
        .tail = 6,
        .labelled = null,
    };
    const closure: exprs.ClosureExpr = .{
        .captures = &.{},
        .params = &.{},
        .return_ty = null,
        .body = closure_body,
        .trait = .@"fn",
    };
    const adapters = try alloc.alloc(exprs.IteratorAdapter, 1);
    adapters[0] = .{ .map = .{ .closure = closure } };

    const exprs_store = try alloc.alloc(exprs.Expr, 9);
    // The function body: `let y; y = 1u8; xs.map(|x| { let y; y = 2u32; y })`
    exprs_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{
            .statements = &.{ 0, 1 },
            .tail = 4,
            .labelled = null,
        } },
    };
    exprs_store[1] = .{
        .id = 1,
        .span = span,
        .ty = 0,
        .kind = .{ .path = .{ .def = y_def, .generic_args = &.{} } },
    };
    exprs_store[2] = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{ .assign = .{
            .target = 1,
            .op = .plain,
            .value = 3,
            .overflow = .checked,
        } },
    };
    exprs_store[3] = .{
        .id = 3,
        .span = span,
        .ty = 0,
        .kind = .{ .literal = .{ .int = .{
            .text = "1",
            .value = 1,
            .base = .dec,
            .ty_suffix = "u8",
        } } },
    };
    exprs_store[4] = .{
        .id = 4,
        .span = span,
        .ty = null,
        .kind = .{ .iterator_chain = .{
            .source = 5,
            .adapters = adapters,
            .terminal = .collect_vec,
        } },
    };
    exprs_store[5] = .{ .id = 5, .span = span, .ty = null, .kind = .{ .unit = {} } };
    exprs_store[6] = .{
        .id = 6,
        .span = span,
        .ty = null,
        .kind = .{ .assign = .{
            .target = 7,
            .op = .plain,
            .value = 8,
            .overflow = .checked,
        } },
    };
    exprs_store[7] = .{
        .id = 7,
        .span = span,
        .ty = 1,
        .kind = .{ .path = .{ .def = y_inner_def, .generic_args = &.{} } },
    };
    exprs_store[8] = .{
        .id = 8,
        .span = span,
        .ty = 1,
        .kind = .{ .literal = .{ .int = .{
            .text = "2",
            .value = 2,
            .base = .dec,
            .ty_suffix = "u32",
        } } },
    };

    const stmts_store = try alloc.alloc(exprs.Statement, 3);
    stmts_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .let = .{ .pattern = 0, .init = null, .ty = null } },
    };
    stmts_store[1] = .{ .id = 1, .span = span, .ty = null, .kind = .{ .expr = 2 } };
    stmts_store[2] = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{ .let = .{ .pattern = 1, .init = null, .ty = null } },
    };

    const pats_store = try alloc.alloc(exprs.Pattern, 2);
    for (pats_store, 0..) |*pattern, index| {
        pattern.* = .{
            .id = @intCast(index),
            .span = span,
            .ty = null,
            .kind = .{ .binding = .{
                .name = "y",
                .mode = .{ .value = {} },
                .mutable = true,
            } },
        };
    }

    const bodies_store = try alloc.alloc(bodies.BodyKind, 2);
    bodies_store[0] = .{ .none = {} };
    bodies_store[1] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 0,
    } };

    var b: bodies.Bodies = .{
        .exprs = exprs_store,
        .stmts = stmts_store,
        .pats = pats_store,
        .types = types_store,
        .bodies = bodies_store,
    };

    try typeLateInitializedBindings(&g, &b);

    try std.testing.expectEqual(@as(exprs.TypeId, 0), stmts_store[0].ty.?);
    try std.testing.expectEqual(@as(exprs.TypeId, 0), pats_store[0].ty.?);
    try std.testing.expectEqual(@as(exprs.TypeId, 1), stmts_store[2].ty.?);
    try std.testing.expectEqual(@as(exprs.TypeId, 1), pats_store[1].ty.?);
}
