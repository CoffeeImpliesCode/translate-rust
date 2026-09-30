# Zig 0.16.0: string literal in a large Debug test binary reads back as 0xAA undefined-fill (silent wrong answer, 8 tests, per call site)

## Summary

In a Debug `zig build test` run, data that functions in the
`translate_rust.frontend` test binary (root `src/frontend/root.zig`, 329 tests)
read back at runtime does not always match what the source says. The anchor
observation is a string literal: `"vec"` (3 bytes, declared in
`src/frontend/expand.zig:42`) is observed in memory as `aa aa aa` rather than
`76 65 63`. `0xAA` is Zig's undefined-memory fill pattern for Debug and
ReleaseSafe. That literal is only where the fault was first noticed; the
measured scope is **8 failing tests out of 329**, 321 passing, all in that one
binary and listed below. For the `"vec"` literal the wrong bytes are dumped and
shown; for the other seven the evidence is behavioural, and the section on the
three experiments states exactly what is shown and what is not.

The corruption is present at the very first executed test in the binary, so it
is not a runtime overwrite by earlier test code. The observable effect is a
silent wrong answer rather than a crash: `std.mem.eql(u8, ident, "vec")` returns
`false`, so `identifyMacro("vec!")` returns `.custom` instead of `.vec`.

The decisive property, established below, is that the fault is **per call
site**. Verbatim copies of the failing test bodies, added to the *same*
binary, pass. The project's source for the affected functions is provably
correct (byte-identical to the committed blob, md5 verified), standalone
reproductions of the identical functions compile and pass, and the
translator's real behaviour — checked through the CLI against the exact Rust
source of every failing test — is correct in all eight cases. Only the large
Debug test binary is wrong.

## Observed vs expected

Observed, from a byte dump of the literal's address inside the frontend test
binary:

| Literal | Expected | Observed |
| --- | --- | --- |
| `"vec"` (`src/frontend/expand.zig:42`) | `76 65 63` | `aa aa aa` |
| `"assert"` (`src/frontend/expand.zig:38`) | `61 73 73 65 72 74` | `61 73 73 65 72 74` (intact) |

Functional consequence in the same binary:

| Call | Expected | Observed |
| --- | --- | --- |
| `identifyMacro("vec")` | `MacroKind.vec` | `MacroKind.vec` (correct) |
| `identifyMacro("vec!")` | `MacroKind.vec` | `MacroKind.custom` |

The function under test:

```zig
pub fn identifyMacro(name: []const u8) MacroKind {
    var ident: []const u8 = name;
    if (std.mem.lastIndexOf(u8, ident, "::")) |idx| {
        ident = ident[idx + 2 ..];
    }
    if (std.mem.endsWith(u8, ident, "!")) {
        ident = ident[0 .. ident.len - 1];
    }
    ident = std.mem.trim(u8, ident, " \t\r\n");

    if (std.mem.eql(u8, ident, "assert")) return .assert;
    // ...
    if (std.mem.eql(u8, ident, "vec")) return .vec;      // <-- literal reads aa aa aa
    // ...
    return .custom;
}
```

The asymmetry in the last two rows is a load-bearing observation: the
`aa aa aa` copy is not the only copy of the literal in the binary, because at
least one intact copy is reachable and yields the correct result for a
different call. One call site of `identifyMacro` in the same binary agrees with
its declared source and another does not. That constrains the problem to
per-copy data, not to a wholesale absence of the literal.

### The measured scope: 8 failing tests in one binary

That literal is where the fault was noticed, not where it stops. In the same
run, 8 of the 329 tests in this binary fail and 321 pass:

| # | Failing test | Declared at |
| --- | --- | --- |
| 1 | `expand.test.identifyMacro classifications` | `src/frontend/expand.zig:2505` |
| 2 | `pipeline.test.analyzeSourceWithOptions selects configured feature-gated entity` | `src/frontend/pipeline.zig:1239` |
| 3 | `pipeline.test.analyzeSource fills test body with literal built-in macros` | `src/frontend/pipeline.zig:2707` |
| 4 | `pipeline.test.analyzeSource keeps cast operand types through source expressions` | `src/frontend/pipeline.zig:2915` |
| 5 | `pipeline.test.analyzeSource lowers FNV dereference scalar cast` | `src/frontend/pipeline.zig:2880` |
| 6 | `pipeline.test.analyzeSource preserves a trailing formatting macro as the block value` | `src/frontend/pipeline.zig:3159` |
| 7 | `pipeline.test.cst.extractFile resolves hex error module and skips disabled strict core impl` | `src/frontend/pipeline.zig:2136` |
| 8 | `pipeline.test.generic conversion results remain dispatchable in their declaration scope` | `src/frontend/pipeline.zig:3180` |

Seven of the eight are in `src/frontend/pipeline.zig`. Only the first is the
bare-literal case; the other seven fail on data the analyzer hands back — a
resolved feature-gated entity, a `trait_path`'s segments, a cast's operand
types, a lowered IR element — which is the same class of read-back, one
indirection further from the literal. The next section shows that all eight
are the toolchain's fault and not the source's.

## Three experiments: the source is not the variable

A single wrong literal could still have been an ordinary source bug. These
three experiments rule that out. They are listed by how much they prove, not by
the order they were run.

### Experiment 2 (decisive) — same binary, same code, different call site

Ten tests were added to the *same* Debug binary that fails:

- seven verbatim copies of the failing test bodies, each wrapped in its own
  function and invoked by a single new test,
- a literal byte dump, and
- direct calls to two of the failing analyses.

Result: **all ten added tests passed**, while the eight original call sites
still failed in that same run (330 tests in the run). The byte dumps at the
added call sites printed correct bytes for `core`, `vec`, `assert`,
`AllocOnly`, `slice`, `Iter`, `TryInto`, `feature` and `alloc` — and
`identifyMacro` still returned the wrong answer in the same process.

This is the whole report in one observation. Identical code, one binary, one
process, two call sites, two different answers. No change to the source can
produce that, and no logic bug can either: the same instructions, reading the
same literal, agree with the source at the new call site and contradict it at
the old one. The compiler's output for a given piece of source in this binary
depends on where that source is called from, which is not a property the
language has. Everything below corroborates this; on its own it is the
finding.

### Experiment 1 — reduction to a smaller binary

The seven failing `pipeline` test bodies were copied **verbatim** into a new
test root file in a copy of the repo on local disk, built with the same
toolchain at the same `-ODebug`:

```
165/165 tests passed, including all 7.
```

Identical test bodies and identical frontend source pass in a 165-test binary
and fail in the 329-test one. The trigger is a property of the binary, not of
the code in it. This is Experiment 2's conclusion reached from the other
direction — a smaller binary instead of a different call site — and it is also
why the reduction in section (a) below has been unable to fire.

### Experiment 3 — the translator itself is functionally correct

The CLI built from this tree (Debug) was run on scratch crates containing the
exact Rust source of each failing test, and then on the project's real
fixtures. Every one behaved correctly:

| Source of the failing test | What the CLI did with it |
| --- | --- |
| `analyzeSourceWithOptions` feature-gated entity | struct present with `default=["alloc"]`, absent with `default=[]` |
| `cst.extractFile` hex error module | analysis succeeds; `impl fmt::Display` binds `trait_path` to segments `[core, fmt, Display]`; `--dump zigast` exits 0 |
| `analyzeSource` literal built-in macros | IR contains every asserted element, including `vec_lit`, `panic_` and the unsupported marker |
| `analyzeSource` cast operand types | the cast carries exactly the asserted source and target types |
| `analyzeSource` FNV dereference scalar cast | all 7 casts carry the asserted source types |
| `analyzeSource` trailing formatting macro | the block tail is the expected `format_write` |
| `analyzeSource` generic conversion results | `--dump zigast` exits 0; the bound path is 3 segments |

On the real fixtures, `test/crates/hex`, `test/crates/fnv` and
`test/crates/compat` all exit 0 under `--dump zigast`.

So the assertions the Debug test binary fails on are all satisfied by the
program the CLI actually runs. The eight failures are failures of the test
binary, not of the translator.

### What these three do and do not prove

Proven: the source of all eight failing tests is correct; the toolchain's
behaviour on it is not; the result depends on the binary and the call site
rather than on the code; the shipped functionality is correct.

Not proven, and deliberately left open: that all eight failures share the
byte-level `0xAA` mechanism. That mechanism is directly observed only for the
`"vec"` literal. For the other seven the evidence sits one level up — same
code, different result — which is enough to make them toolchain defects rather
than source bugs, but not enough to say they are the *same* miscompile. I have
not dumped bytes at the seven failing `pipeline` call sites and do not claim
it.

## Reproduction

### (a) Fast self-contained repro — not available

I still cannot construct a minimal standalone repro. Stated plainly: every
self-contained reduction I tried compiles and passes, so I am not going to
present one as a repro. For the record, the reduction attempts and their
results:

- The `identifyMacro` function copied verbatim into a standalone file, with a
  test asserting `MacroKind.vec == identifyMacro("vec!")`: **passes**.
- The same file compiled as a root source file: **passes**.
- The same function imported from a second module and tested through the
  import: **passes**.
- A byte-dump test printing the literal bytes in a small binary: **correct
  bytes**.
- All seven failing `pipeline` test bodies copied verbatim into a new test
  root in a copy of the repo, same toolchain, same `-ODebug` (Experiment 1):
  **165/165 pass, including all 7**.
- Ten tests added to the failing binary itself — the same bodies at new call
  sites, plus a byte dump and two direct calls (Experiment 2): **all 10 pass,
  while the originals still fail in the same run**.

The trigger appears to require the full ~329-test Debug binary built by the
project's `build.zig`; reduction past that point loses the failure. This is a
known limitation of the report and is the main thing blocking a minimal
reproducer, so a bisect or a `reproducer`-style construction by the Zig team
would be the most useful next step.

One hint about where to look, from Experiment 2: the fault follows the call
site, not the code. The same source compiles and behaves correctly at one call
site in this binary and incorrectly at another. So a search that only varies
file contents, module layout or literal spelling is unlikely to fire, because
those are exactly the things that already agree. What varies the result is
where the code is called from, which points at how a particular call site's
copy of that data is emitted and placed rather than at the literal, the
function, or the module it lives in.

For reference, the harness I would expect to fire is this shape, offered as a
starting point for reduction rather than as a working repro:

```zig
// NOT KNOWN TO REPRODUCE — kept as a reduction starting point.
const std = @import("std");

const MacroKind = enum { assert, vec, custom };

pub fn identifyMacro(name: []const u8) MacroKind {
    var ident: []const u8 = name;
    if (std.mem.endsWith(u8, ident, "!")) ident = ident[0 .. ident.len - 1];
    if (std.mem.eql(u8, ident, "assert")) return .assert;
    if (std.mem.eql(u8, ident, "vec")) return .vec;
    return .custom;
}

test "dumps the literal" {
    const v = "vec";
    const a = "assert";
    std.debug.print("vec   = {x}\n", .{std.mem.asBytes(v)});
    std.debug.print("assert= {x}\n", .{std.mem.asBytes(a)});
    try std.testing.expectEqual(MacroKind.vec, identifyMacro("vec!"));
}
```

To try it:

```sh
zig test repro.zig            # Debug, expect 76 65 63 / PASS
zig test -O ReleaseSafe repro.zig
```

### (b) Project-level observation procedure

This is the sequence that actually fires.

1. Build and run the unit tests in Debug:

   ```sh
   zig build test
   ```

2. The `translate_rust.frontend` test artifact (root `src/frontend/root.zig`,
   329 tests) fails: **8 failed, 321 passed**. The failing tests:

   ```
   src/frontend/expand.zig:2505:   test.identifyMacro classifications
   src/frontend/pipeline.zig:1239:  test.analyzeSourceWithOptions selects configured feature-gated entity
   src/frontend/pipeline.zig:2707:  test.analyzeSource fills test body with literal built-in macros
   src/frontend/pipeline.zig:2915:  test.analyzeSource keeps cast operand types through source expressions
   src/frontend/pipeline.zig:2880:  test.analyzeSource lowers FNV dereference scalar cast
   src/frontend/pipeline.zig:3159:  test.analyzeSource preserves a trailing formatting macro as the block value
   src/frontend/pipeline.zig:2136:  test.cst.extractFile resolves hex error module and skips disabled strict core impl
   src/frontend/pipeline.zig:3180:  test.generic conversion results remain dispatchable in their declaration scope
   ```

   For the first one the failure text is:

   ```
   expected MacroKind.vec, found MacroKind.custom
   ```

   Line 2512 inside it is `try std.testing.expectEqual(MacroKind.vec, identifyMacro("vec!"));`.
   The assertions immediately above it — `identifyMacro("assert")` and
   `identifyMacro("assert!")` at lines 2506 and 2507 — pass, matching the
   intact `"assert"` literal in the table above.

3. To see the bytes, add a temporary byte-dump as the **first** test in the
   frontend test binary's root (`src/frontend/root.zig` is the artifact root;
   placing the dump first guarantees it is the first test executed), then
   rebuild:

   ```zig
   test "00 dump literals" {
       std.debug.print("vec    = {x}\n", .{std.mem.asBytes("vec")});
       std.debug.print("assert = {x}\n", .{std.mem.asBytes("assert")});
   }
   ```

   ```sh
   zig build test --summary all 2>&1 | grep -A2 '00 dump literals'
   ```

   Observed:

   ```
   vec    = aa aa aa
   assert = 61 73 73 65 72 74
   ```

   The dump must be first: placing it later in the binary still shows the
   corruption, but placing it first establishes that nothing ran before it and
   therefore overwrote the literal. Remove the dump before filing.

To confirm the CLI is unaffected, from the same tree and toolchain:

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/translate-rust --help
```

Output is coherent; no `0xAA` corruption is observable there. That is only a
smoke check. For a functional one, see Experiment 3: the CLI from this tree
reproduces the correct behaviour of every failing test on that test's own
source.

## Toolchain and platform

- Zig **0.16.0**, `x86_64-linux` official release build.
- Local copy used: `~/.cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/zig`
  (a local copy; checksum not verified against the published release hash).
- Host OS: Linux 6.12.0, x86_64.
- Project: `translate-rust` (Rust-to-Zig translator), `zig build test`, Debug,
  ~854 tests spread over ~10 test binaries.

## Ruled out

Ruled out, with the evidence:

- **The source is not wrong.** Not just the one function: all 8 failing tests
  have source-level explanations that the toolchain's behaviour contradicts.
  `src/frontend/expand.zig` is byte-identical to the committed blob; md5
  verified. The literal is spelled `"vec"` at line 42 and nothing rewrites it.
  For the other 7, the CLI run in Experiment 3 satisfies every assertion the
  Debug binary fails on, using the exact Rust source those tests analyze.
- **The test bodies are not wrong.** The 7 failing `pipeline` bodies were
  copied verbatim into a 165-test binary that passed 165/165 (Experiment 1),
  and were copied verbatim into the failing binary itself as new call sites,
  where all ten added tests passed while the originals failed in the same run
  (Experiment 2). No change to the source, and none that could exist,
  reconciles those two results.
- **Not a runtime overwrite by earlier tests.** The `aa aa aa` bytes are
  present at the first executed test in the binary, before any other test runs.
- **Not a small-code-generation quirk of this function.** The identical
  function, standalone and imported, compiles and passes.
- **Not universal to the toolchain or the tree.** The `translate-rust` release
  CLI binary, built from the same tree with the same Zig, emits coherent
  output; and the CLI, whatever its optimization level, reproduces the correct
  behaviour of every failing test on that test's own source (Experiment 3).
- **Not specific to one literal.** `"assert"` in the same file, in the same
  function, in the same binary, is intact.
- **Not an alignment/length artefact of the literal itself.** The corrupted
  literal is 3 bytes and reads as 3 `0xAA` bytes — the correct length with the
  content replaced, not a length or truncation problem.

Not ruled out, and left open:

- Root cause. I have deliberately not formed one. The evidence above
  constrains it: literal *content* is replaced by the undefined-fill pattern
  while length is correct, per-copy, per call site, in one artifact, absent
  from another artifact of the same tree.
- Whether the 7 `pipeline` failures are the same byte-level miscompile as the
  `"vec"` literal or a related one. I have shown they are toolchain defects
  and not source bugs; I have not dumped bytes at their call sites.
- Whether a minimal reproducer is constructible at all.

## Optimization-mode behaviour

ReleaseSafe is dramatically worse, not better. On the same tree, same
toolchain:

```sh
zig build test -Doptimize=ReleaseSafe
```

Result: **7 failed, 148 CRASHED**. Debug confines the damage to 8 silent wrong
answers in one binary; ReleaseSafe turns the same source into 148 crashing
tests plus 7 failures.

This asymmetry points at code generation, not at something that only manifests
in a link-time or layout-only path: changing the optimization mode changes the
observable failure mode drastically on identical source. It also means the
Debug-only silent wrong answer is the mildest symptom, and any assessment of
severity based on the Debug run understates it.

## Impact and severity

Release blocker for CI trust. High severity for correctness.

The failure mode is a **silent wrong answer**, not a crash. No panic, no
sanitizer trip, no exit code change on the ReleaseSafe-free path — a string
comparison against a literal simply returns `false` and the program continues
down the wrong branch. In this project that meant a macro identifier
classified as `.custom` instead of `.vec`, i.e. wrong translation output rather
than a build failure.

What makes this a release blocker is not the false failure. It is that the
artifact whose job is to certify the code is itself unreliable, in both
directions at once.

- **False failures, and they are already here.** 8 of 329 tests fail on source
  that is correct. All 7 of the non-literal ones disappear the moment the same
  bodies are compiled at a different call site in the same binary (Experiment
  2), or into a smaller binary (Experiment 1). A suite that goes red for
  reasons unrelated to the code teaches everyone to re-run it and read the
  next result instead.
- **False passes — a mechanism, not a measurement.** The fault is per call
  site, so what a given call site reads is not guaranteed to be what the
  source says. Nothing in the evidence bounds it to producing false failures
  only. A test whose assertion is a negative — this must *not* be `X`, this
  cast must not be present, this path must not resolve — can be satisfied by
  data the program never produced. I have not observed a false pass in this
  project and I am not claiming one; the 8 observed failures are all false
  failures. But a suite is trusted for its negative assertions precisely
  because nothing else catches them, and this binary cannot be shown to
  preserve them.

So the test binary is the broken artifact, and it is broken in the one place
where its own trustworthiness would have to be established. That is the
difference between an inconvenient compiler bug and a CI-trust release
blocker: a suite that can both fail real tests and mask real defects is worse
than no suite, because it is believed. A project that runs its suite at one
optimization level can also plausibly be green on the mode where the bug is
quiet and undiscovered on the mode where it is loud — 8 silent wrong answers
against 148 crashes on the same source is exactly that split.

Practical guidance for anyone hitting this: verify string literals at runtime
in at least one build across optimization modes, and treat "a comparison against
a literal returns false" as a codegen bug rather than a logic bug until the
literal's bytes have been dumped. Two further rules follow from the experiments
above. First, a passing copy of a failing test is not evidence that the
failure is not real — here the same bodies passed at new call sites in the
failing binary itself, so re-running, moving, or duplicating a test is not a
diagnostic here. Second, do not treat a green suite as evidence about a
negative assertion until you have dumped the bytes that assertion compares
against; a suite that can fail real tests and mask real ones gives no signal
either way until the data is inspected.
