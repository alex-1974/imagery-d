# Feature performance and Sobel/Canny correction checkpoint

This #193 follow-up extends the [feature-program receipt](feature-program-2026-11-21.md).
Baseline: `999857d` plus the primitive correctness fixes described below.
All numbers are local diagnostics, not portable latency guarantees.

## Reproduction and scope

Intel i7-9750H, Linux 6.17.0-22 x86-64, glibc 2.44, CPU affinity 0.
LDC 1.43.0 / frontend 2.113, DUB release, no-io benchmark subpackage.
One warmup plus three measured calls, median; CPU frequency/load uncontrolled.
The synthetic fixture is `v=(37*x+17*y+(x*y)%97)&255`. Scalar values are
float32-rounded v/255; RGB8 is (v,255-v,v), converted through color-d to
linear luminance. Engine calculation/output is float64.

Cold Engine timers include source generation/transfer, request scratch,
cache publication and full-output strength traversal. Processing tile edge
is at most 256 (large moment/CLAHE requests may reduce it to retain 8 MiB).
Canny is a separate complete float32 working-plane primitive: input/transfer
and caller edge allocation are outside its timer, internal arrays and global
hysteresis inside. It has no fixed-tile connectivity equivalence claim.

```
dub build :bench --compiler=ldc-1.43.0 --build=release
taskset -c 0 ./imagery-d_bench 1024 3 all scalar
taskset -c 0 ./imagery-d_bench 1024 3 all rgb
taskset -c 0 ./imagery-d_bench 4096 3 all scalar
taskset -c 0 ./imagery-d_bench 4096 3 all rgb
taskset -c 0 python tools/benchmark-feature-references.py
```

## Native measurements

Time in ns/input pixel:

| Operator | Scalar 1024² | Scalar 4096² | RGB 1024² | RGB 4096² |
|---|---:|---:|---:|---:|
| Gaussian | 89.265 | 99.341 | 162.989 | 166.768 |
| Gradient | 139.421 | 146.907 | 213.819 | 206.000 |
| Local normalization | 177.946 | 182.516 | 253.888 | 251.822 |
| Ridge | 555.928 | 592.100 | 625.327 | 623.459 |
| Gabor | 2818.667 | 3030.308 | 2984.055 | 2882.521 |
| Path opening | 1010.261 | 990.537 | 1098.848 | 1058.988 |
| CLAHE | unsupported | unsupported | 260.306 | 273.705 |
| Median | 166.383 | 163.880 | 245.161 | 245.299 |
| Canny | 44.062 | 52.196 | 43.515 | 47.001 |

Allocated bytes per complete cold call, min..max across domains:

| Operator | 1024² | 4096² | Peak Engine tile payload |
|---|---:|---:|---:|
| Gaussian | 37869909 | 542172160 | 4227200 |
| Gradient | 37867178 | 542166698..542172160 | 4227200 |
| Local normalization | 74778965..74781696 | 1083375274..1083378005 | 7513216 |
| Ridge | 37929984..37935445 | 542234965..542243157 | 4293760 |
| Gabor | 37962752..37968213 | 542267733..542281386 | 4327424 |
| Path opening | 39837354 | 544134144..544139605 | 6184832 |
| CLAHE | 40165034 | 544467285 | 6513440 |
| Median | 37864448 | 542166698 | 4227200 |
| Canny | 25186304 | 402673664 | not an Engine tile |

These are actual GC allocation traffic, not retained memory. Engine output
cache payloads allocate once per produced tile (16/256 at 1024²/4096², twice
for the local-moment dependency). Cache eviction bounds retained results,
not cumulative traffic. Canny owns 24N bytes of internal array payload on
x86-64 (four float planes plus one size_t queue), plus caller input/edges and
allocator overhead. No zero-allocation claim applies to these cold APIs.
Prepared workers have their separate zero-allocation receipt.

## External diagnostics

numpy 2.5.5, OpenCV 5.1.0, scipy 1.18.1, scikit-image 0.26.0; OpenCV one
thread, same CPU affinity, warmup and repetitions. Input preparation and
checksums are outside timers; operation temporaries/native allocations are
inside. Python/GC counters cannot represent all native allocations, so no
cross-language allocation comparison is claimed. These are whole working
planes and omit Engine source/cache/provenance work.

Representative external timings in ns/input pixel:

| Reference operation | Scalar 1024² | Scalar 4096² | RGB 1024² | RGB 4096² |
|---|---:|---:|---:|---:|
| OpenCV Gaussian float64 3x3 | 1.696 | 12.782 | 2.192 | 6.553 |
| OpenCV/NumPy Sobel strength+angle float64 | 34.077 | 68.406 | 37.156 | 71.571 |
| OpenCV/NumPy 7x7 normalization float64 | 15.635 | 75.475 | 14.799 | 84.678 |
| OpenCV/NumPy twelve-stencil ridge float64 | 114.264 | 193.001 | 99.311 | 207.457 |
| OpenCV/NumPy eight-complex-filter Gabor float64 | 411.132 | 631.195 | 348.660 | 577.883 |
| scipy median float64 3x3 | 68.369 | 85.502 | 95.894 | 103.121 |
| OpenCV median float32 3x3 | 1.070 | 5.926 | .689 | 4.819 |
| OpenCV Canny with quantized derivatives | 15.233 | 34.303 | 14.272 | 38.944 |
| scikit-image Canny float32, sigma=0 | 58.008 | 127.860 | 55.389 | 103.630 |
| OpenCV CLAHE on quantized luminance | 5.824 | 6.906 | 6.358 | 6.209 |
| scikit-image CLAHE | 100.537 | 235.438 | 81.958 | 261.730 |

Gaussian/Sobel/ridge/Gabor/normalization/scipy-median strength planes have an
independent finite-scalar preflight against Engine. The normalization reference
uses E[x²]-E[x]² and is not a replacement for the centered, full-domain
fallback contract. Ridge/Gabor references emit winner planes; strength is the
preflight metric, not a claim of identical trigonometric tie bits. Gradient
reference output also includes angle; its checksum sums both planes, whereas
Engine's general benchmark sums strength only. OpenCV/scipy scalar Gaussian
and median full-output sums agree at printed precision apart from reduction
rounding; this is a diagnostic, not bit-equivalence evidence.

OpenCV Canny includes Sobel and derivative conversion to int16 at 1/255
granularity; its plateau/tie rules differ. scikit-image interpolates NMS.
OpenCV median narrows to float32; both CLAHE references have distinct
quantization/interpolation/normalization semantics. The script prints these
differences per row. No direct performance ratio is used as proof of equal
work or numerical interchangeability. Neither external library provides the
same monotonic-DAG path opening: this row is explicitly unavailable; the
retained D scalar reference and before/after receipt remain its comparison.

Material gaps remain, especially small filters and Gabor. Source inspection
identifies per-sample reader/validity work, scalar stencil dispatch and AoS
publication in Engine, while OpenCV uses specialized bulk filtering. This is
a mechanism inference, not attribution of the entire measured difference.
Prepared-worker comparisons already remove source/cache work and still show
the Gaussian gap; those semantics and publication costs need further work.
The new thresholds below do not waive that performance-admission requirement.

## Regression ceilings

[feature-budget-2026-11-22.json](feature-budget-2026-11-22.json) gives each
operator/domain a machine-specific ns/pixel ceiling, approximately 25% above
the worst observed size (rounded upward), plus allocation-byte ceilings.
The margin accommodates this three-run, uncontrolled-frequency diagnostic;
it is deliberately a regression alarm, not a universal performance promise.
All Engine tile payloads must stay below 8 MiB. Canny's global arrays have
the explicit 24N contract instead. A scalar CLAHE budget of zero means that
input domain has no admitted implementation.

```
python tools/check-feature-budgets.py /tmp/receipt.log --size 1024 --domain rgb
```

The checker verifies metadata, coverage, finite timing/checksums, latency,
allocation and Engine tile payload. Run it only on the documented pinned
machine/build; shared-runner CI retains correctness/resource gates instead
of unstable wall-clock thresholds. All four local receipts pass. The final
PR checks remain distinct from these local observations.

## Correctness repair and qualification

The new value test fails before repair because Sobel float accumulators start
at D's NaN init. Explicit zero initialization repairs Gaussian, bilateral,
guided, Sobel and corresponding parallel accumulation. The scalar Gaussian
also validates destination length before writes. After that repair, the
eight-ray test separately fails: the old Canny wavefront drops successors
beyond 2*count+1 capacity. Two full-domain buffers fix propagation with bounded
16N bytes of index payload per frontier call and no allocation per wave.

OpenCV Sobel is exact on the 19x17 integer fixture. Three independent inclusive
NMS plus scipy seeded-component cases match complete Canny; direct, staged,
parallel and frontier routes agree. A cropped Sobel core with halo one is
exact. The 17-cell branch case reaches every cell. Gaussian/scipy maximum
absolute error is 3.052e-5 on byte-range input (gate 3e-7 relative + 3e-5
absolute, accounting for float32 kernel/pass accumulation). Constant guided
and bilateral regressions and short-destination failure preservation pass.
Nonconstant bilateral and guided fixtures independently match double NumPy
reductions, with maximum absolute errors 4.010e-7 and 1.569e-7 on normalized
input (gates 6e-7 and 8e-7). The gates cover float32 weight/mean accumulation
over 49/25 taps; the bilateral impulse also has an analytic center check.
The six external timing strength-plane preflights differ by at most
2.665e-15 (gate 2e-13 relative + 1e-14 absolute for backend/reduction order).
Broader #186 region IDs, superpixels and stitched connectivity are not
declared complete by this repair.

All six compilers pass both configurations (22 default/21 no-io modules).
Independent DMD 2.111 Debug and LDC 1.43 Release references and rendered DDOX
pass. The local budget checker accepts all four receipts and rejects wrong
metadata, missing operators, excess latency and excess allocation probes.
The preceding quality head `999857dcafd6cbb8a5a3b9e99d729ddf5a305cec`
has all four CI workflows successful; new-head checks are tracked in PR #205.

## Scalar grid-clustering correction

The #186 baseline `slic` used NaN-initialized centroid sums, so later
assignments compared NaN distances and retained the first-pass labels. The
independent constant 19x17 case already disagrees at 19/323 pixels before
repair. Explicit zero sums restore the intended four-pass scalar algorithm.
Three NumPy assignment/centroid references (constant, diagonal contrast and
deterministic texture; 969 pixels) now have exactly equal label maps. A
permanent 5x4 moving-center case protects later-pass changes. Ties retain the
first grid seed. The function body is expanded for review, with the same
initialization, metric, four passes and empty-cluster retention.

This is exhaustive scalar grid clustering, with squared scalar contrast plus
squared pixel distance/spacing². Caller normalization determines contrast
weight. It is not color SLIC, a connectivity constraint or a stable region-ID
contract across independent crops. Scientific/NoData/multitile admission in
#186 remains open; the correction does not promote that wider operator.

LDC 1.43 Release, i7-9750H, CPU 0, normalized float32 deterministic texture,
one warmup + three measured calls, median, including complete function setup,
four assignment/reduction passes and internal allocation. Input/caller labels
and full-label checksums are outside the timer. Both workloads use 64 seeds:

| Size | Spacing | ns/input pixel | GC bytes/call | Four-call label checksum |
|---|---:|---:|---:|---:|
| 128² | 16 | 594.348 | 76624 | 2119600 |
| 512² | 64 | 639.998 | 1059664 | 34043268 |

Work is O(4*N*K), K=ceil(w/spacing)*ceil(h/spacing). Internal array allocation
traffic is 4N+76K bytes plus allocator overhead on this target: one distance
plane, three center arrays and four sets of three sum arrays plus counts.
There is no prepared/zero-allocation or fast large-K claim. Frequency/load
are uncontrolled; these are local cost receipts rather than performance
admission against a mature SLIC implementation.

```
dub run :bench --compiler=ldc-1.43.0 --build=release -- 512 3 slic scalar
```

Both package configurations pass all six compilers (23/22 unittest modules),
DMD Debug/LDC Release independent references and rendered SLIC DDOX example.
The preceding configured-request head `8b46bdbdf12b5cbc971ac7a1d31ef68fcd5d7398`
has all four CI workflows successful; new-head checks are tracked separately.
