#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -n "${COMPILERS:-}" ]]; then
    read -r -a compilers <<< "$COMPILERS"
else
    compilers=(dmd ldc2)
fi

negative_configs=(
    negative-primary-escape
    negative-metadata-escape
    negative-validity-escape
    negative-roi-escape
)

echo '=== M1.5 IMAGE VIEW CONTRACT ==='
printf 'root: %s\n' "$ROOT"
echo

for compiler in "${compilers[@]}"; do
    if ! command -v "$compiler" >/dev/null 2>&1; then
        echo "FAIL: required compiler not found: $compiler" >&2
        exit 1
    fi

    echo "=== POSITIVE: $compiler ==="

    dub run \
        --root="$ROOT" \
        --compiler="$compiler" \
        --config=default

    echo "PASS: positive contract ($compiler)"
    echo

    for config in "${negative_configs[@]}"; do
        echo "=== NEGATIVE: $compiler / $config ==="

        log="$(mktemp)"

        if dub build \
            --root="$ROOT" \
            --compiler="$compiler" \
            --config="$config" \
            >"$log" 2>&1
        then
            cat "$log"
            rm -f "$log"

            echo \
                "FAIL: compile-negative probe unexpectedly compiled: " \
                "$compiler / $config" \
                >&2

            exit 1
        fi

        tail -n 20 "$log"
        rm -f "$log"

        echo "PASS: rejected as expected ($compiler / $config)"
        echo
    done
done

echo '=== RESULT ==='
echo 'PASS: positive runtime/ROI checks succeeded.'
echo 'PASS: all lifetime escape probes were rejected by all compilers.'
