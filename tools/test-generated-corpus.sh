#!/usr/bin/env bash
# Stage the generated-package corpus once on the host, then measure the aggregate
# it produced across the pinned cross matrix.
#
# This is a separate entry point from `zig build`: it composes the two stages
# that cannot be one build step.
#
#   1. Host stage. `zig build generated-corpus -- --output <dir>` runs
#      `test/generated_corpus.zig`, which drives the real translator over every
#      corpus row and publishes each result as a standalone Zig package. Every
#      package is promoted by the driver, so a row is present only because its
#      manifest, sources and own `zig build test` passed.
#   2. Census stage. `cross-test --list` over the same pinned table reports,
#      per target, whether a runner exists at all. It builds nothing, and it
#      is the join key for the matrix: it says which rows *could* execute.
#   3. Matrix stage. `cross-test` builds and runs the aggregate's pure `test`
#      graph for every one of those targets. The aggregate's build script
#      compiles and runs test artifacts and does nothing else, so a foreign
#      target row never runs a host compiler.
#
# Every census row is then joined against the summary cross-test publishes and
# checked on its own evidence: a row with a runner must build, exit 0, run,
# exit 0 again, report a nonzero assertion count and finish `tests_complete`; a
# row without one must build, exit 0, and say `build_only`. A disagreement
# fails the run even when cross-test itself exited 0, which
# `CROSS_REQUIRE_RUNNERS=0` makes possible.
#
#   4. Authority stage. `zig targets`, run from the same pinned compiler that
#      built everything else, publishes the architectures, operating systems
#      and ABIs this toolchain can build. Every census row is required to
#      decompose into three of them, so the matrix can never name a target the
#      compiler does not report: the census is checked against what this
#      toolchain publishes rather than against a list typed here. It builds
#      nothing and it needs no network.
#
# The row vocabulary is `executed` or `compile_only`, and never "it compiled".
# `executed` is a claim about evidence, not about intent: the published summary
# must carry a passing run, a zero exit, a nonzero assertion count and
# `tests_complete` for that row. Everything else that compiled is
# `compile_only`, and it keeps the reason it did not execute rather than being
# dropped or folded into a total — whether the census found no runner at all
# (`no_runner`), whether it found one the build then could not use
# (`runner_declared_but_not_executed`), or whether the row failed outright
# (`failed`), which is neither. Every target the census listed is a row in the
# receipts below, whatever happened to it.
#
# The join is proven before any row is claimed. `target_count` is a declared
# count, not a row count: a summary that repeats one target id and omits
# another satisfies it and proves nothing, and neither does an equal pair of
# counts over two different sets of ids. So the rows the file actually carries
# are counted, their ids are required to be distinct, the two id sets are
# required to be equal, and until they agree no row is claimed as executed.
# Extras and omissions are refused with the target that disagrees, never folded
# into a total.
#
# The joined rows are written next to the summary as a receipt, so an executed
# row and a compile-only row are distinguishable after the fact.
#
# Nothing here deletes anything. The producer refuses a pre-existing output
# directory, this script refuses one too, and the cross-test profile keeps the
# per-run cache and state it would otherwise remove. Removing a corpus is the
# parent's decision, made after reading it.
#
# Environment:
#   R2Z_CORPUS_ROOT        parent directory for the corpus and the matrix output
#                          (default $HOST_SCRATCH_ROOT/scratch/translate-rust-generated-corpus)
#   R2Z_CORPUS_REUSE       1 = reuse an existing producer output and only re-run
#                          the matrix. The output is never re-verified, so this
#                          is a matrix-only re-run, not a freshness claim.
#   R2Z_CORPUS_LIST        1 = run cross-test --list instead of the full matrix
#   R2Z_CORPUS_CACHE_MAX_MB  refuse to start above this many MiB in the shared
#                          cache (default 65536). The check never prunes: a full
#                          cache is reported and the run stops.
#   R2Z_ZIG                absolute path to a real Zig 0.17.0 executable
#   ZIG                    same, and the variable cross-test itself reads
#
# R2Z_SCRATCH is deliberately not honoured for the producer. Its caches have to
# sit inside the bounded shared cache this script measures, so the producer is
# invoked with R2Z_SCRATCH pointing into that cache rather than with whatever
# the caller happened to have set.
#
#     tools/test-generated-corpus.sh --self-check
#
# runs no producer, no census and no matrix. It pins every placement, transport
# and toolchain rule below by feeding the checks in the policy section a fixed
# table of paths, filesystem types and version strings, each with the verdict it
# must get. `zig build check-entry-points` runs it, so no rule here can be
# dropped or weakened without that step failing.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

die() { printf 'test-generated-corpus: %s\n' "$*" >&2; exit 2; }
note() { printf 'test-generated-corpus: %s\n' "$*" >&2; }

# ── Policy ─────────────────────────────────────────────────────────────────
# Path and toolchain checks do not create or remove files.

# The reason `requested`/`resolved` cannot hold a corpus or a cache, printed
# and returned as 0; nothing printed and 1 when it can.
#
# `requested` is the path as written and `resolved` its `realpath -m` form. A
# symlink alias into /tmp has to be refused for where it lands, not for how it
# was spelled. The walk reads symlinked components and nothing else.
placement_fault() {
    local requested="$1" resolved="$2" cursor
    if [[ "$requested" != /* ]]; then
        printf 'scratch path must be absolute: %s\n' "$requested"
        return 0
    fi
    cursor="$requested"
    while [[ "$cursor" != / ]]; do
        if [[ -L "$cursor" ]]; then
            printf 'scratch path contains a symlink: %s\n' "$cursor"
            return 0
        fi
        cursor="$(dirname -- "$cursor")"
    done
    case "$resolved" in
        /tmp | /tmp/* | /var/tmp | /var/tmp/* | /dev/shm | /dev/shm/*)
            printf 'scratch path resolves into a reserved volume: %s\n' "$resolved"
            return 0
            ;;
        "$repo_root" | "$repo_root"/*)
            printf 'scratch path is inside the repository: %s\n' "$resolved"
            return 0
            ;;
    esac
    return 1
}

# The reason a filesystem type cannot carry the caches, printed and returned as
# 0; nothing printed and 1 when it can. Zig's atomic write is the failure these
# refuse, so a corpus on one of these would abort mid-promotion.
transport_fault() {
    local fstype="$1" path="${2:-the scratch root}"
    case "$fstype" in
        '')
            printf 'no filesystem type could be read for %s\n' "$path"
            return 0
            ;;
        nfs | nfs4 | cifs | smb | smb3 | 9p | afs | ceph | coda | gpfs | \
            lustre | ocfs2 | beegfs | glusterfs | fuse.sshfs | fuse.glusterfs)
            printf 'scratch path is on network filesystem %s: %s\n' "$fstype" "$path"
            return 0
            ;;
    esac
    return 1
}

# The filesystem type of `path`, read from the nearest ancestor that exists, so
# a directory that has not been created yet is still placed rather than refused
# for the wrong reason.
fstype_of() {
    local cursor="$1" parent
    while [[ ! -e "$cursor" ]]; do
        parent="$(dirname -- "$cursor")"
        [[ "$parent" == "$cursor" ]] && break
        cursor="$parent"
    done
    # `/proc/mounts` is the authority on what a path actually sits on, which is
    # why this reader is findmnt and not the kernel's idea of the superblock.
    findmnt -n -o FSTYPE -T "$cursor" 2>/dev/null || true
}

# The reason a toolchain at `path` cannot be run, printed and returned as 0;
# nothing printed and 1 when it can be.
toolchain_path_fault() {
    local path="$1"
    if [[ "$path" != /* ]]; then
        printf 'R2Z_ZIG must be an absolute executable path: %s\n' "$path"
        return 0
    fi
    if [[ ! -x "$path" ]]; then
        printf 'R2Z_ZIG must be an absolute executable path: %s\n' "$path"
        return 0
    fi
    return 1
}

# The reason a `zig version` answer is not a version at all, printed and returned
# as 0; nothing printed and 1 when it is. The anyzig shim outside a checkout
# exits 1 and prints nothing, which is the failure this script must not inherit.
version_fault() {
    local version="$1"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.+-]*)?$ ]]; then
        printf 'toolchain reported no version (answered: %s)\n' "${version:-nothing}"
        return 0
    fi
    return 1
}

# The reason one component of a target triple is not among the values the
# pinned compiler publishes, printed and returned as 0; nothing printed and 1
# when all three are. `zig targets` is the authority: it is the same compiler
# that built every artifact, printing the architectures, operating systems and
# ABIs it can build for. Checking each row against it means the census cannot
# name a target this toolchain does not report, so a row in the matrix is
# backed by the compiler's own table rather than by a list typed here.
target_fault() {
    local target="$1" arch="$2" os="$3" abi="$4" archs="$5" oses="$6" abis="$7"
    grep -qxF -- "$arch" <<<"$archs" ||
        { printf 'architecture %s is not one the pinned compiler reports' "$arch"; return 0; }
    grep -qxF -- "$os" <<<"$oses" ||
        { printf 'operating system %s is not one the pinned compiler reports' "$os"; return 0; }
    grep -qxF -- "$abi" <<<"$abis" ||
        { printf 'ABI %s is not one the pinned compiler reports' "$abi"; return 0; }
    return 1
}

# Decompose one published target triple into the three components `zig targets`
# publishes, as tab-separated text, and return 0; return 1 for anything that is
# not a triple. The default ABI of a triple that names none is `none`, which is
# the value the compiler publishes for it, so a bare `x86_64-linux` and an
# explicit `x86_64-linux.none` decompose to the same three values.
#
# The shape accepted here is the one cross-test's own matrix uses, so a row this
# cannot decompose is a row the census printed in a shape nothing else in this
# harness would accept either — reported, not skipped.
split_target() {
    local target="$1" arch rest os abi remainder
    [[ "$target" =~ ^[a-z0-9_]+-[a-z0-9_.]+(-[a-z0-9_.]+)*$ ]] || return 1
    arch="${target%%-*}"
    rest="${target#*-}"
    # `<os>` runs up to the next separator, and Zig spells an ABI either side of
    # one: `x86_64-linux-musl` and `x86_64-linux.musl` are the same three
    # components. Anything after the ABI — a glibc version, say — is not part of
    # what `zig targets` publishes, so it is dropped here rather than compared.
    os="${rest%%[-.]*}"
    remainder="${rest#"$os"}"
    abi=none
    if [[ -n "$remainder" ]]; then
        abi="${remainder#[-.]}"
        abi="${abi%%[-.]*}"
    fi
    [[ -n "$abi" ]] || abi=none
    printf '%s\t%s\t%s\n' "$arch" "$os" "$abi"
}

# The compiler whose support table this harness measures.
required_zig_version=0.17.0

# The reason `version` is not the pinned compiler, printed and returned as 0.
toolchain_version_fault() {
    local version="$1"
    if version_fault "$version"; then
        return 0
    fi
    if [[ "$version" != "$required_zig_version" ]]; then
        printf 'R2Z_ZIG must report version %s, and it reported %s\n' \
            "$required_zig_version" "$version"
        return 0
    fi
    return 1
}

# The toolchain stores the anyzig shim resolves through, in the order they are
# searched: the compiler the caller's environment already points at, then the
# shared one under $HOME, then the one the host scratch policy selected.
zig_toolchain_roots() {
    local base
    for base in "${ZIG_GLOBAL_CACHE_DIR:-}" "${HOME:-}/.cache/zig" \
        "${HOST_SCRATCH_ROOT:-}/cache/zig"; do
        [[ -n "$base" && -d "$base/p" ]] || continue
        printf '%s\n' "$base/p"
    done
}

# The newest cached binary above that answers `zig version` with the pinned
# compiler.
discover_zig() {
    local root candidate version
    while IFS= read -r root; do
        while IFS= read -r candidate; do
            [[ -x "$candidate" ]] || continue
            # A rejected candidate's reason is silenced: this function's stdout
            # is the toolchain path its caller captures, and printing into it
            # would corrupt the answer.
            if version="$("$candidate" version 2>/dev/null)" &&
                ! toolchain_version_fault "$version" >/dev/null; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done < <(find "$root" -mindepth 2 -maxdepth 2 -name zig -type f \
            -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    done < <(zig_toolchain_roots)
    return 1
}

# ── --self-check ───────────────────────────────────────────────────────────
#
# One table, one verdict per row. A rule that stops being enforced shows up here
# as a case that was refused and now is not.
self_check() {
    local cases=0 failures=0 verdict label want
    run_case() {
        label="$1"
        want="$2"
        shift 2
        cases=$((cases + 1))
        # These functions print their reason and answer 0 when they refuse, so
        # a refusal is the success status here and is inverted on purpose.
        if "$@" >/dev/null 2>&1; then verdict=refused; else verdict=accepted; fi
        if [[ "$verdict" == "$want" ]]; then
            printf '  ok      %-58s %s\n' "$label" "$verdict"
        else
            printf '  FAILED  %-58s %s, must be %s\n' "$label" "$verdict" "$want" >&2
            failures=$((failures + 1))
        fi
    }

    # Placement. `/proc/self/cwd` is a real symlink on every Linux host, which
    # is what pins the symlinked-component rule without creating one.
    # A path outside the checkout is accepted. Both halves of the call have to
    # be that path: passing `$repo_root` as the resolved form tested the
    # checkout-root refusal a second time under a label that claimed to pin the
    # opposite rule, so a change that started refusing every local path would
    # have gone unnoticed here.
    run_case 'an absolute local path outside the checkout' accepted \
        placement_fault /home/tmp/r2z-cache /home/tmp/r2z-cache
    run_case 'a relative path' refused \
        placement_fault r2z-cache /home/tmp/r2z-cache
    run_case '/tmp' refused placement_fault /tmp/r2z-cache /tmp/r2z-cache
    run_case '/var/tmp' refused placement_fault /var/tmp/r2z /var/tmp/r2z
    run_case '/dev/shm' refused placement_fault /dev/shm/r2z /dev/shm/r2z
    run_case 'a symlink landing in a reserved volume' refused \
        placement_fault /tmp/alias /tmp/alias/cache
    run_case 'a symlinked path component' refused \
        placement_fault /proc/self/cwd/cache /home/tmp/cache
    run_case 'the checkout root itself' refused \
        placement_fault "$repo_root" "$repo_root"
    run_case 'a path inside the checkout' refused \
        placement_fault "$repo_root/zig-out/scratch" "$repo_root/zig-out/scratch"

    # Transport. The corpus and the cache both have to survive an atomic write.
    run_case 'ext4' accepted transport_fault ext4 /home/tmp/r2z-corpus
    run_case 'xfs' accepted transport_fault xfs /home/tmp/r2z-corpus
    run_case 'nfs' refused transport_fault nfs /home/tmp/r2z-corpus
    run_case 'nfs4' refused transport_fault nfs4 /home/tmp/r2z-corpus
    run_case '9p' refused transport_fault 9p /home/tmp/r2z-corpus
    run_case 'fuse.glusterfs' refused transport_fault fuse.glusterfs /home/tmp/r2z
    run_case 'an unreadable filesystem type' refused transport_fault '' /home/tmp/x

    # Toolchain. The shim, and the table this harness measures.
    run_case 'a relative R2Z_ZIG' refused toolchain_path_fault zig
    run_case 'an R2Z_ZIG that does not exist' refused \
        toolchain_path_fault /home/tmp/r2z-cache/absent-zig
    run_case 'an executable R2Z_ZIG' accepted \
        toolchain_path_fault "$repo_root/tools/test-generated-corpus.sh"
    run_case 'the silence of a shim with no toolchain' refused version_fault ''
    run_case 'an unparsable answer' refused version_fault unknown
    run_case 'the pinned compiler' accepted \
        toolchain_version_fault "$required_zig_version"
    run_case 'another compiler' refused toolchain_version_fault 0.16.2
    run_case 'a silent shim, by version' refused toolchain_version_fault ''

    # The census authority. `zig targets` publishes three value sets; a row is
    # measured only when its triple decomposes into three of them. The sets here
    # are a fixed stand-in for the compiler's own output, so a rule that stops
    # consulting them shows up as a case that is refused and now is not.
    local archs=$'aarch64\narm\nmips\npowerpc64le\nriscv64\nthumb\nwasm32\nx86\nx86_64'
    local oses=$'freebsd\nlinux\nmaccatalyst\nmacos\nnetbsd\nopenbsd\nwasi\nwindows'
    local abis=$'eabi\ngnu\nmsvc\nmusl\nnone'
    run_case 'a published triple' accepted \
        target_fault x86_64-linux x86_64 linux none "$archs" "$oses" "$abis"
    run_case 'a published triple with an explicit ABI' accepted \
        target_fault x86_64-linux-musl x86_64 linux musl "$archs" "$oses" "$abis"
    run_case 'an architecture the compiler does not report' refused \
        target_fault z80-linux z80 linux none "$archs" "$oses" "$abis"
    run_case 'an operating system the compiler does not report' refused \
        target_fault x86_64-plan9 x86_64 plan9 none "$archs" "$oses" "$abis"
    run_case 'an ABI the compiler does not report' refused \
        target_fault x86_64-linux-plan9abi x86_64 linux plan9abi "$archs" "$oses" "$abis"
    run_case 'a real architecture with an unpublished ABI' refused \
        target_fault x86_64-linux-muslabi64 x86_64 linux muslabi64 "$archs" "$oses" "$abis"

    # Decomposition. The three components a row is recorded under, including the
    # default ABI of a triple that names none and the big-endian spellings.
    run_split() {
        local label="$1" want="$2" target="$3" got
        cases=$((cases + 1))
        if ! got="$(split_target "$target" 2>/dev/null)"; then got='<rejected>'; fi
        if [[ "$got" == "$want" ]]; then
            printf '  ok      %-58s %s\n' "$label" "$got"
        else
            printf '  FAILED  %-58s %s, must be %s\n' "$label" "$got" "$want" >&2
            failures=$((failures + 1))
        fi
    }
    run_split 'x86_64-linux' $'x86_64\tlinux\tnone' x86_64-linux
    run_split 'aarch64_be-linux' $'aarch64_be\tlinux\tnone' aarch64_be-linux
    run_split 'x86_64-linux.musl' $'x86_64\tlinux\tmusl' x86_64-linux.musl
    run_split 'x86_64-linux-gnu.2.5' $'x86_64\tlinux\tgnu' x86_64-linux-gnu.2.5
    run_split 'aarch64_be-linux-musl' $'aarch64_be\tlinux\tmusl' aarch64_be-linux-musl
    run_split 'thumbeb-linux' $'thumbeb\tlinux\tnone' thumbeb-linux
    run_split 'wasm32-wasi' $'wasm32\twasi\tnone' wasm32-wasi
    run_split 'x86_64-linux-musl' $'x86_64\tlinux\tmusl' x86_64-linux-musl
    run_split 'a bare architecture' '<rejected>' x86_64
    run_split 'an uppercase triple' '<rejected>' X86_64-Linux

    printf 'test-generated-corpus: --self-check: %d cases, %d failed\n' "$cases" "$failures"
    ((failures == 0)) ||
        die "the placement, transport and toolchain rules above do not hold"
}

if [[ "${1:-}" == "--self-check" ]]; then
    self_check
    exit 0
fi

# ── 1. The approved host scratch policy ─────────────────────────────────────
# Sourced even when this shell predates it: TMPDIR and ZIG_GLOBAL_CACHE_DIR both
# land on the approved volume, and this cluster keeps /tmp, /var/tmp and
# /dev/shm clear.
if [[ ! -r "$HOME/.local/lib/host-scratch.sh" ]]; then
    die "missing host scratch policy $HOME/.local/lib/host-scratch.sh"
fi
# shellcheck source=/dev/null
source "$HOME/.local/lib/host-scratch.sh" ||
    die "host scratch policy failed"
[[ -n "${HOST_SCRATCH_ROOT:-}" ]] ||
    die "the host scratch policy selected no volume; set R2Z_CORPUS_ROOT"

corpus_requested="${R2Z_CORPUS_ROOT:-$HOST_SCRATCH_ROOT/scratch/translate-rust-generated-corpus}"
corpus_root="$(realpath -m -- "$corpus_requested")"
output="${corpus_root}/corpus"
cache="$(realpath -m -- "${HOST_SCRATCH_ROOT}/cache/translate-rust-generated-corpus-zig")"
cross_out="${corpus_root}/cross-test"

# ── 2. Placement rules ──────────────────────────────────────────────────────
# Local source and scratch may share an ext4 filesystem. Reject transport and
# placement, not equality of filesystem family names. The two rules that decide
# that are `placement_fault` and `transport_fault` above, which `--self-check`
# pins; what is left here needs the directory to exist, so it stays here.
validate_local_root() {
    local requested="$1" resolved="$2" owner fstype fault
    if fault="$(placement_fault "$requested" "$resolved")"; then
        die "$fault"
    fi
    fstype="$(fstype_of "$resolved")"
    [[ -n "$fstype" ]] || die "cannot determine scratch transport for $resolved"
    if fault="$(transport_fault "$fstype" "$resolved")"; then
        die "$fault"
    fi
    mkdir -p -- "$resolved"
    [[ -d "$resolved" && ! -L "$resolved" ]] || die "invalid scratch directory: $resolved"
    owner="$(stat -c %u -- "$resolved")" || die "cannot read scratch owner: $resolved"
    [[ "$owner" == "$(id -u)" ]] || die "scratch directory is not owned by this UID: $resolved"
}
validate_local_root "$corpus_requested" "$corpus_root"
validate_local_root "${HOST_SCRATCH_ROOT}/cache/translate-rust-generated-corpus-zig" "$cache"
case "$corpus_root" in
    "$cache" | "$cache"/*) die "corpus root must not be inside the shared cache" ;;
esac
case "$cache" in
    "$corpus_root" | "$corpus_root"/*) die "shared cache must not be inside the corpus root" ;;
esac

avail_kib="$(df -Pk "$HOST_SCRATCH_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')"
case "${avail_kib:-}" in
    '' | *[!0-9]*) die "cannot read free space for $HOST_SCRATCH_ROOT" ;;
esac
if ((avail_kib < 8388608)); then
    die "the approved scratch volume has less than 8 GiB free; set R2Z_CORPUS_ROOT on another approved mount"
fi

# ── 3. A real toolchain, not the anyzig shim ────────────────────────────────
resolve_zig() {
    local version fault
    if [[ -n "${R2Z_ZIG:-}" ]]; then
        if fault="$(toolchain_path_fault "$R2Z_ZIG")"; then
            die "$fault"
        fi
        version="$("$R2Z_ZIG" version 2>/dev/null || true)"
        if fault="$(toolchain_version_fault "$version")"; then
            die "$fault"
        fi
        printf '%s\n' "$R2Z_ZIG"
        return 0
    fi
    discover_zig
}
zig_bin="$(resolve_zig)" ||
    die "no cached Zig $required_zig_version under any toolchain store (looked in \$ZIG_GLOBAL_CACHE_DIR/p, \$HOME/.cache/zig/p and \$HOST_SCRATCH_ROOT/cache/zig/p); set R2Z_ZIG to an absolute path"

# ── 3b. The tools this script shells out to, resolved rather than assumed ──
# `cross-test` and `dust` are per-user installs that `devenv.nix` does not
# vendor, so a shell which has not sourced the development environment finds
# neither on PATH. Naming the fallback and reporting which file was chosen
# turns an opaque "command not found" into the path that was actually used.
resolve_tool() {
    local name="$1" fallback="${2:-}" candidate
    if candidate="$(command -v "$name" 2>/dev/null)" && [[ -n "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi
    if [[ -n "$fallback" && -f "$fallback" && -x "$fallback" && ! -d "$fallback" ]]; then
        printf '%s\n' "$fallback"
        return 0
    fi
    return 1
}
cross_test="$(resolve_tool cross-test-0.17 "$HOME/.local/bin/cross-test-0.17")" ||
    die "no cross-test-0.17 on PATH or in the user's local bin directory"
cross_test="$(realpath -e -- "$cross_test")" || die "cannot resolve the cross-test driver"
note "cross-test driver: $cross_test"

dust_bin="$(resolve_tool dust "$HOME/.local/bin/dust")" ||
    die "no dust on PATH and none at $HOME/.local/bin/dust; the shared-cache bound is measured with it"
dust_bin="$(realpath -e -- "$dust_bin")" || die "cannot resolve dust"
note "cache measurement tool: $dust_bin"

# The matrix receipt is read out of the summary cross-test publishes, so the
# parser is resolved and reported the same way rather than being assumed.
jq_bin="$(resolve_tool jq '')" ||
    die "no jq on PATH; the per-row matrix receipt is read from the published summary with it"
jq_bin="$(realpath -e -- "$jq_bin")" || die "cannot resolve jq"
note "summary parser: $jq_bin"

# ── 4. The shared cache is shared, bounded, and never pruned ────────────────
# Every target uses one shared cache. The profile serializes builds to avoid
# concurrent writers to that cache.
# The profile reapplies this measured root after cross-test sources host policy,
# so retained temporary and global-cache artifacts stay under the same lock.
cache_max_mb="${R2Z_CORPUS_CACHE_MAX_MB:-65536}"
[[ "$cache_max_mb" =~ ^[0-9]{1,9}$ ]] ||
    die "R2Z_CORPUS_CACHE_MAX_MB must be a positive decimal MiB bound"
cache_max_mb=$((10#$cache_max_mb))
((cache_max_mb > 0)) || die "the cache bound must be positive"
# The lock belongs to the shared cache, not a corpus: distinct corpus roots
# still serialize their measurement, producer, and matrix against each other.
[[ ! -L "$cache/matrix.lock" ]] || die "shared cache lock must not be a symlink"
exec 9>"$cache/matrix.lock"
flock -x 9 || die "cannot lock the shared generated-corpus cache"
# Measured, never pruned: a cache over the bound is reported and the run stops.
# The same measurement is taken again after the matrix, because the matrix is
# what fills that cache — a bound checked only on the way in says nothing about
# what the target matrix left behind.
measure_cache() {
    local measurement byte_pattern='^[[:space:]]*([0-9]{1,18})B?[[:space:]]+.+$'
    measurement="$("$dust_bin" -o b -b -c -P -d 0 -- "$cache")" ||
        die "dust failed to measure allocated shared-cache bytes under $cache"
    # At depth zero dust emits one total. Accept only its decimal byte count
    # (and optional explicit B unit), never an error or human-scale quantity.
    [[ "$measurement" != *$'\n'* && "$measurement" =~ $byte_pattern ]] ||
        die "invalid dust byte measurement: $measurement"
    cache_bytes=$((10#${BASH_REMATCH[1]}))
    if ((cache_bytes > cache_max_mb * 1048576)); then
        die "the shared cache $cache holds $cache_bytes allocated bytes, over the $cache_max_mb MiB bound; this script never removes a cache"
    fi
    note "shared cache $cache holds $cache_bytes allocated bytes, within the $cache_max_mb MiB bound"
}
cache_bytes=0
measure_cache

# ── 5. Host stage ───────────────────────────────────────────────────────────
if [[ -e "$output" ]]; then
    if [[ "${R2Z_CORPUS_REUSE:-0}" != "1" ]]; then
        die "$output already exists; refusing to reuse or remove it. Choose another R2Z_CORPUS_ROOT, or set R2Z_CORPUS_REUSE=1 to re-run only the matrix over the existing corpus."
    fi
    note "reusing the existing corpus at $output without re-verifying it (R2Z_CORPUS_REUSE=1)"
else
    note "staging the corpus into $output"
    (
        cd -- "$repo_root"
        export PATH="$(dirname -- "$zig_bin"):$PATH"
        export ZIG_LOCAL_CACHE_DIR="$cache/producer/local"
        export ZIG_GLOBAL_CACHE_DIR="$cache/producer/global"
        mkdir -p -- "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"
        "$zig_bin" build generated-corpus -- --output "$output"
    )
fi

aggregate="$output/aggregate"
[[ -f "$aggregate/build.zig" ]] ||
    die "$aggregate/build.zig is missing; the producer did not write an aggregate"
[[ -f "$aggregate/corpus_config.zig" ]] ||
    die "$aggregate/corpus_config.zig is missing"
[[ -f "$aggregate/cross-test.profile.sh" ]] ||
    die "$aggregate/cross-test.profile.sh is missing"

# ── 6. The census: what this host could execute ─────────────────────────────
# cross-test runs from the project root, which here is the generated aggregate.
cd -- "$aggregate"

# The census and the matrix both use the version-pinned table, never ambient
# target selectors, and both run the compiler this script resolved.
unset CROSS_MATRIX TARGETS
census="$corpus_root/cross-test-census.txt"
census_err="$corpus_root/cross-test-census.err"
note "cross-test census over the pinned table (detects runners, builds nothing)"
census_status=0
R2Z_MATRIX_CACHE_ROOT="$cache" TMPDIR="$cache" ZIG="$zig_bin" ZIG_GLOBAL_CACHE_DIR="$cache" \
    "$cross_test" --profile "$aggregate/cross-test.profile.sh" --list >"$census" 2>"$census_err" ||
    census_status=$?
((census_status == 0)) || die "cross-test --list failed with $census_status; see $census_err"
[[ -s "$census" ]] || die "cross-test --list wrote no census; see $census_err"

# `--list` prints one header line and then one padded row per target: the
# target, the runner kind it detected (native, exec or unavailable) and why.
# That census is the join key for the matrix result — it says which rows *could*
# execute, the published summary says what each row actually did, and this
# script reports a row as executed only when both agree and the summary carries
# a nonzero assertion count. Counting `qemu-*` executables answers neither
# question (`arm` and `armeb` each serve two rows), so no count here is derived
# from a program-name census, and `CROSS_REQUIRE_RUNNERS=0` never turns a
# compile-only row into a pass.
#
# One header, one census. Two headers mean two runs were concatenated, and the
# first one's count would be read as the second one's.
census_headers="$(awk '/^cross-test:/ { n++ } END { print n + 0 }' "$census")"
((census_headers == 1)) ||
    die "cross-test --list printed $census_headers header lines, not 1; this is not one census of one matrix"
census_declared="$(awk '/^cross-test:/ { for (i = 1; i <= NF; i++) if ($i ~ /^targets=[0-9]+$/) { sub(/^targets=/, "", $i); print $i; exit } }' "$census")"
[[ "$census_declared" =~ ^[0-9]+$ ]] || die "cross-test --list printed no target count header"
# Which published table the rows came from, recorded so the receipts say which
# matrix produced them rather than leaving a reader to assume.
census_matrix_source="$(awk '/^cross-test:/ { for (i = 1; i <= NF; i++) if (substr($i, 1, 7) == "matrix=") { print substr($i, 8); exit } }' "$census")"
[[ -n "$census_matrix_source" ]] || census_matrix_source='unstated'
note "census matrix source: $census_matrix_source"

declare -a census_targets=()
declare -A census_kind=() census_reason=() census_listed=()
census_native=0 census_exec=0 census_unavailable=0
while IFS=$'\t' read -r target kind reason; do
    # A repeated id is not a second target. Storing it in an associative array
    # would collapse the duplicate silently, letting one row's runner kind
    # stand in for the other's, so a repeat is refused here instead: it is a
    # census that disagrees with itself, which is not evidence of anything.
    [[ -n "$target" && -n "$kind" && -n "$reason" ]] ||
        die "cross-test --list printed a census row without a target, a runner kind or a reason"
    [[ -z "${census_listed[$target]+yes}" ]] ||
        die "cross-test --list listed $target more than once; a repeated census id is not a distinct target"
    census_listed["$target"]=1
    census_targets+=("$target")
    census_kind["$target"]="$kind"
    census_reason["$target"]="$reason"
    case "$kind" in
        native) census_native=$((census_native + 1)) ;;
        exec|qemu_user) census_exec=$((census_exec + 1)) ;;
        unavailable) census_unavailable=$((census_unavailable + 1)) ;;
        *) die "cross-test --list reported the unknown runner kind '$kind' for $target" ;;
    esac
done < <(awk '!/^cross-test:/ && NF >= 3 { print $1 "\t" $2 "\t" $3 }' "$census")

# Every non-header line cross-test printed, so a row the parser above could not
# read is reported rather than dropped out of the census and the totals.
census_printed="$(awk '!/^cross-test:/ && NF { n++ } END { print n + 0 }' "$census")"

census_total="${#census_targets[@]}"
((census_printed == census_total)) ||
    die "cross-test --list printed $census_printed census rows but only $census_total were well formed"
((census_declared == census_total)) ||
    die "cross-test --list declared $census_declared targets but listed $census_total rows"
# Require a nonempty compiler support table.
((census_total > 0)) ||
    die "the Zig 0.17.0 support table is empty"
((census_native + census_exec + census_unavailable == census_total)) ||
    die "the census runner kinds do not add up to $census_total targets"

note "census: $census_total targets = $census_native native, $census_exec executable, $census_unavailable unavailable"
note "census receipt: $census"

# ── 6a. The compiler's own target list ──────────────────────────────────────
# The census says which of the pinned table's rows this host can execute.
# `zig targets` says which targets this toolchain can build at all, and it is
# the same executable that built every artifact in this run. Checking the census
# against it is what keeps the matrix a measurement rather than a list: a row
# that does not decompose into three published values is not a target this
# compiler reports, so every matrix row must name a published target.
#
# It builds nothing, reads nothing from the network, and does not depend on
# the aggregate — so it runs on the `--list` path too.
note "reading the pinned compiler's own target list (zig targets; builds nothing)"
targets_txt="$corpus_root/zig-targets.txt"
targets_err="$corpus_root/zig-targets.err"
"$zig_bin" targets >"$targets_txt" 2>"$targets_err" ||
    die "zig targets failed under $zig_bin; see $targets_err"
[[ -s "$targets_txt" ]] || die "zig targets wrote no target list; see $targets_err"

# One value per line for one published section. `zig targets` prints a Zig
# struct literal, and the three sections that name a triple's components are
# flat lists of quoted strings, so the section header selects the set and every
# eight-space-indented quoted line inside it is one published value. Later
# sections nest deeper and are ignored by both the indentation and the name.
published_target_values() {
    awk -v want="$1" '
        $0 ~ "^    \\." && $0 ~ "= \\.\\{$" { section = $1; sub(/^\./, "", section); next }
        section != want { next }
        $0 ~ /^        "[A-Za-z0-9_.-]+",$/ {
            value = $0
            sub(/^        "/, "", value)
            sub(/",$/, "", value)
            print value
        }
    ' "$targets_txt"
}

published_archs="$(published_target_values arch)"
published_oses="$(published_target_values os)"
published_abis="$(published_target_values abi)"
mapfile -t published_archs_lines <<<"$published_archs"
mapfile -t published_os_lines <<<"$published_oses"
mapfile -t published_abi_lines <<<"$published_abis"
# Three empty sets would make every row pass for the wrong reason, so each is
# required to be a real list before any row is checked against it.
[[ -n "$published_archs" && -n "$published_oses" && -n "$published_abis" ]] ||
    die "zig targets published no usable value list; see $targets_txt"
note "compiler target list: ${#published_archs_lines[@]} architectures, ${#published_os_lines[@]} operating systems, ${#published_abi_lines[@]} ABIs"

declare -A target_arch=() target_os=() target_abi=()
declare -a unpublished=()
for target in "${census_targets[@]}"; do
    if ! decomposed="$(split_target "$target")"; then
        unpublished+=("$target is not a target triple in the shape cross-test's matrix uses")
        continue
    fi
    IFS=$'\t' read -r arch os abi <<<"$decomposed"
    if fault="$(target_fault "$target" "$arch" "$os" "$abi" \
        "$published_archs" "$published_oses" "$published_abis")"; then
        unpublished+=("$target: $fault")
        continue
    fi
    target_arch["$target"]="$arch"
    target_os["$target"]="$os"
    target_abi["$target"]="$abi"
done
if ((${#unpublished[@]} > 0)); then
    for entry in "${unpublished[@]}"; do
        printf 'test-generated-corpus: the census lists %s\n' "$entry" >&2
    done
    die "${#unpublished[@]} of $census_total census rows are not targets the pinned compiler reports"
fi
note "census authority: all $census_total rows decompose into three values zig targets publishes; receipt: $targets_txt"

if [[ "${R2Z_CORPUS_LIST:-0}" == "1" ]]; then
    note "listing the matrix instead of running it"
    awk '!/^cross-test:/ && NF >= 3 { printf "  %-27s %-12s %s\n", $1, $2, $3 }' "$census" >&2
    exit "$census_status"
fi

# ── 7. The matrix ───────────────────────────────────────────────────────────
note "cross-test over $aggregate (every census target, Debug and ReleaseSafe in one graph)"
status=0
R2Z_MATRIX_CACHE_ROOT="$cache" TMPDIR="$cache" ZIG="$zig_bin" ZIG_GLOBAL_CACHE_DIR="$cache" \
    "$cross_test" --profile "$aggregate/cross-test.profile.sh" --output "$cross_out" --step test ||
    status=$?

# ── 8. What happened, joined against what could have happened ──────────────
# `reason` is a row's final verdict — tests_complete, runtime_unavailable,
# tests_failed, build_failed — never a runner name. Which runner a row was
# offered is the census's column; what that row then did is the summary's.
summary="$cross_out/cross-test-summary.json"
[[ -f "$summary" ]] || die "cross-test published no summary at $summary"
note "summary: $summary"
note "run logs: $cross_out/runs/"

schema_version="$("$jq_bin" -r '.schema // "missing"' "$summary")"
[[ "$schema_version" == 2 ]] || die "unexpected cross-test summary schema '$schema_version' at $summary"
# `//` is jq's alternative operator and `false` counts as empty to it, so a
# plain `// "missing"` would report a healthy `false` as absent. Compare
# against the literal instead.
bookkeeping="$("$jq_bin" -r 'if .bookkeeping_failure == false then "false" else "true" end' "$summary")"
[[ "$bookkeeping" == false ]] ||
    die "cross-test reported a bookkeeping failure, so no row in $summary is verified"
declared_rows="$("$jq_bin" -r '.target_count | if type == "number" then tostring else "absent" end' "$summary")"
[[ "$declared_rows" =~ ^[0-9]+$ ]] ||
    die "the summary at $summary declares no target_count; a count nobody wrote proves nothing"

# `target_count` is cross-test's declaration about itself. It is not the number
# of rows the file carries, and a summary can satisfy it exactly while repeating
# one target and omitting another. So the rows that are actually there are
# counted, their ids are required to be well formed and distinct, and the count
# has to be this harness's pinned table before anything is joined. All of it
# names the offending target: a duplicate or a missing id is not summarised away
# into a total that still balances.
summary_records="$("$jq_bin" -r 'if (.targets | type) == "array" then (.targets | length | tostring) else "absent" end' "$summary")"
[[ "$summary_records" =~ ^[0-9]+$ ]] ||
    die "the summary at $summary carries no targets array; nothing in it is verified"
unnamed_ids="$("$jq_bin" -r '([.targets[] | .target | select(type != "string") | tostring] + [.targets[] | select((.target | type) == "string") | select((.target | length) == 0) | .target]) | join(",")' "$summary")"
[[ -z "$unnamed_ids" ]] ||
    die "the summary carries row id(s) [$unnamed_ids] that are absent or not target names; no row can be attributed to a target"
duplicate_ids="$("$jq_bin" -r '[.targets[].target] | group_by(.) | map(select(length > 1) | .[0]) | join(",")' "$summary")"
[[ -z "$duplicate_ids" ]] ||
    die "the summary repeats target id(s): $duplicate_ids; a duplicated row is not a second target, and the row it overwrote is not evidence"
unique_ids="$("$jq_bin" -r '[.targets[].target] | unique | length | tostring' "$summary")"
[[ "$unique_ids" =~ ^[0-9]+$ ]] ||
    die "the summary at $summary yielded no readable target id count"
((unique_ids == summary_records)) ||
    die "the summary carries $summary_records rows but only $unique_ids distinct target ids"
((summary_records == census_total)) ||
    die "the summary carries $summary_records target rows but the census listed $census_total"
((declared_rows == summary_records)) ||
    die "the summary declares target_count=$declared_rows but carries $summary_records target rows"
note "summary: $summary_records rows, $unique_ids distinct target ids, declared target_count $declared_rows"

# The published keys are the schema-2 ones cross-test writes: build.status and
# build.exit, run.status, run.exit and run.tests, reason and status. A field that
# is null in the summary stays visibly absent here: it is never replaced by a
# default that could read as a success, so an exit code is compared against the
# literal 0 and an assertion count only counts when it is a real integer.
summary_projection='
    def shown: if . == null then "absent" else tostring end;
    .targets[]
    | [ .target,
        (.build.status | shown), (.build.exit | shown),
        (.run.status | shown), (.run.exit | shown), (.run.tests | shown),
        (.reason | shown), (.status | shown) ]
    | @tsv
'
declare -a summary_targets=()
declare -A row_build=() row_build_exit=() row_run=() row_run_exit=() row_tests=()
declare -A row_reason=() row_status=() row_seen=()
parsed_rows=0
while IFS=$'\t' read -r target build build_exit run run_exit tests reason final; do
    parsed_rows=$((parsed_rows + 1))
    [[ -z "${row_seen[$target]+yes}" ]] ||
        die "the summary row stream repeats $target; a duplicated row is not a second target"
    row_seen["$target"]=1
    summary_targets+=("$target")
    row_build["$target"]="$build"
    row_build_exit["$target"]="$build_exit"
    row_run["$target"]="$run"
    row_run_exit["$target"]="$run_exit"
    row_tests["$target"]="$tests"
    row_reason["$target"]="$reason"
    row_status["$target"]="$final"
done < <("$jq_bin" -r "$summary_projection" "$summary")
((parsed_rows == summary_records)) ||
    die "the summary yielded $parsed_rows readable rows but carries $summary_records; a field carrying a separator would split a row"

violations=()
executed=0 compiled_only=0 native_executed=0 foreign_executed=0

# Set equality is settled before any row is attributed or counted. A summary row
# with no census entry, or a census entry with no summary row, means the two
# sides are not describing the same set of targets, and a join that cannot be
# mapped to targets cannot claim that any of them ran: every agreeing row would
# be evidence for a target the run as a whole never accounted for. So extras and
# omissions are named here, with the target that disagrees, and the row counters
# stay at zero until the sets match exactly.
join_proven=1
declare -a unjoined=()
for target in "${census_targets[@]}"; do
    [[ -n "${row_status[$target]:-}" ]] ||
        unjoined+=("$target (census: the summary has no row for it)")
done
for target in "${summary_targets[@]}"; do
    [[ -n "${census_kind[$target]:-}" ]] ||
        unjoined+=("$target (summary: the census has no row for it)")
done
if ((${#unjoined[@]} > 0)); then
    join_proven=0
    for target in "${unjoined[@]}"; do
        violations+=("$target is not joined by the census and the summary; no row is claimed as executed")
    done
fi

# Two receipts, one row per census target each, in two shapes a reader can use
# without this script. The TSV is the flat record; the JSON is the same record
# with the row's target decomposed into the three components `zig targets`
# publishes, so a target can be told apart from a runner and from a verdict.
# Both are written for every census target whatever happened to it: a target is
# never dropped from a receipt because it could not be executed.
receipt="$cross_out/execution-receipt.tsv"
matrix_json="$cross_out/cross-target-matrix.json"
printf 'target\tkind\tavailability\tcoverage\tcoverage_reason\tbuild\tbuild_exit\trun\trun_exit\trun_tests\treason\tstatus\n' >"$receipt"
{
    printf '{\n'
    printf '  "schema": 1,\n'
    printf '  "toolchain": %s,\n' "$("$jq_bin" -cn --arg v "$required_zig_version" '$v')"
    printf '  "matrix_source": %s,\n' "$("$jq_bin" -cn --arg v "$census_matrix_source" '$v')"
    printf '  "census": { "targets": %d, "native": %d, "executable": %d, "unavailable": %d },\n' \
        "$census_total" "$census_native" "$census_exec" "$census_unavailable"
    printf '  "compiler_target_list": { "source": %s, "architectures": %d, "operating_systems": %d, "abis": %d },\n' \
        "$("$jq_bin" -cn --arg v "$targets_txt" '$v')" \
        "${#published_archs_lines[@]}" "${#published_os_lines[@]}" "${#published_abi_lines[@]}"
    printf '  "targets": [\n'
} >"$matrix_json"
matrix_first=1

# One JSON object per target, carrying the row's own evidence. The four
# coverage verdicts are `executed`, `compile_only`, `failed` and `none`, and
# only `executed` is a claim about running something: it is written when the
# summary carries a passing run, a zero exit, a nonzero assertion count and
# `tests_complete` for that row, which is what the checks below verify.
matrix_row() {
    local target="$1" coverage="$2" coverage_reason="$3"
    ((matrix_first)) || printf ',\n'
    matrix_first=0
    "$jq_bin" -cn \
        --arg target "$target" \
        --arg arch "${target_arch[$target]:-}" \
        --arg os "${target_os[$target]:-}" \
        --arg abi "${target_abi[$target]:-}" \
        --arg kind "${census_kind[$target]:-}" \
        --arg availability "${census_reason[$target]:-}" \
        --arg coverage "$coverage" \
        --arg coverage_reason "$coverage_reason" \
        --arg build "${row_build[$target]:-}" \
        --arg build_exit "${row_build_exit[$target]:-}" \
        --arg run "${row_run[$target]:-}" \
        --arg run_exit "${row_run_exit[$target]:-}" \
        --arg run_tests "${row_tests[$target]:-}" \
        --arg reason "${row_reason[$target]:-}" \
        --arg status "${row_status[$target]:-}" \
        '
        # A field cross-test left out stays absent rather than becoming a
        # default that could read as a result, so the two numeric fields carry
        # a number or null and never a string standing in for one.
        def num($v): if ($v | test("^-?[0-9]+$")) then ($v | tonumber) else null end;
        {
          target: $target,
          arch: (if $arch == "" then null else $arch end),
          os: (if $os == "" then null else $os end),
          abi: (if $abi == "" then null else $abi end),
          runner_kind: (if $kind == "" then null else $kind end),
          runner_reason: (if $availability == "" then null else $availability end),
          coverage: $coverage,
          coverage_reason: $coverage_reason,
          build: {
            status: (if $build == "" then null else $build end),
            exit: num($build_exit),
          },
          run: {
            status: (if $run == "" then null else $run end),
            exit: num($run_exit),
            tests: num($run_tests),
          },
          reason: (if $reason == "" then null else $reason end),
          status: (if $status == "" then null else $status end),
        }'
}

# Two sets of counters, deliberately. `rows_executed` and friends describe what
# each row's own evidence says and always add up to the census, because they are
# what the receipts report. `executed` and `compiled_only` are claims, and they
# stay at zero until the join is proven — a summary that does not account for
# every census target cannot support a claim about any of them, though it can
# still be read row by row.
rows_executed=0
rows_compile_only=0
rows_failed=0
rows_none=0
declared_not_executed=0
count_coverage() {
    case "$1" in
        executed) rows_executed=$((rows_executed + 1)) ;;
        compile_only) rows_compile_only=$((rows_compile_only + 1)) ;;
        failed) rows_failed=$((rows_failed + 1)) ;;
        *) rows_none=$((rows_none + 1)) ;;
    esac
}

for target in "${census_targets[@]}"; do
    kind="${census_kind[$target]}"
    availability="${census_reason[$target]}"
    coverage=none
    coverage_reason=absent_from_summary
    if [[ -z "${row_status[$target]:-}" ]]; then
        printf '%s\t%s\t%s\t%s\t%s\t-\t-\t-\t-\t-\t-\tabsent\t-\n' \
            "$target" "$kind" "$availability" "$coverage" "$coverage_reason" >>"$receipt"
        matrix_row "$target" "$coverage" "$coverage_reason" >>"$matrix_json"
        count_coverage "$coverage"
        violations+=("$target is absent from the published summary")
        continue
    fi
    problems=()
    if [[ "${row_build[$target]}" != pass ]]; then
        problems+=("build ${row_build[$target]}")
    fi
    # A build that says `pass` over a nonzero or missing exit code has not
    # passed; the two halves of the record have to agree before the row is used.
    # `absent` is not 0 here, so a summary that omits the exit code cannot be
    # read as a clean build.
    if [[ "${row_build_exit[$target]}" != 0 ]]; then
        problems+=("build exit ${row_build_exit[$target]}")
    fi
    if [[ "$kind" == native || "$kind" == exec || "$kind" == qemu_user ]]; then
        # An available row counts as executed only when it built, ran to a zero
        # exit, was not skipped and reported a nonzero assertion count. A
        # detected runner is never on its own an execution claim, and neither is
        # a pass verdict that arrives without the evidence behind it.
        if [[ "${row_run[$target]}" != pass ]]; then
            problems+=("run ${row_run[$target]}")
        fi
        if [[ "${row_run_exit[$target]}" != 0 ]]; then
            problems+=("run exit ${row_run_exit[$target]}")
        fi
        assertions="${row_tests[$target]}"
        if [[ ! "$assertions" =~ ^[0-9]{1,9}$ ]] || ((10#$assertions == 0)); then
            problems+=("assertions $assertions")
        fi
        if [[ "${row_reason[$target]}" != tests_complete ]]; then
            problems+=("reason ${row_reason[$target]}")
        fi
        if [[ "${row_status[$target]}" != pass ]]; then
            problems+=("status ${row_status[$target]}")
        fi
        if ((${#problems[@]} == 0)); then
            coverage=executed
            coverage_reason="$availability"
        else
            # The census offered this target a runner and the row still carries
            # no execution. That is not the same as a target with no runner, and
            # it is not folded into one: it is named as its own reason so a
            # reader can tell a matrix that executed nothing because nothing
            # could run it from one that could not use a runner it had.
            coverage=compile_only
            coverage_reason="runner_declared_but_not_executed:$availability"
        fi
        if [[ "$coverage" == executed ]] && ((join_proven)); then
            executed=$((executed + 1))
            if [[ "$kind" == native ]]; then
                native_executed=$((native_executed + 1))
            else
                foreign_executed=$((foreign_executed + 1))
            fi
        fi
        [[ "$coverage" == executed ]] || declared_not_executed=$((declared_not_executed + 1))
    else
        # An unavailable row must be compile-only: it built, it did not run,
        # and it says build_only rather than reporting a pass. Its run exit is
        # deliberately not required to be 0: cross-test records the compiler's
        # own nonzero status there, because that is how it knows the foreign
        # binary could not run.
        if [[ "${row_run[$target]}" != unavailable && "${row_run[$target]}" != skip ]]; then
            problems+=("run ${row_run[$target]}")
        fi
        if [[ "${row_status[$target]}" != build_only ]]; then
            problems+=("status ${row_status[$target]}")
        fi
        if [[ "${row_reason[$target]}" != "$availability" ]]; then
            note "note: $target was unavailable at census ($availability) and at run (${row_reason[$target]})"
        fi
        if ((${#problems[@]} == 0)); then
            coverage=compile_only
            coverage_reason="no_runner:$availability"
            if ((join_proven)); then compiled_only=$((compiled_only + 1)); fi
        else
            coverage=failed
            coverage_reason="${problems[*]}"
        fi
    fi
    count_coverage "$coverage"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$target" "$kind" "$availability" \
        "$coverage" "$coverage_reason" \
        "${row_build[$target]}" "${row_build_exit[$target]}" "${row_run[$target]}" \
        "${row_run_exit[$target]}" "${row_tests[$target]}" "${row_reason[$target]}" \
        "${row_status[$target]}" >>"$receipt"
    matrix_row "$target" "$coverage" "$coverage_reason" >>"$matrix_json"
    if ((${#problems[@]} > 0)); then
        violations+=("$target (census $kind/$availability, ${coverage}): ${problems[*]}")
    fi
done

{
    printf '  ],\n'
    # The per-row verdicts, which always add up to the census. The claimed
    # totals follow in their own field, because they are zero until the join is
    # proven and would otherwise make the row counts disagree with the rows.
    printf '  "coverage": { "executed": %d, "compile_only": %d, "failed": %d, "none": %d },\n' \
        "$rows_executed" "$rows_compile_only" "$rows_failed" "$rows_none"
    printf '  "claimed_totals": { "executed": %d, "compile_only_no_runner": %d, "declared_but_not_executed": %d },\n' \
        "$executed" "$compiled_only" "$declared_not_executed"
    printf '  "claimed": %s\n' "$([[ $join_proven == 1 ]] && printf true || printf false)"
    printf '}\n'
} >>"$matrix_json"

((matrix_first == 1)) &&
    die "no target reached the receipts; a matrix with no rows reports nothing"
"$jq_bin" -e 'type == "object" and (.targets | type) == "array"
    and (.targets | length) == (.census.targets)
    and ([.targets[].target] | unique | length) == (.targets | length)' \
    "$matrix_json" >/dev/null ||
    die "the cross-target matrix at $matrix_json does not carry one distinct row per census target"
note "cross-target matrix: $matrix_json"

# The counters below are about the join, not about a target having run: a row
# that the census made available and that did not execute is still a compile-only
# row, and its total is reported next to the executed one rather than folded into
# it. So the two conditions that used to be one check are now three: rows that
# executed, rows with no runner at all, and rows a runner was offered to and that
# still only compiled.
if ((join_proven)); then
    ((executed + declared_not_executed == census_native + census_exec)) ||
        violations+=("the $((census_native + census_exec)) rows the census made available are $executed executed and $declared_not_executed not, which adds up to neither")
    ((compiled_only == census_unavailable)) ||
        violations+=("$compiled_only rows are compile-only because no runner exists, but the census made $census_unavailable unavailable")
    ((rows_failed == 0)) ||
        violations+=("$rows_failed rows failed; a failure is neither executed nor compile-only coverage and is not counted as either")
fi
((rows_executed + rows_compile_only + rows_failed + rows_none == census_total)) ||
    die "the receipts classify $((rows_executed + rows_compile_only + rows_failed + rows_none)) of $census_total census targets"

note "execution receipt: $receipt"
# The table is the report: one line per target, in census order, saying what the
# row is and why. `awk` reads the receipt rather than the arrays, so what is
# printed is exactly what was written.
awk -F'\t' 'NR == 1 {
    printf "test-generated-corpus: %-27s %-13s %-12s %s\n", "target", "coverage", "kind", "coverage_reason"
    next
}
{
    printf "test-generated-corpus: %-27s %-13s %-12s %s\n", $1, $4, $2, $5
}' "$receipt" >&2
if ((join_proven)); then
    note "executed $executed rows ($native_executed native, $foreign_executed under a foreign runner)"
    note "coverage: $rows_executed executed, $rows_compile_only compile-only ($compiled_only with no runner on this host, $declared_not_executed with a runner the build could not use), $rows_failed failed, $rows_none unclassified"
else
    note "the census and the summary disagree about which targets ran, so nothing is claimed"
    note "rows: $rows_executed executed, $rows_compile_only compile-only, $rows_failed failed, $rows_none unclassified"
fi
if [[ -f "$aggregate/retained-state.txt" ]]; then
    while IFS= read -r retained; do
        [[ -n "$retained" ]] && note "retained run state: $retained"
    done < "$aggregate/retained-state.txt"
fi

# cross-test exits 0 whenever every row either passed or was legitimately
# compile-only, so its own status cannot be the check. Every disagreement is
# named here, with the target it belongs to, and the run fails on the
# disagreement rather than on the code.
if ((${#violations[@]} > 0)); then
    for violation in "${violations[@]}"; do
        printf 'test-generated-corpus: %s\n' "$violation" >&2
    done
    printf 'test-generated-corpus: %d disagreements between the census and the published summary; cross-test exited %d and the receipt is at %s\n' \
        "${#violations[@]}" "$status" "$receipt" >&2
fi

# The bound is measured again now, because the matrix is what filled the cache,
# and it is measured on a failing run too: an over-bound cache is worth knowing
# about exactly when something went wrong.
measure_cache

if ((${#violations[@]} > 0)); then
    exit 1
fi
exit "$status"