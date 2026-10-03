//! translate_rust.backend.zig.documentation — where a Rust source's authored
//! documentation becomes the string the Zig AST carries.
//!
//! Two routes put a `///` block into a generated package, and only one of them
//! runs through this module.
//!
//!   1. Symbol-table entities and module rows. The frontend records the
//!      source's doc comment or `#[doc = "..."]` as an ordered list of `doc`
//!      attributes on the entity, or on the module row. `fromAttributes` joins
//!      that list, in the authored order, and does nothing else.
//!   2. Struct fields, enum variant tags and union fields. A source field has
//!      no entity of its own, so the frontend decodes its text once and stores
//!      it on the IR record itself (`ir.items.Field.documentation`). The
//!      lowering copies that string straight into `ast.StructField`,
//!      `ast.EnumVariant` and `ast.UnionField`. There is no `doc` attribute
//!      list for a field, so that text never passes through this module.
//!
//! This module invents no wording and infers no purpose. It writes no
//! ownership sentence and no allocator sentence either: the text it returns is
//! the authored part of the `///` block and nothing more. The ownership and
//! allocator contract an emitted callable carries — the `allocator` parameter,
//! a by-value runtime-owned parameter, an owned return type — is appended by
//! `lower.zig` after this function returns, and it is read off the signature
//! that was emitted. The sentence and the signature are therefore settled in
//! one place, and `documentation_test.zig` pins that correspondence against the
//! generated packages in `test/golden/zig_ast/`.
//!
//! What the generated packages actually carry, measured over the three
//! payloads in `test/golden/zig_ast/`: 198 public declarations, of which 189
//! carry documentation. The nine that do not are all re-exports or fields
//! rather than declarations this module is answerable for — five public
//! `const` declarations whose initializer only names another declaration (two
//! `@import` module roots, a `pub use` of `util::helper`, and the
//! `FromHexError` error set), and four public fields on `Point` and `Shape`
//! whose source wrote no comment. No public callable, struct, enum or union is
//! undocumented: `lower.zig` writes a fallback sentence for each of those
//! kinds, so the entity route always produces prose. A re-export deliberately
//! gets none, because the contract it would state is already stated at the
//! declaration it points at.

const std = @import("std");
const ir = @import("translate_rust.ir");

/// The attribute name the frontend and the IR wire format both use for
/// documentation, from a doc comment or from `#[doc = "..."]`. The frontend
/// records every one of them with `known = false`, because a comment and the
/// equivalent attribute are recorded identically, so `fromAttributes` reads
/// `name` and `meta` and ignores `known`.
pub const attribute_name = "doc";

/// Join the ordered `doc` attributes of a declaration into one documented
/// string. The authored order is preserved and the lines are separated by
/// `\n`, so the emitter can write one `///` per line.
///
/// Returns the empty string when nothing is documented. A non-empty result is
/// owned by `allocator`, and the caller frees it with that same allocator; the
/// empty result is a static slice with no owner, so freeing it is not the
/// caller's right. The result is the authored part of the `///` block only.
/// Any ownership or allocator sentence in the emitted block is the caller's
/// to add, from the emitted signature, after this returns.
///
/// Failure is only an allocation failure: an unreadable attribute list is not a
/// reason to invent documentation.
pub fn fromAttributes(
    allocator: std.mem.Allocator,
    attributes: []const ir.spine.Attribute,
) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var authored = false;

    for (attributes) |attribute| {
        if (!std.mem.eql(u8, attribute.name, attribute_name)) continue;
        // An attribute with no decoded text is documentation this translator
        // could not evaluate, such as `#[doc = concat!("a", "b")]`. It stays
        // recorded on the entity, but it contributes no prose here, and it does
        // not set `authored` either, so it cannot leave a blank line behind in
        // the emitted block either.
        if (attribute.meta.len == 0) continue;
        if (authored) try out.append(allocator, '\n');
        try out.appendSlice(allocator, attribute.meta);
        authored = true;
    }

    if (!authored) return "";
    return out.toOwnedSlice(allocator);
}
