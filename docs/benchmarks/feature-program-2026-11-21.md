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
needs wider scale/ROI and performance qualification. #196 and #197 now have
the implementations and qualification described below; integration remains
subject to the PR checks. #199 needs wider independent
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

## Final local checkpoint

Code commit `e50c9be`: all six controlled compilers passed the no-io (18
modules) and default (19 modules) unit tests with fixed DUB 1.40.0. The
independent consumer passed DMD 2.111 Debug and LDC 1.43 Release. All
functional checks use enforce so that Release cannot remove probe calls.
The existing M6 reference harness also passed on DMD 2.111 Debug.

The broad GitHub checks for PR #205 are a separate integration gate. This
local receipt does not claim they have completed or that the draft is merged.

## Variable windows and Hessian follow-up

The window kernel merges/removes population Welford moments in two separable
passes. A finite common offset is subtracted before accumulation. Independent
monotone queues maintain extrema while ignoring invalid samples. An exact
constant window is recognized from its extrema and gets zero variance. A
numerically unsafe centered carrier selects the retained complete scalar
reference instead of invalidating otherwise usable constant windows.

Each sample is inserted and removed at most once per separable pass: ordinary
work is linear in the output plus halo. A tracked roundoff estimate detects
severe cancellation after a high-contrast predecessor leaves a low-variance
window. Those windows are recomputed around a local anchor; the deliberately
complete worst-case fallback remains O(window area per output). A regression
with a 1e6 step followed by 1e-8 texture checks this recovery to 1e-22 absolute.
One row record
per expanded row/output column is enough. Vertical results overwrite retired
rows after saving the next outgoing record. Requested tile edge is a maximum;
large windows or mixed square-morphology/moment requests use at most edge 192
to retain the existing 8 MiB engine tile scratch budget. Scratch and cache
are accounted separately.

The numerical method marker in cache identity/provenance changes to
`centered-welford-monotone-v2`. Statistics affected by arithmetic reordering
are compared within tolerance, not asserted bitwise equal to the old nested
scan. Explicit-default versus ordinary-default calls still match bitwise.
NoData and validity remain exact. Extrema/dynamic range remain exact on the
fixtures. Regression coverage includes every odd window size 3..63, tile
edges 1/7/256, masked fields, empty windows, constants, fractional values and
values near 1e12 with differences of 0.000244140625. A separate two-pass
80-bit-real oracle admits 1e-14 absolute standard-deviation error, and either
1e-14 absolute mean error or two binary64 ULPs at 1e12. Observed over 33,480
valid samples: maximum mean error 0.0001220703125 (one ULP at 1e12) and maximum
standard-deviation error 8.8817842e-16. The existing synthetic
ROI/dependency harness uses 1e-10 for reordered moments-derived outputs and
retains exact checks for masks, extrema and unaffected operators.

Hessian response uses finite scalar float32 input with four reserved double
scratch planes (32 bytes per supplied sample) and caller-owned strength,
tangent angle, scale and orientation-validity outputs. Evaluation allocates
zero GC bytes after reserve. Both polarity evaluates bright then dark; ties
at float32 response precision retain the first supplied scale. Zero or
numerically isotropic curvature has no orientation. All three formula families
share a DC-corrected, replicated-edge stencil with support ceil(4*sigma).

Two independent references serve different purposes:

- scipy direct convolutions plus NumPy symmetric eigendecomposition validate
  the exact specified stencil on an isolated line and a rotated/textured/blob
  fixture, all nine variant/polarity pairs, three scales and every output.
  A third fixture configuration exercises fractional scales [0.5,1.25,3.75]
  and nondefault beta, gamma, alpha and responseScale. Constant-image unit
  checks also exercise sigma 32, reaching the maximum kernel radius 128.
  Response regression tolerance is 2e-7 relative + 1e-16 absolute (float32
  rounding plus cancellation at numerical zero); axial angle tolerance is
  4e-7 radians for these well-resolved fixtures. Scale and orientation-validity match exactly away from
  numerically zero responses. The D driver additionally checks interior,
  source-edge and tiny-corner ROI results and sign inversion.
  Observed maximum exact-stencil response error was 1.70219741e-17, with
  matching float32 angles on these fixtures.
- Public scikit-image filters characterize the algorithmic discretization
  difference on the known-width line. Observed Sato line-center relative error
  is 0.0017553 (gate 0.003), maximum Frangi absolute difference 0.0125471
  (gate 0.015), and normalized Meijering shape error 0.000210483 (gate 0.001).
  Frangi gamma is converted per sigma to compare the sigma²-normalized Hessian.
  Meijering's normalization is diagnostic only; production responseScale is a
  fixed caller value so separate ROIs do not redefine the response.

LDC 1.43 Release diagnostics on this machine, one warmup + three measured
runs, 1024² scalar source, including cold engine/cache work:

| Window | ns/pixel | Peak engine tile bytes |
|---|---:|---:|
| 3 | 179.277 | 7397504 |
| 7 | 152.937 | 7513216 |
| 15 | 125.840 | 7747712 |
| 31 | 134.573 | 4802688 |
| 63 | 164.119 | 5585024 |

1024² RGB local normalization measured 259.742 ns/pixel versus the previous
588.537 ns/pixel static-sampling diagnostic; printed full-output checksum
5011.58428818 is unchanged. These sequential, non-affinitized observations
support the structural improvement but are not a controlled portable speedup.

Hessian 256², sigmas [1,2,4], supplied scratch/output allocated before timing:
Sato 568.163, Frangi 619.467 and Meijering 587.386 ns/pixel; each reports zero
GC bytes per evaluation. Timing includes parameter validation and Gaussian
preparation, excludes output checksum traversal and reserve allocations.

```
dub run :bench --compiler=ldc-1.43.0 --build=release -- 1024 3 windows scalar
dub run :bench --compiler=ldc-1.43.0 --build=release -- 256 3 hessian scalar
```
