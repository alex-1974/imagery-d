#!/usr/bin/env bash
# Build identical sources with three code-generation settings. No timed work
# runs while these compilers/reference checks are active.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
artifacts="$(realpath -m "${1:?artifact directory required}")"
oracle_python="${ORACLE_PYTHON:-python3}"
mkdir -p "$artifacts"
for target in portable v3 native; do
    target_flags=""
    if [[ "$target" == v3 ]]; then target_flags="--mcpu=x86-64-v3"; fi
    if [[ "$target" == native ]]; then target_flags="--mcpu=native"; fi
    DFLAGS="--gline-tables-only $target_flags --pass-remarks=loop-vectorize --pass-remarks-missed=loop-vectorize --pass-remarks-analysis=loop-vectorize" \
        dub-dlang-baseline build :bench --compiler=ldc-1.43.0 --build=release --force > "$artifacts/$target-build.log" 2>&1
    cp imagery-d_bench "$artifacts/$target-bench"
    # Exercise the actual sample entry point before the long reference/timing
    # runs, including JSON number types and standalone Hessian dispatch.
    for feature in gaussian32 gradient median ridge gabor hessian pathOpening localNormalization; do
        "$artifacts/$target-bench" 32 1 sample scalar "$feature" > "$artifacts/$target-$feature-smoke.json"
    done
    DFLAGS="--gline-tables-only $target_flags" \
        dub-dlang-baseline build --root=tests/feature_program --compiler=ldc-1.43.0 --build=release --force > "$artifacts/$target-oracle-build.log" 2>&1
    cp tests/feature_program/feature-program-oracle "$artifacts/$target-oracle"
    "$oracle_python" tools/verify-feature-program.py "$artifacts/$target-oracle" > "$artifacts/$target-numerical.txt" 2>&1
    echo "$target: build and independent numerical references passed"
done
