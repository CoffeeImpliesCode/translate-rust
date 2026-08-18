# Source-driven Rust model with tree-sitter parsing + in-Zig type inference

Status: **plan** (next major research/implementation phase). Supersedes the
rustdoc-JSON sidecar as the semantic source of truth *for the crates we
translate*; rustdoc remains a fallback / public-API shortcut for crates whose
source we don't parse.

## 0. Bottom line

The only way to get a *complete* Rust model (real bodies, private items,
generics, trait impls, macro-expanded shapes) without depending on a Rust
toolchain is:

```
tree-sitter-rust ──► lossless CST ──► (1) type model   ──┐
                    (in-process,      (2) code model    ├─► typed IR ──► emit
                     no subprocess)   (3) type inference ◀┘  (existing
                                      (unification,          data-model)
                                       method/trait
                                       resolution,
                                       monomorphization)
```

- **Parser**: tree-sitter (C library, zero Rust deps) — already started in
  `src/model/ts_ext.zig`.
- **Models extracted from source**: declarations → type environment; function
  bodies → untyped code graph.
- **Type inference** in Zig fills every `Expr.ty`, resolves method calls,
  erases/instantiates generics, and emits monomorphization records.

This is reimplementing a *small, bounded slice* of `rustc`'s HIR + typeck in
Zig. There is no shortcut: an untyped CST cannot name `wrapping_mul` on a `u64`
receiver, cannot know `Fletcher16` is an alias, cannot pick an `impl` for a
trait call. That is precisely why the current corpus crates (trait/generic-heavy)
fall back to empty bodies (hybrid, `4d7f15f0`).

---

## 1. Position in the pipeline

The existing IR (`data-model.md`) is already correct and lossless; what changes
is *who produces it*. Today the semantic sidecar is rustdoc JSON (public API,
no bodies); the hybrid patch adds tree-sitter bodies but no types. This plan
replaces the sidecar with a Zig-native producer.

```
parse (ts) → resolve (names) → type-check (inference) → lower → IR (unchanged)
                                                              │
                                        desugar / analyse / emit (unchanged)
```

Stages added in Zig (all in `src/model/`):
1. `cst.zig`      — lossless CST walker (ts_ext today, made complete/lossless).
2. `names.zig`    — name resolution: modules, paths, shadowing, `use`, re-exports.
3. `types_env.zig`— the *type model*: build a `TypeId` table from all items.
4. `infer.zig`    — the *code model* + type inference: constraint gen + unification.
5. `resolve_methods.zig` — trait/impl dispatch for method & operator calls.

The produced `Bodies` (`exprs/stmts/pats/types/bodies`) is byte-identical in
shape to today's — `emit.zig`, `package.zig`, `ts_ext.zig`'s tables, and the
JSON wire format all stay unchanged. This is the key decoupling: inference is a
new producer for an existing IR.

---

## 2. The two extracted models

### 2.1 Type model (from declarations, not bodies)

Walk every item (struct / enum / union / trait / impl / fn sig / const / type
alias / extern block) and populate the IR's `types.Type` table + `Generics` /
`Instantiation` records:

| Source | Model output |
|---|---|
| `struct Point { x: i32 }` | `Type` = path→`Point`; fields typed |
| `struct Foo<T> { v: T }` | `Generics { type_: T }`; `Type` keeps generic param |
| `type Alias = Foo<u32>` | alias → resolved type (no instantiation yet) |
| `enum E { A, B(i32) }` | C-like/data variants typed |
| `trait T { fn m(&self) -> u32 }` | trait method sigs (receiver mode) |
| `impl Point { fn area(&self) -> f64 }` | method → receiver `*const Self` |
| `impl Trait for Point { ... }` | trait-impl table entry |
| `extern "C" { fn putc(c: i32) }` | fn-ptr / extern decl |

The type environment is a `TypeId` table exactly as `data-model/items-types.md
§4` specifies (paths, prims, refs, slices, arrays, tuples, fn-ptr,
`option`/`result`/`boxed`/`str`/`coll` hooks, `generic_inst`).

**Generic params are kept unresolved** in the type table; a call site records an
`Instantiation { generic_id, args }` (monomorphization by record, never copy —
`data-model.md §1`, `items-types.md §3.1`).

### 2.2 Code model (from bodies)

Walk every fn body (and const/static init) into the existing `exprs`/`stmts`/
`pats` tables — **untyped**. Every `Expr.ty` is `null` until inference. This is
exactly what `ts_ext.zig` does today; the difference is:
- today: reject the whole body if *any* node is unresolvable (`.unsupported` →
  empty body);
- here: lower the whole body losslessly, leave types null, and let inference
  resolve or mark `unsupported` per-node.

Per-node `unsupported` (finite reason, never silent — `data-model.md §1`) is the
fallback for what inference cannot type.

---

## 3. Type inference (the new core)

A small, bidirectional, constraint-based inference engine over the typed
declarations + untyped bodies. Classic Hindley-Milner *subset* with Rust's
nominal + trait machinery layered on.

### 3.1 Constraint generation (`infer.zig`)

Walk the code graph and emit constraints between `Expr.ty` slots:

- **annotations** (authoritative): `let x: u32 = e` pins `x`; param/ret types pin
  their exprs.
- **literals**: `0` ambiguous; `0u64`/`0x..u32` pinned; floats → `f32`/`f64`
  (default f64).
- **operators**: `a + b` ⇒ `ty(a) = ty(b) = ty(result)` (plus overflow mode from
  `wrapping_*`/plain); `a << b` ⇒ `ty(b) = comptime_int/usize`, `ty(result) = ty(a)`.
- **casts** `x as T` ⇒ `ty(cast) = T`.
- **index/field**: `a[i]` ⇒ `ty(a) = slice/array[T]`, `ty(expr) = T`; `r.f` ⇒
  `ty(r)` must have field `f` of type `ty(expr)`.
- **calls**: `f(args)` ⇒ `ty(f)` = fn sig; unify param types with arg types.
- **method calls** `r.m(args)` ⇒ `ty(r)` must have method `m` (see §3.3).
- **control flow**: `if` branches must agree; `for pat in iter` ⇒ `ty(iter)` is
  slice/array/iterator, `ty(pat)` = elem; `return e` unifies `ty(e)` with fn ret.
- **optionals/errors**: `e?` ⇒ `ty(e)` = `Result<T,E>` → `ty(expr) = T`;
  `if let Some(v) = o` ⇒ `ty(o)` = `Option<T>`, `ty(v) = T`.

### 3.2 Unification + defaults (`infer.zig`)

Union-find over type variables; constants sink to concrete `TypeId`s. After
fixpoint, unresolved vars get **defaults**: integers → `i32` (Rust's default),
floats → `f64`, unconstrained → `unsupported` (finite reason, not a silent
guess — Rust itself errors on ambiguous types; we mirror that).

Termination: constraint set is finite (per crate); fixpoint via a worklist.

### 3.3 Method / trait / operator resolution (`resolve_methods.zig`)

After unification gives concrete receiver types:

- **inherent methods**: look up `impl <SelfTy> { fn m }` for the receiver type.
- **trait methods**: find the `impl Trait for SelfTy` in scope; if multiple
  candidates (the classic Rust ambiguity), mark `unsupported` (we do not
  implement trait-selection's negative reasoning).
- **operators** `+`/`*`/`^`/…: Rust's operators are traits (`Add`, `Mul`,
  `BitXor`…); resolve via the `impl` table; built-in primitives are assumed
  (no std source needed).
- **constructor / associated fn** `T::new(...)`: resolve against `impl T`.

**Scope of trait resolution**: bounded to *impls defined in the crate or in a
translated dep*, plus a small built-in table for the std prelude types
(`Option`, `Result`, numeric traits, `Default`/`Hash`-adjacent traits we
actually lower). Anything else → `unsupported` (never a wrong dispatch).

### 3.4 Generics / monomorphization

- Call site `Foo::<i32>::new()` / `f::<u32>(x)` → build `Instantiation`.
- Unify the generic body's type variables with the concrete args; the inferred
  body types are per-instantiation but stored **by record** (decl kept once,
  `Instantiation` references args — `data-model.md §1`).
- Lifetimes: erased at emit (diagnostics only — `items-types.md §3`); borrowck is
  out of scope (Zig's ReleaseSafe + `unsound` markers already the contract,
  `ownership-mem.md`).

---

## 4. What makes this hard (the honest cliffs)

1. **Trait/impl selection** (§3.3). The single hardest piece. Rust's solver is
   a full logic program; we implement a bounded table lookup + ambiguity
   refusal. This caps us: a crate whose correctness depends on deep coherence
   (overlapping impls, auto-traits, specialization) → `unsupported`, not wrong.
2. **Macros** (`macro_rules!`, `derive`, proc-macros). Tree-sitter sees the
   *unexpanded* token stream. Plan: support a hand-listed set of built-ins
   (`assert!`, `assert_eq!`, `panic!`, `vec!`-style literal expanders) in
   `expand.zig`; everything else → `unsupported`. No `cargo expand` dependency.
3. **Lifetimes / borrowck**. Erased; correctness delegated to Zig's runtime
   checks + `UnsoundMarker` comments (`ownership-mem.md §5`). This is a known,
   accepted correctness gap (mirrors translate-c losing C's UB guarantees).
4. **Std / core surface**. We never parse std source. `Option`/`Result`/
   numeric types + a few traits are a **built-in type table** (identical to the
   existing `option`/`result`/`boxed` dedicated nodes — `items-types.md §4.3`).
   Anything else from std → `unsupported` (bounded by the translated dialect).
5. **cfg / feature gating**. Parse with a single active cfg matrix (default
   features, all-features flag) chosen per run; `#[cfg(...)]` filters items in
   `names.zig`. Multi-config expansion is out of scope (one active target per
   translation).

---

## 5. Phase plan (each phase ends green: differential `cargo test` ⇄ `zig test`)

**P0 — Lossless CST → type model** (`cst.zig`, `types_env.zig`)
Extract every item + type into `types.Type`/`Generics`/`Instantiation` from
tree-sitter. Test: parse the existing corpus crates, dump the type table,
assert it round-trips. Gate: existing `gate` + a `--dump types` CLI verb.

**P1 — Name resolution** (`names.zig`)
Modules/paths/shadowing/`use`/re-exports → `EntityId`/`UseDecl` resolution
(already shaped by `crate-graph.md`). Test: shadowing + glob-use fixtures.

**P2 — Code model + constraints** (`infer.zig` gen phase)
Lower full bodies (not reject-on-first-unsupported) and emit constraints. Test:
untyped graph for all corpus crates; every `ty` slot resolved *for the pure
subgraph* (fnv-style); method/trait-heavy bodies get per-node `unsupported`
instead of whole-body rejection.

**P3 — Unification + defaults** (`infer.zig` solve phase)
Fixpoint over constraints; literals/operators/control-flow typed. Test:
`checksum`/`fnv1a_hash`-style fns now infer `u64` on every node; `wrapping_mul`
→ wrapping `*%` overflow marked.

**P4 — Method/operator/trait resolution** (`resolve_methods.zig`)
Inherent + trait impl dispatch; built-in std table; ambiguity → `unsupported`.
Test: `Fletcher16::new()`/`.update()`/`.value()` now resolve (fletcher bodies
fill); hex's `BytesToHexChars` either resolves or marks precisely.

**P5 — Generics + monomorphization records** (in `infer.zig`)
Generic call sites → `Instantiation`; comptime Zig emission. Test: a generic
`Foo<T>` called with `u32`/`&[u8]` monomorphizes to two comptime instantiations.

**P6 — Built-in macro expansion** (`expand.zig`)
`assert!`/`assert_eq!`/`panic!`/literal vec expanders. Test: corpus `#[test]`
bodies now fill (the original "no tests" gap, now solved at the source).

**P7 — Drop the sidecar**
`driver.translate` stops shelling out to rustdoc; tree-sitter + inference is the
only producer. rustdoc path deleted or kept behind a flag as a shortcut for
public-API-only dumps. Verify: full corpus `zig build test-crates` + `gate`
green with **zero Rust toolchain invocations**.

---

## 6. Verification strategy

Per phase: the differential pair (`approaches.md §2.2`, rust2zig's discipline):
- `cargo test` on the Rust source (ground truth), `zig test` on the emitted
  package — compare outputs.
- Corpus regen: every phase re-runs `zig build test-crates` over all 14 crates
  (regenerate → ast-check → build → test). A phase is green only when no crate
  *regresses* (a body that filled stays filled; a body that couldn't fill stays
  a clean empty/`unsupported`, never wrong).
- `gate` (fmt/build/test/ast-check/ziglint/zlint) at every commit.

---

## 7. Open decisions (resolved conservatively until overridden)

1. **std built-in table scope**: which std types/traits we hard-code (proposal:
   the exact set the `option`/`result`/`boxed`/`coll` nodes + numeric traits
   already imply). Growth = adding rows, not shapes.
2. **Multi-crate deps**: translate dep crates first and resolve cross-crate
   paths (option (d) of approaches.md) vs. refuse cross-crate type references.
   Proposal: refuse for P0–P6, enable leaf-then-deps after P7.
3. **Inference engine shape**: write a small explicit `unify`/`solve` (proposal)
   vs. reuse an existing Zig inference lib. No credible existing lib → own it.
4. **Macro hygiene**: textual (proposal: none needed for the hand-listed
   built-ins, they expand structurally) vs. full hygiene (out of scope).
5. **cfg matrix**: single active target (proposal) vs. multi-config.

---

## 8. Reference

- `data-model.md` + `data-model/*` — the IR this plan fills (unchanged).
- `src/model/ts_ext.zig` — the CST walker to generalize (`cst.zig`).
- `notes/research/approaches.md` §3.3 / §2.2 — the `analyse`/monomorphization
  stage and rust2zig's differential-test discipline.
- `notes/research/parsing-tooling.md`, `prior-work.md` — front-end and
  existing-art lessons (rust2zig = the closest prior art: `syn`+SCIP+typeck;
  we replace `syn`+SCIP with tree-sitter+in-Zig inference to drop all Rust deps).
