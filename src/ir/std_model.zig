//! translate_rust.ir.std_model — pre-built semantic model for Rust standard library
//! (core, alloc, std) traits and primitive wrappers.
//!
//! Provides `initStdModel` to register standard library traits and types into a
//! CrateGraph's SymbolTable so method resolution, trait bounds, and type checking
//! can reference standard entities without external compiler sidecars.

const std = @import("std");
const spine = @import("spine.zig");
const graph = @import("graph.zig");
const bodies = @import("bodies.zig");
const types = @import("types.zig");

fn externalPathIs(actual: []const []const u8, wanted: []const []const u8) bool {
    if (actual.len != wanted.len) return false;
    for (actual, wanted) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

/// Standard constructors emitted through runtime intrinsics rather than an
/// external source module. These calls keep the catalog's declared signature.
pub const StdConstructor = enum { string_new };

/// One parameter of a known standard-library associated function.
const StdAssocParam = struct { name: []const u8, ty_param: []const u8 };

/// An associated function of a standard-library type, recorded with the
/// signature the standard library actually declares.
///
/// An entity in the graph carries a signature, and a wrong one is worse than
/// no entity at all: the backend checks arity against `params` and reads the
/// declared return when inferring the call. A placeholder would be a fabricated
/// fact, not an admission. So only the functions this table names are admitted,
/// and only with the signature it gives. Anything else keeps the refusal it
/// already has — a typed `unsupported`, which is accurate — until its real
/// declaration is known.
///
/// `std::io::Cursor::new` is, verbatim from the standard library:
/// `impl<T> Cursor<T> { pub const fn new(inner: T) -> Cursor<T> }`.
pub const StdAssocFn = struct {
    owner: []const []const u8,
    /// The other standard spellings of that same declaration. `std::vec::Vec`
    /// and `alloc::vec::Vec` are one item the standard library publishes under
    /// both roots, and a source may write either. Keeping the aliases beside
    /// the signature is what lets both spellings reach ONE declaration instead
    /// of two that could answer differently.
    owner_aliases: []const []const []const u8 = &.{},
    name: []const u8,
    type_params: []const []const u8,
    params: []const StdAssocParam,
    ret_owner: []const []const u8,
    ret_args: []const []const u8,
    constructor: ?StdConstructor = null,
};

const std_assoc_fns = [_]StdAssocFn{
    .{
        .owner = &.{ "std", "io", "Cursor" },
        .name = "new",
        .type_params = &.{"T"},
        .params = &.{.{ .name = "inner", .ty_param = "T" }},
        .ret_owner = &.{ "std", "io", "Cursor" },
        .ret_args = &.{"T"},
    },
    // `impl<R: Read> BufReader<R> { pub fn new(inner: R) -> BufReader<R> }`,
    // verbatim. `R` is the reader the buffer wraps, so `BufReader::new(data)`
    // hands back a `BufReader` over exactly the argument's own type — which is
    // what makes `fill_buf` and `consume` on the result the same two
    // `std::io::BufRead` methods `runtime_io_methods` admits on any other
    // `BufRead`-bounded receiver.
    .{
        .owner = &.{ "std", "io", "BufReader" },
        .name = "new",
        .type_params = &.{"R"},
        .params = &.{.{ .name = "inner", .ty_param = "R" }},
        .ret_owner = &.{ "std", "io", "BufReader" },
        .ret_args = &.{"R"},
    },
    // `impl<T> Vec<T> { pub const fn new() -> Vec<T> }`, verbatim. The element
    // type is not an argument here — `Vec::new()` takes none — so `T` is the
    // element the surrounding position fixes, and this declares the call with
    // that parameter open rather than inventing one.
    .{
        .owner = &.{ "alloc", "vec", "Vec" },
        .owner_aliases = &.{&.{ "std", "vec", "Vec" }},
        .name = "new",
        .type_params = &.{"T"},
        .params = &.{},
        .ret_owner = &.{ "alloc", "vec", "Vec" },
        .ret_args = &.{"T"},
    },
    // `impl String { pub const fn new() -> String }`, verbatim. A `String`
    // carries no type parameter, so this one is declared with its whole
    // signature and the call it builds is typed at extraction.
    .{
        .owner = &.{ "alloc", "string", "String" },
        .owner_aliases = &.{&.{ "std", "string", "String" }},
        .name = "new",
        .type_params = &.{},
        .params = &.{},
        .ret_owner = &.{ "alloc", "string", "String" },
        .ret_args = &.{},
        .constructor = .string_new,
    },
    // `impl<K, V> HashMap<K, V> { pub fn new() -> HashMap<K, V> }`, verbatim.
    // The key and the value are the ones the surrounding position fixes, for
    // the same reason `Vec::new` leaves its element open.
    .{
        .owner = &.{ "std", "collections", "HashMap" },
        .name = "new",
        .type_params = &.{ "K", "V" },
        .params = &.{},
        .ret_owner = &.{ "std", "collections", "HashMap" },
        .ret_args = &.{ "K", "V" },
    },
};

/// The known signature for `Owner::assoc`, or null when this function is not
/// one this translator can declare. Matching is on the RESOLVED owner path, so
/// a crate's own `Cursor` is never claimed by the standard library's, and a
/// standard name published under both roots reaches the one declaration it is.
pub fn findStdAssocFn(owner_path: []const []const u8, assoc_name: []const u8) ?*const StdAssocFn {
    for (&std_assoc_fns) |*entry| {
        if (!std.mem.eql(u8, entry.name, assoc_name)) continue;
        if (!externalPathIs(entry.owner, owner_path)) {
            var published_under = false;
            for (entry.owner_aliases) |alias| {
                if (!externalPathIs(alias, owner_path)) continue;
                published_under = true;
                break;
            }
            if (!published_under) continue;
        }
        return entry;
    }
    return null;
}

/// Match the canonical external module chain, not a source module with the
/// same basename. Graph module rows and symbol entity IDs are distinct.
fn standardAssociatedModule(
    g: *const graph.CrateGraph,
    parent: spine.EntityId,
    owner_path: []const []const u8,
) bool {
    var current: ?spine.EntityId = parent;
    var remaining = owner_path.len - 1;
    while (remaining > 0) {
        remaining -= 1;
        const entity_id = current orelse return false;
        const module = g.moduleForEntity(entity_id) orelse return false;
        if (!module.is_extern or !std.mem.eql(u8, module.name, owner_path[remaining])) return false;
        current = module.parent;
    }
    return current == null;
}

/// Classify a standard associated constructor from its external owner and
/// catalog signature. This never claims a source `String::new`, and does not
/// create an import or an allocation. The call keeps its declared return type.
pub fn standardConstructor(
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    def: spine.EntityId,
) ?StdConstructor {
    const entity = g.symbol_table.get(def) orelse return null;
    if (entity.kind != .fn_ or def >= b.bodies.len) return null;
    if (entity.renamed_to) |renamed| {
        if (!std.mem.eql(u8, renamed, entity.name)) return null;
    }
    const declared = switch (b.bodies[def]) {
        .fn_ => |value| value,
        else => return null,
    };
    const result = switch (declared.ret) {
        .external_nominal => |value| value,
        else => return null,
    };
    const known = findStdAssocFn(result.path, entity.name) orelse return null;
    const constructor = known.constructor orelse return null;
    if (!externalPathIs(result.path, known.ret_owner) or result.args.len != known.ret_args.len or
        declared.params.len != known.params.len or declared.generic_params.len != known.type_params.len or
        declared.is_allocating) return null;
    if (declared.generics) |generics| {
        if (generics.params.len != known.type_params.len or generics.where_clauses.len != 0) return null;
    }
    const parent = entity.parent orelse return null;
    if (standardAssociatedModule(g, parent, known.owner)) return constructor;
    for (known.owner_aliases) |alias| {
        if (standardAssociatedModule(g, parent, alias)) return constructor;
    }
    return null;
}

pub const TraitInfo = struct {
    name: []const u8,
    methods: []const []const u8 = &.{},
};

pub const TypeInfo = struct {
    name: []const u8,
    kind: spine.EntityKind,
    variants: []const []const u8 = &.{},
    methods: []const []const u8 = &.{},
};

/// Core standard library traits.
pub const std_traits: []const TraitInfo = &.{
    .{
        .name = "Clone",
        .methods = &.{ "clone", "clone_from" },
    },
    .{
        .name = "Copy",
        .methods = &.{},
    },
    .{
        .name = "Default",
        .methods = &.{"default"},
    },
    .{
        .name = "Hash",
        .methods = &.{"hash"},
    },
    .{
        .name = "Hasher",
        .methods = &.{
            "finish",     "write",       "write_u8",   "write_u16",
            "write_u32",  "write_u64",   "write_u128", "write_usize",
            "write_i8",   "write_i16",   "write_i32",  "write_i64",
            "write_i128", "write_isize",
        },
    },
    .{
        .name = "BuildHasher",
        .methods = &.{"build_hasher"},
    },
    .{
        .name = "BuildHasherDefault",
        .methods = &.{ "default", "build_hasher" },
    },
    .{
        .name = "Iterator",
        .methods = &.{
            "next",       "count",      "last",      "nth",
            "step_by",    "chain",      "zip",       "map",
            "filter",     "filter_map", "enumerate", "peekable",
            "skip_while", "take_while", "skip",      "take",
            "scan",       "flat_map",   "fuse",      "inspect",
            "by_ref",     "collect",    "fold",      "all",
            "any",        "find",       "position",  "rposition",
            "max",        "min",
        },
    },
    .{
        .name = "IntoIterator",
        .methods = &.{"into_iter"},
    },
    .{
        .name = "Display",
        .methods = &.{"fmt"},
    },
    .{
        .name = "Debug",
        .methods = &.{"fmt"},
    },
};

/// Core standard library types.
pub const std_types: []const TypeInfo = &.{
    .{
        .name = "Option",
        .kind = .enum_,
        .variants = &.{ "None", "Some" },
        .methods = &.{
            "is_some",            "is_none",           "as_ref",
            "as_mut",             "expect",            "unwrap",
            "unwrap_or",          "unwrap_or_default", "map",
            "map_or",             "map_or_else",       "ok_or",
            "ok_or_else",         "and_",              "and_then",
            "filter",             "or_",               "or_else",
            "xor",                "insert",            "get_or_insert",
            "get_or_insert_with", "take",              "replace",
            "copied",             "cloned",
        },
    },
    .{
        .name = "Result",
        .kind = .enum_,
        .variants = &.{ "Ok", "Err" },
        .methods = &.{
            "is_ok",       "is_err",            "ok",
            "err",         "as_ref",            "as_mut",
            "map",         "map_err",           "map_or",
            "map_or_else", "and_",              "and_then",
            "or_",         "or_else",           "unwrap",
            "unwrap_or",   "unwrap_or_default", "expect",
            "expect_err",  "unwrap_err",
        },
    },
    .{
        .name = "String",
        .kind = .struct_,
        .variants = &.{},
        .methods = &.{
            "new",        "with_capacity", "from_utf8",     "as_str",
            "as_bytes",   "as_mut_str",    "into_bytes",    "push",
            "push_str",   "clear",         "len",           "is_empty",
            "capacity",   "reserve",       "shrink_to_fit", "truncate",
            "pop",        "remove",        "retain",        "insert",
            "insert_str", "split_off",
        },
    },
    .{
        .name = "Vec",
        .kind = .struct_,
        .variants = &.{},
        .methods = &.{
            "new",               "with_capacity", "as_slice",    "as_mut_slice",
            "as_ptr",            "as_mut_ptr",    "capacity",    "reserve",
            "shrink_to_fit",     "truncate",      "push",        "pop",
            "insert",            "remove",        "swap_remove", "retain",
            "dedup",             "len",           "is_empty",    "clear",
            "extend_from_slice",
        },
    },
    .{
        .name = "Box",
        .kind = .struct_,
        .variants = &.{},
        .methods = &.{
            "new", "pin", "leak", "into_raw", "from_raw",
        },
    },
    .{
        .name = "HashMap",
        .kind = .struct_,
        .variants = &.{},
        .methods = &.{
            "new",                      "with_capacity",
            "with_capacity_and_hasher", "with_hasher",
            "insert",                   "get",
            "get_mut",                  "get_key_value",
            "get_key_ptr",              "contains_key",
            "contains_value",           "remove",
            "remove_entry",             "len",
            "is_empty",                 "clear",
            "entry",                    "entry_or_default",
            "keys",                     "values",
            "values_mut",               "iter",
            "iter_mut",                 "into_iter",
            "extend",                   "reserve",
            "retain",                   "capacity",
            "shrink_to_fit",            "get_or_insert",
        },
    },
    .{
        .name = "HashSet",
        .kind = .struct_,
        .variants = &.{},
        .methods = &.{
            "new",                      "with_capacity",
            "with_capacity_and_hasher", "with_hasher",
            "insert",                   "contains",
            "remove",                   "take",
            "replace",                  "get_or_insert",
            "len",                      "is_empty",
            "clear",                    "iter",
            "into_iter",                "extend",
            "reserve",                  "retain",
            "union",                    "intersection",
            "difference",               "symmetric_difference",
            "is_subset",                "is_superset",
            "is_disjoint",              "capacity",
            "shrink_to_fit",
        },
    },
};

const zero_span: spine.Span = .{
    .start_line = 0,
    .start_col = 0,
    .end_line = 0,
    .end_col = 0,
};

/// Populates standard library traits and types into the CrateGraph symbol table.
pub fn initStdModel(allocator: std.mem.Allocator, g: *graph.CrateGraph) !void {
    std.debug.assert(g.symbol_table.count() >= 0);

    // Register standard traits.
    for (std_traits) |t| {
        const trait_name = try allocator.dupe(u8, t.name);
        errdefer allocator.free(trait_name);

        const trait_id = try g.symbol_table.add(.{
            .id = 0,
            .kind = .trait_,
            .name = trait_name,
            .span = zero_span,
            .visibility = .public,
            .parent = null,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
        });

        // Register associated trait methods.
        for (t.methods) |m_name| {
            const method_name = try allocator.dupe(u8, m_name);
            errdefer allocator.free(method_name);

            _ = try g.symbol_table.add(.{
                .id = 0,
                .kind = .fn_,
                .name = method_name,
                .span = zero_span,
                .visibility = .public,
                .parent = trait_id,
                .resolved = null,
                .renamed_to = null,
                .attributes = &.{},
            });
        }
    }

    // Register standard types.
    for (std_types) |ty| {
        const type_name = try allocator.dupe(u8, ty.name);
        errdefer allocator.free(type_name);

        const type_id = try g.symbol_table.add(.{
            .id = 0,
            .kind = ty.kind,
            .name = type_name,
            .span = zero_span,
            .visibility = .public,
            .parent = null,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
        });

        // Register enum variants if applicable.
        for (ty.variants) |v_name| {
            const var_name = try allocator.dupe(u8, v_name);
            errdefer allocator.free(var_name);

            _ = try g.symbol_table.add(.{
                .id = 0,
                .kind = .variant,
                .name = var_name,
                .span = zero_span,
                .visibility = .public,
                .parent = type_id,
                .resolved = null,
                .renamed_to = null,
                .attributes = &.{},
            });
        }

        // Register inherent methods.
        for (ty.methods) |m_name| {
            const method_name = try allocator.dupe(u8, m_name);
            errdefer allocator.free(method_name);

            _ = try g.symbol_table.add(.{
                .id = 0,
                .kind = .fn_,
                .name = method_name,
                .span = zero_span,
                .visibility = .public,
                .parent = type_id,
                .resolved = null,
                .renamed_to = null,
                .attributes = &.{},
            });
        }
    }
}

/// Find an entity in the symbol table with matching name.
pub fn findEntity(g: *const graph.CrateGraph, name: []const u8) ?spine.Entity {
    for (g.symbol_table.entities.items) |ent| {
        if (std.mem.eql(u8, ent.name, name)) {
            return ent;
        }
    }
    return null;
}

/// Find a trait entity in the symbol table with matching name.
pub fn findTrait(g: *const graph.CrateGraph, name: []const u8) ?spine.Entity {
    for (g.symbol_table.entities.items) |ent| {
        if (ent.kind == .trait_ and std.mem.eql(u8, ent.name, name)) {
            return ent;
        }
    }
    return null;
}

/// Find a type entity (struct, enum, union, type_alias) with matching name.
pub fn findType(g: *const graph.CrateGraph, name: []const u8) ?spine.Entity {
    for (g.symbol_table.entities.items) |ent| {
        const is_type = switch (ent.kind) {
            .struct_, .enum_, .union_, .type_alias => true,
            else => false,
        };
        if (is_type and std.mem.eql(u8, ent.name, name)) {
            return ent;
        }
    }
    return null;
}

/// Find a child method of an entity by parent EntityId and method name.
pub fn findMethod(g: *const graph.CrateGraph, parent_id: spine.EntityId, method_name: []const u8) ?spine.Entity {
    for (g.symbol_table.entities.items) |ent| {
        if (ent.kind == .fn_ and ent.parent == parent_id and std.mem.eql(u8, ent.name, method_name)) {
            return ent;
        }
    }
    return null;
}

test "initStdModel populates standard traits" {
    const allocator = std.testing.allocator;
    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();

    try initStdModel(allocator, &g);

    // Verify all traits are retrievable by name
    const expected_traits = [_][]const u8{
        "Clone",
        "Copy",
        "Default",
        "Hash",
        "Hasher",
        "BuildHasher",
        "BuildHasherDefault",
        "Iterator",
        "IntoIterator",
        "Display",
        "Debug",
    };

    for (expected_traits) |trait_name| {
        const maybe_trait = findTrait(&g, trait_name);
        try std.testing.expect(maybe_trait != null);
        const trait_ent = maybe_trait.?;
        try std.testing.expectEqual(spine.EntityKind.trait_, trait_ent.kind);
        try std.testing.expectEqualStrings(trait_name, trait_ent.name);
        try std.testing.expectEqual(spine.Visibility.public, trait_ent.visibility);
    }

    // Verify Clone has clone method
    const clone_ent = findTrait(&g, "Clone").?;
    const clone_fn = findMethod(&g, clone_ent.id, "clone");
    try std.testing.expect(clone_fn != null);
    try std.testing.expectEqual(spine.EntityKind.fn_, clone_fn.?.kind);

    // Verify Iterator has next and map methods
    const iter_ent = findTrait(&g, "Iterator").?;
    try std.testing.expect(findMethod(&g, iter_ent.id, "next") != null);
    try std.testing.expect(findMethod(&g, iter_ent.id, "map") != null);
    try std.testing.expect(findMethod(&g, iter_ent.id, "fold") != null);
}

test "initStdModel populates standard types" {
    const allocator = std.testing.allocator;
    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();

    try initStdModel(allocator, &g);

    // Verify Option enum & methods & variants
    const maybe_opt = findType(&g, "Option");
    try std.testing.expect(maybe_opt != null);
    const opt_ent = maybe_opt.?;
    try std.testing.expectEqual(spine.EntityKind.enum_, opt_ent.kind);
    try std.testing.expect(findMethod(&g, opt_ent.id, "is_some") != null);
    try std.testing.expect(findMethod(&g, opt_ent.id, "unwrap") != null);

    // Verify Result enum & methods & variants
    const maybe_res = findType(&g, "Result");
    try std.testing.expect(maybe_res != null);
    const res_ent = maybe_res.?;
    try std.testing.expectEqual(spine.EntityKind.enum_, res_ent.kind);
    try std.testing.expect(findMethod(&g, res_ent.id, "is_ok") != null);
    try std.testing.expect(findMethod(&g, res_ent.id, "map_err") != null);

    // Verify String struct & methods
    const maybe_str = findType(&g, "String");
    try std.testing.expect(maybe_str != null);
    const str_ent = maybe_str.?;
    try std.testing.expectEqual(spine.EntityKind.struct_, str_ent.kind);
    try std.testing.expect(findMethod(&g, str_ent.id, "push_str") != null);
    try std.testing.expect(findMethod(&g, str_ent.id, "as_bytes") != null);

    // Verify Vec struct & methods
    const maybe_vec = findType(&g, "Vec");
    try std.testing.expect(maybe_vec != null);
    const vec_ent = maybe_vec.?;
    try std.testing.expectEqual(spine.EntityKind.struct_, vec_ent.kind);
    try std.testing.expect(findMethod(&g, vec_ent.id, "push") != null);
    try std.testing.expect(findMethod(&g, vec_ent.id, "pop") != null);

    // Verify Box struct & methods
    const maybe_box = findType(&g, "Box");
    try std.testing.expect(maybe_box != null);
    const box_ent = maybe_box.?;
    try std.testing.expectEqual(spine.EntityKind.struct_, box_ent.kind);
    try std.testing.expect(findMethod(&g, box_ent.id, "new") != null);

    // Hash containers: registered so method resolution can see the
    // `HashMap`/`HashSet` surface a translated crate calls. The lowering
    // keeps the `BuildHasher` the source named, so `insert`/`get` must stay
    // resolvable by name, not be erased as "unknown std type".
    const maybe_map = findType(&g, "HashMap");
    try std.testing.expect(maybe_map != null);
    const map_ent = maybe_map.?;
    try std.testing.expectEqual(spine.EntityKind.struct_, map_ent.kind);
    try std.testing.expect(findMethod(&g, map_ent.id, "insert") != null);
    try std.testing.expect(findMethod(&g, map_ent.id, "get") != null);
    try std.testing.expect(findMethod(&g, map_ent.id, "entry") != null);

    const maybe_set = findType(&g, "HashSet");
    try std.testing.expect(maybe_set != null);
    const set_ent = maybe_set.?;
    try std.testing.expectEqual(spine.EntityKind.struct_, set_ent.kind);
    try std.testing.expect(findMethod(&g, set_ent.id, "insert") != null);
    try std.testing.expect(findMethod(&g, set_ent.id, "contains") != null);
}

test "findEntity returns null for nonexistent symbol" {
    const allocator = std.testing.allocator;
    var g = graph.CrateGraph.init(allocator);
    defer g.deinit();

    try initStdModel(allocator, &g);

    try std.testing.expect(findEntity(&g, "NonExistentSymbol12345") == null);
    try std.testing.expect(findTrait(&g, "NonExistentTrait") == null);
    try std.testing.expect(findType(&g, "NonExistentType") == null);
}

test "standard String constructor requires its external module and exact catalog signature" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    // Leave an unrelated entity before the module rows: entity IDs are not
    // dense module-row indices.
    const root: spine.EntityId = 1;
    const module: spine.EntityId = 2;
    const constructor: spine.EntityId = 3;
    const declarations = [_]struct { kind: spine.EntityKind, name: []const u8, parent: ?spine.EntityId }{
        .{ .kind = .struct_, .name = "Unrelated", .parent = null },
        .{ .kind = .module, .name = "alloc", .parent = null },
        .{ .kind = .module, .name = "string", .parent = root },
        .{ .kind = .fn_, .name = "new", .parent = module },
    };
    for (declarations) |declaration| {
        _ = try g.symbol_table.add(.{
            .id = 0,
            .kind = declaration.kind,
            .name = try a.dupe(u8, declaration.name),
            .span = zero_span,
            .visibility = .public,
            .parent = declaration.parent,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
        });
    }
    _ = try g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "alloc",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = true,
        .span = zero_span,
        .items = &.{module},
        .attributes = &.{},
    });
    _ = try g.addModule(.{
        .id = 0,
        .kind = .@"inline",
        .name = "string",
        .parent = root,
        .source_path = null,
        .is_crate = false,
        .is_extern = true,
        .span = zero_span,
        .items = &.{constructor},
        .attributes = &.{},
    });
    const string: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "String" },
        .args = &.{},
    } };
    var body_store = [_]bodies.BodyKind{ .none, .none, .none, .{ .fn_ = .{
        .params = &.{},
        .ret = string,
        .body = 0,
    } } };
    const b: bodies.Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &body_store,
    };
    try std.testing.expectEqual(
        StdConstructor.string_new,
        standardConstructor(&g, &b, constructor).?,
    );
    g.modules.items[0].is_extern = false;
    try std.testing.expect(standardConstructor(&g, &b, constructor) == null);
    g.modules.items[0].is_extern = true;
    g.modules.items[1].is_extern = false;
    try std.testing.expect(standardConstructor(&g, &b, constructor) == null);
    g.modules.items[1].is_extern = true;
    body_store[constructor].fn_.ret = .{ .prim = .u8 };
    try std.testing.expect(standardConstructor(&g, &b, constructor) == null);
    body_store[constructor].fn_.ret = string;
    body_store[constructor].fn_.params = &.{.{ .name = "input", .ty = string, .span = zero_span }};
    try std.testing.expect(standardConstructor(&g, &b, constructor) == null);
    body_store[constructor].fn_.params = &.{};
    body_store[constructor].fn_.generic_params = &.{"T"};
    try std.testing.expect(standardConstructor(&g, &b, constructor) == null);
    body_store[constructor].fn_.generic_params = &.{};
    body_store[constructor].fn_.is_allocating = true;
    try std.testing.expect(standardConstructor(&g, &b, constructor) == null);
    body_store[constructor].fn_.is_allocating = false;
    g.symbol_table.entities.items[constructor].renamed_to = "not_new";
    try std.testing.expect(standardConstructor(&g, &b, constructor) == null);
}
