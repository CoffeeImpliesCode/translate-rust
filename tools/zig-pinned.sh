#!/usr/bin/env bash
# Pinned Zig invocation for this repository.
#
# Three host facts break a bare `zig build` here, and all three fail quietly or
# misleadingly rather than loudly:
#
# 1. `zig` on PATH is the anyzig shim. It re-resolves, and re-downloads, the
#    toolchain on every single invocation, so each build pays a full fetch.
# 2. This repository lives on an NFSv3 mount. Zig's atomic file write uses
#    `renameat2(RENAME_EXCHANGE)`, which NFSv3 does not implement, so any
#    directory Zig writes into atomically on the mount fails with EINVAL and a
#    "programmer bug caused syscall error" panic. That covers both the cache
#    directories AND the install prefix (`zig-out`), so both move to local disk.
# 3. Concurrent `zig build` runs sharing one cache directory corrupt it and
#    abort. Agents and humans run builds in parallel here, so invocations are
#    serialized with a lock.
#
# This script resolves a real cached toolchain directly, serializes against
# other invocations, redirects the caches and prefix to local disk, and forwards
# every argument to `zig build`. Usage is identical to `zig build`:
#
#     tools/zig-pinned.sh
#     tools/zig-pinned.sh test
#     tools/zig-pinned.sh test-crates --summary all
#     tools/zig-pinned.sh run -- test/crates/hex -o /tmp/hex-out
#
# Set R2Z_ZIG to override toolchain discovery. Set R2Z_SCRATCH to override the
# local-disk scratch root. Set R2Z_NO_LOCK=1 to bypass serialization.

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# ── 1. Resolve a real toolchain, bypassing the anyzig shim ──────────────────
#
# Cached toolchains are standalone binaries under ~/.cache/zig/p/<hash>/zig.
# Pick the newest one that actually runs, so a stale hash cannot break us.
if [[ -n "${R2Z_ZIG:-}" ]]; then
    zig_bin="$R2Z_ZIG"
else
    zig_bin=""
    if [[ -d "${HOME}/.cache/zig/p" ]]; then
        while IFS= read -r candidate; do
            [[ -x "$candidate" ]] || continue
            if "$candidate" version >/dev/null 2>&1; then
                # Sorted newest-first by mtime; keep the first that runs.
                zig_bin="$candidate"
                break
            fi
        done < <(find "${HOME}/.cache/zig/p" -mindepth 2 -maxdepth 2 -name zig \
            -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    fi
fi

if [[ -z "$zig_bin" ]]; then
    echo "tools/zig-pinned.sh: no usable cached Zig found under \$HOME/.cache/zig/p." >&2
    echo "  Install one, or set R2Z_ZIG=/absolute/path/to/zig." >&2
    exit 1
fi

zig_version="$("$zig_bin" version 2>/dev/null || echo unknown)"

# ── 2. Move both caches off the NFS mount ──────────────────────────────────
#
# $HOME is itself on the NFS mount here, so defaulting the scratch to
# "$HOME/.cache" would put the caches right back on it and reproduce the exact
# EINVAL abort this script exists to avoid. Prefer a genuinely local path and
# verify it is not the same filesystem as the repository before using it.
scratch_root="${R2Z_SCRATCH:-}"
if [[ -z "$scratch_root" ]]; then
    for candidate in /var/tmp /tmp /dev/shm; do
        if [[ -d "$candidate" ]] && \
           [[ "$(stat -f -c %T "$candidate" 2>/dev/null)" != \
              "$(stat -f -c %T "$repo_root" 2>/dev/null)" ]]; then
            scratch_root="$candidate/r2z-zig-cache-$(id -u)"
            break
        fi
    done
fi
if [[ -z "$scratch_root" ]]; then
    echo "tools/zig-pinned.sh: no local-disk scratch found; set R2Z_SCRATCH to a" >&2
    echo "  path on a different filesystem than $repo_root." >&2
    exit 1
fi
mkdir -p "$scratch_root/local" "$scratch_root/global"


# ── 3. Keep ./zig-out a real directory ─────────────────────────────────────
#
# An earlier version symlinked zig-out into local scratch. That breaks the test
# suite: std.Io.Dir.createDirPath refuses a path component that is a symlink,
# because it is neither a directory nor a file when it does not follow symlinks,
# so `createDirPath(io, "zig-out")` fails with NotDir. The install step only
# copies files, it does not write atomically, so a real directory on the mount is
# fine now that the caches are local. Undo the symlink if one is present.
prefix_link="$repo_root/zig-out"
if [[ -L "$prefix_link" ]]; then
    rm -f "$prefix_link"
    mkdir -p "$prefix_link"
fi

# ── 4. Serialize against other invocations ────────────────────────────────
#
# Two `zig build` runs sharing one cache directory corrupt it and abort. Agents
# and humans build in parallel in this repo, so take an exclusive lock unless
# the caller opts out.
lock_file="$scratch_root/build.lock"
run_zig() {
    cd "$repo_root"
    "$zig_bin" build \
        --cache-dir "$scratch_root/local" \
        --global-cache-dir "$scratch_root/global" \
        "$@"
}

# The build spawns child `zig` processes (package promotion runs `zig build
# test` on generated packages). A bare `zig` on PATH would hit the shim in
# those children, where there is no build.zig.zon to resolve a version from,
# so the shim would exit 1 silently. Put the real binary first on PATH.
toolchain_bin_dir="$(dirname -- "$zig_bin")"
export PATH="$toolchain_bin_dir:$PATH"

echo "tools/zig-pinned.sh: zig $zig_version ($zig_bin)" >&2
echo "tools/zig-pinned.sh: local caches under $scratch_root" >&2
echo "tools/zig-pinned.sh: prefix $prefix_link (real directory in the repo)" >&2

if [[ "${R2Z_NO_LOCK:-0}" == "1" ]]; then
    run_zig "$@"
    exit $?
fi

# `flock` can only exec a real binary, never a shell function, so the lock is
# taken on a file descriptor and the function runs in this shell.
exec 9>"$lock_file"
if ! flock -x 9; then
    echo "tools/zig-pinned.sh: could not acquire $lock_file" >&2
    exit 1
fi

run_zig "$@"
