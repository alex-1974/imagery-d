/++
 R-IM-02d: research-only optical product evidence GATE for the existing
 M3.2 snapshot-bound normalized-difference operator.

 This code does NOT parse STAC/SAFE/Sentinel-2 products, verify sensor
 provenance, or introduce a second raster, channel, or metadata owner.
 Typed declarations are supplied by a future, independently verified
 product adapter; they are NOT trusted facts merely because populated.
+/
module imagery.analysis.optical_product_research;

import imagery.analysis.spectral_metadata_research :
    ResearchMetadataImage, tryNormalizedDifferenceMetadataIntoResearch;
import imagery.analysis.spectral_research :
    ResearchNoData, ResearchSpectralError;
import raster : RasterView, WritableRasterView, Region2D;

enum ResearchOpticalRole : ubyte
{
    unspecified,
    red,
    nearInfrared,
    quality
}

enum ResearchOpticalQuantity : ubyte
{
    unspecified,
    surfaceReflectance,
    toaReflectance,
    radiance,
    classification
}

/// Additional product/asset-level assertions, NOT replacement band metadata.
struct ResearchOpticalAsset
{
    string productId;
    string assetId;
    string providerBandName;
    string processingBaseline;
    uint semanticId;
    ResearchOpticalRole role;
    ResearchOpticalQuantity quantity;
    bool hasCentre;
    double centreMicrometres;
    bool hasFwhm;
    double fwhmMicrometres;
    bool hasNativeGsd;
    double nativeGsdMetres;
    bool hasRawNoData;
    ushort rawNoData;
    double declaredScale;
    double declaredOffset;
}

enum ResearchOpticalGateError : ubyte
{
    none,
    missingProvenance,
    invalidBand,
    invalidSpectralEvidence,
    incompatibleQuantity,
    nativeGridMismatch,
    calibrationMismatch,
    nodataConflict,
    executorRejected
}

struct ResearchOpticalStatus
{
    ResearchOpticalGateError gate;
    ResearchSpectralError underlying;
}

private bool finite(double x)
{
    return x >= -double.max && x <= double.max;
}

/// Only already-aligned, already-materialised ushort bands are considered.
/// The typed evidence gate is an adapter experiment, not a sensor validator.
ResearchOpticalStatus tryOpticalNdIntoResearch(
    scope ResearchMetadataImage!ushort nir,
    scope ResearchMetadataImage!ushort red,
    ResearchOpticalAsset nirAsset,
    ResearchOpticalAsset redAsset,
    Region2D roi,
    scope RasterView!ubyte nirMask,
    bool hasNirMask,
    scope RasterView!ubyte redMask,
    bool hasRedMask,
    scope WritableRasterView!float output,
    scope WritableRasterView!ubyte validity)
{
    ResearchOpticalStatus rejected(ResearchOpticalGateError reason)
    {
        return ResearchOpticalStatus(reason, ResearchSpectralError.none);
    }

    if (nirAsset.productId.length == 0 ||
        redAsset.productId.length == 0 ||
        nirAsset.productId != redAsset.productId ||
        nirAsset.assetId.length == 0 ||
        redAsset.assetId.length == 0 ||
        nirAsset.providerBandName.length == 0 ||
        redAsset.providerBandName.length == 0 ||
        nirAsset.processingBaseline.length == 0 ||
        nirAsset.processingBaseline != redAsset.processingBaseline)
        return rejected(ResearchOpticalGateError.missingProvenance);

    if (nirAsset.semanticId == 0 || redAsset.semanticId == 0 ||
        nirAsset.semanticId == redAsset.semanticId ||
        nirAsset.role != ResearchOpticalRole.nearInfrared ||
        redAsset.role != ResearchOpticalRole.red)
        return rejected(ResearchOpticalGateError.invalidBand);

    // Band wavelengths/FWHM are optional STAC EO metadata, not a
    // replacement for provider spectral response curves.
    foreach (asset; [nirAsset, redAsset])
    {
        if ((asset.hasCentre &&
             (!finite(asset.centreMicrometres) ||
              asset.centreMicrometres <= 0)) ||
            (asset.hasFwhm &&
             (!finite(asset.fwhmMicrometres) ||
              asset.fwhmMicrometres <= 0)))
            return rejected(ResearchOpticalGateError.invalidSpectralEvidence);
    }

    if (nirAsset.quantity != redAsset.quantity ||
        (nirAsset.quantity != ResearchOpticalQuantity.surfaceReflectance &&
         nirAsset.quantity != ResearchOpticalQuantity.toaReflectance))
        return rejected(ResearchOpticalGateError.incompatibleQuantity);

    if (!nirAsset.hasNativeGsd || !redAsset.hasNativeGsd ||
        !finite(nirAsset.nativeGsdMetres) ||
        !finite(redAsset.nativeGsdMetres) ||
        nirAsset.nativeGsdMetres <= 0 ||
        redAsset.nativeGsdMetres <= 0 ||
        nirAsset.nativeGsdMetres != redAsset.nativeGsdMetres)
        return rejected(ResearchOpticalGateError.nativeGridMismatch);

    if (nir.selectedPlane >= nir.metadata.metadata.length ||
        red.selectedPlane >= red.metadata.metadata.length ||
        nir.selectedPlane >= nir.metadata.identities.length ||
        red.selectedPlane >= red.metadata.identities.length)
        return rejected(ResearchOpticalGateError.invalidBand);

    const nm = nir.metadata.metadata[nir.selectedPlane];
    const rm = red.metadata.metadata[red.selectedPlane];
    if (nir.metadata.identities[nir.selectedPlane].semanticId !=
        nirAsset.semanticId ||
        red.metadata.identities[red.selectedPlane].semanticId !=
        redAsset.semanticId)
        return rejected(ResearchOpticalGateError.invalidBand);

    // Existing M3.2 uses *float* scale/offset. This comparison detects
    // manifest/discovered calibration disagreement at that precision;
    // it does NOT certify full STAC JSON binary64 calibration fidelity.
    if (!finite(nirAsset.declaredScale) ||
        !finite(redAsset.declaredScale) ||
        !finite(nirAsset.declaredOffset) ||
        !finite(redAsset.declaredOffset) ||
        !nm.hasCalibration || !rm.hasCalibration ||
        cast(float)nirAsset.declaredScale != nm.scale ||
        cast(float)redAsset.declaredScale != rm.scale ||
        cast(float)nirAsset.declaredOffset != nm.offset ||
        cast(float)redAsset.declaredOffset != rm.offset)
        return rejected(ResearchOpticalGateError.calibrationMismatch);

    // Two levels remain distinct: source asset NoData and caller's
    // validity/quality mask. NoData is a raw DN rule, not a scaled value.
    if ((nir.noData.enabled &&
         (!nirAsset.hasRawNoData ||
          nir.noData.sentinel != nirAsset.rawNoData)) ||
        (red.noData.enabled &&
         (!redAsset.hasRawNoData ||
          red.noData.sentinel != redAsset.rawNoData)))
        return rejected(ResearchOpticalGateError.nodataConflict);

    auto boundNir = nir;
    auto boundRed = red;
    boundNir.noData = ResearchNoData!ushort(
        nirAsset.hasRawNoData, nirAsset.rawNoData);
    boundRed.noData = ResearchNoData!ushort(
        redAsset.hasRawNoData, redAsset.rawNoData);

    const result = tryNormalizedDifferenceMetadataIntoResearch!(
        ushort, ushort)(
        boundNir, boundRed, roi,
        nirMask, hasNirMask, redMask, hasRedMask,
        output, validity);
    if (result != ResearchSpectralError.none)
        return ResearchOpticalStatus(
            ResearchOpticalGateError.executorRejected, result);
    return ResearchOpticalStatus.init;
}
