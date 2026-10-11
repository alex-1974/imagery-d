#!/usr/bin/env bash
# M3.2.12 outside-module verified token construction prohibition.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${COMPILERS:-}" ]]; then
    read -r -a compilers <<< "$COMPILERS"
else
    compilers=(dmd ldc2)
fi

for compiler in "${compilers[@]}"; do
    log="$(mktemp)"
    if dub build --root="$ROOT" --compiler="$compiler" \
        --config=negative-unified-verified-forgery \
        --build=debug --force >"$log" 2>&1; then
        cat "$log" >&2
        echo "FAIL: unchecked verified token unexpectedly compiled" >&2
        rm -f "$log"
        exit 1
    fi
    if ! grep -Eiq 'app\.d\([0-9]+,[0-9]+\): Error:.*(ResearchVerifiedSemanticImage.*(private|inaccessible|not accessible|cannot access)|(private|inaccessible|not accessible|cannot access).*ResearchVerifiedSemanticImage)' "$log"; then
        cat "$log" >&2
        echo "FAIL: no exact verified-token constructor visibility error" >&2
        rm -f "$log"
        exit 1
    fi
    grep -Ei 'app\.d\([0-9]+,[0-9]+\): Error:.*(private|inaccessible|not accessible|cannot access)' "$log" | head -2
    rm -f "$log"
    echo "PASS: $compiler prevents forging unified verified semantic token"
done
echo "PASS: M3.2.12 external construction gates"
