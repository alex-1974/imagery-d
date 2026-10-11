#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGERY_ROOT="$(cd "$ROOT/../.." && pwd)"

if [[ -n "${COMPILERS:-}" ]]; then
    read -r -a compilers <<< "$COMPILERS"
else
    compilers=(dmd ldc2)
fi

for compiler in "${compilers[@]}"; do
    if ! command -v "$compiler" >/dev/null 2>&1; then
        echo "FAIL: required compiler unavailable: $compiler" >&2
        exit 1
    fi

    echo "=== M3.2 synthetic semantics: $compiler ==="
    dub run --root="$ROOT" --compiler="$compiler" --build=debug --force

    echo "=== M3.2 optimized/release semantic smoke: $compiler ==="
    dub run --root="$ROOT" --compiler="$compiler" --build=release --force

    echo "=== M1.5 @safe lifetime negatives: $compiler ==="
    COMPILERS="$compiler" \
        bash "$IMAGERY_ROOT/experiments/m1_5_image_view_contract/tools/run.sh"
done

echo 'PASS: M3.2 positive + M1.5 lifetime negative gates'
