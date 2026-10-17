# M3 RGBA — independent XPS one-versus-four subscriber memory control (2026-10-15)

**Issue #74 · Draft PR #73 · research only.**
**Evidence disposition:** QUALIFIED for the **three real backings / 3-versus-12 real leases** owner/accounting observations and **process-level Linux memory distributions**. This is **not** an all-in per-subscriber memory-budget or RSS bound. **Decision: ADAPT evidence; DEFER physical-memory admission, public API, PR merge and release.**

The two independently submitted archives are from the new experiment
[specified before measurement](m3-rgba-generation-subscriber-physical-memory-protocol.md).
They are not replacements for the [20-process three-generation memory study](m3-rgba-generation-memory-xps-2026-10-15.md) or the
[24-process native GC-range attribution study](m3-rgba-native-gc-range-control-xps-2026-10-15.md).
Those protocols measure different conditions.

## Frozen evidence, verification and boundaries

| Archive | Role | Archive SHA-256 | Qualified payload SHA-256 | Fresh processes | Independently reconstructed CSV |
|---|---|---|---:|---:|---:|
| `20261015T123135Z.tar.gz` | smoke, `2026-10-15T12:31:36Z` | `0e1d53266d3d5e330b0d33804153326092c5ca709acf80da984ed91b7f223059` | **16/16** | **4/4** | **4/4** normalized traces, **22/22** paired rows |
| `20261015T123148Z.tar.gz` | normal, `2026-10-15T12:31:48Z` | `979d1215f8d7603d6da7c801edb3d15a65497e820eac0cfdd44d211ea55186ac` | **124/124** | **40/40** | **40/40** normalized traces, **220/220** paired rows |

**Independent integrity/replay:** The manifests were reparsed and each named
file's digest recomputed, rather than trusting `checksum-validation.txt`.
All non-snapshot regular payload files are covered by the manifest except
the manifest itself and the deliberately generated checksum verification log.
Both archives contain `snapshot/` directories: **412 regular snapshot
files in each**, **not individually covered by the manifests**. The whole
archive SHA above binds their bytes; provenance of the Git/source tag snapshot
is separately recorded below and was not independently reconstructed from
every snapshot byte. Neither archive contains unsafe absolute paths, parent
traversals or tar link members.

The independent replay checked exactly 11 ordered snapshot rows per
consumer process, canonical field counts, ROI size, subscriber count, distinct
generation count, requested payload identity, ledger charge identity, closing
receipts, monotonic cumulative GC allocation, and `VmHWM >= VmRSS` *within
each observation*. Reconstructed normalized CSV bytes match all recorded
`*-stages.csv` files; all paired four-minus-one values were independently
recomputed, not merely read from their prepared summary. All **44** stderr
files are empty. Both validator self-test receipts PASS. The LDC release
consumer build logs record only previously observed, nonfatal
`mir-core 1.7.4` / `ldc.intrinsics.LLVM_version` deprecations.

| Pinned field | Value in both archives |
|---|---|
| Source commit | `297518d228336a49c3777c5eaefd12d3419ca144` |
| Branch | `research/m3-rgba-layer-compositing` |
| Operating system / machine | `xps-15`, x86-64 Linux `6.17.0-22-generic`, Intel Core i7-9750H |
| Compiler / DUB | LDC **1.43.0** / DUB **1.42.0** |
| `raster-d v0.2.0` peeled SHA | `2f2415851e45001df92ce56dad409f680684ba8d` |
| `color-d v0.2.0` peeled SHA | `3359f08f4e83941ac1a8451cadefb146b5736019` |
| Full run sampling | ROI sides 16, 64, 256, 512; five independent repetitions of each one- and four-subscriber condition |
| GitHub CI for exact measured commit | **5/5 workflows SUCCESS** (independently checked on 2026-10-15) |

The runner builds `git archive HEAD` and pinned read-only sibling tags.
The logged untracked research binaries, DUB selections and prior archives
in the user's worktree are **not** included as source inputs. Do not
clean or overwrite those active files.

## Controlled physical ownership and exact lifecycle

Both treatments execute the same real `raster-d` + `imagery-d`
source-over producer for A/B/C in one recycled cache slot, with the
same prepared input fixtures and ROI, and exactly three physically
different retained `RasterLease!SRgba8` packed backings.
The only experimental treatment is **one** versus **four genuine,
independent `GenerationDelivery` subscriber handles *per generation*.

At the `abc_live` checkpoint:

- three underlying backings are alive in **both** arms;
- **3** versus **12** subscriber handles are live;
- requested packed pixel payload is exactly
  `3 * (4 * side * side)` bytes in **both** arms;
- the pre-existing ledger's **illustrative**, not physically qualified,
  charge is `3 * (4 * side * side + 64)` bytes in both arms;
- cache eviction and cache-object exit do not invalidate retained
  independently-owned generations.

The `extras_closed` phase closes nine extra handles in the
four-subscriber arm while the three primary owners remain live.
All records then correctly show three backings, three subscribers
and **unchanged** illustrative charges. Final A/B/C close reduces
active generations from three to zero, requested live output payload
to zero and ledger charge to zero. **40/40** complete normal-process
traces pass; the 4/4 smoke traces pass too.

The only observed **current-thread cumulative GC allocation increment**
is **+256 bytes** at the single `GenerationAccounting` object creation
in **40/40** full traces (and **4/4** smoke traces), with **no additional
increments at any subsequent checkpoint** in either treatment.
This is an *allocation counter*, not a sampled live GC heap size.

For each of the 40 full processes, the recorded `mallinfo2.uordblks`,
`mallinfo2.hblkhd`, current-thread cumulative GC allocation, `VmRSS`
and `VmHWM` values are **identical** between the neighboring
`cache_exited` and `extras_closed` checkpoints.
This is a bounded 11-checkpoint observation, not proof that the
nine closed stack handles occupied zero bytes.

## Baseline-corrected cross-process comparison

Reported values are computed for each repetition `r` and phase `p`:

`(value_4[p,r] - value_4[fixtures,r]) - (value_1[p,r] - value_1[fixtures,r])`.

The two conditions are **separately launched processes**; pairing by
ROI side and repetition number is an analysis convention, **not**
randomized shared-process memory or a guaranteed causal isolation.
Negative values are possible and are preserved as evidence.
The table shows **the median of five comparisons** at `abc_live`,
with the **minimum–maximum** across the same five comparisons.

| ROI side | Requested packed bytes, 3 backings | ΔΔ `VmRSS` median [range], KiB | ΔΔ `mallinfo2.uordblks` median [range], B | ΔΔ `mallinfo2.hblkhd`, B | ΔΔ cumulative thread-GC, B |
|---:|---:|---:|---:|---:|---:|
| 16 | 3,072 | **0** [−64, +60] | **+48** [−80, +688] | 0 (all five) | 0 (all five) |
| 64 | 49,152 | **0** [−64, +4] | **−64** [−224, +96] | 0 (all five) | 0 (all five) |
| 256 | 786,432 | **−4** [−64, +64] | **−16** [−144, +96] | 0 (all five) | 0 (all five) |
| 512 | 3,145,728 | **−64** [−128, 0] | **0** [−416, +256] | 0 (all five) | 0 (all five) |

All 20 `abc_live` comparisons agree on **zero extra reported
`mallinfo2.hblkhd` (glibc mapped-memory) and zero extra cumulative
current-thread GC allocations**. Their `VmRSS` and `uordblks`
differences fluctuate across zero and scale nonmonotonically with
ROI side, ruling out a defensible positive **per-handle** byte charge
inferred from this *sampled cross-process comparison*. The absence
of a reproducible positive delta does **not** establish that physical
copy/retain objects or runtime metadata are allocation-free for
every consumer.

A second descriptive comparison, using each process's own `fixtures`
baseline, yields medians of reported RSS growth at `abc_live`
(in KiB):

| ROI side | One subscriber per backing | Four subscribers per backing |
|---:|---:|---:|
| 16 | 168 | 168 |
| 64 | 228 | 228 |
| 256 | 1,188 | 1,188 |
| 512 | 4,260 | 4,196 |

These are **whole-process** RSS observations; no per-subscriber cost
may be obtained by subtracting those medians or by subtracting
requested payload bytes from them. For ROI 512, the median final
RSS delta at `c_closed` is 288 KiB in the one-subscriber arm,
224 KiB in the four-subscriber arm. This reverse-sign difference
is not evidence that creating more leases saves memory: it
illustrates the sensitivity to allocator/VM history.

**Linux `VmHWM` irregularity:** **10/40** full processes recorded
a decrease in the nominal high-water statistic across checkpoints
(8×64, 1×92, 1×192 KiB), distributed as side-256
(3 one-subscriber, 3 four-subscriber) and side-512
(3 one-subscriber, 1 four-subscriber). Preserve the original
measurements; require only per-sample `VmHWM >= VmRSS`. This
continues the earlier qualified XPS finding, not a raster ownership
regression.

## What is proved, and what is not

**Supported:**
1. For this independently built, serial research consumer, the
   subscriber count changes from 3 to 12 real retained handles **without
   changing the number of physical output backings, requested pixel
   payload, or generation charge**; all final releases complete correctly.
2. Increasing subscribers does not produce an additional sampled
   current-thread GC allocation after the fixed accounting object,
   nor an additional sampled `hblkhd` mapping in these 40 runs.
3. The five process-level memory metrics are invariant across the
   explicit nine-extra-handle close checkpoint in each full run;
   the 1-versus-4 process-level RSS and `uordblks` comparisons vary.

**Not supported:**
- A universal **zero-byte** memory price per subscriber, zero allocator
  calls in the retain hot path, or a measured size for each lease
  value on the stack. No per-retain malloc trace was collected here.
- A complete resident-memory or peak-memory admission equation
  summing native allocator usable sizes, all GC heap effects, producer
  transient buffers, pixel buffers, Linux mappings, source inputs and
  unrelated process state. Neither RSS nor glibc allocator counters
  can be added to the cumulative thread GC allocation counter without
  potential overlap.
- Concurrency, callback races, GC thread allocation behavior, other
  allocators/platforms, or a production cache/eviction policy. Pinned
  raster-d's reference counting remains non-atomic.

## Recommended next qualification and decision

**ADAPT:** retain the source-backed ownership law: **charge each
distinct retained generation/pixel backing once, independently of
subscriber multiplicity, and refund only after the final genuine
backing owner is released**. Do **not** promote the illustrative
`+64` charge to a physical metadata estimate.

**DEFER:** production exact/native/RSS budget admission, public M3
API freeze, PR merge and release. If a physically conservative
admission bound is required, first pre-register its intended
allocator/platform/size scope and overhead policy. Pair native
per-request allocation/usable-size traces (including materialization
peaks and live owner transitions) with separate, attributable
GC-residency observations; do not treat the 11-point `VmHWM`
or sampled `mallinfo2` deltas as a continuous maximum.
Avoid redundant subscriber-count research unless a concrete
allocation/performance risk appears.

All research remains in `imagery-d`. Do not write to sibling repos,
rebase/retarget the grandfathered stacked branch, or merge PR #73
without a separate engineering decision.
