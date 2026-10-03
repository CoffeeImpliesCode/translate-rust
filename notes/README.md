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

| Note | Question it answers | Contradicts today's code? |
|------|---------------------|---------------------------|
| [research/prior-work.md](research/prior-work.md) | What already existed for Rust→Zig, and what analogous transpilers teach | no |
| [research/parsing-tooling.md](research/parsing-tooling.md) | How to get a Rust AST plus semantic information into a Zig program | no |
| [research/idiom-mapping.md](research/idiom-mapping.md) | Per-feature mapping from the Rust language surface to idiomatic Zig 0.16 | **yes — §5** |
| [research/approaches.md](research/approaches.md) | Five candidate translator architectures, and which one was recommended | no |

### Two records that contradict the implementation

The records themselves are dated research and are left as written. These two
are flagged because their text answers a question about *this* translator's
design and the answer is no longer the one the code gives, so citing either
without this caveat would be citing something false.

- **`research/idiom-mapping.md` §5 calls const generics "trivial".** The IR has
  no const-value slot for a const **argument** at all: `GenericArgs` in
  `src/ir/types.zig` carries only `params: []const Type`, so a const argument has
  nowhere to be represented. `validate`'s `IncompleteGenericMetadata` comment
  records the consequence — an arity check that counts type parameters alone
  measures zero arguments for a const-generic declaration and refuses it. What
  §5 calls trivial is a gap the IR has not closed, and the note's `comptime N:
  usize` mapping is a proposal, not something the translator does.
- **`design/architecture/runtime-traits.md` §6.1 describes trait `impl` blocks
  emitting into a `TraitName_TypeName` sibling struct.** The emitter does not do
  that. It hoists every `impl` method into the target's one flat struct
  namespace (`hoistedMethodName` in `src/backend/zig/lower.zig`) and resolves a
  collision by mangling — `name__SelfType`, then `name__SelfType_TraitKey` — so
  two impls sharing a self type are still separated. The forwarded-alias step
  (item 3 of that protocol) is not in the emitter either.

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
  async. Hard-block: procedural/derive macros and catch_unwind. (Recorded as a
  difficulty estimate; §5's "const generics trivial" is contradicted — see
  above.)
- **Approaches**: five architectures lie on two axes (semantic source;
  translated/untranslated boundary). Recommended: **(e) hybrid/incremental** —
  syn + rust-analyzer SCIP behind a named `no_std`-ish dialect, everything
  else pushed to an FFI boundary; referenced roadmap v0→v6.

### What the research recommended next (recorded, not a task list)

The research phase closed by recommending: fork the rust2zig dialect baseline;
v0 = reproduce rust2zig with one example on Zig 0.16 (JSON IR sidecar → Zig emit →
`zig fmt`, with differential `cargo test` ⇄ `zig test` verification); v1 = leaf
`no_std` crate subset (structs, enums, fns, generics→comptime, Result, Drop).
See [research/approaches.md](research/approaches.md) §6 for the full roadmap as
it was written, and the `Sources` section of a research note for its citations.
Only `prior-work.md` lacks that section: it cites each claim inline.

This is a historical recommendation, not a backlog. What was actually built is
in the [repository README](../README.md).

### Open questions recorded at the close of the research phase (2026-08-17)

These were left open. The notes record the question, not a resolution. The
first three are `research/idiom-mapping.md` §21; the fourth is
`research/prior-work.md` §5. The design records carry their own, separate
open-decision sections (`design/data-model.md` §6, `items-types.md` §7,
`exprs-patterns.md` §7, `crate-graph.md` §7, `ownership-mem.md` §9).

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

## Design records (design phase)

Historical design specifications. Each one describes a system that was
*proposed* during the exploration phase. None of them describes the translator
in this tree, and none is a statement of what it supports. Read the
[repository README](../README.md) for that.

Only `design/architecture.md` carries an explicit `Date:` line. The other ten
design records carry no date of their own and are placed in time only by
cross-reference to the 2026-08-17 research notes.

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

| Doc | Contents | Contradicts today's code? |
|-----|----------|---------------------------|
| [design/architecture.md](design/architecture.md) | Master architecture specification — package generation, `r2z-core`, macros, structural fidelity, traits/vtables, allocation, and the directory-layout refactoring plan. It carries no milestone roadmap | no |
| [design/architecture/pkg-dep-macros.md](design/architecture/pkg-dep-macros.md) | Package emission, Cargo dependency graph mapping, and macro expansion pipeline | no |
| [design/architecture/runtime-traits.md](design/architecture/runtime-traits.md) | `r2z-core` runtime library, static duck typing, dynamic `dyn Trait` vtables, and `@fieldParentPtr` supertrait upcasting | **yes — §6.1** |
| [design/architecture/structure-memory.md](design/architecture/structure-memory.md) | 1:1 structural mapping, visibility, re-exports, allocator injection, and LIFO `defer`/`errdefer` RAII | no |
| [design/architecture/features-actionable.md](design/architecture/features-actionable.md) | Enums/unions, dual-track error handling, match guards, raw pointers, the crate-by-crate gap analysis for `mini`/`fnv`/`hex`/`fletcher`, and the M1–M4 milestone roadmap (§4) | no |

§6.1 of `runtime-traits.md` is the `TraitName_TypeName` sibling-struct protocol
described in the contradiction note above. Read it as the design question that
was asked, not as a description of how the emitter resolves a method collision.

## Using these notes

- Cite them as dated research, with the version anchor the note itself carries.
  Zig, rustc, and the transpilers surveyed have all moved since.
- Do not read them as a description of the current code. The
  [repository README](../README.md) and the source under `src/` are.
- Do not read them as an implementation backlog. The research-phase roadmap is
  quoted above as a historical record only.
- Where a record contradicts the implementation, the two flagged above are the
  ones to watch. The record is kept as written; the flag is what stops the
  citation from being read as a description of this tree.
