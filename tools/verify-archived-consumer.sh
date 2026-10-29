#!/usr/bin/env bash
# Prove that the *published-source-archive candidate* is a sufficient DUB
# dependency when no consumer sees the working-tree source or test modules.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
cd "$root"
compiler="${DC:-dmd}"
build="${1:-release}"
archive_ref="${GIT_ARCHIVE_REF:-HEAD}"
if [[ "$build" != "debug" && "$build" != "release" ]]; then
    echo "Expected debug or release build" >&2
    exit 2
fi
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/package" "$scratch/consumer/source"
git archive --format=tar "$archive_ref" | tar -xf - -C "$scratch/package"
cp tests/archive_consumer/source/app.d "$scratch/consumer/source/app.d"
cat > "$scratch/consumer/dub.sdl" <<'DUB'
name "imagery-d-external-archive-probe"
description "Clean source-archive consumer outside the imagery-d checkout"
license "MIT"
targetType "executable"
sourcePaths "source"
dependency "imagery-d" path="../package"
DUB

test -f "$scratch/package/LICENSE"
test -f "$scratch/package/dub.sdl"
test -f "$scratch/package/source/imagery/package.d"
test -f "$scratch/package/source/imagery/presentation/levels.d"
test -f "$scratch/package/source/imagery/presentation/luminance_stretch.d"
test -f "$scratch/package/source/imagery/analysis/rgb_histogram.d"
test ! -d "$scratch/package/tests"
test ! -d "$scratch/package/experiments"
test ! -d "$scratch/package/.github"
test ! -d "$scratch/package/docs/research"

# Both the package and the DUB project are outside the checkout, so
# successful resolution cannot accidentally load local source/imagery.
(
    cd "$scratch/consumer"
    dub run --compiler="$compiler" --build="$build" --force \
        2>&1 | tee "$scratch/external-run.log"
)
grep -q '^M3_LEVELS_ARCHIVED_EXTERNAL=PASS;' "$scratch/external-run.log"
echo "M3_LEVELS_ARCHIVE_EXTERNAL_GATE=PASS; compiler=$compiler build=$build"
