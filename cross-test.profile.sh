#!/usr/bin/env bash
# cross-test profile for translate-rust.
#
# No CROSS_MATRIX on purpose: cross-test then runs its own version-pinned table,
# every Tier 1/2 platform of the Zig 0.16.0 support table, each with automatic
# runner detection. On another Zig version it refuses to guess and demands a
# matrix, which is the right answer for a project pinned to one compiler.
#
# The default build path is kept, so every target compiles the complete test
# graph — library, IR, grammar, model, frontend, backend, driver, golden, e2e —
# not the generated packages, which stay host-only in `zig build test-crates`.
# A row with no runner on this host is compile-only coverage, never a pass.
# Linkage follows build.zig's single policy: a foreign Linux artifact is
# built static, because a QEMU user-mode guest has no loader and no libc to
# find; every other foreign target keeps Zig's default linkage. Execution
# coverage is what the tool reports per row, not what this file claims.
#
# That compile-only row is a build.zig fact rather than a harness choice.
# Getting it needs the build system to decline a foreign run instead of failing
# it, which is `run.skip_foreign_checks`. build.zig's own Run steps do not set
# it, so a foreign target with no runner stops that build at its first run, and
# the row is reported failed: a graph that stopped early was never compiled and
# must not be called compile-only. `test/generated_corpus_build.zig` sets the
# flag, which is why the generated corpus does get whole-graph compile-only rows
# under a foreign runner. The flag is the seam between the two graphs and it
# belongs to build.zig.
#
# Two harnesses read this file, and they agree because the variables mean the
# same thing to both. `./cross-test.sh` measures this repository's own graph: one
# `zig build $CROSS_BUILD_STEP -Dtarget=…` per target, with execution inside that
# build and `--list` reporting, per target, the runner this host has and why. The
# external `cross-test` tool reads the same settings for the generated-package
# matrix, which `tools/test-generated-corpus.sh` drives from inside the aggregate
# with that aggregate's own generated profile, not with this file.
#
# Two steps drive the host toolchain and are therefore compiled but not executed
# off the host: the CLI contract shell step, and the e2e program, which spawns
# `zig test` and `zig build` on generated packages. Both still execute in full
# on the host row. Promotion, the fingerprint probe and the e2e program spawn
# the compiler that built them, resolved by build.zig, not a `zig` from PATH.
#
# 900 s is the per-test-binary deadline the shared gate expects and 1800 s
# covers one whole target. Both jobs are 1 because cross-test shares one cache
# directory across targets and concurrent Zig builds over one cache abort. The
# output prefix goes on the approved host scratch volume, never the repository.

CROSS_BUILD_STEP=test
CROSS_TIMEOUT=900
CROSS_BUILD_TIMEOUT=1800
CROSS_JOBS=1
CROSS_BUILD_JOBS=1
CROSS_REQUIRE_RUNNERS=0

if [ -n "${HOST_SCRATCH_ROOT:-}" ]; then
    CROSS_PREFIX="$HOST_SCRATCH_ROOT/scratch/cross-test-out"
fi