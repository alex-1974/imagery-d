/++
Place one normalized RGBA image or pixel over another using explicit alpha.
Use `sourceOver` for scalar RGBA values and `tryRgbaSourceOverOwned` for an
owned raster result. Declare whether RGB is straight or premultiplied and
choose a blend mode when needed.
+/
module imagery.compositing.source_over;

import core.stdc.stdlib : malloc, free;
import raster : OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;
import std.math : isFinite;

/++
 Declare straight versus premultiplied RGB. `.init` selects straight; the operation does not infer association from sample values.
+/
enum AlphaAssociation : ubyte {
    /++ Unassociated RGB with independent alpha. +/
    straight,
    /++ RGB components already multiplied by alpha. +/
    premultiplied }
/++
 Choose the color blend applied before source-over. `.init` is normal.
+/
enum BlendMode : ubyte {
    /++ Use the source channel unchanged before compositing. +/
    normal,
    /++ Multiply source and destination channels. +/
    multiply,
    /++ One minus the product of inverse channels. +/
    screen,
    /++ Use the smaller channel. +/
    darken,
    /++ Use the larger channel. +/
    lighten }
/++
 Report compositing status. `.init` is none, which is also the success return; a default value does not prove execution.
+/
enum SourceOverError : ubyte {
    /++ Compositing succeeded. +/
    none,
    /++ Invalid alpha or raster request/materialization parameters. +/
    invalidParameters,
    /++ A color component is nonfinite or outside [0,1]. +/
    nonFiniteSample }

/++
 Supply normalized red, green, blue and alpha. `.init` contains NaN fields and is not a valid pixel. Association is supplied separately.
+/
struct RgbaNormalized
{
    /// Finite normalized red component in [0,1].
    double r;
    /// Finite normalized green component in [0,1].
    double g;
    /// Finite normalized blue component in [0,1].
    double b;
    /// Finite alpha coverage in [0,1]; association is declared separately.
    double a;
}

/// Composite straight alpha and inspect the status before reading the output.
@safe unittest
{
    RgbaNormalized result;
    auto status=sourceOver(RgbaNormalized(1,0,0,0.5),
        RgbaNormalized(0,0,1,1),AlphaAssociation.straight,result);
    assert(status==SourceOverError.none);
    assert(result.r==0.5 && result.b==0.5 && result.a==1);
    status=sourceOver(RgbaNormalized(1,0,0,2),
        RgbaNormalized(0,0,1,1),AlphaAssociation.straight,result);
    assert(status==SourceOverError.invalidParameters);
}


/++
 Blend two numeric color channels without alpha compositing or validation.

 Params:
  source = Source channel in the caller-selected color domain.
  destination = Destination channel in the same domain.
  mode = Normal, multiply, screen, darken or lighten.

 Returns:
 The chosen blend formula; normal and unknown modes return source.
+/
double blendChannel(double source, double destination, BlendMode mode)
@safe pure nothrow @nogc
{
    final switch (mode)
    {
        case BlendMode.normal: return source;
        case BlendMode.multiply: return source * destination;
        case BlendMode.screen: return 1.0 - (1.0 - source) * (1.0 - destination);
        case BlendMode.darken: return source < destination ? source : destination;
        case BlendMode.lighten: return source > destination ? source : destination;
    }
}

private bool inUnit(double value) @safe pure nothrow @nogc
{
    return isFinite(value) && value >= 0.0 && value <= 1.0;
}

/++
 Composite one normalized source pixel over a destination pixel.

  Association is supplied explicitly; no transfer-function conversion occurs.
  For straight samples, RGB is divided by output alpha; zero output alpha yields
  transparent black. Premultiplied samples use source RGB plus destination RGB
  scaled by one minus source alpha. The operation validates component ranges but
  does not enforce RGB<=alpha for premultiplied samples. Only declared enum values
  are supported; unknown association values currently follow the straight branch.

 Params:
  source = Input data; its sample model, units and lifetime follow the operation contract above.
  destination = Caller-owned output storage, or the destination pixel/raster for compositing.
  association = Explicit straight or premultiplied alpha association; no automatic conversion.
  result = Output parameter receiving the result described above.

 Returns:
 none on success, invalidParameters for alpha outside [0,1] or nonfinite
  alpha, and nonFiniteSample for RGB outside [0,1] or nonfinite RGB. The out result
  is reset to RgbaNormalized.init on entry and remains so on validation failure.
+/
SourceOverError trySourceOver(
    RgbaNormalized source,
    RgbaNormalized destination,
    AlphaAssociation association,
    out RgbaNormalized result)
@safe pure nothrow @nogc
{
    if (!inUnit(source.a) || !inUnit(destination.a))
        return SourceOverError.invalidParameters;
    if (!inUnit(source.r) || !inUnit(source.g) || !inUnit(source.b) ||
        !inUnit(destination.r) || !inUnit(destination.g) || !inUnit(destination.b))
        return SourceOverError.nonFiniteSample;
    const inverse = 1.0 - source.a;
    const outA = source.a + destination.a * inverse;
    if (association == AlphaAssociation.premultiplied)
    {
        result = RgbaNormalized(
            source.r + destination.r * inverse,
            source.g + destination.g * inverse,
            source.b + destination.b * inverse, outA);
    }
    else
    {
        if (outA == 0.0) { result = RgbaNormalized(0, 0, 0, 0); return SourceOverError.none; }
        result = RgbaNormalized(
            (source.r * source.a + destination.r * destination.a * inverse) / outA,
            (source.g * source.a + destination.g * destination.a * inverse) / outA,
            (source.b * source.a + destination.b * destination.a * inverse) / outA, outA);
    }
    return SourceOverError.none;
}

/++
 Blend source color channels, then composite source over destination.

   Use normal for ordinary source-over. Association is explicit and is not
   changed automatically. The formulas operate in the supplied numeric space.

 Params:
  source = Normalized source RGBA sample.
  destination = Normalized destination RGBA sample.
  association = Straight or premultiplied representation.
  mode = Channel blend mode.
  result = Receives the composite; reset to RgbaNormalized.init on entry.

 Returns:
 none on success, invalidParameters for invalid alpha, or nonFiniteSample for invalid color components.
+/
SourceOverError tryBlendSourceOver(
    RgbaNormalized source, RgbaNormalized destination,
    AlphaAssociation association, BlendMode mode,
    out RgbaNormalized result)
@safe pure nothrow @nogc
{
    if (mode == BlendMode.normal)
        return trySourceOver(source, destination, association, result);
    RgbaNormalized blended = source;
    blended.r = blendChannel(source.r, destination.r, mode);
    blended.g = blendChannel(source.g, destination.g, mode);
    blended.b = blendChannel(source.b, destination.b, mode);
    return trySourceOver(blended, destination, association, result);
}

/++
 Composite with explicit validity flags. Validity is not alpha and is never
    inferred from the pixel values. An invalid source contributes nothing; when
    only one contributor is valid, that contributor is returned unchanged.

 Params:
  source = Input data; its sample model, units and lifetime follow the operation contract above.
  sourceValid = Whether the source sample is present, independently of alpha.
  destination = Caller-owned output storage, or the destination pixel/raster for compositing.
  destinationValid = Whether the destination sample is present, independently of alpha.
  association = Explicit straight or premultiplied alpha association; no automatic conversion.
  result = Output parameter receiving the result described above.
  resultValid = Receives contributor validity; reset to false on entry and may change before a later reported error.

 Returns:
 The named operation status; none denotes success. Inspect the error before using outputs.
+/
SourceOverError tryValidityAwareSourceOver(
    RgbaNormalized source, bool sourceValid,
    RgbaNormalized destination, bool destinationValid,
    AlphaAssociation association,
    out RgbaNormalized result, out bool resultValid)
@safe pure nothrow @nogc
{
    if (!sourceValid && !destinationValid)
    {
        result = RgbaNormalized(0, 0, 0, 0);
        resultValid = false;
        return SourceOverError.none;
    }
    if (!sourceValid) { result = destination; resultValid = true; return SourceOverError.none; }
    if (!destinationValid) { result = source; resultValid = true; return SourceOverError.none; }
    resultValid = true;
    return trySourceOver(source, destination, association, result);
}

private bool ownedBytes(size_t bytes, ref OwnedByteResource owner)
@trusted nothrow @nogc
{
    auto p = malloc(bytes);
    if (p is null) return false;
    if (!tryAdoptMallocResource(p, bytes, owner)) { free(p); return false; }
    return true;
}

/++
 Create an independent packed RGBA8 source-over result for a pixel region.

   Inputs are borrowed for this call. Association is explicit; the operation
   normalizes byte samples and does not perform a color transfer conversion.
   The result is replaced only after all requested pixels have been produced;
   a reported failure leaves the previous result unchanged. See trySourceOver
   for scalar math and tryValidityAwareSourceOver for contributor selection.

 Params:
  source = Input data; its sample model, units and lifetime follow the operation contract above.
  destination = Caller-owned output storage, or the destination pixel/raster for compositing.
  roi = Nonempty half-open source-pixel rectangle, fully contained in the input.
  association = Explicit straight or premultiplied alpha association; no automatic conversion.
  maxResultBytes = Maximum requested retained output pixel/payload bytes, excluding allocator overhead unless stated above.
  published = Output parameter; the operation-specific success and failure-state rules above apply.

 Returns:
 none on success, otherwise invalidParameters or a sample failure.

 Throws:
 Metadata allocation exceptions may propagate.
+/
SourceOverError tryRgbaSourceOverOwned(
    scope RasterView!ubyte source,
    scope RasterView!ubyte destination,
    Region2D roi,
    AlphaAssociation association,
    size_t maxResultBytes,
    ref RasterLease!ubyte published)
@safe
{
    return tryRgbaSourceOverOwnedMode(source, destination, roi,
        association, BlendMode.normal, maxResultBytes, published);
}

/++
 Create an independent packed RGBA8 source-over result for a pixel region.

   Inputs are borrowed for this call. Association is explicit; the operation
   normalizes byte samples and does not perform a color transfer conversion.
   The result is replaced only after all requested pixels have been produced;
   a reported failure leaves the previous result unchanged. See trySourceOver
   for scalar math and tryValidityAwareSourceOver for contributor selection.

 Params:
  source = Input data; its sample model, units and lifetime follow the operation contract above.
  destination = Caller-owned output storage, or the destination pixel/raster for compositing.
  roi = Nonempty half-open source-pixel rectangle, fully contained in the input.
  association = Explicit straight or premultiplied alpha association; no automatic conversion.
  mode = Explicit blend or materialization mode.
  maxResultBytes = Maximum requested retained output pixel/payload bytes, excluding allocator overhead unless stated above.
  published = Output parameter; the operation-specific success and failure-state rules above apply.

 Returns:
 none on success, otherwise invalidParameters or a sample failure.

 Throws:
 Metadata allocation exceptions may propagate.
+/
SourceOverError tryRgbaSourceOverOwnedMode(
    scope RasterView!ubyte source,
    scope RasterView!ubyte destination,
    Region2D roi,
    AlphaAssociation association,
    BlendMode mode,
    size_t maxResultBytes,
    ref RasterLease!ubyte published)
@safe
{
    if (source.planeCount != 4 || destination.planeCount != 4 ||
        source.width == 0 || source.height == 0 ||
        destination.width != source.width || destination.height != source.height)
        return SourceOverError.invalidParameters;
    if (roi.width == 0 || roi.height == 0 || roi.x > source.width ||
        roi.y > source.height || roi.width > source.width - roi.x ||
        roi.height > source.height - roi.y)
        return SourceOverError.invalidParameters;
    if (roi.width > size_t.max / roi.height ||
        roi.width * roi.height > size_t.max / 4)
        return SourceOverError.invalidParameters;
    const bytes = roi.width * roi.height * 4;
    if (bytes > maxResultBytes) return SourceOverError.invalidParameters;
    OwnedByteResource owner;
    if (!ownedBytes(bytes, owner)) return SourceOverError.invalidParameters;
    PlaneByteLayout[4] layouts;
    foreach (c; 0 .. 4) layouts[c] = PlaneByteLayout(c,
        cast(ptrdiff_t)(roi.width * 4), 4);
    RasterLease!ubyte temporary;
    if (!tryImportOwnedRaster!ubyte(owner, layouts[],
        Region2D(0, 0, roi.width, roi.height), temporary).ok)
        return SourceOverError.invalidParameters;
    bool writable;
    scope auto output = temporary.tryWritableView(writable);
    if (!writable) return SourceOverError.invalidParameters;
    foreach (y; roi.y .. roi.y + roi.height)
    foreach (x; roi.x .. roi.x + roi.width)
    {
        RgbaNormalized s, d, composited;
        ubyte sr, sg, sb, sa, dr, dg, db, da;
        if (!source.trySample(0, x, y, sr) || !source.trySample(1, x, y, sg) ||
            !source.trySample(2, x, y, sb) || !source.trySample(3, x, y, sa) ||
            !destination.trySample(0, x, y, dr) || !destination.trySample(1, x, y, dg) ||
            !destination.trySample(2, x, y, db) || !destination.trySample(3, x, y, da))
            return SourceOverError.nonFiniteSample;
        s = RgbaNormalized(sr / 255.0, sg / 255.0, sb / 255.0, sa / 255.0);
        d = RgbaNormalized(dr / 255.0, dg / 255.0, db / 255.0, da / 255.0);
        auto status = tryBlendSourceOver(s, d, association, mode, composited);
        if (status != SourceOverError.none) return status;
        if (!output.trySetSample(0, x - roi.x, y - roi.y, cast(ubyte)(composited.r * 255.0 + 0.5)) ||
            !output.trySetSample(1, x - roi.x, y - roi.y, cast(ubyte)(composited.g * 255.0 + 0.5)) ||
            !output.trySetSample(2, x - roi.x, y - roi.y, cast(ubyte)(composited.b * 255.0 + 0.5)) ||
            !output.trySetSample(3, x - roi.x, y - roi.y, cast(ubyte)(composited.a * 255.0 + 0.5)))
            return SourceOverError.nonFiniteSample;
    }
    published = temporary;
    return SourceOverError.none;
}

/++
 Create an independent packed RGBA8 source-over result for a pixel region.

   Inputs are borrowed for this call. Association is explicit; the operation
   normalizes byte samples and does not perform a color transfer conversion.
   The result is replaced only after all requested pixels have been produced;
   a reported failure leaves the previous result unchanged. See trySourceOver
   for scalar math and tryValidityAwareSourceOver for contributor selection.

 Params:
  source = Input data; its sample model, units and lifetime follow the operation contract above.
  destination = Caller-owned output storage, or the destination pixel/raster for compositing.
  sourceValidity = Single-plane byte validity raster matching the source grid; nonzero is valid.
  destinationValidity = Single-plane byte validity raster matching the destination grid; nonzero is valid.
  roi = Nonempty half-open source-pixel rectangle, fully contained in the input.
  association = Explicit straight or premultiplied alpha association; no automatic conversion.
  mode = Explicit blend or materialization mode.
  maxResultBytes = Maximum requested retained output pixel/payload bytes, excluding allocator overhead unless stated above.
  published = Output parameter; the operation-specific success and failure-state rules above apply.

 Returns:
 none on success, otherwise invalidParameters or a sample failure.

 Throws:
 Metadata allocation exceptions may propagate.
+/
SourceOverError tryRgbaSourceOverOwnedValidity(
    scope RasterView!ubyte source, scope RasterView!ubyte destination,
    scope RasterView!ubyte sourceValidity, scope RasterView!ubyte destinationValidity,
    Region2D roi, AlphaAssociation association, BlendMode mode,
    size_t maxResultBytes, ref RasterLease!ubyte published)
@safe
{
    if (sourceValidity.planeCount != 1 || destinationValidity.planeCount != 1 ||
        sourceValidity.width != source.width || sourceValidity.height != source.height ||
        destinationValidity.width != source.width || destinationValidity.height != source.height)
        return SourceOverError.invalidParameters;
    RasterLease!ubyte result;
    auto status = tryRgbaSourceOverOwnedMode(source, destination, roi, association, mode, maxResultBytes, result);
    if (status != SourceOverError.none) return status;
    bool writable;
    scope auto output = result.tryWritableView(writable);
    if (!writable) return SourceOverError.invalidParameters;
    foreach (y; roi.y .. roi.y + roi.height)
    foreach (x; roi.x .. roi.x + roi.width)
    {
        ubyte sv, dv;
        if (!sourceValidity.trySample(0, x, y, sv) || !destinationValidity.trySample(0, x, y, dv))
            return SourceOverError.nonFiniteSample;
        if (sv != 0 && dv != 0) continue;
        if (sv == 0 && dv == 0)
        {
            foreach (c; 0 .. 4) if (!output.trySetSample(c, x - roi.x, y - roi.y, 0)) return SourceOverError.nonFiniteSample;
            continue;
        }
        auto validView = sv != 0 ? source : destination;
        foreach (c; 0 .. 4)
        {
            ubyte value;
            if (!validView.trySample(c, x, y, value) || !output.trySetSample(c, x - roi.x, y - roi.y, value))
                return SourceOverError.nonFiniteSample;
        }
    }
    published = result;
    return SourceOverError.none;
}

unittest
{
    RgbaNormalized result;
    assert(trySourceOver(RgbaNormalized(1, 0, 0, 1),
        RgbaNormalized(0, 0, 1, 1), AlphaAssociation.straight, result) == SourceOverError.none);
    assert(result.r == 1 && result.b == 0 && result.a == 1);
    assert(trySourceOver(RgbaNormalized(1, 1, 1, 0),
        RgbaNormalized(0.2, 0.3, 0.4, 0), AlphaAssociation.straight, result) == SourceOverError.none);
    assert(result.a == 0);
    assert(blendChannel(0.25, 0.5, BlendMode.multiply) == 0.125);
    assert(blendChannel(0.25, 0.5, BlendMode.screen) == 0.625);
    assert(blendChannel(0.25, 0.5, BlendMode.darken) == 0.25);
    assert(blendChannel(0.25, 0.5, BlendMode.lighten) == 0.5);
    bool resultValid;
    assert(tryValidityAwareSourceOver(RgbaNormalized(1, 0, 0, 1), false,
        RgbaNormalized(0.2, 0.3, 0.4, 1), true, AlphaAssociation.straight,
        result, resultValid) == SourceOverError.none && resultValid && result.r == 0.2);
    assert(tryValidityAwareSourceOver(RgbaNormalized.init, false,
        RgbaNormalized.init, false, AlphaAssociation.straight,
        result, resultValid) == SourceOverError.none && !resultValid);
}

/++
 Preferred spelling of trySourceOver; shares its association and out-parameter contract.
+/
alias sourceOver = trySourceOver;
/++
 Preferred spelling of tryBlendSourceOver; shares its blend and error contract.
+/
alias blendSourceOver = tryBlendSourceOver;
/++
 Preferred spelling of tryValidityAwareSourceOver; validity is independent of alpha.
+/
alias validityAwareSourceOver = tryValidityAwareSourceOver;
