# Architectural approaches for a Rust → Zig translator

Research date: 2026-08-17. Target: Zig **0.16.0** (released 2026-04-14 per `ziglang.org/documentation/0.16.0/` and ziggit thread "0.16.0 Released"). Context: a personal exploration project, single developer, correctness-first, ~Rust 1.77+ toolchain available. Front-end trade-offs are covered in `parsing-tooling.md`; existing-art landscape and lessons in `prior-work.md`. This document stays at the *architecture* level and does not duplicate those.

**Bottom line up front.** The design space for translating *Rust* into *Zig* has two axes that decouple cleanly: **(1)** what you accept as the semantic source of truth — a sidecar running the real Rust toolchain vs. an in-process syntax tree vs. an enforced language boundary; **(2)** where you draw the boundary between translated and untranslated code — every-leaf vs. crates-as-units vs. FFI per-function vs. unify-the-graph. Combining those axes gives the five options below. **For a single-developer exploration project the recommended path is (e), an incremental + boundary-kept dialect that starts from a leaf `no_std`-style crate subset, uses `syn` parsing plus `rust-analyzer` SCIP for semantics (the only end-to-end-working combo in the wild today — `sanxiyn/rust2zig`), and avoids the `rustc_driver` nightly pin until a later milestone demands real typeck coverage.** Justification at §6.

---

## 1. The generic pipeline shape

Every Rust→Zig tool that wants to emit *correct* (not just syntactically valid) Zig eventually runs something close to this pipeline. It is the translate-c analogue for Rust:

```
       ┌─────────────┐
Rust ─▶│   parse     │ ─▶ syntax tree (lossless spans, attrs)
       └─────────────┘
            │
       ┌─────────────┐
       │   resolve   │ ─▶ name resolution + type information
       └─────────────┘
            │
       ┌─────────────┐
       │   expand    │ ─▶ macros & derives desugared in place
       └─────────────┘
            │
       ┌─────────────┐
       │   lower     │ ─▶ language-neutral semantic IR (lossless)
       └─────────────┘
            │
       ┌─────────────┐
       │  desugar    │ ─▶ AST-level rewrites (impl Into for &T → *x, …)
       └─────────────┘
            │
       ┌─────────────┐
       │   analyse   │ ─▶ generic instantiation, monomorphisation tables
       └─────────────┘
            │
       ┌─────────────┐
       │    emit     │ ─▶ Zig source text
       └─────────────┘
            │
       ┌─────────────┐
       │  zig fmt    │ ─▶ canonical form
       └─────────────┘
            │
       ┌─────────────┐
       │   verify    │ ─▶ cargo test on Rust ↔ zig test on Zig
       └─────────────┘
```

*Reference architecture proof*: Zig's own translate-c on master/0.16-dev is exactly this shape (`parse → translate → zig fmt`) — *"then trawl through generated Zig source to check that it is valid zig"*, with the frontend being Zig's own **Aro** parser and renderer on `lib/compiler/translate-c/` (see `parsing-tooling.md` §1a).

*The semantic depth needed*: the *only* differences between options (a)–(e) are *who* runs the first four boxes (parse / resolve / expand / lower) and *what* the IR is allowed to lose. Boxes 5–8 (analyse / emit / fmt / verify) are nearly identical across architectures; they live in Zig regardless. Boxes 1–4 may live in a Rust sidecar (options a, b, c) or be replaced by a foreign-function boundary (options c, d).

---

## 2. The five options

### 2.1 Option (a) — Full translation driven by `rustc` internals

**Idea**. Drive the real compiler via `rustc_driver`/`rustc_interface` to HIR/MIR, capture exactly resolved names + concrete types + fully expanded macros, and emit Zig from that lossless IR. This is the Rust analogue of c2rust's refactor pass on the *output* side (the *input* there is clang for C).

**Pipeline shape**:

```
cargo build → rustc_driver sidecar → HIR/MIR dump → JSON IR (lossless) → Zig emit → zig fmt → verify
                                                  ▲                                              ▲
                                                  pinned nightly                                diff test
```

* `parse` + `resolve` + `expand` are *all* done by rustc; nothing is hand-rolled.
* `lower` = a custom `Hir → IR` pass inside the driver.
* `analyse` is woven into rustc's typeck.
* The sidecar is built against a pinned `rustc nightly` (c2rust pins `nightly-2023-04-15`; see §6 of `prior-work.md`).
* The IR is a Rust trait + tagged-adt encoding that mirrors HIR 1:1; no semantic loss.

**Pros**. Complete semantics; macros resolved; exact types; monomorphisation tables handed to you by the compiler; follows the precedent of every successful translator (c2rust, Cpp2Rust, kani) that has full correctness demands.

**Cons**. Complexity is huge — rustc is a moving target; the pinned nightly c2rust uses dates to early 2023, and *"the master branch is under constant development and you may experience issues or crashes"*; the sidecar must be rebuilt and re-tested on every rustc bump.

**Effort / Risk / Correctness ceiling**.

| Axis | Rating | Notes |
|---|---|---|
| Effort | **Very high** (~6–12 months for a single dev to a usable IR + emit) | c2rust's refactor team of ~5 has not rebased nightly in 3 years. |
| Risk | **Very high** | Nightly pin is permanent; IR schema follows HIR. |
| Correctness ceiling | **Highest** (matches rustc exactly) | But only if the IR is lossless — most projects that tried lost nuance (cfg spans, hygiene IDs, unstable feature gates). |

**Citations.** c2rust README (https://raw.githubusercontent.com/immunant/c2rust/master/README.md): *"The other tools, such as `c2rust-refactor`, use `rustc` internal APIs, however, and are thus pinned to a specific `rustc` `nightly` version: `nightly-2023-04-15`. These are also not published to `crates.io`."* and *"Please note that the master branch is under constant development and you may experience issues or crashes."* rustc dev guide confirms `rustc_interface` exists for this exact use: *"The `rustc_interface` crate provides a low level API to external users for manually driving the compilation process, allowing third parties to effectively use rustc's internals as a library for analyzing a crate or for ad hoc emulating of the rustc driver."* (https://rustc-dev-guide.rust-lang.org/rustc-driver/intro.html).

---

### 2.2 Option (b) — Source-level transpile with a semantic sidecar

**Idea**. Do parsing *and* resolution *and* most expansion outside rustc, with separate cooperating tools. The c2rust analogue here is the *opposite* allocation: in c2rust, the **front end is authoritative** (clang) and the backend just emits; here the frontend is a cooperating *system* of tools (tree-sitter / syn for parse, cargo-expand for macros, rust-analyzer `hir` / SCIP for types, optionally rustdoc JSON for the public API).

**Pipeline shape**:

```
tree-sitter-rust ─┐
                  ├──▶ syn AST + spans → desugar passes (AST→AST)
cargo expand ─────┘                              │
                                                 ▼
                  rust-analyzer hir (or scip dumps, or rustdoc JSON)
                              │
                              ▼
                         semantic IR (lossy w.r.t. unresolved cases)
                              │
                              ▼
                     Zig emit → zig fmt → verify
```

This is exactly the architecture `sanxiyn/rust2zig` uses: *"Written in Rust, using `syn` for parsing / Use SCIP for semantic information / A desugaring phase rewrites the Rust AST into more explicit Rust (still a `syn` AST) before translation, so emission can stay largely structural"* (https://raw.githubusercontent.com/sanxiyn/rust2zig/master/README.md). Its three desugar passes — `binary` (insert explicit derefs on `&T` operands), `match_ergonomics` (make default binding modes explicit), and (transitively) the other visitors — are *"backend-neutral and could be reused by other backends; only target-specific lowerings (e.g. signed `%` -> `@rem`) stay in the translator"* (same source).

**Pros**. Modular: each tool has one job. Cheaper than a `rustc_driver` rewrite. *Already proved end-to-end correct on a non-trivial corpus* — rust2zig's `option`, `sum`, `geometry`, `closure`, `iter`, `dot`, `bitset`, `drop`, `drop2`, `hash`, `random`, `calc` examples all pass both `cargo test` and `zig test` (README). Tooling is mostly stable / on-disk today.

**Cons**. Multiple tools to maintain; semantic answers are *approximate* (rust-analyzer typeck is IDE-grade, can drift from rustc — `"binary_type_at ... only works for variable/parameter idents"`, per rust2zig's own design notes); `cargo expand` is *"a debugging aid only. There should be no expectation that the expanded code can be compiled successfully, nor that if it compiles then it behaves the same as the original code"* (https://raw.githubusercontent.com/dtolnay/cargo-expand/master/README.md) — i.e. it is *never* ground truth. Macro hygiene is broken at the text level; you must use rust-analyzer's expansion or accept partial coverage.

**Effort / Risk / Correctness ceiling**.

| Axis | Rating | Notes |
|---|---|---|
| Effort | **Medium** (3–6 months for a single dev from a fork of rust2zig) | Most code already exists. |
| Risk | **Medium** (rust-analyzer SCIP/hir changes; proc-macro bridge fragility; nightly flag for cargo-expand) | |
| Correctness ceiling | **High** (subject to "if rust-analyzer agrees" caveat; tested on ~13 examples in rust2zig) | Real crates with complex trait bounds may outrun SCIP and require manual type-annotation patches. |

**Citations.** rust2zig README §"Implementation" (https://raw.githubusercontent.com/sanxiyn/rust2zig/master/README.md) for pipeline and discipline; rust2zig README §"Testing" — *"test.sh runs each example under rust through the translator and compares output byte-for-byte against the corresponding files under zig. Expected files are regenerated from translator output after each change. test_test.sh runs cargo test on each Rust example and zig test on the corresponding translated Zig file. This ensures the input/output pairs used to test the translator are in fact equivalent"*; cargo-expand README for the lossy-expansion caveat (https://raw.githubusercontent.com/dtolnay/cargo-expand/master/README.md); and parsing-tooling.md §4 for the front-end trade-off table (https://raw.githubusercontent.com/ziglang/zig/master/lib/compiler/translate-c/main.zig) as the reference shape.

---

### 2.3 Option (c) — Keep the boundary: FFI between translated and untranslated code

**Idea**. Never try to translate arbitrary Rust; translate the *narrow* set of modules whose shapes are tractable, and leave the rest as Rust staticlibs. Two-way FFI (Zig → Rust and Rust → Zig) is the seam. This is **autozig's** pattern (https://raw.githubusercontent.com/layola13/autozig/main/README.md) — *"Safe Rust to Zig FFI with Generics, Async & Stream Support … inspired by autocxx for C++"* — where the Rust user writes `autozig! { … Zig code … --- Rust signatures … }`, the Zig code is compiled to a staticlib, and safe Rust wrappers are generated. The *reverse* shape (Zig user who wants to call Rust) is equally natural.

**Pipeline shape**:

```
                   ┌──────────────────────────────────┐
                   │  Rust host process / crate-graph │
                   │  (left untranslated)             │
                   │                                  │
                   │  staticlib(.a) ┐                 │
                   └────────────────│─────────────────┘
                                    │ C-ABI extern "C"
                                    ▼
                   ┌──────────────────────────────────┐
                   │  Translated Zig module(s)        │
                   │  (Cargo build translated →       │
                   │   zig translate → zig fmt)       │
                   └──────────────────────────────────┘
                                    ▲
                                    │ C-ABI extern "C"
                                    │
                   ┌────────────────│─────────────────┐
                   │  Rust→Zig staticlib              │
                   └──────────────────────────────────┘
```

Practically: `zig build` orchestrates `cargo build --crate-type staticlib` for the untranslated surface; translated modules are produced by `zig translate-c`-style invocation running on the bounded subset of Rust that the tool handles today. autozig's invariants are useful here: *"Encapsulated Unsafe - FFI complexity is isolated; business logic remains unsafe-free"* (autozig README).

**Pros**. Pragmatic — *any* module you cannot translate (async, complex unsafe, proc-macro-heavy, large std surface) simply *is not translated*, with the seam explicit. No need for the rest of the toolchain to handle the unsupported language. Bounds the project on day one.

**Cons**. **No inlining across the boundary** (LTO has limits, and `comptime` cannot reach across FFI). Two build systems; two allocators; two string types (`String` ↔ `[]const u8`). All complex types must round-trip through C ABI; a `HashMap<String, Vec<u8>>` is a 200-line FFI struct by hand. Zero `Drop`/`Defer` cross-pollination. autozig demonstrates this is solvable but expensive — *"Encapsulated Unsafe - FFI complexity is isolated; business logic remains unsafe-free"* is the *result* of an elaborate `ZigBox`/`ZigBuffer` ownership protocol documented in their §"Explicit Lifetime Bridging Protocol" (https://raw.githubusercontent.com/layola13/autozig/main/README.md).

**When it fits**. Mixed crates with std-heavy or async cores that touch only a small inner kernel; migration projects where translating 80% of a code-base buys little compared to translating the inner 20% perfectly.

**Effort / Risk / Correctness ceiling**.

| Axis | Rating | Notes |
|---|---|---|
| Effort | **Low–Medium** to start (build the seam), but per-call-site **High** to grow (every Rust type crossing the boundary is a hand-rolled binding) | |
| Risk | **Medium** (ABI drift, ownership mismatches, allocator mismatch — Roc's manual: *"Zig's ecosystem consistently passes around allocators, which is exactly what we want, whereas off-the-shelf Rust crates almost always assume a single global allocator"*) | https://rtfeldman.com/rust-to-zig |
| Correctness ceiling | **High** (each side runs the *real* compiler) but **bounded by the seam's expressiveness** | |

---

### 2.4 Option (d) — Pull in Rust dependencies: translate the whole crate graph

**Idea**. `cargo metadata` to walk the dep graph; translate every leaf first, then fold dependencies into the translated output. The *compiler* is the orchestrator: `zig build` shells out to `cargo metadata`, decides which deps are translatable, and produces a single Zig workspace. The un-translatable deps stay untranslated (option (c) as a per-crate fallback).

**Pipeline shape**:

```
cargo metadata ─▶ dep graph
                    │
                    ▼
    topological walk, leaf→root
    leaf: no internal deps → translate (option a/b/c per dep size)
    internal node: deps already translated → translate
    untranslatable: leave as staticlib, link from translated root
                    │
                    ▼
         Zig workspace of translated modules + staticlibs of untranslated
                    │
                    ▼
                  zig build → verify per-crate + integration
```

This is what `c2rust --emit-build-files` does in the C→Rust world: *"To generate a `Cargo.toml` template for a Rust library, add the `--emit-build-files` option"* (https://raw.githubusercontent.com/immunant/c2rust/master/c2rust-transpile/README.md) — the modular output plus per-module Cargo skeleton is the *Rust-side* analogue. For us, it is per-crate `build.zig` plus a top-level orchestrator that orchestrates the partial graph.

**Pros**. Maximises translated surface; paves the way to a complete migration; same per-crate verification model as (b)/(c) but at scale.

**Cons**. **Transitive complexity**: a Rust crate's transitive closure contains `tokio`, `serde`, `syn`, `bytes`, etc. Translating all of them is years of work even for an *easy* case (no macros, no async). `cargo metadata`'s `resolver` behaviour changes between editions. Macro hygiene deep in the graph is unsolvable without rustc. The build system becomes a meta-build-system that knows about both ecosystems.

**Feasibility vs. impossibility**.

- **Feasible** for small, hand-curated dep sets (`tinyvec` + `hashbrown` + `equivalent` → e.g. `indexmap`).
- **Borderline** for one layer of `serde`-free community crates.
- **Impossible** today for any crate that depends transitively on `tokio`, `async-trait`, or `proc-macro2`/`syn`/`quote` *as actual logic* (vs. just being listed).

**Effort / Risk / Correctness ceiling**.

| Axis | Rating | Notes |
|---|---|---|
| Effort | **Very high** (every crate is a project; the orchestrator is its own project) | |
| Risk | **Very high** (every dep is an unsupported-syntax risk + a version-skew risk) | |
| Correctness ceiling | **High per crate, low per graph** (one bad leaf poisons the build) | |

---

### 2.5 Option (e) — Hybrid/incremental: start with a leaf-crate subset

**Idea**. Combine (b) and (c): parse + emit + verify using the semantic sidecar *for a deliberately narrow subset of Rust*, leave *everything else* on the FFI boundary, and grow the subset over versions. This is rust2zig's approach (its passing examples are an explicit, named dialect), but framed as a *strategy* rather than a project. It is also the only architecture that c2rust's README explicitly recommends even before they evidence it:

> *"The output of `c2rust transpile` is unsafe and unidiomatic; it is merely the first step in a longer migration process. … This work can be done by a human, a large language model, a deterministic tool, or some combination thereof."*
> — https://raw.githubusercontent.com/immunant/c2rust/master/README.md

The c2rust graph is `transpile → refactor → postprocess`; the recommended Rust→Zig exploration path is the inverse: a *tiny* transpile on day one, an *incremental* widening per version, and an "LLM / human" surface for the rest. The full option set is `(transpile dialect) × (boundary surface)` — let each project *pick the dialect first*, then grow it.

**Pipeline shape (concretely, v0.1 target)**

```
                    input.rs (no_std subset:
                              structs, enums, fns, impls of local types,
                              generic types via comptime,
                              ? Result, Drop via defer,
                              no async, no proc-macros, no unsafe interior)
                            │
syn sidecar ─────────────────┼──────────────────► desugar (binary, match ergonomics)
                            │
rust-analyzer scip ─────────┼──────────────────► analyse (monomorphisation tables,
                            │                       closure capture)
                            ▼
                         Zig emit
                            │
                         zig fmt
                            │
              ┌─────────────┴─────────────┐
              ▼                           ▼
      cargo test (Rust)            zig test (Zig)       ◀── differential pair
              │                           │
              └─────────► compare ◀───────┘
```

**Why this matches a single-developer, correctness-focused, Zig-0.16 exploration.**

1. **Bounded correctness.** A named dialect *is* a correctness contract: each item in the dialect is either handled (with a test) or refused at parse time. c2rust's pattern — *"we recommend using it in combination with a robust test suite"* (same README) — is built on the same idea at the process level; we get it at the dialect level.
2. **No nightly pin.** `syn` is on stable Rust; `rust-analyzer` produces SCIP dumps from stable rust-analyzer over stable cargo; cargo-expand is the only nightly component and is optional (skip the dialect's macro-heavy items). The "if rust-analyzer's typeck differs from rustc" caveat (parsing-tooling.md §2.4) is real but testable: every Rust→Zig pair in rust2zig's corpus has a `cargo test`/`zig test` matching assertion.
3. **Solidarity with prior art.** rust2zig is the natural baseline; replicating its gating dialect is one fork. Bun's LLM-driven port — *"Do the rewrite that looks like we transpiled our Zig code to Rust. We can gradually refactor it to reduce `unsafe` usage"* (https://bun.com/blog/bun-in-rust, 2026-07-08) — picks the same dialect-first shape on its way to a full migration.
4. **Refactor on tap.** When correctness needs more (e.g. a hard-to-translate type loses the borrow checker's enforcement), the dialect grows *or* the untranslatable region crosses the FFI boundary (option (c) as an in-project extension).

**Pros**. Smallest moving parts to ship; the boundary is visible in `build.zig` and the dialect is visible in a single file. Each dialect growth is *one* GitHub-issue-sized commit that flips a feature flag and adds a test pair. Self-correcting: a wrong translation breaks a `cargo test` ⇄ `zig test` pair and the bug is local.

**Cons**. Initial dialect excludes the bulk of interesting Rust (no async, no traits crossing module boundaries, no proc macros, limited std). The dialect grows slowly; a user with a crate using `tokio` cannot use the tool today. Users may outgrow the tool.

**Effort / Risk / Correctness ceiling**.

| Axis | Rating | Notes |
|---|---|---|
| Effort | **Low** to start (fork rust2zig; tighten dialect; ship v0.1) | |
| Risk | **Low** (no nightly; known prior art; dialect is a hard contract) | |
| Correctness ceiling | **High within the dialect; low outside** (the boundary enforces that) | rust2zig proves the ceiling is at least "12 named examples pass differential tests". |

---

## 3. Cross-cutting pipeline details

The boxes below are *shared* by all five options; what changes is who runs them.

### 3.1 Parse
- `tree-sitter-rust` (lossless CST, C library, zig-tree-sitter bindings need *"zig 0.16"*: https://raw.githubusercontent.com/tree-sitter/zig-tree-sitter/master/README.md). Pure syntax.
- `syn` ("a parsing library for parsing a stream of Rust tokens into a syntax tree of Rust source code", https://raw.githubusercontent.com/dtolnay/syn/master/README.md). Full AST incl. attrs, spans; needs a Rust sidecar.
- `rustc_driver` parses to the most authoritative AST but is nightly-bound.

### 3.2 Resolve + Expand
- `rustc_driver`/`rustc_interface` (option a): authoritative, nightly.
- `rust-analyzer` `hir`/`hir-*` crates + `proc-macro-srv` subprocess (option b): IDE-grade approximation, vendored, no stability guarantee (parsing-tooling.md §2.4).
- `cargo expand` (option b, lossy): expands `macro_rules!` and derive macros at the *text* level; reserved for diagnostics (per its own README).
- `rustdoc --output-format json` (subset of option b): resolves the *public* API; lacks bodies and macro expansions.

### 3.3 Lower + Desugar + Analyse
- This is where the *translator* lives. rust2zig's three desugar passes (`binary`, `match_ergonomics`, plus `collect_renames` for shadowing) are backend-neutral and should be reused: each pass is a `syn::visit_mut::VisitMut` walk that turns implicit Rust into explicit Rust before emission.

### 3.4 Emit
- Structural text emission. rust2zig's `translate/` directory (one file per construct: `expr.rs`, `stmt.rs`, `item.rs`, `pat.rs`, `flow.rs`, `call.rs`, `closure.rs`, `ty.rs`, `name.rs`, `generic.rs`, `rename.rs`, `mac.rs`) is the reference component layout.

### 3.5 zig fmt
- Use `zig fmt` as the canonicaliser — both for hygiene and to match translate-c's behaviour (which on master does not call clang at all but does fmt its output, see `parsing-tooling.md` §1a).

### 3.6 Verify
- Differential `cargo test` ⇄ `zig test` (rust2zig style).
- Golden-file `test.sh` for byte-for-byte regressions.
- Property tests on shared invariants (overflows, slice lengths, hash determinism).
- Round-trip FFI cross-check on the untranslated set (c2rust's `cross-checks` does this for C→Rust; see §4).

---

## 4. Verification strategies

These four are mutually reinforcing. The strongest single strategy is the differential pair; they compose into a verification pyramid.

### 4.1 Differential testing — **the cornerstone**
Run every test in the Rust source under `cargo test` *and* run the equivalent tests in the translated Zig under `zig test`, with identical inputs, and compare. This is rust2zig's `test_test.sh` discipline:

> *"test_test.sh runs cargo test on each Rust example and zig test on the corresponding translated Zig file. This ensures the input/output pairs used to test the translator are in fact equivalent."*
> — https://raw.githubusercontent.com/sanxiyn/rust2zig/master/README.md (§"Testing")

Strengths: catches every behavioural drift without an oracle. Weaknesses: requires the Rust crate already have tests; output-comparison is non-trivial for `HashMap`/randomised iteration.

### 4.2 Property testing
Where unit tests are sparse, generate inputs on both sides. For each `fn run(x: T) -> U` in scope, run `cargo test` (with `proptest`/`quickcheck`) and `zig test` (with hand-written or borrowed generators) on the same inputs and assert equality. Useful for parsers, decoders, integer-arithmetic heavy code.

### 4.3 Golden output
rust2zig's `test.sh` is byte-for-byte: *"test.sh runs each example under rust through the translator and compares output byte-for-byte against the corresponding files under zig. Expected files are regenerated from translator output after each change."* Catches every textual regression (whitespace, comments, name choices). Combined with differential testing, the *pair* of `.rs` and `.zig` golden files becomes a correctness-enforcing corpus.

### 4.4 Cross-check instrumentation — **for the FFI boundary**
For option (c), when one side has the "real" implementation and the other is the generated wrapper, instrument both sides to compare at runtime. c2rust has the same problem (C↔Rust) and solves it with a dedicated cross-check subsystem:

> *"This is the top-level directory for all cross-checking components, and contains the following: A clang plugin that automatically inserts cross-check instrumentation into C code. An equivalent rustc compiler plugin for Rust. The libfakechecks cross-checking backend library that prints out all cross-checks to standard output. This library is supported by both the C and Rust compiler plugins. Our experimental fork of the ReMon MVEE modified for C/Rust side-by-side checking."*
> — https://raw.githubusercontent.com/immunant/c2rust/master/cross-checks/README.md

For us the analogues are: a `rustc` plugin that emits cross-check calls at function boundaries in Rust, plus a Zig emit step that emits the same calls, plumbed through `libfakechecks`-style logging. Useful, but *only* in option (c)/(d) territory.

### 4.5 Bun-style test-suite borrowing
Bun's Zig → Rust rewrite maintained a *language-independent* test suite (*~1.4M assertions*) that could be reused in either world — which made the mechanical port reviewable: *"A language-independent test suite with a million assertions"* (https://bun.com/blog/bun-in-rust). For us that means: if our input crate has language-independent tests (TS, JS, fixtures, golden data files), the *test program* is reusable; the *runner* changes.

---

## 5. Comparison table

| Option | Who runs parse/resolve/expand | Boundary shape | Effort | Risk | Correctness ceiling | When it fits |
|---|---|---|---|---|---|---|
| **(a) Full rustc-driven** | rustc sidecar (pinned nightly) | Whole crate | **Very high** | **Very high** (nightly pin) | **Highest** | Years-long migration of *one* large crate where every feature matters |
| **(b) Semantic sidecar** | `syn` + rust-analyzer SCIP / hir | Whole file or crate | **Medium** | **Medium** (hir drift, proc-macro bridge) | **High** | Subset of Rust (no async, no proc-macros); many real-world crates |
| **(c) FFI boundary** | Both compilers (no translation of std) | Per-function C-ABI seam | **Low–Med start**, **High per seam** | **Medium** (ABI, allocator, ownership) | **High** *within the seam*; **N/A outside** | Mixed code-bases; std-heavy / async-heavy cores; `core::` translation as future work |
| **(d) Whole-crate graph** | rustc + syn + manual | Per-crate build | **Very high** | **Very high** (every dep is a project) | **High per crate, low per graph** | Curated dep sets (e.g. translate `indexmap` minus `serde`) |
| **(e) Hybrid / incremental** | `syn` + rust-analyzer SCIP, dialect-bounded | Dialect as a contract; rest via (c) | **Low** | **Low** | **High within dialect**, **N/A outside** | **Exploration project, single dev, correctness-first — this is the recommended path** |

The (a) → (b) gradient is *who is the source of truth* (rustc vs. cooperating tools). The (b) → (c) gradient is *how much is translated* (whole crate vs. narrow dialect). (e) sits between (b) and (c) and inherits the *strengths* of both while paying the dialect-definition tax.

---

## 6. Recommended exploration roadmap

A single-developer personal project of this shape should ship *something testable every milestone*, and *each milestone should grow the dialect by exactly one axis*. Borrowing c2rust's published pipeline (`transpile → refactor → postprocess`, https://raw.githubusercontent.com/immunant/c2rust/master/README.md) and rust2zig's "v0 → v1 → v2" shape (deduced from the passing-example list in `prior-work.md` §1).

### v0 — Foundations (1–2 weeks)
**Goal.** A reproduction of rust2zig on Zig 0.16 with a single translated example (`gcd` or `sum`). Bound to the existing baseline.

- **Translator skeleton**: Zig module layout `parse.zig` (input is JSON IR, no Rust sidecar yet) → `emit.zig` → `zig fmt` step.
- **Sidecar**: minimal Rust binary that runs `rust-analyzer scip .` against a sample crate and emits a JSON the Zig side reads.
- **Dialect**: `fn`, `struct`, integer arithmetic on `i32`, `if`/`else`. *No generics, no enums, no impl.*
- **Verification**: goldens + `cargo test` ⇄ `zig test` on `gcd`.
- **Acceptance**: `zig build` produces `.zig` from a hand-curated one-fn Rust file; `zig test` matches `cargo test` outputs.

### v1 — Leaf-crate subset (1–2 months)
**Goal.** Translate a `no_std` leaf crate that uses structs, enums, fns, and **generics**, including basics of `Drop` and `Result`. This is the "v1" in the assignment contract; restating:

- **Dialect additions**: enum (incl. `Option`-like), `Result` + `?` (`try` in Zig), `Drop` → `defer`/alive-flag elaboration (rust2zig has the design doc `design/drop.md`), generics → `comptime` (rust2zig: *"Rust generics are translated to Zig comptime (enums, functions, and methods)"*, https://raw.githubusercontent.com/sanxiyn/rust2zig/master/README.md).
- **Boundary**: any std-using or async-using code is forbidden; the input is required to be `no_std`-shape (no `std::*`, no `tokio`, no proc-macros beyond `#[derive(Debug, Clone, Copy, PartialEq, Eq)]` which is excluded for now).
- **Verification**: add `drop` and `drop2` (Drop), `option` (generic enum), `sum` (for-loop), `calc` (`Result` + `?`) to the corpus; all pass `cargo test` ⇄ `zig test`.
- **Build integration**: `build.zig` orchestrates the sidecar via `b.addSystemCommand` (Zig 0.16 docs, "C Translation CLI" + parsing-tooling.md §1c) and links the produced `.zig` modules.
- **Acceptance**: `translate-rust --crate <some-leaves-only-crate>` produces a passing `zig test` for the four new patterns.

### v2 — Traits, methods, references (3–6 weeks after v1)
- **Dialect additions**: traits (light subset: only those resolvable in rust-analyzer hir), inherent methods, `&T` / `&mut T` → `*const`/`*T` with the borrow checker's guarantees *replaced* by Zig's runtime checks (because Roc's manual rewrites prove this is acceptable in production: *"Rust's borrow checker would have caught"* two real UAFs in the Zig port that escaped Zig's checks, https://rtfeldman.com/rust-to-zig, 2026-07-16).
- **Verification**: `geometry` (`&mut self` receiver), `closure` (Fn), `iter` (slice iter), `dot` (`std::iter::zip`).

### v3 — Iterators + collections (2–4 weeks after v2)
- **Dialect additions**: limited `for` over `Iterator` (ranges / arrays / slices / zip / enumerate only — rust2zig's exact dialect; *"For loops over iterators (other than ranges, arrays, slices, zip, and enumerate) are TODO"*). Small collection adapters.
- **Verification**: `bitset`, `hash` (FNV-1a, comes for free with const arrays), `random` (PCG).

### v4 — The seam becomes a feature (2–4 weeks after v3)
- **Boundary upgrade**: ship option (c) as an *escape hatch* — `#[translate(ignore)]` or `no_translate!{}` to mark untranslatable items, which the sidecar turns into `extern "C"` shims. This is option (c) growing organically inside the dialect-driven build, not bolted on.
- **Verification**: cross-check instrumentation per c2rust's design — emit cross-check calls into Zig and Rust, compare at runtime; or just *rely on the borrow checker's pass-through*: leave Rust typed items untranslated and assert the untranslated side compiles its own `cargo test`.

### v5 — LLM / human postprocessing (open-ended)
- **Positioning**: c2rust's `postprocess` is *"an LLM-powered postprocessing tool for additional types of cleanup that are hard to do deterministically. Even though the postprocessor validates the output of LLMs, it can introduce errors; we recommend using it in combination with a robust test suite"* (https://raw.githubusercontent.com/immunant/c2rust/master/README.md). Bun's rewrite — *"Do the rewrite that looks like we transpiled our Zig code to Rust. We can gradually refactor it to reduce `unsafe` usage"* (https://bun.com/blog/bun-in-rust, 2026-07-08) — is the existence proof. We can either adopt this (offer the translator as a *first pass* that an LLM can read), or ignore it.

### v6 — `rustc_driver` escape hatch (only if needed)
- When the dialect outgrows what rust-analyzer can resolve correctly (e.g. when GATs, HRTB, or associated-type bounds become important), promote a single supporting tool to a `rustc_driver` sidecar *for that specific question*. This is the c2rust pattern (their refactor tool uses `rustc_interface` pinned to `nightly-2023-04-15`). Do **not** commit to it as the architecture for v1 — commit to it as an *escape hatch* for v6 and beyond.

---

## 7. Sources

1. **`sanxiyn/rust2zig` README** — primary source for option (b)'s pipeline (`syn` + SCIP), dialect shape, desugar phases, `comptime` generics, shadowing, test discipline (`test.sh` byte-for-byte, `test_test.sh` differential), 12 named examples, current limitations. https://raw.githubusercontent.com/sanxiyn/rust2zig/master/README.md
2. **`immunant/c2rust` README** — primary source for option (a)'s nightly-pin cost, the canonical transpile/refactor/postprocess pipeline, and cross-check availability. https://raw.githubusercontent.com/immunant/c2rust/master/README.md
3. **`immunant/c2rust` `cross-checks/README.md`** — direct quote on the cross-check subsystem (clang plugin + `rustc` plugin + `libfakechecks` + ReMon MVEE). https://raw.githubusercontent.com/immunant/c2rust/master/cross-checks/README.md
4. **`immunant/c2rust` `c2rust-transpile/README.md`** — direct quote on `--emit-build-files`, modular emit, filter by file. https://raw.githubusercontent.com/immunant/c2rust/master/c2rust-transpile/README.md
5. **`layola13/autozig` README** — primary source for option (c)'s FFI shape, "Encapsulated Unsafe", `ZigBox`/`ZigBuffer` lifetime protocol. https://raw.githubusercontent.com/layola13/autozig/main/README.md
6. **`dtolnay/cargo-expand` README** — *"Be aware that macro expansion to text is a lossy process. … There should be no expectation that the expanded code can be compiled successfully, nor that if it compiles then it behaves the same as the original code."* https://raw.githubusercontent.com/dtolnay/cargo-expand/master/README.md
7. **`dtolnay/syn` README** — *"Syn is a parsing library for parsing a stream of Rust tokens into a syntax tree of Rust source code."* https://raw.githubusercontent.com/dtolnay/syn/master/README.md
8. **`rust-lang/rustc-dev-guide` — `rustc-driver/intro.html`** — *"The `rustc_interface` crate provides a low level API to external users for manually driving the compilation process, allowing third parties to effectively use rustc's internals as a library for analyzing a crate or for ad hoc emulating of the rustc driver."* https://rustc-dev-guide.rust-lang.org/rustc-driver/intro.html
9. **`ziglang/zig` 0.16.0 docs** — `zig translate-c` CLI invocation, `@cImport` equivalence, `-target`/`-cflags` discipline, C translation cache. https://ziglang.org/documentation/0.16.0/
10. **`bun.com/blog/bun-in-rust`** — Bun's mechanical-port existence proof, *~1.4M-assertion language-independent test suite*, ~64 Claude agents, $165K LLM cost, 19 known regressions sourced to *"code that's syntactically identical in both languages but semantically different"*. https://bun.com/blog/bun-in-rust
11. **`rtfeldman.com/rust-to-zig`** — Roc's manual rewrite of 300K LoC, allocator-model mismatch, runtime-check differences vs. borrow checker. https://rtfeldman.com/rust-to-zig
12. **`tree-sitter/zig-tree-sitter` README** — *"Needs zig 0.16"* binding for the C runtime used in option (b). https://raw.githubusercontent.com/tree-sitter/zig-tree-sitter/master/README.md

Internal cross-references: `notes/research/parsing-tooling.md` (frontend trade-offs), `notes/research/prior-work.md` (existing-art landscape, lessons, citations pool), `notes/research/idiom-mapping.md` (per-feature Rust→Zig mapping rules). Version anchor: Zig 0.16.0 (released 2026-04-14); rustc nightly (pinned analogues: c2rust uses `nightly-2023-04-15`, rust2zig uses current toolchain via rust-analyzer SCIP).
