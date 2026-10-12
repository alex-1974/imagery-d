#!/usr/bin/env bash
# M3.2.18 source lifetime and ordered per-ROI transcript. Writes imagery-d only.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENT="$(cd "$HERE/.." && pwd)"
IMAGERY="$(cd "$EXPERIMENT/../.." && pwd)"
RASTER="$(cd "$IMAGERY/../raster-d" && pwd)"
COMPILER="${COMPILER:-ldc2}"
REPEATS="${REPEATS:-5}"
PACKETS="${PACKETS:-32}"
SIDES="${SIDES:-8,32}"
REUSES="${REUSES:-4,16}"
CPU="${CPU:-}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="${OUTPUT:-$EXPERIMENT/evidence/local/metadata-source-$STAMP}"
BINARY="$EXPERIMENT/m3-2-validated-immutable-roi"

for var in "$REPEATS" "$PACKETS"; do
    [[ "$var" =~ ^[1-9][0-9]*$ ]] || {
        echo "ERROR: REPEATS/PACKETS must be positive integers" >&2
        exit 2
    }
done
(( REPEATS >= 2 && PACKETS <= 8192 )) || exit 2
IFS=',' read -r -a SIDE_VALUES <<<"$SIDES"
IFS=',' read -r -a REUSE_VALUES <<<"$REUSES"
(( ${#SIDE_VALUES[@]} > 0 && ${#REUSE_VALUES[@]} > 0 )) || exit 2
for side in "${SIDE_VALUES[@]}"; do
    [[ "$side" == 8 || "$side" == 32 ]] || exit 2
done
for reuse in "${REUSE_VALUES[@]}"; do
    [[ "$reuse" == 4 || "$reuse" == 16 ]] || exit 2
done
[[ "$(printf '%s\n' "${SIDE_VALUES[@]}" | sort -u | wc -l)" -eq "${#SIDE_VALUES[@]}" ]] || exit 2
[[ "$(printf '%s\n' "${REUSE_VALUES[@]}" | sort -u | wc -l)" -eq "${#REUSE_VALUES[@]}" ]] || exit 2
command -v "$COMPILER" >/dev/null
command -v python3 >/dev/null
command -v dub >/dev/null
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"

{
    echo "schema=imagery-d-m3.2.18-metadata-source-ordered-v1"
    echo "timestamp_utc=$STAMP"
    echo "imagery_commit=$(git -C "$IMAGERY" rev-parse HEAD)"
    echo "imagery_branch=$(git -C "$IMAGERY" branch --show-current)"
    echo "--- imagery worktree ---"
    git -C "$IMAGERY" status --short
    echo "raster_commit=$(git -C "$RASTER" rev-parse HEAD)"
    echo "raster_v0_2_0=$(git -C "$RASTER" rev-parse 'v0.2.0^{}' 2>/dev/null || echo missing)"
    echo "--- raster worktree ---"
    git -C "$RASTER" status --short
    echo "compiler=$COMPILER"
    "$COMPILER" --version
    dub --version
    echo "repeats=$REPEATS packets=$PACKETS sides=$SIDES reuses=$REUSES"
    echo "cpu_affinity=${CPU:-OS_default}"
    uname -a
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || :
    command -v lscpu >/dev/null && lscpu || :
    command -v free >/dev/null && free -h || :
} >"$OUTPUT/environment.txt" 2>&1

if [[ "$(git -C "$RASTER" rev-parse HEAD)" != \
      "$(git -C "$RASTER" rev-parse 'v0.2.0^{}' 2>/dev/null || echo missing)" ]]; then
    echo "NOTE: raster dependency is local-state research, not exact v0.2.0." >&2
fi
# All existing compiler privacy/borrow contracts must hold for the binary.
COMPILERS="$COMPILER" bash "$HERE/run.sh" >"$OUTPUT/m326-gates.log" 2>&1
COMPILERS="$COMPILER" bash "$HERE/run_prepared.sh" >"$OUTPUT/m329-gates.log" 2>&1
COMPILERS="$COMPILER" bash "$HERE/run_sealed.sh" >"$OUTPUT/m3211-gates.log" 2>&1
COMPILERS="$COMPILER" bash "$HERE/run_unified.sh" >"$OUTPUT/m3212-gates.log" 2>&1
(
    cd "$EXPERIMENT"
    dub build --compiler="$COMPILER" --config=default --build=release --force
) >"$OUTPUT/build.log" 2>&1 || {
    tail -100 "$OUTPUT/build.log" >&2
    exit 1
}
test -x "$BINARY"
"$BINARY" --setup-observed-smoke >"$OUTPUT/observed-pixel-oracle.log" 2>&1
sha256sum "$BINARY" >"$OUTPUT/timed-binary.sha256"
if command -v nm >/dev/null; then
    nm -anC "$BINARY" >"$OUTPUT/symbols.txt" 2>&1 || :
fi
if command -v objdump >/dev/null; then
    objdump -d -C "$BINARY" 2>"$OUTPUT/objdump-errors.log" \
        | gzip -9 >"$OUTPUT/disassembly.txt.gz" || :
fi

LAUNCH=()
if [[ -n "$CPU" ]]; then
    command -v taskset >/dev/null
    LAUNCH=(taskset -c "$CPU")
fi
POLICIES=(immutable snapshot)
for ((run=0; run<REPEATS; ++run)); do
    {
        date -u
        free -h || :
        grep -E '^(MemAvailable|SwapFree|SwapTotal):' /proc/meminfo || :
        grep -E '^(pgfault|pgmajfault|pswpin|pswpout)' /proc/vmstat || :
    } >"$OUTPUT/run-$run-system-before.txt" 2>&1

    for side in "${SIDE_VALUES[@]}"; do
        for reuse in "${REUSE_VALUES[@]}"; do
            for ((slot=0; slot<2; ++slot)); do
                policy="${POLICIES[$(((run + slot) % 2))]}"
                log="$OUTPUT/run-$run-$policy-$side-$reuse.log"
                "${LAUNCH[@]}" "$BINARY" \
                    --metadata-source-benchmark "$policy" "$PACKETS" "$side" "$reuse" \
                    >"$log" 2>&1 || {
                    tail -100 "$log" >&2
                    exit 1
                }
            done
        done
    done
    {
        date -u
        free -h || :
        grep -E '^(MemAvailable|SwapFree|SwapTotal):' /proc/meminfo || :
        grep -E '^(pgfault|pgmajfault|pswpin|pswpout)' /proc/vmstat || :
    } >"$OUTPUT/run-$run-system-after.txt" 2>&1
    echo "completed metadata source repeat $((run + 1))/$REPEATS"
done

python3 "$HERE/analyze_metadata_source.py" "$OUTPUT" >"$OUTPUT/analysis.log" 2>&1 || {
    cat "$OUTPUT/analysis.log" >&2
    exit 1
}
cat "$OUTPUT/analysis.log"
echo "M3.2.18 source evidence directory: $OUTPUT"
echo "No mutable zero-copy freeze; caller immutable creation outside measured consumer."
