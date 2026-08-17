# rustdoc JSON → wire-format mapping

Field-by-field map from the v0 sidecar dump (**RUSTDOC JSON**) to our lossless
semantic IR wire format. It is the contract for the *normalization algorithm*
(§6) a future Rust sidecar runs: rustdoc JSON in, `crate-<name>.json` out.

References:
- Shared spine and wire format: `notes/design/data-model.md` §2 (spine),
  §3.1 (node inventory), §4 (IR boundary & serialization).
- Crate/module graph, visibility, paths, symbol table:
  `notes/design/data-model/crate-graph.md` §1–3.
- v0/v1 scoping: `notes/design/data-model-plan.md` (P1, JSON boundary).
- Grounding artifact: `src/fixtures/model/mini-rustdoc.json`, produced by
  `tools/sidecar/rustdoc-json.sh` from `src/fixtures/model/mini`.
  Observed `format_version = 60` (rustc/rustdoc nightly, rustdoc-types-era).

The IR is **JSON-primary** (data-model.md §4): the sidecar dumps JSON, Zig
parses it with `std.json` into the spine structs. Every cross-reference in our
format is a dense IR-local `EntityId` into a `SymbolTable` (crate-graph §3.1);
rustdoc's opaque `DefId`s are never shipped to the emitter.

---

## 1. Top-level document

rustdoc emits one JSON object per crate. Observed keys (format 60):

| rustdoc key | type | → our field | notes |
|---|---|---|---|
| `format_version` | int | header `format_version` | 60 observed. Version gate; normalizer pins to it (data-model.md §4). |
| `crate_version` | string | `Crate.version` | `"0.1.0"` in mini. |
| `crate_id` | — | — | fixed `0` for the dumped crate; not modeled. |
| `root` | DefId | `Crate.root` (`ModuleId`) | DefId of the crate-root module; renumbered (§5). |
| `index` | `{DefId: Item}` | `SymbolTable` | the entity store; every DefId maps to one entity (crate-graph §3.1). |
| `paths` | `{DefId: QualifiedPath}` | `Entity.name`/`Path` | fully-qualified path per item; source for names and for `in_path` visibility. |
| `external_crates` | list | `Crate.deps` (deferred v1) | external deps graph; out of v1 scope (crate-graph §1.3). |
| `target` | string | — | host/triple; ignored. |
| `includes_private` | bool | — | true (we pass `--document-private-items`); asserts the private surface is present. |
| `has_stripped_items` | bool\|null | — | null here; if true, the dump is not lossless → refuse. |

---

## 2. Item skeleton → `Entity`

Every `index[DefId]` is an `Item`. Common fields map onto the shared spine
`Entity` (data-model.md §2; crate-graph §3.1):

| rustdoc field | type | → our `Entity` field | notes |
|---|---|---|---|
| `id` (DefId) | int | `Entity.id` (EntityId) | **renumbered**, never kept (crate-graph §3.1). |
| `name` | string\|null | `Entity.name` | `null` for anonymous nodes, e.g. `use` (name lives in `inner.use.name`). |
| `kind` (implied by `inner`) | union | `Entity.kind` | see §3. |
| `visibility` | string | `Entity.visibility` | see §4. |
| `span` | object | `Entity.span` (`Span`) | see §5. |
| `attrs` | list | `Entity.attributes` | `[{other:"#[...]"}]` → `Attribute{ name, meta, known }` (data-model.md §2). |
| `docs` | string\|null | — | doc comment; not in spine (kept only if a later layer wants it). |
| `links` | map | — | intra-doc link resolution; ignored for v1. |
| `deprecation`/`stability`/`const_stability` | object\|null | — | metadata, not in spine; preserved as attributes if needed. |
| `inner` | union | kind-specific `Entity` payload / sibling tables | see §3. |

`inner` is the kind-discriminating union; there is no literal `kind` string in
format 60 (older formats used a `kinds` array — see §3 note).

---

## 3. `inner` kind → `EntityKind`

`EntityKind` from data-model.md §2 / crate-graph §3.1. Mapping for the v1
surface present in mini:

| rustdoc `inner` variant | `EntityKind` | notes |
|---|---|---|
| `{ "module": {…} }` | `module` | `is_crate` true ⇒ root module (crate-graph §1.2). |
| `{ "struct": {…} }` | `struct_` | |
| `{ "enum": {…} }` | `enum_` | |
| `{ "union": {…} }` | `union_` | |
| `{ "function": {…} }` | `fn_` | |
| `{ "constant": {…} }` | `const_` | |
| `{ "static": {…} }` | `static_` | |
| `{ "trait": {…} }` | `trait_` | |
| `{ "impl": {…} }` | `impl_` | |
| `{ "typedef": {…} }` | `type_alias` | |
| `{ "use": {…} }` | `use_` | → `UseDecl` (crate-graph §3.4). |
| `{ "extern_crate": {…} }` | `extern_crate` | → `ExternCrate` (deferred v1). |
| `{ "macro": {…} }` | `macro_` | |
| `{ "struct_field": {…} }` | `field` | struct/method fields (data-model §3.2). |
| `{ "variant": {…} }` | `variant` | enum variants (data-model §3.2). |

> Format note: format 60's `inner` is a single-discriminant object. Earlier
> rustdoc JSON versions used a `kinds` array with a `"knd"` string like
> `"/crate/"`, `"/struct/"`, `"/enum/"`, `"/fn/"`, `"/module/"`, `"/import/"`.
> The normalizer reads whichever shape `format_version` implies; both reduce
> to the `EntityKind` table above.

---

## 4. Visibility strings → `Visibility`

`Visibility` is the 5-valued lattice from data-model.md §2 / crate-graph §2.1.
rustdoc serializes visibility as a string or a small object:

| rustdoc value | → our `Visibility` | notes |
|---|---|---|
| `"public"` | `.public` | `pub` (mini: crate root, `Point`, `Shape`, `area`, `origin`, `use`, `mod util`). |
| `"crate"` | `.crate_restricted` | `pub(crate)`. |
| `{ "restricted": { "path": "super" } }` | `.super_restricted` | `pub(super)`. |
| `{ "restricted": { "path": "<path>" } }` | `.in_path("<path>")` | `pub(in crate::foo)` — keep the path text (crate-graph §2.1). |
| `"default"` | `.private` | no modifier (mini: `Shape::Circle`/`Rect` variants). |

`pub use` (mini: `pub use util::helper;`): rustdoc `visibility == "public"`.
The normalizer sets `UseDecl.is_pub_export = true` for that case so the
emitter materializes `pub const helper = util.helper;` (crate-graph §2.3).

---

## 5. Span: rustdoc → `Span`

Our `Span` (spine.zig) is `{ start_line, start_col, end_line, end_col }`,
**1-based line/col** (data-model.md §2). rustdoc 60 emits:

```json
"span": {
  "filename": "src/lib.rs",
  "begin":  [10, 5],   // [line, col]
  "end":    [10, 15]   // [line, col]
}
```

Mapping:

| rustdoc field | → our field | notes |
|---|---|---|
| `span.begin[0]` (line) | `Span.start_line` | |
| `span.begin[1]` (col) | `Span.start_col` | |
| `span.end[0]` (line) | `Span.end_line` | |
| `span.end[1]` (col) | `Span.end_col` | |
| `span.filename` | (dropped) | ours store no file; the `Module.source_path` holds it (crate-graph §1.2). |

**Span normalization note (± conversion required).** rustdoc 60 spans are
line/col tuples, not byte offsets — matching our shape at a glance. But the
columns derive from rustc's *byte* spans and are **not on a uniform basis**;
observed on mini, `end` is exclusive for some nodes (`struct Point` →
`end [12,2]` past the closing `}` at col 1) while inclusive for others
(`Shape::Rect` variant → `end [16,37]` includes the trailing `,`). No single
inclusive/exclusive rule holds. The normalizer must therefore:
1. strip `filename` (→ `Module.source_path` / `Crate` root path);
2. canonicalize line/col to 1-based `u32`;
3. fix the `end`-column convention to whatever `Span` promises (extend by one
   col when our end is inclusive and rustdoc's was exclusive, and vice versa);
4. convert **to byte offsets only if a producer actually reports bytes** — the
   naive "rustdoc = byte offsets" assumption does **not** hold for format 60.
Pin the branch on `format_version` (data-model.md §4) because the span schema
is exactly the kind of thing that drifts between rustdoc versions.

---

## 6. Normalization algorithm (rustdoc JSON → our wire JSON)

Given a rustdoc crate dump (mini-rustdoc.json, `format_version` 60), the Rust
sidecar performs, in order:

1. **Gate on `format_version`.** Read the header. If the version is not one
   the normalizer supports, fail loudly (data-model.md §4). Refuse dumps with
   `has_stripped_items == true` (the model is lossless, data-model.md §1).
2. **Create the `SymbolTable`** (`CrateGraph.symbol_table`, crate-graph §3.1).
3. **Renumber DefIds → dense EntityIds.** Assign `0..N` in a stable traversal
   order (crate root first, then depth-first over `module.items`). Record the
   `DefId → EntityId` bijection for step 7. This is the canonical renumbering
   of crate-graph §3.1 / data-model.md §1.2 — no raw DefId survives.
4. **Synthesize the crate-root `Crate`** from `root` + `crate_version` +
   `[package] name`; create the root `Module` with `is_crate: true`.
5. **Walk `module.items` depth-first.** For each item: build `Entity`
   (kind from §3, name from §2, visibility from §4, attributes from `attrs`
   — keep unknown ones as `known: false`), normalize the span (§5), and set
   `parent` to the enclosing module's EntityId.
   - `module` → also record `ModuleKind` (root / inline / file / directory,
     from `source_path` vs inline body) and `Module.source_path` (crate-graph
     §1.2).
   - `use` → `UseDecl`: `kind` (plain / alias / glob from `inner.use.is_glob`
     and `name`), `local_name`, `is_pub_export` (visibility == public),
     `target` = resolved `EntityId` (crate-graph §3.4).
   - `struct_field`/`variant` → `field`/`variant` entities (data-model §3.2);
     variant `discriminant` carried into the enum body record.
6. **Emit our wire JSON**: `{ format_version, sidecar: "rustdoc-json", … }`
   header (data-model.md §4), the symbol table as flat `0..N` entities, and the
   crate/module graph referencing only EntityIds.
7. **Resolve `resolved`/`target` refs** from the step-3 bijection so every
   cross-reference is an EntityId, not a DefId (crate-graph §3.1).

Deferred to P2/P3 (not in this doc): type signatures, generics, fn bodies,
exprs, ownership — they attach per-EntityId tables keyed by the same spine
(data-model.md §3.2–3.4).

---

## 7. Reference: mini fixture observed shapes

Grounding from `src/fixtures/model/mini-rustdoc.json` (all items public unless
noted):

- root `index["69"]` → `module.is_crate=true`, items `[1,4,51,66,67,68]`;
  span `{lib.rs, [1,1]..[30,22]}`; attr `#[attr=NoStd]` (from `#![no_std]`).
- `1` `util` → file module (`src/util.rs`), `is_crate=false`, child `[0]`
  (`helper`).
- `4` `Point` → `struct_`, plain struct, fields `[2,3]` (`x`,`y` : `i32`).
- `51` `Shape` → `enum_`, variants `[47,50]` (`Circle` tuple / `Rect` struct).
- `66`/`67` → `fn_` `area(Shape)->f64`, `origin()->Point`.
- `68` → `use_`, `name:null`, `inner.use = { source:"util::helper",
  name:"helper", id:0, is_glob:false }`, visibility `"public"` ⇒
  `UseDecl{ is_pub_export: true }`.
