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
not a general sigma Gaussian. The initial harness omitted Canny; the
[2026-11-22 follow-up](feature-performance-2026-11-22.md) adds complete Canny,
repeated 4096² runs, external timings, explicit allocation/latency regression
ceilings and the necessary primitive correctness repairs.

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

#193 now has the expanded harness, external diagnostics and local regression
ceilings in the follow-up receipt; material performance gaps remain open.
#194's specifically requested parameter
families are implemented; broader catalog configuration and queued nondefault
requests remain follow-up scope. #195 now has a separately qualified prepared
float32 SoA worker (see below); current float64 cache/output contracts remain.
#198 now has the expanded scale/ROI/performance qualification recorded below.
#196 and #197 now have
the implementations and qualification described below; integration remains
subject to the PR checks. #199 has the shared-DAG implementation and broader
qualification recorded below. #144/#147/#148 need display,
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

## Shared path-morphology qualification

#199 replaces overlapping per-pixel path scans with a threshold-activated
directed graph on each padded tile. Active forward/backward longest paths are
capped at the requested length. A pixel first qualifies at the threshold where
their sum minus one reaches that length. Process thresholds high-to-low for
opening and low-to-high for closing; combine horizontal and vertical DAGs.
NoData blocks vertices, while virtual source-edge pixels use the same clamp
as the original reader. The method selects source values exactly, with no
floating arithmetic in the response. Signed-zero data uses the original
scalar kernel to preserve IEEE tie bits, detected before output modification.

Complexity is O(N log N + N*L*(2*step+1)), with N the padded tile graph area,
instead of O(L²*(2*step+1)) partial-path work independently at every output
pixel. The bound still depends on length; no length-independent complexity
claim is made. Seven arrays reserve 24N+outputArea bytes on x86-64. The sort
uses value/index entries and a capture-free comparator: an initial captured
comparison allocated a hidden closure and was rejected by the zero-GC gate.
Each active node is queued at most once concurrently. Length one bypasses the
graph and requires no extra scratch. Processing tiles remain upper-bounded by
the requested edge; large mixed moment/morphology/path requests cap at 128
where needed to keep total scratch below 8 MiB.

Permanent library tests compare the retained scalar dynamic-programming kernel
exactly at lengths 1/3/7/13/31 and lateral steps 0/1/2, including a mask and
source-edge clamps, for opening and closing. Each prepared evaluation allocates
zero GC bytes. They also check opening anti-extensivity, closing extensivity
and positive affine unit transformations. The independent consumer enumerates
all path choices recursively for lengths 1/3/5, steps 0/1/2 and both operators
on a thin line, blob, masked field, constant and steep line: 25,740 exact output
and validity comparisons across whole/tiled execution. The steep line needs
step two; short blobs disappear. Additional signed-zero, maximal-support and
mixed-feature requests test the fallback and 8 MiB limit. Existing M6 references
and the independent feature program pass.

Same-machine before/after on parent `d0ef3d3`, LDC 1.43 Release, CPU affinity 0,
128² scalar values, one warmup + three measured calls (median), including cold
engine/source/cache setup and sink traversal:

| Length | Lateral step | Before ns/pixel | Shared DAG ns/pixel | Peak tile bytes after |
|---:|---:|---:|---:|---:|
| 7 | 1 | 3754.187 | 1183.527 | 6184832 |
| 15 | 1 | 15524.017 | 1692.438 | 3926912 |
| 31 | 0 | 2655.664 | 1849.524 | 4772736 |
| 31 | 1 | 63249.249 | 2738.538 | 4772736 |
| 31 | 2 | 161095.673 | 9494.629 | 6667776 |

All five full-output checksums match their parent. At 1024² with default length
7/step 1, the same pinned pair measured 3312.252 versus 1005.395 ns/pixel,
matching checksum 1981017.58568. Cold request GC traffic rises from 38,033,749
to 39,840,085 bytes because the reusable per-request graph scratch is larger;
the new kernel itself allocates zero bytes after reserve. Peak tile payload
rises from 4,395,520 to 6,184,832 bytes, still below 8 MiB. This is a local cost
comparison with uncontrolled CPU frequency/system load, not a portable speedup.

```
dub run :bench --compiler=ldc-1.43.0 --build=release -- 128 3 paths scalar
dub run :bench --compiler=ldc-1.43.0 --build=release -- 1024 3 pathOpening scalar
```

Final local validation passes all six compilers in both configurations
(20 no-io and 21 default unittest modules), the existing M6 reference harness,
DMD 2.111 Debug/LDC 1.43 Release independent consumers and rendered DDOX.
The preceding cost-path head `d0ef3d3cd606b1005ddd7687b9d160ebad8e621d`
has all four CI workflows successful; new-head CI is tracked separately.

## Prepared float32 SoA worker qualification

#195 adds `imagery.analysis.feature_worker32` as an explicit alternative to the
unchanged float64 Engine. One serial, noncopyable worker prepares a selected
feature/capacity once and evaluates raster-d callback-scoped working planes.
Float32 or float64 source storage is read with signed strides; arithmetic is
float64 and publication is float32. Callers provide halo/edge extension and,
for RGB analysis, an explicitly declared linear-luminance plane. Encoded-RGB
features and dedicated global/fitted/CLAHE interfaces remain separate. See
ADR 0016 for all scope, failure and borrowed-result lifetime contracts.

The independent consumer checks 126 gray/RGB-derived/strided cases, 29,358
whole-output samples and 4,165 additional interior ROI comparisons against the
float64 Engine. Every valid result equals its exact float conversion; masks
agree apart from explicitly tested float32 range/zero-strength loss. The
largest observed absolute conversion error is 1.49473852e-5 K on the scalar
temperature fixture; it is not a dimensionless universal error bound. Seven
configured families, negative rows/sample strides, padding, masks, NaN, source
edges and float32 input are included. Separate adversarial cases cover huge
and tiny gradients, profile overflow, competing path-direction range loss,
failed setup and failed evaluation. Failure resets the out result to init and
preserves previous published buffers. Successful callback dispatch/evaluation
allocates zero GC bytes, enforced by `@safe nothrow @nogc` signatures. Maximum
prepared work-array payload at 256² and length 31/step 2 is 5,107,264 bytes
(metadata/allocator overhead excluded), below 8 MiB.

Delegate baseline and candidate are compiled in the same LDC 1.43 Release
binary, against parent `aa0f6b9`. Intel i7-9750H, CPU affinity 0, 1024² values,
256² tiles, one warmup + three measured runs, medians. Input is identical double
working storage with identical halos. Each timed tile includes finite-mask
preparation, computation and output stores. Source generation, setup and
full-output checksum traversal are outside the execution timer. Both paths
allocate zero GC bytes per evaluation and have matching checksums after
reference-output quantization. Window/path comparisons also include their
previously admitted shared algorithms, so gains are not solely layout/dispatch.

| Feature | Delegate float64 AoS ns/pixel | Prepared float32 SoA ns/pixel | Reference payload bytes | Worker payload bytes |
|---|---:|---:|---:|---:|
| Gaussian | 50.872 | 64.953 | 3162176 | 1049604 |
| Gradient | 86.763 | 96.673 | 3162176 | 1049604 |
| Local normalization | 381.879 | 162.018 | 3195456 | 4271140 |
| Ridge | 274.377 | 220.957 | 3195456 | 1051684 |
| Gabor | 1623.315 | 1132.172 | 3212288 | 1052736 |
| Path opening | 1939.874 | 838.518 | 3246336 | 3368464 |

Small Gaussian/gradient kernels regress with the explicit publication checks;
this opt-in worker is not a universal speedup and does not replace the Engine.
Frequency/system load are uncontrolled; these are local comparative receipts.
Setup is measured separately, including allocation and parameter preparation:

| Feature | Reference setup ms | Worker setup ms | Reference setup GC bytes | Worker setup GC bytes |
|---|---:|---:|---:|---:|
| Gaussian | .7681 | .5204 | 3170304 | 1077248 |
| Gradient | 1.5817 | .4962 | 3170304 | 1077248 |
| Local normalization | .5491 | 1.7451 | 3203072 | 4300800 |
| Ridge | .3082 | .1378 | 3203072 | 1077248 |
| Gabor | .3102 | .2589 | 3219456 | 1081344 |
| Path opening | 1.7174 | .6379 | 3252224 | 3416064 |

At 256², normalization saves about 14.4 ms per tile, exceeding its additional
1.20 ms setup on the first tile; the other faster families also amortize setup
within one tile in this run. Gaussian/gradient have no steady-state latency
break-even here. These setup numbers include allocator/GC state and are noisy;
consumers should reuse prepared capacity, not prepare inside callbacks.

```
dub run :bench --compiler=ldc-1.43.0 --build=release -- 1024 3 worker32 scalar
API_PROBE_CONFIG=no-io DC=dmd-2.111.0 bash tools/verify-api-probes.sh
```

All six compilers pass default/no-io (22/21 unittest modules). DMD 2.111 Debug
and LDC 1.43 Release independent consumers, the existing M6 reference harness,
rendered DDOX and DIP1000 API probes pass. Positive probes cover nested mask
callbacks and named parameters; negative probes reject mutable output and
worker copying. CI retains the callback lifetime/source contracts on both
floor DMD and current LDC. PR integration and application acceptance remain.

## Region-quality blur and performance qualification

#203's noise sigma, central-gradient energy and detail-frequency ratio are
checked independently with scipy bulk convolution and NumPy median/variance
reductions on 12 periodic-sine, two-frequency texture and constant cases at
Gaussian blur sigmas 0/.75/2/4. Blur is periodic and truncated at ceil(4*sigma);
source publication is float32. Each case includes 11,844 complete interior
stencils. Maximum absolute errors are 4.17e-17 for noise, 2.71e-15 for energy
and 1.18e-15 cycles/pixel for detail frequency. The cross-backend regression
gate is 3e-13 relative + 1e-15 absolute, allowing different floating reduction
orders over ~12k samples; the absolute floor covers near-zero MAD cancellation.

Discrete Gaussian attenuation of the single sine agrees analytically within
1e-7 relative (float32 source quantization). Blur reduces gradient energy;
the single-frequency detail ratio changes by only 1.36e-11 cycles/pixel and
does not identify a blur width or sensor resolution. The mixed-frequency ratio
decreases as high frequencies attenuate. The API documents that limitation.
The preceding independent white-noise fixture has sigma .03 and measures
.029652 (regression interval .027..033; texture can bias this estimator).

Dyadic input under affine unit transforms at factors 1/1024, 1024 and -1
preserves detail frequency/sample counts while sigma scales by abs(factor)
and energy by factor². A central NaN excludes exactly nine complete stencils;
all-invalid and insufficient-scratch failures preserve the published result.
Small permanent library regressions retain these laws and explicit init state.

LDC 1.43 Release, i7-9750H, CPU affinity 0, one warmup + five measured runs
(three for 4096²), median. Source/scratch allocation and checksum are outside
timing; both median sorts and all stencil/reduction work are inside. The input
is a deterministic normalized float32 texture. Each evaluation allocates zero
GC bytes; caller scratch is double, 8 bytes per input sample.

| Size | ns/input pixel | Scratch payload bytes |
|---|---:|---:|
| 256² | 131.012 | 524288 |
| 1024² | 105.200 | 8388608 |
| 4096² | 110.575 | 134217728 |

This is a whole supplied-region statistic with O(N log N) median sorting,
not a bounded 8 MiB tiled engine claim. Consumers choose smaller regions to
bound memory; combining per-tile MADs is not equivalent to a global median.
Frequency/load are uncontrolled; no portable latency guarantee follows.

```
dub run :bench --compiler=ldc-1.43.0 --build=release -- 1024 5 quality scalar
```

The preceding worker head `9532a3f04fa400c96a24f50bac5a83569a0b414b`
passes all four CI workflows. Current-head local validation is recorded at
integration; these prior checks are not relabeled as current-head coverage.
The quality follow-up passes the local six-compiler matrix in both
configurations (22/21 modules), independent DMD 2.111 Debug/LDC 1.43 Release
references and rendered RegionQuality/tryRegionQuality DDOX examples.
