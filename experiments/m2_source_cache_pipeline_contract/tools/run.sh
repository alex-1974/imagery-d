#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ -n "${COMPILERS:-}" ]; then
    # shellcheck disable=SC2086
    compilers="$COMPILERS"
else
    compilers="dmd ldc2"
fi

echo '=== M2 SOURCE / CACHE / PIPELINE CONTRACT ==='
printf 'root: %s\n' "$ROOT"
echo

for compiler in $compilers
do
    if ! command -v "$compiler" >/dev/null 2>&1; then
        echo "FAIL: required compiler not found: $compiler" >&2
        exit 1
    fi

    echo "=== RUN: $compiler ==="

    dub run \
        --root="$ROOT" \
        --compiler="$compiler"

    echo "PASS: M2 contract ($compiler)"
    echo
done

echo '=== RESULT ==='
echo 'PASS: semantic production-key boundaries.'
echo 'PASS: equal-key single-flight.'
echo 'PASS: subscriber cancellation/publication semantics.'
echo 'PASS: cache eviction preserves delivered RasterLease lifetime.'
echo 'PASS: covering logical region serves exact ROI without rematerialization.'
echo 'PASS: execution strategies preserve semantic key and exact output.'
