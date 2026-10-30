# imagery-d

`imagery-d` is a general-purpose **image-processing library for D** in the
`d-geospatial-workspace`. It is intended for photo/graphics editors,
scientific image analysis and GIS/remote-sensing applications alike.

Its central responsibility is **computing on image data**. Consumers are
responsible for the origin and factual/domain-specific interpretation of their
inputs (for example, sensor calibration, STAC metadata, image registration or
satellite processing baseline). Generic filters, tone operations, image
transforms, statistics and compositing must not require satellite/geospatial
metadata. The library still guarantees correctness and safety of the operations
it implements for declared inputs and parameters.

See [the scope clarification](docs/research/general-image-processing-scope-correction-2026-10-17.md)
for the core/consumer separation; specialist metadata remains optional.

**v0.1.0** is the first release of the general-purpose imagery-d source
library. It provides a scalar Levels operator on already-decoded rasters;
ADR 0005 defines the general image domain, ADR 0004 selected the first
operation, and ADR 0006 accepted its public source contract.
The v0.2.0 source set adds RGB8 histograms, derived tone LUTs and
percentile luminance stretch under ADRs 0007–0011.
It is published as a
[GitHub source release](https://github.com/alex-1974/imagery-d/releases/tag/v0.2.0).

**Supported baseline:** Linux x86-64 (tested on Ubuntu 24.04 with
DMD 2.111/2.113 and LDC 1.41/1.43). macOS and Windows had successful
consumer smoke tests but remain **best effort**, not officially qualified
release platforms. As a **pre-1.0** package, source compatibility may
change in future minor releases; no stable ABI is promised.

See the [changelog](CHANGELOG.md) and
[GitHub releases](https://github.com/alex-1974/imagery-d/releases) for
versioned source archives.
The package is not registered on DUB. Registration is planned for v1.0.0,
unless a concrete earlier need arises. Use the GitHub source release until
then; `dub fetch imagery-d` does not resolve from the registry.

## Relationship to raster-d

The dependency direction is:

```text
imagery-d
    |
    v
 raster-d
```

`raster-d` owns generic raster mechanics.

`imagery-d` owns semantics and processing that exist because the data is an
image, remote-sensing product, or imagery pipeline.

### raster-d retains

- raster regions/extents;
- sample/plane/layout and stride/interleaving mechanics;
- ownership, leases and borrowing;
- read-only and writable raster views;
- generic copy/fill/conversion;
- generic reductions;
- alias and physical-range analysis;
- generic dependency/halo mechanics;
- generic tile/window/streaming contracts;
- bounded-residency execution;
- generic cache primitives.

### imagery-d owns or researches

- image and pixel-format semantics;
- channel and colour semantics;
- radiometric processing;
- colour/exposure/radiometric normalization;
- image filters and neighbourhood operators;
- mosaics and image pyramids;
- image-quality analysis;
- imagery-specific source/cache policy;
- image-oriented scheduling and progressive refinement;
- imagery-specific geospatial metadata integration;
- imagery benchmark corpus management;
- later feature extraction, segmentation and ML-assisted interpretation.

Generic raster functionality must not be reimplemented here merely for API
convenience.

## Origin

The original repository named `imagery-d` evolved into a generic raster engine.

On 2026-09-22 that repository and its history were deliberately pivoted to
`raster-d`.

This repository is the new higher-level image-domain consumer anticipated by
that pivot. It does not inherit ownership of the generic raster core.

Relevant historical evidence remains in the `raster-d` repository, including
its pre-pivot architecture, research, benchmarks and ADRs.

## Current status

**M1 / M2 ARCHITECTURE ACCEPTED — v0.2.0 RGB SOURCE SET**

M1 established the image semantic core and is accepted by
`docs/adr/0002-image-semantic-core.md`.

M2 established the source/resource/materialization/cache/request architecture
and is accepted by
`docs/adr/0003-source-cache-pipeline-architecture.md`.

The published v0.1.0 tag contains scalar Levels. This source tree also
contains the accepted RGB analysis and luminance APIs intended for v0.2.0,
without copying the experimental M1/M2 research architecture. Consult the
GitHub releases for publication status; no pre-1.0 compatibility freeze is
implied.

M3 completed the first concrete production vertical slice with an
independently tested scalar Levels API. ADRs 0007–0011 additionally admit
the current RGB source APIs; source/cache functionality remains separate
future work.

Passing M1 and M2 does not itself authorize a speculative general
source/cache framework.

## RGB histogram and ROI statistics

`imagery.analysis.rgb_histogram` (also available through `import imagery`)
provides `RgbHistogram256`, `RgbHistogramError` and masked/unmasked
`tryRgbHistogram256` under accepted [ADR 0007](docs/adr/0007-rgb-histogram-and-statistics.md).
It counts exactly three stored-byte R/G/B channels over a nonempty ROI,
with per-channel minimum, maximum and arithmetic mean. An optional binary
selection mask excludes zero and includes every nonzero byte once, unlike
Levels' fractional editing mask. All-excluded selections succeed with
zero statistics; returned errors preserve the caller's prior result.

This source tree requires raster-d v0.5.x and reuses its generic
`histogram256` for unmasked counting. The RGB API is not part of published
imagery-d v0.1.0. See its Ddoc for the compiled two-pixel example.

`tryRgbCumulativeCounts` derives exact inclusive counts through each byte
value. `tryRgbPercentile` returns an integer 0–100 nearest-rank percentile
per channel from the same result, without another image traversal. It uses
stored RGB bytes; an empty selection has no percentile. Both functions
reject inconsistent caller-modified histogram records and preserve output
on failure.

`tryRgbPercentileStretchLut` builds a 3×256-byte contrast map from two
selected percentiles. Each channel stretches its observed lower/upper bytes
to 0/255 with exact nearest-integer interpolation; a channel whose bounds
coincide gets an identity map. A histogram mask controls threshold estimation
only. The caller chooses which pixels receive the map, so applying a masked
histogram to an image does not silently change the editing-selection rule.

`tryRgbEqualizationLut` builds an alternative 3×256-byte map from the exact
per-channel cumulative counts. It maps the first observed value to zero and
the final observed value to 255, with nearest-integer CDF scaling. Constant
channels retain an identity map. The map is computed on stored RGB bytes;
independent channel equalization can change colour relationships. The P6
consumer demonstrates applying it to a new image without adding a public
image-output owner or implicit mask editing rule.

`tryRgbLuminanceStretchOwned` estimates percentile bounds from 65,536 uniform
CIE XYZ-D65-Y bins. It decodes encoded sRGB to linear light through `color-d`,
scales linear RGB uniformly, and encodes the result as normalized sRGB floats
in a new ROI-local owner. A binary mask affects threshold estimation only.
Its compile-time `Clip` parameter selects hard clipping or fail-on-out-of-gamut
behavior. See [ADR 0011](docs/adr/0011-rgb-luminance-percentile-stretch.md)
for the numerical and ownership contract. `workerLimit` and `minimumChunk`
configure raster-d's bounded executor. The latest local LDC direct-lookup
candidate measured about 25.3 ms serial without a mask and 25.1 ms with one;
four workers measured 7.9 ms and 7.7 ms. These are host-specific diagnostics,
not guarantees; see the
[direct-lookup measurement](docs/performance/m3-luminance-direct-srgb-lookup-2026-10-28.md).
The API remains
sequential by default so applications can choose their own CPU budget.
raster-d v0.5.5 fixes the repeated-row worker capture defect from
[issue #278](https://github.com/alex-1974/raster-d/issues/278); imagery-d keeps
a private histogram per worker and passes the Release correctness/performance
matrix on DMD and LDC. See the
[performance investigation](docs/performance/m3-luminance-stretch-2026-10-23.md),
[previous post-merge baseline](docs/performance/m3-luminance-stretch-post-merge-2026-10-27.md),
and [latest post-merge receipt](docs/performance/m3-luminance-stretch-post-merge-2026-10-28.md).

### Worker budget for 1080p previews

For an interactive LDC preview, pass an explicit worker limit instead of
accepting the serial default when the consumer has CPU headroom. A paired
1080p full-call ABBA comparison of the direct-lookup candidate measured 7.89 ms
with four workers and no mask, and 7.68 ms with a mask (about 3.2× and 3.3×
over the candidate's paired serial calls). Serial medians were 25.30 ms without
a mask and 25.10 ms with a mask. These are local measurements,
not a latency guarantee; benchmark the target machine and account for other
work sharing its CPU budget. `workerLimit = 0` remains sequential. See the
[direct-lookup measurement](docs/performance/m3-luminance-direct-srgb-lookup-2026-10-28.md).

```d
import imagery : LuminanceStretchError, tryRgbLuminanceStretchOwned;
import raster : RasterLease, RasterView, Region2D;

@safe LuminanceStretchError stretchPreview(
    scope RasterView!ubyte decodedRGB,
    size_t maxResultBytes,
    ref RasterLease!float result)
{
    return tryRgbLuminanceStretchOwned!true(
        decodedRGB,
        Region2D(0, 0, decodedRGB.width, decodedRGB.height),
        1, 99,
        maxResultBytes,
        result,
        4); // LDC preview worker cap; choose for the consumer's CPU budget.
}
```

## First release operator: scalar Levels

The first admitted operator applies a scalar Levels mapping to selected
channels of an already decoded `RasterView!ubyte`, `!ushort` or `!float`.
It returns a **new ROI-local `RasterLease!float`** with interleaved channels
and explicit caller-provided pixel-payload budget. An optional single-plane
byte selection mask controls edit strength. The library does not infer
sRGB/ICC conversions, alpha policy, NoData or geographic metadata.

Example of the unmasked call, usable by an ordinary `@safe` D consumer
with a source view that remains alive during the call:

```d
import imagery : Levels, LevelsError, tryLevelsOwned;
import raster : RasterLease, RasterView, Region2D;

@safe LevelsError applyLevelsToRGB(
    scope RasterView!ubyte decodedRGB,
    size_t maxResultBytes,
    ref RasterLease!float result)
{
    bool[3] selected = [true, true, false];
    return tryLevelsOwned!ubyte(
        decodedRGB,
        Region2D(0, 0, decodedRGB.width, decodedRGB.height),
        selected[],
        Levels(0, 1, 2, 0, 1),
        maxResultBytes,
        result);
}
```

Only `LevelsError.none` means the complete new result was published.
`LevelsError.init == LevelsError.notAttempted` is **not success**.
On a normally returned error, the previous result lease is unchanged.
The provided budget covers the **new float pixel payload only**, not
source/old result/allocator overhead/peak RSS. The call is `@safe`,
but not `nothrow`, `@nogc` or implicitly thread-safe.

This example documents the **v0.1.0 source API**, without an ABI
stability or future-minor-version source compatibility guarantee. A separate
[out-of-tree consumer gate](tools/verify-archived-consumer.sh) extracts
`git archive` and compiles a completely separate DUB application against
that archive (not the working-tree source). For evidence and remaining gates,
see the historical [M3 admission review](docs/m3-levels-admission-review-2026-10-20.md) and [accepted ADR 0006](docs/adr/0006-first-owned-levels-public-api-admission.md).

## Documents

- `DESIGN.md` — current image-engine architecture constraints;
- `RESEARCH.md` — active and deferred imagery research;
- `ROADMAP.md` — admission sequence;
- `BENCHMARK.md` — benchmark/corpus principles;
- `docs/adr/0001-library-boundary-and-raster-dependency.md` — initial boundary;
- `docs/adr/0002-image-semantic-core.md` — accepted M1 semantic architecture;
- `docs/adr/0003-source-cache-pipeline-architecture.md` — accepted M2
  source/cache/materialization architecture;
- `docs/adr/0005-general-image-processing-primary-scope.md` — accepted
  general-purpose image-processing scope;
- `docs/adr/0004-first-m3-image-operation-selection.md` — Levels
  qualification priority;
- `docs/adr/0006-first-owned-levels-public-api-admission.md` — first
  accepted production-source API;
- `docs/adr/0007-rgb-histogram-and-statistics.md` — accepted RGB histogram
  source API;
- `docs/tutorial/levels.md` — first source Levels consumer tutorial;
- `CONTRIBUTING.md` — development and verification instructions;
- `docs/research/handover-from-raster-d.md` — extracted historical knowledge.

## Workspace context

When developed inside `d-geospatial-workspace`, current shared workspace
context is available locally under:

    .workspace/

These files are hard links to the canonical workspace documents and are not
part of the `imagery-d` repository or published package.

Repository-root documentation remains specific to `imagery-d`.

The helper:

    tools/link-workspace-docs.sh

creates or verifies the local `.workspace/` hard links. It deliberately refuses
to overwrite an existing file that is not already the expected workspace
hard link.

## Benchmark imagery

Large satellite, aerial and other test imagery is not committed to Git.

The repository will store reproducible scene/source definitions, retrieval
metadata, provenance and content hashes. Local imagery belongs below `data/`
or another ignored local cache.

## License

MIT License; see [LICENSE](LICENSE). The historical experiments carry the same declared repository licence.
