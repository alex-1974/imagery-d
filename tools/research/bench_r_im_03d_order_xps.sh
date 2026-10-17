#!/usr/bin/env bash
# R-IM-03d opt-in XPS case-order experiment, RESEARCH ONLY.
# No CPU control, modification to sibling repositories, or production claim.
set -euo pipefail

REPO="${1:-$(git rev-parse --show-toplevel)}"
SIDE="${2:-1024}"
ROUNDS="${3:-7}"
PATTERN="${4:-1}"
DC="${5:-ldc2}"
OUTDIR="${6:-$(mktemp -d "$HOME/imagery-rim03d-results-XXXXXX")}"
PINNED_RASTER="2f2415851e45001df92ce56dad409f680684ba8d"
SOURCE_SHA="8042a319a88473e97ddf5c7a439b96e5b7ddbf04"
# The exact SHA above is the first R-IM-03d code commit for cross-reference;
# later documentation/CI commits may move branch HEAD without changing code.

cd "$REPO"
test -f experiments/r_im_03a_levels/bench_03c/dub.sdl
test -d ../raster-d || { echo "ERROR: adjacent raster-d missing" >&2; exit 2; }
R_SHA="$(git -C ../raster-d rev-parse HEAD)"
if [[ "$R_SHA" != "$PINNED_RASTER" ]]; then
    echo "ERROR: raster-d $R_SHA, required $PINNED_RASTER" >&2
    echo "Use a separate pinned checkout. The script will not mutate siblings." >&2
    exit 3
fi
if [[ ! "$SIDE" =~ ^[0-9]+$ || ! "$ROUNDS" =~ ^[0-9]+$ || ! "$PATTERN" =~ ^[012]$ ]]; then
    echo "ERROR: SIDE ROUNDS numeric, PATTERN 0/1/2" >&2
    exit 4
fi
if (( SIDE<16 || SIDE>4096 || ROUNDS<1 || ROUNDS>100 )); then
    echo "ERROR: SIDE 16..4096, ROUNDS 1..100" >&2
    exit 4
fi
mkdir -p "$OUTDIR"
OUTDIR="$(realpath "$OUTDIR")"
echo "RIM03D_RESULTS_DIR=$OUTDIR"
printf 'RIM03D_SOURCE_PROBE_COMMIT=%s\n' "$SOURCE_SHA"
printf 'RIM03D_IMAGERY_HEAD=%s\n' "$(git rev-parse HEAD)"
printf 'RIM03D_RASTER_HEAD=%s\n' "$R_SHA"
printf 'RIM03D_GIT_STATUS=%s\n' "$(git status --porcelain | tr '\n' ';')"
printf 'RIM03D_OS=%s\n' "$(uname -srvmo)"
printf 'RIM03D_HOST=%s\n' "$(hostname)"
printf 'RIM03D_CPU=%s\n' "$(grep -m1 'model name' /proc/cpuinfo || true)"
printf 'RIM03D_GOVERNORS=%s\n' "$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u | tr '\n' ',' || true)"
"$DC" --version
dub --version
echo "RIM03D_MEASUREMENT_SCOPE=single-thread raster-d ROI math 4 methods; no Clang C++ comparator"
echo "RIM03D_NOTE=process order is a probe; no randomisation/temperature causality guaranteed"
echo "RIM03D_BUILD=one Release compile; execute separate processes without intermediate recompiles"

dub build --root=experiments/r_im_03a_levels/bench_03c \
    --compiler="$DC" --build=release --force
BINARY="$REPO/experiments/r_im_03a_levels/bench_03c/r-im-03c-levels-math-benchmark"
test -x "$BINARY" || { echo "ERROR: benchmark executable missing" >&2; exit 5; }

snapshot() {
    local tag="$1"
    printf 'RIM03D_ENV_TIME_%s=%s\n' "$tag" "$(date -u +%FT%TZ)"
    # Observational only. Sampling instantaneous cpufreq is NOT the frequency
    # during the actual timed operation, and sensor coverage varies by host.
    printf 'RIM03D_ENV_CPU0_FREQ_KHZ_%s=%s\n' "$tag" \
        "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo unavailable)"
    printf 'RIM03D_ENV_PROC_CPU_MHZ_%s=%s\n' "$tag" \
        "$(grep -m1 'cpu MHz' /proc/cpuinfo || echo unavailable)"
    if command -v sensors >/dev/null 2>&1; then
        echo "RIM03D_ENV_SENSORS_BEGIN_$tag"
        sensors || true
        echo "RIM03D_ENV_SENSORS_END_$tag"
    fi
}

# Order intentionally repeats the suspect case as both isolated and first,
# and places it last in the original forward traversal. Reverse order
# explicitly makes it first; no direct equality of elapsed wall times should
# be inferred from a single process because process order is still fixed.
modes=(
    target-only
    forward
    reverse
    control-only
    target-first
    reverse
    forward
    target-only
)

for k in "${!modes[@]}"; do
    mode="${modes[$k]}"
    receipt="$OUTDIR/order-$(printf '%02d' "$k")-$mode.log"
    {
        printf 'RIM03D_RUN_INDEX=%s\n' "$k"
        printf 'RIM03D_MODE=%s\n' "$mode"
        printf 'RIM03D_PATTERN=%s SIDE=%s ROUNDS=%s\n' "$PATTERN" "$SIDE" "$ROUNDS"
        snapshot BEFORE
        "$BINARY" "$SIDE" "$ROUNDS" "$PATTERN" "$mode"
        snapshot AFTER
    } 2>&1 | tee "$receipt"
done

echo "RIM03D_COMPLETE=$OUTDIR"
echo "RIM03D_LOGS=8"
echo "Keep all eight complete logs for analysis; hosted CI timings cannot substitute."
