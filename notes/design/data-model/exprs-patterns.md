# Data model: Expr / Pattern / Statement (+ Zig-lowering hooks)

Subsystem note for the **lossless semantic IR** (pipeline: `parse -> resolve -> expand
-> lower -> IR -> desugar -> analyse -> emit -> zig fmt -> verify`, per
`notes/research/approaches.md` §1). This file covers the **behavior-bearing core** —
how the IR represents expressions, statements, and patterns, and every Zig-lowering
hook the emitter will consume. Item kinds, the type system, identities, and the crate
graph live in the sibling notes `items-types.md` and `crate-graph.md`; ownership/lifetimes
in `ownership-mem.md`. This note **references** their `DefId`/`TypeId`/`ItemRef`; it does
not redefine them.

Production contract (restated briefly, `notes/research/parsing-tooling.md` §4): a Rust
sidecar runs the real toolchain and emits a **lossless JSON semantic IR**; the Zig tool
consumes it over `std.json`. Every node is therefore a plain data struct with no
pointers-to-source, no lazily-resolved state, and no `anytype` — only what a JSON round
trip can carry losslessly. All nodes live in one Zig root module (`ir.zig`) shared with
the other three notes, so the JSON schema for the whole IR is one coherent top-level type.

---

## 0. Shared node spine (every node carries this)

The IR is a flat, id-referencing graph (DefId-style, per `notes/research/approaches.md`
§3.3 and the crate-graph/items contract). Every `Expr`, `Statement`, and `Pattern` node
opens with the same three fields so the desugar/analyse/emit passes get uniform access to
identity, source position, and the resolved type.

```zig
pub const NodeId  = u64;                 // project-scoped entity id, minted by the sidecar
pub const FileId  = u32;                 // index into the crate-graph file table

pub const Pos = struct { line: u32, col: u32 };
pub const SrcSpan = struct {
    file: FileId,
    start: Pos,
    end: Pos,                             // end is exclusive; line/col, 1-based
};

/// Common header for Expr, Pattern, Statement. Not a separate struct in the JSON
/// (it would add a nesting level); the three fields are inlined as sibling keys,
/// exactly as they appear here.
const Node = struct {
    id: NodeId,
    span: SrcSpan,
    ty: ?TypeId,                          // resolved type when known; null on type-erased nodes
};
```

- `ty: ?TypeId`: the semantic sidecar resolves types (rust-analyzer SCIP / rustc per
  `parsing-tooling.md` §2.3–2.4, `approaches.md` §2.2). `null` means the emitter must
  synthesize, and the analyse pass (monomorphisation/instantiation table) may fill it.
  Keeping it a nullable separate field on every node (rather than a side table) makes
  the IR self-describing and the JSON lossless without an extra lookup.
- `span` mirrors translate-c's span mapping role (`parsing-tooling.md` §1) so every
  diagnostic and every `#[translate(ignore)]` boundary case in v4 can locate source.
- **Reserved-word tags**: JSON/`std.json` tagged unions key on an identifier, but Rust
  node names collide with Zig keywords (`if`, `loop`, `match`, `for`, `try`). All
  discriminant strings in this file are chosen to be valid Zig identifiers
  (`if_else`, `r#loop` → `loop_`, `try_`); the `as_tagged_union` emission below makes
  this a hard rule, not a convention.

---

## 1. Expression node set

`Expr` is a tagged union over the v0/v1 surface **plus** deferred forms carried so the
model never hard-blocks future growth (`idiom-mapping.md` §9–10). Every payload itself
carries the `Node` fields (id/span/ty).

```zig
pub const Expr = struct {
    id: NodeId, span: SrcSpan, ty: ?TypeId,
    kind: ExprKind,
};

pub const ExprKind = union(enum) {
    // — literals & atoms (§1.1) —
    literal: Literal,
    path: PathExpr,                    // ident / value path; resolves to a DefId
    block: BlockExpr,                  // { stmts; tail? }
    unit: void,                        // `()` — an empty () expression/statement

    // — control flow (§1.2) —
    if_else: IfExpr,
    if_let: IfLetExpr,                 // if let P = e { .. }
    match: MatchExpr,
    loop_: LoopExpr,                   // `loop { }`        (tag: loop_)
    while_: WhileExpr,                 // `while c { }`     (tag: while_)
    for_: ForExpr,                     // `for p in e { }`  (tag: for_)
    break_: BreakExpr,                 // `break` / `break :l v`
    continue_: ContinueExpr,           // `continue` / `continue :l`

    // — calls & construction (§1.3) —
    call: Call,
    method_call: MethodCall,
    struct_lit: StructLit,
    enum_variant: EnumVariant,

    // — access (§1.4) —
    field: FieldExpr,
    index: IndexExpr,

    // — operators (§1.5) —
    binary: BinaryExpr,                // arithmetic, comparison, logic
    unary: UnaryExpr,                  // -, !, ~, *deref, &ref / &mut ref
    assign: AssignExpr,                // = and every compound form
    try_: TryExpr,                     // `?` on Result  (tag: try_)
    return_: ReturnExpr,               // `return e?`    (tag: return_)

    // — deferred seams (§4, not emitted in v1) —
    closure: ClosureExpr,
    iterator_chain: IteratorChainExpr,

    // — explicit refusal —
    unsupported: Unsupported,          // never silent omission
};
```

### 1.1 Literals and atoms

```zig
pub const Literal = union(enum) {
    int: IntLit,                       // 42, 0xFF, 1_000, 42u8
    float: FloatLit,                   // 3.14, 2e10
    character: CharLit,                // 'x', '\n'
    string: StringLit,                 // "abc" — []const u8 payload
    boolean: bool,                     // true / false
};

/// Lossless: keep the raw token text PLUS the decoded value. The emitter re-derives
/// Zig syntax (base, `@bitCast` for float bits) from `text`; `value` is the
/// machine meaning used by analyse/instantiation (`approaches.md` §3.3).
pub const IntLit = struct {
    text: []const u8,                  // original spelling, e.g. "0xFF"
    value: i128,                       // decoded value (sign handled)
    base: enum { dec, hex, oct, bin },
    ty_suffix: ?[]const u8,            // "u8", "i64", none (inferred)
};
pub const FloatLit = struct { text: []const u8, value: f64 };
pub const CharLit = struct { text: []const u8, value: u32 };   // scalar value
pub const StringLit = struct { bytes: []const u8 };            // decoded; emitter re-escapes
```

`path: PathExpr` is a resolved reference, not a name:
```zig
pub const PathExpr = struct {
    def: DefId,                        // resolved entity (variable, unit variant, const)
    generic_args: []const TypeArg,     // instantiation at the site (comptime args)
};
```
This collapses Rust's `x`, `Foo::Bar` (unit variant), and `Self::CONST` uniformly;
`desugar/collect_renames` (`approaches.md` §3.3) already resolved shadowing before the
IR, so no scope handling belongs here.

`block: BlockExpr`:
```zig
pub const BlockExpr = struct {
    statements: []const Statement,
    tail: ?Expr,                       // final expression without `;` (unit if none)
    labelled: ?[]const u8,             // 'a: { ... } — Zig emits :blk with unique label
};
```

### 1.2 Control flow

```zig
pub const IfExpr = struct {
    cond: Expr,
    then_: BlockExpr,
    r#else: ElseBranch,                // Zig-else; tag must be valid ident (use "else_branch")
};
pub const ElseBranch = union(enum) {
    none: void,
    block: BlockExpr,
    chain: *IfExpr,                    // else if — linearized, no dangling-else ambiguity
};

/// if let P = scrutinee { .. } else { .. }  — first-class, keeps lossless diagnostics;
/// lowered by the emit pass to optional capture / switch (idiom-mapping.md §9).
pub const IfLetExpr = struct {
    pattern: Pattern,
    scrutinee: Expr,
    then_: BlockExpr,
    r#else: ElseBranch,
};

pub const MatchExpr = struct {
    scrutinee: Expr,
    arms: []const MatchArm,
    /// Sidecar verdict: Option scrutinee lowers to `if`+optional capture, not switch
    /// (optionals are not unions — idiom-mapping.md §9). When set, emit ignores `arms`
    /// binding shape and emits optional capture; still lossless (arms retained).
    option_scrutinee: bool = false,
};
pub const MatchArm = struct {
    patterns: []const Pattern,         // collapsed or-pattern: `a | b =>` is 2 entries
    guard: ?Expr,                      // `n if n > 5 =>` — DEFERRED in v1 (see §5)
    body: Expr,
};

pub const LoopExpr = struct { body: BlockExpr };
pub const WhileExpr = struct { cond: Expr, body: BlockExpr };
pub const ForExpr = struct {
    pattern: Pattern,                  // irrefutable binding
    iterable: Expr,
    body: BlockExpr,
    iter_kind: IterKind,               // pre-computed by the sidecar for direct lowering
};
/// Which Zig `for` shape to emit (idiom-mapping.md §10; prior-work.md §1 rust2zig).
pub const IterKind = union(enum) {
    range: void,                       // a..b / a..=b → Zig `a..b`/`a..=b`
    slice: void,                       // &[T] → `for (slice) |x|`
    multi: []const Expr,               // zip(a,b) → `for (a, b) |x, y|` (index last in Zig)
    enumerate: void,                   // enumerate(xs) → `for (xs, 0..) |x, i|`
    adapter: IteratorChainExpr,        // anything else (v2/v3+; sealed now)
};

pub const BreakExpr    = struct { label: ?[]const u8, value: ?Expr };
pub const ContinueExpr = struct { label: ?[]const u8 };
```

### 1.3 Calls, methods, construction

rust2zig's `call.rs` splits free / associated / constructor; mirror that so the emitter
picks the right render (`f(a)`, `Foo.f(a)` / comptime, `Foo{...}`).

```zig
pub const Call = struct {
    call_kind: CallKind,
    args: []const Expr,
};
pub const CallKind = union(enum) {
    free: DefId,                       // f(a) — plain fn call
    associated: DefId,                 // Foo::f(a) → Zig `Foo.f(a)` (idiom-mapping §2)
    /// A constructor (`T::new()`, `Foo { .. }` whose fn returns Self). The emitter
    /// renders `Foo{ .x = .. }` from the resolved def's fields.
    constructor: DefId,
};

/// Method call with an implicit receiver. Receiver mode is explicit (Zig has no
/// implicit `self` — idiom-mapping.md §2): value/&self/&mut self drive the
/// emitted param type `self: Self` / `*const Self` / `*Self`.
pub const MethodCall = struct {
    receiver: Expr,
    receiver_mode: ReceiverMode,       // self | &self | &mut self
    method: DefId,                     // resolved impl method
    args: []const Expr,
};
pub const ReceiverMode = enum { value, shared, mutable };
// value  -> self: Self        (owned self moves)
// shared -> self: *const Self (&self)
// mutable-> self: *Self       (&mut self)

pub const StructLit = struct {
    def: DefId,
    fields: []const FieldInit,
    base: ?Expr,                       // `..base` struct-update — DEFERRED in v1
};
pub const FieldInit = struct { field: []const u8, value: Expr, shorthand: bool };
//   shorthand: `let x = 1; Foo { x }` → field "x", value PathExpr(x), shorthand=true

pub const EnumVariant = struct {
    def: DefId,                        // the enum
    variant: []const u8,               // tag name
    tuple_fields: []const Expr,        // Shape::Circle(r) — positional
    named_fields: []const FieldInit,   // Shape::Rect { w, h } — named
};
```

### 1.4 Access

```zig
pub const FieldExpr = struct { base: Expr, field: []const u8, resolved: DefId };
pub const IndexExpr = struct { base: Expr, index: Expr };
```

### 1.5 Operators — where correctness traps live

Overflow semantics are the #1 Rust↔Zig hazard (`prior-work.md` §4 lesson 4; Bun's 19
regressions were "syntactically identical ... semantically different"). Rust `a + b`
**panics on overflow in debug, wraps in release**; Zig `+` panics in safety builds and
`+%` wraps. The IR therefore carries an explicit, sidecar-decided overflow mode per
arithmetic operator so emission is deterministic and never "relies on defaults"
(`idiom-mapping.md` §13).

```zig
pub const Overflow = enum { checked, wrapping, saturating };
// checked  -> zig  `+`   (briefly: matches Rust DEBUG intent: panic on overflow)
// wrapping -> zig  `+%`  (matches Rust RELEASE wrap intent)
// saturating-> zig `+|`  (saturating_add)

pub const BinaryExpr = struct {
    op: BinaryOp,
    overflow: Overflow,                // meaningful for add/sub/mul; ignored otherwise
    lhs: Expr,
    rhs: Expr,
};
pub const BinaryOp = union(enum) {
    add, sub, mul, div, rem,           // arithmetic (+overflow)
    bit_and, bit_or, bit_xor,
    shl, shr,                          // `>>` arithmetic on iN, logical on uN — emit accordingly
    eq, ne, lt, le, gt, ge,            // comparison → `== != < <= > >=`
    boolean_and, boolean_or,           // && || (short-circuit; Zig `and`/`or`)
};

pub const UnaryExpr = struct { op: UnaryOp, operand: Expr };
pub const UnaryOp = union(enum) {
    negate,                            // -x
    logical_not,                       // !x
    bit_not,                           // ~x → @not
    deref,                             // *x  (post binary-desugar, `idiom-mapping`/match_ergonomics made derefs explicit)
    r#ref: ReceiverMode,               // &x / &mut x → *const x / *x (receiver-mode drives it)
};

pub const AssignExpr = struct {
    target: Expr,                      // path/field/index lvalue
    op: AssignOp,
    value: Expr,
    overflow: Overflow,                // for compound +/-, as above
};
pub const AssignOp = union(enum) { plain,
    add, sub, mul, div, rem,
    bit_and, bit_or, bit_xor, shl, shr };

pub const TryExpr = struct { inner: Expr };      // `e?` → Zig `try e` (idiom §7)
pub const ReturnExpr = struct { value: ?Expr };  // `return` / `return e`

/// Anything the emitter cannot lower yet. MUST carry a reason; never omitted silently.
pub const Unsupported = struct { reason: []const u8, suggested_version: enum { v1, v2, v3 } };
```

**`?`/`unwrap`/`expect`** (`idiom-mapping.md` §13): `?` is `TryExpr` → `try`. `unwrap()`
/ `expect()` are ordinary `MethodCall`s on `Result`/`Option` that the emitter recognizes
by resolved `method` DefId and lowers to `catch unreachable` / `orelse unreachable`.
Keeping them as method calls (not special nodes) preserves the lossless IR and lets the
`analyse` pass decide; this mirrors rust2zig's type-driven call handling
(`prior-work.md` §1).

---

## 2. Pattern node set

`Pattern` mirrors Rust's pattern grammar but is **post-desugar**: the
`match_ergonomics` pass (`approaches.md` §3.3) has already made default binding modes
explicit, so every binding carries an explicit `BindMode` and there are no implicit
`ref` patterns to re-derive at emit time.

```zig
pub const Pattern = struct {
    id: NodeId, span: SrcSpan, ty: ?TypeId,
    kind: PatternKind,
};

pub const PatternKind = union(enum) {
    wildcard: void,                    // `_`  → Zig `_`
    binding: Binding,
    literal: Literal,                  // `1`, `'a'` — match literals
    path: PathPat,                     // unit enum variant / const pattern: Foo::Variant
    tuple: TuplePat,                   // (a, b, ..)
    slice: SlicePat,                   // [a, b, ..rest, c]
    struct_pat: StructPat,             // Point { x, y, .. }
    reference: ReferencePat,           // &pat / &mut pat (rare post-desugar; kept for full surface)
    or: OrPat,                         // `a | b`
    range: RangePat,                   // `1..=5`, `'a'..='z'`
    // guard is a MatchArm field, NOT a Pattern
};

pub const Binding = struct {
    name: []const u8,
    mode: BindMode,                    // decided by match_ergonomics
    mutable: bool,                     // `mut x`
};
pub const BindMode = union(enum) {
    value: void,                       // capture by value → `|x|`
    shared_ref: void,                  // ref binding → Zig capture `|x|` (const)
    mut_ref: void,                     // ref mut/&mut → Zig `|*x|` pointer capture
};                                     //   (idiom-mapping.md §9: `|v|` value, `|*v|` ptr)

pub const PathPat = struct { def: DefId, variant: ?[]const u8 };
pub const TuplePat = struct { elements: []const Pattern, rest: bool };
pub const SlicePat = struct { elements: []const Pattern, rest: ?Pattern };
pub const StructPat = struct {
    def: DefId,
    fields: []const FieldPat,          // name : pat  |  shorthand name
    rest: bool,                        // `..`
    // #[non_exhaustive] handled at the arm/switch level: emitter synthesizes a `_` arm
};
pub const FieldPat = struct { field: []const u8, pat: ?Pattern, shorthand: bool };
pub const ReferencePat = struct { mode: BindMode, inner: *Pattern };
pub const OrPat = struct { alternatives: []const Pattern };
pub const RangePat = struct { lo: ?Expr, hi: ?Expr, inclusive: bool };
```

**Lowering hooks (`idiom-mapping.md` §9)**:
- `Binding` value mode → `switch` capture `|x|`; `mut_ref` mode → `|*x|`.
- `path` (unit variant) / struct / tuple / slice → `switch` on the tag with payload
  capture; `wildcard` → Zig `else`.
- `or` → multiple switch prongs to the same body (already collapsed into `MatchArm.patterns`).
- `range`/`literal` → literal switch prongs (only integer/char in v1).
- `Option` scrutinee: emit ignores the binding-shape switch and uses optional capture
  `if (opt) |v|` (`MatchExpr.option_scrutinee`).

---

## 3. Statement set

```zig
pub const Statement = struct {
    id: NodeId, span: SrcSpan, ty: ?TypeId,
    kind: StatementKind,
};
pub const StatementKind = union(enum) {
    let: LetStmt,                      // let [mut] pat [: ty] = init?;
    let_else: LetElseStmt,             // let Some(v) = opt else { ... };  (§9)
    expr: Expr,                        // expression statement (incl. `;`-terminated)
    item: ItemRef,                     // nested item (fn/struct/const in a block) — see items-types.md
};
pub const LetStmt = struct {
    pattern: Pattern,                  // irrefutable in v1 (Binding only); refutable ⇒ must lower to if-let
    init: ?Expr,
    ty: ?TypeRef,                      // explicit annotation, if present (C-repr helper)
};
pub const LetElseStmt = struct {
    pattern: Pattern,                  // refutable
    init: Expr,                        // Option<T> → `orelse return`/block (idiom §9)
    else_block: BlockExpr,
};
```
- A bare `;` (empty expr-statement) is `StatementKind.expr` wrapping `ExprKind.unit`.
- `item` defers entirely to `items-types.md` (ItemRef is the crate-graph DefId); the
  emitter renders nested items inline the same way it renders top-level ones.

---

## 4. Closures & iterator chains — the deferred SEAM

Neither is emitted in v1 (`idiom-mapping.md` §10; `prior-work.md` §1: rust2zig handles
only zero/immutable-capture `Fn`). But the **node shapes must exist now** so the emitter
and analyse passes are never rewritten when v2/v3 arrives.

### 4.1 Closure → callable struct

rust2zig's proven lowering: a closure becomes "a struct value with a
`call(self: @This(), ...) R` method, instantiated as `{}`(no captures) or `{ .a = a, ... }`
(with captures), with `.call` appended at call sites" (`prior-work.md` §1; `idiom-mapping.md` §10).

```zig
pub const ClosureExpr = struct {
    captures: []const Capture,
    params: []const Pattern,           // each Binding
    return_ty: ?TypeRef,
    body: BlockExpr,
    trait: ClosureTrait,               // which Fn* to emulate
};
pub const ClosureTrait = enum { r#fn, fn_mut, fn_once };
pub const Capture = struct { name: []const u8, mode: CaptureMode, ty: TypeRef };
pub const CaptureMode = enum { by_value, by_ref, by_mut_ref };
//   emit:  const C = struct { a: T, p: U,
//                              fn call(self: C, x: T) R { <body> } };
//          const f = C{ .a = a, .p = p };     // captures
//          f.call(x)                          // call sites append `.call`
```

### 4.2 Iterator chain → explicit for-loop lowerings

`idiom-mapping.md` §10 and rust2zig's dialect limit iterators to
ranges/arrays/slices/zip/enumerate ("other ... are TODO", `prior-work.md` §1). The IR
models the chain generically; the emitter lowers each adapter to an explicit loop.

```zig
pub const IteratorChainExpr = struct {
    source: Expr,                      // the base iterable
    adapters: []const IteratorAdapter, // applied left-to-right
};
pub const IteratorAdapter = union(enum) {
    map: MapAdapter,
    filter: FilterAdapter,
    enumerate: void,                   // → for (xs, 0..)
    zip: ZipAdapter,
    range_rev: void,                   // (.rev() on a range)
    other: Unsupported,                // any adapter without a direct lowering
};
pub const MapAdapter    = struct { closure: ClosureExpr };
pub const FilterAdapter = struct { closure: ClosureExpr };
pub const ZipAdapter    = struct { other: Expr };   // pairs with `source` in a multi-for
```
The `IterKind.adapter` case (§1.2) is how a `for`-loop over such a chain appears in the
IR; the emitter either expands it to a nested `for`/`if` or (for `other`) refuses with
the `Unsupported` marker. **Sealing, not hard-blocking**: the union is exhaustive today,
so `analyse` can reject unknown adapters loudly, but the node slots already exist so
v3 only adds arms, not a new shape.

---

## 5. v1 subset delimitation

**(In v1 — emitted and tested)** per `approaches.md` §6 v1 dialect and
`idiom-mapping.md` §18–19. Marker: the node is present in the union and `emit` handles it.
- **Expr**: all literals; path; block (incl. labelled); unit; `if_else`; `if_let`;
  `match` on enums/tagged unions/bool (Option → optional-capture path); `loop_`/`while_`;
  `for_` over `IterKind.{range,slice,multi,enumerate}`; `break_`/`continue_` with labels;
  `call.{free,associated,constructor}`; `method_call` with all three receiver modes;
  `struct_lit` (no `..base`); `enum_variant`; `field`/`index`; `binary` (all ops, explicit
  `Overflow`); `unary`; `assign` (all `AssignOp`); `try_` (on `Result`); `return_`.
- **Pattern**: `wildcard`, `binding` (all three `BindMode`), `literal` (int/char),
  `path` (unit variant), `struct_pat`, `tuple_pat`, `slice_pat`, `reference`,
  `or` (collapsed arm patterns), `range` (int/char).
- **Stmt**: `let` (irrefutable binding), `let_else`, `expr`, `item`.
- **Guard**: `MatchArm.guard` is INCLUDED as a field but **must be null** in v1 (deferred
  emission; a non-null guard is a hard parse error carrying `Unsupported`).

**(Deferred — node exists, emission refuses via `Unsupported`)**:
- `match` guards (lowering is known: nested `if` in a `blk: {...}` per `idiom §9`, but not
  shipped in v1).
- `closure` / `iterator_chain` (any adapter beyond the enumerated set; v2/v3). The
  enumerated adapters are wired in `IterKind` but the **chain** form is deferred — v1
  `for` loops carry a pre-lowered `iter_kind`, not an adapter chain.
- `format!` / `concat!` and all `std::fmt` macro hits — deferred; `println!("{}", x)`
  needs type-driven format specifiers (rust2zig "hacked with sed", `prior-work.md` §1).
- `struct_lit.base` (`..x` struct-update).
- `let` with a refutable pattern that is not `let-else` (must become `if_let` in the sidecar).
- `MatchExpr.option_scrutinee` + `Result`/`?`: Result `?` is in; `catch_unwind` and the
  whole `panic!`-to-Result path are out (`idiom §13` — a redesign, not a translation).

The rule, per the shared contract: **every unsupported form is an explicit
`Unsupported` marker with a `reason`, never a silent omission.** `analyse` also rejects
any node marked deferred that reaches it in a v1-emit run, so the dialect boundary is
enforced in one place.

---

## 6. JSON encoding (draft)

Consumed by the Zig emitter via `std.json` (`parsing-tooling.md` §4). The top-level IR
is a `struct { exprs: []const Expr, stmts: []const Statement, ... }` — ids and spans are
inline; child references (`*Expr` in `ElseBranch.chain`, `*Pattern` in `ReferencePat`)
serialize as their `NodeId`, pointing into the flat tables the crate-graph note owns.
This keeps JSON acyclic and cheap to parse.

A tagged union encodes as an object with the **single discriminant key**:
```zig
// emitter/deserializer rule: union(enum) → { "<tag>": <payload fields> }
//   `void` payloads → { "<tag>": {} }            (e.g. unit, wildcard)
//   `bool` payloads → { "<tag>": true }          (e.g. Literal.boolean)
```
Every tag string is chosen to be a valid Zig identifier so `std.json` can reconstruct
the exact union (see reserved-word rule, §0). Example — `n = a + b` with debug intent:

```json
{
  "id": 12, "span": { "file": 0, "start": {"line": 5, "col": 1}, "end": {"line": 5, "col": 9} },
  "ty": 7,
  "kind": {
    "let": {
      "pattern": { "id": 13, "span": {"file": 0,"start":{"line":5,"col":5},"end":{"line":5,"col":6}},
                   "ty": 6, "kind": { "binding": { "name": "n", "mode": "value", "mutable": false } } },
      "init": {
        "id": 14, "span": {"file": 0,"start":{"line":5,"col":9},"end":{"line":5,"col":14}},
        "ty": 6,
        "kind": { "binary": { "op": "add", "overflow": "checked",
                              "lhs": { "kind": { "path": { "def": 3, "generic_args": [] } } },
                              "rhs": { "kind": { "path": { "def": 4, "generic_args": [] } } } } }
      },
      "ty": null
    }
  }
}
```

Note ids on the *payload* `Expr`s are elided in this sketch for brevity; in the real IR
every `Expr`/`Pattern`/`Statement` carries its `id`/`span`/`ty`. The `binary` payload's
`overflow` field is exactly what makes the checked-vs-wrapping decision explicit and
deterministic at decode time.

---

## 7. Open design questions

1. **Overflow default when the sidecar says nothing.** The IR carries `Overflow` per op,
   but what does `analyse` default to when the sidecar (SCIP) does not record the intended
   Rust build mode — Rust debug (checked/panic → Zig `+`) or Rust release (wrap → Zig `+%`)?
   The choice silently changes emitted semantics; we need a crate-level default declared
   once in the IR header, or a hard requirement that the sidecar always annotate.

2. **`if let` / `let-else` as first-class nodes vs. sidecar lowering to `match`.**
   Keeping them lossless aids diagnostics and the `#[translate(ignore)]` boundary, but
   duplicates the match-lowering machinery and forces the emitter to handle both shapes.
   Is the duplication worth it, or should the sidecar lower `if let`→single-arm match and
   `let-else`→`orelse` before the IR?

3. **Where do resolved types live — inline per node (`ty: ?TypeId`) or a side table
   keyed by `NodeId`?** Inline is self-describing and simpler for a lossless JSON round
   trip, but bloats the file and duplicates type ids across deeply nested expressions;
   a side table is compact but makes single-node consumers do a lookup. Which wins for
   the emission hot path and for mono-monomorphisation cache keys?

---

*Cross-references*: `notes/research/idiom-mapping.md` §2, §7, §9–10, §13; `notes/research/approaches.md` §1, §3.3, §6; `notes/research/prior-work.md` §1, §4 (lesson 4); `notes/research/parsing-tooling.md` §4. Sibling design notes: `crate-graph.md`, `items-types.md`, `ownership-mem.md`.
