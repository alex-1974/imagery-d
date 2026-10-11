#!/usr/bin/env bash
# M3.2.11 outside-module access and positional-construction probes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${COMPILERS:-}" ]]; then
    read -r -a compilers <<< "$COMPILERS"
else
    compilers=(dmd ldc2)
fi
for compiler in "${compilers[@]}"; do
    command -v "$compiler" >/dev/null
    for config in negative-sealed-direct-kernel negative-sealed-forged-execution; do
        log="$(mktemp)"
        if dub build --root="$ROOT" --compiler="$compiler" \
            --config="$config" --build=debug --force >"$log" 2>&1; then
            cat "$log" >&2
            echo "FAIL: external access unexpectedly compiled: $config" >&2
            rm -f "$log"
            exit 1
        fi
        # A syntax error, broken dependency or missing module is *not*
        # evidence of D visibility/constructor enforcement.
        if ! grep -Ei 'source/app\.d\([0-9]+,[0-9]+\): Error:.*(private|inaccessible|not accessible|cannot access|protection|not visible)' "$log" >/dev/null; then
            cat "$log" >&2
            echo "FAIL: expected outside-module privacy error absent: $config" >&2
            rm -f "$log"
            exit 1
        fi
        grep -Ei 'source/app\.d\([0-9]+,[0-9]+\): Error:.*(private|inaccessible|not accessible|cannot access|protection|not visible)' "$log" | head -3
        rm -f "$log"
        echo "PASS: $compiler $config rejected by access controls"
    done
done
echo "PASS: sealed execution visibility gates"
