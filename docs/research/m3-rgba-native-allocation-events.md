# M3 RGBA — Issue #74: native allocation-event lifetime instrumentation

**Status: bounded Linux/glibc research probe, native XPS results pending.**
No public API, no release code, no changes to raster-d/color-d, and
**no certified all-in memory bound**. Extends the verified
[XPS process-residency result](m3-rgba-generation-memory-xps-2026-10-15.md)
without treating RSS, glibc arena counters or GC allocation counts
as equivalent memory units.

## Question and hypothesis

The previous 20 native XPS process runs established real RSS dynamics,
a reproducible 256-byte **GC allocation** per fixed-three-generation
control object, and multiple glibc mmap/arena paths, but could
not show **exact native requested-buffer overlap or when individual
backings are actually freed**. They also could not identify
`raster-d` control allocations from a process-wide heap delta.

The next test must instrument **allocation and release events**,
maintain a bounded pointer-identity ledger and distinguish:
(1) the exact consumer-requested RGBA pixel buffer bytes,
(2) other *observed* malloc calls, some of which may come from
`raster-d` import, and
(3) events outside the interposer's scope.
Items (2) and (3) **must not** be silently reclassified as known
control blocks or as zero bytes.

## Deliberately narrow design

A separate C shared library
`experiments/m3_rgba_layer_compositing/alloc_events/m3_alloc_events.c`
interposes Linux/glibc `malloc`, `calloc`, `realloc`,
`free`, `aligned_alloc` and `posix_memalign`. It uses
implementation-specific glibc `__libc_*` entry points and
writes fixed-format events directly to **already-open file descriptor
9** with `syscall(SYS_write)`, without C formatted I/O, dynamic
allocation or heap-owned record tables. This is **research-only and
not portable** beyond the probed glibc environment.

The counters are **thread-local**, enabled by explicitly resolved
`m3_trace_stage()` calls from the independent DUB consumer. Other
threads (including possible druntime/GC workers), allocations
before/after stages, direct `mmap`/`munmap`, glibc internal
allocator calls that bypass the interposed symbols, stack/mapped
resources and external allocators **are not covered**. A `realloc`
is represented as removal of the previous pointer and admission
of the new requested allocation on success; its intermediate
physical peak inside libc is not observed.

The D bridge
`smoke/source/native_allocation_events.d` is compiled in ONLY
by the opt-in DUB configuration
`--config=native-allocation-events`. In default builds all bridge
functions are empty. The public imagery package is not changed
or made dependent on C. The actual experimental source-over
and `raster-d` ownership functions are unchanged.

The D source deliberately records one allocation **intent**
immediately before each consumer-owned pixel-buffer `malloc`:
- intent kind **1**: four-channel scratch; exactly `4N` requested bytes;
- intent kind **2**: packed result; exactly `4N` requested bytes.

Each A/B/C generation must create one kind-1 and one kind-2
allocation. Their actual allocator-returned pointer identities
are used to match subsequent intercepted `free` events.
**The kind is an explicit call-site marker, not a guessed
allocation-size heuristic.**

Other malloc calls are captured as **unclassified events**;
although some are expected around `raster-d` resource adoption
and import, this version does not label any individual one
as definitively its control block.

### Nine marked lifetime stages

| Stage | Interval after marker |
|---:|---|
| 1 | accounting-class construction |
| 2 | A compositing, four-channel scratch, packed import |
| 3 | A cache eviction, old A subscriber retained |
| 4 | B compositing/import, same-slot replacement, eviction |
| 5 | C compositing/import, same-slot replacement, eviction |
| 6 | cache-owner stack destruction |
| 7 | last A subscriber closes |
| 8 | last B subscriber closes |
| 9 | last C subscriber closes |

The immutable input images and prepared composer are constructed
**before stage 1**. Both the sampler and producer already passed
the original 432-scene numerical oracle and independently tested
single-threaded generation/close contract.

The trace has one event per line:

```text
ACTION,PHASE,POINTER,REQUESTED_BYTES,INTENT_KIND
```

where `S` starts a stage, `E` ends it, `I` declares an
explicit pixel-buffer intent, `A` is an observed successful
allocation and `F` an observed free. Hex pointers are ephemeral
identities within **one process**, not comparable across runs.
The event writer must not retain or dereference them.

## Qualification and attribution

`tools/research/summarize_m3_rgba_native_alloc_events.py` validates:

- all nine ordered stage pairs with a closed final stage;
- **six exact pixel-buffer intents**, paired to **six actual
  intercepted allocations** of `4N` bytes (scratch+packed
  for each of A/B/C);
- no duplicated still-live pointer IDs;
- actual free event for every identified pixel-buffer pointer
  by the end of stage 9;
- interposed requested-byte high-water and total allocated bytes,
  computed with a separate pointer-identity ledger, NOT glibc
  arena or RSS differences;
- unknown/pretrace frees preserved as a diagnostic, not treated
  as negative outstanding bytes;
- residual **other** intercepted allocations explicitly
  separated, with no assertion that their identity or overhead
  belongs exclusively to raster-d.

It is **not** enough to see `mallinfo2` shrink or a ledger charge
return to zero; the event stream must observe the physical frees
of identified pixel-buffer pointers.

The summed requested-byte peak is a **conditional lower-level
measurement of intercepted requests**, not an upper bound on
physical committed memory, RSS, implicit allocator bookkeeping,
GC heap, transient `realloc` internals or unmapped components.

## Reproduction

On pinned XPS Linux/glibc and LDC **1.43.0**, with locally
readable raster-d/color-d **v0.2.0** tags:

```sh
bash tools/research/run_m3_rgba_native_alloc_events_xps.sh --smoke
bash tools/research/run_m3_rgba_native_alloc_events_xps.sh
```

The runner compiles the C interposer with GCC/CC's
`-O2 -Wall -Wextra -Werror -fPIC -shared` independently,
builds the **opt-in** D consumer with LDC 1.43.0 Release and
archives actual source/dependency commits through `git archive`.
The smoke run records ROI side 16 and 256 once each. The
full native run records **3 process traces per ROI side** for
16, 64, 256 and 512 (**12 independent event lifetimes**).
All raw event files, process CSV, stdout/stderr, compiler
logs, exact build provenance and SHA-256 manifest are collected
in a fresh imagery-d-local evidence directory.

GitHub CI checks the parser's self-test, C compilation and the
runner shell syntax, while the LDC 1.43 consumer job additionally
executes side 16 and side 256 event streams using LD_PRELOAD
and verifies real pixel allocation pointer lifetimes. CI results
**must not be presented as native XPS performance evidence**.

## Next scientific gate and decision

The experiment can establish **requested payload overlap and
pointer retirement timing** for these real cache generations,
but cannot by itself certify a total allocator budget.

For precise `raster-d` control-block costing, follow up with
a separately controlled *adoption/import-only* probe and a
minimal raw-payload-only comparator using the same allocator
and equivalent compiler/toolchain, or with explicit allocation
call-site attribution. The current unclassified category is not
proof of such a block.

**Decision: research ADAPT, public API DEFER.**
Keep Issue #74 OPEN and existing PR #73 OPEN/DRAFT.
Do not merge the grandfathered stacked research branch, modify
sibling repositories or expose raster-d's reference count.
