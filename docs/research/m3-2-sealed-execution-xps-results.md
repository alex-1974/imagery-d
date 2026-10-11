# M3.2.11 — Dell XPS sealed checked execution: observed performance

**Status:** Complete local-state XPS research evidence and exact common-kernel
codegen check **PASS**. High-channel-count / small-ROI mapping remains
measurably faster with a private, constructor-controlled prepared executor.
**Production API, exact `raster-d v0.2.0` pinning, and a release-grade
metadata setup break-even remain DEFERRED.**

**Collected:** 2026-10-11 19:58:11 UTC.
**Operator archive:** `prepared-20261011T195811Z.tar.gz`,
SHA-256 `d5172e280e7a2f9b2b8d2210503baf482ca2c0793d5875e1969fbca8da728741`.
**Exact measured imagery source:** `45d2a82a6bfd5842a3ae6aefcc3d87908976e7b6`
on `research/m3-2-sealed-execution`. Changes since the previously
CI-qualified implementation were **research documentation only**.
**Tracked imagery worktree:** clean; two untracked generated files
(`dub.selections.json` and the benchmark executable).

## 1. Hardware and dependency provenance

- Dell XPS 15, **Intel Core i7-9750H**, 6 cores / 12 threads.
- Ubuntu Linux `6.17.0-22-generic`, release-mode **LDC 1.41.0**,
  DMD frontend 2.111.0 / LLVM 19.1.7, DUB 1.40.0.
- Governor `powersave`, **OS-default affinity**. Run-time CPU frequency,
  thermal state and interrupts were not controlled.
- Memory snapshot approximately **14 GiB total / 10 GiB in use**,
  **4.0 GiB swap in use / 20 KiB free**. This may introduce significant
  run-to-run host noise; the memory snapshot alone does not prove that
  the hot mapping pages were swapped.
- Local `raster-d` HEAD:
  `1ea67cb6ffb2c887f78d160249a293ad74ba5cda`, **not**
  exact tag `v0.2.0`
  (`2f2415851e45001df92ce56dad409f680684ba8d`).
  The raster worktree reports 17 untracked benchmark executables /
  experiment entries; prior read-only audit found no changed tracked
  source. No other repository was checked out, reset, cleaned or modified.
  DUB prints `raster-d ~release/0.2`, which is not an exact-tag claim.

## 2. Independent evidence checks

The archive contains **20 regular files**: five `run-N.log` files,
the three prepared mapping CSVs, JSON summary, analysis log,
`environment.txt`, build log, separate M3.2.6 and M3.2.9
positive/negative logs, M3.2.11 access-negative log, the common-kernel
audit, compressed disassembly, symbol inventory, empty objdump-error
log, and timed-binary hash manifest.

An **independent Python stdlib parser**, separate from the research
repository's analyzer, checked all of the following:

- **4,320/4,320** exported mapping rows are identical to the
  corresponding five process logs after CSV numeric normalization.
- **1,440/1,440 complete mapped-image triples**: one conservative
  one-shot, one verified-immutable ROI + one-shot, one sealed prepared
  mapping; 24 iterations per timed variant; identical nonzero finite
  output checksums; three distinct execution slots.
- Five processes × four channel counts (3/17/64/256) × three ROI sides
  (8/32/64) × two layout/mask combinations × 12 rounds × three modes.
  Each of the three methods occupies each slot exactly **480** times.
- All **24** published medians, median absolute deviations and
  paired-ratio medians agree with the independent recomputation
  within three-/four-decimal CSV serialization rounding.
- The 16 published setup records likewise agree with
  median-of-five per-process setup means, including the renamed
  `sealed_execution_validate_and_prepare` stage.
- Local LDC 1.41 **M3.2.6 and M3.2.9 debug/release positive
  tests PASS**; inherited lifetime/type/forgery compile negatives
  behave as expected. Both new **M3.2.11** external-access negatives
  were rejected for the **specific private function / constructor**
  rather than a missing import or arbitrary parse failure.
- Optimized disassembly has exactly **one**
  `researchExecuteCheckedPixels` definition and actual callsites
  in `mapComponentsInto` (one-shot) and `mapPrepared`
  (inlined sealed capability); the binary's local
  `common-kernel-audit.log` reports PASS.
- The four-compiler hosted [CI #38169979014](
  https://github.com/alex-1974/imagery-d/actions/runs/38169979014)
  was already **4/4 PASS**, but its 48 tiny hosted benchmark triples
  are only functional smoke, **not** XPS timing evidence.

**Important nuance:** the older M3.2.6 external-forgery fixture now
fails at a constructor **argument-count mismatch** after the
experimental constructor signature changed. This alone is not
proof of constructor privacy. The *new* M3.2.11 dedicated forge
fixture **does** fail at the explicitly **private**
`ResearchCheckedExecution.this` constructor.
A future hardening pass should update all superseded negative probes
to ensure they test the intended rejection reason rather than
merely expecting any build failure.

The reused benchmark output still labels its CSV schema
`imagery-d-m3.2.9-prepared-consumer-v1` and its summary PASS banner
`M3.2.9`, since the **same** three-mode mapped-ROI workload and
independent pixel oracle are reused. The source commit and separate
M3.2.11 privacy logs identify which version was actually tested.

### Checksum/provenance inventory

| Artifact | SHA-256 |
| --- | --- |
| `environment.txt` | `c17e1649320b65b32cf2e21c19f1fa6b53d6f7d3a3e6a29e23ca5eac6eb96671` |
| `prepared-raw.csv` | `8ab238a72d62da97cd1fdeacd7c9af59246532c147064f68eacd4ea25a98adb8` |
| `prepared-summary.csv` | `05fef9e7a7ca7fbd60ed3118e63dd49d346c761598eac50baa28351fcdc483f9` |
| `prepared-setup.csv` | `9708488da8374d06253c97f8258bcf22e466b253d9464b488b1a3c0e9c060fe3` |
| `m3211-visibility-negatives.log` | `c5c5ee1da53efd0e5738443c86af099784a4a8db4bac234f46ff086e6e83c729` |
| `common-kernel-audit.log` | `f3e8aae1a3814fd05dcd6185bef2c4ab7bb2e923f00b778f89ff2f6334ac3a02` |
| `disassembly.txt.gz` | `c3bab1cf39924f67b06dc32a902ff4cd96567c350c44a578ceda0a8afdd27b9d` |
| `symbols.txt` | `17c1b3e31faa9abbf4e5e77d84690c2255a8e1c4b55cc9ad35d401595658ce3e` |

The single `timed-binary.sha256` manifest records
`fd3b95fd560c54d66319027c2c1aa7ac2be9ebf59ae1ed2fd44c9eb07f980ade`.
The executable **bytes are not present** in the archive; the hash
and disassembly cannot be independently matched to that binary
cryptographically. This is operator-recorded provenance, not
independent binary attestation.

## 3. Actual ROI plus full-pixel mapping performance

Each observation times **24 complete synthetic image-domain maps**,
including ROI derivation, explicit three-channel selection,
`stored*0.5-4` radiometric arithmetic, independent validity
where enabled and three-plane destination writes. Every table row
contains **60 matched triples** (five processes × 12 rounds).

All timings are **marginal median ns per mapped ROI**; the last
column reports the **median of the 60 paired conservative/prepared
ratios**, *not* a ratio of marginal medians.

| Channels | ROI | Layout | Conservative ns | Verified ROI + one-shot ns | Sealed prepared ns | Old / prepared |
| ---: | --- | --- | ---: | ---: | ---: | ---: |
| 3 | 8×8 | interleaved | 550.0 | 545.8 | 545.8 | 1.0076× |
| 3 | 64×64 | interleaved | 33,560.4 | 33,639.6 | 33,804.2 | 0.9987× |
| 3 | 64×64 | planar + mask | 37,650.0 | 37,866.7 | 38,106.3 | 0.9963× |
| 64 | 8×8 | interleaved | 591.7 | 570.8 | 550.0 | **1.0833×** |
| 64 | 8×8 | planar + mask | 700.0 | 675.0 | 654.2 | **1.0675×** |
| 256 | 8×8 | interleaved | 783.3 | 697.9 | 600.0 | **1.3074×** |
| 256 | 8×8 | planar + mask | 804.2 | 720.8 | 625.0 | **1.2667×** |
| 256 | 32×32 | interleaved | 9,664.6 | 9,479.2 | 9,358.3 | 1.0280× |
| 256 | 32×32 | planar + mask | 9,293.8 | 9,200.0 | 9,075.0 | 1.0230× |
| 256 | 64×64 | interleaved | 40,543.8 | 40,952.1 | 40,835.4 | 1.0047× |
| 256 | 64×64 | planar + mask | 39,397.9 | 39,610.4 | 39,414.6 | 1.0085× |

All 24 source/channel/layout/ROI cases remain available in
`prepared-summary.csv` and the independently computed CSV summary.

Across **all 1,440 paired rounds**, sealed prepared was:
- against **conservative one-shot**: faster **981**, slower **424**,
  tied **35**;
- against **verified ROI + one-shot**: faster **849**,
  slower **528**, tied **63**.

At **256 channels / 8×8**, prepared was faster than conservative
**58/60** interleaved rounds and **60/60** planar+mask rounds.
The paired median absolute savings were **183.33 ns** interleaved
and **170.83 ns** planar+mask. The five independent **per-process
median old/prepared ratios** range **1.297–1.315×** interleaved and
**1.258–1.318×** planar+mask (one planar process is higher).

For 256 channels / 32×32, the paired benefit is ~2–3% in these
samples, and at 256 channels / 64×64 it becomes marginal.
In particular, the five 256/64×64 **interleaved** process-median
ratios straddle 1.0 (approximately
`0.9985, 0.9980, 1.0065, 1.0095, 0.9942`),
so **do not promise a consistent advantage** at that size.
At only three channels / 64×64 the prepared path is approximately
equal or marginally slower, as expected when pixel processing
dominates the control-plane setup.

Timing is quantized to 100 ns per measured group, or
approximately **4.17 ns per mapped ROI** at 24 iterations.
The 1,440 triples are **nested measurements from five runs**,
not 1,440 statistically independent XPS experiments.

## 4. Explicit setup cost after sealing

The setup benchmark runs 100 iterations per process and reports
medians of the five process-level means in ns per preparation:

| Channels | Borrow + validate | Already immutable factory | **Sealed validate + bind** | Two `.idup` snapshots + factory |
| ---: | ---: | ---: | ---: | ---: |
| 3 | 2 | 2 | **26** | 122 |
| 17 | 6 | 7 | **28** | 523 |
| 64 | 31 | 22 | **44** | 1,755 |
| 256 | 91 | 91 | **114** | 7,141 |

The **`sealed_execution_validate_and_prepare` stage is not a
3-channel O(1) binding-only operation**. It includes a new
**once-per-prepared-executor O(channelCount) full semantic-ID scan**
plus explicit binding and calibration validation. The preexisting
`already_immutable_validate` stage is a separate earlier check;
the sealed preparation stage assumes a verified image is already
available.

### Amortization illustrations (not admission thresholds)

At 256 channels, for caller-owned **mutable** descriptors explicitly
copied to immutable for this path, a nominal setup difference versus
borrowed one-shot is
`snapshot_and_validate + sealed_validate_and_prepare -
caller_borrow_validate = 7141 + 114 - 91 = 7164 ns`.

Using *paired* median 8×8 mapped savings:

- interleaved: `ceil(7164 / 183.33) ≈ 40` repeat similarly
  small ROIs;
- planar+mask: `ceil(7164 / 170.83) ≈ 42` ROIs.

If inputs are **already truly immutable**, the two `.idup` copies
are unnecessary. The additional sealed-binding stage in these
measurements is ~114 ns at 256 bands (besides the image
factory that would also be needed when preparing the verified path).
With ~171–183 ns savings per 8×8 map, an approximate first-ROI
payback becomes conceivable, but **must not be stated as a
qualified threshold**.

These illustrations ignore CPU-frequency/GC drift,
anti-hoist uncertainty, differing semantics of mutable aliases
versus immutable retained snapshots, and end-user ROI reuse
distribution. Very short measurements (e.g. 2–28 ns) may be
materially affected by compiler hoisting or D optimizer behavior.
A process-level anti-hoist experiment with independent observable
preparation results and realistic metadata invalidation/reuse is
required before any release-grade break-even rule.

### Comparison with M3.2.10 (separate XPS runs)

Prior [M3.2.10 common-kernel XPS results](
m3-2-common-pixel-kernel-xps-results.md) observed 256-band
8×8 ratios **1.3251×** (interleaved) and **1.2852×**
(planar+mask), versus today's **1.3074× / 1.2667×**.
Sealed preparation at 256 bands is reported here as **114 ns**,
whereas the earlier **binding-only** stage was **29 ns**.

**This is a descriptive difference between separate dated runs,
not a controlled regression estimate.** It is compatible with
one extra identity scan during setup, but the *timed ROI/pixel loops*
do not include setup. Frequency, thermal state, caching and load
may have changed. Do not attribute per-ROI ratio differences to
one-time preparation without a paired same-host control.

## 5. Mechanism, safety and engineering decision

**Codegen mechanism:** one `researchExecuteCheckedPixels` definition
in optimized LDC disassembly, called by both ordinary and sealed
prepared paths. The previous separate-pixel-loop confounder of
M3.2.9 remains closed. Semantic checking differs only in
the control plane: one-shot repeats it; sealed prepared performs
an extra one-time factory validation and reuses the checked
executor without per-ROI identity re-scans.

**Safety evidence:** the raw kernel is now **D module-private**;
the only valid prepared execution capability is created from
`immutable` descriptors after semantic/grid/binding/calibration
preflight. DMD/LDC visibility and constructor compile-negative
tests reject external bypass. `@safe nothrow @nogc` and DIP1000
borrow lifetime gates remain in the qualified research contract.
`ImageView` owner/data lifetimes remain external; the capability
does not secretly own backing pixels.

**Admit as research evidence:** local five-process XPS
matched mapped-image benefit for 64/256 bands and 8×8 ROIs,
plus complete scalar pixel oracles, source-specific access
controls and the single common optimized pixel-kernel callsite.

**Defer production/release API and claims:** generated snapshot
allocation semantics, actual representative consumer ROI reuse,
quantized/hoistable very-short preparation timings, unrestricted
alias/concurrency/numerical boundary tests, and exact pinned
`raster-d v0.2.0` hardware evidence remain open. Production
could co-locate the two factories to remove duplicate once-only
validation without leaking a forged capability; doing so
would itself need repeat compiler negatives, codegen and hardware
qualification.

**Workspace governance:** preserve the active stacked research
PRs/branches, no wholesale merge to `develop`, no write to
`raster-d` or other workspace repositories.
