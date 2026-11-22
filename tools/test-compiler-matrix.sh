#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
matrix_dub="${MATRIX_DUB:-dub-dlang-baseline}"
compilers=("$@")
if (( ${#compilers[@]} == 0 )); then
    compilers=(dmd-2.111.0 dmd-2.112.1 dmd-2.113.0 ldc-1.41.0 ldc-1.42.0 ldc-1.43.0)
fi
"$matrix_dub" --version
for compiler in "${compilers[@]}"; do
    command -v "$compiler"
    "$compiler" --version
    for configuration in no-io default; do
        "$matrix_dub" test --root="$repo_root" --config="$configuration" --compiler="$compiler"
    done
done
