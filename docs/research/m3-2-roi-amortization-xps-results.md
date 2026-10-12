# M3.2.14 — Independent Dell XPS consumer ROI reuse audit

**Date:** 2026-10-12; **status:** local XPS raw-evidence integrity and qualitative path behavior **PASS**, production break-even / stable GC performance / new API **NOT QUALIFIED**.

**Tracking:** [Issue #50](https://github.com/alex-1974/imagery-d/issues/50), [draft stacked PR #51](https://github.com/alex-1974/imagery-d/pull/51). Underlying implementation and already-green four-compiler functional CI remain unchanged.

## Provenance and check limits

- Uploaded archive `reuse-amortization-20261012T095252Z.tar.gz`; independently computed SHA-256 `69ccd714e61c007a8065c56177163ebc3a05786405d7fd59da7b51b1792b1ada`. Evidence files remain a user-supplied audit archive, **not committed binary evidence**.
- Measured `imagery-d` source HEAD **`ee7f00569aa58dd98badb0dd0db21399313f43bf`**, branch `research/m3-2-14-roi-amortization`.
- Local dependency `raster-d` **`1ea67cb6ffb2c887f78d160249a293ad74ba5cda`**, distinct from `v0.2.0` tag `2f2415851e45001df92ce56dad409f680684ba8d`: research on *local dependency state*, not a pinned v0.2.0 build. Existing untracked raster experiments/binaries were present; no sibling repo was modified.
- Dell XPS 15 / Intel Core i7-9750H, Ubuntu kernel `6.17.0-22-generic`, LDC `1.41.0` (DMD frontend 2.111.0, LLVM 19.1.7), DUB `1.40.0`, release build. OS-default CPU affinity, `powersave` governor. Captured memory: 14 GiB RAM, 11 GiB used and 4.0 GiB swap almost full (172 KiB free). Thermals, frequency, GC collections and allocator state were **not controlled or instrumented**.
- Five separate processes, eight timed rounds (two warm-ups), all channels 3/17/64/256, 8×8/32×32 ROI, planar+validity / interleaved without validity, immutable/mutable-snapshot policy, six reuse counts 1/2/4/8/16/32. Methods rotated within each matched pair.
- The binary SHA manifest records `f938be42563d4cbc9cfcfc99d17ed2ca84d804c4fbd3b835afea2ef66b5ceed5`; binary bytes are **not** in the archive and cannot be independently hash-recomputed. Archived `symbols.txt`, `disassembly.txt.gz`, build/negative-test logs and the observed-pixel oracle log are available.

## Independent evidence verification

The five `run-N.log` files were parsed independently and compared **row by row** with `reuse-raw.csv`. A separate Python pixel model computed stored samples, ROI origins, 8-way metadata selector, 3-way component permutation, mask and scale/offset, then verified each logged `checksum` **and** `expected`, rather than trusting their mutual equality or reusing the repository analyser.

**PASS:** exactly **15,360 unique rows** = **7,680 full matched pairs**, covering **192 paired cases** (384 mode-specific cases, 40 pairs per case), 5 distinct independent processes, 8 complete rounds per process and case, exactly 20 occurrences per (mode, execution slot) in every case. No missing/duplicate combinations; 15,360/15,360 independently modelled checksums agree with reported values within D text formatting tolerance; paired checksums agree exactly. The reported CSV medians, MADs and counts all agree with separately recomputed values. The benchmark also ran its existing independent full three-component *last-ROI* pixel oracle after timing in each batch (verified by successful program completion). All local positive and negative contract logs report intended PASS, including actual private-constructor accessibility denial. This does **not** establish full-pixel oracle checking of *every intermediate ROI*: intermediate maps are observed by their first-sample checksums.

**Timestamp granularity:** every setup, mapping and total time is a multiple of **100 ns**. Setup is printed as `0 ns` in **2,510/3,840 immutable one-shot**, **2,210/3,840 immutable Prepared**, **2,324/3,840 mutable one-shot**, but **0/3,840 mutable-snapshot Prepared** observations. This reflects stopwatch quantisation and optimisation, **not free creation/validation**. Quantised or tied small differences cannot establish sub-100-ns break-even. Timed `total_ns` includes phase and timing overhead and need not equal `setup_ns + map_ns`.

## Measured paired comparison, source-faithful units

Every number below is **nanoseconds per full batch of N mapped ROIs**, not ns/pixel or ns/ROI. The signed `Δ = one_shot.total_ns − prepared.total_ns` is the **median of 40 same-process, same-input, same-round differences**: positive means faster Prepared. Separate medians are not algebraically interchangeable with a paired-difference median.

### 8×8 planar source with validity mask

| Channels | Input policy | ROI reuse | Median one-shot total | Median Prepared total | Paired median Δ | Prepared wins/40 |
|---:|---|---:|---:|---:|---:|---:|
| 64 | immutable | 4 | 3,000 | 2,800 | +200 | 40 |
| 64 | immutable | 8 | 5,800 | 5,400 | +400 | 40 |
| 64 | immutable | 32 | 23,100 | 21,400 | +1,700 | 40 |
| 64 | mutable→snapshot | 1 | 900 | 2,400 | −1,500 | 0 |
| 64 | mutable→snapshot | 16 | 11,600 | 12,300 | −700 | 1 |
| 64 | mutable→snapshot | 32 | 23,100 | 23,100 | 0 | 19 |
| 256 | immutable | 1 | 1,100 | 950 | +200 | 23 |
| 256 | immutable | 2 | 2,000 | 1,600 | +450 | 37 |
| 256 | immutable | 4 | 3,700 | 2,800 | +900 | 40 |
| 256 | immutable | 8 | 7,200 | 5,500 | +1,700 | 40 |
| 256 | immutable | 16 | 14,200 | 10,750 | +3,450 | 40 |
| 256 | immutable | 32 | 28,200 | 21,300 | +6,900 | 40 |
| 256 | mutable→snapshot | 1 | 1,200 | 7,150 | −6,050 | 0 |
| 256 | mutable→snapshot | 8 | 7,300 | 11,700 | −4,300 | 0 |
| 256 | mutable→snapshot | 16 | 14,250 | 17,500 | −2,700 | 0 |
| 256 | mutable→snapshot | 32 | 28,200 | 27,850 | +600 | 24 |

The 256-channel, 8×8, planar, already-immutable N=32 improvement of +6.9 μs is **all 40/40 pairwise wins** and all five process-level medians are positive (6,700/6,800/7,000/6,900/6,800 ns). The separate median totals correspond to around **24.5%** lower batch time for this specific case; this is **not** a general image-pipeline speedup. At N=1, only 23/40 pairs favor Prepared; the +200-ns median is near timer granularity and is not a robust universal single-use recommendation.

With two required mutable metadata snapshots, N=32 is **only 24/40 wins** despite +600-ns paired median (five process medians are positive, but small). Thus **do not certify a reusable 32-ROI breakpoint** for small-ROI snapshot consumers.

### 256-channel, 32×32 ROI: different cost balance

| Layout/policy | N=1 paired Δ | N=4 paired Δ | N=8 paired Δ | N=16 paired Δ | N=32 paired Δ | N=32 wins/40 |
|---|---:|---:|---:|---:|---:|---:|
| Planar+mask, immutable | +300 | +900 | +1,900 | +3,700 | +8,200 | 35 |
| Interleaved, immutable | +300 | +1,000 | +1,900 | +4,350 | +9,700 | 34 |
| Planar+mask, mutable→snapshot | −1,350 | +150 | +1,100 | +3,100 | +7,900 | 27 |
| Interleaved, mutable→snapshot | −350 | +200 | +1,400 | +3,300 | +7,650 | 36 |

Larger ROIs dilute the fixed setup cost and make some previously unfavorable snapshot batches profitable **under this execution order**. At 256 channels / 32×32 / interleaved / mutable→snapshot, N=8 reports +1,400 ns (33/40 wins) and N=32 reports +7,650 ns (36/40 wins; all five process medians positive). At 256 channels / 32×32 / planar / mutable→snapshot, N=32 has 27/40 wins and **one negative process median**, despite +7,900-ns pooled median. Any ROI threshold is conditional on *channel count, ROI dimensions, layout, metadata ownership and allocation state*, not just N.

At 3–17 channels and tiny ROIs many differences are **0 or ±100 ns** and are intrinsically quantisation-limited; at 64 channels with 32×32 ROIs, even N=32 often shows small/no consistent improvement while snapshot cases remain negative. Do not extrapolate the 256-channel gain down to low channels or across ROI sizes.

## Critical reproducible snapshot-tail finding

At the **same fixed case in every one of five independent processes**—**256 channels, 32×32, planar+mask, mutable→snapshot, N=1, recorded round 2, Prepared execution slot 1**—the snapshot setup alone takes:

| Process | Setup ns | Setup milliseconds |
|---:|---:|---:|
| 0 | 773,600 | 0.7736 |
| 1 | 567,400 | 0.5674 |
| 2 | 692,800 | 0.6928 |
| 3 | 649,400 | 0.6494 |
| 4 | 835,100 | 0.8351 |

All **five** snapshots above 50 µs in the entire 3,840-observation mutable-snapshot Prepared sample occur at **this exact deterministic position**. The other 256-channel/32×32 snapshot setup samples can be roughly 1 µs, whereas the earlier 256-channel/8×8 ones center near ~6.7 µs. This source-order/allocator-state sensitivity is more important than a single median break-even number. The binary contains GC-backed snapshot allocation; however **the data do not prove that these five spikes are GC collections**. No GC event tracing, frequency trace, page-fault trace or allocation counters were collected. Thermal scheduling, heap growth, cache state and other mechanisms remain alternatives. The near-full swap makes the host condition unfavorable for generalizing tail latency.

This means a median-only statement *"snapshot is always amortized after N ROIs"* would be misleading. Report both typical paired medians and tail-risk/host-state caveats. Preserve these outliers; **do not trim them silently**.

## LDC code-generation checks

The archive `nm -anC` symbol inventory contains separate concrete noninline mapping wrappers:
- `mapConservative` at `0x28370`;
- `mapPrepared` at `0x28880`;
- actual batch `measureReuseBatch` at `0x2f910`;
- `runConsumerReuseExperiment` at `0x30860`.

The optimised `measureReuseBatch` disassembly directly calls **both** mapping wrappers from distinct branches and, in the Prepared/snapshot path, calls **`gc_malloc` twice and `memcpy`**, as well as selected `ResearchVerifiedSemanticImage.tryPrepare` at `0x25d10`. It also contains stopwatch calls for setup, mapping and total. Therefore the observed work is not just a success-bit microbenchmark: real map functions and metadata snapshot operations survive. The checksum samples and full final output are observable. The precise relative costs of GC, validation and pixels remain **compiler-, allocation- and host-state-sensitive**, and the source-level loops alone do not establish a universally fully optimised implementation.

## Decision / next qualification gate

**Accepted as reproducible research:** integrity, independent oracle, full 7,680-pair matrix, codegen path presence, 256-channel already-immutable repeated-ROI benefit, and nontrivial cost/tail risk of snapshot creation. Existing compiler/negative contract gates remain intact and green at original measured commit [CI #38230421648](https://github.com/alex-1974/imagery-d/actions/runs/38230421648).

**Not accepted:** an unconditional 1-/2-/4-/8-/16-/32-ROI break-even, an `raster-d v0.2.0` release-tag performance claim, or a production API change. Unlike the immutable policy, mutable borrow vs snapshot-Prepared have **different ownership/lifetime guarantees**.

**Next experiment:** hold the semantic workload constant while counterbalancing outer **case order**, instrument/track GC collections and allocation count/volume, collect page-fault and clock/thermal data, preferably run with materially reduced memory/swap pressure and controlled affinity. Compare process-level paired distributions and tails across counterbalanced orders; separately profile setup under a binary-verified consumer-visible result. Only after those gates consider whether a documented consumer should retain a Prepared value across many ROIs.

**No merge** of this stacked research PR into `develop`; no writes outside `imagery-d`.
