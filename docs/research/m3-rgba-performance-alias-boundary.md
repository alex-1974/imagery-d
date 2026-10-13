# M3 RGBA performance and alias research: checked four-plane vs packed POD

**Date:** 2026-10-13. **Issue:** #72, Draft PR #73 stacked on Draft PR #69.
**Scope:** `imagery-d` experiments only. Neither raster-d nor color-d modified.
**Status:** Experimental mechanisms; absolute Dell-XPS evidence pending a local run.

## Source review: alias safety already exists *inside* raster-d

At the pinned `raster-d v0.2.0` code:

1. `RasterView!T` and `WritableRasterView!T` are non-owning, lifetime-bound validated views. Writability certifies write permission, **not exclusivity or noalias**.
2. `raster.zip_transform_into.zipTransformInto` explicitly rejects physically overlapping **source/destination** reachable sample bytes, checks the destination mapping's injectivity and performs every structural/alias check before the first write. Two read-only inputs may overlap.
3. `raster.copy.copyInto` uses the same physical-overlap classification policy.
4. The checker `raster.internal.same_type_overlap.validatedSameTypePlaneRegionsOverlap` and raw region execution pointers are `package(raster)` / internal. No safe, independently callable public `RasterView` overlap query or prepared arbitrary-pixel-function execution was found.

**Important distinction:** arbitrary consumers cannot recover this alias proof by inspecting the public views, but a consumer whose algorithm fits a *public raster execution operation* gains the existing prewrite alias checks automatically. Do not duplicate internal pointer arithmetic or cast away its package boundary.

## New mechanism: packed RGBA POD pixels

`raster.sample.isRasterSampleType!T` deliberately admits indirection-free POD pixel structs and static arrays, not only numeric scalar types. `color.storage.SRgba8` is a four-byte, alignment-one POD whose RGB bytes are **encoded straight sRGB** and fourth byte is straight alpha.

For a **single packed RGBA plane**, `RasterView!SRgba8` can therefore be used with `zipTransformInto!fixedSourceOver`. That route runs raster-d's checked structural and alias preflight and its internally selected raster execution kernel, while `color-d` performs color decoding, linear premultiplication and Porter-Duff source-over.

This is a **narrow technical probe, not a replacement production API**:

- opacity is compile-time fixed at **0.37**, because `zipTransformInto` currently accepts a compile-time `T,T -> T` alias and provides no runtime parameter context;
- both operands and destination are one-plane packed SRgba8 (not arbitrary four-band planar/interleaved images);
- checked color-storage quantization failure cannot be conveyed through `zipTransformInto`'s `T` return; the probe returns an intentionally detectable incorrect value on such an exceptional path and demands exhaustive differential equality for its finite fixture;
- it does not carry full image-domain metadata, linear-premultiplied input variants, variable ROI/opacity or the currently defined `RgbaCompositeError` contract.

Do not silently promote or advertise a more complete contract than this test actually covers.

## Independent real-DUB differential

`experiments/m3_rgba_layer_compositing/packed_probe/` imports released `raster-d v0.2.0`, `color-d v0.2.0` and the separate imagery research package.

It creates **six independently malloc-owned retained raster leases**: upper/lower/output for both the packed and the four-plane interleaved representations. All source pixels match a deterministic indexed fixture, including transparent pixels with hidden straight RGB.

Evidence planned and gated by `.github/workflows/m3-rgba-packed-probe.yml`:

- check each packed output pixel's four bytes against the existing checked four-plane `tryCompositeRgbaSourceOver` result;
- prove in-place packed source/output alias (destination on the same upper source lease) is rejected with exactly `RasterZipTransformError.leftDestinationOverlap`, leaving **every** upper pixel intact;
- zero thread-local GC byte delta per measured repeated call;
- alternating paired **same-mathematics, same-pixels** timing rounds for packed-zip vs four-plane path (but note different accepted layout, alias, error and opacity contracts).

These paired numbers explore a mechanism. They cannot prove general four-plane speedup or justify relaxing alpha, failure or caller-ownership semantics. Byte-equivalence here is *differential* evidence; the separate 432-scene exact independent oracle remains the numerical foundation of the four-plane implementation.

## Separate checked-access control workload

`experiments/m3_rgba_layer_compositing/bench/` measures:

- full production-like four-plane source-over with runtime opacity = 0.37;
- an eight-checked-read / four-checked-write `relay` at the same dimensions and same resident layouts.

`relay` uses different mathematics (byte XOR) and is **NOT** a semantically equivalent competitor. Its difference from the full compositor cannot by itself be attributed to the transfer function, raster access or compiler. It is a diagnostic memory/access floor only.

Both harnesses report raw **per-round microseconds**, alternate paired order, allocate all three/four/six resident sources outside timed calls and test thread-local GC bytes. `BENCHMARK.md` prohibits treating unpinned hosted CI absolute wall-clock figures as stable performance baselines.

## XPS execution and provenance

Run from the imagery repository checkout:

```bash
bash tools/research/run_m3_rgba_composite_xps.sh
```

It writes only ignored `imagery-d/data/m3-rgba-composite-xps/<UTC-stamp>/`; it reads sibling `raster-d` and `color-d` without modifying them. It records:

- git HEAD and dirty status for all three repositories;
- peeled v0.2.0 dependency tags and a warning if local sibling HEAD differs from the tag;
- LDC and DUB versions, platform, CPU, governor and memory state;
- each individual case's CSV, process resource summary, stderr/build logs and checksums.

Before turning these results into **release-qualified tagged-dependency performance claims**, the dependency HEAD/tag mismatch must be removed or the run must be repeated against genuinely pinned released sources without rewriting sibling history. CPU affinity/governor, clock drift, swap and paired direction must be documented. Resident peak from `/usr/bin/time` includes process overhead and does not isolate per-operation scratch-memory residency.

## Decision gates

1. **CI must finish on exact HEAD** for the new packed experiment; never infer success from the earlier four-plane results.
2. If packed output and prewrite alias rejection PASS, treat it as evidence for **reuse of raster-d's existing packed POD execution path**, not permission to duplicate package-private internals.
3. Analyze native XPS paired timings before asking for any new runtime-context transform API in raster-d. No modifications outside imagery-d here.
4. A real supported public surface still requires all M3 production gates and an explicit accept/reject ADR; keep the PR stack Draft.
