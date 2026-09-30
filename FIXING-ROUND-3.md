# Fixing round 3 — plan

Rounds 1 and 2 catalogued 146 crates across three batches and cleared none.
Every fix moved a layer and revealed the next. Round 3 is therefore built
around a different metric: **drive one crate all the way to translating, with
its output verified correct**, and fix the wrong-output defects that surface on
the way. A crate that translates is the first evidence in three rounds that the
chain has a bottom.

## What the net added

A third batch of 26 dependency-free crates, chosen the opposite way from the
first two: the smallest available, on the theory that crate size is the cost
driver, not error count. 146 crates, 112 unique, 2 translating.

## The headline finding

While mapping blocker chains, a subagent found a **one-line bug with the widest
reach of anything so far**, and I verified it independently on the committed
tree:

```rust
pub fn f(x: Option<u8>) -> u8 { match x { Some(v) => v, None => 0 } }
```

The generated package does not build: `use of undeclared identifier 'r2z'`.
`lowerOptionalMatchArm` emits `r2z.option.unwrap` (`lower.zig:10850`) and the
`.match` branch at `lower.zig:11123` never calls `markRuntimeImport()`. The
sibling `.if_let` arm does, at `lower.zig:11038`. **The asymmetry is the bug.**

This matters more than any individual crate: `match` on an `Option` is one of
the most common shapes in Rust, and every occurrence produces a package that
cannot build. Three rounds of layer-peeling missed it because it is not a
refusal — it is a silent success that emits broken code.

## A diagnosability defect that cost real time

On the **first** build failure inside package promotion, the compiler's stderr
is discarded. `promoteWithHooks` only prints it on the second pass
(`package.zig:888`); the first returns through `resolveFingerprint` returning
null (`package.zig:897-909`), so a one-pass compile error reaches the user as a
bare `GeneratedPackageBuildFailed` with no message. Every such defect above
was found by a subagent burning probe cycles on a silent failure.

## The target crate

`const-fnv1a-hash`, 101 lines. Chosen because a chain map measured its links
rather than inferring them, and four of them are ordinary language features
rather than machinery: a `macro_rules!` with six metavars across four fragment
kinds, `#[doc = concat![...]]` with `stringify!`, a `const fn` with a mutating
while loop, a match guard on an `Option`, wrapping arithmetic, and three widths
in one macro. It is a strict superset of corpus `fnv`, which already translates,
so it extends a known-good path rather than opening a new one.

### The candidates that were rejected, and why

This is the part worth recording, because all three *looked* ideal by size:

| crate | lines | why not |
|---|---|---|
| `defer` | 60 | 7 links, 3 of them design-level. Needs `$crate`, `impl Drop`, `ManuallyDrop` plus `ManuallyDrop::take`/`new`, and a **struct declared inside a generic fn** — a known-unsupported construct from the original backlog. One visible error, many behind it. |
| `fnvhash` | 87 | Built on `std::collections::hash_state::DefaultState`/`HashState`, an API **removed from Rust**, and it also needs `HashMap`, unreachable in the frontend today. |
| `unreachable` | 77 | Not a proc-macro crate as assumed, but needs an unresolvable crates.io dependency plus four more links. |
| `wrapping` | 82 | 3–4 links, and the crate has **zero tests**, so a translated package would be a weak regression test. |

Smallness is not reachability. Every one of these has a deep chain wearing a
short first error, which is exactly the trap round 2 warned about.

## Outcome, measured after the round

Suite **704/713**, the 9 failures being the 8 known toolchain miscompilations
plus hex. `test-crates` green at 86/86. Sources formatted.

**A crate cleared for the first time in four rounds — its library.**
`const-fnv1a-hash` (101 lines) analyses, lowers, and its generated package
builds, and its output is *correct*: the digests match the published FNV-1a
vectors for 32- and 64-bit including the empty-slice case, checked with a
driver crate rather than a re-derivation of the same code. Three frontend links
were needed — `to_ne_bytes` / `from_ne_bytes` as the native-endian
`core::mem::transmute` they name, and the result type of a core call. Corpus
`fnv` is byte-identical afterwards, so this extends a known-good path rather
than bending it.

**Its `#[cfg(test)]` module does not yet translate**, so the honest count
depends on what is being asked, and the two must not be conflated:

| question | before round 3 | after round 3 |
|---|---|---|
| library only | 2 of 112 | **3 of 112** |
| library + tests (the net default) | 2 of 112 | 2 of 112 |

The remaining failure is `UnresolvedTypePath` in the test module, from two
links the frontend owner reported and did not fix because they were not in
its two files. That is the next target, and it is a good one precisely because
the library is already proven correct.

That number is worth stating plainly rather than dressing up. One crate is not
a strategy. But it is the first evidence in four rounds that the chain has a
bottom, and it came from refusing to accept a crate by size alone.

## The round's most valuable finding was not the crate

**`match` on an `Option` emitted a package that could not build.**
`lowerOptionalMatchArm` emits `r2z.option.unwrap` and the `.match` branch never
called `markRuntimeImport()`, while the sibling `.if_let` arm did. The
asymmetry was the bug. Three rounds of layer-peeling missed it precisely
because it is not a refusal — it is a silent success that emits broken code,
so every "first error" measurement walked straight past it.

## A regression this round introduced, and then removed

Round 2 changed compound assignment to emit Zig's trapping `+=`, reasoning that
Rust has no wrapping compound-assignment *spelling* and therefore exactly one
overflow mode. That confuses a missing spelling with missing *semantics*: Rust
release wraps. The result was that `a + b` wrapped while `a += b` trapped —
**the same Rust operation with two behaviours, matching no Rust profile** — and
the trap fired in both gate modes, so three probe cases crashed. Corrected:
compound assignment again wraps, agreeing with the binary path, and the
rationale comment now states the Rust profile as an explicit decision rather
than a derivation from grammar. The correction also caught that `+%=` is
integer-only, so a naive version of it would have emitted `f64 +%= f64`, which
does not compile.

## Also fixed

- **`match` arm guards** were refused unconditionally (`error.UnsupportedMatchGuard`)
  even though the frontend lowers them faithfully and the IR carries the field
  through five layers. Now lowered as `pat => if (guard) body else <remaining
  arms>`. A frontend agent proposed desugaring guards in the frontend and was
  correctly refused: it would leave the field dead in the IR and contradict the
  other four layers. It also found a residual case — an irrefutable arm
  preceding a guarded one — that the current lowering does not cover, and
  documented it rather than shipping past it.
- **First-pass build failures swallowed the compiler's stderr**, surfacing as a
  bare `GeneratedPackageBuildFailed`. This is how the above was diagnosed: once
  fixed, the very next run surfaced a ZIR-cache write failure that had been
  invisible for three rounds.
- **The duplicated generic-context check in `src/ir/serialize.zig`** diverged
  from the one in `validate.zig` in six places, which is what `--dump rustir`
  hits. Confirmed and fixed, with the enum-parameter change proven to benefit
  both copies equally rather than only one.
- **Two runtime-iterator method names** (`len`, `clone`) were admitted on a
  slice-iterator receiver, chosen from a candidate set where every other name
  would either fail to compile or — worse — `as_slice` would emit a silently
  wrong value.

## One host caveat, and one scope decision

`/tmp` on this host is at 98% and `/var` at 90%. A round-2 probe run was
silently corrupted by a full `/var` — 94 probes had to be re-run. Any future
measurement should use `/home/tmp`, which has room.

**Input is assumed to be valid Rust. There is no borrow checker, by decision.**
A probe round found that two simultaneous `&mut` borrows, and a borrow held
across a call that mutates, both translate and produce compiling Zig with a
meaningless value. That was recorded here as a soundness gap. It is not one.
Rust's borrow checker is a compile-time guarantee, so any program that reaches
this translator has already had it; Zig and C are equally permissive about
aliasing, and the generated package is memory-unsafe in exactly the way its
source was. Adding a borrow checker would be building a Rust front-end feature
the target languages do not have.

So: the contract is *valid input in, faithful code out*, and borrow-rule
violations are out of scope by the same reasoning that build scripts and
external macro sources are. Do not re-open this as a finding.

## Also in the round

The probe programme goes into ground rounds 1–2 never touched: closure capture
and lifetime, borrow rules and NLL, trait objects and associated types, generic
associated types, and macro expansion with multiple captured variables. This is
the vein that actually pays — rounds 1 and 2 found eleven real wrong-output
bugs there and none in the crate net.

## Explicitly not in the round

Build scripts and external macro sources (both correct refusals). The manifest
group — 14 of 144 rejections and a measured capability win of **zero**.
`Vec` ownership analysis (a blind `defer deinit` would double-free every function
that returns its `Vec`). Trait bounds living in external crates.
