# imagery-d

`imagery-d` is a **general-purpose D image-processing library** within
`d-geospatial-workspace`. It processes already materialized images without
requiring geographic coordinates, satellites, CRS information or any particular
image source. Photography, scientific imagery and remote sensing are all
possible consumers. Generic raster ownership and layout belong to `raster-d`.

The integration line `develop` remains an architecture/research project.
Draft PR #97 carries the first **unmerged** ordinary DUB/source candidate:
scalar image Levels, deliberately selected for qualification under ADR 0004
(Draft PR #96). That candidate is **not an accepted public API or release**.
The isolated source-archive consumer, numeric, ownership, Ddoc, performance
and DMD/LDC Linux gates now pass on the Draft branch. Those tests **do not
admit the public API or publish a package**. An explicit admission decision
is still required before integration. `main` remains unchanged.

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

**M1 / M2 ARCHITECTURE ACCEPTED — PRODUCTION API STILL GATED**

M1 established the image semantic core and is accepted by
`docs/adr/0002-image-semantic-core.md`.

M2 established the source/resource/materialization/cache/request architecture
and is accepted by
`docs/adr/0003-source-cache-pipeline-architecture.md`.

The integrated `develop` line intentionally still has no admitted production
`dub.sdl` or `source/` tree. The **unmerged Draft candidate** in PR #97
does include both, specifically to qualify the first ordinary DUB package
without copying the M1/M2 research implementation wholesale.

M3 selects and validates the first concrete production vertical slice.

The first package surface will be admitted only when that capability has:

1. a concrete consumer requirement;
2. an explicit image-domain semantic contract;
3. an explicit boundary with `raster-d`;
4. defined source/residency/failure behavior where applicable;
5. a correctness oracle;
6. a bounded-memory contract;
7. a reproducible benchmark workload;
8. DMD correctness evidence;
9. LDC optimized-performance evidence.

Passing M1 and M2 does not itself authorize a speculative general
source/cache framework.

## First production candidate: scalar Levels (Draft only)

The initial proposed operation applies a scalar Levels mapping to selected
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

This is **source/API documentation for review**, not a registry installation
instruction or a released-package stability guarantee. A separate
[out-of-tree consumer gate](tools/verify-archived-consumer.sh) extracts
`git archive` and compiles a completely separate DUB application against
that archive (not the working-tree source). For evidence and remaining gates,
see [M3 admission review](docs/m3-levels-admission-review-2026-10-20.md).

## Documents

- `DESIGN.md` — current image-engine architecture constraints;
- `RESEARCH.md` — active and deferred imagery research;
- `ROADMAP.md` — admission sequence;
- `BENCHMARK.md` — benchmark/corpus principles;
- `docs/adr/0001-library-boundary-and-raster-dependency.md` — initial boundary;
- `docs/adr/0002-image-semantic-core.md` — accepted M1 semantic architecture;
- `docs/adr/0003-source-cache-pipeline-architecture.md` — accepted M2
  source/cache/materialization architecture;
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
