# translate-rust

`translate-rust` is a research translator that turns a supported subset of Rust
into standalone Zig packages. It analyses a crate, lowers it to a canonical IR
and then to Zig, generates a package, and promotes that package only after it
builds and runs its own tests. Anything outside the supported subset is
refused with a typed error.

The subset is bounded, and the boundaries below are measured, not aspirational.
This is not a general Rust implementation and nothing here should be read as a
claim that it translates Rust.

## Requirements

Zig 0.16.0. Every command in this file is a stock `zig build` invocation. Some
steps shell out to `zig`, so the toolchain first on `PATH` must be the real
0.16.0 build.

The first build fetches the pinned dependencies from GitHub unless they are
already cached. Crate translation reads Rust source directly; it does not run
Cargo or rustc.

## Input contract

The input crate is assumed to compile. The contract is valid Rust in, faithful
Zig out. Rust has already checked borrowing, so this translator does not include
a borrow checker. Invalid Rust borrow patterns are outside the input contract;
wrong output for valid Rust is a defect, including output that compiles but
computes the wrong value.

## Pipeline and formats

```text
Rust source -> tree-sitter -> frontend -> canonical RustIr -> ZigAST
            -> staged package validation -> the generated package's own
               `zig build test` -> atomic promotion
```

- Canonical wire format **v6** JSON enters the pipeline at `RustIr`. Every
  other wire version is rejected before a package is created.
- Older sidecar JSON is diagnostic inventory only, printed by `--dump model`.
  It is never accepted as translation input.
- `--dump zigast` emits format version 1. Array and repeat lengths stay native
  JSON numbers across the full target `usize` range, so no length passes
  through a float.

## Current positive end-to-end paths

- The `mini` source fixture produces a validated standalone package.
- The canonical v6 `mini` wire fixture produces a validated standalone package.
- The `fnv` source fixture translates and runs all 203 original assertions.
- The `compat` fixture passes 22 translated tests and 6 Zig consumer tests
  through the source, canonical v6 wire, and serialized Zig AST paths. That
  coverage includes casts, callable types, typed iterator ranges, closure state,
  module references, formatting, `String`/`Cow` ownership, alternative-specific
  enum captures, heterogeneous tuple types, and constant/expression string
  decoding.
- The `wyhash` source fixture translates into a multi-file package and runs all
  9 original assertions across 2 test vectors (`read_rest` and `read64` byte
  sorting).
- The `adler` source fixture translates into a multi-file package and runs all 5
  original test vectors (`zeroes`, `ones`, `mixed`, `wiki`, `resume`).
- The `multimod` source fixture maps each discovered module onto its own emitted
  file (`foo.rs` to `foo.zig`, a nested `foo/bar.rs` to `foo/bar.zig`, and a
  `#[path = "..."]` module to `custom_pub.zig`).
- The `xxhash-rust` source fixture translates into a four-file package
  (`src/root.zig`, `src/utils.zig`, `src/xxh32_common.zig`, `src/xxh32.zig`).
- The `hex` fixture translates with its original `#[cfg(test)]` module, and
  every test in the generated package passes under Zig's leak-checking test
  allocator, so an ownership mistake fails the run. Equality operands keep
  temporary `String`, `Vec`, and owned `Result` payloads alive until the
  comparison finishes, then release them. This is not general Rust `Drop`
  support.
- The untouched default-feature `leb128` source fixture translates with its
  original test module and executes all 19 original tests, 27 including the
  generated reachability checks.
- The untouched default-feature `percent-encoding` source fixture translates
  with `std` and `alloc`. Nine Zig consumer tests exercise the six original
  doctest behaviors, the strict and lossy UTF-8 borrowed and owned branches,
  and high-bit ASCII-set removal. They run under the same leak-checking test
  allocator, so a consumer that keeps or drops the wrong buffer is caught.

Ten repository source fixtures translate end to end: `mini`, `fnv`, `compat`,
`wyhash`, `adler`, `multimod`, `xxhash-rust`, `hex`, `leb128` and
`percent-encoding`, plus the canonical v6 `mini` wire fixture.

Cleanup-only allocator effects propagate through callers. Temporary cleanup
releases known runtime owners, never arbitrary user methods named `deinit`.
Native error tags have an explicit AST literal, distinct from fields on a user
binding named `error`; ordinary enum payloads remain ordinary values.
Borrowed standard IO smoke coverage includes advancing a caller-owned byte-slice
descriptor, reading an owned `Cursor<[u8; N]>`, and appending to a caller-owned
`Vec<u8>` through an explicit allocator. These checks do not imply support for
every `std::io` API.

`Iterator::any` short-circuits while preserving cursor advancement and mutable
predicate effects; indexed and explicitly dereferenced iterator places are
updated in place rather than copied. Optional payload projection preserves the
order of tuple indexing and repeated reference dereferences. Range-loop smoke
coverage includes negative signed bounds, empty descending ranges, inclusive
signed and unsigned maximum endpoints, and labelled break/continue. Contextual
empty primitive and nominal arrays retain their element identities when
assigned as borrowed slices. Nested enum-payload matches preserve tag checks
and guarded-arm fallthrough. These are measured boundaries, not support claims
for every pattern or iterator shape.

An empty `--features` selection applies the manifest's default closure; `hex`'s
`default = ["std"]` pulls in `alloc`, so its allocation paths are analysed.

## Refusals

- The `fletcher` fixture refuses the external `quickcheck!` macro with
  `ExternalMacroSourceUnavailable`.
- The `crc16` fixture refuses the generated `tables.rs` include with
  `BuildScriptArtifactUnavailable`. Build scripts are not executed.
- The legacy wire corpus refuses `fnv`, `fletcher`, `hex`, `wyhash`, `adler`,
  `xxhash-rust`, and `seahash`.
- It also refuses `crc16`, `atoi`, `leb128`, `itoa`, `siphasher`,
  `percent-encoding`, and `syn`.

Four more source fixtures are pinned as refusals, each to its exact typed error,
so a change in *which* error a crate fails with is a test failure rather than
silent drift:

| fixture | error | reason |
|---|---|---|
| `siphasher` | `UnresolvedTypePath` | IR validation cannot resolve a nominal type path |
| `itoa` | `UnsupportedExpression` | `unresolved call` |
| `seahash` | `UnsupportedExpression` | `operator requires primitive operands` |
| `atoi` | `UnsupportedType` | unresolved tuple element type |

These are capability gaps, not defects, and the translator does not pretend
otherwise: it refuses rather than emitting wrong Zig. `syn` is deliberately not
pinned, because it is far too large to have been measured.

Cargo dependencies enter `RustIr` as metadata only. The translator does not
translate dependency crates. Macro expansion, trait resolution, and ownership
semantics cover bounded subsets; standalone source trait declarations remain
unsupported. Nothing here promises general Rust support or complete Rust
semantics.

## What these paths do not show

The list above is a list of fixtures, not a coverage rate. Read "translates" as
"this fixture translates", never as "this shape of Rust translates". Wider
sweeps over dependency-free crates have translated only a small handful of
them; the rest stop at a typed error. Part of that gap is the translator's, and
part of it is that the corpus is not in this repository.

Some fixtures were also fitted to what already works. The coverage is real —
`wyhash`, `adler` and `fnv` really do execute their translated tests — but three
of the fixtures were adjusted rather than taken as shipped:

- `wyhash` has its only `for i in 0..data.len()` range loop **commented out**,
  at `test/crates/wyhash/src/functions.rs:43`. That simplification predates
  the fixture batch. The fixture therefore covers only `read_rest` and `read64`,
  not its range loop; range-loop support is exercised by other fixtures.
- `adler`'s vendored source is byte-identical to upstream, but its fixture
  manifest sets `default = []` where upstream ships `default = ["std"]`. It
  translates because the fixture empties the default feature closure, so its
  `std`-gated code is never analysed.
- `xxhash-rust` is a vendored v1-dialect copy whose manifest sets
  `default = ["xxh32"]`. The upstream 0.8.19 crate declares no `default`
  feature at all, so cfg evaluation drops every module and that crate reduces
  to an empty root. It is not pinned as a rejection, because in this tree it
  translates.

## Commands

```bash
# Build the CLI into zig-out/bin/translate-rust.
zig build
zig build run -- --help

# Unit tests, one artifact per module, plus the dead-source guard.
zig build test
zig build check-sources   # fail when a src/**/*.zig file reaches no test root
zig build test-frontend
zig build test-backend
zig build test-frontend -Dfrontend-llvm=true   # LLVM instead of the self-hosted backend

# Translate supported Rust source to a standalone package.
zig build run -- test/crates/mini -o zig-out/r2z-mini

# Emit Zig source from canonical v6 wire JSON.
zig build translate -- test/mini.json

# Inspect the canonical frontend and backend representations.
zig build run -- --dump rustir test/crates/mini
zig build run -- --dump zigast test/crates/mini
zig build run -- --dump-types test/crates/mini
zig build run -- --dump-names test/crates/mini
zig build run -- --dump-infer test/crates/mini

# Inspect legacy sidecar inventory. This does not translate it.
zig build run -- --dump model test/fnv.json

# Translate a fixture and check that staged promotion publishes the package.
zig build source

# End-to-end: translate the fixtures, build each generated package, run the
# translated and consumer tests, and check the pinned refusals.
zig build test-e2e
zig build test-crates

# Regenerate the checked-in wire fixture and source goldens from validated
# canonical IR. Run these only when the emitted Zig is meant to change.
zig build generate-mini-wire
zig build generate-mini-golden
zig build generate-fnv-golden
zig build generate-compat-golden
zig build generate-wyhash-golden
zig build generate-adler-golden
zig build generate-multimod-golden
zig build generate-hex-golden

# Generated API reference.
zig build docs
```

`zig build test` covers the unit suites; `zig build test-e2e` and
`zig build test-crates` are the checks that translate, build, execute, and
refuse. `test-crates` also runs the `r2z-core` runtime package's own test
suite. Neither step asserts test counts; they assert exit status, the generated
package layout, and the exact typed error of every pinned refusal.

## Repository layout

```text
build.zig          # build graph for the CLI, tests, fixtures, and corpus checks
build.zig.zon      # package manifest and pinned dependencies
src/
├── main.zig       # CLI and diagnostic dump modes
├── ir/            # canonical target-independent RustIr and v6 JSON boundary
├── frontend/      # tree-sitter ingestion and Rust analysis
├── backend/zig/   # ZigAST lowering, source emission, and package generation
├── driver/        # source and wire orchestration with staged promotion
└── model/         # legacy sidecar diagnostic inventory
r2z-core/          # generated-package runtime compatibility layer
test/              # fixtures, snapshots, integration tests, and rejection corpus
vendor/            # vendored tree-sitter-rust grammar
```

## Working on this tree

Two maintenance constraints that are easy to get wrong:

- **Keep `(void)` in the vendored scanner.**
  `vendor/tree-sitter-rust/scanner.c` is hand-written;
  `vendor/tree-sitter-rust/parser.c` and `tree_sitter/parser.h` are generated
  and declare `tree_sitter_rust_external_scanner_create` with a `(void)`
  parameter list. Writing it as a legacy empty list `()` still compiles, but it
  is a different C function type, and optimized builds trap inside it on
  clang's `-fsanitize=function` mismatch trap. Change the generated files only
  through the grammar's own generator.
- **Hand-built graph fixtures own their segments.**
  `Graph.deinit` frees the path array *and* every segment in it. A fixture that
  duplicates only the outer array leaves freed literals behind, which read back
  as `0xAA` in Debug and produce failures that look like codegen bugs but are
  use-after-free. Duplicate each segment and the local name, with `errdefer`
  cleanup; `addExternalUseTestAlias` in `src/frontend/ts_ext.zig` is the
  reference. The same class of mistake applies to a type table that inference
  resolves in place: the store has to be a `var`, not a `const`, because
  resolution writes through it (see the `chained raw pointer cast resolves a
  wildcard pointee` test in `src/frontend/infer_test.zig`).

Golden files under `test/golden/` are the emitted Zig, and they are regenerated
from validated canonical IR rather than edited by hand. Change the translator,
regenerate, and read the diff.
