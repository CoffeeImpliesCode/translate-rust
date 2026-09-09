# translate-rust

Zig 0.16.0 research project for translating Rust crates into correct, idiomatic Zig. Use `notes/README.md` for the research/design index and `README.md` for current implementation and coverage. The notes describe private agent-notes and archived records; do not assume their original paths are present in this checkout.

## Local workflow

- Use TDD for new observable behavior: write a failing test, run it, implement the smallest change, then rerun. Golden files define emitted Zig, sidecar wire format, and normalized analyzer output. Examples: `src/fixtures/minimal.rs`, `test/mini-rustdoc.json`, `test/fnv.json`, and `test/golden/zig_src/fnv/src/root.zig`.
- Before adding tests, follow `zig build test`, the model module's `@import` test-inclusion pattern, and runtime file reads via `std.testing.io` and `Dir.cwd`.
- For design-only work, consult `notes/README.md` to locate design records. Do not assume an indexed record is present in this checkout; `README.md` describes current implementation and coverage.
- Research notes should use dated, cited primary sources and record contradictions.
- For future non-Zig formats such as TOML, use `serde.zig`, not a hand-written parser.

## Build and verification

```sh
zig build
zig build run -- ...
zig build test
zig build -Doptimize=ReleaseSafe
gate
zig fmt
```

Run `gate` in the devenv shell. It runs format check, build, tests, AST check, `ziglint`, and `zlint`; `zbc` is advisory.

## Version control

Use `jj`, not raw Git. Check status with `jj st`. Commit only when asked; do not run `jj abandon` without permission.
