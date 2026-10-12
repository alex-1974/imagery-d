#!/usr/bin/env bash
# M3.2.14 full-pixel prepared amortization; writes imagery-d evidence only.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENT="$(cd "$HERE/.." && pwd)"
IMAGERY="$(cd "$EXPERIMENT/../.." && pwd)"
RASTER="$(cd "$IMAGERY/../raster-d" && pwd)"
COMPILER="${COMPILER:-ldc2}"
REPEATS="${REPEATS:-5}"
ROUNDS="${ROUNDS:-8}"
WARMUPS="${WARMUPS:-2}"
SMOKE="${SMOKE:-0}"
CPU="${CPU:-}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="${OUTPUT:-$EXPERIMENT/evidence/local/reuse-amortization-$STAMP}"
BINARY="$EXPERIMENT/m3-2-validated-immutable-roi"

for value in "$REPEATS" "$ROUNDS"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
        echo "ERROR: REPEATS/ROUNDS must be positive integers" >&2
        exit 2
    }
done
[[ "$WARMUPS" =~ ^[0-9]+$ ]] || exit 2
[[ "$SMOKE" == "0" || "$SMOKE" == "1" ]] || exit 2
(( ROUNDS % 2 == 0 )) || {
    echo "ERROR: ROUNDS must be even for balanced paired slots" >&2
    exit 2
}
command -v dub >/dev/null
command -v "$COMPILER" >/dev/null
command -v python3 >/dev/null
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"

{
    echo "schema=imagery-d-m3.2.14-reuse-v1"
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
    echo "repeats=$REPEATS rounds=$ROUNDS warmups=$WARMUPS smoke=$SMOKE"
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
MODE="--reuse-consumer-benchmark"
[[ "$SMOKE" == "0" ]] || MODE="--reuse-consumer-smoke"
for ((run=0; run<REPEATS; ++run)); do
    "${LAUNCH[@]}" "$BINARY" "$MODE" "$ROUNDS" "$WARMUPS" \
        >"$OUTPUT/run-$run.log" 2>&1 || {
        tail -n 100 "$OUTPUT/run-$run.log" >&2
        exit 1
    }
    echo "completed reuse process $((run+1))/$REPEATS"
done
python3 "$HERE/analyze_reuse_amortization.py" "$OUTPUT" \
    >"$OUTPUT/analysis.log" 2>&1 || {
    cat "$OUTPUT/analysis.log" >&2
    exit 1
}
cat "$OUTPUT/analysis.log"
echo "M3.2.14 qualified evidence directory: $OUTPUT"
echo "Timing requires independent host/codegen and statistical interpretation."
