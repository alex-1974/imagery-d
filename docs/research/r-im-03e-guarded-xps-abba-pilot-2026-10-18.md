# R-IM-03e — Short, thermally guarded native D-vs-D pilot protocol

**Date:** 2026-10-18. **Status:** research-only harness implemented; **NO measured XPS pilot results yet**. The purpose is to decide whether the demonstrated u16-LUT removal of a repeated `hasSelection` branch warrants an observed performance benefit and the 4.2–4.4% additional whole-executable `.text` code already seen in the [LDC 1.41/1.43 Assembly audit](r-im-03e-ldc-paired-codegen-2026-10-18.md).

**Strict language boundary:** Both implementations are **native D source**. No C++, no transliteration of C++ into D and no foreign image kernel in the benchmark. This compares the simpler original shared D implementation against the alternative D `static if (HasSelection)` specialization. Source layout, mathematical methods, `raster-d` typed borrow/ownership, independent destination views, masking and ROI are unchanged.

## Exact comparison

- Baseline image D revision: `68ddbdefc5b9cfefd95fe8545ba4848fc5736beb`.
- Candidate D revision: `ae36974af9369d7bbdbbecf9b8619d2da52e59be`.
- Same pinned `raster-d` dependency: `2f2415851e45001df92ce56dad409f680684ba8d`.
- Same **user-selected, recorded** installed LDC compiler/version and `dub --build=release --force` configuration for **both** executables, with no `-ffast-math` or bounds-check weakening. `compare_r_im_03e_codegen.sh` creates the exact pair of archived source snapshots with verified source hashes, verbose compiler logs, full binary disassembly, section sizes and recorded SHA-256 of each built executable.
- Source/destinations identical: R-IM-03c's existing self-validating independent raster-d case-order benchmark; typed u8/u16, planar/interleaved, four channels with fourth channel unselected, optional graded mask 0/128/255, preparation outside timed kernel, 4 math methods. The benchmark itself checks numerical output equality and bounded math differences before printing timing rows.
- Pilot input: **128×128**, **2 rotated rounds**, pattern **1** (integer-code entropy probe, but **not** complete 65,536-code coverage at this size), **forward** case traversal. There are 8 combinations of sample type × physical source layout × selection presence. Each process prints 8 `RIM03C_SUMMARY` rows and **64 `RIM03C_RAW` samples**. Across four separate process instances: **32 summary rows and 256 RAW timings**.
- Balanced process order: baseline → candidate → candidate → baseline (**ABBA**). `pilot-paired-microseconds.csv` contains **32 per-case-method** comparisons (medians of 4 RAW values for each revision), raw distributions and ratio; *none* are an admission-level precision performance result. Without larger repeated runs and multiple sessions, these medians are exploratory/noisy, especially at 128×128. A change of process order, CPU thermal state or cache can dominate branch costs.
- Before publishing any timing differences, the post-run parser enforces exactly 8 semantics cases and 64 RAW rows **in each** process, plus identical code diversity, optimized-method mismatch counts, LUT payload size and Phobos-output fingerprint across processes. Incomplete or mismatched output is a **FAIL**. No synthetic data enters native evidence.

## Two explicitly opt-in phases

New script: [`tools/research/pilot_r_im_03e_xps.sh`](../../tools/research/pilot_r_im_03e_xps.sh).

Run **outside the tracked workspace** into a new, explicit absolute home-directory path. The helper reads native temperature and throttle counters; it never changes governor, clocks, fan settings, `thermald`, swap, affinity or unrelated processes; it does not write to the user’s existing `imagery-d` or `raster-d` directories. It creates fresh pinned clones and builds only within the caller's output directory. Preparation is **not** a benchmark. A later separate `pilot` invocation is necessary to run the four tiny workloads.

```bash
# For a freshly downloaded verified copy of the script:
OUT="$HOME/imagery-rim03e-pilot-$(date -u +%Y%m%dT%H%M%SZ)"

# Phase 1 — compile both exact pinned D sources, no timed image operation:
bash /path/to/pilot_r_im_03e_xps.sh prepare "$OUT" ldc2

# Phase 2 — only when CPU thermals and background load have been reviewed:
bash /path/to/pilot_r_im_03e_xps.sh pilot "$OUT"
```

The script refuses an output location under `d-geospatial-workspace` or a non-absolute path. Preparation refuses to reuse an existing directory, the run validates its pinned `prepared.ok` and executable SHA-256 receipts, and a successful pilot refuses to rerun over its original evidence. **Retain all logs** in `$OUT`: compiler versions and verbose builds, per-build `nm`/disassembly, individual raw and summary rows, `top`, `vmstat`, interval telemetry, `receipt.log` and `pilot-paired-microseconds.csv`.

## Conservative thermal/background safeguards

The user’s XPS recorded **100°C package temperatures**, repeated throttle transitions between idle preflights, Firefox per-core contention and Déjà Dup backup load in previous experiments. A quiet 15-second observation is **not proof of sustained cooling stability**. Do not begin even this pilot if cooling/fan airflow remains suspect.

This particular exploratory protocol implements **fail-closed** thresholds chosen to avoid stressing that machine unnecessarily; **these are not hardware-manufacturer safety certifications**:

1. Require a readable Linux **`coretemp` Package id 0** millidegree sysfs sensor, CPU0 package/core thermal-throttle counters, and installed standard measurement tools. Missing data aborts.
2. Require CPU Package **below 70°C at startup**, including immediately before either compile or workload.
3. For each build or timed process, sample both thermal counters and package temperature **about every 0.5 s**; stop **only the child process group launched by the harness** if temperature reaches **85°C**, if either count increases, or if the process exceeds the allowed runtime. The build phase has a **120-second** child timeout; each timed process a **25-second** timeout. Reject nonzero exit, hot post-state or any post-run counter increment. The monitor cannot guarantee detection of sub-second temperature spikes or protect against hardware failure.
4. Before the pilot and each of its four subprocesses, check a **second `top` snapshot** for **≥92% CPU idle**, available memory **≥2 GiB**, current `vmstat` page-in/page-out **≤1024 KiB/s**, CPU temperature below 70°C and **zero** new thermal-counter transitions across that preflight. This rejects the previously observed active Déjà Dup state.
5. Do **not** forcibly kill Firefox, Déjà Dup, `thermald` or any process other than the **temporary process group created by this helper**. No `sudo`, no clearing swap, no CPU governor/fan or affinity changes. A partial aborted run remains a preserved negative result; do not silently resume it as if it were a clean pair.

**Limitations:** a thermal event that happens between 0.5 s samples will be caught by the changed cumulative counter at the next read unless sampling is interrupted; a fast heat spike may pass unobserved. This is a **low-exposure experimental guard**, not comprehensive thermal validation. Aggregate CPU idle does not exclude all per-core background interference. Source and destination allocations plus LUT setup remain outside the timed pixel loop as in R-IM-03c; they still matter for end-to-end consumer decisions. Time-correlated CPU frequencies and per-case retired instructions are **not** captured here.

## Validation and next decision

The existing four DMD/LDC Debug+Release consumer jobs and two exact-revision LDC codegen jobs remain required. The separate **hosted CI dry-run** for this new helper tests Bash syntax, exact commit pins, safe CLI rejection, and **synthetic-only positive/negative output parser** with a deliberate checksum corruption. Hosted CI does **not** run the pilot, cannot qualify XPS thermal safety or claim meaningful performance.

**Decision gate:** if the native pilot passes all thermal and semantic checks, inspect every raw result (especially no-mask u16 LUT and control cohorts) for consistency of direction within ABBA pairs. Treat the four tiny observations per variant as feasibility evidence only. If there is no obvious material improvement, prefer the simpler original D kernel until a broader representative test can establish benefit. If there is a possible gain, qualify later with larger balanced samples, code placement, preparation/residency and actual consumer workload on a demonstrably stable host. Do not release the specialization or compare languages based on this pilot alone.

**No public imagery-d package/API, no sibling repo modifications, no C++ translation, no changes to R-IM-03b/c/d raw historical evidence or stacked branches.** R-IM-03e stays Draft, Issue #94 OPEN until the evidence is reviewed.
