# M3.2.14 — Prepared ROI reuse and consumer amortization

**Status:** Experimental benchmark and qualification gate. Four-compiler hosted
correctness qualification is required; no local XPS timing or break-even verdict
exists yet. No new production/public API is admitted.

**Tracking:** [Issue #50](https://github.com/alex-1974/imagery-d/issues/50) |
[Stacked PR #51](https://github.com/alex-1974/imagery-d/pull/51) |
[Prerequisite PR #49](https://github.com/alex-1974/imagery-d/pull/49).

## Research question

For a consumer mapping several ROIs of the same source with the same
semantically selected bands, when does verifying metadata and binding once
outweigh the full setup cost? This is explicitly **not** the M3.2.13
checksum-only preparation cost in disguise: each timed operation maps real
pixels through the same checked executor and produces an observed pixel
sample, with full three-channel pixel checks outside the timed path.

## Cases, semantics, and asymmetry

- **Reuse:** 1, 2, 4, 8, 16, 32 ROIs per batch.
- **Channels:** 3, 17, 64, 256; ROI sides 8, 32; source layout planar
  with validity mask and interleaved without mask. The 96×96 source is
  initialized before timing.
- **Inputs:** eight deterministic metadata identities with varying scale
  and offset; three distinct selected-band permutations. Both methods
  receive identical metadata, calibration, ROI sequence and destination
  shape for each paired round.
- **`immutable` policy:** both methods receive already immutable identity
  and intrinsic descriptor arrays, constructed outside the timed batch.
  The one-shot side borrows once and revalidates semantic IDs each map.
  The Prepared side builds a verified image and binding once, then maps
  repeatedly. Both pay their one-time factory setup inside the batch.
- **`mutable_snapshot` policy:** one-shot borrows caller-mutable arrays,
  assuming they are not mutated during that batch, and revalidates on
  every map. Prepared must first `.idup` **both** arrays to immutable
  backing, then verify, bind and reuse. **This is a deliberate difference
  in ownership and safety guarantees.** Do not label any speed advantage
  or deficit a same-contract implementation comparison.
- **Measured per batch:** setup_ns (construction+binding), map_ns
  (all mappings), total_ns (wall time including both phases and timer
  overhead). The three elapsed values are separately observed rather
  than assuming total = setup + map exactly.
- **Observed correctness:** a sample is read from every mapped ROI and
  accumulated. A separate stored-value×calibration oracle predicts the
  exact observed checksum; after timing, the last ROI's complete
  three-plane output is compared pixel-by-pixel with an independent
  expected calculation. The M3.2.13 observed 384-mapping smoke provides
  additional all-permutation calibration coverage.

Each paired round rotates one-shot and Prepared execution slots; the
workload varies metadata sets, binding permutations and the four ROI
origins. Warmups run both modes but are not recorded. Per-block results
are *not* independent observations of every internal mapping operation.

## Evidence tool and strict acceptance criteria

The XPS runner records exact imagery and raster commits, current
worktrees, toolchain versions, CPU/governor/memory context, fixed binary
SHA, available disassembly/symbols, all inherited M3.2.6–13 contract
gates, the full observed consumer smoke, and multiple independent
process logs. It leaves sibling repositories untouched.

`analyze_reuse_amortization.py` rejects:

- missing/extra processes, incomplete or duplicate cases;
- imbalanced or incorrectly rotated method slots;
- missing/reordered channel, ROI, policy, or reuse dimensions;
- negative setup time, or nonpositive pixel-mapping/whole-batch time;
  a 0 ns measured setup is allowed because the hosted stopwatch can
  quantize sub-resolution setup intervals to zero; zero must **not**
  be treated as a genuine cost-free operation;
- self-consistent but wrong checksum/expected values using a **separate
  deterministic pixel-oracle implementation**;
- missing C/D program completion markers.

The analyser emits raw and per-path setup/map/total medians plus
same-round paired total deltas. It **never** declares an automatic
performance winner or universal ROI break-even. Independently inspect
process/thermal/frequency drift, GC/allocation effects, codegen, and
whether a consumer realistically reuses immutable metadata.

### Hosted correctness smoke

```bash
dub run --root=experiments/m3_2_validated_roi --compiler=ldc2 \
  --config=default --build=release --force -- \
  --reuse-consumer-smoke 2 1
```

Hosted smoke covers 3/17 channels, 8×8 ROIs, two layouts/policies,
six reuse counts, two rounds and both modes: **192 timed rows**.
It is for functional correctness only.

### Dell XPS independent performance run

From `libs/imagery-d` on the research branch:

```bash
git fetch origin
git status --short --branch
git switch research/m3-2-14-roi-amortization
git pull --ff-only origin research/m3-2-14-roi-amortization

COMPILER=ldc2 REPEATS=5 ROUNDS=8 WARMUPS=2 SMOKE=0 \
  bash experiments/m3_2_validated_roi/tools/qualify_reuse_xps.sh
```

Five processes × 4 channels × 2 sides × 2 layouts × 2 policies ×
6 reuse counts × 8 timed rounds × 2 modes = **15,360 timed rows**,
representing **7,680 paired comparisons**, with source and destination
storage preallocated outside the timed batch. Each row is a timed
*batch* with `reuse` complete ROI mappings. The runner uses
the current local `raster-d` checkout as **read-only** and reports
whether it exactly matches `v0.2.0`. A mismatch means local-state
research, not release-tag performance.

For close effects, rerun on a quiet system with documented CPU
affinity, stable frequency, temperature and GC pressure. A favorable
single run or a small unsigned paired delta is **not** a release claim.
Record the actual distribution and confidence before admitting a
consumer threshold.

## Promotion gate

Retain M3.2.13 source-level and binary optimization caveats. A
release-grade amortization result requires a full XPS archive,
independent interpretation of source+binary and paired process-level
results, validation under the actual dependency/version and an
explicit reuse/ownership use case. Until then PR #51 remains stacked
research and does not merge to `develop`. No sibling repository
may be changed by this work.
