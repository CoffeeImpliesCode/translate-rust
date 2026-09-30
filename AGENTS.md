# translate-rust

Zig 0.16.0 research project for translating Rust crates into correct, idiomatic Zig. Use `notes/README.md` for the research/design index and `README.md` for current implementation and coverage. The notes describe private agent-notes and archived records; do not assume their original paths are present in this checkout.

## Local workflow

- Use TDD for new observable behavior: write a failing test, run it, implement the smallest change, then rerun. Golden files define emitted Zig, sidecar wire format, and normalized analyzer output. Examples: `src/fixtures/minimal.rs`, `test/mini-rustdoc.json`, `test/fnv.json`, and `test/golden/zig_src/fnv/src/root.zig`.
- Before adding tests, follow `zig build test`, the model module's `@import` test-inclusion pattern, and runtime file reads via `std.testing.io` and `Dir.cwd`.
- For design-only work, consult `notes/README.md` to locate design records. Do not assume an indexed record is present in this checkout; `README.md` describes current implementation and coverage.
- Research notes should use dated, cited primary sources and record contradictions.
- For future non-Zig formats such as TOML, use `serde.zig`, not a hand-written parser.

## Build and verification

**Use `tools/zig-pinned.sh`, not a bare `zig build`.** Two host facts break the
bare form, and both fail quietly rather than loudly:

- `zig` on `PATH` is the anyzig shim, which re-resolves and re-downloads the
  toolchain on every invocation.
- This repository is on an NFSv3 mount. Zig's atomic file write uses
  `renameat2(RENAME_EXCHANGE)`, which NFSv3 does not implement, so any cache
  directory on the mount dies with `EINVAL` and a `programmer bug caused
  syscall error` panic.

`tools/zig-pinned.sh` resolves a real cached toolchain directly, puts it first
on `PATH` for spawned children, and moves both cache directories to local disk.
Its arguments are identical to `zig build`:

```sh
tools/zig-pinned.sh                                  # default install step
tools/zig-pinned.sh test
tools/zig-pinned.sh test-crates --summary all
tools/zig-pinned.sh run -- test/crates/hex -o /tmp/hex-out
```

Set `R2Z_ZIG` to override toolchain discovery and `R2Z_SCRATCH` to override the
local-disk cache root.

Run `gate` in the devenv shell. It runs format check, build, tests, AST check,
`ziglint`, and `zlint`; `zbc` is advisory. Inside that shell the equivalent
builds are `tools/zig-pinned.sh test` and `tools/zig-pinned.sh test-crates`.

## Version control

Use `jj`, not raw Git. Check status with `jj st`. Commit only when asked; do not run `jj abandon` without permission.
