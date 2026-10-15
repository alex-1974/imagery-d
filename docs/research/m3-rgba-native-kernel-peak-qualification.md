# M3 RGBA — kernel peak RSS versus native requested-size peak

**Issue #74 · Draft PR #73 · 2026-10-15 · research-only protocol.**
**State (revised after 2026-10-15 XPS):** The original Python-parent
8-process smoke and 48-process full capture were **integrity-qualified but
rejected for physical kernel-peak interpretation**, because the child
`wait4.ru_maxrss` inherited Python's pre-exec high-water mark. See the
[documented instrument failure and complete XPS audit]
(m3-rgba-native-kernel-peak-xps-2026-10-15.md).
A minimal native C supervisor and new validator are now implemented;
**corrected native-launched XPS evidence is PENDING**. No all-in budget
or public API is authorized.

## Existing evidence and exact remaining question

Do **not** repeat the 96 independently qualified nine-stage
[full-producer native control traces](m3-rgba-native-allocation-controls-xps-2026-10-15.md):
they already report the peak of **simultaneously outstanding interposed
malloc-family *requested sizes*** and full per-pointer final-owner
lifetimes. Recomputing this same quantity under a new name is not research.

Do not reinterpret the [20-process real A/B/C process memory evidence]
(m3-rgba-generation-memory-xps-2026-10-15.md) or the
[40-process subscriber-count comparison]
(m3-rgba-generation-subscriber-physical-memory-xps-2026-10-15.md):
their ten/eleven `/proc/self/status` observations bracket producers but do
not guarantee capture of a **brief memory high-water during production**.
Prior XPS samples also show Linux `VmHWM` *decreases* after large backing
releases. Those unexpected raw observations must not be discarded.

The **new, falsifiable question** is: in the **same independently executed
process** where the exact nine-stage native request trace is collected,
what Linux **process-lifetime maximum resident set size** does
`wait4(2)` report for that process, including moments BETWEEN
`/proc` phase checkpoints? Does the pattern across four matched
control paths and ROI sizes support or contradict an attempted
physical peak-budget model?

## OS measurement contract

On Linux, `wait4` returns a completed child's `struct rusage`;
`ru_maxrss` is the **maximum resident set size in KiB** for that
child. We also preserve minor/major page fault counts and exit status.
See the [Linux man-page for getrusage/wait4 semantics]
(https://man7.org/linux/man-pages/man2/getrusage.2.html).
This is a **kernel-reported, process-wide RSS high-water mark**,
not total virtual address space, allocator reserved capacity, a
physical per-Backing cost, or a portable D API requirement.
It may include input fixtures, runtime initialization, druntime GC,
native allocations, allocation metadata, thread stacks and unrelated
process state. It is *not* a per-operation high-water since the previous
checkpoint, nor attributable to an individual raster import.

The old C `LD_PRELOAD` recorder is reused **unchanged**. It logs only
interposed malloc-family calls on the selected invoking thread,
and its Python replay establishes the observed maximum of requested
size for allocations live **in the trace window**. That peak
may exclude allocations before tracing, other threads, direct
`mmap`, allocator bookkeeping, GC heap residency, and libc
internal calls not intercepted. `realloc` is logged as
`free-old/request-new` *after it returns*; it cannot certify the
actual concurrent implementation peak while realloc is executing.
One must **never add** that requested-size peak to `ru_maxrss`,
`mallinfo2` or the current-thread GC cumulative-allocation count.
All metrics are separate observation layers.

## Research implementation (no consumer implementation change)

**Correction after the first XPS evidence:** The earlier
`capture_m3_native_peak_wait4.py` was **invalidated** for peak-RSS
measurement because a Python parent can contaminate the child's
high-water at fork before exec. Its capture entrypoint is now disabled.
The research-only **native C** `m3_capture_native_peak.c` is instead
compiled with `-Wall -Wextra -Werror` and invoked *directly by the
XPS bash runner*. It `fork`/`execv`s the independent D consumer,
passes FD 9 to the existing C trace, and collects native `wait4`
RSS/faults and child exit status. The C launcher's own pre-spawn
`ru_maxrss` is recorded as a **fifth receipt field** so the validator
can reject a launcher-dominated peak. The `LD_PRELOAD` interposer
is installed only in the D child. Standard output, error and native
events remain separately recorded; existing evidence files are not
overwritten.

The strict `summarize_m3_rgba_native_kernel_peak_xps.py` validates
this receipt and replays the **existing, audited native controls
validator**; for `full` it also replays the established ten-phase
generation-memory snapshot validator. It rejects malformed fields,
nonzero child status, bad success markers, source/pixel-lifetime
violations and stderr diagnostics. Positive and negative synthetic
receipt fixtures are included.

The XPS runner
`tools/research/run_m3_rgba_native_kernel_peak_xps.sh` uses immutable
`git archive HEAD` snapshots and **exact peeled SHA checks** on
read-only `raster-d` and `color-d` v0.2.0. LDC **1.43.0** and Linux
glibc remain pinned; there is no cross-platform performance claim.
The user-held source worktree is never reset or cleaned.

Four independent process modes at each ROI:
`markers` (runtime/fixture/markers-only baseline),
`raw` (unowned C-pixel allocations and frees),
`import` (public raster adoption/import/retained release), and
`full` (real compositor, accounting and cache/subscriber delivery).
The **original source semantics are not altered**.

- Smoke: ROI sides 16 and 256 × four modes × one repetition =
  **eight processes**.
- Full XPS: sides 16, 64, 256, 512 × four modes × three independent
  repetitions = **48 processes**.
- Each produces raw native events, child stdout and stderr, a wait4
  receipt, validated per-run summary and nine-stage ledger, along with
  a paired peak-difference CSV, build/environment logs and SHA-256
  manifest. The temporary source/build snapshot is excluded from the
  evidence manifest and user-upload archive; archive-level digest
  still identifies the complete user-held archive.

The paired difference file records separate columns for
`Δ kernel_peak_rss_kib` and
`Δ peak_intercepted_requested_bytes`. Compute contrasts
`raw-markers`, `import-raw`, `full-import` and
`full-markers` on process pairs grouped by side/repetition. These
are **comparisons of separate processes, not within-process
counterfactuals**. Different allocator warmup and process history
can produce a negative pairwise RSS difference even when all
controls are correct. Do not reject negatives or silently clamp
to zero.

## Qualification and decision criteria

The new native capture is **not yet qualified on the XPS**.
The original two archives are retained as negative method evidence
and as valid independent native request-event replays, not as certified
process peak RSS results.


Accept *recording integrity* only after positive/negative parser
self-tests, CI Linux smoke, strict **48/48 native nine-stage replays**
and checksum verification. Check reproducibility across repetitions.
Report medians and **full min/max** per ROI and contrast, together with
control-specific absolute `ru_maxrss` and event-request peaks,
including discordance with stage-`VmHWM` in `full`.

**This observation cannot by itself qualify an all-in conservative
per-ROI budget**: even the observed absolute process RSS maximum
belongs to a particular prepared fixture/workload/runtime and lacks
a proven hard upper bound for future inputs. We would additionally
need a specified allocator/toolchain/GC regime, a complete
allocation inventory including usable sizes, GC heap lifetime and
peak, reserve-before-materialize/failure semantics, a justified
safety margin and a separately qualified worst-case workload and
thread policy. Otherwise label the result **ADAPT** observation
and **DEFER** admission/public API.

**No speculative hard-coded per-generation metadata allowance,
new public cache/scheduler, release gate or write to sibling
repositories is justified by this measurement.**
