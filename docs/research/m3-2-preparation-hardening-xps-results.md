# M3.2.13 — Independent Dell XPS setup-challenge qualification

**Date:** 2026-10-12 (Europe/Vienna). **Status:** XPS evidence analysed; performance mechanism partially qualified, **not** a production/consumer break-even approval.

**Issue:** [#48](https://github.com/alex-1974/imagery-d/issues/48). **Research PR:** [#49](https://github.com/alex-1974/imagery-d/pull/49), stacked on M3.2.12 and deliberately left open. No sibling repositories modified.

## Provenance and evidence limits

- Uploaded local archive: `setup-challenge-20261012T062329Z.tar.gz`, independently SHA-256 checked: `d2e719e578ba0a64d356ee3db94e4034787a36d2f98c0006b3e349f2cf431189`.
- Measured imagery commit: `80c92d78e6d4f560fd4e679dcf759a3e236f9b84` on `research/m3-2-preparation-hardening`.
- Local raster dependency commit: `1ea67cb6ffb2c887f78d160249a293ad74ba5cda`; the `v0.2.0` tag instead peels to `2f2415851e45001df92ce56dad409f680684ba8d`. **Local-state research**, not pinned-tag performance.
- Dell XPS 15, Intel i7-9750H (6 cores / 12 hardware threads), Ubuntu x86-64 kernel `6.17.0-22-generic`. LDC `1.41.0` (frontend 2.111, LLVM 19.1.7), DUB `1.40.0`; `dub build --compiler=ldc2 --build=release --force`.
- Five separate processes, 12 timed rounds each for 3/17/64/256 channels, 20,000 setups per measurement, two warm-up rounds; OS-default CPU affinity, `powersave` governor. At recorded system snapshot: 14 GiB RAM, 11 GiB used, 4.0 GiB swap essentially fully occupied. CPU-frequency, temperature, GC and memory-pressure effects were not experimentally controlled.
- Repository status in captured environment: imagery had untracked DUB selections/executable only; raster had pre-existing untracked experiment and benchmark binaries. No tracked source modification appears in the captured `git status --short`.
- `timed-binary.sha256` records `8c9d4ca64e0b5c9c50be227e316f1ac66a7094f52395c9ba5a96a1c5e42f3cf8`, but the executable **was not supplied**. Its byte hash therefore cannot be independently recomputed from the archive. The archived symbol table and disassembly are available for inspection.

## Independent integrity audit (not the repository analyser)

The raw `run-0.log`–`run-4.log` rows were parsed independently and compared field-for-field with `setup-challenge-raw.csv`. The expected selector checksums were recomputed directly using a separately implemented unsigned-32-bit LCG, including the two warm-up rounds, rather than trusting the archive's `expected` column or the original Python analyser.

**PASS:** 5 processes; 240 complete four-route cycles; exactly 960 unique measurements; 60 records per (channel count, mode); 20,000 iterations in each; independently reproduced checksum for all 960 rows; every slot/mode matches the rotating schedule; 15 appearances of each (channel count, mode, execution slot) combination, hence exact balance. The 16 reported medians and MADs agree with independently recomputed values. No missing or duplicated process/round/mode/slot tuple was detected.

All four local LDC positive/negative suites reported their intended passes. Crucially, the exact M3.2.9 forged `PreparedSemanticMap(ResearchCheckedExecution.init)` call fails at `app.d(797,35)` because `PreparedSemanticMap.this` **is not accessible**, not because of an obsolete constructor arity. The M3.2.6 owner/validity/metadata/ROI escape checks and M3.2.11/12 private constructor barriers are also present. This local run only used LDC 1.41; the four-compiler CI for the original measured head was separately green at [run #38174882863](https://github.com/alex-1974/imagery-d/actions/runs/38174882863).

## Measured costs (nanoseconds per preparation)

Each median and median absolute deviation (MAD) is computed from **60 block averages**, not from 1.2 million independent timing samples. Each block average times 20,000 calls. Ordering rotates; host/process drift remains visible. Method names describe the benchmark's source routes, not guaranteed costs for fully materialized public consumer objects.

| Channels | Method | Median ns | MAD ns | Five process medians, ns (process 0–4) |
|---:|---|---:|---:|---|
| 3 | borrow_validate | 8.503 | 0.733 | 8.842 / 7.770 / 8.637 / 9.828 / 8.518 |
| 3 | immutable_verify | 8.113 | 0.593 | 8.110 / 7.520 / 8.363 / 8.152 / 8.148 |
| 3 | unified_binding_only | 35.858 | 2.973 | 32.280 / 34.055 / 35.948 / 38.495 / 49.138 |
| 3 | snapshot_and_verify | 110.290 | 10.367 | 106.020 / 101.528 / 108.140 / 115.480 / 137.472 |
| 17 | borrow_validate | 14.727 | 1.852 | 14.505 / 12.773 / 13.053 / 15.227 / 17.808 |
| 17 | immutable_verify | 14.168 | 2.388 | 12.700 / 13.890 / 11.780 / 13.855 / 16.032 |
| 17 | unified_binding_only | 36.662 | 4.552 | 35.540 / 32.457 / 34.055 / 37.302 / 50.642 |
| 17 | snapshot_and_verify | 242.845 | 11.180 | 231.623 / 238.285 / 243.645 / 241.925 / 258.217 |
| 64 | borrow_validate | 30.075 | 2.585 | 27.475 / 29.655 / 29.280 / 30.532 / 44.767 |
| 64 | immutable_verify | 30.108 | 2.715 | 29.887 / 29.332 / 29.765 / 29.003 / 45.002 |
| 64 | unified_binding_only | 33.733 | 1.920 | 31.332 / 33.535 / 33.280 / 33.010 / 47.508 |
| 64 | snapshot_and_verify | 363.163 | 16.070 | 336.497 / 359.325 / 363.548 / 362.548 / 425.015 |
| 256 | borrow_validate | 150.220 | 6.438 | 147.713 / 166.327 / 149.495 / 150.220 / 148.988 |
| 256 | immutable_verify | 152.668 | 8.810 | 146.595 / 160.695 / 148.812 / 153.655 / 143.088 |
| 256 | unified_binding_only | 34.895 | 3.915 | 33.250 / 45.260 / 34.765 / 34.758 / 33.085 |
| 256 | snapshot_and_verify | 1221.585 | 55.640 | 1188.787 / 1371.983 / 1215.023 / 1269.795 / 1156.992 |

**Paired observations:** within the same process/channel/round, the median `snapshot_and_verify - immutable_verify` is 102.28 / 229.28 / 332.60 / 1066.80 ns for 3/17/64/256 channels. `borrow_validate - immutable_verify` is only +0.27 / +0.28 / +0.35 / −0.26 ns, close to noise for this host. At 256 channels, the paired `unified_binding_only - immutable_verify` median is −115.01 ns. These routes do **different semantic work**; a lower cost does not establish interchangeable APIs.

The highest-process medians are not uniformly in the same process across channel counts. For example, process 4 reports binding 49.138 ns at three channels versus 32.280 ns in process 0; snapshot at 64 channels spans 336.497–425.015 ns by process. With almost-full swap and uncontrolled frequency/GC, these are distributions, not intrinsic constant timings.

## Actual LDC codegen and anti-hoisting audit

Inspection of the supplied `symbols.txt` and `disassembly.txt.gz` finds four distinct non-inline wrapper symbols and direct calls to each from the timed `runPreparationChallenge` loop. The loop performs a runtime 32-bit LCG multiply by `0x19660d`, add `0x3c6ef35f`, then selects among eight metadata-array entries. A single universal precomputed checksum or fully hoisted setup is **not** what this disassembly executes.

| Wrapper | Observed instructions | Important limitation |
|---|---|---|
| `challengeBorrow` (`0x2c6c0`) | Bounds/length checks and an actual channel-ID comparison loop; returns first intrinsic ID | No observed scale/offset loads in this optimized wrapper. Construction not retained beyond checksum-required behavior. |
| `challengeVerify` (`0x2c700`) | Actual channel-ID comparison loop; returns first ID | Full validated image object not consumed; optimization prunes result materialization and other unchecked-by-checksum state. |
| `challengeBind` (`0x2c740`) | Calls `ResearchVerifiedSemanticImage.tryPrepare` at `0x25d10`, checks error and prepared marker | Verified input stays the **same prebuilt image** (`stableIds[0]/stableMeta[0]`); three selector-driven binding permutations rotate, but only a **success bit** enters the checksum, never selected data/scale/offset or pixel result. |
| `challengeSnapshot` (`0x2c7c0`) | Two `gc_malloc` calls and two `memcpy` calls, then tail-call into `challengeVerify` | Measures real snapshots but with the same optimized-down postcopy verifier. GC activity is not isolated or controlled. |

The `tryPrepare` disassembly contains index uniqueness/range tests and selected channel-calibration checks; it does not make a full linear metadata-ID pass. Therefore the targeted claim *"the timed 256-channel verification loop still runs while the already-verified binding has O(1) channel-count work"* is supported. A stronger claim *"all production preparation work, including fully observed calibration and initialized return objects, has been forced by the checksum"* **is not** supported.

The eight metadata sets have distinct stored ID/scale/offset data, but the optimized borrow/verify wrappers consume the **ID** and not their scale/offset values; binding uses only the fixed verified set 0. Source-level input variation is not equivalent to forcing optimizer-visible consumption of all the varying fields. Treat this as a benchmark-methodology limitation to repair before release-grade setup numbers.

## Relationship to previous XPS evidence and illustrative amortization

M3.2.12 earlier reported binding-only **19–20 ns**, `immutable_verify` about **89 ns** at 256 channels, and two `.idup` snapshots plus verification about **7325 ns**. This M3.2.13 challenge instead shows **34.895 / 152.668 / 1221.585 ns**, respectively. Their compiler, setup visibility, observation, input choices, and run conditions differ; they are **not** paired interversion measurements. In particular, the much lower new snapshot number must **not** be presented as a 6× optimization or a corrected consumer allocation cost.

For perspective **only**, using M3.2.12's *separate full-pixel* 256-channel, 8×8 experiment: interleaved one-shot 779.2 ns vs prepared 612.5 ns (166.7 ns saved per ROI); planar+validity 829.2 vs 645.8 ns (183.4 ns saved). Adding distinct M3.2.13 setup medians yields *non-qualified arithmetic scenarios*:

- Pre-existing immutable descriptors, measured verification 152.668 ns + binding 34.895 ns = **187.563 ns**: `ceil(187.563 / 166.7) = 2` or `ceil(187.563 / 183.4) = 2` ROIs.
- A hypothetical required two-array snapshot, measured snapshot+verify 1221.585 ns + binding 34.895 ns = **1256.480 ns**: `ceil(1256.480 / 166.7) = 8` or `ceil(1256.480 / 183.4) = 7` ROIs.

**These counts are not observed consumer break-even thresholds.** They combine different experiments and source versions, assume matching semantics and stable marginal timings, and the checksum-shaped setup wrappers omit production-relevant object/calibration consumption. No combined end-to-end prepared-once-versus-one-shot consumer reuse series was measured. Earlier `~43 ROIs` is likewise only a scenario based on the older `.idup` probe; this run does not supersede it as a release rule.

## Decision and follow-up

**Qualified as research:** local XPS long-sample harness ran, raw data and independent deterministic oracle agree; the selected compiler executes genuine channel-ID validation loops and GC-backed snapshot copying, while the verified bind uses indexed O(1) preparation without a second channel-ID scan. Correct current private-constructor denial remains verified.

**Not qualified:** exact production setup/full-result costs, GC-controlled snapshot cost, absence of any optimizer-dead-code reduction, pinned `raster-d v0.2.0` speed, universal performance claim, public API, or release break-even.

**Next focused gate:** make the benchmark consume relevant *values* of the prepared plan/metadata or execute a strictly bounded representative prepared consumer operation with setup and mapping separately accounted. Retain independent checksums and four-path ordering; make false `balanced_slots` a hard analyser failure and add a negative fixture; qualify allocation/GC, affinity, frequency, and pin raster only in an isolated checkout. Rerun exact gates on new heads. Keep all prior M3.2 research evidence and stacked PRs; do not merge this branch into `develop`.
