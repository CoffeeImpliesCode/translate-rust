# Data model: Crate & module graph

Design note for the **top of the lossless semantic IR** (approaches.md §1, box "IR")
of translate-rust (assignee: `CrateGraphModel`). This layer answers: *what is a crate,
how are its modules and files wired, what is visible where, and how do paths resolve to
those entities*. It is the spine every other layer (items, exprs, ownership) hangs off,
so its IDs must be the canonical handles the whole IR shares.

Scope boundary: this note models the *graph* and *resolution* skeleton. Item bodies
(struct/enum/fn details), expression/pattern lowering, and ownership live in the sibling
notes (`items-types.md`, `exprs-patterns.md`, `ownership-mem.md`) and reference the
`DefId`s defined here. Nothing here is a duplicate; this file deliberately stops at the
container/visibility/path plane.

---

## 1. Crate root + module graph

### 1.1 Producers do not decide the shape

The graph is produced by the semantic sidecar (approaches.md §2.5, parsing-tooling.md §4),
which may be `rustdoc --output-format json` (the cheap first milestone, no Rust host) or
later a `rustc_driver`/rust-analyzer sidecar. The sidecar dumps JSON; Zig parses it with
`std.json` and builds this graph. The graph must therefore be **JSON-primary**: every
stored link is an ID, and IDs resolve through a `SymbolTable`, so the emitter never walks
the Rust source again (parsing-tooling.md §2.5: rustdoc JSON is "a version of the Rust AST
... resolved types, spans, attributes, visibility"; `DefId`s are the keys).

rustdoc JSON already supplies, per crate: a `Crate` root node (`root: CrateId`), `Module`
items with `is_crate` + declared module items, `Import`/`Use`/`ExternCrate` items, spans,
attributes, and `visibility` on every item — all keyed by `DefId` and versioned by
`format_version` (parsing-tooling.md §2.5). The model below is a *normalization* of that
surface into a form the Zig emitter can consume without re-resolution.

### 1.2 Node kinds

A Rust crate is a tree of `Module`s rooted at the crate root (lib.rs / main.rs). Modules
arise three ways (idiom-mapping.md §1):

- **inline** — `mod foo { … }` (no separate file; body is inline in the parent's AST);
- **file** — `mod foo;` with body in `foo.rs` *or* `foo/mod.rs` (directory module);
- **root** — the crate root file itself.

`mod foo;` (file split) maps 1:1 to a Zig `@import("foo.zig")` file handle
(idiom-mapping.md §1: "`mod foo;` (file split) maps naturally to `@import("foo.zig")`"),
and the crate root is the Zig file that gets imported (idiom-mapping.md §1: "Rust crate
root ↔ Zig file that is `@import`ed"). The model must therefore record enough *physical*
information (source path, module kind) for the emitter to decide the Zig file layout —
but note Zig does **not** auto-discover files from a mod table: "the importer must name
the file" (idiom-mapping.md §1), so emission needs the resolved source path stored on the
node, not recovered at emit time.

```zig
pub const ModuleKind = enum {
    root,      // crate root file (lib.rs / main.rs)
    inline,    // mod foo { ... } — no file of its own
    file,      // mod foo; — body in foo.rs
    directory, // mod foo; — body in foo/mod.rs (mod.rs layout)
};

pub const Module = struct {
    id: ModuleId,          // = EntityId into SymbolTable
    kind: ModuleKind,
    name: []const u8,      // "" for root; "foo" for mod foo
    parent: ?ModuleId,     // null only for crate root / extern roots
    source_path: ?[]const u8, // file holding this module's items (for file/directory)
    is_crate: bool,        // the crate root
    is_extern: bool,       // root of an *external* crate (deps layer, deferred)
    span: Span,
    items: []const ItemId,      // owned top-level items (modules, structs, fns, ...)
    attributes: []const Attribute, // module-scope attrs (see §4)
};
```

The `items` slice is deliberately a flat list of child entity IDs, not nested inline
structs — this keeps the symbol table the single source of truth and lets the emitter
walk any subtree by ID. `parent` gives the inverse edge so `super::` paths can climb.

### 1.3 Multi-crate input

The top of the whole model is a `CrateGraph` (a workspace / dependency set), not a single
crate — because option (d)/(e) of approaches.md §2 fold dependencies into a translated
Zig workspace ("topological walk, leaf→root … Zig workspace of translated modules").
For v1 only one crate is translated (see §6), but the container already admits N roots so
the graph is not re-modeled when the deps layer lands.

```zig
pub const Crate = struct {
    id: CrateId,
    name: []const u8,          // crate name (rustdoc: `name`)
    edition: u16,              // 2015/2018/2021 (2024) — affects path resolution
    crate_type: CrateType,     // lib / bin (see §4)
    root: ModuleId,            // the crate-root Module
    deps: []const CrateDep,    // name → external CrateId (deferred for v1)
    attributes: []const Attribute,
    is_translated: bool,       // whether this crate is in the v1 translated subset
};

pub const CrateGraph = struct {
    crates: []const Crate,
    symbol_table: *SymbolTable, // global DefId → entity store (§3)
};
```

A `CrateDep` is just `{ extern_name: []const u8, local_alias: []const u8, id: CrateId }` —
recording both the dependency's own crate name and the `extern crate … as …` alias a
`use` can refer to it by.

### 1.4 Zig mapping contract (cross-ref idiom-mapping §1)

| Rust | IR → Zig |
|---|---|
| crate root (lib.rs) | the imported Zig file (`lib.zig`), one `pub const` "module handle" per file |
| `mod foo;` (file split) | `@import("foo.zig")` — importer names the file explicitly |
| `mod foo { … }` (inline) | folded flat into the parent file; no `@import`, nested decls in the container |
| module member | a `pub` decl in the Zig container (Zig default-private mirrors Rust) |
| `pub use` | *no* Zig re-export → materialized as a `pub const alias = target;` (see §2.3) |

The graph stores enough to make all four decisions; the emitter ("mod → @import")
lives in a later phase, not here.

---

## 2. Visibility & the pub surface

### 2.1 The visibility enum

Rust visibility is a 5-valued lattice; Zig is binary (pub/private). The model keeps the
full Rust lattice losslessly (the IR is lossless; approaches.md §1) and reduces to the
Zig binary at emit time with a per-item decision. Keywords (idiom-mapping §1: "`pub` in
Zig defaults everything to private unless `pub`") means a Rust `pub` maps to a Zig `pub`
and Rust-private maps to Zig-private only when the string is emitted at all.

```zig
pub const Visibility = union(enum) {
    public,             // pub — fully exported
    crate_restricted,   // pub(crate)
    super_restricted,   // pub(super)
    in_path: []const u8,// pub(in crate::foo::bar) — the named path
    private,            // no modifier
};
```

`pub(in path)` keeps the path *text* here and defers it to the `Path` resolver (§3);
the emitter must resolve it to confirm the item is still reachable from the export root
and otherwise fold it to whatever the enclosing Zig container exposes.

### 2.2 Export surface computation

The *exported API surface* of a module is the set of items transitively reachable from
the crate root through `public` (and, within `pub(crate)`, through crate-visible) edges —
this is exactly what rustdoc JSON's public-API slice captures (parsing-tooling.md §2.5:
"a per-crate JSON dump of the public API"). The model records visibility per item and the
graph walk that computes the surface is a query, not stored state, so a later `pub`
change doesn't corrupt a cached set:

```zig
// Query helper (computed lazily; not stored in JSON):
pub fn exportedSurface(graph: *const CrateGraph, mod_id: ModuleId) []const ItemId
```

`#[doc(hidden)]` / `#[non_exhaustive]`-style doc-gating is out of this axis (it is an
entities-layer attribute; see §4), except that the attribute is *stored* on the item so
the surface query can optionally honor it.

### 2.3 `pub use` re-exports

`pub use util::helper;` has no direct Zig equivalent (idiom-mapping §1: "Zig HAS no
re-export alias => re-declare"). The model's `UseDecl` (with `is_pub_export: true`) is
the *source*; the *emitter* turns it into `pub const helper = util.helper;`. The IR does
not pre-fold the re-export into a duplicate decl — it keeps the `UseDecl` so the model
retains which name is an alias vs a real definition, and the surface query treats an
exporting `UseDecl` as a real edge in the graph (its target becomes part of the surface).

Example (idiom-mapping §1):
```
lib.rs:  pub mod util;  pub use util::helper;
util.zig: pub fn helper() void {}
lib.zig: pub const util = @import("util.zig");
         pub const helper = util.helper;   // synthesized from pub use — stored as UseDecl
```

---

## 3. Paths, name resolution, and the symbol table

### 3.1 The SymbolTable — DefId-keyed entity store

rustdoc JSON keys everything by an opaque per-invocation `DefId` (parsing-tooling §2.5:
"IDs are `DefId`s that are opaque and not stable across invocations"). The IR therefore
cannot ship raw DefIds to the emitter; it normalizes them into a dense local `EntityId`
backed by a symbol table, and the JSON simply numbers them 0..N without ever dereferencing
a foreign DefId. This is the same "rustdoc's DefId" role the shared contract names, but
rebased onto IR-local IDs so the emitter is sidecar-version-independent.

```zig
pub const EntityId = u32;   // dense, IR-local index into symbol_table.entities

pub const EntityKind = enum {
    crate_, module, struct_, enum_, union_, fn_, const_,
    static_, trait_, impl_, type_alias, use_, extern_crate, macro_, field, variant,
};

pub const Entity = struct {
    id: EntityId,
    kind: EntityKind,
    name: []const u8,          // definition site name (pre-rename; §3.3)
    span: Span,
    visibility: Visibility,
    parent: ?EntityId,         // containing module/impl/union
    resolved: ?EntityId,       // if a use/alias: the target def it resolves to
    renamed_to: ?[]const u8,   // §3.3 — name actually emitted in Zig
    attributes: []const Attribute,
    // kind-specific payloads are NOT here; they live in the items/exprs layers,
    // indexed by the same EntityId (a registry seam, not an inline union).
};

pub const SymbolTable = struct {
    entities: std.AutoHashMap(EntityId, Entity),
};
```

By keeping every entity in one table with a `parent` edge and a `resolved` slot, *paths,
shadowing, and re-exports all collapse into pointer-chasing on `EntityId`*, and the other
layers can attach their own per-kind tables keyed by the same ID without duplicating the
common spine.

### 3.2 Paths

A `Path` is an ordered list of segments plus, after resolution, a terminal target.

```zig
pub const PathPrefix = union(enum) {
    crate_, self_, super_, extern: []const u8, // extern crate name
};

pub const Path = struct {
    prefix: ?PathPrefix,        // null → relative to current scope in simpler cases
    segments: []const []const u8, // foo, bar, baz in crate::foo::bar::baz
    resolution: ?EntityId,        // filled by the resolve pass; null = unresolved
};

pub const PathKind = enum { absolute, relative, super }; // classification for emitter
```

Resolution semantics (as the resolve pass must produce, grounded in the Rust name rules
the sidecar already ran): `crate::` → descend from the crate root module; `super::` →
climb `parent`; `self::` → current module; a bare leading segment → an in-scope `use`
alias (resolved via `UseDecl`), an item in the current module, or an `extern crate`
name. The IR stores both the written `Path` (for diagnostics) and its `resolution`
(the EntityId everything downstream uses) — never emitting a path by re-parsing text.

### 3.3 Shadowing and renames (`collect_renames`, `@"name"`)

rust2zig's `collect_renames` pass exists because "Zig rejects shadowing across all
nested scopes; but siblings are independent" (prior-work §1), and keyword collisions are
escaped as `@"name"` (prior-work §1, idiom-mapping §1). The IR captures this in two
slots on `Entity`:

- `renamed_to`: when a name would collide in Zig or is a Zig keyword, the emitter writes
  `@"<renamed_to>"`; stored so emission is deterministic (a rename is a *decision* made
  once by the same pass rust2zig calls `collect_renames`, not rediscovered per emit).
- Sibling-scope independence: `SymbolTable` scoping is hierarchical (`parent` edges), so
  two `Entity`s that Rust may shadow in nested scopes are kept distinct; the rename pass
  only rewrites when the *Zig target container* actually collides.

The keyword-escape set (Zig reserved words) is a fixed table the sidecar/IR marks:
`fn`, `struct`, `enum`, `union`, `return`, `var`, `const`, `if`, `else`, `while`, `for`,
`switch`, `break`, `continue`, `defer`, `errdefer`, `try`, `catch`, `orelse`, `and`,
`or`, `not`, `null`, `true`, `false`, `undefined`, `comptime`, `inline`, `noalias`,
`volatile`, `export`, `pub`, `extern`, `asm`, `await`, `suspend`, `resume`, `async`,
`anyframe`, `error`, `opaque`, `usingnamespace`, `test`, `threadlocal`, `fn` → `@"fn"`.
The full table lives with the emitter; the IR only stores `renamed_to` results.

### 3.4 `UseDecl` and `ExternCrate`

```zig
pub const UseKind = union(enum) {
    plain: EntityId,        // use a::b::C;  → target
    alias: EntityId,        // use a::b as X; → target, local name X
    glob,                   // use a::b::*;  → marked; emitter must enumerate
};

pub const UseDecl = struct {
    id: EntityId,
    kind: UseKind,
    local_name: []const u8,     // name binding into the current scope
    is_pub_export: bool,        // `pub use` → §2.3 re-export
    target: EntityId,           // the resolved definition
    span: Span,
};

pub const ExternCrate = struct {
    id: EntityId,
    crate_id: CrateId,          // which external crate (deferred for v1)
    alias: []const u8,          // extern crate foo as bar; → bar is what paths see
};
```

A `glob` use (`use a::b::*;`) has no fixed target set at resolution time (it depends on
the target module's full surface); the IR marks it as `glob` and the surface/enumeration
query (§2.2) expands it lazily, so diagnostics and the export walk stay honest instead of
silently dropping the star-import.

---

## 4. Crate/module attributes relevant to translation

Attributes are stored generically (name + optional argument token tree / string), not as
a closed union, so the model never silently fails on an unseen attribute. This axis only
*classifies* the ones that gate or change translation:

```zig
pub const Attribute = struct {
    name: []const u8,           // "cfg", "no_std", "crate_type", ...
    arg: ?AttributeArg,         // string, path list, or token tree
    span: Span,
};

pub const AttributeArg = union(enum) {
    none,
    string: []const u8,         // #[path = "…"], #[crate_type = "lib"]
    list: []const []const u8,   // #[cfg(target_os = "linux", …)] flattened
    raw: []const u8,            // uninterpreted token tree retained losslessly
};
```

Semantic reads for translation:

- **`#[no_std]` / `#[no_implicit_prelude]`** — determines the prelude model. The IR
  records `no_std: bool` on the crate (computable from its attributes); v1 *requires*
  `no_std` (approaches §2.5), so a `std` crate gets a crisp "unsupported: std prelude"
  marker (§6) rather than a half-translation.
- **`#[cfg(...)]` / `#[cfg_attr(...)]`** — the model **stores** every cfg verbatim
  (lossless) and does **not** pre-select an active set at IR-build time, because the
  active set depends on target/features that are orthogonal to the graph. Selection is a
  query (`isActive(graph, cfg, target)`) applied by the surface walk; a cfg-gated item
  that is inactive is reported via the `unsupported` marker path, not silently dropped
  (§6, deferred cfg matrix).
- **`#[crate_type]` / `#[crate_name]`** — folded into `Crate.crate_type` / `Crate.name`
  (or inferred from the file/Cargo metadata).
- **`#[path = "…"]`** — overrides the module source path; folded into
  `Module.source_path`.
- **`#[doc(hidden)]`, `#[non_exhaustive]`** — stored on the entity as attributes; the
  surface query may honor them; the entities layer lowers `non_exhaustive` to a
  synthesized catch-all arm (idiom-mapping §3). Not this axis's decision — recorded here,
  lowered elsewhere.

**Unsupported marker.** Every node carries `unsupported: ?Unsupported` (or the graph
collects an `UnsupportedSet` keyed by EntityId). Explicit, never a silent omission
(shared contract; idiom-mapping's v1-blocker discipline). For the crate axis:

```zig
pub const Unsupported = union(enum) {
    std_prelude,        // crate not no_std
    async_,             // crate has async/await at graph root gates
    dyn_trait,          // dyn Trait anywhere in a pushed surface
    proc_macro,         // crate is a proc-macro crate
    workspace_dep,      // references a dep not in the translated subset
    cfg_gated,          // item inactive under the current cfg target
};
```

---

## 5. Concrete Zig shapes + JSON encoding

### 5.1 Reference Zig structs (recap)

`Crate`, `Module`, `Visibility`, `Path`, `UseDecl`, `ExternCrate`, `Attribute`,
`SymbolTable`/`Entity` are defined in §1.1–§4. They are all `std.json`-serializable
value types; the JSON *encoding shape* is specified next so the sidecar can emit it
without knowing Zig's struct layout.

### 5.2 JSON encoding — tagged

One JSON document per crate (`crate-graph.json`), shape:

```json
{
  "format_version": 1,
  "crate": {
    "id": 0,
    "name": "leaf",
    "edition": 2021,
    "crate_type": "lib",
    "no_std": true,
    "root": 1,
    "deps": []
  },
  "modules": [
    { "id": 1, "kind": "root", "name": "", "parent": null,
      "source_path": "src/lib.rs", "is_crate": true, "items": [2, 3] },
    { "id": 2, "kind": "file", "name": "util", "parent": 1,
      "source_path": "src/util.rs", "is_crate": false, "items": [4] }
  ],
  "entities": [
    { "id": 4, "kind": "fn", "name": "helper", "parent": 2, "visibility": "public",
      "span": { "line": 1, "col": 1 }, "renamed_to": null }
  ],
  "uses": [
    { "id": 6, "kind": "alias", "local_name": "helper",
      "is_pub_export": true, "target": 4 }
  ],
  "renames": { "7": "and_" }
}
```

Encoding rules (lossless, explicit):
- **Tagged unions** as `{ "kind": …, …fields }` — `visibility`, `use.kind`, `module.kind`,
  `attribute.arg`, `path.prefix` all follow this; the Zig deserializer switches on `kind`
  into the corresponding `union(enum)` variant.
- **IDs** are integers; `null` = `?T` optional. `parent: null` marks a root.
- **Entities table** carries the common spine; per-kind detail is split across the
  sibling layers' own ID-keyed tables in the same document (e.g. a `"fns"` array) — the
  graph axis commits to the *document shape* and the shared `id` namespace, not to
  inlining bodies.
- **`renames`** is an ID→string map in addition to `renamed_to` slots, so the collector
  pass can be verified whole-file before any emit touches an entity.

### 5.3 Round-trip property

`std.json.parseFromSlice` → graph → `stringify` must reproduce the document (modulo field
order) — the model is the lossless IR contract, so deserialization is tested against a
golden `crate-graph.json` fixture (the repo already keeps JSON-fixture-diff discipline
per prior-work §1 rust2zig golden-file testing).

---

## 6. v1-subset delimitation

**In scope for v1 (the no_std leaf crate, approaches §2.5):**
- a **single** crate root (`lib.rs`/`main.rs`), `CrateGraph` with exactly one translated
  `Crate`; the container admits N but v1 fills one.
- `no_std` required (`no_std: true`); a `std` crate → `unsupported.std_prelude`, refuse.
- module graph: inline `mod`, `mod foo;` file split (foo.rs *and* foo/mod.rs), crate root.
- visibility: `public`, `private`; `pub(crate)`, `pub(super)`, `pub(in path)` parsed and
  stored, but v1 emission only guarantees `public`/`private` correct (the restricted
  forms reduce to pub/private conservatively); `pub use` re-exports materialized as
  `pub const` aliases.
- paths: `crate::`, `self::`, `super::`, `use … as …` aliases, `extern crate` *names*
  (no actual external dep translation — a referenced external crate must be absent or in
  the boundary, else `unsupported.workspace_dep`).
- shadowing + renames: `collect_renames`-style pass + keyword `@"name"` escaping.
- attributes: stored generically; `#[no_std]`, `#[crate_type]`, `#[crate_name]`,
  `#[path]` honored.

**Deferred (recorded, not silently dropped — each maps to an `Unsupported` on the node):**
- **deps graph / workspace**: multi-crate folding, `zir`-style workspace emission,
  topological leaf→root walk (approaches §2.4) → `workspace_dep`.
- **cfg matrix**: active-set selection across target/features; v1 stores cfg but treats a
  cfg-gated item conservatively (either include or `cfg_gated`); full target matrix
  deferred.
- **proc-macro crates** and any crate whose root uses them → `proc_macro` (approaches
  §2.6: macros are a front-end decision; v1 restricts to macro-free).

These are hard contract boundaries, not TODOs: the `Unsupported` marker makes every
refusal observable in diagnostics (shared contract: "never silent omission").

---

## 7. Open design questions

1. **Sidecar of record for the graph:** rustdoc JSON (parsing-tooling §2.5) gives
   mod/use/crate/visibility/spans for the *public* API but needs `--document-private-items`
   for a full graph and ships opaque per-invocation `DefId`s; rust-analyzer SCIP (per
   rust2zig) gives occurrence→symbol maps but no module tree. Which source should the
   sidecar normalize first for the *complete* (public+private) crate graph, and do we
   accept rustdoc's nightly flag as the v1 graph producer?
2. **ID stability across sidecar invocations:** `DefId`s are "opaque and not stable across
   invocations" (parsing-tooling §2.5). Is the IR's dense renumbering (this note's §3.1)
   sufficient, or do we need a stable content-addressed entity key so a diff tool (and the
   differential test harness, prior-work §1) can correlate two sidecar runs?
3. **Where does the rename pass run:** should `collect_renames` and keyword-`@"…"` escaping
   execute inside the semantic sidecar (writing `renamed_to` into the IR, making emission
   deterministic) or inside the Zig emitter (keeping the IR pure Rust names)? This decides
   whether the IR is "names as Rust wrote them + explicit renames" or "names as Zig emits
   them" — it changes every downstream consumer of `Entity.name`.
