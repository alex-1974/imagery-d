#!/usr/bin/env bash
# M3.2.9 reproducible synthetic mapped-image ROI benchmark. Writes imagery only.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENT="$(cd "$HERE/.." && pwd)"
IMAGERY="$(cd "$EXPERIMENT/../.." && pwd)"
RASTER="$(cd "$IMAGERY/../raster-d" && pwd)"
COMPILER="${COMPILER:-ldc2}"
REPEATS="${REPEATS:-5}"
ROUNDS="${ROUNDS:-12}"
ITERATIONS="${ITERATIONS:-24}"
WARMUPS="${WARMUPS:-2}"
CPU="${CPU:-}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="${OUTPUT:-$EXPERIMENT/evidence/local/prepared-$STAMP}"
BINARY="$EXPERIMENT/m3-2-validated-immutable-roi"

for val in "$REPEATS" "$ROUNDS" "$ITERATIONS"; do
    [[ "$val" =~ ^[1-9][0-9]*$ ]] || {
        echo "ERROR: positive REPEATS/ROUNDS/ITERATIONS required" >&2
        exit 2
    }
done
[[ "$WARMUPS" =~ ^[0-9]+$ ]] || {
    echo "ERROR: WARMUPS must be nonnegative" >&2
    exit 2
}
command -v dub >/dev/null
command -v "$COMPILER" >/dev/null
command -v python3 >/dev/null
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"

{
    echo "schema=imagery-d-m3.2.9-prepared-consumer-v1"
    echo "timestamp_utc=$STAMP"
    echo "imagery_commit=$(git -C "$IMAGERY" rev-parse HEAD)"
    echo "imagery_branch=$(git -C "$IMAGERY" branch --show-current)"
    echo "--- imagery git status ---"
    git -C "$IMAGERY" status --short
    echo "raster_commit=$(git -C "$RASTER" rev-parse HEAD)"
    echo "raster_v0_2_0=$(git -C "$RASTER" rev-parse 'v0.2.0^{}' 2>/dev/null || echo missing)"
    echo "--- raster git status ---"
    git -C "$RASTER" status --short
    echo "compiler=$COMPILER"
    "$COMPILER" --version
    dub --version
    echo "repeats=$REPEATS rounds=$ROUNDS iterations=$ITERATIONS warmups=$WARMUPS"
    echo "cpu_affinity=${CPU:-OS_default}"
    echo "kernel=$(uname -a)"
    echo "governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unavailable)"
    command -v lscpu >/dev/null && lscpu || :
    command -v free >/dev/null && free -h || :
} >"$OUTPUT/environment.txt" 2>&1

if [[ "$(git -C "$RASTER" rev-parse HEAD)" != \
      "$(git -C "$RASTER" rev-parse 'v0.2.0^{}' 2>/dev/null || echo missing)" ]]
then
    echo "WARNING: dependency not exact raster-d v0.2.0 tag; exploratory local state." >&2
fi

COMPILERS="$COMPILER" bash "$HERE/run.sh" >"$OUTPUT/m326-positives-negatives.log" 2>&1
COMPILERS="$COMPILER" bash "$HERE/run_prepared.sh" >"$OUTPUT/m329-positives-negatives.log" 2>&1
COMPILERS="$COMPILER" bash "$HERE/run_sealed.sh" >"$OUTPUT/m3211-visibility-negatives.log" 2>&1
COMPILERS="$COMPILER" bash "$HERE/run_unified.sh" >"$OUTPUT/m3212-unified-negatives.log" 2>&1
(
    cd "$EXPERIMENT"
    dub build --compiler="$COMPILER" --config=default --build=release --force
) >"$OUTPUT/build.log" 2>&1 || {
    tail -n 80 "$OUTPUT/build.log" >&2
    exit 1
}
test -x "$BINARY"
sha256sum "$BINARY" >"$OUTPUT/timed-binary.sha256"

LAUNCH=()
if [[ -n "$CPU" ]]; then
    command -v taskset >/dev/null
    LAUNCH=(taskset -c "$CPU")
fi
for ((run=0; run<REPEATS; run++)); do
    "${LAUNCH[@]}" "$BINARY" --prepared-consumer-benchmark \
        "$ITERATIONS" "$ROUNDS" "$WARMUPS" \
        >"$OUTPUT/run-$run.log" 2>&1 || {
        tail -n 80 "$OUTPUT/run-$run.log" >&2
        exit 1
    }
    echo "completed process $((run+1))/$REPEATS"
done

python3 "$HERE/analyze_prepared_xps.py" "$OUTPUT" \
    >"$OUTPUT/analysis.log" 2>&1 || {
    cat "$OUTPUT/analysis.log" >&2
    exit 1
}
if command -v nm >/dev/null; then
    nm -anC "$BINARY" >"$OUTPUT/symbols.txt" 2>&1 || :
fi
# M3.2.10 specifically measures the two preflight policies sharing a
# single execution kernel; codegen attestation is a required test gate.
command -v objdump >/dev/null || {
    echo "ERROR: objdump is required for M3.2.10 kernel attribution" >&2
    exit 1
}
objdump -d -C "$BINARY" 2>"$OUTPUT/objdump-errors.log" \
    | gzip -9 >"$OUTPUT/disassembly.txt.gz"
python3 "$HERE/audit_common_kernel.py" \
    "$OUTPUT/disassembly.txt.gz" >"$OUTPUT/common-kernel-audit.log" 2>&1 || {
    cat "$OUTPUT/common-kernel-audit.log" >&2
    exit 1
}
cat "$OUTPUT/common-kernel-audit.log"
cat "$OUTPUT/analysis.log"
echo "XPS evidence: $OUTPUT"
echo "No performance/API admission follows automatically."
