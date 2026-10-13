#!/usr/bin/env bash
# Reproducible research-only stage profiling. Never modifies sibling repos.
# Results and temporary pinned source snapshots live ONLY under imagery-d/data/.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBS="$(dirname "$REPO")"
MODE=full
if [[ "${1:-}" == "--smoke" ]]; then MODE=smoke; shift; fi
if [[ "${1:-}" == "--micro" ]]; then MODE=micro; shift; fi
if [[ "${1:-}" == "--micro-smoke" ]]; then MODE=micro_smoke; shift; fi
if [[ "$#" -gt 1 ]]; then
    echo "Usage: $0 [--smoke|--micro|--micro-smoke] [output-directory]" >&2
    exit 2
fi
OUT="${1:-$REPO/data/m3-rgba-hotpath-xps/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
# Do not overwrite previous or partially collected evidence.
if [[ -n "$(ls -A "$OUT")" ]]; then
    echo "ERROR: evidence output directory is not empty: $OUT" >&2
    exit 1
fi

for command in git tar dub ldc2 sha256sum python3; do
    if ! type "$command" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $command" >&2
        exit 1
    fi
done
COMPILER="$(ldc2 --version | sed -n '1p')"
if [[ "$COMPILER" != "LDC - the LLVM D compiler (1.43.0):" ]]; then
    echo "ERROR: this qualified XPS research series requires LDC 1.43.0; observed $COMPILER" >&2
    exit 1
fi
if [[ -n "$(git -C "$REPO" status --porcelain)" ]]; then
    echo "NOTE: the live imagery-d working tree has local changes; pinned source" \
         "snapshot uses committed HEAD only (no files will be discarded)." \
         | tee "$OUT/working-tree-notice.txt"
fi
for dep in raster-d color-d; do
    git -C "$LIBS/$dep" rev-parse -q --verify 'v0.2.0^{commit}' >/dev/null
done

SNAP="$OUT/snapshot"
mkdir -p "$SNAP/imagery-d" "$SNAP/raster-d" "$SNAP/color-d"
git -C "$REPO" archive --format=tar HEAD | tar -xf - -C "$SNAP/imagery-d"
for dep in raster-d color-d; do
    git -C "$LIBS/$dep" archive --format=tar v0.2.0 | tar -xf - -C "$SNAP/$dep"
done
{
    echo "utc=$(date -u --iso-8601=seconds)"
    echo "host=$(hostname)"
    echo "source_mode=pinned-v0.2.0"
    echo "compiler=$COMPILER"
    echo "compiler_bin=$(command -v ldc2)"
    echo "dub=$(dub --version)"
    echo "kernel=$(uname -a)"
    echo "imagery_branch=$(git -C "$REPO" branch --show-current)"
    echo "imagery_measured_commit=$(git -C "$REPO" rev-parse HEAD)"
    for dep in raster-d color-d; do
        echo "$dep.measured_commit=$(git -C "$LIBS/$dep" rev-parse 'v0.2.0^{commit}')"
        echo "$dep.live_commit=$(git -C "$LIBS/$dep" rev-parse HEAD)"
        echo "$dep.live_status_begin"
        git -C "$LIBS/$dep" status --short
        echo "$dep.live_status_end"
    done
    echo "smoke=$([[ "$MODE" == smoke || "$MODE" == micro_smoke ]] && echo 1 || echo 0)"
    echo "mode=$MODE"
    echo "cpu_begin"
    lscpu
    echo "cpu_end"
    echo "governors_begin"
    for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        if [[ -f "$f" ]]; then echo "$f=$(<"$f")"; fi
    done
    echo "governors_end"
    echo "mem_begin"
    grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo
    echo "mem_end"
} > "$OUT/environment.txt"

ROOT=experiments/m3_rgba_layer_compositing/hotpath
(
    cd "$SNAP/imagery-d"
    dub build --root="$ROOT" --compiler=ldc2 --build=release --force
) > "$OUT/build.log" 2>&1
BIN="$SNAP/imagery-d/$ROOT/m3-rgba-hotpath-attribution"
test -x "$BIN"

if [[ "$MODE" == "smoke" ]]; then
    specs=(48:32:2:1)
    patterns=(mixed)
    rois=(whole partial)
elif [[ "$MODE" == "micro_smoke" ]]; then
    specs=(192:192:2:2)
    patterns=(mixed)
    rois=(square16 square64)
elif [[ "$MODE" == "micro" ]]; then
    specs=(512:512:7:24)
    patterns=(mixed transparent)
    rois=(square16 square32 square64 square128)
else
    specs=(512:512:5:2 1024:768:4:2)
    patterns=(mixed opaque transparent)
    rois=(whole partial)
fi

for spec in "${specs[@]}"; do
    IFS=: read -r w h rounds iterations <<< "$spec"
    for pattern in "${patterns[@]}"; do
        for layout in interleaved planar; do
            for roi in "${rois[@]}"; do
                key="${w}x${h}-${pattern}-${layout}-${roi}"
                args=(--width="$w" --height="$h"
                    --rounds="$rounds" --iterations="$iterations"
                    --pattern="$pattern" --layout="$layout")
                if [[ "$roi" == partial ]]; then args+=(--partial); fi
                if [[ "$roi" == square* ]]; then
                    args+=("--roi-side=${roi#square}")
                fi
                echo "Running $key" >&2
                /usr/bin/time -v -o "$OUT/$key-resource.txt" \
                    "$BIN" "${args[@]}" > "$OUT/$key.csv" \
                    2> "$OUT/$key-stderr.log"
                grep -q '^HOTPATH-STAGES PASS:' "$OUT/$key.csv"
                expected_rows=$((rounds * 10))
                actual_rows="$(grep -Ec '^(mixed|opaque|transparent),(planar|interleaved),(whole|partial|square[0-9]+),' "$OUT/$key.csv")"
                if [[ "$actual_rows" -ne "$expected_rows" ]]; then
                    echo "ERROR: missing stage rows in $key" >&2
                    exit 1
                fi
                if grep -Eq '^.*,[1-9][0-9]*,[0-9]+$' "$OUT/$key.csv"; then
                    echo "ERROR: nonzero GC bytes in $key" >&2
                    exit 1
                fi
            done
        done
    done
done
(
    cd "$OUT"
    sha256sum ./*.csv > CHECKSUMS.sha256
    sha256sum -c CHECKSUMS.sha256
)
python3 "$REPO/tools/research/summarize_m3_rgba_hotpath.py" "$OUT" > "$OUT/STAGE_SUMMARY.csv"
test -s "$OUT/STAGE_SUMMARY.csv"
echo "M3 HOTPATH XPS PASS: stored results at $OUT"
echo "Archive for review: tar --exclude='./snapshot' -czf ~/Downloads/hotpath-xps.tar.gz -C '$OUT' ."
