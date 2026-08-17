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

## P4 — dead-lines only (do not start without the pipeline)
- Align emission to `zig fmt` canonical output; port rename/`@"keyword"` from
  step P1's model to the emitter; wire `build.zig` to orchestrate the sidecar
  via `b.addSystemCommand` and link translated modules.

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
