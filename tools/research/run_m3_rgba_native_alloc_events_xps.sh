#!/usr/bin/env bash
# Issue #74: opt-in native glibc event trace of image-generation ownership.
# Writes only imagery-d evidence; sibling repositories are read via git archive.
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBS="$(dirname "$REPO")"
MODE=normal
if [[ "${1:-}" == "--smoke" ]]; then MODE=smoke; shift; fi
if [[ "$#" -gt 1 ]]; then
    echo "Usage: $0 [--smoke] [fresh-empty-evidence-directory]" >&2
    exit 2
fi
OUT="${1:-$REPO/data/m3-native-alloc-events-xps/$(date -u +%Y%m%dT%H%M%SZ)}"
if [[ -e "$OUT" && ( ! -d "$OUT" || -n "$(ls -A "$OUT")" ) ]]; then
    echo "ERROR: refuse existing nonempty output: $OUT" >&2
    exit 1
fi
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
for command in git tar dub ldc2 cc sha256sum python3 lscpu; do
    command -v "$command" >/dev/null || {
        echo "ERROR: missing required tool: $command" >&2
        exit 1
    }
done
COMPILER="$(ldc2 --version | sed -n '1p')"
[[ "$COMPILER" == 'LDC - the LLVM D compiler (1.43.0):' ]] || {
    echo "ERROR: LDC 1.43.0 pinned, observed $COMPILER" >&2
    exit 1
}
for dep in raster-d color-d; do
    git -C "$LIBS/$dep" rev-parse -q --verify 'v0.2.0^{commit}' >/dev/null
done

SNAP="$OUT/snapshot"
mkdir -p "$SNAP/imagery-d" "$SNAP/raster-d" "$SNAP/color-d"
git -C "$REPO" archive HEAD | tar -xf - -C "$SNAP/imagery-d"
for dep in raster-d color-d; do
    git -C "$LIBS/$dep" archive v0.2.0 | tar -xf - -C "$SNAP/$dep"
done
{
    echo "utc=$(date -u --iso-8601=seconds)"
    echo "mode=$MODE"
    echo "compiler=$COMPILER"
    echo "compiler_path=$(command -v ldc2)"
    echo "cc=$(cc --version | head -n1)"
    echo "dub=$(dub --version)"
    echo "host=$(hostname)"
    echo "kernel=$(uname -a)"
    echo "source_sha=$(git -C "$REPO" rev-parse HEAD)"
    echo "source_branch=$(git -C "$REPO" branch --show-current)"
    echo "source_status_begin"
    git -C "$REPO" status --short
    echo "source_status_end"
    for dep in raster-d color-d; do
        echo "$dep.pinned_sha=$(git -C "$LIBS/$dep" rev-parse 'v0.2.0^{commit}')"
    done
    echo "cpu_begin"; lscpu; echo "cpu_end"
    echo "governors_begin"
    for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [[ ! -f "$f" ]] || echo "$f=$(<"$f")"
    done
    echo "governors_end"
} > "$OUT/environment.txt"

ROOT=experiments/m3_rgba_layer_compositing
cc -std=c11 -O2 -Wall -Wextra -Werror -fPIC -shared \
    -o "$OUT/libm3_alloc_events.so" \
    "$SNAP/imagery-d/$ROOT/alloc_events/m3_alloc_events.c" \
    > "$OUT/c-build.log" 2>&1

(
    cd "$SNAP/imagery-d"
    dub build --root="$ROOT/smoke" --compiler=ldc2 \
        --config=native-allocation-events --build=release --force
) > "$OUT/d-build.log" 2>&1
BIN="$SNAP/imagery-d/$ROOT/smoke/m3-rgba-layer-compositing-consumer"
test -x "$BIN" || {
    echo "ERROR: missing native D research consumer" >&2
    exit 1
}
PY="$SNAP/imagery-d/tools/research/summarize_m3_rgba_native_alloc_events.py"
python3 "$PY" --self-test > "$OUT/summary-self-test.txt"
grep -q '^NATIVE ALLOCATION EVENT VALIDATOR SELF-TEST PASS$' "$OUT/summary-self-test.txt"
if [[ "$MODE" == smoke ]]; then
    sides=(16 256); runs=1
else
    sides=(16 64 256 512); runs=3
fi

for side in "${sides[@]}"; do
    for ((index=0;index<runs;index++)); do
        key="side-${side}-run-${index}"
        echo "Native glibc event trace: $key" >&2
        # FD 9 is opened only in the child; events never share the
        # consumer stdout, and pointer IDs are not persisted elsewhere.
        (
            exec 9>"$OUT/$key-events.csv"
            LD_PRELOAD="$OUT/libm3_alloc_events.so" \
                "$BIN" --generation-memory "--side=$side" \
                > "$OUT/$key-stdout.txt" 2> "$OUT/$key-stderr.txt"
        )
        grep -q '^M3 GENERATION MEMORY PASS:' "$OUT/$key-stdout.txt"
        python3 "$PY" "$OUT/$key-events.csv" "$side" \
            > "$OUT/$key-summary.csv"
        test -s "$OUT/$key-summary.csv"
    done
done
(
    cd "$OUT"
    sha256sum environment.txt c-build.log d-build.log summary-self-test.txt \
        libm3_alloc_events.so side-*-events.csv side-*-stdout.txt \
        side-*-stderr.txt side-*-summary.csv > CHECKSUMS.sha256
    sha256sum -c CHECKSUMS.sha256
)
echo "M3 NATIVE EVENT TRACE PASS: $OUT"
echo "Archive the checked evidence directory excluding snapshot/ only;"
echo "the small built research interposer is included in CHECKSUMS.sha256."
