# ADR 0006 — First public owned Levels API

**Status:** PROPOSED ACCEPTANCE — **NOT YET ACCEPTED OR MERGED**  
**Date:** 2026-10-20  
**Evidence head:** Draft PR #97, `0b4c20c3d787cf482841c852f4b4d73c77e95a7f`.  
**Integration base:** `develop` `f47c0ca521b89b526d6e943335bca57b773e08ef`.  
**Prerequisites:** scope clarification ADR 0005 (Draft #84), Levels priority
ADR 0004 (Draft #96); both are unmerged.

## Question

Should the precise, independently qualified first scalar image Levels
operation be admitted to `develop`, without promoting unneeded M1/M2
research types, remote-sensing source machinery or an image I/O framework?
This is **not** a request to freeze ABI, release `v0.x`, publish to DUB,
or merge any grandfathered experimental history.

## Proposed decision

**Recommend acceptance of the following *specific* production source API
for pre-1.0 integration**, subject to explicit admission approval and
guarded resolution/integration of #84 and #96. At this stage this document
is a proposed decision, not an accepted ADR.

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

1. **Domain scope:** review Draft #84 / ADR 0005, including actual
   README/DESIGN/ROADMAP differences; no rewrite of accepted M1/M2.
2. **Operator priority:** review Draft #96 / ADR 0004 and MIT metadata;
   the accepted decision is *candidate priority*, not API.
3. **Public API:** explicitly accept or reject the precise surface above,
   then reconcile its Draft #97 changes with the integrated `develop`.
   README changes overlap on all three PRs; #96 and #97 LICENSE bytes
   are identical. Do not merge or rebase historical research PRs.
4. **Release:** define supported toolchain/platform and package version;
   repeat exact integration/release qualification before main or tag.
   Neither `develop` admission nor an ADR automatically grants a
   freeze, registry publication or release.

**Current verdict:** TECHNICALLY QUALIFIED, **ACCEPTANCE RECOMMENDED,
DECISION PENDING**. No merge, tag or release is authorized by this file.
