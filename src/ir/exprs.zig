//! translate_rust.model.exprs — Expr / Pattern / Statement (P3 model layer).
//!
//! The behavior-bearing core of the lossless semantic IR: every Expr,
//! Pattern, and Statement carries the shared header (id/span/ty) and
//! dispatches via a tagged union.
//!
//! ## Flat ID graph (§6)
//! The IR is a flat, id-referencing graph. Cross-node references (Expr↔Expr,
//! Expr↔Pattern, Statement↔Expr, etc.) are `NodeId` indices into the
//! corresponding top-level tables (exprs, stmts, patterns).  This breaks what
//! would otherwise be unresolvable Zig dependency cycles (Expr ↔ BlockExpr,
//! Pattern ↔ TuplePat, Statement ↔ Expr) and matches the JSON wire format
//! where every child reference serialises as its NodeId integer.
//!
//! ## Reserved-word tags
//! JSON/`std.json` tagged unions key on an identifier. Tags that collide with
//! Zig keywords use raw-identifier syntax: `@"else"`, `@"ref"`, `@"fn"`,
//! `@"or"`. Trailing-underscore tags (`loop_`, `while_`, `for_`, `break_`,
//! `continue_`, `try_`, `return_`) keep JSON discriminants valid Zig idents.

const std = @import("std");

const spine = @import("spine.zig");
const types = @import("types.zig");

// ── §0 Shared node spine (aliases bridging design names to spine types) ────

/// Dense per-node id (mirrors spine.EntityId; named NodeId for design parity).
pub const NodeId = spine.EntityId;
/// Index into the type table (mirrors spine.TypeId).
pub const TypeId = spine.TypeId;
/// Resolved entity id — variable, fn, const, unit variant, etc.
pub const DefId = spine.EntityId;
/// Item reference for nested-item statements; the crate-graph EntityId.
pub const ItemRef = spine.EntityId;
/// Type-table reference (closures/captures where the type may be erased).
pub const TypeRef = spine.TypeId;
/// A single type argument at a call site (comptime arg).
pub const TypeArg = types.Type;

// ── §1 Expression node set ─────────────────────────────────────────────────

pub const Expr = struct {
    id: NodeId,
    span: spine.Span,
    ty: ?TypeId,
    kind: ExprKind,
};

pub const ExprKind = union(enum) {
    // — literals & atoms (§1.1) —
    literal: Literal,
    array: ArrayExpr,
    vec_lit: VecLit,
    range: RangeExpr,
    path: PathExpr,
    block: BlockExpr,
    unit: void,

    // — control flow (§1.2) —
    if_else: IfExpr,
    if_let: IfLetExpr,
    match: MatchExpr,
    loop_: LoopExpr,
    while_: WhileExpr,
    for_: ForExpr,
    break_: BreakExpr,
    continue_: ContinueExpr,

    // — calls & construction (§1.3) —
    call: Call,
    core_call: CoreCall,
    core_function: CoreFunctionValue,
    method_call: MethodCall,
    struct_lit: StructLit,
    enum_variant: EnumVariant,
    external_variant: ExternalVariant,
    format_write: FormatWriteExpr,

    // — access (§1.4) —
    field: FieldExpr,
    index: IndexExpr,

    // — scalar conversions (§1.5) —
    cast: CastExpr,

    // — operators (§1.6) —
    binary: BinaryExpr,
    unary: UnaryExpr,
    assign: AssignExpr,
    try_: TryExpr,
    return_: ReturnExpr,

    closure: ClosureExpr,
    iterator_chain: IteratorChainExpr,

    // — explicit divergence —
    panic_: PanicExpr,

    // — explicit refusal —
    unsupported: Unsupported,
};

pub const FieldExpr = struct {
    base: NodeId,
    field: []const u8,
    resolved: DefId,
};
pub const IndexExpr = struct {
    base: NodeId,
    index: NodeId,
};

// §1.1 Literals & atoms ─────────────────────────────────────────────────────

pub const Literal = union(enum) {
    int: IntLit,
    float: FloatLit,
    character: CharLit,
    string: StringLit,
    byte_array: ByteArrayLit,
    boolean: bool,
};

/// Lossless: keep raw token text PLUS decoded value. Emitter re-derives Zig
/// syntax (base, `@bitCast` for float bits) from `text`; `value` is the
/// machine meaning used by analyse/instantiation.
pub const IntLit = struct {
    text: []const u8,
    value: i128,
    base: enum { dec, hex, oct, bin },
    ty_suffix: ?[]const u8,
};

pub const FloatLit = struct {
    text: []const u8,
    value: f64,
};

pub const CharLit = struct {
    text: []const u8,
    value: u32,
};

pub const StringLit = struct {
    bytes: []const u8,
};

/// A fixed byte-array literal (Rust `b"..."` / `[u8; N]` constant pool).
/// `items` holds the raw bytes; the empty array is allowed (for `b""`).
/// Lossless: the backend re-derives Zig array syntax (`&[_]u8{ ... }`,
/// collapsing to `&[_]u8{V} ** N` when every byte is equal).
pub const ByteArrayLit = struct {
    items: []const u8,
};

/// A fixed-length array literal: `[a, b, c]` or the repeating form `[e; N]`.
/// `elements` holds the element expr NodeIds (all of them for the explicit
/// list form; exactly one element for the repeating form). When `repeat` is
/// non-null the total length is `repeat` (Rust `[e; N]`); otherwise the total
/// length is `elements.len`. Lossless: element exprs are full `Expr` nodes and
/// the backend derives Zig `[_]T{ ... }` / `[_]T{ e } ** N` from them.
///
/// The count is a plain number because a fixed-length array's length is part
/// of its type and therefore known before any code runs. `VecLit` has no such
/// guarantee, which is why its count is a `VecRepeatCount`.
pub const ArrayExpr = struct {
    elements: []const NodeId,
    /// Target-side repeat count; independent of the translator's pointer width.
    repeat: ?u64,
};

/// A `vec![e; N]` repeat count: either a number the translator already holds,
/// or the `Expr` node that produces it.
///
/// `Vec` is a runtime container, so `vec![e; N]` states how many elements a
/// value holds without the count being part of any type: `vec![0u8; n]`
/// repeats as many times as `n` evaluates to, and `n` is an ordinary
/// expression with its own effects, types, lifetimes, and captures.
pub const VecRepeatCount = union(enum) {
    /// A count the translator holds outright; wide so a count a 64-bit target
    /// can state survives any host.
    literal: u64,
    /// A count the target evaluates, as an expression node.
    expression: NodeId,
};

/// A parsed Rust `vec!` literal, distinct from a fixed-length array literal.
/// When `repeat` is null, `elements` may contain any number of nodes, including
/// zero. When `repeat` is set, `elements` must contain exactly one node.
/// This records macro semantics without claiming runtime `Vec` support.
pub const VecLit = struct {
    elements: []const NodeId,
    /// Target-side repeat count; independent of the translator's pointer width.
    repeat: ?VecRepeatCount,
};

/// A range expression (`start..end`, `start..=end`, or `start..`).
/// The absent end is valid for open-ended indexing/slicing only; iteration
/// requires a bounded range.
pub const RangeExpr = struct {
    start: NodeId,
    end: ?NodeId,
    inclusive: bool = false,
};

/// A source-level panic or unreachable expression. Diverging expressions
/// must carry the never type in their shared expression header.
pub const PanicExpr = struct {
    message: []const u8,
};

/// A resolved reference, not a name. Collapses Rust's `x`, `Foo::Bar` (unit
/// variant), and `Self::CONST` uniformly; desugar already resolved shadowing.
pub const PathExpr = struct {
    def: DefId,
    generic_args: []const TypeArg,
};

/// Block expression. `statements` are indices into the stmt table (in order);
/// `tail` is the index of the final tail expression (null → unit `()`).
pub const BlockExpr = struct {
    statements: []const NodeId,
    tail: ?NodeId,
    labelled: ?[]const u8,
};

// §1.2 Control flow ─────────────────────────────────────────────────────────

pub const IfExpr = struct {
    /// Condition expression (index into expr table).
    cond: NodeId,
    then_: BlockExpr,
    @"else": ElseBranch,
};

pub const ElseBranch = union(enum) {
    none: void,
    block: BlockExpr,
    /// `else if` — linearised, no dangling-else ambiguity.  NodeId of the
    /// chained IfExpr (index into expr table).
    chain: NodeId,
};

/// `if let P = scrutinee { .. } else { .. }` — first-class, lossless
/// diagnostics; backend lowers to optional capture / switch.
pub const IfLetExpr = struct {
    /// Pattern node index (index into pattern table).
    pattern: NodeId,
    /// Scrutinee expression index (expr table).
    scrutinee: NodeId,
    then_: BlockExpr,
    @"else": ElseBranch,
};

pub const MatchExpr = struct {
    /// Scrutinee expression index (expr table).
    scrutinee: NodeId,
    arms: []const MatchArm,
    /// Sidecar verdict: Option scrutinee lowers to `if`+optional capture, not
    /// switch (optionals are not unions). When set, emit ignores `arms`
    /// binding shape and emits optional capture; still lossless.
    option_scrutinee: bool = false,
};

pub const MatchArm = struct {
    /// Collapsed or-pattern: `a | b =>` is 2 entries. Each is a pattern-table
    /// index.
    patterns: []const NodeId,
    /// `n if n > 5 =>` — DEFERRED in v1 (must be null at emit time).  Expr
    /// table index when present.
    guard: ?NodeId,
    /// Arm body expression index (expr table).
    body: NodeId,
};

pub const LoopExpr = struct {
    body: BlockExpr,
};

pub const WhileExpr = struct {
    /// Condition expression index (expr table).
    cond: NodeId,
    body: BlockExpr,
    /// Optional pattern capture index (pattern table); null for standard while loops.
    capture: ?NodeId = null,
};

pub const ForExpr = struct {
    /// Irrefutable binding pattern index (pattern table).
    pattern: NodeId,
    /// Iterable expression index (expr table).
    iterable: NodeId,
    body: BlockExpr,
    iter_kind: IterKind,
};

/// Which Zig `for` shape to emit; pre-computed by the sidecar.
pub const IterKind = union(enum) {
    range: void, // a..b / a..=b
    slice: void, // &[T]
    /// zip(a,b) — each element is an expr-table index.
    multi: []const NodeId,
    enumerate: void, // enumerate(xs)
    /// v2/v3+ adapter chain; sealed now.
    adapter: IteratorChainExpr,
};

pub const BreakExpr = struct {
    label: ?[]const u8,
    /// Break value expression index (expr table); null = break with unit.
    value: ?NodeId,
};

pub const ContinueExpr = struct {
    label: ?[]const u8,
};

// §1.3 Calls, methods, construction ─────────────────────────────────────────

pub const Call = struct {
    call_kind: CallKind,
    /// Argument expression indices (expr table).
    args: []const NodeId,
};

/// A call to a supported Rust core or standard-library primitive.
pub const CoreFunction = enum {
    mem_size_of,
    mem_transmute,
    mem_size_of_val,
    ptr_copy_nonoverlapping,
    /// Rust integer `T::from_le_bytes(bytes)`: one type argument `T`, one
    /// value argument `[size_of::<T>()]u8`, and result `T`. The width belongs
    /// to the compilation target, including for `usize` and `isize`.
    /// Unlike `mem_transmute`, this decodes little-endian on every target.
    prim_from_le_bytes,
    /// Rust integer `value.to_le_bytes()`: one type argument `T`, one value
    /// argument `T`, and result `[size_of::<T>()]u8`. Pointer-sized widths
    /// remain target-dependent. Unlike `mem_transmute`, this encodes
    /// little-endian on every target.
    prim_to_le_bytes,
    /// Rust `MaybeUninit::<T>::uninit()`. One type argument `T`, no value
    /// arguments, and result `core::mem::MaybeUninit<T>`, not a live `T`.
    /// Backend layout remains transparent `T`. The array a source writes
    /// (`[MaybeUninit::<u8>::uninit(); N]`) is the separate `.array` node above
    /// this one, carrying `repeat = N`. Rust evaluates the element once and
    /// repeats the value; making the call array-typed would conflate the
    /// element with the enclosing array and its independent length.
    ///
    /// The value is genuinely UNINITIALISED, which is why it cannot be a
    /// zero-filled array literal: the source promised the bytes hold nothing
    /// until it writes them, and initialising them is a different program.
    maybe_uninit_uninit,
    /// Rust `rand_core::impls::fill_bytes_via_next(rng, dest)`, the default body
    /// of `RngCore::fill_bytes`. `args` is `[rng, dest]`: the receiver first
    /// because that is the borrow `fill_bytes` takes, then the slice to fill.
    /// Zero type arguments, two value arguments, and result `unit`. The
    /// receiver is mutable and `dest` is a mutable byte slice. Its identity
    /// is the `rand_core::impls` path, not an unrelated same-named function.
    rng_fill_bytes_via_next,
    /// Rust `core::hash::Hasher::write_uN` and the rest of the family's default
    /// bodies. `generic_args[0]` is the primitive being written and `args` is
    /// `[hasher, value]`. The default body writes the value's OWN bytes, which
    /// is native-endian. One integer type argument, two value arguments
    /// (mutable hasher and that integer), and result `unit`. A source impl's
    /// override must dispatch to its own method instead of this default.
    hash_write_primitive,
    ptr_write_bytes,
    ptr_read_unaligned,
    slice_from_raw_parts,
    slice_from_raw_parts_mut,
    str_from_utf8,
    str_from_utf8_unchecked,
    string_from_utf8,
    string_from_utf8_lossy,
    string_from_utf8_unchecked,
    cmp_min,
    cmp_max,
    default_value,
    convert_from,
    /// Canonical `num_traits::Bounded::min_value`: one type argument `I`,
    /// zero value arguments, result `I`. Source trait implementations take
    /// precedence over the target-integer minimum fallback.
    numeric_min_value,
    /// Canonical `num_traits::Bounded::max_value`, with the same shape and
    /// source-override precedence as `numeric_min_value`.
    numeric_max_value,
    /// Canonical `num_traits::Zero::zero`: one type argument `I`, zero value
    /// arguments, result `I`. This is not `Default::default`; source trait
    /// implementations take precedence over the typed integer-zero fallback.
    numeric_zero,
    /// Canonical `num_traits::One::one`, with the same shape and source-
    /// override precedence as `numeric_zero`, and integer-one fallback.
    numeric_one,
};

/// A core-library function item. It carries type arguments but no value
/// arguments; applying it remains a distinct `core_call` expression.
pub const CoreFunctionValue = struct {
    function: CoreFunction,
    generic_args: []const types.Type = &.{},
};

/// An actual core-library call. This never denotes a function value.
pub const CoreCall = struct {
    function: CoreFunction,
    generic_args: []const types.Type = &.{},
    args: []const NodeId = &.{},
};

pub const CallKind = union(enum) {
    free: DefId, // f(a)
    associated: DefId, // Foo::f(a) → Foo.f(a)
    constructor: DefId, // T::new() / Foo { .. }
};

/// Method call with explicit receiver mode (Zig has no implicit `self`).
pub const MethodCall = struct {
    /// Receiver expression index (expr table).
    receiver: NodeId,
    receiver_mode: ReceiverMode,
    method: DefId,
    /// Argument expression indices (expr table).
    args: []const NodeId,
    /// The method's own turbofish: `xs.collect::<Vec<u8>>()` pins the result
    /// type at the call site, exactly as it does in Rust. Empty when the
    /// source wrote no turbofish, in which case inference decides. Same
    /// representation as `PathExpr.generic_args`.
    generic_args: []const types.Type = &.{},
};
pub const FormatWriteExpr = struct {
    writer: NodeId,
    template: []const u8,
    args: []const NodeId,
};

pub const ReceiverMode = enum {
    value, // self: Self
    shared, // self: *const Self (&self)
    mutable, // self: *Self (&mut self)
};

pub const StructLit = struct {
    def: DefId,
    fields: []const FieldInit,
    /// `..base` struct-update — DEFERRED in v1.  Expr table index.
    base: ?NodeId,
};

pub const FieldInit = struct {
    field: []const u8,
    /// Value expression index (expr table).
    value: NodeId,
    /// `let x = 1; Foo { x }` → field "x", value PathExpr(x), shorthand=true.
    shorthand: bool,
};

pub const EnumVariant = struct {
    def: DefId,
    variant: []const u8,
    /// Positional tuple fields (Shape::Circle(r)); each an expr-table index.
    tuple_fields: []const NodeId,
    /// Named fields (Shape::Rect { w, h }).
    named_fields: []const FieldInit,
};

/// A variant owned by an external nominal enum with no local graph entity.
pub const ExternalVariant = struct {
    owner: types.ExternalNominal,
    variant: []const u8,
    tuple_fields: []const NodeId = &.{},
    named_fields: []const FieldInit = &.{},
};

// §1.5 Scalar conversions ───────────────────────────────────────────────────

pub const ConversionKind = enum {
    as_,
    primitive_from,
};

/// A validated primitive scalar conversion (`value as Target`).
pub const CastExpr = struct {
    /// Conversion syntax and semantics.
    kind: ConversionKind = .as_,
    /// Source expression index (expr table).
    operand: NodeId,
    /// Validated source type. This is explicit because transient composite
    /// types (for example a loop capture reference) are not guaranteed to be
    /// interned in `Bodies.types`.
    source_type: types.Type,
    /// Primitive target type index (type table).
    target: TypeId,
};

// §1.6 Operators ────────────────────────────────────────────────────────────

/// Per-site overflow mode: sidecar-decided so emit is deterministic and never
/// "relies on defaults".
pub const Overflow = enum {
    checked, // zig  `+`   (panic on overflow, matches Rust debug)
    wrapping, // zig  `+%`  (wrap, matches Rust release)
    saturating, // zig  `+|`
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    overflow: Overflow, // meaningful for add/sub/mul; ignored otherwise
    /// Left-hand expression index (expr table).
    lhs: NodeId,
    /// Right-hand expression index (expr table).
    rhs: NodeId,
};

pub const BinaryOp = union(enum) {
    add,
    sub,
    mul,
    div,
    rem, // arithmetic (+overflow)
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr, // `>>` arithmetic on iN, logical on uN — emit accordingly
    eq,
    ne,
    lt,
    le,
    gt,
    ge, // comparison
    boolean_and,
    boolean_or, // && || (short-circuit)
};

pub const UnaryExpr = struct {
    op: UnaryOp,
    /// Operand expression index (expr table).
    operand: NodeId,
};

pub const UnaryOp = union(enum) {
    negate, // -x
    logical_not, // !x
    bit_not, // ~x → @not
    deref, // *x (post binary-desugar, derefs explicit)
    ref: ReceiverMode, // &x / &mut x → *const x / *x
};

pub const AssignExpr = struct {
    /// Lvalue expression index (path/field/index).
    target: NodeId,
    op: AssignOp,
    /// Value expression index (expr table).
    value: NodeId,
    overflow: Overflow, // for compound +/-, as above
};

pub const AssignOp = union(enum) {
    plain,
    add,
    sub,
    mul,
    div,
    rem,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
};

pub const TryExpr = struct {
    /// Inner expression index (expr table); `e?` → zig `try e`.
    inner: NodeId,
};

pub const ReturnExpr = struct {
    /// Return value expression index (expr table); null = `return` with unit.
    value: ?NodeId,
};

// §4 Closures & iterator chains — the deferred SEAM ─────────────────────────

/// rust2zig's proven lowering: closure → callable struct with `.call`.
pub const ClosureExpr = struct {
    captures: []const Capture,
    /// Parameter pattern indices (pattern table); each a Binding.
    params: []const NodeId,
    return_ty: ?TypeRef,
    body: BlockExpr,
    trait: ClosureTrait,
};

pub const ClosureTrait = enum {
    @"fn",
    fn_mut,
    fn_once,
};

pub const Capture = struct {
    name: []const u8,
    mode: CaptureMode,
    ty: TypeRef,
};

pub const CaptureMode = enum {
    by_value,
    by_ref,
    by_mut_ref,
};

/// The backend lowers each adapter to an explicit loop; sealed union so
/// `analyse` rejects unknown adapters loudly but v3 only adds arms.
pub const IteratorTerminal = enum {
    /// Leave the adapter chain as an iterator value.
    iterator,
    /// Materialize the chain into an owned `Vec`.
    collect_vec,
    /// Fold the chain with integer addition.
    sum,
};

pub const IteratorChainExpr = struct {
    /// Base iterable expression index (expr table).
    source: NodeId,
    adapters: []const IteratorAdapter,
    /// Terminal operation. The default preserves deferred iterator fixtures.
    terminal: IteratorTerminal = .iterator,
};

pub const IteratorAdapter = union(enum) {
    map: MapAdapter,
    filter: FilterAdapter,
    /// Apply a closure and flatten each returned iterator.
    flat_map: ClosureExpr,
    enumerate: void, // → for (xs, 0..)
    zip: ZipAdapter,
    range_rev: void, // .rev() on a range
    other: Unsupported,
};

pub const MapAdapter = struct {
    closure: ClosureExpr,
};

pub const FilterAdapter = struct {
    closure: ClosureExpr,
};

pub const ZipAdapter = struct {
    /// The "other" expression index (expr table) to zip with source.
    other: NodeId,
};

// Explicit refusal — never silent omission.
pub const Unsupported = struct {
    reason: []const u8,
    suggested_version: enum { v1, v2, v3 },
};

// ── §2 Pattern node set ─────────────────────────────────────────────────────

/// Post-desugar: every binding carries an explicit BindMode (decided by
/// `match_ergonomics`); no implicit `ref` patterns remain.
pub const Pattern = struct {
    id: NodeId,
    span: spine.Span,
    ty: ?TypeId,
    kind: PatternKind,
};

pub const PatternKind = union(enum) {
    wildcard: void, // `_`
    binding: Binding,
    literal: Literal, // `1`, `'a'`
    path: PathPat, // unit enum variant / const pattern
    external_variant: ExternalVariantPattern,
    tuple: TuplePat, // (a, b, ..)
    slice: SlicePat, // [a, b, ..rest, c]
    struct_pat: StructPat, // Point { x, y, .. }
    reference: ReferencePat, // &pat / &mut pat (rare post-desugar)
    @"or": OrPat, // `a | b`
    range: RangePat, // `1..=5`, `'a'..='z'`
    unsupported: Unsupported,
    // guard is a MatchArm field, NOT a Pattern.
};

pub const Binding = struct {
    name: []const u8,
    mode: BindMode, // decided by match_ergonomics
    mutable: bool, // `mut x`
};

/// Lowering hooks: value mode → `switch` capture `|x|`; mut_ref mode → `|*x|`
/// pointer capture (idiom §9).
pub const BindMode = union(enum) {
    value: void, // capture by value
    shared_ref: void, // ref binding → Zig capture `|x|` (const)
    mut_ref: void, // &mut → Zig `|*x|`
};

pub const PathPat = struct {
    def: DefId,
    variant: ?[]const u8,
};

pub const TuplePat = struct {
    /// Element pattern indices (pattern table).
    elements: []const NodeId,
    rest: bool,
};

pub const SlicePat = struct {
    /// Element pattern indices (pattern table).
    elements: []const NodeId,
    /// Rest pattern index (pattern table); null = no rest.
    rest: ?NodeId,
};

pub const StructPat = struct {
    def: DefId,
    fields: []const FieldPat, // name : pat  |  shorthand name
    rest: bool, // `..`
    // #[non_exhaustive] handled at the arm/switch level.
};

/// A pattern for a variant whose enum owner has no local graph entity.
pub const ExternalVariantPattern = struct {
    owner: types.ExternalNominal,
    variant: []const u8,
    fields: []const FieldPat = &.{},
    rest: bool = false,
};

pub const FieldPat = struct {
    field: []const u8,
    /// Pattern index (pattern table); null = shorthand (same name & type).
    pat: ?NodeId,
    shorthand: bool,
};

pub const ReferencePat = struct {
    mode: BindMode,
    /// Inner pattern index (pattern table).
    inner: NodeId,
};

pub const OrPat = struct {
    /// Alternative pattern indices (pattern table).
    alternatives: []const NodeId,
};

pub const RangePat = struct {
    /// Lower bound expression index (expr table); null = unbounded.
    lo: ?NodeId,
    /// Upper bound expression index (expr table); null = unbounded.
    hi: ?NodeId,
    inclusive: bool,
};

// ── §3 Statement set ────────────────────────────────────────────────────────

pub const Statement = struct {
    id: NodeId,
    span: spine.Span,
    ty: ?TypeId,
    kind: StatementKind,
};

pub const StatementKind = union(enum) {
    let: LetStmt, // let [mut] pat [: ty] = init?;
    let_else: LetElseStmt, // let Some(v) = opt else { ... };
    /// Expression statement (incl. `;`-terminated).  Expr table index.
    expr: NodeId,
    item: ItemRef, // nested item — see items-types.md
};

pub const LetStmt = struct {
    /// Irrefutable binding pattern index (pattern table); refutable ⇒ must
    /// lower to if-let.
    pattern: NodeId,
    /// Initialiser expression index (expr table); null = uninitialised.
    init: ?NodeId,
    ty: ?TypeRef, // explicit annotation, if present (C-repr helper)
};

pub const LetElseStmt = struct {
    /// Refutable pattern index (pattern table).
    pattern: NodeId,
    /// Initialiser expression index (expr table); Option<T> → `orelse return`.
    init: NodeId,
    else_block: BlockExpr,
};

/// A typed reference into one of the three flat node tables.
pub const ReachableNode = union(enum) {
    expression: NodeId,
    statement: NodeId,
    pattern: NodeId,
};

pub const NodeWalkError = error{
    InvalidExprRef,
    InvalidStatementRef,
    InvalidPatternRef,
    InvalidTypeRef,
    InvalidTypeTraversal,
};

/// Iterates all nodes reachable from one expression root.
///
/// Nodes are marked when queued, so shared subgraphs and cycles visit each
/// table row at most once. The fixed-capacity worklist cannot exceed the total
/// number of rows in the three node tables.
pub const NodeWalker = struct {
    allocator: std.mem.Allocator,
    expressions: []const Expr,
    statements: []const Statement,
    patterns: []const Pattern,
    type_table: []const types.Type,
    seen: []bool,
    worklist: []ReachableNode,
    worklist_len: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        expressions: []const Expr,
        statements: []const Statement,
        patterns: []const Pattern,
        type_table: []const types.Type,
    ) std.mem.Allocator.Error!NodeWalker {
        std.debug.assert(expressions.len <= std.math.maxInt(usize) - statements.len);
        const expression_statement_count = expressions.len + statements.len;
        std.debug.assert(expression_statement_count <= std.math.maxInt(usize) - patterns.len);
        const node_count = expression_statement_count + patterns.len;

        const seen = try allocator.alloc(bool, node_count);
        errdefer allocator.free(seen);
        const worklist = try allocator.alloc(ReachableNode, node_count);
        @memset(seen, false);
        return .{
            .allocator = allocator,
            .expressions = expressions,
            .statements = statements,
            .patterns = patterns,
            .type_table = type_table,
            .seen = seen,
            .worklist = worklist,
        };
    }

    pub fn deinit(self: *NodeWalker) void {
        self.allocator.free(self.seen);
        self.allocator.free(self.worklist);
        self.* = undefined;
    }

    pub fn reset(self: *NodeWalker, root: NodeId) NodeWalkError!void {
        @memset(self.seen, false);
        self.worklist_len = 0;
        try self.enqueueExpression(root);
    }

    pub fn next(self: *NodeWalker) NodeWalkError!?ReachableNode {
        if (self.worklist_len == 0) return null;
        self.worklist_len -= 1;
        const node = self.worklist[self.worklist_len];
        try self.enqueueChildren(node);
        return node;
    }

    fn enqueue(self: *NodeWalker, node: ReachableNode, seen_index: usize) void {
        if (self.seen[seen_index]) return;
        std.debug.assert(self.worklist_len < self.worklist.len);
        self.seen[seen_index] = true;
        self.worklist[self.worklist_len] = node;
        self.worklist_len += 1;
    }

    fn enqueueExpression(self: *NodeWalker, id: NodeId) NodeWalkError!void {
        if (@as(usize, id) >= self.expressions.len) return error.InvalidExprRef;
        self.enqueue(.{ .expression = id }, @as(usize, id));
    }

    fn enqueueStatement(self: *NodeWalker, id: NodeId) NodeWalkError!void {
        if (@as(usize, id) >= self.statements.len) return error.InvalidStatementRef;
        self.enqueue(
            .{ .statement = id },
            self.expressions.len + @as(usize, id),
        );
    }

    fn enqueuePattern(self: *NodeWalker, id: NodeId) NodeWalkError!void {
        if (@as(usize, id) >= self.patterns.len) return error.InvalidPatternRef;
        self.enqueue(
            .{ .pattern = id },
            self.expressions.len + self.statements.len + @as(usize, id),
        );
    }

    // Assertion markers carry a real condition expression in their reason.
    fn enqueueUnsupported(self: *NodeWalker, unsupported: Unsupported) NodeWalkError!void {
        const prefix = "assertion:";
        if (!std.mem.startsWith(u8, unsupported.reason, prefix)) return;
        const suffix = unsupported.reason[prefix.len..];
        const condition = std.fmt.parseUnsigned(NodeId, suffix, 10) catch return;
        try self.enqueueExpression(condition);
    }

    fn enqueueTypeRef(self: *NodeWalker, id: TypeRef) NodeWalkError!void {
        if (@as(usize, id) >= self.type_table.len) return error.InvalidTypeRef;
        try self.enqueueType(self.type_table[id], 0);
    }

    fn enqueueExternalNominal(
        self: *NodeWalker,
        external: types.ExternalNominal,
        depth: usize,
    ) NodeWalkError!void {
        for (external.args) |argument| try self.enqueueType(argument, depth);
    }

    fn enqueueBound(
        self: *NodeWalker,
        bound: types.Bound,
        depth: usize,
    ) NodeWalkError!void {
        for (bound.args) |argument| try self.enqueueType(argument, depth);
        for (bound.associated_types) |binding| try self.enqueueType(binding.ty, depth);
    }

    fn enqueueType(
        self: *NodeWalker,
        ty: types.Type,
        depth: usize,
    ) NodeWalkError!void {
        if (depth >= types.traversal_depth_max) return error.InvalidTypeTraversal;
        const child_depth = depth + 1;
        switch (ty) {
            .path, .prim, .unsupported => {},
            .external_nominal => |external| {
                try self.enqueueExternalNominal(external, child_depth);
            },
            .reference => |reference| {
                try self.enqueueType(reference.pointee, child_depth);
            },
            .raw_ptr => |raw_ptr| try self.enqueueType(raw_ptr.pointee, child_depth),
            .slice => |slice| try self.enqueueType(slice.elem, child_depth),
            .array => |array| {
                try self.enqueueType(array.elem, child_depth);
                switch (array.len) {
                    .literal, .generic => {},
                    .expression => |expression| try self.enqueueExpression(expression),
                }
            },
            .tuple => |tuple| {
                for (tuple) |element| try self.enqueueType(element, child_depth);
            },
            .fn_ptr => |fn_ptr| {
                for (fn_ptr.params) |parameter| {
                    try self.enqueueType(parameter, child_depth);
                }
                try self.enqueueType(fn_ptr.ret, child_depth);
            },
            .generic_inst => |generic_inst| {
                for (generic_inst.args.params) |parameter| {
                    try self.enqueueType(parameter, child_depth);
                }
            },
            .option => |option| try self.enqueueType(option.*, child_depth),
            .result => |result| {
                try self.enqueueType(result.ok, child_depth);
                try self.enqueueType(result.err, child_depth);
            },
            .boxed => |boxed| try self.enqueueType(boxed.*, child_depth),
            .@"opaque" => |opaque_ty| {
                for (opaque_ty.bounds) |bound| {
                    try self.enqueueBound(bound, child_depth);
                }
                if (opaque_ty.concrete) |concrete| {
                    try self.enqueueType(concrete.*, child_depth);
                }
            },
            .dyn_trait => |bounds| {
                for (bounds) |bound| try self.enqueueBound(bound, child_depth);
            },
        }
    }

    fn enqueueBlock(self: *NodeWalker, block: BlockExpr) NodeWalkError!void {
        for (block.statements) |statement| try self.enqueueStatement(statement);
        if (block.tail) |tail| try self.enqueueExpression(tail);
    }

    fn enqueueElse(self: *NodeWalker, branch: ElseBranch) NodeWalkError!void {
        switch (branch) {
            .none => {},
            .block => |block| try self.enqueueBlock(block),
            .chain => |chain| try self.enqueueExpression(chain),
        }
    }

    fn enqueueClosure(self: *NodeWalker, closure: ClosureExpr) NodeWalkError!void {
        for (closure.captures) |capture| try self.enqueueTypeRef(capture.ty);
        for (closure.params) |parameter| try self.enqueuePattern(parameter);
        if (closure.return_ty) |return_ty| try self.enqueueTypeRef(return_ty);
        try self.enqueueBlock(closure.body);
    }

    fn enqueueIteratorAdapter(
        self: *NodeWalker,
        adapter: IteratorAdapter,
    ) NodeWalkError!void {
        switch (adapter) {
            .map => |map| try self.enqueueClosure(map.closure),
            .filter => |filter| try self.enqueueClosure(filter.closure),
            .flat_map => |closure| try self.enqueueClosure(closure),
            .enumerate, .range_rev, .other => {},
            .zip => |zip| try self.enqueueExpression(zip.other),
        }
    }

    fn enqueueIteratorChain(
        self: *NodeWalker,
        chain: IteratorChainExpr,
    ) NodeWalkError!void {
        try self.enqueueExpression(chain.source);
        switch (chain.terminal) {
            .iterator, .collect_vec, .sum => {},
        }
        for (chain.adapters) |adapter| try self.enqueueIteratorAdapter(adapter);
    }

    fn enqueueIterKind(self: *NodeWalker, kind: IterKind) NodeWalkError!void {
        switch (kind) {
            .range, .slice, .enumerate => {},
            .multi => |expressions| {
                for (expressions) |expression| try self.enqueueExpression(expression);
            },
            .adapter => |chain| try self.enqueueIteratorChain(chain),
        }
    }

    fn enqueueExpressionChildren(
        self: *NodeWalker,
        expression: Expr,
    ) NodeWalkError!void {
        if (expression.ty) |type_id| try self.enqueueTypeRef(type_id);
        switch (expression.kind) {
            .literal, .unit, .panic_, .continue_ => {},
            .path => |path| {
                for (path.generic_args) |argument| try self.enqueueType(argument, 0);
            },
            .array => |array| {
                for (array.elements) |element| try self.enqueueExpression(element);
            },
            .vec_lit => |vector| {
                for (vector.elements) |element| try self.enqueueExpression(element);
                // A count the target evaluates is a real child node: whatever
                // it touches is the literal's own reach, so it is walked and
                // bound-checked like any other element.
                if (vector.repeat) |count| switch (count) {
                    .literal => {},
                    .expression => |id| try self.enqueueExpression(id),
                };
            },
            .range => |range| {
                try self.enqueueExpression(range.start);
                if (range.end) |end| try self.enqueueExpression(end);
            },
            .block => |block| try self.enqueueBlock(block),
            .if_else => |if_else| {
                try self.enqueueExpression(if_else.cond);
                try self.enqueueBlock(if_else.then_);
                try self.enqueueElse(if_else.@"else");
            },
            .if_let => |if_let| {
                try self.enqueuePattern(if_let.pattern);
                try self.enqueueExpression(if_let.scrutinee);
                try self.enqueueBlock(if_let.then_);
                try self.enqueueElse(if_let.@"else");
            },
            .match => |match| {
                try self.enqueueExpression(match.scrutinee);
                for (match.arms) |arm| {
                    for (arm.patterns) |pattern| try self.enqueuePattern(pattern);
                    if (arm.guard) |guard| try self.enqueueExpression(guard);
                    try self.enqueueExpression(arm.body);
                }
            },
            .loop_ => |loop| try self.enqueueBlock(loop.body),
            .while_ => |while_| {
                try self.enqueueExpression(while_.cond);
                if (while_.capture) |capture| try self.enqueuePattern(capture);
                try self.enqueueBlock(while_.body);
            },
            .for_ => |for_| {
                try self.enqueuePattern(for_.pattern);
                try self.enqueueExpression(for_.iterable);
                try self.enqueueBlock(for_.body);
                try self.enqueueIterKind(for_.iter_kind);
            },
            .break_ => |break_| {
                if (break_.value) |value| try self.enqueueExpression(value);
            },
            .call => |call| {
                for (call.args) |argument| try self.enqueueExpression(argument);
            },
            .core_call => |call| {
                for (call.generic_args) |argument| try self.enqueueType(argument, 0);
                for (call.args) |argument| try self.enqueueExpression(argument);
            },
            .core_function => |function| {
                for (function.generic_args) |argument| try self.enqueueType(argument, 0);
            },
            .method_call => |method| {
                try self.enqueueExpression(method.receiver);
                for (method.generic_args) |argument| try self.enqueueType(argument, 0);
                for (method.args) |argument| try self.enqueueExpression(argument);
            },
            .struct_lit => |literal| {
                for (literal.fields) |field| try self.enqueueExpression(field.value);
                if (literal.base) |base| try self.enqueueExpression(base);
            },
            .enum_variant => |variant| {
                for (variant.tuple_fields) |field| try self.enqueueExpression(field);
                for (variant.named_fields) |field| try self.enqueueExpression(field.value);
            },
            .external_variant => |variant| {
                try self.enqueueExternalNominal(variant.owner, 0);
                for (variant.tuple_fields) |field| try self.enqueueExpression(field);
                for (variant.named_fields) |field| try self.enqueueExpression(field.value);
            },
            .format_write => |format_write| {
                try self.enqueueExpression(format_write.writer);
                for (format_write.args) |argument| try self.enqueueExpression(argument);
            },
            .field => |field| try self.enqueueExpression(field.base),
            .index => |index| {
                try self.enqueueExpression(index.base);
                try self.enqueueExpression(index.index);
            },
            .cast => |cast| {
                try self.enqueueExpression(cast.operand);
                try self.enqueueType(cast.source_type, 0);
                try self.enqueueTypeRef(cast.target);
            },
            .binary => |binary| {
                try self.enqueueExpression(binary.lhs);
                try self.enqueueExpression(binary.rhs);
            },
            .unary => |unary| try self.enqueueExpression(unary.operand),
            .assign => |assign| {
                try self.enqueueExpression(assign.target);
                try self.enqueueExpression(assign.value);
            },
            .try_ => |try_| try self.enqueueExpression(try_.inner),
            .return_ => |return_| {
                if (return_.value) |value| try self.enqueueExpression(value);
            },
            .closure => |closure| try self.enqueueClosure(closure),
            .iterator_chain => |chain| try self.enqueueIteratorChain(chain),
            .unsupported => |unsupported| try self.enqueueUnsupported(unsupported),
        }
    }

    fn enqueueStatementChildren(
        self: *NodeWalker,
        statement: Statement,
    ) NodeWalkError!void {
        if (statement.ty) |type_id| try self.enqueueTypeRef(type_id);
        switch (statement.kind) {
            .let => |let| {
                try self.enqueuePattern(let.pattern);
                if (let.init) |initializer| try self.enqueueExpression(initializer);
                if (let.ty) |type_id| try self.enqueueTypeRef(type_id);
            },
            .let_else => |let_else| {
                try self.enqueuePattern(let_else.pattern);
                try self.enqueueExpression(let_else.init);
                try self.enqueueBlock(let_else.else_block);
            },
            .expr => |expression| try self.enqueueExpression(expression),
            .item => {},
        }
    }

    fn enqueuePatternChildren(
        self: *NodeWalker,
        pattern: Pattern,
    ) NodeWalkError!void {
        if (pattern.ty) |type_id| try self.enqueueTypeRef(type_id);
        switch (pattern.kind) {
            .wildcard, .binding, .literal, .path, .unsupported => {},
            .tuple => |tuple| {
                for (tuple.elements) |element| try self.enqueuePattern(element);
            },
            .slice => |slice| {
                for (slice.elements) |element| try self.enqueuePattern(element);
                if (slice.rest) |rest| try self.enqueuePattern(rest);
            },
            .struct_pat => |struct_pattern| {
                for (struct_pattern.fields) |field| {
                    if (field.pat) |field_pattern| try self.enqueuePattern(field_pattern);
                }
            },
            .external_variant => |variant| {
                try self.enqueueExternalNominal(variant.owner, 0);
                for (variant.fields) |field| {
                    if (field.pat) |field_pattern| try self.enqueuePattern(field_pattern);
                }
            },
            .reference => |reference| try self.enqueuePattern(reference.inner),
            .@"or" => |or_pattern| {
                for (or_pattern.alternatives) |alternative| {
                    try self.enqueuePattern(alternative);
                }
            },
            .range => |range| {
                if (range.lo) |lo| try self.enqueueExpression(lo);
                if (range.hi) |hi| try self.enqueueExpression(hi);
            },
        }
    }

    fn enqueueChildren(self: *NodeWalker, node: ReachableNode) NodeWalkError!void {
        switch (node) {
            .expression => |id| try self.enqueueExpressionChildren(self.expressions[id]),
            .statement => |id| try self.enqueueStatementChildren(self.statements[id]),
            .pattern => |id| try self.enqueuePatternChildren(self.patterns[id]),
        }
    }
};
// =============================================================================
// Walker audit — every child a node can carry is reachable from its parent.
//
// The `enqueue*Children` switches exhaust every union tag (a new tag is a
// compile error, not a missed child), so what the audit must pin is the
// *fields*: a payload whose node or type edge the walker forgets. Each
// fixture below carries exactly one such edge, and the walker must surface
// it. New edges — a new `types.Type` carried by `CoreCall`, say — join this
// family with their own probe, never by extending an existing arm's reach.
// =============================================================================

/// A flat-tables builder for walker fixtures. Every row it appends is dense:
/// the id handed back is that row's index in its own table, exactly as a
/// deserialised wire body would carry it.
const WalkFixture = struct {
    alloc: std.mem.Allocator,
    exprs: std.ArrayListUnmanaged(Expr) = .empty,
    stmts: std.ArrayListUnmanaged(Statement) = .empty,
    pats: std.ArrayListUnmanaged(Pattern) = .empty,
    types: std.ArrayListUnmanaged(types.Type) = .empty,
    span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },

    fn deinit(self: *WalkFixture) void {
        self.exprs.deinit(self.alloc);
        self.stmts.deinit(self.alloc);
        self.pats.deinit(self.alloc);
        self.types.deinit(self.alloc);
        self.* = undefined;
    }

    fn expr(self: *WalkFixture, kind: ExprKind) !NodeId {
        const id: NodeId = @intCast(self.exprs.items.len);
        try self.exprs.append(
            self.alloc,
            .{ .id = id, .span = self.span, .ty = null, .kind = kind },
        );
        return id;
    }

    fn stmt(self: *WalkFixture, kind: StatementKind) !NodeId {
        const id: NodeId = @intCast(self.stmts.items.len);
        try self.stmts.append(
            self.alloc,
            .{ .id = id, .span = self.span, .ty = null, .kind = kind },
        );
        return id;
    }

    fn pat(self: *WalkFixture, kind: PatternKind) !NodeId {
        const id: NodeId = @intCast(self.pats.items.len);
        try self.pats.append(
            self.alloc,
            .{ .id = id, .span = self.span, .ty = null, .kind = kind },
        );
        return id;
    }

    fn ty(self: *WalkFixture, ty_value: types.Type) !TypeId {
        const id: TypeId = @intCast(self.types.items.len);
        try self.types.append(self.alloc, ty_value);
        return id;
    }

    fn walker(self: *const WalkFixture) !NodeWalker {
        return NodeWalker.init(
            self.alloc,
            self.exprs.items,
            self.stmts.items,
            self.pats.items,
            self.types.items,
        );
    }
};

/// The `NodeId`s a walk from `root` visits.
fn reachableExprIds(
    walk: *NodeWalker,
    root: NodeId,
    out: []bool,
) !void {
    try walk.reset(root);
    while (try walk.next()) |node| {
        if (node == .expression) out[@as(usize, node.expression)] = true;
    }
}

// =============================================================================
// Tests — reachability proofs first, then the compile smoke below. The
// walker proofs build their fixtures with the testing allocator and release
// everything they append; the smoke tests keep the original static-slice
// pattern (mirrors items.zig).
//
// Pattern: standalone exercises (enums, payloads) use `_ =` to suppress
// unused warnings.  Composed values (Expr, Pattern, Statement) are consumed
// by the final `_ =` block — no intermediate discards.
// =============================================================================

test "exprs — every ExprKind / Literal / Operator variant compiles" {
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    // ── §1.1 every Literal variant ─────────────────────────────────────────
    const lit_int: Literal = .{ .int = .{ .text = "42", .value = 42, .base = .dec, .ty_suffix = null } };
    const lit_hex: Literal = .{ .int = .{ .text = "0xFF", .value = 0xFF, .base = .hex, .ty_suffix = "u8" } };
    const lit_float: Literal = .{ .float = .{ .text = "3.14", .value = 3.14 } };
    const lit_char: Literal = .{ .character = .{ .text = "'x'", .value = 'x' } };
    const lit_str: Literal = .{ .string = .{ .bytes = "abc" } };
    const lit_bool: Literal = .{ .boolean = true };
    _ = lit_hex;
    _ = lit_float;
    _ = lit_char;
    _ = lit_str;
    _ = lit_bool;

    const vec_lit: VecLit = .{ .elements = &.{ 1, 2 }, .repeat = null };
    const vec_lit_repeated: VecLit = .{ .elements = &.{3}, .repeat = .{ .literal = 4 } };
    const vec_lit_counted: VecLit = .{ .elements = &.{3}, .repeat = .{ .expression = 5 } };
    _ = vec_lit_repeated;
    _ = vec_lit_counted;
    const array_expr: ArrayExpr = .{ .elements = &.{ 3, 4 }, .repeat = null };
    const range_expr: RangeExpr = .{ .start = 5, .end = 6, .inclusive = false };

    // §1.1 — Path, Block (BlockExpr is non-recursive via NodeIds)
    const path_expr: PathExpr = .{ .def = 1, .generic_args = &.{} };
    const block_expr: BlockExpr = .{ .statements = &.{}, .tail = null, .labelled = null };
    const block_with_stmt: BlockExpr = .{ .statements = &.{ 10, 20 }, .tail = 42, .labelled = "blk" };
    _ = block_with_stmt;

    // §1.2 — IfExpr / ElseBranch (all three variants)
    const else_blk: BlockExpr = .{ .statements = &.{}, .tail = null, .labelled = null };
    const if_full: IfExpr = .{ .cond = 5, .then_ = block_expr, .@"else" = .{ .block = else_blk } };
    const if_no_else: IfExpr = .{ .cond = 6, .then_ = block_expr, .@"else" = .{ .none = {} } };
    const else_chain: ElseBranch = .{ .chain = 7 };
    _ = if_no_else;
    _ = else_chain;

    // §1.2 — IfLetExpr
    const if_let_expr: IfLetExpr = .{
        .pattern = 8,
        .scrutinee = 9,
        .then_ = block_expr,
        .@"else" = .{ .none = {} },
    };

    // §1.2 — MatchExpr + MatchArm
    const match_arm: MatchArm = .{ .patterns = &.{ 1, 2 }, .guard = null, .body = 3 };
    const match_with_guard: MatchArm = .{ .patterns = &.{4}, .guard = 5, .body = 6 };
    const match_expr: MatchExpr = .{ .scrutinee = 10, .arms = &.{ match_arm, match_with_guard } };

    // §1.2 — Loop, While, For, Break, Continue
    const loop_expr: LoopExpr = .{ .body = block_expr };
    const while_expr: WhileExpr = .{ .cond = 11, .body = block_expr };
    const for_range: ForExpr = .{
        .pattern = 12,
        .iterable = 13,
        .body = block_expr,
        .iter_kind = .{ .range = {} },
    };
    const for_slice: ForExpr = .{
        .pattern = 14,
        .iterable = 15,
        .body = block_expr,
        .iter_kind = .{ .slice = {} },
    };
    const for_multi: ForExpr = .{
        .pattern = 16,
        .iterable = 17,
        .body = block_expr,
        .iter_kind = .{ .multi = &.{ 18, 19 } },
    };
    const for_enum: ForExpr = .{
        .pattern = 20,
        .iterable = 21,
        .body = block_expr,
        .iter_kind = .{ .enumerate = {} },
    };
    const break_val: BreakExpr = .{ .label = "outer", .value = 22 };
    const break_no_val: BreakExpr = .{ .label = null, .value = null };
    const continue_expr: ContinueExpr = .{ .label = "outer" };
    _ = for_slice;
    _ = for_multi;
    _ = for_enum;
    _ = break_no_val;

    // §1.3 — Call / CoreCall / CallKind.
    const core_functions = [_]CoreFunction{
        .mem_size_of,
        .mem_transmute,
        .mem_size_of_val,
        .ptr_copy_nonoverlapping,
        .ptr_write_bytes,
        .ptr_read_unaligned,
        .slice_from_raw_parts,
        .slice_from_raw_parts_mut,
        .str_from_utf8,
        .str_from_utf8_unchecked,
        .string_from_utf8,
        .string_from_utf8_lossy,
        .string_from_utf8_unchecked,
        .cmp_min,
        .cmp_max,
        .default_value,
        .convert_from,
        .prim_from_le_bytes,
        .prim_to_le_bytes,
        .maybe_uninit_uninit,
        .rng_fill_bytes_via_next,
        .hash_write_primitive,
        .numeric_min_value,
        .numeric_max_value,
        .numeric_zero,
        .numeric_one,
    };
    const core_call: CoreCall = .{
        .function = .mem_size_of,
        .generic_args = &.{.{ .prim = .u8 }},
        .args = &.{},
    };
    const core_function: CoreFunctionValue = .{
        .function = .mem_transmute,
        .generic_args = &.{ .{ .prim = .u8 }, .{ .prim = .u64 } },
    };
    _ = core_functions;

    // §1.3 — Call / CallKind (all three)
    const call_free: Call = .{ .call_kind = .{ .free = 30 }, .args = &.{ 1, 2 } };
    const call_assoc: Call = .{ .call_kind = .{ .associated = 31 }, .args = &.{} };
    const call_ctor: Call = .{ .call_kind = .{ .constructor = 32 }, .args = &.{3} };
    _ = call_assoc;
    _ = call_ctor;

    // §1.3 — MethodCall + ReceiverMode (all three)
    const mc_value: MethodCall = .{ .receiver = 33, .receiver_mode = .value, .method = 34, .args = &.{} };
    const mc_shared: MethodCall = .{ .receiver = 35, .receiver_mode = .shared, .method = 36, .args = &.{1} };
    const mc_mut: MethodCall = .{ .receiver = 37, .receiver_mode = .mutable, .method = 38, .args = &.{ 2, 3 } };
    _ = mc_shared;
    _ = mc_mut;

    // §1.3 — StructLit, FieldInit, EnumVariant
    const fi_a: FieldInit = .{ .field = "x", .value = 39, .shorthand = true };
    const fi_b: FieldInit = .{ .field = "y", .value = 40, .shorthand = false };
    const struct_lit: StructLit = .{ .def = 41, .fields = &.{ fi_a, fi_b }, .base = null };
    const struct_with_base: StructLit = .{ .def = 42, .fields = &.{fi_a}, .base = 43 };
    const enum_variant: EnumVariant = .{
        .def = 44,
        .variant = "Circle",
        .tuple_fields = &.{45},
        .named_fields = &.{fi_a},
    };
    const external_variant: ExternalVariant = .{
        .owner = .{
            .path = &.{ "alloc", "borrow", "Cow" },
            .args = &.{.{ .prim = .u8 }},
        },
        .variant = "Owned",
        .tuple_fields = &.{45},
        .named_fields = &.{fi_a},
    };
    _ = struct_with_base;

    // §1.4 — FieldExpr, IndexExpr
    const field_expr: FieldExpr = .{ .base = 46, .field = "x", .resolved = 47 };
    const index_expr: IndexExpr = .{ .base = 48, .index = 49 };

    // §1.5 — Overflow (all three)
    const ov_checked: Overflow = .checked;
    const ov_wrap: Overflow = .wrapping;
    const ov_sat: Overflow = .saturating;
    _ = ov_checked;
    _ = ov_wrap;
    _ = ov_sat;

    // §1.5 — BinaryOp (all 18 variants — standalone exercises)
    const bin_add: BinaryOp = .add;
    const bin_sub: BinaryOp = .sub;
    const bin_mul: BinaryOp = .mul;
    const bin_div: BinaryOp = .div;
    const bin_rem: BinaryOp = .rem;
    const bin_band: BinaryOp = .bit_and;
    const bin_bor: BinaryOp = .bit_or;
    const bin_bxor: BinaryOp = .bit_xor;
    const bin_shl: BinaryOp = .shl;
    const bin_shr: BinaryOp = .shr;
    const bin_eq: BinaryOp = .eq;
    const bin_ne: BinaryOp = .ne;
    const bin_lt: BinaryOp = .lt;
    const bin_le: BinaryOp = .le;
    const bin_gt: BinaryOp = .gt;
    const bin_ge: BinaryOp = .ge;
    const bin_land: BinaryOp = .boolean_and;
    const bin_lor: BinaryOp = .boolean_or;
    _ = bin_add;
    _ = bin_sub;
    _ = bin_mul;
    _ = bin_div;
    _ = bin_rem;
    _ = bin_band;
    _ = bin_bor;
    _ = bin_bxor;
    _ = bin_shl;
    _ = bin_shr;
    _ = bin_eq;
    _ = bin_ne;
    _ = bin_lt;
    _ = bin_le;
    _ = bin_gt;
    _ = bin_ge;
    _ = bin_land;
    _ = bin_lor;

    // §1.5 — BinaryExpr (consumed by e_binary below)
    const bin_expr: BinaryExpr = .{ .op = .add, .overflow = .checked, .lhs = 50, .rhs = 51 };

    // §1.5 — UnaryOp (5 variants incl. @"ref" payload)
    const u_neg: UnaryOp = .negate;
    const u_lnot: UnaryOp = .logical_not;
    const u_bnot: UnaryOp = .bit_not;
    const u_deref: UnaryOp = .deref;
    const u_ref: UnaryOp = .{ .ref = .shared };
    _ = u_neg;
    _ = u_lnot;
    _ = u_bnot;
    _ = u_deref;
    _ = u_ref;

    const unary_expr: UnaryExpr = .{ .op = .negate, .operand = 52 };

    // §1.5 — AssignOp (all 11 variants — standalone exercises)
    const a_plain: AssignOp = .plain;
    const a_add: AssignOp = .add;
    const a_sub: AssignOp = .sub;
    const a_mul: AssignOp = .mul;
    const a_div: AssignOp = .div;
    const a_rem: AssignOp = .rem;
    const a_band: AssignOp = .bit_and;
    const a_bor: AssignOp = .bit_or;
    const a_bxor: AssignOp = .bit_xor;
    const a_shl: AssignOp = .shl;
    const a_shr: AssignOp = .shr;
    _ = a_plain;
    _ = a_add;
    _ = a_sub;
    _ = a_mul;
    _ = a_div;
    _ = a_rem;
    _ = a_band;
    _ = a_bor;
    _ = a_bxor;
    _ = a_shl;
    _ = a_shr;

    const assign_expr: AssignExpr = .{ .target = 53, .op = .plain, .value = 54, .overflow = .checked };

    // §1.5 — TryExpr, ReturnExpr
    const try_expr: TryExpr = .{ .inner = 55 };
    const ret_unit: ReturnExpr = .{ .value = null };
    const ret_val: ReturnExpr = .{ .value = 56 };
    _ = ret_unit;

    const e_core_call: Expr = .{
        .id = 32,
        .span = span,
        .ty = null,
        .kind = .{ .core_call = core_call },
    };
    const e_core_function: Expr = .{
        .id = 33,
        .span = span,
        .ty = null,
        .kind = .{ .core_function = core_function },
    };
    // Explicit divergence and refusal
    const panic_expr: PanicExpr = .{ .message = "unreachable" };
    const unsup: Unsupported = .{ .reason = "match guards", .suggested_version = .v2 };

    // ── Wrap every ExprKind arm into an Expr (final _ = block) ─────────────
    const e_lit: Expr = .{ .id = 1, .span = span, .ty = null, .kind = .{ .literal = lit_int } };
    const e_array: Expr = .{ .id = 26, .span = span, .ty = null, .kind = .{ .array = array_expr } };
    const e_vec: Expr = .{ .id = 24, .span = span, .ty = null, .kind = .{ .vec_lit = vec_lit } };
    const e_range: Expr = .{ .id = 27, .span = span, .ty = null, .kind = .{ .range = range_expr } };
    const e_path: Expr = .{ .id = 2, .span = span, .ty = null, .kind = .{ .path = path_expr } };
    const e_block: Expr = .{ .id = 3, .span = span, .ty = null, .kind = .{ .block = block_expr } };
    const e_unit: Expr = .{ .id = 4, .span = span, .ty = null, .kind = .{ .unit = {} } };
    const e_if: Expr = .{ .id = 5, .span = span, .ty = null, .kind = .{ .if_else = if_full } };
    const e_if_let: Expr = .{ .id = 6, .span = span, .ty = null, .kind = .{ .if_let = if_let_expr } };
    const e_match: Expr = .{ .id = 7, .span = span, .ty = null, .kind = .{ .match = match_expr } };
    const e_loop: Expr = .{ .id = 8, .span = span, .ty = null, .kind = .{ .loop_ = loop_expr } };
    const e_while: Expr = .{ .id = 9, .span = span, .ty = null, .kind = .{ .while_ = while_expr } };
    const e_for: Expr = .{ .id = 10, .span = span, .ty = null, .kind = .{ .for_ = for_range } };
    const e_break: Expr = .{ .id = 11, .span = span, .ty = null, .kind = .{ .break_ = break_val } };
    const e_cont: Expr = .{ .id = 12, .span = span, .ty = null, .kind = .{ .continue_ = continue_expr } };
    const e_call: Expr = .{ .id = 13, .span = span, .ty = null, .kind = .{ .call = call_free } };
    const e_mc: Expr = .{ .id = 14, .span = span, .ty = null, .kind = .{ .method_call = mc_value } };
    const e_struct: Expr = .{ .id = 15, .span = span, .ty = null, .kind = .{ .struct_lit = struct_lit } };
    const e_enum: Expr = .{ .id = 16, .span = span, .ty = null, .kind = .{ .enum_variant = enum_variant } };
    const e_external_enum: Expr = .{
        .id = 34,
        .span = span,
        .ty = null,
        .kind = .{ .external_variant = external_variant },
    };
    const e_field: Expr = .{ .id = 17, .span = span, .ty = null, .kind = .{ .field = field_expr } };
    const e_index: Expr = .{ .id = 18, .span = span, .ty = null, .kind = .{ .index = index_expr } };
    const e_bin: Expr = .{ .id = 19, .span = span, .ty = null, .kind = .{ .binary = bin_expr } };
    const e_unary: Expr = .{ .id = 20, .span = span, .ty = null, .kind = .{ .unary = unary_expr } };
    const e_assign: Expr = .{ .id = 21, .span = span, .ty = null, .kind = .{ .assign = assign_expr } };
    const e_try: Expr = .{ .id = 22, .span = span, .ty = null, .kind = .{ .try_ = try_expr } };
    _ = e_core_call;
    _ = e_core_function;
    const e_ret: Expr = .{ .id = 23, .span = span, .ty = null, .kind = .{ .return_ = ret_val } };
    const e_panic: Expr = .{ .id = 24, .span = span, .ty = null, .kind = .{ .panic_ = panic_expr } };
    const e_unsup: Expr = .{ .id = 25, .span = span, .ty = null, .kind = .{ .unsupported = unsup } };
    _ = e_lit;
    _ = e_array;
    _ = e_range;
    _ = e_vec;
    _ = e_path;
    _ = e_block;
    _ = e_unit;
    _ = e_if;
    _ = e_if_let;
    _ = e_match;
    _ = e_loop;
    _ = e_while;
    _ = e_for;
    _ = e_break;
    _ = e_cont;
    _ = e_call;
    _ = e_mc;
    _ = e_struct;
    _ = e_enum;
    _ = e_external_enum;
    _ = e_field;
    _ = e_index;
    _ = e_bin;
    _ = e_unary;
    _ = e_assign;
    _ = e_try;
    _ = e_panic;
    _ = e_ret;
    _ = e_unsup;
    // closure / iterator_chain exercised in deferred test.
}

test "exprs — every PatternKind / StatementKind variant compiles" {
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    // §2 — Binding + BindMode (all three modes — consumed by patterns below)
    const bind_val: Binding = .{ .name = "x", .mode = .{ .value = {} }, .mutable = false };
    const bind_ref: Binding = .{ .name = "y", .mode = .{ .shared_ref = {} }, .mutable = false };
    const bind_mut: Binding = .{ .name = "z", .mode = .{ .mut_ref = {} }, .mutable = true };
    _ = bind_ref;
    _ = bind_mut;

    // §2 — every PatternKind arm (consumed by final _ = block)
    const pat_wild: Pattern = .{ .id = 1, .span = span, .ty = null, .kind = .{ .wildcard = {} } };
    const pat_bind: Pattern = .{ .id = 2, .span = span, .ty = null, .kind = .{ .binding = bind_val } };
    const pat_lit: Pattern = .{
        .id = 3,
        .span = span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{ .text = "1", .value = 1, .base = .dec, .ty_suffix = null } } },
    };
    const pat_path: Pattern = .{
        .id = 4,
        .span = span,
        .ty = null,
        .kind = .{ .path = .{ .def = 10, .variant = "A" } },
    };
    const pat_path_unit: Pattern = .{
        .id = 5,
        .span = span,
        .ty = null,
        .kind = .{ .path = .{ .def = 11, .variant = null } },
    };
    const pat_tuple: Pattern = .{
        .id = 6,
        .span = span,
        .ty = null,
        .kind = .{ .tuple = .{ .elements = &.{1}, .rest = false } },
    };
    const pat_tuple_rest: Pattern = .{
        .id = 7,
        .span = span,
        .ty = null,
        .kind = .{ .tuple = .{ .elements = &.{}, .rest = true } },
    };
    const pat_slice: Pattern = .{
        .id = 8,
        .span = span,
        .ty = null,
        .kind = .{ .slice = .{ .elements = &.{2}, .rest = null } },
    };
    const pat_slice_rest: Pattern = .{
        .id = 9,
        .span = span,
        .ty = null,
        .kind = .{ .slice = .{ .elements = &.{}, .rest = 3 } },
    };
    const pat_struct: Pattern = .{
        .id = 10,
        .span = span,
        .ty = null,
        .kind = .{
            .struct_pat = .{
                .def = 12,
                .fields = &.{.{ .field = "x", .pat = 4, .shorthand = true }},
                .rest = false,
            },
        },
    };
    const pat_ref: Pattern = .{
        .id = 11,
        .span = span,
        .ty = null,
        .kind = .{ .reference = .{ .mode = .{ .shared_ref = {} }, .inner = 1 } },
    };
    const pat_or: Pattern = .{
        .id = 12,
        .span = span,
        .ty = null,
        .kind = .{ .@"or" = .{ .alternatives = &.{ 1, 2 } } },
    };
    const pat_range: Pattern = .{
        .id = 13,
        .span = span,
        .ty = null,
        .kind = .{ .range = .{ .lo = 5, .hi = 6, .inclusive = true } },
    };
    const pat_range_open: Pattern = .{
        .id = 14,
        .span = span,
        .ty = null,
        .kind = .{ .range = .{ .lo = null, .hi = null, .inclusive = false } },
    };
    const pat_unsupported: Pattern = .{
        .id = 15,
        .span = span,
        .ty = null,
        .kind = .{ .unsupported = .{
            .reason = "slice pattern",
            .suggested_version = .v3,
        } },
    };
    _ = pat_wild;
    _ = pat_bind;
    _ = pat_lit;
    _ = pat_path;
    _ = pat_path_unit;
    _ = pat_tuple;
    _ = pat_tuple_rest;
    _ = pat_slice;
    _ = pat_slice_rest;
    _ = pat_struct;
    _ = pat_ref;
    _ = pat_or;
    _ = pat_range;
    _ = pat_range_open;
    _ = pat_unsupported;

    // §3 — every StatementKind arm
    const stmt_let: Statement = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .let = .{ .pattern = 1, .init = 2, .ty = null } },
    };
    const stmt_let_no_init: Statement = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{ .let = .{ .pattern = 3, .init = null, .ty = null } },
    };
    const stmt_let_else: Statement = .{
        .id = 3,
        .span = span,
        .ty = null,
        .kind = .{ .let_else = .{
            .pattern = 4,
            .init = 5,
            .else_block = .{ .statements = &.{}, .tail = null, .labelled = null },
        } },
    };
    const stmt_expr: Statement = .{
        .id = 4,
        .span = span,
        .ty = null,
        .kind = .{ .expr = 6 },
    };
    const stmt_item: Statement = .{
        .id = 5,
        .span = span,
        .ty = null,
        .kind = .{ .item = 99 },
    };
    _ = stmt_let;
    _ = stmt_let_no_init;
    _ = stmt_let_else;
    _ = stmt_expr;
    _ = stmt_item;
}

test "exprs — deferred seam (ClosureExpr / IteratorChainExpr / IteratorAdapter) compiles" {
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };
    const block: BlockExpr = .{ .statements = &.{}, .tail = null, .labelled = null };

    // ClosureTrait (all three)
    const ct_fn: ClosureTrait = .@"fn";
    const ct_mut: ClosureTrait = .fn_mut;
    const ct_once: ClosureTrait = .fn_once;
    _ = ct_fn;
    _ = ct_mut;
    _ = ct_once;

    // CaptureMode (all three)
    const cm_val: CaptureMode = .by_value;
    const cm_ref: CaptureMode = .by_ref;
    const cm_mut: CaptureMode = .by_mut_ref;
    _ = cm_val;
    _ = cm_ref;
    _ = cm_mut;

    // Capture (consumed by closure below)
    const capture: Capture = .{ .name = "a", .mode = .by_value, .ty = 1 };

    // ClosureExpr — base for adapters (consumed by adapters below)
    const closure: ClosureExpr = .{
        .captures = &.{capture},
        .params = &.{ 1, 2 },
        .return_ty = null,
        .body = block,
        .trait = .@"fn",
    };

    // MapAdapter / FilterAdapter / ZipAdapter (consumed by IteratorAdapter below)
    const map_ad: MapAdapter = .{ .closure = closure };
    const filter_ad: FilterAdapter = .{ .closure = closure };
    const zip_ad: ZipAdapter = .{ .other = 10 };
    const range: RangeExpr = .{ .start = 1, .end = 2, .inclusive = true };

    // Unsupported (consumed by IteratorAdapter.other below)
    const unsup: Unsupported = .{ .reason = "scan", .suggested_version = .v3 };

    // IteratorAdapter — all 7 variants
    const ia_map: IteratorAdapter = .{ .map = map_ad };
    const ia_filter: IteratorAdapter = .{ .filter = filter_ad };
    const ia_flat_map: IteratorAdapter = .{ .flat_map = closure };
    const ia_enum: IteratorAdapter = .{ .enumerate = {} };
    const ia_zip: IteratorAdapter = .{ .zip = zip_ad };
    const ia_rev: IteratorAdapter = .{ .range_rev = {} };
    const ia_other: IteratorAdapter = .{ .other = unsup };
    _ = ia_filter;
    _ = ia_enum;
    _ = ia_zip;
    _ = ia_rev;
    _ = ia_other;

    const terminal_iterator: IteratorTerminal = .iterator;
    const terminal_collect_vec: IteratorTerminal = .collect_vec;
    const terminal_sum: IteratorTerminal = .sum;
    _ = terminal_iterator;
    _ = terminal_collect_vec;
    _ = terminal_sum;

    // IteratorChainExpr (consumed by IterKind.adapter below)
    const chain: IteratorChainExpr = .{
        .source = 11,
        .adapters = &.{ ia_map, ia_flat_map },
        .terminal = .collect_vec,
    };

    // IterKind.adapter variant (the deferred escape)
    const ik_adapter: IterKind = .{ .adapter = chain };
    _ = ik_adapter;

    // Wrap range, closure & iterator_chain in their Expr arms
    const e_range: Expr = .{ .id = 29, .span = span, .ty = null, .kind = .{ .range = range } };
    const e_closure: Expr = .{ .id = 30, .span = span, .ty = null, .kind = .{ .closure = closure } };
    const e_chain: Expr = .{ .id = 31, .span = span, .ty = null, .kind = .{ .iterator_chain = chain } };
    _ = e_range;
    _ = e_closure;
    _ = e_chain;
}

// A `CoreCall` is exactly where a missed type edge strands a consumer:
// `hash_write_primitive` carries the written primitive as a type argument and
// the hasher and value as value arguments, and serialising its caller without
// walking the type side would leave the primitive half of the call behind.
test "walker reaches the Hasher primitive write's type and both values" {
    var f = WalkFixture{ .alloc = std.testing.allocator };
    defer f.deinit();

    const hasher = try f.expr(.{ .path = .{ .def = 7, .generic_args = &.{} } });
    const hasher_type: types.Type = .{ .reference = &.{
        .mut = true,
        .pointee = .{ .path = .{ .segments = &.{
            .{ .name = "SeaHasher", .id = 7 },
        } } },
    } };
    const hasher_type_id = try f.ty(hasher_type);
    f.exprs.items[@as(usize, hasher)].ty = hasher_type_id;

    // The primitive's own row: a wire walk that stops at the value arguments
    // never names it, so the primitive rides as an array whose length is an
    // expression node and nothing else in the fixture points at it. Reaching
    // the probe below proves the walker descended into `generic_args`
    // rather than stopping at the call's value edges.
    const probe = try f.expr(.{ .unit = {} });
    const primitive_id = try f.ty(.{ .array = &.{
        .elem = .{ .prim = .u64 },
        .len = .{ .expression = probe },
    } });

    const value = try f.expr(.{ .literal = .{ .int = .{
        .text = "0",
        .value = 0,
        .base = .dec,
        .ty_suffix = "u64",
    } } });
    const value_type_id = try f.ty(.{ .prim = .u64 });
    f.exprs.items[@as(usize, value)].ty = value_type_id;

    const call = try f.expr(.{ .core_call = .{
        .function = .hash_write_primitive,
        .generic_args = &.{f.types.items[primitive_id]},
        .args = &.{ hasher, value },
    } });

    var walk = try f.walker();
    defer walk.deinit();
    const reached = try f.alloc.alloc(bool, f.exprs.items.len);
    defer f.alloc.free(reached);
    @memset(reached, false);
    try reachableExprIds(&walk, call, reached);

    try std.testing.expect(reached[@as(usize, call)]);
    try std.testing.expect(reached[@as(usize, hasher)]);
    try std.testing.expect(reached[@as(usize, value)]);
    // The type argument's length expression: reached only if the walker
    // descended into the call's `generic_args` type row.
    try std.testing.expect(reached[@as(usize, probe)]);
}

// The array's element expression and a `vec_lit`'s count expression consume
// the probe length through the *type* table: reaching the count node proves
// `enqueueType` walked the array's length rather than stopping at the element.
test "walker reaches the type-only repeat and index expressions" {
    var f = WalkFixture{ .alloc = std.testing.allocator };
    defer f.deinit();

    const count = try f.expr(.{ .literal = .{ .int = .{
        .text = "64",
        .value = 64,
        .base = .dec,
        .ty_suffix = "u64",
    } } });
    // A length that names an expression node rather than a number; nothing
    // else in the fixture points at `count`.
    const repeated: types.Type = .{ .array = &.{
        .elem = .{ .prim = .u8 },
        .len = .{ .expression = count },
    } };
    const repeated_id = try f.ty(repeated);

    const element = try f.expr(.{ .literal = .{ .int = .{
        .text = "0",
        .value = 0,
        .base = .dec,
        .ty_suffix = "u8",
    } } });

    const repeat_lit = try f.expr(.{ .array = .{ .elements = &.{element}, .repeat = 64 } });
    const indexed = try f.expr(.{ .index = .{ .base = repeat_lit, .index = element } });
    f.exprs.items[@as(usize, repeat_lit)].ty = repeated_id;
    f.exprs.items[@as(usize, indexed)].ty = repeated_id;

    var walk = try f.walker();
    defer walk.deinit();
    const reached = try f.alloc.alloc(bool, f.exprs.items.len);
    defer f.alloc.free(reached);
    @memset(reached, false);
    try reachableExprIds(&walk, indexed, reached);

    try std.testing.expect(reached[@as(usize, indexed)]);
    try std.testing.expect(reached[@as(usize, repeat_lit)]);
    try std.testing.expect(reached[@as(usize, element)]);
    try std.testing.expect(reached[@as(usize, count)]);
}

// A Vec's repeat count is an ordinary expression with its own effects and
// types, while a fixed array's is a plain number. Walking the array must not
// produce the Vec's count node, and walking the Vec must — the two count
// shapes stay distinct on the wire exactly here.
test "walker keeps a Vec repeat expression apart from a fixed array count" {
    var f = WalkFixture{ .alloc = std.testing.allocator };
    defer f.deinit();

    const element = try f.expr(.{ .unit = {} });
    const count = try f.expr(.{ .unit = {} });

    const fixed = try f.expr(.{ .array = .{ .elements = &.{element}, .repeat = 64 } });
    const dynamic = try f.expr(.{ .vec_lit = .{
        .elements = &.{element},
        .repeat = .{ .expression = count },
    } });

    var walk = try f.walker();
    defer walk.deinit();

    const reached_fixed = try f.alloc.alloc(bool, f.exprs.items.len);
    defer f.alloc.free(reached_fixed);
    @memset(reached_fixed, false);
    try reachableExprIds(&walk, fixed, reached_fixed);
    try std.testing.expect(reached_fixed[@as(usize, fixed)]);
    try std.testing.expect(reached_fixed[@as(usize, element)]);
    // The Vec's count node is a *target-side evaluation*, never a row of
    // this array: the fixed array's plain-number count cannot reach it.
    try std.testing.expect(!reached_fixed[@as(usize, count)]);

    const reached_dynamic = try f.alloc.alloc(bool, f.exprs.items.len);
    defer f.alloc.free(reached_dynamic);
    @memset(reached_dynamic, false);
    try reachableExprIds(&walk, dynamic, reached_dynamic);
    try std.testing.expect(reached_dynamic[@as(usize, dynamic)]);
    try std.testing.expect(reached_dynamic[@as(usize, element)]);
    try std.testing.expect(reached_dynamic[@as(usize, count)]);
}

// The comparison temporary is read off the operand's `Expr.ty`, which the
// walker delivers from the row itself even when the operand is nested under
// projections. Reaching the probe length proves that type row was delivered.
test "walker reaches a nested comparison operand's declared type" {
    var f = WalkFixture{ .alloc = std.testing.allocator };
    defer f.deinit();

    const payload = try f.expr(.{ .literal = .{ .int = .{
        .text = "0",
        .value = 0,
        .base = .dec,
        .ty_suffix = "u64",
    } } });
    // The merge target the frontend wrote the comparison against; nothing
    // else in the fixture points at it.
    const probe = try f.expr(.{ .unit = {} });
    const owned: types.Type = .{ .array = &.{
        .elem = .{ .prim = .u8 },
        .len = .{ .expression = probe },
    } };
    const owned_id = try f.ty(owned);
    f.exprs.items[@as(usize, payload)].ty = owned_id;

    const projected = try f.expr(.{ .field = .{ .base = payload, .field = "0", .resolved = 0 } });
    const other = try f.expr(.{ .literal = .{ .boolean = true } });
    const compared = try f.expr(.{ .binary = .{
        .op = .eq,
        .overflow = .checked,
        .lhs = projected,
        .rhs = other,
    } });

    var walk = try f.walker();
    defer walk.deinit();
    const reached = try f.alloc.alloc(bool, f.exprs.items.len);
    defer f.alloc.free(reached);
    @memset(reached, false);
    try reachableExprIds(&walk, compared, reached);

    try std.testing.expect(reached[@as(usize, compared)]);
    // The tuple projection's own base stays reachable through the field.
    try std.testing.expect(reached[@as(usize, projected)]);
    try std.testing.expect(reached[@as(usize, payload)]);
    // And the comparison's operand type row is delivered through the probe.
    try std.testing.expect(reached[@as(usize, probe)]);
    try std.testing.expect(reached[@as(usize, other)]);
}
