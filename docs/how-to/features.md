# Request reusable image features

Use the region engine when several operations should share the same source
reads and prepared data. Import `imagery.analysis.feature_regions` directly.
Use [ordinary array operators](choose-an-api.md) for a single small filter that
does not need source identity, region requests or reusable engine storage.

## Supply pixels and identify their revision

`Source.read` fills the requested row-major `Sample` buffer synchronously.
Give the source a stable identity, a revision that changes with pixels/validity,
an alignment grid, a band and a unit. Width/height count source-grid pixels;
`level` is a caller-selected identifier.

This complete example reads a constant 3-by-3 scalar image and copies the
borrowed float32 output before the engine can reuse it:

```d
import imagery.analysis.feature_regions : Engine, Feature, Source, Sample,
    Provenance, FeaturePlanes32;
import raster : Region2D;

void main() @safe
{
    Source source;
    source.identity = "constant-image";
    source.revision = "1";
    source.grid = "pixel-grid";
    source.band = "intensity";
    source.unit = "relative";
    source.width = source.height = 3;
    source.read = (Region2D region, scope Sample[] samples) @safe {
        foreach (ref sample; samples)
            sample = Sample(1, [0, 0, 0], true);
    };

    Engine engine;
    engine.reservePlanar();
    float[9] retained;
    size_t received;
    engine.runPlanar(source, Region2D(0, 0, 3, 3), Feature.luminance, 3,
        (Region2D tile, scope const FeaturePlanes32 planes, Provenance origin) @safe {
            retained[] = planes.channels[0][];
            received = planes.validity.length;
            assert(origin.identity == "constant-image" && tile.width == 3);
        });
    assert(received == 9 && retained[4] == 1);
}
```

Change the revision when an input pixel or validity changes. Reusing a revision
after editing pixels can reuse an obsolete cache entry. Encoded RGB8 sources
also declare that sample model; scalar operators do not infer color or
spectral roles from channel order.

## Choose output and parameter forms

| Need | Entry point |
| --- | --- |
| Ordinary float64 feature results | `Engine.run` or `runFeatureView` |
| Explicit float32 planes | `Engine.runPlanar` / `runPlanarView` |
| Several parameter families sharing preparation | `FeatureViewParams` with `runFeatureView` |
| Cooperative priority/cancellation and shared requests | `FeatureRequests` |
| Prepared scalar tiles over raster plane windows | `Float32FeatureWorker` |

Read `describeFeature` for channel order, units, validity, dependencies and
supported parameter types. Supply typed local-window, path, ridge, line, Gabor,
shadow or CLAHE settings through the matching interface. A feature's halo is
the neighboring border required by those settings, not a guessed constant.

Float32 output is an explicit representation choice. Full-precision
dependencies remain float64 where the operation contract requires them.
`prepareGaussian32` selects a separate approximate arithmetic path; it is not
implied by asking for float32 output.

## Handle lifetimes, errors and budgets

Copy borrowed planes/values within the callback to retain a snapshot. Prepared
worker output is invalidated by the next successful evaluation or preparation.
Keep source data stable during borrowed reads, and do not store a callback's
temporary window for later use.

Check sample validity before using result channels, and orientation validity
before interpreting a direction. A zero response need not define an orientation.

The engine accepts explicit preparation/cache limits; read their accounting
scope rather than treating them as total process-memory limits. Reader or sink
exceptions can propagate after earlier tiles have been delivered. If an
application needs all-or-nothing publication across an entire multi-tile ROI,
it must collect results privately before publishing that larger application result.
