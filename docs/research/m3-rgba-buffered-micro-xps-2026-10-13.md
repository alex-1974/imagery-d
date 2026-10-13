# M3 RGBA — Buffered allocation versus scratch reuse, native XPS micro-ROI (2026-10-13)

**Status:** research evidence only; Draft PR #73 remains stacked on #69. No production promotion or merge.

## Provenance and integrity

- Evidence archive: `alloc-micro-20261013T202403Z-micro-recovered-f64b1a1.tar.gz`
- Archive SHA-256: `f0556d35f215d3dce75c59b4f758b4a32c19bbd8cb8532625d36d3d7c6323f27`
- Native measurement started 2026-10-13T20:24:03Z on Dell XPS 15, Intel i7-9750H, Ubuntu x86-64, LDC 1.43.0 release / DUB 1.42.0.
- **Measured imagery-d code:** `89f7e435200154b0ffd6430ac62239490704424a`.
- **Recovered CSV parser and analysis branch before this report:** `f64b1a12a8faac2e9a4566306b82499673a8a31a`. This fix reran only the Python-derived `MICRO_COMPARISON.csv`, **not** the timed D benchmark.
- Exact pinned dependencies: `raster-d v0.2.0` at `2f2415851e45001df92ce56dad409f680684ba8d` and `color-d v0.2.0` at `3359f08f4e83941ac1a8451cadefb146b5736019`. No changes to either repository.

Independent inspection of the uploaded tar archive rechecked **16/16 original CSV SHA-256 hashes**, **1,120** full raw timing rows (16 independent cases × 7 paired rounds × 10 stages), **160** stage summary records and **112** per-comparator within-round pairs. Every raw stage logged zero current-thread GC byte delta. There are no missing/duplicate stages or differing canonical output checksums across layouts. All 16 derived comparison rows match fresh calculations from the raw rounds at the advertised precision. Each file has the intended comma-separated PASS trailer, including `prepared_init_us=`. Pixel equality is attested by the *benchmark's internal reference check*, not separately re-executed from this archive.

## Measurement contract

Resident source images are 512², with actual offset ROI `Region2D(5,7,N,N)` for N=16,32,64,128; mixed alpha versus transparent-with-nonzero-hidden-RGB patterns; planar versus interleaved. Each case is a separate process. One stage timing covers **24 calls**, not one call. Normalized ns/px = median batch microseconds × 1000 / (24 × N²).

- **Prepared:** checked runtime-opacity LUT with four-plane output.
- **Reused:** same prepared mathematics, four-plane scratch, packed scratch and one public `raster.copyInto` to independent final packed target; **scratch allocated before timing**.
- **Allocating:** same operation, but both native scratch owner allocations and destruction occur **inside** the measured call; final target and prepared LUT still reused.
- Scratch payloads are 4+4=**8 bytes per ROI pixel** (2/8/32/128 KiB at N=16/32/64/128). Native `malloc` traffic is **not accounted for** by the GC byte statistic.
- Pair ratios are computed from timings **inside the same process and round**, with the **median of seven paired ratios** reported; *not* ratios of unrelated aggregate medians.

## Complete allocation-vs-reuse matrix

Columns Prepared, Reused and Allocating are **ns/pixel** (median stage time); `Reused/Prepared` and `Allocating/Reused` are **paired per-round median ratios**. Last column is the minimum–maximum within-round allocation/reuse ratio. Above 1 means more time.

| Pattern | ROI | Layout | Prepared | Reused | Allocating | Reused/Prepared × | Allocating/Reused × | Allocation pair range × |
|---|---:|---|---:|---:|---:|---:|---:|---:|
| mixed | 16² | interleaved | 117.839 | 126.628 | 127.767 | 1.07438 | 1.00774 | 1.00371–1.01554 |
| mixed | 16² | planar | 128.418 | 141.764 | 177.572 | 1.03083 | 1.02897 | 1.00521–1.54228 |
| mixed | 32² | interleaved | 118.693 | 123.169 | 126.221 | 1.04856 | 1.02328 | 0.98457–1.08370 |
| mixed | 32² | planar | 116.821 | 122.681 | 125.814 | 1.05476 | 1.01234 | 0.99618–1.03014 |
| mixed | 64² | interleaved | 126.546 | 132.935 | 133.840 | 1.05217 | 1.00362 | 0.99897–1.24430 |
| mixed | 64² | planar | 120.138 | 128.296 | 127.075 | 1.06791 | 0.99895 | 0.98868–1.00333 |
| mixed | 128² | interleaved | 122.719 | 126.915 | 128.133 | 1.05380 | 1.00878 | 1.00592–1.01919 |
| mixed | 128² | planar | 117.826 | 123.670 | 125.397 | 1.05960 | 1.01080 | 0.99128–1.02713 |
| transparent | 16² | interleaved | 48.503 | 56.641 | 58.105 | 1.16388 | 1.02000 | 1.00568–1.09281 |
| transparent | 16² | planar | 54.850 | 57.292 | 61.035 | 1.01734 | 1.03693 | 0.88550–1.18072 |
| transparent | 32² | interleaved | 46.468 | 52.531 | 54.281 | 1.14572 | 1.01599 | 1.01096–1.05113 |
| transparent | 32² | planar | 47.201 | 54.810 | 56.519 | 1.15099 | 1.01747 | 0.99784–1.06881 |
| transparent | 64² | interleaved | 45.502 | 52.144 | 52.897 | 1.14241 | 1.01424 | 0.99922–1.03062 |
| transparent | 64² | planar | 47.262 | 55.023 | 55.522 | 1.16423 | 1.01057 | 1.00439–1.07173 |
| transparent | 128² | interleaved | 49.540 | 56.684 | 57.335 | 1.13730 | 1.00947 | 0.99583–1.03054 |
| transparent | 128² | planar | 49.464 | 56.699 | 56.300 | 1.14870 | 0.99973 | 0.99296–1.01875 |

Most allocation/reuse paired medians imply around **0–4% extra time** for new scratch allocation and destruction in this one XPS session. Negative small measured effects are plausible noise, not evidence that extra allocation is advantageous. Buffered repack/copy adds around **5–7% versus Prepared for most mixed-alpha cases**, and around **14–16% for most transparent cases with ROI at least 32²**. Transparent is a special faster arithmetic workload; never present its relative factor as a general photographic-image result.

**Important outliers:** `mixed/planar/16` has allocation/reuse median `1.02897`, with one round at `1.54228`; `mixed/interleaved/64` reaches `1.24430`. Particularly for mixed/planar/16, separately aggregated allocating/reused ns/px (177.572 versus 141.764) would misleadingly suggest ~25% overhead, whereas the *correct paired median* indicates ~2.9%. Do not pool correlated rounds or derive automatic ROI cutoffs.

## Resource observations and limits

- CPU governor was **powersave** on all 12 logical CPUs. No sampled effective frequencies, thermals, affinity control or second independent session is archived.
- At measurement start the host reported `MemAvailable=3,491,484 kB`, `SwapTotal=4,194,300 kB`, and **`SwapFree=236 kB`**. Almost-full swap is not proof of active swapping.
- Per-case GNU time resource logs show **maximum RSS 50,784–51,516 KiB per process**, median 51,058 KiB; these are whole-process peaks, **not** the bytes attributed to Scratch.
- All 16 cases report **zero major page faults and zero filesystem input blocks**, although system/CPU interference remains possible. Prepared LUT setup outside timed stages: 17–25 µs, median 20 µs.
- Percent differences around ~1% require caution, even with 24-call batches, because this is one host session with correlated rounds. No stable production threshold or causal independent-allocation cost is established.

## CI and research decision

At exact pre-report analysis HEAD `f64b1a12...`, **five PR-triggered GitHub workflows succeeded**. [Stage attribution run 38464036473](https://github.com/alex-1974/imagery-d/actions/runs/38464036473) had successful jobs on DMD 2.112.1 / 2.113.0 and LDC 1.42.0 / 1.43.0; the LDC 1.43.0 pinned `--micro-smoke` and CSV regression-test step passed. The available connector checks PR-triggered runs, **not** the full independent push-run count. This report commit, if subsequently published, will require new exact-HEAD checks before any eventual integration decision.

**Outcome:** Retain caller-reusable scratch as an optimization candidate and buffered packed commit as a separate researched failure/prewrite policy; do not establish dispatch thresholds yet. The `raster.copyInto` alias check covers **packed scratch versus target**, not **original four-plane sources versus target**; the latter remains **BLOCKED** by an as-yet unproven legitimate shared owner/typed view representation. No forged double ownership, universal transactionality claim, production API, merge or sibling repository write is authorized.

**Next evidence:** independently repeat the native matrix with frequency/thermal/affinity provenance, then consider actual repeated editor viewport workloads and only semantics-preserving reduction of repack/copy traffic. Preserve the original checksummed CSV archive externally; it is not committed as a large binary.
