#!/usr/bin/env bash
# R-IM-03d: passive, read-only environment observation before native benchmarks.
# No sudo, no workload, no scheduling/governor changes, no process termination.
# Usage: bash tools/research/inspect_r_im_03d_xps_environment.sh [seconds: 1..15]
set -euo pipefail

if (( $# > 1 )); then
    echo "Usage: $0 [seconds: 1..15]" >&2
    exit 2
fi
DURATION="${1:-5}"
if [[ ! "$DURATION" =~ ^[0-9]+$ ]] || (( 10#$DURATION < 1 || 10#$DURATION > 15 )); then
    echo "ERROR: sample duration must be an integer 1..15 seconds" >&2
    exit 2
fi
DURATION=$((10#$DURATION))
for tool in top vmstat awk date uname cat; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: missing read-only tool $tool" >&2
        exit 3
    fi
done
if [[ ! -r /proc/cpuinfo || ! -r /proc/meminfo ]]; then
    echo "ERROR: Linux /proc CPU/memory information unavailable" >&2
    exit 3
fi

# These counters count entries into a thermal-throttle state since boot,
# not throttled seconds or instruction-level performance.
PACKAGE_COUNTER=/sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count
CORE_COUNTER=/sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count
read_counter() {
    local file="$1"
    if [[ -r "$file" ]]; then
        cat "$file"
    else
        printf 'unavailable\n'
    fi
}
snap() {
    local phase="$1"
    printf 'RIM03D_ENV_TIME_%s=%s\n' "$phase" "$(date -u +%FT%TZ)"
    printf 'RIM03D_ENV_PACKAGE_COUNT_%s=%s\n' "$phase" "$(read_counter "$PACKAGE_COUNTER")"
    printf 'RIM03D_ENV_CORE0_COUNT_%s=%s\n' "$phase" "$(read_counter "$CORE_COUNTER")"
    printf 'RIM03D_ENV_CPU0_FREQ_KHZ_%s=' "$phase"
    read_counter /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
    printf 'RIM03D_ENV_SENSORS_BEGIN_%s\n' "$phase"
    if command -v sensors >/dev/null 2>&1; then
        sensors || true
    else
        echo "unavailable: lm-sensors not installed"
    fi
    printf 'RIM03D_ENV_SENSORS_END_%s\n' "$phase"
}

echo 'RIM03D_ENV_SCHEMA=1'
printf 'RIM03D_ENV_HOST=%s\n' "$(hostname)"
printf 'RIM03D_ENV_KERNEL=%s\n' "$(uname -srmo)"
printf 'RIM03D_ENV_SAMPLE_SECONDS=%s\n' "$DURATION"
echo 'RIM03D_ENV_SCOPE=passive observations only, not a load benchmark'
echo 'RIM03D_ENV_NOTE=cpu0 package counters must not be summed across sibling logical CPUs'
echo 'RIM03D_ENV_NOTE=top instantaneous CPU percentages, NOT ps process-lifetime averages'
echo 'RIM03D_ENV_NOTE=vmstat first data row is historical since-boot average; ignore for present activity'
echo 'RIM03D_ENV_NOTE=used swap does NOT establish ongoing page-in/page-out'
echo 'RIM03D_ENV_BEGIN'
snap BEFORE

echo 'RIM03D_ENV_TOP_SECOND_SAMPLE_BEGIN'
# First top measurement can contain since-boot averages. Select second.
# Read all of top's output: do not head/pipefail-SIGPIPE truncation.
top -b -n 2 -d 1 -o %CPU |
    awk '/^top -/ {sample++; emitted=0}
         sample==2 && emitted<25 {print; emitted++}
         END {if(sample<2) exit 1}'
echo 'RIM03D_ENV_TOP_SECOND_SAMPLE_END'

echo 'RIM03D_ENV_MEMINFO_BEGIN'
if command -v free >/dev/null 2>&1; then
    free -h
else
    echo 'free unavailable; inspect /proc/meminfo instead'
    awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree):/ {print}' /proc/meminfo
fi
if command -v swapon >/dev/null 2>&1; then
    swapon --show || true
fi
echo 'RIM03D_ENV_MEMINFO_END'

echo 'RIM03D_ENV_VMSTAT_BEGIN'
# One boot-average line plus DURATION one-second interval observations.
vmstat -w 1 "$((DURATION + 1))"
echo 'RIM03D_ENV_VMSTAT_END'
snap AFTER
echo 'RIM03D_ENV_NO_AUTO_VERDICT=compare BEFORE/AFTER counter snapshots; temperatures are not in-kernel traces'
echo 'RIM03D_ENV_END'
