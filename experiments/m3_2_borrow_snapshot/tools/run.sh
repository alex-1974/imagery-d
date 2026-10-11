#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -n "${COMPILERS:-}" ]]; then
    read -r -a compilers <<< "$COMPILERS"
else
    compilers=(dmd ldc2)
fi

for compiler in "${compilers[@]}"; do
    command -v "$compiler" >/dev/null 2>&1 || {
        echo "FAIL: missing compiler $compiler" >&2
        exit 1
    }

    for build in debug release; do
        echo "=== M3.2.5 correctness $compiler / $build ==="
        dub run --root="$ROOT" --compiler="$compiler" \
            --config=default --build="$build" --force
    done

    log="$(mktemp)"
    echo "=== M3.2.5 negative caller-metadata escape $compiler ==="
    if dub build --root="$ROOT" --compiler="$compiler" \
        --config=negative-caller-metadata-escape \
        --build=debug --force >"$log" 2>&1
    then
        cat "$log" >&2
        rm -f "$log"
        echo "FAIL: stack metadata escape unexpectedly compiled" >&2
        exit 1
    fi

    tail -n 12 "$log"
    if ! grep -Eq 'source/app\.d\([0-9]+,[0-9]+\): Error: (escaping|returning scope|assigning address|returning .* escapes)' "$log"; then
        cat "$log" >&2
        rm -f "$log"
        echo "FAIL: negative was not a scope/borrow compiler rejection" >&2
        exit 1
    fi
    rm -f "$log"
    echo "PASS: caller-backed metadata scope escape rejected"
done

echo "PASS: M3.2.5 DMD/LDC debug/release and borrow escape gates"

if [[ "${RUN_BENCHMARK:-0}" == "1" ]]; then
    compiler="${BENCHMARK_COMPILER:-ldc2}"
    echo "=== M3.2.5 advisory benchmark $compiler ==="
    dub run --root="$ROOT" --compiler="$compiler" \
        --config=default --build=release --force -- --benchmark
fi
