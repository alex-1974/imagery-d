#!/usr/bin/env bash
# Issue #74: native XPS one-vs-four subscriber physical-memory observation.
# Immutable imagery snapshot, pinned read-only raster/color dependencies.
# Adds no public API and makes no allocator-specific budget assertion.
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBS="$(dirname "$REPO")"
MODE=normal
if [[ "${1:-}" == "--smoke" ]]; then MODE=smoke; shift; fi
if [[ "$#" -gt 1 ]]; then
    echo "Usage: $0 [--smoke] [new-empty-evidence-directory]" >&2
    exit 2
fi
OUT="${1:-$REPO/data/m3-generation-subscriber-memory-xps/$(date -u +%Y%m%dT%H%M%SZ)}"
if [[ -e "$OUT" && ( ! -d "$OUT" || -n "$(ls -A "$OUT")" ) ]]; then
    echo "ERROR: output exists and is not empty: $OUT" >&2
    exit 1
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
for command in git tar dub ldc2 python3 sha256sum lscpu; do
    command -v "$command" >/dev/null || {
        echo "ERROR: missing prerequisite $command" >&2
        exit 1
    }
done
compiler="$(ldc2 --version | sed -n '1p')"
[[ "$compiler" == 'LDC - the LLVM D compiler (1.43.0):' ]] || {
    echo "ERROR: exact native LDC 1.43.0 required: $compiler" >&2
    exit 1
}
for dep in raster-d color-d; do
    case "$dep" in
      raster-d) expected=2f2415851e45001df92ce56dad409f680684ba8d ;;
      color-d)  expected=3359f08f4e83941ac1a8451cadefb146b5736019 ;;
    esac
    actual="$(git -C "$LIBS/$dep" rev-parse --verify 'v0.2.0^{commit}')"
    [[ "$actual" == "$expected" ]] || {
        echo "ERROR: $dep pinned tag drift: expected $expected got $actual" >&2
        exit 1
    }
done
SNAP="$OUT/snapshot"
mkdir -p "$SNAP/imagery-d" "$SNAP/raster-d" "$SNAP/color-d"
git -C "$REPO" archive HEAD | tar -xf - -C "$SNAP/imagery-d"
for dep in raster-d color-d; do
    git -C "$LIBS/$dep" archive v0.2.0 | tar -xf - -C "$SNAP/$dep"
done
{
    echo "utc=$(date -u --iso-8601=seconds)"
    echo "mode=$MODE"
    echo "compiler=$compiler"
    echo "compiler_bin=$(command -v ldc2)"
    echo "dub=$(dub --version)"
    echo "host=$(hostname)"
    echo "kernel=$(uname -a)"
    echo "imagery_commit=$(git -C "$REPO" rev-parse HEAD)"
    echo "imagery_branch=$(git -C "$REPO" branch --show-current)"
    echo "source_status_begin"
    git -C "$REPO" status --short
    echo "source_status_end"
    for dep in raster-d color-d; do
        echo "$dep.tag_sha=$(git -C "$LIBS/$dep" rev-parse 'v0.2.0^{commit}')"
    done
    echo "cpu_begin"; lscpu; echo "cpu_end"
    echo "governors_begin"
    for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [[ ! -f "$f" ]] || echo "$f=$(<"$f")"
    done
    echo "governors_end"
} >"$OUT/environment.txt"

ROOT=experiments/m3_rgba_layer_compositing/smoke
(
    cd "$SNAP/imagery-d"
    dub build --root="$ROOT" --compiler=ldc2 --config=default \
        --build=release --force
) >"$OUT/build.log" 2>&1
BIN="$SNAP/imagery-d/$ROOT/m3-rgba-layer-compositing-consumer"
[[ -x "$BIN" ]] || {
    echo "ERROR: missing independent release-mode research consumer" >&2
    exit 1
}
PY="$SNAP/imagery-d/tools/research/summarize_m3_rgba_generation_subscriber_memory_xps.py"
python3 "$PY" --self-test >"$OUT/validator-self-test.txt"
grep -q '^GENERATION SUBSCRIBER MEMORY VALIDATOR SELF-TEST PASS$' \
    "$OUT/validator-self-test.txt"

if [[ "$MODE" == smoke ]]; then
    sides=(16 256); repetitions=1
else
    sides=(16 64 256 512); repetitions=5
fi
for side in "${sides[@]}"; do
    for ((index=0; index<repetitions; index++)); do
        for subscribers in 1 4; do
            key="side-$side-run-$index-subs-$subscribers"
            echo "native subscriber control: $key" >&2
            "$BIN" --generation-subscriber-memory "--side=$side" \
                "--subscribers=$subscribers" \
                >"$OUT/$key.txt" 2>"$OUT/$key.stderr" || {
                    cat "$OUT/$key.stderr" >&2
                    tail -50 "$OUT/$key.txt" >&2
                    exit 1
                }
            test ! -s "$OUT/$key.stderr" || {
                tail -60 "$OUT/$key.stderr" >&2; exit 1;
            }
            python3 "$PY" "$OUT/$key.txt" >"$OUT/$key-stages.csv"
            test "$(wc -l <"$OUT/$key-stages.csv")" -eq 12
            grep -q "^M3 GENERATION SUBSCRIBER MEMORY PASS: side=$side subscribers=$subscribers " \
                "$OUT/$key.txt"
        done
    done
done
python3 - "$OUT" "$repetitions" "${sides[*]}" <<'PY'
import csv
from pathlib import Path
import sys

out = Path(sys.argv[1])
repeats = int(sys.argv[2])
sides = [int(x) for x in sys.argv[3].split()]
metrics = (
    "glibc_malloc_used_bytes", "glibc_mmap_bytes",
    "thread_gc_cumulative_bytes", "vmrss_kib", "vmhwm_kib"
)
with (out / "paired-subscriber-differences.csv").open(
        "w", newline="", encoding="utf-8") as stream:
    writer = csv.writer(stream)
    writer.writerow((
        "side", "repeat", "phase", "one_live_subscribers",
        "four_live_subscribers",
        *(f"baseline_corrected_four_minus_one_{name}" for name in metrics)
    ))
    for side in sides:
        for repeat in range(repeats):
            observed = {}
            for subscribers in (1, 4):
                name = f"side-{side}-run-{repeat}-subs-{subscribers}-stages.csv"
                with (out / name).open(newline="", encoding="utf-8") as file:
                    rows = list(csv.DictReader(file))
                if len(rows) != 11:
                    raise ValueError("paired subscriber input row count")
                observed[subscribers] = rows
            one = observed[1]; four = observed[4]
            for i in range(11):
                if one[i]["phase"] != four[i]["phase"]:
                    raise ValueError("mismatched subscriber phase")
                if one[i]["active_generations"] != four[i]["active_generations"] or (
                    one[i]["requested_live_payload_bytes"] !=
                    four[i]["requested_live_payload_bytes"]
                ) or (one[i]["illustrative_charge_bytes"] !=
                      four[i]["illustrative_charge_bytes"]):
                    raise ValueError("physical backing or accounted payload mismatch")
                deltas = [
                    (int(four[i][m]) - int(four[0][m])) -
                    (int(one[i][m]) - int(one[0][m]))
                    for m in metrics
                ]
                writer.writerow((side, repeat, one[i]["phase"],
                                 one[i]["live_subscribers"],
                                 four[i]["live_subscribers"], *deltas))
PY
(
    cd "$OUT"
    sha256sum environment.txt build.log validator-self-test.txt \
        paired-subscriber-differences.csv \
        side-*.txt side-*.stderr side-*-stages.csv > CHECKSUMS.sha256
    sha256sum -c CHECKSUMS.sha256 > checksum-validation.txt
)
echo "M3 GENERATION SUBSCRIBER MEMORY XPS PASS: $OUT"
echo "Archive checked evidence without snapshot/ only."
