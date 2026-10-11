# M3.2 synthetic semantic display — first reproducible results

**Status:** PASS for the focused synthetic contract; **production admission deferred**.  
**Date:** 2026-10-11  
**Repository:** `alex-1974/imagery-d`  
**Branch:** `research/m3-2-semantic-display`  
**Validated implementation commit:** `52a8fd55d396fc91dc1d842c7359f8e1e3d5aadb`  
**GitHub Actions:** [run 38131191700](https://github.com/alex-1974/imagery-d/actions/runs/38131191700) — four successful jobs  
**Raster dependency:** released `raster-d` tag `v0.2.0`  
**Compiler environment:** GitHub-hosted Ubuntu 24.04 x86-64; D compiler installed by `dlang-community/setup-dlang@v2`

## Results matrix

| Compiler | Positive debug | Positive release | M1.5 positive + four @safe DIP1000 negative lifetime probes |
| --- | --- | --- | --- |
| DMD 2.111.0 | PASS | PASS | PASS |
| DMD 2.113.0 | PASS | PASS | PASS |
| LDC 1.41.0 | PASS | PASS | PASS |
| LDC 1.43.0 | PASS | PASS | PASS |

The M1.5 negative configurations are `negative-primary-escape`,
`negative-metadata-escape`, `negative-validity-escape` and
`negative-roi-escape`. Each was rejected by the compiler in the runner.
The positive M1.5 contract was also rerun.

## Scope actually tested

- Synthetically generated 7 × 4 float image, with four distinct sample planes.
- Physical layouts: planar and pixel-interleaved, represented by
  `raster-d` public plane layouts/leases/views.
- The original M1.5 experimental `ImageView!float` contract is imported
  directly, not forked; it borrows explicit immutable channel descriptors.
- A caller selects source plane order (3, 2, 1) to produce three output
  components. No colour-space conversion or implicit RGB interpretation.
- Optional same-grid one-plane `ubyte` validity, where zero means invalid;
  test-specific invalid-to-zero mapping and a truly mask-free input path.
- Independently materialized same-semantic fixtures, planar/interleaved
  exact output equality, and four uneven ROI partitions exactly matching
  full-region output.
- Rejected duplicate/out-of-range bindings, wrong semantic descriptor
  cardinality, and mismatched validity-grid dimensions.
- All success/failure preconditions in the test driver use a runtime
  `require` helper, not side-effectful expressions inside `assert`;
  debug/release both execute the same tests.

The direct independent oracle for this pure selection operation is
`sampleValue(channel,x,y) = channel * 100 + y * 10 + x`, with exact equality.
There are no transcendental or radiometric computations in this probe.

## Memory scope

For a **single invocation** of the 7×4 fixture using the source,
whole-result and partition-result raster allocations simultaneously:

| Payload | Resident raw sample bytes |
| --- | ---: |
| Four-plane float source | 448 |
| Three-plane float whole output | 336 |
| Three-plane float partition output | 336 |
| One-plane ubyte validity, when enabled | 28 |
| **Total with validity** | **1,148** |
| **Total without validity** | **1,120** |

These are calculated **payload sizes** of the fixtures, not measured process
RSS, peak memory, metadata/control-block overhead, allocator overhead or a
performance benchmark. `makeValidity` is not called in the mask-free branch.
The kernel is declared `@safe nothrow @nogc` and contains no explicit heap
allocation. No claims are made about throughput or the cost of real codecs.

## Not yet established

- Stable public type names, richer per-channel metadata, radiometric
  scale/offset and unit processing;
- alpha association, NoData representations or colour encoding;
- real `imageio-d` decoding or cross-library storage adoption;
- M2 Source/Resource/revision or source logical-coverage contracts;
- independent numerical reference for future nonlinear operations;
- performance comparison with raster-only baseline, larger workloads,
  cache/memory-budget behavior, or optimized LDC benchmarks.

**Decision:** preserve this PASS as experimental evidence on
`research-integration`. A minimal public `imagery-d` API remains gated on a
consumer-backed image-specific capability with complete correctness, memory,
failure and performance qualification plus an explicit admission ADR.

Tracking: [issue #24](https://github.com/alex-1974/imagery-d/issues/24),
[research PR #25](https://github.com/alex-1974/imagery-d/pull/25).
