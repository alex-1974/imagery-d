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
- Typed local moments, path, ridge, line-response, Gabor and shadow parameters
  alter halo, cache identity and provenance. Defaults share the original cache
  identity. CLAHE parameters alter cell geometry/clip factor and provenance,
  retaining only the reusable underlying luminance cache. Parameter and
  partition checks run in the independent consumer.

## Remaining acceptance work

#193 still needs Canny, external timing comparisons, repeated 4096² characterization
and justified performance budgets. #194's specifically requested parameter
families are implemented; broader catalog configuration and queued nondefault
requests remain follow-up scope. #195 still needs reusable worker scratch and independently
qualified float32 SoA outputs; current float64 cache/output contracts remain.
#198 now has the expanded scale/ROI/performance qualification recorded below.
#196 and #197 now have
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

## Typed parameter follow-up

The parameter consumer now checks RidgeParams, LineResponseParams, GaborParams,
ShadowParams and ClaheParams in addition to local statistics and path morphology.
The Gabor bank permits two fractional wavelengths, four axial angles, a Gaussian
sigma ratio and an explicit support ratio; the bank is prepared once per missing
request. Fine/coarse member names identify positions, with their default values
unchanged. Scales remain pixels of the selected grid.

Whole-image, 7-pixel tiles, interior ROI and a source-edge corner agree exactly
for ridge/line/Gabor/CLAHE. Shadow uses an absolute 1e-14 gate for rolling-moment
rounding. A separately summed scalar Gabor formula agrees within 1e-15; the
different order of weight normalization accounts for final rounding. Invalid
settings are rejected before reads or scratch allocations. Tests cover complete
support masks, constants, maximum halos 31/62/32 on a million-pixel procedural
source, the 8 MiB scratch ceiling, explicit defaults hitting ordinary default
cache entries, nondefault misses, repeated nondefault hits without preparation,
and adjacent floating shadow ceilings with distinct identities. CLAHE covers
cell edges 8, 18, 32 and 128, partial edge cells and clip factors .7, 2, 3.5, 256.

The `--parameter-defaults` consumer mode hashes raw float64 channel bits and both
validity flags for 13 affected default outputs on a 73x69 RGB8 fixture with a
mask hole. Comparing the same consumer with parent implementation `3b9a3fe`
checks compatibility independently of the new explicit-default overloads:

```
tests/feature_program/feature-program-oracle --parameter-defaults
```

The documentation build now renders all seven parameter types, including the
new executable examples and public fields, into the actual DDOX site.

Observed LDC Release maxima on the above corpus: Gabor scalar-oracle error
2.77555756e-17, shadow partition error 8.88178420e-16, combined scratch
6,890,824 bytes. The Gabor gate is intentionally 36 times this single-point
observation to allow summation-order/compiler variation across a bank of up to
65x65 samples; it is still below five float64 ulps at unit input scale. The
shadow gate is about 11 times the observed error, allowing the documented
rolling-moment rounding while staying below 46 float64 ulps at unit scale.

Both package configurations passed all six controlled compilers (19 no-io,
20 default unittest modules). The independent Python references and parameter
consumer passed DMD 2.111 Debug and LDC 1.43 Debug/Release. All 13 default-output
digests match parent `3b9a3fe` within each tested compiler/build pair. Digests
are deliberately compared within a compiler/build pair; floating trigonometric
constants need not have identical bits across DMD and LDC. The concatenated
LDC Debug/Release digest receipt has SHA-256
`dc5ad7e0e56cc624363d145f2818a3b4b1828598285a9b4a0a935713222fb796`;
the DMD Debug receipt has SHA-256
`40610a5b076e97ab91fd9089effd138eb92f4a2bacd2c141f69b8e961ac324bd`.

## Structure tensor scale/ROI qualification

#198 now covers 20 exact-stencil cases: vertical line, oblique grating, textured
field and radial signal, each at gradient/integration pixel scales (.5,0),
(.75,.5), (1.25,2.5), (2.75,4), (32,32). scipy Gaussian derivatives/integration
use explicit ceil(3*sigma) radii, matching the declared support rather than
scipy's rounded truncate convention. All 63,700 sample validity flags match.
Energy/coherence are checked everywhere; angles use resolved energy and gaps
because directions near isotropy are ill-conditioned. Constants and radial
centers whose complete support fits the image separately qualify undefined
orientation. The tensor now treats gaps <=32*double.epsilon*trace as undefined
and clamps coherence to [0,1]. Tiny positive sigmas no longer form 0/0 when
both off-center Gaussian weights and sigma squared underflow. Constant normal
and subnormal-valued inputs are permanent regressions.

| Metric | Observed maximum | Gate |
|---|---:|---:|
| scipy axial angle difference | 5.959834e-8 radians | 2e-7 radians |
| scipy coherence difference | 2.980228e-8 | 2e-7 relative + 3e-8 absolute |
| scipy energy difference | 7.426584e-9 | 2e-7 relative + 1e-16 absolute |
| Whole/halo-expanded ROI, all output planes | 0 | exact float32/validity equality |
| Analytic affine-gradient angle | 2.185570e-8 radians | 1e-7 radians |
| Analytic oblique-grating angle | .000130499 radians | .001 radians |
| Public scikit-image grating direction | .001051123 radians | .004 radians |

The first two angle gates cover float32 output rounding. The public skimage
comparison is deliberately a direction diagnostic on one resolved grating:
its Sobel derivatives and four-sigma integration differ from the independent
Gaussian-derivative scales in this API. It is not energy equivalence. Affine
ramps at three angles also verify energy's quadratic unit scaling for factors
1/1024 and 1024, while angle/coherence/validity remain bit-identical. Interior,
source-edge and tiny-corner ROIs use the composed source halo; 6,460 ROI sample
comparisons match all planes exactly. Invalid scales, shapes, nonfinite input
and insufficient reserved scratch preserve all destination sentinels. Evaluation
allocates zero GC bytes after explicit reserve. Rendered DDOX covers both
public types and the evaluation function, including type-level examples.

LDC 1.43 Release on Intel i7-9750H, 1024² scalar plane, CPU affinity 0, one
warmup and five timed runs (median), no forced frequency or system isolation:

| Gradient sigma | Integration sigma | ns/pixel | GC bytes/evaluation |
|---:|---:|---:|---:|
| .5 | 0 | 90.480 | 0 |
| 1 | 2 | 215.465 | 0 |
| 2.75 | 4 | 396.816 | 0 |

The timed operation includes validation and kernel preparation; reserve,
input/output allocation and the full-output checksum are outside the timer.
Workspace is six float64 planes (48 bytes/sample); this API processes an
explicit dense window. The halo tests establish how consumers can request
smaller windows without seams. These local measurements characterize cost,
not a portable performance promise. Reproduce with:

```
dub run :bench --compiler=ldc-1.43.0 --build=release -- 1024 5 tensor scalar
```

The final six-compiler default/no-io matrix and DMD 2.111 Debug/LDC 1.43 Release
references pass. The earlier parameter commit `8dd360f` additionally has all
13 active GitHub checks successful; new tensor-head CI is recorded separately.

## Minimum-cost path window and performance qualification

#204 now has 64 random-field oracle cases (eight 13x11 fields, four/eight
connectivity, four isotropic/anisotropic step pairs spanning 1e-6..1e6).
They include NaN/infinity walls, zero costs, two seeds, duplicate seeds and
reversed seed order. All 9,152 distances and finite/unreachable decisions
match MCP_Geometric; maximum observed relative distance and reconstructed-path
cost error are both zero on DMD 2.111 Debug and LDC 1.43 Debug. The 3e-15
relative gate allows about 14 float64 ulps at unit scale for arithmetic/libm
variation along short paths, despite the exact observations on this corpus.

Every reconstructed step has legal connectivity and matches the published
settled predecessor. `predecessorOf` exposes the map without returning mutable
internal arrays: size_t.max means unknown/unreachable/out of bounds, settled
seeds point to themselves. Seed-to-target buffers remain untouched if too
small. Query permutation versus a fully drained run yields identical distances
and predecessors. Each budgeted call settles at most seven additional cells;
zero-budget calls do no work. The entire steady query/path phase allocates
zero GC bytes. A failed reset preserves the preceding search.

Whole 21x17 versus 13x11-window searches agree exactly for all 286 window
distances across both connectivities and anisotropic steps. This fixture has
an expensive exterior, guaranteeing the optimum stays inside the window;
arbitrary cropped cost fields have no such unconditional equivalence.

The indexed binary heap is intentionally used for integer samples too:
endpoint averaging, diagonal geometry and supplied anisotropic steps do not
produce a general integer edge metric. A bucket queue would require a separate
exact-integer metric specialization, rather than quantizing these costs.
This refines the initial queue suggestion explicitly; see ADR 0015.

Prepared LDC 1.43 Release, Intel i7-9750H, CPU affinity 0, one warmup + five
timed runs, median, with setup/cost copy excluded:

| Workload | Domain | Time | GC bytes/evaluation |
|---|---|---:|---:|
| Complete distance map | 1024x1024 | 338.599 ns/pixel | 0 |
| 64 moving targets with 64-cell search quanta | 128x128 window | 24,651.562 ns/query | 0 |

The interactive target set and full-output checksums are emitted by the
benchmark. Each path's length and three indices contribute to the interactive
checksum; full-map distance traversal happens after its timer. The interactive
timer includes path extraction and checksum updates. Domain-area normalization
is also printed (96.295 ns/window-pixel for all 64 queries); it is not a
per-settled-pixel estimate. Workspace is O(domain pixels), 41 bytes/sample on
x86-64 for the prepared arrays, plus caller input/path storage and array
overhead. Frequency/system load are uncontrolled; this is a cost receipt, not
a portable speed guarantee.

```
dub run :bench --compiler=ldc-1.43.0 --build=release -- 1024 5 cost-path scalar
```

Both package configurations pass the six-compiler matrix; DMD Debug and LDC
Debug references and rendered DDOX pass. The preceding tensor head
`5cd30cb681f622191aa8935b1c7c131933482708` has all 13 active CI checks successful
after one infrastructure-only LDC download HTTP 403 retry.
