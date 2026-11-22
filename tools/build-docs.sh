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
    source/imagery/presentation/exposure_curves.d \
    source/imagery/analysis/rgb_histogram.d \
    source/imagery/analysis/feature_parameters.d \
    source/imagery/analysis/feature_regions.d \
    source/imagery/analysis/feature_requests.d \
    source/imagery/analysis/structure_tensor.d \
    source/imagery/analysis/cost_path.d \
    source/imagery/analysis/quality.d \
    source/imagery/analysis/feature_worker32.d \
    source/imagery/analysis/primitives.d \
    source/imagery/analysis/filters.d \
    source/imagery/analysis/edges.d \
    source/imagery/analysis/morphology.d \
    source/imagery/analysis/segmentation.d \
    source/imagery/analysis/indices.d \
    source/imagery/analysis/execution.d \
    source/imagery/analysis/raster_adapters.d \
    source/imagery/presentation/luminance_stretch.d \
    source/imagery/pyramid/overview_selection.d \
    source/imagery/compositing/source_over.d
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
for parameters in LocalStatisticsParams PathMorphologyParams RidgeParams LineResponseParams GaborParams ShadowParams ClaheParams; do
    test -s "build/ddox/site/imagery/analysis/feature_parameters/$parameters.html"
done
for parameters in RidgeParams LineResponseParams GaborParams ShadowParams ClaheParams; do
    grep -q "assertThrown" "build/ddox/site/imagery/analysis/feature_parameters/$parameters.html"
done
for symbol in StructureTensorParams TensorWorkspace structureTensor; do
    test -s "build/ddox/site/imagery/analysis/structure_tensor/$symbol.html"
done
grep -q "parameters" build/ddox/site/imagery/analysis/structure_tensor/StructureTensorParams.html
grep -q "workspace" build/ddox/site/imagery/analysis/structure_tensor/TensorWorkspace.html
test -s build/ddox/site/imagery/analysis/cost_path/CostPath.html
test -s build/ddox/site/imagery/analysis/cost_path/CostPath.predecessorOf.html
test -s build/ddox/site/imagery/analysis/quality/RegionQuality.html
test -s build/ddox/site/imagery/analysis/quality/tryRegionQuality.html
test -s build/ddox/site/imagery/analysis/feature_regions/runFeatureView.html
test -s build/ddox/site/imagery/analysis/feature_requests/FeatureRequests.submit.html
grep -q "LocalStatisticsParams" build/ddox/site/imagery/analysis/feature_regions/runFeatureView.html
grep -q "LocalStatisticsParams" build/ddox/site/imagery/analysis/feature_requests/FeatureRequests.html
grep -q "constant" build/ddox/site/imagery/analysis/quality/RegionQuality.html
grep -q "search" build/ddox/site/imagery/analysis/cost_path/CostPath.html
for symbol in Float32FeatureWorker FeaturePlanes32 FeatureWorkerError FeaturePlaneDomain; do
    test -s "build/ddox/site/imagery/analysis/feature_worker32/$symbol.html"
done
test -s build/ddox/site/imagery/analysis/feature_worker32/Float32FeatureWorker.tryEvaluate.html
grep -q "withPlane" build/ddox/site/imagery/analysis/feature_worker32/Float32FeatureWorker.tryEvaluate.html
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
echo "M3_LEVELS_DDOX=PASS"
