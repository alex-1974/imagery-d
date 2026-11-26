#!/usr/bin/env bash
# Render and verify the owned image-operation public APIs.
set -euo pipefail
compiler="${DC:-dmd}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
mkdir -p build/ddox
DC="$compiler" python3 tools/test-ddoc-audit.py
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
case "$(basename "$compiler")" in
    ldc*) io_version="--d-version=imageio_io" ;;
    *) io_version="-version=imageio_io" ;;
esac
# Include direct-import APIs as well as root re-exports. Internal declarations
# remain excluded by their D protection; no public module is hidden by omission.
mapfile -t modules < <(python3 - <<'PY'
from pathlib import Path
for module in sorted(Path('source/imagery').rglob('*.d')):
    print(module)
PY
)
"$compiler" -o- -wi "$io_version" -Xfbuild/ddox/raw.json -Dfbuild/ddox/dummy.html \
    "${imports[@]}" "${modules[@]}" 2>&1 | tee build/ddox/compiler.log
if grep -n 'Warning: Ddoc:' build/ddox/compiler.log; then
    echo "Malformed Ddoc is a documentation failure" >&2
    exit 1
fi
python3 tools/check-ddoc.py build/ddox/raw.json --report build/ddox/coverage.json
cp build/ddox/raw.json build/ddox/docs.json
rm -f build/ddox/dummy.html
dub run "ddox@0.16.24" -- filter --min-protection=Public --only-documented \
    build/ddox/docs.json
python3 -c 'import shutil; shutil.rmtree("build/ddox/site", ignore_errors=True)'
dub run "ddox@0.16.24" -- generate-html --navigation-type=ModuleTree \
    build/ddox/docs.json build/ddox/site
python3 tools/doc_static_assets.py --install build/ddox/site
test -s build/ddox/site/index.html
python3 tools/check-ddoc.py build/ddox/raw.json --site build/ddox/site \
    --report build/ddox/coverage.json
# Content must appear in the actual HTML, not only in source comments.
grep -Rq "Levels" build/ddox/site --include='*.html'
grep -Rq "maxResultBytes" build/ddox/site --include='*.html'
grep -Rq "RgbHistogram256" build/ddox/site --include='*.html'
test -s build/ddox/site/imagery/analysis/rgb_histogram/tryRgbCumulativeCounts.html
test -s build/ddox/site/imagery/analysis/rgb_histogram/tryRgbPercentile.html
test -s build/ddox/site/imagery/analysis/rgb_histogram/tryRgbPercentileStretchLut.html
test -s build/ddox/site/imagery/analysis/rgb_histogram/tryRgbEqualizationLut.html
for symbol in HessianLineParams HessianLineWorkspace hessianLineResponse hessianLineHalo LinePolarity HessianLineVariant; do
    test -s "build/ddox/site/imagery/analysis/hessian_lines/$symbol.html"
done
grep -q "reserve" build/ddox/site/imagery/analysis/hessian_lines/HessianLineWorkspace.html
for parameters in LocalStatisticsParams PathMorphologyParams RidgeParams LineResponseParams GaborParams ShadowParams ClaheParams FeatureViewParams; do
    test -s "build/ddox/site/imagery/analysis/feature_parameters/$parameters.html"
done
for parameters in RidgeParams LineResponseParams GaborParams ShadowParams ClaheParams FeatureViewParams; do
    grep -q "assertThrown" "build/ddox/site/imagery/analysis/feature_parameters/$parameters.html"
done
for symbol in StructureTensorParams TensorWorkspace structureTensor; do
    test -s "build/ddox/site/imagery/analysis/structure_tensor/$symbol.html"
done
grep -q "parameters" build/ddox/site/imagery/analysis/structure_tensor/StructureTensorParams.html
for symbol in ComponentSample ComponentStore ComponentPolicy ComponentProvenance ComponentStatistics ComponentError ComponentFailure ComponentResult ComponentTransaction componentScratchBytes labelComponents tryLabelComponentsTransactional traceLabelLines; do
    test -s "build/ddox/site/imagery/analysis/feature_components/$symbol.html"
done
grep -q "Private staging" build/ddox/site/imagery/analysis/feature_components/tryLabelComponentsTransactional.html
for symbol in ColorSlicParams ColorSlicRequest ColorSlicError ColorSlicMetrics ColorSlicSegmentation colorSlicRgb colorSlicWorkBytes tryColorSlic; do
    test -s "build/ddox/site/imagery/analysis/color_slic/$symbol.html"
done
for symbol in RegionGraph RegionDescriptor RegionEdge RegionNeighbor RegionLabel RegionMerge RegionMergeRecord RegionGraphProvenance RegionGraphRequest RegionGraphError tryBuildRegionGraph tryMergeRegionGraph; do
    test -s "build/ddox/site/imagery/analysis/region_graph/$symbol.html"
done
grep -q "complete segmentation" build/ddox/site/imagery/analysis/color_slic/ColorSlicSegmentation.html
grep -q "snapshot" build/ddox/site/imagery/analysis/region_graph/RegionGraph.html
for field in store components contacts validity commit abort; do
    test -s "build/ddox/site/imagery/analysis/feature_components/ComponentTransaction.$field.html"
done
grep -q "workspace" build/ddox/site/imagery/analysis/structure_tensor/TensorWorkspace.html
test -s build/ddox/site/imagery/analysis/cost_path/CostPath.html
test -s build/ddox/site/imagery/analysis/cost_path/CostPath.predecessorOf.html
test -s build/ddox/site/imagery/analysis/quality/RegionQuality.html
test -s build/ddox/site/imagery/analysis/quality/tryRegionQuality.html
for symbol in QualityContributor tryQualityWeights ValidityPolicyError ValidityDecision tryResolveValidity; do
    test -s "build/ddox/site/imagery/mosaic/validity_policy/$symbol.html"
done
grep -q "1e-160" build/ddox/site/imagery/mosaic/validity_policy/tryQualityWeights.html
for symbol in MosaicSource MosaicRequest MosaicFrame MosaicMetrics MosaicFilter MosaicError MosaicTileStatus MosaicTileConsumer MosaicTileReader MosaicQualityReader MosaicSourceProvenance MosaicDisplayWorkspace MosaicDisplayInfo MosaicDisplayConsumer tryAssembleMosaicOwned; do
    test -s "build/ddox/site/imagery/mosaic/multiresolution/$symbol.html"
done
grep -q "orthophoto" build/ddox/site/imagery/mosaic/multiresolution/tryAssembleMosaicOwned.html
grep -q "private storage" build/ddox/site/imagery/mosaic/multiresolution/MosaicDisplayWorkspace.html
for symbol in ImageMaterializationError ImageMaterializationResult RgbMaterializationResult RgbFloatRasterResult RasterMaterializationError RasterMaterializationResult UshortRasterMaterializationResult OwnedRgbMaterialization MaterializedComponentOrigin visitNativePlanes tryMaterializeRgbOwned; do
    test -s "build/ddox/site/imagery/io/$symbol.html"
done
grep -q "published" build/ddox/site/imagery/io/tryMaterializeRgbOwned.html
grep -q "retained" build/ddox/site/imagery/io/OwnedRgbMaterialization.html
for field in raster source originX originY components sampling recipe; do
    test -s "build/ddox/site/imagery/io/OwnedRgbMaterialization.$field.html"
done
for field in identity revision grid qualityPolicy qualityRevision levels tileWidth tileHeight association quality read qualityRead; do
    test -s "build/ddox/site/imagery/mosaic/multiresolution/MosaicSource.$field.html"
done
test -s build/ddox/site/imagery/analysis/primitives/slic.html
grep -q "NaN sums" build/ddox/site/imagery/analysis/primitives/slic.html
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
test -s build/ddox/site/imagery/analysis/feature_worker32/Float32FeatureWorker.prepareGaussian32.html
grep -q "assert" build/ddox/site/imagery/analysis/feature_worker32/Float32FeatureWorker.prepareGaussian32.html
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

for symbol in CannyWorkspace CannyWorkerError; do
    test -s "build/ddox/site/imagery/analysis/canny_worker/$symbol.html"
done
for symbol in LazyCostPath PathSearchError; do
    test -s "build/ddox/site/imagery/analysis/lazy_cost_path/$symbol.html"
done
test -s build/ddox/site/imagery/analysis/feature_regions/Engine.runPlanar.html
test -s build/ddox/site/imagery/analysis/feature_regions/Engine.reservePlanar.html
grep -q "assert" build/ddox/site/imagery/analysis/canny_worker/CannyWorkspace.html
grep -q "assert" build/ddox/site/imagery/analysis/lazy_cost_path/LazyCostPath.html
