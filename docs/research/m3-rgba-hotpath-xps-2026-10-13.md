# M3 RGBA stage attribution — XPS LDC 1.43 evidence (2026-10-13)

**Research evidence, not a production acceptance or general renderer performance claim.**
Source: user-provided `ldc143-20261013T135709Z.tar.gz`; compressed
archive SHA-256: `9ae3890e98d339b9d98782eaa70104b383e7c331cb64c76106c8e0cdda48657c`.
The uploaded archive contains the measurements and environment but **not**
the generated pinned source snapshots.

Supporting contracts:
- [stage experiment and measurement semantics](m3-rgba-hotpath-stage-attribution.md)
- [existing four-session source-over XPS reference](m3-rgba-xps-2026-10-13.md)
- [external Skia, Blend2D, pixman, libvips and FFmpeg hotpath audit](m3-rgba-external-engine-hotpath-audit.md)

## Evidence verification

- **Recorded UTC:** 2026-10-13T13:57:09+00:00.
- **Machine:** `xps-15`, Intel Core i7-9750H (6 cores / 12 threads),
  Ubuntu kernel `6.17.0-22-generic`, x86-64.
- **Imagery-d benchmark source HEAD:** `678cfa06a849817f2a3fe4ccc5759b0109c76f73`;
  branch `research/m3-rgba-layer-compositing`.
- **Compiled dependency sources** from isolated `--pinned` snapshots:
  `raster-d v0.2.0` peeled commit
  `2f2415851e45001df92ce56dad409f680684ba8d`;
  `color-d v0.2.0` peeled commit
  `3359f08f4e83941ac1a8451cadefb146b5736019`.
  The *live* raster-d checkout was at `1ea67cb6...` and held
  numerous untracked benchmarks; color-d also held an untracked
  `dunia/` directory. The runner only **read** the live repositories
  and operated on pinned snapshots in ignored imagery-d `data/`.
- **Tools:** LDC **1.43.0** (DMD frontend 2.113.0, LLVM 22.1.8),
  DUB **1.42.0**, release build. Executable invoked **directly**
  under `/usr/bin/time -v`; compiler and DUB startup are outside
  per-process measurement. Nonfatal `mir-core 1.7.4`
  `LLVM_version` deprecation warnings were present; no compilation errors.
- **Integrity:** all **24/24** raw CSV files match
  `CHECKSUMS.sha256` (**`STAGE_SUMMARY.csv` was generated
  *after* these raw checksums**, so is not in that manifest).
  **756** complete individual timed-stage rows (12 scenarios with
  5 rounds × 7 stages at 512²; 12 with 4 rounds × 7 stages at
  1024×768). Derived summary has **168** grouped stage medians
  (24 scenarios × 7). All 24 per-scenario `HOTPATH-STAGES PASS`
  markers present. All 24 stderr logs empty. Every recorded
  `thread_gc_bytes` value is **0**; this proves neither
  native-allocation absence nor an operation-only scratch budget.
- **Numerical checks:** each scenario compares **every ROI pixel
  byte-exactly** between the staged color path, fused packed-array
  color path and unchanged four-plane imagery research function.
  The program performs this check before measurement and after each
  round. Corresponding interleaved/planar canonical checksums are
  identical in all 12 cross-layout case groups; all round-level
  checksums within a case agree. This does not replace the distinct
  432-scene numerical oracle, its failure-path corpus or negative
  lifetime tests.

## Measured stages — median time per ROI pixel per invocation

Each number below is **the median of the per-case medians across the
8 cases** for the specified alpha pattern (2 image sizes × 2 raster
layouts × 2 ROIs). All cases use two complete hot-loop iterations
per measured round. This is a convenient *descriptive* summary, not
a pooled statistical confidence interval.

| Stage | Mixed alpha (0,128,255) | Both opaque | Both transparent, hidden RGB ≠ 0 |
|---|---:|---:|---:|
| `decode_2rgb` (two source pixels, six RGB channels) | **123.68 ns** | **117.33 ns** | **121.98 ns** |
| `unpremul_encode_quantize` | **68.20 ns** | **63.86 ns** | **8.99 ns** |
| `checked_io` (8 checked reads + 4 checked writes, byte-XOR control) | 15.76 ns | 14.36 ns | 15.08 ns |
| `premultiply_2` | 9.21 ns | 8.21 ns | 9.71 ns |
| `source_over` (includes scaling upper PM channels by fixed opacity 0.37) | **6.37 ns** | **5.39 ns** | **5.99 ns** |
| `packed_full` (fused **packed array** color pipeline) | **193.62 ns** | **183.93 ns** | **124.72 ns** |
| `fourplane_full` (unchanged checked 4-plane consumer) | **222.11 ns** | **211.36 ns** | **165.46 ns** |

**These stage timings are not additive.** In particular, the
`checked_io` XOR control is not source-over; isolated decode/encode
stages write separate prepared arrays, while the complete functions
may be optimized differently by LLVM, and the complete adapter has
more descriptor and input/output semantics.

**The pure Source-over arithmetic is relatively inexpensive compared
with the real `color-d` sRGB transforms on this fixture.** But the
`decode_2rgb` stage is not `llvm.pow` alone: it includes byte
normalization, branch tests, normalization output stores, and
six component transfers. The encode stage also includes
unpremultiplication and checked half-up RGBA8 quantization.
Do **not** claim that a particular percentage of the complete kernel
is attributable to the `pow` instruction from these timings.

### Interpreting transparency

The input fixtures deliberately preserve **nonzero invisible RGB** at
alpha=0. The decode stage processes both encoded RGB values and takes
approximately **122 ns/pixel** on fully transparent input; the output
unpremultiply+encode+quantize stage falls to roughly **9 ns/pixel**
because the linear-premultiplied result has zero alpha and
`color-d` returns canonical transparent black.

This suggests testing an **exact short-circuit** for fully transparent
source/destination configurations and/or avoiding per-pixel RGB
decode when its eventual associated contribution is provably zero.
No optimized behavior has yet been implemented or accepted.
An opaque or transparent *source* does not, by itself, justify
silently copying encoded background bytes without checking
decode→encode rounding, opacity, visible destination alpha and
quantization semantics.

### Packed-array vs checked four-plane full color path

The paired ratio of **case-median** `fourplane_full/packed_full`
ranges by alpha pattern:

| Pattern | Median across eight cases | Range across eight cases |
|---|---:|---:|
| Mixed | **1.145×** | 1.124–1.228× |
| Both opaque | **1.155×** | 1.094–1.190× |
| Both transparent | **1.304×** | 1.261–1.354× |

**Important:** `packed_full` in this attribution benchmark operates
directly on prepared **arrays of `SRgba8`** with neither a raster
`zipTransformInto` call nor its full physical-overlap checks.
Therefore these ratios cannot be interpreted as the same
`zipTransformInto` vs four-plane test that yielded ~**1.25×**
in the preceding qualified 2048² XPS benchmark. Fixture and
measurement organization differ. The new fused packed-array
implementation is **not** a production alias-safe fast path.

### Image sizes, ROI and layout

The scenarios are 512×512 or 1024×768, in planar and
interleaved four-plane layouts, each with entire or `Region2D(5,7,
width-10,height-14)` partial ROI. For example, the 512² partial ROI
is **249,996 pixels** versus 262,144 whole-image; the partial
1024×768 ROI is **764,556 pixels** versus 786,432. These
partial-ROI tests verify offset and ROI consistency, but **do not yet
measure small (e.g. 64²) interactive viewport updates**. Most
full four-plane planar/interleaved differences are modest and can
change sign between sizes/patterns; do not attribute color costs to
memory layout without paired controlled profiling.

## Process memory, host state and caveats

- Recorded CPU governor was **`powersave` on all 12 logical CPUs**.
  No CPU-frequency trace, temperature trace, or cache/perf
  counters were collected.
- `MemAvailable` at startup: **5,452,156 kB**;
  `SwapFree`: **2,040 kB** out of 4,194,300 kB.
  Near-full swap is *not* evidence of active swapping.
- **All 24 measured processes report zero major page faults and zero
  process swaps** in `time -v`.
- Max RSS of each 512² process: **51,676–51,988 KiB** (~50.5–50.8 MiB);
  max RSS of each 1024×768 process: **147,988–148,308 KiB**
  (~144.5–144.8 MiB). These are **entire benchmarking process**
  footprints including *all preallocated color-stage arrays, three
  raster leases, fixtures, runtime*, not isolated compositor memory
  nor a recommended cache budget.
- No NUMA, pinning, isolated clocks, native peak temporary
  allocation, codegen/perf counter profile, AArch64 comparison
  or real-world tile mosaic workload was included.

## Research decision (data-driven priority)

1. **P1: sRGB transform investigation first.** Benchmark a byte-exact
   **256-entry decode LUT** against the existing `color-d v0.2.0`
   `toLinear`, isolate the actual sRGB power transfer (without
   conflating it with view access or output), and check every byte
   value across both DMD and LDC 1.42/1.43. A candidate LUT must
   preserve canonical output byte rounding and transparent-alpha
   corner cases in the existing independent numerical corpus
   (432 scenes), or be labeled *approximate*, never silently promoted.
2. **P1: transparent case short-circuit probe.** Test mixed,
   zero-alpha hidden-RGB, upper-only transparent, lower-only
   transparent, and opacity 0/1. Require the *same* color-d
   output bytes/error classifications across layouts and ROIs,
   prewrite invalid-input rejection and alias requirements.
3. **P2: prepared/packed row execution.** The four-plane checked
   raster view access is a meaningful cost, but **is not dominant
   in this controlled access-only diagnostic**. Measure
   span/prevalidated row access via existing public `raster-d`
   surfaces first; do not duplicate its package-private
   address/alias validation or weaken fail-before-write.
4. **P2/P3: region reuse and SIMD only after codegen inspection.**
   A cached linear-premultiplied working set can be large; explicit
   lifetime, output representation, memory budgeting, and first-use
   amortization are mandatory.

**Disposition:** establish this XPS run as a **qualified research
hotpath-attribution reference** (correct source/compiler matrix,
checksummed raw data, complete multi-case stage comparisons), not
a production or absolute long-term clock-controlled performance gate.
Maintain stacked **OPEN/DRAFT PR #73** and independent Issue #72.
No changes to other repositories or public APIs.
