# ADR 0020 — Color SLIC and owned region graphs

**Status:** Implemented and qualified, unreleased; PR #205 integration pending.

## Decision

Add a separate CIE Lab D50 SLIC implementation with local color/spatial search,
explicit compactness/spacing, mask-aware seeds, fixed iterations, bounded orphan
fallback and categorical four-connectivity cleanup. Merge small adjacent pieces
through a deterministic region graph. Keep the legacy scalar grid clusterer
unchanged and explicitly distinct.

Keep labels and assignment scratch caller/file-backed. Publish final labels,
validity and owned graph only after the complete staged operation succeeds.
Expose region/edge statistics, shape evidence, sorted neighbors, adjacent merges
and original-label lineage as immutable owned graph records. No source pixels,
decoder handles or label-store callbacks are retained in graph results.

The exact source/domain, Lab conversion, parameters and auxiliary feature recipes
are part of provenance. Crops read finalized global labels; smaller independent
analyses are not assigned a false equivalence guarantee.

## Evidence

See the [consumer contract](../color-slic-region-graph.md) and
[qualification receipt](../benchmarks/slic-graph-display-2026-11-22.md).
Independent NumPy clustering, SciPy connectivity, direct pixel reductions,
adjacency enumeration and merge references cover partitions, files, NoData,
orphan fallback, parameter extremes, histories and real RGB scenes. The supported
compiler matrix, @safe/named/readonly contracts and rendered examples qualify
the public implementation. No stable API freeze or application-class truth is
declared by this decision; #187's reviewed Dunia use remains separate.
