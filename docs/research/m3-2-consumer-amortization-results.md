# M3.2.8 — Semantic image consumer and metadata preparation results

**Status:** Synthetic image-consumer correctness qualified; XPS performance
and metadata break-even **PENDING**. This is not a production API decision.

**Date:** 2026-10-11  
**Repository:** `alex-1974/imagery-d`  
**Research branch:** `research/m3-2-consumer-amortization`  
**Issue:** [#38](https://github.com/alex-1974/imagery-d/issues/38)  
**Stacked PR:** [#39](https://github.com/alex-1974/imagery-d/pull/39)
(base: `research/m3-2-xps-roi-qualification`)

## 1. Baseline and question

[M3.2.7 XPS evidence](m3-2-xps-roi-observed-results.md) showed
that immutable validated-once ROI creation avoids a repeated
O(channelCount) identity scan. At 1024 channels, the **ROI control-plane
microbenchmark** on the supplied local XPS configuration observed
approximately 605.10 ns per conservative ROI versus 21.22 ns per
validated immutable ROI, a paired median ratio of 28.64x.

The missing engineering question is: **Does this isolated benefit
matter when the consumer actually maps pixels, and when immutable
metadata must first be prepared?**

## 2. Consumer operation

The experiment adds a self-contained synthetic common-grid image consumer
on top of the existing M1.5, M3.2.2, M3.2.3 and M3.2.6 contracts:

- input `RasterLease!float`, either planar with optional one-plane
  validity or interleaved without validity;
- metadata semantic IDs and calibrations for 3, 17, 64 or 256 channels;
- ROI output 8×8, 32×32 or 64×64 pixels, with several coordinate offsets;
- explicit selection of the **last three** image channels, with the
  existing M3.2.2 operation applying
  `physical = stored*0.5 - 4`;
- independently retained destination `RasterLease!float`;
- exact independent per-pixel oracle before timing, including invalid
  mask policy and source layout equivalence;
- identical existing `mapComponentsInto` kernel called on both
  conservative and validated-immutable ROIs.

The **only difference** between the two measured mapping paths is
the semantic ROI derivation. Importantly, the existing mapping kernel
still rechecks the channel IDs on each invocation. No new short-circuit
pixel kernel was introduced merely to improve a benchmark score.

Each timed pair verifies identical output checksums. Pixel data are
synthetic resident raster data, not file decodes; this is an image-domain
mapping consumer, not an end-to-end image IO pipeline.

## 3. Preparation costs independently exposed

The program emits three preparations for each channel count:

| Mode | Allocation/copy in imagery metadata layer |
| --- | --- |
| `caller_borrow_validate` | None; M1 view + conservative compound borrow over caller-owned descriptors |
| `already_immutable_validate` | None; immutable-only factory checks identities and grid |
| `snapshot_and_validate` | Two `.idup` descriptor-array snapshots, then immutable-only factory |

The snapshot uses GC-backed allocations and copies D descriptor structs;
it does not deep-copy the data referenced by source/quantity strings.

All construction takes place **outside** the ROI mapping timing loops.
No metadata allocator is admitted by this experiment.

Any future break-even calculation must compare preparation cost
differences with **consumer operation** savings, not with the M3.2.7
ROI-only timing. If mapping savings are zero/negative or statistically
unstable, no positive preparation break-even exists.

## 4. Early compiler validation

The first complete targeted [GitHub run 38159384893](https://github.com/alex-1974/imagery-d/actions/runs/38159384893)
passed on **DMD 2.111.0, DMD 2.113.0, LDC 1.41.0 and LDC 1.43.0**,
using pinned `raster-d v0.2.0`. Its jobs retained the original
M3.2.6 debug/release positives and six negative DIP1000/type/capability
gates, and passed the new complete pixel-mapping smoke in release mode.

The later [full harness run 38159493658](https://github.com/alex-1974/imagery-d/actions/runs/38159493658)
also passed **all four compiler jobs**. Its LDC 1.43.0 job additionally
ran `qualify_consumer_xps.sh` end to end in smoke mode, recording an
environment manifest, binary hash, compiler preflight, paired raw
mapping/setup rows, summary CSV/JSON, and codegen evidence. The Python
analyzer accepted **48 complete paired mapping rounds** from one small
CI process. The short 2-iteration hosted samples are **functional harness
evidence only**, not consumer performance results.

Two prior failed prototype iterations are deliberately preserved in
the research history as useful D engineering findings:

1. Calling the two existing `mapInto` methods on a locally borrowed
   `scope` ROI exposed missing `scope` annotations on their implicit
   `this` parameters. Both **research-only** method declarations
   now add `scope` without introducing `@system`/`@trusted` bypasses.
   The existing escape-negative gates still pass.
2. In D, uninitialized `double` defaults to `NaN`. A benchmark
   accumulator accidentally inherited that value, producing matching
   `nan` checksums despite successful pixel-oracle tests. It now
   explicitly initializes to `0.0`, and wrapper errors return a
   separate bool rather than a NaN sentinel.

No change was made to released `raster-d` or any other repository.

## 5. XPS performance status

The 4-compiler result is a **correctness qualification**. The
optimized XPS consumer timings, preparation timing distributions and
amortization threshold have **not yet been collected**.

A separate non-gating runner is provided:

```bash
cd ~/Programmiersprachen/dlang/d-geospatial-workspace/libs/imagery-d
git fetch origin
git switch research/m3-2-consumer-amortization
git pull --ff-only origin research/m3-2-consumer-amortization
COMPILER=ldc2 REPEATS=5 ROUNDS=9 ITERATIONS=12 WARMUPS=2 \
    bash experiments/m3_2_validated_roi/tools/qualify_consumer_xps.sh
```

The script records local raster/imagery status, compiler, CPU, binary
hash, raw paired per-process timings, setup timings, medians and MAD,
symbols and disassembly. It **does not modify** any other workspace
repository. A non-v0.2.0 sibling raster checkout is marked as
local-state exploratory evidence; strict release pinning remains open.

## 6. Decision

**Proven:** separate image-domain mapping variants can produce the same
independent oracle values without sacrificing borrowed-view lifetime
checks. The full-mapping benchmark is now executable.

**Not proven:** an end-to-end speedup, consumer-level release performance
budget, amortization point for immutable snapshots, numerical accuracy
on arbitrary floating calibration, or the need for a new public image
owner. The M1/M2 ADRs and public API gate remain unchanged.

**Next acceptance evidence:** successful complete XPS harness run,
inspect distributions, compare preparation vs per-ROI savings and
codegen, and only then decide whether the validated-immutable ROI
capability is worth promoting.
