# Feature-kernel baseline and qualification

General demand for #197–204 is accepted by the repository owner. Admission
still requires explicit numerical, ownership and performance contracts.

The implementation starts at develop `819492a`. An isolated worktree protects
the existing uncommitted M6 work in the desktop checkout.

## Reproduction

```
dub run :bench --compiler=ldc-1.43.0 --build=release -- 1024 3 all rgb
dub run :bench --compiler=ldc-1.43.0 --build=release -- 4096 3 all rgb
dub run :bench --compiler=ldc-1.43.0 --build=release -- 1024 3 all scalar
dub build --root=tests/feature_program --compiler=dmd-2.113.0
python tools/verify-feature-program.py tests/feature_program/feature-program-oracle
bash tools/test-compiler-matrix.sh
```

The reference Python environment uses numpy 2.5.5, OpenCV 5.1.0 and
scikit-image 0.26.0. These are test dependencies, not runtime dependencies.

Each measured invocation uses a fresh engine, with one untimed warmup and
three timed invocations. Output includes a full-output checksum, median
ns/pixel, actual GC allocated bytes in the current thread, separately counted
engine scratch and cache allocations, and peak tile payload. Allocated bytes
are cumulative allocation traffic, not retained memory. Counters describe
explicit engine boundaries rather than all runtime allocator calls. Input
generation and sink traversal are included; decoder and IO costs are absent.
Scalar sample values are rounded to float32 before passing through the current
float64 engine. RGB input is encoded RGB8. The fixed Gaussian is binomial 3x3,
not a general sigma Gaussian. Canny is not yet included in this harness.

## Initial 1024² RGB8 measurement

LDC 1.43.0 / frontend 2.113 / LLVM 22.1.8, Linux x86-64. Measurements are
local diagnostics without fixed CPU affinity. No portable speed guarantee.

| Feature | Delegate baseline ns/pixel | Static sampling ns/pixel |
|---|---:|---:|
| Gaussian | 160.989 | 165.127 |
| Sobel gradient | 206.771 | 206.782 |
| Local normalization | 596.478 | 588.537 |
| Ridge | 653.544 | 601.057 |
| Gabor | 3299.619 | 2961.448 |
| Path opening | 2865.781 | 2423.812 |
| CLAHE | 254.130 | 239.757 |
| Median | 248.415 | 244.246 |

Checksums match at printed precision. These sequential measurements motivate
the static sampling change; they do not isolate causality for unrelated
CLAHE or fixed small-filter differences. The later configurable path change
needs its own measurement. No zero-allocation claim applies to Engine.run:
the engine still allocates request scratch and retained cache payloads.

## Numerical contracts and completed probes

- Area scalar reduction integrates parent pixel cells and requires every
  positive-weight contributor to be valid and finite. Upsampling is rejected.
  A rational integer-overlap reference checks every 7x5 reduction; one-pixel
  ROI partitions are identical. OpenCV INTER_AREA agrees on 35 target grids
  within 2e-7 relative and 2e-6 absolute (OpenCV float weight rounding).
- RGB indices explicitly choose encoded or linear evaluation; linearization
  uses color-d. Black has valid zero ExG and undefined chromaticity. Independent
  scalar sRGB arithmetic checks both domains to 1e-14 absolute.
- Histogram matching uses inclusive quantiles. Self matching is identity;
  malformed totals preserve output. Exact rational comparison avoids overflow
  and floating-point loss for ulong counts.
- CostPath uses nonnegative endpoint-mean geometric edge costs, deterministic
  tie breaking, multiple seeds and incremental bounded search. Infinity/NaN
  blocks samples. A binary heap bounds memory to O(pixels), time O(pixels log
  pixels). Search and path queries allocate zero GC bytes after preparation.
  All 72 distances on a two-seed 9x8 field agree with MCP_Geometric to 1e-13
  relative. Uniform-cost and blocked-wall regressions run without Python.
- Region quality uses a normalized second-difference MAD noise estimate and
  central-gradient energy. Known sigma .03 noise measures .029652. Detail
  frequency is an image statistic, not a sensor-resolution assertion.
- Typed local moments parameters and path parameters alter halo, cache identity
  and provenance. Defaults share the original cache identity. Parameter and
  partition checks run in the independent consumer. Other parameter families
  in #194 remain to be implemented.

## Remaining acceptance work

#193 still needs Canny, external timing comparisons, repeated 4096² characterization
and justified performance budgets. #194 still needs ridge, Gabor, CLAHE and
shadow parameters. #195 still needs reusable worker scratch and independently
qualified float32 SoA outputs; current float64 cache/output contracts remain.
#198 now has a dense Gaussian-derivative tensor implementation, a reserved
workspace and a scipy differential reference for all output planes. It still
needs wider scale/ROI and performance qualification. #196 and #197 remain
implementation work. #199 needs wider independent
path enumeration and performance qualification. #144/#147/#148 need display,
quality-weight and multiresolution integration beyond scalar area reduction.
#187 requires actual manually reviewed route, shore and building scenes and
multiple tool workflows; the available Dunia tests exercise API sharing only.

The six-compiler unit-test matrix passed both default and no-io during the
initial implementation (before the tensor addition). Final checks are recorded
separately; this earlier run is not presented as final-head tensor coverage.

No release or API freeze follows from these diagnostics.

## Located Dunia scene inventory

The Codex chat “Intelligente Wegführung entwerfen” records the real fixture
location `dunia-libs/geo-research-d/data/multi-aoi/`. The related
`data/multi-region-aoi/` contains training/holdout manifests and OSM pixel
references. The old `/tmp/dunia-vision-esri-aoi/review-labels.csv` described in
the review instructions was not present during this inspection. No completed
human labels were found in the durable dataset directories.

Run the shared-feature replay on the existing, unscaled center crops:

```
python tools/verify-feature-scenes.py tests/feature_program/feature-program-oracle \
  /path/to/dunia-libs/geo-research-d/data/multi-aoi
```

LDC 1.43 Release, 256² source crops at (896,486), output region (5,7,246,242):

| Scene | Input PNG SHA-256 | Elapsed ms | Gradient cache hits |
|---|---|---:|---:|
| Marchfeld | 4f60cb726ba7b9c6e993995598212bb681c05789ead5cec2f3272265b901289f | 73 | 16 |
| Wienerwald | 401cfcf4debe5955fae686123145ccb45b60927e6147b814b547a025cf824677 | 74 | 16 |
| Semmering | c70db459b7e52a07938c9d0091cb062584aeee4de9d1e0fd29ffffe2c18dd458 | 74 | 16 |

Every scene used 287,872 peak tile bytes and 5,739,488 peak retained cache
bytes. Requests shared gradient between local-statistics and OKLab feature
selections, with exact result equality. These are real image/API replays;
they do not establish water/building tool acceptance or human ground truth.

## 4096² scalar diagnostic

One warmup and one measured run, LDC 1.43 Release. This run includes the
first configurable path implementation, before restoring compact default
scratch specialization. It is not the final path performance claim.

| Feature | ns/pixel | GC allocated bytes/call |
|---|---:|---:|
| Gaussian | 84.999 | 542172160 |
| Gradient | 137.651 | 542172160 |
| Local normalization | 498.857 | 1080157184 |
| Ridge | 495.761 | 542245888 |
| Gabor | 2655.946 | 542262272 |
| Path opening | 3543.431 | 542327808 |
| Median | 151.595 | 542172160 |

The large cumulative allocation traffic despite bounded retained cache makes
worker scratch/cache reuse in #195 necessary; bounded live payload alone is
not a zero-allocation execution claim.
