# M3.2.7 — Reproducible XPS ROI qualification

**Status:** Benchmark harness under qualification. No XPS benchmark evidence
has been collected by ChatGPT. All code and document edits stay within
`imagery-d`.

## Context and baseline

This extends [M3.2.6](../../docs/research/m3-2-validated-immutable-roi-results.md)
without modifying the previously accepted M1.5/M3.2 experimental contracts.
The primary goal is to validate an **ROI control-plane** improvement, not
image processing, decoder performance or a new public image owner.

The source-level hypothesis is that deriving an ROI from a semantically
validated image with truly immutable channel metadata avoids another
O(channel count) cross-descriptor identity scan. The old composite view
remains the conservative alternative for caller-mutable `const` data.

## Benchmark paths

All paths receive the **same** resident `raster-d` source, the same
`Region2D` windows, and immutable descriptor metadata. All return a
matched ROI-shape/metadata checksum.

1. `raster_only`: `RasterView!float.tryRoi` (lower-bound control, no imagery semantic validation).
2. `revalidated_image`: original M3.2.3 `BorrowedSemanticImage.tryRoi` (rechecks channel IDs).
3. `verified_immutable_image`: M3.2.6 `ValidatedImmutableImage.tryRoi` (one-time validated immutable metadata).

The three noinline wrappers are in
`source/m3_2_roi_xps/benchmark.d`. They are distinct call boundaries
for inspection; checksums and varied ROI offsets help prevent dead-code
elimination. The benchmark deliberately does **not** time image
materialization, metadata snapshot creation or arithmetic mapping.
The `raster_only` control is *not* semantically equivalent to imagery's
validation and should not be compared as if it were.

## Local XPS procedure

From `libs/imagery-d` on the XPS:

```bash
git fetch origin
git switch research/m3-2-xps-roi-qualification
git pull --ff-only origin research/m3-2-xps-roi-qualification

# No changes are made to raster-d by this script.
COMPILER=ldc2 REPEATS=5 ROUNDS=15 ITERATIONS=50000 WARMUPS=3 \
  bash experiments/m3_2_validated_roi/tools/qualify_xps_roi.sh
```

Optional CPU pinning (verify the CPU is valid and appropriate first):

```bash
CPU=2 COMPILER=ldc2 \
  bash experiments/m3_2_validated_roi/tools/qualify_xps_roi.sh
```

Do not change CPU governors, disable turbo, or modify system
configuration merely to run these exploratory tests. Record actual
frequency/governor conditions and use controlled repetitions. A
comparison between `ldc2` and `dmd` can be run separately if useful,
but keep toolchain/corpus/build identity in each record.

The runner only writes:
- the `imagery-d` experiment build artifacts;
- a timestamped `experiments/m3_2_validated_roi/evidence/local/xps-* `
  evidence directory containing a manifest, positive/negative compiler
  gate log, binary SHA-256, per-process logs, raw CSV, median/spread
  summary, and code-generation artifacts.

It does not run `git checkout`, reset, commit or write files in the
sibling `raster-d` or other repositories. The exact `raster-d` HEAD
and the v0.2.0 tag commit are recorded. If these differ, the run is
**exploratory only**, not pinned v0.2.0 evidence.

Use the result:
`roi-summary.csv` (median/p10/p90/min/max/MAD ns/call),
`roi-summary.json`, `roi-raw.csv` (all paired rounds) and
`relevant-symbols.txt` + compressed disassembly. The latter should
be checked to confirm the noinline wrapper calls and actual semantic
validation loops are present, not optimized away.

**Do not commit raw performance evidence blindly.** Review and retain a
small evidence summary in `docs/research/`; large raw artifacts should
be archived separately with checksums under workspace evidence rules.

## Correctness and evidence rules

- Existing DMD/LDC debug and release semantic/lifetime tests run before
  collecting XPS samples.
- Benchmark itself checks checksum equality for every paired cycle;
  independent semantic output oracle is already covered in M3.2.6.
- Each process has warm-ups and balanced/reversed measurement order.
  `raster_only` is a same-run control; metadata validation differs by design.
- The harness measures elapsed monotonic time via D `StopWatch`.
  Its numbers are not CPU-time or full image-operation latency.
- Compiler/codegen inspection is required. The presence of separate
  callable wrappers alone does not prove the compiler preserved exactly
  the desired checks, nor does a checksum alone prevent all hoisting.
- Performance acceptance needs independent XPS measurement distributions
  and ultimately a consumer-representative image operation. This harness
  is not a production-performance verdict.

Tracking: [issue #36](https://github.com/alex-1974/imagery-d/issues/36).
