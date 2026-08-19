#!/usr/bin/env bash
set -euo pipefail

declare -A RUNNERS=(
  ### tier 1
  ["x86_64-linux"]=""

  ### tier 2
  ["aarch64-freebsd"]="skip"
  ["aarch64-linux"]="qemu-aarch64"
  ["aarch64_be-linux"]="qemu-aarch64_be"
  ["aarch64-macos"]="skip"
  ["aarch64-netbsd"]="skip"
  ["aarch64_be-netbsd"]="skip"
  ["aarch64-openbsd"]="skip"
  ["aarch64-windows"]="skip"
  ["hexagon-linux"]="qemu-hexagon"
  ["loongarch64-linux"]="qemu-loongarch64"
  ["aarch64-linux-android"]="qemu-aarch64"
  ["arm-linux"]="qemu-arm"
  ["armeb-linux"]="qemu-armeb"
  ["mips-linux"]="qemu-mips"
  ["mipsel-linux"]="qemu-mipsel"
  ["mips-netbsd"]="skip"
  ["mipsel-netbsd"]="skip"
  ["mips64-linux"]="qemu-mips64"
  ["mips64el-linux"]="qemu-mips64el"
  ["mips64-openbsd"]="skip"
  ["mips64el-openbsd"]="skip"
  ["powerpc-linux"]="qemu-ppc"
  ["powerpc-netbsd"]="skip"
  ["powerpc64-linux"]="qemu-ppc64"
  ["powerpc64le-linux"]="qemu-ppc64le"
  ["powerpc64-freebsd"]="skip"
  ["powerpc64le-freebsd"]="skip"
  ["powerpc64-openbsd"]="skip"
  ["riscv32-linux"]="qemu-riscv32"
  ["riscv64-linux"]="qemu-riscv64"
  ["riscv64-openbsd"]="skip"
  ["s390x-linux"]="qemu-s390x"
  ["thumb-windows"]="skip"
  ["wasm32-wasi"]="skip"  # run skipped: Io.futexWait traps on single-threaded wasm (spawn/event tests)
  ["x86-linux"]=""
  ["x86-netbsd"]="skip"
  ["x86-openbsd"]="skip"
  ["x86-windows"]="env -S WINEDEBUG=-all wine"
  ["x86_64-freebsd"]="skip"
  ["x86_64-maccatalyst"]="skip"
  ["x86_64-macos"]="skip"
  ["x86_64-netbsd"]="skip"
  ["x86_64-openbsd"]="skip"
  ["x86_64-windows"]="env -S WINEDEBUG=-all wine"
)

if [ -z "${TARGETS+x}" ]; then
  TARGETS=("${!RUNNERS[@]}")
fi

BUILD_DIR="./zig-out"
mkdir -p "$BUILD_DIR"

# Timestamp applied to all log files so successive runs don't clash.
TS="$(date +%Y%m%d-%H%M%S)"

# -- helpers --

BUILD_FAILED=()
RUN_FAILED=()

# Measure the widest target name for log alignment.
max_target=0
for t in "${TARGETS[@]}"; do
  len=${#t}
  if [ "$len" -gt "$max_target" ]; then max_target=$len; fi
done

# Determine the interior box width.
# The longest line inside the box is e.g.: "Build failures:      [fail] powerpc64-openbsd"
num_targets="${#TARGETS[@]}"
# Rough interior content lengths for summary lines
len_total="Total targets:      $num_targets"                              # ~26
len_build_ok="Build failures:      ✅ none"                               # ~33
len_run_ok="Run failures:        ✅ none"                                 # ~33
# For failures, the target name makes it longer.
len_fail="Build failures:      💥 "                                       # ~27 plus target
# Find the longest target name for failure lines.
longest_target=0
for t in "${TARGETS[@]}"; do
  len=${#t}
  [ "$len" -gt "$longest_target" ] && longest_target=$len
done

# Compute interior width: header + side padding vs. content lines
inner=$(( 30 > (27 + longest_target) ? 30 : (27 + longest_target) ))
# Ensure at least 42
[ "$inner" -lt 42 ] && inner=42

# Pre-compute the horizontal rule.
# Rule lines: "  ╭" + hr + "╮"  → total = inner + 6
# Box lines:  "  │ " + content(padded inner) + " │" → total = inner + 6
# So hr must be inner + 2 dashes to match.
hr="$(printf "─%.0s" $(seq 1 $((inner + 2))))"

# Resolve the test binary path for a given target.
exe_path() {
  local target="$1"
  local exe="$BUILD_DIR/bin/skript-test-$target"
  if [[ "$target" == *"windows"* ]]; then
    echo "$exe.exe"
  elif [[ "$target" == *"wasm32-wasi"* ]]; then
    echo "$exe.wasm"
  else
    echo "$exe"
  fi
}

# Print a log line (goes to stderr).
log() {
  local target="$1"
  local symbol="$2"
  local msg="$3"
  printf >&2 "  %-*s  %s  %s\n" "$max_target" "$target" "$symbol" "$msg"
}

# Print a box line:  │ <content padded to inner> │
# The caller passes just the interior content (no │ borders).
box() {
  local content="$1"
  printf >&2 "  │ %-*s │\n" "$inner" "$content"
}

# Print a horizontal rule with given left/right corners:  ╭────╮
rule() {
  local left="$1" right="$2"
  printf >&2 "  %s%s%s\n" "$left" "$hr" "$right"
}

# -- phase 0: native build (sequential, populates cache) --

echo >&2 ""
rule "╭" "╮"
box  "CROSS-TEST: NATIVE BUILD (cache warm)"
rule "╰" "╯"
echo >&2 ""

NATIVE_TARGET="$(zig env 2>/dev/null | grep '\.target = ' | head -1 | sed 's/.*= "\(.*\)",*/\1/' | sed 's/\.[0-9].*//')"
if [ -z "$NATIVE_TARGET" ]; then
  NATIVE_TARGET="native"
fi

log "$NATIVE_TARGET" "🔨" "native build to populate cache ..."
logfile="$BUILD_DIR/build-native-$TS.log"
if zig build test-compile --prefix "$BUILD_DIR" > "$logfile" 2>&1; then
  rm -f "$logfile"
  log "$NATIVE_TARGET" "✅" "native build ok"
else
  rc=$?
  log "$NATIVE_TARGET" "💥" "native build FAILED (exit $rc) — log: $logfile"
  exit $rc
fi

# -- phase 1: compile all targets in parallel (cache already warm) --

echo >&2 ""
rule "╭" "╮"
box  "CROSS-TEST: BUILD PHASE"
rule "╰" "╯"
echo >&2 ""

MAX_JOBS=$(( $(nproc) / 2 ))  # limit to half the cores to avoid thrashing
[ "$MAX_JOBS" -lt 1 ] && MAX_JOBS=1

build_pids=()
for target in "${TARGETS[@]}"; do
  # throttle: wait if at capacity
  if [ ${#build_pids[@]} -ge $MAX_JOBS ]; then
    wait -n 2>/dev/null || true  # wait for any single job (ignore exit)
    # rebuild pid list: remove finished pids
    new_pids=()
    for pid in "${build_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        new_pids+=("$pid")
      fi
    done
    build_pids=("${new_pids[@]}")
  fi

  (
    logfile="$BUILD_DIR/build-$target-$TS.log"
    log "$target" "🔨" "compiling ..."
    if zig build test-compile -Dtarget="$target" --prefix "$BUILD_DIR" > "$logfile" 2>&1; then
      rm -f "$logfile"
      log "$target" "✅" "build ok"
      exit 0
    else
      rc=$?
      log "$target" "💥" "build FAILED (exit $rc) — log: $logfile"
      exit $rc
    fi
  ) &
  build_pids+=("$!")
done

i=0
for pid in "${build_pids[@]}"; do
  target="${TARGETS[$i]}"
  wait "$pid" || BUILD_FAILED+=("$target")
  i=$((i + 1))
done

echo >&2 ""

# -- phase 2: run all targets in parallel --

rule "╭" "╮"
box  "CROSS-TEST: RUN PHASE"
rule "╰" "╯"
echo >&2 ""

run_pids=()
for target in "${TARGETS[@]}"; do
  (
    runner="${RUNNERS[$target]}"
    exe="$(exe_path "$target")"

    if [ "$runner" = "skip" ]; then
      log "$target" "⏭️" "skipped (runner=skip)"
      exit 0
    fi

    if [ ! -f "$exe" ]; then
      log "$target" "⚠️" "binary not found at $(basename "$exe")"
      exit 0
    fi

    logfile="$BUILD_DIR/run-$target-$TS.log"
    log "$target" "▶️" "running${runner:+ via $runner} ..."
    if [ -z "$runner" ]; then
      cmd="$exe"
    else
      cmd="$runner $exe"
    fi
    if $cmd > "$logfile" 2>&1; then
      rm -f "$logfile"
      log "$target" "✅" "all tests passed"
      exit 0
    else
      rc=$?
      log "$target" "💥" "run FAILED (exit $rc) — log: $logfile"
      exit $rc
    fi
  ) &
  run_pids+=("$!")
done

i=0
for pid in "${run_pids[@]}"; do
  target="${TARGETS[$i]}"
  wait "$pid" || RUN_FAILED+=("$target")
  i=$((i + 1))
done

echo >&2 ""

# -- summary --

rule "╭" "╮"
box  "CROSS-TEST SUMMARY"
rule "├" "┤"
box  "Total targets:      $num_targets"

if [ ${#BUILD_FAILED[@]} -eq 0 ]; then
  box "Build failures:      [ok]  none"
else
  for f in "${BUILD_FAILED[@]}"; do
    box "Build failures:      [fail] $f"
  done
fi

if [ ${#RUN_FAILED[@]} -eq 0 ]; then
  box "Run failures:        [ok]  none"
else
  for f in "${RUN_FAILED[@]}"; do
    box "Run failures:        [fail] $f"
  done
fi

rule "╰" "╯"
echo >&2 ""

if [ ${#BUILD_FAILED[@]} -gt 0 ] || [ ${#RUN_FAILED[@]} -gt 0 ]; then
  exit 1
fi
