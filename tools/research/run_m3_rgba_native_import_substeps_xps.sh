#!/usr/bin/env bash
# Issue #74 direct GC.addRange/removeRange control and public import attribution, XPS.
# Only reads sibling tags and writes to a fresh imagery-d evidence directory.
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBS="$(dirname "$REPO")"
MODE=normal
if [[ "${1:-}" == "--smoke" ]]; then MODE=smoke; shift; fi
if [[ "$#" -gt 1 ]]; then
  echo "Usage: $0 [--smoke] [new-empty-evidence-directory]" >&2
  exit 2
fi
OUT="${1:-$REPO/data/m3-native-import-substeps-xps/$(date -u +%Y%m%dT%H%M%SZ)}"
if [[ -e "$OUT" && ( ! -d "$OUT" || -n "$(ls -A "$OUT")" ) ]]; then
  echo "ERROR: output exists and is nonempty: $OUT" >&2
  exit 1
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
for command in git tar dub ldc2 cc python3 sha256sum lscpu; do
  command -v "$command" >/dev/null || {
    echo "missing prerequisite: $command" >&2; exit 1;
  }
done
COMPILER="$(ldc2 --version | sed -n '1p')"
[[ "$COMPILER" == 'LDC - the LLVM D compiler (1.43.0):' ]] || {
  echo "requires exact native LDC 1.43.0; observed $COMPILER" >&2
  exit 1
}
for dep in raster-d color-d; do
  git -C "$LIBS/$dep" rev-parse -q --verify 'v0.2.0^{commit}' >/dev/null
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
  echo "compiler=$COMPILER"
  echo "compiler_bin=$(command -v ldc2)"
  echo "cc=$(cc --version | sed -n '1p')"
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
} > "$OUT/environment.txt"

ROOT="experiments/m3_rgba_layer_compositing"
cc -std=c11 -O2 -Wall -Wextra -Werror -fPIC -shared \
  -o "$OUT/libm3_alloc_events.so" \
  "$SNAP/imagery-d/$ROOT/alloc_events/m3_alloc_events.c" \
  > "$OUT/c-build.log" 2>&1
(
 cd "$SNAP/imagery-d"
 dub build --root="$ROOT/smoke" --compiler=ldc2 \
   --config=native-allocation-events --build=release --force
) >"$OUT/d-build.log" 2>&1
BIN="$SNAP/imagery-d/$ROOT/smoke/m3-rgba-layer-compositing-consumer"
test -x "$BIN" || { echo "missing LDC independent consumer" >&2; exit 1; }
PY="$SNAP/imagery-d/tools/research/summarize_m3_rgba_native_import_substeps.py"
python3 "$PY" --self-test > "$OUT/substep-self-test.txt"
grep -q '^NATIVE IMPORT SUBSTEPS SELF-TEST PASS$' "$OUT/substep-self-test.txt"

if [[ "$MODE" == smoke ]]; then
  repetitions=1
else
  repetitions=3
fi
for side in 16 256; do
  for ((iteration=0;iteration<repetitions;iteration++)); do
    for case in raw adopt gc-range import; do
      key="side-$side-run-$iteration-$case"
      echo "native import steps $key" >&2
      (
        exec 9>"$OUT/$key-events.csv"
        LD_PRELOAD="$OUT/libm3_alloc_events.so" \
          "$BIN" --native-import-substeps "--side=$side" "--case=$case" \
          > "$OUT/$key-stdout.txt" 2>"$OUT/$key-stderr.txt"
      )
      grep -q "^M3 NATIVE IMPORT SUBSTEPS PASS: case=$case side=$side stages=13" \
        "$OUT/$key-stdout.txt"
      test ! -s "$OUT/$key-stderr.txt" || {
        tail -60 "$OUT/$key-stderr.txt" >&2; exit 1;
      }
      python3 "$PY" "$OUT/$key-events.csv" "$case" "$side" \
        "$OUT/$key-stages.csv" > "$OUT/$key-validator.txt"
      test "$(wc -l < "$OUT/$key-stages.csv")" -eq 14
      test -s "$OUT/$key-lifetimes.csv"
    done
  done
done
python3 - "$OUT" "$repetitions" <<'PY'
import csv, pathlib, sys
out = pathlib.Path(sys.argv[1]); repeats = int(sys.argv[2])
with (out / "paired-differences.csv").open("w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["side","repeat","stage","comparison",
                     "delta_other_calls","delta_other_bytes",
                     "delta_other_live_end_bytes"])
    for side in (16, 256):
        for repeat in range(repeats):
            runs = {}
            for case in ("raw", "adopt", "gc-range", "import"):
                file = out / f"side-{side}-run-{repeat}-{case}-stages.csv"
                with file.open(newline="") as rows:
                    runs[case] = list(csv.DictReader(rows))
            for stage in range(13):
                for a,b in (("adopt","raw"),("gc-range","raw"),
                            ("import","adopt"),("import","gc-range"),
                            ("import","raw")):
                    x,y = runs[a][stage],runs[b][stage]
                    writer.writerow([side,repeat,stage+1,a+"-"+b,
                        int(x["other_calls"])-int(y["other_calls"]),
                        int(x["other_bytes"])-int(y["other_bytes"]),
                        int(x["other_live_end_bytes"])-
                          int(y["other_live_end_bytes"])])
PY
# Compare equal-sized requests by birth/free stage without relying on
# ephemeral pointer values or assuming a private raster-d object identity.
python3 - "$OUT" "$repetitions" <<'PY'
import collections, csv, pathlib, sys
out = pathlib.Path(sys.argv[1])
repeats = int(sys.argv[2])
columns = ("side", "repeat", "birth_stage", "free_stage_or_0",
           "requested_bytes_each", "intent_kind", "comparison",
           "delta_allocations", "delta_requested_bytes")
with (out / "paired-lifetime-differences.csv").open(
        "w", newline="", encoding="utf-8") as stream:
    writer = csv.writer(stream)
    writer.writerow(columns)
    for side in (16, 256):
        for repeat in range(repeats):
            histograms = {}
            for case in ("raw", "adopt", "gc-range", "import"):
                path = out / f"side-{side}-run-{repeat}-{case}-lifetimes.csv"
                values = collections.Counter()
                with path.open(newline="", encoding="utf-8") as rows:
                    for event in csv.DictReader(rows):
                        key = tuple(int(event[name]) for name in (
                            "birth_stage", "free_stage_or_0",
                            "requested_bytes_each", "intent_kind"))
                        values[key] += int(event["allocations"])
                histograms[case] = values
            for a, b in (("adopt", "raw"), ("gc-range", "raw"),
                         ("import", "adopt"), ("import", "gc-range"),
                         ("import", "raw")):
                keys = sorted(set(histograms[a]) | set(histograms[b]))
                for birth, death, requested, kind in keys:
                    delta = (histograms[a][(birth, death, requested, kind)] -
                             histograms[b][(birth, death, requested, kind)])
                    if delta:
                        writer.writerow((side, repeat, birth, death,
                                         requested, kind, a + "-" + b,
                                         delta, delta * requested))
PY
(
 cd "$OUT"
 sha256sum environment.txt c-build.log d-build.log substep-self-test.txt \
   libm3_alloc_events.so paired-differences.csv \
   paired-lifetime-differences.csv side-* > CHECKSUMS.sha256
 sha256sum -c CHECKSUMS.sha256 > checksum-validation.txt
)
echo "M3 NATIVE IMPORT SUBSTEPS EVIDENCE PASS: $OUT"
echo "Upload a checksummed archive excluding snapshot/ only; four-arm protocol: raw/adopt/gc-range/import."
