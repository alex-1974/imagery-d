#!/usr/bin/env bash
# Issue #74, Linux/glibc all-layer *observation*, not certified full bounds.
# Writes only a new imagery-d evidence directory, never any sibling repo.
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBS="$(dirname "$REPO")"
MODE=normal
if [[ "${1:-}" == "--smoke" ]]; then MODE=smoke; shift; fi
if [[ "$#" -gt 1 ]]; then
    echo "Usage: $0 [--smoke] [new-empty-output-directory]" >&2
    exit 2
fi
OUT="${1:-$REPO/data/m3-rgba-generation-memory-xps/$(date -u +%Y%m%dT%H%M%SZ)}"
if [[ -e "$OUT" && ( ! -d "$OUT" || -n "$(ls -A "$OUT")" ) ]]; then
    echo "ERROR: refuse nonempty evidence destination $OUT" >&2
    exit 1
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
for cmd in git tar dub ldc2 sha256sum python3 lscpu grep; do
    command -v "$cmd" >/dev/null || {
        echo "ERROR: missing prerequisite $cmd" >&2; exit 1;
    }
done
COMPILER="$(ldc2 --version | sed -n '1p')"
[[ "$COMPILER" == 'LDC - the LLVM D compiler (1.43.0):' ]] || {
    echo "ERROR: native LDC 1.43.0 required, got: $COMPILER" >&2
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
    echo "host=$(hostname)"
    echo "compiler=$COMPILER"
    echo "compiler_bin=$(command -v ldc2)"
    echo "dub=$(dub --version)"
    echo "kernel=$(uname -a)"
    echo "imagery_commit=$(git -C "$REPO" rev-parse HEAD)"
    echo "imagery_branch=$(git -C "$REPO" branch --show-current)"
    echo "worktree_status_begin"
    git -C "$REPO" status --short
    echo "worktree_status_end"
    for dep in raster-d color-d; do
        echo "$dep.pinned_commit=$(git -C "$LIBS/$dep" rev-parse 'v0.2.0^{commit}')"
    done
    echo "cpu_begin"
    lscpu
    echo "cpu_end"
    echo "governors_begin"
    for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [[ ! -f "$f" ]] || echo "$f=$(<"$f")"
    done
    echo "governors_end"
} > "$OUT/environment.txt"

ROOT=experiments/m3_rgba_layer_compositing/smoke
(
    cd "$SNAP/imagery-d"
    dub build --root="$ROOT" --compiler=ldc2 --config=default \
        --build=release --force
) > "$OUT/build.log" 2>&1
BIN="$SNAP/imagery-d/$ROOT/m3-rgba-layer-compositing-consumer"
[[ -x "$BIN" ]] || {
    echo "ERROR: expected release consumer binary missing" >&2
    exit 1
}

python3 "$SNAP/imagery-d/tools/research/summarize_m3_rgba_generation_memory_xps.py" \
    --self-test > "$OUT/summary-self-test.txt"
grep -q '^GENERATION MEMORY VALIDATOR SELF-TEST PASS$' "$OUT/summary-self-test.txt"

if [[ "$MODE" == smoke ]]; then
    sides=(16 256); repetitions=1
else
    sides=(16 64 256 512); repetitions=5
fi
for side in "${sides[@]}"; do
    for ((index=0;index<repetitions;index++)); do
        key="side-${side}-run-${index}"
        echo "native memory observation: $key" >&2
        "$BIN" --generation-memory "--side=$side" \
            > "$OUT/$key.txt" 2> "$OUT/$key.stderr"
        python3 "$SNAP/imagery-d/tools/research/summarize_m3_rgba_generation_memory_xps.py" \
            "$OUT/$key.txt" > "$OUT/$key-summary.csv"
        grep -q '^M3 GENERATION MEMORY PASS:' "$OUT/$key.txt"
        test "$(grep -c '^m3_generation_memory,' "$OUT/$key.txt")" -eq 10
        test -s "$OUT/$key-summary.csv"
    done
done
(
    cd "$OUT"
    sha256sum environment.txt build.log summary-self-test.txt \
        side-*.txt side-*.stderr side-*-summary.csv > CHECKSUMS.sha256
    sha256sum -c CHECKSUMS.sha256
)
echo "M3 GENERATION MEMORY XPS PASS: $OUT"
echo "Archive this checksummed directory without snapshot/ for review."
