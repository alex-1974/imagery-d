#!/usr/bin/env bash
# Research-only, *identical public raster.zipTransformInto* LUT on/off XPS A/B.
# All source snapshots belong ONLY to ignored imagery-d/data; siblings read-only.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBS="$(dirname "$REPO")"
MODE=full
if [[ "${1:-}" == "--smoke" ]]; then MODE=smoke; shift; fi
if [[ "${1:-}" == "--micro" ]]; then
    if [[ "$MODE" != "full" ]]; then
        echo "--micro and --smoke are mutually exclusive" >&2
        exit 2
    fi
    MODE=micro
    shift
fi
if [[ "$#" -gt 1 ]]; then
    echo "Usage: $0 [--smoke|--micro] [absolute-output-directory]" >&2
    exit 2
fi
OUT="${1:-$REPO/data/m3-rgba-lut-zip-xps/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
for tool in git tar dub ldc2 sha256sum awk; do
    command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }
done
COMPILER="$(ldc2 --version | sed -n '1p')"
if [[ "$COMPILER" != "LDC - the LLVM D compiler (1.43.0):" ]]; then
    echo "Must run on LDC 1.43.0: $COMPILER" >&2
    exit 1
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
    echo "source_mode=pinned-v0.2.0"
    echo "smoke=$([[ "$MODE" == smoke ]] && echo 1 || echo 0)"
    echo "mode=$MODE"
    echo "compiler=$COMPILER"
    echo "compiler_binary=$(command -v ldc2)"
    echo "dub=$(dub --version)"
    echo "uname=$(uname -a)"
    echo "hostname=$(hostname)"
    echo "imagery_measured_commit=$(git -C "$REPO" rev-parse HEAD)"
    echo "imagery_branch=$(git -C "$REPO" branch --show-current)"
    echo "imagery_live_status_begin"
    git -C "$REPO" status --short
    echo "imagery_live_status_end"
    for dep in raster-d color-d; do
        echo "$dep.measured_commit=$(git -C "$LIBS/$dep" rev-parse 'v0.2.0^{commit}')"
        echo "$dep.live_commit=$(git -C "$LIBS/$dep" rev-parse HEAD)"
        echo "$dep.live_status_begin"
        git -C "$LIBS/$dep" status --short
        echo "$dep.live_status_end"
    done
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

ROOT=experiments/m3_rgba_layer_compositing/lut_packed_zip
(
    cd "$SNAP/imagery-d"
    dub build --root="$ROOT" --compiler=ldc2 --build=release --force
) > "$OUT/build.log" 2>&1
BIN="$SNAP/imagery-d/$ROOT/m3-rgba-lut-packed-zip"
test -x "$BIN"

if [[ "$MODE" == "smoke" ]]; then
    sizes=(48:40:2:1)
    patterns=(mixed)
    rois=(whole partial)
elif [[ "$MODE" == "micro" ]]; then
    # Many repeats amortize timing granularity for tiny offset regions.
    # Both variants still use the same public alias-checked zip operation.
    sizes=(512:512:9:32)
    patterns=(mixed transparent)
    rois=(square16 square32 square64 square128)
else
    sizes=(512:512:7:3 2048:2048:5:2)
    patterns=(mixed opaque transparent)
    rois=(whole partial)
fi
count=0
for size in "${sizes[@]}"; do
    IFS=: read -r width height rounds iterations <<< "$size"
    for pattern in "${patterns[@]}"; do
        for layout in compact padded; do
            for roi in "${rois[@]}"; do
                name="${width}x${height}-${pattern}-${layout}-${roi}"
                args=(--width="$width" --height="$height"
                    --rounds="$rounds" --iterations="$iterations"
                    --pattern="$pattern" --layout="$layout")
                if [[ "$roi" == "partial" ]]; then args+=(--partial); fi
                if [[ "$roi" == square* ]]; then
                    args+=("--roi-side=${roi#square}")
                fi
                echo "Running $name" >&2
                /usr/bin/time -v -o "$OUT/$name-resource.txt" \
                    "$BIN" "${args[@]}" > "$OUT/$name.csv" \
                    2> "$OUT/$name-stderr.log"
                awk -F, -v n="$rounds" '
                    NR==1 { if(NF!=14 || $1!="pattern") exit 10; next }
                    /^ZIP-EXACT-LUT PASS:/ { pass++; next }
                    { if(NF!=14 || $11!=0 || $13!=0) exit 11; rows++ }
                    END { if(pass!=1 || rows!=n) exit 12 }
                ' "$OUT/$name.csv"
                count=$((count+1))
            done
        done
    done
done
(
    cd "$OUT"
    sha256sum ./*.csv > CHECKSUMS.sha256
    sha256sum -c CHECKSUMS.sha256
)
echo "PACKED ZIP LUT XPS PASS: $count cases, LDC 1.43 pinned v0.2.0 at $OUT"
echo "Package: tar --exclude='./snapshot' -czf ~/Downloads/m3-rgba-lut-zip-xps.tar.gz -C '$OUT' ."
