#!/usr/bin/env bash
# Local Dell-XPS diagnostic performance evidence, NOT a release qualification.
# Only writes under imagery-d/data/ (ignored) and reads sibling repositories.
# Usage: bash tools/research/run_m3_rgba_composite_xps.sh [--pinned] [--smoke] [output-directory]
set -euo pipefail

HOST_REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST_LIBS="$(dirname "$HOST_REPO")"
REPO="$HOST_REPO"
WORKSPACE_LIBS="$HOST_LIBS"
BENCH="experiments/m3_rgba_layer_compositing/bench"
PACKED="experiments/m3_rgba_layer_compositing/packed_probe"
PINNED=0
SMOKE=0
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --pinned) PINNED=1 ;;
        --smoke) SMOKE=1 ;;
        *) echo "ERROR: unknown runner option $1" >&2; exit 2 ;;
    esac
    shift
done
if [[ "$#" -gt 1 ]]; then
    echo "Usage: $0 [--pinned] [--smoke] [output-directory]" >&2
    exit 2
fi
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${1:-$HOST_REPO/data/m3-rgba-composite-xps/$STAMP}"
mkdir -p "$OUT"

# The optional pinned snapshot uses only `git archive` (read-only) against
# active repositories. All extracted files, builds and generated binaries stay
# beneath ignored imagery-d/data/; live sibling HEADs are never switched.
if [[ "$PINNED" -eq 1 ]]; then
    SNAPSHOT="$OUT/snapshot"
    mkdir -p "$SNAPSHOT/imagery-d" "$SNAPSHOT/raster-d" "$SNAPSHOT/color-d"
    git -C "$HOST_REPO" archive --format=tar HEAD \
        | tar -xf - -C "$SNAPSHOT/imagery-d"
    for dep in raster-d color-d; do
        git -C "$HOST_LIBS/$dep" archive --format=tar v0.2.0 \
            | tar -xf - -C "$SNAPSHOT/$dep"
    done
    REPO="$SNAPSHOT/imagery-d"
    WORKSPACE_LIBS="$SNAPSHOT"
fi

if ! command -v ldc2 >/dev/null 2>&1; then
    echo "ERROR: ldc2 missing" >&2
    exit 1
fi
if ! command -v dub >/dev/null 2>&1; then
    echo "ERROR: dub missing" >&2
    exit 1
fi

{
    echo "utc=$(date -u --iso-8601=seconds)"
    echo "runner=$(hostname)"
    echo "os=$(uname -a)"
    echo "imagery_head=$(git -C "$HOST_REPO" rev-parse HEAD)"
    echo "imagery_branch=$(git -C "$HOST_REPO" branch --show-current)"
    echo "source_mode=$([[ "$PINNED" -eq 1 ]] && echo pinned-v0.2.0 || echo local-head)"
    echo "runner_smoke=$SMOKE"
    echo "imagery_status_start"
    git -C "$HOST_REPO" status --short
    echo "imagery_status_end"
    for dep in raster-d color-d; do
        path="$HOST_LIBS/$dep"
        echo "$dep.local_head=$(git -C "$path" rev-parse HEAD)"
        echo "$dep.v0_2_0_commit=$(git -C "$path" rev-parse 'v0.2.0^{commit}')"
        if [[ "$PINNED" -eq 1 ]]; then
            echo "$dep.measured_commit=$(git -C "$path" rev-parse 'v0.2.0^{commit}')"
        else
            echo "$dep.measured_commit=$(git -C "$path" rev-parse HEAD)"
        fi
        echo "$dep.status_start"
        git -C "$path" status --short
        echo "$dep.status_end"
    done
    echo "compiler=$(ldc2 --version | head -n 2 | tr '\n' ' ')"
    echo "dub=$(dub --version)"
    echo "cpu_start"
    lscpu || true
    echo "cpu_end"
    echo "governors_start"
    for path in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [[ -f "$path" ]] && printf '%s=%s\n' "$path" "$(< "$path")"
    done
    echo "governors_end"
    echo "meminfo_start"
    grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo || true
    echo "meminfo_end"
} > "$OUT/environment.txt"

# color-d v0.2.0's published support is LDC 1.42.0 / 1.43.0.
# Older/newer compilers may be useful diagnostics, not release qualification.
LDC_VERSION="$(ldc2 --version | head -n 1)"
if [[ ! "$LDC_VERSION" =~ 1\.(42|43)\.[0-9]+ ]]; then
    echo "NOTICE: LDC version is outside the qualified color-d v0.2.0 matrix; results are diagnostic." | tee -a "$OUT/qualification-warning.txt"
fi

for dep in raster-d color-d; do
    local_head="$(git -C "$HOST_LIBS/$dep" rev-parse HEAD)"
    release_head="$(git -C "$HOST_LIBS/$dep" rev-parse 'v0.2.0^{commit}')"
    if [[ "$PINNED" -eq 0 && "$local_head" != "$release_head" ]]; then
        echo "NOTICE: $dep local HEAD is NOT peeled v0.2.0; results will be LOCAL-HEAD diagnostics, not a tagged-release comparison." | tee -a "$OUT/qualification-warning.txt"
    fi
done
if [[ "$(git -C "$HOST_REPO" rev-parse --abbrev-ref HEAD)" != "research/m3-rgba-layer-compositing" ]]; then
    echo "NOTICE: imagery-d branch differs from the benchmark research branch." | tee -a "$OUT/qualification-warning.txt"
fi

# Build exactly once, then time the directly executed binaries.
# The earlier XPS 2026-10-13 run used /usr/bin/time around `dub run`;
# that wrapper could rebuild and contaminate external RSS/elapsed metrics.
# Stopwatch timings inside the app had always excluded build and startup.
SPECS=(512:512:7:4 2048:2048:5:2)
if [[ "$SMOKE" -eq 1 ]]; then SPECS=(32:32:2:1); fi
(
    cd "$REPO"
    dub build --root="$BENCH" --compiler=ldc2 --build=release --force
    dub build --root="$PACKED" --compiler=ldc2 --build=release --force
) > "$OUT/build.log" 2>&1
test -x "$REPO/$BENCH/m3-rgba-layer-compositing-bench"
test -x "$REPO/$PACKED/m3-rgba-packed-probe"

for spec in "${SPECS[@]}"; do
    IFS=: read -r width height rounds iterations <<< "$spec"
    for mode in encoded linear-pm; do
        for layout in interleaved planar; do
            key="${width}x${height}-${mode}-${layout}"
            echo "Running $key" >&2
            (
                cd "$REPO"
                /usr/bin/time -v -o "$OUT/$key-resource.txt" \
                    "$REPO/$BENCH/m3-rgba-layer-compositing-bench" \
                    --width="$width" --height="$height" \
                    --rounds="$rounds" --iterations="$iterations" \
                    --mode="$mode" --layout="$layout"
            ) > "$OUT/$key.csv" 2> "$OUT/$key-stderr.log"
        done
    done
done

# Same-color-math, same-pixel *restricted* packed-POD versus canonical test.
# Packed zip uses a compile-time opacity (0.37), packed interleaved bytes only,
# and deliberately lacks general production error propagation.
for spec in "${SPECS[@]}"; do
    IFS=: read -r width height rounds iterations <<< "$spec"
    key="${width}x${height}-packed-vs-four-plane"
    echo "Running $key" >&2
    (
        cd "$REPO"
        /usr/bin/time -v -o "$OUT/$key-resource.txt" \
            "$REPO/$PACKED/m3-rgba-packed-probe" \
            --width="$width" --height="$height" \
            --rounds="$rounds" --iterations="$iterations"
    ) > "$OUT/$key.csv" 2> "$OUT/$key-stderr.log"
done

(
    cd "$OUT"
    sha256sum ./*.csv > CHECKSUMS.sha256
)
echo "Benchmark archived in: $OUT"
echo "Absolute values require a stable XPS reference configuration;"
echo "compare paired relay/composite directions and source/output correctness first."
