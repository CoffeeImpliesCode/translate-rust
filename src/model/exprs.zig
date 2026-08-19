//! translate_rust.model.exprs — Expr / Pattern / Statement (P3 model layer).
//! See notes/design/data-model/exprs-patterns.md §0–§5.
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
    method_call: MethodCall,
    struct_lit: StructLit,
    enum_variant: EnumVariant,

    // — access (§1.4) —
    field: FieldExpr,
    index: IndexExpr,

    // — operators (§1.5) —
    binary: BinaryExpr,
    unary: UnaryExpr,
    assign: AssignExpr,
    try_: TryExpr,
    return_: ReturnExpr,

    // — deferred seams (§4, not emitted in v1) —
    closure: ClosureExpr,
    iterator_chain: IteratorChainExpr,

    // — explicit refusal —
    unsupported: Unsupported,
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
/// Lossless: the emitter re-derives Zig array syntax (`&[_]u8{ ... }`,
/// collapsing to `&[_]u8{V} ** N` when every byte is equal).
pub const ByteArrayLit = struct {
    items: []const u8,
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
/// diagnostics; emitter lowers to optional capture / switch.
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

// §1.4 Access ───────────────────────────────────────────────────────────────

pub const FieldExpr = struct {
    /// Base expression index (expr table).
    base: NodeId,
    field: []const u8,
    resolved: DefId,
};

pub const IndexExpr = struct {
    /// Base expression index (expr table).
    base: NodeId,
    /// Index expression index (expr table).
    index: NodeId,
};

// §1.5 Operators ────────────────────────────────────────────────────────────

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

/// The emitter lowers each adapter to an explicit loop; sealed union so
/// `analyse` rejects unknown adapters loudly but v3 only adds arms.
pub const IteratorChainExpr = struct {
    /// Base iterable expression index (expr table).
    source: NodeId,
    adapters: []const IteratorAdapter,
};

pub const IteratorAdapter = union(enum) {
    map: MapAdapter,
    filter: FilterAdapter,
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
    tuple: TuplePat, // (a, b, ..)
    slice: SlicePat, // [a, b, ..rest, c]
    struct_pat: StructPat, // Point { x, y, .. }
    reference: ReferencePat, // &pat / &mut pat (rare post-desugar)
    @"or": OrPat, // `a | b`
    range: RangePat, // `1..=5`, `'a'..='z'`
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

// =============================================================================
// Tests — instantiate every union arm and struct to prove compile.  All values
// use compile-time static slices; no allocator needed (mirrors items.zig).
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

    // Explicit refusal
    const unsup: Unsupported = .{ .reason = "match guards", .suggested_version = .v2 };

    // ── Wrap every ExprKind arm into an Expr (final _ = block) ─────────────
    const e_lit: Expr = .{ .id = 1, .span = span, .ty = null, .kind = .{ .literal = lit_int } };
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
    const e_field: Expr = .{ .id = 17, .span = span, .ty = null, .kind = .{ .field = field_expr } };
    const e_index: Expr = .{ .id = 18, .span = span, .ty = null, .kind = .{ .index = index_expr } };
    const e_bin: Expr = .{ .id = 19, .span = span, .ty = null, .kind = .{ .binary = bin_expr } };
    const e_unary: Expr = .{ .id = 20, .span = span, .ty = null, .kind = .{ .unary = unary_expr } };
    const e_assign: Expr = .{ .id = 21, .span = span, .ty = null, .kind = .{ .assign = assign_expr } };
    const e_try: Expr = .{ .id = 22, .span = span, .ty = null, .kind = .{ .try_ = try_expr } };
    const e_ret: Expr = .{ .id = 23, .span = span, .ty = null, .kind = .{ .return_ = ret_val } };
    const e_unsup: Expr = .{ .id = 25, .span = span, .ty = null, .kind = .{ .unsupported = unsup } };
    _ = e_lit;
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
    _ = e_field;
    _ = e_index;
    _ = e_bin;
    _ = e_unary;
    _ = e_assign;
    _ = e_try;
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

    // Unsupported (consumed by IteratorAdapter.other below)
    const unsup: Unsupported = .{ .reason = "scan", .suggested_version = .v3 };

    // IteratorAdapter — all 6 variants
    const ia_map: IteratorAdapter = .{ .map = map_ad };
    const ia_filter: IteratorAdapter = .{ .filter = filter_ad };
    const ia_enum: IteratorAdapter = .{ .enumerate = {} };
    const ia_zip: IteratorAdapter = .{ .zip = zip_ad };
    const ia_rev: IteratorAdapter = .{ .range_rev = {} };
    const ia_other: IteratorAdapter = .{ .other = unsup };
    _ = ia_filter;
    _ = ia_enum;
    _ = ia_zip;
    _ = ia_rev;
    _ = ia_other;

    // IteratorChainExpr (consumed by IterKind.adapter below)
    const chain: IteratorChainExpr = .{ .source = 11, .adapters = &.{ia_map} };

    // IterKind.adapter variant (the deferred escape)
    const ik_adapter: IterKind = .{ .adapter = chain };
    _ = ik_adapter;

    // Wrap closure & iterator_chain in their Expr arms
    const e_closure: Expr = .{ .id = 30, .span = span, .ty = null, .kind = .{ .closure = closure } };
    const e_chain: Expr = .{ .id = 31, .span = span, .ty = null, .kind = .{ .iterator_chain = chain } };
    _ = e_closure;
    _ = e_chain;
}
