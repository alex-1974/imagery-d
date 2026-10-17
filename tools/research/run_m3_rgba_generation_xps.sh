#!/usr/bin/env bash
# Issue #74: pinned native evidence for three-ticket generation lifetime,
# synchronous cancellation, and observed GC metadata allocation.
# Only creates a NEW evidence tree under imagery-d; no sibling writes.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBS="$(dirname "$REPO")"
MODE=normal
if [[ "${1:-}" == "--smoke" ]]; then MODE=smoke; shift; fi
if [[ "$#" -gt 1 ]]; then
    echo "Usage: $0 [--smoke] [new-output-directory]" >&2
    exit 2
fi
OUT="${1:-$REPO/data/m3-rgba-generation-xps/$(date -u +%Y%m%dT%H%M%SZ)}"
if [[ -e "$OUT" ]]; then
    [[ -d "$OUT" && -z "$(ls -A "$OUT")" ]] || {
        echo "ERROR: refusing nonempty evidence directory: $OUT" >&2
        exit 1
    }
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

for tool in git tar dub ldc2 sha256sum lscpu awk grep; do
    command -v "$tool" >/dev/null || {
        echo "ERROR: missing $tool" >&2; exit 1;
    }
done
compiler="$(ldc2 --version | sed -n '1p')"
[[ "$compiler" == 'LDC - the LLVM D compiler (1.43.0):' ]] || {
    echo "ERROR: exact LDC 1.43.0 required, got: $compiler" >&2
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
    echo "compiler=$compiler"
    echo "compiler_path=$(command -v ldc2)"
    echo "dub=$(dub --version)"
    echo "host=$(hostname)"
    echo "kernel=$(uname -a)"
    echo "source_commit=$(git -C "$REPO" rev-parse HEAD)"
    echo "source_branch=$(git -C "$REPO" branch --show-current)"
    echo "source_worktree_status_begin"
    git -C "$REPO" status --short
    echo "source_worktree_status_end"
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
    echo "ERROR: missing independent consumer: $BIN" >&2; exit 1;
}

runs=3
[[ "$MODE" != smoke ]] || runs=1
echo "run,metadata_thread_gc_bytes,cancellation_pass,multigeneration_pass" \
    > "$OUT/generation-summary.csv"
for ((run=0;run<runs;run++)); do
    log="$OUT/consumer-run-${run}.txt"
    "$BIN" > "$log" 2> "$OUT/consumer-run-${run}.stderr"
    grep -q '^M3 RGBA multigeneration PASS:' "$log"
    grep -q '^M3 RGBA generation cancellation PASS:' "$log"
    grep -q '^M3 RGBA composite consumer PASS: 432 scenes, 51840' "$log"
    metadata="$(awk '/^M3 RGBA multigeneration GC metadata observation: / { print $7 }' "$log")"
    [[ "$metadata" =~ ^[0-9]+$ ]] || {
        echo "ERROR: no single numeric metadata observation in run $run: [$metadata]" >&2
        exit 1
    }
    echo "$run,$metadata,yes,yes" >> "$OUT/generation-summary.csv"
done
(
    cd "$OUT"
    sha256sum environment.txt build.log generation-summary.csv \
        consumer-run-*.txt consumer-run-*.stderr > CHECKSUMS.sha256
    sha256sum -c CHECKSUMS.sha256
)
echo "M3 GENERATION XPS PASS: $OUT"
echo "Upload the checksummed directory as an archive, excluding snapshot/"
