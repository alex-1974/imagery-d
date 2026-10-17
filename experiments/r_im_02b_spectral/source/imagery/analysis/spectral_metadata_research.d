/++
 R-IM-02c: research-only metadata adapter to the existing R-IM-02b
 normalized-difference kernel. Reuses ORIGINAL M3.2 immutable snapshots
 and intrinsic channel types, without a second semantic metadata hierarchy.
+/
module imagery.analysis.spectral_metadata_research;

import imagery.analysis.spectral_research :
    ResearchGrid, ResearchNoData, ResearchSpectralBand,
    ResearchSpectralError, ResearchUnit,
    tryNormalizedDifferenceIntoResearch;
import m3_2_metadata_owner.contract : ResearchMetadataState;
import raster : RasterView, WritableRasterView, Region2D;

/++
 Consumer image with the ORIGINAL M3.2 immutable metadata snapshot.
 The physical sample owner remains external to this borrowed view.
 Frame/grid information is still a caller declaration, NOT a proof
 of source registration or CRS compatibility.
+/
struct ResearchMetadataImage(T)
{
    RasterView!T pixels;
    ResearchMetadataState metadata;
    size_t selectedPlane;
    ResearchGrid grid;
    ResearchNoData!T noData;
}

/// No allocation. Every channel identity is checked against its matching
/// intrinsic immutable descriptor before any destination write.
private ResearchSpectralError validateImage(T)(
    scope ResearchMetadataImage!T image)
{
    auto ids = image.metadata.identities;
    auto intrinsic = image.metadata.metadata;
    if (ids.length == 0 || intrinsic.length != ids.length ||
        ids.length != image.pixels.planeCount ||
        image.selectedPlane >= ids.length)
        return ResearchSpectralError.invalidMetadata;
    foreach (i; 0 .. ids.length)
    {
        if (ids[i].semanticId == 0 ||
            ids[i].semanticId != intrinsic[i].semanticId)
            return ResearchSpectralError.invalidIdentity;
        // A duplicated opaque semantic ID would make a band lookup
        // ambiguous even if each descriptor matched its own plane.
        foreach (j; 0 .. i)
            if (ids[i].semanticId == ids[j].semanticId)
                return ResearchSpectralError.invalidIdentity;
    }
    return ResearchSpectralError.none;
}

/++
 Bind two source bands to their ORIGINAL M3.2 snapshot calibration.

 No caller-provided separate scale/offset/bandId may override the snapshot.
 The matching nonempty quantityLabel proves only *descriptor agreement*,
 NOT scientifically validated unit identity or sensor reflectance.
 A real product/source reader must establish actual provenance.

 NoData is a separate raw-value rule and does not silently become an
 alpha, quality mask or an implicit spatial validity interpretation.
 On a preflight failure the caller destinations stay untouched; late
 access/write failure and physical overlap remain the existing R-IM-02b
 research limitations. This is NOT a safe general production Into API.
+/
ResearchSpectralError tryNormalizedDifferenceMetadataIntoResearch(A, B)(
    scope ResearchMetadataImage!A a,
    scope ResearchMetadataImage!B b,
    Region2D roi,
    scope RasterView!ubyte maskA,
    bool hasMaskA,
    scope RasterView!ubyte maskB,
    bool hasMaskB,
    scope WritableRasterView!float values,
    scope WritableRasterView!ubyte validity)
if ((is(A == ushort) || is(A == float)) &&
    (is(B == ushort) || is(B == float)))
{
    auto err = validateImage(a);
    if (err != ResearchSpectralError.none)
        return err;
    err = validateImage(b);
    if (err != ResearchSpectralError.none)
        return err;

    auto ma = a.metadata.metadata;
    auto mb = b.metadata.metadata;
    const ia = ma[a.selectedPlane];
    const ib = mb[b.selectedPlane];

    if (!ia.hasCalibration || !ib.hasCalibration ||
        ia.quantityLabel.length == 0 ||
        ia.quantityLabel != ib.quantityLabel)
        return ResearchSpectralError.invalidCalibration;

    // The original M3.2 metadata stores float calibration factors.
    // We intentionally preserve that precision and widen to double for
    // the numeric operation rather than fabricate higher-precision data.
    auto left = ResearchSpectralBand!A(
        a.pixels, a.selectedPlane, ia.semanticId, a.grid,
        ResearchUnit.otherConsistentUnit, true,
        cast(double)ia.scale, cast(double)ia.offset,
        a.noData);
    auto right = ResearchSpectralBand!B(
        b.pixels, b.selectedPlane, ib.semanticId, b.grid,
        ResearchUnit.otherConsistentUnit, true,
        cast(double)ib.scale, cast(double)ib.offset,
        b.noData);

    return tryNormalizedDifferenceIntoResearch!(A, B)(
        left, right, roi, maskA, hasMaskA, maskB, hasMaskB,
        values, validity);
}
