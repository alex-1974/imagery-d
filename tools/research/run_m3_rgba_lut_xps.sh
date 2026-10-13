#!/usr/bin/env bash
# Research-only exact 8-bit sRGB decode LUT benchmark on the local XPS.
# Never modifies sibling repositories. Pin their tagged sources with git archive.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBS="$(dirname "$REPO")"
SMOKE=0
if [[ "${1:-}" == "--smoke" ]]; then SMOKE=1; shift; fi
if [[ "$#" -gt 1 ]]; then
    echo "Usage: $0 [--smoke] [output-directory]" >&2
    exit 2
fi
OUT="${1:-$REPO/data/m3-rgba-lut-xps/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
for cmd in git tar dub ldc2 sha256sum awk; do
    command -v "$cmd" >/dev/null || { echo "Missing command $cmd" >&2; exit 1; }
done
COMPILER="$(ldc2 --version | sed -n '1p')"
if [[ "$COMPILER" != "LDC - the LLVM D compiler (1.43.0):" ]]; then
    echo "Expected qualified LDC 1.43.0; got $COMPILER" >&2
    exit 1
fi
for dep in raster-d color-d; do
    git -C "$LIBS/$dep" rev-parse --verify 'v0.2.0^{commit}' >/dev/null
done
SNAP="$OUT/snapshot"
mkdir -p "$SNAP/imagery-d" "$SNAP/raster-d" "$SNAP/color-d"
git -C "$REPO" archive --format=tar HEAD | tar -xf - -C "$SNAP/imagery-d"
for dep in raster-d color-d; do
    git -C "$LIBS/$dep" archive --format=tar v0.2.0 | tar -xf - -C "$SNAP/$dep"
done
{
    echo "utc=$(date -u --iso-8601=seconds)"
    echo "hostname=$(hostname)"
    echo "source_mode=pinned-v0.2.0"
    echo "compiler=$COMPILER"
    echo "compiler_path=$(command -v ldc2)"
    echo "dub=$(dub --version)"
    echo "uname=$(uname -a)"
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
    echo "smoke=$SMOKE"
    echo "cpu_begin"
    lscpu
    echo "cpu_end"
    echo "governors_begin"
    for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [[ ! -f "$f" ]] || echo "$f=$(<"$f")"
    done
    echo "governors_end"
    echo "memory_begin"
    grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo
    echo "memory_end"
} > "$OUT/environment.txt"

ROOT=experiments/m3_rgba_layer_compositing/decode_lut
(
    cd "$SNAP/imagery-d"
    dub build --root="$ROOT" --compiler=ldc2 --build=release --force
) > "$OUT/build.log" 2>&1
BIN="$SNAP/imagery-d/$ROOT/m3-rgba-exact-decode-lut"
test -x "$BIN"

if [[ "$SMOKE" -eq 1 ]]; then
    specs=(48:36:2:1)
else
    specs=(512:512:5:2 2048:2048:4:2)
fi
count=0
for spec in "${specs[@]}"; do
    IFS=: read -r width height rounds iterations <<< "$spec"
    if [[ "$SMOKE" -eq 1 ]]; then
        patterns=(mixed)
        opacities=(0.37)
    elif [[ "$width" -eq 512 ]]; then
        patterns=(mixed opaque transparent top-transparent bottom-transparent)
        opacities=(0 0.37 1)
    else
        patterns=(mixed)
        opacities=(0.37)
    fi
    for pattern in "${patterns[@]}"; do
        for opacity in "${opacities[@]}"; do
            for layout in interleaved planar; do
                for area in whole partial; do
                    caseName="${width}x${height}-${pattern}-opacity${opacity}-${layout}-${area}"
                    args=(--width="$width" --height="$height"
                        --rounds="$rounds" --iterations="$iterations"
                        --pattern="$pattern" --layout="$layout"
                        --opacity="$opacity")
                    if [[ "$area" == partial ]]; then args+=(--partial); fi
                    echo "Running $caseName" >&2
                    /usr/bin/time -v -o "$OUT/$caseName-resource.txt" \
                        "$BIN" "${args[@]}" > "$OUT/$caseName.csv" \
                        2> "$OUT/$caseName-stderr.log"
                    awk -F, -v n="$rounds" '
                        NR == 1 { if (NF != 17 || $1 != "pattern") exit 10; next }
                        /^EXACT-DECODE-LUT PASS:/ { pass++; next }
                        {
                            if (NF != 17 || $14 != 0 || $17 != 0) exit 11;
                            rows++;
                        }
                        END { if (pass != 1 || rows != n) exit 12 }
                    ' "$OUT/$caseName.csv"
                    count=$((count + 1))
                done
            done
        done
    done
done
(
    cd "$OUT"
    sha256sum ./*.csv > CHECKSUMS.sha256
    sha256sum -c CHECKSUMS.sha256
)
echo "M3 EXACT LUT XPS PASS: $count checksummed cases at $OUT"
echo "Package with: tar --exclude='./snapshot' -czf ~/Downloads/m3-rgba-lut-xps.tar.gz -C '$OUT' ."
