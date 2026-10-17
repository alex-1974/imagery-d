# M3 RGBA — Exact sRGB8 LUT inside public raster zip: XPS results

**Date:** 2026-10-13 18:11:48 UTC (Europe/Vienna: 20:11:48 CEST).
**Status:** qualified **restricted research** on actual Dell XPS hardware.
**Boundary:** these results establish a faster **fixed-opacity 0.37**
encoded-straight `SRgba8` callback under **the same public**
`raster.zipTransformInto` checks as its direct-sRGB competitor.
They are **not** a production imagery API acceptance, a speed promise
for arbitrary color/layouts/opacity, nor evidence of checked error
propagation for all pixel failures.

Related:
- [LUT + raster zip contract](m3-rgba-lut-packed-zip.md)
- [earlier packed-array LUT XPS run](m3-rgba-lut-xps-2026-10-13.md)
- [earlier stage attribution](m3-rgba-hotpath-xps-2026-10-13.md)
- [original source-over XPS sessions](m3-rgba-xps-2026-10-13.md)

## Input provenance and checks

**User-supplied archive:** `ldc143-20261013T181148Z.tar.gz`.
Compressed archive SHA-256:

```text
bd2c3fceac41290cd671b1edbc2ee6f62eed2df9f428647abd53fb3802eb3255
```

The measured read-only source snapshots were **excluded** from the uploaded
archive; source identity derives from the runner's recorded `git archive`
mechanism and measured git SHAs. Neither active sibling branch nor
pre-existing untracked work was switched or cleaned.

| Provenance / integrity | Checked observation |
|---|---|
| Host / CPU | `xps-15`, Intel Core i7-9750H, 6C/12T x86-64 AVX2 |
| Linux | 6.17.0-22-generic |
| Imagery measured HEAD | `bc660843443170f5abfbe58a9163d319870387fe`, research branch |
| Source mode | `pinned-v0.2.0`, **full** (smoke=0) |
| Measured raster-d | `v0.2.0`: `2f2415851e45001df92ce56dad409f680684ba8d` |
| Measured color-d | `v0.2.0`: `3359f08f4e83941ac1a8451cadefb146b5736019` |
| Toolchain | **LDC 1.43.0** (DMD frontend 2.113.0, LLVM 22.1.8); DUB 1.42.0 |
| Execution | Release binary **directly invoked** under `/usr/bin/time -v` (build once, separately) |
| SHA-256 | **24/24 raw CSV files verify** against `CHECKSUMS.sha256` |
| Complete scenarios / timed rows | 24 cases × 7 rounds (512²) or × 5 rounds (2048²) = **144/144 paired rounds** |
| Callback/output correctness | All 24 `ZIP-EXACT-LUT PASS` markers; 144/144 rows with `pixel_differences=0`; every ROI pixel byte-equal **between LUT zip, direct zip, and the unchanged four-plane adapter**, before timing and after each round |
| ROI and alias | Outside-ROI sentinel verified; **both actual source/destination physical overlap directions rejected** by raster error classification before any write, and source bytes verified unchanged |
| GC instrumentation | 144/144 measured paired rounds report **0 current-thread GC allocated-byte delta** |
| stderr/build | All 24 scenario stderr logs empty, release build completed; only pre-existing `mir-core` LLVM-version deprecation notices in build log |
| OS summary | All 24 measured processes exit 0, with 0 major page faults and 0 process swaps |

### Exact workload

The **only intended difference** between the two comparands is:
- direct decode: `SRgba8 -> color-d.toLinear` in the pure pixel callback;
- LUT decode: runtime-prepared, immutable **256 × double** values from the
  **same actual color-d runtime conversion**.

Both variants use `raster.zipTransformInto!callback` with identical shape,
region, injectivity, exact reachable-byte physical alias checks, and
public raster executor dispatch. Both use `color-d`'s ordinary
premultiply, opacity-scaled linear-light source-over, unpremultiply,
sRGB re-encode and `tryToSRgba8`. The caller-provided buffers and
normal test lifecycle are unchanged.

The LUT is initialized **once at module startup** in
`shared static this()` and is thereafter **immutable**. This
satisfies the callable's `@safe pure nothrow @nogc` contract, but a
process-global immutable table is still a **research-only lifetime/ownership
choice**, not a selected general API.

Input patterns: **mixed** (0/128/255 alpha), **opaque** (255),
**transparent** (0 alpha, with **hidden nonzero RGB**).
Layouts: **compact** and **row-padded** packed RGBA; region shapes:
whole image and nonzero-origin near-full ROI (`7,11,w-14,h-22`).
Note these partial regions remain ~94–98% of the whole image and
**do not benchmark tiny interactive viewport updates**.

## Measured speed by alpha distribution

The table shows **median of the 4 per-case medians** for each
size × alpha pattern (2 layout × 2 ROI), with per-case
median of alternating, paired timed rounds.
Values are in **nanoseconds per ROI pixel per complete call**,
i.e. `median_round_microseconds * 1000 / (iterations * ROI_pixels)`.
Speedup column is the **median of per-case ratios**,
not an unpaired quotient or a statistical confidence interval.

| Size | Alpha pattern | Direct zip ns/pix | Exact LUT zip ns/pix | Median paired factor |
|---|---|---:|---:|---:|
| 512² | **mixed** | **172.37** | **67.57** | **2.496×** |
| 512² | opaque | 169.35 | 69.27 | **2.460×** |
| 512² | fully transparent / hidden RGB | 111.63 | 7.47 | **14.870×** |
| 2048² | **mixed** | **176.84** | **71.99** | **2.456×** |
| 2048² | opaque | 177.27 | 72.33 | **2.456×** |
| 2048² | fully transparent / hidden RGB | 108.40 | 7.48 | **14.560×** |

For the representative **mixed-alpha** source-over workload, the
LUT's ~**2.46–2.50×** pixel throughput means approximately
**59–60% less elapsed time** for the timed packed raster
zip operation. The much greater transparent speedups arise
when the output's alpha is zero and the unchanged color-d
unpremultiplication/canonicalization avoids expensive output
color encoding; the direct path nevertheless computes input
sRGB transfer. They are **special cases**, not the
representative RGBA overall speedup.

**All 144/144 individual paired round measurements have
`lut_zip_us < direct_zip_us`**, including all patterns,
both sizes, both layouts and both ROI shapes.
Across all patterns the per-round direct/LUT ratios
range from **2.157× to 15.862×**. No confidence
interval, thermal normalization or independent repeated
session was collected; absolute results are reference-machine
observations, not a stable minimum-guaranteed threshold.

### Representative 2048² full image: per **single** compositing pass

Each 2048² scenario contains 5 rounds × 2 passes.
The values below divide the **median paired round**
elapsed microseconds by two. The ratio uses corresponding
round medians.

| Input alpha | Packed layout | Direct zip ms/image | LUT zip ms/image | Factor |
|---|---|---:|---:|---:|
| mixed | compact | **763.52** | **292.28** | **2.612×** |
| mixed | row-padded | **739.21** | **295.32** | **2.503×** |
| opaque | compact | 774.28 | 309.02 | 2.506× |
| opaque | row-padded | 731.00 | 297.71 | 2.455× |
| transparent | compact | 474.87 | 32.82 | 14.471× |
| transparent | row-padded | 449.78 | 30.67 | 14.663× |

All full-image cases read and write *real owned `RasterLease!SRgba8`*
buffers through the public validated executor. This directly
addresses the old packed-array benchmark's lack of raster
preflight coverage. The four-plane adapter is a separately
validated oracle, **not timed inside these paired zip numbers**;
do not report `2.5×` as a speedup against four-plane without
an equivalent fresh paired comparison.

### Initialization

The run records `lut_init_us` for the **one-time process-level**
immutable table construction from all 256 `color-d` runtime
channel conversions:

- median across 24 cases: **19 microseconds**;
- observed range: **14–38 microseconds**;
- median 512² cases **18 µs**, 2048² **21 µs**;
- the numeric table's payload is **2 KiB**.

This time is **not** added to each `zipTransformInto` call.
A simple amortization division by the per-pixel saving
may be instructive but would not establish a measured
small-ROI crossover, especially because `shared static this()`
initializes before `main()`, not at each image job. A
future general subsystem must explicitly choose when/where
prepared immutable values are stored and how profiles,
input representations and lifetime vary.

## Memory and external conditions

- CPU governor `powersave` on all 12 logical processors;
  no clocks or thermals recorded across the runs.
- Host at start: `MemAvailable = 5,039,076 kB`,
  `SwapFree = 164 kB` of `SwapTotal = 4,194,300 kB`.
  Nearly exhausted *free swap space* alone is not
  proof of swapping within this measurement.
- **0 major page faults and 0 swaps reported** by
  all 24 `/usr/bin/time -v` process records.
- Whole-process maximum resident set size:
  **10,572–10,832 KiB** for 512², and
  **118,064–118,412 KiB** for 2048²
  (~10.3–10.6 MiB and ~115.3–115.6 MiB).
- The harness retains **seven independent source/output
  leases** (four packed for the two zip paths, three
  byte-plane for the canonical differential) and makes
  repeated all-pixel verification reads. RSS is **not**
  the memory cost of one `zipTransformInto` call or
  a single packed compositor. The ~2 KiB table should
  not be confused with the test-process RSS.
- Compared with the earlier LUT array experiment's
  **~628 MiB** 2048² process RSS, this harness retains
  fewer large intermediate decoded `double` arrays.
  The tests are not otherwise matched, so this is
  **not** evidence of an equally sized production
  memory saving due only to using raster zip.
- No isolated temporary-native allocation measurement,
  micro-ROI sweep, CPU affinity isolation,
  perf-counter/codegen proof, AArch64, 4K/8K streaming,
  real imagery mosaic or second qualified XPS
  session has yet been supplied.

## Decisions and next experiments

**Qualified evidence now supports:**

1. **Exhaustive exact RGB8 channel LUT**, runtime-created using
   released `color-d`, agrees on 256/256 values under the
   four-compiler matrix (tested in CI); no local approximation.
2. The LUT retains byte-exact results for all tested
   RGBA fixtures, with the existing **public raster zip
   alias/shape/injectivity execution semantics**.
3. On this XPS, an existing checked-source execution
   mechanism yields **~2.5× mixed-alpha throughput**
   improvement without a second overlap engine
   or any writes to `raster-d` or `color-d`.

**What remains open before any production API or merge:**

- **Failure signaling:** the transform alias
  `T,T->T` cannot propagate a checked
  `tryToSRgba8` error. The research callback
  returns `SRgba8.init` in an unreachable-on-fixture
  quantization-failure branch. This is **not**
  a general checked-`tryComposite` replacement.
- **Runtime opacity:** this callback bakes
  `0.37` into its template-specialized function;
  `raster.zipTransformInto` has no runtime
  context argument. An engine/session design
  needs its own contract and validation.
- **Lifetime and architecture:** module-global
  once-initialized immutable 2 KiB table is
  legal for this strict sRGB8 domain but not
  automatically a suitable architecture for
  varying profiles, sessions, configurable
  color transforms or plugin consumers.
- **Input family:** packed SRgba8 only, no
  premultiplied-linear input validation, planar
  pixel staging, arbitrary input transfer curves,
  or general checked failure paths. The
  repository's 432-scene independent oracle
  and compile-negative view/lifetime tests
  remain separate evidence.
- **Further evidence:** benchmark true small
  offset ROIs (e.g. 32², 64², 128²),
  mixed/zero-alpha boundaries, exact
  prewrite noninjectivity/alias behavior
  and output failure cases; then profile LDC's
  actual code generation and decide whether
  an extended stateful checked transform
  primitive is *really necessary*.
- **Stability:** repeat native run with
  documented CPU clocks/temperature before
  setting absolute regression thresholds.

**Disposition:** retain research-only implementation in
`research/m3-rgba-layer-compositing` and
OPEN/DRAFT PR #73, stacked on Draft #69;
no merge to `research-integration`,
`develop` or `main`, and no writes in
other repositories.
