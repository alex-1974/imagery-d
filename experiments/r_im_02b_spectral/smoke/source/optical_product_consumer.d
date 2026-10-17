/++
 R-IM-02d independent DUB consumer: STAC-shaped, SYNTHETIC optical
 products. No external scene was read and no sensor origin was verified.
 Oracles use original fixture formulas and the declared processing profile,
 never the research operator's output formula or any decoded product.
+/
module optical_product_consumer;

import core.stdc.stdlib : malloc;
import std.stdio : writeln;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView, Region2D,
    tryAdoptMallocResource, tryImportOwnedRaster;
import m1_5_image_view.contract : ChannelDescriptor;
import m3_2_channel_metadata.contract : IntrinsicChannel;
import m3_2_metadata_owner.contract : ResearchMetadataState;
import imagery.analysis.spectral_research : ResearchGrid, ResearchNoData;
import imagery.analysis.spectral_metadata_research : ResearchMetadataImage;
import imagery.analysis.optical_product_research :
    ResearchOpticalRole, ResearchOpticalQuantity, ResearchOpticalAsset,
    ResearchOpticalGateError, tryOpticalNdIntoResearch;

private enum size_t W = 6;
private enum size_t H = 4;
private enum size_t C = 2;

private void demand(bool ok, string what)
{
    if (!ok)
        throw new Exception("R-IM-02d synthetic optical consumer: " ~ what);
}

private ushort dn(bool nir, size_t x, size_t y)
{
    if (x == 1 && y == 1)
        return 2500; // mathematical ND=0 with nonzero denominator
    if (nir && x == 2 && y == 0)
        return 0; // raw DN=0 NoData MUST be applied before offset
    if (!nir && x == 3 && y == 2)
        return 0;
    if (x == 4 && y == 3)
        return nir ? cast(ushort)2000 : cast(ushort)500;
    return nir ? cast(ushort)(3500 + 5*x + 7*y)
               : cast(ushort)(1300 + 17*x + 5*y);
}

private bool permitted(size_t x, size_t y)
{
    return (x + y) % 5 != 0; // independent of per-band raw NoData
}

private RasterLease!T ownRaster(T)(
    size_t width, size_t height, size_t planes,
    bool interleaved)
{
    auto bytes = width * height * planes * T.sizeof;
    auto raw = cast(T*)malloc(bytes);
    demand(raw !is null, "malloc");
    OwnedByteResource owner;
    demand(tryAdoptMallocResource(raw, bytes, owner), "adopt");
    auto descriptors = new PlaneByteLayout[](planes);
    foreach (p; 0 .. planes)
        descriptors[p] = interleaved
            ? PlaneByteLayout(p*T.sizeof,
                cast(ptrdiff_t)(width*planes*T.sizeof),
                cast(ptrdiff_t)(planes*T.sizeof))
            : PlaneByteLayout(p*width*height*T.sizeof,
                cast(ptrdiff_t)(width*T.sizeof),
                cast(ptrdiff_t)T.sizeof);
    RasterLease!T lease;
    auto status = tryImportOwnedRaster!T(owner, descriptors[],
        Region2D(0, 0, width, height), lease);
    demand(status.ok, "checked raster import");
    return lease;
}

private RasterLease!ushort makePixels(bool nir, bool interleaved)
{
    auto p = ownRaster!ushort(W,H,C,interleaved);
    bool ok;
    scope auto dst = p.tryWritableView(ok);
    demand(ok, "source writer");
    foreach (ch; 0 .. C)
    foreach (y; 0 .. H)
    foreach (x; 0 .. W)
        demand(dst.trySetSample(ch,x,y,
            ch == 1 ? dn(nir,x,y) : cast(ushort)(111+ch+x+y)),
            "source write");
    return p;
}

private RasterLease!ubyte makeMask()
{
    auto p = ownRaster!ubyte(W,H,1,false);
    bool ok;
    scope auto w = p.tryWritableView(ok);
    demand(ok, "mask writer");
    foreach (y; 0 .. H)
    foreach (x; 0 .. W)
        demand(w.trySetSample(0,x,y,
            permitted(x,y) ? cast(ubyte)255 : cast(ubyte)0),
            "mask write");
    return p;
}

private ResearchMetadataState makeMetadata(bool nir, bool withOffset)
{
    const uint selectedId = nir ? 77 : 42;
    ChannelDescriptor[2] ids = [
        ChannelDescriptor(nir ? 177 : 142), ChannelDescriptor(selectedId)];
    IntrinsicChannel[2] info = [
        IntrinsicChannel(ids[0].semanticId,"Other","surface-reflectance",
            true,0.0001f,withOffset ? -0.1f : 0.0f),
        IntrinsicChannel(selectedId,nir ? "B08" : "B04",
            "surface-reflectance",true,0.0001f,
            withOffset ? -0.1f : 0.0f)
    ];
    auto snapshot = ResearchMetadataState.snapshot(ids[], info[]);
    // Mutate caller arrays after snapshot, proving the producer's
    // original calibrated values and IDs cannot be rewritten this way.
    ids[1] = ChannelDescriptor(999);
    info[1] = IntrinsicChannel(999,"tampered","unknown",false,1,42);
    demand(snapshot.identities[1].semanticId == selectedId &&
        snapshot.metadata[1].scale == 0.0001f,
        "immutable metadata snapshot");
    return snapshot;
}

private ResearchOpticalAsset asset(bool nir, bool withOffset)
{
    ResearchOpticalAsset a;
    a.productId = "synthetic-scene-0001";
    a.assetId = nir ? "NIR" : "RED";
    a.providerBandName = nir ? "B08" : "B04";
    a.processingBaseline = withOffset ? "04.00" : "03.01";
    a.semanticId = nir ? 77 : 42;
    a.role = nir ? ResearchOpticalRole.nearInfrared
                 : ResearchOpticalRole.red;
    a.quantity = ResearchOpticalQuantity.surfaceReflectance;
    a.hasCentre = true;
    a.centreMicrometres = nir ? 0.842 : 0.665;
    a.hasFwhm = true;
    a.fwhmMicrometres = nir ? 0.106 : 0.031;
    a.hasNativeGsd = true;
    a.nativeGsdMetres = 10;
    a.hasRawNoData = true;
    a.rawNoData = 0;
    a.declaredScale = 0.0001;
    a.declaredOffset = withOffset ? -0.1 : 0.0;
    return a;
}

private void independentOracle(
    size_t x, size_t y, bool masked, bool offsetApplied,
    out float value, out ubyte validity)
{
    value = 0;
    validity = 0;
    if (masked && !permitted(x,y))
        return;
    const nr = dn(true,x,y);
    const rd = dn(false,x,y);
    if (nr == 0 || rd == 0)
        return;
    // The original IntrinsicChannel has float-calibration precision.
    const scale = cast(double)0.0001f;
    const off = offsetApplied ? cast(double)(-0.1f) : 0.0;
    const n = cast(double)nr*scale+off;
    const r = cast(double)rd*scale+off;
    const denom = n + r;
    if (denom == 0)
        return;
    const score = (n - r)/denom;
    value = cast(float)score;
    validity = 255;
}

private void runCase(bool layout, bool withMask, bool offsetApplied)
{
    auto nOwner = makePixels(true,layout);
    auto rOwner = makePixels(false,!layout);
    auto maskOwner = makeMask();
    const grid = ResearchGrid(11,300,600,10,-10);
    auto n = ResearchMetadataImage!ushort(nOwner.view(),
        makeMetadata(true,offsetApplied),1,grid,ResearchNoData!ushort.init);
    auto r = ResearchMetadataImage!ushort(rOwner.view(),
        makeMetadata(false,offsetApplied),1,grid,ResearchNoData!ushort.init);
    auto na = asset(true,offsetApplied);
    auto ra = asset(false,offsetApplied);
    auto mask = withMask ? maskOwner.view() : RasterView!ubyte.init;
    const Region2D[5] windows = [
        Region2D(0,0,W,H),
        Region2D(0,0,3,2), Region2D(3,0,3,2),
        Region2D(0,2,3,2), Region2D(3,2,3,2)
    ];
    float[W*H] whole;
    ubyte[W*H] wholeValid;

    foreach (idx, roi; windows)
    {
        auto pixels = ownRaster!float(roi.width,roi.height,1,false);
        auto validity = ownRaster!ubyte(roi.width,roi.height,1,true);
        bool good1, good2;
        scope auto outPixels = pixels.tryWritableView(good1);
        scope auto outMask = validity.tryWritableView(good2);
        demand(good1 && good2,"writable output");
        const state = tryOpticalNdIntoResearch(
            n,r,na,ra,roi,mask,withMask,mask,withMask,
            outPixels,outMask);
        demand(state.gate == ResearchOpticalGateError.none,
            "accepted optical product evidence");

        auto pxRead = pixels.view();
        auto mRead = validity.view();
        foreach (dy; 0 .. roi.height)
        foreach (dx; 0 .. roi.width)
        {
            const x=roi.x+dx, y=roi.y+dy;
            float value,want;
            ubyte flag,wantFlag;
            demand(pxRead.trySample(0,dx,dy,value) &&
                mRead.trySample(0,dx,dy,flag),"read result pixels");
            independentOracle(x,y,withMask,offsetApplied,want,wantFlag);
            const diff = value - want;
            demand(flag == wantFlag && diff>=-0.000002f &&
                diff<=0.000002f,"independent scientific index oracle");
            if(idx==0)
            {
                whole[y*W+x]=value;
                wholeValid[y*W+x]=flag;
            }
            else
                demand(value == whole[y*W+x] &&
                       flag == wholeValid[y*W+x],
                       "partitioned ROI equality");
        }
    }

    // A nonempty caller-owned result MUST remain unchanged on every
    // product/asset preflight rejection, not just on a .init output.
    auto pixels=ownRaster!float(W,H,1,false);
    auto valid=ownRaster!ubyte(W,H,1,false);
    bool good1,good2;
    scope auto dst=pixels.tryWritableView(good1);
    scope auto vm=valid.tryWritableView(good2);
    demand(good1 && good2,"negative-case result views");
    foreach (y;0..H)
    foreach (x;0..W)
        demand(dst.trySetSample(0,x,y,-777.0f) &&
            vm.trySetSample(0,x,y,33),"negative sentinels");

    void reject(ResearchOpticalAsset left,
        ResearchOpticalAsset right,ResearchOpticalGateError expected)
    {
        auto state = tryOpticalNdIntoResearch(
            n,r,left,right,windows[0],
            mask,withMask,mask,withMask,dst,vm);
        demand(state.gate==expected,"reject incorrect asset semantics");
    }

    auto wrong = na;
    wrong.productId="other-scene";
    reject(wrong,ra,ResearchOpticalGateError.missingProvenance);
    wrong=na;
    wrong.processingBaseline="05.00";
    reject(wrong,ra,ResearchOpticalGateError.missingProvenance);
    wrong=na;
    wrong.semanticId=999;
    reject(wrong,ra,ResearchOpticalGateError.invalidBand);
    wrong=na;
    wrong.role=ResearchOpticalRole.quality;
    reject(wrong,ra,ResearchOpticalGateError.invalidBand);
    wrong=na;
    wrong.quantity=ResearchOpticalQuantity.radiance;
    reject(wrong,ra,ResearchOpticalGateError.incompatibleQuantity);
    wrong=na;
    wrong.nativeGsdMetres=20;
    reject(wrong,ra,ResearchOpticalGateError.nativeGridMismatch);
    wrong=na;
    wrong.hasNativeGsd=false;
    reject(wrong,ra,ResearchOpticalGateError.nativeGridMismatch);
    wrong=na;
    wrong.centreMicrometres=double.nan;
    reject(wrong,ra,ResearchOpticalGateError.invalidSpectralEvidence);
    wrong=na;
    wrong.declaredOffset=17;
    reject(wrong,ra,ResearchOpticalGateError.calibrationMismatch);
    wrong=na;
    wrong.hasRawNoData=false;
    auto nWithNoData=n;
    nWithNoData.noData=ResearchNoData!ushort(true,0);
    const nodataConflict=tryOpticalNdIntoResearch(
        nWithNoData,r,wrong,ra,windows[0],mask,withMask,mask,withMask,dst,vm);
    demand(nodataConflict.gate==ResearchOpticalGateError.nodataConflict,
        "reject contradictory raw NoData declaration");

    auto dstRead=pixels.view();
    auto maskRead=valid.view();
    foreach (y;0..H)
    foreach (x;0..W)
    {
        float observed; ubyte flag;
        demand(dstRead.trySample(0,x,y,observed) &&
               maskRead.trySample(0,x,y,flag) &&
               observed==-777.0f && flag==33,
               "all optical preflight rejections preserve destination");
    }
}

void runOpticalProductConsumer()
{
    foreach (layout;[false,true])
    foreach (masked;[false,true])
    foreach (withOffset;[false,true])
        runCase(layout,masked,withOffset);

    writeln("R-IM-02d optical product PASS: 8 configurations, ",
        "40 complete ROI+mask pairs, 384 pixels verified, ",
        "10 negative asset preflight cases per configuration");
}
