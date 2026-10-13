# M3 RGBA — Buffered packed copy-commit XPS qualification

**Measured:** 2026-10-13 **19:57:40 UTC** (Europe/Vienna 21:57:40 CEST).  
**Classification:** qualified **research-only** evidence, not production API admission, all-or-nothing failure proof or validated original-source noalias check. **Writes confined to imagery-d**.

## 1. Uploaded primary evidence and source identity

**Original user-uploaded archive:** `buffered-20261013T195740Z.tar.gz`  
**SHA-256 of compressed upload:**

```text
f56263be290dcdecbbfc719128c07d31cb6fa4a3168e12382bd797e97c3f1094
```

All measurements were independently reconstructed from **raw per-case CSVs** and reconciled with the uploaded `STAGE_SUMMARY.csv`; the summary is not the sole source. The runner excluded generated pinned source snapshots from the user archive. Source identity follows its read-only `git archive` construction and the recorded exact Git SHAs, not an independently retained bytewise snapshot hash.

| Attribute | Recorded/verified value |
|---|---|
| XPS / OS | `xps-15`, Intel Core i7-9750H (6C/12T, AVX2), Linux 6.17.0-22-generic |
| **Measured imagery-d source** | **`80415be3a46d1fd4b4beb4afb3830e90a0a2ea38`** on `research/m3-rgba-layer-compositing` |
| **Measured raster-d** | tagged v0.2.0, **`2f2415851e45001df92ce56dad409f680684ba8d`** |
| **Measured color-d** | tagged v0.2.0, **`3359f08f4e83941ac1a8451cadefb146b5736019`** |
| Compiler | **LDC 1.43.0**, DUB 1.42.0; the fixed XPS runner builds once in release and invokes the executable directly |
| Mode | `source_mode=pinned-v0.2.0`, `smoke=0` |
| Primary checksum manifest | **24/24** original per-case CSV SHA-256 entries PASS |
| Scenario matrix | **24/24** (512² and 1024×768; mixed/opaque/transparent alpha; planar/interleaved four-plane layout; whole/offset near-full ROI) |
| Paired timing rounds | **108/108** (512²: 5 rounds × 12 cases; 1024×768: 4 rounds × 12 cases), 2 complete ROI iterations per stage per round |
| Stages and rows | **9 distinct labels** in every round; **972/972 individual timed rows**, **216** independently reconcilable stage medians |
| Semantic oracle | **24/24** `HOTPATH-STAGES PASS` trailers; source verifies all ROI output pixels of original four-plane, prepared four-plane and buffered packed final result against the separately calculated packed/color-d reference before and after every measured round; paired cross-layout canonical hashes agree |
| GC instrumentation | **0 current-thread GC allocated-byte delta** in 972 timed stage entries; this does **not** establish zero native allocations elsewhere |
| Error/resource logs | **24/24** stderr files empty; 24 successful process exits; **0 major page faults** and **0 swaps** reported by `/usr/bin/time -v` |
| Build | Release compilation/link successful; only nonfatal upstream `mir-core 1.7.4` LLVM-version deprecation diagnostics |

The live `raster-d` branch (`1ea67cb6...`) differs from measured v0.2.0 and contains its own existing untracked experiments; `color-d` contains `dunia/` work. This runner only **reads** the external release tags and produces snapshots/output under ignored `imagery-d/data/`; it does not alter sibling trees or their branches.

## 2. Exactly what was compared

All three principal stages use the same original four-plane owner-backed inputs, selected ROI and **runtime upper opacity 0.37**, with unchanged tagged sRGB8 color operations:

1. **`fourplane_full`** — previous imagery four-plane adapter, direct public color-d sRGB transfer, checked per-pixel error status. Original source/output physical nonoverlap remains a **caller precondition**.
2. **`prepared_fourplane_full`** — same four-plane adapter with a caller-owned `ResearchPreparedRgbaContext`, prepared binary64-exact `double[256]` sRGB8 decode LUT and checked runtime opacity; reports image errors rather than replacing failures with sentinel pixels. **Same caller nonoverlap precondition.**
3. **`buffered_packed_commit`** — same prepared four-plane computation into a **separately owned four-plane scratch**, repack into a **separate owned single-plane `SRgba8` scratch**, and one **public `raster.copyInto`** into a separate owned packed final target. Each of those **three passes is included** in the timed stage, including copy's physical scratch/final overlap and target-injectivity preflight. The three owned ROI-size buffers were **allocated before timing**, and the LUT's once-per-context initialization was measured separately.

The last stage's single-plane final output is **not** the same storage *representation* as the four-plane stages. Although the output pixels and per-pixel color semantics are compared exactly, these timings do not make the alternatives interchangeable as public image APIs.

**Alias/failure distinction:** `copyInto` certifies **packed scratch vs packed final target**, not the original two four-plane sources vs final target. Because original inputs are fully materialized before the copy, a future design might instead specify **snapshot** semantics. That has **not** been qualified for deliberately overlapping original source/target worksets. The four-plane adapter itself permits partial internal scratch writes on exceptional sample/quantization error, while the **final packed target** is still untouched if preparation fails. A successful public final copy is not a demonstrated general transactional guarantee for arbitrary outputs/concurrent mutation.

Other diagnostic stages (`checked_io`, `decode_2rgb`, `premultiply_2`, `source_over`, `unpremul_encode_quantize`, `packed_full`) are independent workloads, **not additive components** of full execution time.

## 3. Complete throughput result

Each time is the **median of four per-scenario median** ns/ROI-pixel values (2 layouts × whole/offset ROI) for one size/alpha configuration; a scenario median is across its 5 or 4 in-process rounds. The 1.8–3.0× factors use **medians of paired per-case direct/buffered ratios**, not a ratio of unrelated aggregate medians.

| Image size | Input alpha | Direct four-plane ns/px | Prepared four-plane ns/px | Buffered packed commit ns/px | Direct / buffered speedup |
|---|---|---:|---:|---:|---:|
| **512²** | **mixed** | **207.11** | **106.24** | **114.45** | **1.817×** |
| 512² | opaque | 207.26 | 107.29 | 112.67 | **1.829×** |
| 512² | entirely transparent, hidden RGB nonzero | 152.20 | 43.77 | 49.52 | **3.036× special** |
| **1024×768** | **mixed** | **207.63** | **108.03** | **111.10** | **1.861×** |
| 1024×768 | opaque | 206.05 | 106.53 | 112.52 | **1.826×** |
| 1024×768 | entirely transparent, hidden RGB nonzero | 154.87 | 44.06 | 51.29 | **3.006× special** |

Paired **direct/prepared** factors remain ~**1.92–1.93×** in mixed and opaque cases, as observed in previous prepared XPS research. Fully transparent final pixels benefit disproportionally from the absence of expensive direct sRGB decode, but **~3× is not representative mixed-alpha performance**.

**Ordering is unanimous within this one session:** in **108/108** paired measured rounds, `prepared_fourplane_full < buffered_packed_commit < fourplane_full`. The minimum/maximum observed **direct/buffered per-round factor across all cases** is **1.410× to 3.555×** (including transparent special cases).

### Cost of scratch staging + packing + validated final copy

From **paired individual rounds**, median `buffered / prepared` latency inflation is:

| Size | Mixed alpha | Opaque | Transparent |
|---|---:|---:|---:|
| 512² | **+6.05%** | +4.38% | +12.86% |
| 1024×768 | **+4.91%** | +5.70% | +14.69% |

The overhead is a smaller percentage when the per-pixel color work dominates. Transparent output is so fast with the LUT that the extra scratch packing/copy becomes a larger fraction. These are **within-process paired observations**, not an external clock-normalized confidence interval.

### Whole-image mixed-alpha examples — one complete ROI pass

One round times **two ROI invocations**, so the following per-frame milliseconds divide the scenario median round microseconds by 2:

| Image size | Source/output layout | Direct four-plane ms | Prepared four-plane ms | Buffered packed ms |
|---|---|---:|---:|---:|
| 512² | interleaved | **55.34** | **28.93** | **30.78** |
| 512² | planar | **55.50** | **28.43** | **30.76** |
| 1024×768 | interleaved | **164.19** | **85.03** | **87.60** |
| 1024×768 | planar | **171.10** | **87.18** | **90.21** |

The stage names and values describe **standalone scalar color/raster research kernels**; they are **not** display frame latency, concurrent tile rendering, or end-to-end image loading.

## 4. Memory, preparation and measurement limitations

- Once-per-context LUT creation (from the **actual runtime color-d sRGB implementation**) plus validated opacity: **18 μs median**, **15–38 μs observed range** across 24 independent scenario processes. The numeric table has **2048 bytes**; the struct additionally carries opacity/state. Preparation is **outside** the timed stages.
- Whole benchmark process **maximum RSS** ranges:
  - 512²: **54,616–54,940 KiB** (~53.3–53.7 MiB).
  - 1024×768: **156,956–157,540 KiB** (~153.3–153.8 MiB).
- That RSS includes the *entire nine-stage attribution harness*, with many original independent color-stage `double` arrays, packed fixtures, owner-backed four-plane images **and three new ROI-size buffered-mode images**. It is **not** the native scratch memory of one production call.
- Data payload beyond original inputs/final output is **two ROI-sized 4-byte/pixel scratch buffers** = **8 × ROI-pixels bytes**; the separate new packed final target is an additional **4 × ROI-pixels bytes**. Thus the *three new benchmark buffers total* **12 × ROI-pixels bytes** (for 512²: 3 MiB; 1024×768: 9 MiB), excluding descriptor metadata and allocators. All were **preallocated before timing**.
- CPU governors were **`powersave` for all 12 logical CPUs**. No per-round frequencies, temperatures, scheduling pinning, perf counters or thermal normalization. Host startup `MemAvailable = 4,025,724 kB`; configured swap `4,194,300 kB` with only **184 kB free**. No measured process I/O swaps/major faults. A near-full swap file is a **host qualification caveat**, not proof that these processes were actively swapping.
- One OS process per case, repeated measurements inside the same process; there was no independent second-XPS session, clock-controlled variance estimate, 16²/32² small-viewport prepared/buffered sweep or realistic parallel streaming scene.
- There is **no measured native-allocation-inclusive cost** for constructing/freeing scratch on each call and **no memory-residency budget** for unlimited long-lived ROI/snapshot owners. Measuring reused-scratch throughput must not be presented as the total first-call latency.

## 5. Research verdict and next controlled gate

**Validated within a narrow domain:** a **public-only**, alias-checked **packed scratch → packed target** commit can follow a caller-owned runtime-opacity, classified-error prepared four-plane pass while preserving exact successful RGBA8 bytes. In the qualified mixed-alpha large-ROI scenarios, that buffered policy is **~1.82–1.86×** faster than the old direct four-plane path but **~5–6% slower** than the same prepared four-plane computation without extra staging. No modifications to `raster-d` or `color-d` were needed.

**Not validated:** direct output physical alias rejection for the **original** four-plane source planes; four-plane destination atomicity; failure-atomic behavior on arbitrary final copy errors; a no-allocation caller-facing product API; real throughput for newly allocated scratch every call; runtime opacity changes without preparing a new 2-KiB table; other encodings beyond the successful experimental color fixtures; generic UI/viewports; multi-threading; or production release qualification.

**Proposed next experiments — imagery-d only:**

1. **Small ROI buffered execution:** compare prepared/direct/buffered at 16², 32², 64², 128² under identical source/pixel/ROI ownership, measuring both **reused-scratch** and **allocation-inclusive** operation costs. The already qualified small-ROI *packed zip* results cannot substitute for this general error-capable four-plane buffered path.
2. **Noalias vs snapshot choice:** deliberately construct physically overlapping **original four-plane source** and packed final target using legitimate public `RasterLease` ownership, and explicitly decide whether the contract *rejects original overlap* or *commits from a frozen prepared snapshot*. Do not claim a checked-prewrite original alias classifier that current public raster does not expose.
3. **Failure before final commit:** create negative cases for invalid opacity/PM/source interpretation and intentionally unusable final copy layouts; check both **error category** and byte-exact preservation of the final output. Distinguish classification/prewrite guarantee from unexpected late physical write failure.
4. **Memory and speed controls:** measure allocation totals separately from thread-GC bytes, including scratch lifetime/reuse and peak residency; repeat on XPS with frequency/thermal metadata.
5. **Architecture admission:** keep prepared four-plane, buffered packed and packed pure zip experiments **separate** until they can meet a single explicitly selected alias/failure/output contract; no speculative new `raster-d` API, duplicate physical affine logic or implicit `color-d` transfer change.

**Disposition:** keep `research/m3-rgba-layer-compositing` and stacked Draft PR #73 OPEN; no merge into `research-integration`, `develop` or `main`. **Only imagery-d may be edited.** The measured commit is `80415be3...`, and subsequent documentation commits require their own exact-HEAD CI verification; do not conflate prior successful smoke gates with those checks.
