#!/usr/bin/env bash
# M3.2.8 actual mapped-image ROI benchmark, without modifying other repos.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
IMAGERY="$(cd "$ROOT/../.." && pwd)"
RASTER="$(cd "$IMAGERY/../raster-d" && pwd)"
COMPILER="${COMPILER:-ldc2}"
REPEATS="${REPEATS:-5}"
ITERATIONS="${ITERATIONS:-12}"
ROUNDS="${ROUNDS:-9}"
WARMUPS="${WARMUPS:-2}"
CPU="${CPU:-}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="${OUTPUT:-$ROOT/evidence/local/consumer-$STAMP}"
BINARY="$ROOT/m3-2-validated-immutable-roi"

for val in "$REPEATS" "$ITERATIONS" "$ROUNDS"; do
    [[ "$val" =~ ^[1-9][0-9]*$ ]] || {
        echo "ERROR: repeats/iterations/rounds must be positive integers" >&2
        exit 2
    }
done
[[ "$WARMUPS" =~ ^[0-9]+$ ]] || {
    echo "ERROR: warmups must be nonnegative" >&2
    exit 2
}

command -v dub >/dev/null
command -v "$COMPILER" >/dev/null
command -v python3 >/dev/null

mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
{
    echo "schema=imagery-d-m3.2.8-consumer-v1"
    echo "timestamp_utc=$STAMP"
    echo "imagery_commit=$(git -C "$IMAGERY" rev-parse HEAD)"
    echo "imagery_branch=$(git -C "$IMAGERY" branch --show-current)"
    echo "imagery_status:"
    git -C "$IMAGERY" status --short
    echo "raster_commit=$(git -C "$RASTER" rev-parse HEAD)"
    echo "raster_release_commit=$(git -C "$RASTER" rev-parse 'v0.2.0^{}' 2>/dev/null || echo missing)"
    echo "raster_status:"
    git -C "$RASTER" status --short
    echo "compiler=$COMPILER"
    "$COMPILER" --version
    dub --version
    echo "iterations=$ITERATIONS rounds=$ROUNDS warmups=$WARMUPS repeats=$REPEATS"
    echo "cpu_affinity=${CPU:-OS_default}"
    echo "governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unavailable)"
    echo "hostname=$(hostname)"
    echo "kernel=$(uname -r)"
    command -v lscpu >/dev/null && lscpu || :
    command -v free >/dev/null && free -h || :
} >"$OUTPUT/environment.txt" 2>&1

if [[ "$(git -C "$RASTER" rev-parse HEAD)" != \
      "$(git -C "$RASTER" rev-parse 'v0.2.0^{}' 2>/dev/null || echo missing)" ]]
then
    echo "WARNING: raster-d != v0.2.0, results are local-state research evidence." >&2
fi

# Separate correctness from measurement, then build a single timed binary.
COMPILERS="$COMPILER" bash "$HERE/run.sh" \
    >"$OUTPUT/correctness.log" 2>&1 || {
        tail -n 50 "$OUTPUT/correctness.log" >&2
        exit 1
    }

(
    cd "$ROOT"
    dub build --compiler="$COMPILER" --config=default --build=release --force
) >"$OUTPUT/build.log" 2>&1 || {
    tail -n 60 "$OUTPUT/build.log" >&2
    exit 1
}
test -x "$BINARY" || {
    echo "ERROR: benchmark binary missing $BINARY" >&2
    exit 1
}
sha256sum "$BINARY" >"$OUTPUT/timed-binary.sha256"

RUNNER=()
if [[ -n "$CPU" ]]; then
    command -v taskset >/dev/null || {
        echo "ERROR: taskset missing" >&2
        exit 1
    }
    RUNNER=(taskset -c "$CPU")
fi

for ((run=0; run<REPEATS; ++run)); do
    "${RUNNER[@]}" "$BINARY" --consumer-benchmark \
        "$ITERATIONS" "$ROUNDS" "$WARMUPS" \
        >"$OUTPUT/run-$run.log" 2>&1 || {
            tail -n 60 "$OUTPUT/run-$run.log" >&2
            exit 1
        }
    echo "completed consumer process $((run+1))/$REPEATS"
done

python3 "$HERE/analyze_consumer_xps.py" "$OUTPUT" --output "$OUTPUT" \
    >"$OUTPUT/analysis.log" 2>&1 || {
        cat "$OUTPUT/analysis.log" >&2
        exit 1
    }

if command -v nm >/dev/null; then
    nm -anC "$BINARY" >"$OUTPUT/symbols.txt" 2>&1 || :
fi
if command -v objdump >/dev/null; then
    objdump -d -C "$BINARY" 2>"$OUTPUT/objdump-errors.log" \
        | gzip -9 >"$OUTPUT/disassembly.txt.gz" || :
fi
echo
cat "$OUTPUT/analysis.log"
echo "Evidence: $OUTPUT"
echo "Codegen and metadata break-even require review; no production claim."
