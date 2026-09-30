# Fixing round 2 — plan

Round 1 cleared zero fixtures. Round 2 is therefore aimed at two different
things, and it is worth being explicit about which is which.

**Depth**, on the seven blocked fixtures and the 116-crate corpus. Round 1's own
taxonomy established that clearing one layer reveals the next: 0 of 20 headline
corpus crates translated after their reported blocker was neutralised. But the
round 2 net found something round 1's corpus missed, because batch 2 was shaped
differently: **the raise SITES are few even though the crates are many.** Twenty
sites account for every rejection across 116 crates, and the smallest crate at
several of them is under 200 lines — which means the cause is probably small
even where the crate is large.

**Wrongness**, which is what actually matters. A 197-probe semantic sweep
re-ran round 1's probes (all four wrong-output bugs confirmed fixed, none
regressed) and added 160 more. It found **one silent wrong-value bug** and ten
more constructs that are accepted and then emit Zig which does not compile.
An accepted-and-wrong construct is worse than a refusal: it costs a debugging
session instead of an error message.

## Tier 1 — silent wrong values. Fix first.

| # | Construct | Evidence | Cost |
|---|---|---|---|
| A1 | `continue 'label;` drops the label and targets the innermost loop | compiles, runs, returns 12 where Rust says 8. A/B over 21 candidate values, one passes in both runs | one guard |
| A3 | `.iter().sum()` adds pointers | emits `expected type 'u32', found '*const u32'`; a pointer-shaped sum target would silently sum addresses | one place |
| A9 | every compound assignment emits the wrapping form | `t_1 +%= 4294967295; t_1 +%= 2;` yields 1 and the test passes. Rust debug builds panic. Both gate modes compile it, so it is never caught | one operator map |

A1 is the sharpest: `lower.zig:11247` discards a label the IR already carries
(`exprs.zig:294-296`), while a labelled **break** is correctly refused. The
validator protects one and not the other.

A3 escaped the fixtures because `compat` uses `.copied().map().filter().sum()` —
`copied` supplies the deref. No fixture uses a bare `.iter().sum()`.

## Tier 2 — accepted but emits non-compiling Zig. Refuse rather than emit junk.

`A4` tuple pattern in a match arm · `A5` `if let` / `let-else` Option payload ·
`A6` `let t = 5u32; t += 1;` emitted as a Zig `const` · `A7` `.rev()` on a
byte-slice iterator and `.count()` on a range, methods that do not exist ·
`A8` `Option::map` · `A10` a `Vec` returned by a call and indexed inline.

A4 and A5 are the same class as round 1's fix H — a name emitted with no
declaration anywhere — one level over, in pattern position rather than value
position. A6 is an extremely common Rust idiom.

## Tier 3 — depth, via the non-fatal channel

`infer.zig:6110` is reached when a cast's operand is untyped. It hard-errors
with `InvalidCast`; it should mark the expression unsupported. Scoped to exactly
that condition — operand `.ty == null` **and** source type `.unsupported` — one
edit clears seahash's layer 1 and itoa's layer 1 together. This is the
"non-fatal escalation" change round 1 deferred as too broad; scoping it to one
site makes it tractable.

Note the two are genuinely different bugs sharing one line: seahash is an
open-ended slice range `X[..n]` leaving the operand untyped, itoa is a
qualified associated-type projection used as a cast target. Fixing one will not
fix the other.

Two corpus clusters are aimed at the smallest crates at them:

| site | crates | smallest |
|---|---|---|
| `ir/validate.zig:1382` | 6 | `wrapping` at 82 lines |
| `frontend/cst.zig:1681` | 5 | `void` at 121 lines, `saturating` 193, `nb` 283 |

## Tier 4 — remaining accepted-wrongness

`A2` the integer range element type is dropped (8 of 11 forms emit
non-compiling Zig; the IR's `Literal` has no type-suffix field to hold it) ·
`A11` every `Vec` allocation leaks, a new layer behind round 1's indexing fix.

## Corrections the round 2 work forced

- Round 1's `compat_vec` "index out of bounds: index 2, len 2" was **our own
  bad test expectation**, not a translator bug. `collected(&[1,2,3,4])` filtered to
  `x>4` is `[6,8]`, so `len 2` is right.
- `itoa`'s remaining `unresolved call` is **not** round 1's generic-`I::assoc()`
  arm failing. That arm is firing and works. The remaining refusals are trait
  bounds living in an external crate — a separate, documented limitation.
- `infer.zig:6110` is a shared **line**, not a shared **bug**.

## Explicitly not in this round

`crc16` and `fletcher` (build scripts and external macro sources — both correct
refusals). The manifest group, which is 14 of 116 rejections and a measured
capability win of **zero**. External-crate trait bounds. Struct update syntax,
trait objects, `dyn`, and `impl Trait` in argument position — all clean typed
refusals, and all buying no currently-reachable fixture.

## Outcome, measured after the round

Suite: **695/704 passing**, 9 failing — the same 8 toolchain miscompilations plus
hex. `test-crates` green at 86/86. Sources formatted. Corpus: still 2 of 116
translating.

Tier 1 landed as follows. **A1** was **refused** rather than implemented, and
that is the right call: the IR has no label on `for` or `while` at all, only on
`loop`, so emitting `:label` would have meant changing ZigAST and the encoder —
files the change did not own. Refusing makes a labelled `continue` behave like
the already-refused labelled `break`. **A3** was implemented: the sum sink now
dereferences. **A9** was implemented on the backend's side and the real producer
bug reported: Rust has no wrapping compound-assignment operator, so a compound
assign has exactly one overflow mode, and the backend now derives it from the
grammar instead of trusting a field. Goldens moved accordingly — adler's
`s.* +%= o.*` became `s.* += o.*`, which is the correct correspondence.

Tier 2 split by cost: A5 (`if let`, Option form) and A8 (`Option::map`) were
implemented; A1, A4, A5b, A7 and A10 were refused so they stop producing Zig
that cannot compile. A4 and A5 were the same class as round 1's fix H — a name
emitted with no declaration anywhere — one level over, in pattern position.

Tier 3 landed and did what it was aimed at. The non-fatal escalation at
`infer.zig:6110` turned both `InvalidCast`s into named markers, and both moved
on: seahash to `operator requires primitive operands`, itoa to `unresolved
call`. `UnresolvedTypePath` fell from 8 crates to 6 and `UnresolvedNominalType`
from 9 to 6, so the depth fixes moved **five** crates off three sites. Enum type
parameters were simply never recorded — `enumItem` scanned for variants and
type identifiers but not `type_parameters`, so `EnumBody.generic_params` was
always empty and both the validator and the serializer were checking variant
field types against an empty scope.

One correction worth recording because it was nearly shipped wrong: widening
the validator's generic context appeared to make it a blanket admission, and
two negative controls caught it. The cause was **not** the widening — a struct
method's signature was never validated at all. The method loop built
`method_context` and passed it only to `validateGenericsContext` and the body
walk; `method.params` and `method.ret` were skipped, so every name in a
re-parented method's signature was admitted regardless. The widening is what
makes the restored check precise enough for the six crates it targeted.

Tier 4 was deferred with reasons rather than attempted. A2 needs a field on
`ast.Literal` plus a serializer round-trip. A11 — every `Vec` allocation leaks —
is an ownership analysis, not a mechanical insertion: a blind `defer deinit`
would double-free every function that returns its `Vec`.

**Third consecutive round in which no crate starts translating.** Five crates
moved a layer; zero cleared. The evidence now points one way: these crates are
not a queue of independent bugs but a dependency chain roughly as deep as the
translator's feature set, and the per-fix cost is real while the per-round
yield is a handful of crates moving one step. Worth deciding explicitly whether
that trade is the one worth making, rather than discovering it a fourth time.
