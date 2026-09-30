> **Historical design record — not current coverage.** Written during the
> exploration phase of this translator. It records a proposed design, not what
> the translator does today. Nothing here is a claim that `translate-rust`
> supports a Rust shape. For what the translator actually translates, read the
> [repository README](../../../README.md).

# Data model — Ownership, Borrowing, Drop, Allocator

File: `notes/design/data-model/ownership-mem.md`.

How the lossless IR models Rust's ownership surface — move vs `Copy`, borrows
(`&T`/`&mut T`), `Drop`/RAII, and the allocator layer — so the Zig emitter lowers
each node correctly. This is the hardest and most-contested axis (idiom-mapping
§8; design question 2 in `notes/README.md`). Citations are `[note §section]`
plus, for facts not verbatim in the notes, an external URL. Facts are referenced
and extended into concrete Zig `struct` shapes, never restated.

---

## 1. Guiding model

Zig has no borrow checker; translation removes guarantees: `&T` → `*const T`,
`&mut T` → `*T`, owned `T` → `T` by value, lifetimes erased (idiom §8;
prior-work §4 lesson 8). The IR cannot *represent* borrow-checking; it must
record enough **usage** so the emitter (a) produces semantically identical Zig
and (b) flags points where Zig's runtime checks do **not** reproduce Rust's
borrow safety (idiom §8: "no compiler to enforce aliasing"; prior-work §4
lesson 8: Zig checks are "less comprehensive" than Rust's safe subset). It never
silently omits an unsupported case — deferred features carry an explicit
deferred seam (§7).

Every node carries a **span** (`line`, `col`) for diagnostics and a stable **id**
into the shared symbol table (rustdoc `DefId` analogue — parsing-tooling §2.5).

---

## 2. Ownership representation

### 2.1 Value kind: move vs `Copy`

Rust distinguishes *move* (owner transfers, source dead) from `Copy` (memcpy,
source usable). Zig has no distinction — every `T` copies freely. The emitter
needs the Rust-side fact per site to know whether re-reading the source is legal
and whether a second drop must be suppressed. The IR freezes the answer from the
sidecar (SCIP/rustdoc resolves `Copy`/`Drop` bounds).

```zig
pub const ValueKind = enum { move, copy, move_drop };
/// move_drop: has a Drop impl; moves transfer the drop owner.

/// Ownership banner on a value-typed node.
pub const Ownership = struct {
    kind: ValueKind,
    owner: ?EntityRef,               // drop location: local/field/box/arena
    moved_across_boundary: bool = false,
    span: Span,
};
```

### 2.2 By-value vs by-reference params and receivers

idiom §2/§8 fix the lowering: `&T` → `*const T`, `&mut T` → `*T`, owned → `T`.
The IR carries Rust-side intent so the emitter picks the shape and callers pass
the right value. This resolves the idiom §8 trap that "borrowing rules
disappear": facts are preserved, only enforcement is gone — which is exactly what
the unsoundness marker (§5) flags.

```zig
pub const BorrowKind = enum {
    owned,      // T
    shared,     // &T     -> *const T   (idiom §8)
    mutable,    // &mut T -> *T         (unique; emitter must not alias)
    slice_const, // &[T]   -> []const T
    slice_mut,   // &mut [T] -> []T
};

pub const ParamShape = struct {
    borrow: BorrowKind,
    zig_ty: ZigTyRef,                  // resolved from SCIP signature
    is_receiver: bool = false,         // &self -> *const Self etc. (§2, §8)
    lifetime_uses: ArrayListUnmanaged(UnsoundUsage) = .empty,
    span: Span,
};
```

`zig_ty` is frozen from the SCIP signature (`xs: &[i32]` → `[]const u8`), as
rust2zig reads `signature_documentation.text` (prior-work §1).

### 2.3 Copy vs clone

`clone()` stays an ordinary method call (lowered to a real Zig fn, or a plain
struct copy when the target is `Copy`). No separate scheme in v1 (§7).

### 2.4 Lifetimes: erased, usage recorded

Lifetimes have no runtime effect; the IR erases them (idiom §8; rust2zig).
Erasure must not hide risk: Rust's borrow checker caught two real UAFs in Roc's
Zig port that Zig's checks missed (prior-work §3 Roc row;
rtfeldman.com/rust-to-zig, 2026-07-16). So `lifetime_uses` records aliasing edges
so the emitter can comment/assert where a UAF is runtime-undetectable (§5).

---

## 3. Drop / RAII

`Drop` and compiler-inserted field-drop order have no Zig equivalent; Zig has
`defer`/`errdefer`. The IR describes the drop plan.

```zig
pub const DropInfo = struct {
    drop_impl: ?EntityRef,             // impl Drop body, else field-wise drop
    field_order: ArrayListUnmanaged(FieldDrop) = .empty,
    strategy: DropStrategy,
    uses_allocator: bool = false,
    allocator: ?AllocatorUse,
    span: Span,
};
pub const FieldDrop = struct { field: EntityRef, drop: DropInfo };

/// rust2zig design/drop.md (prior-work §4): "`defer x.drop()` when destruction
/// is unconditional on scope exit; alive flags only when destruction is
/// path-sensitive". Encoded 1:1.
pub const DropStrategy = enum {
    defer_only,   // v1: defer (and errdefer on error paths)
    alive_flag,   // deferred: path-sensitive; an alive bit carries the state
};
```

### 3.2 Destructor order & error cleanup

- **Normal exit**: fields drop in declaration order after the struct's own
  `Drop` body. Zig `defer` is LIFO, so the emitter writes `defer`s in **reverse**
  to match Rust's runtime order — a recorded source-of-truth fact, not an
  emitter guess.
- **Error exit**: in an error-returning scope, each `defer` also becomes
  `errdefer` (idiom §8) so the resource is released on the error path. The
  emitter decides `defer`+`errdefer` per scope context.

### 3.3 v1

Only `defer_only` is v1 (scoped, by-value). `alive_flag` is present in the schema
but gated out (§7), per rust2zig design/drop.md.

---

## 4. Allocator / arena strategy

Rust assumes one implicit global allocator
([rtfeldman.com/rust-to-zig](https://rtfeldman.com/rust-to-zig): "off-the-shelf
Rust crates almost always assume a single global allocator"; approaches §2.3),
while Zig threads an explicit `std.mem.Allocator` through every allocating fn
(idiom §8; andrewkelley.me). The IR therefore must know, per allocation, **which
allocator** is in scope and how it is built — a structural change (allocating
Rust fns silently gain an allocator param in Zig output).

```zig
pub const AllocatorSource = enum {
    param,           // injected leading param (default for any allocator fn)
    field,           // owning struct holds an arena allocator
    global_arena,    // harness-owned single arena (no_std v1 test entry)
    none,            // fn does not allocate; v1-legal
};
pub const AllocatorUse = struct {
    source: AllocatorSource,
    param_index: ?u16,                 // .param: insertion position
    owner_field: ?EntityRef,           // .field: which field owns the arena
    prim: AllocPrim,
    span: Span,
};
pub const AllocPrim = enum {
    create_destroy,  // Box<T> -> gpa.create / gpa.destroy   (idiom §8)
    alloc_free,      // slice-of-T -> gpa.alloc / gpa.free
    aligned,         // alignedAlloc (Box<[u8;N]>)
    arena,           // owned bucket -> arena.alloc / arena.deinit (most deferred)
};
```

### 4.2 Arena and Box recursion

Recursive `enum List { Cons(u32, Box<List>) }` needs pointer indirection in both
languages, but Zig does **not** auto-allocate — the translator calls
`gpa.create(List)` for each `Cons.next`, owned by the Box (idiom §3). The IR
marks such a field `AllocatorUse.prim == create_destroy`, `owner: .box`. For v1
the preferred container is a single scoped arena owned by the entry point
(`AllocatorSource.global_arena`/`.field`) so the whole no_std program frees with
one `defer arena.deinit()`, sidestepping per-value `free`. Per-value
`create_destroy` stays v1-legal for simple `Box<i32>` (idiom §8 example).

### 4.3 Roc: the negative control

Roc abandoned Rust partly over the allocator model (prior-work §3;
approaches §2.3). The IR does not re-solve this; it institutionalizes the Zig
side: every allocating construct records `AllocatorUse`, and the emitter always
threads the allocator. A construct whose allocator the IR cannot source becomes
an unsoundness/deferred marker, never a silent omission (§5, §7).

---

## 5. Unsoundness marker

The central novelty: points where Zig's ReleaseSafe checks do **not** reproduce
Rust borrow-checker safety must be a first-class explicit artifact, never
silent. Grounding: prior-work §4 lesson 8 (Rust→Zig "removes guarantees"; Zig
checks "less comprehensive"); idiom §8 ("must not introduce aliasing that Zig
would allow but Rust forbade").

```zig
pub const UnsoundCategory = enum {
    alias_mut,             // &mut uniqueness unenforced
    borrow_outlives_owner, // UAF Zig may not catch (Roc's two UAFs)
    returned_dangling,     // returned pointer may dangle post-erasure
    copy_alias,            // Copy preserved only by convention
    interior_mut,          // *T/atomic not gated by Zig checks (deferred)
};

pub const UnsoundMarker = struct {
    category: UnsoundCategory,
    at: NodeRef,
    severity: enum { comment, assert_unreachable, redesign_required },
    message: []const u8,
    span: Span,
};
```

Emitter contract: `comment` always emits `// UNSOUND: <message>` at the node;
`assert_unreachable` adds a runtime guard emitted as explicit
`if (!cond) @panic(...)` so it survives ReleaseFast (idiom §13: `assert` is
elided there); `redesign_required` refuses to emit unless a human override flag
is passed (the dialect boundary; approaches §6 v4 escape hatch). This enforces
the shared contract's "explicit unsupported markers, never silent omission".

---

## 6. Concrete Zig shapes + JSON encoding

### 6.1 Consolidation

All shapes above are camelCase Zig `struct`s; `enum` discriminants map to Zig
enum constants. They serialize via `std.json` (shared contract: lossless
round-trip).

### 6.2 JSON wire encoding (draft)

Ownership, DropInfo, AllocatorUse, and UnsoundMarker serialize as tagged unions
(outer `"kind"` discriminator) so `std.json` round-trips without losing any
discriminant:

```json
{
  "ownership": { "kind": "move_drop", "owner": { "kind": "field", "id": 42 },
                 "moved_across_boundary": false, "span": { "line": 7, "col": 3 } },
  "param":     { "borrow": "shared", "zig_ty": 11, "is_receiver": false,
                 "lifetime_uses": [
                    { "category": "borrow_outlives_owner", "at": 205,
                      "severity": "assert_unreachable",
                      "message": "borrow may outlive its referent after lifetime erasure",
                      "span": { "line": 9, "col": 5 } } ],
                 "span": { "line": 7, "col": 8 } },
  "drop":      { "drop_impl": null, "field_order": [
                    { "field": 43, "drop": { "drop_impl": null, "strategy": "defer_only",
                                             "uses_allocator": true,
                                             "allocator": { "source": "global_arena",
                                                            "prim": "arena" } } } ],
                 "strategy": "defer_only", "uses_allocator": true,
                 "allocator": { "source": "global_arena", "prim": "arena",
                                "span": { "line": 12, "col": 1 } },
                 "span": { "line": 5, "col": 0 } },
  "allocator": { "source": "param", "param_index": 0, "owner_field": null,
                 "prim": "create_destroy", "span": { "line": 14, "col": 2 } },
  "unsound":   { "category": "alias_mut", "at": 301, "severity": "comment",
                 "message": "&mut uniqueness not enforced by Zig",
                 "span": { "line": 3, "col": 12 } }
}
```

Rule: every `Span` is `{"line": n, "col": m}`; type/entity refs are integer ids
into the shared symbol table (or a tagged `{"kind": "...", "id": n}` ref where
ambiguous). `std.json.parseFromSlice` reconstructs identical Zig structures.

---

## 7. v1 subset delimitation

| Axis construct | v1 | Deferred (designed) |
|---|---|---|
| By-value scoped ownership (explicit allocator path) | ✅ | |
| Copy vs move classification | ✅ | |
| `&T`/`&mut T` → `*const T`/`*T` **recording** | ✅ | |
| `Drop` via `defer`/`errdefer` (`defer_only`) | ✅ | |
| Path-sensitive drop (`alive_flag`) | | ✅ |
| Scoped arena allocator (`global_arena`/`field`) | ✅ | |
| Simple per-value `Box<T>` `create/destroy` | ✅ | |
| `Rc`/`Arc` refcount wrappers | | ✅ (seam §8) |
| `Cell`/`RefCell` interior mutability | | ✅ |
| `Mutex`/atomics | | ✅ |
| Move-across-fn **without** allocator path | | ✅ (refused) |
| `Clone` method body translation | ✅ (emits a Zig fn) | |
| Unsoundness markers | ✅ (always) | |

v1-soundness rules (grounding: approaches §6 v1 "no `std::*`"; idiom §8 "v1
blocker for any crate relying on interior mutability or shared ownership; not a
blocker for no_std-ish scoped code"):
1. Input is `no_std`-shaped: no `std::*`, async, proc-macros.
2. Every allocating construct must resolve `AllocatorUse`; else it is
   `UnsoundMarker.severity == redesign_required` and v1 refuses emission.
3. Move-across-a-fn-boundary is allowed **only** when the value carries an
   explicit allocator (param/field arena). Values that would dangle get
   `borrow_outlives_owner`/`returned_dangling` markers and are refused unless a
   human override is passed.
4. Rc/Arc/RefCell/Cell/Mutex enter at v2+, never silently in v1.

The deferred seams (`DropStrategy.alive_flag`, `AllocatorUse.prim == arena`,
§8 wrappers) are **present** in the schema but gated by the emitter's refusal
logic — the shared contract's "explicit unsupported markers".

---

## 8. The Rc/Arc/RefCell seam (deferred)

The model reserves the *shape* so v2+ synthesizes wrappers without an IR change.
Grounded in idiom §8: "`Rc<T>`/`Arc<T>` → shared resource with an explicit
refcount struct (`std.atomic` for `Arc`); neither exists in std as a generic;
hand-roll a refcounted wrapper."; and approaches §6 v2+ (Rc/Arc/RefCell are
v1 blockers → v2).

```zig
/// Reserved for v2+. NOT emitted by v1 (gated at the boundary).
pub const SharedOwnership = struct {
    kind: enum { rc, arc, refcell, cell, mutex },
    atomic: bool,                    // Arc/Mutex use std.atomic primitives
    field: []const u8,               // synthesized wrapper field (rc.inner, ...)
    allocator: AllocatorUse,
};
```

Open question Q1 collapses into: **is a scoped allocator + defer enough for v2,
or must v2 synthesize these wrappers?** The seam makes either answer expressible
without re-designing the IR.

---

## 9. Open design questions

- **Q1. Scoped allocator + defer — enough, or must v2 synthesize Rc/Arc/RefCell
  wrappers?** The §8 seam makes both expressible, but the cost is structural:
  wrapping changes fn signatures, and `RefCell` borrow flags are runtime checks
  Zig cannot guarantee — the same unsoundness class as §5. Recommend deferring
  until a real v2 crate needs them; the seam buys time at the cost of an
  unvalidated shape.
- **Q2. Where does the allocator come from for a translated leaf crate whose
  entry is `fn main()`?** `global_arena` (harness-owned) is simplest for v1
  tests but is a lie for real `no_std` crates that receive buffers. Is
  `global_arena` acceptable for v1, or must every allocating fn thread `.param`
  from the start so v2 doesn't rewrite all signatures?
- **Q3. How aggressive should `UnsoundMarker` emission be in ReleaseSafe vs
  ReleaseFast?** Zig elides `std.debug.assert` in ReleaseFast (idiom §13), so
  `assert_unreachable` must be emitted as explicit `if (!cond) @panic(...)` to
  survive — but that changes code size/perf. Pin emission to ReleaseSafe (where
  checks actually run), or always harden? Interacts with the default build mode
  and the differential `zig test` harness.
