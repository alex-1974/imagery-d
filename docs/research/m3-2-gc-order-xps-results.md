# M3.2.15 — Independent counterbalanced Dell XPS GC-order audit

**Audit date:** 2026-10-12. **Outcome:** all raw measurements, logged order and pixel checks independently qualified; five large preparation delays coincide with five measured GC collections and pauses. **No controlled GC-causality isolation or production threshold**.

**Tracking:** [Research issue #52](https://github.com/alex-1974/imagery-d/issues/52), [stacked draft PR #53](https://github.com/alex-1974/imagery-d/pull/53), [M3.2.14 prior independent XPS audit](m3-2-roi-amortization-xps-results.md).

## Evidence identity / acceptance level

- Uploaded **`gc-order-20261012T105404Z.tar.gz`**, independently hashed SHA-256 **`643732d2fc0f783397b5c7559b05f3172e1a8bef5fb24e28b5f4fb27109cfbf0`**. Archive is retained externally as a user-supplied artifact, **not committed in Git**.
- Measured `imagery-d` HEAD: **`d59628c2e7e4630fac72f83943c601b5c447f0ad`**; exact branch `research/m3-2-15-gc-order-qualification`. This measured commit already passed the full four-compiler hosted correctness/runner CI [#38238156462](https://github.com/alex-1974/imagery-d/actions/runs/38238156462). Repository documentation added after measuring does **not** change the measured binary's identity.
- `raster-d` local HEAD **`1ea67cb6ffb2c887f78d160249a293ad74ba5cda`**; archived `v0.2.0` peeled commit `2f2415851e45001df92ce56dad409f680684ba8d`. These are **different commits**: evidence is for the local dependency state, not an exact release dependency comparison. Untracked preexisting benchmark artifacts in both worktrees are listed in `environment.txt`; this research did not write sibling repositories.
- Dell XPS 15, Ubuntu kernel `6.17.0-22-generic`, LDC **1.41.0** / DMD frontend 2.111.0 / LLVM 19.1.7; release build, DUB 1.40.0. CPU governor `powersave`, OS-default CPU affinity; frequency snapshots often roughly 4.0–4.3 GHz, with individual idle 800 MHz readings. Available RAM roughly 3.0–3.1 GiB, **4.0 GiB swap almost fully used (only 232 KiB free)**. Do not generalize latency distribution to a quiet/fixed-clock machine.
- Five independent processes (`run-0.log` … `run-4.log`), **8 recorded rounds**, **2 warmups**, 3/17/64/256 channels, 8×8 / 32×32 ROI, planar+validity / interleaved without validity, immutable/mutable snapshot, reuse counts 1/2/4/8/16/32, both method slots.
- Archived binary manifest records SHA-256 **`a06acd91720248cc183ad1d73344b4cc9fa5dc88f0bbeaaeafdbc90316d75e68`**. The executable itself was **not included** in the uploaded archive; digest cannot be independently recalculated from archived binary bytes. The optimized disassembly and symbol list *are* present and were inspected.

## Independent integrity review

A separate Python implementation (not importing the repository's `analyze_gc_order.py`) read and compared every CSV measurement to each process log in source order. It independently regenerated:

1. The exact *per-process* 192-case order, including channel rotation, ROI-side rotation, layout rotation, and the 12-policy/reuse permutation `(caseSlot * 5 + process * 7) % 12`;
2. All eight recorded round × two slot modes, including the corrected warmup offset;
3. The physical-value pixel oracle for every ROI's observed first component, using stored value, three binding permutations, per-case calibration, validity mask and ROI origin;
4. Strict uniqueness of process/channel/ROI/layout/policy/reuse/round/slot tuples; pairing parity and independent checksum agreement;
5. **All 384** reported per-mode group medians, MADs, setup/map/total medians, observed GC/allocated bytes, minor/major faults, threshold counts and maximum setup times;
6. Exact matching of the six logged setup tails >50 µs and all stored JSON tail records.

**PASS:** **15,360/15,360 source-log rows**, **7,680/7,680 paired comparisons**, **192 paired cases** (40 matches per case), four-compiler contract gate logs and M3.2.13 observed pixel oracle. The D program's own per-batch last-ROI three-component full-pixel oracle reported PASS; the separate replayer checked **all intermediate ROI sample checksums**, not every intermediate pixel. All setup/map/total and GC pause times are quantized to **100 ns**; 0-ns fast setup means below timer resolution, not free work. The independent audit reported **3,618 minor page faults, zero major faults, five GC collections and aggregate GC pause 3.3033 ms** across all recorded measured batches.

## Five GC-linked setup tails: moved with case scheduling

All five significant 0.58–0.83 ms snapshot setup events are in **256-channel**, **caller-mutable→two snapshots**, **Prepared**, **recorded round 2, Prepared slot 1**, one per process. Their case identity and absolute rank differ:

| Process | Case rank | ROI / layout / reuse | Timed setup | GC collections | GC pause | Minor faults |
|---:|---:|---|---:|---:|---:|---:|
| 0 | 170 | 32×32 planar+mask, 16 ROIs | 689.2 µs | 1 | 673.4 µs | 35 |
| 1 | 120 | 32×32 interleaved, 2 ROIs | 615.4 µs | 1 | 600.9 µs | 35 |
| 2 | 73 | 8×8 planar+mask, 2 ROIs | 587.3 µs | 1 | 579.6 µs | 35 |
| 3 | 36 | 8×8 planar+mask, 8 ROIs | 648.5 µs | 1 | 635.4 µs | 33 |
| 4 | 169 | 32×32 planar+mask, 8 ROIs | 831.4 µs | 1 | 814.0 µs | 35 |

The reported GC pause constitutes **97.6–98.7% of the measured setup duration** in those five batches. They are also **all five of the GC collections observed across the entire 15,360-row dataset**; no GC event occurred outside the >50-µs setups. Every event occurs within that process's **first 256-channel block**, although the rank within that block differs (offsets 26, 24, 25, 36, 25). A fixed `reuse=1` / planar 32×32 operation is **not** responsible: changing order moves the event across ROI size, layout and reuse, whereas the 256-channel snapshot policy and timed early-round location persist.

**Additional distinct tail:** process 2, rank 54, 256 channels, 32×32 planar, mutable snapshot, 4 ROIs, recorded round 3/slot 0: **78.1 µs setup**, **zero registered GC collections/pause**, **5 minor faults**, zero major faults. The origin of this event remains unexplained; do not fold it into the GC explanation or silently trim it. Maximum setup excluding these six tails is 36.2 µs.

These observations strongly support **GC collection/pause timing as the immediate source of the five largest measured delays**. This is *instrumented temporal and duration correspondence*, not an isolated intervention proving the trigger mechanism or excluding scheduling/allocator co-effects. In particular, the original M3.2.14 uninstrumented archive had five 567.4–835.1 µs setups at **one fixed** 256-channel 32×32 planar snapshot/reuse=1 case, also recorded round 2/slot 1. The new counterbalanced layout demonstrates that the identity of that old case is not necessary for a similar spike.

## Allocation volume, page-fault and swap controls

Per **one mutable-snapshot Prepared batch**, GC allocated-in-current-thread deltas are exactly:
3 channels **192 B**; 17 channels **1,120 B**; 64 channels **4,464 B**; 256 channels **17,744 B**. All one-shot paths and already-immutable Prepared paths report **zero GC-allocated bytes** within the measured batch. Total instrumented snapshot allocation across all five processes: **22,579,200 B**; five GC collections, one per process.

On each of the five GC-linked tails the recorded batch allocated 17,744 B, counted 33–35 **minor** page faults and zero major faults. The unaccounted non-GC tail counted 5 minor faults. **`/proc/vmstat` `pswpin`, `pswpout`, and `pgmajfault` did not change between the per-process before/after snapshots**; process-wide rusage reports zero major faults in every measured batch. Thus **no additional swap I/O or major faults were observed during this experiment**, notwithstanding the nearly exhausted swap capacity. The full swap is a general uncontrolled host-pressure concern, **not an evidenced cause** for these five GC pauses.

Optimized LDC disassembly for `measureReuseBatch` retains the two `gc_malloc` snapshot calls, copies (`memcpy`), the real selected-band preparation and both mapping wrappers (`mapConservative`, `mapPrepared`). In `runConsumerReuseOrdered`, direct calls to `getrusage`, `GC.stats`, and `GC.profileStats` bracket calls to `measureReuseBatch`. This confirms the compiler did not eliminate the compared pixel/snapshot work and that instrumented counters surround—not replace—the consumer batch. It does **not** independently verify the absent physical binary SHA.

## Within-M3.2.15 paired consumer signal (not across-run A/B)

For the 256-channel **8×8 planar+mask** cases, in ns per **complete batch**:

| Ownership policy | ROI reuse | One-shot total median | Prepared total median | Paired median (one-shot − Prepared) | Prepared wins/40 |
|---|---:|---:|---:|---:|---:|
| immutable | 1 | 1,100 | 1,000 | +100 | 23 |
| immutable | 4 | 3,600 | 3,000 | +650 | 39 |
| immutable | 16 | 13,500 | 10,850 | +2,700 | 40 |
| immutable | 32 | 26,600 | 21,300 | **+5,400** | **37** |
| mutable→snapshot | 1 | 1,150 | 7,050 | −5,850 | 0 |
| mutable→snapshot | 8 | 7,000 | 11,600 | −4,600 | 10 |
| mutable→snapshot | 32 | 26,700 | 27,350 | **−500** | **14** |

The 256-channel 8×8 already-immutable N=32 case has five positive per-process paired medians (**5,300/5,500/5,300/5,400/5,400 ns**). Low-channel/small-effect cases remain strongly quantized. With the snapshots, no reliable N=32 break-even for the small 8×8 ROI follows from this run.

Crucially, these totals **must not be presented as a controlled performance change from M3.2.14**. The new protocol added per-batch GC and Linux rusage sampling, reorganized outer cases and changed allocator/cache trajectories. The original M3.2.14 256ch 8×8 immutable N=32 paired median was +6,900 ns (40/40 wins), versus this +5,400 ns (37/40 wins). The original snapshot N=32 +600 ns (24/40 wins) contrasts with this −500 ns (14/40 wins), illustrating sensitivity, **not an admissible causal benchmark regression**.

## Decision / next gate

**Accept as source-specific research:** evidence integrity; deterministic case-order verification; observable snapshot allocation sizes; direct GC cycle/pause correspondence in **all five very large tails**; tail mobility across case identities; absence of observed paging/swapping during the five recorded processes; repeated immutable Prepared benefit at 256 channels.

**Still unqualified:** why/when the GC threshold is reached, whether a practical GC scheduling/allocation policy eliminates tail latency, any universal ROI reuse break-even, a guaranteed no-GC execution path for mutable metadata, performance on exactly pinned `raster-d v0.2.0`, a production-facing API or promotion to `develop`.

**Proposed causal follow-up (new bounded probe, not retroactive edit):** repeat the identical 256-channel mutable-snapshot workload in a controlled setting while holding the case schedule fixed. Add *separate* diagnostic modes for (a) normal GC, (b) explicit GC collection before the timed batch, and (c) carefully scoped `GC.disable` with collection restored and heap growth monitored outside timing; the latter is diagnostic only, never a recommended production policy. Record allocated bytes, GC count/pause, before/after heap use and distribution tails, with same independent pixel semantics and several process-level replicates. Separately investigate the unexplained **78.1-µs no-GC** tail and its minor faults. Avoid an all-GC-disabled production shortcut. Control affinity/frequency and reduce swapping pressure before asserting stable speedups.

**Repository state:** PR #53 stays **OPEN / draft**, stacked on PR #51; no merge, no public API and no writes to sibling repositories.
