#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
compiler="${DC:-dmd}"
probe_configuration="${API_PROBE_CONFIG:-default}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# DUB resolves the same actual dependency graph as an ordinary consumer.
dub describe --compiler="$compiler" --config="$probe_configuration" > "$tmp/describe.json"
mapfile -t include_paths < <(python3 - "$tmp/describe.json" <<'PY'
import json,pathlib,sys
d=json.loads(pathlib.Path(sys.argv[1]).read_text())
for package in d.get("packages", []):
    base=pathlib.Path(package["path"])
    for path in package.get("importPaths", []):
        print("-I="+str((base / path).resolve()))
PY
)
# DMD and LDC use compile-only -c; no linker errors can satisfy a
# rejected-source gate. The positive fixture ensures dependencies/flags work.
"$compiler" -c -preview=dip1000 "${include_paths[@]}" \
    -of="$tmp/positive.o" tests/api_contract/borrow_positive.d
"$compiler" -c -preview=dip1000 "${include_paths[@]}" \
    -of="$tmp/worker32.o" tests/api_contract/worker32_positive.d
"$compiler" -c -preview=dip1000 "${include_paths[@]}" \
    -of="$tmp/queue.o" tests/api_contract/queue_parameters_positive.d

for check in borrow_escape unsupported_double into_not_public destination_not_public worker32_mutable_result worker32_copy queue_clahe; do
    if "$compiler" -c -preview=dip1000 "${include_paths[@]}" \
        -of="$tmp/${check}.o" "tests/api_contract/${check}.d" \
        >"$tmp/${check}.out" 2>"$tmp/${check}.err"; then
        echo "ERROR: forbidden API/lifetime source unexpectedly compiled: $check" >&2
        exit 1
    fi
    if ! test -s "$tmp/${check}.err"; then
        echo "ERROR: missing compile diagnostic for $check" >&2
        exit 1
    fi
done
echo "M3_LEVELS_API_COMPILE=PASS; scoped worker/configured queue and @safe consumer plus 7 negative contracts"
