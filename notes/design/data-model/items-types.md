# Data Model — Items & Types

Lossless semantic IR of translate-rust (Zig 0.16). Covers **items (declarations)** and
**types**. Siblings: `crate-graph.md` (modules/DefId symbol table), `exprs-patterns.md`
(expressions/patterns), `ownership-mem.md` (Box/Rc/slices/memory).

- Producer: Rust semantic sidecar (rust-analyzer SCIP / rustdoc JSON, parsing-tooling.md §4).
- Consumer: Zig emitter over `std.json`.
- Hard contract: **lossless** round-trip; unsupported forms carry an explicit
  `unsupported` marker, never silent omission (approaches.md §2.5 "refused at parse time").

---

## 0. Shared spine

Every node carries the common header (symbol table owned by crate-graph.md). `Span`
mirrors tree-sitter line/col (src/rust.zig); translate-c maps spans for diagnostics
(parsing-tooling.md §1a).

```zig
pub const Id = struct { krate: u32, local: u32 };   // DefId-like, unique per decl
pub const Span = struct { start: Pos, end: Pos };
pub const Pos  = struct { line: u32, col: u32 };    // 1-based
pub const Vis  = enum { pub, crate_, priv_ };
```

JSON convention: every record carries an explicit `"kind"` discriminant + payload —
exactly how Zig `union(enum)` serializes under `std.json`, so the structs below round-trip
directly.

---

## 1. Items

Header hoisted so the emitter's `switch (item.kind)` has one entry point.

```zig
pub const Item = struct { id: Id, span: Span, vis: Vis, attrs: []const Attr, kind: ItemKind };

pub const ItemKind = union(enum) {
    struct_: Struct, enum_: Enum, union_: Union, fn_: Fn,
    const_: Const, static: Static, type_alias: Alias, impl: Impl,
    trait: Trait, extern_block: ExternBlock,
    mod: Mod, use: Use,                       // module tree owned by crate-graph.md
    unsupported: Unsupported,                 // §6 losslessness valve
};
```

Sources: idiom-mapping.md §2–§6, §15–§17; rust2zig `src/translate/item.rs` (prior-work.md §1).

### 1.1 Struct — named/tuple/unit → struct / extern struct

```zig
pub const Struct = struct { name: []const u8, generics: ?Generics,
    layout: struct_kind, fields: []const Field };
pub const Field = struct { name: []const u8, ty: Type, visibility: Vis, span: Span };
pub const struct_kind = enum { named, tuple, unit };
```

`named` → `struct {...}`; `tuple` fields → positional `field_0..N`; `unit` → empty struct.
`#[repr(C)]`→`extern struct`, `#[repr(packed)]`→`packed struct`, `#[repr(transparent)]`→
single-field struct (idiom §2). Layout is a desugar decision from the attr (§2), not a
separate struct kind.

### 1.2 Enum — C-like/data/recursive → enum(uN) / union(enum)

```zig
pub const Enum = struct { name: []const u8, generics: ?Generics,
    kind: enum_kind, variants: []const Variant,
    repr_int: ?int_repr, non_exhaustive: bool };
pub const Variant = struct { name: []const u8,
    fields: VariantFields /* .none | .tuple([]Type) | .named([]Field) */,
    discriminant: ?i128 };
pub const enum_kind = enum { c_like, data, mixed };
```

`.c_like`→`enum(uN)` (idiom §3: `repr(u8)`→`enum(u8)`; default isize→match). `.data`/
`.mixed`→`union(enum)`. Recursive variants: indirection lives on the *type* node as
`Box<T>`→`*T` (idiom §3 `next: *List`), allocation owned by ownership-mem.md. `#[non_
exhaustive]`→inject synthetic `else` arm — Zig's tag set is fixed, unhandled tags are
`corruptSwitch` (idiom §3).

### 1.3 Union — extern/untagged

```zig
pub const Union = struct { name: []const u8, generics: ?Generics,
    repr: union_repr, fields: []const Field };
pub const union_repr = enum { extern_, packed, untagged };
```

`extern union` / `packed union` / bare `union` (idiom §4).

### 1.4 Function — receivers to explicit self params

```zig
pub const Fn = struct { name: []const u8, generics: ?Generics,
    params: []const Param, ret: Type,          // `()` → void
    is_async: bool, is_unsafe: bool, is_const_fn: bool,
    receiver: ?Receiver, body: ?BodyRef };     // body in exprs-patterns.md
pub const Param = struct { name: []const u8, ty: Type, span: Span };
pub const Receiver = enum { owned, ref_, mut_ref };
```

Receiver erasure (idiom §2): `&self`→`self: *const Self`, `&mut self`→`self: *Self`, owned
`self`→`self: Self`. `is_unsafe` retained for the ownership contract (idiom §16); `is_
async` retained but v1-gated.

### 1.5 Const / Static

```zig
pub const Const = struct { name: []const u8, ty: Type, init: BodyRef };
pub const Static = struct { name: []const u8, ty: Type, init: BodyRef, mut: bool };
```

`const`→container-level Zig `const`; `static`→`var` (`mut` flag; `static mut` interior
mutability is v1-gated, ownership-mem.md).

### 1.6 Type alias

```zig
pub const Alias = struct { name: []const u8, ty: Type, generics: ?Generics };
```

Plain→`const NAME = <ty>` (idiom §1). Generic→`fn NAME(comptime ...) type` (idiom §5).

### 1.7 Impl blocks + associated items

```zig
pub const Impl = union(enum) { inherent: Inherent, trait: TraitImpl };
pub const Inherent  = struct { self_ty: Type, generics: ?Generics, assoc: []const AssocItem };
pub const TraitImpl = struct { trait_path: Path, self_ty: Type, generics: ?Generics,
    assoc: []const AssocItem };
pub const AssocItem = union(enum) { fn_: Fn, const_: Const, type_: AssocType };
pub const AssocType = struct { name: []const u8, generics: ?Generics,
    bounds: []const Bound, default: ?Type };
```

Methods stay *inside* the struct name (Zig lazy-field namespacing, idiom §2: `impl Point`
bodies become `pub fn` in `const Point = struct {...}`). Trait impls are the static-dispatch
case (idiom §6a); exact trait-impl emission split is a §7 question.

### 1.8 Extern / FFI

```zig
pub const ExternBlock = struct { abi: Abi, items: []const Fn };
pub const Abi = enum { c, system, rust_intrinsic };
pub const extern_kind = enum { decl, export };   // declared vs #[no_mangle] export
```

`extern "C" fn` decl→`extern fn`; `#[no_mangle] pub extern "C" fn` body→`export fn`
(idiom §17). `Abi.system`→`callconv(.winapi)` on Windows (idiom §17).

### 1.9 Trait declarations

```zig
pub const Trait = struct { name: []const u8, generics: ?Generics,
    supertraits: []const Path, methods: []const TraitMethod,
    assoc_types: []const AssocTypeDecl, assoc_consts: []const Const };
pub const TraitMethod = struct { sig: FnSig, default_body: ?BodyRef };
```

Static dispatch→comptime duck typing (idiom §6a); `dyn Trait`→synthesized `{ptr,vtable}`
struct (idiom §6b) — **v1 blocker** (§19 #1). Supertraits/associated-types/GATs/HRTB have
no direct analogue (idiom §6 traps); stored faithfully, desugared or refused per §6.

---

## 2. Attributes

Attributes are the translator's *policy inputs* and must survive losslessly even when
untranslated. Each `Attr` is a preserved `(path, meta)` pair + a `known` flag the emitter
can act on.

```zig
pub const Attr = struct { path: []const u8, meta: Meta, known: bool, span: Span };
pub const Meta = struct { raw: []const u8 };     // lossless text fallback
```

| Attr | Effect | v1 |
|---|---|---|
| `#[repr(C / packed / transparent)]` | `extern`/`packed`/single-field struct | in |
| `#[repr(uN / iN / usize)]` | `enum(uN)` backing int | in |
| `#[non_exhaustive]` | inject `else` arm | in |
| `#[no_mangle]` | `export fn` / pinned name | in |
| `#[inline(...)]` / `#[deprecated]` | hint / comment, preserved | in (no-op) |
| `#[derive(...)]` | deferred to expansion (§2.1) | out/expand |
| `#[cfg(...)]` | target filtering (crate-graph) | out |

Unknown attrs (`#[serde(...)]`) stay `.known=false` raw text — the emitter keeps them as
comments and never drops them.

### 2.1 Derive

No direct Zig idiom (idiom §15: derive → manual Zig `format`/`clone`/`std.meta.eql`).
Allow-listed + simple: desugar to those members *at expansion* (sidecar), then translate.
Otherwise the derive bubbles into an `unsupported` marker naming the trait (§6), so the
emitter never silently yields a type missing its Rust traits. Owned by expand stage
(approaches.md §3.2), but the marker survives in the IR.

---

## 3. Generics & monomorphization

Rust generics → Zig `comptime` (idiom §5; prior-work §1). Monomorphization is **generic
decl kept + instantiation records**, never body duplication (approaches.md §3.3;
rust2zig's `GenericArgRef` locates the instantiation at a call site).

```zig
pub const Generics = struct { params: []const GenericParam,
    where: []const WhereClause,        // retained as diagnostics; erased at emit (idiom §5/§6)
    defaults: []const { param_idx: u32, ty: Type } };
pub const GenericParam = union(enum) { type_: TypeParam, const_: ConstParam, lifetime: LifetimeParam };
pub const TypeParam     = struct { name: []const u8, bounds: []const Bound };
pub const ConstParam    = struct { name: []const u8, ty: Type };   // `const N: usize`
pub const LifetimeParam = struct { name: []const u8 };             // erased; diagnostic only
```

Emit: `comptime T: type` / `comptime N: usize`; method comptime params go *after* `self`
(idiom §5; prior-work §1). Where-clauses/bounds are not emitted (duck typing) but retained
for diagnostics. Lifetimes erased at emit yet kept for spans.

### 3.1 Instantiation records

```zig
pub const GenericArgs = struct { params: []const Type };
pub const Instantiation = struct { generic_id: Id, args: GenericArgs,
    zig_suffix: []const u8 };          // mangled name for distinct comptime instantiation
```

`analyse` builds a `[]Instantiation` table per generic decl (approaches.md §3.3). IR stores
the decl **once**; each use site references `generic_id + args` (a `GenericInst` type, §4.4).
Emitter relies on comptime memoization for identical types (idiom §5). No body duplication.

---

## 4. Type representation

`Type` is the tagged union every field/param/return references.

```zig
pub const Type = union(enum) {
    path: Path,                          // resolved nominal type
    prim: Prim,
    reference: Ref,  ptr: RawPtr,  slice: Slice,  array: Array,
    tuple: []const Type,  fn_ptr: FnPtr,
    generic_inst: GenericInst,           // `Foo<i32>` → decl id + args
    option: &Type,  result: Result,  boxed: &Type,   // §4.5 dedicated nodes
    str: StrKind,  coll: Collection,                   // §4.6
    unsupported: Unsupported,                            // §6
};
```

### 4.1 Paths, primitives, references, pointers, slices

```zig
pub const Path = struct { segments: []const { name: []const u8, id: ?Id } };
pub const Prim = enum { i8..i128, u8..u128, isize, usize, f32, f64, bool, char, unit, never };
pub const Ref    = struct { mut: bool, pointee: Type, lifetime: ?LifetimeParam };
pub const RawPtr = struct { mut: bool, pointee: Type };
pub const Slice  = struct { const_: bool, elem: Type };
```

`&T`→`*const T`, `&mut T`→`*T` (idiom §8; prior-work §1). `&[T]`→`[]const T`. Raw pointers
→ `*const T`/`*T`; arithmetic/C-style → `[*]T`/`[*c]T` (idiom §16). `char`→`u21`,
`usize`→`usize`, `()`→`void`, `!`→`noreturn`.

### 4.2 Arrays / tuples / fn pointers / generic instantiations

```zig
pub const Array = struct { elem: Type, len: ArrayLen };
pub const ArrayLen = union(enum) { literal: usize, generic: u32 };  // generic idx for `const N`
pub const FnPtr = struct { params: []const Type, ret: Type, abi: ?Abi };
pub const GenericInst = struct { decl: Id, args: GenericArgs };
```

`[T;N]`→`[N]T` (idiom §5); tuples→anonymous structs; fn-ptr→`fn(...)`, C-ABI→`callconv(.c)`
(idiom §17). Generic path+args resolves to a §3.1 `Instantiation`.

### 4.3 Dedicated `option` / `result` / `boxed` nodes — rationale

These three get dedicated nodes **instead of plain `Path`** because the emitter forks
structurally on them and the ownership layer must see them:

- `Option<T>` → Zig optional `?T` (idiom §7). A plain path would force the emitter to
  introspect std `Option`'s definition (not in the crate) — fragile. The node carries the
  resolved inner `T` and drives optional-capture lowering (`if (opt) |v|`, idiom §7/§9).
- `Result<T,E>` → error union `E!T` **only when `E` is a finite error set** (idiom §7 trap:
  `Box<dyn Error>`/`anyhow` has no Zig analogue → `unsupported` or coarse `anyerror`). Node
  stores both so `?`→`try` is direct.
- `Box<T>` → `*T` with explicit allocation (`gpa.create` + `defer gpa.destroy`, idiom
  §3/§8). A dedicated node lets the ownership layer thread the allocator and pick
  scoped-vs-path-sensitive `defer` (ownership-mem.md; prior-work §1 drop elaboration);
  without it the emitter would erase owned-ness and leak/alias silently.

They are desugar-to-Zig *hooks*, not final Zig forms; the semantic Rust type is preserved
inside so the IR stays lossless.

```zig
pub const Result = struct { ok: Type, err: Type, is_error_unionable: bool };
```

### 4.4 str / String / collections

```zig
pub const StrKind = enum { borrowed, owned };   // &str→[]const u8; String→ArrayList(u8)
```

`&str`→`[]const u8` (idiom §11); `String`→`std.ArrayList(u8)` **unmanaged** `.empty`
(idiom §11: managed deprecated in 0.16). `Cow`→`union(enum)`. `Vec/HashMap/...`→Zig std
`ArrayList(T)`/`AutoHashMap(K,V)`/... via a `Collection` node (idiom §12 table), allocator
threading owned by ownership-mem.md.

---

## 5. JSON encoding sketch

Tagged objects via discriminant fields (Zig `union(enum)` JSON form). Examples:

```json
{ "kind": "struct", "id": { "krate": 0, "local": 3 },
  "span": { "start": { "line": 1, "col": 0 }, "end": { "line": 3, "col": 1 } },
  "vis": "pub", "attrs": [ { "path": "repr", "meta": { "raw": "C" }, "known": true } ],
  "payload": { "name": "Point", "generics": null, "layout": "named",
    "fields": [ { "name": "x", "ty": { "kind": "prim", "prim": "i32" }, "vis": "pub" } ] } }
```

```json
{ "kind": "enum", "vis": "pub",
  "payload": { "name": "Shape", "kind": "data", "repr_int": null, "non_exhaustive": false,
    "variants": [
      { "name": "Circle", "fields": { "kind": "tuple", "tys": [ { "kind": "prim", "prim": "f64" } ] } },
      { "name": "Rect",   "fields": { "kind": "named", "fields": [
          { "name": "w", "ty": { "kind": "prim", "prim": "f64" }, "vis": "priv_" } ] } } ] } }
```

```json
{ "kind": "fn", "vis": "pub",
  "payload": { "name": "parse", "generics": null,
    "params": [ { "name": "s", "ty": { "kind": "str", "str": "borrowed" } } ],
    "ret": { "kind": "result",
      "ok": { "kind": "prim", "prim": "i32" },
      "err": { "kind": "unsupported", "reason": "ParseError (resolved error-set ref)" },
      "is_error_unionable": true },
    "is_async": false, "is_unsafe": false, "receiver": null, "body": { "ref": 14 } } }
```

Generic instantiation: `{ "kind": "generic_inst", "decl": { "krate": 0, "local": 9 },
"args": { "params": [ { "kind": "prim", "prim": "usize" } ] } }`. All tags match Zig union
names (`struct_`, `enum_`, `fn_`), so `std.json` `parseFromSlice`/`stringify` round-trip
directly.

---

## 6. v1 subset (cross-ref idiom §19/§18)

**In:** struct (named/tuple/unit)+inherent impl (§2); C-like & data-carrying enums
(non-recursive, or recursive-`Box` given ownership layer); extern/untagged unions (§4);
`fn` with owned/`&`/`&mut` receivers; `const`/`static`; plain aliases; generics→comptime
(type+const params, no where emission); `Option`→`?T`; `Result`(finite set)→`E!T`;
`&str`/`String`slices; `Vec`/`HashMap`→std; `#[repr]`/`#[no_mangle]`/`#[non_exhaustive]`;
`extern "C"`; unsafe-pointer casts (§16). The rust2zig corpus dialect (approaches §2.5;
prior-work §1).

**Out / deferred — explicit `unsupported` markers, never silent:**

| Form | Reason | Source |
|---|---|---|
| `dyn Trait` / heterogeneous trait objects | no Zig vtable; manual `{ptr,vtable}` | idiom §6, §19 #1 |
| `Rc`/`Arc`/`RefCell`/`Mutex` interior mutability | ownership/arena layer | §8, §19 #2 |
| path-sensitive `Drop` | alive-flag/defer elaboration partial | §8, §19 #2 |
| custom iterators; FnMut/move closures | per-adapter state-machine lowering | §10, §19 #3 |
| async/await with executor | rewrite, not translation | §14, §19 #4 |
| derive/proc macros beyond `assert!`/`panic!`/`println!` | needs Rust-toolchain pre-expansion | §15, §19 #5 |
| `catch_unwind` | impossible; redesign to error-return | §13, §19 #6 |
| associated types / GATs / HRTB / supertraits | no Zig analogue | §6 |
| `where`-clause *emission* | duck-typed; bounds retained as diag | §5/§6 |

Every out-of-scope form carries `{ "kind": "unsupported", "reason": "...", "orig": <raw> }`
so the emitter refuses (v1) or emits a comment — never a wrong construct. `#[cfg]` and the
module tree are crate-graph.md's; bodies/patterns are exprs-patterns.md's.

---

## 7. Open questions

1. **Trait-impl emission split (static dispatch):** with comptime duck typing (idiom §6a),
   do trait-impl methods fold into the impl'd struct's emitted `struct {...}` (Lazy-field
   namespacing) or emit as standalone generic fns? Folding collides when two traits define
   the same method name — a known rust2zig renaming gap (prior-work §1).

2. **Option/Result/Box: resolve in sidecar vs in Zig?** Do the dedicated nodes hold the
   *already-resolved* inner type (simpler emitter, bakes in an assumption about std
   identity), or store the raw path and let Zig's `analyse` recognize
   `core::option::Option` (purely structural IR)? Decides the sidecar↔IR contract.

3. **Non-finite `Result` error type:** for `Result<T, Box<dyn Error>>`, is the fallback
   `anyerror` (coarse, loses the set — idiom §7 trap) acceptable in v1, or must it be
   `unsupported` until a dynamic-error model exists? Affects which real crates clear v1.
