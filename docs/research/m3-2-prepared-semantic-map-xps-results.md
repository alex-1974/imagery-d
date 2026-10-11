# M3.2.9 — Dell XPS prepared semantic mapping: observed performance

**Status:** Local XPS research performance and correctness **PASS for the recorded
source/dependency state**. Production API/kernel promotion, isolated effect
attribution, robust preparation break-even and pinned-tag release evidence
**NOT ADMITTED**.

**Evidence date:** 2026-10-11 18:55 UTC.  
**Operator archive:** `prepared-20261011T185500Z.tar.gz`
SHA-256 `11b7b5502c262f7ed1b7a4f7d732b501b02b5b316757bd27809e8eae52836e36`.  
**Measured imagery source:** `18da97fbc12ef8b57f612943849492fb94d507a0`;
branch `research/m3-2-prepared-semantic-map`, no tracked worktree edits.  
**Dependency:** local `raster-d` HEAD `1ea67cb6ffb2c887f78d160249a293ad74ba5cda`,
**not** exact tag `v0.2.0` (`2f2415851e45001df92ce56dad409f680684ba8d`).
The 17 worktree status entries are known untracked benchmark/experiment
artifacts; earlier audits showed no modified tracked raster sources.
**Platform:** Dell XPS 15 / i7-9750H, Ubuntu Linux 6.17.0-22, LDC 1.41.0
(DMD frontend 2.111.0, LLVM 19.1.7), DUB 1.40.0, release,
`intel_pstate/powersave`, OS-default affinity. At capture, the 4 GiB swap
area was essentially full.

## 1. Audit of supplied evidence

The archive contained 17 ordinary files, including five `run-N.log` logs,
`prepared-raw.csv`, `prepared-summary.csv`, `prepared-setup.csv`,
`prepared-summary.json`, local compiler positive/negative logs,
`environment.txt`, `symbols.txt`, `disassembly.txt.gz`,
`build.log` and `timed-binary.sha256`.

Independent CSV/log parsing verified:

- **4,320 timing rows**: 5 processes × 4 channel counts × 3 ROI sizes ×
  2 layout/mask cases × 12 rounds × 3 full mapping modes;
- **1,440/1,440 complete triples**, identical iteration counts (24
  mapped ROIs per timing) and identical non-NaN/nonzero checksums;
- all 4,320 raw CSV rows match the five separate process logs;
- each mode appears **480 times in each of the three execution slots**;
- `prepared_semantic_map` was faster than `revalidated_image` in
  **1,365/1,440** paired observations (75 slower), and faster than
  `verified_immutable_image` in **1,357/1,440** (83 slower).

The 1,440 comparisons are **repeated measurements nested inside five
process runs**, not 1,440 statistically independent machines/runs. All
elapsed totals are multiples of 100 ns; at 24 operations each this
means ~4.17 ns per-call quantization.

The local LDC compiler logs confirm **debug/release correctness PASS**
and expected rejections of all six earlier M3.2.6
lifetime/immutable/forgery negatives, plus three M3.2.9
owner/metadata escape and external-construction negatives. The
independent synthetic oracle checks full mapped pixels *before*
the benchmark. The GitHub four-compiler contract matrix is separately
[PASS](https://github.com/alex-1974/imagery-d/actions/runs/38165284478);
hosted timing is never used as XPS speed evidence.

Recorded file SHA-256 values:

| Evidence | SHA-256 |
| --- | --- |
| `environment.txt` | `40fc6a5ae4e06464a93d30759f7c402da4b50eb8ca2e6847e0cc6d74284281a7` |
| `prepared-raw.csv` | `f8c860296fdfeec450715c060cf3bea21ca139d04ea655ef294777eeeb3d589e` |
| `prepared-summary.csv` | `b5303c2f4e5f19adaa9df64bce0e49970ce0ded7b5216523b68834b262f8487c` |
| `prepared-setup.csv` | `f89230cf162586293adbc2c1b8b21016cb41f3d6f75cfd7e9718827688b3c223` |
| `m329-positives-negatives.log` | `b70016c8382baaca5c2fa78cb951f5dc4f09f222c8b1c5d2e8dac2addb4168c1` |
| `symbols.txt` | `8040f7bad41ed8dd2db492de49e98176a0c02b79e4fa33a1adf9ccc9a69329a3` |
| `disassembly.txt.gz` | `d8618714df7d0410ab68b2b8fc895c376c20d3061d7be1c5825fd84ee7f030e0` |

The **one** timed executable SHA-256 manifest records:
`e9f1792ac9233d98da22aa04a6b92510e0e049f64500ca9b1dc1181bcf446a83`.
The executable bytes were not uploaded, and there is no independent
second executable manifest; this is **reported binary identity**, not
independent byte-level attestation.

## 2. Mapped pixel performance

The three source-independent synthetic consumers select an explicit
three-band physical mapping (`stored*0.5-4`) and write their own
three-plane float output: conservative ROI + original one-shot kernel;
validated immutable ROI + original one-shot kernel; and prepared ROI
+ prepared kernel. Optional validity remains an independent mask.

**Median elapsed nanoseconds per complete mapping**, 60 matched
triples per table row. Speed ratio is **median of paired
old/prepared ratios**, not a ratio of marginal medians:

| Bands | ROI | Layout | Conservative ns | Verified ROI ns | Prepared ns | Paired old/prepared |
| ---: | --- | --- | ---: | ---: | ---: | ---: |
| 3 | 64×64 | interleaved, unmasked | 40,114.6 | 39,891.7 | 35,850.0 | **1.123×** |
| 3 | 64×64 | planar + validity | 46,266.7 | 46,022.9 | 39,362.5 | **1.159×** |
| 256 | 8×8 | interleaved, unmasked | 900.0 | 820.8 | 670.8 | **1.343×** |
| 256 | 8×8 | planar + validity | 933.3 | 862.5 | 637.5 | **1.474×** |
| 256 | 32×32 | interleaved, unmasked | 11,539.6 | 11,789.6 | 10,889.6 | **1.070×** |
| 256 | 32×32 | planar + validity | 11,908.3 | 11,562.5 | 9,427.1 | **1.236×** |
| 256 | 64×64 | interleaved, unmasked | 49,893.8 | 49,618.8 | 46,487.5 | **1.073×** |
| 256 | 64×64 | planar + validity | 48,043.8 | 47,568.8 | 40,975.0 | **1.172×** |

All 24 cases (3/17/64/256 bands × 8/32/64 side × two layouts)
are present in the operator's raw CSV and independent recomputation.
At 256 bands / 8×8 the prepared path won 59/60 interleaved
and 56/60 planar/validity matched comparisons. Its **five
process-median** old/prepared ratios span 1.299–1.353× interleaved
and 1.395–1.511× planar+validity; the first planar process had
substantially greater absolute runtime across **all** three modes.

**Interpretation boundary:** these are measured **whole research-path
speedups**, not an isolated effect of caching semantic validation.
At only **three bands**, 64×64 mappings still improve by 12–16%.
An O(channelCount) metadata check cannot explain this by itself;
the prepared prototype also uses a **different pixel kernel**.

## 3. Setup evidence and non-admitted break-even

Medians of five process-level means from 100 setup iterations
per process, nanoseconds per preparation:

| Bands | Borrow + validate | Already immutable factory | Prepared binding alone | Two `.idup` + immutable factory |
| ---: | ---: | ---: | ---: | ---: |
| 3 | 2 | 2 | 25 | 115 |
| 17 | 10 | 7 | 27 | 514 |
| 64 | 33 | 21 | 29 | 1,791 |
| 256 | 137 | 92 | 28 | 8,142 |

At 256 bands, snapshot+factory versus borrowed setup differs by
~8,005 ns. The observed 8×8 prepared-path *paired* per-ROI savings
are ~229 ns interleaved and ~300 ns planar+validity, giving
illustrative reuse counts of ~**36** or **27** respectively if the
snapshot were required solely to enable this path. **Not a
qualified break-even**: short measurements, code hoisting, GC/heap
state, CPU scheduling, and differing borrow/snapshot lifetime
semantics are uncontrolled. If metadata is already genuinely
immutable, there is no `.idup` surcharge to amortize.

## 4. Codegen proves a major attribution confounder

The operator-supplied x86-64 disassembly exposes the three wrappers:

- `mapConservative` at `0x28e50`, `mapVerified` at `0x28ff0`:
  both call **the same** `mapComponentsInto` at `0x25aa0`.
- `mapPrepared` at `0x29350`: calls
  `PreparedSemanticMap.tryRoi` at `0x26150` and the **separate**
  `PreparedSemanticMap.mapInto` at `0x263f0`.
- Original mapping contains an actual semantic-ID loop
  `0x25ae0–0x25af7` (descriptor stride 56 bytes).
  The prepared map does not repeat that scan.
- In this optimized binary the original mapping calls
  `ImageView.tryValidity` at `0x25cd7`, whereas the prepared
  mapping function contains **no separate call instructions**:
  its validity/sample checks are inlined. Thus per-pixel call structure,
  inlining and register/layout optimization **also differ**.

There is no support for claiming that the **entire** observed
advantage comes from one-time semantic preparation.
Byte-level disassembly-to-executable matching remains unavailable.

## 5. Engineering verdict and next evidence

**Accept as local-state research evidence:** numerical correctness of
the tested synthetic stored/physical/mask cases, four-toolchain
borrow/capability gates, complete balanced XPS timing triplets and
repeated observed advantages of the overall prepared research path.

**Reject for production now:** public `PreparedSemanticMap` API,
general consumer acceleration guarantee, allocation/GC-free owner,
single clear break-even number, and pinned `raster-d v0.2.0`
performance claim.

**Required next experiment (imagery-d only):** refactor the
M3.2.2 one-shot and M3.2.9 prepared entry points to invoke a
**single private audited pixel kernel**, with distinct preflight
strategies but identical inner-loop codegen and numerical/error
semantics; rerun the same corpus, all DIP1000 negatives and
controlled XPS codegen/timings. Strengthen the setup microbenchmark
against hoisting/measurement granularity and, if strict release
pinning is required, use a separate clean `raster-d v0.2.0`
checkout without editing the active raster research worktree.

This is research documentation only. No changes outside
`imagery-d`, and no merging to `develop`.
