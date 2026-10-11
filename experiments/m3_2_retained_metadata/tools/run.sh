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
    negative-intrinsic-escape
    negative-primary-escape
    negative-validity-escape
    negative-owner-escape
    negative-roi-escape
)

for compiler in "${compilers[@]}"; do
    command -v "$compiler" >/dev/null 2>&1 || {
        echo "FAIL: missing compiler $compiler" >&2
        exit 1
    }

    echo "=== M3.2.3 positive debug: $compiler ==="
    dub run --root="$ROOT" --compiler="$compiler" \
        --config=default --build=debug --force
    echo "=== M3.2.3 positive release: $compiler ==="
    dub run --root="$ROOT" --compiler="$compiler" \
        --config=default --build=release --force

    for negative in "${negatives[@]}"; do
        echo "=== M3.2.3 negative: $compiler / $negative ==="
        logfile="$(mktemp)"
        if dub build --root="$ROOT" --compiler="$compiler" \
            --config="$negative" --build=debug --force \
            >"$logfile" 2>&1
        then
            cat "$logfile"
            rm -f "$logfile"
            echo "FAIL: escaped borrow compiled: $negative" >&2
            exit 1
        fi
        tail -n 22 "$logfile"
        # A generic dependency/syntax failure is not proof of lifetime safety.
        # Diagnostics are retained for human review on every CI run.
        # Require a real DIP1000 escape error from *this* contract; a
        # missing dependency or unrelated syntax error is not a PASS.
        if ! grep -Eq 'contract\\.d\\([0-9]+,[0-9]+\\): Error: (escaping|returning scope|assigning address|returning .* escapes)' "$logfile"; then
            echo "FAIL: negative build did not prove a borrow escape" >&2
            cat "$logfile" >&2
            rm -f "$logfile"
            exit 1
        fi
        rm -f "$logfile"
        echo "PASS: rejected negative borrow $negative"
    done
done

echo "PASS: M3.2.3 retained borrow, ROI and negative compile gates"
