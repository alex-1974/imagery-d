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
`none`. The caller must check the returned status. Direct destination
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
