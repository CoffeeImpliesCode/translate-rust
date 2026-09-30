# Handoff — translate-rust

Written 2026-09-29; revised 2026-09-30 after a clean-checkout measurement pass. **The work
described below is committed.** The substantive batch is `xpwlyywn` ("wip: eight-fixture
Rust-to-Zig translation batch (hex incomplete)"). Its child `mvquxpkn` ("chore: drop two
stray demo-package scratch directories from the repo root") is the last revision that
touches the tree, and the working-copy commit `sklorwok` stacked on top carries no
description: it is host-toolchain work only (`AGENTS.md`, `devenv.nix`,
`tools/zig-pinned.sh`). So `jj st` does report three modified files, but nothing in the
translator, the fixtures, or the goldens is uncommitted. Revision ids are stable now that
the batch is committed; a transcript written before that commit still shows a hash that
moved with every amend, so trust the description there and the id here.

## What this project is

Zig 0.16 research project translating a Rust subset into standalone Zig packages.
Pipeline: `Rust source -> tree-sitter -> frontend -> RustIr -> ZigAST -> staged package validation -> zig build test -> atomic promotion`.

Canonical wire format is **v6**; every other version is rejected at the driver boundary.
Older sidecar JSON is diagnostic inventory for `--dump model` only, never translation input.

## Verified state

| Check | Result |
|---|---|
| `tools/zig-pinned.sh test`, Debug | 871 tests, **9 failing** (was 23) |
| `tools/zig-pinned.sh test-crates` | **PASSED** — 3/3 steps, 86/86 tests |
| `tools/zig-pinned.sh test-e2e` | blocked by the `hex` fixture, see item 2 |
| `gate` (devenv shell) | not run — `test-e2e` is red while `hex` is incomplete |

The counts above were measured before the round 2 work. `FIXING-ROUND-2.md` carries the latest
measured suite: **695/704 passing**, 9 failing — the same 8 toolchain miscompilations plus
`hex` — with `test-crates` green at 86/86. Anything measured after that date lives in
`FIXING-ROUND-2.md` or `FIXING-ROUND-3.md`, not here.

### Triage: 23 failures down to 9, and all 9 are accounted for

The tree is **not** green, but what is left is now almost entirely *not ours*.

**1. Eight failures are a Zig 0.16.0 miscompilation — not our code.** All eight sit in
the single `translate_rust.frontend` Debug test binary (root `src/frontend/root.zig`).
The literal `"vec"` reads back as `0xAA` undefined-fill, so `identifyMacro("vec!")`
answers `.custom`. Three experiments pin this to the toolchain: the 7 failing
`pipeline` test bodies, copied verbatim into a smaller binary, all pass (165/165);
the same bodies appended to the *failing* binary all pass while the original 8 call
sites still fail in that same run; and the Debug CLI, built from the same tree,
behaves correctly on every one of those tests' exact Rust sources. Identical code,
same binary, different call site, different result — no source change can produce
that. Full analysis: `tools/zig-0.16.0-vec-literal-miscompile.md`. **Do not "fix"
these.** The 148 ReleaseSafe crashes are believed to be the same fault; that is a
belief, not a measurement.

**2. One failure is the `hex` fixture, a real and still-open capability gap.** hex does
not translate, so its golden test fails and `generate-hex-golden` cannot run. The commit
that added the fixture is titled "…(hex incomplete)", so this is known and tracked, not a
regression — but four gaps have been closed along the way and the blocker has moved four
times. Where it stands, most recent first:

  1. `UnsupportedExternalUse`, returned at the end of the `.external` arm of
     `useHasLowerableTarget` in `src/backend/zig/lower.zig`. hex's two `#[cfg(test)]`
     modules reach it through their `use alloc::string::ToString;` line. This entry was
     wrong until a wide corpus measurement corrected it: it used to name
     `pretty_assertions` as an unmodelled external crate, but that import is already
     admitted, by the `useNamesUntranslatedCrate` branch of the same function (currently
     `lower.zig:3283-3293`), because the macro itself is expanded by the frontend and the
     import is already spent. Deleting hex's two `use alloc::string::ToString;` lines
     clears this top blocker.
  2. `UnsupportedExpression` on a `vec![]` literal inside a `#[test]` entity, from
     `lower.zig:10825`.
  3. `chunks` was missing from the frontend's iterator-chain vocabulary, so
     `hex.chunks(2).enumerate().map(..).collect()` stayed nested method calls. **Fixed**:
     `chunks` and `chunks_exact` are chain links now, and `iteratorItemType` names
     `core::slice::{Chunks,ChunksExact}<T> -> &[T]`. `windows` was deliberately NOT
     admitted — nothing lowers a receiver's `.windows(n)` at all, so admitting the name
     would promise an adapter the backend never emits.
  4. `Option::map`/`Result::map` with a tuple-destructured closure parameter was refused
     because `patternName` rejects tuple patterns. **Fixed**.

  Closed earlier: a trait method's result could not be named from its signature plus a
  call-site turbofish, because the call-site callee is a bodiless `method_ref`; and the
  `collect::<Vec<_>>()` result was unnamed because the turbofish binding ran before the
  receiver walk. Both are fixed and pinned.

**3. The 14 failures that are now fixed, and what each was.**
- *Six golden fixtures were stale twice over, and were regenerated.* The lowerer emits a
  `pub` module import as a re-export `const_decl` rather than populating `ast.File.imports`,
  and the emitter emits a top-level `bin_op` bare rather than wrapping it. Both changes are
  intentional. `mini`, `fnv`, `compat`, `wyhash`, `adler` and `multimod` were refreshed with
  the new `generate-<fixture>-golden` steps, never hand-edited. **hex's goldens were NOT
  regenerated**, because hex does not translate; its `rust_ir` and `zig_ast` snapshots are
  stale and stay that way until the blocker above is closed.
- *A real `package.zig` bug.* `workspaceCoreAbsolute` resolved `@src().file` against a
  runtime anchor, but the compiler spells it relative to the *module root*, so the
  three-level climb landed two levels above the repo and the `r2z-core` probe always
  missed. It surfaced as `DependencySourceUnavailable` and broke every
  `zig build run -- <crate> -o <dir>`, and with it promotion, `test-e2e` and the gate.
  The walk now uses only the runtime anchor. It was never an NFS artefact: any local
  copy that happened to have an `r2z-core` checkout two levels up masked it.
- *Two stale assertion needles* in `lower_test.zig` expected parenthesised output the
  bare-`bin_op` policy no longer emits.
- *A self-contradictory fixture.* `emitBlanketImplFixture` built byte-identical IR for
  its "valid" and "refused" shapes while one test demanded success and another
  demanded rejection of that same IR. It now builds three distinct situations, and a
  missing `validateMethodTopology` call in `collectHoistedMethods` — which had let two
  rejections silently pass — was added at the one place where it is meaningful.
- *A lost safety net.* compat stopped generating its two
  `translated tests reachable through …` tests, because the scan read `file.imports`
  after import promotion had emptied it. The scan now reads promoted re-exports too.

Do not "fix" the lowerer to satisfy a stale snapshot.


The e2e run ends with:
`e2e: mini/fnv/wyhash/adler/compat/hex/multimod/xxhash-rust translated; source siphasher/itoa/atoi/leb128/seahash/percent-encoding/fletcher/crc16 rejected with pinned typed errors; fnv/fletcher wire rejected; translateWithOptions honoured`:

`zbc` reports 31 ADVISORY findings, as it always does here, and is advisory per `AGENTS.md`.
The long-standing ones are struct literals built with `Lowerer.alloc`, which is the driver arena
and unwinds on error. Do not "fix" them. The only thing worth doing there is a doc comment on
`lowerRustIr` recording that it requires an arena.

`tools/zig-pinned.sh run -- test/crates/hex -o <dir>` does **not** succeed today: hex is the
open blocker described above. The other seven positive fixtures do translate. A bare `zig` is
the anyzig shim on this host regardless — see **Working notes**.

### Coverage

Translate end to end today: `mini`, `fnv`, `compat`, `wyhash`, `adler`, `multimod`,
`xxhash-rust`, plus the canonical v6 `mini` wire fixture. The end-to-end matrix in
`test/e2e_test.zig` requires **eight** source fixtures — those seven plus `hex` — and as of the
last measurement (`FIXING-ROUND-2.md`, 2026-09-30) `hex` still refuses, so `test-e2e` and the
gate are red on `hex` alone.

`wyhash` (2 vectors / 9 assertions), `adler` (5 vectors), `fnv` (203 assertions) all execute their
translated tests under the generated package's own `zig build test`.

`multimod` is in the end-to-end matrix: `test/e2e_test.zig` requires it to translate into four
files (`src/root.zig`, `src/foo.zig`, `src/foo/bar.zig`, `src/custom_pub.zig`) and
`src/frontend/pipeline.zig` asserts its module tree (`mod foo;`, two-level `mod bar;` inside
`foo.rs`, and `#[path = "..."]` resolution). Nothing else in the suite lowers or emits it.

Reject by macro source: `fletcher` (`ExternalMacroSourceUnavailable`), `crc16`
(`BuildScriptArtifactUnavailable`). Reject by wire: the legacy `fnv.json` and
`fletcher.json` fixtures, plus every non-v6 sidecar in `test/`.

`xxhash-rust` was listed here as rejecting at promotion with `EmptyRootFile`, and that pin
was stale for this tree. It is gone from `test/e2e_test.zig`, which now requires the
fixture to translate: `tools/zig-pinned.sh run -- test/crates/xxhash-rust -o <dir>`
succeeds and stages a four-file package — `src/root.zig`, `src/utils.zig`,
`src/xxh32_common.zig`, `src/xxh32.zig` — whose `src/root.zig` carries the three module
re-exports. The earlier apparent failure was a pre-existing output directory
(`DirNotEmpty`), not a translation failure; the driver refuses to write into a directory
that already exists, and the measurement runner re-ran its translate into the directory the
first run had just populated.

Two crates of that name must not be conflated. The fixture is a vendored v1-dialect copy
whose manifest sets `default = ["xxh32"]`, so cfg evaluation keeps three modules. The
upstream 0.8.19 crate the wide corpus measured declares no `default` feature at all, so
cfg evaluation drops every module and that crate genuinely reduces to an empty root. The
corpus row for the upstream crate stands; the `EmptyRootFile` pin on the fixture did not.

`hex` is a fixture in progress, not a completed one. Note the feature model: an empty
`--features` selection means the manifest's `default` closure applies, and hex's
`default = ["std"]` pulls in `alloc` transitively, so its `#[cfg(feature = "alloc")]` code
**is** analysed. Its upstream `#[cfg(test)]` module also uses `pretty_assertions`, whose
import is admitted even though the macro it names is not a modelled dependency.
Do not "fix" hex by selecting fewer features; that would delete coverage while looking
like progress.

## Layout worth knowing

```
src/ir/            canonical RustIr + the v6 JSON boundary; owns IR validation
src/frontend/      tree-sitter ingestion, macro expansion, method resolution, type inference
src/backend/zig/   ZigAST, lowering, emission, serialization, package promotion
src/driver/        source and wire orchestration
r2z-core/          runtime the generated packages import (String, Result, Option, ops, iterators)
test/crates/       source fixtures; test/golden/ holds RustIr + ZigAST + emitted-source snapshots
test/generate_*.zig  regenerators, one per build.zig step
```

`golden_test.zig` drives `mini`, `fnv`, `compat`, `wyhash`, `adler`, `multimod`, and `hex` as
translation fixtures (plus `missing` as a declared rejection) and compares byte for byte,
printing the actual payload on mismatch. There is **no** auto-update mode, so a fixture with
no generator is hand-updated from the dumped output.

Regenerators that exist, one per fixture plus the wire file: `zig build generate-mini-wire`,
`generate-mini-golden`, `generate-fnv-golden`, `generate-compat-golden`,
`generate-wyhash-golden`, `generate-adler-golden`, `generate-multimod-golden` and
`generate-hex-golden`. This file used to list three of them and call the rest "being added";
they are all in `build.zig` now. Hand-editing those snapshots is what this file warns against.

## Recent work (committed as `xpwlyywn` and its ancestors)

```
r2z-core    structural equality: r2z.ops.equal compares aggregates by value
frontend    equality admission: builtInEqualityType covers result and payload enums
frontend    trait calls through a qualified path
backend     inline closures, range patterns, named-field variant construction
backend     per-self-type trait method names, impl Trait returns, iterator adapters
fixtures    hex promoted from reject to a full fixture: goldens + e2e coverage
build       new generate-hex-golden step
```

The thread through all of it: `assert_eq!` lowers to a binary `==` over its two dereferenced
operands, and equality on `Result` and on payload-carrying enums was the single thing keeping
`hex` from translating. Everything else above was pulled in behind it.

## Non-obvious invariants

**Zig 0.16 has no `==` for structs or unions.** `std.meta.eql` is the native aggregate comparison.
Anything that assumes `==` works on an aggregate will not compile. `r2z.ops.equal` keeps a
`std.meta.eql` fast path behind a `comptime` check for exactly this reason.

**A Zig range is a statement, not a value.** `0..len` cannot be a receiver, an argument, or a
binding. A range in a value position lowers to an `r2z.Range{ .start = .., .end = .. }` struct
literal. A `for` header is the one position that does accept a range, and there it stays bare:
the emitted hex root reads `for (out[0..], 0..)`, with `0..` still a range.

**Rust namespaces fields and methods separately; Zig does not.** hex has a `next: Option<char>`
field next to an `impl Iterator::next` method. The field is emitted as `next_field`, because the
runtime iterator protocol calls the method by name and a colliding field would shadow it.

**Trait impls for a non-struct self type have no declaration body to hoist onto.**
`impl Trait for [u8; N]` has no struct to attach methods to, so its methods hoist to the enclosing
module. Several impls of one trait for different self types must be emitted under distinct names or
they collapse into one and the wrong return type wins — hence the emitted hex root carries
`from_hex__u8_2`, `from_hex__u8_3`, and one name per array length rather than a single
`from_hex`. hex's macro expands roughly 145 such impls.

**A field-less enum variant is a value, not a type.** It must be emitted module-qualified
(`error_1.FromHexError.OddLength`) or it names nothing at the use site.

**The frontend deliberately leaves iterator methods as ordinary calls.** The backend picks the
runtime implementation from the external iterator carrier plus the method name. Do not "resolve"
these in the frontend; that decision belongs in the lowerer.

**Zig only collects `test` blocks from analyzed files.** An unused container-level `@import` is never
analyzed, so a translated test module that nothing references compiles away and `zig build test`
reports success over zero assertions. `appendTestReachabilityRefs` emits a synthetic reference per
reachable test module. There is exactly one test artifact, rooted at `src/root.zig` — a per-file
test artifact cannot work, because a file compiled as its own module root may not import its
siblings.

**Rust `private` means "this module and its descendants"; a Zig file is a hard boundary.** Descendant
Rust modules become sibling Zig files, which cannot see a non-`pub` item. Items are therefore emitted
`pub` outside the crate root. This is a real semantic widening — the crate's public API still
comes from `src/root.zig` re-exports, but a `pub mod`'s private items are now reachable. Recorded in
commit `9895359`.

**A `pub` module import is emitted as a re-export, not as an import entry.** A `pub mod`
in Rust re-exports its contents, so a `pub` import whose path starts with `./` is lowered
to `pub const NAME = @import("...");` — a `const_decl` wrapping a builtin `import` node —
and is removed from `ast.File.imports`. This is `promotePublicModuleImportsToReExports`
in `src/backend/zig/lower.zig`. Consequences worth knowing: the import moves to the bottom
of the emitted file rather than the top, and a non-`pub` import stays in `file.imports`,
which is why `adler`'s `tests.zig` keeps its reachability test and `compat`'s `pub` modules
briefly did not. Do not "fix" emitted code to match an older snapshot; regenerate.

**A top-level `bin_op` is emitted bare.** The emitter parenthesises only where Zig
precedence demands it, via `needsOperandParens`. Snapshots taken before that policy
landed show `return (seed ^ P0);` where the current emitter produces `return seed ^ P0;`.
Again: regenerate, never hand-edit a snapshot to match.

## Round 3, measured 2026-09-30 — wrong output, not depth

Read this beside the list under **Next step**, which describes capability gaps at the
*first* error. The crate metric has not moved once in three rounds: 146 crates catalogued
across three batches, **zero cleared**. The other metric has. `FIXING-ROUND-3.md` counts
**eleven real wrong-output bugs** found and fixed by the round 1–2 probe sweeps, against none in
the crate net — round 2's 197-probe sweep alone re-ran round 1's four and added one silent
wrong value plus ten accepted shapes that emit Zig which cannot compile. Round 3's headline
find, below, is one more of the same class. The measurements live in `FIXING-ROUND.md`,
`FIXING-ROUND-2.md` and `FIXING-ROUND-3.md`; what follows is only what the tree looks like
afterwards. All of it is uncommitted in the working copy as of this date.

**1. `match` on an `Option` emitted a package that could not build.** This is the widest reach
of anything found in three rounds, because `match` on an `Option` is one of the most common
shapes in Rust and every occurrence produced broken output:

```rust
pub fn f(x: Option<u8>) -> u8 { match x { Some(v) => v, None => 0 } }
```

`lowerOptionalMatchArm` (`lower.zig:10809`) emits `r2z.option.unwrap` (`lower.zig:10858`), and
the `.match` arm of `lowerExpr` (`lower.zig:11206`) never called `markRuntimeImport()`, while
the sibling `.if_let` arm did (`lower.zig:11180`). **The asymmetry is the bug:** the emitted
file named `r2z.` with an empty import list, and `zig build` answered `use of undeclared
identifier 'r2z'`. Three rounds of layer-peeling missed it because it is not a refusal —
translation *succeeded*. It was found only by hand-compiling the emitted output. Fixed on the
payload path alone (`lower.zig:10854`), because a `Some(_)` arm and an irrefutable binding emit
no runtime call; pinned by the `Match and the r2z runtime import` group in `lower_test.zig`
(from `lower_test.zig:12038`).

**2. `match` arm guards were refused outright.** `error.UnsupportedMatchGuard` fired on any
guarded arm (`lower.zig:11084` when it was measured) even though the frontend lowers the guard
faithfully — `lowerMatch` in `src/frontend/ts_ext.zig` reads the `condition` field of
`match_pattern` — and the IR carries `MatchArm.guard` through five layers: `exprs.zig:251`,
`validate.zig:2164`, `serialize.zig:4274`, `monomorphize.zig:615`, `infer.zig:1151`. The
identifier is gone from the tree. A guarded arm now lowers to
`pat => if (guard) { body } else { <the remaining arms, one shorter> }`, which Rust's
exhaustiveness rule makes a legal switch on its own (`lowerMatchArms`, `lower.zig:10904`;
`expandGuardedMatchArm`, `lower.zig:10981`); pinned by the four guard tests from
`lower_test.zig:12464`. **Do not desugar guards in the frontend**: it would leave
`MatchArm.guard` dead in the IR and contradict the four other layers that carry it.

**3. A first-pass build failure printed nothing.** `promoteWithHooks` reported the captured
compiler output only on the second pass (`package.zig:920`); the first pass fell out through
`resolveFingerprint` returning null (`package.zig:941`) and reached the user as a bare
`GeneratedPackageBuildFailed` with no message. Every failure path now calls the report hook,
and the hook prints stdout, then stderr, then a named line when neither stream carried anything
(`printBuildFailure`, `package.zig:837`). No error value changed — callers still match
`error.GeneratedPackageBuildFailed`. Pinned by four tests from `package.zig:1889`, including one
that a passing build reports nothing.

This one cost real time, and it is worth more than the fix. A whole class of defect in this
project is *silent*: the translator reports success and emits Zig that does not compile. Probe
cycles went into reconstructing messages that existed and were thrown away. A silent-emission
bug now costs one cycle instead of five.

**4. Smallness is not reachability.** Round 3 fetched 26 of the smallest dependency-free crates
available on the theory that crate size is the cost driver, and every finalist that looked ideal
by size was a deep chain wearing a short first error: `defer` at 60 lines needs `$crate`,
`impl Drop`, `ManuallyDrop` and a struct declared inside a generic fn; `fnvhash` at 87 is built
on `std::collections::hash_state`, an API removed from Rust; `unreachable` at 77 needs an
unresolvable dependency plus four more links; `wrapping` at 82 has zero tests, so a translated
package would be a weak regression test. The full table is in `FIXING-ROUND-3.md`.

**5. The raise SITES are few even though the crates are many.** About twenty sites account for
every rejection across the corpus, and the smallest crate at several of them is under 200 lines.
That is why the size hypothesis was worth testing at all, even though it failed.

The round's target crate, `const-fnv1a-hash` (101 lines), had not landed when this was written —
there is no such fixture under `test/crates/`. The crate metric is therefore still **2 of 112**
unique crates, and nothing above should be read as a crate having cleared.

## Next step

**The backlog below is re-derived from a measurement, not from memory.** Every error was
read off the current tree with `tools/zig-pinned.sh run -- <crate> -o <dir>`. None of
these is a defect; all are capability gaps, and the last is a decision rather than a bug.

1. **Finish `hex`.** It is the only thing keeping `test-e2e` and the gate red, and it is
   the fixture the wip commit already flagged as incomplete. The blocker chain is
   enumerated in the triage section above; the next one is `alloc::string::ToString`
   (measured: deleting hex's two `use alloc::string::ToString;` lines clears it — the
   `pretty_assertions` import this item used to name is already handled), then a `vec![]`
   literal in a `#[test]` entity. Once hex translates, regenerate its goldens and the suite
   goes to 8 failures, all of them the toolchain miscompilation.
2. **The remaining source rejections, with their real first errors.** All six are now
   asserted in `test-crates` and in the e2e executable, so a change in *which* error a
   crate fails with is caught rather than drifting silently:

   | crate | error | reason reported |
   |---|---|---|
   | `siphasher` | `UnresolvedTypePath` | — |
   | `itoa` | `InvalidCast` | — |
   | `seahash` | `InvalidCast` | — |
   | `atoi` | `UnsupportedExpression` | `unresolved call` |
   | `leb128` | `UnsupportedExpression` | `operator requires primitive operands` |
   | `percent-encoding` | `UnsupportedExpression` | `operator requires primitive operands` |

   **Four crates, four independent causes.** An earlier revision of this file claimed the
   two `InvalidCast` failures share one shape, and that the two
   `operator requires primitive operands` failures share another predicate worth fixing
   once to clear two crates. A wide corpus measurement disproved both claims.

   - `seahash` is not `itoa`'s defect repeated. It has an independent `.rev()` gap —
     `src/reference.rs:46` calls `.rev()` on a slice iterator, and the frontend admits
     `.rev()` only over a bare range expression — plus its own cast site. Removing the
     `.rev()` call does not make the crate translate.
   - `leb128` is an inference-defaults defect. An unsuffixed integer literal joins a class
     that stays unconstrained until the Defaults phase, and that phase resolves the default
     type by search rather than interning it, so a crate that never names an integer type
     leaves the class null-typed and the operand check answers false. Measured: one
     unrelated `-> i32` line clears all ten of its markers, and a `-> f64` line clears none.
   - `percent-encoding` is a type-alias defect. Its `type Chunk = u32;` reaches that same
     operand check as a nominal path, and the check counts a type as scalar only when it
     is primitive. Measured: spelling the field `[Chunk; N]` as `[u32; N]` clears all five
     of its markers, and seeding an integer type in the crate clears none.

   Four crates, four fixes: no single predicate clears two of them. `syn` is deliberately
   not pinned — it is ~64k lines of Rust and was not measured. Note that this measurement
   was only possible after the `package.zig` `workspaceCoreAbsolute` fix in **Triage** above;
   before it, the driver failed with `DependencySourceUnavailable` for every crate.
3. **Nested `fn` declared inside a `#[test] fn` is still unsupported.** adler's `bufread` test
   relies on it and is also `cfg(feature = "std")`-gated, so it never surfaced. The missing piece
   is where a nested item lives in the emitted module, not the lowering itself.
4. **Enabling the `alloc` feature for hex.** The plumbing already exists and is not the work.
   `driver.pipeline.translateWithFeatures` takes an explicit `features` list and forwards it
   as `.cfg.features` to `analyzeCrateWithOptions`; the CLI accepts `--features <a,b>` on a
   crate-directory translation, read before the positional path and rejected for wire input,
   which has no feature model (`src/main.zig`). An empty selection is not "no features": it
   means no selection was made, so the manifest's `default` closure applies. So
   `translate-rust --features alloc test/crates/hex -o <dir>` already reaches the gated code.
   What remains is the runtime capability that switch turns on: `.to_string()` and
   `to_owned()` support, plus named-field enum construction on the `alloc`-gated paths. Decide
   first whether `alloc` is in scope, because it changes what the runtime has to offer.

## Working notes

- **Build through `tools/zig-pinned.sh`, never bare `zig build`.** Two host facts break a bare
  invocation, and both fail quietly or misleadingly rather than loudly. First, `zig` on PATH is
  the anyzig shim: it re-resolves and re-downloads the toolchain on *every* invocation, so each
  build pays a full fetch, and in the child `zig build` that package promotion spawns there is
  no `build.zig.zon` to resolve a version from, so the shim exits 1 with no output at all.
  Second, this repository sits on an NFSv3 mount, and Zig's atomic file write uses
  `renameat2(RENAME_EXCHANGE)`, which NFSv3 does not implement — a cache directory on the mount
  dies with EINVAL -> SIGABRT and a "programmer bug caused syscall error" panic. The runner
  resolves a real cached toolchain, points both cache directories at local disk, and puts that
  real binary first on PATH so promoted packages inherit it. It also takes an exclusive
  `flock`, because two `zig build` runs sharing one cache directory corrupt it and abort.
  `zig-out` deliberately stays a **real directory** in the repo, not a symlink into local
  scratch: `std.Io.Dir.createDirPath` rejects a path component that is a symlink, so
  `createDirPath(io, "zig-out")` in the e2e test fails with `NotDir`. The install step only
  copies files rather than writing atomically, so once the caches are local a real directory
  on the mount is fine.
  Note that `$HOME` is itself on the NFS mount here, so the runner probes `/var/tmp`, `/tmp`,
  and `/dev/shm` for a filesystem that actually differs from the repository's instead of
  defaulting to `$HOME/.cache`, which would silently put the caches back on the mount.
  Arguments are identical to `zig build`; `R2Z_ZIG` overrides toolchain discovery and
  `R2Z_SCRATCH` the local scratch root.
- `AGENTS.md` governs workflow: TDD for observable behaviour, `jj` not git, `gate` for correctness.
- `notes/README.md` is an index into a private agent-notes store; the links need the local
  `agent-notes` symlink and do not resolve in a fresh clone.
- Regenerate goldens with the build steps above, not by hand. `generate-mini-wire` rewrites
  `test/mini.json`; `generate-fnv-golden` and `generate-hex-golden` rewrite the RustIr, ZigAST, and
  emitted-source snapshots. `golden_test.zig` itself has no update mode — it prints the exact
  expected bytes on mismatch, so a hand-write is the fallback, not the routine.
- Avoid bulk regex rewrites over `src/`. One over-deleted a function body in `resolve_methods.zig`;
  recovery was `jj restore --from <rev> <file>` and re-applying the edits by hand.
