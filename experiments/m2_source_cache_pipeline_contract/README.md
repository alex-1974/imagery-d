# M2 Source / Cache / Pipeline Contract Experiment

## Status

Research spike only.

This experiment does **not** define the production `imagery-d` API.

It mechanically probes the architecture described by the M2 research set:

- `docs/research/m2-source-resource-access-model.md`
- `docs/research/m2-region-materialization-boundary.md`
- `docs/research/m2-cache-architecture.md`
- `docs/research/m2-demand-cancellation-prefetch.md`
- `docs/research/m2-product-to-image-materialization.md`
- `docs/research/m2-reference-consumer-validation.md`

## Dependency

The experiment uses the sibling workspace repository:

    ../../../raster-d

through DUB.

The expected raster baseline for the initial experiment is:

    a073b3ad6b541fcd8421ed304722feaa47e9083b

That is the same raster-d baseline used by the accepted M1.5 ImageView
experiment.

## Questions

The experiment asks whether the M2 architecture can satisfy six narrow
contracts without introducing a production scheduler or a second raster
ownership model.

### 1. Production-key identity

The resolved semantic materialization plan defines production identity.

The experiment verifies that these change the key:

- source/resource revision;
- target grid;
- target sample representation;
- radiometric semantics;
- resampling semantics;
- validity semantics;
- ordered component selection.

It also verifies that these do **not** change the key:

- execution strategy;
- priority;
- generation/epoch.

### 2. Single-flight

Two subscribers for one equal production key join one shared production.

### 3. Cancellation

The deterministic lifecycle model verifies:

- cancelling one subscriber does not cancel another;
- cancelling all interested subscribers before publication may stop production;
- publish-before-cancel produces delivery;
- cancel-before-publish produces cancellation;
- a subscriber receives exactly one terminal state.

No threads are required to test these state-machine semantics.

### 4. Cache eviction versus delivered lifetime

The experiment uses the real `raster-d` `RasterLease!T`.

A decoded coverage is retained independently by:

- a cache entry;
- a delivered materialization owner.

Evicting the cache entry must not invalidate the delivered materialization.

The experiment deliberately does not create a second pixel-storage ownership
system.

### 5. Covering-hit ROI

A resident decoded coverage with logical source placement can serve an exact
contained request by translating logical coordinates to a relative
`RasterView.tryRoi`.

No second source materialization is performed.

The zero-copy nature of `RasterView.tryRoi` is inherited from the established
`raster-d` contract; this experiment verifies that imagery-side logical
placement composes with that contract.

### 6. Semantic plan versus execution plan

Two intentionally different execution strategies materialize the same semantic
plan.

They must:

- produce the same `ProductionKey`;
- produce the same exact raster sample values.

## Deliberate limits

This experiment does not implement:

- HTTP;
- COG;
- WMTS;
- filesystems or disk cache;
- GDAL;
- OpenImageIO;
- real image codecs;
- worker threads;
- a thread pool;
- a general scheduler;
- a general DAG;
- real resampling;
- cross-grid transformation;
- production cache replacement policy;
- persistent cache serialization;
- final public source/product/cache types.

The fixed two-component plan fixture is not a proposed final product model.

## Run

From the experiment directory:

    ./tools/run.sh

or from the `imagery-d` repository root:

    experiments/m2_source_cache_pipeline_contract/tools/run.sh

The default verification matrix requires both DMD and LDC.

A selected compiler set can be used with:

    COMPILERS="dmd" ./tools/run.sh

## PASS

PASS requires both compilers to confirm:

1. semantic-key identity boundaries;
2. equal-key single-flight;
3. cancellation/publication terminal-state semantics;
4. cache eviction without invalidating a delivered `RasterLease`;
5. contained logical request to resident ROI without rematerialization;
6. exact output equality across two execution strategies.
