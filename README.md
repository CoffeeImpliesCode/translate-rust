# translate-rust

`translate-rust` explores a `translate-c`-style Rust-to-Zig tool. It translates a supported Rust subset into standalone Zig packages.

## Status

This repository contains a research implementation with a live in-process source pipeline:

```text
Rust source -> tree-sitter -> frontend -> canonical RustIr -> ZigAST
            -> staged package validation -> zig build test -> atomic promotion
```

Canonical wire format v6 JSON enters the same pipeline at `RustIr`. The translator rejects all other wire versions before package creation.

Older sidecar JSON is diagnostic inventory for `--dump model`. It is not accepted translation input.

Current positive end-to-end paths are:

- The `mini` source fixture produces a validated standalone package.
- The canonical v6 `mini` wire fixture produces a validated standalone package.
- The `fnv` source fixture translates and runs all 203 original assertions.
- The `compat` fixture passes 10 translated tests and 5 Zig consumer tests through source, canonical v6 wire, and serialized Zig AST paths. Coverage includes casts, callable types, typed iterator ranges, closure state, module references, formatting, and `String`/`Cow` ownership.
- The `wyhash` source fixture translates into a multi-file package and runs all 9 original assertions across 2 test vectors (`read_rest` and `read64` byte sorting).
- The `adler` source fixture translates into a multi-file package and runs all 5 original test vectors (`zeroes`, `ones`, `mixed`, `wiki`, `resume`).
- The `multimod` source fixture maps each discovered module onto its own emitted file (`foo.rs` to `foo.zig`, a nested `foo/bar.rs` to `foo/bar.zig`, and a `#[path = "..."]` module to `custom_pub.zig`).
- The `xxhash-rust` source fixture translates into a four-file package (`src/root.zig`, `src/utils.zig`, `src/xxh32_common.zig`, `src/xxh32.zig`). It was pinned as rejecting with `EmptyRootFile`; that pin was stale for this tree.

Current rejection coverage is:

- The `fletcher` fixture rejects the external `quickcheck!` macro with `ExternalMacroSourceUnavailable`.
- The `crc16` fixture rejects the generated `tables.rs` include with `BuildScriptArtifactUnavailable`; build scripts are not executed.
- The `hex` source fixture does not translate yet. It fails IR validation with `UnsupportedExpression`; the frontend cannot name a trait method's result type from its signature combined with a call-site turbofish. Note the feature model: an empty `--features` selection applies the manifest's `default` closure, and hex's `default = ["std"]` pulls in `alloc` transitively, so its `alloc`-gated code *is* analysed. `hex` goldens cannot be regenerated until this is fixed.
- The legacy wire corpus rejects `fnv`, `fletcher`, `hex`, `wyhash`, `adler`, `xxhash-rust`, and `seahash`.
- It also rejects `crc16`, `atoi`, `leb128`, `itoa`, `siphasher`, `percent-encoding`, and `syn`.

Six more source fixtures are pinned as rejections, each to its exact typed error, so a
change in *which* error a crate fails with is a test failure rather than silent drift:

| fixture | error | reason |
|---|---|---|
| `siphasher` | `UnresolvedTypePath` | IR validation cannot resolve a nominal type path |
| `itoa` | `InvalidCast` | inference rejects a cast whose operand has no known type |
| `seahash` | `InvalidCast` | inference rejects a cast; independently, the `.rev()` at `src/reference.rs:46` is admitted only over a bare range expression |
| `atoi` | `UnsupportedExpression` | `unresolved call` |
| `leb128` | `UnsupportedExpression` | `operator requires primitive operands` — an unconstrained integer class keeps a null type because the Defaults phase resolves the default type by search instead of interning it |
| `percent-encoding` | `UnsupportedExpression` | `operator requires primitive operands` — a type alias arrives as a nominal path, and only a primitive type counts as a scalar operand |

The `seahash` and `percent-encoding` rows are not repeats of the rows above them. A wide
corpus measurement proved four independent causes where this table previously claimed two
shared ones: `seahash` carries an independent `.rev()` gap as well as its own cast site, and
`leb128` and `percent-encoding` reach the same reason string by different routes. See the
next section and `FIXING-ROUND.md`.

These are capability gaps, not defects. `syn` is deliberately not pinned: it is far too
large to have been measured.

Cargo dependencies enter `RustIr` as metadata only. The translator does not translate dependency crates.

Macro expansion, trait resolution, and ownership semantics cover bounded subsets. These paths do not promise general Rust support or complete Rust semantics.
Standalone source trait declarations remain unsupported.

## Measured coverage, and what the fixtures do not show

The positive list above is a list of fixtures, not a coverage rate. A measurement pass ran
the translator over a corpus of dependency-free crates and recorded the exact first typed
error for each, twice: once on the default feature closure (57 crates) and once library-only
(55).

- **2 of 57 crates translate at all** on the default pass — `fnv` and `utf8-width`. On the
  library-only pass 1 of 55 does: `utf8-width`. Every other crate stops at a typed error.
  The commonest are `UnsupportedConstInitializer` and `UnsupportedCfgPredicate` at 10 each,
  then the manifest-group errors at 8 in total, `InvalidType` and `InvalidCast` at 5 each,
  and `UnresolvedTypePath` at 4.
- **The rejection count flatters the translator.** Eight of those rejections are
  `CargoManifest*` errors, raised before analysis ever runs, and clearing all eight buys no
  capability: each crate then fails with a different error instead.
- **The repository's own fixtures were partly fitted to what already works.** The coverage
  is real — `wyhash`, `adler` and `fnv` really do execute their translated tests — but three
  of the fixtures were adjusted rather than taken as shipped:
  - `wyhash` has its only `for i in a..b` range loop **commented out**, so the fixture
    exercises no range loop, a construct the translator does not model.
  - `adler`'s vendored source is byte-identical to upstream, but its fixture manifest sets
    `default = []` where upstream ships `default = ["std"]`. It translates because the
    fixture empties the default feature closure, so its `std`-gated code is never analysed.
  - `xxhash-rust` is a vendored v1-dialect copy whose manifest sets `default = ["xxh32"]`.
    The upstream 0.8.19 crate the corpus measured declares no `default` feature at all, so
    cfg evaluation drops every module and that crate still reduces to an empty root.

Read "translates" as "this fixture translates", never as "this shape of Rust translates".
`FIXING-ROUND.md` carries the full measurement and the ranked fix list it produced.

## Modules

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
notes/README.md    # navigation index for private research and archived plans
```

The project uses Zig 0.16, devenv with direnv, and Jujutsu for version control. Use the [notes index](notes/README.md) to locate project records.

## Commands

```bash
direnv allow

# `tools/zig-pinned.sh` takes the same arguments as `zig build`. Use it
# instead of a bare `zig build`: on this host the bare form re-downloads the
# toolchain per invocation and dies on the NFS mount. See AGENTS.md.
tools/zig-pinned.sh
tools/zig-pinned.sh run -- --help

# Translate supported Rust source to a standalone package.
tools/zig-pinned.sh run -- test/crates/mini -o zig-out/r2z-mini

# Emit source from canonical v6 wire JSON.
tools/zig-pinned.sh translate -- test/mini.json

# Regenerate checked-in wire fixtures and source goldens from validated canonical IR.
tools/zig-pinned.sh generate-mini-wire
tools/zig-pinned.sh generate-mini-golden
tools/zig-pinned.sh generate-fnv-golden
tools/zig-pinned.sh generate-compat-golden
tools/zig-pinned.sh generate-wyhash-golden
tools/zig-pinned.sh generate-adler-golden
tools/zig-pinned.sh generate-multimod-golden
tools/zig-pinned.sh generate-hex-golden

# Inspect canonical frontend and backend representations.
tools/zig-pinned.sh run -- --dump rustir test/crates/mini
tools/zig-pinned.sh run -- --dump zigast test/crates/mini

# Inspect legacy sidecar inventory. This command does not translate it.
tools/zig-pinned.sh run -- --dump model test/fnv.json

# Run unit, golden, source, wire, and end-to-end tests.
tools/zig-pinned.sh test

# Run source, wire, AST roundtrip, runtime, and legacy rejection checks.
tools/zig-pinned.sh test-crates

# Run correctness gates; run translation checks only if they pass.
gate

# Rebuild the gate wrapper after devenv configuration changes, then run it.
devenv shell -- gate

jj st
```
