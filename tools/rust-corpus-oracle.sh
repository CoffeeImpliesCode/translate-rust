#!/usr/bin/env bash
# Native Rust oracle runner for the seven promoted corpus crates.
#
# What this script does, in order:
#
# 1. Copies the oracle crate and all seven pristine crate roots into a *new*,
#    owned, local scratch tree that mirrors `test/`'s layout (oracle next to
#    `crates/<name>`), so the oracle's `../crates/<name>` path dependencies keep
#    working. Nothing under the repository is ever written: cargo would create
#    `Cargo.lock`, `target/` and registry state next to the sources otherwise,
#    and the published fixtures must stay byte-identical to their archives.
# 2. Verifies the transport: every staged file's sha256 must equal the source
#    file's sha256, no symlinks may appear in a staged tree, and the three
#    archived roots' upstream git sha1 (from `.cargo_vcs_info.json`) must match
#    the published values.
# 3. Pins the toolchain. `test/crates/atoi` ships a `rust-toolchain.toml`
#    pinning 1.57.0; `RUSTUP_TOOLCHAIN` overrides that child selection with the
#    host's installed modern toolchain, and the script verifies the override is
#    still in force while the working directory is the staged atoi root.
# 4. Builds and runs the oracle twice — the empty default feature closure and
#    the explicit `xxh32` closure — writing one receipt per configuration and
#    checking that the receipt written by `--output` is byte-identical to the
#    receipt printed on stdout.
# 5. Runs the original crates' own unit, integration and doc tests from their
#    own manifests, in their staged copies, for all seven crates. For six crates
#    the lib/integration and doc targets are separate invocations; docs are
#    attempted even when the first invocation failed.
#    `xxhash-rust` unit/integration tests retain two distinct configurations:
#    its actual (empty) default closure and `--features xxh32`. Its ungated doc
#    example instead runs ONCE under the crate's published documentation
#    profile, read from the staged root package's metadata.docs.rs.features by
#    `cargo metadata --format-version 1 --no-deps`. That profile enables xxh32,
#    const_xxh32, xxh64, const_xxh64, xxh3, const_xxh3, not std. This is a
#    separate docs-profile verdict, NOT a closed-default or xxh32 doc pass.
#    Upstream CI uses the same six features for cargo test:
#    https://github.com/DoumanAsh/xxhash-rust/blob/7026cd705195f502283f97aafc9ea41930099c68/.github/workflows/rust.yml
#    Target selections, enabled features and source feature gates are printed,
#    so targets that compile to zero tests are visible rather than skipped.
# 6. Re-resolves every fixture's version with `cargo metadata --format-version 1
#    --no-deps` in the staged tree, selects the root package by manifest_path,
#    and compares its version with the receipt's declaration. A drifted fixture
#    fails the run. The manifests are never scraped by hand.
#
# Environment: everything cargo writes goes to local scratch
# (CARGO_HOME, CARGO_TARGET_DIR, TMPDIR/TMP/TEMP). The registry has to be
# fetched once over the network: `rand_core` (wyhash) and `num-traits` (atoi)
# for the oracle build, plus `criterion`, `quickcheck`, `getrandom` and
# `xxhash-c-sys` for the upstream test targets.
#
# Usage:
#   tools/rust-corpus-oracle.sh --output /local/path/for/receipts
#   tools/rust-corpus-oracle.sh --scratch /local/scratch --output /local/out --strict-prerequisites
#
# Placement: --scratch and --output are absolute paths that must resolve
# *outside* the repository (no cache or cargo directory inside it), must not
# live under /tmp, /var/tmp or /dev/shm, and must sit on a local filesystem.
# Sharing one local filesystem with the source tree is fine and is the normal case; a
# network mount is not. Existing receipt files are refused.
#
# Nothing is removed. This run's scratch directory is always reported at the end
# and left in place, logs and all, for the caller to inspect and delete.
#
# Exit status: 0 everything passed; 1 a case or an upstream test failed; 2 a
# usage, staging or toolchain prerequisite problem. An upstream invocation that
# never reached "running N tests" *and* whose log names a missing or unbuildable
# dependency is reported as a typed PREREQ-UNAVAIL with the log path; it fails
# the run under --strict-prerequisites. A compile error in the crate's own
# sources is a genuine failure, is reported as UPSTREAM-FAIL, and is never
# downgraded to a missing prerequisite.

set -euo pipefail

self_name="${0##*/}"
repo_root="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

oracle_source="$repo_root/test/rust-corpus-oracle"
crud_crates=(wyhash adler xxhash-rust siphasher itoa seahash atoi)

# Upstream git sha1 from `.cargo_vcs_info.json`, for the three roots whose
# published archives were verified against crates.io. The other four are
# printed but not claimed to be archive-verified here.
declare -A archived_sha1=(
    [wyhash]=6d388f5906d655dc1840589334390dd802a4d9cb
    [adler]=a94f525f62698d699d1fb3cc9112db8c35662b16
    [xxhash-rust]=7026cd705195f502283f97aafc9ea41930099c68
)

xxhash_docs_source="https://github.com/DoumanAsh/xxhash-rust/blob/${archived_sha1[xxhash-rust]}/.github/workflows/rust.yml"

die() {
    echo "$self_name: $*" >&2
    exit 2
}

usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); if (length($0)) print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"

    cat <<EOF

Options:
  --scratch ABS       local, owned scratch root, outside the repository
                      (default: \$HOST_SCRATCH_ROOT/scratch/translate-rust)
  --output ABS        directory that receives the two receipts: outside the
                      repository, on local storage, created if absent
  --strict-prerequisites
                      fail the run when an upstream invocation could not reach
                      its tests because a dependency was unavailable
  -h, --help          this text

This run's scratch directory is always kept and its path is printed at the end;
the runner never deletes anything.

Receipts written to --output:
  rust-corpus-oracle.default.json   empty default feature closure
  rust-corpus-oracle.xxh32.json     explicit xxh32 closure

xxhash-rust upstream selection:
  unit/integration: empty default closure and explicit xxh32, separately
  documentation:   ONCE under staged root metadata.docs.rs.features
                   (six published documentation features, without std)
  This separate docs-profile verdict does not claim closed-cfg docs pass.
  Source: $xxhash_docs_source
EOF
}

# ── arguments ───────────────────────────────────────────────────────────────
scratch_root=""
output_dir=""
strict_prerequisites=0

while (( $# )); do
    case "$1" in
        --scratch)
            [[ $# -ge 2 ]] || die "--scratch needs an absolute path"
            scratch_root="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || die "--output needs an absolute path"
            output_dir="$2"
            shift 2
            ;;
        --clean)
            die "--clean was removed: this runner never deletes anything. The run directory it prints is yours to remove."
            ;;
        --strict-prerequisites)
            strict_prerequisites=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            die "unexpected argument '$1' (try --help)"
            ;;
    esac
done

# ── 1. host policy ──────────────────────────────────────────────────────────
# Source the approved scratch policy first, on every host, before anything is
# created. The library is a no-op on hosts it does not recognise, so sourcing
# it unconditionally is what makes the default below available everywhere the
# policy approves a volume — not only on the hosts whose name starts buildhost.
scratch_lib="${HOME:-/nonexistent}/.local/lib/host-scratch.sh"
scratch_policy_loaded=0
if [[ -r "$scratch_lib" ]]; then
    # shellcheck source=/dev/null
    if . "$scratch_lib"; then
        scratch_policy_loaded=1
    else
        die "approved scratch policy $scratch_lib refused to configure itself"
    fi
fi
if [[ -z "$scratch_root" ]]; then
    if (( scratch_policy_loaded == 1 )) && [[ -n "${HOST_SCRATCH_ROOT:-}" ]]; then
        scratch_root="$HOST_SCRATCH_ROOT/scratch/translate-rust"
    else
        die "no --scratch given and the approved scratch policy exported no HOST_SCRATCH_ROOT"
    fi
fi
[[ -n "$output_dir" ]] || die "--output is required"

# ── 2. placement and ownership guards ───────────────────────────────────────
# The policy is about where this run *writes*, not about which filesystem the
# source happens to live on: every byte cargo writes must land outside the
# repository and on local storage. A source mirror and a scratch directory on
# one local mount is the normal case and is allowed — cargo writing into the
# repository is the hazard, and cargo merely sharing a filesystem with it is
# not. A network mount, /tmp, /var/tmp, /dev/shm and anything inside the
# repository are refused.
my_uid="$(id -u)"

# How `path` is actually transported: /proc/mounts is the authority, matched by
# longest mount point. A filesystem family name is not — a loop mount and a
# network export of the same family look alike to `stat -f`. An unresolvable
# path is refused rather than assumed local.
mount_transport() {
    local path="$1"
    if [[ ! -r /proc/mounts ]]; then
        printf 'unknown'
        return
    fi
    awk -v p="$path" '
        {
            point = $2
            if (index(p, point) != 1) next
            rest = substr(p, length(point) + 1)
            if (rest != "" && substr(rest, 1, 1) != "/") next
            if (length(point) < best) next
            best = length(point); type = $3
        }
        END { print (best == 0 ? "unknown" : type) }' /proc/mounts
}

require_local_filesystem() {
    local path="$1" what="$2" transport
    transport="$(mount_transport "$path")"
    case "$transport" in
        nfs | nfs4 | cifs | smbfs | smb3 | 9p | afs | ceph | coda | gpfs | \
            lustre | ocfs2 | beegfs | glusterfs | autofs | fuse | fuse.* | fuseblk)
            die "$what $path is on mount type '$transport'; this runner writes only to local storage, and network, fuse and cluster mounts are refused"
            ;;
        unknown)
            die "cannot tell which mount holds $what $path; refusing to write without knowing how it is transported"
            ;;
    esac
    printf '%s' "$transport"
}

# Resolve, then refuse the destinations that are never acceptable: a system
# temp alias, and any path that lands inside the repository — which is also how
# a repository-internal cache directory is caught.
reject_forbidden_destination() {
    local path="$1" what="$2" resolved reserved real_reserved
    resolved="$(realpath -m -- "$path")"
    for reserved in /tmp /var/tmp /dev/shm; do
        real_reserved="$(realpath -m -- "$reserved")"
        case "$resolved" in
            "$real_reserved" | "$real_reserved"/*)
                die "$what must not live under $real_reserved (resolved: $resolved)"
                ;;
        esac
    done
    case "$resolved" in
        "$repo_root" | "$repo_root"/*)
            die "$what $resolved is inside the repository; cargo, its registry and its target directory must stay out of the source tree"
            ;;
    esac
    printf '%s' "$resolved"
}

# Creates an absolute path one component at a time, private (0700) under the
# caller's umask, and checks every level on the way: no component may be a
# symlink, and a component other users can write to is only acceptable with the
# sticky bit, which is the approved shared-scratch-mount pattern. A hostile link
# or a shared directory can therefore never redirect where this run writes.
make_private_dir() {
    local path="$1" what="$2"
    local -a components
    local current="" component mode
    [[ "$path" == /* ]] || die "$what $path is not an absolute path"
    IFS='/' read -r -a components <<<"${path#/}"
    for component in "${components[@]}"; do
        [[ -n "$component" ]] || continue
        current="$current/$component"
        [[ ! -L "$current" ]] || die "$what: $current is a symlink; refusing to create or write through it"
        if [[ -e "$current" ]]; then
            [[ -d "$current" ]] || die "$what: $current exists and is not a directory"
            mode="$(stat -c %a -- "$current")"
            if (( (8#$mode & 8#022) != 0 && (8#$mode & 8#1000) == 0 )); then
                die "$what: $current is writable by other users and is not sticky; refusing to write under it"
            fi
        else
            (umask 077; mkdir -- "$current") || die "$what: cannot create $current"
        fi
    done
}

check_owned_dir() {
    local path="$1" what="$2"
    [[ -d "$path" ]] || die "$what $path does not exist"
    [[ ! -L "$path" ]] || die "$what $path is a symlink; refusing to transport through it"
    local owner
    owner="$(stat -c %u -- "$path")"
    [[ "$owner" == "$my_uid" ]] || die "$what $path is owned by uid $owner, not $my_uid"
    [[ -w "$path" && -x "$path" ]] || die "$what $path is not writable"
}

check_owned_dir "$repo_root" "repository root"
[[ -d "$oracle_source" && ! -L "$oracle_source" ]] || die "missing or symlinked oracle source tree"
for crate in "${crud_crates[@]}"; do
    crate_source="$repo_root/test/crates/$crate"
    [[ -d "$crate_source" && ! -L "$crate_source" ]] || die "missing or symlinked crate root: $crate_source"
    [[ "$(stat -c %u -- "$crate_source")" == "$my_uid" ]] || die "crate root $crate_source is not owned by uid $my_uid"
    [[ ! -d "$crate_source/target" ]] || die "crate root $crate_source contains a target/ directory; the fixture is not pristine"
    if find "$crate_source" -type l -print -quit | grep -q .; then
        die "crate root $crate_source contains a symlink; refusing to transport it"
    fi
done

scratch_root="$(reject_forbidden_destination "$scratch_root" "--scratch")"
output_dir="$(reject_forbidden_destination "$output_dir" "--output")"
scratch_transport="$(require_local_filesystem "$scratch_root" "--scratch")"
output_transport="$(require_local_filesystem "$output_dir" "--output")"
repo_transport="$(mount_transport "$repo_root")"

make_private_dir "$scratch_root" "--scratch"
check_owned_dir "$scratch_root" "scratch root"
make_private_dir "$output_dir" "--output"
check_owned_dir "$output_dir" "output directory"

echo "$self_name: source $repo_root is on '$repo_transport'; scratch $scratch_root on '$scratch_transport'; output $output_dir on '$output_transport'" >&2
if [[ "$repo_transport" == "$scratch_transport" ]]; then
    echo "$self_name: source and scratch share the mount, which is allowed: they are separate directories and nothing is written into the repository" >&2
fi

default_receipt="$output_dir/rust-corpus-oracle.default.json"
xxh32_receipt="$output_dir/rust-corpus-oracle.xxh32.json"
for receipt in "$default_receipt" "$xxh32_receipt"; do
    if [[ -e "$receipt" || -L "$receipt" ]]; then
        die "refusing to overwrite existing receipt $receipt"
    fi
done

# ── 3. toolchain ────────────────────────────────────────────────────────────
cargo_bin="$(command -v cargo || true)"
rustc_bin="$(command -v rustc || true)"
[[ -n "$cargo_bin" && -n "$rustc_bin" ]] || die "prerequisite: no cargo/rustc on PATH; install a modern stable Rust toolchain"
command -v python3 >/dev/null 2>&1 || die "prerequisite: no python3 on PATH; required to read cargo metadata JSON"

# Resolve the active toolchain from a directory that has no rust-toolchain file,
# so atoi's pinned 1.57.0 is never what gets selected.
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
run_dir="$scratch_root/run-$run_id"
[[ ! -e "$run_dir" && ! -L "$run_dir" ]] || die "run directory $run_dir already exists"
make_private_dir "$run_dir" "run directory"
chmod 700 -- "$run_dir"

if command -v rustup >/dev/null 2>&1; then
    active_toolchain="$(cd -- "$run_dir" && rustup show active-toolchain 2>/dev/null | awk '{print $1}')"
    if [[ -n "$active_toolchain" ]]; then
        export RUSTUP_TOOLCHAIN="$active_toolchain"
    fi
fi
rustc_version="$(cd -- "$run_dir" && rustc -V)"
cargo_version="$(cd -- "$run_dir" && cargo -V)"

# ── 4. stage ────────────────────────────────────────────────────────────────
tree="$run_dir/tree"
install -d -m 700 -- "$tree/crates"

stage_tree() {
    local name="$1" source="$2" destination="$tree/$3"
    cp -a -- "$source" "$destination"
    if find "$destination" -type l -print -quit | grep -q .; then
        die "staged copy of $name contains a symlink"
    fi
    (cd -- "$source" && find . -type f -print0 | sort -z | xargs -0r sha256sum) >"$run_dir/source-$name.sha256"
    (cd -- "$destination" && find . -type f -print0 | sort -z | xargs -0r sha256sum) >"$run_dir/staged-$name.sha256"
    if ! diff -u "$run_dir/source-$name.sha256" "$run_dir/staged-$name.sha256" >"$run_dir/staged-$name.diff"; then
        die "staged copy of $name is not byte-identical to the source; see $run_dir/staged-$name.diff"
    fi
    echo "$self_name: staged $name ($(wc -l <"$run_dir/staged-$name.sha256") files, checksums equal)"
}

echo "$self_name: staging into $run_dir" >&2
stage_tree oracle "$oracle_source" oracle
for crate in "${crud_crates[@]}"; do
    stage_tree "$crate" "$repo_root/test/crates/$crate" "crates/$crate"
done

# Archive provenance for the roots whose published archives were verified.
for crate in "${!archived_sha1[@]}"; do
    vcs_file="$tree/crates/$crate/.cargo_vcs_info.json"
    [[ -r "$vcs_file" ]] || die "$crate has no .cargo_vcs_info.json; cannot confirm archive provenance"
    found_sha1="$(grep -o '"sha1": *"[0-9a-f]*"' "$vcs_file" | head -1 | cut -d'"' -f4)"
    if [[ "$found_sha1" != "${archived_sha1[$crate]}" ]]; then
        die "$crate upstream sha1 is $found_sha1, expected ${archived_sha1[$crate]}"
    fi
    echo "$self_name: $crate upstream sha1 $found_sha1 matches the published archive"
done
for crate in "${crud_crates[@]}"; do
    vcs_file="$tree/crates/$crate/.cargo_vcs_info.json"
    if [[ -r "$vcs_file" ]]; then
        echo "$self_name: $crate upstream sha1 $(grep -o '"sha1": *"[0-9a-f]*"' "$vcs_file" | head -1 | cut -d'"' -f4)"
    fi
done

# ── 5. cargo environment, all on local scratch ──────────────────────────────
# Every cargo and test write goes under this run's own directory, whatever
# CARGO_HOME, CARGO_TARGET_DIR or TMPDIR the host policy exported before.
export CARGO_HOME="$run_dir/cargo-home"
export CARGO_TARGET_DIR="$run_dir/target"
export TMPDIR="$run_dir/tmp"
export TMP="$run_dir/tmp"
export TEMP="$run_dir/tmp"
make_private_dir "$CARGO_HOME" "cargo home"
make_private_dir "$CARGO_TARGET_DIR" "cargo target directory"
make_private_dir "$TMPDIR" "temporary directory"
export CARGO_TERM_COLOR=never
export CARGO_INCREMENTAL=0
unset CARGO_NET_OFFLINE || true

for destination in "$CARGO_HOME" "$CARGO_TARGET_DIR" "$TMPDIR"; do
    case "$destination" in
        "$run_dir" | "$run_dir"/*) ;;
        *) die "internal error: $destination is outside this run's directory" ;;
    esac
    require_local_filesystem "$destination" "cargo write destination" >/dev/null
done

oracle_manifest="$tree/oracle/Cargo.toml"

echo "$self_name: rustc $rustc_version" >&2
echo "$self_name: cargo $cargo_version" >&2
echo "$self_name: RUSTUP_TOOLCHAIN=${RUSTUP_TOOLCHAIN:-<unset>}" >&2
echo "$self_name: CARGO_HOME=$CARGO_HOME CARGO_TARGET_DIR=$CARGO_TARGET_DIR TMPDIR=$TMPDIR" >&2

atoi_rustc="$(cd -- "$tree/crates/atoi" && rustc -V)"
echo "$self_name: rustc while cwd is the staged atoi root: $atoi_rustc" >&2
if [[ "$atoi_rustc" != "$rustc_version" ]]; then
    die "the staged atoi root still selects a different toolchain ($atoi_rustc); RUSTUP_TOOLCHAIN did not take effect"
fi

oracle_failures=0
prerequisite_gaps=0
upstream_failures=0

record_status() {
    local status="$1" name="$2" detail="$3"
    printf '%-14s %-42s %s\n' "$status" "$name" "$detail"
}

# ── 6. oracle: default feature closure, then explicit xxh32 ─────────────────
echo "$self_name: fetching registry dependencies" >&2
if ! (cd -- "$tree/oracle" && cargo fetch --manifest-path "$oracle_manifest") >"$run_dir/cargo-fetch.log" 2>&1; then
    tail -20 "$run_dir/cargo-fetch.log" >&2
    die "prerequisite: registry-unreachable, cargo fetch failed (see $run_dir/cargo-fetch.log)"
fi
(cd -- "$tree/oracle" && cargo tree --manifest-path "$oracle_manifest" --edges normal) >"$run_dir/cargo-tree-default.log" 2>&1 || true

run_oracle() {
    local label="$1" receipt="$2"
    shift 2
    local stdout_log="$run_dir/oracle-$label.stdout.json"
    local stderr_log="$run_dir/oracle-$label.stderr.log"
    local status=0
    (cd -- "$tree/oracle" && cargo run --quiet --manifest-path "$oracle_manifest" "$@" -- --output "$receipt") >"$stdout_log" 2>"$stderr_log" || status=$?
    if [[ ! -f "$receipt" ]]; then
        echo "$self_name: oracle $label produced no receipt; last stderr lines:" >&2
        tail -30 "$stderr_log" >&2
        oracle_failures=$((oracle_failures + 1))
        record_status "ORACLE-ERROR" "$label" "no receipt written (see $stderr_log)"
        return
    fi
    if ! cmp -s -- "$receipt" "$stdout_log"; then
        oracle_failures=$((oracle_failures + 1))
        record_status "ORACLE-MISMATCH" "$label" "--output receipt differs from stdout"
        return
    fi
    local summary
    summary="$(grep -o '"summary":{[^}]*}' "$receipt" || true)"
    record_status "ORACLE-$([ "$status" -eq 0 ] && echo PASS || echo FAIL)" "$label" "$summary (stderr: $stderr_log)"
    if [[ "$status" -ne 0 ]]; then
        oracle_failures=$((oracle_failures + 1))
        grep '^rust-corpus-oracle: FAIL' "$stderr_log" >&2 || true
    fi
}

run_oracle default-features "$default_receipt"
run_oracle xxh32 "$xxh32_receipt" --features xxh32
(cd -- "$tree/oracle" && cargo tree --manifest-path "$oracle_manifest" --features xxh32 --edges normal) >"$run_dir/cargo-tree-xxh32.log" 2>&1 || true

# ── 7. upstream unit, integration and doc tests ──────────────────────────────
# Six crates retain both selections even when their first invocation fails.
# xxhash-rust keeps its two requested unit closures and one separate docs profile.
report_selection() {
    local crate="$1" features="$2" mode="$3"
    local gates
    gates="$(grep -rho --include='*.rs' 'cfg(feature = "[a-z0-9_]*")' "$tree/crates/$crate" 2>/dev/null | sort -u | tr '\n' ' ' || true)"
    case "$mode" in
        all)
            printf '    selection: cargo test --lib --tests ; then cargo test --doc ; enabled features: %s\n' "${features:-<default>}"
            ;;
        unit)
            printf '    selection: cargo test --lib --tests ; enabled features: %s\n' "${features:-<default>}"
            printf '    docs: SEPARATE xxhash-rust-docs-profile invocation, not a doc pass under this unit closure\n'
            ;;
        docs)
            printf '    selection: cargo test --doc ONCE ; published documentation profile features: %s\n' "$features"
            printf '    config source: staged root package metadata.docs.rs.features (cargo metadata --format-version 1 --no-deps)\n'
            printf '    upstream CI source: %s\n' "$xxhash_docs_source"
            printf '    docs: SEPARATE profile, not a closed-default or xxh32 doc pass\n'
            ;;
    esac
    printf '    feature gates in staged sources: %s\n' "${gates:-<none>}"
}

# A gap is reported as a gap only when the log names one: a registry that could
# not be reached, a package cargo could not resolve, or a toolchain the crate
# cannot be built with. Every other non-zero exit — in particular a compile
# error in the crate's own sources — is a genuine failure and is never
# downgraded to a missing prerequisite.
prerequisite_reason() {
    local log="$1" pattern reason
    # The reason is tab-separated from an extended-regexp alternation, so the
    # `|` characters inside the pattern survive the split.
    while IFS=$'\t' read -r reason pattern; do
        [[ -n "$pattern" ]] || continue
        if grep -qE "$pattern" "$log"; then
            printf '%s' "$reason"
            return 0
        fi
    done <<'EOF'
registry-unreachable	(failed to fetch|failed to get|failed to download|download of |error sending request|network failure|unable to get packages|registry index|failed to query replaced source)
package-unresolvable	(no matching package named|no matching version|failed to select a version|couldn't find a package|package .* not found)
toolchain-incompatible	(requires rustc|requires cargo|cannot be built because it needs|is not supported by|unrecognized .* option)
EOF
    return 1
}

classify_upstream() {
    local log="$1" status="$2" reason
    if [[ "$status" -eq 0 ]]; then
        printf 'ok'
        return
    fi
    if grep -q 'test result:' "$log" || grep -q 'running [0-9]* test' "$log"; then
        printf 'failed'
        return
    fi
    if reason="$(prerequisite_reason "$log")"; then
        printf 'prereq:%s' "$reason"
    else
        printf 'failed'
    fi
}

run_upstream() {
    local crate="$1" label="$2" features="$3" mode="$4"
    shift 4
    local manifest="$tree/crates/$crate/Cargo.toml"
    local log="$run_dir/upstream-$crate$label.log"
    local lib_status=0 doc_status=0 status=0
    local lib_detail="not selected" doc_detail="not selected"
    {
        echo "=== $crate $label : features ${features:-<default>} ==="
        report_selection "$crate" "$features" "$mode"
    } >"$log"

    # The other six crates always attempt both independent selections.
    # xxhash-rust units and docs have separate, explicitly named configurations.
    if [[ "$mode" != "docs" ]]; then
        (cd -- "$tree/crates/$crate" && cargo test --manifest-path "$manifest" --lib --tests "$@") >>"$log" 2>&1 || lib_status=$?
        lib_detail="exit $lib_status"
        {
            echo
            echo "--- cargo test --lib --tests exited $lib_status ---"
        } >>"$log"
    fi
    if [[ "$mode" != "unit" ]]; then
        (cd -- "$tree/crates/$crate" && cargo test --manifest-path "$manifest" --doc "$@") >>"$log" 2>&1 || doc_status=$?
        doc_detail="exit $doc_status"
        {
            echo
            echo "--- cargo test --doc exited $doc_status ---"
        } >>"$log"
    else
        echo "--- docs use SEPARATE xxhash-rust-docs-profile; no closed-cfg doc verdict ---" >>"$log"
    fi
    echo "--- feature selection that was attempted: ${features:-<default>} ---" >>"$log"

    (( lib_status == 0 )) || status=$lib_status
    (( doc_status == 0 )) || status=$doc_status

    local verdict
    verdict="$(classify_upstream "$log" "$status")"
    local executed
    executed="$(grep -o 'running [0-9]* test[s]*' "$log" | sort -u | tr '\n' ';' || true)"
    local results
    results="$(grep -o 'test result: [a-z]*\. [0-9]* passed[^;]*' "$log" | tr '\n' ';' || true)"
    case "$verdict" in
        ok)
            record_status "UPSTREAM-OK" "$crate$label" "features ${features:-<default>}; ${executed:-no test summary} ${results:-} (log: $log)"
            ;;
        failed)
            upstream_failures=$((upstream_failures + 1))
            record_status "UPSTREAM-FAIL" "$crate$label" "lib/tests $lib_detail, doc $doc_detail; ${executed:-no test summary} $(grep -m1 '^error' "$log" || true) (log: $log)"
            ;;
        prereq:*)
            prerequisite_gaps=$((prerequisite_gaps + 1))
            record_status "PREREQ-UNAVAIL" "$crate$label" "${verdict#prereq:}: lib/tests $lib_detail, doc $doc_detail; $(grep -m1 '^error' "$log" || echo 'no targets built') (log: $log)"
            ;;
    esac
}

run_xxhash_docs_profile() {
    local manifest="$tree/crates/xxhash-rust/Cargo.toml"
    local metadata="$run_dir/xxhash-rust-docs-profile.metadata.json"
    local config_log="$run_dir/xxhash-rust-docs-profile.config.log"
    local status=0 features verdict
    {
        echo "=== xxhash-rust-docs-profile configuration ==="
        echo "cargo metadata --format-version 1 --no-deps --manifest-path $manifest"
        echo "select root package by manifest_path; read metadata.docs.rs.features"
        echo "upstream CI source: $xxhash_docs_source"
    } >"$config_log"
    (cd -- "$tree/crates/xxhash-rust" && cargo metadata --format-version 1 --no-deps --manifest-path "$manifest") >"$metadata" 2>>"$config_log" || status=$?
    if (( status == 0 )); then
        features="$(python3 - "$metadata" "$manifest" 2>>"$config_log" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    metadata = json.load(source)
roots = [package for package in metadata["packages"]
         if os.path.realpath(package["manifest_path"]) == os.path.realpath(sys.argv[2])]
if len(roots) != 1:
    raise ValueError("cargo metadata must identify exactly one root package")
features = roots[0]["metadata"]["docs"]["rs"]["features"]
if not isinstance(features, list) or not features or any(
        not isinstance(feature, str) or not feature for feature in features):
    raise ValueError("root metadata.docs.rs.features must be a nonempty string list")
print(",".join(features))
PY
        )" || status=$?
    fi
    if (( status != 0 )); then
        echo "--- docs-profile configuration exited $status; doc target not run ---" >>"$config_log"
        verdict="$(classify_upstream "$config_log" "$status")"
        if [[ "$verdict" == prereq:* ]]; then
            prerequisite_gaps=$((prerequisite_gaps + 1))
            record_status "PREREQ-UNAVAIL" "xxhash-rust-docs-profile" "${verdict#prereq:}: config exit $status (log: $config_log)"
        else
            upstream_failures=$((upstream_failures + 1))
            record_status "UPSTREAM-FAIL" "xxhash-rust-docs-profile" "config exit $status; doc target not run (log: $config_log)"
        fi
        return
    fi
    echo "published documentation profile features: $features" >>"$config_log"
    record_status "DOCS-CONFIG" "xxhash-rust-docs-profile" "features $features; root metadata.docs.rs.features (metadata: $metadata; log: $config_log)"
    echo "    upstream CI source: $xxhash_docs_source"
    run_upstream xxhash-rust "-docs-profile" "$features" docs --features "$features"
}

for crate in "${crud_crates[@]}"; do
    if [[ "$crate" == "xxhash-rust" ]]; then
        # No default features: default unit targets legitimately run zero tests.
        # xxh32 units exercise the 32-bit algorithm. Docs run separately once.
        run_upstream "$crate" "-default" "" unit
        run_upstream "$crate" "-xxh32" "xxh32" unit --features xxh32
        run_xxhash_docs_profile
    else
        run_upstream "$crate" "" "" all
    fi
done

# ── 8. fixture version anchors ──────────────────────────────────────────────
# The receipt declares the fixture versions its expected values were taken from.
# Cargo metadata's root package, selected by manifest_path, is the authority for
# the staged version. Package IDs are opaque: path IDs need not name the package
# after '#'. No manifest is scraped by hand, and any unresolved/drifted root fails.
version_mismatches=0
if [[ -f "$default_receipt" ]]; then
    header="$(head -1 "$default_receipt")"
    : >"$run_dir/cargo-metadata-versions.log"
    for crate in adler atoi itoa seahash siphasher wyhash xxhash-rust; do
        manifest="$tree/crates/$crate/Cargo.toml"
        metadata="$run_dir/version-$crate.metadata.json"
        if ! (cd -- "$tree/crates/$crate" && cargo metadata --offline --format-version 1 --no-deps --manifest-path "$manifest") >"$metadata" 2>>"$run_dir/cargo-metadata-versions.log"; then
            version_mismatches=$((version_mismatches + 1))
            record_status "VERSION-UNRESOLVED" "$crate" "cargo metadata could not resolve $manifest (see $run_dir/cargo-metadata-versions.log)"
            continue
        fi
        if ! pkg_version="$(python3 - "$metadata" "$manifest" "$crate" 2>>"$run_dir/cargo-metadata-versions.log" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    metadata = json.load(source)
roots = [package for package in metadata["packages"]
         if os.path.realpath(package["manifest_path"]) == os.path.realpath(sys.argv[2])]
if len(roots) != 1:
    raise ValueError("cargo metadata must identify exactly one root package")
root = roots[0]
if root["name"] != sys.argv[3]:
    raise ValueError("cargo metadata root package name does not match the fixture")
version = root["version"]
if not isinstance(version, str) or not version.strip():
    raise ValueError("cargo metadata root package version must be nonempty")
print(version)
PY
        )"; then
            version_mismatches=$((version_mismatches + 1))
            record_status "VERSION-UNRESOLVED" "$crate" "cargo metadata root package/version invalid (metadata: $metadata; see $run_dir/cargo-metadata-versions.log)"
            continue
        fi
        printf '%s\t%s\n' "$crate" "$pkg_version" >>"$run_dir/cargo-metadata-versions.log"
        declared="$(printf '%s' "$header" | grep -o "\"$crate\":\"[^\"]*\"" | head -1 | cut -d'"' -f4)"
        if [[ "$declared" != "$pkg_version" ]]; then
            version_mismatches=$((version_mismatches + 1))
            record_status "VERSION-DRIFT" "$crate" "receipt declares '${declared:-<none>}', cargo resolves the staged crate as $pkg_version"
        else
            record_status "VERSION-OK" "$crate" "$pkg_version"
        fi
    done
fi

# ── 9. prove cargo wrote nothing into the repository ─────────────────────────
# Re-hash the source trees and compare against the manifests taken before any
# cargo ran. A difference means the run mutated a fixture, which is the one
# outcome this staging exists to prevent.
repo_mutations=0
for name in oracle "${crud_crates[@]}"; do
    if [[ "$name" == "oracle" ]]; then
        source_dir="$oracle_source"
    else
        source_dir="$repo_root/test/crates/$name"
    fi
    (cd -- "$source_dir" && find . -type f -print0 | sort -z | xargs -0r sha256sum) >"$run_dir/after-$name.sha256"
    if ! diff -q "$run_dir/source-$name.sha256" "$run_dir/after-$name.sha256" >/dev/null; then
        repo_mutations=$((repo_mutations + 1))
        record_status "FIXTURE-MUTATED" "$name" "a source file changed during the run; see $run_dir/after-$name.sha256"
    fi
done
if (( repo_mutations == 0 )); then
    echo "$self_name: source trees unchanged during the run (sha256 identical for the oracle and all ${#crud_crates[@]} crate roots)"
fi

# ── 10. summary ─────────────────────────────────────────────────────────────
echo
echo "$self_name: receipts"
for receipt in "$default_receipt" "$xxh32_receipt"; do
    if [[ -f "$receipt" ]]; then
        printf '  %s  %s\n' "$receipt" "$(grep -o '"summary":{[^}]*}' "$receipt")"
    else
        printf '  %s  MISSING\n' "$receipt"
    fi
done
echo "$self_name: xxhash-rust unit/integration closures: empty default and explicit xxh32; docs: SEPARATE xxhash-rust-docs-profile, root metadata.docs.rs.features (not closed-cfg doc passes)"
echo "$self_name: xxhash-rust docs-profile config/log: $run_dir/xxhash-rust-docs-profile.config.log ; $run_dir/upstream-xxhash-rust-docs-profile.log"
echo "$self_name: published docs profile / upstream CI source: $xxhash_docs_source"
echo "$self_name: run directory kept at $run_dir (logs, staged tree, cargo home, target); nothing was deleted"
echo "$self_name: failures: oracle=$oracle_failures upstream=$upstream_failures prerequisite-unavailable=$prerequisite_gaps version-drift=$version_mismatches fixture-mutations=$repo_mutations"
if (( prerequisite_gaps > 0 )) && (( strict_prerequisites == 0 )); then
    echo "$self_name: $prerequisite_gaps prerequisite gap(s) above did not fail this run; --strict-prerequisites would"
fi

exit_code=0
if (( repo_mutations > 0 )); then
    exit_code=1
fi
if (( oracle_failures > 0 || upstream_failures > 0 || version_mismatches > 0 )); then
    exit_code=1
fi
if (( prerequisite_gaps > 0 )) && (( strict_prerequisites == 1 )); then
    exit_code=1
fi

# The run directory is kept whatever the outcome: no cleanup option exists, and
# deleting a tree that cargo has been writing to is the caller's decision, made
# with the uid, mount and live-use checks the caller already owns.

exit "$exit_code"
