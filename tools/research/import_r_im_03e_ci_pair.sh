#!/usr/bin/env bash
# R-IM-03e: import verified CI-built D pair into an isolated XPS pilot folder.
# No compilation, image workload, sudo, repo mutations, or process changes.
# Usage: bash import_r_im_03e_ci_pair.sh /absolute/new/output /absolute/unpacked/CI/artifact
set -euo pipefail
export LC_ALL=C

BASE=68ddbdefc5b9cfefd95fe8545ba4848fc5736beb
CAND=ae36974af9369d7bbdbbecf9b8619d2da52e59be
RASTER=2f2415851e45001df92ce56dad409f680684ba8d
OUT="$1"
BUNDLE="$2"

[[ "$OUT" == /* && "$BUNDLE" == /* && "$OUT" != / && "$OUT" != "$HOME" ]] || {
  echo 'ERROR: require separate absolute output and unpacked bundle paths' >&2; exit 2;
}
for cmd in python3 sha256sum readelf realpath install; do
  command -v "$cmd" >/dev/null || { echo "ERROR: missing $cmd" >&2; exit 2; }
done
OUT="$(realpath -m -- "$OUT")"
BUNDLE="$(realpath -- "$BUNDLE")"
[[ "$OUT" != *'/d-geospatial-workspace/'* && "$OUT" != "$BUNDLE" ]] || {
  echo 'ERROR: output must be outside the workspace and bundle directory' >&2; exit 2;
}
[[ ! -e "$OUT" ]] || {
  echo 'ERROR: output directory already exists; preserve existing evidence' >&2; exit 2;
}
[[ -d "$BUNDLE" ]] || { echo 'ERROR: missing unpacked CI artifact directory' >&2; exit 3; }

# Deliberately validate the manifest and exact provenance BEFORE creating OUT.
# Refuse extra manifest records, path traversal, duplicates and non-ELF inputs.
python3 - "$BUNDLE" "$BASE" "$CAND" "$RASTER" <<'PY'
import hashlib, pathlib, re, sys
directory=pathlib.Path(sys.argv[1])
wanted={"baseline","candidate"}
manifest=(directory/"SHA256SUMS")
if manifest.is_symlink() or not manifest.is_file():
    sys.exit("ERROR: missing regular SHA256SUMS")
lines=manifest.read_text().splitlines()
seen=set()
if len(lines)!=2: sys.exit("ERROR: manifest must contain exactly two executables")
for line in lines:
    match=re.fullmatch(r"([0-9a-f]{64})  (baseline|candidate)",line)
    if not match: sys.exit("ERROR: malformed SHA256SUMS")
    digest,name=match.groups()
    if name in seen: sys.exit("ERROR: duplicate binary in SHA256SUMS")
    seen.add(name)
    path=directory/name
    if path.is_symlink() or not path.is_file(): sys.exit("ERROR: nonregular prebuilt binary")
    if hashlib.sha256(path.read_bytes()).hexdigest()!=digest:
        sys.exit("ERROR: binary digest mismatch: "+name)
    with path.open("rb") as f:
        if f.read(4)!=b"\x7fELF": sys.exit("ERROR: binary is not an ELF executable")
if seen!=wanted: sys.exit("ERROR: incomplete binary manifest")
log=directory/"provenance.log"
if log.is_symlink() or not log.is_file():
    sys.exit("ERROR: provenance.log missing")
text=log.read_text()
required=[
    "RIM03E_BASE_SHA="+sys.argv[2],
    "RIM03E_CAND_SHA="+sys.argv[3],
    "RIM03E_RASTER_SHA="+sys.argv[4],
    "RIM03E_BUILD_DONE,baseline",
    "RIM03E_BUILD_DONE,candidate",
    "RIM03E_TIMING_VERDICT=none",
]
if not all(line in text.splitlines() or line=="RIM03E_TIMING_VERDICT=none" and
           "RIM03E_TIMING_VERDICT=none" in text for line in required):
    sys.exit("ERROR: provenance pins or build receipts missing")
if "LDC - the LLVM D compiler (1.41.0):" not in text:
    sys.exit("ERROR: pair must have been built with LDC 1.41.0")
print("RIM03E_PREBUILT_MANIFEST_AND_PINS=PASS")
PY

for name in baseline candidate; do
  arch="$(readelf -h "$BUNDLE/$name" | awk '/Machine:/{print $2}')"
  [[ "$arch" == Advanced ]] || {
    echo "ERROR: binary architecture not ELF x86-64: $name" >&2; exit 3;
  }
done

mkdir -p "$OUT"
cp -- "$BUNDLE/provenance.log" "$OUT/ci-provenance.log"
cp -- "$BUNDLE/SHA256SUMS" "$OUT/ci-SHA256SUMS"
{
  echo "RIM03E_PINS base=$BASE candidate=$CAND raster=$RASTER compiler=CI_LDC_1.41.0"
  echo "RIM03E_ORIGIN=GitHub Actions prebuilt D pair; no XPS compilation"
  echo "RIM03E_IMPORT_TIME_UTC=$(date -u +%FT%TZ)"
  echo "RIM03E_SOURCE_BUNDLE=$BUNDLE"
} > "$OUT/receipt.log"
for name in baseline candidate; do
  exe="$OUT/build/pair/$name/experiments/r_im_03a_levels/bench_03c/r-im-03c-levels-math-benchmark"
  mkdir -p "$(dirname "$exe")"
  install -m 0755 "$BUNDLE/$name" "$exe"
  sha256sum "$exe" > "$OUT/$name.sha256"
done
printf 'RIM03E_PREPARED=%s:%s:%s\n' "$BASE" "$CAND" "$RASTER" > "$OUT/prepared.ok"
echo "RIM03E_PREBUILT_IMPORT_OK=$OUT"
echo 'RIM03E_CAVEAT=hosted Ubuntu binary ABI and D runtime must be checked before executing XPS pilot'
