# ADR 0006 — First public owned Levels API

**Status:** **ACCEPTED FOR DEVELOP SOURCE API — RELEASE/API FREEZE DEFERRED**  
**Date:** 2026-10-20  
**Evidence head:** Draft PR #97, `0b4c20c3d787cf482841c852f4b4d73c77e95a7f`.  
**Integration base:** `develop` `f47c0ca521b89b526d6e943335bca57b773e08ef`.  
**Prerequisites fulfilled:** ADR 0005 (PR #84, integration `6bb8bca9`),
ADR 0004 and MIT alignment (PR #96, integration `5c9351a8`).

## Question

Should the precise, independently qualified first scalar image Levels
operation be admitted to `develop`, without promoting unneeded M1/M2
research types, remote-sensing source machinery or an image I/O framework?
This is **not** a request to freeze ABI, release `v0.x`, publish to DUB,
or merge any grandfathered experimental history.

## Accepted decision

**ACCEPT the following specific production-source API for integration
to `develop`.** This follows the owner's instruction to continue the
documented ADR acceptance and guarded integration sequence, after
accepted scope ADR 0005 and priority ADR 0004 were integrated.
It is **not** a stable API/ABI freeze, release, or DUB publication.

Public module `imagery.presentation.levels`; curated `import imagery`;
DUB package `imagery-d` (MIT, `raster-d ~>0.2.0`).

```d
struct Levels {
    double inputBlack, inputWhite, gamma, outputBlack, outputWhite;
}
enum LevelsError : ubyte {
    notAttempted, none, invalidSource, invalidRegion,
    invalidParameters, invalidChannelSelection, invalidMask,
    sampleFailure, allocationFailure, resultExceedsBudget
}
@safe LevelsError tryLevelsOwned(T)(
    scope RasterView!T pixels, Region2D roi,
    scope const(bool)[] affected, Levels settings,
    size_t maxResultBytes, ref RasterLease!float published)
if (is(T == ubyte) || is(T == ushort) || is(T == float));
@safe LevelsError tryLevelsOwned(T)(
    scope RasterView!T pixels, Region2D roi,
    scope const(bool)[] affected, Levels settings,
    scope RasterView!ubyte selection, size_t maxResultBytes,
    ref RasterLease!float published)
if (is(T == ubyte) || is(T == ushort) || is(T == float));
```

Names, named parameters, order, constraints, `@safe` and return types
are part of this proposal; consult the Ddoc/exact source for bodies.
`Levels.init` is invalid (NaN fields); `LevelsError.init` is
`notAttempted` and not success. Only an explicitly returned `none`
means successful publication.

## Semantic contract

- Already-materialized u8/u16/f32 scalar channels, any legal `raster-d`
  planar/interleaved/strided layout and nonempty bounded ROI.
- Integers normalize by 255/65535. Float uses its declared numeric domain.
  Input thresholds and gamma finite, inputBlack < inputWhite, gamma > 0;
  output range finite and 0 <= outputBlack <= outputWhite <= 1.
- Selected finite samples: clamp the threshold-normalized result to
  [0,1], raise to inverse gamma (exact gamma=2 uses sqrt), map to
  output range. Unselected channels and selected float NaN/±Inf
  numerically pass through; no bitwise NaN payload promise.
- `affected`: exactly one flag per source channel. Optional selection
  mask: one full-source-sized ubyte plane; byte/255 is editing
  strength, **not** validity, NoData, automatic alpha or opacity.
  Selection weight 1 uses mapped value directly to prevent cancellation.
- No implicit sRGB/ICC transform, alpha association, geographic CRS,
  source provenance, calibration, file decoding or 8-bit quantization.

## Memory, ownership, and failure

Output is a new independent, ROI-local interleaved `RasterLease!float`
with the source's plane count. Source/mask are borrowed; output is
published **only after full success**, replacing prior lease. Every
normally returned failure preserves the prior owner; source/result
self-owner overlap has a separate physical nonalias regression.
`maxResultBytes` caps **only new pixel payload** (ROI width * ROI height *
planes * sizeof(float)), not old output, source, metadata, allocator,
peak RSS or I/O. Zero/short fails; exact capacity passes, with checked
multiplication and signed raster layout bounds before malloc.

The two public methods are `@safe` via a single privately audited
`@trusted` malloc/free-to-raster-d token adapter. They are neither
`nothrow` nor `@nogc`; normal allocation/import failures may return
`allocationFailure`, but OOM `Error` or arbitrary exception
unwinding has no recovery or exception-atomicity guarantee. No
concurrent mutation/refcount synchronization is supplied.

## Qualification record

- Independent P6 image-to-image byte oracle, preserved output on error.
- Real extracted `git archive` consumed by separate **out-of-checkout
  DUB project**, both @safe overloads, masked/unmasked RGB, DMD2.113 and
  LDC1.43 Debug/Release. This is not third-party adoption or a DUB release.
- Normal DUB 48-case, 240-full-ROI, masked/layout/type/rollback corpus.
- Independent 90-digit Decimal oracle: 624 deterministic finite cases,
  observed worst **1 float32 ULP**, not a universal 1-ULP bound.
- DIP1000 scope and invalid API compile negatives; rendered DDox and MIT
  archive, independent real P6 file consumer.
- LDC Release paired gamma2 masked RGBA 512x384/1024x768:
  candidate/general-pow median 0.120–0.128;
  candidate/sqrt reference 1.38–1.46. No global gamma, C++ parity,
  fixed-frequency workstation or peak-RSS claim.
- Exact reference [PR CI #39392010515](https://github.com/alex-1974/imagery-d/actions/runs/39392010515),
  [push #39392004914](https://github.com/alex-1974/imagery-d/actions/runs/39392004914),
  [Fast #39392010407](https://github.com/alex-1974/imagery-d/actions/runs/39392010407):
  all success. Re-run gates for every subsequent final HEAD.

See the [admission review](../m3-levels-admission-review-2026-10-20.md),
[API audit](../m3-levels-api-audit-2026-10-20.md), and
[paired benchmark](../performance/m3-levels-paired-2026-10-20.md).

## Rejected or deferred alternatives

Mandatory ImageView metadata, universal source/cache DAG, STAC/CRS,
image codec and new pixel ownership are rejected for this first operation.
Caller-writable Into, native integer output, full colour-managed photo
semantics, `@nogc`/nothrow and additional operators are deferred until
independently justified. A public destination alias/rollback promise
without tests is explicitly rejected.

## Admission, integration and release are distinct

1. **Domain:** ADR 0005 integrated general-purpose image scope via #84,
   retaining accepted M1/M2 and their preserved research.
2. **Priority and licence:** ADR 0004 and MIT alignment integrated via
   #96. Selecting the first qualification target alone did not admit API.
3. **API:** this ADR **accepts** only the precise public surface and
   contracts enumerated above for production-source integration on
   `develop`. PR #97 must still be squash-merged with exact-head gates
   and deliberate README conflict resolution. No experimental history
   is merged wholesale.
4. **Release remains open:** explicit version/platform/compiler support,
   full release gate, API/ABI freeze, `main` promotion and DUB Registry
   publication require separate authorization.

**Decision:** ACCEPTED FOR UNRELEASED DEVELOP SOURCE CODE.
No release, tag or freeze is authorized.
