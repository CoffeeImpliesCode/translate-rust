# Implementation plan — the crate data model (IR)

Sequenced build-out of the Rust-crate IR defined in `data-model.md`, mapped to
the v0/v1 roadmap in `research/approaches.md` §6. Every step must end green
(`zig fmt --check`, `zig build`, `zig build test`).

## P0 — design (this phase, done)
- Docs: `data-model.md` (unified) + `data-model/{crate-graph,items-types,exprs-patterns,ownership-mem}.md`.
- Front-end already wired: `src/rust.zig` parses Rust → tree-sitter syntax tree.

## P1 — IR core: shared spine + crate graph + JSON boundary (approaches v0)
Goal: parse a sidecar-produced JSON crate dump into the model and walk it.
- Add a `src/model/` module tree matching the four axes (house convention:
  dotted modules, e.g. `translate_rust.model`, `translate_rust.model.graph`).
- `src/model/spine.zig`: `Span`, `EntityId`, `TypeId`, `EntityKind`, `Entity`,
  `SymbolTable`, `Visibility`, `Attribute`, `Unsupported`.
- `src/model/graph.zig`: `CrateGraph`, `Crate`, `Module`, `UseDecl`,
  `ExternCrate`, `Path`.
- `src/model/json.zig`: std.json deserializer from the sidecar wire format
  (tagged unions, `format_version` header; reserved-word tag renames).
- Sidecar producer (v0): `cargo +nightly rustdoc -- --output-format json
  --document-private-items` → one `crate-<name>.json`.
- Fixture: a tiny hand-written `no_std` crate (struct + fn + enum) checked in
  under `src/fixtures/`; its pre-generated JSON becomes a golden fixture.
- Tests: parse the golden JSON, walk modules/visibility, resolve a `pub use`
  path; assert `format_version` honored, unknown attr preserved.
- Acceptance: `translate-rust --dump model <crate.json>` prints the crate/module
  inventory; model tests green.

## P2 — items + types + generics (approaches v1, part 1)
Goal: represent every v1 item/type and feed a first emitter slice.
- `src/model/items.zig`: `Item` tagged union + associated items + `impl`.
- `src/model/types.zig`: `Type` tagged union incl. dedicated
  `option`/`result`/`boxed` nodes; `GenericParam` + `Instantiation` records.
- Emitter stub `src/emit/items.zig`: struct → `struct`/`extern struct`,
  enum → `enum(uN)`/`union(enum)`, fn signature → explicit receiver params,
  generics → comptime params. (Full expr lowering is P3.)
- **Target crate: `fnv`** (CrateScout pick: zero deps, `#![no_std]`, no_alloc,
  zero macros, ~130 LOC, 50.7M dl/mo, 55k dependents). Its single
  `const fn fnv_hash(&[u8]) -> u64` is a perfect first body.
- Tests: translate `fnv`'s hash fn + its own test vectors; assert the Zig
  `fnvHash([]const u8) u64` equals the crate's FNV-1a vectors (differential
  oracle).
- Acceptance: `translate-rust --translate <path-to-fnv> > fnv.zig`; generated
  file compiles; hash matches vectors.

## P3 — expressions/patterns + ownership (approaches v1, part 2)
Goal: translate function bodies for the v1 dialect.
- `src/model/exprs.zig` (Expr/Statement/Pattern, overflow modes) +
  `src/model/ownership.zig` (`Ownership`, `ParamShape`, `DropInfo`,
  `AllocatorUse`, `UnsoundMarker`).
- Emitter `src/emit/`: block/if/match→switch/if, calls, field/index, ops with
  overflow lowering, `try_`→`try`, `let`→const/var, `defer` Drop emission.
- Widen corpus after `fnv`: `hex` (no_std, no_alloc, no macros, only-optional
  serde dep) then `itoa` (flag: 3 macro_rules!, unsafe — validate the
  macro/unsafe seams).
- Tests: per-example golden `.zig` files (rust2zig `test.sh` discipline) plus
  `zig test` on each translation; compare against the crate's own behavior.
- Acceptance: fnv + hex + itoa hash/encode/decode bodies translate and pass
  their own vectors in `zig test`.

## Naming convention — `r2z-<cratename>` (translation PACKAGE target)

Established 2026-08-17, corrected same day. A translated crate `foo` is emitted as a
**Zig package named `r2z-foo`** — a directory, NOT a single file. A single `r2z-foo.zig`
file only works for a leaf crate; it breaks on modules and deps:

- **Modules** (idiom-mapping §1): Rust `mod foo;` → `@import("foo.zig")` — each module is
  its own Zig file. A crate's translation is a `src/` tree mirroring the Rust mod graph,
  not one flat file.
- **Deps**: a dependency must be a *package* with a manifest. For crate A to
  `@import("r2z-B")`, B must be a Zig package A's build graph fetches.

**Correct target shape** — each translated crate is a generated package dir:

```
r2z-<crate>/
  build.zig        # generated: declares the crate module(s) + test step
  build.zig.zon    # generated: package manifest
  src/
    root.zig       # crate root (the r2z-<crate>.zig output becomes this)
    util.zig       # mod util → own file
    ...
```

**Dependency translation**: A depends on B → A's `build.zig.zon` lists `.@"r2z-B"` as a
dependency; A's `build.zig` does `b.dependency("r2z-B", .{})` + exposes it as a module;
A's translated code `@import("r2z-B")`. This mirrors c2rust's `--emit-build-files`
(per-crate build skeleton, prior-work §3) — the P4 "link translated modules" bullet.

**Current state / gap**: the emitter today emits a single flat file (module banner comments
instead of a file tree) and no build.zig/.zon. The `test/r2z-*.zig` goldens are valid as
*expected source content* for a single module, but the real output must become a package
dir (multi-file per module + generated build.zig + build.zig.zon) before deps work.

**Test corpus layout** (top-level `test/`):

```
test/
  crates/{mini,fnv,hex}/   # checked-in real Rust crate sources (no_std, zero required deps)
  mini.json, fnv.json, mini-rustdoc.json   # wire-format models (inputs)
  r2z-fnv.zig, r2z-hex.zig   # golden translated outputs (r2z-<cratename>.zig)
```

The crates are vendored from crates.io: `fnv` 1.0.7 (servo/rust-fnv), `hex` 0.4.3 (KokaKiwi/rust-hex, v1 core = lib.rs+error.rs, serde feature trimmed). All compile `--no-default-features` (no_std). `mini` was moved from `src/fixtures/model/`.

## Integration testing — crate `#[test]` blocks as Zig `test` blocks

The primary integration-testing strategy (rust2zig's `test_test.sh` differential
discipline, prior-work §4): a translated crate carries its own test suite.

- **Convention**: a crate's `#[cfg(test)]` `#[test]` fns translate to Zig `test`
  blocks appended to the translated output (`test/r2z-<crate>.zig`). `zig test` on
  the translated crate runs the crate's own behavior verification — a green run =
  the translation is behaviorally correct against the authoritative vectors.
- **Wired**: `zig build test-crates` runs `zig test` on every `test/r2z-*.zig`.
- **fnv (done)**: the real `basic_tests` (~180 authoritative FNV-1a vectors +
  repeat_10/500 cases) translated to Zig `test "basic_tests"`. `fnv1a_hash` matches
  the crate's FnvHasher output, so the vectors are the differential oracle.
- **hex (deferred)**: its real tests exercise `encode_to_slice`/`decode_to_slice`/
  `FromHexError`/`vec`/`alloc`/`pretty_assertions` — beyond the v1 dialect (errors,
  alloc, arrays, unwrap). The reduced `r2z-hex.zig` (slice `encode` only) has no such
  API. Wireable once the emitter handles errors/alloc/arrays.
- **mini (deferred)**: no `#[test]` in the crate; its translation (structs/enums)
  is unimplemented, so no `r2z-mini.zig` target yet.

**Emitter gap**: the emitter does not yet emit `test` blocks (no test-module capture
in the wire model, no `assert_eq!`/`assert!` macro lowering). The golden test blocks
are hand-translated expected output; the model+emitter path for tests is a follow-up.

## Corpus expansion — scouting more v1-dialect test crates

Three parallel scouts (hashing/checksum, encoding, parsing/formatting) surveyed the
crates.io ecosystem for more fnv-like targets. Honest finding: **no crate besides fnv
is a pure free-fn v1 target** — every candidate wraps its compute in a streaming
Hasher/struct with generics/methods, or uses macros/alloc/errors the emitter can't
lower yet.

- **fletcher** (chosen): `calc_fletcher16(&[u8]) -> u16`, no_std, zero deps, no macros,
  578 LOC, real `#[test]` vectors. The algorithm (chunked `a+=el; b+=a`, one's-complement
  `reduce`, `a | b<<8`) is lowered to a free fn in `test/r2z-fletcher.zig`, with the
  crate's real vectors as the differential oracle.
- Honest rejects: adler/wyhash (SIMD/struct core), seahash/xxhash (unsafe/macros),
  base64/percent-encoding/data-encoding (struct+Iterator+alloc), leb128 (std::io),
  itoa (sealed trait+macros), strsim/unicase (alloc). All are hex-like (partial) at best.

## P4 — full integration (PIPELINE LIVE, 100% complete)
Pipeline now runs end-to-end in-memory (fnv + hex bodies) and via the build:
- ✅ `zig build sidecar` — drives `tools/sidecar/rustdoc-json.sh` (cargo +nightly rustdoc) on the mini fixture → `zig-out/crate-mini.json`.
- ✅ `zig build translate -- <wire-json>` — runs the CLI `--translate` on a wire-format dump.
- ✅ Second v1-dialect corpus: `hex.zig` + `emit_hex_test.zig` golden (30/30 tests).
- ✅ Align emission to `zig fmt` canonical output — in-process `std.zig.Ast` parsing and rendering (`formatZig`) runs on emitted source; produces canonical formatting with zero external processes.
- ✅ Port rename/`@"keyword"` from the model to the emitter — `std.zig.fmtId` escaping across functions, types, constants, variables, and path segments + `entity.renamed_to` honored.
- ✅ Wire format v2 (JSON carries bodies) — `json.parseFull`/`encodeFull` decode/encode bodies; `test/fnv.json` is v2; the CLI `--translate` and positional invocation now read v2 and emit full bodies via `parseFull` → `emitRich` (previously stub-only). Bodies/`BodyKind`/`ConstBody`/`FnBody` unified into a leaf `src/model/bodies.zig` (emit.Bodies == json.Bodies; breaks the json↔emit import cycle).
- ✅ Local-binding resolution — `test/fnv.json` includes param/local entities (`data`, `h`, `byte`) so `PathExpr.def` resolves cleanly to entity names; no `/* unknown path */`.
- ✅ CLI teardown — `translateCrate` uses `ArenaAllocator` over `init.gpa`; zero leaks on process exit.
- ✅ Link translated modules into `build.zig` as real compiled artifacts — `r2z-fnv` and `r2z-fletcher` exported as modules; `r2z-fnv` installed as `zig-out/lib/libr2z-fnv.a` static library.

## Verification strategy (throughout)
- rust2zig-style: golden outputs (`test.sh`) + differential `zig test` against
  each target crate's own test vectors.
- `@embedFile`-based fixtures (downward paths only — `../` embeds are rejected
  by the build, established in the tree-sitter wiring).
- Model tests exercise losslessness: JSON → model → JSON round-trips equal
  (std.json property).

## Dependencies between steps
P1 (model+JSON boundary) is the **contract**; P2/P3 (items/types, exprs/
ownership) consume its `EntityId`/`SymbolTable` spine. P4 needs everything.
Front-end (source ↔ model) and model ↔ emitter are the two seams.
