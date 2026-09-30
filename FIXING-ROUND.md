# Fixing round 2 — plan from the wide net

Every item below is measured, not inferred. Sources: the 55-crate corpus under
`/tmp/r2z-net/corpus`, the net results in
`/tmp/r2z-net/results/*.tsv`, executed probes under
`/var/tmp/semnet`, and root-cause reduction under `/var/tmp/tax`.

## The headline

Of 55 dependency-free real crates, **2 translate**. The repository's own six
positive fixtures all translate — but that number is not what it looks like. The
`wyhash` fixture has had its only `for i in a..b` **commented out**, and `adler`'s
manifest sets `default = []` where upstream ships `default = ["std"]`. The
`adler` source is byte-identical to upstream; it translates only because the
fixture empties the default feature closure. Coverage is real but was fitted.

## Ranked fixes

| # | Fix | Evidence | Unblocks |
|---|---|---|---|
| A | Intern `prim(.i32)` / `prim(.f64)` before inference | One unrelated `-> i32` line clears **10/10** markers in leb128 | leb128; a whole class of null-ty noise |
| B | Range loops `for i in a..b` | 3/3 probe forms fail; **the only range in the fixture set is commented out** | ubiquitous Rust |
| C | `I::assoc()` on a generic parameter | `unresolved call`; one new `lowerCall` arm | atoi, siphasher layer 2 |
| D | Expand type aliases; only `.prim` counts as scalar | spelling `[Chunk; N]` as `[u32; N]` clears 5/5 | percent-encoding |
| E | `.rev()` only admitted over a range | measured A/B on seahash | seahash |
| F | Admit `alloc::string::ToString` | deleting 2 lines clears hex's top blocker | **hex (known item 1)** |
| G | Shift amount must be `u5` | `t_1 <<= y` with `y: u32` → `expected type 'u5'` | silent miscompile |
| H | Tuple/enum constructor used as a value | `let e = A;` → `use of undeclared identifier 'A'` | silent miscompile |
| I | `Vec` indexing lowered to `ArrayList` indexing | `v[0]` → `does not support indexing` | silent miscompile |
| J | `empty_statement` missing from item dispatch | `rustc-hash` ParseFailed is one absent node case | rustc-hash |

## Correction: the corpus histogram is a depth signal, not a work queue

Measured after this round was scoped: for all 20 headline corpus crates, the
reported blocker was neutralised and the crate re-run. **0 of 20 translate.**
Each moves on to a different error. The `UnsupportedConstInitializer` group is
not one cause but five raise sites across five different Rust shapes; the
`UnsupportedCfgPredicate` group is likewise mostly a deliberate "refuses to"
at `cst.zig:5304`, documented and pinned by a test.

So the ten-crate groups do not mean ten crates of work available. They mean the
translator is many layers short of these crates. This round is therefore scoped
to the **repository's own ten rejecting fixtures**, where each cause is
distinct, isolated and verifiable — not to the corpus counts. A fixture that
starts translating is the unit of progress; a corpus error moving one layer
deeper is not.

**Deliberately not fixed:** `crc16` (build scripts — the translator does not run
Cargo) and `fletcher` (external macro with no source). Both are correct
refusals, not gaps.

**Explicitly deprioritised:** the manifest group is 8 of 55 rejections but a
measured capability win of **zero** — all 8 move past the manifest and fail with
a different error. Do not fix it for the count.

## Outcome, measured after the round

Every item A–J landed, each with a regression test verified to fail without its
fix. Four were real wrong-output bugs found by the net rather than refusals: the
`u5` shift amount, the unqualified tuple/enum constructor, `Vec` indexing, and
range loops — the last of which was **entirely dead**, since the only
`for i in a..b` in the whole fixture set was commented out.

Suite: **882/891 passing**, 9 failing — the same 8 toolchain miscompilations as
before, plus hex. `test-crates` is green at 86/86. Sources are formatted.

**No fixture started translating.** The honest reading is that each fix moved a
layer deeper without clearing a crate:

| fixture | before | after |
|---|---|---|
| leb128 | `operator requires primitive operands` | `method dispatch unavailable` |
| percent-encoding | `operator requires primitive operands` | `method receiver unavailable` |
| hex | `UnsupportedExternalUse` | `UnsupportedExpression` at `lower.zig:10868` |
| atoi | `unresolved call` | unchanged — Fix C did not reach its shape |
| seahash | `InvalidCast` | `InvalidCast`, now at `infer.zig:6110` |
| siphasher | `UnresolvedTypePath` | unchanged, `validate.zig:1382` |
| itoa | `InvalidCast` | `InvalidCast`, now at `infer.zig:6110` |

The corpus histogram is unchanged, exactly as the first-failure correction
predicted. That is the shape of the problem: these crates are many layers deep,
and clearing one layer reveals the next rather than ending the story. The right
unit of progress from here is a named fixture reaching translation, not a corpus
error moving one step along.

## Cross-cutting design point

The frontend has a non-fatal channel (unsupported markers) **and** a fatal
channel (typed errors). Four causes reach the fatal channel only because one
missing type escalates before the marker is consulted. Making that escalation
non-fatal would turn four opaque errors into four named markers, letting each
fix land and be verified independently. This is the highest-leverage structural
change available, and it is deliberately not in the round above because it
changes error contracts the suite pins.

## Corrections this net forced on the documentation

1. The two `operator requires primitive operands` cases do **not** share a
   cause (leb128 = A, percent-encoding = D).
2. The two `InvalidCast` cases do **not** share a cause, despite
   `e2e_test.zig` calling seahash "the same inference gap as itoa".
3. hex's blocker is `alloc::string::ToString`, **not** `pretty_assertions` —
   that import is already handled at `lower.zig:3283`.
4. `xxhash-rust` **no longer rejects**. The `EmptyRootFile` pin in
   `test/e2e_test.zig` and in `HANDOFF.md` is stale for this tree.
