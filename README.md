# translate-rust

Exploration of a **translate-c-style tool for Rust → Zig**: a program that
takes a Rust crate and emits correct, idiomatic Zig — the Rust analogue of
Zig's `translate-c` (clang AST → Zig source). Harder than C: module system,
generics, traits, ownership/borrowing, macros, and the std surface all need
translation strategies, not just syntax mapping.

Scaffolded to the same conventions as `~/projects/{notui, skript, ztex}`.

## Status

**Research phase.** The scaffold builds and runs; no translation pipeline
yet. Findings live in `notes/research/`:

- `prior-work.md` — existing Rust→Zig efforts and lessons from analogous
  transpilers (C→Rust, C++→Rust, …)
- `parsing-tooling.md` — linkable Rust parsers / semantic sources
  (tree-sitter-rust, syn, rustc_interface, rust-analyzer, rustdoc JSON) and
  how translate-c itself is built
- `idiom-mapping.md` — Rust language features → correct, proper Zig
  (enums → tagged unions, Result → error unions, traits → comptime/vtables, …)
- `approaches.md` — architectures: full translation vs. FFI boundary vs.
  pull-in-deps, and the recommended exploration path

## Stack

- **Language**: Zig 0.16 (module API, `std.Io`, Juicy Main)
- **VCS**: jj — DO NOT USE GIT COMMANDS
- **Dev env**: devenv + direnv (`.envrc` → `use devenv`)
- **Linting**: zlint (`zlint.json` rules) + `zig fmt --check`

## Structure

```
build.zig          # build graph: translate_rust module → exe → run/test steps
build.zig.zon      # package manifest (fingerprint, paths)
devenv.nix         # nix dev environment (zig, pkg-config)
.envrc             # direnv → devenv hook
AGENTS.md          # agent rules
src/
├── main.zig       # CLI skeleton (std.process.Init)
└── root.zig       # library root + unit tests
notes/             # design research (notes/research/*.md)
```

## Commands

```bash
direnv allow        # enter devenv shell (first time / after devenv.nix edits)
zig build           # Debug build → zig-out/bin/translate-rust
zig build run       # build + run
zig build run -- --help   # CLI skeleton help
zig build test      # unit tests
zig fmt --check .   # formatting gate
zlint               # lint (prefer ~/.local/bin/zlint; devenv nixpkgs is fallback)
gate                # all quality gates (fmt, build, test, ast-check, lint)
jj st               # working-copy status (never git)
```
