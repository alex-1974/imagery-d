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
case "$(basename "$compiler")" in
    ldc*) io_version="--d-version=imageio_io" ;;
    *) io_version="-version=imageio_io" ;;
esac
"$compiler" -o- -wi "$io_version" -Xfbuild/ddox/docs.json -Dfbuild/ddox/dummy.html \
    "${imports[@]}" \
    source/imagery/package.d \
    source/imagery/io.d \
    source/imagery/presentation/levels.d \
    source/imagery/presentation/brightness_contrast.d \
    source/imagery/presentation/exposure_curves.d \
    source/imagery/analysis/rgb_histogram.d \
    source/imagery/analysis/feature_parameters.d \
    source/imagery/analysis/feature_regions.d \
    source/imagery/analysis/feature_requests.d \
    source/imagery/analysis/feature_components.d \
    source/imagery/analysis/feature_segmentation.d \
    source/imagery/analysis/structure_tensor.d \
    source/imagery/analysis/cost_path.d \
    source/imagery/analysis/quality.d \
    source/imagery/mosaic/validity_policy.d \
    source/imagery/mosaic/multiresolution.d \
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
for symbol in MosaicSource MosaicRequest MosaicFrame MosaicMetrics MosaicFilter MosaicError MosaicTileStatus MosaicTileConsumer MosaicTileReader MosaicQualityReader MosaicSourceProvenance tryAssembleMosaicOwned; do
    test -s "build/ddox/site/imagery/mosaic/multiresolution/$symbol.html"
done
grep -q "orthophoto" build/ddox/site/imagery/mosaic/multiresolution/tryAssembleMosaicOwned.html
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
