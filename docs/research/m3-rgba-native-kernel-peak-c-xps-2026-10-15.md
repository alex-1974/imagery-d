# M3 RGBA — native-C kernel-peak XPS qualification (2026-10-15)

**Issue #74 · Draft PR #73 · research-only.**
**Decision: ACCEPT integrity / exact native request-lifetime replay and the process-level Linux measurements as observations; REJECT a hard physical memory-admission bound from them.**
The native-C replacement has corrected the earlier Python-launch contamination, **but 9/12 full-process /proc resident values exceed the corresponding `wait4.ru_maxrss`**. Both original sources of evidence are preserved without silent normalization.

## Source evidence and provenance

Original user-uploaded archive: `20261015T134309Z.tar.gz`.
**Entire compressed-archive SHA-256:**
`3f057d9e81a2cff7719ae8438dce16eb925f3f35a03dd54d7a0a36e01fdeb786`.

| Property | Recorded value |
|---|---|
| XPS capture | 2026-10-15 **13:43:09 UTC**, normal/full mode |
| Host | `xps-15`, Core i7-9750H, Linux x86-64 `6.17.0-22-generic` |
| Compiler, DUB, C compiler | **LDC 1.43.0**, **DUB 1.42.0**, **GCC 15.2.0** |
| Source branch / HEAD | `research/m3-rgba-layer-compositing` / **`7bc249d7e5b088793b66203215ca71077bc9611c`** |
| `raster-d v0.2.0` peeled SHA | `2f2415851e45001df92ce56dad409f680684ba8d` |
| `color-d v0.2.0` peeled SHA | `3359f08f4e83941ac1a8451cadefb146b5736019` |
| Exact measured-commit GitHub CI | **5/5 workflows completed SUCCESS** |
| Independent subprocesses | **48/48**, all four `markers/raw/import/full` modes × four ROI sides × three repetitions |
| Child stderr | **48/48 empty** |
| Native capture scaling canary | **PASS** |
| Python summary-validator self-test | **PASS** |

**Archive-integrity qualification:** 346 regular tar entries; **346 distinct manifest names**, of which **344 regular files are present and match their recorded SHA-256**. Two manifest-listed, compiled native research binaries—`m3_capture_native_peak` and `libm3_alloc_events.so`—are **absent from the uploaded tar**, though the captured `checksum-validation.txt` reports `OK` for them in the original XPS directory. That receipt is **not a substitute** for independently hashing absent bytes. Apart from the manifest and its checksum-output receipt, no other regular files are missing from, or unexpectedly added to, the listed payload. No duplicate/unsafe archive paths or links were found. **Do not write “346/346 archive checksums pass” or imply full executable-byte provenance from this upload.** The recorded pinned Git commit/dependency versions identify source provenance; a Git source snapshot was not included in this tar.

Untracked pre-existing XPS research executables, DUB selections and prior evidence archives are present in `worktree_begin/end`. The runner built immutable `git archive HEAD` and pinned read-only sibling tags, so they do not enter the research executable source. No other repository was modified.

### Independent replay beyond the included validation receipts

All **48 raw, nine-phase native malloc/free/intent traces** were independently replayed from pointer-bearing event streams; all **48 stored per-phase CSVs** exactly match the freshly calculated per-stage allocation and pointer-lifetime ledger. The checks include phase order, one scratch and packed tagged allocation per A/B/C producer, sizes, required frees, final absence of tagged pixels, untagged bytes outstanding and per-event requested-size peak. All **48 single-run summaries**, **48 pairwise peak contrast rows**, and **12 full-producer /proc-vs-wait4 difference rows** were independently recomputed and matched their user-supplied CSVs. Each of the 12 full-producer ten-phase /proc traces also satisfies the real-generation/pixel-budget identity, valid last-owner retirement, and a separate **+256 B** thread-cumulative GC metadata-class allocation, with no further sampled increase. One pretrace free is present in every event trace; it is not an automatically identified image allocation or ownership leak.

These checks establish reproducibility of the recorded **measurement protocol**, not all-in physical memory correctness or unrecorded C-binary bit identity.

## Corrected C launch: observed Linux resident memory

Unlike the disqualified prior Python-parent capture, the research C child supervisor was invoked directly from Bash. Its recorded prelaunch resident high-water lies far below each D-child report (approximately 1.4 MiB versus 3.6–10.1 MiB); the small-versus-24-MiB child canary also reports PASS. The former near-constant, Python-dominated ~13 MiB peak has **not recurred**.

The table below gives three independent full-producer processes per ROI; all values KiB. `Δ` is **wait4 child maximum minus the highest sampled /proc VmRSS**. The highest sampled `VmHWM` equals the highest sampled `VmRSS` numerically in these 12 full runs (but not necessarily at the same moment).

| ROI side | Native-C `wait4.ru_maxrss` median [min, max] | Full child max sampled `VmRSS` median [min, max] | Signed `Δ` by repeat, KiB | Runs with `VmRSS > wait4` |
|---:|---:|---:|---|---:|
| 16 | **3,820** [3,764, 3,916] | **3,860** [3,840, 3,868] | **+76, −104, −40** | 2/3 |
| 64 | **4,060** [3,972, 4,112] | **3,984** [3,976, 3,996] | **+116, +84, −12** | 1/3 |
| 256 | **5,264** [5,260, 5,396] | **5,388** [5,328, 5,468] | **−128, −64, −72** | 3/3 |
| 512 | **10,012** [9,960, 10,124] | **10,084** [10,076, 10,128] | **−4, −64, −124** | 3/3 |
| **Total** | | | **Observed signed range: −128 to +116 KiB** | **9/12** |

The differences are **not just a peculiarity of nominal `VmHWM`**. In precisely **9/12** cases, the contemporaneous process `VmRSS` sample is also numerically above the **process-lifetime** RSS maximum reported at exit by `wait4`. Neither statistic may safely be treated as a mathematically certified upper bound for this experiment.

**Independent Linux documentation:** `/proc/pid/status` describes both `VmRSS` and `VmHWM` as **inaccurate**; `proc_pid_statm(5)` explains that a kernel-internal scalability optimization can cause imprecision and recommends `/proc/pid/smaps` or `smaps_rollup` for a more accurate, slower point-in-time inventory. `getrusage(2)` defines `ru_maxrss` as the process high-water in KiB. This makes the observed cross-source inconsistency **plausible as kernel accounting/sampling disagreement**, **not proof** of which value is inaccurate by how much or that the native C recorder has no further instrumentation effects.
References:
- https://man7.org/linux/man-pages/man5/proc_pid_status.5.html
- https://man7.org/linux/man-pages/man5/proc_pid_statm.5.html
- https://man7.org/linux/man-pages/man2/getrusage.2.html

## Native intercepted-request peak: separate, reproducible measurement

These are **only the maximum sum of outstanding intercepted malloc-family requested sizes on the measured D thread in the nine-stage recorder window**. They omit allocator headers/usable bytes, GC heap residency, nonintercepted `mmap`, other threads and prior allocations, and are *not* total process RSS. Each peak is **identical in three independently captured repeats**.

| ROI side | Markers-only request peak | Raw request peak | Public-import request peak | Full producer request peak | Import − raw requested peak |
|---:|---:|---:|---:|---:|---:|
| 16 | 36,832 B | 39,904 B | 40,504 B | **40,504 B** | **600 B** |
| 64 | 36,832 B | 100,872 B | 101,768 B | **101,768 B** | **896 B** |
| 256 | 36,832 B | 1,083,912 B | 1,084,808 B | **1,084,808 B** | **896 B** |
| 512 | 36,832 B | 4,229,640 B | 4,230,536 B | **4,230,536 B** | **896 B** |

The `import`/raw contrast is the **difference in independent process maxima**; it is not an exact per-backing usable-size byte charge. A separate qualified direct GC-range control attributes the **48/72/48/24 B** request trajectory to druntime conservative range bookkeeping in the narrower two-import setup; do not automatically subtract it as per-backing native physical memory here.

The paired kernel `full - import` **median** high-water differences are:
ROI16 **+8 KiB** (min 0, max +116),
ROI64 **+100 KiB** (+60…+176),
ROI256 **+1,036 KiB** (+996…+1,224),
ROI512 **+4,092 KiB** (+4,092…+4,352).
For all four ROI sizes the *same pairwise intercepted requested-size peak difference* is **0 B**. This discrepancy demonstrates that **source image fixtures, compositor execution, GC and general process runtime can materially affect kernel-reported resident high-water even when measured intercepted request peaks agree**. It does not identify which component caused the difference. Pairing uses **different processes**, so neither sign nor value is a universal causal contribution.

The raw-vs-markers kernel peak can even be negative (e.g., side 256: median **−88 KiB**) despite a deterministic positive difference in requested live bytes. Cross-process kernel measurements cannot establish a monotonic per-resource cost by subtraction.

## Research decision and admission boundary

**PASS:** frozen source, 48-process source/owner/event replay, exact requested-size peak under the original tracer's scope, full requested pixel lifecycle, and process-level native-C `wait4` measurements as *reported observations*; the corrected launcher removes the previously diagnosed Python high-water contamination. **PASS with provenance caveat:** all **344 available** manifest-listed payload files match; two manifested binaries absent from upload prevent complete independent binary verification.

**MEASUREMENT CONTRADICTION REMAINS:** `wait4.ru_maxrss` is **not a certified continuous physical upper bound** on the in-child `VmRSS` samples in this pinned host, with nine of twelve full runs violating the naive cross-source inequality. Do not discard those nine, adjust, clamp or invent a new RSS “max” by mixing inconsistent counters.

**ADAPT:** stop using process RSS or malloc request peaks as directly additive budget components. Preserve this qualified numerical evidence and document a **bounded resource-policy contract** separately: exactly tracked scratch/packed pixel requests and true retained last-owner generations are hard-accountable, while native control metadata, runtime GC/allocator effects and globally shared tables need explicit platform headroom or independently scoped bounds before admission. If a more accurate *point-in-time* Linux resident inventory is needed, a separate `smaps_rollup` **diagnostic** is a reasonable next controlled research step; it still cannot prove an exact instantaneous materialization peak or all-future-input guarantee. Avoid an open-ended RSS instrument research cycle without a concrete decision threshold.

**DEFER:** full physical resident-memory admission, public image API freeze, Draft PR #73 merge, release and generalization to other allocators, runtimes or threaded cancellation. Do not modify sibling `raster-d` or `color-d`.
