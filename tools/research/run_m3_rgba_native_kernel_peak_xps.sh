#!/usr/bin/env bash
# Issue #74: process-wide kernel RSS high-water vs existing per-event request peak.
# Independent pinned Linux/glibc/XPS research ONLY. No production API changes.
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBS="$(dirname "$REPO")"
MODE=normal
if [[ "${1:-}" == "--smoke" ]]; then MODE=smoke; shift; fi
if [[ "$#" -gt 1 ]]; then
    echo "Usage: $0 [--smoke] [new-empty-evidence-directory]" >&2
    exit 2
fi
OUT="${1:-$REPO/data/m3-native-kernel-peak-xps/$(date -u +%Y%m%dT%H%M%SZ)}"
if [[ -e "$OUT" && ( ! -d "$OUT" || -n "$(ls -A "$OUT")" ) ]]; then
    echo "ERROR: evidence directory already contains data: $OUT" >&2
    exit 1
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
for command in git tar dub ldc2 cc sha256sum python3 lscpu; do
    command -v "$command" >/dev/null || {
        echo "ERROR: missing prerequisite $command" >&2
        exit 1
    }
done
compiler="$(ldc2 --version | sed -n '1p')"
[[ "$compiler" == 'LDC - the LLVM D compiler (1.43.0):' ]] || {
    echo "ERROR: requires pinned native LDC 1.43.0, got: $compiler" >&2
    exit 1
}
for dep in raster-d color-d; do
    case "$dep" in
        raster-d) expected=2f2415851e45001df92ce56dad409f680684ba8d ;;
        color-d)  expected=3359f08f4e83941ac1a8451cadefb146b5736019 ;;
    esac
    actual="$(git -C "$LIBS/$dep" rev-parse --verify 'v0.2.0^{commit}')"
    [[ "$actual" == "$expected" ]] || {
        echo "ERROR: $dep v0.2.0 drift (expected $expected got $actual)" >&2
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
    echo "compiler_path=$(command -v ldc2)"
    echo "cc=$(cc --version | sed -n '1p')"
    echo "dub=$(dub --version)"
    echo "host=$(hostname)"
    echo "kernel=$(uname -a)"
    echo "imagery_commit=$(git -C "$REPO" rev-parse HEAD)"
    echo "imagery_branch=$(git -C "$REPO" branch --show-current)"
    echo "worktree_begin"
    git -C "$REPO" status --short
    echo "worktree_end"
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

ROOT=experiments/m3_rgba_layer_compositing
cc -std=c11 -O2 -Wall -Wextra -Werror -fPIC -shared \
    -o "$OUT/libm3_alloc_events.so" \
    "$SNAP/imagery-d/$ROOT/alloc_events/m3_alloc_events.c" \
    >"$OUT/c-build.log" 2>&1
(
    cd "$SNAP/imagery-d"
    dub build --root="$ROOT/smoke" --compiler=ldc2 \
        --config=native-allocation-events --build=release --force
) >"$OUT/d-build.log" 2>&1
cc -std=c11 -O2 -Wall -Wextra -Werror \
    -o "$OUT/m3_capture_native_peak" \
    "$SNAP/imagery-d/$ROOT/alloc_events/m3_capture_native_peak.c" \
    >"$OUT/launcher-build.log" 2>&1
BIN="$SNAP/imagery-d/$ROOT/smoke/m3-rgba-layer-compositing-consumer"
test -x "$BIN" || { echo "ERROR: missing independent consumer binary" >&2; exit 1; }
CAPTURE="$OUT/m3_capture_native_peak"
SUMMARY="$SNAP/imagery-d/tools/research/summarize_m3_rgba_native_kernel_peak_xps.py"
# Native supervisor is invoked DIRECTLY from bash. Running a Python child
# supervisor would contaminate wait4 ru_maxrss with Python's pre-exec HWM.
"$CAPTURE" "$SNAP/capture-canary" "$OUT/libm3_alloc_events.so" /usr/bin/true
# The larger EXECD child must have a larger kernel peak. Python is only
# the payload of the native-C launched canary, NEVER the parent supervisor.
"$CAPTURE" "$SNAP/capture-canary-large" "$OUT/libm3_alloc_events.so" \
    "$(command -v python3)" -c \
    'data=bytearray(24*1024*1024); data[0]=1; print("native-child-peak")'
python3 - "$SNAP/capture-canary-wait4.csv" \
    "$SNAP/capture-canary-large-wait4.csv" \
    >"$OUT/capture-self-test.txt" <<'PY'
import csv, sys
receipts = []
for name in sys.argv[1:]:
    with open(name, newline="", encoding="utf-8") as source:
        entries = list(csv.DictReader(source))
    assert len(entries) == 1
    assert tuple(entries[0]) == (
        "exit_code", "kernel_peak_rss_kib", "minor_faults", "major_faults",
        "launcher_pre_spawn_peak_rss_kib")
    assert entries[0]["exit_code"] == "0"
    assert int(entries[0]["kernel_peak_rss_kib"]) > 0
    assert int(entries[0]["launcher_pre_spawn_peak_rss_kib"]) > 0
    receipts.append(entries[0])
assert (int(receipts[1]["kernel_peak_rss_kib"]) -
        int(receipts[0]["kernel_peak_rss_kib"])) >= 8192, (
    "large exec child did not raise native-observed peak by at least 8 MiB")
print("NATIVE MINIMAL C LAUNCHER SCALING CANARY PASS")
PY
python3 "$SUMMARY" --self-test >"$OUT/summary-self-test.txt"

if [[ "$MODE" == smoke ]]; then
    sides=(16 256); repetitions=1
else
    sides=(16 64 256 512); repetitions=3
fi
for side in "${sides[@]}"; do
    for ((index=0; index<repetitions; index++)); do
        for case in markers raw import full; do
            key="side-$side-run-$index-$case"
            echo "native kernel peak comparison: $key" >&2
            if [[ "$case" == full ]]; then
                command_args=(--generation-memory "--side=$side")
            else
                command_args=(--native-allocation-control
                    "--case=$case" "--side=$side")
            fi
            "$CAPTURE" "$OUT/$key" \
                "$OUT/libm3_alloc_events.so" \
                "$BIN" "${command_args[@]}"
            python3 "$SUMMARY" "$OUT/$key" "$case" "$side" \
                "$OUT/$key-summary.csv" >"$OUT/$key-validation.txt"
            test "$(wc -l <"$OUT/$key-summary.csv")" -eq 2
            test "$(wc -l <"$OUT/$key-stages.csv")" -eq 10
        done
    done
done
python3 - "$OUT" "$repetitions" "${sides[*]}" <<'PY'
import csv
from pathlib import Path
import sys

out = Path(sys.argv[1])
repetitions = int(sys.argv[2])
sides = [int(v) for v in sys.argv[3].split()]
names = ("markers", "raw", "import", "full")
comparisons = (("raw", "markers"), ("import", "raw"),
               ("full", "import"), ("full", "markers"))
with (out / "paired-kernel-vs-request-peaks.csv").open(
        "w", newline="", encoding="utf-8") as stream:
    writer = csv.writer(stream)
    writer.writerow(("side", "repeat", "comparison",
                     "delta_kernel_peak_rss_kib",
                     "delta_intercepted_requested_peak_bytes",
                     "a_kernel_peak_rss_kib", "b_kernel_peak_rss_kib"))
    for side in sides:
        for index in range(repetitions):
            rows = {}
            for case in names:
                file = out / f"side-{side}-run-{index}-{case}-summary.csv"
                with file.open(newline="", encoding="utf-8") as inp:
                    values = list(csv.DictReader(inp))
                if len(values) != 1 or values[0]["case"] != case or (
                    int(values[0]["side"]) != side
                ):
                    raise ValueError("unexpected case/side in matched receipt")
                rows[case] = values[0]
            for a, b in comparisons:
                x, y = rows[a], rows[b]
                ax, by = int(x["kernel_peak_rss_kib"]), int(y["kernel_peak_rss_kib"])
                writer.writerow((
                    side, index, a + "-" + b, ax - by,
                    int(x["peak_intercepted_requested_bytes"]) -
                    int(y["peak_intercepted_requested_bytes"]),
                    ax, by))
PY
# Full-mode sample-vs-wait4 disagreement is a FIRST-CLASS research result.
# A process may replay all native events correctly while its two Linux
# resident-memory statistics disagree. Never falsify rows or fail before
# the checksummed evidence manifest is produced.
python3 - "$OUT" "$repetitions" "${sides[*]}" <<'PY'
import csv
from pathlib import Path
import sys

out = Path(sys.argv[1])
repetitions = int(sys.argv[2])
sides = [int(x) for x in sys.argv[3].split()]
disagreements = 0
rss_disagreements = 0
with (out / "peak-observation-disagreements.csv").open(
        "w", newline="", encoding="utf-8") as dest:
    writer = csv.writer(dest)
    writer.writerow((
        "side", "repeat", "kernel_peak_rss_kib",
        "full_max_sampled_vm_rss_kib",
        "full_max_sampled_vm_hwm_kib",
        "wait4_minus_max_sampled_rss_kib",
        "wait4_minus_max_sampled_hwm_kib",
        "full_rss_exceeds_wait4",
        "full_hwm_exceeds_wait4"
    ))
    for side in sides:
        for repeat in range(repetitions):
            file = out / f"side-{side}-run-{repeat}-full-summary.csv"
            with file.open(newline="", encoding="utf-8") as src:
                rows = list(csv.DictReader(src))
            if len(rows) != 1 or int(rows[0]["side"]) != side:
                raise ValueError("invalid full peak observation receipt")
            row = rows[0]
            writer.writerow([side, repeat] + [
                row[x] for x in (
                    "kernel_peak_rss_kib", "full_max_sampled_vm_rss_kib",
                    "full_max_sampled_vm_hwm_kib",
                    "wait4_minus_max_sampled_rss_kib",
                    "wait4_minus_max_sampled_hwm_kib",
                    "full_rss_exceeds_wait4",
                    "full_hwm_exceeds_wait4"
                )
            ])
            disagreements += int(row["full_hwm_exceeds_wait4"])
            rss_disagreements += int(row["full_rss_exceeds_wait4"])
print(
    f"PEAK OBSERVATION DISCORDANCE: VmHWM>wait4 {disagreements}/"
    f"{len(sides)*repetitions}, VmRSS>wait4 "
    f"{rss_disagreements}/{len(sides)*repetitions}; "
    "preserved signed values, NO physical admission claim"
)
PY
(
    cd "$OUT"
    sha256sum environment.txt c-build.log d-build.log \
        launcher-build.log capture-self-test.txt summary-self-test.txt \
        m3_capture_native_peak libm3_alloc_events.so \
        paired-kernel-vs-request-peaks.csv \
        peak-observation-disagreements.csv \
        side-* >CHECKSUMS.sha256
    sha256sum -c CHECKSUMS.sha256 >checksum-validation.txt
)
echo "M3 NATIVE KERNEL PEAK XPS PASS: $OUT"
echo "Archive checksummed evidence EXCLUDING snapshot/."
