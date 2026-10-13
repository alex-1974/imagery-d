# M3 decoded RGBA tile background consumer — independent full-pixel results

**Date:** 2026-10-13. **Status:** research-only candidate, not a Dunia integration, public imagery-d API, decoder, renderer, M3 admission ADR, or release. Tracking: [Issue #68](https://github.com/alex-1974/imagery-d/issues/68), [stacked draft PR #69](https://github.com/alex-1974/imagery-d/pull/69), above [independent multispectral consumer PR #67](https://github.com/alex-1974/imagery-d/pull/67) and [module import proof PR #65](https://github.com/alex-1974/imagery-d/pull/65).

## 1. Exact bounded question and source responsibility

Can a D program holding **multiple already decoded neighbouring RGBA raster tiles** use the research-only `imagery.presentation` import surface to create an explicitly requested viewport (panning/cropping and deterministic nearest-neighbour scaling), while preserving alpha bytes and having no visible seams, hidden allocations, implicit alpha/NoData coercion or unexpected output mutation on invalid input?

**In scope:** six caller-owned `raster-d` `RasterLease!ubyte` 4-component tiles on a 3×2 regular logical pixel grid, typed borrowed `RasterView!ubyte`, explicit world-pixel tile origin and shape, output to caller-owned 4-component `WritableRasterView!ubyte`, declared alpha association, integer/rational scale parameters and explicit source ROI.

**Not in scope:** `imageio-d` JPEG/PNG/GeoTIFF decoding; OSM/Editor Layer Index/provider licenses; HTTP/TMS/WMS/WMTS; cache L1/L2/L3, revision, prioritization, scheduler/cancellation, GPU upload/renderer; world-coordinate projection; compositing one map layer over another; colour transfer curves, gamma, ICC or filtering/interpolation with a halo. The M2 source/cache architecture remains accepted but is not implemented by this short image operation. The consumer name refers to a *class of use cases*, not a dependency on Dunia.

**Alpha contract:** because [accepted M1 ADR 0002](../adr/0002-image-semantic-core.md) forbids inferring alpha solely from four planes, the test function requires an explicit `RgbaAlphaAssociation` (straight, premultiplied or explicitly unknown; `.init`/unspecified is invalid). Its *caller* states the four source planes mean ordered R,G,B,A; the method simply **copies the four encoded `ubyte` samples without interpreting colour, modifying alpha, premultiplying, compositing or deciding NoData/validity**. The synthetic premultiplied inputs are prepared **by the test fixture**, not automatically converted in imagery.

## 2. Implementation under experiments/

- `experiments/m3_module_import_surface/source/imagery/presentation/tiles.d`: `DecodedRgbaTile`, `RgbaAlphaAssociation`, `RgbaTileError`, `tryMapNearestRgbaTiles` all **research-only**.
- `experiments/m3_module_import_surface/source/imagery/presentation/package.d`: intentional family export. `imagery` root still imports only `core`. `imagery.all` expands only through the existing `presentation` family.
- `experiments/m3_module_import_surface/smoke/source/consumers/tiles.d`: truly **separate DUB executable** using `imagery.presentation.tiles` and `raster-d` directly, with no imports of M1/M3 private contract modules.
- `experiments/m3_module_import_surface/smoke/source/app.d`: invokes this consumer alongside the previous independently tested 16-case multiband research consumer.
- `.github/workflows/m3-decoded-rgba-tiles-consumer.yml`: DMD 2.111/2.113 and LDC 1.41/1.43, Ubuntu 24.04, debug+release, `raster-d` at tagged `v0.2.0`.

All operation inputs/outputs are already resident, non-owning or caller-owned; none of the tile mapping's `@safe nothrow @nogc` calls allocate. `GC.stats().allocatedInCurrentThread` deltas are checked around *each successful map*, excluding fixture and owner creation. Zero allocated bytes **does not mean** a collector cannot ever pause the thread, nor that malloc/other setup storage costs are zero.

## 3. Explicit pixel coordinate and scaling contract

Tiles have exact row-major logical positions `(column * tileWidth, row * tileHeight)`. These are **mosaic pixel coordinates**, neither `RasterView.region` nor CRS/geographic coordinates. The method checks every supplied tile's four-plane/shape/position contract and requires complete grid coverage in this limited regular-grid model.

The caller selects an actual ROI in the mosaic and an explicit rational scale `numerator/denominator`; only **integral positive destination dimensions** are supported. Pixel-origin aligned nearest samples the source at `srcX = roi.x + floor(dstX * denominator / numerator)` and similarly for `srcY`. The method does not claim pixel-centre or anti-aliasing semantics; no hidden linear interpolation is performed. Overflow/zero-scale and outside-grid dimensions are rejected prior to writing output.

Under the selected contract, upsampling duplicates bytes and downsampling selects samples; **alpha is sampled with the same explicitly chosen rule** and never interpolated or used as validity. At zoom/ROI seams the same global source coordinate picks the same channel value independent of which tile contains it.

All preflight classifications (`invalidGrid`, `invalidAssociation`, `invalidRegion`, `invalidScale`, `destinationMismatch`) **preserve all caller output pixels**. If a validated view unexpectedly refuses a pixel read/write after preflight, `sampleFailure` may leave a partially filled buffer; this function does **not** pretend to be an all-or-nothing transaction.

## 4. Independent oracle, cases and numerical strength

**Fixture grid:** 3 columns × 2 rows of decoded **4×4** tiles = **12×8** logical image. Four component byte samples are generated from absolute global logical `x,y`. Straight alpha fixtures retain nonzero invisible RGB; premultiplied fixtures independently produce associated RGB. Alpha takes **0, 128 and 255** values.

**Test matrix:** 2 source layout families × 2 *independently selected output* layout families × 2 alpha associations × 6 ROI+scale views = **48 complete actual output rasters**.

| View | Source ROI (x,y,w,h) | Scale | Destination (w×h) | Output positions per layout/alpha combo |
|---|---|---|---|---:|
| Whole | (0,0,12,8) | 1× | 12×8 | 96 |
| Upscale | (0,0,12,8) | 2× | 24×16 | 384 |
| Downscale | (0,0,12,8) | 0.5× | 6×4 | 24 |
| Crop/pan crossing x=4/8, y=4 seams | (3,2,6,4) | 1× | 6×4 | 24 |
| Cropped upscale | (3,2,6,4) | 2× | 12×8 | 96 |
| Rational crop | (2,0,8,6) | 1.5× | 12×9 | 108 |

One input/output/association combo therefore checks **732 output positions**. All eight combos check **5,856 RGBA pixel positions and 23,424 separately compared component bytes**, generated through an **independent global-pixel oracle** (not by reading the input tile with the same sample index algorithm). That all-component oracle also checks every tile boundary, all interior pixels and invisible/partial/opaque alpha values; it does not simply checksum the result.

After each successful map, the consumer overwrites output with sentinels and tries malformed requests. Tests require explicit error classes and no changed sentinel pixel for: wrong tile placement, missing tile, missing decoded tile view/four-plane shape, `unspecified` alpha, out-of-grid ROI, zero scale, nonintegral target size and wrong output dimensions. These are **preflight errors** and do not exercise an artificial unsafe pointer or a forced late sample failure.

**Comparison with the preceding M3 research:** [multispectral standalone DUB consumer](m3-standalone-image-roi-consumer.md) verifies 16 configurations/48 complete small ROIs with stored-vs-physical band values and independent validity. The new tile consumer verifies spatial **image assembly and alpha byte preservation**, which is a different class of image-domain behaviour. It does not silently pass off simple 4-channel RGBA as scientifically calibrated multispectral data.

## 5. Constraints and next candidate

Independent DUB smoke uses only `raster-d` as external dependency. A real decoding consumer may later compose `imageio-d` and imagery/raster boundaries without making codecs mandatory dependencies of `imagery.core`. No evidence here establishes cache efficiency, GUI frame times, pixel-filter quality at fractional zoom, blending correctness for two layers, scene-graph design, WMS/tile provider throughput, CRS transformations or XPS-optimized performance.

**Research admissible conclusion:** a typed, explicitly declared decoded RGBA tile consumer can perform exact nearest-neighbour pan/zoom/region output with preserved alpha and correct seams, independent of Dunia/GUI/source transport. **Production admission remains blocked** by [M3 Issue #24](https://github.com/alex-1974/imagery-d/issues/24) until complete selected operation semantics, true external adoption, full lifecycle memory/performance, release-quality public API and an explicit accepting/rejecting ADR. This PR remains Draft stacked on #67; no merge or sibling repository changes.
