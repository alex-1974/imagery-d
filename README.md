# imagery-d

`imagery-d` is the higher-level D image and remote-sensing library of
the `d-geospatial-workspace`.

The repository begins as an architecture and research project. Production
package/API work is admitted only after a concrete image-domain capability has
passed the project's research and design gates.

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

There is intentionally still no production `dub.sdl` and no production
`source/` tree.

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
