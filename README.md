# imagery-d

`imagery-d` is a general-purpose, high-performance **image-processing library
for D** in the `d-geospatial-workspace`. It is intended for photo/graphics
editors, scientific image analysis and GIS/remote-sensing applications alike.

Its central responsibility is **computing on image data**. Consumers are
responsible for the origin and factual/domain-specific interpretation of their
inputs (for example, sensor calibration, STAC metadata, image registration or
satellite processing baseline). Generic filters, tone operations, image
transforms, statistics and compositing must not require satellite/geospatial
metadata. The library still guarantees correctness and safety of the operations
it implements for declared inputs and parameters.

See [the scope clarification](docs/research/general-image-processing-scope-correction-2026-10-17.md)
for the core/consumer separation; specialist metadata remains optional.

The integration line `develop` now includes its **first accepted but
unreleased** image-processing source API: scalar Levels. The first release
version is **v0.1.0 (selected, not yet published)**; for pre-1.0 changes,
see the [release tracking issue](https://github.com/alex-1974/imagery-d/issues/99).
Linux x86-64 is the initial supported release target; tested macOS and
Windows consumer canaries are best effort, not a full release support claim. ADR 0005 governs
the general-image domain, ADR 0004 its first-operator priority and
ADR 0006 the exact API admission. This is **not a published version,
an API/ABI freeze, or a DUB Registry package**; `main` remains unchanged.

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

**M1 / M2 ARCHITECTURE ACCEPTED — FIRST M3 LEVELS SOURCE API ADMITTED**

M1 established the image semantic core and is accepted by
`docs/adr/0002-image-semantic-core.md`.

M2 established the source/resource/materialization/cache/request architecture
and is accepted by
`docs/adr/0003-source-cache-pipeline-architecture.md`.

`develop` now contains the narrowly accepted production `dub.sdl` and
`source/imagery` Levels module, without copying the experimental M1/M2
research architecture. No published version or source-compatibility freeze
is implied.

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

## First source operator: scalar Levels (unreleased)

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

This is an **unreleased develop source-API example**, not an instruction
to install a registry release or a claim of long-term source compatibility. A separate
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
  accepted production-source API (unreleased);
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
