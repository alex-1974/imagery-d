# Scalar Levels on already-decoded images (v0.1.0)

This tutorial describes the **v0.1.0 source API**. DUB registry
installation is available only after the package has been registered. `imagery-d` performs image-domain computation.
A separate decoder/consumer owns the input image and must expose a
valid `raster-d` `RasterView`; imagery-d does not currently decode files.

## Basic operation

```d
import imagery : Levels, LevelsError, tryLevelsOwned;
import raster : RasterLease, RasterView, Region2D;

// The owner of decodedRGB must outlive this borrowed input view.
@safe LevelsError adjustRGB(
    scope RasterView!ubyte decodedRGB,
    size_t newPixelBudget,
    ref RasterLease!float published)
{
    bool[3] selected = [true, true, false];
    auto roi = Region2D(0, 0, decodedRGB.width, decodedRGB.height);
    return tryLevelsOwned!ubyte(
        decodedRGB, roi, selected[],
        Levels(0, 1, 2, 0, 1),
        newPixelBudget, published);
}
```

The first and second channels are edited (gamma 2); the third is copied
numerically. The result has the same number of channels and ROI size,
but is always a **new interleaved `RasterLease!float`**. It is never
implicitly quantized to 8-bit, sRGB-encoded or saved to an image file.
A photo or GIS consumer decides those later presentation steps.

## Important caller responsibilities

- **Input domain:** `ubyte` and `ushort` normalize by 255/65535;
  `float` uses its existing numeric values. Thresholds are expressed
  in the corresponding normalized/intended float domain.
- **Parameters:** inputBlack/inputWhite are finite with black < white;
  gamma is finite and strictly positive; outputBlack/outputWhite are
  finite and ordered in [0,1]. Invalid `Levels.init` is rejected.
- **ROI:** a nonempty source-bounded `Region2D`. The new result
  starts at local (0,0) and has ROI width/height.
- **Selection of channels:** `affected` contains one Boolean per
  plane. There is **no automatic alpha preservation**; leave alpha
  unselected if it should pass through.
- **Optional edit mask:** the second overload additionally takes
  `scope RasterView!ubyte selection` before the budget argument.
  It must have exactly one plane and full-source dimensions. A mask
  byte of 0 passes the sample unchanged; 255 uses the complete mapped
  value; intermediate bytes blend linearly. This is **not** NoData,
  transparency, or a scientific validity mask.
- **Output budget:** `maxResultBytes` must cover exactly the NEW
  `ROI.width * ROI.height * source.planeCount * float.sizeof` pixel
  payload. The input, old published owner, allocation metadata and
  total process RSS are NOT bounded by this argument.
- **Result status:** only `LevelsError.none` means success.
  `LevelsError.init == notAttempted` means no attempt. On a
  normally returned error the existing `published` owner is unchanged.
  A runtime OOM `Error` is **not** guaranteed recoverable.
- **Safety:** both overloads are `@safe`, but neither `nothrow` nor
  `@nogc`. Do not mutate shared raster storage concurrently or
  allow borrowed views to outlive their owner.

For concrete image-file I/O, the repository includes a **consumer-only**
binary P6 example in `tests/ppm_consumer`. It is not a production decoder
dependency of `imagery-d`. For the exact API and its evidence see
[ADR 0006](../adr/0006-first-owned-levels-public-api-admission.md) and
[Levels audit](../m3-levels-api-audit-2026-10-20.md).

v0.1.0 is a pre-1.0 release and does not promise a stable ABI or
source compatibility across future minor versions.
