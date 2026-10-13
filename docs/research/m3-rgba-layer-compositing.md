# M3 RGBA layer source-over: bounded research qualification

**Date:** 2026-10-13. **Issue:** #72. **Parent:** Draft PR #69 at `02eaca00149bc52de3c204903367c5c368c369ad`.
**Status:** Research prototype; production admission **NOT** granted. Results must be evaluated against the exact CI head.

## API and dependency audit (read-only)

The `color-d` **v0.2.0** tag resolves to commit `3359f08f4e83941ac1a8451cadefb146b5736019`; comparison to `develop` found no changes to public color source files. Verified public source declarations:

- `color.storage.SRgba8`: packed RGBA bytes have **straight encoded sRGB** meaning. `toAlphaSRgb!double` and `tryToSRgba8` normalize/check/quantize with half-up byte rounding.
- `color.rgb.SRgbd.toLinear` and `LinearSRgbd.toSRgb`: explicit sRGB transfer.
- `color.alpha.Alpha`, `Premultiplied`, `premultiply`, `unpremultiply`: explicit straight/linear-premultiplied distinction and zero-alpha canonicalization.
- `color.composite.sourceOver`: accepts **premultiplied linear** sRGB, not raw encoded RGB; `@safe pure nothrow @nogc`; does not clamp/validate.
- `raster-d` `RasterView!ubyte` and `WritableRasterView!ubyte`: nonowning, checked per-component read/write and legal planar/interleaved layouts; **no public noalias/physical-overlap guarantee**.

**Compiler policy:** color-d v0.2.0 supports DMD 2.112.1/2.113.0 and LDC 1.42.0/1.43.0. The older M3 DMD2.111/LDC1.41 evidence is not evidence of compatibility of the new full color-d dependency.

## Single research operation

`imagery.presentation.composite.tryCompositeRgbaSourceOver` is compiled in its **own** research-only DUB library and invoked by an independent DUB executable. It accepts two same-grid borrowed four-plane RGBA8 images, a bounded nonempty `Region2D`, one explicit top-layer opacity (finite 0..1), and a caller-owned four-plane destination with exactly the ROI dimensions.

Both inputs carry independent `RgbaEncoding` (`encodedSRgb` vs `linearSRgb`) and `RgbaAssociation` (`straight` vs `premultiplied`) tags. Encoded-premultiplied byte input is rejected: its math and storage contract cannot be inferred from `SRgba8`. Premultiplied bytes, when accepted, are **linear** values; RGB must each be <= alpha. Their ROI samples are validated before writes.

The output is always **straight encoded sRGB RGBA8**. Invisible RGB at fully zero final alpha is canonical transparent black (unlike the older byte-preserving tile mapper). The top-layer opacity scales both *premultiplied* linear light and alpha before `color-d.sourceOver`; no second Porter-Duff implementation is introduced.

The adapter performs no decoder, network fetch, tile mosaic, reprojection, image-wide temporary allocation, or scheduler work. All source/backing lifetimes remain external.

**Failure semantics:** invalid image format/association, ROI/target shape, opacity and noncanonical linear-premultiplied samples are rejected before the first output write. Unexpected sample/quantization errors in the output pass may leave a partial result; rollback is not promised. **Aliasing remains an explicit caller precondition, not an enforced runtime rejection** because raster-d's current public views cannot prove disjoint storage. This is a production admission gap.

## Independent consumer/oracle design

A separate DUB executable holds three **independent `RasterLease!ubyte` allocations** (top, bottom, target) and uses only documented module entry points. It computes expected pixel values from *separately implemented* sRGB transfer and source-over equations using doubles, not `color-d` conversion or compositor calls.

Matrix:
- 2 layouts for each of upper, lower, output = 8;
- 3 meaningful image storage models per layer: encoded/straight, linear/straight, linear/premultiplied = 9 pairs;
- 3 upper opacities: 0, 0.37, 1;
- 2 source ROIs: 8x6 whole and offset 4x3;
- **432 scenes**, **51,840 output component comparisons** at every actual pixel, up to one 8-bit quantization step for independently rounded implementations.
- The deterministic fixture includes alpha 0, 64, 128, 255, distinct upper/lower data, invisible nonzero straight RGB, planar/interleaved layouts, and offset ROI.
- Output sentinel preservation is checked after invalid NaN/negative opacity, bad ROI, and encoded-premultiplied declaration. Premultiplied invalid RGB>alpha is injected and tested separately.
- Calls measure thread-local GC allocated-byte delta. **This does not establish no malloc, no GC pause, no end-to-end latency, or XPS production performance**.
- `-preview=dip1000` negative configuration must reject return of a `DecodedRgbaLayer` borrowing a locally expiring `RasterLease`.

## Qualification status

The dedicated workflow `.github/workflows/m3-rgba-layer-compositing.yml` checks debug and release builds, exact full-output oracle, preflight, local lease lifetime negative and no production root under **DMD 2.112.1/2.113.0 and LDC 1.42.0/1.43.0**. Until those jobs finish for an exact commit, the implementation and the 432-scene counts are **test design, not a reported PASS**.

## Open gates before a production decision

- CI must establish correct compilation and independent results on exact HEAD.
- Need an *enforceable* alias contract or deliberately separated destination/validated nonoverlap capability before claiming runtime checked alias safety.
- Need a separate XPS optimized benchmark and complete source/target lifecycle accounting against the pinned released dependencies; per-pixel `trySample` is a correctness baseline, not a demonstrated high-performance renderer.
- Real independent image consumer and the 13 M3 admission gates, including an explicit accept/reject ADR, remain outstanding.
- No M3 research PR, including this one, is merged into `develop`, `research-integration`, or `main` by this work.
