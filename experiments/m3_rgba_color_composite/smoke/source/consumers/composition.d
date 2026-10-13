module consumers.composition;

// This is a distinct ordinary DUB application, not a copy of the
// Porter-Duff code and not a GUI renderer. The oracle intentionally
// does NOT import any color-d maths API or imagery's sourceOver helper.
import core.stdc.stdlib : malloc;
import core.memory : GC;
import std.math : pow;
import imagery.presentation.composite :
    RgbaCompositeLayer, RgbaCompositeSpace, RgbaCompositeError,
    tryCompositeSourceOver;
import imagery.presentation.tiles : RgbaAlphaAssociation;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;

private enum Layout : ubyte { planar, interleaved }
private enum size_t width = 8, height = 6;

private void require(bool ok, string description)
{
    if (!ok)
        throw new Exception("M3 RGBA composite independent consumer: " ~ description);
}

// Complete and independent deterministic input fixture. 8x6 spans a
// mock 2x2 grid's x=4/y=3 seams. Values are stored as encoded sRGB
// or *linear-light* and premultiplication is done ONLY in linear-light.
private double alphaAt(size_t layer, size_t x, size_t y)
@safe pure nothrow @nogc
{
    const index = layer == 0 ? (x + 2 * y) % 3
                             : (x + y + 1) % 3;
    return index == 0 ? 0.0 : (index == 1 ? 0.5 : 1.0);
}
private double straightAt(
    size_t layer, size_t c, size_t x, size_t y,
    RgbaCompositeSpace space
) @safe pure nothrow @nogc
{
    const double shift = cast(double)layer * 0.035;
    if (space == RgbaCompositeSpace.encodedSRgb)
    {
        if (c == 0) return 0.08 + 0.10 * x + shift;
        if (c == 1) return 0.05 + 0.10 * y + shift;
        return 0.10 + 0.08 * ((x + y) % 8) + shift;
    }
    // Extended linear-light values MUST survive without implicit clipping.
    if (c == 0) return 0.20 + 0.17 * x + shift;
    if (c == 1) return -0.20 + 0.16 * y + shift;
    return 0.10 + 0.13 * ((3 * x + y) % 7) + shift;
}
private double storedAt(
    size_t layer, size_t c, size_t x, size_t y,
    RgbaCompositeSpace space, RgbaAlphaAssociation association
) @safe pure nothrow @nogc
{
    if (c == 3) return alphaAt(layer, x, y);
    const double v = straightAt(layer, c, x, y, space);
    return association == RgbaAlphaAssociation.premultiplied
        ? v * alphaAt(layer, x, y) : v;
}

// Independent piecewise nominal sRGB transfer reference; this test
// does NOT call color-d's decode or colour composite.
private double referenceLinear(double encoded)
{
    if (encoded <= 0.04045)
        return encoded / 12.92;
    return pow((encoded + 0.055) / 1.055, 2.4);
}

private double referenceResult(
    size_t c, size_t x, size_t y,
    RgbaCompositeSpace foregroundSpace,
    RgbaAlphaAssociation foregroundAssociation,
    RgbaCompositeSpace backgroundSpace,
    RgbaAlphaAssociation backgroundAssociation,
    bool reverse = false
)
{
    const size_t top = reverse ? 1 : 0;
    const size_t bottom = reverse ? 0 : 1;
    const auto topSpace = top == 0 ? foregroundSpace : backgroundSpace;
    const auto bottomSpace = bottom == 0 ? foregroundSpace : backgroundSpace;
    const double at = alphaAt(top, x, y);
    const double ab = alphaAt(bottom, x, y);
    if (c == 3)
        return at + ab * (1.0 - at);

    // Reference is formulated from raw independent straight-value
    // image generation, NOT from imagery's premultiply/sourceOver.
    double ct = straightAt(top, c, x, y, topSpace);
    double cb = straightAt(bottom, c, x, y, bottomSpace);
    if (topSpace == RgbaCompositeSpace.encodedSRgb)
        ct = referenceLinear(ct);
    if (bottomSpace == RgbaCompositeSpace.encodedSRgb)
        cb = referenceLinear(cb);
    return ct * at + cb * ab * (1.0 - at);
}

private RasterLease!double makeImage(
    Layout layout, size_t layer,
    RgbaCompositeSpace space, RgbaAlphaAssociation association,
    size_t nplanes = 4, size_t w = width, size_t h = height,
    bool fill = true
)
{
    const bytes = nplanes * w * h * double.sizeof;
    auto memory = cast(double*)malloc(bytes);
    require(memory !is null, "malloc owned raster");

    OwnedByteResource owned;
    require(tryAdoptMallocResource(memory, bytes, owned),
        "adopt raw double-pixel resource");
    auto planes = new PlaneByteLayout[](nplanes);
    foreach (c; 0 .. nplanes)
    {
        planes[c] = layout == Layout.planar
            ? PlaneByteLayout(c * w * h * double.sizeof,
                cast(ptrdiff_t)(w * double.sizeof),
                cast(ptrdiff_t)double.sizeof)
            : PlaneByteLayout(c * double.sizeof,
                cast(ptrdiff_t)(w * nplanes * double.sizeof),
                cast(ptrdiff_t)(nplanes * double.sizeof));
    }
    RasterLease!double lease;
    const imported = tryImportOwnedRaster!double(
        owned, planes[], Region2D(0, 0, w, h), lease);
    require(imported.ok, "import borrowed raster resource");
    if (fill)
    {
        bool ok;
        scope auto writable = lease.tryWritableView(ok);
        require(ok, "make input writable");
        foreach (c; 0 .. nplanes)
        foreach (y; 0 .. h)
        foreach (x; 0 .. w)
            require(writable.trySetSample(c, x, y, storedAt(
                layer, c, x, y, space, association)),
                "write fixture input");
    }
    return lease;
}

private struct Treatment
{
    RgbaCompositeSpace fgSpace;
    RgbaAlphaAssociation fgAssociation;
    RgbaCompositeSpace bgSpace;
    RgbaAlphaAssociation bgAssociation;
}

private void assertUnchanged(
    scope RasterView!double readback, size_t w, size_t h, double sentinel
)
{
    foreach (c; 0 .. 4)
    foreach (y; 0 .. h)
    foreach (x; 0 .. w)
    {
        double v;
        require(readback.trySample(c, x, y, v)
            && v == sentinel, "preflight overwrote destination");
    }
}

private void exercise(
    Layout foregroundLayout, Layout destinationLayout,
    Treatment treatment
)
{
    const auto backgroundLayout =
        foregroundLayout == Layout.planar ? Layout.interleaved
                                          : Layout.planar;
    auto foregroundLease = makeImage(
        foregroundLayout, 0, treatment.fgSpace, treatment.fgAssociation);
    auto backgroundLease = makeImage(
        backgroundLayout, 1, treatment.bgSpace, treatment.bgAssociation);
    auto foreground = RgbaCompositeLayer(
        foregroundLease.view(), treatment.fgSpace, treatment.fgAssociation);
    auto background = RgbaCompositeLayer(
        backgroundLease.view(), treatment.bgSpace, treatment.bgAssociation);

    const Region2D[3] views = [
        Region2D(0, 0, width, height),
        Region2D(3, 1, 4, 4), // crosses mock x=4/y=3 seams
        Region2D(2, 0, 5, 5)
    ];

    foreach (roi; views)
    {
        auto destinationLease = makeImage(
            destinationLayout, 0, RgbaCompositeSpace.linearSRgb,
            RgbaAlphaAssociation.premultiplied, 4,
            roi.width, roi.height, false);
        bool writable;
        scope auto output = destinationLease.tryWritableView(writable);
        require(writable, "get output writer");
        auto readback = destinationLease.view();

        const before = GC.stats().allocatedInCurrentThread;
        const e = tryCompositeSourceOver(
            foreground, background, roi, output);
        const after = GC.stats().allocatedInCurrentThread;
        require(e == RgbaCompositeError.none,
            "two-layer linear-premultiplied source over");
        require(after == before,
            "hot source-over compositing allocated GC bytes");

        foreach (y; 0 .. roi.height)
        foreach (x; 0 .. roi.width)
        foreach (c; 0 .. 4)
        {
            double got;
            require(readback.trySample(c, x, y, got),
                "read full output image independently");
            const expected = referenceResult(
                c, roi.x + x, roi.y + y,
                treatment.fgSpace, treatment.fgAssociation,
                treatment.bgSpace, treatment.bgAssociation);
            const diff = got > expected ? got - expected : expected - got;
            require(diff <= 2e-11,
                "wrong alpha, source over order, sRGB gamma, or pixel position");
        }

        // A direct order diagnostic at two partly transparent layers.
        if (roi.x == 0 && roi.y == 0)
        {
            double measured;
            require(readback.trySample(0, 2, 1, measured),
                "read noncommutative witness");
            const reversed = referenceResult(
                0, 2, 1, treatment.fgSpace, treatment.fgAssociation,
                treatment.bgSpace, treatment.bgAssociation, true);
            const delta = measured > reversed
                ? measured - reversed : reversed - measured;
            require(delta > 0.001,
                "source-over order appears reversed/commutative");
        }

        enum double sentinel = -12345.0;
        foreach (c; 0 .. 4)
        foreach (y; 0 .. roi.height)
        foreach (x; 0 .. roi.width)
            require(output.trySetSample(c, x, y, sentinel),
                "write failure sentinel");

        // Error cases MUST NOT write a pixel:
        auto encodedAsPremultiplied = foreground;
        encodedAsPremultiplied.space = RgbaCompositeSpace.encodedSRgb;
        encodedAsPremultiplied.association =
            RgbaAlphaAssociation.premultiplied;
        require(tryCompositeSourceOver(
            encodedAsPremultiplied, background, roi, output)
            == RgbaCompositeError.invalidColourSemantics,
            "encoded premultiplied cannot masquerade as linear");
        assertUnchanged(readback, roi.width, roi.height, sentinel);

        require(tryCompositeSourceOver(
            foreground, background, Region2D(width, height, 1, 1), output)
            == RgbaCompositeError.invalidRegion,
            "out-of-bounds ROI");
        assertUnchanged(readback, roi.width, roi.height, sentinel);

        auto wrongDestLease = makeImage(
            Layout.planar, 0, RgbaCompositeSpace.linearSRgb,
            RgbaAlphaAssociation.premultiplied, 3,
            roi.width, roi.height, false);
        bool wrongOk;
        scope auto wrongDestination = wrongDestLease.tryWritableView(wrongOk);
        require(wrongOk, "wrong destination fixture");
        require(tryCompositeSourceOver(
            foreground, background, roi, wrongDestination)
            == RgbaCompositeError.destinationMismatch,
            "reject wrong 3-channel output");

        // Unusable alpha preflight is proved with a separate owner,
        // not by mutating a currently borrowed input source.
        auto badAlphaLease = makeImage(
            Layout.planar, 0, treatment.fgSpace,
            treatment.fgAssociation);
        bool badOk;
        scope auto badWriter = badAlphaLease.tryWritableView(badOk);
        require(badOk && badWriter.trySetSample(3, roi.x, roi.y, 1.25),
            "invalid alpha fixture");
        auto invalidTop = RgbaCompositeLayer(
            badAlphaLease.view(), treatment.fgSpace,
            treatment.fgAssociation);
        require(tryCompositeSourceOver(invalidTop, background, roi, output)
            == RgbaCompositeError.invalidAlpha,
            "preflight invalid alpha not rejected");
        assertUnchanged(readback, roi.width, roi.height, sentinel);

        if (treatment.fgAssociation ==
            RgbaAlphaAssociation.premultiplied)
        {
            auto badPremulLease = makeImage(
                Layout.planar, 0, treatment.fgSpace,
                treatment.fgAssociation);
            bool badPremulOk;
            scope auto badPremulWriter =
                badPremulLease.tryWritableView(badPremulOk);
            // x=0,y=0 in foreground fixture has exact alpha zero.
            // Deliberately violate canonical transparent premultiplied RGB.
            require(badPremulOk &&
                badPremulWriter.trySetSample(0, 0, 0, 0.5),
                "noncanonical premultiplied fixture");
            auto invalidPremul = RgbaCompositeLayer(
                badPremulLease.view(), treatment.fgSpace,
                treatment.fgAssociation);
            const Region2D whole = Region2D(0, 0, width, height);
            // The full image has the right destination shape.
            // This is a malformed pixel, NOT a wrong-output-size case.
            if (roi.x == 0 && roi.y == 0)
            {
                require(tryCompositeSourceOver(
                    invalidPremul, background, whole, output)
                    == RgbaCompositeError.invalidPremultiplied,
                    "reject noncanonical transparent premultiplied sample");
                assertUnchanged(readback, roi.width, roi.height, sentinel);
            }
        }
    }
}

void runImageCompositionConsumer()
{
    enum E = RgbaCompositeSpace.encodedSRgb;
    enum L = RgbaCompositeSpace.linearSRgb;
    enum S = RgbaAlphaAssociation.straight;
    enum P = RgbaAlphaAssociation.premultiplied;
    const Treatment[8] policies = [
        Treatment(E,S,E,S), Treatment(L,S,L,S),
        Treatment(L,P,L,S), Treatment(L,S,L,P),
        Treatment(L,P,L,P), Treatment(E,S,L,P),
        Treatment(L,P,E,S), Treatment(L,S,E,S)
    ];
    foreach (layout; [Layout.planar, Layout.interleaved])
    foreach (destinationLayout; [Layout.planar, Layout.interleaved])
    foreach (policy; policies)
        exercise(layout, destinationLayout, policy);

    import std.stdio : writeln;
    writeln("M3 composition PASS: 96 full linear-premultiplied outputs, "
        ~ "independent all-pixel Porter-Duff and sRGB oracle, "
        ~ "alpha validation and zero compositing GC");
}

version (M3_COMPOSITE_NEGATIVE_LOCAL_LEASE_ESCAPE)
{
    @safe RgbaCompositeLayer illegalEscapedLayer()
    {
        RasterLease!double local;
        return RgbaCompositeLayer(
            local.view(), RgbaCompositeSpace.linearSRgb,
            RgbaAlphaAssociation.straight);
    }
}
