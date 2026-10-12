# M3.2.19 — source-adapter failure states and scoped lifetime negatives

**Status:** research-only verification of `ResearchLongLivedMetadataSource`;
[issue #60](https://github.com/alex-1974/imagery-d/issues/60),
[stacked draft PR #61](https://github.com/alex-1974/imagery-d/pull/61)
above [PR #59](https://github.com/alex-1974/imagery-d/pull/59).
No public API, no cross-repository edits and **no merge to develop**.

## Inherited conclusions

M1.5's non-owning ROI contract and the M3.2.12 sealed
`ValidatedImmutableImage`/`PreparedSemanticMap` pipeline protect
immutable semantics and scoped borrowed raster/validity views. M3.2.17's
independent XPS measurement admitted copy-once metadata snapshots as a
way to remove per-packet GC snapshot allocation. M3.2.18 independently
verified 40 processes, 2,560 actual packet mappings and 25,600 **ordered**
ROIs (153,600 expected first/last channel samples), all with zero
recorded mapping GC allocation. These results are **not a general
latency bound** or an immutable zero-copy freeze from mutable input.

This tranche adds **error/escape evidence**, not a new source owner,
a cached cross-packet Prepared token or faster pixel execution.

## Exact safety failure matrix

The `--metadata-source-failures` consumer actually imports three
sample planes, a validity mask and a reusable 3-plane output.
`ResearchLongLivedMetadataSource.snapshot` copies three mutable
semantic identities and three intrinsic calibration records before
mapping. Each case calls the existing `@safe nothrow @nogc`
`tryMapOrderedInto`. Its error channel is the experimental
`SourceRoiError`, not the public imagery-d API.

| Input class | Expected error | Output and observation contract |
|---|---|---|
| No requested ROI | `sampleBuffer` | untouched |
| Too short first samples | `sampleBuffer` | untouched |
| Too short last samples | `sampleBuffer` | untouched |
| Too many first samples | `sampleBuffer` | untouched |
| Default `.init` source owner | `invalidImage` | untouched |
| Channel descriptor count != source planes | `invalidImage` | untouched |
| Mismatched intrinsic semantic ID | `invalidImage` | untouched |
| Validity required, invalid validity view | `invalidImage` | untouched |
| Selected channel outside source | `invalidBinding` | untouched |
| Missing selected-channel physical calibration | `invalidBinding` | untouched |
| Zero-size ROI | `invalidRegion` | untouched |
| ROI outside primary extent | `invalidRegion` | untouched |
| Destination side differs from ROI | `invalidRegion` | untouched |
| Output with only two planes | `mappingFailure` | untouched |
| ROI 0 valid, ROI 1 invalid | `invalidRegion` | **ROI 0 has already written pixels and first/last observation data** |
| One valid ROI | `none` | complete 3-channel full-pixel oracle |

The test reinitializes **caller-owned output** and **first/last
observation buffers** to sentinels on each case. All failures
which occur before the first destination write **must preserve
the sentinels**; GC allocated bytes during each mapping call
must remain zero. The two-ROI case deliberately documents
non-transactional semantics: the invalid second ROI must not
erase or roll back successfully written first-ROI results.
The test's independent full-grid physical/validity oracle checks
every output pixel of the successful 8×8 ROI.

**Important:** `tryMapOrderedInto` checks sample-buffer lengths
before image/semantic/ROI validity. `invalidImage` precedes
`invalidBinding`; `invalidRegion` precedes mapping of that ROI.
It is **not** a whole-request validation transaction. Later malformed
windows can leave earlier output and observation elements updated.

The current `sampleFailure` branch requires that a destination
pixel read unexpectedly fail **after** shape validation, a
successful `mapInto` and the same expected output coordinates.
It is not artificially forced with an invalid raw pointer or
corrupted raster view in this `@safe` test; do not claim coverage.

## DIP1000 source-specific lifetime negatives

Two **separate** `dub.sdl` configurations, compiled with
`-preview=dip1000` and `@safe`:

- `negative-m3219-primary-escape` must reject returning a
  `PreparedSemanticMap` constructed from an automatic local
  `RasterLease!float` while metadata is held by the
  long-lived source adapter.
- `negative-m3219-validity-escape` must reject returning a
  `PreparedSemanticMap` constructed from an automatic local
  `RasterLease!ubyte` while its primary image and metadata are
  otherwise externally borrowed.

A negative compilation **only passes when** the compiler rejects
source code *in `m3_2_metadata_source/contract.d`* with a scoped
return/escape diagnostic. An unrelated build failure is not a
valid negative pass. The test must be repeated on DMD 2.111,
DMD 2.113, LDC 1.41 and LDC 1.43.

These are **whole-source lifetime boundary probes**. They do
not establish that arbitrary `cast(immutable)` is safe, and do
not prohibit returning a legitimate GC-backed immutable metadata
source independent of the borrowed pixel/validity resource.

## Promotion and limitation

Qualification additionally retains all M3.2.6–18 private
constructor/forgery, compiler/lifetime negatives, actual ordered
ROI mapping oracles, GC-intervention and source-generation tests.
There is **no performance benchmark** in this tranche, so
no XPS run or performance-speedup claim should be inferred from
a hosted CI pass.

A later research tranche may separately test caching a validated
Prepared mapping across packets **only with a provable retained
pixel/mask/metadata lifetime**. If performance is claimed it must
account for preparation, reuse and representative consumer
end-to-end mapping and pass its own XPS oracle/provenance gates.

The research PR must remain **OPEN/DRAFT** and stacked; promotion
to `develop` requires selection of accepted safe production changes
and the workspace's explicit integration process.
