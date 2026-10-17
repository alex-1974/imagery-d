#!/usr/bin/env bash
# Recover a completed native owned-result XPS session from its immutable raw
# CSVs. Does NOT rerun, recompile, reset, clean, or touch sibling repositories.
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "Usage: $0 EXISTING-MICRO-OUTPUT-DIRECTORY" >&2
    exit 2
fi
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$(realpath -e -- "$1")"
case "$OUT" in
    "$REPO/data/m3-rgba-owned-xps/"*) ;;
    *)
        echo "ERROR: directory must be within imagery-d/data/m3-rgba-owned-xps" >&2
        exit 1
        ;;
esac
for file in environment.txt CHECKSUMS.sha256; do
    [[ -f "$OUT/$file" ]] || {
        echo "ERROR: missing $file" >&2
        exit 1
    }
done
grep -qx 'mode=micro' "$OUT/environment.txt" || {
    echo "ERROR: existing run is not a full native micro session" >&2
    exit 1
}
grep -qx 'source_mode=pinned-v0.2.0' "$OUT/environment.txt" || {
    echo "ERROR: source pinning missing" >&2
    exit 1
}
echo "=== Validate 20 original raw CSV SHA-256 files ==="
[[ "$(wc -l < "$OUT/CHECKSUMS.sha256")" -eq 20 ]] || {
    echo "ERROR: expected exactly 20 raw SHA-256 entries" >&2
    exit 1
}
(cd "$OUT" && sha256sum -c CHECKSUMS.sha256)

DEST="$OUT/OWNED_COMPARISON.csv"
BACKUP="$OUT/OWNED_COMPARISON.before-recovery.txt"
# The older runner left either an empty or header-only result on parser failure.
# Never replace an already finished or otherwise unrecognized comparison.
if [[ -e "$DEST" || -L "$DEST" ]]; then
    [[ ! -L "$DEST" && -f "$DEST" ]] || {
        echo "ERROR: derived comparison is not a regular file" >&2
        exit 1
    }
    python3 - "$DEST" <<'PY'
import csv
import pathlib
import sys
p = pathlib.Path(sys.argv[1])
with p.open(newline="") as f:
    rows = list(csv.reader(f))
if len(rows) > 1 or (rows and rows[0][:3] !=
                     ["pattern", "layout", "roi"]):
    raise SystemExit("ERROR: refusing to overwrite nontrivial prior summary")
PY
    [[ ! -e "$BACKUP" && ! -L "$BACKUP" ]] || {
        echo "ERROR: old summary backup already exists: $BACKUP" >&2
        exit 1
    }
fi

TMP="$(mktemp "$OUT/.owned-summary-recovery.XXXXXXXX")"
ARCHIVE_TMP=
trap 'rm -f -- "$TMP"; if [[ -n "$ARCHIVE_TMP" ]]; then rm -f -- "$ARCHIVE_TMP"; fi' EXIT
python3 "$REPO/tools/research/summarize_m3_rgba_owned_result_xps.py" \
    "$OUT" > "$TMP"

# Parser already validates raw hashes, stage keys and checksums; independently
# check that it really produced the full comparison matrix before publication.
python3 - "$TMP" <<'PY'
import csv
import pathlib
import sys
with pathlib.Path(sys.argv[1]).open(newline="") as f:
    rows = list(csv.DictReader(f))
required = {(p, l, f"square{s}")
            for p in ("mixed", "transparent")
            for l in ("planar", "interleaved")
            for s in (16, 32, 64, 128, 256)}
actual = {(r["pattern"], r["layout"], r["roi"]) for r in rows}
if len(rows) != 20 or actual != required:
    raise SystemExit("ERROR: recovered comparison must contain 20 unique cases")
if any(r["rounds"] != "7" or r["iterations"] != "24" for r in rows):
    raise SystemExit("ERROR: recovered comparison has wrong repetitions")
print("RECOVERED SUMMARY: 20/20 cases, 7 paired rounds per case")
PY

mkdir -p "$HOME/Downloads"
STAMP="$(basename "$OUT")"
ARCHIVE="$HOME/Downloads/${STAMP}-owned-recovered.tar.gz"
[[ ! -e "$ARCHIVE" && ! -L "$ARCHIVE" ]] || {
    echo "ERROR: archive exists; refusing to overwrite: $ARCHIVE" >&2
    exit 1
}
if [[ -e "$DEST" ]]; then
    cp -- "$DEST" "$BACKUP"
fi
mv -- "$TMP" "$DEST"
TMP=
# Make archive atomically in Downloads and publish only on successful tar.
ARCHIVE_TMP="$(mktemp "$HOME/Downloads/.m3-owned-archive.XXXXXXXX")"
tar --exclude='./snapshot' --exclude='./.owned-summary-recovery.*' \
    -czf "$ARCHIVE_TMP" -C "$OUT" .
mv -- "$ARCHIVE_TMP" "$ARCHIVE"
ARCHIVE_TMP=
echo "RECOVERY PASS: raw benchmark files retained unchanged"
echo "CSV=$DEST"
echo "ARCHIVE=$ARCHIVE"
sha256sum "$ARCHIVE"
head -n 5 "$DEST"
