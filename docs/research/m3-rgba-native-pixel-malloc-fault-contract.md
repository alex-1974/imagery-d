# M3 RGBA — actual native pixel malloc failure, empty publication and refund

**2026-10-15 · Issue #75 · Research only · DMD/LDC exact-head CI pending.**
**Decision:** bounded investigation of the owned-packed result error path,
**not** publication of the research generation cache, memory API, or an
all-in OOM guarantee. The first/second malloc-failure experiment is
separate from the already independently archived successful native
malloc event traces.

**Post-test gate update (exact measured source):** at imagery-d
`201fd88e3daee4ca8bf56118718a1647976fbb2a`, all **5/5
GitHub workflows SUCCESS**. The independent native first/second
`malloc == NULL` cases passed **DMD 2.112.1 / 2.113.0** and
**LDC 1.42.0 / 1.43.0** in release. This replaces the
original pending status for that source only; later experimental
imports are separately qualified.
The [separate real public-import metadata failure protocol]
(m3-rgba-public-import-metadata-enomem-protocol.md) now covers
pre/post-commit error dispositions, with independent CI status.

## Why this control is not another simulated cancellation test

The existing research `ReservedFault.beforeFirstAllocation`,
`beforeSecondAllocation` and `latePackedWrite` controls *return
before a selected work stage* and prove state cleanup. They do
**not** prove what happens when the actual libc pixel allocation
returns NULL and the D runtime unwinds out of the function.
The [first-production-slice review]
(m3-rgba-first-production-slice-admission-review.md) identifies
this distinction as admission blocker B3.

This new **Linux/glibc-only** test interposes `malloc` into the
existing independent DUB consumer. A deliberately narrow exported
control API arms **exactly one** matched pixel request, identified
by an explicit D call immediately before its physical malloc,
with the expected requested size (1,024 bytes for the 16×16 ROI).
It returns **NULL, errno=ENOMEM** for the selected request on
the invoking thread, then disarms itself. No probabilistic
system-wide memory pressure or unbounded process memory
allocation is needed. The D logic itself makes the normal
`malloc` call: no synthetic pre-malloc skip.
The shim lives exclusively in
`experiments/m3_rgba_layer_compositing/alloc_events/m3_fail_pixel_malloc.c`,
built as a research LD_PRELOAD library.

The `native_pixel_faults.d` D bridge is enabled **only** under
the additional `native-pixel-faults` research DUB configuration.
The ordinary source-over, normal benchmark and archived native
trace configurations contain only empty no-op stubs for its
intent calls. No production imagery/raster/color module is
linked to the shim.

## Exact trial, assertions and interpretation

The test creates two genuine already-owned 32×32 sources and
prepares the same exact source-over configuration before fault
arming. For ROI `Region2D(5,7,16,16)`, the existing
serialized `RoiReservationLedger(3400)` uses its historical
**illustrative** 128B/64B metadata credits; this is **not**
a physical metadata admission guarantee. Its full in-flight
charge is 2,176B; a successful result retains 1,088B in
the research example.

| Trial | Physical malloc that returns NULL | Required control evidence |
|---|---|---|
| First pixel request, kind=1 | Four-channel scratch, 1,024B | One targeted failed malloc; zero scratch allocation/free; the normal D failed-allocator exception observed; no published packed owner; zero ledger charge, slot empty |
| Second pixel request, kind=2 | Packed output, 1,024B | One targeted failed malloc; precisely one earlier physically allocated scratch and exactly one intercepted release of its same pointer during D unwinding; no published owner; zero ledger charge, slot empty |

After each failure, the fault is **disarmed** and the
**same ledger, same slot and same ROI** undergo a full
source-over/pack/import success, produces a sampleable
one-plane `RasterLease!SRgba8` with the expected retained
example charge, then releases its real owner and refunds
the entire charge. This immediately tests whether the
failure left a hidden ledger/state obstacle for further
materialization.

Assertions run in **LDC/DMD release builds**, not only
D `assert` debug mode. CI requires one distinct PASS
receipt per failure kind, in a new trailing step that
builds the separate research config and the shim
using `cc -std=c11 -O2 -Wall -Wextra -Werror -fPIC
-shared`. The four-compiler matrix is DMD 2.112.1,
DMD 2.113.0, LDC 1.42.0 and LDC 1.43.0.
**Until the exact-source CI step is green, these
tests are IMPLEMENTED but not qualified PASS.**

## Explicit negative claims

- The thrown exception is the current research
  helper's response to `malloc == NULL`, **not**
  a new accepted recoverable result or an implied
  publicly stable error enum.
- The native C shim records only tagged selected
  `malloc`/corresponding `free` events on its
  thread. This experiment cannot prove glibc
  allocator usable-byte size, mmap/GC residency,
  other-thread state, a kernel OOM killer response,
  druntime Error-level OOM, or total process
  physical-memory admission.
- Passing the first and second pixel-site tests
  does **not** cover failure in
  `tryAdoptMallocResource`, raster-d control-block
  allocation, the publicly reported
  `releasedAfterCommit` import disposition,
  late native release failures, or arbitrary
  concurrency/cancellation. Those remain **open**.
- The shim is not a production allocator or a
  valid generic mechanism for providing memory
  quotas. It changes malloc behavior **solely**
  for this recorded independent consumer test.
- The producer currently validates some source
  semantics after scratch allocation; preflight
  ordering remains open separately. The
  destination-oriented four-plane compositor's
  alias/noalias question is **independent**.
- The exact historical 128/64B credits must not
  be misrepresented as proven per-generation
  physical metadata costs: the qualified Tier-P
  requested-pixel math is a distinct 8N/4N law.

## Admission disposition

**If the tests pass:** update the Issue #75 owned
result matrix to acknowledge actual first and
second pixel `malloc` NULL unwinding, scratch
release, zero-publication and quota refund on
the pinned glibc host. The remaining real
import/GC Error dispositions and public API
choice still block M3 admission. Keep Draft
PR #73 OPEN/DRAFT, no release and no edits to
sibling repositories.

**If a test fails:** preserve the failing
compiler/run logs, diagnose the precise
ownership or exception rule, do not weaken
expected ledger or pointer-release assertions
just to force a green gate.
