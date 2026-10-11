#!/usr/bin/env bash
# M3.2.7 evidence-only XPS ROI benchmark; NEVER edits sibling repositories.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENT="$(cd "$HERE/.." && pwd)"
IMAGERY="$(cd "$EXPERIMENT/../.." && pwd)"
RASTER="$(cd "$IMAGERY/../raster-d" && pwd)"
COMPILER="${COMPILER:-ldc2}"
ITERATIONS="${ITERATIONS:-50000}"
ROUNDS="${ROUNDS:-15}"
WARMUPS="${WARMUPS:-3}"
REPEATS="${REPEATS:-5}"
CPU="${CPU:-}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="${OUTPUT:-$EXPERIMENT/evidence/local/xps-$STAMP}"
BINARY="$EXPERIMENT/m3-2-validated-immutable-roi"

for value in "$ITERATIONS" "$ROUNDS" "$REPEATS"; do
    if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: ITERATIONS/ROUNDS/REPEATS must be positive integers" >&2
        exit 2
    fi
done
if ! [[ "$WARMUPS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: WARMUPS must be a nonnegative integer" >&2
    exit 2
fi

command -v "$COMPILER" >/dev/null
command -v dub >/dev/null
command -v python3 >/dev/null
test -d "$RASTER/.git" || git -C "$RASTER" rev-parse --is-inside-work-tree >/dev/null

mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
META="$OUTPUT/environment.txt"
RAW="$OUTPUT/roi-raw.csv"

{
    echo "schema=imagery-d-m3.2.7-xps-v1"
    echo "timestamp_utc=$STAMP"
    echo "imagery_dir=$IMAGERY"
    echo "imagery_commit=$(git -C "$IMAGERY" rev-parse HEAD)"
    echo "imagery_branch=$(git -C "$IMAGERY" branch --show-current)"
    echo "imagery_dirty=$(git -C "$IMAGERY" status --porcelain | wc -l)"
    echo "raster_commit=$(git -C "$RASTER" rev-parse HEAD)"
    echo "raster_tag_v0.2.0=$(git -C "$RASTER" rev-parse 'v0.2.0^{}' 2>/dev/null || echo missing)"
    echo "raster_dirty=$(git -C "$RASTER" status --porcelain | wc -l)"
    echo "compiler=$COMPILER"
    "$COMPILER" --version
    dub --version
    echo "build=dub --build=release --compiler=$COMPILER --config=default --force"
    echo "iterations=$ITERATIONS rounds=$ROUNDS warmups=$WARMUPS repeats=$REPEATS"
    echo "affinity_cpu=${CPU:-OS_default}"
    echo "hostname=$(hostname)"
    echo "kernel=$(uname -a)"
    echo "cpu_governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unavailable)"
    echo "cpu_driver=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo unavailable)"
    echo "--- lscpu ---"
    command -v lscpu >/dev/null && lscpu || :
    echo "--- free -h ---"
    command -v free >/dev/null && free -h || :
    echo "--- git status ---"
    git -C "$IMAGERY" status --short
} >"$META" 2>&1

RASTER_SHA="$(git -C "$RASTER" rev-parse HEAD)"
TAG_SHA="$(git -C "$RASTER" rev-parse 'v0.2.0^{}' 2>/dev/null || true)"
if [[ -z "$TAG_SHA" || "$RASTER_SHA" != "$TAG_SHA" ]]; then
    echo "WARNING: local raster-d is not the v0.2.0 tag: exploratory evidence only." >&2
    echo "raster_dependency_not_pinned=true" >> "$META"
else
    echo "raster_dependency_not_pinned=false" >> "$META"
fi

# Compile exactly once; the binary is reused for every timed process.
# This DUB recipe is in imagery-d and reads sibling raster-d, without edits.
(
    cd "$EXPERIMENT"
    dub build --compiler="$COMPILER" --config=default --build=release --force
) >"$OUTPUT/build.log" 2>&1 || {
    tail -n 80 "$OUTPUT/build.log" >&2
    exit 1
}
test -x "$BINARY" || {
    echo "ERROR: executable not found at $BINARY" >&2
    find "$EXPERIMENT" -maxdepth 2 -type f -executable -printf '%p\n' >&2
    exit 1
}
sha256sum "$BINARY" >"$OUTPUT/binary.sha256"

# The full correctness/compile-negative suite is separate from timing;
# run once against the same compiler and dependency. It rebuilds, so hash
# the executable again before timing if the built artifact changed.
COMPILERS="$COMPILER" bash "$HERE/run.sh" \
    >"$OUTPUT/correctness.log" 2>&1 || {
        tail -n 100 "$OUTPUT/correctness.log" >&2
        exit 1
    }
sha256sum "$BINARY" >"$OUTPUT/timed-binary.sha256"

RUNNER=()
if [[ -n "$CPU" ]]; then
    command -v taskset >/dev/null || {
        echo "ERROR: CPU requested but taskset not found" >&2
        exit 1
    }
    RUNNER=(taskset -c "$CPU")
fi

printf 'tag,run,channels,round,slot,mode,iterations,elapsed_ns,checksum\n' > "$RAW"
for ((run=0; run<REPEATS; ++run)); do
    LOG="$OUTPUT/run-$run.log"
    "${RUNNER[@]}" "$BINARY" --benchmark-xps \
        "$ITERATIONS" "$ROUNDS" "$WARMUPS" >"$LOG" 2>&1 || {
            tail -n 90 "$LOG" >&2
            exit 1
        }
    awk -F, -v run="$run" 'BEGIN {OFS=","} /^roi_xps,/ {
        if (NF != 8) exit 5;
        print "roi_xps",run,$2,$3,$4,$5,$6,$7,$8
    }' "$LOG" >> "$RAW"
    echo "completed paired process $((run+1))/$REPEATS"
done

python3 "$HERE/analyze_xps_roi.py" \
    --raw "$RAW" \
    --summary "$OUTPUT/roi-summary.csv" \
    --json "$OUTPUT/roi-summary.json" \
    >"$OUTPUT/analyze.log" 2>&1 || {
        cat "$OUTPUT/analyze.log" >&2
        exit 1
    }

if command -v nm >/dev/null; then
    nm -anC "$BINARY" >"$OUTPUT/symbols.txt" 2>&1 || :
    grep -iE 'roi_xps|rasterControl|conservativeControl|validatedControl|runBatch' \
        "$OUTPUT/symbols.txt" >"$OUTPUT/relevant-symbols.txt" || :
fi
if command -v objdump >/dev/null; then
    # Review whether the three noinline call boundaries survive LDC
    # and inspect the ROI loops before making performance claims.
    objdump -d -C "$BINARY" 2>"$OUTPUT/objdump-errors.log" \
        | gzip -9 >"$OUTPUT/disassembly.txt.gz" || :
fi

echo
cat "$OUTPUT/analyze.log"
echo "Evidence directory: $OUTPUT"
echo "Review relevant-symbols.txt and disassembly.txt.gz before promotion."
echo "No performance acceptance decision is made by this script."
