#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -n "${COMPILERS:-}" ]]; then
    read -r -a compilers <<< "$COMPILERS"
else
    compilers=(dmd ldc2)
fi

lifetime_negatives=(
    negative-primary-escape
    negative-validity-escape
    negative-metadata-escape
    negative-roi-escape
)

for compiler in "${compilers[@]}"; do
    command -v "$compiler" >/dev/null 2>&1 || {
        echo "FAIL: required D compiler unavailable: $compiler" >&2
        exit 1
    }

    for build in debug release; do
        echo "=== M3.2.6 positive $compiler / $build ==="
        dub run --root="$ROOT" --compiler="$compiler" \
            --config=default --build="$build" --force
    done

    for negative in "${lifetime_negatives[@]}"; do
        log="$(mktemp)"
        echo "=== M3.2.6 expected lifetime rejection $compiler / $negative ==="
        if dub build --root="$ROOT" --compiler="$compiler" \
            --config="$negative" --build=debug --force \
            >"$log" 2>&1
        then
            cat "$log" >&2
            rm -f "$log"
            echo "FAIL: invalid borrow unexpectedly compiled" >&2
            exit 1
        fi
        if ! grep -Eq 'm3_2_verified_roi/contract\.d\([0-9]+,[0-9]+\): Error: (escaping|returning scope|assigning address|returning .* escapes)' "$log"; then
            cat "$log" >&2
            rm -f "$log"
            echo "FAIL: no true DIP1000 escape diagnostic" >&2
            exit 1
        fi
        tail -n 7 "$log"
        rm -f "$log"
        echo "PASS: rejected scope escape $negative"
    done

    log="$(mktemp)"
    echo "=== M3.2.6 reject mutable metadata $compiler ==="
    if dub build --root="$ROOT" --compiler="$compiler" \
        --config=negative-mutable-metadata --build=debug \
        --force >"$log" 2>&1
    then
        cat "$log" >&2
        rm -f "$log"
        echo "FAIL: non-immutable metadata obtained fast capability" >&2
        exit 1
    fi
    if ! grep -Eiq 'm3_2_verified_roi/contract\.d\([0-9]+,[0-9]+\): Error:.*(immutable|implicitly convert|cannot convert|argument types|function.*called)' "$log"; then
        cat "$log" >&2
        rm -f "$log"
        echo "FAIL: mutable metadata was not rejected by type system" >&2
        exit 1
    fi
    tail -n 7 "$log"
    rm -f "$log"
    echo "PASS: const/mutable metadata cannot obtain immutable fast path"

    echo "=== M3.2.6 reject forged external verified state $compiler ==="
    log="$(mktemp)"
    if dub build --root="$ROOT" --compiler="$compiler" \
        --config=negative-forged-capability --build=debug \
        --force >"$log" 2>&1
    then
        cat "$log" >&2
        rm -f "$log"
        echo "FAIL: an unvalidated image could fake the capability" >&2
        exit 1
    fi
    if ! grep -Eiq 'source/app\.d\([0-9]+,[0-9]+\): Error:.*(private|inaccessible|cannot access|not accessible|constructor)' "$log"; then
        cat "$log" >&2
        rm -f "$log"
        echo "FAIL: forged capability test did not fail for access control" >&2
        exit 1
    fi
    tail -n 7 "$log"
    rm -f "$log"
    echo "PASS: external code cannot forge validated marker"
done

echo "PASS: M3.2.6 correctness + lifetime + immutable gate"

if [[ "${RUN_BENCHMARK:-0}" == "1" ]]; then
    compiler="${BENCHMARK_COMPILER:-ldc2}"
    echo "=== M3.2.6 non-gating elapsed time: $compiler ==="
    dub run --root="$ROOT" --compiler="$compiler" \
        --config=default --build=release --force -- --benchmark
fi
