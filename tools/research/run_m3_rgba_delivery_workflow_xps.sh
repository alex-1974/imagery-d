#!/usr/bin/env bash
# Issue #74 native hot-hit / real source-over+eviction DeliveryHandle evidence.
# All snapshots are pinned; writes only to a new imagery-d local evidence dir.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBS="$(dirname "$REPO")"
MODE=normal
if [[ "${1:-}" == "--smoke" ]]; then MODE=smoke; shift; fi
if [[ "$#" -gt 1 ]]; then
    echo "Usage: $0 [--smoke] [new-output-directory]" >&2
    exit 2
fi
OUT="${1:-$REPO/data/m3-rgba-delivery-workflow-xps/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
[[ -z "$(ls -A "$OUT")" ]] || {
    echo "ERROR: refusing nonempty evidence directory: $OUT" >&2
    exit 1
}
for cmd in git tar dub ldc2 sha256sum lscpu python3; do
    command -v "$cmd" >/dev/null || {
        echo "ERROR: missing $cmd" >&2
        exit 1
    }
done
COMPILER="$(ldc2 --version | sed -n '1p')"
[[ "$COMPILER" == 'LDC - the LLVM D compiler (1.43.0):' ]] || {
    echo "ERROR: LDC 1.43.0 required, observed: $COMPILER" >&2
    exit 1
}
git -C "$REPO" ls-files --error-unmatch \
    tools/research/run_m3_rgba_delivery_workflow_xps.sh >/dev/null
for dep in raster-d color-d; do
    git -C "$LIBS/$dep" rev-parse -q --verify 'v0.2.0^{commit}' >/dev/null
done

# Reproducible archive rather than building a potentially dirty live checkout.
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
    echo "compiler_path=$(command -v ldc2)"
    echo "dub=$(dub --version)"
    echo "kernel=$(uname -a)"
    echo "imagery_source_commit=$(git -C "$REPO" rev-parse HEAD)"
    echo "imagery_source_branch=$(git -C "$REPO" branch --show-current)"
    echo "imagery_status_begin"
    git -C "$REPO" status --short
    echo "imagery_status_end"
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
    echo "frequencies_begin"
    for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do
        [[ ! -f "$f" ]] || echo "$f=$(<"$f")"
    done
    echo "frequencies_end"
} > "$OUT/environment.txt"

ROOT=experiments/m3_rgba_layer_compositing/smoke
(
    cd "$SNAP/imagery-d"
    dub build --root="$ROOT" --compiler=ldc2 --config=default \
        --build=release --force
) > "$OUT/build.log" 2>&1
BIN="$SNAP/imagery-d/$ROOT/m3-rgba-layer-compositing-consumer"
[[ -x "$BIN" ]] || {
    echo "ERROR: release consumer executable missing: $BIN" >&2
    exit 1
}

if [[ "$MODE" == smoke ]]; then
    rounds=2; hot=4096; churn=2; warmups=1
else
    rounds=13; hot=250000; churn=16; warmups=2
fi
for side in 16 64; do
    "$BIN" --delivery-workflow-bench "--side=$side" \
        "--rounds=$rounds" "--hot-iterations=$hot" \
        "--churn-iterations=$churn" "--warmups=$warmups" \
        > "$OUT/side-$side-runner.txt" 2> "$OUT/side-$side-stderr.txt"
    grep -q '^DELIVERY-WORKFLOW PASS:' "$OUT/side-$side-runner.txt"
    test "$(grep -c '^m3_delivery_workflow,' "$OUT/side-$side-runner.txt")" \
        -eq "$((4 * rounds))" || {
        echo "ERROR: incomplete workflow rows for side=$side" >&2
        exit 1
    }
    python3 "$SNAP/imagery-d/tools/research/summarize_m3_rgba_delivery_workflow_xps.py" \
        "$OUT/side-$side-runner.txt" > "$OUT/side-$side-summary.csv.tmp"
    [[ -s "$OUT/side-$side-summary.csv.tmp" ]] || exit 1
    mv -- "$OUT/side-$side-summary.csv.tmp" "$OUT/side-$side-summary.csv"
    {
        grep '^experiment,side,round,stage,iterations,elapsed_us,thread_gc_bytes,digest$' \
            "$OUT/side-$side-runner.txt"
        grep '^m3_delivery_workflow,' "$OUT/side-$side-runner.txt"
    } > "$OUT/side-$side-raw.csv"
done
(
    cd "$OUT"
    sha256sum environment.txt build.log side-*-runner.txt \
        side-*-raw.csv side-*-summary.csv > CHECKSUMS.sha256
    sha256sum -c CHECKSUMS.sha256
)
echo "M3 DELIVERY WORKFLOW XPS PASS: $OUT"
echo "Evidence directory contains both ROI sizes, provenance, paired rows, and checksums."
