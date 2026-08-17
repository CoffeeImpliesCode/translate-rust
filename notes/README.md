# Research notes — translate-rust

Exploration phase of a translate-c-style Rust → Zig tool. Each note is a
self-contained research deliverable; the index below tracks status.

| Note | Question | Status |
|------|----------|--------|
| [research/prior-work.md](research/prior-work.md) | What already exists for Rust→Zig; lessons from analogous transpilers | ✅ landed (2026-08-17) |
| [research/parsing-tooling.md](research/parsing-tooling.md) | Linkable Rust parsers / semantic sources; how translate-c works | ✅ landed (2026-08-17) |
| [research/idiom-mapping.md](research/idiom-mapping.md) | Rust features → correct, proper Zig | ⏸ halted mid-run (research done, write failed) |
| [research/approaches.md](research/approaches.md) | Architectures: full vs. boundary vs. pull-in-deps; recommended path | ⏸ halted mid-run (cancelled) |

## Headline findings so far

- **Prior work**: exactly two source-level Rust→Zig transpilers exist —
  `sanxiyn/rust2zig` (active, syn + rust-analyzer SCIP semantics, the natural
  baseline/benchmark) and a dead tokenizer. No `translate-rust` in ziglang/zig.
  c2rust is the reference architecture (mechanical first pass → deterministic
  refactor → human); Cpp2Rust proves a runtime layer can bridge ownership;
  c2z shows C++→Zig collapses into bindings+glue.
- **Tooling**: Zig's translate-c on master is 100% Aro (Zig's own C parser) —
  no clang. The Rust analogue of "authoritative frontend" is rustc itself
  (`rustc_interface`, nightly-pinned like c2rust's refactor tool); the cheap
  first milestone is `rustdoc --output-format json` (public API + types, no
  bodies); cargo expand is lossy, never ground truth.
