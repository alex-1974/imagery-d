# Color SLIC and region graphs

`imagery.analysis.color_slic` and `imagery.analysis.region_graph` implement
full-domain color superpixels and an owned adjacency graph. Both are opt-in
direct imports. Raster storage, decoding, CRS transforms, scheduling and the
interpretation of regions as roads/buildings/water stay outside these modules.

## Color superpixels

The implementation follows the local color/spatial clustering model of
[Achanta et al., SLIC (2012)](https://www.cs.jhu.edu/~ayuille1/JHUcourses/VisionAsBayesianInference2022/4/Achanta_SLIC_PAMI2012.pdf):
regular seeds, optional low-gradient perturbation, local Lab/space assignments,
centroid updates and a connectivity step. The explicit D50 color coordinates,
mask-aware seed selection and deterministic graph cleanup described below are
this implementation's choices. It does not reuse the old scalar `slic` primitive.

Supply stable `ComponentReader` observations in **CIE Lab D50**. Accepted samples
have state=candidate/seed, valid=true and finite color coordinates with absolute
value <=1e6. A seed state has no special growing behavior in SLIC. A valid but
excluded sample stays excluded. `colorSlicRgb(Source)` converts declared RGB8
samples through color-d's sRGB -> linear -> XYZ D65 -> Bradford -> Lab D50 path;
it does not infer alpha, NoData, sensor calibration or another color encoding.
That adapter converts on every read. Repeated analysis can instead use
caller-prepared Lab rows, with the preparation recipe in source provenance.

`ColorSlicParams` controls:

| Parameter | Contract |
|---|---|
| spacing | Integer 1..256 pixels; grid anchored to the fixed analysis extent |
| compactness | Finite 1e-6..1e6; distance is dc² + (m/S)² ds² |
| iterations | 1..100 fixed assignment/update passes |
| perturbSeeds | Lowest finite Lab gradient in a 3×3 neighborhood, row-major ties |
| minimumSizeFactor | 0..1 times S²; zero disables small-region merging |
| maxCleanupRounds | Explicit failure limit for graph-based cleanup |

Each grid cell first chooses a valid sample nearest its nominal center; empty
mask cells have no active seed. Empty clusters keep their preceding centers.
Spatial bins restrict normal comparisons to the closed ±S search window. A
32-epsilon coordinate-relative margin prevents rounded centroids on that window
boundary from being accidentally omitted. Rare uncovered pixels compare all
active centers; the request's distance-evaluation limit includes that fallback.
Seed/gradient work is separately bounded by the seed grid and local neighborhoods.

After the fixed passes, categorical four-connected labeling splits disconnected
pieces. Small pieces merge into adjacent regions by longest shared boundary,
then smallest mean-color contrast, then smallest ID. Rounds continue until no
eligible merge remains, or fail at maxCleanupRounds. An isolated NoData island
cannot be merged across missing pixels and may remain below the requested size.
The number of connected output regions is therefore approximate, not exactly
the number of seeds.

## Publication and storage

`tryColorSlic` takes two separate caller backings:

1. `assignmentStore`: private scratch containing centroid assignments.
2. `ComponentTransaction.store`: private staging for canonical connected labels.

They must not alias each other, the source, or a previously published backing.
RAM and windowed temporary files implement the same contract. The engine never
allocates a full-source label or color image. Input must remain stable across
all reads. The transaction's validity sink preserves finite-observation validity
separately from label zero. Optional region/contact sinks receive **post-cleanup**
records and contacts, not the intermediate disconnected assignments.

Only after all phases, final label remapping, sinks and cancellation checks does
the nonthrowing caller commit publish the label backing. The function then
publishes `ColorSlicSegmentation`, containing the immutable graph, exact settings,
source facts and complete versioned parameter recipe. Every other exit after
valid commit/abort callbacks invokes abort; D Errors propagate after abort.
The old segmentation and published label aliases remain intact when the caller
honors its staging contract. `.init.valid` is false; an all-masked domain can be
a successfully completed segmentation with no regions.

`maxCenters` limits grid slots, `maxLabels` provisional component labels and
`maxEdges` unique adjacency pairs. Work/result capacities are checked before
publication. `colorSlicWorkBytes` reserves clustering, component and graph phases,
graph generations and bounded merge history. It excludes caller buffers,
providers, GC headers and unreachable memory awaiting GC. It is a logical live
payload budget, not a process RSS ceiling. The qualified fixture uses 5,219,160
bytes under an 8 MiB request. The complete operation is allocating and makes no
@nogc/nothrow promise. Texture/edge feature identities and units must be supplied
when their finite observations participate.

## Complete region graph

`tryBuildRegionGraph` can consume any already finalized connected label store,
including Canny hysteresis, seeded growing or SLIC. Nonzero labels must have
accepted finite-color observations. A source can have valid excluded label-zero
pixels. Source revision/domain and segmentation/color/auxiliary recipes are
explicit in `RegionGraphProvenance`.

The graph owns immutable records and exposes:

- Sorted IDs, accepted-pixel area, global bounds, color means/population variances,
  separate texture/edge counts, means and population variances.
- Local pixel-center centroid and spatial covariance, perimeter, fill ratio,
  resolved principal direction, compactness and feature coverage.
- Unique shared-side edges, shared-side counts, finite boundary-edge coverage,
  endpoint-averaged edge means/variances and mean-color contrast.
- Sorted CSR neighbors, allocation-free ID lookup, original-to-current labels
  and persistent merge history.

Adjacency counts horizontal/vertical shared sides. Diagonal connectivity does
not create a shared side. Principal directions are invalid for numerically
isotropic footprints, using the component engine's relative covariance rule.

Copies share immutable GC-owned arrays. Returned const slices remain owned by
the GC; they are not borrowed decoder windows. Mutating records through the
graph is prohibited by the type system. `tryRegion`/`tryResolveLabel` initialize
their out parameters on failure. Queries are @safe/nothrow/@nogc.

`tryMergeRegionGraph` accepts adjacency pairs from the input graph. Batches and
chains produce the minimum member ID, combine population moments, remove
internal shared sides from perimeter and aggregate remaining edge evidence.
Reduction order follows sorted source IDs, independently of pair order. It does
not rewrite the original label store. `tryResolveLabel` or `labelMap` interprets
that store against any later generation. Copies of earlier graphs retain their
original records and lineage. Generation alone is not a unique cache identity;
include source/feature provenance and exact label-map/merge-history contents.

Both build and merge publish only complete graphs. Bad metadata, inconsistent
labels, capacities, numerical overflow, callback failures and cancellation leave
the old graph and aliases unchanged. Pixel scratch consists of bounded rows;
fixed-capacity hash tables bound graph staging. Expected scan work is linear in
pixels plus hashing, with sorting/CSR construction in region/edge counts;
adversarial hash distributions can require more probes.

## Viewports and qualification

IDs are stable across processing blocks and storage backings for the **same
source/domain/policy**. A viewport reads a crop of finalized labels and queries
the same graph. Independently clustering a smaller domain is not promised to
reproduce the original IDs or connections outside that domain.

Executable usage examples are the documented unittests on `tryColorSlic` and
`tryMergeRegionGraph`; the external consumer is `tests/component_regions`.
The [qualification receipt](https://github.com/alex-1974/imagery-d/blob/v0.4.0/docs/benchmarks/slic-graph-display-2026-11-22.md) retains
independent bulk NumPy clustering, SciPy connectivity, pixel-derived graph and
merge references, six-compiler/API gates and real-scene evidence. Dunia's
manually reviewed interpretation and UI acceptance remain separate under #187.
