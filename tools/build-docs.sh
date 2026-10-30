#!/usr/bin/env bash
# Render and verify the owned image-operation public APIs.
set -euo pipefail
compiler="${DC:-dmd}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
mkdir -p build/ddox
dub build --compiler="$compiler" --build=release --force
dub describe --compiler="$compiler" > build/ddox/dub-describe.json
mapfile -t imports < <(python3 - <<'PY'
import json,pathlib
d=json.loads(pathlib.Path("build/ddox/dub-describe.json").read_text())
for package in d.get("packages",[]):
    base=pathlib.Path(package["path"])
    for path in package.get("importPaths",[]):
        print("-I="+str((base/path).resolve()))
PY
)
"$compiler" -o- -wi -Xfbuild/ddox/docs.json -Dfbuild/ddox/dummy.html \
    "${imports[@]}" \
    source/imagery/package.d \
    source/imagery/presentation/levels.d \
    source/imagery/presentation/brightness_contrast.d \
    source/imagery/analysis/rgb_histogram.d \
    source/imagery/presentation/luminance_stretch.d \
    source/imagery/pyramid/overview_selection.d
rm -f build/ddox/dummy.html
dub run "ddox@0.16.24" -- filter --min-protection=Public --only-documented \
    build/ddox/docs.json
dub run "ddox@0.16.24" -- generate-html --navigation-type=ModuleTree \
    build/ddox/docs.json build/ddox/site
test -s build/ddox/site/index.html
# Content must appear in the actual HTML, not only in source comments.
grep -Rq "Levels" build/ddox/site --include='*.html'
grep -Rq "maxResultBytes" build/ddox/site --include='*.html'
grep -Rq "RgbHistogram256" build/ddox/site --include='*.html'
test -s build/ddox/site/imagery/analysis/rgb_histogram/tryRgbCumulativeCounts.html
test -s build/ddox/site/imagery/analysis/rgb_histogram/tryRgbPercentile.html
test -s build/ddox/site/imagery/analysis/rgb_histogram/tryRgbPercentileStretchLut.html
test -s build/ddox/site/imagery/analysis/rgb_histogram/tryRgbEqualizationLut.html
test -s build/ddox/site/imagery/presentation/luminance_stretch/LuminanceStretchError.html
test -s build/ddox/site/imagery/presentation/luminance_stretch/tryRgbLuminanceStretchOwned.html
test -s build/ddox/site/imagery/pyramid/overview_selection/OverviewLevel.html
test -s build/ddox/site/imagery/pyramid/overview_selection/OverviewSelection.html
test -s build/ddox/site/imagery/pyramid/overview_selection/trySelectOverviewLevel.html
grep -Rq "XYZ-D65-Y" build/ddox/site/imagery/presentation/luminance_stretch --include='*.html'
# --only-documented otherwise silently drops public result fields.
for field in bins includedPixels excludedPixels minimum maximum mean; do
    test -s "build/ddox/site/imagery/analysis/rgb_histogram/RgbHistogram256.$field.html"
done
grep -q 'mask byte 1 includes once' \
    build/ddox/site/imagery/analysis/rgb_histogram/tryRgbHistogram256.html
grep -q 'returned failure preserves publication' \
    build/ddox/site/imagery/analysis/rgb_histogram/tryRgbHistogram256.html
echo "M3_LEVELS_DDOX=PASS"
