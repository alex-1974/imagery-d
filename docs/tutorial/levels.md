# Adjust selected channels with Levels

Use `tryLevelsOwned` to adjust black point, white point and gamma on decoded
raster channels. It reads a borrowed input view and returns a new float raster.
This example uses imagery-d and raster-d; it edits red and green while copying
blue numerically.

## Run the example

Follow [installation](../how-to/install.md), then replace the application's
`source/app.d` with this program. Run it with `dub run` so the assertions execute.
The small `makeRgb` function creates test pixels through raster-d; a decoder
would normally supply the input owner.

```d
import imagery : Levels, LevelsError, tryLevelsOwned;
import raster : OwnedByteResource, PlaneByteLayout, RasterLease,
    RasterView, Region2D, tryAdoptMallocResource, tryImportOwnedRaster;
import core.stdc.stdlib : malloc, free;
import std.exception : enforce;
import std.math : abs;

// Adopting raw malloc storage is raster-d's explicit @system ownership boundary.
RasterLease!ubyte makeRgb() @system
{
    void* memory = malloc(6);
    enforce(memory !is null);
    OwnedByteResource owner;
    if (!tryAdoptMallocResource(memory, 6, owner))
    {
        free(memory);
        throw new Exception("Cannot adopt the example pixels");
    }
    const PlaneByteLayout[3] planes = [
        PlaneByteLayout(0, 6, 3), PlaneByteLayout(1, 6, 3), PlaneByteLayout(2, 6, 3)
    ];
    RasterLease!ubyte image;
    enforce(tryImportOwnedRaster!ubyte(owner, planes[], Region2D(0, 0, 2, 1), image).ok);
    {
        bool canWrite;
        scope auto view = image.tryWritableView(canWrite);
        enforce(canWrite);
        foreach (channel; 0 .. 3)
        {
            enforce(view.trySetSample(channel, 0, 0, 64));
            enforce(view.trySetSample(channel, 1, 0, 128));
        }
    }
    return image;
}

LevelsError adjustRgb(scope RasterView!ubyte input, size_t budget,
    ref RasterLease!float output) @safe
{
    bool[3] selected = [true, true, false];
    return tryLevelsOwned!ubyte(input, Region2D(0, 0, 2, 1), selected[],
        Levels(0, 1, 2, 0, 1), budget, output);
}

void main() @system
{
    auto input = makeRgb();
    RasterLease!float output;
    enum budget = 2 * 1 * 3 * float.sizeof;
    enforce(adjustRgb(input.view(), budget, output) == LevelsError.none);
    {
        scope auto view = output.view();
        float red, blue;
        enforce(view.trySample(0, 0, 0, red));
        enforce(view.trySample(2, 0, 0, blue));
        enforce(red > blue); // Gamma brightens selected red; blue passes through.
        enforce(abs(blue - 64 / 255.0f) < 1e-6f);
    }
    enforce(adjustRgb(input.view(), budget - 1, output)
        == LevelsError.resultExceedsBudget);
    scope auto retained = output.view();
    enforce(retained.width == 2 && retained.height == 1);
}
```

The `@system` setup is limited to adopting caller-owned raw storage. The
processing function `adjustRgb` is `@safe`. For production input, use the
storage/decoding boundary appropriate to the application; do not add a trust
annotation to bypass an ownership check.

## Interpret the result

The output is a new interleaved `RasterLease!float`, with the ROI's width and
height and local origin `(0,0)`. Integer input is normalized by 255 or 65535;
float input uses its declared numeric domain. Levels does not implicitly
sRGB-encode, quantize or save that result.

Only `LevelsError.none` means success. The default error is `notAttempted`.
On a normally returned error the previous output owner is preserved; this
is why the second request in the example still leaves a readable result.

## Supply parameters and storage

- Keep the input owner alive while the borrowed view is read.
- Select one Boolean per channel. Leave alpha unselected when it should pass
  through; channel roles are not inferred.
- Supply a nonempty source-bounded ROI. Input black/white points must be finite
  and increasing, gamma finite and positive, and output bounds ordered in `[0,1]`.
  `Levels.init` is invalid.
- Budget the new float pixel payload: ROI width times height times channel
  count times `float.sizeof`. This does not bound the input, an older result,
  allocator metadata or total process memory.

The mask overload adds a full-source, single-plane byte edit-selection mask.
Zero preserves a sample, 255 applies the complete mapping, and intermediate
bytes blend the two. This is edit coverage, not alpha or a NoData declaration.
See [mask roles](../concepts/image-data.md#three-kinds-of-masks).

The operation can allocate and has no universal `nothrow`/`@nogc` or concurrent
mutation guarantee. The [versioned Levels reference](https://alex-1974.github.io/imagery-d/v0.4.0/imagery/presentation/levels/tryLevelsOwned.html)
is the complete contract.
