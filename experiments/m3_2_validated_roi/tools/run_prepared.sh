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
    command -v "$compiler" >/dev/null || exit 2
    for profile in debug release; do
        echo "=== M3.2.9 prepared positive $compiler / $profile ==="
        dub run --root="$ROOT" --compiler="$compiler" \
            --config=default --build="$profile" --force -- --prepared-smoke
    done
    for kind in negative-prepared-owner-escape negative-prepared-metadata-escape negative-prepared-forgery; do
        log="$(mktemp)"
        if dub build --root="$ROOT" --compiler="$compiler" \
            --config="$kind" --build=debug --force >"$log" 2>&1
        then
            cat "$log" >&2
            rm -f "$log"
            echo "FAIL: $kind unexpectedly compiled" >&2
            exit 1
        fi
        case "$kind" in
            negative-prepared-owner-escape)
                expression='m3_2_verified_roi/contract\.d\([0-9]+,[0-9]+\): Error: (escaping|returning scope|returning .* escapes|assigning address)' ;;
            negative-prepared-metadata-escape)
                expression='m3_2_verified_roi/contract\.d\([0-9]+,[0-9]+\): Error: (escaping|returning scope|returning .* escapes|assigning address)' ;;
            negative-prepared-forgery)
                expression='source/app\.d\([0-9]+,[0-9]+\): Error:.*(private|inaccessible|cannot access|not accessible|constructor)' ;;
        esac
        if ! grep -Eq "$expression" "$log"; then
            cat "$log" >&2
            rm -f "$log"
            echo "FAIL: rejection not from the expected safety contract" >&2
            exit 1
        fi
        tail -n 8 "$log"
        rm -f "$log"
        echo "PASS: $kind"
    done
done

echo "PASS: M3.2.9 prepared mapping contract and negative gates"
