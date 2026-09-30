# Notes index

`notes/` holds the exploration-phase records of this translator: dated research
into Rust→Zig translation, and the design records that grew out of it.

**These notes are not a coverage claim.** They are documents about what was
investigated and what was proposed, written in August 2026. Nothing in them says
that `translate-rust` supports a Rust shape. For what the translator actually
translates today, read the [repository README](../README.md); the fixtures and
the pinned refusals it lists are the only statement of current coverage.

Every link on this page is a relative link to a file in this repository, so the
whole index resolves in a fresh clone.

## Research records (2026-08-17)

Dated research. Each note carries its own inline citations and an explicit
version anchor; the facts were verified on the research date and may have
changed since.

| Note | Question it answers |
|------|---------------------|
| [research/prior-work.md](research/prior-work.md) | What already existed for Rust→Zig, and what analogous transpilers teach |
| [research/parsing-tooling.md](research/parsing-tooling.md) | How to get a Rust AST plus semantic information into a Zig program |
| [research/idiom-mapping.md](research/idiom-mapping.md) | Per-feature mapping from the Rust language surface to idiomatic Zig 0.16 |
| [research/approaches.md](research/approaches.md) | Five candidate translator architectures, and which one was recommended |

### What the research concluded (as recorded on 2026-08-17)

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

### What the research recommended next (recorded, not a task list)

The research phase closed by recommending: fork the rust2zig dialect baseline;
v0 = reproduce.com plus one example on Zig 0.16 (JSON IR sidecar → Zig emit →
`zig fmt`, with differential `cargo test` ⇄ `zig test` verification); v1 = leaf
`no_std` crate subset (structs, enums, fns, generics→comptime, Result, Drop).
See [research/approaches.md](research/approaches.md) §6 for the full roadmap as
it was written, and the `§Sources` section of each note for citations.

This is a historical recommendation, not a backlog. What was actually built is
in the [repository README](../README.md).

### Open questions recorded at the close of the design phase (2026-08-18)

These were left open. The notes record the question, not a resolution.

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

## Design records (2026-08-18)

Historical design specifications. Each one describes a system that was
*proposed* during the exploration phase. None of them describes the translator
in this tree, and none is a statement of what it supports. Read the
[repository README](../README.md) for that.

### Data model

The lossless semantic IR the design proposed the translator would emit Zig
from: a unified reference plus one note per axis.

| Doc | Contents |
|-----|----------|
| [design/data-model.md](design/data-model.md) | Unified IR design — shared spine, node inventory, JSON boundary, v1 subset, open decisions |
| [design/data-model/crate-graph.md](design/data-model/crate-graph.md) | Crate/module graph, visibility, paths, symbol table |
| [design/data-model/items-types.md](design/data-model/items-types.md) | Items plus types plus generics/monomorphization |
| [design/data-model/exprs-patterns.md](design/data-model/exprs-patterns.md) | Expressions, statements, patterns plus Zig-lowering hooks |
| [design/data-model/ownership-mem.md](design/data-model/ownership-mem.md) | Ownership, Drop, allocator, unsoundness markers |
| [design/data-model/rustdoc-json-mapping.md](design/data-model/rustdoc-json-mapping.md) | Field-by-field rustdoc JSON to wire-format mapping |

### Architecture

| Doc | Contents |
|-----|----------|
| [design/architecture.md](design/architecture.md) | Master architecture specification — package generation, `r2z-core`, macros, structural fidelity, traits/vtables, allocation, and the M1–M4 actionable roadmap |
| [design/architecture/pkg-dep-macros.md](design/architecture/pkg-dep-macros.md) | Package emission, Cargo dependency graph mapping, and macro expansion pipeline |
| [design/architecture/runtime-traits.md](design/architecture/runtime-traits.md) | `r2z-core` runtime library, static duck typing, dynamic `dyn Trait` vtables, and `@fieldParentPtr` supertrait upcasting |
| [design/architecture/structure-memory.md](design/architecture/structure-memory.md) | 1:1 structural mapping, visibility, re-exports, allocator injection, and LIFO `defer`/`errdefer` RAII |
| [design/architecture/features-actionable.md](design/architecture/features-actionable.md) | Enums/unions, dual-track error handling, match guards, raw pointers, and crate-by-crate actionable breakdown |

## Using these notes

- Cite them as dated research, with the version anchor the note itself carries.
  Zig, rustc, and the transpilers surveyed have all moved since.
- Do not read them as a description of the current code. The
  [repository README](../README.md) and the source under `src/` are.
- Do not read them as an implementation backlog. The research-phase roadmap is
  quoted above as a historical record only.
