# R-IM-03a — General-purpose Levels image operation, independent DUB consumer

**Date:** 2026-10-17. **Status:** Research prototype; exact-HEAD DMD/LDC and oracle results require CI confirmation.  
**Branch:** `research/r-im-03a-general-levels-consumer` from the existing `research-integration` at `f47c0ca521b89b526d6e943335bca57b773e08ef`.  
**Design clarification:** independent review [Draft PR #84](https://github.com/alex-1974/imagery-d/pull/84) on `develop` says general image operations **do not depend on satellite metadata**. No PR, merge or source modification of R-IM-02 research or grandfathered RGBA Draft #73 is made.

## Objective and primary references

Provide an independent, photo-editor-like **Levels** image operation for grayscale and multichannel samples. A screenshot, JPEG, rendered RGBA layer or scientific image buffer may all be input; **not one line of the algorithm requires** scene ID, wavelength, STAC, CRS, georegistration, physical calibration provenance or remote-source access.

- [GIMP 3 Levels documentation](https://docs.gimp.org/3.0/en/gimp-tool-levels.html) confirms independently controlled input-black, input-white, midtone/gamma, output-black/output-white and selected channel. GIMP also allows non-destructive preview and alpha-channel-specific adjustments, but this experiment does not implement its entire colour-management, adjustment-layer or GUI system.
- [GEGL levels operation](https://gegl.org/operations/gegl-levels.html) exposes input/output ranges as its own image point operation; it must not be assumed to include all GIMP UI channel/gamma features. 
- [OpenImageIO 3.2 ImageBufAlgo](https://openimageio.readthedocs.io/en/stable/imagebufalgo.html) exposes ROI and channel-aware operations and a `contrast_remap` that can **extrapolate** values outside its input range unless explicitly clamped.
- [libvips operators](https://www.libvips.org/API/current/function-list.html) demonstrate a large set of image operations and a separable gamma operation.

**Non-equivalence:** We deliberately choose a **clamping Levels** formula, not OIIO's default extrapolating contrast remap. No exact GIMP/GEGL binary equivalence or native benchmark is claimed. The UI terms are motivation; image math contracts must be specified independently.

## Research-only module and precise equation

`experiments/r_im_03a_levels/source/imagery/presentation/levels_research.d` is built as a separate DUB research library over **raster-d v0.2.0** (pinned source `2f2415851e45001df92ce56dad409f680684ba8d`).

Input sample types: `ubyte`, `ushort`, `float`. For 8/16-bit inputs, normalize stored integer values to the scalar interval `[0,1]` by division by 255 or 65535. For float, the supplied numeric value is used unchanged, including values outside `[0,1]` or nonfinite.

For each selected finite source channel value `v` and **explicit** parameters `b<w`, `gamma>0`, `0<=lo<=hi<=1`:

```text
t = clamp((v-b) / (w-b), 0, 1)
mapped = lo + pow(t, 1/gamma) * (hi-lo)
a = optional selection-mask byte / 255, or 1 if mask absent
output = v + a * (mapped-v)
```

Unselected channels are copied as normalized float without a tone transform. A selected input with mask byte 0 is also copied. A float input of NaN or positive/negative infinity is copied unchanged, even if selected. **There is no hidden NoData, gamma decoding, alpha interpretation, unit conversion or colour-space transform.**

Selection-mask byte is a **graded editing-selection strength**, not a validity mask. `0` means unchanged; `128` partially blends; `255` applies full adjustment. The user chooses affected channels. For a normal straight RGBA photo editing use case, only R/G/B are selected, and alpha passes through unchanged. **The kernel does not infer that channel 3 is alpha**, nor does it claim safe colour math on premultiplied encoded RGBA; the consumer must decide suitable colour encoding/association or supply already prepared scalar channels. For an alpha-channel Levels edit, future explicit semantics are a separate case.

The return is a **caller-owned float raster destination of ROI-local dimensions**, with plane count identical to source, retaining the same channel order. ROI is any checked source-local rectangle; there are no geospatial coordinates. Planar/interleaved, strides and ownership remain **raster-d** concerns.

Before writes, failures for empty source, out-of-bounds/empty ROI, selection-vector cardinality, nonfinite/degenerate parameters, invalid selection-mask geometry or wrong output shape leave the **previous whole output exactly unchanged**. Later source/read/write failure may leave a **partial** caller destination. Because physical nonalias is **not enforced** by the research API, it **must not** be admitted verbatim into a general public package, especially where output may overlap input or selection-mask buffers. The independent fixture uses disjoint raster-d leases. No total @safe/@nogc/nothrow or memory peak/RSS bound is asserted.

## Independent reference consumer and oracles

Research library: `experiments/r_im_03a_levels/dub.sdl`.  
Separate DUB executable: `experiments/r_im_03a_levels/smoke/dub.sdl`, `smoke/source/app.d`.

Real raster-d `RasterLease!T` owners are allocated, imported and initialized by the consumer; no own raster refcount/borrow hierarchy is introduced. Synthetic photo-like pixel values are deterministic:

```text
code(channel,x,y) = (31*x + 17*y + 13*channel) mod 256
ubyte: code
ushort: 257*code
float: float(code / 255), with one NaN and one infinity special case
selection(x,y) = {0,128,255} depending on (x+2y) mod 3
```

Cross-product: **3 sample types × 2 channels counts (1 gray, 4 RGBA) × 2 layout kinds × 2 selection mask states × 2 gamma modes = 48 configurations**.

Each configuration runs **1 full 8×6 result + 4 4×3 quadrants**: **240 complete result images** and **11,520 channel-value observations** (24 gray and 24 RGBA configurations × 96 pixels × respective channel count).

- Independent reference uses fixture mathematics, and `sqrt(t)` for gamma=2 rather than the kernel's `pow(t,1/gamma)`. Gamma=1 is checked against a simple linear remap. It checks every output sample with a stated floating tolerance (including NaN/Inf propagation).
- Every quadrant output must be **exactly equal, channel-for-channel**, to the full output at the corresponding source coordinate (NaN treated by both-value-is-NaN equality).
- Mask strengths include **0 (unchanged), 128 (partial) and 255 (full)**. In RGBA, channel 3 is unselected and explicitly verified against the independent source value, not an inferred alpha API.
- Negative preflight tests reject invalid ROI, collapsed input range, zero gamma, invalid output range, missing required mask, malformed output dimensions, plus wrong channel count for RGBA. Existing initialized output sentinels **must be unchanged in every channel/pixel**.
- All tests are synthetic and separate from any production photo editor. A smoke executable is not automatically a genuine non-test downstream consumer.

## Compiler qualification gate

Workflow `.github/workflows/r-im-03a-general-levels-consumer.yml` verifies **DMD 2.111.0, DMD 2.113.0, LDC 1.41.0, LDC 1.43.0**, independently building and running the DUB external consumer in **Debug and Release** on both push and PR. It requires the 48-case/240-image guarded PASS line. **No PASS claim until exact-HEAD actions finish.**

In this environment no `dmd`, `ldc2`, or `dub` is installed locally. CI output is the actual executable evidence rather than merely assuming that authored D code compiles.

## Next gates before any public operation

1. **Consumer demand:** identify a named, genuinely non-test photo/graphics application requirement rather than claiming adoption from a synthetic executable.
2. **Result-form and alias:** compare transactional owned results against caller destination, preserving old owner on failure and proving noalias/in-place rules with negative compile probes where meaningful.
3. **Colour semantics:** choose explicit working colour encoding before calling it a correct photographic colour adjustment. Alpha association and separate colour math are `color-d` boundary questions, not guesses based on R/G/B positions.
4. **Integer output:** optional `ubyte` and `ushort` result with explicit rounding/clamping/LUT policy; do not freeze a float-only public API from this first experiment.
5. **Performance:** compare streaming and full/region executions, LUT vs native pow, layout specialization, and pinned LDC optimized behavior against a semantically equal baseline on XPS. No speedup claimed.
6. **General image API:** inspect GIMP/GEGL, libvips, OIIO/Photoshop-like workflows for levels, curves, masks, layers and operation composition without creating a mandatory GUI or scheduler framework.

**Boundary:** This study remains under `experiments/`, `docs/research/` and a research-only workflow. No production `source/imagery`, root DUB package, Accepted ADR, sibling-repo edit or grandfathered PR rewriting. The independent generic-image direction of Draft PR #84 is preserved.
