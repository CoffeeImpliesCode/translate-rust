# Handoff — translate-rust

Written 2026-09-29. **The work described below is uncommitted.** `jj st` shows a large
working-copy diff on top of `2692a1c docs: record the hex library boundary and refresh the mini
wire`. The revision id moves with every amend — trust the description, not the hash.

## What this project is

Zig 0.16 research project translating a Rust subset into standalone Zig packages.
Pipeline: `Rust source -> tree-sitter -> frontend -> RustIr -> ZigAST -> staged package validation -> zig build test -> atomic promotion`.

Canonical wire format is **v6**; every other version is rejected at the driver boundary.
Older sidecar JSON is diagnostic inventory for `--dump model` only, never translation input.

## Verified state

| Check | Result |
|---|---|
| `gate` (devenv shell) | PASSED (fmt, build, test, ast-check, ziglint, zlint) |
| `zig build test` | 695/695, 28/28 build steps |
| `zig build test-e2e` | PASSED |
| `zig build test-crates` | PASSED (also runs the `r2z-core` suite) |

The e2e run ends with:
`e2e: mini/fnv/wyhash/xxhash-rust/adler/compat/hex translated; fletcher/crc16 macro rejects; fnv/fletcher wire rejected`

`zbc` reports 31 ADVISORY findings, as it always does here, and is advisory per `AGENTS.md`.
The long-standing ones are struct literals built with `Lowerer.alloc`, which is the driver arena
and unwinds on error. Do not "fix" them. The only thing worth doing there is a doc comment on
`lowerRustIr` recording that it requires an arena.

`zig build run -- test/crates/hex -o <dir>` succeeds, emitting `src/root.zig`, `src/error.zig`,
`src/test.zig`. The generated package's own `zig build test` reports 3/3 steps, 5/5 tests.

### Coverage

Translate end to end: `mini`, `fnv`, `compat`, `wyhash`, `xxhash-rust`, `adler`, `hex`.

`wyhash` (2 vectors / 9 assertions), `adler` (5 vectors), `fnv` (203 assertions) all execute their
translated tests under the generated package's own `zig build test`.

`multimod` is source-analysis coverage only: `src/frontend/pipeline.zig` asserts its module tree
(`mod foo;`, two-level `mod bar;` inside `foo.rs`, and `#[path = "..."]` resolution). It is not in
the end-to-end matrix.

Reject by macro source: `fletcher` (`ExternalMacroSourceUnavailable`), `crc16`
(`BuildScriptArtifactUnavailable`). Reject by wire: the legacy `fnv.json` and `fletcher.json`
fixtures, plus every non-v6 sidecar in `test/`.

`hex` is now a full fixture, but only 3 of its upstream `#[test]` functions run. The driver passes
no cargo features, and the rest of the crate's tests are `#[cfg(feature = "alloc")]`-gated.

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

`golden_test.zig` covers `mini`, `fnv`, and `hex` as translation fixtures and compares byte for
byte, printing the actual payload on mismatch. There is **no** auto-update mode, so a fixture with
no generator is hand-updated from the dumped output.

Regenerators that do exist: `zig build generate-mini-wire`, `zig build generate-fnv-golden`,
`zig build generate-hex-golden`.

## Recent work (this session, uncommitted)

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

## Next step

**Three real candidates, in the order I would take them.** None is a defect; all three are capability
gaps, and the third is a decision rather than a bug.

1. **The remaining rejections in the corpus.** `siphasher` still fails `UnresolvedTypePath`;
   `itoa` fails `InvalidCast`; `atoi` and `leb128` fail `UnsupportedExpression`. These are the
   remaining rejection entries besides `fletcher`, `crc16`, and the legacy wire set. Re-run the
   driver on one crate, read the first error, and decide whether the fix belongs in the frontend's
   type resolution or in the lowerer before writing code.
2. **Nested `fn` declared inside a `#[test] fn` is still unsupported.** adler's `bufread` test
   relies on it and is also `cfg(feature = "std")`-gated, so it never surfaced. The missing piece
   is where a nested item lives in the emitted module, not the lowering itself.
3. **Enabling the `alloc` feature for hex.** That would exercise far more of the crate and would
   immediately need named-field enum construction on the `alloc`-gated paths plus `.to_string()`
   and `to_owned()` support. The frontend already takes a `features` list
   (`analyzeCrateWithOptions` with `.{ .cfg = .{ .features = ... } }`); the driver calls the
   no-options `analyzeCrate`, so the plumbing is the small half. Decide first whether `alloc` is in
   scope, because it changes what the runtime has to offer.

## Working notes

- `AGENTS.md` governs workflow: TDD for observable behaviour, `jj` not git, `gate` for correctness.
- `notes/README.md` is an index into a private agent-notes store; the links need the local
  `agent-notes` symlink and do not resolve in a fresh clone.
- Regenerate goldens with the build steps above, not by hand. `generate-mini-wire` rewrites
  `test/mini.json`; `generate-fnv-golden` and `generate-hex-golden` rewrite the RustIr, ZigAST, and
  emitted-source snapshots. `golden_test.zig` itself has no update mode — it prints the exact
  expected bytes on mismatch, so a hand-write is the fallback, not the routine.
- Avoid bulk regex rewrites over `src/`. One over-deleted a function body in `resolve_methods.zig`;
  recovery was `jj restore --from <rev> <file>` and re-applying the edits by hand.
