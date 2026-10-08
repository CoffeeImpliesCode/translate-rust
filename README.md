# translate-rust

`translate-rust` is a research translator that turns a supported subset of Rust
into standalone Zig packages. It analyses a crate, lowers it to a canonical IR
and then to Zig, generates a package, and promotes that package only after it
builds and runs its own tests. Anything outside the supported subset is
refused with a typed error.

The subset is bounded, and the boundaries below are measured, not aspirational.
This is not a general Rust implementation and nothing here should be read as a
claim that it translates Rust.

## Requirements

Zig 0.16.0. In this checkout, use `tools/zig-pinned.sh` instead of `zig build`.
It selects the real toolchain, puts it on `PATH` for child builds, and keeps
caches on local storage. Generated standalone packages use `zig build` with
the same toolchain.

The first build fetches the pinned dependencies from GitHub unless they are
already cached. Crate translation reads Rust source directly; it does not run
Cargo or rustc.

## Input contract

The input crate is assumed to compile. The contract is valid Rust in, faithful
Zig out. Rust has already checked borrowing, so this translator does not include
a borrow checker. Invalid Rust borrow patterns are outside the input contract;
wrong output for valid Rust is a defect, including output that compiles but
computes the wrong value.

## Pipeline and formats

```text
Rust source -> tree-sitter -> frontend -> canonical RustIr -> ZigAST
            -> staged package validation -> the generated package's own
               `zig build test` -> atomic promotion
```

- Canonical wire format **v6** JSON enters the pipeline at `RustIr`. Every
  other wire version is rejected before a package is created.
- Older sidecar JSON is diagnostic inventory only, printed by `--dump model`.
  It is never accepted as translation input.
- `--dump zigast` emits format version 1. Literal array lengths and repeat
  counts are `u64` output metadata, independent of the translator's pointer
  width. They remain unquoted decimal JSON numbers across the full `u64`
  range. Decoding rejects negative or overflowing counts with `BadWireFormat`,
  without clamping or passing them through a float.
- Inferred-record ordering uses fixed-endian node hashing, so canonical
  snapshots do not depend on host byte order.
- IR, diagnostic-model and Zig AST encoders return caller-owned JSON bytes.
  Temporary encoding allocations are released on success and allocation failure.
- Tree-sitter node aggregates cross the Zig/C boundary through pointers and
  output parameters. Aggregate calls stay inside C, avoiding target-specific
  aggregate calling-convention mismatches.
- Recursive generic substitution releases partial owned containers on failure.
  Source nodes and substituted argument types remain borrowed.
- Canonical IR expression and Zig AST decoders release partially decoded owned
  fields on malformed wire data and allocation failure. JSON entry points
  preserve `OutOfMemory` instead of reporting it as `InvalidJson`.
- Frontend IR and decoded Zig AST packages use a caller-owned arena. Keep it
  alive until the last use of the result, then release it.
- Escaped and Unicode characters share one scalar decoder across constants,
  body literals and match patterns. Braced escapes accept underscore separators
  and count hex digits, not bytes. String escapes emit the scalar's UTF-8 bytes.

## Generated package contract

Generated packages register a module with the crate's name. Import that module
through `b.dependency(...).module(...)`, not a checkout-relative source path:

```zig
const library = b.dependency("crate_name", .{
    .target = target,
    .optimize = optimize,
}).module("crate_name");
consumer.root_module.addImport("crate_name", library);
```

Packages that need `r2z-core` ship it under `r2z-core/`. The installed translator
embeds these runtime sources. Generation and consumer builds do not require
the translator's source checkout. Generated dependencies receive the consumer's
target and optimization settings. Standalone builds default to `ReleaseSafe`.

Generated `//!` and `///` comments retain Rust source documentation. A module
comment states the Zig import contract and the ownership contract. A function
comment states its explicit allocator requirement, whether its by-value
runtime-owned arguments transfer, and whether it returns a payload the caller
has to release. Copies do not create independent owners. Returned pointers,
slices and erased interfaces borrow backing storage. Zig does not enforce Rust
privacy, borrowing or move rules.

Those three function sentences are read off the emitted signature rather than
off the source, so each one is checked against the signature it documents:
`src/backend/zig/documentation_test.zig` decodes every pinned
`test/golden/zig_ast/` package into a typed AST and fails when a sentence
survives a parameter or a return type that no longer has the property the
sentence names. Every emitted function, struct, enum and union carries a
comment, and so does every emitted file.

Translated Display implementations expose Zig's native `format` hook for
`{f}` and the runtime's `{}` route. Debug implementations use `formatDebug`
through the runtime's `{:?}` route, without a Display fallback. An inherent
method that collides with a protocol hook gets a distinct name. Generated
callers use that name. Neither native hook asks its caller for an allocator,
so only allocator-free formatter bodies are admitted: a `fmt` body that
needs an allocator is refused with `UnsupportedAllocatingFormatter` rather
than emitted without it. Needing an allocator covers cleanup as much as
allocation — a body that only releases an owned temporary through `deinit`
already asks for one.

Runtime formatting hooks expose `Writer.Error`, not a separate allocation-error tag.
To preserve an allocation-failure cause, a hook must propagate the write failure promptly.
The diagnostic window ends after a successful callback or buffered write progress.
A hook that recovers and later returns its own `WriteFailed` does not retain the earlier allocation cause.

An allocator parameter does not imply a returned error. Cleanup-only
functions keep their plain return type. Allocation failures propagate
separately from the source's Result representation. `Result::ok`,
`Result::err` and `Result::unwrap_err` take the enclosing function's explicit
allocator for that reason alone: the arm the source discards is released
through it, and the arm the source keeps is moved out exactly once.

## Current positive end-to-end paths

- The `mini` source fixture produces a validated standalone package.
- The canonical v6 `mini` wire fixture produces a validated standalone package.
- The `fnv` source fixture translates and runs all 203 original assertions.
- The `compat` fixture stages and validates through the source, canonical v6
  wire, and serialized Zig AST paths. The Zig consumer passes all three.
  The backend moved-result runtime regression also passes.
  The consumer covers casts, callable types, typed iterator ranges, closure state, and module
  references, formatting, `String`/`Cow` ownership, and alternative-specific
  enum captures, heterogeneous tuple types, and constant/expression string
  decoding, plus runtime `Result` projections that release a discarded arm and
  transfer the retained payload, thin raw-pointer address comparisons reached
  through a type alias or a reference, and local runtime owners released when
  their callable returns, transferred into a `Result` payload, or released
  when a later allocation in the same function fails.
- The `wyhash` source fixture translates into a multi-file package and runs all
  9 original assertions across 2 test vectors (`read_rest` and `read64` byte
  sorting).
- The `adler` source fixture translates into a multi-file package and runs all 5
  original test vectors (`zeroes`, `ones`, `mixed`, `wiki`, `resume`).
- The `multimod` source fixture maps each discovered module onto its own emitted
  file (`foo.rs` to `foo.zig`, a nested `foo/bar.rs` to `foo/bar.zig`, and a
  `#[path = "..."]` module to `custom_pub.zig`).
- The `xxhash-rust` source fixture translates into a four-file package
  (`src/root.zig`, `src/utils.zig`, `src/xxh32_common.zig`, `src/xxh32.zig`).
- The `hex` fixture translates with its original `#[cfg(test)]` module.
  Equality operands keep temporary `String`, `Vec`, and owned `Result`
  payloads alive until the comparison finishes, then release them.
  Focused Zig consumers check these cleanup paths with a leak-checking
  allocator. This is not general Rust `Drop` support.
- The untouched default-feature `itoa` source fixture produces a package that builds and runs.
  All four promoted-package consumer tests pass, including 128-bit boundaries and buffer reuse.
- The untouched default-feature `percent-encoding` source fixture translates
  with `std` and `alloc`. Nine Zig consumer tests exercise the six original
  doctest behaviors, the strict and lossy UTF-8 borrowed and owned branches,
  and high-bit ASCII-set removal. They run under the same leak-checking test
  allocator, so a consumer that keeps or drops the wrong buffer is caught.

The last recorded census ran the built CLI over all 36 crates in `test/crates/`:
`./zig-out/bin/translate-rust <crate> -o <fresh dir>`.
This path stages, builds, and runs each generated package.
That historical census recorded **24 of 36 crates translating and running**.
It has not been repeated for the current tree.

The per-fixture paths above are the ones the `test-e2e` program drives.
Their options differ from the census options.
The current `compat` smoke validates all three paths and passes their consumers.
A fresh CLI run promotes `differential`; its historical refusal is no longer current.
The differential run passed 40 consumer tests in Debug and ReleaseSafe.
Both modes matched all 155 native Rust oracle records, including bounded ownership flows.

### Last recorded census refusals

These rows record the historical census, not errors remeasured on the current tree.
The pinned table below describes the separate `test-e2e` contract.

| crate | error |
|---|---|
| `allocating-fmt` | `UnsupportedAllocatingFormatter` |
| `atoi` | `MissingExpressionType` |
| `crc16` | `BuildScriptArtifactUnavailable` |
| `differential` | historical unpinned refusal; the current CLI promotes a package |
| `fletcher` | `ExternalMacroSourceUnavailable` |
| `generic-owner-transfer` | `UnsupportedExternalUse` |
| `guarded-owned-fallthrough` | `GeneratedPackageRunFailed` |
| `leb128` | `UnsupportedExternalUse` |
| `loop-ownership-exits` | `UnsupportedExpression` |
| `seahash` | `UnsupportedPattern` |
| `siphasher` | `UnsupportedExpression` |
| `syn` | `UnsupportedCfgPredicate` |

The historical `guarded-owned-fallthrough` run translated and staged the crate.
Its generated package's own run failed.
The current CLI promotes `guarded-owned-fallthrough`.
Its generated package passes all six native tests in Debug and ReleaseSafe.
These checks include owner release after constructor allocation failure.

The historical `generic-owner-transfer` refusal does not establish a current spelling boundary.
The backend supports both `alloc::vec::Vec` and `std::vec::Vec`.
`differential` proves finite generic flows instantiated with `String` and `Vec`.
This does not prove arbitrary release through a bare type parameter.
The current `generic-owner-transfer` fixture promotes and passes all seven consumer checks in Debug and ReleaseSafe.
Its relay calls use a cleanup-only allocator parameter without an invented error return.
The nested `Vec<T>` case uses the concrete inner vector type.

Sixteen ownership fixtures now have checked-in value-level consumers.
The separate `zero-field-shapes` consumer also checks returned values.
These consumers call fixture functions rather than compare emitted text.
The historical ownership result was twelve passing consumers out of thirteen.
That count is not a new measurement of the sixteen-consumer graph.

The current `struct-field-owner-move` package passes five consumer tests in Debug and ReleaseSafe.
Its owning `Bag.into_label` method takes the explicit allocator needed to release remaining owned fields.

Cleanup-only allocator effects propagate through callers. Temporary cleanup
releases known runtime owners, never arbitrary user methods named `deinit`.
Native error tags have an explicit AST literal, distinct from fields on a user
binding named `error`; ordinary enum payloads remain ordinary values.
Standard IO consumers check advancing a caller-owned byte-slice descriptor,
reading an owned `Cursor<[u8; N]>`, and appending to a caller-owned `Vec<u8>`
through an explicit allocator. `BufReader<R>` uses an inline 8 KiB window.
Its `fill_buf` borrows the unread window, and `consume` advances its position.
Short reads use buffered bytes. Large reads bypass an empty window.
A reader held by value has an independent position. A borrowed reader advances
the caller's state. A cursor beyond its input returns EOF without changing its
position. These checks do not imply support for every `std::io` API.

`r2z.random.fill_bytes_via_next` takes a mutable generator handle and allocates
no memory. It writes generated words in little-endian order.
Each full eight-byte block uses `next_u64`.
A one-to-four-byte tail uses `next_u32`. A five-to-seven-byte tail uses
`next_u64`. An empty destination does not advance the generator.
Native Rust `rand_core` 0.5.1 and Zig checks match bytes and generator state
for lengths 0 through 24, including an unaligned destination at offset 3.
These checks pass in Debug and ReleaseSafe. They prove the runtime helper,
not complete generated-crate or frontend coverage.

`vec_push_owned(T, allocator, *Vec(T), item)` consumes `item` once, on entry,
on both success and error. On allocation failure, it releases `item` and
retains the destination's existing contents.

`vec_repeat_owned(T, allocator, item, count)` consumes `item` once, on entry.
The caller evaluates the source expression once. A zero count releases
`item` without allocation. A count of one moves the original into the result.
For larger counts, the helper makes deep copies, then moves the original into
the last element. On allocation failure, it releases the original, all partial
copies, and the result buffer.

Callers must finish all fallible argument preparation before `takeOwned`
transfers an owner. Cleanup and deep copies cover only known runtime containers:
`String`, `Vec`, `Cow`, `FromUtf8Error`, and active built-in wrappers.
They do not follow borrows or call arbitrary user methods named `deinit` or
`clone`. The private deep-copy helper copies a known `String` without UTF-8
revalidation. These contracts do not provide general Rust `Drop`, `Clone`, or
borrow-checker support.

Standard-library identity, not a type's basename, selects the empty `String::new` intrinsic.
Prelude, `alloc`, `std`, renamed-import, and block-local-import paths keep its zero-argument ABI.
Native Debug and ReleaseSafe consumers check those paths.
A user-defined `String` constructor remains user code, including its returned field value.
The permanent native regression checks source-local type and constructor identity with the exact returned `u32` value `41`.
It does not pin an incidental namespace spelling.

A source function that forwards the empty constructor also keeps a zero-argument ABI.
A cleanup-only local keeps an allocator parameter and plain return type without allocating.
The native checks pass even when the allocator rejects its first allocation.

Owning iterator `map` and `flat_map` stages transfer each owner once.
A mutable `zip` keeps the right-hand `&mut` reference rather than copying its pointee.
Local and parameter `Result.map` and `Result.map_err` consume their receivers.
Cleanup-only paths keep a plain `Result` return and an explicit allocator parameter.
They do not introduce an allocation-error return solely for cleanup.

After a successful guard, multi-owner enum matches move the selected payload leaves.
They release the other owned leaves.
These transfers do not add general user-enum release or foreign-type `takeOwned` support.
Direct and transitive canonical `Copy` bounds preserve allocator-free, by-value primitive calls.
Partial aggregate construction releases prepared owners on allocation failure or an early source `Result` return through `?`.
The differential tuple case checks both exits with allocation-failure sweeps.

Projected optional payload borrows preserve the original storage address and lifetime.
Nested payload moves and single-variant tag tests retain their bounded ownership behavior.
Differential consumers check these reference surfaces and allocation-failure cleanup in both modes.
An unchanged explicit-reference Rust probe also passes native Debug and ReleaseSafe checks.

Signed `/=` and `%=` use truncating division and its corresponding remainder.
For an indexed assignment place, the right-hand side runs before place evaluation.
Each runs once. Differential consumers check negative operands and side-effect order.

The public `ownsTemporaryStorage` and `isOwnedVecCopy` queries are bounded ownership predicates.
A false result does not prove that an arbitrary Rust type implements `Copy`.
Focused public-query and deep-rendering checks preserve exact output bytes in Debug and ReleaseSafe.
Each mode also passes eight allocation-failure runs.

Public `dropTemporary` also releases non-comptime tuple fields, including
known owners inside arrays, optional values, error unions, vectors, and active
tagged-union payloads. It leaves a named foreign struct and borrowed storage
alone. A released runtime `Cow` returns to its empty state. Live consumers
check independent tuple copies, retained borrows, unchanged foreign storage,
and final allocator release in Debug and ReleaseSafe.

All 245 runtime tests pass in Debug and ReleaseSafe. They cover the owned `Vec`
helpers, the `CowSlice` copy paths and their allocation-failure sweeps, and the
`String`/`Cow` releases. They prove those contracts, not complete
generated-code support.

`RustHashType(RuntimeType, layout)` preserves Rust `Hash` source shapes that
native Zig types can erase, such as `str` and `[u8]`.
The descriptor holds compile-time `Type` and `Layout` values without runtime storage.
`RustHashRef` uses a slice view only for a root `str` or slice.
Other roots use a single-item pointer, including a reference to `str`.
The caller retains the borrowed storage.
Live Debug and ReleaseSafe consumers check these views and mutation of the original storage.
These checks prove the descriptor API. Generated `Hash` behaviour is proved
separately: a native Rust driver records the canonical byte trace for every
primitive, slice, `str`, tuple, address and override shape, and the wyhash
corpus crate's generated package builds and runs its own tests against it.

Unused locals with an underscore prefix follow the same rule as other unused
locals. Their initializers still run, including mutation and allocation effects.

An unread parameter is emitted as `_<name>`. Zig rejects a parameter nothing
reads, and unlike an unread local it has no statement to discard it with. The
name keeps its position, so a call site still passes every argument in position.
A name that already begins with `_` keeps the one it has. A `let` that rebinds
a parameter's name shadows it, so the parameter stays unread unless that
initialiser reads it. A read that happens only inside a nested block, an
inlined closure body or a loop payload still counts: the closure reaches the
emitter already inlined at its call site, and a macro has already been expanded.

Bounded runtime-container cleanup covers a `String`, `Vec`, `Cow` or
`FromUtf8Error` binding in the top-level body of a function or test that
needs an allocator. Such a binding gets one deferred `deinit(allocator)`
directly after its `let`, so the release runs when the callable returns and
on its failure path too. The shapes it covers are carried by `compat` — a
`String` mutated in place that lives to the end of its function, two owners
where a failure in the second constructor still releases the first, and an
owner moved into a `Result` payload that is either handed back to the caller or
released through the enclosing allocator — and each runs under
`std.testing.checkAllAllocationFailures`.
Transfers through `Vec` elements, conditional and match values, and loop break
values retain each owner's bytes.
The `Vec<String>` sweep includes later growth failures after owners were appended.

A binding the source hands on is left to whoever took it, and that exclusion
is a syntactic scan of the callable body rather than a proof of Rust move
semantics: a by-value call or method argument, a receiver taken by value, a
`return`, a `let` initializer, a block or branch tail, a loop break value,
the right-hand side of an assignment, and enum, struct, array or `Vec` element
positions each take a binding off the release list. A binding the scan cannot
account for stays unreleased rather than risking a second free. Bindings in
nested block scopes and user type destructor semantics are outside this pass.
This is bounded runtime-owner transfer, not general Rust `Drop` support.

A Rust `*const T` lowers to `[*]allowzero align(1) const T` and `*mut T` to
`[*]allowzero align(1) T`: a pointer of unbounded length and alignment 1, so
a null address is representable and a comparison between two raw pointers
reads addresses rather than pointees. `==`, `!=`, `<`, `<=`, `>` and `>=` are
admitted on thin raw pointers reached through a type alias or a reference; an
ordering comparison of a raw pointer to an unsized pointee stays refused.
Raw pointers with a slice pointee use `[]const T` or `[]T`. The pointee's own
operators never participate in an address comparison.

Finite `f64` literals retain their IEEE 754 bits through source translation,
canonical v6 JSON, and serialized Zig AST JSON. `compat` carries cases for
large values, small values, the largest finite value, the smallest subnormal,
and both signed zeros. The current smoke validates all three package paths.
Numeric JSON tokens wider
than `i64` remain numbers, not quoted strings.

Two frontend repairs are bounded the same way. A tuple literal's element row
is private to that literal, so once every element has been solved, each slot
still standing for a placeholder takes the type its own element solved to; a
slot the source spelled out, a concrete type or a lexical generic such as
`I`, keeps that type, and a slot whose element solved to nothing or to
another placeholder stays open instead of being guessed, so IR validation
refuses it rather than emitting it. `compat` carries it: two tuple literals
in one function reach two different callers with their own contextual element
types intact. The current smoke validates that fixture. A supertrait bound written
as a qualified path resolves in the lexical module of the trait that wrote it,
so a method reaches a generic parameter through the trait that declares it
rather than through a shadowing name in the caller's scope.

`Iterator::any` short-circuits while preserving cursor advancement and mutable
predicate effects; indexed and explicitly dereferenced iterator places are
updated in place rather than copied. Optional payload projection preserves the
order of tuple indexing and repeated reference dereferences. Range-loop smoke
coverage includes negative signed bounds, empty descending ranges, inclusive
signed and unsigned maximum endpoints, and labelled break/continue. Contextual
empty primitive and nominal arrays retain their element identities when
assigned as borrowed slices. Nested enum-payload matches preserve tag checks
and guarded-arm fallthrough. These are measured boundaries, not support claims
for every pattern or iterator shape.

An empty `--features` selection applies the manifest's default closure; `hex`'s
`default = ["std"]` pulls in `alloc`, so its allocation paths are analysed.

### Three structural boundaries, documented not fixed

These three are stated as boundaries because the code answers the question the
other way and a test pins that answer. None of them is a defect claim; each is
the current, deliberately pinned shape of the support.

**A named struct is not an owner type.** The runtime has no release for one:
`dropTemporary` frees nothing for a struct that is not a tuple, and
`supportsOwnedMove` answers false for a foreign named struct, so `takeOwned`
refuses it at compile time rather than leaking at run time. The only move the
runtime can spell is the per-field transfer, and that is what the lowering
emits. A struct's remaining owned fields therefore get no release of their own.
Pinned by `a named struct is not an owner type, and the runtime agrees` in
`src/backend/zig/lower.zig` and by the refused-type list in
`r2z-core/src/alloc.zig`. Widening it needs the struct-level release and the
field-level transfer to arrive together, and the struct-level one cannot arrive
first.

**A local enum with owned payload fields has no element-walk release.** The
element walk covers a tuple, an array, an `Option`, a `Result` and a `Vec` whose
element owns storage. A locally declared enum is none of those, so an owned
payload standing in a variant has no general runtime release.
The passing `enum-variant-owner-move` consumer proves bounded explicit payload transfers and cleanup.
It does not add a general element-walk release for user enums.

**A zero-variant enum cannot be represented.** `emit.zig` writes
`const Name = enum {\n};`, which no Zig version accepts, so the Zig AST
validator refuses the declaration with `EmptyTranslatedContainer` rather than
emitting a package that will not compile. A `match` over such an enum refuses
with `MissingVariantDefinition`.

## Refusals

The legacy wire corpus never reaches analysis: every payload except
`test/mini.json` carries a `format_version` of 2, 3 or 60, and the canonical v6
boundary rejects all three. That covers `fnv`, `fletcher`, `hex`, `wyhash`,
`adler`, `xxhash-rust`, `seahash`, `crc16`, `atoi`, `leb128`, `itoa`,
`siphasher`, `percent-encoding` and `syn`. `test/mini-rustdoc.json` is rejected
with `UnsupportedWireVersion` by name.

Six source fixtures have exact construct-refusal pins in `test-e2e`.
A change in one of these typed errors fails the test.
`siphasher` has a separate refusal-and-no-publication check, without an exact error pin.
The seven source refusal checks describe that program's options, not a new census.

| fixture | error | reason |
|---|---|---|
| `allocating-fmt` | `UnsupportedAllocatingFormatter` | a `Display` body that needs an allocator cannot use the native `format` hook |
| `fletcher` | `ExternalMacroSourceUnavailable` | it has no `macro_rules!` and no dependencies at all. `src/lib.rs:66` writes `extern crate quickcheck;` under `#[macro_use]`, and three `quickcheck! { … }` bodies follow inside its `#[cfg(test)] mod test`. `quickcheck`'s source is not in this repository, so `identifyMacro` returns `.custom` and the expansion is refused. The macro is reached by `extern crate` plus `#[macro_use]`, not through any `use`, and the checksum tables are ordinary computed values rather than macro output |
| `crc16` | `BuildScriptArtifactUnavailable` | its `build.rs` table is an artifact no translation run can have produced; build scripts are not executed |
| `leb128` | `UnsupportedExternalUse` | `tests/quickchecks.rs` is never analysed — a Cargo integration target is not reachable from the manifest root, which follows `mod` declarations only — and `quickcheck` never becomes a reachable root because `pipeline.zig:1063` builds `graph.Crate.deps` from `manifest.dependencies` alone, so a `[dev-dependencies]` entry is never one. What is actually refused is the bare `use std;` at `src/lib.rs:246`, and the test *pristine leb128 refuses on `use std;` alone, and quickcheck is never analysed* in `src/frontend/ts_ext_test.zig` pins exactly that |
| `seahash` | `UnsupportedPattern` | lowering a struct pattern that binds more than one field |
| `atoi` | `MissingExpressionType` | the BACKEND, not the frontend: `driver/pipeline.zig` validates before it lowers, so no node is refused by the analysis and the emitter is the stage that gives up, on an expression whose type it could not read |

The current `siphasher` CLI run reports `UnsupportedExternalUse` and publishes no package.
That observed external-use gap is not an exact construct-error pin.
The previous generic-metadata pin described an invalid IR producer bug, not a valid source boundary.
The backend now accepts canonical nested source primitive and blanket-implementation containers.
It retains non-extern, strict canonical identity, and reciprocal membership checks.
A native regression checks the returned value `7`.

Each row records where coverage stops, and the translator refuses rather than
emitting wrong Zig. That is not an exemption: wrong output for valid Rust is a
defect wherever it appears, and these fixtures are only pinned so that a silent
change of error is visible. A crate leaves the table only by actually
publishing a package that a consumer builds and runs. `syn` has no pinned
refusal row. Its last recorded census error was `UnsupportedCfgPredicate`.
That historical result is not a current-tree measurement.

Cargo dependencies enter `RustIr` as metadata only. The translator does not
translate dependency crates. Macro expansion, trait resolution, and ownership
semantics cover bounded subsets; standalone source trait declarations remain
unsupported. Nothing here promises general Rust support or complete Rust
semantics.

Macro repetition lookups binary-search the captures recorded by the matcher,
without a second allocated index. The 16,384 emitted-token limit is unchanged;
large argument lists do not require a full capture scan for each output value.

## What these paths do not show

The list above describes fixtures, not a coverage rate for Rust.
Read "translates" as "this fixture translates", not "this Rust shape translates".
The last recorded census covered 36 repository crates.
It recorded 24 successes and 12 refusals. These counts are historical.
Neither those counts nor the current focused smoke prove general Rust support.

The census stages, builds, and runs a generated package for every crate.
`--dump rustir` analyzes with `include_tests` off. Translation enables it.
A crate can dump clean IR and still refuse translation.
The translation path, not a dump, determines package coverage.

The fixture sources and tests match these published archives byte-for-byte:
[wyhash 0.4.0](https://static.crates.io/crates/wyhash/wyhash-0.4.0.crate),
[adler 1.0.2](https://static.crates.io/crates/adler/adler-1.0.2.crate), and
[xxhash-rust 0.8.15](https://static.crates.io/crates/xxhash-rust/xxhash-rust-0.8.15.crate).
Only added provenance comments differ in their normalized `Cargo.toml` files.
Earlier coverage used trimmed modules and changed feature defaults.

- `wyhash` includes its `traits` module and `rand_core` dependency.
  The commented alternative range loop in `read_rest` also exists in the
  [published archive](https://static.crates.io/crates/wyhash/wyhash-0.4.0.crate).
  Its upstream comment states that the alternative changes hash byte ordering.
  The fixture keeps the original algorithm.
- `adler` keeps the upstream `default = ["std"]` feature closure.
  This selects the `adler32<R: BufRead>` API and its buffered-reader test.
- `xxhash-rust` declares no default feature. Its default configuration produces
  a valid empty registered module, not a translation refusal.
  Select `--features xxh32` to translate the 32-bit algorithm.

### Fixture provenance

The corpus contains 14 upstream-derived fixtures and 22 project-authored fixtures.
The upstream group has 13 registry snapshots and one Fletcher GitHub snapshot.
Each upstream fixture's `Cargo.toml` note records its primary URL and comparison date, 2026-10-08.
The notes describe manifest changes, omitted files, and retained original manifests.
`compat` and `multimod` are project-authored fixtures, not upstream snapshots.

All 11 retained `Cargo.toml.orig` files match their archives byte-for-byte.
They are upstream source manifests, not Cargo's normalized registry manifests.
The separate `Cargo.toml` files retain the normalized manifests with provenance comments.
`leb128` and `syn` omit `Cargo.lock`.
`fnv` and `hex` use reduced local manifests. `hex` also omits serde source, benchmarks, and integration tests.

Fletcher's `1.1.4` version is a fixture label, not a published registry release.
Its source exactly matches [jbangelo/fletcher commit `2d941b4c26061fd3b057485723d4df92315a757d`](https://github.com/jbangelo/fletcher/tree/2d941b4c26061fd3b057485723d4df92315a757d).
That commit's source manifest declares version `1.0.0`.
The [fixture note](test/crates/fletcher/Cargo.toml) records the local manifest changes and omitted files.

### Golden coverage

`test/golden_test.zig` assigns one comparison contract to each golden fixture:

| fixture | golden contract | byte comparison |
|---|---|---|
| `mini` | full canonical RustIR, ZigAST, and emitted source | all three layers |
| `compat`, `wyhash`, `adler`, `multimod` | emitted source | every emitted source file |
| `fnv`, `hex` | typed AST and public API contract | none |

The typed fixtures must analyze, validate, lower, and emit valid packages.
Their typed assertions check declarations, imports, module maps, and public APIs.
Their contracts do not pin RustIR row indices or generated label numbers.
The retained `fnv` and `hex` ZigAST files supply decoded documentation-contract inputs.
They are not RustIR byte pins or current-output byte comparisons.
No further golden deletion is required for these typed contracts.

## Commands

```bash
# Build the CLI into zig-out/bin/translate-rust.
tools/zig-pinned.sh
tools/zig-pinned.sh run -- --help

# Unit tests, one artifact per module, plus the dead-source guard.
tools/zig-pinned.sh test
tools/zig-pinned.sh check-sources   # fail when a src/**/*.zig file reaches no test root
tools/zig-pinned.sh test-rust       # focused parser and node-navigation checks
tools/zig-pinned.sh test-frontend
tools/zig-pinned.sh test-backend
tools/zig-pinned.sh test-frontend -Dfrontend-llvm=true   # LLVM instead of the self-hosted backend

# Translate supported Rust source to a standalone package.
tools/zig-pinned.sh run -- test/crates/mini -o zig-out/r2z-mini

# Emit Zig source from canonical v6 wire JSON.
tools/zig-pinned.sh translate -- test/mini.json

# Inspect the canonical frontend and backend representations.
tools/zig-pinned.sh run -- --dump rustir test/crates/mini
tools/zig-pinned.sh run -- --dump zigast test/crates/mini
tools/zig-pinned.sh run -- --dump-types test/crates/mini
tools/zig-pinned.sh run -- --dump-names test/crates/mini
tools/zig-pinned.sh run -- --dump-infer test/crates/mini

# Inspect legacy sidecar inventory. This does not translate it.
tools/zig-pinned.sh run -- --dump model test/fnv.json

# Translate a fixture and check that staged promotion publishes the package.
tools/zig-pinned.sh source

# End-to-end: translate the complete source fixtures, run each consumer, and
# reject the incomplete wire and source fixtures against their pinned errors.
tools/zig-pinned.sh test-e2e
tools/zig-pinned.sh test-crates

# The three verification commands.
tools/zig-pinned.sh test install          # unit suites and CLI build
tools/zig-pinned.sh test-crates            # translate, stage, build and run the crate corpus
tools/zig-pinned.sh generated-corpus -- --output "<absolute-local-dir>"

# Two machine checks over the documentation itself.
tools/zig-pinned.sh check-commands   # every command this README names is a published step
tools/zig-pinned.sh check-corpus     # every crate fixture under test/crates/ has a row

# Regenerate the checked-in wire fixture and source goldens from validated
# canonical IR. Run these only when the emitted Zig is meant to change.
tools/zig-pinned.sh generate-mini-wire
tools/zig-pinned.sh generate-mini-golden
tools/zig-pinned.sh generate-fnv-golden
tools/zig-pinned.sh generate-compat-golden
tools/zig-pinned.sh generate-wyhash-golden
tools/zig-pinned.sh generate-adler-golden
tools/zig-pinned.sh generate-multimod-golden
tools/zig-pinned.sh generate-hex-golden

# Generated API reference.
tools/zig-pinned.sh docs
```

`<absolute-local-dir>` must be absolute, outside this repository, and on a
filesystem that supports atomic writes. The pinned runner applies the same
placement rule.

### Verification status

The final native verification command passed **60 of 60 steps** and **1618 of 1618 tests**:

```bash
tools/zig-pinned.sh test test-crates check-commands check-corpus --summary all -j2
```

The test total includes all 18 golden tests, 430 backend tests, and 583 frontend tests.
All sixteen ownership consumers and the separate `zero-field-shapes` consumer passed in Debug and ReleaseSafe.
Differential passed 40 tests in both modes and matched all 155 Rust records.
The six exact source construct-refusal checks and siphasher refusal/no-publication check passed.
The native graph also passed its wire refusals and all four promoted itoa consumer tests.
No step asserts a test count. Steps check exit status, package layout, and exact pinned refusal errors.

Source formatting checks passed for `build.zig`, `src`, `r2z-core/src`, and top-level test Zig files.
The recursive formatting check, including emitted goldens, exited with status 1 on four golden files.
The 18 golden tests pass. These results do not establish that every golden follows the formatter's style.

The earlier default gate attempt passed 1616 unit tests but did not complete.
It reported 53 ziglint issues, two zlint warnings, and 608 zwanzig findings.
The zwanzig total includes 160 analysis-limit findings.
The advisory zbc check reported integer overflow and exited with status 134.
No baseline establishes whether these findings existed before this work.
The default 53-target cross run stopped with TERM status 143.
Its receipt contains 41 completed target entries and 12 interrupted entries.
It did not complete, so no all-target or all-green result is claimed.

`tools/zig-pinned.sh check-commands` fails when a command named in this README,
in `AGENTS.md`, or in a pinned script's own usage header names a step the build
graph does not publish. Every `tools/zig-pinned.sh <step>` invocation below is
therefore checked, not merely conventional.

`tools/zig-pinned.sh check-corpus` fails when a crate fixture under
`test/crates/` has no row, or when one file calls a crate positive that another
file refuses. The rows themselves are `corpus_rows` in `build.zig`, and each row
names the node that owns it.

### The corpus receipt

`generated-corpus` always writes `corpus-rows.json` beside its `aggregate/`
directory, on the way out of a failing run as well as a passing one — a run that
printed a failure count and left nothing behind gave an operator a number and no
rows. The file carries one entry per row including the FAILED ones, naming the
error a red row failed with.

Each row is classified `executed`, `compile_only` or `not_staged`, always with
a reason beside the verdict:

- `executed` — an assertion somebody ran in this row: either the package's own
  translated `#[cfg(test)]` module, or a checked-in consumer that binds the row
  and calls into it.
- `compile_only` — the row exists to prove a configuration compiles. This is
  legal only for a configuration that publishes no API at all, so there is no
  value to call; anything else that merely compiled without a value assertion is
  reported as such rather than folded into coverage.
- `not_staged` — the row never reached a promoted package, so no claim is made
  about it at all. It appears in the file so the row count reconciles; it is not
  coverage.

Run the native Rust corpus oracle separately:

```bash
tools/rust-corpus-oracle.sh \
  --scratch "<approved-local-scratch>" \
  --output "<fresh-local-output>" \
  --strict-prerequisites
```

Replace both placeholders with absolute paths outside the repository on
approved local storage. Do not use NFS, `/tmp`, `/var/tmp`, or `/dev/shm`.
The runner copies checkout fixtures to local scratch and compares each staged file's hash with its checkout file.
It checks the checkout again after the run.
These hashes prove transport equality, not equality with upstream archives.
Cargo writes only to local scratch.
The runner does not delete files automatically and refuses existing receipt files.

The oracle records two distinct feature closures: default and explicit
`xxh32`. Both native oracle runs and all original unit, integration, and
documentation rows passed with strict prerequisites.
Native checks also passed root-package version and staging-hash checks.
Cargo metadata supplies root-package versions.
The runner checks three pinned VCS metadata strings: `adler`, `wyhash`, and `xxhash-rust`.
Those strings do not prove source-tree equality.
The runner does not use `cargo pkgid` or scrape manifest text for versions.

The `xxhash-rust` documentation check uses a separate published metadata
profile: `xxh32`, `const_xxh32`, `xxh64`, `const_xxh64`, `xxh3`, and
`const_xxh3`, without `std`. This is not a default-feature or `xxh32`-only
documentation pass. These native results do not prove generated positive
crates, complete frontend or ownership coverage, or the target matrix.

`tools/zig-pinned.sh test` covers the unit suites; `test-e2e` and
`test-crates` translate, build, execute, and refuse.
`test-crates` also runs the `r2z-core` runtime package's own test
suite. `generated-corpus` stages a fresh package per corpus row and writes the
`corpus-rows.json` receipt described above. None of these steps asserts a test
count; they assert exit status, the generated package layout, the exact typed
error of every pinned refusal, and — for the corpus receipt — that the row
classifications agree with the graph they were built from.

Temporary corpus packages and nested runtime build caches use the build cache,
not repository output directories. The pinned runner keeps that cache on local
storage.

`cross-test.profile.sh` requests all 53 Zig 0.16.0 Tier 1/2 targets from the
[published support table](https://ziglang.org/download/0.16.0/release-notes.html#Support-Table).
The external `cross-test` tool compiles the full translator test graph for each
target. Foreign Linux artifacts use static linkage for QEMU without guest libc;
other targets keep Zig's default linkage. The tool executes checks where a
runner exists and reports other rows as compile-only. The CLI shell contract
and compiler-driven e2e program execute only on the native target.
Generated-package corpus checks remain native.

## Repository layout

```text
build.zig          # build graph for the CLI, tests, fixtures, and corpus checks
build.zig.zon      # package manifest and pinned dependencies
src/
├── main.zig       # CLI and diagnostic dump modes
├── ir/            # canonical target-independent RustIr and v6 JSON boundary
├── frontend/      # tree-sitter ingestion and Rust analysis
├── backend/zig/   # ZigAST lowering, source emission, and package generation
├── driver/        # source and wire orchestration with staged promotion
└── model/         # legacy sidecar diagnostic inventory
r2z-core/          # generated-package runtime compatibility layer
test/              # fixtures, snapshots, integration tests, and rejection corpus
vendor/            # vendored tree-sitter-rust grammar
```

## Working on this tree

Maintenance constraints that are easy to get wrong:

- **Run file-system tests from local storage.**
  Zig 0.16 `std.testing.tmpDir` creates `.zig-cache/tmp` relative to the working
  directory. Compiler cache flags and `TMPDIR` do not change that location.
  For an NFS checkout, use a UID-owned local source copy with the same pinned
  `zig-pkg` dependencies. Check every copied file before accepting its results.
  Start the devenv shell from that copy. Keep compiler caches and generated
  output on local storage too.

- **Keep `(void)` in the vendored scanner.**
  `vendor/tree-sitter-rust/scanner.c` is hand-written;
  `vendor/tree-sitter-rust/parser.c` and `tree_sitter/parser.h` are generated
  and declare `tree_sitter_rust_external_scanner_create` with a `(void)`
  parameter list. Writing it as a legacy empty list `()` still compiles, but it
  is a different C function type, and optimized builds trap inside it on
  clang's `-fsanitize=function` mismatch trap. Change the generated files only
  through the grammar's own generator.
- **Regenerate the Rust lexer from its checked-in grammar.**
  The vendored grammar is based on tree-sitter-rust v0.24.2, with Rust Unicode
  escape separators accepted in characters and strings. With tree-sitter CLI
  0.26.8, run `tree-sitter generate --abi 15 --output . grammar.js` from
  `vendor/tree-sitter-rust/`. That directory supplies `tree-sitter.json`;
  another working directory can silently select an older ABI.
- **Hand-built graph fixtures own their segments.**
  `Graph.deinit` frees the path array *and* every segment in it. A fixture that
  duplicates only the outer array leaves freed literals behind, which read back
  as `0xAA` in Debug and produce failures that look like codegen bugs but are
  use-after-free. Duplicate each segment and the local name, with `errdefer`
  cleanup; `addExternalUseTestAlias` in `src/frontend/ts_ext.zig` is the
  reference. The same class of mistake applies to a type table that inference
  resolves in place: the store has to be a `var`, not a `const`, because
  resolution writes through it (see the `chained raw pointer cast resolves a
  wildcard pointee` test in `src/frontend/infer_test.zig`).
  Module item slices stored in `CrateGraph` must also use the graph's allocator.
  A returned fixture must not borrow runtime-built local arrays. Duplicate those
  arrays into the caller's allocator; literal-only comptime constants have
  static storage and do not need a copy.

Golden files under `test/golden/` contain canonical RustIR, ZigAST, or emitted Zig.
Use the coverage table above to identify each file's comparison contract.
Regenerate snapshots through the validated generators, not by hand.
When the intended output changes, change the translator, regenerate, and read the diff.
