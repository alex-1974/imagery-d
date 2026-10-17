#!/usr/bin/env bash
# R-IM-03b reproducible, OPT-IN native XPS paired benchmark.
# No performance result is asserted until this is actually executed.
set -euo pipefail

REPO="${1:-$(git rev-parse --show-toplevel)}"
SIDE="${2:-1024}"
ROUNDS="${3:-7}"
COMPILER="${4:-ldc2}"

cd "$REPO"
test -f experiments/r_im_03a_levels/bench/dub.sdl
test -d ../raster-d || { echo "Missing sibling raster-d" >&2; exit 2; }
printf 'RUN_UTC=%s\n' "$(date -u +%FT%TZ)"
printf 'GIT_HEAD=%s\n' "$(git rev-parse HEAD)"
printf 'GIT_BRANCH=%s\n' "$(git branch --show-current)"
printf 'GIT_STATUS=%s\n' "$(git status --porcelain | tr '\n' ';')"
printf 'HOST=%s\n' "$(hostname)"
printf 'OS=%s\n' "$(uname -srvmo)"
printf 'CPU=%s\n' "$(grep -m 1 'model name' /proc/cpuinfo || true)"
printf 'GOVERNORS=%s\n' "$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u | tr '\n' ',' || true)"
printf 'SIBLING_RASTER_SHA=%s\n' "$(git -C ../raster-d rev-parse HEAD)"
printf 'SIZE=%s ROUNDS=%s COMPILER=%s\n' "$SIDE" "$ROUNDS" "$COMPILER"
"$COMPILER" --version
dub --version
echo "Measurement scope: already-decoded, already-allocated RGBA buffers."
echo "Expected fields: preparation separately; median repeated operations."
echo "No C++ parity, CPU pinning, governor control or perf counters assumed."
echo "Do NOT compare numbers from different semantic or system conditions."
dub run --root=experiments/r_im_03a_levels/bench \
  --compiler="$COMPILER" --build=release --force -- "$SIDE" "$ROUNDS"
