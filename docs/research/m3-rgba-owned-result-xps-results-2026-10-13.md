# M3 RGBA — Native XPS owned-result performance evidence (2026-10-13)

**Status:** independently reconciled checksummed research evidence. No production-API/merge admission. Draft PR #73 is stacked on Draft PR #69. This is **one native host session**, not a release-qualified throughput threshold.

## Archive identity and measured code

- User-provided **original XPS evidence archive**: `20261013T215728Z-owned-recovered.tar.gz`.
- Archive **SHA-256**: `b2354e77356c9ddd3fb67552bce08578f1d4f3bf921ba537505a0f6661c64ccc`.
- Run environment began **2026-10-13 21:57:29 UTC** (23:57:29 Europe/Vienna).
- **Measured imagery-d code**: `192394906d368692c3ac57c3bf5217cb8784579f`; **not** the later research-report/summary-parser branch HEAD.
- Released dependency snapshots: `raster-d v0.2.0` = `2f2415851e45001df92ce56dad409f680684ba8d`; `color-d v0.2.0` = `3359f08f4e83941ac1a8451cadefb146b5736019`. Live sibling HEADs differed in some cases, but the benchmark built the **pinned archived dependency sources**, not live HEAD. Neither sibling repo was modified.
- Dell XPS 15 / Intel Core i7-9750H, Linux 6.17.0-22-generic x86_64, **LDC 1.43.0 release**, DUB 1.42.0.
- Recovery reprocessed the **derived summary only** after the stdout-redirection/raw-name-count parser regression. The old partial `OWNED_COMPARISON.before-recovery.txt` contains only a header. No 20-case native rerun.

The independently inspected tarball has exactly **20** original raw case CSVs, all **20/20 SHA-256 checksums** match the original `CHECKSUMS.sha256`. Each CSV has its expected comma-separated PASS trailer, 7 rounds × 3 stages = 21 stage rows, with all exact round/stage keys, correct 24-iteration batches, and no duplicates. Thus **420/420** timed batch measurements and **140 paired rounds per comparison** are complete. All recorded stage-level current-thread GC byte deltas were zero. All 20 case stderr logs are empty. All seven round records within each case have a common canonical pixel checksum, and the planar/interleaved canonical checksums agree for each corresponding pattern/ROI pair. The *harness* checks all ROI pixels against the independently qualified prepared output before and after rounds; the archive's repeated checksum is not a separate re-execution of this pixel oracle. All numeric `OWNED_COMPARISON.csv` fields were recalculated from the 420 raw rows and agree at the emitted precision.

## Exact workload and comparative semantics

Two encoded-straight RGBA8 source images each have 512×512 resident pixels. Layouts are interleaved or planar; patterns are mixed alpha and fully transparent alpha **with nonzero hidden input RGB**. ROIs are 16²/32²/64²/128²/256² and rotate over (5,7), (18,23), (41,53), (71,91) within each batch. Source buffers, original contextual decoder LUT and prepared opacity are constructed outside timed batches. Stage order rotates across 7 rounds per independently launched case, with 24 **complete function invocations** per stage timing.

| Stage | Distinct contract and timed work |
|---|---|
| `prepared_reused_output` | Prepared source-over directly into a preallocated four-`ubyte`-plane output. No ROI-native allocation per call. |
| `owned_allocating_result` | Same prepared operation into a newly allocated four-plane scratch; allocate/pack a `RasterLease!SRgba8`, and publish the packed backing after success. Per call includes two native allocations and destruction/bookkeeping. |
| `buffered_allocating_final` | Exact owned-result path, then allocate a second fresh packed target and call public `raster.copyInto`. This includes **both** final-target allocation and copy, so the result cannot be interpreted as isolated `copyInto` overhead. |

These stages intentionally differ in allocation and output ownership/error semantics; a numerical speed comparison is not an API substitutability claim. Normalized `ns/pixel = median(batch elapsed_us) × 1000 / (24 × ROI pixels)`. Stage ns/px medians describe each stage separately. Ratios are **median of 7 within-round paired ratios** for one scenario; do not divide independently calculated stage medians.

## Complete per-case matrix

`Owned / Prepared` > 1 means owned allocation + staging is slower than preallocated direct output. `Buffered / Owned` > 1 means allocating an extra final target + copying takes longer than directly publishing the owned packed result.

| Pattern | ROI | Layout | Prepared ns/px | Owned ns/px | Buffered ns/px | Owned / Prepared | Buffered / Owned |
|---|---:|---|---:|---:|---:|---:|---:|
| mixed | 16² | interleaved | 114.26 | 123.54 | 127.77 | 1.0924× | 1.0329× |
| mixed | 16² | planar | 115.56 | 132.98 | 126.14 | 1.1577× | 1.0104× |
| mixed | 32² | interleaved | 106.45 | 112.18 | 114.14 | 1.0547× | 1.0071× |
| mixed | 32² | planar | 106.40 | 114.10 | 114.05 | 1.0612× | 0.9870× |
| mixed | 64² | interleaved | 105.80 | 109.90 | 109.30 | 1.0430× | 1.0013× |
| mixed | 64² | planar | 105.58 | 109.61 | 109.83 | 1.0491× | 1.0038× |
| mixed | 128² | interleaved | 105.32 | 111.26 | 109.63 | 1.0544× | 0.9987× |
| mixed | 128² | planar | 105.46 | 113.25 | 114.48 | 1.0598× | 0.9993× |
| mixed | 256² | interleaved | 107.85 | 115.74 | 115.79 | 1.0731× | 1.0009× |
| mixed | 256² | planar | 107.00 | 116.25 | 116.52 | 1.0818× | 0.9932× |
| transparent | 16² | interleaved | 47.04 | 55.83 | 66.89 | 1.2657× | 1.2263× |
| transparent | 16² | planar | 45.74 | 59.24 | 69.99 | 1.2832× | 1.1788× |
| transparent | 32² | interleaved | 45.21 | 52.29 | 52.45 | 1.1445× | 0.9910× |
| transparent | 32² | planar | 45.74 | 51.03 | 52.57 | 1.1294× | 1.0062× |
| transparent | 64² | interleaved | 43.95 | 49.65 | 49.76 | 1.1283× | 1.0035× |
| transparent | 64² | planar | 43.71 | 48.75 | 48.88 | 1.1152× | 1.0027× |
| transparent | 128² | interleaved | 43.72 | 49.75 | 49.18 | 1.1343× | 1.0027× |
| transparent | 128² | planar | 43.09 | 48.75 | 48.68 | 1.1301× | 1.0013× |
| transparent | 256² | interleaved | 43.62 | 50.56 | 51.19 | 1.1721× | 1.0086× |
| transparent | 256² | planar | 42.61 | 50.41 | 50.77 | 1.1824× | 1.0029× |

## Findings — paired statistics and limits

1. **Owned Result versus Prepared with reused output:** descriptive *median across case-level paired medians* = **+6.05%** in the 10 mixed-alpha cases and **+13.94%** in the 10 fully transparent cases. For mixed alpha with ROI ≥32², the corresponding case median is **+5.72%**; fully transparent ≥32²: **+13.22%**. All 20 individual case medians favor the reused direct output for speed. The numbers pay for different allocation/output semantics, not identical output contracts.
2. **Additional packed final allocation and copy:** among the **16 cases with ROI ≥32²**, median of the individual case-level `Buffered / Owned` paired ratios is **1.0020× (+0.20%)**; cases range **0.9870×–1.0086×**. Their direction varies. A final-copy elimination is a real structural simplification and saves one native packed-result target and a memory transfer, but this single session **does not establish a material end-to-end latency improvement for ROIs ≥32²**.
3. **Tiny 16² transparent cases:** `Buffered / Owned` paired medians are **1.2263×** (interleaved) and **1.1788×** (planar), but the interleaved seven-round range spans **0.8418×–1.3878×**, including opposite directions. Small absolute timings and drift/interference make a fixed cutoff unjustified. Mixed/planar/16 shows the same paired-versus-unpaired trap: independent stage medians (132.98 vs 126.14 ns/px) suggest buffered faster, yet paired median `Buffered / Owned` is **1.0104×**, the opposite direction.
4. Comparing `buffered_allocating_final` with `owned_allocating_result` *cannot* identify pure copy cost: that path includes creation of another malloc-owned `RasterLease!SRgba8`. Neither the previous three-buffer XPS archive nor hosted CI timing is an exact baseline for this allocation policy. No production ROI switch threshold or generic editor-speed claim is supported.

## Host and resource controls

- Scaling governor **powersave** for all 12 logical CPUs. At one start-of-run snapshot cores 0–3 and 10–11 report ~4.0 GHz, cores 4–9 ~0.8 GHz. This is not a per-case frequency trace, CPU affinity rule, or thermal record. Preserve as measurement limitation.
- `MemAvailable=4,045,676 kB`; `SwapTotal=4,194,300 kB`; **`SwapFree=52 kB`** at start. Nearly full swap does **not** imply active swapping during timings.
- All 20 GNU-time process reports have **zero major page faults and zero filesystem input blocks**; per-process maximum RSS range **5,356–6,308 KiB**, median **5,588 KiB**. This is whole-process peak RSS and **not** isolated scratch memory, which has a structural 4N byte retained owned result / peak 8N simultaneous ROI staging payload.
- Prepared LUT initialization appears as **18–71 µs** across 20 independent processes; 71 µs for mixed/interleaved/32 is an outlier. Initialization is excluded from timed stage samples and should be amortized only under an explicit consumer reuse model.
- 420 recorded thread-local GC byte deltas equal zero; this **does not count native malloc or resource-control bookkeeping**.
- `build.log` contains LDC/LLVM deprecated-intrinsics warnings from `mir-core`; actual benchmark processes produced no stderr. No source/toolchain issue is inferred from a warning alone.

## Quality and integration gate

The baseline runner HEAD `1923949...` originally had a **postprocessing** defect: shell stdout redirection created `OWNED_COMPARISON.csv` before the validator counted raw `*.csv` entries. The corrected validator + recovery script published a matching regenerated summary without rerunning native measurements. A subsequent test-only CI failure on `f6187250...` stemmed from the expectation `"manifest cases"` rather than the correct rejection diagnostic `"unexpected checksum manifest path"`; this was adjusted separately in test-only commit `60b8fbc8...`. Neither problem invalidates the checksummed native timings.

**Decision:** Candidate B is a semantically valuable **owned-output alternative**, not an established speedup over a caller-reused direct output. Its peak scratch/published residency and allocation status need explicit production contracts before any admission. Candidate A (physically certified original four-plane source against **caller-provided packed** output) remains **BLOCKED**. Keep PR #73 Draft, no merge, no sibling repo edits. Next performance gate, if still desired, is a *second independent native XPS session* with controlled CPU/thermal provenance and a representative repeated viewport source/target lifecycle; do not add an automatic dispatch heuristic from these micro ratios.

**Archive retention:** keep the original checksummed `.tar.gz` as a research/audit artifact. The repository report records its exact SHA-256 and retained derived findings; do not commit raw native evidence as binary Git history.
