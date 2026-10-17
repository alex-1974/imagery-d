# M3 RGBA hot-path research — source audit of fast image engines

**Date:** 2026-10-13. **Status:** RESEARCH ONLY / EVIDENCE-ONLY.
**Repository:** `imagery-d`, Issue #72, Draft PR #73 stacked on Draft PR #69.
**Boundary:** No changes to `raster-d`, `color-d`, their public APIs or any
other sibling. This report is **not** a production admission or an implementation
recipe to copy an engine.

## Question and established local baseline

Which *actual source-level techniques* used by established graphics/image
engines might improve `imagery-d`'s **correct linear-light, straight-alpha
encoded sRGB RGBA8 source-over** without silently weakening color, alias,
lifetime, error or region semantics?

Locally qualified reference: XPS i7-9750H, `raster-d v0.2.0`,
`color-d v0.2.0`, LDC 1.43.0 / LLVM 22, packed POD `SRgba8` via
`raster.zipTransformInto` at compile-time opacity 0.37: **1.249x** throughput
against the four-plane checked-access reference at 512², **1.251x** at 2048²;
12/12 output comparisons byte-equal. See
[m3-rgba-xps-2026-10-13.md](m3-rgba-xps-2026-10-13.md). Those timings do
**not** benchmark any of the third-party engines.

The reference compositor is:
`experiments/m3_rgba_layer_compositing/source/imagery/presentation/composite.d`.
It uses 8 per-channel `trySample` calls + 4 `trySetSample` calls per
pixel, converts RGB to linear with `color-d`, premultiplies, scales upper
associated light and alpha by runtime opacity, performs `sourceOver`,
unpremultiplies, re-encodes sRGB, and quantizes to straight RGBA8. Its
preflight validates all linear-premultiplied input sample bytes in the ROI
**before any write**. Generic four-plane input/output noalias is only a
caller precondition, not runtime-proven.

### Semantic comparison gate (CRITICAL)

A result from a fast library is comparable **only if** all of these are
identified first:

- **color space for the blend:** encoded sRGB vs **linear-light** sRGB;
- input/output alpha: straight vs premultiplied;
- output: **straight encoded RGBA8**, transparent-black canonicalization,
  8-bit half-up quantization and any extended-value failure;
- input/output layouts: packed RGBA vs four physical single-channel planes,
  ROI, noncontiguous/negative strides and aliasing;
- GPU vs CPU, one thread vs many, conversions/allocations/preparation
  included vs excluded.

A premultiplied 8-bit source-over kernel that **blends gamma-encoded bytes**
is not mathematically equivalent to the present `color-d` source-over.
Do not cite its MPix/s as evidence of equivalent performance.

## Third-party **source-level** audit

### 1. pixman — table-selected formats, packed pixels, SIMD and alpha shortcuts

- Generic CPU fast path [`pixman-fast-path.c`, lines near
  `fast_composite_over_8888_8888`](https://github.com/servo/pixman/blob/master/pixman/pixman-fast-path.c#L593-L627):
  processes `uint32_t` RGBA-like pixels per row; wholly opaque source
  replaces destination directly; zero packed source leaves output alone;
  otherwise calls packed `over`. Important: packed premultiplied pixel
  representation/rounding is NOT our straight encoded output contract.
- The table of
  [`PIXMAN_STD_FAST_PATH` configurations](https://github.com/servo/pixman/blob/master/pixman/pixman-fast-path.c#L1815-L1865)
  matches operations and pixel formats to specialized functions *before*
  traversing pixels.
- [`pixman-sse2.c`, `core_combine_over_u_sse2_no_mask`](https://github.com/servo/pixman/blob/master/pixman/pixman-sse2.c#L657-L736):
  aligns destination, uses four 32-bit pixels per 128-bit SSE2 step,
  skips all-transparent vectors, copies all-opaque vectors, else unpacks,
  computes vector over, packs and stores. Source/destination alignment,
  scalar tails and CPU specialization are explicit. ARM NEON also has
  specialized operator/format tables.

**Transferable:** an explicit special-case map for *validated, common* RGB
layouts, a prepared row loop, and correctness-qualified vector variants.
**Not transferable by substitution:** byte-domain premultiplied blending,
in-place destination mutation, zero-alpha hidden-color preservation, or
implicitly weakening output quantization / alias semantics.

### 2. Skia — vectorized stages and precision-aware color transfer

- [`SkRasterPipeline` source/toolkit overview](https://skia.googlesource.com/skia.git/+/refs/heads/main/tools/raster_pipeline/):
  stage programs compiled for CPU features (`sse2`, modern x86, `neon`,
  scalar); different **highp float** and faster **lowp fixed-point** routes.
- [`SkRasterPipeline_opts.h` code](https://skia.googlesource.com/skia/+/34c67453a5d032b2f5416564a8c80aa5dca05c9f/src/opts/SkRasterPipeline_opts.h):
  stages for load/store, `premul`, `unpremul`, source-over and color
  conversion. Its `from_srgb` uses a polynomial on the nonlinear branch
  instead of general `pow`; `to_srgb` uses reciprocal-sqrt/rational
  approximations and CPU-specific constants. This is **approximate transfer,
  not proof of equivalence** to `color-d`'s exact sRGB transfer.
- [`SkColorSpaceXformSteps.cpp`](https://android.googlesource.com/platform/external/skia/+/31dc48138c/src/core/SkColorSpaceXformSteps.cpp)
  builds color-transform stages based on flags for linearize, encode,
  gamut, unpremultiply and premultiply. Stages that are not needed can
  be omitted when inputs are already correctly tagged/prepared.
- Some lowp stage sets do **not** implement `from_srgb` or `to_srgb`;
  Skia can fall back to highp. Do **not** conflate lowp speed with the
  full linear-light color-conversion path.

**Transferable:** preselect stages once; fuse passes when numerically safe;
investigate SIMD-friendly approximate sRGB **only** in a separate
accuracy-gated experiment. Avoid assuming every Skia result is bit-identical
or always using a lowp pipeline.

### 3. Blend2D — CPU-specific pipeline generation with register-budget limits

- [`CompOpPart::prepare_part` and composition setup](https://github.com/blend2d/blend2d/blob/master/blend2d/pipeline/jit/compoppart.cpp#L25-L160):
  generates specific composition paths for operation and source/destination
  properties. E.g., RGBA32 `SrcOver` admits larger vector widths/pixel
  batches than costly operators; when source/destination fetch is expensive,
  it limits simultaneous pixels to avoid bloated pipelines.
- [Blend2D architecture](https://blend2d.com/) uses AsmJit and runtime CPU
  specialization; [implementation change history](https://blend2d.com/about.html)
  describes table-driven pipeline selection and portable-versus-JIT pixel
  equality testing across x86/AArch64. It is a **renderer**, not a drop-in
  two-image, float-linear-light compositing reference.

**Transferable:** separate **operation preparation** from the pixel loop;
choose packed/planar and encoding/alpha variant once per ROI; verify on
all available compilers/CPU families; do not start by implementing a JIT.
D templates + a small prepared runtime dispatch may test this hypothesis
at far lower maintenance cost.

### 4. libvips — reduce work and memory pressure at pipeline level

- [Why libvips is quick](https://github.com/libvips/libvips/wiki/Why-is-libvips-quick):
  demand-driven rectangular regions, work partitioned/streamed by an
  image I/O pipeline, overlapped input/output, low locking, avoiding full
  image residency. Some operations (notably convolution) perform
  run-time kernel generation; this is **not** proof all compositing is JIT.
- Actual [`composite.cpp`](https://github.com/libvips/libvips/blob/master/libvips/conversion/composite.cpp#L570-L625)
  shows the familiar premultiplied `OVER` algebra in a generic typed
  pixel loop. This is useful as an actual **math** implementation,
  not evidence that libvips scalar composite outperforms us.
- [`vips_composite` API](https://www.libvips.org/API/current/type_func.Image.composite.html):
  the default composite space can be **sRGB (encoded)**; consumers can
  explicitly select another, such as `scRGB` (linear, sRGB primaries).
  It supports premultiplied input as a flag. Its output is typically
  **floating-point with alpha**, not necessarily our quantized
  straight `SRgba8` output. [libvips color semantics](https://github.com/libvips/libvips/blob/master/doc/libvips-colour.md)
  identify `scRGB` as the linear space.

**Transferable:** region-first processing and retained prepared image regions,
rather than entire-image copies or a new scheduler. Beware: any libvips
composition comparison must request the same **linear-light compositing
space** and explicitly quantize with our policy.

### 5. FFmpeg overlay — efficient packed scans and alpha-form variants

- Actual [`vf_overlay.c`](https://github.com/FFmpeg/FFmpeg/blob/master/libavfilter/vf_overlay.c)
  implements packed RGB processing using pointer strides, slices per worker,
  special branches for `alpha=0` and `alpha=255`, a fixed-point
  `FAST_DIV255`, and distinct straight/premultiplied alpha variants.
  It also provides planar RGB/YUV loops and a final x86-specific dispatch.
- The quoted byte formula is a **pixel-byte-domain** blend. It does not
  establish equivalent gamma-aware linear-light transfer, alpha
  canonicalization or our exact half-up quantization.

**Transferable:** select formats/alpha modes outside loops; test slice/row
partition and genuine constant-alpha workloads. Do not adopt the integer
formula into `color-d` just because it executes quickly.

### Supplemental: Cairo's representation contract

[Cairo ARGB32 image surfaces](https://cairographics.org/manual/cairo-Image-Surfaces.html)
explicitly use **premultiplied 8-bit ARGB**. This is valuable as a reminder:
quick direct `OVER` on a premultiplied 32-bit surface is not the same
problem as decoded **straight** sRGB input requiring linearization and
return-to-straight RGBA8.

## Local code findings: what we can realistically improve

These observations are based on **released local source**, not a profiler:

1. [`color-d v0.2.0 rgb.d`](https://github.com/alex-1974/color-d/blob/v0.2.0/source/color/rgb.d)
   already routes runtime `srgbDecodePow24` and
   `srgbEncodePowInv24` to **`ldc.intrinsics.llvm_pow`** with a
   separate CTFE / DMD `std.math.pow` path. Therefore the obvious
   `pow → llvm_pow` suggestion is **already implemented**, not new.
2. Up to **six RGB decode components** (three per source) and **three
   RGB encode components** run through piecewise sRGB transfer per
   output pixel. Not all enter the nonlinear-power branch, so "**nine
   `pow` calls per pixel**" is *not* a measured fact. Hypothesis: the
   transfer and unpremultiplication workload is significant.
3. [`raster-d v0.2.0 view.d`](https://github.com/alex-1974/raster-d/blob/v0.2.0/source/raster/view.d)
   explicitly documents `trySample` as a **correctness/control-plane
   accessor**, not its optimized execution adapter. Our four-plane
   reference makes 8 checked reads and 4 checked writes/pixel.
4. [Our source](../../experiments/m3_rgba_layer_compositing/source/imagery/presentation/composite.d)
   makes an additional **full pixel preflight pass for each
   linear-premultiplied source** to enforce noncanonical-byte rejection
   before output mutation. Fusing this naively would violate the
   documented fail-before-write contract.
5. [Our packed probe](../../experiments/m3_rgba_layer_compositing/packed_probe/source/app.d)
   already uses raster's compiled `zipTransformInto` engine and
   physical alias checking but only at compile-time opacity 0.37, on
   packed `SRgba8`, with **incomplete checked quantization error
   propagation**. It is an **evidence-only restricted mechanism**,
   not an accepted optimized general endpoint.

## Proposed experiments in order (hypotheses, not decisions)

| Priority | Research probe (imagery-d only) | What to measure | Correctness / memory gate |
|---|---|---|---|
| **P0** | **Hot-path attribution**: isolated checked-RGBA load/store, byte→linear decoding, linear premultiply/OVER, unpremultiply, linear→encoded/quantize, and full fused path. | ns/pixel, cycles/pixel, branch/caches, LLVM assembly, `perf stat` if available; DMD correctness, LDC release. | Each stage's setup outside timed kernel; no claim that XOR relay isolates gamma; independent oracle unchanged. |
| **P1** | **Exact 256-entry sRGB decode LUT** as a *separate research variant* for 8-bit source; compare indexed `double` table to v0.2.0 `toLinear`. | Isolated decode speed, overall source-over, instruction counts, cache misses. | All 256 source byte values, alpha/opacity/ROI matrix, output bytes **exact or explicitly declared tolerance**; CTFE vs runtime `pow` differences checked; no table promoted to color-d. |
| **P1** | **Prepared packed/planar row-kernel selection** reusing public raster mechanisms, reducing per-pixel bounds/layout decisions. | Hot calls, data layout, repeated ROI, 512²/2048², strided+negative layouts. | **Physical alias**, injective output and no-mutation preflight must remain; do NOT reach into `raster.internal` or assert noalias without proof. |
| **P2** | **Cache correctly tagged linear-premultiplied decoded regions** (input stage, with bounded residency), compositing multiple opacities to straight sRGB output. | First-use conversion cost, repeated-frame throughput, peak decoded/cache/output bytes. | Same visible pixels and rounding contract; invalid PM validation; memory budget + transparent black; no full-image cache requirement. |
| **P2** | Optional **sRGB approximation** and `float`/SIMD variants as *numerically distinct* experiments, inspired by Skia. | MPix/s versus worst-channel byte error, delta-E if meaningful, threshold, codegen. | Must state reference difference, especially half-up ties; never silently mark approx as exact `color-d` semantics. |
| **P3** | Region/viewport batching, repeated composed-region reuse, and threading on independent **proven non-overlapping** output regions. | latency to first visible region, total CPU, peak resident sets, scaling with threads. | M2 cancellation/retained ownership, no data races; small ROI must avoid whole-frame work. |
| **Later** | Production-size C++/Skia/libvips comparison and x86/AArch64 codegen. | only **equivalent** color/output/ROI semantics plus setup/teardown. | Reject unfair alpha/gamma/precision comparisons; architecture-changing selection needs non-x86 evidence. |

### Why this order?

- **First separate arithmetic from checked access.** The earlier `relay`
  benchmark is *not* semantically equivalent, so its performance
  differential cannot be assigned to one bottleneck.
- **Keep `color-d` and `raster-d` canonical.** A fast domain-specific
  renderer is not a reason to copy color transfer or validated address
  arithmetic into `imagery-d`.
- **Do not precompute arbitrary results by changing the model**:
  cached linear-premultiplied pixels require explicit ownership/budget
  and must not silently replace current borrowed source semantics.
- **A timing win is insufficient.** Exact byte equality is the existing
  research oracle for current fixtures; all general API, failure, ROI and
  lifetime promises must be independently preserved.

### Required reproducible next evidence

Create a **new independently compiled benchmark research consumer on the
existing stacked branch**, not production `source/`:
- pinned raster-d/color-d v0.2.0, supported LDC 1.43 and DMD correctness;
- timed **stage attribution** with meaningful component-equivalent
  calls (not reinterpretation of byte XOR as color computation);
- at least 3 alpha distributions: all-opaque, all-transparent,
  realistic mixed; plus hidden nonzero RGB at alpha=0;
- 2 layouts, 512² + 2048² and a *partial* viewport ROI;
- alternating A/B rounds, warmup, raw per-round CSV, compiler flags,
  checksum, thread-local GC bytes, process RSS and CPU/thermal provenance;
- compiler assembly/auto-vectorization inspection before explicit SIMD;
- compare with the **existing independent 432-scene oracle** and
  negative lifetime/alias/preflight tests.

**Decision at this point:** the strongest research hypotheses are
(1) expensive sRGB conversion and (2) repeated generic checked sample
access. Neither is yet isolated by instrumentation. Retain Draft PR #73
and Issue #72; do not merge, refactor other libraries or claim a
production result.
