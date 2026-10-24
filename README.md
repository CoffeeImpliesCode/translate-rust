# translate-rust

Experimental Rust-to-Zig translator. It reads a crate, builds a canonical Rust IR,
lowers it to a Zig AST, and emits a standalone package. Package promotion builds
and runs the generated package's tests before publishing it.

## Requirements

- Zig 0.16.0 and a C-compatible libc target.
- Network access for the pinned tree-sitter and serde dependencies.
- A POSIX shell for integration checks. Rust and Cargo are needed for native
  differential tests and the Rust corpus oracle, not for source translation.
- Local storage with atomic file operations for test scratch and compiler caches.

The Zig 0.17.0 migration is blocked by tree-sitter's upstream build script:
`findSourceFiles` uses the removed `std.Build.build_root` field. The pinned
revision and upstream `master` both contain that call. The manifests retain the
current compiler requirement until a compatible dependency is available.

## Build and test

```sh
zig build
zig build test
zig build test-crates
zig build docs
```

`test` runs module tests and source/command/corpus consistency checks.
`test-crates` translates fixtures, checks generated packages and consumers, runs
runtime tests, and checks pinned refusals. Some checks require `rustc` on `PATH`;
`-Drustc=/absolute/path/to/rustc` selects it explicitly.

## Use

```sh
zig build run -- --help
zig build run -- test/crates/mini -o zig-out/r2z-mini
zig build run -- --features xxh32 test/crates/xxhash-rust -o zig-out/r2z-xxhash
zig build run -- --dump rustir test/crates/mini
zig build run -- --dump zigast test/crates/mini
zig build translate -- test/mini.json
```

Use a fresh output directory. Generated packages register a module with the
crate's name:

```zig
const library = b.dependency("crate_name", .{
    .target = target,
    .optimize = optimize,
}).module("crate_name");
consumer.root_module.addImport("crate_name", library);
```

Packages that need the runtime ship `r2z-core/`. Its sources are embedded in the
translator. Consumer builds do not need the translator's checkout. Generated
function documentation describes allocator parameters and ownership transfers.
Copies do not create independent owners. Returned pointers, slices and erased
interfaces borrow their backing storage.

## Input and support boundaries

Input must be valid Rust. The translator does not implement a borrow checker.
Unsupported constructs return typed errors. Cargo dependencies enter the IR as
metadata; dependency crates and build scripts are not executed or translated.
Macro expansion, trait resolution and ownership cleanup support bounded subsets.
General Rust `Drop` semantics are not implemented.

Canonical translation input uses version 6 RustIR JSON. Older sidecar JSON is
available only through `--dump model`. `--dump zigast` uses format version 1.
Frontend IR and decoded Zig AST packages use caller-owned arenas, which must
outlive their results.

Fixtures exercise translation paths, not a Rust language coverage percentage.
The `Cargo.toml.orig` files are upstream fixture manifests and remain with their
crate snapshots. Fixture provenance is recorded in each crate's `Cargo.toml`.

## Layout

- `src/frontend/`: tree-sitter ingestion and Rust analysis.
- `src/ir/`: canonical RustIR and its JSON boundary.
- `src/backend/zig/`: Zig AST, lowering, emission and package generation.
- `src/driver/`: source/wire orchestration and staged promotion.
- `src/model/`: legacy sidecar diagnostic inventory.
- `r2z-core/`: generated-package runtime support.
- `test/`: source fixtures, goldens, consumers and refusal cases.
- `vendor/tree-sitter-rust/`: Rust grammar and generated C parser.

Regenerate goldens through the `generate-*-golden` build steps when output changes.
Keep the vendored scanner's `(void)` signatures consistent with its generated
parser. Regenerate that parser through the grammar's own generator.

## License

No project-wide license file is supplied. Vendored fixtures and grammar sources
retain their upstream license files and notices.
