# Research notes — translate-rust

Exploration phase of a translate-c-style Rust → Zig tool. Each note is a
self-contained research deliverable.

| Note | Question | Status |
|------|----------|--------|
| [research/prior-work.md](research/prior-work.md) | What already exists for Rust→Zig; lessons from analogous transpilers | ✅ (2026-08-17) |
| [research/parsing-tooling.md](research/parsing-tooling.md) | Linkable Rust parsers / semantic sources; how translate-c works | ✅ (2026-08-17) |
| [research/idiom-mapping.md](research/idiom-mapping.md) | Rust features → correct, proper Zig | ✅ (2026-08-17) |
| [research/approaches.md](research/approaches.md) | Architectures: full vs. boundary vs. pull-in-deps; recommended path | ✅ (2026-08-17) |

## Synthesis (what the research decides)

- **Prior work**: exactly two source-level Rust→Zig transpilers exist —
  `sanxiyn/rust2zig` (active; syn + rust-analyzer SCIP semantics; the natural
  baseline) and a dead tokenizer. No `translate-rust` in ziglang/zig. c2rust
  is the reference architecture (mechanical pass → deterministic refactor →
  human/LLM); Cpp2Rust proves a runtime layer can bridge ownership; c2z shows
  full C++→Zig collapses into bindings+glue.
- **Tooling**: Zig's translate-c on master is 100% Aro (Zig's own C parser) —
  no clang. The Rust analogue of "authoritative frontend" is rustc itself
  (`rustc_interface`, nightly-pinned like c2rust); `rustdoc --output-format
  json` is the cheap first milestone (public API + types, no bodies);
  cargo expand is lossy, never ground truth; tree-sitter-rust/syn are
  syntax-only.
- **Idiom mapping**: 17-feature Rust→Zig map. Mechanical: modules, structs,
  enums, unions, FFI. Moderate: generics→comptime, Option/Result→optional/
  error unions, pattern matching, strings, collections, unsafe, static traits.
  Hard: dyn Trait, ownership (Rc/Arc/RefCell/drop), custom iterators/closures,
  async. Hard-block: procedural/derive macros and catch_unwind.
- **Approaches**: five architectures lie on two axes (semantic source;
  translated/untranslated boundary). Recommended: **(e) hybrid/incremental** —
  syn + rust-analyzer SCIP behind a named `no_std`-ish dialect, everything
  else pushed to an FFI boundary; referenced roadmap v0→v6.

## Recommended next step (design phase)

Fork the rust2zig dialect baseline; v0 = reproduce.com + one example on Zig
0.16 (JSON IR sidecar → Zig emit → `zig fmt`, with differential
`cargo test` ⇄ `zig test` verification); v1 = leaf `no_std` crate subset
(structs, enums, fns, generics→comptime, Result, Drop). See
`research/approaches.md` §6 for the full roadmap, and its §7 / the other
notes' §Sources for citations.

## Design-phase open questions (answered by the user, not the research)

1. **dyn Trait**: synthesize a vtable struct, or exclude from v1 (rust2zig
   excludes it)?
2. **Ownership model**: scoped allocator + defer/errdefer only, or also
   synthesize Rc/Arc/RefCell refcount wrappers?
3. **Macro expansion**: is running the Rust toolchain (cargo expand / pinned
   rustc_driver) an acceptable mandatory front-end step for v1, or must the
   translator stay syntax-only and reject macros?
4. **Positioning**: deterministic translator, differential-testing oracle,
   or first pass feeding an LLM refactor — the three roles differ
   architecturally.
