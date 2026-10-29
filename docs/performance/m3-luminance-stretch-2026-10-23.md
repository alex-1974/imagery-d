# RGB luminance stretch — initial Release throughput receipt

**Status:** local diagnostic evidence; not a portable performance claim
**Date:** 2026-10-23
**Candidate base:** `63f077bc4a8a3c029cda2f7e81523f889be6795f`
**Compiler:** LDC 1.43.0, D frontend 2.113.0, LLVM 22.1.8
**DUB:** 1.42.0
**Build:** `dub build --root=tests/perf_consumer --compiler=ldc2 --build=release --force`

## Workload and method

The native consumer creates deterministic interleaved RGB8 input with
`(x*29 + y*17 + channel*53) & 255`, then times the complete owned full-ROI
operation at percentiles 1 and 99, including output allocation and raster
writes. Each shape receives two warm-ups and seven timed runs; the median is
reported. The source construction, output preflight and owner destruction are
outside the timed interval. Before timing, every output sample is checked to be
finite normalized sRGB in `[0,1]`.

Runs were pinned to CPU 0 on Ubuntu 26.10 x86-64, Intel Core i7-9750H, with the
reported `powersave` governor. The fixed histogram occupies 512 KiB; the
reported output payload is `width*height*3*sizeof(float)`. No speedup against a
different algorithm or platform is claimed.

## Results

| ROI | Median | Throughput | Replicates |
|---:|---:|---:|---:|
| 512 × 384 | 45,606 μs | 4.311 Mpixel/s | 7 |
| 1024 × 768 | 179,950 μs | 4.370 Mpixel/s | 7 |

These measurements establish a repeatable bounded workload and a baseline for
later same-machine comparisons. They do not complete release performance
qualification; rerun on the exact candidate head and supported CI hardware.

## Production-size follow-up and local optimization

**Status:** local working-tree evidence, not release qualification. **Commit base:** `8a58176`. **Compiler:** LDC 1.42.0, D frontend 2.112.1, LLVM 19.1.7. **DUB:** 1.40.0. **Build:** `dub run --root=tests/perf_consumer --compiler=ldc2 --build=release --force`. **Host:** Ubuntu 26.10, Linux 6.17.0-22-generic, x86-64, Intel Core i7-9750H. **Affinity:** CPU 0; governor reported as `powersave`; frequency was not locked.

The initial committed implementation was rebuilt from `8a58176` and compared
with the working version under the same LDC 1.42.0 build and CPU-0 affinity.
The working version changes RGB8 transfer work to float, creates a 256-value
color-d-derived sRGB decode table per call, and creates a 16,384-interval
color-d-derived output-encoding table per call with linear interpolation. The
consumer still checks the independent XYZ-D65-Y oracle; its expanded 256×256
deterministic RGB case observed a maximum error of one output byte, matching
the existing one-byte acceptance bound.

The benchmark retains one decoded RGB8 source across calls. Each timed
operation includes histogramming, table setup, output allocation, color
processing and raster writes; input setup and output semantic preflight are
outside timing. Output destruction is outside timing. Preview runs execute 12
full owned-result calls per batch, with two warm-up batches and seven timed
batches. The 12-MP and 24-MP cases run once per batch.

| Workload | Commit base | Working version | Working median |
|---|---:|---:|---:|
| 512 × 384 | 44,650 μs; 4.403 MP/s | 11,768 μs; 16.707 MP/s | 3.79× faster |
| 1024 × 768 | 177,264 μs; 4.437 MP/s | 42,874 μs; 18.343 MP/s | 4.13× faster |
| 1920 × 1080, one call | — | 117,978 μs; 17.576 MP/s | — |
| 1920 × 1080, binary mask, one call | — | 116,949 μs; 17.731 MP/s | — |
| 1920 × 1080, 12 repeated calls | — | 1,415,738 μs per batch | 117,978 μs/call |
| 1920 × 1080, mask, 12 repeated calls | — | 1,403,393 μs per batch | 116,949 μs/call |
| 4000 × 3000 (12 MP) | — | 734,565 μs; 16.336 MP/s | — |
| 6000 × 4000 (24 MP) | — | 1,516,889 μs; 15.822 MP/s | — |

The mask case used a deterministic binary selection with 20% excluded pixels.
Its measured median was 0.6% lower than the unmasked case, so this run does not
resolve a small mask overhead; the mask adds one byte read in the
threshold-estimation pass. The first 1080p pass took about 118 ms, so
full-resolution repeated slider previews are still not a 30-fps workload.
Downsampled preview input or further kernel work is needed for that target.
This benchmark includes fresh result allocation on every preview call and does
not measure destination-buffer reuse.

Coarser histogram experiments tested 8,192, 16,384 and 32,768 bins on the
independent 256×256 deterministic RGB oracle. The first two exceeded the
one-byte output tolerance (maximum error: two codes). The 32,768-bin case
passed at one code but measured 44,895 μs for 1024×768 (17.517 MP/s), versus
42,874 μs (18.343 MP/s) for 65,536 bins under the same compiler and affinity.
The smaller histogram showed no speed benefit and weakened threshold
resolution, so the implementation retains 65,536 bins.

## Remaining execution boundary

The imagery kernel still reads three source channels through
`RasterView.trySample` in both passes and writes three output channels through
`trySetSample`. The raster-d 0.3.0 source documents `trySample` as a
control-plane accessor; its fast validated pointer adapters are package
internal. The public pointwise families cover one input plane or two
same-sample-type inputs, not one three-channel `ubyte` pixel mapped to three
`float` outputs. imagery-d therefore has no safe public route to fuse these
passes into raster-d's fast execution adapters.

This is the next concrete performance gap. Reaching smooth full-resolution
preview requires a raster-d generic multi-plane source/destination kernel (or
equivalent borrowed row-span contract), with alias, signed-stride and lifetime
rules validated there. The image-specific histogram, sRGB/XYZ math and output
semantics remain in imagery-d. The current local raster-d checkout is on its
frozen `release/0.2` branch with unrelated untracked benchmark artifacts; this
measurement made no changes to that repository.

Linux hardware counters were unavailable because the host sets
`perf_event_paranoid=4`. The earlier 4.311/4.370 MP/s result above used LDC
1.43.0 and is retained as its historical receipt; comparisons in this section
use the exact same LDC 1.42.0 configuration for commit base and working code.

## Kernel attribution diagnostic

The `--kernels-only` mode in `tests/perf_consumer` compares distinct work on a
retained 1024×768 deterministic RGB8 fixture. It uses LDC Release, CPU 0
affinity, two warmups and seven medians on the same i7-9750H host. The dense
color cases repeat the fixture 16 times to amortize timer overhead; throughput
is expressed per logical pixel operation. The table-driven case builds the
same 256-entry decode and 16,384-interval encode tables used by imagery before
the timed loop. The raster case performs three `trySample` reads and three
`trySetSample` writes to float storage per pixel, but no color transform,
histogram, allocation, or output publication.

| Diagnostic kernel | Median | Logical throughput |
|---|---:|---:|
| color-d sRGB decode + XYZ-D65-Y matrix, dense values | 631.8 ms / 16 repeats | 19.92 MPixel/s |
| color-d direct sRGB decode + encode, dense values | 1,023.2 ms / 16 repeats | 12.30 MPixel/s |
| imagery lookup tables + XYZ-D65-Y + output interpolation, dense values | 396.8 ms / 16 repeats | 31.71 MPixel/s |
| raster-d 3 reads + 3 writes, identity copy | 7.03 ms / 1 pass | 111.85 MPixel/s |

These are diagnostic kernels, not a percentage decomposition of the full
stretch: their control flow, memory traffic, and outputs differ. They do show
that direct per-channel sRGB power transfers are expensive, but imagery has
already removed those transfers from its per-pixel loop with lookup tables.
The current table-based color/Y work is roughly 2.7× the accessor-only
throughput, while the complete current stretch measured 11.70 MPixel/s in a
separate run. Thus both histogram/multipass overhead and the scalar raster
access API are plausible targets; the measurement does not justify attributing
the full-kernel cost to color-d. A targeted color-d improvement should focus
on reusable batch/table facilities or cheaper standards-correct transfer
evaluation, and should be accepted only if it improves imagery's existing
table-driven kernel without reducing numerical accuracy.

The host was not frequency-locked: a separate full-kernel rerun varied from
the earlier 18.34 MPixel/s to 11.70 MPixel/s. Treat absolute throughput here as
local evidence only, not a stable performance guarantee.

## raster-d 0.4.0 and color-d 0.3.0 integration

The current imagery implementation raises its DUB requirements to
`raster-d ~>0.4.0` and `color-d ~>0.3.0`. It uses color-d's exact
`makeSRgb8DecodeTable!T()` for the bounded byte input. The 16,384-interval
output-encoding table remains an imagery-owned per-call approximation because
color-d's exact batch encoder operates on floating-point color arrays and does
not replace this bounded interpolation path.

Both histogram and transform passes now use raster-d's scoped `withPlane` /
`withPlanesInto` data windows. Source channel reads, mask reads, and output
writes no longer call `trySample` or `trySetSample` per pixel. The result stays
interleaved to preserve the existing imagery API contract. raster-d's
multi-destination overlap validation conservatively rejects intersecting byte
envelopes, including disjoint interleaved channels; imagery therefore validates
the source against one output plane with `withPlanesInto` and borrows the two
sibling destination planes separately. The destination is a fresh owner with
validated channel offsets, so its output planes cannot alias the source or
each other.

Measured with LDC 1.42.0 Release on CPU 0 on the same i7-9750H host, with two
warmups and seven medians per shape:

| Workload | Median | Throughput |
|---|---:|---:|
| 512 × 384 | 7,709 μs | 25.50 MPixel/s |
| 1024 × 768 | 27,905 μs | 28.18 MPixel/s |
| 1920 × 1080, one call averaged across 12-call batches | 71,974 μs/call | 28.81 MPixel/s |
| 1920 × 1080, binary mask, 12-call batches | 72,522 μs/call | 28.59 MPixel/s |
| 4000 × 3000 (12 MP) | 464,132 μs | 25.86 MPixel/s |
| 6000 × 4000 (24 MP) | 908,538 μs | 26.42 MPixel/s |

Against the prior working implementation's same-compiler 1024×768 result of
42,874 μs (18.34 MPixel/s), the scoped-window version measured about 1.54×
faster in this run. Its 1080p pass is still about 72 ms, roughly 14 frames/s;
30-fps full-resolution preview is not achieved. CPU frequency was not fixed,
so these remain local diagnostic values. The independent 12-case P6/XYZ-D65-Y
oracle passed on both DMD and LDC with maximum output error of one byte.

## Pass attribution follow-up

The bounded perf consumer adds `--pass-attribution`, which times a 1080p
masked histogram pass including the fixed-bin threshold scan, the transform
pass including RGB8 lookup, XYZ-D65-Y/scaling, output interpolation and three
float writes, and the complete public operation separately. The isolated pass
work reuses the same interleaved fixture and raster-d scoped windows. LDC
1.42.0 Release, CPU 0 affinity, two warmups and seven medians produced:

| Workload | Median | Throughput |
|---|---:|---:|
| Histogram + threshold scan, binary mask | 11.14 ms | 186.07 MPixel/s |
| Transform + output writes | 39.37 ms | 52.67 MPixel/s |
| Both isolated passes | 50.74 ms | — |
| Complete owned-result operator, binary mask | 74.28 ms/call | 27.92 MPixel/s |

The two isolated passes sum to less than the complete API because they omit
validation, output allocation/import, output-curve table generation and some
wrapper work. This is an attribution aid, not a direct percentage breakdown.
The first transform diagnostic used a fixed `0.75/Y` scale and did not model
percentile-bin branches or clipping. Its 39 ms result and the resulting 24 ms
apparent gap are superseded by the corrected comparison below. In the same run, the
existing 1024×768 identity raster accessor microbenchmark reached
142.38 MPixel/s; a table-driven color/Y/encode microbenchmark reached
41.84 MPixel/s. These figures point toward per-pixel color arithmetic and
encoding as the next investigation, rather than raster-d accessor overhead,
but do not isolate individual instructions or prove color-d is at fault.
Hardware counters remain unavailable and CPU frequency is not fixed.

### Corrected paired comparison

The original transform microbenchmark omitted production's bin mapping and
clipping, which made it too cheap. The perf consumer now derives the 1st/99th
nearest-rank bins from the selected masked pixels and applies the production
branches, clipping and output interpolation. It times that kernel beside the
complete owned-result API in the same process with the same 1080p source and
mask, two warmups and seven replicates. One LDC 1.42.0 Release / CPU 0 run:

| Workload | Median |
|---|---:|
| Histogram + threshold scan | 12.18 ms |
| Corrected transform + output writes | 68.28 ms |
| Complete masked API call | 74.90 ms |

The isolated pass medians are not additive: their sum is about 7% above the
complete call, consistent with separate timing and wrapper/validation
differences. They show that production's transform accounts for most of the
runtime and remove evidence for a roughly 20–25 ms hidden wrapper cost. The
matched output allocation/touch diagnostic was 0.82 ms. Further attribution
should focus on production-equivalent pixel work or paired compiler/codegen
experiments, not guessed wrapper overhead.

A repeat after a forced Release rebuild measured 12.59 ms histogram,
66.09 ms corrected transform, and 73.29 ms full API. This confirms the same
overall attribution while showing ordinary local run variation; absolute
timings remain diagnostic because CPU frequency is uncontrolled.

The staged diagnostic additionally separates RGB8 decode + XYZ-D65-Y/scaling
from output encoding. On a subsequent run, the linear stage took 25.64 ms.
Encoding from the 16,384-interval table plus raster writes took 24.11 ms. An
exact scalar `LinearSRgb!float.toSRgb` pass over the same clipped staged RGB
values plus writes took 73.77 ms. Across all staged channels, the table's
maximum absolute difference from exact color-d encoding was `9.24e-7` in
normalized sRGB. Thus the existing interpolation table is materially faster
than scalar exact encoding on this host and remains well inside the observed
one-byte P6 oracle tolerance; it does not show whether color-d could provide a
faster exact batch kernel. The staged pass includes an extra full-size RGB
buffer and is diagnostic only, not a production timing decomposition.

## LDC SIMD transform follow-up

The production LDC float transform now handles four pixels per
`core.simd.Vector!(float[4])` group. Byte-table lookup, histogram-bin mapping,
gamut policy, output-curve interpolation, and raster window loads/stores remain
scalar around the vectorized luminance, scale, and three-channel multiply. A
scalar tail handles widths not divisible by four. DMD and non-LDC builds keep
the portable scalar implementation; the private double instantiation also
remains scalar. This specialization was added only after a same-input kernel
probe showed a 2.13× LDC improvement (61.65 ms scalar vs 28.91 ms SIMD for
1920×1080 linear math and output-buffer writes) with zero float error on that
fixture. The DMD probe showed only 1.01× and did not justify compiler-specific
SIMD there.

On a subsequent LDC 1.42.0 Release run with the same 1080p full-API benchmark
workload, the median was 61.84 ms/call (33.53 MPixel/s), versus the previously
measured 73–75 ms scalar working version, an observed 16–18% reduction in
elapsed time. The 12 MP and 24 MP cases measured 407.4 ms (29.46 MPixel/s) and
810.7 ms (29.60 MPixel/s). These are local single-run diagnostics with
unlocked CPU frequency, not a portable guarantee. The DMD 1080p scalar build
measured 463.8 ms/call (4.47 MPixel/s); the DMD production sweep was stopped
after 12 MP because its runtime was substantially higher. This indicates a
material compiler/code-generation gap for this kernel, separate from the
LDC-only SIMD contribution.

The forced DMD and LDC unit-test builds both passed. The independently computed
P6 oracle passed all 12 cases with maximum one-byte error, including the
deterministic 256×256 RGB input. The four-lane kernel test reported zero
maximum absolute error against the scalar math on its 1080p fixture. Re-run
these diagnostics with `dub test --force` under both compilers, then build the
PPM consumer and perf consumer in Release; run `--production` for complete
operator measurements.

## DMD versus LDC code-generation diagnosis

Both compilers are installed locally (DMD 2.111.0, LDC 1.42.0). The perf
consumer now reports the active compiler in its output; earlier hard-coded
`LDC-Release` labels were inaccurate for DMD runs and have been corrected.
Release binaries were built separately, copied aside, then run alternately on
CPU 0 to avoid concurrent builds, binary replacement, and same-core contention.
Three paired 512×384 and 1024×768 runs produced:

| Compiler | 512×384 median | 1024×768 median | 1024×768 throughput |
|---|---:|---:|---:|
| DMD 2.111.0 | 46.2–48.7 ms | 180.2–189.5 ms | 4.15–4.36 MPixel/s |
| LDC 1.42.0 | 6.85–6.99 ms | 24.1–26.3 ms | 30.0–32.7 MPixel/s |

The gap is approximately 7× on this host. Isolated staged work puts table
encoding/writes near parity (about 60–63 ms at 1080p) and decode/Y/scale in
the same broad range (about 48–90 ms, with run variation). The histogram
diagnostic was much slower under DMD (about 286 ms versus 35 ms), but that
diagnostic also includes a separate benchmark implementation and large staged
buffers, so it is not a clean per-pass attribution of the public API.

The object files provide a stronger code-generation clue: `nm -C` on the DMD
consumer shows externally called `RasterPlaneWindow!ubyte.load` and
`WritableRasterPlaneWindow!float.store` symbols, while the LDC consumer has no
matching symbols. This is consistent with LDC inlining the raster-d affine
window accessors and DMD retaining a function call for each sample. The
production transform performs three loads and three stores per pixel; the
histogram performs three more loads. This is the leading explanation for the
compiler gap, though symbol presence alone does not prove the whole timing
difference.

An imagery-side trial replaced histogram slice indexing with a trusted pointer
increment based on the `ushort` bin range. A single DMD run appeared faster,
but paired follow-up results did not isolate a stable improvement, so the
change was reverted. This avoids keeping unchecked code without robust
evidence. The current raster-d API exposes affine windows but no row-span
access for interleaved planes. A durable fix likely belongs in raster-d: make
the tiny validated accessors reliably inline for DMD, or expose an equivalent
validated row-span contract that imagery can use without per-sample calls.
Until then, imagery keeps the common safe window API and its LDC-only measured
SIMD specialization. No package/toolchain changes were needed; DMD 2.111.0 is
present locally.

## raster-d 0.4.1 row-view integration

raster-d 0.4.1 adds `RasterPlaneRow`/`WritableRasterPlaneRow`, `row(y)` views,
and contiguous-row spans. imagery now uses the row views in histogram and
transform loops so row-stride arithmetic is hoisted once per row. The RGB
planes use sample stride 3, so `contiguousRowSpan` is intentionally unavailable
for this interleaved layout; the row accessors still load/store one strided
sample at a time.

The same local Release consumer and CPU-0 methodology was used before and after
the imagery integration. At 1024×768, the v0.4.0 code measured DMD 180.2–189.5
ms and LDC 24.1–26.3 ms across three paired runs. With raster-d 0.4.1 row
views, one follow-up measured DMD 179.6 ms and LDC 21.9 ms. This suggests a
small LDC benefit in this sample and no material DMD improvement; CPU frequency
is unlocked, so the single follow-up is diagnostic rather than qualification.
`nm -C` on the DMD binary still shows calls to both window and row `load` /
`store` methods, explaining why row-stride hoisting alone does not close the
DMD gap. The Release benchmark compiles under both compilers, both imagery
unit-test builds pass, and the independent P6 oracle still passes all 12 cases
with maximum one-byte error.

## raster-d 0.5.0 strided-pointer integration

raster-d 0.5.0 adds callback-scoped `data` pointers and `sampleStride` to
read-only and writable row values. The imagery histogram and transform now
hoist each row pointer and stride before the inner loop, then use direct
strided indexing inside the raster-d callback. The narrowly scoped callback
closures are `@trusted`: raster-d validates affine ranges and retains the
pointer lifetime boundary; imagery never stores these pointers beyond the
callback. Destination channels are still separately borrowed because the
generic multi-destination alias contract conservatively treats their shared
interleaved allocation as overlapping.

With raster-d v0.5.0, DMD Release at 1024×768 measured 180.509 ms
(4.357 MPixel/s), compared with 179.611 ms (4.379 MPixel/s) in the earlier
single-run v0.4.1 follow-up. LDC Release measured 23.806 ms (33.035 MPixel/s),
compared with 21.916 ms (35.884 MPixel/s) in that same earlier follow-up.
These single-run comparisons have an unlocked CPU frequency and show no
full-operation improvement yet; the raster-d result of 1.79 ns/pixel
(approximately 2.1× over its prior row path) is an isolated RGB-kernel
benchmark, not a direct prediction of complete imagery throughput. The DMD
and LDC unit tests pass, the PPM consumer builds with the new dependency, and
the independent XYZ-D65-Y oracle passes 12 cases with maximum one-byte error.

After raster-d v0.5.0 became available from the ordinary DUB package cache, the
temporary local package override was removed and the Release consumers were
rebuilt against `/home/alexander/.dub/packages/raster-d/0.5.0/`. A repeat run
measured DMD 179.481 ms (4.382 MPixel/s) and LDC 22.800 ms (34.493 MPixel/s)
at 1024×768. This confirms that the direct-row API is actually used from the
published package; the overall DMD operation remains near the prior baseline.
Both compilers' unit tests passed, and the independent oracle again passed all
12 cases with maximum one-byte error. This was a single diagnostic repeat with
CPU frequency unlocked, not performance qualification.

## Direct XYZ-D65 Y row

The full-operation attribution showed that scalar DMD spent much of its time
constructing/converting `LinearSRgb!T` solely to read `.toXyzD65.y`. The
production path now evaluates the same XYZ-D65 matrix row directly using
`Y = (87098/409605)R + (175762/245763)G + (12673/175545)B`. The four-lane LDC
kernel already used these coefficients; the scalar histogram and transform
paths now use the same row. XYZ X/Z are not computed when the operation only
needs luminance.

The independent 12-case XYZ-D65-Y oracle passed with maximum one-byte output
error after this change. In the same local 1024×768 Release consumer, DMD
improved from 179.481 ms (4.382 MPixel/s) to 49.681 ms (15.830 MPixel/s), a
3.62× speedup. LDC measured 22.552 ms (34.872 MPixel/s) versus 22.800 ms
(34.493 MPixel/s), effectively unchanged. A 1920×1080 attribution run after
the change measured 33.250 ms for histogramming and 191.501 ms for the staged
transform diagnostic; the complete owned-result call measured 173.426 ms.
These stage values come from a diagnostic staged-buffer path and must not be
added as if they were disjoint portions of the full API. Host frequency remains
unlocked, so these are local results rather than portable qualification.

The output sRGB encoding table was then reduced from 16,384 to 4,096 intervals
(64 KiB to 16 KiB of float samples), improving cache residency. The independent
12-case output oracle still passed with maximum one-byte error. DMD Release at
1024×768 improved from 49.681 ms to 47.001 ms (15.830 to 16.732 MPixel/s,
5.7%); LDC measured 22.699 ms (34.646 MPixel/s), effectively unchanged from
22.552 ms. This small local gain does not close the 30-fps full-HD target.

A dedicated repeated full-HD run (12 calls per batch, two warmups, seven
replicates, CPU 0 affinity) measured DMD at 136.523 ms/call and LDC at
59.430 ms/call without a mask; these are the pre-hoisted-reciprocal results.
They correspond to about 7.3 FPS on DMD and 16.8 FPS on LDC. DMD's explicit four-lane
production-kernel trial was slower than the scalar path (about 58.9 vs 49.7 ms
at 1024×768), so it was disabled again. The LDC vector path remains enabled.

The scalar transform also divided the mapped percentile-bin offset by the
same `upperBin - lowerBin` for every pixel. The reciprocal is now computed
once per operation and multiplied into each offset. The independent byte
oracle still passes. At 1024×768, the latest medians were 46.275 ms DMD
(16.995 MPixel/s) and 22.850 ms LDC (34.417 MPixel/s). Repeated full-HD
medians were 125.357 ms DMD / 120.345 ms masked and 57.057 ms LDC / 56.782 ms
masked. This improves on the prior run but remains above the 33 ms 30-fps
budget; CPU frequency is unlocked and these figures are local diagnostics.

The backend-tuned table was then verified in the full-HD workload: 4,096
intervals for DMD and 1,024 for LDC. Latest 1024×768 medians were 48.317 ms
(16.277 MPixel/s) for DMD and 20.532 ms (38.303 MPixel/s) for LDC. Repeated
full-HD medians were 120.345 ms/call for DMD and 55.073 ms/call for LDC
(masked: 120.345 ms and 55.073 ms in their respective runs). Relative to the
4,096-interval LDC run, 1,024 intervals improved 1024×768 throughput by about
11% and full-HD latency from 57.057 to 55.073 ms. The DMD 1,024-interval trial
was slower, so DMD keeps 4,096. The one-byte oracle passed on both table
choices. Neither backend has reached the 33 ms 30-fps budget.

Reproduce the pass and full-operator runs with:

```sh
dub build --compiler=ldc2 --build=release --force
taskset -c 0 ./m3-levels-paired-perf --pass-attribution
taskset -c 0 ./m3-levels-paired-perf --production
taskset -c 0 ./m3-levels-paired-perf --kernels-only
```

## Y-only matrix experiment

The XYZ-D65 Y row was also expressed directly with its three color-d
coefficients and compared against `LinearSRgb!float.toXyzD65.y`, with both
kernels using color-d's RGB8 decode table on the same 1024×768 repeated
fixture. The exhaustive comparison over all 16,777,216 RGB8 triplets found
zero differing Y values. In one paired local LDC Release run, table decode
plus direct Y measured 359 MPixel/s and table decode plus the XYZ-D65
conversion's Y component measured 348 MPixel/s. This small difference was not
reflected in the complete 1080p operation, which remained around 73–74 ms;
the compiler already optimizes away unused X/Z work. The production code
therefore retains color-d's named conversion for clarity and has no custom
duplicate matrix path. These dense microbenchmarks omit output work and are
diagnostic only.

The per-call 16,385-sample sRGB output-curve setup itself measured 0.122 ms
median in the same seven-replicate LDC diagnostic. That is negligible beside
the roughly 74 ms full operation, so caching the table would add shared state
and lifetime/concurrency concerns without a meaningful expected gain. The
matching 24,883,200-byte output allocation plus a full-buffer touch measured
1.17 ms. This rules out allocation/page touching as the source of the roughly
24 ms gap between the earlier isolated pass sum and complete API call. The
touch microbenchmark is approximate: it uses `memset` and does not include
raster import or the actual output values. The histogram remains a bounded
512 KiB stack array; an isolated zero-fill timer was optimized away by LDC and
was discarded rather than treated as evidence. The current attribution mode
reports each stage separately and no longer presents a misleading aggregate
that includes all diagnostic-only staged kernels.

## raster-d v0.5.1 parallel transform — 2026-10-25

Imagery now uses `withPlanesIntoParallel` for the owned-result transform.
`workerLimit` and `minimumChunk` are explicit runtime parameters; the default
worker limit is zero, which keeps the public operation serial. The transform
passes all three interleaved float destinations to raster-d for affine
disjointness validation. Each worker receives disjoint row ranges, and the
operation returns only after raster-d joins all per-call threads. Clipping
failure is published through an atomic status; partial writes remain confined
to the temporary result, which is discarded unless the complete pass succeeds.

The perf consumer compares serial and four-worker full operations in
alternating order with two warmups and seven medians per mode. On the local
Intel Core i7-9750H with LDC 1.42.0 Release, one paired run measured:

| Workload | Serial | Four workers | Speedup |
|---|---:|---:|---:|
| 1024 × 768 | 24.080 ms | 7.750 ms | 3.11× |
| 1920 × 1080 | 64.469 ms | 21.149 ms | 3.05× |
| 1920 × 1080, mask | 65.700 ms | 22.191 ms | 2.96× |

The same paired DMD 2.111.0 Release run measured:

| Workload | Serial | Four workers | Speedup |
|---|---:|---:|---:|
| 1024 × 768 | 51.695 ms | 21.103 ms | 2.45× |
| 1920 × 1080 | 138.964 ms | 56.576 ms | 2.46× |
| 1920 × 1080, mask | 133.254 ms | 50.612 ms | 2.63× |

These historical v0.5.1 measurements were taken before the v0.5.5 row-worker
fix; current results are recorded below. They remain useful as a baseline, not
as the current performance claim.

The independent P6/XYZ-D65-Y oracle now runs 24 serial/parallel cases on DMD
and LDC, covering masks, constant and neutral images, 256×256 deterministic
RGB, and small-image sequential fallback. Both compilers observed at most one
byte of output error. DMD/LDC Release unit tests and the DMD parallel
`Clip=false` rollback consumer passed.

Reproduce the local parallel comparison with:

```sh
dub build --root=tests/perf_consumer --compiler=ldc2 --build=release --force
tests/perf_consumer/m3-levels-paired-perf --parallel-luminance
```

## raster-d v0.5.5 parallel row fix — 2026-10-27

The v0.5.4 executor defect and requirements were recorded in
[raster-d issue #278](https://github.com/alex-1974/raster-d/issues/278).
Version 0.5.5 binds each thread's worker index through a factory parameter and
adds repeated exact-coverage, disjoint-slot, and multi-phase tests. The issue
is closed in the release. imagery-d now allocates a 65,536-bin histogram and
selected-pixel counter per worker; the phase callback uses the worker index,
then reduces all private slots after raster-d's barrier. The transformation
phase also uses the requested worker count.

Independent Release consumers and paired benchmarks passed with DMD 2.111.0
and LDC 1.42.0. Each pair used two warm-ups and seven alternating measurements
on the local Intel Core i7-9750H host; CPU frequency was not locked. Timings
include thread creation and the complete owned-result operation.

| Compiler | ROI | Mask | Serial | Four workers | Speedup |
|---|---:|:---:|---:|---:|---:|
| LDC 1.42.0 | 1024 × 768 | no | 21.356 ms | 7.726 ms | 2.76× |
| LDC 1.42.0 | 1024 × 768 | yes | 21.085 ms | 6.899 ms | 3.06× |
| LDC 1.42.0 | 1920 × 1080 | no | 54.922 ms | 18.141 ms | 3.03× |
| LDC 1.42.0 | 1920 × 1080 | yes | 56.057 ms | 18.690 ms | 3.00× |
| DMD 2.111.0 | 1024 × 768 | no | 52.731 ms | 16.204 ms | 3.25× |
| DMD 2.111.0 | 1024 × 768 | yes | 48.847 ms | 14.373 ms | 3.40× |
| DMD 2.111.0 | 1920 × 1080 | no | 132.778 ms | 39.107 ms | 3.40× |
| DMD 2.111.0 | 1920 × 1080 | yes | 124.911 ms | 36.199 ms | 3.45× |

### 1080p worker-count sweep after the SIMD alignment fix

The complete operation was measured with worker limits 1, 2, 4, 6 and 8,
with and without a mask. Eight workers bring DMD below the 33.3 ms 30-fps
target (26.7–27.6 ms); six workers also meet it (29.6–31.6 ms). Four workers
remain above target with DMD. LDC is
already below target with four workers (20.0–22.5 ms); six and eight show no
consistent masked advantage on this frequency-variable host. For this host,
use eight workers with DMD and four with LDC when a 1080p 30-fps preview is
required. The API default remains sequential so applications can choose a
budget appropriate to their own workload and hardware.

| Compiler | Workers | Mask | Serial | Timed request | Speedup |
|---|---:|:---:|---:|---:|---:|
| DMD 2.111.0 | 2 | no | 127.183 ms | 65.537 ms | 1.94× |
| DMD 2.111.0 | 2 | yes | 123.461 ms | 66.188 ms | 1.87× |
| DMD 2.111.0 | 4 | no | 131.458 ms | 38.146 ms | 3.45× |
| DMD 2.111.0 | 4 | yes | 127.043 ms | 37.123 ms | 3.42× |
| DMD 2.111.0 | 6 | no | 133.807 ms | 31.608 ms | 4.23× |
| DMD 2.111.0 | 6 | yes | 126.528 ms | 29.644 ms | 4.27× |
| DMD 2.111.0 | 8 | no | 132.059 ms | 26.729 ms | 4.94× |
| DMD 2.111.0 | 8 | yes | 137.485 ms | 27.626 ms | 4.98× |
| LDC 1.42.0 | 4 | no | 71.144 ms | 19.985 ms | 3.56× |
| LDC 1.42.0 | 4 | yes | 81.506 ms | 22.503 ms | 3.62× |
| LDC 1.42.0 | 6 | no | 75.767 ms | 15.859 ms | 4.78× |
| LDC 1.42.0 | 6 | yes | 94.426 ms | 32.153 ms | 2.94× |
| LDC 1.42.0 | 8 | no | 72.457 ms | 19.758 ms | 3.67× |
| LDC 1.42.0 | 8 | yes | 78.384 ms | 22.303 ms | 3.52× |

The DMD sweep was stable enough to show a clear scaling trend. LDC's host
frequency drift produced an anomalous six-worker masked result, so four
workers remain the more predictable LDC choice. Reproduce either sweep with:

```sh
dub run --root=tests/perf_consumer --compiler=dmd --build=release --force -- --worker-sweep
dub run --root=tests/perf_consumer --compiler=ldc2 --build=release --force -- --worker-sweep
```

The complete P6/XYZ-D65-Y oracle passed 24 serial/four-worker cases with each
compiler, including masks, with at most one output-byte error. Debug and
Release imagery unit and independent consumer runs passed on DMD and LDC.
Reproduce the paired matrix with:

```sh
dub run --root=tests/perf_consumer --compiler=ldc2 --build=release --force -- --parallel-luminance
dub run --root=tests/perf_consumer --compiler=dmd --build=release --force -- --parallel-luminance
```
