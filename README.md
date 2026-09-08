# translate-rust

`translate-rust` explores a `translate-c`-style Rust-to-Zig tool. It translates a supported Rust subset into standalone Zig packages.

## Status

This repository contains a research implementation with a live in-process source pipeline:

```text
Rust source -> tree-sitter -> frontend -> canonical RustIr -> ZigAST
            -> staged package validation -> zig build test -> atomic promotion
```

Canonical wire format v5 JSON enters the same pipeline at `RustIr`. The translator rejects all other wire versions before package creation.

Older sidecar JSON is diagnostic inventory for `--dump model`. It is not accepted translation input.

Current positive end-to-end paths are:

- The `mini` source fixture produces a validated standalone package.
- The canonical v5 `mini` wire fixture produces a validated standalone package.
- The `fnv` source fixture translates and runs all 203 original assertions.

Current rejection coverage is:

- The `fletcher` fixture rejects the external `quickcheck!` macro with `ExternalMacroSourceUnavailable`.
- The `crc16` fixture rejects the generated `tables.rs` include with `BuildScriptArtifactUnavailable`; build scripts are not executed.
- The legacy wire corpus rejects `fnv`, `fletcher`, `hex`, `wyhash`, `adler`, `xxhash-rust`, and `seahash`.
- It also rejects `crc16`, `atoi`, `leb128`, `itoa`, `siphasher`, `percent-encoding`, and `syn`.

Cargo dependencies enter `RustIr` as metadata only. The translator does not translate dependency crates.

Macro expansion, trait resolution, and ownership semantics cover bounded subsets. These paths do not promise general Rust support or complete Rust semantics.

## Modules

```text
build.zig          # build graph for the CLI, tests, fixtures, and corpus checks
build.zig.zon      # package manifest and pinned dependencies
src/
├── main.zig       # CLI and diagnostic dump modes
├── ir/            # canonical target-independent RustIr and v5 JSON boundary
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

# Emit source from canonical v5 wire JSON.
zig build translate -- test/mini.json

# Inspect canonical frontend and backend representations.
zig build run -- --dump rustir test/crates/mini
zig build run -- --dump zigast test/crates/mini

# Inspect legacy sidecar inventory. This command does not translate it.
zig build run -- --dump model test/fnv.json

# Run unit, golden, source, wire, and end-to-end tests.
zig build test

# Run mini wire translation, source E2E, runtime tests, and all legacy rejects.
zig build test-crates

# Run correctness gates; run translation checks only if they pass.
gate

# Rebuild the gate wrapper after devenv configuration changes, then run it.
devenv shell -- gate

jj st
```
