#!/usr/bin/env bash
# Research-only transport of a completed M3 owned-result XPS measurement.
# Does not run benchmarks, alter any original file, or write sibling repos.
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    echo 'Usage: archive_m3_rgba_owned_xps.sh OUTPUT_DIR m3-owned-library|m3-owned-library-thinlto' >&2
    exit 2
fi
ROOT="$(cd -- "$1" && pwd)"
KIND="$2"
case "$KIND" in
    m3-owned-library|m3-owned-library-thinlto) ;;
    *) echo "ERROR: invalid archive kind: $KIND" >&2; exit 2 ;;
esac
ID="$(basename -- "$ROOT")"
if [[ ! "$ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "ERROR: unsafe measurement directory name: $ID" >&2
    exit 2
fi
for name in CHECKSUMS.sha256 LIBRARY_COMPARISON.csv environment.txt build.log m3-owned-library-consumer; do
    test -f "$ROOT/$name" || {
        echo "ERROR: cannot export incomplete XPS run: missing $name" >&2
        exit 1
    }
done
if [[ "$KIND" == m3-owned-library-thinlto ]]; then
    test -s "$ROOT/CODEGEN_CALLS.json" || {
        echo 'ERROR: missing ThinLTO codegen receipt' >&2
        exit 1
    }
fi
# Revalidate original committed-source measurements before transport.
(cd "$ROOT" && sha256sum -c CHECKSUMS.sha256 >/dev/null)

DOWNLOADS="$HOME/Downloads"
mkdir -p -- "$DOWNLOADS"
TARGET="$DOWNLOADS/$KIND-$ID.tar.gz"
if [[ -e "$TARGET" ]]; then
    echo "ERROR: refusing to overwrite original XPS archive: $TARGET" >&2
    exit 1
fi
TMP="$(mktemp "$DOWNLOADS/.$KIND-$ID.XXXXXXXX.tar.gz.tmp")"
trap 'rm -f -- "$TMP"' EXIT

# The repo snapshot is redundant for exchange; the original executable,
# raw CSVs, build/environment records, hashes and source SHA remain included.
tar --exclude='./snapshot' -czf "$TMP" -C "$ROOT" .

# Check bytes INSIDE the newly produced transport archive, not only disk.
python3 - "$TMP" "$KIND" <<'PY'
import hashlib
import json
import sys
import tarfile

with tarfile.open(sys.argv[1], "r:gz") as archive:
    members = {}
    for entry in archive:
        name = entry.name.removeprefix("./")
        if not name or name == "." or entry.isdir():
            continue
        if (not entry.isfile() or name.startswith("/")
                or ".." in name.split("/") or name in members):
            raise SystemExit("ERROR: unsafe/duplicate XPS archive entry: " + name)
        members[name] = entry
    if any(name == "snapshot" or name.startswith("snapshot/")
           for name in members):
        raise SystemExit("ERROR: repository snapshot included in transport")
    if "CHECKSUMS.sha256" not in members:
        raise SystemExit("ERROR: missing archived checksum manifest")
    text = archive.extractfile(members["CHECKSUMS.sha256"]).read().decode()
    originals = {}
    for line in text.splitlines():
        digest, name = line.split(maxsplit=1)
        name = name.lstrip("*").removeprefix("./")
        if name in originals or "/" in name or len(digest) != 64:
            raise SystemExit("ERROR: malformed original checksum manifest")
        originals[name] = digest
    if "environment.txt" not in members:
        raise SystemExit("ERROR: missing measured environment")
    env = archive.extractfile(members["environment.txt"]).read().decode()
    parsed = dict(line.split("=", 1) for line in env.splitlines()
                  if "=" in line)
    mode = parsed.get("mode")
    if mode not in ("micro", "smoke"):
        raise SystemExit("ERROR: unknown XPS mode")
    thin = sys.argv[2].endswith("-thinlto")
    if thin != (parsed.get("optimization_mode") == "thin-lto"):
        raise SystemExit("ERROR: archive label does not match compiler mode")
    expected = (40 if mode == "micro" else 8) + (4 if thin else 3)
    if len(originals) != expected:
        raise SystemExit("ERROR: unexpected count of original manifest entries")
    for name, digest in originals.items():
        if name not in members:
            raise SystemExit("ERROR: missing original measurement: " + name)
        found = hashlib.sha256(
            archive.extractfile(members[name]).read()).hexdigest()
        if found != digest:
            raise SystemExit("ERROR: changed original measurement: " + name)
    if sys.argv[2].endswith("-thinlto"):
        report = json.load(archive.extractfile(members["CODEGEN_CALLS.json"]))
        executable = archive.extractfile(
            members["m3-owned-library-consumer"]).read()
        if report["binary_sha256"] != hashlib.sha256(executable).hexdigest():
            raise SystemExit("ERROR: codegen receipt does not match executable")
    print("M3 OWNED ARCHIVE MANIFEST PASS:", len(originals), "/", len(originals))
PY

# Atomic no-clobber publication on the Downloads filesystem.
ln -- "$TMP" "$TARGET"
rm -f -- "$TMP"
trap - EXIT
echo "M3 OWNED XPS ARCHIVE PASS: $TARGET"
sha256sum -- "$TARGET"
