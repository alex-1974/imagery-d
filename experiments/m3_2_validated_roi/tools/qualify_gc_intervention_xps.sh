#!/usr/bin/env bash
# M3.2.16 isolated GC intervention for identical mutable-snapshot ROI work; writes imagery-d evidence only.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENT="$(cd "$HERE/.." && pwd)"
IMAGERY="$(cd "$EXPERIMENT/../.." && pwd)"
RASTER="$(cd "$IMAGERY/../raster-d" && pwd)"
COMPILER="${COMPILER:-ldc2}"
REPEATS="${REPEATS:-5}"
ROUNDS="${ROUNDS:-1024}"
WARMUPS="${WARMUPS:-16}"
SIDE="${SIDE:-32}"
REUSE="${REUSE:-1}"
SMOKE="${SMOKE:-0}"
CPU="${CPU:-}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="${OUTPUT:-$EXPERIMENT/evidence/local/gc-intervention-$STAMP}"
BINARY="$EXPERIMENT/m3-2-validated-immutable-roi"

for value in "$REPEATS" "$ROUNDS" "$SIDE" "$REUSE"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
        echo "ERROR: REPEATS/ROUNDS must be positive integers" >&2
        exit 2
    }
done
if (( REPEATS < 2 )); then
    echo "ERROR: REPEATS must be >=2 for independent process-level evidence" >&2
    exit 2
fi
[[ "$WARMUPS" =~ ^[0-9]+$ ]] || exit 2
[[ "$SMOKE" == "0" || "$SMOKE" == "1" ]] || exit 2
(( WARMUPS <= ROUNDS )) || {
    echo "ERROR: WARMUPS must not exceed ROUNDS" >&2
    exit 2
}
(( SIDE == 8 || SIDE == 32 )) || {
    echo "ERROR: SIDE must be 8 or 32" >&2
    exit 2
}
(( REUSE == 1 || REUSE == 4 || REUSE == 16 )) || {
    echo "ERROR: REUSE must be 1, 4 or 16" >&2
    exit 2
}
command -v dub >/dev/null
command -v "$COMPILER" >/dev/null
command -v python3 >/dev/null
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"

{
    echo "schema=imagery-d-m3.2.16-gc-intervention-v1"
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
    echo "repeats=$REPEATS rounds=$ROUNDS warmups=$WARMUPS smoke=$SMOKE side=$SIDE reuse=$REUSE"
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

# This retains all existing source/lifetime gates in the measured configuration.
COMPILERS="$COMPILER" bash "$HERE/run.sh" >"$OUTPUT/m326-gates.log" 2>&1
COMPILERS="$COMPILER" bash "$HERE/run_prepared.sh" >"$OUTPUT/m329-gates.log" 2>&1
COMPILERS="$COMPILER" bash "$HERE/run_sealed.sh" >"$OUTPUT/m3211-gates.log" 2>&1
COMPILERS="$COMPILER" bash "$HERE/run_unified.sh" >"$OUTPUT/m3212-gates.log" 2>&1
(
    cd "$EXPERIMENT"
    dub build --compiler="$COMPILER" --config=default --build=release --force
) >"$OUTPUT/build.log" 2>&1 || {
    tail -n 100 "$OUTPUT/build.log" >&2
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
MODE="--gc-intervention-benchmark"
[[ "$SMOKE" == "0" ]] || MODE="--gc-intervention-smoke"
POLICIES=(normal precollect deferred)
for ((run=0; run<REPEATS; ++run)); do
    # System observations are outside the measured executable and
    # may themselves perturb page-cache state. They are context only.
    {
        date -u
        free -h || :
        grep -E '^(MemAvailable|SwapFree|SwapTotal|Committed_AS):' /proc/meminfo || :
        grep -E '^(pgfault|pgmajfault|pswpin|pswpout|allocstall)' /proc/vmstat || :
        for freq in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
            [[ ! -f "$freq" ]] || printf '%s=%s\n' "$freq" "$(cat "$freq")"
        done
    } >"$OUTPUT/run-$run-system-before.txt" 2>&1
    # Three separate processes per repetition, with rotated *launch*
    # order. No policy ever inherits another policy's disabled GC state.
    for ((slot=0; slot<3; ++slot)); do
        policy="${POLICIES[$(((run + slot) % 3))]}"
        logfile="$OUTPUT/run-$run-$policy.log"
        "${LAUNCH[@]}" "$BINARY" "$MODE" "$policy" \
            "$ROUNDS" "$WARMUPS" "$SIDE" "$REUSE" \
            >"$logfile" 2>&1 || {
            tail -n 100 "$logfile" >&2
            exit 1
        }
    done
    {
        date -u
        free -h || :
        grep -E '^(MemAvailable|SwapFree|SwapTotal|Committed_AS):' /proc/meminfo || :
        grep -E '^(pgfault|pgmajfault|pswpin|pswpout|allocstall)' /proc/vmstat || :
        for freq in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
            [[ ! -f "$freq" ]] || printf '%s=%s\n' "$freq" "$(cat "$freq")"
        done
    } >"$OUTPUT/run-$run-system-after.txt" 2>&1
    echo "completed GC intervention triple $((run+1))/$REPEATS"
done
python3 "$HERE/analyze_gc_intervention.py" "$OUTPUT" \
    >"$OUTPUT/analysis.log" 2>&1 || {
    cat "$OUTPUT/analysis.log" >&2
    exit 1
}
cat "$OUTPUT/analysis.log"
echo "M3.2.16 GC intervention evidence directory: $OUTPUT"
echo "Explicit precollection is OUTSIDE the timed block; compare no single median in isolation."
