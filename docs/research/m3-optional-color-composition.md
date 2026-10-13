# M3 optional colour-aware RGBA layer composition — research evidence

**Date:** 2026-10-13.  
**Tracking:** [Issue #70](https://github.com/alex-1974/imagery-d/issues/70);
[stacked Draft PR #71](https://github.com/alex-1974/imagery-d/pull/71)
above [decoded RGBA tile PR #69](https://github.com/alex-1974/imagery-d/pull/69).
**Status:** source-level and ordinary separate-DUB consumer correctness
research; **not** a public production `imagery-d` API, M3 admission ADR,
external editor adoption, compositor release or full-lifecycle XPS benchmark.

## 1. Reference-model discovery and responsible library

The released [`color-d v0.2.0`](https://github.com/alex-1974/color-d/tree/v0.2.0)
already provides the precise value-level mathematics:

- `color.rgb.SRgbd.toLinear`: explicitly decode encoded-sRGB to
  linear-light RGB, without implicit clipping.
- `color.alpha.Alpha!LinearSRgbd` and
  `color.alpha.premultiply`: explicitly derive premultiplied
  linear-light colour from straight linear-light colour.
- `color.alpha.Premultiplied!LinearSRgbd`: already-premultiplied
  **linear** RGB plus alpha.
- `color.composite.sourceOver`: premultiplied linear-light
  Porter–Duff **foreground over background**. It is not
  commutative. It does not decode, encode, or clip inputs.

These are inspected **public v0.2.0 provider functions**, not
assumed or newly duplicated formulae. The research operator
delegates pixel colour calculation to them. `imagery-d` handles
**raster ROI, four-component interpretation, colour/alpha source
declarations, preflight, output and lifetime**, leaving value-level
mathematics in `color-d`.

**DUB dependency isolation matters:** the optional research library
`experiments/m3_rgba_color_composite/dub.sdl` depends on the
existing M3 research module library and released `color-d`.
It does **not** add `color-d` to the existing baseline
`experiments/m3_module_import_surface/dub.sdl`, nor introduce a
production root manifest or `source/imagery/**`. Consequently
`import imagery;`/`imagery.core` and the previous
`imagery.presentation.tiles` research family do **not**
silently acquire `color-d` or `imageio-d` as required
dependencies. No `color-d` or `raster-d` repository has
been modified.

## 2. Explicit input/output and non-goals

`imagery.presentation.composite.tryCompositeSourceOver`
(only in the optional research package) accepts:

- **foreground** `RgbaCompositeLayer`: retained borrowed
  four-plane `RasterView!double`, `RgbaCompositeSpace`,
  `RgbaAlphaAssociation`;
- **background** layer in the same **resident 2-D grid**,
  with independently declared colour/alpha semantics;
- one explicit ROI within that common grid;
- a caller-owned four-plane `WritableRasterView!double`
  matching the ROI exactly.

Input cases admitted:

| Declared value space | Declared alpha | Handling |
|---|---|---|
| **encoded sRGB** (normalized computational values) | straight | explicit `color-d` decode to linear, then `premultiply` |
| **linear sRGB** | straight | explicit `premultiply` |
| **linear sRGB** | premultiplied | use already premultiplied linear coordinates |
| encoded sRGB | premultiplied | **REJECT** (no unsafe relabelling of nonlinear premultiplication) |
| unknown/unspecified space or association | any | **REJECT** |

**Output is always four-channel premultiplied linear-light RGB
with alpha**. It is **not** encoded sRGB bytes and **not**
`color.storage.SRgba8`, whose documented meaning is
*encoded straight-alpha* bytes. No implicit `toSRgb`,
byte quantization, clipping, gamut-map or renderer packing
occurs. Extended linear RGB values, including negative or
above-one values, are allowed; alpha is separately required
to be finite in **[0,1]**. At exactly zero premultiplied
alpha, nonzero associated RGB is rejected rather than
silently repaired. For nonzero alpha extended RGB is
intentionally not restricted to [0, alpha].

**The destination's colour-space/association information is
only a function contract, not yet a distinct compile-time
result type**. A production interface needs a more robust
typed result/owner with full semantic provenance.

No source overlap/in-place read/write guarantee is made.
The caller must retain both source `RasterLease` owners and
the target storage for the call. Preflight errors do not write
to target; an unexpected read/write failure after preflight
may partially write. The operation is `@safe nothrow @nogc`,
but zero allocation does not guarantee zero GC pauses.

Not in this experimental scope: HTTP/tile source acquisition,
`imageio-d` decoding, cache/versioning, reprojected map
layers, layer opacity UI, blend modes other than source-over,
gamma-space compositing, backend GUI/GPU integration, output
storage encoding, asynchronous cancellation, lifetime
ownership beyond a scoped call, or tile/pixel filtering.

## 3. Complete independently checked two-layer pixel oracle

A **separate DUB consumer**
`experiments/m3_rgba_color_composite/smoke` imports
`imagery.presentation.composite` and existing raster
ownership, **not** the internal implementation modules of
`color-d` or older M3 tests.

The deterministic fixture creates independent
**8×6, four-plane double** images for top and bottom
on each processing call. The background layout is deliberately
the opposite of the foreground. Output layout varies
independently. The logical image has mock seams at x=4,
y=3; **these input layers are already resident complete
images, not six individually supplied decoded tiles**.
The previous M3 tile consumer verifies actual tile assembly
in its own [separate report](m3-decoded-rgba-tiles-consumer.md).

Two foreground layouts × two destination layouts × eight
different source space/association combinations × three
ROIs (**8×6**, seam-crossing **4×4**, **5×5**) =
**96 actual complete RGBA output images**.

The independent external-to-provider oracle **does not
import or call `color-d` mathematics**. It reconstructs
stored input colours/alpha from global fixture formulae,
decodes encoded sRGB with the nominal piecewise sRGB
transfer using `std.math.pow`, then directly evaluates
the analytical Porter–Duff equations:

```text
Aout = Af + Ab × (1 − Af)
Cout_premult_linear = Cf_linear × Af
                    + Cb_linear × Ab × (1 − Af)
```

This is allowed **in the test oracle only**, not copied into
the research adapter implementation. Explicit noncommutative
foreground/background order is checked at a pixel where
both alphas are 0.5.

The 32 combinations of 2×2×8 treatment/layout cases
each check all 48+16+25 = 89 output positions:
**2,848 independent output pixel positions and 11,392
individual double RGBA component checks**, each with
absolute tolerance **2×10⁻¹¹** to accommodate
independent double `pow`/transfer evaluation. This is
not an `imageio` encoded-byte numerical oracle.

Both inputs contain deliberately distinct colour values,
transparent/50%-transparent/opaque alpha and extended
linear RGB, including values below 0 and above 1.
Straight-alpha transparent hidden RGB is preserved in the
input; the premultiplied output uses the mathematical
zero-alpha representation. No incorrect
`straight → already-premultiplied` shortcut can satisfy
the full independent result oracle.

## 4. Fail-closed cases and lifetime gates

All recoverable preflight failures are checked with
sentinel output buffers that must remain unchanged:

- missing/invalid four-plane source RasterView;
- unknown/unspecified colour space or alpha association;
- encoded premultiplied sources;
- off-grid ROI;
- wrong number of output planes or ROI extent;
- invalid alpha >1 or outside [0,1];
- noncanonical zero-alpha premultiplied RGB in the **foreground
  and background**, including a hidden nonzero channel.

The source alpha preflight examines every requested pixel
on both layers and rejects `NaN`/non-finite alpha via
the [0,1] comparison. **It does not impose a unit gamut
or finite-RGB policy** on extended linear values beyond
zero-alpha premultiplied canonicality. Runtime
sample-read/write failure after preflight is not
synthetically forced with unsafe pointers.

The separate DUB consumer config
`negative-local-composite-layer-escape` must fail to
compile an `@safe` function that returns a composite
layer borrowing a local `RasterLease!double` raster,
under `-preview=dip1000`. The workflow checks the
error references the dedicated consumer probe source
and includes a scope/escape/return/lifetime diagnostic;
an unrelated compilation failure does not qualify.

Each positive mapped call records **zero new GC bytes
allocated in the calling thread**. Fixture construction
(`malloc`, planes and DUB setup) is outside the
mapping section, and full process memory/latency/GC
collector pause behavior is **not measured**.

## 5. Compiler qualification and limits

`color-d` released `v0.2.0` publicly supports
**DMD 2.112.1, DMD 2.113.0, LDC 1.42.0 and
LDC 1.43.0**. CI for **this optional integration**
follows **that** floor, pins both
`color-d v0.2.0` and `raster-d v0.2.0`,
and exercises debug, release, preflight/ordinary
DUB consumer and compiler-negative lifetime tests.

The base `imagery-d` research matrix retains its
separate historical DMD 2.111 / LDC 1.41 compatibility
without asserting that the optional `color-d` adapter
runs on unsupported `color-d` versions.

**Qualifying code commit:** `68bb30c75b61065024d1782527c21e62dd1203f4`.  
**Source-code CI:** [GitHub Actions #38371705876](https://github.com/alex-1974/imagery-d/actions/runs/38371705876)
**4/4 SUCCESS**, all debug/release independent DUB consumer
runs, first four supported compiler floors and owner-escape
negative builds. The first documentation-only HEAD was
separately requalified at [Actions #38371950059](https://github.com/alex-1974/imagery-d/actions/runs/38371950059)
**4/4 SUCCESS**. Hosted tests establish correctness/scope
and real provider-based pixel mathematics, not XPS
performance or image editor frame timing.

## 6. Research disposition

**ADAPT** `color-d`'s existing public premultiplied
linear-light compositing in a *separate optional imagery
ROI operator*. **DO NOT** create a second colour
mathematics layer or make `color-d` mandatory for
the baseline image-semantic core.

**DEFER** public `imagery.presentation.composite`
and its provisional RgbaCompositeLayer/output contract
until an actual downstream editor/CLI consumer demands
it, and until explicit colour type/alpha/result
contracts, full-lifecycle retained memory, optimized
consumer workload, and an accepted/rejected M3 ADR
are present. Keep parent M3 Issue #24 **open**.
The selected first M3 candidate remains the checked
three-component display mapping; this result extends
consumer evidence but does not silently replace the
chosen production gate.

This research PR stays **OPEN/DRAFT**, stacked
on #69; no `develop` or `research-integration`
merge and no writes to other workspace repositories.
