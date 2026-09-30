> **Historical research record — not current coverage.** Research date
> 2026-08-17; sources are cited inline and were verified on that date. This
> note records what was investigated then, not what the translator does today.
> Nothing here is a claim that `translate-rust` supports a Rust shape. For what
> the translator actually translates, read the
> [repository README](../../README.md).

# Parsing & tooling: getting a Rust AST + semantic info into Zig

Research date: 2026-08-17. Target: Zig **0.16** (development/master; latest tagged release is **0.15.2**).

Question: *How can a Zig program get a Rust AST plus semantic information (names, types, expanded macros) — i.e. what is the Rust analogue of translate-c's clang dependency?*

Bottom line up front (details and sources below):

- Zig's own `translate-c` is **not** built on the public libclang C API (`clang_parseTranslationUnit`/`clang_visitChildren`) any more. On release **0.15.2** it links clang's **C++** AST API through a Zig shim (`src/clang.zig`) *plus* Zig's own C parser **Aro** for macro text. On **master (0.16-dev)** the clang dependency is **gone entirely**: translate-c moved to `lib/compiler/translate-c/` and is **100% Aro** (Zig's own C frontend). So even Zig's "reference architecture" is migrating off clang; the stable pattern is "authoritative C frontend → semantic AST → emit Zig".
- **There is no stable, published Rust frontend that yields resolved types + expanded macros.** Every option is a trade-off (see table below). The only *complete* semantic answer is rustc itself, which is nightly/unstable (`rustc_interface`/`rustc_driver`, the path c2rust takes for its refactor tool and pays a nightly-pin price for).
- **Recommended architecture**: a **Rust sidecar process** that runs the real Rust toolchain and emits a lossless JSON *semantic IR*; the Zig tool consumes that IR over stdin/file (Zig `build.zig` drives the sidecar via `b.addSystemCommand`). For full correctness use a **pinned-nightly `rustc_driver`** sidecar (the true translate-c↔clang analogue). If nightly is unacceptable, fall back to vendored **rust-analyzer `hir`** crates (types are approximate). Treat `cargo expand` output as a diagnostic, **never** as translation ground truth (lossy, macro-hygiene broken).
- `rustdoc --output-format json` (nightly flag) is the *cheapest* JSON-only analogue — it is literally "a version of the Rust AST" for the public API with resolved types — but it has **no function bodies and no macro expansion**, so it only covers a "bindings" subset of the goal.

---

## 1. Reference architecture: how Zig's translate-c actually works

### 1a. Current state on master (0.16-dev): pure Aro, no clang

On master, `src/translate_c.zig` is gone. The translator now lives in `lib/compiler/translate-c/` as a standalone package (`main.zig`, `Translator.zig`, `MacroTranslator.zig`, `ast.zig`, `Scope.zig`, `PatternList.zig`, ...). The driver parses C with **Aro** and renders Zig:

`lib/compiler/translate-c/main.zig` (driver):
```zig
const aro = @import("aro");
...
var comp = aro.Compilation.initDefault(gpa, arena, io, &diagnostics, std.fs.cwd()) ...
...
var pp = try aro.Preprocessor.initDefault(d.comp);
...
try pp.preprocessSources(.{ .main = source, ... });
var c_tree = try pp.parse();      // -> aro.Tree (C AST)
...
const rendered_zig = try Translator.translate(.{
    .gpa = gpa, .comp = d.comp, .pp = &pp, .tree = &c_tree,
});
```
Source: https://raw.githubusercontent.com/ziglang/zig/master/lib/compiler/translate-c/main.zig

`lib/compiler/translate-c/Translator.zig` (imports — **no `clang`**):
```zig
const aro = @import("aro");
const CToken = aro.Tokenizer.Token;
const Tree = aro.Tree;
const Node = Tree.Node;
const QualType = aro.QualType;
```
Source: https://raw.githubusercontent.com/ziglang/zig/master/lib/compiler/translate-c/Translator.zig:1-16

Master's `build.zig` wires `aro` as a module import, not as a linked clang dependency:
```zig
const aro_mod = b.createModule(.{
    .root_source_file = b.path("lib/compiler/aro/aro.zig"),
});
...
compiler_mod.addImport("aro", aro_mod);
```
Source: https://raw.githubusercontent.com/ziglang/zig/master/build.zig:712-718

So on master, translating C→Zig requires **no clang at all**. (The Zig compiler *binary* still links clang/LLVM for the `zig cc`/C-backend path, but translate-c itself does not.)

### 1b. Recent release 0.15.2: hybrid — clang C++ API + Aro

`src/translate_c.zig` on **0.15.2** imports both clang (C++ API via shim) and Aro, plus a shared module:
```zig
const clang = @import("clang.zig");
const aro = @import("aro");
const common = @import("aro_translate_c");   // shared AST-node translation logic
```
Source: https://raw.githubusercontent.com/ziglang/zig/0.15.2/src/translate_c.zig:7-10

It parses via clang and walks the semantic AST:
```zig
const ast_unit = clang.LoadFromCommandLine(args_begin, args_end, &clang_errors.ptr, ...);
```
and visits declarations/types/layout — e.g. `clang.RecordDecl`, `clang.TypedefNameDecl`, `clang.QualType`, `clang.Type` (`getTypeClass()` → `.Record/.Enum/.Builtin/.Elaborated/...`), `clang.ASTRecordLayout`, `getAlignedAttribute`/`getPackedAttribute`, `clang.Expr.EvaluateAsInt(...)`. Aro's tokenizer is used to read **macro bodies** (`#define` text). The semantic/layout facts (field offsets, alignment, enum sizes, constant evaluation) come from **clang**, not Aro.
Source: https://raw.githubusercontent.com/ziglang/zig/0.15.2/src/translate_c.zig:89-92, :325-343, :744-750, :1712-1732, :2226-2228

### 1c. What it requires to build (build.zig)

`build.zig` links the clang **C++ libraries** (the `clang_libs` list) and LLVM/LLD when building the compiler that embeds translate-c:
```zig
const clang_libs = [_][]const u8{
    "clangFrontendTool", "clangCodeGen", "clangFrontend", "clangDriver",
    "clangSerialization", "clangSema", "clangStaticAnalyzerFrontend",
    "clangStaticAnalyzerCheckers", "clangStaticAnalyzerCore", "clangAnalysis",
    "clangASTMatchers", "clangAST", "clangParse", "clangSema", "clangAPINotes",
    "clangBasic", "clangEdit", "clangLex", "clangRewriteFrontend", "clangRewrite",
    "clangCrossTU", "clangIndex", "clangToolingCore", "clangExtractAPI",
    "clangSupport", "clangInstallAPI", "clangAST",
};
...
for (clang_libs) |lib_name| mod.linkSystemLibrary(lib_name, .{});
```
Source: https://raw.githubusercontent.com/ziglang/zig/master/build.zig:1142-1170 and :855-857

It also needs LLVM/LLD libraries and a C++ standard library (`libc++`/`libc++abi`, or `"c++"`), e.g. build.zig:888.

### 1d. Historical note (correcting the common mental model)

The popular description "translate-c links the *libclang C API*, parses a translation unit, and walks *cursors*" (`clang_parseTranslationUnit`, `clang_visitChildren`, `clang_getCursorKind`, ...) is the **pre-0.11** design. Grepping `src/translate_c.zig` at tags **0.9.0, 0.10.0, 0.13.0, 0.15.2** for those `clang_*` C-API symbols returns **no matches** — Zig dropped the libclang cursor API years ago in favor of clang's C++ AST (via `src/clang.zig` + `src/zig_clang_*.cpp` shims) and, on master, Aro.

### 1e. The takeaway for the Rust analogue

translate-c's essential recipe, in all eras: **(1) hand the C source to an *authoritative C frontend* that resolves names/types/layout/macros, (2) walk its semantic AST, (3) emit Zig source text, (4) let the Zig compiler type-check the output.** The Rust analogue therefore wants an *authoritative Rust frontend* (rustc — see §2.3) feeding a semantic IR. A pure syntax tree (tree-sitter, syn) is *not* the analogue of clang for this purpose: it lacks exactly the semantics translate-c needs.

---

## 2. Candidate Rust front-ends

Legend: **consume** = how a Zig program gets the data; **effort/risk** = relative integration cost & maintenance burden for this project.

### 2.1 tree-sitter-rust — syntax only, embeds as C library

- **What it provides**: a lossless, error-tolerant **syntax tree** (green-tree style) and token stream for Rust. No name resolution, no types, no macro expansion (macro calls appear as token-tree nodes). The runtime is "written in pure C11" and "dependency-free so that the runtime library can be embedded in any application".
  - Quote (https://tree-sitter.github.io/tree-sitter/): *"Dependency-free so that the runtime library (which is written in pure C11) can be embedded in any application"*.
- **Consume from Zig**: the runtime is a C11 library; Zig links C libraries natively (`exe.linkSystemLibrary` / `@cImport`). There is an official **`tree-sitter/zig-tree-sitter`** binding — and it explicitly targets the version this project needs:
  - Quote (https://raw.githubusercontent.com/tree-sitter/zig-tree-sitter/master/README.md): *"Zig bindings to the tree-sitter parsing library. Needs zig 0.16."* Its build.zig example shows `b.dependency("tree_sitter", ...)` + `exe.root_module.addImport("tree-sitter", ...)` and linking a grammar as a C library.
  - The `tree-sitter-rust` grammar (github.com/tree-sitter/tree-sitter-rust) is a `parser.c` C file generated by the tree-sitter CLI; the zig-tree-sitter example links `tree-sitter-zig` the same way (extern `fn tree_sitter_zig() callconv(.c) *ts.Language`).
- **Integration cost**: low — a C dep + small Zig binding, already 0.16-ready.
- **Maintenance risk**: low (grammar + runtime are stable, MIT).
- **License**: MIT (runtime, bindings, and the Rust grammar).

### 2.2 syn + quote — full syntax AST incl. attributes; no resolution/types

- **What it provides**: "a parsing library for parsing a stream of Rust tokens into a syntax tree of Rust source code", rooted at `syn::File`, covering "most stable Rust source code", with **spans** (line/column) and **attributes**. Explicitly no semantics: no name resolution, no types, no macro expansion (invocations remain `Macro` syntax nodes).
  - Quote (https://raw.githubusercontent.com/dtolnay/syn/master/README.md): *"Syn is a parsing library for parsing a stream of Rust tokens into a syntax tree of Rust source code."* and *"Every token parsed by Syn is associated with a `Span` that tracks line and column information back to the source of that token."*
- **Consume from Zig**: needs a **Rust host**. Either a Rust sidecar that parses and serializes to JSON over stdin, or a Rust `--crate-type staticlib` exposing an `extern "C"` surface that Zig links. Syn is not a C library, so it cannot be embedded in Zig directly.
- **Integration cost**: medium (a Rust sidecar + JSON schema).
- **Maintenance risk**: low–medium — syn is stable, semver-respecting, ubiquitous; but the host toolchain (Rust, cargo) becomes a build prerequisite.
- **License**: Apache-2.0 **or** MIT (dual, opt-at-your-discretion).
- **Notes**: the companion `quote` crate is for *generation* (token printing) — irrelevant here except as an escape hatch for emitting Rust.

### 2.3 rustc_interface / rustc_driver — the complete semantic answer (nightly, unstable) — what c2rust does

- **What it provides**: the real compiler front-end as a library. `rustc_interface` "provides a low level API to external users for manually driving the compilation process, allowing third parties to effectively use rustc's internals as a library for analyzing a crate". Driving rustc to/through HIR + typeck yields: **fully resolved names, concrete types, and fully expanded macros** (expansion happens before HIR) — exactly the translate-c/`clang` semantic depth, and the only option on this list that is truly complete.
  - Quote (https://rustc-dev-guide.rust-lang.org/rustc-driver/intro.html): *"The `rustc_interface` crate provides a low level API to external users for manually driving the compilation process, allowing third parties to effectively use rustc's internals as a library for analyzing a crate or for ad hoc emulating of the rustc driver."*
- **Stability / the c2rust precedent**: `rustc_driver`/`rustc_interface` are **nightly-only and change without notice between nightlies**. c2rust (C→Rust) uses rustc internals in its **refactor** tool and pins a specific nightly:
  - Quote (https://raw.githubusercontent.com/immunant/c2rust/master/README.md): *"The other tools, such as `c2rust-refactor`, use `rustc` internal APIs, however, and are thus pinned to a specific `rustc` `nightly` version: `nightly-2023-04-15`. These are also not published to `crates.io`."*
  - Same README: *"`c2rust` and `c2rust-transpile` are installed by default and can be built on `stable` `rustc`."* — i.e. c2rust deliberately keeps the *translator* off rustc internals (stable) and isolates the nightly pin to the refactorer. (c2rust's C *input* frontend is clang/libclang — its clang is the C frontend, not the Rust one.)
- **Consume from Zig**: Rust sidecar binary (built with the pinned nightly) run as a subprocess by `build.zig`, emitting a JSON semantic IR. Rust staticlib embedding of rustc is impractical (rustc is huge); a sidecar process is the sane boundary.
- **Integration cost**: high — build & pin a nightly toolchain; write a rustc driver; design a lossless IR; re-test on every toolchain bump.
- **Maintenance risk**: **high** — pinned nightly is a permanent dependency; every rustc version update can break the driver (c2rust pins a 2023 nightly as evidence).
- **License**: rustc is MIT/Apache-2.0 dual-licensed; its standard library is the same. No copyleft blocker.

### 2.4 rust-analyzer crates (rowan syntax + hir: name resolution, types, macro expansion)

- **What it provides**: rowan (published: github.com/rust-analyzer/rowan) is a **lossless syntax tree** library. The `syntax` crate is the parse layer; the `hir` façade gives a "static, fully resolved view" — name resolution, **type inference**, and **macro expansion** (declarative + proc macros via a `proc-macro-srv` subprocess) all happen in the `hir-*` crates.
  - Quote (https://rust-analyzer.github.io/book/contributing/architecture.html): *"`hir-xxx` crates ... Name resolution, macro expansion and type inference all happen here."* and *"`hir` provides a static, fully resolved view of the code."* and *"If you think about 'using rust-analyzer as a library', `hir` crate is most likely the façade you'll be talking to."*
- **External usability**: the `ide` crate is explicitly "intended for use by various tools", and `syntax`/`hir`/`ide` are declared **API boundaries** — but the `hir-*` implementation crates are *"not, and will never be, an api boundary"*, and these crates are **not published to crates.io** with semver (they live in the rust-analyzer monorepo; only `lib/`-published crates like rowan and `mbe`/`tt`/`proc-macro-*` are independent). Proc-macro support is a known weak point (bridge is unstable and historically broke on some nightlies).
  - Quote (https://rust-analyzer.github.io/book/contributing/architecture.html): *"`ide` uses Rust API and is intended for use by various tools."* and *"these crates are not, and will never be, an api boundary"* (about `hir-*`).
- **Consume from Zig**: Rust sidecar (crates vendored via git dependency) that loads a crate and dumps JSON.
- **Integration cost**: high — the API is large and undocumented externally; must pin a rust-analyzer revision.
- **Maintenance risk**: **high** — no stability guarantee, monorepo churn, proc-macro bridge fragility; you fork rust-analyzer's crates.
- **License**: Apache-2.0/MIT.
- **Correctness caveat**: rust-analyzer's type inference is IDE-grade, **not** guaranteed bit-for-bit equal to rustc's typeck — fine for tooling, risky as ground truth for "correct" output.

### 2.5 rustdoc JSON output (nightly `-Zunstable-options --output-format json`)

- **What it provides**: a per-crate JSON dump of the **public API** with resolved types, spans, attributes, visibility, docs. It is literally a serialized slice of the Rust AST:
  - Quote (https://rust-lang.github.io/rfcs/2963-rustdoc-json.html): *"When you request JSON output from `rustdoc`, you're getting a version of the Rust abstract syntax tree (AST), so you could see anything that you could export from a valid Rust crate."*
  - It is **still unstable** and needs nightly:
  - Quote (https://raw.githubusercontent.com/rust-lang/rustdoc-types/master/README.md): *"This crate contains the type definitions for rustdoc's currently-unstable `--output-format=json` flag. They can be deserialized with `serde-json` from the output of `cargo +nightly rustdoc -- --output-format json -Z unstable-options`."*
- **What it does NOT cover**: function **bodies** are absent (doc API only), and it does **not** expand macros into bodies (macro definitions appear as `Macro` items; invocations are not lowered). IDs are `DefId`s that are opaque and not stable across invocations; there is a `format_version` field for the schema. Private items need `--document-private-items`.
- **Consume from Zig**: **no Rust host required** — `rustc`/`cargo` (nightly) produces a JSON file; Zig parses it directly (a JSON parser in Zig, e.g. `std.json`). This is the *only* candidate whose output Zig can consume with zero Rust code.
- **Integration cost**: low–medium — shell out to nightly rustdoc; implement/borrow a JSON deserializer.
- **Maintenance risk**: medium — schema changes with `format_version`; nightly flag; but the type definitions are versioned and maintained by rust-lang (`rustdoc-types` crate), and it is the format the ecosystem (e.g. `cargo-semver-checks`) already depends on.
- **License**: rustdoc/rustc MIT/Apache-2.0; the `rustdoc-types` crate Apache-2.0/MIT.
- **Fit**: good for the **bindings/API** subset (the part of translate-c that most resembles translating headers); insufficient alone for bodies + macros.

### 2.6 Macro expansion paths: cargo expand / `rustc -Zunpretty=expanded`

- **What it provides**: source-level macro expansion. `cargo expand` is literally a wrapper around the compiler's unstable pretty-print:
  - Quote (https://raw.githubusercontent.com/dtolnay/cargo-expand/master/README.md): *"This is a wrapper around the more verbose compiler command: `cargo rustc --profile=check -- -Zunpretty=expanded`."*
  - Requires **nightly** (or `RUSTC_BOOTSTRAP=1`): `-Zunpretty`/`-Zunstable-options` are unstable flags. It expands both `macro_rules!` and proc macros/derives (the example output shows a `#[derive(Debug)]` fully expanded).
- **Critical caveat — lossy**: expanded text is not guaranteed to compile or behave identically (macro-hygiene leaks):
  - Quote (https://raw.githubusercontent.com/dtolnay/cargo-expand/master/README.md): *"Be aware that macro expansion to text is a lossy process. This is a debugging aid only. There should be no expectation that the expanded code can be compiled successfully, nor that if it compiles then it behaves the same as the original code."*
- **Consume from Zig**: shell out; then parse the expanded source with §2.1/§2.2 to get structure. Still **no type information**.
- **Integration cost**: low (it's just a subprocess + a parser).
- **Maintenance risk**: medium (nightly flag, formatting noise; rustfmt used by default).
- **License**: cargo-expand Apache-2.0/MIT; rustc's pretty-printer under rustc's MIT/Apache-2.0.

### 2.7 Linking Rust into Zig — staticlib vs sidecar

- **Feasibility from `build.zig`**: Zig's build system can run arbitrary external commands, so it can invoke **cargo** directly:
  - Quote (https://raw.githubusercontent.com/ziglang/zig/0.15.2/lib/std/Build.zig:925): `pub fn addSystemCommand(b: *Build, argv: []const []const u8) *Step.Run { ... }` — and `Build.run(b, argv)` for eager execution.
  - Pattern: `b.addSystemCommand(&.{ "cargo", "build", "--release", "--crate-type", "staticlib", ... })`, then link the produced `.a` (e.g. `exe.addObjectFile` / `linkSystemLibrary`). Zig also ships the C runtime, so a Rust `staticlib` (which bundles Rust std) links against Zig's `-lc` for libc.
- **Two consumption shapes**:
  1. **Rust `--crate-type staticlib` with an `extern "C"` surface**: Zig `@extern`/`@cImport` the exported functions. Best for *small* helpers. Rust must export C-ABI functions (Rust types cross the boundary as C ABI only). Building a real front-end (syn/rust-analyzer/rustc) as a staticlib is heavy and awkward.
  2. **Rust sidecar binary emitting JSON over stdin/stdout or a file**: the Rust tool does the semantic work and serializes; Zig parses JSON. This is the recommended shape for a front-end (matches §2.3/§2.4/§2.5, and matches how Zig itself would drive `rustc`).
- **Risk/effort**: staticlib = medium (C-ABI marshalling, linking Rust std + C runtime in a Zig context); sidecar = low-medium (just a process contract + JSON schema).
- Both shapes are common and proven (e.g. `zig-rust-interop` demos, `cargo-zirild` uses Zig as its linker for Rust).

---

## 3. Comparison table

| Option | Syntax | Names resolved | Types | Macros expanded | Consume from Zig | Effort | Risk | License |
|---|---|---|---|---|---|---|---|---|
| tree-sitter-rust | full | no | no | no (tokens only) | C lib + `zig-tree-sitter` (0.16-ready) | Low | Low | MIT |
| syn + quote | full + attrs + spans | no | no | no (invocations kept as nodes) | Rust host (sidecar JSON or staticlib) | Med | Low-Med | Apache-2.0/MIT |
| rustc_interface / rustc_driver | full (HIR) | yes | yes, exact | yes (pre-HIR) | Rust sidecar (pinned nightly) -> JSON IR | **High** | **High** (nightly pin; c2rust pins 2023) | MIT/Apache-2.0 |
| rust-analyzer `hir`/`hir-*` | full (rowan) | yes | yes (approx, IDE-grade) | yes (incl. proc-macros) | Rust sidecar (vendored crates) -> JSON | High | **High** (no semver, unpub, proc-macro bridge) | Apache-2.0/MIT |
| rustdoc JSON (nightly) | public API only | yes | yes | no (items, not expanded) | **Zig parses JSON directly** (no Rust host) | Low-Med | Med (nightly flag; versioned schema) | MIT/Apache-2.0 |
| cargo expand / `-Zunpretty=expanded` | expanded **text** | ~ | no | yes, **lossy** | shell out -> reparse (syn/tree-sitter) | Low | Med (nightly; lossy by design) | Apache-2.0/MIT |

"Effort/Risk" is relative for a small exploration project.

---

## 4. Verdict and recommendation

**Goal**: a tool that must eventually produce *correct, idiomatic* Zig — i.e. it needs macros resolved **and** types.

**Problem**: no single stable, published Rust frontend provides both. The two complete options (rustc internals, rust-analyzer hir) are both unstable; everything stable is partial.

**Recommendation — layered, with the IR boundary as the core design decision:**

1. **Architecture**: a **Rust sidecar process emitting a lossless JSON semantic IR**, driven by Zig `build.zig` via `b.addSystemCommand`, consumed by the Zig tool via `std.json`. This mirrors translate-c's shape (authoritative frontend -> semantic AST -> Zig) and keeps the hard part (generating *idiomatic* Zig) in Zig, decoupled from how the IR is produced.

2. **For correctness (north star)**: implement the sidecar on **`rustc_driver`/`rustc_interface`, pinned to a specific nightly**, following the c2rust precedent. It is the only option that gives exact types + fully expanded macros + hygiene-correct semantics. Accept the permanent nightly-pin cost; isolate it so it is swappable (keep the JSON IR stable). This is the true "clang of Rust".

3. **If nightly is unacceptable**: fall back to **vendored rust-analyzer `hir` crates** (name resolution + types + macro expansion on a stable-ish toolchain). Acknowledge types are IDE-grade (approximate) and the crate API has no stability guarantee — so correctness claims must be validated against the real compiler.

4. **As the first milestone / fallback subset**: **`rustdoc --output-format json`** (nightly) is the *cheapest* route and the only one whose output Zig parses directly with **no Rust host**. It is a true analogue of the "translate the header/API" slice of translate-c (public API, resolved types, spans, attrs, docs). Start there to build & validate the Zig emission pipeline; it just cannot produce bodies or expanded macros, so it cannot be the endgame for full-crate translation.

5. **Never** treat `cargo expand` text as translation ground truth (lossy, hygiene-broken per its own README); use it only for inspection/testing. Use **syn** (sidecar) or **tree-sitter-rust** (`zig-tree-sitter`, already 0.16-ready) for lightweight structural parsing where semantics are not yet needed (e.g. syntax-only passes, or parsing the `cargo expand` output for diagnostics).

**Why not "embed the frontend as a C lib like Zig embeds clang"**: clang exposes a stable C++/C ABI that Zig wraps; rustc has **no stable ABI** and rust-analyzer is not built to be a shared library. A JSON-speaking sidecar is the practical equivalent and avoids the ABI problem entirely.

---

## 5. Sources (primary, verified 2026-08-17)

1. Zig master — `lib/compiler/translate-c/main.zig` (Aro driver: `aro.Compilation`, `pp.preprocessSources`, `pp.parse`, `Translator.translate`). https://raw.githubusercontent.com/ziglang/zig/master/lib/compiler/translate-c/main.zig
2. Zig master — `lib/compiler/translate-c/Translator.zig` (no clang; `const aro = @import("aro");`). https://raw.githubusercontent.com/ziglang/zig/master/lib/compiler/translate-c/Translator.zig:1-16
3. Zig master — `build.zig` (aro module import; `clang_libs` C++ list; linking). https://raw.githubusercontent.com/ziglang/zig/master/build.zig:712-718, :1142-1170, :855-857
4. Zig 0.15.2 — `src/translate_c.zig` (hybrid: `clang.zig` + `aro` + `aro_translate_c`; `clang.LoadFromCommandLine`). https://raw.githubusercontent.com/ziglang/zig/0.15.2/src/translate_c.zig:7-10, :89-92
5. Zig 0.15.2 — `lib/std/Build.zig:925` (`addSystemCommand`). https://raw.githubusercontent.com/ziglang/zig/0.15.2/lib/std/Build.zig:925-928
6. c2rust README (rustc-internal-API tools pinned to `nightly-2023-04-15`; transpile on stable; clang prerequisites). https://raw.githubusercontent.com/immunant/c2rust/master/README.md
7. rustc dev guide — rustc-driver intro (`rustc_interface` as a library). https://rustc-dev-guide.rust-lang.org/rustc-driver/intro.html
8. RFC 2963 rustdoc JSON ("a version of the Rust AST"; format details). https://rust-lang.github.io/rfcs/2963-rustdoc-json.html
9. rustdoc-types README ("currently-unstable `--output-format=json`"; `cargo +nightly rustdoc -- --output-format json -Z unstable-options`). https://raw.githubusercontent.com/rust-lang/rustdoc-types/master/README.md
10. syn README ("parsing a stream of Rust tokens into a syntax tree"; spans). https://raw.githubusercontent.com/dtolnay/syn/master/README.md
11. cargo-expand README (wrapper over `-Zunpretty=expanded`; "lossy ... debugging aid only"). https://raw.githubusercontent.com/dtolnay/cargo-expand/master/README.md
12. rust-analyzer — Architecture book (`hir-*` do "name resolution, macro expansion and type inference"; `hir`/`ide`/`syntax` API boundaries; `hir-*` "never an api boundary"). https://rust-analyzer.github.io/book/contributing/architecture.html
13. zig-tree-sitter README ("Needs zig 0.16"; build.zig usage). https://raw.githubusercontent.com/tree-sitter/zig-tree-sitter/master/README.md
14. tree-sitter intro ("runtime library (which is written in pure C11) can be embedded in any application"). https://tree-sitter.github.io/tree-sitter/

Version anchors: Zig 0.15.2 (latest release) and master/0.16-dev; rustc nightly (current, 2026); rust-analyzer master; c2rust master.
