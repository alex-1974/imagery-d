# M3.2.17 — Independent Dell XPS immutable metadata ownership and reuse audit

**Audit date:** 2026-10-12. **Result:** evidence integrity **PASS**;
immutable source metadata and mutable-to-immutable **copy-once** both retain
**zero measured metadata GC allocation per mapped ROI packet**, while
copy-per-packet allocates **17,744 bytes per packet** and is slower on the
selected recorded workload in **all 20 process-level repeat/stratum comparisons**.
This validates reuse of M3.2's existing sealed Prepared path, **not** a
mutable-to-immutable zero-copy freeze, real-time latency bound, or new
production/public API.

**Tracking:** [research issue #56](https://github.com/alex-1974/imagery-d/issues/56),
[stacked draft PR #57](https://github.com/alex-1974/imagery-d/pull/57),
[method/ownership protocol](m3-2-immutable-metadata-ownership-reuse.md),
[previous M3.2.16 XPS GC intervention audit](m3-2-gc-intervention-xps-results.md).

## 1. Provenance and admissibility

- **User-provided archive:** `metadata-owner-20261012T133443Z.tar.gz`;
  independent whole-archive SHA-256
  **`bb97c9d4c45128095f3b3093ffbbf2d8e26a6901cb17cfc37ebe6fc39be16442`**.
  Archive retained externally and is not committed as binary research payload.
- **Exact measured imagery HEAD:** `920806d71b7dfbabc000e0f7a28fa4fd20956c65`,
  branch `research/m3-2-17-metadata-owner-reuse`. Four-compiler correctness
  and hosted full-runner CI at this source HEAD:
  [Actions #38255457192](https://github.com/alex-1974/imagery-d/actions/runs/38255457192)
  **4/4 SUCCESS** (DMD 2.111/2.113; LDC 1.41/1.43).
  Subsequent documentation commits must never be represented as the measured binary.
- **Raster dependency local HEAD:** `1ea67cb6ffb2c887f78d160249a293ad74ba5cda`,
  **not** the peeled `v0.2.0` tag
  `2f2415851e45001df92ce56dad409f680684ba8d`.
  Build resolves local `raster-d ~release/0.2`; this is local-state
  research and not an exact released-v0.2.0 consumer measurement.
  The archive's worktree report records pre-existing untracked build
  artifacts in imagery-d and raster-d; **no changes to sibling repositories**.
- **XPS reference host:** Dell XPS 15, Intel Core i7-9750H, Ubuntu
  `6.17.0-22-generic`, LDC 1.41.0 (DMD frontend 2.111.0,
  LLVM 19.1.7), DUB 1.40.0, optimized release binary.
  CPU `powersave` governor; OS-default affinity, unpinned frequency.
  Available RAM before runs ~7.55 GiB; swap remained nearly full
  (e.g. ~69,460 KiB free in before-run snapshots). All five repeat-level
  `/proc/vmstat` snapshots showed **zero delta in pswpin, pswpout
  and pgmajfault**, but these are not precise per-packet fault counters.
- Binary SHA-256 reported in archive:
  **`a3bbfd233cfd5714fbabb4d4034e6726e286ef842c628d1b83cfd5de1c5555b0`**.
  The binary itself is **not in the uploaded archive**; therefore its SHA
  cannot be independently recomputed from saved binary bytes.
  `symbols.txt`, `disassembly.txt.gz`, `build.log`,
  `m326/m329/m3211/m3212-gates.log` are retained.

## 2. Complete independent semantic/evidence audit

Exactly **5 independent processes per policy×ROI-size×reuse stratum**:
3 policies × 2 ROI sizes (8×8/32×32) × 2 reuse counts (4/16) × 5 repeats
= **60 unique processes**; each contains **32 packets**, for
**1,920/1,920 recorded actual processing packets**. Those
packets perform **19,200 real individual ROI mappings** in total
(5 processes × 3 policies × 2 sides × 32 packets × (4+16) ROIs).

An **independent Python replayer**, not importing
`analyze_metadata_owner.py`, validated:

1. All **60 distinct exact log names** and the contiguous 32-packet
   sequence for each process/policy/ROI/reuse case; completion marker
   exactly once in every source log.
2. All first-component physical-value checksums independently
   reconstructed from actual source channel 254, source sample
   `254*16 + 2*y + x`, calibration `scale=0.625` and
   `offset=-6`, validity `(x+y)%11 != 0`, and the 4-position
   ROI-origin cycle. Expected checksum is **7688.875** for four ROI
   calls, **30755.5** for sixteen; recorded text rounds 7688.875 to
   `7688.88`. **All 1,920 logged observed and expected checks PASS**.
3. `metadata-owner-raw.csv` agrees value-for-value and order-for-order
   with all raw source log records, including packet number, setup/map
   times and GC allocation bytes.
4. All **60 per-process statistics** (medians, summed preparation/map/copy
   duration, allocations, maximum setup) independently recomputed and
   matched `metadata-owner-processes.csv` and
   `metadata-owner-summary.json` without relying on the repository analyzer.
5. Program's last-ROI independent **full three-component pixel oracle
   PASS in all 60 processes**, and snapshot-alias-isolation sanity
   checks PASS. The external replayer checks the *logged first pixel
   aggregated per packet*, not all intermediate ROI pixels.
6. Existing private/borrow/DIP1000 gates and prior M3 smoke outputs
   are retained in the binary/evidence harness. The M3.2.17 hosted CI
   also requires forbidden implicit mutable→immutable and
   const→immutable conversions to be rejected on all four compilers.

**A measurement limitation:** counts 4 and 16 are multiples of the
4-origin cycle, and the checksum is a **sum**, so the recorded first-pixel
checksum is the same each packet in a given reuse stratum and would not
detect an arbitrary permutation of intermediate window order by itself.
The separate last-ROI full-pixel oracle would catch an incorrect last
region; the actual `mapPrepared` call and 4/16 loop are visible in source
and retained disassembly. More discriminating per-ROI fingerprints
would be preferable for future evidence.

## 3. Allocation accounting: the decisive contract

**All 640 `snapshot_each` packet rows** report exactly **17,744 GC bytes
in the batch**. All 640 `snapshot_once` and all 640 `immutable` rows
report **zero** within the measured reuse loop.

All **20 distinct `snapshot_once` processes** report exactly
17,744 bytes allocated by a single two-array `.idup` snapshot
*before* the 32 mapped packets. No further copy occurs in later rows.

| Metadata ownership policy | Packet hot-path GC bytes over all 20 processes | Recorded one-time GC bytes over those 20 processes |
|---|---:|---:|
| Genuinely immutable source | **0 B** | **0 B recorded inside consumer** |
| `snapshot_once` from caller-mutable arrays | **0 B** | **354,880 B** |
| `snapshot_each` from caller-mutable arrays | **11,356,160 B** | **0 B in a separate once-only phase** |

Per **individual process**, `snapshot_each` allocates
32×17,744 = **567,808 B** across the 32 packets; `snapshot_once`
allocates 17,744 B once, a **96.875% reduction** in measured snapshot
allocation volume over this 32-packet lifetime.

The `immutable` fixture internally builds its *caller-provided*
immutable arrays with two `.idup` calls **before the recorded
consumer section**; those bytes were not sampled and must not be
silently asserted to be zero lifecycle allocation. The
`ResearchMetadataState.fromImmutable` operation itself borrows those
already immutable array pointers without deep-copying.

All three paths use the same real physical mapping, with checked
intrinsic identity and stored/physical semantics; no cut in output
workload or pixel semantics is responsible for these allocation
differences. The `ResearchMetadataState` does **not** implement a
new unique non-GC owner, a `UniqueBuffer`, a thread-sharing policy or
an unsafe cast-based mutable freeze.

## 4. End-to-end *selected timed components*: five process replicates

For each independent process, selected accounted time is:
`sum(packet map_ns) + sum(packet setup_ns) +
sum(once_copy_ns)`. This includes two-array copy and one-time
Verified/Prepared setup where applicable; it does **not** include
fixture creation, CLI/log overhead, GC stats sampling, pixel-oracle
work, process exit, or original immutable-provider construction.
A 0-ns per-packet setup means below 100-ns stopwatch granularity,
**not a zero-cost instruction**.

The following values are **medians of the five complete-process
selected-component totals**, in **microseconds for all 32 packets**:

| ROI size | ROIs per packet | immutable | snapshot once + copy | snapshot each | once vs each (ratio of reported medians) |
|---|---:|---:|---:|---:|---:|
| 8×8 | 4 | **87.8** | **95.4** | **314.6** | **3.30×** |
| 8×8 | 16 | **342.1** | **350.1** | **601.8** | **1.72×** |
| 32×32 | 4 | **1238.0** | **1219.0** | **1450.7** | **1.19×** |
| 32×32 | 16 | **4936.7** | **4952.7** | **5244.0** | **1.06×** |

The ratios are of **medians from distinct OS processes**, not
within-process prepared-vs-conservative paired benchmark speedups.
For each of the four strata and each of the five repetition indices,
the observed `snapshot_each − snapshot_once` difference in
selected-component total time is **positive**:

| ROI size | ROIs | Differences per repeat in µs, each minus once | Median difference |
|---|---:|---|---:|
| 8×8 | 4 | 227.7, 220.1, 210.7, 393.4, 212.0 | **220.1 µs** |
| 8×8 | 16 | 206.3, 269.0, 174.6, 272.8, 251.7 | **251.7 µs** |
| 32×32 | 4 | 218.2, 209.0, 197.8, 303.4, 364.9 | **218.2 µs** |
| 32×32 | 16 | 262.6, 456.8, 177.7, 291.3, 249.1 | **262.6 µs** |

The `run` index is a *rotated policy launch group*, **not**
simultaneous or within-process matched heap/CPU state. Do not treat
the 20 signs as 20 independent randomized causal experiments
(the four strata share a host and launch campaign). The consistency
is nevertheless meaningful source-specific support for amortizing
metadata preparation.

## 5. Per-packet medians and actual mapping work

All three variants actually map the same 4/16 3-channel ROIs from the
same 256-channel planar masked source.

| ROI size | ROIs | `immutable` packet median mapping | `snapshot_once` | `snapshot_each` |
|---|---:|---:|---:|---:|
| 8×8 | 4 | 2.7 µs | 2.7 µs | 2.7 µs |
| 8×8 | 16 | 10.5 µs | 10.55 µs | 10.5 µs |
| 32×32 | 4 | 37.8 µs | 37.7 µs | 37.6 µs |
| 32×32 | 16 | 152.7 µs | 152.85 µs | 153.5 µs |

`snapshot_each` setup median is about **6.4–7.1 µs per packet**,
compared with one-time `snapshot_once` copy cost around
**6.0–6.6 µs per entire 32-packet process**, plus negligible-size
one-time verification/Prepared setup on this timer. Thus the fixed
metadata cost matters much more for 8×8 than for 32×32 ×16.

### Observed tails (no GC causality claim)

All `immutable` per-packet setup measurements ≤**0.6 µs**;
all `snapshot_once` setup ≤**1.2 µs** (only packet 0 sets up;
later rows report 0 in this schema). Across 640 `snapshot_each`
packets, there is exactly **one setup >50 µs**:

- repeat **3**, ROI 8×8, reuse 4, packet 8:
  **83.4 µs** snapshot+validation setup,
  17,744 B reported GC allocation for that packet.
  Two additional slower setups at 39.6 and 25.5 µs are retained
  in raw logs.

Unlike M3.2.15/M3.2.16, this M3.2.17 protocol does **not** log
in-batch `GC.profileStats().numCollections/totalPauseTime` or
per-packet minor/major faults. The 83.4-µs event is a **real
setup tail**, not proven to be a GC cycle or a page fault.
Mapping tails (e.g. 308.9 µs in a 32×32 ×16 repeated-snapshot packet)
are also retained; no trimmed-percentile release bound is claimed.

## 6. Optimized machine code and limitations

The supplied optimized LDC 1.41 compressed disassembly and symbol list
were independently inspected:

- `measureReuseBatch` contains **two `gc_malloc` calls and two
  `memcpy` calls** for mutable→immutable arrays, as well as the
  real `mapPrepared` call (no optimizer-erased control).
- `mapOwnerPackets` retains `mapPrepared` and explicit
  `GC.stats` reads around each packet; it does not perform per-packet
  array allocation in the immutable/copy-once loops.
- `runMetadataOwnerReuseExperiment` retains real snapshot
  `gc_malloc`/`memcpy` calls for the already-immutable fixture
  and copy-once paths, and retains an actual call to
  `measureReuseBatch` for the copy-every-packet control.

This supports the causal **code shape** difference between metadata
lifetimes without claiming the archived source *alone* proves a
universal performance factor. The binary SHA manifest cannot be
verified without archived executable bytes.

The current `ResearchMetadataState` stores GC-backed immutable
array slices; it does **not** own an external resource or prevent
all copying of the lightweight state. Its safety depends on the
immutable backing genuinely being immutable, and the M3.2 sealed
factories maintaining the source/metadata borrows.

## 7. Conclusion and next admitted research decision

**Accepted as research evidence:**
- completed, independently replayed real-pixel workload;
- safe separation of already immutable borrow versus explicit
  mutable-to-immutable `.idup` snapshots;
- immutable metadata and copy-once Prepared execution can reuse
  validated data for 32 packets × 4/16 ROIs without further
  measured hot-loop metadata GC allocation;
- copy-once is measurably cheaper on the selected components
  than repeated copying, with a larger proportional gain when ROI
  mapping is short;
- no weakening of prior private checked-executor or DIP1000
  negative safety/forgery gates.

**Still not qualified:**
- generic mutable→immutable *zero-copy freeze*, transferable unique
  metadata owner, move-only/borrow concurrency semantics;
- an allocator/arena solution for ownership-transfer without
  reachable stale aliases;
- full caller-provided immutable materialization lifecycle costs;
- exact tagged `raster-d v0.2.0` benchmark;
- GC pause causality for 83.4 µs, reliable maximum latency
  on a quiet/pinned CPU, multi-machine performance generality;
- a new public API, guaranteed GC-free entire program,
  or production adoption.

**Next bounded step:** a precise lifetime/ownership probe around
long-lived metadata source adapters (construct-once per image,
ensure no alias-driven mutable publication after copy), and
if warranted a *separate* exclusive-owner no-escaped-alias
prototype. Avoid adding general `UniqueBuffer`/arena APIs
to `containers-d` without a genuine second consumer.
Performance follow-up should preserve all full-pixel tests,
use calibrated varied per-ROI fingerprints to avoid the
repeating checksum's order blindness, and record GC+fault
tails under controlled CPU/memory conditions.

**PR #57 remains OPEN/DRAFT**, stacked on PR #55. The source
measured here remains immutable evidence and no research branch
is merged into `develop`.
