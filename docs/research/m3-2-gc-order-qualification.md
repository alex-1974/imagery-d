# M3.2.15 — Counterbalanced case order and GC/page-fault tail qualification

**Status:** Experimental instrumentation and CI qualification only. **No new
XPS timing or GC-causality conclusion**. This stage is stacked on
[M3.2.14 draft PR #51](https://github.com/alex-1974/imagery-d/pull/51)
as [draft PR #53](https://github.com/alex-1974/imagery-d/pull/53),
tracked by [issue #52](https://github.com/alex-1974/imagery-d/issues/52).

## Motivation from immutable M3.2.14 XPS archive

[Independent XPS audit](m3-2-roi-amortization-xps-results.md)
validates 15,360 real mapped-image timings. Five independent processes
all showed anomalous **0.5674–0.8351 ms** snapshot setup at exactly
256 channels, 32×32 planar+validity, caller-mutable snapshot, reuse=1,
recorded round=2 and Prepared slot=1. The baseline executed its outer
(channel, ROI, layout, policy, reuse) cases in a fixed order. The result
suggests allocator-state or order sensitivity. It does **not** establish
an observed GC collection; neither GC cycle counters nor page-fault
deltas were recorded.

The original benchmark and archive are immutable research evidence.
This stage is a different, more heavily instrumented follow-up, not a
retroactive correction or replacement of the M3.2.14 benchmark.

## Independent process counterbalancing

The new `--reuse-gc-order-benchmark ROUNDS WARMUPS PROCESS_SEED` command
uses the same underlying source image, pixel executor, calibrated metadata,
three component permutations, six ROI reuse counts and full 3-plane final
pixel oracle as M3.2.14. Each paired round still reverses method order,
and both methods receive identical inputs.

**Only outer case scheduling is different:**

- Channels are rotated by `PROCESS_SEED` across 3, 17, 64, 256;
- ROI sizes are rotated by `PROCESS_SEED / 2` across 8 and 32;
- planar and interleaved layouts are rotated by `PROCESS_SEED`;
- all 12 policy/reuse combinations are permuted by
  `(case_slot * 5 + PROCESS_SEED * 7) % 12`, with multiplier 5 coprime to 12.

The runner passes unique process indices 0…REPEATS−1 as seeds; the
benchmark emits both the seed and an **outer case rank** on every row.
The strict Python analyzer independently regenerates the **exact
expected order** and rejects rows that are missing, reordered,
duplicated, forged, incorrectly timed or associated with the wrong
process. Two process seeds are the absolute minimum; five processes
are the reference XPS protocol.

This is deterministic **counterbalancing**, not a statistically
independent random draw and not an exhaustive Latin-square design.
Rotations may still correlate with hardware/cache/allocator state.

## Runtime observation

For *each measured path*, outside the three StopWatch phases:

- `GC.stats().allocatedInCurrentThread`: counter delta in GC-allocated
  bytes on the executing thread;
- `GC.profileStats().numCollections`: delta in completed GC cycles;
- `GC.profileStats().totalPauseTime`: reported GC pause-time delta;
- Linux `getrusage(RUSAGE_SELF)`: minor and major process page faults.

The snapshots are taken immediately before and after the complete
measured operation and **before its output pixel oracle**. The program
serializes the two paired records only **after both methods and their
oracles** to avoid printing between matched measured operations.
Nevertheless, GC/rusage calls, oracle traversal and emission may
change the state of subsequent batches; any drift relative to M3.2.14
cannot be attributed only to outer case order. GC cycle counters and
pause times depend on the runtime collector/profiling implementation.
A zero means no event was reported, not necessarily that there was no
allocator/OS overhead. Linux page fault counters are process-wide, not
per-allocator or exact causality measures.

The XPS runner additionally captures memory/swap, selected
`/proc/vmstat` counters and current per-CPU frequency **before and after**
each separate process, plus source/dependency SHAs, dirty worktree
states, compiler/DUB versions, CPU governor and affinity, optimized
binary SHA/symbol/disassembly and inherited safety/lifetime test logs.
It does not modify sibling repositories. For `raster-d` not at exact
`v0.2.0`, the data are labelled **local dependency state**.

The follow-up runner is Linux-specific (research only). This choice
does not introduce a platform requirement into `imagery-d`.

## Evidence and execution

From `libs/imagery-d`, after verifying local worktrees:

```bash
git fetch origin
git status --short --branch
git switch research/m3-2-15-gc-order-qualification
git pull --ff-only origin research/m3-2-15-gc-order-qualification

COMPILER=ldc2 REPEATS=5 ROUNDS=8 WARMUPS=2 SMOKE=0 \
  bash experiments/m3_2_validated_roi/tools/qualify_gc_order_xps.sh
```

For a bounded correctness-only smoke (two different process seeds):

```bash
COMPILER=ldc2 REPEATS=2 ROUNDS=2 WARMUPS=1 SMOKE=1 \
  bash experiments/m3_2_validated_roi/tools/qualify_gc_order_xps.sh
```

Complete XPS expectation:
5 processes × 4 channels × 2 sides × 2 layouts ×
2 policies × 6 reuse counts × 8 rounds × 2 alternatives =
**15,360 timed rows and 7,680 matched pairs**. Every result includes
`case_rank`, `order_seed`, timed setup/mapping/total and GC/rusage
deltas. Samples with 0 ns setup are valid sub-resolution observations;
negative setup and nonpositive map/total are rejected. Intermediate
ROI samples are independently checksummed; the final ROI's full
3-channel output is independently validated.

The script emits `gc-order-raw.csv`, `gc-order-summary.csv`,
`gc-order-summary.json` and raw logs, including every setup tail
over 50 μs without trimming.

## Admission gate and planned analysis

Inspect whether future >50 μs events follow **case identity** or
**sequence rank / process order** (or both), and whether their measured
windows report GC collections, pauses or major/minor faults. Compare
paired outcomes by channel/ROI/layout/policy, per-process medians
and long tails; check memory pressure and OS frequency state.

Do not infer GC causality merely from temporal association; even
a perfect correlation in this protocol needs an isolating experiment.
The instrumented and uninstrumented benchmark latencies differ in
measurement environment, so **do not compare their absolute median
nanoseconds as an A/B performance result**. No universal ROI
break-even or public imagery API follows from this stage.

All existing PRs remain stacked, evidence retained, and
`develop` untouched.
