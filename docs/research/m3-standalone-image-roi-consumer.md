# M3 independent DUB checked ROI consumer — functional qualification

**Date:** 2026-10-13  
**Classification:** Research/Verification for an M3 candidate consumer.  
**Issue:** [#66](https://github.com/alex-1974/imagery-d/issues/66).  
**Stacked draft PR:** [#67](https://github.com/alex-1974/imagery-d/pull/67), on [module-import PR #65](https://github.com/alex-1974/imagery-d/pull/65).  
**Scope:** prove an ordinary **separate DUB executable** can import the
hierarchical imagery modules and execute real, numerically checked
multi-channel masked/stored/physical image ROI work without importing
any M1/M3 private research module. **No production package or public
API admission is implied.**

## 1. Exact consumer path

The consumer exists at
`experiments/m3_module_import_surface/smoke/source/consumers/roi.d`
and is invoked from that independent DUB program's `app.d`.
It depends via DUB on the **research-only** library under
`experiments/m3_module_import_surface/`; that library's only
external DUB dependency is `raster-d`.
The consumer imports:

```d
import imagery.core.channel : ChannelDescriptor;
import imagery.core.metadata : IntrinsicChannel;
import imagery.presentation.channels :
    ColourBinding, DeclaredColour, ValueInterpretation,
    ResearchLongLivedMetadataSource, SourceRoiError;
import raster : RasterLease, RasterView, Region2D,
    OwnedByteResource, PlaneByteLayout,
    tryAdoptMallocResource, tryImportOwnedRaster;
```

The consumer never imports `m1_5_image_view.contract`,
`m3_2_channel_metadata.contract`,
`m3_2_metadata_source.contract` or a private checked pixel
executor directly. The package facade re-exports the **actual
previously qualified experimental implementation**, not a stub.

The source raster is independently constructed with `malloc`
plus `raster-d`'s owned resource adoption and typed
`RasterLease!float`. Validity is a separately owned
one-plane `RasterLease!ubyte`; the destination is a separate
three-plane caller-owned raster. Pixel/mask backing is
**never** transferred into the long-lived immutable metadata
source, and the scoped adapter call is the only way the consumer
uses the Prepared mapping. This is an explicit real ownership
path but is **not a measured full-lifecycle allocation budget**.

## 2. Complete numerical/failure test matrix

The source grid is **9×7 with five channels**; the actual
selected three-component binding is input channels **4, 2, 0**,
in that deliberate non-RGB-default order. The three input
windows of size **3×2** are:

```text
(0,0)  (2,1)  (5,3)
```

The raster source's declared layouts are planar and
interleaved; the destination is purposely assigned the
**opposite** layout in each case. The one-plane validity
mask is explicitly optional, and when selected uses a
known invalid-pixel pattern including **interior pixels**.

Every case uses two value policies:

- `stored`: returns the selected raw source channel value,
  with invalid pixels set to zero under the **explicit
  research fixture policy**;
- `physical`: maps `stored * scale + offset`,
  with independent immutable metadata generations:
  original **0.5/−4** and refreshed **2/+1**.
  This is *not* sRGB conversion or implicit normalization.

The raw independent source formula is
`channel*100 + y*10 + x`; invalidity is
`(x + 2*y) % 5 == 0` when validity is used.

**2 source layouts × 2 validity states × 2 value
interpretations × 2 immutable metadata generations =
16 configurations.** Every configuration runs a *single
actual batched* mapping over its three ordered ROIs and
collects 18 observed first/last corner values. Then it
maps each ROI individually through the **same real checked
mapping method**, reading and independently checking every
pixel of every output component against the external
source/mask/calibration formula:

- **48 complete single-ROI images**;
- **48 × 3 components × 3×2 pixels = 864 independent
  component-pixel comparisons**;
- batched first/last corner values are compared with the
  individual-call first/last values and with the independent
  external formula for every ROI;
- the D-side comparisons are exact `float` values using
  entirely exactly representable source/calibration cases.

This is stronger coverage of *all intermediate ROI
interiors* than M3.2.18/20's six-corner-only external
transcripts. **Do not overstate it**: the three-window
batched call reuses one destination and only exposes
corner observations for intermediate windows; the full
intermediate images are reconstructed by **separate
single-ROI calls** under the same checked implementation.
It is not a trace of all intermediate pixels produced
during the batched call.

Mapping allocations are checked as the difference of
`GC.stats().allocatedInCurrentThread` around each
successful batch and single-ROI operation.
The consumer requires **zero new allocated GC bytes**
in each such call, not zero allocations across
fixture creation or zero GC collector pauses.
All fixtures and source metadata copies are created
outside those checks.

Failure classes are explicitly exercised:

- An ROI outside the source grid returns
  `SourceRoiError.invalidRegion` without modifying any
  destination pixel or caller first/last observations.
- A selected source channel outside the available five
  planes returns `SourceRoiError.invalidBinding`.
- The original mutable intrinsic metadata is updated
  after the first immutable snapshot; the original
  generation keeps its old channel labels/calibration,
  while a new snapshot reflects the new metadata.
- The mask remains **different from alpha/NoData/colour**
  as required by M1 ADR 0002. Invalid-to-zero remains a
  **fixture policy only**, not an admitted imagery-d
  production invalidity/output API.

## 3. Reproducibility and four-compiler gate

The research workflow
`.github/workflows/m3-standalone-image-roi-consumer.yml`
uses Ubuntu 24.04, `raster-d` Git tag `v0.2.0` in a
local path dependency, and the four workspace compiler
targets:

| Compiler | Independent DUB debug | Independent DUB release |
| --- | --- | --- |
| DMD 2.111.0 | PASS | PASS |
| DMD 2.113.0 | PASS | PASS |
| LDC 1.41.0 | PASS | PASS |
| LDC 1.43.0 | PASS | PASS |

**Measured source revision:** `cb26a6d9886a0f0b1d16979a1f474cb0410e8319`.  
**Completed CI:** [Actions #38365247409](https://github.com/alex-1974/imagery-d/actions/runs/38365247409) **4/4 SUCCESS**, including the original root/core/presentation/all/direct import smoke and the newly added actual ROI consumer.

Run on a workspace with an adjacent `raster-d` checkout:

```bash
dub run --root=experiments/m3_module_import_surface/smoke \
  --compiler=dmd --config=default --build=debug --force
dub run --root=experiments/m3_module_import_surface/smoke \
  --compiler=ldc2 --config=default --build=release --force
```

**Do not confuse this narrow functional verification with a
full Dell XPS optimized-performance baseline.** The new
consumer intentionally collects no elapsed-time distribution,
allocation peak/RSS, full metadata/source-lifecycle cost,
scheduler noise or IO/read latency.

## 4. Decision and remaining production gates

**ACCEPT for M3 research:** the proposed hierarchical module
facade is usable from a genuinely distinct DUB dependency and
exposes a real checked ROI operation; 16 representative source/
layout/mask/radiometry/generation combinations and all 48
single-ROI grids pass the independent pixel oracle under
both DMD and LDC in debug and release.

**NOT YET a downstream external adoption:** This executable
lives in the imagery-d repository as a verification consumer;
it does **not** establish that an independently maintained
third-party application uses the candidate API.

**M3 public admission still DEFER:** the parent
[Issue #24](https://github.com/alex-1974/imagery-d/issues/24)
and [M3 selection document](m3-first-production-slice-selection.md)
still require a named production caller with accepted semantic
and validity policy, minimal non-experimental D API and failure
contract, full memory/residency accounting and competitive
end-to-end optimized benchmarks with exact dependency
pinning, and a separate accepting/rejecting ADR.

The implementation remains under `experiments/`.
No root `dub.sdl` or public `source/imagery/**` was created;
the existing M3.2 negative lifetime/forgery oracle code
and research stack remain unchanged. No merge to
`develop` or `research-integration`; no writes to
other workspace repositories.
