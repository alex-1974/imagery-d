#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

run_one()
{
    local compiler="$1"
    shift

    echo
    echo "=== $compiler $* ==="
    "$compiler" --version
    dub-dlang-baseline run --compiler="$compiler" --force "$@"
}

run_one dmd-2.113.0
run_one ldc-1.43.0 --build=release
