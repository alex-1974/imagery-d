#!/usr/bin/env bash
# Non-destructive replay of EXISTING pinned 2026-10-15 XPS preflight timings.
# Reads/checks original raw CSVs, build and measured consumer bytes.
# Creates ONLY new, separately hashed analysis artifacts; never times again.
set -euo pipefail

if [[ "$#" != 1 ]]; then
    echo "Usage: bash tools/research/replay_m3_rgba_owned_preflight_xps.sh EXISTING_DATA_DIR" >&2
    exit 2
fi
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$(cd -- "$1" && pwd)"
VALIDATOR="$REPO/tools/research/summarize_m3_rgba_owned_preflight_xps.py"

for name in CHECKSUMS.sha256 environment.txt build.log m3-owned-preflight-consumer; do
    test -f "$OUT/$name" || { echo "ERROR: missing original evidence: $name" >&2; exit 1; }
done
for target in PREFLIGHT_COMPARISON.csv ANALYSIS_PROVENANCE.txt ANALYSIS_CHECKSUMS.sha256; do
    test ! -e "$OUT/$target" || {
        echo "ERROR: refusing to overwrite existing derived artifact: $OUT/$target" >&2
        exit 1
    }
done
MEASURED="$(sed -n 's/^imagery_measured_commit=//p' "$OUT/environment.txt")"
if [[ ! "$MEASURED" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: absent/invalid exact original measured Git SHA" >&2
    exit 1
fi
ANALYSIS="$(git -C "$REPO" rev-parse HEAD)"
if [[ ! "$ANALYSIS" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: invalid analysis Git SHA" >&2
    exit 1
fi
echo "Original source: $MEASURED"
echo "Analysis source: $ANALYSIS"

# Fail fast on the corrected parser's own real-trailer & tamper tests.
python3 -B "$VALIDATOR" --self-test

# Independently replay the unchanged original recorded byte manifest.
(
    cd "$OUT"
    sha256sum -c CHECKSUMS.sha256
)

# Leave a stale *.tmp from the *old failing runner* untouched.
TMP="$(mktemp "$OUT/.replay-summary.XXXXXXXX")"
trap 'rm -f -- "$TMP"' EXIT
python3 -B "$VALIDATOR" "$OUT" > "$TMP"
test -s "$TMP"
test "$(wc -l < "$TMP")" -eq 41 || {
    echo "ERROR: summary must have one header plus 40 cases" >&2
    exit 1
}
grep -q '^meaning,pattern,layout,roi,pixels,rounds,iterations,' "$TMP" || {
    echo "ERROR: invalid derived summary header" >&2
    exit 1
}
mv -- "$TMP" "$OUT/PREFLIGHT_COMPARISON.csv"
{
    printf 'measured_commit=%s\n' "$MEASURED"
    printf 'analysis_commit=%s\n' "$ANALYSIS"
    printf 'analysis_validator_sha256=%s\n' "$(sha256sum "$VALIDATOR" | cut -d' ' -f1)"
    printf 'original_manifest_sha256=%s\n' "$(sha256sum "$OUT/CHECKSUMS.sha256" | cut -d' ' -f1)"
    printf 'source_mode=unmodified-raw-XPS-replay\n'
} > "$OUT/ANALYSIS_PROVENANCE.txt"
(
    cd "$OUT"
    sha256sum PREFLIGHT_COMPARISON.csv ANALYSIS_PROVENANCE.txt \
        > ANALYSIS_CHECKSUMS.sha256
    sha256sum -c ANALYSIS_CHECKSUMS.sha256
)
echo "M3 OWNED PREFLIGHT REPLAY PASS: 40 cases, original bytes untouched"
echo "Original evidence directory: $OUT"
