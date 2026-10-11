# M3.2.7 — XPS ROI qualification harness: CI evidence

**Status:** XPS benchmark preparation and toolchain/smoke gates **PASS**;
**Dell XPS hardware benchmark pending**. This is not a production
performance or API admission result.

**Date:** 2026-10-11  
**Repository:** `alex-1974/imagery-d`  
**Research branch:** `research/m3-2-xps-roi-qualification`  
**Validated implementation/CI commit:** `eb617b9e815b954cb4c4a8960ccc1fabad0a150f`  
**GitHub Actions run:** [#38136645338](https://github.com/alex-1974/imagery-d/actions/runs/38136645338)  
**Dependency for CI:** released `raster-d` tag `v0.2.0`  
**CI platform:** GitHub-hosted Ubuntu 24.04 x86-64; **not XPS**

## Completed verification

| Compiler | Existing M3.2.6 positive debug/release + six negatives | ROI three-path checksum smoke | Outcome |
| --- | --- | --- | --- |
| DMD 2.111.0 | PASS | PASS | PASS |
| DMD 2.113.0 | PASS | PASS | PASS |
| LDC 1.41.0 | PASS | PASS | PASS |
| LDC 1.43.0 | PASS | PASS | PASS |

The LDC 1.43.0 CI job additionally executed the **complete XPS
script** in miniature with `REPEATS=1 ROUNDS=2 ITERATIONS=128 WARMUPS=1`.
It verified:

- the local shell script and Python analyzer can be parsed;
- executable build, existing compiler safety preflight, one-process
  measurement and raw CSV generation complete successfully;
- parsed rows form 10 paired rounds across channel counts
  3, 17, 64, 256 and 1024; each pair contains exactly the three
  modes with equal checksums and nonzero elapsed timings;
- median/spread CSV and JSON output are produced;
- environment manifest and executable/disassembly/symbol capture
  are invoked without touching `raster-d`.

The short hosted CI sample is a **harness functional smoke**, not
timing evidence: 128 iterations and two cycles are insufficient
for a performance decision.

## Bench methodology

- `raster_only`: direct `RasterView.tryRoi`, a lower-bound/drift
  control that intentionally has no imagery semantic checks.
- `revalidated_image`: original `BorrowedSemanticImage.tryRoi`,
  which rechecks per-channel semantic IDs.
- `verified_immutable_image`: tested immutable-metadata view,
  whose ROI does not repeat that ID scan.
- No allocations or metadata copies in the timed ROI loops.
  Input construction, mutable-to-immutable snapshots, and raster
  import are outside the timed region.
- Three explicitly **noninline** benchmark wrappers, dynamic
  window selection, matched visible checksum, balanced/reversed order
  across six permutations, warm-up and independent process repeats.
- Standard-library-only Python analysis validates complete paired
  cycles and reports median, p10/p90, min/max and MAD as **ns per
  call**, plus an exploratory per-cycle ratio.

The wrapper observes metadata identity/count and ROI success. The
source-level ROI validation mechanisms differ by design. This is a
**microbenchmark of control-plane cost**, not an end-to-end image
processing benchmark or a general numerical correctness oracle.

## Open XPS gate

Actual local XPS results are **not yet collected or checked**.
The operator should run from `libs/imagery-d`:

```bash
git fetch origin
git switch research/m3-2-xps-roi-qualification
git pull --ff-only origin research/m3-2-xps-roi-qualification
COMPILER=ldc2 REPEATS=5 ROUNDS=15 ITERATIONS=50000 WARMUPS=3 \
  bash experiments/m3_2_validated_roi/tools/qualify_xps_roi.sh
```

The local runner prints its evidence path and writes
`environment.txt`, `binary.sha256`,
`timed-binary.sha256`, `roi-raw.csv`,
`roi-summary.csv`, `roi-summary.json`,
`correctness.log`, `symbols.txt`,
`relevant-symbols.txt` and compressed disassembly when tools
are available. The run records whether the sibling `raster-d`
is at the v0.2.0 tag and **does not checkout or edit** any other
repository. A different raster commit is marked exploratory.

Before a production decision:
1. Inspect the LDC disassembly to establish that noinline
   wrappers and ROI validation loops are truly present and that
   hot code has not been folded/hoisted unexpectedly.
2. Review XPS benchmark distributions, CPU scheduling/frequency
   metadata, baseline binary and raster-d commit.
3. Establish a consumer-representative image processing workload
   and a preparation/amortization comparison when the immutable
   metadata source is not already available.
4. Re-run the initial M1.5 and M3.2.2–M3.2.6 gates on the actual
   promotion candidate; do not merge stacked research wholesale.

**Decision:** benchmark harness is qualified to collect local
evidence; the fast immutable ROI public API and any performance
claim are **not yet admitted**.

Tracking: [Issue #36](https://github.com/alex-1974/imagery-d/issues/36),
[PR #37](https://github.com/alex-1974/imagery-d/pull/37).
