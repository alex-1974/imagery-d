# M3.2.10 — Dell XPS common-kernel ROI + pixel mapping results

**Status: Research performance/mechanism evidence PASS for the recorded
local image/raster source state.** Production exposure and public API
**NOT ADMITTED**. The mapped operation benefit is meaningful mainly
for **many channels and small ROIs**; it is **not** a general image
pipeline acceleration claim.

**Collected:** 2026-10-11 19:19:01 UTC.  
**Operator archive:** `prepared-20261011T191901Z.tar.gz`, SHA-256
`754af98a81153bb0bab6e8d6eb40103a2890ee1b8889a9b21075796f1694a983`.  
**Measured imagery commit:** `4a4a85a07159cd2db1ad1623ca355054e94abca6`
(branch `research/m3-2-common-pixel-kernel`, only untracked DUB
selection JSON and generated executable).  
**Raster dependency:** `1ea67cb6ffb2c887f78d160249a293ad74ba5cda`,
NOT the exact `v0.2.0` release tag
`2f2415851e45001df92ce56dad409f680684ba8d`.
The earlier read-only raster worktree audit explains all 17 status
entries as untracked benchmark/experiment artifacts and found no
modified tracked source; nothing was cleaned or reset.

**Host:** Dell XPS 15, Intel Core i7-9750H (6C/12T),
Linux 6.17.0-22-generic, LDC 1.41.0 (DMD frontend 2.111.0,
LLVM 19.1.7), DUB 1.40.0, release.
Governor `powersave`, OS-default CPU affinity. At run capture,
4.0 GiB swap was almost entirely used (92 KiB free), an uncontrolled
host-state confounder.

## 1. Evidence inventory and independent validation

The user-provided archive contains **19 regular files**:
five `run-N.log` process logs; `environment.txt`;
`prepared-raw.csv`, `prepared-summary.csv`,
`prepared-setup.csv`, `prepared-summary.json`;
`common-kernel-audit.log`, `disassembly.txt.gz`,
`symbols.txt`, `build.log`, `analysis.log`;
`m326-positives-negatives.log`,
`m329-positives-negatives.log`,
`objdump-errors.log`, and `timed-binary.sha256`.

A second **independent parser** of the raw CSV and all five
execution logs verified:

- Exactly **4,320 mapped-operation measurements**:
  five independent process invocations × four channel counts
  (3/17/64/256) × three ROI sides (8/32/64) × two
  layout/validity configurations × 12 rounds × three modes.
- **1,440/1,440 complete matched triples**, each with one
  `revalidated_image`, `verified_immutable_image`, and
  `prepared_semantic_map`, identical 24-iteration counts,
  matching non-NaN/nonzero mapped-output checksums and
  three distinct execution slots.
- All **4,320/4,320 CSV rows** match the five program logs.
- Each mode ran **480 times in each** position (first, second,
  third). The checksum check is a paired output check, not a
  replacement for the independent exact-value pixel oracle
  performed by the positive compiler tests before timing.
- All **24** medians and old/verified-to-prepared median
  paired ratios in the generated summary agree with the
  independent recomputation within serialization rounding.

Against the original one-shot mode, prepared was **faster in
1,102/1,440** matched rounds, slower in **331**, equal in **7**.
Against the validated-ROI + one-shot mapper, prepared was faster
in **1,045/1,440**, slower in **377**, equal in **18**.

These are *nested, repeated observations within five process runs*,
not 1,440 independent XPS machines; avoid treating simple win
counts as independent statistical trials.

### Evidence fingerprints

| File | SHA-256 |
| --- | --- |
| `environment.txt` | `cac2b5e71a25bd0fb84d276a7757ab3f927d9881fd6317f5b1123c93eb91d0bf` |
| `prepared-raw.csv` | `9a162e93b6b3833423b72f951a248f6909cf58ee713b0166f67a3410a8a7720c` |
| `prepared-summary.csv` | `e7af189bc5622338a5b461de4fc4c2a8235ce6e948ee0208ce4bc6e893293647` |
| `prepared-setup.csv` | `85f76712c22173d3a069008ffd03e05d256f27f2c33bfed48ee407695ecd8016` |
| `common-kernel-audit.log` | `f3e8aae1a3814fd05dcd6185bef2c4ab7bb2e923f00b778f89ff2f6334ac3a02` |
| `m326-positives-negatives.log` | `c9467127ce330725e243265b3a0d6e830809fb7f8e99122d53f741b8dfe33b20` |
| `m329-positives-negatives.log` | `6f1823eb0d95492586671d0812cbaa84c70f6c044b0fd60a18162855799d5478` |
| `disassembly.txt.gz` | `e0e9f2d3da52aaf8595ac9d4c755bacb023f5cd3980b346337fde94739f5bf37` |

The one `timed-binary.sha256` manifest reports executable hash
`f40d3dc9e796dbcbf9a4c2958b9dc31b9a10067555c2dbc405f982f640f15dd8`.
The executable bytes themselves are not uploaded; this recorded
fingerprint cannot be independently recomputed or prove a
cryptographic linkage between separately supplied disassembly
and the timed executable.

## 2. Observed three-way mapped-pixel performance

All reported times are **median nanoseconds per full ROI mapping**,
including semantic ROI derivation, selected channel reads,
radiometric `stored*0.5-4`, validity when enabled, and output
pixel writes. Each table row has **60 paired/tripled rounds**;
the speed ratio is the **median of the paired old/prepared
ratios**, not the ratio of marginal medians.

| Channels | ROI | Layout | Conservative ns | Verified ROI + one-shot ns | Prepared ns | Old / prepared |
| ---: | --- | --- | ---: | ---: | ---: | ---: |
| 3 | 64×64 | interleaved | 33,488 | 33,646 | 33,550 | **1.0005×** |
| 3 | 64×64 | planar + mask | 37,346 | 37,706 | 37,573 | **1.0010×** |
| 64 | 8×8 | interleaved | 596 | 575 | 542 | **1.0977×** |
| 64 | 8×8 | planar + mask | 683 | 658 | 629 | **1.0819×** |
| 256 | 8×8 | interleaved | 788 | 696 | 588 | **1.3251×** |
| 256 | 8×8 | planar + mask | 804 | 721 | 625 | **1.2852×** |
| 256 | 32×32 | interleaved | 9,735 | 9,629 | 9,467 | 1.0215× |
| 256 | 32×32 | planar + mask | 9,438 | 9,323 | 9,148 | 1.0275× |
| 256 | 64×64 | interleaved | 41,942 | 41,629 | 40,952 | 1.0198× |
| 256 | 64×64 | planar + mask | 40,200 | 39,710 | 39,794 | 1.0124× |

All 24 configurations are in the archived `prepared-summary.csv`.
For 256 channels / 8×8, prepared beat the conservative baseline
**60/60 rounds in each** layout. Five separate process-median
old/prepared ratios ranged **1.305–1.370× interleaved** and
**1.279–1.287× planar+mask**. Median *paired* time saved
was **193.75 ns** per interleaved ROI and **179.17 ns**
per planar+mask ROI.

The **prepared vs already verified ROI + one-shot** paired
median ratios for the same 256-channel 8×8 cases are
**1.1849× interleaved** and **1.1523× planar+mask**.

By 64×64, the benefit is small compared with total pixel work,
and at just three channels/64×64 it is effectively absent.
Across some other cases the relative performance direction
varies between rounds, processes and layout; the table is not
an unconditional acceleration guarantee. Timer totals
are quantized in increments of 100 ns, or ~4.17 ns/map
at 24 maps per timed sample.

## 3. Common-kernel codegen attribution

The independently inspected compressed disassembly contains
**one** `researchExecuteCheckedPixels` function definition.
The included `common-kernel-audit.log` reports:

```text
PASS: single common codegen kernel used by both mapped paths
```

It identifies a call to that symbol from the original
`m3_2_channel_metadata.contract.mapComponentsInto` and one
from the compiled prepared consumer entry point
`m3_2_consumer_workload.benchmark.mapPrepared`
(the prepared `mapInto` receiver has been inlined into that
caller). Thus **both routes execute the same noninline inner
pixel/validity loop** in the timed release binary, unlike M3.2.9.

The changed preflight paths still do different *control-plane work*:
conservative ROI validation and full M3.2.2 one-shot
channel checks/calibration; immutable verified ROI skipping its
repeat identity pass but invoking one-shot mapping;
and prepared semantics validated once, then just per-destination
preflight. This experiment now supports a measurable benefit
from **the combined removal of repeated ROI and mapping preflights**,
not a claim about any single instruction/scan contribution.
No hardware counter, controlled CPU frequency, or branch-level
cause attribution was measured.

Unlike the original M3.2.9 experiment, the large-ROI/three-band
speedup disappeared. That is consistent with the original
difference being at least partly pixel-kernel code generation,
but **separate run-to-run host effects prevent attributing
the exact difference between old and new archives quantitatively**.

## 4. Preparation cost and tentative reuse economics

The program records 100 setup iterations per process. Values
below are medians of **five process-level average ns/call**:

| Channels | Caller borrow + validation ns | Already immutable factory ns | Prepared binding only ns | Two `.idup` snapshots + factory ns |
| ---: | ---: | ---: | ---: | ---: |
| 3 | 2 | 2 | 26 | 115 |
| 17 | 9 | 6 | 29 | 516 |
| 64 | 35 | 22 | 29 | 1,771 |
| 256 | 137 | 91 | 29 | 7,363 |

At 256 channels, if snapshotting both descriptor arrays
is needed *only* for this prepared path, a rough difference
`(7363 + 29) - 137 = 7255 ns` over caller borrow
would be amortized by approximately
`ceil(7255 / 193.75) = 38` similarly small interleaved
ROIs or `ceil(7255 / 179.17) = 41` planar+mask ROIs.

**These 38/41 estimates are arithmetic illustrations, NOT
qualified reuse thresholds.** Prep samples at 2–29 ns
can be distorted by inlining/hoisting and clock granularity;
snapshot allocations can be affected by GC state; different
lifetime/ownership contracts are not necessarily semantically
interchangeable. If the caller's metadata are already truly
immutable, the two `.idup` costs are irrelevant.

## 5. Remaining restrictions and engineering decision

**Accepted as research evidence:** complete audited matched XPS
dataset, local compiler correctness/negative lifetime tests,
same-pixel-kernel machine-code check, and a reproducible,
substantial 256-channel/8×8 control-plane benefit
(about 1.29–1.33× over the full conservative mapping path).

**NOT admitted:**
- Production-exposed shared raw execution adapter:
  `researchExecuteCheckedPixels` presently accepts scalar
  parameters directly in a cross-module research setup;
  `@safe` guards memory, **not** caller-forgeable semantic
  preflight invariants.
- Public `PreparedSemanticMap` / image owner API, broad mapping
  speedup promises, independent pixel numerical guarantees
  beyond the synthetic oracle, or the current setup break-even
  as a release-quality threshold.
- Exact pinned-`raster-d v0.2.0` hardware evidence or
  independently attested executable bytes.

The shared checked loop and preflight separation are promising,
but a **true private execution-module boundary or unforgeable
validated capability** is required before production promotion.
Broader numerical/error/aliasing and concurrent caller-mutable
metadata semantics require explicit qualification, along with
controlled frequency/affinity/GC-aware XPS measurements for
any release performance gate. Preserve prior M3.2.7–M3.2.9
research and active branch stack. Do not merge this research
wholesale into `develop`, and do not edit other repositories.

**Next research recommendation:** design/qualify a capability-safe
private execution boundary and realistic prepared-state reuse
scenarios. Keep preparation anti-hoist and pinned release
dependency checks as distinct acceptance gates.
