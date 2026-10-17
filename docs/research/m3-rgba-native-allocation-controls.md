# M3 RGBA — matched native allocation controls for Issue #74

**Status: research-only design and instrumentation; native XPS measurements pending.**
A follow-on to the verified
[12-process native allocation-event result](m3-rgba-native-allocation-events-xps-2026-10-15.md),
which identified **61 unclassified allocation events** and
**13 unmatched-at-end stage-1 pointers / 35,336 requested bytes**
per process. Those observations were never proof of raster-d leaks or
native metadata overhead.

## Research question and falsifiable comparison

Which allocation events *actually change* when we use public
`raster-d` malloc-resource adoption and import, independent of the
known output-pixel buffers and the instrument itself? Can the control
measurements distinguish runtime/sampler overhead from imported
backing metadata, while preserving the same source-image warmup and
allocation/free observation window?

Four modes are built into the **independent DUB research consumer**:

| Case | Source fixtures/prepared RGBA context | One fixed-three-ticket generation accounting class | Three 4N scratch/packed malloc pairs | Public raster-d import | RGBA source-over |
|---|---|---|---|---|---|
| `markers` | yes | yes | none | only common pretrace fixtures | no |
| `raw` | yes | yes | yes, direct malloc/free | only common pretrace fixtures | no |
| `import` | yes | yes | yes | **both** per-generation scratch and packed result | no |
| `full` | yes | yes | yes | yes, as in existing proven source-over path | **yes** |

A/B/C are generated in stages **2, 4 and 5** and the externally
held packed buffers are released in stages **7, 8 and 9**.
An imported scratch lease and a direct raw scratch buffer are
kept alive until the packed output has been allocated, then each
is freed in its producer stage. The `full` case remains exactly
the *original* `--generation-memory` A/B/C lifetime test, with
real RGBA source-over and cache slot recycling. For control cases
the cache's fixed metadata accounting object is constructed
but no cache reservations are published; the raw/import backings
are independently owned in that consumer mode.

**Optimizing-compiler qualification incident (2026-10-15):**
The first hosted LDC 1.43 opt-in control run rejected the `raw`
trace: it contained `I(kind=1)` intents but **no kind-1 scratch
malloc events**. The optimizer had eliminated the scratch allocation
because an internal constant write/read did not make the
temporary storage observable. Accepting that trace would corrupt
the raw-versus-import comparison. The explicit raw control now
passes its scratch pointer to `m3_trace_touch`, an opt-in,
dynamically resolved, externally compiled C function which
writes volatile bytes at both ends of the provided storage
**after** the packed allocation is created and **before** the
scratch is freed. This performs no traced malloc, prevents
dead-allocation elimination, and ensures the requested raw
scratch backing is physically observable during overlap.
The scientific data remain subject to passing the actual
full LDC CI gate; these changes do **not** authorize silently
weakening the six-allocation/free verification.

Every mode constructs the same two populated source-image fixture
leases **outside** its event window, prepares the same source-over
context (even if not used for that control), prewarms
`sampleGenerationMemory()`, resolves the same opt-in
`LD_PRELOAD` trace symbols, samples the same nine phase
boundaries and keeps output on separate stdout/FD9 streams.
Both the C tracer and D compiler are identical across modes.

**Important matching caveats:** the full path invokes additional
cache reserve/adopt/deliver/evict and prepared-color operations;
their malloc events are not guaranteed to originate only from
raster-d. Lazy druntime/GC behavior and imported resource
destructors can vary with the case. A difference in anonymous
`kind=0` malloc requested bytes is a **candidate signal for
further call-site attribution**, not by itself a certified
control-block cost. The `markers` case still constructs the
generation accounting class, so its phase-1 allocations provide a
baseline rather than an absent-accounting reference.

## Observable event contract

The unchanged Linux/glibc single-thread C interposer records native
malloc-family calls by pointer ID into FD 9. Only the two explicit
call sites for the research-owned RGBA pixel buffers emit
`kind=1` (scratch) or `kind=2` (packed) allocation intents.
The new dedicated validator
`tools/research/summarize_m3_rgba_native_alloc_controls.py`
requires:

- exactly nine closed and ordered stages, no dangling declared intent;
- `markers`: zero tagged allocations;
- `raw`, `import`, `full`: exactly six tagged allocations,
  two per A/B/C production stage, each **4×side²** requested bytes;
- each tagged scratch freed **within** its production stage;
- each tagged packed pointer freed at the matching last-owner
  stage **7/8/9**, with no early owner release or terminal survivors;
- malloc pointer identity is never simultaneously duplicated;
- other intercepted malloc/free events stay classified as
  **unknown source**, including any unmatched pretrace frees.

For each stage, the output CSV reports tagged and unclassified
allocation calls/bytes, tagged/other frees, pretrace frees,
end-of-stage requested bytes still outstanding in each category,
and the highest intercepted outstanding requested bytes
within that stage. A separate aggregate CSV contains totals,
production-phase unclassified requested bytes, stage-1 requested
bytes, final unclassified outstanding bytes and observed peak
intercepted requested bytes.

These are **event-based requested-byte counts**, not the usable
size of a native allocator block, process RSS, full GC heap
size, transient realloc peak or an all-in peak guarantee.
The tracer does not observe direct mmap, other threads, or
glibc internal bypasses; the parser cannot establish an exact
control-block type from a pointer address or malloc size.

## Compiler gate and native XPS design

CI retains all previous independent source-over/ownership/
negative-compile gates. The control protocol's malformed-trace
self-test and the XPS runner's shell syntax are checked in all
four compiler jobs. LDC **1.43.0** additionally compiles
the **opt-in** `native-allocation-events` configuration and
tests all four modes with FD9/LD_PRELOAD at ROI side 16 and 256.

Native runner:
```sh
bash tools/research/run_m3_rgba_native_alloc_controls_xps.sh --smoke
bash tools/research/run_m3_rgba_native_alloc_controls_xps.sh
```

The script uses immutable archived imagery HEAD, pinned raster-d
and color-d **v0.2.0**, LDC 1.43.0 release and one strictly built
glibc C interposer. Smoke mode executes **4 cases × 2 sides =
8 independent processes**. The full run exercises
**4 cases × 4 sides × 3 repeats = 48 processes**. Each process
produces a checksummed event trace, stdout/stderr, nine-stage
CSV and aggregate CSV. Compiler/CPU/governor/source commit
provenance and both build logs are archived with SHA-256.
The binary research recorder is covered by the manifest.

No native XPS result is claimed until those source-verified
logs have been uploaded and independently checked.

## Decision gate

1. Compare *within matched side and run index* the unclassified
   allocation call counts, requested sizes, stages and lifetimes
   between `markers` and `raw`, then `raw` and `import`,
   then `import` and `full`.
2. If import-only introduces consistent events in its producer
   stages, identify them with a separate call-site/stack-backed
   attribution experiment before naming them raster-d
   control-block metadata or using them in an admission budget.
3. Preserve any extra phase-1 residuals as unattributed until
   their owner/lifetime is demonstrated; the GC's 256-byte
   class allocation **must not** be added to malloc observations
   without proving it was not also intercepted.
4. Keep native allocator/RSS bound, pool/backpressure and
   cross-thread/cancellation API admission **DEFERRED**.

The accepted research branch remains stacked on the
existing Draft PR #73, with Issue #74 OPEN. No public imagery
API, C runtime dependency in the production package,
raster-d change, branch rewrite or merge.
