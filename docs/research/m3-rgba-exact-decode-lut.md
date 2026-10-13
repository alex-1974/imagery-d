# M3.2 — Exact runtime sRGB byte-decode LUT probe

**Research only; evidence-only.** 2026-10-13. Draft PR #73 (stacked
on Draft PR #69), Issue #72. This experiment does **not** extend the
public `imagery-d`, `raster-d`, or `color-d` APIs; it does not
make a production color-transfer decision.

Related evidence:
- [Independent XPS hotpath-stage qualification](m3-rgba-hotpath-xps-2026-10-13.md)
- [External Skia/Blend2D/pixman/libvips/FFmpeg mechanisms](m3-rgba-external-engine-hotpath-audit.md)
- [Four XPS compositing reference sessions](m3-rgba-xps-2026-10-13.md)

## Research hypothesis

The XPS `decode_2rgb` attribution on the released LDC 1.43
matrix was roughly **117–124 ns/pixel** for two encoded sRGB
pixels/six RGB components, versus around **5–6 ns/pixel** for
the isolated premultiplied `source_over` stage. This does **not**
prove an isolated `llvm.pow` cost. It motivates testing whether
a table over the **finite `ubyte` domain** can move transfer
computation into a one-time preparation stage.

Importantly, **`color-d v0.2.0` already uses `llvm_pow`**
for runtime sRGB transfer under LDC; simply changing Phobos
`pow` to an LDC intrinsic is not a new optimization here.

## Exact value construction

Probe: [`decode_lut/source/app.d`](../../experiments/m3_rgba_layer_compositing/decode_lut/source/app.d).

- Store `double[256]` inside a small `DecodeLut` (2048 payload
  bytes, excluding surrounding ordinary `Work` fixture arrays).
- For each byte value `b` in `0..255`, call the **public**
  `color.SRgba8(b,b,b,255).toAlphaSRgb!double().color.toLinear()`
  in the **runtime** initialization path, and store its red component.
  No locally duplicated transfer polynomial or approximate power
  formula is introduced. All three sRGB channels use the same
  scalar function.
- A table lookup returns `LinearSRgbd(table[r], table[g], table[b])`;
  alpha is the same normalized `double` ratio `a / 255.0`.
- Before timing, independently recalculate the 256 values through
  the *same public color-d interface* and require **exact
  binary64 numerical equality** for all three RGB components.
  All values are finite nonnegative and include canonical +0.
  This is an exhaustive **finite byte-domain identity check**,
  not a proof for arbitrary floating-point sRGB input.
- The runtime table must **not** be replaced blindly with a
  `__ctfe`-generated literal: `color-d` deliberately uses
  different backend code paths for CTFE/DMD vs LDC runtime
  `llvm_pow`. A CTFE table is a distinct candidate requiring
  its own exhaustive binary64/effective RGBA differential gate.

Thus the table is **runtime-prepared** and *its initial preparation
cost is part of the research economics*, even though it is
excluded from per-pixel hotloop timings. The standalone benchmark
records `lut_init_us` separately for this reason.

## Full composition equivalence

The comparison uses actual `color-d`:
`premultiply`, `sourceOver`, `unpremultiply`,
`toSRgb`, and checked `tryToSRgba8`. Both the
direct-color and lookup pipelines apply runtime opacity to
**premultiplied RGB and alpha**, in the same expression order.
Output is **straight encoded sRGB RGBA8**, including zero-alpha
canonical transparent black.

Every relevant ROI pixel is compared **byte for byte** between:
1. direct `color-d`-based composition over packed `SRgba8` arrays;
2. identical composition with the runtime 256-value
   decode table;
3. the unchanged research four-plane `tryCompositeRgbaSourceOver`
   with independent `RasterLease!ubyte` source/destination buffers,
   planar or interleaved.

These comparisons occur once before timing and **after every paired
timing round**. The caller-owned output uses independent allocation,
and the input bytes include **nonzero hidden RGB at alpha 0**.

The comprehensive CI matrix exercises:
- **all 256 possible channel bytes** on each compiler;
- alpha scenarios: mixed (0,1,128,254,255), both opaque,
  both transparent with hidden RGB, top-only transparent,
  bottom-only transparent;
- runtime opacities **0, 0.37, 1**;
- **planar/interleaved** four-plane canonical views;
- **full and offset partial ROI**.

That is **5 × 3 × 2 × 2 = 60 end-to-end scenarios per
compiler** with two rounds and exact per-pixel checks.
Compilers: **DMD 2.112.1**, **DMD 2.113.0**,
**LDC 1.42.0**, **LDC 1.43.0**, with tagged
`raster-d v0.2.0` and `color-d v0.2.0`. The
LDC 1.43 CI job additionally uses a debug build and
the pinned runner smoke. The earlier 432-scene independent
oracle remains a **separate** test; checking LUT against
the original adapter is a *differential*, not an
independent mathematical proof.

## Timing methodology (not general production throughput)

The executable reports an alternating A/B pair of **four
complete-ROI kernels** per round:

| Field | Work | Limitation |
|---|---|---|
| `direct_decode_us` | Decode two straight sRGB pixels, write two prepared `LinearAlpha` arrays | No image output or compositing |
| `lut_decode_us` | Same normalization, table lookup, prepared-array output | Runtime-prepared LUT |
| `direct_full_us` | Two decoded pixels + color-d source-over + encode/quantize, writing packed output | No raster alias/preflight operation |
| `lut_full_us` | Identical fused color pipeline except LUT decode | No raster alias/preflight operation |
| `lut_init_us` | One-time table creation through 256 `color-d` decodes | Separate from repeated-pixel kernel |
| `thread_gc_bytes` | GC accounting of all four timed kernels | Does not measure native scratch allocations |

All four timed kernels are checked for exactly zero
`GC.stats().allocatedInCurrentThread` increase. Output
is verified after every round. The raw CSV records
`runtime_lut_value_mismatches=0` and deterministic
canonical output checksums.

The packed-array work is *not* raster
`zipTransformInto` and lacks its alias/injectivity protection.
No production API may be derived from these results directly.
Timings on GitHub-hosted CI are **smoke/same-run diagnostics**,
not an XPS absolute baseline. Never equate fast byte-domain
encoded-sRGB alpha blending with this linear-light workload.

## Native XPS protocol

The runner
[`run_m3_rgba_lut_xps.sh`](../../tools/research/run_m3_rgba_lut_xps.sh)
requires **LDC 1.43.0**, archived sources
**raster-d v0.2.0** and **color-d v0.2.0**, and
writes only below ignored `imagery-d/data/m3-rgba-lut-xps/`.
Sibling repositories are **read-only**. The built release binary
is executed directly under `/usr/bin/time -v`,
recording process RSS/faults, host CPU/governor, free swap,
compiler, DUB, live checkout provenance, raw CSV and SHA-256.

For the real XPS workload: use 512×512 and 2048×2048,
5 mixed/alpha variants and 3 opacities at the smaller size,
plus representative mixed-alpha 2048² tests at
opacity 0.37, both layouts and both ROI shapes.
Warm verification and preparation are out of hotloop timing;
`lut_init_us` remains separately recorded.
Run with no concurrent heavy jobs if possible; log actual
frequency/thermal readings if the system provides them.

After a safe fast-forward of `imagery-d`'s current
research branch:

```bash
cd ~/Programmiersprachen/dlang/d-geospatial-workspace/libs/imagery-d
git status --short
git fetch origin
git merge --ff-only origin/research/m3-rgba-layer-compositing

export PATH="$HOME/dlang/ldc-1.43.0/bin:$PATH"
hash -r
ldc2 --version | sed -n '1,3p'

OUT="$PWD/data/m3-rgba-lut-xps/ldc143-$(date -u +%Y%m%dT%H%M%SZ)"
bash tools/research/run_m3_rgba_lut_xps.sh "$OUT"
tar --exclude='./snapshot' -czf "$HOME/Downloads/$(basename "$OUT").tar.gz" -C "$OUT" .
```

Do not force the branch update, discard untracked work or switch
sibling repository branches. Exclude generated source snapshots
from the evidence archive while preserving environment, raw
checksums, build logs and process resource logs.

## Interpretation and release gates

**Hypothesis to confirm:** normalized byte lookup removes repeated
transcendental transfer evaluations and materially improves
both standalone two-pixel decode **and** whole same-math
linear-light packed-array composition.

**A faster isolated decode does not guarantee a faster whole
compositor**; initialization, linear-light output encode, alias
validation, arbitrary layouts and amortization matter. Any
source-level compiler-specific ordering/precision difference
fails the *exact* hypothesis, not something to hide behind
a one-channel tolerance.

**Remaining before production:**
- apply a selected, full-domain color transfer strategy at
  the correct layering boundary (likely predecode/adapter vs
  `color-d`, decision **not yet taken**);
- prove prewrite alias and invalid-premultiplication handling,
  runtime opacity, ROI, and error propagation for general
  borrowed/writable views;
- qualify real tile/cache/viewport behavior, memory budgeting,
  and 2K/4K+ streaming cases on real hardware;
- if attempting compile-time constants, approximations or SIMD,
  independently qualify precise numerical behavior;
- use AArch64 evidence for architecture-changing optimizations.

No branch merges, new production symbol or sibling library
change are authorized by this experiment alone.
