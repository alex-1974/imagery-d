#!/usr/bin/env bash
# R-IM-03e short D-versus-D native research pilot. No C++ code or production API.
# Usage: bash pilot_r_im_03e_xps.sh prepare /absolute/output/path [ldc2]
#        bash pilot_r_im_03e_xps.sh pilot   /absolute/output/path
# Scope: isolated checkouts, conservative temperature stop, 128x128 ABBA pilot.
set -euo pipefail
export LC_ALL=C
BASE=68ddbdefc5b9cfefd95fe8545ba4848fc5736beb
CAND=ae36974af9369d7bbdbbecf9b8619d2da52e59be
RASTER=2f2415851e45001df92ce56dad409f680684ba8d
MODE="${1:-}"; OUT="${2:-}"; DC="${3:-ldc2}"
[[ "$MODE" == prepare || "$MODE" == pilot ]] || { echo 'Usage: script prepare|pilot /absolute/output/path [ldc2]' >&2; exit 2; }
[[ "$OUT" == /* && "$OUT" != / && "$OUT" != "$HOME" && "$OUT" != *'/d-geospatial-workspace/'* ]] || {
  echo 'ERROR: output must be an absolute path OUTSIDE d-geospatial-workspace' >&2; exit 2;
}
for cmd in git tar python3 sensors top vmstat timeout setsid sha256sum; do
  command -v "$cmd" >/dev/null || { echo "ERROR: missing $cmd" >&2; exit 2; }
done
[[ "$MODE" == pilot || "$(command -v "$DC")" ]] || { echo "ERROR: missing compiler $DC" >&2; exit 2; }
[[ "$MODE" == pilot || "$(command -v dub)" ]] || { echo 'ERROR: missing dub' >&2; exit 2; }
OUT="$(realpath -m -- "$OUT")"
[[ "$OUT" != *'/d-geospatial-workspace/'* ]] || { echo 'ERROR: output resolved into workspace' >&2; exit 2; }
THERMAL=/sys/devices/system/cpu/cpu0/thermal_throttle
[[ -r "$THERMAL/package_throttle_count" && -r "$THERMAL/core_throttle_count" ]] || {
  echo 'ERROR: CPU0 thermal-throttle sysfs unavailable; abort' >&2; exit 3;
}
SENSOR=''
for dir in /sys/class/hwmon/hwmon*; do
  [[ -r "$dir/name" && "$(cat "$dir/name")" == coretemp ]] || continue
  for label in "$dir"/temp*_label; do
    [[ -r "$label" && "$(cat "$label")" == 'Package id 0' ]] || continue
    value="${label%_label}_input"
    [[ -r "$value" ]] && SENSOR="$value"
  done
done
[[ -n "$SENSOR" ]] || { echo 'ERROR: no coretemp Package id 0 thermal sensor; abort' >&2; exit 3; }
temp_millideg() { cat "$SENSOR"; }
pkg_counter() { cat "$THERMAL/package_throttle_count"; }
core_counter() { cat "$THERMAL/core_throttle_count"; }
check_cool() {
  local value
  value="$(temp_millideg)"
  [[ "$value" =~ ^[0-9]+$ && "$value" -lt 70000 ]] || {
    echo "RIM03E_ABORT=preflight_package_${value}mC_at_or_above_70C" >&2; return 1;
  }
}
# Only signals a new process group started by THIS helper, never any user process.
guarded() {
  local tag="$1" limit="$2" log="$3"; shift 3
  local startpkg startcore pid rc=0 reason='' value pkg core
  check_cool
  startpkg="$(pkg_counter)"; startcore="$(core_counter)"
  echo "RIM03E_COMMAND=$tag TIME=$(date -u +%FT%TZ) PACKAGE=$startpkg CORE0=$startcore" | tee -a "$OUT/receipt.log"
  setsid timeout --signal=TERM --kill-after=2s "${limit}s" "$@" >"$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    value="$(temp_millideg)"; pkg="$(pkg_counter)"; core="$(core_counter)"
    echo "RIM03E_TELEMETRY,$tag,$(date -u +%FT%TZ),$value,$pkg,$core" >> "$OUT/telemetry.csv"
    if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value >= 85000 )); then reason="temperature_at_or_above_85C"; fi
    if (( pkg != startpkg || core != startcore )); then reason="new_thermal_throttle_transition"; fi
    if [[ -n "$reason" ]]; then
      echo "RIM03E_ABORT=$tag:$reason" | tee -a "$OUT/receipt.log" >&2
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" || true
      return 4
    fi
    sleep 0.5
  done
  wait "$pid" || rc=$?
  value="$(temp_millideg)"; pkg="$(pkg_counter)"; core="$(core_counter)"
  echo "RIM03E_TELEMETRY,$tag,$(date -u +%FT%TZ),$value,$pkg,$core" >> "$OUT/telemetry.csv"
  if (( rc != 0 || value >= 85000 || pkg != startpkg || core != startcore )); then
    echo "RIM03E_ABORT=$tag:exit_${rc}_temp_${value}_pkg_${pkg}_core_${core}" | tee -a "$OUT/receipt.log" >&2
    return 4
  fi
  echo "RIM03E_DONE=$tag" | tee -a "$OUT/receipt.log"
}
quiet() {
  local label="$1" beforepkg beforecore idle swap avail
  check_cool
  beforepkg="$(pkg_counter)"; beforecore="$(core_counter)"
  top -b -n 2 -d 1 -o %CPU | awk '/^top -/{n++} n==2{print}' > "$OUT/${label}-top.log"
  vmstat -w 1 4 > "$OUT/${label}-vmstat.log"
  idle="$(python3 - "$OUT/${label}-top.log" <<'PY'
import re,sys
s=open(sys.argv[1]).read(); x=re.search(r'^%CPU\(s\):.*?([0-9]+(?:\.[0-9]+)?)\s+id\b',s,re.I|re.M)
if not x: sys.exit('top idle field missing')
print(x.group(1))
PY
)"
  swap="$(awk 'NR>3 && $1~/^[0-9]+$/ {if($7>max)max=$7;if($8>max)max=$8} END {print max+0}' "$OUT/${label}-vmstat.log")"
  avail="$(awk '$1=="MemAvailable:" {print $2}' /proc/meminfo)"
  echo "RIM03E_QUIET=$label idle=$idle swap_max_KiBps=$swap mem_available_KiB=$avail temp_mC=$(temp_millideg)" | tee -a "$OUT/receipt.log"
  [[ "$(pkg_counter)" == "$beforepkg" && "$(core_counter)" == "$beforecore" ]] || {
    echo 'RIM03E_ABORT=thermal_transition_during_preflight' >&2; return 4;
  }
  check_cool
  awk -v idle="$idle" -v swap="$swap" -v avail="$avail" 'BEGIN{exit !(idle>=92 && swap<=1024 && avail>=2097152)}' || {
    echo 'RIM03E_ABORT=background_load_or_paging_or_low_memory' >&2; return 4;
  }
}
if [[ "$MODE" == prepare ]]; then
  [[ ! -e "$OUT" ]] || { echo 'ERROR: prepare needs a new output directory' >&2; exit 2; }
  check_cool
  mkdir -p "$OUT"
  echo "RIM03E_PINS base=$BASE candidate=$CAND raster=$RASTER compiler=$DC" | tee "$OUT/receipt.log"
  uname -a >> "$OUT/receipt.log"
  "$DC" --version > "$OUT/compiler-version.log"; dub --version > "$OUT/dub-version.log"
  git clone -q --filter=blob:none --single-branch --branch research/r-im-03e-d-native-levels-specialization \
    https://github.com/alex-1974/imagery-d.git "$OUT/imagery"
  git clone -q --filter=blob:none https://github.com/alex-1974/raster-d.git "$OUT/imagery/deps/raster-d"
  git -C "$OUT/imagery/deps/raster-d" checkout -q --detach "$RASTER"
  [[ "$(git -C "$OUT/imagery/deps/raster-d" rev-parse HEAD)" == "$RASTER" ]] || exit 3
  for sha in "$BASE" "$CAND"; do git -C "$OUT/imagery" cat-file -e "$sha^{commit}"; done
  guarded prepare 120 "$OUT/prepare-build.log" bash \
    "$OUT/imagery/tools/research/compare_r_im_03e_codegen.sh" "$DC" "$OUT/build"
  for variant in baseline candidate; do
    [[ -x "$OUT/build/pair/$variant/experiments/r_im_03a_levels/bench_03c/r-im-03c-levels-math-benchmark" ]] || exit 4
    sha256sum "$OUT/build/pair/$variant/experiments/r_im_03a_levels/bench_03c/r-im-03c-levels-math-benchmark" \
      > "$OUT/$variant.sha256"
  done
  printf 'RIM03E_PREPARED=%s:%s:%s\n' "$BASE" "$CAND" "$RASTER" > "$OUT/prepared.ok"
  echo "RIM03E_PREPARE_OK=$OUT" | tee -a "$OUT/receipt.log"
  exit 0
fi
[[ -f "$OUT/prepared.ok" ]] || { echo 'ERROR: run prepare first' >&2; exit 3; }
[[ "$(cat "$OUT/prepared.ok")" == "RIM03E_PREPARED=$BASE:$CAND:$RASTER" ]] || {
  echo 'ERROR: provenance mismatch' >&2; exit 3;
}
for variant in baseline candidate; do sha256sum -c "$OUT/$variant.sha256" >/dev/null; done
[[ ! -f "$OUT/pilot-complete.flag" ]] || { echo 'ERROR: already completed; keep original evidence' >&2; exit 3; }
quiet baseline_start
order=(baseline candidate candidate baseline)
logs=()
for idx in 0 1 2 3; do
  variant="${order[$idx]}"
  quiet "before_${idx}_${variant}"
  log="$OUT/pilot-$(printf %02d "$idx")-$variant.log"
  exe="$OUT/build/pair/$variant/experiments/r_im_03a_levels/bench_03c/r-im-03c-levels-math-benchmark"
  guarded "pilot_${idx}_${variant}" 25 "$log" "$exe" 128 2 1 forward
  logs+=("$variant:$log")
done
python3 - "$OUT" "${logs[@]}" <<'PY'
import csv,sys
from collections import defaultdict
from statistics import median
from pathlib import Path
out=Path(sys.argv[1]); expected={}; obs=defaultdict(list)
for item in sys.argv[2:]:
    variant,path=item.split(':',1); cases=raw=0
    for line in Path(path).read_text().splitlines():
        f=line.split(',')
        if f[0]=='RIM03C_SUMMARY':
            if len(f)!=17: raise SystemExit('invalid summary')
            key=tuple(f[i] for i in (1,2,3,4,5))
            sem=tuple(f[i] for i in (7,13,14,15,16))
            if key in expected and expected[key]!=sem: raise SystemExit('semantic mismatch '+str(key))
            expected[key]=sem; cases+=1
        elif f[0]=='RIM03C_RAW':
            if len(f)!=9: raise SystemExit('invalid raw row')
            key=tuple(f[i] for i in (1,2,3,4,5)); obs[(variant,key,int(f[7]))].append(int(f[8]));raw+=1
    if (cases,raw)!=(8,64): raise SystemExit(f'incomplete pilot process: {item} {cases=} {raw=}')
if len(expected)!=8: raise SystemExit('incomplete case cohort')
with (out/'pilot-paired-microseconds.csv').open('w',newline='') as fh:
    w=csv.writer(fh);w.writerow(('kind','pattern','side','layout','mask','method','baseline_median_us','candidate_median_us','candidate/baseline','baseline_samples','candidate_samples'))
    for key in sorted(expected):
        for method in range(4):
            a=obs[('baseline',key,method)];b=obs[('candidate',key,method)]
            if len(a)!=4 or len(b)!=4: raise SystemExit('incomplete paired raw samples')
            aa,bb=median(a),median(b)
            w.writerow((*key,method,aa,bb,round(bb/aa,4) if aa else 'NA',';'.join(map(str,a)),';'.join(map(str,b))))
print('RIM03E_SEMANTIC_EQUALITY=PASS; 8 cases, 256 RAW values, exploratory pilot only')
PY
printf '%s\n' "RIM03E_EXPLORATORY_COMPLETE $(date -u +%FT%TZ)" > "$OUT/pilot-complete.flag"
echo "RIM03E_PILOT_COMPLETE=$OUT (NO performance qualification)" | tee -a "$OUT/receipt.log"
