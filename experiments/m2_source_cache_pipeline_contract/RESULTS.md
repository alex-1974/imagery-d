# M2 Source / Cache / Pipeline Contract Results

## Status

PASS

Verified locally on 2026-09-24.

## Toolchains

- DMD 2.111.0
- LDC 1.41.0
- LDC frontend: DMD 2.111.0
- DUB 1.40.0
- target: x86_64 Linux

## Repository baselines

### imagery-d

- branch: `research/m2-source-cache-pipeline`
- pre-experiment HEAD: `2c43f23329c9b5d70b31cde1d7fba362f0335a68`

### raster-d

- commit: `a073b3ad6b541fcd8421ed304722feaa47e9083b`
- branch: `main`
- local HEAD matched `origin/main`
- worktree during validation: clean

This is the same `raster-d` commit used by the accepted M1.5 ImageView
contract experiment.

The experiment consumes the sibling `raster-d` repository through the DUB
path dependency declared in `dub.sdl`.

## Verification matrix

| Contract | DMD 2.111.0 | LDC 1.41.0 |
|---|---|---|
| semantic production-key identity | PASS | PASS |
| equal-key single-flight | PASS | PASS |
| subscriber cancellation/publication lifecycle | PASS | PASS |
| cache eviction versus delivered raster lifetime | PASS | PASS |
| covering logical region to exact raster ROI | PASS | PASS |
| semantic plan versus execution strategy | PASS | PASS |

## Production-key identity

The experiment confirmed that `ProductionKey` is determined by the resolved
semantic materialization plan rather than request-local execution metadata.

Changing any of the following changed production identity:

- source/resource revision;
- target grid identity;
- materialized sample representation;
- radiometric policy;
- resampling policy;
- validity policy;
- ordered component selection.

Changing only the following did not change production identity:

- execution strategy;
- priority;
- generation/epoch.

The experiment uses a structural key rather than only a hash so that semantic
identity mistakes cannot be hidden by hash behavior.

## Single-flight

Two subscribers requesting the same production key joined one
`SharedProduction`.

The deterministic model recorded exactly one production start.

This supports the M2 rule that duplicate in-flight semantic work should be
coalesced independently of subscriber identity.

## Cancellation and publication

The lifecycle model confirmed:

- cancelling one subscriber does not cancel another waiting subscriber;
- a production remains running while at least one interested subscriber
  remains;
- when all subscribers cancel before publication, the production may enter
  the stopped state;
- publication before cancellation results in delivery;
- cancellation before publication results in cancellation;
- delivered and cancelled are terminal and mutually exclusive subscriber
  outcomes.

The experiment deliberately models the state transitions synchronously.

It does not claim to validate thread synchronization, lock behavior or a
production scheduler.

## Cache membership versus raster lifetime

The experiment used the real `raster-d` `RasterLease!ubyte` ownership
capability.

One decoded resident coverage was retained independently by:

- the cache;
- a delivered materialization owner.

After the producer retain was dropped and the cache entry was evicted, the
delivered materialization remained readable.

This supports the M2 invariant:

    cache membership != raster lifetime

No second pixel-storage ownership system was required.

Final backing destruction remains the responsibility of `raster-d` and is
covered by its existing `RasterLease` ownership tests.

## Covering cache hit and exact ROI

The resident coverage carried imagery-side logical placement:

    Region2D(10, 20, 4, 3)

The contained logical request:

    Region2D(11, 21, 2, 1)

was translated to the resident relative region:

    Region2D(1, 1, 2, 1)

and served through the real `raster-d` `RasterView.tryRoi` operation.

The requested samples matched the expected source samples and the experiment
recorded no second source materialization.

This supports the M2 boundary in which logical source placement remains above
`raster-d`, while zero-copy resident ROI mechanics remain owned by `raster-d`.

## Semantic plan versus execution plan

The experiment provided two intentionally different materialization loop
strategies:

- `unfused`;
- `fused`.

Both represented the same resolved semantic plan.

They therefore produced:

- the same `ProductionKey`;
- the same dimensions;
- exactly equal sample values at every tested coordinate.

This supports the M2 distinction:

    TargetImageContract
        ->
    ResolvedMaterializationPlan
        ->
    semantic ProductionKey

while execution strategy remains an implementation choice when semantic
equivalence is preserved.

## Initial compiler-harness corrections

The first DMD build exposed two D-language issues in the experiment harness:

1. a `const` plan produced a `const` inferred mutation fixture;
2. a temporary `canonicalPlan()` result could not bind to the
   `const ref` parameter of `makeProductionKey`.

The experiment was corrected by:

- keeping the key-mutation fixture mutable;
- binding `canonicalPlan()` to a local value before passing it by `const ref`.

No M2 architecture decision changed as a result.

## M2 contract result

The experiment supports the current M2 architecture:

- semantic result identity is separate from execution policy;
- equal semantic work can be single-flight;
- subscriber lifetime is separate from shared-production lifetime;
- cancellation does not imply revocation of unrelated subscribers;
- cache membership is separate from retained raster lifetime;
- imagery-side logical coverage composes with `raster-d` resident ROI;
- different execution strategies may share one semantic key when they are
  semantically equivalent.

## What PASS does not establish

PASS does not freeze a production `imagery-d` API.

It also does not validate:

- HTTP or range-request behavior;
- COG or WMTS access;
- real decoders or codec cancellation;
- disk or persistent cache behavior;
- cache replacement policy;
- concurrent thread synchronization;
- a worker pool;
- a scheduler;
- a general DAG;
- memory-admission accounting under real load;
- real resampling or cross-grid transformation;
- retry/backoff behavior;
- offline/stale-cache policy;
- final source, resource, cache or materialization type names.

Those remain separate implementation or promotion gates.
