# M3.2.16 — bounded GC intervention on real mutable-to-Prepared ROI mapping

**Status:** research-only intervention harness; **not a GC strategy recommendation,
public API or production change**. Source + protocol are preserved on
[issue #54](https://github.com/alex-1974/imagery-d/issues/54) and
[stacked draft PR #55](https://github.com/alex-1974/imagery-d/pull/55)
above [PR #53](https://github.com/alex-1974/imagery-d/pull/53).

## Evidence inherited, and question

[M3.2.15 independent XPS audit](m3-2-gc-order-xps-results.md):
five full consumer snapshot preparations were 587–831 µs and overlapped
five independently reported GC collections and 580–814 µs GC pause;
each occurred at 256 channels. A 78.1 µs outlier had no reported
collection. The previous probe varied all outer cases, so GC-trigger
mechanism remains unresolved.

**Question:** with the *same exact semantic mapping workload* in separate
processes, do measured stalls follow automatic collection activity, does
moving a collection outside the measured window remove the in-window
pause, and what latency/heap cost does bounded deferral impose?

## Three independent interventions

Every invocation uses **exactly one** selected policy, isolated in its own
fresh OS process. The runner rotates **launch** order by process repeat.
The program constructs the same 256-channel planar image with a validity
mask, 8 alternative mutable descriptor/IntrinsicChannel arrays, an identical
3-plane float output, and the same ROI sequence, value scales, offsets and
3-band permutations for each policy. Each measured batch runs exactly:

```text
mutable IDs/metadata
   -> two independent .idup immutable snapshots
   -> verified image
   -> prepared three-component physical mapping
   -> reuse 1/4/16 real 8x8/32x32 ROI mappings
   -> observed per-ROI first-lane checksum
   -> independent full final ROI three-lane oracle (outside timer)
```

`measureReuseBatch` and its three StopWatch sections are **reused
unchanged** from M3.2.14–15. No synthetic success-token shortcut.

- **normal**: automatic GC untouched; snapshot/mapping measured.
- **precollect**: `GC.collect()` explicitly run *before each batch*,
  **outside** the setup/map/total StopWatches. Record external collection
  wall time, collection count and pause separately. It is a latency
  redistribution, **not** a cost-free improvement; for lifecycle comparison
  add external time and, where material, the resulting heap changes.
- **deferred**: `GC.disable()` immediately before the batch and
  `GC.enable()` after collecting the in-batch counters. Restoration is
  paired on normal/exception scope exit. Crucially, **allocations remain
  enabled**; emergency collections under memory pressure may still
  occur. Disabled mode does not imply `@nogc`. GC state is always restored
  before full output verification / next batch.

`GC.disable` applies process-wide and is used here **only** as a bounded
causal diagnostic. Holding a collector disabled in a real GUI or long
consumer pipeline is *not* proposed.

Reference D runtime semantics:
[core.memory.GC](https://dlang.org/phobos/core_memory.html)
and [D GC documentation](https://dlang.org/spec/garbage.html).

## Counters, interpretation and residual confounds

Immediately outside the timed batch, record delta GC allocation bytes,
completed cycles and pause time; `getrusage(RUSAGE_SELF)` minor and major
fault deltas; and `GC.stats()` before/after reported used/free heap
bytes. After restoring a deferred batch, sample post-enable collection
counter/pause separately. The GC heap-used/free values may only refresh
after a collection and must not be read as exact immediately-live bytes.

The external precollection, disable/enable toggles, counter probes and
full-pixel oracle are outside StopWatch windows. They still change
allocator/cache state between rounds and do not equal typical consumer
lifecycle costs. Three **different processes** cannot have identical
heap histories in the strong causal-intervention sense; process-level
replicates, hardware context, GC cycles/pause and tails are essential.
The modes are not silently claimed to be equivalent GC contracts.

Independent analyzer `analyze_gc_intervention.py` demands the *full*
3-policy × process × contiguous round matrix and replays every observed
per-ROI physical-value checksum without trusting the program's
`checksum==expected` predicate. It rejects wrong policy, missing data,
false precollection in a control, invalid counters, negative times and
forged checksums. It preserves every setup >50 µs in the final JSON;
**no trimming**, and no automatic win/causality verdict.

## XPS qualification commands

From `libs/imagery-d`, after inspecting the current worktree:

```bash
git fetch origin
git status --short --branch
git switch research/m3-2-16-gc-intervention
git pull --ff-only origin research/m3-2-16-gc-intervention

COMPILER=ldc2 REPEATS=5 ROUNDS=1024 WARMUPS=16 \
  SIDE=32 REUSE=1 SMOKE=0 \
  bash experiments/m3_2_validated_roi/tools/qualify_gc_intervention_xps.sh
```

Run a separate **8×8** or **4-ROI** follow-up only after the
32×32 / 1-ROI target is independently qualified:

```bash
COMPILER=ldc2 REPEATS=5 ROUNDS=1024 WARMUPS=16 \
  SIDE=32 REUSE=4 SMOKE=0 \
  bash experiments/m3_2_validated_roi/tools/qualify_gc_intervention_xps.sh
```

A hosted smoke (`REPEATS=2 ROUNDS=2 WARMUPS=1 SMOKE=1`)
only checks semantic/log correctness, not benchmark performance.
The full reference experiment has **15 OS processes** (5 repeats
× 3 separate policies) and **15,360 recorded batches** (each batch
includes `REUSE` real ROI maps) plus warmup work. It records exact
imagery and raster commits and worktree state, toolchain and host
configuration, memory/swap/frequency context around each repetition,
optimized binary SHA, available symbols/disassembly, all inherited
private-constructor/DIP1000 negative compiler gates, raw logs,
independently validated raw and per-process summary CSV+JSON.

Run with materially reduced memory/swap pressure and consider CPU
affinity; an observed 100-ns-quantized setup below stopwatch resolution
is not free. If raster HEAD differs from pinned `v0.2.0`, label
evidence **local dependency state**. No sibling repository is
modified. The runner itself uses separate OS processes and never
leaves GC disabled across invocations.

## Promotion criteria

1. Every policy has a complete matrix and independent semantic oracle.
2. Report process-level **median, maximum, upper tail** and GC pause
   distributions, including 78.1-µs-like no-GC tails.
3. Report external `GC.collect()` wall time and cycles **as incurred**,
   never suppress them in a consumer lifecycle claim.
4. Compare both in-window and complete lifecycle and observe heap/fault
   state. Explain any precollect/deferral collection displaced later.
5. Repeat on multiple clean processes under documented host conditions;
   do not claim a GC trigger threshold without evidence.
6. No universal break-even, GC production policy, release performance
   gate or imagery public API change until promotion is separately
   justified.

PR #55 remains stacked research, **not merged to `develop`**.
