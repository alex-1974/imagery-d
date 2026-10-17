# M3 RGBA — scoped, caller-owned prepared sRGB8 context with runtime opacity

**Date:** 2026-10-13. **Issue:** #72. **Stacked Draft PR:** #73 on #69.
**Admission:** **RESEARCH ONLY**, **NOT** a production compositor or a
replacement for `raster.zipTransformInto`.
**Write scope:** only `imagery-d`. `color-d` and `raster-d` were
examined read-only at their already released **v0.2.0** contracts.

## 1. Research question and selected bounded step

Prior independently qualified XPS evidence shows an exact runtime
256-entry sRGB8 decode LUT yields ~2.5× throughput for mixed-alpha
RGBA8 source-over, both in packed arrays and inside the existing
public `raster.zipTransformInto` with physical alias preflight,
including 16²–128² offset ROIs. See
[micro-ROI XPS report](m3-rgba-lut-zip-micro-xps-2026-10-13.md).

But that **fixed-opacity 0.37** raster callback must be a compile-time
alias `@safe pure nothrow @nogc T(T,T)` and returns **only T**, with
no runtime parameter or pixel-error result. Treating a failed
`tryToSRgba8` as `SRgba8.init` is **not** a valid production
error contract. A mutable module-global current-opacity would violate
the functional/concurrency invariant. No changes to raster-d are
authorized.

This experiment asks a **separate** question: can a
caller-owned `scope`-used prepared image-domain context carry a
runtime opacity and exact channel table while preserving the
original **four-plane imagery research adapter's existing
classification, color and no-allocation behavior**?

The implementation is deliberately **not** the alias-checked fast
raster zip path; a function cannot silently gain its physical overlap
certificate merely because its math is identical.

## 2. Implementation boundary

In the **existing experimental library source only**:
[`experiments/m3_rgba_layer_compositing/source/imagery/presentation/composite.d`](../../experiments/m3_rgba_layer_compositing/source/imagery/presentation/composite.d)

Three research-only declarations are added:

- `ResearchPreparedRgbaContext` — a value containing private
  `double[256]` sRGB8 decoded channel values (**2048 byte payload**),
  a finite validated `double` opacity and one preparation-state
  bit. It owns **no pixel buffers**, **no borrowed views**, no metadata
  or locks, and does not mutate shared global state.
- `tryPrepareRgbaContext(double opacity, out ResearchPreparedRgbaContext)`
  — initializes the table **at runtime from actual public
  `color-d v0.2.0` transformations**, once per context, rejecting
  NaN, +/-infinity, negative or >1 opacity. `out` resets to inert
  `.init` before any work, so an invalid preparation leaves no
  stale formerly-prepared value.
- `tryCompositeRgbaSourceOverPrepared(ref const Prepared, scope top,
  scope bottom, Region2D roi, scope output)` — uses validated
  runtime opacity + exact LUT for **encoded-straight sRGB8** sources,
  delegates premultiplication, source-over, output encoding and
  checked half-up RGBA8 quantization to existing **color-d**,
  and delegates linear-straight / linear-premultiplied byte
  interpretation to the **existing imagery research helper**.

The prepared value is passed **by ref const**, avoiding an
accidental 2-KiB copy *per ROI invocation*. Its `.init`
is inert and returns the new research error
`RgbaCompositeError.invalidPreparedContext` **before writes**.
The context's fields and positional constructor are private;
source code outside the module cannot forge or modify those
fields (whole-source compiler-negative gates are required).
A value itself can be copied when desired; it contains only
immutable *invariant values as data* and no borrowed resource,
so the copy does not extend any source backing lifetime.

The **producer and consumer both remain `@safe nothrow @nogc`**.
No `@trusted`, pointer arithmetic, independent sRGB formula,
`raster.internal` imports, GC allocation or new owner hierarchy
is necessary.

## 3. Ownership/lifetime and state transitions

The factory creates an independently reusable *configuration*;
it is **not** a prepared raster-image binding.

```text
ResearchPreparedRgbaContext.init
  ├─ rejected bad opacity -> inert; invalidOpacity
  └─ successful factory -> ready; owns 256 double values + opacity
       ├─ scope borrowed top/bottom/output in operation A
       ├─ scope borrowed top/bottom/output in operation B
       └─ ... no retained views or pointers
```

Consumers cannot use a borrowed `RasterView` after its
`RasterLease` storage expires; the **existing** DIP1000
`negative-local-lease-escape` source remains a required CI
gate. This prepared value **does not capture the views at all**,
so its own lifetime cannot accidentally prolong or replace
the backing lifetime.

Each call repeats descriptor/shape/ROI preflight and
linear-premultiplied canonical-byte validation as the old
four-plane adapter does. It does **not** claim to cache
an upstream successful physical-alias certification across calls.

## 4. Error matrix and precise limitation

| Property | One-shot four-plane reference | Prepared four-plane variant |
|---|---|---|
| Invalid opacity | `invalidOpacity` per invocation | `invalidOpacity` during factory, cannot create ready context |
| Inert/default context | no equivalent argument | `invalidPreparedContext`, before writes |
| Invalid source interpretation/ROI/output | classified before writes | same classifications, before writes |
| Noncanonical linear-PM input byte | `invalidPremultiplication`, before writes | same classified preflight |
| Encoded-straight RGB8 | actual `color-d` runtime transfer per pixel | **exact** 256-valued table, prepared once |
| Linear straight / linear premultiplied | original conversion semantics | **same helper**, no LUT misuse |
| Output | straight encoded SRgba8; alpha-zero black | same, byte-exact gate |
| Runtime opacity | yes | **yes, prepared once per session** |
| Unexpected sample/write/quantization failure | classified, **partial output possible** | same category / **partial output possible** |
| Physical source/output overlap check | explicit **caller noalias precondition** | **same caller precondition**, NOT independently proven |
| Raster executor specialized row kernels | not used | not used; **no performance claim pending benchmark** |

The scope is deliberately **narrower** than a full production
compositor. We must not describe `@safe` as proving physical
noalias: `@safe` proves memory safety, while different valid
views can still describe overlapping reachable bytes.
No failure-atomic/transactional upgrade is attempted.

## 5. Qualification matrix

The existing independent
[`smoke/source/app.d`](../../experiments/m3_rgba_layer_compositing/smoke/source/app.d)
is extended **in-place** rather than copying the independent
sRGB/Porter–Duff oracle. It already checks **432 scenes**:
2 top layouts × 2 bottom layouts × 2 output layouts ×
3 top encodings/associations × 3 bottom encodings/associations ×
3 runtime opacities (0, 0.37, 1) × 2 full/offset ROIs.
For every scene it now:

1. constructs and initializes a **fresh prepared context** using
   the scene's validated **runtime opacity**;
2. calls the prepared compositor twice with the same context and
   independent caller-owned output lease; then reuses that same context
   for a **distinct offset 2×2 ROI packet** in a second independent
   output lease, checking its four-corner RGBA values against the
   corresponding subset of the original output;
3. checks **every RGBA output channel** for exact byte equality to
   the original four-plane adapter, whose result is separately
   qualified against the independent arithmetic oracle;
4. asserts **zero thread-local GC allocation** across the two
   prepared mapping calls;
5. tests the inert `.init` and factory rejections for NaN,
   +infinity, -0.1 and 1.1 leaving the marked target **untouched**.

Together these test **51,840** output-channel observations in
the 432-scene matrix. Exact prepared-vs-old equality supplements,
not replaces, the independent original pixel oracle.

The existing DUB smoke configuration additionally has two
separate **whole-source negative compile** variants:
- `negative-prepared-constructor-forge`: external
  `ResearchPreparedRgbaContext(0.37)` must fail because
  the constructor is private;
- `negative-prepared-private-field-mutation`: external
  assignment to its private `opacity` must be denied.

The existing `negative-local-lease-escape` remains
the whole-source borrowed-view lifetime gate. The
[CI workflow](../../.github/workflows/m3-rgba-layer-compositing.yml)
is configured for **DMD 2.112.1/2.113.0 and
LDC 1.42.0/1.43.0**, debug and release.

**Qualification rule:** record the **exact-head** CI results
before calling these tests PASS. There is no native XPS
performance evidence for the new prepared four-plane
implementation; do not borrow the previous packed-zip
2.5× ratio.

## Native prepared four-plane XPS evidence — 2026-10-13

The first [pinned LDC 1.43 XPS run comparing prepared and direct
four-plane execution](m3-rgba-prepared-xps-2026-10-13.md) is now
qualified as **research-only** evidence: 24/24 SHA-256-verified
raw files, 108/108 complete paired rounds, 864/864 eight-stage
records and independent reconciliation of 192 stage medians.

For mixed-alpha source-over, the **median of per-case paired
speedup ratios** is **1.923×** at 512² and **1.933×** at
1024×768. Both-full-transparent input is a separately
classified **~3.46–3.48×** special case. All 108 direct
versus prepared pairs favor prepared, with every output
pixel verified by the research stage consumer before
and after timing and no observed current-thread GC-byte
increase.

The **once-per-context** LUT and runtime opacity preparation
was **18 microseconds median** (16–23 microseconds observed),
excluded from per-pixel timing. Actual small-ROI amortization,
runtime-input diversity and verified physical alias preflight
remain **open**.

**Crucial difference:** These are **four-plane** caller-nonoverlap
precondition kernels, not the public `raster.zipTransformInto`
physically alias-checked packed path. A 1.9× result here and
a 2.5× result there do **not** create one combined
production-safe API. No sibling changes or integration merge.

## 6. Explicit non-goals and next gate

This prototype intentionally does **not**:
- introduce `ImageryLease`, alter `RasterLease` ownership,
  or make a prepared object that retains a view between calls;
- bypass physical noalias validation in `raster-d` or claim
  the current four-plane writer is physically overlap-safe;
- modify public color transfer or add a CTFE sRGB8 table;
- silently assume a never-failing `tryToSRgba8` without
  returning the error when it fails;
- add runtime parameters to `raster.zipTransformInto` or
  make its callback stateful;
- promise a fully transactional output on every failure;
- merge to `research-integration`, `develop`, `main`
  or alter another repository.

**Next after four-compiler gates:** measure *the actual
prepared four-plane function* versus the unchanged direct
four-plane function with runtime opacities and reusable
context across multiple ROI packets. Account for the
one-time 256-entry preparation inside an appropriately
defined amortization window. Compare with the packed
zip LUT only as a **separate, narrower contract**.
Deciding a production M3 surface requires a deliberate
additional alias/error/lifetime admission review.
