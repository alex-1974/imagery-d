#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -n "${COMPILERS:-}" ]]; then
    read -r -a compilers <<< "$COMPILERS"
else
    compilers=(dmd ldc2)
fi

negatives=(
    negative-owner-escape
    negative-roi-escape
    negative-metadata-access-escape
)

for compiler in "${compilers[@]}"; do
    command -v "$compiler" >/dev/null 2>&1 || {
        echo "FAIL: compiler unavailable: $compiler" >&2
        exit 1
    }

    for mode in debug release; do
        echo "=== M3.2.4 positive: $compiler / $mode ==="
        dub run --root="$ROOT" --compiler="$compiler" \
            --config=default --build="$mode" --force
    done

    for negative in "${negatives[@]}"; do
        echo "=== M3.2.4 negative: $compiler / $negative ==="
        log="$(mktemp)"
        if dub build --root="$ROOT" --compiler="$compiler" \
            --config="$negative" --build=debug --force >"$log" 2>&1
        then
            cat "$log"
            rm -f "$log"
            echo "FAIL: negative lifetime probe unexpectedly compiled" >&2
            exit 1
        fi

        tail -n 16 "$log"
        # The expected compiler diagnostic must originate from this
        # contract and explicitly describe escaping lifetime/scope data.
        if ! grep -Eq 'm3_2_dynamic_metadata/contract\.d\([0-9]+,[0-9]+\): Error: (escaping|returning scope|assigning address|returning .* escapes)' "$log"; then
            echo "FAIL: negative build lacks matching borrow-escape diagnostic" >&2
            cat "$log" >&2
            rm -f "$log"
            exit 1
        fi
        rm -f "$log"
        echo "PASS: rejected dynamic metadata borrow $negative"
    done
done

echo 'PASS: M3.2.4 immutable snapshot, move, ROI and lifetime probes'
