# M6 feature region experiment

This executable qualifies the directly imported library module `imagery.analysis.feature_regions` for [#182](https://github.com/alex-1974/imagery-d/issues/182). The [slice contract](../../docs/m6-feature-region-slice.md) describes the proposed production semantics.

A caller supplies either sRGB8 or a scalar measurement through a synchronous region reader. The feature engine publishes scoped tiles to a sink. The scalar source carries a band and unit. Local mean and standard deviation retain that unit. Gradients are measured per grid pixel, with direction in radians. Source and channel metadata participate in cache identity. Each tile and aggregate carries provenance with source identity, revision, grid, level, selected channel, unit, output extent, feature and implementation version. The fixed operator parameters are tied to that version. For volume or area measurements, callers must supply an explicit coordinate conversion before interpreting gradients in physical units.

The executable checks local statistics and Sobel against direct independent calculations on masked synthetic temperature data, including source edges and several processing decompositions. It also checks OKLab white, a hand-counted RGB histogram, cache reuse and revision invalidation, and constant gradients over procedural sources of different total size.

## Reproduce

Run from this directory. Fetch the manifest-pinned input with `python3 ../../tools/fetch-m4-real.py --fetch` if the local JPEG is absent.

```sh
dub run --compiler=dmd --config=default
DFLAGS=-preview=dip1000 dub run --compiler=dmd --config=no-io
dub build --compiler=ldc2 --build=release --config=no-io
fixture=$(mktemp)
magick ../../data/m4/land_ocean_ice_2048.jpg -colorspace sRGB -depth 8 "rgb:$fixture"
/usr/bin/time -f 'Peak process RSS: %M KiB' ./m6-feature-regions "$fixture"
unlink "$fixture"
```

## Independent photograph reference

The optional photo check compares color and local contrast pixel by pixel with independent formulas. It reads the same photograph through RGB rows with 17 padding bytes, and compares a non-origin region reaching the right and bottom image edges under two tile decompositions. The reference uses the original packed pixels, direct linear RGB-to-OKLab matrices and a two-moment variance calculation.

Both DMD 2.111.0 and LDC 1.42.0 Release passed using the local Ubuntu wallpaper photograph `Derwentwater_by_mendhak.jpg`. The photo stays external to this repository. The check expects a photograph whose 5th and 95th percentile bins are distinct and interior, with samples on both sides of the fitted interval.

```sh
fixture=$(mktemp)
magick /usr/share/backgrounds/Derwentwater_by_mendhak.jpg -resize '64x48!' -colorspace sRGB -depth 8 "rgb:$fixture"
dub run --compiler=dmd -- --photo "$fixture"
dub run --compiler=ldc2 --build=release -- --photo "$fixture"
unlink "$fixture"
```

The source JPEG SHA-256 was `2ccb383e169c7ace22edf466f03ceeb843e8eb215b7281183622cc180762837e`. The prepared RGB8 fixture SHA-256 was `25b4bd4673cbe9bc76d6091885964b53cce8108ad5615666ef26da1316e7027d`.

## First measurement

DMD 2.111.0 and LDC 1.42.0 both passed the executable's checks. On the 2048 × 1024 Earth RGB fixture, the histogram processed 2,097,152 samples in 220 ms. Gradient and local statistics for the first 512 × 384 request took 204 ms. Gradient and OKLab for the second request took 111 ms with four gradient cache hits. The two timings cover different feature combinations.

| Measurement | Observed |
|---|---:|
| Analysis tile buffers, peak per request | 4,293,760 bytes |
| Analysis tile buffer allocations across both requests | 9 |
| Histogram buffer | 1 allocation, 1,048,576 bytes |
| Cache payload allocations | 12 |
| Cache index growth requests | 3 |
| Accounted live cache bytes after both requests | 14,681,954 bytes |
| Peak accounted live cache bytes | 15,730,530 bytes |
| Process peak RSS | 38,308 KiB |

The explicit counters cover named engine allocations and live entry bytes. Process RSS also includes GC, allocator capacity, benchmark input and runtime. A repeated gradient request served entirely from cache creates no tile work buffers or cache payloads. The separate procedural-source check holds request size and tile size constant while changing source extent from 17 × 17 to 1,000,017 × 1,000,017. Tile buffer bytes are identical.

Actual Dunia Vision Consumer validation is part of #187 and follows the final merge of the implementation into `develop`. The experiment is sequential and uses in-process exact tile reuse. Concurrent single-flight and cancellation belong to the interactivity work in #184.

## Library regression tests

Both root unit suites pass with DMD 2.111.0 and explicit template instantiation. In this environment, direct `dub test` without the debug build and `-allinst` combination encountered unresolved color-d template symbols during linking.

```sh
DFLAGS=-allinst dub test --compiler=dmd --config=default --build=debug
DFLAGS=-allinst dub test --compiler=dmd --config=no-io --build=debug
```

The scoped reader and sink are checked with DMD's DIP1000 preview in no-io. Enabling DIP1000 globally in the default build also applies it to transport-d 0.2.1, which currently fails that check.

## #183 radiometry and quality

The [slice contract](../../docs/m6-feature-region-slice.md) specifies the operator parameters, mask handling, memory and output semantics. The harness asserts analytical impulse and constant-field responses, NoData propagation and exact agreement across tile decompositions. The exposure test maps black and white to the fitted reference endpoints. CLAHE has a hand-counted clipped histogram, a two-cell interpolation check and exact region equivalence including masked and partial cells. The photo check independently verifies clipped luminance normalization.

One LDC 1.42.0 Release run on the same 2048×1024 RGB source gave the following times for a 512×384 region and 256-pixel processing tiles. Exposure profile fitting scans the full scene. Exposure application follows that fit. CLAHE in this sequence can reuse the linear luminance tiles produced during exposure application.

| Operation | ms |
|---|---:|
| Local normalization | 89 |
| Gaussian / box / median | 26 / 27 / 34 |
| Bilateral / diffusion | 58 / 36 |
| Laplace / sharpness | 23 / 21 |
| Clipping / underexposure | 16 / 17 |
| Noise / dynamic range | 52 / 91 |
| Exposure profile / application | 161 / 18 |
| CLAHE | 25 |

The maximum counted core work buffer size was 4,293,760 bytes. Peak RSS for the entire extended benchmark process was 74,680 KiB, which includes the RGB fixture, multiple sequential workloads and GC/allocator retention. Each local operator uses three reusable heap buffers on the first miss. Exposure application and CLAHE each add one reusable output buffer. CLAHE's fixed cell scratch is accounted for in the slice contract.

## #184 overview and interactive replay

The same reference commands exercise an odd-sized scalar overview against hand-calculated bilinear center samples and NoData, then compare full-grid and non-origin reads exactly at valid positions. Queue checks cover visible priority, exact-key sharing, cancellation before and during a read, a late subscriber, failure followed by retry and bounded subscriber capacity. See the [execution contract](../../docs/m6-feature-region-slice.md) for the one-event-loop model and the separation of tile and cache budgets.

The LDC 1.42.0 Release scene replay selected a 1024×512 nearest overview of the 2048×1024 Earth image, then requested overlapping pan, zoom and fine-grid tiles. Four deliveries came from three jobs in 38 ms. Core tile buffers peaked at 4,227,200 bytes and accounted retained cache at 6,292,149 bytes. Dispatch uses one extra tile of at most 2 MiB. Peak RSS for the entire benchmark process, including the preceding radiometry runs, was 76,352 KiB.

## #185–#187 structure, components and evidence

DMD 2.111.0 passed the reference checks in default and no-io, with DIP1000 enabled in no-io. LDC 1.42.0 Release passed the same checks. Structural tests compare the full image with a shifted region and different tile layout, including analytical line and binary texture cases. Connected-component tests cover complete weak paths through multiple blocks, filtering disconnected weak components, deterministic IDs, shape and color statistics, adjacency, the analytic Canny step, straight segments and budget exhaustion. Spectral checks use independent synthetic band values for expected differences, ratios and signed vegetation and water responses. These cases include NoData, zero denominators and swapped roles.

The LDC Release benchmark reused the manifest-pinned 2048×1024 input and sampled a 128×96 region with 64×64 feature tiles. Selected timings follow.

| Workload | Observed |
|---|---:|
| Entropy / GLCM | 14 / 17 ms |
| Gabor bank / ridge / line response | 58 / 9 / 23 ms |
| Path opening / closing | 47 / 44 ms |
| Square opening / closing profiles | 341 / 316 ms |
| Canny and line tracing | 25 ms |
| Color regions and region quality | 85 ms |
| Channel difference | 949 µs |

The largest core tile buffers in the structure benchmark totaled 315,904 bytes, plus fixed local scratch. The Canny and region benchmarks used a label budget of 4,096 and 518,464 bytes of component scratch; the caller-owned label store is separate. The full benchmark process peaked at 78,524 KiB RSS, including input, caches and preceding benchmark workloads. The real-scene channel benchmark uses RGB code values. Calibrated spectral behavior is covered by the separate reflectance fixture.
