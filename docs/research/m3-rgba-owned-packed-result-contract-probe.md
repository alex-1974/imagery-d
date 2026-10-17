# M3 RGBA — Candidate B: publish-on-success owned packed result

**Status:** implemented research **consumer** probe, not an admitted imagery-d production API. Existing Draft PR #73 remains stacked on Draft #69. Writes only in imagery-d. Read-only external dependencies: published raster-d/color-d v0.2.0.

## Concrete consumer need and contract distinction

The previous [buffered packed commit](m3-rgba-public-raster-checked-commit-probe.md) staged a four-channel ROI, repacked a second ROI buffer and then called public `raster.copyInto` into a third, **caller-provided** packed destination. That last operation is necessary for the *caller-supplied destination* policy but validates only staged packed source against final target, not the original four-channel sources.

This separate experiment asks whether an application that **wants a freshly owned packed result** can make the already-checked packed staging buffer the *result itself*. This is not a transparent optimization of the caller-provided-output contract: it changes who allocates, owns and retains the output, and what a failed call can publish.

## Prototype implementation (no public API)

In the independent [432-scene DUB consumer](../../experiments/m3_rgba_layer_compositing/smoke/source/app.d), two consumer-local functions implement and test Candidate B:

- `tryCompositeOwnedPackedResearch`: calls the already-qualified image-domain `tryCompositeRgbaSourceOverPrepared` into a fresh four-plane interleaved `RasterLease!ubyte` scratch of ROI extent. Known validation/PM/quantization failures return without publishing any lease. On success, it allocates a **new** one-plane `RasterLease!SRgba8` and packs each four-channel pixel by public `trySample` / `trySetSample`. It returns status `none` and **only then** publishes the packed lease into a caller-supplied empty `RasterLease!SRgba8` result parameter.
- `checkOwnedPackedResult`: byte-compares **every** packed pixel against the already independently qualified original four-plane output for each of the 432 scenarios (2 input layouts × 2 input layouts × 2 reference output layouts × 3 top representations × 3 bottom representations × 3 opacities × 2 ROIs). Verifies inert context and invalid huge/overflow ROI do **not** publish a lease. The existing premultiplication-negative source fixture additionally checks that noncanonical linear-premultiplied input returns `invalidPremultiplication` without publishing any packed result. Also issues a second independent 2×2 ROI request with the same prepared context and checks that the previous result stays byte-identical.

Additional `checkOwnedPackedWithSharedOriginalBacking` runs a concrete same-owner source alias: **upper and lower read-only layers borrow one genuine retained `RasterLease!ubyte`**, matching against the existing independently computed four-plane oracle. The newly published packed output must remain unchanged even after the original source lease is subsequently mutated via a *legitimate* writable borrow. No typed alias is forged and no second owner is created for the original allocation.

**Scratch is always privately owned**. The retained `RasterLease!SRgba8` result holds the packed allocation; assigning it retains the same backing through raster-d's shared ownership and does not create a second independently releasing malloc resource. With no original/result physical sharing, source/output disjointness follows **by construction** during this controlled single-threaded execution, not from a public arbitrary-typed overlap classifier.

## Residency and failure semantics

For ROI of N pixels (4 bytes per RGBA8 pixel):

| Phase | Incremental pixel-storage payload relative to retained source | Surviving payload after call |
|---|---|---|
| Four-plane staging | 4N bytes | — |
| Packed staging and complete repack | max **8N bytes** simultaneously | — |
| Publish staged packed owner; discard four-plane scratch | — | **4N bytes** packed result |

This eliminates the old three-buffer design's extra destination allocation and last `copyInto`. It does **not** eliminate the four-plane preparation or RGBA repack, the native allocations, metadata allocations, or the one-time prepared-context LUT. No native performance or GC delta is claimed for this prototype.

- On classified image-domain errors, the packed result stays **unpublished** and provisional scratch is automatically destroyed. The independent consumer tests inert context and invalid ROI; the pre-existing per-scene oracle covers valid inputs and linear-PM scenarios. It does not inject arbitrary late sample failures, heap failure or concurrent mutation.
- Native `malloc`/owned-raster import failures are handled by the *existing independent consumer* checked helpers, which throw. They are **not** converted to `RgbaCompositeError`; Candidate B is **not** an exception-free or general `@nogc` library API.
- The caller must provide an *empty* output lease; this condition is checked by the consumer and a nonempty lease triggers the consumer's exception helper. The operation does not silently replace a published result.
- Source/result disjointness arises from **two distinct genuine allocations** (scratch/new packed result) and no borrowed retyping. No promise about thread-safe use of mutable sources, concurrent cancellation, arbitrary callback failure-atomicity or cross-type original/output physical alias rejection is made.
- ROI **extent arithmetic** is checked before allocation to prevent overflow in `w × h × 4`; semantic source/ROI containment checks still run in the prepared compositor, after allocating the four-plane scratch, and may return their established statuses.

## Admission and measurements

The existing [source-over CI workflow](../../.github/workflows/m3-rgba-layer-compositing.yml) requires a diagnostic `M3 RGBA owned-packed result PASS: 432 byte-exact scenes` in its **debug** independent-consumer run and still runs both debug and release, all existing negative DIP1000/compiler tests, plus the newly accepted public-owner alias probe on DMD 2.112.1 / 2.113.0 and LDC 1.42.0 / 1.43.0.

**Do not claim PASS until exact-HEAD CI succeeds.** The benchmark [XPS allocation/reuse matrix](m3-rgba-buffered-micro-xps-2026-10-13.md) measured the **different three-buffer strategy** (both scratch buffers plus last packed `copyInto`). Its ratios **must not** be attributed to this owned-result implementation. Any native Candidate B benchmark must time its own allocation+conversion+packing, count peak pixel payload and metadata and include at least one realistic multi-ROI consumer.

**Design decision:** Candidate B remains a separate proposed *owned-result image-domain API*; the original-source vs caller-owned packed target overlap guarantee in Candidate A remains **BLOCKED**. No release, merge, base retarget or sibling dependency/API change is authorized by this probe.
