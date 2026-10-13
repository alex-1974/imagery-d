# M3 RGBA — XPS qualified runtime-exact sRGB byte LUT measurements

**Date:** 2026-10-13, **14:25:52 UTC**.
**Status:** QUALIFIED RESEARCH EVIDENCE for a narrow **8-bit straight-encoded sRGB packed-array consumer**; **NOT** a production API admission, generalized imagery speed claim or cross-platform performance guarantee.

## Source, execution and evidence validation

**Primary evidence:** externally uploaded `ldc143-20261013T142552Z.tar.gz`; SHA-256 of exact compressed upload:

```text
a045607e5aa374bc610ae24d0a8b38ced4e86c86c290ff19e58026af721b78b2
```

A copy of the raw evidence is held in the user's uploaded archive; the
generated pinned source snapshots are **not** inside that archive.
The runner's verified construction (`git archive`) and the recorded
measured source SHA provide provenance, not an independent source-tree
byte hash from the user archive.

| Recorded property | Evidence |
|---|---|
| Machine / CPU | `xps-15`, Intel Core i7-9750H (6C/12T, x86-64, AVX2) |
| Kernel | Linux `6.17.0-22-generic` |
| Imagery research source | `29f0ab58f01ef6168a93455e9ee5c46b169b3731` on `research/m3-rgba-layer-compositing` |
| Measured raster-d | **v0.2.0**, `2f2415851e45001df92ce56dad409f680684ba8d` |
| Measured color-d | **v0.2.0**, `3359f08f4e83941ac1a8451cadefb146b5736019` |
| Toolchain | **LDC 1.43.0** / DMD frontend 2.113.0 / LLVM 22.1.8, DUB 1.42.0 |
| Build/run | One release build, then direct executable invocations under `/usr/bin/time -v`; compiler process excluded |
| Input integrity | **64/64** raw case CSV SHA-256 checksums PASS |
| Case completeness | 60 cases at 512² (5 alpha patterns × 3 opacities × 2 raster layouts × 2 ROIs) + 4 cases at 2048² (mixed, 0.37, 2 layouts × 2 ROIs) |
| Timed rounds | **316/316** (60 × 5 + 4 × 4), 2 image iterations per round |
| Correctness | Each case has an `EXACT-DECODE-LUT PASS` marker; all 316 CSV rows report **0** runtime LUT-value mismatches and **0** current-thread GC-allocated-byte deltas; source explicitly compares all ROI output pixels against direct/color-d and unchanged four-plane imagery research adapter **before and after each round** |
| Cross-layout | Corresponding planar/interleaved canonical output checksums agree for all matched pattern/opacity/ROI cases |
| stderr | 64/64 case stderr files empty |
| Other logs | One `environment.txt`, `build.log`, 64 process `-resource.txt` reports |
| Build notices | Nonfatal `mir-core 1.7.4` `LLVM_version` deprecation diagnostics; release build/link succeeded |

The user’s *live* raster-d HEAD (`1ea67cb6...`) differs from
v0.2.0, but its **measured** pinned source is the exact v0.2.0 commit.
Both sibling worktrees contain pre-existing untracked research files,
and imagery-d has its own untracked artifacts. The runner only read the
repos; it did **not** switch, reset, stage or clean them.

## Results: full color operation versus isolated decode

All values below are measurements of **two packed straight-encoded
sRGB input pixels** processed to a **straight RGBA8 linear-light
source-over output** using the same public color-d
`premultiply`, `sourceOver`, `unpremultiply`, `toSRgb` and
`tryToSRgba8` operations, with runtime opacity.

The LUT is only **256 × 8 = 2048 bytes** of channel-value data.
It is constructed **once at runtime from public color-d v0.2.0**
(`toLinear`), then looked up for each `ubyte` channel; no approximate
transfer formula or altered alpha law was introduced.

### All 512² cases — median-of-case-median values

The first two columns below are **median ns/ROI pixel per operation**,
computed as `median_us * 1000 / (iterations * ROI_pixels)`.
The acceleration factor is **the median of corresponding case ratios**,
not the ratio of unpaired aggregate medians.

| Timed kernel | Direct color-d | Exact runtime LUT | Median paired throughput factor |
|---|---:|---:|---:|
| Two input sRGB RGB values to linear, 6 channels | **116.48 ns/pixel** | **5.69 ns/pixel** | **20.44×** |
| Complete packed-array decode→premultiply→opacity source-over→unpremultiply→sRGB encode→checked RGBA8 storage | **170.35 ns/pixel** | **67.00 ns/pixel** | **2.55×** |

The full-kernel median advantage corresponds approximately to
**60.8% less elapsed time** for the tested color loop,
or **155% more pixel throughput**. All **316/316** individual
rounds record the LUT variant faster than direct conversion in
**both** isolated decode and full packed-array composition.

These numbers do **not** mean `imagery-d`'s existing public
four-plane `tryCompositeRgbaSourceOver` or checked
`raster.zipTransformInto` runs 2.55× faster: the **timed**
direct/LUT comparison executes **packed arrays** without general
raster validation, alias preflight, arbitrary strides or checked
output-lease ownership. Correctness comparison to the four-plane
adapter happens outside the timed region.

### 2048² — mixed alpha, opacity 0.37, full ROI

At 2048² each median is over **4 rounds × 2 complete image passes**.
Timings are per pixel and **per single image pass**:

| Layout | Direct full ns/pixel | LUT full ns/pixel | Paired median-time ratio | Direct full pass | LUT full pass |
|---|---:|---:|---:|---:|---:|
| Interleaved | **167.93** | **66.53** | **2.524×** | **704.33 ms** | **279.06 ms** |
| Planar | **182.14** | **74.12** | **2.457×** | **763.94 ms** | **310.89 ms** |

The planar/interleaved setting controls the **canonical four-plane
oracle**, but **both timed packed-array kernels use the same
contiguous buffers regardless of layout**. These small
between-scenario time differences therefore **cannot** be attributed
to planar vs interleaved optimized memory accesses.

The 2048² *partial* ROI covers 4,120,884 pixels rather than
4,194,304; its full-path ratios are **2.504×**
(interleaved) and **2.511×** (planar). These offset ROIs cover
~98% of the image and do **not** simulate a 64² viewport update.

### Alpha distribution, 512²: median full-path ratio

All values: median of the four distinct (2 canonical layouts ×
2 ROI shapes) **case median-time ratios** for a given alpha
pattern and opacity.

| Input alpha pattern | Opacity 0 | Opacity 0.37 | Opacity 1 |
|---|---:|---:|---:|
| Mixed (0,1,128,254,255) | **2.652×** | **2.539×** | **2.540×** |
| Both opaque | **2.525×** | **2.542×** | **2.543×** |
| Both transparent with nonzero hidden RGB | **11.237×** | **11.143×** | **10.935×** |
| Top transparent, bottom alpha 128 | **2.528×** | **2.506×** | **2.531×** |
| Bottom transparent, top alpha 128 | **11.032×** | **2.540×** | **2.539×** |

**Interpretation of extreme transparent ratios:** When the
fully composed alpha is zero, color-d's
`unpremultiply` yields canonical transparent black and
avoids nonzero-alpha output sRGB encoding. With the LUT, the
remaining lookup/compositing arithmetic is short and the direct
path still computes unneeded sRGB transfer. When **top alpha
128 with output opacity 0**, the same fully transparent output
explains the bottom-transparent `~11×` condition.

Do not mix these transparent cases into an unqualified
"typical full image is 11× faster" claim; representative
mixed-alpha complete-color improvement is **~2.5×**.
No alpha-specific short circuit has yet been added to
either algorithm; this is an emergent property of unchanged
canonical compositing semantics and the runtime LUT.

### LUT initialization and first-use economics

Measured single table preparation via the **same public
color-d runtime transfer for all 256 bytes**:

- **15 µs median** across the 64 case processes;
  **11–68 µs observed range**.
- A rough algebraic amortization heuristic using each
  case's measured full-kernel per-pixel saving puts the
  break-even at a **median ~137 composited pixels**,
  with roughly **100–674 pixels** across all cases.
  For an ordinary mixed 512² full ROI at 0.37,
  the observed preparation was **14–17 µs** and
  saved approximately **102–103 ns/pixel**,
  suggesting ~**140–170 pixels**.
- This is **not a separately validated micro-ROI crossover**:
  full-width/large-ROI microbenchmarks may have different
  call overhead, thermal/clock behavior, cache residency,
  branch prediction, and setup amortization. Do not
  hardcode a threshold or claim the LUT must be per-image.
  A reusable prepared table could amortize its cost
  over many tiles/regions, subject to a correct owner
  and lifetime design.

A CTFE-generated pre-baked table is *not* established as
equivalent to the runtime-prepared table:
`color-d` v0.2.0 intentionally uses `llvm_pow` at
LDC runtime and a different CTFE code path. Exact
binary64 equivalence across DMD/LDC must be tested
**before** treating a compile-time table as a drop-in.

## Memory, host limits, and what was *not* measured

- Host CPU governor recorded **`powersave` on all
  12 logical CPUs**, without frequency/temperature trace.
  CPU scaling is not held constant.
- At start: `MemAvailable = 5,817,904 kB`,
  `SwapFree = 6,388 kB` of `4,194,300 kB`
  configured swap. This near-full swap does **not** by
  itself imply swap I/O during this run.
- All **64** `/usr/bin/time -v` process summaries show
  **zero major page faults and zero process swaps**.
- Total peak resident **process** footprint:
  - **43,392–43,788 KiB** at 512²
    (~42.4–42.8 MiB).
  - **643,168–643,540 KiB** at 2048²
    (~628.1–628.5 MiB).
- **Crucial:** these are process maxima for a
  *comparison harness* retaining **two full-source
  RGBA buffers, two output buffers, four
  large decoded working arrays and three
  independent four-plane raster leases** plus runtime.
  They are **not** the working set of a
  packed-only production compositor and
  do not isolate per-call native scratch.
  The LUT itself is only ~2 KiB.
- No thermal/affinity normalization,
  XPS independent second session, 4K/8K
  streaming source, AArch64, `perf` counters,
  LLVM vectorization/codegen investigation,
  or operation-only temporary-memory peak
  is supplied. This is a qualified **reference
  machine observation**, not a stable
  cross-environment threshold.
- Current experiment covers only **encoded
  straight 8-bit source RGB**. Linear
  premultiplied input validation and runtime
  output-storage failures from the general
  four-plane adapter remain separate contracts.
- The 256-value check proves numerical
  identity for **every `ubyte` channel** to
  the **color-d runtime implementation
  on each qualified compiler**, and the
  64 scene cases prove tested exact
  output equality. Neither proves all
  possible two-layer pairs/opacities, nor
  independently re-executes the separate
  **432-scene** external mathematical oracle.

## Research verdict and next controlled experiment

**Supported:** A **runtime exact**, 2 KiB byte-decode
table dramatically improves the source-decode stage
and increases *same-math complete packed-array
linear-light compositing throughput* roughly
**2.5× for mixed alpha** on this XPS, under
LDC 1.43.0 and released raster/color v0.2.0.
Observed alpha-zero corner cases may be
even faster, and the one-time table
preparation is small relative to the
tested full-frame workload.

**Not yet supported:** Adopting a
generic LUT in `color-d` or an
optimized production `imagery-d` API.

**Recommended next proof:**
1. Attach the runtime-prepared table to the
   existing **raster-d v0.2.0 public**
   physically overlap-checked `zipTransformInto`
   packed-`SRgba8` path and measure **LUT on/off
   under the exact same external execution
   and prewrite alias contract**, not
   just on packed arrays. Retain a
   byte-exact differential against the
   four-plane reference and all layout/
   ROI constraints.
2. Inspect the **actual LLVM codegen**
   and account for inverse sRGB encode
   cost, vectorization and output
   quantization; if necessary add
   dedicated short ROI cases (64²,
   128²) without full-memory benchmark
   inflation.
3. Evaluate LUT table construction policy:
   a prepared, immutable read-only
   table bound to a session, source
   type, or processing engine; do
   not assume a new per-frame allocation
   or unsafe global shared mutable cache.
4. Prove full runtime opacity,
   quantization/error propagation,
   alias, premultiplied input validation,
   ROI/lifetime and native working-set
   budget separately **before** API
   promotion or rehoming optimizations
   to `color-d`.

**Branch policy:** Keep
`research/m3-rgba-layer-compositing`
and stacked **Draft PR #73** open.
No `develop`, `research-integration`
or `main` merge, no production
admission, and no write to sibling
repositories on the basis of this
single native performance session.
