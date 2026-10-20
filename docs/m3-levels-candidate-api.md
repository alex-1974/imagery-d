# M3 Levels production candidate — not yet admitted to develop

This document qualifies one public-shaped **draft** Levels operation on a
separate unmerged branch. Its selection priority is recorded in ADR 0004 on
Draft PR #96. No API freeze, release, or published consumer package exists.

Module: `imagery.presentation.levels`, re-exported by `imagery`.
Input: borrowed `RasterView!ubyte`, `!ushort`, or `!float`, a
checked nonempty `Region2D`, one Boolean choice per source channel,
and finite Levels settings. Optional same-image-size single-plane
`RasterView!ubyte` **editing selection** uses strength byte/255;
it is not a validity or alpha mask.

Result: freshly allocated `RasterLease!float`, ROI-sized, same channel
count, interleaved. Integral input normalized by 255 or 65535; float
preserves its numeric input domain. NaN and +/- infinity float values
pass through. Unselected channels pass through numerically (normalized
for integer inputs). The consumer must choose the colour domain and
alpha channel selection; no ICC/sRGB/premultiplication conversion.

The mandatory `maxResultBytes` covers exactly the new float pixel
payload, `roi.width * roi.height * channels * float.sizeof`.
Zero or one byte short rejects a nonempty operation, equality permits it.
Checked products and signed stride representation precede allocation.
The previous result owner stays untouched on **returned failures**;
actual exception/OOM handling is not promised as `nothrow`.
The cap excludes existing results, source, mask, raster metadata,
allocator/GC overhead, and PPM I/O — **not a peak RSS cap**.

`Levels.init` is invalid (NaN field defaults); `LevelsError.init` is
`notAttempted` (also **not success**). The caller must check the returned
status for the **explicit** `none` return. Direct destination
writing is private until physical-alias and rollback semantics warrant it.

Research evidence is preserved on PR #85/#95 and is not imported into
the consumer archive. Independent DUB, Ddoc, compiler and end-to-end
performance gates must pass before any production admission decision.


## Bounded LDC Release end-to-end smoke (GitHub-hosted, not XPS)

Pinned `raster-d` and LDC 1.43.0 Release were used in the actual P6
consumer. The deterministic identity fixture includes whole P6 file read,
import into real raster leases, Levels, quantization and file output.
One warmup and three measured runs were taken per shape. Both push and PR
[workflow #39324653294](https://github.com/alex-1974/imagery-d/actions/runs/39324653294)
and [push #39324645393](https://github.com/alex-1974/imagery-d/actions/runs/39324645393)
produced checksummed identity output. Hosted-runner medians differed
materially, so these are *smoke receipts only*, **not** a stable benchmark
or a speedup/performance acceptance verdict.

| GitHub Actions run | 512² median | 1024² median |
|---|---:|---:|
| PR #39324653294 | 18.615 ms | 67.824 ms |
| Push #39324645393 | 34.415 ms | 129.081 ms |

Absolute throughput claims and C++ parity remain unqualified; no thermally
stressful XPS measurement was run.

## API-audit: finite threshold subtraction overflow

A finite `inputBlack < inputWhite` pair need not have a finite
`inputWhite - inputBlack` in binary64. The earlier one-pass normalization
would treat `Levels(-double.max, double.max, 1, 0, 1)` and a finite zero
sample as approximately **0** instead of the correct **0.5**. The production
candidate now detects such finite-but-overflowing spans, uses an equivalent
half-scaled ratio, clamps exact boundaries without division, and keeps the
original finite parameter domain. The independent ordinary DUB consumer
regresses the symmetric interval against 0.5 and sqrt(0.5), both gamma
extremes, all-channel passthrough, float NaN/infinities and preservation of
a previously published owner on returned failures. This is not a promise
of sub-ULP accuracy or fully validated HDR/colour semantics.


## API-audit: input/output owner overlap

The scalar output always uses a newly adopted allocation. The destination
lease may therefore also be the source's retained owner **for this operation**:
input reads and the private result computation finish before the new lease
replaces the prior owner. The independent DUB consumer checks this exact
self-owner scenario with an independently retained copy of the old backing,
mutates that old backing after successful replacement and confirms the new
result is unchanged. A rejected budget on the same owner preserves its
latest output. This is *not* a general permission for unsafe concurrent
mutation, arbitrary borrowed-view escape or direct Into-style destination
aliasing. `raster-d` leases use non-atomic reference accounting; callers
must synchronize lifetime/mutation separately.


## Draft D safety boundary

Both unmasked and masked `tryLevelsOwned` are explicitly `@safe`. The
implementation contains one private, audited `@trusted` helper for
`malloc`-backed memory creation and adoption into the existing
`raster-d` ownership token. The returned raster is always owned by
`RasterLease!float`; no raw pointer escapes to the public API. A genuine
`@safe` DUB consumer compile-contract test verifies both overloads under
DMD/LDC and DIP1000. The operation may still allocate GC descriptor
metadata and can throw or raise fatal OOM; it is **not** `@nogc`,
`nothrow`, thread-safe by itself, or a peak-process-memory limiter.
Success and returned-error publication behavior remain as documented.
See the dated audit for the trust-boundary proof and limits.
