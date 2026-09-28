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
- The `xxhash-rust` source fixture translates into a validated standalone package.
- The `adler` source fixture translates into a multi-file package and runs all 5 original test vectors (`zeroes`, `ones`, `mixed`, `wiki`, `resume`).
- The `hex` source fixture translates into a three-file package (`src/root.zig`, `src/error.zig`, `src/test.zig`) and runs 5 tests under the generated package's own `zig build test`. Three are upstream `#[cfg(test)]` functions that carry no feature gate (`test_encode_to_slice`, `test_decode_to_slice`, `test_from_hex_array`); the other two are added by the emitter. The remaining upstream tests are `#[cfg(feature = "alloc")]`, and the driver passes no cargo features, so they are not present.

Current rejection coverage is:

- The `fletcher` fixture rejects the external `quickcheck!` macro with `ExternalMacroSourceUnavailable`.
- The `crc16` fixture rejects the generated `tables.rs` include with `BuildScriptArtifactUnavailable`; build scripts are not executed.
- The legacy wire corpus rejects `fnv`, `fletcher`, `hex`, `wyhash`, `adler`, `xxhash-rust`, and `seahash`.
- It also rejects `crc16`, `atoi`, `leb128`, `itoa`, `siphasher`, `percent-encoding`, and `syn`.

Cargo dependencies enter `RustIr` as metadata only. The translator does not translate dependency crates.

Macro expansion, trait resolution, and ownership semantics cover bounded subsets. These paths do not promise general Rust support or complete Rust semantics.
Standalone source trait declarations remain unsupported.

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
zig build
zig build run -- --help

# Translate supported Rust source to a standalone package.
zig build run -- test/crates/mini -o zig-out/r2z-mini

# Emit source from canonical v6 wire JSON.
zig build translate -- test/mini.json

# Regenerate checked-in wire fixtures and source goldens from validated canonical IR.
zig build generate-mini-wire
zig build generate-fnv-golden
zig build generate-hex-golden

# Inspect canonical frontend and backend representations.
zig build run -- --dump rustir test/crates/mini
zig build run -- --dump zigast test/crates/mini

# Inspect legacy sidecar inventory. This command does not translate it.
zig build run -- --dump model test/fnv.json

# Run unit, golden, source, wire, and end-to-end tests.
zig build test

# Run source, wire, AST roundtrip, runtime, and legacy rejection checks.
zig build test-crates

# Run correctness gates; run translation checks only if they pass.
gate

# Rebuild the gate wrapper after devenv configuration changes, then run it.
devenv shell -- gate

jj st
```
