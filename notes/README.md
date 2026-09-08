# Notes index

The repository research and design notes moved to a private agent-notes store. This index records their destinations without duplicating their content.

Use the [repository README](../README.md) for current implementation and coverage. These notes are references, not evidence of current support. Archived plans record historical intent only.

Canonical links use the repository's ignored `agent-notes` symlink. They require the local private store and do not resolve in a fresh clone.

## Canonical notes

These 16 notes are the live canonical copies.

| # | Original repository path | Canonical destination |
|---:|---|---|
| 1 | `notes/README.md` | [research-notes-translate-rust--n-ffe0cb4188b94761a11cdf0e58c9b3fb.md](../agent-notes/research-notes-translate-rust--n-ffe0cb4188b94761a11cdf0e58c9b3fb.md) |
| 2 | `notes/design/architecture.md` | [translate-rust-architecture-decoupled-frontend-backend-design--n-4179ebd715f941baa9b6145eac057297.md](../agent-notes/translate-rust-architecture-decoupled-frontend-backend-design--n-4179ebd715f941baa9b6145eac057297.md) |
| 3 | `notes/design/architecture/features-actionable.md` | [feature-translation-mechanics-actionable-milestone-roadmap--n-b1396538f0704435949b4baad7762803.md](../agent-notes/feature-translation-mechanics-actionable-milestone-roadmap--n-b1396538f0704435949b4baad7762803.md) |
| 4 | `notes/design/architecture/pkg-dep-macros.md` | [package-generation-dependency-graph-and-macro-expansion-architecture--n-9dc0fd66713a4f13961f15737a314093.md](../agent-notes/package-generation-dependency-graph-and-macro-expansion-architecture--n-9dc0fd66713a4f13961f15737a314093.md) |
| 5 | `notes/design/architecture/runtime-traits.md` | [runtime-trait-translation-architecture-r2z-core-trait-systems--n-1c30b5efabaa4eecb0db7cbb9d7a1cc1.md](../agent-notes/runtime-trait-translation-architecture-r2z-core-trait-systems--n-1c30b5efabaa4eecb0db7cbb9d7a1cc1.md) |
| 6 | `notes/design/architecture/structure-memory.md` | [architecture-design-structure-memory-1-1-mapping-visibility-allocators-drop--n-110ac5c0b3c0492c9ce28e8bea8953b3.md](../agent-notes/architecture-design-structure-memory-1-1-mapping-visibility-allocators-drop--n-110ac5c0b3c0492c9ce28e8bea8953b3.md) |
| 7 | `notes/design/data-model/crate-graph.md` | [data-model-crate-module-graph--n-af24c667c068421194a76582fd08b46b.md](../agent-notes/data-model-crate-module-graph--n-af24c667c068421194a76582fd08b46b.md) |
| 8 | `notes/design/data-model/exprs-patterns.md` | [data-model-expr-pattern-statement-zig-lowering-hooks--n-9e0d3fde308847e9b0dd56c099cd851d.md](../agent-notes/data-model-expr-pattern-statement-zig-lowering-hooks--n-9e0d3fde308847e9b0dd56c099cd851d.md) |
| 9 | `notes/design/data-model/items-types.md` | [data-model-items-types--n-1068ac51a2c54f568a4aad3aae2efb3a.md](../agent-notes/data-model-items-types--n-1068ac51a2c54f568a4aad3aae2efb3a.md) |
| 10 | `notes/design/data-model/ownership-mem.md` | [data-model-ownership-borrowing-drop-allocator--n-f87f8a8079c34fd999d8f9d42e4994e4.md](../agent-notes/data-model-ownership-borrowing-drop-allocator--n-f87f8a8079c34fd999d8f9d42e4994e4.md) |
| 11 | `notes/design/data-model/rustdoc-json-mapping.md` | [rustdoc-json-wire-format-mapping--n-47b6fc6356f14b1288b80381a0a50f64.md](../agent-notes/rustdoc-json-wire-format-mapping--n-47b6fc6356f14b1288b80381a0a50f64.md) |
| 12 | `notes/design/data-model.md` | [data-model-the-rust-crate-ir-unified-design--n-6798e351c6614d1987a5d836e7cd30f3.md](../agent-notes/data-model-the-rust-crate-ir-unified-design--n-6798e351c6614d1987a5d836e7cd30f3.md) |
| 13 | `notes/research/approaches.md` | [architectural-approaches-for-a-rust-zig-translator--n-08904bd6068e455fb45482ae518f0eb3.md](../agent-notes/architectural-approaches-for-a-rust-zig-translator--n-08904bd6068e455fb45482ae518f0eb3.md) |
| 14 | `notes/research/idiom-mapping.md` | [idiom-mapping-rust-correct-proper-zig-0-16--n-cee1ee30e08d4528be3031619e1ebefc.md](../agent-notes/idiom-mapping-rust-correct-proper-zig-0-16--n-cee1ee30e08d4528be3031619e1ebefc.md) |
| 15 | `notes/research/parsing-tooling.md` | [parsing-tooling-getting-a-rust-ast-semantic-info-into-zig--n-9181c9ca26e04488b9813c1f84028d61.md](../agent-notes/parsing-tooling-getting-a-rust-ast-semantic-info-into-zig--n-9181c9ca26e04488b9813c1f84028d61.md) |
| 16 | `notes/research/prior-work.md` | [prior-work-rustzig-translation-and-analogous-transpilers--n-9f208a58147744d7b097250cc439dc5c.md](../agent-notes/prior-work-rustzig-translation-and-analogous-transpilers--n-9f208a58147744d7b097250cc439dc5c.md) |

The replacement for `notes/README.md` has provenance from `README--translate-rust.md`. Migration normalized it, so it is not a byte-identical copy.

## Archived historical plans

These three plans are in the dated private archive. They are not canonical notes and do not define current support.

The local links require this workstation's private archive. If that archive is unavailable, run the matching `jj` command from the repository root.

| # | Original repository path | Local archive | Historical retrieval |
|---:|---|---|---|
| 17 | `notes/design/data-model-plan.md` | [data-model-plan.md](file://~/.agents/agent-notes-archive/round-2-2026-08-30/design/data-model-plan.md) | `jj file show -r74787c43 notes/design/data-model-plan.md` |
| 18 | `notes/design/restructuring-plan.md` | [restructuring-plan.md](file://~/.agents/agent-notes-archive/round-2-2026-08-30/design/restructuring-plan.md) | `jj file show -r74787c43 notes/design/restructuring-plan.md` |
| 19 | `notes/design/source-model-type-inference.md` | [source-model-type-inference.md](file://~/.agents/agent-notes-archive/round-2-2026-08-30/design/source-model-type-inference.md) | `jj file show -r74787c43 notes/design/source-model-type-inference.md` |
