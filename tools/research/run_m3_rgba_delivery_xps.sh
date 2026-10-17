#!/usr/bin/env bash
# Native XPS evidence runner for independent delivery control-plane costs.
# Never treats GitHub-hosted CI timings as native XPS data.
# All work goes to ignored imagery-d/data or an explicit new output directory.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBS="$(dirname "$REPO")"
MODE=normal
if [[ "${1:-}" == "--smoke" ]]; then MODE=smoke; shift; fi
if [[ "$#" -gt 1 ]]; then
    echo "Usage: $0 [--smoke] [new-output-directory]" >&2
    exit 2
fi
OUT="${1:-$REPO/data/m3-rgba-delivery-xps/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
[[ -z "$(ls -A "$OUT")" ]] || {
    echo "Output directory must be empty: $OUT" >&2; exit 1;
}
for c in git tar dub ldc2 sha256sum lscpu python3; do
    command -v "$c" >/dev/null || { echo "Missing $c" >&2; exit 1; }
done
COMPILER="$(ldc2 --version | sed -n '1p')"
[[ "$COMPILER" == 'LDC - the LLVM D compiler (1.43.0):' ]] || {
    echo "Require exact supported XPS compiler: LDC 1.43.0; got $COMPILER" >&2
    exit 1
}
git -C "$REPO" ls-files --error-unmatch tools/research/run_m3_rgba_delivery_xps.sh >/dev/null
for dep in raster-d color-d; do
    git -C "$LIBS/$dep" rev-parse -q --verify 'v0.2.0^{commit}' >/dev/null
done

# Immutable checkout of the committing source for reproducibility. Live dirty
# working trees and other sibling repos are never edited.
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
    echo "os=$(uname -a)"
    echo "compiler=$COMPILER"
    echo "compiler_path=$(command -v ldc2)"
    echo "dub=$(dub --version)"
    echo "imagery_commit=$(git -C "$REPO" rev-parse HEAD)"
    echo "imagery_live_branch=$(git -C "$REPO" branch --show-current)"
    echo "imagery_status_begin"
    git -C "$REPO" status --short
    echo "imagery_status_end"
    for dep in raster-d color-d; do
        echo "$dep.pinned_commit=$(git -C "$LIBS/$dep" rev-parse 'v0.2.0^{commit}')"
    done
    echo "cpu_begin"
    lscpu
    echo "cpu_end"
    echo "cpu_governors_begin"
    for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [[ ! -f "$f" ]] || echo "$f=$(<"$f")"
    done
    echo "cpu_governors_end"
} > "$OUT/environment.txt"

ROOT=experiments/m3_rgba_layer_compositing/smoke
(
    cd "$SNAP/imagery-d"
    dub build --root="$ROOT" --compiler=ldc2 --config=default \
      --build=release --force
) > "$OUT/build.log" 2>&1
BIN="$SNAP/imagery-d/$ROOT/m3-rgba-layer-compositing-consumer"
[[ -x "$BIN" ]] || { echo "Missing executable: $BIN" >&2; exit 1; }

if [[ "$MODE" == smoke ]]; then
    rounds=2; iterations=4096; warmups=1
else
    rounds=13; iterations=250000; warmups=4
fi
# The app benchmark alternates raw/controlled order per round. It is
# deliberately separate from the full raster source-over cost.
"$BIN" --delivery-bench \
    "--rounds=$rounds" "--iterations=$iterations" "--warmups=$warmups" \
    > "$OUT/runner.txt" 2> "$OUT/stderr.txt"
grep -q '^DELIVERY-BENCH PASS:' "$OUT/runner.txt"
grep -q '^DELIVERY-METADATA research_cache_control_gc_thread_bytes=' "$OUT/runner.txt"
test "$(grep -c '^m3_delivery,' "$OUT/runner.txt")" -eq "$((2 * rounds))"
{
    grep '^experiment,round,stage,iterations,elapsed_us,thread_gc_bytes,completed_pairs$' "$OUT/runner.txt"
    grep '^m3_delivery,' "$OUT/runner.txt"
} > "$OUT/paired-raw.csv"
test "$(wc -l < "$OUT/paired-raw.csv")" -eq "$((1 + 2 * rounds))"
(
    cd "$OUT"
    sha256sum paired-raw.csv runner.txt environment.txt build.log \
      > CHECKSUMS.sha256
    sha256sum -c CHECKSUMS.sha256
)
python3 "$SNAP/imagery-d/tools/research/summarize_m3_rgba_delivery_xps.py" \
    "$OUT/runner.txt" > "$OUT/paired-summary.csv.tmp"
test -s "$OUT/paired-summary.csv.tmp"
mv -- "$OUT/paired-summary.csv.tmp" "$OUT/paired-summary.csv"
(
    cd "$OUT"
    sha256sum paired-summary.csv >> CHECKSUMS.sha256
    sha256sum -c CHECKSUMS.sha256
)
echo "M3 DELIVERY XPS EVIDENCE PASS: $OUT"
echo "Raw CSVs, environment, checksums and build.log are local; attach the evidence archive for analysis."
