# Data model: the Rust crate IR — unified design

Authoritative reference for the lossless semantic IR of translate-rust.
Four detail notes define each axis in depth; this file fixes the shared
spine, the cross-cutting decisions, and the v1 subset. Read the detail notes
for the full struct shapes and JSON encodings:

| Axis | Detail note |
|---|---|
| Crate & module graph, visibility, paths, symbol table | `data-model/crate-graph.md` |
| Items (struct/enum/union/fn/impl/trait) + types + generics | `data-model/items-types.md` |
| Expressions, statements, patterns + Zig-lowering hooks | `data-model/exprs-patterns.md` |
| Ownership, borrowing, Drop, allocator, unsoundness markers | `data-model/ownership-mem.md` |

Position in the pipeline (approaches.md §1): `parse → resolve → expand →
lower → **IR (this model)** → desugar → analyse → emit → zig fmt → verify`.

---

## 1. Contract

- **JSON-primary.** The semantic sidecar (rustdoc JSON first, later
  rust-analyzer SCIP / rustc_driver) dumps JSON; Zig parses it with `std.json`
  into these structs. The model is lossless over the translated surface.
- **Canonical ID.** Every entity is a dense IR-local `EntityId = u32` into a
  `SymbolTable`, replacing the sidecar's opaque per-invocation `DefId`
  (parsing-tooling §2.5). All cross-references are `EntityId`s; nothing
  re-resolves source text. `parent` + `resolved` edges make paths/shadowing/
  re-exports pointer-chases.
- **Shared spine.** Every node carries `id: EntityId` + `span: Span` (line/col);
  expressions additionally carry `ty: ?TypeId` (see §3.2).
- **Span on every node** for diagnostics, mirroring translate-c's span mapping.
- **Lossless but gated.** The model is *designed* for the full Rust surface;
  finite unsupported forms are first-class `Unsupported` nodes with a reason —
  never silent omission.
- **Monomorphization by record, not copy.** Generic decls are kept once;
  call sites reference an `Instantiation` record (generic decl + concrete args).
  No body duplication.
- **Zig 0.16 targets** (the model feeds the emitter): comptime generics,
  `union(enum)` tagged unions, error unions, optionals, explicit allocators,
  `extern struct`/`enum(uN)` for FFI.

---

## 2. Shared spine (the cross-axis types)

```zig
pub const Span = struct { start_line: u32, start_col: u32, end_line: u32, end_col: u32 };

pub const EntityId = u32;   // dense index into SymbolTable.entities
pub const TypeId = u32;     // dense index into crate.type_table

pub const EntityKind = enum {
    crate_, module, struct_, enum_, union_, fn_, const_, static_,
    trait_, impl_, type_alias, use_, extern_crate, macro_, field, variant,
};

pub const Entity = struct {
    id: EntityId,
    kind: EntityKind,
    name: []const u8,          // definition-site name (pre-rename)
    span: Span,
    visibility: Visibility,    // crate-graph §2.1
    parent: ?EntityId,         // containing module/impl/union
    resolved: ?EntityId,       // if use/alias: target definition
    renamed_to: ?[]const u8,   // emitted name if renamed / keyword-escaped @"name"
    attributes: []const Attribute,
};

pub const Visibility = union(enum) {
    public, crate_restricted, super_restricted, in_path: []const u8, private,
};

pub const Attribute = struct {
    name: []const u8,          // e.g. "repr", "no_mangle", "non_exhaustive", "derive"
    meta: []const u8,          // raw args, preserved losslessly
    known: bool,               // does the emitter understand + act on it?
};

pub const Unsupported = struct { reason: enum { ... }, message: []const u8, span: Span };
```

`known` on `Attribute` is the escape hatch: unknown attributes survive as
comments at emit, never dropped (items-types §2).

---

## 3. Node inventory (by axis — detailed shapes in the detail notes)

### 3.1 Crate & module graph — `data-model/crate-graph.md`
- `CrateGraph { crates, symbol_table }`; `Crate { id, name, edition, crate_type, root: ModuleId, deps, attributes, is_translated }`.
- `Module { id, kind (root/inline/file/directory), name, parent, source_path, is_crate, is_extern, span, items, attributes }`.
- `UseDecl { kind (plain/alias/glob), local_name, is_pub_export, target }`; `ExternCrate`.
- `Path { prefix, segments, resolution }`.
- `pub use` → not pre-folded; stored as exporting `UseDecl`, the emitter
  materializes `pub const alias = target;` (Zig has no re-export).

### 3.2 Items & types — `data-model/items-types.md`
- `Item` (tagged union): struct (named/tuple/unit → `struct`/`extern struct`),
  enum (C-like → `enum(uN)`, data-carrying → `union(enum)`, recursive → `*T` via
  allocator, `non_exhaustive` → synthesized else arm), union (`extern`/packed),
  fn (receivers → explicit `self: *const Self`/`*Self`), const/static, alias,
  impl (inherent + trait; associated items), trait decl, `extern "C"` block.
- `Type` (tagged union): paths, primitives (incl. never/unit), references
  (`&T`→`*const T`, `&mut T`→`*T`, `&[T]`→`[]const T`), raw pointers, slices,
  arrays, tuples, fn-ptr, generic instantiations, **plus dedicated
  `option`/`result`/`boxed`/`str`/`coll` nodes** so the emitter forks on
  Zig optional/error-union/allocator/slice.
- Generics: `GenericParam` (type/const/lifetime) + `Instantiation` records;
  type/const params → comptime; lifetimes retained as diagnostics, erased at emit.

### 3.3 Expressions, statements, patterns — `data-model/exprs-patterns.md`
- Shared node spine: `id, span, ty`.
- `Expr` (tagged union): literals, path, block, if/if-let, match (with
  `option_scrutinee`), loop/while/for (`IterKind`), labelled break/continue,
  calls (free/assoc/ctor), method calls with `ReceiverMode`, field/index,
  binary/unary/assign with explicit **Overflow mode** (checked/wrapping/saturating),
  `try_`, `return_`, closure/iterator seams, `Unsupported`.
- `Pattern` (post match-ergonomics): wildcard, binding, literal, path, tuple,
  slice, struct, ref, or, range; guards on `MatchArm` (deferred v1).
- `Statement`: let, let-else, expr, nested item.
- Closures/iterators: **sealed as seams** now (`ClosureExpr`→callable struct
  with `.call`; iterator chain → explicit for-loop), so v2/v3 add arms, not shapes.

### 3.4 Ownership, borrowing, Drop, allocator — `data-model/ownership-mem.md`
- `Ownership` banner per site (move/copy/move_drop + owner ref): the emitter
  knows re-read legality + drop suppression even though Zig enforcement is gone.
- `ParamShape { BorrowKind (owned/shared/mutable/slice_const/slice_mut), zig_ty }`.
- Lifetimes erased for emission; `lifetime_uses` records aliasing edges (Roc
  proved borrowck catches UAFs Zig w/ ReleaseSafe misses).
- `DropInfo` + `DropStrategy`: v1 **defer-only**; defer+errdefer + LIFO-reversed
  order later.
- `AllocatorUse { AllocatorSource (param/field/global_arena) }` — explicit
  threads.
- `UnsoundMarker { category, severity, message, span }` — flags every point
  ReleaseSafe does not reproduce borrow safety; emits `UNSOUND` comment, hardened
  `@panic` guard, or hard refusal — never silent.

---

## 4. IR boundary & serialization

- Wire format: **JSON**, tagged unions encoded with a single discriminant key
  and valid-identifier tag strings; reserved-word tags renamed
  (`if_else`, `loop_`, `try_`, `return_`) (exprs-patterns §6).
- A JSON header carries `{ format_version, sidecar, toolchain }` (versioning;
  rustdoc `format_version` analog). `EntityId`s are just 0..N in the JSON.
- v1 consumer: one `crate-<name>.json` per resource; Zig `std.json` parse →
  model structs.
- **Future non-JSON formats** (TOML etc.): use **serde.zig**, not hand-rolled
  parsers (AGENTS.md / project preference).

---

## 5. v1 subset (enforced by `Unsupported`, never silent)

In: a single translated **no_std leaf crate** with structs (named/tuple/unit),
C-like + data-carrying enums (incl. Option), fns, generics → comptime, Result
`?` → `try` (finite error sets), Box via scoped allocator + `defer` Drop,
inline/file/directory modules, pub/private + `pub use`, `crate::`/`self::`/
`super::`/use-alias paths, renames + keyword-escape.

Out (explicit `Unsupported`/seam, not built): dyn Trait, Rc/Arc/RefCell,
path-sensitive Drop (alive-flag), custom iterators/closures, async, proc/derive
macros (beyond `assert!`/`panic!`/`println!`), `catch_unwind`, workspace/deps
graph, cfg matrix.

Reference: idiom-mapping §19; each detail note's "v1 subset" section.

---

## 6. Design decisions still open (gate implementation)

1. **Semantic sidecar first**: rustdoc JSON (cheap, but public-API only + needs
   `--document-private-items`, nightly) vs rust-analyzer SCIP (private items,
   occurrence maps, no module tree). crate-graph.md §7.
2. **Option/Result/Box representation**: sidecar resolves inner type (simpler
   emitter, assumes std identity) vs store raw path + Zig recognises
   `core::option::Option`. items-types.md §7.
3. **Overflow default** when no build-mode intent is recorded (checked → Zig `+`
   vs wrapping → Zig `+%`): needs a crate-level IR-header default or a hard
   sidecar annotation. exprs-patterns.md §7.
4. **Allocator threading**: harness-owned `global_arena` vs thread `.param`
   from v1 (avoids v2 signature rewrites). ownership-mem.md §7 Q2.
5. **EntityId stability**: IR-local renumbering (simple) vs content-addressed
   keys (diffing/CI-stable). crate-graph.md §7 Q2.
6. **dyn Trait / Rc-RefCell strategy** for v2+: vtable-struct synthesis vs
   continued exclusion.

Consensus defaults (safe unless overridden): (1) rustdoc JSON for v0/v1;
(2) sidecar resolves inner types; (3) **checked** default with a crate-level
header override + sidecar annotation when known; (4) thread `.param` from the
start where the model already threads allocators; (5) IR-local renumbering +
keep `format_version`; (6) defer both, seal the seams.

**Decision 1 supersedes for v2+**: the rustdoc sidecar is a v0/v1 stopgap. The
endgame is a self-contained Zig producer — tree-sitter parses source, a Zig
type-inference engine fills every `Expr.ty` and resolves methods/traits/
generics — so translate-rust depends on no Rust toolchain. See
`source-model-type-inference.md` (plan). This IR (the `types.Type` table, the
`exprs/` code tables, `Instantiation` records) is the producer-neutral contract
both the sidecar and the inference engine target unchanged.
