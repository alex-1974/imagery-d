# M3 RGBA — deterministic semantic validation before owned pixel allocation

**Date:** 2026-10-15 · **Issue #75** · **Draft PR #73**
**Status:** research-only implementation and four-compiler regression gate.
**Qualification:** exact-head CI PENDING. This is not a public M3 API decision.

## Admission question

The original consumer-local owned packed RGBA helper created an actual
four-plane `malloc` backing **before** calling the prepared compositor.
That prepared compositor then checked its input geometry, source encoding,
prepared-context readiness and canonical linear-premultiplied samples.
Consequently a valid-sized ROI with an invalid source descriptor,
an inert context, an out-of-source ROI or one noncanonical PM sample
could consume scratch allocation and raster-d import overhead before
predictably failing. The fixed research Tier-P payload accounting
refunded the reservation, but it did **not** prevent needless
physical allocation. The separate actual native pixel and importer
ENOMEM experiments address resource failure *after* admissible work
and do not discharge this deterministic preflight obligation.

## Narrow implementation

The research-only image-domain module now factors the previously
existing prepared-compositor preflight into two shared private
`@safe nothrow @nogc` helpers: (1) source/configuration/ROI
geometry; (2) a complete scan of canonical linear-PM bytes in
the selected ROI. Its public-in-the-research-package
`tryPreflightRgbaSourceOverPrepared` combines those checks and
**does not allocate storage, retain views or write samples**.
It checks input shape/metadata and ROI, but does **not**
validate any future output writable view's plane count, shape,
layout/injectivity or physical overlap, nor does it certify
future sampled bytes against concurrent mutations.

Both the consumer-local direct `tryCompositeOwnedPackedResearch`
and the reserving `runReservedOwnedProbe` now invoke this
preflight **before the first physical scratch allocation**,
after existing output-emptiness/checked-ROI-size and, for
the reserving helper, after the logical quota has been acquired.
If preflight fails in the reserving case, its pre-existing
`scope(exit)` returns the entire pending charge before
the function exits. The destination-oriented prepared
compositor preserves its prior priority of invalid
output descriptor **before** canonical PM scans, then
uses the same extracted canonical PM checker. Its
mathematical per-pixel operation and `color-d` conversions
remain unchanged.

The independent owned helper's existing second invocation
of the prepared compositor repeats the canonical PM scan
for PM inputs after allocating scratch. This redundancy
keeps the original prepared writing contract independent
and is **not asserted to be performance-neutral**.
A later optimized publication form could avoid duplicate
validation only with an auditable lifetime-bound validation
capability, provenance rule and its own compiler/performance
tests. Do not introduce an unsafe unchecked path now.

## Native no-allocation regression evidence

The same opt-in native `m3_fail_pixel_malloc.c` interposer used
for true malloc/metadata ENOMEM qualification counts physical
scratch/packed pixel `malloc` requests by explicit, immediately
preceding producer intent labels. In the independent
`native-pixel-faults` release-DUB test it is disarmed
(`kind=0`): any actual pixel allocation would still be counted,
but it cannot be misinterpreted as a caused ENOMEM.

After preparing real, already malloc-backed 32×32 source
leases, the test presents four deterministic invalid cases
to **both** the direct owned helper and the quota-reserving
helper:

| Case | Invalid condition | Required preflight status |
|---:|---|---|
| 0 | `ResearchPreparedRgbaContext.init` | `invalidPreparedContext` |
| 1 | Nonempty ROI starts at (29,29), size 16×16, outside 32×32 source | `invalidRegion` |
| 2 | Encoded sRGB tagged premultiplied, which is unsupported | `invalidEncoding` |
| 3 | Linear-premultiplied upper source with `r=255, a=0` at the **last** ROI coordinate (20,22) of ROI (5,7,16,16) | `invalidPremultiplication` |

All four cases must preserve an **empty** packed publication,
observe exactly **zero** intercepted scratch and packed
pixel allocation requests, and (for the reserving path)
return `ledger.charged=0` with its slot empty. The
complete-ROI poisoned-PM case challenges
first-pixel-only shortcuts.

CI requires four individual
`M3 RGBA SEMANTIC PREFLIGHT PASS: case=0..3`
receipts in the independent consumer's new glibc-only
native fault configuration. The underlying prepared
compositor's 432-scene independent numerical oracle,
DMD/LDC debug/release tests and previous native
first-/second-malloc/import dispositions remain mandatory.
**Do not report this new result PASS before the exact
commit's GitHub Actions have completed successfully.**

## Deliberately retained gaps

- The input snapshot is borrowed; another thread changing
  source pixels between preflight and construction could
  invalidate the semantic observation. This is a
  single-threaded owner/ROI research contract, **not**
  a concurrency or snapshot guarantee.
- A valid-looking raster view does not establish
  physical source/output noalias. The independent
  four-plane alias counterexample remains true.
- Real pixel allocation failure and public importer
  metadata failure are separate tested error
  classes, not prevented by semantic preflight.
  Druntime/GC Error-level OOM and backing-control
  registration remain outside this test.
- Tier P bounds **requested** RGBA pixels, not
  allocator metadata or total RSS; no new physical
  memory budget is inferred.
- This check does not choose between destination-oriented
  and independently owned result publication, create
  any accepted public name/error enum, freeze an API,
  or admit experimental cache/scheduler types.

**Disposition: ADAPT the reusable semantic validation,
DEFER production admission and any claim of concurrency,
universal OOM recovery or physical memory ceiling.**
Only `imagery-d` research/CI is written; sibling
repositories are pinned read-only.
