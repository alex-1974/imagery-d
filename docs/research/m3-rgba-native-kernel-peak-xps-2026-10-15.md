# M3 RGBA — native kernel-peak XPS evidence: instrument defect and disposition

**Later corrected XPS study:** The [native-C directly launched 48-process XPS measurement](m3-rgba-native-kernel-peak-c-xps-2026-10-15.md) replaces the Python-wrapper kernel high-water **method**, not the immutable raw evidence. It captures ROI-dependent `wait4` reports but still observes **9/12** cases of higher sampled `VmRSS`. Neither study is a certified all-in memory budget.

**2026-10-15 · Issue #74 · Draft PR #73 · Research-only.**

**Disposition: REJECT the original Python-wrapper `wait4` RSS peak as a D-consumer memory measure; ACCEPT its independently replayed native allocation-event evidence, with the original scope.** Retain both original archives and their provenance. The replacement native-C-wrapper experiment is **IMPLEMENTED BUT NOT YET MEASURED ON XPS**. **ADAPT** the measurement method; **DEFER** the all-in memory budget, API admission, PR merge and release.

## Frozen uploads and independent replay

| User-delivered file | Role / capture UTC | Archive SHA-256 | Manifest entries verified | Correctly replayed processes | Recomputed paired rows |
|---|---|---|---:|---:|---:|
| `20261015T125436Z.tar.gz` | smoke, 2026-10-15 12:54:36 | `ae10661b9fededab7adc99759a8f7ea26a8ffb76960db43e4c9dd6aa3d05821e` | **63/63** | **8/8** | **8/8** |
| `20261015T125447Z.tar.gz` | full, 2026-10-15 12:54:47 | `a2175bb95f514cca696169f5446f839cce0fd6417ddd5c1cb180f556fb9672a3` | **343/343** | **48/48** | **48/48** |

The 56 traces reproduce all native nine-stage record-contract outcomes under the
frozen validator, and all **56 stage CSV outputs are byte-for-byte reproducible**.
The wait4 receipts and per-run summary fields, separate stdout/stderr, and
pairwise requested-byte/OS-peak deltas are internally consistent with the
original Python capture method. All 56 stderr files are empty; both
capture/summary self-test receipts PASS. **Correct file integrity and
replay do not imply validity of the experimental measurement construct.**
The older independent nine-stage native allocation studies already
qualified the request-peak numbers; this upload does not add new
source attribution.

Each archive has 419 regular **`snapshot/`** files that are **not
individually covered by its payload manifest**. The whole-file archive
digest binds the supplied bytes. No unsafe absolute or `..` member
paths or links were detected, and no extra unmanifested regular
*non-snapshot* payload files were found beyond the manifest and
checksum-verification log.

All provenance entries in both reports identify:
`imagery-d 4323b81ce36cfc84237ccc3fb20a3edffff7ccb8`,
branch `research/m3-rgba-layer-compositing`, XPS-15 Linux x86-64,
kernel `6.17.0-22-generic`, **LDC 1.43.0**, DUB 1.42.0,
`raster-d v0.2.0` peeled `2f2415851e45001df92ce56dad409f680684ba8d`
and `color-d v0.2.0` peeled
`3359f08f4e83941ac1a8451cadefb146b5736019`.
Untracked active user work appears in the saved worktree report but
does not enter `git archive HEAD` source builds.
The **exact measured commit passed 5/5 GitHub workflows**. Those gates
did not test whether Python process memory contaminated the wait4 maximum.

## What the original results actually say

All 48 full-run `wait4.ru_maxrss` results lie within **13,192–13,416 KiB**
regardless of ROI side 16, 64, 256 or 512. In contrast, the actual
running D `full` research consumer records the following **maximum
of its ten sampled /proc VmHWM values**, which change materially with
the requested output size:

| ROI side | Median Python-wrapper `wait4` peak (KiB) | Median D `full` maximum sampled `VmHWM` (KiB) | Median discrepancy (KiB) | Valid native request-size peak, `full` (bytes) |
|---:|---:|---:|---:|---:|
| 16 | **13,344** | **3,804** | **9,516** | 40,504 |
| 64 | **13,392** | **3,896** | **9,460** | 101,768 |
| 256 | **13,348** | **5,380** | **7,972** | 1,084,808 |
| 512 | **13,368** | **10,056** | **3,312** | 4,230,536 |

For all 12 separate `full` child processes the Python-wrapper
wait4 result exceeds the largest in-process `VmHWM` by
**3,164–9,584 KiB**. The four modes'
original paired `Δ kernel_peak_rss_kib` signs vary in both directions
and remain small even though the actual native request-size peaks
grow by several MiB. Therefore the apparent constant 13 MiB
`wait4` peak is **not credible as an independently isolated
physical memory high-water for the D research consumer**.

The request-size peak is a **different metric** and remains
replayable: for the `full` arm it increases from **40,504 B** at
side 16 to **4,230,536 B** at side 512. It is the maximum sum
of still-open *interposed requested sizes on the measured thread*,
not a physical process peak.

## Mechanism diagnosis: Python parent high-water before exec

The original research wrapper
`capture_m3_native_peak_wait4.py` called
`subprocess.Popen(..., pass_fds=(9,))` from a Python process and then
`os.wait4(child.pid, ...)`. The spawned child can inherit Linux
high-water accounting from its parent at **fork**, before its subsequent
`exec` of the D binary. The Python VM already has a much larger
resident footprint than the small D program at modest ROI sizes.
The reported maximum remains that **preexec high-water** even when
the D program later releases memory.

This was independently reproduced in the analysis container using
`/usr/bin/true`: when started from a Python interpreter whose own
high-water was approximately **95,244 KiB**, both the original
`subprocess.Popen(pass_fds=...)+wait4` and a Python-origin
`posix_spawn()+wait4` path reported **95,244 KiB** as the
very small child's peak. A dedicated native C helper started **directly
from a shell**, executing the same `/usr/bin/true` and collecting
`wait4`, reported **384 KiB**, comparable to GNU `/usr/bin/time`
for `true` in the same container. This control confirms the
measurement-design hazard, not a theorem about every platform's
fork/exec accounting.

**Do not substitute Python `posix_spawn` naively**: it too reproduced
the high-water inheritance in the controlled local test. This is a
material defect of the original **RSS peak claim**, not of the
interposed malloc-pointer ledger or of raster-d ownership.

## Corrected, independently reproducible instrument design

- New, small research-only native
  `experiments/m3_rgba_layer_compositing/alloc_events/m3_capture_native_peak.c`.
  Invoke the native helper **directly from the XPS bash runner**, never
  through a Python supervisor. Its small pre-spawn RSS high-water is
  recorded in an added `launcher_pre_spawn_peak_rss_kib` receipt field.
- The helper creates separate un-overwritable FD9 event, stdout, stderr
  and wait4 CSV files; directly `fork`/`execv` the existing D
  consumer with the pinned `LD_PRELOAD` interposer; and returns
  nonzero on a bad child exit. The research-only launcher's own C
  source is compiled with `-Wall -Wextra -Werror`.
- The **revised validator rejects the original four-field receipts**,
  requires the fifth native-launch provenance field, and rejects
  cases in which the launcher's pre-spawn maximum *equals or exceeds*
  the child's measured peak. For `full`, it checks that the measured
  kernel peak covers the maximum in-child sampled `VmHWM`.
  The C launcher cannot, by itself, remove all external process
  interference or turn an observed peak into a universal bound.
- The original Python capture entrypoint is **disabled for future
  captures**, while preserved for historic forensic inspection.
- The corrected 48-process XPS runner still reuses the **same
  four `markers` / `raw` / `import` / `full` consumer arms**,
  exact snapshot/dependency SHA pins, independent native replay,
  matched pair differences and SHA-256 evidence protocol.
  Only the launch/measurement mechanism has been replaced.
  The consumer production source and sibling repositories were not
  modified.
- Initial native C local smoke: compile with GCC `-std=c11 -O2
  -Wall -Wextra -Werror`, launch `/usr/bin/true` and validate
  receipt/exit: **PASS**. **Native D/XPS qualification remains PENDING**
  until the new commit's GitHub CI and a fresh user-run XPS archive
  verify the corrected full experiment.

## Decision and next gate

**REJECT** the numerical original Python-wrapper
`kernel_peak_rss_kib` as a D-consumer physical budget observation;
do not average, normalize or subtract its false constant baseline.
**PRESERVE** all raw event evidence and its previously independently
qualified native request-size peaks.

**ADAPT** native-shell-launched C child/consumer process-level
high-water measurement with explicit launch baseline.
Require exact source CI, eight-process native XPS smoke and
48-process fresh captures, 100% strict replay, reproducible ROI
scaling and paired variability before any claim that the kernel
reported peak is representative of D workload memory.

**DEFER** an exact admission bound. A correct `ru_maxrss` report
still contains input fixtures, druntime/GC and unrelated process
memory, lacks a complete allocator usable-size/residency inventory,
and does not promise a worst-case maximum for future workloads,
threads or allocators. Issue #74 stays OPEN and PR #73 DRAFT.
