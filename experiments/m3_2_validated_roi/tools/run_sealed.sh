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
        case "$config" in
            negative-sealed-direct-kernel)
                # DMD hides a private declaration from the external
                # module symbol table. This probe explicitly qualifies
                # the right symbol and module, so a failure there is
                # a real privacy denial, not a missing dependency.
                pattern='app\.d\([0-9]+,[0-9]+\): Error:.*(undefined identifier .researchExecuteCheckedPixels. in module .m3_2_channel_metadata\.contract.|researchExecuteCheckedPixels.*(private|inaccessible|not accessible|cannot access|not visible))'
                ;;
            negative-sealed-forged-execution)
                pattern='app\.d\([0-9]+,[0-9]+\): Error:.*(private|inaccessible|not accessible|cannot access|protection|not visible)'
                ;;
        esac
        if ! grep -Ei "$pattern" "$log" >/dev/null; then
            cat "$log" >&2
            echo "FAIL: expected exact privacy denial absent: $config" >&2
            rm -f "$log"
            exit 1
        fi
        grep -Ei "$pattern" "$log" | head -3
        rm -f "$log"
        echo "PASS: $compiler $config rejected by access controls"
    done
done
echo "PASS: sealed execution visibility gates"
