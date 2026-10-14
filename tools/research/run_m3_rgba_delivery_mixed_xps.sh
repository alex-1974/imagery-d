#!/usr/bin/env bash
# Issue #74 native mixed direct-mapped subscriber cache workload.
# Writes only new imagery-d-local evidence, never sibling repositories.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBS="$(dirname "$REPO")"
MODE=normal
if [[ "${1:-}" == "--smoke" ]]; then MODE=smoke; shift; fi
if [[ "$#" -gt 1 ]]; then
    echo "Usage: $0 [--smoke] [new-output-directory]" >&2
    exit 2
fi
OUT="${1:-$REPO/data/m3-rgba-delivery-mixed-xps/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
[[ -z "$(ls -A "$OUT")" ]] || {
    echo "ERROR: refuse nonempty evidence directory: $OUT" >&2
    exit 1
}
for command in git tar dub ldc2 sha256sum python3 lscpu; do
    command -v "$command" >/dev/null || {
        echo "Missing: $command" >&2; exit 1
    }
done
COMPILER="$(ldc2 --version | sed -n '1p')"
[[ "$COMPILER" == 'LDC - the LLVM D compiler (1.43.0):' ]] || {
    echo "ERROR: pinned LDC 1.43.0 required: $COMPILER" >&2
    exit 1
}
git -C "$REPO" ls-files --error-unmatch \
    tools/research/run_m3_rgba_delivery_mixed_xps.sh >/dev/null
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
    echo "host=$(hostname)"
    echo "mode=$MODE"
    echo "compiler=$COMPILER"
    echo "compiler_bin=$(command -v ldc2)"
    echo "dub=$(dub --version)"
    echo "kernel=$(uname -a)"
    echo "imagery_commit=$(git -C "$REPO" rev-parse HEAD)"
    echo "imagery_branch=$(git -C "$REPO" branch --show-current)"
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
    echo "ERROR: missing release executable: $BIN" >&2
    exit 1
}

if [[ "$MODE" == smoke ]]; then
    rounds=2; requests=100; warmups=0
else
    rounds=9; requests=200; warmups=1
fi
python3 "$SNAP/imagery-d/tools/research/summarize_m3_rgba_delivery_mixed_xps.py" \
    --self-test > "$OUT/summary-self-test.txt"
grep -q '^MIXED DELIVERY SUMMARY SELF-TEST PASS$' "$OUT/summary-self-test.txt"

for side in 16 64; do
    for hit in 25 75 95; do
        for subscribers in 1 2 4; do
            key="side-${side}-hit-${hit}-subs-${subscribers}"
            echo "Running $key ($rounds rounds, $requests requests per variant)" >&2
            "$BIN" --delivery-mixed-bench "--side=$side" \
                "--hit=$hit" "--subscribers=$subscribers" \
                "--rounds=$rounds" "--requests=$requests" \
                "--warmups=$warmups" \
                > "$OUT/$key-runner.txt" 2> "$OUT/$key-stderr.txt"
            grep -q '^DELIVERY-MIXED PASS:' "$OUT/$key-runner.txt"
            test "$(grep -c '^m3_delivery_mixed,' "$OUT/$key-runner.txt")" \
                -eq "$((2 * rounds))" || {
                echo "ERROR: incomplete mixed rows in $key" >&2; exit 1;
            }
            python3 "$SNAP/imagery-d/tools/research/summarize_m3_rgba_delivery_mixed_xps.py" \
                "$OUT/$key-runner.txt" > "$OUT/$key-summary.csv.tmp"
            test -s "$OUT/$key-summary.csv.tmp"
            mv -- "$OUT/$key-summary.csv.tmp" "$OUT/$key-summary.csv"
            grep -q "^median,${side},${hit},${subscribers},${rounds}," \
                "$OUT/$key-summary.csv"
            {
                grep '^experiment,side,hit_percent,subscribers,round,variant,requests,hits,misses,evictions,retains,refunds,elapsed_us,thread_gc_bytes,digest$' \
                    "$OUT/$key-runner.txt"
                grep '^m3_delivery_mixed,' "$OUT/$key-runner.txt"
            } > "$OUT/$key-raw.csv"
        done
    done
done

(
    cd "$OUT"
    sha256sum environment.txt build.log summary-self-test.txt \
        *-runner.txt *-raw.csv *-summary.csv > CHECKSUMS.sha256
    sha256sum -c CHECKSUMS.sha256
)
echo "M3 DELIVERY MIXED XPS PASS: $OUT"
echo "Archive the checksummed evidence directory excluding snapshot before uploading."
