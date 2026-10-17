#!/usr/bin/env bash
# Native paired three-way benchmark of EXACT candidate-B owned producer:
# legacy order vs repeated PM ROI scan vs fused PM recheck on pixel use.
# All three produce a real new packed RGBA result in the same compiled build.
# Reuses XPS immutable-source provenance without changing sibling repos.
# Writes only ignored imagery-d/data; dependency repositories are read-only.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBS="$(dirname "$REPO")"
MODE=micro
if [[ "${1:-}" == "--smoke" ]]; then MODE=smoke; shift; fi
if [[ "${1:-}" == "--micro" ]]; then MODE=micro; shift; fi
if [[ "$#" -gt 1 ]]; then
    echo "Usage: $0 [--smoke|--micro] [new-output-directory]" >&2
    exit 2
fi
OUT="${1:-$REPO/data/m3-rgba-fused-xps/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
if [[ -n "$(ls -A "$OUT")" ]]; then
    echo "ERROR: output directory is not empty: $OUT" >&2
    exit 1
fi
for command in git tar dub ldc2 sha256sum python3 lscpu; do
    command -v "$command" >/dev/null || {
        echo "ERROR: missing $command" >&2
        exit 1
    }
done
test -x /usr/bin/time || {
    echo "ERROR: /usr/bin/time missing" >&2
    exit 1
}
COMPILER="$(ldc2 --version | sed -n '1p')"
if [[ "$COMPILER" != "LDC - the LLVM D compiler (1.43.0):" ]]; then
    echo "ERROR: LDC 1.43.0 required, observed: $COMPILER" >&2
    exit 1
fi
# GitHub pull_request jobs legitimately check out detached HEADs; the archived
# measured Git commit, not a mutable branch label, defines reproducibility.
if ! git -C "$REPO" ls-files --error-unmatch \
    tools/research/run_m3_rgba_fused_xps.sh >/dev/null 2>&1; then
    echo "ERROR: runner is not committed in this imagery-d checkout" >&2
    exit 1
fi
# Untracked local benchmarks/archives remain untouched. The evidence
# source is the immutable committed HEAD, NOT potentially dirty worktree files.
if [[ -n "$(git -C "$REPO" status --porcelain)" ]]; then
    echo "NOTE: live imagery-d has local changes/untracked files; using committed HEAD snapshot" \
        | tee "$OUT/working-tree-notice.txt" >&2
fi
for dep in raster-d color-d; do
    git -C "$LIBS/$dep" rev-parse -q --verify 'v0.2.0^{commit}' >/dev/null
done
SNAP="$OUT/snapshot"
mkdir -p "$SNAP/imagery-d" "$SNAP/raster-d" "$SNAP/color-d"
git -C "$REPO" archive --format=tar HEAD | tar -xf - -C "$SNAP/imagery-d"
for dep in raster-d color-d; do
    git -C "$LIBS/$dep" archive --format=tar v0.2.0 | tar -xf - -C "$SNAP/$dep"
done
{
    echo "utc=$(date -u --iso-8601=seconds)"
    echo "host=$(hostname)"
    echo "mode=$MODE"
    echo "source_mode=pinned-v0.2.0"
    echo "compiler=$COMPILER"
    echo "compiler_bin=$(command -v ldc2)"
    echo "dub=$(dub --version)"
    echo "kernel=$(uname -a)"
    echo "imagery_branch=$(git -C "$REPO" branch --show-current)"
    echo "imagery_measured_commit=$(git -C "$REPO" rev-parse HEAD)"
    echo "raster-d.measured_commit=$(git -C "$LIBS/raster-d" rev-parse 'v0.2.0^{commit}')"
    echo "color-d.measured_commit=$(git -C "$LIBS/color-d" rev-parse 'v0.2.0^{commit}')"
    for dep in raster-d color-d; do
        echo "$dep.live_commit=$(git -C "$LIBS/$dep" rev-parse HEAD)"
        echo "$dep.live_status_begin"
        git -C "$LIBS/$dep" status --short
        echo "$dep.live_status_end"
    done
    echo "cpu_begin"
    lscpu
    echo "cpu_end"
    echo "governors_begin"
    for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        if [[ -f "$f" ]]; then echo "$f=$(<"$f")"; fi
    done
    echo "governors_end"
    echo "current_freq_begin"
    for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do
        if [[ -f "$f" ]]; then echo "$f=$(<"$f")"; fi
    done
    echo "current_freq_end"
    echo "mem_begin"
    grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo
    echo "mem_end"
} > "$OUT/environment.txt"

# A validator typo must NEVER waste 40 expensive recorded XPS cases.
# Exercise the exact validator from the pinned source snapshot first.
python3 "$SNAP/imagery-d/tools/research/summarize_m3_rgba_fused_xps.py" --self-test

ROOT=experiments/m3_rgba_layer_compositing/smoke
(
    cd "$SNAP/imagery-d"
    dub build --root="$ROOT" --compiler=ldc2 --build=release --force
) > "$OUT/build.log" 2>&1
BIN="$SNAP/imagery-d/$ROOT/m3-rgba-layer-compositing-consumer"
test -x "$BIN" || {
    echo "ERROR: executable not found: $BIN" >&2
    exit 1
}
if [[ "$MODE" == smoke ]]; then
    w=192; h=192; rounds=2; iterations=2
    patterns=(mixed)
    meanings=(encoded-straight linear-pm)
    layouts=(interleaved planar)
    sides=(16 64)
else
    w=512; h=512; rounds=7; iterations=24
    patterns=(mixed transparent)
    meanings=(encoded-straight linear-pm)
    layouts=(interleaved planar)
    sides=(16 32 64 128 256)
fi
for meaning in "${meanings[@]}"; do
    for pattern in "${patterns[@]}"; do
        for layout in "${layouts[@]}"; do
            for side in "${sides[@]}"; do
                key="${w}x${h}-${meaning}-${pattern}-${layout}-square${side}"
                echo "Running $key" >&2
                if /usr/bin/time -v -o "$OUT/$key-resource.txt" \
                    "$BIN" --owned-fused-bench "--meaning=$meaning" \
                        --width="$w" --height="$h" --side="$side" \
                        --rounds="$rounds" --iterations="$iterations" \
                        "--pattern=$pattern" "--layout=$layout" \
                    > "$OUT/$key.csv" 2> "$OUT/$key-stderr.log"; then
                    :
                else
                    code=$?
                    echo "ERROR: benchmark executable failed: $key (exit $code)" >&2
                    tail -n 35 "$OUT/$key-stderr.log" >&2 || true
                    tail -n 15 "$OUT/$key.csv" >&2 || true
                    exit "$code"
                fi
                if ! grep -q '^M3 FUSED OWNED BENCH PASS:' "$OUT/$key.csv"; then
                    echo "ERROR: missing pixel-oracle PASS trailer: $key" >&2
                    tail -n 20 "$OUT/$key.csv" >&2 || true
                    exit 1
                fi
                n="$(grep -Ec '^(encoded-straight|linear-pm),(mixed|transparent),(planar|interleaved),square[0-9]+,' "$OUT/$key.csv" || true)"
                if [[ "$n" != "$((3 * rounds))" ]]; then
                    echo "ERROR: unexpected stage count for $key: $n" >&2
                    tail -n 20 "$OUT/$key.csv" >&2 || true
                    exit 1
                fi
                if [[ -s "$OUT/$key-stderr.log" ]]; then
                    echo "ERROR: nonempty benchmark stderr: $key" >&2
                    tail -n 35 "$OUT/$key-stderr.log" >&2 || true
                    exit 1
                fi
            done
        done
    done
done

# Retain executable byte identity in uploaded evidence, unlike earlier
# source-only captured archives with omitted compiled research binaries.
cp -- "$BIN" "$OUT/m3-fused-owned-consumer"
(
    cd "$OUT"
    sha256sum ./*.csv environment.txt build.log m3-fused-owned-consumer \
        > CHECKSUMS.sha256
    sha256sum -c CHECKSUMS.sha256
)
# Never create a .csv before validation finishes. A failed analysis
# leaves the raw hashed evidence untouched and the previous summary absent.
COMPARISON_TMP="$OUT/FUSED_COMPARISON.csv.tmp"
COMPARISON="$OUT/FUSED_COMPARISON.csv"
if [[ -e "$COMPARISON_TMP" || -e "$COMPARISON" ]]; then
    echo "ERROR: derived comparison already exists: $OUT" >&2
    exit 1
fi
python3 "$SNAP/imagery-d/tools/research/summarize_m3_rgba_fused_xps.py" \
    "$OUT" > "$COMPARISON_TMP"
test -s "$COMPARISON_TMP"
mv -- "$COMPARISON_TMP" "$COMPARISON"
echo "M3 FUSED OWNED XPS PASS: $OUT"
echo "To archive immutable original CSVs and derived summary (exclude snapshot):"
echo "tar --exclude='./snapshot' -czf \"\$HOME/Downloads/m3-fused-$(date -u +%Y%m%dT%H%M%SZ).tar.gz\" -C '$OUT' ."
