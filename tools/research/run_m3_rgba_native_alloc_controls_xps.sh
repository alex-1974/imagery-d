#!/usr/bin/env bash
# Issue #74 four matched controls, immutable research snapshots, XPS native.
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
OUT="${1:-$REPO/data/m3-native-alloc-controls-xps/$(date -u +%Y%m%dT%H%M%SZ)}"
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
PY="$SNAP/imagery-d/tools/research/summarize_m3_rgba_native_alloc_controls.py"
python3 "$PY" --self-test > "$OUT/control-self-test.txt"
grep -q '^NATIVE ALLOCATION CONTROLS SELF-TEST PASS$' "$OUT/control-self-test.txt"

if [[ "$MODE" == smoke ]]; then
  sides=(16 256); repetitions=1
else
  sides=(16 64 256 512); repetitions=3
fi
for side in "${sides[@]}"; do
  for ((iteration=0;iteration<repetitions;iteration++)); do
    for case in markers raw import full; do
      key="side-${side}-run-${iteration}-${case}"
      echo "native control $key" >&2
      (
        exec 9>"$OUT/$key-events.csv"
        if [[ "$case" == full ]]; then
          LD_PRELOAD="$OUT/libm3_alloc_events.so" \
            "$BIN" --generation-memory "--side=$side" \
            > "$OUT/$key-stdout.txt" 2>"$OUT/$key-stderr.txt"
        else
          LD_PRELOAD="$OUT/libm3_alloc_events.so" \
            "$BIN" --native-allocation-control "--side=$side" "--case=$case" \
            > "$OUT/$key-stdout.txt" 2>"$OUT/$key-stderr.txt"
        fi
      )
      if [[ "$case" == full ]]; then
        grep -q '^M3 GENERATION MEMORY PASS:' "$OUT/$key-stdout.txt"
      else
        grep -q "^M3 ALLOCATION CONTROL PASS: case=$case side=$side" \
          "$OUT/$key-stdout.txt"
      fi
      test ! -s "$OUT/$key-stderr.txt" || {
        echo "unexpected stderr for $key" >&2
        tail -60 "$OUT/$key-stderr.txt" >&2; exit 1;
      }
      python3 "$PY" "$OUT/$key-events.csv" "$case" "$side" \
        "$OUT/$key"
      test -s "$OUT/$key-summary.csv" && test -s "$OUT/$key-stages.csv"
    done
  done
done
(
  cd "$OUT"
  sha256sum environment.txt c-build.log d-build.log control-self-test.txt \
      libm3_alloc_events.so side-* > CHECKSUMS.sha256
  sha256sum -c CHECKSUMS.sha256
)
echo "M3 NATIVE ALLOCATION CONTROLS PASS: $OUT"
echo "Upload a checksummed archive excluding snapshot/ only."
