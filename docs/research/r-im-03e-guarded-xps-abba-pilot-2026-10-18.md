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

## Recovery after first native prepare failure — 2026-10-18

**Observed native XPS output, transcribed from user terminal:** The original helper fetched the research imagery checkout and a pinned raster-d checkout, then printed `RIM03E_COMMAND=prepare TIME=2026-10-18T10:42:54Z PACKAGE=140637 CORE0=36523`, followed by `RIM03E_ABORT=prepare:exit_3_temp_53000_pkg_140637_core_36523`. The CPU Package was **53°C**, both package/core0 thermal-throttle counts were **unchanged during the command**, and the child returned **exit code 3**. **This is a filesystem/checkout execution failure, not a thermal trip or a D benchmark result.** No `RIM03E_PREPARE_OK` or `prepared.ok` was produced, hence the subsequent attempted `pilot` correctly refused to run. That user subsequently supplied **literal placeholder path** `/PFAD/ZUM/RIM03E_OUTPUT`, not an actual output directory.

**Code-level root cause:** the original helper called `bash "$OUT/imagery/tools/research/compare_r_im_03e_codegen.sh"` **without changing its working directory**. The invoked comparer uses `git rev-parse --show-toplevel` and requires `$REPO/deps/raster-d`, per its own documented usage contract. Because the user was inside their ordinary `d-geospatial-workspace/libs/imagery-d` checkout, the comparer identified **that** Git root rather than the fresh `$OUT/imagery` root, and could exit **3** at the missing pinned dependency check. The **exact last log line of this user's `prepare-build.log` has not yet been provided**, so this is a strongly code-supported diagnosis rather than a claim to have inspected the user's on-disk log.

**Correction:** the helper now launches the comparison as `bash -c 'set -e; cd "$1"; exec bash "$2" "$3" "$4"' _ "$OUT/imagery" ...`, with an explicit cwd independent of the user's currently open terminal. On any new unsuccessful attempt it prints the last 30 lines of `prepare-build.log`, preserving the original file. New CI invokes the same exact wrapper from `$RUNNER_TEMP`, not its repository root, so a recurrence of the wrong-cwd bug fails the existing paired LDC codegen jobs.

**Preserve already cloned work:** `resume` is a separate, narrowly permitted action. It will only reuse a previously created output folder with an intact isolated imagery/raster Git clone, matching source/dependency commits and compiler receipt, a logged `prepare:exit_3` failure, no `prepared.ok`, and no old `build/pair` tree. It does **not** delete the initial `receipt.log`, source checkouts or the original build failure log; it appends a resume receipt, then builds into the still-vacant `$OUT/build`. Any other failure requires diagnosing the original logs or creating a **new** output directory – never silently deleting or overwriting unknown work.

Example: find the existing result directory rather than inventing a path and use the **new fixed script from its exact SHA**, not the old downloaded script:

```bash
find "$HOME" -maxdepth 1 -type d -name 'imagery-rim03e-abba-*' -print
bash "$HOME/imagery-rim03e-pilot.sh" resume "/ACTUAL/ABSOLUTE/OUTPUT/PATH" ldc2
```

Do not run the subsequent `pilot` until `resume` prints `RIM03E_PREPARE_OK`, and cooling/backup checks are acceptable. If the user requests a fresh run rather than resuming, choose a new output path; preserve the original aborted folder for audit.

## Second native prepare: thermal stop and CI-prebuilt alternative — 2026-10-18

**Native user terminal evidence, distinct from first git-CWD failure.** The user's exact failed output path is `/home/alexander/imagery-rim03e-abba-20261018T104249Z`. Its preserved `prepare-build.log` originally contained:

```text
fatal: Not a valid object name 68ddbdefc5b9cfefd95fe8545ba4848fc5736beb^{commit}
ERROR: exact revision 68ddbdefc5b9cfefd95fe8545ba4848fc5736beb unavailable (fetch full history)
```

**Clarification:** this was emitted from the **wrong cwd** by the original comparer (running against the user's existing workspace checkout). It does **not** establish that the fresh isolated `$OUT/imagery` clone lacked the exact baseline commit; the corrected invocation reached its baseline source hash.

The user then downloaded and ran the corrected `c46e653452e4751682323be364ada08feb409c85` helper with `resume`:

```text
RIM03E_RESUME=/home/alexander/imagery-rim03e-abba-20261018T104249Z TIME=2026-10-18T15:17:12Z
RIM03E_COMMAND=prepare TIME=2026-10-18T15:17:12Z PACKAGE=141553 CORE0=36640
RIM03E_ABORT=prepare:new_thermal_throttle_transition
RIM03E_PREPARE_FAILED: last 30 lines from prepare-build.log:
  ... LDC LLVM target listing ...
  DUB version 1.40.0 ...
  RIM03E_BUILD=both variants same toolchain, dub release, no boundscheck weakening
  RIM03E_SOURCE_HASH,baseline,8f506544207993e0539dd99ed4552ad4e78b1988a77b7981fc10c4f603571357
  RIM03E_BUILD_BEGIN,baseline
```

**Result:** the corrected checkout/candidate source retrieval and baseline entry succeeded, but the thermal monitor saw at least one new package/core0 throttle counter transition **during compilation**. The monitor aborted **its own** child process group; no successful D source pair, `prepared.ok`, ABBA pilot, or native runtime measurement exists. The exact highest temperature and new event count **cannot be inferred** from these selected output lines; the owner’s `telemetry.csv` remains on their machine. The existing `resume` is intentionally not reusable once a partial `$OUT/build/pair` tree exists; do **not** delete this aborted data and retry compilation by weakening safety gates.

**Research decision:** stop asking this thermally sensitive XPS to compile both D variants. Instead publish the existing exact-revision LDC **1.41.0** CI Release builds as a *pair* of Linux x86-64 ELF binaries with an accompanying **two-file SHA-256 manifest and source pin / compiler provenance**. This does not alter the D kernels or duplicate them; it relocates compilation to the hosted CI. The new [`tools/research/import_r_im_03e_ci_pair.sh`](../../tools/research/import_r_im_03e_ci_pair.sh) consumes an **unpacked, specific completed GitHub Actions artifact**, refuses altered hashes / wrong source, LDC or dependency SHA, imports binaries into a **fresh, isolated** `$OUT/build/pair/{baseline,candidate}/...` path, and writes the pre-existing pilot `prepared.ok` and executable receipts. It does **not** execute the programs. The hosted CI uses this importer and tiny **semantic-only** u16 masked smoke on both imported binaries and a deliberate corrupted-binary rejection; all hosted timings are ignored.

**Scientific portability caveat:** these builds use Ubuntu 24.04 x86-64 hosted runner toolchain instead of compiling on the XPS. A build manifest and ELF hash are **not** proof of runtime portability: the eventual owner must inspect `file`/`readelf -d`/runtime shared libraries on the XPS and verify the tiny semantic consumer execution before any timed ABBA runs. Both variants use the **same CI toolchain/build flags and host**; measurements later taken on the XPS are the only eligible *XPS runtime* evidence. The original local compiler platform would be preferable only on an adequately stable, safely cooled development machine. The user’s original aborted build evidence remains intact and important.

### Verified CI-built D pair: actual artifact and import receipt

At source branch HEAD `37415dcf3f761dd4ae8deb9992101a90e8adc482`, [push Actions run #39140220532](https://github.com/alex-1974/imagery-d/actions/runs/39140220532) and [PR Actions run #39140223747](https://github.com/alex-1974/imagery-d/actions/runs/39140223747) each completed **7/7 SUCCESS**, including four independent DMD/LDC consumer jobs, LDC 1.41/1.43 codegen pairs, and the synthetic-only harness checks. The LDC 1.41 codegen CI job now **also** emits the artifact `r-im-03e-prebuilt-pair-ldc-1.41.0`. This is **not** a performance evidence receipt.

**Exact official push-run artifact:** GitHub Actions artifact **12140449742**, ZIP SHA-256 `ce2e0b42233103996cbd8f5e59ea2b268e1898a2dc8efc430e55540730b18184`, with two executable digests:
- `baseline`: `a7dab96b73d40fa7d6ce2b54b3d0b3fca529714ee4b8fd79d2ececa7115e3de9`.
- `candidate`: `8ca7b74308762ee91d775586f24cd30ef59df14ee08c5787e1cdd9d9ebf2a9cd`.

The ZIP's `SHA256SUMS`, `provenance.log` and both ELF payloads were independently inspected: **sha256sum -c PASS**, `file` identified each as **Linux x86-64 ELF64 PIE**, and `readelf -d` found only `libm.so.6`, `libgcc_s.so.1`, `libc.so.6` and Linux ELF interpreter as listed NEEDED dependencies for baseline. The user’s Ubuntu 24.04 still must verify runtime loader/ABI availability on their actual host. The CI also executed an un-timed tiny u16 masked smoke for **both** imported programs, checked the matching semantic fields, and verified the importer rejects an intentionally modified binary.

**No need to rebuild these D sources on the XPS.** From a terminal authenticated to `gh`:

```bash
BUNDLE="$HOME/imagery-rim03e-ci-artifact"
OUT="$HOME/imagery-rim03e-prebuilt-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BUNDLE"
gh run download 39140220532 --repo alex-1974/imagery-d \
  --name r-im-03e-prebuilt-pair-ldc-1.41.0 --dir "$BUNDLE"
(cd "$BUNDLE" && sha256sum -c SHA256SUMS)
# Download/import only the exact audited research importer script:
bash /path/to/import_r_im_03e_ci_pair.sh "$OUT" "$BUNDLE"
```

The **import** phase checks expected sample/repository/compiler pins and SHA-256s, then writes isolated expected `$OUT/build/pair` paths and `prepared.ok` without running images or building code. The separate **pilot** still requires the original guarded helper (corrected research SHA `c46e653452e4751682323be364ada08feb409c85`) and should only occur after hardware/thermal readiness and runtime dependency checks. Preserve `~/imagery-rim03e-abba-20261018T104249Z` and its `prepare-build.log`/`telemetry.csv` as **aborted data**, not an unfinished pair to silently overwrite.

Artifact retention is **30 days**. Artifacts from another CI run may contain different executables even with the same source (e.g. build IDs); do not silently substitute hashes from a different artifact. Both D implementations share one compiler/build host, so even exact hashes are **not evidence of XPS runtime performance**.

**No new native pilot result.** Draft PR #93 and Issue #94 stay OPEN.

## Validation and next decision

The existing four DMD/LDC Debug+Release consumer jobs and two exact-revision LDC codegen jobs remain required. The separate **hosted CI dry-run** for this new helper tests Bash syntax, exact commit pins, safe CLI rejection, and **synthetic-only positive/negative output parser** with a deliberate checksum corruption. Hosted CI does **not** run the pilot, cannot qualify XPS thermal safety or claim meaningful performance.

**Decision gate:** if the native pilot passes all thermal and semantic checks, inspect every raw result (especially no-mask u16 LUT and control cohorts) for consistency of direction within ABBA pairs. Treat the four tiny observations per variant as feasibility evidence only. If there is no obvious material improvement, prefer the simpler original D kernel until a broader representative test can establish benefit. If there is a possible gain, qualify later with larger balanced samples, code placement, preparation/residency and actual consumer workload on a demonstrably stable host. Do not release the specialization or compare languages based on this pilot alone.

**No public imagery-d package/API, no sibling repo modifications, no C++ translation, no changes to R-IM-03b/c/d raw historical evidence or stacked branches.** R-IM-03e stays Draft, Issue #94 OPEN until the evidence is reviewed.
