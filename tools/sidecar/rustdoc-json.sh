#!/usr/bin/env sh
# rustdoc-json.sh — v0 sidecar producer for translate-rust.
#
# Dumps one Cargo package's crate as rustdoc JSON and copies it to a
# crate-<name>.json sidecar artifact, the wire input of the model's JSON
# boundary (notes/design/data-model-plan.md P1; data-model.md §4).
#
# Usage:
#   tools/sidecar/rustdoc-json.sh <pkg-dir> [output-dir]
#
#   <pkg-dir>    a Cargo package directory containing Cargo.toml
#   [output-dir] where crate-<name>.json is written (default: ./target)
#
# Runs (nightly only — --output-format json is an unstable option):
#   cargo +nightly rustdoc --lib --manifest-path <pkg>/Cargo.toml \
#     -- --output-format json -Z unstable-options --document-private-items
set -euo pipefail

pkg_dir=$1
out_dir=${2:-./target}

if [ -z "$pkg_dir" ]; then
    echo "error: usage: $0 <pkg-dir> [output-dir]" >&2
    exit 2
fi

manifest="$pkg_dir/Cargo.toml"
if [ ! -f "$manifest" ]; then
    echo "error: no Cargo.toml found at '$manifest'" >&2
    exit 2
fi

# Resolve the crate name from [package] name = "..." in Cargo.toml without
# relying on find/ls or the build products directory.
crate_name=$(
    awk '
        /^\[/ { in_pkg = 0 }
        /^\[package\]/ { in_pkg = 1; next }
        in_pkg && /^[[:space:]]*name[[:space:]]*=/ {
            sub(/^[^=]*=/, "")
            gsub(/[[:space:]]/, "")
            gsub(/"/, "")
            print
            exit
        }
    ' "$manifest"
)
if [ -z "$crate_name" ]; then
    echo "error: could not resolve package.name from '$manifest'" >&2
    exit 2
fi

# Fail fast with a clear message when the nightly toolchain / rustdoc JSON
# support is missing (the format requires a nightly compiler). `rustup run`
# avoids needing a Cargo.toml in the current directory for the probe.
if ! rustup run nightly rustdoc --version >/dev/null 2>&1; then
    echo "error: nightly toolchain or rustdoc is missing; install it with:" >&2
    echo "  rustup toolchain install nightly" >&2
    exit 1
fi

mkdir -p "$out_dir"

# Build into a cargo-target dir scoped under the output dir so we never write
# into the package's own target/ and the produced <target>/doc/<name>.json is
# deterministic.
cargo_target="$out_dir/cargo-target"
export CARGO_TARGET_DIR="$cargo_target"
export RUSTFLAGS="${RUSTFLAGS:--C linker=clang}"

cargo +nightly rustdoc --all-features --lib --manifest-path "$manifest" \
    -- --output-format json -Z unstable-options --document-private-items

json_src="$cargo_target/doc/$crate_name.json"
if [ ! -f "$json_src" ]; then
    echo "error: rustdoc did not produce '$json_src'" >&2
    exit 1
fi

output="$out_dir/crate-$crate_name.json"
cp "$json_src" "$output"
echo "wrote: $output"
