# M3.2.2 — Intrinsic channel identity and explicit radiometry evidence

**Status:** Focused synthetic experiment **PASS**; production API admission **deferred**.  
**Date:** 2026-10-11  
**Repository:** `alex-1974/imagery-d`  
**Research branch:** `research/m3-2-channel-metadata`  
**Validated implementation / workflow commit:** `61606dcf6758ac3ea94cbc0510e944b05f887d51`  
**GitHub Actions:** [run 38131693229](https://github.com/alex-1974/imagery-d/actions/runs/38131693229)  
**Dependency:** `raster-d` tag `v0.2.0`  
**Platform:** GitHub-hosted Ubuntu 24.04, x86-64

## Compiler and lifetime matrix

| Toolchain | M3.2.1 + M3.2.2 debug | M3.2.1 + M3.2.2 release | M1.5 positive | Four `@safe` lifetime negative builds |
| --- | --- | --- | --- | --- |
| DMD 2.111.0 | PASS | PASS | PASS | 4/4 rejected |
| DMD 2.113.0 | PASS | PASS | PASS | 4/4 rejected |
| LDC 1.41.0 | PASS | PASS | PASS | 4/4 rejected |
| LDC 1.43.0 | PASS | PASS | PASS | 4/4 rejected |

All four jobs completed with `success`. Each job log contains two
`M3.2 PASS` messages (debug + release) and four expected rejection
messages (primary, metadata, validity, ROI lifetime escape). The
original M1.5 positive runtime test also completed successfully.

**Important:** These are compiler/runtime regression probes, not benchmarks
or a supported-compiler-floor announcement for a future public package.

## Evidence demonstrated

The extended test in `experiments/m3_2_semantic_display/source/app.d`
reuses the accepted M1.5 experimental `ImageView!float` lifetime
implementation, not a separate competing view or raster owner. A new
`m3_2_channel_metadata.contract` module adds an entirely provisional
borrowed, read-only intrinsic metadata descriptor and colour binding.

- **Opaque channel identity:** four channels retain stable IDs and source
  labels; `R`, `NIR`, `B08`, and `G` do **not** dictate display order.
  Explicit display component indices are (3, 2, 1).
- **Raw versus physical:** raw selection leaves float samples unchanged;
  physical selection explicitly calculates `stored * scale + offset`.
  A deliberately uncalibrated channel remains valid in a raw product and
  need not block other selected calibrated channels.
- **No invisible normalisation/clipping:** test values after physical
  calibration include both negative values and results greater than 1.
  No automatic sRGB conversion takes place even if a binding contains a
  declared encoding tag.
- **Failure modes:** channel count mismatch, mismatched semantic ID,
  repeated or out-of-range component selection, missing calibration on a
  selected channel, and non-finite scale/offset are rejected before
  destination writes.
- **Layout neutrality:** planar/interleaved, whole processing versus four
  uneven ROI partitions, and independently built equivalent raster samples
  retain identical numerical results.
- **Validity:** an optional `ubyte` mask remains independent of calibration,
  alpha, and NoData; the mask-free path allocates no validity buffer.
  Invalid-to-zero is a **test policy**, not universal image semantics.
- **Lifetime:** M1.5 compile-negative probes remain intact and are rerun
  without editing the original M1.5 implementation.
- **Function attributes:** the experiment's mapping kernel is declared
  `@safe nothrow @nogc`.

The synthetic exact-value oracle independently constructs input samples as
`channel * 100 + y * 10 + x`, applies explicit fixture calibration constants,
and compares stored and physical output exactly. These binary-exact test
constants qualify this narrowly bounded corpus, **not** general floating
point radiometric error budgets.

## Memory bookkeeping

One 7 × 4 four-channel float source uses 448 raw sample bytes.
The M3.2.1 whole and partition outputs use 336 bytes each.
During M3.2.2, three additional 3-channel float outputs are simultaneously
allocated (336 bytes each), plus an optional 28-byte validity raster.

| Raw sample payload resident at the M3.2.2 probe peak | Bytes |
| --- | ---: |
| Four-plane float source | 448 |
| Two original three-plane float outputs | 672 |
| Three M3.2.2 three-plane outputs | 1,008 |
| Optional `ubyte` validity | 0 / 28 |
| **Total without validity** | **2,128** |
| **Total with validity** | **2,156** |

These are **calculated** fixture payload sizes, excluding metadata, lease
control blocks, allocation overhead, executable runtime, and RSS. They do not
establish a real peak-memory measurement or performance advantage.

## Unresolved admission questions

1. Metadata owner/lifetime: experiment passes channel metadata only as
   borrowed arguments to the operation; a production owner retaining metadata
   and leases together remains undecided.
2. Intrinsic meaning: sample calibration field types, units, arbitrary
   source labels, semantic IDs and real interoperability schema remain
   provisional, not frozen.
3. Alpha association, NoData, quality masks, colour profile processing,
   and source radiometric provenance are independent unsolved design gates.
4. Error atomicity and partial-result publication during runtime sample
   failures are not tested as a transactional contract.
5. Real decimal input and general floating-point arithmetic need independent
   numerical tolerance/oracle qualification; scalar `float` is not yet a
   justified universal physical representation.
6. Optimized LDC throughput, cache behavior, allocator instrumentation,
   varied ROI dimensions and a raster-only benchmark control are missing.
7. No real `imageio-d` decoders, geospatial CRS handling, M2 remote
   materialization, cache or source revision validation were involved.

**Decision:** Retain these results in a research PR; **do not yet freeze
`ImageView`, channel metadata, radiometry, display binding, colour mapping
or a public production package.**

Tracking: [issue #26](https://github.com/alex-1974/imagery-d/issues/26),
[stacked PR #27](https://github.com/alex-1974/imagery-d/pull/27), underlying
[M3.2.1 PR #25](https://github.com/alex-1974/imagery-d/pull/25).
