#!/usr/bin/env bash
# Opt-in native R-IM-03c XPS comparison. No edits to sibling repositories.
set -euo pipefail
REPO="${1:-$(git rev-parse --show-toplevel)}"
SIDE="${2:-1024}"
ROUNDS="${3:-7}"
PATTERN="${4:-1}"
DC="${5:-ldc2}"
EXPECTED_RASTER=2f2415851e45001df92ce56dad409f680684ba8d

cd "$REPO"
test -f experiments/r_im_03a_levels/bench_03c/dub.sdl
test -d ../raster-d || { echo "Missing adjacent raster-d checkout" >&2; exit 2; }
CURRENT_RASTER="$(git -C ../raster-d rev-parse HEAD)"
if [[ "$CURRENT_RASTER" != "$EXPECTED_RASTER" ]]; then
  printf 'ERROR: raster-d commit %s != pinned %s\n' "$CURRENT_RASTER" "$EXPECTED_RASTER" >&2
  echo 'Use a separate clean benchmark clone; do not alter active workspace branches.' >&2
  exit 3
fi
printf 'RUN_UTC=%s\n' "$(date -u +%FT%TZ)"
printf 'HOST=%s\n' "$(hostname)"
printf 'OS=%s\n' "$(uname -srvmo)"
printf 'CPU=%s\n' "$(grep -m1 'model name' /proc/cpuinfo || true)"
printf 'GOVERNORS=%s\n' "$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u | tr '\n' ',' || true)"
printf 'IMAGERY_HEAD=%s\n' "$(git rev-parse HEAD)"
printf 'IMAGERY_STATUS=%s\n' "$(git status --porcelain | tr '\n' ';')"
printf 'RASTER_HEAD=%s\n' "$CURRENT_RASTER"
printf 'PARAMS_SIDE=%s PARAMS_ROUNDS=%s PARAMS_PATTERN=%s\n' "$SIDE" "$ROUNDS" "$PATTERN"
echo 'PATTERN: 0=expanded 8-bit, 1=full 16-bit diversity, 2=smooth synthetic gradient'
"$DC" --version
dub --version
echo 'RIM03C_RAW reports every execution. Hosted CI figures are NOT XPS evidence.'
echo 'Measurement: Phobos pow vs LLVM pow vs sqrt(gamma2) vs prepared binary64 LUT.'
dub run --root=experiments/r_im_03a_levels/bench_03c \
  --compiler="$DC" --build=release --force -- "$SIDE" "$ROUNDS" "$PATTERN"
